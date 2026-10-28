#!/usr/bin/env bash
# classify-violations.sh: tests for the forbidden-agent census (config agents.forbidden, here
# [codex]). Runs discover.sh against a STUBBED orca (two hosts, local and host-b), pipes it
# through classify.sh, and checks that a forbidden-agent terminal under worktrees.path_match
# becomes a VIOLATION row (agent, host, worktree, handle, title) and a claude, shell or
# out-of-scope one does not. Also checks the incomplete-check paths: an offline host, a host
# whose terminal list fails or is cut off, and a discover document with no terminal data must
# never read as "no violations"; and that an empty agents.forbidden turns the census off.
# Touches nothing outside a mktemp dir. No real orca, no network.
#
#   scripts/test/classify-violations.sh         # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_FORBIDDEN_AGENTS
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-violations.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
# Hermetic config: the shared test fixture (path_match "/acme/", org AcmeOrg) plus agents.forbidden.
{ cat "$HERE/fixtures/config.test.yaml"; printf 'agents:\n  forbidden: [codex]\n'; } > "$ROOT/config.yaml"
export CM_CONFIG="$ROOT/config.yaml"
export CM_HOME="$ROOT/home" STUB_DIR="$ROOT/stub"
mkdir -p "$CM_HOME/cache" "$STUB_DIR"
printf '[{"name":"acme-app","isArchived":false}]\n' > "$CM_HOME/cache/org-repos.json"   # fresh: no gh call

# Stub orca. Local and host-b each have worktrees and a terminal list from files in $STUB_DIR;
# a host listed in $STUB_DIR/term-fail answers `terminal list` with an error.
cat > "$ROOT/orca-stub" <<'S'
#!/usr/bin/env bash
host=local
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "--environment" ] && host="${args[$((i + 1))]}"; done
case "$1 $2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"},{"kind":"environment","name":"host-b"}]}}\n' ;;
  "worktree ps")
    if [ -e "$STUB_DIR/ps-fail-$host" ]; then echo '{"ok":false,"error":{"message":"down"}}'; exit 1; fi
    cat "$STUB_DIR/ps-$host.json" ;;
  "terminal list")
    if [ -e "$STUB_DIR/term-fail-$host" ]; then echo '{"ok":false,"error":{"message":"boom"}}'; exit 1; fi
    if [ -e "$STUB_DIR/term-trunc-$host" ]; then jq '.result.truncated = true' "$STUB_DIR/terms-$host.json"; exit 0; fi
    cat "$STUB_DIR/terms-$host.json" ;;
  *) echo "stub: unhandled $*" >&2; exit 2 ;;
esac
S
chmod +x "$ROOT/orca-stub"
export ORCA_CLI_COMMAND="$ROOT/orca-stub"

wtrow() { # wtrow <path>: a minimal Orca worktree row of the org repo
  jq -cn --arg p "$1" '{path: $p, repo: "acme-app", branch: "refs/heads/x", displayName: ($p | split("/") | last), agents: [], liveTerminalCount: 1}'
}
for h in local host-b; do
  { wtrow "/nonexistent/acme/claude-lane-$h"; wtrow "/nonexistent/acme/codex-lane-$h"; } \
    | jq -s '{ok: true, result: {worktrees: ., totalCount: length}}' > "$STUB_DIR/ps-$h.json"
done
term() { jq -cn --arg h "$1" --arg p "$2" --arg t "$3" --arg a "$4" \
  '{handle: $h, worktreePath: $p, worktreeId: ("r::" + $p), title: $t, agentIdentity: (if $a == "" then null else $a end)}'; }
{
  term t_local_claude /nonexistent/acme/claude-lane-local "resumed claude" claude
  term t_local_codex  /nonexistent/acme/codex-lane-local  "resumed codex"  codex
  term t_local_shell  /nonexistent/acme/claude-lane-local "zsh" ""
  term t_local_other  /nonexistent/otherproject/codex-x   "resumed codex"  codex   # out of scope: never listed
} | jq -s '{ok: true, result: {terminals: .}}' > "$STUB_DIR/terms-local.json"
{
  term t_hostb_claude /nonexistent/acme/claude-lane-host-b "resumed claude" claude
  term t_hostb_codex1 /nonexistent/acme/codex-lane-host-b  "resumed codex"  codex
  term t_hostb_codex2 /nonexistent/acme/codex-lane-host-b  "second codex"   Codex
} | jq -s '{ok: true, result: {terminals: .}}' > "$STUB_DIR/terms-host-b.json"

PASS=0; FAIL=0
check() { # check <label> <command...>: passes when the command succeeds
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"; else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$label"; fi
}
q() { printf '%s' "$OUT" | jq -r "$1"; }
gcount() { grep -c "$1" <<<"$2" || true; }   # count lines matching, 0 included

"$HERE/../discover.sh" --no-prs > "$ROOT/discover.json" 2>"$ROOT/discover.err" || { echo "discover.sh failed"; cat "$ROOT/discover.err"; exit 1; }
OUT="$("$HERE/../classify.sh" < "$ROOT/discover.json" 2>/dev/null)" || { echo "classify.sh failed"; exit 1; }

check "discover keeps in-scope terminals only (6 of 7)" test "$(jq '.terminals | length' "$ROOT/discover.json")" = 6
check "codex terminals give 3 violation rows (local, host-b x2)" test "$(q '.violations | length')" = 3
check "local codex row carries host, worktree, handle, title" \
  test "$(q '.violations[] | select(.handle == "t_local_codex") | [.host, .worktree, .title] | join("|")')" = "local|codex-lane-local|resumed codex"
check "remote host codex row names the remote host" \
  test "$(q '.violations[] | select(.handle == "t_hostb_codex1") | [.host, .worktree] | join("|")')" = "host-b|codex-lane-host-b"
check "agentIdentity match ignores case (Codex)" test "$(q '[.violations[] | select(.handle == "t_hostb_codex2")] | length')" = 1
check "claude terminals give no violation row" test "$(q '[.violations[] | select(.handle | test("claude"))] | length')" = 0
check "a shell terminal gives no violation row" test "$(q '[.violations[] | select(.handle == "t_local_shell")] | length')" = 0
check "codex terminal outside path_match gives no violation row" \
  test "$(q '[.violations[] | select(.handle == "t_local_other")] | length')" = 0
check "every reachable host listed: check complete" test "$(q '.violationCheck.complete')" = true

TABLE="$("$HERE/../classify.sh" --table < "$ROOT/discover.json" 2>/dev/null)"
check "--table prints the violation count" grep -q '^violations: 3$' <<<"$TABLE"
check "--table prints a VIOLATION row with host, worktree, handle, title" \
  grep -qE '^VIOLATION +codex +local +codex-lane-local +t_local_codex +resumed codex$' <<<"$TABLE"
check "--table prints no VIOLATION row for a claude terminal" test "$(gcount '^VIOLATION.*claude-lane' "$TABLE")" = 0

# Claude-only census: no violations, no VIOLATION row.
term t_c /nonexistent/acme/claude-lane-local "resumed claude" claude | jq -s '{ok: true, result: {terminals: .}}' > "$STUB_DIR/terms-local.json"
term t_d /nonexistent/acme/claude-lane-host-b "resumed claude" claude | jq -s '{ok: true, result: {terminals: .}}' > "$STUB_DIR/terms-host-b.json"
"$HERE/../discover.sh" --no-prs > "$ROOT/discover2.json" 2>/dev/null
OUT="$("$HERE/../classify.sh" < "$ROOT/discover2.json" 2>/dev/null)"
check "claude-only census: zero violations" test "$(q '.violations | length')" = 0
check "claude-only census: check complete" test "$(q '.violationCheck.complete')" = true
TABLE="$("$HERE/../classify.sh" --table < "$ROOT/discover2.json" 2>/dev/null)"
check "claude-only --table: 'violations: 0'" grep -q '^violations: 0$' <<<"$TABLE"
check "claude-only --table: no VIOLATION row" test "$(gcount '^VIOLATION' "$TABLE")" = 0

# A host whose terminal list fails: the check is incomplete and says which host, never "none".
: > "$STUB_DIR/term-fail-host-b"
"$HERE/../discover.sh" --no-prs > "$ROOT/discover3.json" 2>/dev/null
OUT="$("$HERE/../classify.sh" < "$ROOT/discover3.json" 2>/dev/null)"
check "failed terminal list: check incomplete" test "$(q '.violationCheck.complete')" = false
check "failed terminal list: the gap names the host" test "$(q '.violationCheck.gaps[0] | startswith("host-b:")')" = true
TABLE="$("$HERE/../classify.sh" --table < "$ROOT/discover3.json" 2>/dev/null)"
check "failed terminal list: --table says CHECK INCOMPLETE" grep -q '^violations: 0 (CHECK INCOMPLETE: host-b:' <<<"$TABLE"

# A cut-off terminal list (truncated:true) is incomplete too, never "none".
rm -f "$STUB_DIR/term-fail-host-b"; term t_trunc_codex /nonexistent/acme/codex-lane-host-b "resumed codex" codex | jq -s '{ok: true, result: {terminals: .}}' > "$STUB_DIR/terms-host-b.json"
: > "$STUB_DIR/term-trunc-host-b"
"$HERE/../discover.sh" --no-prs > "$ROOT/discover4.json" 2>/dev/null
OUT="$("$HERE/../classify.sh" < "$ROOT/discover4.json" 2>/dev/null)"
check "truncated terminal list: check incomplete, names the host" test "$(q '.violationCheck.complete')/$(q '.violationCheck.gaps[0] | startswith("host-b:")')" = false/true
check "truncated list: the codex row already listed is kept" test "$(q '[.violations[] | select(.handle == "t_trunc_codex")] | length')" = 1
rm -f "$STUB_DIR/term-trunc-host-b"

# An offline host (worktree ps fails) leaves its terminals unlisted: incomplete, never "none".
: > "$STUB_DIR/ps-fail-host-b"
"$HERE/../discover.sh" --no-prs > "$ROOT/discover5.json" 2>/dev/null
OUT="$("$HERE/../classify.sh" < "$ROOT/discover5.json" 2>/dev/null)"
check "offline host: check incomplete, names the host" test "$(q '.violationCheck.complete')/$(q '.violationCheck.gaps | join(" ") | contains("host-b: host offline")')" = false/true
rm -f "$STUB_DIR/ps-fail-host-b"

# Odd terminal data: a non-string agentIdentity must not break classify; a "resumed codex" title with no
# identity yet still counts.
OUT="$(jq '.terminals += [{host:"local",handle:"t_odd",worktreePath:"/nonexistent/acme/x",title:"odd",agentIdentity:{"a":1}},
                          {host:"local",handle:"t_title",worktreePath:"/nonexistent/acme/y",title:"resumed codex",agentIdentity:null}]' "$ROOT/discover2.json" \
  | "$HERE/../classify.sh" 2>/dev/null)"
check "non-string agentIdentity: classify still runs, no row for it" test "$(q '[.violations[] | select(.handle == "t_odd")] | length')" = 0
check "title 'resumed codex' with no agentIdentity: violation row" test "$(q '[.violations[] | select(.handle == "t_title")] | length')" = 1

# A discover document with no terminal data (older discover.sh) is never "no violations".
OUT="$(jq 'del(.terminals, .terminalScope)' "$ROOT/discover2.json" | "$HERE/../classify.sh" 2>/dev/null)"
check "document without terminal data: check incomplete" test "$(q '.violationCheck.complete')" = false

# Census off: with agents.forbidden empty discover lists no terminals and classify reports the
# check as off, not as "complete, none found".
sed '/^agents:/,$d' "$ROOT/config.yaml" > "$ROOT/config-off.yaml"
OUT="$(CM_CONFIG="$ROOT/config-off.yaml" "$HERE/../discover.sh" --no-prs 2>/dev/null | CM_CONFIG="$ROOT/config-off.yaml" "$HERE/../classify.sh" 2>/dev/null)"
check "agents.forbidden empty: census disabled, no violation rows" test "$(q '.violationCheck.enabled')/$(q '.violations | length')" = false/0
TABLE="$(CM_CONFIG="$ROOT/config-off.yaml" "$HERE/../classify.sh" --table < "$ROOT/discover2.json" 2>/dev/null)"
check "agents.forbidden empty: --table says violations: off" grep -q '^violations: off' <<<"$TABLE"
# Env override beats the file.
OUT="$(CM_FORBIDDEN_AGENTS="agy" "$HERE/../classify.sh" < "$ROOT/discover2.json" 2>/dev/null)"
check "CM_FORBIDDEN_AGENTS overrides the config list" test "$(q '.violationCheck.forbidden | join(",")')" = agy

# Digest: ledger.violations rows are listed; a complete empty check adds no section.
printf '{"workers":{},"violations":[{"agent":"codex","host":"host-b","worktree":"codex-lane-host-b","handle":"t_hostb_codex1","title":"resumed codex"}]}\n' > "$ROOT/ledger-v.json"
DIG="$("$HERE/../digest.sh" --full --ledger "$ROOT/ledger-v.json" 2>/dev/null)"
check "digest lists the violation section" grep -q '^Forbidden agents on Acme work (1)$' <<<"$DIG"
check "digest lists the violation row" grep -q '^- codex host-b codex-lane-host-b t_hostb_codex1 resumed codex$' <<<"$DIG"
GRP="$("$HERE/../digest.sh" --ledger "$ROOT/ledger-v.json" 2>/dev/null)"
check "the default (group) digest never lists a forbidden agent, host or handle" test "$(gcount 'Forbidden agents|host-b|t_hostb_codex1' "$GRP")" = 0
printf '{"workers":{},"violations":[],"violationCheck":{"enabled":true,"complete":false,"gaps":["host-b: host offline, terminals not listed"],"checkedAt":"2026-10-24T16:00:00Z"}}\n' > "$ROOT/ledger-i.json"
DIG="$("$HERE/../digest.sh" --full --ledger "$ROOT/ledger-i.json" 2>/dev/null)"
check "digest with an incomplete check says CHECK INCOMPLETE" grep -q '^- CHECK INCOMPLETE, not proof of none: host-b: host offline' <<<"$DIG"
printf '{"workers":{},"violations":[],"violationCheck":{"enabled":true,"complete":true,"gaps":[],"checkedAt":"2026-10-24T16:00:00Z"}}\n' > "$ROOT/ledger-n.json"
DIG="$("$HERE/../digest.sh" --full --ledger "$ROOT/ledger-n.json" 2>/dev/null)"
check "digest with no violations has no forbidden-agents section" test "$(gcount 'Forbidden agents' "$DIG")" = 0
printf '{"workers":{},"violations":[],"violationCheck":{"enabled":false,"complete":true,"gaps":[]}}\n' > "$ROOT/ledger-o.json"
DIG="$("$HERE/../digest.sh" --full --ledger "$ROOT/ledger-o.json" 2>/dev/null)"
check "digest with the census off has no forbidden-agents section" test "$(gcount 'Forbidden agents' "$DIG")" = 0

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
