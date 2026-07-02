---
name: make-a-goal
description: |
  Produce a fully-filled autonomous-run mega-prompt at .agents/goals/<slug>.md
  by interviewing the user for the missing context. The output file is the
  "set the goal · walk away · come back to shipped work" prompt — drop it
  into a fresh Claude Code / Codex session to run end-to-end without hand-
  holding. Use when Stevie says "/make-a-goal", "/make-a-goal <outcome>",
  "make a goal", "set a goal", "build me a goal prompt", or similar. The
  skill does NOT execute the goal — it only produces the artifact.
  Named `make-a-goal` (not `goal`) because `/goal` is a reserved system slash.
argument-hint: "[the final outcome — one line, optional]"
---

# /make-a-goal — autonomous-run mega-prompt builder

Interview for missing context, then write a filled mega-prompt to
`.agents/goals/<slug>.md`. Stevie runs it later by pasting that file into a
fresh session. This skill produces the artifact ONLY — never executes the run.
Caveman mode by default. Address user as **Stevie**.

## When NOT to use

| Situation | Route to |
|---|---|
| Stevie wants the goal EXECUTED now | Not this skill; paste an existing `.agents/goals/*.md` into a fresh session |
| Turn a plan into a spec, no autonomous run | `/plan` or `/interview` |
| Split one outcome into sub-goals | Only if explicitly asked; default is ONE goal |

## Bundled files (both must exist)

- `assets/mega-prompt.md.tmpl` — output template. Tokens: `{{OUTCOME}}`,
  `{{PROJECT}}`, `{{STACK}}`, `{{CURRENT_STATE}}`, `{{WORKING_DIR}}`,
  `{{CONSTRAINTS}}`, `{{AUDIENCE}}`, `{{SUCCESS_1}}`, `{{SUCCESS_2}}`, `{{SUCCESS_3}}`.
- `assets/stub-plan.md.tmpl` — stub handed to `/interview`. Token: `{{OUTCOME}}`.

## Runbook

1. **Get the outcome line.** If `$ARGUMENTS` non-empty, that IS the line → step 2.
   Else `AskUserQuestion`: "What does done look like — in one line?" Requirements:
   one sentence, present-tense, observable. Vague ("ship the app") → push back for
   specifics. Multi-sentence → ask Stevie to compress to one line first.

2. **Slug + paths.** Slug = kebab-case the outcome, strip stopwords, ≤50 chars
   (e.g. "deploy v1 of the dashboard with login" → `deploy-v1-dashboard-with-login`).
   `mkdir -p .agents/goals`. Paths: plan `<slug>.plan.md`, spec `<slug>.plan-spec.md`,
   goal `<slug>.md`. If `<slug>.md` exists → suffix `-2`, `-3`, ….

3. **Write stub plan.** Read `assets/stub-plan.md.tmpl`, sub `{{OUTCOME}}`, write to
   plan path. Leave it prescriptive — it tells `/interview` which fields to extract.

4. **Interview.**
   - `/interview` available → invoke it on `<slug>.plan.md`. It loops via
     `AskUserQuestion` until covered and writes `<slug>.plan-spec.md`. Do not re-drive its loop.
   - `/interview` NOT available → ask the field set (from `stub-plan.md.tmpl`)
     directly via `AskUserQuestion`, skip the spec artifact, jump to step 6.

5. **Map spec → fields, fill gaps.** Read `<slug>.plan-spec.md`, extract:

   | Field | Spec source |
   |---|---|
   | `{{PROJECT}}` | Objectives → Primary Goals |
   | `{{STACK}}` | Technical Requirements → Components / Architecture |
   | `{{CURRENT_STATE}}` | Implementation Notes · context paragraphs |
   | `{{WORKING_DIR}}` | Constraints · often absent |
   | `{{CONSTRAINTS}}` | Constraints & Dependencies |
   | `{{AUDIENCE}}` | User Experience intro · often absent |
   | `{{SUCCESS_1..3}}` | Objectives → Success Metrics |

   Then at most ONE more `AskUserQuestion` round for unfilled fields:

   | Condition | Action |
   |---|---|
   | `WORKING_DIR`/`AUDIENCE`/`CURRENT_STATE` thin | Ask only those; never re-ask what spec answered |
   | Working dir = "this repo" | Substitute absolute `$PWD`, not the literal string |
   | >3 success metrics | Ask which 3 are the hard-gates for "done" |
   | <3 success metrics | Ask for the rest — 3 is the template minimum |

6. **Render.** Read `assets/mega-prompt.md.tmpl`, sub every `{{FIELD}}`. Multi-line
   values into single-line slots → join with `; `. Write to `<slug>.md`.
   DO NOT touch the **Operating Rules / Quality Bar / Final Deliverable** blocks —
   verbatim, non-negotiable across every run.

7. **Report.** Give Stevie: absolute goal path, absolute spec path (to revise
   context without re-interviewing), the run instruction ("paste `<slug>.md` into
   a fresh Claude Code or Codex session"), and the slug.

## Non-goals

- **No execution.** Artifact only.
- **No setup-as-goal.** Secrets, tokens, IDs, provisioning → context/constraints.
  Goal line stays at outcome level; the executing agent works out steps.
- **No mini-goals by default.** If the outcome came from another agent/person,
  recover it and render ONE goal unless Stevie asks to split.
- **No committing `.agents/goals/`** — leave to Stevie.
- **No editing the verbatim template blocks.**
