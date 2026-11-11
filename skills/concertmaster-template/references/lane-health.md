# Lane health: is every lane really running

A reboot, a Spot preemption, a restart of the terminal daemon or a crash can leave a lane with no process while the
ledger still says `running`. Nobody sees it until someone counts sessions by hand. `scripts/lane-health.sh` makes that
count every loop, ties each stop to its cause, resumes a healthy session once, and alerts when it does not come back.
`scripts/cm-status.sh` (the `/cm-status` view, `companions/cm-status.md`) shows the result in plain words.

```text
┌──────────────┐  every loop  ┌────────────────┐   prints  ┌────────────┐
│ each lead    │─────────────▶│ lane-health.sh │──────────▶│ cm:health  │
│ (own kids)   │              │ --lead <id>    │           │ line in its│
└──────────────┘              └────────────────┘           │ comment    │
┌──────────────┐  every tick  ┌────────────────┐   writes  ├────────────┤
│ concertmaster│─────────────▶│ lane-health.sh │──────────▶│ ledger     │
│ (leads and   │              │ --all --act    │           │ + alerts   │
│  unowned)    │              └───────┬────────┘           └────────────┘
└──────────────┘                      ▼
                              ┌────────────────┐
                              │ cm-status.sh   │  read-only, a fresh
                              │ (/cm-status)   │  --no-write pass
                              └────────────────┘
```

## Who checks what

| checker | command | scope | resumes | sends alerts |
|---|---|---|---|---|
| concertmaster, every tick (SKILL.md § The tick step 2) | `lane-health.sh --all --act` | every ledger worker, plus any agent in a `worktrees.path_match` worktree that no ledger row holds | leads, and sessions no lead owns | yes |
| each lead, every loop (`references/lanes.md` § What the lead's ticker does) | `lane-health.sh --lead <your worker id> --act --line` | its own children (ledger `parent`, else its own `cm:child` lines) | its own children | no: it posts the `cm:health` line in its comment |

The split means two checkers never resume the same session. With the concertmaster down, the leads keep checking their
children; the digest says `concertmaster check missing` once the last `--all` pass is older than two lane loops.

## What it reads, per host

This machine is read directly; any other host over ssh to `cm_ssh_target` (the probe is streamed to `bash -s`, the
remote `hostname -s` must match, as `live-agent.sh` does). A host that does not answer is `unknown (host down)` for
every session on it, and nothing is resumed anywhere else (hard rule 6).

| fact | source |
|---|---|
| live agents | processes of this user on a terminal whose command is a `respawn.live_agents` name; never a zombie or a tty-less daemon. Read from `/proc` on Linux; on a host with no `/proc` (macOS) from `ps -A` (pid, uid, parent, state, tty, elapsed time, name, argv) with each agent's cwd from `lsof -a -p <pid> -d cwd`. A live agent whose cwd `lsof` cannot read, that is missing from the argv table, or whose command changed by the time its cwd is read makes the scan incomplete; with no `ps` or `lsof` the host is `unknown` and says why |
| session id | the cmdline `--resume <id>` (or `--session-id`; with no `/proc`, where argv is split on spaces, only a session-id-shaped word given once, whose transcript is in that worktree), unless a transcript in that cwd is newer than that id's own and was written after the process started while it is the only agent in that cwd, headless ones counted (`/clear` starts a new session in the same process); else the ONE transcript in that cwd's `~/.claude/projects/<dir>`; with two or more, the newest one written after the process started when it is the only agent there (a `--continue` resume); otherwise unknown. A recorded id is carried forward only for the same pid |
| runtime | the first parent process whose name, argv[0] basename, or interpreted script path is a `plugly` or `orca` program, else the handle variable in its environment |
| model, effort | `--model` and `--effort` on the cmdline, else the last recorded value, else the ledger row |
| handle | `PLUGLY_TERMINAL_HANDLE`, else `ORCA_TERMINAL_HANDLE` (both set and different: none); with no `/proc`, best effort from `ps -E` on macOS (split on spaces) |
| permission mode | `--dangerously-skip-permissions` or `--permission-mode bypassPermissions` on the cmdline, kept as `live.bypass`. With no `/proc` the argv is split on spaces, so a prompt that only names the flag would read as it: there no flag word is false, the flag word with the footer itself on one of the pane's bottom three lines (`⏵⏵ bypass permissions on`) is true, the flag word on an idle or busy pane with no footer is false, and anything else (a menu, an unread pane) keeps what was recorded for that pid, else stays unrecorded |
| last write | the mtime of that session's transcript |
| boot | `/proc/stat` btime, else `uptime -s`, else `sysctl -n kern.boottime` (macOS); `last -x` lines are kept as evidence |
| preemption | `health.cloud: gce` asks the metadata server (`instance/preempted`, `scheduling/provisioning-model`); a `Power key pressed` line logged by the previous boot counts too |
| daemon restart | `health.daemon_units`: a unit whose `ActiveEnterTimestamp` is later than boot |
| pane | the bottom 12 non-empty lines of the agent's terminal (limit and error on the bottom 6 only) |
| last task | the first line of the worktree comment, else the ledger `lastComment`, else `current` or `task` |

Ledger paths are read too, not only the CLI's worktree list: a worktree one runtime does not list is still checked.

## The seven words

| mark | word | when | meaning line, for example |
|---|---|---|---|
| ● | running | a busy pane (`esc to interrupt`), or a transcript written in the last `health.running_seconds` | (the last task line) |
| ○ | idle | one process, a quiet pane, an older transcript | fine, nothing to do |
| ? | waiting on you | a question menu under `health.stuck_minutes`; a `cm:blocked`, `cm:ask` or `cm:waiting-owner` first line, or `blocked-on-owner`; two copies of one session or worktree | a question menu is open: Which option? |
| ⚠ | stuck | a usage limit (the usage-credits menu included), an API error, or a menu that has waited `health.stuck_minutes` | account limit on screen: Resets at 5pm; the check never answers it |
| ✗ | stopped | the row should run (state not asleep, retired, done, teardown or queued) and no process holds it | stopped: the server restarted at 10:27 and this one did not come back; I will retry once |
| z | asleep | state `asleep`, no process | put to sleep on purpose at 09:00; never resumed by the check or a reboot |
| · | unknown | no ledger row; the host did not answer; the scan was incomplete; retired work came back | not in the ledger; not slept: branch not merged |

The cause of a stop, first hit wins: a boot after the session's last write is `reboot` (`preemption` with the evidence
above); a daemon restart after it is `daemon restart`; a pane last seen on a limit is `limit`; no last write known is
`unknown`; otherwise `crash`.

## What `--act` does

| case | action |
|---|---|
| stopped, and running, idle or waiting the pass before | ONE resume in its owner runtime: `<agent> [--dangerously-skip-permissions] --resume <full id> [--model m] [--effort e]` in the same worktree (`terminal create --worktree path:<path>`); the bypass flag only when `live.bypass` is true (the process it replaces ran with it): a resume never widens a session's permissions, and a session whose mode was never recorded (it stopped before the mode was kept) is not resumed automatically, the meaning line says so. The binary from `spawn-verify.sh resolve` (or `CM_HEALTH_AGENT_BIN`). First a fresh probe: any process on that worktree or id means left alone. The try is written to `$CM_HOME/cache/lane-health-attempts/` before the create is checked |
| verify | within `health.verify_seconds`: exactly one process on that session id, an idle or busy agent pane (a trust dialog, a menu or an error is not up) with `bypass permissions` on it when bypassed, and that id's transcript is the newest in the worktree. Else `retry 1 failed`, the terminal is left open to look at |
| stopped again, or the try failed | no second try until the session has run `health.resume_reset_hours` after it; a lead alerts |
| a boot or daemon restart under `health.settle_minutes` ago | nothing is resumed on that host this pass: the host's own resume runs first |
| no session id, an agent other than claude, no record from before the stop | not resumed; said in the meaning line; a lead alerts |
| a child of a lead, in `--all` | left to its lead (`its lead <id> resumes it`): its ledger `parent`, or any worktree comment on any host with a `cm:child <name>[@host]` line for it (the concertmaster's own excepted) |
| unknown worker, `--all` | put to sleep (exact pid, its cwd checked first, and on a remote host its `hostname -s`; TERM and 10 s; its terminal closed; an `asleep` ledger row added with `adopted: true`) only when it is not lead-shaped, has a session id and a known last write (so it can be woken again), runs no second copy, its tree is clean, HEAD is merged into `origin/<default>` and not on its first-parent line (a fresh branch is not merged work), and its transcript is `health.unknown_idle_minutes` old. It is probed again right before the kill: a transcript that moved or a busy pane means not slept |
| unknown that looks like a lead (a configured lane, an ownership lead, a lane-shaped name, the concertmaster, or the name or session id of any `standing: true` ledger worker) | never slept; the owner is asked |
| a worker whose comment first line is `cm:done` or `cm:retire` | not expected to run: never `stopped`, never resumed |
| duplicate | alert; nothing touched (hard rule 4) |
| stuck | alert at `health.stuck_minutes`; a usage-credits or limit menu is never answered |
| `resume.lock` or a cutover lock held | no create and no kill this pass. While it acts, lane-health holds `resume.lock` itself (`resume.sh` and the cutover scripts accept a `lane-health` holder and stand down; no lock, no action), and every writing run holds a lock on its own record from before it reads it to after it writes it (`$CM_HOME/lane-health.lock` for `--all`, `<cache file>.lock` for each lead; a second run on the same record exits 4) |
| a long pass | a resume or a sleep starts only while its worst case (verify, create, probes) still ends inside `health.run_budget_seconds` (540) from the start of the run; the rest, and any alert past it, waits for the next pass |
| a host whose worktree comments could not be read (or `CM_HEALTH_NO_COMMENTS=1`) | a `cm:child` claim there may be unread, so a parentless worker (never a lead) is not resumed and no unknown is slept this pass; it says which host. Only a host that holds a live ledger worker or a lead counts, and the comments are read through the CLI even when ssh fails; a host gone for good goes in `health.ignore_hosts` |
| an agent with no terminal (a headless `claude -p`) in the worktree, or on the session id | counted as a copy: the session is `unknown`, never resumed beside it, and it blocks a `wake` |
| a host that did not answer, a process scan that was incomplete | `unknown`; nothing resumed or slept there, and the session keeps its last verdict, so a healthy session that stopped while its host was down is still resumed once the host is back |

## Alerts

`--all --act` only. One per event, recorded in ledger `health.alerted` (kept 7 days; a failed send is retried on the
next two passes): an inbox note `$CM_HOME/inbox/lane-health-<kind>-<UTC>-<pid>.md` (the tick reads it with the other
fleet notes) and the send hook, `health.alerts.send`, else `messaging.owner_digest.send` when its adapter is not
`none`. `{to}` and `{text}` in the command become `"$CM_ALERT_TO"` and `"$CM_ALERT_TEXT"`: the values reach it as
environment, never as command text, so pane text in an alert cannot run. Write them bare, never inside quotes.

| kind | when | text |
|---|---|---|
| `lead-stopped` | a lead is stopped after its one try, or cannot be tried | `<project>: lead <name> on <host> is stopped: <meaning>.` |
| `host-reboot`, `host-preemption` | a boot the check did not see before (the host was up at the last pass), once the host has settled | `<project>: <host> restarted at 10:27. Came back: 3 (a, b, c). Not back: 1 (d (stopped)).` |
| `stuck` | stuck for `health.stuck_minutes` | `<project>: <name> on <host> is stuck for 34 min: <meaning>.` |
| `duplicate` | two processes on one worktree or one session id | `<project>: two copies of <name> on <host> (pids 4242, 4307). Nothing was touched; say which one keeps going.` |

The texts name sessions and hosts: point the hook at the owner or a private group, never a wide chat.

## Sleep (leads only stop this way)

A lead holds long context that a teardown destroys, so no agent ever cleans up or tears down a lead (SKILL.md hard rule
27). Only the owner cleans up a lead; an agent asked to do it asks the owner to confirm first (an approved
`remove-standing` ask, then `teardown.sh --force-standing <ask-id>`). A lead can be put to SLEEP:

```bash
scripts/lane-health.sh sleep <worker-id>            # dry run: what it would stop
scripts/lane-health.sh sleep <worker-id> --apply    # stop the process (exact pid), close its terminal, state asleep
scripts/lane-health.sh wake  <worker-id> --apply    # resume the same session id, verified, state back
scripts/lane-health.sh wake  <worker-id> --apply --bypass     # only for a row whose permission mode was never recorded
scripts/lane-health.sh wake  <worker-id> --apply --no-bypass  # the same, without the bypass (also narrows a bypassed one)
```

Sleep keeps the worktree, the branch, the transcript and the ledger row (`state: asleep`, `asleepAt`, `asleepFrom`, the
session id under `live`), and puts a `cm:asleep <UTC> ...` line at the top of the worktree comment (`wake` takes it off):
a lead on a host with no ledger reads its children from comments only, and that line is how it knows. It refuses a duplicate and a session with no known id (it could not be woken on the same
session), and it refuses while the scan of that host is incomplete (a second copy may be unseen). Wake resumes in the
permission mode the session slept in (`live.bypass`) and never widens it: `--bypass` on a row recorded without it is
refused, and a row slept before the mode was kept needs `--bypass` or `--no-bypass`. `roster.sh`, `resume.sh`, `boot-sweep.sh` and `runtime-check.sh` skip an asleep row, so neither a tick nor a
reboot revives it; `teardown.sh` still refuses it as a standing row.

## Ledger fields

Per worker (`references/ledger.md`): `live` (host, runtime, pid, sessionId, sessionSource, handle, model, effort, agent,
bypass, lastTranscriptAt, checkedAt; kept when the process is gone, so a resume knows the id), `kind` (standing, worker,
asleep, retired), `shouldRun`, `lastTask`, `lastStopAt`, `lastStopCause`, `stopHistory[]` (last 10), `resumeAttempts`,
and `health` (word, meaning, paneState, paneSince, stopFromHealthy, healthySince, lastResumeAt, checkedAt). Top level:
`hostEvents[]` (`{host, at, kind: reboot|preemption|daemon-restart, evidence, watched, seenAt}`, last 200),
`hosts.<h>.bootAt` and `healthCheckedAt`, and `health` (checkedAt, mode, summary counts, attention, alerted). A lead's
own record of its children lives in `$CM_HOME/cache/lane-health-lead-<id>.json` on its host; it never writes the ledger.

## Env and tests

`CM_NOW`, `CM_HEALTH_SETTLE_MIN`, `_STUCK_MIN`, `_RUNNING_S`, `_UNKNOWN_IDLE_MIN`, `_RESET_H`, `_VERIFY_S`, `_POLL_S`,
`_SSH_S`, `_RUN_BUDGET_S`, `_CLOUD`, `_DAEMON_UNITS`, `CM_HEALTH_SEND`, `CM_HEALTH_AGENT_BIN`, `CM_HEALTH_NO_COMMENTS=1` (skip the
comment read). Tests: `scripts/test/lane-health.sh` (stubbed orca, plugly, ssh and host tools over a fake `/proc`, and stubbed `ps`, `lsof` and `sysctl` over the same processes for a host with no `/proc`).
