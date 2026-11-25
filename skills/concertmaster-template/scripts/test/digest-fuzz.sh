#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# digest-fuzz.sh (test): digest.sh reads the ledger, the gh answers (merged and open PRs, deploy runs and their jobs)
# and the worktree comments of the fleet CLI, and parses every one of them itself. One value of the wrong shape must
# never crash it: for every path in a rich fixture of each input, the value there is replaced by null, a number, a
# string and a container of the other kind (an empty list for an object, else an empty object), and every top-level
# field is also deleted, one mutation per run (each root also gets every wrong type). Every run must either
# build the digest (exit 0, the header line, no jq error text) or fail closed with exactly one clear line on stderr
# and nothing on stdout (exit 1, "no digest built"). Only the ledger root that is not an object may fail closed: any
# other single mutation drops a row or a field and the digest is still built, except a whole ledger value of the wrong
# type (asks, followUps, workers, deployWindows, health, health.attention, health.summary, hostEvents, hosts, queue, queue.items),
# which must print "unreadable (ledger .<name> is not ...)", never a quiet none. Then
# the fixture itself must still list
# every section it feeds, so the fuzz never passes on a fixture that reads nothing.
# gh and the fleet CLI are PATH stubs answering from files: no network, no real CLI, no send. Synthetic names only.
#
# The fixture is the MAXIMAL base of scripts/test/digest-base.sh. The default run is a SLICE (every path mutated once, with a wrong
# value picked from the path); CM_FUZZ_FULL=1 tries every wrong value at every path, CM_FUZZ_ONLY=<regex over "<doc> <path> <value>">
# keeps the matching mutations only. Every path that scripts/test/fixtures/digest-fields.tsv lists as class A must print an
# "unreadable (ledger ..." note when it holds a value of a type the inventory does not allow (null stays legal).
#
#   scripts/test/digest-fuzz.sh     # exit 0 when every case passes (CM_FUZZ_JOBS=n sets the parallel runs, default 8)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../digest.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-digest-fuzz.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
BASE="$ROOT/base"
mkdir -p "$ROOT/bin" "$BASE/cm" "$BASE/home" "$ROOT/jobs"
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT CM_DIGEST_GH_TIMEOUT CM_TZ CM_TZ_LABEL CM_NEVER_TOUCH CM_ORCA_REPO CM_PATH_MATCH CM_SELF_WORKTREE CM_EXTRA_REPOS
{ cat "$HERE/fixtures/config.test.yaml"; printf 'digest:\n  deploy_workflow: Release Deploy\n  deploy_job: Ship to Prod\n'; } > "$ROOT/config.yaml"
# the delegated release and deploy classes: none by default, so the config lists the usual ones
cat >> "$ROOT/config.yaml" <<'EOF2'
drive:
  delegated_classes:
    - 'native (release|build|app release)'
    - 'store submission'
    - 'store build'
    - 'app ?listing'
    - 'play ?listing'
    - 'listing console'
    - 'ota (release|bundle|update)'
    - 'over[ -]?the[ -]?air'
    - '(daily |production )?deploy window'
    - 'feature switch[ -]?on( (of|for) (the )?(chat widget|beta banner))?'
    - '(turn(ed|ing)?|switch(ed|ing)?) on (the )?(chat widget|beta banner)'
    - '(chat widget|beta banner) (flag|global flip)'
    - 'beta go[ .-]?live'
EOF2
export CM_CONFIG="$ROOT/config.yaml" PATH="$ROOT/bin:$PATH"

# gh stub: pr list answers from $STUB_DIR/<state>.json, run list from runs.json, run view <id> from run-<id>.json.
cat > "$ROOT/bin/gh" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") state=""; while [ $# -gt 0 ]; do case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac; done
             cat "$STUB_DIR/$state.json" ;;
  "run list") cat "$STUB_DIR/runs.json" ;;
  "run view") cat "$STUB_DIR/run-$3.json" ;;
esac
exit 0
S
# Fleet CLI stub: one local host, its worktrees from $STUB_DIR/wt.json.
cat > "$ROOT/bin/orca" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") printf '%s' '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}]}}' ;;
  "worktree list") cat "$STUB_DIR/wt.json" ;;
esac
S
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca"
export ORCA_CLI_COMMAND="$ROOT/bin/orca" PLUGLY_CLI_COMMAND="$ROOT/bin/orca"

ago() { jq -nr --argjson h "$1" 'now - $h * 3600 | floor | todate'; }
. "$HERE/digest-base.sh"
mkdigestbase "$BASE"
A1="$(ago 1)"

PASS=0; FAIL=0
has() { case "$2" in *"$3"*) PASS=$((PASS + 1)); printf 'PASS %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s: "%s" not in:\n%s\n' "$1" "$3" "$2" ;; esac; }
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }

# run_in <dir> [args]: digest.sh over the inputs in <dir>, stdout to <dir>/out, stderr to <dir>/err, the exit code printed
run_in() {
  local d="$1"; shift
  HOME="$d/home" CM_HOME="$d/cm" STUB_DIR="$d" CM_SELF_WORKTREE=concertmaster "$SCRIPT" "$@" > "$d/out" 2> "$d/err"
  echo $?
}

# 0. the fixture reads every input: each section it feeds is listed --------------------------------------------------
RC="$(run_in "$BASE" --full)"; OUT="$(cat "$BASE/out")"
check "fixture: exit 0" "$RC" "0"
for want in "Priorities (1)" "- 1. ship the roster" "ask a-merge | answer: merge #12 past the red e2e?" "- lane-blk on local | cm:blocked:" \
            "- lane-z club roster | which club first?" "Merged (2)" "Deployed (1)" "- v1.2.3 at" "STOPPED dw-2: smoke red" \
            "Open PRs (2)" "Lanes (" "Waiting on Owner" "Waiting on Reviewer" "- restarts in the window: 1 reboot(s)" "- lane-s on host-a: stuck, no output" \
            "Open follow-ups (1)" "pr #77 on host-a (rung 3): merged 77 first" "Decided while you were away (verdict-agent) (1)" "Stuck (1)" \
            "Forbidden agents on Acme work" "Supabase stacks without a worktree" "offline: host-b" "Next: #41"; do
  has "fixture lists: $want" "$OUT" "$want"
done
RC="$(run_in "$BASE")"
check "fixture group text: exit 0" "$RC" "0"
has "fixture group text: the tooling line" "$(cat "$BASE/out")" "Tooling: 1 concertmaster PRs merged, 1 open"

# 1. single mutations over every path of every input -----------------------------------------------------------------
# One job per line: <doc file> <TAB> <path as JSON> <TAB> <value as JSON, or "delete">. A value of the same type as
# the one it replaces is skipped (it is no mutation of the type).
# The DEFAULT is a slice: every path of every input is mutated ONCE, with a wrong value picked from the path (so every kind of wrong
# value is used and every field is hit at least once; never a null, and of a type the inventory does not allow where it lists the path), plus the deletion of every top-level field; CM_FUZZ_FULL=1 tries null, a
# number, a text and the other container at every path. CM_FUZZ_ONLY=<extended regex over "<doc> <path> <value>"> keeps only the
# matching mutations.
jq -R -s 'split("\n") | map(select(length > 0 and (startswith("#") | not)) | split("\t")) | map(select(.[2] == "A") | {pat: (.[0] | split(".")), types: (.[1] | split(","))})' \
  "$HERE/fixtures/digest-fields.tsv" > "$ROOT/digest-a.json"
FULL=0; [ "${CM_FUZZ_FULL:-0}" = 1 ] && FULL=1
: > "$ROOT/jobs.tsv"
for doc in cm/ledger.json merged.json open.json runs.json run-901.json wt.json; do
  jq -r --arg doc "$doc" --argjson full "$FULL" --slurpfile inv "$ROOT/digest-a.json" '
    def pmatch($pat; $p): ($p | length) == ($pat | length) and all(range(0; $p | length); . as $i | $pat[$i] == "*" or $pat[$i] == ($p[$i] | tostring));
    . as $d | [paths] | .[] | . as $p | ($d | getpath($p) | type) as $t
    | ([null, 7, "s", (if $t == "object" then [] else {} end)] | map(select(type != $t))) as $vs
    # slice: one wrong value, never null, of a type the inventory does not allow at that path when it lists one
    | (if $doc == "cm/ledger.json" then ([$inv[0][] | select(pmatch(.pat; $p))] | first | .types) else null end) as $legal
    | ((($vs | map(. as $v | select($v != null and ($legal == null or (($legal | index($v | type)) == null))))) as $c
       | (if ($c | length) > 0 then $c else ($vs | map(select(. != null))) end) as $pool
       | if $full == 1 then $vs[] elif ($pool | length) > 0 then $pool[(($p | tojson | explode | add) % ($pool | length))] else empty end)
    | [$doc, ($p | tojson), tojson]),
      (if ($p | length) == 1 then [$doc, ($p | tojson), "delete"] else empty end)
    | @tsv' "$BASE/$doc" >> "$ROOT/jobs.tsv"
  for v in null 7 '"s"' '[]' '{}' true; do printf '%s\t%s\t%s\n' "$doc" '[]' "$v" >> "$ROOT/jobs.tsv"; done
done
if [ -n "${CM_FUZZ_ONLY:-}" ]; then
  awk -F'\t' -v re="$CM_FUZZ_ONLY" '($1 " " $2 " " $3) ~ re' "$ROOT/jobs.tsv" > "$ROOT/jobs.sel" || : > "$ROOT/jobs.sel"
  mv -f "$ROOT/jobs.sel" "$ROOT/jobs.tsv"
fi
NJOBS="$(wc -l < "$ROOT/jobs.tsv" | tr -d ' ')"

# one mutation: copy the fixture, apply it, run --full (and the group text on every other job), judge the outcome
cat > "$ROOT/one.sh" <<'S'
#!/usr/bin/env bash
set -uo pipefail
n="$1"; line="$(sed -n "${n}p" "$ROOT/jobs.tsv")"
doc="${line%%$'\t'*}"; rest="${line#*$'\t'}"; p="${rest%%$'\t'*}"; v="${rest#*$'\t'}"
d="$ROOT/jobs/$n"; cp -R "$BASE" "$d"
if [ "$v" = delete ]; then f='delpaths([$p])'; else f='setpath($p; $v)'; fi
if [ "$v" = delete ]; then jq --argjson p "$p" "$f" "$BASE/$doc" > "$d/$doc"; else jq --argjson p "$p" --argjson v "$v" "$f" "$BASE/$doc" > "$d/$doc"; fi
modes="--full"; [ $((n % 4)) -eq 0 ] && modes="--full group"
for m in $modes; do
  if [ "$m" = group ]; then set --; else set -- --full; fi
  HOME="$d/home" CM_HOME="$d/cm" STUB_DIR="$d" CM_SELF_WORKTREE=concertmaster "$SCRIPT" "$@" > "$d/out" 2> "$d/err"; rc=$?
  why=""
  if [ "$rc" -eq 0 ]; then
    head -n 1 "$d/out" | grep -q 'concertmaster digest, ' || why="exit 0 but no header line"
    grep -q 'jq: error' "$d/out" "$d/err" && why="exit 0 with jq error text"
  elif [ "$rc" -eq 1 ]; then
    if [ -s "$d/out" ] || [ "$(wc -l < "$d/err" | tr -d ' ')" != 1 ] || ! grep -q 'no digest built' "$d/err"; then why="exit 1 but not one clear line"
    elif [ "$doc" != cm/ledger.json ] || [ "$p" != '[]' ]; then why="failed closed on a single field (only a ledger root that is not an object may)"; fi
  else
    why="exit $rc (a crash)"
  fi
  # a whole list of the wrong type (null is absent, an empty list) is named as unreadable in --full
  if [ -z "$why" ] && [ "$rc" -eq 0 ] && [ "$m" = --full ] && [ "$doc" = cm/ledger.json ] && [ "$v" != null ] && [ "$v" != delete ]; then
    case "$p" in
      '["asks"]'|'["followUps"]'|'["workers"]'|'["deployWindows"]'|'["health"]'|'["health","attention"]'|'["health","summary"]'|'["hostEvents"]'|'["hosts"]'|'["queue"]'|'["queue","items"]')
        k="$(jq -r 'join(".")' <<<"$p")"
        grep -qF "unreadable (ledger .$k is not" "$d/out" || why="a whole .$k of the wrong type printed no unreadable line" ;;
    esac
  fi
  # every ledger path the inventory (fixtures/digest-fields.tsv) lists as class A: a value of a type it does not allow is named
  # as unreadable, never counted, listed or dropped quietly
  if [ -z "$why" ] && [ "$rc" -eq 0 ] && [ "$m" = --full ] && [ "$doc" = cm/ledger.json ] && [ "$v" != null ] && [ "$v" != delete ]; then
    vt="$(jq -r type <<<"$v")"
    # jq -e: 0 = the path is class A and the type is not allowed, 1 = not that, anything else = the check itself failed. A jq error must
    # never read as "not class A" (the old form indexed .pat on the loop number, errored on every run and skipped the assertion)
    jq -e --argjson p "$p" --arg vt "$vt" 'any(.[]; . as $r | ($r.pat | length) == ($p | length)
          and ([range(0; $p | length)] | all(. as $i | $r.pat[$i] == "*" or $r.pat[$i] == ($p[$i] | tostring))) and (($r.types | index($vt)) == null))' "$ROOT/digest-a.json" >/dev/null 2>"$d/jqerr"
    crc=$?
    if [ "$crc" -eq 0 ]; then
      grep -qF 'unreadable (ledger .' "$d/out" || why="class A path $(jq -r 'map(tostring) | join(".")' <<<"$p") with a $vt printed no unreadable note"
    elif [ "$crc" -ne 1 ]; then
      why="the class A check itself failed (jq rc $crc): $(head -c 120 "$d/jqerr" | tr '\n' ' ')"
    fi
  fi
  [ -n "$why" ] && printf 'BAD %s %s %s %s [%s]: %s | %s\n' "$n" "$doc" "$p" "$v" "${m}" "$why" "$(head -c 200 "$d/err" | tr '\n' ' ')"
done
rm -rf -- "$d"
exit 0
S
chmod +x "$ROOT/one.sh"
export ROOT BASE SCRIPT
T0="$(date +%s)"
seq 1 "$NJOBS" | xargs -P "${CM_FUZZ_JOBS:-8}" -n 1 "$ROOT/one.sh" > "$ROOT/fuzz.out" 2>&1
T1="$(date +%s)"
BAD="$(grep -c '^BAD ' "$ROOT/fuzz.out" | tr -d ' ')"
check "fuzz: $NJOBS single mutations, none crashes, none fails closed on one field ($((T1 - T0))s)" "$BAD" "0"
[ "$BAD" = 0 ] || grep '^BAD ' "$ROOT/fuzz.out" | head -n 40
[ -n "${CM_FUZZ_ONLY:-}" ] || check "fuzz: every path of every input got its mutations (no job lost)" \
  "$([ "$NJOBS" -gt "$([ "$FULL" = 1 ] && echo 800 || echo 250)" ] && echo yes || echo "no: $NJOBS")" "yes"
# the designed exit: a ledger root that is not an object fails closed with the one line
for v in '[]' '7' 'null'; do
  mkdir -p "$ROOT/root"; cp -R "$BASE/." "$ROOT/root/"; printf '%s' "$v" > "$ROOT/root/cm/ledger.json"
  RC="$(run_in "$ROOT/root" --full)"
  check "a ledger root of $v fails closed: exit 1, no stdout" "$RC:$(wc -c < "$ROOT/root/out" | tr -d ' ')" "1:0"
  has "with the one clear line" "$(cat "$ROOT/root/err")" "is not a JSON object: no digest built"
done

# 2. digest.sh writes no state: a second run over the same inputs prints the same report ----------------------------
find "$BASE/cm" -type f | LC_ALL=C sort > "$ROOT/files.before"
run_in "$BASE" --full > /dev/null; sed 1d "$BASE/out" > "$ROOT/first"
run_in "$BASE" --full > /dev/null; sed 1d "$BASE/out" > "$ROOT/second"
find "$BASE/cm" -type f | LC_ALL=C sort > "$ROOT/files.after"
check "no state file is written in the state dir" "$(diff "$ROOT/files.before" "$ROOT/files.after" >/dev/null && echo same)" "same"
check "a second run prints the same report (no seen-file hides a row)" "$(diff "$ROOT/first" "$ROOT/second" >/dev/null && echo same)" "same"

# 3. a long ask is cut before it is cleaned: a 200000 character question costs the same as a short one -------------
# Every other character is a control character: cleaning the whole string first (one gsub over 100000 matches) takes
# minutes in jq 1.7, cutting first takes milliseconds. The question goes in through a file: 200000 characters on argv
# is over the kernel limit for one argument.
yes "$(printf 'a\001')" | tr -d '\n' | head -c 200000 > "$ROOT/lq.txt"
jq --rawfile q "$ROOT/lq.txt" '.asks[0].question = $q | .workers["w-bo"].blockedQuestion = $q | .followUps[0].text = $q | .decisions[0].text = $q' \
  "$BASE/cm/ledger.json" > "$BASE/cm/l.t" && mv "$BASE/cm/l.t" "$BASE/cm/ledger.json"
T0="$(date +%s)"; RC="$(run_in "$BASE" --full)"; T1="$(date +%s)"
check "a 200000 character question: the fixture holds it (the check is not vacuous)" "$(jq '.asks[0].question | length' "$BASE/cm/ledger.json")" "200000"
check "a 200000 character question: exit 0" "$RC" "0"
check "and the digest is built in under 20s ($((T1 - T0))s)" "$([ $((T1 - T0)) -lt 20 ] && echo fast || echo slow)" "fast"
check "and its row is cut to 160 characters" "$(grep -c '^- lane-x #12: ask a-merge | answer: ' "$BASE/out")" "1"

# 4. targeted shapes: what a wrong type turns into, not only that it does not crash ------------------------------------
fresh() { rm -rf -- "$ROOT/t"; mkdir -p "$ROOT/t"; cp -R "$BASE/." "$ROOT/t/"; jq "$1" "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; }
cp "$BASE/cm/ledger.json" "$ROOT/b.json"
jq '.asks[0].question = "merge #12?" | .workers["w-bo"].blockedQuestion = "which club first?" | .followUps[0].text = "check the card" | .decisions[0].text = "merged 77 first"' \
  "$ROOT/b.json" > "$ROOT/b.t" && mv "$ROOT/b.t" "$ROOT/b.json"
# a newline in any printed field never starts a report line of its own
fresh '.followUps[0].owner = "lead-a\n- FORGED owner line" | .workers["w-st"].task = "stuck one\n- FORGED stuck line"
       | .deployWindows[1].blockedReason = "smoke\nFORGED stopped line" | .queue.items[0].lane = "lane-q\u2028- FORGED next line"
       | .hosts["FORGED\nhost"] = {reachable: false}'
RC="$(run_in "$ROOT/t" --full)"; OUT="$(cat "$ROOT/t/out")"
check "newlines in fields: exit 0" "$RC" "0"
check "newlines in fields: no line starts with a forged text" "$(grep -c '^\(- \)\?FORGED' "$ROOT/t/out")" "0"
has "newlines in fields: the text is kept on its own line" "$OUT" "owner lead-a - FORGED owner line,"
check "newlines in fields: no line separator character is printed" "$(LC_ALL=C grep -c "$(printf '\342\200\250')" "$ROOT/t/out")" "0"
# an unreadable census record says incomplete, never a quiet none
fresh '.violationCheck = "garbled" | .violations = []'
has "a violationCheck that is not an object: CHECK INCOMPLETE" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "CHECK INCOMPLETE, not proof of none: ledger violationCheck is unreadable"
fresh '.violations = "garbled" | del(.violationCheck)'
has "violations that are not a list: CHECK INCOMPLETE" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "CHECK INCOMPLETE, not proof of none: ledger violations is unreadable"
fresh '.supabaseStacks = 7'
has "a supabaseStacks that is not an object: CHECK INCOMPLETE" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "CHECK INCOMPLETE, not proof of none: ledger supabaseStacks is unreadable"
fresh '.supabaseStacks = {orphans: "x", complete: true}'
has "a supabaseStacks orphans that is not a list: CHECK INCOMPLETE though it says complete" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "supabaseStacks.orphans is unreadable"
fresh 'del(.supabaseStacks)'
has "no supabaseStacks at all: CHECK NOT RUN" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "CHECK NOT RUN: the ledger has no supabaseStacks"
fresh '.supabaseStacks = {}'
has "an empty supabaseStacks: still CHECK NOT RUN" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "CHECK NOT RUN: the ledger has no supabaseStacks"
# an owner ask with a non-text lane is named as such, never as the concertmaster
fresh '.asks[0].lane = {"x": 1}'
B="$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Blocked on you/,/^$/p' "$ROOT/t/out")"
has "an ask with a non-text lane is the owner's, labelled invalid lane" "$B" "- (invalid lane) #12: ask a-merge |"
fresh '.asks[0].worker = 7 | del(.asks[0].lane)'
has "an ask with a non-text worker is labelled invalid worker" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "- (invalid worker) #12: ask a-merge |"
# a queue priority that is not text is named, never read as normal
fresh '.queue.items[0].priority = 3'
has "a queue priority that is not text says so" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "lane-q (invalid priority)"
# a gh deploy run whose jobs or status are wrong-typed is never a proven deploy
printf '%s' '{"jobs": "garbled"}' > "$ROOT/t/run-901.json"; fresh '.'
printf '%s' '{"jobs": "garbled"}' > "$ROOT/t/run-901.json"
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
has "deploy jobs that are not a list: the run is not a proven deploy" "$OUT" "- v1.2.3 at"
has "and the ledger row says gh did not prove it" "$OUT" "(ledger says done, gh: no prod deploy job succeeded)"
has "and the deploy job drift is named" "$OUT" "check digest.deploy_job"
jq '.[0].status = 7' "$BASE/runs.json" > "$ROOT/t/runs.json"; cp "$BASE/run-901.json" "$ROOT/t/run-901.json"
has "a run status that is not text: the prod job still proves the deploy, no crash" "$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")" "Deployed (1)"

# a whole ledger list of the wrong type is unreadable in every section that reads it, never none; null stays none
fresh '.asks = {"x": {id: "m1", kind: "merge", state: "open", question: "merge it?", askedAt: "'"$A1"'"}} | .followUps = "corrupt"
       | .workers = [{lane: "lane-z", task: "club roster", state: "blocked-on-owner", blockedQuestion: "which club first?"}]'
RC="$(run_in "$ROOT/t" --full)"; OUT="$(cat "$ROOT/t/out")"
check "wrong-typed lists: exit 0" "$RC" "0"
for sec in "Blocked on you" "Needs Owner" "Waiting on Owner"; do
  S1="$(printf '%s\n' "$OUT" | sed -n "/^$sec (/,/^\$/p")"
  has "wrong-typed lists: $sec names .asks unreadable" "$S1" "- unreadable (ledger .asks is not a list)"
  has "wrong-typed lists: $sec names .workers unreadable" "$S1" "- unreadable (ledger .workers is not an object)"
  check "wrong-typed lists: $sec never says none" "$(printf '%s\n' "$S1" | grep -c '^- none')" "0"
done
S1="$(printf '%s\n' "$OUT" | sed -n '/^Open follow-ups (/,/^$/p')"
has "wrong-typed lists: Open follow-ups names .followUps unreadable" "$S1" "- unreadable (ledger .followUps is not a list)"
check "wrong-typed lists: Open follow-ups never says none" "$(printf '%s\n' "$S1" | grep -c '^- none')" "0"
RC="$(run_in "$ROOT/t")"
has "wrong-typed lists: the group text Waiting on Owner names it too" "$(sed -n '/^Waiting on Owner (/,/^$/p' "$ROOT/t/out")" "- unreadable (ledger .asks is not a list)"
fresh '.asks = null | .followUps = null | .workers = null'
RC="$(run_in "$ROOT/t" --full)"; OUT="$(cat "$ROOT/t/out")"
check "null lists: no unreadable line (null is an empty list)" "$(printf '%s\n' "$OUT" | grep -c 'unreadable (ledger')" "0"
has "null lists: Open follow-ups says none" "$(printf '%s\n' "$OUT" | sed -n '/^Open follow-ups (/,/^$/p')" "- none"

# every other whole value a section reads: a STOPPED window, a restart, an attention row, an offline host and a queued
# item never vanish because their list has the wrong type; the note goes where they print, and stderr says so once
fresh '.deployWindows = "corrupt" | .health.attention = {"a": 1} | .hostEvents = {"e": 1} | .hosts = ["host-b"] | .queue.items = "corrupt"'
RC="$(run_in "$ROOT/t" --full)"; OUT="$(cat "$ROOT/t/out")"
check "wrong-typed values: exit 0, the rest of the report is built" "$RC" "0"
S1="$(printf '%s\n' "$OUT" | sed -n '/^Deployed/,/^$/p')"
has "wrong-typed values: Deployed names .deployWindows unreadable" "$S1" "- unreadable (ledger .deployWindows is not a list)"
check "wrong-typed values: Deployed never says none" "$(printf '%s\n' "$S1" | grep -c '^- none')" "0"
S1="$(printf '%s\n' "$OUT" | sed -n '/^Fleet health/,/^$/p')"
has "wrong-typed values: Fleet health names .health.attention unreadable" "$S1" "- unreadable (ledger .health.attention is not a list)"
has "wrong-typed values: Fleet health names .hostEvents unreadable" "$S1" "- unreadable (ledger .hostEvents is not a list)"
has "wrong-typed values: the footer names .hosts unreadable" "$OUT" "- unreadable (ledger .hosts is not an object)"
has "wrong-typed values: Next names .queue.items unreadable" "$OUT" "Next: unreadable (ledger .queue.items is not a list)"
has "wrong-typed values: stderr says the report is partial" "$(cat "$ROOT/t/err")" "named as unreadable in the report"
fresh '.health = "corrupt" | .queue = 7'
OUT="$(run_in "$ROOT/t" >/dev/null; cat "$ROOT/t/out")"
has "wrong-typed values: the group text names .health unreadable" "$OUT" "- unreadable (ledger .health is not an object)"
has "wrong-typed values: the group text names .queue unreadable" "$OUT" "Next: unreadable (ledger .queue is not an object)"
fresh '.deployWindows = null | .hostEvents = null | .hosts = null | .queue = null | .health = null'
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
check "null values: no unreadable line" "$(printf '%s\n' "$OUT" | grep -c 'unreadable (ledger')" "0"
check "null values: nothing on stderr" "$(wc -c < "$ROOT/t/err" | tr -d ' ')" "0"

# a MEMBER of the wrong type is named the same way as a whole value, never dropped: a list member that is not an object,
# a map value that is not an object, and a field the report reads that is not of its type (a state that is not text, a
# reachable that is not true or false). Each is named in the section that would have printed the row
fresh '.deployWindows += [7] | .asks += [7] | .followUps += [7] | .hosts["host-c"] = 7 | .workers["w-z"] = []
       | .hostEvents += [7] | .health.attention += [7] | .queue.items += [7]'
RC="$(run_in "$ROOT/t" --full)"; OUT="$(cat "$ROOT/t/out")"
check "wrong-typed members: exit 0, the rest of the report is built" "$RC" "0"
has "member: Deployed names .deployWindows[2]" "$(printf '%s\n' "$OUT" | sed -n '/^Deployed/,/^$/p')" "- unreadable (ledger .deployWindows[2] is not an object)"
for sec in "Blocked on you" "Needs Owner" "Waiting on Owner"; do
  S1="$(printf '%s\n' "$OUT" | sed -n "/^$sec (/,/^\$/p")"
  has "member: $sec names .asks[4]" "$S1" "- unreadable (ledger .asks[4] is not an object)"
  has "member: $sec names .workers.w-z" "$S1" "- unreadable (ledger .workers.w-z is not an object)"
done
has "member: Open follow-ups names .followUps[1]" "$(printf '%s\n' "$OUT" | sed -n '/^Open follow-ups (/,/^$/p')" "- unreadable (ledger .followUps[1] is not an object)"
S1="$(printf '%s\n' "$OUT" | sed -n '/^Fleet health/,/^$/p')"
has "member: Fleet health names .hostEvents[1]" "$S1" "- unreadable (ledger .hostEvents[1] is not an object)"
has "member: Fleet health names .health.attention[1]" "$S1" "- unreadable (ledger .health.attention[1] is not an object)"
has "member: the footer names .hosts.host-c" "$OUT" "- unreadable (ledger .hosts.host-c is not an object)"
has "member: Next names .queue.items[1]" "$OUT" "Next: unreadable (ledger .queue.items[1] is not an object)"
has "member: stderr says the report is partial" "$(cat "$ROOT/t/err")" "named as unreadable in the report"
fresh '.hosts["host-b"] = false | .hosts["host-d"] = {reachable: "false"} | .asks[0].state = 7 | .workers["w-bo"].state = {}
       | .deployWindows[1].state = ["stopped"] | .queue.items[0].state = true | .hostEvents[0].kind = 7'
RC="$(run_in "$ROOT/t" --full)"; OUT="$(cat "$ROOT/t/out")"
check "wrong-typed fields: exit 0" "$RC" "0"
has "field: hosts.host-b as false is not an object" "$OUT" "- unreadable (ledger .hosts.host-b is not an object)"
has "field: hosts.host-d reachable as text is named, the offline host is not silently dropped" "$OUT" "- unreadable (ledger .hosts.host-d.reachable is not true or false)"
has "field: asks[0].state as a number" "$(printf '%s\n' "$OUT" | sed -n '/^Blocked on you (/,/^$/p')" "- unreadable (ledger .asks[0].state is not text)"
has "field: workers.w-bo.state as an object" "$(printf '%s\n' "$OUT" | sed -n '/^Blocked on you (/,/^$/p')" "- unreadable (ledger .workers.w-bo.state is not text)"
has "field: deployWindows[1].state as a list (a STOPPED window cannot vanish)" "$(printf '%s\n' "$OUT" | sed -n '/^Deployed/,/^$/p')" "- unreadable (ledger .deployWindows[1].state is not text)"
has "field: queue.items[0].state as true" "$OUT" "Next: unreadable (ledger .queue.items[0].state is not text)"
has "field: hostEvents[0].kind as a number" "$(printf '%s\n' "$OUT" | sed -n '/^Fleet health/,/^$/p')" "- unreadable (ledger .hostEvents[0].kind is not text)"
# B4 C4: a NULL member of a list or a map is named like any other non-object member (it used to vanish), and a state that is no known
# state at all is named (a typo, "mystery", an empty or blank text), never read as "not that state"
fresh '.asks += [null] | .followUps += [null] | .workers["w-n"] = null | .hosts["host-n"] = null | .hostEvents += [null] | .queue.items += [null]'
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
has "B4 C4 a null ask is named" "$(printf '%s\n' "$OUT" | sed -n '/^Blocked on you (/,/^$/p')" "- unreadable (ledger .asks[4] is not an object)"
has "B4 C4 a null worker is named" "$(printf '%s\n' "$OUT" | sed -n '/^Blocked on you (/,/^$/p')" "- unreadable (ledger .workers.w-n is not an object)"
has "B4 C4 a null follow-up is named" "$(printf '%s\n' "$OUT" | sed -n '/^Open follow-ups (/,/^$/p')" "- unreadable (ledger .followUps[1] is not an object)"
has "B4 C4 a null host is named" "$OUT" "- unreadable (ledger .hosts.host-n is not an object)"
has "B4 C4 a null host event is named" "$(printf '%s\n' "$OUT" | sed -n '/^Fleet health/,/^$/p')" "- unreadable (ledger .hostEvents[1] is not an object)"
has "B4 C4 a null queue item is named" "$OUT" "Next: unreadable (ledger .queue.items[1] is not an object)"
for st in mystery '' ' '; do
  fresh ".asks[0].state = \"$st\" | .workers[\"w-bo\"].state = \"$st\""
  OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
  has "B4 C4 ask state '$st' is not a known state: named" "$(printf '%s\n' "$OUT" | sed -n '/^Blocked on you (/,/^$/p')" "- unreadable (ledger .asks[0].state is not a known state"
  has "B4 C4 worker state '$st' is not a known state: named" "$(printf '%s\n' "$OUT" | sed -n '/^Blocked on you (/,/^$/p')" "- unreadable (ledger .workers.w-bo.state is not a known state"
done
# B4 O4: a health record that was checked (checkedAt set) but has no summary at all, absent or null, must not print "0 running, 0 idle, ..."
for hs in 'del(.health.summary)' '.health.summary = null'; do
  fresh "$hs"
  OUT="$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Fleet health/,/^$/p' "$ROOT/t/out")"
  has "B4 O4 ($hs): named, a counter is never read as 0" "$OUT" "- unreadable (ledger .health.summary is missing: a counter is never read as 0)"
  check "B4 O4 ($hs): no zero counts are printed for it" "$(printf '%s\n' "$OUT" | grep -c '0 running, 0 idle')" "0"
done
fresh 'del(.health.summary) | del(.health.checkedAt)'
OUT="$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Fleet health/,/^$/p' "$ROOT/t/out")"
has "B4 O4 control: no summary and never checked is 'not checked yet', no unreadable line" "$OUT" "not checked yet"
check "B4 O4 control: no unreadable summary line" "$(printf '%s\n' "$OUT" | grep -c 'summary is missing')" "0"
# more rows than five are counted, not all listed
fresh '.asks = [range(0; 9) | 7]'
has "member: nine bad asks print five and a count" "$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Blocked on you (/,/^$/p' "$ROOT/t/out")" "- and 4 more unreadable ledger rows"
# health: a summary or checkedAt of the wrong type is named, never zero counts or "not checked yet"
fresh '.health.summary = "corrupt"'
OUT="$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Fleet health/,/^$/p' "$ROOT/t/out")"
has "health.summary as text is named unreadable" "$OUT" "- unreadable (ledger .health.summary is not an object)"
check "and no zero counts are printed for it" "$(printf '%s\n' "$OUT" | grep -c '0 running, 0 idle')" "0"
fresh '.health.checkedAt = {"x": 1}'
OUT="$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Fleet health/,/^$/p' "$ROOT/t/out")"
has "health.checkedAt of the wrong type is named unreadable" "$OUT" "- unreadable (ledger .health.checkedAt is not text)"
check "and is not read as never checked" "$(printf '%s\n' "$OUT" | grep -c 'not checked yet')" "0"
fresh '.violations = [7] | .supabaseStacks.orphans = [7]'
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
has "a violations row that is not an object: CHECK INCOMPLETE, the gap named" "$OUT" "CHECK INCOMPLETE, not proof of none: "
has "a violations row that is not an object: the gap says violations" "$OUT" "ledger violations is unreadable"
has "a supabaseStacks orphans row that is not an object: CHECK INCOMPLETE" "$OUT" "supabaseStacks.orphans has a row that is not an object"
# the Deployed section when gh failed still names an unreadable deployWindows, and with gh fine and nothing else to
# print it never says none over it
fresh '.deployWindows = 7'
printf '%s' '{}' > "$ROOT/t/runs.json"
OUT="$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Deployed/,/^$/p' "$ROOT/t/out")"
has "gh failed: Deployed says unknown" "$OUT" "Deployed: unknown (gh failed)"
has "gh failed: Deployed still names .deployWindows unreadable" "$OUT" "- unreadable (ledger .deployWindows is not a list)"
fresh '.deployWindows = 7'
jq '[]' "$BASE/runs.json" > "$ROOT/t/runs.json"
OUT="$(run_in "$ROOT/t" --full >/dev/null; sed -n '/^Deployed/,/^$/p' "$ROOT/t/out")"
has "gh fine, nothing deployed: Deployed names .deployWindows unreadable" "$OUT" "- unreadable (ledger .deployWindows is not a list)"
check "and never says none over it" "$(printf '%s\n' "$OUT" | grep -c '^- none')" "0"

# a worktree list that is not a list is a host not read, never a host with no lanes; one bad row costs only itself
fresh '.'
jq '.result.worktrees = "garbled"' "$BASE/wt.json" > "$ROOT/t/wt.json"
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
has "a worktree list that is not a list: the host is listed as not read" "$OUT" "- host not read: local ("
has "and Blocked on you counts it, never none" "$OUT" "Blocked on you (3, 1 host not read, see Fleet health)"
jq '.result.worktrees[1] = "garbled"' "$BASE/wt.json" > "$ROOT/t/wt.json"
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
has "a worktree row that is not an object: the other rows are still read" "$OUT" "- lane-blk on local | cm:blocked: which table holds the backfill?"
check "and the host counts as read" "$(printf '%s\n' "$OUT" | grep -c 'host not read')" "0"

# a gh PR repo that is not text is never the main repo: named as invalid, never in the main-repo review list
fresh '.'
jq '.[1].repo = false | .[1].isDraft = false | .[1].reviewDecision = ""' "$BASE/open.json" > "$ROOT/t/open.json"
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
has "an open PR whose repo is false is named as an invalid repo" "$OUT" "- (invalid repo)#22 notes [open]"
check "and it is not in the review list of the main repo" "$(printf '%s\n' "$OUT" | grep -c 'still need review or approval: #21$')" "1"

# 5. the in-shell gate in front of the line withhold lets every secret shape through to the full check -------------
rep() { printf "%${2}s" '' | tr ' ' "$1"; }
SECRETS=("-----BEGIN RSA PRIV""ATE KEY-----" "gh""p_$(rep Q 36)" "sk-""ant-$(rep R 30)" "wh""sec_$(rep W 30)" "AK""IA$(rep Z 16)"
         "ey""J$(rep h 20).ey""J$(rep p 24).$(rep s 24)" "Bea""rer ab12.cd34.ef56.gh78.ij90" "pass""word=Hun""ter$(rep 9 3)!"
         "PASS""PHRASE is Swor""dfish$(rep 4 3)" "x$(rep M 20)$(rep 7 20)y")
printf '%s\n' "${SECRETS[@]}" | jq -R -s --arg a1 "$A1" \
  '[split("\n")[:-1] | to_entries[] | {id: "s-\(.key)", kind: "merge", state: "open", question: ("use " + .value + " now"), askedAt: $a1}]' > "$ROOT/sa.json"
check "secret shapes: the fixture holds every one" "$(jq length "$ROOT/sa.json")" "${#SECRETS[@]}"
fresh '.'
jq --slurpfile sa "$ROOT/sa.json" '.asks = $sa[0]' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"
RC="$(run_in "$ROOT/t" --full)"
check "secret shapes: exit 0" "$RC" "0"
check "secret shapes: every Blocked ask row is withheld" "$(sed -n '/^Blocked on you/,/^$/p' "$ROOT/t/out" | grep -c '^- \[withheld: looks like a credential\]$')" "${#SECRETS[@]}"
leak=0; for t in "${SECRETS[@]}"; do grep -qF -- "${t:6:12}" "$ROOT/t/out" && leak=$((leak + 1)); done
check "secret shapes: no part of any secret is printed" "$leak" "0"

# 6. a report program that fails half way prints nothing of the report: one line with the first error, the failing
# status. The failure is forced in a copy of the skill dir (the real script is never edited)
mkdir -p "$ROOT/fc"; cp -R "$HERE/../.." "$ROOT/fc/skill"
FCS="$ROOT/fc/skill/scripts/digest.sh"
sed 's/^\( *| \)"Fleet health",$/\1error("forced failure"), "Fleet health",/' "$SCRIPT" > "$FCS"
check "fail closed: the forced failure is in the copy" "$(grep -c 'error("forced failure")' "$FCS")" "1"
fresh '.'
RC="$(HOME="$ROOT/t/home" CM_HOME="$ROOT/t/cm" STUB_DIR="$ROOT/t" bash "$FCS" --full > "$ROOT/t/out" 2> "$ROOT/t/err"; echo $?)"
check "fail closed: a non-zero status" "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "fail closed: nothing of the report on stdout (sections before the failure included)" "$(wc -c < "$ROOT/t/out" | tr -d ' ')" "0"
check "fail closed: exactly one line on stderr" "$(wc -l < "$ROOT/t/err" | tr -d ' ')" "1"
has "fail closed: the line names the first error" "$(cat "$ROOT/t/err")" "no digest built (jq: error"
has "and the error itself" "$(cat "$ROOT/t/err")" "forced failure"

# 6b. round 5: every counter, state and key the report counts or routes by is type-checked ----------------------------------
# Repro map: H4 a health.summary counter that is not a number (running false / "corrupt" / {} / [] printed counts or garbage,
# exit 0 without a note), F the counter whatever its key ({"stuck": false} printed "0 stuck"), G a state that differs from a
# known one only by case or padding, G2 a workers key padded with white space, B a credential-shaped map key, A the ask fields.
# Each group has its controls (the legal value keeps its line and prints no note).
fleet() { sed -n '/^Fleet health/,/^$/p' "$ROOT/t/out"; }
fresh '.'
OUT="$(run_in "$ROOT/t" --full >/dev/null; cat "$ROOT/t/out")"
has "H4 control: the legal counters print" "$(fleet)" "2 running, 1 idle"
check "H4 control: no unreadable note" "$(printf '%s\n' "$OUT" | grep -c 'unreadable (ledger')" "0"
for k in running idle "waiting on you" stuck stopped asleep unknown; do
  for bad in false true '"corrupt"' '{}' '[]'; do
    jq --argjson v "$bad" --arg k "$k" '.health.summary[$k] = $v' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"
    RC="$(run_in "$ROOT/t" --full)"; OUT="$(cat "$ROOT/t/out")"
    has "H4 summary.$k = $bad: named unreadable" "$OUT" "unreadable (ledger .health.summary.$k is not a number)"
    case "$(fleet)" in *"$bad $k"*|*"0 $k"*|*"false $k"*) check "H4 summary.$k = $bad: the line prints no count for it" "printed" "not printed" ;; *) check "H4 summary.$k = $bad: the line prints no count for it" "not printed" "not printed" ;; esac
    check "H4 summary.$k = $bad: exit 0" "$RC" "0"
  done
done
jq '.health.summary = {stuck: false}' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "F summary {stuck: false}: named" "$(cat "$ROOT/t/out")" "unreadable (ledger .health.summary.stuck is not a number)"
check "F summary {stuck: false}: never prints 0 stuck" "$(fleet | grep -c '0 stuck')" "0"
jq '.health.summary = {"some new bucket": "x"}' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "F a counter under a key the report does not print is checked too" "$(cat "$ROOT/t/out")" "unreadable (ledger .health.summary.some new bucket is not a number)"
# AT-C: a summary that is {} or lacks a counter is a damaged record: named, and the counts line is not printed (`// 0` printed "0 stuck")
jq '.health.summary = {}' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
for k in running idle "waiting on you" stuck stopped asleep unknown; do
  has "AT-C summary {}: the missing counter $k is named" "$(cat "$ROOT/t/out")" "unreadable (ledger .health.summary.$k is missing: a counter is never read as 0)"
done
check "AT-C summary {}: no zero counts line" "$(fleet | grep -c '0 running')" "0"
for k in running idle "waiting on you" stuck stopped asleep unknown; do
  jq --arg k "$k" 'del(.health.summary[$k])' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; RC="$(run_in "$ROOT/t" --full)"
  has "AT-C summary without $k: named" "$(cat "$ROOT/t/out")" "unreadable (ledger .health.summary.$k is missing: a counter is never read as 0)"
  check "AT-C summary without $k: the counts line is not printed" "$(fleet | grep -c ' running, ')" "0"
  check "AT-C summary without $k: exit 0" "$RC" "0"
done
fresh '.'; run_in "$ROOT/t" --full >/dev/null
check "AT-C control: the full summary prints its line and no missing note" "$(fleet | grep -c '2 running, 1 idle')$(grep -c 'is missing: a counter' "$ROOT/t/out")" "10"
# G: a near miss of a known state is unreadable, a known one and an unknown one that is no near miss are not
for st in Open OPEN ' open '; do
  jq --arg v "$st" '.asks[0].state = $v' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
  has "G ask state '$st': named a near miss" "$(cat "$ROOT/t/out")" "unreadable (ledger .asks[0].state is a near miss of a known state"
done
for st in answered weird; do
  jq --arg v "$st" '.asks[0].state = $v' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
  check "G control: ask state '$st' is no near miss, no note" "$(grep -c 'near miss' "$ROOT/t/out")" "0"
done
for st in Blocked-On-Owner RUNNING ' parked '; do
  jq --arg v "$st" '.workers["w-bo"].state = $v' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
  has "G worker state '$st': named a near miss" "$(cat "$ROOT/t/out")" "unreadable (ledger .workers.w-bo.state is a near miss of a known state"
done
jq '.workers["w-bo"].state = "parked-by-owner"' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
check "G control: a legacy worker state spelling is known, no note" "$(grep -c 'near miss' "$ROOT/t/out")" "0"
for st in Queued ' granted'; do
  jq --arg v "$st" '.queue.items[0].state = $v' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
  has "G queue item state '$st': named a near miss" "$(cat "$ROOT/t/out")" "unreadable (ledger .queue.items[0].state is a near miss of a known state"
done
jq '.deployWindows[0].state = "Done"' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "G deployWindows state 'Done': named a near miss" "$(cat "$ROOT/t/out")" "unreadable (ledger .deployWindows[0].state is a near miss of a known state"
jq '.followUps[0].state = "OPEN"' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "G followUps state 'OPEN': named a near miss" "$(cat "$ROOT/t/out")" "unreadable (ledger .followUps[0].state is a near miss of a known state"
# every documented ask state (references/ledger.md, iv_ask_states: open answered in-progress decided closed) is legal. A narrower list named a closed or an in-progress ask unreadable.
# A ledger with an extra ask in that state prints what the same ledger prints without it, and no "unreadable" line.
fresh '.'; RCB="$(run_in "$ROOT/t" --full)"; sed 1d "$ROOT/t/out" > "$ROOT/p1-base"
for st in open answered in-progress decided closed; do
  fresh '.'; jq --arg st "$st" '.asks += [{id: "a-p1", kind: "merge", state: $st, lane: "lane-p1", question: "an old question", askedAt: "2026-01-01T00:00:00Z"}]' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"
  RCP="$(run_in "$ROOT/t" --full)"; sed 1d "$ROOT/t/out" > "$ROOT/p1-out"
  check "P1 documented ask state '$st' is legal: no unreadable note about the ask" "$(grep -c 'unreadable (ledger .asks' "$ROOT/t/out")" "0"
  case "$st" in open) ;; *) check "P1 documented ask state '$st': the report equals the ledger without it" "$RCP$(cmp -s "$ROOT/p1-base" "$ROOT/p1-out" && echo same || echo differs)" "${RCB}same" ;; esac
done
# mutant: the narrow list again must name the closed ask unreadable
mkdir -p "$ROOT/mut-ask" && cp "$HERE"/../*.sh "$HERE"/../*.jq "$ROOT/mut-ask/" 2>/dev/null
sed -i 's/^CM_ASK_STATES="open answered in-progress decided closed"$/CM_ASK_STATES="open answered decided"/' "$ROOT/mut-ask/lib.sh"
if ! cmp -s "$HERE/../lib.sh" "$ROOT/mut-ask/lib.sh"; then
  fresh '.'; jq '.asks += [{id: "a-p1", kind: "merge", state: "closed", lane: "lane-p1", question: "an old question", askedAt: "2026-01-01T00:00:00Z"}]' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"
  SAVE_SCRIPT="$SCRIPT"; SCRIPT="$ROOT/mut-ask/digest.sh"; run_in "$ROOT/t" --full >/dev/null; SCRIPT="$SAVE_SCRIPT"
  has "P1 mutant: with the narrow ask list a closed ask is named unreadable again, the case is caught" "$(cat "$ROOT/t/out")" "unreadable (ledger .asks["
else check "P1 mutant: the sed matches lib.sh" "no" "yes"; fi
# G2: a worker id is matched exactly
jq '.workers = {" w-run ": .workers["w-run"]}' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "G2 a workers key padded with spaces: named" "$(cat "$ROOT/t/out")" 'unreadable (ledger .workers[" w-run "] is a worker id with surrounding white space)'
# B: a credential-shaped map key is never echoed: not in stdout, not on stderr
KEY="gh""p_$(rep Q 36)"
for shape in workers hosts; do
  if [ "$shape" = workers ]; then jq --arg k "$KEY" '.workers = {($k): {state: 7, lane: "lane-k"}}' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"
  else jq --arg k "$KEY" '.hosts = {($k): {reachable: "yes"}}' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; fi
  run_in "$ROOT/t" --full >/dev/null; J="$(cat "$ROOT/t/out")$(cat "$ROOT/t/err")"; run_in "$ROOT/t" >/dev/null; J="$J$(cat "$ROOT/t/out")$(cat "$ROOT/t/err")"
  case "$J" in *"${KEY:0:12}"*) check "B a credential-shaped $shape key is in no output (stdout, stderr, group text)" "echoed" "withheld" ;; *) check "B a credential-shaped $shape key is in no output (stdout, stderr, group text)" "withheld" "withheld" ;; esac
  has "B $shape key: the unreadable note is still printed (withheld line)" "$J" "withheld"
done
jq '.workers = {"w-plain": {state: 7, lane: "lane-k"}}' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "B control: a plain worker key is named" "$(cat "$ROOT/t/out")" "unreadable (ledger .workers.w-plain.state is not text)"
# A: the ask fields the owner scan reads
for f in kind scope question topic lane worker path; do
  jq --arg f "$f" '.asks[0][$f] = false' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
  has "A ask $f = false: named" "$(cat "$ROOT/t/out")" "unreadable (ledger .asks[0].$f is not text)"
done
jq '.asks[0].pr = false' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "A ask pr = false: named" "$(cat "$ROOT/t/out")" "unreadable (ledger .asks[0].pr is not a number or text)"
jq '.asks[0].noCode = "true"' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "A ask noCode = text: named" "$(cat "$ROOT/t/out")" "unreadable (ledger .asks[0].noCode is not true or false)"
jq '.asks[0].files = false' "$ROOT/b.json" > "$ROOT/t/cm/ledger.json"; run_in "$ROOT/t" --full >/dev/null
has "A ask files = false: named" "$(cat "$ROOT/t/out")" "unreadable (ledger .asks[0].files is not a list)"

# 7. the fork-free line check of the withhold gives the same answer as the full check, line for line ----------------
# Both functions are read out of digest.sh (it is a script, not a library) next to secret-shape.sh, then run over a
# corpus of every shape the two run rules, the gate and the slow path tell apart, each also inside a report line.
LC="$ROOT/linecheck.sh"
{ printf '. %q\n' "$HERE/../secret-shape.sh"
  sed -n '/^DIGEST_WH=/p; /^line_looks_secret() {/,/^}/p; /^DIGEST_WH_WORDS=/,/^DIGEST_WH_SLOW=/p; /^line_secret_fast() {/,/^}/p' "$SCRIPT"; } > "$LC"
check "line check: both functions were read out of digest.sh" "$(grep -c '^line_looks_secret() {$\|^line_secret_fast() {$' "$LC")" "2"
H40="$(rep a 20)$(rep 9 20)"
CORPUS=("plain words only" "short-kebab-lane" "lane-with-a-very-long-kebab-case-name-for-the-check-and-more" "$(rep x 39)" "$(rep x 40)" "$(rep x 220)"
        "$H40" "$H40 and $H40" "$(rep a 41)" "$(rep A 20)$(rep 9 20)" "$(rep A 20)-$(rep 9 20)" "x$H40" "$(rep a 20)-$(rep 9 20)"
        "$(rep f 39)-$(rep A 3)" "${SECRETS[@]}" "a $(rep F 64) b" "https://user:pa55""word@host.example/x" "-----BEGIN $H40 PRIVATE KEY-----"
        "sign-in failed for Swordf1sh9" "login as admin" "LOGIN admin Hunter99x" "pass""wd: Tr0ub4dor&3" "0.12345678-1234-1234-1234-123456789012.abcdefgh:QUJDREVGR0g="
        "commit $H40 merged" "mixedCaseRun$(rep Q 20)$(rep 3 10)" "$(rep _ 45)" "$(rep - 45)" "a$(rep - 45)b" "xox""b-123 slack" "eyJ$(rep a 12)")
same=0; differ=""
for c in "${CORPUS[@]}"; do
  for line in "$c" "- lane-x #12: ask a-1 | answer: use $c now (merge, open 1h0m)"; do
    full="$(bash -c '. "$1"; line_looks_secret "$2" && echo yes || echo no' _ "$LC" "$line")"
    fast="$(bash -c '. "$1"; line_secret_fast "$2" && echo yes || echo no' _ "$LC" "$line")"
    if [ "$full" = "$fast" ]; then same=$((same + 1)); else differ="$differ [$line: full $full, fast $fast]"; fi
  done
done
check "line check: the fast check agrees with the full one on every corpus line (${same} agree)" "${differ:-none}" "none"
check "line check: the corpus has secret-shaped and plain lines both" \
  "$(for c in "${CORPUS[@]}"; do bash -c '. "$1"; line_looks_secret "$2" && echo yes || echo no' _ "$LC" "$c"; done | sort -u | tr '\n' ' ')" "no yes "

printf 'digest-fuzz: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
