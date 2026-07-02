---
name: critique
description: Get a Distinguished Engineer level technical critique of the current approach
user-invocable: true
---

# Critique Command

Brutally honest, constructive Distinguished-Engineer critique of an approach/implementation. Output: a structured JSON verdict in one `<output>` block, then saved to disk.

## When NOT to use

| Situation | Use instead |
|-----------|-------------|
| UI/UX, cognitive-load, or usability review of a frontend | `impeccable` skill |
| Line-level bug/correctness review of a diff | `code-review` skill |
| Hunt over-engineering only, one line per finding | `ponytail-review` skill |
| Critique a plan/approach with a verdict score | this skill (correct) |

<!-- recall:begin -->

## Step 0: Prior-art check (MANDATORY, run first)

Build `<QUERY>` = short summary of the approach + domain keywords (e.g. `event-sourced migration rollback strategy`). Run:

```bash
uv run "{{HOME_TOOL_DIR}}/skills/recall/scripts/recall.py" "<QUERY>" --limit 5 --format markdown
```

| recall result | Do this |
|--------|---------|
| Names a constraint / anti-pattern / prior decision relevant to the task | Surface it to the user BEFORE the main critique |
| Nothing relevant | Proceed silently, don't mention the check |
| Empty output OR non-zero exit | Treat as "no prior art" — never block, never call it an error (KB may be absent) |

<!-- recall:end -->

## Usage

```
/critique [type] "context"
```

`type` defaults to `general`. Example: `/critique cost "Kubernetes for a static website"`.

| type | Focus |
|------|-------|
| `general` | Overall technical review (default) |
| `architecture` | System design and patterns |
| `performance` | Performance and scalability |
| `security` | Security implications |
| `cost` | Total cost of ownership |
| `complexity` | Overengineering assessment |
| `all` | All of the above |

## Runbook

1. **Extract context** from the conversation: recent technical decisions, files created/modified this session, relevant snippets, stated trade-offs and constraints.
2. **Analyze** from a 25+-year Distinguished Engineer lens: name anti-patterns and overengineering, weigh complexity vs. problem size, list simpler alternatives, evaluate long-term implications. Every concern MUST cite concrete evidence from the code/decision — never a generic worry.
3. **Score the verdict** — pick exactly one:

   | Verdict | Meaning |
   |---------|---------|
   | `APPROVE` | Sound; proceed |
   | `CAUTION` | Proceed but fix named concerns first |
   | `RECONSIDER` | Serious doubts; a listed alternative is likely better |
   | `REJECT` | Do not proceed as-is |

4. **Emit** the critique as JSON inside one `<output>`…`</output>` block (schema below).
5. **Save** to `{{HOME_TOOL_DIR}}/critiques/critique_[TIMESTAMP]_[TYPE].json` — `[TIMESTAMP]` = `date +%Y%m%dT%H%M%S`, `[TYPE]` = requested type. Run `mkdir -p {{HOME_TOOL_DIR}}/critiques` first.

## Output schema (JSON inside `<output>` block)

Include every key; omit a section only when the requested `type` makes it irrelevant.

- `summary`: `{ verdict, one_liner, confidence }` (confidence 0.0–1.0)
- `strengths`: 2–3 genuine strengths
- `concerns`: `{ critical[], major[], minor[] }`, each item `{ issue, impact }`
- `alternatives`: `[ { approach, pros, cons } ]`
- `cost_analysis`: `{ initial, operational, hidden, tco_3yr }`
- `complexity`: `{ overengineering_score, simplifications[] }` (score 0–10)
- `team_impact`: `{ learning_curve, hiring_difficulty, maintenance_burden }`
- `future_proofing`: `{ scalability_limits, migration_difficulty, tech_debt }`
- `recommendation`: `{ proceed: bool, conditions[] }`
- `wisdom`: pattern recognition, war stories, principles

Voice: brutally honest but constructive, data-driven with real examples. Advisory, not prescriptive — challenge assumptions, weigh context. Prevent expensive mistakes without crushing innovation.

## Response protocol (after critique is shown)

1. Acknowledge each concern point.
2. Agree, or give rationale against it.
3. Propose concrete adjustments for valid points.
4. Update the implementation if significant issues surfaced.
