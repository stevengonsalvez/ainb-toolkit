#!/usr/bin/env bash
# programme-rollup.sh: behaviour tests for scripts/programme-rollup.sh on a temp CM_HOME with
# synthetic lanes and hosts. Never touches the live ledger.
#
#   scripts/test/programme-rollup.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_LEDGER
PR="$HERE/../programme-rollup.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-rollup.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/cmhome"
mkdir -p "$CM_HOME"
L="$CM_HOME/ledger.json"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
# has <label> <text> <fixed string>
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing: $3
$2"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "unexpected: $3
$2"; else ok "$1"; fi; }
# row <table> <programme>: the table row for a programme
row() { printf '%s\n' "$1" | grep -F "| $2 |" | head -1; }

HEADER='| programme | lead + host | state | open PRs | waiting on |'

seed() { cat > "$L" <<'JSON'
{"workers":{
  "w-lead-a":{"host":"host-a","path":"/w/lane-a-lead","lane":"lane-a","state":"running","standing":true,
              "lastComment":"cm:running 2 workers\ncm:child worker-a1"},
  "w-a1":{"host":"host-a","path":"/w/worker-a1","lane":"lane-a","parent":"w-lead-a","state":"running",
          "lastComment":"cm:blocked which table should the backfill use?"},
  "w-a2":{"host":"host-a","path":"/w/worker-a2","lane":"lane-a","parent":"w-lead-a","state":"running",
          "lastComment":"cm:running","pr":77},
  "w-lead-b":{"host":"host-b","path":"/w/lane-b-lead","lane":"lane-b","state":"idle","standing":true,
              "lastComment":"cm:idle 0 open beads"},
  "w-other":{"host":"host-b","path":"/w/unrelated","lane":"lane-z","state":"running","lastComment":"cm:blocked not mine"},
  "w-gone":{"host":"host-a","path":"/w/old-lead","lane":"lane-d","state":"gone","lastComment":"cm:running old"}},
 "lanes":{
  "lane-a":{"state":"running","lead":"w-lead-a"},
  "lane-b":{"state":"idle","lead":"w-lead-b"},
  "lane-c":{"state":"absent","lead":null},
  "lane-d":{"state":"running","lead":"w-gone"},
  "lane-e":{"state":"gone","lead":null}},
 "prs":{
  "r#5":{"number":5,"state":"OPEN","driver":"w-lead-a"},
  "r#6":{"number":6,"state":"MERGED","driver":"w-lead-a"},
  "r#7":{"number":7,"state":"OPEN","driver":"w-a1"},
  "r#77":{"number":77,"state":"CLOSED","driver":"w-a2"},
  "r#9":{"number":9,"state":"OPEN","driver":"w-other"}}}
JSON
}

echo "== two programmes, a blocked worker, an idle lane, no lead"
seed
cp "$L" "$ROOT/before.json"
OUT="$("$PR" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "exit 0"; else bad "exit $rc" "$OUT"; fi
has "header row" "$OUT" "$HEADER"
has "separator row" "$OUT" '|-----------|'
A="$(row "$OUT" lane-a)"
has "lane-a lead and host" "$A" "| lane-a-lead @ host-a |"
has "lane-a state is the first comment line" "$A" "| cm:running 2 workers |"
has "lane-a PRs: open ones only, with count" "$A" "| #5 #7 (2) |"
has "lane-a waits on its worker's cm:blocked" "$A" "| blocked: which table should the backfill use? |"
B="$(row "$OUT" lane-b)"
has "lane-b idle state" "$B" "| cm:idle 0 open beads |"
has "lane-b no PRs" "$B" "| 0 |"
has "lane-b waits on nothing" "$B" "| none |"
C="$(row "$OUT" lane-c)"
has "lane with no lead: state says no lead" "$C" "| no lead |"
has "lane with no lead: lead cell none" "$C" "| none | no lead |"
D="$(row "$OUT" lane-d)"
has "lane whose lead worker is gone: no lead" "$D" "| no lead |"
lacks "a gone lane is not listed" "$OUT" "lane-e"
lacks "another lane's PR and blocked text stay out" "$OUT" "not mine"
lacks "no blank state cell" "$OUT" "|  |"
if cmp -s "$L" "$ROOT/before.json" && [ ! -d "$CM_HOME/ledger.bak" ]; then ok "ledger untouched, no backup written"; else bad "ledger changed"; fi

echo "== --json"
J="$("$PR" --json 2>&1)"
if printf '%s' "$J" | jq -e 'length == 4 and (map(.programme) == ["lane-a","lane-b","lane-c","lane-d"])' >/dev/null 2>&1; then ok "four rows, sorted"; else bad "--json rows" "$J"; fi
if printf '%s' "$J" | jq -e '.[0] | .prs == [5,7] and .prCount == 2 and .lead == "lane-a-lead" and .host == "host-a" and .state == "cm:running 2 workers"' >/dev/null 2>&1; then ok "lane-a row fields"; else bad "lane-a json" "$J"; fi
if printf '%s' "$J" | jq -e '.[2] | .lead == null and .state == "no lead" and .waitingOn == "none" and .prs == []' >/dev/null 2>&1; then ok "no-lead row fields"; else bad "lane-c json" "$J"; fi

echo "== classify output adds the OPEN PR of a child worktree"
cat > "$ROOT/classify.json" <<'JSON'
{"items":[
 {"host":"host-a","path":"/w/worker-a2","pr":{"number":88,"state":"OPEN","author":"x"}},
 {"host":"host-a","path":"/w/worker-a1","pr":{"number":89,"state":"MERGED","author":"x"}},
 {"host":"host-b","path":"/w/unrelated","pr":{"number":90,"state":"OPEN","author":"x"}},
 {"host":"host-a","path":"/w/no-pr","pr":null}]}
JSON
OUT="$("$PR" --classify "$ROOT/classify.json" 2>&1)"
has "classify PR joins the ledger PRs" "$(row "$OUT" lane-a)" "| #5 #7 #88 (3) |"
lacks "a MERGED classify PR and another lane's PR are ignored" "$OUT" "#89"
lacks "other lane's classify PR stays out" "$OUT" "#90"
OUT="$("$PR" --classify - < "$ROOT/classify.json" 2>&1)"
has "--classify - reads stdin" "$(row "$OUT" lane-a)" "#88"
OUT="$("$PR" --classify "$ROOT/missing.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "unreadable classify file: warning, no crash"; else bad "unreadable classify exit $rc" "$OUT"; fi
has "the table still prints" "$OUT" "$HEADER"
printf 'not json' > "$ROOT/garbage.json"
OUT="$("$PR" --classify "$ROOT/garbage.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$OUT" | grep -qF "$HEADER"; then ok "garbage classify document: warning, table prints"; else bad "garbage classify exit $rc" "$OUT"; fi

echo "== waiting on: followup, waiting-owner, order, done followups"
jq '.workers["w-lead-b"].lastComment = "cm:idle 1 open bead\ncm:followup v1 owner=owner-a decide the flag\ncm:waiting-owner interview Q4"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "followup owner shown" "$(row "$OUT" lane-b)" "| followup owner=owner-a: decide the flag |"
jq '.workers["w-lead-b"].lastComment = "cm:idle\ncm:followup v1 owner=owner-a decide the flag\ncm:followup-done v1\ncm:waiting-owner interview Q4"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a done followup is skipped, next marker wins" "$(row "$OUT" lane-b)" "| waiting-owner: interview Q4 |"
jq '.workers["w-lead-a"].lastComment = "cm:blocked lead question | ready: #5"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "the lead is read before its workers" "$(row "$OUT" lane-a)" "| blocked: lead question |"
has "the lead's blocked state is the state column" "$(row "$OUT" lane-a)" "| cm:blocked lead question |"

echo "== malformed comments: no crash, no blank cell"
seed
jq '.workers["w-lead-a"].lastComment = "just some prose | with a pipe"
    | .workers["w-lead-b"].lastComment = 42
    | .workers["w-a1"].lastComment = {"x":1}
    | .workers["w-a2"].lastComment = "cm:followup !!bad"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "exit 0 on malformed comments"; else bad "exit $rc" "$OUT"; fi
has "prose comment: unparsed, the line is cut at the pipe separator" "$(row "$OUT" lane-a)" "| unparsed: just some prose |"
has "non-string comment: falls back to the ledger state" "$(row "$OUT" lane-b)" "| ledger:idle |"
lacks "no blank state cell" "$OUT" "|  |"
if [ "$(printf '%s\n' "$OUT" | tail -n +3 | grep -o '|' | wc -l | tr -d ' ')" = 24 ]; then ok "every row still has six pipes"; else bad "row shape" "$OUT"; fi
jq 'del(.workers["w-lead-a"].lastComment) | .workers["w-lead-b"].lastComment = ""' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "missing comment: ledger state" "$(row "$OUT" lane-a)" "| ledger:running |"
has "empty comment: ledger state" "$(row "$OUT" lane-b)" "| ledger:idle |"
jq '.prs = [] | .lanes["lane-a"] = "oops" | .workers["w-a2"].pr = {"number": 5}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$PR" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "odd prs and lane shapes: no crash"; else bad "odd shapes exit $rc"; fi

echo "== a secret-shaped comment is scrubbed"
seed
GH="gh"; FAKE="${GH}p_abcdefghijklmnop1234"
jq --arg t "cm:running token $FAKE" '.workers["w-lead-b"].lastComment = $t' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
lacks "token text is redacted" "$OUT" "$FAKE"

echo "== empty ledger"
printf '%s' '{"workers":{}}' > "$L"
OUT="$("$PR" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "exit 0"; else bad "exit $rc" "$OUT"; fi
has "header present" "$OUT" "$HEADER"
has "none row" "$OUT" "| none |"
if [ "$("$PR" --json)" = "[]" ]; then ok "--json prints []"; else bad "--json on an empty ledger"; fi

echo "== hostile ledgers (review findings)"
# H1: non-string path, host and PR state must not drop the whole table
cat > "$L" <<'JSON'
{"workers":{"l":{"host":"h|x\ny","path":42,"state":"running","lastComment":"cm:running"},
            "k":{"host":"h","path":"/w/k","lane":"p","state":"running","pr":3}},
 "lanes":{"p":{"state":"running","lead":"l"}},
 "prs":{"a":{"repo":"o/a","number":3,"state":5,"driver":"k"}}}
JSON
OUT="$("$PR" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "non-string path and PR state: exit 0"; else bad "non-string exit $rc" "$OUT"; fi
has "non-string path falls back to the worker id" "$(row "$OUT" p)" "| l @ h/x y |"
lacks "host with a pipe and a newline stays on one row" "$OUT" "h|x"
# H2: the same PR number in two repos is judged per repo
cat > "$L" <<'JSON'
{"workers":{"l":{"host":"h","path":"/w/l","state":"running","lastComment":"cm:running"}},
 "lanes":{"p":{"state":"running","lead":"l"}},
 "prs":{"a#5":{"repo":"o/a","number":5,"state":"CLOSED","driver":"l"},
        "b#5":{"repo":"o/b","number":5,"state":"OPEN","driver":"l"}}}
JSON
OUT="$("$PR" 2>&1)"
has "CLOSED PR in repo a does not hide the OPEN #5 in repo b" "$(row "$OUT" p)" "| #5 (1) |"
jq '.prs["c#5"] = {"repo":"o/c","number":5,"state":"OPEN","driver":"l"}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "two OPEN #5 in different repos are told apart" "$(row "$OUT" p)" "| b#5 c#5 (2) |"
# H3 / failure path: the table shell and one unknown row are printed, exit 1
printf '%s' '{"workers":{},"lanes":{"p":{"state":"running"}},"prs":"x"}' > "$L"
OUT="$("$PR" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "a ledger with prs that is not an object still rolls up"; else bad "odd prs exit $rc" "$OUT"; fi
printf 'not json' > "$L"
OUT="$("$PR" 2>/dev/null)"; rc=$?
if [ "$rc" = 1 ]; then ok "unreadable ledger: exit 1"; else bad "unreadable ledger exit $rc"; fi
has "unreadable ledger still prints the header" "$OUT" "$HEADER"
has "unreadable ledger prints an unknown row" "$OUT" "| unknown (rollup failed) |"
if [ "$("$PR" --json 2>/dev/null)" = "[]" ]; then ok "unreadable ledger: --json prints []"; else bad "--json on unreadable ledger"; fi
# M1, M2: classify with two documents, with nothing at all
seed
printf '%s\n%s\n' '{"items":[{"host":"host-a","path":"/w/worker-a2","repo":"o/a","pr":{"number":88,"state":"OPEN"}}]}' '{"items":[]}' > "$ROOT/two.json"
OUT="$("$PR" --classify "$ROOT/two.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$(row "$OUT" lane-a)" | grep -qF '#88'; then ok "two classify documents are merged"; else bad "two documents exit $rc" "$OUT"; fi
: > "$ROOT/empty.json"
OUT="$("$PR" --classify "$ROOT/empty.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'classify input is empty'; then ok "empty classify input: a warning, not silence"; else bad "empty classify exit $rc" "$OUT"; fi
# M3: this tick's classify state beats the ledger
printf '%s' '{"items":[{"host":"host-a","path":"/w/worker-a1","pr":{"number":7,"state":"MERGED"}}]}' > "$ROOT/c.json"
OUT="$("$PR" --classify "$ROOT/c.json" 2>&1)"
lacks "classify MERGED removes a ledger-OPEN PR" "$(row "$OUT" lane-a)" "#7"
# M4: trailing slashes do not break the path match
jq '.workers["w-a2"].path = "/w/worker-a2/"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
printf '%s' '{"items":[{"host":"host-a","path":"/w/worker-a2","pr":{"number":88,"state":"OPEN"}}]}' > "$ROOT/c.json"
OUT="$("$PR" --classify "$ROOT/c.json" 2>&1)"
has "a trailing slash on the ledger path still matches" "$(row "$OUT" lane-a)" "#88"
# M6: a grandchild counts, a worker in two lanes counts once
seed
jq '.workers["w-gc"] = {"host":"host-a","path":"/w/gc","parent":"w-a1","state":"running","lastComment":"cm:running","pr":31}
    | .workers["w-two"] = {"host":"host-b","path":"/w/two","lane":"lane-b","parent":"w-lead-a","state":"running","lastComment":"cm:blocked two lanes"}
    | .prs["r#32"] = {"repo":"o/a","number":32,"state":"OPEN","driver":"w-two"}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a grandchild's PR counts for the programme" "$(row "$OUT" lane-a)" "#31"
lacks "a worker naming lane-b is not also lane-a's" "$(row "$OUT" lane-a)" "#32"
has "it counts for lane-b" "$(row "$OUT" lane-b)" "#32"
has "its blocked text shows on lane-b" "$(row "$OUT" lane-b)" "| blocked: two lanes |"
# retired lead, control characters, markers that only share a prefix
jq '.workers["w-lead-b"].state = "retired"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a retired lead is no live lead" "$(row "$OUT" lane-b)" "| no lead |"
seed
jq '.workers["w-lead-b"].lastComment = "cm:running \u001b[31mred\nx\ncm:waiting-owner-later nope\ncm:blocked"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
lacks "control characters are removed from a cell" "$OUT" "$(printf '\033')"
lacks "cm:waiting-owner-later is not a waiting-owner marker" "$(row "$OUT" lane-b)" "waiting-owner"
has "a bare cm:blocked is still a blocker" "$(row "$OUT" lane-b)" "| blocked |"
# Codex review: a worker PR and a repo-qualified entry for the same PR are one PR, and classify MERGED removes it
seed
jq '.workers["w-a2"].pr = 5 | .prs["o/r#5"] = {"repo":"o/r","number":5,"state":"OPEN","driver":"w-a2"}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
J="$("$PR" --json 2>&1)"
if printf '%s' "$J" | jq -e '.[] | select(.programme == "lane-a") | ([.prs[] | select(. == 5)] | length) == 1' >/dev/null 2>&1; then ok "worker.pr and a qualified prs entry count once"; else bad "duplicate PR 5" "$J"; fi
printf '%s' '{"items":[{"host":"host-a","path":"/w/worker-a2","repo":"o/r","pr":{"number":5,"state":"MERGED"}}]}' > "$ROOT/c.json"
J="$("$PR" --classify "$ROOT/c.json" --json 2>&1)"
if printf '%s' "$J" | jq -e '.[] | select(.programme == "lane-a") | ([.prs[] | select(. == 5)] | length) == 0' >/dev/null 2>&1; then ok "classify MERGED removes the worker.pr copy too"; else bad "merged PR 5 still open" "$J"; fi
# Codex review: a done or retired worker keeps its open PR; a gone worker does not; its stale wait is not shown
seed
jq '.workers["w-a1"].lastComment = "cm:running" | .workers["w-a2"].pr = 78 | .workers["w-a2"].state = "done" | .workers["w-a2"].lastComment = "cm:blocked stale wait"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a done worker's open PR stays on its programme" "$(row "$OUT" lane-a)" "#78"
lacks "a done worker's old blocker is not a wait" "$(row "$OUT" lane-a)" "stale wait"
jq '.workers["w-a2"].state = "retired"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a retired worker's open PR stays on its programme" "$(row "$OUT" lane-a)" "#78"
jq '.workers["w-a2"].state = "gone"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
lacks "a gone worker's PR drops out" "$(row "$OUT" lane-a)" "#78"
# Codex review 2: owner-qualified and bare repo names are one repo; classify state still wins
seed
jq '.workers["w-a2"].pr = 5 | .prs["Acme/App#5"] = {"repo":"Acme/App","number":5,"state":"OPEN","driver":"w-a2"}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
J="$("$PR" --json 2>&1)"
if printf '%s' "$J" | jq -e '.[] | select(.programme == "lane-a") | ([.prs[] | select(. == 5)] | length) == 1' >/dev/null 2>&1; then ok "qualified repo and worker.pr count once"; else bad "duplicate PR 5 (qualified)" "$J"; fi
printf '%s' '{"items":[{"host":"host-a","path":"/w/worker-a2","repo":"app","pr":{"number":5,"state":"MERGED"}}]}' > "$ROOT/c.json"
J="$("$PR" --classify "$ROOT/c.json" --json 2>&1)"
if printf '%s' "$J" | jq -e '.[] | select(.programme == "lane-a") | ([.prs[] | select(. == 5)] | length) == 0' >/dev/null 2>&1; then ok "bare-repo classify MERGED removes the qualified ledger entry"; else bad "merged PR 5 still open (bare repo)" "$J"; fi
# Codex review 2: a follow-up closed in the ledger followUps[] is not a wait, a later blocker shows
seed
jq '.workers["w-lead-b"].lastComment = "cm:idle\ncm:followup v9 owner=owner-a decide the flag\ncm:blocked real blocker"
    | .followUps = [{"id":"v9","worker":"w-lead-b","lane":"lane-b","owner":"owner-a","text":"decide the flag","state":"done"}]' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
lacks "a ledger-closed follow-up is not reported as a wait" "$(row "$OUT" lane-b)" "decide the flag"
has "the next real blocker shows" "$(row "$OUT" lane-b)" "| blocked: real blocker |"
jq '.followUps[0].lane = "lane-a"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a follow-up done in another lane does not close this one" "$(row "$OUT" lane-b)" "decide the flag"
# Codex review 3: a worker PR resolves to the repo its team drives, not to another repo's PR of the same number
seed
jq '.workers["w-a2"].pr = 5
    | .prs["app#5"] = {"repo":"app","number":5,"state":"CLOSED","driver":"w-a2"}
    | .prs["tool#5"] = {"repo":"tool","number":5,"state":"OPEN","driver":"w-other"}
    | del(.prs["r#5"])' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
J="$("$PR" --json 2>&1)"
if printf '%s' "$J" | jq -e '.[] | select(.programme == "lane-a") | ([.prs[] | select(. == 5)] | length) == 0' >/dev/null 2>&1; then ok "a closed PR is not revived by another repo's open PR of the same number"; else bad "revived PR 5" "$J"; fi
# Codex review 3: a fresh MERGED observation clears a PR in the programme that only drives it
seed
jq '.prs["app#40"] = {"repo":"app","number":40,"state":"OPEN","driver":"w-lead-b"}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "the driver programme lists its open PR" "$(row "$OUT" lane-b)" "#40"
printf '%s' '{"items":[{"host":"host-a","path":"/w/worker-a1","repo":"app","pr":{"number":40,"state":"MERGED"}}]}' > "$ROOT/c.json"
OUT="$("$PR" --classify "$ROOT/c.json" 2>&1)"
lacks "a MERGED observation on another programme's worktree clears the driver's PR" "$(row "$OUT" lane-b)" "#40"
# Codex review 4: a retired lead without a lane field still owns its PRs; the row says no lead
seed
jq 'del(.workers["w-lead-a"].lane, .workers["w-a1"].lane, .workers["w-a2"].lane) | .workers["w-lead-a"].state = "retired"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a retired lead is no live lead" "$(row "$OUT" lane-a)" "| none | no lead |"
has "a retired lead's PRs and its children's stay on the programme" "$(row "$OUT" lane-a)" "#5 #7 (2)"
# Codex review 4: a value from a host that did not answer this tick is marked (last tick)
seed
OUT="$("$PR" 2>&1)"
lacks "online hosts: nothing is marked stale" "$OUT" "(last tick)"
jq '.hosts = {"host-a":{"reachable":false,"offlineSince":"2026-10-30T09:00:00Z"},"host-b":{"reachable":true,"offlineSince":null}}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "an offline host marks the lead state" "$(row "$OUT" lane-a)" "| cm:running 2 workers (last tick) |"
has "an offline host marks the PR cell" "$(row "$OUT" lane-a)" "#5 #7 (2) (last tick)"
has "an offline host marks the wait cell" "$(row "$OUT" lane-a)" "which table should the backfill use? (last tick) |"
lacks "a reachable host's programme is not marked" "$(row "$OUT" lane-b)" "(last tick)"
J="$("$PR" --json 2>&1)"
if printf '%s' "$J" | jq -e '.[] | select(.programme == "lane-a") | .stale.state and .stale.prs and .stale.waiting' >/dev/null 2>&1; then ok "--json carries the stale flags"; else bad "json stale" "$J"; fi
seed
printf '%s' '{"items":[{"class":"host-offline","host":"host-b"}]}' > "$ROOT/c.json"
OUT="$("$PR" --classify "$ROOT/c.json" 2>&1)"
has "a classify host-offline row marks that host's programme" "$(row "$OUT" lane-b)" "| cm:idle 0 open beads (last tick) |"
lacks "and not the other host's" "$(row "$OUT" lane-a)" "(last tick)"
# Codex review 5: a literal backslash-n separates comment lines, as followups.sh reads them
seed
jq '.workers["w-lead-b"].lastComment = "cm:idle\\ncm:followup f1 owner=owner-a choose flag"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "an escaped backslash-n comment still shows its follow-up" "$(row "$OUT" lane-b)" "| followup owner=owner-a: choose flag |"
has "and its first line is the state" "$(row "$OUT" lane-b)" "| cm:idle |"
# Codex review 5: a follow-up is closed under the poster's own namespace (lane, else worker id)
seed
jq 'del(.workers["w-a1"].lane) | .workers["w-a1"].lastComment = "cm:running\ncm:followup f2 owner=owner-a pick one"
    | .followUps = [{"id":"f2","worker":"w-a1","lane":"lane-a","owner":"owner-a","text":"pick one","state":"done"}]' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a done item in the programme label does not close a laneless poster's item" "$(row "$OUT" lane-a)" "pick one"
jq '.followUps[0].lane = "w-a1"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
lacks "a done item under the poster's worker id closes it" "$(row "$OUT" lane-a)" "pick one"
# Codex review 6: tabs, indentation and repeated spaces separate markers as in followups.sh
seed
jq '.workers["w-lead-b"].lastComment = "cm:idle\n  cm:followup\tv1\towner=Owner-A   decide flag\ncm:followup-done\tv2"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
has "a tab-separated, indented follow-up is a wait" "$(row "$OUT" lane-b)" "| followup owner=owner-a: decide flag |"
jq '.workers["w-lead-b"].lastComment = "cm:idle\ncm:followup\tv1\towner=owner-a decide flag\ncm:followup-done\tv1"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
lacks "a tab-separated done marker closes it" "$(row "$OUT" lane-b)" "decide flag"
jq '.workers["w-lead-b"].lastComment = "cm:idle\ncm:followup Bad_Id owner=owner-a nope"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
OUT="$("$PR" 2>&1)"
lacks "an id outside the kebab-case grammar is not a follow-up" "$(row "$OUT" lane-b)" "nope"
# Codex review 7: a reachable host whose census was truncated is marked like an offline one (--discover)
seed
printf '%s' '{"hosts":[{"name":"host-a","reachable":true,"truncated":true},{"name":"host-b","reachable":true,"truncated":false}]}' > "$ROOT/d.json"
OUT="$("$PR" --discover "$ROOT/d.json" 2>&1)"
has "a truncated host marks its programme" "$(row "$OUT" lane-a)" "| cm:running 2 workers (last tick) |"
lacks "a complete host's programme is not marked" "$(row "$OUT" lane-b)" "(last tick)"
printf '%s' '{"hosts":[{"name":"host-b","reachable":false,"truncated":null}]}' > "$ROOT/d.json"
OUT="$("$PR" --discover "$ROOT/d.json" 2>&1)"
has "an unreachable host in discover marks its programme" "$(row "$OUT" lane-b)" "(last tick)"
OUT="$("$PR" --discover "$ROOT/none.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'discover file .* not readable'; then ok "unreadable discover input: a warning, the table still prints"; else bad "discover missing exit $rc" "$OUT"; fi
printf 'not json' > "$ROOT/d.json"
OUT="$("$PR" --discover "$ROOT/d.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'discover input is not JSON'; then ok "garbage discover input: a warning, the table still prints"; else bad "discover garbage exit $rc" "$OUT"; fi
OUT="$("$PR" --discover "$ROOT/d.json" 2>/dev/null)"
has "garbage discover input marks the state cell" "$(row "$OUT" lane-a)" "| cm:running 2 workers (last tick) |"
has "and the PR cell" "$(row "$OUT" lane-a)" "#5 #7 (2) (last tick)"
has "and the wait cell" "$(row "$OUT" lane-a)" "which table should the backfill use? (last tick) |"
OUT="$("$PR" --discover "$ROOT/none.json" 2>/dev/null)"
has "an unreadable discover file marks every row" "$(row "$OUT" lane-b)" "| cm:idle 0 open beads (last tick) |"
"$PR" --discover >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "--discover without a value: exit 2"; else bad "--discover alone exit $rc"; fi
# Codex review 8: a failed GitHub PR lookup marks the PR cells, not the state cells
seed
printf '%s' '{"hosts":[{"name":"host-a","reachable":true,"truncated":false}],"errors":[{"where":"gh pr list app","message":"bulk query failed"}]}' > "$ROOT/d.json"
OUT="$("$PR" --discover "$ROOT/d.json" 2>&1)"
has "a failed PR lookup marks the PR cell" "$(row "$OUT" lane-a)" "#5 #7 (2) (last tick)"
has "it also marks a programme with no PRs" "$(row "$OUT" lane-b)" "| 0 (last tick) |"
lacks "and leaves the state cell alone" "$(row "$OUT" lane-a)" "2 workers (last tick)"
printf '%s' '{"hosts":[],"errors":[{"where":"terminal list host-a","message":"x"}]}' > "$ROOT/d.json"
OUT="$("$PR" --discover "$ROOT/d.json" 2>&1)"
lacks "an unrelated discover error marks nothing" "$OUT" "(last tick)"
# Codex review 9: a --classify input that cannot be read marks the PR cells
seed
OUT="$("$PR" --classify "$ROOT/none.json" 2>&1)"
has "a missing classify file marks the PR cell" "$(row "$OUT" lane-a)" "#5 #7 (2) (last tick)"
: > "$ROOT/c.json"
OUT="$("$PR" --classify "$ROOT/c.json" 2>&1)"
has "an empty classify input marks the PR cell" "$(row "$OUT" lane-a)" "#5 #7 (2) (last tick)"
printf 'not json' > "$ROOT/c.json"
OUT="$("$PR" --classify "$ROOT/c.json" 2>&1)"
has "an invalid classify input marks the PR cell" "$(row "$OUT" lane-a)" "#5 #7 (2) (last tick)"
printf '%s' '{"items":[]}' > "$ROOT/c.json"
OUT="$("$PR" --classify "$ROOT/c.json" 2>&1)"
lacks "a readable classify input marks nothing" "$OUT" "(last tick)"
# Codex review 10: a worker on a host the discover document does not list is stale
seed
printf '%s' '{"hosts":[{"name":"local","reachable":true,"truncated":false},{"name":"host-b","reachable":true,"truncated":false}]}' > "$ROOT/d.json"
OUT="$("$PR" --discover "$ROOT/d.json" 2>&1)"
has "a host missing from discovery marks its programme" "$(row "$OUT" lane-a)" "| cm:running 2 workers (last tick) |"
lacks "a listed host's programme is not marked" "$(row "$OUT" lane-b)" "(last tick)"
printf '%s' '{"hosts":[]}' > "$ROOT/d.json"
OUT="$("$PR" --discover "$ROOT/d.json" 2>&1)"
lacks "an empty hosts list is no evidence, nothing is marked" "$OUT" "(last tick)"
# the new files carry no em-dash
if ! grep -q "$(printf '\342\200\224')" "$HERE/../programme-rollup.sh" "$HERE/programme-rollup.sh"; then ok "no em-dash in the script or its test"; else bad "em-dash found"; fi

echo "== bad input"
rm -f "$L"
"$PR" >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then ok "missing ledger: exit 1"; else bad "missing ledger exit $rc"; fi
printf 'not json' > "$L"
"$PR" >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then ok "unreadable ledger: exit 1"; else bad "unreadable ledger exit $rc"; fi
seed
"$PR" --nope >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "unknown arg: exit 2"; else bad "unknown arg exit $rc"; fi
"$PR" --classify >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "--classify without a value: exit 2"; else bad "--classify alone exit $rc"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
