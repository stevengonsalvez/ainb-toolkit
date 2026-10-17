#!/usr/bin/env bash
# mc-emit.sh: behaviour tests for the telemetry emitter. curl is a PATH
# shim that records its argv and the body it was sent and answers with the
# code in $STUB/code; CM_HOME, HOME and TMPDIR all live in a mktemp dir.
# Touches nothing outside it. No real network, no real ~/.concertmaster.
#
#   scripts/test/mc-emit.sh         # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EMIT="$HERE/../mc-emit.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-mc-emit.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
STUB="$ROOT/stub"
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/tmp" "$STUB"
unset MC_TENANT_ID MC_PROJECT_ID MC_BASE_URL MC_QUIET MC_FLUSH_BATCH MC_FLUSH_SECS MC_OUTBOX_MAX CM_INSTALLED_EMIT
export HOME="$ROOT/home" TMPDIR="$ROOT/tmp" CM_HOME="$ROOT/cm"
export MC_BASE_URL="http://mc.stub.invalid" MC_TOKEN_FILE="$ROOT/token" STUB_DIR="$STUB"
export PATH="$ROOT/bin:$PATH"
TOKEN="tok-$$-secret-value"
printf '%s\n' "$TOKEN" > "$MC_TOKEN_FILE"

# ---- curl shim ---------------------------------------------------------------
cat > "$ROOT/bin/curl" <<'S'
#!/usr/bin/env bash
# Records argv, the body (stdin) and the header file it was pointed at.
# $STUB_DIR/exit set: behave like a real curl timeout (prints 000, exits 28).
printf '%s\n' "$*" >> "$STUB_DIR/curl.args"
cat >> "$STUB_DIR/bodies.jsonl"; echo >> "$STUB_DIR/bodies.jsonl"
prev=""
for a in "$@"; do
  [ "$prev" = "-H" ] && case "$a" in @*) cat "${a#@}" >> "$STUB_DIR/headers.txt" ;; esac
  prev="$a"
done
[ -f "$STUB_DIR/exit" ] && { printf '000'; exit "$(cat "$STUB_DIR/exit")"; }
# $STUB_DIR/inject set: a hook queues a line while this flush runs.
[ -f "$STUB_DIR/inject" ] && { cat "$STUB_DIR/inject" >> "$CM_HOME/outbox.jsonl"; rm -f "$STUB_DIR/inject"; }
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
emit() { "$EMIT" "$@" 2>> "$STUB/stderr"; echo "rc=$?"; }

# ---- no tenant: nothing sent, every line stays queued --------------------------
reset
check "no tenant: event call exits 0" "$(emit worker.done "w1 done" '{"pr":1}')" "rc=0"
check "no tenant: upsert call exits 0" "$(emit --fleet-upsert a1 n1 active task /w)" "rc=0"
check "no tenant: both lines queued" "$(lines "$CM_HOME/outbox.jsonl")" "2"
check "no tenant: curl never called" "$(calls)" "0"
check "no tenant: nothing dead-lettered" "$(lines "$CM_HOME/outbox.dead.jsonl")" "0"
check "no tenant: queued body carries tenantId null" \
  "$(jq -r '.body.tenantId' "$CM_HOME/outbox.jsonl" | sort -u)" "null"
check "no tenant: warns that nothing was sent" "$(grep -c 'MC_TENANT_ID unset: nothing sent' "$STUB/stderr")" "2"
check "no tenant: --flush also sends nothing" "$(emit --flush; calls)" "rc=0
0"

# ---- no base URL: nothing sent even with a tenant and token --------------------
reset
check "no base URL: call exits 0" "$(MC_BASE_URL="" MC_TENANT_ID="t-test" emit worker.done "w1 done")" "rc=0"
check "no base URL: line queued" "$(lines "$CM_HOME/outbox.jsonl")" "1"
check "no base URL: curl never called" "$(calls)" "0"
check "no base URL: warns that nothing was sent" "$(grep -c 'no base URL' "$STUB/stderr")" "1"
reset
emit worker.done "w1 done" >/dev/null; emit --fleet-upsert a1 n1 active task /w >/dev/null

# ---- tenant set: 2xx drops the line, tenant filled in --------------------------
export MC_TENANT_ID="t-test"
echo 200 > "$STUB/code"
check "tenant: flush exits 0" "$(emit --flush)" "rc=0"
check "tenant: both queued lines sent" "$(calls)" "2"
check "tenant: 2xx emptied the outbox" "$(lines "$CM_HOME/outbox.jsonl")" "0"
check "tenant: null tenant filled in on send" "$(jq -r '.tenantId' "$STUB/bodies.jsonl" | sort -u)" "t-test"
check "tenant: endpoints posted" "$(sed 's/.* //' "$STUB/curl.args" | sort | tr '\n' ' ')" \
  "http://mc.stub.invalid/api/events http://mc.stub.invalid/api/fleet/upsert "

# ---- token never on argv, header file removed ----------------------------------
check "token: never in curl argv" "$(grep -c -- "$TOKEN" "$STUB/curl.args")" "0"
check "token: sent through the header file" "$(grep -c "^X-MC-Token: $TOKEN$" "$STUB/headers.txt")" "2"
check "token: header file removed after flush" "$(find "$TMPDIR" -name 'mc-hdr.*' | wc -l | tr -d ' ')" "0"
check "token: never in any queued or dead line" "$(cat "$CM_HOME"/outbox*.jsonl 2>/dev/null | grep -c -- "$TOKEN")" "0"

# ---- tenant from mc.env (parsed, not sourced) ----------------------------------
reset; unset MC_TENANT_ID
printf 'MC_TENANT_ID="t-file"\n' > "$CM_HOME/mc.env"
emit worker.done x >/dev/null
check "mc.env tenant: line sent" "$(calls)" "1"
check "mc.env tenant: body carries it" "$(jq -r '.tenantId' "$STUB/bodies.jsonl")" "t-file"
reset; printf 'export MC_TENANT_ID= t-crlf \r\n' > "$CM_HOME/mc.env"
emit worker.done x >/dev/null
check "mc.env tenant: export prefix, CR and spaces stripped" "$(jq -r '.tenantId' "$STUB/bodies.jsonl")" "t-crlf"
reset; printf "MC_TENANT_ID='<tenant id from Open config>'\n" > "$CM_HOME/mc.env"
emit worker.done x >/dev/null
check "mc.env placeholder tenant: treated as unset, nothing sent" "$(calls) $(lines "$CM_HOME/outbox.jsonl")" "0 1"
check "mc.env placeholder tenant: warns" "$(grep -c 'is not a tenant id' "$STUB/stderr")" "1"
check "mc.env placeholder tenant: marker file for quiet hooks" "$([ -f "$CM_HOME/mc-emit.tenant-rejected" ] && echo yes)" "yes"
reset; MC_TENANT_ID="t.test:1|a" MC_QUIET=1 "$EMIT" worker.done x
check "tenant with . : | accepted and sent" "$(jq -r '.tenantId' "$STUB/bodies.jsonl")" "t.test:1|a"
check "accepted tenant: no marker file" "$([ -f "$CM_HOME/mc-emit.tenant-rejected" ] && echo yes || echo no)" "no"
export MC_TENANT_ID="t-test"

# ---- cap: no-tenant outbox is bounded, drops are recorded ------------------------
reset; unset MC_TENANT_ID
for i in 1 2 3 4 5; do MC_OUTBOX_MAX=3 MC_QUIET=1 "$EMIT" worker.done "n$i"; done
check "cap: no-tenant outbox holds MC_OUTBOX_MAX lines" "$(lines "$CM_HOME/outbox.jsonl")" "3"
check "cap: the newest lines are kept" "$(jq -r '.body.message' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')" "n3 n4 n5 "
check "cap: drops recorded even with MC_QUIET=1" "$(jq -s 'map(.dropped) | add' "$CM_HOME/outbox.dropped")" "2"

# concurrent emits while the cap trims: every line is either queued or counted dropped
reset
for i in $(seq 1 60); do MC_OUTBOX_MAX=20 MC_QUIET=1 "$EMIT" worker.done "c$i" & done; wait
check "cap under 60 concurrent emits: queued + dropped == 60" \
  "$(( $(lines "$CM_HOME/outbox.jsonl") + $(jq -s 'map(.dropped) | add // 0' "$CM_HOME/outbox.dropped" 2>/dev/null || echo 0) ))" "60"
check "cap under concurrent emits: never over the cap" "$([ "$(lines "$CM_HOME/outbox.jsonl")" -le 20 ] && echo ok)" "ok"
check "cap: no write lock left behind" "$([ -d "$CM_HOME/outbox.wlock" ] && echo held || echo free)" "free"
export MC_TENANT_ID="t-test"

# ---- network and auth failures keep lines and stop the batch -----------------
reset; unset MC_TENANT_ID; emit worker.done a >/dev/null; emit worker.done b >/dev/null; export MC_TENANT_ID="t-test"
echo 28 > "$STUB/exit"
check "curl timeout (exit 28): exits 0" "$(emit --flush)" "rc=0"
check "curl timeout: one attempt, then the batch stops" "$(calls)" "1"
check "curl timeout: both lines kept, none dead" "$(lines "$CM_HOME/outbox.jsonl") $(lines "$CM_HOME/outbox.dead.jsonl")" "2 0"
rm -f "$STUB/exit" "$STUB/curl.args"; echo 401 > "$STUB/code"
emit --flush >/dev/null
check "401: one attempt, then the batch stops" "$(calls)" "1"
check "401: both lines kept, none dead" "$(lines "$CM_HOME/outbox.jsonl") $(lines "$CM_HOME/outbox.dead.jsonl")" "2 0"

rm -f "$STUB/curl.args"; echo 429 > "$STUB/code"
emit --flush >/dev/null
check "429: one attempt, then the batch stops" "$(calls)" "1"

# ---- order: lines a flush could not send go back in front ----------------------
reset; echo 200 > "$STUB/code"
for i in 1 2 3; do echo "{\"endpoint\":\"/api/events\",\"body\":{\"tenantId\":\"t-test\",\"type\":\"o$i\"},\"queuedAt\":$i}"; done > "$CM_HOME/outbox.jsonl"
echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"new"},"queuedAt":9}' > "$STUB/inject"
MC_FLUSH_BATCH=1 "$EMIT" --flush 2>/dev/null
check "order: unsent backlog stays ahead of a line queued during the flush" \
  "$(jq -r '.body.type' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')" "o2 o3 new "

# ---- fleet order: never send an upsert older than one already accepted ---------
reset; echo 200 > "$STUB/code"
echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":"t-test","agentId":"a","status":"idle"},"queuedAt":5}' > "$CM_HOME/outbox.jsonl"
emit --flush >/dev/null
check "fleet order: accepted upsert recorded" "$(jq -r '.a' "$CM_HOME/fleet.sent.json")" "5"
echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":"t-test","agentId":"a","status":"active"},"queuedAt":3}' > "$CM_HOME/outbox.jsonl"
rm -f "$STUB/curl.args"; emit --flush >/dev/null
check "fleet order: older upsert never sent, not queued, not dead" "$(calls) $(lines "$CM_HOME/outbox.jsonl") $(lines "$CM_HOME/outbox.dead.jsonl")" "0 0 0"
echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":null,"agentId":"a","status":"active"},"queuedAt":4,"deadCode":400}' > "$CM_HOME/outbox.dead.jsonl"
OUT5="$("$EMIT" --requeue-dead 2>/dev/null)"
check "fleet order: requeue skips an upsert overtaken by an accepted one" \
  "$(printf '%s\n' "$OUT5" | tail -n 1) $(printf '%s\n' "$OUT5" | grep -c 'dropped 1 superseded') $(lines "$CM_HOME/outbox.dead.jsonl") $(lines "$CM_HOME/outbox.jsonl")" \
  "requeued 0 line(s) 1 0 0"

# ---- MC_NO_FLUSH, unknown flags, orphans, a broken write lock ----------------------
reset; rm -f "$STUB/curl.args"
MC_NO_FLUSH=1 "$EMIT" --issue-state 1 open 2>/dev/null
check "MC_NO_FLUSH=1: queued, not flushed" "$(lines "$CM_HOME/outbox.jsonl") $(calls)" "1 0"
"$EMIT" --requeue_dead 2>/dev/null
check "unknown --flag: nothing queued" "$(lines "$CM_HOME/outbox.jsonl")" "1"
reset
echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"orphan"},"queuedAt":1}' > "$CM_HOME/outbox.flushing.999999"
emit worker.done fresh >/dev/null
check "orphaned flushing file from a dead pid: adopted and sent" "$(jq -r '.type' "$STUB/bodies.jsonl" | paste -sd' ' -) $(find "$CM_HOME" -name 'outbox.flushing.*' | wc -l | tr -d ' ')" "orphan worker.done 0"
reset; : > "$CM_HOME/outbox.wlock"; touch -t 202001010000 "$CM_HOME/outbox.wlock"
unset MC_TENANT_ID; T0=$(date +%s); MC_QUIET=1 "$EMIT" worker.done w; T1=$(date +%s); export MC_TENANT_ID="t-test"
check "write lock that cannot be stolen: gives up in seconds, line still queued" "$([ $((T1 - T0)) -le 10 ] && echo fast) $(lines "$CM_HOME/outbox.jsonl")" "fast 1"

# ---- installed copy older than this one: warned --------------------------------
reset; echo 200 > "$STUB/code"; mkdir -p "$HOME/.concertmaster/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.concertmaster/bin/mc-emit.sh"
emit worker.done x >/dev/null
check "stale installed copy: warned" "$(grep -c 'older than' "$STUB/stderr")" "1"
check "stale installed copy: this copy still sends" "$(calls)" "1"
check "--version prints MC_EMIT_VERSION" "$("$EMIT" --version)" "3"
rm -rf -- "${HOME:?}/.concertmaster"

# ---- 400 dead-letters with deadCode; 5xx keeps --------------------------------
reset; echo 400 > "$STUB/code"
emit worker.done bad >/dev/null
check "400: line dead-lettered" "$(lines "$CM_HOME/outbox.dead.jsonl")" "1"
check "400: deadCode recorded" "$(jq -r '.deadCode' "$CM_HOME/outbox.dead.jsonl")" "400"
check "400: outbox empty" "$(lines "$CM_HOME/outbox.jsonl")" "0"
reset; echo 400 > "$STUB/code"; unset MC_TENANT_ID; emit worker.done queued-unset >/dev/null; export MC_TENANT_ID="t-test"
emit --flush >/dev/null
check "400 after tenant fill-in: dead record carries the sent tenant" "$(jq -r '.body.tenantId' "$CM_HOME/outbox.dead.jsonl")" "t-test"
check "400 after tenant fill-in: never a requeue candidate" "$("$EMIT" --requeue-dead 2>/dev/null | tail -n 1)" "requeued 0 line(s)"
reset; echo 200 > "$STUB/code"
echo '{"endpoint":"/api/events","body":{"tenantId":"other","type":"x"},"queuedAt":1}' > "$CM_HOME/outbox.jsonl"
emit --flush >/dev/null
check "explicit other tenant: left alone on send" "$(jq -r '.tenantId' "$STUB/bodies.jsonl")" "other"
reset
echo '{"endpoint":"@evil.example/x","body":{"tenantId":"t-test","type":"x"},"queuedAt":1}' > "$CM_HOME/outbox.jsonl"
emit --flush >/dev/null
check "unknown endpoint: never posted" "$(calls)" "0"
check "unknown endpoint: dead-lettered" "$(lines "$CM_HOME/outbox.dead.jsonl")" "1"
reset; echo 503 > "$STUB/code"
emit worker.done later >/dev/null
check "503: line kept queued" "$(lines "$CM_HOME/outbox.jsonl")" "1"
check "503: nothing dead-lettered" "$(lines "$CM_HOME/outbox.dead.jsonl")" "0"

# ---- provisional emitters -----------------------------------------------------
reset; unset MC_TENANT_ID
emit --tick '{"summary":"3 live, 1 stuck","live":3,"stuck":1}' >/dev/null
emit --issue-state 44 in-review '#90' >/dev/null
emit --issue-state 45 open >/dev/null
emit --issue-state nope open >/dev/null
check "emitters: three lines queued, bad issue refused" "$(lines "$CM_HOME/outbox.jsonl")" "3"
check "tick: type from TYPE_TICK" "$(jq -r 'select(.body.type == "concertmaster.tick") | .endpoint' "$CM_HOME/outbox.jsonl")" "/api/events"
check "tick: message and fleet summary" \
  "$(jq -c 'select(.body.type == "concertmaster.tick") | [.body.message, .body.metadata.fleet.live, .body.metadata.source]' "$CM_HOME/outbox.jsonl")" \
  '["3 live, 1 stuck",3,"concertmaster"]'
check "issue-state: type, message and metadata" \
  "$(jq -c 'select(.body.type == "issue.state") | [.endpoint, .body.message, .body.metadata.issue, .body.metadata.state, .body.metadata.pr]' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')" \
  '["/api/events","#44 in-review",44,"in-review",90] ["/api/events","#45 open",45,"open",null] '
export MC_TENANT_ID="t-test"

# ---- --requeue-dead ------------------------------------------------------------
DEADF="$CM_HOME/outbox.dead.jsonl"
seed_dead() {
  reset
  {
    echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"a"},"queuedAt":1,"deadCode":400}'
    echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":null,"agentId":"b"},"queuedAt":2,"deadCode":400}'
    echo '{"endpoint":"/api/events","body":{"tenantId":"other","type":"c"},"queuedAt":3,"deadCode":400}'
    echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"d"},"queuedAt":4,"deadCode":404}'
    echo 'not json at all'
  } > "$DEADF"
  echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"q"},"queuedAt":5}' > "$CM_HOME/outbox.jsonl"
  cp "$DEADF" "$ROOT/dead.orig"
}
seed_dead; unset MC_TENANT_ID
check "requeue, no tenant: exits 0" "$(emit --requeue-dead)" "rc=0"
check "requeue, no tenant: dead file unchanged" "$(cmp -s "$DEADF" "$ROOT/dead.orig" && echo same)" "same"
check "requeue, no tenant: outbox unchanged" "$(lines "$CM_HOME/outbox.jsonl")" "1"
check "requeue, no tenant: no backup" "$(find "$CM_HOME" -name 'outbox.dead.jsonl.bak.*' | wc -l | tr -d ' ')" "0"
check "requeue, no tenant: warns" "$(grep -c 'nothing requeued' "$STUB/stderr")" "1"
export MC_TENANT_ID="t-test"

seed_dead
OUT="$("$EMIT" --requeue-dead 2>>"$STUB/stderr")"; RC=$?
check "requeue: exits 0" "$RC" "0"
check "requeue: prints the count" "$(printf '%s\n' "$OUT" | tail -n 1)" "requeued 2 line(s)"
check "requeue: two lines added to the queued one" "$(lines "$CM_HOME/outbox.jsonl")" "3"
check "requeue: moved lines go in front, oldest first, tenant set, no deadCode" \
  "$(jq -c '[.body.tenantId, has("deadCode"), .queuedAt]' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')" \
  '["t-test",false,1] ["t-test",false,2] ["t-test",false,5] '
check "requeue: other lines stay dead, byte for byte" \
  "$(sed -n '3,5p' "$ROOT/dead.orig" | cmp -s - "$DEADF" && echo same)" "same"
BAK="$(find "$CM_HOME" -name 'outbox.dead.jsonl.bak.*')"
check "requeue: one backup, equal to the original" "$(printf '%s\n' "$BAK" | grep -c . ; cmp -s "$BAK" "$ROOT/dead.orig" && echo same)" "1
same"
check "requeue: backup path printed" "$(printf '%s\n' "$OUT" | head -n 1)" "backup: $BAK"
check "requeue: curl never called" "$(calls)" "0"
check "requeue: lock released" "$([ -d "$CM_HOME/outbox.lock" ] && echo held || echo free)" "free"

OUT2="$("$EMIT" --requeue-dead 2>>"$STUB/stderr")"
check "requeue again: idempotent count" "$OUT2" "requeued 0 line(s)"
check "requeue again: outbox unchanged" "$(lines "$CM_HOME/outbox.jsonl")" "3"
check "requeue again: dead unchanged" "$(lines "$DEADF")" "3"
check "requeue again: no second backup" "$(find "$CM_HOME" -name 'outbox.dead.jsonl.bak.*' | wc -l | tr -d ' ')" "1"

seed_dead
OUT3="$(MC_OUTBOX_MAX=2 "$EMIT" --requeue-dead 2>>"$STUB/stderr")"
check "requeue past the cap: refused" "$OUT3" "requeued 0 line(s)"
check "requeue past the cap: dead and outbox unchanged, no backup" \
  "$(cmp -s "$DEADF" "$ROOT/dead.orig" && echo same) $(lines "$CM_HOME/outbox.jsonl") $(find "$CM_HOME" -name 'outbox.dead.jsonl.bak.*' | wc -l | tr -d ' ')" "same 1 0"
check "requeue: no temp files left" "$(find "$CM_HOME" -name '*.move.*' -o -name '*.keep.*' -o -name '*.requeue.*' | wc -l | tr -d ' ')" "0"

seed_dead; mkdir "$CM_HOME/outbox.lock"
check "requeue, flush holds the lock: exits 0" "$(emit --requeue-dead)" "rc=0"
check "requeue, flush holds the lock: dead unchanged" "$(cmp -s "$DEADF" "$ROOT/dead.orig" && echo same)" "same"
check "requeue, flush holds the lock: lock left alone" "$([ -d "$CM_HOME/outbox.lock" ] && echo held)" "held"

# stale flush lock (crashed flusher, over 10 minutes old) is stolen by requeue
seed_dead; mkdir "$CM_HOME/outbox.lock"; touch -t 202001010000 "$CM_HOME/outbox.lock"
check "requeue steals a stale lock" "$("$EMIT" --requeue-dead 2>/dev/null | tail -n 1)" "requeued 2 line(s)"

# superseded fleet upserts are dropped on replay, newest per agentId kept
reset
{
  echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":null,"agentId":"a","status":"old"},"queuedAt":1,"deadCode":400}'
  echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":null,"agentId":"b","status":"old"},"queuedAt":2,"deadCode":400}'
  echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":null,"agentId":"a","status":"new"},"queuedAt":3,"deadCode":400}'
  echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"e"},"queuedAt":4,"deadCode":400}'
} > "$DEADF"
echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":"t-test","agentId":"b","status":"queued"},"queuedAt":9}' > "$CM_HOME/outbox.jsonl"
OUT4="$("$EMIT" --requeue-dead 2>>"$STUB/stderr")"
check "upsert replay: superseded ones reported" "$(printf '%s\n' "$OUT4" | grep -c 'dropped 2 superseded')" "1"
check "upsert replay: newest a, the event, then the queued b" \
  "$(jq -r '"\(.body.agentId // .body.type):\(.body.status // "-")"' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')" "a:new e:- b:queued "
check "upsert replay: dead file emptied of the picked lines" "$(lines "$DEADF")" "0"

# the cap drops the oldest, which after a requeue are the requeued lines
seed_dead; "$EMIT" --requeue-dead >/dev/null 2>&1; unset MC_TENANT_ID
for i in 1 2 3; do MC_OUTBOX_MAX=5 MC_QUIET=1 "$EMIT" worker.done "late$i"; done
check "cap after requeue: oldest (requeued) dropped first, newest kept" \
  "$(jq -r '.body.message // .body.type' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')" "q late1 late2 late3 "
export MC_TENANT_ID="t-test"

# backups are pruned to the newest 5
seed_dead; for i in 1 2 3 4 5 6 7; do : > "$CM_HOME/outbox.dead.jsonl.bak.2020010${i}T000000Z.1"; done
"$EMIT" --requeue-dead >/dev/null 2>&1
check "backups pruned to the newest 5" "$(find "$CM_HOME" -name 'outbox.dead.jsonl.bak.*' | wc -l | tr -d ' ')" "5"
check "the new backup is among them" "$(find "$CM_HOME" -name 'outbox.dead.jsonl.bak.2026*' -o -name 'outbox.dead.jsonl.bak.2027*' | wc -l | tr -d ' ')" "1"

# the dead file is bounded too
reset; for i in 1 2 3 4; do echo "{\"endpoint\":\"/api/events\",\"body\":{\"tenantId\":\"x\"},\"queuedAt\":$i,\"deadCode\":404}"; done > "$DEADF"
unset MC_TENANT_ID; MC_OUTBOX_MAX=2 MC_QUIET=1 "$EMIT" worker.done z; export MC_TENANT_ID="t-test"
check "dead file keeps its newest MC_OUTBOX_MAX lines" "$(jq -r '.queuedAt' "$DEADF" | tr '\n' ' ')" "3 4 "

# --any-tenant also takes 400 lines that carried a (wrong) tenant
reset
echo '{"endpoint":"/api/events","body":{"tenantId":"typo","type":"x"},"queuedAt":1,"deadCode":400}' > "$DEADF"
check "requeue without --any-tenant leaves a typo'd tenant dead" "$("$EMIT" --requeue-dead 2>/dev/null | tail -n 1)" "requeued 0 line(s)"
check "requeue --any-tenant moves it with the configured tenant" \
  "$("$EMIT" --requeue-dead --any-tenant 2>/dev/null | tail -n 1) $(jq -r '.body.tenantId' "$CM_HOME/outbox.jsonl")" "requeued 1 line(s) t-test"

# requeued lines then flush cleanly with a 2xx
seed_dead; "$EMIT" --requeue-dead >/dev/null 2>&1; echo 200 > "$STUB/code"
emit --flush >/dev/null
check "requeue then flush: all sent" "$(lines "$CM_HOME/outbox.jsonl")" "0"
check "requeue then flush: every body has a tenant" "$(jq -r '.tenantId' "$STUB/bodies.jsonl" | grep -c '^t-test$')" "3"

# ---- project id: projectId on every event kind, never on an upsert -----------
reset; export MC_PROJECT_ID="p_example"; echo 200 > "$STUB/code"
emit worker.done "w1 done" '{"pr":1}' >/dev/null
emit worktree.teardown "teardown h:/w" >/dev/null
emit --tick '{"summary":"1 live","live":1}' >/dev/null
emit --issue-state 44 in-review '#90' >/dev/null
check "project id: every event kind posted with it" \
  "$(jq -r '"\(.type)=\(.projectId)"' "$STUB/bodies.jsonl" | tr '\n' ' ')" \
  "worker.done=p_example worktree.teardown=p_example concertmaster.tick=p_example issue.state=p_example "
reset; MC_NO_FLUSH=1 "$EMIT" worker.done queued 2>/dev/null
check "project id: stamped when queued, not only on send" "$(jq -r '.body.projectId' "$CM_HOME/outbox.jsonl")" "p_example"
reset
check "project id: --fleet-upsert exits 0" "$(emit --fleet-upsert a1 n1 active task /w)" "rc=0"
check "project id: --fleet-upsert queues and sends nothing" "$(lines "$CM_HOME/outbox.jsonl") $(calls)" "0 0"
check "project id: skipped upsert logged once" "$(grep -c 'fleet upsert for a1 not sent' "$STUB/stderr")" "1"
MC_QUIET=1 "$EMIT" --fleet-upsert a2 n2 idle - /w
check "project id: quiet skip still recorded in fleet.skipped" "$(jq -r '.agentId' "$CM_HOME/fleet.skipped")" "a2"
# a line queued before the project id was set gets it on send; another project's is kept
reset
{ echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"old"},"queuedAt":1}'
  echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"mine","projectId":"p_other"},"queuedAt":2}'; } > "$CM_HOME/outbox.jsonl"
emit --flush >/dev/null
check "project id: filled in on send, an existing one left alone" \
  "$(jq -r '"\(.type)=\(.projectId)"' "$STUB/bodies.jsonl" | tr '\n' ' ')" "old=p_example mine=p_other "
# from mc.env and from config.yaml
reset; unset MC_PROJECT_ID; printf 'MC_PROJECT_ID="p_from-file"\n' > "$CM_HOME/mc.env"
emit worker.done x >/dev/null
check "project id: read from mc.env" "$(jq -r '.projectId' "$STUB/bodies.jsonl")" "p_from-file"
reset; printf 'telemetry:\n  project_id: p_from-cfg\n' > "$CM_HOME/config.yaml"
emit worker.done x >/dev/null
check "project id: read from config telemetry.project_id" "$(jq -r '.projectId' "$STUB/bodies.jsonl")" "p_from-cfg"

# ---- project id unset or invalid: no projectId key at all ----------------------
reset
emit worker.done x >/dev/null; emit --tick '{"live":0}' >/dev/null
check "no project id: no projectId key, not even null" "$(jq -r 'has("projectId")' "$STUB/bodies.jsonl" | sort -u)" "false"
check "no project id: no warning" "$(grep -c 'project id' "$STUB/stderr")" "0"
rm -f "$STUB/curl.args"; emit --fleet-upsert a1 n1 active task /w >/dev/null
check "no project id: legacy upsert still posted" "$(sed 's/.* //' "$STUB/curl.args")" "http://mc.stub.invalid/api/fleet/upsert"
for bad in "P_UPPER" "p_" "p_-lead" "x_acme" "p_has space" "p_$(printf 'a%.0s' $(seq 1 40))"; do
  reset; MC_PROJECT_ID="$bad" emit worker.done x >/dev/null
  check "invalid project id '$bad': not sent, one warning" \
    "$(jq -r 'has("projectId")' "$STUB/bodies.jsonl") $(grep -c 'is not a p_<owner> id' "$STUB/stderr")" "false 1"
done
reset; MC_PROJECT_ID="p_$(printf 'a%.0s' $(seq 1 39))" emit worker.done x >/dev/null
check "project id at the 41-char limit: sent" "$(jq -r '.projectId | length' "$STUB/bodies.jsonl")" "41"

# ---- 403 on a fleet upsert dead-letters; 403 on an event still stops ---------
reset; echo 403 > "$STUB/code"
{ echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":"t-test","agentId":"a"},"queuedAt":1}'
  echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"e"},"queuedAt":2}'; } > "$CM_HOME/outbox.jsonl"
emit --flush >/dev/null
check "403 upsert: dead-lettered with deadCode 403" "$(jq -r '"\(.endpoint) \(.deadCode)"' "$CM_HOME/outbox.dead.jsonl")" "/api/fleet/upsert 403"
check "403 upsert: the event behind it was tried, kept, not dead" "$(calls) $(jq -r '.body.type' "$CM_HOME/outbox.jsonl")" "2 e"
emit --flush >/dev/null
check "403 event: kept, batch stops, upsert never retried" "$(calls) $(lines "$CM_HOME/outbox.jsonl") $(lines "$CM_HOME/outbox.dead.jsonl")" "3 1 1"
check "403 upsert: not a requeue candidate" "$("$EMIT" --requeue-dead --any-tenant 2>/dev/null | tail -n 1)" "requeued 0 line(s)"

# ---- requeue with a project id: projectId, tenantId and a stable eventId -------
seed_proj() {
  reset
  {
    echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"a","message":"m"},"queuedAt":1,"deadCode":400}'
    echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"a","message":"m"},"queuedAt":1,"deadCode":400}'
    echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"b","eventId":"keep-me"},"queuedAt":2,"deadCode":400}'
    echo '{"endpoint":"/api/events","body":{"tenantId":null,"type":"c","projectId":"p_other"},"queuedAt":3,"deadCode":400}'
    echo '{"endpoint":"/api/fleet/upsert","body":{"tenantId":null,"agentId":"u"},"queuedAt":4,"deadCode":400}'
  } > "$DEADF"
  cp "$DEADF" "$ROOT/dead.proj"
}
export MC_PROJECT_ID="p_example"
seed_proj; OUTP="$("$EMIT" --requeue-dead 2>/dev/null)"
check "requeue, project id: events moved, other project and upsert stay" "$(printf '%s\n' "$OUTP" | tail -n 1)" "requeued 3 line(s)"
check "requeue, project id: tenantId and projectId stamped" \
  "$(jq -r '"\(.body.tenantId) \(.body.projectId)"' "$CM_HOME/outbox.jsonl" | sort -u)" "t-test p_example"
check "requeue, project id: existing eventId kept, others rq- ids" \
  "$(jq -r '.body.eventId | if startswith("rq-") then "rq:\(length)" else . end' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')" "rq:43 rq:43 keep-me "
check "requeue, project id: identical lines share one id (the same event)" \
  "$(jq -r '.body.eventId' "$CM_HOME/outbox.jsonl" | sort -u | wc -l | tr -d ' ')" "2"
check "requeue, project id: eventIds match the sink's charset" \
  "$(jq -r '.body.eventId | test("^[A-Za-z0-9._:-]{1,128}$")' "$CM_HOME/outbox.jsonl" | sort -u)" "true"
check "requeue, project id: no _idsrc left behind" "$(grep -c _idsrc "$CM_HOME/outbox.jsonl")" "0"
check "requeue, project id: other project's line untouched, byte for byte" \
  "$(sed -n '4,5p' "$ROOT/dead.proj" | cmp -s - "$DEADF" && echo same)" "same"
jq -r '.body.eventId' "$CM_HOME/outbox.jsonl" > "$ROOT/ids.1"
seed_proj; "$EMIT" --requeue-dead >/dev/null 2>&1
check "requeue twice: same eventIds both times" "$(jq -r '.body.eventId' "$CM_HOME/outbox.jsonl" | cmp -s - "$ROOT/ids.1" && echo same)" "same"
# the dead file is trimmed from the top (cap_dead): line numbers shift, ids must not
seed_proj; { echo '{"endpoint":"/api/events","body":{"tenantId":"x"},"queuedAt":0,"deadCode":404}'
  echo '{"endpoint":"/api/events","body":{"tenantId":"x"},"queuedAt":0,"deadCode":404}'; cat "$ROOT/dead.proj"; } > "$DEADF"
"$EMIT" --requeue-dead >/dev/null 2>&1
check "requeue after a trim shifted the lines: same eventIds" "$(jq -r '.body.eventId' "$CM_HOME/outbox.jsonl" | cmp -s - "$ROOT/ids.1" && echo same)" "same"
# tenant-free: a line dead with a wrong tenant gets the id it would have had with none
seed_proj; sed -i.orig '1s/"tenantId":null/"tenantId":"tenant-x"/' "$DEADF"
MC_TENANT_ID="tenant-x" "$EMIT" --requeue-dead --any-tenant >/dev/null 2>&1
check "requeue: eventId ignores the tenant the line died with" \
  "$(jq -r '.body.eventId' "$CM_HOME/outbox.jsonl" | cmp -s - "$ROOT/ids.1" && echo same)" "same"
echo 200 > "$STUB/code"; emit --flush >/dev/null
check "requeue then flush: every event posted with projectId and eventId" \
  "$(jq -r '"\(.projectId) \(.eventId != null)"' "$STUB/bodies.jsonl" | sort -u)" "p_example true"
# a copy older than 3 filled the tenant in before the bound token refused the line
reset; echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"v2"},"queuedAt":7,"deadCode":400}' > "$DEADF"
check "requeue, project id: tenant set but no projectId is picked without --any-tenant" \
  "$("$EMIT" --requeue-dead 2>/dev/null | tail -n 1) $(jq -r '"\(.body.tenantId) \(.body.projectId)"' "$CM_HOME/outbox.jsonl")" "requeued 1 line(s) t-test p_example"
# a 403 on an event naming another project (id changed while queued) dead-letters
reset; echo 403 > "$STUB/code"
{ echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"was-a","projectId":"p_a"},"queuedAt":1}'
  echo '{"endpoint":"/api/events","body":{"tenantId":"t-test","type":"now"},"queuedAt":2}'; } > "$CM_HOME/outbox.jsonl"
emit --flush >/dev/null
check "403 event naming another project: dead-lettered with deadCode 403" "$(jq -r '"\(.body.type) \(.deadCode)"' "$DEADF")" "was-a 403"
check "403 event for the configured project: kept, batch stopped" "$(calls) $(jq -r '.body.type' "$CM_HOME/outbox.jsonl")" "2 now"
# no sha256sum and no shasum: requeue still moves the lines, without an eventId
NH="$ROOT/nohash"; mkdir -p "$NH"
for d in $(printf '%s' "$PATH" | tr ':' ' '); do for f in "$d"/*; do
  n="${f##*/}"; case "$n" in sha256sum|shasum|'*') continue ;; esac; [ -e "$NH/$n" ] || [ -L "$NH/$n" ] || ln -s "$f" "$NH/$n"
done; done
seed_proj; OUTH="$(PATH="$NH" "$EMIT" --requeue-dead 2>>"$STUB/stderr")"
check "no hasher, project id: requeue still moves the lines" "$(printf '%s\n' "$OUTH" | tail -n 1)" "requeued 3 line(s)"
check "no hasher: events go without a new eventId, one warning" \
  "$(jq -r '.body.eventId // "none"' "$CM_HOME/outbox.jsonl" | tr '\n' ' ')$(grep -c 'no sha256sum or shasum' "$STUB/stderr")" "none none keep-me 1"
unset MC_PROJECT_ID
seed_proj; OUTH="$(PATH="$NH" "$EMIT" --requeue-dead 2>/dev/null)"
check "no hasher, no project id: requeue still moves the lines (upsert too)" "$(printf '%s\n' "$OUTH" | tail -n 1)" "requeued 4 line(s)"
seed_proj; "$EMIT" --requeue-dead >/dev/null 2>&1
check "requeue, no project id: no projectId stamped, eventId still set" \
  "$(jq -r 'select(.endpoint == "/api/events") | "\(.body | has("projectId")) \(.body.eventId != null)"' "$CM_HOME/outbox.jsonl" | sort -u)" "false true"
check "requeue, no project id: line naming a project stays dead, upsert moves" \
  "$(jq -r '.body.type // .body.agentId' "$DEADF" | tr '\n' ' ')$(jq -r 'select(.endpoint == "/api/fleet/upsert") | .body.agentId' "$CM_HOME/outbox.jsonl")" "c u"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
