---
name: commit
description: Create well-formatted git commits for changes made during the session
user-invocable: true
---

# Commit

Runbook: clean up agent scratch, plan atomic commits, commit by named paths, push per branch-protection rules. Execute steps in order.

## When NOT to use
- User wants to review a PR before merge → use `/review` (GitHub PR) or `/code-review` (working diff), not this skill.
- User only wants a commit *message* string, no staging/committing → use `/caveman-commit`.
- No changes staged or unstaged (`git status` clean) → stop, tell user there is nothing to commit.

## Step 0: Announce
Print verbatim:
```
I'll help you create git commits for the changes in this session.

Let me review what was accomplished and prepare appropriate commits.
```

## Step 1: Pre-commit cleanup (MANDATORY — do before any staging)

"Agent scratch" = any file that exists for the agent's benefit, not the repo's: debug scripts, temp notes, work-tracking markdown, goals/plans/research/handover docs.

Run the scan:
```bash
git status
ls -la .env* env.* *.env 2>/dev/null
ls -la test_*.* debug_*.* tmp_*.* temp_*.* 2>/dev/null
```

Apply this table to each file found:

| File matches | Action |
|---|---|
| `.env`, `.env.*`, `*.env` NOT in `.gitignore` | Add pattern to `.gitignore`; never stage the file |
| debug/temp script created this session (`test_*.js`, `debug_*.txt`, `tmp_*.py`) | `rm` it |
| markdown created this session AND not user-requested | `rm` it |
| under `.agents/{goals,plans,research,scratch,handover}/` (by intent, any path) | local-only: `git rm --cached` if tracked, ensure dir in `.gitignore` |
| `.agents/pr-signals/`, `.agents/MEMORY.md`, other deliberately-tracked agent infra | KEEP |
| explicitly user-requested doc, essential README/API doc | KEEP |

Add gitignore patterns when needed:
```bash
printf '.env*\n*.env\nenv.*\n' >> .gitignore   # env.* covers env.local-style names the scan surfaces
```

If any cleanup is required, present the list and wait for a yes before deleting:
```
I found files to clean up before committing:
- test_oauth.js (debug script → remove)
- debug_notes.md (work tracking → remove)
- .env.local (→ add to .gitignore, do not commit)

Clean these up before creating commits?
```

Re-run `git status` after cleanup. Expected: only real deliverables remain untracked/modified. If agent scratch still appears → repeat the table before proceeding.

## Step 2: Understand the changes
```bash
git status
git diff
git diff --staged
```
From the conversation + diff, identify distinct intents (feature, fix, refactor, test, docs). One intent = one commit. Count the intents now; that count = number of commits.

## Step 3: Plan commits

Rules:
- One commit per single concern. If a diff mixes two intents, split it across two commits.
- Group implementation with its own tests only if they serve the same concern; otherwise separate.
- Subject: imperative mood, conventional-commit type, ≤50 chars. Body only when the "why" is not obvious from the subject.
- Focus body on WHY, not a restatement of the diff.

Conventional-commit types:

| Type | Use for |
|---|---|
| feat | new feature |
| fix | bug fix |
| docs | documentation only |
| style | formatting, no logic change |
| refactor | restructure, no behavior change |
| perf | performance improvement |
| test | add/update tests |
| build | build system or dependencies |
| ci | CI/CD config |
| chore | maintenance |

Breaking change: append `!` after type and add a `BREAKING CHANGE:` footer line.

## Step 4: Present the plan
Show each commit with its type, summary, exact file list, and full message, then ask:
```
Based on the changes, I plan to create N commit(s):

Commit 1 — feat: add OAuth2 authentication support
Files:
- src/auth/oauth.js
- src/auth/tokenStore.js
Message:
feat: add OAuth2 authentication support

- Implement OAuth2 flow with refresh tokens
- Add token storage and validation

Shall I proceed?
```
Wait for confirmation before Step 5.

## Step 5: Stage and commit (per commit)
```bash
git add src/auth/oauth.js src/auth/tokenStore.js
git commit -m "feat: add OAuth2 authentication support

- Implement OAuth2 flow with refresh tokens
- Add token storage and validation"
```

Hard rules:
- NEVER `git add -A` or `git add .` — stage only the named paths for this commit. Why: bulk-add drags agent scratch into the commit.
- NEVER add Claude/AI attribution, "Generated with", or `Co-Authored-By`. Commit as if the user wrote it; match the repo's existing commit tone.
- Do not stage debug code, secrets, or temp files.
- Verify the code works before committing (run the relevant tests/build if not already run this session).

Work in progress — if the session's implementation is incomplete, ask the user which they want before committing:
1. Commit the completed parts with a clear message.
2. Create a WIP commit to save progress.
3. Wait until the feature is complete.

Verify after each commit:
```bash
git log --oneline -n 3
git status
```

## Step 6: Push

Determine branch and protection:
```bash
BRANCH=$(git branch --show-current)
git fetch origin
git log origin/$BRANCH..HEAD --oneline   # commits that will be pushed
```

Protected branch = `main`, `master`, or `release/*`.

| Situation | Action |
|---|---|
| Feature branch, not on remote | `git push -u origin $BRANCH` (auto) |
| Feature branch, already tracking | `git push` (auto) |
| Protected branch | Ask user to confirm (see prompt below); push only on yes |
| Local behind remote / push rejected | `git pull --rebase` then `git push` |
| Force push would be needed | STOP — ask explicit permission regardless of branch |

Protected-branch confirmation prompt:
```
You have commits ready to push to $BRANCH (protected).
Confirm: tests passed, code reviewed, ready to deploy? (yes/no)
```

Always print the commits before pushing:
```bash
echo "Pushing to origin/$BRANCH:"
git log origin/$BRANCH..HEAD --oneline
```

Rejection handling — expected outcome and branch:
```bash
git fetch origin
git pull --rebase && git push
```
If push still fails after rebase → it is branch protection or permissions, not a sync issue. Do NOT retry the push. Report the failure and offer `gh pr create` instead.

After a successful feature-branch push, tell the user they can open a PR with `gh pr create`.

## Quick reference
```bash
git status                                   # what changed
git diff                                      # unstaged changes
git add src/feature.js tests/feature.test.js  # stage named paths only
git commit -m "feat: implement new feature"
git log --oneline -10                         # recent commits
git commit --amend                            # fix the last commit
git reset HEAD file.js                        # unstage
```
