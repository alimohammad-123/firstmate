#!/usr/bin/env bash

fm_secondmate_retirement_lock_path() { printf '%s/.secondmate-retirement.lock\n' "$1"; }
fm_secondmate_retirement_marker_path() { printf '%s/.secondmate-retiring\n' "$1"; }

fm_secondmate_spawn_task_lock_acquire() {  # <home> <state> <task-lock>
  local home=$1 state=$2 task_lock=$3 admission marker rc
  if [ ! -e "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ]; then
    fm_lock_try_acquire "$task_lock"
    return $?
  fi
  admission=$(fm_secondmate_retirement_lock_path "$state") || return 1
  marker=$(fm_secondmate_retirement_marker_path "$state") || return 1
  while ! fm_lock_try_acquire "$admission"; do
    if [ -e "$marker" ] || [ -L "$marker" ] || [ ! -d "$state" ]; then
      return 2
    fi
    sleep 0.1
  done
  if [ -e "$marker" ] || [ -L "$marker" ]; then
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
