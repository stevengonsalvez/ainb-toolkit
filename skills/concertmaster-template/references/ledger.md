# Ledger and outbox

The ledger is concertmaster's memory. It survives compaction, restarts and a
fresh session, so it is re-read at the start of every tick and is the source of
truth whenever it disagrees with what the session remembers.

```text
┌────────────────────────────┐   ┌────────────────────────────┐
│ $CM_HOME/          │   │ written by                 │
│   ledger.json              │◀──│ concertmaster only         │
│   roster.yaml              │◀──│ scripts/roster.sh each tick│
│   outbox.jsonl             │◀──│ mc-emit.sh (any process)   │
│   outbox.dead.jsonl        │◀──│ mc-emit.sh (4xx lines)     │
│   briefs/<worker>.md       │◀──│ concertmaster at spawn     │
│   salvage/<host>/...       │◀──│ teardown.sh --salvage      │
│   handovers/<worker>-*.md  │◀──│ stuck-rule respawn         │
│   cache/org-repos.json     │◀──│ discover.sh (24h cache)    │
│   config.yaml (optional)   │   │ hand-edited config         │
│   mc.env                   │   │ hand-edited telemetry cfg  │
│   bin/                     │   │ hook install (optional)    │
└────────────────────────────┘   └────────────────────────────┘
```

Host-local, outside git. The directory is `cfg.state_dir` (default
`~/.concertmaster`, written `$CM_HOME` below). Concertmaster runs on one host
(`cfg.hosts.home`); moving it means copying the directory whole.

## Write rules

- **EVERY ledger write goes through `cm_ledger_write`** (`scripts/lib.sh`). Never
  `jq ... > ledger.json`, `mv ... ledger.json`, `cp ... ledger.json` or an editor on the live
  file. The one sanctioned exception is the restore command below, run by an operator on a lost
  ledger. A new script or tick step that writes the ledger MUST call `cm_ledger_write`; do not
  copy the temp-file-and-`mv` pattern, which has no output check and no backup.
- One writer: the concertmaster session. Workers never touch it; they report
  through their Orca worktree comment.
- Times are UTC ISO-8601 without fractions: `2026-10-04T11:00:00Z`.
- Unknown is `null`, never an invented value.
- Missing file on boot means first boot (SKILL.md § First boot), but only when `ledger.bak/`
  holds no copies. A missing or empty ledger WITH backups was lost: restore it (below).

`cm_ledger_write [--init] <jq-filter> [jq args...]` runs the filter against the current
`$CM_HOME/ledger.json` and replaces the ledger with the result. It returns non-zero, leaves the
ledger untouched and says why on stderr when ANY of these fails:

| refusal | rule |
|---|---|
| not one object with `workers` | the output must pass `jq -e 'type=="object" and has("workers")'` and be a single document whose `workers` is an object: no output, a string, an array, several documents (a stray top-level `,`), no `workers` key, or `workers: null` is refused |
| shrunk | the output must be at least half the old file's bytes. A deliberate cut of more than half is done in steps, each at most halving, or by restoring a smaller copy |
| no old ledger | a missing or empty ledger is refused, never created. `--init` is the one way to create it (first boot): the filter runs with no input (`jq -n`) and builds the whole document. `--init` refuses when a non-empty ledger exists, and when `ledger.bak/` holds copies (the ledger was lost: restore it; `CM_LEDGER_INIT_FORCE=1` overrides, only on the owner's word), because a fresh history would push every good copy out of the ring |
| jq failed | a runtime or syntax error in the filter |
| lock busy | `ledger.json.lock` held by another writer for 5 seconds |
| no backup | the old file could not be copied into the ring |

On success the OLD file is first copied into the backup ring, then the new file (a temp file in
the same directory) is moved over with `mv`, so a reader sees the old or the new ledger, never
half of one, and a refusal leaves no temp file behind.

```bash
. "$SKILL/scripts/lib.sh"      # $SKILL = the concertmaster skill directory; CM_HOME comes from the config
cm_ledger_write '.workers[$id].state = "stuck" | .workers[$id].updatedAt = $now | .updatedAt = $now' \
  --arg id w-dev-101 --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  || echo "ledger NOT written (reason above): fix the filter, do not write the file by hand"
```

Under `set -e` a refusal stops the caller; add `|| ...` where the script goes on. A caller that
reads, plans and writes in one pass takes the lock first with `cm_ledger_lock` (release with
`cm_ledger_unlock`, e.g. in an EXIT trap); `cm_ledger_write` inside it re-enters the lock.

**Lock.** `ledger.json.lock`, a `mkdir` lock whose `pid` file holds the owner's token (not a bare
pid: `$$` is the same in every subshell). Re-entry is for the same shell (bash 4+; on bash 3.2 a
subshell counts as the holder): never run background writers while holding the lock. A lock older
than 2 minutes is stale: it is renamed away (`mv`, so only one waiter wins), then the take is
retried. A `mkdir` lock rather than `flock`: `flock` is absent on macOS (bash 3.2), and the lock
must exclude every writer on every host.

**Backup ring.** `$CM_HOME/ledger.bak/<UTC yyyymmddThhmmssZ>.json` (`~/.concertmaster/ledger.bak/`
by default), the OLD ledger as it stood before each write. A second write in the same second is
`<ts>_002.json`, so name order is write order; only timestamp-named files are pruned or picked, so a
copy you place there by hand is left alone. The newest 20 are kept (`CM_LEDGER_BAK_KEEP`), older
ones are deleted. The newest copy is the ledger before the last write. `CM_LEDGER` (a path) and
`CM_LEDGER_BAK` (a directory) override the ledger file and the ring location.

**Restore** (the ledger is empty, missing or damaged; copies the newest backup back):

```bash
cp "$(ls -1 "${CM_HOME:-$HOME/.concertmaster}"/ledger.bak/[0-9]*T*Z*.json | LC_ALL=C sort | tail -1)" "${CM_HOME:-$HOME/.concertmaster}/ledger.json"
```

To go further back, list the ring (`ls -1 ~/.concertmaster/ledger.bak/`) and `cp` an older file.
`cm_ledger_restore_hint` prints the same command for the paths in use; `cm_ledger_write` prints it
when it refuses on a lost ledger.

**Why (25 Oct 2026, 22:33Z).** A concertmaster jq filter produced no output, and the write guard
`jq -s 'length == 1' l.tmp >/dev/null` exits 0 even when it prints `false`, so an empty `l.tmp`
replaced `ledger.json`, with no copy of the old one to restore. The checks above read `jq -e` exit
codes, and the ring keeps a way back.

Test: `scripts/test/ledger-write.sh`.

## Schema: `ledger.json` (`concertmaster.ledger/v1`)

```json
{
  "schema": "concertmaster.ledger/v1",
  "createdAt": "2026-10-04T18:00:00Z",
  "updatedAt": "2026-10-04T18:15:00Z",
  "tick": { "count": 42, "lastAt": "2026-10-04T18:15:00Z", "nextWakeSeconds": 900 },

  "firstBoot": { "askedAt": "2026-10-04T18:02:00Z", "completedAt": "2026-10-04T18:05:00Z" },
  "killList": [
    { "id": "local:/home/dev/orca/workspaces/acme-app/fw-327", "host": "local",
      "path": "/home/dev/orca/workspaces/acme-app/fw-327", "class": "done-merged",
      "decision": "approved", "at": "2026-10-04T18:05:00Z" },
    { "id": "build-2:/home/dev/orca/workspaces/acme-app/pr-sweep", "host": "build-2",
      "path": "/home/dev/orca/workspaces/acme-app/pr-sweep", "class": "idle",
      "decision": "declined", "at": "2026-10-04T18:05:00Z" },
    { "id": "local:/home/dev/orca/workspaces/acme-app/load-fixtures", "host": "local",
      "path": "/home/dev/orca/workspaces/acme-app/load-fixtures", "class": "done-selfreported",
      "decision": "report-only", "at": "2026-10-04T18:05:00Z" }
  ],

  "hosts": {
    "local":          { "kind": "local", "selector": "", "reachable": true,
                        "lastSeenAt": "2026-10-04T18:15:00Z", "offlineSince": null,
                        "role": "general", "maxWorkers": 8 },
    "build-2": { "kind": "environment", "selector": "--environment build-2",
                        "hostname": "build-2", "reachable": true, "lastSeenAt": "2026-10-04T18:15:00Z",
                        "offlineSince": null, "role": "general", "maxWorkers": 6 },
    "laptop":         { "kind": "environment", "selector": "--environment laptop",
                        "reachable": false, "lastSeenAt": "2026-10-04T09:00:00Z",
                        "offlineSince": "2026-10-04T09:15:00Z", "role": "native", "maxWorkers": 2 }
  },

  "lanes": {
    "pr-sweeper":  { "state": "running", "lead": "w-pr-sweeper", "queue": [], "createdAt": "2026-10-04T18:06:00Z" },
    "dev-sweeper": { "state": "absent",  "lead": null,
                     "queue": [ { "ref": "issue#101", "title": "calendar export", "addedAt": "2026-10-04T18:10:00Z" } ] },
    "epic:frameworks": { "state": "running", "lead": "w-epic-frameworks", "goalFile": ".agents/goals/frameworks.md", "queue": [] }
  },

  "workers": {
    "w-dev-101": {
      "host": "build-2",
      "worktreeId": "c820e481-...::/home/dev/orca/workspaces/acme-app/dev-101-calendar-export",
      "path": "/home/dev/orca/workspaces/acme-app/dev-101-calendar-export",
      "terminal": "term_abc123",
      "agent": "claude",
      "lane": "dev-sweeper",
      "task": "issue #101 calendar export",
      "state": "running",
      "nudges": 0,
      "lastNudgeAt": null,
      "lastOutputAt": "2026-10-04T18:14:10Z",
      "lastComment": "cm:running plan written, implementing",
      "spawnedAt": "2026-10-04T18:11:00Z",
      "updatedAt": "2026-10-04T18:15:00Z",
      "pr": null,
      "briefFile": "$CM_HOME/briefs/w-dev-101.md",
      "handoverFile": null,
      "blockedQuestion": null,
      "adopted": false
    }
  },

  "prs": {
    "acme-app#341": {
      "repo": "AcmeOrg/acme-app", "number": 341, "title": "load people",
      "author": "alex", "state": "OPEN", "headSha": "abc123...",
      "driver": "w-pr-sweeper",
      "gate": { "rts": "NEEDS_WORK", "reviewVerdict": null, "ciGate": "pending",
                "reviewRounds": 1, "checkedAt": "2026-10-04T18:15:00Z" },
      "mergedAt": null, "mergeSha": null, "deployWindow": null, "authorNotifiedAt": null
    }
  },

  "deployWindows": [
    { "id": "2026-10-04T11:00", "at": "2026-10-04T10:00:00Z",
      "state": "done", "prs": [344, 345], "fromTag": "v1.4.56", "tag": "v1.4.57",
      "worker": "w-deploy-20261004-1100", "stagingRunId": 123, "stagingValidated": true,
      "prodRunId": 456, "blockedReason": null, "finishedAt": "2026-10-04T10:41:00Z" }
  ],

  "asks": [
    { "id": "ask-7", "askedAt": "2026-10-04T18:02:00Z", "topic": "kill list",
      "question": "Approve 18 teardowns?", "state": "answered", "answer": "approve all" },
    { "id": "ask-12", "askedAt": "2026-10-10T09:00:00Z", "topic": "remove standing lane",
      "kind": "remove-standing", "host": "local",
      "path": "/home/dev/orca/workspaces/acme-app/research-demos-2",
      "worker": "w-demo-sweeper",
      "question": "Remove the demo-sweeper lane?", "state": "answered",
      "answer": "yes, remove it", "decision": "approved", "usedAt": null }
  ],

  "digests": { "lastSentAt": "2026-10-04T17:00:00Z", "lastCollaboratorDmAt": {} }
}
```

## Field reference

| path | meaning |
|---|---|
| `tick.nextWakeSeconds` | the ScheduleWakeup delay chosen at the end of the last tick (600 to 1800) |
| `firstBoot.completedAt` | set after the kill list is answered and acted on; autonomous teardown of merged work starts after it |
| `killList[]` | one entry per first-boot candidate, `id` = `<host>:<path>`; `decision` is `approved` (retire + teardown), `declined` (never touched, never re-asked) or `report-only` (reported, never acted on); honoured on every later tick |
| `hosts.<name>.reachable` | from the last discover; `offlineSince` set on the first unreachable tick |
| `hosts.<name>.hostname` | `hostname -s` the host answers over ssh; teardown.sh refuses a remote host that answers otherwise (seeded from `cfg.hosts.per_host.<name>.hostname`) |
| `hosts.<name>.role` | `general`, `native` (native builds), `overflow`; seeded from `cfg.hosts` |
| `hosts.<name>.maxWorkers` | live-worker cap for that host; seeded from `cfg.hosts`, read every tick |
| `lanes.<lane>.state` | `absent`, `spawning`, `running`, `idle` (queue empty, lead kept: lanes are standing and never torn down), `draining` (legacy: treat as `idle`), `gone` |
| `lanes.<lane>.queue` | items handed by the owner not yet given to a worker |
| `workers.<id>.state` | `queued`, `spawning`, `running`, `stuck`, `blocked-on-owner`, `done`, `retired` (agent terminal closed, worktree kept), `teardown`, `gone` (only when its host was reached and the row is absent) |
| `workers.<id>.terminal` | the ONE agent handle (`agentTerminalHandle` or `startupTerminal.handle`); refreshed after an Orca restart |
| `workers.<id>.agent` | `claude`, `codex` or `agy`. Unset (some adopted lanes): `resume` never starts claude there, the row is `manual` |
| `workers.<id>.model` | optional model name for the roster (`sonnet`, `opus`, ...), or null; set at spawn when known |
| `workers.<id>.current` | optional one-line item the worker is on, for the roster and the resume nudge; falls back to `task` |
| `workers.<id>.nudges` | count since the last real progress; reset to 0 when output resumes |
| `workers.<id>.lastOutputAt` | from Orca `lastOutputAt` (null on some remote rows: fall back to agent `updatedAt`) |
| `workers.<id>.lastComment` | the worker's Orca comment, `cm:<state> <detail>` (lanes.md § Reporting) |
| `workers.<id>.adopted` | true for sessions found at first boot rather than spawned |
| `workers.<id>.standing` | true for sweepers and lane leads, false for single-task workers; set at spawn and at adoption. The ONLY source of standing for `teardown.sh` and `classify.sh` (names never decide): true or being a `lanes.<lane>.lead` refuses teardown and retire, false allows, null or missing refuses as "standing state unknown". Removal of a standing lane needs a `remove-standing` ask (§ asks) |
| `workers.<id>.beadsEpic` | beads epic id (string) the worker owns, e.g. `acme-epic1`, or null; set at spawn, adoption, or when a lane takes an epic. Any other type refuses teardown. Not done, and `teardown.sh` refuses, while any child bead (dotted `<epic>.N` or `parent-child` linked, recursively) is not closed or tombstoned |
| `workers.<id>.state` `gone` / `repurposed` | dead records: ignored when matching a worktree, so an old record on a reused path never decides standing or beads |
| `prs.<repo>#<n>.driver` | worker id currently pushing to the PR; at most one |
| `prs.<repo>#<n>.gate` | last merge-gate reading, each part bound to `headSha` |
| `prs.<repo>#<n>.authorNotifiedAt` | last PR comment to a collaborator (`cfg.messaging.collaborators`) |
| `deployWindows[].state` | `pending`, `rails-check`, `staging`, `validating`, `prod`, `done`, `skipped` (nothing to ship), `stopped` (a rail or red staging) |
| `asks[]` | every AskUserQuestion: open ones are "needs <owner>" in the digest |
| `asks[].kind` | set only for asks that unlock a teardown override: `remove-standing` (`--force-standing`) or `accept-unmerged-beads` (`--accept-unmerged-beads`). Such an ask also carries `host`, `path` (canonical) and/or `worker` naming exactly one worktree, `decision` (`approved` or `declined`, from the owner's answer) and `usedAt` (set by concertmaster after the `--apply` that used it; a used ask never unlocks again). `teardown.sh` accepts it only when `state` is `answered`, `decision` is `approved`, `usedAt` is null, and host + path/worker match the worktree. Any other answered ask unlocks nothing |
| `digests.lastCollaboratorDmAt` | map of collaborator github handle to last daily DM time |
| `digests.lastSentAt` | last digest send (`cfg.schedule.digest_times`) |

## `outbox.jsonl`

One JSON object per line, appended by `scripts/mc-emit.sh` from any process
(concertmaster ticks, teardown, worker hooks on this host). A line is removed
only after the telemetry sink (`cfg.telemetry.base_url`) answers 2xx; with no
base URL or no tenant configured lines stay queued (capped). Capped at 5000 lines, oldest dropped.

```json
{"endpoint":"/api/events","body":{"tenantId":"<cfg.telemetry.tenant_id>","type":"pr.merged","message":"#341 merged","metadata":{"source":"concertmaster","host":"host-1","pr":341},"timestamp":1791150228000},"queuedAt":1791150228000}
{"endpoint":"/api/fleet/upsert","body":{"tenantId":"<cfg.telemetry.tenant_id>","agentId":"host-1:9f1c...","name":"acme-app/dev-101","status":"active","currentTask":"issue #319","workspace":"/home/dev/orca/workspaces/acme-app/dev-319","hiddenFromUI":false},"queuedAt":1791150229000}
```

| field | meaning |
|---|---|
| `endpoint` | `/api/events` or `/api/fleet/upsert`, appended to `MC_BASE_URL` |
| `body` | the exact POST body |
| `queuedAt` | epoch ms when queued |

A flush sends at most 10 lines in at most 30s. 401, 403, 408, 429, 5xx and
network failures keep the line queued; any other 4xx moves it to
`outbox.dead.jsonl` with a `deadCode`, since it can never succeed. So does a
403 on `/api/fleet/upsert` (`deadCode` 403): the sink refuses that route to
project-bound and shared tokens every time. So does a 403 on an event naming a
`projectId` other than the configured one (the id changed while it was queued). With a project id
(`cfg.telemetry.project_id`, `MC_PROJECT_ID`) every `/api/events` body carries
`projectId` (filled in on send for lines queued before it, never rewritten when
present, never `null`) and `--fleet-upsert` queues nothing; the latest skip is
in `fleet.skipped` (`{"at","agentId","reason"}`), written even when quiet. With no
tenant (`cfg.telemetry.tenant_id`, `MC_TENANT_ID`) a flush sends nothing (a sink
typically answers 400 to `tenantId: null`) and lines stay queued, still under the
cap: over 5000 the outbox is trimmed to 4500, oldest first, and each trim is a
line in `outbox.dropped` (`{"at","dropped","cap"}`, newest 200 kept), even when
quiet. Every append and outbox rewrite takes the short write lock
`outbox.wlock`. A line queued before the tenant was set gets it filled in when
sent. `mc-emit.sh --requeue-dead` puts dead lines with `deadCode` 400 and
`body.tenantId` null back in FRONT of the outbox, oldest first, with the tenant
set (with a project id it also takes 400 lines that carry a tenant but no
`projectId`; events get the project id and, when they have none, an `eventId`
`rq-<sha256 of body minus tenantId and projectId, then queuedAt>`, so
requeueing the same line twice is deduped by the sink, and with no `sha256sum`
or `shasum` they go without one after a warning; a line naming another
project, or a fleet upsert while a project id is set, stays dead), after a timestamped backup of the dead file (newest 5 kept). A fleet upsert
with a newer upsert for the same agentId (requeued or queued) is dropped.
`fleet.sent.json` (`{"<agentId>": <queuedAt>}`) records the newest upsert the
sink accepted per agent; neither a flush nor a requeue sends an older one, and
lines a flush could not send go back in front of the outbox, so a backlog never
overwrites newer fleet state. Requeue refuses when the result would pass the
cap: drain first with `MC_FLUSH_BATCH=500 MC_FLUSH_SECS=300 mc-emit.sh --flush`
(under the 10-minute lock steal), repeated while the outbox shrinks (it stops on
401, 403, 408 and 429). `--any-tenant` also takes 400 lines that carried a wrong
tenant. The dead file keeps its newest 5000 lines. Any other dead line: read it
when the sink's contract changes, requeue by hand.

Event `type` vocabulary: `concertmaster.tick` (`--tick`) and `issue.state`
(`--issue-state`), both PROVISIONAL until your sink's contract is fixed (set
`TYPE_TICK` and `TYPE_ISSUE_STATE` in `scripts/mc-emit.sh`), `tick` (older ticks), `worker.spawned`, `worker.stuck`,
`worker.nudged`, `worker.respawned`, `worker.done`, `worktree.teardown`,
`pr.merged`, `deploy.started`, `deploy.staging`, `deploy.prod`, `deploy.stopped`,
`ask.opened`, `ask.answered`, `host.offline`, `host.online`, and from hooks
`session.start`, `session.stop`, `session.notification`.

Fleet `status`: `active`, `idle`, `error`.
