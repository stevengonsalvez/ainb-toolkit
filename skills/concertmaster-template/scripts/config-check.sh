#!/usr/bin/env bash
# config-check.sh: the config doctor. Fails when the active config is missing a
# required key, holds a value of the wrong shape (bad enum, bad time, a token
# where a path belongs) or contains anything that looks like a secret.
#
#   scripts/config-check.sh                  # the active config (lib.sh cm_config_file)
#   scripts/config-check.sh --config <file>  # a specific file, e.g. config.example.yaml
#
# Exit 0 when every check passes, 1 on any failure, 2 on a usage error.
# Read-only. The active config is the one lib.sh picks: CM_CONFIG, else config.yaml
# next to SKILL.md, else $CM_HOME/config.yaml (config.example.yaml is never read
# unless named with --config).
# Required: schema, project.name, project.owner.name and id, github.org and
# main_repo, worktrees.orca_repo and self_name, hosts.home. Optional keys are
# checked only when set: the shape of the schedule, merge, messaging, lanes,
# telemetry, ci and unlinked_prs blocks. Run it after every config edit.
# shellcheck disable=SC2016  # the single-quoted filters are jq programs, not shell
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

CFG=""
case "${1:-}" in
  --config) CFG="${2:-}"; [ -n "$CFG" ] || { cm_warn "--config needs a file"; exit 2; } ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  '') ;;
  *) cm_warn "unknown arg: $1"; exit 2 ;;
esac
[ -n "$CFG" ] || [ -z "${CM_CONFIG:-}" ] || [ -r "$CM_CONFIG" ] || { cm_warn "CM_CONFIG=$CM_CONFIG is not readable"; exit 1; }
[ -n "$CFG" ] || CFG="$(cm_config_file)" || { cm_warn "no config.yaml found (CM_CONFIG, next to SKILL.md, or \$CM_HOME)"; exit 1; }
[ -r "$CFG" ] || { cm_warn "cannot read $CFG"; exit 1; }
command -v jq >/dev/null 2>&1 || { cm_warn "missing dependency: jq"; exit 1; }
command -v yq >/dev/null 2>&1 || { cm_warn "missing dependency: yq (mikefarah v4)"; exit 1; }
JSON="$(yq -o=json -I=0 '.' "$CFG" 2>/dev/null)" || { cm_warn "$CFG is not valid YAML"; exit 1; }
printf '%s' "$JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || { cm_warn "$CFG is not a YAML mapping"; exit 1; }

FAILS=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$1"; }

# req <label> <jq filter that must be true>
req() {
  if printf '%s' "$JSON" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}
# opt <label> <jq path> <jq predicate on the value>: passes when the key is absent or null
opt() {
  req "$1" "($2) as \$v | \$v == null or (\$v | $3)"
}
nonempty_str='(type == "string" and length > 0)'
hhmm='(type == "array" and all(.[]; type == "string" and test("^([01][0-9]|2[0-3]):[0-5][0-9]$")))'

printf 'config: %s\n' "$CFG"
req "schema is concertmaster.config/v1"        '.schema == "concertmaster.config/v1"'
req "project.name"                              ".project.name | $nonempty_str"
req "project.owner.name"                        ".project.owner.name | $nonempty_str"
req "project.owner.id"                          ".project.owner.id | $nonempty_str"
req "github.org"                                ".github.org | $nonempty_str"
req "github.main_repo"                          ".github.main_repo | $nonempty_str"
req "worktrees.orca_repo"                       ".worktrees.orca_repo | $nonempty_str"
req "worktrees.self_name"                       ".worktrees.self_name | $nonempty_str"
req "hosts.home"                                ".hosts.home | $nonempty_str"

opt "github.exclude_repo_patterns is a list of strings" '.github.exclude_repo_patterns' 'type == "array" and all(.[]; type == "string" and length > 0)'
opt "worktrees.never_touch is a list of strings"        '.worktrees.never_touch' 'type == "array" and all(.[]; type == "string" and length > 0)'
opt "worktrees.path_match compiles as a regex"          '.worktrees.path_match' 'type == "string" and (. as $re | try ("" | test($re) | true) catch false)'
opt "hosts.min_free_disk_gb is a number"                '.hosts.min_free_disk_gb' 'type == "number" and . >= 0'
opt "schedule.deploy_windows are HH:MM"                 '.schedule.deploy_windows' "$hhmm"
opt "schedule.digest_times are HH:MM"                   '.schedule.digest_times' "$hhmm"
opt "schedule.tick_delays_s are positive numbers"       '.schedule.tick_delays_s' 'type == "object" and all(.[]; type == "number" and . > 0)'
opt "merge.strategy is merge, squash or rebase"         '.merge.strategy' 'IN("merge", "squash", "rebase")'
opt "merge.command names the PR ({pr})"                 '.merge.command' 'type == "string" and contains("{pr}")'
opt "messaging.owner_digest.adapter is wacli, slack, email or none" '.messaging.owner_digest.adapter' 'IN("wacli", "slack", "email", "none")'
req "messaging.owner_digest.send is set unless the adapter is none" \
  '(.messaging.owner_digest // null) as $d | $d == null or ($d.adapter // "none") == "none" or ($d.send | type == "string" and length > 0)'
opt "outward_messages values are autonomous or draft_first" '.outward_messages' 'type == "object" and all(.[]; IN("autonomous", "draft_first"))'
opt "lanes: each has a name, a boolean standing and a known agent" '.lanes' \
  'type == "array" and all(.[]; (.name | type == "string" and length > 0) and (.standing | type == "boolean") and ((.agent // "claude") | IN("claude", "codex", "agy")))'
opt "lanes: names are unique"                           '.lanes' '(map(.name) | length) == (map(.name) | unique | length)'
req "no never_touch name is a lane name" \
  '((.worktrees.never_touch // []) | map(ascii_downcase)) as $nt
   | ([(.lanes // [])[] | .name | ascii_downcase] | map(select(. as $k | $nt | index($k))) | length) == 0'
opt "telemetry.base_url is https (or empty)"            '.telemetry.base_url' 'type == "string" and (. == "" or startswith("https://"))'
opt "telemetry.project_id matches ^p_[a-z0-9][a-z0-9-]{0,38}\$ (or empty)" '.telemetry.project_id' 'type == "string" and (. == "" or test("^p_[a-z0-9][a-z0-9-]{0,38}$"))'
opt "telemetry.tenant_id is not a placeholder"          '.telemetry.tenant_id' 'type == "string" and (test("[<>\"[:space:]]") | not)'
opt "telemetry.token_file is a path (~, / or \$), never a token" '.telemetry.token_file' 'type == "string" and test("^(~|/|\\$)[^ ]*$")'
opt "intake.chats: each chat has a jid"                 '.intake.chats' 'type == "object" and all(.[]; (.jid | type == "string" and length > 0))'
opt "away.timeout_minutes is a positive number"         '.away.timeout_minutes' 'type == "number" and . > 0'
opt "ci.queue.threshold and minutes are positive numbers" '.ci.queue' 'type == "object" and ((.threshold // 1) | type == "number" and . > 0) and ((.minutes // 1) | type == "number" and . > 0)'
opt "unlinked_prs.since is an ISO-8601 UTC time"        '.unlinked_prs.since' 'type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
opt "unlinked_prs.skip_authors is a list of strings"    '.unlinked_prs.skip_authors' 'type == "array" and all(.[]; type == "string" and length > 0)'
opt "unlinked_prs.include_drafts is a boolean"          '.unlinked_prs.include_drafts' 'type == "boolean"'
opt "unlinked_prs.timeout_s is a positive number"       '.unlinked_prs.timeout_s' 'type == "number" and . > 0'
opt "automations.names is a list of strings"            '.automations.names' 'type == "array" and all(.[]; type == "string" and length > 0)'
opt "automations.expected is a list of strings"         '.automations.expected' 'type == "array" and all(.[]; type == "string" and length > 0)'
opt "automations.forbidden_agents is a list of strings" '.automations.forbidden_agents' 'type == "array" and all(.[]; type == "string" and length > 0)'
opt "automations.duplicate_pattern compiles as a regex" '.automations.duplicate_pattern' 'type == "string" and (. as $re | try ("" | test($re) | true) catch false)'

# Secrets and house style, on the raw text. Pieces are split so this file never
# holds a literal token prefix itself.
PREFIX_RE="sb_""secret_|s""bp_[A-Za-z0-9]|sb_""publishable_|ey""J[A-Za-z0-9_-]{8,}|sk-""ant-|sk-""proj-|gh""p_[A-Za-z0-9]{8,}|github_""pat_|sk_""live_|rk_""live_|wh""sec_|AI""za[A-Za-z0-9_-]{8,}|AK""IA[A-Z0-9]{8,}|xo""x[bp]-|xkeys""ib-|-----BEGIN [A-Z ]*PRIVATE KEY"
# key: value pairs whose key names a secret; a value that is an env var name (A-Z0-9_) or
# a path (~, /, $) is a reference, not a secret.
KV_RE="(password|passwd|pass|api[_-]?key|secret|token|auth[_-]?token)[[:space:]]*[:=][[:space:]]*[\"']?[^\"'[:space:]#]{8,}"
LEAK=""
if LC_ALL=C grep -Eiq -- "$PREFIX_RE" "$CFG"; then LEAK=prefix; fi
# A reference is an env var name WITH an underscore (API_KEY_NAME: a base32 seed has none) or an
# absolute path under a well-known root (a base64 token that starts with / does not).
ENVNAME_RE='^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$'
PATH_RE='^(~/|\$[A-Z_]+/|/(home|etc|usr|var|opt|tmp|Users)/)[A-Za-z0-9._/-]*$'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  val="${line#*[:=]}"; val="$(printf '%s' "$val" | sed -e "s/^[[:space:]]*//" -e "s/^[\"']//" -e "s/[\"'].*\$//")"
  if printf '%s' "$val" | LC_ALL=C grep -Eq -- "$ENVNAME_RE|$PATH_RE"; then continue; fi
  LEAK=keyvalue
done <<EOT
$(LC_ALL=C grep -Eio -- "$KV_RE" "$CFG")
EOT
if [ -n "$LEAK" ]; then bad "no secret-looking text in $(basename "$CFG") ($LEAK)"; else ok "no secret-looking text in $(basename "$CFG")"; fi
EMDASH="$(printf '\342\200\224')"
if grep -q -- "$EMDASH" "$CFG"; then bad "no em-dash in $(basename "$CFG")"; else ok "no em-dash in $(basename "$CFG")"; fi

printf 'config-check: %s failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
