#!/usr/bin/env bash
# Behavioral regression for ordinary task Treehouse leases.
# Drives the real fm-spawn.sh and fm-teardown.sh through a stateful fake
# Treehouse CLI and fake tmux endpoint. The fake models only documented public
# command surfaces: lease JSON, status JSON, and conditional return.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-task-lease)
WORLD="$TMP_ROOT/world"
HOME_A="$WORLD/home-a"
HOME_B="$WORLD/home-b"
PROJECT="$WORLD/project"
WT1="$WORLD/wt-1"
WT2="$WORLD/wt-2"
WT3="$WORLD/wt-3"
WT4="$WORLD/wt-4"
FAKEBIN=$(fm_fakebin "$WORLD")
TREEHOUSE_STATE="$WORLD/treehouse-leases.tsv"
TREEHOUSE_POOL="$WORLD/treehouse-pool.txt"
TREEHOUSE_COUNTER="$WORLD/treehouse-counter"
TREEHOUSE_LOG="$WORLD/treehouse.log"
TMUX_LOG="$WORLD/tmux.log"
export TREEHOUSE_STATE TREEHOUSE_POOL TREEHOUSE_COUNTER TREEHOUSE_LOG TMUX_LOG

mkdir -p "$HOME_A/data" "$HOME_A/state" "$HOME_A/config" "$HOME_A/projects" \
  "$HOME_B/data" "$HOME_B/state" "$HOME_B/config" "$HOME_B/projects"
HOME_A_REAL=$(cd "$HOME_A" && pwd -P)
HOME_B_REAL=$(cd "$HOME_B" && pwd -P)
fm_git_worktree "$PROJECT" "$WT1" lease-wt-1
fm_git_worktree "$PROJECT" "$WT2" lease-wt-2
fm_git_worktree "$PROJECT" "$WT3" lease-wt-3
fm_git_worktree "$PROJECT" "$WT4" lease-wt-4
printf '%s\n' "$WT1" "$WT2" "$WT3" "$WT4" > "$TREEHOUSE_POOL"
: > "$TREEHOUSE_STATE"
: > "$TREEHOUSE_LOG"
: > "$TMUX_LOG"
printf '0\n' > "$TREEHOUSE_COUNTER"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TREEHOUSE_LOG"
case "${1:-}" in
  get)
    shift
    holder=
    lease=0
    json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease) lease=1 ;;
        --json) json=1 ;;
        --lease-holder) shift; holder=${1:-} ;;
      esac
      shift
    done
    [ "$lease" -eq 1 ] && [ "$json" -eq 1 ] && [ -n "$holder" ] || exit 2
    selected=
    while IFS= read -r candidate; do
      grep -Fq "${candidate}"$'\t' "$TREEHOUSE_STATE" 2>/dev/null && continue
      selected=$candidate
      break
    done < "$TREEHOUSE_POOL"
    [ -n "$selected" ] || { echo 'all worktrees held' >&2; exit 1; }
    counter=$(cat "$TREEHOUSE_COUNTER")
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$TREEHOUSE_COUNTER"
    lease_id="lease-$counter"
    printf '%s\t%s\t%s\n' "$selected" "$lease_id" "$holder" >> "$TREEHOUSE_STATE"
    if [ "${FM_FAKE_GET_MALFORMED:-0}" = 1 ]; then
      printf '{"path":'
      exit 0
    fi
    jq -n --arg path "$selected" --arg lease_id "$lease_id" --arg lease_holder "$holder" \
      '{path:$path,lease_id:$lease_id,lease_holder:$lease_holder,leased_at:"2026-08-06T00:00:00Z"}'
    ;;
  status)
    [ "${2:-}" = --json ] || exit 2
    printf 'status-cwd %s\n' "$PWD" >> "$TREEHOUSE_LOG"
    jq -Rn '
      [inputs | select(length > 0) | split("\t")
        | {path:.[0],status:"leased",lease_id:.[1],lease_holder:.[2]}]
    ' < "$TREEHOUSE_STATE"
    ;;
  return)
    printf 'return-cwd %s\n' "$PWD" >> "$TREEHOUSE_LOG"
    shift
    [ "${1:-}" = --force ] || exit 2
    shift
    path=${1:-}
    shift
    expected_id=
    expected_holder=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --if-lease-id) shift; expected_id=${1:-} ;;
        --if-lease-holder) shift; expected_holder=${1:-} ;;
      esac
      shift
    done
    [ -n "$path" ] && [ -n "$expected_id" ] && [ -n "$expected_holder" ] || exit 2
    [ "${FM_FAKE_RETURN_FAIL_ID:-}" != "$expected_id" ] || {
      echo 'simulated conditional return failure' >&2
      exit 1
    }
    match=$(awk -F '\t' -v p="$path" -v i="$expected_id" -v h="$expected_holder" \
      '$1 == p && $2 == i && $3 == h { print NR }' "$TREEHOUSE_STATE")
    [ -n "$match" ] || { echo 'lease precondition failed' >&2; exit 1; }
    awk -F '\t' -v p="$path" -v i="$expected_id" -v h="$expected_holder" \
      '!( $1 == p && $2 == i && $3 == h )' "$TREEHOUSE_STATE" > "$TREEHOUSE_STATE.tmp"
    mv "$TREEHOUSE_STATE.tmp" "$TREEHOUSE_STATE"
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/treehouse"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{pane_current_command}"*) printf 'zsh\n'; exit 0 ;;
  *"#{pane_tty}"*) printf '/dev/null\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|set-window-option|send-keys|kill-window) exit 0 ;;
  new-window)
    [ "${FM_FAKE_TMUX_CREATE_FAIL:-0}" != 1 ] || exit 1
    printf '@lease-window\n'
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" no-mistakes gh gh-axi lsof ps

make_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf 'lease test for %s\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
}

run_spawn() {
  local home=$1 id=$2 expected_path=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$expected_path" PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJECT" "sh -c 'true'" --mode no-mistakes --yolo off "$@"
}

run_teardown_force() {
  local home=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEARDOWN_GUARD_DONE=1 FM_TREEHOUSE_RETURN_LOCK_RETRIES=0 \
    PATH="$FAKEBIN:$PATH" "$TEARDOWN" "$id" --force
}

make_brief "$HOME_A" alpha
run_spawn "$HOME_A" alpha "$WT1" >/dev/null || fail 'first task spawn failed'
META_A="$HOME_A/state/alpha.meta"
RECORDED_PROJECT=$(sed -n 's/^project=//p' "$META_A")
assert_grep "worktree=$WT1" "$META_A" 'first task did not record the allocated lease path'
assert_grep 'treehouse_lease_id=lease-1' "$META_A" 'first task did not record immutable lease identity'
assert_grep "treehouse_lease_holder=firstmate-task:$HOME_A_REAL:alpha" "$META_A" \
  'first task holder was not scoped to its absolute Firstmate home'
assert_grep 'get --lease --json --lease-holder' "$TREEHOUSE_LOG" \
  'spawn did not use Treehouse durable JSON acquisition'
assert_grep "cd -- '$WT1'" "$TMUX_LOG" 'endpoint did not explicitly enter the returned lease path'
pass 'spawn acquires and records one home-scoped durable Treehouse lease before launch'

get_count_before=$(grep -c '^get ' "$TREEHOUSE_LOG")
run_spawn "$HOME_A" alpha "$WT1" >/dev/null || fail 'same-task endpoint restart failed'
get_count_after=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$get_count_after" -eq "$get_count_before" ] || fail 'endpoint restart allocated a second Treehouse lease'
grep -Fq "$WT1"$'\tlease-1\t' "$TREEHOUSE_STATE" \
  || fail 'simulated owner/backend restart made the original lease reusable'
assert_grep "status-cwd $RECORDED_PROJECT" "$TREEHOUSE_LOG" \
  "lease verification did not run from the owning project clone; log: $(cat "$TREEHOUSE_LOG")"
pass 'endpoint or owner restart reuses the exact recorded lease without process identity'

make_brief "$HOME_A" beta
run_spawn "$HOME_A" beta "$WT2" >/dev/null || fail 'later task spawn failed'
assert_grep "worktree=$WT2" "$HOME_A/state/beta.meta" \
  'later allocation selected the already-held first worktree'
pass 'a later allocation cannot select a worktree held by an earlier task lease'

make_brief "$HOME_B" alpha
run_spawn "$HOME_B" alpha "$WT3" >/dev/null || fail 'same-id other-home spawn failed'
assert_grep "treehouse_lease_holder=firstmate-task:$HOME_B_REAL:alpha" "$HOME_B/state/alpha.meta" \
  'same task id in another home did not receive a distinct holder'
[ "$(sed -n 's/^treehouse_lease_id=//p' "$HOME_B/state/alpha.meta")" != \
  "$(sed -n 's/^treehouse_lease_id=//p' "$META_A")" ] \
  || fail 'same task id in two homes shared one lease identity'
pass 'two homes using the same task id receive non-colliding lease identities and holders'

cp "$META_A" "$META_A.correct"
printf '%s\n' 'treehouse_lease_id=wrong-lease' >> "$META_A.tmp"
grep -v '^treehouse_lease_id=' "$META_A.correct" >> "$META_A.tmp"
mv "$META_A.tmp" "$META_A"
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if run_teardown_force "$HOME_A" alpha >/dev/null 2>&1; then
  fail 'teardown accepted a wrong lease identity'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] || fail 'wrong identity reached Treehouse return'
[ -f "$META_A" ] || fail 'wrong identity removed task metadata'
grep -Fq "$WT1"$'\tlease-1\t' "$TREEHOUSE_STATE" || fail 'wrong identity released the real lease'
mv "$META_A.correct" "$META_A"
pass 'wrong lease identity refuses before any conditional return or task-record cleanup'

teardown_out=$(run_teardown_force "$HOME_A" alpha 2>&1) \
  || fail "correct identity teardown failed\n$teardown_out\n--- meta ---\n$(cat "$META_A")"
[ ! -f "$META_A" ] || fail 'correct identity teardown retained task metadata'
if grep -Fq "$WT1"$'\tlease-1\t' "$TREEHOUSE_STATE"; then
  fail 'correct identity teardown did not return its lease'
fi
assert_grep "return --force $WT1 --if-lease-id lease-1 --if-lease-holder firstmate-task:$HOME_A_REAL:alpha" \
  "$TREEHOUSE_LOG" 'teardown did not use both conditional lease predicates'
assert_grep "return-cwd $RECORDED_PROJECT" "$TREEHOUSE_LOG" \
  'conditional return did not execute in the owning project repository'
pass 'correct path, identity, and holder conditionally return the exact task lease'

make_brief "$HOME_A" legacy
fm_write_meta "$HOME_A/state/legacy.meta" \
  "window=firstmate:fm-legacy" "endpoint_task_id=legacy" \
  "worktree=$WT4" "project=$PROJECT" "harness=sh" "kind=ship" \
  "mode=no-mistakes" "yolo=off"
get_count_before=$(grep -c '^get ' "$TREEHOUSE_LOG")
if run_spawn "$HOME_A" legacy "$WT4" >/dev/null 2>&1; then
  fail 'spawn allocated around legacy task metadata with no lease identity'
fi
get_count_after=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$get_count_after" -eq "$get_count_before" ] || fail 'legacy recovery allocated a replacement copy'
if run_teardown_force "$HOME_A" legacy >/dev/null 2>&1; then
  fail 'teardown released a legacy task with no lease identity'
fi
assert_present "$HOME_A/state/legacy.meta" 'legacy compatibility refusal erased task metadata'
pass 'legacy in-flight tasks are preserved with actionable recovery instead of guessed allocation or release'

make_brief "$HOME_A" rollback
if FM_FAKE_TMUX_CREATE_FAIL=1 run_spawn "$HOME_A" rollback "$WT1" >/dev/null 2>&1; then
  fail 'spawn unexpectedly succeeded after simulated endpoint creation failure'
fi
if grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE"; then
  fail 'spawn failure retained its newly acquired lease despite successful rollback'
fi
grep -Fq "$WT2"$'\tlease-2\t' "$TREEHOUSE_STATE" \
  || fail 'spawn failure rolled back another task lease'
grep -Fq "$WT3"$'\tlease-3\t' "$TREEHOUSE_STATE" \
  || fail 'spawn failure rolled back another home lease'
assert_grep "return --force $WT1 --if-lease-id lease-4 --if-lease-holder firstmate-task:$HOME_A_REAL:rollback" \
  "$TREEHOUSE_LOG" 'spawn failure did not roll back only the exact acquired lease'
pass 'pre-publication spawn failure rolls back only its own exact lease'

make_brief "$HOME_A" rollback-held
if FM_FAKE_TMUX_CREATE_FAIL=1 FM_FAKE_RETURN_FAIL_ID=lease-5 \
  run_spawn "$HOME_A" rollback-held "$WT1" >/dev/null 2>&1; then
  fail 'spawn unexpectedly succeeded when exact rollback was configured to fail'
fi
HELD_META="$HOME_A/state/rollback-held.meta"
HELD_RECEIPT="$HOME_A/state/.rollback-held.treehouse-lease-acquire.json"
assert_present "$HELD_META" 'failed rollback did not preserve recoverable lease metadata'
assert_present "$HELD_RECEIPT" 'failed rollback did not preserve the exact acquisition receipt'
assert_grep 'treehouse_lease_id=lease-5' "$HELD_META" 'failed rollback metadata lost the lease id'
assert_grep 'treehouse_lease_recovery=spawn-rollback-failed' "$HELD_META" \
  'failed rollback metadata did not identify the recovery condition'
grep -Fq "$WT1"$'\tlease-5\t' "$TREEHOUSE_STATE" \
  || fail 'failed rollback hid the still-held Treehouse lease'
pass 'failed exact rollback preserves both lease identity and raw acquisition evidence'

# The shared lease seam runs before every Treehouse-backed endpoint adapter.
# Fail each non-tmux adapter at its first fake CLI call and prove its freshly
# acquired lease is still exact and conditionally rolled back. These are fake
# command surfaces only; no live backend process or Treehouse state is touched.
for backend in herdr zellij cmux; do
  cat > "$FAKEBIN/$backend" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$FAKEBIN/$backend"
  id="lease-$backend"
  make_brief "$HOME_A" "$id"
  get_count_before=$(grep -c '^get ' "$TREEHOUSE_LOG")
  return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
  if run_spawn "$HOME_A" "$id" "$WT4" --backend "$backend" >/dev/null 2>&1; then
    fail "$backend spawn unexpectedly succeeded with a failing fake endpoint adapter"
  fi
  get_count_after=$(grep -c '^get ' "$TREEHOUSE_LOG")
  return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
  [ "$get_count_after" -eq $((get_count_before + 1)) ] \
    || fail "$backend did not acquire through the shared durable lease seam"
  [ "$return_count_after" -eq $((return_count_before + 1)) ] \
    || fail "$backend pre-publication failure did not conditionally roll back its lease"
  if grep -Fq "$WT4"$'\t' "$TREEHOUSE_STATE"; then
    fail "$backend endpoint failure left its freshly acquired lease reusable only by accident"
  fi
done
pass 'Herdr, Zellij, and cmux share the durable pre-endpoint lease and exact rollback guarantee'

make_brief "$HOME_A" ambiguous-acquire
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if FM_FAKE_GET_MALFORMED=1 run_spawn "$HOME_A" ambiguous-acquire "$WT4" >/dev/null 2>&1; then
  fail 'spawn accepted an unreadable Treehouse acquisition identity'
fi
AMBIGUOUS_RECEIPT="$HOME_A/state/.ambiguous-acquire.treehouse-lease-acquire.json"
assert_present "$AMBIGUOUS_RECEIPT" 'ambiguous acquisition did not preserve the raw Treehouse receipt'
assert_absent "$HOME_A/state/ambiguous-acquire.meta" \
  'ambiguous acquisition invented recoverable task metadata without an exact identity'
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'ambiguous acquisition guessed a conditional return without an exact identity'
grep -Fq "$WT4"$'\tlease-9\t' "$TREEHOUSE_STATE" \
  || fail 'ambiguous acquisition hid that the fake Treehouse copy remained held'
pass 'ambiguous acquisition preserves raw evidence and never guesses a lease release'

echo '# all fm-treehouse-task-lease tests passed'
