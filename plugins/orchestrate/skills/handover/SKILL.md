---
name: handover
description: Generate HANDOVER.md from a programme's index files and release the owner lock so another session, on any harness, can pick the programme up. Use when credits or context are running out, when asked to stop, when a session is ending, or before switching the orchestrator to a different agent or machine.
---

# handover

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh handover <programme> "<reason>"
```

Writes `HANDOVER.md` in the programme dir, records a `handover` event with the
reason, and deletes `owner.json`.

## The brief is generated, never authored

It is built from `lanes.jsonl`, `events.jsonl`, `hosts.jsonl` and `reviews/`:
lanes and their states, PR ownership, owed notices, reviews on disk, the last
twenty decisions and steers, host pressure, and one next action. A brief written
by hand goes stale the moment the next tick runs; this one cannot.

Do not add prose to it. Anything the next orchestrator must know permanently
belongs in `ORCHESTRATION.md`, which every tick reads. Anything about one
decision belongs in a `decision` event, so a later tick can see what was told to
whom.

## Before handing over

1. Run one tick, so the index reflects reality rather than a stale reading.
2. Drive `owed` to zero. A lane left awaiting a verdict on a merged PR is the
   single most expensive thing to hand over.
3. Then run handover, and tell whoever is next the one line they need:
   `orchestrate:takeover <programme>`.

## Credit guard

When `handover.credit_threshold_pct` in `programme.yaml` is crossed and the
harness exposes its own usage, run this yourself rather than waiting to run out,
and notify with the takeover command.

## The programme dir is host-local

Taking over on a different machine needs that directory copied there first, or
the same machine used. Say which you did.
