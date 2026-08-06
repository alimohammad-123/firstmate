#!/usr/bin/env bash
# Behavioral regression for ordinary task Treehouse leases.
# Drives the real fm-spawn.sh and fm-teardown.sh through a stateful fake
# Treehouse CLI, fake tmux/Herdr/Zellij/cmux endpoints, and secondmate retirement
# races. The fakes model only documented public command surfaces and observable
# endpoint lifecycle behavior.
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
XDG_STATE_HOME="$WORLD/xdg-state"
EVENT_LOG="$WORLD/events.log"
FM_REAL_MV=$(command -v mv)
FM_REAL_RM=$(command -v rm)
FM_REAL_CP=$(command -v cp)
FM_REAL_SLEEP=$(command -v sleep)
FM_REAL_PS=$(command -v ps)
FM_REAL_PYTHON3=$(command -v python3)
export TREEHOUSE_STATE TREEHOUSE_POOL TREEHOUSE_COUNTER TREEHOUSE_LOG TMUX_LOG TMUX_WINDOWS TMUX_COUNTER ENDPOINT_STATE ENDPOINT_COUNTER CMUX_FOCUS_MARKER XDG_STATE_HOME EVENT_LOG FM_REAL_MV FM_REAL_RM FM_REAL_CP FM_REAL_SLEEP FM_REAL_PS FM_REAL_PYTHON3

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
    if [ "${FM_FAKE_TERM_AFTER_GET:-0}" = 1 ]; then
      kill -TERM "$PPID"
    fi
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
    if [ "${FM_FAKE_RETURN_INDEX_LOCK_ID:-}" = "$expected_id" ] \
       && [ ! -e "$TREEHOUSE_STATE.return-lock-$expected_id" ]; then
      : > "$TREEHOUSE_STATE.return-lock-$expected_id"
      if [ -n "${FM_FAKE_RETURN_RESTART_TASK:-}" ]; then
        printf '@return-restart-%s\tfirstmate\tfm-%s\n' \
          "$FM_FAKE_RETURN_RESTART_TASK" "$FM_FAKE_RETURN_RESTART_TASK" >> "$TMUX_WINDOWS"
      fi
      echo "fatal: Unable to create '$path/.git/index.lock': File exists" >&2
      exit 1
    fi
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
    if [ "${FM_FAKE_TMUX_REBOUND_BEFORE_FAILURE:-0}" = 1 ]; then
      target=
      prev=
      for arg in "$@"; do [ "$prev" != -t ] || target=$arg; prev=$arg; done
      rebound_marker="$TMUX_WINDOWS.rebound-${target#@}"
      if [ ! -e "$rebound_marker" ]; then
        : > "$rebound_marker"
        row=$(awk -F '\t' -v target="$target" '$1 == target {print; exit}' "$TMUX_WINDOWS")
        session=$(printf '%s\n' "$row" | cut -f2)
        name=$(printf '%s\n' "$row" | cut -f3)
        awk -F '\t' -v target="$target" 'BEGIN {OFS="\t"} {if ($1 == target) $3="foreign-after-restart"; print}' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
        mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
        printf '@restart-replacement-%s\t%s\t%s\n' "${target#@}" "$session" "$name" >> "$TMUX_WINDOWS"
      fi
    fi
    if [ "${FM_FAKE_TMUX_RENAME_BEFORE_FAILURE:-0}" = 1 ]; then
      target=
      prev=
      for arg in "$@"; do [ "$prev" != -t ] || target=$arg; prev=$arg; done
      awk -F '\t' -v target="$target" 'BEGIN {OFS="\t"} {if ($1 == target) $3="renamed-after-create"; print}' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
      mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
    fi
    [ "${FM_FAKE_CURRENT_PATH_FAIL:-0}" != 1 ] && printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{pane_pid}"*)
    if [ -n "${FM_FAKE_TMUX_PROCESS_FILE:-}" ]; then
      if [ ! -s "$FM_FAKE_TMUX_PROCESS_FILE" ]; then
        "$FM_REAL_PYTHON3" - "$FM_FAKE_TMUX_PROCESS_FILE" "$FM_REAL_SLEEP" <<'PY' >/dev/null 2>&1 &
import os, sys
os.setsid()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))
os.execv(sys.argv[2], [sys.argv[2], "30"])
PY
        i=0
        while [ ! -s "$FM_FAKE_TMUX_PROCESS_FILE" ] && [ "$i" -lt 100 ]; do
          "$FM_REAL_SLEEP" 0.01
          i=$((i + 1))
        done
      fi
      cat "$FM_FAKE_TMUX_PROCESS_FILE"
    fi
    exit 0
    ;;
  *"#{pane_current_command}"*) printf 'zsh\n'; exit 0 ;;
  *"#{pane_tty}"*) printf '/dev/null\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    case "$*" in
      *'#{session_name}'*) cat "$TMUX_WINDOWS" ;;
      *'#{window_id}'*) cut -f1 "$TMUX_WINDOWS" ;;
      *) cut -f3 "$TMUX_WINDOWS" ;;
    esac
    exit 0
    ;;
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
  kill-window)
    [ "${FM_FAKE_TMUX_KILL_FAIL:-0}" != 1 ] || exit 0
    target=${3:-}
    case "$target" in
      @*) awk -F '\t' -v id="$target" '$1 != id' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp" ;;
      *) window=${target##*:=}; awk -F '\t' -v name="$window" '$3 != name' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp" ;;
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
    [ -z "$name" ] || printf '%s\tfirstmate\t%s\n' "$wid" "$name" >> "$TMUX_WINDOWS"
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
  *'workspace list'*)
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-retire-surviving-herdr"}]}}\n'
    exit 0
    ;;
  *'tab list'*)
    jq -Rn '
      [inputs | select(length > 0) | split("\t") | select(.[0] == "herdr")
        | {tab_id:.[1],label:.[3]}] | {result:{tabs:.}}
    ' < "$ENDPOINT_STATE" 2>/dev/null || printf '{"result":{"tabs":[]}}\n'
    exit 0
    ;;
  *'tab create'*)
    counter=$(cat "$ENDPOINT_COUNTER"); counter=$((counter + 1)); printf '%s\n' "$counter" > "$ENDPOINT_COUNTER"
    tab="t$counter"; workspace=w1; label=
    prev=
    for arg in "$@"; do
      [ "$prev" != --label ] || label=$arg
      [ "$prev" != --workspace ] || workspace=$arg
      prev=$arg
    done
    pane="$workspace:p$counter"
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
      workspace=${pane%%:*}
      jq -n --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" --arg cwd "$cwd" \
        '{result:{pane:{pane_id:$pane,tab_id:$tab,workspace_id:$workspace,foreground_cwd:$cwd,shell_pid:99999}}}'
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
      if [ "${FM_FAKE_CMUX_DUPLICATE_BEFORE_FAILURE:-0}" = 1 ]; then
        ws=
        prev=
        for arg in "$@"; do [ "$prev" != --workspace ] || ws=$arg; prev=$arg; done
        title=$(awk -F '\t' -v ws="$ws" '$1 == "cmux" && $2 == ws {print $4; exit}' "$ENDPOINT_STATE")
        awk -F '\t' -v ws="$ws" '!($1 == "cmux" && $2 == ws)' "$ENDPOINT_STATE" > "$ENDPOINT_STATE.tmp"
        mv "$ENDPOINT_STATE.tmp" "$ENDPOINT_STATE"
        printf 'cmux\t22222222-2222-2222-2222-222222222231\t33333333-3333-3333-3333-333333333331\t%s\twindow-1\n' "$title" >> "$ENDPOINT_STATE"
        printf 'cmux\t22222222-2222-2222-2222-222222222232\t33333333-3333-3333-3333-333333333332\t%s\twindow-2\n' "$title" >> "$ENDPOINT_STATE"
      fi
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
if [ "${FM_FAKE_BLOCK_BEFORE_META_PUBLISH:-0}" = 1 ] \
   && [ "$dest" = "${FM_STATE_OVERRIDE:-}/${FM_FAKE_PUBLISH_ID:-}.meta" ]; then
  : > "$FM_FAKE_PUBLISH_READY"
  while [ ! -f "$FM_FAKE_PUBLISH_RELEASE" ]; do
    "$FM_REAL_SLEEP" 0.05
  done
fi
source_arg=${@: -2:1}
if [ "${FM_FAKE_RECOVERY_PUBLISH_FAIL:-0}" = 1 ] \
   && [ "$dest" = "${FM_STATE_OVERRIDE:-}/${FM_FAKE_PUBLISH_ID:-}.meta" ] \
   && [[ "$source_arg" == *.meta.lease-recovery.* ]]; then
  exit 1
fi
"$FM_REAL_MV" "$@"
status=$?
if [ "$status" -eq 0 ] \
   && [ "$dest" = "${FM_STATE_OVERRIDE:-}/${FM_FAKE_PUBLISH_ID:-}.meta" ]; then
  printf 'metadata-published %s\n' "${FM_FAKE_PUBLISH_ID:-}" >> "$EVENT_LOG"
fi
if [ "$status" -eq 0 ] \
   && [ "${FM_FAKE_TERM_AFTER_META_PUBLISH:-0}" = 1 ] \
   && [ "$dest" = "${FM_STATE_OVERRIDE:-}/$FM_FAKE_PUBLISH_ID.meta" ]; then
  kill -TERM "$PPID"
fi
exit "$status"
SH
chmod +x "$FAKEBIN/mv"

cat > "$FAKEBIN/rm" <<'SH'
#!/usr/bin/env bash
set -u
target=${!#}
if [ -n "${FM_FAKE_REMOVE_HOME:-}" ] && [ "$target" = "$FM_FAKE_REMOVE_HOME" ]; then
  "$FM_REAL_RM" "$@"
  "$FM_REAL_CP" -R "$FM_FAKE_RECYCLE_TEMPLATE" "$FM_FAKE_REMOVE_HOME"
  : > "$FM_FAKE_REMOVE_READY"
  while [ ! -f "$FM_FAKE_REMOVE_RELEASE" ]; do
    "$FM_REAL_SLEEP" 0.05
  done
  exit 0
fi
exec "$FM_REAL_RM" "$@"
SH
chmod +x "$FAKEBIN/rm"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_BLOCK_DURING_TEARDOWN:-0}" = 1 ] \
   && [ ! -e "${FM_FAKE_TEARDOWN_READY:-}" ]; then
  : > "$FM_FAKE_TEARDOWN_READY"
  while [ ! -e "$FM_FAKE_TEARDOWN_RELEASE" ]; do
    "$FM_REAL_SLEEP" 0.05
  done
fi
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"
cat > "$FAKEBIN/lsof" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_RECORD_REAP:-0}" != 1 ] || printf 'reap-scan %s\n' "$*" >> "$EVENT_LOG"
[ "${FM_FAKE_LSOF_FAIL:-0}" != 1 ] || exit 1
if [ "${FM_FAKE_LSOF_MALFORMED:-0}" = 1 ]; then
  printf 'unparseable\n'
  exit 0
fi
if [ -n "${FM_FAKE_RESTART_AFTER_REAP_TASK:-}" ] \
   && [ ! -e "$TMUX_WINDOWS.reap-restarted-$FM_FAKE_RESTART_AFTER_REAP_TASK" ]; then
  : > "$TMUX_WINDOWS.reap-restarted-$FM_FAKE_RESTART_AFTER_REAP_TASK"
  printf '@reap-restart-%s\tfirstmate\tfm-%s\n' \
    "$FM_FAKE_RESTART_AFTER_REAP_TASK" "$FM_FAKE_RESTART_AFTER_REAP_TASK" >> "$TMUX_WINDOWS"
fi
exit 0
SH
chmod +x "$FAKEBIN/lsof"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_REAL_PS:-0}" = 1 ] && exec "$FM_REAL_PS" "$@"
exit 0
SH
chmod +x "$FAKEBIN/ps"
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_REAL_SLEEP:-0}" = 1 ] && exec "$FM_REAL_SLEEP" "$@"
exit 0
SH
chmod +x "$FAKEBIN/sleep"
fm_fake_exit0 "$FAKEBIN" gh gh-axi

make_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf 'lease test for %s\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
}

next_treehouse_path() {
  local candidate
  while IFS= read -r candidate; do
    grep -Fq "$candidate"$'\t' "$TREEHOUSE_STATE" 2>/dev/null && continue
    printf '%s\n' "$candidate"
    return 0
  done < "$TREEHOUSE_POOL"
  return 1
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
    FM_TEARDOWN_GUARD_DONE=1 FM_TREEHOUSE_RETURN_LOCK_RETRIES="${FM_TEST_RETURN_RETRIES:-0}" \
    PATH="$FAKEBIN:$PATH" "$TEARDOWN" "$id" --force
}

run_teardown() {
  local home=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEARDOWN_GUARD_DONE=1 FM_TREEHOUSE_RETURN_LOCK_RETRIES="${FM_TEST_RETURN_RETRIES:-0}" \
    PATH="$FAKEBIN:$PATH" "$TEARDOWN" "$id"
}

make_secondmate_retirement_fixture() {  # <home> <parent-id>
  local home=$1 parent_id=$2
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/bin"
  printf '%s\n' "$parent_id" > "$home/.fm-secondmate-home"
  printf '# test home\n' > "$home/AGENTS.md"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  cat > "$HOME_A/state/$parent_id.meta" <<EOF
window=firstmate:fm-$parent_id
endpoint_task_id=$parent_id
worktree=$home
project=$home
harness=sh
kind=secondmate
mode=secondmate
yolo=off
home=$home
projects=test
EOF
  printf -- '- %s - test secondmate (home: %s; scope: lease lifecycle; projects: test; added 2026-08-06)\n' \
    "$parent_id" "$home" >> "$HOME_A/data/secondmates.md"
  printf '@parent-%s\tfirstmate\tfm-%s\n' "$parent_id" "$parent_id" >> "$TMUX_WINDOWS"
}

hold_task_lifecycle_lock() {  # <lock> <ready> <release>
  local lock=$1 ready=$2 release=$3
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$lock"
    : > "$ready"
    while [ ! -f "$release" ]; do
      "$FM_REAL_SLEEP" 0.05
    done
    fm_lock_release "$lock"
  ) &
  HELD_LOCK_PID=$!
}

run_backend_late_failure() {  # <backend> <home> <id> <expected-path> <ambiguous>
  local backend=$1 home=$2 id=$3 expected_path=$4 ambiguous=$5
  [ "$backend" != cmux ] || rm -f -- "$CMUX_FOCUS_MARKER"
  case "$backend:$ambiguous" in
    tmux:0) FM_FAKE_CURRENT_PATH_FAIL=1 run_spawn "$home" "$id" "$expected_path" --backend tmux ;;
    tmux:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_TMUX_KILL_FAIL=1 run_spawn "$home" "$id" "$expected_path" --backend tmux ;;
    herdr:0) FM_FAKE_CURRENT_PATH_FAIL=1 run_spawn "$home" "$id" "$expected_path" --backend herdr ;;
    herdr:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_HERDR_KILL_AMBIGUOUS=1 run_spawn "$home" "$id" "$expected_path" --backend herdr ;;
    zellij:0) FM_FAKE_CURRENT_PATH_FAIL=1 run_spawn "$home" "$id" "$expected_path" --backend zellij ;;
    zellij:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_ZELLIJ_KILL_AMBIGUOUS=1 run_spawn "$home" "$id" "$expected_path" --backend zellij ;;
    cmux:0) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_CMUX_CURRENT_WINDOW_EMPTY=1 run_spawn "$home" "$id" "$expected_path" --backend cmux ;;
    cmux:1) FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_CMUX_CURRENT_WINDOW_EMPTY=1 FM_FAKE_CMUX_KILL_AMBIGUOUS=1 run_spawn "$home" "$id" "$expected_path" --backend cmux ;;
  esac
}

run_backend_teardown_ambiguous() {  # <backend> <home> <id>
  local backend=$1 home=$2 id=$3
  case "$backend" in
    tmux) FM_FAKE_TMUX_KILL_FAIL=1 run_teardown_force "$home" "$id" ;;
    herdr) FM_FAKE_HERDR_KILL_AMBIGUOUS=1 run_teardown_force "$home" "$id" ;;
    zellij) FM_FAKE_ZELLIJ_KILL_AMBIGUOUS=1 run_teardown_force "$home" "$id" ;;
    cmux) FM_FAKE_CMUX_KILL_AMBIGUOUS=1 run_teardown_force "$home" "$id" ;;
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

secondmate_backend_title() {  # <backend> <home> <task-id>
  local backend=$1 home=$2 task_id=$3
  ( unset FM_ROOT_OVERRIDE; FM_HOME=$home FM_ROOT=$home
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source "$backend"
    case "$backend" in
      zellij) fm_backend_zellij_scoped_title "fm-$task_id" ;;
      cmux) fm_backend_cmux_scoped_title "fm-$task_id" ;;
    esac
  )
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
awk -F '\t' '$3 != "fm-alpha"' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
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
awk -F '\t' '$3 != "fm-alpha"' "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
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

make_brief "$HOME_A" tmux-restart-recover
run_spawn "$HOME_A" tmux-restart-recover "$WT1" >/dev/null \
  || fail 'tmux restart recovery fixture could not publish'
TMUX_RESTART_META="$HOME_A/state/tmux-restart-recover.meta"
tmux_restart_old=$(sed -n 's/^tmux_window_id=//p' "$TMUX_RESTART_META")
tmux_restart_new=@restart-recovered
awk -F '\t' -v old="$tmux_restart_old" -v new="$tmux_restart_new" \
  'BEGIN {OFS="\t"} {$1 = ($1 == old ? new : $1); print}' \
  "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
run_teardown_force "$HOME_A" tmux-restart-recover >/dev/null \
  || fail 'tmux teardown did not recover one unique exact task name after server restart'
if backend_endpoint_is_live tmux "$tmux_restart_new"; then
  fail 'tmux restart recovery did not retire the uniquely correlated live window'
fi
pass 'tmux teardown recovers one unique exact task window after restart'

make_brief "$HOME_A" tmux-rebound
run_spawn "$HOME_A" tmux-rebound "$WT1" >/dev/null \
  || fail 'tmux rebound fixture could not publish'
TMUX_REBOUND_META="$HOME_A/state/tmux-rebound.meta"
tmux_rebound_old=$(sed -n 's/^tmux_window_id=//p' "$TMUX_REBOUND_META")
tmux_rebound_new=@rebound-replacement
awk -F '\t' -v old="$tmux_rebound_old" \
  'BEGIN {OFS="\t"} {if ($1 == old) $3="foreign-window"; print}' \
  "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
printf '%s\tfirstmate\tfm-tmux-rebound\n' "$tmux_rebound_new" >> "$TMUX_WINDOWS"
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if run_teardown_force "$HOME_A" tmux-rebound >/dev/null 2>&1; then
  fail 'tmux teardown accepted a recorded id rebound to another window'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'tmux rebound identity reached Treehouse return'
backend_endpoint_is_live tmux "$tmux_rebound_old" \
  || fail 'tmux rebound refusal killed the unrelated recorded-id window'
backend_endpoint_is_live tmux "$tmux_rebound_new" \
  || fail 'tmux rebound refusal killed the exact-name replacement window'
backend_endpoint_remove tmux "$tmux_rebound_old"
run_teardown_force "$HOME_A" tmux-rebound >/dev/null \
  || fail 'tmux rebound fixture could not recover after the foreign id disappeared'
pass 'tmux teardown refuses rebound ids before lease return'

make_brief "$HOME_A" tmux-absent
run_spawn "$HOME_A" tmux-absent "$WT1" >/dev/null \
  || fail 'tmux absent fixture could not publish'
TMUX_ABSENT_META="$HOME_A/state/tmux-absent.meta"
tmux_absent_old=$(sed -n 's/^tmux_window_id=//p' "$TMUX_ABSENT_META")
backend_endpoint_remove tmux "$tmux_absent_old"
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if run_teardown_force "$HOME_A" tmux-absent >/dev/null 2>&1; then
  fail 'tmux teardown accepted an absent recorded id with no exact-name recovery'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'tmux absent identity reached Treehouse return'
printf '@absent-recovery\tfirstmate\tfm-tmux-absent\n' >> "$TMUX_WINDOWS"
printf '@absent-ambiguous\tfirstmate\tfm-tmux-absent\n' >> "$TMUX_WINDOWS"
if run_teardown_force "$HOME_A" tmux-absent >/dev/null 2>&1; then
  fail 'tmux teardown accepted ambiguous exact-name recovery'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'tmux ambiguous identity reached Treehouse return'
backend_endpoint_remove tmux @absent-ambiguous
run_teardown_force "$HOME_A" tmux-absent >/dev/null \
  || fail 'tmux absent fixture could not clean up after exact-name recovery appeared'
pass 'tmux teardown refuses absent endpoint identity before lease return'

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
assert_grep "return --force $WT1 --if-lease-id lease-7 --if-lease-holder firstmate-task:$HOME_A_REAL:rollback" \
  "$TREEHOUSE_LOG" 'spawn failure did not roll back only the exact acquired lease'
kill_line=$(grep -n '^tmux kill-window ' "$EVENT_LOG" | tail -1 | cut -d: -f1)
return_line=$(grep -n "^treehouse return --force $WT1 --if-lease-id lease-7 " "$EVENT_LOG" | cut -d: -f1)
[ -n "$kill_line" ] && [ -n "$return_line" ] || fail 'late rollback did not record endpoint and lease cleanup'
[ "$kill_line" -lt "$return_line" ] || fail 'late rollback returned its lease before endpoint removal'
pass 'late pre-publication failure confirms its exact endpoint gone before returning its lease'

make_brief "$HOME_A" rollback-held
if FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_RETURN_FAIL_ID=lease-8 \
  run_spawn "$HOME_A" rollback-held "$WT1" >/dev/null 2>&1; then
  fail 'spawn unexpectedly succeeded when exact rollback was configured to fail'
fi
HELD_META="$HOME_A/state/rollback-held.meta"
HELD_RECEIPT="$HOME_A/state/.rollback-held.treehouse-lease-acquire.json"
assert_present "$HELD_META" 'failed rollback did not preserve recoverable lease metadata'
assert_present "$HELD_RECEIPT" 'failed rollback did not preserve the exact acquisition receipt'
assert_grep 'treehouse_lease_id=lease-8' "$HELD_META" 'failed rollback metadata lost the lease id'
assert_grep 'treehouse_lease_recovery=spawn-rollback-failed' "$HELD_META" \
  'failed rollback metadata did not identify the recovery condition'
grep -Fq "$WT1"$'\tlease-8\t' "$TREEHOUSE_STATE" \
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

PRIMARY_COMPAT_PARENT="$WORLD/primary-compat-parent"
PRIMARY_COMPAT_HOME="$PRIMARY_COMPAT_PARENT/home"
mkdir -p "$PRIMARY_COMPAT_HOME/data" "$PRIMARY_COMPAT_HOME/state" \
  "$PRIMARY_COMPAT_HOME/config" "$PRIMARY_COMPAT_HOME/projects"
printf 'off\n' > "$PRIMARY_COMPAT_HOME/config/herdr-presentation-spaces"
make_brief "$PRIMARY_COMPAT_HOME" primary-parent-compat
chmod 500 "$PRIMARY_COMPAT_PARENT"
set +e
XDG_STATE_HOME="$PRIMARY_COMPAT_PARENT/xdg-state" \
  run_spawn "$PRIMARY_COMPAT_HOME" primary-parent-compat "$WT1" --backend tmux \
    >"$WORLD/primary-parent-compat.out" 2>"$WORLD/primary-parent-compat.err"
primary_compat_rc=$?
set -e
chmod 700 "$PRIMARY_COMPAT_PARENT"
[ "$primary_compat_rc" -eq 0 ] \
  || fail "primary spawn required a parent-directory lifecycle write\n$(cat "$WORLD/primary-parent-compat.err")"
assert_absent "$PRIMARY_COMPAT_PARENT/xdg-state" \
  'primary spawn created secondmate lifecycle state outside its home'
run_teardown_force "$PRIMARY_COMPAT_HOME" primary-parent-compat >/dev/null \
  || fail 'primary parent-write compatibility fixture could not be torn down'
pass 'ordinary primary spawn retains its home-local per-task lock path'

for backend in tmux herdr zellij cmux; do
  id="teardown-order-$backend"
  make_brief "$HOME_A" "$id"
  run_spawn "$HOME_A" "$id" "$WT1" --backend "$backend" >/dev/null \
    || fail "$backend teardown-order fixture could not publish"
  meta="$HOME_A/state/$id.meta"
  field=$(backend_endpoint_meta_field "$backend")
  identity=$(sed -n "s/^$field=//p" "$meta")
  return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
  if run_backend_teardown_ambiguous "$backend" "$HOME_A" "$id" >/dev/null 2>&1; then
    fail "$backend teardown accepted an endpoint close without exact absence proof"
  fi
  return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
  [ "$return_count_after" -eq "$return_count_before" ] \
    || fail "$backend teardown returned its lease after ambiguous endpoint cleanup"
  backend_endpoint_is_live "$backend" "$identity" \
    || fail "$backend ambiguous teardown did not preserve the live endpoint"
  assert_present "$meta" "$backend ambiguous teardown erased task metadata"
  event_before=$(wc -l < "$EVENT_LOG" | tr -d ' ')
  FM_FAKE_RECORD_REAP=1 run_teardown_force "$HOME_A" "$id" >/dev/null \
    || fail "$backend teardown-order fixture could not close exactly"
  event_slice="$WORLD/$id.events"
  tail -n "+$((event_before + 1))" "$EVENT_LOG" > "$event_slice"
  kill_line=$(grep -nF "$(backend_kill_event_pattern "$backend")" "$event_slice" | head -1 | cut -d: -f1)
  reap_line=$(grep -nF 'reap-scan ' "$event_slice" | head -1 | cut -d: -f1)
  return_line=$(grep -nF 'treehouse return --force ' "$event_slice" | head -1 | cut -d: -f1)
  [ -n "$kill_line" ] && [ -n "$reap_line" ] && [ -n "$return_line" ] \
    || fail "$backend teardown did not exercise endpoint retirement, process reap, and exact return"
  [ "$kill_line" -lt "$reap_line" ] && [ "$reap_line" -lt "$return_line" ] \
    || fail "$backend teardown did not retire endpoint before reap and return after reap"
done
pass 'all Treehouse backends retire endpoints before process reap and lease return'

make_brief "$HOME_A" tmux-no-lsof
run_spawn "$HOME_A" tmux-no-lsof "$WT1" >/dev/null \
  || fail 'missing-lsof fallback fixture could not publish'
TMUX_NO_LSOF_PROCESS="$WORLD/tmux-no-lsof.process"
FM_LSOF_BIN="$WORLD/missing-lsof" FM_FAKE_REAL_PS=1 FM_FAKE_REAL_SLEEP=1 \
  FM_FAKE_TMUX_PROCESS_FILE="$TMUX_NO_LSOF_PROCESS" \
  run_teardown_force "$HOME_A" tmux-no-lsof >/dev/null \
  || fail 'captured tmux process fallback did not permit exact teardown without lsof'
tmux_no_lsof_pid=$(cat "$TMUX_NO_LSOF_PROCESS")
if kill -0 "$tmux_no_lsof_pid" 2>/dev/null; then
  fail 'missing-lsof fallback left the captured tmux process group alive'
fi
pass 'missing lsof uses a pre-retirement exact tmux process fallback'

make_brief "$HOME_A" reap-ambiguous
run_spawn "$HOME_A" reap-ambiguous "$WT1" >/dev/null \
  || fail 'ambiguous reap fixture could not publish'
REAP_AMBIGUOUS_META="$HOME_A/state/reap-ambiguous.meta"
reap_ambiguous_lease=$(sed -n 's/^treehouse_lease_id=//p' "$REAP_AMBIGUOUS_META")
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if FM_FAKE_LSOF_MALFORMED=1 run_teardown_force "$HOME_A" reap-ambiguous >/dev/null 2>&1; then
  fail 'teardown accepted an ambiguous process scan'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'ambiguous process scan reached conditional lease return'
assert_present "$REAP_AMBIGUOUS_META" 'ambiguous process scan erased task metadata'
grep -Fq "$WT1"$'\t'"$reap_ambiguous_lease"$'\t' "$TREEHOUSE_STATE" \
  || fail 'ambiguous process scan released the exact lease'
run_teardown_force "$HOME_A" reap-ambiguous >/dev/null \
  || fail 'ambiguous reap fixture did not recover on a readable retry'
pass 'ambiguous process scans refuse before conditional lease return'

make_brief "$HOME_A" endpoint-after-reap
run_spawn "$HOME_A" endpoint-after-reap "$WT1" >/dev/null \
  || fail 'post-reap endpoint restart fixture could not publish'
ENDPOINT_AFTER_REAP_META="$HOME_A/state/endpoint-after-reap.meta"
endpoint_after_reap_lease=$(sed -n 's/^treehouse_lease_id=//p' "$ENDPOINT_AFTER_REAP_META")
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if FM_FAKE_RESTART_AFTER_REAP_TASK=endpoint-after-reap \
  run_teardown_force "$HOME_A" endpoint-after-reap >/dev/null 2>&1; then
  fail 'teardown returned a lease after the task endpoint restarted during reap'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'post-reap endpoint restart reached conditional lease return'
assert_present "$ENDPOINT_AFTER_REAP_META" 'post-reap endpoint restart erased task metadata'
grep -Fq "$WT1"$'\t'"$endpoint_after_reap_lease"$'\t' "$TREEHOUSE_STATE" \
  || fail 'post-reap endpoint restart released the exact lease'
backend_endpoint_remove tmux @reap-restart-endpoint-after-reap
run_teardown_force "$HOME_A" endpoint-after-reap >/dev/null \
  || fail 'post-reap endpoint restart fixture did not recover after exact removal'
pass 'endpoint identity is freshly rechecked after process reap'

make_brief "$HOME_A" endpoint-on-return-retry
run_spawn "$HOME_A" endpoint-on-return-retry "$WT1" >/dev/null \
  || fail 'return-retry endpoint fixture could not publish'
ENDPOINT_RETRY_META="$HOME_A/state/endpoint-on-return-retry.meta"
endpoint_retry_lease=$(sed -n 's/^treehouse_lease_id=//p' "$ENDPOINT_RETRY_META")
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if FM_TEST_RETURN_RETRIES=1 FM_FAKE_RETURN_INDEX_LOCK_ID="$endpoint_retry_lease" \
  FM_FAKE_RETURN_RESTART_TASK=endpoint-on-return-retry \
  run_teardown_force "$HOME_A" endpoint-on-return-retry >/dev/null 2>&1; then
  fail 'return retry skipped fresh endpoint identity correlation'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq $((return_count_before + 1)) ] \
  || fail 'return retry invoked Treehouse again after endpoint identity rebound'
assert_present "$ENDPOINT_RETRY_META" 'return-retry rebound erased task metadata'
grep -Fq "$WT1"$'\t'"$endpoint_retry_lease"$'\t' "$TREEHOUSE_STATE" \
  || fail 'return-retry rebound released the exact lease'
backend_endpoint_remove tmux @return-restart-endpoint-on-return-retry
run_teardown_force "$HOME_A" endpoint-on-return-retry >/dev/null \
  || fail 'return-retry endpoint fixture did not recover after exact removal'
pass 'every conditional return retry freshly rechecks endpoint identity'

make_brief "$HOME_A" tmux-final-rebound
run_spawn "$HOME_A" tmux-final-rebound "$WT1" >/dev/null \
  || fail 'tmux final-correlation fixture could not publish'
TMUX_FINAL_META="$HOME_A/state/tmux-final-rebound.meta"
tmux_final_old=$(sed -n 's/^tmux_window_id=//p' "$TMUX_FINAL_META")
tmux_final_new=@final-rebound-replacement
TMUX_FINAL_READY="$WORLD/tmux-final-rebound.ready"
TMUX_FINAL_RELEASE="$WORLD/tmux-final-rebound.release"
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
event_count_before=$(wc -l < "$EVENT_LOG" | tr -d ' ')
FM_FAKE_BLOCK_DURING_TEARDOWN=1 \
  FM_FAKE_TEARDOWN_READY="$TMUX_FINAL_READY" \
  FM_FAKE_TEARDOWN_RELEASE="$TMUX_FINAL_RELEASE" \
  run_teardown_force "$HOME_A" tmux-final-rebound \
  >"$WORLD/tmux-final-rebound.out" 2>"$WORLD/tmux-final-rebound.err" &
tmux_final_pid=$!
i=0
while [ ! -e "$TMUX_FINAL_READY" ] && [ "$i" -lt 100 ]; do
  "$FM_REAL_SLEEP" 0.05
  i=$((i + 1))
done
assert_present "$TMUX_FINAL_READY" \
  'tmux final-correlation fixture did not reach its post-validation barrier'
awk -F '\t' -v id="$tmux_final_old" \
  'BEGIN {OFS="\t"} {if ($1 == id) $3="foreign-final-window"; print}' \
  "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
printf '%s\tfirstmate\tfm-tmux-final-rebound\n' "$tmux_final_new" >> "$TMUX_WINDOWS"
: > "$TMUX_FINAL_RELEASE"
if wait "$tmux_final_pid"; then
  fail 'tmux teardown accepted an id rebound after early validation'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'tmux final-correlation refusal returned the Treehouse lease'
tail -n "+$((event_count_before + 1))" "$EVENT_LOG" > "$WORLD/tmux-final-rebound.events"
if grep -Fq 'tmux kill-window -t ' "$WORLD/tmux-final-rebound.events"; then
  fail 'tmux final-correlation refusal killed an endpoint after id reuse'
fi
backend_endpoint_is_live tmux "$tmux_final_old" \
  || fail 'tmux final-correlation refusal killed the rebound foreign window'
backend_endpoint_is_live tmux "$tmux_final_new" \
  || fail 'tmux final-correlation refusal killed the exact-name replacement'
assert_present "$TMUX_FINAL_META" 'tmux final-correlation refusal erased task metadata'
grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE" \
  || fail 'tmux final-correlation refusal lost the held lease'
backend_endpoint_remove tmux "$tmux_final_old"
run_teardown_force "$HOME_A" tmux-final-rebound >/dev/null \
  || fail 'tmux final-correlation fixture could not recover after ambiguity cleared'
pass 'tmux teardown revalidates live identity before endpoint retirement and lease return'

make_brief "$HOME_A" cmux-duplicate-title
run_spawn "$HOME_A" cmux-duplicate-title "$WT1" --backend cmux >/dev/null \
  || fail 'cmux duplicate-title fixture could not publish'
CMUX_DUPLICATE_META="$HOME_A/state/cmux-duplicate-title.meta"
cmux_duplicate_recorded=$(sed -n 's/^cmux_workspace_id=//p' "$CMUX_DUPLICATE_META")
cmux_duplicate_title=$(awk -F '\t' -v ws="$cmux_duplicate_recorded" \
  '$1 == "cmux" && $2 == ws {print $4; exit}' "$ENDPOINT_STATE")
[ -n "$cmux_duplicate_title" ] || fail 'cmux duplicate-title fixture lost its scoped title'
backend_endpoint_remove cmux "$cmux_duplicate_recorded"
cmux_duplicate_a=22222222-2222-2222-2222-222222222221
cmux_duplicate_b=22222222-2222-2222-2222-222222222222
printf 'cmux\t%s\t33333333-3333-3333-3333-333333333331\t%s\twindow-1\n' \
  "$cmux_duplicate_a" "$cmux_duplicate_title" >> "$ENDPOINT_STATE"
printf 'cmux\t%s\t33333333-3333-3333-3333-333333333332\t%s\twindow-2\n' \
  "$cmux_duplicate_b" "$cmux_duplicate_title" >> "$ENDPOINT_STATE"
return_count_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
if run_teardown_force "$HOME_A" cmux-duplicate-title >/dev/null 2>&1; then
  fail 'cmux teardown accepted ambiguous exact-title recovery'
fi
return_count_after=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$return_count_after" -eq "$return_count_before" ] \
  || fail 'cmux duplicate-title ambiguity reached Treehouse return'
backend_endpoint_is_live cmux "$cmux_duplicate_a" \
  || fail 'cmux duplicate-title ambiguity closed the first arbitrary workspace'
backend_endpoint_is_live cmux "$cmux_duplicate_b" \
  || fail 'cmux duplicate-title ambiguity closed the second arbitrary workspace'
assert_present "$CMUX_DUPLICATE_META" 'cmux duplicate-title refusal erased task metadata'
backend_endpoint_remove cmux "$cmux_duplicate_b"
run_teardown_force "$HOME_A" cmux-duplicate-title >/dev/null \
  || fail 'cmux duplicate-title fixture could not recover after becoming unique'
pass 'cmux duplicate-title recovery refuses before endpoint or lease mutation'

make_brief "$HOME_A" rollback-tmux-rebound
tmux_rebound_event_before=$(wc -l < "$EVENT_LOG" | tr -d ' ')
if FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_TMUX_REBOUND_BEFORE_FAILURE=1 \
  run_spawn "$HOME_A" rollback-tmux-rebound "$WT1" --backend tmux >/dev/null 2>&1; then
  fail 'tmux rollback accepted a restart-reused window id'
fi
TMUX_REBOUND_META="$HOME_A/state/rollback-tmux-rebound.meta"
TMUX_REBOUND_RECEIPT="$HOME_A/state/.rollback-tmux-rebound.treehouse-lease-acquire.json"
tmux_rebound_recorded=$(sed -n 's/^tmux_window_id=//p' "$TMUX_REBOUND_META")
tmux_rebound_replacement="@restart-replacement-${tmux_rebound_recorded#@}"
awk -F '\t' -v identity="$tmux_rebound_recorded" '$1 == identity && $3 == "foreign-after-restart" {found=1} END {exit !found}' "$TMUX_WINDOWS" \
  || fail 'tmux rollback restart fixture lost the rebound recorded id'
backend_endpoint_is_live tmux "$tmux_rebound_replacement" \
  || fail 'tmux rollback restart fixture lost the unique exact-name replacement'
tail -n "+$((tmux_rebound_event_before + 1))" "$EVENT_LOG" > "$WORLD/rollback-tmux-rebound.events"
if grep -Fq 'tmux kill-window -t ' "$WORLD/rollback-tmux-rebound.events"; then
  fail 'tmux rollback mutated an endpoint after its recorded id rebound'
fi
assert_present "$TMUX_REBOUND_META" 'tmux rebound rollback erased exact lease metadata'
assert_present "$TMUX_REBOUND_RECEIPT" 'tmux rebound rollback erased acquisition evidence'
grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE" \
  || fail 'tmux rebound rollback returned the ambiguous lease'
backend_endpoint_remove tmux "$tmux_rebound_recorded"
run_teardown_force "$HOME_A" rollback-tmux-rebound >/dev/null \
  || fail 'tmux rebound rollback fixture could not recover through its unique exact-name endpoint'
pass 'tmux rollback refuses a restart-reused id before endpoint or lease mutation'

make_brief "$HOME_A" rollback-cmux-duplicates
cmux_duplicate_event_before=$(wc -l < "$EVENT_LOG" | tr -d ' ')
if FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_CMUX_DUPLICATE_BEFORE_FAILURE=1 \
  run_spawn "$HOME_A" rollback-cmux-duplicates "$WT1" --backend cmux >/dev/null 2>&1; then
  fail 'cmux rollback accepted duplicate exact task titles'
fi
CMUX_ROLLBACK_META="$HOME_A/state/rollback-cmux-duplicates.meta"
CMUX_ROLLBACK_RECEIPT="$HOME_A/state/.rollback-cmux-duplicates.treehouse-lease-acquire.json"
backend_endpoint_is_live cmux 22222222-2222-2222-2222-222222222231 \
  || fail 'cmux rollback duplicate-title ambiguity closed the first workspace'
backend_endpoint_is_live cmux 22222222-2222-2222-2222-222222222232 \
  || fail 'cmux rollback duplicate-title ambiguity closed the second workspace'
tail -n "+$((cmux_duplicate_event_before + 1))" "$EVENT_LOG" > "$WORLD/rollback-cmux-duplicates.events"
if grep -Fq 'cmux close-workspace --workspace ' "$WORLD/rollback-cmux-duplicates.events"; then
  fail 'cmux rollback mutated a workspace before unique all-window correlation'
fi
assert_present "$CMUX_ROLLBACK_META" 'cmux duplicate rollback erased exact lease metadata'
assert_present "$CMUX_ROLLBACK_RECEIPT" 'cmux duplicate rollback erased acquisition evidence'
grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE" \
  || fail 'cmux duplicate rollback returned the ambiguous lease'
backend_endpoint_remove cmux 22222222-2222-2222-2222-222222222232
run_teardown_force "$HOME_A" rollback-cmux-duplicates >/dev/null \
  || fail 'cmux duplicate rollback fixture could not recover after becoming unique'
pass 'cmux rollback requires one unique all-window title before mutation'

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
  if [ "$backend" = tmux ]; then
    awk -F '\t' -v identity="$identity" -v name="fm-$id" \
      'BEGIN {OFS="\t"} {if ($1 == identity) $3=name; print}' \
      "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
    mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
  fi
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
  if [ "$backend" = tmux ]; then
    tasktmp_identity=$(sed -n 's/^tasktmp=//p' "$meta")
    busy_gen_identity=$(sed -n 's/^busy_gen=//p' "$meta")
    printf '%s\n' \
      'pr=https://example.test/pull/42' \
      'pr_head=0123456789abcdef' \
      'x_request=req-preserve' \
      'x_request_ts=1700000000' \
      'x_followups=1' \
      'traceparent=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01' \
      >> "$meta"
  fi
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
  if [ "$backend" = tmux ]; then
    assert_grep 'pr=https://example.test/pull/42' "$meta" 'recovered rollback erased pr metadata'
    assert_grep 'pr_head=0123456789abcdef' "$meta" 'recovered rollback erased pr_head metadata'
    assert_grep 'x_request=req-preserve' "$meta" 'recovered rollback erased x_request metadata'
    assert_grep 'x_request_ts=1700000000' "$meta" 'recovered rollback erased x_request_ts metadata'
    assert_grep 'x_followups=1' "$meta" 'recovered rollback erased x_followups metadata'
    assert_grep 'traceparent=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01' "$meta" \
      'recovered rollback erased traceparent metadata'
    [ "$(sed -n 's/^tasktmp=//p' "$meta")" = "$tasktmp_identity" ] \
      || fail 'recovered rollback changed tasktmp metadata'
    [ "$(sed -n 's/^busy_gen=//p' "$meta")" = "$busy_gen_identity" ] \
      || fail 'recovered rollback changed busy_gen metadata'
    awk -F '\t' -v identity="$new_identity" -v name="fm-$id" \
      'BEGIN {OFS="\t"} {if ($1 == identity) $3=name; print}' \
      "$TMUX_WINDOWS" > "$TMUX_WINDOWS.tmp"
    mv "$TMUX_WINDOWS.tmp" "$TMUX_WINDOWS"
  fi
  run_teardown_force "$HOME_A" "$id" >/dev/null \
    || fail "$backend replacement recovery could not be torn down exactly"
done
pass 'recovered leases preserve durable metadata and replacement endpoint identity'

make_brief "$HOME_A" metadata-owner-race
run_spawn "$HOME_A" metadata-owner-race "$WT1" --backend tmux >/dev/null \
  || fail 'metadata owner race fixture could not publish its first endpoint'
METADATA_RACE_META="$HOME_A/state/metadata-owner-race.meta"
metadata_race_old=$(sed -n 's/^tmux_window_id=//p' "$METADATA_RACE_META")
backend_endpoint_remove tmux "$metadata_race_old"
METADATA_RACE_READY="$WORLD/metadata-owner-race.ready"
METADATA_RACE_RELEASE="$WORLD/metadata-owner-race.release"
FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_TMUX_KILL_FAIL=1 \
  FM_FAKE_BLOCK_BEFORE_META_PUBLISH=1 FM_FAKE_PUBLISH_ID=metadata-owner-race \
  FM_FAKE_PUBLISH_READY="$METADATA_RACE_READY" FM_FAKE_PUBLISH_RELEASE="$METADATA_RACE_RELEASE" \
  run_spawn "$HOME_A" metadata-owner-race "$WT1" --backend tmux \
  >"$WORLD/metadata-owner-race.spawn.out" 2>"$WORLD/metadata-owner-race.spawn.err" &
metadata_race_spawn_pid=$!
i=0
while [ ! -e "$METADATA_RACE_READY" ] && [ "$i" -lt 100 ]; do
  "$FM_REAL_SLEEP" 0.05
  i=$((i + 1))
done
assert_present "$METADATA_RACE_READY" 'recovery publication did not reach its metadata mutation barrier'
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_A" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-x-link.sh" metadata-owner-race req-concurrent \
    --carry-count 2 --carry-ts 1700000000 --carry-platform x --carry-max 280 \
  >"$WORLD/metadata-owner-race.x.out" 2>"$WORLD/metadata-owner-race.x.err" &
metadata_race_x_pid=$!
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_A" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-pr-check.sh" metadata-owner-race https://github.com/example/project/pull/42 \
  >"$WORLD/metadata-owner-race.pr.out" 2>"$WORLD/metadata-owner-race.pr.err" &
metadata_race_pr_pid=$!
"$FM_REAL_SLEEP" 0.2
kill -0 "$metadata_race_x_pid" 2>/dev/null \
  || fail 'X metadata writer bypassed the active task metadata mutation lock'
kill -0 "$metadata_race_pr_pid" 2>/dev/null \
  || fail 'PR metadata writer bypassed the active task metadata mutation lock'
: > "$METADATA_RACE_RELEASE"
if wait "$metadata_race_spawn_pid"; then
  fail 'metadata owner race spawn unexpectedly survived its late failure'
fi
wait "$metadata_race_x_pid" \
  || fail "X metadata writer failed after recovery publication\n$(cat "$WORLD/metadata-owner-race.x.err")"
wait "$metadata_race_pr_pid" \
  || fail "PR metadata writer failed after recovery publication\n$(cat "$WORLD/metadata-owner-race.pr.err")"
metadata_race_new=$(sed -n 's/^tmux_window_id=//p' "$METADATA_RACE_META")
[ -n "$metadata_race_new" ] && [ "$metadata_race_new" != "$metadata_race_old" ] \
  || fail 'concurrent metadata writers restored stale endpoint identity'
assert_grep 'x_request=req-concurrent' "$METADATA_RACE_META" 'recovery lost concurrent X metadata'
assert_grep 'x_followups=2' "$METADATA_RACE_META" 'recovery lost concurrent X follow-up state'
assert_grep 'pr=https://github.com/example/project/pull/42' "$METADATA_RACE_META" \
  'recovery lost concurrent PR metadata'
run_teardown_force "$HOME_A" metadata-owner-race >/dev/null \
  || fail 'metadata owner race fixture could not be torn down exactly'
pass 'task lifecycle lock serializes recovery, PR, and X metadata owners'

make_brief "$HOME_A" recovery-publish-failure
run_spawn "$HOME_A" recovery-publish-failure "$WT1" --backend tmux >/dev/null \
  || fail 'recovery publication failure fixture could not publish its first endpoint'
RECOVERY_FAILURE_META="$HOME_A/state/recovery-publish-failure.meta"
recovery_failure_old=$(sed -n 's/^tmux_window_id=//p' "$RECOVERY_FAILURE_META")
backend_endpoint_remove tmux "$recovery_failure_old"
if FM_FAKE_CURRENT_PATH_FAIL=1 FM_FAKE_TMUX_KILL_FAIL=1 \
  FM_FAKE_RECOVERY_PUBLISH_FAIL=1 FM_FAKE_PUBLISH_ID=recovery-publish-failure \
  run_spawn "$HOME_A" recovery-publish-failure "$WT1" --backend tmux \
  >"$WORLD/recovery-publish-failure.out" 2>"$WORLD/recovery-publish-failure.err"; then
  fail 'recovery publication failure fixture unexpectedly succeeded'
fi
set -- "$HOME_A/state/.recovery-publish-failure.meta.lease-recovery."*
[ "$#" -eq 1 ] && [ -f "$1" ] \
  || fail 'failed recovery publication did not retain one exact temporary evidence record'
RECOVERY_FAILURE_TMP=$1
assert_grep "recovery evidence remains at $RECOVERY_FAILURE_TMP" "$WORLD/recovery-publish-failure.err" \
  'failed recovery publication did not report its actionable evidence path'
assert_grep 'treehouse_lease_recovery=spawn-rollback-failed' "$RECOVERY_FAILURE_TMP" \
  'temporary recovery evidence omitted its recovery state'
recovery_failure_new=$(sed -n 's/^tmux_window_id=//p' "$RECOVERY_FAILURE_TMP")
[ -n "$recovery_failure_new" ] && [ "$recovery_failure_new" != "$recovery_failure_old" ] \
  || fail 'temporary recovery evidence did not bind the surviving replacement endpoint'
backend_endpoint_is_live tmux "$recovery_failure_new" \
  || fail 'failed recovery publication lost its surviving replacement endpoint'
grep -Fq "$WT1"$'\t' "$TREEHOUSE_STATE" \
  || fail 'failed recovery publication returned the held lease'
"$FM_REAL_MV" -f -- "$RECOVERY_FAILURE_TMP" "$RECOVERY_FAILURE_META"
run_teardown_force "$HOME_A" recovery-publish-failure >/dev/null \
  || fail 'recovery publication failure fixture could not reconcile exact retained evidence'
pass 'recovery publication failure retains and reports exact temporary evidence'

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

make_brief "$HOME_A" lifecycle-order
run_spawn "$HOME_A" lifecycle-order "$WT1" --backend tmux >/dev/null \
  || fail 'lifecycle ordering fixture could not publish its first endpoint'
LIFECYCLE_META="$HOME_A/state/lifecycle-order.meta"
lifecycle_old_identity=$(sed -n 's/^tmux_window_id=//p' "$LIFECYCLE_META")
backend_endpoint_remove tmux "$lifecycle_old_identity"
LIFECYCLE_READY="$WORLD/lifecycle-publish.ready"
LIFECYCLE_RELEASE="$WORLD/lifecycle-publish.release"
FM_FAKE_BLOCK_BEFORE_META_PUBLISH=1 FM_FAKE_PUBLISH_ID=lifecycle-order \
  FM_FAKE_PUBLISH_READY="$LIFECYCLE_READY" FM_FAKE_PUBLISH_RELEASE="$LIFECYCLE_RELEASE" \
  run_spawn "$HOME_A" lifecycle-order "$WT1" --backend tmux \
  >"$WORLD/lifecycle-spawn.out" 2>"$WORLD/lifecycle-spawn.err" &
lifecycle_spawn_pid=$!
i=0
while [ ! -f "$LIFECYCLE_READY" ] && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -f "$LIFECYCLE_READY" ] || fail 'replacement spawn did not reach its guarded publication boundary'
lifecycle_returns_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
run_teardown_force "$HOME_A" lifecycle-order \
  >"$WORLD/lifecycle-teardown.out" 2>"$WORLD/lifecycle-teardown.err" &
lifecycle_teardown_pid=$!
sleep 0.2
lifecycle_returns_held=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$lifecycle_returns_held" -eq "$lifecycle_returns_before" ] \
  || fail 'teardown returned the lease while replacement publication held the task lifecycle'
kill -0 "$lifecycle_teardown_pid" 2>/dev/null \
  || fail 'teardown did not wait for replacement publication to release the task lifecycle'
: > "$LIFECYCLE_RELEASE"
wait "$lifecycle_spawn_pid" \
  || fail "replacement spawn failed after lifecycle release\n$(cat "$WORLD/lifecycle-spawn.err")"
wait "$lifecycle_teardown_pid" \
  || fail "teardown failed after replacement publication\n$(cat "$WORLD/lifecycle-teardown.err")"
lifecycle_publish_line=$(grep -n '^metadata-published lifecycle-order$' "$EVENT_LOG" | tail -1 | cut -d: -f1)
lifecycle_return_line=$(grep -n '^treehouse return --force ' "$EVENT_LOG" | tail -1 | cut -d: -f1)
[ -n "$lifecycle_publish_line" ] && [ -n "$lifecycle_return_line" ] \
  || fail 'lifecycle ordering did not record publication and conditional return'
[ "$lifecycle_publish_line" -lt "$lifecycle_return_line" ] \
  || fail 'teardown returned the lease before replacement metadata publication completed'
assert_absent "$LIFECYCLE_META" 'ordered teardown retained replacement task metadata'
pass 'replacement publication and exact lease return serialize on one task lifecycle'

RETIRE_HOME="$WORLD/retiring-secondmate"
make_secondmate_retirement_fixture "$RETIRE_HOME" retire-admission
make_brief "$RETIRE_HOME" held-child
run_spawn "$RETIRE_HOME" held-child "$WT1" --backend tmux >/dev/null \
  || fail 'retirement admission fixture could not publish its child'
RETIRE_LOCK_READY="$WORLD/retire-child-lock.ready"
RETIRE_LOCK_RELEASE="$WORLD/retire-child-lock.release"
hold_task_lifecycle_lock "$RETIRE_HOME/state/.spawn-held-child.lock" \
  "$RETIRE_LOCK_READY" "$RETIRE_LOCK_RELEASE"
i=0
while [ ! -f "$RETIRE_LOCK_READY" ] && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -f "$RETIRE_LOCK_READY" ] || fail 'retirement fixture did not hold the existing child lifecycle'
run_teardown "$HOME_A" retire-admission \
  >"$WORLD/retire-admission.out" 2>"$WORLD/retire-admission.err" &
retire_pid=$!
RETIRE_MARKER="$RETIRE_HOME/state/.secondmate-retiring"
"$FM_REAL_SLEEP" 0.2
assert_absent "$RETIRE_MARKER" 'refusal-prone retirement published a durable admission barrier'
make_brief "$RETIRE_HOME" admitted-child
retire_admitted_path=$(next_treehouse_path) \
  || fail 'retirement admission fixture had no free Treehouse path'
retire_gets_before=$(grep -c '^get ' "$TREEHOUSE_LOG")
run_spawn "$RETIRE_HOME" admitted-child "$retire_admitted_path" --backend tmux \
  >"$WORLD/admitted-child.out" 2>"$WORLD/admitted-child.err" &
retire_admitted_pid=$!
"$FM_REAL_SLEEP" 0.2
retire_gets_after=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$retire_gets_after" -eq "$retire_gets_before" ] \
  || fail 'child launch passed home admission during retirement preflight'
kill -0 "$retire_admitted_pid" 2>/dev/null \
  || fail 'child admission did not wait for retirement preflight'
: > "$RETIRE_LOCK_RELEASE"
wait "$HELD_LOCK_PID" || fail 'held child lifecycle lock did not release cleanly'
if wait "$retire_pid"; then
  fail 'ordinary secondmate retirement unexpectedly discarded active child work'
fi
assert_absent "$RETIRE_MARKER" 'ordinary retirement refusal permanently drained the secondmate home'
wait "$retire_admitted_pid" \
  || fail "child admission did not resume after ordinary refusal\n$(cat "$WORLD/admitted-child.err")"
assert_present "$RETIRE_HOME/state/admitted-child.meta" \
  'resumed child admission did not publish after retirement refusal'
run_teardown_force "$HOME_A" retire-admission \
  >"$WORLD/retire-admission-retry.out" 2>"$WORLD/retire-admission-retry.err" \
  || fail "forced retirement retry failed\n$(cat "$WORLD/retire-admission-retry.err")"
assert_absent "$RETIRE_HOME" 'completed secondmate retirement retained its home'
pass 'secondmate refusal releases admission and allows a guarded retirement retry'

RETIRE_AMBIGUOUS_HOME="$WORLD/retiring-ambiguous-secondmate"
make_secondmate_retirement_fixture "$RETIRE_AMBIGUOUS_HOME" retire-ambiguous
make_brief "$RETIRE_AMBIGUOUS_HOME" ambiguous-child
retire_ambiguous_path=$(next_treehouse_path) \
  || fail 'ambiguous retirement fixture had no free Treehouse path'
run_spawn "$RETIRE_AMBIGUOUS_HOME" ambiguous-child "$retire_ambiguous_path" --backend tmux >/dev/null \
  || fail 'ambiguous retirement fixture could not publish its child'
RETIRE_AMBIGUOUS_META="$RETIRE_AMBIGUOUS_HOME/state/ambiguous-child.meta"
retire_ambiguous_lease=$(sed -n 's/^treehouse_lease_id=//p' "$RETIRE_AMBIGUOUS_META")
RETIRE_AMBIGUOUS_MARKER="$RETIRE_AMBIGUOUS_HOME/state/.secondmate-retiring"
if FM_FAKE_RETURN_FAIL_ID="$retire_ambiguous_lease" \
  run_teardown_force "$HOME_A" retire-ambiguous \
    >"$WORLD/retire-ambiguous.out" 2>"$WORLD/retire-ambiguous.err"; then
  fail 'ambiguous forced retirement unexpectedly completed'
fi
assert_present "$RETIRE_AMBIGUOUS_MARKER" \
  'ambiguous destructive retirement did not preserve its durable admission barrier'
assert_present "$RETIRE_AMBIGUOUS_META" \
  'ambiguous destructive retirement erased child lease identity'
grep -Fq "$retire_ambiguous_path"$'\t'"$retire_ambiguous_lease"$'\t' "$TREEHOUSE_STATE" \
  || fail 'ambiguous destructive retirement released or lost the child lease'
make_brief "$RETIRE_AMBIGUOUS_HOME" blocked-after-progress
retire_ambiguous_gets_before=$(grep -c '^get ' "$TREEHOUSE_LOG")
if run_spawn "$RETIRE_AMBIGUOUS_HOME" blocked-after-progress "$WT2" --backend tmux \
  >"$WORLD/blocked-after-progress.out" 2>"$WORLD/blocked-after-progress.err"; then
  fail 'child launch passed admission after ambiguous destructive retirement'
fi
retire_ambiguous_gets_after=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$retire_ambiguous_gets_after" -eq "$retire_ambiguous_gets_before" ] \
  || fail 'retirement barrier allowed a new Treehouse acquisition after ambiguous progress'
printf '@ambiguous-child-recovery\tfirstmate\tfm-ambiguous-child\n' >> "$TMUX_WINDOWS"
run_teardown_force "$HOME_A" retire-ambiguous \
  >"$WORLD/retire-ambiguous-retry.out" 2>"$WORLD/retire-ambiguous-retry.err" \
  || fail "ambiguous retirement retry failed\n$(cat "$WORLD/retire-ambiguous-retry.err")"
assert_absent "$RETIRE_AMBIGUOUS_HOME" 'ambiguous retirement retry retained its home'
pass 'ambiguous retirement preserves its barrier and exact child identity'

RETIRE_REMOVAL_HOME="$WORLD/retiring-removal-secondmate"
RETIRE_RECYCLE_TEMPLATE="$WORLD/retiring-removal-recycled"
make_secondmate_retirement_fixture "$RETIRE_REMOVAL_HOME" retire-removal
RETIRE_REMOVAL_HOME_CANON=$(cd "$RETIRE_REMOVAL_HOME" && pwd -P) \
  || fail 'removal-race fixture home could not be canonicalized'
make_brief "$RETIRE_REMOVAL_HOME" removal-held
retire_removal_held_path=$(next_treehouse_path) \
  || fail 'removal-race fixture had no Treehouse path for its held child'
run_spawn "$RETIRE_REMOVAL_HOME" removal-held "$retire_removal_held_path" --backend tmux >/dev/null \
  || fail 'removal-race fixture could not publish its held child'
mkdir -p "$RETIRE_RECYCLE_TEMPLATE/data/removal-waiter" \
  "$RETIRE_RECYCLE_TEMPLATE/data/removal-fresh" \
  "$RETIRE_RECYCLE_TEMPLATE/state" "$RETIRE_RECYCLE_TEMPLATE/config" \
  "$RETIRE_RECYCLE_TEMPLATE/projects"
printf 'off\n' > "$RETIRE_RECYCLE_TEMPLATE/config/herdr-presentation-spaces"
printf 'lease test for removal-waiter\nDelivery contract: mode=no-mistakes\n' \
  > "$RETIRE_RECYCLE_TEMPLATE/data/removal-waiter/brief.md"
printf 'lease test for removal-fresh\nDelivery contract: mode=no-mistakes\n' \
  > "$RETIRE_RECYCLE_TEMPLATE/data/removal-fresh/brief.md"
RETIRE_REMOVAL_LOCK_READY="$WORLD/retire-removal-child-lock.ready"
RETIRE_REMOVAL_LOCK_RELEASE="$WORLD/retire-removal-child-lock.release"
hold_task_lifecycle_lock "$RETIRE_REMOVAL_HOME/state/.spawn-removal-held.lock" \
  "$RETIRE_REMOVAL_LOCK_READY" "$RETIRE_REMOVAL_LOCK_RELEASE"
i=0
while [ ! -f "$RETIRE_REMOVAL_LOCK_READY" ] && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -f "$RETIRE_REMOVAL_LOCK_READY" ] \
  || fail 'removal-race fixture did not hold its child lifecycle'
RETIRE_REMOVE_READY="$WORLD/retire-remove.ready"
RETIRE_REMOVE_RELEASE="$WORLD/retire-remove.release"
FM_FAKE_REMOVE_HOME="$RETIRE_REMOVAL_HOME_CANON" \
  FM_FAKE_RECYCLE_TEMPLATE="$RETIRE_RECYCLE_TEMPLATE" \
  FM_FAKE_REMOVE_READY="$RETIRE_REMOVE_READY" \
  FM_FAKE_REMOVE_RELEASE="$RETIRE_REMOVE_RELEASE" \
  run_teardown_force "$HOME_A" retire-removal \
    >"$WORLD/retire-removal.out" 2>"$WORLD/retire-removal.err" &
retire_removal_pid=$!
"$FM_REAL_SLEEP" 0.2
retire_removal_waiter_path=$(next_treehouse_path) \
  || fail 'removal-race fixture had no Treehouse path for its waiting child'
retire_removal_gets_before=$(grep -c '^get ' "$TREEHOUSE_LOG")
run_spawn "$RETIRE_REMOVAL_HOME" removal-waiter "$retire_removal_waiter_path" --backend tmux \
  >"$WORLD/removal-waiter.out" 2>"$WORLD/removal-waiter.err" &
retire_removal_waiter_pid=$!
"$FM_REAL_SLEEP" 0.2
retire_removal_gets_waiting=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$retire_removal_gets_waiting" -eq "$retire_removal_gets_before" ] \
  || fail 'waiting child acquired a lease during removal preflight'
kill -STOP "$retire_removal_waiter_pid"
: > "$RETIRE_REMOVAL_LOCK_RELEASE"
wait "$HELD_LOCK_PID" || fail 'removal-race held child lifecycle did not release cleanly'
i=0
while [ ! -f "$RETIRE_REMOVE_READY" ] && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -f "$RETIRE_REMOVE_READY" ] || fail 'secondmate removal did not reach recycled-home boundary'
kill -CONT "$retire_removal_waiter_pid"
"$FM_REAL_SLEEP" 0.2
if wait "$retire_removal_waiter_pid"; then
  fail 'pre-removal child launch entered the recycled secondmate home'
fi
retire_removal_gets_held=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$retire_removal_gets_held" -eq "$retire_removal_gets_before" ] \
  || fail 'waiting child acquired from a recycled home before retirement released admission'
run_spawn "$RETIRE_REMOVAL_HOME" removal-fresh "$retire_removal_waiter_path" --backend tmux \
  >"$WORLD/removal-fresh.out" 2>"$WORLD/removal-fresh.err" &
retire_removal_fresh_pid=$!
"$FM_REAL_SLEEP" 0.2
if wait "$retire_removal_fresh_pid"; then
  fail 'recycled-home launch escaped the admission barrier during removal'
fi
retire_removal_gets_fresh=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$retire_removal_gets_fresh" -eq "$retire_removal_gets_before" ] \
  || fail 'recycled-home launch acquired a lease while removal retained admission'
: > "$RETIRE_REMOVE_RELEASE"
wait "$retire_removal_pid" \
  || fail "secondmate removal race teardown failed\n$(cat "$WORLD/retire-removal.err")"
retire_removal_gets_after=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$retire_removal_gets_after" -eq "$retire_removal_gets_before" ] \
  || fail 'pre-removal child launch acquired a lease from the recycled home'
for retirement_sibling in "$WORLD"/.fm-secondmate-retirement-*; do
  [ ! -e "$retirement_sibling" ] && [ ! -L "$retirement_sibling" ] \
    || fail 'secondmate retirement wrote lifecycle data beside a Treehouse-managed home'
done
"$FM_REAL_RM" -rf -- "$RETIRE_REMOVAL_HOME"
pass 'secondmate admission barrier survives removal and rejects stale waiters'

RETIRE_MISSING_HOME="$WORLD/retiring-missing-state-secondmate"
RETIRE_MISSING_TEMPLATE="$WORLD/retiring-missing-state-recycled"
make_secondmate_retirement_fixture "$RETIRE_MISSING_HOME" retire-missing-state
RETIRE_MISSING_HOME_CANON=$(cd "$RETIRE_MISSING_HOME" && pwd -P) \
  || fail 'missing-state fixture home could not be canonicalized'
"$FM_REAL_RM" -rf -- "$RETIRE_MISSING_HOME/state"
mkdir -p "$RETIRE_MISSING_TEMPLATE/data/missing-state-fresh" \
  "$RETIRE_MISSING_TEMPLATE/config" "$RETIRE_MISSING_TEMPLATE/projects"
printf 'off\n' > "$RETIRE_MISSING_TEMPLATE/config/herdr-presentation-spaces"
printf 'lease test for missing-state-fresh\nDelivery contract: mode=no-mistakes\n' \
  > "$RETIRE_MISSING_TEMPLATE/data/missing-state-fresh/brief.md"
RETIRE_MISSING_READY="$WORLD/retire-missing.ready"
RETIRE_MISSING_RELEASE="$WORLD/retire-missing.release"
FM_FAKE_REMOVE_HOME="$RETIRE_MISSING_HOME_CANON" \
  FM_FAKE_RECYCLE_TEMPLATE="$RETIRE_MISSING_TEMPLATE" \
  FM_FAKE_REMOVE_READY="$RETIRE_MISSING_READY" \
  FM_FAKE_REMOVE_RELEASE="$RETIRE_MISSING_RELEASE" \
  run_teardown_force "$HOME_A" retire-missing-state \
    >"$WORLD/retire-missing.out" 2>"$WORLD/retire-missing.err" &
retire_missing_pid=$!
i=0
while [ ! -f "$RETIRE_MISSING_READY" ] && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -f "$RETIRE_MISSING_READY" ] \
  || fail 'missing-state retirement did not reach its recycled-home boundary'
retire_missing_gets_before=$(grep -c '^get ' "$TREEHOUSE_LOG")
run_spawn "$RETIRE_MISSING_HOME" missing-state-fresh "$WT1" --backend tmux \
  >"$WORLD/missing-state-fresh.out" 2>"$WORLD/missing-state-fresh.err" &
retire_missing_fresh_pid=$!
"$FM_REAL_SLEEP" 0.2
if wait "$retire_missing_fresh_pid"; then
  fail 'missing state or home marker bypassed external retirement admission'
fi
retire_missing_gets_after=$(grep -c '^get ' "$TREEHOUSE_LOG")
[ "$retire_missing_gets_after" -eq "$retire_missing_gets_before" ] \
  || fail 'missing state or home marker allowed Treehouse acquisition during removal'
: > "$RETIRE_MISSING_RELEASE"
wait "$retire_missing_pid" \
  || fail "missing-state retirement failed\n$(cat "$WORLD/retire-missing.err")"
"$FM_REAL_RM" -rf -- "$RETIRE_MISSING_HOME"
pass 'missing state and marker cannot bypass external retirement admission'

RETIRE_REPLACEMENT_HOME="$WORLD/retiring-replacement-secondmate"
make_secondmate_retirement_fixture "$RETIRE_REPLACEMENT_HOME" retire-replacement
make_brief "$RETIRE_REPLACEMENT_HOME" replacing-child
run_spawn "$RETIRE_REPLACEMENT_HOME" replacing-child "$WT1" --backend tmux >/dev/null \
  || fail 'retirement replacement fixture could not publish its child'
RETIRE_REPLACEMENT_META="$RETIRE_REPLACEMENT_HOME/state/replacing-child.meta"
retire_old_identity=$(sed -n 's/^tmux_window_id=//p' "$RETIRE_REPLACEMENT_META")
backend_endpoint_remove tmux "$retire_old_identity"
RETIRE_REPLACEMENT_READY="$WORLD/retire-replacement.ready"
RETIRE_REPLACEMENT_RELEASE="$WORLD/retire-replacement.release"
FM_FAKE_BLOCK_BEFORE_META_PUBLISH=1 FM_FAKE_PUBLISH_ID=replacing-child \
  FM_FAKE_PUBLISH_READY="$RETIRE_REPLACEMENT_READY" \
  FM_FAKE_PUBLISH_RELEASE="$RETIRE_REPLACEMENT_RELEASE" \
  run_spawn "$RETIRE_REPLACEMENT_HOME" replacing-child "$WT1" --backend tmux \
  >"$WORLD/retire-replacement-spawn.out" 2>"$WORLD/retire-replacement-spawn.err" &
retire_replacement_spawn_pid=$!
i=0
while [ ! -f "$RETIRE_REPLACEMENT_READY" ] && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -f "$RETIRE_REPLACEMENT_READY" ] \
  || fail 'child replacement did not reach its guarded publication boundary'
retire_replacement_returns_before=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
run_teardown_force "$HOME_A" retire-replacement \
  >"$WORLD/retire-replacement.out" 2>"$WORLD/retire-replacement.err" &
retire_replacement_pid=$!
RETIRE_REPLACEMENT_MARKER="$RETIRE_REPLACEMENT_HOME/state/.secondmate-retiring"
"$FM_REAL_SLEEP" 0.2
assert_absent "$RETIRE_REPLACEMENT_MARKER" \
  'replacement retirement committed before child publication preflight completed'
retire_replacement_returns_held=$(grep -c '^return ' "$TREEHOUSE_LOG" || true)
[ "$retire_replacement_returns_held" -eq "$retire_replacement_returns_before" ] \
  || fail 'forced secondmate cleanup returned a child lease during replacement publication'
assert_present "$RETIRE_REPLACEMENT_META" \
  'forced secondmate cleanup erased child metadata during replacement publication'
: > "$RETIRE_REPLACEMENT_RELEASE"
wait "$retire_replacement_spawn_pid" \
  || fail "child replacement failed after publication release\n$(cat "$WORLD/retire-replacement-spawn.err")"
wait "$retire_replacement_pid" \
  || fail "forced secondmate cleanup failed after replacement publication\n$(cat "$WORLD/retire-replacement.err")"
retire_replacement_publish_line=$(grep -n '^metadata-published replacing-child$' "$EVENT_LOG" | tail -1 | cut -d: -f1)
retire_replacement_return_line=$(grep -n '^treehouse return --force ' "$EVENT_LOG" | tail -1 | cut -d: -f1)
[ -n "$retire_replacement_publish_line" ] && [ -n "$retire_replacement_return_line" ] \
  || fail 'secondmate replacement ordering did not record publication and return'
[ "$retire_replacement_publish_line" -lt "$retire_replacement_return_line" ] \
  || fail 'forced secondmate cleanup returned the child lease before replacement publication'
assert_absent "$RETIRE_REPLACEMENT_HOME" 'replacement cleanup retained the retired secondmate home'
pass 'forced secondmate cleanup retains child lifecycle ownership through exact return'

for backend in tmux herdr zellij cmux; do
  parent_id="retire-surviving-$backend"
  child_id="surviving-$backend"
  retire_surviving_home="$WORLD/retiring-surviving-$backend"
  make_secondmate_retirement_fixture "$retire_surviving_home" "$parent_id"
  make_brief "$retire_surviving_home" "$child_id"
  retire_surviving_path=$(next_treehouse_path) \
    || fail "$backend surviving-endpoint fixture had no free Treehouse path"
  run_spawn "$retire_surviving_home" "$child_id" "$retire_surviving_path" --backend "$backend" >/dev/null \
    || fail "$backend surviving-endpoint fixture could not publish its child"
  retire_surviving_meta="$retire_surviving_home/state/$child_id.meta"
  retire_surviving_field=$(backend_endpoint_meta_field "$backend")
  retire_surviving_identity=$(sed -n "s/^$retire_surviving_field=//p" "$retire_surviving_meta")
  retire_surviving_lease=$(sed -n 's/^treehouse_lease_id=//p' "$retire_surviving_meta")
  case "$backend" in
    zellij|cmux)
      retire_surviving_title=$(secondmate_backend_title "$backend" "$retire_surviving_home" "$child_id")
      awk -F '\t' -v backend="$backend" -v identity="$retire_surviving_identity" -v title="$retire_surviving_title" \
        'BEGIN {OFS="\t"} {if ($1 == backend && ($2 == identity || $3 == identity)) $4=title; print}' \
        "$ENDPOINT_STATE" > "$ENDPOINT_STATE.tmp"
      mv "$ENDPOINT_STATE.tmp" "$ENDPOINT_STATE"
      ;;
  esac
  case "$backend" in
    tmux)
      FM_FAKE_TMUX_KILL_FAIL=1 run_teardown_force "$HOME_A" "$parent_id" \
        >"$WORLD/$parent_id.out" 2>"$WORLD/$parent_id.err" && \
        fail 'forced secondmate cleanup accepted a surviving tmux endpoint'
      ;;
    herdr)
      FM_FAKE_HERDR_KILL_AMBIGUOUS=1 run_teardown_force "$HOME_A" "$parent_id" \
        >"$WORLD/$parent_id.out" 2>"$WORLD/$parent_id.err" && \
        fail 'forced secondmate cleanup accepted a surviving Herdr endpoint'
      ;;
    zellij)
      FM_FAKE_ZELLIJ_KILL_AMBIGUOUS=1 run_teardown_force "$HOME_A" "$parent_id" \
        >"$WORLD/$parent_id.out" 2>"$WORLD/$parent_id.err" && \
        fail 'forced secondmate cleanup accepted a surviving Zellij endpoint'
      ;;
    cmux)
      FM_FAKE_CMUX_KILL_AMBIGUOUS=1 run_teardown_force "$HOME_A" "$parent_id" \
        >"$WORLD/$parent_id.out" 2>"$WORLD/$parent_id.err" && \
        fail 'forced secondmate cleanup accepted a surviving cmux endpoint'
      ;;
  esac
  assert_present "$retire_surviving_meta" \
    "$backend surviving endpoint cleanup erased child identity evidence"
  backend_endpoint_is_live "$backend" "$retire_surviving_identity" \
    || fail "$backend surviving endpoint cleanup lost the endpoint it could not confirm absent"
  grep -Fq "$retire_surviving_path"$'\t'"$retire_surviving_lease"$'\t' "$TREEHOUSE_STATE" \
    || fail "$backend surviving endpoint cleanup returned or lost the child lease"
  run_teardown_force "$HOME_A" "$parent_id" >/dev/null \
    || fail "$backend surviving-endpoint retirement retry failed"
  assert_absent "$retire_surviving_home" \
    "$backend surviving-endpoint retirement retry retained its secondmate home"
done
pass 'forced secondmate cleanup confirms every backend endpoint absent before lease return'

make_brief "$HOME_A" acquisition-handoff
acquisition_handoff_counter_before=$(cat "$TREEHOUSE_COUNTER")
if FM_FAKE_TERM_AFTER_GET=1 run_spawn "$HOME_A" acquisition-handoff "$WT4" >/dev/null 2>&1; then
  fail 'spawn unexpectedly completed after post-acquisition termination'
fi
acquisition_handoff_lease="lease-$((acquisition_handoff_counter_before + 1))"
if awk -F '\t' -v lease="$acquisition_handoff_lease" '$2 == lease {found=1} END {exit !found}' "$TREEHOUSE_STATE"; then
  fail 'post-acquisition termination stranded its exact Treehouse lease'
fi
assert_grep "return --force " "$TREEHOUSE_LOG" \
  'post-acquisition termination did not issue an exact conditional return'
assert_grep "--if-lease-id $acquisition_handoff_lease --if-lease-holder firstmate-task:$HOME_A_REAL:acquisition-handoff" \
  "$TREEHOUSE_LOG" 'post-acquisition termination returned a different lease identity'
assert_absent "$HOME_A/state/.acquisition-handoff.treehouse-lease-acquire.json" \
  'post-acquisition termination retained a successfully returned receipt'
assert_absent "$HOME_A/state/acquisition-handoff.meta" \
  'post-acquisition termination invented published task metadata'
pass 'post-acquisition termination returns only its complete exact receipt identity'

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
pass 'partial or malformed acquisition preserves raw evidence and never guesses a lease release'

echo '# all fm-treehouse-task-lease tests passed'
