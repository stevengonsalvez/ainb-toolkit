#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2016  # "A && ok || bad": ok never fails; single-quoted jq programs
# ledger-rebuild.sh (test): the recovery drill (references/ledger.md § Rebuild). Hermetic: a copy of the scripts with no
# config.yaml beside them, a stub gh (fixtures/gh-issue-comments) for the lane issues and a stub fleet CLI for the host
# and worktree lists (synthetic lane-a-sweeper, lane-b-sweeper, host-b, host-c). A ledger is built and its lanes
# recorded through lane-record.sh; then the ledger and its ring are moved aside (the host is lost), the ledger is
# rebuilt, and lanes, issues, states, leads and the worker-to-lane mapping must equal the saved ledger. Then: a newer
# record merges into a present ledger without losing anything, a ring blocks --init, a gh failure writes nothing.
#
#   scripts/test/ledger-rebuild.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-ledger-rebuild.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 && command -v yq >/dev/null 2>&1 || { echo "missing dependency: jq or yq" >&2; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }

mkdir -p "$ROOT/skill" "$ROOT/bin" "$ROOT/stub" "$ROOT/cm" "$ROOT/lost" "$ROOT/tmp"
cp -R "$HERE/.." "$ROOT/skill/scripts"
cp "$HERE/fixtures/gh-issue-comments" "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
cat > "$ROOT/bin/fleet" <<'EOF'
#!/usr/bin/env bash
# stub fleet CLI: host list from $STUB/hosts.json, worktree list from $STUB/wl-<host>.json (none = unreachable)
host=local; prev=""
for a in "$@"; do [ "$prev" = --environment ] && host="$a"; prev="$a"; done
echo "$1 $2 host=$host" >> "$STUB/cli.log"
case "$1 $2" in
  "host list") cat "$STUB/hosts.json" ;;
  "worktree list") [ -f "$STUB/wl-$host.json" ] || { echo "host $host unreachable" >&2; exit 1; }; cat "$STUB/wl-$host.json" ;;
  *) echo '{"ok":false,"error":{"message":"not stubbed"}}'; exit 1 ;;
esac
EOF
chmod +x "$ROOT/bin/fleet"
unset CM_ORG CM_REPO CM_LEDGER CM_LEDGER_BAK CM_PROJECT_ID CM_SELF_WORKTREE CM_PATH_MATCH CM_ORCA_REPO PLUGLY_CLI_COMMAND CM_CLI_KIND
export PATH="$ROOT/bin:$PATH" STUB="$ROOT/stub" CM_HOME="$ROOT/cm" TMPDIR="$ROOT/tmp" ORCA_CLI_COMMAND="$ROOT/bin/fleet"
cat > "$ROOT/config.yaml" <<'EOF'
schema: concertmaster.config/v1
project: { id: acme, name: acme, owner: { name: owner, id: owner } }
github: { org: AcmeOrg, main_repo: acme-app }
worktrees: { orca_repo: acme-app, path_match: "/acme-app/", self_name: concertmaster, never_touch: [] }
hosts:
  home: local
  defaults: { role: general, maxWorkers: 4 }
  per_host: { host-b: { role: general, maxWorkers: 6, hostname: host-b } }
lanes:
  - { name: lane-a-sweeper, standing: true, issue: 11 }
  - { name: lane-b-sweeper, standing: true, issue: 12 }
  - { name: lane-c-sweeper, standing: true }
  - { name: lane-d-sweeper, standing: true }
ownership:
  leads: { lane-a-sweeper: lane-a-sweeper, lane-b-sweeper: lane-b-sweeper, lane-d-sweeper: lane-d-sweeper }
  prefixes: { task-: lane-b-sweeper }
  comment_markers: ["cm:child"]
  comment_stop_words: []
EOF
printf 'state_dir: %s\n' "$CM_HOME" >> "$ROOT/config.yaml"
export CM_CONFIG="$ROOT/config.yaml"
S="$ROOT/skill/scripts"
D=/srv/work/acme-app
wt() { jq -cn --arg n "$1" --arg c "$2" --arg d "$D" --argjson main "${3:-false}" \
  '{id: ("repo1::" + $d + "/" + $n), path: ($d + "/" + $n), branch: ("refs/heads/" + $n), displayName: $n, isMainWorktree: $main, isArchived: false, comment: $c}'; }
wl() { jq -s '{ok: true, result: {worktrees: ., truncated: false, totalCount: length}}'; }
printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"},{"kind":"environment","name":"host-b"},{"kind":"environment","name":"host-c"}]}}\n' > "$STUB/hosts.json"
{ wt concertmaster "cm:state freeze=off window=- prod=v1 at=2026-11-24T09:00:00Z"
  wt lane-a-sweeper 'cm:running sweeping\ncm:child fix-x'
  wt fix-x "cm:running fixing the export"
  wt lane-d-sweeper "cm:running sweeping, no issue of its own"
  wt acme-app "" true; } | wl > "$STUB/wl-local.json"
{ wt lane-b-sweeper "cm:asleep 2026-11-24T08:00:00Z put to sleep by lane-health; wake with scripts/lane-health.sh wake w-lane-b-sweeper --apply"
  wt lane-b-sweeper "" | jq -c '.comment = null'   # the CLI can list one worktree twice, one copy with no comment
  wt task-42 "cm:blocked which database?"
  wt stray-1 ""; } | wl > "$STUB/wl-host-b.json"

# the ledger the concertmaster had: more than any rebuild can know (live, nudges, prs, asks)
jq -n --arg d "$D" '
  def w($n; $h; $lane; $st; $stand): {host: $h, path: ($d + "/" + $n), worktreeId: ("repo1::" + $d + "/" + $n), lane: $lane, state: $st,
    standing: $stand, agent: "claude", nudges: 0, live: {pid: 4242}, spawnedAt: "2026-11-20T10:00:00Z", updatedAt: "2026-11-24T08:59:00Z"};
  {schema: "concertmaster.ledger/v1", project: "acme", createdAt: "2026-11-01T00:00:00Z", updatedAt: "2026-11-24T09:00:00Z",
   tick: {count: 420, lastAt: "2026-11-24T09:00:00Z", nextWakeSeconds: 1200},
   hosts: {local: {kind: "local", selector: "", reachable: true, lastSeenAt: "2026-11-24T09:00:00Z", offlineSince: null, role: "general", maxWorkers: 4},
           "host-b": {kind: "environment", selector: "--environment host-b", hostname: "host-b", reachable: true, lastSeenAt: "2026-11-24T09:00:00Z", offlineSince: null, role: "general", maxWorkers: 6},
           "host-c": {kind: "environment", selector: "--environment host-c", reachable: false, lastSeenAt: "2026-11-23T09:00:00Z", offlineSince: "2026-11-23T09:15:00Z", role: "general", maxWorkers: 4}},
   lanes: {"lane-a-sweeper": {state: "running", lead: "w-lane-a-sweeper", queue: [], issue: 11},
           "lane-b-sweeper": {state: "idle", lead: "w-lane-b-sweeper", queue: [], issue: 12},
           "lane-c-sweeper": {state: "absent", lead: null, queue: []},
           "lane-d-sweeper": {state: "running", lead: "w-lane-d-sweeper", queue: []}},
   workers: {concertmaster: w("concertmaster"; "local"; "concertmaster"; "running"; true),
             "w-lane-a-sweeper": w("lane-a-sweeper"; "local"; "lane-a-sweeper"; "running"; true),
             "w-fix-x": (w("fix-x"; "local"; "lane-a-sweeper"; "running"; false) + {parent: "w-lane-a-sweeper"}),
             "w-lane-b-sweeper": w("lane-b-sweeper"; "host-b"; "lane-b-sweeper"; "asleep"; true),
             "w-task-42": w("task-42"; "host-b"; "lane-b-sweeper"; "blocked-on-owner"; false),
             "w-lane-d-sweeper": w("lane-d-sweeper"; "local"; "lane-d-sweeper"; "running"; true)},
   prs: {"acme-app#341": {number: 341, state: "OPEN"}}, asks: [{id: "ask-1", state: "open"}]}' > "$CM_HOME/ledger.json"

lr() { bash "$S/lane-record.sh" "$@" >/dev/null 2>&1 || bad "lane-record.sh $*" "rc=$?"; }
echo 2026-11-24T10:00:00Z > "$STUB/clock"; lr post lane-a-sweeper "idle lead=w-lane-a-sweeper"
echo 2026-11-24T10:05:00Z > "$STUB/clock"; lr post lane-b-sweeper "idle lead=w-lane-b-sweeper"
echo 2026-11-24T10:10:00Z > "$STUB/clock"; lr post lane-a-sweeper "running lead=w-lane-a-sweeper"
lr post lane-a-sweeper "running lead=w-lane-a-sweeper"
[ "$(jq length "$STUB/issue-11.json") $(jq length "$STUB/issue-12.json")" = "2 1" ] && ok "setup: lane-a has 2 records, lane-b 1 (a repeat posts nothing)" || bad "setup" "$(cat "$STUB/gh.log")"
cp "$CM_HOME/ledger.json" "$ROOT/saved.json"

rb() { OUT="$(bash "$S/ledger-rebuild.sh" "$@" 2>"$ROOT/err")"; RC=$?; ERR="$(cat "$ROOT/err")"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
rb
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$STUB/cli.log" ] && ok "a ledger that has every record: current, the fleet is not even read" || bad "current" "rc=$RC $ERR"
has "...and it says so" "$ERR" "ledger current: no lane record newer than the ledger's"

# the host is lost: the ledger and its ring go with it
mv "$CM_HOME/ledger.json" "$CM_HOME/ledger.bak" "$ROOT/lost/"
rb
[ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.workers and .lanes and .hosts' >/dev/null 2>&1 && [ ! -e "$CM_HOME/ledger.json" ] \
  && ok "dry run: prints the ledger it would write, writes nothing" || bad "dry run" "rc=$RC $ERR"
has "...says the ledger is missing" "$ERR" "no ledger at $CM_HOME/ledger.json"
has "...reports the unreachable host" "$ERR" "host host-c:"
has "...and the lane with no issue" "$ERR" "lane lane-c-sweeper: no lanes[].issue, its state is not rebuilt (its lead is)"
has "...and an orphan worktree, left to the tick" "$ERR" "worktree stray-1 @ host-b: no owner (ORPHAN), not rebuilt"
rb --apply
[ "$RC" = 0 ] && [ -s "$CM_HOME/ledger.json" ] && ok "--apply writes the ledger" || bad "apply" "rc=$RC $ERR"
R="$CM_HOME/ledger.json"

norm='{lanes: (.lanes | map_values(if .issue != null then {state, issue, lead} else {issue, lead} end)),
       workers: (.workers | map_values({host, path, lane, state})),
       hosts: (.hosts | map_values({kind, selector, role, maxWorkers}))}'
if diff <(jq -S "$norm" "$ROOT/saved.json") <(jq -S "$norm" "$R") > "$ROOT/diff"; then
  ok "drill: lanes, issues, states, leads, hosts and the worker-to-lane mapping equal the saved ledger"
else bad "drill diff (saved < > rebuilt)" "$(cat "$ROOT/diff")"; fi
got="$(jq -c '[.lanes["lane-a-sweeper"] | .state, .issue, .lead, .recordedState]' "$R")"
[ "$got" = '["running",11,"w-lane-a-sweeper","running lead=w-lane-a-sweeper"]' ] && ok "lane-a: state from the NEWEST record, its issue, its lead" || bad "lane-a" "$got"
got="$(jq -c '[.workers["w-fix-x"].lane, .workers["w-fix-x"].standing, .workers["w-task-42"].lane, .workers["w-task-42"].state, .workers["w-task-42"].standing, .workers["w-stray-1"]]' "$R")"
[ "$got" = '["lane-a-sweeper",false,"lane-b-sweeper","blocked-on-owner",null,null]' ] && ok "classify rules: a cm:child claim (standing false), a name prefix (standing unknown), no row for an orphan" || bad "mapping" "$got"
got="$(jq -c '[.workers["w-lane-b-sweeper"].state, .workers["w-lane-b-sweeper"].standing, .workers.concertmaster.lane]' "$R")"
[ "$got" = '["asleep",true,"concertmaster"]' ] && ok "a lead asleep before the loss stays asleep; the concertmaster is its own row" || bad "asleep" "$got"
got="$(jq -c '[(.workers | length), ([.workers[].path] | index("/srv/work/acme-app/acme-app")), .hosts["host-c"].reachable, .project]' "$R")"
[ "$got" = '[6,null,false,"acme"]' ] && ok "no main checkout, host-c offline, the ledger stamped with the project" || bad "shape" "$got"
got="$(jq -c '.lanes["lane-d-sweeper"] | [.issue, .state, .lead]' "$R")"
[ "$got" = '[null,null,"w-lane-d-sweeper"]' ] && ok "a lane with no issue still gets its entry and its lead (no second lead spawned)" || bad "issue-less lane" "$got"
got="$(jq -c '[(.workers | keys | map(select(startswith("w-lane-b-sweeper")))), .workers["w-lane-b-sweeper"].state, .lanes["lane-b-sweeper"].lead]' "$R")"
[ "$got" = '[["w-lane-b-sweeper"],"asleep","w-lane-b-sweeper"]' ] && ok "a worktree listed twice (one copy with no comment) is one row, still asleep, still the lead" || bad "dedupe" "$got"
grep -vE '^(host list|worktree list) ' "$STUB/cli.log" > "$ROOT/other-calls" && bad "fleet calls" "$(cat "$ROOT/other-calls")" \
  || ok "only host and worktree lists are read: no other host's files are fetched"
rb
[ "$RC" = 0 ] && [ -z "$OUT" ] && has "a second run: current" "$ERR" "ledger current" || bad "second run" "rc=$RC $ERR"

# a record newer than a present ledger (a restored backup, a lost ledger write): merged, nothing lost
jq '. + [{id: 9, created_at: "2099-01-01T00:00:00Z", body: "cm:state lane-b-sweeper running lead=w-lane-b-sweeper", author_association: "MEMBER"}]' \
  "$STUB/issue-12.json" > "$STUB/x" && mv "$STUB/x" "$STUB/issue-12.json"
{ jq -c '.result.worktrees[]' "$STUB/wl-host-b.json"; wt task-77 "cm:running new work"; } | wl > "$STUB/x" && mv "$STUB/x" "$STUB/wl-host-b.json"
jq '.workers["w-task-42"].beadsEpic = "acme-e1"' "$R" > "$ROOT/x" && mv "$ROOT/x" "$R"
rb
has "an older ledger: the dry run says it merges" "$ERR" "ledger older than the lane record"
rb --apply
got="$(jq -c '[.lanes["lane-b-sweeper"].state, .lanes["lane-b-sweeper"].lead, .workers["w-task-42"].beadsEpic, .workers["w-task-77"].lane, (.workers | length), .prs == null]' "$R")"
[ "$RC" = 0 ] && [ "$got" = '["running","w-lane-b-sweeper","acme-e1","lane-b-sweeper",7,true]' ] \
  && ok "merge: GitHub's newer state wins, a field it never knew is kept, the new worktree is added" || bad "merge" "rc=$RC $got $ERR"
cp "$ROOT/lost/ledger.json" "$R"   # the restored copy, older than every record
rb --apply
got="$(jq -c '[.lanes["lane-b-sweeper"].state, .prs["acme-app#341"].number, (.asks | length), .tick.count, (.workers | length)]' "$R")"
[ "$RC" = 0 ] && [ "$got" = '["running",341,1,420,7]' ] && ok "a restored copy keeps its prs, asks and tick; the newer lane state and worktree are laid over it" || bad "restored" "rc=$RC $got $ERR"

# merge keeps what the ledger knows better: a lane whose record is not newer, a successor lead, and asleep only tightens
rec() { jq --arg at "$2" --arg l "$3" --arg s "$4" '. + [{id: (length + 100), created_at: $at, body: "cm:state \($l) \($s)", author_association: "OWNER"}]' \
  "$STUB/issue-$1.json" > "$STUB/x" && mv "$STUB/x" "$STUB/issue-$1.json"; }
jq --arg d "$D" '.lanes["lane-a-sweeper"].state = "spawning" | .lanes["lane-a-sweeper"].lead = "w-lane-a-sweeper-2"
  | .workers["w-lane-a-sweeper-2"] = {host: "local", path: ($d + "/lane-a-sweeper-2"), lane: "lane-a-sweeper", state: "running", standing: true}
  | .workers["w-lane-b-sweeper"].state = "running" | .workers.concertmaster.path = "/old/place/concertmaster" | .workers.concertmaster.worktreeId = "old::concertmaster"' "$R" > "$ROOT/x" && mv "$ROOT/x" "$R"
rec 12 2099-01-02T00:00:00Z lane-b-sweeper "idle lead=w-lane-b-sweeper"
rec 11 2099-01-02T00:00:00Z lane-a-sweeper "paused for maintenance"
rb --apply
got="$(jq -c '[.lanes["lane-a-sweeper"].state, .lanes["lane-a-sweeper"].lead, .lanes["lane-b-sweeper"].state, .workers["w-lane-b-sweeper"].state, .workers["w-lane-b-sweeper"].asleepFrom]' "$R")"
[ "$RC" = 0 ] && [ "$got" = '["spawning","w-lane-a-sweeper-2","idle","asleep","running"]' ] \
  && ok "merge: a newer record whose first word is no lane state leaves the state alone, a live successor lead is kept, a restored row asleep on its comment goes back to sleep" \
  || bad "merge keeps" "rc=$RC $got $ERR"
has "...and the unknown word is reported" "$ERR" "lane lane-a-sweeper: newest record '2099-01-02T00:00:00Z cm:state lane-a-sweeper paused for maintenance' does not start with a lane state"
got="$(jq -c '[.workers.concertmaster.path, (.workers | keys | map(select(startswith("concertmaster"))))]' "$R")"
[ "$got" = "[\"$D/concertmaster\",[\"concertmaster\"]]" ] && ok "the concertmaster row keeps its key and moves to where it runs now" || bad "self" "$got"

# a lead that claims a configured lane with cm:child: the claimed row is never written standing false (teardown would take it)
{ jq -c '.result.worktrees[] | if .displayName == "lane-a-sweeper" then .comment += "\\ncm:child lane-c-sweeper" else . end' "$STUB/wl-local.json"
  wt lane-c-sweeper "cm:running"; } | wl > "$STUB/x" && mv "$STUB/x" "$STUB/wl-local.json"
rec 11 2099-01-03T00:00:00Z lane-a-sweeper "running lead=w-lane-a-sweeper"
rb
got="$(printf '%s' "$OUT" | jq -c '[.workers["w-lane-c-sweeper"].lane, .workers["w-lane-c-sweeper"].standing]')"
[ "$RC" = 0 ] && [ "$got" = '["lane-a-sweeper",null]' ] && ok "a cm:child claim on a lane-shaped name: standing unknown, not false" || bad "laneish" "rc=$RC $got $ERR"

touch "$STUB/gh-fail"
rb
[ "$RC" = 1 ] && [ -z "$OUT" ] && has "gh down with a present ledger: even the dry run judges nothing (never 'current')" "$ERR" "nothing judged or written" || bad "gh fail dry" "rc=$RC $ERR"
mv "$STUB/gh-fail" "$STUB/gh-fail.off"

# a lost ledger whose ring is still here (the merges above filled it): --init is refused, restore first
mv "$R" "$ROOT/lost/ledger-2.json"
touch "$STUB/gh-fail"
rb --apply
[ "$RC" = 1 ] && [ ! -e "$R" ] && has "ring present: refused before gh or the fleet is read (gh down too), with the restore command" "$ERR" "holds copies: restore the newest first" || bad "ring" "rc=$RC $ERR"
mv "$STUB/gh-fail" "$STUB/gh-fail.off"
mv "$CM_HOME/ledger.bak" "$ROOT/lost/ledger.bak-2"

touch "$STUB/gh-fail"
rb --apply
[ "$RC" = 1 ] && [ ! -e "$R" ] && has "a lane issue gh cannot read: --apply writes nothing" "$ERR" "nothing judged or written" || bad "gh fail" "rc=$RC $ERR"
mv "$STUB/gh-fail" "$STUB/gh-fail.off"

yq 'del(.lanes[].issue)' "$CM_CONFIG" > "$ROOT/noissue.yaml"
CM_CONFIG="$ROOT/noissue.yaml" rb --apply
[ "$RC" = 4 ] && [ ! -e "$R" ] && has "no ledger and no lane record: exit 4, first boot, nothing written" "$ERR" "this is first boot" || bad "first boot" "rc=$RC $ERR"

jq '.project = "other"' "$ROOT/lost/ledger-2.json" > "$R"
rb
[ "$RC" = 3 ] && ok "another project's ledger: exit 3, nothing read" || bad "foreign" "rc=$RC $ERR"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
