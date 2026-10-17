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

- One writer: the concertmaster session. Workers never touch it; they report
  through their Orca worktree comment.
- Atomic: write a temp file in the same directory, then `mv` it over.
- Times are UTC ISO-8601 without fractions: `2026-10-04T11:00:00Z`.
- Unknown is `null`, never an invented value.
- Missing file on boot means first boot (SKILL.md § First boot).

```bash
L=$CM_HOME/ledger.json
jq --arg id w-dev-101 --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.workers[$id].state = "stuck" | .workers[$id].updatedAt = $now | .updatedAt = $now' \
  "$L" > "$L.tmp" && mv "$L.tmp" "$L"
```

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
| `workers.<id>.beadsEpic` | beads epic id (string) the worker owns, e.g. `acme-ldm1`, or null; set at spawn, adoption, or when a lane takes an epic. Any other type refuses teardown. Not done, and `teardown.sh` refuses, while any child bead (dotted `<epic>.N` or `parent-child` linked, recursively) is not closed or tombstoned |
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
`outbox.dead.jsonl` with a `deadCode`, since it can never succeed. With no
tenant (`cfg.telemetry.tenant_id`, `MC_TENANT_ID`) a flush sends nothing (a sink
typically answers 400 to `tenantId: null`) and lines stay queued, still under the
cap: over 5000 the outbox is trimmed to 4500, oldest first, and each trim is a
line in `outbox.dropped` (`{"at","dropped","cap"}`, newest 200 kept), even when
quiet. Every append and outbox rewrite takes the short write lock
`outbox.wlock`. A line queued before the tenant was set gets it filled in when
sent. `mc-emit.sh --requeue-dead` puts dead lines with `deadCode` 400 and
`body.tenantId` null back in FRONT of the outbox, oldest first, with the tenant
set, after a timestamped backup of the dead file (newest 5 kept). A fleet upsert
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
