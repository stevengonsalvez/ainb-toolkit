---
name: status
description: Print a programme's lanes, owner, host pressure, PR ownership, owed notices and last tick, from the index files alone with no Orca or network calls. Use for a standup, to see what is running without disturbing it, to check who owns the lock, or when a tick is too expensive or the hosts are unreachable.
---

# status

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh status <programme>
```

Reads files only. It touches no host, sends nothing, creates nothing and writes
nothing at all, not even an event, so it is safe while another session owns the
programme. The same holds for `discover`, `read`, `owed` and
`adopt --dry-run`.

| section | source | read it for |
|---|---|---|
| `lanes` | `lanes.jsonl` | what was true at the last tick, not what is true now |
| `owner` | `owner.json` | who holds the lock, and how long ago they ticked |
| `hosts` | `hosts.jsonl` | last disk reading per host, and which rung answered |
| `prs seen` | `events.jsonl` | which lane owns which PR |
| `owed` | `events.jsonl` plus `gh` | merged or closed PRs whose lane was never told |
| `last tick` | `events.jsonl` | the counters and the gap at that tick |

`owed` is the one section that calls out, to ask GitHub for each PR's state.

## Judgment

`status` shows the last tick's view. A `last tick` timestamp older than twice
the cadence means the numbers are stale: the lanes may have moved on, a host may
have restarted, and handles may no longer resolve. Run `orchestrate:tick` (or
`orchestrate:takeover` if the lock is someone else's and stale) before acting on
anything it printed.
