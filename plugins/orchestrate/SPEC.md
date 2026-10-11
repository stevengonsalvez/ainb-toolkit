# Specification: `lane-orchestrator` skill

**Generated from:** a structured interview of the plugin's owner after running a ten-lane, three-host programme by hand
**Interview date:** 2026-09-20 (five rounds)
**Version:** 1.1 (adds handover and namespacing, the owner's note after round five)
**Build with:** `/skill-creator`. **Depends on:** `/orca-cli`, `/loop` (Claude Code only).

## Status of this spec against the shipped plugin

| item | state (plugin 0.1.1) |
|---|---|
| cut 1 (build order, row 1) | shipped |
| cut 2 (preflight ladder, placement, spawn, reviewer lanes, retirement at exit) | not started; `preflight` and `spawn` are placeholders |
| acceptance: replay | passed against ten live lanes on three hosts, read-only |
| acceptance: cold tick | passed on Codex, headless, from the programme directory alone |
| acceptance: handover | passed in tests; not yet run across two real providers |
| acceptance: kill and recover | deferred on RESTART IDENTITY (see Open questions) |
| credit guard, rendered review nudge | read by the agent, not enforced by code |

## Outcome

One command puts a session in charge of N agent lanes on any mix of Orca hosts, with a durable record of
what runs where, one recorded path for every message, and a loop that nudges, gates merges and restarts
lanes until the programme's exit condition holds. Any harness can run a tick from the files alone.

## Shape

```
┌──────────┐  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌──────────┐
│ discover │─▶│ adopt /  │─▶│ tick      │─▶│ act       │─▶│ re-arm   │
│ orca envs│  │ spawn    │  │ stateless │  │ per policy│  │ or stop  │
└──────────┘  └────┬─────┘  └─────┬─────┘  └─────┬─────┘  └────┬─────┘
                   ▼              ▼              ▼             ▼
              lanes.jsonl    hosts.jsonl    events.jsonl   owner.json
                   ▲                                           │
                   └──── stale handle / dead lane: re-resolve ◀┘
```

```
loop engine                         tick = f(programme dir) -> events, exit code
┌─────────────┐   ┌──────────────────────────────┐
│ Claude Code │──▶│ native /loop + ScheduleWakeup│
└─────────────┘   └──────────────────────────────┘
┌─────────────┐   ┌──────────────────────────────┐
│ Codex, agy  │──▶│ tmux driver, headless tick   │   STOP file ends it
└─────────────┘   └──────────────────────────────┘
┌─────────────┐   ┌──────────────────────────────┐
│ any         │──▶│ tick --once                  │
└─────────────┘   └──────────────────────────────┘
```

## Decisions

| # | topic | decision | alternatives rejected | why |
|---|---|---|---|---|
| D1 | lane origin | adopt AND spawn | adopt only | a lane started by hand and never registered is how lane P got lost |
| D2 | rule split | generic skill, per-programme `programme.yaml` plus free-text `ORCHESTRATION.md` | rules baked in; rules only in memory | second programme must not need a skill edit; toolkit copy must hold nothing personal |
| D3 | autonomy | configurable, default merge on passing verdict | always merge; always ask | unattended loop needs it; outward acts always ask regardless |
| D4 | index | `~/.claude/orchestrator/<programme>/`, jsonl | in-repo gitignored; sqlite | survives worktree removal, greppable, ten lanes do not need a schema |
| D5 | transport | Orca only. NO ssh, anywhere | read-only ssh; full ssh fallback | one write path per lane; an unreachable host is reported and skipped |
| D6 | host metrics | ladder: Beszel hub API, then Orca probe terminal, then live session count | Beszel only; skip Beszel | one call for all hosts plus history; degrades without blinding placement |
| D7 | placement | hard refusals, then score, then place or propose | always ask; fewest lanes | a 45G build must not land on a 12G box; 3am restarts must not block |
| D8 | loop engine | Claude: native `/loop`. Codex and agy: external tmux driver only | in-session sleep loop; single tick only | tick is stateless, so the scheduler is interchangeable |
| D9 | loop options | mode (once, fixed, self-paced), stop conditions, missed-tick watchdog | quiet hours and host guards (not chosen) | covers tonight's silent 90 minute gap |
| D10 | agents | Claude, Codex, agy, Gemini all first-class, as lanes and as orchestrator host | Claude only; Claude full and others basic | lane Q hit 92 percent of its week; orchestration must outlive one vendor's quota |
| D11 | review | per project: `review` block, mode per PR class (`orchestrator`, `lane`, `ci`, `none`), verdict rule, nudge text | fixed review sets in the skill; free text only | some projects review in CI, some in the lane, some here; the orchestrator nudges to match |
| D12 | review engine | when mode is `orchestrator`: native subagents where present, else a short-lived reviewer lane; small deltas read directly | always reviewer lanes; orchestrator reads everything | parallel subagents finished in minutes; an independent reader caught the data-loss bug |
| D13 | ownership | single owner lock `owner.json`, takeover when stale (2x cadence) or `--takeover` | no lock; shared index on the tailnet | two orchestrators would double-merge and double-message |
| D14 | name and home | `lane-orchestrator`, authored in ainb-toolkit, synced to every agent | user skills only; fold into `/orca-cli` | all agents must see it; `/orca-cli` is a version-matched stub |
| D15 | force-push | refused unless the owner explicitly asks in that session | never; config flag | his words: only if the user explicitly asks |
| D16 | handover | first-class and cheap: `handover` writes a generated brief and releases the lock; `takeover` on ANY agent kind resumes from files | handover as a prose note written by hand | credits run out mid-programme (lane Q hit 92 percent); the next orchestrator may be a different vendor |
| D17 | namespacing | shipped as a namespaced set, `orchestrate:<verb>`, one verb per entry point, identical names on every harness | one monolithic skill | any agent type can run any verb; a fresh agent needs only `orchestrate:takeover <programme>` |

## Never do (hard refusals, config cannot lift them)

| refusal | note |
|---|---|
| bulk or server-level kills | no `tmux kill-server`, `pkill`, `killall`; exact session name or exact PID only |
| delete or clean under a live lane | ask the owning lane to clean; retire a worktree only when merged, clean and idle |
| merge outside declared trunk, unsigned or attributed commits | `trunk` and `never_merge_into` are walls; no `--no-gpg-sign`; attribution guard on merges and on every PR post |
| force-push | only on the owner's explicit ask, recorded as an event with his words |
| outward or irreversible acts without asking | new repository, publishing, deleting remote branches, bulk issue closes, new hosts: structured question first, even under full autonomy |
| any ssh | D5 |

## Handover (any agent kind can take over)

```
owner low on credits / asked to stop / session ending
        │
        ▼
┌────────────────────┐   ┌──────────────────────┐   ┌─────────────────────┐
│ orchestrate:       │──▶│ HANDOVER.md generated│──▶│ owner.json released │
│ handover           │   │ from the index       │   │ event: handover     │
└────────────────────┘   └──────────────────────┘   └──────────┬──────────┘
                                                               ▼
┌────────────────────┐   ┌──────────────────────┐   ┌─────────────────────┐
│ any agent, any box │──▶│ orchestrate:takeover │──▶│ verify handles, run │
│ Claude, Codex, agy │   │ <programme>          │   │ one tick, arm loop  │
└────────────────────┘   └──────────────────────┘   └─────────────────────┘
```

| rule | detail |
|---|---|
| nothing lives only in a conversation | a tick already runs from files alone, so handover adds a brief, not state |
| `HANDOVER.md` is generated, not authored | lanes and states, open PRs with review status, in-flight reviewers and where their reports land, open decisions and steers with who was told, owed notices, host pressure, the single next action |
| credit guard | each tick reads the orchestrator's own usage where the harness shows it; over the threshold in `programme.yaml` it runs `handover` by itself and notifies the owner with the takeover command |
| takeover is one line | `orchestrate:takeover <programme>` on any harness; it claims the lock, re-verifies every handle before any send, runs one tick, then arms that harness's loop engine |
| cross-host takeover | the programme dir is host-local (D4): takeover on another box needs the dir copied or the same box used; recorded as an open question below |
| takeover is recorded | `takeover` event names outgoing and incoming session, harness and reason |

## Namespace

| verb | entry point |
|---|---|
| `orchestrate:discover` | list Orca environments, hosts, worktrees, terminals |
| `orchestrate:adopt` | index existing lanes, confirm once |
| `orchestrate:preflight` | host metrics ladder and ranking |
| `orchestrate:spawn` | place and start a lane with a goal |
| `orchestrate:tick` | one stateless tick |
| `orchestrate:loop` | arm the engine for this harness |
| `orchestrate:status` | table of lanes, PRs, owed, hosts, from files only |
| `orchestrate:handover` | generate the brief, release the lock |
| `orchestrate:takeover` | claim, verify, tick, arm |
| `orchestrate:retire` | retire merged, clean, idle lanes |

Packaging: a plugin named `orchestrate` on Claude Code (skills surface as `orchestrate:<verb>`); the toolkit
sync emits the same verb names as prompts or commands for Codex, agy and Copilot. Shared scripts live once,
under the plugin, and every verb calls them; no verb carries its own copy of the logic.

## Files

```
~/.claude/orchestrator/<programme>/
  programme.yaml      policy (D2, D3, D7, D9, D11)
  ORCHESTRATION.md    free text: house rules, how to nudge, who decides what
  agents.yaml         per agent kind: start, resume, idle, busy, ctx, compact, headless
  lanes.jsonl         one row per lane, rewritten on change
  hosts.jsonl         last metrics per host, and which ladder rung answered
  events.jsonl        append-only: pr, notified, tick, decision, spawn, restart, refuse, takeover
  owner.json          session, host, harness, last tick
  reviews/<pr>-<kind>.md
  HANDOVER.md         generated brief for the next orchestrator
  STOP                presence ends the tmux driver
```

| record | fields |
|---|---|
| lane | `lane, env, handle, worktree, branch, agent, goal, exclusive[], status, ctx_pct, last_seen` |
| host | `host, env, src(beszel/probe/count), disk_free_gb, mem_free_gb, cores, load1, lanes, t` |
| event `pr` | `t, pr, lane` (recorded on first sight of the PR) |
| event `notified` | `t, lane, pr or -, result(delivered/unconfirmed/dead-shell), msg` |
| event `tick` | `t, n, lanes{working,idle,asking,done,dead}, open_prs, owed, gap_s` |
| event `decision` | `t, topic, told[], text, source` (so a later tick sees what was told to whom) |

```yaml
# programme.yaml (shape)
trunk: v2
never_merge_into: [main]
autonomy: merge_on_verdict        # or ask
signing: {required: true, key: "<id>"}
attribution_guard: true
ci: ignore                        # or gate
loop: {mode: self_paced, every: 20m, max_ticks: 0, max_hours: 0}
handover: {credit_threshold_pct: 85, notify: true}
exit: "open_prs == 0 && scope_done"
metrics: {beszel_hub: "http://<tailnet-host>:8090", token_ref: "bitwarden:<item>"}
placement:
  floors: {disk_free_gb: 20, mem_free_gb: 4}
  weights: {disk: 40, ram: 30, load: 20, lanes: 10}
  max_lanes_per_host: 6
  exclusive: [wdio, proof]
review:
  default: {mode: orchestrator, kinds: [code], verdict: "line1 in {MERGE, MERGE WITH FOLLOW-UPS}"}
  classes:
    - {match: {paths: ["**/proto/**", "**/migrations/**"]}, mode: orchestrator, kinds: [code, security]}
    - {match: {label: docs}, mode: none}
  nudge: {stale_pr: "PR #{pr} has no review after {age}. Run {how}."}
```

## Commands

| command | does |
|---|---|
| `discover` | `orca status` per environment, reachable or not, worktrees, terminals; reads each handle, never trusts `list` alone |
| `adopt` | proposes `lanes.jsonl` rows from discovery, detects agent kind from the screen, the owner confirms once |
| `preflight` | metrics ladder per host, writes `hosts.jsonl`, prints ranking with refusals |
| `spawn --host auto --worktree W --agent K --goal G --needs ...` | placement, `orca worktree create`, `orca terminal create --command <start>`, goal sent through the send path, row appended |
| `send <lane> <pr or -> <text>` | dead-shell guard, send through Orca, confirm on screen, record result |
| `owed` | merged or closed PRs whose lane has no delivered notice |
| `tick [--once]` | the unit of work, below |
| `loop [--every N] [--max-ticks N] [--max-hours N]` | engine per D8 |
| `retire <lane>` | only when merged, clean, idle; through Orca |
| `handover` | generate `HANDOVER.md` from the index, release `owner.json`, record |
| `takeover` | claim a released or stale `owner.json`, re-verify handles, one tick, arm the loop, record |

## Tick (stateless, in order)

1. Owner check; watchdog: gap since last `tick` event over 2x cadence is reported first.
2. Read every indexed lane; classify `working, idle, asking, done, dead`; record `ctx_pct`.
3. Dead or stale handle: re-resolve by worktree, restart with the agent's `resume`, rewrite the row, event.
4. Context over threshold and idle: send the agent's `compact` with a keep list.
5. Host metrics (ladder); over floor: ask the owning lane to clean; never delete under it.
6. Open PRs: record ownership on first sight; apply the `review` policy for the PR's class;
   nudge per mode (`lane`: ask for its report; `ci`: wait on head-sha checks; `orchestrator`: run D12).
7. Passing verdict and `autonomy: merge_on_verdict`: merge gate (head sha, merge-tree, signatures,
   attribution), merge into `trunk`, notify the owning lane.
8. Failing verdict: post the scrubbed report, send findings to the lane, record the decision.
9. Lane `asking`: answer from `ORCHESTRATION.md` and the goal; structured question to the owner only
   when it is his to decide.
10. `owed` to empty. Append `tick`. Evaluate `exit`; on true: notify, stop, offer retirement.

## Edge cases

| scenario | behaviour |
|---|---|
| remote `terminal list` empty while lanes live | ignore list; read each indexed handle |
| send returns not-ok or screen shows a shell prompt | `dead-shell`; restart via `resume`; resend once; record both |
| host restarted, orchestrator resumed | watchdog reports the gap; every handle re-verified before any send |
| Beszel hub down or host not enrolled | next ladder rung; `hosts.jsonl.src` says which |
| all hosts refused at spawn | no spawn; structured question with the ranking |
| two suites on one host | `exclusive` resource held in the index; second request waits or goes elsewhere |
| lane quotes gates that do not cover what it names | verdict rule needs sha and command in evidence; lane claims are not verdicts unless mode is `lane` |
| wrong steer sent to a lane | correction is a new `decision` event naming the one it replaces |
| report contains host paths or vendor words | scrubber strips paths, refuses on any remaining hit, nothing is posted |
| second orchestrator starts | refuses unless owner stale or `--takeover` |
| zsh caller | every script is bash with explicit argument reads |

## Build order

| cut | contents |
|---|---|
| 1 | namespaced verbs, handover and takeover, discover, adopt, index files, send path, `owed`, tick (classify, restart, compact, disk via Orca probe, nudge, merge gate from review policy, scrubber), `/loop` and tmux driver, `owner.json`, watchdog, never-do list |
| 2 | preflight ladder with Beszel, placement score and refusals, spawn, restart on a healthier host, reviewer lanes on non-Claude harnesses, retirement at exit |
| 3 | status page, programme doc rows, cost ceilings |

Seed to lift from: `the hand-written `lane.sh` of the first programme`, and the session's `merge-sweep.sh`
and `post-review.sh`.

## Acceptance (must pass before unattended use)

- [ ] Replay: `adopt` against the first programme's live lanes finds all ten, flags a lane waiting on a
      verdict for a merged PR, and reports zero owed after one tick.
- [ ] Kill and recover: close a lane's terminal mid-task; next tick marks it dead, restarts it with the
      right resume command, fixes the handle, records the event.
- [ ] Handover: a Claude orchestrator runs `orchestrate:handover`; a Codex or agy session runs
      `orchestrate:takeover` and continues with no question to the owner and no lost or duplicated notice.
- [ ] Cold tick: one headless tick from an empty context on Codex or agy, using only the programme dir,
      yields the same classification as the Claude session.

Not chosen as a gate, still to be checked in tests: every hard refusal is refused and logged.

## Risks

| risk | impact | likelihood | mitigation |
|---|---|---|---|
| screen-scraping agent prompts breaks on a UI change | high | med | patterns in `agents.yaml`, not code; `discover` reports unmatched screens |
| auto-merge default surprises another toolkit user | high | low | `autonomy` must be set explicitly at `adopt`; no implicit default write |
| headless tick lacks judgment context | med | med | decisions and steers are events; `ORCHESTRATION.md` read every tick |
| Beszel to Orca host-name mismatch | low | med | explicit map in `programme.yaml`, verified at `preflight` |
| crashed owner blocks for 2x cadence | low | med | `--takeover`, recorded |
| placement floors wrong for a host | med | med | floors per host; cut 1 collects real numbers before cut 2 uses them |

## Deferred

- Quiet hours and per-host guards as loop options (offered, not chosen).
- Shared index across hosts.
- sqlite, if lanes pass a few dozen.

## Open questions

- [ ] Beszel hub URL on the tailnet and the Bitwarden item holding a read-only token.
- [ ] Headless invocation for agy (exact command and flags) and Gemini's resume form, to fill `agents.yaml`.
- [ ] RESTART IDENTITY (found 2026-09-20 while planning the kill-and-recover run, blocks that acceptance check):
      a Claude lane is restarted with `claude --continue`, which resumes the most recent conversation in that
      directory. A worktree with several agents (three terminals in `pr-sweep`, two in lane P's worktree) can
      resume the WRONG conversation, and a throwaway lane in the orchestrator's own worktree could resume the
      orchestrator. Record each lane's agent session id at adopt and spawn (`agent_session` on the lane row),
      restart with an explicit resume of that id, and refuse to restart a lane whose id is unknown when its
      worktree holds more than one agent. Same question per agent kind for Codex, agy and Gemini.
- [ ] Cross-host takeover: copy the programme dir on handover, or keep orchestration on one box.
- [ ] Credit threshold per harness, and where each harness exposes its own usage.
- [ ] Toolkit path for the skill and whether `/sync-learnings` needs a mapping entry for it.

---

*Generated through systematic interview of the plan author.*
