#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# queue.sh (test): behaviour tests for the work queue. add then list keeps the
# order (P0, urgent, oldest addedAt); a grant with the total at the cap grants
# nothing, one under it grants the top item; host caps hold; every write leaves
# one valid JSON document, and a filter emitting several documents is refused;
# fresh grants hold their slot; the lock belongs to its holder.
# Touches nothing outside a mktemp dir.
#
#   scripts/test/queue.sh              # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
Q="$HERE/../queue.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-queue.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
# The guarded ledger writer lives in lib.sh (references/ledger.md). Without it the write paths cannot be tested.
if ! bash -c '. "$1"; declare -F cm_ledger_write' _ "$HERE/../lib.sh" >/dev/null 2>&1; then
  echo "this suite needs cm_ledger_write in scripts/lib.sh (references/ledger.md)" >&2; exit 1
fi
export CM_HOME="$ROOT/home" CM_CONFIG="$ROOT/config.yaml"
L="$CM_HOME/ledger.json"
mkdir -p "$CM_HOME"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
# check <label> <cmd...>: pass when the command succeeds
check() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$l"; else fail "$l" "check failed"; fi; }
one_doc() { [ "$(jq -s 'length' "$L" 2>/dev/null)" = 1 ] && jq -e 'type == "object"' "$L" >/dev/null 2>&1; }
order() { "$Q" list --json | jq -r 'map("\(.issue)") | join(",")'; }
state_of() { jq -r --arg i "$1" '.queue.items[] | select(.issue == ($i | tonumber)) | .state' "$L"; }

cat > "$CM_CONFIG" <<'EOF'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme-app/" }
hosts:
  home: local
  defaults: { role: general, maxWorkers: 2 }
  per_host:
    local:  { role: general, maxWorkers: 11 }
    host-a:    { role: general, maxWorkers: 15 }
    host-b:  { role: general, maxWorkers: 4 }
    host-c:    { role: native,  maxWorkers: 2 }
queue: { cap: 30 }
EOF
fresh() { printf '{"schema":"concertmaster.ledger/v1","updatedAt":null,"hosts":{},"workers":{}}\n' > "$L"; }

# --- add then list ----------------------------------------------------------
fresh
out="$(CM_NOW=2026-10-18T09:00:00Z "$Q" add 101 dev-sweeper)"
[ "$out" = "queued, position 1: #101 dev-sweeper normal" ] && pass "add prints queued, position 1" || fail "add position" "$out"
CM_NOW=2026-10-18T09:01:00Z "$Q" add 102 ops-sweeper --priority urgent >/dev/null
out="$(CM_NOW=2026-10-18T09:02:00Z "$Q" add '#103' dev-sweeper --priority P0)"
[ "$out" = "queued, position 1: #103 dev-sweeper P0" ] && pass "a newer P0 goes to position 1" || fail "P0 position" "$out"
out="$(CM_NOW=2026-10-18T09:03:00Z "$Q" add 104 dev-sweeper)"
[ "$out" = "queued, position 4: #104 dev-sweeper normal" ] && pass "a newer normal goes after the older one" || fail "normal position" "$out"
[ "$(order)" = "103,102,101,104" ] && pass "list order: P0, urgent, then oldest addedAt" || fail "list order" "$(order)"
"$Q" list | grep -q '^1 *q-3 *#103 *dev-sweeper *P0' && pass "list table shows position, id, issue" || fail "list table" "$("$Q" list | head -2)"
out="$(CM_NOW=2026-10-18T09:04:00Z "$Q" add 101 dev-sweeper)"
[ "$out" = "already queued, position 3: #101 dev-sweeper" ] && [ "$(jq '.queue.items | length' "$L")" = 4 ] \
  && pass "same issue and lane is not queued twice" || fail "dedupe" "$out"
[ -n "$(find "$CM_HOME/ledger.bak" -name '*.json' 2>/dev/null)" ] && pass "a queue write backs the old ledger up to the ring" || fail "queue ring" "$(ls -A "$CM_HOME")"
[ "$(jq -r '.queue.cap' "$L")" = 30 ] && pass "add records the configured cap in the ledger" || fail "cap seed" "$(jq -c .queue.cap "$L")"
check "ledger is one JSON object after adds" one_doc
"$Q" depth | grep -q '^queue: depth=4 next: #103 dev-sweeper P0, #102 ops-sweeper urgent, #101 dev-sweeper normal$' \
  && pass "depth prints the depth and next 3" || fail "depth" "$("$Q" depth)"

# --- bad input --------------------------------------------------------------
"$Q" add 105 dev-sweeper --priority high >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "unknown priority refused (exit 2)" || fail "bad priority" "rc=$rc"
"$Q" add abc dev-sweeper >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "non-numeric issue refused (exit 2)" || fail "bad issue" "rc=$rc"
"$Q" add 105 'dev;rm' >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "lane with shell characters refused (exit 2)" || fail "bad lane" "rc=$rc"

# --- grant at and under the cap ---------------------------------------------
cp "$L" "$ROOT/before.json"
out="$("$Q" grant --live local=11,host-a=15,host-b=4)"
printf '%s' "$out" | grep -q '^granted nothing$' && cmp -s "$L" "$ROOT/before.json" \
  && pass "30 live sessions: nothing granted, ledger unchanged" || fail "grant at cap" "$out"
out="$(CM_NOW=2026-10-18T09:30:00Z "$Q" grant --live local=10,host-a=15,host-b=4)"
[ "$(printf '%s\n' "$out" | grep -c '^granted ')" = 1 ] && printf '%s' "$out" | grep -q '^granted q-3 #103 dev-sweeper P0 -> local$' \
  && pass "29 live sessions: exactly the top P0 item granted" || fail "grant under cap" "$out"
[ "$(state_of 103)" = granted ] && [ "$(jq -r '.queue.items[] | select(.issue == 103) | .grantedAt + " " + .host' "$L")" = "2026-10-18T09:30:00Z local" ] \
  && pass "granted item has state, grantedAt and host" || fail "granted fields" "$(jq -c '.queue.items[] | select(.issue == 103)' "$L")"
[ "$(state_of 102)" = queued ] && pass "the next item stays queued" || fail "next queued" "$(state_of 102)"
check "ledger is one JSON object after a grant" one_doc
out="$(CM_NOW=2026-10-18T09:35:00Z "$Q" grant --live local=10,host-a=15,host-b=4)"
printf '%s' "$out" | grep -q '^granted nothing$' && printf '%s' "$out" | grep -q 'local 10+1/11' \
  && pass "a fresh grant counts as live until it shows up: no second grant into that slot" || fail "pending grant" "$out"
out="$(CM_NOW=2026-10-18T10:05:00Z "$Q" grant --live local=10,host-a=15,host-b=4 --dry-run)"
printf '%s' "$out" | grep -q '^would grant q-2 #102' \
  && pass "after queue.grant_hold_minutes the grant no longer holds a slot" || fail "hold expiry" "$out"

# --- host caps --------------------------------------------------------------
# total 20 of 30, but local and host-a full: the next items go to host-b, the one free general host
out="$("$Q" grant --live local=11,host-a=15,host-b=0 --dry-run)"
printf '%s' "$out" | grep -q 'would grant q-2 #102 ops-sweeper urgent -> host-b' \
  && pass "an item with no host goes to the general host with a free slot" || fail "host pick" "$out"
[ "$(state_of 102)" = queued ] && pass "--dry-run writes nothing" || fail "dry run" "$(state_of 102)"
# host-b has 4 slots; total cap would allow more but host-b fills at 4
fresh
for i in 1 2 3 4 5 6; do CM_NOW="2026-10-18T10:0$i:00Z" "$Q" add "20$i" dev-sweeper --host host-b >/dev/null; done
out="$("$Q" grant --live local=0,host-a=0,host-b=1)"
[ "$(printf '%s\n' "$out" | grep -c '^granted ')" = 3 ] && [ "$(state_of 204)" = queued ] \
  && pass "a pinned host never goes past its maxWorkers" || fail "host cap" "$out"
# hosts are counted as full when the discover document says unreachable or truncated
fresh
CM_NOW=2026-10-18T11:00:00Z "$Q" add 301 dev-sweeper >/dev/null
cat > "$ROOT/discover.json" <<'EOF'
{"schema":"concertmaster.discover/v1",
 "hosts":[{"name":"local","reachable":true,"truncated":false},
          {"name":"host-a","reachable":false,"truncated":null},
          {"name":"host-b","reachable":true,"truncated":true}],
 "worktrees":[
  {"host":"local","path":"/w/acme-app/a","liveTerminalCount":1,"agents":[{"paneKey":"p1"},{"paneKey":"p2"}]},
  {"host":"local","path":"/w/acme-app/b","liveTerminalCount":0,"agents":[{"paneKey":"p3"}]},
  {"host":"local","path":"/w/other-app/c","liveTerminalCount":1,"agents":[{"paneKey":"p4"}]},
  {"host":"local","path":"/w/acme-app/d","liveTerminalCount":1,"agents":[{"paneKey":null},{"paneKey":null}]},
  {"host":"host-b","path":"/w/acme-app/e","liveTerminalCount":1,"agents":[{"paneKey":"p5"}]}]}
EOF
out="$("$Q" grant --discover "$ROOT/discover.json" --dry-run)"
printf '%s' "$out" | grep -q '^live=.*host-b ?/4, host-c -/2, local 4/11' && printf '%s' "$out" | grep -q 'host-a ?/15' \
  && pass "discover: live agent panes under path_match counted, unknown hosts shown as ?" || fail "discover counts" "$out"
printf '%s' "$out" | grep -q '^live=23/30' && printf '%s' "$out" | grep -q 'would grant q-1 #301 dev-sweeper normal -> local' \
  && pass "discover: unreachable and truncated hosts count as full, missing ones as 0; the native host is never picked" || fail "discover grant" "$out"

# --- no cap anywhere --------------------------------------------------------
sed '/^queue:/d' "$CM_CONFIG" > "$ROOT/nocap.yaml"
fresh; CM_CONFIG="$ROOT/nocap.yaml" "$Q" add 401 dev-sweeper >/dev/null
CM_CONFIG="$ROOT/nocap.yaml" "$Q" grant --live local=0 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(state_of 401)" = queued ] && pass "no queue cap configured: nothing granted (exit 2)" || fail "no cap" "rc=$rc"

# --- mark -------------------------------------------------------------------
"$Q" mark q-1 "done" >/dev/null && [ "$(state_of 401)" = "done" ] && pass "mark sets done" || fail "mark" "$(state_of 401)"
"$Q" mark q-9 "done" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "mark of an unknown id refused (exit 2)" || fail "mark unknown" "rc=$rc"

fresh; CM_NOW=2026-10-18T12:00:00Z "$Q" add 451 dev-sweeper >/dev/null
CM_NOW=2026-10-18T12:01:00Z "$Q" add 452 dev-sweeper >/dev/null
CM_NOW=2026-10-18T12:05:00Z "$Q" grant --live local=10 >/dev/null   # one slot: q-1 only
"$Q" mark q-1 queued >/dev/null && [ "$(order)" = "451,452" ] && [ "$(jq -r '.queue.items[0].grantedAt' "$L")" = null ] \
  && pass "mark queued puts a failed hand-off back at its old position" || fail "requeue" "$(order)"

# --- host names and the lock ------------------------------------------------
err="$("$Q" grant --live local=0,host-d=1 --dry-run 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'census hosts host-d not in config' \
  && pass "a census host missing from config, with config hosts unseen, warns" || fail "host name warn" "$err"
mkdir "$L.lock" && printf '999999\n' > "$L.lock/pid"
# shellcheck source=SCRIPTDIR/../lib.sh
( . "$HERE/../lib.sh"; CM_LEDGER="$L" cm_ledger_unlock )
[ -d "$L.lock" ] && pass "exit never removes a lock another process holds" || fail "lock ownership" "lock removed"
touch -t 202001010000 "$L.lock"
"$Q" add 461 dev-sweeper >/dev/null 2>&1 && [ ! -e "$L.lock" ] && [ -z "$(find "$CM_HOME" -name 'ledger.json.lock.stale.*')" ] \
  && pass "a stale lock (over 2 minutes) is stolen and cleaned up" || fail "stale lock" "$(ls -a "$CM_HOME")"

# --- the single-document guard ----------------------------------------------
fresh; CM_NOW=2026-10-18T12:00:00Z "$Q" add 501 dev-sweeper >/dev/null
cp "$L" "$ROOT/before.json"
# shellcheck source=SCRIPTDIR/../queue.sh
( . "$Q"; write_ledger '., .' ) >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && cmp -s "$L" "$ROOT/before.json" && pass "a filter emitting two documents is refused, ledger untouched" \
  || fail "multi-doc guard" "rc=$rc"
# shellcheck source=SCRIPTDIR/../queue.sh
( . "$Q"; write_ledger 'empty' ) >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && cmp -s "$L" "$ROOT/before.json" && pass "a filter emitting nothing is refused, ledger untouched" \
  || fail "empty guard" "rc=$rc"
# shellcheck source=SCRIPTDIR/../queue.sh
( . "$Q"; write_ledger '[.]' ) >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && cmp -s "$L" "$ROOT/before.json" && pass "a filter emitting a non-object is refused, ledger untouched" \
  || fail "non-object guard" "rc=$rc"
[ -z "$(find "$CM_HOME" -name 'ledger.json.tmp.*')" ] && [ ! -e "$L.lock" ] && pass "no temp file or lock left behind" \
  || fail "leftovers" "$(ls "$CM_HOME")"

# --- no guarded writer in lib.sh --------------------------------------------
# A copy of queue.sh next to a lib.sh without cm_ledger_write: reads work, writes refuse clearly.
fresh; CM_NOW=2026-10-18T12:00:00Z "$Q" add 601 dev-sweeper >/dev/null
mkdir -p "$ROOT/nolib"; cp "$Q" "$ROOT/nolib/queue.sh"
cat > "$ROOT/nolib/lib.sh" <<'EOF2'
cm_warn() { printf 'concertmaster: %s\n' "$*" >&2; }
cm_cfg() { printf '%s' "${2:-}"; }
cm_cfg_json() { printf '%s' "${2:-null}"; }
CM_HOME="${CM_HOME:-/nonexistent}"; CM_PATH_MATCH=""
EOF2
cp "$L" "$ROOT/before.json"
err="$(bash "$ROOT/nolib/queue.sh" add 602 dev-sweeper 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$err" | grep -q 'needs cm_ledger_write' && cmp -s "$L" "$ROOT/before.json" \
  && pass "no cm_ledger_write: add refuses with a message, ledger untouched" || fail "no writer add" "rc=$rc $err"
bash "$ROOT/nolib/queue.sh" mark q-1 "done" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && cmp -s "$L" "$ROOT/before.json" && pass "no cm_ledger_write: mark refuses (exit 1)" || fail "no writer mark" "rc=$rc"
[ "$(bash "$ROOT/nolib/queue.sh" depth)" = "queue: depth=1 next: #601 dev-sweeper normal" ] \
  && pass "no cm_ledger_write: depth still reads" || fail "no writer depth" "$(bash "$ROOT/nolib/queue.sh" depth 2>&1)"

printf '\nqueue: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
