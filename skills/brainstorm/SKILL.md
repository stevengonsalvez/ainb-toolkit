---
name: brainstorm
description: Turn an idea into an approved design spec. Brainstorm is the orchestrator - it scaffolds a topic-stub with subject-type detection and ASCII preview hypotheses, then DELEGATES the iterative Q&A to /interview. After /interview returns a spec, brainstorm self-reviews, gates on user approval, and hands off to /plan. No HTML, no browser - terminal + ASCII previews only.
user-invocable: true
---

Brainstorm idea: `$ARGUMENTS`. Deliverable = an approved spec doc, NOT code. **You orchestrate; `/interview` runs the Q&A.**

<HARD-GATE>
Do NOT write code, scaffold, run install/build, or invoke any implementation skill (`/plan`, `/implement`, `/plan-tdd`, framework codegen) until a written spec exists in `.agents/specs/` AND the user explicitly approved it (Step 10). Then Step 12 (`/plan` handoff) is the only terminal action. Applies to every project regardless of perceived simplicity.
</HARD-GATE>

**Every brainstorm produces a spec** — todo list, single util, config change, all of them. Spec may be 10 lines for trivial work, but it must exist and be approved. "Simple" is where unexamined assumptions bite hardest.

## When NOT to use

| Situation | Use instead |
|-----------|-------------|
| Spec already exists + approved | `/plan` directly |
| Running the actual Q&A loop | `/interview` (brainstorm delegates to it — don't duplicate) |
| Idea already fully specified, no design questions | `/plan` directly |

## Division of labour

| Skill | Owns |
|-------|------|
| `/brainstorm` | Recall, project scan, subject-type detection, stub scaffolding w/ ASCII previews, self-review, user-review gate, `/plan` handoff |
| `/interview` | The iterative AskUserQuestion Q&A loop that populates the spec file |

You write ONE rich stub file, hand off, read the result back. Terminal state = `/plan` invocation. Never invoke `/implement` or codegen directly.

```
Recall+scan ─▶ detect type ─▶ scaffold stub ─▶ INVOKE /interview
                                                     │ (writes <stub>-spec.md)
                                                     ▼
/plan handoff ◀─ user gate ◀─ self-review ◀─ read back spec
```

## Checklist (track via TaskCreate)

1. Recall prior learnings (Step 1)
2. Scan project context (Step 2)
3. Decompose if too large (Step 3)
4. Detect subject type (Step 4)
5. Pre-stub clarifier — optional, ≤1 question (Step 5)
6. Scaffold `.agents/specs/YYYY-MM-DD-<topic>-stub.md` (Step 6)
7. Invoke `/interview <stub-path>` (Step 7)
8. Read back `<stub>-spec.md` (Step 8)
9. Self-review spec (Step 9)
10. User-review gate — explicit approval (Step 10)
11. Rename + commit final spec (Step 11)
12. Handoff to `/plan` (Step 12)

<!-- recall:begin -->

## Step 1: Prior-art check (MANDATORY)

Recall prior learnings before brainstorming so you don't re-decide something already captured:

```bash
uv run "{{HOME_TOOL_DIR}}/skills/recall/scripts/recall.py" \
  "<QUERY>" \
  --limit 5 --format markdown
```

**Query** = topic + constraint hints (e.g. `"caching strategy mobile offline"`).

| Result | Action |
|--------|--------|
| A learning names a relevant constraint/anti-pattern/prior decision | Surface it to the user BEFORE proceeding |
| Nothing relevant | Proceed silently |
| Empty output / non-zero exit | Treat as "no prior art" — NOT an error. Never block on recall failure |

<!-- recall:end -->

## Step 2: Project context

- `git log --oneline -20` — recent direction
- `ls` repo root + relevant subdirs
- Read `docs/`, `README.md`, `AGENTS.md`, `CLAUDE.md`
- Note existing patterns to follow

## Step 3: Decompose check

If the request names multiple independent subsystems ("platform with chat + file storage + billing + analytics"), STOP and decompose:

```
"Build platform with X, Y, Z"
        ├────────┬────────┐
        ▼        ▼        ▼
     Sub-X    Sub-Y    Sub-Z
   (each its own /brainstorm cycle later)
```

Pick the FIRST sub-project. Brainstorm THAT only. Others get their own cycle later.

## Step 4: Detect subject type

Infer from `$ARGUMENTS` + project context. Ambiguous → ask ONE question (Step 5). A brainstorm often spans 2-3 types (e.g. API + data model + CLI) — include the ASCII library slice for EACH.

| Subject | Preview shape |
|---------|---------------|
| UI (web/mobile) | ASCII wireframe (header / sections / buttons) |
| TUI | ASCII screen mock (panes / status bar / keys) |
| API | endpoint + request/response JSON snippet |
| Data model | entity box + relationship arrows |
| Architecture | component box + dataflow arrows |
| CLI | command syntax + sample stdout |
| Config | YAML/JSON snippet |
| State machine | state node + transition arrows |
| Pure concept | no preview — text description only |

## Step 5: Pre-stub clarifier (optional, ≤1 question)

Only if subject type or core scope is unclear. Use AskUserQuestion. Examples:
- "What kind of artifact?" → { Web UI, Mobile UI, TUI, API, CLI, library, mixed }
- "Hard constraint?" → { has deadline, no constraints, needs perf target }

Enough context from `$ARGUMENTS` + Step 2 → **skip this step**, go straight to Step 6. Goal is to give `/interview` enough to run — not to do its job.

## Step 6: Scaffold the topic-stub

1. **Read the ASCII library**: `{{HOME_TOOL_DIR}}/skills/brainstorm/assets/ascii-library.md` (8 subject-keyed sections). Copy the matching slice(s) into the stub's `## ASCII preview library` section.
2. **Resolve every `<placeholder>` from $ARGUMENTS + Step 2 BEFORE writing.** On-disk stub must contain no angle-bracket placeholders, no `TBD`, no `TODO`. A placeholder-laden stub wastes /interview's first round on re-derivation.
3. Write to `.agents/specs/YYYY-MM-DD-<topic-slug>-stub.md`.

**The stub IS the contract with `/interview`.** It must contain EXACTLY these headings — no em-dash suffixes, no rewording (interview string-matches them):

- `## Idea`
- `## Project context (inferred)`
- `## Subject type(s)`
- `## Initial hypotheses`
- `## ASCII preview library`
- `## For /interview`
- `## Output Spec Template`

Template body (fill it, keep the two contract sections — `## For /interview` and `## Output Spec Template` — verbatim in structure):

````markdown
# Brainstorm topic stub: <title>

> This is a brainstorm stub. The `/interview` skill will read it and run the iterative Q&A. Follow the instructions in the "For /interview" section.

## Idea

<one-paragraph problem statement from $ARGUMENTS + clarifier answer>

## Project context (inferred)

- Stack: <e.g. Rust + tokio>, <repo patterns spotted>
- Existing patterns: <bullet list of relevant docs / code paths>
- Constraints surfaced from recall: <if any>

## Subject type(s)

<UI | TUI | API | data model | architecture | CLI | config | state machine | mixed>

## Initial hypotheses

Three candidate approaches. **`/interview` MUST present these via AskUserQuestion in its first round, using the ASCII preview field shown below for each.**

### A: <name>  (recommended)

<one-line rationale>

```
<ASCII preview drawn from the matching library section>
```

### B: <name>

<tradeoff vs A>

```
<ASCII preview>
```

### C: <name>  (optional - only if there's a real third path)

<tradeoff>

```
<ASCII preview>
```

## ASCII preview library

Inlined slices from `{{HOME_TOOL_DIR}}/skills/brainstorm/assets/ascii-library.md` that match this brainstorm's subject type(s). `/interview` uses these in subsequent AskUserQuestion `preview` fields.

<paste the matching subject-type sections here>

## For /interview

**Read this carefully before starting the interview.**

- **First round**: present the three approach hypotheses above via AskUserQuestion. Set `preview` to the ASCII block under each.
- **Subsequent rounds**: drill into architecture, data model, interface, behavior, errors, testing. **Every option-style question MUST use `AskUserQuestion`** with `preview` populated from the library above when comparing concrete shapes.
- **One question per turn** (or 2-4 if naturally batched). Multi-choice preferred.
- **Topics to cover** (skip if N/A): architecture / data model / interface (UI/API/CLI/TUI) / happy path / 2-3 critical edge cases / error handling / testing strategy / out of scope / open questions.
- **Output**: write the spec to `<this-stub-basename>-spec.md` using the "Output Spec Template" section below — **NOT** the default `/interview` corporate template.

### Format preferences (apply to BOTH chat outputs AND spec file)

Per Stevie's CLAUDE.md `<flow_diagrams>` rule. Boundary:

| Content shape                                | Use                                              |
|----------------------------------------------|--------------------------------------------------|
| Flow / sequence / relationships / state      | ASCII box+arrow diagram (`┌─┐ │ └─┘ ─▶ ▼`)        |
| Tabular DATA (rows × columns of facts)       | markdown pipe table                              |
| Discrete items, no ordering                  | bullet list                                      |
| Picks / open questions                       | `- [ ]` checklist                                |
| Prose / narrative paragraphs                 | AVOID — break it into one of the above           |

Rules:
- **Diagram FIRST, table SECOND** when both apply to the same section.
- Diagram width ≤ 80 chars.
- Caveman inside boxes (short technical terms, never sentences).
- Sequence diagrams (vertical lifelines) ONLY for protocol handshakes / back-and-forth.
- Branching trees ONLY for explicit if/else logic.
- No prose-only sections in the spec. Every section must be diagram + table + bullets.

## Output Spec Template

```markdown
# Spec: <title>

**Generated from:** <stub-path>
**Date:** <YYYY-MM-DD>
**Format:** diagram-first, table-second, no prose paragraphs

## Problem

| Question | Answer            |
|----------|-------------------|
| What?    | <one-liner>       |
| Why?     | <motivator>       |
| Who?     | <primary user>    |

## Users + use cases

| Persona     | Goal                | Primary use case          |
|-------------|---------------------|---------------------------|
| <persona 1> | <what they want>    | <core flow they trigger>  |
| <persona 2> | <...>               | <...>                     |

## Approach

| Option | Summary       | Tradeoff           | Picked? |
|--------|---------------|--------------------|---------|
| A      | <name>        | <vs B and C>       |  ✓      |
| B      | <name>        | <vs A>             |         |
| C      | <name>        | <vs A>             |         |

**Why A:** <one line>

## Architecture

<ASCII box+arrow diagram, ≤ 80 chars wide>

| Component | Purpose      | Owns                |
|-----------|--------------|---------------------|
| <name>    | <one-liner>  | <data / behavior>   |

## Data model

<ASCII entity + relationship diagram>

| Entity   | Fields (key only)        | Relationships    |
|----------|--------------------------|------------------|
| <name>   | id, ...                  | 1:N to <other>   |

## Interface

ASCII previews per applicable subject type (UI wireframe | TUI screen | API endpoints | CLI sample | config schema).

| Surface    | Trigger              | Shape                 |
|------------|----------------------|-----------------------|
| <name>     | <user/system event>  | <method / screen / cmd> |

## Behavior

Happy path (ASCII flow):

[start] ──action──▶ [state-1] ──action──▶ [state-2] ──ok──▶ [done]

Edge cases:

| Scenario          | Trigger              | Expected behavior        |
|-------------------|----------------------|--------------------------|
| <case 1>          | <condition>          | <what happens>           |
| <case 2>          | <condition>          | <what happens>           |
| <case 3>          | <condition>          | <what happens>           |

## Errors

| Failure mode    | User-visible surface       | Recovery              |
|-----------------|----------------------------|-----------------------|
| <e.g. 500>      | <toast / log / silent>     | <retry / fallback>    |
| <network drop>  | <...>                      | <...>                 |

## Testing strategy

| Layer       | Scope                              | Coverage gate       |
|-------------|------------------------------------|---------------------|
| Integration | <flows covered>                    | <must-pass>         |
| E2E         | <user-visible journeys>            | <must-pass>         |
| Unit        | <only where logic is non-trivial>  | <if applicable>     |

## Out of scope

- <explicit item 1>
- <explicit item 2>

## Open questions for /plan

- [ ] <question 1>
- [ ] <question 2>
```
````

After writing the stub, **DO NOT answer the questions yourself.** Hand off to `/interview`.

## Step 7: Invoke /interview

**Filename contract (used in Steps 8-11):** `/interview` writes `<input-basename>-spec.md` next to the input. Given `<topic>-stub.md`, output is `<topic>-stub-spec.md`. Every path below depends on this — if the suffix ever changes, update Steps 8-11.

```
Skill(skill: "interview", args: ".agents/specs/YYYY-MM-DD-<topic>-stub.md")
```

`/interview` will: read the stub → use its embedded `## Output Spec Template` (NOT the default) → honor `## Initial hypotheses` / `## ASCII preview library` / `## For /interview` → run AskUserQuestion rounds (hypotheses first, then design) → write `.agents/specs/YYYY-MM-DD-<topic>-stub-spec.md`.

Wait for `/interview` to return control.

## Step 8: Read back the spec

Read `.agents/specs/YYYY-MM-DD-<topic>-stub-spec.md`.

| Result | Branch |
|--------|--------|
| File exists, non-trivial | Proceed to Step 9 |
| File missing or near-empty | `/interview` did not complete — re-invoke Step 7 or ask user; do NOT fabricate the spec yourself |

## Step 9: Spec self-review

Fresh-eyes pass. Fix inline; don't re-loop. Only flag issues that would cause real planning problems — leave minor wording/style alone.

| Gate | Look for |
|------|----------|
| Placeholder | `TBD`, `TODO`, `<...>`, empty sections |
| Consistency | sections contradicting each other; arch ≠ behavior |
| Ambiguity | requirement readable two ways → pick one, make explicit |
| Scope | still one project, or bloated? if bloated → decompose again (Step 3) |
| YAGNI | unrequested features creeping in → strip |

## Step 10: User-review gate

Post verbatim:

> "Spec written to `.agents/specs/YYYY-MM-DD-<topic>-stub-spec.md`. Review it. Changes welcome before we finalize + move to `/plan`."

| User response | Branch |
|---------------|--------|
| Explicit approval | Proceed to Step 11 |
| Changes requested | Fix → re-run Step 9 → re-ask. Do NOT proceed |
| No response yet | Wait. Never auto-proceed to `/plan` (HARD-GATE) |

## Step 11: Rename + commit

Stub files were created by `Write` (untracked), so use plain `mv`/`rm`, NOT `git mv`/`git rm` (those need tracked files):

```bash
mv .agents/specs/YYYY-MM-DD-<topic>-stub-spec.md .agents/specs/YYYY-MM-DD-<topic>.md
rm .agents/specs/YYYY-MM-DD-<topic>-stub.md
git add .agents/specs/YYYY-MM-DD-<topic>.md
git commit -m "feat(spec): add <topic> design spec"
```

One atomic commit; only the final spec lands in history (stub was scaffolding).

## Step 12: Handoff to /plan

Invoke `/plan` (Skill tool) with the final spec path. Do NOT invoke `/implement`, framework codegen, or anything else. This is the terminal action.

## Anti-patterns (each maps to a rule above)

| Anti-pattern | Correct |
|--------------|---------|
| Doing the Q&A inside `/brainstorm` | Delegate to `/interview` (Step 7) |
| Thin stub → shallow questions | Put everything /interview needs in the stub (Step 6) |
| Plaintext option tables | AskUserQuestion only (per CLAUDE.md `<option_presentation>`) |
| HTML / browser companions | Terminal + ASCII only |
| Stub with unresolved `<placeholders>` | Resolve all before writing (Step 6) |
| Auto-running `/plan` without approval | Wait for explicit yes (Step 10, HARD-GATE) |
| Renaming stub-spec with `git mv` | Plain `mv` — files are untracked (Step 11) |
| Em-dash suffix / reworded stub headings | Exact-match the 7 headings (Step 6) |
