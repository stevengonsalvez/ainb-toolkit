---
name: coding-agent
description: >
  Spin off a coding agent. `ainb run` is the primary spawn path for any session
  that runs in a terminal: it creates an isolated git worktree, records the
  session, and makes it visible to the TUI, fleet and ATC tooling. Fall back to
  the Task tool for bounded in-session work, and to raw tmux only when ainb is
  unavailable. NOT for simple single-file edits, do those directly.
user-invocable: true
---

# /coding-agent, Delegate Coding Work

`ainb run` is the spawn path. Every coding session that needs its own terminal
goes through it, in every git repo, not just fleet repos. The other patterns in
this file are real and still useful, but each one is a fallback with a stated
trigger. If you cannot name the trigger, use Pattern 1.

## When to use each pattern

| Situation | Pattern |
|-----------|---------|
| Any coding session that needs its own terminal, in any git repo | **Pattern 1: `ainb run`** |
| Several independent fixes at once | **Pattern 1**, one `--create-branch` per fix (Pattern 5) |
| PR review | **Pattern 1** into a disposable `/tmp` clone (Pattern 4) |
| Claude Code capped or erroring | **Pattern 1** with `--tool codex` (Pattern 6) |
| Bounded work, no terminal needed, fine to die with this turn | Pattern 2: Task tool (fallback) |
| `ainb` not on PATH, or the target directory is not a git repo | Pattern 3: raw tmux (fallback) |

---

## Pattern 1: `ainb run` (PRIMARY)

Use this unless one of the fallback triggers below applies. An `ainb` session
lands in an isolated worktree, gets the right HOME/config, is recorded in the
session store, and shows up in the `ainb` TUI, `ainb fleet standup` and ATC.

### The contract

```bash
ainb run \
  --repo /absolute/path/to/repo-root \
  --worktree --create-branch fix/issue-101 \
  --tool claude \
  --model opus \
  --dangerously-skip-permissions \
  -p "$(cat /tmp/task-101.md)"
```

If a task worktree **already exists**, point `--repo` at the worktree and drop
the isolation flags (adding `--worktree` again would nest a worktree inside a
worktree):

```bash
ainb run --repo /absolute/path/to/existing/worktree --tool claude -p "$(cat task.md)"
```

### Flag by flag

| Flag | Why |
|------|-----|
| `--repo <abs-path>` | Repo root for a fresh session, or an existing task worktree. Absolute path, always. |
| `--worktree` | Isolation. Creates a git worktree under `~/.agents-in-a-box/worktrees/by-name/<repo>--<branch>--<shortid>`. |
| `--create-branch <branch>` | Implies `--worktree` and names the branch. Prefer this over bare `--worktree`, which invents `ainb/session-<shortid>`. |
| `--tool claude\|codex\|gemini\|copilot` | Which CLI to launch. Defaults to `claude`. |
| `--model <id>` | Passed through to the provider unchanged. Optional. |
| `--dangerously-skip-permissions` | Unattended runs only. Omit for anything you will babysit. |
| `-p "<task>"` | Initial prompt, sent once the input box is actually ready. |
| `--name <handle>` | Optional stable handle for the tmux session. Legal, see below. |
| `--parent <session-id>` | Only when spawning from inside another ainb session, see the resolution recipe below. |

### Never do these

1. **Never spawn into a bare checkout.** `ainb run --repo <repo> ...` with no
   `--worktree` and no `--create-branch` runs the agent directly in the repo's
   own working tree. Two agents then share one working tree and stomp each
   other. The TUI used to flag such a session as a `(broken)` workspace row;
   it now names it correctly after the owning repo, which means the mistake is
   no longer visible in the session list. Use `--worktree --create-branch
   <branch>`, or pass an existing worktree path as `--repo`.

   Quick check when you are unsure what a path is:

   ```bash
   test -f "$P/.git" && echo "real worktree: pass as --repo, no --worktree" \
                     || echo "repo root: add --worktree --create-branch <branch>"
   ```

   (In a real git worktree `.git` is a *file* pointing at the gitdir. In a normal
   clone it is a *directory*.)

2. **Never launch raw `tmux new-session ... claude -p` for repo coding.** It
   bypasses worktree isolation, the session store and cleanup. Pattern 3 exists
   only for the two triggers named there.

### `--name` is legal, use it deliberately

By default ainb mints the session name `<workspace>-<shortid>` (tmux name
`tmux_<workspace>-<shortid>`). `--name <handle>` overrides only that session
name, and therefore only the tmux name (`tmux_<sanitized-handle>`). It does
**not** touch `workspace_name`, which is derived from the basename of the git
repository that OWNS the session directory, so the TUI workspace label is
unaffected. Fleet routes on
the tmux name with the `tmux_` prefix stripped, so a custom name routes fine.

Prefer the minted name so a session sorts next to its siblings. Reach for
`--name` when you genuinely want a stable handle to type at (`ainb attach
reviewer`). Do not use it to encode task state that will go stale.

### Parent linkage

When you are spawning from inside an ainb session and want the child's
completions routed to your inbox, pass `--parent <your-own-session-id>`.

**ainb does not export your own session id into the environment.** It exports
only `AINB_PARENT_SESSION`, and that holds your *parent's* id, not yours. There
is no `$AINB_SESSION_ID`. Resolve your own id from the tmux session name
instead:

```bash
# Resolve this session's ainb id (empty when not inside an ainb tmux session)
MY_TMUX=$(tmux display-message -p '#{session_name}' 2>/dev/null)
MY_ID=$(ainb list --format json \
        | jq -r --arg t "$MY_TMUX" '.[] | select(.tmux_session_name == $t) | .session_id')

ainb run --repo "$REPO" --worktree --create-branch "$BRANCH" --tool claude \
  ${MY_ID:+--parent "$MY_ID"} \
  -p "$(cat "$TASK_FILE")"
```

If `MY_ID` comes back empty (you are not inside an ainb session, or `tmux` is
not available), `${MY_ID:+--parent "$MY_ID"}` emits nothing at all and the child
spawns unparented, which is fine. That guard is the whole point: an unresolved
id has two different failure shapes, and only one of them is loud.

| You wrote | What actually happens |
|-----------|----------------------|
| `--parent ""` (quoted, empty or whitespace-only) | Parses fine. `ainb run` trims the value and drops it, so the child spawns UNPARENTED with no warning and its completions never reach your inbox. |
| `--parent $MY_ID` (unquoted, `MY_ID` unset) | The token vanishes before clap sees it, so clap takes the NEXT token as the parent id. If that token starts with `-`, or `--parent` was last, clap aborts with `error: a value is required for '--parent <PARENT>'` (exit 2) and nothing spawns. If it does not start with `-` (a bare path, a branch name), clap swallows it as the parent id and the flag it belonged to is silently lost, so the spawn is corrupted. |

`${MY_ID:+--parent "$MY_ID"}` is correct for both: unset or empty emits no flag,
set emits a quoted one.

### Verify the spawn (do this every time)

```bash
# 1. The session exists and has a real workspace name
ainb list --format json | jq -r '.[] | "\(.session_id)\t\(.workspace_name)\t\(.worktree_path)"'
```

A `workspace_name` of `(broken)` means ainb could not resolve the session root
to a git repository at all: no ancestor directory holds a usable `.git`, and the
directory name carries no `<repo>--<branch>--<shortid>` hint to fall back on.
That is a dead root. Kill the session and respawn with
`--worktree --create-branch`.

A session whose worktree directory was deleted outright keeps its recorded name
in `ainb list` rather than reading `(broken)`, so you can still tell what it was
before you clean it up.

A plain checkout, or a subdirectory of one, is **not** broken. It resolves to
the repository that owns it and is named after that repository. It is merely
unisolated, which `ainb list` will not flag for you, so check the flags you
passed rather than waiting for `(broken)` to appear.

```bash
# 2. Follow up on a session (id or name from step 1)
ainb status <id>          # one-shot state
ainb logs <id> --lines 80 # recent output; -f to follow
ainb attach <id>          # interactive, do NOT call this from inside a tool call
ainb kill <id> --force    # teardown, exact id only
```

**Always pass `--force` to `ainb kill` (and `ainb git cleanup`) from a tool
call.** Without it they print `[y/N]` and read stdin. Under a non-interactive
stdin the read returns empty, they print `Cancelled.` and exit 0, so the session
survives while you believe it is gone.

### Expected: a subdirectory session is labelled with the owning repo

If you point `--repo` at a subdirectory of a checkout, the TUI's workspace row
carries the **owning repository's** name, not the subdirectory's. That is
correct (the workspace row is the grouping key, and the repo is what owns the
group), but it reads like a rename if you were watching the old behaviour. It is
not a regression, and it is not a sign that the wrong directory was used.

---

## Pattern 2: Task tool (FALLBACK, in-session subagent)

**Use this instead of ainb only when** the work is bounded, needs no terminal of
its own, and it is fine for it to die with this turn. The subagent runs inside
the current SDK session with full tool access (Bash, Read, Write, Edit, Glob,
Grep). No persistence, no tmux pane, no fleet visibility.

### Good fits

- Implement a feature, fix a bug, write tests, all inside one turn
- Refactor a module or file
- Analyse a codebase and produce a report

### How to invoke

```
Task({
  description: "Fix the rate-limiting bug in the API gateway",
  prompt: "..."
})
```

### Prompt template

Write the Task prompt as a complete standalone brief. The subagent has no memory
of the conversation that spawned it. Include:

1. **What to do**, specific, unambiguous objective
2. **Where to work**, directory, repo, relevant files
3. **Constraints**, branch to use, things not to touch, style rules
4. **Definition of done**, what success looks like
5. **How to report back**, files changed, tests run, result

```
Task({
  description: "Implement retry logic for the Slack webhook sender",
  prompt: """
    You are a backend engineer implementing retry logic for a webhook sender.

    Repository: /workspace/project
    Target file: src/channels/slack.ts, the `sendWebhook` function

    Task:
    - Add exponential backoff retry (max 3 attempts, base delay 500ms)
    - Only retry on 429 and 5xx HTTP responses
    - Preserve the existing function signature
    - Do NOT modify other files

    Constraints:
    - TypeScript strict mode is on
    - No new dependencies, use built-in fetch and setTimeout
    - Keep the existing error-logging pattern (console.error with context object)

    When done:
    - Run `npm run build` to verify compilation
    - Summarise: files changed, retry logic approach, any edge cases handled
  """
})
```

### Multi-subagent parallelism

Run independent tasks simultaneously. Do NOT chain tasks that depend on each
other's output, wait for the first to complete.

```
// Run two independent fixes in parallel
Task({ description: "Fix auth timeout", prompt: "..." })
Task({ description: "Fix typos in CLAUDE.md", prompt: "..." })

// Then, once both complete, run the dependent task
Task({ description: "Integration test for auth + config", prompt: "..." })
```

---

## Pattern 3: raw tmux (FALLBACK ONLY)

**Use this instead of ainb only when** `command -v ainb` fails, or the target
directory is not a git repo (ainb needs a repo to build a worktree from). Check
first:

```bash
command -v ainb >/dev/null && git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  && echo "use Pattern 1" || echo "tmux fallback justified"
```

Sessions created this way are invisible to `ainb list`, `ainb fleet standup` and
ATC. You own their lifecycle.

### Standard launch sequence

```bash
# 1. Generate a session name
TIMESTAMP=$(date +%s)
SESSION="agent-${TIMESTAMP}"
WORK_DIR="/path/to/repo"   # absolute path always

# 2. Create tmux session and start Claude Code
tmux new-session -d -s "$SESSION" -c "$WORK_DIR"
tmux send-keys -t "$SESSION" "claude --dangerously-skip-permissions" C-m

# 3. Wait for Claude to initialise (check for prompt, not just sleep)
sleep 3
tmux capture-pane -p -t "$SESSION" -S -30  # verify it's ready

# 4. Send the task (use -l flag for safe literal sending)
tmux send-keys -t "$SESSION" -l "Your full task description here"
tmux send-keys -t "$SESSION" C-m

# 5. Report session info back to user
echo "Session: $SESSION"
echo "Monitor: tmux attach -t $SESSION"
echo "Capture: tmux capture-pane -p -t $SESSION -S -100"
echo "Kill:    tmux kill-session -t $SESSION"
```

### Check progress without blocking

```bash
# Tail the last 50 lines of output
tmux capture-pane -p -t "$SESSION" -S -50

# Check if Claude is still working (look for spinner or output activity)
tmux capture-pane -p -t "$SESSION" -S -5
```

### Send a follow-up prompt

```bash
# Only send follow-up when the previous task is clearly done
tmux send-keys -t "$SESSION" -l "Now run the test suite and fix any failures"
tmux send-keys -t "$SESSION" C-m
```

### Headless (non-interactive) mode

For scripted work where you want output captured to a log file rather than
interactive:

```bash
TIMESTAMP=$(date +%s)
SESSION="agent-${TIMESTAMP}"
WORK_DIR="/path/to/repo"
LOG="/tmp/agent-${TIMESTAMP}.log"
PROMPT_FILE="/tmp/agent-${TIMESTAMP}-prompt.md"
cat > "$PROMPT_FILE" <<'EOF'
Your full task prompt here.
EOF

tmux new-session -d -s "$SESSION" -c "$WORK_DIR" \
  "claude -p \"\$(cat '$PROMPT_FILE')\" --dangerously-skip-permissions --max-turns 80 2>&1 | tee '$LOG'"

echo "Output logged to: $LOG"
echo "Monitor: tmux attach -t $SESSION"
```

**Quoting rule:** do not inline long Markdown prompts with backticks, `$`, env
var names, or code fences inside outer double quotes. The shell can
expand/mangle them before Claude starts. Use a prompt file plus literal
`$(cat file)` in the tmux command, or `tmux send-keys -l` with escaped command
substitution. The same rule applies to `ainb run -p "$(cat file)"`.

---

## Pattern 4: PR review

Review a pull request without touching the live project. Always clone to `/tmp`,
then spawn with Pattern 1 against that clone.

```bash
TIMESTAMP=$(date +%s)
PR_NUMBER="42"
REPO="owner/repo"
WORK_DIR="/tmp/pr-review-${TIMESTAMP}"

# Clone and checkout the PR branch
git clone "https://github.com/${REPO}.git" "$WORK_DIR"
git -C "$WORK_DIR" fetch origin "pull/${PR_NUMBER}/head:review/pr-${PR_NUMBER}"

# Spawn the reviewer in an isolated worktree off that clone
ainb run \
  --repo "$WORK_DIR" \
  --worktree --create-branch "review/pr-${PR_NUMBER}" \
  --tool claude \
  --dangerously-skip-permissions \
  -p "Review PR #${PR_NUMBER}. Check correctness, security, test coverage, and style. Summarise findings."

ainb list --format json | jq -r '.[] | "\(.session_id)\t\(.workspace_name)"'
```

**Rules for PR reviews:**
- NEVER run the agent inside the live project directory, contamination risk
- Clone to `/tmp/pr-review-{timestamp}`, isolated and disposable
- Clean up after: `ainb kill <id> --force`, **verify the session is gone**, then
  `rm -rf /tmp/pr-review-${TIMESTAMP}`. Without `--force` the kill silently
  cancels and you delete the checkout out from under a live agent:

  ```bash
  ainb kill "$ID" --force
  ainb list --format json | jq -e --arg id "$ID" 'all(.session_id != $id)' >/dev/null \
    && rm -rf "/tmp/pr-review-${TIMESTAMP}" \
    || echo "session $ID still present, NOT deleting the checkout"
  ```

If `ainb` is unavailable, fall back to Pattern 3 with `-c "$WORK_DIR"` and the
same `/tmp` rules.

---

## Pattern 5: Parallel fixes

Work on multiple issues simultaneously without branch-switching conflicts. One
`ainb run` per issue: each gets its own branch and its own worktree, so no
manual `git worktree add` is needed.

```bash
REPO_DIR="/workspace/project"    # absolute path to the repo root

for ISSUE in 101 102; do
  ainb run \
    --repo "$REPO_DIR" \
    --worktree --create-branch "fix/issue-${ISSUE}" \
    --tool claude \
    --dangerously-skip-permissions \
    -p "Fix issue #${ISSUE}: [description]"
done

ainb list --format json | jq -r '.[] | "\(.session_id)\t\(.workspace_name)\t\(.worktree_path)"'
```

Tear down when merged or discarded:

```bash
ainb kill <id> --force         # per session, exact id only
ainb git cleanup --dry-run     # see what would be pruned
ainb git cleanup --force       # prune worktrees ainb created
```

`--force` is not optional from a tool call: both commands otherwise block on a
`[y/N]` stdin read, cancel, and still exit 0.

**Fallback (Pattern 3 only):** if you had to create worktrees by hand, remove
them by hand too.

```bash
git -C "$REPO_DIR" worktree add /tmp/fix-issue-101 -b fix/issue-101 main
# ... tmux session per worktree ...
git -C "$REPO_DIR" worktree remove /tmp/fix-issue-101
```

---

## Pattern 6: Codex

If Claude Code is rate-capped or unavailable, keep Pattern 1 and swap the tool.

### Check availability first

```bash
claude --version 2>/dev/null && echo "CC: available" || echo "CC: not found"
which codex 2>/dev/null && echo "Codex: available" || echo "Codex: not installed"
```

### Codex through ainb (preferred)

```bash
ainb run \
  --repo "$REPO_DIR" \
  --worktree --create-branch "fix/issue-101" \
  --tool codex \
  -p "Your task description"
```

### Raw codex in tmux (last resort, Pattern 3 triggers only)

```bash
TIMESTAMP=$(date +%s)
SESSION="codex-${TIMESTAMP}"
WORK_DIR="/path/to/repo"

tmux new-session -d -s "$SESSION" -c "$WORK_DIR"
tmux send-keys -t "$SESSION" "codex exec --full-auto 'Your task description'" C-m
echo "Capture: tmux capture-pane -p -t $SESSION -S -50"

# interactive variant
tmux send-keys -t "$SESSION" "codex --yolo" C-m
sleep 3
tmux send-keys -t "$SESSION" -l "Your task description"
tmux send-keys -t "$SESSION" C-m
```

---

## Fallback decision tree

```
ainb run --worktree --create-branch     ← default for any terminal session
    ↓ work is bounded and needs no terminal
Task tool (dies with this turn)
    ↓ ainb missing, or target is not a git repo
tmux + claude --dangerously-skip-permissions
    ↓ CC capped or erroring after 2 retries
ainb run --tool codex   (or tmux + codex exec --full-auto in the tmux fallback)
    ↓ Codex not installed
Report to user: install codex or retry later
```

---

## Session management

### ainb sessions (Pattern 1, 4, 5, 6)

```bash
ainb list                                  # text table
ainb list --format json | jq -r '.[] | "\(.session_id)\t\(.workspace_name)\t\(.worktree_path)"'
ainb list --running                        # running only
ainb status <id>
ainb logs <id> --lines 100                 # -f to follow
ainb attach <id>                           # interactive only, never from a tool call
ainb kill <id> --force                     # --force is mandatory from a tool call
ainb git worktrees                         # what ainb has on disk
ainb git cleanup --dry-run                 # preview the prune
ainb git cleanup --force                   # prune stale worktrees
```

`ainb kill` and `ainb git cleanup` prompt `[y/N]` on stdin whenever `--force` is
absent. There is no tty check, so from a non-interactive Bash tool call the read
returns empty, they print `Cancelled.` and exit 0. An exit code of 0 from a bare
`ainb kill` therefore proves nothing. Always pass `--force`, and confirm with
`ainb list`.

Naming is minted by ainb: session `<workspace>-<shortid>`, tmux
`tmux_<workspace>-<shortid>`, worktree directory
`<repo>--<branch>--<shortid>`. `--name` overrides the session/tmux name only and
is legal (fleet routes on the tmux name); `workspace_name` comes from the
basename of the git repository that owns the session directory either way.

### Fallback tmux sessions (Pattern 3 only)

```bash
tmux list-sessions 2>/dev/null | grep -E "^(agent|codex|pr-review)-"
tmux kill-session -t "agent-${TIMESTAMP}"
```

**Never use `tmux kill-server`**, it destroys all sessions across all users and
projects. Kill by exact session name only.

| Prefix | Use |
|--------|-----|
| `agent-{timestamp}` | fallback Claude Code coding session |
| `codex-{timestamp}` | fallback Codex session |
| `pr-review-{timestamp}` | fallback PR review checkout |

---

## Rules

1. **`ainb run` is the default spawn path.** Reach for Task tool or raw tmux only
   when you can name the trigger from the table at the top.

2. **Never create a session directly in a plain checkout.** Either
   `--worktree --create-branch <branch>` off a repo root, or an existing real
   worktree passed as `--repo`. Nothing else.

3. **Prefer the minted session name.** `--name` is legal and fleet routes on it,
   but it only buys you a stable handle. Do not use it to encode task state.

4. **Verify after spawning.** `ainb list --format json` must show the new session
   with a real `workspace_name`. `(broken)` (root outside any git repo, or a
   dangling worktree pointer) means respawn. A real repo name does **not** prove
   you isolated it, check the flags you passed.

5. **PR reviews always use `/tmp`.** Never run an agent inside the live project
   directory for review work, contamination risk.

6. **Never block.** After starting a session, report the identifier and move on.
   Use `ainb logs` / `tmux capture-pane` to check progress, never `ainb attach`
   or `tmux attach` from within a tool call.

7. **One task per session.** Do not reuse a session for unrelated work.

8. **Absolute paths only.** `--repo` and `tmux -c` both need absolute paths;
   neither inherits your working directory reliably.

9. **Literal key sending.** Use `tmux send-keys -t SESSION -l "text"` (the `-l`
   flag) for any prompt text containing special characters. Without `-l`,
   characters like `$`, `{`, `}`, `*` get interpreted by the shell.

10. **No `bash pty:true`.** That is an OpenClaw-specific API that does not exist
    here. All interactive terminal work goes through ainb or tmux.

11. **No `process action:log`.** Also OpenClaw-only. Use `ainb logs <id>` or
    `tmux capture-pane -p -t SESSION -S -N` to read session output.

12. **Check the tool exists before use.** `which codex` before a Codex session,
    `command -v ainb` before assuming Pattern 1 is available.

13. **Clean up with `--force`.** `ainb kill <id> --force` plus
    `ainb git cleanup --force` for ainb sessions; `git worktree remove` plus
    `tmux kill-session -t <exact-name>` for fallback ones. Without `--force` both
    ainb commands prompt on stdin, cancel under a non-interactive tool call, and
    still exit 0. Never `rm -rf` a session's directory until `ainb list` shows the
    session actually gone.

14. **There is no `$AINB_SESSION_ID`.** ainb exports only `AINB_PARENT_SESSION`
    (your parent's id). Resolve your own id from the tmux session name via
    `ainb list --format json` before passing `--parent`, and emit the flag with
    `${MY_ID:+--parent "$MY_ID"}`. Never hand `--parent` an unresolved value:
    quoted-empty is silently dropped, unquoted-unset makes clap eat the next
    token.
