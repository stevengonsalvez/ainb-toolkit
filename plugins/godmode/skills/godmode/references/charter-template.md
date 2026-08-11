# Charter template — the programme constitution

Write to `.agents/goals/<slug>-charter.md`. Fill every `{{...}}`. The driver
re-reads this file every tick; nothing in it is decorative. Keep it under ~120
lines — it is loaded constantly.

```markdown
# /godmode {{PROGRAMME TITLE}} — CHARTER (the constitution)

Every loop iteration re-reads this file. It is the source of truth for how the
programme runs. Base branch: {{BASE_BRANCH}}. Worktree: {{WORKTREE_PATH}}.

— MODE AND AUTHORITY —
· Mode: {{finite | perpetual}}. Approval policy: {{none | roadmap}}.
· Provider capability receipts: {{scheduler + peer-model adapters per host}}.
· External integration authority: {{configured integrations only}}.
· Production policy: {{progressive rollout, health signals, automatic rollback}}.

— OUTCOME —
{{North-star restated as terminal states: every feature in the registry
({{REGISTRY_PATH}}) either SHIPPED with green verification, or explicitly
parked with a Feasibility Court verdict (downgraded tier + named blocker).
Fold in any pre-existing backlog items by ID with their required disposition.}}

— PIPELINE (state machine per epic) —
Creative-quorum Discover → Feasibility Court ({{once | every generation}}) →
Roadmap + epic beads → {{optional roadmap approval}} → per epic: Plan (planner →
adversarial review → revise → verify-the-revise) → Execute (build-pair →
pair review → adversarial epic review → VERIFY → fix loop ≤2 → build gate)
→ full cumulative regression → auto-merge when all declared checks pass.
One mutation owner at a time. Regression and discovery may run in parallel.
Confirmed defects preempt mutation, become repair incidents, then resume paused
work after re-verification and rebase.

— MODEL POLICY —
· CREATIVE QUORUM = {{Claude primary + codex:codex-rescue | Codex primary +
  Claude Fable | two Copilot models, enriched by Claude or Codex}}. Record
  both proposals, evidence, dissent, synthesis, and availability receipt.
· One available model means defer creative work, never invent a solo verdict.
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
· NEVER commit: charter, state, dashboard html, scratch, env files. Exception:
  the sidecar mirror on refs/godmode/{{slug}} is hook-maintained via plumbing.

— LIVE DASHBOARD —
· {{DASHBOARD_URL}} (slug {{SLUG}}, password {{PASSWORD|none}}, entry added to
  the existing root index). Local file: explainers/{{slug}}.html.
· HOOK-OWNED: every state.json write renders + republishes it (PHASE chip,
  RAG per epic + feature, testing table, commit log, evidence links). Keep
  state.json truthful; write current_note; that IS the dashboard duty.

— LOOP PROTOCOL (each wake) —
1. Read charter + state. 2. Validate with `programme_policy.py validate-state`.
3. Check running work and `next-action`; launch regression after ship, repair
after confirmed incident, and next discovery while mutation is occupied. 4.
Refresh lease. 5. Update beads, state, audit receipts, and dashboard. 6.
Schedule next wake with adaptive research backoff when Court is empty.
· STOP RULES: budget or deadline | security | production-safety after rollback |
  lost lease | missing required authority. Repeated ordinary failure is bounded
  retry plus quarantine, not a global stop.

— TERMINATION —
Finite: {{backlog-dry | budget | deadline}}. Perpetual: {{budget | deadline |
safety}}. In perpetual mode backlog-dry queues cited adaptive research and the
next generation. Hard stop posts final summary, incident evidence, and alert.

— SUCCESS CRITERIA (ALL MUST BE TRUE) —
1. Every candidate has two creative views, evidence, and Court verdict.
2. Every epic: plan + review + execution + verification + cumulative regression
   green + auto-merge receipt; parked features carry verdicts.
3. Dashboard live and updated throughout.
4. Evidence exists for every closed epic (suite output, artifacts, PR links).

— OPERATING RULES — NON-NEGOTIABLE —
1. PLAN FIRST per epic. 2. WORK AUTONOMOUSLY (optional approval + safety stops).
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
