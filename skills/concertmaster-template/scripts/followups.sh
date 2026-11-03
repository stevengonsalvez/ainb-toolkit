#!/usr/bin/env bash
# followups.sh: the follow-up ledger. Leads and workers report children and open items in their
# Orca worktree comment; this folds them into the ONE ledger (references/ledger.md), so an item
# that must outlive a worker is never held only in a session's memory.
#
#   scripts/followups.sh reconcile [--discover <file>]   # discover JSON on stdin or in <file>
#   scripts/followups.sh close <id> [--lane <lane>]      # close a follow-up from outside a comment
#   scripts/followups.sh open [--lane <lane>]            # open items as TSV: id worker lane owner openedAt text
#   scripts/followups.sh for-worktree <name-or-path>     # open items of that worktree's worker and its children, as `open`
#   scripts/followups.sh report                          # TSV rows for the turn-end table
#   scripts/followups.sh escalate [--create --only <lane/id@fp,...> | --create --all-candidates] [--after-hours <n>] [--max <n>] [--show <n>] | escalate --resolve <lane>/<id> <n|release>   # GitHub issue for old or cross-lane items
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
# Child adoption (a lead-spawned child has no ledger row, so teardown would refuse "standing unknown"): a
# cm:child <name> posted by a live ledger worker, naming a discovered worktree on the same host (Orca
# displayName or path basename) that no live ledger worker covers, is added as workers.<name> with standing
# false, adopted true, the poster lane, beadsEpic from an `epic=<bead-id>` token on the same line (else null), path/host/worktreeId from the census, and the state its OWN comment
# reports on its first line (cm:running running, cm:blocked blocked-on-owner, cm:done done, cm:retire retired,
# cm:failed stuck, ...; no cm: tag yet: spawning). An existing ledger worker is never overwritten (a taken key
# is skipped and reported). Written through cm_ledger_write only (atomic, locked).
# It prints one line per problem, for the tick report:
#   followups: adopted <name> (child of <poster>, standing false, state <s>)   a child added to the ledger
#   followups: adopt-skipped <name> (ledger id already taken ...)               a dead row holds the id: nothing written
#   followups: malformed <worker> <line, first 80 chars>   a cm:child / cm:followup line that does not parse
#   followups: unmatched <host>:<path> <ids>               tagged worktree with no live ledger worker
#   followups: unmatched-child <poster> <name>             a cm:child naming no live ledger worker
#   followups: parent-conflict <child> <parent>,<parent>   two claimants, nothing set
#   followups: reused-id <worker> <id> ...                  a closed id posted again with other text (teardown refuses it too)
# A worktree absent from the census changes nothing: absence never closes anything, and an item moves to
# another poster only when its own worker is no longer live or no longer posts the line (the new
# poster writes the same lane + id and the old one drops it: the handover rule). Idempotent: a
# second run writes nothing. Every write goes through cm_ledger_write.
# for-worktree: the open items (same TSV as `open`) posted by the ledger worker that owns the worktree (path or
# directory name equals the argument, or the worker id) and by every worker below it (parent chain). Exit 3 when
# no ledger worker owns it (nothing is known), 1 when the ledger is unusable. An item that already has a GitHub
# issue (escalate, issue / issueUrl set) lives on there, so it is not listed and does not block a teardown.
# The match is by path, directory name or worker id, with no host: the same absolute path on two hosts lists
# both workers' items, which errs toward listing too much. scripts/salv3.sh calls it so a
# salvage lists what must outlive the worker.
# escalate: for each OPEN follow-up with no issue yet that has been open over followups.escalate_after_hours
# (default 24, or --after-hours) OR whose owner lane differs from the lane that posted it (an owner that is a
# lane, or a worker of another lane; the project owner and an unknown owner never count as cross-lane), it makes
# ONE issue in github.org/github.main_repo: title from the id and text, labels from followups.issue_labels (default
# none), a body with the owner, the source worktree name and the age. The issue number goes onto the follow-up
# (issue, issueUrl, escalatedAt, through cm_ledger_write) so a second run never makes a second one. DEFAULT IS
# A DRY RUN: it prints "would create" lines (bodies for the first --show, default 5) and the exact --only line to
# approve, and writes nothing; --create is needed to touch GitHub and needs --only <lane/id@fingerprint,...> (the
# entries the owner approved from the dry run, copied as printed; the fingerprint covers the owner and text, so a
# follow-up changed since needs a new dry run; the list is not worked out again at create time) or the explicit
# --all-candidates. The body holds no path, brief or credential: a text that looks like one is refused (printed,
# left unmarked). Budget: nothing is created when `gh api rate_limit` (free) reports under 800 calls left or cannot
# be read; a run within 180 s of the last --create run does nothing (the poll floor); at most --max (default 5)
# issues per run, and the first gh failure stops the run (never a retry loop) and leaves that item unmarked.
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
    // (capture("^cm:child\\s+(?<n>[^\\s@]+)(?:@(?<h>\\S+))?(?<r>.*)$")
        | {t: "child", n, h: (.h // null), es: ([ .r | scan("(?:^|\\s)epic=([A-Za-z0-9._-]+)") | .[0] ] | unique)} | . + {e: (.es | first // null)})
    // {t: "bad", line: .};
# every discovered row with its live ledger worker (null when none) and its parsed tags
def rowposts($ws; $rows): [ $rows[] | . as $r
  | ([ $ws[] | select(live) | select(.host == null or .host == $r.host)
       | select(((.worktreeId // "") != "" and .worktreeId == $r.worktreeId)
                or ((.path // "") != "" and (.path | npath) == ($r.path | npath))) ] | sort_by(.id) | first) as $w
  | {r: $r, w: $w, tags: [ ($r.comment // "") | tags ]} ];
def sameRepo($posts; $k): . as $w | ([ $posts[] | select(.w != null and .w.id == $w.id) | (.r.repo // null) ] | first) as $wr
  | ($wr == null or ($k.repo // null) == null or $wr == $k.repo);
def childid($ws; $posts; $k): ([ $ws[] | select(live) | select(.host == null or .host == $k.host)
  | select(.id == $k.name or (.path | base) == $k.name) | select(sameRepo($posts; $k)) ] | sort_by(.id) | first | .id?) // null;
# The ledger worker a cm:child name means: by ledger id or folder name, else through the census row that carries the
# name (a display name). One resolver for claims, unmatched children and declared epics, so an alias is never
# understood by one check and dropped by another.
def childref($ws; $posts; $k): (childid($ws; $posts; $k)
  // ([ $posts[] | select(.w != null and .r.host == $k.host and ((.r.repo // null) == ($k.repo // null)) and ((.r.displayName // "") == $k.name or (.r.path | base) == $k.name)) ]
      | if length == 1 then .[0].w.id else null end));
# cm:child claims as {child, parent}; claims on one child by different parents are conflicts
def chost($ph): (.h // $ph) | if . == "this machine" then "local" else . end;
def claims($ws; $posts): [ $posts[] | .w as $w | .r.host as $h | (.r.repo // null) as $pr | .tags[] | select(.t == "child")
  | {child: childref($ws; $posts; {host: chost($h), name: .n, repo: $pr}), parent: $w.id, name: .n} | select(.child != null and .child != .parent) ];
def nochild($ws; $posts): [ $posts[] | .w as $w | .r.host as $h | (.r.repo // null) as $pr | .tags[] | select(.t == "child")
  | select(childref($ws; $posts; {host: chost($h), name: .n, repo: $pr}) == null) | {poster: $w.id, name: .n} ];
def setparent($c; $p): if $c == null or $c == $p then .
  elif (.workers[$c].parent // null) != null then .
  elif (ups(.workers; $p) | index($c)) != null then .
  else .workers[$c].parent = $p end;
# the state a child comment reports on its first line (a segment, as everywhere); no cm: tag yet is spawning
def tagstate: ((tagsegs | first) // "") as $l
  | if ($l | startswith("cm:") | not) then "spawning"
    else (([ $l | capture("^cm:(?<t>[a-z-]+)") | .t ] | first) // "") as $t
      | ({"blocked": "blocked-on-owner", "waiting-owner": "blocked-on-owner", "done": "done", "retire": "retired",
          "failed": "stuck", "keep": "parked", "running": "running", "idle": "idle", "spawning": "spawning",
          "stuck": "stuck", "parked": "parked", "queued": "queued"}[$t] // "running") end;
# Child adoption. A cm:child <name> posted by a live ledger worker, naming a discovered worktree on the same
# host AND in the same repository as the poster (discover lists every repo of the org, so a stale line must not
# claim a worktree of another project) that no live ledger worker covers, is adopted: standing false, state from the child own comment. Never
# overwrites: a ledger key already taken (any state) is skipped and reported, never replaced.
def laneish($n): ($n | ascii_downcase) as $l | (lanenames | index($l)) != null or ($l | test(laneshape));
def adoptclaimsraw($rows): . as $L
  | [ ($L.workers // {}) | to_entries[] | select(.value | type == "object") | .value + {id: .key} ] as $ws
  | rowposts($ws; $rows) as $rp
  | [ $rp[] | select(.w != null) | .w as $w | .r.host as $h | (.r.repo // null) as $pr | .tags[] | select(.t == "child")
      | . as $c | select(($c.n | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")) and $c.n != $w.id)
      | ($c | chost($h)) as $th
      | select(childid($ws; $rp; {host: $th, name: $c.n, repo: $pr}) == null)
      | ([ $rp[] | select(.w == null and .r.host == $th and ((.r.repo // null) == $pr) and ((.r.displayName // "") == $c.n or (.r.path | base) == $c.n)) ]) as $m
      | select(($m | length) >= 1)
      | {name: $c.n, epic: $c.e, epics: $c.es, poster: $w.id, lane: ($w.lane // $w.id), n: ($m | length), row: $m[0].r,
         laneish: ([ $c.n, ($m[0].r.displayName // ""), ($m[0].r.path | base) ] | map(select(. != "")) | any(laneish(.)))} ];
# A standing lane is never adopted as a single-task child (it would be written standing:false): such a claim is
# skipped and reported (adopt-skipped, lane-shaped). Two unledgered worktrees with one name are ambiguous: neither
# is adopted and the name is reported (adopt-ambiguous).
def adoptclaims($rows): adoptclaimsraw($rows) | map(select(.n == 1 and (.laneish | not)));
def adoptlane($rows): adoptclaimsraw($rows) | map(select(.laneish) | .name) | unique;
def adoptambig($rows): adoptclaimsraw($rows) | map(select(.n > 1 and (.laneish | not)) | .name) | unique;
# One child claimed more than once keeps every epic= restriction: a single declared epic wins over claims
# that name none (the strictest reading). Two different epic= ids are a conflict: no claim can be dropped
# silently, so such a child is not adopted (reported as adopt-conflict). Poster conflicts stay parent-conflict.
def epicsof: [ .[] | ((.epics // []) + [.epic | select(. != null)])[] ] | unique;
# The claims are grouped by the worktree they resolve to (host + path), not by the name used: a worktree named by
# both its display name and its folder is ONE child, keyed by its folder name when claimed, else the first name.
def claimkey: .row.host + "\u0001" + .row.path;
def adoptgroups($rows): adoptclaims($rows) | group_by(claimkey)
  | map((map(.name) | unique) as $n | (.[0].row.path | base) as $b
        | {name: (if ($n | index($b)) != null then $b else $n[0] end), epics: epicsof, g: .});
def adoptconflict($rows): adoptgroups($rows) | map(select((.epics | length) > 1) | .name);
# Every epic= declared on a cm:child line, per ledger child (host-resolved like claims): {id, epics}.
def declaredepics($rows): . as $L
  | [ ($L.workers // {}) | to_entries[] | select(.value | type == "object") | .value + {id: .key} ] as $ws
  | rowposts($ws; $rows) as $rp
  | [ $rp[] | select(.w != null) | .w.id as $p | .r.host as $h | (.r.repo // null) as $pr | .tags[] | select(.t == "child" and ((.es // []) | length) > 0)
      | . as $c | (chost($h)) as $th
      | childref($ws; $rp; {host: $th, name: $c.n, repo: $pr}) as $id
      | $c.es[] as $ep | {id: $id, epic: $ep, by: $p} | select(.id != null) ]
  | group_by(.id) | map({id: .[0].id, epics: (map(.epic) | unique), by: (map(.by) | unique)});
# One name for two different worktrees is ambiguous: neither is adopted.
def adoptable($rows): adoptgroups($rows) | map(select((.epics | length) <= 1))
  | group_by(.name) | map(select(length == 1) | .[0] | . as $x | $x.g[0] + {name: $x.name, epic: ($x.epics | first)});
'
# the shared lane predicate (lib.sh) reaches jq as data, never as a second copy of the rule
DEFS="def lanenames: $(cm_lane_names | jq -R . | jq -sc .); def laneshape: $(jq -n --arg r "$CM_LANE_SHAPE_RE" '$r'); $DEFS"

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
      | . as $L0
      | reduce (adoptable($disc[0].worktrees // [])[] | select(($L0.workers // {})[.name] == null)) as $a (.;
          .workers[$a.name] = {host: $a.row.host, path: $a.row.path, worktreeId: ($a.row.worktreeId // null),
            state: ($a.row.comment | tagstate), standing: false, adopted: true, lane: $a.lane, parent: null,
            beadsEpic: ($a.epic // null), lastComment: ((($a.row.comment | tagsegs | first) // "") | clean | .[0:200])})
      | . as $L
      | [ ($L.workers // {}) | to_entries[] | select(.value | type == "object") | .value + {id: .key} ] as $ws
      | rowposts($ws; $disc[0].worktrees // []) as $rp
      | ($rp | map(select(.w != null))) as $posts
      # an adopted child whose lead adds epic=<id> to its cm:child line later still gets that restriction: filled
      # in only while beadsEpic is empty, never replacing a set value. Different ids (declared ones and a set
      # beadsEpic together) are a conflict: epicConflict records them all, whether or not beadsEpic is set, with
      # the claimants (epicConflictBy), and teardown treats it as unknown beads state. A conflict is only ever
      # resolved when EVERY recorded claimant is read again and the ids agree: an unreadable host, a cut-off
      # census, or a claimant that dropped its epic= token leaves it standing.
      | declaredepics($disc[0].worktrees // []) as $eg
      | reduce $eg[] as $f (.;
          if (.workers[$f.id].adopted == true) then
            (($f.epics + [ .workers[$f.id].beadsEpic | select(type == "string" and . != "") ]) | unique) as $all
            | (((.workers[$f.id].epicConflictBy // []) - $f.by) | length) as $missing
            | (((.workers[$f.id].epicConflict // []) | length) > 0) as $had
            | if ($all | length) > 1 then
                (.workers[$f.id].epicConflict = (($all + (.workers[$f.id].epicConflict // [])) | unique)
                 | .workers[$f.id].epicConflictBy = (((.workers[$f.id].epicConflictBy // []) + $f.by) | unique))
              elif $had and $missing > 0 then .
              elif ((.workers[$f.id].beadsEpic // null) == null) then .workers[$f.id].beadsEpic = $all[0] | del(.workers[$f.id].epicConflict, .workers[$f.id].epicConflictBy)
              else del(.workers[$f.id].epicConflict, .workers[$f.id].epicConflictBy) end
          else . end)
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
            else .followUps[$i] |= ((if .text != $c.text then del(.issue, .issueUrl, .escalatedAt) else . end) + {worker: $c.worker, owner: $c.owner, text: $c.text}) end)   # new text is a new task: an issue made for the old one does not cover it. An escalate claim (escalatingAt) stays: a run that holds it records the issue it made against that claim, and with the claim gone the issue would go unrecorded
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
    # A child adopted in this pass can itself declare children (a grandchild with its own follow-ups), and those
    # are only visible once the child is a ledger worker: repeat until a pass changes nothing (depth bounded).
    PRINTED=""
    for _pass in 1 2 3 4 5; do
      _before="$(cksum < "$LEDGER" 2>/dev/null || true)"
      # children to adopt, worked out on the ledger as it is now (after the write they are ordinary workers).
      # These lines are report text only, computed outside the ledger lock: the write below re-runs the filter
      # under the lock, so a stale line can mislead the report but never the ledger.
      # shellcheck disable=SC2016
      ADOPT="$(jq -r --slurpfile disc "$TMPD" "$DEFS"'
        . as $L | (adoptable($disc[0].worktrees // [])[]
        | if ($L.workers // {})[.name] == null
          then "followups: adopted \(.name) (child of \(.poster), standing false, state \(.row.comment | tagstate))"
          else "followups: adopt-skipped \(.name) (ledger id already taken: nothing overwritten)" end),
        (adoptlane($disc[0].worktrees // [])[] | "followups: adopt-skipped \(.) (lane-shaped name: a standing lane is never adopted as a child)"),
        (adoptambig($disc[0].worktrees // [])[] | "followups: adopt-ambiguous \(.) (more than one worktree carries this name: none adopted, make the cm:child line unambiguous)"),
        (adoptconflict($disc[0].worktrees // [])[] | "followups: adopt-conflict \(.) (claims name different epic= ids: not adopted, resolve the cm:child lines)"),
        (declaredepics($disc[0].worktrees // [])[] | select((.epics | length) > 1) | . as $e
          | select($L.workers[$e.id].adopted == true)
          | select((($e.epics + [ $L.workers[$e.id].beadsEpic | select(type == "string" and . != "") ]) | unique | length) > 1)
          | "followups: epic-conflict \($e.id) (cm:child lines and the ledger name different epics, \($e.epics | join(", ")): teardown blocked until they agree)")' "$LEDGER")" || ADOPT=""
      apply "($FILTER) as \$new | if \$new == . then . else \$new | .updatedAt = \$now end" --arg now "$NOW" --arg oid "$OWNER_ID" --slurpfile disc "$TMPD" || exit 1
      while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        case $'\n'"$PRINTED" in *$'\n'"$_l"$'\n'*) ;; *) printf '%s\n' "$_l"; PRINTED="$PRINTED$_l"$'\n' ;; esac
      done <<< "$ADOPT"
      [ "$(cksum < "$LEDGER" 2>/dev/null || true)" != "$_before" ] || break
    done
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

  for-worktree)
    need_ledger
    [ $# -ge 1 ] && [ -n "$1" ] || { cm_warn "followups.sh: for-worktree needs a worktree name or path"; exit 2; }
    jq -e '(.followUps // []) | type == "array"' "$LEDGER" >/dev/null 2>&1 || { cm_warn "followups.sh: ledger followUps is not an array"; exit 1; }
    # exit 3 means "nothing is known about this worktree": only true of a sound ledger, never of a broken one
    jq -e 'type == "object" and ((.workers | type) == "object")' "$LEDGER" >/dev/null 2>&1 || { cm_warn "followups.sh: ledger has no workers object"; exit 1; }
    OWN="$(jq -r --arg t "$1" "$DEFS"'
      (.workers // {}) as $W
      | [ $W | to_entries[] | select(.value | type == "object")
          | select(((.value.path | npath) == ($t | npath) and ($t | npath) != "") or (.value.path | base) == $t or .key == $t) | .key ] | length' "$LEDGER")"
    [ "$OWN" -gt 0 ] || exit 3
    jq -r --arg t "$1" "$DEFS"'
      (.workers // {}) as $W
      | [ $W | to_entries[] | select(.value | type == "object")
          | select(((.value.path | npath) == ($t | npath) and ($t | npath) != "") or (.value.path | base) == $t or .key == $t) | .key ] as $own
      | [ $W | keys[] | . as $k | select(ups($W; $k) | any(. as $a | $own | index($a) != null)) ] as $fam
      | (.followUps // [])[] | select(.state != "done" and ((.issue // .issueUrl) == null) and (.worker as $w | $fam | index($w) != null))
      | [.id, .worker, .lane, .owner, .openedAt, .text] | map(. // "" | clean) | @tsv' "$LEDGER"
    ;;

  escalate)
    need_ledger
    CREATE=0; MAXN=5; RESOLVE=""; RESNUM=""; ONLY=""; ALLC=0; SHOWMAX=5
    AFTER="$(cm_cfg .followups.escalate_after_hours 24)"
    while [ $# -gt 0 ]; do
      case "$1" in
        --create) CREATE=1; shift ;;
        --after-hours) [ $# -ge 2 ] || { cm_warn "followups.sh: --after-hours needs a number"; exit 2; }; AFTER="$2"; shift 2 ;;
        --resolve) [ $# -ge 3 ] || { cm_warn "followups.sh: --resolve needs <lane>/<id> and <issue-number|release>"; exit 2; }; RESOLVE="$2"; RESNUM="$3"; shift 3 ;;
        --only) [ $# -ge 2 ] || { cm_warn "followups.sh: --only needs <lane/id@fingerprint>[,...] as the dry run prints it"; exit 2; }; ONLY="${2//[[:space:]]/}"; shift 2 ;;
        --all-candidates) ALLC=1; shift ;;
        --show) [ $# -ge 2 ] || { cm_warn "followups.sh: --show needs a whole number"; exit 2; }; SHOWMAX="$2"; shift 2 ;;
        --max) [ $# -ge 2 ] || { cm_warn "followups.sh: --max needs a whole number"; exit 2; }; MAXN="$2"; shift 2 ;;
        *) cm_warn "followups.sh: unknown arg: $1"; exit 2 ;;
      esac
    done
    # every --only entry is lane/id@fingerprint, the form the dry run prints: the approval is bound to the owner and text the
    # owner read, so a follow-up changed since (reconcile may rewrite it) needs a new dry run and a new approval
    if [ -n "$ONLY" ]; then
      IFS=, read -ra WANT <<<"$ONLY"
      for w in "${WANT[@]}"; do
        case "$w" in */*@?*) ;; *) cm_warn "followups.sh: --only entry \"$w\" is not lane/id@fingerprint (copy the line the dry run prints)"; exit 2 ;; esac
      done
    fi
    case "$SHOWMAX" in ''|*[!0-9]*) cm_warn "followups.sh: --show needs a whole number"; exit 2 ;; esac
    # --create works from the list the owner approved, never from a list worked out again at create time
    # (items cross 24 h and new cross-lane posts land between the dry run and the create)
    if [ -z "$RESOLVE" ] && [ "$CREATE" = 1 ] && [ -z "$ONLY" ] && [ "$ALLC" = 0 ]; then
      cm_warn "followups.sh: --create needs --only <lane/id>[,...] (the ids the owner approved from the dry run); --all-candidates creates every candidate and is for the owner only"
      exit 2
    fi
    if [ -n "$RESOLVE" ]; then
      # clear a claim left by a run that timed out or could not release it: record the issue number a person
      # found on GitHub, or release the claim so the next run may try again
      case "$RESOLVE" in */*) ;; *) cm_warn "followups.sh: --resolve needs <lane>/<id>"; exit 2 ;; esac
      case "$RESNUM" in release) ;; ''|*[!0-9]*) cm_warn "followups.sh: --resolve needs an issue number or release"; exit 2 ;; esac
      # a number becomes the issue url, which needs the repository; release does not
      if [ "$RESNUM" != release ] && { [ -z "$CM_ORG" ] || [ -z "$CM_REPO" ]; }; then
        cm_warn "followups.sh: github.org / github.main_repo are not configured: cannot build the issue url for $RESNUM"; exit 1
      fi
      # the claim is found by its whole "lane/id" name, so a "/" in either part cannot move the split
      # shellcheck disable=SC2016
      rtok="$(jq -r --arg r "$RESOLVE" '[(.followUps // [])[] | select(((.lane | tostring) + "/" + (.id | tostring)) == $r and .escalatingAt != null)] | if length == 1 then .[0].escalatingAt | tostring else "" end' "$LEDGER" 2>/dev/null)"
      [ -n "$rtok" ] || { cm_warn "followups.sh: $RESOLVE has no open claim to resolve"; exit 1; }
      # a claim is TOKEN = <time>-<pid> of the run that made it. Releasing it while that run is still asking GitHub lets the next
      # run ask again and make a second issue, so release waits for the run to end (a number is safe: the run then fails to record)
      # A live pid on an OLD claim is a reused pid, not that run (a --create run lasts minutes): over an hour old, release goes ahead.
      rpid="${rtok##*-}"; rts="${rtok%-*}"
      rage="$(jq -nr --arg t "$rts" --argjson n "$(date -u +%s)" '(try ($t | fromdateiso8601) catch null) as $e | if $e == null then 0 else ($n - $e) end' 2>/dev/null || echo 0)"
      case "$rage" in ''|*[!0-9-]*) rage=0 ;; esac
      if [ "$RESNUM" = release ] && [ "$rage" -lt 3600 ] && [ -n "$rpid" ] && [ -z "${rpid//[0-9]/}" ] && kill -0 "$rpid" 2>/dev/null; then
        cm_warn "followups.sh: the claim on $RESOLVE belongs to a --create run that is still alive (pid $rpid): wait for it to end, then release"; exit 1
      fi
      # shellcheck disable=SC2016
      apply '
        (.followUps | map(((.lane | tostring) + "/" + (.id | tostring)) == $r and .escalatingAt != null) | index(true)) as $i
        | if $i == null then .
          elif $n == "release" then (.followUps[$i] |= del(.escalatingAt) | .updatedAt = $now)
          else (.followUps[$i] |= ((. + {issue: ($n | tonumber), issueUrl: ("https://github.com/" + $org + "/" + $repo + "/issues/" + $n), escalatedAt: $now}) | del(.escalatingAt)) | .updatedAt = $now) end' \
        --arg r "$RESOLVE" --arg n "$RESNUM" --arg org "$CM_ORG" --arg repo "$CM_REPO" --arg now "$NOW" || exit 1
      echo "followups: $RESOLVE: claim resolved ($RESNUM)"
      exit 0
    fi
    printf '%s' "$AFTER" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || { cm_warn "followups.sh: --after-hours needs a number"; exit 2; }
    printf '%s' "$MAXN" | grep -Eq '^[0-9]+$' || { cm_warn "followups.sh: --max needs a whole number"; exit 2; }
    [ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] || { cm_warn "followups.sh: github.org / github.main_repo are not configured"; exit 1; }
    jq -e '(.followUps // []) | type == "array"' "$LEDGER" >/dev/null 2>&1 || { cm_warn "followups.sh: ledger followUps is not an array"; exit 1; }
    GH_T="${CM_FOLLOWUPS_GH_TIMEOUT:-30}"; FLOOR="${CM_FOLLOWUPS_FLOOR_S:-180}"; STAMP="$CM_HOME/.followups-escalate.stamp"
    TOK="$NOW-$$"
    # A claim (escalatingAt) with no issue is an earlier run that died, or timed out, between asking GitHub and
    # recording the answer: the issue may exist. Say so every run; never create a second one for it.
    jq -r --arg tok "$TOK" '(.followUps // [])[] | select(type == "object" and .state != "done" and .issue == null and .issueUrl == null
        and .escalatingAt != null and .escalatingAt != $tok)
      | "followups: escalate verify by hand \(.lane | tostring | gsub("[[:cntrl:]]+"; " "))/\(.id | tostring | gsub("[[:cntrl:]]+"; " ")): a claim from \(.escalatingAt | tostring | gsub("[[:cntrl:]]+"; " ")) has no issue number, look for an existing GitHub issue before creating one"' "$LEDGER"
    # shellcheck disable=SC2016
    CANDS="$(jq -c --argjson after "$AFTER" --argjson nowe "$(date -u +%s)" --arg oid "$OWNER_ID" "$DEFS"'
      # an ISO time with Z or any +hh:mm / -hhmm offset; a naive time (no zone) stays null
      def ts: try (sub("\\.[0-9]+"; "") as $x
        | if ($x | test("[+-][0-9]{2}:?[0-9]{2}$"))
          then ($x | capture("^(?<b>.*?)(?<sg>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")) as $c
            | (($c.b + "Z") | fromdateiso8601) - (if $c.sg == "+" then 1 else -1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60)
          else ($x | fromdateiso8601) end) catch null;
      def lc: ascii_downcase;
      (.lanes // {}) as $lanes | (.workers // {}) as $W
      | def ownerlane($o): if ($o | lc) == $oid then null   # the project owner is not a lane
          else ([ $lanes | keys[] | select(lc == ($o | lc)) ] | first) as $l
            | if $l != null then $l
              else ([ $W | to_entries[] | select((.key | lc) == ($o | lc)) | (.value.lane // .key) ] | first // null) end end;
      (.followUps // [])[]
      | select(type == "object" and .state != "done" and ((.issue // .issueUrl // .escalatingAt) == null)
               and (.id | type) == "string" and (.lane | type) == "string")
      | . as $f
      | ((.openedAt // null) | if type == "string" then ts else null end) as $t
      | (if $t == null then null else (($nowe - $t) / 3600) end) as $age
      | ownerlane(($f.owner // "") | tostring) as $ol
      | ($age != null and $age >= $after) as $old
      | ($ol != null and ($ol | tostring | lc) != ($f.lane | lc)) as $cross
      | select($old or $cross)
      | {idRaw: $f.id, laneRaw: $f.lane, ownerRaw: ($f.owner // ""), textRaw: ($f.text // ""),
         id: ($f.id | clean), lane: ($f.lane | clean), owner: (($f.owner // "") | clean),
         text: (($f.text // "") | clean), openedAt: (($f.openedAt // "") | clean),
         ageH: (if $age == null then null else ($age | floor) end),
         worktree: ((($W[(($f.worker // "") | tostring)].path // "") | tostring) | base | clean),
         reason: ([ (if $old then "open over \($after)h" else empty end),
                    (if $cross then "owner lane \($ol) differs from the posting lane \($f.lane)" else empty end) ] | join("; ") | clean)}' "$LEDGER")" \
      || { cm_warn "followups.sh: cannot read the ledger"; exit 1; }
    [ -n "$CANDS" ] || { echo "followups: escalate: nothing old or cross-lane without an issue"; exit 0; }
    BODYF=""; ERRF=""; LOCKD="$CM_HOME/.followups-escalate.lock"; HAVELOCK=0; HAVETAKE=0; TAKEN="$LOCKD.takeover"
    esc_cleanup() {
      [ -z "$BODYF" ] || rm -f -- "$BODYF"
      [ -z "$ERRF" ] || rm -f -- "$ERRF"
      if [ "$HAVETAKE" = 1 ]; then rmdir "$TAKEN" 2>/dev/null || true; fi
      # only the run whose pid is in the lock removes it
      if [ "$HAVELOCK" = 1 ] && [ "$(cat "$LOCKD/pid" 2>/dev/null || true)" = "$$" ]; then rm -f -- "$LOCKD/pid"; rmdir "$LOCKD" 2>/dev/null || true; fi
    }
    trap esc_cleanup EXIT
    if [ "$CREATE" = 1 ]; then
      # one --create run at a time: the floor check, the stamp and the per-run cap all live inside this lock, so two
      # runs started together cannot both pass the floor or both spend a cap
      mkdir -p "$CM_HOME"
      if ! mkdir "$LOCKD" 2>/dev/null; then
        opid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
        if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && [ -z "$(find "$LOCKD" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then echo "followups: escalate skipped, another --create run is in progress (pid $opid)"; exit 0; fi
        # no pid yet: its owner is between mkdir and writing it. Give it a minute before calling the lock stale.
        if [ -z "$opid" ] && [ -z "$(find "$LOCKD" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then echo "followups: escalate skipped, another --create run is starting"; exit 0; fi
        # its owner is gone, or a live pid holds a lock older than an hour (a dead holder's pid that another process took over: a
        # --create run lasts minutes). Taking the lock over is itself done under a second lock, and what is there is looked at
        # again inside it: a run that saw the dead holder a moment ago must not remove the fresh lock another run made since.
        # a takeover lock left by a run that died inside it clears after ten minutes (the takeover itself takes milliseconds, so
        # only a holder paused that long loses it; two holders are then still kept from a double create by the per-item claims).
        # Known and narrow: a live run that really lasts over an hour is taken over too, for the same reason.
        if [ -d "$TAKEN" ] && [ -n "$(find "$TAKEN" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$TAKEN" 2>/dev/null || true; fi
        if ! mkdir "$TAKEN" 2>/dev/null; then echo "followups: escalate skipped, another --create run is taking over the stale lock"; exit 0; fi
        HAVETAKE=1
        cpid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
        if [ ! -d "$LOCKD" ]; then :   # gone already: just take it below
        elif [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null && [ -z "$(find "$LOCKD" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
          echo "followups: escalate skipped, another --create run is in progress (pid $cpid)"; exit 0
        elif [ -z "$cpid" ] && [ -z "$(find "$LOCKD" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
          echo "followups: escalate skipped, another --create run is starting"; exit 0
        else
          rm -f -- "$LOCKD/pid"; rmdir "$LOCKD" 2>/dev/null || true
        fi
        mkdir "$LOCKD" 2>/dev/null || { echo "followups: escalate skipped, another --create run is in progress"; exit 0; }
        rmdir "$TAKEN" 2>/dev/null || true; HAVETAKE=0
      fi
      HAVELOCK=1; printf '%s\n' "$$" > "$LOCKD/pid"
      if [ -e "$STAMP" ]; then
        LASTRUN="$(stat -c %Y "$STAMP" 2>/dev/null || stat -f %m "$STAMP" 2>/dev/null || echo 0)"
        if [ $(( $(date +%s) - LASTRUN )) -lt "$FLOOR" ]; then echo "followups: escalate skipped, the last --create run was under ${FLOOR}s ago (poll floor)"; exit 0; fi
      fi
      REM="$(cm_timeout "$GH_T" gh api rate_limit --jq '[.resources.core.remaining, .resources.graphql.remaining] | min' 2>/dev/null </dev/null || true)"
      case "$REM" in ''|*[!0-9]*) echo "followups: escalate skipped, the GitHub budget could not be read"; exit 0 ;; esac
      [ "$REM" -ge 800 ] || { echo "followups: escalate skipped, GitHub budget low ($REM calls left in the smaller of the core and GraphQL allowances, back off under 800)"; exit 0; }
      mkdir -p "$CM_HOME" && : > "$STAMP"
    fi
    # labels, one per element (a label may hold spaces)
    LARGS=(); LNAMES=()
    while IFS= read -r lb; do [ -n "$lb" ] && { LARGS+=(--label "$lb"); LNAMES+=("$lb"); }; done < <(cm_cfg_json .followups.issue_labels '[]' | jq -r 'if type == "array" then .[] | strings else empty end' 2>/dev/null)
    BODYF="$(mktemp "${TMPDIR:-/tmp}/cm-followups-body.XXXXXX")" || exit 1
    ERRF="$(mktemp "${TMPDIR:-/tmp}/cm-followups-err.XXXXXX")" || exit 1
    cnt=0; failed=0; shown=0; APPROVE=(); ONLYSEEN=()
    # drop zero-width and bidi control characters from text that goes out
    nz() { printf '%s' "$1" | jq -Rrs 'gsub("[\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]"; "")'; }
    # give back our claim when GitHub made nothing
    release_claim() {
      # shellcheck disable=SC2016
      apply '(.followUps | map(.lane == $lane and .id == $id and .state != "done" and .escalatingAt == $tok) | index(true)) as $i
        | if $i == null then . else .followUps[$i] |= del(.escalatingAt) end | .updatedAt = $now' \
        --arg lane "$rlane" --arg id "$rid" --arg tok "$TOK" --arg now "$NOW" || true
    }
    # write the issue number against our claim, even if the item was closed while gh ran
    record_issue() {
      # shellcheck disable=SC2016
      apply '
        (.followUps | map(.lane == $lane and .id == $id and .escalatingAt == $tok) | index(true)) as $i
        | if $i == null then error("follow-up not found")
          else .followUps[$i] |= ((. + {issue: ($n | tonumber), issueUrl: $url, escalatedAt: $now}) | del(.escalatingAt)) end
        | .updatedAt = $now' --arg lane "$rlane" --arg id "$rid" --arg n "$inum" --arg url "$url" --arg now "$NOW" --arg tok "$TOK" \
        || { cm_warn "followups.sh: issue $url belongs to $flane/$fid but the ledger write failed: record it by hand (the claim stays, so it is not made twice)"; return 1; }
    }
    while IFS= read -r row <&3; do
      [ -n "$row" ] || continue
      fid="$(jq -r .id <<<"$row")"; flane="$(jq -r .lane <<<"$row")"; ftext="$(jq -r .text <<<"$row")"
      fowner="$(jq -r .owner <<<"$row")"; fwt="$(jq -r .worktree <<<"$row")"; fage="$(jq -r '.ageH // "?"' <<<"$row")"
      fopened="$(jq -r .openedAt <<<"$row")"; freason="$(jq -r .reason <<<"$row")"
      rid="$(jq -r .idRaw <<<"$row")"; rlane="$(jq -r .laneRaw <<<"$row")"
      rowner="$(jq -c .ownerRaw <<<"$row")"; rtext="$(jq -c .textRaw <<<"$row")"   # what the candidate was built from
      # a short fingerprint of the owner and text as read now; the dry run prints it, --only must carry it
      fp="$(printf '%s\n%s' "$rowner" "$rtext" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-10)"
      if [ -n "$ONLY" ]; then
        case ",$ONLY," in
          *",$flane/$fid@$fp,"*) ONLYSEEN+=("$flane/$fid") ;;
          *",$flane/$fid@"*) echo "followups: escalate $flane/$fid changed since the dry run (owner or text differs): run the dry run again and approve it again"; ONLYSEEN+=("$flane/$fid"); continue ;;
          *) continue ;;
        esac
      fi
      # the issue is visible to the whole repo: nothing from a brief, a token or a private path goes in it.
      # A heuristic, not a scanner (cm_text_looks_secret, lib.sh): it refuses the common key shapes and private paths.
      # checked as read AND with the invisible characters taken out, because that is the text that goes out (the title and
      # body drop zero-width and bidi characters, which could otherwise join the pieces of a key)
      chk="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' "$fid" "$flane" "$ftext" "$fowner" "$fwt" "$fopened" "$freason")"
      if cm_text_looks_secret <<<"$chk" || cm_text_looks_secret <<<"$(nz "$chk")"; then
        echo "followups: escalate refused $flane/$fid: the text looks like it holds a credential, a brief or a private path (edit the follow-up, then rerun)"
        failed=1; continue
      fi
      # the title is outside any code block: no @mention, no #n link, no bidi or zero-width control from the text
      ttl="$(printf '%s' "$ftext" | jq -Rrs 'gsub("[\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]"; "") | gsub("@"; "(at)") | gsub("#"; "(no.)") | .[0:80]')"
      title="follow-up $fid: $ttl"
      {
        # shellcheck disable=SC2016  # backticks are markdown in the issue body
        printf 'Follow-up `%s` raised by lane `%s`.\n\n' "$fid" "$flane"
        # the text, owner and worktree name go in an indented code block, so an @name or #n in them notifies nobody
        { nz "$ftext"; printf '\n'
          printf 'owner: %s\nsource worktree: %s\nopen since: %s (%sh)\nwhy an issue: %s\n' "$(nz "$fowner")" "$(nz "${fwt:-unknown}")" "$(nz "$fopened")" "$fage" "$(nz "$freason")"; } | sed 's/^/    /'
        printf '\n'
        # shellcheck disable=SC2016
        printf 'Raised from the concertmaster follow-up ledger. Closing this issue does not close the ledger item: close it with `scripts/followups.sh close %s --lane %s`, or post `cm:followup-done %s` in the worktree comment that raised it.\n' "$fid" "$flane" "$fid"
      } > "$BODYF"
      if [ "$CREATE" = 0 ]; then
        APPROVE+=("$flane/$fid@$fp")
        echo "would create: [$flane/$fid] $title ($freason; owner $fowner; labels: ${LNAMES[*]:-none})"
        if [ "$shown" -lt "$SHOWMAX" ]; then sed 's/^/    | /' "$BODYF"; shown=$((shown + 1))
        else echo "    | (body not shown: the dry run prints $SHOWMAX bodies, raise it with --show <n>)"; fi
        continue
      fi
      if [ "$cnt" -ge "$MAXN" ]; then echo "followups: escalate limit reached ($MAXN issues this run); the rest next run"; break; fi
      # 1. CLAIM the item in the ledger (under its lock) BEFORE asking GitHub; only the run whose token is on it goes on
      # shellcheck disable=SC2016
      apply '
        (.followUps | map(.lane == $lane and .id == $id and .state != "done") | index(true)) as $i
        | if $i == null then .
          elif (.followUps[$i].issue // .followUps[$i].issueUrl // .followUps[$i].escalatingAt) != null then .
          elif ((.followUps[$i].owner // "") != $owner or (.followUps[$i].text // "") != $text) then .   # reconcile changed it since the candidate was read
          else (.followUps[$i] |= (. + {escalatingAt: $tok}) | .updatedAt = $now) end' --arg lane "$rlane" --arg id "$rid" --arg tok "$TOK" --arg now "$NOW" --argjson owner "$rowner" --argjson text "$rtext" \
        || { failed=1; break; }
      if [ "$(jq -r --arg lane "$rlane" --arg id "$rid" '[.followUps[] | select(.lane == $lane and .id == $id and .state != "done")][0].escalatingAt // ""' "$LEDGER")" != "$TOK" ]; then
        echo "followups: escalate skipped $flane/$fid: another run holds it, it already has an issue, or it changed since it was read (next run)"; continue
      fi
      # 1b. an issue for this follow-up may already exist (a restored backup, an older run, a person): link it, never duplicate
      lrc=0; found="$(cm_timeout "$GH_T" gh issue list -R "$CM_ORG/$CM_REPO" --state all --search "in:title follow-up $rid" --json number,title,url,body --limit 100 2>"$ERRF" </dev/null)" || lrc=$?
      if [ "$lrc" != 0 ] || ! jq -e 'type == "array"' <<<"$found" >/dev/null 2>&1; then
        release_claim
        cm_warn "followups.sh: could not look for an existing issue for $flane/$fid (exit $lrc): nothing created, left unmarked, stopping this run"
        failed=1; break
      fi
      if [ "$(jq 'length' <<<"$found")" -ge 100 ]; then
        # the claim stays: --resolve needs it to record a number you found, or to give it up
        cm_warn "followups.sh: the search for $flane/$fid hit its 100-result limit, so a miss proves nothing: nothing created, the claim stays; look on GitHub, then: followups.sh escalate --resolve $flane/$fid <number|release>"
        failed=1; break
      fi
      hit="$(jq -r --arg id "$rid" --arg lane "$rlane" '[.[] | select((.title // "" | startswith("follow-up " + $id + ":")) and ((.body // "") | contains("raised by lane `" + $lane + "`")))][0] | if . then "\(.number) \(.url)" else empty end' <<<"$found" 2>/dev/null || true)"
      if [ -n "$hit" ]; then
        inum="${hit%% *}"; url="${hit#* }"
        record_issue || { failed=1; break; }
        echo "linked: [$flane/$fid] $url (an issue for it already existed, none created)"
        continue
      fi
      # 2. ask GitHub
      grc=0; url="$(cm_timeout "$GH_T" gh issue create -R "$CM_ORG/$CM_REPO" --title "$title" --body-file "$BODYF" ${LARGS[@]+"${LARGS[@]}"} 2>"$ERRF" </dev/null)" || grc=$?
      if [ "$grc" != 0 ]; then
        why="$(head -n 1 "$ERRF" | tr -c '[:print:]' '?' | cut -c1-120)"
        # GitHub definitely refused: an HTTP 4xx answer (not 408), a validation error, no auth, an unknown repo or label
        refused=0
        grep -qiE 'HTTP (40[0-79]|4[1-9][0-9])|validation failed|could not add label|gh auth login|authentication required|could not resolve to a (repository|user)|label .* not found' "$ERRF" 2>/dev/null && refused=1
        if [ "$grc" = 126 ] || [ "$grc" = 127 ]; then
          # 126 not executable, 127 not found: gh never ran, so it made nothing and the claim goes back
          release_claim
          cm_warn "followups.sh: gh could not be run for $flane/$fid (exit $grc, ${why:-no message}): nothing created, left unmarked, stopping this run"
        elif [ "$grc" -ge 124 ] || [ "$refused" = 0 ]; then
          # 124 timeout, 137 killed, 142 perl alarm, or exit 1 with no refusal: a dropped connection can follow a
          # created issue, so GitHub may have made it
          cm_warn "followups.sh: gh did not confirm for $flane/$fid (${why:-no message}): the issue may exist; the claim stays, look on GitHub, then: followups.sh escalate --resolve $flane/$fid <number|release>"
        else
          # GitHub refused: it made nothing, release the claim so the next run can try
          release_claim
          cm_warn "followups.sh: gh issue create failed for $flane/$fid (${why:-no message}): left unmarked, stopping this run"
        fi
        failed=1; break
      fi
      url="$(printf '%s' "$url" | tail -n 1 | tr -d '[:space:]')"
      inum="${url##*/}"
      case "$inum" in ''|*[!0-9]*) inum="" ;; esac
      if [ -z "$inum" ]; then
        cm_warn "followups.sh: gh answered without an issue url for $flane/$fid: the issue may exist; the claim stays, look on GitHub, then: followups.sh escalate --resolve $flane/$fid <number|release>"
        failed=1; break
      fi
      # 3. RECORD the answer against our claim (the claim stays when the url is unreadable: that run is reported as verify-by-hand)
      record_issue || { failed=1; break; }
      cnt=$((cnt + 1))
      echo "created: [$flane/$fid] $url"
    done 3<<<"$CANDS"
    if [ -n "$ONLY" ]; then
      for w in "${WANT[@]}"; do
        found=0; for sn in ${ONLYSEEN[@]+"${ONLYSEEN[@]}"}; do [ "$sn" = "${w%@*}" ] && found=1; done
        [ "$found" = 1 ] || echo "followups: escalate --only ${w%@*} is not a candidate now (closed, already escalated, claimed, or not old or cross-lane)"
      done
    fi
    if [ "$CREATE" = 0 ] && [ "${#APPROVE[@]}" -gt 0 ]; then
      APPROVEQ=""; for e in "${APPROVE[@]}"; do APPROVEQ="${APPROVEQ:+$APPROVEQ,}$(printf '%q' "$e")"; done   # each entry shell-quoted, the comma between them left as the separator
      echo "followups: to create exactly these once the owner approves: scripts/followups.sh escalate --create --only ${APPROVEQ}"
    fi
    [ "$failed" = 0 ] || exit 1
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
