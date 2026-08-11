# godmode plugin

The autonomous product factory, packaged as the first plugin of the
ainb-toolkit in-repo marketplace. Three things the plugin adds over the old
bootstrap-synced skill: hooks OWN the status surface (unskippable), run state
syncs across machines on a dedicated git ref, and a single-driver lease stops
two sessions driving one programme.

## Install

All three CLIs read the marketplace at the repo root and install godmode from
`plugins/godmode/` (verified end-to-end 2026-07-18: skill + hooks land in each
CLI's plugin cache).

| Provider | Command |
|---|---|
| Claude Code | `claude plugin marketplace add stevengonsalvez/ainb-toolkit && claude plugin install godmode@ainb-toolkit` |
| Codex | `codex plugin marketplace add stevengonsalvez/ainb-toolkit && codex plugin add godmode@ainb-toolkit` (reads the same `.claude-plugin/marketplace.json`; shares `hooks/hooks.json` by convention) |
| Copilot CLI | `copilot plugin marketplace add stevengonsalvez/ainb-toolkit && copilot plugin install godmode@ainb-toolkit` (reads `.github/plugin/marketplace.json`; uses `hooks/copilot-hooks.json`) |

Each `marketplace add` also accepts a local path instead of `owner/repo` for
testing an unmerged checkout. Driving requires provider capability: Claude uses
its native scheduler, Codex uses native automation, and Copilot requires a
configured external scheduler adapter. Missing capability defers driving with a
visible status receipt, never a false claim of autonomous execution.

## Prerequisites (per machine)

- `git`, `jq`, `python3`, `bd` (beads)
- Publishing: `~/.claude/skills/here-now/` and `~/.claude/skills/explain-to-me/`
  (bootstrap-synced sibling skills) and `~/.herenow/credentials` (0600).
  Missing pieces DEGRADE VISIBLY: `/godmode status` preflight prints
  "status publishing DISABLED: missing <X>"; the pipeline writes a pending
  marker and the dashboard shows a staleness banner.
- After merging a change that migrates a skill to a plugin, run
  `node bootstrap.js` once per machine: pristine stale copies of
  `~/.claude/skills/godmode` are removed, locally edited ones are preserved at
  `~/.claude/skills/.godmode.pre-plugin-backup-<date>/` (reconcile via
  /sync-learnings v2, then delete the backup).

## Hook inventory

| Event | Script | Does |
|---|---|---|
| SessionStart (startup/resume/compact) | `sync.sh pull` | refresh sidecar cache; inert (<50 ms) without a local programme |
| PostToolUse (Write\|Edit) | `on-state-write.sh` | validate state, render dashboard, publish, sidecar push; pending marker on failure; exit 2 on invalid state or lease loss |
| Stop | `explainer-gate.sh` | block the DRIVER session when a transition phase lacks its explainer receipt (subagents/bystanders exempt; fail-open on infra errors) |
| Stop | `sync.sh push --if-active` | heartbeat backstop (quiet ticks, Bash-written state) |
| PreCompact | `sync.sh push --if-active` | pre-compaction insurance push |

## Sidecar + lease

```
origin
└─ refs/godmode/<slug>          ← dedicated ref, never a branch
   └─ one commit per sync: state.json (durable subset) + charter.md + lease.json

[unclaimed] ──run──▶ [held: machine/user/session]
                        │ heartbeat rides each sync commit (debounced)
                        ▼
        heartbeat older than GODMODE_LEASE_TTL (1800 s)?
          │ yes: other machine auto-claims       │ no: claim refused
          ▼                                      ▼
       [held: B]                    run --take-over: confirm, claim, adopt
```

- CAS = push rejection, classified: protected/declined refs fail CLOSED
  ("cross-machine sync disabled", exit 6); non-fast-forward = raced (exit 3).
  Lease pushes never blind-replay.
- Observers are structurally read-only: `/godmode status` reads the sync cache
  and never creates scratch state, so observer machines cannot push.
- `GODMODE_SYNC=local` disables all remote sync (single-machine mode: zero
  push cost, everything else works).

## Machine-B runbook

```bash
/godmode status            # discover programmes (git ls-remote refs/godmode/*),
                           # report state + lease holder; read-only
/godmode run               # auto-claims only if the lease is STALE
/godmode run --take-over   # confirm, force-claim, sync.sh adopt <slug>
```

## Version policy (observed, not assumed)

`claude plugin update` compares VERSIONS: same version = "already at latest",
content is NOT delivered (observed 2026-07-16 on Claude Code 2.1.211); a patch
bump delivers a fresh cache dir. Therefore: ANY change under
`plugins/godmode/**` bumps at least the patch version, and all three provider
manifests (`plugins/godmode/.claude-plugin/`, `plugins/godmode/.codex-plugin/`,
`.github/plugin/`) carry the SAME version (bats-enforced:
`tests/plugin/manifests.bats`).

## Troubleshooting

| Symptom | Meaning | Fix |
|---|---|---|
| `<slug>-publish.pending` exists / dashboard banner | publish or sync infra failing | fix creds/network; next state write retries and clears it |
| `<slug>-lease-lost` marker / exit-2 hook message | another session took the lease | post handoff note, stop re-arming; `--take-over` to reclaim |
| "cross-machine sync disabled" | remote rejects `refs/godmode/*` | unprotect the ref namespace or run `GODMODE_SYNC=local` |
| `.godmode.pre-plugin-backup-<date>/` in skills dir | migration found local edits | port edits into `plugins/godmode/`, push, delete backup |
| stop blocked with "shipped without its explainer" | phase flipped, no receipt | publish via `${CLAUDE_PLUGIN_ROOT}/scripts/explainer-publish.sh` (writes the receipt) |

## Tests

```bash
npm run test:plugin        # bats: render/sidecar/lease/gate/manifests
npm run test:plugin:e2e    # sandbox-HOME marketplace install, drives installed hooks
```

The suite is mutation-checked: every rule worth having has a test that dies
when the rule is deleted. `gate.bats` carries a negative control (a do-nothing
gate must fail the suite) because `jq -e` returns 0 on empty input, which once
made all nine gate tests pass against a stub.
# Perpetual mode

Godmode 0.3.0 adds charter-selected perpetual evolution. It never terminates
because a backlog is empty. It re-enters creative, evidence-gated discovery
with adaptive backoff, then creates the next goal generation. Creative stages
require two independent models, preserve disagreement, and defer when no
quorum is available. Every shipped epic queues cumulative regression; a
confirmed defect preempts mutation until repaired and fully re-verified.

Provider driving is capability-gated: Claude needs its native scheduler, Codex
needs native automation, and Copilot needs a configured external scheduler.
Missing capability is visible deferment, never claimed autonomy.
