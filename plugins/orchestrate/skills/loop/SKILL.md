---
name: loop
description: Arm the repeating tick engine for whichever harness is running, with a cadence, stop conditions and a STOP file. Use after a tick to keep a programme moving unattended, when a loop has stalled and needs re-arming, or to stop one. Claude Code arms its native loop; Codex, agy and anything else use the bundled tmux driver.
---

# loop

The tick is stateless, so the scheduler is interchangeable. Pick the one the
current harness has.

```
┌──────────────┐   ┌───────────────────────────────┐
│ Claude Code  │──▶│ native /loop + ScheduleWakeup │
└──────────────┘   └───────────────────────────────┘
┌──────────────┐   ┌───────────────────────────────┐
│ Codex, agy,  │──▶│ orchestrate.sh loop --tmux    │  STOP ends it
│ anything     │   └───────────────────────────────┘
└──────────────┘
```

## The loop holds the token

Arming a loop needs the ownership token from `orchestrate:takeover`, exported or
passed as `--session`. The driver hands it to every tick it spawns, and the
tmux form passes it into the session it creates. On Claude Code, keep it
exported in the session that arms `/loop`; the prompt below runs in that
session, so it inherits it.

## Claude Code

Arm `/loop` in dynamic mode with this prompt, re-entered each wake:

```
Run one orchestrate tick for <programme>, following the orchestrate:tick skill.
```

Do not also run the bundled driver. Two schedulers means double messages.

## Every other harness

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh loop <programme> --tmux \
  --every 20m --max-hours 8
```

| flag | effect |
|---|---|
| `--every <20m\|2h\|90s>` | cadence, defaults to `loop.every` in programme.yaml |
| `--max-ticks N` | stop after N ticks |
| `--max-hours N` | stop after N hours |
| `--tick-timeout S` | seconds one tick may take before it is stopped and the loop moves on. Defaults to twice the cadence. Without it a wedged tick hangs the loop and STOP never gets read |
| `--observe` | every tick classifies and reports, and sends, restarts and creates nothing. Use it to watch a programme without touching it |
| `--tmux` | run detached in a session named `orchestrate-<programme>` |
| `--agent-cmd "<cmd>"` | feed `assets/tick-prompt.md` to a headless agent each tick instead of running the mechanical tick alone |

The judgment half of a tick needs an agent, so a driver with no `--agent-cmd`
does the mechanical half only. To get a full tick unattended:

```bash
orchestrate.sh loop <programme> --tmux --every 20m \
  --agent-cmd 'codex exec -'          # or: agy --print
```

## Stopping

```bash
touch ~/.claude/orchestrator/<programme>/STOP
```

The loop ends at the next check and records why. STOP is read before each tick,
after each tick and during the wait between them, so it works even when a tick
has just been stopped for running long. A STOP already present makes
`loop` refuse to arm, so remove it before restarting. To stop the tmux driver
directly, kill that one session by its exact name:
`tmux kill-session -t orchestrate-<programme>`. Never a bulk or server-level
kill, never `pkill`.

## It also stops on its own

The per-tick bound stops the TICK, not necessarily everything the tick started:
an `--agent-cmd` that forks leaves its children running. Prefer a command that
exits cleanly, and check for strays after a run that timed out.

`max-ticks`, `max-hours`, and the `exit` expression in `programme.yaml` turning
true. Each records a `loop` event with its reason, so the next orchestrator can
see why it ended.
