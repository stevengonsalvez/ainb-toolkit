#!/usr/bin/env bash
# ci-queue-alert.sh test: stubbed gh, a fake clock (CM_NOW), a dead telemetry URL. Asserts: no
# alert under the threshold or before M minutes, exactly one alert per episode (note + outbox event),
# the 2-sample clear with a cleared note, a restarted clock for a new episode, the blind alert after
# 30 minutes without a good sample, empty/garbage state, bad numbers, --dry-run changing nothing even
# from an over-threshold state.
#
#   scripts/test/ci-queue-alert.sh         # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/ci-queue-alert.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-queue-test.XXXXXX")"
trap 'rm -rf "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home" HOME="$ROOT/home" MC_BASE_URL="http://127.0.0.1:9" MC_QUIET=1
export CM_CONFIG=/nonexistent CM_QUEUE_REPO="acme/acme-app"
mkdir -p "$ROOT/bin" "$CM_HOME"
cat > "$ROOT/bin/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) echo "${STUB_BUDGET:-5000}" ;;
  *actions/runs*) [ -n "${STUB_FAIL:-}" ] && exit 1; echo "${STUB_COUNT:-0}" ;;
esac
S
chmod +x "$ROOT/bin/gh"; export PATH="$ROOT/bin:$PATH"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
notes() { find "$CM_HOME/inbox" -name "ci-queue-alert-$1-*.md" 2>/dev/null | wc -l | tr -d ' '; }
events() { grep -c "ci.queue.$1" "$CM_HOME/outbox.jsonl" 2>/dev/null || true; }
T0=1800000000
at() { STUB_COUNT="$2" CM_NOW=$((T0 + $1 * 60)) "$SCRIPT"; }

at 0 5 >/dev/null;   check "under threshold: no alert" "$(notes alert)" "0"
at 5 40 >/dev/null;  at 12 40 >/dev/null; check "over threshold but under 15 min: no alert" "$(notes alert)" "0"
at 21 40 >/dev/null; check "over threshold 16 min: one alert note" "$(notes alert)" "1"
check "the alert also reaches the telemetry outbox (outbox)" "$(events alert)" "1"
at 26 50 >/dev/null; check "still over: no second alert" "$(notes alert)" "1"
at 31 3 >/dev/null;  check "one low sample does not clear" "$(notes cleared)" "0"
at 36 40 >/dev/null; check "a spike back above resets the low counter, no new alert yet" "$(notes alert)" "1"
at 41 3 >/dev/null;  at 46 3 >/dev/null; check "two low samples clear the episode" "$(notes cleared)" "1"
at 51 40 >/dev/null; at 55 40 >/dev/null; check "new episode restarts the clock (no alert yet)" "$(notes alert)" "1"
at 70 40 >/dev/null; check "new episode alerts after 15 min" "$(notes alert)" "2"

# blind monitor: budget too low / call failing for 30+ minutes -> one BLIND alert
B=$((T0 + 600 * 60))
STUB_COUNT=3 CM_NOW=$B "$SCRIPT" >/dev/null
STUB_BUDGET=5 CM_NOW=$((B + 10 * 60)) "$SCRIPT" >/dev/null; check "10 min blind: no blind alert" "$(notes blind)" "0"
STUB_BUDGET=5 CM_NOW=$((B + 35 * 60)) "$SCRIPT" >/dev/null; check "35 min blind: one blind alert" "$(notes blind)" "1"
STUB_FAIL=1 CM_NOW=$((B + 40 * 60)) "$SCRIPT" >/dev/null; check "no second blind alert in the same episode" "$(notes blind)" "1"
check "all three note kinds match the single glob the tick reads" "$(find "$CM_HOME/inbox" -name "ci-queue-alert-*.md" | wc -l | tr -d ' ')" "$(( $(notes alert) + $(notes cleared) + $(notes blind) ))"
check "blind alert reaches the telemetry outbox" "$(events blind)" "1"
STUB_COUNT=3 CM_NOW=$((B + 45 * 60)) "$SCRIPT" >/dev/null; STUB_BUDGET=5 CM_NOW=$((B + 120 * 60)) "$SCRIPT" >/dev/null
check "after a good sample a new blind episode can alert again" "$(notes blind)" "2"

# state robustness
printf 'not json at all' > "$CM_HOME/cache/ci-queue.json"
STUB_COUNT=40 CM_NOW=$((T0 + 5000 * 60)) "$SCRIPT" >/dev/null; check "garbage state reads as a fresh start" "$(jq -r .alerted "$CM_HOME/cache/ci-queue.json")" "false"
: > "$CM_HOME/cache/ci-queue.json"
STUB_COUNT=40 CM_NOW=$((T0 + 5001 * 60)) "$SCRIPT" >/dev/null; check "empty state file reads as a fresh start" "$(jq -r .since "$CM_HOME/cache/ci-queue.json")" "$((T0 + 5001 * 60))"
check "no leftover temp state files" "$(find "$CM_HOME/cache" -name '*.tmp.*' | wc -l | tr -d ' ')" "0"
CM_QUEUE_THRESHOLD=abc "$SCRIPT" >/dev/null 2>&1; check "non-numeric threshold is a usage error" "$?" "2"

# dry-run from an over-threshold, long-running state changes nothing
printf '{"since":%s,"alerted":false,"low":0,"last_ok":%s}' "$((T0 - 100000))" "$T0" > "$CM_HOME/cache/ci-queue.json"
before_state="$(cat "$CM_HOME/cache/ci-queue.json")"; before_notes="$(find "$CM_HOME/inbox" -type f | wc -l | tr -d ' ')"; before_out="$(wc -l < "$CM_HOME/outbox.jsonl")"
STUB_COUNT=99 CM_NOW=$((T0 + 30)) "$SCRIPT" --dry-run >/dev/null
check "dry-run writes no alert note even when an alert is due" "$(find "$CM_HOME/inbox" -type f | wc -l | tr -d ' ')" "$before_notes"
check "dry-run leaves the state file alone" "$(cat "$CM_HOME/cache/ci-queue.json")" "$before_state"
check "dry-run emits no mission-control event" "$(wc -l < "$CM_HOME/outbox.jsonl")" "$before_out"
exit $fail
