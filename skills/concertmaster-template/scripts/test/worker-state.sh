#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# worker-state.sh (test): a worker state that is present and is not EXACTLY a known state string is unknown and never resumable
# (lib.sh cm_state_unknown, cm_state_resumable). jq `//` and a case-insensitive match read "Asleep", "asleep " and false as a running
# lane that a reboot could revive; null or absent is the legacy running. Also the roster: an unknown-state lane stays OUT of it and
# is named in a comment, a known state and an absent state are listed as before.
#
#   scripts/test/worker-state.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-worker-state.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_LEDGER_BAK_KEEP CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_EXCLUDE_REPOS CM_PATH_MATCH
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME" "$CM_HOME"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$SCRIPTS/lib.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }
# punk <json state>: "<unknown>,<resumable>"
punk() { jq -nrc --argjson s "$1" "$CM_JQ_STATE_DEFS"' $s | [cm_state_unknown, cm_state_resumable] | map(tostring) | join(",")'; }
for s in '"Asleep"' '"asleep "' '"ASLEEP"' '"Done"' '"running "' false 7 '{}' '[]' '""' true '"gon"'; do
  [ "$(punk "$s")" = "true,false" ] && pass "state $s: unknown and never resumable" || fail "unknown $s" "$(punk "$s")"
done
for s in '"asleep"' '"done"' '"retired"' '"torn-down"' '"gone"' '"repurposed"'; do
  [ "$(punk "$s")" = "false,false" ] && pass "control: known no-resume state $s is not unknown and not resumable" || fail "control $s" "$(punk "$s")"
done
for s in null '"running"' '"stuck"' '"blocked-on-owner"'; do
  [ "$(punk "$s")" = "false,true" ] && pass "control: $s is known and resumable" || fail "control $s" "$(punk "$s")"
done

# --- roster.sh
L="$CM_HOME/ledger.json"
live_shape() {
  cat > "$L" <<'J'
{"workers": {
  "w-run":  {"host": "local", "path": "/x/w-run",  "lane": "lane-a", "state": "running"},
  "w-done": {"host": "local", "path": "/x/w-done", "lane": "lane-b", "state": "done"}}}
J
}
live_shape
out="$(bash "$SCRIPTS/roster.sh" --stdout 2>&1)"
case "$out" in *"/x/w-run"*) pass "roster.sh lists the running worker" ;; *) fail "roster lists running" "$out" ;; esac
case "$out" in *"/x/w-done"*) fail "roster leaves out done" "listed" ;; *) pass "roster.sh leaves out a done worker" ;; esac
for bad in '"Asleep"' '"asleep "' '"Done"' false 7 '{}'; do
  live_shape
  jq --argjson v "$bad" '.workers["w-run"].state = $v' "$L" > "$L.t" && mv "$L.t" "$L"
  out="$(bash "$SCRIPTS/roster.sh" --stdout 2>&1)"
  case "$out" in *"/x/w-run"*) fail "roster state $bad" "an unknown state is in the resume list" ;; *) pass "roster.sh: state $bad is not listed" ;; esac
  case "$out" in *"# state not a known state, so NOT listed and never resumed (fix the ledger row): w-run"*) pass "roster.sh: state $bad is named in a comment" ;; *) fail "roster note $bad" "$(printf '%s' "$out" | head -4)" ;; esac
done
live_shape
jq 'del(.workers["w-run"].state)' "$L" > "$L.t" && mv "$L.t" "$L"
out="$(bash "$SCRIPTS/roster.sh" --stdout 2>&1)"
case "$out" in *"/x/w-run"*) pass "control: an absent state is the legacy running and is listed" ;; *) fail "control absent" "missing: $out" ;; esac
case "$out" in *"# state not a known state"*) fail "control note" "a note for a clean ledger" ;; *) pass "control: no unknown-state note on a clean ledger" ;; esac
# mutant: a roster that selects on the old inline list lists the unknown state
M="$ROOT/mut"; mkdir -p "$M"; cp -R "$SCRIPTS"/. "$M"/
perl -pi -e 's/select\(\.value\.state \| cm_state_resumable\)/select((.value.state \/\/ "running") | IN("queued", "spawning", "gone", "repurposed", "retired", "teardown", "done", "asleep") | not)/' "$M/roster.sh"
if ! cmp -s "$SCRIPTS/roster.sh" "$M/roster.sh"; then
  live_shape; jq '.workers["w-run"].state = "Asleep"' "$L" > "$L.t" && mv "$L.t" "$L"
  out="$(bash "$M/roster.sh" --stdout 2>&1)"
  case "$out" in *"/x/w-run"*) pass "mutant: with the old inline list a near-miss state is listed (the case above is caught)" ;; *) fail "mutant not caught" "$out" ;; esac
else fail "mutant" "the perl edit no longer matches roster.sh"; fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
