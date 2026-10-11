---
name: discover
description: List the Orca environments, hosts, worktrees and terminals a programme could use, and say which environments are unreachable. Use before adopting or spawning lanes, when a host may have restarted, when "what is running where" is unclear, or when a remote environment looks down. Asks Orca only, never ssh.
---

# discover

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh discover \
  --environment local --environment <remote-a> --environment <remote-b>
```

One TSV row per worktree: `env, ok|UNREACHABLE, worktree, orca-id`. An
environment Orca cannot answer for prints one `UNREACHABLE` row and the run
continues; the others are still listed.

## Reading it

| you see | it means |
|---|---|
| rows for an environment | Orca answered, those worktrees exist |
| one `UNREACHABLE` row | Orca could not answer. Report it and skip that host |
| a worktree you expected is missing | it was removed, or the environment name is wrong |

An empty terminal list does NOT mean a host is dead. That has happened while
lanes were alive, so discover deliberately reports worktrees, and `adopt` reads
each handle before believing anything about liveness.

## Never

Do not fall back to ssh or to a tailnet probe when an environment is
unreachable. That has raised a false outage. Orca is the only transport
(see `${CLAUDE_PLUGIN_ROOT}/references/never-do.md`).

## Next

`orchestrate:adopt` turns what you found into `lanes.jsonl`.
