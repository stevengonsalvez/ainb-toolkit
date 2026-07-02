---
name: plan
description: Create a detailed implementation plan
user-invocable: true
---

# Create Plan

Produce a phased, file-level implementation plan through interactive research and iteration. Be skeptical: verify every requirement against actual code before writing it into the plan. Output is a `plans/*.md` file that `/implement` consumes directly.

**When NOT to use / route elsewhere:**
- Requirements still fuzzy, no clear task yet → run `/interview` first, then return here.
- No codebase understanding yet, need to explore what exists → run `/research` first (it searches learnings + codebase); its output feeds Step 1 here.
- Test-first workflow wanted → use `/plan-tdd` instead.

<!-- recall:begin -->

## Step 0: Prior-art check (MANDATORY, run first)

Recall prior learnings so you don't re-decide something already captured:

```bash
uv run "{{HOME_TOOL_DIR}}/skills/recall/scripts/recall.py" \
  "<QUERY>" \
  --limit 5 --format markdown
```

- `<QUERY>` = user task description + any file paths + domain keywords (e.g. `"user auth OAuth migration"`).
- Result names a constraint / anti-pattern / prior decision relevant to the task → surface it to the user BEFORE the main flow.
- Empty output or non-zero exit → treat as "no prior art", proceed silently. Never block on recall failure.

<!-- recall:end -->

## Step 1: Intake

1. Parameters (file path or task description) provided → skip the greeting, read provided files FULLY (Read tool, no `limit`/`offset`), go to Step 2.
2. No parameters → print exactly this, then wait:

```
I'll help you create a detailed implementation plan. Let me start by understanding what we're building.

Please provide:
1. The task/requirement description
2. Any relevant context, constraints, or specific requirements
3. Links to related research or previous implementations

I can also check for existing research documents if you've already run /research on this topic.
```

## Step 2: Context gathering

Do these in order. Read every file FULLY before spawning any sub-task.

| Source | Action |
|--------|--------|
| `research/` dir | Relevant file exists → read it as the plan's foundation. None → run `/research`, then continue. |
| `.planning/ROADMAP.md` | Exists → read; use its phases as the plan's phase structure. |
| `.planning/STATE.md` | Exists → read current position + blockers. |
| `.planning/**/CONTEXT.md` | Exists → read locked decisions; **the plan MUST honor these**. |
| Any file the user mentioned | Read FULLY yourself before delegating. |

Then spawn **general-purpose** sub-agents in parallel (one message, multiple Task calls) to: (a) find all files related to the task, (b) map the current implementation, (c) find existing docs. Each returns explanations with `file:line` references. Wait for all, then read every file they identified FULLY.

Cross-reference requirements against the real code. Note discrepancies and assumptions needing verification.

Present understanding + only the questions research could not answer:

```
Based on my research of the codebase, I understand we need to [accurate summary].

I've found that:
- [Current implementation detail with file:line reference]
- [Relevant pattern or constraint discovered]
- [Potential complexity or edge case identified]

Questions that my research couldn't answer:
- [Specific technical question requiring human judgment]
- [Business logic clarification]
```

## Step 3: Deep research & design options

- User corrects a misunderstanding → do NOT just accept it. Spawn a new research task / read the named files, verify the fact yourself, THEN proceed.
- Track research tasks with TodoWrite.
- Spawn parallel sub-tasks for: deeper file discovery, patterns/conventions to follow, integration points, similar features to model after, existing tests. Wait for ALL.
- Present findings + design options and get the user to pick:

```
Based on my research, here's what I found:

**Current State:**
- [Key discovery about existing code]

**Design Options:**
1. [Option A] - [pros/cons]
2. [Option B] - [pros/cons]

Which approach aligns best with your vision?
```

## Step 4: Phase structure + wave dependencies

1. Propose phases (name + what each accomplishes). Confirm phasing with the user before writing details.

2. Assign waves. **Wave** = a set of phases that can run in parallel.

| Rule | Meaning |
|------|---------|
| No dependencies | Wave 1 |
| Depends on a Wave N phase | Wave N+1 |
| File appears in 2 phases of the SAME wave | NOT allowed — add an artificial dependency to serialize them |

Present the dependency graph, e.g.:

```
Phase 1: No dependencies (Wave 1)
Phase 2: Depends on Phase 1 (Wave 2)
Phase 3: No dependencies (Wave 1) -- parallel with Phase 1
Phase 4: Depends on Phase 2, Phase 3 (Wave 3)
```

Get sign-off on structure before writing the full plan.

## Step 5: Write the plan

Write to `plans/{descriptive_name}.md`. Use this exact skeleton — `/implement` parses the `<!-- wave: ... -->` comments and `[CHECKPOINT:*]` markers, so keep both formats verbatim:

```markdown
# [Feature/Task Name] Implementation Plan

## Overview
[What we're implementing and why, 1-2 sentences]

## Current State Analysis
[What exists now, what's missing, key constraints discovered]

## Desired End State
[The end state and how to verify it]

### Key Discoveries:
- [Finding with file:line reference]
- [Pattern to follow]
- [Constraint to work within]

## What We're NOT Doing
[Explicit out-of-scope items — prevents scope creep]

## Implementation Approach
[High-level strategy and reasoning]

## Phase 1: [Descriptive Name]
<!-- wave: 1 | depends_on: [] | files: [path/to/file1.ext, path/to/file2.ext] -->

### Overview
[What this phase accomplishes]

### Changes Required:

#### 1. [Component/File Group]
**File**: `path/to/file.ext`
**Changes**: [Summary]

```[language]
// Specific code to add/modify
```

### Success Criteria:

#### Automated Verification:
- [ ] Tests pass: `npm test`
- [ ] Type checking passes: `npm run typecheck`
- [ ] Linting passes: `npm run lint`
- [ ] Build succeeds: `npm run build`

#### Manual Verification:
- [ ] Feature works as expected when tested
- [ ] Edge cases handled correctly
- [ ] No regressions in related features

### Checkpoints (if applicable):
- **`[CHECKPOINT:human-verify]`**: Review automated work before continuing
  - What was built: [description]
  - How to verify: [numbered steps + expected outcomes]
  - Resume: Type "approved" or describe issues
- **`[CHECKPOINT:decision]`**: Choose between options
  - Options: [A vs B with trade-offs]
  - Impact: [what changes based on choice]
- **`[CHECKPOINT:human-action]`**: Non-automatable step (rare)
  - What's needed: [action only a human can take, e.g. "Click email verification link"]

---

## Phase 2: [Descriptive Name]
[Same structure]

---

## Testing Strategy
### Unit Tests: [what to test, key edge cases]
### Integration Tests: [end-to-end scenarios]
### Manual Testing Steps:
1. [Step to verify feature]
2. [Edge case to test manually]

## Performance Considerations
[Implications or optimizations, if any]

## Migration Notes
[How to handle existing data/systems, if applicable]

## References
- Original requirements: [location]
- Related research: `research/[relevant].md`
- Similar implementation: `[file:line]`
```

**Hard rules for the written plan:**

| Rule | Detail |
|------|--------|
| File ownership | Each file may be modified in only ONE phase per wave. Overlap within a wave → add a dependency between those phases. List every file a phase touches in its `files:` wave comment. |
| Checkpoint: automatable | If Claude CAN do it via CLI/API/Bash, it MUST NOT be a checkpoint. |
| Checkpoint: budget | Max 1 checkpoint per phase (prevents fatigue). |
| Checkpoint: mix | `human-verify` ≈ 90% (visual/UX review); `decision` occasional; `human-action` ≈ 1% (only what Claude literally cannot do). |
| Success criteria | Always split into Automated (runnable commands, file existence, compile/typecheck/tests) vs Manual (UI/UX, real-world perf, hard-to-automate edge cases). |
| No open questions | Every decision resolved before finalizing. Research or ask immediately — never leave unresolved questions in the final plan. |

## Step 6: Review & iterate

Tell the user the plan location and ask for review:

```
I've created the initial implementation plan at:
`plans/[filename].md`

Please review it and let me know:
- Are the phases properly scoped?
- Are the success criteria specific enough?
- Any technical details that need adjustment?
- Missing edge cases or considerations?
```

Iterate on feedback (add/remove phases, adjust approach, sharpen criteria, adjust scope) until the user is satisfied.

## Phase-ordering patterns (pick by task type)

| Task type | Phase order |
|-----------|-------------|
| New feature | Research existing patterns → data model → backend logic → API endpoints → UI last |
| Refactoring | Document current behavior → incremental changes → maintain backwards compat → migration strategy |
| Database change | Schema/migration → data access methods → business logic → API → clients |
