# Spec: godmode as a Claude Code plugin

**Generated from:** .agents/specs/2026-07-16-godmode-plugin-stub.md
**Date:** 2026-07-16
**Format:** diagram-first, table-second, no prose paragraphs

## Problem

| Question | Answer |
|----------|--------|
| What?    | Repackage /godmode as an installable plugin (Claude + Codex + Copilot) with hook-enforced status publishing and beads-clubbed cross-machine run sync |
| Why?     | Dashboard/explainer updates are model-driven and skippable today; run state is machine-local so a programme cannot be observed or resumed from a second machine |
| Who?     | Stevie driving multi-epic godmode programmes across machines and providers |

## Users + use cases

| Persona | Goal | Primary use case |
|---------|------|------------------|
| Driver (machine A, Claude) | Run the factory unattended with status never going stale | /godmode run; hooks publish dashboard + push sidecar every tick |
| Observer/resumer (machine B) | See live status; take over after crash or by choice | /godmode status (pull + report); /godmode run auto-claims stale lease or --take-over |
| Non-Claude session (Codex/Copilot) | Same status + sync visibility without the loop | /godmode status, dashboard publish, sidecar sync, lease guard via provider hooks |
| Toolkit maintainer | Update godmode, get changes to all machines | Edit own marketplace clone, /sync-learnings v2 git push, claude plugin update elsewhere |

## Approach

| Option | Summary | Tradeoff | Picked? |
|--------|---------|----------|---------|
| A | Hook sidecar, cross-provider: hooks do publish/sync deterministically, block model skips; shipped inside each provider's plugin package | vs B: real enforcement; vs C: no new daemon lifecycle | ✓ |
| B | Thin plugin wrapper, prompt-enforced status | Cheapest; status stays skippable (the original complaint) | |
| C | Watchdog daemon owns publish + sync | Works with no session alive; new lifecycle, invisible-daemon smell | |

**Why A:** the harness executes hooks, so status and sync stop depending on model discipline, with no daemon to babysit.

**Strategic frame decided alongside:** ainb-toolkit becomes a plugin marketplace via strangler pattern; godmode is the first migrant; eventual carve-up is few fat family plugins (engineering, orchestration, session-ops, media, crypto, publishing); execution of those migrations is out of scope here.

## Architecture

```
ainb-toolkit repo (= marketplace root)
├─ .claude-plugin/marketplace.json          ← NEW
├─ plugins/godmode/                         ← NEW (hard move from skills/)
│   ├─ .claude-plugin/plugin.json
│   ├─ .codex-plugin/plugin.json            ← ponytail pattern
│   ├─ commands/godmode.md
│   ├─ skills/godmode/  (SKILL.md + references + assets)
│   ├─ hooks/hooks.json  hooks/copilot-hooks.json
│   └─ scripts/ publish.sh  sync.sh  lease.sh  beads_remote.sh
├─ skills/ agents/ bootstrap.js             ← legacy, untouched (strangler)

runtime (driver session, machine A):
 state.json write ──▶ PostToolUse hook ──▶ publish.sh (dash from state+beads)
                                      └──▶ sync.sh push sidecar + heartbeat
 turn end ─────────▶ Stop hook: phase flipped without explainer? BLOCK
 session start ────▶ SessionStart hook: git fetch + sidecar pull + lease check
 pre-compact ──────▶ PreCompact hook: sidecar push (cheap insurance)

sync-back (maintainer):
 ~/.claude/plugins/marketplaces/ainb-toolkit/  = own git clone
 edit live ──▶ /sync-learnings v2: git add/commit/push ──▶ origin main
 machine B: claude plugin update  (pull)
```

| Component | Purpose | Owns |
|-----------|---------|------|
| marketplace.json | Makes ainb-toolkit installable as marketplace | plugin registry |
| plugin.json (+ .codex-plugin, copilot-hooks.json) | Per-provider install manifests | hook wiring, versioning |
| commands/godmode.md | /godmode entry (init, run, status, pause) | arg parsing, mode dispatch |
| skills/godmode | The existing constitution + references (hard-moved) | loop protocol, stage playbooks |
| publish.sh | Render dashboard from state.json + beads, push to here.now | deterministic status surface |
| sync.sh | Sidecar pull/push via git plumbing, heartbeat refresh | cross-machine state |
| lease.sh | Claim, refresh, staleness check, take-over | single-driver guarantee |
| Stop hook script | Explainer gate: block turn when phase flipped without /explain-to-me update | enforcement |
| /sync-learnings v2 | Detect own-marketplace paths, git flow instead of copy-diff | maintainer sync-back |

## Data model

```
origin/main
├─ .beads/issues.jsonl                      ← beads, as today
└─ .beads/godmode/<slug>/                   ← NEW committed sidecar
    ├─ state.json     durable mirror
    ├─ charter.md     constitution copy
    └─ lease.json     driver lease

┌─ root bead (programme) ─┐ 1:N  ┌─ epic beads ─┐ 1:N ┌─ feature beads ─┐
│ <slug>                  │─────▶│ <slug>-eNN   │────▶│ <slug>-eNN-fMM  │
└──────────────────────────┘      └──────────────┘     └─────────────────┘
        │ keyed by slug
        ▼
.beads/godmode/<slug>/  (sidecar)      .agents/scratch/<slug>-state.json
  durable subset, synced         ◀──── full local state incl. machine-local
                                        fields (running_task, run_id)
```

| Entity | Fields (key only) | Relationships |
|--------|-------------------|---------------|
| sidecar state.json | phase, current_epic, branch, epics{}, human_gate, termination{}, dashboard_slug | keyed by slug; subset of local scratch state |
| lease.json | machine, session_id, heartbeat_ts, held_since | 1:1 per programme slug |
| charter.md (sidecar) | full charter copy | 1:1 per slug; enables machine B drive |
| local scratch state.json | sidecar fields + running_task, running_run_id, stop_counters | machine-local superset, never synced fields stay local |
| beads issues.jsonl | epic/feature beads, close-with-evidence notes | as today; transport shared with sidecar |

## Interface

Commands:

```
/godmode <north-star> [--no-court] [--budget N] [--deadline ISO] [--fable off]
/godmode run [--take-over]        # claims/refuses per lease; drives loop
/godmode status                   # any machine, any provider: pull + report
/godmode pause                    # stop re-arming, state stays resumable
```

Machine B status sample:

```
$ /godmode status
programme: swift-epoch     phase: E02_EXECUTE
lease: held by mac-studio (session 7418d) heartbeat 4m ago  ← you are read-only
epics: e00 SHIPPED_PR2903 · e01 SHIPPED_PR2904 · e02 EXECUTING
dashboard: https://swift-epoch-fvds.here.now (fresh 4m ago)
```

hooks.json (Claude shape; Codex/Copilot equivalents mirror it):

```json
{ "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command",
      "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh\" pull" }]}],
    "PostToolUse": [{ "matcher": "Write|Edit",
      "hooks": [{ "type": "command",
      "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/on-state-write.sh\"" }]}],
    "Stop": [{ "hooks": [{ "type": "command",
      "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/explainer-gate.sh\"" }]}],
    "PreCompact": [{ "hooks": [{ "type": "command",
      "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh\" push" }]}]
}}
```

| Surface | Trigger | Shape |
|---------|---------|-------|
| /godmode command | user | markdown command, dispatches to skill |
| dashboard | every state.json write (hook) | here.now HTML rendered by publish.sh |
| /explain-to-me explainer | phase transition (model, Stop-hook enforced) | rich HTML on here.now |
| sidecar | hook push/pull | files under .beads/godmode/<slug>/ on origin/main |
| provider parity | install per provider | Claude full loop; Codex/Copilot: status, publish, sync, lease guard; run refuses with message |

## Behavior

Happy path (ASCII flow):

```
[tick wake] ──read charter+state──▶ [stage work] ──state.json write──▶
[PostToolUse: publish.sh + sync.sh push (heartbeat)] ──▶
[phase flip?] ──yes──▶ [model runs /explain-to-me update] ──▶
[Stop hook: explainer stamp present ⇒ allow] ──▶ [re-arm ScheduleWakeup]
        └─no───────────────────────────────────▶ (gate passes trivially)

machine B:
[SessionStart: sync.sh pull] ──▶ [/godmode status] ──▶ [report, read-only]
[/godmode run] ──lease fresh──▶ [refused, show holder]
               ──lease stale──▶ [auto-claim, drive]
               ──take-over────▶ [AskUserQuestion confirm] ──▶ [claim, drive]
```

Edge cases:

| Scenario | Trigger | Expected behavior |
|----------|---------|-------------------|
| Phase flipped, explainer skipped | Stop hook finds no explainer stamp for new phase | Turn blocked with reason "run /explain-to-me update for <phase>"; model complies, stamp written, stop allowed |
| Lease stale (holder crashed) | heartbeat_ts older than TTL (default 30 min, ~3 missed ticks) | Machine B /godmode run auto-claims, notes takeover in sidecar + dashboard banner |
| Take-over while fresh | --take-over flag | AskUserQuestion confirm, then lease rewritten; old holder's next hook sees lost lease, downgrades to read-only and stops re-arming |
| Concurrent claim race | two machines push lease simultaneously | git push ordering decides; rejected pusher refetches, sees other holder, backs off |
| bd silent-persist failure | bd round-trip check fails | beads_mode jsonl-plumbing, as today; sidecar unaffected (own files, same plumbing) |
| Compaction mid-run | PreCompact hook | sidecar pushed before compaction, resume-safe |

## Errors

| Failure mode | User-visible surface | Recovery |
|--------------|----------------------|----------|
| here.now unreachable | staleness banner on last-good dashboard; pending-publish marker | retry next tick; never blocks factory |
| git push rejected (branch moved) | hook log line | refetch + replay (beads_remote.sh contract); never force |
| bd broken | state.json beads_mode flag | jsonl plumbing path, as today |
| Sidecar pull fails on SessionStart | warning in session context | proceed with local state; status marks "sync unverified" |
| Stop-hook script crashes | hook error surfaced by harness | fail OPEN for infra errors (never wedge the turn); only healthy-machinery skip blocks |
| Lost lease mid-turn | hook warning | current machine finishes turn, does not re-arm, posts handoff note |

## Testing strategy

| Layer | Scope | Coverage gate |
|-------|-------|---------------|
| Unit (bats) | publish.sh render, sync.sh push/pull round-trip vs throwaway git remote, lease.sh claim/refresh/stale/steal, explainer-gate stale predicate | all pass, incl. push-reject replay and 0-empty-line JSONL validation |
| Integration | hooks.json wiring: simulated PostToolUse/Stop/SessionStart events invoke scripts with plugin root env | all pass |
| E2E (sandbox) | claude plugin install from local marketplace into sandbox HOME; scripted tick + phase flip; assert dashboard rendered, sidecar on remote, Stop hook blocks without explainer stamp and allows with it | must pass before merge |

## Out of scope

- Dual-driver merge (two machines driving different epics concurrently)
- Family carve-up migrations (engineering/media/crypto plugins): direction set, execution later
- ainb TUI integration (lease/run visibility in Daemons or sessions screens)
- Degraded non-Claude drive loop (Codex/Copilot stay status + sync parity; run refuses)
- Dashboard visual redesign (existing programme-dashboard.html carries over)

## Amendments (post-critique, 2026-07-16)

Adversarial review (29-agent workflow, 20 confirmed findings) hardened the design; verdict CAUTION with conditions, all folded into `plans/godmode-plugin.md`:

- [A1] Sync transport: sidecar moves from origin/main to dedicated ref `refs/godmode/<slug>`, ONE commit per sync. Why: protected-main lease split-brain, per-tick heartbeat commits polluting main, CI-on-main triggers. Beads stay on main as today. No epic-branch fallback for the sidecar, ever (lease must live where pulls read); unpushable ref = fail closed, sync disabled visibly.
- [A2] Lease identity: machine + user + SESSION token, full-identity compare. Two sessions on one host contend like two machines.
- [A3] Observer model: `/godmode status` never reconstructs local run state (reads sync cache); only `/godmode run` (claim or confirmed --take-over) adopts. SessionStart hook stays local-inert; fresh-machine discovery via `git ls-remote 'refs/godmode/*'` in the command layer. Supersedes the architecture diagram arrow "SessionStart pulls other machine's run state".
- [A4] state.json additions: `driver_session_id`, `phase_since`, `current_note`. state.json writes are Write/Edit-tool-only (hooks key on PostToolUse); Stop-hook heartbeat backstop covers quiet ticks and Bash slips. Every mutating push is lease-holder-gated; lost lease surfaces to the model (exit 2), never a silent marker.
- [A5] Single-machine runs: `GODMODE_SYNC=local` disables remote sync entirely; the one-system case pays zero push cost and loses nothing except cross-machine resume.

## Open questions for /plan

- [ ] Explainer stamp mechanism: exact location + shape (e.g. .agents/scratch/<slug>-explainer.<phase>.stamp) and how the Stop hook detects "phase flipped this session"
- [ ] Heartbeat TTL: confirm 30 min default and its coupling to ScheduleWakeup ~600 s cadence (3 missed ticks)
- [ ] Codex/Copilot hook event mapping: which of their lifecycle events approximate PostToolUse/Stop; what falls back to the installer script
- [ ] /sync-learnings v2: detection rule for own-marketplace clones and commit-message convention for learning pushes
- [ ] Charter mid-run edits: does machine B editing sidecar charter.md propagate, and does the "never commit charters" non-negotiable get amended in SKILL.md for the sidecar copy only
- [ ] marketplace.json versioning discipline: version bump policy per plugin change (semver? date?)
