#!/usr/bin/env bash
# followups.sh: the follow-up ledger. Leads and workers report children and open items in their
# Orca worktree comment; this folds them into the ONE ledger (references/ledger.md), so an item
# that must outlive a worker is never held only in a session's memory.
#
#   scripts/followups.sh reconcile [--discover <file>]   # discover JSON on stdin or in <file>
#   scripts/followups.sh close <id> [--lane <lane>]      # close a follow-up from outside a comment
#   scripts/followups.sh open [--lane <lane>]            # open items as TSV: id worker lane owner openedAt text
#   scripts/followups.sh report                          # TSV rows for the turn-end table
#   scripts/followups.sh comment-open                    # one comment on stdin: ids of open tag lines
#
# Comment lines (one per line; a " | " also separates them; a literal \n counts as a newline):
#   cm:child <worktree-name>                             the poster owns that child worktree
#   cm:followup <id> owner=<owner-id|lane|worker> <text>   an open item that outlives the worker
#   cm:followup-done <id>                                closes it
# `id` is kebab-case, at most 40 chars, unique per lane, never reused (a closed id is not reopened by
# a stale line). The owner is lowercased.
#
# reconcile: for every discovered worktree whose comment maps to a live ledger worker (state not
# dead: gone or repurposed), sets workers.<child>.parent from the Orca parentWorktreeId and
# from cm:child (only while unset; a cycle or two different claimants set nothing), upserts
# followUps[] keyed by lane + id, closes the ones with a cm:followup-done line, and mirrors
# items owned by the project owner (owner=<project.owner.id>, compared lowercase) as an asks[] row (kind owner,
# id fu-<lane>-<id>, found again by lane + followUp).
# It prints one line per problem, for the tick report:
#   followups: malformed <worker> <line, first 80 chars>   a cm:child / cm:followup line that does not parse
#   followups: unmatched <host>:<path> <ids>               tagged worktree with no live ledger worker
#   followups: unmatched-child <poster> <name>             a cm:child naming no live ledger worker
#   followups: parent-conflict <child> <parent>,<parent>   two claimants, nothing set
#   followups: reused-id <worker> <id> ...                  a closed id posted again with other text (teardown refuses it too)
# A worktree absent from the census changes nothing: absence never closes anything, and an item moves to
# another poster only when its own worker is no longer live or no longer posts the line (the new
# poster writes the same lane + id and the old one drops it: the handover rule). Idempotent: a
# second run writes nothing. Every write goes through cm_ledger_write.
# report: an item is orphaned when its worker is missing or in a state other than spawning, running,
# stuck, blocked-on-owner or idle (queued, done, retired and teardown count as orphaned on
# purpose: that worker will not act on it); it is listed until it closes or another live worker posts the same
# lane + id. "Orphaned" is worked out when reading, never stored.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

LEDGER="$(cm_ledger_path)"
NOW="$(date -u +%FT%TZ)"
OWNER_ID="$(cm_lower "$CM_OWNER_ID")"   # project.owner.id: the owner= value that means "the project owner"
need_ledger() { [ -s "$LEDGER" ] || { cm_warn "followups.sh: no ledger at $LEDGER"; exit 1; }; }

# shellcheck disable=SC2016  # jq programs, not shell
DEFS='
def cm_state_dead: IN("gone", "repurposed");
def live: ((.state // "") | cm_state_dead | not);
def npath: (. // "") | sub("/+$"; "");
def base: npath | split("/") | last // "";
def clean: tostring | gsub("[[:cntrl:]]+"; " ");
def ups($W; $id): [limit(50; $id | recurse($W[.].parent? // empty | select(type == "string")))];
def fidx($lane; $id): [ (.followUps // [])[] | .lane == $lane and .id == $id ] | index(true);
def alive: IN("spawning", "running", "stuck", "blocked-on-owner", "idle");
# the tag grammar, defined once (comment-open and reconcile both use it)
def tagsegs: (. // "") | tostring | gsub("\\\\n"; "\n")
  | [ split("\n")[] | split(" | ")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) ];
def looksfu: test("(^|[-*+>;,`]\\s*|\\d+\\.\\s+)cm:\\s*(follow[-_ ]?ups?|child)"; "i");
def tags: tagsegs[] | select(test("^cm:(child|followup|followup-done)") or looksfu)
  | (capture("^cm:followup-done\\s+(?<id>[a-z0-9][a-z0-9-]{0,39})(?:\\s.*)?$") | {t: "done", id})
    // (capture("^cm:followup\\s+(?<id>[a-z0-9][a-z0-9-]{0,39})\\s+owner=(?<owner>[A-Za-z0-9._:-]{1,40})(?:\\s+(?<text>.*))?$")
        | {t: "fu", id, owner: (.owner | ascii_downcase), text: ((.text // "") | clean | .[0:200])})
    // (capture("^cm:child\\s+(?<n>\\S+)") | {t: "child", n})
    // {t: "bad", line: .};
# every discovered row with its live ledger worker (null when none) and its parsed tags
def rowposts($ws; $rows): [ $rows[] | . as $r
  | ([ $ws[] | select(live) | select(.host == null or .host == $r.host)
       | select(((.worktreeId // "") != "" and .worktreeId == $r.worktreeId)
                or ((.path // "") != "" and (.path | npath) == ($r.path | npath))) ] | sort_by(.id) | first) as $w
  | {r: $r, w: $w, tags: [ ($r.comment // "") | tags ]} ];
def childid($ws; $k): ([ $ws[] | select(live) | select(.host == null or .host == $k.host)
  | select(.id == $k.name or (.path | base) == $k.name) ] | sort_by(.id) | first | .id?) // null;
# cm:child claims as {child, parent}; claims on one child by different parents are conflicts
def claims($ws; $posts): [ $posts[] | .w as $w | .r.host as $h | .tags[] | select(.t == "child")
  | {child: childid($ws; {host: $h, name: .n}), parent: $w.id, name: .n} | select(.child != null and .child != .parent) ];
def nochild($ws; $posts): [ $posts[] | .w as $w | .r.host as $h | .tags[] | select(.t == "child")
  | select(childid($ws; {host: $h, name: .n}) == null) | {poster: $w.id, name: .n} ];
def setparent($c; $p): if $c == null or $c == $p then .
  elif (.workers[$c].parent // null) != null then .
  elif (ups(.workers; $p) | index($c)) != null then .
  else .workers[$c].parent = $p end;
'

# apply <filter> [jq args...]: write only when the filter changes the ledger; a jq error is an error.
apply() {
  local f="$1" rc=0 err
  shift
  err="$(jq -e "$DEFS (. as \$o | ($f) | . != \$o)" "$@" "$LEDGER" 2>&1 >/dev/null)" || rc=$?
  case "$rc" in
    0) cm_ledger_write "$DEFS $f" "$@" ;;
    1) return 0 ;;
    *) cm_warn "followups.sh: ${err%%$'\n'*}: ledger untouched"; return 1 ;;
  esac
}

cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
  reconcile)
    need_ledger
    DISC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --discover) [ $# -ge 2 ] || { cm_warn "followups.sh: --discover needs a file"; exit 2; }; DISC="$2"; shift 2 ;;
        *) cm_warn "followups.sh: unknown arg: $1"; exit 2 ;;
      esac
    done
    TMPD="$(mktemp "${TMPDIR:-/tmp}/cm-followups.XXXXXX")"
    trap 'rm -f -- "$TMPD"' EXIT
    if [ -n "$DISC" ]; then cat -- "$DISC" > "$TMPD"; else cat > "$TMPD"; fi
    jq -e '.worktrees | type == "array"' "$TMPD" >/dev/null 2>&1 \
      || { cm_warn "followups.sh: not a discover document (no worktrees array): nothing changed"; exit 1; }
    # shellcheck disable=SC2016
    FILTER='
      if ((.followUps // []) | type) != "array" or any((.followUps // [])[]; type != "object") then error("ledger followUps is not an array of objects") else . end
      | . as $L
      | [ ($L.workers // {}) | to_entries[] | select(.value | type == "object") | .value + {id: .key} ] as $ws
      | rowposts($ws; $disc[0].worktrees // []) as $rp
      | ($rp | map(select(.w != null))) as $posts
      # Orca is the authority on parentage; cm:child fills the rest (never a conflicting claim)
      | [ $posts[] | select((.r.parentWorktreeId // "") != "") | .w.id as $c | .r.parentWorktreeId as $pw
          | ([ $ws[] | select(live) | select((.worktreeId // "") != "" and .worktreeId == $pw) ] | sort_by(.id) | first | .id?) as $pid
          | {child: $c, parent: $pid} | select(.parent != null and .parent != .child) ] as $oparents
      | claims($ws; $posts) as $cl
      | ($cl | group_by(.child) | map(select((map(.parent) | unique | length) == 1) | .[0])) as $okclaims
      | reduce ($oparents + $okclaims)[] as $p (.; setparent($p.child; $p.parent))
      | [ $posts[] | .w as $w | .tags[] | select(.t == "fu") | . + {worker: $w.id, lane: ($w.lane // $w.id)} ] as $fus
      | [ $posts[] | .w as $w | .tags[] | select(.t == "done") | {id, lane: ($w.lane // $w.id)} ] as $dones
      | ($L.followUps // []) as $old
      | ($fus | group_by([.lane, .id]) | map(. as $g
          | ([ $old[] | select(.lane == $g[0].lane and .id == $g[0].id) ] | first) as $e
          | if $e != null and ([$g[].worker] | index($e.worker)) != null
            then ($g | map(select(.worker == $e.worker)) | first)
            elif $e != null and $e.state != "done" and any($ws[]; .id == $e.worker and live) and (([$posts[].w.id] | index($e.worker)) == null)
            then $e
            else ($g | sort_by(.worker) | first) end)) as $reps
      | reduce $reps[] as $c (.;
          fidx($c.lane; $c.id) as $i
          | if $i == null
            then .followUps = ((.followUps // []) + [{id: $c.id, worker: $c.worker, lane: $c.lane, owner: $c.owner, text: $c.text,
                                                       state: "open", openedAt: $now, closedAt: null}])
            elif .followUps[$i].state == "done" then .
            elif .followUps[$i].worker == $c.worker and .followUps[$i].owner == $c.owner and .followUps[$i].text == $c.text then .
            else .followUps[$i] |= (. + {worker: $c.worker, owner: $c.owner, text: $c.text}) end)
      | reduce $dones[] as $d (.;
          fidx($d.lane; $d.id) as $i
          | if $i == null or .followUps[$i].state == "done" then .
            else .followUps[$i] |= (. + {state: "done", closedAt: $now}) end)
      # owner is the project owner: one asks[] row (found by lane + followUp, not by id string) so the terminal report lists it
      | reduce (.followUps // [])[] as $f (.;
          ([ (.asks // [])[] | .kind == "owner" and .followUp == $f.id and .lane == $f.lane ] | index(true)) as $j
          | ("fu-\($f.lane)-\($f.id)") as $a0
          | (if any((.asks // [])[]; .id == $a0) then "\($a0)-\((.asks | length))" else $a0 end) as $aid
          | if $f.state != "done" and $f.owner == $oid then
              (if $j == null then .asks = ((.asks // []) + [{id: $aid, kind: "owner", state: "open", askedAt: $now,
                   question: "follow-up \($f.id) (\($f.worker)): \($f.text)", lane: $f.lane, worker: $f.worker, followUp: $f.id}])
               elif .asks[$j].decision == "owner-changed" then .asks[$j] |= (. + {state: "open", decision: null, answeredAt: null, askedAt: $now, worker: $f.worker,
                   question: "follow-up \($f.id) (\($f.worker)): \($f.text)"})
               else . end)
            elif $j != null and .asks[$j].state == "open" then .asks[$j] |= (. + {state: "answered", decision: (if $f.state == "done" then "followup-closed" else "owner-changed" end), answeredAt: $now})
            else . end)
    '
    apply "($FILTER) as \$new | if \$new == . then . else \$new | .updatedAt = \$now end" --arg now "$NOW" --arg oid "$OWNER_ID" --slurpfile disc "$TMPD" || exit 1
    # problems for the tick report: malformed lines, tagged worktrees with no live worker, conflicting parents
    # shellcheck disable=SC2016
    jq -r --slurpfile disc "$TMPD" "$DEFS"'
      [ (.workers // {}) | to_entries[] | select(.value | type == "object") | .value + {id: .key} ] as $ws
      | rowposts($ws; $disc[0].worktrees // []) as $rp
      | ($rp | map(select(.w != null))) as $posts
      | ( $posts[] | .w.id as $w | .tags[] | select(.t == "bad") | "followups: malformed \($w) \(.line | clean | .[0:80])" ),
        ( $rp[] | select(.w == null and (.tags | length) > 0)
          | "followups: unmatched \(.r.host):\(.r.path) \([.tags[] | if .t == "child" then "child:\(.n)" elif .t == "bad" then "bad" else .id end] | join(","))" ),
        ( . as $L | $posts[] | .w as $w | .tags[] | select(.t == "fu") | . as $c
          | select(any(($L.followUps // [])[]; .lane == ($w.lane // $w.id) and .id == $c.id and .state == "done" and .text != $c.text))
          | "followups: reused-id \($w.id) \($c.id) (a closed id is never reopened: post the item under a new id)" ),
        ( nochild($ws; $posts)[] | "followups: unmatched-child \(.poster) \(.name | clean | .[0:80])" ),
        ( . as $L | claims($ws; $posts) | group_by(.child)[] | select((map(.parent) | unique | length) > 1)
          | select(($L.workers[.[0].child].parent // null) == null)
          | "followups: parent-conflict \(.[0].child) \(map(.parent) | unique | join(","))" )' "$LEDGER"
    jq -r '"followups: \([(.followUps // [])[] | select(.state != "done")] | length) open, \([(.followUps // [])[] | select(.state == "done")] | length) done"' "$LEDGER"
    ;;

  close)
    need_ledger
    ID="${1:-}"; LANE=""
    [ -n "$ID" ] || { cm_warn "usage: followups.sh close <id> [--lane <lane>]"; exit 2; }
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --lane) LANE="${2:-}"; shift 2 ;;
        *) cm_warn "followups.sh: unknown arg: $1"; exit 2 ;;
      esac
    done
    HITS="$(jq -r --arg id "$ID" --arg lane "$LANE" '[(.followUps // [])[] | select(.id == $id and .state != "done" and ($lane == "" or .lane == $lane))] | length' "$LEDGER")"
    [ "$HITS" = 1 ] || { cm_warn "followups.sh: $HITS open follow-up(s) match id $ID${LANE:+ in lane $LANE}: need exactly 1 (pass --lane)"; exit 1; }
    # shellcheck disable=SC2016
    apply '
      (.followUps | map(.id == $id and .state != "done" and ($lane == "" or .lane == $lane)) | index(true)) as $i
      | .followUps[$i].lane as $ln
      | .followUps[$i] |= (. + {state: "done", closedAt: $now})
      | reduce (.asks // [] | to_entries[] | select(.value.kind == "owner" and .value.followUp == $id and .value.lane == $ln and .value.state == "open") | .key) as $j (.;
          .asks[$j] |= (. + {state: "answered", decision: "followup-closed", answeredAt: $now}))
      | .updatedAt = $now' --arg now "$NOW" --arg id "$ID" --arg lane "$LANE" || exit 1
    printf 'closed %s\n' "$ID"
    ;;

  open)
    need_ledger
    LANE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --lane) LANE="${2:-}"; shift 2 ;;
        *) cm_warn "followups.sh: unknown arg: $1"; exit 2 ;;
      esac
    done
    jq -r --arg lane "$LANE" "$DEFS"'
      (.followUps // [])[] | select(.state != "done" and ($lane == "" or .lane == $lane))
      | [.id, .worker, .lane, .owner, .openedAt, .text] | map(clean) | @tsv' "$LEDGER"
    ;;

  report)
    need_ledger
    # kind, id, worker, lane, owner, state, text. `orphaned`: open, its worker is missing or not alive
    # (state = the worker state). `followup`: open, its owner is a lane or worker that is gone, idle or
    # missing, or an item owned by the project owner whose ask is no longer open (state owner-answered).
    jq -r --arg oid "$OWNER_ID" "$DEFS"'
      def ci($m; $o): ([ ($m // {}) | keys[] | select(ascii_downcase == $o) ] | first) // $o;
      def ownerstate($o0):
        ci(.lanes; $o0) as $o | ci(.workers; $o0) as $wo
        | if $o0 == $oid then "owner"
        elif ((.lanes // {})[$o] | type) == "object" then
          ((.lanes[$o].state // "absent") as $s
           | (.workers[(.lanes[$o].lead // "")].state // "missing") as $ls
           | if ($s | IN("gone", "idle", "absent", "draining")) then $s
             elif ($ls | IN("missing") or cm_state_dead) then "lead-\($ls)"
             else "running" end)
        elif (.workers[$wo] | type) == "object" then
          (.workers[$wo] as $w | if ($w.state // "") | alive | not then ($w.state // "missing")
                                elif ($w.lastComment // "") | startswith("cm:idle") then "idle" else "running" end)
        else "missing" end;
      . as $r
      | ( [ (.followUps // [])[] | select(.state != "done") | . as $f
            | (($r.workers[$f.worker].state? // "missing") | if alive then empty else . end) as $ps
            | ["orphaned", $f.id, $f.worker, $f.lane, $f.owner, $ps, $f.text] ]
        + [ (.followUps // [])[] | select(.state != "done") | . as $f
            | (if $f.owner == $oid
               then (if any(($r.asks // [])[]; .kind == "owner" and .followUp == $f.id and .lane == $f.lane and .state == "open") then "owner" else "owner-answered" end)
               else ($r | ownerstate($f.owner)) end) as $os
            | select($os | IN("running", "owner") | not)
            | ["followup", $f.id, $f.worker, $f.lane, $f.owner, $os, $f.text] ] )
      | .[] | map(clean) | @tsv' "$LEDGER"
    ;;

  comment-open)
    # one comment on stdin (any text); prints the ids of cm:followup lines with no cm:followup-done line for the same id,
    # and bad:<line> for a cm:followup line that does not parse (it is stored nowhere, so the gate must see it)
    # --texts: each open id is followed by a tab and its text (teardown compares it with a closed row, so a
    # closed id reused for a new item is still caught)
    TX=0; [ "${1:-}" = "--texts" ] && TX=1
    jq -Rrs --argjson tx "$TX" "$DEFS"'
      [ tags ] as $t
      | ([ $t[] | select(.t == "done") | .id ]) as $d
      | ([ $t[] | select(.t == "fu") | select(.id as $i | $d | index($i) | not)
            | if $tx == 1 then "\(.id)\t\(.text)" else .id end ] | unique[]),
        ([ $t[] | select(.t == "bad") | "bad:\(.line | clean | .[0:80])" ] | unique[])'
    ;;

  -h|--help|'') sed -n '2,/^set -euo/{/^#/p;}' "$0"; [ -n "$cmd" ] || exit 2 ;;
  *) cm_warn "followups.sh: unknown command: $cmd"; exit 2 ;;
esac
