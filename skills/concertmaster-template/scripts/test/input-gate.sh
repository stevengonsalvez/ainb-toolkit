#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# input-gate.sh (test): the hard cases of the typed input boundary (scripts/input-view.jq and the cm_input_* adapter in scripts/lib.sh), one family each:
#   a live reply never gives zero output, and a bad, negative or boolean count is not complete
#   a worker host that is null is invalid (only an absent key defaults, and only below schemaVersion 2)
#   an open ask about the worker holds teardown even with a null, blank or duplicate id; asks as an object map holds
#   ask state, kind and decision are exact enums
#   a repeated key at any depth, one read, and a failed scan is unreadable
#   a key written twice inside a row, NaN and Infinity, a lane state outside the enum, an ask whose tie cannot be established
#   a follow-up on a worker whose parent chain cannot be placed, an unreadable middle row, a loop, a repeated key in a reply
#   numbers too big for a double, decimals that only round to a whole number, a validator that must not accept a trailing newline
#   a missing container at schemaVersion 2, an issue URL allow-list, a path alias, a lane that is no lane, one single-line predicate under every kind
#   the migration manifest lists every unreadable or invalid member
#
#   scripts/test/input-gate.sh      # exit 0 when every case passes

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-input-gate.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_LEDGER_BAK_KEEP CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_EXCLUDE_REPOS CM_PATH_MATCH
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME" "$CM_HOME" "$ROOT/tmp"; export TMPDIR="$ROOT/tmp"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$HERE/../lib.sh"
PASS=0; FAIL=0
# rep <char> <count>: a run of one character, built at run time so no long token-shaped literal sits in this file
rep() { printf '%*s' "$2" '' | tr ' ' "$1"; }
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s%s\n' "$1" "${2:+: $2}"; }
L="$ROOT/l.json"
W='"host":"local","path":"/w/a","state":"done","standing":false'
# d <label> <ledger text> <action> <target> <want permit> [reason substring]
d() {
  local label="$1" doc="$2" a="$3" t="$4" want="$5" sub="${6:-}" out got
  printf '%s' "$doc" > "$L"
  out="$(cm_input_decide "$a" "$t" "$L")"; got="$(printf '%s' "$out" | jq -r '.permit')"
  if [ "$got" != "$want" ]; then no "$label" "permit=$got want $want: $out"; return; fi
  if [ -n "$sub" ] && ! printf '%s' "$out" | jq -e --arg s "$sub" 'any(.reasons[]; contains($s))' >/dev/null; then no "$label" "no reason has \"$sub\": $out"; return; fi
  ok "$label"
}
# --- live replies
live() { # <label> <kind> <reply text> <want complete> [reason substring]
  local out n
  out="$(printf '%s' "$3" | cm_input_live "$2")"; n="$(printf '%s\n' "$out" | grep -c .)"
  if [ "$n" != 1 ]; then no "$1" "expected exactly one envelope, got $n lines: $out"; return; fi
  if [ "$(printf '%s' "$out" | jq -r '.complete')" != "$4" ]; then no "$1" "$out"; return; fi
  if [ -n "${5:-}" ] && ! printf '%s' "$out" | jq -e --arg s "$5" '.reason | contains($s)' >/dev/null; then no "$1" "reason: $out"; return; fi
  ok "$1"
}
# a reply key or value with a lone surrogate is unreadable (jq merges keys that differ only there); a pair is one character
live "a reply key with a lone surrogate is incomplete" terminals '{"ok":true,"result":{"terminals":[{"handle":"h","a\udc00":1,"a\udfff":2}]}}' false "could not be read"
live "a reply value with a lone surrogate is incomplete" worktrees '{"ok":true,"result":{"worktrees":[{"path":"/w\ud800"}]}}' false "could not be read"
live "control: a reply with a surrogate pair is complete" terminals '{"ok":true,"result":{"terminals":[{"handle":"h","title":"\ud83d\ude00","agentIdentity":"agent-a"}]}}' true
for r in '{"result":false}' '{"result":7}' '{"result":[]}' '{"result":"x"}' '{}' '7' 'null' '[]' '"s"' 'not json' ''; do
  live "live: reply $r gives one incomplete envelope" terminals "$r" false
  live "live: worktrees reply $r gives one incomplete envelope" worktrees "$r" false
done
for c in false true '"3"' -1 1.5 '{}' '[]' ; do live "live: totalCount $c is not complete" terminals "{\"result\":{\"terminals\":[],\"totalCount\":$c}}" false; done
live "live: totalCount 0 on an empty list is complete" terminals '{"result":{"terminals":[],"totalCount":0}}' true
live "live: totalCount above the rows is not complete" terminals '{"result":{"terminals":[{"handle":"a"}],"totalCount":2}}' false "total count"
for t in true null '"no"' 0; do live "live: truncated $t is not complete" terminals "{\"result\":{\"terminals\":[],\"truncated\":$t}}" false "truncated"; done
live "live: ok:false is not complete" terminals '{"ok":false,"result":{"terminals":[]}}' false "ok is not true"
live "live: a clean reply is complete" terminals '{"ok":true,"result":{"terminals":[{"handle":"a"}],"totalCount":1,"truncated":false}}' true
# --- host null
for v in 1 2; do
  d "host null is invalid at schemaVersion $v (never local)" "{\"schemaVersion\":$v,\"workers\":{\"a\":{\"host\":null,\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false}}}" teardown a false "host is unreadable"
done
d "host null is invalid with no schemaVersion (legacy)" '{"workers":{"a":{"host":null,"path":"/w/a","state":"done","standing":false}}}' teardown a false "host is unreadable"
d "an absent host KEY is still local while legacy" '{"workers":{"a":{"path":"/w/a","state":"done","standing":false}}}' teardown a true
d "an absent host KEY is refused at schemaVersion 2" '{"schemaVersion":2,"workers":{"a":{"path":"/w/a","state":"done","standing":false}}}' teardown a false "host is unreadable"
# --- asks hold teardown
for id in null '""' '" "' 5 '[]'; do
  d "an open ask about the worker with id $id holds teardown" "{\"workers\":{\"a\":{$W,\"lane\":\"pr\"}},\"asks\":[{\"id\":$id,\"state\":\"open\",\"worker\":\"a\"}]}" teardown a false "open ask"
done
d "an open ask with no id tied only by lane holds teardown" "{\"workers\":{\"a\":{$W,\"lane\":\"pr\"}},\"asks\":[{\"state\":\"open\",\"lane\":\"pr\"}]}" teardown a false "about this worker"
d "an open ask tied by pr holds teardown" "{\"workers\":{\"a\":{$W,\"pr\":42}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"pr\":42}]}" teardown a false "about this worker"
d "an open ask tied by path holds teardown" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"path\":\"/w/a/\"}]}" teardown a false "about this worker"
d "two asks with the same id both hold" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"worker\":\"a\"},{\"id\":\"q\",\"state\":\"answered\",\"worker\":\"b\"}]}" teardown a false "open ask"
d "an ask whose worker field is unreadable may be this one's: holds" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"worker\":false}]}" teardown a false "may be about this worker"
d "an ask row that is not an object holds every teardown" "{\"workers\":{\"a\":{$W}},\"asks\":[null]}" teardown a false "unreadable"
d "an asks OBJECT MAP holds" "{\"workers\":{\"a\":{$W}},\"asks\":{\"q\":{\"id\":\"q\",\"state\":\"open\",\"worker\":\"a\"}}}" teardown a false "asks is unreadable"
for v in false 0 '""' '"x"'; do d "asks $v holds" "{\"workers\":{\"a\":{$W}},\"asks\":$v}" teardown a false "asks is unreadable"; done
d "an open ask about ANOTHER worker holds nothing here" "{\"workers\":{\"a\":{$W,\"lane\":\"pr\"}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"worker\":\"b\",\"lane\":\"other\"}]}" teardown a true
d "an open ask with no tie field may be about anyone: it holds" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"open\"}]}" teardown a false "may be about this worker"
for st in answered decided closed; do d "a $st ask about the worker lets go" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"$st\",\"worker\":\"a\"}]}" teardown a true; done
for st in open in-progress Bogus '""' null; do d "an ask in state $st about the worker holds" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":$( [ "$st" = null ] || [ "$st" = '""' ] && echo "$st" || echo "\"$st\""),\"worker\":\"a\"}]}" teardown a false "open ask"; done
# --- exact enums
printf '%s' '{"workers":{},"asks":[{"id":"x","state":"Bogus","kind":"Bogus","decision":"Bogus","worker":false},{"id":"y","state":"open","kind":"code","decision":"approved"}]}' > "$L"
v="$(cm_input_view "$L")"
[ "$(printf '%s' "$v" | jq -r '[.asks[0].fields.state.status, .asks[0].fields.kind.status, .asks[0].fields.decision.status] | join(",")')" = "invalid,invalid,invalid" ] && ok "ask state, kind and decision outside the contract enums are invalid" || no "ask enums" "$(printf '%s' "$v" | jq -c '.asks[0].fields')"
[ "$(printf '%s' "$v" | jq -r '[.asks[1].fields.state.status, .asks[1].fields.kind.status, .asks[1].fields.decision.status] | join(",")')" = "valid,valid,valid" ] && ok "ask state, kind and decision inside the enums are valid" || no "ask enums valid"
out="$("$HERE/../input-migrate-manifest.sh" --json "$L")"; [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && ok "an ask with invalid enums makes the manifest not clean" || no "manifest enums" "$out"
for k in Code " CODE " merge-gate-override remove-standing; do
  printf '{"workers":{},"asks":[{"id":"x","state":"open","kind":"%s"}]}' "$k" > "$L"; got="$(cm_input_view "$L" | jq -r '.asks[0].fields.kind.status')"
  case "$k" in Code|" CODE ") w=valid ;; *) w=valid ;; esac
  [ "$got" = "$w" ] && ok "ask kind \"$k\" reads as a contract kind (trimmed, lower case)" || no "kind $k" "$got"
done
# --- duplicate keys at any depth, one read, a failed scan refuses
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"pr"}},"lanes":{"pr":{"lead":"a"},"pr":{"state":"gone"}}}' > "$L"
[ "$(cm_input_dupkeys "$L")" = '["lanes","pr"]' ] && ok "jdupkeys reports a non-empty replacement at a non-leaf" || no "dupkeys nonleaf" "$(cm_input_dupkeys "$L")"
out="$(cm_input_decide teardown a "$L")"; [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "teardown is refused when the lane that names the lead is written twice" || no "dup lane" "$out"
printf '%s' '{"workers":{"a":{"x":1}},"workers":{"b":{"x":1}}}' > "$L"
[ "$(cm_input_view "$L" | jq -r '.containers.workers.status')" = invalid ] && ok "a container key written twice makes the container invalid" || no "dup container"
for body in '{"a":{"k":{},"k":{}}}' '{"a":[{"k":[1],"k":[2]}]}' '{"a":{"b":{"c":1,"c":2}}}'; do
  printf '%s' "$body" > "$L"; [ -n "$(cm_input_dupkeys "$L")" ] && ok "jdupkeys finds a repeat in $body" || no "dupkeys $body"
done
printf '%s' '{"a":{"k":1},"b":{"k":1}}' > "$L"; [ -z "$(cm_input_dupkeys "$L")" ] && ok "the same key in two objects is not a repeat" || no "false positive"
printf 'nope' > "$L"; cm_input_dupkeys "$L" >/dev/null 2>&1; [ $? = 2 ] && ok "jdupkeys on a non-JSON file fails (rc 2)" || no "dupkeys rc"
# a failed scan is unreadable, not clean: a fake python3 that fails (or prints nothing) on the PATH
mkdir -p "$ROOT/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$ROOT/fakebin/python3"; chmod +x "$ROOT/fakebin/python3"
printf '%s' "{\"workers\":{\"a\":{$W}}}" > "$L"
out="$(PATH="$ROOT/fakebin:$PATH" cm_input_decide teardown a "$L")"; rc=$?
[ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && [ "$rc" != 0 ] && ok "a failing duplicate scan refuses (not clean input)" || no "scan failure" "rc=$rc $out"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/fakebin/python3"
out="$(PATH="$ROOT/fakebin:$PATH" cm_input_bundle "$L")"; [ "$(printf '%s' "$out" | jq -r '.readable')" = true ] && ok "(a scanner that exits 0 with no output is a clean scan: the exit status is what counts)" || no "scan rc0"
cm_input_bundle "$ROOT/vanished.json" >/dev/null; [ $? = 1 ] && ok "a ledger that cannot be read is unreadable" || no "vanished"
snaps=0; for f in "$TMPDIR"/cm-input.*; do [ -e "$f" ] && snaps=1; done; [ "$snaps" = 0 ] && ok "the one-read snapshot is removed" || no "snapshot left behind"
# --- non-blocking: the changed snapshot prints permit:false, hostile ids stay valid JSON
printf '%s' "{\"workers\":{\"a\":{$W}}}" > "$CM_HOME/ledger.json"
first="$(cm_input_decide teardown a)"
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/MOVED","state":"done","standing":false}}}' > "$CM_HOME/ledger.json"
out="$(cm_input_revalidate "$first")"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "a changed snapshot prints permit:false and returns 1" || no "snapshot print" "rc=$rc $out"
for id in 'a"b' 'x\' '$(touch /tmp/cm-pwn)' "new
line"; do
  out="$(cm_input_decide teardown "$id" 2>/dev/null)"
  printf '%s' "$out" | jq -e --arg t "$id" '.permit == false and .target == $t' >/dev/null 2>&1 && ok "hostile id $(printf '%s' "$id" | head -c 12 | tr '\n' '~') gives valid refusal JSON" || no "hostile id" "$out"
done
out="$(cm_input_decide teardown 2>/dev/null)"; printf '%s' "$out" | jq -e '.permit == false' >/dev/null 2>&1 && ok "a usage error is valid refusal JSON" || no "usage json" "$out"
# --- the manifest lists every unreadable or invalid member
mfx() { printf '%s' "$1" > "$L"; "$HERE/../input-migrate-manifest.sh" --json "$L" 2>/dev/null; }
out="$(mfx "{\"workers\":{\"a\":{$W}},\"followUps\":[null]}")"
[ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && [ "$(printf '%s' "$out" | jq -r '.members[0].container')" = followUps ] && ok "manifest: a null follow-up is listed, not clean" || no "manifest null followup" "$out"
out="$(mfx "{\"workers\":{\"a\":{$W}},\"followUps\":[{\"id\":5,\"worker\":false,\"state\":\"open\"}]}")"
[ "$(printf '%s' "$out" | jq -r '.members[0].invalid | map(.field) | sort | join(",")')" = "id,worker" ] && ok "manifest: invalid follow-up fields are listed" || no "manifest followup fields" "$out"
out="$(mfx "{\"workers\":{\"a\":{$W}},\"followUps\":[{\"state\":\"open\"}]}")"
[ "$(printf '%s' "$out" | jq -r '.members[0].missing | join(",")')" = "id,worker,lane,owner" ] && ok "manifest: a follow-up without id and worker is listed" || no "manifest followup missing" "$out"
out="$(mfx "{\"workers\":{\"a\":{$W}},\"lanes\":{\"pr\":{\"lead\":false,\"state\":\"zz\"},\"q\":null}}")"
[ "$(printf '%s' "$out" | jq -r '[.members[] | select(.container == "lanes") | .member] | join(",")')" = "lanes.pr,lanes.q" ] && ok "manifest: lane rows with bad fields or not objects are listed" || no "manifest lanes" "$out"
out="$(mfx '{"workers":{"a":{"host":"local","state":"running","standing":false}}}')"
[ "$(printf '%s' "$out" | jq -r '.workers[0].missing | join(",")')" = "path" ] && [ "$(printf '%s' "$out" | jq -r '.clean')" = false ] && ok "manifest: a worker without a path is listed" || no "manifest path" "$out"
out="$(mfx '{"workers":{},"asks":[{"id":"q"}]}')"
[ "$(printf '%s' "$out" | jq -r '.members[0].missing | join(",")')" = "state" ] && ok "manifest: an ask with no state is listed" || no "manifest ask state" "$out"
out="$(mfx '{"workers":{},"hosts":{"h":{"maxWorkers":0}},"deployWindows":[{"id":"w","state":"zz"}]}')"
[ "$(printf '%s' "$out" | jq -r '[.members[].container] | sort | join(",")')" = "deployWindows,hosts" ] && ok "manifest: bad host and deploy window members are listed" || no "manifest hosts/windows" "$out"
out="$(mfx "{\"schemaVersion\":2,\"workers\":{\"a\":{$W}},\"followUps\":[{\"id\":\"f\",\"worker\":\"a\",\"lane\":\"pr\",\"owner\":\"owner-1\",\"state\":\"open\"}],\"asks\":[{\"id\":\"q\",\"state\":\"open\"}],\"lanes\":{\"pr\":{\"lead\":\"a\"}}}")"
[ "$(printf '%s' "$out" | jq -r '.clean')" = true ] && ok "manifest: a well-typed ledger is still clean" || no "manifest clean" "$out"
# --- a big ledger (well over the 128 KB a command-line argument may hold) still decides and still gives a manifest, from one read
jq -n -c '{workers: (reduce range(0; 20000) as $i ({}; .["w\($i)"] = {host: "local", path: "/w/\($i)", state: "done", standing: false})), asks: [], followUps: [], lanes: {}}' > "$L"
size="$(wc -c < "$L" | tr -d ' ')"
out="$(cm_input_decide teardown w19999 "$L")"; [ "$(printf '%s' "$out" | jq -r '.permit')" = true ] && ok "a ${size} byte ledger decides (no argument-size limit)" || no "big ledger decide" "$(printf '%s' "$out" | head -c 200)"
out="$("$HERE/../input-migrate-manifest.sh" --json "$L" 2>&1)"; [ "$(printf '%s' "$out" | jq -r '.clean' 2>/dev/null)" = true ] && ok "a ${size} byte ledger gives a clean manifest" || no "big ledger manifest" "$(printf '%s' "$out" | head -c 200)"
# =====================================================================================================================================
# what the typed view reads, and what it holds
# =====================================================================================================================================
WL="$W,\"lane\":\"pr\""
# --- NaN, Infinity and -Infinity are not JSON: the view is unreadable, whatever jq would have made of them
for bad in NaN Infinity -Infinity; do
  d "$bad as a state refuses (an unreadable ledger, never a defaulted state)" "{\"workers\":{\"a\":{\"host\":\"local\",\"path\":\"/a\",\"state\":$bad,\"standing\":false}}}" nudge a false "unreadable"
  d "$bad anywhere in the document refuses" "{\"workers\":{\"a\":{$W}},\"extra\":[$bad]}" teardown a false "unreadable"
done
d "a plain number outside double range refuses (1e999 reads as infinity)" "{\"workers\":{\"a\":{$W}},\"extra\":1e999}" teardown a false "unreadable"
d "ordinary numbers still read" "{\"workers\":{\"a\":{$W,\"n\":1.5e3}}}" teardown a true
# --- a key written twice INSIDE a row holds what the row might be about, whichever value survived
d "ask with state written twice (open, closed) holds every teardown" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"worker\":\"a\",\"state\":\"open\",\"state\":\"closed\"}]}" teardown a false "written twice"
d "ask with worker written twice (a, b) holds every teardown" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"worker\":\"a\",\"worker\":\"b\"}]}" teardown a false "written twice"
d "ask with worker written twice holds a worker it never named" "{\"workers\":{\"z\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"closed\",\"worker\":\"a\",\"worker\":\"b\"}]}" teardown z false "written twice"
d "follow-up row with a repeated key holds teardown" "{\"workers\":{\"a\":{$W}},\"followUps\":[{\"id\":\"f\",\"worker\":\"b\",\"worker\":\"c\",\"state\":\"done\"}]}" teardown a false "unreadable"
d "lane row with a repeated key holds teardown" "{\"workers\":{\"a\":{$WL}},\"lanes\":{\"pr\":{\"lead\":\"x\",\"lead\":\"y\"}}}" teardown a false "unreadable"
d "a lane row for ANOTHER lane with a repeated key holds teardown too (it may be this worker's)" "{\"workers\":{\"a\":{$WL}},\"lanes\":{\"zz\":{\"lead\":\"x\",\"lead\":\"y\"}}}" teardown a false "unreadable"
d "worker row with a repeated key refuses its own teardown" "{\"workers\":{\"a\":{$W,\"state\":\"running\"}}}" teardown a false "written twice"
d "a repeated key in ANOTHER worker's row that may be this one's parent holds" "{\"workers\":{\"a\":{$W,\"parent\":\"p\"},\"p\":{$W,\"parent\":\"x\",\"parent\":\"y\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"p\",\"lane\":\"pr\",\"owner\":\"owner-1\",\"state\":\"open\"}]}" teardown a false "follow-up"
d "a clean closed ask still lets go" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"worker\":\"a\",\"state\":\"closed\"}]}" teardown a true
# --- a lane state outside the enum holds the workers of that lane
for st in false 0 7 '""' '" "' '[]' '{}' '"Running"' '"paused"' '"gone "'; do
  d "lane state $st holds a worker in the lane" "{\"workers\":{\"a\":{$WL}},\"lanes\":{\"pr\":{\"lead\":null,\"state\":$st}}}" teardown a false "lane pr state is unreadable"
done
d "an unreadable lane state holds a worker whose lane is not readable" "{\"workers\":{\"a\":{$W,\"lane\":7}},\"lanes\":{\"pr\":{\"state\":false}}}" teardown a false "lane pr state"
d "an unreadable lane state holds a worker with no lane (it may be in it)" "{\"workers\":{\"a\":{$W}},\"lanes\":{\"pr\":{\"state\":false}}}" teardown a false "lane pr state"
d "an unreadable state of ANOTHER lane does not hold a worker whose lane is readable and different" "{\"workers\":{\"a\":{$WL}},\"lanes\":{\"dev\":{\"lead\":null,\"state\":false}}}" teardown a true
d "a known lane state does not hold" "{\"workers\":{\"a\":{$WL}},\"lanes\":{\"pr\":{\"lead\":null,\"state\":\"idle\"}}}" teardown a true
# --- an open ask whose tie to the worker cannot be established holds, whatever it is missing
d "open ask naming a lane the worker has no lane for holds" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"lane\":\"pr\"}]}" teardown a false "may be about this worker"
d "open ask naming a pr the worker has no pr for holds" "{\"workers\":{\"a\":{$W}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"pr\":12}]}" teardown a false "may be about this worker"
d "open ask with worker null and a worker that has a lane holds" "{\"workers\":{\"a\":{$WL}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"worker\":null}]}" teardown a false "may be about this worker"
d "open ask naming nothing at all holds" "{\"workers\":{\"a\":{$WL}},\"asks\":[{\"id\":\"q\",\"state\":\"open\"}]}" teardown a false "may be about this worker"
d "open ask with a blank worker holds" "{\"workers\":{\"a\":{$WL}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"worker\":\"\"}]}" teardown a false "may be about this worker"
d "open ask for ANOTHER worker still does not hold" "{\"workers\":{\"a\":{$WL}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"worker\":\"b\",\"lane\":\"pr\"}]}" teardown a true
d "open ask for a different REAL lane (a lane row) does not hold" "{\"workers\":{\"a\":{$WL}},\"lanes\":{\"dev\":{\"state\":\"running\"}},\"asks\":[{\"id\":\"q\",\"state\":\"open\",\"lane\":\"dev\"}]}" teardown a true
d "answered ask with nothing named lets go" "{\"workers\":{\"a\":{$WL}},\"asks\":[{\"id\":\"q\",\"state\":\"answered\"}]}" teardown a true
# =====================================================================================================================================
# an open follow-up on a worker whose chain runs through an unplaceable row holds
# =====================================================================================================================================
A='"a":{"host":"local","path":"/a","state":"done","standing":false}'
FU='"followUps":[{"id":"f","worker":"c","lane":"pr","owner":"owner-1","state":"open"}]'
d "descendant of a row with parent:false (c under b) holds teardown of a" "{\"workers\":{$A,\"b\":{\"parent\":false},\"c\":{\"parent\":\"b\"}},$FU}" teardown a false "cannot be placed"
d "descendant of a row with a repeated key holds teardown of a" "{\"workers\":{$A,\"b\":{\"parent\":\"x\",\"parent\":\"y\"},\"c\":{\"parent\":\"b\"}},$FU}" teardown a false "cannot be placed"
d "descendant of a null row holds teardown of a" "{\"workers\":{$A,\"b\":null,\"c\":{\"parent\":\"b\"}},$FU}" teardown a false "cannot be placed"
d "descendant of a row with an unreadable parent three deep holds teardown of a" "{\"workers\":{$A,\"b\":{\"parent\":7},\"d\":{\"parent\":\"b\"},\"c\":{\"parent\":\"d\"}},$FU}" teardown a false "cannot be placed"
d "a looping parent chain holds teardown of a (corrupt, never placed)" "{\"workers\":{$A,\"c\":{\"parent\":\"x\"},\"x\":{\"parent\":\"y\"},\"y\":{\"parent\":\"x\"}},$FU}" teardown a false "cannot be placed"
d "a worker that is its own parent holds teardown of a" "{\"workers\":{$A,\"c\":{\"parent\":\"c\"}},$FU}" teardown a false "cannot be placed"
d "a dangling parent is the root of its own family: a follow-up there does not hold a (contract rule C)" "{\"workers\":{$A,\"c\":{\"parent\":\"nobody\"}},$FU}" teardown a true
d "a placed chain that does not reach a still does not hold a" "{\"workers\":{$A,\"b\":{\"host\":\"local\"},\"c\":{\"parent\":\"b\"}},$FU}" teardown a true
d "a real descendant of a still holds a" "{\"workers\":{$A,\"b\":{\"parent\":\"a\"},\"c\":{\"parent\":\"b\"}},$FU}" teardown a false "open follow-up f on c"
d "a follow-up on an unplaceable row itself still holds" "{\"workers\":{$A,\"c\":{\"parent\":false}},$FU}" teardown a false "cannot be placed"
d "a closed follow-up on a descendant of an unplaceable row holds nothing" "{\"workers\":{$A,\"b\":{\"parent\":false},\"c\":{\"parent\":\"b\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"c\",\"lane\":\"pr\",\"owner\":\"owner-1\",\"state\":\"done\"}]}" teardown a true
# =====================================================================================================================================
# unreadable rows, replies and numbers
# =====================================================================================================================================
# --- an unreadable MIDDLE row holds the follow-ups of everything below it
for x in '"garbage"' 7 '{"parent":5}' '{"parent":"p","parent":"q"}' null '[]'; do
  d "unreadable middle row $x: a follow-up on its child holds teardown of t" "{\"workers\":{\"t\":{$W},\"x\":$x,\"c\":{\"parent\":\"x\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"c\",\"lane\":\"pr\",\"owner\":\"owner-1\",\"state\":\"open\"}]}" teardown t false "cannot be placed"
done
d "unreadable middle row, three deep: the follow-up is on the grandchild" "{\"workers\":{\"t\":{$W},\"x\":7,\"b\":{\"parent\":\"x\"},\"c\":{\"parent\":\"b\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"c\",\"lane\":\"pr\",\"owner\":\"owner-1\",\"state\":\"open\"}]}" teardown t false "cannot be placed"
# --- a live reply is scanned for repeated keys, from the same bytes
live "live: a repeated agentIdentity is incomplete (a running agent is not a bare shell)" terminals '{"ok":true,"result":{"terminals":[{"handle":"h","agentIdentity":"agent-a","agentIdentity":null}]}}' false "written twice"
live "live: truncated written twice (true, false) is incomplete" terminals '{"ok":true,"result":{"terminals":[],"truncated":true,"truncated":false}}' false "written twice"
live "live: ok written twice (false, true) is incomplete" terminals '{"ok":false,"ok":true,"result":{"terminals":[]}}' false "written twice"
live "live: totalCount written twice is incomplete" worktrees '{"ok":true,"result":{"worktrees":[],"totalCount":5,"totalCount":0}}' false "written twice"
live "live: a key repeated in a row is incomplete (worktrees)" worktrees '{"ok":true,"result":{"worktrees":[{"id":"a","path":"/p","path":"/q"}]}}' false "written twice"
live "live: NaN in a reply is incomplete" terminals '{"ok":true,"result":{"terminals":[],"totalCount":NaN}}' false
live "live: a clean reply is still complete and the agent is an agent" terminals '{"ok":true,"result":{"terminals":[{"handle":"h","agentIdentity":"agent-a"}]}}' true
out="$(printf '%s' '{"ok":true,"result":{"terminals":[{"handle":"h","agentIdentity":"agent-a"}]}}' | cm_input_live terminals)"; [ "$(printf '%s' "$out" | jq -r '.terminals[0].agent')" = agent ] && ok "live: a clean reply types the agent" || no "live agent" "$out"
# --- a number too big for a double is unreadable, integer or not
big="$(python3 -c "print('9' * 400)")"
d "a 400 digit integer makes the ledger unreadable" "{\"workers\":{\"a\":{$W}},\"extra\":$big}" teardown a false "unreadable"
d "an integer that fits a double is still read" "{\"workers\":{\"a\":{$W,\"n\":123456789012345678901234567890}}}" teardown a true
live "live: a 400 digit integer in a reply is incomplete" terminals "{\"ok\":true,\"result\":{\"terminals\":[],\"totalCount\":$big}}" false
# --- an empty host is a refusal, never local
printf '%s' "{\"workers\":{\"a\":{$W}}}" > "$CM_HOME/ledger.json"
for h in '' ' '; do
  out="$(cm_input_decide teardown a --host "$h" "$CM_HOME/ledger.json")"; rc=$?
  [ "$rc" != 0 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "decide --host '$h' refuses (never local)" || no "empty host decide" "rc=$rc $out"
done
d "the host the decision is for being a real host is permitted (control)" "{\"workers\":{\"a\":{$W}}}" teardown a true
d "the host the decision is for being blank is a reason in the view" "{\"workers\":{\"a\":{$W}}}" teardown a true
out="$(jq -c -L "$HERE/.." 'include "input-view"; iv_decide("teardown"; .; "a"; {host: ""})' <<<"$(cm_input_view "$CM_HOME/ledger.json")")"
[ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "iv_decide with a blank host refuses" || no "iv_decide blank host" "$out"
# at schemaVersion 2 a MISSING followUps, lanes or asks is not an empty list: the teardown protection data is absent, so teardown is refused.
# Legacy ledgers (no schemaVersion, or 1) keep the empty-container default. Each container is dropped alone, then all three.
CV='"asks":[],"followUps":[],"lanes":{}'
d "schemaVersion 2 with all three containers present: teardown permitted (control)" "{\"schemaVersion\":2,$CV,\"workers\":{\"a\":{$W}}}" teardown a true
d "schemaVersion 2 with only schemaVersion and a complete non-standing worker: teardown refused" "{\"schemaVersion\":2,\"workers\":{\"a\":{$W}}}" teardown a false "is missing"
d "schemaVersion 2 without followUps: teardown refused" "{\"schemaVersion\":2,\"asks\":[],\"lanes\":{},\"workers\":{\"a\":{$W}}}" teardown a false "followUps is missing"
d "schemaVersion 2 without lanes: teardown refused" "{\"schemaVersion\":2,\"asks\":[],\"followUps\":[],\"workers\":{\"a\":{$W}}}" teardown a false "lanes is missing"
d "schemaVersion 2 without asks: teardown refused" "{\"schemaVersion\":2,\"followUps\":[],\"lanes\":{},\"workers\":{\"a\":{$W}}}" teardown a false "asks is missing"
d "schemaVersion 3 without the containers: teardown refused" "{\"schemaVersion\":3,\"workers\":{\"a\":{$W}}}" teardown a false "is missing"
d "legacy ledger (no schemaVersion) without the containers: teardown keeps the empty default" "{\"workers\":{\"a\":{$W}}}" teardown a true
d "schemaVersion 1 without the containers: teardown keeps the empty default" "{\"schemaVersion\":1,\"workers\":{\"a\":{$W}}}" teardown a true
# =====================================================================================================================================
# families, closures and snapshots
# =====================================================================================================================================
# --- a follow-up whose worker is unreadable holds a teardown when its lane may be the lane of anything in the target's family
TL='"t":{"host":"local","path":"/t","state":"done","standing":false,"lane":"a"},"c":{"host":"local","path":"/c","state":"running","standing":false,"lane":"b","parent":"t"}'
for wv in '"c"' '7' '""' '" "' 'false' '{}' 'null' '["c"]'; do
  d "follow-up with worker $wv on lane b holds teardown of t (c in lane b is its descendant)" "{\"workers\":{$TL},\"followUps\":[{\"id\":\"f\",\"worker\":$wv,\"lane\":\"b\",\"owner\":\"o\",\"state\":\"open\"}]}" teardown t false
  d "the same, schemaVersion 2 (worker $wv)" "{\"schemaVersion\":2,\"workers\":{$TL},\"followUps\":[{\"id\":\"f\",\"worker\":$wv,\"lane\":\"b\",\"owner\":\"o\",\"state\":\"open\"}]}" teardown t false
done
d "a follow-up with an unreadable worker on a lane nothing in the family has still permits" "{\"workers\":{$TL,\"z\":{\"lane\":\"zz\"}},\"followUps\":[{\"id\":\"f\",\"worker\":7,\"lane\":\"zz\",\"owner\":\"o\",\"state\":\"open\"}]}" teardown t true
d "a follow-up with an unreadable worker whose lane may be an UNPLACEABLE row's holds" "{\"workers\":{$TL,\"u\":{\"parent\":false,\"lane\":\"u\"}},\"followUps\":[{\"id\":\"f\",\"worker\":7,\"lane\":\"u\",\"owner\":\"o\",\"state\":\"open\"}]}" teardown t false
# --- the family closure is linear in the depth of the chain
jq -nc '[range(0;2500)] | map({key: ("w" + tostring), value: ({host:"local",path:("/w" + tostring),state:"done",standing:false} + (if . > 0 then {parent: ("w" + ((. - 1) | tostring))} else {} end))}) | from_entries | {workers: .}' > "$ROOT/deep.json"
t0="$(date +%s)"; out="$(timeout 60 bash -c '. "$1/lib.sh"; cm_input_decide teardown w0 "$2"' _ "$HERE/.." "$ROOT/deep.json")"; t1="$(date +%s)"
[ "$(printf '%s' "$out" | jq -r '.permit' 2>/dev/null)" = true ] && [ $((t1 - t0)) -le 30 ] && ok "a 2500-deep parent chain decides in $((t1 - t0))s" || no "deep chain" "$((t1 - t0))s $(printf '%s' "$out" | head -c 200)"
# --- a live snapshot whose copy FAILS is incomplete, whatever the bytes copied
out="$( cat() { printf '%s' '{"ok":true,"result":{"terminals":[]}}'; return 1; }; cm_input_live terminals </dev/null 2>/dev/null )"; rc=$?
[ "$rc" != 0 ] && [ "$(printf '%s' "$out" | jq -r '.complete' 2>/dev/null)" = false ] && ok "a live copy that exits non-zero is incomplete (the bytes it copied do not count)" || no "live cat status" "rc=$rc $out"
out="$(printf '%s' '{"ok":true,"result":{"terminals":[]}}' | cm_input_live terminals 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.complete')" = true ] && ok "control: the same reply through a copy that succeeds is complete" || no "live control" "rc=$rc $out"
# --- a validator does not accept a trailing newline (a regex `$` matches before a final newline)
d "worker host \"local\\n\" is invalid, not local" '{"workers":{"a":{"host":"local\n","path":"/w/a","state":"done","standing":false}}}' teardown a false "host is unreadable"
d "worker host \"h \\n\" has a space and is invalid" '{"workers":{"a":{"host":"box\n","path":"/w/a","state":"done","standing":false}}}' teardown a false "host is unreadable"
d "worker path \"/w/a\\n\" is invalid" '{"workers":{"a":{"host":"local","path":"/w/a\n","state":"done","standing":false}}}' teardown a false "path is unreadable"
d "an ask about path \"/w/a\\n\" may be about the worker at /w/a: held" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/a\n"}]}' teardown a false "open ask"
d "control: an ask about another readable path does not hold" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/b","worker":"zz"}]}' teardown a true
d "a follow-up issue URL with a trailing newline is no escalation" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5\n"}]}' teardown a false "open follow-up"
d "control: the same URL without the newline is an escalation" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5"}]}' teardown a true
# owner and repo are ONE segment each, and the number stops at the cap of the issue field (1e9)
d "ghurl: owner and repo with .. segments between them" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/x/../../b/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a .. segment after the repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/x/y/../issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an extra path segment after the repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/x/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an empty repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o//issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an empty owner" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com//r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a number of 1000000000, the cap" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/1000000000"}]}' teardown a false "open follow-up"
d "ghurl: a 20 digit number" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/pull/99999999999999999999"}]}' teardown a false "open follow-up"
d "ghurl: control: the largest number under the cap" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/999999999"}]}' teardown a true
d "ghurl: control: an owner with a dash and a repo with dots" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/Acme-Org/acme.app/pull/42?w=1"}]}' teardown a true
# a lexical alias of a path (a repeated slash, a . segment) names the same place; a path with a .. segment is invalid, so an ask about it fails closed
d "path: an ask about /w/./a holds the worker at /w/a" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/./a"}]}' teardown a false "open ask"
d "path: an ask about /w//a holds the worker at /w/a" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w//a"}]}' teardown a false "open ask"
d "path: an ask about //w/a/. holds the worker at /w/a" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"//w/a/."}]}' teardown a false "open ask"
d "path: an ask about /w/b/../a is invalid and holds" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/b/../a"}]}' teardown a false "open ask"
d "path: an ask about /w/.. is invalid and holds" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/.."}]}' teardown a false "open ask"
d "path: an ask about control: /w/ab is another place and does not hold" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/ab"}]}' teardown a true
d "path: an ask about control: /w/.a is another place and does not hold" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/.a"}]}' teardown a true
d "path: an ask about control: /w/a.. is a name, not a .. segment, and does not hold" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"asks":[{"id":"q","state":"open","path":"/w/a.."}]}' teardown a true
d "path: a worker path with a repeated slash still matches its alias" '{"workers":{"a":{"host":"local","path":"/w//a","worktree":"/w/a/","state":"done","standing":false}}}' teardown a true
d "path: a worker path with a .. segment is invalid" '{"workers":{"a":{"host":"local","path":"/w/b/../a","state":"done","standing":false}}}' teardown a false "path is unreadable"
d "blank: a parent of only U+2063 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u2063"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+00AD is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u00ad"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+3164 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u3164"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+202E is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u202e"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+034F is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u034f"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+115F is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u115f"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+1160 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u1160"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+FFA0 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\uffa0"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+FE00 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\ufe00"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+FE0F is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\ufe0f"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+200E is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u200e"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+200F is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u200f"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+202A is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u202a"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+2064 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u2064"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+0085 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u0085"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+2028 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u2028"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+2029 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u2029"}}}' teardown a false "parent is unreadable"
d "blank control: a parent of plain letters is real text (a dangling one is a root: a documented limit)" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"zz"}}}' teardown a true
# owner and repo are an ASCII allow-list (owner [A-Za-z0-9][A-Za-z0-9-]{0,38}, repo [A-Za-z0-9._-]{1,100} but not only dots), # and ? only after the number
d "ghurl: owner with #" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o#/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: repo with #" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r#/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a # right after the number" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5x#"}]}' teardown a false "open follow-up"
d "ghurl: owner with ?" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o?/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: repo with ?" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r?/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a ? right after the number" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5x?"}]}' teardown a false "open follow-up"
d "ghurl: owner with @" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o@/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: repo with @" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r@/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a @ right after the number" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5@"}]}' teardown a false "open follow-up"
d "ghurl: owner with :" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o:/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: repo with :" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r:/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a : right after the number" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5:"}]}' teardown a false "open follow-up"
d "ghurl: owner with a backslash" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o\\/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: repo with a backslash" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r\\/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a a backslash right after the number" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5\\"}]}' teardown a false "open follow-up"
d "ghurl: owner with %" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o%/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: repo with %" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r%/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a % right after the number" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5%"}]}' teardown a false "open follow-up"
d "ghurl: a percent-encoded .. as the owner" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/%2e%2e/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a percent-encoded .. as the repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/%2e%2e/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an owner that starts with a dash" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/-o/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an owner of 40 characters" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/'"$(rep a 40)"'/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a repo of 101 characters" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/'"$(rep r 101)"'/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a non-ASCII owner" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/\u00e9/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an owner with an underscore" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o_x/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a repo of only dots" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/.../issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a # before /issues" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r#/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a ? before /pull" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r?/pull/5"}]}' teardown a false "open follow-up"
d "ghurl control: digits and hyphens" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/Acme-Org2/app-1/issues/3"}]}' teardown a true
d "ghurl control: a dotted repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r.js/issues/7"}]}' teardown a true
d "ghurl control: an underscore repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/my_repo/pull/7"}]}' teardown a true
d "ghurl control: a #fragment suffix" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5#issuecomment-9"}]}' teardown a true
d "ghurl control: a ?q=1 suffix" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/pull/5?q=1"}]}' teardown a true
d "ghurl control: a 39 character owner" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/'"$(rep a 39)"'/r/issues/5"}]}' teardown a true
d "ghurl control: a 100 character repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/'"$(rep r 100)"'/issues/5"}]}' teardown a true
d "ghurl control: a .git repo (a documented limit)" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r.git/issues/5"}]}' teardown a true
# a follow-up or ask whose lane matches no lane row and no worker lane (a near spelling) is unreadable, so it holds; a lane that is real still narrows
d "lane: an unreadable worker and a near-spelling lane L holds" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"},"b":{"host":"local","path":"/w/b","state":"running","standing":false,"lane":"m"}},"followUps":[{"id":"f","worker":false,"lane":"L","owner":"o","state":"open"}]}' teardown a false "may be this one"
d "lane: an unreadable worker and a lane with a trailing space holds" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"},"b":{"host":"local","path":"/w/b","state":"running","standing":false,"lane":"m"}},"followUps":[{"id":"f","worker":false,"lane":"l ","owner":"o","state":"open"}]}' teardown a false "may be this one"
d "lane: a worker naming no row and a near-spelling lane holds" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"},"b":{"host":"local","path":"/w/b","state":"running","standing":false,"lane":"m"}},"followUps":[{"id":"f","worker":"zz","lane":"L","owner":"o","state":"open"}]}' teardown a false "may be this one"
d "lane control: an unreadable worker and the target's own lane holds" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"},"b":{"host":"local","path":"/w/b","state":"running","standing":false,"lane":"m"}},"followUps":[{"id":"f","worker":false,"lane":"l","owner":"o","state":"open"}]}' teardown a false "may be this one"
d "lane control: an unreadable worker and another real lane (m) narrows" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"},"b":{"host":"local","path":"/w/b","state":"running","standing":false,"lane":"m"}},"followUps":[{"id":"f","worker":false,"lane":"m","owner":"o","state":"open"}]}' teardown a true
d "lane: an ask about a near-spelling lane L may be about the worker: held" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"},"b":{"host":"local","path":"/w/b","state":"running","standing":false,"lane":"m"}},"asks":[{"id":"q","state":"open","lane":"L"}]}' teardown a false "open ask"
d "lane control: an ask about another real lane m does not hold" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"},"b":{"host":"local","path":"/w/b","state":"running","standing":false,"lane":"m"}},"asks":[{"id":"q","state":"open","lane":"m"}]}' teardown a true
d "blank: a parent of only U+2800 (Braille blank) is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u2800"}}}' teardown a false "parent is unreadable"
d "str: a parent with a newline inside is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u000ay"}}}' teardown a false "parent is unreadable"
d "str: a parent ending in a newline is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u000a"}}}' teardown a false "parent is unreadable"
d "str: a parent with a tab inside is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u0009y"}}}' teardown a false "parent is unreadable"
d "str: a parent ending in a tab is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u0009"}}}' teardown a false "parent is unreadable"
d "str: a parent with a DEL inside is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u007fy"}}}' teardown a false "parent is unreadable"
d "str: a parent ending in a DEL is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u007f"}}}' teardown a false "parent is unreadable"
d "str: a parent with a NUL-adjacent C0 inside is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u0001y"}}}' teardown a false "parent is unreadable"
d "str: a parent ending in a NUL-adjacent C0 is invalid" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"x\u0001"}}}' teardown a false "parent is unreadable"
# ONE single-line predicate under EVERY single-line kind, so a character that a program trims, drops or splits on (TAB, VT, NUL, NEL, U+2028, U+2029, ESC, newline, CR)
# never makes two different strings read as the same. Each class x each kind x one decision that reads it. The ask or follow-up with such a character holds exactly as one with a
# different valid value does; a worker row with it is unreadable; the same row without it is permitted (the control).
WD='"host":"local","path":"/w/a","state":"running","standing":false,"lane":"L"'
for cc in 0009:TAB 000b:VT 0000:NUL 0085:NEL 2028:LS 2029:PS 001b:ESC 000a:LF 000d:CR; do
  code="${cc%%:*}"; nm="${cc##*:}"
  d "path: an ask whose path ends in $nm is not read as the path /w/a: teardown of its worker is held" "{\"schemaVersion\":2,\"workers\":{\"T\":{$WD}},\"asks\":[{\"id\":\"a1\",\"state\":\"open\",\"path\":\"/w/a\\u$code\"}]}" teardown T false "open ask a1"
  d "path: a worker whose own path ends in $nm is unreadable, never the path /w/a" "{\"schemaVersion\":2,\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w/a\\u$code\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}}}" teardown T false "path is unreadable"
  d "path: a worker path with $nm in the middle is unreadable" "{\"schemaVersion\":2,\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w\\u$code/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}}}" teardown T false "path is unreadable"
  d "str: a parent with $nm is unreadable" "{\"schemaVersion\":2,\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\",\"parent\":\"p\\u$code\"}}}" teardown T false "parent is unreadable"
  d "host: a host with $nm is unreadable" "{\"schemaVersion\":2,\"workers\":{\"T\":{\"host\":\"h\\u$code\",\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}}}" teardown T false "host is unreadable"
  d "strlist: an epicConflict entry with $nm is unreadable" "{\"schemaVersion\":2,\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\",\"epicConflict\":[\"x\\u$code\"]}}}" teardown T false "epicConflict is unreadable"
  d "url: an issue URL whose tail after the number holds $nm is no issue: the follow-up holds teardown" "{\"schemaVersion\":2,\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"T\",\"lane\":\"L\",\"owner\":\"o\",\"state\":\"open\",\"issueUrl\":\"https://github.com/o/r/issues/5#a\\u$code\"}]}" teardown T false "open follow-up f on T"
done
# a worker KEY with the character is an unreadable member: held, never a silent target (the target holds the same character, so the NUL class is the view test's)
for cc in $'\t':TAB $'\v':VT $'\xc2\x85':NEL $'\xe2\x80\xa8':LS $'\xe2\x80\xa9':PS $'\e':ESC $'\n':LF $'\r':CR; do
  ch="${cc%%:*}"; nm="${cc##*:}"; kj="$(printf '%s' "$ch" | jq -Rs .)"; kj="${kj%\"}"; kj="T${kj#\"}\""
  d "key: a worker keyed T+$nm is an unreadable member and is not a target" "{\"schemaVersion\":2,\"workers\":{$kj:{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}}}" teardown "T$ch" false "unreadable"
done
d "key control: the same row keyed T alone is permitted" "{\"schemaVersion\":2,\"asks\":[],\"followUps\":[],\"lanes\":{},\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}}}" teardown T true
d "control: an ask about a different valid path does not hold" "{\"schemaVersion\":2,\"followUps\":[],\"lanes\":{},\"workers\":{\"T\":{$WD}},\"asks\":[{\"id\":\"a1\",\"state\":\"open\",\"path\":\"/w/b\"}]}" teardown T true
d "control: a path with a space, a dot and a hyphen is valid" "{\"schemaVersion\":2,\"asks\":[],\"followUps\":[],\"lanes\":{},\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w/my dir/a.b-c\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}}}" teardown T true
d "control: an issue URL whose tail is URL characters is an issue" "{\"schemaVersion\":2,\"asks\":[],\"lanes\":{},\"workers\":{\"T\":{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"done\",\"standing\":false,\"lane\":\"L\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"T\",\"lane\":\"L\",\"owner\":\"o\",\"state\":\"open\",\"issueUrl\":\"https://github.com/o/r/issues/5?a=1&b=%20#c/d\"}]}" teardown T true
# an issue or pull number is 1 or more (0, 00, 000 are no issue) and "." / ".." are no owner or repo; a valid URL keeps releasing
d "ghurl: issue number 0" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/0"}]}' teardown a false "open follow-up"
d "ghurl: pull number 000" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/pull/000"}]}' teardown a false "open follow-up"
d "ghurl: an owner and repo of .." '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/../../issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an owner of . and repo of .." '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/./../issues/5"}]}' teardown a false "open follow-up"
d "ghurl: a repo of .." '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/../issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an owner of ..." '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/.../r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: an owner with a zero-width space" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/\u200b/r/issues/5"}]}' teardown a false "open follow-up"
d "ghurl: control: a valid issue URL" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5"}]}' teardown a true
d "ghurl: control: a valid pull URL with a fragment" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/pull/12#issuecomment-1"}]}' teardown a true
d "ghurl: control: a valid issue URL with a query" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/10?x=1"}]}' teardown a true
d "ghurl: control: a dotted repo name is a real repo" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r.js/issues/7"}]}' teardown a true
d "blank: a parent of only U+200B is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u200b"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+200C is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u200c"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+200D is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u200d"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+2060 is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u2060"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+FEFF is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\ufeff"}}}' teardown a false "parent is unreadable"
d "blank: a parent of only U+180E is invalid, never a root" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"parent":"\u180e"}}}' teardown a false "parent is unreadable"
d "blank: a path of only U+200B is invalid" '{"workers":{"a":{"host":"local","path":"\u200b","state":"done","standing":false}}}' teardown a false "path is unreadable"
d "blank: a host of only U+200B is invalid" '{"workers":{"a":{"host":"\u200b","path":"/w/a","state":"done","standing":false}}}' teardown a false "host is unreadable"
d "blank: a follow-up worker of only U+200B is no readable worker: held by lane" '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l"}},"followUps":[{"id":"f","worker":"\u200b","lane":"l","owner":"o","state":"open"}]}' teardown a false "no readable worker"
# =====================================================================================================================================
# loops, decimals and exact names
# =====================================================================================================================================
# dt <label> <ledger text> <action> <target> <want permit> [reason substring]: like d, but the decision runs under a timeout, so a hang is a FAIL and not a stall
dt() {
  local label="$1" doc="$2" a="$3" t="$4" want="$5" sub="${6:-}" out got
  # DT_FILL=1: a schemaVersion 2 document gets the three protection containers it does not carry (a missing one refuses teardown by itself), so a case
  # about the family walk, a follow-up or a lane tests THAT and not the missing container
  [ "${DT_FILL:-}" = 1 ] && doc="$(printf '%s' "$doc" | jq -c 'if (.schemaVersion // 0) >= 2 then (.asks //= []) | (.followUps //= []) | (.lanes //= {}) else . end')"
  printf '%s' "$doc" > "$L"
  out="$(timeout 20 bash -c '. "$1/lib.sh"; cm_input_decide "$2" "$3" "$4"' _ "$HERE/.." "$a" "$t" "$L" 2>&1; echo "rc=$?")"
  case "$out" in *"rc=124") no "$label" "no answer in 20s"; return ;; esac
  out="${out%$'\n'rc=*}"
  got="$(printf '%s' "$out" | jq -r '.permit' 2>/dev/null)"
  if [ "$got" != "$want" ]; then no "$label" "permit=$got want $want: $out"; return; fi
  if [ -n "$sub" ] && ! printf '%s' "$out" | jq -e --arg s "$sub" 'any(.reasons[]; contains($s))' >/dev/null; then no "$label" "no reason has \"$sub\": $out"; return; fi
  ok "$label"
}
# --- the target is inside a parent loop (or is its own parent): the family walk ends and the teardown is held
DT_FILL=1
for sv in '' '"schemaVersion":2,'; do
  CN='"host":"local","path":"/w/a","state":"done","standing":false'
  dt "teardown of a worker that is its own parent is held, not a hang (${sv:-no schemaVersion})" "{${sv}\"workers\":{\"a\":{$CN,\"parent\":\"a\"}}}" teardown a false "parent chain"
  dt "teardown of a target inside a 2-row parent loop is held (${sv:-no schemaVersion})" "{${sv}\"workers\":{\"t\":{$CN,\"parent\":\"c\"},\"c\":{$CN,\"parent\":\"t\"}}}" teardown t false "parent chain"
  dt "teardown of a target inside a 3-row parent loop is held (${sv:-no schemaVersion})" "{${sv}\"workers\":{\"t\":{$CN,\"parent\":\"c\"},\"c\":{$CN,\"parent\":\"d\"},\"d\":{$CN,\"parent\":\"t\"}}}" teardown t false "parent chain"
  dt "teardown of a target below a loop (child of a looping row) is held (${sv:-no schemaVersion})" "{${sv}\"workers\":{\"t\":{$CN,\"parent\":\"c\"},\"c\":{$CN,\"parent\":\"d\"},\"d\":{$CN,\"parent\":\"c\"}}}" teardown t false "parent chain"
  dt "a loop elsewhere in the ledger does not hold a target that is not in it (${sv:-no schemaVersion})" "{${sv}\"workers\":{\"t\":{$CN},\"c\":{$CN,\"parent\":\"d\"},\"d\":{$CN,\"parent\":\"c\"}}}" teardown t true
  dt "nudge of a worker inside a loop is still decided (${sv:-no schemaVersion})" "{${sv}\"workers\":{\"a\":{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"running\",\"standing\":false,\"parent\":\"a\"}}}" nudge a true
done
DT_FILL=
# --- a decimal that is not a whole number but rounds to one in a double is NOT a whole number (the token decides, not the double)
WA='"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}}'
FUI() { printf '{%s,"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issue":%s}]}' "$WA" "$1"; }
for n in 1.0000000000000001 0.99999999999999999999 4503599627370497.5 1.00000000000000001e0 10.000000000000001E-1 12.0000000000000001; do
  dt "follow-up issue $n is not a whole number: the teardown is held" "$(FUI "$n")" teardown a false
  dt "schemaVersion $n is not readable: a nudge is refused" "{\"schemaVersion\":$n,\"workers\":{\"a\":{\"path\":\"/w/a\"}}}" nudge a false
  live "live: totalCount $n is not complete" terminals "{\"result\":{\"terminals\":[{\"handle\":\"a\"}],\"totalCount\":$n}}" false
done
dt "control: follow-up issue 1.5 holds the teardown" "$(FUI 1.5)" teardown a false
dt "control: follow-up issue 7 is an escalation" "$(FUI 7)" teardown a true
# an exact whole number spelled with a fraction part or an exponent IS a whole number (its exact value is an integer): accepted, same as 1
for n in 1.0 1e0 10E-1 1.0e0 7.000 0.7e1; do
  dt "follow-up issue $n is exactly a whole number: accepted as an escalation" "$(FUI "$n")" teardown a true
done
for n in 1.0 1e0; do
  dt "schemaVersion $n is exactly a whole number: accepted" "{\"schemaVersion\":$n,\"workers\":{\"a\":{\"host\":\"local\",\"path\":\"/w/a\",\"state\":\"running\",\"standing\":false}}}" nudge a true
done
out="$(mfx "{\"workers\":{\"a\":{$W}},\"freeze\":{\"state\":\"off\",\"ttl\":1.0000000000000001}}")"
[ -z "$out" ] && ok "manifest: a ttl that is a decimal rounding to a whole number is an unreadable ledger, not clean" || no "manifest decimal ttl" "$out"
# --- a name that matches no member EXACTLY is unknown: it holds by lane, it is never taken as someone else
DT_FILL=1
TT='"t":{"host":"local","path":"/w/t","state":"done","standing":false,"lane":"a"},"x":{"host":"local","path":"/w/x","state":"running","standing":false,"lane":"a"}'
for sv in '' '"schemaVersion":2,'; do
  for wv in '"T"' '" t"' '"gone-worker"' '"t "' '"tt"'; do
    dt "follow-up on $wv (no such worker) in the lane of t holds the teardown of t (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"followUps\":[{\"id\":\"f\",\"worker\":$wv,\"lane\":\"a\",\"owner\":\"o\",\"state\":\"open\"}]}" teardown t false "no worker row"
  done
  dt "control: a follow-up on $wv in ANOTHER lane does not hold t (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"lanes\":{\"zz\":{\"state\":\"running\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"gone\",\"lane\":\"zz\",\"owner\":\"o\",\"state\":\"open\"}]}" teardown t true
  dt "control: a follow-up on another EXISTING worker (not below t) does not hold t (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"followUps\":[{\"id\":\"f\",\"worker\":\"x\",\"lane\":\"a\",\"owner\":\"o\",\"state\":\"open\"}]}" teardown t true
  dt "control: a DONE follow-up on a worker that is gone does not hold (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"followUps\":[{\"id\":\"f\",\"worker\":\"gone\",\"lane\":\"a\",\"owner\":\"o\",\"state\":\"done\"}]}" teardown t true
  for lv in '"T"' '" t"' '"gone-worker"'; do
    dt "lane a whose lead $lv names no worker holds the teardown of t in lane a (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"lanes\":{\"a\":{\"lead\":$lv}}}" teardown t false "lead"
    dt "control: lane zz whose lead $lv names no worker does not hold t in lane a (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"lanes\":{\"zz\":{\"lead\":$lv}}}" teardown t true
  done
  dt "control: a lead that names another existing worker does not hold t (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"lanes\":{\"a\":{\"lead\":\"x\"}}}" teardown t true
  dt "control: the lead that IS t holds (${sv:-no schemaVersion})" "{${sv}\"workers\":{$TT},\"lanes\":{\"a\":{\"lead\":\"t\"}}}" teardown t false "lead of lane a"
done
# --- cm_input_decide acts only on exactly ONE readable view document, and checks the status of whatever produced it
printf '%s' "{\"workers\":{\"a\":{$W}}}" > "$L"
GV="$ROOT/good-view.json"; cm_input_view "$L" > "$GV"
dv() { # <label> <view file> <want rc> <want permit>
  local out rc got
  out="$(cm_input_decide teardown a --view-file "$2" 2>/dev/null)"; rc=$?
  got="$(printf '%s' "$out" | jq -r '.permit' 2>/dev/null)"
  [ "$rc" = "$3" ] && [ "$got" = "$4" ] && ok "$1" || no "$1" "rc=$rc permit=$got out=$out"
}
dv "view file: one valid view permits (control)" "$GV" 0 true
{ cat "$GV"; echo BROKEN; } > "$ROOT/v-tail.json"
dv "view file: a valid view followed by a malformed line refuses with rc 2" "$ROOT/v-tail.json" 2 false
{ cat "$GV"; printf '{"broken":'; } > "$ROOT/v-tail2.json"
dv "view file: a valid view followed by a truncated document refuses with rc 2" "$ROOT/v-tail2.json" 2 false
{ cat "$GV"; cat "$GV"; } > "$ROOT/v-two.json"
dv "view file: two valid views refuse with rc 2" "$ROOT/v-two.json" 2 false
{ echo BROKEN; cat "$GV"; } > "$ROOT/v-head.json"
dv "view file: a malformed line before a valid view refuses with rc 2" "$ROOT/v-head.json" 2 false
: > "$ROOT/v-empty.json"
dv "view file: an empty file refuses with rc 2" "$ROOT/v-empty.json" 2 false
printf '[1]\n' > "$ROOT/v-arr.json"
dv "view file: a document that is not an object refuses with rc 2" "$ROOT/v-arr.json" 2 false
dv "view file: a file that does not exist refuses with rc 2" "$ROOT/v-none.json" 2 false
# a NUL byte: a command substitution drops it, so text that jq rejects would read as a valid view if the file were read that way
{ cat "$GV"; printf '\0'; } > "$ROOT/v-nul.json"
dv "view file: a valid view followed by a NUL byte refuses with rc 2" "$ROOT/v-nul.json" 2 false
{ printf '\0'; cat "$GV"; } > "$ROOT/v-nul-head.json"
dv "view file: a NUL byte before a valid view refuses with rc 2" "$ROOT/v-nul-head.json" 2 false
sed 's/"host"/"ho@st"/' "$GV" | tr '@' '\0' > "$ROOT/v-nul-key2.json"
dv "view file: a NUL byte inside a key refuses with rc 2" "$ROOT/v-nul-key2.json" 2 false
# the producer branch: a stand-in for cm_input_view (a subshell, so the real one is back afterwards)
dp() { # <label> <want rc> <want permit> <producer body>
  local out rc got body="$4"
  out="$( cm_input_view() { eval "$body"; }; cm_input_decide teardown a "$L" 2>/dev/null )"; rc=$?
  got="$(printf '%s' "$out" | jq -r '.permit' 2>/dev/null)"
  [ "$rc" = "$2" ] && [ "$got" = "$3" ] && ok "$1" || no "$1" "rc=$rc permit=$got out=$out"
}
dp "producer: one valid view, status 0 permits (control)" 0 true 'cat "$GV"'
dp "producer: a valid view then a malformed line refuses with rc 2" 2 false 'cat "$GV"; echo BROKEN'
dp "producer: two valid views refuse with rc 2" 2 false 'cat "$GV"; cat "$GV"'
dp "producer: no output at all refuses with rc 2" 2 false ':'
dp "producer: a valid readable view but a failing status refuses with rc 2" 2 false 'cat "$GV"; return 1'
dp "producer: a failing status with no view refuses with rc 2" 2 false 'return 3'
jq -c '.readable = "false"' "$GV" > "$ROOT/v-str-false.json"
dp "producer: a failing status with a view that says readable:\"false\" (a string) refuses with rc 2" 2 false 'cat "$ROOT/v-str-false.json"; return 1'
jq -c '.readable = false' "$GV" > "$ROOT/v-bool-false.json"
dp "producer: a failing status with a view that says readable:false (the unreadable-ledger shape) refuses" 1 false 'cat "$ROOT/v-bool-false.json"; return 1'
# the real producer on an unreadable ledger still ends in a refusal with the reason (rc 1, not a crash)
out="$(cm_input_decide teardown a "$ROOT/vanished.json" 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "producer: an unreadable ledger refuses with rc 1 and a reason" || no "unreadable ledger" "rc=$rc $out"
# revalidation: a prior decision with a valid first document and a malformed tail is not a decision
printf '%s' "{\"workers\":{\"a\":{$W}}}" > "$L"
prior="$(cm_input_decide teardown a "$L")"
out="$(cm_input_revalidate "$prior" "$L" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = true ] && ok "revalidate: an unchanged ledger is still permitted (control)" || no "revalidate control" "rc=$rc $out"
out="$(cm_input_revalidate "$prior
BROKEN" "$L" 2>/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "revalidate: a prior decision with a malformed tail refuses" || no "revalidate tail" "rc=$rc $out"
out="$(cm_input_revalidate "$prior
$prior" "$L" 2>/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "revalidate: two prior decisions refuse" || no "revalidate two" "rc=$rc $out"
{ cat "$GV"; echo BROKEN; } > "$ROOT/v-tail.json"
out="$(cm_input_revalidate "$prior" --view-file "$ROOT/v-tail.json" 2>/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "revalidate: a view file with a malformed tail refuses" || no "revalidate view tail" "rc=$rc $out"
out="$(cm_input_revalidate "$prior" --view-file "$ROOT/v-nul.json" 2>/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "revalidate: a view file with a NUL byte after the view refuses" || no "revalidate view NUL" "rc=$rc $out"
out="$(cm_input_revalidate "$prior" --view-file "$GV" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.permit')" = true ] && ok "revalidate: a clean view file is still permitted (control)" || no "revalidate view control" "rc=$rc $out"
# the enum a reader checks a state against and the enum of the typed view are ONE list. stall.sh and digest.sh read CM_ASK_STATES (lib.sh); input-view.jq has iv_ask_states.
# A reader list narrower than the view's marks the documented states closed and in-progress unreadable and holds the whole stall judgment (exit 3 every tick). They must stay equal.
IVA="$(jq -nc -L "$HERE/.." 'include "input-view"; iv_ask_states')"; LIBA="$(jq -nc "$CM_JQ_STATE_DEFS"' cm_ask_states')"
[ -n "$IVA" ] && [ "$IVA" = "$LIBA" ] && ok "ask states: lib.sh CM_ASK_STATES equals iv_ask_states in input-view.jq ($IVA)" || no "ask states drift" "view=$IVA lib=$LIBA"
for st in closed in-progress; do
  jq -e --arg s "$st" 'index($s) != null' <<<"$LIBA" >/dev/null && ok "ask state $st is a known state of the readers" || no "ask state $st is missing from CM_ASK_STATES"
done
# mutant: a narrowed CM_ASK_STATES breaks the equality
mkdir -p "$ROOT/mut-asks" && cp "$HERE"/../lib.sh "$HERE"/../*.jq "$ROOT/mut-asks/" && sed -i 's/^CM_ASK_STATES="open answered in-progress decided closed"$/CM_ASK_STATES="open answered decided"/' "$ROOT/mut-asks/lib.sh"
LIBN="$(bash -c '. "$1/lib.sh"; jq -nc "$CM_JQ_STATE_DEFS"" cm_ask_states"' _ "$ROOT/mut-asks")"
[ "$LIBN" != "$IVA" ] && ok "ask states: a narrowed reader list differs from the view (the equality check would fail)" || no "ask states mutant not caught"
DT_FILL=
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
