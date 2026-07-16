# Charter template — the programme constitution

Write to `.agents/goals/<slug>-charter.md`. Fill every `{{...}}`. The driver
re-reads this file every tick; nothing in it is decorative. Keep it under ~120
lines — it is loaded constantly.

```markdown
# /godmode {{PROGRAMME TITLE}} — CHARTER (the constitution)

Every loop iteration re-reads this file. It is the source of truth for how the
programme runs. Base branch: {{BASE_BRANCH}}. Worktree: {{WORKTREE_PATH}}.

— OUTCOME —
{{North-star restated as terminal states: every feature in the registry
({{REGISTRY_PATH}}) either SHIPPED with green verification, or explicitly
parked with a Feasibility Court verdict (downgraded tier + named blocker).
Fold in any pre-existing backlog items by ID with their required disposition.}}

— PIPELINE (state machine per epic) —
Feasibility Court (once{{, SKIPPED via --no-court}}) → Roadmap + epic beads
(once) → [HUMAN GATE: roadmap blessing] → per epic: Plan (planner →
adversarial review → revise → verify-the-revise) → Execute (build-pair →
pair review → adversarial epic review → VERIFY → fix loop ≤2 → build gate)
→ epic bead closed only when verification green → stacked PR.
Epics serial on stacked branches unless blessed-parallel AND provably disjoint.

— MODEL POLICY —
· BRAIN (brainstorm / roadmap orchestration / adversarial review) = {{fable |
  <fallback: strongest Claude + codex pair>}}
· BUILD = {{opus}} + {{codex:codex-rescue}} pair; disagreements surfaced.
· TEST/VALIDATE = {{sonnet}}. SCAFFOLD = {{sonnet}}.

— VERIFICATION DOCTRINE —
· Surface lane(s) for this programme: {{web | tui | api | library — list, with
  any forced overrides}} per godmode references/verify-lanes.md.
· Mock ONLY the human at the input boundary; assert real outputs + side
  effects ({{name the concrete side-effect stores: DB tables, files, queues}}).
· Expensive/flaky transduction ({{STT/TTS/OCR/none}}) proven ONCE, then text.
· Live validation backend: {{name it + how migrations/deploys get onto it —
  and what is FORBIDDEN (e.g. never db push/link; Mgmt-API sql() only)}}.
· Evidence uploaded to here.now, linked from the dashboard Evidence tab.

— COMMIT POLICY —
· Atomic single-concern conventional commits, named paths only, no AI
  attribution. {{Signing rule for this machine.}}
· One PR per epic, labelled {{REVIEW_LABEL}}, stacked on the previous.
· NEVER commit: charter, state, dashboard html, scratch, env files.

— LIVE DASHBOARD —
· {{DASHBOARD_URL}} (slug {{SLUG}}, password {{PASSWORD|none}}, entry added to
  the existing root index). Local file: explainers/{{slug}}.html.
· Refreshed EVERY tick: PHASE chip, RAG per epic + feature, testing table,
  full commit log (sha+message, newest first), evidence links.

— LOOP PROTOCOL (each wake) —
1. Read this charter + .agents/scratch/{{slug}}-state.json. 2. Check running
workflow; on completion persist artifacts, verify commits, advance the state
machine, launch the next stage. 3. Refresh + republish dashboard. 4. Update
beads + state. 5. ScheduleWakeup ~600s, reason = current phase.
· STOP RULES: workflow errors ×2 same stage | validation fails ×3 one epic |
  any prod/staging touch | epic > {{TOKEN_CAP|~15M}} subagent tokens.

— TERMINATION —
{{backlog-dry (default) | budget: N subagent tokens total | deadline: ISO}}
— first bound to fire wins; on termination post a final summary, PushNotification,
and stop re-arming the loop.

— SUCCESS CRITERIA (ALL MUST BE TRUE) —
1. Every registry feature has a Court verdict recorded.
2. Every blessed epic: plan artifact + reviewed + executed + verification
   green + PR raised; parked features carry verdicts.
3. Dashboard live and updated throughout.
4. Evidence exists for every closed epic (suite output, artifacts, PR links).

— OPERATING RULES — NON-NEGOTIABLE —
1. PLAN FIRST per epic. 2. WORK AUTONOMOUSLY (one human gate + stop rules).
3. SELF-VERIFY every step. 4. DEBUG YOURSELF. 5. NO PLACEHOLDERS in shipped
code. 6. PROGRESS LOG (dashboard + beads). 7. STAY ON GOAL. 8. IF BLOCKED,
log + continue parallelizable work. 9. CHECK SUCCESS BEFORE STOPPING.
```

## Filling guidance

- OUTCOME: enumerate terminal states, not activities. If a backlog tracker
  (beads) exists, name the specific pre-existing item IDs the programme absorbs.
- VERIFICATION: name the actual backend and the actual forbidden operations for
  this repo — copy them from the project's CLAUDE.md/MEMORY, don't invent.
- Record any already-fixed / stale items discovered during Court directly in
  the OUTCOME section as "CLOSED as already-fixed — do NOT re-fix" with the
  evidence, so no later stage regresses them (see lessons.md).
