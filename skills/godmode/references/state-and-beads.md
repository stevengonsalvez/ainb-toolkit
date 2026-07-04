# State, beads, and resume

## state.json schema

`.agents/scratch/<slug>-state.json` — small, flat, driver-owned. Update every
tick that changes anything.

```json
{
  "phase": "DISCOVER | FEASIBILITY_COURT | ROADMAP | HUMAN_GATE | E<N>_PLAN | E<N>_EXECUTE | E<N>_SHIP | DONE",
  "current_epic": "e02-entity-resolution",
  "branch": "e02-entity-resolution",
  "running_task": "wq2xrhp74",
  "running_run_id": "wf_ffacbda8-86c",
  "human_gate": "pending | blessed | blessed_parallel_pairs",
  "epics": {"e00": "SHIPPED_PR2903", "e01": "SHIPPED_PR2904", "e02": "EXECUTING"},
  "termination": {"backlog_dry": true, "budget_tokens": null, "deadline": null,
                   "spent_tokens_estimate": 0},
  "dashboard_slug": "swift-epoch-fvds",
  "stop_counters": {"stage_errors": {}, "epic_validation_fails": {}}
}
```

Rules: strings not booleans for phases (grep-able); bump `stop_counters` and
check against STOP RULES before re-arming. Termination bounds are
INDEPENDENT toggles — any subset may be set; the first enabled bound to fire
terminates the programme.

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

## Durability caveats

Charter + state.json typically live in gitignored dirs (`.agents/goals/`,
`.agents/scratch/`) — they survive session death but NOT worktree deletion or
another machine. Therefore: (a) resume assumes the SAME worktree; (b) mirror
the durable minimum (phase, epic→status map, dashboard slug, termination
config) into the programme's root bead notes at each phase transition, so a
cross-machine resume can reconstruct; (c) if a cleanup pass (e.g. a commit
skill's scratch sweep) runs mid-programme, it MUST exempt
`<slug>-charter.md` and `<slug>-state.json`.

## Resume procedure (new session / post-crash / post-compaction)

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
