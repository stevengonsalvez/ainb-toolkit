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
# A worktree comment starting `cm:retire` counts as every agent done (done-
# selfreported: retire, then teardown once clean and merged or closed); one
# starting `cm:keep` is held as standing-idle (never retire or teardown). A
# standing lane is not kept asleep: standing-dead still respawns it. Live agents
# and dirty or unpushed work keep their own class; a ledger-unknown worktree
# keeps its standing-unknown flag until the ledger records standing:false.
#
# Flag has-child-agent (child worktrees, a pane with a parent pane, or more
# than one agent pane) overrides the action to "investigate" and the item is
# never a teardown candidate.
#
# Violations (config agents.forbidden, passed as --argjson forbidden): every terminal in the
# discover document's `terminals` (discover.sh keeps only worktree paths matching config
# worktrees.path_match) whose agentIdentity is a forbidden agent (or whose title is
# "resumed <agent>", the resumer's title before Orca has identified the process) becomes a
# row in `.violations`: host, worktree (name), path, handle, title, agent. Independent of
# class. The check is `violationCheck.complete` only when discover listed terminals on every
# reachable host, untruncated; a document without terminal data, an offline host, or a host
# whose terminal list failed or was cut off, is incomplete and names why, so "no violations"
# is never claimed unchecked. With agents.forbidden empty the census is off:
# `violationCheck.enabled` is false and `complete` is true with no gaps.
# Ownership (when --argjson own is not null; rules in config.yaml `ownership`):
# every in-scope worktree (the configured Orca repo, never a main checkout, never a
# never_touch name) gets `owner` (a lane label) and `ownerSource`, first hit wins:
#   self     the concertmaster worktree itself
#   lead     the worktree is a lane lead (config leads, or the ledger's lanes.<lane>.lead)
#   comment:<lead>  a lead's own worktree comment lists the worktree after one of
#            its markers ("WORKERS I OWN: a (..), b (..)"); tolerant of format;
#            fresher than the ledger, so it wins over it
#   ledger   workers.<id>.lane
#   prefix   longest worktree-name prefix in the config
#   standing a ledger-standing worktree with no other owner owns itself
#   scratch-of:<worker>  a git-only worktree inside that worker's session scratch
#            dir (config scratch_path_regex) inherits the worker's owner
# No owner: flag ORPHAN and a suggest to ask the likely lane, else tear down per
# the teardown gates. A lead with no live session (or no worktree in a fully
# reachable census) while it owns open work: flag LEAD-DEAD on the lead row and
# list it under .ownership.leadDead. Class never changes for ownership.
#
# Timestamps are epoch ms; any of them may be null on remote rows.

def live_states: ["working", "waiting", "permission", "blocked", "running"];

# Epoch-ms values before 2020 are placeholders (Orca reports 0 or tiny values
# on never-opened main checkouts); treat them as unknown.
def max_or_null: map(select(. != null and . > 1577836800000)) | if length == 0 then null else max end;

def normpath: if type == "string" then sub("/+$"; "") else "" end;

def lc: ascii_downcase;
def rxesc: gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}])"; "\\" + .c);
def tokens: [ match("[A-Za-z0-9][A-Za-z0-9._-]*"; "g").string | sub("[._-]+$"; "") | lc ];
# Worker names a lead lists in $text: after each marker that starts the comment, a
# " | " section, a sentence ("... . OWNED (x): a, b") or a "cm:<state> " prefix (or follows
# ", ", ": " or " - " directly before ( [ or :), and is written as a
# header (followed by "(", "[" or ":" or by a few words and a colon), up to the
# next " | ", the next "<stop word>:", the next ALL-CAPS header, or the end.
# Parenthesised text is masked for the marker, pipe, stop-word and name search
# (a "(cm: nudged)" never cuts a list, a "(not owned)" never starts one, a name
# inside a parenthesis is never claimed); a marker after "not", "not-", "never",
# "no longer" or "dis" is a negation. Only names in $names count, so prose and
# host names never become owners.
def mask: gsub("(?<p>\\([^()]*\\))"; (.p | length) as $n | " " * $n);
def claims($text; $mk; $stop; $names):
  ($text | mask | mask) as $m
  | ($mk | map(rxesc) | join("|")) as $mre
  | (if ($stop | length) > 0 then "\\b(" + ($stop | map(rxesc) | join("|")) + ")\\s*:" else null end) as $sre
  # strong boundaries (comment start, pipe section, sentence, line, a "cm:<state> " prefix) allow the
  # "few words and a colon" header; weak ones (", " ": " " - ") need the marker right before ( [ or :
  | ("(?:\\A|\\| |[.;] |\\n|cm:[A-Za-z-]+\\s+)\\s*\\b(" + $mre + ")") as $strong
  | ("(?:, |: | - )\\b(" + $mre + ")(?=\\s*[(\\[:])") as $weak
  | [ ($strong, $weak) as $rx | $m | match($rx; "gi") | .captures[0] as $mk0
      | select(($text[($mk0.offset + $mk0.length):]) | test("^(\\s*[(\\[:]|(?![^:|()\\n]{0,40}\\bby\\b)[^:|()\\n]{0,40}:)"))
      | select(($text[($mk0.offset + $mk0.length):]) | test("^\\s*\\([^)]*\\b(not|never|no longer)\\b") | not)
      | {offset: $mk0.offset, length: $mk0.length}
      | ($m[(.offset + .length):]) as $mrest
      | ([ ([$mrest | match(" \\| ")] | first | .offset?),
           (if $sre == null then null else ([$mrest | match($sre; "i")] | first | .offset?) end),
           ([$mrest | match("\\b[A-Z]{2,}[A-Z0-9 ]*:")] | first | .offset?),
           ([$mrest | match("\\.\\s")] | first | .offset?) ]
         | map(select(. != null)) | if length == 0 then ($mrest | length) else min end) as $e
      | $mrest[:$e] | tokens[] | select(. as $t | $names | index($t)) ] | unique;
def nrm: ascii_downcase | gsub("[^a-z0-9]"; "-");

($stuckMin // 45) as $stuck
| [ ($forbidden // [])[] | select(type == "string" and length > 0) | ascii_downcase ] as $forbid
| (($ledger // [])[0] // {}) as $L
| [ ($L.lanes // {})[]? | .lead? // empty | select(type == "string") ] as $leads
| [ ($L.lanes // {}) | if type == "object" then . else {} end | to_entries[]
    | select(.value | type == "object") | select(.value.lead | type == "string")
    | . as $e | (($L.workers // {}) | if type == "object" then . else {} end)[$e.value.lead]
    | select(type == "object") | select(.path | type == "string")
    | select(((.state // "") | IN("gone", "repurposed")) | not)
    | {name: (.path | normpath | split("/") | last // ""), label: $e.key, host: (.host // null)} ] as $ledgerLeads
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
      | (($w.comment // "") | test("^cm:retire(\\s|$)")) as $cmRetire
      | (($w.comment // "") | test("^cm:keep(\\s|$)")) as $cmKeep
      | ([
          (if $standing then "standing" else empty end),
          (if $standingUnknown then "standing-unknown" else empty end),
          ($epics[] | "beads-epic:\(.)"),
          (if $cmIdle then "cm:idle" else empty end),
          (if $cmRetire then "cm:retire" else empty end),
          (if $cmKeep then "cm:keep" else empty end),
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
         elif $allDone or $cmRetire then
           {class: "done-selfreported",
            reason: (if $allDone then "all \($w.agents | length) agent(s) report done" else "comment cm:retire" end),
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
         elif ($standing or $cmKeep) and $c0.class != "main-checkout" then
           (if ($c0.class == "stuck" and $cmIdle)
               or (["done-merged", "done-selfreported", "orphan-git-only", "idle"] | index($c0.class)) then
              {class: "standing-idle", reason: ((if $standing then "standing lane; " else "kept by cm:keep; " end) + $c0.reason),
               suggest: ((if $prState == "OPEN" then "hand PR #\($w.pr.number) to pr-sweeper; " else "" end)
                         + (if $cmKeep
                            then "kept by comment (cm:keep <why, until when>): chase the owner once its until-when has passed; never retire, teardown or respawn"
                            elif ($epics | length) > 0
                            then "standing lane: count open beads under \($epics | join(",")); open: nudge to continue; never retire, teardown or respawn"
                            else "standing lane: idle; hand it work; never retire, teardown or respawn" end))}
            elif $c0.class == "stuck" and $standing then
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
         flags: $flags, reason: $c.reason, suggest: $c.suggest,
         name: ($w.path | normpath | split("/") | last // ""), isMain: ($w.isMainWorktree // false),
         comment: ($w.comment // ""), noAgent: $noAgent,
         ledgerLane: ([$lw[] | .value.lane? | select(type == "string" and length > 0)] | first // null)} )
  ] as $items0
| (if $own == null then null else
    ($own.neverTouch // [] | map(lc)) as $nt
    | ($own.repo // "" | lc) as $repo
    | ($own.self // "" | lc) as $self
    | ($own.markers // []) as $mk
    | ($own.stopWords // []) as $stop
    | def inscope: (.name // "" | lc) as $n | (.repo // "" | lc) as $r
                    | $n != "" and .repo != null and $r == $repo and (.isMain | not)
                      and (($nt | index($n)) == null) and (($nt | index($r)) == null);
      ([ $items0[] | select(inscope) | .name | lc ] | unique) as $names
    | (( $own.leads // {} | to_entries | map({name: (.key | lc), label: .value}))
       + ($ledgerLeads | map({name: (.name | lc), label: .label}))
       | unique_by(.name)) as $leadList
    | [ $leadList[] | . as $ld
        | ([ $items0[] | select(inscope and (.name | lc) == $ld.name) | .comment ] | join(" | ")) as $c
        | claims($c; $mk; $stop; $names)[] | select(. != $ld.name)
        | {name: ., label: $ld.label, lead: $ld.name} ] as $claims
    | ($own.prefixes // {} | to_entries | map({key: (.key | lc), value: .value})) as $pfx
    | [ $items0[] | . as $i
        | (if ($i | inscope | not) then
             {owner: null, ownerSource: (if $i.class == "host-offline" then null elif $i.isMain then "main-checkout" else "out-of-scope" end), extra: []}
           else
             ($i.name | lc) as $nm
             | ([$claims[] | select(.name == $nm)] | sort_by(.label)) as $cl
             | ([$pfx[] | . as $p | select($nm | startswith($p.key))] | sort_by(.key | length) | last) as $pf
             | ($leadList | map(select(.name == $nm)) | first) as $ld
             | if $nm == $self then {owner: $own.self, ownerSource: "self", extra: []}
               elif $ld != null then {owner: $ld.label, ownerSource: "lead", extra: []}
               elif ($cl | length) > 0 then
                 {owner: $cl[0].label, ownerSource: ("comment:" + $cl[0].lead),
                  extra: (if ($cl | map(.label) | unique | length) > 1
                          then ["owner-contested:" + ($cl | map(.label) | unique | join(","))] else [] end)}
               elif $i.ledgerLane != null then {owner: $i.ledgerLane, ownerSource: "ledger", extra: []}
               elif $pf != null then {owner: $pf.value, ownerSource: "prefix", extra: []}
               elif ($i.flags | index("standing")) != null then {owner: $i.name, ownerSource: "standing", extra: []}
               else {owner: null, ownerSource: "none", extra: []} end
           end) as $o
        | $i + {owner: $o.owner, ownerSource: $o.ownerSource, flags: ($i.flags + $o.extra)} ] as $owned1
    # Last rule: a worktree made inside another worker's session scratch dir
    # (a git-only temp worktree) belongs to that worker's owner. The agent CLI encodes a
    # cwd by turning every non-alphanumeric into "-", and a session may start in a
    # subdirectory, so both sides are normalised and the longest worktree name
    # that prefixes the captured segment wins. Then ORPHAN.
    | ([ $owned1[] | select(.owner != null and (.name // "") != "") | . + {n: (.name | nrm)} ]) as $ownedNorm
    | [ $owned1[] | . as $i
        | if $i.ownerSource != "none" then $i
          else
            (if ($own.scratchPathRegex // null) == null then null
             else (try ([$i.path // "" | capture($own.scratchPathRegex; "i")] | first | .worker?) catch null) end) as $w
            | (if $w == null then null
               else ($w | nrm) as $wn
                    | ($ownedNorm | map(select(. as $r | $r.n == $wn or ($wn | startswith($r.n + "-")))) | sort_by(.n | length) | last) end) as $par
            | if $par != null then $i + {owner: $par.owner, ownerSource: ("scratch-of:" + $par.name)}
              else $i + {flags: ($i.flags + ["ORPHAN"]),
                         suggest: ($i.suggest + "; ORPHAN: no owner (no lead lists it, no prefix covers it). Ask the likely lane lead"
                           + (if (($i.class | IN("idle", "orphan-git-only", "done-merged", "done-selfreported"))
                                  and (($i.flags | index("standing")) == null) and (($i.flags | index("standing-unknown")) == null)
                                  and (($i.flags | index("has-child-agent")) == null))
                              then "; with no claim after 2 ticks and the lead's loop interval, tear down per the teardown gates (SKILL.md § Ownership)"
                              else "; never teardown on this class (SKILL.md § Ownership)" end))} end
          end ] as $owned
    | ([ $ledgerLeads[] | {key: (.name | lc), value: .host} ] | from_entries) as $ledgerHost
    | [ $leadList[] | . as $ld
        | ([ $owned[] | select(inscope and (.name | lc) == $ld.name) ]) as $rows
        # Open work is counted per lead, not per label: an item another lead's comment
        # claimed is that lead's; label-owned items (prefix, ledger) go to this lead only
        # while no other lead sharing the label has a live session (a superseded
        # a superseded iteration must not inherit its successor's work).
        | ([ $leadList[] | select(.label == $ld.label and .name != $ld.name) | .name ]) as $sibs
        | ([ $sibs[] | . as $sn | [ $owned[] | select(inscope and (.name | lc) == $sn) ] | select(length > 0 and (all(.[]; .noAgent) | not)) ] | length > 0) as $sibLive
        | ([ $owned[] | select(.owner == $ld.label and ((.ownerSource | IN("lead", "self")) | not)
                               and ((.class | IN("done-merged", "main-checkout", "host-offline")) | not)
                               and ((.pr == null) or ((.pr.state | IN("MERGED", "CLOSED")) | not))
                               and ((.name | lc) != $ld.name)
                               and ((.ownerSource == ("comment:" + $ld.name))
                                    or (((.ownerSource | startswith("comment:")) | not) and ($sibLive | not)))) ]) as $open
        # A lead with no worktree is called dead only when the ledger records it as
        # spawned and not gone, and its own host answered in full (not offline, not truncated).
        | ($ledgerHost[$ld.name] // null) as $lh
        | (($lh != null) and ([$hosts[] | select(.name == $lh and .reachable and (.truncated != true))] | length) > 0) as $hostOk
        | select(($open | length) > 0)
        | select((($rows | length) > 0 and all($rows[]; .noAgent)) or (($rows | length) == 0 and $hostOk))
        | {lane: $ld.label, lead: $ld.name, hosts: ($rows | map(.host)),
           reason: (if ($rows | length) == 0 then "lead worktree not in the census (ledger lead, its host answered in full)" else "lead session gone" end),
           open: ($open | map(.name) | unique)} ] as $dead
    | {owned: ([ $owned[] | . as $i
          | if (.owner != null) and ([$dead[] | select(.lead == ($i.name | lc))] | length) > 0 and ($i | inscope) then
              .flags += ["LEAD-DEAD"]
              | if .class == "standing-dead" then .
                else .suggest += "; LEAD-DEAD: lane \(.owner) lead session is gone while it owns \([$dead[] | select(.lead == ($i.name | lc)) | .open | length] | first) open item(s): respawn in place (claude --continue in its worktree) else hand the items to another lead; never leave them unwatched" end
            else . end ]),
       dead: $dead} end) as $O2
| (if $O2 == null then $items0 else $O2.owned end | map(del(.isMain, .comment, .noAgent, .ledgerLane))) as $items
| ([ (.terminals // [])[]
     | (if (.agentIdentity | type) == "string" then (.agentIdentity | ascii_downcase) else "" end) as $id
     | (if (.title | type) == "string" then (.title | ascii_downcase) else "" end) as $ti
     | ([ $forbid[] | select(. == $id or "resumed " + . == $ti) ] | first // null) as $hit
     | select($hit != null)
     | {host, worktree: ((.worktreePath | normpath | split("/") | last) // ""), path: .worktreePath,
        handle: (.handle // null), title: (.title // null), agent: $hit, rule: "forbidden-agent"} ]
   | sort_by(.host, .worktree, .handle)) as $violations
| (.terminalScope // null) as $ts
| (if ($forbid | length) == 0 then []
   elif $ts == null or ($ts.enabled | not) then ["discover document has no terminal data (older discover.sh, or agents.forbidden unset when it ran): forbidden-agent check not run"]
   elif ($ts.pathMatch // "") == "" then ["worktrees.path_match is unset: forbidden-agent check not run"]
   else [ ($ts.hosts // [])[] | select(.ok != true) | "\(.host): \(.error // "terminal list failed")" ]
        + [ $hosts[] | select(.reachable | not) | "\(.name): host offline, terminals not listed" ]
        + [ $hosts[] | select(.reachable) | .name as $n
            | select(([($ts.hosts // [])[] | select(.host == $n)] | length) == 0)
            | "\($n): terminals not listed" ] end) as $vgaps
| {
    schema: "concertmaster.classify/v1",
    generatedAt: .generatedAt,
    stuckMinutes: $stuck,
    summary: ($items | group_by(.class) | map({key: .[0].class, value: length}) | from_entries),
    violations: $violations,
    violationCheck: {enabled: ($forbid | length > 0), forbidden: $forbid,
                     complete: ($vgaps | length == 0), gaps: $vgaps},
    ownership: (if $O2 == null then {configured: false, error: ($ownErr // "ownership accounting is off")}
                else {configured: true,
                      orphans: ($items | map(select(.flags | index("ORPHAN"))) | length),
                      leadDead: $O2.dead,
                      byOwner: ($items | map(select(.owner != null)) | group_by(.owner) | map({key: .[0].owner, value: length}) | from_entries)} end),
    items: $items
  }
