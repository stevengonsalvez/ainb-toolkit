#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# ask-timeout-fuzz.sh: every ledger field the classifier of scripts/ask-timeout.sh reads, set to every wrong type, from the maximal base
# (scripts/test/ask-timeout-base.sh) and the inventory scripts/test/fixtures/asktimeout-fields.tsv. A wrong value in a class A field
# must never leave the ask verdict-due or in-progress: it is never (stays with the owner), or not an open ask at all, and the list must
# still exit 0 and list the ask beside it (a worker row that is a number must not abort the list). A class B field only has to keep
# the list alive. Wrong values: false, true, 7, "x", {}, [], ["x"] minus the legal types of the field. The ask-level mutations ride
# in ONE ledger (an ask each, the same worker), the ones that change the workers or the id are runs of their own.
# CM_AT_SCRIPT=<path> runs another copy of ask-timeout.sh (the revert check: a copy with one fix undone must fail).
#
#   scripts/test/ask-timeout-fuzz.sh     # exit 0 when every mutation holds
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${CM_AT_SCRIPT:-$HERE/../ask-timeout.sh}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-at-fuzz.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
unset CM_AWAY_TIMEOUT_MIN CM_OWN_SCOPE_KINDS CM_LEDGER CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME
export HOME="$ROOT/home" CM_HOME="$ROOT/home/.concertmaster" CM_NOW="2026-10-17T19:00:00Z" CM_CONFIG="$ROOT/config.yaml"
mkdir -p "$CM_HOME"
cat > "$CM_CONFIG" <<'EOF2'
schema: concertmaster.config/v1
project: { name: Project One, owner: { name: Owner One, id: owner-1 } }
github: { org: AcmeOrg, main_repo: acme-app }
EOF2
# shellcheck source=SCRIPTDIR/ask-timeout-base.sh
. "$HERE/ask-timeout-base.sh"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }

mkatbase "$ROOT/base.json"
classes() { "$SCRIPT" --ledger "$1" --all 2>/dev/null | awk 'NR > 2 && !/^VERDICT/ && !/^  / { print $1 " " $2 }'; }
BASE="$(classes "$ROOT/base.json" | tr '\n' ',')"
check "base: both asks are verdict-due" "$BASE" "at-a verdict-due,at-b verdict-due,"
jq -R -n '[inputs | select(length > 0 and (startswith("#") | not)) | split("\t")
          | {path: (.[1] | split(".")), legal: (.[2] | split(",")), cls: .[3], bases: (.[4] | split(""))}]' \
  < "$HERE/fixtures/asktimeout-fields.tsv" > "$ROOT/inv.json"
VALS='[false, true, 7, "x", {}, [], ["x"]]'
# every mutation: path, the wrong value, class, base ask id
jq -c --argjson vals "$VALS" '.[] | . as $f | ($vals[] | select((type as $t | ($f.legal | index($t)) == null))) as $v
  | $f.bases[] | {path: $f.path, v: $v, cls: $f.cls, on: (if . == "A" then "at-a" else "at-b" end)}' "$ROOT/inv.json" > "$ROOT/muts.jsonl"
N=$(wc -l < "$ROOT/muts.jsonl" | tr -d ' ')
check "the inventory yields mutations ($N)" "$([ "$N" -gt 100 ] && echo yes || echo no)" "yes"
# a class B extra: text that is not a time, for the time fields
echo '{"path":["asks","*","askedAt"],"v":"not a time","cls":"B","on":"at-a"}' >> "$ROOT/muts.jsonl"

# ask-level mutations (not id): one ledger, an ask per mutation
jq -s -c --slurpfile base "$ROOT/base.json" '
  [.[] | select(.path[0] == "asks" and .path[1] == "*" and .path[2] != "id")] as $m
  | $base[0] as $b
  | $b | .asks = [ range(0; $m | length) as $i | $m[$i] as $x
      | ($b.asks[] | select(.id == $x.on)) | .id = "m\($i)" | .[$x.path[2]] = $x.v ]' "$ROOT/muts.jsonl" > "$ROOT/ask-level.json"
jq -s -r '[.[] | select(.path[0] == "asks" and .path[1] == "*" and .path[2] != "id")] | to_entries[] | "m\(.key)\t\(.value.path | join("."))\t\(.value.v | tojson)\t\(.value.cls)"' "$ROOT/muts.jsonl" > "$ROOT/ask-level.map"
classes "$ROOT/ask-level.json" > "$ROOT/ask-level.out"
check "ask-level: the list exits 0" "$("$SCRIPT" --ledger "$ROOT/ask-level.json" --all >/dev/null 2>&1; echo $?)" "0"
while IFS=$'\t' read -r id path v cls; do
  got="$(awk -v id="$id" '$1 == id { print $2 }' "$ROOT/ask-level.out")"
  case "$cls" in
    A) case "$got" in verdict-due|in-progress) check "$path = $v: never verdict-due" "$got" "never or no row" ;; *) PASS=$((PASS + 1)) ;; esac ;;
    *) PASS=$((PASS + 1)) ;;
  esac
done < "$ROOT/ask-level.map"

# the mutations that change the workers, the id or the lists: a run each, both asks present
while IFS= read -r m; do
  path="$(jq -r '.path | join(".")' <<<"$m")"; cls="$(jq -r '.cls' <<<"$m")"; on="$(jq -r '.on' <<<"$m")"
  case "$path" in asks.\*.id|workers|workers.\*|workers.\*.lane|workers.\*.pr|asks) ;; *) continue ;; esac
  jq --argjson m "$m" --arg p "$path" '
    if $p == "asks" then .asks = $m.v
    elif $p == "workers" then .workers = $m.v
    elif $p == "workers.*" then .workers["w-dev"] = $m.v
    elif ($p | startswith("workers.*.")) then .workers["w-dev"][$m.path[2]] = $m.v
    else (.asks |= map(if .id == $m.on then .id = $m.v else . end)) end' "$ROOT/base.json" > "$ROOT/one.json"
  rc=0; out="$("$SCRIPT" --ledger "$ROOT/one.json" --all 2>/dev/null)" || rc=$?
  # a top-level asks that is not a list cannot be read: exit 1, nothing listed (fail closed); every other mutation lists and exits 0
  if [ "$path" = asks ]; then check "asks = $(jq -c .v <<<"$m"): nothing is verdict-due" "$(grep -c verdict-due <<<"$out")" "0"; continue; fi
  [ "$rc" = 0 ] || { check "$path = $(jq -c .v <<<"$m"): the list exits 0" "$rc" "0"; continue; }
  if [ "$cls" = A ]; then
    case "$path" in
      asks.\*.id) got="$(awk '$1 == "?" { print $2 }' <<<"$out" | head -n 1)" ;;
      *) got="$(awk -v id="$on" '$1 == id { print $2 }' <<<"$out")" ;;
    esac
    case "$got" in verdict-due|in-progress) check "$path = $(jq -c .v <<<"$m") on $on: never verdict-due" "$got" "never or no row" ;; *) PASS=$((PASS + 1)) ;; esac
  else PASS=$((PASS + 1)); fi
  # the ask beside it is not touched by a wrong id or a wrong worker row of another ask: workers.* and workers decide every ask (never), the other ask stays listed
done < "$ROOT/muts.jsonl"
# a worker row that is a number does not abort the list: the other ask (its own lane, no worker) is still verdict-due
jq '.workers["w-dev"] = 7 | .asks += [(.asks[0] | .id = "at-c" | .worker = null)]' "$ROOT/base.json" > "$ROOT/one.json"
check "a worker row that is a number: the ask without that worker is still verdict-due" \
  "$("$SCRIPT" --ledger "$ROOT/one.json" --all 2>/dev/null | awk '$1 == "at-c" { print $2 }')" "verdict-due"

printf 'ask-timeout-fuzz: %s passed, %s failed (%s mutations)\n' "$PASS" "$FAIL" "$N"
[ "$FAIL" -eq 0 ]
