#!/usr/bin/env bash
# shellcheck disable=SC2016  # the bash -c bodies are single-quoted on purpose
# orca-json-helpers.sh: tests for jsanitize and jstrings, the helpers that let jq read remote
# Orca JSON carrying lone UTF-16 surrogates. No Orca, no network.
#
#   scripts/test/orca-json-helpers.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
command -v python3 >/dev/null 2>&1 || { echo "missing dependency: python3" >&2; exit 1; }
PASS=0; FAIL=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"; else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$label"; fi
}

# A reply with a lone high surrogate escape and a raw tab inside a string (strict JSON rejects it).
BAD="$(printf '{"ok":true,"result":{"screen":"a\\ud83dz\tb","n":["x","y"]}}')"
check "jq alone rejects the lone surrogate reply" bash -c '! printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$BAD"
check "jsanitize output parses with jq" bash -c 'printf "%s" "$1" | "$2/jsanitize" | jq -e ".ok == true" >/dev/null' _ "$BAD" "$S"
check "jsanitize keeps the surrounding text" bash -c 'printf "%s" "$1" | "$2/jsanitize" | jq -r ".result.screen" | grep -q "^a.*z"' _ "$BAD" "$S"
check "jstrings prints every string, one per line" bash -c '[ "$(printf "%s" "$1" | "$2/jstrings" | grep -cE "^(x|y)$")" = 2 ]' _ "$BAD" "$S"
check "jsanitize passes well-formed JSON through unchanged" bash -c '[ "$(printf "%s" "{\"a\":[1,\"b\"]}" | "$1/jsanitize" | jq -c .)" = "{\"a\":[1,\"b\"]}" ]' _ "$S"
check "jsanitize echoes non-JSON input instead of failing" bash -c '[ "$(printf "not json" | "$1/jsanitize")" = "not json" ]' _ "$S"
check "jstrings on non-JSON prints nothing and exits 0" bash -c '[ -z "$(printf "not json" | "$1/jstrings")" ]' _ "$S"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
