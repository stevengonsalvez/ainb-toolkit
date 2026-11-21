#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# runtime-check.sh test: STUBBED orca (the live terminal-read shape), fake Claude transcripts with set
# ages, a fixture ledger. Asserts the runtime-restart check: renamed terminal handles are detected and
# refreshed in the ledger BY PATH; a stale lane (transcript older than 2 x its loop interval, 1 x when its
# handle churned) is nudged ONCE through boot-sweep.sh --since/--lanes, a fresh one is skipped; menu,
# mid-turn and shell-prompt lanes are not typed into; an unconfirmed nudge is retried once then gave-up and
# never repeated every tick; a per-lane loopIntervalMin wins; non-standing lanes, the concertmaster and other
# projects are never touched; --dry-run sends and writes nothing.
# Touches nothing outside a mktemp dir. No real orca, no network.
#
#   scripts/test/runtime-check.sh         # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../runtime-check.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-runtime-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home" STUB_DIR="$ROOT/stub" CM_CLAUDE_PROJECTS="$ROOT/projects"
mkdir -p "$CM_HOME/cache" "$STUB_DIR" "$CM_CLAUDE_PROJECTS"
cat > "$ROOT/cfg.yaml" <<'Y'
worktrees: { path_match: "/acme-app/" }
lanes:
  - { name: slow, loop_minutes: 60 }
Y
export CM_PATH_MATCH="/acme-app/" CM_CONFIG="$ROOT/cfg.yaml" CM_BOOT_CONFIRM_S=3
NOW="$(date +%s)"

FAKE_LH="$ROOT/fake-lane-handles.sh"
cat > "$FAKE_LH" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = --worker ]; then ids="$2"; else ids="$(jq -r '.workers | keys[]' "$CM_HOME/ledger.json" 2>/dev/null)"; fi
for id in $ids; do
  h="$(jq -r --arg i "$id" '.workers[$i].terminal // empty' "$CM_HOME/ledger.json" 2>/dev/null)"
  [ -n "$h" ] || continue
  mkdir -p "$CM_HOME/lanes/$id"
  printf '%s\tlocal\tclaude\t-\t%s\n' "$h" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/$id/handle"
done
exit 0
FAKE
chmod +x "$FAKE_LH"
export CM_TEST=1 CM_LANE_HANDLES="$FAKE_LH"

wt() { printf '%s/wt/acme-app/%s' "$ROOT" "$1"; }
CMWT="$ROOT/wt/acme-app/concertmaster"
tdirp() { printf '%s/%s' "$CM_CLAUDE_PROJECTS" "$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"; }
mk() { # mk <lane> <transcript age in minutes>
  mkdir -p "$(tdirp "$(wt "$1")")"; touch -d "@$((NOW - $2 * 60))" "$(tdirp "$(wt "$1")")/s.jsonl"
}
# lane: age (min) at start. Default loop interval is 30 (config absent), so the stale limit is 60 min.
mk churn 40        # handle renamed, 40m old: churned, judged after ONE interval (30m): nudged
mk churnfresh 5    # handle renamed, 5m old: refreshed, not nudged
mk stale 90        # same handle, 90m old (> 2 x 30): nudged
mk fresh 10        # same handle, 10m old: skipped, nothing sent
mk between 45      # same handle, 45m old (1x to 2x, no churn): not yet stale
mk busy 90; mk menu 90; mk shell 90; mk unconf 90
mk custom 25       # loopIntervalMin 10: 25m > 2 x 10, nudged though under the 60m default
mk slow 90         # lane "slow": config loop_minutes 60, so 90m is NOT stale (limit 120m); the 30m default would be
mk zsh 90          # a zsh prompt (with spaces) under Claude scrollback: never typed into
mk noterm2 25      # no handle recorded, loopIntervalMin 10: "handle set" and stale (25m > 2 x 10m)
mk nonstanding 90; mk notrans 0
mkdir -p "$(tdirp "$(wt nodir)")"   # no transcript at all: unknown
mk dup 90

cat > "$CM_HOME/ledger.json" <<J
{"workers":{
 "w-churn":   {"standing":true,"host":"local","path":"$(wt churn)","terminal":"t_churn_old"},
 "w-cfresh":  {"standing":true,"host":"local","path":"$(wt churnfresh)/","terminal":"t_cf_old"},
 "w-stale":   {"standing":true,"host":"local","path":"$(wt stale)","terminal":"t_stale"},
 "w-fresh":   {"standing":true,"host":"local","path":"$(wt fresh)","terminal":"t_fresh"},
 "w-between": {"standing":true,"host":"local","path":"$(wt between)","terminal":"t_between"},
 "w-busy":    {"standing":true,"host":"local","path":"$(wt busy)","terminal":"t_busy"},
 "w-menu":    {"standing":true,"host":"local","path":"$(wt menu)","terminal":"t_menu"},
 "w-shell":   {"standing":true,"host":"local","path":"$(wt shell)","terminal":"t_shell"},
 "w-unconf":  {"standing":true,"host":"local","path":"$(wt unconf)","terminal":"t_unconf"},
 "w-custom":  {"standing":true,"host":"local","path":"$(wt custom)","terminal":"t_custom","loopIntervalMin":10},
 "w-slow":    {"standing":true,"host":"local","path":"$(wt slow)","terminal":"t_slow","lane":"slow"},
 "w-zsh":     {"standing":true,"host":"local","path":"$(wt zsh)","terminal":"t_zsh"},
 "w-noterm2": {"standing":true,"host":"local","path":"$(wt noterm2)","loopIntervalMin":10},
 "w-nonst":   {"standing":false,"host":"local","path":"$(wt nonstanding)","terminal":"t_nonst"},
 "w-noterm":  {"standing":true,"host":"local","path":"$(wt notrans)","terminal":"t_gone"},
 "w-nodir":   {"standing":true,"host":"local","path":"$(wt nodir)","terminal":"t_nodir"},
 "w-dup":     {"standing":true,"host":"local","path":"$(wt dup)","terminal":"t_dup1"},
 "w-gone":    {"standing":true,"host":"local","path":"$(wt gone)","terminal":"t_old","state":"gone"},
 "w-remote":  {"standing":true,"host":"remote-host","path":"$(wt remote)","terminal":"t_remote"},
 "concertmaster": {"standing":true,"host":"local","path":"$CMWT","terminal":"t_cm"}
}}
J
LEDGER_BEFORE="$(cat "$CM_HOME/ledger.json")"

LIST="$ROOT/terminals.json"
{
  printf '{"result":{"terminals":['
  printf '{"handle":"t_churn_new","worktreePath":"%s","agentIdentity":"claude"},' "$(wt churn)"
  printf '{"handle":"t_cf_new","worktreePath":"%s","agentIdentity":"claude"},' "$(wt churnfresh)"
  for l in stale fresh between busy menu shell unconf custom nonst nodir slow zsh noterm2; do printf '{"handle":"t_%s","worktreePath":"%s","agentIdentity":"claude"},' "$l" "$(wt $l)"; done
  printf '{"handle":"t_dup1","worktreePath":"%s","agentIdentity":"claude"},{"handle":"t_dup2","worktreePath":"%s","agentIdentity":"claude"},' "$(wt dup)" "$(wt dup)"
  printf '{"handle":"t_cm","worktreePath":"%s","agentIdentity":"claude"},' "$CMWT"
  printf '{"handle":"t_codexterm","worktreePath":"%s","agentIdentity":"codex"},' "$(wt notrans)"
  printf '{"handle":"t_other","worktreePath":"%s/wt/otherproject/x","agentIdentity":"claude"}' "$ROOT"
  printf ']}}'
} > "$LIST"
export LIST

# Stub orca: the LIVE `terminal read --screen` shape (.result.terminal.tail). A nudge that works advances the lane's
# transcript (touch); t_unconf accepts input but nothing happens.
cat > "$ROOT/orca" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls.log"
cmd="$1 $2"; shift 2; h=""
while [ $# -gt 0 ]; do [ "$1" = "--terminal" ] && h="$2"; shift; done
tail_json() { printf '{"ok":true,"result":{"terminal":{"handle":"%s","tail":%s}}}\n' "$h" "$1"; }
case "$cmd" in
  "terminal list") cat "$LIST" ;;
  "terminal read")
    case "$h" in
      t_menu)  tail_json '["Pick one","Enter to select · Arrow keys to navigate"]' ;;
      t_busy)  tail_json '["working (12s · esc to interrupt)","bypass permissions on"]' ;;
      t_shell) tail_json '["some output","claude@host:~$ "]' ;;
      t_zsh)   tail_json '["❯ ","  ? for shortcuts","claude@host-a ~/x %"]' ;;
      *)       tail_json '["❯ ","  ? for shortcuts"]' ;;
    esac ;;
  "terminal send")
    lane="${h#t_}"; lane="${lane%_new}"; [ "$h" = t_cf_new ] && lane=churnfresh
    [ "$h" = t_unconf ] || for d in "$CM_CLAUDE_PROJECTS"/*-"$lane"; do [ -d "$d" ] && touch "$d/s.jsonl"; done
    echo '{"ok":true}' ;;
esac
S
chmod +x "$ROOT/orca"
export ORCA_CLI_COMMAND="$ROOT/orca"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
res() { printf '%s\n' "$OUT" | awk -F'\t' -v n="$1" '$1==n{print $4}'; }
sent_to() { grep -c "^terminal send --terminal $1 " "$STUB_DIR/calls.log" 2>/dev/null || true; }
sends() { grep -c '^terminal send' "$STUB_DIR/calls.log" 2>/dev/null || true; }
rec() { jq -r --arg k "$1" '.workers[$k].terminal // "null"' "$CM_HOME/ledger.json"; }

# ---- dry run: decides, sends nothing, writes nothing ------------------------------------------
: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT" --dry-run)"
check "dry-run: stale lane would be nudged" "$(res w-stale)" "would-nudge"
check "dry-run: churned lane would be nudged" "$(res w-churn)" "would-nudge"
check "dry-run sends nothing" "$(sends)" "0"
check "dry-run leaves the ledger byte-for-byte alone" "$(cat "$CM_HOME/ledger.json")" "$LEDGER_BEFORE"

# ---- real run ----------------------------------------------------------------------------------
: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT")"
check "handle churn detected and the lane nudged once (1x interval)" "$(res w-churn)" "nudged"
check "churn row names the old and new handle" "$(printf '%s\n' "$OUT" | grep -c 'handle churn t_churn_old -> t_churn_new')" "1"
check "churned lane with a fresh transcript is refreshed, not nudged" "$(res w-cfresh)" "refreshed"
check "ledger handle re-resolved by path (churn)" "$(rec w-churn)" "t_churn_new"
check "ledger handle re-resolved by path (trailing-slash path, fresh lane)" "$(rec w-cfresh)" "t_cf_new"
check "refresh stamps terminalRefreshedAt" "$(jq -r '.workers["w-churn"].terminalRefreshedAt | type' "$CM_HOME/ledger.json")" "string"
check "stale lane (90m > 2 x 30m) nudged" "$(res w-stale)" "nudged"
check "fresh lane skipped" "$(res w-fresh)" "ok"
check "lane between 1x and 2x with no churn is not yet stale" "$(res w-between)" "ok"
check "mid-turn lane not typed into" "$(res w-busy)" "busy"
check "question menu not typed into" "$(res w-menu)" "menu"
check "shell prompt reported, not typed into" "$(res w-shell)" "report"
check "accepted but no turn: unconfirmed" "$(res w-unconf)" "unconfirmed"
check "per-lane loopIntervalMin 10 makes 25m stale" "$(res w-custom)" "nudged"
check "non-standing lane never touched" "$(printf '%s\n' "$OUT" | grep -c 'w-nonst')" "0"
check "remote-host and gone ledger rows never touched" "$(printf '%s\n' "$OUT" | grep -cE 'w-remote|w-gone')" "0"
check "the concertmaster itself is never nudged from here" "$(printf '%s\n' "$OUT" | grep -c 'concertmaster')" "0"
check "lane whose terminal is gone is reported no-terminal (codex terminal ignored)" "$(res w-noterm)" "no-terminal"
check "no transcript at all is unknown, not nudged" "$(res w-nodir)" "unknown"
check "duplicate Claude terminals: reported, untouched" "$(res w-dup)" "duplicate"
check "duplicate lane ledger handle is NOT rewritten" "$(rec w-dup)" "t_dup1"
check "config lanes[].loop_minutes 60: a 90m-old lane is not stale" "$(res w-slow)" "ok"
check "zsh prompt with spaces under Claude scrollback: reported, not typed into" "$(res w-zsh)" "report"
check "empty ledger terminal + loopIntervalMin 10: handle set, nudged (columns not shifted)" "$(res w-noterm2)/$(printf '%s\n' "$OUT" | grep -c 'handle set t_noterm2')" "nudged/1"
check "ledger handle written for the lane that had none" "$(rec w-noterm2)" "t_noterm2"
check "exactly the churn, stale, unconf, custom and noterm2 lanes got input" "$(sends)" "5"
check "each nudged lane got one send" "$(for h in t_churn_new t_stale t_unconf t_custom t_noterm2; do sent_to $h; done | tr '\n' ' ')" "1 1 1 1 1 "
check "nothing sent to fresh, between, busy, menu, shell, non-standing, dup, cm, other-project, codex" "$(grep -cE 'send --terminal (t_fresh|t_between|t_busy|t_menu|t_shell|t_zsh|t_slow|t_nonst|t_dup1|t_dup2|t_cm|t_other|t_codexterm|t_cf_new) ' "$STUB_DIR/calls.log" || true)" "0"
check "a churned lane is told Orca restarted" "$(grep -c '^terminal send --terminal t_churn_new .*Orca restarted' "$STUB_DIR/calls.log" || true)" "1"
check "a stale lane with NO churn gets the neutral status check, not a claim that Orca restarted" "$(grep -c '^terminal send --terminal t_stale .*Status check from the concertmaster' "$STUB_DIR/calls.log" || true)/$(grep -c '^terminal send --terminal t_stale .*Orca restarted' "$STUB_DIR/calls.log" || true)" "1/0"
check "no inbox note is written by the tick mode" "$(find "$CM_HOME/inbox" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---- second tick: nudged lanes are active now; unconfirmed retried once, then gave-up ------------
: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT")"
check "nudged lane is fresh next tick (no second nudge)" "$(res w-stale)" "ok"
check "churned lane is fresh next tick and its handle is stable" "$(res w-churn)" "ok"
check "second tick: nothing refreshed, ledger handle unchanged" "$(rec w-churn)" "t_churn_new"
check "unconfirmed lane retried once" "$(res w-unconf)" "unconfirmed"
OUT="$("$SCRIPT")"
check "after two nudges the lane is gave-up, not nudged every tick" "$(res w-unconf)" "gave-up"
check "gave-up: only the one retry was sent since the first tick (1 + the first tick = two nudges)" "$(sent_to t_unconf)" "1"
OUT="$("$SCRIPT")"
check "gave-up stays gave-up on later ticks" "$(res w-unconf)" "gave-up"
check "later ticks send the gave-up lane nothing more" "$(sent_to t_unconf)" "1"

# ---- a lane that gets going starts a fresh episode (attempts are per transcript) ----------------
# w-unconf is gave-up (2 nudges, transcript unchanged). Its transcript changing means it took a turn: new episode.
touch -d "@$((NOW - 100 * 60))" "$(tdirp "$(wt unconf)")/s.jsonl"
: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT")"
check "gave-up lane whose transcript changed starts a fresh episode and is nudged again" "$(res w-unconf)" "unconfirmed"
check "that fresh-episode lane really got a send" "$(sent_to t_unconf)" "1"

# ---- a lane that takes a turn after every nudge but never re-arms: capped across episodes --------
# t_stale was nudged once in tick 1 (history 1 of 3). Each round: quiet again at a DIFFERENT transcript age (a new
# episode every time, so the per-episode cap of two cannot be what stops it), nudged, takes a turn.
for round in 2 3; do
  touch -d "@$((NOW - (130 + round) * 60))" "$(tdirp "$(wt stale)")/s.jsonl"
  : > "$STUB_DIR/calls.log"; OUT="$("$SCRIPT")"
  check "nudge number $round in 6h goes out" "$(res w-stale)/$(sent_to t_stale)" "nudged/1"
done
touch -d "@$((NOW - 140 * 60))" "$(tdirp "$(wt stale)")/s.jsonl"
: > "$STUB_DIR/calls.log"; OUT="$("$SCRIPT")"
check "the 4th in 6h is gave-up and nothing is sent" "$(res w-stale)/$(sent_to t_stale)" "gave-up/0"
check "...by the 6h cap (not the per-episode one)" "$(printf '%s\n' "$OUT" | grep -c 'w-stale.*nudged 3 times in 6 h')" "1"

# ---- churn persists after the first tick refreshed the handle ------------------------------------
check "terminalChurnAt is stamped for a churned lane" "$(jq -r '.workers["w-cfresh"].terminalChurnAt | type' "$CM_HOME/ledger.json")" "string"
check "terminalChurnAt is NOT stamped for a first-time handle set" "$(jq -r '.workers["w-noterm2"].terminalChurnAt | type' "$CM_HOME/ledger.json")" "null"
# The lane went quiet 45m ago (over 1 x 30m, under 2 x 30m) and the ledger says the restart came after that turn.
touch -d "@$((NOW - 45 * 60))" "$(tdirp "$(wt churnfresh)")/s.jsonl"
jq '.workers["w-cfresh"].terminalChurnAt = (now | todate)' "$CM_HOME/ledger.json" > "$CM_HOME/l.tmp" && mv "$CM_HOME/l.tmp" "$CM_HOME/ledger.json"
: > "$STUB_DIR/calls.log"; OUT="$("$SCRIPT")"
check "a later tick still treats the lane as churned (1 x limit) and nudges it" "$(res w-cfresh)" "nudged"
check "...with the restart text, not the neutral one" "$(grep -c '^terminal send --terminal t_cf_new .*Orca restarted' "$STUB_DIR/calls.log" || true)" "1"
check "once the lane took a turn it is no longer churned (next tick: ok)" "$(OUT="$("$SCRIPT")"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="w-cfresh"{print $4}')" "ok"

# ---- resume.lock: handles refresh, nothing is sent ---------------------------------------------
touch -d "@$((NOW - 200 * 60))" "$(tdirp "$(wt fresh)")/s.jsonl"
jq '.workers["w-fresh"].terminal = "t_fresh_recorded_old"' "$CM_HOME/ledger.json" > "$CM_HOME/l.tmp" && mv "$CM_HOME/l.tmp" "$CM_HOME/ledger.json"
mkdir -p "$CM_HOME" && : > "$CM_HOME/resume.lock"
: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT")"
check "resume.lock: a churned stale lane is reported resume-in-progress" "$(res w-fresh)" "resume-in-progress"
check "resume.lock: nothing is sent" "$(sends)" "0"
check "resume.lock: the ledger handle is still refreshed by path" "$(rec w-fresh)" "t_fresh"
rm -f "$CM_HOME/resume.lock"

# ---- unreadable inputs fail closed --------------------------------------------------------------
mv "$CM_HOME/ledger.json" "$CM_HOME/ledger.off"
"$SCRIPT" >/dev/null 2>&1; check "no ledger: exit 1, nothing sent" "$?" "1"
mv "$CM_HOME/ledger.off" "$CM_HOME/ledger.json"
echo '{"ok":false}' > "$LIST"
: > "$STUB_DIR/calls.log"
OUT="$("$SCRIPT" 2>/dev/null)"
check "terminal list failing: one unreadable row, nothing sent, ledger untouched" "$(printf '%s\n' "$OUT" | awk -F'\t' '$4=="unreadable"' | wc -l | tr -d ' ')/$(sends)" "1/0"
# ---- Code Mode dialog recovery : scripts/codemode-recover.sh through runtime-check.sh -------------------------------------
# A host reboot leaves each resumed lane on the Claude Code Code Mode opt-in dialog. The pane text is neutral fixture text. A second
# stub serves panes from files, counts the Esc keys it receives and swaps in an "after Esc" pane when one is set; a remote host
# (--environment remote-host) has its own terminal list, and bad-host has none.
echo "--- Code Mode dialog recovery"
P2="$ROOT/panes"; export P2
export CM_CODEMODE_SETTLE_S=0 CM_CODEMODE_POLLS=2
cat > "$ROOT/orca2" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls2.log"
cmd="$1 $2"; shift 2; h=""; env=""; txt=""
while [ $# -gt 0 ]; do
  case "$1" in --terminal) h="$2"; shift ;; --environment) env="$2"; shift ;; --text) txt="$2"; shift ;; esac
  shift
done
case "$cmd" in
  "terminal list") case "$env" in remote-host) cat "$LIST_R" ;; bad-host) echo '{"ok":false}' ;; *) cat "$LIST2" ;; esac ;;
  "terminal read")
    [ -f "$P2/lock-on-read.$h" ] && : > "$CM_HOME/resume.lock"
    if [ -f "$P2/pane.$h" ]; then printf '{"ok":true,"result":{"terminal":{"handle":"%s","tail":%s}}}\n' "$h" "$(jq -Rn '[inputs]' < "$P2/pane.$h")"
      if [ -f "$P2/flip.$h" ]; then cp "$P2/flip.$h" "$P2/pane.$h"; rm -f "$P2/flip.$h"; fi
    else printf '{"ok":true,"result":{"terminal":{"handle":"%s","tail":["❯ ","  ? for shortcuts"]}}}\n' "$h"; fi ;;
  "terminal send")
    if [ "$txt" = $'\033' ]; then
      n="$(cat "$P2/esc.$h" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$P2/esc.$h"
      [ -f "$P2/after-esc.$h" ] && cp "$P2/after-esc.$h" "$P2/pane.$h"
    else
      lane="${h#t_}"; for d in "$CM_CLAUDE_PROJECTS"/*-"$lane"; do [ -d "$d" ] && touch "$d/s.jsonl"; done
    fi
    echo '{"ok":true}' ;;
esac
S
chmod +x "$ROOT/orca2"
export ORCA_CLI_COMMAND="$ROOT/orca2" PLUGLY_CLI_COMMAND="$ROOT/orca2"
export LIST2="$ROOT/terminals2.json" LIST_R="$ROOT/terminals-r.json"
IDLE=('❯ ' '  ? for shortcuts')
DIALOG=(' ╭──────────────────────────────────────────╮' ' │ Try Code Mode?                            │' ' │ ❯ 1. Yes, turn on Code Mode               │' ' │   2. No, start without it                 │' ' ╰──────────────────────────────────────────╯' ' Enter to confirm · Esc to start without it')
pane() { local h="$1"; shift; printf '%s\n' "$@" > "$P2/pane.$h"; }
after() { local h="$1"; shift; printf '%s\n' "$@" > "$P2/after-esc.$h"; }
for l in cm1 cm2 cm3 cm4 cm5 cm6 cm7 cm8 cm9 cmu cmf ctl; do mk "$l" 90; done
# the terminal lists: every handle is t_<lane>; cm9 has two Claude terminals; the other-project terminal is not ours
{
  printf '{"ok":true,"result":{"terminals":['
  for l in cm1 cm2 cm3 cm4 cm5 cm6 cm7 cm8 cmu cmf ctl; do printf '{"handle":"t_%s","worktreePath":"%s","agentIdentity":"claude"},' "$l" "$(wt $l)"; done
  printf '{"handle":"t_cm9a","worktreePath":"%s","agentIdentity":"claude"},{"handle":"t_cm9b","worktreePath":"%s","agentIdentity":"claude"},' "$(wt cm9)" "$(wt cm9)"
  printf '{"handle":"t_cm","worktreePath":"%s","agentIdentity":"claude"},' "$CMWT"
  printf '{"handle":"t_other","worktreePath":"%s/wt/otherproject/x","agentIdentity":"claude"}' "$ROOT"
  printf ']}}'
} > "$LIST2"
{
  printf '{"ok":true,"result":{"terminals":['
  printf '{"handle":"t_rcm","worktreePath":"%s","agentIdentity":"claude"},{"handle":"t_rcw","worktreePath":"%s","agentIdentity":"claude"}' "$(wt rcm)" "$(wt rcw)"
  printf ']}}'
} > "$LIST_R"
ledger2() {
  cat > "$CM_HOME/ledger.json" <<J
{"workers":{
 "w-cm1": {"standing":true,"host":"local","path":"$(wt cm1)","terminal":"t_cm1"},
 "w-cm2": {"standing":false,"host":"local","path":"$(wt cm2)","terminal":"t_cm2"},
 "w-cm3": {"standing":true,"host":"local","path":"$(wt cm3)","terminal":"t_cm3"},
 "w-cm4": {"standing":true,"host":"local","path":"$(wt cm4)","terminal":"t_cm4"},
 "w-cm5": {"standing":true,"host":"local","path":"$(wt cm5)","terminal":"t_cm5"},
 "w-cm6": {"standing":true,"host":"local","path":"$(wt cm6)","terminal":"t_cm6"},
 "w-cm7": {"standing":true,"host":"local","path":"$(wt cm7)","terminal":"t_cm7"},
 "w-cm8": {"standing":true,"host":"local","path":"$(wt cm8)","terminal":"t_cm8"},
 "w-cm9": {"standing":true,"host":"local","path":"$(wt cm9)","terminal":"t_cm9a"},
 "w-cmu": {"standing":true,"host":"local","path":"$(wt cmu)","terminal":"t_cmu_old"},
 "w-cmf": {"standing":true,"host":"local","path":"$(wt cmf)","terminal":"t_cmf"},
 "w-ctl": {"standing":true,"host":"local","path":"$(wt ctl)","terminal":"t_ctl"},
 "w-rcm": {"standing":true,"host":"remote-host","path":"$(wt rcm)","terminal":"t_rcm"},
 "w-rcw": {"standing":false,"host":"remote-host","path":"$(wt rcw)","terminal":"t_rcw"},
 "w-bad": {"standing":true,"host":"bad-host","path":"$(wt bad)","terminal":"t_bad"},
 "w-gone2": {"standing":true,"host":"remote-host","path":"$(wt rcm)","terminal":"t_old","state":"gone"},
 "concertmaster": {"standing":true,"host":"local","path":"$CMWT","terminal":"t_cm"}
}}
J
}
world() { # a fresh world: ledger, panes, Esc counters, state, call log
  export CM_HOME="$ROOT/home2-$1"; rm -rf "$CM_HOME" "$P2"; mkdir -p "$CM_HOME/cache" "$P2"; ledger2; : > "$STUB_DIR/calls2.log"
  for l in cm1 cm2 cm3 cm4 cm5 cm6 cm7 cm8 cm9 cmu cmf ctl; do touch -d "@$((NOW - 90 * 60))" "$(tdirp "$(wt $l)")/s.jsonl"; done
  pane t_cm1 "${DIALOG[@]}";  after t_cm1 "${IDLE[@]}"       # the happy path: Esc closes it, the pane is idle
  pane t_cm2 "${DIALOG[@]}";  after t_cm2 "${IDLE[@]}"       # a non-standing worker
  pane t_cm3 "${DIALOG[@]}"                                  # the dialog survives Esc
  pane t_cm4 "${DIALOG[@]}";  after t_cm4 'working (12s · esc to interrupt)' 'bypass permissions on'   # closed, lane is mid-turn
  pane t_cm5 'Allow this command?' '  1. Yes' '  2. No' ' Esc to cancel'                         # a permission prompt
  pane t_cm6 'Pick a model' '  1. Sonnet' '  2. Opus' ' Enter to confirm · Esc to cancel'          # another select menu
  pane t_cm7 "${DIALOG[@]}" '❯ ' '  ? for shortcuts'                                              # old dialog text above a live prompt
  pane t_cm8 'Try something else?' ' Enter to confirm · Esc to start without it'                  # lookalike footer, no Code Mode words
  pane t_cm9a "${DIALOG[@]}"; pane t_cm9b "${DIALOG[@]}"                                             # two Claude terminals in one worktree
  pane t_cm "${DIALOG[@]}"                                                                       # the concertmaster's own pane
  pane t_rcm "${DIALOG[@]}"; after t_rcm "${IDLE[@]}"       # remote host
  pane t_rcw "${DIALOG[@]}"                                  # remote worker, dialog survives Esc
  : > "$P2/pane.t_cmu"                                       # a pane that reads blank (still loading): nothing may be sent or skipped
  pane t_cmf "${DIALOG[@]}"; printf '%s\n' "${IDLE[@]}" > "$P2/flip.t_cmf"   # the dialog is gone by the second read, before any Esc
}
esc2() { cat "$P2/esc.$1" 2>/dev/null || echo 0; }
sends2() { grep -c '^terminal send' "$STUB_DIR/calls2.log" 2>/dev/null || true; }
nudges2() { grep -c "^terminal send --terminal $1 .*--enter" "$STUB_DIR/calls2.log" 2>/dev/null || true; }
ESCB="$(printf '\033')"

world a
OUT="$("$SCRIPT" --dry-run)"
check "dry-run: a lane on the dialog would be recovered" "$(res w-cm1)" "would-recover"
check "dry-run: a remote lane on the dialog would be recovered" "$(res w-rcm)" "would-recover"
check "dry-run sends nothing and writes no Esc state" "$(sends2)/$([ -e "$CM_HOME/cache/codemode-recover.tsv" ] && echo state || echo none)" "0/none"
mkdir -p "$CM_HOME" && : > "$CM_HOME/resume.lock"
OUT="$("$SCRIPT")"
check "resume.lock: not one key is sent while a resume runs" "$(sends2)" "0"
rm -f "$CM_HOME/resume.lock"

: > "$STUB_DIR/calls2.log"
OUT="$("$SCRIPT")"
check "dialog then closed after Esc: the lane is recovered" "$(res w-cm1)" "recovered"
check "recovered lane: exactly one Esc and one nudge, nothing else" "$(esc2 t_cm1)/$(nudges2 t_cm1)/$(grep -c '^terminal send --terminal t_cm1 ' "$STUB_DIR/calls2.log")" "1/1/2"
check "the Esc is a single key, no Enter, and it goes BEFORE the nudge" "$(grep '^terminal send --terminal t_cm1 ' "$STUB_DIR/calls2.log" | head -n 1 | grep -c "$ESCB")/$(grep '^terminal send --terminal t_cm1 ' "$STUB_DIR/calls2.log" | head -n 1 | grep -c -- '--enter')" "1/0"
check "a standing lane gets the re-arm nudge (loop died with the restart)" "$(grep -c '^terminal send --terminal t_cm1 .*re-arm your standing /loop' "$STUB_DIR/calls2.log" || true)" "1"
check "the lane is not judged or nudged a second time by the stale pass in the same tick" "$(printf '%s\n' "$OUT" | grep -c 'w-cm1')" "1"
check "a non-standing worker is recovered too, with the worker text (no /loop)" "$(res w-cm2)/$(grep -c '^terminal send --terminal t_cm2 .*carry on from where you stopped' "$STUB_DIR/calls2.log")/$(grep -c '^terminal send --terminal t_cm2 .*standing /loop' "$STUB_DIR/calls2.log" || true)" "recovered/1/0"
check "dialog still open after Esc: reported as menu, one Esc, no nudge" "$(res w-cm3)/$(esc2 t_cm3)/$(nudges2 t_cm3)" "menu/1/0"
check "...and the row says the dialog is still open" "$(printf '%s\n' "$OUT" | grep -c 'w-cm3.*Code Mode dialog still open after Esc')" "1"
check "dialog closed but the lane is mid-turn: closed, no nudge" "$(res w-cm4)/$(esc2 t_cm4)/$(nudges2 t_cm4)" "closed/1/0"
check "a permission prompt is NOT touched: no Esc, no text" "$(res w-cm5)/$(esc2 t_cm5)/$(grep -c '^terminal send --terminal t_cm5 ' "$STUB_DIR/calls2.log" || true)" "menu/0/0"
check "another select menu (Esc to cancel) is NOT touched" "$(res w-cm6)/$(esc2 t_cm6)/$(grep -c '^terminal send --terminal t_cm6 ' "$STUB_DIR/calls2.log" || true)" "menu/0/0"
check "old dialog text above a live prompt is NOT matched: no Esc" "$(esc2 t_cm7)" "0"
check "a lookalike footer without the Code Mode words is NOT touched" "$(res w-cm8)/$(esc2 t_cm8)" "menu/0"
check "two Claude terminals in one worktree: no Esc to either" "$(res w-cm9)/$(esc2 t_cm9a)/$(esc2 t_cm9b)" "duplicate/0/0"
check "the concertmaster's own pane is never touched" "$(printf '%s\n' "$OUT" | grep -c concertmaster)/$(esc2 t_cm)" "0/0"
check "an ordinary stale lane still goes through the old path (control)" "$(res w-ctl)/$(esc2 t_ctl)/$(nudges2 t_ctl)" "nudged/0/1"
check "other-project terminal never touched" "$(grep -c 't_other' "$STUB_DIR/calls2.log" || true)" "0"
check "remote lane: recovered through --environment" "$(res w-rcm)/$(esc2 t_rcm)/$(nudges2 t_rcm)" "recovered/1/1"
check "remote lane: EVERY call about it names its host (read, Esc, nudge)" "$(grep 't_rcm' "$STUB_DIR/calls2.log" | grep -vc -- '--environment remote-host' || true)" "0"
check "remote lane: the host's terminal list was read with --environment" "$(grep -c '^terminal list --environment remote-host' "$STUB_DIR/calls2.log")" "1"
check "local lanes never carry --environment on read or send" "$(grep -E '^terminal (read|send) --terminal t_(cm1|cm3|ctl) ' "$STUB_DIR/calls2.log" | grep -c -- '--environment' || true)" "0"
check "remote worker with a stubborn dialog: menu, one Esc, no nudge" "$(res w-rcw)/$(esc2 t_rcw)/$(nudges2 t_rcw)" "menu/1/0"
check "a host whose terminal list fails is skipped quietly (no row, nothing sent to it)" "$(printf '%s\n' "$OUT" | grep -c 'w-bad')/$(grep -c 't_bad' "$STUB_DIR/calls2.log" || true)" "0/0"
check "a dead (gone) remote row at the same path adds nothing" "$(printf '%s\n' "$OUT" | grep -c 'w-gone2')" "0"
check "exactly six Esc keys in all (cm1 cm2 cm3 cm4 rcm rcw), one each" "$(for h in t_cm1 t_cm2 t_cm3 t_cm4 t_rcm t_rcw; do esc2 $h; done | tr '\n' ' ')" "1 1 1 1 1 1 "

# no loop: a dialog that survives Esc gets a second key on the next tick, then none
: > "$STUB_DIR/calls2.log"; OUT="$("$SCRIPT")"
check "tick 2: the stubborn dialog gets its 2nd (last) Esc, still menu" "$(res w-cm3)/$(esc2 t_cm3)" "menu/2"
check "tick 2: the recovered lane is clean now (no further Esc, ordinary row)" "$(esc2 t_cm1)/$(res w-cm1)" "1/ok"
: > "$STUB_DIR/calls2.log"; OUT="$("$SCRIPT")"
check "tick 3: the cap of 2 Esc keys holds, nothing is sent to that terminal" "$(esc2 t_cm3)/$(grep -c '^terminal send --terminal t_cm3 ' "$STUB_DIR/calls2.log" || true)" "2/0"
check "tick 3: the row tells a person to answer it" "$(printf '%s\n' "$OUT" | grep -c 'w-cm3.*menu.*by hand')" "1"

# the Esc record survives a recovery: a terminal that is recovered, then hits the dialog again twice more inside 6 h, gets no 3rd key
pane t_cm1 "${DIALOG[@]}"; after t_cm1 "${IDLE[@]}"; : > "$STUB_DIR/calls2.log"; OUT="$("$SCRIPT")"
check "a 2nd dialog on a recovered terminal (a 2nd reboot) is recovered: Esc number 2" "$(res w-cm1)/$(esc2 t_cm1)" "recovered/2"
pane t_cm1 "${DIALOG[@]}"; after t_cm1 "${IDLE[@]}"; : > "$STUB_DIR/calls2.log"; OUT="$("$SCRIPT")"
check "a 3rd inside the same 6 h is NOT sent: the record was kept through the recoveries" "$(res w-cm1)/$(esc2 t_cm1)/$(grep -c '^terminal send --terminal t_cm1 ' "$STUB_DIR/calls2.log" || true)" "menu/2/0"
# a first read that comes back blank sends nothing and does not take the lane out of the other checks
check "a blank pane is not a Code Mode row and gets no Esc" "$(esc2 t_cmu)/$(printf '%s\n' "$OUT" | grep -c 'w-cmu.*Code Mode')" "0/0"
check "a blank pane: pass 1 still refreshed the lane handle by path" "$(rec w-cmu)" "t_cmu"
check "a blank pane: pass 1 still judged the stale lane (the sweep read the pane and reported it)" "$(res w-cmu)" "unreadable"
check "the dialog gone between the first read and the key: NO Esc, no Code Mode row" "$(esc2 t_cmf)/$(printf '%s\n' "$OUT" | grep -c 'w-cmf.*Code Mode')" "0/0"

# direct: a lane file that names ANOTHER terminal is never overridden, and an Esc that cannot be recorded is never sent
world h
mkdir -p "$CM_HOME/lanes/w-cm1"
printf 't_elsewhere\tlocal\tclaude\t-\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/w-cm1/handle"
CT="$("$HERE/../codemode-recover.sh" --terminal t_cm1 --lane w-cm1 --text hello 2>/dev/null)"
check "a lane handle file naming another terminal: held, no Esc, no text" "$(printf '%s' "$CT" | cut -f1)/$(esc2 t_cm1)/$(sends2)" "held/0/0"
world s
rm -rf "$CM_HOME/cache"; : > "$CM_HOME/cache"
CT="$("$HERE/../codemode-recover.sh" --terminal t_cm1 --lane w-cm1 --text hello 2>/dev/null)"
check "an Esc count that cannot be recorded: held, NOT sent (the cap must hold)" "$(printf '%s' "$CT" | cut -f1)/$(esc2 t_cm1)/$(sends2)" "held/0/0"
world l
: > "$P2/lock-on-read.t_cm1"   # resume.sh starts while the Code Mode pass is reading its first lane
OUT="$("$SCRIPT")"
check "resume.lock appearing mid-pass: that lane is held, not one key is sent" "$(res w-cm1)/$(esc2 t_cm1)/$(sends2)" "held/0/0"
check "resume.lock appearing mid-pass: no later lane is touched either (checked per lane)" "$(for h in t_cm2 t_cm3 t_cm4 t_rcm t_rcw; do esc2 $h; done | tr '\n' ' ')" "0 0 0 0 0 "
rm -f "$CM_HOME/resume.lock"

# direct: the script refuses a control byte in the nudge text before reading or sending anything
: > "$STUB_DIR/calls2.log"
CT="$("$HERE/../codemode-recover.sh" --terminal t_cm1 --lane w-cm1 --text "$(printf 'a\033b')" 2>/dev/null)"
check "codemode-recover.sh refuses a control byte in --text, nothing read or sent" "$(printf '%s' "$CT" | cut -f1)/$(wc -l < "$STUB_DIR/calls2.log" | tr -d ' ')" "send-failed/0"
"$HERE/../codemode-recover.sh" --terminal t_cm1 --lane w-cm1 >/dev/null 2>&1; check "codemode-recover.sh without --text: usage, exit 2" "$?" "2"
"$HERE/../codemode-recover.sh" --terminal t_cm1 --text hello >/dev/null 2>&1; check "codemode-recover.sh without --lane: usage, exit 2 (every send is verified through the lane handle)" "$?" "2"
CT="$("$HERE/../codemode-recover.sh" --terminal t_cm5 --lane w-cm5 --text hello 2>/dev/null)"
check "codemode-recover.sh on a permission prompt: none, nothing sent" "$(printf '%s' "$CT" | cut -f1)/$(grep -c '^terminal send' "$STUB_DIR/calls2.log" || true)" "none/0"

# mutants: a copy of the skill with a guard removed must fail the rows above
mutant() { # <name> <sed script>
  local m="$ROOT/mut-$1"; rm -rf "$m"; mkdir -p "$m"; cp -R "$HERE/.."/. "$m"/ 2>/dev/null
  sed -i.bak "$2" "$m/codemode-recover.sh"
  if cmp -s "$HERE/../codemode-recover.sh" "$m/codemode-recover.sh"; then echo "FAIL mutant $1: the sed no longer matches codemode-recover.sh (update this test)"; fail=1; return 1; fi
  world "m$1"; "$m/runtime-check.sh" >/dev/null 2>&1; return 0
}
if mutant noanchor '/for (j = f + 1; j <= NR; j++)/d'; then
  check "mutant: without the end-of-screen anchor old dialog text gets an Esc (caught by the scrollback row)" "$([ "$(esc2 t_cm7)" = 0 ] && echo missed || echo caught)" "caught"
fi
if mutant noheading 's/for (k = 1; k <= f; k++) if (l\[k\] ~ \/code mode\/) { h = 1; break }/h = 1/'; then
  check "mutant: without the Code Mode heading the lookalike footer gets an Esc (caught)" "$([ "$(esc2 t_cm8)" = 0 ] && echo missed || echo caught)" "caught"
fi
if mutant nocap 's/if \[ "\$tries" -ge "\$MAXESC" \]; then out menu/if false; then out menu/'; then
  for _ in 1 2; do "$ROOT/mut-nocap/runtime-check.sh" >/dev/null 2>&1; done
  check "mutant: without the Esc cap a stubborn dialog gets a 3rd key (caught)" "$([ "$(esc2 t_cm3)" -le 2 ] && echo missed || echo caught)" "caught"
fi

"$SCRIPT" --bogus >/dev/null 2>&1; check "bad usage: exit 2" "$?" "2"
exit $fail
