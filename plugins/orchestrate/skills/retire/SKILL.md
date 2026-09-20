---
name: retire
description: Remove a finished lane's worktree through Orca, only once it is merged, clean and idle. Use when a lane's work has landed and its worktree is just taking disk, or at a programme's exit condition. Refuses on anything still working, still holding an open PR, or still showing a live agent.
---

# retire

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh retire <programme> <lane>
```

Three guards, all refusals, each recorded as a `refuse` event:

| guard | refuses when |
|---|---|
| `retire-busy` | the lane's status is not `idle` or `done` |
| `retire-unmerged` | its `branch` still has an open PR |
| `retire-live` | its screen still shows a live agent and it is not marked `done` |

Removal goes through Orca. Nothing is deleted from the filesystem directly, no
process is killed, and there is no force.

## Before retiring

1. Run a tick, so the lane's status is current rather than a stale reading.
2. Check `owed` is zero for that lane. Retiring a lane that was never told its
   PR merged loses the notice permanently.
3. Confirm the branch field in `lanes.jsonl` is filled. An empty `branch` means
   the unmerged guard cannot check anything, so check it yourself.

## When a refusal fires

It is telling you the lane is not finished. Ask the lane to wind up its work and
go idle, then retire it at the next tick. Do not work around the guard by
removing the worktree by hand: a lane with uncommitted work loses it, and that
has happened.

Disk pressure is not a reason to retire early. Ask the owning lane to clean, and
never delete under it.
