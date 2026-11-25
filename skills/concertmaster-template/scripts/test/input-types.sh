#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# input-types.sh (test): the worker state lists and the closed type table of lib.sh, the vocabulary of the typed input boundary
# (references/input-contract.md). Covers: every state in CM_STATES_* is documented in references/ledger.md and the no-resume list is the
# one resume.sh and roster.sh use; cm_state_dead reads gone, repurposed and the legacy spelling torn-down as dead and nothing else
# (a non-string state is not dead); cm_row_fields_ok accepts a well-typed row, a row with absent or null fields and a multi-line
# free-text field, and refuses every wrong type and every string field (of the row, `live` and `health`) that holds a control
# character, taken from the table itself so a field added later is covered without a new line here; cm_name_ok and cm_strip agree.
#
#   scripts/test/input-types.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-input-types.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_LEDGER_BAK_KEEP CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_EXCLUDE_REPOS CM_PATH_MATCH
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME" "$CM_HOME"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$HERE/../lib.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s%s\n' "$1" "${2:+: $2}"; }
# jqb <program> [jq args...]: run a program with the state and name definitions in front of it
jqb() { local p="$1"; shift; jq -nc "$@" "$CM_JQ_STATE_DEFS $CM_JQ_NAME_DEFS $p"; }

# --- the state lists
miss=""
for s in $CM_STATES_ALL; do grep -q "\`$s\`" "$SKILL/references/ledger.md" || miss="$miss $s"; done
[ -z "$miss" ] && ok "every state of CM_STATES_ALL is documented in references/ledger.md" || no "undocumented state" "$miss"
[ "$CM_STATES_ALL" = "$CM_STATES_LIVE $CM_STATES_DEAD" ] && ok "CM_STATES_ALL is the live states then the dead ones" || no "ALL list" "$CM_STATES_ALL"
dup="$(printf '%s\n' $CM_STATES_ALL | sort | uniq -d | tr '\n' ' ')"
[ -z "$dup" ] && ok "no state is listed twice" || no "duplicate state" "$dup"
bad=""
for s in $CM_STATES_NORESUME $CM_STATES_DEAD; do case " $CM_STATES_ALL " in *" $s "*) ;; *) bad="$bad $s" ;; esac; done
[ -z "$bad" ] && ok "the no-resume list names only known states" || no "no-resume list" "$bad"
want="$(printf '%s\n' $CM_STATES_NORESUME $CM_STATES_DEAD | sort | tr '\n' ' ')"
# the shared predicate cm_state_resumable is false for exactly the no-resume and dead states (and for an unknown state), true for every other known state
got="$(for s in $CM_STATES_ALL torn-down; do [ "$(jqb '$s | cm_state_resumable' --arg s "$s")" = true ] || printf '%s\n' "$s"; done | sort | tr '\n' ' ')"
want2="$(printf '%s\n' $CM_STATES_NORESUME $CM_STATES_DEAD torn-down | sort | tr '\n' ' ')"
[ "$got" = "$want2" ] && ok "cm_state_resumable is false for exactly CM_STATES_NORESUME, CM_STATES_DEAD and the legacy torn-down" || no "cm_state_resumable list" "got [$got] want [$want2]"
for f in resume.sh roster.sh; do
  if grep -q 'cm_state_resumable' "$HERE/../$f"; then ok "$f reads the shared cm_state_resumable predicate"; continue; fi
  got="$(grep -o 'IN("queued"[^)]*)' "$HERE/../$f" | head -1 | grep -o '"[a-z-]*"' | tr -d '"' | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] && ok "$f leaves out exactly CM_STATES_NORESUME and CM_STATES_DEAD" || no "$f state list" "got [$got] want [$want]"
done
# --- cm_state_dead
for s in gone repurposed torn-down; do
  [ "$(jqb '$s | cm_state_dead' --arg s "$s")" = true ] && ok "state $s is dead" || no "dead $s"
done
for s in $CM_STATES_LIVE ""; do
  [ "$(jqb '$s | cm_state_dead' --arg s "$s")" = false ] && ok "state \"$s\" is not dead" || no "not dead $s"
done
for v in null 0 true '["gone"]' '{"a":1}'; do
  [ "$(jqb "$v | cm_state_dead")" = false ] && ok "a state $v is not dead (it is not text)" || no "non-text state $v"
done
[ "$(jqb '"torn-down" | cm_state_norm' | tr -d '"')" = gone ] && ok "the legacy spelling torn-down reads as gone" || no "state norm"
[ "$(jqb '"running" | cm_state_norm' | tr -d '"')" = running ] && ok "any other state is left as it is" || no "state norm plain"
# --- the closed type table
GOOD='{"host":"local","path":"/w/a","worktree":"/w/a","lane":"pr","terminal":"t1","parent":"p","state":"running","sessionId":"s1","agent":"claude","model":"m","effort":"high","beadsEpic":"e","kind":"worker","standing":false,"adopted":true,"shouldRun":true,"resumeAttempts":0,"nudges":3,"loopIntervalMin":10,"stopHistory":[],"lastComment":"cm:running\nline two","task":"a task","current":"x","live":{"sessionId":"s1","agent":"claude","pid":123,"bypass":false,"lastTranscriptAt":"2026-01-01T00:00:00Z","checkedAt":1700000000},"health":{"word":"running","paneState":"busy","stopFromHealthy":false,"meaning":"fine\nsecond line"}}'
fok() { jq -c "$CM_JQ_NAME_DEFS"' cm_row_fields_ok' <<<"$1"; }
[ "$(fok "$GOOD")" = true ] && ok "a well-typed row, with multi-line free text, passes" || no "good row"
[ "$(fok '{}')" = true ] && ok "an empty row passes (absent is allowed)" || no "empty row"
[ "$(fok '{"host":null,"standing":null,"live":null,"health":null}')" = true ] && ok "null fields and a null live and health pass" || no "null fields"
for v in null 5 '"x"' true '[]'; do
  [ "$(fok "$v")" = false ] && ok "a row that is $v is refused" || no "row $v"
done
# every field of the three tables, with a wrong-typed value and, for a string field, a control character
for tbl in row live health; do
  for pair in $(jqb "cm_${tbl}_types | to_entries[] | \"\\(.key)=\\(.value)\"" | tr -d '"'); do
    k="${pair%%=*}"; t="${pair#*=}"
    case "$t" in
      string) wrongs='5|true|["a"]|{}' ;;
      boolean) wrongs='"true"|1|[]|{}' ;;
      count) wrongs='"1"|-1|1.5|true|[]' ;;
      array) wrongs='"a"|1|{}|true' ;;
      object) wrongs='"a"|1|[]|true' ;;
      text) wrongs='5|true|[]|{}' ;;
      time) wrongs='true|[]|{}' ;;
      *) wrongs='' ;;
    esac
    old="$IFS"; IFS='|'
    for w in $wrongs; do
      IFS="$old"
      if [ "$tbl" = row ]; then doc="{\"$k\":$w}"; else doc="{\"$tbl\":{\"$k\":$w}}"; fi
      [ "$(fok "$doc")" = false ] && ok "$tbl.$k ($t): $w is refused" || no "$tbl.$k $w"
    done
    IFS="$old"
    if [ "$t" = string ]; then
      for ch in '\u0000' '\u0009' '\u000a' '\u001b' '\u0085' '\u2028' '\u2029'; do
        if [ "$tbl" = row ]; then doc="{\"$k\":\"a${ch}b\"}"; else doc="{\"$tbl\":{\"$k\":\"a${ch}b\"}}"; fi
        [ "$(fok "$doc")" = false ] && ok "$tbl.$k: a control character $ch is refused" || no "$tbl.$k control $ch"
      done
    fi
  done
done
for v in '"x"' 5 '[]' true; do
  [ "$(fok "{\"live\":$v}")" = false ] && ok "a live that is $v is refused" || no "live $v"
  [ "$(fok "{\"health\":$v}")" = false ] && ok "a health that is $v is refused" || no "health $v"
done
[ "$(fok '{"live":{"checkedAt":1700000000.5}}')" = true ] && ok "a time may be a number" || no "time number"
[ "$(fok '{"unknownField":{"a":[1]}}')" = true ] && ok "a field outside the table is not judged" || no "extra field"
# --- cm_name_ok and cm_strip
for ch in '\u0000' '\u0009' '\u000b' '\u000a' '\u001b' '\u0085' '\u2028' '\u2029'; do
  [ "$(jqb '"a'"$ch"'b" | [cm_name_ok, (cm_strip == "ab")] | join(",")' | tr -d '"')" = "false,true" ] && ok "cm_name_ok refuses $ch and cm_strip drops it" || no "name $ch"
done
for n in 'a b' 'box-1.example' '/w/my dir/a.b' 'T-1.x_y' 'x\u00e9y' 'x\u200by'; do
  [ "$(jqb '"'"$n"'" | [cm_name_ok, (cm_strip == .)] | join(",")' | tr -d '"')" = "true,true" ] && ok "cm_name_ok accepts \"$n\" and cm_strip leaves it" || no "plain name $n"
done
[ "$(jqb '[5, null, true, [], {}] | map(cm_name_ok) | unique | join(",")' | tr -d '"')" = "false" ] && ok "a value that is not text is never a name" || no "non-text name"
[ "$(jqb '[5, null, "a\u0000b"] | map(cm_val_ok) | join(",")' | tr -d '"')" = "true,true,false" ] && ok "cm_val_ok passes a non-string and a plain string, refuses a string with a control character" || no "cm_val_ok"
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
