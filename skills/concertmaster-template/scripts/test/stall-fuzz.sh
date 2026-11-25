#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# stall-fuzz.sh (test): one wrong-typed value never lets a protected lane or PR ladder. The base fixture is MAXIMAL
# (scripts/test/stall-base.sh): every field stall.sh reads, on every kind of row of every input, is present (an inert one as
# an explicit null), and lanes, PRs and asks are built so that each protective field is the one thing holding something:
# 23 protected lanes, 11 protected PRs, six ledger asks, five workers; a second base adds a merge freeze. The
# baseline is run first: only the free lane, three standing or orphaned lanes and the free PR ladder.
# The mutation targets come from scripts/test/fixtures/stall-fields.tsv, the inventory of every field the program reads
# (scripts/test/field-reads.sh checks the inventory against the compiled program and the base): for EVERY path of every
# input document that matches a line of the inventory (each leaf, container and list or map member, an inert null included,
# and the document root), that one value is replaced by each of a text, a number, true, false, {} and [] that is not a legal
# type of the field, one mutation per run, and scripts/stall.sh --json runs on it (a union-typed member keeps its legal types:
# a PR label as text or as an object, an author, a ledger ask askedAt or pr as a number or text). A class A field (a wrong
# type there decides whether something is held) must exit 3 with a gap that names the path, every lane, PR and ask unverified
# and no ladder row; a class G field (the document gate) must give a STALE-INPUT line; a class B field (display or time only)
# and a document root must either exit 3 as above or leave every protected lane and PR off the ladder (exit 0 or 4 with
# every ladder row already laddering in its base). Anything else fails.
# Cost: mutations of class A (and, separately, of class B) that cannot interact are RUN TOGETHER (up to CM_FUZZ_GROUP=6 at a time,
# paths that are neither equal nor nested): a class A group passes when it exits 3 with no ladder row and a gap for EVERY member, a
# class B group when it exits 0 or 4 with no new ladder row; otherwise each member of it is run alone, with the single-mutation
# criteria, so a hole is never hidden by another member. CM_FUZZ_GROUP=1 runs every mutation alone. The DEFAULT is a slice: every
# concrete path of the inventory is mutated ONCE, with a wrong value picked from the path (so every kind of wrong value is used and
# every field of every row is hit at least once); CM_FUZZ_FULL=1 runs every wrong value at every path (about five times as many
# mutations). The count of mutations, of runs and the runtime print at the end. gh, orca, plugly and ssh are stubs that fail loudly;
# stall.sh reads files only. Synthetic names only.
# CM_STALL_SCRIPT=<path> runs another copy of stall.sh (the revert check: a copy with one guard removed must fail here);
# CM_FUZZ_ONLY=<regex> keeps only the mutations whose "<base> <doc> <path> <value>" line matches.
#
#   scripts/test/stall-fuzz.sh     # exit 0 when every case passes (CM_FUZZ_JOBS=n sets the parallel runs, default 8)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${CM_STALL_SCRIPT:-$HERE/../stall.sh}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-stall-fuzz.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_EXTRA_REPOS CM_EXTRA_ORCA_REPOS CM_NEVER_TOUCH CM_TZ CM_TZ_LABEL

mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/jobs"
CALLS="$ROOT/cli-calls.log"; : > "$CALLS"
for t in orca plugly gh ssh; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 99\n' "$t" "$CALLS" > "$ROOT/bin/$t"; chmod +x "$ROOT/bin/$t"
done
export HOME="$ROOT/home" PATH="$ROOT/bin:$PATH" ORCA_CLI_COMMAND="$ROOT/bin/orca" PLUGLY_CLI_COMMAND="$ROOT/bin/plugly"
sed -e 's/^  timezone_label: UTC$/&\n  tick_delays_s: { busy: 600, running: 1200, quiet: 1800 }\n  stall_rungs_min: [30, 60, 90]/' \
    -e 's/^  self_name: concertmaster$/&\n  never_touch: [nt-lane]/' \
    "$HERE/fixtures/config.test.yaml" > "$ROOT/config.yaml"
printf 'messaging:\n  collaborators:\n    - { name: Pat, github: pat-collab }\n' >> "$ROOT/config.yaml"
# the delegated release and deploy classes (config drive.delegated_classes): none by default, so the fixture lists the usual ones
cat >> "$ROOT/config.yaml" <<'EOF2'
drive:
  delegated_classes:
    - 'native (release|build|app release)'
    - 'store submission'
    - 'store build'
    - 'ota (release|bundle|update)'
    - 'over[ -]?the[ -]?air'
    - '(daily |production )?deploy window'
EOF2
export CM_CONFIG="$ROOT/config.yaml"

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }

T0="2026-11-16T12:00:00Z"
ago() { jq -nr --arg t "$T0" --argjson m "$1" '$t | fromdateiso8601 - ($m * 60) | todate'; }
export CM_NOW="$T0"
SINCE="$(ago 2)"
# shellcheck source=SCRIPTDIR/stall-base.sh
. "$HERE/stall-base.sh"

runone() { # runone <dir>: stall.sh --json on <dir>: "<exit> <laddered rows: kind:name@host, sorted, comma joined, - for none> g<gaps> u<unverified> <ok|stale|none>"
  # ok is a JSON report, stale a STALE-INPUT line, none neither; the report is kept in <dir>/out.json
  local d="$1" out rc info
  out="$(CM_HOME="$d/cm" timeout 120 bash "$SCRIPT" --classify "$d/cls.json" --discover "$d/disc.json" --asks "$d/asks.json" \
         --ledger "$d/led.json" --since "$SINCE" --json 2>/dev/null)"; rc=$?
  printf '%s' "$out" > "$d/out.json"
  if info="$(printf '%s' "$out" | jq -r '[([.rows[] | "\(.kind):\(.name)@\(.host // "-")"] | sort | join(",") | if . == "" then "-" else . end), "g\(.gaps | length)", "u\(.unverified)", "ok"] | join(" ")' 2>/dev/null)" && [ -n "$info" ]; then
    printf '%s %s\n' "$rc" "$info"
  elif printf '%s' "$out" | grep -q '^STALE-INPUT'; then printf '%s - g0 u0 stale\n' "$rc"
  else printf '%s - g0 u0 none\n' "$rc"; fi
}

mkbase "$ROOT/base-open" 'null'
mkbase "$ROOT/base-frozen" "$(jq -nc --arg t "$(ago -600)" '{state: "on", window: "w1", ttl: $t}')"
B1="$(runone "$ROOT/base-open")"; B2="$(runone "$ROOT/base-frozen")"
check "base: only the free lane, the standing and orphaned lanes with work and the free PR ladder (exit 4, one unverified host)" "$B1" \
  "4 lane:dev-sweeper@local,lane:l-free@local,lane:l-orph@local,lane:l-sq2@local,lane:l-sq@local,pr:#13@-,pr:acme-learning#16@- g0 u4 ok"
check "base under a freeze: the same lanes ladder, every PR is held (exit 4)" "$B2" \
  "4 lane:dev-sweeper@local,lane:l-free@local,lane:l-orph@local,lane:l-sq2@local,lane:l-sq@local g0 u4 ok"
EXEMPT="$(CM_HOME="$ROOT/base-open/cm" bash "$SCRIPT" --classify "$ROOT/base-open/cls.json" --discover "$ROOT/base-open/disc.json" \
  --asks "$ROOT/base-open/asks.json" --ledger "$ROOT/base-open/led.json" --since "$SINCE" --json 2>/dev/null \
  | jq -r '[.exempt[] | select(.kind != "ask") | "\(.name):\(.code)"] | sort | join(" ")')"
check "base: each protection holds its lane or PR" "$EXEMPT" \
  "#11:lane #12:label #14:lane #15:human #17:ask #18:human #19:label #20:lane #21:lane #22:ask l-ask:ask l-asleep:asleep l-bo:owner l-cb:ask l-child:child l-del:ask l-dm:class l-dsr:class l-main:class l-nc:ask l-off:unverified l-other:class l-own:ask l-park:parked l-self:self l-stand:idle l-trunc:unverified l-unr:unverified l-unread:unverified l-wait:owner l-wid:parked l-wk:ask nt-lane:class"

# ---- the mutations ---------------------------------------------------------------------------------------------------
# one mutation per line of jobs.ndjson: {base, doc, p: path, v: value, cls, needle, label}. The targets are the paths of the base
# that match a line of the inventory (scripts/test/fixtures/stall-fields.tsv), plus the root of each document; the freeze
# base mutates only the freeze. A value of a legal type of the field (null always) is no mutation.
jq -R -n '[inputs | select(length > 0 and (startswith("#") | not)) | split("\t") | {doc: .[0], pat: (.[1] | split(".")), types: (.[2] | split(",")), cls: .[3]}]' \
  < "$HERE/fixtures/stall-fields.tsv" > "$ROOT/inventory.json"
cat > "$ROOT/gen.jq" <<'G'
def lbl: {cls: "classify", disc: "discover", asks: "asks", led: "ledger"}[$doc];
def gp: reduce .[] as $s (""; if ($s | type) == "number" then . + "[\($s)]" else . + "." + $s end);
def pmatch($pat; $p): ($p | length) == ($pat | length) and all(range(0; $p | length); . as $i | $pat[$i] == "*" or $pat[$i] == ($p[$i] | tostring));
# the default slice: ONE wrong value per path, chosen by the path (so every kind of wrong value is used, and every path is hit
# at least once); CM_FUZZ_FULL=1 tries every wrong value at every path
def pick($ok; $p): if ($ok | length) == 0 then empty elif $full == 1 then $ok[] else $ok[(($p | tojson | explode | add) % ($ok | length))] end;
($inv[0] | map(select(.doc == $doc))) as $ents
| ["\"s\"", "7", "true", "false", "{}", "[]"] as $vals
| ( (paths | select(length > 0)) as $p
    | ($ents | map(select(pmatch(.pat; $p))) | first) as $e
    | select($e != null and ($b != "base-frozen" or $p[0] == "freeze"))
    # a freeze whose state is wrong is reported on the freeze itself
    | (if $doc == "led" and $p == ["freeze", "state"] then ["freeze"] else $p end) as $np
    | pick([$vals[] | . as $v | select((($e.types + ["null"]) | index($v | fromjson | type)) == null)]; $p)
    | . as $v
    | {base: $b, doc: $doc, p: $p, v: $v, cls: $e.cls, needle: "\(lbl): \($np | gp) is not ", label: "\($b) \($doc) \($p | tojson) \($v)"} ),
  ( select($b != "base-frozen") | $vals[] | . as $v | select(($v | fromjson | type) != "object")
    | {base: $b, doc: $doc, p: [], v: $v, cls: "R", needle: "", label: "\($b) \($doc) [] \($v)"} )
G
FULL=0; [ "${CM_FUZZ_FULL:-0}" = 1 ] && FULL=1
: > "$ROOT/jobs.ndjson"
for base in base-open base-frozen; do
  for doc in cls disc asks led; do
    [ "$base" = base-frozen ] && [ "$doc" != led ] && continue
    jq -c --arg b "$base" --arg doc "$doc" --argjson full "$FULL" --slurpfile inv "$ROOT/inventory.json" -f "$ROOT/gen.jq" "$ROOT/$base/$doc.json" >> "$ROOT/jobs.ndjson"
  done
done
# CM_FUZZ_ONLY=<extended regex over "<base> <doc> <path> <value>"> keeps only the matching mutations (a quick look at one input,
# or the revert check of one guard); the whole set runs when it is unset
if [ -n "${CM_FUZZ_ONLY:-}" ]; then
  jq -c --arg re "$CM_FUZZ_ONLY" 'select(.label | test($re))' "$ROOT/jobs.ndjson" > "$ROOT/jobs.sel" || : > "$ROOT/jobs.sel"
  mv -f "$ROOT/jobs.sel" "$ROOT/jobs.ndjson"
fi
NMUT="$(wc -l < "$ROOT/jobs.ndjson" | tr -d ' ')"
# the runs: class A mutations that cannot interact share a run (up to CM_FUZZ_GROUP, default 6: the report names at most 8 gaps);
# every other mutation is a run of its own. A line of runs.ndjson is {base, doc, members: [mutation...]}
GSIZE="${CM_FUZZ_GROUP:-6}"
jq -c -s --argjson gs "$GSIZE" '
  def pre($a; $b): ($a | length) <= ($b | length) and ($b[0:($a | length)] == $a);
  [ .[] | select(.cls != "A" and .cls != "B") | {base, doc, members: [.]} ] as $solo
  | ( reduce (.[] | select(.cls == "A" or .cls == "B")) as $j ({groups: []};
        (first(range(0; .groups | length) as $i
               | select(.groups[$i].base == $j.base and .groups[$i].doc == $j.doc and .groups[$i].members[0].cls == $j.cls and (.groups[$i].members | length) < $gs
                        and all(.groups[$i].members[]; (pre(.p; $j.p) or pre($j.p; .p)) | not)) | $i) // null) as $i
        | if $i == null then .groups += [{base: $j.base, doc: $j.doc, members: [$j]}] else .groups[$i].members += [$j] end) | .groups ) as $grp
  | ($grp + $solo)[]' "$ROOT/jobs.ndjson" > "$ROOT/runs.ndjson"
NRUNS="$(wc -l < "$ROOT/runs.ndjson" | tr -d ' ')"
cat > "$ROOT/one.sh" <<'S'
#!/usr/bin/env bash
set -uo pipefail
n="$1"; line="$(sed -n "${n}p" "$ROOT/runs.ndjson")"
base="$(jq -r .base <<<"$line")"; doc="$(jq -r .doc <<<"$line")"
case "$base" in base-open) allowed="$(cut -d' ' -f2 <<<"$B1")" ;; *) allowed="$(cut -d' ' -f2 <<<"$B2")" ;; esac
# try <dir-suffix> <members json>: apply the members to the base, run stall.sh, print "" when the criteria hold, else why.
try() {
  local sfx="$1" ms="$2" d res rc rows gaps unver verdict why="" cls m needle
  d="$ROOT/jobs/$n.$sfx"; cp -R "$ROOT/$base" "$d"; rm -rf -- "${d:?}/cm"; mkdir -p "$d/cm"
  jq --argjson ms "$ms" 'reduce $ms[] as $m (.; setpath($m.p; ($m.v | fromjson)))' "$ROOT/$base/$doc.json" > "$d/$doc.json"
  res="$(runone "$d")"; read -r rc rows gaps unver verdict <<<"$res"
  cls="$(jq -r '.[0].cls' <<<"$ms")"
  if [ "$cls" = A ]; then
    # class A: exit 3, a report, no ladder row, something unverified, and a gap that names every member
    if [ "$rc" != 3 ]; then why="exit $rc, not 3"
    elif [ "$verdict" != ok ]; then why="exit 3 but no report ($verdict)"
    elif [ "$rows" != "-" ]; then why="exit 3 but it laddered $rows"
    elif [ "$unver" = u0 ]; then why="exit 3 with nothing marked unverified"
    else
      while IFS= read -r needle; do
        jq -e --arg x "$needle" 'any(.gaps[]; contains($x))' "$d/out.json" >/dev/null 2>&1 || why="${why}no gap names '$needle' "
      done < <(jq -r '.[].needle' <<<"$ms")
    fi
  elif [ "$cls" = G ]; then
    [ "$rc" = 3 ] && [ "$verdict" = stale ] || why="a gate value: exit $rc ($verdict), want a STALE-INPUT line (exit 3)"
  else
    # class B and a document root: either a named refusal, or nothing that was protected starts to ladder
    case "$rc" in
      3) if [ "$(jq length <<<"$ms")" -gt 1 ]; then why="exit 3 in a group of display or time values (run alone)"
         elif [ "$verdict" = stale ]; then :
         elif [ "$rows" != "-" ]; then why="exit 3 but it laddered $rows"
         elif [ "$gaps" = g0 ]; then why="exit 3 with no named gap"
         elif [ "$unver" = u0 ]; then why="exit 3 with nothing marked unverified"; fi ;;
      0|4) if [ "$verdict" != ok ]; then why="exit $rc and no report"
           elif [ "$rows" != "-" ]; then
             for r in ${rows//,/ }; do case ",$allowed," in *",$r,"*) ;; *) why="${why}starts to ladder: $r " ;; esac; done
           fi ;;
      *) why="exit $rc" ;;
    esac
  fi
  rm -rf -- "${d:?}"
  printf '%s' "$why"
}
members="$(jq -c .members <<<"$line")"
why="$(try g "$members")"
if [ -n "$why" ] && [ "$(jq length <<<"$members")" -gt 1 ]; then
  # a group that did not pass whole: run every member alone, so the verdict is that member's own
  i=0
  while IFS= read -r m; do
    i=$((i + 1)); w="$(try "m$i" "[$m]")"
    [ -n "$w" ] && printf 'BAD %s: %s\n' "$(jq -r .label <<<"$m")" "$w"
  done < <(jq -c '.[]' <<<"$members")
  printf 'RERUN %s\n' "$n"
elif [ -n "$why" ]; then
  printf 'BAD %s: %s\n' "$(jq -r '.[0].label' <<<"$members")" "$why"
fi
exit 0
S
chmod +x "$ROOT/one.sh"
export ROOT SCRIPT SINCE B1 B2 CM_NOW
export -f runone
T0S="$(date +%s)"
seq 1 "$NRUNS" | xargs -P "${CM_FUZZ_JOBS:-8}" -n 1 "$ROOT/one.sh" > "$ROOT/fuzz.out" 2>&1
T1S="$(date +%s)"
BAD="$(grep -c '^BAD ' "$ROOT/fuzz.out" | tr -d ' ')"
check "fuzz: $NMUT single wrong-typed values in $NRUNS runs, none lets a protected lane or PR ladder, every exit 3 names its gap" "$BAD" "0"
[ "$BAD" = 0 ] || grep '^BAD ' "$ROOT/fuzz.out" | head -n 40
check "fuzz: every run finished (no run lost to a crash or a timeout)" "$(grep -vc '^BAD \|^RERUN ' "$ROOT/fuzz.out" | tr -d ' ')" "0"
if [ -z "${CM_FUZZ_ONLY:-}" ]; then
  # every line of the inventory (every field of every row kind of every input) got at least one mutation, in the slice as in the full run
  UNHIT="$(jq -r -s --slurpfile inv "$ROOT/inventory.json" '
    def pmatch($pat; $p): ($p | length) == ($pat | length) and all(range(0; $p | length); . as $i | $pat[$i] == "*" or $pat[$i] == ($p[$i] | tostring));
    . as $jobs | $inv[0][] | select(.cls != "R") | . as $e
    | select(($jobs | any(.doc == $e.doc and (.p | length) > 0 and pmatch($e.pat; .p))) | not) | "\(.doc) \(.pat | join("."))"' "$ROOT/jobs.ndjson" | tr '\n' ';')"
  check "fuzz: every inventory field was mutated at least once" "${UNHIT:-none}" "none"
  [ "$FULL" = 1 ] && check "fuzz: the full job list covers every input (over 2000 mutations)" "$([ "$NMUT" -gt 2000 ] && echo yes || echo "no: $NMUT")" "yes"
fi
check "fuzz: orca, plugly, gh and ssh were never called" "$(wc -l < "$CALLS" | tr -d ' ')" "0"

printf 'stall-fuzz: %s mutations in %s runs, %s run alone after a group did not pass whole, %ss (%s parallel)\n' "$NMUT" "$NRUNS" "$(grep -c '^RERUN ' "$ROOT/fuzz.out" | tr -d ' ')" "$((T1S - T0S))" "${CM_FUZZ_JOBS:-8}"
printf 'stall-fuzz: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
