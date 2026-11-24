#!/usr/bin/env bash
# lane-record.sh: the lane's state on its GitHub issue, the record that outlives any host (SKILL.md § The tick,
# references/ledger.md § Rebuild).
#
#   scripts/lane-record.sh post <lane> <state-line>   # one `cm:state <lane> <state-line>` comment, only on a change
#   scripts/lane-record.sh read <lane>                # the newest one: `<created_at> cm:state <lane> <state-line>`
#
# The issue is config lanes[].issue (a number) in github.org/github.record_repo (default github.main_repo).
# <state-line> is one line, at most 200 characters, no `@` (it would notify), nothing credential-shaped; its first
# word is the lane state of the ledger (absent, spawning, running, idle, draining, gone). post compares it with the
# ledger lanes.<lane>.recordedState and makes no gh call when it is the same, so a tick may call it for every lane.
# After a post it records recordedState and recordedAt (the comment's created_at) through cm_ledger_write. No
# ledger: nothing is posted (run scripts/ledger-rebuild.sh first), so a tick without a ledger cannot spam the issue.
# read takes only comments by an OWNER, MEMBER or COLLABORATOR (anyone can comment on an issue) whose whole body
# is that one line; it prints nothing when there is none.
# Exit: 0 posted, unchanged, or read; 1 gh failed or the ledger write failed (the reason on stderr: report it,
# never stop the tick on it); 2 usage, a lane with no issue, or a refused line; 3 the ledger belongs to another
# project. Env: CM_GH_TIMEOUT (default 60 s per gh call).
# shellcheck disable=SC2016  # the single-quoted filters are jq programs, not shell
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

die() { printf 'lane-record: %s\n' "$1" >&2; exit "${2:-1}"; }
GH_TIMEOUT="${CM_GH_TIMEOUT:-60}"
LANE_STATES="absent spawning running idle draining gone"

cmd="${1:-}"; lane="${2:-}"
case "$cmd" in
  post) [ $# -eq 3 ] || die "usage: lane-record.sh post <lane> <state-line>" 2 ;;
  read) [ $# -eq 2 ] || die "usage: lane-record.sh read <lane>" 2 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) die "usage: lane-record.sh post <lane> <state-line> | read <lane>" 2 ;;
esac
command -v gh >/dev/null 2>&1 || die "gh not found" 1

issue="$(cm_cfg_json '.lanes' '[]' | jq -r --arg l "$lane" '[.[]? | select(.name == $l) | .issue] | first // empty | select(type == "number" and . >= 1 and . == floor)' 2>/dev/null)"
[ -n "$issue" ] || die "lane '$lane' has no lanes[].issue in the config: nothing recorded" 2
rrepo="$(cm_cfg .github.record_repo "$CM_REPO")"
if [ -z "$CM_ORG" ] || [ -z "$rrepo" ]; then die "github.org and github.record_repo (or main_repo) must be set" 2; fi
api="repos/$CM_ORG/$rrepo/issues/$issue/comments"

if [ "$cmd" = read ]; then
  err="$(mktemp "${TMPDIR:-/tmp}/cm-lane-record.XXXXXX")" || die "cannot create a temp file" 1
  trap 'rm -f -- "${err:?}"' EXIT
  # ponytail: reads every page of the issue; a GraphQL `last:` query if a lane issue grows past a few thousand comments
  raw="$(cm_timeout "$GH_TIMEOUT" gh api --paginate "$api?per_page=100" 2>"$err")" \
    || die "gh read of $CM_ORG/$rrepo#$issue failed: $(head -c 200 "$err" | tr '\n' ' ')" 1
  printf '%s' "$raw" | jq -sr --arg p "cm:state $lane " '
    [ (add // [])[] | select((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
      | (.body // "" | sub("\\s+$"; "")) as $b
      | select(($b | startswith($p)) and ($b | test("[\\r\\n]") | not))
      | {at: (.created_at // ""), id: (.id // 0), body: $b} ]
    | sort_by(.at, .id) | last // empty | "\(.at) \(.body)"' 2>/dev/null \
    || die "the comments of $CM_ORG/$rrepo#$issue were not a comment list" 1
  exit 0
fi

line="$3"
case "$line" in *$'\n'*|*$'\r'*|*@*) die "refused: the state line must be one line with no @ in it" 2 ;; esac
[ "${#line}" -le 200 ] || die "refused: the state line is longer than 200 characters" 2
state="${line%% *}"
case " $LANE_STATES " in *" $state "*) ;; *) die "refused: the first word '$state' is not a lane state ($LANE_STATES)" 2 ;; esac
if printf '%s' "$line" | cm_text_looks_secret; then die "refused: the state line looks like it holds a credential" 2; fi

L="$(cm_ledger_path)"
cm_ledger_guard "$L" || exit 3
[ -s "$L" ] || die "no ledger at $L: nothing posted (run scripts/ledger-rebuild.sh first)" 1
last="$(jq -r --arg l "$lane" '.lanes[$l].recordedState // empty' "$L" 2>/dev/null)" || die "ledger $L unreadable: nothing posted" 1
if [ "$last" = "$line" ]; then printf 'lane-record: %s unchanged\n' "$lane"; exit 0; fi

err="$(mktemp "${TMPDIR:-/tmp}/cm-lane-record.XXXXXX")" || die "cannot create a temp file" 1
trap 'rm -f -- "${err:?}"' EXIT
resp="$(cm_timeout "$GH_TIMEOUT" gh api -X POST "$api" -f body="cm:state $lane $line" 2>"$err")" \
  || die "gh post to $CM_ORG/$rrepo#$issue failed (nothing recorded, the next tick tries again): $(head -c 200 "$err" | tr '\n' ' ')" 1
at="$(printf '%s' "$resp" | jq -r '.created_at // empty' 2>/dev/null)"
[ -n "$at" ] || at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# updatedAt never falls behind the comment, so the rebuild check reads this ledger as current
cm_ledger_write '.lanes[$l].recordedState = $s | .lanes[$l].recordedAt = $at | .updatedAt = ([$now, $at, (.updatedAt // "")] | max)' \
  --arg l "$lane" --arg s "$line" --arg at "$at" --arg now "$now" \
  || die "posted to $CM_ORG/$rrepo#$issue but the ledger was not written: the next tick may post it again" 1
printf 'lane-record: %s posted %s\n' "$lane" "$(printf '%s' "$resp" | jq -r '.html_url // "(no url)"' 2>/dev/null)"
