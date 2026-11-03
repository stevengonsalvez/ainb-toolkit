#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# asks.sh (test): every cm:ask, cm:blocked and cm:waiting-owner in every lane's Orca comment is found on
# every host, wherever it sits in the comment: line 1, line 2 or later, after " | ", after a literal \n.
# Root cause pinned: the old scan read only lines starting cm:ask, so a cm:blocked on line 2 or after a
# " | " sat unseen for hours. Also: a comment with no tag, a tag quoted mid-sentence, a malformed comment
# (number, object, null), an unreachable host and a host that answers garbage are listed or ignored, never
# a crash and never "no blockers". Ages: new, then "older than 1 tick" on the second consecutive run.
# Stub Orca, synthetic names (lane-a, host-a), a mktemp dir; touches nothing else.
#
#   scripts/test/asks.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-asks.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
env=""
for ((i = 1; i <= $#; i++)); do [ "${!i}" = "--environment" ] && { j=$((i + 1)); env="${!j}"; }; done
case "$1 $2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"},{"kind":"environment","name":"host-a"},{"kind":"environment","name":"host-b"},{"kind":"environment","name":"host-c"}]}}' ;;
  "worktree list")
    case "$env" in
      "") printf '%s' '{"ok":true,"result":{"worktrees":[
          {"path":"/w/acme/lane-a","displayName":"lane-a","comment":"cm:running 3 workers\ncm:blocked line two needs a decision: A or B"},
          {"path":"/w/acme/lane-d","displayName":"lane-d","comment":"cm:running\ncm:child w-1\ncm:ask third line question"},
          {"path":"/w/acme/lane-e","displayName":"lane-e","comment":"cm:running fine, we are not cm:blocked here"},
          {"path":"/w/acme/lane-f","displayName":"lane-f","comment":"plain note with no tag"},
          {"path":"/w/acme/lane-g","displayName":"lane-g","comment":12345},
          {"path":"/w/acme/lane-h","displayName":"lane-h","comment":{"a":"cm:blocked inside an object"}},
          {"path":"/w/acme/lane-i","displayName":"lane-i","comment":null},
          {"path":"/w/acme/lane-j","displayName":"lane-j","comment":"cm:blocked"},
          {"path":"/w/acme/lane-k","displayName":"lane-k","comment":"cm:running\\ncm:waiting-owner literal backslash n text"},
          {"path":"/w/acme/lane-l","displayName":"lane-l","comment":"cm:blockedfoo not a tag | xcm:blocked nor this | cm:asking nor this"},
          {"path":"/w/acme/NEVERid","displayName":"NEVERid","comment":"cm:blocked never touched"},
          {"path":"/w/acme/lane-m","displayName":"lane-m","comment":"  cm:blocked:   colon form, padded   "}
        ]}}' ;;
      host-a) printf '%s' '{"ok":true,"result":{"worktrees":[
          {"path":"/w/acme/lane-b","displayName":"lane-b","comment":"cm:running 2 workers | cm:blocked pipe-joined blocker | cm:followup x owner=owner-b t"},
          {"path":"/w/acme/lane-c","displayName":"lane-c","comment":"cm:merge-ready #5 abcdef123456 | cm:waiting-owner approve plan"}
        ]}}' ;;
      host-b) echo "host unreachable" >&2; exit 1 ;;
      host-c) printf 'this is not json at all' ;;
    esac ;;
esac
STUB
chmod +x "$BIN/orca"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/acme/", orca_repo: app, never_touch: [NEVERid] }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_HOME="$ROOT/home" ORCA_CLI_COMMAND="$BIN/orca" PATH="$BIN:$PATH"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH CM_ASKS_SEEN
mkdir -p "$CM_HOME"

J1="$("$S/asks.sh" --json 2>"$ROOT/err1")"
has() { jq -e "$1" <<<"$J1" >/dev/null 2>&1; }
# row <worktree> <tag> <text-substring>
row() { jq -e --arg w "$1" --arg t "$2" --arg x "$3" '[.asks[] | select(.worktree == $w and .tag == $t and (.text | contains($x)))] | length == 1' <<<"$J1" >/dev/null 2>&1; }

row lane-a cm:blocked "line two needs a decision" && pass "cm:blocked on line 2 is found" || fail "line 2" "$(jq -c '.asks' <<<"$J1")"
row lane-d cm:ask "third line question" && pass "cm:ask on line 3 is found" || fail "line 3" "$(jq -c '.asks' <<<"$J1")"
row lane-b cm:blocked "pipe-joined blocker" && pass "cm:blocked after ' | ' on line 1 is found" || fail "pipe" "$(jq -c '.asks' <<<"$J1")"
row lane-c cm:waiting-owner "approve plan" && pass "cm:waiting-owner after ' | ' on a remote host is found" || fail "waiting-owner" "$(jq -c '.asks' <<<"$J1")"
row lane-k cm:waiting-owner "literal backslash n text" && pass "a literal \\n counts as a newline" || fail "literal n" "$(jq -c '.asks' <<<"$J1")"
row lane-j cm:blocked "(no text)" && pass "a bare cm:blocked is reported with a placeholder text" || fail "bare tag" "$(jq -c '.asks' <<<"$J1")"
row lane-m cm:blocked "colon form, padded" && pass "cm:blocked: with a colon and padding is found" || fail "colon" "$(jq -c '.asks' <<<"$J1")"
for w in lane-e lane-f lane-l; do
  has "[.asks[] | select(.worktree == \"$w\")] | length == 0" && pass "$w: no tag at a segment start, nothing reported" || fail "$w" "$(jq -c '.asks' <<<"$J1")"
done
for w in lane-g lane-h lane-i; do
  has "[.asks[] | select(.worktree == \"$w\")] | length == 0" && pass "$w: malformed comment ignored, no crash" || fail "$w" "$(jq -c '.asks' <<<"$J1")"
done
has '[.asks[] | select(.worktree == "NEVERid")] | length == 0' && pass "a never_touch worktree is not read" || fail "never_touch" "$(jq -c '.asks' <<<"$J1")"
has '.count == 7' && pass "exactly the seven real blockers" || fail "count" "$(jq -c '[.asks[] | .worktree]' <<<"$J1")"
has '.hostsRead | sort == ["host-a","local"]' && pass "reads the local host and the reachable remote" || fail "hostsRead" "$(jq -c '.hostsRead' <<<"$J1")"
has '[.unreachable[] | .host] | sort == ["host-b","host-c"]' && pass "unreachable host and garbage host are listed, not read as clean" || fail "unreachable" "$(jq -c '.unreachable' <<<"$J1")"
has '.olderThanOneTick == 0 and ([.asks[] | .runs] | all(. == 1))' && pass "first run: everything is new" || fail "age run 1" "$(jq -c '.asks[0]' <<<"$J1")"
[ -s "$CM_HOME/asks-seen.json" ] && pass "first-seen file written" || fail "seen file" "missing"

JP="$("$S/asks.sh" --peek --json 2>/dev/null)"
jq -e '.olderThanOneTick == 0 and ([.asks[] | .runs] | all(. == 1))' <<<"$JP" >/dev/null 2>&1 \
  && pass "--peek after one run: not older, run count not advanced" || fail "peek age" "$(jq -c '[.asks[] | {worktree, runs}]' <<<"$JP")"
J2="$("$S/asks.sh" --json 2>/dev/null)"
jq -e '.olderThanOneTick == 7 and ([.asks[] | .runs] | all(. == 2))' <<<"$J2" >/dev/null 2>&1 \
  && pass "second consecutive run: every blocker is older than 1 tick" || fail "age run 2" "$(jq -c '[.asks[] | {worktree, runs}]' <<<"$J2")"
T="$("$S/asks.sh" --peek 2>/dev/null)"
grep -q 'older-than-1-tick' <<<"$T" && grep -q $'^HOST\tWORKTREE\tTAG\tTEXT\tAGE' <<<"$T" && pass "table form: header and older-than-1-tick shown" || fail "table" "$T"
grep -q '^unreachable: host-b' <<<"$T" && grep -q '^asks: 7 open, 7 older than 1 tick' <<<"$T" && pass "table form: unreachable hosts and the count are listed" || fail "table footer" "$T"
R3="$(jq -c '[.. | .runs? // empty] | max' "$CM_HOME/asks-seen.json")"
[ "$R3" = 2 ] && pass "--peek does not change the first-seen file" || fail "--peek" "max runs $R3"

# a blocker that disappears is forgotten; an unreachable host's items are kept
jq '. + {"host-b\u0001lane-z\u0001cm:blocked\u0001kept while host-b is down": {host:"host-b", worktree:"lane-z", tag:"cm:blocked", firstSeen:"2026-10-31T00:00:00Z", lastSeen:"2026-10-31T00:00:00Z", runs:5}}
    + {"local\u0001lane-gone\u0001cm:blocked\u0001answered long ago": {host:"local", worktree:"lane-gone", tag:"cm:blocked", firstSeen:"2026-10-31T00:00:00Z", lastSeen:"2026-10-31T00:00:00Z", runs:5}}' \
  "$CM_HOME/asks-seen.json" > "$ROOT/seen.tmp" && mv "$ROOT/seen.tmp" "$CM_HOME/asks-seen.json"
"$S/asks.sh" >/dev/null 2>&1
jq -e 'keys | any(contains("lane-z"))' "$CM_HOME/asks-seen.json" >/dev/null 2>&1 \
  && pass "items of an unreachable host are kept" || fail "kept" "$(jq -c 'keys' "$CM_HOME/asks-seen.json")"
jq -e 'keys | any(contains("lane-gone")) | not' "$CM_HOME/asks-seen.json" >/dev/null 2>&1 \
  && pass "an item gone from a reachable host is forgotten" || fail "forgotten" "$(jq -c 'keys' "$CM_HOME/asks-seen.json")"

# a damaged first-seen file is replaced, not fatal
printf 'not json{' > "$CM_HOME/asks-seen.json"
J4="$("$S/asks.sh" --json 2>/dev/null)"
jq -e '.count == 7 and .olderThanOneTick == 0' <<<"$J4" >/dev/null 2>&1 && pass "a damaged first-seen file starts over, no crash" || fail "damaged seen" "$(jq -c '.count' <<<"$J4")"
"$S/asks.sh" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && pass "unknown arg: exit 2" || fail "usage" "rc"

# orca host list failing: the local host is still read and the failure is listed
cat > "$BIN/orca-down" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") echo "orca down" >&2; exit 1 ;;
  "worktree list") printf '%s' '{"ok":true,"result":{"worktrees":[{"path":"/w/acme/lane-a","displayName":"lane-a","comment":"cm:blocked still found"}]}}' ;;
esac
STUB
chmod +x "$BIN/orca-down"
J5="$(ORCA_CLI_COMMAND="$BIN/orca-down" CM_ASKS_SEEN="$ROOT/seen5.json" "$S/asks.sh" --json 2>/dev/null)"
jq -e '.count == 1 and (.unreachable | length == 1) and (.unreachable[0].error | contains("host list failed"))' <<<"$J5" >/dev/null 2>&1 \
  && pass "host list down: local host still read, failure listed" || fail "host list down" "$J5"

# host list down must not erase the ages of items on hosts that were not read this run
jq -n '{("host-b\u0001lane-r\u0001cm:blocked\u0001old question"): {host:"host-b", worktree:"lane-r", tag:"cm:blocked", firstSeen:"2026-10-30T00:00:00Z", lastSeen:"2026-10-31T00:00:00Z", runs:4}}' > "$ROOT/seen6.json"
ORCA_CLI_COMMAND="$BIN/orca-down" CM_ASKS_SEEN="$ROOT/seen6.json" "$S/asks.sh" >/dev/null 2>&1
jq -e 'to_entries | any(.value.host == "host-b" and .value.runs == 4)' "$ROOT/seen6.json" >/dev/null 2>&1 \
  && pass "host list down: a remote item's age is kept, not reset" || fail "host list down erased a remote age" "$(cat "$ROOT/seen6.json")"
jq -e 'to_entries | any(.value.host == "local")' "$ROOT/seen6.json" >/dev/null 2>&1 \
  && pass "host list down: the local host's fresh item is recorded" || fail "local item missing" "$(cat "$ROOT/seen6.json")"

# a worktree list cut off at the limit is a partial read: reported, rows used, unseen blockers keep their age
cat > "$BIN/orca-trunc" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}]}}' ;;
  "worktree list") printf '%s' '{"ok":true,"result":{"truncated":true,"totalCount":900,"worktrees":[{"path":"/w/acme/lane-a","displayName":"lane-a","comment":"cm:blocked returned row"}]}}' ;;
esac
STUB
chmod +x "$BIN/orca-trunc"
jq -n '{("local\u0001lane-a\u0001/w/acme/lane-a\u0001cm:blocked\u0001returned row"): {host:"local", worktree:"lane-a", tag:"cm:blocked", firstSeen:"2026-10-30T00:00:00Z", lastSeen:"2026-10-31T00:00:00Z", runs:3},
        ("local\u0001lane-q\u0001cm:blocked\u0001beyond the limit"): {host:"local", worktree:"lane-q", tag:"cm:blocked", firstSeen:"2026-10-30T00:00:00Z", lastSeen:"2026-10-31T00:00:00Z", runs:4}}' > "$ROOT/seen7.json"
J7="$(ORCA_CLI_COMMAND="$BIN/orca-trunc" CM_ASKS_SEEN="$ROOT/seen7.json" "$S/asks.sh" --json 2>/dev/null)"
jq -e '.count == 1 and (.unreachable | length == 1) and (.unreachable[0].error | contains("truncated"))' <<<"$J7" >/dev/null 2>&1 \
  && pass "truncated list: rows used and the host reported incomplete" || fail "truncated report" "$J7"
jq -e 'to_entries | any(.value.worktree == "lane-q" and .value.runs == 4)' "$ROOT/seen7.json" >/dev/null 2>&1 \
  && pass "truncated list: a blocker beyond the limit keeps its age" || fail "truncated erased an age" "$(cat "$ROOT/seen7.json")"
jq -e 'to_entries | any(.value.worktree == "lane-a" and .value.runs == 4)' "$ROOT/seen7.json" >/dev/null 2>&1 \
  && pass "truncated list: a returned blocker still ages" || fail "truncated aging stuck" "$(cat "$ROOT/seen7.json")"

# orca prints a valid list and then fails: not a successful read, the saved ages stay
cat > "$BIN/orca-late" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}]}}' ;;
  "worktree list") printf '%s' '{"ok":true,"result":{"worktrees":[{"path":"/w/acme/lane-a","displayName":"lane-a","comment":"cm:blocked partial"}]}}'; exit 3 ;;
esac
STUB
chmod +x "$BIN/orca-late"
jq -n '{("local\u0001lane-q\u0001cm:blocked\u0001saved question"): {host:"local", worktree:"lane-q", tag:"cm:blocked", firstSeen:"2026-10-30T00:00:00Z", lastSeen:"2026-10-31T00:00:00Z", runs:6}}' > "$ROOT/seen8.json"
J8="$(ORCA_CLI_COMMAND="$BIN/orca-late" CM_ASKS_SEEN="$ROOT/seen8.json" "$S/asks.sh" --json 2>/dev/null)"
jq -e '.count == 0 and (.unreachable | length == 1) and (.unreachable[0].error | contains("failed"))' <<<"$J8" >/dev/null 2>&1 \
  && pass "orca fails after printing a list: host unreachable, nothing read" || fail "late failure accepted" "$J8"
jq -e 'to_entries | any(.value.worktree == "lane-q" and .value.runs == 6)' "$ROOT/seen8.json" >/dev/null 2>&1 \
  && pass "orca fails after printing a list: saved ages are kept" || fail "late failure erased ages" "$(cat "$ROOT/seen8.json")"

# two worktrees on one host with the same display name and the same blocker text are two blockers
cat > "$BIN/orca-dup" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}]}}' ;;
  "worktree list") printf '%s' '{"ok":true,"result":{"worktrees":[{"path":"/w/acme/one/lane-z","displayName":"lane-z","comment":"cm:blocked same words"},{"path":"/w/acme/two/lane-z","displayName":"lane-z","comment":"cm:blocked same words"}]}}' ;;
esac
STUB
chmod +x "$BIN/orca-dup"
J9="$(ORCA_CLI_COMMAND="$BIN/orca-dup" CM_ASKS_SEEN="$ROOT/seen9.json" "$S/asks.sh" --json 2>/dev/null)"
jq -e '.count == 2 and ([.asks[].path] | unique | length == 2)' <<<"$J9" >/dev/null 2>&1 \
  && pass "same display name and text on two paths: both blockers kept" || fail "duplicate blockers collapsed" "$J9"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
