---
name: plan-tdd
description: Create a test-driven development plan for the project
user-invocable: true
---

Create a test-driven development (TDD) plan for: $ARGUMENTS

TDD = write a failing test first (red), make it pass with minimal code (green), clean up (refactor). This skill produces plan documents only; it does NOT write code.

## When NOT to use
| Situation | Use instead |
|-----------|-------------|
| No test-first requirement; just want a build plan | `/plan` |
| Work is a set of GitHub issues to file | `/plan-gh` |
| Execute an existing plan, not create one | `/implement` |

<!-- recall:begin -->

## Step 0: Prior-art check (MANDATORY)

Recall prior learnings first so you don't re-decide something already captured.

```bash
uv run "{{HOME_TOOL_DIR}}/skills/recall/scripts/recall.py" \
  "<QUERY>" \
  --limit 5 --format markdown
```

`<QUERY>` = task description + `"testing strategy"` + target module name. Example: `"payment webhook testing strategy"`.

| Result | Action |
|--------|--------|
| Learning names a relevant constraint / anti-pattern / prior decision | Surface it to the user BEFORE Step 1 |
| Nothing relevant | Proceed silently; don't mention the check |
| Empty output or non-zero exit | Treat as "no prior art" — NOT an error. Never block on it |

<!-- recall:end -->

## Step 1: Read the spec
- Path in $ARGUMENTS → read it.
- No path → look for `spec.md` in project root. Absent → ask user for spec path and STOP until given.
- Extract: requirements, acceptance criteria, expected behavior.

## Step 2: Break work into testable chunks
- Decompose into components/features, each independently testable.
- Pick each chunk's test level: **unit** (single function/class), **integration** (module boundaries, DB, IO), **e2e** (full user flow).
- Size each chunk to one red-green-refactor cycle. Needs >1 cycle → split it. No complexity jumps between chunks.
- Order chunks so each builds on the prior; last chunk wires everything together under an integration test.

## Step 3: Define the test harness
- Framework + runner (`pytest`, `vitest`, `go test`): match what the project already uses; if none, pick the language default.
- Test file location + naming convention (e.g. `tests/test_*.py`, `*.test.ts`).
- Mock/fixture strategy and test-data source.

## Step 4: Write per-chunk TDD prompts
For each chunk, produce a prompt with three explicit phases:
1. **Red** — the failing test(s) to write, and the exact assertion each makes.
2. **Green** — minimal implementation to pass.
3. **Refactor** — cleanup while keeping tests green.

Each prompt references prior chunks' code and keeps their tests passing.

## Step 5: Write the three output files
Save to project root, exact names:

| File | Contents |
|------|----------|
| `tdd-development-plan.md` | Chunk breakdown, ordering, test levels per chunk |
| `tdd-implementation-prompts.md` | The per-chunk red-green-refactor prompts from Step 4 |
| `testing-strategy.md` | Harness, file layout, naming, mock strategy, e2e/perf milestones, example test skeleton |

## Gate
Done when all three files exist AND every spec feature maps to at least one failing-test-first chunk.
If any spec requirement has no chunk → return to Step 2 and add one.
