#!/usr/bin/env bash
# Does the suite actually catch anything? Each mutation below breaks one
# guarantee in a copy of the tree and re-runs the suite, which must fail. A
# mutation that survives means the assertions around it are decoration.
#
#   tests/mutants.sh            run every mutation
#   ORCH_TEST_MUTANTS=1 run.sh  run them from the suite
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "$HERE")"
KILLED=0; SURVIVED=0

# mutate <name> <file> <python-replacement-expression>
mutate() {
  local name="$1" rel="$2" old="$3" new="$4" tmp
  tmp="$(mktemp -d)"
  cp -R "$PLUGIN/." "$tmp/"
  if ! OLD="$old" NEW="$new" python3 - "$tmp/$rel" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in s:
    sys.exit(2)
p.write_text(s.replace(old, new, 1))
PY
  then
    printf 'SKIPPED %s (the line it mutates has moved)\n' "$name"
    rm -rf "$tmp"; return 0
  fi
  if env -u ORCH_TEST_MUTANTS "$tmp/tests/run.sh" >"$tmp/out.log" 2>&1; then
    printf 'SURVIVED %s: the suite stayed green with this broken\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  else
    printf 'killed %s (%s assertions went red)\n' "$name" "$(grep -c '^  FAIL' "$tmp/out.log")"
    KILLED=$((KILLED + 1))
  fi
  rm -rf "$tmp"
}

mutate "send confirmation" scripts/lib.sh \
  'if [ "${after:-0}" -gt "${before:-0}" ]; then res=delivered; else res=unconfirmed; fi' \
  'res=delivered'

mutate "dead-shell guard" scripts/lib.sh \
  'grep -Eq -- "$(agent_cfg "$(lane_field "$lane" agent)" shell_prompt '"'"'\$ $'"'"')"; then' \
  'grep -Eq -- '"'"'zzz-no-shell-prompt-ever'"'"'; then'

mutate "trunk base wall" scripts/lib.sh \
  '[ "$base" = "$trunk" ] || { refuse merge-wrong-base' \
  '[ "$base" != "" ] || { refuse merge-wrong-base'

mutate "owner requirement" scripts/lib.sh \
  '  if [ ! -s "$OWNER" ]; then
    refuse owner-unclaimed' \
  '  if false; then
    refuse owner-unclaimed'

mutate "head sha pin" scripts/lib.sh \
  '[ "$head" = "$want" ] || { refuse merge-sha-mismatch' \
  '[ -n "$head" ] || { refuse merge-sha-mismatch'

mutate "ambiguous rebind refusal" scripts/lib.sh \
  '    if [ "$(printf '"'"'%s\n'"'"' "$handle" | grep -c .)" != 1 ]; then' \
  '    handle="$(printf '"'"'%s\n'"'"' "$rows" | head -1 | cut -f1)"
    if false; then'

mutate "pre-merge re-read" scripts/lib.sh \
  '  view2="$(gh pr view "$pr" --json state,baseRefName,headRefOid 2>/dev/null)"' \
  '  view2="$(printf '"'"'{"state":"OPEN","baseRefName":"%s","headRefOid":"%s"}'"'"' "$base" "$head")"'

mutate "STOP read during the wait" scripts/orchestrate.sh \
  '      [ -f "$STOP" ] && break
      sleep 1; slept=$((slept + 1))' \
  '      sleep 1; slept=$((slept + 1))'

mutate "owed state exhaustiveness" scripts/lib.sh \
  '      *) printf '"'"'%s\t%s\t%s\n'"'"' "$lane" "$pr" "owed-unknown" ;;' \
  '      *) ;;'

mutate "token ownership" scripts/lib.sh \
  '  owner_is_ours && return 0' \
  '  return 0'

printf '\n%s killed, %s survived\n' "$KILLED" "$SURVIVED"
[ "$SURVIVED" = 0 ] || exit 1
exit 0
