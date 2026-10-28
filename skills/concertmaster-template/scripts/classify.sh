#!/usr/bin/env bash
# classify.sh: classify discover.sh output. Reads JSON on stdin.
#
#   scripts/discover.sh | scripts/classify.sh            # JSON
#   scripts/discover.sh | scripts/classify.sh --table    # human table
#
# Env: CM_STUCK_MIN (default 45), CM_CONFIG (config file override). Rules live
# in classify.jq. Reads the ledger ($CM_HOME/ledger.json): standing and beads
# epics come from it alone. Without a readable ledger every item is flagged
# standing-unknown (no retire or teardown suggested); names never decide.
# Reads the active config through lib.sh (CM_CONFIG, else config.yaml next to
# SKILL.md, else $CM_HOME/config.yaml; never config.example.yaml): its
# `ownership` block gives every in-scope worktree an `owner`, flags rows nobody
# owns ORPHAN and a lane lead whose session is gone while it owns open work
# LEAD-DEAD (SKILL.md § Ownership). No readable config: ownership is skipped
# (.ownership.configured=false), never guessed.
# Forbidden agents (config agents.forbidden, env CM_FORBIDDEN_AGENTS): each terminal in
# discover's `terminals` running one is a `.violations` row (host, worktree, handle, title,
# agent); --table prints a `violations:` line and one VIOLATION row each. Unlisted, offline,
# cut-off or failed hosts make the check incomplete (CHECK INCOMPLETE), never "none".
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
MODE=json
case "${1:-}" in
  --table) MODE=table ;;
  -h|--help) sed -n '2,/^set -euo/{/^#/p;}' "$0"; exit 0 ;;
  '') ;;
  *) printf 'classify.sh: unknown arg: %s\n' "$1" >&2; exit 2 ;;
esac

LEDGER="${CM_HOME:-$HOME/.concertmaster}/ledger.json"
if [ -s "$LEDGER" ] && jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1; then
  LEDGER_ARGS=(--slurpfile ledger "$LEDGER")
else
  printf 'classify.sh: ledger %s missing or unreadable: every item standing-unknown\n' "$LEDGER" >&2
  LEDGER_ARGS=(--argjson ledger '[]')
fi

FORBIDDEN="$(jq -nc --arg s "$CM_FORBIDDEN_AGENTS" '$s | split(" ") | map(select(length > 0))')"
OWN=null
OWN_ERR=""
if [ -n "${CM_CONFIG:-}" ] && [ ! -r "$CM_CONFIG" ]; then
  OWN_ERR="CM_CONFIG=$CM_CONFIG is not readable"
  printf 'classify.sh: %s: ownership accounting skipped\n' "$OWN_ERR" >&2
elif [ -z "${CM_CONFIG_FILE:-}" ]; then
  OWN_ERR="no config.yaml found"
  printf 'classify.sh: %s: ownership accounting skipped\n' "$OWN_ERR" >&2
elif OWN="$(printf '%s' "$CM_CFG_JSON" | jq -ce '
        def strs: type == "array" and all(.[]; type == "string");
        def lanes: type == "object" and length > 0 and all(.[]; type == "string" and length > 0);
        {repo: .worktrees.orca_repo, self: .worktrees.self_name, neverTouch: (.worktrees.never_touch // []),
         leads: (.ownership.leads // {}), prefixes: (.ownership.prefixes // {}),
         markers: (.ownership.comment_markers // []), stopWords: (.ownership.comment_stop_words // []),
         scratchPathRegex: ((.ownership.scratch_path_regex // null) as $r
           | if $r == null then null
             elif (try ("" | test($r) | true) catch false) and ($r | contains("(?<worker>")) then $r
             else null end)}
        | select((.repo | type == "string" and length > 0) and (.self | type == "string" and length > 0)
                 and (.neverTouch | strs) and (.leads | lanes) and (.prefixes | lanes)
                 and (.markers | strs and length > 0 and all(.[]; length > 0)) and (.stopWords | strs))' 2>/dev/null)" \
   && [ -n "$OWN" ]; then
  :
else
  OWN=null
  OWN_ERR="ownership config missing or malformed in $CM_CONFIG_FILE (yq missing or the ownership block invalid: needs worktrees.orca_repo, worktrees.self_name, ownership.leads, prefixes and comment_markers)"
  printf 'classify.sh: %s: ownership accounting skipped\n' "$OWN_ERR" >&2
fi

OUT="$(jq --argjson stuckMin "${CM_STUCK_MIN:-45}" --argjson forbidden "$FORBIDDEN" --argjson own "$OWN" --arg ownErr "$OWN_ERR" "${LEDGER_ARGS[@]}" -f "$HERE/classify.jq")"

if [ "$MODE" = json ]; then
  printf '%s\n' "$OUT"
  exit 0
fi

printf '%s\n' "$OUT" | jq -r '"summary: " + (.summary | to_entries | map("\(.key)=\(.value)") | join(" "))'
# A forbidden agent on project work: always a line when the census is on, never silent.
printf '%s\n' "$OUT" | jq -r 'if .violationCheck.enabled | not then "violations: off (agents.forbidden is empty)"
  else "violations: \(.violations | length)"
    + (if .violationCheck.complete then "" else " (CHECK INCOMPLETE: \(.violationCheck.gaps | join("; ")))" end) end'
printf '%s\n' "$OUT" | jq -r '.violations[] | ["VIOLATION", .agent, .host, .worktree, (.handle // "-"), (.title // "-")] | @tsv' | {
  if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}
printf '%s\n' "$OUT" | jq -r '"ownership: " + (if .ownership.configured then "orphans=\(.ownership.orphans) lead-dead=\(.ownership.leadDead | length)" else "NOT CONFIGURED, ownership is off: \(.ownership.error)" end)'
printf '%s\n' "$OUT" | jq -r '
  (["host", "class", "worktree", "owner", "branch", "pr", "idle", "flags", "suggest"] | @tsv),
  (.items | sort_by(.class, .host)[]
    | [ .host, .class,
        ((.path // "-") | split("/") | last),
        (.owner // "-"),
        (.branch // "-"),
        (if .pr == null then "-" else "#\(.pr.number) \(.pr.state)" end),
        (if .idleMinutes == null then "-" else "\(.idleMinutes)m" end),
        ([.flags[]? | select(. == "ORPHAN" or . == "LEAD-DEAD")] | join(",") | if . == "" then "-" else . end),
        .suggest ] | @tsv)' | {
  if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}
