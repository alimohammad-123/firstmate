#!/usr/bin/env bash
# Shared durable Treehouse task-lease identity contract.
#
# Ordinary ship and scout tasks on tmux, Herdr, Zellij, and cmux acquire one
# process-independent Treehouse lease through:
#   treehouse get --lease --json --lease-holder <home-scoped-holder>
# The documented path, lease_id, and lease_holder fields are the only allocation
# fields parsed. Callers record the exact path as worktree= and the other two as
# treehouse_lease_id= and treehouse_lease_holder= in task metadata.
#
# Recovery verifies that exact triple against `treehouse status --json` before a
# replacement endpoint can enter the recorded path. Cleanup uses both supported
# conditional-return predicates against that exact path:
#   treehouse return --force <path> --if-lease-id <id> --if-lease-holder <holder>
# Treehouse validates those conditions and performs reset/release while holding
# its state lock. Missing, duplicate, malformed, legacy, or mismatched identity
# is never guessed or released by path alone.
#
# The persistent secondmate-home lease path remains owned by fm-home-seed.sh and
# fm-teardown.sh and deliberately does not use this ordinary-task contract.
# Orca owns its own worktree identity and never calls these functions.
#
# Functions publish results through FM_TREEHOUSE_LEASE_PATH,
# FM_TREEHOUSE_LEASE_ID, and FM_TREEHOUSE_LEASE_HOLDER. Acquisition also sets
# FM_TREEHOUSE_LEASE_ACQUISITION_ARMED=1 after creating this invocation's
# receipt and before invoking Treehouse; callers retain that state until exact
# rollback or complete metadata publication.

fm_treehouse_lease_value_line_safe() {  # <value>
  local value=${1:-}
  [ -n "$value" ] || return 1
  case "$value" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

fm_treehouse_lease_holder_for_task() {  # <home> <task-id>
  local home=$1 task_id=$2 holder
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  holder="firstmate-task:$home:$task_id"
  fm_treehouse_lease_value_line_safe "$holder" || return 1
  printf '%s\n' "$holder"
}

fm_treehouse_lease_parse_receipt() {  # <receipt-json> <expected-holder>
  local receipt=$1 expected_holder=$2
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  FM_TREEHOUSE_LEASE_PATH=$(jq -er '.path | strings | select(length > 0)' "$receipt" 2>/dev/null) || return 1
  FM_TREEHOUSE_LEASE_ID=$(jq -er '.lease_id | strings | select(length > 0)' "$receipt" 2>/dev/null) || return 1
  FM_TREEHOUSE_LEASE_HOLDER=$(jq -er '.lease_holder | strings | select(length > 0)' "$receipt" 2>/dev/null) || return 1

  fm_treehouse_lease_value_line_safe "$FM_TREEHOUSE_LEASE_PATH" || return 1
  fm_treehouse_lease_value_line_safe "$FM_TREEHOUSE_LEASE_ID" || return 1
  fm_treehouse_lease_value_line_safe "$FM_TREEHOUSE_LEASE_HOLDER" || return 1
  [ "$FM_TREEHOUSE_LEASE_HOLDER" = "$expected_holder" ] || return 1
  case "$FM_TREEHOUSE_LEASE_PATH" in
    /*) ;;
    *) return 1 ;;
  esac
  return 0
}

fm_treehouse_lease_receipt_matches_exact() {  # <receipt-json> <path> <lease-id> <holder>
  local receipt=$1 path=$2 lease_id=$3 holder=$4
  fm_treehouse_lease_parse_receipt "$receipt" "$holder" || return 1
  [ "$FM_TREEHOUSE_LEASE_PATH" = "$path" ] \
    && [ "$FM_TREEHOUSE_LEASE_ID" = "$lease_id" ] \
    && [ "$FM_TREEHOUSE_LEASE_HOLDER" = "$holder" ]
}

fm_treehouse_lease_acquire() {  # <project-dir> <holder> <receipt-json>
  local project=$1 holder=$2 receipt=$3 receipt_dir
  fm_treehouse_lease_value_line_safe "$project" || return 1
  fm_treehouse_lease_value_line_safe "$holder" || return 1
  receipt_dir=$(dirname "$receipt")
  [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || return 1
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    printf 'error: prior Treehouse lease acquisition evidence exists at %s; reconcile it before retrying spawn\n' "$receipt" >&2
    return 1
  fi
  if ! (umask 077; : > "$receipt"); then
    printf 'error: cannot create Treehouse lease acquisition receipt %s\n' "$receipt" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Output flag consumed by the sourcing spawn owner.
  FM_TREEHOUSE_LEASE_ACQUISITION_ARMED=1
  if ! (CDPATH='' cd -- "$project" && treehouse get --lease --json --lease-holder "$holder") > "$receipt"; then
    # A caller can still roll back safely when Treehouse reported a complete
    # identity before a later command failure. Partial or malformed output stays
    # only as evidence and is never converted into a guessed release.
    fm_treehouse_lease_parse_receipt "$receipt" "$holder" 2>/dev/null || true
    printf 'error: Treehouse durable lease acquisition failed; preserved its machine-readable output at %s\n' "$receipt" >&2
    return 1
  fi
  if ! fm_treehouse_lease_parse_receipt "$receipt" "$holder"; then
    printf 'error: Treehouse reported an unreadable or mismatched durable lease identity; preserved the exact acquisition output at %s and will not guess a release\n' "$receipt" >&2
    return 1
  fi
  return 0
}

fm_treehouse_lease_meta_read_exact() {  # <meta>
  local meta=$1 key count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  for key in worktree treehouse_lease_id treehouse_lease_holder; do
    count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
    [ "$count" = 1 ] || return 1
  done
  FM_TREEHOUSE_LEASE_PATH=$(grep '^worktree=' "$meta" | cut -d= -f2-)
  FM_TREEHOUSE_LEASE_ID=$(grep '^treehouse_lease_id=' "$meta" | cut -d= -f2-)
  FM_TREEHOUSE_LEASE_HOLDER=$(grep '^treehouse_lease_holder=' "$meta" | cut -d= -f2-)
  fm_treehouse_lease_value_line_safe "$FM_TREEHOUSE_LEASE_PATH" || return 1
  fm_treehouse_lease_value_line_safe "$FM_TREEHOUSE_LEASE_ID" || return 1
  fm_treehouse_lease_value_line_safe "$FM_TREEHOUSE_LEASE_HOLDER" || return 1
  case "$FM_TREEHOUSE_LEASE_PATH" in
    /*) ;;
    *) return 1 ;;
  esac
  return 0
}

fm_treehouse_lease_verify_current() {  # <path> <lease-id> <holder> <repo-inspection-dir>
  local path=$1 lease_id=$2 holder=$3 repo_dir=$4 status_json
  fm_treehouse_lease_value_line_safe "$path" || return 1
  fm_treehouse_lease_value_line_safe "$lease_id" || return 1
  fm_treehouse_lease_value_line_safe "$holder" || return 1
  fm_treehouse_lease_value_line_safe "$repo_dir" || return 1
  [ -d "$path" ] && [ -d "$repo_dir" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Inspect from the task's project clone, not from the leased path itself:
  # Treehouse reports the invocation's own worktree as "you're here", which
  # would hide the lease status even when the immutable identity still matches.
  status_json=$(CDPATH='' cd -- "$repo_dir" && treehouse status --json) || return 1
  printf '%s\n' "$status_json" | jq -e \
    --arg path "$path" --arg lease_id "$lease_id" --arg holder "$holder" '
      type == "array"
      and ([.[] | select(
        type == "object"
        and .path == $path
        and .status == "leased"
        and .lease_id == $lease_id
        and .lease_holder == $holder
      )] | length) == 1
      and ([.[] | select(type == "object" and .path == $path)] | length) == 1
      and ([.[] | select(type == "object" and .lease_id == $lease_id)] | length) == 1
    ' >/dev/null 2>&1
}

fm_treehouse_lease_return_exact() {  # <path> <lease-id> <holder> <repo-dir>
  local path=$1 lease_id=$2 holder=$3 repo_dir=$4
  fm_treehouse_lease_value_line_safe "$path" || return 1
  fm_treehouse_lease_value_line_safe "$lease_id" || return 1
  fm_treehouse_lease_value_line_safe "$holder" || return 1
  fm_treehouse_lease_value_line_safe "$repo_dir" || return 1
  [ -d "$repo_dir" ] || return 1
  ( CDPATH='' cd -- "$repo_dir" \
    && treehouse return --force "$path" \
      --if-lease-id "$lease_id" \
      --if-lease-holder "$holder" )
}
