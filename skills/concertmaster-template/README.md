# concertmaster-template

A project-agnostic copy of the **concertmaster** fleet-orchestrator skill, the
runbook generalised from a production project's agent fleet. One Claude session (the
concertmaster) owns every worktree, agent session and PR for one GitHub org
across every Orca host: it discovers and classifies sessions, spawns standing
lane leads and single-task workers, drives PRs through a strict merge gate,
ships in deploy windows, keeps hosts clean, and reports to one human owner. It
never writes code.

Everything that varied per project is now a key in `config.yaml`. The runbook
(`SKILL.md`), the lane briefs (`references/lanes.md`) and the scripts read
those keys; nothing in them names an org, repo, host, person or chat.

```text
┌──────────────┐ copy  ┌──────────────────────────────┐ fill  ┌─────────────┐
│ this template│──────▶│ <repo>/.agents/skills/       │──────▶│ config.yaml │
│              │       │   concertmaster/             │       │ (per proj)  │
└──────────────┘       └──────────────┬───────────────┘       └─────────────┘
                                      │ scripts/lib.sh reads config via yq
                                      ▼
                          discover, classify, teardown, resume, intake, ...
```

## Layout

| path | what |
|---|---|
| `SKILL.md` | the runbook: tick, state machine, lanes, merge gate, deploy windows, retire vs teardown, first boot, edge cases, messaging, reporting |
| `config.example.yaml` | every per-project key, commented; `[script]` marks keys the scripts read |
| `references/lanes.md` | brief templates with `{{placeholders}}` and a placeholder-to-config map |
| `references/overlay.md` | the project overlay contract: hook points, `references/project-local.md` format, overlay versus toolkit PR |
| `references/ledger.md` | ledger, roster and outbox schema |
| `references/intake.md` | chat intake procedure; wacli is one adapter |
| `references/resume.md` | restart recovery |
| `references/hooks-install.md` | optional telemetry hooks |
| `references/boot-sweep.md`, `references/runtime-check.md`, `references/systemd/` | re-arm lanes after a host restart or an Orca runtime restart; unit and timer files for the boot sweep, CI queue alert and credential check (`@USER@` and `@HOME@` tokens) |
| `references/ci-capacity.md` | CI queue alert and the shared-token budget |
| `references/credentials.md`, `references/credentials-index.seed.json` | credential index (names only) and the weekly validity check |
| `references/prompt-stalls.md` | the guarded-`rm` rule, the rm-guard hook and an optional allowlist |
| `references/away-timeout.md` | the away timeout (hard rule 16) and `scripts/ask-timeout.sh`: which asks may get an independent verdict |
| `references/queue.md` | the work queue: add, grant under caps, mark, audit (`scripts/queue.sh`, `scripts/queue-audit.sh`) |
| `companions/dev-flow.md` | generic copy of the dev-flow skill the dev-sweeper runs |
| `scripts/` | bash + jq (+ yq) scripts, `lib.sh` holds the config loader. Fleet jobs: `boot-sweep.sh`, `runtime-check.sh`, `ci-queue-alert.sh`, `cred-check.sh`, `hooks/rm-guard-hook.sh`. `sync-from-toolkit.sh` updates a project's copy |
| `scripts/test/` | hermetic tests, run against `scripts/test/fixtures/config.test.yaml` |

## Dependencies

Tools: `bash` (3.2+), `jq`, `yq` (mikefarah v4), `python3` (the `jsanitize` and `jstrings` Orca JSON helpers), `git`, `gh`, `curl`, the Orca
CLI (`orca` / `orca-ide`), `bd` (beads), Claude Code with `/loop` and
ScheduleWakeup. Optional: `wacli` (chat intake and digest), `codex`, `agy`, `bws` (credential check), `systemd` (boot sweep, CI queue alert and credential check timers), `shellcheck` (lint).

Skills the runbook calls. These live in the source project's repo
(`.agents/skills/<name>`) or in the global toolkit skills, NOT in this template:
copy them into the new project or replace them with equivalents.

| skill | used for | where it lives today |
|---|---|---|
| `pr-sweep` | pr-sweeper orchestration, `verbs/ship.md` (deploy), `adapters/orca.md`, `scripts/verdict-at-head.sh`, `scripts/verify-merge.sh` | source project repo `.agents/skills/pr-sweep` |
| `ready-to-ship` | drives one PR to merge-ready with evidence (the project CI evidence script) | source project repo |
| `dev-flow` | dev-sweeper's per-item flow | source project repo; generic copy in `companions/dev-flow.md` |
| `orca-cli` | every Orca call (worktree, terminal, host) | global skill |
| beads (`bd`) | epics, the beads gate | CLI + global `beads` skill |
| `gh` | PRs, issues, repo list | CLI |
| `/commit`, `/review`, `/research`, `/interview`, `/codex:rescue` | worker and lead steps | global skills / plugins |
| ops route skills (`cfg.ops.route`) | ops-sweeper routing | project-specific; null routes mean "investigate yourself" |

## Update a project (public engine, private config)

The engine lives here; each project keeps its own `config.yaml` (and any other
`config.*.yaml`) and its overlay, `references/project-local.md`, in its own repo.
Project rules go in the overlay, never in an engine file: a sync overwrites the
`SKILL.md` body, `scripts/`, `references/` and `companions/`, so an edit made there
in place is lost on the next update (`references/overlay.md`). To pull a newer
engine into a project's copy:

```bash
# from a toolkit checkout (or any copy of this tree):
scripts/sync-from-toolkit.sh --dry-run <repo>/.agents/skills/concertmaster   # what would change
scripts/sync-from-toolkit.sh           <repo>/.agents/skills/concertmaster   # do it
# or straight from GitHub, no checkout:
scripts/sync-from-toolkit.sh --fetch   <repo>/.agents/skills/concertmaster
```

It never writes `config.yaml`, keeps the project's `SKILL.md` frontmatter, leaves
project-only files alone (`--prune` removes engine files the toolkit dropped), and
prints the config keys that `config.example.yaml` now documents but the project's
`config.yaml` does not set. `references/project-local.md` is created as a stub
(one empty section per hook point) when missing and never written or pruned after
that. Update checklist:

1. `--dry-run` first; it lists `references/project-local.md` as `create` or `keep`.
2. Sync, then read the overlay report: hook points with no section yet (new places
   you can add to) and sections that match no hook point (no longer applied: move
   them to the right hook or delete them).
3. Add the reported config keys you need to `config.yaml`.
4. Re-copy the installed hook scripts on each host (`references/hooks-install.md`).
5. Run the tests (`scripts/test/*.sh`). A fix you need in the engine goes to the
   toolkit as a PR, not into the synced copy (`references/overlay.md` § Fixing
   the engine upstream).

Telemetry needs two required
config values, `telemetry.base_url` and `telemetry.tenant_id`: there is no default
for either, and nothing is sent until both are set. A project-bound sink token also
needs `telemetry.project_id` (a `p_<owner>` id), else the sink refuses every event.

## Adopt in a new project

1. **Copy.** `cp -r {{HOME_TOOL_DIR}}/skills/concertmaster-template <repo>/.agents/skills/concertmaster`;
   set the frontmatter `name:` to `concertmaster` and rewrite the
   `description:` triggers for the project.
2. **Configure.** `cp config.example.yaml config.yaml` and fill every key:
   org, main repo, exclude globs, owner, hosts and caps, timezone and deploy
   windows, deploy rails, merge command and gate scripts, lanes and models,
   beads epics, messaging recipients, outward-message policy, terminology,
   state dir. Decide whether `config.yaml` is committed (it holds no secrets)
   or kept in `$CM_HOME`.
3. **Bring the dependencies.** Copy or replace `pr-sweep`, `ready-to-ship`
   and `dev-flow` (start from `companions/dev-flow.md`), and point
   `cfg.merge.gates.*` and `cfg.deploy.ship_verb` at real scripts. A gate with
   no script means a weaker merge gate: write it down in `open_questions`.
4. **Fill the briefs.** Read `references/lanes.md`; every `{{placeholder}}`
   maps to a config key or to the handed item.
5. **Write the overlay.** From the toolkit checkout, run
   `scripts/sync-from-toolkit.sh <repo>/.agents/skills/concertmaster` once to
   create the `references/project-local.md` stub, then put project rules there, never in an engine file: database, secrets and
   copy rules under `## brief-footer`, per-lane addenda under `## lane: <label>`,
   extra tick steps under `## tick-extra`. `references/overlay.md` lists every hook
   point and what must be a toolkit PR instead. Commit the overlay with the project.
6. **Test.** `scripts/config-check.sh` (the config doctor), then `for t in scripts/test/*.sh; do bash "$t" || echo "FAIL $t"; done`
   and `shellcheck -x scripts/*.sh scripts/hooks/*.sh scripts/test/*.sh`. Then a
   read-only dry run with the real config: `scripts/discover.sh --no-prs | scripts/classify.sh --table`.
7. **Boot.** In an Orca terminal on `cfg.hosts.home`, in the
   `cfg.worktrees.self_name` worktree, run `/concertmaster`. First boot shows
   the kill list once; after that it runs on `/loop`.
