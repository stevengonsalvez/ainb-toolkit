# Stage workflow templates

Each pipeline stage launches one ultracode `Workflow`. These are shapes, not
verbatim scripts — parameterise from the charter (model policy, paths, epic
scope). Every template shares the GROUND preamble pattern:

```js
const ground = `READ FIRST: <charter path> (doctrine + commit policy) and
<stage input artifacts>. Branch: <branch>. Env/creds: <session env file>.
COMMIT POLICY: atomic single-concern commits, conventional, named paths,
no AI attribution. NEVER commit .agents/, explainers/, scratch, env files.
(The refs/godmode/* sidecar is hook-maintained; workflows never touch it.)`
```

Rules that apply to every stage script:
- `export const meta = {...}` pure literal, phases matching `phase()` calls.
- Pass model per charter policy via `opts.model` / `opts.agentType`.
- Schemas (`opts.schema`) for every verdict/validation agent — no parsing prose.
- On completion the DRIVER (not the workflow) persists artifacts, verifies
  commits, advances state. Workflows return data; the driver owns state.
- Every creative stage receives a `creative_quorum` route and returns two
  independent proposals plus a synthesis receipt. If route status is deferred,
  do not invent a solo creative result.

These scripts run inside the `Workflow` tool — `agent()`, `parallel()`,
`pipeline()`, `phase()`, `log()` are the tool's built-ins (no imports).
Before launching, resolve every placeholder: `BRAIN` / `BUILD_MODEL` are
model-name strings from the charter policy; `REVIEW_SCHEMA` /
`VERDICTS_SCHEMA` / `VAL_SCHEMA` must be defined as literal JSON Schema
objects at the top of the script. A script with an unresolved placeholder is
a bug, not a convention.

## Discover

Purpose: create the feature REGISTRY the Court consumes. Pair the host primary
with its routed creative peer, then synthesise evidence and dissent:

```js
phase('Discover')
const proposals = await parallel(CREATIVE_QUORUM.models.map(model => () => agent(`${ground} You are the DISCOVERY brain. North
  star: <north-star>. (1) Scan the repo (structure, manifests, existing docs/
  backlog/beads) to understand what exists. (2) Brainstorm the NIRVANA feature
  landscape — beyond MVP, end-game thinking: every capability a finished
  product would have, grouped by space. Append any user-supplied feature list
  verbatim (marked user-requested). (3) WRITE .agents/plans/<slug>-registry.md
  as a numbered table: id, name, one-line description, space, rough tier.
  Aim wide — the Court prunes, you don't.`, {model, effort:'high'})))
const registry = await agent(`${ground} Synthesize these independent proposals.
  Preserve disagreement, cite evidence, score confidence, and reject any idea
  lacking a value hypothesis: ${proposals}`, {model: CREATIVE_QUORUM.synthesizer,
  schema: REGISTRY_SCHEMA, effort:'high'})
```

Replenishment runs after every ship. In perpetual mode, an empty critic result
sets `lanes.discovery.status: backoff` and a future `next_at`; it never marks
the programme DONE. New candidates enter the Court as generation N+1.

## Feasibility Court (W0)

Purpose: every registry feature → grounded verdict.

```js
// fan out: one grounding agent per feature CLUSTER (5-8 features each,
// sonnet, effort low) → read the real code/data the feature needs
// then: both creative peers judge each cluster, synthesis preserves dissent
phase('Ground')
const evidence = await parallel(clusters.map(c => () =>
  agent(`${ground} Ground these features against the REAL tree: ${c.list}.
  For each: does the data/API/schema it needs exist? Cite files. NO opinions,
  only evidence.`, {model:'sonnet', effort:'low', phase:'Ground'})))
phase('Judge')
const verdicts = await parallel(clusters.map((c,i) => () =>
  parallel(CREATIVE_QUORUM.models.map(model => () => agent(`${ground} You are the Feasibility Court. Evidence:\n${evidence[i]}\n
  Verdict per feature: SHIP-ABLE (tier) | DOWNGRADE (to what, why) |
  PARK (named blocker). Be ruthless about missing prerequisites.`,
  {model, schema: VERDICTS_SCHEMA, phase:'Judge'})))))
return verdicts
```

Driver afterwards: write the verdict table into the registry artifact.

## Roadmap (W1)

Creative quorum synthesis clusters ship-able features into epics with
dependency order, size, validation scenarios, and confidence. Driver seeds
beads. Only `approval_policy: roadmap` waits for blessing; perpetual mode
continues immediately.

## Plan (W2) — per epic (or blessed pair in one workflow via parallel())

```js
async function planEpic(slug, scope) {
  const plan = await agent(`${ground} You are the PLANNER for EPIC ${slug}.
    ${scope} WRITE .agents/plans/epic-${slug}-plan.md (file-level,
    dependency-ordered tasks with repo-constraint flags, validation section
    naming suites/scenarios) and .agents/goals/epic-${slug}.md. GROUND every
    task in real code — read the files you plan to change.`,
    {model: BUILD_MODEL, effort:'high'})
  const review = await agent(`${ground} Adversarially review the plan as the
    sceptical staff engineer. Hunt: wrong assumptions about existing code
    (VERIFY in-repo — prior runs caught already-fixed bugs and nonexistent
    functions), stale backlog claims, missing repo constraints, scope creep,
    unrunnable validation (check fixtures/env). Cite evidence.`,
    {model: BRAIN, schema: REVIEW_SCHEMA, effort:'high'})
  if (review.findings.some(f => f.severity !== 'low'))
    await agent(`${ground} Fold findings into BOTH artifacts IN PLACE (Edit) —
      plan AND goal file. Return what changed in EACH file.`,
      {model: BUILD_MODEL, effort:'high'})
  return { plan: plan.slice(0, 800), findings: review.findings.length,
           verdict: review.verdict }
}
```

DRIVER MUST then verify the revise actually edited the plan files
(mtime/content vs findings) — see lessons.md ("revise patched the wrong file").

## Execute (W3) — per epic

Shape (sequential workstreams; parallel only with disjoint file-sets):

```js
phase('Build <ws>')            // per workstream from the plan
  build  = agent(builder prompt, {model: BUILD_MODEL, effort:'high'})
  pair   = agent(codex pair-review prompt, {agentType:'codex:codex-rescue'})
phase('Review')
  review = agent(adversarial epic diff review, {model: BRAIN, schema: REVIEW_SCHEMA})
  if (high/medium) fix = agent(fixer, {model: BUILD_MODEL})
phase('Verify')                // sonnet runner; see verify-lanes.md
  val = agent(verifyPrompt, {model:'sonnet', schema: VAL_SCHEMA})
  while (!val.passed && fixes < 2) { fixer; re-verify }   // bounded fix loop
return {review, validation: val, fixCycles}
```

Verify-prompt essentials (bake in — each averts a known failure, lessons.md):
- First diff the epic against its base for backend/infra changes; if present,
  deploy/apply them to the validation backend BEFORE running scenarios (and
  respect the repo's deploy flags — e.g. never strip JWT verification).
- Run every suite the plan names + the programme's regression spine.
- Build gate: run UNPIPED to a log (`cmd > /tmp/x.log 2>&1`), report EXIT.
  If the agent's window closes mid-build, report INCONCLUSIVE — the driver
  re-runs the build itself, backgrounded, and gates the ship on EXIT=0.
- Report honestly: pre-existing failures proven via merge-base diff are
  reportable as such, never silently absorbed.

## SHIP (driver, not a workflow)

1. Re-run/confirm build gate (EXIT=0). 2. Push epic branch; PR stacked on the
previous epic's branch; body = what+why+validation evidence+review catches;
apply the review label via REST (`gh api .../labels`). 3. Close epic +
folded-feature beads with evidence notes (scripts/beads_remote.sh). 4. Update
state.json (hooks publish the dashboard), then write the phase explainer and
publish via explainer-publish.sh (its receipt clears the Stop gate); next
epic's branch created FROM this one.

## Regression and repair (driver)

After every epic verification passes, queue `lanes.regression` against the
candidate merge commit in an isolated worktree. Run the entire cumulative
regression spine plus affected real-surface lanes. Discovery and planning may
continue while it runs. A failure becomes a confirmed defect only after
reproduction, root-cause evidence, and a durable test or real-surface proof.
Confirmed defects pause the mutation owner, create a repair incident, repair
and re-verify, then rebase and resume paused work. Auto-merge happens only
after this lane passes.
