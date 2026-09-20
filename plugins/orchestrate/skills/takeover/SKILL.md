---
name: takeover
description: Claim a programme's owner lock, re-verify every lane handle, run one tick and report what to arm next. Use to pick up a programme after a handover, to resume one whose orchestrator crashed or ran out of credits, or to take a stale lock. One line is enough to start with no other context.
---

# takeover

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh takeover <programme>

# the lock is held and fresh, and you are certain the holder is gone
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh takeover <programme> --takeover
```

This is the whole start-up sequence for a fresh session on any harness. Nothing
else needs to be in context.

1. Claims `owner.json`. A lock held by another session is refused unless it is
   stale past twice the cadence, or `--takeover` is passed. Either way the
   takeover is recorded with both session names and the reason.
2. Re-verifies every handle BEFORE anything is sent. A host may have restarted
   while nobody was watching, and a send into a stale handle lands nowhere.
3. Runs one tick.
4. Tells you what to arm for this harness.

## Then, in order

1. Read `HANDOVER.md` in the programme dir if there is one, then
   `ORCHESTRATION.md`, which is the house rules and outranks your instincts.
2. Do the judgment half of the tick you just ran, per `orchestrate:tick`.
3. Arm the loop: `/loop` on Claude Code, `orchestrate:loop --tmux` anywhere
   else.

## If takeover is refused

The refusal names the session holding the lock and how long ago it ticked. That
session is probably alive. Do not pass `--takeover` to get past a refusal you
have not understood: two orchestrators on one programme double-merge and
double-message. Check with the holder, or wait for the lock to go stale.

## Cross-host

The programme dir is host-local. To take over from another machine, copy
`~/.claude/orchestrator/<programme>/` there first, then re-verify handles, which
this verb does anyway. Say in your first report that you moved it.
