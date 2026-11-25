#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2016  # pass() always succeeds; check bodies are single-quoted on purpose
# capacity-check.sh (test): the tick check that counts agent terminals per host against the cap and lists teardown candidates
# for a host over its cap, hermetic. A stub fleet CLI (host list, terminal list per host) with replies in the real
# plugly shape (`agentIdentity` string or null), a classify.sh-shaped JSON fixture, no network, no real plugly or orca call.
# Covers: per-host count vs cap on the HOST lines; a host over its cap lists done-merged and task-done workers and bare shells;
# NEVER a standing lane (configured, lane-shaped, ledger standing, flagged standing or cm:keep), the concertmaster's own
# worktree, a worker with an open PR, dirty or unpushed git, a beads epic, a child agent or any running worker, nor a bare shell
# in one of those; a host exactly at its cap is ok (over means count > cap); a host under cap says "none needed" and the
# classification is never asked for; a bare shell is not counted; an agent terminal outside path_match counts but is never a
# candidate; per_host, ledger and defaults caps resolve in queue.sh order, with CM_CAPACITY_DEFAULT_CAP only when set (a host with no cap is CHECK INCOMPLETE); an unreadable host and a
# cut-off list are CHECK INCOMPLETE (not over, not clean); a classification that cannot be read lists NO candidate (CANDIDATES
# UNKNOWN) and still exits 1; the fallback classify command runs only when a host is over cap; --json carries the same rows;
# exit 0 within cap / 1 over cap / 2 usage. Mutants on a scratch copy: the open-work guard, the standing-lane guard, the
# concertmaster guard, the over-cap comparison and the agent-only count each broken must fail a case.
#
#   scripts/test/capacity-check.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-capacity-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
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
lanes:
  - { name: pr-sweeper, standing: true }
ownership:
  leads: { buildboss: build }
hosts:
  defaults: { role: general, maxWorkers: 2 }
  per_host:
    local: { role: general, maxWorkers: 3 }
    box2:  { role: general, maxWorkers: 2 }
    box3:  { role: general, maxWorkers: 2 }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_TEST=1
unset CM_ORG CM_REPO CM_PATH_MATCH CM_SELF_WORKTREE CM_LEDGER CM_SELF_PATH CM_CAPACITY_CLASSIFY_CMD CM_CAPACITY_DEFAULT_CAP ORCA_CLI_COMMAND PLUGLY_CLI_COMMAND
export CM_CLI_KIND="${CM_CLI_KIND:-orca}"

# the stub fleet CLI: `host list` and `terminal list [--environment <h>]` read $STUB_DIR files; the argv is logged
mkdir -p "$ROOT/bin" "$ROOT/stub"
export STUB_DIR="$ROOT/stub" STUB_LOG="$ROOT/stub.log"
cat > "$ROOT/bin/fleet-stub" <<'E'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "host list") [ -f "$STUB_DIR/hostlist.json" ] || { echo "no host list" >&2; exit 1; }; cat "$STUB_DIR/hostlist.json" ;;
  "terminal list")
    shift 2; h=local
    while [ $# -gt 0 ]; do case "$1" in --environment) h="$2"; shift 2 ;; *) shift ;; esac; done
    [ -f "$STUB_DIR/tl-$h.json" ] || { echo "host $h unreachable" >&2; exit 1; }
    cat "$STUB_DIR/tl-$h.json" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
E
chmod +x "$ROOT/bin/fleet-stub"
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub"; fi

# term <handle> <path> <agentIdentity|null>: one terminal row in the real shape
term() { jq -cn --arg h "$1" --arg p "$2" --argjson a "$3" '{handle: $h, worktreePath: $p, worktreeId: ("repo::" + $p), title: "t", agentIdentity: $a}'; }
# putt <host> <row>...: the terminal list reply of a host
putt() { local h="$1"; shift; printf '%s\n' "$@" | jq -s -c '{ok: true, result: {terminals: ., totalCount: length, truncated: false}}' > "$STUB_DIR/tl-$h.json"; }
hostlist() { printf '%s\n' "$@" | jq -R -s -c '{ok: true, result: {hosts: (split("\n") | map(select(length > 0)) | map(if . == "local" then {kind: "local", name: "this machine", id: "local"} else {kind: "remote", name: ., id: .} end))}}' > "$STUB_DIR/hostlist.json"; }
# item <host> <class> <path> <flags-json> <prState|null>: one classify.sh item
item() { jq -cn --arg h "$1" --arg c "$2" --arg p "$3" --argjson f "$4" --arg s "$5" '{host: $h, class: $c, path: $p, flags: $f, pr: (if $s == "null" then null else {number: 9, state: $s} end)}'; }
CLS="$ROOT/classified.json"
putc() { printf '%s\n' "$@" | jq -s -c '{items: .}' > "$CLS"; }
S="$SKILL/scripts/capacity-check.sh"
run() { : > "$STUB_LOG"; bash "${1:-$S}" "${@:2}" >"$ROOT/out" 2>"$ROOT/err"; RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"; }
W=/work/acme

hostlist local box2 box3
# local: cap 3, twelve agent terminals + bare shells
putt local \
  "$(term t-merged $W/dev-merged '"claude"')" \
  "$(term t-done $W/dev-done '"claude"')" \
  "$(term t-openpr $W/dev-openpr '"claude"')" \
  "$(term t-doneopen $W/dev-doneopen '"claude"')" \
  "$(term t-dirty $W/dev-dirty '"claude"')" \
  "$(term t-beads $W/dev-beads '"claude"')" \
  "$(term t-lane $W/pr-sweeper '"claude"')" \
  "$(term t-cm $W/concertmaster '"claude"')" \
  "$(term t-ledger $W/led-lane '"claude"')" \
  "$(term t-keep $W/dev-keep '"claude"')" \
  "$(term t-elsewhere /elsewhere/x '"claude"')" \
  "$(term t-unknown $W/dev-unknown '"claude"')" \
  "$(term t-child $W/dev-child '"claude"')" \
  "$(term t-shell-merged $W/dev-merged null)" \
  "$(term t-shell-stray $W/stray null)" \
  "$(term t-shell-running $W/dev-openpr null)" \
  "$(term t-shell-lane $W/pr-sweeper null)" \
  "$(term t-shell-cm $W/concertmaster null)" \
  "$(term t-shell-lead $W/buildboss null)"
putt box2 "$(term b-1 $W/dev-b1 '"claude"')" "$(term b-shell $W/dev-b1 null)"
putt box3 "$(term c-1 $W/dev-c1 '"claude"')" "$(term c-2 $W/dev-c2 '"codex"')"
putc \
  "$(item local done-merged $W/dev-merged '["pr:#9:MERGED","no-pr"]' MERGED)" \
  "$(item local done-selfreported $W/dev-done '["no-pr"]' null)" \
  "$(item local running $W/dev-openpr '["pr:#9:OPEN"]' OPEN)" \
  "$(item local done-selfreported $W/dev-doneopen '["pr:#9:OPEN"]' OPEN)" \
  "$(item local done-merged $W/dev-dirty '["pr:#9:MERGED","dirty:3"]' MERGED)" \
  "$(item local done-merged $W/dev-beads '["pr:#9:MERGED","beads-epic:E-1"]' MERGED)" \
  "$(item local standing-idle $W/pr-sweeper '["standing"]' null)" \
  "$(item local running $W/concertmaster '[]' null)" \
  "$(item local done-merged $W/led-lane '["pr:#9:MERGED"]' MERGED)" \
  "$(item local done-merged $W/dev-keep '["cm:keep","pr:#9:MERGED"]' MERGED)" \
  "$(item local done-merged $W/dev-child '["has-child-agent","pr:#9:MERGED"]' MERGED)" \
  "$(item box2 done-merged $W/dev-b1 '["pr:#9:MERGED"]' MERGED)"
printf '{"workers":{"w-led":{"standing":true,"path":"%s/led-lane/"}}}\n' "$W" > "$CM_HOME/ledger.json"
ASKLOG="$ROOT/classify.asked"; : > "$ASKLOG"

run "$S" --classified "$CLS"
check "local counts 13 agent terminals against cap 3 and is OVER by 10 (bare shells not counted)" 'grep -qx "  HOST local claude=13 cap=3 OVER by 10" <<<"$OUT"' "$OUT"
check "the header counts the hosts over cap" 'grep -q "^capacity: 1 of 3 hosts over cap (target 0)\$" <<<"$OUT"' "$OUT"
check "exit 1 when a host is over its cap" '[ "$RC" = 1 ]' "rc=$RC"
check "a done-merged worker is a pr-merged candidate with its handle" 'grep -qF "  CANDIDATE local t-merged pr-merged dev-merged: $W/dev-merged" <<<"$OUT"' "$OUT"
check "a done-selfreported worker is a task-done candidate" 'grep -qF "  CANDIDATE local t-done task-done dev-done: $W/dev-done" <<<"$OUT"' "$OUT"
check "a bare shell in a done worktree is a bare-shell candidate" 'grep -qF "  CANDIDATE local t-shell-merged bare-shell dev-merged: $W/dev-merged" <<<"$OUT"' "$OUT"
check "a bare shell in a path with NO classification row is NOT a candidate" '! grep -q "t-shell-stray" <<<"$OUT"' "$OUT"
check "exactly three candidates are listed (two workers, one bare shell in a done worktree)" '[ "$(grep -c "^  CANDIDATE " <<<"$OUT")" = 3 ]' "$OUT"
check "candidates are followed by ONE plain NOTE that the list does not read the beads store and that teardown.sh refuses on open beads" '[ "$(grep -c "^  NOTE local: " <<<"$OUT")" = 1 ] && grep -q "^  NOTE local: .*does not read a worktree.s beads store" <<<"$OUT" && grep -q "teardown.sh refuses on open beads" <<<"$OUT" && grep -q "dry-run it (no --apply)" <<<"$OUT" && [ "$(grep -n "^  NOTE" <<<"$OUT" | cut -d: -f1)" -gt "$(grep -n "^  CANDIDATE" <<<"$OUT" | tail -n1 | cut -d: -f1)" ]' "$OUT"
check "a standing lane (configured name) is NEVER listed, nor its bare shell" '! grep -qE "t-lane|t-shell-lane|pr-sweeper" <<<"$(grep "^  CANDIDATE" <<<"$OUT")"' "$OUT"
check "an ownership lead (buildboss) bare shell is NEVER listed" '! grep -q "t-shell-lead" <<<"$OUT"' "$OUT"
check "the concertmaster own worktree is NEVER listed, nor its bare shell" '! grep -qE "t-cm|t-shell-cm" <<<"$OUT"' "$OUT"
check "a ledger standing worker is NEVER listed" '! grep -q "t-ledger" <<<"$OUT"' "$OUT"
# a standing that is not the boolean is read as standing: never listed as a candidate; control: standing false is listed
cp "$CM_HOME/ledger.json" "$ROOT/ledger.at-b"
for bad in '"true"' 1 '{}' '[]' '"yes"'; do
  jq --argjson v "$bad" '.workers["w-led"].standing = $v' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
  check "standing $bad: a ledger worker is still NEVER listed" '! grep -q "t-ledger" <<<"$OUT"' "$OUT"
done
jq '.workers["w-led"].standing = false' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
check "control: standing false is listed" 'grep -qF "  CANDIDATE local t-ledger " <<<"$OUT"' "$OUT"
# a path that is not text must not hide a valid worktree key of the same standing row (the lane keeps its exemption)
jq '.workers["w-led"] |= (. + {worktree: .path} | .path = 7)' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
check "a path of 7 does not hide the worktree key: the ledger worker is still NEVER listed" '! grep -q "t-ledger" <<<"$OUT"' "$OUT"
# Typed boundary: a ledger row that cannot be read (not an object, a host or path that is not text, a standing row with no path that is text) can exempt no worktree, and
# it was read as "no such lane": the lane was listed as a candidate to close. Now no candidate is listed while there is one, and the report says why. Controls: a dead record
# with a wrong-typed path holds nothing, and the same ledger with standing false lists the worker.
for patch in '.workers["w-led"].path = false' '.workers["w-led"].path = ["/x"]' '.workers["w-led"].standing = false | .workers["w-junk"] = false' '.workers["w-led"].standing = false | .workers["w-junk"] = null' \
             '.workers["w-led"].standing = false | .workers["w-junk"] = {host: ["local"], path: "/elsewhere"}' '.workers["w-led"].standing = false | .workers["w-junk"] = {host: "local", path: false, standing: true}'; do
  jq "$patch" "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
  check "typed boundary ($patch): no candidate is listed" '! grep -q "^  CANDIDATE " <<<"$OUT"' "$OUT"
  check "typed boundary ($patch): the report says a ledger row cannot be read" 'grep -q "CHECK INCOMPLETE" <<<"$OUT" && grep -q "cannot be read" <<<"$OUT"' "$OUT"
done
jq '.workers["w-led"].standing = false | .workers["w-junk"] = {host: "local", path: false, standing: true, state: "gone"}' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
check "typed boundary control: a gone record with a path of the wrong type holds nothing, the worker is listed" 'grep -qF "  CANDIDATE local t-ledger " <<<"$OUT"' "$OUT"
# mutant: a copy that does not count the unreadable rows lists the lane again, so the cases above are caught
mkdir -p "$ROOT/mut-tb/scripts" && cp "$SKILL"/scripts/lib.sh "$SKILL"/scripts/capacity-check.sh "$SKILL"/scripts/jdupkeys "$ROOT/mut-tb/scripts/"
sed -i 's/^\[ -n "\$STAND_BAD" \] || STAND_BAD=1$/STAND_BAD=0/' "$ROOT/mut-tb/scripts/capacity-check.sh"
if ! cmp -s "$SKILL/scripts/capacity-check.sh" "$ROOT/mut-tb/scripts/capacity-check.sh"; then
  jq '.workers["w-led"].standing = false | .workers["w-junk"] = false' "$ROOT/ledger.at-b" > "$CM_HOME/ledger.json"; run "$ROOT/mut-tb/scripts/capacity-check.sh" --classified "$CLS"
  if grep -qF '  CANDIDATE local t-ledger ' <<<"$OUT"; then pass "mutant: with the unreadable-row count off the worker is listed again, the typed-boundary case is caught"; else fail "mutant typed boundary" "the mutated script still listed no candidate: $OUT"; fi
else fail "mutant typed boundary" "the sed no longer matches capacity-check.sh"; fi
# a ledger that cannot be read as ONE object with a worker map must hold every candidate, never read as "no standing lane" (it listed the ledger-standing lane to close).
# false, [], "x", 7, true as workers; [], null, "x" as the whole ledger; a truncated and an empty file; a key written twice in a row (jq keeps the last: standing false,...,true).
# Every one: no candidate is listed and the report says the ledger cannot be read. Control: workers null/absent is a ledger with no rows and still lists.
badledger() { # <label> <ledger text>
  printf '%s\n' "$2" > "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
  check "unreadable ledger ($1): no candidate is listed" '! grep -q "^  CANDIDATE " <<<"$OUT"' "$OUT"
  check "unreadable ledger ($1): the report says a ledger row cannot be read" 'grep -q "CHECK INCOMPLETE" <<<"$OUT" && grep -q "cannot be read" <<<"$OUT"' "$OUT"
}
for bad in false '[]' '"x"' 7 true; do badledger "workers $bad" "{\"workers\": $bad}"; done
for bad in '[]' null '"x"' 7 false; do badledger "ledger $bad" "$bad"; done
badledger "truncated" '{"workers": {"w-led": {"standing": true, "path": "/x'
badledger "empty file" ''
DUPL="$(jq -c . "$ROOT/ledger.at-b" | sed 's/"standing":true/"standing":false,"standing":true/')"
check "the dup fixture really has a repeated key" 'grep -q "\"standing\":false,\"standing\":true" <<<"$DUPL"' "$DUPL"
badledger "repeated key standing false then true" "$DUPL"
# a ledger of two JSON documents used to print "(ledger): 0; 0 ledger worker row(s)" (one count per document): it now says what is wrong
TWODOC="$(jq -c . "$ROOT/ledger.at-b")"$'\n''{"workers":{}}'
badledger "two JSON documents" "$TWODOC"
check "two documents: the report says the ledger holds more than one JSON document, with one count" 'grep -q "ledger holds more than one JSON document" <<<"$OUT" && grep -q "1 ledger worker row(s) cannot be read" <<<"$OUT" && ! grep -qF "(ledger): 0; 0" <<<"$OUT"' "$OUT"
mkdir -p "$ROOT/mut-2d/scripts" && cp -R "$SKILL"/scripts/. "$ROOT/mut-2d/scripts/"
sed -i '/^case "\$STAND_BAD" in/d' "$ROOT/mut-2d/scripts/capacity-check.sh"
if ! cmp -s "$SKILL/scripts/capacity-check.sh" "$ROOT/mut-2d/scripts/capacity-check.sh"; then
  printf '%s\n' "$TWODOC" > "$CM_HOME/ledger.json"; run "$ROOT/mut-2d/scripts/capacity-check.sh" --classified "$CLS"
  if grep -qF '(ledger): 0; 0' <<<"$OUT"; then pass "mutant: without the count normalisation a two-document ledger prints '0; 0' again, the case is caught"; else fail "mutant two documents" "the mutated script still printed one count: $OUT"; fi
else fail "mutant two documents" "the sed no longer matches capacity-check.sh"; fi
printf '{"workers": null}\n' > "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
check "control: workers null is a ledger with no rows, candidates are listed" 'grep -q "^  CANDIDATE " <<<"$OUT"' "$OUT"
# mutant: without the ledger gate every one of them lists again
mkdir -p "$ROOT/mut-ur/scripts" && cp "$SKILL"/scripts/lib.sh "$SKILL"/scripts/capacity-check.sh "$SKILL"/scripts/jdupkeys "$ROOT/mut-ur/scripts/"
sed -i 's/^\[ -z "\$LEDGER_BAD" \] || \[ "\$STAND_BAD" != 0 \] || STAND_BAD=1$/:/' "$ROOT/mut-ur/scripts/capacity-check.sh"
if ! cmp -s "$SKILL/scripts/capacity-check.sh" "$ROOT/mut-ur/scripts/capacity-check.sh"; then
  for bad in '{"workers": false}' '{"workers": []}' '[]' 'null' '"x"' '{"workers": {"w-led": {"standing": true, "path": "/x'; do
    printf '%s\n' "$bad" > "$CM_HOME/ledger.json"; run "$ROOT/mut-ur/scripts/capacity-check.sh" --classified "$CLS"
    if grep -q '^  CANDIDATE ' <<<"$OUT"; then pass "mutant: without the ledger gate '$bad' lists a candidate again, the case is caught"; else fail "mutant unreadable ledger $bad" "the mutated script still listed no candidate"; fi
  done
  printf '%s\n' "$DUPL" > "$CM_HOME/ledger.json"; run "$ROOT/mut-ur/scripts/capacity-check.sh" --classified "$CLS"
  if grep -q '^  CANDIDATE ' <<<"$OUT"; then pass "mutant: without the ledger gate a repeated key lists a candidate again, the case is caught"; else fail "mutant repeated key" "the mutated script still listed no candidate"; fi
else fail "mutant unreadable ledger" "the sed no longer matches capacity-check.sh"; fi
cp "$ROOT/ledger.at-b" "$CM_HOME/ledger.json"; run "$S" --classified "$CLS"
check "a cm:keep worker is NEVER listed" '! grep -q "t-keep" <<<"$OUT"' "$OUT"
check "a worker with an open PR (running) is NEVER listed, nor its bare shell" '! grep -qE "t-openpr|t-shell-running" <<<"$OUT"' "$OUT"
check "a done-selfreported worker whose PR is still OPEN is NEVER listed" '! grep -q "t-doneopen" <<<"$OUT"' "$OUT"
check "a worker with dirty git is NEVER listed" '! grep -q "t-dirty" <<<"$OUT"' "$OUT"
check "a worker with a beads epic is NEVER listed" '! grep -q "t-beads" <<<"$OUT"' "$OUT"
check "a worker with a child agent is NEVER listed" '! grep -q "t-child" <<<"$OUT"' "$OUT"
check "a worktree the classification cannot place is NEVER listed as an agent candidate" '! grep -q "t-unknown" <<<"$OUT"' "$OUT"
check "an agent terminal outside path_match is counted but NEVER listed" '! grep -q "t-elsewhere" <<<"$OUT"' "$OUT"
check "a host under its cap says none needed with no candidate row" 'grep -qx "  HOST box2 claude=1 cap=2 ok (none needed)" <<<"$OUT"' "$OUT"
check "a host exactly at its cap (2 of the default 2, a codex agent counts) is ok, not over" 'grep -qx "  HOST box3 claude=2 cap=2 ok (none needed)" <<<"$OUT"' "$OUT"
check "no candidate row names a host that is within its cap" '! grep -E "^  CANDIDATE (box2|box3) " <<<"$OUT"' "$OUT"
check "the report holds no em-dash and no non-ASCII" '! LC_ALL=C grep -qP "[^\x00-\x7F]" <<<"$OUT"' "$OUT"

# --json
run "$S" --classified "$CLS" --json
check "--json carries the host rows, the over count and complete:true, exit 1" 'jq -e ".over == 1 and .complete == true and (.hosts | map(select(.host == \"local\"))[0] | .count == 13 and .cap == 3 and .over == true and (.candidates | length) == 3) and (.hosts | map(select(.host == \"box2\"))[0] | .over == false and .candidatesState == \"none-needed\")" <<<"$OUT" >/dev/null && [ "$RC" = 1 ]' "rc=$RC $OUT"
check "--json: a host with candidates carries candidatesNote (the beads-store limit), a host without does not" 'jq -e "(.hosts | map(select(.host == \"local\"))[0].candidatesNote | test(\"beads store\") and test(\"refuses on open beads\")) and (.hosts | map(select(.host == \"box2\"))[0] | has(\"candidatesNote\") | not)" <<<"$OUT" >/dev/null' "$OUT"

# under cap everywhere: exit 0, the classification is never asked for
putt local "$(term t-1 $W/dev-1 '"claude"')" "$(term t-2 $W/dev-2 '"claude"')" "$(term t-sh $W/dev-3 null)"
export CM_CAPACITY_CLASSIFY_CMD="echo asked >> $ASKLOG; cat $CLS"
run
check "under cap everywhere: 'capacity: 0 of 3 hosts over cap', every host ok, exit 0" 'grep -q "^capacity: 0 of 3 hosts over cap (target 0)\$" <<<"$OUT" && grep -qx "  HOST local claude=2 cap=3 ok (none needed)" <<<"$OUT" && ! grep -q CANDIDATE <<<"$OUT" && [ "$RC" = 0 ]' "rc=$RC $OUT"
check "under cap: no NOTE (it follows candidate rows only)" '! grep -q "NOTE" <<<"$OUT"' "$OUT"
check "under cap: the classification is never run" '[ ! -s "$ASKLOG" ]' "$(cat "$ASKLOG")"

# over cap with no --classified: the fallback classify command runs, once
putt local "$(term t-1 $W/dev-merged '"claude"')" "$(term t-2 $W/dev-done '"claude"')" "$(term t-3 $W/dev-openpr '"claude"')" "$(term t-4 $W/dev-beads '"claude"')"
run
check "over cap, no --classified: the fallback command is run and its candidates are listed" '[ "$(wc -l < "$ASKLOG" | tr -d " ")" = 1 ] && grep -q "CANDIDATE local t-1 pr-merged dev-merged" <<<"$OUT" && grep -q "CANDIDATE local t-2 task-done dev-done" <<<"$OUT" && ! grep -qE "t-3|t-4" <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
check "the host line says OVER by 1 (4 of cap 3)" 'grep -qx "  HOST local claude=4 cap=3 OVER by 1" <<<"$OUT"' "$OUT"

# --no-candidates (boot-sweep): counts and caps only, the classification is never run, no candidate row and no UNKNOWN row
: > "$ASKLOG"; export CM_CAPACITY_CLASSIFY_CMD="echo asked >> $ASKLOG; cat $CLS"
run "$S" --no-candidates
check "--no-candidates: the over-cap host line is printed, no classification is run, no CANDIDATE row, exit 1" 'grep -qx "  HOST local claude=4 cap=3 OVER by 1" <<<"$OUT" && [ ! -s "$ASKLOG" ] && ! grep -q "CANDIDATE" <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
unset CM_CAPACITY_CLASSIFY_CMD

# a classification that cannot be read: NO candidate, never read as safe
export CM_CAPACITY_CLASSIFY_CMD="exit 3"
run
check "a failing classification lists NO candidate, says CANDIDATES UNKNOWN, and still exits 1" 'grep -q "^  CANDIDATES UNKNOWN local: classification failed" <<<"$OUT" && ! grep -q "^  CANDIDATE " <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
unset CM_CAPACITY_CLASSIFY_CMD
printf 'not json\n' > "$ROOT/bad-cls.json"
run "$S" --classified "$ROOT/bad-cls.json"
check "an unreadable --classified file lists NO candidate and says CANDIDATES UNKNOWN" 'grep -q "CANDIDATES UNKNOWN local" <<<"$OUT" && ! grep -q "^  CANDIDATE " <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
# an all-protected host: nothing safe
putc "$(item local standing-idle $W/dev-merged '["standing"]' null)" "$(item local running $W/dev-done '[]' OPEN)" "$(item local running $W/dev-openpr '[]' null)" "$(item local done-merged $W/dev-beads '["beads-epic:E-9"]' MERGED)"
run "$S" --classified "$CLS"
check "every terminal protected: NO SAFE CANDIDATES, nothing listed, exit 1" 'grep -q "^  NO SAFE CANDIDATES local: 1 over cap" <<<"$OUT" && ! grep -q "^  CANDIDATE " <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
check "...and no NOTE is printed when there is no candidate row" '! grep -q "NOTE" <<<"$OUT"' "$OUT"

# caps: ledger host cap, defaults cap, explicit default
hostlist local box4
putt local "$(term t-1 $W/dev-1 '"claude"')"
putt box4 "$(term d-1 $W/dev-d1 '"claude"')" "$(term d-2 $W/dev-d2 '"claude"')" "$(term d-3 $W/dev-d3 '"claude"')"
putc "$(item box4 done-merged $W/dev-d1 '[]' MERGED)"
run "$S" --classified "$CLS"
check "a host with no per_host key uses hosts.defaults.maxWorkers (2): 3 agents is OVER by 1" 'grep -qx "  HOST box4 claude=3 cap=2 OVER by 1" <<<"$OUT"' "$OUT"
printf '{"hosts":{"box4":{"maxWorkers":5}}}\n' > "$CM_HOME/ledger.json"
run "$S" --classified "$CLS"
check "the ledger host maxWorkers beats hosts.defaults (5): 3 agents is ok, exit 0" 'grep -qx "  HOST box4 claude=3 cap=5 ok (none needed)" <<<"$OUT" && [ "$RC" = 0 ]' "rc=$RC $OUT"
rm -f "$CM_HOME/ledger.json"
printf 'schema: concertmaster.config/v1\nworktrees: { path_match: "/acme/" }\n' > "$ROOT/nohosts.yaml"
CM_CONFIG="$ROOT/nohosts.yaml" run "$S" --classified "$CLS"
check "no hosts block anywhere: the host is CHECK INCOMPLETE naming it, never counted against a guessed cap of 2" 'grep -q "CHECK INCOMPLETE: .*box4: no cap configured for this host name" <<<"$OUT" && ! grep -q "HOST box4" <<<"$OUT"' "$OUT"
check "...and --json says complete:false with that host in the problems" 'CM_CONFIG="$ROOT/nohosts.yaml" bash "$S" --classified "$CLS" --json 2>/dev/null | jq -e ".complete == false and (.problems | map(.name) | index(\"box4\")) != null and ((.hosts | map(.host)) | index(\"box4\")) == null" >/dev/null'
run "$S" --classified "$CLS"
check "a host counted against the shared defaults cap (no per_host entry) gets a WARN row saying so, and is still counted" 'grep -q "(WARN: box4: no hosts.per_host.box4 entry: counted against the shared default cap 2" <<<"$OUT" && grep -qx "  HOST box4 claude=3 cap=2 OVER by 1" <<<"$OUT"' "$OUT"
CM_CAPACITY_DEFAULT_CAP=9 CM_CONFIG="$ROOT/nohosts.yaml" run "$S" --classified "$CLS"
check "CM_CAPACITY_DEFAULT_CAP overrides the built-in default" 'grep -qx "  HOST box4 claude=3 cap=9 ok (none needed)" <<<"$OUT" && [ "$RC" = 0 ]' "rc=$RC $OUT"

# an unreadable host is incomplete, never over and never clean
hostlist local box2
putt local "$(term t-1 $W/dev-1 '"claude"')"
rm -f "$STUB_DIR/tl-box2.json"
run "$S" --classified "$CLS"
check "an unreadable host is CHECK INCOMPLETE with its name, not counted as over, exit 0" 'grep -q "^capacity: 0 of 1 hosts over cap (target 0) (CHECK INCOMPLETE: box2: " <<<"$OUT" && [ "$RC" = 0 ]' "rc=$RC $OUT"
run "$S" --classified "$CLS" --json
check "--json says complete:false and names the host" 'jq -e ".complete == false and .problems[0].name == \"box2\"" <<<"$OUT" >/dev/null' "$OUT"
# a cut-off list is a lower bound, flagged
putt box2 "$(term b-1 $W/dev-b1 '"claude"')"
jq -c '.result.truncated = true' "$STUB_DIR/tl-box2.json" > "$STUB_DIR/x" && mv "$STUB_DIR/x" "$STUB_DIR/tl-box2.json"
run "$S" --classified "$CLS"
check "a truncated terminal list is CHECK INCOMPLETE (the count is a lower bound)" 'grep -q "CHECK INCOMPLETE: box2: terminal list truncated" <<<"$OUT"' "$OUT"
# a failed host list reads local only, and says so
rm -f "$STUB_DIR/hostlist.json"
run "$S" --classified "$CLS"
check "a failed host list reads the local host only and says so" 'grep -q "CHECK INCOMPLETE: (host list): " <<<"$OUT" && grep -q "HOST local " <<<"$OUT" && ! grep -q "HOST box2" <<<"$OUT"' "$OUT"
hostlist local box2 box3

# usage and missing scope
run "$S" --bogus
check "an unknown argument exits 2" '[ "$RC" = 2 ]' "rc=$RC $ERR"
run "$S" --classified
check "--classified without a file exits 2" '[ "$RC" = 2 ]' "rc=$RC $ERR"
CM_CAPACITY_DEFAULT_CAP=abc run
check "a non-numeric CM_CAPACITY_DEFAULT_CAP exits 2" '[ "$RC" = 2 ]' "rc=$RC $ERR"
printf 'schema: concertmaster.config/v1\n' > "$ROOT/noscope.yaml"
CM_CONFIG="$ROOT/noscope.yaml" run
check "no path_match: fail closed with a CHECK INCOMPLETE line, exit 0" 'grep -q "CHECK INCOMPLETE: no worktrees.path_match" <<<"$OUT" && [ "$RC" = 0 ]' "rc=$RC $OUT"

# ---- data of ledger or classification size is never an argument (Linux: one argument is capped at 128 KiB) ----
head -c 400000 /dev/zero | tr '\0' x > "$ROOT/pad.txt"; PAD="$(cat "$ROOT/pad.txt")"
hostlist local box4
putt local "$(term g-1 $W/dev-g1 '"claude"')" "$(term g-2 $W/dev-g2 '"claude"')" "$(term g-3 $W/dev-g3 '"claude"')" "$(term g-4 $W/dev-g4 '"claude"')"
putt box4 "$(term h-1 $W/dev-h1 '"claude"')" "$(term h-2 $W/dev-h2 '"claude"')" "$(term h-3 $W/dev-h3 '"claude"')"
jq -cn --rawfile pad "$ROOT/pad.txt" '{hosts: {box4: {maxWorkers: 5}}, workers: {}, pad: $pad}' > "$CM_HOME/ledger.json"
CLSBIG="$ROOT/classified-big.json"
jq -cn --rawfile pad "$ROOT/pad.txt" --arg p "$W/dev-g1" '{items: [{host: "local", class: "done-merged", path: $p, flags: [], pr: {number: 9, state: "MERGED"}}], pad: $pad}' > "$CLSBIG"
check "the padded ledger and classification really exceed one argument (400 KB each)" '[ "$(wc -c < "$CM_HOME/ledger.json")" -gt 200000 ] && [ "$(wc -c < "$CLSBIG")" -gt 200000 ]'
run "$S" --classified "$CLSBIG"
check "a 400 KB ledger: the config cap of local (3) still applies, never the default 2" 'grep -qx "  HOST local claude=4 cap=3 OVER by 1" <<<"$OUT"' "$OUT"
check "a 400 KB ledger: a host cap that lives only in the ledger (box4 = 5) is read, 3 agents is ok" 'grep -qx "  HOST box4 claude=3 cap=5 ok (none needed)" <<<"$OUT"' "$OUT"
check "a 400 KB classification still lists the candidate, with no CHECK INCOMPLETE and exit 1" 'grep -qF "  CANDIDATE local g-1 pr-merged dev-g1: $W/dev-g1" <<<"$OUT" && ! grep -q "CHECK INCOMPLETE" <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
cat > "$ROOT/cap1.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
hosts:
  per_host:
    local: { maxWorkers: 1 }
CFG
hostlist local
putt local "$(term g-1 $W/dev-g1 '"claude"')" "$(term g-2 $W/dev-g2 '"claude"')"
CM_CONFIG="$ROOT/cap1.yaml" run "$S" --classified "$CLSBIG"
check "2 agents on a host capped at 1 with a 400 KB classification: OVER by 1 and the candidate, never 'capacity: 0 of 0'" 'grep -qx "  HOST local claude=2 cap=1 OVER by 1" <<<"$OUT" && grep -q "CANDIDATE local g-1 pr-merged dev-g1" <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
printf '{"workers":{}}\n' > "$CM_HOME/ledger.json"
# a cap lookup that fails is CHECK INCOMPLETE, never the default cap
cat > "$ROOT/capbad.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
hosts:
  per_host:
    local: { maxWorkers: abc }
CFG
CM_CONFIG="$ROOT/capbad.yaml" run "$S" --classified "$CLSBIG"
check "an unusable cap (maxWorkers: abc) is CHECK INCOMPLETE naming the host, not the default cap, not an all-clear" 'grep -q "CHECK INCOMPLETE: local: cap lookup failed" <<<"$OUT" && ! grep -q "cap=2" <<<"$OUT" && ! grep -qx "capacity: 0 of 0 hosts over cap (target 0)" <<<"$OUT"' "rc=$RC $OUT"
CM_CONFIG="$ROOT/capbad.yaml" run "$S" --classified "$CLSBIG" --json
check "...and --json says complete:false with the problem" 'jq -e ".complete == false and (.problems | map(.name) | index(\"local\")) != null" <<<"$OUT" >/dev/null' "$OUT"
# a candidate pass that fails keeps the counts and says so
putc "$(jq -cn --arg p "$W/dev-g1" '{host: "local", class: "done-merged", path: $p, flags: "oops", pr: null}')"
CM_CONFIG="$ROOT/cap1.yaml" run "$S" --classified "$CLS"
check "a failing candidate pass: the host is still OVER, candidates UNKNOWN, CHECK INCOMPLETE, exit 1" 'grep -qx "  HOST local claude=2 cap=1 OVER by 1" <<<"$OUT" && grep -q "CANDIDATES UNKNOWN local" <<<"$OUT" && grep -q "CHECK INCOMPLETE: (candidates): the candidate pass failed" <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
check "none of the capacity scripts hands ledger, classification or list data to jq as an argument" '! grep -nE "\-\-argjson (L|cls|ledger|classified|stand|lanes|never|bad|items)\b" "$SKILL/scripts/capacity-check.sh" "$SKILL/scripts/unlinked-worktrees.sh"'

# ---- host identity (second review): the same machine under two names is a WARN row, and the reads are parallel and bounded ----
rm -f "$CM_HOME/ledger.json"
mk29() { local h="$1" pre="$2" i rows=(); for i in 1 2 3; do rows+=("$(term "$pre$i" "$W/dev-$pre$i" '"claude"')"); done; putt "$h" "${rows[@]}"; }
cat > "$ROOT/same.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
hosts:
  per_host:
    host-a:      { maxWorkers: 2, hostname: shared-box }
    host-b: { maxWorkers: 2, hostname: shared-box }
    other-1:    { maxWorkers: 2, hostname: other-a }
    other-2:    { maxWorkers: 2, hostname: other-b }
CFG
hostlist host-a host-b
mk29 host-a a; mk29 host-b b
CM_CONFIG="$ROOT/same.yaml" run "$S" --no-candidates
check "two hosts with an identical non-zero count and the same hostname: a WARN row naming both (counts left as read, both OVER)" 'grep -q "(WARN: host-b: host-a and host-b both report 3 agent terminals and look like ONE machine (the same hostname shared-box)" <<<"$OUT" && grep -qx "  HOST host-a claude=3 cap=2 OVER by 1" <<<"$OUT" && grep -qx "  HOST host-b claude=3 cap=2 OVER by 1" <<<"$OUT"' "$OUT"
CM_CONFIG="$ROOT/same.yaml" run "$S" --no-candidates --json
check "...and --json carries it under warnings" 'jq -e "(.warnings | length) == 1 and (.warnings[0].warning | test(\"ONE machine\"))" <<<"$OUT" >/dev/null' "$OUT"
cat > "$ROOT/alias.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
hosts:
  same_machine: [[host-a, host-b]]
  per_host:
    host-a:      { maxWorkers: 2 }
    host-b: { maxWorkers: 2 }
CFG
CM_CONFIG="$ROOT/alias.yaml" run "$S" --no-candidates
check "both names in one hosts.same_machine group: the same WARN (hosts.same_machine), no deprecation row" 'grep -q "ONE machine (hosts.same_machine)" <<<"$OUT" && ! grep -q "deprecated" <<<"$OUT"' "$OUT"
# the old list-of-name-lists health.host_aliases still counts, with a deprecation WARN; its map form is hostname aliases only
yq '.health.host_aliases = [["host-a", "host-b"]] | del(.hosts.same_machine)' "$ROOT/alias.yaml" > "$ROOT/alias-list.yaml"
yq '.health.host_aliases = {"host-a": ["host-b"]} | del(.hosts.same_machine)' "$ROOT/alias.yaml" > "$ROOT/alias-map.yaml"
CM_CONFIG="$ROOT/alias-list.yaml" run "$S" --no-candidates
check "health.host_aliases as a list of name lists (deprecated): the same WARN plus a deprecation row" 'grep -q "ONE machine (health.host_aliases, deprecated)" <<<"$OUT" && grep -q "(config): health.host_aliases as a list of name lists is deprecated: move it to hosts.same_machine" <<<"$OUT"' "$OUT"
CM_CONFIG="$ROOT/alias-map.yaml" run "$S" --no-candidates
check "health.host_aliases as a map (names hostname -s answers as) is not read as one machine" '! grep -q "ONE machine" <<<"$OUT" && ! grep -q "deprecated" <<<"$OUT"' "$OUT"
# the old example put a same-machine pair in the map form ({ build-box: [build-box-2] }): with no hosts.same_machine and
# both hosts at the same count (29 each), one row per entry points at hosts.same_machine instead of the WARN going silent
cat > "$ROOT/oldmap.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
health:
  host_aliases: { build-box: [build-box-2], other-box: [other-vm] }
hosts:
  per_host:
    build-box:   { maxWorkers: 40 }
    build-box-2: { maxWorkers: 40 }
CFG
mkn() { local h="$1" pre="$2" n="$3" i rows=(); for ((i = 1; i <= n; i++)); do rows+=("$(term "$pre$i" "$W/dev-$pre$i" '"claude"')"); done; putt "$h" "${rows[@]}"; }
hostlist build-box build-box-2; mkn build-box bb 29; mkn build-box-2 bc 29
CM_CONFIG="$ROOT/oldmap.yaml" run "$S" --no-candidates
check "old map-form same-machine entry, both hosts at 29: one row pointing at hosts.same_machine" 'grep -q "(config): health.host_aliases.build-box names build-box and build-box-2, which both report 29 agent terminals: health.host_aliases is now only the names hostname -s answers as, so they are no longer treated as one machine; if they are, list them in hosts.same_machine" <<<"$OUT" && [ "$(grep -o "health.host_aliases.build-box names" <<<"$OUT" | wc -l | tr -d " ")" = 1 ] && ! grep -q "other-box names" <<<"$OUT"' "$OUT"
yq '.hosts.same_machine = [["build-box", "build-box-2"]]' "$ROOT/oldmap.yaml" > "$ROOT/oldmap-sm.yaml"
yq '.hosts.same_machine = []' "$ROOT/oldmap.yaml" > "$ROOT/oldmap-empty.yaml"
CM_CONFIG="$ROOT/oldmap-empty.yaml" run "$S" --no-candidates
check "...with hosts.same_machine: [] (the new example): the map-form row still shows, once" '[ "$(grep -o "health.host_aliases.build-box names build-box and build-box-2, which both report 29" <<<"$OUT" | wc -l | tr -d " ")" = 1 ]' "$OUT"
yq '.hosts.same_machine = [["build-box", "other-1"]]' "$ROOT/oldmap.yaml" > "$ROOT/oldmap-other.yaml"
CM_CONFIG="$ROOT/oldmap-other.yaml" run "$S" --no-candidates
check "...with a hosts.same_machine group that does not hold the pair: the map-form row still shows" 'grep -q "health.host_aliases.build-box names build-box and build-box-2" <<<"$OUT"' "$OUT"
CM_CONFIG="$ROOT/oldmap-sm.yaml" run "$S" --no-candidates
check "...with hosts.same_machine set: the same-machine WARN, no map-form row" 'grep -q "ONE machine (hosts.same_machine)" <<<"$OUT" && ! grep -q "health.host_aliases.build-box names" <<<"$OUT"' "$OUT"
mkn build-box-2 bc 28
CM_CONFIG="$ROOT/oldmap.yaml" run "$S" --no-candidates
check "...and with different counts (29 and 28): no map-form row" '! grep -q "health.host_aliases.build-box names" <<<"$OUT"' "$OUT"
hostlist host-a host-b   # back to the pair the cases below read
cat > "$ROOT/two.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
hosts:
  per_host:
    host-a:      { maxWorkers: 2 }
    host-b: { maxWorkers: 2 }
CFG
CM_CONFIG="$ROOT/two.yaml" run "$S" --no-candidates
check "identical counts and nothing relating the two names (different handles): NO warning (two real machines can match)" '! grep -q "WARN" <<<"$OUT"' "$OUT"
putt host-b "$(term a1 $W/dev-a1 '"claude"')" "$(term a2 $W/dev-a2 '"claude"')" "$(term zz $W/dev-zz '"claude"')"
CM_CONFIG="$ROOT/two.yaml" run "$S" --no-candidates
check "identical counts and the same terminal handle on both lists: WARN (a terminal handle both lists hold)" 'grep -q "ONE machine (a terminal handle both lists hold)" <<<"$OUT"' "$OUT"
putt host-b "$(term b1 $W/dev-b1 '"claude"')"
CM_CONFIG="$ROOT/same.yaml" run "$S" --no-candidates
check "the same hostname but different counts: no same-machine warning" '! grep -q "ONE machine" <<<"$OUT"' "$OUT"
hostlist host-a host-b; mk29 host-a a; putt host-b
CM_CONFIG="$ROOT/same.yaml" run "$S" --no-candidates
check "a zero count on both is not evidence (no warning)" '! grep -q "ONE machine" <<<"$OUT"' "$OUT"
# the config names a host the census does not, and the census names one the config does not (queue.sh parity)
cat > "$ROOT/names.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
hosts:
  defaults: { maxWorkers: 2 }
  per_host:
    host-a: { maxWorkers: 2 }
    other-1: { maxWorkers: 2 }
CFG
hostlist host-a box9; putt host-a "$(term u1 $W/dev-u1 '"claude"')"; putt box9 "$(term u2 $W/dev-u2 '"claude"')"
CM_CONFIG="$ROOT/names.yaml" run "$S" --no-candidates
check "config hosts not read and read hosts not in the config: a '(host names)' WARN naming both sides" 'grep -q "(host names): config hosts .*other-1.* were not read, read hosts .*box9" <<<"$OUT"' "$OUT"

# parallel and bounded: 6 hosts that each answer after 2 s take about 2 s, not 12; a host past the budget is CHECK INCOMPLETE
cat > "$ROOT/bin/fleet-stub-slow" <<'E'
#!/usr/bin/env bash
[ "$1 $2" != "terminal list" ] || sleep "${STUB_SLEEP:-0}"
exec "$ORIG_STUB" "$@"
E
chmod +x "$ROOT/bin/fleet-stub-slow"
cat > "$ROOT/six.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
hosts:
  defaults: { maxWorkers: 5 }
  per_host: { h1: {maxWorkers: 5}, h2: {maxWorkers: 5}, h3: {maxWorkers: 5}, h4: {maxWorkers: 5}, h5: {maxWorkers: 5}, h6: {maxWorkers: 5} }
CFG
hostlist h1 h2 h3 h4 h5 h6; for h in h1 h2 h3 h4 h5 h6; do putt $h "$(term "$h-1" "$W/dev-$h-1" '"claude"')"; done
ORIG_STUB="$ROOT/bin/fleet-stub"; export ORIG_STUB
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub-slow"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub-slow"; fi
S0=$SECONDS; STUB_SLEEP=2 CM_CONFIG="$ROOT/six.yaml" run "$S" --no-candidates; EL=$((SECONDS - S0))
check "six hosts that each take 2 s are read in parallel: well under the 12 s a sequential loop needs, all six counted" '[ "$EL" -lt 9 ] && grep -q "^capacity: 0 of 6 hosts over cap (target 0)\$" <<<"$OUT"' "elapsed=$EL $OUT"
S0=$SECONDS; STUB_SLEEP=8 CM_CAPACITY_BUDGET=3 CM_CONFIG="$ROOT/six.yaml" run "$S" --no-candidates; EL=$((SECONDS - S0))
check "a host that outlives the time budget is 'not checked: time budget' (CHECK INCOMPLETE, never silent, never within cap), the run ends near the budget" '[ "$EL" -lt 7 ] && grep -q "CHECK INCOMPLETE" <<<"$OUT" && grep -q "not checked: time budget" <<<"$OUT"' "elapsed=$EL $OUT"
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub"; fi
check "the capacity reads are background jobs joined by wait, not a sequential loop" 'grep -q "read_host \"\$n\" \"\$host\" &" "$SKILL/scripts/capacity-check.sh"'

# ---- mutants on a scratch copy: each guard broken must fail a case ----
hostlist local box9
putt box9 "$(term z-1 $W/dev-z1 '"claude"')"
putt local \
  "$(term t-merged $W/dev-merged '"claude"')" "$(term t-lane $W/pr-sweeper '"claude"')" "$(term t-cm $W/concertmaster '"claude"')" \
  "$(term t-openpr $W/dev-openpr '"claude"')" "$(term t-beads $W/dev-beads '"claude"')" "$(term t-shell $W/dev-merged null)" \
  "$(term t-shell-stray $W/stray-shell null)"
putc \
  "$(item local done-merged $W/dev-merged '[]' MERGED)" "$(item local done-merged $W/pr-sweeper '[]' MERGED)" "$(item local done-merged $W/concertmaster '[]' MERGED)" \
  "$(item local done-selfreported $W/dev-openpr '["pr:#9:OPEN"]' OPEN)" "$(item local done-merged $W/dev-beads '["beads-epic:E-1"]' MERGED)"
printf '{"workers":{}}\n' > "$CM_HOME/ledger.json"
cat > "$ROOT/mut.config.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
lanes:
  - { name: pr-sweeper, standing: true }
hosts:
  per_host:
    local: { maxWorkers: 4 }
    box9:  { maxWorkers: 1 }
CFG
export CM_CONFIG="$ROOT/mut.config.yaml"
mkdir -p "$ROOT/mut/scripts" && cp "$SKILL"/scripts/lib.sh "$SKILL"/scripts/capacity-check.sh "$SKILL"/scripts/jdupkeys "$ROOT/mut/scripts/"
M="$ROOT/mut/scripts/capacity-check.sh"
run "$S" --classified "$CLS"
WANT="$OUT"
check "baseline for the mutants: 5 agents over cap 4 lists t-merged (pr-merged) and the shell, nothing protected, box9 at its cap is ok" '[ "$(grep -c "^  CANDIDATE " <<<"$OUT")" = 2 ] && grep -q "t-merged pr-merged" <<<"$OUT" && grep -q "t-shell bare-shell" <<<"$OUT" && [ "$RC" = 1 ]' "rc=$RC $OUT"
mutant() { # <label> <perl substitution that breaks one guard>
  cp "$SKILL/scripts/capacity-check.sh" "$M"; perl -0pi -e "$2" "$M"
  if cmp -s "$SKILL/scripts/capacity-check.sh" "$M"; then fail "mutant $1" "the edit changed nothing"; return; fi
  run "$M" --classified "$CLS"
  if [ "$OUT" = "$WANT" ]; then fail "mutant $1" "the mutated script still gave the right answer"; else pass "mutant $1 is caught"; fi
}
mutant "open-work guard removed" 's/\(\$it \| open_flag\) or \(\$it \| pr_open\)/false/g'
mutant "beads-store note removed" 's/\),\n    \(if \(\(\.candidates \/\/ \[\]\) \| length\) > 0 then "  NOTE[^\n]*else empty end\)\x27/)\x27/'
mutant "open-PR guard removed" 's/ or \(\$it \| pr_open\)//g; s/\(\$it \| pr_open\)/false/g'
mutant "standing-lane name guard removed" 's/or any\(\$lanes\[\]; \. == \$n\) or \(\$n \| test\(\$shape\)\) or any\(\$stand\[\]; \. == \$p\)//'
mutant "concertmaster guard removed" 's/\(\$n == \$self\) or \(\$selfpath != "" and \$p == \$selfpath\)/false/'
mutant "over comparison off by one" 's/over: \(\$n > \$h\.cap\)/over: (\$n >= \$h.cap)/'
mutant "unmatched bare shell listed again" 's/if \$it == null then empty\n                 elif \(\$it \| open_flag\)/if \$it == null then {handle: \$r.handle, reason: "bare-shell", name: (\$p | base), path: \$p}\n                 elif (\$it | open_flag)/'
mutant "bare shells counted as agents" 's/\[ \$t\[\] \| select\(\.host == \$h\.host and \.agent\) \]/[ \$t[] | select(.host == \$h.host) ]/'

# mutants of the argument-size and incomplete handling: each must change the answer on the padded fixtures
printf '{"hosts":{"box4":{"maxWorkers":5}},"workers":{},"pad":"%s"}\n' "$PAD" > "$CM_HOME/ledger.json"
hostlist local
putt local "$(term g-1 $W/dev-g1 '"claude"')" "$(term g-2 $W/dev-g2 '"claude"')" "$(term g-3 $W/dev-g3 '"claude"')" "$(term g-4 $W/dev-g4 '"claude"')"
mutant_big() { # <label> <perl> <expected-line-or-pattern that the GOOD script prints> <config> <classified-file>
  cp "$SKILL/scripts/capacity-check.sh" "$M"; perl -0pi -e "$2" "$M"
  if cmp -s "$SKILL/scripts/capacity-check.sh" "$M"; then fail "mutant $1" "the edit changed nothing"; return; fi
  CM_CONFIG="$4" run "$M" --classified "$5"
  if grep -qE -- "$3" <<<"$OUT"; then fail "mutant $1" "the mutated script still gave the right answer"; else pass "mutant $1 is caught"; fi
}
CFG3="$ROOT/mut.config.yaml"; sed -i 's/maxWorkers: 4/maxWorkers: 3/' "$CFG3"
mutant_big "ledger passed as one argument" 's/--slurpfile L "\$LFILE"/--argjson L "\$(cat "\$LFILE")"/; s/\$L\[0\]\.hosts/\$L.hosts/' '^  HOST local claude=4 cap=3 OVER by 1$' "$CFG3" "$CLSBIG"
mutant_big "a failed cap lookup falls back to the default cap" 's/\x27\x27\|\*\[!0-9\]\*\) printf [^\n]*cap lookup failed[^\n]*return 0 ;;/\x27\x27|*[!0-9]*) cap=2 ;;/' 'CHECK INCOMPLETE: local: cap lookup failed' "$ROOT/capbad.yaml" "$CLSBIG"
hostlist local
putt local "$(term g-1 $W/dev-g1 '"claude"')" "$(term g-2 $W/dev-g2 '"claude"')"
mutant_big "classification passed as one argument" 's/--slurpfile clsf "\$CFILE"/--argjson clsx "\$(cat "\$CFILE")"/; s/\(\$clsf\[0\]\) as \$cls/(\$clsx) as \$cls/' 'CANDIDATE local g-1 pr-merged dev-g1' "$ROOT/cap1.yaml" "$CLSBIG"
putc "$(jq -cn --arg p "$W/dev-g1" '{host: "local", class: "done-merged", path: $p, flags: "oops", pr: null}')"
mutant_big "a failed candidate pass is not reported" 's/printf \x27%s\\t%s\\n\x27 "\(candidates\)".*?>> "\$TMP\/bad\.tsv"/:/s' 'CHECK INCOMPLETE: \(candidates\)' "$ROOT/cap1.yaml" "$CLS"

# host identity and budget mutants
hostlist host-a host-b; mk29 host-a a; mk29 host-b b
mutant_big "same-machine warning removed" 's/select\(\$x\.count > 0 and \$x\.count == \$y\.count\)/select(false)/' 'ONE machine' "$ROOT/same.yaml" "$CLS"
cat > "$ROOT/nocap.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", self_name: concertmaster }
CFG
hostlist box4; putt box4 "$(term d-1 $W/dev-d1 '"claude"')" "$(term d-2 $W/dev-d2 '"claude"')" "$(term d-3 $W/dev-d3 '"claude"')"
mutant_big "no-cap host falls back to a guessed cap of 2" 's/    none\) printf [^\n]*return 0 ;;/    none) cap=2 ;;/' 'no cap configured for this host name' "$ROOT/nocap.yaml" "$CLS"
mutant_big "defaults-cap warning removed" 's/printf \x27%s\\t%s\\n\x27 "\$host" "no hosts\.per_host\.\$host entry[^\n]*warn\.tsv"/:/' 'no hosts.per_host.box4 entry' "$ROOT/mut.config.yaml" "$CLS"

# the parallel read and the budget cut, each removed: the slow-host cases must then fail
hostlist h1 h2 h3 h4 h5 h6; for h in h1 h2 h3 h4 h5 h6; do putt $h "$(term "$h-1" "$W/dev-$h-1" '"claude"')"; done
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub-slow"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub-slow"; fi
cp "$SKILL/scripts/capacity-check.sh" "$M"; perl -0pi -e 's/read_host "\$n" "\$host" & JOBS\+=\("\$!"\)/read_host "\$n" "\$host"/' "$M"
if cmp -s "$SKILL/scripts/capacity-check.sh" "$M"; then fail "mutant sequential reads" "the edit changed nothing"; else
  S0=$SECONDS; STUB_SLEEP=2 CM_CONFIG="$ROOT/six.yaml" run "$M" --no-candidates; EL=$((SECONDS - S0))
  if [ "$EL" -ge 9 ]; then pass "mutant sequential host reads is caught (6 x 2 s took ${EL}s)"; else fail "mutant sequential reads" "still fast: ${EL}s"; fi
fi
cp "$SKILL/scripts/capacity-check.sh" "$M"; perl -0pi -e 's/ht="\$HT"; \[ "\$left" -ge "\$ht" \] \|\| ht="\$left"; /ht="\$HT"; /' "$M"
if cmp -s "$SKILL/scripts/capacity-check.sh" "$M"; then fail "mutant budget cut" "the edit changed nothing"; else
  S0=$SECONDS; STUB_SLEEP=6 CM_CAPACITY_BUDGET=2 CM_CONFIG="$ROOT/six.yaml" run "$M" --no-candidates; EL=$((SECONDS - S0))
  if [ "$EL" -ge 6 ]; then pass "mutant budget cut removed is caught (waited ${EL}s past a 2 s budget)"; else fail "mutant budget cut" "still bounded: ${EL}s"; fi
fi
if [ "$CM_CLI_KIND" = plugly ]; then export PLUGLY_CLI_COMMAND="$ROOT/bin/fleet-stub"; else export ORCA_CLI_COMMAND="$ROOT/bin/fleet-stub"; fi

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
