#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# census-line.sh (test): rule 4 of the census-to-zero work. classify.sh --census prints
# `census: orphans N, unknown-git N, dirty N (target 0)` as data, names every row over 0 with
# worktree, host and reason, and counts other-project apart. Synthetic names (lane-a, host-a ...),
# a scoped config and a synthetic discover document. Touches only a mktemp dir.
#
#   scripts/test/census-line.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-censusline.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
export CM_HOME="$ROOT"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE

cat > "$ROOT/scoped.yaml" <<'Y'
schema: concertmaster.config/v1
worktrees:
  orca_repo: acme-app
  self_name: concertmaster
  never_touch: [tool-x]
ownership:
  leads: { lead-a: lane-a }
  comment_markers: ["workers i own"]
  comment_stop_words: []
  prefixes: { lane-: lane-a }
Y
printf 'schema: concertmaster.config/v1\n' > "$ROOT/unscoped.yaml"
cat > "$ROOT/ledger.json" <<'J'
{"workers": {"w-std": {"host": "host-a", "path": "/w/lane-standing", "standing": true},
             "w-one": {"host": "host-a", "path": "/w/lane-single", "standing": false}}}
J
NOW=1791600000000; OLD=$((NOW - 600000))
row() { # row <host> <name> <repo> <extra-json>
  jq -cn --arg h "$1" --arg n "$2" --arg repo "$3" --argjson x "${4:-{\}}" --argjson old "$OLD" '
    ({host: $h, path: ("/w/" + $n), displayName: $n, repo: $repo, status: "idle", comment: "", source: "orca",
      worktreeId: null, isMainWorktree: false, childWorktreeIds: [], inOrca: true, liveTerminalCount: 0,
      agents: [], lastOutputAt: $old, lastActivityAt: $old,
      git: {exists: true, statusOk: true, dirty: 0, unpushed: 0}, pr: null}) + $x'
}
doc() { jq -s --argjson now "$NOW" --argjson gs "${1:-[]}" '{generatedAtMs: $now, generatedAt: "t",
  hosts: [{name: "host-a", reachable: true}, {name: "host-b", reachable: true}], gitScope: {hosts: $gs}, worktrees: .}'; }
DIRTY2='{"git": {"exists": true, "statusOk": true, "dirty": 2, "unpushed": 1}}'
LIVE='{"liveTerminalCount": 1, "agents": [{"state": "working", "paneKey": "p1", "updatedAt": '"$((NOW - 60000))"'}], "git": {"exists": true, "statusOk": true, "dirty": 9, "unpushed": 0}}'

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1: missing '$3' in: $2"; fi; }
hasnot() { if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1: unexpected '$3' in: $2"; else ok "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }

# ---- a census with one of each ----
{
  row host-a lane-clean acme-app                                           # clean, owned by prefix
  row host-a lane-unk acme-app '{"git": null}'                              # unknown-git, with a scope error
  row host-b lane-unk2 acme-app '{"git": null}'                             # unknown-git, no scope entry
  row host-a lane-dirty acme-app "$DIRTY2"                                  # dirty 2, unpushed 1
  row host-a lane-standing acme-app "$DIRTY2"                               # standing lane, dirty: still counted
  row host-a lane-single acme-app                                           # ledger single-task, clean
  row host-a lane-live acme-app "$LIVE"                                     # live agent mid-work: not counted
  row host-a zzz-nobody acme-app                                            # no owner: orphan
  row host-a tool-x acme-app                                                # never_touch exact name, clean: other-project, not counted
  row host-a elsewhere other-app '{"git": null}'                            # other-project, unknown: not counted
  row host-a acme-main acme-app '{"isMainWorktree": true, "git": {"exists": true, "statusOk": true, "dirty": 4, "unpushed": 0}}'
} | doc '[{"host":"host-a","ok":false,"via":null,"error":"git state not collected: orca terminal: create failed; ssh: exit 255"}]' > "$ROOT/d1.json"
OUT="$(CM_CONFIG="$ROOT/scoped.yaml" "$HERE/../classify.sh" --census < "$ROOT/d1.json" 2>/dev/null)"
eq "first line is the census line with the three counts" "$(printf '%s\n' "$OUT" | head -1)" "census: orphans 1, unknown-git 2, dirty 2 (target 0)"
has "orphan row named: worktree, host, reason"        "$OUT" "  orphans: zzz-nobody @ host-a: no owner"
has "unknown-git row names the Orca and ssh failure"  "$OUT" "  unknown-git: lane-unk @ host-a: git state not collected: orca terminal: create failed; ssh: exit 255"
has "unknown-git row on a host with no scope entry"   "$OUT" "  unknown-git: lane-unk2 @ host-b: git state not collected on host-b"
has "dirty row names dirty and unpushed"              "$OUT" "  dirty: lane-dirty @ host-a: dirty:2, unpushed:1"
has "a standing lane with dirt is counted"            "$OUT" "  dirty: lane-standing @ host-a"
hasnot "a live agent mid-work is not counted"         "$OUT" "lane-live"
hasnot "other-project rows are not named"             "$OUT" "tool-x"
hasnot "the other-repo row is not named"              "$OUT" "elsewhere"
hasnot "a main checkout is not counted"               "$OUT" "acme-main"
hasnot "clean rows are not named"                     "$OUT" "lane-clean"
has "other-project is a separate count"               "$OUT" "other-project: 2 (listed apart, not counted)"
# the Supabase stack line (no scan data in these synthetic documents: INCOMPLETE, never a clean zero) follows the apart line
eq "no row line past the three kinds plus the apart line and the stack line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 8
J1="$(CM_CONFIG="$ROOT/scoped.yaml" "$HERE/../classify.sh" < "$ROOT/d1.json" 2>/dev/null)"
eq "JSON carries the same counts (.census)" "$(jq -r '.census | "\(.orphans) \(.unknownGit) \(.dirty) \(.otherProject)"' <<< "$J1")" "1 2 2 2"
eq "JSON rows are structured (kind, worktree, host, reason)" "$(jq -r '.census.rows[0] | keys | join(",")' <<< "$J1")" "host,kind,reason,worktree"

# ---- zero ----
{ row host-a lane-clean acme-app; row host-a tool-x acme-app; } | doc > "$ROOT/d0.json"
OUT0="$(CM_CONFIG="$ROOT/scoped.yaml" "$HERE/../classify.sh" --census < "$ROOT/d0.json" 2>/dev/null)"
eq "all clean: the line reads zero and no row follows" "$OUT0" "census: orphans 0, unknown-git 0, dirty 0 (target 0)
other-project: 1 (listed apart, not counted)
supabase-stacks: orphans 0 (target 0) (CHECK INCOMPLETE: discover document has no Supabase stack data (older discover.sh): stack check not run)"

# ---- ownership not configured: orphans cannot be counted, never guessed as 0 ----
OUTU="$(CM_CONFIG="$ROOT/unscoped.yaml" "$HERE/../classify.sh" --census < "$ROOT/d1.json" 2>/dev/null)"
has "no ownership config: orphans print ? not 0" "$OUTU" "census: orphans ?, unknown-git"
has "no ownership config: the reason is named"   "$OUTU" "orphans: ? (ownership off:"

# ---- the same output as a tick script sees it: exit 0, nothing on stderr noise-free path ----
CM_CONFIG="$ROOT/scoped.yaml" "$HERE/../classify.sh" --census < "$ROOT/d1.json" >/dev/null 2>&1
eq "--census exits 0 even with rows over 0" "$?" 0

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
