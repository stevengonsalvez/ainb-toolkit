#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
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
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
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
doctor "the example schedule.stall_rungs_min is accepted"        "$EXAMPLE" 0 'ok   schedule.stall_rungs_min'
variant no-stall-rungs '/^  stall_rungs_min: /d'
doctor "an unset schedule.stall_rungs_min is fine (defaults)"   "$ROOT/no-stall-rungs.yaml" 0 'config-check: 0 failed'
variant bad-stall-rungs 's/^  stall_rungs_min: .*/  stall_rungs_min: [60, 30, 90]/'
doctor "stall_rungs_min out of order fails"                     "$ROOT/bad-stall-rungs.yaml" 1 'FAIL schedule.stall_rungs_min'
variant short-stall-rungs 's/^  stall_rungs_min: .*/  stall_rungs_min: [30, 60]/'
doctor "stall_rungs_min with two rungs fails"                   "$ROOT/short-stall-rungs.yaml" 1 'FAIL schedule.stall_rungs_min'
variant good-delegated 's/^  delegated_classes: .*/  delegated_classes: ["store build", "play ?listing"]/'
doctor "drive.delegated_classes with valid fragments passes"    "$ROOT/good-delegated.yaml" 0 'ok   drive.delegated_classes'
variant bad-delegated 's/^  delegated_classes: .*/  delegated_classes: ["store build", "(unclosed"]/'
doctor "a delegated class that is not a regex fails"            "$ROOT/bad-delegated.yaml" 1 'FAIL drive.delegated_classes'
variant wild-delegated 's/^  delegated_classes: .*/  delegated_classes: ["store build", "ship.*"]/'
doctor "a delegated class with a wildcard dot fails"             "$ROOT/wild-delegated.yaml" 1 'FAIL drive.delegated_classes'
variant word-delegated 's/^  delegated_classes: .*/  delegated_classes: ["\\\\w+ build"]/'
doctor "a delegated class with a word wildcard fails"            "$ROOT/word-delegated.yaml" 1 'FAIL drive.delegated_classes'
variant empty-delegated 's/^  delegated_classes: .*/  delegated_classes: ["store build", "(beta)?"]/'
doctor "a delegated class that matches the empty text fails"     "$ROOT/empty-delegated.yaml" 1 'FAIL drive.delegated_classes'
variant class-delegated 's/^  delegated_classes: .*/  delegated_classes: ["beta go[ .-]?live", "over[ -]?the[ -]?air", "ota (release|bundle)"]/'
doctor "a dot inside a bracket class is not a wildcard"          "$ROOT/class-delegated.yaml" 0 'ok   drive.delegated_classes'
variant golive-delegated 's/^  delegated_classes: .*/  delegated_classes: ["go[ .-]?live"]/'
doctor "one optional bracket class between literal text (go[ .-]?live) passes" "$ROOT/golive-delegated.yaml" 0 'ok   drive.delegated_classes'
# a bracket class with a repeat, or a negated class, absorbs free words: "ship the store foo bar baz build to production"
# ...and chained bracket classes (each one optional or not) and the any-character escapes \N \X \O \H \R
for frag in 'store [a-z ]+' 'ship [^x]*' 'ship [^x]' 'store [a-z ]{0,40}' 'store([a-z ])*' 'store\\s+build' \
            'store[a-z ]?[a-z ]?[a-z ]?build' 'store [a-z][a-z][a-z] build' 'store ([a-z ])?([a-z ])? build' \
            'store \\N build' 'store \\X build' 'store \\O build' 'store \\H build' 'store \\R build'; do
  yq ".drive.delegated_classes = [\"store build\", \"$frag\"]" "$EXAMPLE" > "$ROOT/rep-delegated.yaml"
  doctor "a delegated class that can absorb free words fails ($frag)" "$ROOT/rep-delegated.yaml" 1 'FAIL drive.delegated_classes'
done
variant bad-outward 's/^  everything_else: draft_first.*/  everything_else: whenever/'
doctor "an unknown outward_messages value fails"                "$ROOT/bad-outward.yaml" 1 'FAIL outward_messages'
variant bad-since 's/^  since: .*/  since: "last week"/'
doctor "unlinked_prs.since that is not a UTC time fails"        "$ROOT/bad-since.yaml" 1 'FAIL unlinked_prs.since'

variant bad-cap 's/^  defaults: { role: general, maxWorkers: 4 }/  defaults: { role: general, maxWorkers: 0 }/'
doctor "a hosts.defaults.maxWorkers of 0 fails"                 "$ROOT/bad-cap.yaml" 1 'FAIL hosts.defaults.maxWorkers'
variant frac-cap 's/^    local: { role: general, maxWorkers: 6 }/    local: { role: general, maxWorkers: 2.5 }/'
doctor "a hosts.per_host maxWorkers that is not whole fails"    "$ROOT/frac-cap.yaml" 1 'FAIL hosts.per_host: every maxWorkers'
variant str-cap 's/^    local: { role: general, maxWorkers: 6 }/    local: { role: general, maxWorkers: many }/'
doctor "a hosts.per_host maxWorkers that is a word fails"       "$ROOT/str-cap.yaml" 1 'FAIL hosts.per_host: every maxWorkers'
variant bad-alias 's/^  ignore_hosts: \[\]/  host_aliases: { a: 7 }\n  ignore_hosts: []/'
doctor "health.host_aliases with a number in it fails"          "$ROOT/bad-alias.yaml" 1 'FAIL health.host_aliases'
variant good-alias 's/^  ignore_hosts: \[\]/  host_aliases: { a: [b, c] }\n  ignore_hosts: []/'
doctor "health.host_aliases as a map of name lists passes"      "$ROOT/good-alias.yaml" 0 'config-check: 0 failed'

variant bad-forbidden 's/^  forbidden_agents: \[\]/  forbidden_agents: codex/'
doctor "automations.forbidden_agents that is not a list fails"  "$ROOT/bad-forbidden.yaml" 1 'FAIL automations.forbidden_agents'
variant bad-path-match 's|^  path_match: "[^"]*"|  path_match: "([unclosed"|'
doctor "a worktrees.path_match that does not compile fails"     "$ROOT/bad-path-match.yaml" 1 'FAIL worktrees.path_match'
variant bad-dup-pattern 's/^  duplicate_pattern: "[^"]*"/  duplicate_pattern: "([unclosed"/'
doctor "an automations.duplicate_pattern that does not compile fails" "$ROOT/bad-dup-pattern.yaml" 1 'FAIL automations.duplicate_pattern'

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
awk '{ print } /^  base_url:/ { print "  api_key: TELEMETRY_API_KEY"; print "  secret_file: /home/x/.secrets/y" }' "$EXAMPLE" > "$ROOT/refs.yaml"
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
# health.host_aliases: a name must not be another host's key, hostname or alias (the probe's identity check and the stop
# check before a sleep would take that machine for this host). Base: two hosts with a hostname each.
yq '.hosts.per_host.host-a = {"role": "general", "hostname": "alpha"} | .hosts.per_host.host-b = {"role": "general", "hostname": "beta"}' "$EXAMPLE" > "$ROOT/ident-base.yaml"
doctor "the base config with two distinct hostnames passes"      "$ROOT/ident-base.yaml" 0 'config-check: 0 failed'
yq '.health.host_aliases.host-b = ["beta-alt"]' "$ROOT/ident-base.yaml" > "$ROOT/alias-ok.yaml"
doctor "a host alias nobody else owns passes"                   "$ROOT/alias-ok.yaml" 0 'config-check: 0 failed'
yq '.health.host_aliases.host-b = ["alpha"]' "$ROOT/ident-base.yaml" > "$ROOT/alias-hostname.yaml"
doctor "an alias equal to another host's hostname fails"        "$ROOT/alias-hostname.yaml" 1 "FAIL no host name"
yq '.health.host_aliases.host-b = ["HOST-A"]' "$ROOT/ident-base.yaml" > "$ROOT/alias-key.yaml"
doctor "an alias equal to another host's key fails (case ignored)" "$ROOT/alias-key.yaml" 1 "FAIL no host name"
yq '.health.host_aliases.host-a = ["vm-0-12"] | .health.host_aliases.host-b = ["vm-0-12"]' "$ROOT/ident-base.yaml" > "$ROOT/alias-twice.yaml"
doctor "a name listed under two hosts fails"                    "$ROOT/alias-twice.yaml" 1 "FAIL no host name"
yq '.health.host_aliases.host-b = ["host-b", "Host-B.example.net"]' "$ROOT/ident-base.yaml" > "$ROOT/alias-own.yaml"
doctor "an alias equal to its own host's key is only redundant, it passes" "$ROOT/alias-own.yaml" 0 'config-check: 0 failed'
yq '.hosts.per_host.host-a.hostname = "beta"' "$ROOT/ident-base.yaml" > "$ROOT/ident-hostnames.yaml"
doctor "host-a.hostname equal to host-b's hostname fails"        "$ROOT/ident-hostnames.yaml" 1 "FAIL no host name .*beta"
yq '.hosts.per_host.local.hostname = "box-main" | .health.host_aliases.host-b = ["box-main"]' "$ROOT/ident-base.yaml" > "$ROOT/ident-local.yaml"
doctor "an alias equal to local's hostname fails"                "$ROOT/ident-local.yaml" 1 "FAIL no host name .*box-main"
yq '.hosts.per_host.local.hostname = "box-main"' "$ROOT/ident-base.yaml" > "$ROOT/ident-local-ok.yaml"
doctor "local's own hostname alone passes"                       "$ROOT/ident-local-ok.yaml" 0 'config-check: 0 failed'
yq '.health.host_aliases.host-b = "beta-alt"' "$ROOT/ident-base.yaml" > "$ROOT/alias-notlist.yaml"
doctor "an alias value that is not a list fails"                 "$ROOT/alias-notlist.yaml" 1 'FAIL health.host_aliases'
# health.host_aliases has one shape (host -> names hostname -s answers as); fleet names of one machine are hosts.same_machine
yq '.health.host_aliases = [["host-a", "host-b"]]' "$ROOT/ident-base.yaml" > "$ROOT/alias-listform.yaml"
doctor "health.host_aliases as a list of name lists fails, pointing at hosts.same_machine" "$ROOT/alias-listform.yaml" 1 'FAIL health.host_aliases maps a host name to a list of host names (a list of name lists belongs in hosts.same_machine)'
doctor "...and the identity check still reads the config (no 'unreadable')" "$ROOT/alias-listform.yaml" 1 'ok   no host name (key, hostname, alias, ledger hostname) belongs to two hosts'
yq '.hosts.same_machine = [["host-a", "host-b"]]' "$ROOT/ident-base.yaml" > "$ROOT/same-ok.yaml"
doctor "hosts.same_machine as a list of name lists passes"      "$ROOT/same-ok.yaml" 0 'ok   hosts.same_machine is a list of fleet name lists'
yq '.hosts.same_machine = [["host-a"]]' "$ROOT/ident-base.yaml" > "$ROOT/same-one.yaml"
doctor "a hosts.same_machine group of one name fails"           "$ROOT/same-one.yaml" 1 'FAIL hosts.same_machine'
yq '.hosts.same_machine = {"host-a": ["host-b"]}' "$ROOT/ident-base.yaml" > "$ROOT/same-map.yaml"
doctor "hosts.same_machine as a map fails"                      "$ROOT/same-map.yaml" 1 'FAIL hosts.same_machine'
mkdir -p "$CM_HOME"
printf '{"schema":"concertmaster.ledger/v1","workers":{},"hosts":{"host-b":{"hostname":"alpha"}}}\n' > "$CM_HOME/ledger.json"
doctor "a ledger hosts.<h>.hostname equal to another host's hostname fails" "$ROOT/ident-base.yaml" 1 "FAIL no host name .*alpha"
printf '{"schema":"concertmaster.ledger/v1","workers":{},"hosts":{"host-b":{"hostname":"beta"}}}\n' > "$CM_HOME/ledger.json"
doctor "a ledger hostname that is its own host's name passes, with the ledger read" "$ROOT/ident-base.yaml" 0 'ledger hosts'
rm -f "$CM_HOME/ledger.json"
doctor "with no ledger the check says INFO and the config still passes" "$ROOT/ident-base.yaml" 0 'INFO host identity set: no ledger'

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
