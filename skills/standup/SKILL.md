---
name: standup
description: Read-only branch-scoped situation report for Stevie. Surfaces beads in-flight, what's been done since last invocation, what's pending, active swarms/coding-agents/subagents in this worktree, and — most importantly — what specifically needs Stevie's input (decisions, PR merges, AskUserQuestion threads, blocked beads). Output is progressive tables, one shape per stage, address the user as Stevie. Trigger on /standup, "give me a standup", "what's the state of this branch", "what do you need from me". Read-only — never claims beads, never merges, never posts anywhere.
---

# Standup — Stevie's branch-scoped situation report

Read-only report shaped so Stevie acts in 30 seconds: state of the branch + exactly what waits on **him**. Never mutates anything.

- Address the reader as **Stevie**, always.
- Output in **caveman mode** (drop articles, filler, hedging; keep technical terms exact) UNLESS Stevie is already in normal mode this conversation.
- Tables stay readable — do NOT caveman column headers or cell content.
- Target runtime **<10s**. No LLM fan-out. No API beyond `gh` and `bd`.

## Design facts (each output rule traces to one)

1. Stevie scans the left edge (column 1), not prose. Anything important not in a ball or column-1 cell is invisible.
2. The headline is "what needs ME." Inputs section is the lede; surface it even when everything else is empty.
3. A session with unknown scope is a hidden blocker. The "working on" column is load-bearing.
4. Stevie returns to worktrees cold. Externalize state to disk; frame everything "since last standup."
5. Read-only is the trust contract. The moment it might `bd close`/`gh merge`, he must babysit it.
6. Speed is the product. >10s = a standup he won't run.

## When NOT to use (route elsewhere)

| Situation | Use instead |
|---|---|
| Cross-branch / cross-project survey | different tool (not standup) |
| Active task tracking in one conversation | TodoWrite |
| PR-level deep dive | `/pr-signals` or open the PR |
| Incident triage | `/incident-investigate` |

## When to use

- Stevie types `/standup`, "give me a standup", "what's the state of this branch".
- Stevie asks "what do you need from me?" — run standup, lead with Inputs.
- Stevie returns to a worktree cold, or starts a session in an unfamiliar worktree.

## Output rules

1. **Lead with Counts, climax on Inputs (Fact 2).** First shape = 1-row Counts table. Last shape = `### Inputs needed from Stevie 🔴`. Everything between is skippable context.
2. **ONE unified beads table — never sub-tables (Fact 1).** All four states (shipped/pending/next/blocked) in one table. Never split into In-progress/Ready/Blocked sub-tables.
3. **Status ball on the left edge of every status/priority cell (Fact 1).** Ball is the scan target. Enum: 🟢 shipped · 🔵 pending · 🟡 next (P\<n>) · 🔴 blocked (by …). Priority: 🔴 high · 🟡 medium · 🔵 low.
4. **Options → `---` separators, one line each (Fact 1).** Each option/alternative separated by a horizontal rule with ONE line of rationale. Never bullet-soup or run-on prose.
5. **Structural comparison → ASCII diagram, not prose (Fact 1).** Data flow / RLS chain / deploy sequence / who-calls-what gets drawn with box chars, ≤80 chars wide, caveman inside boxes.
6. **Decisions → `/interview`, not raw AskUserQuestion (Fact 2).** Multi-faceted decision (which option + scope + timing) → surface row, render option block (rule 4) + diagram (rule 5), then invoke `/interview`. A single `AskUserQuestion` is allowed ONLY for a clean binary yes/no.
7. **Caveman prose, exact terms, tables stay tables (Fact 6).** Drop hedging adverbs. `"22 blocked. Top 5 below."` not `"it looks like there might possibly be a few…"`.
8. **Emojis carry status semantics only (Fact 1).** Allowed only where it encodes state: 🟢/🔵/🟡/🔴/⚫ balls, 🔴 on Inputs header, ✅/✘/⏳ in CI rollups. No decorative emoji.
9. **Cap every list (Fact 1).** Blocked beads → 5 + `_(+ N more 🔴 — see bd blocked)_`. Inputs → 10. Next → 5. Overflow gets noted, never dumped.

## Section order (fixed — 5 tables + optional decision block)

1. **Summary** — 1-row Counts table, each figure prefixed with its ball.
2. **Beads** — the ONE unified table (rule 2). Cols `id | title | status | PR`. Sort: shipped → pending → next → blocked. PR col = `#NNNN → merged|open|draft` for shipped, `—` otherwise.
3. **PRs raised in this worktree** — `# | title | state | CI | labels | when`. State ball: 🟢 merged · 🟡 open · ⚫ draft · 🔴 closed-unmerged.
4. **Active swarms / coding-agents / subagents** — `name | source | working on | last activity | status`. Status ball: 🟢 running · 🟡 idle (>5min) · 🔴 stuck. "working on" = actual bead/task, never just the session name (Fact 3).
5. **Work in flight (deploy pipeline)** — ASCII box-and-arrow of any in-flight ship. Render ONLY when something is mid-ship; skip entirely otherwise.
6. **Inputs needed from Stevie 🔴** — THE headline (Fact 2). Build even when everything else is empty.

Close with: `Anything else, Stevie?`

## Gather the data (run in order; skip a section gracefully if its source is missing)

### Step 0 — Guardrails

```bash
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Stevie — not in a git repo. /standup needs a worktree."; exit 1
fi
BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
  echo "Stevie — detached HEAD. Switch to a branch and re-run."; exit 1
fi
WORKTREE_PATH=$(git rev-parse --show-toplevel)
SAFE_BRANCH=$(echo "$BRANCH" | sed 's|[/:]|_|g')

# Tool-neutral state dir (shared across Claude/Codex/Copilot/Gemini). Never write .claude/ or .codex/.
STATE_DIR="$WORKTREE_PATH/.agents/standup"
STATE_FILE="$STATE_DIR/${SAFE_BRANCH}.json"
mkdir -p "$STATE_DIR"
```

### Step 1 — Establish "since" cutoff (Fact 4)

```bash
if [ -f "$STATE_FILE" ]; then
  SINCE=$(jq -r '.last_run_at' "$STATE_FILE")
else
  MERGE_BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null)
  SINCE=$(git show -s --format=%cI "$MERGE_BASE" 2>/dev/null || date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ')
fi
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
```

Elapsed display: minutes if <60, else hours+minutes. Use `date -d`/`gdate` if available, else manual subtraction.

### Step 2 — Load project label config (optional)

Config path order (first match wins):
1. `$WORKTREE_PATH/.agents/standup/config.json` (preferred)
2. `$WORKTREE_PATH/.agents/standup-config.json` (legacy)

If neither exists, default to SHOT semantics:

```jsonc
{
  "label_map": {
    "review_requested":  "popashot-please-review",
    "reviewed":          "popashot-reviewed",
    "review_done":       "popashot-review-done",
    "comments_fixed":    "popashot-pr-comments-fixed",
    "e2e_passed":        "popashot-e2e-passed"
  }
}
```

Stevie-action signal = `comments_fixed` label present + all required CI green = ready to admin-merge.

### Step 3 — Beads (ONE unified table)

Skip if `[ ! -d .beads ]`.

```bash
# shipped = closed since cutoff, mentioning branch
SHIPPED=$(bd list --status=closed --json 2>/dev/null \
  | jq --arg s "$SINCE" --arg b "$BRANCH" '[.[]
      | select(.closed_at >= $s)
      | select((.title // "" | contains($b)) or (.description // "" | contains($b)) or ((.notes // "") | contains($b)))
      | {id, title, status: "shipped", pr: (.notes // "" | capture("#(?<n>[0-9]+)").n // "—")}]')

# pending = in_progress on this branch
PENDING=$(bd list --status=in_progress --json 2>/dev/null \
  | jq --arg b "$BRANCH" '[.[]
      | select((.title // "" | contains($b)) or (.description // "" | contains($b)) or ((.notes // "") | contains($b)))
      | {id, title, status: "pending", pr: "—"}]')

# next = top 5 ready (surface even if not branch-scoped — branch may be done)
NEXT=$(bd ready --json 2>/dev/null | jq '.[0:5] | map({id, title, status: ("next (P" + (.priority|tostring) + ")"), pr: "—"})')

# blocked = all blocked, blocker IDs in status
BLOCKED=$(bd blocked --json 2>/dev/null | jq '[.[] | {id, title, status: ("blocked (by " + ((.blocked_by // []) | join(", ")) + ")"), pr: "—"}]')

echo "$SHIPPED $PENDING $NEXT $BLOCKED" | jq -s 'add'
```

Render per rules 2+3+9: one table, `id | title | status | PR`, balls left-edge, blocked capped at 5 + overflow note.

### Step 4 — PRs raised in this worktree

For each open PR with head branch = current branch:

```bash
gh pr view <num> --json number,title,isDraft,statusCheckRollup,labels,reviews,createdAt --jq '{
  number, title, isDraft,
  ci: ([.statusCheckRollup[] | .conclusion] | group_by(.) | map({(.[0]): length}) | add),
  labels: [.labels[].name],
  age_hours: (((now - (.createdAt | fromdateiso8601)) / 3600) | floor)
}'
```

Labels are the truth — do NOT re-run `/pr-signals`. If `comments_fixed` label + all-green CI, flag this row in Inputs.

### Step 5 — Active swarms / coding-agents / subagents (this worktree only) (Fact 3)

```bash
if command -v tmux >/dev/null 2>&1 && tmux ls >/dev/null 2>&1; then
  tmux list-sessions -F '#{session_name}|#{session_path}|#{session_activity}' 2>/dev/null \
    | awk -F'|' -v wt="$WORKTREE_PATH" '$2 == wt' \
    | while IFS='|' read -r name path activity; do
        case "$name" in
          swarm-*|agent-*|expect-*|dev-*|coding-agent-*)
            # "working on" resolution, priority order:
            #   1. bead ID: grep -oE 'shotclubhouse-[a-z0-9.]+'  (adjust prefix per project)
            #   2. issue/PR ref: grep -oE '#[0-9]+'
            #   3. last non-empty visible line
            pane=$(tmux capture-pane -t "$name" -p -S -200 2>/dev/null)
            working_on=$(echo "$pane" | grep -oE 'shotclubhouse-[a-z0-9.]+' | tail -1)
            [ -z "$working_on" ] && working_on=$(echo "$pane" | grep -oE '#[0-9]+' | tail -1)
            [ -z "$working_on" ] && working_on=$(echo "$pane" | tail -5 | grep -v '^$' | tail -1 | cut -c1-60)
            echo "$name|tmux|$working_on|$activity|running"
            ;;
        esac
      done
fi

# Preferred agent-authored status, if present:
[ -x .agents/scratch/swarm-status.sh ] && .agents/scratch/swarm-status.sh 2>/dev/null
```

Also call the **TaskList** tool to enumerate in-flight Task agents in *this* conversation; the agent `description` (4-word summary) goes in "working on".

Branch on the "working on" cell:
- Resolved → render it.
- Empty/`?` → mark `?` AND add a "session running with unknown scope" row to Inputs (Fact 3).
- Whole section empty → render `_(none active)_`, don't skip.

### Step 5.5 — Work in flight (deploy pipeline)

Render ONLY when a ship is mid-flight (PR merged to main in ~last 2h with prod deploy and/or OTA still moving). If nothing is deploying, skip entirely — no empty box.

```bash
PROD=$(gh run list --workflow=deploy-production.yml --event=push --limit=1 \
  --json status,conclusion,headBranch --jq '{ref:.[0].headBranch, status:.[0].status, conclusion:.[0].conclusion}')
OTA=$(gh run list --workflow=deploy-ota.yml --limit=1 \
  --json status,conclusion,displayTitle --jq '{status:.[0].status, conclusion:.[0].conclusion, title:.[0].displayTitle}')
```

Stage label mapping:

| Stage state | Label |
|---|---|
| PR merged / prod run `success` / OTA promote `success` | `DONE` |
| stage `in_progress` or `queued` | `IN FLIGHT` |
| stage not started (OTA before prod tag; device reload until OTA promote success) | `NOT YET` |
| any stage `failure` | `🔴 FAILED` → add to Inputs |

Device box caps at `NOT YET` once OTA is `DONE` (standup can't know Stevie reloaded) with note `_(applies on next app reload)_`.

Render (rule 5):

```
┌─────────┐   ┌─────────┐   ┌──────────┐   ┌─────────────┐   ┌──────────┐
│ #NNNN   │──▶│ merged  │──▶│ prod web │──▶│ OTA publish │──▶│ device   │
│ +tag    │   │ to main │   │ vX.Y.Z   │   │ +promote    │   │ reloads  │
└─────────┘   └─────────┘   └──────────┘   └─────────────┘   └──────────┘
   DONE          DONE        IN FLIGHT        NOT YET           NOT YET
```

### Step 6 — Inputs needed from Stevie 🔴 (Fact 2)

Highest-signal section. Build the table even if every other section is empty. Sources:

**a. Blocked beads with decision-shaped notes:**
```bash
bd blocked --json 2>/dev/null | jq '[.[] | select(
  (.notes // "" | test("(?i)awaiting|decision|stevie|review|approval|input|choose|pick|confirm")))]'
```

**b. PRs flagged Stevie-action** (`comments_fixed` + CI all green, OR `please_review` + latest claude-review = CHANGES REQUESTED):
```bash
gh pr view <num> --json comments,statusCheckRollup,labels --jq '
  {needs_merge: (.labels | map(.name) | contains(["popashot-pr-comments-fixed"])
                and ([.statusCheckRollup[] | .conclusion] | all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL"))),
   claude_changes_req: (.comments | map(select(.author.login == "claude")) | last | .body | contains("CHANGES REQUESTED"))}'
```

**c. AskUserQuestion threads in spawned tmux sessions** (scan last 50 pane lines per worktree agent session):
```bash
tmux capture-pane -t "$session" -p -S -50 \
  | grep -E "^[?❯>] |Press|please choose|please select|y/n|\(Y/n\)" | tail -3
```

**d. Unanswered decision points in the CURRENT conversation.** Read the session transcript; find the most recent assistant message ending in a question (ends with `?`, contains `Want me to`/`Should I`/`Confirm`/`(A)...(B)...`) with no user reply after it, and surface it. Best-effort — skip silently on parse failure.
```bash
PROJECT_DIR=$(echo "$WORKTREE_PATH" | sed 's|/|-|g; s|^-||')
TRANSCRIPT=$(ls -t ~/.claude/projects/-${PROJECT_DIR}/*.jsonl 2>/dev/null | head -1)
```

**e. Sessions running with unknown scope** — any Step 5 row whose "working on" = `?` (Fact 3).

**f. Explicit `// @stevie:` markers in branch diff:**
```bash
git diff $(git merge-base HEAD main)..HEAD -- ':!*.lock' \
  | grep -E "^\+.*(// @stevie:|#shame:blocked|TODO:.*stevie)" | sed 's/^+//'
```

Render (rules 3+9): sort by priority (high first), cap at 10. If a row needs a >1-option decision, follow rules 4+5+6 (option block → diagram → `/interview`). If empty: `Stevie — nothing waiting on you. Carry on.`

### Step 7 — Persist state (Fact 4)

After successful render (`$BRIEF_SUMMARY` = one line like `shipped=1 next=5 pending=0 blocked=22 inputs=1`):

```bash
jq -n --arg b "$BRANCH" --arg w "$WORKTREE_PATH" --arg t "$NOW" --arg s "$BRIEF_SUMMARY" '{
  branch: $b, worktree_path: $w, last_run_at: $t, last_summary: $s
}' > "$STATE_FILE"
```

## Output skeleton

```markdown
**Stevie's standup — <BRANCH>**

| field | value |
|---|---|
| Branch | <BRANCH> |
| Worktree | <WORKTREE_PATH> |
| Counts | 🟢 <S> shipped / 🟡 <N> next / 🔵 <P> pending / 🔴 <B> blocked / inputs <I> |

### Beads
| id | title | status | PR |
|---|---|---|---|
| ag-xx | ... | 🟢 shipped | #2535 → merged |
| ag-yy | ... | 🔵 pending | #2540 → open |
| ag-zz | ... | 🟡 next (P1) | — |
| ag-ww | ... | 🔴 blocked (by ag-vv) | — |
*(cap blocked at 5 + `_(+ N more 🔴 — see bd blocked)_`)*

### PRs raised in this worktree
| # | title | state | CI | labels | when |
|---|---|---|---|---|---|
| 2535 | fix(rls)... | 🟢 merged | ✅ | popashot-pr-comments-fixed | 13h ago |
*(or `_(none open or merged this cycle)_`)*

### Active swarms / coding-agents / subagents
| name | source | working on | last activity | status |
|---|---|---|---|---|
| swarm-1778… | tmux | shotclubhouse-ag-z0nc | 2m ago | 🟢 running |
*(or `_(none active)_`)*

### Work in flight
```
┌─────────┐   ┌─────────┐   ┌──────────┐   ┌─────────────┐   ┌──────────┐
│ #2891   │──▶│ merged  │──▶│ prod web │──▶│ OTA publish │──▶│ device   │
│ +M1/M2  │   │ to main │   │ v1.2.56  │   │ +promote    │   │ reloads  │
└─────────┘   └─────────┘   └──────────┘   └─────────────┘   └──────────┘
   DONE          DONE        IN FLIGHT        NOT YET           NOT YET
```
*(omit entirely when nothing is mid-ship)*

### Inputs needed from Stevie 🔴
| source | item | action | priority |
|---|---|---|---|
| PR #2535 | popashot-pr-comments-fixed + CI green | admin-merge ready | 🔴 high |
| Bead ag-xx | blocked: awaiting decision on caching strategy | needs your call | 🔴 high |
| tmux swarm-1778 | "(Y/n)" prompt unanswered 12m | reply or kill | 🟡 medium |
| chat | last msg ended "Want me to ship option 2?" — no reply | answer in chat | 🔴 high |
*(or `Stevie — nothing waiting on you. Carry on.`)*

Anything else, Stevie?
```

### Decision sub-block (append AFTER Inputs when a >1-option choice or structural PR surfaces)

Use rules 4+5, then call `/interview`:

```markdown
### Option to decide — <one-line context>

**Option A — ship hotfix policy**
Unblocks users now, leaves RPC follow-up open.

---

**Option B — ship RPC migration**
Proper fix, requires frontend change + native rebuild.

Architecture:

    client ──▶ profiles SELECT (RLS-gated)
                    │
        ┌───────────┴───────────┐
        │                       │
    Option A                Option B
    add policy           strip policy + RPC
    (no FE change)       (FE migration needed)
```

## Pre-render check

Delete before rendering:
1. Any prose a table could carry (rule 2).
2. Any decorative emoji not encoding status (rule 8).
3. Any hedging adverb — "perhaps/might/could possibly" (rule 7).
4. Any list past its cap → replace tail with overflow note (rule 9).

Then the one test: **reading ONLY the Counts row + Inputs table, does Stevie know (a) branch state and (b) exactly what waits on him?** If no → the Counts row or Inputs section is under-built; fix that first.

## Break-the-rules branches

| Situation | Do this |
|---|---|
| Stevie says "explain" / "walk me through" a row | Full prose for that one item — still no preamble, still caveman. Add a header to skim back to the table. |
| Decision is genuinely binary | Skip `/interview` (rule 6); fire a single `AskUserQuestion`. |
| Zero data everywhere (beads/PRs/agents/inputs all empty) | Skip the 4 context tables; render only: `Stevie — branch <X> is quiet. Nothing in flight, nothing waiting on you.` |
| Stevie already in normal mode this conversation | Honour it — don't force caveman back on. |

## Error handling

| Missing | Behaviour |
|---|---|
| `bd` | skip beads sections; note `_(beads not initialised)_` |
| `gh` | skip PR sections; note `_(gh CLI not authenticated)_` |
| `tmux` | skip swarm section; note `_(tmux unavailable)_` |
| `jq` | fail hard: `Stevie — install jq, /standup needs it` |
| TaskList tool unavailable | skip todo + agent enumeration silently |
| transcript parse failure (source d) | skip that sub-source silently |

## Hard rules (Fact 5 — the trust contract)

- READ-ONLY. Never `bd update`/`bd close`/`gh pr merge`/`gh pr comment`/`git commit`, etc.
- NEVER post to Slack/Discord/GH comments — output is stdout only.
- NEVER re-run `/pr-signals` — labels are the source of truth.
- NEVER claim a bead or change assignee.
- The state file is the ONLY write, under `.agents/standup/` (tool-neutral, like `.agents/MEMORY.md`). Add `.agents/standup/` to project `.gitignore` if per-branch state shouldn't be committed.

## Future flags (NOT in v1)

`--since <ISO-date>` (override cutoff) · `--no-state` (skip state file) · `--json` (machine output) · cron mode via `/schedule`.
