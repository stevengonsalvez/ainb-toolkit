#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# input-parity.sh (test): for WELL-TYPED input the typed boundary (scripts/input-view.jq) must decide exactly as today's reader does.
# Each reference below is the jq idiom a program uses today, copied from it:
#   resume candidate  roster.sh: (.state // "running") not in the no-resume list, plus runtime-check.sh: .standing == true and (.host // "local") == "local"
#   teardown hold     teardown.sh and followups.sh: a follow-up with state != "done" and (.issue // .issueUrl) == null
#   teardown standing a row with standing == true is never torn down
# The grid is every state spelling x standing x host and every well-typed follow-up escalation. Invalid input is test/input-matrix.sh.
#
#   scripts/test/input-parity.sh      # exit 0 when every case matches
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-input-parity.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
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
L="$ROOT/l.json"
STATES="$CM_STATES_ALL $(printf '%s\n' $CM_STATES_LEGACY | cut -d= -f1 | tr '\n' ' ')"
# --- resume: one ledger, one worker per (state, standing, host)
ws='{}'
for s in $STATES; do for st in true false; do for h in local host-a; do
  ws="$(printf '%s' "$ws" | jq -c --arg k "w-$s-$st-$h" --arg s "$s" --argjson st "$st" --arg h "$h" '.[$k] = {host: $h, path: ("/w/" + $k), state: $s, standing: $st}')"
done; done; done
printf '{"workers":%s}' "$ws" > "$L"
view="$ROOT/view.json"; cm_input_view "$L" > "$view"
want="$(jq -r "$CM_JQ_STATE_DEFS"'.workers | to_entries[] | select((.value.state // "running") | cm_state_resumable) | select(.value.standing == true and ((.value.host // "local") == "local")) | .key' "$L" | sort)"
got=""; n=0
for k in $(jq -r '.workers | keys[]' "$L"); do
  n=$((n + 1))
  if cm_input_decide resume "$k" --view-file "$view" >/dev/null; then got="$got$k"$'\n'; fi
done
got="$(printf '%s' "$got" | sort)"
if [ "$got" = "$want" ]; then ok "resume: $n well-typed rows (every state, standing, host) decide as resume.sh does"; else no "resume parity" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -5 | tr '\n' ' ')"; fi
# --- absent state and absent host read as today's defaults while the ledger is legacy
printf '%s' '{"workers":{"a":{"path":"/w/a","standing":true}}}' > "$L"
cm_input_decide resume a "$L" >/dev/null && ok "legacy: absent state and host resume like (.state // running) and (.host // local)" || no "legacy defaults"
# --- teardown: the escalation of a follow-up
for esc in none issue url; do
  for fs in open "done"; do
  case "$esc" in none) e='' ;; issue) e=',"issue":12' ;; url) e=',"issueUrl":"https://github.com/o/r/issues/12"' ;; esac
  printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","state":"%s"%s}]}' "$fs" "$e" > "$L"
  legacy_hold="$(jq -r '[ .followUps[] | select(.state != "done" and ((.issue // .issueUrl) == null) and (.worker == "a")) ] | length > 0' "$L")"
  if cm_input_decide teardown a "$L" >/dev/null; then new_hold=false; else new_hold=true; fi
  [ "$legacy_hold" = "$new_hold" ] && ok "teardown: follow-up $fs, escalation $esc: hold=$new_hold as teardown.sh" || no "follow-up $fs $esc" "legacy hold=$legacy_hold new hold=$new_hold"
  done
done
# --- teardown: a standing row is never torn down, a plain finished one is
for st in true false; do
  printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":%s}}}' "$st" > "$L"
  if cm_input_decide teardown a "$L" >/dev/null; then got=permit; else got=refuse; fi
  [ "$st" = true ] && w=refuse || w=permit
  [ "$got" = "$w" ] && ok "teardown: standing $st -> $got" || no "teardown standing $st" "got $got want $w"
done
# --- nudge: every live state is nudged, every other is not (cm_state_resumable is the same list)
printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}}}' > "$L"
bad=0
for s in $STATES; do
  printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"%s","standing":false}}}' "$s" > "$L"
  legacy="$(jq -r "$CM_JQ_STATE_DEFS"'.workers.a.state | cm_state_resumable' "$L")"
  if cm_input_decide nudge a "$L" >/dev/null; then new=true; else new=false; fi
  [ "$legacy" = "$new" ] || { bad=1; no "nudge parity for state $s" "legacy $legacy new $new"; }
done
[ "$bad" = 0 ] && ok "nudge: every state spelling decides as cm_state_resumable" || true
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
