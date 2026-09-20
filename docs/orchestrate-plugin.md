# orchestrate plugin

One session takes charge of N agent lanes on any mix of Orca hosts: a durable record of what runs
where, one recorded path for every message, a stateless tick, a merge gate that refuses, and a
handover any agent kind can pick up. Version 0.1.0 is cut 1.

```
discover ─▶ adopt ─▶ takeover ─▶ tick (observe first) ─▶ loop ─▶ handover
                        │
                        └─ prints the ownership token once
```

## Install

| Provider | Command |
|---|---|
| Claude Code | `claude plugin marketplace add stevengonsalvez/ainb-toolkit && claude plugin install orchestrate@ainb-toolkit` |
| Codex | `codex plugin marketplace add stevengonsalvez/ainb-toolkit && codex plugin add orchestrate@ainb-toolkit` |
| Copilot CLI | `copilot plugin marketplace add stevengonsalvez/ainb-toolkit && copilot plugin install orchestrate@ainb-toolkit` |

Already added the marketplace for godmode? Refresh it instead of adding it again:
`claude plugin marketplace update ainb-toolkit`, `codex plugin marketplace upgrade ainb-toolkit`.

Skills appear namespaced, the same names on every provider:
`orchestrate:discover`, `adopt`, `takeover`, `tick`, `loop`, `status`, `handover`, `retire`,
and the two cut 2 placeholders `preflight` and `spawn`.

## Prerequisites (per machine)

- `bash`, `jq`, `git`, `gh` (authenticated), and the Orca CLI (`orca`, or `orca-ide` on Linux).
- `sha256sum` or `shasum`, and `/dev/urandom`: the ownership token refuses to degrade without them.
- Transport is Orca only. There is no ssh path.

## First run

```bash
O="<plugin dir>/scripts/orchestrate.sh"
$O init <programme> --trunk <branch> --never-merge-into main --repo <checkout>
# edit ~/.claude/orchestrator/<programme>/programme.yaml: autonomy and repo are set deliberately
$O takeover <programme>          # prints: export ORCHESTRATE_SESSION=<token>, shown once
export ORCHESTRATE_SESSION=<token>
$O adopt <programme> --dry-run   # writes nothing; shows indexed and unindexed lanes
$O adopt <programme>
$O tick <programme> --once --observe
$O loop <programme>              # Claude Code: use the native /loop with the tick skill instead
```

| Rule | Why |
|---|---|
| Keep the token | Every verb that writes needs it, in the environment or as `--session`. Only its hash is stored. Lost token: `takeover` again, which is recorded. |
| Observe first | The first tick after a takeover observes by itself. A misclassified lane would otherwise get a resume command typed into it. |
| `autonomy` has no default | Missing means ask. Merging on a verdict is a choice made per programme. |
| Review is per programme | `review` block: `orchestrator`, `lane`, `ci` or `none` per PR class, plus the free text in `ORCHESTRATION.md`. |
| Handover is one verb | `handover` writes `HANDOVER.md` from the index and spends the token; any provider runs `takeover` to continue. |

## Loop engine per provider

| Provider | Engine |
|---|---|
| Claude Code | native `/loop`, each firing runs the tick skill |
| Codex, others | `orchestrate.sh loop --tmux`, a driver that runs one headless tick per cadence; a `STOP` file in the programme directory ends it |
| Any | `tick --once` |

## Known limits in 0.1.0

- `preflight` and `spawn` are placeholders: host scoring, placement and spawning are cut 2.
- The credit guard and the rendered review nudge are read by the agent, not enforced by code.
- Screen patterns for Codex, agy and Gemini lanes in `agents.yaml` are marked UNVERIFIED.
- A dead Claude lane is restarted with a continue-latest command. In a worktree that holds more
  than one agent that can resume the wrong conversation. Until lanes carry an agent session id,
  keep ticks in observe mode for such worktrees and restart those lanes by hand.
- The programme directory is local to one machine. Taking over from another machine needs the
  directory copied first.
