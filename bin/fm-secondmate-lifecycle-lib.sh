#!/usr/bin/env bash
# Shared secondmate-home admission and retirement lifecycle contract.
#
# Source this file only after bin/fm-wake-lib.sh has provided
# fm_lock_try_acquire and fm_lock_release.
# The admission lock lives beside the canonical home rather than inside it and
# is keyed by the canonical home path, so teardown can retain it while the home
# itself is returned or removed.
# Spawn acquires the home admission lock before its per-task lifecycle lock;
# teardown acquires the same home lock before retaining child lifecycle locks.
# fm_secondmate_spawn_task_lock_acquire returns 0 with the task lock held, 1
# when the task lock is contended or identity cannot be resolved, and 2 when
# retirement or a changed home generation requires the launch to refuse.
# A retirement marker is created only while admission is held, records its
# exact creating owner, is removed only by that owner before destructive
# progress, and is retained after ambiguous destructive progress.

fm_secondmate_canonical_home() {  # <home>
  local home=$1 canonical
  canonical=$(CDPATH='' cd -P -- "$home" 2>/dev/null && pwd -P) || return 1
  case "$canonical" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$canonical"
}

fm_secondmate_home_generation() {  # <home>
  local home=$1 canonical marker file_id
  canonical=$(fm_secondmate_canonical_home "$home") || return 1
  marker="$canonical/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    file_id=$(stat -f '%d:%i' "$marker" 2>/dev/null) || return 1
  else
    file_id=$(stat -c '%d:%i' "$marker" 2>/dev/null) || return 1
  fi
  case "$file_id" in ''|*[!0-9:]*) return 1 ;; esac
  printf '%s\t%s\n' "$canonical" "$file_id"
}

fm_secondmate_retirement_lock_path() {  # <home>
  local canonical parent digest
  canonical=$(fm_secondmate_canonical_home "$1") || return 1
  parent=${canonical%/*}
  [ -n "$parent" ] || parent=/
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$canonical" | sha256sum | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$digest" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  printf '%s/.fm-secondmate-retirement-%s.lock\n' "$parent" "$digest"
}

fm_secondmate_retirement_marker_path() { printf '%s/.secondmate-retiring\n' "$1"; }

fm_secondmate_spawn_task_lock_acquire() {  # <home> <state> <task-lock>
  local home=$1 state=$2 task_lock=$3 admission marker generation current_generation rc
  if [ ! -e "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ]; then
    fm_lock_try_acquire "$task_lock"
    return $?
  fi
  generation=$(fm_secondmate_home_generation "$home") || return 2
  admission=$(fm_secondmate_retirement_lock_path "$home") || return 1
  marker=$(fm_secondmate_retirement_marker_path "$state") || return 1
  while ! fm_lock_try_acquire "$admission"; do
    if [ -e "$marker" ] || [ -L "$marker" ] || [ ! -d "$state" ]; then
      return 2
    fi
    current_generation=$(fm_secondmate_home_generation "$home") || return 2
    [ "$current_generation" = "$generation" ] || return 2
    sleep 0.1
  done
  current_generation=$(fm_secondmate_home_generation "$home") || {
    fm_lock_release "$admission" || true
    return 2
  }
  if [ "$current_generation" != "$generation" ] \
    || [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_lock_release "$admission" || true
    return 2
  fi
  rc=0
  fm_lock_try_acquire "$task_lock" || rc=$?
  fm_lock_release "$admission" || true
  return "$rc"
}

fm_secondmate_retirement_mark_locked() {  # <state> <owner>
  local state=$1 owner=$2 marker tmp
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
