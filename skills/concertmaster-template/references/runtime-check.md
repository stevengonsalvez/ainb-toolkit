# Runtime restart check: re-arm lanes after an Orca restart

An Orca RUNTIME restart (the Orca process restarts, the machine does not) is the quiet sibling of a VM
reboot. Every terminal handle changes, sessions are resumed, and the `/loop` or `ScheduleWakeup` timer
of each standing lane silently dies with the old process. `scripts/boot-sweep.sh` never runs (no
boot), so without this check a lane stays dead until someone notices.

```text
┌──────────────┐   ┌───────────────────┐   ┌──────────────────┐   ┌─────────────────────┐
│ Orca restart │──▶│ runtime-check.sh  │──▶│ stale lane?      │──▶│ boot-sweep.sh       │
│ handles churn│   │ handles by PATH,  │   │ no turn for      │   │ --since --lanes     │
│ timers die   │   │ ledger refreshed  │   │ 2 x loop (1 x    │   │ one nudge, confirm  │
└──────────────┘   └───────────────────┘   │ after churn)     │   │ by transcript       │
                                           └──────────────────┘   └─────────────────────┘
```

## Where it runs
Once per tick, after the discover step (SKILL.md § The tick, step 2), on THIS host only. Give the call
a 600000 ms timeout (or run it in the background): each stale lane can wait up to
`CM_BOOT_CONFIRM_S` (60 s) for its nudge to be confirmed. `--dry-run` makes the same decisions and sends
and writes nothing.

## Per standing lane
Input is every ledger worker with `standing: true`, host local or unset, state not `gone` or
`repurposed`. The concertmaster itself (the `worktrees.self_name` directory) is never touched.

| step | rule |
|---|---|
| handle | the lane's ONE Claude terminal, found by worktree PATH in `orca terminal list` (never by the recorded handle). `workers.<id>.terminal` is rewritten when it differs. None: `no-terminal` (resume.sh's job). More than one: `duplicate`, left alone |
| churn | the recorded handle is gone from the list for that path: an Orca restart. The ledger row is stamped `terminalChurnAt` and stays "churned" until the lane's transcript is newer than that, so refreshing the handle on the first tick never hides the restart |
| stale | the newest Claude transcript is older than 2 x the lane's loop interval (1 x for a churned lane: its wake is already missed). Interval: `workers.<id>.loopIntervalMin`, else `lanes[].loop_minutes` in config, else `schedule.lane_loop_minutes` (30) |
| nudge | stale lanes go to `boot-sweep.sh --since <now - limit> --lanes <path>`, the same decision core as the boot sweep, in tick mode |
| text | churn: "Orca restarted, re-arm your `/loop`". Stale with no churn: a NEUTRAL status check (do nothing if your loop is armed), because nothing proves its timer died |
| resume.lock | while `$CM_HOME/resume.lock` exists nothing is sent: handles are still refreshed and each stale lane is reported `resume-in-progress` |

Tick mode of `boot-sweep.sh` (`--since <epoch> [--lanes <path,path>]`) differs from the boot path in
five ways: no Orca wait or settle delay, no inbox note, attempts kept per transcript in
`$CM_HOME/cache/runtime-sweep.tsv`, a pane is typed into only when its LAST line is a Claude footer
(`CM_FOOTER_RE` in `lib.sh`), and a lane nudged 3 times in 6 h is `gave-up` even if it took a turn each
time (`runtime-sweep-history.tsv`). The usual refusals still apply: question menu, mid-turn, shell
prompt, no sign of Claude, unreadable screen, duplicate terminals.

A nudge counts only when the transcript advances within `CM_BOOT_CONFIRM_S`; otherwise it is
`unconfirmed`, retried once, then `gave-up`. A lane that got going starts a fresh episode (the
attempt counter is keyed to the transcript mtime).

## Output
TSV, one row per lane: `lane  handle  age  result  detail`. Results: `ok`, `refreshed`, `nudged`,
`would-nudge`, `skipped`, `unconfirmed`, `gave-up`, `busy`, `menu`, `report`, `unreadable`,
`send-failed`, `no-ledger`, `not-standing`, `unknown`, `no-terminal`, `duplicate`,
`resume-in-progress`. Put every non-`ok` row in the turn-end report. Exit 0 unless the ledger is
unreadable (1) or usage is wrong (2).

## Config and env
`schedule.lane_loop_minutes` (default 30), `lanes[].loop_minutes` (per lane), `worktrees.path_match`
(scope, required), `worktrees.self_name`. Env: `CM_HOME`, `CM_PATH_MATCH`, `CM_SELF_PATH_RE`,
`CM_RUNTIME_SWEEP` (the sweep script, tests), `CM_CLAUDE_PROJECTS`, `CM_BOOT_CONFIRM_S`,
`CM_TICK_NUDGE` (the text, set by runtime-check).

The ledger is written under a lock, atomically, keeping its file mode, BEFORE any nudge, so a killed
run still leaves fresh handles.

## Test
`scripts/test/runtime-check.sh`: stubbed orca (live `terminal read` shape), fake transcripts with set
ages, a fixture ledger, no network. Covers churn and refresh by path, the 1x and 2x limits, per-lane
intervals, every refusal, the two-nudge episode cap, the 3-in-6 h cap, persistent churn and
`resume.lock`.
