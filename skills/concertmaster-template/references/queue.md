# Work queue

New work waits in the ledger (`.queue`) for a free slot instead of spawning past capacity. The
concertmaster adds items, grants them in order each tick, and hands each granted item to its lane in
the same tick. `scripts/queue.sh` is the deterministic half.

```text
owner hands issue ─▶ queue.sh add ─▶ queued ─▶ queue.sh grant ─▶ granted ─▶ lane starts it ─▶ mark done
                                         ▲                          │ hand-off failed
                                         └────── mark <id> queued ──┘
```

## Rules

- Order: `P0` (security or prod) first, then `urgent`, then oldest `addedAt`.
- `add <issue> <lane> [--priority P0|urgent|normal] [--host <name>]` prints `queued, position N`; an
  item already queued for the same issue and lane is not added twice.
- `grant (--discover <file> | --live <host>=<n>,...) [--dry-run]` counts live agent sessions per host
  (agent panes in a live terminal under `worktrees.path_match`, from a `discover.sh` document, or
  given with `--live`), then grants the top item whose host has a free slot while the total is under
  the cap, and repeats until a cap is hit. An item with no host goes to the reachable `general` host
  with the most free slots; `native` hosts are never picked automatically.
- Caps: total = `queue.cap` (config), else ledger `.queue.cap`; per host = `hosts.per_host.<h>.maxWorkers`,
  else ledger `hosts.<h>.maxWorkers`, else `hosts.defaults.maxWorkers`. No total cap anywhere: nothing
  is granted (exit 2).
- An item granted within `queue.grant_hold_minutes` (default 30) counts as live on its host (shown
  `+n`), so a slow spawn is never granted twice. A hand-off that failed goes back with
  `mark <id> queued`; it keeps its `addedAt`.
- A host that is unreachable or truncated in the discover document counts as full (shown `?`). A
  configured host missing from the census counts 0 and gets no grant (`-`).
- `list [--json]` and `depth` read only.

## Requirement

`add`, `mark` and a real `grant` write the ledger through `cm_ledger_write`, `cm_ledger_lock` and
`cm_ledger_unlock` from `scripts/lib.sh` (the guarded ledger writer, `references/ledger.md`). A
`lib.sh` without them makes those commands refuse with a message and exit 1. Tests:
`scripts/test/queue.sh`.
