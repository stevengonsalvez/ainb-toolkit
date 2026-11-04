#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# fleet-read.sh (test): a reachable host that answers the project-scoped worktree list with
# repo_not_found (ok:false, exit 1) is a host with no worktrees of the project, read as COMPLETE with
# an empty list, but ONLY when it is proven: the host answers `orca repo list`, no repo there has a
# path matching worktrees.path_match, and an unscoped worktree list is ok, whole, and has no matching
# path. Everything else stays unreachable (fail closed), with a reason: a repo that exists under another
# name, a matching worktree, a failed or hung repo list, a cut-off unscoped list, another error code,
# garbage. Stub Orca answering per --environment; synthetic hosts host-a..host-i and a synthetic path_match.
#
#   scripts/test/fleet-read.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-fleet-read.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
# Per-host answers. host-a and the local host: a normal list. host-b: no such repo, nothing matching.
# host-c: no such repo under this name, but a repo whose path matches exists under another name.
# host-d: no such repo, no matching repo, but an unscoped worktree has a matching path. host-e: repo list fails.
# host-f: another error code. host-g: garbage. host-h: unscoped list cut off. host-i: repo list hangs.
[ -z "${STUB_LOG:-}" ] || printf '%s\n' "$*" >> "$STUB_LOG"
env=""; scoped=0
for ((i = 1; i <= $#; i++)); do
  [ "${!i}" = "--environment" ] && { j=$((i + 1)); env="${!j}"; }
  [ "${!i}" = "--repo" ] && scoped=1
done
normal='{"ok":true,"result":{"worktrees":[{"path":"/w/proj-x/lane-a","displayName":"lane-a","comment":"cm:running"}]}}'
case "$1 $2" in
  "host list")
    printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}'
    for h in ${STUB_HOSTS:-host-a host-b host-c host-d host-e host-f host-g host-h host-i}; do printf ',{"kind":"environment","name":"%s"}' "$h"; done
    printf ']}}\n' ;;
  "worktree list")
    if [ "$scoped" = 1 ]; then
      case "$env" in
        ""|host-a) printf '%s\n' "$normal" ;;
        host-f) printf '%s\n' '{"ok":false,"error":{"code":"unauthorized","message":"no access"}}'; exit 1 ;;
        host-g) printf 'this is not json at all' ;;
        *) printf '%s\n' '{"ok":false,"error":{"code":"repo_not_found","message":"no repo named app-x"}}'; exit 1 ;;
      esac
    else
      case "$env" in
        host-b|host-c|host-e|host-i) printf '%s\n' '{"ok":true,"result":{"worktrees":[{"path":"/w/other/wt-1","displayName":"wt-1"}]}}' ;;
        host-d) printf '%s\n' '{"ok":true,"result":{"worktrees":[{"path":"/w/other/wt-1","displayName":"wt-1"},{"path":"/w/proj-x/lane-z","displayName":"lane-z"}]}}' ;;
        host-p) printf '%s\n' '{"ok":true,"result":{"hostScope":{"hostIds":["local"],"omittedHostIds":[]},"worktrees":[{"displayName":"no-path-row"}]}}' ;;
        host-m) printf '%s\n' '{"ok":true,"result":{"hostScope":{"hostIds":[],"omittedHostIds":[]},"worktrees":[{"path":"/w/other/wt-1","displayName":"wt-1"}]}}' ;;
        host-n) printf '%s\n' '{"ok":true,"result":{"hostScope":{"hostIds":["local"],"omittedHostIds":["ssh:ssh-1"],"omittedHostSelectors":[{"hostId":"ssh:ssh-1","selector":null}]},"worktrees":[{"path":"/w/other/wt-1","displayName":"wt-1"}]}}' ;;
        host-j) jq -cn '{ok:true,result:{worktrees:[range(500) | {path:("/w/other/wt-\(.)"), displayName:"x"}]}}' ;;
        host-h) printf '%s\n' '{"ok":true,"result":{"truncated":true,"totalCount":900,"worktrees":[{"path":"/w/other/wt-1","displayName":"wt-1"}]}}' ;;
        *) printf '%s\n' "$normal" ;;
      esac
    fi ;;
  "repo list")
    case "$env" in
      host-o) printf '%s\n' '{"ok":true,"result":{"repos":[{"id":"r4","displayName":"App-X","path":"/srv/app","kind":"git"}]}}' ;;
      host-k) printf '%s\n' '{"ok":true,"result":{"repos":[{"id":"r3","displayName":"renamed-app","path":"/w/proj-x","kind":"git"}]}}' ;;
      host-c) printf '%s\n' '{"ok":true,"result":{"repos":[{"id":"r1","displayName":"renamed-app","path":"/w/proj-x/main","kind":"git"}]}}' ;;
      host-e) printf '%s\n' '{"ok":false,"error":{"code":"internal","message":"repo store unavailable"}}'; exit 1 ;;
      host-i) exec sleep 5 ;;
      *) printf '%s\n' '{"ok":true,"result":{"repos":[{"id":"r2","displayName":"other-app","path":"/w/other/app","kind":"git"}]}}' ;;
    esac ;;
esac
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '[]'
STUB
chmod +x "$BIN/orca" "$BIN/gh"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/proj-x/", orca_repo: app-x }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_HOME="$ROOT/home" ORCA_CLI_COMMAND="$BIN/orca" PATH="$BIN:$PATH" CM_HOST_TIMEOUT=1
export STUB_LOG="$ROOT/calls.log"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH
mkdir -p "$CM_HOME"

# shellcheck source=SCRIPTDIR/../lib.sh
. "$S/lib.sh"
# shellcheck source=SCRIPTDIR/../fleet-read.sh
. "$S/fleet-read.sh"

OUT="$ROOT/out"; mkdir -p "$OUT"
cm_fleet_worktrees "$OUT"
read_hosts="$(jq -r '.host' "$OUT/hosts.ndjson" | sort | paste -sd, -)"
unreach_hosts="$(jq -r '.host' "$OUT/unreach.ndjson" | sort | paste -sd, -)"
why() { jq -r --arg h "$1" 'select(.host == $h) | .error' "$OUT/unreach.ndjson"; }

[ "$read_hosts" = "host-a,host-b,local" ] && pass "read hosts: local, host-a and host-b (repo_not_found proven absent)" || fail "hosts read" "$read_hosts"
[ "$unreach_hosts" = "host-c,host-d,host-e,host-f,host-g,host-h,host-i" ] && pass "unreachable: host-c to host-i, nothing else" || fail "unreachable" "$unreach_hosts"

f="$(jq -r 'select(.host == "host-b") | .file' "$OUT/hosts.ndjson")"
[ -n "$f" ] && jq -e '.ok == true and (.result.worktrees | type == "array") and (.result.worktrees | length == 0)' "$f" >/dev/null 2>&1 \
  && pass "host-b has a valid empty worktree list file: consumers that iterate hosts see it as complete" || fail "host-b file" "${f:-no file}"
f="$(jq -r 'select(.host == "host-a") | .file' "$OUT/hosts.ndjson")"
f2="$(jq -r 'select(.host == "host-b") | .file' "$OUT/hosts.ndjson")"
jq -e '.result.inferredEmpty == "repo_not_found"' "$f2" >/dev/null 2>&1 && pass "host-b's empty list is marked inferred (repo_not_found), host-a's is not" || fail "inferred marker" "$(cat "$f2")"
jq -e '.result.worktrees | length == 1' "$f" >/dev/null 2>&1 && pass "host-a normal list is read untouched" || fail "host-a" "$(cat "$f" 2>/dev/null)"

why host-c | grep -q '/w/proj-x/main' && pass "host-c (repo under another name): incomplete, reason names the matching repo path" || fail "host-c reason" "$(why host-c)"
why host-d | grep -q '/w/proj-x/lane-z' && pass "host-d (matching worktree in the unscoped list): incomplete, reason names the path" || fail "host-d reason" "$(why host-d)"
why host-e | grep -q 'repo list failed' && pass "host-e (repo list fails): incomplete, fail closed" || fail "host-e reason" "$(why host-e)"
why host-f | grep -q 'orca worktree list failed' && ! why host-f | grep -q 'repo list' && pass "host-f (another error code): unreachable" || fail "host-f reason" "$(why host-f)"
why host-g | grep -q 'not a worktree list' && pass "host-g (garbage): unreachable" || fail "host-g reason" "$(why host-g)"
why host-h | grep -q 'cut off' && pass "host-h (unscoped list truncated): incomplete" || fail "host-h reason" "$(why host-h)"
why host-i | grep -q 'repo list failed' && pass "host-i (repo list hangs past the timeout): incomplete" || fail "host-i reason" "$(why host-i)"

# the proof is only attempted after repo_not_found: no repo list on a normal host, or on an unauthorized or garbage one
for h in host-a host-f host-g; do
  grep -q -- "^repo list .*--environment $h\$" "$STUB_LOG" && fail "$h" "repo list was called" || pass "$h: no repo list call (only repo_not_found triggers the proof)"
done
grep -q -- '^repo list --json --environment host-b$' "$STUB_LOG" && pass "host-b: repo list called on that host" || fail "host-b call" "$(grep '^repo list' "$STUB_LOG" | tr '\n' ';')"

# a path_match that is unset cannot rule out the project under another name: fail closed on repo_not_found
OUT2="$ROOT/out2"; mkdir -p "$OUT2"
CM_PATH_MATCH="" cm_fleet_worktrees "$OUT2"
jq -e 'select(.host == "host-b") | .error | test("path_match is unset")' "$OUT2/unreach.ndjson" >/dev/null 2>&1 \
  && pass "no path_match: host-b is incomplete, not complete" || fail "no path_match" "$(cat "$OUT2/unreach.ndjson" | head -c 300)"

# host-j: repo_not_found, then an unscoped list of exactly 500 rows with no truncated flag: cut off, not complete
OUT3="$ROOT/out3"; mkdir -p "$OUT3"
STUB_HOSTS="host-j" cm_fleet_worktrees "$OUT3"
jq -e 'select(.host == "host-j") | .error | test("cut off")' "$OUT3/unreach.ndjson" >/dev/null 2>&1 \
  && pass "host-j: an unscoped list of exactly the 500-row limit is cut off, incomplete" || fail "host-j limit" "$(head -c 300 "$OUT3/unreach.ndjson")"

# host-o: a repo named like the project (case-insensitive) at a path path_match misses contradicts repo_not_found
OUT10="$ROOT/out10"; mkdir -p "$OUT10"
STUB_HOSTS="host-o" cm_fleet_worktrees "$OUT10"
jq -e 'select(.host == "host-o") | .error | test("named like the project: /srv/app")' "$OUT10/unreach.ndjson" >/dev/null 2>&1 \
  && pass "host-o: a repo named like the project is incomplete, reason names its path" || fail "host-o name" "$(head -c 300 "$OUT10/unreach.ndjson")"

# host-p: a worktree row with no path cannot be tested against path_match: a hit, whatever the pattern
OUT11="$ROOT/out11"; mkdir -p "$OUT11"
STUB_HOSTS="host-p" cm_fleet_worktrees "$OUT11"
jq -e 'select(.host == "host-p") | .error | test("row without a path")' "$OUT11/unreach.ndjson" >/dev/null 2>&1 \
  && pass "host-p: a path-less row is a hit with a realistic path_match, host incomplete" || fail "host-p empty hit" "$(head -c 300 "$OUT11/unreach.ndjson")"

# a repo checkout at a path with no trailing slash still matches a path_match that ends in "/"
OUT5="$ROOT/out5"; mkdir -p "$OUT5"
STUB_HOSTS="host-k" cm_fleet_worktrees "$OUT5"
jq -e 'select(.host == "host-k") | .error | test("/w/proj-x")' "$OUT5/unreach.ndjson" >/dev/null 2>&1 \
  && pass "host-k: a repo at /w/proj-x matches path_match /proj-x/ (trailing slash added), incomplete" || fail "host-k trailing slash" "$(head -c 300 "$OUT5/unreach.ndjson")"
# an invalid path_match regex fails closed, even over empty lists
OUT6="$ROOT/out6"; mkdir -p "$OUT6"
CM_PATH_MATCH='/proj-x/(' STUB_HOSTS="host-b" cm_fleet_worktrees "$OUT6"
jq -e 'select(.host == "host-b") | .error | test("not a valid regex")' "$OUT6/unreach.ndjson" >/dev/null 2>&1 \
  && pass "an invalid path_match regex: host-b incomplete, not complete" || fail "invalid regex" "$(head -c 300 "$OUT6/unreach.ndjson")"

# host-m: the unscoped list covered no host at all (hostScope.hostIds empty): it proves nothing about the project
OUT7="$ROOT/out7"; mkdir -p "$OUT7"
STUB_HOSTS="host-m" cm_fleet_worktrees "$OUT7"
jq -e 'select(.host == "host-m") | .error | test("did not cover the host it was asked about")' "$OUT7/unreach.ndjson" >/dev/null 2>&1 \
  && pass "host-m: an unscoped list that covered no host is incomplete" || fail "host-m uncovered" "$(head -c 300 "$OUT7/unreach.ndjson")"
# host-n: the page covers the host asked about and lists a paired server's own ssh target as omitted (selector null),
# as a real remote host does: that must not keep a project-less host unreachable
OUT9="$ROOT/out9"; mkdir -p "$OUT9"
STUB_HOSTS="host-n" cm_fleet_worktrees "$OUT9"
{ [ "$(jq -r '.host' "$OUT9/hosts.ndjson" | sort | paste -sd, -)" = "host-n,local" ] && [ ! -s "$OUT9/unreach.ndjson" ]; } \
  && pass "host-n: omitted ssh targets do not block a proven project-less host" || fail "host-n omitted" "$(head -c 300 "$OUT9/unreach.ndjson")"

# an end-anchored path_match still matches the raw repo path (the trailing-slash form alone would miss it)
OUT8="$ROOT/out8"; mkdir -p "$OUT8"
CM_PATH_MATCH='/proj-x$' STUB_HOSTS="host-k" cm_fleet_worktrees "$OUT8"
jq -e 'select(.host == "host-k") | .error | test("/w/proj-x")' "$OUT8/unreach.ndjson" >/dev/null 2>&1 \
  && pass "path_match /proj-x\$ matches the raw repo path: host-k incomplete" || fail "anchored path_match" "$(head -c 300 "$OUT8/unreach.ndjson")"

# the reader needs no pipefail in the caller (it turns it on) and puts the caller's setting back
OUT4="$ROOT/out4"; mkdir -p "$OUT4"
RESTORED="$( set +o pipefail; cm_fleet_worktrees "$OUT4"; [[ ":$SHELLOPTS:" != *:pipefail:* ]] && echo off || echo on )"
{ [ "$RESTORED" = off ] && [ "$(jq -r '.host' "$OUT4/hosts.ndjson" | sort | paste -sd, -)" = "host-a,host-b,local" ]; } \
  && pass "no pipefail in the caller: hosts still read correctly, and the caller's setting is restored" || fail "pipefail local" "restored=$RESTORED $(jq -r '.host' "$OUT4/hosts.ndjson" | paste -sd, -)"

# queue-audit.sh parses its own scoped list: the same rule. An old granted item with no PR and no comment is
# STALLED when every host was read (host-b counts as read) and UNVERIFIED when one host was not (host-c).
cat > "$CM_HOME/ledger.json" <<'LEDGER'
{"queue":{"items":[{"id":"q-1","issue":41,"lane":"lane-a","state":"granted","grantedAt":"2020-01-01T00:00:00Z"}]}}
LEDGER
QA="$(STUB_HOSTS="host-a host-b" "$S/queue-audit.sh" 2>"$ROOT/qa1.err")"
grep -Eq '^STALLED +q-1' <<<"$QA" && ! grep -q 'unread' "$ROOT/qa1.err" \
  && pass "queue-audit: host-b (repo_not_found, proven absent) is read, so the idle item is STALLED" || fail "queue-audit host-b" "$QA / $(cat "$ROOT/qa1.err")"
QA="$(STUB_HOSTS="host-a host-c" "$S/queue-audit.sh" 2>"$ROOT/qa2.err")"
grep -Eq '^UNVERIFIED +q-1' <<<"$QA" && grep -q 'unread: host-c' "$ROOT/qa2.err" && grep -q '/w/proj-x/main' "$ROOT/qa2.err" \
  && pass "queue-audit: host-c (repo under another name) is unread, so the idle item is UNVERIFIED, reason names the path" || fail "queue-audit host-c" "$QA / $(cat "$ROOT/qa2.err")"

printf '%s\n' "fleet-read: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
