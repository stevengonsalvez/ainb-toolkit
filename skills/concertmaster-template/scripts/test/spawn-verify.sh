#!/usr/bin/env bash
# spawn-verify.sh test: fixture panes and a STUBBED orca/ssh/HOME. Asserts that `check` exits 0
# only for a Claude pane showing the configured model (spawn.expected_model) at the configured effort (banner line or status line) and
# fails a plain shell prompt (even one that echoes the claude command line), "command not
# found", a different model or effort, and an empty pane; that --wait rides out a banner that
# arrives late; and that `resolve` returns an absolute path, skips a ~500 byte stub, and says
# what to do when there is no claude. Touches nothing outside a mktemp dir. No network.
#
#   scripts/test/spawn-verify.sh         # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SV="$HERE/../spawn-verify.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-spawn-verify.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"
# the expected model and effort come from config (spawn.*), not from the script
printf 'schema: concertmaster.config/v1\nspawn:\n  expected_model: sonnet-5.5\n  expected_effort: high\n' > "$ROOT/config.yaml"
export CM_CONFIG="$ROOT/config.yaml"

PASS=0; FAIL=0
check() { # check <label> <command...>: passes when the command succeeds
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"; else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$label"; fi
}
rc() { "$@" >/dev/null 2>&1; echo $?; }

P="$ROOT/panes"; mkdir -p "$P"
cat > "$P/banner.txt" <<'E'
╭───────────────────────────────────────────────────╮
│ ✻ Welcome to Claude Code v2.1.310                 │
│   Sonnet 5.5 with high effort · Claude Max        │
╰───────────────────────────────────────────────────╯
 ? for shortcuts
E
cat > "$P/status.txt" <<'E'
❯
  sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31% · 5h [░░░░░░] 0% ↻ 20:00
E
cat > "$P/shell-echo.txt" <<'E'
claude@host-a ~/orca/workspaces/acme-app/job-1 % claude --dangerously-skip-permissions --model claude-sonnet-5-5 --effort high
claude@host-a ~/orca/workspaces/acme-app/job-1 %
E
cat > "$P/notfound.txt" <<'E'
claude@host-a ~/orca/workspaces/acme-app/job-1 % claude --dangerously-skip-permissions --model claude-sonnet-5-5 --effort high
zsh: command not found: claude
claude@host-a ~/orca/workspaces/acme-app/job-1 %
E
cat > "$P/brief-in-shell.txt" <<'E'
claude@host-a ~/x % claude --model claude-sonnet-5-5 --effort high
zsh: command not found: claude
claude@host-a ~/x % Read ~/state/briefs/w-1.md and start
zsh: command not found: Read
E
cat > "$P/opus.txt" <<'E'
│ ✻ Welcome to Claude Code v2.1.310                 │
│   Opus 4.7 with high effort · Claude Max          │
 ? for shortcuts
E
cat > "$P/sonnet-medium.txt" <<'E'
❯
  sonnet-5.5 · eff medium · 🟢 0/50 · ctx [█░░░░░] 31%
E
cat > "$P/sonnet-old.txt" <<'E'
│   Sonnet 4.6 with high effort · Claude Max
 ? for shortcuts
E
cat > "$P/loading.txt" <<'E'
 ✻ Welcome to Claude Code v2.1.310
 ? for shortcuts
E
: > "$P/empty.txt"

cat > "$P/crashed-banner.txt" <<'E'
│ ✻ Welcome to Claude Code v2.1.310                 │
│   Sonnet 5.5 with high effort · Claude Max        │
Error: Raw mode is not supported on the current process.stdin
❯
E
cat > "$P/exited-status.txt" <<'E'
  sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31%
TypeError: fetch failed
claude@host-a:~/x$
E
cat > "$P/terminated.txt" <<'E'
  sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31%
zsh: terminated  /home/user/.local/bin/claude
host-a%
E
cat > "$P/footer-busy.txt" <<'E'
  ⎿  Running tests
✻ Working… (12s · esc to interrupt)
  sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31% · $0.12
  ⏵⏵ bypass permissions on (shift+tab to cycle)
  ◯ general-purpose  Check why authentication expired, killed jobs exited
E
cat > "$P/footer-perm.txt" <<'E'
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31%
  ⏵⏵ bypass permissions on (shift+tab to cycle)
E
cat > "$P/echo-dot.txt" <<'E'
claude@host-a ~/x % claude --model sonnet-5.5 --effort high
zsh: command not found: claude
claude@host-a ~/x %
E
cat > "$P/scrollback.txt" <<'E'
 ? for shortcuts
  sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31%
a
b
c
d
e
f
g
h
i
j
k
claude@host-a ~/x %
E
cat > "$P/opus-quoting-sonnet.txt" <<'E'
  the transcript quoted:   sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31%
  opus-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31%
  ⏵⏵ bypass permissions on (shift+tab to cycle)
E
cat > "$P/plan-mode.txt" <<'E'
  sonnet-5.5 · eff high · 🟢 0/50 · ctx [█░░░░░] 31%
  ⏸ plan mode on (shift+tab to cycle)
E
cat > "$P/dialog.txt" <<'E'
│   Sonnet 5.5 with high effort · Claude Max
Do you want to proceed?
  Enter to select · ↑/↓ to navigate · Esc to cancel
E
check "banner line 'Sonnet 5.5 with high effort': ok" test "$(rc "$SV" check --file "$P/banner.txt")" = 0
check "status line 'sonnet-5.5 · eff high': ok" test "$(rc "$SV" check --file "$P/status.txt")" = 0
check "plain shell echoing the claude command: not ok (exit 1)" test "$(rc "$SV" check --file "$P/shell-echo.txt")" = 1
check "shell echo: reason is shell-prompt" test "$("$SV" check --file "$P/shell-echo.txt" 2>&1)" = "verify: FAIL shell-prompt"
check "command not found: not ok, reason named" test "$("$SV" check --file "$P/notfound.txt" 2>&1)" = "verify: FAIL command-not-found"
check "brief typed into the shell: not ok" test "$(rc "$SV" check --file "$P/brief-in-shell.txt")" = 1
check "Opus banner: not ok, reason wrong-model" test "$("$SV" check --file "$P/opus.txt" 2>&1 | cut -c1-22)" = "verify: FAIL wrong-mod"
check "sonnet-5.5 at medium effort: not ok" test "$(rc "$SV" check --file "$P/sonnet-medium.txt")" = 1
check "Sonnet 4.6: not ok" test "$(rc "$SV" check --file "$P/sonnet-old.txt")" = 1
check "Claude still loading, model not shown: not ok, reason no-banner" test "$("$SV" check --file "$P/loading.txt" 2>&1)" = "verify: FAIL no-banner"
check "empty pane: not ok" test "$(rc "$SV" check --file "$P/empty.txt")" = 1
check "--model/--effort override: opus pane at high verifies as opus-4.7" test "$(rc "$SV" check --file "$P/opus.txt" --model opus-4.7)" = 0
check "banner, then an error, then a shell prompt (Claude died): not ok" test "$(rc "$SV" check --file "$P/crashed-banner.txt")" = 1
check "status line, then a bash error, then a bash prompt (no space before \$): not ok" test "$(rc "$SV" check --file "$P/exited-status.txt")" = 1
check "status line, then 'zsh: terminated', then host%: not ok" test "$(rc "$SV" check --file "$P/terminated.txt")" = 1
check "crashed banner ending in a starship prompt: reason is claude-not-running, not wrong-model" test "$("$SV" check --file "$P/crashed-banner.txt" 2>&1 | cut -c1-31)" = "verify: FAIL claude-not-running"
check "real footer: status line, permissions line, subagent row with 'authentication', 'killed': ok" test "$(rc "$SV" check --file "$P/footer-busy.txt")" = 0
check "real footer: status line then the permissions line: ok" test "$(rc "$SV" check --file "$P/footer-perm.txt")" = 0
check "C locale: the status line still matches (multibyte separator)" test "$(LC_ALL=C rc "$SV" check --file "$P/status.txt")" = 0
check "C locale: the busy footer pane is ok" test "$(LC_ALL=C rc "$SV" check --file "$P/footer-busy.txt")" = 0
check "C locale: a shell echo still fails" test "$(LC_ALL=C rc "$SV" check --file "$P/shell-echo.txt")" = 1
check "echoed dot-form command (--model sonnet-5.5 --effort high): not ok" test "$(rc "$SV" check --file "$P/echo-dot.txt")" = 1
check "model line only in old scrollback, outside the last 12 lines: not ok" test "$(rc "$SV" check --file "$P/scrollback.txt")" = 1
check "flag with no value (--wait last): exit 2, no hang" test "$(timeout 5 "$SV" check --terminal x --wait >/dev/null 2>&1; echo $?)" = 2
check "--effort last: exit 2, no hang" test "$(timeout 5 "$SV" check --file "$P/banner.txt" --effort >/dev/null 2>&1; echo $?)" = 2
check "opus status line under a quoted sonnet line: not ok (bottom-most model line wins)" test "$(rc "$SV" check --file "$P/opus-quoting-sonnet.txt")" = 1
check "opus under a quoted sonnet line: reason is wrong-model" test "$("$SV" check --file "$P/opus-quoting-sonnet.txt" 2>&1 | cut -c1-24)" = "verify: FAIL wrong-model"
check "plan mode footer: ok" test "$(rc "$SV" check --file "$P/plan-mode.txt")" = 0
check "open question menu: not ok, reason claude-dialog (Claude is live, do not respawn)" test "$("$SV" check --file "$P/dialog.txt" 2>&1 | cut -c1-26)" = "verify: FAIL claude-dialog"
# no flags and no spawn.* config: nothing to verify against, exit 2 with a hint
printf 'schema: concertmaster.config/v1\n' > "$ROOT/empty.yaml"
check "no expected model in config and no flag: exit 2" test "$(CM_CONFIG="$ROOT/empty.yaml" rc "$SV" check --file "$P/banner.txt")" = 2
check "no config, flags given: --model/--effort win" test "$(CM_CONFIG="$ROOT/empty.yaml" rc "$SV" check --file "$P/banner.txt" --model sonnet-5.5 --effort high)" = 0
check "config says opus-4.7: the sonnet banner is wrong-model" test "$(printf 'spawn:\n  expected_model: opus-4.7\n  expected_effort: high\n' > "$ROOT/opus.yaml"; CM_CONFIG="$ROOT/opus.yaml" "$SV" check --file "$P/banner.txt" 2>&1 | cut -c1-24)" = "verify: FAIL wrong-model"
check "unknown command: exit 2" test "$(rc "$SV" frobnicate)" = 2
check "missing --file: exit 2" test "$(rc "$SV" check --file "$P/nope.txt")" = 2

# Terminal mode against a stub orca (the live `terminal read --screen` shape: .result.terminal.tail).
cat > "$ROOT/orca-stub" <<'S'
#!/usr/bin/env bash
# terminal read: first $STUB_SHELL_READS answers show the shell pane, then the Claude pane.
n=0; [ -f "$STUB_DIR/n" ] && n="$(cat "$STUB_DIR/n")"; n=$((n + 1)); echo "$n" > "$STUB_DIR/n"
if [ -e "$STUB_DIR/read-fail" ]; then echo '{"ok":false}'; exit 1; fi
if [ "$n" -le "${STUB_SHELL_READS:-0}" ]; then f="$STUB_PANES/shell-echo.txt"; else f="$STUB_PANES/${STUB_FINAL:-banner}.txt"; fi
jq -Rs '{ok: true, result: {terminal: {handle: "term_x", tail: (split("\n") | map(select(. != "")))}}}' < "$f"
S
chmod +x "$ROOT/orca-stub"
export ORCA_CLI_COMMAND="$ROOT/orca-stub" STUB_DIR="$ROOT/stub" STUB_PANES="$P"; mkdir -p "$STUB_DIR"
reset() { rm -f "$STUB_DIR/n" "$STUB_DIR/read-fail"; }
reset; STUB_SHELL_READS=99; export STUB_SHELL_READS
check "terminal mode, shell pane: not ok" test "$(rc "$SV" check --terminal term_x)" = 1
reset; STUB_SHELL_READS=0
check "terminal mode, Claude pane: ok" test "$(rc "$SV" check --terminal term_x --environment host-a)" = 0
reset; STUB_SHELL_READS=2
check "--wait rides out a banner that arrives on the 3rd read" test "$(rc "$SV" check --terminal term_x --wait 10)" = 0
reset; STUB_SHELL_READS=99
check "--wait gives up on a shell pane (exit 1)" test "$(rc "$SV" check --terminal term_x --wait 3)" = 1
reset; : > "$STUB_DIR/read-fail"
check "unreadable pane: exit 2, never ok" test "$(rc "$SV" check --terminal term_x)" = 2
reset

# resolve: fake HOME, no claude on the login PATH.
H="$ROOT/h"; mkdir -p "$H/.local/bin" "$H/.npm-global/bin"
run_resolve() { HOME="$H" PATH="/usr/bin:/bin" "$SV" resolve; }
OUTS="$(run_resolve 2>&1)"; RC=$?
check "no claude anywhere: exit 1" test "$RC" = 1
check "no claude: says what to do (npm install -g @anthropic-ai/claude-code@)" grep -q 'npm install -g @anthropic-ai/claude-code@' <<<"$OUTS"
head -c 500 /dev/zero | tr '\0' '#' > "$H/.npm-global/bin/claude"; chmod +x "$H/.npm-global/bin/claude"
OUTS="$(run_resolve 2>&1)"; RC=$?
check "a 500 byte stub is refused (exit 1)" test "$RC" = 1
check "stub refusal names the path and 'stub'" grep -q "claude: a stub\|$H/.npm-global/bin/claude is 500 bytes: a stub" <<<"$OUTS"
head -c 200000 /dev/zero | tr '\0' 'x' > "$H/.local/bin/claude"; chmod +x "$H/.local/bin/claude"
OUTS="$(run_resolve 2>/dev/null)"; RC=$?
check "real binary: absolute path printed, exit 0" test "$RC/$OUTS" = "0/$H/.local/bin/claude"
rm -f "$H/.local/bin/claude"; head -c 200000 /dev/zero | tr '\0' 'x' > "$H/.npm-global/bin/claude"
check "falls back to ~/.npm-global/bin/claude when it is real" test "$(run_resolve 2>/dev/null)" = "$H/.npm-global/bin/claude"
# --ssh: a stub ssh that runs the piped lookup locally proves the function is shipped to the target.
mkdir -p "$ROOT/bin"; printf '#!/usr/bin/env bash\nexec bash -s\n' > "$ROOT/bin/ssh"; chmod +x "$ROOT/bin/ssh"
check "--ssh runs the same lookup on the target" test "$(HOME="$H" PATH="$ROOT/bin:/usr/bin:/bin" "$SV" resolve --ssh host-a 2>/dev/null)" = "$H/.npm-global/bin/claude"
check "--ssh without a target: exit 2" test "$(rc "$SV" resolve --ssh)" = 2

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
