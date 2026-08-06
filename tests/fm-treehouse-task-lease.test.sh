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
TMUX_WINDOWS="$WORLD/tmux-windows"
TMUX_COUNTER="$WORLD/tmux-counter"
ENDPOINT_STATE="$WORLD/backend-endpoints.tsv"
ENDPOINT_COUNTER="$WORLD/backend-endpoint-counter"
CMUX_FOCUS_MARKER="$WORLD/cmux-focus-moved"
EVENT_LOG="$WORLD/events.log"
FM_REAL_MV=$(command -v mv)
export TREEHOUSE_STATE TREEHOUSE_POOL TREEHOUSE_COUNTER TREEHOUSE_LOG TMUX_LOG TMUX_WINDOWS TMUX_COUNTER ENDPOINT_STATE ENDPOINT_COUNTER CMUX_FOCUS_MARKER EVENT_LOG FM_REAL_MV

mkdir -p "$HOME_A/data" "$HOME_A/state" "$HOME_A/config" "$HOME_A/projects" \
  "$HOME_B/data" "$HOME_B/state" "$HOME_B/config" "$HOME_B/projects"
printf 'off\n' > "$HOME_A/config/herdr-presentation-spaces"
printf 'off\n' > "$HOME_B/config/herdr-presentation-spaces"
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
: > "$TMUX_WINDOWS"
: > "$ENDPOINT_STATE"
: > "$EVENT_LOG"
printf '0\n' > "$TREEHOUSE_COUNTER"
printf '0\n' > "$TMUX_COUNTER"
printf '0\n' > "$ENDPOINT_COUNTER"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TREEHOUSE_LOG"
printf 'treehouse %s\n' "$*" >> "$EVENT_LOG"
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
printf 'tmux %s\n' "$*" >> "$EVENT_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    if [ "${FM_FAKE_TMUX_RENAME_BEFORE_FAILURE:-0}" = 1 ]; then
      target=
      prev=
      for arg in "$@"; do [ "$prev" != -t ] || target=$arg; prev=$arg; done
      awk -F '\t' -v target="$target" 'BEGIN {OFS="\t"} {if ($1 == target) $2="renamed-after-create"; print}' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
      mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
    fi
    [ "${FM_FAKE_CURRENT_PATH_FAIL:-0}" != 1 ] && printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{pane_current_command}"*) printf 'zsh\n'; exit 0 ;;
  *"#{pane_tty}"*) printf '/dev/null\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    case "$*" in
      *'#{window_id}'*) cut -f1 "$TMUX_WINDOWS" ;;
      *) cut -f2 "$TMUX_WINDOWS" ;;
    esac
    exit 0
    ;;
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
  kill-window)
    [ "${FM_FAKE_TMUX_KILL_FAIL:-0}" != 1 ] || exit 0
    target=${3:-}
    case "$target" in
      @*) awk -F '\t' -v id="$target" '$1 != id' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp" ;;
      *) window=${target##*:=}; awk -F '\t' -v name="$window" '$2 != name' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp" ;;
    esac
    mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
    exit 0
    ;;
  new-window)
    [ "${FM_FAKE_TMUX_CREATE_FAIL:-0}" != 1 ] || exit 1
    name=
    while [ "$#" -gt 0 ]; do
      [ "$1" != -n ] || { shift; name=${1:-}; }
      shift
    done
    counter=$(cat "$TMUX_COUNTER")
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$TMUX_COUNTER"
    wid="@lease-window-$counter"
    [ -z "$name" ] || printf '%s\t%s\n' "$wid" "$name" >> "$TMUX_WINDOWS"
    printf '%s\n' "$wid"
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf 'herdr %s\n' "$*" >> "$EVENT_LOG"
case "$*" in
  'status --json'*) printf '{"client":{"protocol":14,"version":"0.7.5"},"server":{"running":true}}\n'; exit 0 ;;
  *'status --json'*) printf '{"server":{"running":true}}\n'; exit 0 ;;
  *'session list --json'*)
    jq -n --arg socket "${ENDPOINT_STATE%/*}/herdr.sock" '{sessions:[{name:"default",running:true,socket_path:$socket}]}'
    exit 0
    ;;
  *'workspace list'*) printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n'; exit 0 ;;
  *'tab list'*)
    jq -Rn '
      [inputs | select(length > 0) | split("\t") | select(.[0] == "herdr")
        | {tab_id:.[1],label:.[3]}] | {result:{tabs:.}}
    ' < "$ENDPOINT_STATE" 2>/dev/null || printf '{"result":{"tabs":[]}}\n'
    exit 0
    ;;
  *'tab create'*)
    counter=$(cat "$ENDPOINT_COUNTER"); counter=$((counter + 1)); printf '%s\n' "$counter" > "$ENDPOINT_COUNTER"
    tab="t$counter"; pane="w1:p$counter"; label=
    prev=
    for arg in "$@"; do [ "$prev" != --label ] || label=$arg; prev=$arg; done
    printf 'herdr\t%s\t%s\t%s\n' "$tab" "$pane" "$label" >> "$ENDPOINT_STATE"
    jq -n --arg tab "$tab" --arg pane "$pane" '{result:{tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
    exit 0
    ;;
  *'pane get'*)
    pane=
    prev=
    for arg in "$@"; do [ "$prev" != get ] || pane=$arg; prev=$arg; done
    row=$(awk -F '\t' -v pane="$pane" '$1 == "herdr" && $3 == pane {print; exit}' "$ENDPOINT_STATE")
    if [ -z "$row" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    else
      tab=$(printf '%s' "$row" | cut -f2)
      cwd=${FM_FAKE_PANE_PATH:-}
      [ "${FM_FAKE_CURRENT_PATH_FAIL:-0}" != 1 ] || cwd=
      jq -n --arg pane "$pane" --arg tab "$tab" --arg cwd "$cwd" \
        '{result:{pane:{pane_id:$pane,tab_id:$tab,workspace_id:"w1",foreground_cwd:$cwd,shell_pid:99999}}}'
    fi
    exit 0
    ;;
  *'pane close'*)
    pane=
    prev=
    for arg in "$@"; do [ "$prev" != close ] || pane=$arg; prev=$arg; done
    if [ "${FM_FAKE_HERDR_KILL_AMBIGUOUS:-0}" != 1 ]; then
      awk -F '\t' -v pane="$pane" '!($1 == "herdr" && $3 == pane)' "$ENDPOINT_STATE" > "$ENDPOINT_STATE.tmp"
      mv "$ENDPOINT_STATE.tmp" "$ENDPOINT_STATE"
    fi
    printf '{"result":{}}\n'
    exit 0
    ;;
  *'pane run'*|*'pane send-text'*|*'pane send-keys'*) printf '{"result":{}}\n'; exit 0 ;;
esac
printf '{"result":{}}\n'
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/zellij" <<'SH'
#!/usr/bin/env bash
set -u
printf 'zellij %s\n' "$*" >> "$EVENT_LOG"
case "${1:-}" in
  --version) printf 'zellij 0.44.0\n'; exit 0 ;;
  list-sessions) printf 'firstmate\n'; exit 0 ;;
esac
case "$*" in
  *'action list-tabs --json'*)
    awk -F '\t' '$1 == "zellij" {print $2 "\t" $4}' "$ENDPOINT_STATE" \
      | jq -Rn '[inputs | split("\t") | {tab_id:(.[0] | tonumber),name:.[1],active:false}]'
    exit 0
    ;;
  *'action list-panes --json'*)
    awk -F '\t' '$1 == "zellij" {print $2 "\t" $3}' "$ENDPOINT_STATE" \
      | jq -Rn '[inputs | split("\t") | {tab_id:(.[0] | tonumber),id:(.[1] | tonumber),is_plugin:false}]'
    exit 0
    ;;
  *'action new-tab '*)
    counter=$(cat "$ENDPOINT_COUNTER"); counter=$((counter + 1)); printf '%s\n' "$counter" > "$ENDPOINT_COUNTER"
    tab=$((counter + 100)); pane=$((counter + 200)); name=
    prev=
    for arg in "$@"; do [ "$prev" != --name ] || name=$arg; prev=$arg; done
    printf 'zellij\t%s\t%s\t%s\n' "$tab" "$pane" "$name" >> "$ENDPOINT_STATE"
    printf '%s\n' "$tab"
    exit 0
    ;;
  *'action dump-screen'*)
    if [ "${FM_FAKE_CURRENT_PATH_FAIL:-0}" != 1 ]; then
      printf '__FM_ZELLIJ_CWD_BEGIN__\n%s\n__FM_ZELLIJ_CWD_END__\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
  *'action close-tab-by-id '*)
    tab=
    prev=
    for arg in "$@"; do [ "$prev" != close-tab-by-id ] || tab=$arg; prev=$arg; done
    if [ "${FM_FAKE_ZELLIJ_KILL_AMBIGUOUS:-0}" != 1 ]; then
      awk -F '\t' -v tab="$tab" '!($1 == "zellij" && $2 == tab)' "$ENDPOINT_STATE" > "$ENDPOINT_STATE.tmp"
      mv "$ENDPOINT_STATE.tmp" "$ENDPOINT_STATE"
    fi
    exit 0
    ;;
  *'action paste '*|*'action send-keys '*) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/zellij"

cat > "$FAKEBIN/cmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'cmux %s\n' "$*" >> "$EVENT_LOG"
case "${1:-}" in
  version) printf 'cmux 0.64.17 (97) [abcdef1]\n'; exit 0 ;;
  ping) printf 'PONG\n'; exit 0 ;;
  list-windows)
    printf '[{"id":"window-1","workspace_count":0},{"id":"window-2","workspace_count":1}]\n'
    exit 0
    ;;
  workspace)
    if [ "${2:-}" = list ]; then
      window=
      prev=
      for arg in "$@"; do [ "$prev" != --window ] || window=$arg; prev=$arg; done
      if [ -z "$window" ] && [ "${FM_FAKE_CMUX_CURRENT_WINDOW_EMPTY:-0}" = 1 ] && [ -f "$CMUX_FOCUS_MARKER" ]; then
        printf '{"workspaces":[]}\n'
      else
        awk -F '\t' -v window="$window" '$1 == "cmux" && (window == "" || $5 == window) {print $2 "\t" $4}' "$ENDPOINT_STATE" \
          | jq -Rn '{workspaces:[inputs | split("\t") | {id:.[0],title:.[1]}]}'
      fi
      exit 0
    fi
    ;;
  new-workspace)
    counter=$(cat "$ENDPOINT_COUNTER"); counter=$((counter + 1)); printf '%s\n' "$counter" > "$ENDPOINT_COUNTER"
    ws=$(printf '00000000-0000-0000-0000-%012d' "$counter")
    sf=$(printf '11111111-1111-1111-1111-%012d' "$counter")
    name=default; window=window-2; prev=
    for arg in "$@"; do
      [ "$prev" != --name ] || name=$arg
      [ "$prev" != --window ] || window=$arg
      prev=$arg
    done
    printf 'cmux\t%s\t%s\t%s\t%s\n' "$ws" "$sf" "$name" "$window" >> "$ENDPOINT_STATE"
    printf '%s\n' "$ws"
    exit 0
    ;;
  list-panes)
    ws=
    prev=
    for arg in "$@"; do [ "$prev" != --workspace ] || ws=$arg; prev=$arg; done
    sf=$(awk -F '\t' -v ws="$ws" '$1 == "cmux" && $2 == ws {print $3; exit}' "$ENDPOINT_STATE")
    if [ -n "$sf" ]; then
      jq -n --arg sf "$sf" '{panes:[{selected_surface_id:$sf,surface_ids:[$sf]}]}'
    else
      printf '{"panes":[]}\n'
    fi
    exit 0
    ;;
  read-screen)
    if [ "${FM_FAKE_CURRENT_PATH_FAIL:-0}" = 1 ]; then
      : > "$CMUX_FOCUS_MARKER"
      printf '{"text":""}\n'
    else
      jq -n --arg path "${FM_FAKE_PANE_PATH:-}" '{text:("__FM_CMUX_CWD_BEGIN__\n" + $path + "\n__FM_CMUX_CWD_END__")}'
    fi
    exit 0
    ;;
  close-workspace)
    ws=
    prev=
    for arg in "$@"; do [ "$prev" != --workspace ] || ws=$arg; prev=$arg; done
    if [ "${FM_FAKE_CMUX_KILL_AMBIGUOUS:-0}" != 1 ]; then
      awk -F '\t' -v ws="$ws" '!($1 == "cmux" && $2 == ws)' "$ENDPOINT_STATE" > "$ENDPOINT_STATE.tmp"
      mv "$ENDPOINT_STATE.tmp" "$ENDPOINT_STATE"
    fi
    exit 0
    ;;
  send|send-key) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/cmux"

cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
set -u
dest=${!#}
"$FM_REAL_MV" "$@"
status=$?
if [ "$status" -eq 0 ] \
   && [ "${FM_FAKE_TERM_AFTER_META_PUBLISH:-0}" = 1 ] \
   && [ "$dest" = "${FM_STATE_OVERRIDE:-}/$FM_FAKE_PUBLISH_ID.meta" ]; then
  kill -TERM "$PPID"
fi
exit "$status"
SH
chmod +x "$FAKEBIN/mv"
fm_fake_exit0 "$FAKEBIN" no-mistakes gh gh-axi lsof ps sleep

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
    HERDR_ENV='' HERDR_PANE_ID='' HERDR_SOCKET_PATH='' HERDR_TAB_ID='' HERDR_WORKSPACE_ID='' \
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

run_backend_late_failure() {  # <backend> <home> <id> <expected-path> <ambiguous>
  local backend=$1 home=$2 id=$3 expected_path=$4 ambiguous=$5
  [ "$backend" != cmux ] || rm -f -- "$CMUX_FOCUS_MARKER"
  case "$backend:$ambiguous" in
    tmux:0) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_TMUX_RENAME_BEFORE_FAILURE=1 run_spawn "$home" "$id" "$expected_path" --backend tmux ;;
    tmux:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_TMUX_RENAME_BEFORE_FAILURE=1 FM_FAKE_TMUX_KILL_FAIL=1 run_spawn "$home" "$id" "$expected_path" --backend tmux ;;
    herdr:0) FM_FAKE_CURRENT_PATH_FAIL=1 run_spawn "$home" "$id" "$expected_path" --backend herdr ;;
    herdr:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_HERDR_KILL_AMBIGUOUS=1 run_spawn "$home" "$id" "$expected_path" --backend herdr ;;
    zellij:0) FM_FAKE_CURRENT_PATH_FAIL=1 run_spawn "$home" "$id" "$expected_path" --backend zellij ;;
    zellij:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_ZELLIJ_KILL_AMBIGUOUS=1 run_spawn "$home" "$id" "$expected_path" --backend zellij ;;
    cmux:0) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_CMUX_CURRENT_WINDOW_EMPTY=1 run_spawn "$home" "$id" "$expected_path" --backend cmux ;;
    cmux:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_CMUX_CURRENT_WINDOW_EMPTY=1 FM_FAKE_CMUX_KILL_AMBIGUOUS=1 run_spawn "$home" "$id" "$expected_path" --backend cmux ;;
  esac
}

backend_endpoint_meta_field() {  # <backend>
  case "$1" in
    tmux) printf 'tmux_window_id' ;;
    herdr) printf 'herdr_pane_id' ;;
    zellij) printf 'zellij_pane_id' ;;
    cmux) printf 'cmux_workspace_id' ;;
  esac
}

backend_endpoint_remove() {  # <backend> <identity>
  local backend=$1 identity=$2
  case "$backend" in
    tmux)
      awk -F '\t' -v identity="$identity" '$1 != identity' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
      mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
      ;;
    herdr|zellij)
      awk -F '\t' -v backend="$backend" -v identity="$identity" '!($1 == backend && $3 == identity)' "$ENDPOINT_STATE" > "$ENDPOINT_STATE.tmp"
      mv "$ENDPOINT_STATE.tmp" "$ENDPOINT_STATE"
      ;;
    cmux)
      awk -F '\t' -v identity="$identity" '!($1 == "cmux" && $2 == identity)' "$ENDPOINT_STATE" > "$ENDPOINT_STATE.tmp"
      mv "$ENDPOINT_STATE.tmp" "$ENDPOINT_STATE"
      ;;
  esac
}

backend_endpoint_is_live() {  # <backend> <identity>
  local backend=$1 identity=$2
  case "$backend" in
    tmux) awk -F '\t' -v identity="$identity" '$1 == identity {found=1} END {exit !found}' "$TMUX_WINDOWS" ;;
    herdr|zellij) awk -F '\t' -v backend="$backend" -v identity="$identity" '$1 == backend && $3 == identity {found=1} END {exit !found}' "$ENDPOINT_STATE" ;;
    cmux) awk -F '\t' -v identity="$identity" '$1 == "cmux" && $2 == identity {found=1} END {exit !found}' "$ENDPOINT_STATE" ;;
  esac
}

backend_kill_event_pattern() {  # <backend>
  case "$1" in
    tmux) printf 'tmux kill-window -t @' ;;
    herdr) printf 'herdr pane close ' ;;
    zellij) printf 'zellij --session firstmate action close-tab-by-id ' ;;
    cmux) printf 'cmux close-workspace --workspace ' ;;
  esac
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
awk -F '\t' '$2 != "fm-alpha"' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
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
awk -F '\t' '$2 != "fm-alpha"' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
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
if FM_FAKE_CURRENT_PATH_FAIL=1 run_spawn "$HOME_A" rollback "$WT1" >/dev/null 2>&1; then
  fail 'spawn unexpectedly succeeded after a late pre-publication failure'
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
kill_line=$(grep -n '^tmux kill-window ' "$EVENT_LOG" | tail -1 | cut -d: -f1)
return_line=$(grep -n "^treehouse return --force $WT1 --if-lease-id lease-4 " "$EVENT_LOG" | cut -d: -f1)
[ -n "$kill_line" ] && [ -n "$return_line" ] || fail 'late rollback did not record endpoint and lease cleanup'
[ "$kill_line" -lt "$return_line" ] || fail 'late rollback returned its lease before endpoint removal'
pass 'late pre-publication failure confirms its exact endpoint gone before returning its lease'

make_brief "$HOME_A" rollback-held
if FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_RETURN_FAIL_ID=lease-5 \
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

run_spawn "$HOME_A" rollback-held "$WT1" >/dev/null \
  || fail 'exact preserved-lease recovery did not publish successfully'
assert_absent "$HELD_RECEIPT" 'successful exact recovery left its matched acquisition receipt behind'
run_teardown_force "$HOME_A" rollback-held >/dev/null \
  || fail 'teardown after exact preserved-lease recovery failed'
make_brief "$HOME_A" rollback-held
run_spawn "$HOME_A" rollback-held "$WT1" >/dev/null \
  || fail 'task id could not be reused after exact recovery and teardown'
pass 'matched recovery receipt retires through publication, teardown, and task-id reuse'
run_teardown_force "$HOME_A" rollback-held >/dev/null \
  || fail 'task-id reuse cleanup failed'

make_brief "$HOME_A" endpoint-held
if FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_TMUX_KILL_FAIL=1 \
  run_spawn "$HOME_A" endpoint-held "$WT1" >/dev/null 2>&1; then
  fail 'spawn unexpectedly succeeded when endpoint rollback confirmation failed'
fi
ENDPOINT_HELD_META="$HOME_A/state/endpoint-held.meta"
ENDPOINT_HELD_RECEIPT="$HOME_A/state/.endpoint-held.treehouse-lease-acquire.json"
assert_present "$ENDPOINT_HELD_META" 'ambiguous endpoint cleanup did not preserve lease metadata'
assert_present "$ENDPOINT_HELD_RECEIPT" 'ambiguous endpoint cleanup did not preserve acquisition evidence'
grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE" \
  || fail 'ambiguous endpoint cleanup returned the still-entered lease'
pass 'unconfirmed endpoint cleanup preserves the exact lease and acquisition evidence'
run_teardown_force "$HOME_A" endpoint-held >/dev/null \
  || fail 'exact teardown could not recover the endpoint-held lease'
assert_absent "$ENDPOINT_HELD_RECEIPT" 'exact teardown left its matched acquisition receipt behind'
make_brief "$HOME_A" endpoint-held
run_spawn "$HOME_A" endpoint-held "$WT1" >/dev/null \
  || fail 'task id could not be reused after exact receipt-bearing teardown'
run_teardown_force "$HOME_A" endpoint-held >/dev/null \
  || fail 'receipt-bearing teardown reuse cleanup failed'
pass 'exact teardown retires its matched receipt and permits task-id reuse'

for backend in tmux herdr zellij cmux; do
  id="late-$backend"
  make_brief "$HOME_A" "$id"
  event_before=$(wc -l < "$EVENT_LOG" | tr -d ' ')
  if run_backend_late_failure "$backend" "$HOME_A" "$id" "$WT1" 0 >/dev/null 2>&1; then
    fail "$backend spawn unexpectedly succeeded after post-creation failure"
  fi
  event_slice="$WORLD/$id.events"
  tail -n "+$((event_before + 1))" "$EVENT_LOG" > "$event_slice"
  kill_line=$(grep -nF "$(backend_kill_event_pattern "$backend")" "$event_slice" | head -1 | cut -d: -f1)
  return_line=$(grep -nF 'treehouse return --force ' "$event_slice" | head -1 | cut -d: -f1)
  [ -n "$kill_line" ] && [ -n "$return_line" ] \
    || fail "$backend late rollback did not exercise endpoint removal and conditional return"
  [ "$kill_line" -lt "$return_line" ] \
    || fail "$backend returned its lease before retiring its exact endpoint"
  assert_absent "$HOME_A/state/$id.meta" "$backend successful rollback published recovery metadata"
  assert_absent "$HOME_A/state/.$id.treehouse-lease-acquire.json" "$backend successful rollback retained acquisition evidence"
  if grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE"; then
    fail "$backend successful endpoint rollback retained its Treehouse lease"
  fi

  id="late-ambiguous-$backend"
  make_brief "$HOME_A" "$id"
  if run_backend_late_failure "$backend" "$HOME_A" "$id" "$WT1" 1 >/dev/null 2>&1; then
    fail "$backend spawn unexpectedly succeeded with ambiguous endpoint cleanup"
  fi
  meta="$HOME_A/state/$id.meta"
  receipt="$HOME_A/state/.$id.treehouse-lease-acquire.json"
  field=$(backend_endpoint_meta_field "$backend")
  identity=$(sed -n "s/^$field=//p" "$meta")
  [ -n "$identity" ] || fail "$backend ambiguous cleanup did not preserve its stable endpoint identity"
  backend_endpoint_is_live "$backend" "$identity" \
    || fail "$backend ambiguous cleanup metadata does not bind the surviving endpoint"
  assert_present "$receipt" "$backend ambiguous cleanup did not preserve acquisition evidence"
  grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE" \
    || fail "$backend ambiguous cleanup returned the still-entered lease"
  run_teardown_force "$HOME_A" "$id" >/dev/null \
    || fail "$backend teardown could not recover an ambiguity-preserved endpoint"
done
pass 'tmux, Herdr, Zellij, and cmux retire exact late endpoints before return and preserve ambiguity'

for backend in tmux herdr zellij cmux; do
  id="replacement-$backend"
  make_brief "$HOME_A" "$id"
  run_spawn "$HOME_A" "$id" "$WT1" --backend "$backend" >/dev/null \
    || fail "$backend replacement fixture could not publish its first endpoint"
  meta="$HOME_A/state/$id.meta"
  field=$(backend_endpoint_meta_field "$backend")
  old_identity=$(sed -n "s/^$field=//p" "$meta")
  lease_identity=$(sed -n 's/^treehouse_lease_id=//p' "$meta")
  backend_endpoint_remove "$backend" "$old_identity"
  if run_backend_late_failure "$backend" "$HOME_A" "$id" "$WT1" 1 >/dev/null 2>&1; then
    fail "$backend recovered-lease relaunch unexpectedly survived its late failure"
  fi
  new_identity=$(sed -n "s/^$field=//p" "$meta")
  [ -n "$new_identity" ] && [ "$new_identity" != "$old_identity" ] \
    || fail "$backend recovery metadata retained the dead endpoint instead of its replacement"
  [ "$(sed -n 's/^treehouse_lease_id=//p' "$meta")" = "$lease_identity" ] \
    || fail "$backend replacement recovery changed the durable lease identity"
  backend_endpoint_is_live "$backend" "$new_identity" \
    || fail "$backend replacement recovery metadata does not bind the surviving endpoint"
  run_teardown_force "$HOME_A" "$id" >/dev/null \
    || fail "$backend replacement recovery could not be torn down exactly"
done
pass 'recovered leases preserve each backend replacement endpoint identity after ambiguous cleanup'

make_brief "$HOME_A" publication-handoff
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if FM_FAKE_TERM_AFTER_META_PUBLISH=1 FM_FAKE_PUBLISH_ID=publication-handoff \
  run_spawn "$HOME_A" publication-handoff "$WT1" --backend tmux >/dev/null 2>&1; then
  fail 'spawn unexpectedly completed after publication-boundary termination'
fi
PUBLISHED_META="$HOME_A/state/publication-handoff.meta"
assert_present "$PUBLISHED_META" 'publication-boundary termination removed committed metadata'
published_identity=$(sed -n 's/^tmux_window_id=//p' "$PUBLISHED_META")
backend_endpoint_is_live tmux "$published_identity" \
  || fail 'publication-boundary termination retired the committed endpoint'
grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE" \
  || fail 'publication-boundary termination returned the committed lease'
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'publication-boundary termination issued a conditional return after atomic publication'
run_teardown_force "$HOME_A" publication-handoff >/dev/null \
  || fail 'publication-boundary committed task could not be torn down normally'
pass 'exact atomic metadata publication is the committed rollback handoff boundary'

make_brief "$HOME_A" ambiguous-acquire
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
held_count_before=$(wc -l < "$TREEHOUSE_STATE" | tr -d ' ')
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
held_count_after=$(wc -l < "$TREEHOUSE_STATE" | tr -d ' ')
[ "$held_count_after" -eq $((held_count_before + 1)) ] \
  || fail 'ambiguous acquisition hid or duplicated its fake Treehouse held-copy record'
pass 'ambiguous acquisition preserves raw evidence and never guesses a lease release'

echo '# all fm-treehouse-task-lease tests passed'
