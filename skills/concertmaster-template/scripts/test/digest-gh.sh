#!/usr/bin/env bash
# digest-gh.sh: behaviour tests for digest.sh sourcing Merged and the open PR count from gh, and for
# the lastSentAt window. gh is a PATH stub answering from files in $STUB: no network. CM_HOME, HOME
# and the ledger live in a mktemp dir.
#
#   scripts/test/digest-gh.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../digest.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-digest-gh.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
STUB="$ROOT/stub"
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/cm" "$STUB"
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT  CM_DIGEST_GH_TIMEOUT CM_TZ CM_TZ_LABEL
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" STUB_DIR="$STUB" PATH="$ROOT/bin:$PATH"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
L="$ROOT/cm/ledger.json"

# gh stub: `gh pr list -R <repo> --state merged|open ...`. Answers from $STUB/<state>.json and
# exits with $STUB/<state>.rc (default 0); $STUB/<state>.sleep makes it hang first.
cat > "$ROOT/bin/gh" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh.args"
state=""
while [ $# -gt 0 ]; do case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac; done
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
OUT="$(run)"; RC=$?
check "empty ledger: exit 0" "$RC" "0"
has "empty ledger: Merged lists gh PRs" "$OUT" "Merged (2)"
has "empty ledger: oldest merge first" "$OUT" "$(printf -- '  #201 first merged (alice)\n  #202 second merged (bob)')"
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
OUT="$(run)"; RC=$?
check "gh down: digest still prints, exit 0" "$RC" "0"
has "gh down: Merged unknown" "$OUT" "Merged: unknown (gh failed)"
lacks "gh down: no Merged (0)" "$OUT" "Merged (0)"
has "gh down: open PRs unknown" "$OUT" "open PRs: unknown (gh failed)"
lacks "gh down: no open PRs: 0" "$OUT" "open PRs: 0"
reset; ledger; echo '[]' > "$STUB/merged.json"; echo '{"message":"API rate limit exceeded"}' > "$STUB/open.json"
OUT="$(run)"
has "merged ok but empty: a real zero is Merged (0) none" "$OUT" "$(printf 'Merged (0)\n  none')"
has "open answer that is not an array: unknown" "$OUT" "open PRs: unknown (gh failed)"
reset; ledger; echo 'not json at all' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
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
OUT="$(run)"
has "100 merged PRs: heading says 100+" "$OUT" "Merged (100+)"
has "1000 open PRs: count says 1000+" "$OUT" "open PRs: 1000+"
reset; ledger
jq -nc --arg at "$(ago 1)" '[{number: 7, title: "evil\u001b[31m title\nnewline", mergedAt: $at, author: null, url: "u"}]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
OUT="$(run)"
check "title control characters are flattened, missing author is ?" "$(printf '%s\n' "$OUT" | grep -c '^  #7 evil.\[31m title newline (?)$')" "1"
reset
jq -n '{workers: {"w1": {state: "running", host: "local"}, "w2": {state: "stuck", task: "stuck one", host: "host-b", lastOutputAt: "2026-01-01T00:00:00Z"}},
  hosts: {"host-b": {reachable: false}}, prs: {"1": {number: 1, state: "OPEN", mergedAt: null}}}' > "$L"
echo '[]' > "$STUB/merged.json"; echo '[{"number":9}]' > "$STUB/open.json"
OUT="$(run)"
has "ledger sections still work (stuck)" "$OUT" "stuck one on host-b"
has "fleet line: ledger running and offline, gh open" "$OUT" "Fleet: 1 running (local 1), open PRs: 1, offline: host-b"

# 5. digest.sh is read-only ------------------------------------------------------------------------------
reset; ledger "$(ago 3)"; echo '[]' > "$STUB/merged.json"; echo '[]' > "$STUB/open.json"
cp "$L" "$ROOT/before.json"
run >/dev/null
check "ledger byte-identical after a run" "$(cmp -s "$ROOT/before.json" "$L" && echo same || echo changed)" "same"
check "no backup ring, lock or temp file created" "$(find "$ROOT/cm" -mindepth 1 ! -name ledger.json | wc -l | tr -d ' ')" "0"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
