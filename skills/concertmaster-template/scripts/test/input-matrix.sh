#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# input-matrix.sh (test): the invalid-member MATRIX of the typed input boundary (references/input-contract.md, rules 1 and 3).
# For every field the boundary models (the FAMILIES table below), one case per bad value of that field (false, 0, "", " ", {}, [], an unknown enum, a
# wrong-typed value, a name with a newline; null is the ABSENT block) for each action the field gates. The rule under test: an invalid value never
# WEAKENS a protection and never WIDENS a permission, so the decision is exactly permit:false, with the reason the family names.
# MATRIX_LEGACY=1 runs the same grid against a reader written like the usual idioms (`//` defaults, `== true`, `(.issue // .issueUrl) == null`) and prints how
# many cases it fails: the red side of the red/green pair. The default run is the green side. Negative cases need permit exactly false.
#
#   scripts/test/input-matrix.sh                   # green: the boundary, exit 0 when no case weakens or widens
#   MATRIX_LEGACY=1 scripts/test/input-matrix.sh   # red: the usual idioms, exit 0 when there ARE failures (the matrix is sensitive)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-input-matrix.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
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

GRID='
include "input-view";
def bads: [false, 0, "", " ", {}, [], "zz-unknown", "local\n", "/w/a\n"];
def isvalid($f; $v):
    if $f == "standing" then ($v | type) == "boolean"
  elif $f == "state" then ($v | type) == "string" and ($cfg.states | index($v)) != null
  elif $f == "host" then ($v | type) == "string" and ($v | test("\\A\\S+\\z")) and (($v | ascii_downcase) != "local" or $v == "local")
  elif $f == "parent" or $f == "beadsEpic" then ($v | type) == "string" and ($v | test("\\S"))
  elif $f == "epicConflict" then ($v | type) == "array"
  elif $f == "path" then ($v | type) == "string" and ($v | test("\\A/[^\\n\\r]*\\z"))
  else false end;
def acts: [ "sleep", "nudge", "resume", "capacity_kill", "teardown" ];
def base($a):
  {host: "local", path: "/w/a"}
  + (if $a == "sleep" or $a == "resume" then {state: "running", standing: true}
     elif $a == "nudge" or $a == "capacity_kill" then {state: "running", standing: false}
     else {state: "done", standing: false} end);
def ledger($a; $w; $extra): ({workers: {a: $w}} + $extra);
def td($label; $w; $extra; $sub): {label: $label, doc: ledger("teardown"; base("teardown") + $w; $extra), action: "teardown", want: false, sub: $sub};

# FAMILIES: the cases each field kind makes
def families: [
  {name: "worker standing", gen: (acts[] as $a | bads[] as $v | select(isvalid("standing"; $v) | not) | {label: ("standing " + ($v | tojson) + " refuses " + $a), doc: ledger($a; base($a) + {standing: $v}; {}), action: $a, want: false, sub: "standing is unknown"})},
  {name: "worker state", gen: (acts[] as $a | bads[] as $v | select(isvalid("state"; $v) | not) | {label: ("state " + ($v | tojson) + " refuses " + $a), doc: ledger($a; base($a) + {state: $v}; {}), action: $a, want: false, sub: "state is unknown"})},
  {name: "worker host", gen: (acts[] as $a | ((bads + ["LOCAL", "Local", " local ", "local "])[] | select(isvalid("host"; .) | not)) as $v | {label: ("host " + ($v | tojson) + " refuses " + $a), doc: ledger($a; base($a) + {host: $v}; {}), action: $a, want: false, sub: "host is unreadable"}, {label: ("host null refuses " + $a), doc: ledger($a; base($a) + {host: null}; {}), action: $a, want: false, sub: "host is unreadable"})},
  {name: "worker path", gen: (acts[] as $a | bads[] as $v | select(isvalid("path"; $v) | not) | {label: ("path " + ($v | tojson) + " refuses " + $a), doc: ledger($a; base($a) + {path: $v}; {}), action: $a, want: false, sub: "path is unreadable"})},
  {name: "worker parent", gen: (bads[] as $v | select(isvalid("parent"; $v) | not) | td("parent " + ($v | tojson) + " refuses teardown"; {parent: $v}; {}; "parent is unreadable"))},
  {name: "worker beadsEpic", gen: (bads[] as $v | select(isvalid("beadsEpic"; $v) | not) | td("beadsEpic " + ($v | tojson) + " refuses teardown"; {beadsEpic: $v}; {}; "beadsEpic is unreadable"))},
  {name: "worker epicConflict", gen: (bads[] as $v | select(isvalid("epicConflict"; $v) | not) | td("epicConflict " + ($v | tojson) + " refuses teardown"; {epicConflict: $v}; {}; "epicConflict is unreadable"))},
  {name: "followUps container", gen: (bads[] as $v | select(($v | type) != "array") | td("followUps " + ($v | tojson) + " holds teardown"; {}; {followUps: $v}; "followUps is unreadable"))},
  {name: "followUps member", gen: ([null, false, 0, "", " ", []][] as $v | td("followUps member " + ($v | tojson) + " holds teardown"; {}; {followUps: [$v]}; "unreadable"))},
  {name: "followUps issue", gen: ([null, false, 0, -1, "", " ", "12", "#12", {}, []][] as $v | td("followUps issue " + ($v | tojson) + " is no escalation"; {}; {followUps: [{id: "f", worker: "a", state: "open", issue: $v}]}; "open follow-up"))},
  {name: "followUps state", gen: ([null, false, 0, "", " ", {}, [], "open", "DONE", "done "][] as $v | td("followUps state " + ($v | tojson) + " is not done"; {}; {followUps: [{id: "f", worker: "a", state: $v}]}; "open follow-up"))},
  {name: "followUps worker", gen: ([false, 0, "", " ", {}, [], "A", " a", "a ", "gone-worker"][] as $v | td("followUps worker " + ($v | tojson) + " holds (may be this one, or names no row exactly)"; {}; {followUps: [{id: "f", worker: $v, state: "open"}]}; "may be this one"))},
  {name: "lanes container", gen: (bads[] as $v | select(($v | type) != "object") | td("lanes " + ($v | tojson) + " holds teardown"; {}; {lanes: $v}; "lanes is unreadable"))},
  {name: "lanes lead", gen: (["A", " a", "a ", "gone-worker", "aa"][] as $v | td("lane lead " + ($v | tojson) + " names no worker row exactly and holds teardown"; {}; {lanes: {pr: {lead: $v}}}; "no worker row"))},
  {name: "lanes row", gen: ([null, false, 0, "", []][] as $v | td("lanes row " + ($v | tojson) + " holds teardown"; {}; {lanes: {pr: $v}}; "is unreadable"))},
  {name: "lane lead", gen: ([false, 0, "", " ", {}, []][] as $v | td("lane lead " + ($v | tojson) + " holds teardown"; {lane: "pr"}; {lanes: {pr: {lead: $v}}}; "lead is unreadable"))},
  {name: "asks container", gen: (bads[] as $v | select(($v | type) != "array") | td("asks " + ($v | tojson) + " holds teardown"; {}; {asks: $v}; "asks is unreadable"))},
  {name: "ask row", gen: ([null, false, 0, "", []][] as $v | td("ask row " + ($v | tojson) + " holds teardown"; {}; {asks: [$v]}; "unreadable"))},
  {name: "ask id", gen: ([null, "", " ", 5, []][] as $v | td("open ask about the worker with id " + ($v | tojson) + " holds teardown"; {lane: "pr"}; {asks: [{id: $v, state: "open", worker: "a"}]}; "open ask"))},
  {name: "ask state", gen: ([null, false, 0, "", {}, [], "Bogus"][] as $v | td("open ask in state " + ($v | tojson) + " holds teardown"; {}; {asks: [{id: "q", state: $v, worker: "a"}]}; "open ask"))},
  {name: "ask tie", gen: ([false, 0, "", {}, []][] as $v | td("open ask whose worker is " + ($v | tojson) + " may be this one"; {}; {asks: [{id: "q", state: "open", worker: $v}]}; "may be about this worker"))}
];

# LEGACY: the usual reader idioms (a `//` default, `== true`, a state list, `(.issue // .issueUrl) == null`), written the same way
def legacy($doc; $a):
  ($doc.workers.a) as $w
  | (($w.state // "running") | if type == "string" then (($cfg.legacy[.]) // .) else . end) as $s
  | ((($w.host // "local") == "local")) as $local
  | (($s | type) == "string" and (($cfg.dead | index($s)) == null) and (($cfg.noresume | index($s)) == null)) as $resumable
  | if $a == "nudge" then $resumable
    elif $a == "resume" then ($resumable and $w.standing == true and $local)
    elif $a == "sleep" then ($resumable and $local and ($w.standing != false))
    elif $a == "capacity_kill" then ($resumable and ($w.standing != true))
    else ($w.standing != true and ([ ($doc.followUps // [])[]? | select(type == "object" and .state != "done" and ((.issue // .issueUrl) == null) and .worker == "a") ] | length == 0)) end;
def decide($doc; $a):
  if env.MATRIX_LEGACY == "1" then ((try legacy($doc; $a) catch false) | {permit: ., reasons: []})
  else (iv_view($doc; $cfg) | iv_decide($a; .; "a"; {host: "local"})) end;
def run($c): $c + (decide($c.doc; $c.action) | {permit, reasons});

# control: the base row is permitted (so a refusal below is the field, not the fixture)
( acts[] as $a | run({label: ("control " + $a + ": a well-typed row is permitted"), doc: ledger($a; base($a); {}), action: $a, want: true, sub: null}) ),
# the families
( families[] as $f | ({family: $f.name}), ($f.gen | run(.)) ),
# schemaVersion present but invalid: every action refuses (the decisions read the version through iv_version in scripts/input-view.jq; the contract section 5)
( acts[] as $a | [false, 0, -1, "", " ", "2", {}, [], 1.5][] as $v
  | run({label: ("schemaVersion " + ($v | tojson) + " refuses " + $a), doc: ledger($a; base($a); {schemaVersion: $v}), action: $a, want: false, sub: "schemaVersion is invalid"}) ),
# a worker row that is not an object, and workers that is not an object: every action refuses
( acts[] as $a | [null, false, 0, "", [], "x"][] as $v | run({label: ("worker row " + ($v | tojson) + " refuses " + $a), doc: {workers: {a: $v}}, action: $a, want: false, sub: "unreadable"}) ),
( acts[] as $a | [false, 0, "", [], "x"][] as $v | run({label: ("workers " + ($v | tojson) + " refuses " + $a), doc: {workers: $v}, action: $a, want: false, sub: "workers is"}) ),
# the ABSENT block (key missing): the default is taken only while schemaVersion < 2
( [ "standing", "state", "host" ][] as $f | acts[] as $a
  | run({label: ("v2: absent " + $f + " refuses " + $a), doc: ledger($a; (base($a) | del(.[$f])); {schemaVersion: 2}), action: $a, want: false, sub: (if $f == "host" then "host is unreadable" else "unknown" end)}) ),
( acts[] as $a | run({label: ("absent path refuses " + $a), doc: ledger($a; (base($a) | del(.path)); {}), action: $a, want: false, sub: "path is unreadable"}) )
'
MATRIX_LEGACY="${MATRIX_LEGACY:-0}" jq -n -c -L "$HERE/.." --argjson cfg "$(cm_input_cfg)" "$GRID" > "$ROOT/out.ndjson" 2>"$ROOT/jq.err"
if [ -s "$ROOT/jq.err" ]; then no "the grid ran" "$(head -3 "$ROOT/jq.err")"; fi
jq -c 'select(.family != null)' "$ROOT/out.ndjson" | LC_ALL=C sort -u > "$ROOT/fam.ndjson"
jq -c 'select(.family == null)' "$ROOT/out.ndjson" > "$ROOT/cases.ndjson"
cases="$(wc -l < "$ROOT/cases.ndjson" | tr -d ' ')"
# every family must have produced cases, or the grid has lost one
while IFS= read -r line; do
  nm="$(printf '%s' "$line" | jq -r '.family')"
  ok "family \"$nm\" is part of the grid"
done < "$ROOT/fam.ndjson"
# negative cases need permit EXACTLY false (null or a non-boolean is a failure), controls exactly true; the green run also needs the family's reason
bad="$(jq -r 'select((.want == false and .permit != false) or (.want == true and .permit != true)) | "\(.label)\twant permit=\(.want) got \(.permit | tojson)"' "$ROOT/cases.ndjson")"
nbad=0; if [ -n "$bad" ]; then nbad="$(printf '%s\n' "$bad" | wc -l | tr -d ' ')"; fi
noreason="$(jq -r 'select(.want == false and .permit == false and .sub != null) | . as $c | select(any($c.reasons[]; contains($c.sub)) | not) | "\(.label)\tno reason has \"\(.sub)\": \(.reasons | tojson)"' "$ROOT/cases.ndjson")"
nnr=0; if [ -n "$noreason" ]; then nnr="$(printf '%s\n' "$noreason" | wc -l | tr -d ' ')"; fi
if [ "${MATRIX_LEGACY:-0}" = 1 ]; then
  printf '%s\n' "$bad" | head -25
  printf 'legacy idioms: %s of %s cases weaken a protection or widen a permission\n' "$nbad" "$cases"
  if [ "$nbad" -gt 0 ]; then ok "red: the matrix catches today's idioms ($nbad cases)"; else no "red: the matrix found nothing wrong with today's idioms"; fi
else
  distinct="$(jq -s '[.[] | {doc, action}] | unique | length' "$ROOT/cases.ndjson")"
  if [ "$cases" -gt 400 ] && [ "$distinct" -gt 100 ]; then ok "the grid has $cases cases, $distinct distinct (document, action) pairs"; else no "grid size" "only $cases cases"; fi
  for hv in LOCAL Local " local " "local "; do
    lab="$(jq -nr --arg v "$hv" '"host " + ($v | tojson) + " refuses teardown"')"
    if jq -e --arg l "$lab" -s 'any(.[]; .label == $l and .want == false)' "$ROOT/cases.ndjson" >/dev/null; then ok "the grid has the host spelling $(jq -nr --arg v "$hv" '$v | tojson') as a refusal case"; else no "host spelling missing from the grid" "$lab"; fi
  done
  if [ "$nbad" = 0 ]; then ok "green: every negative case is exactly permit:false and every control is permit:true"; else printf '%s\n' "$bad" | head -30; no "green: $nbad cases weaken or widen"; fi
  if [ "$nnr" = 0 ]; then ok "green: every refusal carries the reason its family names"; else printf '%s\n' "$noreason" | head -20; no "green: $nnr refusals have the wrong reason"; fi
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
