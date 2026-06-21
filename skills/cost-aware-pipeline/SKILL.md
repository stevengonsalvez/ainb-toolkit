---
name: cost-aware-pipeline
description: |
  Intelligence-first model routing for LLM pipelines. Sonnet is the default.
  Haiku is the exception, requiring positive justification. Opus for high-stakes
  and complex reasoning. Protects answer quality while reducing cost 30-50% vs
  defaulting everything to the session model.

  Use when: building multi-model pipelines, optimising API costs without
  sacrificing quality, designing retry strategies, implementing prompt caching,
  choosing models for sub-tasks.
---

# Cost-Aware LLM Pipeline (Intelligence-First)

## Routing Principle

**Sonnet is the default. Haiku is the exception. Opus is for high stakes.**

Start cheap, escalate on failure is NOT safe for intelligence-first. Haiku fails
silently — it returns confident, plausible, wrong answers that never trigger
the retry escalation. The retry ladder protects the mechanism, not the answer quality.

Route DOWN to Haiku only when the task is verifiably mechanical. Route UP to
Opus when consequence of error is high or when Sonnet has failed.

## Routing Decision Tree

```
Is consequence of error HIGH?              → OPUS
(security, data migration, architecture,
 non-reversible actions)

Is output UNVERIFIABLE (semantic)?         → SONNET minimum
(can't mechanically check correctness)

Is scope CROSS-FILE / CROSS-MODULE?        → SONNET minimum

Does task require JUDGMENT not retrieval?  → SONNET minimum
(ambiguous, requires weighing options)

Is pattern NOVEL / DOMAIN-SPECIFIC?       → SONNET minimum
(unusual architecture, custom DSL, rare idiom)

Is context > 50K tokens?                  → SONNET minimum
(Haiku degrades faster at long context)

ALL OF THE ABOVE ARE NO?                  → HAIKU OK
(pure extraction, single file,
 mechanically verifiable, reversible,
 ≤ 2 reasoning steps, well-known pattern)
```

## Routing Table

| Model | Route when | Examples |
|-------|-----------|---------|
| **Haiku** | Pure retrieval, single-file, mechanically verifiable, reversible, ≤2 reasoning steps, well-known pattern | `grep` for literal string, list files, extract struct field name, convert well-known format |
| **Sonnet** | **DEFAULT** — implementation, refactor, test writing, search-with-judgment, multi-file scope, code generation (see overrides below for named exceptions) | Writing tests, refactoring, non-architecture docs, dev-issue debugging (escalates), search needing semantic understanding |
| **Opus** | High-consequence, multi-file synthesis, architecture, security, novel patterns, after Sonnet fails twice | System design, security audit, concurrency bugs, cross-codebase impact analysis |

## Task-Specific Overrides (HARD RULES — override the table above)

These named task classes have fixed routing regardless of line count or scope:

| Task | Route | Notes |
|------|-------|-------|
| **Code review** | **Opus** | Always. Review quality is the safety net; do not cheap out on it |
| **Adversarial reviews / verification** | **Opus** | Always. The whole point is catching what cheaper models miss |
| **Final reviews** (pre-merge, pre-ship, gate) | **Opus** | Always. Last line of defence before commit/merge/deploy |
| **Distinguished-engineer tasks** | **Opus** | Always. Highest judgment bar by definition |
| **Architecture** (design + drawings + diagrams) | **Opus** | Cross-module reasoning; encodes system-wide decisions |
| **Planning / preparation** (/plan, /plan-tdd, scoping) | **Opus** | Always. Plan errors propagate into every downstream implementation step |
| **Making a goal** (/make-a-goal, goal prompts) | **Opus** | Always. The goal artifact drives an entire autonomous run |
| **Creating a workflow** (authoring the script) | **Opus** | Always. Workflow structure decides what every phase + agent does |
| **Workflow / swarm orchestration** (running it) | **Opus** | Always. The orchestrator's routing + sequencing decisions cascade to every worker |
| **Other documentation** (READMEs, API docs, guides) | **Sonnet** | Generation, low consequence |
| **Debugging — dev issues** | **Sonnet → Opus** | Start Sonnet, escalate to Opus on failure or if root cause is non-obvious |
| **Debugging — production issues** | **Opus** | Always. Production consequence overrides cost |
| **Security (any)** | **Opus** | Always |
| **Data migration / non-reversible** | **Opus** | Always |

## NEVER Use Haiku For

1. **Security checks** — misses are catastrophic and silent
2. **Output used for decisions** without mechanical verification
3. **Cross-file symbol resolution** — wrong file/method/struct picked confidently
4. **Constraint queries** — "usages that do NOT call X before Y" (negation handling weak)
5. **Code or doc generation** — extraction only, never generation
6. **Context > 50K tokens** — degradation accelerates and is silent
7. **Non-reversible actions** — file deletions, migrations, config changes
8. **Novel or domain-specific patterns** — pattern-matches to wrong training prior

## Haiku Silent Failure Modes

These NEVER trigger retry escalation — they look correct:

- **Multi-hop collapse**: A→B→C reasoning becomes A→C; step B silently dropped
- **Ambiguous symbol**: multiple structs with similar names → picks wrong one confidently
- **Novelty interpolation**: domain-specific architecture → fills in what "usually" happens
- **Negation inversion**: "NOT X before Y" constraint silently dropped or inverted
- **Plausible paraphrase**: function summary is grammatically correct, semantically wrong

## Advisor Mode (MANDATORY for Sonnet/Haiku subagents)

Any subagent running on **Haiku or Sonnet** MUST have its output validated by an
**Opus advisor** before the result is accepted. Scoped to that subagent's run only —
the advisor pass fires when the cheap-model subagent returns, not session-wide.

This closes the silent-failure gap. The retry ladder only fires on exceptions;
it cannot catch plausible-but-wrong answers. The Opus advisor reads the cheap
model's output adversarially and either accepts it or sends it back.

```
Sonnet/Haiku subagent runs task
        │
        ▼
   produces output
        │
        ▼
  Opus advisor reviews ──► reject → re-run (escalate model)
        │ accept
        ▼
   output accepted
```

**Rules:**
- Haiku subagent → Opus advisor pass, always
- Sonnet subagent → Opus advisor pass, always
- Opus subagent → no advisor (it IS the advisor tier)
- Advisor prompt is adversarial: "find what's wrong with this output; default to
  reject if you cannot verify correctness"
- On reject: re-run the task one tier up (Haiku→Sonnet, Sonnet→Opus), not same model
- Advisor scope = that subagent's output only, not the whole session

**Cost note:** the advisor pass adds one Opus call per cheap-model subagent run.
This is the price of intelligence-first. If the advisor cost approaches running
the task on Opus directly, skip the cheap model and run Opus from the start.

## Retry Ladder (Intelligence-First)

Two ladders depending on task class:

```
HAIKU-ELIGIBLE TASKS (verifiably mechanical):
  Attempt 1: Haiku
  Attempt 2: Sonnet + "previous answer may be subtly wrong, re-examine carefully: {error}"
  Attempt 3: Opus
  → Escalate to human

ALL OTHER TASKS (default):
  Attempt 1: Sonnet
  Attempt 2: Opus + error + examples
  → Escalate to human
```

**Critical**: escalation trigger must include semantic validation where possible,
not just exception detection. If output cannot be mechanically validated, do NOT
start at Haiku.

## Missing Routing Criteria (check these before routing)

| Dimension | Question | If YES → upgrade |
|-----------|----------|-----------------|
| Reasoning depth | Multi-hop inference required? | Sonnet+ |
| Ambiguity | Multiple plausible answers needing judgment? | Sonnet+ |
| Cross-file scope | Spans files, modules, crates? | Sonnet+ |
| Novelty | Outside mainstream patterns? | Sonnet+ |
| Consequence | Wrong answer catastrophic? | Opus |
| Output type | Generating (not extracting)? | Sonnet+ |
| Reversibility | Action undoable? | If no → Sonnet+ |
| Verifiability | Output mechanically checkable? | If no → Sonnet+ |
| Context size | > 50K tokens in context? | Sonnet+ |

## Prompt Caching Structure

Front-load stable content for Anthropic's 90% cache read discount (5-min TTL):

```
┌─────────────────────────────────────┐
│ STATIC: system prompt, CLAUDE.md    │  ← cached, rarely changes
│ STATIC: tool definitions            │
├─────────────────────────────────────┤
│ SEMI-STATIC: file contents (task)   │  ← cached per-task
│ SEMI-STATIC: docs, test results     │  ← DIRTY after write tool calls
├─────────────────────────────────────┤
│ DYNAMIC: user message, tool output  │  ← NOT cached, changes every turn
└─────────────────────────────────────┘
```

**Cache invalidation**: after any write tool call, treat file content as dirty.
Do not rely on cached file state after edits — re-read the file.

## Pricing Reference (per 1M tokens, USD)

| Model | Input | Output | Relative cost |
|-------|-------|--------|---------------|
| Haiku | $0.80 | $4.00 | 1× (baseline) |
| Sonnet | $3.00 | $15.00 | ~4× |
| Opus | $15.00 | $75.00 | ~19× |

Cost saving from routing Haiku-eligible tasks to Haiku: real, but secondary.
Never sacrifice quality for cost. A wrong Haiku answer costs more to debug than
running Sonnet in the first place.

## Implementation

```python
def route_to_model(task: str, complexity: str, criteria: dict) -> str:
    # Hard overrides first
    if criteria.get("high_consequence") or criteria.get("security"):
        return "opus"
    if criteria.get("non_reversible"):
        return "sonnet"  # minimum

    # Haiku only if ALL clear
    haiku_eligible = (
        not criteria.get("cross_file")
        and not criteria.get("judgment_required")
        and not criteria.get("novel_pattern")
        and not criteria.get("generation")
        and not criteria.get("unverifiable")
        and criteria.get("context_tokens", 0) < 50_000
        and complexity == "simple"
    )

    if haiku_eligible:
        return "haiku"

    if complexity in ("complex", "creative") or criteria.get("synthesis"):
        return "opus"

    return "sonnet"  # default
```

When spawning sub-agents:
- `model: "haiku"` — ONLY for pure retrieval (literal grep, file listing, known-format extraction)
- `model: "sonnet"` — default for all implementation, review, search-with-understanding
- `model: "opus"` — architecture, security, distinguished-engineer tasks, after sonnet fails
