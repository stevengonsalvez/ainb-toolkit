#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# digest-gh.sh: behaviour tests for digest.sh sourcing Merged, Deployed and the open PR count from gh, and
# for the lastSentAt window. gh is a PATH stub answering from files in $STUB: no network (it also answers
# `run list` and `run view`). CM_HOME, HOME and the ledger live in a mktemp dir.
#
#   scripts/test/digest-gh.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../digest.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-digest-gh.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
STUB="$ROOT/stub"
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/cm" "$STUB"
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT  CM_DIGEST_GH_TIMEOUT CM_TZ CM_TZ_LABEL
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" STUB_DIR="$STUB" PATH="$ROOT/bin:$PATH"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
cp "$CM_CONFIG" "$ROOT/config.base.yaml"
L="$ROOT/cm/ledger.json"

# gh stub: `gh pr list -R <repo> --state merged|open ...` answers from $STUB/<state>.json; `gh run list`
# answers from $STUB/runs.json; `gh run view <id>` answers from $STUB/run-<id>.json. Each exits with
# $STUB/<key>.rc (default 0); $STUB/<key>.sleep makes it hang first.
cat > "$ROOT/bin/gh" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh.args"
state=""
if [ "${1:-}" = run ]; then
  case "${2:-}" in list) state=runs ;; view) state="run-${3:-}" ;; esac
else
  while [ $# -gt 0 ]; do case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac; done
fi
[ -f "$STUB_DIR/$state.sleep" ] && exec sleep "$(cat "$STUB_DIR/$state.sleep")"
[ -f "$STUB_DIR/$state.json" ] && cat "$STUB_DIR/$state.json"
rc=0; [ -f "$STUB_DIR/$state.rc" ] && rc="$(cat "$STUB_DIR/$state.rc")"
[ "$rc" != 0 ] && echo "gh: HTTP 401 stub" >&2
exit "$rc"
S
chmod +x "$ROOT/bin/gh"

PASS=0; FAIL=0
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi
}
has() { # has <label> <text> <fixed string that must be in it>
  case "$2" in *"$3"*) PASS=$((PASS + 1)); printf 'PASS %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s: "%s" not in:\n%s\n' "$1" "$3" "$2" ;; esac
}
lacks() { # lacks <label> <text> <fixed string that must NOT be in it>
  case "$2" in *"$3"*) FAIL=$((FAIL + 1)); printf 'FAIL %s: "%s" found in:\n%s\n' "$1" "$3" "$2" ;; *) PASS=$((PASS + 1)); printf 'PASS %s\n' "$1" ;; esac
}
reset() { rm -rf -- "${STUB:?}"/*; }
# ago <hours>: an ISO UTC time that many hours ago.
ago() { jq -nr --argjson h "$1" 'now - $h * 3600 | floor | todate'; }
# ledger [lastSentAt]: an emptied ledger (no PRs, no workers), optionally with lastSentAt.
ledger() { jq -n --arg ls "${1:-}" '{schema: "concertmaster.ledger/v1", workers: {}, prs: {}}
  | if $ls != "" then .digests = {lastSentAt: $ls} else . end' > "$L"; }
# pr <number> <title> <hours ago> [login]
pr() { jq -nc --argjson n "$1" --arg t "$2" --arg at "$(ago "$3")" --arg login "${4:-alice}" \
  '{number: $n, title: $t, mergedAt: $at, author: {login: $login}, url: "https://github.com/AcmeOrg/acme-app/pull/\($n)"}'; }
run() { "$SCRIPT" "$@" 2>"$ROOT/err"; }

# 1. empty ledger, gh returns merged PRs: Merged lists them, open count comes from gh ------------------
reset; ledger
{ pr 201 "first merged" 8; pr 202 "second merged" 2 bob; } | jq -s -c . > "$STUB/merged.json"
printf '[{"number":1},{"number":2},{"number":3}]' > "$STUB/open.json"
OUT="$(run --full)"; RC=$?
check "empty ledger: exit 0" "$RC" "0"
has "empty ledger: Merged lists gh PRs" "$OUT" "Merged (2)"
has "empty ledger: oldest merge first" "$OUT" "$(printf -- '- #201 first merged (alice)\n- #202 second merged (bob)')"
has "empty ledger: open count from gh" "$OUT" "open PRs: 3"
lacks "empty ledger: no ledger-derived tracked count" "$OUT" "open PRs tracked"
has "header names the project and the zone" "$OUT" "Acme concertmaster digest"
has "header window defaults to 12h" "$OUT" "(last 12h)"
check "gh asked for the configured repo, merged then open" "$(sed -e 's/--search [^ ]*//' "$STUB/gh.args" | tr -s ' ' | tr '\n' '|')" \
  "pr list -R AcmeOrg/acme-app --state merged --json number,title,mergedAt,author,url --limit 100|pr list -R AcmeOrg/acme-app --state open --json number --limit 1000|"
SEARCH="$(grep -- '--state merged' "$STUB/gh.args" | sed -e 's/.*--search merged:>=\([^ ]*\) .*/\1/')"
check "12h cut-off sent to gh (within a minute)" "$(jq -nr --arg a "$SEARCH" --arg b "$(ago 12)" '(($a | fromdateiso8601) - ($b | fromdateiso8601)) | fabs < 60')" "true"

# 2. lastSentAt: newer than 12h narrows the window, older widens it ------------------------------------
LS="$(ago 2.9)"; reset; ledger "$LS"
{ pr 230 "inside" 1; pr 229 "before last digest" 5; } | jq -s -c . > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
has "lastSentAt 2.9h ago: window is 3h" "$OUT" "(last 3h)"
has "lastSentAt 2.9h ago: PR after it listed" "$OUT" "#230 inside"
lacks "lastSentAt 2.9h ago: PR before it dropped" "$OUT" "#229"
has "lastSentAt 2.9h ago: Merged (1)" "$OUT" "Merged (1)"
SEARCH="$(grep -- '--state merged' "$STUB/gh.args" | sed -e 's/.*--search merged:>=\([^ ]*\) .*/\1/')"
check "lastSentAt 2.9h ago: cut-off sent to gh is lastSentAt" "$(jq -nr --arg a "$SEARCH" --arg b "$LS" '(($a | fromdateiso8601) - ($b | fromdateiso8601)) | fabs < 1')" "true"
# the window starts at lastSentAt exactly: 2.5h-old PR is in the previous digest (sent 2.1h ago), not this one
LS="$(ago 2.1)"; reset; ledger "$LS"
{ pr 9001 "already in last digest" 2.5; pr 9002 "after last digest" 2.0; } | jq -s -c . > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
has "lastSentAt 2.1h ago: header rounds the gap up" "$OUT" "(last 3h)"
has "lastSentAt 2.1h ago: PR after it listed" "$OUT" "#9002 after last digest"
lacks "lastSentAt 2.1h ago: PR merged before it not listed again" "$OUT" "#9001"
has "lastSentAt 2.1h ago: Merged (1)" "$OUT" "Merged (1)"
SEARCH="$(grep -- '--state merged' "$STUB/gh.args" | sed -e 's/.*--search merged:>=\([^ ]*\) .*/\1/')"
check "lastSentAt 2.1h ago: gh cut-off is lastSentAt" "$(jq -nr --arg a "$SEARCH" --arg b "$LS" '(($a | fromdateiso8601) - ($b | fromdateiso8601)) | fabs < 1')" "true"
reset; ledger "$(ago 29.9)"
{ pr 220 "twenty hours ago" 20; } | jq -s -c . > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
has "lastSentAt 29.9h ago: window rounds up to 30h" "$OUT" "(last 30h)"
has "lastSentAt 29.9h ago: PR from 20h ago listed (12h would drop it)" "$OUT" "#220 twenty hours ago"
reset; ledger "$(ago 30)"
{ pr 220 "twenty hours ago" 20; } | jq -s -c . > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run --since-hours 6)"
has "--since-hours beats lastSentAt" "$OUT" "(last 6h)"
lacks "--since-hours beats lastSentAt: PR outside 6h dropped" "$OUT" "#220"
reset; ledger "not a time"; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
has "unparseable lastSentAt falls back to 12h" "$(run)" "(last 12h)"
reset; ledger "$(jq -nr 'now + 7200 | floor | todate')"; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
has "future lastSentAt falls back to 12h" "$(run)" "(last 12h)"
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
check "--since-hours abc is a usage error" "$(run --since-hours abc >/dev/null; echo $?)" "2"

# 3. gh failures say unknown, never a confident zero ---------------------------------------------------
reset; ledger
echo 1 > "$STUB/merged.rc"; echo 1 > "$STUB/open.rc"
OUT="$(run --full)"; RC=$?
check "gh down: digest still prints, exit 0" "$RC" "0"
has "gh down: Merged unknown" "$OUT" "Merged: unknown (gh failed)"
lacks "gh down: no Merged (0)" "$OUT" "Merged (0)"
has "gh down: open PRs unknown" "$OUT" "open PRs: unknown (gh failed)"
lacks "gh down: no open PRs: 0" "$OUT" "open PRs: 0"
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '{"message":"API rate limit exceeded"}' > "$STUB/open.json"
OUT="$(run --full)"
has "merged ok but empty: a real zero is Merged (0) none" "$OUT" "$(printf 'Merged (0)\n- none')"
has "open answer that is not an array: unknown" "$OUT" "open PRs: unknown (gh failed)"
reset; ledger; echo 'not json at all' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run --full)"
has "garbage merged answer: Merged unknown" "$OUT" "Merged: unknown (gh failed)"
has "garbage merged answer: open still counted" "$OUT" "open PRs: 0"
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"; echo 5 > "$STUB/merged.sleep"; echo 5 > "$STUB/open.sleep"
T0=$SECONDS; OUT="$(CM_DIGEST_GH_TIMEOUT=1 run)"; T1=$SECONDS
has "hung gh: timed out to unknown" "$OUT" "Merged: unknown (gh failed)"
check "hung gh: ended by the timeout, not the stub" "$(( T1 - T0 < 5 ))" "1"
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(CM_ORG="" CM_REPO="" CM_CONFIG=/nonexistent run)"
has "no repo configured: unknown, gh not called" "$OUT" "Merged: unknown (gh failed)"
check "no repo configured: gh not called" "$(test -e "$STUB/gh.args" && echo called || echo none)" "none"

# 4. caps, titles, the rest of the digest ---------------------------------------------------------------
reset; ledger
jq -nc --arg at "$(ago 1)" '[range(100) | {number: (6000 + .), title: "t", mergedAt: $at, author: {login: "a"}, url: "u"}]' > "$STUB/merged.json"
jq -nc '[range(1000) | {number: .}]' > "$STUB/open.json"
OUT="$(run --full)"
has "100 merged PRs: heading says 100+" "$OUT" "Merged (100+)"
has "1000 open PRs: count says 1000+" "$OUT" "open PRs: 1000+"
reset; ledger
jq -nc --arg at "$(ago 1)" '[{number: 7, title: "evil\u001b[31m title\nnewline", mergedAt: $at, author: null, url: "u"}]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
check "title control characters are flattened, missing author is ?" "$(printf '%s\n' "$OUT" | grep -c '^- #7 evil.\[31m title newline (?)$')" "1"
reset
jq -n '{workers: {"w1": {state: "running", host: "local"}, "w2": {state: "stuck", task: "stuck one", host: "host-b", lastOutputAt: "2026-01-01T00:00:00Z"}},
  hosts: {"host-b": {reachable: false}}, prs: {"1": {number: 1, state: "OPEN", mergedAt: null}}}' > "$L"
echo '[]' > "$STUB/merged.json"; echo '[{"number":9}]' > "$STUB/open.json"
OUT="$(run --full)"
has "ledger sections still work (stuck)" "$OUT" "stuck one on host-b"
has "fleet line: ledger running and offline, gh open" "$OUT" "Fleet: 1 running (local 1), open PRs: 1, offline: host-b"

# 5. digest.sh is read-only ------------------------------------------------------------------------------
reset; ledger "$(ago 3)"; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
cp "$L" "$ROOT/before.json"
run >/dev/null
check "ledger byte-identical after a run" "$(cmp -s "$ROOT/before.json" "$L" && echo same || echo changed)" "same"
check "no backup ring, lock or temp file created" "$(find "$ROOT/cm" -mindepth 1 ! -name ledger.json | wc -l | tr -d ' ')" "0"

# 6. the default text is terse and has no owner-only sections; --full adds them ---------------------------
reset; echo '[{"number":5,"title":"merged one","mergedAt":"'"$(ago 1)"'","author":{"login":"al"},"url":"u"}]' > "$STUB/merged.json"; echo '[{"number":1}]' > "$STUB/open.json"
jq -n --arg at "$(ago 1)" '{schema: "concertmaster.ledger/v1", prs: {},
  workers: {"w1": {state: "blocked-on-owner", lane: "L1", task: "needs an answer", blockedQuestion: "which way?"},
            "w2": {state: "stuck", task: "stuck one", host: "host-a", lastOutputAt: "2026-01-01T00:00:00Z"}},
  asks: [{state: "open", question: "open ask text", askedAt: $at}],
  deployWindows: [{id: "d1", state: "done", tag: "v9.9.9", finishedAt: $at, prs: [5]}]}' > "$L"
OUT="$(run)"
has "terse digest: Merged kept" "$OUT" "- #5 merged one (al)"
has "terse digest: Deployed kept" "$OUT" "- v9.9.9 at "
lacks "terse digest: no Needs section" "$OUT" "Needs Owner"
lacks "terse digest: no blocked question" "$OUT" "which way?"
lacks "terse digest: no open ask" "$OUT" "open ask text"
lacks "terse digest: no Stuck section" "$OUT" "Stuck ("
lacks "terse digest: no Fleet line" "$OUT" "Fleet:"
lacks "terse digest: no greeting" "$OUT" "Hi "
check "terse digest: gh not asked for the open PR count" "$(grep -c -- '--state open' "$STUB/gh.args")" "0"
OUT="$(run --full)"
has "--full: Merged kept" "$OUT" "- #5 merged one (al)"
has "--full: Needs section" "$OUT" "Needs Owner (2)"
has "--full: blocked question" "$OUT" "- L1 needs an answer: which way?"
has "--full: open ask" "$OUT" "- ask: open ask text"
has "--full: Stuck section" "$OUT" "Stuck (1)"
has "--full: Fleet line with the gh open count" "$OUT" "Fleet: 0 running, open PRs: 1"

# 7. Deployed comes from GitHub (tag-push runs of the deploy workflow), merged with the ledger by tag ---------
# The deploy workflow and the job that proves a prod deploy come from config (digest.deploy_workflow,
# digest.deploy_job); the names below are made up. A run's own conclusion proves nothing (a cancelled
# advisory job makes the whole run "cancelled" after prod shipped): the named job decides.
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  deploy_workflow: Release Deploy\n  deploy_job: Ship to Prod\n'; } > "$ROOT/config.deploy.yaml"
export CM_CONFIG="$ROOT/config.deploy.yaml"
runrec() { # runrec <id> <tag> <conclusion> <created hours ago> <updated hours ago> [status]: one `gh run list` row
  jq -nc --argjson id "$1" --arg tag "$2" --arg c "$3" --arg cr "$(ago "$4")" --arg up "$(ago "$5")" --arg st "${6:-completed}" \
    '{databaseId: $id, headBranch: $tag, displayTitle: "release \($tag)", event: "push", workflowName: "Release Deploy",
      status: $st, conclusion: (if $st == "completed" then $c else "" end), createdAt: $cr, updatedAt: $up}'; }
runjobs() { # runjobs <id> <hours ago the prod job finished> <name=conclusion>...: the `gh run view <id>` answer
  local id="$1" h="$2"; shift 2
  jq -nc --arg at "$(ago "$h")" --args '{jobs: ($ARGS.positional | map(split("=") | {name: .[0], status: "completed", conclusion: .[1], startedAt: $at, completedAt: $at}))}' "$@" > "$STUB/run-$id.json"; }
deploy_reset() { reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"; }
ships() { printf '%s\n' "$1" | grep -Ec "^- $2 at [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}$3\$" || true; }

# 7.1 a tag-push deploy with NO ledger row: listed from gh, although the run itself says cancelled
deploy_reset
{ runrec 4100 v9.4.100 cancelled 7 6.4; } | jq -s -c . > "$STUB/runs.json"
runjobs 4100 6.5 "Check Tag=success" "Smoke Tests=cancelled" "Ship to Prod=success" "Deploy docs=success"
OUT="$(run)"
has "deployed: a tag-push run with no ledger row is listed" "$OUT" "Deployed (1)"
check "deployed: line shape is <tag> at <time> when the ledger knows no PRs" "$(ships "$OUT" 'v9\.4\.100' '')" "1"
lacks "deployed: never a zero when a release shipped" "$OUT" "Deployed (0)"
lacks "deployed: a cancelled run with a succeeded prod job is not flagged" "$OUT" "no prod deploy job succeeded"
GA="$(tr '\n' '|' < "$STUB/gh.args")"
has "deployed: gh asked for the configured workflow, push events only, on the main repo" "$GA" "run list -R AcmeOrg/acme-app --workflow Release Deploy --event push --json"
has "deployed: gh asked for the jobs of the run in the window" "$GA" "run view 4100 -R AcmeOrg/acme-app --json jobs"
OWN="$(run --full)"
has "deployed: --full lists it too" "$OWN" "Deployed (1)"

# 7.2 the ledger also has the tag: one line, with the PRs; a "v" prefix difference does not double it
deploy_reset
{ runrec 4100 v9.4.100 cancelled 7 6.4; } | jq -s -c . > "$STUB/runs.json"
runjobs 4100 6.5 "Ship to Prod=success"
jq '.deployWindows = [{id: "w1", state: "done", tag: "v9.4.100", finishedAt: "'"$(ago 6.45)"'", prs: [101, 102]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
has "deployed: ledger and gh agree: one release, counted once" "$OUT" "Deployed (1)"
check "deployed: the tag is listed once with the ledger's PRs" "$(ships "$OUT" 'v9\.4\.100' ': #101 #102')" "1"
check "deployed: no second line for the same tag" "$(printf '%s\n' "$OUT" | grep -c 'v9\.4\.100')" "1"
jq '.deployWindows[0].tag = "9.4.100"' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
check "deployed: tag match ignores a leading v" "$(printf '%s\n' "$OUT" | grep -c '9\.4\.100')" "1"
# the ledger says done, gh finds no succeeded prod job: the ledger row stands, no contradicting second line
deploy_reset
{ runrec 500 v2.0.0 failure 3 2.5; } | jq -s -c . > "$STUB/runs.json"; runjobs 500 2.6 "Ship to Prod=failure"
jq '.deployWindows = [{id: "w1", state: "done", tag: "v2.0.0", finishedAt: "'"$(ago 2.4)"'", prs: [77]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
check "deployed: a ledger done row is not contradicted by a second gh line" "$(printf '%s\n' "$OUT" | grep -c 'v2\.0\.0')" "1"
has "deployed: the ledger row is kept" "$OUT" "Deployed (1)"
has "deployed: the conflict with gh is said on the line" "$OUT" "(ledger says done, gh: no prod deploy job succeeded)"

# 7.3 two releases in the window, oldest first; a ledger-only release (no run found) still lists
deploy_reset
{ runrec 601 v3.0.2 success 2 1.5; runrec 600 v3.0.1 success 9 8.5; } | jq -s -c . > "$STUB/runs.json"
runjobs 601 1.6 "Ship to Prod=success"; runjobs 600 8.6 "Ship to Prod=success"
jq '.deployWindows = [{id: "w0", state: "done", tag: "v3.0.0", finishedAt: "'"$(ago 11)"'", prs: [1]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
has "deployed: three releases (two gh, one ledger-only)" "$OUT" "Deployed (3)"
check "deployed: oldest first" "$(printf '%s\n' "$OUT" | grep -o '^- v3\.0\.[0-9]' | tr '\n' ' ')" "- v3.0.0 - v3.0.1 - v3.0.2 "

# 7.4 a run with no succeeded prod job is not "deployed" and is not hidden
deploy_reset
{ runrec 701 v4.0.1 success 5 4.5; runrec 702 v4.0.2 failure 4 3.5; runrec 703 v4.0.3 cancelled 3 2.5; runrec 704 v4.0.4 success 2 1.5; } | jq -s -c . > "$STUB/runs.json"
runjobs 701 4.6 "Check Tag=success" "Ship to Prod=skipped"
runjobs 702 3.6 "Ship to Prod=failure"
runjobs 703 2.6 "Ship to Prod=cancelled"
echo '{"jobs":[]}' > "$STUB/run-704.json"
OUT="$(run)"
has "deployed: nothing succeeded, the count is a real zero" "$OUT" "Deployed (0)"
for t in v4.0.1 v4.0.2 v4.0.3 v4.0.4; do
  has "deployed: $t listed, not counted" "$OUT" "- $t at "
done
check "deployed: two that started (skipped or failed deploy job) are 'ran'" "$(printf '%s\n' "$OUT" | grep -c ': ran, no prod deploy job succeeded$')" "2"
check "deployed: two that never started (cancelled in the queue, no jobs) say so" "$(printf '%s\n' "$OUT" | grep -c ': not started (cancelled or skipped), no prod deploy job succeeded$')" "2"
lacks "deployed: no 'none' next to the unproven runs" "$OUT" "$(printf 'Deployed (0)\n- none')"
# an in-flight run is not a failed one
deploy_reset
{ runrec 710 v4.1.0 "" 1 0.2 in_progress; } | jq -s -c . > "$STUB/runs.json"
runjobs 710 0.5 "Check Tag=success"
has "deployed: a run still in progress is said to be in progress" "$(run)" "v4.1.0 at "
has "deployed: in progress wording" "$(run)" "still running, no prod deploy job succeeded yet"
lacks "deployed: in progress is not 'ran, no prod deploy job succeeded'" "$(run)" "ran, no prod deploy job succeeded"

# 7.5 the window: a run that finished before it is not listed (and its jobs are not fetched); one that started before it and finished inside is
deploy_reset
{ runrec 801 v5.0.1 success 30 29.5; runrec 802 v5.0.2 success 13 11.5; } | jq -s -c . > "$STUB/runs.json"
runjobs 801 29.6 "Ship to Prod=success"; runjobs 802 11.6 "Ship to Prod=success"
OUT="$(run)"
lacks "deployed: finished before the window, not listed" "$OUT" "v5.0.1"
has "deployed: created before the window, finished inside it: listed" "$OUT" "- v5.0.2 at "
check "deployed: jobs fetched only for runs near the window" "$(grep -c 'run view 801' "$STUB/gh.args")" "0"
# the prod job finished before the window although the run kept going inside it: not a deploy of this window
deploy_reset
{ runrec 810 v5.1.0 success 14 11.5; } | jq -s -c . > "$STUB/runs.json"; runjobs 810 13 "Ship to Prod=success"
OUT="$(run)"
lacks "deployed: prod job finished before the window, run tail inside it: not listed" "$OUT" "v5.1.0"
lacks "deployed: and not flagged as unproven" "$OUT" "no prod deploy job succeeded"

# 7.6 gh fails: unknown, never a zero; the ledger rows still show
deploy_reset
jq '.deployWindows = [{id: "w1", state: "done", tag: "v6.0.0", finishedAt: "'"$(ago 1)"'", prs: [9]}, {id: "w2", state: "stopped", blockedReason: "staging red", at: "'"$(ago 2)"'"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
echo 1 > "$STUB/runs.rc"
OUT="$(run)"; RC=$?
check "deployed: gh run list fails, digest still prints" "$RC" "0"
has "deployed: gh run list fails: unknown" "$OUT" "Deployed: unknown (gh failed)"
lacks "deployed: gh run list fails: no zero" "$OUT" "Deployed (0)"
has "deployed: gh down: ledger STOPPED row kept" "$OUT" "- STOPPED w2: staging red"
has "deployed: gh down: ledger done row kept" "$OUT" "- v6.0.0 at "
rm -f -- "$STUB/runs.rc"
{ runrec 901 v6.0.1 success 2 1.5; } | jq -s -c . > "$STUB/runs.json"; echo 1 > "$STUB/run-901.rc"
OUT="$(run)"
has "deployed: gh run view fails for a run in the window: unknown" "$OUT" "Deployed: unknown (gh failed)"
lacks "deployed: gh run view fails: no zero" "$OUT" "Deployed (0)"
rm -f -- "$STUB/run-901.rc"
echo 'not json' > "$STUB/runs.json"
has "deployed: garbage run list: unknown" "$(run)" "Deployed: unknown (gh failed)"
echo '{"message":"rate limited"}' > "$STUB/runs.json"
has "deployed: run list that is not an array: unknown" "$(run)" "Deployed: unknown (gh failed)"
{ runrec 901 v6.0.1 success 2 1.5; } | jq -s -c . > "$STUB/runs.json"; echo 'garbage' > "$STUB/run-901.json"
has "deployed: run view garbage: unknown" "$(run)" "Deployed: unknown (gh failed)"
echo '[]' > "$STUB/runs.json"; echo 5 > "$STUB/runs.sleep"
T0=$SECONDS; OUT="$(CM_DIGEST_GH_TIMEOUT=1 run)"; T1=$SECONDS
has "deployed: hung gh run list: timed out to unknown" "$OUT" "Deployed: unknown (gh failed)"
check "deployed: hung gh run list: ended by the timeout" "$(( T1 - T0 < 5 ))" "1"
rm -f -- "$STUB/runs.sleep"
deploy_reset; echo '[]' > "$STUB/runs.json"
has "deployed: gh answers an empty list: a real zero" "$(run)" "$(printf 'Deployed (0)\n- none')"
# STOPPED rows stay next to gh deploys
deploy_reset
{ runrec 4100 v9.4.100 cancelled 7 6.4; } | jq -s -c . > "$STUB/runs.json"; runjobs 4100 6.5 "Ship to Prod=success"
jq '.deployWindows = [{id: "w2", state: "stopped", blockedReason: "staging red", at: "'"$(ago 2)"'"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
has "deployed: gh deploy and ledger STOPPED row together" "$OUT" "$(printf -- '- STOPPED w2: staging red')"
has "deployed: the gh deploy is counted, the STOPPED row is not a deploy" "$OUT" "Deployed (1)"

# 7.6b a failing run filter is a failed read, never a quiet zero; tagless releases stay separate; a renamed job is called out
deploy_reset
echo '[1]' > "$STUB/runs.json"
OUT="$(run)"
has "deployed: a malformed run row is a failed read" "$OUT" "Deployed: unknown (gh failed)"
lacks "deployed: a malformed run row is not a zero" "$OUT" "Deployed (0)"
deploy_reset; echo '[]' > "$STUB/runs.json"
jq '.deployWindows = [{id: "a", state: "done", finishedAt: "'"$(ago 3)"'", prs: [1]}, {id: "b", state: "done", finishedAt: "'"$(ago 2)"'", prs: [2]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
has "deployed: two tagless ledger releases are two lines" "$OUT" "Deployed (2)"
lacks "deployed: tagless releases do not pool their PRs" "$OUT" "#1 #2"
deploy_reset
{ runrec 950 v7.0.1 success 3 2.5; } | jq -s -c . > "$STUB/runs.json"; runjobs 950 2.6 "Renamed Job=success"
OUT="$(run)"
has "deployed: no run has the configured job: the drift is called out" "$OUT" 'check digest.deploy_job: none of the 1 finished runs updated in the window has a job named "Ship to Prod"'
has "deployed: and the run is still listed as unproven" "$OUT" "v7.0.1 at "
deploy_reset
{ runrec 951 v7.0.2 success 3 2.5; } | jq -s -c . > "$STUB/runs.json"; runjobs 951 2.6 "Ship to Prod=success"
lacks "deployed: configured job present: no drift note" "$(run)" "check digest.deploy_job"

# 7.6c review round 2: clocks, in-flight runs, truncation, a ledger row with no finishedAt
# the ledger stamps finishedAt AFTER gh's job finished: gh before the window, ledger inside it: not listed again, no false conflict
deploy_reset
{ runrec 960 v8.0.1 success 3.5 2.9; } | jq -s -c . > "$STUB/runs.json"; runjobs 960 2.95 "Ship to Prod=success"
jq '.deployWindows = [{id: "w1", state: "done", tag: "v8.0.1", finishedAt: "'"$(ago 2.4)"'", prs: [8]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run --since-hours 2.7)"
lacks "deployed: gh placed the deploy before the window: not listed again by its later ledger time" "$OUT" "v8.0.1"
lacks "deployed: and no false 'no prod deploy job succeeded' conflict" "$OUT" "ledger says done"
OUT="$(run --since-hours 3)"
check "deployed: gh time inside the window: listed once, with the ledger PRs" "$(ships "$OUT" 'v8\.0\.1' ': #8')" "1"
lacks "deployed: ... and no conflict note" "$OUT" "ledger says done"
# an in-flight run with no deploy job yet is not config drift
deploy_reset
{ runrec 961 v8.1.0 "" 1 0.1 in_progress; } | jq -s -c . > "$STUB/runs.json"; runjobs 961 0.5 "Check Tag=success"
lacks "deployed: a run still in flight never raises the drift note" "$(run)" "check digest.deploy_job"
# a full page of runs inside the window may hide older releases
deploy_reset
{ runrec 970 v8.2.2 success 2 1.5; runrec 971 v8.2.1 success 3 2.5; } | jq -s -c . > "$STUB/runs.json"; runjobs 970 1.6 "Ship to Prod=success"; runjobs 971 2.6 "Ship to Prod=success"
has "deployed: a full page, oldest still in the window: heading says 2+" "$(CM_DIGEST_RUN_LIMIT=2 run)" "Deployed (2+)"
has "deployed: below the page size: plain count" "$(CM_DIGEST_RUN_LIMIT=3 run)" "Deployed (2)"
{ runrec 970 v8.2.2 success 2 1.5; runrec 972 v8.2.0 success 40 39.5; } | jq -s -c . > "$STUB/runs.json"
has "deployed: a full page whose oldest run is outside the window is complete" "$(CM_DIGEST_RUN_LIMIT=2 run)" "Deployed (1)"
# a done ledger row with no finishedAt falls back to its window time
deploy_reset; echo '[]' > "$STUB/runs.json"
jq '.deployWindows = [{id: "w1", state: "done", tag: "v8.3.0", at: "'"$(ago 2)"'", prs: [83]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "deployed: a done row with no finishedAt still lists (falls back to at)" "$(run)" "- v8.3.0 at "

# 7.7 config: the job name is read from config, never hard-coded; unset workflow leaves the ledger as the only source
deploy_reset
{ runrec 4100 v9.4.100 cancelled 7 6.4; } | jq -s -c . > "$STUB/runs.json"; runjobs 4100 6.5 "Deploy Prod=success" "Ship to Prod=failure"
lacks "deployed: another host's job name does not count (only digest.deploy_job)" "$(run)" "Deployed (1)"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  deploy_workflow: Other Flow\n  deploy_job: Deploy Prod\n'; } > "$ROOT/config.other.yaml"
has "deployed: a configured job name is honoured" "$(CM_CONFIG="$ROOT/config.other.yaml" run)" "Deployed (1)"
has "deployed: a configured workflow name is sent to gh" "$(grep -c 'run list -R AcmeOrg/acme-app --workflow Other Flow' "$STUB/gh.args" | sed 's/^/n=/')" "n=1"
: > "$STUB/gh.args"
OUT="$(CM_CONFIG="$ROOT/config.base.yaml" run)"
has "deployed: no deploy workflow configured: ledger only, a plain none" "$OUT" "$(printf 'Deployed (0)\n- none')"
check "deployed: no deploy workflow configured: gh run not called" "$(grep -c '^run ' "$STUB/gh.args")" "0"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  deploy_workflow: Release Deploy\n'; } > "$ROOT/config.nojob.yaml"
check "deployed: a workflow without a job is a usage error" "$(CM_CONFIG="$ROOT/config.nojob.yaml" run >/dev/null; echo $?)" "2"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  deploy_workflow: [a]\n  deploy_job: x\n'; } > "$ROOT/config.badwf.yaml"
check "deployed: a non-string workflow is a usage error" "$(CM_CONFIG="$ROOT/config.badwf.yaml" run >/dev/null; echo $?)" "2"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
