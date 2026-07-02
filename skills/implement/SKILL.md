---
name: implement
description: Execute an approved implementation plan from plans/ step-by-step — phase-by-phase code changes, run success criteria, check off boxes, handle checkpoints and parallel waves
user-invocable: true
---

# Implement Plan

Execute an approved technical plan from `plans/`. Plans contain phases; each phase has "Changes Required" and "Success Criteria".

## When NOT to use
- No plan exists yet → run `/plan` (or `/plan-tdd` for TDD) first.
- User wants to verify a finished implementation against spec → `/validate`.
- User wants the full plan→implement→validate loop orchestrated → `/workflow`.

## Step 0: Prior-art check (recommended, non-blocking)

<!-- recall:begin -->
Run before implementing so you don't re-decide something already captured:

```bash
uv run "{{HOME_TOOL_DIR}}/skills/recall/scripts/recall.py" \
  "<QUERY>" --limit 5 --format markdown
```

- `<QUERY>` = current phase name + touched module names, e.g. `"auth middleware session token storage"`.
- Skip if the calling `/plan` already ran recall.
- Result routing:
  | Result | Action |
  |--------|--------|
  | Learning names a constraint/anti-pattern/prior decision relevant to this task | Surface to user BEFORE proceeding |
  | Nothing relevant | Proceed silently, don't mention it |
  | Empty output / non-zero exit | Treat as "no prior art" — never block, never call it an error |
<!-- recall:end -->

## Step 1: Load the plan

1. If no plan path given → ask for one. Stop until provided.
2. Read the plan file completely. Note existing `- [x]` checkmarks (already-done work).
3. Read the original requirements and every file the plan mentions — **fully, no limit/offset**. You need complete context.
4. Create a TodoWrite list, one item per phase.

## Step 2: Detect execution mode

Scan all `## Phase` sections for `<!-- wave:` comments.
- Any `<!-- wave:` comment present → **Wave Mode** (Step 3W).
- None → **Sequential Mode** (Step 3S).

## Step 3W: Wave Mode

Execute phases grouped by wave number, waves in ascending order.

| Wave shape | How to run |
|------------|-----------|
| Single phase in wave | Execute inline (same as sequential — avoids spawn overhead) |
| Multiple phases in wave | Spawn one parallel Task agent per phase |

Spawn each multi-phase agent with:
```
Task(
  subagent_type: "general-purpose",
  prompt: "Implement Phase {N}: {title}

  Plan: {plan_path}
  Phase: {N} only

  Read the plan and implement ONLY Phase {N}.
  Follow Changes Required exactly. Run Success Criteria checks.
  Update plan checkboxes when done.
  Files you own (ONLY modify these): {files from wave comment}
  Report: what was implemented, tests passing, any deviations."
)
```

Rules:
1. Wait for ALL agents in a wave before starting the next wave.
2. After each wave, run `git diff --name-only` and confirm no two phases touched the same file (ownership conflict). If they did → report and stop.
3. If any phase fails, stop and present:
   ```
   Wave {N}: Succeeded: Phase {X}, {Y}. Failed: Phase {Z} — {reason}
   Options: 1) Retry failed phase only  2) Continue to next wave (skip failed)  3) Fall back to sequential for remaining
   ```
   Wait for the user's choice.

## Step 3S: Sequential Mode

For each phase, in order, do NOT start the next until the current is fully done:

1. **Understand** — read phase overview, success criteria, files touched, inter-change dependencies.
2. **Implement** — make the changes. Follow existing code style/conventions. Add needed imports. Keep changes consistent across files.
3. **Verify** — run the phase's automated success-criteria checks. Fix failures before moving on. Never let errors accumulate. Batch verification at natural stopping points, not mid-edit.
4. **Update progress** — check off `- [x]` items in the plan file with Edit; update TodoWrite; note any deviation.
5. **Update project state** (only if `.planning/` dir exists):
   - `.planning/STATE.md` ← phase progress
   - `.planning/phases/{phase}/SUMMARY.md` ← deviations (if file exists)
   - `.planning/REQUIREMENTS.md` ← mark completed requirements

## Checkpoints

**Automation-first rule**: before honoring any checkpoint, confirm you truly cannot do the action yourself via CLI/API/file ops. Checkpoints verify after automation — they never replace it.

| Marker in plan | Do this |
|----------------|---------|
| `[CHECKPOINT:human-verify]` | Present what was built + how to verify → wait for approval. "approved" → next phase. Issues → fix and re-present. |
| `[CHECKPOINT:decision]` | Present options + trade-offs from the plan → wait for choice → record the decision in the plan file → continue on chosen path. |
| `[CHECKPOINT:human-action]` | State exactly what the user must do → wait for "done" → verify it took effect if possible → continue. |

## Testing

Follow the plan's testing strategy: unit tests for new code, update tests affected by changes, run integration tests for end-to-end behavior, document any manual testing.

## When reality doesn't match the plan

| Situation | Do this |
|-----------|---------|
| Plan step can't be followed as written | STOP. Present the block (below). Wait for guidance. |
| Codebase evolved since plan was written | Document the differences, propose adaptations preserving intent, get confirmation before major changes. |
| Something you built doesn't work | Re-read the plan section, check for a missed dependency, add logging, read error messages. Still stuck → document expected vs actual + what you tried, ask for specific guidance. |

Mismatch block format:
```
Issue in Phase [N]:
Expected: [what the plan says]
Found: [actual situation]
Why this matters: [explanation]
How should I proceed?
```

## Resuming a partially-done plan

Plan has existing `- [x]` marks → trust completed work is done, pick up from the first unchecked item. Only re-verify prior work if something looks off.

## Completion checklist

Do not call implementation complete until all are true:
- [ ] All phases implemented
- [ ] All automated tests passing
- [ ] Manual verification completed
- [ ] Plan document updated with all checkmarks
- [ ] Deviations documented
- [ ] Code follows project conventions
- [ ] No unresolved TODO comments left
- [ ] Performance considerations addressed
