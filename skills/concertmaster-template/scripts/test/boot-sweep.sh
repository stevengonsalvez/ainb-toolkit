#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# boot-sweep.sh test: STUBBED orca, fake Claude transcripts with set mtimes, fake boot time.
# Asserts which lanes get a nudge (no turn since boot) and which are left alone (active since
# boot, menu, mid-turn, shell, no Claude, duplicates), that a nudge only counts when the
# transcript advances, the two-attempt cap, the failure paths, and that --dry-run writes nothing.
# The concertmaster session (path ending /<worktrees.self_name>, or the ledger row
# workers.<worktrees.self_name>) is nudged with the exact text "/loop /concertmaster tick", with or
# without a ledger; a concertmaster that cannot be re-armed is flagged for a human.
# Touches nothing outside a mktemp dir. No real orca, no network.
#
#   scripts/test/boot-sweep.sh         # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/boot-sweep.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-boot-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home" STUB_DIR="$ROOT/stub" CM_CLAUDE_PROJECTS="$ROOT/projects"
mkdir -p "$CM_HOME" "$STUB_DIR" "$CM_CLAUDE_PROJECTS"
export CM_PATH_MATCH="/acme-app/" CM_CONFIG=/nonexistent
export CM_BOOT_EPOCH="$(( $(date +%s) - 86400 ))" CM_BOOT_CONFIRM_S=3

wt() { printf '%s/wt/acme-app/%s' "$ROOT" "$1"; }
CMWT="$ROOT/wt/acme-app/concertmaster"   # the concertmaster worktree (default self_name): matched by path, no ledger row
tdirp() { printf '%s/%s' "$CM_CLAUDE_PROJECTS" "$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"; }
tdir() { tdirp "$(wt "$1")"; }
mkp() { mkdir -p "$(tdirp "$1")"; touch -d "@$((CM_BOOT_EPOCH + $2))" "$(tdirp "$1")/s.jsonl"; }
mk() { mkp "$(wt "$1")" "$2"; } # $1 lane, $2 transcript mtime offset from boot (seconds)
mkp "$CMWT" -3600; mk cmrow -3600
CMFOO="$ROOT/wt/acme-app/concertmaster-foo"; mkp "$CMFOO" -3600   # looks like the concertmaster, is not
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
  # the concertmaster row: its path is NOT concertmaster-shaped, so only the ledger row identifies it
  printf ',"concertmaster":{"standing":true,"host":"local","path":"%s"}' "$(wt cmrow)"
  printf ',"w-nonstanding":{"standing":false,"host":"local","path":"%s"}' "$(wt nonstanding)"
  printf ',"w-remote":{"standing":true,"host":"remote-host","path":"%s"}' "$(wt remote)"
  printf '}}'
} > "$CM_HOME/ledger.json"

LIST="$ROOT/terminals.json"
{
  printf '{"result":{"terminals":['
  for l in active stale menu busy shell noclaude unconf failsend nonstanding nodir; do printf '{"handle":"t_%s","worktreePath":"%s","agentIdentity":"claude"},' "$l" "$(wt $l)"; done
  printf '{"handle":"t_cm","worktreePath":"%s","agentIdentity":"claude"},{"handle":"t_cmrow","worktreePath":"%s","agentIdentity":"claude"},' "$CMWT" "$(wt cmrow)"
  printf '{"handle":"t_cmfoo","worktreePath":"%s","agentIdentity":"claude"},' "$CMFOO"
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
      t_cm)      if [ -n "${STUB_CM_MENU:-}" ]; then s='Pick one\nEnter to select · Arrow keys to navigate'; else s='❯ \n  ? for shortcuts'; fi ;;
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
    if [ "$h" = t_cm ]; then touch "$TOUCH_CM"; fi
    if [ "$h" = t_cmrow ]; then touch "$TOUCH_CMROW"; fi
    echo '{"ok":true}' ;;
esac
S
chmod +x "$ROOT/orca"
TOUCH_STALE="$(tdir stale)/s.jsonl"
TOUCH_CM="$(tdirp "$CMWT")/s.jsonl"; TOUCH_CMROW="$(tdir cmrow)/s.jsonl"
export ORCA_CLI_COMMAND="$ROOT/orca" TOUCH_STALE TOUCH_CM TOUCH_CMROW

# cm-worktree-sync.sh (run at boot) must never touch the real worktree this test runs from: a stand-in that prints
# $STUB_SYNC_OUT, exits $STUB_SYNC_RC (default 0) and records its arguments
FAKE_WS="$ROOT/fake-worktree-sync.sh"
cat > "$FAKE_WS" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/sync-calls.log"
[ -z "${STUB_SYNC_OUT:-}" ] || printf '%s\n' "$STUB_SYNC_OUT"
exit "${STUB_SYNC_RC:-0}"
FAKE
chmod +x "$FAKE_WS"
export CM_WORKTREE_SYNC="$FAKE_WS"
# capacity-check.sh (run at boot, counts only) is likewise a stand-in: it prints $STUB_CAP_OUT, exits $STUB_CAP_RC (default 0)
# and records its arguments
FAKE_CC="$ROOT/fake-capacity-check.sh"
cat > "$FAKE_CC" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/cap-calls.log"
[ -z "${STUB_CAP_OUT:-}" ] || printf '%s\n' "$STUB_CAP_OUT"
exit "${STUB_CAP_RC:-0}"
FAKE
chmod +x "$FAKE_CC"
export CM_CAPACITY_CHECK="$FAKE_CC"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
sends() { grep -c '^terminal send' "$STUB_DIR/calls.log" 2>/dev/null || true; }
res() { printf '%s\n' "$OUT" | awk -F'\t' -v n="$1" '$1==n{print $3}'; }
NUDGE_CM_LINE='--text /loop /concertmaster tick --enter'
sent_to() { grep -c "^terminal send --terminal $1 " "$STUB_DIR/calls.log" 2>/dev/null || true; }

: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT" --dry-run --no-wait)"
check "dry-run marks the concertmaster (by path, no ledger row) as would-nudge" "$(res concertmaster)" "would-nudge"
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
check "concertmaster found by path is nudged and confirmed" "$(res concertmaster)" "nudged"
check "concertmaster found by its ledger row is nudged and confirmed" "$(res "$(basename "$(wt cmrow)")")" "nudged"
check "concertmaster gets the exact loop text" "$(grep -c "^terminal send --terminal t_cm .*$NUDGE_CM_LINE" "$STUB_DIR/calls.log" || true)" "1"
check "concertmaster (ledger row) gets the exact loop text" "$(grep -c "^terminal send --terminal t_cmrow .*$NUDGE_CM_LINE" "$STUB_DIR/calls.log" || true)" "1"
check "a concertmaster-lookalike path is not the concertmaster (never nudged)" "$(res concertmaster-foo)" "not-standing"
check "an ordinary lane still gets the generic nudge" "$(grep -c '^terminal send --terminal t_stale .*The VM restarted' "$STUB_DIR/calls.log" || true)" "1"
check "only the stale, unconfirmed, failsend and two concertmaster terminals got input" "$(sends)" "5"
check "nothing was read from or sent to the non-standing or no-dir lanes" "$(grep -cE 't_nonstanding|t_nodir' "$STUB_DIR/calls.log" || true)" "0"

: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT" --no-wait)"
check "confirmed lane is not nudged twice (active now)" "$(res stale)" "skipped"
check "confirmed concertmaster is not nudged twice (active now)" "$(res concertmaster)" "skipped"
check "unconfirmed lane is retried once" "$(res unconf)" "unconfirmed"
OUT="$("$SCRIPT" --no-wait)"
check "after two attempts the lane is left to the concertmaster" "$(res unconf)" "gave-up"
# a concertmaster that cannot be re-armed (menu showing) is flagged for a human, not left to the dead tick
mkp "$CMWT" -3600; rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv; : > "$STUB_DIR/calls.log"; export STUB_CM_MENU=1
OUT="$("$SCRIPT" --no-wait 2>"$ROOT/err")"; unset STUB_CM_MENU
check "concertmaster at a menu is not typed into" "$(res concertmaster)" "menu"
check "a failed concertmaster re-arm is shouted in the unit log" "$(grep -c 'CONCERTMASTER NOT RE-ARMED' "$ROOT/err" || true)" "1"
check "a failed concertmaster re-arm tops the inbox note" "$(grep -l 'NEEDS A HUMAN' "$CM_HOME"/inbox/boot-sweep-*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
check "inbox notes written with seconds in the name" "$([ "$(find "$CM_HOME/inbox" -name 'boot-sweep-*Z-*.md' | wc -l | tr -d ' ')" -ge 3 ] && echo yes)" "yes"
# no readable ledger: send nothing and leave a note
mv "$CM_HOME/ledger.json" "$CM_HOME/ledger.json.off"; : > "$STUB_DIR/calls.log"
rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
mkp "$CMWT" -3600   # the concertmaster is idle again: a path match needs no ledger
OUT="$("$SCRIPT" --no-wait)"
check "no ledger: only the concertmaster is nudged" "$(sends)" "1"
check "no ledger: the concertmaster got the exact loop text" "$(sent_to t_cm)" "1"
check "no ledger: other lanes are no-ledger, never not-standing" "$(printf '%s\n' "$OUT" | awk -F'\t' '$3=="not-standing"' | wc -l | tr -d ' ')" "0"
check "no ledger: the stale lane is named no-ledger" "$(res stale)" "no-ledger"
check "no ledger: the note says the ledger is missing" "$(grep -l 'Ledger missing or unreadable' "$CM_HOME"/inbox/boot-sweep-*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
# no ledger and no concertmaster terminal: nothing sent, a note says why
jq 'del(.result.terminals[] | select(.handle == "t_cm"))' "$LIST" > "$LIST.new" && mv "$LIST.new" "$LIST"
: > "$STUB_DIR/calls.log"; rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
OUT="$("$SCRIPT" --no-wait)"
check "no ledger, no concertmaster: nothing sent" "$(sends)" "0"
check "no ledger, no concertmaster: an inbox note says why" "$(grep -l 'No standing local lanes' "$CM_HOME"/inbox/boot-sweep-*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
# ---- the concertmaster worktree drift check and the capacity count at boot ----
# a ledger with the concertmaster row only, and one concertmaster terminal, so the sweep reaches its normal report and note
printf '{"workers":{"concertmaster":{"standing":true,"host":"local","path":"%s"}}}\n' "$CMWT" > "$CM_HOME/ledger.json"
printf '{"ok":true,"result":{"terminals":[{"handle":"t_cm","worktreePath":"%s","agentIdentity":"claude"}]}}\n' "$CMWT" > "$LIST"
mkp "$CMWT" 1; : > "$STUB_DIR/calls.log"; : > "$STUB_DIR/sync-calls.log"; rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
OUT="$("$SCRIPT" --no-wait 2>"$ROOT/err")"
check "level worktree: the sync script ran once with no arguments" "$(tr -d ' \n' < "$STUB_DIR/sync-calls.log")|$(wc -l < "$STUB_DIR/sync-calls.log" | tr -d ' ')" "|1"
check "level worktree: silent, no (worktree-sync) row" "$(res '(worktree-sync)')" ""
OUT="$(STUB_SYNC_OUT='cm-worktree-sync: ff aaaaaaaaaaaa..bbbbbbbbbbbb behind=4' "$SCRIPT" --no-wait 2>"$ROOT/err")"
check "a fast-forward at boot is a report row with the status line" "$(printf '%s\n' "$OUT" | grep -c '^(worktree-sync).*report.*ff aaaaaaaaaaaa..bbbbbbbbbbbb behind=4' || true)" "1"
check "...and is not a blocker (no unit-log line, no BLOCKER in the note)" "$(grep -c 'worktree-sync' "$ROOT/err" || true)$(grep -l 'BLOCKER' "$CM_HOME"/inbox/boot-sweep-*.md 2>/dev/null | wc -l | tr -d ' ')" "00"
BL='cm-worktree-sync: BLOCKED reason=index-lock behind=7 ahead=0 lock=index.lock(age 700000s,size 0,holder=none) | cm:blocked cm-worktree-sync x'
rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv; rm -f "$CM_HOME"/inbox/boot-sweep-*.md
OUT="$(STUB_SYNC_OUT="$BL" STUB_SYNC_RC=1 "$SCRIPT" --no-wait 2>"$ROOT/err")"
check "a blocker is a (worktree-sync) report row with the reason and the count behind" "$(printf '%s\n' "$OUT" | grep -c '^(worktree-sync).*report.*reason=index-lock behind=7' || true)" "1"
check "...the pipe in the line is not left to split the TSV row (still four columns)" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="(worktree-sync)"{print NF}')" "4"
check "...is repeated in the unit log" "$(grep -c 'boot-sweep: cm-worktree-sync: BLOCKED reason=index-lock behind=7' "$ROOT/err" || true)" "1"
check "...and tops the inbox note as a BLOCKER" "$(grep -l 'BLOCKER: the concertmaster worktree is not level with its remote' "$CM_HOME"/inbox/boot-sweep-*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
: > "$STUB_DIR/sync-calls.log"; OUT="$(STUB_SYNC_OUT="$BL" STUB_SYNC_RC=1 "$SCRIPT" --dry-run --no-wait 2>/dev/null)"
check "--dry-run passes --dry-run to the sync script" "$(tr -d ' \n' < "$STUB_DIR/sync-calls.log")" "--dry-run"
check "a sync script that crashes (exit 7, no status line) is still a row" "$(STUB_SYNC_OUT='' STUB_SYNC_RC=7 "$SCRIPT" --no-wait 2>/dev/null | grep -c '^(worktree-sync).*exited 7' || true)" "1"
check "a missing sync script is a row, never silent" "$(CM_WORKTREE_SYNC="$ROOT/nope.sh" "$SCRIPT" --no-wait 2>/dev/null | grep -c '^(worktree-sync).*missing or not executable' || true)" "1"
printf '{"ok":true,"result":{"terminals":[]}}\n' > "$LIST"
check "the row survives the no-terminals early exit" "$(STUB_SYNC_OUT="$BL" STUB_SYNC_RC=1 "$SCRIPT" --no-wait 2>/dev/null | grep -c '^(worktree-sync)' || true)" "1"
check "tick mode (--since) does not run the sync script" "$(: > "$STUB_DIR/sync-calls.log"; "$SCRIPT" --since "$(date +%s)" >/dev/null 2>&1; wc -c < "$STUB_DIR/sync-calls.log" | tr -d ' ')" "0"
check "tick mode (--since) does not run the capacity check" "$(: > "$STUB_DIR/cap-calls.log"; "$SCRIPT" --since "$(date +%s)" >/dev/null 2>&1; wc -c < "$STUB_DIR/cap-calls.log" | tr -d ' ')" "0"
# capacity (counts only at boot): silent within cap, one row over cap, a row for a crash or an unread host, always --no-candidates
printf '{"ok":true,"result":{"terminals":[{"handle":"t_cm","worktreePath":"%s","agentIdentity":"claude"}]}}\n' "$CMWT" > "$LIST"
mkp "$CMWT" 1; : > "$STUB_DIR/cap-calls.log"; rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
OUT="$(STUB_CAP_OUT='capacity: 0 of 2 hosts over cap (target 0)' "$SCRIPT" --no-wait 2>"$ROOT/err")"
check "capacity within cap: the check ran once with --no-candidates and the sweep adds no row" "$(tr -d '\n' < "$STUB_DIR/cap-calls.log")|$(printf '%s\n' "$OUT" | grep -c '^(capacity)' || true)" "--no-candidates|0"
CAPOVER='capacity: 1 of 2 hosts over cap (target 0)
  HOST local claude=26 cap=11 OVER by 15
  HOST box2 claude=1 cap=2 ok (none needed)'
rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
OUT="$(STUB_CAP_OUT="$CAPOVER" STUB_CAP_RC=1 "$SCRIPT" --no-wait 2>"$ROOT/err")"
check "an over-cap host is one (capacity) report row naming the host, its count and its cap" "$(printf '%s\n' "$OUT" | grep -c '^(capacity).*report.*local claude=26 cap=11 OVER by 15' || true)" "1"
check "...the row says the tick lists the candidates and no ok host is named" "$(printf '%s\n' "$OUT" | grep '^(capacity)' | grep -c 'box2' || true)|$(printf '%s\n' "$OUT" | grep '^(capacity)' | grep -c 'listed by the tick' || true)" "0|1"
check "...and the row keeps four TSV columns" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="(capacity)"{print NF}')" "4"
rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
OUT="$(STUB_CAP_OUT='capacity: 0 of 1 hosts over cap (target 0) (CHECK INCOMPLETE: box2: rc=1 unreachable)' "$SCRIPT" --no-wait 2>/dev/null)"
check "an unread host is a (capacity) row with CHECK INCOMPLETE, never silent" "$(printf '%s\n' "$OUT" | grep -c '^(capacity).*CHECK INCOMPLETE: box2' || true)" "1"
rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
check "a capacity script that crashes (exit 7, no status line) is still a row" "$(STUB_CAP_OUT='' STUB_CAP_RC=7 "$SCRIPT" --no-wait 2>/dev/null | grep -c '^(capacity).*exited 7' || true)" "1"
rm -f "${CM_HOME:?}/cache/boot-sweep-"*.tsv
check "a missing capacity script is a row, never silent" "$(CM_CAPACITY_CHECK="$ROOT/nope.sh" "$SCRIPT" --no-wait 2>/dev/null | grep -c '^(capacity).*missing or not executable' || true)" "1"
# ---- the INSTALLED copy (the unit runs ~/.concertmaster/bin, not the repo): no stand-ins, the files named by the cp line of
# references/boot-sweep.md, in a directory that is no git worktree ----
SKILLDIR="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
DOC="$SKILLDIR/references/boot-sweep.md"
doc_cp_files() { awk '/^cp scripts\/boot-sweep.sh/{f=1} f{print} f&&/\.concertmaster\/bin\/ *\\?$/{exit}' "$DOC" | tr ' ' '\n' | grep '^scripts/' | sed 's#^scripts/##'; }
install_from_doc() { # <dest> <files...>
  local d="$1" f; shift; rm -rf -- "${d:?}"; mkdir -p "$d"
  for f in "$@"; do cp "$SKILLDIR/scripts/$f" "$d/" 2>/dev/null; done
  chmod +x "$d"/*.sh 2>/dev/null
  cp "$SKILLDIR"/scripts/*.jq "$d/" 2>/dev/null
}
DOCFILES="$(doc_cp_files | tr '\n' ' ')"
check "the doc's install line names the two boot checks" "$(printf '%s\n' "$DOCFILES" | tr ' ' '\n' | grep -cx 'cm-worktree-sync.sh\|capacity-check.sh')" "2"
# shellcheck disable=SC2086  # the file list is word-split on purpose
install_from_doc "$ROOT/installed-bin" $DOCFILES
rm -rf -- "${CM_HOME:?}/cache" "${CM_HOME:?}"/inbox/boot-sweep-*.md
: > "$STUB_DIR/calls.log"
OUT="$(env -u CM_WORKTREE_SYNC -u CM_CAPACITY_CHECK "$ROOT/installed-bin/boot-sweep.sh" --dry-run --no-wait 2>"$ROOT/err")"
check "installed copy: no (worktree-sync) or (capacity) row says missing" "$(printf '%s\n' "$OUT" | grep -c '^(\(worktree-sync\|capacity\)).*missing or not executable' || true)" "0"
check "installed copy: (worktree-sync) is an INFO 'not configured' row, never a BLOCKED" "$(printf '%s\n' "$OUT" | grep -c '^(worktree-sync).*cm-worktree-sync: INFO not configured' || true)|$(printf '%s\n' "$OUT" | grep -c '^(worktree-sync).*BLOCKED' || true)" "1|0"
# the doc list dropping a script is what the test must notice: install without the two and the rows say missing
install_from_doc "$ROOT/installed-bin2" boot-sweep.sh lib.sh
OUT="$(env -u CM_WORKTREE_SYNC -u CM_CAPACITY_CHECK "$ROOT/installed-bin2/boot-sweep.sh" --dry-run --no-wait 2>/dev/null)"
check "(the case bites) an install without the two scripts reports both as missing" "$(printf '%s\n' "$OUT" | grep -c '^(\(worktree-sync\|capacity\)).*missing or not executable' || true)" "2"
exit $fail
