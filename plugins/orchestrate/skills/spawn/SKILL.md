---
name: spawn
description: Start a new agent lane on a chosen host with a worktree, an agent and a goal, then index it. Placement scoring is cut 2; this describes the manual path that produces the same indexed result, so no lane is ever started without being recorded.
---

# spawn

CUT 2 IS NOT BUILT. There is no automatic placement, no scoring and no
`spawn` verb yet. Use the manual path below, which ends in the same place: a
lane in `lanes.jsonl` that every other verb can drive.

A lane started by hand and never registered is how a lane got lost for hours.
Step 4 is not optional.

## Manual path

1. Pick a host per `orchestrate:preflight`. Refuse any host under the floors, at
   its lane cap, or already holding an exclusive resource this lane needs.
2. Create the worktree with the agent in its first terminal:

```bash
orca worktree create --name <lane-name> --agent <claude|codex> \
  --repo id:<repoId> --json          # add --environment <env> for a remote host
```

   Take `startupTerminal.handle` from the result as the one handle for this
   lane. Do not create a second terminal for the same agent.

3. Wait for the TUI, then send the goal. A prompt typed into a starting TUI is
   lost:

```bash
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json
orca terminal send --terminal <handle> --text "<goal>" --enter --json
```

4. Index it, so it exists as far as every other verb is concerned:

```bash
jq -nc '{lane:"<X>", env:"<env>", handle:"<handle>", worktree:"<name>",
         branch:"<branch>", agent:"<kind>", goal:"<one line>", exclusive:[],
         status:"working", ctx_pct:"", last_seen:""}' \
  >> ~/.claude/orchestrator/<programme>/lanes.jsonl
```

   `agent` must match a profile in `agents.yaml`, since it decides how the lane
   is resumed and compacted. `branch` must be filled, since the merge gate and
   the retirement guard both read it.

5. Confirm it landed: `orchestrate.sh adopt <programme> --dry-run` should show
   the new lane reading `working`, not `unknown` or `dead`.

## Never

Creating a new repository, a new host or anything else outward is a structured
question first, even under full autonomy. See
`${CLAUDE_PLUGIN_ROOT}/references/never-do.md`.
