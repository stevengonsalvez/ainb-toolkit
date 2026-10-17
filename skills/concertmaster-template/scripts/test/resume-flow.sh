#!/usr/bin/env bash
# resume-flow.sh: integration test for roster.sh and resume.sh with a STUBBED
# orca. A synthetic roster holds live, dead, offline, duplicate, missing and
# failed rows; the stub records every orca call and the test asserts which
# calls were made (and, more important, which were not), plus the table.
# Touches nothing outside a mktemp dir. No real orca, no network.
#
#   scripts/test/resume-flow.sh         # exit 0 when every case passes
# shellcheck disable=SC2016  # check bodies are single-quoted on purpose: they are eval-ed later
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Hermetic config: never the project config.yaml next to scripts/.
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE
SCRIPTS="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-resume-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
PROC_PID=""
trap '[ -z "$PROC_PID" ] || kill "$PROC_PID" 2>/dev/null; rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home"
STUB="$ROOT/stub"
mkdir -p "$CM_HOME" "$STUB" "$ROOT/bin" "$ROOT/wtproc"
# a real process named claude, with its cwd in a throwaway worktree: exercises the real process check
cp "$(command -v sleep)" "$ROOT/bin/claude"
( cd "$ROOT/wtproc" && exec "$ROOT/bin/claude" 120 ) </dev/null >/dev/null 2>&1 &
PROC_PID=$!
PROCWT="$(cd "$ROOT/wtproc" && pwd -P)"

# ---- stubbed orca -------------------------------------------------------------
cat > "$STUB/orca" <<'S'
#!/usr/bin/env bash
# Records the call, serves fixtures. Env: STUB_DIR.
echo "$*" >> "$STUB_DIR/calls.log"
arg() { local a; while [ $# -gt 1 ]; do [ "$1" = "$K" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2" in
  "worktree ps")
    env=local; K=--environment; v="$(arg "$@")"; [ -n "$v" ] && env="$v"
    [ -f "$STUB_DIR/ps-$env.json" ] || { echo "host offline" >&2; exit 1; }
    c=$(( $(cat "$STUB_DIR/pscount-$env" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STUB_DIR/pscount-$env"
    if [ "$c" -gt 1 ] && [ -f "$STUB_DIR/steal-lock" ]; then echo 99999 > "$CM_HOME/resume.lock/pid"; fi
    if [ "$c" -gt 1 ] && [ -f "$STUB_DIR/ps-$env.late.json" ]; then cat "$STUB_DIR/ps-$env.late.json"; else cat "$STUB_DIR/ps-$env.json"; fi ;;
  "terminal create")
    K=--worktree; sel="$(arg "$@")"
    case "$sel" in *fail-lane*) echo '{"ok":false}'; exit 1 ;; esac
    n=$(( $(cat "$STUB_DIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/n"
    echo "$sel" > "$STUB_DIR/handle-term_new_$n"
    printf '{"ok":true,"result":{"terminal":{"handle":"term_new_%s"}}}\n' "$n" ;;
  "terminal wait")
    K=--terminal; h="$(arg "$@")"
    if grep -q slow-lane "$STUB_DIR/handle-$h" 2>/dev/null; then
      echo '{"ok":true,"result":{"wait":{"satisfied":false}}}'
    else
      echo '{"ok":true,"result":{"wait":{"satisfied":true}}}'
    fi ;;
  "terminal read")
    K=--terminal; h="$(arg "$@")"
    if grep -q blind-lane "$STUB_DIR/handle-$h" 2>/dev/null; then echo "screen unavailable" >&2; exit 1; fi
    if grep -q replay-lane "$STUB_DIR/handle-$h" 2>/dev/null; then
      printf '{"ok":true,"result":{"screen":"old: Enter to select option\\n%s\\nClaude Code v2\\n> \\n  ? for shortcuts"}}\n' "$(printf 'transcript line\\n%.0s' $(seq 1 25))"
    elif grep -q shell-lane "$STUB_DIR/handle-$h" 2>/dev/null; then
      echo '{"ok":true,"result":{"screen":"bash: claude: No conversation found\n$ "}}'
    elif grep -q menu-lane "$STUB_DIR/handle-$h" 2>/dev/null; then
      echo '{"ok":true,"result":{"screen":"Which option?\n 1. yes\n Enter to select · Tab/Arrow keys to navigate"}}'
    else
      echo '{"ok":true,"result":{"screen":"Claude Code v2\n> \n  ? for shortcuts"}}'
    fi ;;
  "terminal send")
    echo '{"ok":true,"result":{"send":{"accepted":true}}}' ;;
  *) echo "stub orca: unexpected call: $*" >&2; exit 2 ;;
esac
S
chmod +x "$STUB/orca"
export STUB_DIR="$STUB" ORCA_CLI_COMMAND="$STUB/orca"
export CM_TEST=1
export CM_TEST_CLAUDE_CWDS_CMD="cat $STUB/cwds.txt"

ps_row() { # ps_row <path> <panes> <liveTerminalCount> [worktreeId]: panes = number of top-level agent panes
  jq -cn --arg p "$1" --argjson n "$2" --argjson t "$3" --arg id "${4:-wt-$(basename "$1")}" '
    {worktreeId: $id, path: $p, liveTerminalCount: $t,
     agents: [range(0; $n) | {paneKey: "p\(.)", parentPaneKey: null, state: "working"}]}'
}
{
  ps_row /x/pr-sweep 1 1                 # live
  ps_row /x/dev-sweeper 0 1              # dead: only a bare shell tab
  ps_row /x/ops-dup 2 2                  # duplicate: two agent panes
  ps_row /x/epic-pid 1 1                 # duplicate: one pane, two claude processes
  ps_row /x/research 0 1                 # live: no agent entry, but a claude process owns the cwd
  ps_row /x/menu-lane 0 1                # dead, but the resumed session shows a question menu
  ps_row /x/fail-lane 0 0                # dead, claude --continue cannot start
  ps_row /y/remote-dead 0 0              # dead on a remote host
  ps_row /y/stale-agent 1 0              # agent entry but no live terminal: dead
  ps_row /x/blind-lane 0 1               # dead, but its screen cannot be read: nudge held
  ps_row /x/slow-lane 0 1                # dead, resumed terminal never goes idle: failed
  ps_row /x/codex-lane 0 0               # dead, but the lane runs codex: manual
  jq -cn '{worktreeId: "wt-bad-lane", path: "/x/bad-lane", liveTerminalCount: 1, agents: ["not-an-object"]}'   # unreadable: unknown
  ps_row /x/twin-a 1 1                   # two rows, one lane name: labels need the worktree
  ps_row /x/twin-b 1 1
  ps_row /x/shell-lane 0 1               # dead, claude --continue falls back to a bare shell: failed, nothing typed
  ps_row /x/noagent-lane 0 0             # dead, but the ledger has no agent: manual
  ps_row /x/idle-lane 0 0                # dead standing lane whose last status was cm:idle
  ps_row /x/inject-lane 0 0              # dead; its ledger text carries shell metacharacters
  ps_row /x/replay-lane 0 0              # dead; the old menu is only in the replayed transcript, not at the bottom
  ps_row /x/late-lane 0 0                # dead at the census, live by the re-check
  ps_row /x/shared 0 0                   # two roster rows point here: no create
  ps_row /x/sub-lane 0 1                 # live through a claude process inside a subdirectory
  ps_row /x/idshared 0 0                 # two roster rows, different paths, one worktree id: no create
  ps_row /x/variant 0 0                  # two roster rows, /x/variant and /x/./variant/: no create
  ps_row /x/byid-live 0 0 wt-byid-live   # roster path stale, matched by id; the process is in Orca's path
  ps_row /x/byid 0 0 wt-by-id            # roster path differs, matched by worktreeId
  ps_row "$PROCWT" 0 1                   # a real claude-named process owns this cwd: live
} | jq -s '{ok: true, result: {worktrees: ., totalCount: length}}' > "$STUB/ps-local.json"
# the re-check sees a different world for late-lane: a live agent appeared after the census
jq '.result.worktrees |= map(if .path == "/x/late-lane" then .liveTerminalCount = 1 | .agents = [{paneKey: "p0", parentPaneKey: null, state: "working"}] else . end)' "$STUB/ps-local.json" > "$STUB/ps-local.late.json"
# remote host: dead row plus a stale agent entry; the offline host has no fixture
{ ps_row /y/remote-dead 0 0; ps_row /y/remote-bare 0 1; ps_row /y/lag 0 0
  jq -cn '{worktreeId: "wt-rn", path: "/y/remote-nocount", agents: [{paneKey: "p0", parentPaneKey: null, state: "working"}]}'
  jq -cn '{worktreeId: "wt-rf", path: "/y/remote-nofield"}'; } | jq -s '{ok: true, result: {worktrees: ., totalCount: length}}' > "$STUB/ps-remote-1.json"
printf '%s\n' /x/epic-pid /x/epic-pid /x/research /x/sub-lane/inner /x/byid-live > "$STUB/cwds.txt"

row() { # row <lane> <host> <path> <current> [agent] [state] [worktreeId]
  local agent='"claude"' wid=null; [ -n "${5:-}" ] && agent="\"$5\""; [ "${5:-}" = NONE ] && agent=null
  [ -n "${7:-}" ] && wid="\"$7\""
  printf -- '- lane: "%s"\n  host: "%s"\n  worktree: "%s"\n  worktreeId: %s\n  terminal: null\n  model: "sonnet"\n  agent: %s\n  beadsEpic: null\n  current: %s\n  prs: [4612]\n  state: "%s"\n  updatedAt: 2026-10-13T08:00:00Z\n' "$1" "$2" "$3" "$wid" "$agent" "$(jq -cn --arg c "$4" '$c')" "${6:-cm:running}"
}
{
  echo '# test roster'
  row pr-sweeper local /x/pr-sweep "#4641 merge sweep"
  row dev-sweeper local /x/dev-sweeper "#4612 calendar export"
  row ops-dup local /x/ops-dup "#1700 fault"
  row epic-pid local /x/epic-pid "epic work"
  row research local /x/research "#1701 question"
  row menu-lane local /x/menu-lane "#4702 menu"
  row fail-lane local /x/fail-lane "#4703 fail"
  row remote-lane remote-1 /y/remote-dead "#4704 remote"
  row stale-lane local /y/stale-agent "#4705 stale"
  row epic-offline mac-1 /m/offline "#4706 offline"
  row ghost local /x/ghost "#4707 ghost"
  row blind-lane local /x/blind-lane "#4708 blind"
  row slow-lane local /x/slow-lane "#4709 slow"
  row codex-lane local /x/codex-lane "#4710 codex" codex
  row bad-lane local /x/bad-lane "#4711 bad"
  row remote-bare remote-1 /y/remote-bare "#4712 bare"
  row twin local /x/twin-a "twin a"
  row twin local /x/twin-b "twin b"
  row shell-lane local /x/shell-lane "#4713 shell"
  row noagent-lane local /x/noagent-lane "#4714 noagent" NONE
  row idle-lane local /x/idle-lane "#4715 idle" claude "cm:idle 3 open beads"
  row inject-lane local /x/inject-lane '#4716 migrate a > b; ls | tee x && echo `id` $(id) "q" '"'"'z'"'"
  row replay-lane local /x/replay-lane "#4719 replay"
  row late-lane local /x/late-lane "#4720 late"
  row shared-a local /x/shared "shared a"
  row shared-b local /x/shared "shared b"
  row byid-lane local /elsewhere/byid "#4721 byid" claude "cm:running" wt-by-id
  row sub-lane local /x/sub-lane "sub lane"
  row idshared-a local /nowhere/a "id shared a" claude "cm:running" wt-idshared
  row idshared-b local /nowhere/b "id shared b" claude "cm:running" wt-idshared
  row variant-a local /x/variant "variant a"
  row variant-b local /x/./variant/ "variant b"
  row lag-a remote-1 /y/lag-a "lag a" claude "cm:running" wt-lag
  row lag-b remote-1 /y/lag-b "lag b" claude "cm:running" wt-lag
  row byid-live local /stale/byid-live "#4722 byid live" claude "cm:running" wt-byid-live
  row remote-nocount remote-1 /y/remote-nocount "#4717 nocount"
  row remote-nofield remote-1 /y/remote-nofield "#4718 nofield"
} > "$CM_HOME/roster.yaml"
# a fresh roster and no ledger: used as is
: > "$STUB/calls.log"
OUT="$("$SCRIPTS/resume.sh" 2>"$ROOT/err.txt")"; RC=$?
[ "$RC" = 0 ] || [ "$RC" = 3 ] || { echo "resume.sh failed rc=$RC"; cat "$ROOT/err.txt"; exit 1; }
CALLS="$(cat "$STUB/calls.log")"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1"; fi; }
has_line() { printf '%s\n' "$OUT" | grep -Eq "$1"; }
creates() { printf '%s\n' "$CALLS" | grep -c '^terminal create'; }
sends() { printf '%s\n' "$CALLS" | grep -c '^terminal send'; }

echo "--- table"
printf '%s\n' "$OUT"
echo "--- checks"
check "live row left alone"                        'has_line "pr-sweeper +live +left alone"'
check "dead row: claude --continue then nudged"    'has_line "dev-sweeper +dead +claude --continue --model sonnet, nudged \(#4612\)"'
check "offline host skipped, retry next tick"      'has_line "epic-offline +offline +retry next tick"'
check "two agent panes: duplicate"                 'has_line "ops-dup +duplicate +sent to neither, ask Owner"'
check "two claude processes on one cwd: duplicate" 'has_line "epic-pid +duplicate +sent to neither, ask Owner"'
check "claude process with no agent entry: live"   'has_line "research +live +left alone"'
check "menu showing: resumed, nudge held"          'has_line "menu-lane +held +claude --continue --model sonnet started in terminal term_new_[0-9]+, nudge not sent \(question menu"'
check "terminal create failure: failed"            'has_line "fail-lane +failed +.*respawn with a handover"'
check "remote dead row: resumed and nudged"        'has_line "remote-lane +dead +claude --continue --model sonnet, nudged \(#4704\)"'
check "stale agent entry, no live terminal: dead"  'has_line "stale-lane +dead +claude --continue --model sonnet, nudged \(#4705\)"'
check "worktree absent on a reachable host: missing" 'has_line "ghost +missing +"'
check "screen unreadable: resumed, nudge held, never sent" 'has_line "blind-lane +held +.*nudge not sent \(screen unreadable"'
check "terminal never idle: failed, handle reported"  'has_line "slow-lane +failed +.*never went idle \(terminal term_new_[0-9]+ left open\)"'
check "codex lane: manual, not claude --continue"   'has_line "codex-lane +manual +agent is codex"'
check "unreadable live count: unknown, left alone"  'has_line "bad-lane +unknown +live count unreadable, left alone"'
check "remote open terminal, no agent entry: unknown" 'has_line "remote-bare +unknown +terminal open, no agent entry"'
check "same lane on two rows: labelled by worktree" 'has_line "twin:twin-a +live" && has_line "twin:twin-b +live"'
check "bare shell after claude --continue: failed, nothing typed" 'has_line "shell-lane +failed +shell prompt on screen, not Claude \(terminal term_new_[0-9]+ left open\)"'
check "no agent in the ledger: manual"              'has_line "noagent-lane +manual +agent unknown"'
check "remote row with a working agent and no count: live" 'has_line "remote-nocount +live"'
check "remote row with no count and no agent: unknown"     'has_line "remote-nofield +unknown"'
check "model flag passed to claude --continue"      'printf "%s\n" "$CALLS" | grep "^terminal create" | grep "dev-sweeper" | grep -q -- "--command claude --continue --model sonnet"'
check "cm:idle lane: nudge says restore the status, not carry on" 'idle_h="$(grep -l idle-lane "$STUB"/handle-* | sed "s#.*handle-##")"; printf "%s\n" "$CALLS" | grep "^terminal send" | grep -- "--terminal $idle_h" | grep -q "restore that status"'
check "needs-attention rows: exit 3"                  '[ "$RC" = 3 ]'
check "menu only in the replayed transcript, Claude at the bottom: nudged" 'has_line "replay-lane +dead +.*nudged \(#4719\)"'
check "live agent appeared since the census: re-check stops the create" 'has_line "late-lane +live +live agent appeared since the census"'
check "two roster rows on one worktree: one decision, none acted"   'has_line "shared-a +duplicate +roster rows share" && has_line "shared-b +duplicate +roster rows share" && has_line "^ask Owner: shared-a: several roster rows"'
check "matched by worktreeId when the roster path differs"          'has_line "byid-lane +dead +.*nudged \(#4721\)"'
check "matched by id with a stale roster path: the process check uses Orca's path" 'has_line "byid-live +live +left alone"'
check "claude process inside a subdirectory counts as live"         'has_line "sub-lane +live +left alone"'
check "nudge text has no shell metacharacter, quote or backtick"    'line="$(printf "%s\n" "$CALLS" | grep "^terminal send" | grep "migrate a")"; [ -n "$line" ] && ! printf "%s" "$line" | grep -q "[;|&<>\`$\"]" && ! printf "%s" "$line" | grep -q "[$(printf "\047")]"'
check "one worktree id, two roster paths: duplicate, none acted" 'has_line "idshared-a +duplicate +roster rows resolve to one worktree" && has_line "idshared-b +duplicate +roster rows resolve to one worktree"'
check "path variants of one worktree (/x/./variant/): duplicate"  'has_line "variant-a +duplicate" && has_line "variant-b +duplicate"'
check "remote census lag, rows differing by path, one id: duplicate" 'has_line "lag-a +duplicate +roster rows resolve to one worktree" && has_line "lag-b +duplicate +roster rows resolve to one worktree"'
check "duplicates produce ask lines"               'has_line "^ask Owner: ops-dup: 2 live agents" && has_line "^ask Owner: epic-pid: 2 live agents"'
check "no ask line for live, dead or offline rows" '! has_line "^ask Owner: (pr-sweeper|dev-sweeper|research|epic-offline)"'

echo "--- calls"
check "terminal create only for the 12 resumable dead rows (dev, menu, fail, remote, stale, blind, slow, shell, idle, inject, replay, byid)" '[ "$(creates)" = 12 ]'
check "nudge sent to exactly 7 (dev, remote, stale, idle, inject, replay, byid; never menu, fail, blind, slow, shell)" '[ "$(sends)" = 7 ]'
for forbidden in idshared variant wt-lag byid-live shared late-lane sub-lane pr-sweep ops-dup epic-pid research ghost offline codex-lane bad-lane remote-bare twin noagent-lane remote-nocount remote-nofield; do
  check "no create or send touching $forbidden"    '! printf "%s\n" "$CALLS" | grep -E "^terminal (create|send)" | grep -q "$forbidden"'
done
check "remote resume targets its environment"      'printf "%s\n" "$CALLS" | grep "^terminal create" | grep -q -- "--environment remote-1"'
check "local resume has no --environment"          '! printf "%s\n" "$CALLS" | grep "^terminal create" | grep "dev-sweeper" | grep -q -- "--environment"'
check "resume uses the worktree id, same worktree" 'printf "%s\n" "$CALLS" | grep "^terminal create" | grep -q -- "--worktree id:wt-dev-sweeper"'
check "no send to the blind or slow terminals"      'for l in blind-lane slow-lane shell-lane; do h="$(grep -l "$l" "$STUB"/handle-* | sed "s#.*handle-##")"; ! printf "%s\n" "$CALLS" | grep "^terminal send" | grep -q -- "--terminal $h" || exit 1; done'
check "nudge names current (#4612 calendar export)" 'printf "%s\n" "$CALLS" | grep "^terminal send" | grep -q "#4612 calendar export"'
check "the menu terminal got a read but no send"   'menu_h="$(grep -l menu-lane "$STUB"/handle-* | sed "s#.*handle-##")"; printf "%s\n" "$CALLS" | grep -q "^terminal read --terminal $menu_h" && ! printf "%s\n" "$CALLS" | grep "^terminal send" | grep -q -- "--terminal $menu_h"'
check "claude --continue is the command"           'printf "%s\n" "$CALLS" | grep "^terminal create" | grep -q -- "--command claude --continue"'

echo "--- a failed resume is not repeated every tick"
: > "$STUB/calls.log"
OUT="$("$SCRIPTS/resume.sh" --lane shell-lane 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "failed attempt in the last 30 min: no second terminal" 'has_line "shell-lane +failed +resume already tried in the last 30 min" && [ "$(creates)" = 0 ]'

echo "--- dry run"
: > "$STUB/calls.log"; rm -f -- "${STUB:?}"/handle-* "${STUB:?}/n" "${STUB:?}"/pscount-*; rm -rf -- "${CM_HOME:?}/resume.attempts"
OUT="$("$SCRIPTS/resume.sh" --dry-run 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "dry run: no create, no send"                '[ "$(creates)" = 0 ] && [ "$(sends)" = 0 ]'
check "dry run: dead row reported as would resume" 'has_line "dev-sweeper +dead +would claude --continue --model sonnet, nudge \(#4612\)"'

echo "--- roster.sh"
cat > "$CM_HOME/ledger.json" <<'J'
{"updatedAt": "2026-10-13T08:00:00Z",
 "prs": {"r#4612": {"number": 4612, "driver": "w-dev"}, "r#4637": {"number": 4637, "driver": "w-dev"}, "r#1": {"number": 1, "driver": "w-other"}},
 "workers": {
  "w-dev":  {"lane": "dev-sweeper", "host": "local", "agent": "claude", "model": "sonnet", "path": "/x/dev-sweeper", "terminal": "term_4535d409",
             "model": "sonnet", "beadsEpic": "acme-dev", "task": "#4612 calendar export ghp_abcdefghijkl1234",
             "lastComment": "cm:idle 8 open beads", "updatedAt": "2026-10-13T08:00:00Z", "secret": "must-not-appear"},
  "w-gone": {"lane": "x", "host": "local", "path": "/x/gone", "state": "gone"},
  "w-done": {"lane": "y", "host": "local", "path": "/x/done", "state": "retired"}}}
J
rm -f "$CM_HOME/roster.yaml"
"$SCRIPTS/roster.sh"; R="$CM_HOME/roster.yaml"
check "roster written with mode 600"               '[ "$(stat -c %a "$R" 2>/dev/null || stat -f %Lp "$R")" = 600 ]'
check "roster holds the active row only"           '[ "$(grep -c "^- lane:" "$R")" = 1 ] && grep -q "lane: \"dev-sweeper\"" "$R"'
check "roster carries the spec fields"             'for k in lane host worktree terminal model beadsEpic current prs state updatedAt; do grep -Eq "^(- |  )$k:" "$R" || { echo "missing $k" >&2; exit 1; }; done'
check "prs come from the PRs this worker drives"   'grep -q "prs: \[4612,4637\]" "$R"'
check "token-shaped text redacted, no extra fields" '! grep -q "ghp_abcdefghijkl1234\|must-not-appear" "$R" && grep -q "\[redacted\]" "$R"'
check "no temp file left behind"                   '[ -z "$(ls -A "$CM_HOME" | grep "^\.roster")" ]'
cp "$R" "$ROOT/roster.before"
echo not-json > "$CM_HOME/ledger.json"
check "unreadable ledger: roster untouched, exit 1" '! "$SCRIPTS/roster.sh" 2>/dev/null && cmp -s "$R" "$ROOT/roster.before"'

echo "--- resume with a missing roster"
cat > "$CM_HOME/ledger.json" <<'J'
{"updatedAt": "2026-10-13T08:00:00Z",
 "workers": {"w-dev": {"lane": "dev-sweeper", "host": "local", "agent": "claude", "model": "sonnet", "path": "/x/dev-sweeper", "task": "#4612 calendar export", "lastComment": "cm:running"}}}
J
rm -f "$R"; : > "$STUB/calls.log"; rm -f -- "${STUB:?}"/handle-* "${STUB:?}/n" "${STUB:?}"/pscount-*; rm -rf -- "${CM_HOME:?}/resume.attempts"
OUT="$("$SCRIPTS/resume.sh" 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "missing roster: rewritten from ledger, then resumed" '[ -s "$R" ] && has_line "dev-sweeper +dead +claude --continue --model sonnet, nudged \(#4612\)"'
rm -f "$R" "$CM_HOME/ledger.json"; : > "$STUB/calls.log"
check "no roster and no ledger: exit 1, no orca call" '! "$SCRIPTS/resume.sh" >/dev/null 2>&1 && [ ! -s "$STUB/calls.log" ]'

echo "--- stale roster: a worker the ledger retired is not resumed"
cat > "$CM_HOME/ledger.json" <<'J'
{"updatedAt": "2026-10-13T09:00:00Z",
 "workers": {"w-dev": {"lane": "dev-sweeper", "host": "local", "agent": "claude", "model": "sonnet", "path": "/x/dev-sweeper", "task": "#4612 calendar export", "lastComment": "cm:running"},
             "w-ret": {"lane": "ghost-retired", "host": "local", "path": "/x/blind-lane", "state": "retired"}}}
J
{ row dev-sweeper local /x/dev-sweeper "#4612 calendar export"; row ghost-retired local /x/blind-lane "#4708 retired"; } > "$R"
touch -d '2 hours ago' "$R" 2>/dev/null || touch -t 202610130600 "$R"
: > "$STUB/calls.log"; rm -f -- "${STUB:?}"/handle-* "${STUB:?}/n" "${STUB:?}"/pscount-*; rm -rf -- "${CM_HOME:?}/resume.attempts"
OUT="$("$SCRIPTS/resume.sh" 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "stale roster rewritten: retired worker left out" '! has_line "ghost-retired" && has_line "dev-sweeper +dead"'
check "retired worker's tree got no create or send"   '! printf "%s\n" "$CALLS" | grep -E "^terminal (create|send)" | grep -q "blind-lane"'

echo "--- one row only (what the tick's standing-dead uses)"
cat > "$CM_HOME/ledger.json" <<'J'
{"updatedAt": "2026-10-13T09:00:00Z",
 "workers": {"w-dev": {"lane": "dev-sweeper", "host": "local", "agent": "claude", "model": "sonnet", "path": "/x/dev-sweeper", "task": "#4612 calendar export", "lastComment": "cm:running"},
             "w-menu": {"lane": "menu-lane", "host": "local", "agent": "claude", "model": "sonnet", "path": "/x/menu-lane", "task": "#4702 menu", "lastComment": "cm:running"}}}
J
: > "$STUB/calls.log"; rm -f -- "${STUB:?}"/handle-* "${STUB:?}/n" "${STUB:?}"/pscount-*; rm -rf -- "${CM_HOME:?}/resume.attempts"
OUT="$("$SCRIPTS/resume.sh" --path /x/dev-sweeper/ 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "--path: only that row is acted on"            '[ "$(creates)" = 1 ] && has_line "dev-sweeper +dead" && ! has_line "menu-lane"'
OUT="$("$SCRIPTS/resume.sh" --lane no-such-lane 2>/dev/null)"
check "--lane with no match: nothing to resume, exit 5" '"$SCRIPTS/resume.sh" --lane no-such-lane >/dev/null 2>&1; [ $? = 5 ]'

echo "--- fail closed on the process check, truncated census, host filter, budget"
echo '{"ok":true,"result":{"worktrees":[],"truncated":true}}' > "$STUB/ps-bigbox.json"
cat > "$CM_HOME/ledger.json" <<'J'
{"updatedAt": "2026-10-13T09:00:00Z",
 "workers": {"w-dev": {"lane": "dev-sweeper", "host": "local", "agent": "claude", "model": "sonnet", "path": "/x/dev-sweeper", "task": "#4612 calendar export", "lastComment": "cm:running"},
             "w-rem": {"lane": "remote-lane", "host": "remote-1", "agent": "claude", "model": "sonnet", "path": "/y/remote-dead", "task": "#4704 remote", "lastComment": "cm:running"},
             "w-big": {"lane": "big-lane", "host": "bigbox", "agent": "claude", "path": "/z/big", "task": "far away", "lastComment": "cm:running"}}}
J
: > "$STUB/calls.log"; rm -f -- "${STUB:?}"/handle-* "${STUB:?}/n" "${STUB:?}"/pscount-*; rm -rf -- "${CM_HOME:?}/resume.attempts"
OUT="$(CM_TEST_CLAUDE_CWDS_CMD=false "$SCRIPTS/resume.sh" --host local 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "process check cannot run: local dead row is unknown, no create" 'has_line "dev-sweeper +unknown +process check unavailable" && [ "$(creates)" = 0 ]'
OUT="$("$SCRIPTS/resume.sh" --host bigbox 2>/dev/null)"
check "truncated census: unknown, not missing"       'has_line "big-lane +unknown +census truncated" && ! has_line "^ask Owner"'
: > "$STUB/calls.log"
OUT="$("$SCRIPTS/resume.sh" --host remote-1 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "--host: only that host's row is acted on"     'has_line "remote-lane +dead" && ! has_line "dev-sweeper" && [ "$(creates)" = 1 ]'
: > "$STUB/calls.log"; rm -f -- "${STUB:?}"/handle-* "${STUB:?}/n" "${STUB:?}"/pscount-*; rm -rf -- "${CM_HOME:?}/resume.attempts"
OUT="$(CM_RESUME_BUDGET_S=-1 "$SCRIPTS/resume.sh" --host local 2>/dev/null)"
# shellcheck disable=SC2034  # BRC is read inside the eval-ed check below
BRC=$?
CALLS="$(cat "$STUB/calls.log")"
check "run budget used: dead row deferred, no create, exit 6 (run again)" 'has_line "dev-sweeper +deferred +run budget used" && [ "$(creates)" = 0 ] && [ "$BRC" = 6 ]'

jq --arg p "$PROCWT" '.workers["w-proc"] = {lane: "proc-lane", host: "local", agent: "claude", path: $p, task: "real process", lastComment: "cm:running"}' "$CM_HOME/ledger.json" > "$CM_HOME/ledger.tmp" && mv "$CM_HOME/ledger.tmp" "$CM_HOME/ledger.json"
: > "$STUB/calls.log"
OUT="$(env -u CM_TEST_CLAUDE_CWDS_CMD "$SCRIPTS/resume.sh" --lane proc-lane 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
check "real process check: a process named claude with its cwd in the worktree is live" 'has_line "proc-lane +live +left alone" && [ "$(creates)" = 0 ]'

echo "--- lock ownership is checked again right before a create"
cat > "$CM_HOME/ledger.json" <<'J'
{"updatedAt": "2026-10-13T09:00:00Z",
 "workers": {"w-dev": {"lane": "dev-sweeper", "host": "local", "agent": "claude", "model": "--dangerously-skip-permissions", "path": "/x/dev-sweeper", "task": "#4612 calendar export", "lastComment": "cm:running"}}}
J
: > "$STUB/calls.log"; rm -f -- "${STUB:?}"/handle-* "${STUB:?}/n" "${STUB:?}"/pscount-*; rm -rf -- "${CM_HOME:?}/resume.attempts"; touch "$STUB/steal-lock"
OUT="$("$SCRIPTS/resume.sh" --lane dev-sweeper 2>/dev/null)"; CALLS="$(cat "$STUB/calls.log")"
rm -f "$STUB/steal-lock"; rm -rf -- "${CM_HOME:?}/resume.lock"
check "lock taken over after the census: unknown, no create" 'has_line "dev-sweeper +unknown +lost the resume lock" && [ "$(creates)" = 0 ]'
OUT="$("$SCRIPTS/resume.sh" --dry-run --lane dev-sweeper 2>/dev/null)"
check "a model value starting with a dash is not passed to claude" '! has_line "--model" && has_line "dev-sweeper +dead +would claude --continue, nudge"'
env -u CM_TEST "$SCRIPTS/resume.sh" --dry-run --lane dev-sweeper > /dev/null 2> "$ROOT/gate.err"
check "process-check override is ignored without CM_TEST=1"  'grep -q "ignored (it needs CM_TEST=1)" "$ROOT/gate.err"'

echo "--- lock"
mkdir "$CM_HOME/resume.lock"; echo "$$" > "$CM_HOME/resume.lock/pid"
: > "$STUB/calls.log"
check "live lock holder: exit 4, no orca call"       '"$SCRIPTS/resume.sh" >/dev/null 2>&1; [ $? = 4 ] && [ ! -s "$STUB/calls.log" ]'
echo 999999 > "$CM_HOME/resume.lock/pid"
check "stale lock reclaimed, run proceeds, lock released" '"$SCRIPTS/resume.sh" >/dev/null 2>&1; [ ! -d "$CM_HOME/resume.lock" ]'

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
