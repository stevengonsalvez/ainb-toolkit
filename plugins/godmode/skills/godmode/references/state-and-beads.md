# State, beads, and resume

## state.json schema

`.agents/scratch/<slug>-state.json` — small, flat, driver-owned. Update every
tick that changes anything.

```json
{
  "phase": "DISCOVER | FEASIBILITY_COURT | ROADMAP | HUMAN_GATE | E<N>_PLAN | E<N>_EXECUTE | E<N>_SHIP | DONE",
  "mode": "finite | perpetual",
  "approval_policy": "none | roadmap",
  "generation": 3,
  "phase_since": "2026-07-16T17:00:00Z",
  "current_epic": "e02-entity-resolution",
  "branch": "e02-entity-resolution",
  "running_task": "wq2xrhp74",
  "running_run_id": "wf_ffacbda8-86c",
  "driver_session_id": "<written as null at INIT; the PostToolUse hook backfills the driver's real session_id (first-writer-wins); gates the Stop hook>",
  "current_note": "one paragraph for the dashboard note slot",
  "human_gate": "none | pending | blessed | blessed_parallel_pairs",
  "epics": {"e00": "SHIPPED_PR2903", "e01": "SHIPPED_PR2904", "e02": "EXECUTING"},
  "termination": {"backlog_dry": false, "budget_tokens": null, "deadline": null,
                   "spent_tokens_estimate": 0, "reason": null},
  "lanes": {
    "mutation": {"owner": "e02-entity-resolution | repair-17 | null"},
    "regression": {"status": "idle | queued | running | passed | failed"},
    "discovery": {"status": "idle | queued | running | backoff", "next_at": null}
  },
  "creative_quorum": {"status": "ready | deferred", "models": ["claude:fable", "codex:rescue"],
                        "receipt": "path or URL"},
  "incidents": [{"id": "repair-17", "status": "confirmed | quarantined | resolved",
                 "evidence": "path or URL"}],
  "deployment": {"status": "idle | canary | healthy | rolled_back", "receipt": null},
  "dashboard_slug": "swift-epoch-fvds",
  "stop_counters": {"stage_errors": {}, "epic_validation_fails": {}}
}
```

Rules: strings not booleans for phases (grep-able); bump `stop_counters` and
check against STOP RULES before re-arming. `finite` may enable `backlog_dry`.
`perpetual` must set it false: an empty Court queues adaptive research instead
of completion. `programme_policy.py validate-state` runs from the state-write
hook and rejects impossible transitions without rewriting state.

The mutation lane has one owner only. Regression and discovery may run in
parallel. A confirmed incident replaces the current mutation owner until its
repair and cumulative verification finish. `creative_quorum.status: ready`
requires two distinct model identifiers and a receipt containing both views,
their disagreement, evidence, and synthesis.

### Token accounting (feeds --budget and the per-epic cap)

- Workflow task-notifications carry `<subagent_tokens>` in their `<usage>`
  block; Agent-tool notifications carry `total_tokens`. Add whichever the
  notification provides to `spent_tokens_estimate` on arrival.
- If a notification carries neither, read the workflow journal / TaskOutput
  for usage; if spend is still unmeasurable AND a `--budget` is set, treat the
  budget as VIOLATED and STOP (fail closed, never open).

## Beads

One bead per epic (`<slug>-ev<NN>`) and per feature where useful. Status flow:
open → in_progress → closed-with-evidence. Notes carry the proof trail
(commits, suite results, PR links) — a bead close note should let a stranger
audit the claim.

### Happy path (bd working)

Seed with `bd create --title=... --type=feature|task --priority=N` using the
`<slug>-e<NN>` id convention, `bd dep add` for ordering. Then ROUND-TRIP CHECK:
`bd show <id>` succeeds AND the row appears in `.beads/issues.jsonl`. If the
round-trip fails even once (bd printing success while persisting nothing is a
known failure mode), record `"beads_mode": "jsonl-plumbing"` in state.json and
use the plumbing path below for the rest of the programme.

### When the local bd DB is unreliable (known failure mode)

`bd create` can silently not persist against a stale/legacy DB while printing
success. The canonical write path is then **JSONL + git plumbing against
origin/main, no checkout touched**:

```bash
git fetch origin main
ORIGIN=$(git rev-parse origin/main)
git show origin/main:.beads/issues.jsonl > /tmp/b.jsonl
# edit /tmp/b.jsonl with python json.loads/dumps per line (NEVER sed/awk on JSON;
# a bad edit once blanked a line — validate 0 empty lines before pushing)
export GIT_INDEX_FILE=/tmp/bead-idx
git read-tree "$ORIGIN"
BLOB=$(git hash-object -w /tmp/b2.jsonl)
git update-index --cacheinfo 100644,"$BLOB",.beads/issues.jsonl
TREE=$(git write-tree)
C=$(git commit-tree "$TREE" -p "$ORIGIN" -m "chore(beads): <what>")
unset GIT_INDEX_FILE
git push origin "$C":main
```

`scripts/beads_remote.sh` wraps this (default branch `main`; set
`BEADS_BRANCH` for `master`/`trunk`). If the push is rejected because the
branch moved, re-fetch and replay — never force. If the branch is
push-PROTECTED, fall back to committing the beads change on the current epic
branch instead — it merges with the PR.

## Sidecar sync + lease (cross-machine)

The plugin hooks maintain a durable mirror on the dedicated ref
`refs/godmode/<slug>` (never a branch): `state.json` (durable subset),
`charter.md`, `lease.json`. One commit per sync, debounced to at most about
one heartbeat commit per tick. `GODMODE_SYNC=local` disables all remote sync
for single-machine programmes (zero push cost).

- Durable-subset rule: machine-local fields (`running_task`,
  `running_run_id`, `driver_session_id`) never sync; `sync.sh adopt` nulls
  them on reconstruction.
- Lease: `{holder, machine, heartbeat_ts, held_since}`; holder identity is
  `machine/user/SESSION-token`, so two sessions on one host contend like two
  machines. TTL `GODMODE_LEASE_TTL` (default 1800 s). CAS = push rejection,
  classified: protected/declined refs fail CLOSED (sync disabled, visibly),
  non-fast-forward means raced. Lease pushes NEVER blind-replay.
- Observer model: `/godmode status` reads the sync cache
  (`.agents/scratch/.godmode-sync/<slug>/`) and never creates scratch state,
  so observer machines cannot trigger mutating hooks. Only `/godmode run`
  (after claim or confirmed `--take-over`) runs `sync.sh adopt`.
- Fallback when the sync ref is unreachable: mirror the durable minimum
  (phase, epic map, dashboard slug, termination config) into the programme's
  root bead notes at phase transitions, as before.
- If a cleanup pass (e.g. a commit skill's scratch sweep) runs mid-programme,
  it MUST exempt `<slug>-charter.md`, `<slug>-state.json`, and the
  `.godmode-sync/` cache.

## Resume procedure (new session / post-crash / post-compaction)

0. Same machine: `sync.sh pull`. Another machine: `sync.sh discover`, then
   `/godmode run` (lease claim, then `sync.sh adopt <slug>`).
1. Read the charter, then state.json. These outrank any conversation summary.
2. `TaskList` / check the `running_task` output file: workflow still running →
   just re-enter the loop (re-arm ScheduleWakeup). Completed → process its
   result per the LOOP protocol. Vanished (session died mid-run) → resume it:
   `Workflow({scriptPath, resumeFromRunId})` — unchanged agents replay from
   cache; only in-flight work re-runs.
3. Cross-check git: does the epic branch exist, what commits landed? Commits
   are ground truth over state.json when they disagree (a stage may have
   finished writing but died before the driver persisted state).
4. Re-verify the dashboard is reachable and republish with a "resumed" note.
5. Continue the state machine.
