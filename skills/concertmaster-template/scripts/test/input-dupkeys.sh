#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# input-dupkeys.sh (test): scripts/jdupkeys and cm_input_dupkeys (scripts/lib.sh), the repeated-key scan of the typed input boundary.
# jq keeps only the last of two equal keys, so a repeat is invisible to it. The scan reads the document itself: a repeat at any depth and
# whatever the values; a document it cannot read exactly (not JSON, NaN, Infinity, a number that does not fit a double, a decimal that only
# rounds to a whole number, a lone surrogate) is rc 2, which a caller treats as an unreadable document, never as a clean one.
#
#   scripts/test/input-dupkeys.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-input-dupkeys.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "missing dependency: python3" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_LEDGER_BAK_KEEP CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_EXCLUDE_REPOS CM_PATH_MATCH
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME" "$CM_HOME"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$HERE/../lib.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s%s\n' "$1" "${2:+: $2}"; }
F="$ROOT/doc.json"
# dk <label> <document> <want rc> <want output (one path per line, as printed)>
dk() {
  local label="$1" doc="$2" wrc="$3" want="$4" out rc
  printf '%s' "$doc" > "$F"
  out="$(cm_input_dupkeys "$F" 2>/dev/null)"; rc=$?
  if [ "$rc" = "$wrc" ] && [ "$out" = "$want" ]; then ok "$label"; else no "$label" "rc=$rc out=[$out] want rc=$wrc [$want]"; fi
}
# --- a repeat, at any depth, whatever the values
dk "no repeat in a clean document" '{"workers":{"a":{"state":"x"}},"asks":[]}' 0 ''
dk "a repeated leaf key is reported with its path" '{"workers":{"a":{"state":"running","state":"done"}}}' 0 '["workers","a","state"]'
dk "a repeated key with object values (a non-leaf)" '{"workers":{"a":{}},"lanes":{"pr":{"lead":"a"},"pr":{"state":"gone"}}}' 0 '["lanes","pr"]'
dk "a repeated top-level key" '{"workers":{"a":{"x":1}},"workers":{"b":{"x":1}}}' 0 '["workers"]'
dk "a repeat inside a list of objects" '{"a":[{"k":[1],"k":[2]}]}' 0 '["a",0,"k"]'
dk "a repeat three levels down" '{"a":{"b":{"c":1,"c":2}}}' 0 '["a","b","c"]'
dk "the same key in two different objects is not a repeat" '{"a":{"k":1},"b":{"k":1}}' 0 ''
dk "the same key in two list members is not a repeat" '{"a":[{"k":1},{"k":2}]}' 0 ''
dk "two repeats are two lines" '{"x":1,"x":2,"y":{"z":1,"z":2}}' 0 "$(printf '["x"]\n["y","z"]')"
dk "a key repeated three times is one line" '{"x":1,"x":2,"x":3}' 0 '["x"]'
dk "a repeated key whose values are equal is still a repeat" '{"schemaVersion":2,"schemaVersion":2}' 0 '["schemaVersion"]'
# --- a document that cannot be read exactly is rc 2, never clean
dk "not JSON" 'nope' 2 ''
dk "an empty file" '' 2 ''
dk "two documents" '{"a":1}{"a":2}' 2 ''
for bad in NaN Infinity -Infinity; do dk "$bad is not JSON" "{\"a\":$bad}" 2 ''; done
dk "a float that overflows a double" '{"a":1e999}' 2 ''
dk "an integer too big for a double (400 digits)" "{\"a\":$(python3 -c "print('9' * 400)")}" 2 ''
dk "an integer that fits a double is read" '{"a":123456789012345678901234567890}' 0 ''
dk "a decimal that only rounds to 1 is unreadable" '{"a":1.0000000000000001}' 2 ''
dk "a decimal that only rounds to 2 is unreadable" '{"a":1.99999999999999999}' 2 ''
dk "an exact whole spelled 1.0 is read" '{"a":1.0}' 0 ''
dk "an exact whole spelled 1e0 is read" '{"a":1e0}' 0 ''
dk "an exact whole spelled 7.000 is read" '{"a":7.000}' 0 ''
dk "an ordinary fraction is read" '{"a":1.5e3}' 0 ''
# a lone surrogate escape reads as U+FFFD in jq, so two keys that differ only there are ONE key to jq and two to a scan by code point
dk "two keys that differ only in a lone surrogate are unreadable" '{"a\udc00":1,"a\udfff":2}' 2 ''
dk "a lone surrogate in a value is unreadable" '{"x":"\udfff"}' 2 ''
dk "a lone surrogate nested in a list is unreadable" '[{"k":["\ud800"]}]' 2 ''
dk "a lone high surrogate before a plain escape is unreadable" '{"n":"\ud83dA"}' 2 ''
dk "a surrogate pair (one real character) is read" '{"x":"😀","😀":1}' 0 ''
dk "a real U+FFFD is read" '{"p":"é�"}' 0 ''
# --- the file itself
out="$(cm_input_dupkeys "$ROOT/no-such-file.json" 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok "a missing file is rc 2" || no "missing file" "rc=$rc"
printf '%s' '{"workers":{"a":{"state":"x","state":"y"}}}' > "$CM_HOME/ledger.json"
[ "$(cm_input_dupkeys)" = '["workers","a","state"]' ] && ok "no argument scans the ledger path" || no "default path"
# --- a scanner that cannot run is an unreadable document, never a clean one
mkdir -p "$ROOT/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$ROOT/fakebin/python3"; chmod +x "$ROOT/fakebin/python3"
printf '%s' '{"workers":{}}' > "$F"
PATH="$ROOT/fakebin:$PATH" cm_input_dupkeys "$F" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "a scanner that fails passes its failure on (rc 1: not a clean scan)" || no "failing scanner" "rc=$rc"
# an environment with no python3 at all: only the shell and jq on the PATH
mkdir -p "$ROOT/nopy"; for t in jq sh bash cat dirname mktemp rm; do p="$(command -v "$t")" && ln -sf "$p" "$ROOT/nopy/$t"; done
out="$(PATH="$ROOT/nopy" bash -c '. "$1"; cm_input_dupkeys "$2"; echo "rc=$?"' _ "$HERE/../lib.sh" "$F" 2>/dev/null)"
case "$out" in *rc=2) ok "no python3 on the PATH is rc 2" ;; *) no "no python3" "$out" ;; esac
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
