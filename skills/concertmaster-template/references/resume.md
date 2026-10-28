# Resume

`/concertmaster resume` gets the fleet back after a restart without the owner
re-explaining any work. Storage survives a restart (`$CM_HOME`), so
the only thing missing is "which lanes were live and what was each doing".
The roster answers that. Loss of the host's storage is out of scope.

```text
┌──────────────┐ each tick ┌──────────────────────────┐
│ ledger.json  │──────────▶│ roster.yaml (active only)│
│ (truth)      │ roster.sh │ mode 600, atomic rewrite │
└──────────────┘           └────────────┬─────────────┘
                                        │ scripts/resume.sh
                                        ▼
        ┌─────────────────────────────────────────────────┐
        │ per row: host up? agent live in the worktree?   │
        │  offline ─▶ skip, retry next tick               │
        │  2+ live ─▶ send to neither, ask owner          │
        │  1 live  ─▶ leave alone                         │
        │  none    ─▶ re-check, then claude --continue in │
        │             the same tree + ONE nudge naming    │
        │             `current`                           │
        └─────────────────────────────────────────────────┘
```

## Roster

`$CM_HOME/roster.yaml`, rewritten whole each tick by `scripts/roster.sh`
(temp file in the same directory, `chmod 600`, `mv`). Active rows only: ledger
workers whose state is not `queued`, `spawning`, `gone`, `repurposed`, `retired`,
`teardown` or `done` (those have no worktree to resume). Standing lanes stay in
while idle. Only these fields are copied (an allowlist; token-shaped text in
`current` and `state` is replaced with `[redacted]`, best effort):

| field | from |
|---|---|
| lane, host, terminal, agent, beadsEpic | `workers.<id>.lane`, `host`, `terminal`, `agent`, `beadsEpic` |
| worktree, worktreeId | `workers.<id>.path`, `worktreeId` (resume matches by Orca id first, as `classify` does) |
| model | `workers.<id>.model`, else null |
| current | `workers.<id>.current`, else `task` |
| prs | numbers in `prs.*` whose `driver` is the worker, plus the worker's own `pr` |
| state | `workers.<id>.lastComment`, else `state` |
| updatedAt | `workers.<id>.updatedAt`, else the ledger's |

The spec lists ten fields; `agent` and `worktreeId` are the two additions
(resume must not start claude in a codex lane, and must find a worktree the way
classify does). The ledger stays the truth. Never commit the roster, the ledger
or briefs.

## Procedure (`scripts/resume.sh`)

1. **Roster fresh, one run at a time.** With a readable ledger, run
   `scripts/roster.sh` first, every time (cheap, atomic): the tick retires and
   tears down workers after it writes the roster, and a stale row would revive a
   lane closed on purpose. No readable ledger: use the roster as is. Neither:
   stop. A lock (`$CM_HOME/resume.lock`, atomic stale reclaim, pid reuse
   checked) makes a second run exit 4, so the tick and the owner never both create
   an agent for one lane. A run proves the lock is its own after taking it and
   again right before every terminal create (a row is `unknown` if it was lost).
   Only the test sets `CM_TEST=1` with `CM_TEST_CLAUDE_CWDS_CMD`; without
   `CM_TEST=1` that override is ignored.
   `--host <h> --worktree-id <id> --path <worktree>` or `--lane <label>` limits a
   run to one row (the tick's `standing-dead` passes all three: hosts share
   identical layouts, and classify matches by id or path). A filter that matches
   no row resumes nothing and exits 5: respawn that lane by hand. Exit 4 means
   another run holds the lock: do nothing for that lane this tick.
   A full run takes minutes (each dead row waits for its TUI). Run it in the
   background or with a 600000 ms Bash timeout. Rows stream to stderr as they are
   decided (including a line before each terminal create) and the table prints at
   the end. A row only starts when its worst case still fits in
   `CM_RESUME_BUDGET_S` (540); `CM_RESUME_ROW_MAX_S` defaults to the sum of the
   row's timeouts (385 s). Later rows are `deferred`, exit 6: run again.
2. **One census per host**: `orca worktree ps [--environment <host>] --json`
   with a timeout. No answer is **offline**, not dead (rule 6): skip, keep the
   row, retry next tick; the first words of the error are shown. Never respawn an
   offline host's lane elsewhere. A row with no host is **unknown**.
3. **Find the worktree** by Orca id, else by path, and from here on use the path of
   the worktree Orca matched (a ledger path can be stale): the process check looks
   at the real directory. Absent on a reachable host:
   **missing**; leave alone and ask the owner. Absent from a census marked
   `truncated` (or whose `totalCount` exceeds the rows returned): **unknown**.
   Two or more roster rows that resolve to one worktree on one host (same Orca id,
   or the same normalised Orca path, so `/w/./dev` and a stale ledger path count):
   **duplicate**, one decision for the group, none acted on. At most one terminal is
   created per worktree per run, even if a group were missed.
4. **Count live agents.** Orca's `liveTerminalCount` is the evidence, as in the
   `standing-dead` test of `classify.jq` (`0`, or no agent entry, is dead; an
   agent's `state` goes stale after a restart, so it is not trusted over an
   explicit `0`). Unlike classify, a row with no `liveTerminalCount` at all is not
   read as zero: a live-state agent counts as live, an agent entry in any other
   state is **unknown**. The count is the number of top-level panes (no
   `parentPaneKey`). On the local host also count `claude` processes of this user
   whose cwd is the worktree or inside it (canonical paths; `pgrep -u`, then
   `/proc/<pid>/cwd` or `lsof`): a shell tab can sit beside a live agent tab, and
   a process Orca does not track still counts. The count is the larger of the two.
   Any input that cannot be read is **unknown**, left alone. The local process
   check must have run: if `pgrep`, `/proc` or `lsof` fails, a local row with no
   live agent is **unknown**, not dead. There is no process backstop on a remote
   host, so a remote terminal that is open but has no agent entry, or a remote row
   with neither count nor agent entry, is **unknown** too.

   | live count | status | action |
   |---|---|---|
   | 0, agent is claude | dead | step 5 |
   | 0, agent is codex, agy or unset | manual | resume by hand, claude --continue would start the wrong agent |
   | 1 | live | leave alone |
   | 2 or more | duplicate | send to neither, ask the owner which one keeps going (rule 4) |

5. **Resume a dead row, in the same worktree, never a new one**:
   1. **Re-check just before acting**: a fresh `worktree ps` for the host and a
      fresh process list. The census is minutes old by the time a late row is
      reached, and a lane may have been reopened by hand or by the tick since. A
      live agent now: **live**, no create. Anything unreadable: **unknown**.
   2. `orca terminal create --worktree id:<worktreeId> --command "claude --continue [--model <model>]" --json`
      (`path:` when Orca gave no id). No handle back: **failed**, fall to the
      handover respawn (SKILL.md § Stuck rule step 4).
   3. `terminal wait --for tui-idle`; one retry with a doubled timeout. Still
      not idle: **failed**, no nudge (a prompt typed into a starting TUI is lost).
      The new terminal is left open and its handle is printed: re-census before
      any handover respawn, or that creates a second agent.
   4. `terminal read --screen`, judged on its last 12 non-empty lines only (the
      replayed transcript above proves nothing), and fail closed. An unreadable
      screen, or a question menu (`Enter to select`, `Enter to confirm`, `Arrow
      keys`), is **held** (rule 3). A shell prompt as the last line, or no Claude
      TUI marker (and, locally, no claude process with that cwd), is **failed**:
      a bare shell, the usual result of "No conversation found". Nothing is typed.
   5. ONE `terminal send` naming `current` and the last status, asking the
      agent to check git status and its worktree comment, carry on, and set
      `cm:running`. A lane whose last status was `cm:idle` or `cm:blocked` is
      told to restore that status instead and start work only if there is any.
      Ledger text passes a character allow-list first (letters, digits, space and
      `# : . , _ / ( ) + @ = -`), so no shell metacharacter, quote or backtick is
      ever typed. A send that is not accepted is **held**.
      For a standing lane's own agent on this host, the nudge also carries the
      newest 1200 characters of the lane journal (`references/ledger.md` § Lane
      journal), through the same allow-list and marked as data.
6. **Print the table** (lane, status, action), then one `ask <owner>:` line per
   duplicate or missing row. Exit 0 when every row is live, resumed or offline;
   exit 3 when any row needs attention (failed, held, missing, unknown, manual,
   duplicate); exit 6 when rows were deferred. A failed or held resume leaves its
   terminal open and records the attempt: the same worktree is not resumed again
   for `CM_RESUME_RETRY_MIN` (30) minutes, so a bare shell does not collect one
   new terminal per tick.

```text
$ /concertmaster resume
  pr-sweeper     live       left alone
  dev-sweeper    dead       claude --continue --model sonnet, nudged (#412)
  ops-sweeper    live       left alone
  epic-billing   offline    retry next tick
```

A **held** row has a resumed agent and no nudge: the concertmaster reads that
terminal's pane (rule 3), answers or cancels what is showing, then sends the
nudge itself. It is not retried by the next run, which sees a live agent.
`--dry-run` makes the same decisions and sends nothing.

## Relation to the tick

The tick already classifies a standing lane with no agent as `standing-dead` and
respawns it with `claude --continue`. Resume extends that, it does not fork it:
`standing-dead` calls `scripts/resume.sh --host <h> --worktree-id <id> --path <wt>`,
and `/concertmaster resume` is the on-demand and boot entry to the same code,
over every roster row instead of only classified standing lanes (the tick passes
one row, so it never revives a row it just retired). A git-only lane that Orca
does not list is `standing-dead` in classify but `missing` here: respawn it by
hand. A live-but-silent session is not resume's business: the tick's stuck rule
and abrupt-session nudge cover it.

## Safety

- A `claude` started outside Orca on a remote host is invisible to resume (there is
  no process backstop there); a local one is caught by the process check.
- Check the live process and every terminal in the worktree before any resume;
  never create a duplicate next to a live agent (a bare shell tab is not an agent).
  Every unreadable input fails toward doing nothing, never toward a second agent.
- Never type into a question menu; hold the nudge. Never type into a shell.
- Never `tmux kill-server`, `pkill`, or any wildcard kill. Resume closes nothing.
- Resume never writes the ledger. After a successful resume, the next tick
  re-reads Orca and refreshes `terminal` (handles go stale after a restart).
- `claude --continue` takes the most recent conversation for the worktree. If its
  last messages are about another repo, or a headless `claude -p` run was the
  latest, it is the wrong conversation: treat it as stuck and ask before reusing
  it (resume does not check this).
- Unconfirmed against a real restart: if Orca restores tabs as shells but keeps
  old agent entries, `liveTerminalCount` above 0 with a stale entry reads as one
  live agent and resume does nothing; the tick's stuck rule catches it.
- `CM_TEST_CLAUDE_CWDS_CMD` replaces the process check and exists for the test
  only; resume warns when it is set. Never set it in a real environment.
- Terminology rules from `cfg.terminology.rules` apply. No em-dashes.

## Test

`scripts/test/resume-flow.sh` runs `roster.sh` and `resume.sh` against a stubbed
orca (plus one real process named claude for the real process check) with live,
dead, offline, duplicate, shared-path, missing, failed, held, manual and unknown
rows, and asserts the orca calls made and not made, plus the table and exit
codes. Run it after any change.
