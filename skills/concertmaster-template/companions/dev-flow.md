---
name: dev-flow
description: Five-step flow for delivering one issue or bead in a single session: research, plan with Given/When/Then acceptance criteria, implement, validate every criterion with evidence, ship to merge-ready. Cheap enough for Sonnet or Haiku to follow. Use when the dev-sweeper or any session is handed an issue or bead to deliver, or when asked to "run dev-flow". Calls no other phase skill, only /commit and /ready-to-ship; every other step is inline here (escalation commands excepted). Template copy: place at .agents/skills/dev-flow/SKILL.md and fill the two project lines marked PROJECT.
argument-hint: "<issue|bead> [--autonomous]"
---

# Dev flow

One session, one item, five steps. No other phase skill is called except `/commit`
(step 3) and `/ready-to-ship` (step 5); only the escalation commands below add to that. Item = GitHub issue or bead; an issue
without a bead gets one under your lane's epic (`bd create --external-ref gh-<n> --parent <epic>`).

1. **Research.** Read the issue and the code it touches. Write 10 lines or fewer:
   what exists, what is wrong, what to reuse. `bd update <id> --notes "<text>"`.
2. **Plan.** `bd update <id> --design "<files to change, one per line>"` and
   `--acceptance "<1 to 5 criteria>"`, each `Given <state> When <action> Then <outcome>
   [evidence: screenshot | command]`. A criterion you cannot check with evidence is
   not a criterion. Stuck or unclear here: escalate (below).
3. **Implement.** One branch per item, from `origin/main`. Touch only the planned files; a new file is a plan change, update
   `--design` first. Small, single-concern commits via `/commit` (signed, conventional,
   no AI mention). PROJECT: apply the terminology rules from the concertmaster
   config (`terminology.rules`) to user-facing text.
4. **Validate.** Check each criterion and record pass or fail with evidence:
   UI = screenshot of the PR preview deployment (PROJECT: name the CI job that
   builds it, and when a manual preview deploy is allowed); backend, cron or SQL =
   command output (curl, SQL on local or staging, read-only). Never production.
   Unit tests never count as validate. Put a table (criterion, result, evidence)
   in the PR body. A failing criterion goes back to step 3, recheck only that
   one. Two retries; the third failure escalates with the evidence.
5. **Ship.** Open a non-draft PR, let CI run, then `/ready-to-ship` (review loop,
   comment fixes, preview E2E) until it reports merge-ready. Set the worktree
   comment `cm:merge-ready #<pr> <sha12>` (or the format your lane brief gives, as the
   dev-sweeper's `ready:` list) and stop this item. Never merge or deploy. Leave the
   bead open: `bd update <id> --status in_progress --notes "waiting on merge #<pr> <sha12>"`.
   The epic owner closes it after the merge (your lead, per its brief; with no lead,
   you, when told the PR merged). Never close it at merge-ready; never ask the
   concertmaster or pr-sweeper to close it.

```text
research ─▶ plan ─▶ implement ─▶ validate ─▶ ship
             │ stuck    ▲  fail     │  (2 retries, 3rd fail escalates)
             ▼          └───────────┘
        escalation table
```

## Escalation

| situation | normal | `--autonomous` |
|---|---|---|
| complex or unclear, a question | `/codex:rescue` | `/codex:rescue` |
| needs human input | `/interview` | `/codex:rescue` or `/agy:rescue` |

`--autonomous`: nobody answers, so never open a question menu. Product, credential
and spend decisions are for a human: set `cm:blocked <one question>` for those, and
when no escalation gives an answer. The escalation commands come from host plugins
(codex, agy); if one is missing, set `cm:blocked`.

## Failure modes

| failure | do |
|---|---|
| bead write fails | put notes, design and criteria in the PR body; say so in the `cm:` comment |
| escalation gives no answer | `cm:blocked <question>`, carry on with other items |
