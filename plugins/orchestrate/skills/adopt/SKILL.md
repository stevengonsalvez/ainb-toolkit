---
name: adopt
description: Index the agent lanes that already exist into a programme's lanes.jsonl, reading each terminal to classify it and its context use. Use when taking charge of lanes started by hand, when starting a programme from running work, or as the re-verify pass after a host restart or before any send. Dry-run first, confirm once, then write.
---

# adopt

```bash
# propose, write nothing
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh adopt <programme> --dry-run \
  --environment local --environment <remote>

# write the rows once the table looks right
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh adopt <programme> \
  --environment local --environment <remote>
```

Needs a programme dir. Create one first with `orchestrate.sh init <programme>
--trunk <branch> --never-merge-into <branch>`, then edit `programme.yaml`:
`autonomy` must be set deliberately, never left to a default.

Columns: `lane, env, worktree, agent, handle, status, ctx`.

## What it does

- Reads EVERY handle in screen mode. Liveness is never inferred from a terminal
  listing: an empty list has come back while lanes were alive.
- A handle that reads empty is re-resolved from its worktree, and the row is
  rewritten with the live handle.
- Classifies each lane `working, idle, asking, dead, unknown` from the screen
  patterns in `agents.yaml`, and reads its context use from the status line.
- `done` and `retired` are decisions, not screen states, so an existing `done`
  row is left alone.

## Judgment left to you

| thing | what to do |
|---|---|
| a lane reads `unknown` | read it: `orchestrate.sh read <programme> <lane> 40`. The screen pattern in `agents.yaml` is probably wrong for this agent. Fix the pattern, not the code |
| `ctx` is blank | that agent kind has no verified context pattern yet. See `${CLAUDE_PLUGIN_ROOT}/references/agents-yaml.md` |
| a lane's agent kind is wrong | edit the `agent` field in `lanes.jsonl`; it decides how the lane is resumed and compacted |
| a lane is `dead` | `orchestrate:tick` restarts it with that kind's resume command |

Fill `branch`, `goal` and `exclusive` in `lanes.jsonl` by hand after adopting:
adopt cannot know them, and the merge gate and retirement guard both read
`branch`.

## Next

`orchestrate:tick` once, then arm `orchestrate:loop`.
