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
| `/godmode run [--take-over]` | Resume/continue the loop from state (any session, incl. post-crash). Claims the driver lease first: refuses while another session's lease is fresh, auto-claims a stale one, `--take-over` forces after an AskUserQuestion confirm. On a fresh machine: `sync.sh discover`, pick the slug, claim, then `sync.sh adopt <slug>` reconstructs local state |
| `/godmode status` | Standup: read state + beads + dashboard + lease, report, change nothing. NEVER adopts (observer-safe: no scratch state means hooks stay inert). Preflight prints "status publishing DISABLED: missing <X>" when here-now/credentials are absent |
| `/godmode pause` | Stop re-arming the loop; state stays resumable; release the lease (`lease.sh release`) |

## Provider parity

| Capability | Claude | Codex | Copilot |
|---|---|---|---|
| init / run (drive the loop) | full | refuse + status message | refuse + status message |
| status / discover | yes | yes | yes |
| dashboard publish + sidecar sync + lease guard | all hooks | hooks.json (shared format) | sessionStart pull + staleness nudge only |

## The three-layer machine

```
LAYER 1  CHARTER   .agents/goals/<slug>-charter.md   — constitution, re-read EVERY tick
LAYER 2  DRIVER    /loop dynamic mode                — ScheduleWakeup ~600s, same prompt re-entered
LAYER 3  WORKFLOWS one ultracode Workflow per stage  — resumable via resumeFromRunId
STATE    beads (epic/feature nodes) + .agents/scratch/<slug>-state.json (working
         copy) + hook-maintained sidecar mirror {state,charter,lease} on the
         dedicated ref refs/godmode/<slug> (cross-machine; GODMODE_SYNC=local opts out)
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
   `references/state-and-beads.md`) with `driver_session_id: null` and a
   `phase_since` timestamp. You cannot know your own session_id: the
   PostToolUse hook fills `driver_session_id` from the hook event on this very
   write (first-writer-wins), which is why the write must precede the claim.
   Then claim the driver lease:
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lease.sh claim <repo> <slug>`.
4. Dashboard publishing is HOOK-OWNED: every state.json write triggers
   render + publish + sidecar push (PostToolUse). Your duties: keep
   state.json truthful, write `current_note`, pick a stable
   `dashboard_slug`. Publish failure never blocks (pending marker +
   dashboard banner; hooks retry on the next state write).
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
3. Heartbeat + lease: run `${CLAUDE_PLUGIN_ROOT}/scripts/lease.sh refresh`
   EVERY wake, state changed or not (quiet multi-tick workflows must not
   starve the lease). Exit 5 or a `<slug>-lease-lost` marker: post a handoff
   note, downgrade to read-only, do NOT re-arm. The dashboard republishes
   itself on every state write (hook-owned); a pending-publish marker means
   degraded publishing, mention it and keep going.
4. Update beads (recipes in `references/state-and-beads.md`), state.json, and
   the token ledger (accounting rules in the same file — fail CLOSED if spend
   is unmeasurable under a --budget). state.json writes go through the
   Write/Edit TOOL only (Non-negotiables). On a phase flip also stamp
   `phase_since`; after SHIP / HUMAN_GATE / DONE write the phase explainer
   (/explain-to-me) and publish it via
   `${CLAUDE_PLUGIN_ROOT}/scripts/explainer-publish.sh` (the Stop gate blocks
   your stop until its receipt exists).
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

- `scripts/beads_remote.sh` (skill-local) — close/annotate beads on origin/main
  via git plumbing without touching any checkout (safe under concurrent worktrees)
- Plugin scripts at `${CLAUDE_PLUGIN_ROOT}/scripts/`:
  `render_dashboard.py` (deterministic dashboard) · `on-state-write.sh`
  (PostToolUse pipeline) · `explainer-publish.sh` (receipt writer, the ONLY
  sanctioned explainer publish path) · `explainer-gate.sh` (Stop gate) ·
  `sync.sh` (pull|push|adopt|discover) · `lease.sh` (claim|refresh|check|release)
  · `sidecar_remote.sh` (refs/godmode/<slug> plumbing) · `staleness-note.sh`
  (Copilot nudge)

## Non-negotiables

- Commit policy: atomic single-concern commits, conventional, named paths only
  (never `git add -A`), no AI attribution, never commit charters/state/
  dashboards/scratch/env files, EXCEPT the sidecar mirror on
  `refs/godmode/<slug>`, which hooks maintain via git plumbing. Sign only when
  the gpg cache is warm; never spawn GUI pinentry headless.
- state.json is written ONLY via the Write/Edit tool, never Bash
  redirection/jq/mv: the status and heartbeat hooks key on the PostToolUse
  event (belt: the Stop-hook heartbeat entry; a Bash-written state file means
  a silently stale dashboard and a starving lease).
- Plugin version policy: ANY change under `plugins/godmode/**` bumps at least
  the patch version, all three provider manifests together.
- The dashboard is not optional and never goes stale past one tick.
- Stale-work check: before fixing any backlog item, verify it isn't already
  fixed in-tree (`git log/show` + live probe). Close-with-citation beats re-fix.
- Build gates run UNPIPED to a log file, backgrounded, gated on `EXIT=0`.
