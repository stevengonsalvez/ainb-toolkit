#!/usr/bin/env bash
# tick-emit.sh: behaviour tests for the per-tick mission-control emits.
# Runs the real mc-emit.sh; curl is a PATH shim answering with $STUB/code.
# CM_HOME, HOME and TMPDIR live in a mktemp dir. No real network.
#
#   scripts/test/tick-emit.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../tick-emit.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-tick-emit.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
STUB="$ROOT/stub"
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/tmp" "$STUB"
unset MC_TENANT_ID MC_PROJECT_ID MC_BASE_URL MC_QUIET MC_NO_FLUSH MC_FLUSH_BATCH MC_FLUSH_SECS MC_OUTBOX_MAX CM_INSTALLED_EMIT CM_MC_EMIT
export HOME="$ROOT/home" TMPDIR="$ROOT/tmp" CM_HOME="$ROOT/cm" STUB_DIR="$STUB"
export MC_BASE_URL="http://mc.stub.invalid" MC_TOKEN_FILE="$ROOT/token" PATH="$ROOT/bin:$PATH"
export CM_AGENT_ID="host-a:concertmaster" CM_WORKSPACE="/w/concertmaster"
printf '{}\n' > "$ROOT/config.yaml"; export CM_CONFIG="$ROOT/config.yaml"   # no host or skill config
TOKEN="tok-$$-secret-value"
printf '%s\n' "$TOKEN" > "$MC_TOKEN_FILE"

cat > "$ROOT/bin/curl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.args"
cat >> "$STUB_DIR/bodies.jsonl"; echo >> "$STUB_DIR/bodies.jsonl"
# $STUB_DIR/code.upsert set: the code for /api/fleet/upsert only.
case "$*" in *"/api/fleet/upsert"*) [ -f "$STUB_DIR/code.upsert" ] && { cat "$STUB_DIR/code.upsert"; exit 0; } ;; esac
printf '%s' "$(cat "$STUB_DIR/code" 2>/dev/null || echo 200)"
S
chmod +x "$ROOT/bin/curl"

PASS=0; FAIL=0
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi
}
reset() { rm -rf -- "${CM_HOME:?}" "${STUB:?}"/*; mkdir -p "$CM_HOME"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
calls() { lines "$STUB/curl.args"; }
OUTBOX() { echo "$CM_HOME/outbox.jsonl"; }
DEADF() { echo "$CM_HOME/outbox.dead.jsonl"; }
tick() { "$SCRIPT" "$@" > "$STUB/out" 2>&1; echo "rc=$?"; }

CLS="$ROOT/classify.json"
cat > "$CLS" <<'J'
{"schema":"concertmaster.classify/v1","summary":{"running":2,"stuck":1,"host-offline":1},
 "items":[{"host":"local","class":"running"},{"host":"local","class":"running"},
          {"host":"host-b","class":"stuck"},{"host":"host-c","class":"host-offline"}]}
J

# ---- tenant unset: tick succeeds, both lines stay queued, nothing sent ---------
reset
check "no tenant: tick exits 0" "$(tick --classify "$CLS" --extra '{"unlinkedPrs":3}')" "rc=0"
check "no tenant: curl never called" "$(calls)" "0"
check "no tenant: two lines queued" "$(lines "$(OUTBOX)")" "2"
check "no tenant: first line is the tick event" \
  "$(head -n 1 "$(OUTBOX)" | jq -r '"\(.endpoint) \(.body.type)"')" "/api/events concertmaster.tick"
check "no tenant: second line is the concertmaster upsert" \
  "$(sed -n 2p "$(OUTBOX)" | jq -r '"\(.endpoint) \(.body.agentId) \(.body.name) \(.body.status) \(.body.workspace)"')" \
  "/api/fleet/upsert host-a:concertmaster concertmaster active /w/concertmaster"
check "summary message from classify" "$(head -n 1 "$(OUTBOX)" | jq -r '.body.message')" \
  "tick: 4 items; host-offline=1 running=2 stuck=1; offline: host-c"
check "summary carries counts and --extra" \
  "$(head -n 1 "$(OUTBOX)" | jq -c '.body.metadata.fleet | [.items, .counts.running, .unlinkedPrs, .offlineHosts]')" '[4,2,3,["host-c"]]'
check "no tenant: one warning line, own lines queued" "$(grep -c 'tick-emit: queued=2 dead=0 of this tick' "$STUB/out") $(grep -c . "$STUB/out")" "1 1"
"$SCRIPT" --classify "$CLS" >/dev/null 2>&1
check "second tick: one more upsert (one per tick)" \
  "$(jq -r 'select(.endpoint == "/api/fleet/upsert") | .body.agentId' "$(OUTBOX)" | sort | uniq -c | tr -s ' ')" " 2 host-a:concertmaster"
check "second tick: two tick events" "$(jq -r 'select(.body.type == "concertmaster.tick") | 1' "$(OUTBOX)" | grep -c .)" "2"

# ---- tenant set, mission-control answers 400: dead-lettered, tick still green ---
reset; export MC_TENANT_ID="t-acme"; echo 400 > "$STUB/code"
check "400: tick exits 0" "$(tick --classify "$CLS")" "rc=0"
check "400: one flush, both lines posted" "$(calls)" "2"
check "400: outbox empty" "$(lines "$(OUTBOX)")" "0"
check "400: both lines dead-lettered with their types" \
  "$(jq -r '"\(.deadCode) \(.endpoint) \(.body.type // .body.agentId)"' "$(DEADF)" | tr '\n' '|')" \
  "400 /api/events concertmaster.tick|400 /api/fleet/upsert host-a:concertmaster|"
check "400: warning counts the dead lines, says requeue" "$(grep -c 'dead=2 .*--requeue-dead' "$STUB/out")" "1"
check "inherited MC_NO_FLUSH=1: last emit still flushes" \
  "$(reset; echo 400 > "$STUB/code"; MC_NO_FLUSH=1 "$SCRIPT" --classify "$CLS" >/dev/null 2>&1; calls)" "2"
check "400: tick posted before the upsert" "$(sed 's/.* //' "$STUB/curl.args" | tr '\n' ' ')" \
  "http://mc.stub.invalid/api/events http://mc.stub.invalid/api/fleet/upsert "

# ---- dead file already at the cap: new dead letters still counted ----------
reset; echo 400 > "$STUB/code"; for _ in 1 2 3; do echo '{"endpoint":"/api/events","body":{},"queuedAt":1,"deadCode":400}'; done > "$(DEADF)"
MC_OUTBOX_MAX=3 "$SCRIPT" --classify "$CLS" > "$STUB/out" 2>&1
check "capped dead file: still 3 lines" "$(lines "$(DEADF)")" "3"
check "capped dead file: warning counts 2 new dead letters" "$(grep -c 'dead=2' "$STUB/out")" "1"

# ---- backlog: own lines judged, not the shared outbox -----------------------------
reset; echo 200 > "$STUB/code"
for n in $(seq 1 15); do echo "{\"endpoint\":\"/api/events\",\"body\":{\"type\":\"session.stop\",\"n\":$n},\"queuedAt\":$n}"; done > "$(OUTBOX)"
echo '{"endpoint":"/api/events","body":{"type":"old"},"queuedAt":9999999999999,"deadCode":404}' > "$(DEADF)"
"$SCRIPT" --classify "$CLS" > "$STUB/out" 2>&1
check "backlog: 10 oldest sent, own 2 still queued, foreign dead line not counted" \
  "$(calls) $(grep -c 'queued=2 dead=0 .*backlog ahead' "$STUB/out")" "10 1"

# ---- 2xx: one-line success ------------------------------------------------------
reset; echo 200 > "$STUB/code"
check "2xx: tick exits 0" "$(tick --classify "$CLS")" "rc=0"
check "2xx: success line" "$(cat "$STUB/out")" "tick-emit: tick + fleet upsert sent (active)"
check "2xx: upsert confirmed in fleet.sent.json" "$(jq -r 'has("host-a:concertmaster")' "$CM_HOME/fleet.sent.json")" "true"
reset; echo 200 > "$STUB/code"; echo '{"host-a:concertmaster": 99999999999999}' > "$CM_HOME/fleet.sent.json"
"$SCRIPT" --classify "$CLS" > "$STUB/out" 2>&1
check "upsert dropped by the fleet-order guard: not claimed as sent" "$(grep -c 'upsert is not confirmed' "$STUB/out")" "1"
reset; echo '{"generatedAt":"2026-01-01T00:00:00Z","items":[{"host":"local","class":"running"}]}' | "$SCRIPT" >/dev/null 2>&1
check "old discover: discoverAt carried, discoverStale true" \
  "$(head -n 1 "$STUB/bodies.jsonl" | jq -c '.metadata.fleet | [.discoverAt, .discoverStale]')" '["2026-01-01T00:00:00Z",true]'
check "stdin that never closes: tick does not hang" \
  "$( (sleep 30 | CM_HOME="$ROOT/cm-hang" timeout 20 "$SCRIPT" >/dev/null 2>&1; echo "rc=$?") )" "rc=0"

# ---- 5xx keeps the lines queued for later -----------------------------------------
reset; echo 503 > "$STUB/code"
check "503: tick exits 0" "$(tick --classify "$CLS")" "rc=0"
check "503: both lines kept queued" "$(lines "$(OUTBOX)") $(lines "$(DEADF)")" "2 0"
check "503: warning says retried, not tenant" "$(grep -c 'retried next tick' "$STUB/out")" "1"

# ---- unlinked count from unlinked-prs.json, bad --extra warned ---------------------
reset; unset MC_TENANT_ID
echo '{"stale":true,"prs":[{"number":1},{"number":2}]}' > "$CM_HOME/unlinked-prs.json"
"$SCRIPT" --classify "$CLS" --extra '<n>' > "$STUB/out" 2>&1
check "unlinkedPrs read from unlinked-prs.json" \
  "$(head -n 1 "$(OUTBOX)" | jq -c '.body.metadata.fleet | [.unlinkedPrs, .unlinkedStale]')" '[2,true]'
check "non-object --extra: warned" "$(grep -c 'extra is not a JSON object' "$STUB/out")" "1"

# ---- bad input, idle fleet, stdin --------------------------------------------------
reset; unset MC_TENANT_ID
check "garbage classify: exit 0" "$(echo 'not json' | "$SCRIPT" >/dev/null 2>&1; echo "rc=$?")" "rc=0"
check "garbage classify: bare tick and error upsert still queued" \
  "$(jq -r '.body.message // .body.status' "$(OUTBOX)" | tr '\n' '|')" "tick: classify unavailable|error|"
reset
echo '{"items":[{"host":"local","class":"standing-idle"}]}' | "$SCRIPT" >/dev/null 2>&1
check "stdin input, no live work: status idle" "$(jq -r 'select(.endpoint == "/api/fleet/upsert") | .body.status' "$(OUTBOX)")" "idle"
check "missing emitter: exit 0" "$(CM_MC_EMIT="$ROOT/nope" "$SCRIPT" --classify "$CLS" >/dev/null 2>&1; echo "rc=$?")" "rc=0"
check "dangling flag: exit 0" "$("$SCRIPT" --classify "$CLS" --task >/dev/null 2>&1; echo "rc=$?")" "rc=0"

# ---- secrets never printed ----------------------------------------------------------
reset; export MC_TENANT_ID="<paste-tenant-here>"
tick --classify "$CLS" >/dev/null
check "placeholder tenant: not echoed" "$(grep -c 'paste-tenant-here' "$STUB/out")" "0"
check "placeholder tenant: says placeholder" "$(grep -c 'is a placeholder' "$STUB/out")" "1"
export MC_TENANT_ID="t-acme-secret"; echo 400 > "$STUB/code"
tick --classify "$CLS" >/dev/null
check "tenant never printed" "$(grep -c 't-acme-secret' "$STUB/out")" "0"
check "token never printed" "$(grep -c -- "$TOKEN" "$STUB/out")" "0"
check "token never on curl argv" "$(grep -c -- "$TOKEN" "$STUB/curl.args")" "0"

# ---- the SKILL.md step 5 line itself, run as the agent's shell would ---------
# (CM_HOME unset: the line must still find the discover file and classify it)
reset; unset MC_TENANT_ID
# shellcheck disable=SC2016  # backticks are literal markdown, not expansion
LINE="$(grep -o '`scripts/classify.sh < [^`]*| scripts/tick-emit.sh`' "$HERE/../../SKILL.md" | head -n 1 | tr -d '`')"
H2="$ROOT/home2"; mkdir -p "$H2/.concertmaster"
jq -n '{generatedAtMs: 0, generatedAt: "2026-01-15T19:00:00Z", hosts: [{name: "local", reachable: true}], worktrees: []}' \
  > "$H2/.concertmaster/last-discover.json"
( cd "$HERE/../.." && env -u CM_HOME HOME="$H2" CM_AGENT_ID=host-a:concertmaster bash -c "$LINE" >/dev/null 2>&1 )
check "step 5 line found in SKILL.md" "$([ -n "$LINE" ] && echo yes)" "yes"
check "step 5 line with CM_HOME unset: classify ran, not 'classify unavailable'" \
  "$(head -n 1 "$H2/.concertmaster/outbox.jsonl" 2>/dev/null | jq -r '.body.message | startswith("tick: ")
     and (contains("classify unavailable") | not)')" "true"

# ---- fleet upsert refused by design -----------------------------------
# Project-bound token: mc-emit skips the upsert; the tick is still flushed and sent.
reset; export MC_TENANT_ID="t-acme" MC_PROJECT_ID="p_acme"; echo 200 > "$STUB/code"
check "project id: tick exits 0" "$(tick --classify "$CLS")" "rc=0"
check "project id: only the tick event posted, with projectId" \
  "$(sed 's/.* //' "$STUB/curl.args" | tr '\n' ' ')$(jq -r '"\(.type) \(.projectId)"' "$STUB/bodies.jsonl")" \
  "http://mc.stub.invalid/api/events concertmaster.tick p_acme"
check "project id: outbox and dead file empty, no upsert queued" "$(lines "$(OUTBOX)") $(lines "$(DEADF)")" "0 0"
check "project id: skip recorded for this agent" "$(jq -r '.agentId' "$CM_HOME/fleet.skipped")" "host-a:concertmaster"
check "project id: one warning line, says skipped" \
  "$(grep -c . "$STUB/out") $(grep -c 'tick sent; fleet upsert skipped' "$STUB/out")" "1 1"
cat > "$ROOT/emit-race" <<R
#!/usr/bin/env bash
# mc-emit, then a worker hook's skip lands in the one fleet.skipped slot.
"$HERE/../mc-emit.sh" "\$@"; rc=\$?
[ "\$1" != --fleet-upsert ] || echo "{\"at\":\$(date +%s)000,\"agentId\":\"w-other\"}" > "\$CM_HOME/fleet.skipped"
exit \$rc
R
chmod +x "$ROOT/emit-race"
reset; CM_MC_EMIT="$ROOT/emit-race" "$SCRIPT" --classify "$CLS" > "$STUB/out" 2>&1
check "project id, a worker hook overwrote fleet.skipped: tick still flushed" \
  "$(calls) $(grep -c 'fleet upsert skipped' "$STUB/out")" "1 1"
check "project id, inherited MC_NO_FLUSH=1: tick still flushed" \
  "$(reset; MC_NO_FLUSH=1 "$SCRIPT" --classify "$CLS" >/dev/null 2>&1; calls)" "1"
reset; echo 503 > "$STUB/code"
"$SCRIPT" --classify "$CLS" > "$STUB/out" 2>&1
check "project id, endpoint down: tick kept queued, warns retried" \
  "$(lines "$(OUTBOX)") $(grep -c 'queued=1 dead=0 .*retried next tick' "$STUB/out")" "1 1"
unset MC_PROJECT_ID
# Shared token, no project id: the sink answers 403 on the upsert route only.
reset; echo 200 > "$STUB/code"; echo 403 > "$STUB/code.upsert"
check "403 upsert: tick exits 0" "$(tick --classify "$CLS")" "rc=0"
check "403 upsert: tick sent, upsert dead-lettered with 403" \
  "$(lines "$(OUTBOX)") $(jq -r '"\(.deadCode) \(.endpoint)"' "$(DEADF)")" "0 403 /api/fleet/upsert"
check "403 upsert: one warning line, says refused" \
  "$(grep -c . "$STUB/out") $(grep -c 'fleet upsert refused (403' "$STUB/out")" "1 1"
"$SCRIPT" --classify "$CLS" > "$STUB/out" 2>&1
check "403 upsert: next tick sends the tick only, no new dead line (no retry storm)" "$(calls) $(lines "$(DEADF)")" "3 1"
check "403 upsert: next tick says the upsert is held, one line" \
  "$(grep -c . "$STUB/out") $(grep -c 'fleet upsert not sent (refused with 403' "$STUB/out")" "1 1"
jq -c '.queuedAt = 1' "$(DEADF)" > "$ROOT/dead.old" && mv "$ROOT/dead.old" "$(DEADF)"
"$SCRIPT" --classify "$CLS" >/dev/null 2>&1
check "403 upsert older than 24h: the upsert is tried again" "$(calls) $(lines "$(DEADF)")" "5 2"
rm -f "$STUB/code.upsert"
check "refusal output never shows the token or tenant" \
  "$(grep -c -e "$TOKEN" -e 't-acme' "$STUB/out")" "0"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
