#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2016  # pass() always succeeds; check bodies are single-quoted on purpose
# unlinked-worktrees.sh (test): the tick check that lists live worktrees with no linked issue, hermetic. A stub fleet
# CLI (host list, worktree list per host) with replies in the real plugly shape (`linkedIssue` number or null, `linkedItems`),
# no network, no real plugly or orca call.
# Covers: an unlinked worktree is listed (with its PR number or none); a worktree with `linkedIssue` is not; one linked only
# through `linkedItems` (type issue) is not; one with only a linked PR IS listed; the exempt set (the concertmaster's own
# worktree, a configured lane, a lane-shaped name, a ledger standing worktree, a main checkout, an archived worktree, a
# never_touch segment, a path outside path_match) is never listed, and a lane's CHILD is not exempt; a second host is read with
# its own --environment; an unreadable host is CHECK INCOMPLETE and never read as clean; a failed host list reads local only
# and says so; --json carries the same rows; a duplicated row counts once; a list cut off at the limit (truncated:true or a totalCount above
# the rows) is CHECK INCOMPLETE for that host only, its rows still listed; usage errors exit 2; every path exits 0.
# Mutants on a scratch copy of the script: the linked test, the standing-lane exemption and the archived exemption each
# removed must fail a case.
#
#   scripts/test/unlinked-worktrees.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-unlinkedwt-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }
check() { if (eval "$2"); then pass "$1"; else fail "$1" "${3:-}"; fi; }
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }

export CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
github: { org: AcmeOrg, main_repo: acme-app }
worktrees:
  path_match: "/acme/"
  self_name: concertmaster
  never_touch: [otherproj, sideproj]
lanes:
  - { name: pr-sweeper, standing: true }
  - { name: dev-sweeper, standing: true }
ownership:
  leads: { buildboss: build }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_TEST=1
unset CM_ORG CM_REPO CM_PATH_MATCH CM_SELF_WORKTREE CM_LEDGER ORCA_CLI_COMMAND PLUGLY_CLI_COMMAND
export CM_CLI_KIND="${CM_CLI_KIND:-orca}"

# the stub fleet CLI: `host list` and `worktree list [--environment <h>]` read $STUB_DIR files; the argv is logged
mkdir -p "$ROOT/bin" "$ROOT/stub"
export STUB_DIR="$ROOT/stub" STUB_LOG="$ROOT/stub.log"
cat > "$ROOT/bin/fleet-stub" <<'E'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "host list") [ -f "$STUB_DIR/hostlist.json" ] || { echo "no host list" >&2; exit 1; }; cat "$STUB_DIR/hostlist.json" ;;
  "worktree list")
    shift 2; h=local
    while [ $# -gt 0 ]; do case "$1" in --environment) h="$2"; shift 2 ;; *) shift ;; esac; done
    [ -f "$STUB_DIR/wl-$h.json" ] || { echo "host $h unreachable" >&2; exit 1; }
    cat "$STUB_DIR/wl-$h.json" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
E
chmod +x "$ROOT/bin/fleet-stub"
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub"; fi

# row <path> <linkedIssue|null> <linkedPR|null> [extra jq object merged in]: a worktree row in the real shape
row() {
  local x="${4-}"; [ -n "$x" ] || x='{}'
  jq -cn --arg p "$1" --argjson i "$2" --argjson pr "$3" --argjson x "$x" '
    {id: ("repo::" + $p), path: $p, displayName: ($p | split("/") | last), branch: ("refs/heads/" + ($p | split("/") | last)),
     isMainWorktree: false, isArchived: false, comment: "", linkedIssue: $i, linkedPR: $pr,
     linkedItems: ([ (if $i != null then {provider: "github", type: "issue", number: $i} else empty end),
                     (if $pr != null then {provider: "github", type: "pr", number: $pr} else empty end) ]),
     linkedLinearIssue: null, linkedGitLabIssue: null} + $x'
}
# put <host> <row>...: the worktree list reply of a host
put() { local h="$1"; shift; printf '%s\n' "$@" | jq -s -c '{ok: true, result: {worktrees: ., totalCount: length, truncated: false}}' > "$STUB_DIR/wl-$h.json"; }
hostlist() { printf '%s\n' "$@" | jq -R -s -c '{ok: true, result: {hosts: (split("\n") | map(select(length > 0)) | map(if . == "local" then {kind: "local", name: "this machine", id: "local"} else {kind: "environment", name: ., id: .} end))}}' > "$STUB_DIR/hostlist.json"; }
S="$SKILL/scripts/unlinked-worktrees.sh"
run() { : > "$STUB_LOG"; bash "${1:-$S}" "${@:2}" >"$ROOT/out" 2>"$ROOT/err"; RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"; }

W=/work/acme
hostlist local
put local \
  "$(row $W/dev-101-unlinked null null)" \
  "$(row $W/dev-102-linked 102 null)" \
  "$(row $W/dev-103-prlinked null 77)" \
  "$(row $W/dev-104-itemsonly null null '{"linkedItems":[{"provider":"github","type":"issue","number":104}]}')" \
  "$(row $W/concertmaster null null)" \
  "$(row $W/pr-sweeper null null)" \
  "$(row $W/buildboss null null)" \
  "$(row $W/demo-sweeper null null)" \
  "$(row $W/epic-calendar null null)" \
  "$(row $W/ledger-lane null null)" \
  "$(row $W/main-checkout null null '{"isMainWorktree":true}')" \
  "$(row $W/old-archived null null '{"isArchived":true}')" \
  "$(row $W/otherproj/leaf null null)" \
  "$(row /elsewhere/other-project/thing null null)" \
  "$(row $W/sweep-6001 null null)" \
  "$(row $W/dev-lead-time-fix null null)" \
  "$(row $W/epic-orphan null null)" \
  "$(row $W/dev-101-unlinked null null)"
# a lead is exempt on POSITIVE evidence: configured (pr-sweeper), an ownership lead (buildboss) or a ledger worker with standing:true
printf '{"workers":{"w-ledger":{"standing":true,"path":"%s/ledger-lane/"},"w-demo":{"standing":true,"path":"%s/demo-sweeper"},"w-epic":{"standing":true,"path":"%s/epic-calendar/"},"w-child":{"standing":false,"path":"%s/dev-101-unlinked"}}}\n' "$W" "$W" "$W" "$W" > "$CM_HOME/ledger.json"

run
listed() { grep -c '^  UNLINKED ' <<<"$OUT" | tr -d ' '; }
check "the header counts the listed rows and states the target" 'grep -q "^unlinked-worktrees: 5 (target 0)\$" <<<"$OUT"' "$OUT"
check "an unlinked worktree is listed with its path, host and no PR" 'grep -qF "  UNLINKED dev-101-unlinked @ local: $W/dev-101-unlinked pr=none" <<<"$OUT"' "$OUT"
check "a duplicated row counts once" '[ "$(grep -c "dev-101-unlinked" <<<"$OUT")" = 1 ]' "$OUT"
check "a worktree with a linked issue is NOT listed" '! grep -q "dev-102-linked" <<<"$OUT"' "$OUT"
check "a worktree linked only through linkedItems (type issue) is NOT listed" '! grep -q "dev-104-itemsonly" <<<"$OUT"' "$OUT"
check "a worktree with only a linked PR IS listed, with the PR number (the issue link is missing)" 'grep -qF "dev-103-prlinked @ local: $W/dev-103-prlinked pr=77" <<<"$OUT"' "$OUT"
check "a standing lane lead worktree is exempt on positive evidence (pr-sweeper configured, buildboss ownership lead, demo-sweeper and epic-calendar ledger standing:true)" '! grep -qE "UNLINKED (pr-sweeper|buildboss|demo-sweeper|epic-calendar) " <<<"$OUT"' "$OUT"
check "a worker whose NAME merely contains -lead (dev-lead-time-fix) is LISTED: a name shape exempts nothing" 'grep -qF "UNLINKED dev-lead-time-fix @ local: $W/dev-lead-time-fix pr=none" <<<"$OUT"' "$OUT"
check "an unledgered epic-shaped name (epic-orphan, no config, no ledger row) is LISTED until it is recorded" 'grep -qF "UNLINKED epic-orphan @ local" <<<"$OUT"' "$OUT"
check "a lane CHILD is not exempt (sweep-6001 is listed)" 'grep -q "UNLINKED sweep-6001 @ local" <<<"$OUT"' "$OUT"
check "the concertmaster own worktree is exempt" '! grep -q "UNLINKED concertmaster " <<<"$OUT"' "$OUT"
check "a ledger worker with standing:true is exempt (trailing slash in the ledger path tolerated)" '! grep -q "ledger-lane" <<<"$OUT"' "$OUT"
check "a ledger worker with standing:false is not exempt" 'grep -q "UNLINKED dev-101-unlinked " <<<"$OUT"' "$OUT"
check "a main checkout and an archived worktree are exempt" '! grep -qE "main-checkout|old-archived" <<<"$OUT"' "$OUT"
check "a never_touch path segment (otherproj) is exempt, a path outside path_match is never read" '! grep -qE "otherproj|other-project" <<<"$OUT"' "$OUT"
check "exit 0 and exactly five rows listed" '[ "$RC" = 0 ] && [ "$(listed)" = 5 ]' "rc=$RC $OUT"
# a standing that is present and not the boolean is read as standing (a lead is never listed for cleanup on a damaged field);
# controls: standing false is listed, standing true is exempt
cp "$CM_HOME/ledger.json" "$ROOT/ledger.at-b"
for bad in '"true"' 1 '{}' '[]' '"yes"'; do
  jq --argjson v "$bad" '.workers["w-ledger"].standing = $v' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run
  check "standing $bad: still exempt, never listed" '! grep -q "ledger-lane" <<<"$OUT"' "$OUT"
done
jq '.workers["w-ledger"].standing = false' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run
check "control: standing false is listed" 'grep -q "UNLINKED ledger-lane @ local" <<<"$OUT"' "$OUT"
jq '.workers["w-ledger"].standing = true' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run
check "control: standing true is exempt" '! grep -q "ledger-lane" <<<"$OUT"' "$OUT"
# one worker row that is not an object (7, null, false, text) must not drop every standing exemption; a path that is not text
# must not hide a valid worktree key of the same row
for junk in 7 null false '"x"' '[]'; do
  jq --argjson j "$junk" '.workers["w-junk"] = $j' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run
  check "a worker row $junk beside a standing worker: still exempt, no parse note" '! grep -q "ledger-lane" <<<"$OUT" && ! grep -q "could not be parsed" <<<"$OUT"' "$OUT"
done
jq '.workers["w-ledger"] |= (. + {worktree: .path} | .path = 7)' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run
check "a path of 7 does not hide the worktree key: still exempt" '! grep -q "ledger-lane" <<<"$OUT"' "$OUT"
# Typed boundary: a worker row that cannot be read (not an object, a host or path that is not text, a standing row with no path that is text) exempts no worktree. It was read
# as "no such lane" and nothing said so; now the report says CHECK INCOMPLETE with the count. Controls: readable rows say nothing, and a dead record with a wrong-typed path says nothing.
for patch in '.workers["w-ledger"].path = false' '.workers["w-ledger"].path = ["x"]' '.workers["w-junk"] = false' '.workers["w-junk"] = null' '.workers["w-junk"] = 7' \
             '.workers["w-junk"] = {host: ["local"], path: "/elsewhere"}' '.workers["w-junk"] = {host: "local", path: false, standing: true}' '.workers["w-junk"] = {host: "local", path: false, standing: "true"}'; do
  jq "$patch" "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run
  check "typed boundary ($patch): the report says a ledger worker row cannot be read" 'grep -q "CHECK INCOMPLETE" <<<"$OUT" && grep -q "ledger worker row(s) cannot be read" <<<"$OUT"' "$OUT"
done
for patch in '.workers["w-junk"] = {host: "local", path: false, standing: true, state: "gone"}' '.workers["w-junk"] = {host: "local", path: "/x/ok", standing: false}'; do
  jq "$patch" "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run
  check "typed boundary control ($patch): nothing unreadable, no CHECK INCOMPLETE" '! grep -q "cannot be read" <<<"$OUT"' "$OUT"
done
# a ledger of two JSON documents used to print "(ledger): 0; 0 ledger worker row(s)" (one count per document): one count, and the reason says what is wrong
{ jq -c . "$ROOT/ledger.at-b"; printf '{"workers":{}}\n'; } > "$CM_HOME/ledger.json"; run
check "two JSON documents: CHECK INCOMPLETE, the ledger holds more than one JSON document, one count" 'grep -q "CHECK INCOMPLETE" <<<"$OUT" && grep -q "more than one JSON document" <<<"$OUT" && ! grep -qF "0; 0" <<<"$OUT" && ! grep -qE "\(ledger\)[[:space:]]+0" <<<"$OUT"' "$OUT"
mkdir -p "$ROOT/mut-2d/scripts" && cp -R "$SKILL"/scripts/. "$ROOT/mut-2d/scripts/"
sed -i '/^  case "\$sbad" in/d' "$ROOT/mut-2d/scripts/unlinked-worktrees.sh"
if ! cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$ROOT/mut-2d/scripts/unlinked-worktrees.sh"; then
  run "$ROOT/mut-2d/scripts/unlinked-worktrees.sh"
  if grep -qE '0[;[:space:]]+0 ledger worker row' <<<"$OUT" || grep -qE '\(ledger\)[[:space:]]+0' <<<"$OUT"; then pass "mutant: without the count normalisation a two-document ledger prints two counts again, the case is caught"; else fail "mutant two documents" "$OUT"; fi
else fail "mutant two documents" "the sed no longer matches unlinked-worktrees.sh"; fi
# mutant: a copy that does not count the unreadable rows stays silent, so the cases above are caught
mkdir -p "$ROOT/mut-tb/scripts" && cp "$SKILL"/scripts/lib.sh "$SKILL"/scripts/unlinked-worktrees.sh "$SKILL"/scripts/jdupkeys "$ROOT/mut-tb/scripts/"
sed -i 's/^  \[ "\$sbad" = 0 \] || printf /  [ 1 = 1 ] || printf /' "$ROOT/mut-tb/scripts/unlinked-worktrees.sh"
if ! cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$ROOT/mut-tb/scripts/unlinked-worktrees.sh"; then
  jq '.workers["w-junk"] = false' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run "$ROOT/mut-tb/scripts/unlinked-worktrees.sh"
  if grep -q "cannot be read" <<<"$OUT"; then fail "mutant typed boundary" "the mutated script still said it"; else pass "mutant: with the unreadable-row report off the script is silent, the typed-boundary case is caught"; fi
else fail "mutant typed boundary" "the sed no longer matches unlinked-worktrees.sh"; fi
# a ledger that is not ONE object with a worker MAP and no repeated key exempts nothing and says so (workers false and [] were read as "no workers", a key written twice
# as its last value). Each says CHECK INCOMPLETE and "cannot be read"; the mutant with the gate off is silent about workers false.
DUPAB="$(jq -c . "$ROOT/ledger.at-b" | sed 's/"standing":true/"standing":false,"standing":true/')"
check "the repeated-key fixture really has a key written twice" '[ "$(grep -c "\"standing\":false,\"standing\":true" <<<"$DUPAB")" = 1 ]' "$DUPAB"
for c in 'workers false|{"workers":false}' 'workers []|{"workers":[]}' 'workers text|{"workers":"x"}' 'repeated key|'"$DUPAB"; do
  printf '%s\n' "${c#*|}" > "$CM_HOME/ledger.json"; run
  check "ledger gate (${c%%|*}): the report says CHECK INCOMPLETE and the ledger cannot be read" 'grep -q "CHECK INCOMPLETE" <<<"$OUT" && grep -q "cannot be read" <<<"$OUT"' "$OUT"
done
mkdir -p "$ROOT/mut-lg/scripts" && cp "$SKILL"/scripts/lib.sh "$SKILL"/scripts/unlinked-worktrees.sh "$SKILL"/scripts/jdupkeys "$ROOT/mut-lg/scripts/"
sed -i 's/^  if ! gwhy="\$(cm_workers_gate "\$LEDGER")"; then /  if false; then /' "$ROOT/mut-lg/scripts/unlinked-worktrees.sh"
if ! cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$ROOT/mut-lg/scripts/unlinked-worktrees.sh"; then
  printf '%s\n' '{"workers":false}' > "$CM_HOME/ledger.json"; run "$ROOT/mut-lg/scripts/unlinked-worktrees.sh"
  if grep -q "cannot be read" <<<"$OUT"; then fail "mutant ledger gate" "the mutated script still said it"; else pass "mutant: with the ledger gate off workers false is silent again, the case is caught"; fi
else fail "mutant ledger gate" "the sed no longer matches unlinked-worktrees.sh"; fi
cp "$ROOT/ledger.at-b" "$CM_HOME/ledger.json"
run "$S" --json
check "--json carries the same rows, the exempt count and complete:true" 'jq -e ".unlinked | map(.name) | sort == [\"dev-101-unlinked\",\"dev-103-prlinked\",\"dev-lead-time-fix\",\"epic-orphan\",\"sweep-6001\"]" <<<"$OUT" >/dev/null && jq -e ".exempt == 9 and .complete == true" <<<"$OUT" >/dev/null' "$OUT"

# all linked: a clean tick prints just the header
put local "$(row $W/dev-1 1 null)" "$(row $W/dev-2 2 5)"
run
check "every worktree linked: 'unlinked-worktrees: 0 (target 0)' and no rows" '[ "$OUT" = "unlinked-worktrees: 0 (target 0)" ] && [ "$RC" = 0 ]' "$OUT"

# a second host is read with its own --environment, rows carry the host name
hostlist local box2
put local "$(row $W/dev-1 1 null)"
put box2 "$(row $W/remote-job null null)"
run
check "a second host is read via --environment box2 and its unlinked row names the host" 'grep -q "^worktree list --environment box2 " "$STUB_LOG" && grep -qF "UNLINKED remote-job @ box2: $W/remote-job pr=none" <<<"$OUT"' "$OUT / $(cat "$STUB_LOG")"
# an unreadable host is never "all linked"
rm -f "$STUB_DIR/wl-box2.json"
run
check "an unreadable host is CHECK INCOMPLETE with its name, never clean" 'grep -q "^unlinked-worktrees: 0 (target 0) (CHECK INCOMPLETE: box2: " <<<"$OUT" && [ "$RC" = 0 ]' "$OUT"
run "$S" --json
check "--json says complete:false and names the host" 'jq -e ".complete == false and .hosts[0].name == \"box2\"" <<<"$OUT" >/dev/null' "$OUT"
# a failed host list: local only, and it says so
rm -f "$STUB_DIR/hostlist.json"
put local "$(row $W/dev-9 null null)"
run
check "a failed host list reads the local host only and says so (CHECK INCOMPLETE), still lists the local row" 'grep -q "^unlinked-worktrees: 1 (target 0) (CHECK INCOMPLETE: (host list): " <<<"$OUT" && grep -q "UNLINKED dev-9 @ local" <<<"$OUT"' "$OUT"
hostlist local

# usage and missing scope
run "$S" --bogus
check "an unknown argument exits 2" '[ "$RC" = 2 ]' "rc=$RC $ERR"
run "$S" --json extra
check "an extra argument exits 2" '[ "$RC" = 2 ]' "rc=$RC $ERR"
printf 'schema: concertmaster.config/v1\n' > "$ROOT/noscope.yaml"
CM_CONFIG="$ROOT/noscope.yaml" run
check "no path_match: fail closed, CHECK INCOMPLETE line, exit 0 (never reads other projects' worktrees)" 'grep -q "CHECK INCOMPLETE: no worktrees.path_match" <<<"$OUT" && [ "$RC" = 0 ]' "rc=$RC $OUT"

# ---- a ledger over one argument (400 KB) still exempts its standing worker; an unparsable ledger is never silently ignored ----
hostlist local
head -c 400000 /dev/zero | tr '\0' x > "$ROOT/pad.txt"
jq -cn --rawfile pad "$ROOT/pad.txt" --arg p "$W/ledger-lane/" '{workers: {"w-ledger": {standing: true, path: $p}}, pad: $pad}' > "$CM_HOME/ledger.json"
put local "$(row $W/dev-5 null null)" "$(row $W/ledger-lane null null)"
run
check "a 400 KB ledger: the standing worker is still exempt and dev-5 is listed, no CHECK INCOMPLETE" '[ "$OUT" = "unlinked-worktrees: 1 (target 0)"$'"'"'\n'"'"'"  UNLINKED dev-5 @ local: $W/dev-5 pr=none" ]' "$OUT"
printf '{"workers": [oops\n' > "$CM_HOME/ledger.json"
run
check "an unparsable ledger is CHECK INCOMPLETE (ledger), never read as 'no standing workers'" 'grep -q "CHECK INCOMPLETE: (ledger): the ledger could not be parsed" <<<"$OUT"' "$OUT"
printf '{"workers":{"w-ledger":{"standing":true,"path":"%s/ledger-lane/"}}}\n' "$W" > "$CM_HOME/ledger.json"

# ---- a standing worker exempts its own host's path only: the same path on another host is an ordinary worktree ----
hostlist local box2
printf '{"workers":{"w-ledger":{"standing":true,"host":"local","path":"%s/ledger-lane"},"w-remote":{"standing":true,"host":"box2","path":"%s/box2-lane"}}}\n' "$W" "$W" > "$CM_HOME/ledger.json"
put local "$(row $W/ledger-lane null null)" "$(row $W/box2-lane null null)"
put box2 "$(row $W/ledger-lane null null)" "$(row $W/box2-lane null null)"
run
check "a standing worker recorded on local does not exempt the same path on box2, and the reverse" '[ "$(listed)" = 2 ] && grep -qF "UNLINKED ledger-lane @ box2:" <<<"$OUT" && grep -qF "UNLINKED box2-lane @ local:" <<<"$OUT"' "$OUT"
printf '{"workers":{"w-ledger":{"standing":true,"path":"%s/ledger-lane"}}}\n' "$W" > "$CM_HOME/ledger.json"
put local "$(row $W/ledger-lane null null)"
put box2 "$(row $W/ledger-lane null null)"
run
check "a standing worker with no recorded host belongs to the local host only" '[ "$(listed)" = 1 ] && grep -qF "UNLINKED ledger-lane @ box2:" <<<"$OUT"' "$OUT"
hostlist local
rm -f "$STUB_DIR/wl-box2.json"

# ---- mutants on a scratch copy: each exemption or the linked test removed must fail a case ----
mkdir -p "$ROOT/mut/scripts" && cp "$SKILL"/scripts/lib.sh "$SKILL"/scripts/unlinked-worktrees.sh "$SKILL"/scripts/jdupkeys "$ROOT/mut/scripts/"
M="$ROOT/mut/scripts/unlinked-worktrees.sh"
put local "$(row $W/dev-1 1 null)" "$(row $W/foo-sweeper null null)" "$(row $W/old-archived null null '{"isArchived":true}')" "$(row $W/dev-5 null null)" \
  "$(row $W/ledger-lane null null)" "$(row $W/buildboss null null)" "$(row $W/concertmaster null null)" "$(row $W/main-checkout null null '{"isMainWorktree":true}')" \
  "$(row $W/otherproj/leaf null null)"
printf '{"workers":{"w-ledger":{"standing":true,"path":"%s/ledger-lane/"},"w-foo":{"standing":true,"path":"%s/foo-sweeper"}}}\n' "$W" "$W" > "$CM_HOME/ledger.json"
WANT="unlinked-worktrees: 1 (target 0)"$'\n'"  UNLINKED dev-5 @ local: $W/dev-5 pr=none"
run
check "baseline for the mutants: only dev-5 is listed" '[ "$OUT" = "$WANT" ]' "$OUT"
mutant() { # <label> <perl substitution that removes one guard>
  cp "$SKILL/scripts/unlinked-worktrees.sh" "$M"; perl -0pi -e "$2" "$M"
  if cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$M"; then fail "mutant $1" "the edit changed nothing"; return; fi
  run "$M"
  if [ "$OUT" = "$WANT" ]; then fail "mutant $1" "the mutated script still gave the right answer"; else pass "mutant $1 is caught"; fi
}
mutant "linked test removed" 's/def linked: .*?\n.*?\n.*?;/def linked: false;/s'
mutant "configured lane and ownership lead exemption removed" 's/elif any\(names\[\]; \. as \$n \| any\(\$lanes\[\]; \. == \$n\)\) then "standing lane \(configured\)"//'
mutant "ledger standing exemption removed" 's/elif \(\(\$host \| ascii_downcase\) \+ "\|" \+ \(\.path \| sub\("\/\+\$"; ""\)\)\) as \$p \| any\(\$stand\[\]; \. == \$p\) then "standing lane \(ledger\)"//'
mutant "concertmaster own worktree exemption removed" 's/elif any\(names\[\]; \. == \$self\)[^\n]*then "concertmaster worktree"//'
mutant "archived exemption removed" 's/elif \(\.isArchived \/\/ false\) then "archived"//'
mutant "main checkout exemption removed" 's/if \(\.isMainWorktree \/\/ false\) then "main checkout"/if false then "main checkout"/'
mutant_ledger() { # the unparsable-ledger report removed must fail the case
  cp "$SKILL/scripts/unlinked-worktrees.sh" "$M"; perl -0pi -e 's/else printf \x27%s\\t%s\\n\x27 "\(ledger\)".*?>> "\$TMP\/bad\.tsv"; fi/else :; fi/s' "$M"; perl -0pi -e 's/if ! gwhy="\$\(cm_workers_gate "\$LEDGER"\)"; then/if false; then/' "$M"; perl -0pi -e 's/\[ -n "\$sbad" \] \|\| sbad=1/sbad="\${sbad:-0}"/' "$M"
  if cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$M"; then fail "mutant ledger parse report" "the edit changed nothing"; return; fi
  printf '{"workers": [oops\n' > "$CM_HOME/ledger.json"; run "$M"
  if grep -q "CHECK INCOMPLETE: (ledger)" <<<"$OUT"; then fail "mutant ledger parse report" "still reported"; else pass "mutant ledger parse report removed is caught"; fi
  printf '{"workers":{"w-ledger":{"standing":true,"path":"%s/ledger-lane/"}}}\n' "$W" > "$CM_HOME/ledger.json"
}
mutant_ledger
mutant "never_touch exemption removed" 's/elif \(\.path \| ascii_downcase \| split\("\/"\)\) as \$segs .*? then "never_touch"//s'

# ---- time budget: hosts are read in parallel and a host past the budget is CHECK INCOMPLETE ----
cat > "$ROOT/bin/fleet-stub-slow" <<'E'
#!/usr/bin/env bash
[ "$1 $2" != "worktree list" ] || sleep "${STUB_SLEEP:-0}"
exec "$ORIG_STUB" "$@"
E
chmod +x "$ROOT/bin/fleet-stub-slow"; ORIG_STUB="$ROOT/bin/fleet-stub"; export ORIG_STUB
hostlist h1 h2 h3 h4 h5 h6; for h in h1 h2 h3 h4 h5 h6; do put $h "$(row $W/dev-$h null null)"; done
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub-slow"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub-slow"; fi
S0=$SECONDS; STUB_SLEEP=2 run; EL=$((SECONDS - S0))
check "six hosts that each take 2 s are read in parallel (well under the 12 s a sequential loop needs), all six rows listed" '[ "$EL" -lt 9 ] && grep -q "^unlinked-worktrees: 6 (target 0)\$" <<<"$OUT"' "elapsed=$EL $OUT"
S0=$SECONDS; STUB_SLEEP=8 CM_UNLINKED_BUDGET=3 run; EL=$((SECONDS - S0))
check "a host that outlives the time budget is 'not checked: time budget' (CHECK INCOMPLETE, never 'all linked'), the run ends near the budget" '[ "$EL" -lt 7 ] && grep -q "CHECK INCOMPLETE" <<<"$OUT" && grep -q "not checked: time budget" <<<"$OUT"' "elapsed=$EL $OUT"
cp "$SKILL/scripts/unlinked-worktrees.sh" "$M"; perl -0pi -e 's/read_host "\$n" "\$host" & JOBS\+=\("\$!"\)/read_host "\$n" "\$host"/' "$M"
if cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$M"; then fail "mutant sequential reads" "the edit changed nothing"; else
  S0=$SECONDS; STUB_SLEEP=2 run "$M"; EL=$((SECONDS - S0))
  if [ "$EL" -ge 9 ]; then pass "mutant sequential host reads is caught (6 x 2 s took ${EL}s)"; else fail "mutant sequential reads" "still fast: ${EL}s"; fi
fi
cp "$SKILL/scripts/unlinked-worktrees.sh" "$M"; perl -0pi -e 's/ht="\$HT"; \[ "\$left" -ge "\$ht" \] \|\| ht="\$left"; /ht="\$HT"; /' "$M"
if cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$M"; then fail "mutant budget cut" "the edit changed nothing"; else
  S0=$SECONDS; STUB_SLEEP=6 CM_UNLINKED_BUDGET=2 run "$M"; EL=$((SECONDS - S0))
  if [ "$EL" -ge 6 ]; then pass "mutant budget cut removed is caught (waited ${EL}s past a 2 s budget)"; else fail "mutant budget cut" "still bounded: ${EL}s"; fi
fi
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub"; fi

# ---- the concertmaster exemption is a name AND a repo: a same-named worktree of another repo is an ordinary worktree ----
cat > "$ROOT/orca.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees:
  path_match: "/acme/|/learning/"
  self_name: concertmaster
  orca_repo: acme
CFG
hostlist local
put local "$(row /work/acme/concertmaster null null)" "$(row /work/learning/concertmaster null null)"
CM_CONFIG="$ROOT/orca.yaml" run
check "with worktrees.orca_repo set, the concertmaster under /acme/ is exempt and a same-named worktree under /learning/ is LISTED" '! grep -q "UNLINKED concertmaster @ local: /work/acme/" <<<"$OUT" && grep -q "UNLINKED concertmaster @ local: /work/learning/concertmaster" <<<"$OUT"' "$OUT"
cp "$SKILL/scripts/unlinked-worktrees.sh" "$M"; perl -0pi -e 's/ and \(\$orca == "" or [^\n]*? then "concertmaster worktree"/ then "concertmaster worktree"/' "$M"
if cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$M"; then fail "mutant repo check on the concertmaster exemption" "the edit changed nothing"; else
  CM_CONFIG="$ROOT/orca.yaml" run "$M"
  if grep -q "learning/concertmaster" <<<"$OUT"; then fail "mutant repo check on the concertmaster exemption" "still listed"; else pass "mutant repo check removed is caught (the other repo's concertmaster hidden)"; fi
fi

# the name-shape exemption put BACK must be caught: dev-lead-time-fix would vanish from the report
cp "$SKILL/scripts/unlinked-worktrees.sh" "$M"; perl -0pi -e 's/(      elif \(\(\$host \| ascii_downcase\) \+ "\|" \+ \(\.path \| sub\("\/\+\$"; ""\)\)\) as \$p \| any\(\$stand)/      elif any(names[]; test("-lead(\$|-)|-sweeper|^epic[-:]")) then "standing lane (lane-shaped)"\n$1/' "$M"
if cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$M"; then fail "mutant name-shape exemption restored" "the edit changed nothing"; else
  put local "$(row $W/dev-lead-time-fix null null)" "$(row $W/dev-5 null null)"
  run "$M"
  if grep -q "dev-lead-time-fix" <<<"$OUT"; then fail "mutant name-shape exemption restored" "still listed"; else pass "mutant name-shape exemption restored is caught (dev-lead-time-fix hidden)"; fi
fi

# ---- a worktree list cut off at the limit makes the census INCOMPLETE, never "fewer worktrees" ----
# putx <host> <truncated true|false> <totalCount> <row>...: a worktree list reply with the given truncation fields
putx() { local h="$1" t="$2" c="$3"; shift 3; printf '%s\n' "$@" | jq -s -c --argjson t "$t" --argjson c "$c" '{ok: true, result: {worktrees: ., totalCount: $c, truncated: $t}}' > "$STUB_DIR/wl-$h.json"; }
hostlist local
putx local true 500 "$(row $W/dev-7 null null)" "$(row $W/dev-8 8 null)"
run
check "truncated:true: the header says CHECK INCOMPLETE naming the host and the truncation, never a plain count" 'grep -q "^unlinked-worktrees: 1 (target 0) (CHECK INCOMPLETE: local: worktree list truncated at the limit of 500" <<<"$OUT"' "$OUT"
check "...the rows that WERE returned are still judged and listed, and the run still exits 0" 'grep -qF "UNLINKED dev-7 @ local: $W/dev-7 pr=none" <<<"$OUT" && [ "$RC" = 0 ]' "rc=$RC $OUT"
run "$S" --json
check "--json: truncated:true is complete:false with the host in the problems (hosts[])" 'jq -e ".complete == false and (.hosts | map(select(.name == \"local\" and (.error | test(\"truncated\")))) | length) == 1 and (.unlinked | length) == 1" <<<"$OUT" >/dev/null' "$OUT"
putx local false 900 "$(row $W/dev-7 null null)" "$(row $W/dev-8 8 null)"
run
check "a totalCount above the rows returned (the other truncation signal) is CHECK INCOMPLETE too" 'grep -q "CHECK INCOMPLETE: local: worktree list truncated" <<<"$OUT"' "$OUT"
putx local false 2 "$(row $W/dev-7 null null)" "$(row $W/dev-8 8 null)"
run
check "truncated:false and totalCount equal to the rows: complete, no CHECK INCOMPLETE" '[ "$OUT" = "$(printf "unlinked-worktrees: 1 (target 0)\n  UNLINKED dev-7 @ local: $W/dev-7 pr=none")" ]' "$OUT"
hostlist local box2
putx local false 1 "$(row $W/dev-1 1 null)"
putx box2 true 500 "$(row $W/remote-job null null)"
run
check "truncation on ONE host names only that host; the other host is read as before" 'grep -q "CHECK INCOMPLETE: box2: worktree list truncated" <<<"$OUT" && ! grep -q "local: worktree list truncated" <<<"$OUT" && grep -qF "UNLINKED remote-job @ box2" <<<"$OUT"' "$OUT"
# the mutants: the truncation test removed (both signals, then each alone) must read the census as complete again
trunc_mutant() { # <label> <perl> <truncated> <totalCount>
  cp "$SKILL/scripts/unlinked-worktrees.sh" "$M"; perl -0pi -e "$2" "$M"
  if cmp -s "$SKILL/scripts/unlinked-worktrees.sh" "$M"; then fail "mutant $1" "the edit changed nothing"; return; fi
  hostlist local; putx local "$3" "$4" "$(row $W/dev-7 null null)" "$(row $W/dev-8 8 null)"
  run "$M"
  if grep -q "CHECK INCOMPLETE" <<<"$OUT"; then fail "mutant $1" "still incomplete: $OUT"; else pass "mutant $1 is caught (the cut-off list read as complete)"; fi
}
trunc_mutant "truncation check removed" 's/  if jq -e \x27\.result\.truncated == true or[^\n]*\n    printf[^\n]*\n  fi\n//' true 500
trunc_mutant "truncated:true signal removed" 's/\.result\.truncated == true or \(\(\(\.result\.totalCount/false or (((.result.totalCount/' true 2
trunc_mutant "totalCount signal removed" 's/ or \(\(\(\.result\.totalCount \/\/ null\) \| type\) == "number" and \.result\.totalCount > \(\.result\.worktrees \| length\)\)//' false 900

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
