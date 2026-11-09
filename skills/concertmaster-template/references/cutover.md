# Cutover: moving a host's lanes from Orca terminals to Plugly terminals

`scripts/cutover-host.sh <host>` moves the Claude lanes of ONE host from Orca terminals to Plugly terminals, one
lane at a time, in the same worktree, with `claude --continue`. It is a kit: nothing in it runs by itself. The first
real use is on one host after a deploy window, driven by the concertmaster.

```text
┌───────────┐  close by exact handle  ┌────────────────┐  claude --continue  ┌──────────────┐
│ Orca term │────────────────────────▶│ same worktree  │────────────────────▶│ Plugly term  │
│ (idle)    │                         │ path           │   banner verified   │ nudged       │
└───────────┘                         └────────────────┘                     └──────┬───────┘
      ▲            any failure after the close: rollback                           │
      └──────────── Orca terminal recreated, verified, handle refreshed ◀───────────┘
```

## When to use it

- The host is registered in Plugly (`plugly host list` names it) and its Plugly runtime answers.
- A deploy window is open or no lane is mid-merge. A lane that is mid-turn is skipped, never forced.
- `CM_CLI_KIND` does not matter to this script: it drives both CLIs by name (`ORCA_CLI_COMMAND` and
  `PLUGLY_CLI_COMMAND` pick the commands). Switching the rest of the skill to Plugly (config key `cli`) is a
  separate step, done after the last host is cut over.
- Run it ON the host being cut over (`<host>` = `local`). `--apply` is refused for a remote host: the turn check
  reads that machine's Claude transcripts. The dry run works for any host. See "Who runs it, per host" and "Cutover order" below.
- The exclusion is two-way and per `CM_HOME`: the cutover will not start while `resume.sh` of the SAME `CM_HOME` is mid-run, and
  that `resume.sh` stands down (exit 4) while the cutover holds `$CM_HOME/cutover-host.lock`, so a tick cannot start a second
  agent in the gap between a lane's old and new terminal. `resume.sh` is checked again right after the cutover takes its own lock, to
  catch one that started in between. A cutover run on ANOTHER machine (a remote `--apply`) holds a lock in THAT machine's
  `CM_HOME`, which the concertmaster host's `resume.sh` does not read: see "Hold the concertmaster's resume".
- Run it from OUTSIDE the lanes (an operator shell). A lane whose terminal is the caller's own
  (`$ORCA_TERMINAL_HANDLE` or `$PLUGLY_TERMINAL_HANDLE`) is `skip: self`.

## Procedure

1. **Dry run (the default).** `scripts/cutover-host.sh <host>` prints the pre-check lines and the plan table and
   changes nothing: no create, close or send, no ledger, handle file or journal write, no lock. Read every row.
2. **Canary.** `scripts/cutover-host.sh <host> --apply --lane <one worker>`: pick a plain worker, not a standing
   lane. Check its terminal, its next turn and `scripts/lane-handles.sh --get <worker>`.
3. **The rest.** `scripts/cutover-host.sh <host> --apply`. Lanes already on Plugly are skipped, so the run is safe to
   repeat after a stop. Run it in the background or with a long Bash timeout: each lane can wait up to
   `--wait-idle-s` (300) for an idle prompt, then up to a minute for the banner and the first turn.

Plan rows: `cutover` (claude, one live agent, on an Orca terminal), `manual` (the agent is codex or agy: never
restarted with `claude --continue`, move it by hand), `duplicate` (two live agents in one tree, or two ledger rows on
one path: ask the owner), `dead` (no live agent: `scripts/resume.sh`, not this script), and `skip: <reason>` (self,
already on plugly, not selected by `--lane`, no terminal handle, live check could not run, `cannot read the live model`
(the status line or banner is not on the lane's screen, or is not a known form: open the pane, or re-run when it shows),
`model mismatch (ledger X, live Y)` or `effort mismatch (ledger X, live Y)`). Every handle in the
table is read from the live agent through `live-agent.sh`; the ledger handle is never used to act. After the table the
dry run prints `rows:` (counts by row kind) and, when any, a `look:` list of the lanes whose pane could not be read.

`--lane <worker>` (repeatable) limits the run to those workers; `--except <worker>` (repeatable) leaves those workers out, and
wins over `--lane`. Both reject a worker that is not on the host (exit 2). Only the terminal that RUNS the script is
`skip: self`; every other lane, the concertmaster's own included, plans as `cutover` unless it is left out with `--except`.

**Model and effort come from the lane's live pane**, read by `spawn-verify.sh read` (the parser `check` uses). The
ledger `model` is `""` for standing lanes and a bare alias (`sonnet`) for a worker, so it is not the source. A bare alias
or an empty value is ignored; a full `claude-<family>-<n>-<m>` (or an effort level) in the ledger must agree with the
pane, else the lane is skipped. The relaunch and the later banner check use exactly what the pane showed. The pane is read again right before the close; a
lane whose model changed since the plan is skipped.

`--apply` prints the plan first and refuses (exit 1) while a selected row is `duplicate`; leave that lane out with
`--lane` for the others.

## Pre-checks

Each prints one `check <name>: ok` or `FAIL (<reason>)` line. All must pass or the run refuses with exit 1 (a dry run
too, so it doubles as a readiness test).

| check | passes when |
|---|---|
| `ledger-readable` | the ledger parses and belongs to this project |
| `plugly-host-registered` | `plugly host list` names the host (`local` is the local machine) |
| `plugly-terminals` | the Plugly runtime answers `terminal list` for the host |
| `orca-host-reachable` | Orca answers `worktree ps` and `terminal list` for the host |
| `claude-binary` | `spawn-verify.sh resolve` gives an absolute, non-stub claude on the host |
| `no-cutover-lock` | `$CM_HOME/cutover-host.lock` does not exist |
| `no-resume-lock` | no `resume.sh` run holds `$CM_HOME/resume.lock` |

## Per-lane steps (--apply)

Order: workers first, then standing lanes (ledger `standing: true`, or a lane-shaped name), the pr-sweeper last. Why:
a worker is the cheapest to lose a turn on; a standing lane carries a `/loop` and other lanes report to it; the
pr-sweeper merges and relays reviews, so it stays on its old terminal until every other lane has moved, and a run
that stops early leaves it untouched. Never in parallel.

| step | what |
|---|---|
| a | wait for an idle Claude prompt (no menu, no running tool, and no background shell, Monitor or subagent shown in the footer or a task row: closing the terminal would kill that work) up to `--wait-idle-s`; otherwise `skip: busy`, go on to the next lane. Never force-closed |
| b | lane journal entry `cm:handover cutover to plugly <UTC time>` (the resumed session reads it) |
| c | close the Orca terminal by its exact handle: the handle is resolved from the live agent again after the idle wait, and the Orca terminal list must show it on this lane's worktree as a claude terminal (a handle inherited from another tree makes the lane `manual` at the plan, `skip` at the close) |
| d | create a Plugly terminal in the SAME worktree path running `<claude> --continue --model <m> --effort <e>`, the model and effort the lane's pane showed (see above). A create that fails, times out or answers in a shape the parser does not read may still have made a terminal: every plugly terminal that appeared on the worktree since before the close is closed by its exact handle before anything else starts |
| e | `spawn-verify.sh check` on the new terminal must exit 0 for that same model and effort (a plain shell prompt is not proof) |
| f | rewrite the handle: `lane-handles.sh --worker <id>` (handle file and ledger), then `cm_worker_set_handle`; both must agree with the new terminal |
| g | send the `/loop` re-arm nudge (the text `boot-sweep.sh` uses, `lib.sh` `CM_NUDGE_TICK`) and wait until a `user` line carrying that text, stamped at or after the send, appears in a transcript written since (old nudges in the history and startup writes do not count; a transcript without timestamps never confirms, so the lane is rolled back) |

## Rollback

Any failure in c to g rolls back THAT lane: the new Plugly terminal is closed by its exact handle; an Orca terminal
running `claude --continue` is created in the same path (the call `resume.sh` makes) and verified; the handle is
refreshed from the live agent; `cutover failed: <step>` (`close`, `create`, `verify`, `handle`, `nudge`) goes in the
lane journal. The recreated Orca terminal gets the same `/loop` re-arm nudge. The run then STOPS (exit 1) and prints which lanes are done, failed and untouched. A close that was
refused leaves the Orca terminal in place, so there is nothing to recreate. If the rollback itself cannot recreate
a verified terminal the output says `LANE DOWN` (exit 3): run `scripts/resume.sh` for that lane at once. Before any Orca terminal is created, `live-agent.sh` must show no agent left in the tree. If the new Plugly terminal will not close, or an agent is still there after the wait (`CM_CUTOVER_EXIT_WAIT_S`, 15 s), or a refused close leaves the old agent's state unknown, nothing is created: `LANE STRANDED` (exit 3), check that lane by hand. A close the CLI refused or timed out on is judged from the Orca terminal list and the live agent after they settle (up to `CM_CUTOVER_EXIT_WAIT_S`), not from the answer: still open with its agent means never closed (nothing to undo); gone means the Orca terminal is recreated; gone with its agent still running, or unreadable, is `LANE STRANDED`. An old agent still running after an accepted close creates nothing either. A signal (Ctrl-C, a Bash-tool timeout) between the close and the end of a lane is journalled and exits 3 with a warning; check that lane's terminals. When a lane ends without a verified terminal (STRANDED or LANE DOWN) the recorded handle is made true: the lane reader refreshes it from whatever agent is live, and with no agent at all the ledger handle (which can only point at a dead terminal) is cleared and the report says so. A handle write that is refused during a rollback is reported (`NOT restored`), not hidden behind "rolled back". A lane is never left with no terminal and no message.

## Handle environment names

The self-skip and the live-agent check depend on which variable a terminal exports.

| runtime | variable | status |
|---|---|---|
| Orca terminal | `ORCA_TERMINAL_HANDLE` (also `ORCA_TAB_ID`, `ORCA_WORKTREE_ID`, `ORCA_WORKSPACE_ID`) | observed in a live Orca terminal; the dry run's own terminal read `skip: self` |
| Plugly terminal | `PLUGLY_TERMINAL_HANDLE` (also `PLUGLY_TAB_ID`, `PLUGLY_WORKTREE_ID`) | observed in a live Plugly terminal: own=<listed handle>, orca=UNSET. No `PLUGLY_*` variable is set in an Orca terminal |

`cutover-host.sh` treats a lane whose terminal is `$ORCA_TERMINAL_HANDLE` or `$PLUGLY_TERMINAL_HANDLE` as `skip: self`.
`live-agent.sh` (and `_cm_lane_agent_alive` in `lib.sh`, and the `teardown.sh` process scan) read the handle from the agent process's
environment: `PLUGLY_TERMINAL_HANDLE` when present and non-empty, else `ORCA_TERMINAL_HANDLE`. The whole environ is read first, so the
order of the two names does not matter. A lane that is already on Plugly is therefore found. When BOTH are set, non-empty and
DIFFERENT, the handle is AMBIGUOUS: an agent in an Orca terminal can carry a Plugly handle it inherited (the Orca daemon was started
from a Plugly shell), or the reverse, and the environ cannot say which terminal it runs in. Then `live-agent.sh` gives no handle
(`lane-handles.sh` reports `no-handle` and writes no terminal), `_cm_lane_agent_alive` answers 3 (cannot tell, fail closed), and the
`teardown.sh` scan refuses the teardown, naming both candidates (`ambiguous(plugly=...,orca=...)`): such a process is never a leftover
and never exempt. The rule is `cm_environ_handle` in `lib.sh`.

**Check the Plugly names BEFORE the canary's `--apply`, on a throwaway terminal.** Create a Plugly terminal in a scratch
worktree that is not a lane, read the variables in it, close it by its exact handle:

```bash
H=$(plugly terminal create --worktree path:<scratch worktree> --title envcheck --json | jq -r '.result.terminal.handle')
plugly terminal send --terminal "$H" --text 'echo "own=${PLUGLY_TERMINAL_HANDLE:-UNSET} orca=${ORCA_TERMINAL_HANDLE:-UNSET}"' --enter --json
plugly terminal read --terminal "$H" --screen --json | jq -r '.result.terminal.tail | join("\n")' | tail -n 6
echo "listed=$H"
plugly terminal close --terminal "$H" --json
```

(The `create` reply shape is not observed yet: if `H` is empty, take the handle from `plugly terminal list --json` by title.)
`own=` must equal `listed=`, and `orca=` must be `UNSET` or ALSO equal `listed=` (these are terminal handles, not secrets: print them whole).

Expected, and what each result means:

- `own=` equal to `listed=`: the Plugly name is right. The script's own self-skip then works (it compares both
  `$ORCA_TERMINAL_HANDLE` and `$PLUGLY_TERMINAL_HANDLE`, `cutover-host.sh` "SELF_H").
- `orca=` ALSO equal to `listed=`: `live-agent.sh` finds a lane that is already on Plugly. Go on to the canary.
- `orca=UNSET` (only the Plugly name): this is the result observed in a live Plugly terminal, and it is fine. `live-agent.sh`
  reads the Plugly name first, so it finds the Plugly agent's handle. The canary goes ahead.
- `orca=` set to a DIFFERENT handle than `listed=` (inherited from the shell that started the Plugly daemon): STOP. Both names set
  and different is AMBIGUOUS, so every Plugly agent started by that daemon would read as having no handle: `live-agent.sh` finds no
  handle, `lane-handles.sh` marks the lane `no-handle` (no send), and `teardown.sh` refuses for its processes. Start the Plugly daemon
  from a shell with no `ORCA_*` variables (`env | grep '^ORCA_'` prints nothing), then re-run this check.
- `PLUGLY_TERMINAL_HANDLE` unset: stop. The self-skip is unproven there; run the cutover only from a shell outside every lane.

## What the dry run caught while the kit was built

A read-only dry run against live Orca and Plugly runtimes (nothing created, closed or sent) found:

- Before the model gate read the live pane, **zero** lanes to cut over: every claude lane was `skip: ledger model ... is missing or has no known banner form` (the ledger `model` is `""` for standing lanes and a bare alias for a worker).
- On a ledger of many rows most rows are `dead` (retired or done), a few are `skip` (model), one is `skip: self`, a couple are `manual`.
- A remote host: the `claude-binary` pre-check failed with `Could not resolve hostname <word>` when the ledger `hostname` was a bare word, until the ssh target rule below.
- An offline host: three pre-checks fail (plugly terminal list, orca worktree ps, ssh timeout) and the run refuses: correct.

Counts by plan row kind (`rows:` line) are the number to read first; row contents depend on the fleet.

## Who runs it, per host

`--apply` runs only ON the host it moves (the turn check reads that machine's Claude transcripts), so a remote host needs an
operator shell there. The dry run works from anywhere that can reach the host.

| host kind | who runs `--apply` | must be present on that host | `<host>` argument there | dry run from the concertmaster host |
|---|---|---|---|---|
| the concertmaster's own host | an operator shell OUTSIDE every lane (a plain terminal tab, not a lane's terminal), last of all, with `--except <concertmaster worker id>` | a checkout of this skill, `orca` and `plugly` on `PATH`, claude binary, `jq`, the project ledger | `local` | `scripts/cutover-host.sh local` |
| an Orca environment host (a remote Linux worker box registered in Orca and Plugly) | a short-lived terminal the concertmaster creates on that host (`orca terminal create --environment <host> ...`), or `ssh <host>` | a checkout of this skill, `orca` and `plugly` on `PATH` (the host's own runtimes), claude binary, `jq`, a ledger or config for that host (`CM_HOME`/`CM_LEDGER` pointing at a copy that holds its workers) | `local` | `scripts/cutover-host.sh <host>` |
| a remote Linux box reached by ssh only | `ssh <host>` into a shell with this skill checked out | as above | `local` | `scripts/cutover-host.sh <host>` with `CM_SSH_TARGET=<ssh alias>` if the alias differs from the host name |
| a Mac | NOT SUPPORTED for now | `live-agent.sh` reads the agent's terminal handle from Linux `/proc/<pid>/environ` and exits 3 elsewhere, so every row on a Mac plans as `skip` (live check could not run) | n/a | the dry run shows exactly that. What it would need: a non-`/proc` agent scan in `live-agent.sh` (process environment via `ps`), with its own test. A Mac's lanes stay on Orca |

Rules that hold for every row:

- On the host itself the argument is always `local`: the script's `<host>` is relative to the runtime the shell talks to.
- The ledger on that host must list the workers whose `host` is `local` there. The dry run from the concertmaster host
  is the way to see what that host's plan will be before anyone goes there.
- **A remote `--apply` needs the concertmaster's `resume.sh` held** (next section): the lock the script takes is in the remote shell's
  own `CM_HOME`, and the concertmaster host's tick would still see a lane between its closed Orca terminal and its new Plugly agent as dead.
- The shell that runs `--apply` should not be a lane's terminal: that terminal's row is `skip: self` and has to be moved by hand.
- `--apply` is refused for a remote `<host>` (exit 2), so it always runs on the host with `local`. It writes the new handles into the
  ledger and the lane handle files of THAT shell's `CM_HOME`, and the `cm:handover cutover to plugly` journal entries into that
  `CM_HOME`'s lane journals: on a remote host that is a COPY of the ledger. The concertmaster's own ledger catches up by itself:
  `lane-handles.sh` (run every tick, SKILL.md step 2c, and by hand with `--worker <id>`) re-resolves each remote worker's handle
  from `live-agent.sh` over ssh and rewrites the handle file and the ledger terminal. The journal entries stay in the copy: append
  one on the concertmaster host (`scripts/lane-journal.sh append <lane> "cm:handover cutover to plugly <UTC time>"`) if the lane's
  next session should read it. Throw the ledger copy away after the run; nothing reads it back.

**Covered by the suite:** the dry run for `local` against stub runtimes (including `skip: self` for the shell's own terminal), the model
gate reading panes, the ssh target rule (argv recorded) and `--except`. **Verify on first use:** a dry run from the concertmaster host for
each remote host (the host-name alias resolves, `claude-binary` passes); `orca terminal create --environment <host>` for the
operator terminal; the skill checkout and ledger copy on each remote kind; that `lane-handles.sh` on the concertmaster host picks up a
remote worker's new Plugly handle (needs the Plugly environment names above); the Plugly handle variables; a real `--apply`.

### Hold the concertmaster's resume (every remote `--apply`)

`resume.sh` on the concertmaster host loops over every host in the roster and creates terminals with `--environment`, so it
can start an Orca claude in a remote lane that is, for a moment, between its closed Orca terminal and its new Plugly agent
(the respawn guard narrows that window but only sees an agent once its process exists). `resume.sh` stands down (exit 4)
while `$CM_HOME/cutover-host.lock` names a live process whose command line contains `cutover-host`. A remote run locks the
REMOTE shell's `CM_HOME`, so the concertmaster takes the same lock in ITS OWN `CM_HOME` with `scripts/cutover-hold.sh`, on the
concertmaster host, for the whole remote run (the canary included):

```bash
scripts/cutover-hold.sh start --hours 4     # refuses (exit 1) if a lock exists already: a cutover, a forgotten hold, a stale one
scripts/cutover-hold.sh status               # must say held; check again once the remote run has started (the stand-in runs in its own session where `setsid` exists; without it, on a Mac, it only ignores a hangup, so start it from tmux)
# ... the operator runs the remote cutover-host.sh --apply ...
scripts/lane-handles.sh --worker <id>        # for EACH moved worker, from the concertmaster host: it must print the new Plugly handle
scripts/cutover-hold.sh release              # only then
```

Why in that order: until `lane-handles.sh` has re-resolved each moved worker from the concertmaster host (over ssh, through `live-agent.sh`)
its ledger still names the closed Orca terminal, and an early release lets a tick treat the lane as dead. If `lane-handles.sh` does not
print the new handle, keep the hold and fix that first (see "Handle environment names"). While it is held `resume.sh` stands down for EVERY host (a tick
resumes nothing, by design) and `cutover-host.sh` on the concertmaster host fails its `no-cutover-lock` pre-check, so run the dry runs
before the hold or after the release. The hold expires with its stand-in process (`--hours`, 1 to 24, default 4): release it as soon as the
host is done, and always on failure; `release` kills only the stand-in it started (it checks the process name, never a reused pid).
`start` exits 130 when it is interrupted (INT, TERM or HUP, even during the script's own setup) before the hold is taken, with nothing held and nothing left behind (`release` interrupted may be half done: run it again and check `status`. One window is not re-runnable: a signal between `release` removing the lock's `pid` file and removing the lock directory leaves a lock that names no pid, and the rerun refuses with `names pid none, not our stand-in`. When `ps` shows no cutover and no `cutover-host-hold` process, remove that lock by hand, as in the paragraph below); a retry loop must stop on 130, not retry. A signal that arrives after the hold is recorded is ignored and the start still ends `held` (exit 0), so after ANY interrupt of `start` or `release`, run `cutover-hold.sh status` before trusting the outcome. `start` refuses (exit 1) while `resume.sh` is running (`$CM_HOME/resume.lock`): an agent create it already started could still land after "held". Wait for it to end and start again; it checks once more after the lock is made, and undoes the lock if `resume.sh` started meanwhile. `start` and `release` run one at a time: each holds an exclusive `flock(1)` on `$CM_HOME/cutover-hold.claim.lock` for its whole critical section, waited for up to `CM_HOLD_CLAIM_WAIT_S` (default 20 s, at most 9999). The kernel drops that lock when the process ends however it ends, so nothing is stale and nothing is reaped. Several `start`s at once, from an expired hold or from fresh state, leave exactly one holder and one stand-in, and the others exit 1 (a one-off soak, not committed: five concurrent starts, 60 rounds each for an expired hold, fresh state and a claim owner that died holding the claim, once idle and once at a load average of about 16 on four cores, 360 of 360 rounds with exactly one holder, one stand-in, no orphan and a release that always worked; what the committed suite re-runs on every pass is five concurrent starts from an expired and from fresh state, three rounds each, a live and a killed claim owner, and the other cases listed in `scripts/test/cutover-host.sh`). `flock(1)` is required (Linux util-linux; stock macOS has none, and a Mac cannot be cut over anyway, see the table above): without it `start` and `release` fail closed (exit 1) instead of running unserialized, so a concertmaster on a Mac must hold `resume.sh` by hand (do not run it) for a remote run. The stand-in is started with the claim's file descriptor closed, so it does not keep the claim. The hold stops `resume.sh` only: **hand respawns of that host's lanes (SKILL.md, exit 5, lanes listed missing) are suspended for the whole remote run too**, or a lane could get two agents.

If a `start` was hard-killed (SIGKILL, power loss) between creating the lock and writing its pid, or the stand-in's pid was reused after it expired, `release` and `start` both refuse and leave the lock. When `ps` shows no cutover and no `cutover-host-hold` process, remove it by hand with the literal path of your `CM_HOME` (default `~/.concertmaster`): `rm -f ~/.concertmaster/cutover-host.lock/pid; rmdir ~/.concertmaster/cutover-host.lock`.

`cutover-hold.sh status` says whether it is held, `EXPIRED` (the stand-in is gone, so `resume.sh` is NOT held; the next `start` or a `release` cleans it up) or held by something else. The stand-in runs in its own session (`setsid`) so a hangup of the calling shell does not end it; `release` exits 1 and warns `NOT released` on stderr when it had to leave a lock that is not its own. If it cannot be taken, the concertmaster does not run `resume.sh` at all for the duration
(its tick skips the resume step). Tested in `scripts/test/cutover-host.sh`: start, resume stands down, second start refused, release, a foreign
lock left alone, a reused pid not killed.

### The ledger copy on a remote host

`cutover-host.sh local` reads the ledger of its own `CM_HOME`, so on a remote host that is a copy that lists the host's workers as `local`.
Make it from the concertmaster's ledger, never editing the original, in a fresh state dir on the remote host:

```bash
# on the concertmaster host: where its ledger really is (CM_LEDGER, else $CM_HOME/ledger.json)
bash -c '. scripts/lib.sh; cm_ledger_path'
# on the remote host; <host> is the Orca environment name the concertmaster's ledger uses; the copy lands in a fresh CM_HOME
mkdir -p "$HOME/.concertmaster-cutover"; scp <concertmaster host>:<the path printed above> "$HOME/.concertmaster-cutover/source.json"
jq --arg h "<host>" '{schema, project, hosts, workers: (.workers | with_entries(select((.value | type) == "object" and .value.host == $h)) | map_values(.host = "local"))}' \
  "$HOME/.concertmaster-cutover/source.json" > "$HOME/.concertmaster-cutover/ledger.json"
export CM_HOME="$HOME/.concertmaster-cutover"
jq '{project, workers: (.workers | length)}' "$CM_HOME/ledger.json"   # project must be set, workers must be the count you expect for this host
```

Check that last line before running anything: a `project` of `null` (a legacy ledger without the field) is refused by the ledger guard
outside the project state dir (add it: `jq '.project = "<project id>"'`), and `0` workers means a wrong path or host name (the dry run then
plans no rows, quietly). Only `schema`, `project`, `hosts` and `workers` travel to the remote host (the fields the scripts read); the `project` field travels with the copy otherwise. Its worker rows now say `local`; the original keeps `<host>`.
(The jq filter is checked; the scp, the guard on a real remote state dir and the run are verify-on-first-use.)

## Cutover order

1. **Dry run every host from the concertmaster host.** `scripts/cutover-host.sh <host>` for `local` and each remote host.
   Read the `rows:` line, the `look:` list and every pre-check. A host that refuses (offline, not registered in Plugly,
   ssh target not resolving) is fixed or left out; nothing is changed.
2. **Canary one plain worker on one non-concertmaster host.** First the throwaway-terminal check in "Handle environment names"
   (BEFORE any `--apply`). Then hold the concertmaster's resume (`scripts/cutover-hold.sh start`) and make the ledger copy (the two sections above). Then, on that host,
   from an operator shell:
   `scripts/cutover-host.sh local --apply --lane <one worker>`. Check the lane's terminal, its next turn, and
   `scripts/lane-handles.sh --get <worker>` (on the host) and `--worker <id>` from the concertmaster host.
3. **That host whole.** `scripts/cutover-host.sh local --apply` on it. Workers first, then standing lanes, the pr-sweeper last.
   Re-run for skipped (busy) lanes. The run ends clean (orphan check 0) before moving on.
4. **The next hosts**, the same way: dry run, canary one worker, the host whole.
5. **The concertmaster's own host LAST**, from an operator shell outside the lanes. The concertmaster's own lane is moved by hand
   at the very end. Why by hand, and why `--except`: from an operator shell the script's `skip: self` covers only the terminal running
   the script, so the concertmaster's standing row plans as `cutover` (before the pr-sweeper) and the script would close it as soon as
   it is idle, mid-orchestration, leaving the manual steps below pointing at a terminal that is gone. There is no way to ask the
   script to skip it by name other than `--except`, so name it. (Run from INSIDE the concertmaster's terminal instead, its row is
   `skip: self` by itself and the same manual steps apply.)
   1. `scripts/cutover-host.sh local --apply --except <concertmaster worker id>` from the operator shell: every other lane moves,
      the concertmaster row reads `skip: not selected (--lane or --except)`. Dry-run it twice first: WITHOUT `--except`, to see that the concertmaster row plans as `cutover` (a left-out lane's pane is not read, so with `--except` the row can only say `was: skip, live model not read`), then WITH it, to see that it is left out and every other row is as expected.
   2. In the concertmaster terminal, write the lane journal entry (`scripts/lane-journal.sh append <lane> "cm:handover cutover to plugly <UTC time>"`)
      and let its turn finish. Look at the footer of that terminal: a `N shell(s)` or `monitor` suffix, a task row or `ctrl+t to show tasks`
      means background work that closing the terminal KILLS. Wait for it or stop it first.
   3. `scripts/spawn-verify.sh read --terminal <handle>` and note what it PRINTS: `live: <family>-<n>.<m> <effort>` (for example
      `live: sonnet-5.5 high`). Use exactly those values below, never the example's. Close that Orca terminal by its exact handle
      (`orca terminal close --terminal <handle>`). Wait until the old agent is gone (`scripts/live-agent.sh <path>` exits 1), then create the
      Plugly terminal in the same worktree:
      `plugly terminal create --worktree path:<path> --title cutover --command "<claude> --continue --model claude-<family>-<n>-<m> --effort <effort>"`
      (the launch flag is the printed model with dashes: `sonnet-5.5` becomes `claude-sonnet-5-5`; `<claude>` is the absolute path from
      `scripts/spawn-verify.sh resolve`).
      Rollback, if the new terminal does not verify in step 4 or the create fails: close any new Plugly terminal on that worktree by its exact
      handle (`plugly terminal close --terminal <h>`), confirm `scripts/live-agent.sh <path>` exits 1, then recreate the Orca terminal with the same
      launch line (`orca terminal create --worktree path:<path> --title resume --command "<same line>"`) and check it with `scripts/spawn-verify.sh check`. The lane has
      no agent until that is done; `scripts/resume.sh` does the same recreate when the lane is a ledger row.
   4. `CM_CLI_KIND=plugly scripts/spawn-verify.sh check --terminal <new handle> --model <family>-<n>.<m> --effort <effort>` (the values `read`
      printed; `CM_CLI_KIND=plugly` makes it read through the Plugly CLI, without it the new handle is looked up in Orca and the pane is
      "unreadable"); then `scripts/lane-handles.sh --worker <id>` and nudge it with the `/loop` text (`CM_NUDGE_TICK` in `lib.sh`).
   5. `scripts/cutover-host.sh local` (dry run) must show every lane `already on plugly` and no orphan.

## The orphan rule

After the last lane (skipped only by the test) the script checks the lanes it owns (cut over now, or already on
Plugly), under the Plugly CLI. An orphan is:

- a live agent whose terminal is not the ledger handle,
- a ledger handle that is not a live terminal in Plugly, or
- an Orca AGENT terminal (claude, codex, agy) still open on a cut-over worktree. A plain shell tab a lane keeps on its worktree is not an orphan.

Any orphan is listed and the run exits 1. The check reuses `live-agent.sh`, `lane-handles.sh` and the two terminal
lists; it does not run `discover.sh` (that needs GitHub) or add a second census.

## Exit codes

| code | meaning |
|---|---|
| 0 | every selected lane is on Plugly (or the dry run is clean) |
| 1 | refused (pre-check, duplicate row, lock), a lane failed and was rolled back, or orphans |
| 2 | usage error (bad flag, `--lane` not on the host, `--apply` on a remote host, `--skip-census` with `--apply` outside the test) |
| 3 | a lane has no terminal (`LANE DOWN`, use `resume.sh`), is `STRANDED` on a plugly terminal that would not close, or the run was interrupted mid-lane |
| 4 | finished, but a lane was skipped (busy, changed since the plan, journal write failed) or a selected lane is one this script does not move (manual, dead, self, model without a banner form): re-run later or read the plan |

## Limits

- `claude --continue` takes the most recent conversation for the worktree (see `references/resume.md` § Safety).
- The live-agent check reads the terminal handle from the agent's environment (`PLUGLY_TERMINAL_HANDLE` first, else
  `ORCA_TERMINAL_HANDLE`; both set and different gives no handle). If a Plugly terminal exports it under yet another name, step f fails on the canary and the lane is
  rolled back: that is the signal to teach `live-agent.sh` the name before cutting over more lanes. See "Handle environment names".
- The ledger row needs no `model` or `effort`: the lane's pane is the source. If it carries them, they must agree with the
  pane (a bare alias or an empty value is ignored; an effort that is neither empty nor a level is a skip, so a bad key is fixed, not hidden). The new terminal is started with exactly the pane's model and effort and the banner is
  checked against them. No `--dangerously-skip-permissions` is passed: if a lane normally runs in bypass mode, check on
  the canary that the footer still shows it; if not, the launch flags are the next change.
- Timing variables (`CM_CUTOVER_POLL_S`, `CM_CUTOVER_CALL_S`, `CM_CUTOVER_VERIFY_WAIT_S`, `CM_CUTOVER_EXIT_WAIT_S`,
  `CM_CUTOVER_CREATE_GRACE_S`, `CM_BOOT_CONFIRM_S`) must be whole seconds, read as decimal (`08` is 8); anything else exits 2
  before any call. `CM_CUTOVER_CALL_S` and `CM_CUTOVER_POLL_S` must be at least 1.
- A recreated Orca terminal must show exactly its own agent twice in a row; no agent at all is `LANE DOWN` (exit 3), not a clean rollback. The final sweep of a run that stopped on a rolled-back lane also waits for what it closed to exit and recounts the agents (a warning, not a silent pass, if it cannot be confirmed).
- The ssh target of a remote host is `lib.sh` `cm_ssh_target`, the same rule `live-agent.sh` and `discover.sh` use: `CM_SSH_TARGET`; else the ledger `hosts.<h>.sshTarget` (an explicit ssh alias or address, for a host whose ssh name differs from both its Orca name and its hostname); else `hosts.<h>.hostname` when it is an address (holds a dot or colon); else the host name as an ssh alias. A dotless ledger `hostname` is what `hostname -s` prints (the identity `teardown.sh` and `live-agent.sh` compare), not something ssh can resolve, so it is not a target. A target that starts with a dash or holds whitespace is refused by the `claude-binary` pre-check, and the ssh call in `spawn-verify.sh` uses `--`. A host whose ssh alias differs from its Orca environment name needs `CM_SSH_TARGET=<alias>` for that run (it names ONE host).
- After a plugly create that gave no usable answer the script waits `CM_CUTOVER_CREATE_GRACE_S` (10) for a late terminal,
  and after the Orca terminal is recreated it looks for late plugly terminals once more and counts the agents in the tree;
  anything other than the recreated terminal's agent, seen twice in a row within `CM_CUTOVER_EXIT_WAIT_S`, is `LANE STRANDED` (the report names the verified Orca terminal, points the ledger at it and says the `/loop` was not re-armed). A last sweep for late plugly terminals also runs before the report of a run that stopped on a rolled-back lane.
- Background-work detection reads the footer and task rows of the pane (`N shell(s)`, `N background tasks`, `ctrl+t to
  show tasks`, in the last four lines of the pane, or a task row starting with a circle). It is a heuristic and errs toward "busy"; a lane that shows none of
  these while working is still caught by the running-tool check, not by this one.
- Not tested without a live fleet: a real Plugly terminal start, real banner timing, the host's real `PATH`.
