#!/usr/bin/env bash
# config-check.sh (test): behaviour tests for the config doctor and for config
# selection. config.example.yaml must pass; a copy missing a required key, with a
# value of the wrong shape or with a secret-looking value must fail; a config.yaml
# must be preferred over config.example.yaml. Touches nothing outside a mktemp dir.
#
#   scripts/test/config-check.sh              # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
EXAMPLE="$SKILL/config.example.yaml"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-config.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home"
unset CM_CONFIG
DOCTOR="$HERE/../config-check.sh"
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
# doctor <label> <file> <want rc> [pattern the output must show]
doctor() {
  local out rc=0
  out="$("$DOCTOR" --config "$2" 2>&1)" || rc=$?
  if [ "$rc" = "$3" ] && { [ -z "${4:-}" ] || printf '%s' "$out" | grep -q -- "$4"; }; then pass "$1"
  else fail "$1" "rc=$rc $(printf '%s' "$out" | grep -E '^FAIL|failed' | head -3 | tr '\n' ';')"; fi
}
# variant <name> <sed expression>: the example config with one edit
variant() { sed -e "$2" "$EXAMPLE" > "$ROOT/$1.yaml"; }

doctor "config.example.yaml passes every check"                 "$EXAMPLE" 0 'config-check: 0 failed'
printf 'schema: concertmaster.config/v1\n' > "$ROOT/bare.yaml"
doctor "a bare config is missing the required keys"             "$ROOT/bare.yaml" 1 'FAIL project.name'

variant no-org '/^  org: AcmeOrg/d'
doctor "missing github.org fails"                               "$ROOT/no-org.yaml" 1 'FAIL github.org'
variant no-main '/^  main_repo: /d'
doctor "missing github.main_repo fails"                         "$ROOT/no-main.yaml" 1 'FAIL github.main_repo'
variant bad-schema 's/concertmaster.config\/v1/other/'
doctor "wrong schema fails"                                     "$ROOT/bad-schema.yaml" 1 'FAIL schema'
variant no-self 's/^  self_name: .*/  self_gone: x/'
doctor "missing worktrees.self_name fails"                      "$ROOT/no-self.yaml" 1 'FAIL worktrees.self_name'

variant bad-window 's/^  deploy_windows: .*/  deploy_windows: ["25:99"]/'
doctor "a deploy window that is not HH:MM fails"                "$ROOT/bad-window.yaml" 1 'FAIL schedule.deploy_windows'
variant bad-strategy 's/^  strategy: merge .*/  strategy: fast-forward/'
doctor "an unknown merge.strategy fails"                        "$ROOT/bad-strategy.yaml" 1 'FAIL merge.strategy'
variant bad-merge-cmd 's/^  command: .*/  command: "gh pr merge --merge"/'
doctor "a merge.command without {pr} fails"                     "$ROOT/bad-merge-cmd.yaml" 1 'FAIL merge.command'
variant bad-adapter 's/^    adapter: wacli .*/    adapter: pigeon/'
doctor "an unknown owner_digest adapter fails"                  "$ROOT/bad-adapter.yaml" 1 'FAIL messaging.owner_digest.adapter'
variant bad-agent 's/{ name: ops-sweeper, standing: true,  spawn_at: 2, agent: claude/{ name: ops-sweeper, standing: true,  spawn_at: 2, agent: other/'
doctor "a lane with an unknown agent fails"                     "$ROOT/bad-agent.yaml" 1 'FAIL lanes: each has'
variant dup-lane 's/{ name: ops-sweeper,/{ name: dev-sweeper,/'
doctor "a duplicate lane name fails"                            "$ROOT/dup-lane.yaml" 1 'FAIL lanes: names are unique'
variant nt-lane 's/^  never_touch: \[\].*/  never_touch: [pr-sweeper]/'
doctor "a never_touch name that is a lane name fails"           "$ROOT/nt-lane.yaml" 1 'FAIL no never_touch name is a lane name'
variant bad-outward 's/^  everything_else: draft_first.*/  everything_else: whenever/'
doctor "an unknown outward_messages value fails"                "$ROOT/bad-outward.yaml" 1 'FAIL outward_messages'
variant bad-since 's/^  since: .*/  since: "last week"/'
doctor "unlinked_prs.since that is not a UTC time fails"        "$ROOT/bad-since.yaml" 1 'FAIL unlinked_prs.since'

variant http-url 's|^  base_url: ""|  base_url: "http://mc.example.com"|'
doctor "an http telemetry.base_url fails"                       "$ROOT/http-url.yaml" 1 'FAIL telemetry.base_url'
variant https-url 's|^  base_url: ""|  base_url: "https://mc.example.com"|'
doctor "an https telemetry.base_url passes"                     "$ROOT/https-url.yaml" 0 'config-check: 0 failed'
variant bad-project 's/^  project_id: ""/  project_id: "Bad Id"/'
doctor "a malformed telemetry.project_id fails"                 "$ROOT/bad-project.yaml" 1 'FAIL telemetry.project_id'
variant good-project 's/^  project_id: ""/  project_id: "p_acme"/'
doctor "a well-formed telemetry.project_id passes"              "$ROOT/good-project.yaml" 0 'config-check: 0 failed'
variant tenant-placeholder 's/^  tenant_id: ""/  tenant_id: "<paste-tenant-here>"/'
doctor "a placeholder telemetry.tenant_id fails"                "$ROOT/tenant-placeholder.yaml" 1 'FAIL telemetry.tenant_id'
variant token-in-file 's|^  token_file: [^ ]*|  token_file: some-pasted-token-value|'
doctor "a token pasted into token_file fails"                   "$ROOT/token-in-file.yaml" 1 'FAIL telemetry.token_file'
variant chat-no-jid 's/^  chats: {}.*/  chats: { team-chat: { title: "Team Chat" } }/'
doctor "an intake chat without a jid fails"                     "$ROOT/chat-no-jid.yaml" 1 'FAIL intake.chats'

# an env-var-name reference and a path are not secrets
awk '{ print } /^  base_url:/ { print "  api_key: IMGBB_API_KEY"; print "  secret_file: /home/x/.secrets/y" }' "$EXAMPLE" > "$ROOT/refs.yaml"
doctor "env-var-name and path references are not secrets"       "$ROOT/refs.yaml" 0 'config-check: 0 failed'

# a base32 seed (all caps and digits, no underscore) and a base64 token starting with / are NOT references
for pair in "base32:token: JBSWY3DPEHPK3PXPJBSWY3DP" "base64slash:secret: /abcdEFGH0123456789xyz+="; do
  name="${pair%%:*}"; val="${pair#*:}"
  { cat "$EXAMPLE"; printf '# %s\n' "$val"; } > "$ROOT/secret-$name.yaml"
  doctor "secret-looking text ($name) fails" "$ROOT/secret-$name.yaml" 1 'FAIL no secret-looking text'
done

# Secret-looking text, assembled at run time so this file never holds a literal one.
for pair in "sb_""secret_:sb_""secret_$(printf 'a%.0s' 1 2 3 4 5 6 7 8)" "jwt:ey""J$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10)" \
            "anthropic:sk-""ant-$(printf 'c%.0s' 1 2 3 4 5 6)" "password:password: $(printf 'd%.0s' 1 2 3 4 5 6 7 8 9)" \
            "stripe:sk_""live_$(printf 'e%.0s' 1 2 3 4 5 6 7 8)" "github:gh""p_$(printf 'f%.0s' 1 2 3 4 5 6 7 8 9)" \
            "token:token: $(printf 'g%.0s' 1 2 3 4 5 6 7 8 9)" "bang:pass: p@ss!w0rd-$(printf 'h%.0s' 1 2 3)"; do
  name="${pair%%:*}"; val="${pair#*:}"
  { cat "$EXAMPLE"; printf '# %s\n' "$val"; } > "$ROOT/secret-$name.yaml"
  doctor "secret-looking text ($name) fails"                    "$ROOT/secret-$name.yaml" 1 'FAIL no secret-looking text'
done
{ cat "$EXAMPLE"; printf '# a dash %s here\n' "$(printf '\342\200\224')"; } > "$ROOT/emdash.yaml"
doctor "an em-dash fails (house style)"                         "$ROOT/emdash.yaml" 1 'FAIL no em-dash'

# Selection (lib.sh): CM_CONFIG, else config.yaml next to SKILL.md, else
# $CM_HOME/config.yaml; config.example.yaml is never read. A copy of lib.sh in a temp skill tree.
mkdir -p "$ROOT/skill/scripts" "$ROOT/home"
cp "$HERE/../lib.sh" "$ROOT/skill/scripts/lib.sh"
# shellcheck disable=SC2016  # the single-quoted script is for the inner bash
pick() { env -u CM_CONFIG "$@" bash -c '. "$1"; cm_config_file' _ "$ROOT/skill/scripts/lib.sh" 2>/dev/null; }
printf 'schema: x\n' > "$ROOT/skill/config.example.yaml"
if pick CM_HOME="$ROOT/home" >/dev/null; then fail "example only" "config.example.yaml was selected"; else pass "only config.example.yaml present: it is never selected"; fi
printf 'schema: y\n' > "$ROOT/home/config.yaml"
got="$(pick CM_HOME="$ROOT/home")"
if [ "$got" = "$ROOT/home/config.yaml" ]; then pass "\$CM_HOME/config.yaml is the last resort"; else fail "CM_HOME config" "$got"; fi
printf 'schema: z\n' > "$ROOT/skill/config.yaml"
got="$(pick CM_HOME="$ROOT/home")"
if [ "$got" = "$ROOT/skill/scripts/../config.yaml" ]; then pass "config.yaml next to SKILL.md beats config.example.yaml and CM_HOME"; else fail "skill config preferred" "$got"; fi
printf 'schema: w\n' > "$ROOT/override.yaml"
# shellcheck disable=SC2016
got="$(env CM_CONFIG="$ROOT/override.yaml" CM_HOME="$ROOT/home" bash -c '. "$1"; cm_config_file' _ "$ROOT/skill/scripts/lib.sh" 2>/dev/null)"
if [ "$got" = "$ROOT/override.yaml" ]; then pass "CM_CONFIG overrides both"; else fail "CM_CONFIG override" "$got"; fi
# CM_CONFIG set but unreadable: the doctor fails instead of checking another file.
if env CM_CONFIG="$ROOT/nope.yaml" CM_HOME="$ROOT/home" bash "$DOCTOR" >/dev/null 2>&1; then fail "doctor, unreadable CM_CONFIG" "rc 0"; else pass "doctor fails when CM_CONFIG is set but unreadable"; fi
# The doctor with no config at all fails.
rm -f -- "${ROOT:?}/skill/config.yaml" "${ROOT:?}/home/config.yaml"
cp "$DOCTOR" "$ROOT/skill/scripts/config-check.sh"
if env -u CM_CONFIG CM_HOME="$ROOT/home" bash "$ROOT/skill/scripts/config-check.sh" >/dev/null 2>&1; then fail "doctor with no config" "rc 0"; else pass "doctor with no config at all fails"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
