#!/usr/bin/env bash
# automations-audit.sh: list Orca automations that belong to this project and flag the bad ones.
#
#   scripts/automations-audit.sh      # TSV: flag host id name agent enabled schedule
#
# An Orca automation can silently spawn sessions on a timer: a recovery timer left behind
# after a reboot keeps creating duplicate lane sessions for hours. This lists every
# automation on every host whose name contains the project name (project.name), a lane
# name (lanes[].name, placeholder names with "<" skipped) or an entry of automations.names,
# and flags:
#   FORBIDDEN  enabled and runs an agent listed in automations.forbidden_agents (default
#              none; agents.forbidden is read when that key is unset)
#   DUPLICATE  enabled and its NAME matches automations.duplicate_pattern (default
#              sweeper|lead|recovery|resume: a lane-recovery timer): read it with
#              `orca automations show <id>`; disable it when it is redundant with a
#              standing lane (the ledger decides, this script does not)
#   ok         anything else (still listed), and any automation whose exact name is in
#              automations.expected (a deliberate one; FORBIDDEN still applies to it)
# Read-only: it never edits or removes anything. Disable with `orca automations edit`
# only after reading `orca automations show <id>`.
# Exit 0 (rows printed, or none), 2 when the config names nothing to match.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
case "${1:-}" in
  '') ;;
  -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
  *) cm_warn "unknown arg: $1"; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { cm_warn "automations-audit.sh: jq missing"; exit 0; }
ORCA="$(cm_orca)"
NAMES="$(jq -cn --arg p "$(cm_cfg .project.name)" --argjson l "$(cm_cfg_json '[.lanes[]?.name]' '[]')" --argjson x "$(cm_cfg_json '.automations.names' '[]')" \
  '([$p] + $l + $x) | map(select(type == "string" and length > 0 and (contains("<") | not)))')"
[ "$NAMES" != '[]' ] || { cm_warn "automations-audit.sh: no project or lane names in config"; exit 2; }
FORBID="$(cm_cfg_json '.automations.forbidden_agents' "$(cm_cfg_json '.agents.forbidden' '[]')")"
EXPECT="$(cm_cfg_json '.automations.expected' '[]')"
DUP="$(cm_cfg .automations.duplicate_pattern 'sweeper|lead|recovery|resume')"
hosts="local"
for e in $("$ORCA" host list --json 2>/dev/null </dev/null | jq -r '.result.hosts[]? | select(.name != "this machine") | .name'); do
  hosts="$hosts $e"
done
for h in $hosts; do
  args=(); [ "$h" = local ] || args=(--environment "$h")
  cm_timeout 30 "$ORCA" automations list ${args[@]+"${args[@]}"} --json 2>/dev/null </dev/null \
    | jq -r --argjson names "$NAMES" --argjson forbid "$FORBID" --argjson expect "$EXPECT" --arg dup "$DUP" --arg h "$h" '
        def lc: ascii_downcase;
        (.result // .) as $r | ($r.automations // $r) | if type == "array" then .[] else empty end
        | (.name // "") as $n
        | select(any($names[]; . as $x | ($n | lc) | contains($x | lc)))
        | (if (.enabled == true and (.agentId as $a | any($forbid[]; . == $a))) then "FORBIDDEN"
           elif (.enabled == true and (any($expect[]; (. | lc) == ($n | lc)) | not) and ($n | test($dup; "i"))) then "DUPLICATE"
           else "ok" end) as $f
        | [$f, $h, .id, $n, (.agentId // "-"), (.enabled | tostring), (.rrule // "-")] | @tsv'
done
exit 0
