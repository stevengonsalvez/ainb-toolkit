# The drive ladder: no lane, PR or ask waits for hours without a move

`scripts/stall.sh` is the mechanical half. Every tick, after discover, classify and asks, it reads their
JSON files and the ledger (no `orca`, `gh` or `ssh` call) and lists every lane, PR and ask that has had no
progress for `schedule.stall_rungs_min` minutes (default 30, 60, 90), the rung it is on and the action
already taken. The concertmaster takes the action and records it with `--act`.

```text
no progress ──▶ 30 min: rung 1 ──▶ 60 min: rung 2 ──▶ 90 min: rung 3
                nudge (an ask:     restart or re-place   independent verdict,
                relay or reply)    (an ask: relay or     then act
                                   close it)
```

A ladder never skips a rung: the rung is the lower of the age rung and the last rung acted plus one. A due
row with no action at or above its rung since the tick started is `NO-ACTION` (exit 4): a nudge every tick
never hides a missed restart or verdict. While `$CM_HOME/resume.lock` is held a lane or PR on rung 2 is
`held`: no restart runs (`scripts/resume.sh` or `scripts/lane-health.sh` only).

## What counts as progress

- lane: the classify idle time, and the first sighting of the head commit of its open PR;
- PR: the first sighting of its head commit (kept in `$CM_HOME/stall-seen.json`) and `updatedAt`;
- ask: `asks.sh` `firstSeen`, or a ledger ask's `askedAt`.

A time written inside a worktree comment is never progress: a note or a deadline says nothing about when the
lane last moved.

## What never ladders (exempt, with a reason)

- hosts that were not read in full (offline, cut off, unreachable for `asks.sh`): counted as `unverified`,
  never stalled;
- main checkouts, other projects, `worktrees.never_touch`, merged or self-reported-done lanes, the
  concertmaster's own worktree, a lead's children, a lane the ledger holds `asleep` or `parked`, a standing
  lane with nothing queued or granted;
- anything waiting on the owner: a `cm:waiting-owner` comment, a worker in `blocked-on-owner`, every comment
  ask (`cm:ask`, `cm:blocked`: they carry no kind, so they are owner-only), a lane with an open ask, and the PR
  a live ledger ask names (`asks[].pr`);
- PRs labelled `do-not-merge`, every PR while the ledger `freeze` is on, PRs by a `messaging.collaborators`
  author, and the PR of a waiting lane;
- a row with a `blocked` or `close-ask` action recorded, until it makes progress.

## Which ledger asks the ladder may drive

A ledger ask with a string `id` ladders only when its kind is one of:

- `code`, `design`, `test`, `scope`, `product`: the same gates as the away timeout (`references/away-timeout.md`),
  one shared definition: an issue number, a lane (the ask's, else its ledger worker's) that is not ops, epic or
  pr-sweeper, not an epic "plan ready" approval, `files[]` listed unless `noCode: true`, every path on the allowlist
  and off the never-list, and no owner-only subject in the shared deny scan (`scripts/ask-deny.sh`);
- `release` or `deploy`, and ONLY when the question and topic are exactly one phrase naming a class listed in
  `drive.delegated_classes` (`[verb] [the] <class> [build|release|bundle|update] [version] [to|on|in <track>]
  [today|tonight|now]`, no other words). The default list is empty, so every release or deploy ask goes to the
  owner. An ask that also names a secret, a credential term, a runbook or a cutover is the owner's whatever
  class it names.

Listing a class is the owner's delegation to answer that one ask. It changes nothing else: the verdict decides the
question, and the act that follows still runs the normal path. A deploy still waits for a deploy window with every
`deploy.rails` entry clear, a rails hit still asks the owner, and a native release still goes through its own gates.
The away timeout (`references/away-timeout.md`) never decides a release or a deploy; only this ladder does, and only
for a listed class.

Everything else is owner-only and shows as Blocked: `secrets` always, `merge`, `credentials`, `migration`,
`auth`, `payments`, `prod-data`, `teardown`, `owner`, the teardown override kinds, a missing or unknown kind. A
question, topic, lane, worker or path that is not text, a `files` that is not a list of text, or those fields over
4000 characters as JSON, makes the ask the owner's before any text is normalised.

## Recording an action

```text
scripts/stall.sh --act <lane|pr|ask> <name> <verb> "<what was done>" [--host H] [--path P]
```

Verbs: `nudge`, `relay` (rung 1), `restart`, `replace`, `close-ask` (rung 2), `verdict`, `blocked` (rung 3).
One JSON line goes to `$CM_HOME/stall-actions.ndjson`. A text, name, host or path that looks like a
credential is refused (`scripts/secret-shape.sh`), so say what was done without the value. A `verdict` also
appends a `decisions[]` row to the ledger first (`references/ledger.md`); nothing is recorded when that write
is refused.

## Output and exit codes

A table (`KIND NAME HOST AGE RUNG DUE ACTED`), one summary line, then a `NO-ACTION` line when flagged; `--json`
adds `rows[]`, `exempt[]`, `unverified`, `gaps[]`. A name, text, host or path that looks like a credential is
printed as `[withheld: looks like a credential]`. Exit 0 clean, 4 `NO-ACTION`, 3 an input missing, unparsable or
older than two ticks (the longest `schedule.tick_delays_s` twice), 2 usage. Every input is sanitised once, so one
malformed value holds only itself. Test: `scripts/test/stall.sh`.
