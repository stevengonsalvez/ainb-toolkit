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

# also index the lanes it reported as UNINDEXED
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh adopt <programme> --include-new
```

Needs a programme dir and the ownership token. Create the dir with
`orchestrate.sh init <programme> --trunk <branch> --repo <checkout>`, edit
`programme.yaml` (`autonomy` and `repo` must both be set deliberately, never
left to a default), then claim it with `orchestrate:takeover`, which prints the
token once. A dry run needs no token; writing does.

Columns: `lane, env, worktree, agent, handle, status, ctx`.

## What it does

- Reads EVERY handle in screen mode. Liveness is never inferred from a terminal
  listing: an empty list has come back while lanes were alive.
- A handle that reads empty is re-resolved from its worktree, and the row is
  rewritten with the live handle.
- Classifies each lane `working, idle, asking, dead, unknown` from the screen
  patterns in `agents.yaml`, and reads its context use from the status line.
- `done`, `retired` and `needs-rebind` are decisions, not screen states, so a row
  already carrying one is left alone.
- MERGES into an existing row. `branch`, `goal`, `exclusive` and `title` are
  yours and are never blanked by a re-verify pass: the retirement guard reads
  `branch`, so wiping it would quietly disarm the wall that stops a worktree
  being removed under open work.
- Reports anything live that is not indexed as an `UNINDEXED` row. A lane
  started by hand and never registered is the failure this verb exists to
  prevent, so discovery runs every time, not only on an empty index. Those rows
  are written only with `--include-new`.

## Judgment left to you

| thing | what to do |
|---|---|
| a lane reads `unknown` | read it: `orchestrate.sh read <programme> <lane> 40`. The screen pattern in `agents.yaml` is probably wrong for this agent. Fix the pattern, not the code |
| `ctx` is blank | that agent kind has no verified context pattern yet. See `${CLAUDE_PLUGIN_ROOT}/references/agents-yaml.md` |
| a lane's agent kind is wrong | edit the `agent` field in `lanes.jsonl`; it decides how the lane is resumed and compacted |
| a lane is `dead` | `orchestrate:tick` restarts it with that kind's resume command |
| a lane reads `needs-rebind` | its worktree holds several terminals and none is uniquely titled for it. Set `title` in `lanes.jsonl` to that terminal's title, then adopt again. Nothing is sent to a lane in this state |
| an `UNINDEXED` row appears | decide whether it is a lane. If it is, name it and adopt with `--include-new`, then fill its `branch` and `goal` |

Fill `branch`, `goal`, `exclusive` and `title` in `lanes.jsonl` by hand after
adopting: adopt cannot know them, they survive every later adopt, and the
retirement guard refuses outright when `branch` is unknown. `title` is what
binds a lane to its own terminal when a worktree holds more than one.

## Before the first unattended run

Fill `attribution_patterns` and `scrub.deny` in `programme.yaml` with the tool
and vendor names this programme must never publish, anchored as the template
shows. The shipped defaults match one trailer shape and nothing else, so until
you set them a report naming a vendor in prose scrubs clean and posts.

Every policy key, and which of them are walls:
`${CLAUDE_PLUGIN_ROOT}/references/programme-yaml.md`.

## Next

`orchestrate:tick` once, then arm `orchestrate:loop`.
