---
name: interview
description: |
  Interview the user about a plan file to extract detailed requirements,
  clarify ambiguities, and uncover edge cases. Uses iterative questioning
  to produce a comprehensive specification.
version: 1.0.0
authors:
  - Thariq Shihipar (original concept)
  - Rob Zolkos (gist adaptation)
  - Claude Code Toolkit (enhancement)
argument-hint: <plan-file>
model: opus
license: Apache-2.0

metadata:
  category: planning
  keywords: [interview, requirements, specification, planning, discovery]
  original-source: https://gist.github.com/robzolkos/40b70ed2dd045603149c6b3eed4649ad

compatibility: |
  Works with any LLM tool that supports:
  - File reading
  - Multi-turn questioning (AskUserQuestion or equivalent)
  - File writing

  Tested with: Claude Code, Codex (OpenAI)

allowed-tools:
  - Read
  - Write
  - AskUserQuestion
---

# Interview Skill

Runbook: interview the plan author with a structured question tool, then write a spec file. Input = a plan file path in `$ARGUMENTS` (`$1`).

## When NOT to use

- No plan file exists yet, or the idea is still raw → run `/brainstorm` first; it scaffolds the stub and calls this skill for you.
- User wants an implementation plan, not requirements clarification → use `/plan`.

## Flow

```
┌────────┐   ┌──────────────┐   ┌──────────────┐   ┌────────────┐
│ Read   │──▶│ Detect       │──▶│ AskUser-     │──▶│ Write      │
│ input  │   │ embedded     │   │ Question     │   │ spec.md    │
│ file   │   │ sections     │   │ rounds 1..N  │   │            │
└────────┘   └──────────────┘   └──────────────┘   └────────────┘
```

## Step 1 — Read and analyze the plan

1. `Read` the file at `$ARGUMENTS`. If the path is missing or unreadable → stop and ask the user for a valid plan file path.
2. Extract: core objectives, technical components, user-facing aspects, dependencies, and gaps (underspecified areas — these become questions).

### Scan for `/brainstorm` handoff sections

These sections may be embedded in the input file. They are `/brainstorm`'s handoff contract — honor each verbatim:

| Section (if present in input)   | Do this                                                                                                  |
|---------------------------------|----------------------------------------------------------------------------------------------------------|
| `## For /interview`             | Follow verbatim. Dictates first-round question shape, ASCII preview usage, topic coverage.                |
| `## Initial hypotheses`         | Pre-populated A/B/C approaches. Your FIRST AskUserQuestion round MUST present these as options, each option's ASCII code-block embedded in its `preview` field. |
| `## ASCII preview library`      | Reusable preview snippets keyed by subject type. Use in later rounds' `preview` fields when comparing concrete shapes (mockups, schemas, diagrams). |
| `## Output Spec Template`        | Literal markdown template for the spec output. Use verbatim in Step 5 instead of the default template.    |
| `## Format preferences`         | Dictates chat + spec output shape. Honor it; overrides the default convention below.                      |

## Step 2 — Conduct the interview

MANDATORY: use a structured user-prompt tool. NEVER dump questions as plaintext chat unless every structured option below is unavailable.

Why forced: an "or equivalent" out makes agents skip the structured tool, producing lower-quality interviews. Typed answers can be branched on; plaintext cannot.

Pick the tool — first match wins:

| Host                                  | Tool                                                                    |
|---------------------------------------|-------------------------------------------------------------------------|
| Claude Code                           | `AskUserQuestion` (questions array, `multiSelect: true` when multi-pick) |
| Codex / OpenAI Agents SDK             | native prompt primitive: `user_prompt` / `prompt_user` / `ask_user` / `Prompt` — pick whichever is in your tool list |
| Cursor / Windsurf / other agents      | built-in user-question primitive (`request_input`, `ask`, etc.)         |
| Generic LLM, no native tool           | LAST RESORT: plaintext block `### Question 1:` / `### Question 2:`, ask user to answer inline |

Branch: if a likely prompt tool exists but the call fails as unavailable → treat as "no native tool", fall back to plaintext immediately. Do NOT spend a turn asking how to ask.

### Output shape convention (default — `## Format preferences` overrides)

| Content shape                            | Use                                        |
|------------------------------------------|--------------------------------------------|
| Flow / sequence / relationships / state  | ASCII box+arrow diagram (`┌─┐ │ └─┘ ─▶ ▼`)  |
| Tabular DATA (rows × columns of facts)   | markdown pipe table                        |
| Discrete items, no ordering              | bullet list                                |
| Picks / open questions                   | `- [ ]` checklist                          |
| Prose / narrative paragraphs             | AVOID — convert to one of the above        |

Rules: diagram FIRST, table SECOND when both apply. Diagram width ≤ 80 chars, caveman terms inside boxes. No prose-only sections in the spec. AskUserQuestion `preview` fields follow the same convention.

### Question quality gate

| Ask questions that are          | Do NOT ask questions that are        |
|---------------------------------|--------------------------------------|
| Specific and actionable         | Already answered in the plan         |
| Non-obvious (not in the plan)   | Yes/no with no follow-up             |
| Exploratory of edge cases       | Too abstract to be actionable        |
| Challenging to assumptions      | Trivial or obvious                   |
| Focused on trade-offs/priorities |                                     |

Cover these categories across rounds (skip any that don't apply):
- **Technical:** architecture trade-offs, performance, security, error handling, integration points.
- **UI/UX:** user flows, interaction edge cases, accessibility, responsive/mobile.
- **Business/Product:** success metrics, feature priority, MVP vs future scope, stakeholders.
- **Risks:** known risks + mitigations, external dependencies, timeline, technical debt.
- **Trade-offs:** what to sacrifice for speed, what's non-negotiable, build vs buy.

## Step 3 — Iterate

1. MANDATORY: batch 2–4 questions per AskUserQuestion call. NEVER one question per round — except the final yes/no approval gate. Use `multiSelect: true` when multiple answers are valid.
2. Read answers, pick follow-up threads on the highest-uncertainty areas, go deeper.
3. Continue until ALL of these are true (completion gate):
   - Core technical decisions clarified
   - Edge cases identified and addressed
   - Priorities established
   - Constraints documented
   - No remaining scope ambiguity

If the gate is not met after a round → run another round. If met → go to Step 4.

## Step 4 — Generate the spec

Output path: same directory as the plan, named `{plan-basename}-spec.md`.
Example: `project-plan.md` → `project-plan-spec.md`.

Template selection:
- Input had `## Output Spec Template` → use it verbatim, fill placeholders from interview answers, do NOT mix in the default template.
- Otherwise → use the Default Specification Template below.

`Write` the completed spec to the output path.

### Default Specification Template

```markdown
# Specification: {Project/Feature Name}

**Generated from:** {plan file path}
**Interview date:** {current date}
**Version:** 1.0

## Executive Summary

{2-3 sentence summary of what this specification covers}

## Objectives

### Primary Goals
- {Goal 1}
- {Goal 2}

### Success Metrics
- {Metric 1}
- {Metric 2}

## Scope

### In Scope
- {Item 1}

### Out of Scope
- {Item 1}

### Future Considerations
- {Item 1}

## Technical Requirements

### Architecture
{Architecture decisions and rationale}

### Components
| Component | Purpose | Technology |
|-----------|---------|------------|
| {name} | {purpose} | {tech} |

### Integrations
- {System 1}: {How it integrates}

### Performance Requirements
- {Requirement 1}

### Security Requirements
- {Requirement 1}

## User Experience (if applicable)

### User Flows
1. {Flow name}: {Description}

### Edge Cases
| Scenario | Expected Behavior |
|----------|-------------------|
| {scenario} | {behavior} |

## Constraints & Dependencies

### Technical Constraints
- {Constraint 1}

### External Dependencies
- {Dependency 1}

### Timeline Constraints
- {Constraint 1}

## Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| {risk} | High/Med/Low | High/Med/Low | {mitigation} |

## Decisions Made

### Key Trade-offs
- **Decision:** {What was decided}
- **Alternatives considered:** {What else was considered}
- **Rationale:** {Why this choice}

### Deferred Decisions
- {Decision 1}: {Why deferred}

## Implementation Notes

### Priority Order
1. {Highest priority item}
2. {Second priority}

### Technical Debt Accepted
- {Item 1}: {Justification}

## Open Questions

- [ ] {Any remaining questions}

---

*This specification was generated through systematic interview of the plan author.*
```

## Example (single best case)

Plan excerpt: *"Build a user authentication system with OAuth support."*

Good round-1 questions (batched, specific, non-obvious):
1. Which OAuth providers are must-have vs nice-to-have (Google, GitHub, Apple)?
2. If a user links an OAuth account already tied to another user — merge, block, or error?
3. Session timeout requirements? Persist across browser restarts?
4. Audit logging level for auth events? Any compliance requirements?

## Portability notes

- **Claude Code:** `AskUserQuestion`, `questions` array, `multiSelect: true` for multi-pick, 2–4 per round.
- **Codex (Agents SDK / CLI):** use the native prompt primitive present at runtime (name varies by version: `user_prompt`, `prompt_user`, `ask_user`, `Prompt`). Codex has a real one — do NOT simulate via plaintext.
- **Cursor / Windsurf / Aider:** use the agent's own input primitive (`request_input`, `ask`). Do not fall through to plaintext if a structured one exists.
- **Generic LLM:** last resort only. Numbered `Question N:` headers, explicit "answer inline before continuing", no interleaved content.
