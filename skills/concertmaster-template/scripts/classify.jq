# classify.jq: give every discovered worktree/session exactly one class.
# Input: the discover.sh document. Args: --argjson stuckMin <minutes>,
# --slurpfile ledger <ledger.json> (or --argjson ledger '[]' when absent).
#
# Classes, checked in this order (first match wins):
#   host-offline       host unreachable this tick (one item per host)
#   main-checkout      a repo's main checkout: never touched
#   stuck              live agent (or status working/permission/waiting) with
#                      no output for stuckMin+ minutes
#   running            live agent with recent output
#   unknown-git        git state not collected (remote host) or a git check
#                      failed or the path is gone: investigate, never teardown
#   dirty-or-unpushed  dirty tree or unpushed commits, whatever the PR state.
#                      Never delete.
#   done-merged        PR merged/closed, tree clean (teardown candidate)
#   done-selfreported  every agent reports done, PR not merged
#   orphan-git-only    git worktree Orca does not track, PR not merged
#   idle               Orca worktree, no live agent, nothing merged: adopt or ask
#
# Standing lanes (sweepers and leads) then override, from the LEDGER only
# (the owner's rule; names never decide). Ledger workers match by Orca
# worktreeId, else by path with trailing slashes stripped; gone/repurposed
# records are ignored. Standing = any matched worker standing:true or a lane
# lead. A standing item with no agent at all becomes standing-dead (below).
# Otherwise a standing item that would be done-merged, done-selfreported,
# orphan-git-only or idle, or that is "stuck" with comment cm:idle and no
# agent in state working, becomes
#   standing-dead      standing lane with no agent at all (no agent pane, no
#                      live terminal, or git-only): respawn in place with
#                      `claude --continue` in its worktree; never teardown
#   standing-idle      long-lived lane with nothing to do: hand it work; never
#                      retire, teardown or stuck-respawn. An open PR is still
#                      handed to the pr-sweeper.
# A standing item that is genuinely stuck keeps class stuck; its suggest says
# respawn in place only. No matched worker, or a standing that is not a
# boolean, flags standing-unknown: no retire or teardown until the ledger
# records it. Items whose ledger worker owns a beadsEpic get flag
# beads-epic:<id> and a done suggest that runs the beads gate first.
#
# Flag has-child-agent (child worktrees, a pane with a parent pane, or more
# than one agent pane) overrides the action to "investigate" and the item is
# never a teardown candidate.
#
# Timestamps are epoch ms; any of them may be null on remote rows.

def live_states: ["working", "waiting", "permission", "blocked", "running"];

# Epoch-ms values before 2020 are placeholders (Orca reports 0 or tiny values
# on never-opened main checkouts); treat them as unknown.
def max_or_null: map(select(. != null and . > 1577836800000)) | if length == 0 then null else max end;

def normpath: if type == "string" then sub("/+$"; "") else "" end;

($stuckMin // 45) as $stuck
| (($ledger // [])[0] // {}) as $L
| [ ($L.lanes // {})[]? | .lead? // empty | select(type == "string") ] as $leads
| .generatedAtMs as $now
| (.hosts // []) as $hosts
| [
    ( $hosts[] | select(.reachable | not)
      | {host: .name, class: "host-offline", path: null, repo: null, branch: null,
         worktreeId: null, inOrca: null, idleMinutes: null, pr: null,
         flags: [], reason: ("unreachable: " + (.error // "unknown")),
         suggest: "retry next tick; assume nothing dead; no teardown"} ),

    ( (.worktrees // [])[]
      | . as $w
      | ([$w.agents[]? | select(.state as $s | live_states | index($s))]) as $live
      | (($w.agents | length) > 0 and ([$w.agents[]? | select(.state != "done")] | length) == 0) as $allDone
      | ([$w.lastOutputAt, ([$w.agents[]?.updatedAt] | max_or_null)] | max_or_null) as $outRef
      | ($outRef // ([$w.lastActivityAt] | max_or_null)) as $ref
      | (if $ref == null or $now == null then null else ((($now - $ref) / 60000) | floor) end) as $idle
      | (($w.status // "") as $s | ["working", "permission", "waiting"] | index($s)) as $statusLive
      | ($w.pr.state // null) as $prState
      | ($prState == "MERGED" or $prState == "CLOSED") as $prDone
      | ($w.git) as $g
      | (if $g == null then false
         elif $g.exists == false then false
         elif $g.statusOk == false then false
         elif $g.dirty == null or $g.unpushed == null then false
         else true end) as $gitKnown
      | ($gitKnown and ($g.dirty > 0)) as $dirty
      | ($gitKnown and ($g.unpushed != 0)) as $unpushed
      | ((($w.childWorktreeIds // []) | length) > 0
         or ([$w.agents[]? | select(.parentPaneKey != null)] | length) > 0
         or ([$w.agents[]? | .paneKey] | unique | length) > 1) as $childAgent
      | [ (($L.workers // {}) | if type == "object" then . else {} end) | to_entries[]
          | select(.value | type == "object")
          | select(((.value.state // "") | IN("gone", "repurposed")) | not)
          | select(.value.host == null or .value.host == $w.host)
          | select((($w.worktreeId // "") != "" and .value.worktreeId == $w.worktreeId)
                   or ((.value.path | normpath) != "" and (.value.path | normpath) == ($w.path | normpath))) ] as $lw
      | (any($lw[]; .value.standing == true) or any($lw[]; .key as $k | $leads | index($k))) as $standing
      | (($standing | not) and (($lw | length) == 0 or any($lw[]; (.value.standing | type) != "boolean"))) as $standingUnknown
      | ([ $lw[] | .value.beadsEpic // empty | select(type == "string") ] | unique) as $epics
      | ((($w.comment // "") | startswith("cm:idle"))
         and ([ $w.agents[]? | select(.state == "working") ] | length) == 0) as $cmIdle
      | ([
          (if $standing then "standing" else empty end),
          (if $standingUnknown then "standing-unknown" else empty end),
          ($epics[] | "beads-epic:\(.)"),
          (if $cmIdle then "cm:idle" else empty end),
          (if ($live | length) > 1 then "multi-agent" else empty end),
          (if ($w.childWorktreeIds | length) > 0 then "has-children" else empty end),
          (if $childAgent then "has-child-agent" else empty end),
          (if $dirty then "dirty:\($g.dirty)" else empty end),
          (if $unpushed then "unpushed:\($g.unpushed)" else empty end),
          (if $g == null then "git-unknown"
           elif $g.exists != false and ($gitKnown | not) then "git-check-failed" else empty end),
          (if $g != null and ($g.exists == false) then "path-missing" else empty end),
          (if ([$live[] | select(.state == "waiting" or .state == "permission")] | length) > 0
              or $w.status == "permission" then "awaiting-input" else empty end),
          (if $w.pr == null then "no-pr" else "pr:#\($w.pr.number):\($w.pr.state)" end),
          (if $w.source == "git" then "git-only" else empty end)
        ]) as $flags
      | (if $w.isMainWorktree then
           {class: "main-checkout", reason: "main checkout", suggest: "never touch"}
         elif (($live | length) > 0 or $statusLive) and $idle != null and $idle >= $stuck then
           {class: "stuck",
            reason: "status \($w.status // "?"), agents [\([$w.agents[]?.state] | join(","))], no output for \($idle)m",
            suggest: "read pane (--screen); answer if factual, else nudge (max 2) or escalate"}
         elif ($live | length) > 0 or $statusLive then
           {class: "running", reason: "live agent, output \($idle // "?")m ago",
            suggest: (if ($flags | index("awaiting-input")) then "read pane; answer via menu keys or escalate" else "none" end)}
         elif ($gitKnown | not) then
           {class: "unknown-git",
            reason: (if $g == null then "git state not collected on \($w.host)"
                     elif $g.exists == false then "path gone"
                     else "a git check failed" end),
            suggest: (if $g != null and $g.exists == false then "investigate: path gone (git worktree prune candidate)"
                      else "investigate; never teardown on unknown state" end)}
         elif $dirty or $unpushed then
           {class: "dirty-or-unpushed",
            reason: "dirty \($g.dirty), unpushed \($g.unpushed), PR \($prState // "none")",
            suggest: "never delete; escalate with diff summary"}
         elif $prDone then
           {class: "done-merged", reason: "PR #\($w.pr.number) \($prState)", suggest: "teardown"}
         elif $allDone then
           {class: "done-selfreported", reason: "all \($w.agents | length) agent(s) report done",
            suggest: (if $w.pr != null and $prState == "OPEN" then "retire worker; PR #\($w.pr.number) to pr-sweeper"
                      else "retire worker; confirm deliverable; teardown only if the owner approves" end)}
         elif $w.source == "git" then
           {class: "orphan-git-only", reason: "git worktree Orca does not track",
            suggest: (if $prState == "OPEN" then "hand PR #\($w.pr.number) to pr-sweeper" else "check branch; ask" end)}
         else
           {class: "idle", reason: "no live agent, nothing merged",
            suggest: (if $prState == "OPEN" then "hand PR #\($w.pr.number) to pr-sweeper" else "adopt or ask" end)}
         end) as $c0
      | ((($w.agents // []) | length) == 0 or $w.source == "git" or $w.liveTerminalCount == 0) as $noAgent
      | (if $standing and $noAgent
            and (["idle", "done-merged", "done-selfreported", "orphan-git-only", "dirty-or-unpushed"] | index($c0.class)) then
           {class: "standing-dead", reason: ("standing lane, no live agent; " + $c0.reason),
            suggest: ((if $prState == "OPEN" then "hand PR #\($w.pr.number) to pr-sweeper; " else "" end)
                      + "respawn in place (claude --continue in its worktree); never retire or teardown")}
         elif $standing and $c0.class != "main-checkout" then
           (if ($c0.class == "stuck" and $cmIdle)
               or (["done-merged", "done-selfreported", "orphan-git-only", "idle"] | index($c0.class)) then
              {class: "standing-idle", reason: ("standing lane; " + $c0.reason),
               suggest: ((if $prState == "OPEN" then "hand PR #\($w.pr.number) to pr-sweeper; " else "" end)
                         + (if ($epics | length) > 0
                            then "standing lane: count open beads under \($epics | join(",")); open: nudge to continue; never retire, teardown or respawn"
                            else "standing lane: idle; hand it work; never retire, teardown or respawn" end))}
            elif $c0.class == "stuck" then
              $c0 + {suggest: "standing lane: read pane, nudge (max 2); respawn in place only, never retire or teardown"}
            else $c0 end)
         elif $standingUnknown and (["done-merged", "done-selfreported", "orphan-git-only", "idle"] | index($c0.class)) then
           $c0 + {suggest: ("standing unknown: record ledger standing true/false first; no retire or teardown until then"
                            + (if $prState == "OPEN" then "; hand PR #\($w.pr.number) to pr-sweeper" else "" end))}
         elif ($epics | length) > 0 and (["done-merged", "done-selfreported"] | index($c0.class)) then
           $c0 + {suggest: ("beads gate first: every bead under \($epics | join(",")) closed (teardown.sh dry run); then " + $c0.suggest)}
         else $c0 end) as $c1
      | (if $childAgent and (["done-merged", "done-selfreported", "orphan-git-only", "idle", "standing-idle", "standing-dead"] | index($c1.class))
         then $c1 + {suggest: "investigate: child agent present; never teardown"}
         else $c1 end) as $c
      | {host: $w.host, class: $c.class, path: $w.path, repo: $w.repo, branch: $w.branch,
         worktreeId: $w.worktreeId, inOrca: $w.inOrca, idleMinutes: $idle,
         pr: (if $w.pr == null then null else {number: $w.pr.number, state: $w.pr.state, author: $w.pr.author} end),
         flags: $flags, reason: $c.reason, suggest: $c.suggest} )
  ] as $items
| {
    schema: "concertmaster.classify/v1",
    generatedAt: .generatedAt,
    stuckMinutes: $stuck,
    summary: ($items | group_by(.class) | map({key: .[0].class, value: length}) | from_entries),
    items: $items
  }
