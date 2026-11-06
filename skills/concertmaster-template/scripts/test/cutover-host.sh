#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2016,SC2034  # check bodies are single-quoted on purpose (eval-ed later); A && pass || fail is if-then-else
# cutover-host.sh (test): the Plugly cutover kit, hermetic. A STUB orca and a STUB plugly answer from fixture files and
# record their argv; the real live-agent.sh, lane-handles.sh, lane-journal.sh and spawn-verify.sh run against a fake
# /proc (CM_PROC_ROOT with CM_TEST=1) that the stubs edit when a terminal is created or closed, so "the agent moved to
# the new terminal" is observed by the same code the fleet uses. CM_HOME, the ledger, the lane files and the
# transcripts live in a temp dir. Synthetic names only.
#
# Each case is its own check:
#   dry run touches nothing (only read verbs in the stub argv log, no ledger/handle/journal/lock write); the plan lists
#   lane, worker, worktree, handle, agent, state, action; the host missing from the plugly host list refuses; a non-claude
#   lane is `manual` and never touched; a duplicate row refuses --apply (and --lane leaves it out); the caller's own
#   terminal is skipped; the happy path (two lanes, in order, exact argv: close by exact handle, create in the same path,
#   banner check, handle rewritten, nudge sent, handover note written BEFORE the close); a busy lane is skipped and the run
#   goes on; a failed banner check rolls back (Orca terminal recreated and verified, plugly terminal closed) and stops; a
#   failed rollback is LANE DOWN (exit 3); a failed close; a nudge with no turn; the census with an orphan exits 1 and lists
#   it; a second run is idempotent; a half-done host finishes the rest; a held lock refuses; --skip-census is refused
#   with --apply outside the test; no-bare-orca.sh passes with the new script.
#   Review fixes (each its own check): a rollback whose plugly close is refused is STRANDED (exit 3), never a second agent
#   next to it; an accepted close with the old agent still running creates nothing; a run whose selected lanes are all
#   manual exits 4, not 0; a ledger model with no banner form is skipped at the plan; --apply on a remote host is refused;
#   a SIGTERM mid-lane journals "interrupted" and exits 3; the rollback re-arms the /loop; resume.sh stands down (exit 4)
#   while a cutover runs; an unusable ledger row is never split into fields.
#   Real fleet (each its own check): the stub orca and plugly answer in the REAL reply shapes (every key of the live runtimes,
#   invented values) and a shape guard compares each reply with its own copy of the real key lists; the model and effort
#   come from the live pane (bare alias and empty ledger model ignored, a disagreeing full ledger model or effort skipped, an
#   unreadable pane skipped and listed under look:, a pane that changed before the close skipped); a remote host's ssh target
#   (bare ledger hostname ignored, address used, CM_SSH_TARGET first, dash and whitespace refused, stub ssh records argv); the
#   real Claude footers ("1 shell", "2 shells", "9 shells", "6 shells, 1 monitor") read BUSY and the bare footer reads idle.
# The Plugly fake processes carry ORCA_TERMINAL_HANDLE (the name live-agent.sh reads); whether Plugly exports that name is
# unproven (references/cutover.md, Limits), so every check that moves a lane assumes it.
# The whole suite runs twice, with no orca or plugly on PATH and with decoys on PATH that must never be called.
#
#   scripts/test/cutover-host.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
if [ -z "${CUTOVER_TEST_MODE:-}" ]; then
  rc=0
  for m in no-cli decoy-cli; do echo "=== PATH mode: $m"; CUTOVER_TEST_MODE="$m" bash "$0" || rc=1; done
  exit "$rc"
fi
MODE="$CUTOVER_TEST_MODE"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-cutover-host.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
# shellcheck disable=SC2154  # _hp is the trap's own loop variable
# hold stand-ins started by the tests are recorded in $ROOT/hold-pids and killed on exit, whatever failed in between
trap 'while read -r _hp; do ps -p "$_hp" -o args= 2>/dev/null | grep -q cutover-host-hold && kill "$_hp" 2>/dev/null; done 2>/dev/null < "$ROOT/hold-pids"; [ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s%s\n' "$1" "${2:+: $2}"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1" "${3:-}"; fi; }

# ---- the PATH: a directory of symlinks to what the scripts need, the stubs first, decoys behind them ----------------------
BIN="$ROOT/bin"; TOOLS="$ROOT/tools"; DECOY="$ROOT/decoy"; mkdir -p "$BIN" "$TOOLS" "$DECOY"
for t in bash env jq python3 awk sed grep cut tr sort head tail wc date mktemp cat rm rmdir mkdir touch ln stat find column readlink \
         uname dirname basename sleep timeout id hostname kill ls mv cp printf tee expr seq sha256sum cmp comm xargs true false perl sh chmod sync yq shellcheck ps setsid flock; do
  tp="$(command -v "$t" 2>/dev/null)" && ln -sf "$tp" "$TOOLS/$t"
done
for d in orca orca-ide orca-dev plugly plugly-dev; do printf '#!/bin/sh\necho "%s $*" >> "%s/decoy.log"\nexit 1\n' "$d" "$ROOT" > "$DECOY/$d"; chmod +x "$DECOY/$d"; done
if [ "$MODE" = decoy-cli ]; then export PATH="$BIN:$DECOY:$TOOLS"; else export PATH="$BIN:$TOOLS"; fi
unset SSH_CONNECTION CM_CLI_KIND CM_ORG CM_REPO CM_PROJECT CM_PATH_MATCH CM_LEDGER CM_LIVE_AGENT CM_LANE_HANDLES CM_SSH_TARGET \
      CM_SSH_EXPECT_HOSTNAME ORCA_TERMINAL_HANDLE PLUGLY_TERMINAL_HANDLE CM_TICK_NUDGE
export HOME="$ROOT/home"; mkdir -p "$HOME/.local/bin"
head -c 120000 /dev/zero > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"   # a claude that resolve accepts (not a stub)
export CM_CONFIG="$HERE/fixtures/config.test.yaml" CM_TEST=1
export ORCA_CLI_COMMAND="$BIN/orca-stub" PLUGLY_CLI_COMMAND="$BIN/plugly-stub"
export CM_CUTOVER_CREATE_GRACE_S=0 CM_CUTOVER_EXIT_WAIT_S=1 CM_CUTOVER_POLL_S=0 CM_CUTOVER_VERIFY_WAIT_S=0 CM_BOOT_CONFIRM_S=1 CM_CUTOVER_CALL_S=30 CM_CUTOVER_TEST=1
CLAUDE_EXPECT="$("$SCRIPTS/spawn-verify.sh" resolve 2>/dev/null)"
case "$CLAUDE_EXPECT" in /*) ;; *) echo "no claude resolved in the test HOME"; exit 1 ;; esac

# ---- the fake /proc helper, shared by the test and the stubs --------------------------------------------------------------
cat > "$BIN/procs.sh" <<'PROCS'
# mkproc <proc root> <pid> <cwd> <terminal handle> <agent>: one fake agent process (live-agent.sh reads these files)
mkproc() {
  local root="$1" pid="$2" cwd="$3" h="$4" agent="$5" d
  d="$root/$pid"; mkdir -p "$d"
  printf '%s (%s) S 1 %s %s 34816 -1 4194560\n' "$pid" "$agent" "$pid" "$pid" > "$d/stat"
  ln -sfn "$cwd" "$d/cwd"
  printf '/usr/local/bin/%s\0' "$agent" > "$d/cmdline"
  printf 'HOME=/home/x\0ORCA_TERMINAL_HANDLE=%s\0' "$h" > "$d/environ"
  printf '%s\n' "$agent" > "$d/comm"
}
# killproc_for <proc root> <handle>: remove every fake process that carries that terminal handle
killproc_for() {
  local root="$1" h="$2" d
  for d in "$root"/[0-9]*; do
    [ -e "$d/environ" ] || continue
    if tr '\0' '\n' < "$d/environ" | grep -qx "ORCA_TERMINAL_HANDLE=$h"; then rm -rf -- "${d:?}"; fi
  done
}
PROCS

# ---- the REAL reply shapes (key sets from a read-only look at live Orca and Plugly runtimes), shared by the stubs and the test -----------
# Every reply is {id, ok, result, _meta}. The values are invented (example ids, /work/example paths); the KEYS are the real ones.
# The shape guard in the test compares against its own copy of the key lists, so a stub cannot drift from the real shape unseen.
cat > "$BIN/shapes.sh" <<'SHAPES'
shape_env() { jq -c --arg id "${REQ_ID:-req-example}" '{id: $id, ok: true, result: ., _meta: {runtimeId: "runtime-example"}}'; }   # stdin: the result object
# shape_hosts <environment name>...: the local machine, then one environment per argument
shape_hosts() {
  jq -cn --args '{hosts: ([{id: "local", kind: "local", machineName: "example-machine", name: "this machine", platform: "linux", selector: "--host local"}]
       + [ $ARGS.positional[] | {id: ("env-" + .), kind: "environment", name: ., selector: ("--environment " + .)} ])}' --args "$@" | shape_env
}
# shape_terminals <path override or "">; stdin: handle<TAB>worktree path<TAB>agent per line. A plain shell has no agentIdentity key.
shape_terminals() {
  jq -Rn --arg wp "${1:-}" '[inputs | select(length > 0) | split("\t") | . as $f
      | {branch: "example/branch", connected: true, executionHostId: "local", handle: $f[0], incarnationId: "incarnation-example",
         lastOutputAt: 1700000000000, leafId: "leaf-example", orphaned: false, preview: "", ptyId: "pty-example", tabId: "tab-example",
         title: "example", worktreeId: "wt-example", worktreePath: (if $wp != "" then $wp else $f[1] end), writable: true}
        + (if ($f[2] // "") != "" then {agentIdentity: $f[2]} else {} end)] as $t
    | {hostScope: {hostIds: ["local"], omittedHostIds: []}, terminals: $t, topologyRevisions: {}, totalCount: ($t | length), truncated: false}' | shape_env
}
# shape_read <handle>; stdin: the screen text
shape_read() {
  jq -Rs --arg h "$1" '(split("\n")) as $l | {terminal: {handle: $h, latestCursor: 0, limited: false, nextCursor: 0, oldestCursor: 0,
      returnedLineCount: ($l | length), source: "screen", status: "ok", tail: $l, tailRows: ($l | length), truncated: false}}' | shape_env
}
# shape_ps <orca|plugly>: one example worktree with every key of that CLI
shape_ps() {
  jq -cn --arg kind "$1" '{agents: [], branch: "example/branch", childWorktreeIds: [], comment: "", createdAt: 1700000000000,
      creatorProvenance: {kind: "example"}, displayName: "example", hasAttachedPty: false, hasHostSidebarActivity: false, hostId: "local", isActive: false,
      isArchived: false, isMainWorktree: false, isPinned: false, lastActivityAt: 1700000000000, lastOutputAt: 1700000000000,
      linkedGitLabIssue: null, linkedGitLabMR: null, linkedIssue: null, linkedLinearIssue: null, linkedPR: null, liveTerminalCount: 0,
      parentWorktreeId: null, path: "/work/example/wt", preview: "", repo: "example/repo", repoId: "repo-example", sortOrder: 0,
      status: "idle", terminalPlatform: "linux", unread: false, workspaceKind: "worktree", workspaceStatus: "active",
      worktreeId: "wt-example", worktreeInstanceId: "wti-example"}
      + (if $kind == "orca" then {defaultBranch: "main", linkedItems: [], terminalVerdict: "ok", unverifiableTerminalCount: 0} else {manualOrder: 0} end)
      | {hostScope: {hostIds: ["local"], omittedHostIds: []}, totalCount: 1, truncated: false, worktrees: [.]}' | shape_env
}
# shape_wtlist: plugly `worktree list`
shape_wtlist() {
  jq -cn '{branch: "example/branch", childWorktreeIds: [], comment: "", displayName: "example", displayNameMode: "fixed", git: {}, head: ([range(40) | "0"] | join("")),
      hostId: "local", id: "wt-example", identity: {}, instanceId: "wti-example", isArchived: false, isBare: false, isMainWorktree: false, isPinned: false,
      isUnread: false, lastActivityAt: 1700000000000, lineage: null, linkedAzureDevOpsPR: null, linkedBitbucketPR: null, linkedGitLabIssue: null,
      linkedGitLabMR: null, linkedGiteaPR: null, linkedIssue: null, linkedLinearIssue: null, linkedLinearIssueOrganizationUrlKey: null,
      linkedLinearIssueWorkspaceId: null, linkedPR: null, linkedTaskSourceContext: null, linkedWorkItem: null, manualOrder: 0,
      parentWorktreeId: null, path: "/work/example/wt", repoId: "repo-example", sortOrder: 0, workspaceStatus: "active"}
      | {hostScope: {hostIds: ["local"], omittedHostIds: []}, totalCount: 1, truncated: false, worktrees: [.]}' | shape_env
}
SHAPES
. "$BIN/shapes.sh"

# ---- the stub CLI: orca-stub and plugly-stub are this one script ---------------------------------------------------------
cat > "$BIN/stub" <<'STUB'
#!/usr/bin/env bash
kind="${0##*/}"; kind="${kind%-stub}"
printf '%s %s\n' "$kind" "$*" >> "$STUB_LOG"
. "$(dirname "$0")/procs.sh"; . "$(dirname "$0")/shapes.sh"
S="$STUB_STATE"; terms="$S/terms.$kind"; touch "$terms"
term=""; wt=""; cmdtxt=""; text=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in --terminal) term="${args[i+1]:-}" ;; --worktree) wt="${args[i+1]:-}" ;; --command) cmdtxt="${args[i+1]:-}" ;; --text) text="${args[i+1]:-}" ;; esac
done
knob() { [ -e "$S/knob/$1.$kind" ]; }
good_pane() { printf 'Sonnet 5.5 with high effort\n\n? for shortcuts\n'; }
# the banner of a terminal follows the command that launched it: --model claude-opus-5-5 --effort max -> "Opus 5.5 with max effort"
launched_pane() {
  local mdl=sonnet-5.5 eff=high
  if [[ "$1" =~ --model[[:space:]]claude-([a-z]+)-([0-9]+)-([0-9]+) ]]; then mdl="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"; fi
  if [[ "$1" =~ --effort[[:space:]]([a-z]+) ]]; then eff="${BASH_REMATCH[1]}"; fi
  printf '%s with %s effort\n\n? for shortcuts\n' "$(printf '%s' "${mdl/-/ }" | sed 's/^./\U&/')" "$eff"
}
case "$1 $2" in
  "host list")
     if [ "$kind" = plugly ]; then cat "$S/hosts.plugly.json"; else shape_hosts; fi ;;
  "worktree ps") shape_ps "$kind" ;;
  "worktree list") if [ "$kind" = plugly ]; then shape_wtlist; else echo '{"ok":true}'; fi ;;
  "terminal list")
     knob list-fails && { echo '{"ok":false}'; exit 1; }
     lc=$(( $(cat "$S/listcount.$kind" 2>/dev/null || echo 0) + 1 )); echo "$lc" > "$S/listcount.$kind"
     wp=""; if knob list-wrongpath-from && [ "$lc" -ge "$(cat "$S/knob/list-wrongpath-from.$kind")" ]; then wp=/elsewhere; fi
     shape_terminals "$wp" < "$terms" ;;
  "terminal read")
     f="$S/screens/$kind-$term"; [ -s "$f" ] || { good_pane > "$f"; }
     rc_=$(( $(cat "$S/readcount.$kind" 2>/dev/null || echo 0) + 1 )); echo "$rc_" > "$S/readcount.$kind"
     # swap-pane: at the read number in swap-at, the screen becomes the text in swap-pane (a /model switch between the plan and the close)
     if [ -s "$S/knob/swap-at.$kind" ] && [ "$rc_" -eq "$(cat "$S/knob/swap-at.$kind")" ]; then cp "$S/knob/swap-pane.$kind" "$f"; fi
     # read-moves-handle: the agent's terminal changes while the cutover waits for idle. The knob file holds the read number it fires on (empty: the first)
     if knob read-moves-handle && [ "$rc_" -ge "$(cat "$S/knob/read-moves-handle.$kind" 2>/dev/null | grep -E '^[0-9]+$' || echo 1)" ]; then
       rm -f "$S/knob/read-moves-handle.$kind"; killproc_for "$STUB_PROC" "$term"; mkproc "$STUB_PROC" 7777 "$(awk -F'\t' -v h="$term" '$1 == h { print $2; exit }' "$terms")" ot-moved claude
     fi
     shape_read "$term" < "$f" ;;
  "terminal close")
     if knob close-fails; then echo '{"ok":false,"error":{"message":"refused"}}'; exit 1; fi
     if knob close-answers-no; then   # Orca closes it but the call answers with a failure (a timed-out call that went through)
       killproc_for "$STUB_PROC" "$term"; grep -v "^$term"$'\t' "$terms" > "$terms.new"; mv "$terms.new" "$terms"
       echo '{"ok":false,"error":{"message":"timed out"}}'; exit 1
     fi
     if knob close-answers-no-lingers; then   # same, and the agent takes 2 s to exit
       grep -v "^$term"$'\t' "$terms" > "$terms.new"; mv "$terms.new" "$terms"; ( sleep 2; killproc_for "$STUB_PROC" "$term" ) </dev/null >/dev/null 2>&1 &
       echo '{"ok":false,"error":{"message":"timed out"}}'; exit 1
     fi
     echo "# journal-handover-at-close=$(grep -l 'cutover to plugly' "$CM_HOME"/lanes/*/journal.md 2>/dev/null | wc -l | tr -d ' ')" >> "$STUB_LOG"
     if [ "$term" = pt-late ] && knob close-lingers-late; then ( sleep 2; killproc_for "$STUB_PROC" "$term" ) </dev/null >/dev/null 2>&1 &   # the closed late claude takes 2 s to exit
     elif ! knob close-keeps-proc; then killproc_for "$STUB_PROC" "$term"; fi
     knob close-keeps || { grep -v "^$term	" "$terms" > "$terms.new"; mv "$terms.new" "$terms"; }
     echo '{}' | shape_env ;;
  "terminal create")
     if knob create-fails; then echo '{"ok":false,"error":{"message":"no runtime"}}'; exit 1; fi
     # create-hangs: the call blocks for as long as the knob file exists (the test removes it), bounded at 120 s so a stub never hangs a run
     if knob create-hangs; then for _ in $(seq 1 1200); do knob create-hangs || break; sleep 0.1; done; fi
     n=$(( $(cat "$S/next" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/next"
     h="${kind:0:1}t-$n"; path="${wt#path:}"
     printf '%s\t%s\tclaude\n' "$h" "$path" >> "$terms"
     if [ -s "$S/knob/new-pane.$kind" ]; then cp "$S/knob/new-pane.$kind" "$S/screens/$kind-$h"; else launched_pane "$cmdtxt" > "$S/screens/$kind-$h"; fi
     if ! knob no-agent; then
       pn=$(( $(cat "$S/pidn" 2>/dev/null || echo 5000) + 1 )); echo "$pn" > "$S/pidn"
       mkproc "$STUB_PROC" "$pn" "$path" "$h" claude
     fi
     if [ "$kind" = orca ] && knob late-plugly-on-orca-create; then   # a plugly create that finished late, after its CLI call was cut off
       printf 'pt-late\t%s\tclaude\n' "$path" >> "$S/terms.plugly"; mkproc "$STUB_PROC" 7999 "$path" pt-late claude
     fi
     if knob create-times-out; then echo '{"ok":false,"error":{"message":"timed out"}}'; exit 1; fi   # the terminal exists, the answer never came
     if knob create-odd-key; then jq -cn --arg h "$h" '{terminalHandle:$h}' | shape_env; exit 0; fi   # a shape the parser does not read
     jq -cn --arg h "$h" '{terminal:{handle:$h}}' | shape_env ;;
  "terminal send")
     if knob send-fails; then echo '{"ok":false}'; exit 1; fi
     if [ "$kind" = orca ] && knob late-plugly-on-rearm; then   # lands after every check inside the rollback
       printf 'pt-late\t%s\tclaude\n' "$(awk -F'\t' -v h="$term" '$1 == h { print $2; exit }' "$terms")" >> "$S/terms.plugly"
       mkproc "$STUB_PROC" 7998 "$(awk -F'\t' -v h="$term" '$1 == h { print $2; exit }' "$terms")" pt-late claude
     fi
     path="$(awk -F'\t' -v h="$term" '$1 == h { print $2; exit }' "$terms")"
     if [ -n "$path" ] && ! knob send-no-turn; then
       d="$CM_CLAUDE_PROJECTS/$(printf '%s' "$path" | sed 's#[^A-Za-z0-9]#-#g')"; mkdir -p "$d"
       if knob send-startup-write; then printf '{"type":"system","text":"startup"}\n' >> "$d/s.jsonl"; touch "$d"/*.jsonl   # a write that is not the nudge, and the history files rewritten with it
       else jq -cn --arg t "$text" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{type:"user",timestamp:$ts,text:$t}' >> "$d/s.jsonl"; fi
     fi
     echo '{}' | shape_env ;;
  *) echo '{}' | shape_env ;;
esac
STUB
chmod +x "$BIN/stub"; ln -sf stub "$BIN/orca-stub"; ln -sf stub "$BIN/plugly-stub"
# a stub ssh: records its argv, answers "could not resolve" for the target `unreachable`, else runs the remote command line here
cat > "$BIN/ssh" <<'SSHSTUB'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "${SSH_LOG:-/dev/null}"
while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; -o) shift 2 ;; *) shift ;; esac; done
tgt="${1:-}"; shift
if [ "$tgt" = unreachable ]; then echo "ssh: Could not resolve hostname unreachable" >&2; exit 255; fi
eval "$*"
SSHSTUB
chmod +x "$BIN/ssh"
# shellcheck source=/dev/null
. "$BIN/procs.sh"

# ---- a case: its own CM_HOME, stub state, fake /proc, worktrees and ledger ------------------------------------------------
N=0; HANDLE_N=0
newcase() {
  N=$((N + 1)); C="$ROOT/case$N"
  export CM_HOME="$C/cm" STUB_STATE="$C/stub" STUB_LOG="$C/argv.log" STUB_PROC="$C/proc" CM_PROC_ROOT="$C/proc" CM_CLAUDE_PROJECTS="$C/projects"
  mkdir -p "$CM_HOME" "$STUB_STATE/knob" "$STUB_STATE/screens" "$STUB_PROC" "$CM_CLAUDE_PROJECTS" "$C/wt"
  : > "$STUB_LOG"; export SSH_LOG="$C/ssh.log"; : > "$SSH_LOG"
  shape_hosts host-a > "$STUB_STATE/hosts.plugly.json"
  jq -n '{schema: "concertmaster.ledger/v1", updatedAt: "2020-01-01T00:00:00Z", workers: {}}' > "$CM_HOME/ledger.json"
  PID_N=100
}
# add_lane <id> <lane> <standing true|false> <agent> [model] [host]: a worktree, an agent process on an Orca terminal ot-<k>, a ledger row
add_lane() {
  local id="$1" lane="$2" standing="$3" agent="$4" model="${5-claude-sonnet-5-5}" host="${6:-local}" wt h
  [ "$model" != - ] || model=""   # "-" = a ledger row with no model at all
  HANDLE_N=$((HANDLE_N + 1)); h="ot-w$HANDLE_N"; wt="$C/wt/$id"; mkdir -p "$wt"
  PID_N=$((PID_N + 1)); mkproc "$STUB_PROC" "$PID_N" "$wt" "$h" "$agent"
  printf '%s\t%s\t%s\n' "$h" "$wt" "$agent" >> "$STUB_STATE/terms.orca"
  jq --arg id "$id" --arg lane "$lane" --argjson st "$standing" --arg agent "$agent" --arg model "$model" --arg host "$host" --arg wt "$wt" --arg h "$h" --arg eff "${ADD_EFFORT:-}" \
    '.workers[$id] = ({lane: $lane, host: $host, agent: $agent, path: $wt, state: "running", terminal: $h, standing: $st} + (if $model == "" then {} else {model: $model} end) + (if $eff == "" then {} else {effort: $eff} end))' \
    "$CM_HOME/ledger.json" > "$CM_HOME/ledger.json.new" && mv "$CM_HOME/ledger.json.new" "$CM_HOME/ledger.json"
  eval "H_${id//-/_}=$h; W_${id//-/_}=$wt"
}
hof() { local v="H_${1//-/_}"; printf '%s' "${!v}"; }
wof() { local v="W_${1//-/_}"; printf '%s' "${!v}"; }
CUT="$SCRIPTS/cutover-host.sh"
run_cut() { OUT="$(bash "$CUT" "$@" 2>&1)"; RC=$?; printf "%s\n" "$OUT" > "$C/last.out"; }
muts() { grep -E ' terminal (create|close|send) ' "$STUB_LOG"; }
ledger_term() { jq -r --arg id "$1" '.workers[$id].terminal' "$CM_HOME/ledger.json"; }
lane_file_handle() { cut -f1 "$CM_HOME/lanes/$1/handle" 2>/dev/null; }
sum_state() { { sha256sum "$CM_HOME/ledger.json"; find "$CM_HOME" -mindepth 1 -not -name ledger.json | sort; } 2>/dev/null | sha256sum; }
plan_row() { printf '%s\n' "$OUT" | grep -E "[[:space:]]$1[[:space:]]" | head -n 1; }

# ============================================================================================================
echo "--- dry run"
newcase; add_lane w-dev-1 dev-1 false claude claude-sonnet-5-5; add_lane w-dev-2 dev-2 false claude; add_lane w-pr-sweeper pr-sweeper true claude
S0="$(sum_state)"
run_cut local
check "dry run exits 0 and says nothing was changed" '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "dry run: nothing was changed"' "$OUT"
check "dry run: the stub argv log holds only read verbs (host list, worktree ps, terminal list, terminal read)" \
  '[ -s "$STUB_LOG" ] && ! grep -vE "^(orca|plugly) (host list|worktree ps|terminal list|terminal read)( |$)" "$STUB_LOG" | grep -q .' "$(cat "$STUB_LOG")"
check "dry run: no ledger, handle file, journal or lock write (state hash unchanged, no lanes dir, no lock)" \
  '[ "$(sum_state)" = "$S0" ] && [ ! -e "$CM_HOME/lanes" ] && [ ! -e "$CM_HOME/cutover-host.lock" ]'
check "dry run: the seven named pre-check lines are printed" \
  'for n in ledger-readable plugly-host-registered plugly-terminals orca-host-reachable claude-binary no-cutover-lock no-resume-lock; do printf "%s\n" "$OUT" | grep -q "^check $n: ok" || exit 1; done'
check "dry run: the plan table has its columns and a row per lane with the LIVE handle, agent and action" \
  'printf "%s\n" "$OUT" | grep -Eq "^lane +worker +worktree +handle +agent +state +action" && plan_row w-dev-1 | grep -q "$(hof w-dev-1).*claude.*running.*cutover" && plan_row w-pr-sweeper | grep -q "cutover"'
check "dry run: the order is workers, then standing lanes, the pr-sweeper last" \
  'printf "%s\n" "$OUT" | grep -E "^  [0-9]\. " | tr -d "\n " | grep -q "1\.w-dev-12\.w-dev-23\.w-pr-sweeper"' "$OUT"
for k in orca plugly; do
  OUTK="$(CM_CLI_KIND=$k bash "$CUT" local 2>&1)"; RCK=$?
  check "dry run under CM_CLI_KIND=$k gives the same plan (the script drives both CLIs by name)" '[ "$RCK" = 0 ] && [ "$(printf "%s\n" "$OUTK" | grep -c "cutover$")" = 3 ]'
done

echo "--- pre-checks"
newcase; add_lane w-dev-1 dev-1 false claude
shape_hosts > "$STUB_STATE/hosts.plugly.json"
run_cut host-a
check "a host missing from the plugly host list refuses with exit 1 and names the host" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check plugly-host-registered: FAIL.*host-a" && [ -z "$(muts)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude; : > "$STUB_STATE/knob/list-fails.plugly"
run_cut local --apply
check "a plugly runtime that does not answer refuses (plugly-terminals)" '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check plugly-terminals: FAIL" && [ -z "$(muts)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude; : > "$STUB_STATE/knob/list-fails.orca"
run_cut local --apply
check "an Orca host that does not answer refuses (orca-host-reachable)" '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check orca-host-reachable: FAIL" && [ -z "$(muts)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
mkdir "$CM_HOME/resume.lock"; (exec -a resume-fake sleep 60) & RPID=$!; echo "$RPID" > "$CM_HOME/resume.lock/pid"
run_cut local --apply
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
check "a resume.sh run mid-flight refuses the cutover (no-resume-lock), nothing mutated" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check no-resume-lock: FAIL" && [ -z "$(muts)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude; mkdir "$CM_HOME/cutover-host.lock"; echo 999999 > "$CM_HOME/cutover-host.lock/pid"
run_cut local --apply
check "a held cutover lock refuses a second run: nothing closed, the lock left alone" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check no-cutover-lock: FAIL" && [ -z "$(muts)" ] && [ -d "$CM_HOME/cutover-host.lock" ]' "$OUT"
run_cut local
check "a held lock also fails the dry run (it is a pre-check), still without writing" '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check no-cutover-lock: FAIL"'
newcase; add_lane w-dev-1 dev-1 false claude
OUT2="$(env -u CM_CUTOVER_TEST bash "$CUT" local --apply --skip-census 2>&1)"; RC2=$?
check "--skip-census with --apply is refused unless CM_CUTOVER_TEST=1 (exit 2, nothing closed)" '[ "$RC2" = 2 ] && [ -z "$(muts)" ]' "$OUT2"
newcase; add_lane w-dev-1 dev-1 false claude
run_cut local --lane w-nope
check "--lane naming a worker that is not on the host is a usage error (exit 2)" '[ "$RC" = 2 ] && printf "%s\n" "$OUT" | grep -q "w-nope"' "$OUT"

echo "--- rows that are never cut over"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-research research false codex; add_lane w-gone gone false claude
killproc_for "$STUB_PROC" "$(hof w-gone)"
S0="$(sum_state)"
run_cut local --apply
check "a codex lane is listed manual and never restarted with claude --continue" \
  'plan_row w-research | grep -q "manual" && ! muts | grep -q "$(hof w-research)" && grep -qa "ORCA_TERMINAL_HANDLE=$(hof w-research)" "$STUB_PROC"/*/environ' "$OUT"
check "a lane with no live agent is dead: handed to resume.sh, never closed or created" 'plan_row w-gone | grep -q "dead.*resume.sh" && ! muts | grep -q "$(hof w-gone)"' "$OUT"
check "...while the claude lane in the same run is cut over" '[ "$(ledger_term w-dev-1)" = pt-1 ]' "$OUT"

echo "--- duplicate"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-dev-2 dev-2 false claude
PID_N=$((PID_N + 1)); mkproc "$STUB_PROC" "$PID_N" "$(wof w-dev-2)" "ot-extra" claude   # a second agent, another terminal, in dev-2's tree
printf 'ot-extra\t%s\tclaude\n' "$(wof w-dev-2)" >> "$STUB_STATE/terms.orca"
run_cut local --apply
check "a duplicate row is listed and refuses --apply (exit 1, nothing closed, no lock left)" \
  '[ "$RC" = 1 ] && plan_row w-dev-2 | grep -q "duplicate" && printf "%s\n" "$OUT" | grep -q "refused: duplicate" && [ -z "$(muts)" ] && [ ! -e "$CM_HOME/cutover-host.lock" ]' "$OUT"
: > "$STUB_LOG"
run_cut local --apply --lane w-dev-1
check "...unless the duplicate lane is left out with --lane: the other lane is cut over, the duplicate untouched" \
  '[ "$RC" = 0 ] && [ "$(ledger_term w-dev-1)" = pt-1 ] && ! muts | grep -q "w-dev-2\|ot-extra\|$(hof w-dev-2)"' "$OUT"

echo "--- self"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-dev-2 dev-2 false claude
ORCA_TERMINAL_HANDLE="$(hof w-dev-1)" run_cut local --apply
check "the caller's own terminal (ORCA_TERMINAL_HANDLE) is skip: self and is never closed; the other lane is cut over" \
  'plan_row w-dev-1 | grep -q "skip: self.*outside the lanes" && ! muts | grep -q "terminal close --terminal $(hof w-dev-1) " && [ "$(ledger_term w-dev-2)" = pt-1 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
OUT="$(PLUGLY_TERMINAL_HANDLE="$(hof w-dev-1)" bash "$CUT" local --apply 2>&1)"; RC=$?
check "...and PLUGLY_TERMINAL_HANDLE does the same" 'plan_row w-dev-1 | grep -q "skip: self" && [ -z "$(muts)" ]' "$OUT"

echo "--- --except: the concertmaster's own lane when the script runs from an operator shell"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-concertmaster concertmaster true claude; add_lane w-pr-sweeper pr-sweeper true claude
run_cut local
check "from an operator shell only the terminal RUNNING the script is skip: self, so the concertmaster's row plans as cutover (why the doc must not say it stays skip: self)" \
  'plan_row w-concertmaster | grep -q "cutover" && ! plan_row w-concertmaster | grep -q "skip: self"' "$OUT"
OHC="$(hof w-concertmaster)"; : > "$STUB_LOG"
run_cut local --apply --except w-concertmaster
check "--except leaves the concertmaster out: the other lanes move, its terminal is never closed, its ledger handle and the lane stay untouched, its pane is not read" \
  '{ [ "$RC" = 4 ] || [ "$RC" = 0 ]; } && plan_row w-concertmaster | grep -q "skip: not selected (--lane or --except)" && [ "$(ledger_term w-dev-1)" = pt-1 ] && [ "$(ledger_term w-pr-sweeper)" = pt-2 ] && [ "$(ledger_term w-concertmaster)" = "$OHC" ] && ! muts | grep -q "$OHC" && ! grep -q "^orca terminal read --terminal $OHC " "$STUB_LOG"' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
run_cut local --except w-nope
check "--except naming a worker that is not on the host is a usage error (exit 2)" '[ "$RC" = 2 ] && printf "%s\n" "$OUT" | grep -q "w-nope"' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-dev-2 dev-2 false claude
run_cut local --apply --lane w-dev-1 --lane w-dev-2 --except w-dev-2
check "--except wins over --lane: only the lane not excluded moves" '[ "$(ledger_term w-dev-1)" = pt-1 ] && [ "$(ledger_term w-dev-2)" = "$(hof w-dev-2)" ]' "$OUT"

echo "--- happy path"
newcase; add_lane w-dev-1 dev-1 false claude claude-sonnet-5-5; add_lane w-pr-sweeper pr-sweeper true claude
add_lane w-ops-sweeper ops-sweeper true claude
OH1="$(hof w-dev-1)"; OHP="$(hof w-pr-sweeper)"; OHO="$(hof w-ops-sweeper)"
run_cut local --apply
check "happy path: exit 0 and the report lists the three lanes done" '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "done:      w-dev-1 w-ops-sweeper w-pr-sweeper"' "$OUT"
EXP="orca terminal close --terminal $OH1 --json
plugly terminal create --worktree path:$(wof w-dev-1) --title cutover --command $CLAUDE_EXPECT --continue --model claude-sonnet-5-5 --effort high --json
plugly terminal send --terminal pt-1 --text $(bash -c ". '$SCRIPTS/lib.sh'; printf '%s' \"\$CM_NUDGE_TICK\"") --enter --json
orca terminal close --terminal $OHO --json
plugly terminal create --worktree path:$(wof w-ops-sweeper) --title cutover --command $CLAUDE_EXPECT --continue --model claude-sonnet-5-5 --effort high --json
plugly terminal send --terminal pt-2 --text $(bash -c ". '$SCRIPTS/lib.sh'; printf '%s' \"\$CM_NUDGE_TICK\"") --enter --json
orca terminal close --terminal $OHP --json
plugly terminal create --worktree path:$(wof w-pr-sweeper) --title cutover --command $CLAUDE_EXPECT --continue --model claude-sonnet-5-5 --effort high --json
plugly terminal send --terminal pt-3 --text $(bash -c ". '$SCRIPTS/lib.sh'; printf '%s' \"\$CM_NUDGE_TICK\"") --enter --json"
GOT="$(muts)"
check "happy path: the exact mutating argv, lane by lane: close by exact handle, create in the SAME path with claude --continue [--model], nudge (workers, standing lane, pr-sweeper last)" \
  '[ "$GOT" = "$EXP" ]' "$(printf 'want:\n%s\ngot:\n%s' "$EXP" "$GOT")"
check "happy path: the banner is checked on each new plugly terminal before the nudge (terminal read on pt-1 precedes its send)" \
  '[ "$(grep -n "plugly terminal read --terminal pt-1 " "$STUB_LOG" | head -n 1 | cut -d: -f1)" -lt "$(grep -n "plugly terminal send --terminal pt-1 " "$STUB_LOG" | cut -d: -f1)" ]'
check "happy path: the handover note is in the lane journal BEFORE each close" '[ "$(grep "journal-handover-at-close" "$STUB_LOG" | tr "\n" " ")" = "# journal-handover-at-close=1 # journal-handover-at-close=2 # journal-handover-at-close=3 " ]' "$(grep journal-handover "$STUB_LOG")"
check "happy path: the journal entry reads cm:handover cutover to plugly <UTC time>" 'grep -Eq "cm:handover cutover to plugly [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z" "$CM_HOME/lanes/w-dev-1/journal.md" && grep -Eq "cm:handover cutover to plugly" "$CM_HOME/lanes/pr-sweeper/journal.md"'
check "happy path: the ledger terminal and the lane handle file are rewritten to the new plugly handles" \
  '[ "$(ledger_term w-dev-1)" = pt-1 ] && [ "$(ledger_term w-ops-sweeper)" = pt-2 ] && [ "$(ledger_term w-pr-sweeper)" = pt-3 ] && [ "$(lane_file_handle w-dev-1)" = pt-1 ] && [ "$(lane_file_handle w-pr-sweeper)" = pt-3 ]'
check "happy path: the orphan check ran and was clean, no Orca terminal is left on a cut-over worktree" 'printf "%s\n" "$OUT" | grep -q "orphan check clean" && ! grep -q . "$STUB_STATE/terms.orca"'
check "happy path: the lock is released" '[ ! -e "$CM_HOME/cutover-host.lock" ]'
check "happy path: nothing but the stubs was called (decoys on PATH untouched)" '[ ! -s "$ROOT/decoy.log" ]'

echo "--- idempotent"
: > "$STUB_LOG"; S0="$(sum_state)"
run_cut local --apply
check "a second run: every lane is already on plugly, nothing closed, created or sent, exit 0" \
  '[ "$RC" = 0 ] && [ "$(printf "%s\n" "$OUT" | grep -c "skip: already on plugly")" = 3 ] && [ -z "$(muts)" ]' "$OUT"
check "a second run changes no ledger or handle state" '[ "$(sum_state)" = "$S0" ]'
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-dev-2 dev-2 false claude
run_cut local --apply --lane w-dev-1
: > "$STUB_LOG"
run_cut local --apply
check "a half-done host: the lane already on plugly is skipped, the rest is finished" \
  'plan_row w-dev-1 | grep -q "already on plugly" && [ "$(ledger_term w-dev-2)" = pt-2 ] && ! muts | grep -q "$(hof w-dev-1)" && [ "$RC" = 0 ]' "$OUT"

echo "--- busy"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-dev-2 dev-2 false claude
printf 'Sonnet 5.5 with high effort\n* Working... (esc to interrupt)\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply --wait-idle-s 0
check "a lane that never idles is skip: busy, never closed, and the run goes on to the next lane (exit 4: re-run later)" \
  '[ "$RC" = 4 ] && printf "%s\n" "$OUT" | grep -q "skip: busy" && ! muts | grep -q "$(hof w-dev-1)" && [ "$(ledger_term w-dev-2)" = pt-1 ] && [ "$(ledger_term w-dev-1)" = "$(hof w-dev-1)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
printf 'Which one?\nEnter to select\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply --wait-idle-s 0
check "a lane showing a question menu is not idle either: skipped, never closed" '[ "$RC" = 4 ] && [ -z "$(muts)" ]' "$OUT"

echo "--- rollback"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-dev-2 dev-2 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"
OH1="$(hof w-dev-1)"
run_cut local --apply
check "a failed banner check rolls back: the new plugly terminal is closed by its exact handle" 'muts | grep -q "^plugly terminal close --terminal pt-1 --json"' "$OUT"
check "...an Orca terminal running claude --continue is created in the same path and verified" \
  'muts | grep -q "^orca terminal create --worktree path:$(wof w-dev-1) --title resume --command $CLAUDE_EXPECT --continue --model claude-sonnet-5-5 --effort high --json" && grep -q "^orca terminal read --terminal ot-2 " "$STUB_LOG"'
check "...the lane handle is refreshed to the recreated Orca terminal (ledger and handle file)" '[ "$(ledger_term w-dev-1)" = ot-2 ] && [ "$(lane_file_handle w-dev-1)" = ot-2 ]'
check "...cutover failed: verify is in the lane journal" 'grep -q "cutover failed: verify" "$CM_HOME/lanes/w-dev-1/journal.md"'
check "...the run STOPS (exit 1): the next lane is untouched and the report says which" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "failed:    w-dev-1" && printf "%s\n" "$OUT" | grep -q "untouched: w-dev-2" && ! muts | grep -q "$(hof w-dev-2)"' "$OUT"
check "...no lock left behind" '[ ! -e "$CM_HOME/cutover-host.lock" ]'
check "...the rollback re-arms the /loop on the recreated Orca terminal (nudge sent to ot-2 through the lane reader)" \
  'muts | grep -q "^orca terminal send --terminal ot-2 --text "'

newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/close-fails.plugly"
run_cut local --apply
check "a rollback whose plugly close is refused is STRANDED (exit 3): no Orca terminal is created next to the live plugly agent" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "LANE STRANDED" && ! muts | grep -q "^orca terminal create" && grep -q "would not close and may still run an agent: NOT creating" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"
check "...and live-agent shows exactly the one plugly agent, never two" \
  '[ "$("$SCRIPTS/live-agent.sh" "$(wof w-dev-1)" | wc -l | tr -d " ")" = 1 ]'

newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/close-keeps-proc.orca"
run_cut local --apply
check "an accepted close with the old agent still running creates nothing: STRANDED, exit 3, a truthful journal note" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "LANE STRANDED" && ! muts | grep -q "terminal create" && grep -q "cutover failed: close.*still running" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/close-keeps-proc.plugly"
run_cut local --apply
check "a rollback whose plugly close is ACCEPTED but whose agent is slow to exit waits, then is STRANDED: no Orca claude next to it" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "LANE STRANDED" && ! muts | grep -q "^orca terminal create" && grep -q "an agent is still running in the tree.*NOT creating" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/create-fails.plugly"
run_cut local --apply
check "a plugly create that fails rolls back to an Orca terminal and stops (exit 1)" \
  '[ "$RC" = 1 ] && [ "$(ledger_term w-dev-1)" = ot-1 ] && grep -q "cutover failed: create" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/create-fails.orca"
run_cut local --apply
check "a rollback that cannot recreate the terminal says LANE DOWN, exits 3 and journals it" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "LANE DOWN" && printf "%s\n" "$OUT" | grep -q "resume.sh" && grep -q "ROLLBACK could not create" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/close-fails.orca"
run_cut local --apply
check "a close that is refused leaves the Orca terminal alone: nothing created, journal says cutover failed: close, exit 1" \
  '[ "$RC" = 1 ] && ! muts | grep -q "terminal create" && grep -q "cutover failed: close" "$CM_HOME/lanes/w-dev-1/journal.md" && [ "$(ledger_term w-dev-1)" = "$(hof w-dev-1)" ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/send-no-turn.plugly"
run_cut local --apply
check "a nudge after which no turn starts rolls back (cutover failed: nudge) and stops" \
  '[ "$RC" = 1 ] && grep -q "cutover failed: nudge" "$CM_HOME/lanes/w-dev-1/journal.md" && [ "$(ledger_term w-dev-1)" = ot-2 ]' "$OUT"

echo "--- review fixes"
newcase; add_lane w-research research false codex
run_cut local --apply --lane w-research
check "a run whose selected lanes are all manual exits 4 and lists them as not moved (never 0)" \
  '[ "$RC" = 4 ] && printf "%s\n" "$OUT" | grep -q "not moved: w-research" && [ -z "$(muts)" ]' "$OUT"
# the model gate: model and effort come from the LIVE pane (the real ledger holds "" for standing lanes and a bare alias for a worker)
newcase; add_lane w-dev-1 dev-1 false claude opus; add_lane w-dev-2 dev-2 false claude sonnet; add_lane w-pr-sweeper pr-sweeper true claude -
run_cut local --apply
check "a bare alias (opus, sonnet) or an empty ledger model is never trusted: all three lanes are relaunched with the LIVE sonnet-5.5 / high" \
  '[ "$RC" = 0 ] && [ "$(muts | grep -c "^plugly terminal create .*--continue --model claude-sonnet-5-5 --effort high --json")" = 3 ] && ! muts | grep -q -- "--model opus\|--model sonnet "' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude claude-opus-5-5
run_cut local --apply
check "a full ledger model that disagrees with the live banner is skip: model mismatch (ledger X, live Y): nothing touched, exit 4" \
  '[ "$RC" = 4 ] && plan_row w-dev-1 | grep -q "skip: model mismatch (ledger claude-opus-5-5, live claude-sonnet-5-5)" && [ -z "$(muts)" ]' "$OUT"
newcase; ADD_EFFORT=high add_lane w-dev-1 dev-1 false claude -
printf '  opus-5.5 · eff max · 🟢 3/50 · ctx [░░░░░░] 15%% · $0.96\n  ⏵⏵ bypass permissions on\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply
check "a ledger effort that disagrees with the live one is skip: effort mismatch (ledger X, live Y)" \
  '[ "$RC" = 4 ] && plan_row w-dev-1 | grep -q "skip: effort mismatch (ledger high, live max)" && [ -z "$(muts)" ]' "$OUT"
newcase; ADD_EFFORT=turbo add_lane w-dev-1 dev-1 false claude -
run_cut local --apply
check "a ledger effort that is not a level is a loud skip, not hidden" '[ "$RC" = 4 ] && plan_row w-dev-1 | grep -q "ledger effort \"turbo\" is not a level" && [ -z "$(muts)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude -; add_lane w-dev-2 dev-2 false claude -; add_lane w-dev-3 dev-3 false claude -
printf '  ⏵⏵ bypass permissions on\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
printf 'Opus 4 with high effort\n\n? for shortcuts\n' > "$STUB_STATE/screens/orca-$(hof w-dev-2)"
run_cut local --apply
check "a pane whose banner cannot be read (scrolled off, or not a known <family>-<n>.<m> form) is skip: cannot read the live model, never guessed; the readable lane still moves" \
  '[ "$RC" = 4 ] && plan_row w-dev-1 | grep -q "skip: cannot read the live model" && plan_row w-dev-2 | grep -q "skip: cannot read the live model" && ! muts | grep -q "$(hof w-dev-1)\|$(hof w-dev-2)" && [ "$(ledger_term w-dev-3)" = pt-1 ]' "$OUT"
check "...and they are listed under a look: line so the operator can open the panes (2 lanes, ids named)" \
  'printf "%s\n" "$OUT" | grep -q "^look: 2 lane(s) whose live model could not be read" && printf "%s\n" "$OUT" | grep -q "^  w-dev-1: cannot read" && printf "%s\n" "$OUT" | grep -q "^  w-dev-2: cannot read" && [ "$(printf "%s\n" "$OUT" | grep "^rows:")" = "rows: 3 total, cutover 1, skip 2" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-dev-2 dev-2 false claude
run_cut local --lane w-dev-1
check "a canary (--lane) reads the pane of the selected lane only, not every lane on the host" \
  '[ "$(grep -c "^orca terminal read " "$STUB_LOG")" = 1 ] && grep -q "^orca terminal read --terminal $(hof w-dev-1) " "$STUB_LOG" && ! grep -q "^orca terminal read --terminal $(hof w-dev-2) " "$STUB_LOG" && [ "$(printf "%s\n" "$OUT" | grep "^rows:")" = "rows: 2 total, cutover 1, not-selected 1" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
printf 'Opus 5.5 with high effort\n\n? for shortcuts\n' > "$STUB_STATE/knob/swap-pane.orca"; echo 3 > "$STUB_STATE/knob/swap-at.orca"
run_cut local --apply
check "a /model switch between the plan and the close (the pane is read again before the close) skips the lane: not closed, exit 4" \
  '[ "$RC" = 4 ] && printf "%s\n" "$OUT" | grep -q "the live model of $(hof w-dev-1) changed" && [ -z "$(muts)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
jq '.workers["w-forged"] = {lane: "f", host: "local", agent: "claude", path: "/w/f", state: "running\n0\u001fw-forged2\u001fx\u001f/w/victim", terminal: "ot-f"}' "$CM_HOME/ledger.json" > "$CM_HOME/l.new" && mv "$CM_HOME/l.new" "$CM_HOME/ledger.json"
run_cut local --apply
check "a control character in the state is never split into a forged row; an unusable row in a full run is not moved (exit 4)" \
  '[ "$RC" = 4 ] && [ "$(printf "%s\n" "$OUT" | grep -c "ledger row is not usable")" = 1 ] && ! printf "%s\n" "$OUT" | grep -q "w-forged2" && printf "%s\n" "$OUT" | grep -q "not moved: .*w-forged" && [ "$(ledger_term w-dev-1)" = pt-1 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_LOG"
run_cut host-a --apply
check "--apply on a remote host is refused (exit 2) before any CLI call" \
  '[ "$RC" = 2 ] && printf "%s\n" "$OUT" | grep -q "remote host" && [ ! -s "$STUB_LOG" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
jq --arg wt "$C/wt/bad" '.workers["w-bad\nx"] = {lane: "bad", host: "local", agent: "claude", path: $wt, state: "running", terminal: "ot-bad"}' "$CM_HOME/ledger.json" > "$CM_HOME/l.new" && mv "$CM_HOME/l.new" "$CM_HOME/ledger.json"
run_cut local
check "a ledger row with a control character in its id is shown once, quoted, as unusable (never split into forged fields)" \
  '[ "$RC" = 0 ] && [ "$(printf "%s\n" "$OUT" | grep -c "ledger row is not usable")" = 1 ] && printf "%s\n" "$OUT" | grep -q "w-bad" && plan_row w-dev-1 | grep -q cutover' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/create-hangs.plugly"
bash "$CUT" local --apply > "$C/sig.out" 2>&1 &
SIGPID=$!
REACHED=0; for _ in $(seq 1 900); do if grep -q "plugly terminal create" "$STUB_LOG"; then REACHED=1; break; fi; sleep 0.1; done
[ "$REACHED" = 1 ] || bad "a SIGTERM mid-lane: create not reached within 90 s (the run never got to the create; no signal sent blind)"
kill -TERM "$SIGPID" 2>/dev/null   # the trap runs once the blocked create call returns (when not reached, this just ends the run)
rm -f "$STUB_STATE/knob/create-hangs.plugly"              # release the stub's create
wait "$SIGPID"; RC=$?; OUT="$(cat "$C/sig.out")"
check "a SIGTERM between the close and the end of the lane journals it, says LANE DOWN? and exits 3 (never a silent lane)" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "interrupted at create" && grep -q "cutover interrupted at create" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"
check "...and the lock is released after the interrupt" '[ ! -e "$CM_HOME/cutover-host.lock" ]'
newcase
mkdir "$CM_HOME/cutover-host.lock"; echo $$ > "$CM_HOME/cutover-host.lock/pid"
OUTR="$(bash "$SCRIPTS/resume.sh" 2>&1)"; RCR=$?
check "resume.sh stands down (exit 4) while a cutover holds its lock" '[ "$RCR" = 4 ] && printf "%s\n" "$OUTR" | grep -q "cutover"' "$OUTR"
echo 999999 > "$CM_HOME/cutover-host.lock/pid"
OUTR="$(bash "$SCRIPTS/resume.sh" 2>&1)"; RCR=$?
check "...but a lock left by a dead pid does not block it (resume.sh runs: empty roster, exit 0)" '[ "$RCR" = 0 ] && printf "%s\n" "$OUTR" | grep -q "nothing to resume"' "$OUTR"
(exec sleep 60) & SPID=$!; echo "$SPID" > "$CM_HOME/cutover-host.lock/pid"
OUTR="$(bash "$SCRIPTS/resume.sh" 2>&1)"; RCR=$?
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
check "...nor does a lock whose pid was reused by an unrelated process (runs: exit 0)" '[ "$RCR" = 0 ] && printf "%s\n" "$OUTR" | grep -q "nothing to resume"' "$OUTR"
rm -f "$CM_HOME/cutover-host.lock/pid"
OUTR="$(bash "$SCRIPTS/resume.sh" 2>&1)"; RCR=$?
check "...but a young lock with no pid yet (being made) does block it" '[ "$RCR" = 4 ]' "$OUTR"
# the hold for a REMOTE apply (scripts/cutover-hold.sh): a lock in the concertmaster's own CM_HOME whose pid is a cutover-host-hold process
HOLD="$SCRIPTS/cutover-hold.sh"
newcase
: > "$ROOT/hold-pids"
HOUT="$(bash "$HOLD" start --hours 1 2>&1)"; HRC=$?; cat "$CM_HOME/cutover-hold.pid" >> "$ROOT/hold-pids" 2>/dev/null
check "cutover-hold.sh start takes the hold: exit 0, status says held" '[ "$HRC" = 0 ] && bash "$HOLD" status | grep -q "^held"' "$HOUT"
OUTR="$(bash "$SCRIPTS/resume.sh" 2>&1)"; RCR=$?
check "...and resume.sh stands down (exit 4) while it is held" '[ "$RCR" = 4 ] && printf "%s\n" "$OUTR" | grep -q "cutover"' "$OUTR"
HPID="$(cat "$CM_HOME/cutover-hold.pid")"
check "...the stand-in is detached: its own session (a hangup or a group kill of the caller cannot reach it)" '[ "$(ps -o sid= -p "$HPID" | tr -d " ")" = "$HPID" ] || ! command -v setsid >/dev/null' ""
HOUT2="$(bash "$HOLD" start 2>&1)"; HRC2=$?
check "...a second start is refused (exit 1) and leaves the first hold alone" '[ "$HRC2" = 1 ] && [ "$(cat "$CM_HOME/cutover-hold.pid")" = "$HPID" ] && kill -0 "$HPID"' "$HOUT2"
bash "$HOLD" release >/dev/null 2>&1; HRC3=$?
OUTR="$(bash "$SCRIPTS/resume.sh" 2>&1)"; RCR=$?
alive() { local s; s="$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')"; [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }   # running, not a zombie
for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$HPID" || break; sleep 0.2; done
check "release kills only the stand-in, removes the lock and lets resume.sh run again (exit 0)" \
  '[ "$HRC3" = 0 ] && ! alive "$HPID" && [ ! -e "$CM_HOME/cutover-host.lock" ] && [ ! -e "$CM_HOME/cutover-hold.pid" ] && [ "$RCR" = 0 ] && printf "%s\n" "$OUTR" | grep -q "nothing to resume"' "$OUTR"
newcase
HOUT="$(bash "$HOLD" start --hours "$(printf '%s%s' 18446744073 709551624)" 2>&1)"; HRC=$?
check "--hours takes one or two digits: a huge number cannot wrap into range (exit 2, no lock)" '[ "$HRC" = 2 ] && [ ! -e "$CM_HOME/cutover-host.lock" ]' "$HOUT"
HOUT="$(bash "$HOLD" start --hours 25 2>&1)"; HRC=$?
check "...and 25 is out of range (exit 2)" '[ "$HRC" = 2 ]' "$HOUT"
newcase
bash "$HOLD" start --hours 1 >/dev/null 2>&1; EPID="$(cat "$CM_HOME/cutover-hold.pid")"; echo "$EPID" >> "$ROOT/hold-pids"
kill "$EPID"; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$EPID" 2>/dev/null || break; sleep 0.2; done
HOUT="$(bash "$HOLD" status 2>&1)"; HRC=$?
check "an expired hold (stand-in gone, lock still ours) is reported as EXPIRED, exit 1, not as held" '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q EXPIRED' "$HOUT"
HOUT="$(bash "$HOLD" start --hours 1 2>&1)"; HRC=$?; cat "$CM_HOME/cutover-hold.pid" >> "$ROOT/hold-pids"
check "...and the next start cleans it up and takes a fresh hold (exit 0, held)" '[ "$HRC" = 0 ] && bash "$HOLD" status | grep -q "^held"' "$HOUT"
bash "$HOLD" release >/dev/null 2>&1
newcase
mkdir "$CM_HOME/cutover-host.lock"; echo 999999 > "$CM_HOME/cutover-host.lock/pid"
HOUT="$(bash "$HOLD" start 2>&1)"; HRC=$?
check "start refuses an existing lock (a forgotten hold, a stale one, a running cutover): exit 1, the lock and its pid untouched, no hold file written (no stand-in was started)" \
  '[ "$HRC" = 1 ] && [ "$(cat "$CM_HOME/cutover-host.lock/pid")" = 999999 ] && [ ! -e "$CM_HOME/cutover-hold.pid" ]' "$HOUT"
HOUT="$(bash "$HOLD" release 2>&1)"; HRC=$?
check "release without a hold of ours is refused (exit 1) and leaves a foreign lock alone" '[ "$HRC" = 1 ] && [ -d "$CM_HOME/cutover-host.lock" ]' "$HOUT"
newcase
# a stand-in that is a ZOMBIE (it exited, its parent never reaps it) counts as gone: the hold is EXPIRED, not wedged
bash -c '( exec -a cutover-host-hold sleep 1 ) & echo $! > "$1"; exec sleep 8' _ "$CM_HOME/zp" & ZPAR=$!
for _ in $(seq 1 25); do [ -s "$CM_HOME/zp" ] && break; sleep 0.2; done
ZP="$(cat "$CM_HOME/zp")"; mkdir "$CM_HOME/cutover-host.lock"; echo "$ZP" > "$CM_HOME/cutover-host.lock/pid"; echo "$ZP" > "$CM_HOME/cutover-hold.pid"
for _ in $(seq 1 40); do ZS="$(ps -p "$ZP" -o stat= 2>/dev/null | tr -d ' ')"; case "$ZS" in Z*) break ;; esac; sleep 0.2; done
HOUT="$(bash "$HOLD" status 2>&1)"; HRC=$?
case "$ZS" in
  Z*) check "a zombie stand-in (exited, never reaped) counts as gone: status says EXPIRED, not NOT held by us (exit 1)" '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q EXPIRED' "$ZS / $HOUT" ;;
  *) printf 'SKIP zombie case: the exited stand-in was reaped here (state %s), so there is no zombie to test (not counted as a pass)\n' "${ZS:-gone}" ;;
esac
kill "$ZPAR" 2>/dev/null; wait "$ZPAR" 2>/dev/null
newcase
mkdir "$CM_HOME/cutover-host.lock"; : > "$CM_HOME/cutover-hold.pid"
bash "$HOLD" release >/dev/null 2>&1; HRC=$?
check "release never removes a pidless lock on the strength of an empty hold file (it may be a cutover that just took the lock): exit 1, lock stays, hold file kept for a retry" '[ "$HRC" = 1 ] && [ -d "$CM_HOME/cutover-host.lock" ] && [ -e "$CM_HOME/cutover-hold.pid" ]' ""
newcase
( exec -a cutover-host-hold sleep 60 ) & FPID=$!; ( exec sleep 60 ) & OPID=$!
mkdir "$CM_HOME/cutover-host.lock"; echo "$OPID" > "$CM_HOME/cutover-host.lock/pid"; echo "$FPID" > "$CM_HOME/cutover-hold.pid"
bash "$HOLD" release >/dev/null 2>&1; HRC=$?
check "release leaves a lock whose pid is not the recorded stand-in alone (a real cutover took it): the lock and its pid stay" '[ -d "$CM_HOME/cutover-host.lock" ] && [ "$(cat "$CM_HOME/cutover-host.lock/pid")" = "$OPID" ]' ""
HMSG="$(bash "$HOLD" release 2>&1 >/dev/null)"
check "...and release said so with exit 1 and a NOT released warning on stderr" '[ "$HRC" = 1 ] && printf "%s\n" "$HMSG" | grep -q "NOT released"' "$HMSG"
kill "$OPID" "$FPID" 2>/dev/null; wait "$OPID" "$FPID" 2>/dev/null
newcase
( exec sleep 60 ) & OPID=$!
mkdir "$CM_HOME/cutover-host.lock"; echo "$OPID" > "$CM_HOME/cutover-host.lock/pid"; echo "$OPID" > "$CM_HOME/cutover-hold.pid"
bash "$HOLD" release >/dev/null 2>&1
check "release never kills a pid that is not the stand-in (a reused pid): the unrelated process lives" 'kill -0 "$OPID" 2>/dev/null' ""
check "...and a lock that names that live unrelated pid (a real cutover that reused it) is not ours: left in place" '[ -d "$CM_HOME/cutover-host.lock" ] && [ "$(cat "$CM_HOME/cutover-host.lock/pid")" = "$OPID" ]' ""
echo "$OPID" > "$CM_HOME/cutover-hold.pid"   # the hold file names the same live unrelated pid: the path that must NOT clean it as expired
bash "$HOLD" start >/dev/null 2>&1; HRC=$?
check "...and start refuses it too (exit 1) instead of cleaning it as an expired hold" '[ "$HRC" = 1 ] && [ -d "$CM_HOME/cutover-host.lock" ] && [ "$(cat "$CM_HOME/cutover-host.lock/pid")" = "$OPID" ]' ""
kill "$OPID" 2>/dev/null; wait "$OPID" 2>/dev/null
# standins <seconds>: stand-ins with that argument started by THIS test run (its environment carries CM_HOLD_TOKEN=$ROOT), so two
# copies of the suite running at once do not count each other's. A read right at a stand-in's exec can see no environment yet: it is
# retried for a moment, so a live stand-in is not undercounted.
export CM_HOLD_TOKEN="$ROOT"
standins() {
  local n=0 p i env
  for p in $(ps -eo pid,args= | awk -v h="$1" '$2 == "cutover-host-hold" && $3 == h { print $1 }'); do
    if [ -r /proc/self/environ ]; then
      env=""; for i in 1 2 3 4 5 6 7 8 9 10; do env="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null)"; [ -n "$env" ] && break; ps -p "$p" >/dev/null 2>&1 || break; sleep 0.1; done
      printf '%s\n' "$env" | grep -qx "CM_HOLD_TOKEN=$ROOT" && n=$((n + 1))
    else
      n=$((n + 1))   # no /proc (macOS): count every stand-in with that argument (run one copy of the suite at a time there)
    fi
  done
  echo "$n"
}
# claim_holder: a process that holds the claim flock (as another start would) until it is killed; prints its pid
claim_holder() { ( exec 8>"$CM_HOME/cutover-hold.claim.lock"; flock 8; exec -a claim-holder sleep 60 ) >/dev/null 2>&1 & echo $!; }   # stdout closed, or $(claim_holder) would wait for it
# several starts at once, from an EXPIRED hold and from fresh state: exactly one wins, exactly one stand-in runs, the lock names it, the
# others exit 1 (no orphans, no pidless lock)
for VARIANT in expired fresh; do
for ROUND in 1 2 3; do
  newcase
  if [ "$VARIANT" = expired ]; then
    bash "$HOLD" start --hours 7 >/dev/null 2>&1; EPID="$(cat "$CM_HOME/cutover-hold.pid")"; echo "$EPID" >> "$ROOT/hold-pids"
    kill "$EPID"; for _ in $(seq 1 25); do ps -p "$EPID" -o stat= 2>/dev/null | grep -qv Z || break; sleep 0.2; done
  fi
  SPIDS=""
  for K in 1 2 3 4 5; do ( bash "$HOLD" start --hours 7 > "$C/par$K.out" 2>&1; echo $? > "$C/par$K.rc" ) & SPIDS="$SPIDS $!"; done
  # shellcheck disable=SC2086  # SPIDS is a list of pids
  wait $SPIDS 2>/dev/null
  NHELD="$(cat "$C"/par?.out | grep -c '^held:')"; NPID="$(cat "$CM_HOME/cutover-hold.pid" 2>/dev/null)"; echo "$NPID" >> "$ROOT/hold-pids"
  for _ in $(seq 1 25); do [ "$(standins 25200)" = 1 ] && break; sleep 0.2; done   # a start that lost kills nothing (it never spawned); this only lets a live count settle
  RSTAT="$(bash "$HOLD" status 2>&1)"; RSTAND="$(standins 25200)"; RLOCK="$(cat "$CM_HOME/cutover-host.lock/pid" 2>/dev/null)"; RLOSE="$(cat "$C"/par?.rc | grep -c '^1$')"
  check "5 parallel starts from $VARIANT state (round $ROUND): exactly one says held, exactly one stand-in runs, the lock names it, the other four exit 1" \
    '[ "$NHELD" = 1 ] && [ "$RSTAND" = 1 ] && [ "$RLOCK" = "$NPID" ] && printf "%s\n" "$RSTAT" | grep -q "^held" && [ "$RLOSE" = 4 ]' "held=$NHELD standins=$RSTAND lock=$RLOCK hold=$NPID status=[$RSTAT] losers=$RLOSE rcs=$(cat "$C"/par?.rc | tr '\n' ' ')"
  bash "$HOLD" release >/dev/null 2>&1; for _ in $(seq 1 25); do [ "$(standins 25200)" = 0 ] && break; sleep 0.2; done
  check "...and one release leaves no stand-in and no lock (round $ROUND)" '[ "$(standins 25200)" = 0 ] && [ ! -e "$CM_HOME/cutover-host.lock" ]' ""
done
done
# resume.sh running right now: a create it started could still land after "held", so start refuses; a stale resume.lock does not block
newcase
mkdir "$CM_HOME/resume.lock"; ( exec -a resume-fake sleep 60 ) & RSPID=$!; echo "$RSPID" > "$CM_HOME/resume.lock/pid"
HOUT="$(bash "$HOLD" start --hours 6 2>&1)"; HRC=$?
check "start refuses (exit 1, clear message, no lock, no stand-in) while resume.sh is running" \
  '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q "resume.sh is running" && [ ! -e "$CM_HOME/cutover-host.lock" ] && [ "$(standins 21600)" = 0 ]' "$HOUT"
kill "$RSPID" 2>/dev/null; wait "$RSPID" 2>/dev/null
echo 999999 > "$CM_HOME/resume.lock/pid"
HOUT="$(bash "$HOLD" start --hours 6 2>&1)"; HRC=$?; cat "$CM_HOME/cutover-hold.pid" >> "$ROOT/hold-pids" 2>/dev/null
check "...but a resume.lock left by a dead pid does not block it (exit 0, held)" '[ "$HRC" = 0 ] && bash "$HOLD" status | grep -q "^held"' "$HOUT"
bash "$HOLD" release >/dev/null 2>&1
# resume.sh starts while a start waits for the claim: the check made with the claim held catches it (the first check had passed)
newcase
CHPID="$(claim_holder)"; sleep 0.5
CM_HOLD_CLAIM_WAIT_S=30 bash "$HOLD" start --hours 6 > "$C/second.out" 2>&1 & SCPID=$!
sleep 1
mkdir "$CM_HOME/resume.lock"; ( exec -a resume-fake sleep 60 ) & RSPID=$!; echo "$RSPID" > "$CM_HOME/resume.lock/pid"
kill "$CHPID" 2>/dev/null; wait "$CHPID" 2>/dev/null
wait "$SCPID"; HRC=$?; cat "$CM_HOME/cutover-hold.pid" >> "$ROOT/hold-pids" 2>/dev/null   # a stand-in a broken check let through is still killed on exit
check "resume.sh started while a start waited for the claim: the start refuses (exit 1) with the second check's message, makes no lock, no stand-in" \
  '[ "$HRC" = 1 ] && grep -q "resume.sh started while this start waited" "$C/second.out" && [ ! -e "$CM_HOME/cutover-host.lock" ] && [ "$(standins 21600)" = 0 ]' "rc=$HRC $(cat "$C/second.out")"
kill "$RSPID" 2>/dev/null; wait "$RSPID" 2>/dev/null
# a stand-in that never starts (a setsid that does nothing): start fails (exit 1), leaves no lock and no stand-in
newcase
mkdir "$ROOT/nosetsid-$N"; printf '#!/bin/sh\nexit 0\n' > "$ROOT/nosetsid-$N/setsid"; chmod +x "$ROOT/nosetsid-$N/setsid"
HOUT="$(PATH="$ROOT/nosetsid-$N:$PATH" bash "$HOLD" start --hours 6 2>&1)"; HRC=$?
check "a start whose stand-in never starts fails (exit 1, says so) and leaves no lock and no stand-in" \
  '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q "stand-in process did not start" && [ ! -e "$CM_HOME/cutover-host.lock" ] && [ "$(standins 21600)" = 0 ]' "$HOUT"
# the claim is a flock: a live holder makes start give up after the bounded wait, a killed holder frees it at once
newcase
CHPID="$(claim_holder)"; sleep 0.5
HOUT="$(CM_HOLD_CLAIM_WAIT_S=2 bash "$HOLD" start --hours 6 2>&1)"; HRC=$?
check "a live claim (another start or release in progress) makes start give up after the bounded wait: exit 1, nothing made" \
  '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q "another start or release holds" && [ ! -e "$CM_HOME/cutover-host.lock" ]' "$HOUT"
kill "$CHPID" 2>/dev/null; wait "$CHPID" 2>/dev/null
HOUT="$(CM_HOLD_CLAIM_WAIT_S=2 bash "$HOLD" start --hours 6 2>&1)"; HRC=$?; cat "$CM_HOME/cutover-hold.pid" >> "$ROOT/hold-pids" 2>/dev/null
check "...and the claim of a killed owner is free at once (no reaping, no minute to wait): exit 0, held" '[ "$HRC" = 0 ] && bash "$HOLD" status | grep -q "^held"' "$HOUT"
bash "$HOLD" release >/dev/null 2>&1
# the stand-in does not keep the claim: after a start the claim is free again for the next one
newcase
bash "$HOLD" start --hours 6 >/dev/null 2>&1; cat "$CM_HOME/cutover-hold.pid" >> "$ROOT/hold-pids" 2>/dev/null
check "the stand-in does not inherit the claim: right after a start, the flock is free" '( exec 7>"$CM_HOME/cutover-hold.claim.lock"; flock -n 7 )' ""
bash "$HOLD" release >/dev/null 2>&1
# no flock(1): start and release fail closed
newcase
mkdir "$ROOT/noflock-$N"; for f in "$TOOLS"/*; do [ "${f##*/}" = flock ] || ln -s "$f" "$ROOT/noflock-$N/${f##*/}"; done
HOUT="$(PATH="$ROOT/noflock-$N" bash "$HOLD" start --hours 6 2>&1)"; HRC=$?
check "without flock(1) start fails closed (exit 1, says so), nothing made" '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q "flock(1) is not installed" && [ ! -e "$CM_HOME/cutover-host.lock" ]' "$HOUT"
HOUT="$(PATH="$ROOT/noflock-$N" bash "$HOLD" release 2>&1)"; HRC=$?
check "...and so does release (exit 1)" '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q "flock(1) is not installed"' "$HOUT"
# a start interrupted while it waits for the claim exits 130 (a retry loop must not read it as contention), makes nothing, and leaves
# the other owner's claim alone
newcase
CHPID="$(claim_holder)"; sleep 0.5
CM_HOLD_CLAIM_WAIT_S=30 bash "$HOLD" start --hours 6 > "$C/sig-hold.out" 2>&1 & SHPID=$!
sleep 1
kill -TERM "$SHPID" 2>/dev/null; wait "$SHPID"; HRC=$?
check "a start interrupted by TERM while waiting for the claim exits 130 at once, makes no lock and no stand-in, and leaves the other owner's claim alone" \
  '[ "$HRC" = 130 ] && [ ! -e "$CM_HOME/cutover-host.lock" ] && ! ( exec 7>"$CM_HOME/cutover-hold.claim.lock"; flock -n 7 ) && [ "$(standins 21600)" = 0 ]' "rc=$HRC $(cat "$C/sig-hold.out")"
kill "$CHPID" 2>/dev/null; wait "$CHPID" 2>/dev/null
# an interrupt before the script's own setup is also 130 (the trap is set before lib.sh is sourced)
newcase
# A copy of the script beside a lib.sh that stops inside the setup (it marks the spot and waits), so the signal lands there every time,
# not by a sleep: the answer is exactly 130, never 143, and never a finished status.
mkdir "$C/setupcopy"; cp "$HOLD" "$C/setupcopy/cutover-hold.sh"
printf ': > "%s/in-setup"\nwhile :; do sleep 0.05; done\n' "$C" > "$C/setupcopy/lib.sh"
bash "$C/setupcopy/cutover-hold.sh" status > /dev/null 2>&1 & ISPID=$!
for _i in $(seq 1 100); do [ -e "$C/in-setup" ] && break; sleep 0.05; done
kill -TERM "$ISPID" 2>/dev/null; wait "$ISPID"; HRC=$?
check "a TERM that arrives while the script is still setting up (before the claim code) exits exactly 130, not 143" '[ -e "$C/in-setup" ] && [ "$HRC" = 130 ]' "rc=$HRC"
# a release cut off between removing the lock's pid file and removing the lock directory: the rerun cannot finish it (the doc says so)
newcase
mkdir "$CM_HOME/cutover-host.lock"; echo 999999 > "$CM_HOME/cutover-hold.pid"
HOUT="$(bash "$HOLD" release 2>&1)"; HRC=$?
check "a release rerun over a lock with no pid file refuses (exit 1, names pid none) and leaves the lock: not re-runnable" '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q "names pid none" && [ -d "$CM_HOME/cutover-host.lock" ]' "rc=$HRC $HOUT"
check "references/cutover.md says so and gives the by-hand step" 'grep -q "names pid none" "$SCRIPTS/../references/cutover.md" && grep -q "remove that lock by hand" "$SCRIPTS/../references/cutover.md"'
rmdir "$CM_HOME/cutover-host.lock" 2>/dev/null; rm -f "$CM_HOME/cutover-hold.pid"
newcase
HOUT="$(CM_HOLD_CLAIM_WAIT_S=99999 bash "$HOLD" start 2>&1)"; HRC=$?
check "CM_HOLD_CLAIM_WAIT_S above 9999 is a usage error (exit 2), nothing made" '[ "$HRC" = 2 ] && [ ! -e "$CM_HOME/cutover-host.lock" ]' "$HOUT"
HOUT="$(CM_HOLD_CLAIM_WAIT_S=abc bash "$HOLD" release 2>&1)"; HRC=$?
check "a bad CM_HOLD_CLAIM_WAIT_S is a usage error (exit 2) for release too, before anything is touched" '[ "$HRC" = 2 ]' "$HOUT"
HOUT="$(CM_HOLD_CLAIM_WAIT_S=abc bash "$HOLD" status 2>&1)"; HRC=$?
check "...but a bad CM_HOLD_CLAIM_WAIT_S does not stop status, which never takes the claim (exit 1: not held)" '[ "$HRC" = 1 ] && printf "%s\n" "$HOUT" | grep -q "not held"' "$HOUT"

echo "--- r4: create that times out, inherited handles, model and effort, background tasks"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/create-times-out.plugly"
run_cut local --apply
LC="$(grep -n '^plugly terminal close --terminal pt-1' "$STUB_LOG" | head -n 1 | cut -d: -f1)"; LO="$(grep -n '^orca terminal create' "$STUB_LOG" | head -n 1 | cut -d: -f1)"
check "a create that times out but made a terminal: the stray plugly terminal is closed by exact handle BEFORE an Orca claude is created, one agent is left" \
  '[ "$RC" = 1 ] && [ -n "$LC" ] && [ -n "$LO" ] && [ "$LC" -lt "$LO" ] && [ "$("$SCRIPTS/live-agent.sh" "$(wof w-dev-1)" | wc -l | tr -d " ")" = 1 ] && [ "$(ledger_term w-dev-1)" = ot-2 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/create-odd-key.plugly"
run_cut local --apply
check "...also when the create answers with its handle under a key the parser does not read (found by the terminal list, not the answer)" \
  '[ "$RC" = 1 ] && muts | grep -q "^plugly terminal close --terminal pt-1" && [ "$("$SCRIPTS/live-agent.sh" "$(wof w-dev-1)" | wc -l | tr -d " ")" = 1 ] && [ "$(ledger_term w-dev-1)" = ot-2 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/create-times-out.plugly"; : > "$STUB_STATE/knob/close-fails.plugly"
run_cut local --apply
check "...and when that stray terminal will not close: LANE STRANDED (exit 3), no Orca terminal is created" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "LANE STRANDED" && ! muts | grep -q "^orca terminal create"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
sed -i "s#^\(ot-w[0-9]*\)\t[^\t]*\t#\1\t/another/tree\t#" "$STUB_STATE/terms.orca"
run_cut local --apply
check "an inherited handle (the terminal list shows it on another worktree) makes the lane manual: nothing is closed" \
  'plan_row w-dev-1 | grep -q "manual.*another worktree" && [ -z "$(muts)" ] && [ "$RC" = 4 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
echo 2 > "$STUB_STATE/knob/list-wrongpath-from.orca"
run_cut local --apply
check "...and the list is read again right before the close: a handle that moved to another worktree since the plan is not closed" \
  '[ "$RC" = 4 ] && printf "%s\n" "$OUT" | grep -q "does not list" && [ -z "$(muts)" ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude -
run_cut local --apply
check "a ledger row with no model at all is relaunched from the live pane: --model claude-sonnet-5-5 --effort high" \
  '[ "$RC" = 0 ] && muts | grep -q "^plugly terminal create .*--continue --model claude-sonnet-5-5 --effort high --json" && [ "$(ledger_term w-dev-1)" = pt-1 ]' "$OUT"
newcase; ADD_EFFORT=max add_lane w-dev-1 dev-1 false claude claude-opus-5-5
printf 'Opus 5.5 with max effort\n\n? for shortcuts\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply
check "the launch and the banner check use the live pane (an agreeing ledger is fine): --model claude-opus-5-5 --effort max, verified against an Opus 5.5 / max banner" \
  '[ "$RC" = 0 ] && muts | grep -q "^plugly terminal create .*--continue --model claude-opus-5-5 --effort max --json" && [ "$(ledger_term w-dev-1)" = pt-1 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude -
printf '  opus-5.5 · eff max · 🟢 3/50 · ctx [░░░░░░] 15%% · $0.96\n  ⏵⏵ bypass permissions on\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply
check "the real status-line form (model and effort on one line, the footer under it) is read: Opus 5.5 / max relaunched with no ledger model" \
  '[ "$RC" = 0 ] && muts | grep -q "^plugly terminal create .*--continue --model claude-opus-5-5 --effort max --json" && [ "$(ledger_term w-dev-1)" = pt-1 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude claude-sonnet-5-5
printf 'Opus 5.5 with high effort\n\n? for shortcuts\n' > "$STUB_STATE/knob/new-pane.plugly"
run_cut local --apply
check "a new terminal whose banner does not match the live model that was relaunched is rolled back (cutover failed: verify), not accepted" \
  '[ "$RC" = 1 ] && grep -q "cutover failed: verify" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'Sonnet 5.5 with high effort\n\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · 1 shell\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply --wait-idle-s 0
check "a prompt with a background shell is busy, not idle: not closed, skipped (exit 4)" \
  '[ "$RC" = 4 ] && printf "%s\n" "$OUT" | grep -q "pane still background" && [ -z "$(muts)" ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
printf 'Sonnet 5.5 with high effort\n  ◯ monitor: tail -f build.log\n? for shortcuts\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply --wait-idle-s 0
check "...and so is a prompt with a Monitor / background-subagent task row" '[ "$RC" = 4 ] && [ -z "$(muts)" ]' "$OUT"

echo "--- r4: locks, ledger truth, orphan rule, env, turn check, handle change"
newcase; add_lane w-dev-1 dev-1 false claude
(exec -a resume-fake sleep 60) & RPID=$!
cat > "$C/live-trip.sh" <<TRIP
#!/usr/bin/env bash
# the first live check of the run: a resume.sh run takes its lock, then the real live-agent.sh answers
if [ -e "$C/trip" ]; then rm -f "$C/trip"; mkdir "$CM_HOME/resume.lock"; echo $RPID > "$CM_HOME/resume.lock/pid"; fi
exec "$SCRIPTS/live-agent.sh" "\$@"
TRIP
chmod +x "$C/live-trip.sh"; : > "$C/trip"
OUT="$(CM_LIVE_AGENT="$C/live-trip.sh" bash "$CUT" local --apply 2>&1)"; RC=$?
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
check "a resume.sh run that starts after the pre-check but before the cutover lock is seen again after the lock: refused, nothing mutated, lock released" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "a resume.sh run started" && [ -z "$(muts)" ] && [ ! -e "$CM_HOME/cutover-host.lock" ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/send-fails.plugly"; : > "$STUB_STATE/knob/create-fails.orca"
run_cut local --apply
check "a LANE DOWN does not leave the ledger pointing at the dead plugly terminal: the handle is cleared and the report says so" \
  '[ "$RC" = 3 ] && [ "$(ledger_term w-dev-1)" = "" ] && printf "%s\n" "$OUT" | grep -q "was cleared"' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude; add_lane w-other other false claude
jq '.workers["w-other"].terminal = "ot-2"' "$CM_HOME/ledger.json" > "$CM_HOME/l.new" && mv "$CM_HOME/l.new" "$CM_HOME/ledger.json"
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"
run_cut local --apply --lane w-dev-1
check "a refused handle write in the rollback is reported, not hidden behind 'rolled back'" \
  'printf "%s\n" "$OUT" | grep -q "NOT restored" && grep -q "NOT restored" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'ot-shell\t%s\t\n' "$(wof w-dev-1)" >> "$STUB_STATE/terms.orca"
run_cut local --apply
check "the orphan check counts agent terminals only: a plain shell tab left on the worktree is not an orphan" \
  '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "orphan check clean"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
OUT="$(CM_CUTOVER_EXIT_WAIT_S="a[\$(touch $C/pwned)]" bash "$CUT" local --apply 2>&1)"; RC=$?
OUT2="$(CM_CUTOVER_POLL_S="1;touch $C/pwned2" bash "$CUT" local 2>&1)"; RC2=$?
check "the timing variables must be whole seconds: a command substitution in one is refused (exit 2) and never runs" \
  '[ "$RC" = 2 ] && [ "$RC2" = 2 ] && [ ! -e "$C/pwned" ] && [ ! -e "$C/pwned2" ] && [ -z "$(muts)" ]' "$OUT $OUT2"

newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/send-startup-write.plugly"
TD="$CM_CLAUDE_PROJECTS/$(printf '%s' "$(wof w-dev-1)" | sed 's#[^A-Za-z0-9]#-#g')"; mkdir -p "$TD"
jq -cn --arg t "$(bash -c ". '$SCRIPTS/lib.sh'; printf '%s' \"\$CM_NUDGE_TICK\"")" '{type:"user",timestamp:"2020-01-01T00:00:00.000Z",text:$t}' > "$TD/old.jsonl"
run_cut local --apply
check "a transcript write that is not the nudge (a startup write in the same second), with an OLD nudge in the history, is not a turn: rolled back (cutover failed: nudge)" \
  '[ "$RC" = 1 ] && grep -q "cutover failed: nudge" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
echo 2 > "$STUB_STATE/knob/read-moves-handle.orca"   # the plan reads the pane once; the idle wait is the 2nd read
run_cut local --apply
check "the live handle is resolved again after the idle wait: a lane whose terminal changed meanwhile is not closed" \
  '[ "$RC" = 4 ] && printf "%s\n" "$OUT" | grep -q "live handle changed during the idle wait" && [ -z "$(muts)" ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
OUT="$(CM_CUTOVER_EXIT_WAIT_S=08 CM_CUTOVER_VERIFY_WAIT_S=09 bash "$CUT" local --apply 2>&1)"; RC=$?
OUT2="$(CM_CUTOVER_CALL_S=0 bash "$CUT" local 2>&1)"; RC2=$?
OUT3="$(env -u CM_TEST CM_CUTOVER_POLL_S=0 bash "$CUT" local 2>&1)"; RC3=$?
check "zero-padded timing values are read as decimal (08 is not octal): the lane moves; CALL_S=0 and, outside the test, POLL_S=0 are refused (exit 2)" \
  '[ "$RC" = 0 ] && [ "$(ledger_term w-dev-1)" = pt-1 ] && [ "$RC2" = 2 ] && [ "$RC3" = 2 ]' "$OUT $OUT2 $OUT3"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/late-plugly-on-orca-create.orca"
run_cut local --apply
check "a plugly terminal that finishes creating after the Orca claude is up (the CLI call was cut off, the runtime was not) is found and closed by exact handle; the lane ends with exactly one agent" \
  'muts | grep -q "^plugly terminal close --terminal pt-late" && [ "$("$SCRIPTS/live-agent.sh" "$(wof w-dev-1)" | cut -f2 | sort -u | wc -l | tr -d " ")" = 1 ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'Sonnet 5.5 with high effort\n\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ctrl+t to show todos\n' > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
run_cut local --apply
check "a normal idle footer that mentions todos (a real Claude Code footer shape) is idle, not background: the lane moves" \
  '[ "$RC" = 0 ] && [ "$(ledger_term w-dev-1)" = pt-1 ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/late-plugly-on-orca-create.orca"; : > "$STUB_STATE/knob/close-lingers-late.plugly"
OUT="$(CM_CUTOVER_EXIT_WAIT_S=1 bash "$CUT" local --apply 2>&1)"; RC=$?
check "a closed late plugly claude that is still exiting when the Orca terminal is verified is STRANDED when it outlives the wait: the report names the verified Orca terminal and what to do, the ledger points at it" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "Orca terminal ot-2 is verified" && grep -q "NOT re-armed" "$CM_HOME/lanes/w-dev-1/journal.md" && [ "$(ledger_term w-dev-1)" = ot-2 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/late-plugly-on-orca-create.orca"; : > "$STUB_STATE/knob/close-lingers-late.plugly"
OUT="$(CM_CUTOVER_EXIT_WAIT_S=10 bash "$CUT" local --apply 2>&1)"; RC=$?
check "...but one that does exit within the wait is not a false STRANDED: the rollback completes with one agent and the /loop re-armed" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "re-arm nudge sent to ot-2" && [ "$("$SCRIPTS/live-agent.sh" "$(wof w-dev-1)" | cut -f2 | sort -u | wc -l | tr -d " ")" = 1 ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/close-answers-no.orca"
run_cut local --apply
check "a close that answers with a failure but happened is not reported as never closed: the terminal is gone, the rollback recreates an Orca terminal (exit 1, journal says so)" \
  '[ "$RC" = 1 ] && muts | grep -q "^orca terminal create" && ! grep -q "never closed" "$CM_HOME/lanes/w-dev-1/journal.md" && [ "$(ledger_term w-dev-1)" = ot-1 ]' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/close-answers-no-lingers.orca"
OUT="$(CM_CUTOVER_EXIT_WAIT_S=8 bash "$CUT" local --apply 2>&1)"; RC=$?
check "...also when its agent is still exiting at the first look: the judgement waits for the list and the agent to settle" \
  '[ "$RC" = 1 ] && muts | grep -q "^orca terminal create" && ! grep -q "never closed" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/no-agent.orca"
run_cut local --apply
check "a recreated Orca terminal that passes its banner check but runs no agent is LANE DOWN (exit 3), not a clean rollback" \
  '[ "$RC" = 3 ] && printf "%s\n" "$OUT" | grep -q "LANE DOWN" && ! grep -q "rolled back to Orca terminal" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'ot-w%s\t/other/tree\tclaude\n' "$HANDLE_N" >> "$STUB_STATE/terms.orca"
run_cut local --apply
check "a handle listed twice (once on another worktree) is manual: nothing is closed" \
  'plan_row w-dev-1 | grep -q "manual" && [ -z "$(muts)" ]' "$OUT"

echo "--- ssh target (a remote host's dry run)"
# ssh_case <ledger hosts map JSON>: a ledger with host-x on it and a plugly that lists host-x; the stub ssh records its argv
ssh_case() { newcase; add_lane w-dev-1 dev-1 false claude; jq --argjson hs "$1" '.hosts = $hs | .workers["w-dev-1"].host = "host-x"' "$CM_HOME/ledger.json" > "$CM_HOME/l.new" && mv "$CM_HOME/l.new" "$CM_HOME/ledger.json"; shape_hosts host-x > "$STUB_STATE/hosts.plugly.json"; }
ssh_case '{"host-x": {"hostname": "examplebox"}}'
run_cut host-x
check "a ledger hostname that is a bare word (what hostname -s prints) is NOT the ssh target: the host name is used as the ssh alias" \
  'grep -q -- "-- host-x bash -s" "$SSH_LOG" && ! grep -q -- "-- examplebox " "$SSH_LOG" && printf "%s\n" "$OUT" | grep -q "check claude-binary: ok"' "$(cat "$SSH_LOG"; echo "$OUT")"
ssh_case '{"host-x": {"hostname": "box.example.test"}}'
run_cut host-x
check "a ledger hostname that is an address (holds a dot) IS the ssh target" 'grep -q -- "-- box.example.test bash -s" "$SSH_LOG" && ! grep -q -- "-- host-x " "$SSH_LOG"' "$(cat "$SSH_LOG")"
ssh_case '{"host-x": {"hostname": "box.example.test", "sshTarget": "alias-z"}}'
run_cut host-x
check "an explicit ledger hosts.<h>.sshTarget beats the hostname and the host name (a host whose ssh name differs from both)" 'grep -q -- "-- alias-z bash -s" "$SSH_LOG" && ! grep -q -- "-- box.example.test \|-- host-x " "$SSH_LOG"' "$(cat "$SSH_LOG")"
ssh_case '{"host-x": {"hostname": "box.example.test"}}'
OUT="$(CM_SSH_TARGET=alias-y bash "$CUT" host-x 2>&1)"; RC=$?
check "CM_SSH_TARGET beats the ledger and the host name" 'grep -q -- "-- alias-y bash -s" "$SSH_LOG" && ! grep -q -- "-- box.example.test \|-- host-x " "$SSH_LOG"' "$(cat "$SSH_LOG")"
ssh_case '{}'
run_cut host-x
check "a host with no ledger entry at all (like a host registered without a hostname) uses the host name" 'grep -q -- "-- host-x bash -s" "$SSH_LOG"' "$(cat "$SSH_LOG")"
ssh_case '{"host-x": {"hostname": "-oProxyCommand=x.example.test"}}'
run_cut host-x
check "an ssh target that starts with a dash (ledger address) is refused by the pre-check (claude-binary), never handed to ssh" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check claude-binary: FAIL.*starts with a dash" && [ ! -s "$SSH_LOG" ]' "$OUT"
ssh_case '{}'
OUT="$(CM_SSH_TARGET='-oProxyCommand=x' bash "$CUT" host-x 2>&1)"; RC=$?
check "...and the same for CM_SSH_TARGET" '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check claude-binary: FAIL.*starts with a dash" && [ ! -s "$SSH_LOG" ]' "$OUT"
ssh_case '{}'
OUT="$(CM_SSH_TARGET='a b' bash "$CUT" host-x 2>&1)"; RC=$?
check "...and for a target with whitespace" '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check claude-binary: FAIL" && [ ! -s "$SSH_LOG" ]' "$OUT"
ssh_case '{}'
OUT="$(CM_SSH_TARGET=unreachable bash "$CUT" host-x 2>&1)"; RC=$?
check "an ssh target that does not resolve fails claude-binary with ssh's own message (exit 1, nothing changed)" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "check claude-binary: FAIL.*Could not resolve hostname unreachable" && [ -z "$(muts)" ]' "$OUT"

newcase; add_lane w-dev-1 dev-1 false claude
printf 'user@host:~/wt$ \n' > "$STUB_STATE/knob/new-pane.plugly"; : > "$STUB_STATE/knob/late-plugly-on-rearm.orca"; : > "$STUB_STATE/knob/close-lingers-late.plugly"
OUT="$(CM_CUTOVER_EXIT_WAIT_S=10 bash "$CUT" local --apply 2>&1)"; RC=$?
check "the final sweep of a stopped run closes a plugly terminal that lands after the rollback AND waits for its claude to exit: one agent when the script returns, no warning" \
  '[ "$RC" = 1 ] && muts | grep -q "^plugly terminal close --terminal pt-late" && ! printf "%s\n" "$OUT" | grep -q "WARNING: more than" && [ "$("$SCRIPTS/live-agent.sh" "$(wof w-dev-1)" | cut -f2 | sort -u | wc -l | tr -d " ")" = 1 ]' "$OUT"

newcase; ADD_EFFORT="" add_lane w-dev-1 dev-1 false claude
jq '.workers["w-dev-1"].effort = ""' "$CM_HOME/ledger.json" > "$CM_HOME/l.new" && mv "$CM_HOME/l.new" "$CM_HOME/ledger.json"
run_cut local --apply
check "a ledger effort that is present but empty is ignored: the live effort is the one relaunched" \
  '[ "$RC" = 0 ] && muts | grep -q "^plugly terminal create .*--effort high --json"' "$OUT"

echo "--- census"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/close-keeps.orca"
run_cut local --apply
check "the orphan check: an Orca terminal still open on a cut-over worktree makes the run exit 1 and lists it" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "ORPHANS: 1" && printf "%s\n" "$OUT" | grep -q "w-dev-1: Orca terminal $(hof w-dev-1) (claude) is still open" && printf "%s\n" "$OUT" | grep -q "refusing to finish"' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/no-agent.plugly"
printf 'Sonnet 5.5 with high effort\n\n? for shortcuts\n' > "$STUB_STATE/knob/new-pane.plugly"
run_cut local --apply
check "...an agent that never appears on the new terminal fails the handle step (rolled back), not silently" '[ "$RC" = 1 ] && grep -q "cutover failed: handle" "$CM_HOME/lanes/w-dev-1/journal.md"' "$OUT"
newcase; add_lane w-dev-1 dev-1 false claude
: > "$STUB_STATE/knob/close-keeps.orca"
run_cut local --apply --skip-census
check "--skip-census (test only) skips the orphan check" '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "orphan check skipped"' "$OUT"

echo "--- real footers: a Claude prompt that holds background work is BUSY (strings seen on live lanes)"
for sfx in '1 shell' '2 shells' '9 shells' '6 shells, 1 monitor'; do
  for pre in '' ' (shift+tab to cycle)'; do
    newcase; add_lane w-dev-1 dev-1 false claude
    printf '  sonnet-5.5 · eff high · 🟢 3/50 · ctx [░░░░░░] 15%% · $0.96\n  ⏵⏵ bypass permissions on%s · %s\n' "$pre" "$sfx" > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
    run_cut local --apply --wait-idle-s 0
    check "footer \"bypass permissions on${pre} · $sfx\" reads BUSY: skipped (exit 4), never closed" \
      '[ "$RC" = 4 ] && printf "%s\n" "$OUT" | grep -q "pane still background" && [ -z "$(muts)" ]' "$OUT"
  done
done
for bare in '  ⏵⏵ bypass permissions on' '  ⏵⏵ bypass permissions on (shift+tab to cycle)' '  ⏵⏵ bypass permissions on (shift+tab to cycle) · PR #7'; do
  newcase; add_lane w-dev-1 dev-1 false claude
  printf '  sonnet-5.5 · eff high · 🟢 3/50 · ctx [░░░░░░] 15%% · $0.96\n%s\n' "$bare" > "$STUB_STATE/screens/orca-$(hof w-dev-1)"
  run_cut local --apply
  check "the bare footer \"${bare# }\" (nothing running) reads idle: the lane is cut over" '[ "$RC" = 0 ] && [ "$(ledger_term w-dev-1)" = pt-1 ]' "$OUT"
done

echo "--- stub shapes: every stub reply carries the REAL key set (the lists below are copied from live runtimes; do not derive them from the stubs)"
REAL_ENVELOPE='_meta id ok result'
REAL_HOST_LOCAL='id kind machineName name platform selector'
REAL_HOST_ENV='id kind name selector'
REAL_TL_RESULT='hostScope terminals topologyRevisions totalCount truncated'
REAL_TERMINAL='agentIdentity branch connected executionHostId handle incarnationId lastOutputAt leafId orphaned preview ptyId tabId title worktreeId worktreePath writable'
REAL_PS_RESULT='hostScope totalCount truncated worktrees'
REAL_PS_COMMON='agents branch childWorktreeIds comment createdAt creatorProvenance displayName hasAttachedPty hasHostSidebarActivity hostId isActive isArchived isMainWorktree isPinned lastActivityAt lastOutputAt linkedGitLabIssue linkedGitLabMR linkedIssue linkedLinearIssue linkedPR liveTerminalCount parentWorktreeId path preview repo repoId sortOrder status terminalPlatform unread workspaceKind workspaceStatus worktreeId worktreeInstanceId'
REAL_PS_ORCA='defaultBranch linkedItems terminalVerdict unverifiableTerminalCount'
REAL_PS_PLUGLY='manualOrder'
REAL_WTLIST='branch childWorktreeIds comment displayName displayNameMode git head hostId id identity instanceId isArchived isBare isMainWorktree isPinned isUnread lastActivityAt lineage linkedAzureDevOpsPR linkedBitbucketPR linkedGitLabIssue linkedGitLabMR linkedGiteaPR linkedIssue linkedLinearIssue linkedLinearIssueOrganizationUrlKey linkedLinearIssueWorkspaceId linkedPR linkedTaskSourceContext linkedWorkItem manualOrder parentWorktreeId path repoId sortOrder workspaceStatus'
REAL_READ_TERMINAL='handle latestCursor limited nextCursor oldestCursor returnedLineCount source status tail tailRows truncated'
# has_keys <json> <jq path to an object> <key>...: the object at the path holds every key
has_keys() { local j="$1" path="$2"; shift 2; printf '%s' "$j" | jq -e --arg p "$path" --args 'getpath($p | split(".") | map(select(length > 0) | if test("^[0-9]+$") then tonumber else . end)) as $o | $ARGS.positional | all(. as $k | $o | has($k))' "$@" >/dev/null 2>&1; }
newcase; add_lane w-dev-1 dev-1 false claude
printf 'ot-shell\t/work/example/shell\t\n' >> "$STUB_STATE/terms.orca"; printf 'pt-shell\t/work/example/shell\t\n' >> "$STUB_STATE/terms.plugly"; printf 'pt-agent\t/work/example/agent\tclaude\n' >> "$STUB_STATE/terms.plugly"
for k in orca plugly; do
  STUB="$BIN/$k-stub"
  TL="$("$STUB" terminal list --json)"; HL="$("$STUB" host list --json)"; PS="$("$STUB" worktree ps --json)"; RD="$("$STUB" terminal read --terminal "$(hof w-dev-1)" --screen --json)"
  check "$k stub: every reply (host list, terminal list, worktree ps, terminal read) has the envelope keys _meta id ok result" \
    'for j in "$HL" "$TL" "$PS" "$RD"; do has_keys "$j" "" $REAL_ENVELOPE || exit 1; done'
  check "$k stub: host list carries the real local entry keys" 'has_keys "$HL" "result.hosts.0" $REAL_HOST_LOCAL'
  check "$k stub: terminal list carries the real result keys and, per agent terminal, the real terminal keys" \
    'has_keys "$TL" "result" $REAL_TL_RESULT && ag="$(printf "%s" "$TL" | jq -c "[.result.terminals[] | select(has(\"agentIdentity\"))][0]")" && [ "$ag" != null ] && has_keys "$ag" "" $REAL_TERMINAL'
  check "$k stub: a plain shell terminal has the real terminal keys minus agentIdentity (the real list omits it there)" \
    'sh="$(printf "%s" "$TL" | jq -c "[.result.terminals[] | select(.handle == \"${k:0:1}t-shell\" or .handle == \"ot-shell\" or .handle == \"pt-shell\")][0]")"; [ "$sh" != null ] && has_keys "$sh" "" ${REAL_TERMINAL#agentIdentity } && ! printf "%s" "$sh" | jq -e has\(\"agentIdentity\"\) >/dev/null'
  check "$k stub: worktree ps carries the real result keys and the real worktree keys" \
    'has_keys "$PS" "result" $REAL_PS_RESULT && has_keys "$PS" "result.worktrees.0" $REAL_PS_COMMON && has_keys "$PS" "result.worktrees.0" $([ "$k" = orca ] && echo $REAL_PS_ORCA || echo $REAL_PS_PLUGLY)'
  check "$k stub: terminal read carries the real terminal keys (tail among them)" 'has_keys "$RD" "result.terminal" $REAL_READ_TERMINAL'
done
check "plugly stub: worktree list carries the real keys" 'WL="$("$BIN/plugly-stub" worktree list --json)"; has_keys "$WL" "" $REAL_ENVELOPE && has_keys "$WL" "result" $REAL_PS_RESULT && has_keys "$WL" "result.worktrees.0" $REAL_WTLIST'
check "plugly stub: the host list names a local entry and an environment entry with their real keys" \
  'HL="$("$BIN/plugly-stub" host list --json)"; has_keys "$HL" "result.hosts.0" $REAL_HOST_LOCAL && has_keys "$HL" "result.hosts.1" $REAL_HOST_ENV'
check "the shape guard bites: a reply with one real key removed fails it (so a drifting stub cannot pass)" \
  'TL="$("$BIN/orca-stub" terminal list --json)"; has_keys "$TL" "result.terminals.0" $REAL_TERMINAL && ! has_keys "$(printf "%s" "$TL" | jq -c "del(.result.terminals[0].ptyId)")" "result.terminals.0" $REAL_TERMINAL && ! has_keys "$(printf "%s" "$TL" | jq -c "del(._meta)")" "" $REAL_ENVELOPE'

echo "--- repo guards"
OUTG="$(bash "$HERE/no-bare-orca.sh" 2>&1)"; RCG=$?
check "no-bare-orca.sh passes with the new script (no bare orca or plugly call)" '[ "$RCG" = 0 ]' "$(printf '%s\n' "$OUTG" | grep -v '^PASS' | head -n 8)"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck -x -S warning is clean on cutover-host.sh and this test" 'shellcheck -x -S warning "$CUT" "$HERE/cutover-host.sh"'
else
  ok "shellcheck not installed: skipped (said so)"
fi
check "the decoy orca/plugly on PATH were never called in this mode" '[ ! -s "$ROOT/decoy.log" ]'

printf '\n%s passed, %s failed (PATH mode: %s)\n' "$PASS" "$FAIL" "$MODE"
[ "$FAIL" = 0 ]
