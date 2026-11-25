#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# field-reads.sh (test): the static cross-check of "every field a program reads is type-checked and fuzzed". The jq program of
# scripts/stall.sh, of scripts/digest.sh and the classifier of scripts/ask-timeout.sh is compiled once with `jq --debug-dump-disasm` (the CM_TEST=1 seam CM_TEST_JQ_FLAGS), and
# every field NAME it reads by key (a constant that INDEX or INDEX_OPT consumes: .a, .a.b, $v.a, .["a"]) is listed. Then:
#   stall.sh   every name read must be a field of the inventory scripts/test/fixtures/stall-fields.tsv, or a program-built name on
#              the allowlist scripts/test/fixtures/stall-read-allow.tsv (with its reason); every inventory field must still be read
#              (no stale line); every inventory path must be present in the maximal base (scripts/test/stall-base.sh), so the fuzz
#              reaches it.
#   digest.sh  every name read must be a key of the maximal base (scripts/test/digest-base.sh) or on the allowlist
#              scripts/test/fixtures/digest-read-allow.tsv; every class A path of scripts/test/fixtures/digest-fields.tsv must be
#              present in the base ledger.
# A new field read added to either program without a line in those files fails here: add it to the inventory (and to V_SPEC in
# stall.sh, or the d_row specs in digest.sh, when a wrong type there would hold, exempt, park, relay, route, time or count), or to
# the allowlist with its reason. CM_FIELD_STALL / CM_FIELD_DIGEST=<path> check another copy of a script (the revert check: a copy
# with one extra read must fail).
# ask-timeout.sh  the same name-level check for the classifier of scripts/ask-timeout.sh against scripts/test/fixtures/asktimeout-fields.tsv and
#   asktimeout-read-allow.tsv, with the base scripts/test/ask-timeout-base.sh (CM_FIELD_ASKTIMEOUT=<path> checks another copy).
# What it cannot see: a key built at run time (a map keyed by a lane or worker name, $x[$name]), has("x"), getpath, to_entries on a
# document value, a field read by bash outside jq (the document schema), the precise row kind a name belongs to (it checks the
# NAME, so a name listed for one row kind covers the same name read on another: stall-fuzz and the named rows cover the kind), and
# the gh and fleet CLI answers digest.sh reads (consciously left out, see SKILL.md). The inventory is the audit; this check keeps it
# from going stale.
#
#   scripts/test/field-reads.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STALL="${CM_FIELD_STALL:-$HERE/../stall.sh}"
DIGEST="${CM_FIELD_DIGEST:-$HERE/../digest.sh}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-field-cov.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_EXTRA_REPOS CM_EXTRA_ORCA_REPOS CM_NEVER_TOUCH CM_TZ CM_TZ_LABEL CM_ORCA_REPO CM_PATH_MATCH CM_SELF_WORKTREE

mkdir -p "$ROOT/bin" "$ROOT/home"
for t in orca plugly gh ssh; do printf '#!/bin/sh\nexit 99\n' > "$ROOT/bin/$t"; chmod +x "$ROOT/bin/$t"; done
export HOME="$ROOT/home" PATH="$ROOT/bin:$PATH" ORCA_CLI_COMMAND="$ROOT/bin/orca" PLUGLY_CLI_COMMAND="$ROOT/bin/plugly"
sed -e 's/^  main_repo: acme-app$/&\n  extra_repos: [acme-learning]/' \
    -e 's/^  timezone_label: UTC$/&\n  tick_delays_s: { busy: 600, running: 1200, quiet: 1800 }\n  stall_rungs_min: [30, 60, 90]/' \
    -e 's/^  self_name: concertmaster$/&\n  never_touch: [nt-lane]/' \
    "$HERE/fixtures/config.test.yaml" > "$ROOT/config.yaml"
printf 'messaging:\n  collaborators:\n    - { name: Pat, github: pat-collab }\ndigest:\n  deploy_workflow: Release Deploy\n  deploy_job: Ship to Prod\n' >> "$ROOT/config.yaml"
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
export CM_CONFIG="$ROOT/config.yaml"

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }

T0="2026-11-16T12:00:00Z"
ago() { jq -nr --arg t "$T0" --argjson m "$1" '$t | fromdateiso8601 - ($m * 60) | todate'; }
export CM_NOW="$T0"
SINCE="$(ago 2)"
# shellcheck source=SCRIPTDIR/stall-base.sh
. "$HERE/stall-base.sh"
mkbase "$ROOT/sb" 'null'

# names_of <disasm file>: the sorted field names a compiled jq program reads by key. A constant pushed by PUSHK_UNDER and consumed by
# INDEX or INDEX_OPT is a key; a subexpression opens its own stack of pending constants.
names_of() {
  awk 'BEGIN { d = 0; n[0] = 0 }
    $1 !~ /^[0-9][0-9][0-9][0-9]$/ { next }
    { op = $2 }
    op == "PUSHK_UNDER" { n[d]++; q[d, n[d]] = substr($0, index($0, "\"")); next }
    op == "SUBEXP_BEGIN" { d++; n[d] = 0; next }
    op == "SUBEXP_END" { d--; if (d < 0) d = 0; next }
    op == "INDEX" || op == "INDEX_OPT" { if (n[d] > 0) { print q[d, n[d]]; n[d]-- } ; next }
    op == "LOADV" || op == "LOADVN" || op == "DUP" || op == "POP" || op == "LOADK" { next }
    { n[d] = 0 }' "$1" | grep '^"' | tr -d '"' | sort -u
}

# ---- stall.sh --------------------------------------------------------------------------------------------------------------
d="$ROOT/sb"
CM_TEST=1 CM_TEST_JQ_FLAGS=--debug-dump-disasm CM_HOME="$d/cm" bash "$STALL" --classify "$d/cls.json" --discover "$d/disc.json" \
  --asks "$d/asks.json" --ledger "$d/led.json" --since "$SINCE" --json > "$ROOT/stall.disasm" 2> "$ROOT/stall.err"
check "stall: the test seam dumps the compiled program ($(wc -l < "$ROOT/stall.disasm" | tr -d ' ') lines)" \
  "$([ "$(wc -l < "$ROOT/stall.disasm" | tr -d ' ')" -gt 2000 ] && echo yes || echo "no: $(head -c 200 "$ROOT/stall.err")")" "yes"
names_of "$ROOT/stall.disasm" > "$ROOT/stall.read"
check "stall: the program reads fields by key ($(wc -l < "$ROOT/stall.read" | tr -d ' ') names)" "$([ "$(wc -l < "$ROOT/stall.read" | tr -d ' ')" -gt 40 ] && echo yes || echo no)" "yes"
awk -F'\t' '!/^#/ && NF { n = split($2, a, "."); if (a[n] != "*") print a[n] }' "$HERE/fixtures/stall-fields.tsv" | sort -u > "$ROOT/stall.inv"
awk -F'\t' '!/^#/ && NF { print $1 }' "$HERE/fixtures/stall-read-allow.tsv" | sort -u > "$ROOT/stall.allow"
sort -u "$ROOT/stall.inv" "$ROOT/stall.allow" > "$ROOT/stall.known"
UNKNOWN="$(comm -23 "$ROOT/stall.read" "$ROOT/stall.known" | tr '\n' ' ')"
check "stall: every field the program reads is in the inventory or on the allowlist (a new read needs a line)" "${UNKNOWN:-none}" "none"
# the inventory lines of class G are read by bash (check_doc), the rest must still be read by the program
awk -F'\t' '!/^#/ && NF && $4 != "G" { n = split($2, a, "."); if (a[n] != "*") print a[n] }' "$HERE/fixtures/stall-fields.tsv" | sort -u > "$ROOT/stall.invnog"
STALE="$(comm -13 "$ROOT/stall.read" "$ROOT/stall.invnog" | tr '\n' ' ')"
check "stall: every inventory field is still read by the program (no stale line)" "${STALE:-none}" "none"
STALEALLOW="$(comm -13 "$ROOT/stall.read" "$ROOT/stall.allow" | tr '\n' ' ')"
check "stall: every allowlisted name is still read (no stale allowlist line)" "${STALEALLOW:-none}" "none"
# every inventory path is present in the base document (an explicit null counts: a null in the base is where a wrong type is put)
for doc in cls disc asks led; do
  jq -R -n --arg doc "$doc" '[inputs | select(length > 0 and (startswith("#") | not)) | split("\t") | select(.[0] == $doc) | .[1] | split(".")]' \
    < "$HERE/fixtures/stall-fields.tsv" > "$ROOT/inv.$doc.json"
  MISSING="$(jq -r --slurpfile inv "$ROOT/inv.$doc.json" '
    def pmatch($pat; $p): ($p | length) == ($pat | length) and all(range(0; $p | length); . as $i | $pat[$i] == "*" or $pat[$i] == ($p[$i] | tostring));
    [paths] as $ps
    | $inv[0][] | . as $pat | select(($ps | any(pmatch($pat; .))) | not) | join(".")' "$ROOT/sb/$doc.json" | tr '\n' ' ')"
  check "stall: every $doc inventory path is present in the maximal base" "${MISSING:-none}" "none"
done

# ---- digest.sh -------------------------------------------------------------------------------------------------------------
ago() { jq -nr --argjson h "$1" 'now - $h * 3600 | floor | todate'; }
# shellcheck source=SCRIPTDIR/digest-base.sh
. "$HERE/digest-base.sh"
DB="$ROOT/db"; mkdir -p "$DB/cm" "$DB/home"
mkdigestbase "$DB"
HOME="$DB/home" CM_HOME="$DB/cm" STUB_DIR="$DB" CM_SELF_WORKTREE=concertmaster CM_TEST=1 CM_TEST_JQ_FLAGS=--debug-dump-disasm \
  bash "$DIGEST" --full > "$ROOT/digest.disasm" 2> "$ROOT/digest.err"
check "digest: the test seam dumps the compiled program ($(wc -l < "$ROOT/digest.disasm" | tr -d ' ') lines)" \
  "$([ "$(wc -l < "$ROOT/digest.disasm" | tr -d ' ')" -gt 2000 ] && echo yes || echo "no: $(head -c 200 "$ROOT/digest.err")")" "yes"
names_of "$ROOT/digest.disasm" > "$ROOT/digest.read"
# the keys the maximal base carries anywhere (the ledger, the gh answers and the fleet CLI answer)
for f in cm/ledger.json merged.json open.json runs.json run-901.json wt.json; do jq -r '[.. | objects | keys[]] | unique[]' "$DB/$f"; done | sort -u > "$ROOT/digest.basekeys"
awk -F'\t' '!/^#/ && NF { print $1 }' "$HERE/fixtures/digest-read-allow.tsv" | sort -u > "$ROOT/digest.allow"
sort -u "$ROOT/digest.basekeys" "$ROOT/digest.allow" > "$ROOT/digest.known"
UNKNOWN="$(comm -23 "$ROOT/digest.read" "$ROOT/digest.known" | tr '\n' ' ')"
check "digest: every field the program reads is a key of the maximal base or on the allowlist (a new read needs a line)" "${UNKNOWN:-none}" "none"
STALEALLOW="$(comm -13 "$ROOT/digest.read" "$ROOT/digest.allow" | tr '\n' ' ')"
check "digest: every allowlisted name is still read (no stale allowlist line)" "${STALEALLOW:-none}" "none"
jq -R -n '[inputs | select(length > 0 and (startswith("#") | not)) | split("\t") | select(.[2] == "A") | .[0] | split(".")]' \
  < "$HERE/fixtures/digest-fields.tsv" > "$ROOT/inv.digest.json"
MISSING="$(jq -r --slurpfile inv "$ROOT/inv.digest.json" '
  def pmatch($pat; $p): ($p | length) == ($pat | length) and all(range(0; $p | length); . as $i | $pat[$i] == "*" or $pat[$i] == ($p[$i] | tostring));
  [paths] as $ps
  | $inv[0][] | . as $pat | select(($ps | any(pmatch($pat; .))) | not) | join(".")' "$DB/cm/ledger.json" | tr '\n' ' ')"
check "digest: every class A inventory path is present in the maximal base ledger" "${MISSING:-none}" "none"

# ---- ask-timeout.sh -----------------------------------------------------------------------------------------------------------
# the classifier is one jq program (list mode); the claim and record modes read filesAt, verdictRef and issue in their own small programs
# (the script header), so the inventory is the classifier's reads
# shellcheck source=SCRIPTDIR/ask-timeout-base.sh
. "$HERE/ask-timeout-base.sh"
mkatbase "$ROOT/at.json"
mkdir -p "$ROOT/home/.concertmaster"
CM_HOME="$ROOT/home/.concertmaster" CM_NOW="2026-10-17T19:00:00Z" CM_TEST=1 CM_TEST_JQ_FLAGS=--debug-dump-disasm \
  bash "${CM_FIELD_ASKTIMEOUT:-$HERE/../ask-timeout.sh}" --ledger "$ROOT/at.json" > "$ROOT/at.disasm" 2> "$ROOT/at.err"
check "ask-timeout: the test seam dumps the compiled program ($(wc -l < "$ROOT/at.disasm" | tr -d ' ') lines)" \
  "$([ "$(wc -l < "$ROOT/at.disasm" | tr -d ' ')" -gt 1500 ] && echo yes || echo "no: $(head -c 200 "$ROOT/at.err")")" "yes"
names_of "$ROOT/at.disasm" > "$ROOT/at.read"
awk -F'\t' '!/^#/ && NF { n = split($2, a, "."); if (a[n] != "*") print a[n] }' "$HERE/fixtures/asktimeout-fields.tsv" | sort -u > "$ROOT/at.inv"
awk -F'\t' '!/^#/ && NF { print $1 }' "$HERE/fixtures/asktimeout-read-allow.tsv" | sort -u > "$ROOT/at.allow"
sort -u "$ROOT/at.inv" "$ROOT/at.allow" > "$ROOT/at.known"
UNKNOWN="$(comm -23 "$ROOT/at.read" "$ROOT/at.known" | tr '\n' ' ')"
check "ask-timeout: every field the classifier reads is in the inventory or on the allowlist (a new read needs a line)" "${UNKNOWN:-none}" "none"
STALE="$(comm -13 "$ROOT/at.read" "$ROOT/at.inv" | tr '\n' ' ')"
check "ask-timeout: every inventory field is still read by the classifier (no stale line)" "${STALE:-none}" "none"
STALEALLOW="$(comm -13 "$ROOT/at.read" "$ROOT/at.allow" | tr '\n' ' ')"
check "ask-timeout: every allowlisted name is still read (no stale allowlist line)" "${STALEALLOW:-none}" "none"
jq -R -n '[inputs | select(length > 0 and (startswith("#") | not)) | split("\t") | .[1] | split(".")]' \
  < "$HERE/fixtures/asktimeout-fields.tsv" > "$ROOT/inv.at.json"
MISSING="$(jq -r --slurpfile inv "$ROOT/inv.at.json" '
  def pmatch($pat; $p): ($p | length) == ($pat | length) and all(range(0; $p | length); . as $i | $pat[$i] == "*" or $pat[$i] == ($p[$i] | tostring));
  [paths] as $ps
  | $inv[0][] | . as $pat | select(($ps | any(pmatch($pat; .))) | not) | join(".")' "$ROOT/at.json" | tr '\n' ' ')"
check "ask-timeout: every inventory path is present in the maximal base ledger" "${MISSING:-none}" "none"

# ---- every program that reads the ledger, asks, health or lanes -------------------------------------------------------------
# Found by grep, not by a hand list, in every `*.sh` AND every `*.jq` (a jq file is a program too: scripts/classify.jq and
# scripts/intake.jq hold the ledger reads of classify.sh and intake.sh). The three seam programs above are checked by field name.
# For every other one the protective reads (standing, freeze, a state with a default, issue and project with a default) are checked
# ONE READ AT A TIME: a read is typed when the text right after it pipes it into a typed helper (`.standing | cm_standing_any`,
# `.state | cm_state_dead`, `| type`, `| tojson`) or compares it with the exact boolean (`.standing == true`); a read with a
# default (`.state // "x"`, `.issue // ...`, `.freeze`) is never typed by what else stands on the same line. An untyped read must
# sit on scripts/test/fixtures/protective-read-allow.tsv with a reason, and the literal there must COVER that read (a second untyped
# read on the same line is not excused by the first one's row). A program that reads the ledger and is not on
# scripts/test/fixtures/ledger-readers.tsv fails. CM_FIELD_SCRIPTS=<dir> checks another copy of the scripts (the revert check).
PROT_RE='\.standing\b|\.freeze\b|state *// *"|\.issue *//|\.issueUrl *//|\.project *//'
DISC_RE='ledger\.json|cm_ledger_path|\$LEDGER|--ledger|CM_LEDGER|\.workers\b|\.asks\b|\.health\b|\.lanes\b|\.freeze\b|\.followUps\b|\.deployWindows\b'
# rd_unguarded <program path> <allow file> <program name> <used out>: the line numbers of the untyped, unexcused protective reads, one
# per read (a line with two such reads is named twice); the allow literals that excused a read are appended to <used out>
rd_unguarded() {
  grep -nE "$PROT_RE" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | awk -v prog="$3" -v allowf="$2" -v usedf="$4" '
    BEGIN {
      n = 0
      while ((getline l < allowf) > 0) { split(l, a, "\t"); if (a[1] == prog && a[2] != "") lits[++n] = a[2] }
      close(allowf)
      prot = "\\.standing|\\.freeze|state *// *\"|\\.issue *//|\\.issueUrl *//|\\.project *//"
      typed = "^[ \t]*\\|[ \t]*(cm_standing_|cm_state_|type([^A-Za-z0-9_]|$)|tojson)|^[ \t]*==[ \t]*true([^A-Za-z0-9_]|$)"
    }
    {
      i = index($0, ":"); ln = substr($0, 1, i - 1); text = substr($0, i + 1)
      s = text; off = 0
      while (match(s, prot)) {
        start = off + RSTART; tok = substr(s, RSTART, RLENGTH)
        after = substr(s, RSTART + RLENGTH)
        c1 = substr(after, 1, 1)
        word = (tok !~ /\/\//) && (c1 ~ /[A-Za-z0-9_]/)      # .standingTrue, .freezeX: another field, not this read
        if (!word && after !~ typed) {
          covered = 0
          for (k = 1; k <= n; k++) {
            lit = lits[k]; from = 1
            while ((p = index(substr(text, from), lit)) > 0) {
              pos = from + p - 1
              if (start >= pos && start < pos + length(lit)) { covered = 1; print prog "\t" lit >> usedf }
              from = pos + 1
            }
          }
          if (!covered) print ln
        }
        s = substr(s, RSTART + RLENGTH); off = off + RSTART + RLENGTH - 1
      }
    }'
}
# rd_scan <scripts dir> <readers tsv> <allow tsv> <out prefix>: writes <out>.found (programs that read the ledger), <out>.unlisted,
# <out>.stale, <out>.badkind, <out>.staleF, <out>.unguarded, <out>.stalerow
rd_scan() {
  local sd="$1" readers="$2" rallow="$3" o="$4" prog f ln
  ( cd "$sd" && { grep -lE "$DISC_RE" -- *.sh 2>/dev/null; grep -lE "$DISC_RE" -- *.jq 2>/dev/null; } ) | sort -u > "$o.found"
  awk -F'\t' '!/^#/ && NF { print $1 }' "$readers" | sort -u > "$o.listed"
  comm -23 "$o.found" "$o.listed" | tr '\n' ' ' > "$o.unlisted"
  comm -13 "$o.found" "$o.listed" | tr '\n' ' ' > "$o.stale"
  awk -F'\t' '!/^#/ && NF && $2 != "seam" && $2 != "scan" && $2 != "none" { print $1 }' "$readers" | tr '\n' ' ' > "$o.badkind"
  : > "$o.staleF"
  while read -r prog fields; do
    for f in $(printf '%s' "$fields" | tr ',' ' '); do
      grep -vE '^[[:space:]]*#' "$sd/$prog" | grep -E "\\.$f\\b" >/dev/null || printf ' %s:%s' "$prog" "$f" >> "$o.staleF"   # no -q: it would SIGPIPE the producer under pipefail
    done
  done < <(awk -F'\t' '!/^#/ && NF && $3 != "" { print $1, $3 }' "$readers")
  : > "$o.used"; : > "$o.unguarded"
  # every program that is not kind none (a seam program is also name-checked above; a none program holds no protective read)
  while IFS= read -r prog; do
    [ "$(awk -F'\t' -v p="$prog" '!/^#/ && $1 == p { print $2 }' "$readers")" != none ] || continue
    for ln in $(rd_unguarded "$sd/$prog" "$rallow" "$prog" "$o.used"); do printf ' %s:%s' "$prog" "$ln" >> "$o.unguarded"; done
  done < "$o.found"
  sort -u "$o.used" > "$o.used.s"
  awk -F'\t' '!/^#/ && NF { print $1 "\t" $2 }' "$rallow" | sort -u > "$o.allow.s"
  comm -13 "$o.used.s" "$o.allow.s" | tr '\t' ':' | tr '\n' ' ' > "$o.stalerow"
}
SD="${CM_FIELD_SCRIPTS:-$HERE/..}"
READERS="$HERE/fixtures/ledger-readers.tsv"; RALLOW="$HERE/fixtures/protective-read-allow.tsv"
rd_scan "$SD" "$READERS" "$RALLOW" "$ROOT/rd"
check "readers: every program (*.sh and *.jq) that reads the ledger, asks, health or lanes is on ledger-readers.tsv ($(wc -l < "$ROOT/rd.found" | tr -d ' ') programs)" "$(cat "$ROOT/rd.unlisted")" ""
check "readers: every ledger-readers.tsv row names a program that still reads the ledger (no stale row)" "$(cat "$ROOT/rd.stale")" ""
check "readers: every kind is seam, scan or none" "$(cat "$ROOT/rd.badkind")" ""
check "readers: every protective field a row lists is still read by that program (no stale field)" "$(cat "$ROOT/rd.staleF")" ""
check "readers: every protective read (standing, freeze, state or issue with a default, project), one by one, is typed or covered by protective-read-allow.tsv" "$(cat "$ROOT/rd.unguarded")" ""
check "readers: every protective-read-allow.tsv row still covers a read (no stale row)" "$(cat "$ROOT/rd.stalerow")" ""
check "readers: classify.jq and intake.jq are scanned programs, not skipped as a .jq file" "$(grep -cE '^(classify|intake)\.jq$' "$ROOT/rd.found" | tr -d ' ')" "2"

# ---- the scan itself, on a synthetic scripts dir (each line below must be caught; each control must not) ---------------------------
MS="$ROOT/ms"; mkdir -p "$MS"
cat > "$MS/zz-typed.sh" <<'M'
jq '.workers[] | select(.standing | cm_standing_any) | select(.standing == true)' "$LEDGER"
M
cat > "$MS/zz-untyped-sh.sh" <<'M'
jq '.workers[] | select(.standing)' "$LEDGER"
M
cat > "$MS/zz-twice.sh" <<'M'
jq '.workers[] | select((.standing | cm_standing_any) and .state // "running")' "$LEDGER"
M
cat > "$MS/zz-twice2.sh" <<'M'
jq '.workers[] | select((.standing | cm_standing_any) and (.standing)) | .project // "x"' "$LEDGER"
M
cat > "$MS/zz-untyped.jq" <<'M'
.workers | map(select(.standing)) | .[0].state // "running"
M
cat > "$MS/zz-typed.jq" <<'M'
.workers | map(select(.standing | cm_standing_any)) | length
M
cat > "$MS/zz-unlisted.jq" <<'M'
.asks | length
M
cat > "$MS/zz-field.sh" <<'M'
jq '.workers[] | .standingTrue | length' "$LEDGER"
M
printf 'zz-typed.sh\tscan\tstanding\tcontrol\nzz-untyped-sh.sh\tscan\tstanding\tx\nzz-twice.sh\tscan\tstanding\tx\nzz-twice2.sh\tscan\tstanding\tx\nzz-untyped.jq\tscan\tstanding\tx\nzz-typed.jq\tscan\tstanding\tx\nzz-field.sh\tscan\t\tx\n' > "$MS/readers.tsv"
printf '# none\nzz-twice2.sh\tselect((.standing | cm_standing_any) and (.standing))\tcovers the first read only (the second is on the line too)\n' > "$MS/allow.tsv"
rd_scan "$MS" "$MS/readers.tsv" "$MS/allow.tsv" "$ROOT/mrd"
check "scan self-test: a .jq program that reads the ledger and is not listed is found" "$(cat "$ROOT/mrd.unlisted")" "zz-unlisted.jq "
check "scan self-test: an untyped read, a read beside a typed helper on the same line, and an untyped .jq read are named; typed reads and another field (.standingTrue) are not" \
  "$(tr ' ' '\n' < "$ROOT/mrd.unguarded" | grep . | sort | tr '\n' ' ')" "zz-twice.sh:1 zz-twice2.sh:1 zz-untyped-sh.sh:1 zz-untyped.jq:1 zz-untyped.jq:1 "
check "scan self-test: an allow row excuses only the read its literal covers" "$(cat "$ROOT/mrd.used" | cut -f1 | sort -u | tr '\n' ' ')" "zz-twice2.sh "

printf 'field-reads: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
