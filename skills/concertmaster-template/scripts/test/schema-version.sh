#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# schema-version.sh (test): cm_ledger_schema_version (scripts/lib.sh), the version read of the typed input boundary.
# The key ABSENT or null is version 1 (a legacy ledger); a positive whole number is itself; anything else present is `invalid`
# (never read as 1, so an invalid value is invalid in every version); no file, no JSON or not one object is `unreadable`.
#
#   scripts/test/schema-version.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-schema-version.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_LEDGER_BAK_KEEP CM_ORG CM_REPO CM_PROJECT CM_EXCLUDE_REPOS CM_PATH_MATCH
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME" "$CM_HOME"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$HERE/../lib.sh"
PASS=0; FAIL=0
# sv <label> <ledger text> <want word> <want rc>
sv() {
  local label="$1" doc="$2" want="$3" wrc="$4" got rc f="$ROOT/l.json"
  printf '%s' "$doc" > "$f"
  got="$(cm_ledger_schema_version "$f")"; rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$wrc" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" rc=%s want "%s" rc=%s\n' "$label" "$got" "$rc" "$want" "$wrc"; fi
}
sv "absent key is version 1" '{"workers":{}}' 1 0
sv "null is version 1" '{"workers":{},"schemaVersion":null}' 1 0
sv "1 is 1" '{"workers":{},"schemaVersion":1}' 1 0
sv "2 is 2" '{"workers":{},"schemaVersion":2}' 2 0
sv "12 is 12" '{"workers":{},"schemaVersion":12}' 12 0
sv "2.0 is 2" '{"workers":{},"schemaVersion":2.0}' 2 0
for bad in 0 -1 2.5 '"2"' '"1"' '""' '" "' true false '{}' '[]' '[2]' 1e9 ; do
  sv "schemaVersion $bad is invalid, never version 1" "{\"workers\":{},\"schemaVersion\":$bad}" invalid 1
done
sv "a ledger that is a list is unreadable" '[]' unreadable 2
sv "two documents are unreadable" '{"workers":{}}{"workers":{}}' unreadable 2
sv "not JSON is unreadable" 'not json' unreadable 2
sv "empty file is unreadable" '' unreadable 2
got="$(cm_ledger_schema_version "$ROOT/no-such-file")"; rc=$?
if [ "$got" = unreadable ] && [ "$rc" = 2 ]; then PASS=$((PASS + 1)); echo "PASS a missing file is unreadable"; else FAIL=$((FAIL + 1)); echo "FAIL a missing file: $got rc=$rc"; fi
printf '{"workers":{},"schemaVersion":2}' > "$CM_HOME/ledger.json"
got="$(cm_ledger_schema_version)"
if [ "$got" = 2 ]; then PASS=$((PASS + 1)); echo "PASS no argument reads the live ledger path"; else FAIL=$((FAIL + 1)); echo "FAIL default path: $got"; fi
# the version read scans the SAME bytes the view scans (contract rule G): a repeated schemaVersion is invalid,
# and a decimal that is not a whole number but rounds to one makes the document unreadable. An exact whole spelled with a fraction or an exponent is fine.
sv "a repeated schemaVersion (2 then 1) is invalid, never legacy 1" '{"schemaVersion":2,"schemaVersion":1,"workers":{}}' invalid 1
sv "a repeated schemaVersion (1 then 2) is invalid" '{"schemaVersion":1,"schemaVersion":2,"workers":{}}' invalid 1
sv "a repeated schemaVersion with the same value is invalid" '{"schemaVersion":2,"schemaVersion":2,"workers":{}}' invalid 1
sv "a schemaVersion decimal that rounds to 1 makes the ledger unreadable" '{"schemaVersion":1.0000000000000001,"workers":{}}' unreadable 2
sv "a schemaVersion decimal that rounds to 2 makes the ledger unreadable" '{"schemaVersion":1.99999999999999999,"workers":{}}' unreadable 2
sv "a near-integer decimal anywhere makes the ledger unreadable (as for the view)" '{"schemaVersion":2,"workers":{"a":{"issue":1.0000000000000001}}}' unreadable 2
sv "control: schemaVersion 1.0 is 1" '{"schemaVersion":1.0,"workers":{}}' 1 0
sv "control: schemaVersion 1e0 is 1" '{"schemaVersion":1e0,"workers":{}}' 1 0
sv "control: schemaVersion 10E-1 is 1" '{"schemaVersion":10E-1,"workers":{}}' 1 0
sv "control: schemaVersion 7.000 is 7" '{"schemaVersion":7.000,"workers":{}}' 7 0
sv "control: a repeated key elsewhere does not touch the version read" '{"schemaVersion":2,"workers":{"a":{"x":1,"x":2}}}' 2 0
sv "control: a repeated key inside a worker named schemaVersion is not the version's" '{"schemaVersion":2,"workers":{"schemaVersion":{"a":1}}}' 2 0
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
