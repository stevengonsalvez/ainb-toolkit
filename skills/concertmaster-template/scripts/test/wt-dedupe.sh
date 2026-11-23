#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2016  # pass() always succeeds; check bodies are single-quoted on purpose
# wt-dedupe.sh (test): lib.sh cm_wt_dedupe keeps ONE row per worktree of a `worktree list` reply. The fleet CLI can
# return the same worktree twice, one copy with a null comment; a reader that takes the first match would then read a live
# worker as unowned. Covers: the null-comment copy first and last, the survivor's place, running state merged over the
# duplicates (agents without repeats, the larger liveTerminalCount, the union of child ids, a busy status), --no-merge
# (pick one), totalCount lowered by the rows removed only when it counted rows, rows with no path matched by worktreeId, a
# row with neither never merged, an ok:false reply passed through, and a reply that is not JSON failing closed (exit 1,
# nothing on stdout). Mutant on a scratch copy of lib.sh: a dedupe that passes the reply through fails the duplicate cases.
#
#   scripts/test/wt-dedupe.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-wtdedupe-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }
check() { if (eval "$2"); then pass "$1"; else fail "$1" "${3:-}"; fi; }
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }

export CM_CONFIG="$HERE/fixtures/config.test.yaml" CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO

# run <lib.sh> <args for cm_wt_dedupe> with the reply on stdin (a file in $IN); RC, OUT
run() { local lib="$1"; shift; OUT="$(bash -c '. "$1"; shift; cm_wt_dedupe "$@"' _ "$lib" "$@" < "$IN" 2>/dev/null)"; RC=$?; }
IN="$ROOT/in.json"
LIB="$SKILL/scripts/lib.sh"

# the same worktree twice: the real row has the comment and a live agent, the copy has neither
dup() { # <order: first|last> [totalCount]
  jq -cn --arg o "$1" --argjson tc "${2:-3}" '
    {path: "/w/acme/lane-a", worktreeId: "r::lane-a", displayName: "lane-a", comment: "cm:running", status: "idle",
     agents: [{paneKey: "p1", updatedAt: "2"}], liveTerminalCount: 1, childWorktreeIds: ["c1"]} as $real
    | ($real | .comment = null | .status = "working" | .agents = [{paneKey: "p2", updatedAt: "1"}] | .liveTerminalCount = 2 | .childWorktreeIds = ["c2"]) as $copy
    | {path: "/w/acme/lane-b", worktreeId: "r::lane-b", displayName: "lane-b", comment: "cm:idle"} as $other
    | {ok: true, result: {worktrees: (if $o == "first" then [$copy, $real, $other] else [$real, $copy, $other] end), totalCount: $tc}}' > "$IN"
}

for order in first last; do
  dup "$order"; run "$LIB"
  check "duplicate ($order copy has a null comment): ONE row per worktree, the one with the comment wins" '[ "$RC" = 0 ] && [ "$(jq -r "[.result.worktrees[] | select(.displayName == \"lane-a\")] | length" <<<"$OUT")" = 1 ] && [ "$(jq -r ".result.worktrees[] | select(.displayName == \"lane-a\") | .comment" <<<"$OUT")" = "cm:running" ]' "rc=$RC $OUT"
  check "duplicate ($order): the survivor keeps the place of the first copy" '[ "$(jq -r "[.result.worktrees[].displayName] | join(\",\")" <<<"$OUT")" = "lane-a,lane-b" ]' "$OUT"
  check "duplicate ($order): both copies agents are kept, the larger liveTerminalCount, the union of child ids, a busy status" '[ "$(jq -r ".result.worktrees[0] | [(.agents | length), .liveTerminalCount, (.childWorktreeIds | sort | join(\"+\")), .status] | join(\" \")" <<<"$OUT")" = "2 2 c1+c2 working" ]' "$OUT"
  check "duplicate ($order): totalCount counted rows, so it drops by the one row removed" '[ "$(jq -r ".result.totalCount" <<<"$OUT")" = 2 ]' "$OUT"
done
dup first 1; run "$LIB"
check "a totalCount already below the raw row count counted worktrees: left alone" '[ "$(jq -r ".result.totalCount" <<<"$OUT")" = 1 ]' "$OUT"
dup first; run "$LIB" --no-merge
check "--no-merge picks one row and merges nothing (one agent, the real row's count)" '[ "$(jq -r ".result.worktrees[0] | [(.agents | length), .liveTerminalCount, .status] | join(\" \")" <<<"$OUT")" = "1 1 idle" ]' "$OUT"

# no path: matched by worktreeId; neither: never merged
jq -cn '{ok: true, result: {worktrees: [{worktreeId: "r::x", comment: null}, {worktreeId: "r::x", comment: "c"}, {comment: null}, {comment: null}]}}' > "$IN"; run "$LIB"
check "rows with no path are one worktree by worktreeId; two rows with neither are never merged" '[ "$(jq -r ".result.worktrees | length" <<<"$OUT")" = 3 ] && [ "$(jq -r ".result.worktrees[0].comment" <<<"$OUT")" = c ]' "$OUT"
jq -cn '{ok: true, result: {worktrees: [{path: "/a", comment: "c"}, {path: "/b"}]}}' > "$IN"; run "$LIB"
check "a list without duplicates passes through unchanged" '[ "$(jq -c ".result.worktrees" <<<"$OUT")" = "[{\"path\":\"/a\",\"comment\":\"c\"},{\"path\":\"/b\"}]" ]' "$OUT"

# replies it cannot filter
printf '%s\n' '{"ok":false,"error":{"code":"no_runtime"}}' > "$IN"; run "$LIB"
check "an ok:false reply (no worktrees array) passes through unchanged" '[ "$RC" = 0 ] && [ "$(jq -r ".error.code" <<<"$OUT")" = no_runtime ]' "rc=$RC $OUT"
printf 'not json at all\n' > "$IN"; run "$LIB"
check "a reply that is not JSON FAILS CLOSED: exit 1, nothing on stdout" '[ "$RC" = 1 ] && [ -z "$OUT" ]' "rc=$RC out=$OUT"
: > "$IN"; run "$LIB"
check "an empty reply FAILS CLOSED too" '[ "$RC" = 1 ] && [ -z "$OUT" ]' "rc=$RC out=$OUT"

# mutant: cm_wt_dedupe that passes the reply through
MUT="$ROOT/lib-mut.sh"; cp "$LIB" "$MUT"
sed -i 's/^cm_wt_dedupe() {$/cm_wt_dedupe() { cat; return 0/' "$MUT"
if cmp -s "$LIB" "$MUT"; then fail "mutant pass-through" "the edit changed nothing"; else
  dup first; run "$MUT"
  check "mutant (cm_wt_dedupe passes the reply through) is caught: the duplicate is still there" '[ "$(jq -r "[.result.worktrees[] | select(.displayName == \"lane-a\")] | length" <<<"$OUT")" = 2 ]' "$OUT"
  printf 'not json\n' > "$IN"; run "$MUT"
  check "mutant (pass-through) is caught: a non-JSON reply is no longer refused" '[ "$RC" = 0 ]' "rc=$RC"
fi

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
