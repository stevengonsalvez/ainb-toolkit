#!/usr/bin/env bash
# boot-sweep.sh test: STUBBED orca, fake Claude transcripts with set mtimes, fake boot time.
# Asserts which lanes get a nudge (no turn since boot) and which are left alone (active since
# boot, menu, mid-turn, shell, no Claude, duplicates), that a nudge only counts when the
# transcript advances, the two-attempt cap, the failure paths, and that --dry-run writes nothing.
# Touches nothing outside a mktemp dir. No real orca, no network.
#
#   scripts/test/boot-sweep.sh         # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/boot-sweep.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-boot-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home" STUB_DIR="$ROOT/stub" CM_CLAUDE_PROJECTS="$ROOT/projects"
mkdir -p "$CM_HOME" "$STUB_DIR" "$CM_CLAUDE_PROJECTS"
export CM_PATH_MATCH="/acme-app/" CM_CONFIG=/nonexistent
export CM_BOOT_EPOCH="$(( $(date +%s) - 86400 ))" CM_BOOT_CONFIRM_S=3

wt() { printf '%s/wt/acme-app/%s' "$ROOT" "$1"; }
tdir() { printf '%s/%s' "$CM_CLAUDE_PROJECTS" "$(printf '%s' "$(wt "$1")" | sed 's#[^A-Za-z0-9]#-#g')"; }
mk() { # $1 lane, $2 transcript mtime offset from boot (seconds)
  mkdir -p "$(tdir "$1")"; touch -d "@$((CM_BOOT_EPOCH + $2))" "$(tdir "$1")/s.jsonl"; }
mk active 500; mk stale -3600; mk menu -3600; mk busy -3600; mk shell -3600; mk noclaude -3600
mk dup -3600; mk unconf -3600; mk failsend -3600; mk gone -3600; mk nonstanding -3600

# ledger: standing local lanes only (nonstanding is a dev worker, nodir is standing but has no transcript dir)
{
  printf '{"workers":{'
  first=1
  for l in active stale menu busy shell noclaude dup unconf failsend nodir; do
    [ "$first" = 1 ] || printf ','; first=0
    printf '"w-%s":{"standing":true,"host":"local","path":"%s/"}' "$l" "$(wt $l)"
  done
  printf ',"w-nonstanding":{"standing":false,"host":"local","path":"%s"}' "$(wt nonstanding)"
  printf ',"w-remote":{"standing":true,"host":"remote-host","path":"%s"}' "$(wt remote)"
  printf '}}'
} > "$CM_HOME/ledger.json"

LIST="$ROOT/terminals.json"
{
  printf '{"result":{"terminals":['
  for l in active stale menu busy shell noclaude unconf failsend nonstanding nodir; do printf '{"handle":"t_%s","worktreePath":"%s","agentIdentity":"claude"},' "$l" "$(wt $l)"; done
  printf '{"handle":"t_dup1","worktreePath":"%s","agentIdentity":"claude"},{"handle":"t_dup2","worktreePath":"%s","agentIdentity":"claude"},' "$(wt dup)" "$(wt dup)"
  printf '{"handle":"t_other","worktreePath":"%s/wt/otherproject/x","agentIdentity":"claude"},' "$ROOT"
  printf '{"handle":"t_codex","worktreePath":"%s","agentIdentity":"codex"}' "$(wt gone)"
  printf ']}}'
} > "$LIST"
export LIST

cat > "$ROOT/orca" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls.log"
cmd="$1 $2"; shift 2; h=""
while [ $# -gt 0 ]; do [ "$1" = "--terminal" ] && h="$2"; shift; done
case "$cmd" in
  "worktree ps") echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  "terminal list") cat "$LIST" ;;
  "terminal read")
    case "$h" in
      t_menu)    s='Pick one\nEnter to select · Arrow keys to navigate' ;;
      t_busy)    s='working (12s · esc to interrupt)\nbypass permissions on' ;;
      t_shell)   s='some output\nclaude@host:~$ ' ;;
      t_noclaude) s='just text\nnothing here' ;;
      *)         s='❯ \n  ? for shortcuts' ;;
    esac
    printf '{"ok":true,"result":{"screen":"%s"}}\n' "$s" ;;
  "terminal send")
    [ "$h" = t_failsend ] && { echo '{"ok":false}'; exit 0; }
    # a nudge that "works" advances the lane's transcript; t_unconf accepts input but nothing happens
    if [ "$h" = t_stale ]; then touch "$TOUCH_STALE"; fi
    echo '{"ok":true}' ;;
esac
S
chmod +x "$ROOT/orca"
export ORCA_CLI_COMMAND="$ROOT/orca" TOUCH_STALE="$(tdir stale)/s.jsonl"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
sends() { grep -c '^terminal send' "$STUB_DIR/calls.log" 2>/dev/null || true; }
res() { printf '%s\n' "$OUT" | awk -F'\t' -v n="$1" '$1==n{print $3}'; }

: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT" --dry-run --no-wait)"
check "dry-run sends nothing" "$(sends)" "0"
check "dry-run marks the lane with no turn since boot" "$(res stale)" "would-nudge"
check "dry-run writes no state" "$(find "$CM_HOME/cache" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
check "dry-run writes no inbox note" "$(find "$CM_HOME/inbox" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT" --no-wait)"
check "lane active since boot is skipped" "$(res active)" "skipped"
check "lane with no turn since boot is nudged and confirmed" "$(res stale)" "nudged"
check "question menu not typed into" "$(res menu)" "menu"
check "mid-turn left alone" "$(res busy)" "busy"
check "shell prompt reported only" "$(res shell)" "report"
check "no sign of Claude left alone" "$(res noclaude)" "unreadable"
check "duplicate terminals reported, not nudged" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="dup"{print $3}' | sort -u)" "report"
check "send accepted but no turn is reported unconfirmed" "$(res unconf)" "unconfirmed"
check "send refused by orca is reported" "$(res failsend)" "send-failed"
check "a non-standing dev worker is never nudged" "$(res nonstanding)" "not-standing"
check "standing lane with no transcript dir is unknown, not nudged" "$(res nodir)" "unknown"
check "other projects and codex terminals are ignored" "$(printf '%s\n' "$OUT" | grep -cE 'otherproject|t_other|t_codex' || true)" "0"
check "only the stale and the unconfirmed lane got input (failsend refused)" "$(sends)" "3"
check "nothing was read from or sent to the non-standing or no-dir lanes" "$(grep -cE 't_nonstanding|t_nodir' "$STUB_DIR/calls.log" || true)" "0"

: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT" --no-wait)"
check "confirmed lane is not nudged twice (active now)" "$(res stale)" "skipped"
check "unconfirmed lane is retried once" "$(res unconf)" "unconfirmed"
OUT="$("$SCRIPT" --no-wait)"
check "after two attempts the lane is left to the concertmaster" "$(res unconf)" "gave-up"
check "inbox notes written with seconds in the name" "$([ "$(find "$CM_HOME/inbox" -name 'boot-sweep-*Z-*.md' | wc -l | tr -d ' ')" -ge 3 ] && echo yes)" "yes"
# no readable ledger: send nothing and leave a note
mv "$CM_HOME/ledger.json" "$CM_HOME/ledger.json.off"; : > "$STUB_DIR/calls.log"
rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
OUT="$("$SCRIPT" --no-wait)"
check "no ledger: nothing sent" "$(sends)" "0"
check "no ledger: an inbox note says why" "$(grep -l 'No standing local lanes' "$CM_HOME"/inbox/boot-sweep-*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
exit $fail
