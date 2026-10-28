#!/usr/bin/env bash
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
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home" STUB_DIR="$ROOT/stub" CM_CLAUDE_PROJECTS="$ROOT/projects"
mkdir -p "$CM_HOME/cache" "$STUB_DIR" "$CM_CLAUDE_PROJECTS"
cat > "$ROOT/cfg.yaml" <<'Y'
worktrees: { path_match: "/acme-app/" }
lanes:
  - { name: slow, loop_minutes: 60 }
Y
export CM_PATH_MATCH="/acme-app/" CM_CONFIG="$ROOT/cfg.yaml" CM_BOOT_CONFIRM_S=3
NOW="$(date +%s)"

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
"$SCRIPT" --bogus >/dev/null 2>&1; check "bad usage: exit 2" "$?" "2"
exit $fail
