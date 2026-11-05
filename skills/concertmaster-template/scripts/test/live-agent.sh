#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2016  # check bodies are single-quoted on purpose: they are eval-ed later
# live-agent.sh (test): behaviour tests for scripts/live-agent.sh and for lib.sh cm_worker_set_handle.
# Covers: a live agent found with its real handle; a different worktree that only shares a path prefix;
# a shell, an editor and sleep in the worktree; a subdirectory cwd; an interpreter wrapper (node, bun)
# with options; a configured agent list; no /proc; an unreadable own-uid entry; a tty-less broker and a
# zombie; a remote host over a stubbed ssh (wrong machine, FQDN, down); cm_worker_set_handle guards
# (unknown worker, bad handle, a handle another live worker holds, --by-path with none or two matches).
# Touches nothing outside a mktemp dir. No real orca, no network. The scans use a fake /proc under that
# dir; one case (CM_PROC_ROOT without CM_TEST=1) lets live-agent.sh read the real /proc, read-only.
#
#   scripts/test/live-agent.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_SSH_TARGET CM_LEDGER
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-live-agent.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_TEST=1
mkdir -p "$HOME" "$CM_HOME"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1"; fi; }

LA="$SCRIPTS/live-agent.sh"
WT="$ROOT/wt/lane-a"            # the worktree under test
WT2="$ROOT/wt/lane-a2"          # shares the prefix "lane-a" with WT, is not WT
mkdir -p "$WT" "$WT/src/inner" "$WT2"
P="$ROOT/proc"                      # the fake /proc

# mkproc <pid> <cwd> <environ-kv-or-empty> <argv...>: one fake pid dir (cmdline and environ NUL separated;
# stat as the kernel writes it, state PSTATE and terminal PTTY: an Orca agent runs on a pty)
PSTATE=S; PTTY=34816
mkproc() {
  local pid="$1" cwd="$2" env="$3"; shift 3
  mkdir -p "$P/$pid"
  printf '%s (%s) %s 1 %s %s %s -1 4194560\n' "$pid" "claude (x) y" "$PSTATE" "$pid" "$pid" "$PTTY" > "$P/$pid/stat"
  ln -sfn "$cwd" "$P/$pid/cwd"
  printf '%s\0' "$@" > "$P/$pid/cmdline"
  if [ -n "$env" ]; then printf 'HOME=/h/x\0%s\0PATH=/usr/bin\0' "$env" > "$P/$pid/environ"; else printf 'HOME=/h/x\0PATH=/usr/bin\0' > "$P/$pid/environ"; fi
}
reset_proc() { rm -rf -- "${P:?}"; mkdir -p "$P"; }
la() { CM_PROC_ROOT="$P" "$LA" "$@"; }

echo "--- live-agent.sh: what counts as a live agent"
reset_proc
mkproc 101 "$WT" "ORCA_TERMINAL_HANDLE=term_real_1" /usr/local/bin/claude --dangerously-skip-permissions
OUT="$(la "$WT")"; RC=$?
check "live claude in the worktree: exit 0, pid<TAB>handle<TAB>agent" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "101\tterm_real_1\tclaude")" ]'

reset_proc
mkproc 102 "$WT2" "ORCA_TERMINAL_HANDLE=term_other" claude
OUT="$(la "$WT")"; RC=$?
check "agent in a DIFFERENT worktree that only shares a path prefix: not a match, exit 1" '[ "$RC" = 1 ] && [ -z "$OUT" ]'
OUT="$(la "$WT2")"; RC=$?
check "the same process is a match for its own worktree" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "102\tterm_other\tclaude")" ]'

reset_proc
mkproc 103 "$WT" "ORCA_TERMINAL_HANDLE=term_sh" -bash
mkproc 104 "$WT" "" /usr/bin/vim notes.md
mkproc 105 "$WT" "" /usr/bin/sleep 600
OUT="$(la "$WT")"; RC=$?
check "a shell, an editor and sleep in the worktree are not agents: exit 1" '[ "$RC" = 1 ] && [ -z "$OUT" ]'

reset_proc
mkproc 106 "$WT/src/inner" "ORCA_TERMINAL_HANDLE=term_sub" claude
OUT="$(la "$WT/")"; RC=$?
check "agent whose cwd is inside the worktree matches (trailing slash on the argument too)" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "106\tterm_sub\tclaude")" ]'

reset_proc
mkproc 107 "$WT" "ORCA_TERMINAL_HANDLE=term_node" /usr/bin/node /opt/cli/claude --continue
mkproc 108 "$WT" "ORCA_TERMINAL_HANDLE=term_codex" codex
mkproc 109 "$WT" "ORCA_TERMINAL_HANDLE=term_agy" /x/bin/agy
OUT="$(la "$WT" | sort -n | cut -f3 | tr '\n' ' ')"
check "default agents: claude behind node, codex and agy all match" '[ "$OUT" = "claude codex agy " ]'

reset_proc
mkproc 112 "$WT" "ORCA_TERMINAL_HANDLE=term_flags" /usr/bin/node --max-old-space-size=4096 /opt/cli/claude --continue
OUT="$(la "$WT")"
check "an interpreter with options still matches on the first non-option argument" '[ "$OUT" = "$(printf "112\tterm_flags\tclaude")" ]'

reset_proc
mkproc 116 "$WT" "ORCA_TERMINAL_HANDLE=term_req" /usr/bin/node -r ./preload.js /opt/cli/claude --continue
mkproc 117 "$WT" "ORCA_TERMINAL_HANDLE=term_imp" /usr/bin/node --import ./hook.mjs --require=other.js /opt/cli/codex
mkproc 118 "$WT" "" /usr/bin/node -r ./preload.js /opt/tools/build.js
OUT="$(la "$WT" | sort -n)"
check "node -r / --import take a value: the value is skipped, the next word is the command; a non-agent script stays a non-match" '[ "$OUT" = "$(printf "116\tterm_req\tclaude\n117\tterm_imp\tcodex")" ]'
mkproc 119 "$WT" "" /usr/bin/node -r
OUT="$(timeout 10 env CM_PROC_ROOT="$P" "$LA" "$WT" 2>&1 | sort -n | wc -l | tr -d " ")"; RC=${PIPESTATUS[0]}
check "node with an option and no value after it does not loop or crash (no timeout, exit 0)" '[ "$OUT" = 2 ] && [ "$RC" = 0 ]'
reset_proc
mkproc 124 "$WT" "" /usr/bin/node -e 'console.log(1)' claude
mkproc 126 "$WT" "" /usr/bin/node -p 1 codex
mkproc 127 "$WT" "" /usr/bin/bun -e x agy
OUT="$(la "$WT")"; RC=$?
check "node -e / -p / bun -e: the word after inline code is an argument, not the command: exit 1" '[ "$RC" = 1 ] && [ -z "$OUT" ]'

reset_proc
mkproc 122 "$WT" "ORCA_TERMINAL_HANDLE=term_nonul" /usr/bin/node /opt/cli/x
printf '/usr/bin/node\0/opt/cli/claude' > "$P/122/cmdline"     # the last word has no closing NUL
OUT="$(la "$WT")"; RC=$?
check "a cmdline whose last word has no closing NUL still names the agent" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "122\tterm_nonul\tclaude")" ]'
printf 'claude' > "$P/122/cmdline"
OUT="$(la "$WT")"; RC=$?
check "a one-word cmdline with no NUL at all still names the agent" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "122\tterm_nonul\tclaude")" ]'
printf 'HOME=/h/x\0ORCA_TERMINAL_HANDLE=term_lastenv' > "$P/122/environ"   # the handle is the last variable, no closing NUL
OUT="$(la "$WT")"
check "an environ whose last variable has no closing NUL still gives its handle" '[ "$OUT" = "$(printf "122\tterm_lastenv\tclaude")" ]'

reset_proc
PTTY=0 mkproc 113 "$WT" "ORCA_TERMINAL_HANDLE=term_broker" /usr/bin/node /opt/codex/bin/codex app-server
OUT="$(la "$WT")"; RC=$?
check "a tty-less agent-named daemon (the codex app-server broker) is not a live lane: exit 1" '[ "$RC" = 1 ] && [ -z "$OUT" ]'
PTTY=34816 PSTATE=Z mkproc 114 "$WT" "ORCA_TERMINAL_HANDLE=term_zombie" claude
OUT="$(la "$WT")"; RC=$?
check "a zombie agent is not a live lane: exit 1, and not 'unreadable' either" '[ "$RC" = 1 ] && [ -z "$OUT" ]'
mkproc 115 "$WT" "ORCA_TERMINAL_HANDLE=term_real" claude
OUT="$(la "$WT")"
check "the real agent beside a broker and a zombie is the only row" '[ "$OUT" = "$(printf "115\tterm_real\tclaude")" ]'

reset_proc
mkproc 110 "$WT" "ORCA_TERMINAL_HANDLE=bad;rm -rf" claude
mkproc 111 "$WT" "" codex
OUT="$(la "$WT" | sort -n)"
check "a handle with a shell metacharacter is dropped; a process without the variable has an empty handle" '[ "$OUT" = "$(printf "110\t\tclaude\n111\t\tcodex")" ]'

echo "--- live-agent.sh: one unrelated unreadable process must not stall the host"
reset_proc
mkproc 150 "$WT" "" /usr/bin/vim notes.md
rm -f "$P/150/cwd"                                   # a process of ours whose cwd we cannot read, and it is no agent
OUT="$(la "$WT" 2>/dev/null)"; RC=$?
check "unreadable cwd on a NON-agent process: exit 1 (none), not 3" '[ "$RC" = 1 ] && [ -z "$OUT" ]'
mkproc 151 "$WT" "ORCA_TERMINAL_HANDLE=term_hidden" claude
rm -f "$P/151/cwd"
la "$WT" >/dev/null 2>&1; RC=$?
check "unreadable cwd on an AGENT-named process: exit 3 (cannot prove there is none)" '[ "$RC" = 3 ]'
mkproc 152 "$WT" "ORCA_TERMINAL_HANDLE=term_real_2" claude
OUT="$(la "$WT" 2>/dev/null)"; RC=$?
check "...and a readable agent beside it is still found: exit 0" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "152\tterm_real_2\tclaude")" ]'

reset_proc
mkproc 153 "$WT" "ORCA_TERMINAL_HANDLE=term_renamed" /opt/versions/2.1.4/bin/bin-x
printf 'claude\n' > "$P/153/comm"
OUT="$(la "$WT")"; RC=$?
check "a renamed or versioned path still matches on the kernel process name (comm)" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "153\tterm_renamed\tclaude")" ]'
"$LA" "$WT" --local --agents "  " >/dev/null 2>"$ROOT/err"; RC=$?
check "an empty or blank agent list is refused: exit 2, never 'none'" '[ "$RC" = 2 ] && grep -q "empty" "$ROOT/err"'

echo "--- live-agent.sh: configured agent names, usage, no /proc, unreadable entries"
if command -v yq >/dev/null 2>&1; then
  printf 'schema: concertmaster.config/v1\nrespawn:\n  live_agents: [fooagent]\n' > "$ROOT/cfg-agents.yaml"
  reset_proc; mkproc 120 "$WT" "ORCA_TERMINAL_HANDLE=term_foo" fooagent; mkproc 121 "$WT" "" claude
  OUT="$(CM_CONFIG="$ROOT/cfg-agents.yaml" CM_PROC_ROOT="$P" "$LA" "$WT")"
  check "respawn.live_agents in the config replaces the default list" '[ "$OUT" = "$(printf "120\tterm_foo\tfooagent")" ]'
else
  echo "SKIP configured agent names (yq not installed)"
fi

"$LA" >/dev/null 2>&1; RC=$?
check "no argument: usage, exit 2" '[ "$RC" = 2 ]'
"$LA" relative/path >/dev/null 2>&1; RC=$?
check "relative path: usage, exit 2" '[ "$RC" = 2 ]'
"$LA" "$WT" --bogus >/dev/null 2>&1; RC=$?
check "unknown flag: exit 2" '[ "$RC" = 2 ]'
"$LA" --help >"$ROOT/help" 2>&1; RC=$?
check "--help prints the header comment only: exit 0, starts at the title, ends at the exit-code paragraph, no code" '[ "$RC" = 0 ] && head -n 1 "$ROOT/help" | grep -q "^live-agent.sh: " && tail -n 1 "$ROOT/help" | grep -q "never respawns on them" && ! grep -Eq "^set -|^PROC=" "$ROOT/help"'

reset_proc; mkproc 125 "$WT" "ORCA_TERMINAL_HANDLE=term_gate" claude
CM_TEST=0 CM_PROC_ROOT="$P" "$LA" "$WT" >/dev/null 2>"$ROOT/err"
check "CM_PROC_ROOT without CM_TEST=1 is ignored (the real /proc is scanned, not the fake one)" 'grep -q "needs CM_TEST=1" "$ROOT/err"'
CM_PROC_ROOT="$ROOT/no-such-proc" "$LA" "$WT" >/dev/null 2>"$ROOT/err"; RC=$?
check "no /proc on the host: exit 3 and says so" '[ "$RC" = 3 ] && grep -q "not possible" "$ROOT/err"'

reset_proc
mkproc 130 "$WT" "" claude
rm -f "$P/130/cmdline"
OUT="$(la "$WT" 2>/dev/null)"; RC=$?
check "an unreadable entry and no match: exit 3 (incomplete), never read as 'none'" '[ "$RC" = 3 ]'
mkproc 131 "$WT" "ORCA_TERMINAL_HANDLE=term_ok" claude
OUT="$(la "$WT" 2>/dev/null)"; RC=$?
check "an unreadable entry beside a real match: still exit 0 with the match" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "131\tterm_ok\tclaude")" ]'

echo "--- live-agent.sh: a remote host over ssh (stubbed)"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/ssh" <<'S'
#!/usr/bin/env bash
# stub ssh: records the target and the remote command, then runs the command locally with stdin passed through
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac; done
target="$1"; shift
echo "$target" >> "$STUB_SSH_LOG"; printf '%s\n' "$*" >> "$STUB_SSH_LOG"
[ "$target" != down-host ] || exit 255
exec bash -c "$*"
S
chmod +x "$ROOT/bin/ssh"
export STUB_SSH_LOG="$ROOT/ssh.log"; : > "$STUB_SSH_LOG"
reset_proc; mkproc 140 "$WT" "ORCA_TERMINAL_HANDLE=term_remote" claude
OUT="$(PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)" "$LA" "$WT" --host remote-1)"; RC=$?
check "remote host: scanned over ssh to the target, match returned" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "140\tterm_remote\tclaude")" ] && head -n 1 "$STUB_SSH_LOG" | grep -qx fleet-box'
check "remote host: the worktree reaches the remote shell as one quoted word" 'grep -q -- "--local --agents" "$STUB_SSH_LOG"'
: > "$STUB_SSH_LOG"; reset_proc
OUT="$(PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)" "$LA" "$WT" --host remote-1)"; RC=$?
check "remote host, no agent there: exit 1" '[ "$RC" = 1 ]'
reset_proc; mkproc 141 "$WT" "ORCA_TERMINAL_HANDLE=term_remote2" claude
OUT="$(PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)" "$LA" "$WT" --host remote-1)"; RC=$?
check "remote host answering as the expected hostname: scanned" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "141\tterm_remote2\tclaude")" ]'
PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME=some-other-box "$LA" "$WT" --host remote-1 >/dev/null 2>"$ROOT/err"; RC=$?
check "ssh target that is the wrong machine (CM_SSH_TARGET meant for another host): exit 3, not 1" '[ "$RC" = 3 ] && grep -qi "cannot check" "$ROOT/err"'
reset_proc; mkproc 143 "$WT" "ORCA_TERMINAL_HANDLE=term_fqdn" claude
OUT="$(PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s).fleet.example.test" "$LA" "$WT" --host remote-1)"; RC=$?
check "expected hostname given as a FQDN: matches the short name hostname -s returns" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "143\tterm_fqdn\tclaude")" ]'
OUT="$(PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)X.fleet.example.test" "$LA" "$WT" --host remote-1 2>/dev/null)"; RC=$?
check "...but a FQDN whose short part differs is still the wrong machine: exit 3" '[ "$RC" = 3 ]'
PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=down-host "$LA" "$WT" --host remote-1 >/dev/null 2>"$ROOT/err"; RC=$?
check "remote host unreachable: exit 3, not 1" '[ "$RC" = 3 ] && grep -q "cannot check" "$ROOT/err"'
CM_SSH_TARGET="-oProxyCommand=x" "$LA" "$WT" --host remote-1 >/dev/null 2>&1; RC=$?
check "an ssh target that looks like an option is refused: exit 3" '[ "$RC" = 3 ]'
reset_proc; mkproc 142 "$WT" "ORCA_TERMINAL_HANDLE=term_secs" claude
for bad in abc 1.5 -3 0 00 000 ""; do
  # shellcheck disable=SC2034  # OUT is read inside the eval-ed check below
  OUT="$(PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)" CM_LIVE_AGENT_SSH_S="$bad" "$LA" "$WT" --host remote-1 2>"$ROOT/err")"; RC=$?
  case "$bad" in "") want_warn=0 ;; *) want_warn=1 ;; esac
  check "CM_LIVE_AGENT_SSH_S='$bad': falls back to 20 s, still scans" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "142\tterm_secs\tclaude")" ] && { [ '"$want_warn"' = 0 ] || grep -q "using 20" "$ROOT/err"; }'
done
PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)" CM_LIVE_AGENT_SSH_S=08 "$LA" "$WT" --host remote-1 >/dev/null 2>"$ROOT/err"; RC=$?
check "CM_LIVE_AGENT_SSH_S=08 is eight seconds (not bad octal), no warning" '[ "$RC" = 0 ] && ! grep -q "using 20" "$ROOT/err"'
PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME=".fleet.example.test" "$LA" "$WT" --host remote-1 >/dev/null 2>&1; RC=$?
check "an expected hostname with an empty short part (.fleet.example.test) is refused: exit 3, never a match" '[ "$RC" = 3 ]'
PATH="$ROOT/bin:$PATH" CM_PROC_ROOT="$P" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)" CM_LIVE_AGENT_SSH_S=7 "$LA" "$WT" --host remote-1 >/dev/null 2>"$ROOT/err"; RC=$?
check "CM_LIVE_AGENT_SSH_S=7: a plain number is taken as it is, no warning" '[ "$RC" = 0 ] && ! grep -q "using 20" "$ROOT/err"'

echo "--- cm_worker_set_handle (lib.sh)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$SCRIPTS/lib.sh"
mkledger() {
  jq -n --arg wt "$WT" '{schema: "concertmaster.ledger/v1", updatedAt: "2000-01-01T00:00:00Z",
    workers: {"w-prs": {lane: "lane-a", host: "local", agent: "claude", model: "sonnet", path: $wt, state: "running",
                        terminal: "term_stale", task: "task-a", lastComment: "cm:running"}}}' > "$CM_HOME/ledger.json"
}
mkledger
cm_worker_set_handle w-prs term_fresh 2>/dev/null; RC=$?
check "sets terminal and terminalRefreshedAt, leaves state alone" '[ "$RC" = 0 ] && [ "$(jq -r ".workers[\"w-prs\"] | [.terminal, (.terminalRefreshedAt|type), .state] | join(\",\")" "$CM_HOME/ledger.json")" = "term_fresh,string,running" ]'
cp "$CM_HOME/ledger.json" "$ROOT/before.json"
cm_worker_set_handle w-nope term_x 2>/dev/null; RC=$?
check "unknown worker id: refused, ledger untouched" '[ "$RC" = 1 ] && cmp -s "$ROOT/before.json" "$CM_HOME/ledger.json"'
cm_worker_set_handle w-prs 'x;y' 2>/dev/null; RC=$?
check "handle with a metacharacter: refused, ledger untouched" '[ "$RC" = 1 ] && cmp -s "$ROOT/before.json" "$CM_HOME/ledger.json"'
cm_worker_set_handle w-prs 2>/dev/null; RC=$?
check "missing argument: usage, exit 2" '[ "$RC" = 2 ]'
mkledger
jq '.workers["w-conc"] = {lane: "concertmaster", host: "local", path: "/elsewhere/concertmaster", state: "running", terminal: "term_conc"}' "$CM_HOME/ledger.json" > "$CM_HOME/ledger.tmp" && mv "$CM_HOME/ledger.tmp" "$CM_HOME/ledger.json"
cp "$CM_HOME/ledger.json" "$ROOT/before.json"
cm_worker_set_handle w-prs term_conc 2>/dev/null; RC=$?
check "a handle another worker holds: refused (exit 4) under the lock, ledger untouched" '[ "$RC" = 4 ] && cmp -s "$ROOT/before.json" "$CM_HOME/ledger.json"'
cm_worker_set_handle --by-path local "$WT/" term_by_path 2>/dev/null; RC=$?
check "--by-path finds the one worker (trailing slash normalised) and writes it" '[ "$RC" = 0 ] && [ "$(jq -r ".workers[\"w-prs\"].terminal" "$CM_HOME/ledger.json")" = term_by_path ]'
cp "$CM_HOME/ledger.json" "$ROOT/before.json"
cm_worker_set_handle --by-path local /no/such/worktree term_x 2>/dev/null; RC=$?
check "--by-path with no worker at that path: exit 5, ledger untouched" '[ "$RC" = 5 ] && cmp -s "$ROOT/before.json" "$CM_HOME/ledger.json"'
jq --arg wt "$WT" '.workers["w-twin"] = {lane: "twin", host: "local", path: $wt, state: "running", terminal: "term_twin"}' "$CM_HOME/ledger.json" > "$CM_HOME/ledger.tmp" && mv "$CM_HOME/ledger.tmp" "$CM_HOME/ledger.json"
cp "$CM_HOME/ledger.json" "$ROOT/before.json"
cm_worker_set_handle --by-path local "$WT" term_y 2>/dev/null
# shellcheck disable=SC2034  # RC is read inside the eval-ed check below
RC=$?
check "--by-path with two workers at that path: exit 5, nothing guessed" '[ "$RC" = 5 ] && cmp -s "$ROOT/before.json" "$CM_HOME/ledger.json"'

echo
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
