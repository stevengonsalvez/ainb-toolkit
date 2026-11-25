#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# digest-report-shape.sh (test): the report shape of report shape. digest.sh --full carries "Blocked on you" (only the
# owner's items: every open ledger ask that ask_owner_why in scripts/ask-deny.sh calls owner-only, the same set
# scripts/stall.sh exempts as Blocked, checked here against stall.sh itself; secrets always, production and test alike;
# an own-scope ask that names an owner-only subject; every cm:blocked, cm:waiting-owner and cm:waiting-owner lane line
# on every host, a cm:ask in the concertmaster's own worktree, ledger workers blocked-on-owner), "Decided while you were
# away" (ledger decisions[], at least the last 12 hours), and the Programmes and Census files the tick writes. An empty
# section prints "none" and never disappears. A host not read is not a Blocked row: it is listed under Fleet health
# (a Moved this tick row in the tick report) and the Blocked heading counts it, never read as none. The group text
# gains none of these sections and is the same whatever they hold. Last, SKILL.md names the two tables.
# gh and the fleet CLI are PATH stubs answering from files: no network, no real CLI, no send. Synthetic names only.
#
#   scripts/test/digest-report-shape.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../digest.sh"
SK="$HERE/../../SKILL.md"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-digest-shape.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
STUB="$ROOT/stub"
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/cm" "$STUB"
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT CM_DIGEST_GH_TIMEOUT CM_TZ CM_TZ_LABEL CM_NEVER_TOUCH CM_ORCA_REPO CM_PATH_MATCH CM_SELF_WORKTREE CM_EXTRA_REPOS
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" STUB_DIR="$STUB" PATH="$ROOT/bin:$PATH"
cp "$HERE/fixtures/config.test.yaml" "$ROOT/config.yaml"
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
L="$ROOT/cm/ledger.json"

# gh stub: `gh pr list --state merged|open` answers from $STUB/<state>.json.
cat > "$ROOT/bin/gh" <<'S'
#!/usr/bin/env bash
state=""
while [ $# -gt 0 ]; do case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac; done
[ -f "$STUB_DIR/$state.json" ] && cat "$STUB_DIR/$state.json"
exit 0
S
# Fleet CLI stub: three hosts, host-b unreachable. $STUB/cli.rc makes every call fail (the CLI is down).
cat > "$ROOT/bin/orca" <<'S'
#!/usr/bin/env bash
[ -f "$STUB_DIR/cli.rc" ] && { echo "fleet cli stub: down" >&2; exit "$(cat "$STUB_DIR/cli.rc")"; }
env=""
for ((i = 1; i <= $#; i++)); do [ "${!i}" = "--environment" ] && { j=$((i + 1)); env="${!j}"; }; done
case "$1 $2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"},{"kind":"environment","name":"host-a"},{"kind":"environment","name":"host-b"}]}}' ;;
  "worktree list")
    case "$env" in
      "") printf '%s' '{"ok":true,"result":{"worktrees":[
          {"path":"/w/acme/lane-blk","displayName":"lane-blk","comment":"cm:running build\ncm:blocked which table holds the backfill? | cm:note x"},
          {"path":"/w/acme/lane-run","displayName":"lane-run","comment":"cm:running\ncm:ask a lane question the lane answers"},
          {"path":"/w/acme/lane-pipe","displayName":"lane-pipe","comment":"cm:waiting-owner interview Q4|Q5 club scope"},
          {"path":"/w/acme/lane-gone","displayName":"lane-gone","comment":"cm:merged #9 abc\ncm:blocked old blocker on a finished lane"},
          {"path":"/w/acme/concertmaster","displayName":"concertmaster","comment":"cm:running tick\ncm:ask define the lease of the test tenant"}
        ]}}' ;;
      host-a) printf '%s' '{"ok":true,"result":{"worktrees":[
          {"path":"/w/acme/lane-wo","displayName":"lane-wo","comment":"cm:merge-ready #7 0123456789ab | cm:waiting-owner flip the flag? (recommend yes)"}
        ]}}' ;;
      host-b) echo "host unreachable" >&2; exit 1 ;;
    esac ;;
esac
S
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca"
export ORCA_CLI_COMMAND="$ROOT/bin/orca" PLUGLY_CLI_COMMAND="$ROOT/bin/orca"

PASS=0; FAIL=0
has() { case "$2" in *"$3"*) PASS=$((PASS + 1)); printf 'PASS %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s: "%s" not in:\n%s\n' "$1" "$3" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) FAIL=$((FAIL + 1)); printf 'FAIL %s: "%s" found in:\n%s\n' "$1" "$3" "$2" ;; *) PASS=$((PASS + 1)); printf 'PASS %s\n' "$1" ;; esac; }
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }
# The template keeps an ask with no issue number with the owner (a verdict needs an issue to be recorded on), so an ask a case
# means to be own-scope carries one: fixl gives every code, design, test, scope or product ask with no issue the number 900,
# in the ledger $L, before a script reads it.
fixl() {
  [ -f "$L" ] || return 0
  jq 'if type == "object" and has("asks") then .asks |= (if type == "array" then map(if type == "object" and .issue == null and (.kind | type == "string") and ((.kind | ascii_downcase | gsub("^\\s+|\\s+$"; "")) | IN("code", "design", "test", "scope", "product")) then . + {issue: 900} else . end) else . end) else . end' "$L" > "$L.fx" 2>/dev/null && mv "$L.fx" "$L"
}
run() { fixl; "$SCRIPT" "$@" 2>"$ROOT/err"; }
sec() { printf '%s\n' "$1" | sed -n "/^$2/,/^\$/p"; }   # one section: its heading line to the next blank line
ago() { jq -nr --argjson h "$1" 'now - $h * 3600 | floor | todate'; }
printf '[]' > "$STUB/merged.json"; printf '[]' > "$STUB/open.json"

base_ledger() { jq -n --arg sent "$(ago "$1")" '{schema: "concertmaster.ledger/v1", workers: {}, prs: {}, digests: {lastSentAt: $sent}}' > "$L"; }

# 1. empty: both sections print one "none" line, never disappear -----------------------------------------------------
base_ledger 2
touch "$STUB/cli.rc"; printf '1' > "$STUB/cli.rc"
OUT="$(run --full)"; RC=$?
check "empty: exit 0" "$RC" "0"
has "empty: Decided heading with its window" "$OUT" "Decided while you were away (0, last 12h)"
check "empty: Decided prints one none line" "$(sec "$OUT" 'Decided while you were away (0' | sed -n '2p')" "- none"
check "fleet CLI down: Blocked says none read and counts the host, never none" "$(sec "$OUT" 'Blocked on you' | sed -n '1,2p' | tr '\n' '|')" "Blocked on you (0, 2 hosts not read, see Fleet health)|- none read|"
lacks "fleet CLI down: the unread host is no Blocked row" "$(sec "$OUT" 'Blocked on you')" "- host not read"
has "fleet CLI down: the local host is listed as not read under Fleet health" "$(sec "$OUT" 'Fleet health')" "- host not read: local ("
rm -f -- "$STUB/cli.rc"
# a quiet fleet: one local host, one running lane, nothing blocked
cat > "$ROOT/bin/orca-quiet" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") printf '%s' '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}]}}' ;;
  "worktree list") printf '%s' '{"ok":true,"result":{"worktrees":[{"path":"/w/acme/lane-q","displayName":"lane-q","comment":"cm:running quiet"}]}}' ;;
esac
S
chmod +x "$ROOT/bin/orca-quiet"
OUT="$(ORCA_CLI_COMMAND="$ROOT/bin/orca-quiet" PLUGLY_CLI_COMMAND="$ROOT/bin/orca-quiet" run --full)"
check "nothing blocked, every host read: one none line" "$(sec "$OUT" 'Blocked on you' | tr '\n' '|')" "Blocked on you (0)|- none||"
check "Blocked comes right after Priorities in --full" "$(printf '%s\n' "$OUT" | grep -E '^(Priorities|Blocked on you|Merged)' | head -n 3 | sed 's/ (.*//' | tr '\n' '|')" "Priorities|Blocked on you|Merged|"
has "no programme file: says not written, never silent" "$OUT" "Programmes: not written yet"
has "no census file: says not written, never silent" "$OUT" "Census: not written yet"

# 2. blocked rows: owner-only asks, lane lines, own-worktree asks, blocked-on-owner workers ----------------------------
# a credential-shaped kind, built at run time so no token-shaped literal sits in this file
CK="sk-$(printf '%s' ant)-api03-$(printf 'A%.0s' $(seq 32))"
jq --arg ck "$CK" --arg a1 "$(ago 1)" --arg a2 "$(ago 3)" '.asks = [
    {id: "a-merge", kind: "merge", state: "open", question: "merge #12 past the red e2e?", lane: "lane-x", issue: 12, askedAt: $a1},
    {id: "a-nokind", state: "open", question: "no kind recorded here", worker: "w-y", askedAt: $a2},
    {id: "a-scope", scope: "auth", state: "open", question: "rotate the auth hook?", askedAt: $a1},
    {id: "a-owner", kind: "owner", state: "open", question: "pick a|b for the export", askedAt: $a1},
    {id: "a-code", kind: "code", state: "open", lane: "dev-sweeper", question: "own scope code choice", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-deploy", kind: "deploy", state: "open", question: "open the deploy window", askedAt: $a1},
    {id: "a-release", kind: "release", state: "open", question: "feature switch-on of chat widget for one club", askedAt: $a1},
    {id: "a-club", kind: "release", state: "open", question: "feature switch-on of the chat widget", askedAt: $a1},
    {id: "a-golive", kind: "Release ", state: "open", question: "approve the beta go-live", askedAt: $a1},
    {id: "a-goline", kind: "release", state: "open", question: "go acme-id staging abc123", askedAt: $a1},
    {id: "a-cutover", kind: "deploy", state: "open", question: "start the Acme ID cutover?", askedAt: $a1},
    {id: "a-selfdeploy", kind: "deploy", state: "open", question: "open the daily deploy window", worker: "concertmaster", askedAt: $a1},
    {id: "a-selfmerge", kind: "merge", state: "open", question: "own worktree merge call", worker: "concertmaster", askedAt: $a1},
    {id: "a-credkind", kind: $ck, state: "open", question: "pick the odd one", askedAt: $a1},
    {id: "a-sec-prod", kind: "secrets", state: "open", question: "rotate the production signing key", askedAt: $a1},
    {id: "a-sec-test", kind: "secrets", state: "open", question: "store the staging test persona key", topic: "test project only", askedAt: $a1},
    {id: "a-sec-scope", scope: "secrets", state: "open", question: "the preview branch key", askedAt: $a1},
    {id: "a-code-rls", kind: "code", state: "open", question: "add a row level policy for the roster view?", files: ["src/features/roster/Roster.tsx"], askedAt: $a1},
    {id: "a-design-mig", kind: "design", state: "open", question: "split the migration into two files?", noCode: true, askedAt: $a1},
    {id: "a-code-nofiles", kind: "code", state: "open", question: "own scope choice with no files listed", askedAt: $a1},
    {id: "a-srk", kind: "deploy", state: "open", question: "set SUPABASE_SERVICE_ROLE_KEY on production", askedAt: $a1},
    {id: "a-stripe", kind: "release", state: "open", question: "add the live Stripe key to production", askedAt: $a1},
    {id: "a-r2", kind: "deploy", state: "open", question: "rotate the R2 access key", askedAt: $a1},
    {id: "a-pat", kind: "release", state: "open", question: "upload with the new GH PAT", askedAt: $a1},
    {id: "a-hook", kind: "deploy", state: "open", question: "register the payments webhook", askedAt: $a1},
    {id: "a-keys", kind: "deploy", state: "open", question: "copy the keys over", askedAt: $a1},
    {id: "a-vault", kind: "deploy", state: "open", question: "update the vault entry", askedAt: $a1},
    {id: "a-jwt", kind: "deploy", state: "open", question: "rotate the jwt", askedAt: $a1},
    {id: "a-envvar", kind: "deploy", state: "open", question: "set the env var on production", askedAt: $a1},
    {id: "a-p8", kind: "release", state: "open", question: "update the .p8 for the store upload", askedAt: $a1},
    {id: "a-prov", kind: "release", state: "open", question: "new provisioning profile for the release", askedAt: $a1},
    {id: "a-keychain", kind: "release", state: "open", question: "unlock the keychain", askedAt: $a1},
    {id: "a-p12", kind: "release", state: "open", question: "upload the p12 cert", askedAt: $a1},
    {id: "a-dsn", kind: "deploy", state: "open", question: "add the DSN to production", askedAt: $a1},
    {id: "a-oauth", kind: "deploy", state: "open", question: "set the OAuth client for prod", askedAt: $a1},
    {id: "a-bearer", kind: "deploy", state: "open", question: "add the new bearer for prod", askedAt: $a1},
    {id: "a-rel-kbd", kind: "release", state: "open", question: "feature switch-on for keyboard fc", askedAt: $a1},
    {id: "a-rel-path", kind: "release", state: "open", question: "feature switch-on for pathfinder fc", askedAt: $a1},
    {id: "a-rel-patch", kind: "release", state: "open", question: "feature switch-on for patch united", askedAt: $a1},
    {id: "a-o-fb", kind: "release", state: "open", question: "update the Firebase service account", askedAt: $a1},
    {id: "a-o-pp", kind: "release", state: "open", question: "new passphrase", askedAt: $a1},
    {id: "a-o-env", kind: "deploy", state: "open", question: "update the .env on prod", askedAt: $a1},
    {id: "a-o-gsj", kind: "release", state: "open", question: "google-services.json", askedAt: $a1},
    {id: "a-o-gsi", kind: "release", state: "open", question: "GoogleService-Info.plist", askedAt: $a1},
    {id: "a-o-hmac", kind: "deploy", state: "open", question: "HMAC", askedAt: $a1},
    {id: "a-o-pem", kind: "release", state: "open", question: "store the pem", askedAt: $a1},
    {id: "a-o-salt", kind: "deploy", state: "open", question: "salt", askedAt: $a1},
    {id: "a-o-bw", kind: "deploy", state: "open", question: "BW_CLIENTID", askedAt: $a1},
    {id: "a-o-r2b", kind: "deploy", state: "open", question: "R2 bucket creds", askedAt: $a1},
    {id: "a-o-asc", kind: "release", state: "open", question: "ASC issuer id", askedAt: $a1},
    {id: "a-o-asp", kind: "release", state: "open", question: "app-specific pw", askedAt: $a1},
    {id: "a-o-npmrc", kind: "release", state: "open", question: ".npmrc", askedAt: $a1},
    {id: "a-o-kube", kind: "deploy", state: "open", question: "kubeconfig", askedAt: $a1},
    {id: "a-o-enc", kind: "deploy", state: "open", question: "encryption passphrase", askedAt: $a1},
    {id: "a-o-tc", kind: "deploy", state: "open", question: "transcrypt pass", askedAt: $a1},
    {id: "a-o-otakey", kind: "release", state: "open", question: "ship the OTA release and rotate the service account key", askedAt: $a1},
    {id: "a-c-native", kind: "release", state: "open", question: "submit the native release", askedAt: $a1},
    {id: "a-c-sub", kind: "release", state: "open", question: "store submission 1.4.2", askedAt: $a1},
    {id: "a-c-tf", kind: "release", state: "open", question: "push the store build", askedAt: $a1},
    {id: "a-c-ps", kind: "release", state: "open", question: "promote the play listing release", askedAt: $a1},
    {id: "a-c-ota", kind: "release", state: "open", question: "push the OTA release", askedAt: $a1},
    {id: "a-c-air", kind: "release", state: "open", question: "ship the over the air update", askedAt: $a1},
    {id: "a-c-win", kind: "deploy", state: "open", question: "production deploy window tonight", askedAt: $a1},
    {id: "a-c-fee", kind: "release", state: "open", question: "switch on the beta banner", askedAt: $a1},
    {id: "a-c-scores", kind: "release", state: "open", question: "turn on the beta banner flag", askedAt: $a1},
    {id: "a-x01", kind: "release", state: "open", question: "store build using the new BW_CLIENTID", askedAt: $a1},
    {id: "a-x02", kind: "release", state: "open", question: "OTA release plus the kubeconfig", askedAt: $a1},
    {id: "a-x03", kind: "release", state: "open", question: "native release & the R2 bucket creds", askedAt: $a1},
    {id: "a-x04", kind: "release", state: "open", question: "OTA release / ASC issuer id", askedAt: $a1},
    {id: "a-x05", kind: "release", state: "open", question: "OTA bundle + the .npmrc", askedAt: $a1},
    {id: "a-x06", kind: "release", state: "open", question: "deploy window via the transcrypt pass", askedAt: $a1},
    {id: "a-x07", kind: "release", state: "open", question: "native release to install the kubeconfig", askedAt: $a1},
    {id: "a-x08", kind: "release", state: "open", question: "attach the kubeconfig to the store build", askedAt: $a1},
    {id: "a-x09", kind: "release", state: "open", question: "include the BW_CLIENTID in the OTA release", askedAt: $a1},
    {id: "a-x10", kind: "release", state: "open", question: "publish the store build to the R2 bucket creds", askedAt: $a1},
    {id: "a-x11", kind: "release", state: "open", question: "OTA release - put the kubeconfig on the runner", askedAt: $a1},
    {id: "a-x12", kind: "release", state: "open", question: "OTA release so we can store the creds", askedAt: $a1},
    {id: "a-x13", kind: "release", state: "open", question: "switch on chat widget for acme fc using the kubeconfig", askedAt: $a1},
    {id: "a-sl1", kind: "release", state: "open", question: "ota release for rotating creds", askedAt: $a1},
    {id: "a-sl2", kind: "release", state: "open", question: "native release for pasting kubeconfig", askedAt: $a1},
    {id: "a-sl3", kind: "release", state: "open", question: "ship the native release for exporting members", askedAt: $a1},
    {id: "a-sl4", kind: "release", state: "open", question: "native release 1.6 to production for dumping profiles", askedAt: $a1},
    {id: "a-sl5", kind: "release", state: "open", question: "app listing for wiping data", askedAt: $a1},
    {id: "a-sl6", kind: "deploy", state: "open", question: "open the deploy window for transcrypt pass", askedAt: $a1},
    {id: "a-sl7", kind: "release", state: "open", question: "store build of r2 bucket creds", askedAt: $a1},
    {id: "a-sl8", kind: "release", state: "open", question: "store build for the kubeconfig", askedAt: $a1},
    {id: "a-sl9", kind: "release", state: "open", question: "OTA release", topic: "for rotating creds", askedAt: $a1},
    {id: "a-nt1", kind: "release", state: "open", question: ["paste the kubeconfig and rotate everything"], topic: "store build", askedAt: $a1},
    {id: "a-nt2", kind: "release", state: "open", question: {"do": "set the BW_CLIENTID, then upload"}, topic: "OTA release", askedAt: $a1},
    {id: "a-nt3", kind: "release", state: "open", question: 42, topic: "native release", askedAt: $a1},
    {id: "a-nl", kind: "release", state: "open", question: "store build service\nrole", askedAt: $a1},
    {id: "a-ok1", kind: "release", state: "open", question: "store build 1.5.2", askedAt: $a1},
    {id: "a-ok2", kind: "release", state: "open", question: "OTA release 1.5.3 to production channel", askedAt: $a1},
    {id: "a-ok3", kind: "release", state: "open", question: "switch on the chat widget for Acme FC", askedAt: $a1},
    {id: "a-ok4", kind: "release", state: "open", question: "native release 1.6", askedAt: $a1},
    {id: "a-rel-plain", kind: "release", state: "open", question: "release 1.4.2 to production", askedAt: $a1},
    {id: "a-rel-words", kind: "release", state: "open", question: "switch on chat widget for monkey path fc", askedAt: $a1},
    {id: "a-ntcode", kind: "code", state: "open", question: ["split the card list"], files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-longcode", kind: "code", state: "open", question: ("split the card list " * 220), files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-ops", kind: "code", state: "open", lane: "ops-sweeper", question: "split the ops card list?", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-opsw", kind: "code", state: "open", worker: " w-ops ", question: "split the worker card list?", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-epiclane", kind: "code", state: "open", lane: "epic-cm-upgrade", question: "split the epic card list?", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-plan", kind: "design", state: "open", lane: "dev-sweeper", question: "plan ready: approve the epic plan?", files: ["docs/plan.md"], askedAt: $a1},
    {id: "a-nolane", kind: "code", state: "open", question: "split the nolane card?", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-blankw", kind: "code", state: "open", lane: "dev-sweeper", worker: "  ", question: "split the blankw card?", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-prsw", kind: "code", state: "open", lane: "pr-sweeper", question: "split the prsw card?", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-devctl", kind: "code", state: "open", lane: "dev-sweeper", question: "split the dev card list?", files: ["src/components/Card.tsx"], askedAt: $a1},
    {id: "a-pad", kind: "code", state: "open", question: "split the card list?", noCode: true, worker: " w-pr ", askedAt: $a1},
    {id: "a-done", kind: "merge", state: "answered", question: "answered merge call", askedAt: $a1}
  ]
  | .workers = {"w-bo": {lane: "lane-z", task: "club roster", state: "blocked-on-owner", blockedQuestion: "which club first?"},
                "w-run": {lane: "lane-z", task: "other", state: "running"},
                "w-pr": {lane: "lane-p", task: "card list", state: "running", pr: 5},
                "w-ops": {lane: "ops-sweeper", task: "ops", state: "running"}}' "$L" > "$L.t" && mv "$L.t" "$L"
OUT="$(run --full)"; RC=$?
check "blocked: exit 0" "$RC" "0"
B="$(sec "$OUT" 'Blocked on you')"
has "an open merge ask is the owner's, with lane, issue, kind and age" "$B" "- lane-x #12: ask a-merge | answer: merge #12 past the red e2e? (merge, open 1h0m)"
has "an ask with no kind is owner-only" "$B" "- w-y: ask a-nokind | answer: no kind recorded here (no kind, open 3h"
has "the kind is read from scope when kind is missing; no lane is the concertmaster" "$B" "- concertmaster: ask a-scope | answer: rotate the auth hook? (auth,"
has "a pipe in an ask is not a column break" "$B" "answer: pick a/b for the export (owner,"
lacks "an own-scope ask past the scan, its files in the allowlist, is not the owner's" "$B" "own scope code choice"
# round 3: ask-timeout.sh calls an ops, epic or pr-sweep lane and an epic "plan ready" approval never (they stay with the owner), so ask_owner_why must call them owner-only too. They were
# dropped from "Blocked on you" and "Needs" (a valid code ask from ops-sweeper read as own-scope), where the old Needs listed them. The lane on the ask, the lane only on the worker row, an epic lead lane
# and a plan approval are all the owner's; a dev-sweeper own-scope ask beside them is not.
has "an open code ask from the ops-sweeper lane with valid files is the owner's (lane on the ask)" "$B" "ask a-ops | answer: split the ops card list?"
has "an open code ask whose lane is only on its worker row (ops-sweeper) is the owner's" "$B" "ask a-opsw | answer: split the worker card list?"
has "an open code ask from an epic lead lane is the owner's" "$B" "ask a-epiclane | answer: split the epic card list?"
has "an epic plan ready approval is the owner's even from a dev lane with valid files" "$B" "ask a-plan | answer: plan ready: approve the epic plan?"
lacks "control: a dev-sweeper own-scope code ask with valid files is not the owner's" "$B" "a-devctl"
# round 4: ask_owner_why calls owner-only every ask that ask-timeout.sh keeps with the owner for who is asking: (a) no lane on the ask or its worker row, (b) a blank worker id, (c) a worker row that is
# not an object, (d) a non-text worker lane whatever the ask lane is, and the pr-sweep lane. (c) and (d) need a damaged workers map, so they run on their own ledger at the end of this file.
has "(a) an own-scope ask with no lane anywhere is the owner's (an unknown asker)" "$B" "ask a-nolane | answer: split the nolane card?"
has "(b) an own-scope ask with a blank worker id is the owner's" "$B" "ask a-blankw | answer: split the blankw card?"
has "the pr-sweep lane is the owner's" "$B" "ask a-prsw | answer: split the prsw card?"
has "the ops ask is also under Needs" "$(sec "$OUT" 'Needs ')" "split the ops card list?"
# mutant (cp -R, so scripts/jdupkeys comes along): the lane and plan-approval exclusions taken out of ask-deny.sh. The four asks read as own-scope again and are dropped from Blocked on you and Needs, the harm
mkdir -p "$ROOT/mut-ops" && cp -R "$HERE"/../. "$ROOT/mut-ops"/
perl -pi -e 's/elif \(\$lane \| startswith\("ops"\)\) or \(\$lane \| startswith\("epic"\)\) or \(\$lane \| startswith\("pr-sweep"\)\) then/elif false then/; s/\)\?plan ready"; "i"/)?plan readyzz"; "i"/' "$ROOT/mut-ops/ask-deny.sh"
if ! cmp -s "$HERE/../ask-deny.sh" "$ROOT/mut-ops/ask-deny.sh"; then
  fixl; MOUT="$("$ROOT/mut-ops/digest.sh" --full 2>/dev/null)"; MB="$(sec "$MOUT" 'Blocked on you')"
  lacks "mutant: without the lane exclusion the ops-sweeper ask (lane on the ask) is dropped from Blocked on you" "$MB" "ask a-ops |"
  lacks "mutant: without the lane exclusion the ops-sweeper ask (lane on the worker row) is dropped from Blocked on you" "$MB" "ask a-opsw |"
  lacks "mutant: without the lane exclusion the epic lead ask is dropped from Blocked on you" "$MB" "ask a-epiclane |"
  lacks "mutant: without the plan exclusion the plan ready approval is dropped from Blocked on you" "$MB" "ask a-plan |"
  lacks "mutant: the ops ask is dropped from Needs too" "$(sec "$MOUT" 'Needs ')" "split the ops card list?"
  has "mutant: the Blocked count falls by the five dropped asks (ops, ops via worker, epic, plan approval, pr-sweep)" "$MB" "Blocked on you (94,"
else FAIL=$((FAIL + 1)); echo "FAIL mutant: the perl edit did not match ask-deny.sh"; fi
lacks "a delegated deploy ask is not the owner's" "$B" "open the deploy window ("
lacks "a delegated release ask (a club switch-on, one class phrase) is not the owner's" "$B" "feature switch-on of the chat widget ("
has "a club switch-on with a for <club> tail is the owner's (the allowlist has no free-text slot)" "$B" "ask a-release | answer: feature switch-on of chat widget for one club (release,"
lacks "a credential-shaped kind is never printed in the digest (it reads as unknown kind)" "$OUT" "$CK"
has "an ask of an unlisted kind shows as unknown kind" "$B" "answer: pick the odd one (unknown kind,"
lacks "a go-live ask (kind with stray case and a space) is delegated, not the owner's" "$B" "approve the beta go-live"
has "a release ask naming a go line is the owner's" "$B" "ask a-goline | answer: go acme-id staging abc123 (release,"
has "a deploy ask naming the Acme ID cutover is the owner's" "$B" "ask a-cutover | answer: start the Acme ID cutover? (deploy,"
N="$(sec "$OUT" 'Needs ')"
has "the --full Needs section lists the owner's ask" "$N" "ask: merge #12 past the red e2e?"
lacks "the --full Needs section does not list a delegated deploy ask" "$N" "open the deploy window ("
lacks "the --full Needs section does not list a delegated release ask" "$N" "feature switch-on of the chat widget ("
lacks "no --full owner heading lists a delegated deploy ask" "$(printf '%s\n' "$OUT" | sed -n '/^Needs /,/^$/p;/^Blocked on you/,/^$/p')" "open the deploy window ("
has "a production secrets ask is the owner's" "$B" "ask a-sec-prod | answer: rotate the production signing key (secrets,"
has "a test-project secrets ask is STILL the owner's (no wording clears one)" "$B" "ask a-sec-test | answer: store the staging test persona key (secrets,"
has "a secrets ask read from scope is the owner's" "$B" "ask a-sec-scope |"
has "an own-scope ask naming RLS is the owner's" "$B" "ask a-code-rls | answer: add a row level policy for the roster view? (code,"
has "an own-scope noCode ask naming a migration is the owner's" "$B" "ask a-design-mig | answer: split the migration into two files? (design,"
has "an own-scope ask with no files[] and no noCode is the owner's (the ask-timeout.sh gate)" "$B" "ask a-code-nofiles |"
lacks "an answered ask is gone" "$B" "answered merge call"
for a in a-srk a-stripe a-r2 a-pat a-hook a-keys a-vault a-jwt a-envvar a-p8 a-prov a-keychain a-p12 a-dsn a-oauth a-bearer; do has "a release or deploy ask naming a key, PAT, service role, access key or webhook is the owner's ($a)" "$B" "ask $a |"; done
has "a release ask naming no delegated class is the owner's (default deny: a lane must name what it releases)" "$B" "ask a-rel-plain | answer: release 1.4.2 to production (release,"
for a in a-x01 a-x02 a-x03 a-x04 a-x05 a-x06 a-x07 a-x08 a-x09 a-x10 a-x11 a-x12 a-x13 a-sl1 a-sl2 a-sl3 a-sl4 a-sl5 a-sl6 a-sl7 a-sl8 a-sl9 a-nt1 a-nt2 a-nt3 a-nl; do has "a class phrase with anything else, a for or of tail on a release, a non-text question or a split word is the owner's ($a)" "$B" "ask $a |"; done
for a in a-ok1 a-ok2 a-ok4; do lacks "one class phrase is not the owner's ($a)" "$B" "ask $a |"; done
for a in a-o-fb a-o-pp a-o-env a-o-gsj a-o-gsi a-o-hmac a-o-pem a-o-salt a-o-bw a-o-r2b a-o-asc a-o-asp a-o-npmrc a-o-kube a-o-enc a-o-tc a-o-otakey; do has "a phrasing that leaked past the word list is the owner's ($a)" "$B" "ask $a |"; done
has "a class phrase that also names a secret is the owner's" "$B" "ask a-o-otakey | answer: ship the OTA release and rotate the service account key (release,"
for a in a-c-native a-c-sub a-c-tf a-c-ps a-c-ota a-c-air a-c-win a-c-fee a-c-scores; do lacks "a release or deploy ask naming a delegated class is not the owner's ($a)" "$B" "ask $a |"; done
for a in a-ok3 a-rel-kbd a-rel-path a-rel-patch a-rel-words; do has "a class phrase with a for <club> tail is the owner's, whatever the club is called ($a)" "$B" "ask $a |"; done
has "a noCode ask whose padded worker id names a worker with a PR is the owner's" "$B" "ask a-pad |"
has "an own-scope ask with a non-text question is the owner's (ask_bad, before any text is read)" "$B" "ask a-ntcode |"
has "an own-scope ask over 4000 characters as JSON is the owner's (ask_bad)" "$B" "ask a-longcode |"
has "a lane cm:blocked on line 2 is listed" "$B" "- lane-blk on local | cm:blocked: which table holds the backfill?"
has "a cm:waiting-owner after a pipe on a remote host is listed" "$B" "- lane-wo on host-a | cm:waiting-owner: flip the flag? (recommend yes)"
has "a cm:waiting-owner is listed, its pipe made safe" "$B" "- lane-pipe on local | cm:waiting-owner: interview Q4/Q5 club scope"
has "a cm:ask in the concertmaster's own worktree is a held item" "$B" "- concertmaster on local | cm:ask: define the lease of the test tenant"
lacks "a lane's own cm:ask is not the owner's" "$B" "a lane question the lane answers"
lacks "a finished lane's old blocker is gone" "$B" "old blocker on a finished lane"
has "a ledger worker blocked-on-owner is listed" "$B" "- lane-z club roster | which club first?"
lacks "a running worker is not" "$B" "lane-z other"
lacks "an unreachable host is no Blocked row (a fleet-health fact, Moved in the tick report)" "$B" "- host not read"
has "an unreachable host is listed under Fleet health, never read as none" "$(sec "$OUT" 'Fleet health')" "- host not read: host-b ("
# the four asks with a non-text question (a-nt1 to a-nt3, a-ntcode) stay owner rows AND each prints one "unreadable (ledger .asks[n].question
# is not text)" note (round 5: every ask field the owner scan reads is named when it has the wrong type), so the count is 88 + 4
check "the count is the item rows and the four unreadable-question notes, the unread host counted beside it" "$(printf '%s\n' "$B" | sed -n '1p')" "Blocked on you (99, 1 host not read, see Fleet health)"
check "the four non-text questions each print one unreadable note" "$(printf '%s\n' "$B" | grep -c '^- unreadable (ledger .asks\[[0-9]*\].question is not text)')" "4"
check "every row is an item with exactly one column break (the notes aside)" "$(printf '%s\n' "$B" | grep '^- ' | grep -v '^- unreadable (ledger ' | awk -F' [|] ' 'NF != 2' | wc -l | tr -d ' ')" "0"
# the same definition as stall.sh: its owner-exempt ledger asks are exactly the digest's Blocked asks
NOWI="$(jq -nr 'now | floor | todate')"
jq -n --arg g "$NOWI" '{schema: "concertmaster.classify/v1", generatedAt: $g, items: []}' > "$ROOT/cls.json"
jq -n --arg g "$NOWI" '{schema: "concertmaster.discover/v1", generatedAt: $g, hosts: [], worktrees: [], prs: {open: []}}' > "$ROOT/disc.json"
jq -n --arg g "$NOWI" '{generatedAt: $g, asks: [], hostsRead: [], unreachable: []}' > "$ROOT/asks.json"
fixl; SJ="$(CM_SELF_WORKTREE=concertmaster "$HERE/../stall.sh" --classify "$ROOT/cls.json" --discover "$ROOT/disc.json" --asks "$ROOT/asks.json" --ledger "$L" --since "$NOWI" --json 2>"$ROOT/stall.err")"
# the own worktree of the concertmaster holds an ask (code held): the owner's only when stall.sh says "the owner decides"
STALL_OWNER="$(printf '%s' "$SJ" | jq -r '[.exempt[] | select(.kind == "ask" and (.code == "owner" or (.code == "held" and (.reason | contains("the owner decides"))))) | .name] | sort | join(" ")' 2>/dev/null)"
check "a delegated ask from the own worktree is held for the concertmaster, not the owner" "$(printf '%s' "$SJ" | jq -r '[.exempt[] | select(.kind == "ask" and .name == "a-selfdeploy") | .code + ":" + (.reason | contains("the concertmaster decides it itself") | tostring)] | join(",")' 2>/dev/null)" "held:true"
lacks "and digest.sh does not list it as Blocked on you" "$B" "open the daily deploy window"
has "an owner-only ask from the own worktree is held and listed" "$B" "ask a-selfmerge | answer: own worktree merge call (merge,"
# LC_ALL=C: the same codepoint order as the jq sort of the stall.sh side
DIGEST_OWNER="$(printf '%s\n' "$B" | sed -n 's/^- [^|]*: ask \([^ |]*\) |.*/\1/p' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
check "stall.sh read the ledger asks" "$(printf '%s' "$SJ" | jq -r '[.exempt[] | select(.kind == "ask")] | length > 0' 2>/dev/null)" "true"
check "stall.sh and digest.sh name the same owner-only asks" "$DIGEST_OWNER" "$STALL_OWNER"
check "and the set is the expected one" "$STALL_OWNER" "a-bearer a-blankw a-code-nofiles a-code-rls a-credkind a-cutover a-design-mig a-dsn a-envvar a-epiclane a-goline a-hook a-jwt a-keychain a-keys a-longcode a-merge a-nl a-nokind a-nolane a-nt1 a-nt2 a-nt3 a-ntcode a-o-asc a-o-asp a-o-bw a-o-enc a-o-env a-o-fb a-o-gsi a-o-gsj a-o-hmac a-o-kube a-o-npmrc a-o-otakey a-o-pem a-o-pp a-o-r2b a-o-salt a-o-tc a-oauth a-ok3 a-ops a-opsw a-owner a-p12 a-p8 a-pad a-pat a-plan a-prov a-prsw a-r2 a-rel-kbd a-rel-patch a-rel-path a-rel-plain a-rel-words a-release a-scope a-sec-prod a-sec-scope a-sec-test a-selfmerge a-sl1 a-sl2 a-sl3 a-sl4 a-sl5 a-sl6 a-sl7 a-sl8 a-sl9 a-srk a-stripe a-vault a-x01 a-x02 a-x03 a-x04 a-x05 a-x06 a-x07 a-x08 a-x09 a-x10 a-x11 a-x12 a-x13"

# 2b. the report withholds a credential-shaped line (the line analog of stall.sh --json per-field withholding) ----------
base_ledger 2
TOKD="ghp""_$(printf 'q%.0s' $(seq 36))"
LONGLANE="lane-with-a-very-long-kebab-case-name-for-the-check"
jq --arg t "$TOKD" --arg ll "$LONGLANE" --arg a1 "$(ago 1)" '.asks = [
    {id: "t-tok", kind: "merge", state: "open", question: ("use " + $t + " to push"), lane: "lane-t", askedAt: $a1},
    {id: "t-long", kind: "merge", state: "open", question: "merge the long one?", lane: $ll, askedAt: $a1}]
  | .followUps = [{id: "fu-t", lane: "lane-t", owner: $t, worker: "w-t", text: "check it", state: "open", openedAt: $a1}]' "$L" > "$L.t" && mv "$L.t" "$L"
OUT="$(run --full)"; RC=$?
check "withhold: exit 0" "$RC" "0"
lacks "a credential-shaped ask question never reaches --full" "$OUT" "$TOKD"
lacks "nor any part of it" "$OUT" "qqqqqqqqqqqqqqqqqqqq"
has "its Blocked row is withheld, the bullet kept" "$(sec "$OUT" 'Blocked on you')" "- [withheld: looks like a credential]"
has "a long kebab-case lane name is not taken for a credential (its row is kept)" "$(sec "$OUT" 'Blocked on you')" "- ${LONGLANE:0:40}: ask t-long | answer: merge the long one?"
GOUT="$(run)"
lacks "the group text never carries it either" "$GOUT" "qqqqqqqqqqqqqqqqqqqq"

# 3. decisions: at least the last 12 hours, the window start when it is earlier, unreadable entries counted ------------
base_ledger 2
jq --arg d1 "$(ago 1)" --arg d11 "$(ago 11)" --arg d13 "$(ago 13)" '.decisions = [
    {id: "d-1", at: $d1, subject: {kind: "pr", name: "#77", host: "host-a"}, rung: 3, text: "Q: merge order? Reviewer A: 77 first. Reviewer B: agree. Act: merged 77 first", source: "stall.sh", by: "concertmaster"},
    {id: "d-11", at: $d11, subject: {kind: "lane", name: "lane-k"}, rung: 3, text: "Q: restart or re-place? both: re-place. Act: re-placed", source: "stall.sh", by: "concertmaster"},
    {id: "d-13", at: $d13, subject: {kind: "ask", name: "lane-m"}, rung: 3, text: "thirteen hours old", source: "stall.sh", by: "concertmaster"},
    {id: "d-bad", at: "not a time", subject: "x", rung: 3, text: "bad time"},
    7
  ]' "$L" > "$L.t" && mv "$L.t" "$L"
OUT="$(run --full)"
D="$(sec "$OUT" 'Decided while you were away (')"
check "digest 2h after the last send: a 12h window, two decisions" "$(printf '%s\n' "$D" | sed -n '1p')" "Decided while you were away (2, last 12h)"
has "a decision names subject, host, rung and its text" "$D" "pr #77 on host-a (rung 3): Q: merge order? Reviewer A: 77 first. Reviewer B: agree. Act: merged 77 first"
has "an 11h old decision is in the 12h window" "$D" "lane lane-k (rung 3): Q: restart or re-place?"
lacks "a 13h old decision is outside it" "$D" "thirteen hours old"
has "entries that are not objects or have no readable time are counted" "$D" "- 2 unreadable entries in ledger decisions[]"
check "oldest first" "$(printf '%s\n' "$D" | grep -n 'lane-k\|#77' | cut -d: -f1 | tr '\n' ' ')" "2 3 "
has "the verdict-agent away-timeout section is still its own section" "$OUT" "Decided while you were away (verdict-agent) (0)"
base_ledger 14
jq --arg d13 "$(ago 13)" '.decisions = [{id: "d-13", at: $d13, subject: {kind: "ask", name: "lane-m"}, rung: 3, text: "thirteen hours old"}]' "$L" > "$L.t" && mv "$L.t" "$L"
OUT="$(run --full)"
D="$(sec "$OUT" 'Decided while you were away (')"
check "the 08:00 report after a 14h night: the window reaches the last send" "$(printf '%s\n' "$D" | sed -n '1p')" "Decided while you were away (1, last 14h)"
has "so a decision 13h ago is not skipped" "$D" "ask lane-m (rung 3): thirteen hours old"
jq '.decisions = {"not": "a list"}' "$L" > "$L.t" && mv "$L.t" "$L"
has "decisions that are not a list say unreadable, never none" "$(run --full)" "Decided while you were away: unreadable (ledger .decisions is not a list)"
jq --arg at "$(ago 1)" '.decisions = [range(0; 23) | {id: "d-\(.)", at: $at, subject: {kind: "lane", name: "lane-\(.)"}, rung: 3, text: "n\(.)"}]' "$L" > "$L.t" && mv "$L.t" "$L"
D="$(sec "$(run --full)" 'Decided while you were away (')"
has "more than 20: the earlier ones are counted" "$D" "- +3 earlier, see ledger decisions[]"
check "more than 20: 20 decision lines" "$(printf '%s\n' "$D" | grep -c '(rung 3)')" "20"

# 4. programme and census files: printed as written, with their age; a stale one says stale -------------------------
printf '| programme | lead + host | state | open PRs | waiting on |\n|---|---|---|---|---|\n| epic:acme | lead-a @ host-a | cm:running | #5 (1) | none |\n' > "$CM_HOME/programmes.md"
printf 'census: orphans 0, unknown-git 0, dirty 1 (target 0)\n  dirty: lane-d @ host-a: dirty:2 (class dirty-or-unpushed)\nother-project: 2 (listed apart, not counted)\n' > "$CM_HOME/census.txt"
OUT="$(run --full)"
has "Programmes heading with its age" "$OUT" "Programmes (written 0m ago)"
has "the programme table is printed as written" "$(sec "$OUT" 'Programmes')" "| epic:acme | lead-a @ host-a | cm:running | #5 (1) | none |"
has "the census rows are printed as written, indent kept" "$(sec "$OUT" 'Census')" "  dirty: lane-d @ host-a: dirty:2 (class dirty-or-unpushed)"
touch -t 202001010000 "$CM_HOME/census.txt"
has "an old census file says stale" "$(run --full)" ", stale)"

# 5. the group text: none of these sections, and byte for byte the same whatever they hold ---------------------------
body() { printf '%s\n' "$1" | tail -n +2; }   # the text without its header line (it carries the minute)
GROUP_FULL="$(run)"
for s in "Blocked on you" "Decided while" "Programmes" "Census"; do lacks "group text has no $s section" "$GROUP_FULL" "$s"; done
base_ledger 14
rm -f -- "$CM_HOME/programmes.md" "$CM_HOME/census.txt"
GROUP_BARE="$(run)"
check "group text is the same with or without decisions, programme and census files" "$(body "$GROUP_FULL")" "$(body "$GROUP_BARE")"
jq --arg a "$(ago 1)" '.asks = [{id: "a-x", kind: "code", state: "answered", question: "q", askedAt: $a}]' "$L" > "$L.t" && mv "$L.t" "$L"
check "and the same with an answered ask (only open asks show anywhere)" "$(body "$(run)")" "$(body "$GROUP_BARE")"

# 6. SKILL.md names the shape: two tables, the five-row cap, and stall.sh in the tick ----------------
sect() { awk -v h="$1" '$0 ~ "^## " h "$" {on=1; next} /^## / {on=0} on' "$SK"; }
# line breaks and runs of spaces folded: a phrase may wrap in the Markdown
REP="$(sect 'Reporting' | tr '\n' ' ' | sed 's/  */ /g')"; TICK="$(sect 'The tick' | tr '\n' ' ' | sed 's/  */ /g')"
has "§ Reporting has the Blocked on you table header" "$REP" "| feature | what you need to do |"
has "§ Reporting has the Moved this tick table header" "$REP" "| what | result |"
has "§ Reporting caps Moved at 5 rows" "$REP" "at most 5 rows"
has "§ Reporting keeps the no-picker rule" "$REP" "A tick turn never"
has "§ Reporting sends the old tables to digest --full" "$REP" "scripts/digest.sh --full"
has "§ The tick runs stall.sh" "$TICK" "scripts/stall.sh --classify"
has "§ The tick flags a stalled tick with no action" "$TICK" "NO-ACTION"
lacks "§ Reporting has no em-dash" "$REP" "$(printf '\342\200\224')"
# shellcheck disable=SC2016  # literal backticks: the Markdown text, not a command
has "§ Reporting: a host not read is a Moved row" "$REP" '`host not read: <host> | <error>, its cm:blocked lines not listed`'
has "§ Reporting: an unread host never lets Blocked say none" "$REP" '| none read | <n> host(s) not read, see Moved |'
# shellcheck disable=SC2016
has "§ Reporting: a secrets ask is always a Blocked row" "$REP" 'a `secrets` ask always'
# shellcheck disable=SC2016
has "§ Reporting names the shared owner-only definition" "$REP" '`ask_owner_why` in `scripts/ask-deny.sh`'
# shellcheck disable=SC2016
lacks "§ Reporting never lists secrets as delegated" "$REP" '`deploy`, `secrets`'

# round 4 (c) and (d): a worker row that is not an object, and a worker row whose lane is not text while the ask names a lane of its own, on their own ledger
cp "$L" "$ROOT/ledger.r4keep"
jq --arg a "$(ago 1)" '.asks += [{id: "a-rownon", kind: "code", state: "open", lane: "dev-sweeper", worker: "w-bad", question: "split the rownon card?", files: ["src/components/Card.tsx"], askedAt: $a},
                              {id: "a-wlane", kind: "code", state: "open", lane: "dev-sweeper", worker: "w-nt", question: "split the wlane card?", files: ["src/components/Card.tsx"], askedAt: $a}]
  | .workers["w-bad"] = false | .workers["w-nt"] = {lane: 7, task: "x", state: "running"}' "$ROOT/ledger.r4keep" > "$L"
OUT="$(run --full)"; B="$(sec "$OUT" 'Blocked on you')"
has "(c) an ask naming a worker row that is not an object is the owner's" "$B" "ask a-rownon | answer: split the rownon card?"
has "(d) a non-text worker lane is the owner's even when the ask names its own lane" "$B" "ask a-wlane | answer: split the wlane card?"
# revert-proof mutants (cp -R, so scripts/jdupkeys comes along): each hold turned off alone restores the dropped ask. The mutant copy gets a python edit of the one elif that names the hold.
r4_mut() { # <dir> <message fragment of the hold to turn off, or "pr-sweep">
  python3 - "$1/ask-deny.sh" "$2" <<'PY'
import sys,re
p,key=sys.argv[1],sys.argv[2]
t=open(p).read()
if key=='pr-sweep':
    t=t.replace(' or ($lane | startswith("pr-sweep"))',' or false')
else:
    out=[]
    for l in t.split('\n'):
        if 'elif ' in l and key in l: l=re.sub(r'elif .* then "(of kind|no lane)',r'elif false then "\1',l,count=1)
        out.append(l)
    t='\n'.join(out)
open(p,'w').write(t)
PY
}
r4_case() { # <label> <fragment> <ask id> <ledger file> : with the hold off the ask is dropped from Blocked on you
  local m="$ROOT/mut-r4-$2"; m="${m// /_}"; mkdir -p "$m" && cp -R "$HERE"/../. "$m"/ && r4_mut "$m" "$2"
  if cmp -s "$HERE/../ask-deny.sh" "$m/ask-deny.sh"; then FAIL=$((FAIL + 1)); echo "FAIL mutant $1: the edit did not change ask-deny.sh"; return; fi
  lacks "mutant $1: with the hold off the ask is dropped from Blocked on you (the harm)" "$(fixl; sec "$("$m/digest.sh" --full 2>/dev/null)" 'Blocked on you')" "ask $3 |"
}
r4_case "(a) no lane" "no lane (ask or ledger worker)" a-nolane
r4_case "(b) blank worker" "with a blank worker id" a-blankw
r4_case "(c) worker row not an object" "whose worker row is not an object" a-rownon
r4_case "(d) non-text worker lane" "with a non-text worker lane" a-wlane
r4_case "pr-sweep lane" "pr-sweep" a-prsw
cp "$ROOT/ledger.r4keep" "$L"

# round 6: a padded workers key is the worker its trimmed id names (its PR is seen), and two keys that trim to one id are no row: both asks are the owner's
cp "$L" "$ROOT/ledger.r6keep"
jq --arg a "$(ago 1)" '.asks += [{id: "a-r6pad", kind: "code", state: "open", lane: "dev-sweeper", worker: "w-r6p", question: "split the r6pad card?", noCode: true, askedAt: $a},
                              {id: "a-r6pad2", kind: "code", state: "open", lane: "dev-sweeper", worker: " w-r6p ", question: "split the r6padtwo card?", noCode: true, askedAt: $a},
                              {id: "a-r6two", kind: "code", state: "open", worker: "w-r6d", question: "split the r6two card?", noCode: true, askedAt: $a},
                              {id: "a-r6ctl", kind: "code", state: "open", lane: "dev-sweeper", worker: "w-r6c", question: "split the r6ctl card?", noCode: true, askedAt: $a}]
  | .workers[" w-r6p "] = {lane: "dev-sweeper", task: "x", state: "running", pr: 5}
  | .workers["w-r6d"] = {lane: "dev-sweeper", task: "x", state: "running", pr: 6}
  | .workers[" w-r6d "] = {lane: "dev-sweeper", task: "x", state: "running"}
  | .workers[" w-r6c "] = {lane: "dev-sweeper", task: "x", state: "running"}' "$ROOT/ledger.r6keep" > "$L"
OUT="$(run --full)"; B="$(sec "$OUT" 'Blocked on you')"
has "R6 an ask whose worker is a padded workers key with a PR is the owner's" "$B" "ask a-r6pad | answer: split the r6pad card?"
has "R6 the same with a padded ask worker id" "$B" "ask a-r6pad2 | answer: split the r6padtwo card?"
has "R6 an ask whose worker id is the key of two rows once trimmed is the owner's" "$B" "ask a-r6two | answer: split the r6two card?"
lacks "R6 control: a padded key with no PR and a dev lane is not the owner's" "$B" "ask a-r6ctl |"
# revert-proof mutants (cp -R, so scripts/jdupkeys comes along): the workers map read by the exact key again, and the two-key hold removed
r6_case() { # <label> <old text> <new text> <ask id>
  local m="$ROOT/mut-r6-${4}"; mkdir -p "$m" && cp -R "$HERE"/../. "$m"/
  python3 - "$m/ask-deny.sh" "$2" "$3" <<'PY'
import sys
p,old,new=sys.argv[1:4]
t=open(p).read()
if old in t: open(p,'w').write(t.replace(old,new,1))
PY
  if cmp -s "$HERE/../ask-deny.sh" "$m/ask-deny.sh"; then FAIL=$((FAIL + 1)); echo "FAIL mutant $1: the edit did not change ask-deny.sh"; return; fi
  lacks "mutant $1: the ask is dropped from Blocked on you (the harm)" "$(fixl; sec "$("$m/digest.sh" --full 2>/dev/null)" 'Blocked on you')" "ask $4 |"
}
r6_case "R6 exact workers key" '$wn.ws as $ws' '($workers | if type == "object" then . else {} end) as $ws' a-r6pad
r6_case "R6 exact workers key, padded ask worker id" '$wn.ws as $ws' '($workers | if type == "object" then . else {} end) as $ws' a-r6pad2
r6_case "R6 two keys of one id" '($wn.dup | index($wk)) != null' 'false' a-r6two
cp "$ROOT/ledger.r6keep" "$L"

printf 'digest-report-shape: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
