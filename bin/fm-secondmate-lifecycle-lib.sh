#!/usr/bin/env bash
# Shared secondmate-home admission and retirement lifecycle contract.
#
# Source this file only after bin/fm-wake-lib.sh has provided
# fm_lock_try_acquire and fm_lock_release.
# The admission lock and epoch live under the machine's existing Firstmate XDG
# state root and are keyed by the canonical home path, so teardown can retain
# them while the home itself is returned or removed without writing inside a
# Treehouse-managed hierarchy.
# Spawn acquires the home admission lock before its per-task lifecycle lock;
# teardown acquires the same home lock before retaining child lifecycle locks.
# fm_secondmate_spawn_task_lock_acquire returns 0 with the task lock held, 1
# when the task lock is contended or identity cannot be resolved, and 2 when
# retirement or a changed home epoch requires the launch to refuse.
# A retirement marker is created only while admission is held, records its
# exact creating owner, is removed only by that owner before destructive
# progress, and is retained after ambiguous destructive progress.

fm_secondmate_canonical_home() {  # <home>
  local home=$1 canonical
  canonical=$(CDPATH='' cd -P -- "$home" 2>/dev/null && pwd -P) || return 1
  case "$canonical" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$canonical"
}

fm_secondmate_lifecycle_root() {
  local root
  root="${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/secondmate-lifecycle"
  case "$root" in /*) ;; *) return 1 ;; esac
  case "$root" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$root"
}

fm_secondmate_lifecycle_root_ensure() {
  local root
  root=$(fm_secondmate_lifecycle_root) || return 1
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ]
    return $?
  fi
  mkdir -p -- "$root" || return 1
  [ -d "$root" ] && [ ! -L "$root" ]
}

fm_secondmate_retirement_external_path() {  # <home> <suffix>
  local canonical root digest
  canonical=$(fm_secondmate_canonical_home "$1") || return 1
  root=$(fm_secondmate_lifecycle_root) || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$canonical" | sha256sum | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$digest" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  printf '%s/secondmate-retirement-%s.%s\n' "$root" "$digest" "$2"
}

fm_secondmate_retirement_lock_path() {
  fm_secondmate_lifecycle_root_ensure || return 1
  fm_secondmate_retirement_external_path "$1" lock
}

fm_secondmate_retirement_epoch_path() { fm_secondmate_retirement_external_path "$1" epoch; }

fm_secondmate_retirement_epoch_field() {  # <home> <epoch|owner>
  local path content version epoch owner
  path=$(fm_secondmate_retirement_epoch_path "$1") || return 1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'none\n'
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  content=$(cat "$path") || return 1
  version=$(printf '%s\n' "$content" | sed -n 's/^version=//p')
  epoch=$(printf '%s\n' "$content" | sed -n 's/^epoch=//p')
  owner=$(printf '%s\n' "$content" | sed -n 's/^owner=//p')
  [ "$(printf '%s\n' "$content" | grep -c '^version=')" -eq 1 ] \
    && [ "$(printf '%s\n' "$content" | grep -c '^epoch=')" -eq 1 ] \
    && [ "$(printf '%s\n' "$content" | grep -c '^owner=')" -eq 1 ] \
    && [ "$version" = 1 ] && [ -n "$owner" ] || return 1
  [ "${#epoch}" -eq 32 ] || return 1
  case "$epoch" in *[!A-Fa-f0-9]*) return 1 ;; esac
  case "$2" in
    epoch) printf '%s\n' "$epoch" ;;
    owner) printf '%s\n' "$owner" ;;
    *) return 1 ;;
  esac
}

fm_secondmate_retirement_epoch_read() { fm_secondmate_retirement_epoch_field "$1" epoch; }

fm_secondmate_retirement_epoch_owner() { fm_secondmate_retirement_epoch_field "$1" owner; }

fm_secondmate_retirement_epoch_advance_locked() {  # <home> <owner>
  local home=$1 owner=$2 path tmp epoch
  path=$(fm_secondmate_retirement_epoch_path "$home") || return 1
  epoch=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  [ "${#epoch}" -eq 32 ] || return 1
  case "$epoch" in *[!a-f0-9]*) return 1 ;; esac
  tmp="$path.tmp.${BASHPID:-$$}"
  printf 'version=1\nepoch=%s\nowner=%s\n' "$epoch" "$owner" > "$tmp" || return 1
  mv -f -- "$tmp" "$path" || {
    rm -f -- "$tmp"
    return 1
  }
}

fm_secondmate_retirement_marker_path() { printf '%s/.secondmate-retiring\n' "$1"; }

fm_secondmate_spawn_task_lock_acquire() {  # <home> <state> <task-lock>
  local home=$1 state=$2 task_lock=$3 admission marker epoch_path epoch current_epoch epoch_owner held_pid home_marker rc
  home_marker="$home/.fm-secondmate-home"
  epoch_path=$(fm_secondmate_retirement_epoch_path "$home") || return 1
  if [ ! -e "$home_marker" ] && [ ! -L "$home_marker" ] \
    && [ ! -e "$epoch_path" ] && [ ! -L "$epoch_path" ]; then
    fm_lock_try_acquire "$task_lock"
    return $?
  fi
  admission=$(fm_secondmate_retirement_lock_path "$home") || return 1
  epoch=$(fm_secondmate_retirement_epoch_read "$home") || return 2
  while ! fm_lock_try_acquire "$admission"; do
    held_pid=${FM_LOCK_HELD_PID:-}
    epoch_owner=$(fm_secondmate_retirement_epoch_owner "$home") || return 2
    case "$epoch_owner" in
      "$held_pid".*) [ -n "$held_pid" ] && return 2 ;;
    esac
    sleep 0.1
  done
  current_epoch=$(fm_secondmate_retirement_epoch_read "$home") || {
    fm_lock_release "$admission" || true
    return 2
  }
  if [ "$current_epoch" != "$epoch" ]; then
    fm_lock_release "$admission" || true
    return 2
  fi
  if [ -e "$home_marker" ] || [ -L "$home_marker" ]; then
    if [ ! -f "$home_marker" ] || [ -L "$home_marker" ] || [ ! -d "$state" ]; then
      fm_lock_release "$admission" || true
      return 2
    fi
    marker=$(fm_secondmate_retirement_marker_path "$state") || {
      fm_lock_release "$admission" || true
      return 1
    }
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      fm_lock_release "$admission" || true
      return 2
    fi
  fi
  rc=0
  fm_lock_try_acquire "$task_lock" || rc=$?
  fm_lock_release "$admission" || true
  return "$rc"
}

fm_secondmate_retirement_mark_locked() {  # <state> <owner>
  local state=$1 owner=$2 marker tmp
  # shellcheck disable=SC2034 # Output flag consumed by the sourcing teardown owner.
  FM_SECONDMATE_RETIREMENT_MARKER_CREATED=0
  marker=$(fm_secondmate_retirement_marker_path "$state") || return 1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ]
    return $?
  fi
  tmp="$marker.tmp.$$"
  printf 'version=1\nowner=%s\n' "$owner" > "$tmp" || return 1
  mv -f -- "$tmp" "$marker" || {
    rm -f -- "$tmp"
    return 1
  }
  # shellcheck disable=SC2034 # Output flag consumed by the sourcing teardown owner.
  FM_SECONDMATE_RETIREMENT_MARKER_CREATED=1
}

fm_secondmate_retirement_unmark_exact() {  # <state> <owner>
  local state=$1 owner=$2 marker actual expected
  marker=$(fm_secondmate_retirement_marker_path "$state") || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  actual=$(cat "$marker") || return 1
  expected=$(printf 'version=1\nowner=%s\n' "$owner")
  [ "$actual" = "$expected" ] || return 1
  rm -f -- "$marker"
}
