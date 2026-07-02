---
name: validate
description: Verify implementation against specifications
user-invocable: true
---

# Validate

Runbook: prove an implementation plan was executed correctly. Verify every success criterion, catch stubs/orphans, and report gaps. Output is a saved validation report.

## When NOT to use (route elsewhere)

| Situation | Use instead |
|-----------|-------------|
| No plan file exists; you just changed code and want to confirm it works end-to-end | `/verify` |
| Hunting for correctness bugs in a diff | `/code-review` |
| Building the feature (not checking it) | `/implement` |

Validate REQUIRES a plan with success criteria. No plan → ask for one or use `/verify`.

<!-- recall:begin -->

## Step 0: Prior-art check (RECOMMENDED)

Before validating, recall prior learnings from the global knowledge base so we don't re-learn or re-decide something already captured:

```bash
uv run "{{HOME_TOOL_DIR}}/skills/recall/scripts/recall.py" \
  "<QUERY>" \
  --limit 5 --format markdown
```

**Query construction for `/validate`**: the feature/change being validated + relevant verification keywords (e.g. `"OAuth callback validation edge cases"`).

**What to do with results:**

- If a returned learning names a constraint, anti-pattern, or prior decision directly relevant to the task — surface it to the user BEFORE proceeding with this skill's main flow.
- If nothing relevant returns — proceed silently, no need to mention the check.
- Never block on recall failure. Empty output / non-zero exit is expected when the KB is absent or the subprocess errors — treat it as "no prior art found", not as an error.

<!-- recall:end -->

## Step 1: Locate the plan and set context

1. Pick the plan:
   - Path provided → use it.
   - Else → `ls -t plans/*.md | head` and pick the most recent one with `- [x]` checkmarks (implemented).
   - No plan found → say so, ask the user for the path. Do not guess.
2. Read the plan in full. Extract into a working list:
   - Every file the plan says should be modified/created.
   - Every "Success Criteria" (split into Automated vs Manual).
   - Every observable truth (what a user should be able to do).
3. State context in one line: "Validating `plans/X.md` — N phases, M files, K automated checks."

## Step 2: Discover the implementation (parallel Tasks)

Spawn these Task agents in ONE message (independent, so parallel):

```
Task 1 — DB/schema: Was migration [N] added? Does schema match plan? Return: implemented vs specified.
Task 2 — Code: Find all files changed for [feature]. Return: file-by-file planned vs actual.
Task 3 — Tests: Were tests added/modified per plan? Run test cmd, capture results. Return: status + coverage gaps.
```

Skip a Task if the plan has no work in that category (e.g. no DB changes → drop Task 1).

## Step 3: Run automated verification

For each command under the plan's "Automated Verification", run it and record pass/fail. If the plan lists none, run the matching stack commands:

Run each command SEPARATELY and record its own pass/fail — never `&&`-chain them (a chain short-circuits on first failure and skips the remaining checks, violating the do-not-stop rule below):

```bash
# JS/TS
npm test; npm run lint; npm run typecheck; npm run build
# Python
pytest; flake8; mypy .
# Go
go test ./...; go vet ./...; golangci-lint run
# Rust
cargo test; cargo clippy; cargo fmt --check
# Generic
make test; make check; make lint
```

Branch on outcome:
- All pass → mark phase criteria met, continue.
- A command fails → investigate root cause (read the error, the file:line). Record it as a finding with severity (Step 6). Do NOT stop — keep validating remaining phases.
- Command missing/binary absent (`command not found`) → note "check unrunnable: <cmd>" as a Manual item, don't fabricate a pass.

## Step 4: Goal-Backward Verification (the core check)

Task completion ≠ working feature. For each observable truth from Step 1, verify its artifact at three levels:

| Level | Check | Fails when |
|-------|-------|-----------|
| **Exists** | File/function present | file/symbol absent |
| **Substantive** | Real code, not a stub | matches a stub pattern below |
| **Wired** | Imported, called, routed, or rendered | defined but never referenced |

**Stub patterns → NOT substantive** (flag any of these):
`return null` / `return {}` / `return undefined`; `// TODO` / `// FIXME` / `// placeholder`; `throw new Error("Not implemented")`; empty function body or bare `pass`; `onClick={() => {}}`; `Response.json({ message: "Not implemented" })`; function defined but never imported/called.

Produce the matrix (this exact format goes in the report):

```markdown
## Goal-Backward Verification

| Truth | Artifact | Exists | Substantive | Wired | Status |
|-------|----------|--------|-------------|-------|--------|
| User can login | src/auth/login.ts | Y | Y | Y | VERIFIED |
| Session persists | src/auth/session.ts | Y | Y | N | ORPHANED |
| Errors display | src/components/Error.tsx | Y | N | - | STUB |
| Rate limited | src/middleware/rate.ts | N | - | - | MISSING |
```

Status rule: all three Y → VERIFIED. Exists+Substantive but not Wired → ORPHANED. Exists but stub → STUB. Missing file → MISSING.

For every non-VERIFIED row, write a gap block:

```markdown
### Gap: Session persistence (ORPHANED)
- **Truth**: "Session persists across page reloads"
- **Issue**: session.ts is substantive but never imported in app routes
- **Fix**: Import and wire session middleware in src/app.ts
```

## Step 5: Code quality review (parallel Tasks)

Spawn in one message:

```
Task 1 — Review [Phase feature]: matches plan? error handling? bugs? Return findings with file:line.
Task 2 — Test coverage for [feature]: added per plan? quality? missing cases? Return locations + gaps.
Task 3 — Regressions in [related component]: existing behavior intact? breaking changes? Return concerns.
```

## Step 6: Write the validation report

Fill this template with real values (no placeholders left) and save to `validation/YYYY-MM-DD_HH-MM-SS_planname.md`:

```markdown
# Validation Report: [Plan Name]

**Date**: [date + time]
**Plan**: plans/[plan_file].md
**Validation Type**: [Automated | Manual | Comprehensive]

## Implementation Status
### Phase Completion
Phase 1: [Name] - Fully implemented
Phase 3: [Name] - Partially implemented (see issues)

### Files Modified
`src/auth/oauth.js` - Added as specified
`tests/auth.test.js` - Missing test cases

## Automated Verification Results
Build: `npm run build` passes (2.3s)
Tests: 142 passing, 2 failing (OAuth callback timeout; token refresh undefined var)
Linting: clean | Coverage: 78% (target 80%)

## Goal-Backward Verification
[matrix from Step 4 + gap blocks]

## Code Review Findings
### Matches Plan
- [items]
### Deviations from Plan
- [item] — Impact: [positive/negative + why]
### Potential Issues
**[Category]**: [issue] — Recommendation: [fix]

## Manual Testing Required
- [ ] [criterion the automation could not check]

## Recommendations
### Immediate Actions
1. [blocker fix]
### Before Production
1. [important fix]

## Summary
**Overall Status**: [Complete | Mostly Complete | Incomplete]
[2-3 sentences: what works, what blocks completion]
**Next Steps**: numbered list
```

Severity rule for findings: **Blocker** (must fix before merge — failing tests, MISSING/STUB truths, security holes) / **Important** (fix soon — ORPHANED wiring, coverage below target) / **Nice-to-have** (later). Every Blocker gets a concrete fix or an outlined approach.

## Step 7: Offer next actions

After presenting the report, ask the user (single message):
1. Fix the failing tests?
2. Implement the missing/stubbed features?
3. Run additional checks?
4. Generate a manual-testing checklist?

## Rules

- Run every automated check; never claim a pass you didn't observe.
- A green test suite with a STUB or MISSING truth is still a FAIL — Goal-Backward wins over checkmarks.
- Report deviations from the plan even when they're improvements (say so, mark Impact positive).
- Be constructive: every gap ships with a fix or an approach.
- Check documentation as a validation dimension: README/API docs/inline docs updated where the change requires it.
- Close the loop into the plan: for each Blocker/Important gap, append an unchecked `- [ ]` fix item to the source plan under the affected phase and note the phase needs rework, so `/implement` can resume from it.
