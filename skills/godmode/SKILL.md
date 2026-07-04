---
name: godmode
description: "Autonomous product factory — /make-a-goal in godmode. Point it at a north-star outcome and it runs the whole delivery machine unattended: brainstorm the feature landscape (Discover), put every idea through a Feasibility Court, cluster into a Roadmap of epics, then per epic Plan → adversarial review → Execute (model-paired build) → VERIFY (drive the real UI/TUI/API, not mocks) → ship a stacked PR, looping until the backlog is dry or a budget/time bound fires. One human gate (roadmap blessing), hard stop rules, always-on tabbed RAG dashboard, crash-proof resume from state files. Use when the user says 'godmode', 'run the factory', 'ship X to nirvana', 'execute this whole backlog autonomously', 'goals within goals', or wants a multi-epic programme driven end-to-end with real end-to-end verification. NOT for single features, one-off verification, or scoped builds — use /make-a-goal, browser/tmux verification skills, or a plain plan for those."
---

# godmode — the autonomous product factory

A runtime orchestrator that OWNS the loop. It composes existing machinery —
`/loop` (driver), `Workflow` (staged ultracode), beads (state), `/here-now`
(dashboard hosting), `tmux-verify`/browser-harness/Playwright (verify lanes) —
into one self-driving programme. You are the driver each tick; these files are
your constitution and playbooks.

## Entry modes

| Invocation | Action |
|---|---|
| `/godmode <north-star> [--no-court] [--budget <tokens>] [--deadline <ISO>] [--fable off]` (alias: `/godmode init <north-star> ...`) | INIT: generate charter + state + dashboard + beads, run Feasibility Court + Roadmap, present roadmap at the human gate |
| `/godmode run` | Resume/continue the loop from state (any session, incl. post-crash) |
| `/godmode status` | Standup: read state + beads + dashboard, report, change nothing |
| `/godmode pause` | Stop re-arming the loop; state stays resumable |

## The three-layer machine

```
LAYER 1  CHARTER   .agents/goals/<slug>-charter.md   — constitution, re-read EVERY tick
LAYER 2  DRIVER    /loop dynamic mode                — ScheduleWakeup ~600s, same prompt re-entered
LAYER 3  WORKFLOWS one ultracode Workflow per stage  — resumable via resumeFromRunId
STATE    beads (epic/feature nodes) + .agents/scratch/<slug>-state.json
```

## Pipeline (stage names are the primary vocabulary; W-numbers are aliases)

```
DISCOVER                 once   BRAIN brainstorms the nirvana landscape from the
        │                       north-star + a repo scan + any existing backlog →
        │                       writes the feature REGISTRY (.agents/plans/<slug>-registry.md).
        │                       User-supplied feature lists are appended, not replaced.
        ▼
FEASIBILITY COURT (W0)   once   every REGISTRY idea → verdict: feasible | downgrade | park+blocker
        │                       skipped only by explicit --no-court (registry taken verbatim)
        ▼
ROADMAP (W1)             once   cluster survivors → ordered epics + parallel-pair candidates,
        │                       seed beads (one per epic + per feature)
        ▼
[HUMAN GATE]                    the ONLY interactive gate: user blesses the roadmap
        ▼                       (may authorise parallel epic pairs)
per epic, serial on stacked branches:
   PLAN (W2)      planner → adversarial review → revise → VERIFY THE REVISE EDITED THE
        │         PLAN FILES (mtime/content) — see references/lessons.md
        ▼
   EXECUTE (W3)   build (model pair per workstream) → pair review → adversarial epic
        │         review (+fix) → VERIFY (surface lane, references/verify-lanes.md)
        ▼         → bounded fix loop (≤2) → build gate (unpiped!)
   SHIP           stacked PR (labelled for review) → close epic+feature beads with
        │         evidence notes → dashboard update
        ▼
TERMINATION       backlog-dry (default) | --budget exhausted | --deadline reached
                  — first to fire wins; post final summary + PushNotification, stop loop
```

Backlog replenishment: after each epic ships, a BRAIN completeness-critic pass
("what would a user still complain about — modality unrun, claim unverified?")
may append new features to the REGISTRY; they enter the Court like any other.
Backlog-dry means the critic comes back empty too.

Parallel epics: allowed ONLY if blessed AND file-sets provably disjoint AND
worktrees available; otherwise serialise (single worktree = single checkout).

## INIT procedure

1. Parse the north-star + flags. Derive `<slug>`.
2. Generate the charter from `references/charter-template.md` — fill outcome,
   model policy (resolve fable toggle), verify doctrine, termination, stop
   rules, dashboard slug. Write `.agents/goals/<slug>-charter.md`.
3. Write `.agents/scratch/<slug>-state.json` (schema:
   `references/state-and-beads.md`).
4. Copy `assets/programme-dashboard.html` → `explainers/<slug>.html`, fill
   the `{{...}}` placeholders, publish:
   `bash {{HOME_TOOL_DIR}}/skills/here-now/scripts/publish.sh explainers/<slug>.html
   --slug <slug> --api-key <here.now token from the user's memory/keychain>`
   (stable slug; password-protect if the project demands; ADD an entry to the
   existing root index — never create a new index). Publish failure never
   blocks: keep the local file fresh, retry next tick.
5. Run DISCOVER (template: `references/stage-workflows.md`) → writes the
   registry. Then, unless `--no-court`, the Feasibility Court workflow, then
   Roadmap. With `--no-court`: registry taken verbatim, straight to Roadmap.
6. Present the roadmap to the user (HUMAN GATE), set state
   `human_gate: "pending"`, PushNotification ONCE — and do NOT arm the loop.
   Blessing arrives as a user message; it re-enters via `/godmode run`, which
   sets `human_gate: "blessed"` and starts the loop.

## LOOP protocol (every wake — this is the driver contract)

1. Read the charter + state.json. They outrank your memory of last tick.
   If `human_gate` is `"pending"`: do NOT re-arm — the gate was already posted;
   wait for the user (see INIT step 6).
2. Check the running workflow (task output file / TaskList). If done: read its
   result AND its journal if the result looks off; persist artifacts; verify
   commits landed per the commit policy; advance the state machine (consult
   `bd ready` for dependency order when picking the next epic); launch the
   next stage workflow.
3. Refresh + republish the dashboard (every tick, even timestamp-only). If
   the host is unreachable: keep the local file fresh, retry next tick, never
   block the factory on publishing.
4. Update beads (recipes in `references/state-and-beads.md`), state.json, and
   the token ledger (accounting rules in the same file — fail CLOSED if spend
   is unmeasurable under a --budget).
5. Re-arm: ScheduleWakeup ~600s, reason = current phase, prompt = the DRIVER
   RE-ENTRY PROMPT verbatim (below). Honour STOP RULES first.

### Driver re-entry prompt (the exact string for every ScheduleWakeup)

```
/godmode run — programme charter: .agents/goals/<slug>-charter.md, state:
.agents/scratch/<slug>-state.json. Follow the charter's LOOP PROTOCOL exactly.
```

Never improvise a different prompt; this string is what makes every future
wake re-enter this skill and re-read the constitution.

## STOP RULES (halt the loop + page the human)

Page = PushNotification + a red banner note on the dashboard, then stop
re-arming. Triggers:

- A workflow errors twice on the same stage.
- Validation fails 3 consecutive runs on one epic.
- PRODUCTION is untouchable, always. The validation backend named in the
  charter is writable ONLY via the charter's stated mechanism; any write
  outside that list (or any production write at all) = STOP.
- Per-epic token spend exceeds the charter cap (default ~15M subagent tokens),
  or budget spend is unmeasurable while a --budget is set.

## Model policy (defaults; charter may override any line)

| Role | Default | Fallback |
|---|---|---|
| BRAIN — brainstorm, roadmap orchestration, adversarial review | fable | `--fable off` or unavailable → opus-4.8 + `codex:codex-rescue` pair |
| BUILD | opus + codex pair (`codex:codex-rescue` agentType), disagreements surfaced not silently resolved | charter override |
| TEST / VALIDATE | sonnet | charter override |
| SCAFFOLD / mechanical | sonnet | charter override |

## VERIFY (≠ validate — the point of this skill)

Auto-detect the epic's surface from touched files + project manifest, then run
the mandated lane from `references/verify-lanes.md`:
Web UI → real-browser drive · TUI → tmux+VHS frame-truth · API → real requests
+ side-effect asserts · library → unit+property(+mutation).
Cross-cutting: mock ONLY the human at the input boundary; READ the artefact
(never blank-check); evidence uploaded to here.now and linked from the
dashboard Evidence tab AND the PR body. Per-epic human review is PASSIVE —
the PR + dashboard notify; it never blocks the loop. The roadmap blessing is
the only blocking gate.

## References (load when you reach that step)

- `references/charter-template.md` — the constitution scaffold (INIT step 2)
- `references/stage-workflows.md` — Court/Roadmap/Plan/Execute Workflow script templates (each stage launch)
- `references/verify-lanes.md` — surface detection + the four proof playbooks (Execute's VERIFY step)
- `references/state-and-beads.md` — state.json schema, beads JSONL plumbing, resume procedure
- `references/lessons.md` — hard-won operational catches; consult BEFORE authoring any stage workflow and whenever a stage result looks wrong

## Scripts

- `scripts/beads_remote.sh` — close/annotate beads on origin/main via git
  plumbing without touching any checkout (safe under concurrent worktrees)

## Non-negotiables

- Commit policy: atomic single-concern commits, conventional, named paths only
  (never `git add -A`), no AI attribution, never commit charters/state/
  dashboards/scratch/env files. Sign only when the gpg cache is warm; never
  spawn GUI pinentry headless.
- The dashboard is not optional and never goes stale past one tick.
- Stale-work check: before fixing any backlog item, verify it isn't already
  fixed in-tree (`git log/show` + live probe). Close-with-citation beats re-fix.
- Build gates run UNPIPED to a log file, backgrounded, gated on `EXIT=0`.
