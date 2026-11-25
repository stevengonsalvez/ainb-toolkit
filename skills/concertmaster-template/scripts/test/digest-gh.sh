#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# digest-gh.sh: behaviour tests for digest.sh sourcing Merged, Deployed and the open PR count from gh, and for
# the window and the group text. gh is a PATH stub answering from files in $STUB: no network (it also answers
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
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT CM_DIGEST_GH_TIMEOUT CM_TZ CM_TZ_LABEL
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" STUB_DIR="$STUB" PATH="$ROOT/bin:$PATH"
cp "$HERE/fixtures/config.test.yaml" "$ROOT/config.yaml"
export CM_CONFIG="$ROOT/config.yaml"
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
# Fleet CLI stub: the lanes read finds no CLI answer (host list fails), so these cases never touch a real orca or plugly.
# scripts/test/digest-progress.sh covers the lanes themselves.
printf '#!/bin/sh\necho "fleet cli stub: not available" >&2\nexit 1\n' > "$ROOT/bin/orca"
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca"
export ORCA_CLI_COMMAND="$ROOT/bin/orca" PLUGLY_CLI_COMMAND="$ROOT/bin/orca"

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
# ledger [lastSentAt]: the emptied ledger of the 25 Oct wipe (no PRs, no workers), optionally with lastSentAt.
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
  "pr list -R AcmeOrg/acme-app --state merged --json number,title,mergedAt,author,url --limit 100|pr list -R AcmeOrg/acme-app --state open --json number,title,isDraft,reviewDecision --limit 1000|"
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
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"; echo 120 > "$STUB/merged.sleep"; echo 120 > "$STUB/open.sleep"
# The stub hangs 120s per call: a digest that waited for it would take minutes. The bound is far below that and far
# above a loaded host (a run under load has taken over 9s), so it tells the timeout from the stub, not a fast host
T0=$SECONDS; OUT="$(CM_DIGEST_GH_TIMEOUT=1 run)"; T1=$SECONDS
has "hung gh: timed out to unknown" "$OUT" "Merged: unknown (gh failed)"
check "hung gh: ended by the timeout, not the stub ($(( T1 - T0 ))s)" "$(( T1 - T0 < 60 ))" "1"
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(CM_ORG="" CM_REPO="" CM_CONFIG=/nonexistent run)"
has "no repo configured: unknown, gh not called" "$OUT" "Merged: unknown (gh failed)"
check "no repo configured: gh not called" "$(test -e "$STUB/gh.args" && echo called || echo none)" "none"

# 4. caps, titles, the rest of the digest ---------------------------------------------------------------
reset; ledger
jq -nc --arg at "$(ago 1)" '[range(100) | {number: (8000 + .), title: "t", mergedAt: $at, author: {login: "a"}, url: "u"}]' > "$STUB/merged.json"
jq -nc '[range(1000) | {number: .}]' > "$STUB/open.json"
OUT="$(run --full)"
has "100 merged PRs: heading says 100+" "$OUT" "Merged (100+)"
has "1000 open PRs: count says 1000+" "$OUT" "open PRs: 1000+"
reset; ledger
jq -nc --arg at "$(ago 1)" '[{number: 7, title: "evil\u001b[31m title\nnewline", mergedAt: $at, author: null, url: "u"}]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
check "title control characters are flattened, missing author is ?" "$(printf '%s\n' "$OUT" | grep -c '^- #7 evil.\[31m title newline (?)$')" "1"
reset
jq -n '{workers: {"w1": {state: "running", host: "local"}, "w2": {state: "stuck", task: "stuck one", host: "m1", lastOutputAt: "2026-01-01T00:00:00Z"}},
  hosts: {"m1": {reachable: false}}, prs: {"1": {number: 1, state: "OPEN", mergedAt: null}}}' > "$L"
echo '[]' > "$STUB/merged.json"; echo '[{"number":9}]' > "$STUB/open.json"
OUT="$(run --full)"
has "ledger sections still work (stuck)" "$OUT" "stuck one on m1"
has "fleet line: ledger running and offline, gh open" "$OUT" "Fleet: 1 running (local 1), open PRs: 1, offline: m1"

# 5. digest.sh is read-only ------------------------------------------------------------------------------
reset; ledger "$(ago 3)"; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
cp "$L" "$ROOT/before.json"
run >/dev/null
check "ledger byte-identical after a run" "$(cmp -s "$ROOT/before.json" "$L" && echo same || echo changed)" "same"
check "no backup ring, lock or temp file created" "$(find "$ROOT/cm" -mindepth 1 ! -name ledger.json | wc -l | tr -d ' ')" "0"

# 6. the group text: owner-only sections stay out of the group text -----------------------------------------
reset; echo '[{"number":5,"title":"merged one","mergedAt":"'"$(ago 1)"'","author":{"login":"al"},"url":"u"}]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
jq -n --arg at "$(ago 1)" '{schema: "concertmaster.ledger/v1", prs: {},
  workers: {"w1": {state: "blocked-on-owner", lane: "L1", task: "needs an answer", blockedQuestion: "which way?"}},
  asks: [{state: "open", question: "open ask text", askedAt: $at},
         {state: "decided", decidedBy: "verdict-agent", decidedAt: $at, issue: 77, question: "decided ask text", verdictRef: "https://example.test/v"}],
  violations: [{agent: "banned-agent", host: "host-2", worktree: "banned-lane", handle: "t1", title: "resumed banned agent"}],
  deployWindows: [{id: "d1", state: "done", tag: "v9.9.9", finishedAt: $at, prs: [5]}],
  queue: {items: [{state: "queued", issue: 12, lane: "L2", addedAt: $at}]}}' > "$L"
OUT="$(run)"
has "group digest: Merged kept" "$OUT" "- #5 merged one (al)"
has "group digest: Deployed kept" "$OUT" "- v9.9.9 at "
has "group digest: Next kept" "$OUT" "Next: #12 L2 normal (1 waiting)"
lacks "group digest: no Needs section" "$OUT" "Needs Owner"
WST="$(printf '%s\n' "$OUT" | sed -n '/^Waiting on Owner/,/^Waiting on Reviewer/p')"
has "group digest: Waiting on Owner lists the blocked question" "$WST" "- L1 needs an answer: which way?"
has "group digest: Waiting on Owner lists the open ask" "$WST" "- ask: open ask text"
lacks "group digest: no Decided section" "$OUT" "Decided while"
lacks "group digest: no forbidden-agents section" "$OUT" "Forbidden agents on Acme work"
lacks "group digest: no greeting" "$OUT" "Hi "
lacks "group digest: no Stuck section" "$OUT" "Stuck ("
lacks "group digest: no Fleet line" "$OUT" "Fleet:"
OUT="$(run --full)"
has "--full: Needs section" "$OUT" "Needs Owner (2)"
NEEDS2="$(printf '%s\n' "$OUT" | sed -n '/^Needs Owner/,/^$/p')"
has "--full: blocked question is under Needs" "$NEEDS2" "- L1 needs an answer: which way?"
has "--full: the open ask is under Needs" "$NEEDS2" "- ask: open ask text"
has "--full: Decided section" "$OUT" "Decided while you were away (verdict-agent) (1)"
has "--full: forbidden-agents section" "$OUT" "Forbidden agents on Acme work (1)"
has "--full: Stuck section" "$OUT" "Stuck ("
has "--full: Fleet line" "$OUT" "Fleet: 0 running, open PRs: 0"

# 8. Next line: an item with no issue shows by id and summary, never "#null" ---------------------------------------
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
jq '.queue.items = [
  {id: "q-1", issue: 342, lane: "dev", priority: "normal", state: "queued", addedAt: "2026-10-01T00:00:00Z"},
  {id: "q-2", issue: null, summary: "tidy the roster export", lane: "ops", priority: "urgent", state: "queued", addedAt: "2026-10-02T00:00:00Z"},
  {id: "q-3", lane: "research", priority: "normal", state: "queued", addedAt: "2026-10-03T00:00:00Z"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
has "queue: item with an issue keeps #<issue>" "$OUT" "#342 dev normal"
has "queue: issue-less item shows id and summary" "$OUT" "q-2 tidy the roster export ops urgent"
has "queue: issue-less item without a summary shows its id" "$OUT" "q-3 research normal"
has "queue: waiting count" "$OUT" "(3 waiting)"
lacks "queue: no #null in the group text" "$OUT" "#null"
jq '.queue.items = [{id: "q-9\nINJECTED line", lane: "dev\u001b[31m", summary: "", title: "from the title", state: "queued"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
check "queue: a control character in id or lane never starts a new line" "$(printf '%s\n' "$OUT" | grep -c '^INJECTED')" "0"
has "queue: an empty summary falls back to the title" "$OUT" "from the title"
jq '.queue.items = [{id: "q-1", issue: 342, lane: "dev", priority: "normal", state: "queued", addedAt: "2026-10-01T00:00:00Z"},
  {id: "q-2", issue: null, summary: "tidy the roster export", lane: "ops", priority: "urgent", state: "queued", addedAt: "2026-10-02T00:00:00Z"},
  {id: "q-3", lane: "research", priority: "normal", state: "queued", addedAt: "2026-10-03T00:00:00Z"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
lacks "queue: no #null in the --full text" "$(run --full)" "#null"
jq '.queue.items = [{id: "q-9", lane: "dev", state: "queued"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "queue: lone issue-less item" "$(run)" "Next: q-9 dev normal (1 waiting)"
reset; ledger
jq '.deployWindows = [{state: "done", tag: "v1.2.3", finishedAt: "'"$(ago 1)"'", prs: [301, null]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
has "deployed: a null PR in the list is dropped" "$OUT" "v1.2.3 at"
has "deployed: the real PR stays" "$OUT" "#301"
lacks "deployed: no #null" "$OUT" "#null"

# 9. group digest hides internal tooling PRs behind one line; the owner digest (--full) lists everything ------
reset; ledger
prf() { # prf <number> <title> <hours ago> <file>...: a merged or open PR with changed files
  local n="$1" t="$2" h="$3"; shift 3
  pr "$n" "$t" "$h" | jq -c --args '. + {files: ($ARGS.positional | map({path: ., additions: 1, deletions: 0}))}' "$@"; }
{ prf 8001 "feat(concertmaster): digest line" 3 .agents/skills/concertmaster/scripts/digest.sh
  prf 8002 "fix(app): roster sort" 2 src/pages/Roster.tsx
  prf 8003 "chore: tidy skill docs" 2 .agents/skills/concertmaster/SKILL.md .agents/skills/concertmaster/references/lanes.md
  prf 8004 "fix: mixed change" 1 .agents/skills/concertmaster/SKILL.md src/index.tsx
  prf 8005 "Fix(Concertmaster)!: loud scope case, no file list" 1
  prf 8008 "fix(concertmaster): drop column" 1 supabase/migrations/20261028_drop.sql src/index.tsx
  prf 8009 "feat(concertmaster): path-less file row" 1 .agents/skills/concertmaster/SKILL.md
  prf 8006 "feat(concertmaster,app): scope list with a product scope" 1 src/a.ts
  prf 8007 "docs: no files known" 1; } | jq -s -c 'map(if .number == 8009 then .files += [{additions: 1}] else . end)' > "$STUB/merged.json"
{ prf 8101 "docs(concertmaster): open tooling" 1 .agents/skills/concertmaster/SKILL.md
  prf 8102 "feat(app): open product" 1 src/b.ts; } | jq -s -c . > "$STUB/open.json"
OUT="$(run)"
has "group: product PR listed" "$OUT" "- #8002 fix(app): roster sort"
has "group: PR with product and tooling files listed" "$OUT" "- #8004 fix: mixed change"
has "group: scope list with a product scope listed" "$OUT" "- #8006 "
has "group: PR with no file list and no scope listed" "$OUT" "- #8007 docs: no files known"
lacks "group: concertmaster scope hidden" "$OUT" "#8001"
lacks "group: all files under the skill dir hidden" "$OUT" "#8003"
lacks "group: scope match is case-insensitive (no file list: scope decides)" "$OUT" "#8005"
has "group: a concertmaster scope never hides a PR whose files include product code" "$OUT" "- #8008 fix(concertmaster): drop column"
has "group: a file row with no path is not tooling and does not crash" "$OUT" "- #8009 "
has "group: Merged count excludes tooling" "$OUT" "Merged (6)"
has "group: one tooling line with merged and open counts" "$OUT" "Tooling: 3 concertmaster PRs merged, 1 open"
has "group: open tooling PR is listed under Open PRs (everything in progress)" "$(printf '%s\n' "$OUT" | sed -n '/^Open PRs/,/^$/p')" "- #8101 "
check "group: exactly one Tooling line" "$(printf '%s\n' "$OUT" | grep -c '^Tooling:')" "1"
OWN="$(run --full)"
has "owner: tooling PR listed" "$OWN" "- #8001 feat(concertmaster): digest line"
has "owner: file-only tooling PR listed" "$OWN" "- #8003 chore: tidy skill docs"
has "owner: Merged counts everything" "$OWN" "Merged (9)"
lacks "owner: no Tooling summary line" "$OWN" "Tooling:"
has "owner: open count counts every open PR" "$OWN" "open PRs: 2"
# nothing internal merged and nothing internal open: no Tooling line at all; an open one alone brings it back
echo "[$(prf 8002 "fix(app): roster sort" 2 src/pages/Roster.tsx)]" > "$STUB/merged.json"
echo "[$(prf 8102 "feat(app): open product" 1 src/b.ts)]" > "$STUB/open.json"
lacks "group: no tooling PRs merged or open, no Tooling line" "$(run)" "Tooling:"
echo "[$(prf 8101 "docs(concertmaster): open tooling" 1 .agents/skills/concertmaster/SKILL.md)]" > "$STUB/open.json"
has "group: no tooling PR merged but one open: the line still prints" "$(run)" "Tooling: 0 concertmaster PRs merged, 1 open"
# the open list failed: the line says the open count is unknown, never zero
{ prf 8001 "feat(concertmaster): digest line" 3 .agents/skills/concertmaster/scripts/digest.sh; } | jq -s -c . > "$STUB/merged.json"
echo 3 > "$STUB/open.rc"
has "group: open read failed: unknown, not 0" "$(run)" "Tooling: 1 concertmaster PRs merged, open unknown (gh failed)"
rm -f -- "$STUB/open.rc"
# 100 files is gh's cut-off: a visible product file still proves product code; 100 files all under the prefix fall back to the scope
reset; ledger; echo '[]' > "$STUB/open.json"
big() { # big <number> <title> <dir>: a merged PR with 100 changed files under <dir>
  pr "$1" "$2" 1 | jq -c --arg d "$3" '. + {files: [range(0; 100) | {path: "\($d)f\(.).txt", additions: 1, deletions: 0}]}'; }
{ big 8201 "fix(concertmaster): big product" src/; big 8202 "fix(concertmaster): big tooling" .agents/skills/concertmaster/; } | jq -s -c . > "$STUB/merged.json"
OUT="$(run)"
has "100 product files with a concertmaster scope: listed" "$OUT" "- #8201 "
lacks "100 files all under the skill dir with the scope: hidden" "$OUT" "#8202"
# the open list is always fetched for the group text: an open tooling PR must show even when none merged
reset; ledger; echo "[$(prf 8002 "fix(app): roster sort" 2 src/pages/Roster.tsx)]" > "$STUB/merged.json"
run >/dev/null
check "group: no tooling PR merged, gh is still asked for open PRs (an open tooling PR must show)" "$(grep -c -- '--state open' "$STUB/gh.args")" "1"
echo "[$(prf 8001 "feat(concertmaster): digest line" 2 .agents/skills/concertmaster/SKILL.md)]" > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"; : > "$STUB/gh.args"
run >/dev/null
check "group: a tooling PR merged, gh is asked for open PRs" "$(grep -c -- '--state open' "$STUB/gh.args")" "1"
# config: hide_scopes and hide_paths replace the defaults; empty lists hide nothing
{ prf 8001 "feat(concertmaster): digest line" 3 .agents/skills/concertmaster/scripts/digest.sh
  prf 8010 "feat(labs): experiment" 2
  prf 8011 "chore: vendor bump" 2 vendor/x.txt; } | jq -s -c . > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
cp "$ROOT/config.yaml" "$ROOT/config.base.yaml"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  hide_scopes: [labs]\n  hide_paths: ["vendor/"]\n'; } > "$ROOT/config.yaml"
OUT="$(run)"
lacks "config: configured scope hidden" "$OUT" "#8010"
lacks "config: configured path hidden" "$OUT" "#8011"
has "config: the default scope no longer hidden" "$OUT" "- #8001 "
has "config: tooling line uses the first configured scope" "$OUT" "Tooling: 2 labs PRs merged, 0 open"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  hide_scopes: []\n  hide_paths: []\n'; } > "$ROOT/config.yaml"
OUT="$(run)"
has "config: empty lists hide nothing" "$OUT" "Merged (3)"
lacks "config: empty lists, no Tooling line" "$OUT" "Tooling:"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  hide_scopes: concertmaster\n'; } > "$ROOT/config.yaml"
check "config: a scalar hide_scopes is a usage error" "$(run >/dev/null; echo $?)" "2"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  hide_paths: [""]\n'; } > "$ROOT/config.yaml"
check "config: an empty path prefix is a usage error (it would hide every PR)" "$(run >/dev/null; echo $?)" "2"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  hide_scopes: [""]\n'; } > "$ROOT/config.yaml"
check "config: an empty scope is a usage error" "$(run >/dev/null; echo $?)" "2"
cp "$ROOT/config.base.yaml" "$ROOT/config.yaml"

# 10. Deployed comes from GitHub (tag-push runs of the deploy workflow), merged with the ledger by tag ---------
# The deploy workflow and the job that proves a prod deploy come from config (digest.deploy_workflow,
# digest.deploy_job); the names below are made up. A run's own conclusion proves nothing (a cancelled
# advisory job makes the whole run "cancelled" after prod shipped): the named job decides.
cp "$ROOT/config.base.yaml" "$ROOT/config.yaml"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  deploy_workflow: Release Deploy\n  deploy_job: Ship to Prod\n'; } > "$ROOT/config.deploy.yaml"
export CM_CONFIG="$ROOT/config.deploy.yaml"
runrec() { # runrec <id> <tag> <conclusion> <created hours ago> <updated hours ago> [status]: one `gh run list` row
  jq -nc --argjson id "$1" --arg tag "$2" --arg c "$3" --arg cr "$(ago "$4")" --arg up "$(ago "$5")" --arg st "${6:-completed}" \
    '{databaseId: $id, headBranch: $tag, displayTitle: "chore: release \($tag)", event: "push", workflowName: "Release Deploy",
      status: $st, conclusion: (if $st == "completed" then $c else "" end), createdAt: $cr, updatedAt: $up}'; }
runjobs() { # runjobs <id> <hours ago the prod job finished> <name=conclusion>...: the `gh run view <id>` answer
  local id="$1" h="$2"; shift 2
  jq -nc --arg at "$(ago "$h")" --args '{jobs: ($ARGS.positional | map(split("=") | {name: .[0], status: "completed", conclusion: .[1], startedAt: $at, completedAt: $at}))}' "$@" > "$STUB/run-$id.json"; }
deploy_reset() { reset; ledger; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"; }
ships() { printf '%s\n' "$1" | grep -Ec "^- $2 at [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}$3\$" || true; }

# 10.1 a tag-push deploy with NO ledger row: listed from gh, although the run itself says cancelled
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

# 10.2 the ledger also has the tag: one line, with the PRs; a "v" prefix difference does not double it
deploy_reset
{ runrec 4100 v9.4.100 cancelled 7 6.4; } | jq -s -c . > "$STUB/runs.json"
runjobs 4100 6.5 "Ship to Prod=success"
jq '.deployWindows = [{id: "w1", state: "done", tag: "v9.4.100", finishedAt: "'"$(ago 6.45)"'", prs: [101, 102]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
has "deployed: ledger and gh agree: one release, counted once" "$OUT" "Deployed (1)"
check "deployed: the tag is listed once with the ledger's PRs" "$(ships "$OUT" 'v9\.4\.100' ': #101 #102')" "1"
check "deployed: no second line for the same tag" "$(printf '%s\n' "$OUT" | grep -c 'v9\.4\.100')" "1"
jq '.deployWindows[0].tag = "1.4.100"' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
check "deployed: tag match ignores a leading v" "$(printf '%s\n' "$OUT" | grep -c '1\.4\.100')" "1"
# the ledger says done, gh finds no succeeded prod job: the ledger row stands, no contradicting second line
deploy_reset
{ runrec 500 v2.0.0 failure 3 2.5; } | jq -s -c . > "$STUB/runs.json"; runjobs 500 2.6 "Ship to Prod=failure"
jq '.deployWindows = [{id: "w1", state: "done", tag: "v2.0.0", finishedAt: "'"$(ago 2.4)"'", prs: [77]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
check "deployed: a ledger done row is not contradicted by a second gh line" "$(printf '%s\n' "$OUT" | grep -c 'v2\.0\.0')" "1"
has "deployed: the ledger row is kept" "$OUT" "Deployed (1)"
has "deployed: the conflict with gh is said on the line" "$OUT" "(ledger says done, gh: no prod deploy job succeeded)"

# 10.3 two releases in the window, oldest first; a ledger-only release (no run found) still lists
deploy_reset
{ runrec 601 v3.0.2 success 2 1.5; runrec 600 v3.0.1 success 9 8.5; } | jq -s -c . > "$STUB/runs.json"
runjobs 601 1.6 "Ship to Prod=success"; runjobs 600 8.6 "Ship to Prod=success"
jq '.deployWindows = [{id: "w0", state: "done", tag: "v3.0.0", finishedAt: "'"$(ago 11)"'", prs: [1]}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
OUT="$(run)"
has "deployed: three releases (two gh, one ledger-only)" "$OUT" "Deployed (3)"
check "deployed: oldest first" "$(printf '%s\n' "$OUT" | grep -o '^- v3\.0\.[0-9]' | tr '\n' ' ')" "- v3.0.0 - v3.0.1 - v3.0.2 "

# 10.4 a run with no succeeded prod job is not "deployed" and is not hidden
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

# 10.5 the window: a run that finished before it is not listed (and its jobs are not fetched); one that started before it and finished inside is
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

# 10.6 gh fails: unknown, never a zero; the ledger rows still show
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
echo '[]' > "$STUB/runs.json"; echo 120 > "$STUB/runs.sleep"
T0=$SECONDS; OUT="$(CM_DIGEST_GH_TIMEOUT=1 run)"; T1=$SECONDS
has "deployed: hung gh run list: timed out to unknown" "$OUT" "Deployed: unknown (gh failed)"
check "deployed: hung gh run list: ended by the timeout ($(( T1 - T0 ))s)" "$(( T1 - T0 < 60 ))" "1"
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

# 10.6b a failing run filter is a failed read, never a quiet zero; tagless releases stay separate; a renamed job is called out
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

# 10.6c review round 2: clocks, in-flight runs, truncation, a ledger row with no finishedAt
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

# 10.7 config: the job name is read from config, never hard-coded; unset workflow leaves the ledger as the only source
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
export CM_CONFIG="$ROOT/config.yaml"

# 11. the Tooling line: open tooling PRs are counted by path, by scope, from cut-off and empty file lists, and drafts ----
# Real cause of the "0 open" miss: see the PR body (no open concertmaster PR existed to re-run against, so each suspect has a fixture here).
tl() { printf '%s\n' "$1" | grep '^Tooling:' || true; }
SK=.agents/skills/concertmaster/SKILL.md
mergedtool() { { prf 8501 "feat(concertmaster): merged one" 2 "$SK"; prf 8502 "fix(app): roster" 2 src/r.ts; } | jq -s -c . > "$STUB/merged.json"; }
nomergedtool() { { prf 8502 "fix(app): roster" 2 src/r.ts; } | jq -s -c . > "$STUB/merged.json"; }
opens() { jq -s -c . > "$STUB/open.json"; }

reset; ledger; mergedtool
# (a) by path, title scope not a hidden one: the files decide
{ prf 8601 "docs(spec): tooling by path" 1 "$SK"; prf 8602 "chore: tidy" 1 "$SK" .agents/skills/concertmaster/scripts/digest.sh; } | opens
check "tooling open: counted by path alone, scope not hidden" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 2 open"
# by scope, no file list at all (gh gave an empty list)
{ prf 8603 "docs(concertmaster): scope only" 1; } | opens
check "tooling open: counted by scope when gh gave no file list" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 1 open"
{ prf 8604 "docs(spec): no scope match, no files" 1; } | opens
check "tooling open: no hidden scope and no file list: product, not counted" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 0 open"
# cut-off lists (gh stops at 100 files)
bigopen() { # bigopen <number> <title> <dir-of-99-files> [outside-file]: an open PR whose file list is 100 long
  pr "$1" "$2" 1 | jq -c --arg d "$3" --arg o "${4:-}" '. + {files: ([range(0; 100) | {path: "\($d)f\(.).txt", additions: 1, deletions: 0}] | if $o != "" then .[99] = {path: $o} else . end)}'; }
{ bigopen 8611 "fix(concertmaster): big tooling" .agents/skills/concertmaster/; } | opens
check "tooling open: cut-off list all under the prefix, hidden scope: counted" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 1 open"
{ bigopen 8612 "fix(concertmaster): big mixed" .agents/skills/concertmaster/ src/x.ts; } | opens
check "tooling open: cut-off list with one visible product file: product, not counted" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 0 open"
# draft PRs are open work like any other
{ prf 8621 "feat(concertmaster): wip" 1 "$SK" | jq -c '. + {isDraft: true}'; } | opens
check "tooling open: a draft PR counts as open" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 1 open"
# (b) skill dir plus other files
{ prf 8631 "docs(spec): spec plus skill" 1 "$SK" docs/specs/digest.md; prf 8632 "chore: skill plus package" 1 "$SK" package.json; } | opens
check "tooling open: skill dir plus a product file is product, not counted" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 0 open"
# a sibling agent skill dir the owner lists in hide_paths belongs to the same tooling
{ prf 8641 "fix(concertmaster): lane contract" 1 "$SK" .agents/skills/pr-sweep/verbs/drive.md; } | opens
check "tooling open: sibling skill dir outside hide_paths: not counted" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 0 open"
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  hide_paths: [".agents/skills/concertmaster/", ".agents/skills/pr-sweep/"]\n'; } > "$ROOT/config.yaml"
check "tooling open: sibling skill dir listed in hide_paths: counted" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 1 open"
cp "$ROOT/config.base.yaml" "$ROOT/config.yaml"
# (c) the label names every hidden scope
{ cat "$ROOT/config.base.yaml"; printf 'digest:\n  hide_scopes: [concertmaster, ops]\n'; } > "$ROOT/config.yaml"
{ prf 8651 "fix(ops): tooling scope two" 1; } | opens
check "tooling open: second hidden scope counted and named in the label" "$(tl "$(run)")" "Tooling: 1 concertmaster/ops PRs merged, 1 open"
cp "$ROOT/config.base.yaml" "$ROOT/config.yaml"
# (f) nothing tooling merged in the window: an open tooling PR still shows
nomergedtool
{ prf 8661 "feat(concertmaster): open only" 1 "$SK"; } | opens
check "tooling open: nothing merged, one open: the line still prints" "$(tl "$(run)")" "Tooling: 0 concertmaster PRs merged, 1 open"
echo '[]' > "$STUB/open.json"
lacks "tooling open: nothing merged, nothing open: no Tooling line" "$(run)" "Tooling:"
mergedtool
check "tooling open: one merged, none open: the line prints a real zero" "$(tl "$(run)")" "Tooling: 1 concertmaster PRs merged, 0 open"
# gh trouble around the line
nomergedtool; echo 1 > "$STUB/open.rc"
lacks "tooling open: nothing merged, open list failed: no line (nothing known to report)" "$(run)" "Tooling:"
rm -f -- "$STUB/open.rc"
{ prf 8671 "feat(concertmaster): open one" 1 "$SK"; } | opens
echo 1 > "$STUB/merged.rc"
OUT="$(run)"
check "tooling open: merged read failed, one open: merged unknown, open counted" "$(tl "$OUT")" "Tooling: merged unknown (gh failed), 1 open"
has "tooling open: merged read failed: Merged says unknown" "$OUT" "Merged: unknown (gh failed)"
rm -f -- "$STUB/merged.rc"
# the owner text lists everything and carries no Tooling line
lacks "tooling open: --full has no Tooling line" "$(run --full)" "Tooling:"

# 12. a payload past 128 KB must not travel as one argv string -------------------------------
# Linux refuses a single argv string over MAX_ARG_STRLEN (128 KB): jq then exits 126 "Argument list too long".
# MERGED_JSON, OPEN_JSON, GH_DEPLOYS and each run's `gh run view` answer are ~200 KB here; the digest must still
# come out right. Each mutant puts one of them back on --argjson and must fail (exit 126, or Deployed lost).
export CM_CONFIG="$ROOT/config.deploy.yaml"
deploy_reset
# the generators read their big input on stdin: the fixture must not hit the argv limit it is testing
jq -nc '[range(0; 3300) | {path: "src/generated/module-\(.)/index.tsx", additions: 1, deletions: 0}]' \
  | jq -c --arg at "$(ago 2)" \
  '[{number: 771, title: "feat(app): big merged", mergedAt: $at, author: {login: "alice"}, url: "https://github.com/AcmeOrg/acme-app/pull/771", files: .}]' > "$STUB/merged.json"
jq -nc '[range(0; 900) | {number: (8000 + .), title: ("feat(app): open pr " + (. | tostring) + " " + ("x" * 220)),
    files: [{path: "src/a.tsx", additions: 1, deletions: 0}]}]
  | .[0:3] |= map(.title = "feat(concertmaster): open tooling" | .files = [{path: ".agents/skills/concertmaster/SKILL.md", additions: 1, deletions: 0}])' > "$STUB/open.json"
{ runrec 970 v9.0.1 success 3 1.5; } | jq -s -c . > "$STUB/runs.json"
jq -nc --arg at "$(ago 1.6)" '{jobs: ([{name: "Ship to Prod", status: "completed", conclusion: "success", startedAt: $at, completedAt: $at}]
  + [range(0; 2200) | {name: "filler job \(.)", status: "completed", conclusion: "success", startedAt: $at, completedAt: $at}])}' > "$STUB/run-970.json"
check "big payload: merged.json is over 200 KB" "$([ "$(wc -c < "$STUB/merged.json")" -ge 200000 ] && echo yes || echo no)" "yes"
check "big payload: open.json is over 200 KB" "$([ "$(wc -c < "$STUB/open.json")" -ge 200000 ] && echo yes || echo no)" "yes"
check "big payload: the run view is over 200 KB" "$([ "$(wc -c < "$STUB/run-970.json")" -ge 200000 ] && echo yes || echo no)" "yes"
OUT="$(run)"; RC=$?
check "big payload: exit 0" "$RC" "0"
check "big payload: no argv error on stderr" "$(grep -c 'Argument list too long' "$ROOT/err" || true)" "0"
has "big payload: the big merged PR is listed" "$OUT" "- #771 feat(app): big merged (alice)"
has "big payload: Merged counts it" "$OUT" "Merged (1)"
has "big payload: the open tooling PRs are counted from the big open list" "$OUT" "Tooling: 0 concertmaster PRs merged, 3 open"
has "big payload: the deploy in the big run view is listed" "$OUT" "Deployed (1)"
check "big payload: the deploy line names the tag" "$(ships "$OUT" 'v9\.0\.1' '')" "1"
OWN="$(run --full)"; RC=$?
check "big payload: --full exits 0" "$RC" "0"
has "big payload: --full counts the 900 open PRs" "$OWN" "open PRs: 900"
# mutants: restore --argjson for one large value each; the real script differs from every mutant.
# The mutant copies the whole skill dir, so lib.sh finds every sibling it sources.
# The 126 outcome needs a kernel that caps ONE argv string (Linux MAX_ARG_STRLEN, 32 pages: 128 KB on 4 KB pages);
# macOS and 16/64 KB-page Linux accept 200 KB, so probe the host first and skip the 126 checks where it does not apply.
MUT="$ROOT/mut"; mkdir -p "$MUT"; cp -a "$HERE/../.." "$MUT/skill"
MUTS="$MUT/skill/scripts/digest.sh"
ARGV_CAP=no; BIGARG="$(head -c 200000 /dev/zero | tr '\0' x)"
/usr/bin/env true "$BIGARG" 2>/dev/null || ARGV_CAP=yes
unset BIGARG
[ "$ARGV_CAP" = yes ] || echo "skip the exit 126 mutant checks: this host accepts a 200 KB argv string"
mutant() { # mutant <label> <sed expr> <want>: run a digest.sh with the sed edit applied; want rc126 or lostdeploy
  sed -e "$2" "$SCRIPT" > "$MUTS"; chmod +x "$MUTS"
  check "mutant $1: the edit changed the script" "$(cmp -s "$SCRIPT" "$MUTS" && echo same || echo changed)" "changed"
  local mout mrc; mout="$("$MUTS" 2>"$ROOT/err")"; mrc=$?
  case "$3" in
    rc126) [ "$ARGV_CAP" = yes ] || return 0
      check "mutant $1: exit 126" "$mrc" "126"; has "mutant $1: argv error reported" "$(cat "$ROOT/err")" "Argument list too long" ;;
    lostdeploy) [ "$ARGV_CAP" = yes ] || return 0
      lacks "mutant $1: the deploy is lost" "$mout" "Deployed (1)"; has "mutant $1: the failed read is reported" "$mout" "Deployed: unknown (gh failed)" ;;
  esac
}
mutant "merged on argv" 's|--slurpfile ghMergedF <(printf .%s. "$MERGED_JSON")|--argjson ghMergedF "[$MERGED_JSON]"|' rc126
mutant "open on argv" 's|--slurpfile ghOpenF <(printf .%s. "$OPEN_JSON")|--argjson ghOpenF "[$OPEN_JSON]"|' rc126
mutant "deploys on argv" 's|--slurpfile ghDeploysF <(printf .%s. "$GH_DEPLOYS")|--argjson ghDeploysF "[$GH_DEPLOYS]"|' rc126
mutant "run view on argv" 's|--slurpfile v <(printf .%s. "$view")|--argjson v "$view"|; s|\$v\[0\]\.jobs|$v.jobs|' lostdeploy
export CM_CONFIG="$ROOT/config.yaml"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
