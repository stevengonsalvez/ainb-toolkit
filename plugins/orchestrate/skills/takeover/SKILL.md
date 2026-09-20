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

## The token it prints is the ownership

Taking a programme mints a token and prints it once, with the export line:

```
export ORCHESTRATE_SESSION=<token>
```

Export it immediately. It is stored NOWHERE: `owner.json` holds only its hash.
Every verb that writes (`send`, `merge`, `post`, `mark`, `pr`, `retire`, `tick`,
`loop`) refuses without it and names this verb as the way in. A harness that
cannot set an environment variable passes `--session <token>` instead.

That is what makes the lock per ORCHESTRATOR rather than per directory. An
identity kept in the programme directory would be readable by any process that
opens it, and two orchestrators on one host would silently share one lock and
double-merge, which is the thing the lock exists to stop.

| situation | what to do |
|---|---|
| you lost the token | the programme stays locked until the lock goes stale, then `takeover` again. There is no recovery path that reads it back, by design |
| you are arming a loop | the driver passes the token to the ticks it spawns. Keep it exported in the session that armed the loop |
| the harness has no environment | pass `--session <token>` on every call |
| someone handed the programme over | the old token is spent; claim a new one here |

A same-user process that steals the token is inside the documented trust
boundary (`${CLAUDE_PLUGIN_ROOT}/references/never-do.md`). One that merely runs
the script in the same directory is not an owner.

This is the whole start-up sequence for a fresh session on any harness. Nothing
else needs to be in context.

1. Claims `owner.json` and mints the token above. A lock held by another session
   is refused unless it is stale past twice the cadence, or `--takeover` is
   passed. Either way the takeover is recorded with both labels and the reason.
   Taking a programme you already hold is a no-op, not a fight.
2. Re-verifies every handle BEFORE anything is sent. A host may have restarted
   while nobody was watching, and a send into a stale handle lands nowhere.
3. Runs one tick in OBSERVE mode: it classifies, measures and audits, and sends,
   restarts and creates nothing. A lane misclassified from a handle that went
   stale while nobody was watching would otherwise have a resume command typed
   into a live session. Read that tick, then run one that acts.
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
