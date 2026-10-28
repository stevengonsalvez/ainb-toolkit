#!/usr/bin/env bash
# automations-audit.sh (test): behaviour tests for the Orca automations audit. The
# orca CLI is a stub that answers `host list` and `automations list` from files in a
# mktemp dir; the config is written there too. No Orca, no network.
#
#   scripts/test/automations-audit.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../automations-audit.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-autoaudit.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home"
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" STUB_DIR="$ROOT" ORCA_CLI_COMMAND="$ROOT/bin/orca-stub"
unset CM_CONFIG CM_PROJECT

cat > "$ROOT/bin/orca-stub" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") cat "$STUB_DIR/hosts.json" ;;
  "automations list")
    case "$*" in
      *"--environment host-b"*) cat "$STUB_DIR/auto-host-b.json" ;;
      *) cat "$STUB_DIR/auto-local.json" ;;
    esac ;;
  *) exit 1 ;;
esac
S
chmod +x "$ROOT/bin/orca-stub"
echo '{"result":{"hosts":[{"name":"this machine"},{"name":"host-b"}]}}' > "$ROOT/hosts.json"
cat > "$ROOT/auto-local.json" <<'J'
{"result":{"automations":[
 {"id":"a1","name":"Acme ops-sweeper recovery tick","agentId":"codex","enabled":true,"rrule":"FREQ=MINUTELY;INTERVAL=30"},
 {"id":"a2","name":"Acme pr-sweeper resume","agentId":"claude","enabled":true,"rrule":"FREQ=HOURLY"},
 {"id":"a3","name":"Acme nightly report","agentId":"claude","enabled":true,"rrule":"FREQ=DAILY"},
 {"id":"a4","name":"Acme dev-sweeper recovery","agentId":"codex","enabled":false,"rrule":"FREQ=HOURLY"},
 {"id":"a5","name":"Unrelated housekeeping","agentId":"codex","enabled":true,"rrule":"FREQ=DAILY"},
 {"id":"a6","name":"Acme planned recovery","agentId":"claude","enabled":true,"rrule":"FREQ=DAILY"}
]}}
J
echo '{"result":{"automations":[{"id":"b1","name":"lane-a lead tick","agentId":"claude","enabled":true,"rrule":"FREQ=HOURLY"}]}}' > "$ROOT/auto-host-b.json"

cfg() { printf 'schema: concertmaster.config/v1\nproject: { name: Acme }\nlanes:\n  - { name: lane-a, standing: true }\n  - { name: "epic:<name>", standing: true }\n%s\n' "$1" > "$ROOT/config.yaml"; export CM_CONFIG="$ROOT/config.yaml"; }

PASS=0; FAIL=0
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi
}
flags() { "$SCRIPT" 2>/dev/null | cut -f1,3 | tr '\t\n' ': ' ; }

cfg 'automations: { forbidden_agents: [codex] }'
check "forbidden agent, duplicate name, ok, disabled, other project, other host" "$(flags)" \
  "FORBIDDEN:a1 DUPLICATE:a2 ok:a3 ok:a4 DUPLICATE:a6 DUPLICATE:b1 "
check "an unrelated automation is not listed" "$("$SCRIPT" 2>/dev/null | grep -c a5)" "0"
check "the host column names the Orca environment" "$("$SCRIPT" 2>/dev/null | grep b1 | cut -f2)" "host-b"

cfg 'automations: { forbidden_agents: [codex], expected: ["acme planned recovery"] }'
check "an expected name is not a duplicate (case-insensitive)" "$("$SCRIPT" 2>/dev/null | grep a6 | cut -f1)" "ok"

cfg 'automations: { forbidden_agents: [codex], expected: ["Acme ops-sweeper recovery tick"] }'
check "an expected name is still FORBIDDEN when it runs a forbidden agent" "$("$SCRIPT" 2>/dev/null | grep a1 | cut -f1)" "FORBIDDEN"

cfg ''
check "no forbidden agents configured: nothing is FORBIDDEN" "$("$SCRIPT" 2>/dev/null | cut -f1 | grep -c FORBIDDEN)" "0"
cfg 'agents: { forbidden: [codex] }'
check "agents.forbidden is read when automations.forbidden_agents is unset" "$("$SCRIPT" 2>/dev/null | grep a1 | cut -f1)" "FORBIDDEN"

cfg 'automations: { names: ["Unrelated"] }'
check "automations.names adds a name to match" "$("$SCRIPT" 2>/dev/null | grep -c a5)" "1"
cfg 'automations: { duplicate_pattern: "planned" }'
check "automations.duplicate_pattern replaces the default" "$("$SCRIPT" 2>/dev/null | grep a6 | cut -f1) $("$SCRIPT" 2>/dev/null | grep a2 | cut -f1)" "DUPLICATE ok"

# every row is plain TSV
check "output is plain TSV with 7 columns" "$("$SCRIPT" 2>/dev/null | awk -F'\t' 'NF != 7' | grep -c .)" "0"

printf 'schema: concertmaster.config/v1\n' > "$ROOT/config.yaml"
"$SCRIPT" >/dev/null 2>&1; check "config naming nothing: exit 2" "$?" "2"
check "unknown arg: exit 2" "$("$SCRIPT" --nope >/dev/null 2>&1; echo $?)" "2"
cfg ''
echo 'not json' > "$ROOT/auto-local.json"
check "garbage answer from orca: exit 0, no rows from that host" "$("$SCRIPT" 2>/dev/null | cut -f3 | tr '\n' ' ')" "b1 "

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
