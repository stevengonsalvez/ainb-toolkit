#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# input-view.sh (test): the typed input boundary (scripts/input-view.jq + the cm_input_* adapter in scripts/lib.sh).
# Covers the envelope, the three-state standing and state, the legacy defaults (schemaVersion < 2 only), bounded holds, duplicate keys,
# the live-reply adapter and revalidation. The per-field invalid matrix is test/input-matrix.sh.
#
#   scripts/test/input-view.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-input-view.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
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
# d <label> <ledger text> <action> <target> <want permit true|false> [reason substring]
d() {
  local label="$1" doc="$2" a="$3" t="$4" want="$5" sub="${6:-}" out got
  printf '%s' "$doc" > "$L"
  out="$(cm_input_decide "$a" "$t" "$L")"
  got="$(printf '%s' "$out" | jq -r '.permit')"
  if [ "$got" != "$want" ]; then no "$label" "permit=$got want $want: $out"; return; fi
  if [ -n "$sub" ] && ! printf '%s' "$out" | jq -e --arg s "$sub" 'any(.reasons[]; contains($s))' >/dev/null; then no "$label" "no reason has \"$sub\": $out"; return; fi
  ok "$label"
}
W='"host":"local","path":"/w/x"'
# --- envelope
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}}}' > "$L"
v="$(cm_input_view "$L")"
[ "$(printf '%s' "$v" | jq -r '.schema')" = "cm.input/v1" ] && ok "envelope carries the schema name" || no "envelope schema"
[ "$(printf '%s' "$v" | jq -r '.workers[0] | [.sourcePath, .key, .rowBad, .fields.state.status] | join(",")')" = "workers.a,a,false,valid" ] && ok "member has sourcePath, key, rowBad and typed fields" || no "member shape" "$v"
[ "$(printf '%s' "$v" | jq -r '.legacy')" = true ] && ok "no schemaVersion is a legacy view" || no "legacy flag"
cm_input_view "$ROOT/none.json" >/dev/null; [ $? = 1 ] && ok "a missing file is an unreadable view (rc 1)" || no "missing file rc"
printf '[]' > "$L"; [ "$(cm_input_view "$L" | jq -r '.readable')" = false ] && ok "a ledger that is a list is not readable" || no "list ledger"
printf 'not json' > "$L"; cm_input_decide sleep a "$L" >/dev/null; [ $? = 1 ] && ok "not JSON refuses every decision" || no "not json decide"
# --- tri-state standing (legacy defaults per action)
d "legacy: absent standing may be nudged" "{\"workers\":{\"a\":{$W,\"state\":\"running\"}}}" nudge a true
d "legacy: absent standing refuses sleep (unknown)" "{\"workers\":{\"a\":{$W,\"state\":\"running\"}}}" sleep a false "standing is unknown"
d "legacy: absent standing refuses teardown (unknown)" "{\"workers\":{\"a\":{$W,\"state\":\"done\"}}}" teardown a false "standing is unknown"
d "standing:true allows sleep" "{\"workers\":{\"a\":{$W,\"state\":\"running\",\"standing\":true}}}" sleep a true
d "standing:false refuses sleep" "{\"workers\":{\"a\":{$W,\"state\":\"running\",\"standing\":false}}}" sleep a false "not a standing lead"
d "standing:true refuses teardown" "{\"workers\":{\"a\":{$W,\"state\":\"done\",\"standing\":true}}}" teardown a false "never torn down"
d "standing:false done worker may be torn down" "{\"workers\":{\"a\":{$W,\"state\":\"done\",\"standing\":false}}}" teardown a true
for bad in '"true"' 0 1 '"no"' '{}' '[]' '""'; do
  d "standing $bad refuses sleep AND teardown AND nudge" "{\"schemaVersion\":1,\"workers\":{\"a\":{$W,\"state\":\"running\",\"standing\":$bad}}}" sleep a false "standing is unknown"
  d "standing $bad refuses teardown" "{\"workers\":{\"a\":{$W,\"state\":\"done\",\"standing\":$bad}}}" teardown a false "standing is unknown"
  d "standing $bad refuses nudge" "{\"workers\":{\"a\":{$W,\"state\":\"running\",\"standing\":$bad}}}" nudge a false "standing is unknown"
done
# --- state
d "legacy: absent state reads running (legacy default)" "{\"workers\":{\"a\":{$W,\"standing\":false}}}" nudge a true
d "state unknown enum refuses nudge" "{\"workers\":{\"a\":{$W,\"standing\":false,\"state\":\"zzz\"}}}" nudge a false "state is unknown"
d "state unknown enum refuses teardown" "{\"workers\":{\"a\":{$W,\"standing\":false,\"state\":\"zzz\"}}}" teardown a false "state is unknown"
for bad in false 0 '""' '" "' '{}' '[]' true; do
  d "state $bad refuses nudge" "{\"workers\":{\"a\":{$W,\"standing\":false,\"state\":$bad}}}" nudge a false "state is unknown"
done
d "a legacy spelling reads as its state" "{\"workers\":{\"a\":{$W,\"standing\":false,\"state\":\"torn-down\"}}}" nudge a false "not nudgeable"
d "retired is not nudged" "{\"workers\":{\"a\":{$W,\"standing\":false,\"state\":\"retired\"}}}" nudge a false "not nudgeable"
d "a state outside the enum (parked) is unknown" "{\"workers\":{\"a\":{$W,\"standing\":false,\"state\":\"parked\"}}}" nudge a false "state is unknown"
# --- schemaVersion 2: absent is unknown, nothing defaults
d "v2: absent state refuses nudge" "{\"schemaVersion\":2,\"workers\":{\"a\":{$W,\"standing\":false}}}" nudge a false "state is unknown"
d "v2: absent standing refuses nudge" "{\"schemaVersion\":2,\"workers\":{\"a\":{$W,\"state\":\"running\"}}}" nudge a false "standing is unknown"
d "v2: absent host refuses" "{\"schemaVersion\":2,\"workers\":{\"a\":{\"path\":\"/w/a\",\"state\":\"running\",\"standing\":false}}}" nudge a false "host is unreadable"
d "v2: fully typed row is permitted" "{\"schemaVersion\":2,\"workers\":{\"a\":{$W,\"state\":\"running\",\"standing\":false}}}" nudge a true
d "an invalid schemaVersion refuses everything" "{\"schemaVersion\":\"2\",\"workers\":{\"a\":{$W,\"state\":\"running\",\"standing\":false}}}" nudge a false "schemaVersion is invalid"
# --- host
d "legacy: absent host key is local" "{\"workers\":{\"a\":{\"path\":\"/w/a\",\"state\":\"running\",\"standing\":false}}}" nudge a true
for bad in null false 0 '""' '" "' '{}' '[]' '"LOCAL"' '" local "'; do
  case "$bad" in null) continue ;; esac
  d "host $bad is invalid, never local" "{\"workers\":{\"a\":{\"host\":$bad,\"path\":\"/w/a\",\"state\":\"running\",\"standing\":false}}}" nudge a false "host is unreadable"
done
d "a worker on another host is not acted on here" "{\"workers\":{\"a\":{\"host\":\"host-a\",\"path\":\"/w/a\",\"state\":\"running\",\"standing\":false}}}" nudge a false "worker is on host host-a"
# --- path aliases
d "alias worktree counts when path is absent" "{\"workers\":{\"a\":{\"host\":\"local\",\"worktree\":\"/w/a\",\"state\":\"running\",\"standing\":false}}}" nudge a true
d "an invalid canonical path is not rescued by an alias" "{\"workers\":{\"a\":{\"host\":\"local\",\"path\":false,\"worktree\":\"/w/a\",\"state\":\"running\",\"standing\":false}}}" nudge a false "path is unreadable"
d "conflicting path and alias hold" "{\"workers\":{\"a\":{\"host\":\"local\",\"path\":\"/w/a\",\"worktreePath\":\"/w/b\",\"state\":\"running\",\"standing\":false}}}" nudge a false "path is unreadable"
# --- a row that is not an object, no row, no container
d "a null worker row refuses" '{"workers":{"a":null}}' nudge a false "unreadable"
d "a list worker row refuses" '{"workers":{"a":[]}}' nudge a false "unreadable"
d "no such worker refuses" '{"workers":{}}' nudge a false "no such worker"
d "workers as a list refuses" '{"workers":[]}' nudge a false "workers is invalid"
# --- teardown holds
BASE="\"standing\":false,\"state\":\"done\""
d "open follow-up on the worker holds teardown" "{\"workers\":{\"a\":{$W,$BASE}},\"followUps\":[{\"id\":\"f\",\"worker\":\"a\",\"state\":\"open\"}]}" teardown a false "open follow-up f"
d "an escalated follow-up (issue number) does not hold" "{\"workers\":{\"a\":{$W,$BASE}},\"followUps\":[{\"id\":\"f\",\"worker\":\"a\",\"state\":\"open\",\"issue\":12}]}" teardown a true
for bad in 0 -1 '"#12"' '"12"' '"none"' true '""'; do
  d "follow-up issue $bad is not an escalation" "{\"workers\":{\"a\":{$W,$BASE}},\"followUps\":[{\"id\":\"f\",\"worker\":\"a\",\"state\":\"open\",\"issue\":$bad}]}" teardown a false "open follow-up"
done
d "a follow-up with a real issue URL does not hold" "{\"workers\":{\"a\":{$W,$BASE}},\"followUps\":[{\"id\":\"f\",\"worker\":\"a\",\"state\":\"open\",\"issueUrl\":\"https://github.com/o/r/issues/5\"}]}" teardown a true
d "a done follow-up does not hold" "{\"workers\":{\"a\":{$W,$BASE}},\"followUps\":[{\"id\":\"f\",\"worker\":\"a\",\"state\":\"done\"}]}" teardown a true
d "an open follow-up on a child holds the parent" "{\"workers\":{\"a\":{$W,$BASE},\"c\":{\"host\":\"local\",\"path\":\"/w/c\",\"state\":\"running\",\"parent\":\"a\"}},\"followUps\":[{\"id\":\"f\",\"worker\":\"c\",\"state\":\"open\"}]}" teardown a false "open follow-up f on c"
d "a follow-up that is not an object holds (may be this one's)" "{\"workers\":{\"a\":{$W,$BASE}},\"followUps\":[null]}" teardown a false "unreadable"
d "followUps as an object holds every teardown" "{\"workers\":{\"a\":{$W,$BASE}},\"followUps\":{}}" teardown a false "followUps is unreadable"
d "a follow-up with an unreadable worker in ANOTHER, REAL lane (a lane row) does not hold (bounded)" "{\"workers\":{\"a\":{$W,$BASE,\"lane\":\"x\"}},\"lanes\":{\"y\":{\"state\":\"running\"}},\"followUps\":[{\"id\":\"f\",\"worker\":null,\"lane\":\"y\",\"state\":\"open\"}]}" teardown a true
d "a follow-up with an unreadable worker and no lane holds" "{\"workers\":{\"a\":{$W,$BASE,\"lane\":\"x\"}},\"followUps\":[{\"id\":\"f\",\"worker\":null,\"state\":\"open\"}]}" teardown a false "may be this one"
d "a dangling parent is its own root, not a hold" "{\"workers\":{\"a\":{$W,$BASE,\"parent\":\"gone\"}}}" teardown a true
d "an unreadable parent holds" "{\"workers\":{\"a\":{$W,$BASE,\"parent\":false}}}" teardown a false "parent is unreadable"
d "lane lead holds teardown" "{\"workers\":{\"a\":{$W,$BASE}},\"lanes\":{\"pr\":{\"lead\":\"a\"}}}" teardown a false "lead of lane pr"
d "a lane row that is not an object holds" "{\"workers\":{\"a\":{$W,$BASE}},\"lanes\":{\"pr\":null}}" teardown a false "lane pr is unreadable"
d "epicConflict non-list holds" "{\"workers\":{\"a\":{$W,$BASE,\"epicConflict\":{}}}}" teardown a false "epicConflict is unreadable"
d "beadsEpic false holds" "{\"workers\":{\"a\":{$W,$BASE,\"beadsEpic\":false}}}" teardown a false "beadsEpic is unreadable"
# --- duplicate keys 
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false,"state":"done"}}}' > "$L"
[ "$(cm_input_dupkeys "$L" | wc -l | tr -d ' ')" = 1 ] && ok "cm_input_dupkeys finds the repeated leaf path" || no "dupkeys count"
out="$(cm_input_decide nudge a "$L")"; [ "$(printf '%s' "$out" | jq -r '.permit')" = false ] && ok "a worker row with a repeated key refuses (rowBad)" || no "dup row" "$out"
d "a repeated key in ANOTHER row does not refuse this one" '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false},"b":{"state":"x","state":"y"}}}' nudge a true
printf '%s' '{"schemaVersion":2,"schemaVersion":3,"workers":{}}' > "$L"
[ "$(cm_input_view "$L" | jq -r '.schemaVersion.status')" = invalid ] && ok "a repeated schemaVersion is invalid" || no "dup schemaVersion"
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}}}' > "$L"
[ -z "$(cm_input_dupkeys "$L")" ] && ok "no duplicates in a clean ledger" || no "clean dupkeys"
# --- asks: blank, missing or duplicate id is rowBad
printf '%s' '{"workers":{},"asks":[{"id":"a1","state":"open"},{"id":"a1","state":"open"},{"state":"open"},{"id":" ","state":"open"},{"id":"ok","state":"open"},null]}' > "$L"
v="$(cm_input_view "$L")"
[ "$(printf '%s' "$v" | jq -r '[.asks[] | .rowBad != false] | map(tostring) | join(",")')" = "true,true,true,true,false,true" ] && ok "asks: duplicate, missing, blank ids and a null row are rowBad" || no "asks rowBad" "$(printf '%s' "$v" | jq -c '[.asks[] | .rowBad]')"
# --- the live-reply adapter
lt() { printf '%s' "$2" | jq -c -L "$HERE/.." --argjson cfg "$(cm_input_cfg)" "include \"input-view\"; $1"; }
r='{"result":{"terminals":[{"handle":"t1","agentIdentity":"claude"},{"handle":"t2"},{"handle":"t3","agentIdentity":false},"x"],"truncated":false}}'
[ "$(lt 'iv_live_terminals(.; $cfg) | [.complete, (.terminals | map(.agent) | join(","))] | join(" ")' "$r" | tr -d '"')" = "true agent,shell,unknown,unknown" ] && ok "live terminals: agent, shell, unknown (agentIdentity:false and a non-object are never a shell)" || no "live terminals" "$(lt 'iv_live_terminals(.; $cfg)' "$r")"
[ "$(lt 'iv_live_terminals(.; $cfg).complete' '{"result":{"terminals":[],"truncated":true}}')" = false ] && ok "a truncated terminal list is not complete" || no "truncated"
[ "$(lt 'iv_live_terminals(.; $cfg; [["result","truncated"]]).complete' '{"result":{"terminals":[]}}')" = false ] && ok "a reply with a repeated key (the scan found one) is not complete" || no "dups terminals"
[ "$(lt 'iv_live_worktrees(.; $cfg; [["result","worktrees",0,"id"]]).complete' '{"result":{"worktrees":[]}}')" = false ] && ok "the same for worktrees" || no "dups worktrees"
[ "$(lt 'iv_live_terminals(.; $cfg; []).complete' '{"result":{"terminals":[]}}')" = true ] && ok "no repeated key: an empty terminal list is complete" || no "dups none"
[ "$(lt 'iv_live_terminals(.; $cfg).complete' '{"ok":true}')" = false ] && ok "ok:true with no terminals array is not an empty list" || no "no terminals array"
[ "$(lt 'iv_live_terminals(.; $cfg).complete' '{"result":{"terminals":[{"handle":"a"}],"totalCount":5}}')" = false ] && ok "totalCount above the rows read is not complete" || no "totalCount"
[ "$(lt 'iv_live_terminals(.; $cfg).complete' '{"result":{"terminals":[],"truncated":false}}')" = true ] && ok "an empty, untruncated list is complete" || no "empty complete"
[ "$(lt 'iv_live_text(.).status' '"hello"')" = '"valid"' ] && [ "$(lt 'iv_live_text(.).status' '{}')" = '"invalid"' ] && [ "$(lt 'iv_live_text(.).status' 'null')" = '"missing"' ] && ok "a screen read is text, missing or invalid (never an empty screen)" || no "live text"
# --- revalidation: decide again right before acting, compare the snapshot
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}}}' > "$CM_HOME/ledger.json"
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}}}' > "$CM_HOME/ledger.json"
first="$(cm_input_decide nudge a)"
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/MOVED","state":"running","standing":false}}}' > "$CM_HOME/ledger.json"
cm_input_revalidate "$first" >/dev/null; [ $? = 1 ] && ok "revalidate refuses when the snapshot changed" || no "revalidate snapshot"
printf '%s' '{"workers":{"a":{"host":"local","path":"/w/a","state":"running","standing":false}}}' > "$CM_HOME/ledger.json"
cm_input_revalidate "$first" >/dev/null; [ $? = 0 ] && ok "revalidate accepts an unchanged snapshot" || no "revalidate same"
cm_input_revalidate '{}' >/dev/null 2>&1; [ $? = 2 ] && ok "revalidate with no prior decision fails closed" || no "revalidate empty"
# jq reads a lone surrogate escape as U+FFFD, so two keys that differ only there are ONE key to jq and two to python: a lone surrogate
# anywhere (a key or a string value) makes the document unreadable. A surrogate PAIR is one real character and stays accepted.
WA='"a":{"host":"local","path":"/w/a","standing":false,"state":"done"}'
d "control: two equal lane keys refuse" '{"schemaVersion":2,"workers":{'"$WA"'},"lanes":{"p":{"lead":"a"},"p":{"state":"idle"}}}' teardown a false "unreadable"
d "two lane keys that differ only in a lone surrogate refuse" '{"schemaVersion":2,"workers":{'"$WA"'},"lanes":{"p\udc00":{"lead":"a"},"p\udfff":{"state":"idle"}}}' teardown a false "unreadable"
d "two worker keys that differ only in a lone surrogate refuse" '{"schemaVersion":2,"workers":{'"$WA"',"b\udc00":{"host":"local","path":"/w/b","standing":false,"state":"done"},"b\udfff":{"host":"local","path":"/w/c","standing":false,"state":"done"}}}' teardown a false "unreadable"
d "two host keys that differ only in a lone surrogate refuse" '{"schemaVersion":2,"workers":{'"$WA"'},"hosts":{"h\udc00":{"reachable":true},"h\udfff":{"reachable":false}}}' teardown a false "unreadable"
d "a lone surrogate in a string value refuses" '{"schemaVersion":2,"workers":{"a":{"host":"local","path":"/w/a","standing":false,"state":"done","note":"x\ud800y"}}}' teardown a false "unreadable"
d "a lone high surrogate before a non-surrogate escape refuses" '{"schemaVersion":2,"workers":{"a":{"host":"local","path":"/w/a","standing":false,"state":"done","note":"\ud83dA"}}}' teardown a false "unreadable"
d "control: a surrogate pair in a string value is accepted" '{"schemaVersion":2,"asks":[],"followUps":[],"lanes":{},"workers":{"a":{"host":"local","path":"/w/a","standing":false,"state":"done","note":"\ud83d\ude00"}}}' teardown a true
d "control: a surrogate pair in a key is accepted" '{"schemaVersion":2,"asks":[],"followUps":[],"workers":{'"$WA"'},"lanes":{"p\ud83d\ude00":{"state":"idle"}}}' teardown a true
D8="$ROOT/d8.json"
for doc in '{"a\udc00":1,"a\udfff":2}' '{"x":"\udfff"}' '[{"k":["\ud800"]}]'; do
  printf '%s' "$doc" > "$D8"; python3 "$HERE/../jdupkeys" "$D8" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "jdupkeys: a lone surrogate is unreadable (rc 2): $doc" || no "jdupkeys lone surrogate $doc" "rc=$rc"
done
for doc in '{"x":"\ud83d\ude00","\ud83d\ude00":1}' '{"p":"\u00e9\ufffd"}'; do
  printf '%s' "$doc" > "$D8"; out="$(python3 "$HERE/../jdupkeys" "$D8" 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && ok "jdupkeys: a pair or a real U+FFFD scans clean: $doc" || no "jdupkeys pair $doc" "rc=$rc $out"
done
# one blank test. A field made only of zero-width or other invisible code points is blank (invalid), never a name
BV="$ROOT/b9.json"
for cp in 200b 200c 200d 2060 feff 180e 0020 00a0 2003 3000 2063 00ad 3164 202e 034f 115f 1160 ffa0 fe00 fe0f 200e 200f 202a 2064 0085 2028 2029 0009 001f 2800; do
  u="\u$cp"
  printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"%s","parent":"%s","worktreeId":"%s","terminal":"%s"}},"lanes":{"x":{"lead":"%s"}},"followUps":[{"id":"f","worker":"%s","lane":"%s","owner":"o","state":"open"}]}' "$u" "$u" "$u" "$u" "$u" "$u" "$u" > "$BV"
  got="$(cm_input_view "$BV" | jq -r '[.workers[0].fields.lane.status, .workers[0].fields.parent.status, .workers[0].fields.worktreeId.status, .workers[0].fields.terminal.status, .followUps[0].fields.worker.status, .followUps[0].fields.lane.status, .lanes[0].fields.lead.status] | join(",")')"
  [ "$got" = "invalid,invalid,invalid,invalid,invalid,invalid,invalid" ] && ok "blank U+$cp is invalid in lane, parent, worktreeId, terminal, a follow-up worker and lane, a lane lead" || no "blank U+$cp" "$got"
done
printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"l\u200b","parent":"p"}}}' > "$BV"
[ "$(cm_input_view "$BV" | jq -r '[.workers[0].fields.lane.status, .workers[0].fields.parent.status] | join(",")')" = "valid,valid" ] && ok "control: text with a zero-width space inside it is still text" || no "inner zero-width control"
printf '{"workers":{"a":{"host":"local","path":"\u200b","state":"done","standing":false}}}' > "$BV"
[ "$(cm_input_view "$BV" | jq -r '.workers[0].fields.path.status')" = invalid ] && ok "a path of only U+200B is invalid" || no "path zero-width"
# a text field (name, id, lane, parent, ...) has no control character in it; a worktree comment is free text and may span lines
for cp in 000a 0009 0001 007f 000d; do
  u="x\u$cp""y"
  printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false,"lane":"%s","parent":"%s","worktreeId":"%s","terminal":"%s","beadsEpic":"%s"}},"lanes":{"x":{"lead":"%s"}},"followUps":[{"id":"f","worker":"%s","lane":"%s","owner":"o","state":"open"}]}' "$u" "$u" "$u" "$u" "$u" "$u" "$u" "$u" > "$BV"
  got="$(cm_input_view "$BV" | jq -r '[.workers[0].fields.lane.status, .workers[0].fields.parent.status, .workers[0].fields.worktreeId.status, .workers[0].fields.terminal.status, .workers[0].fields.beadsEpic.status, .followUps[0].fields.worker.status, .followUps[0].fields.lane.status, .lanes[0].fields.lead.status] | join(",")')"
  [ "$got" = "invalid,invalid,invalid,invalid,invalid,invalid,invalid,invalid" ] && ok "a control character U+$cp inside text is invalid in every text field" || no "control U+$cp" "$got"
done
# ONE single-line predicate (no control character, no U+2028 or U+2029) under EVERY single-line kind: str (a parent here), strlist, host, path, the part of an
# issue URL after the number, and an object key (a worker key). Each class of character x each kind.
for cp in 0009 000b 0000 0085 2028 2029 001b 000a 000d 007f; do
  printf '{"workers":{"a":{"host":"h\\u%sx","path":"/w/a\\u%sb","state":"done","standing":false,"parent":"p\\u%sq","epicConflict":["e","f\\u%sg"]},"T\\u%sx":{"host":"local","path":"/w/t","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5#a\\u%sb"}]}' "$cp" "$cp" "$cp" "$cp" "$cp" "$cp" > "$BV"
  got="$(cm_input_view "$BV" | jq -r '[.workers[0].fields.host.status, .workers[0].fields.path.status, .workers[0].fields.parent.status, .workers[0].fields.epicConflict.status, (.workers[1].rowBad | type), .followUps[0].fields.issueUrl.status] | join(",")')"
  [ "$got" = "invalid,invalid,invalid,invalid,string,invalid" ] && ok "U+$cp is refused by every single-line kind (host, path, str, strlist, key, URL tail)" || no "one line U+$cp" "$got"
done
printf '{"workers":{"a":{"host":"box-1.example","path":"/w/my dir/a.b","state":"done","standing":false,"parent":"p q","epicConflict":["e f"]},"T-1.x_y":{"host":"local","path":"/w/t","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5?x=1&y=%%20z#a/b.c~d"}]}' > "$BV"
got="$(cm_input_view "$BV" | jq -r '[.workers[0].fields.host.status, .workers[0].fields.path.status, .workers[0].fields.parent.status, .workers[0].fields.epicConflict.status, (.workers[1].rowBad | type), .followUps[0].fields.issueUrl.status] | join(",")')"
[ "$got" = "valid,valid,valid,valid,boolean,valid" ] && ok "control: a host, a path with a space, a spaced name, a list, a plain key and a URL tail of URL characters are valid" || no "one line controls" "$got"
printf '{"workers":{"a":{"host":"local","path":"/w/a","state":"done","standing":false}},"followUps":[{"id":"f","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5#a b"},{"id":"g","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5#a\\u00a0b"},{"id":"h","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5#a\\u200bb"},{"id":"i","worker":"a","lane":"l","owner":"o","state":"open","issueUrl":"https://github.com/o/r/issues/5#a\\\\b"}]}' > "$BV"
got="$(cm_input_view "$BV" | jq -r '[.followUps[].fields.issueUrl.status] | join(",")')"
[ "$got" = "invalid,invalid,invalid,invalid" ] && ok "a URL tail with a space, a no-break space, a zero-width space or a backslash is invalid" || no "url tail" "$got"
LV="$ROOT/lv.json"
printf '%s' '{"result":{"worktrees":[{"id":"w1","path":"/w/a","comment":"line one\nline two\n"},{"id":"w2","path":"/w/b","comment":"\u2800"}]}}' > "$LV"
got="$(cm_input_live worktrees < "$LV" | jq -r '[.worktrees[0].fields.comment.status, .worktrees[1].fields.comment.status] | join(",")')"
[ "$got" = "valid,invalid" ] && ok "a worktree comment may span lines (free text); a blank one is invalid" || no "comment kind" "$got"
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
