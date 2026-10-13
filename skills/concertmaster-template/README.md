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
| `references/ledger.md` | ledger, roster and outbox schema |
| `references/intake.md` | chat intake procedure; wacli is one adapter |
| `references/resume.md` | restart recovery |
| `references/hooks-install.md` | optional telemetry hooks |
| `companions/dev-flow.md` | generic copy of the dev-flow skill the dev-sweeper runs |
| `scripts/` | bash + jq (+ yq) scripts, `lib.sh` holds the config loader |
| `scripts/test/` | hermetic tests, run against `scripts/test/fixtures/config.test.yaml` |

## Dependencies

Tools: `bash` (3.2+), `jq`, `yq` (mikefarah v4), `git`, `gh`, `curl`, the Orca
CLI (`orca` / `orca-ide`), `bd` (beads), Claude Code with `/loop` and
ScheduleWakeup. Optional: `wacli` (chat intake and digest), `codex`, `agy`.

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
   maps to a config key or to the handed item. Add project rules (database,
   secrets, copy) to the common footer.
5. **Test.** `for t in scripts/test/*.sh; do bash "$t" || echo "FAIL $t"; done`
   and `shellcheck -x scripts/*.sh scripts/hooks/*.sh scripts/test/*.sh`. Then a
   read-only dry run with the real config: `scripts/discover.sh --no-prs | scripts/classify.sh --table`.
6. **Boot.** In an Orca terminal on `cfg.hosts.home`, in the
   `cfg.worktrees.self_name` worktree, run `/concertmaster`. First boot shows
   the kill list once; after that it runs on `/loop`.
