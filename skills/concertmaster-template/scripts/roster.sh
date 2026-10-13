#!/usr/bin/env bash
# roster.sh: rewrite $CM_HOME/roster.yaml from $CM_HOME/ledger.json.
#
#   scripts/roster.sh              # write the roster (atomic, mode 600)
#   scripts/roster.sh --stdout     # print it, write nothing
#
# The roster is a short view of ACTIVE work only: one row per live standing
# lane or live worker (ledger worker state not queued, spawning, gone,
# repurposed, retired, teardown or done: those have no worktree to resume).
# The ledger stays the truth; the roster is rewritten whole every tick and
# read by `/concertmaster resume` (references/resume.md).
#
# Fields per row (an allowlist, so nothing else is copied; free text is cut to
# 200 chars and scrubbed of common token shapes, best effort; the file is mode
# 600): lane, host, worktree, worktreeId, terminal, model, agent, beadsEpic,
# current, prs, state, updatedAt. agent and worktreeId are the two additions to
# the spec's list: resume must not run claude --continue in a codex or agy lane,
# and must match a worktree by its Orca id as classify does.
#
# Exit 0 on success. Exit 1 when the ledger is missing or unreadable: the
# existing roster is left untouched, never emptied.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

STDOUT=0
case "${1:-}" in
  --stdout) STDOUT=1 ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  '') ;;
  *) cm_warn "roster.sh: unknown arg: $1"; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { cm_warn "roster.sh: missing dependency: jq"; exit 1; }

LEDGER="$CM_HOME/ledger.json"
ROSTER="$CM_HOME/roster.yaml"
if ! { [ -s "$LEDGER" ] && jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1; }; then
  cm_warn "roster.sh: ledger $LEDGER missing or unreadable; roster left as is"
  exit 1
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

render() {
  jq -r --arg now "$NOW" '
    def scrub: if type == "string"
      then gsub("(sbp_|sk_live_|sk_test_|ghp_|gho_|github_pat_|sb_secret_|sb_publishable_|whsec_|rk_live_|rk_test_|ghs_|ghu_|ghr_|glpat-|xapp-|xoxa-|xoxe-|AKIA|AIza|eyJ)[A-Za-z0-9_.-]{8,}|\\bBearer +[A-Za-z0-9_.=-]{12,}|\\bsk-[A-Za-z0-9_-]{16,}|\\bxox[bp]-[A-Za-z0-9-]{8,}"; "[redacted]")
           | gsub("[\r\n\t]+"; " ") | .[0:200]
      else . end;
    . as $L
    | (if ($L.prs | type) == "object" then $L.prs else {} end) as $prs
    | [ (if ($L.workers | type) == "object" then $L.workers else {} end) | to_entries[]
        | select(.value | type == "object")
        | select((.value.state // "running") | IN("queued", "spawning", "gone", "repurposed", "retired", "teardown", "done") | not)
        | .key as $id | .value as $w
        | { lane: ($w.lane // null),
            host: ($w.host // null),
            worktree: ($w.path // null),
            worktreeId: (if ($w.worktreeId | type) == "string" then $w.worktreeId else null end),
            terminal: ($w.terminal // null),
            model: ($w.model // null),
            agent: ($w.agent // null),
            beadsEpic: (if ($w.beadsEpic | type) == "string" then $w.beadsEpic else null end),
            current: (($w.current // $w.task // null) | scrub),
            prs: ( ( [ $prs[]? | select(type == "object" and .driver == $id) | .number ]
                     + [ $w.pr? | if type == "number" then . elif type == "object" then .number else empty end ] )
                   | map(select(type == "number")) | unique ),
            state: (($w.lastComment // $w.state // null) | scrub),
            updatedAt: ($w.updatedAt // $L.updatedAt // $now) } ]
    | sort_by(.lane // "", .host // "", .worktree // "") as $rows
    | "# concertmaster roster: active work only, rewritten each tick from ledger.json. Do not edit.",
      "# generated \($now)",
      (if ($rows | length) == 0 then "[]" else
        ($rows[] |
          "- lane: \(.lane | tojson)",
          "  host: \(.host | tojson)",
          "  worktree: \(.worktree | tojson)",
          "  worktreeId: \(.worktreeId | tojson)",
          "  terminal: \(.terminal | tojson)",
          "  model: \(.model | tojson)",
          "  agent: \(.agent | tojson)",
          "  beadsEpic: \(.beadsEpic | tojson)",
          "  current: \(.current | tojson)",
          "  prs: \(.prs | tojson)",
          "  state: \(.state | tojson)",
          "  updatedAt: \(.updatedAt | tostring | tojson)") end)' "$LEDGER"
}

if [ "$STDOUT" = 1 ]; then
  render
  exit 0
fi

umask 077
mkdir -p "$CM_HOME"
TMP="$(mktemp "$CM_HOME/.roster.yaml.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
render > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$ROSTER"
trap - EXIT
