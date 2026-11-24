#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# input-migrate.sh (test): scripts/input-migrate-manifest.sh, the read-only dry-run manifest of the typed input boundary.
# What it must list, that it writes nothing (the ledger bytes, no lock, no backup ring, no temp file), and its exit codes.
#
#   scripts/test/input-migrate.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-input-migrate.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_LEDGER_BAK_KEEP CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_EXCLUDE_REPOS CM_PATH_MATCH
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME" "$CM_HOME"
M="$HERE/../input-migrate-manifest.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s%s\n' "$1" "${2:+: $2}"; }
L="$CM_HOME/ledger.json"
mf() { printf '%s' "$1" > "$L"; "$M" --json "$L" 2>"$ROOT/err"; }
# a clean v2 ledger: exit 0, clean true
out="$(mf '{"schemaVersion":2,"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"pr","owner":"owner-1","state":"open","issue":12}],"asks":[{"id":"x","state":"open"}],"lanes":{"pr":{"state":"running","lead":"a"}}}')"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = true ] && ok "a fully typed ledger is clean (exit 0)" || no "clean ledger" "rc=$rc $out"
# each thing the stamp must settle
out="$(mf '{"workers":{"a":{"path":"/w/a"}}}')"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.workers[0].missing | join(",")')" = "state,standing,host" ] && ok "missing state, standing and host are listed per worker" || no "missing keys" "$out"
out="$(mf '{"workers":{"a":{"host":"local","worktree":"/w/a","state":"running","standing":false},"b":{"host":"local","worktreePath":"/w/b","state":"running","standing":false}}}')"
[ "$(printf '%s' "$out" | jq -r '[.workers[].aliasToMove.from] | join(",")')" = "worktree,worktreePath" ] && ok "path aliases to move to path are listed" || no "aliases" "$out"
out="$(mf '{"workers":{"a":{"host":"local","path":"/w/a","state":"torn-down","standing":false}}}')"
[ "$(printf '%s' "$out" | jq -r '.workers[0].stateSpelling | "\(.from)>\(.to)"')" = "torn-down>gone" ] && ok "a legacy state spelling is listed with its state" || no "spelling" "$out"
out="$(mf '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}},"followUps":[{"id":"f","worker":"a","issue":"#12"},{"id":"g","worker":"a","issue":"7"},{"id":"h","worker":"a","issue":"none"},{"id":"i","worker":"a","issue":3}]}')"
[ "$(printf '%s' "$out" | jq -r '[.followUpIssues[] | "\(.followUp)=\(.asNumber)"] | join(",")')" = "f=12,g=7" ] && ok "issue text like #12 and 7 is listed with its number (none and a real number are not)" || no "issue text" "$out"
out="$(mf '{"workers":{},"asks":[{"id":"a"},{"id":"a"},{"state":"open"},{"id":" "},{"id":"ok"}]}')"
[ "$(printf '%s' "$out" | jq -r '.asksWithoutId | length')" = 4 ] && ok "asks with a blank, missing or duplicate id are listed" || no "asks" "$out"
out="$(mf '{"workers":{"a":{"host":"local","terminal":"t1","state":"running","standing":false}}}')"
[ "$(printf '%s' "$out" | jq -r '.workers[0].terminalOnly')" = true ] && ok "a terminal-only row is listed" || no "terminal-only" "$out"
out="$(mf '{"workers":{"a":null,"b":{"host":false,"path":"/w/b","state":"zzz","standing":"yes"}}}')"
[ "$(printf '%s' "$out" | jq -r '[.workers[] | .worker + ":" + (.invalid | map(.field) | join("/"))] | join(",")')" = "a:,b:host/state/standing" ] && ok "invalid fields and an unreadable row are listed" || no "invalid" "$out"
out="$(mf '{"schemaVersion":2,"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false,"state":"done"}}}')"
[ "$(printf '%s' "$out" | jq -r '.repeatedKeys | length')" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && ok "a key written twice makes it not clean" || no "repeated" "$out"
out="$(mf '{"schemaVersion":"2","workers":{}}')"
[ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && ok "an invalid schemaVersion is not clean" || no "bad version" "$out"
out="$(mf '{"workers":[]}')"
[ "$(printf '%s' "$out" | jq -r '.containerIssues | length')" = 1 ] && ok "workers that is a list is listed as a container issue" || no "container" "$out"
# text mode
txt="$(printf '%s' '{"workers":{"a":{"worktree":"/w/a"}}}' > "$L"; "$M" "$L")"
case "$txt" in *"worker a: missing state, standing, host; move worktree to path"*"not clean"*) ok "text mode names the worker and what to settle" ;; *) no "text mode" "$txt" ;; esac
# exit codes
"$M" "$ROOT/none.json" >/dev/null 2>&1; [ $? = 2 ] && ok "a missing ledger is exit 2" || no "missing exit"
printf 'nope' > "$L"; "$M" "$L" >/dev/null 2>&1; [ $? = 2 ] && ok "a ledger that is not JSON is exit 2" || no "not json exit"
# READ ONLY: bytes unchanged, no lock, no backup ring, no stray file, mtime untouched
printf '%s' '{"workers":{"a":{"worktree":"/w/a","state":"torn-down"}},"asks":[{"state":"open"}]}' > "$L"
touch -d '2020-01-01 00:00:00' "$L"; before="$(cksum < "$L") $(stat -c %Y "$L" 2>/dev/null || stat -f %m "$L")"; ls -A "$CM_HOME" > "$ROOT/ls.before"
"$M" "$L" >/dev/null 2>&1; "$M" --json "$L" >/dev/null 2>&1
after="$(cksum < "$L") $(stat -c %Y "$L" 2>/dev/null || stat -f %m "$L")"; ls -A "$CM_HOME" > "$ROOT/ls.after"
[ "$before" = "$after" ] && ok "the ledger bytes and mtime are untouched" || no "ledger changed" "$before / $after"
cmp -s "$ROOT/ls.before" "$ROOT/ls.after" && ok "no lock, backup ring or temp file is created next to the ledger" || no "stray files" "$(diff "$ROOT/ls.before" "$ROOT/ls.after")"
# a missing required container or follow-up field is not clean, and every member is rendered
for d in '{"workers":null}' '{}' '{"workers":{}}' '{"workers":{},"asks":[],"followUps":[]}' '{"workers":{},"asks":[],"lanes":{}}'; do
  out="$(mf "$d")"; rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && [ "$(printf '%s' "$out" | jq -r '.missingContainers | length')" -ge 1 ] && ok "required container missing is not clean: $d" || no "missing container $d" "rc=$rc $out"
done
out="$(mf '{"workers":{},"asks":[],"followUps":[],"lanes":{}}')"; rc=$?
[ "$rc" = 0 ] && ok "empty required containers are clean" || no "empty containers clean" "$out"
out="$(mf '{"workers":{},"asks":[],"lanes":{},"followUps":[{"id":"f","worker":"a"}]}')"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.members[0].missing | join(",")')" = "lane,owner,state" ] && ok "a follow-up without lane, owner and state is not clean and lists them" || no "followup required" "$out"
txt="$(printf '%s' '{"workers":{},"asks":[],"lanes":{},"followUps":[null,{"id":5}]}' > "$L"; "$M" "$L")"
case "$txt" in *"followUps[0]: unreadable (the row is null"*"followUps[1]: missing worker, lane, owner, state; invalid id (not non-blank text"*"2 other members"*) ok "text mode renders every unreadable member with its identity and reason" ;; *) no "text members" "$txt" ;; esac
txt="$(printf '%s' '{"workers":null}' > "$L"; "$M" "$L")"
case "$txt" in *"workers: absent or null"*"4 missing containers"*) ok "text mode names a missing container" ;; *) no "text containers" "$txt" ;; esac
# an invalid worker field prints its reason, not only its name
txt="$(printf '%s' '{"workers":{"a":{"host":false,"path":"/w/a","state":"zzz","standing":"yes"},"b":{"host":"local","state":"running","standing":false}},"asks":[],"followUps":[],"lanes":{}}' > "$L"; "$M" "$L")"
case "$txt" in *"worker a: invalid host (not a plain host name"*"state (not a known state)"*"standing (not a boolean"*) ok "text mode gives each invalid worker field with its reason" ;; *) no "worker field reasons" "$txt" ;; esac
case "$txt" in *"worker b: missing path"*) ok "text mode names a missing worker field" ;; *) no "worker missing" "$txt" ;; esac
# a repeated key in, or an invalid value of, freeze or health is not clean (an absent one is fine)
B='"workers":{},"asks":[],"followUps":[],"lanes":{}'
for d in "{$B,\"freeze\":{\"state\":\"off\"},\"health\":{}}" "{$B}" "{$B,\"freeze\":null,\"health\":null}"; do
  out="$(mf "$d")"; rc=$?
  [ "$rc" = 0 ] && ok "a readable or absent freeze and health stay clean: $d" || no "freeze health clean $d" "rc=$rc $out"
done
for d in "{$B,\"freeze\":\"on\"}" "{$B,\"freeze\":[]}" "{$B,\"freeze\":{\"state\":\"maybe\"}}" "{$B,\"freeze\":{}}" "{$B,\"freeze\":{\"state\":true}}" "{$B,\"health\":[1]}" "{$B,\"health\":\"ok\"}" "{$B,\"freeze\":{\"state\":\"off\",\"state\":\"on\"}}" "{$B,\"freeze\":{\"state\":\"on\"},\"freeze\":{\"state\":\"off\"}}" "{$B,\"health\":{\"x\":1,\"x\":2}}"; do
  out="$(mf "$d")"; rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && [ "$(printf '%s' "$out" | jq -r '[.containerIssues[] | select(.sourcePath == "freeze" or .sourcePath == "health")] | length')" -ge 1 ] && ok "freeze or health unreadable is not clean and is named: $d" || no "freeze health $d" "rc=$rc $out"
done
txt="$(printf '%s' "{$B,\"freeze\":{\"state\":\"maybe\"}}" > "$L"; "$M" "$L")"
case "$txt" in *"freeze"*"not on or off"*) ok "text mode names the freeze problem" ;; *) no "freeze text" "$txt" ;; esac
# the manifest is not clean where the decisions still hold, and says why
CW='"host":"local","path":"/w/c","state":"done","standing":false'
WK='"a":{"host":"local","path":"/w/a","state":"done","standing":false}'
mk() { printf '{"workers":{%s},"asks":[],"followUps":[%s],"lanes":{}%s}' "$1" "${2:-}" "${3:-}"; }
for d in "$(mk "$WK,\"c\":{$CW,\"parent\":\"c\"}")" "$(mk "$WK,\"x\":{$CW,\"parent\":\"y\"},\"y\":{$CW,\"parent\":\"x\"}")" "$(mk "$WK,\"b\":{$CW,\"parent\":false},\"c\":{$CW,\"parent\":\"b\"}")"; do
  out="$(mf "$d")"; rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && [ "$(printf '%s' "$out" | jq -r '.parentProblems | length')" -ge 1 ] && ok "a worker whose parent chain cannot be placed is not clean and is listed: $(printf '%s' "$d" | cut -c1-90)" || no "parent problems $d" "rc=$rc $out"
done
out="$(mf "$(mk "$WK,\"x\":{$CW,\"parent\":\"y\"},\"y\":{$CW,\"parent\":\"x\"},\"c\":{$CW,\"parent\":\"x\"}")")"
[ "$(printf '%s' "$out" | jq -r '[.parentProblems[] | select(.worker == "c") | .why] | join(",")')" = "its parent chain loops" ] && ok "a worker that hangs off a loop says the chain loops" || no "loop why" "$out"
out="$(mf "$(mk "$WK,\"c\":{$CW,\"parent\":\"c\"}")")"
[ "$(printf '%s' "$out" | jq -r '.parentProblems[0].why')" = "is its own parent" ] && ok "a self-parent says so" || no "self parent why" "$out"
txt="$(mk "$WK,\"c\":{$CW,\"parent\":\"c\"}" > "$L"; "$M" "$L")"
case "$txt" in *"worker c: is its own parent"*) ok "text mode names the parent problem" ;; *) no "parent text" "$txt" ;; esac
out="$(mf "$(mk "$WK,\"c\":{$CW,\"parent\":\"gone\"}")")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '.danglingParents')" = '[{"worker":"c","parent":"gone"}]' ] && ok "a dangling parent is REPORTED and does not make the manifest unclean (the root of its own family)" || no "dangling" "rc=$rc $out"
txt="$(mk "$WK,\"c\":{$CW,\"parent\":\"gone\"}" > "$L"; "$M" "$L")"
case "$txt" in *"worker c: parent gone has no row"*) ok "text mode reports the dangling parent" ;; *) no "dangling text" "$txt" ;; esac
FU1='{"id":"f","worker":"a","lane":"l","owner":"o","state":"open"}'
out="$(mf "$(mk "$WK" "$FU1,$FU1")")"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.duplicateFollowUpIds[0].id')" = f ] && ok "two follow-ups with one id are not clean and the id is listed" || no "dup follow-up ids" "rc=$rc $out"
out="$(mf "$(mk "$WK" "$FU1,{\"id\":\"g\",\"worker\":\"a\",\"lane\":\"l\",\"owner\":\"o\",\"state\":\"open\"}")")"; rc=$?
[ "$rc" = 0 ] && ok "distinct follow-up ids are clean" || no "distinct ids" "rc=$rc $out"
for fz in '{"state":"off","ttl":7}' '{"state":"on","ttl":"tomorrow"}' '{"state":"on","ttl":"2026-11-21T10:00:00Z\n"}' '{"state":"off","window":7}'; do
  out="$(mf "$(mk "$WK" "" ",\"freeze\":$fz")")"; rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '[.containerIssues[] | select(.sourcePath | startswith("freeze"))] | length')" -ge 1 ] && ok "freeze $fz is not clean and is named" || no "freeze $fz" "rc=$rc $out"
done
for fz in '{"state":"on","ttl":"2026-11-21T10:00:00Z","window":"09:00-11:00"}' '{"state":"off"}'; do
  out="$(mf "$(mk "$WK" "" ",\"freeze\":$fz")")"; rc=$?
  [ "$rc" = 0 ] && ok "freeze $fz is clean" || no "freeze ok $fz" "rc=$rc $out"
done
# a lone surrogate (jq reads it as U+FFFD, so two keys that differ only there are one key to jq) is an unreadable ledger (exit 2, the same as NaN), and a pair is clean
out="$(mf '{"schemaVersion":2,"lanes":{"p":{"lead":"a"},"p":{"state":"idle"}},"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}},"followUps":[],"asks":[]}')"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && ok "control: two equal lane keys are not clean" || no "lone surrogate ascii twin" "rc=$rc $out"
out="$(mf '{"schemaVersion":2,"lanes":{"p\udc00":{"lead":"a"},"p\udfff":{"state":"idle"}},"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}},"followUps":[],"asks":[]}')"; rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && grep -q "not one readable JSON object" "$ROOT/err" && ok "two lane keys that differ only in a lone surrogate: exit 2, the ledger is unreadable (never clean)" || no "lone surrogate surrogate twin" "rc=$rc $out $(cat "$ROOT/err")"
out="$(mf '{"schemaVersion":2,"workers":{"a\udc00":{"host":"local","path":"/w/a","standing":false,"state":"done"},"a\udfff":{"host":"local","path":"/w/b","standing":false,"state":"done"}},"lanes":{},"followUps":[],"asks":[]}')"; rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && grep -q "not one readable JSON object" "$ROOT/err" && ok "two worker keys that differ only in a lone surrogate: exit 2, the ledger is unreadable (never clean)" || no "lone surrogate worker twin" "rc=$rc $out $(cat "$ROOT/err")"
out="$(mf '{"schemaVersion":2,"workers":{"a":{"host":"local","path":"/w/a","standing":false,"state":"running","note":"\ud83d\ude00"}},"followUps":[],"asks":[],"lanes":{"p\ud83d\ude00":{"state":"running","lead":"a"}}}')"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = true ] && ok "control: a surrogate pair is clean" || no "lone surrogate pair" "rc=$rc $out"
# the manifest checks the OPERATIONAL fields of the closed type table too (agent, live.*, health.*, counters, times), the same test as cm_row_fields_ok.
# A worker with valid host, path, state and standing but agent:["agent-a"] and live:"broken" is not clean. Controls: a well-typed agent, live and health stay clean.
CT='"schemaVersion":2,"asks":[],"followUps":[],"lanes":{}'
WK='"host":"local","path":"/w/a","state":"running","standing":false'
out="$(mf "{$CT,\"workers\":{\"a\":{$WK,\"agent\":\"agent-a\",\"live\":{\"pid\":3,\"model\":\"m\"},\"health\":{\"word\":\"ok\"},\"nudges\":2}}}")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = true ] && ok "well-typed agent, live, health and counters are clean" || no "manifest control" "rc=$rc $out"
out="$(mf "{$CT,\"workers\":{\"a\":{$WK,\"agent\":[\"agent-a\"],\"live\":\"broken\"}}}")"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && [ "$(printf '%s' "$out" | jq -r '.workers[0].invalid | map(.field) | sort | join(",")')" = "agent,live" ] && ok "agent:[\"agent-a\"] and live:\"broken\" are listed and the ledger is not clean" || no "manifest agent/live" "rc=$rc $out"
. "$HERE/../lib.sh"
RJ="$(mktemp "$ROOT/rowj.XXXXXX")"; jq -n "$CM_JQ_NAME_DEFS"'{agent: ["agent-a"], live: "broken"} | cm_row_fields_ok' > "$RJ"
[ "$(cat "$RJ")" = false ] && ok "cm_row_fields_ok refuses that same row (the manifest and the closed type table agree)" || no "manifest parity" "$(cat "$RJ")"
for c in 'nudges:-1' 'nudges:"2"' 'resumeAttempts:1.5' 'loopIntervalMin:"10"' 'standing:"no"' 'live:{"pid":"x"}' 'live:{"bypass":"yes"}' 'live:[]' 'health:{"stopFromHealthy":"false"}' 'health:[]' 'agent:"cla\nude"' 'health:{"word":"a\u0001"}' 'live:{"handle":"t x"}'; do
  k="${c%%:*}"; v="${c#*:}"
  out="$(mf "{$CT,\"workers\":{\"a\":{$WK,\"$k\":$v}}}")"; rc=$?
  want="$(jq -n "$CM_JQ_NAME_DEFS"'(('"{$WK,\"$k\":$v}"') | cm_row_fields_ok)')"
  [ "$want" = false ] && [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && ok "$c is not clean and cm_row_fields_ok agrees" || no "manifest $c" "rc=$rc want=$want $out"
done
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
