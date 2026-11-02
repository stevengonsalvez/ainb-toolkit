#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC1091  # check bodies are single-quoted on purpose: they are eval-ed later
# ledger-guard.sh (test): a ledger of another project is never read or written. Evidence:
# CM_HOME leaked in from a second project's session on a shared host and teardown.sh read that
# project's ledger. Synthetic projects project-a (this one) and project-b. Covers: a project field
# mismatch is refused, a foreign path without a field is refused, a matching field is accepted, a
# legacy unstamped ledger in the default state dir is accepted with a warning and is not rewritten,
# cm_ledger_write stamps the project and refuses a foreign ledger (file untouched), --init stamps
# and refuses a foreign location, classify.sh and discover.sh refuse or skip a foreign ledger, and no
# project id configured means no judgement. (teardown.sh is covered in teardown-gates.sh.)
# Touches only a mktemp dir.
#
#   scripts/test/ledger-guard.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-ledgerguard.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_LEDGER CM_PROJECT_ID
export HOME="$ROOT/home"
MINE="$HOME/.concertmaster"            # project-a's default state dir (no state_dir in the test config)
OTHER="$HOME/.concertmaster-project-b" # the other project's state dir on the same host
mkdir -p "$MINE" "$OTHER"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1"; fi; }
GUARD="$SCRIPTS/ledger-guard.sh"
ledger() { printf '%s\n' "$2" > "$1/ledger.json"; }       # ledger <dir> <json>
guard() { CM_PROJECT_ID="${PID-project-a}" CM_HOME="$1" "$GUARD" 2>"$ROOT/err"; }   # guard <dir>
W='"workers": {"w": {"host": "local", "path": "/x/lane-a", "standing": false}}'

# ---- the field -------------------------------------------------------------------------------------------
ledger "$OTHER" "{\"project\": \"project-b\", $W}"
guard "$OTHER"; RC=$?
check "field mismatch: refused with exit 3"                      '[ "$RC" = 3 ]'
check "the refusal names the ledger's project and the running one" 'grep -q "belongs to project .project-b.; this session runs project .project-a." "$ROOT/err"'
check "the refusal says nothing was read or written"              'grep -q "Nothing was read or written" "$ROOT/err"'
ledger "$MINE" "{\"project\": \"project-b\", $W}"
guard "$MINE"; RC=$?
check "field mismatch is refused even inside this project's state dir" '[ "$RC" = 3 ]'
ledger "$OTHER" "{\"project\": \"Project-A\", $W}"
guard "$OTHER"; RC=$?
check "matching field (case-insensitive) is accepted at any path"  '[ "$RC" = 0 ]'

# ---- the path --------------------------------------------------------------------------------------------
ledger "$OTHER" "{$W}"
guard "$OTHER"; RC=$?
check "no field, path outside this project's state dir: refused"   '[ "$RC" = 3 ]'
check "the path refusal says how to proceed"                       'grep -q "sits outside this project.s state dir" "$ROOT/err" && grep -q "copy it to $MINE/ledger.json" "$ROOT/err"'
check "the foreign file is untouched"                              '[ "$(jq -c . "$OTHER/ledger.json")" = "{\"workers\":{\"w\":{\"host\":\"local\",\"path\":\"/x/lane-a\",\"standing\":false}}}" ]'
ledger "$MINE" "{$W}"
guard "$MINE"; RC=$?
check "legacy unstamped ledger in the state dir: accepted"         '[ "$RC" = 0 ]'
check "legacy ledger: a warning says it is unstamped"              'grep -q "has no project field (legacy file)" "$ROOT/err"'
check "legacy ledger: the guard never rewrites it"                 '! jq -e ".project" "$MINE/ledger.json" >/dev/null 2>&1'
ln -s "$OTHER" "$ROOT/link"
ledger "$OTHER" "{$W}"
guard "$ROOT/link"; RC=$?
check "a symlink to a foreign dir is judged by where it lands"     '[ "$RC" = 3 ]'
guard "$ROOT/none"; RC=$?
check "no ledger yet: nothing to judge"                            '[ "$RC" = 0 ]'
PID="" guard "$OTHER"; RC=$?
check "no project id configured: no judgement (legacy configs)"    '[ "$RC" = 0 ]'
check "CM_LEDGER pointing at a foreign file is judged"             '(CM_PROJECT_ID=project-a CM_HOME="$MINE" CM_LEDGER="$OTHER/ledger.json" "$GUARD" 2>/dev/null; [ $? = 3 ])'
cat > "$ROOT/withid.yaml" <<'Y'
schema: concertmaster.config/v1
project: { name: Acme, id: project-a }
github: { org: AcmeOrg, main_repo: acme-app }
Y
check "project.id from the config is the project's id"             '(CM_CONFIG="$ROOT/withid.yaml" CM_HOME="$OTHER" "$GUARD" 2>/dev/null; [ $? = 3 ])'

# ---- writes ----------------------------------------------------------------------------------------------
wr() { # wr <dir> [args]: cm_ledger_write in a subshell as project-a
  ( export CM_PROJECT_ID=project-a CM_HOME="$1"; shift; . "$SCRIPTS/lib.sh"; cm_ledger_write "$@" ) 2>"$ROOT/err"
}
ledger "$OTHER" "{\"project\": \"project-b\", $W}"; BEFORE="$(cat "$OTHER/ledger.json")"
wr "$OTHER" '.touched = true'; RC=$?
check "cm_ledger_write on a foreign ledger: refused, exit 3"       '[ "$RC" = 3 ]'
check "cm_ledger_write on a foreign ledger: file untouched, no backup" '[ "$(cat "$OTHER/ledger.json")" = "$BEFORE" ] && [ ! -d "$OTHER/ledger.bak" ]'
ledger "$MINE" "{$W}"
wr "$MINE" '.touched = true'; RC=$?
check "cm_ledger_write on a legacy ledger in the state dir: ok"    '[ "$RC" = 0 ]'
check "the write stamped the project"                              '[ "$(jq -r .project "$MINE/ledger.json")" = project-a ] && [ "$(jq -r .touched "$MINE/ledger.json")" = true ]'
wr "$MINE" '.again = true'; RC=$?
check "a stamped ledger is written as before"                      '[ "$RC" = 0 ] && [ "$(jq -r .project "$MINE/ledger.json")" = project-a ]'
rm -rf -- "${MINE:?}"/ledger.json "${MINE:?}"/ledger.bak
wr "$MINE" --init '{schema: "concertmaster.ledger/v1", workers: {}}'; RC=$?
check "--init in the state dir stamps the project"                 '[ "$RC" = 0 ] && [ "$(jq -r .project "$MINE/ledger.json")" = project-a ]'
NEW="$ROOT/elsewhere"; mkdir -p "$NEW"
wr "$NEW" --init '{schema: "concertmaster.ledger/v1", workers: {}}'; RC=$?
check "--init outside the state dir: refused, nothing created"     '[ "$RC" = 3 ] && [ ! -e "$NEW/ledger.json" ] && grep -q "would be created" "$ROOT/err"'

# ---- readers ---------------------------------------------------------------------------------------------
printf '{"generatedAtMs": 1, "hosts": [], "worktrees": []}\n' > "$ROOT/doc.json"
ledger "$OTHER" "{\"project\": \"project-b\", $W}"
OUT="$(CM_PROJECT_ID=project-a CM_HOME="$OTHER" "$SCRIPTS/classify.sh" < "$ROOT/doc.json" 2>"$ROOT/err")"; RC=$?
check "classify.sh with a foreign ledger: exit 3, no output"       '[ "$RC" = 3 ] && [ -z "$OUT" ] && grep -q "belongs to project .project-b." "$ROOT/err"'
ledger "$MINE" "{\"project\": \"project-a\", $W}"
OUT="$(CM_PROJECT_ID=project-a CM_HOME="$MINE" "$SCRIPTS/classify.sh" < "$ROOT/doc.json" 2>/dev/null)"; RC=$?
check "classify.sh with this project's ledger runs"                '[ "$RC" = 0 ] && printf "%s" "$OUT" | jq -e ".schema == \"concertmaster.classify/v1\"" >/dev/null'
# discover: the ledger is only read when `orca host list` fails; a foreign one is skipped, not read.
mkdir -p "$ROOT/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/bin/orca"; chmod +x "$ROOT/bin/orca"
mkdir -p "$OTHER/cache"; printf '[{"name":"acme-app"}]\n' > "$OTHER/cache/org-repos.json"
ledger "$OTHER" "{\"project\": \"project-b\", \"hosts\": {\"host-z\": {\"kind\": \"environment\"}}, $W}"
DOC="$(CM_PROJECT_ID=project-a CM_HOME="$OTHER" ORCA_CLI_COMMAND="$ROOT/bin/orca" "$SCRIPTS/discover.sh" --no-prs 2>/dev/null)"
check "discover.sh does not take hosts from a foreign ledger"      'printf "%s" "$DOC" | jq -e "[.hosts[].name] | index(\"host-z\") == null" >/dev/null'
check "discover.sh records the refusal as an error row"            'printf "%s" "$DOC" | jq -e "[.errors[] | select(.where == \"ledger\" and (.message | test(\"not this project\"))) ] | length == 1" >/dev/null'

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
