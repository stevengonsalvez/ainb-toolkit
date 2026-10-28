#!/usr/bin/env bash
# queue-audit.sh test: stubbed gh and Orca CLI, a fixture ledger. Asserts: a PR or a worktree comment
# naming the issue makes an item OK, neither after the stall window is STALLED, a young item is OK, no
# issue is NO-ISSUE, no timestamp is UNKNOWN-AGE, an unreadable host turns STALLED into UNVERIFIED, and a
# failed gh call prints STALE and exits 3.
#
#   scripts/test/queue-audit.sh        # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/queue-audit.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-queue-audit.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home"
cat > "$ROOT/bin/gh" <<'S'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && exit 1
echo '[{"number":90001,"title":"fix #101","body":"","state":"OPEN","createdAt":"2099-01-01T00:00:00Z"}]'
S
cat > "$ROOT/bin/orca" <<'S'
#!/usr/bin/env bash
case "$*" in
  "host list"*) echo '{"result":{"hosts":[]}}' ;;
  "worktree list"*) [ -n "${ORCA_FAIL:-}" ] && exit 1
    echo '{"result":{"worktrees":[{"path":"/w/acme-app/wt-a","comment":"working on #102"}]}}' ;;
esac
S
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca"
export PATH="$ROOT/bin:$PATH" CM_HOME="$ROOT/home" HOME="$ROOT/home" CM_CONFIG=/nonexistent
export CM_ORG=AcmeOrg CM_REPO=acme-app CM_PATH_MATCH=/acme-app/ ORCA_CLI_COMMAND="$ROOT/bin/orca"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; old="$(jq -nr 'now - 7200 | todate')"
cat > "$CM_HOME/ledger.json" <<J
{"workers":{},"queue":{"items":[
 {"id":"q-1","issue":101,"lane":"dev-sweeper","state":"granted","grantedAt":"$old"},
 {"id":"q-2","issue":102,"lane":"dev-sweeper","state":"granted","grantedAt":"$old"},
 {"id":"q-3","issue":103,"lane":"dev-sweeper","state":"queued","addedAt":"$old"},
 {"id":"q-4","issue":104,"lane":"dev-sweeper","state":"queued","addedAt":"$now"},
 {"id":"q-5","lane":"dev-sweeper","state":"queued","addedAt":"$old"},
 {"id":"q-6","issue":105,"lane":"dev-sweeper","state":"queued"},
 {"id":"q-7","issue":106,"lane":"dev-sweeper","state":"done","addedAt":"$old"}]}}
J
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
flag() { awk -v id="$1" '$2 == id { print $1 }'; }
OUT="$("$SCRIPT" 2>/dev/null)"; RC=$?
check "exit 0" "$RC" "0"
check "a PR naming the issue: OK" "$(printf '%s\n' "$OUT" | flag q-1)" "OK"
check "a worktree comment naming the issue: OK" "$(printf '%s\n' "$OUT" | flag q-2)" "OK"
check "neither after the window: STALLED" "$(printf '%s\n' "$OUT" | flag q-3)" "STALLED"
check "a young item: OK" "$(printf '%s\n' "$OUT" | flag q-4)" "OK"
check "no issue: NO-ISSUE" "$(printf '%s\n' "$OUT" | flag q-5)" "NO-ISSUE"
check "no timestamp: UNKNOWN-AGE" "$(printf '%s\n' "$OUT" | flag q-6)" "UNKNOWN-AGE"
check "a closed item is not audited" "$(printf '%s\n' "$OUT" | flag q-7)" ""
OUT="$(ORCA_FAIL=1 "$SCRIPT" 2>"$ROOT/err")"
check "unread host: STALLED becomes UNVERIFIED" "$(printf '%s\n' "$OUT" | flag q-3)" "UNVERIFIED"
check "unread host: listed on stderr" "$(grep -c '^unread: local$' "$ROOT/err")" "1"
check "a PR still makes it OK with an unread host" "$(printf '%s\n' "$OUT" | flag q-1)" "OK"
OUT="$(GH_FAIL=1 "$SCRIPT" 2>/dev/null)"; RC=$?
check "gh failure: STALE line" "$OUT" "STALE gh call failed, no verdicts"
check "gh failure: exit 3" "$RC" "3"
rm -f "$CM_HOME/ledger.json"
check "no ledger: exit 2" "$("$SCRIPT" >/dev/null 2>&1; echo $?)" "2"
[ "$fail" = 0 ]
