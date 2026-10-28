#!/usr/bin/env bash
# classify.sh: classify discover.sh output. Reads JSON on stdin.
#
#   scripts/discover.sh | scripts/classify.sh            # JSON
#   scripts/discover.sh | scripts/classify.sh --table    # human table
#
# Env: CM_STUCK_MIN (default 45). Rules live in classify.jq. Reads the ledger
# ($CM_HOME/ledger.json): standing and beads epics come from it alone.
# Without a readable ledger every item is flagged standing-unknown (no retire
# or teardown suggested); names never decide.
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
OUT="$(jq --argjson stuckMin "${CM_STUCK_MIN:-45}" --argjson forbidden "$FORBIDDEN" "${LEDGER_ARGS[@]}" -f "$HERE/classify.jq")"

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
printf '%s\n' "$OUT" | jq -r '
  (["host", "class", "worktree", "branch", "pr", "idle", "suggest"] | @tsv),
  (.items | sort_by(.class, .host)[]
    | [ .host, .class,
        ((.path // "-") | split("/") | last),
        (.branch // "-"),
        (if .pr == null then "-" else "#\(.pr.number) \(.pr.state)" end),
        (if .idleMinutes == null then "-" else "\(.idleMinutes)m" end),
        .suggest ] | @tsv)' | {
  if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}
