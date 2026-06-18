# ainb-toolkit — Portable AI-Agent Skills & Configs

One canonical source. Many AI tools. Write a skill once, install it into
Claude Code, Codex, Copilot, Gemini, Hermes, nanoclaw, Amazon Q, Cursor,
Cline, Roo, or Clawdhub.

This repository is the **sole canonical home** for the skills, the legacy
`bootstrap.js` installer, and the catalog. It is consumed as an external
source by [`ainb`](https://github.com/stevengonsalvez/agents-in-a-box)
(the Rust unit manager) and is installable directly by any SKILL.md-aware
agent harness.

## Related repositories

| Repo | What it holds |
|---|---|
| **stevengonsalvez/ainb-toolkit** (this repo) | Canonical skills (`skills/`), agents (`agents/`), workflows, utilities, the `external-dependencies.yaml` manifest, the `bootstrap.js` legacy installer, and the generated `catalog.yaml`. |
| [stevengonsalvez/agents-in-a-box](https://github.com/stevengonsalvez/agents-in-a-box) | The `ainb` TUI/CLI unit manager (Rust). Installs/browses skills from this repo as a pinned external source, generates the enriched `catalog-index.json` release asset, and ships the `reflect` plugin + `reflect-kb` retrieval CLI. |

---

## Install with `ainb` (recommended)

`ainb` (from the agents-in-a-box repo) treats this repo as an external
skill provider and handles install / update / sync / drift across tool
home dirs:

```bash
# Browse this repo's curated catalog
ainb skill browse "" --catalog ainb

# Add this repo as a source, then install any skill
ainb source add gh:stevengonsalvez/ainb-toolkit
ainb skill install gh:stevengonsalvez/ainb-toolkit@main/skills/<name> --targets claude --yes

# Verify + sync changes back to this repo
ainb skill check
ainb skill sync --to-repo
```

See the agents-in-a-box repo for `ainb` install (homebrew tap or
`cargo install`).

---

## Nix

The flattened `skills/` and `agents/` trees are exposed as Nix packages:

```nix
inputs.ainb-toolkit.url = "github:stevengonsalvez/ainb-toolkit";
# ...
skillsPkg = ainb-toolkit.packages.${system}.skills;   # $out/skills/<name>/...
agentsPkg = ainb-toolkit.packages.${system}.agents;   # $out/agents/<cat>/...
```

```bash
nix build github:stevengonsalvez/ainb-toolkit#skills
```

---

## Quick start (legacy `bootstrap.js`)

The node installer still works and deploys the full tree to a tool home:

```bash
npm install

# Interactive (picks tool from menu)
node bootstrap.js

# Non-interactive (one tool)
node bootstrap.js --tool=claude-code-4.5
node bootstrap.js --tool=codex
node bootstrap.js --tool=copilot
node bootstrap.js --tool=gemini

# Verify everything landed (read-only)
node bootstrap.js --tool=claude-code-4.5 --verify

# Install external deps (git-cloned skills, npx-skills, claude plugins)
bash ~/.claude/setup-external.sh
```

**Repeat for each target tool.** Each tool gets its own home directory
population (`~/.claude/`, `~/.codex/`, …). Hermes is special — it reads
from `~/.claude/skills/` via `skills.external_dirs`, so installing for
Claude transitively covers Hermes.

---

## Repository layout

This repo is **flattened**: the canonical source trees live directly at
the repo root (there is no `packages/` wrapper). Everything here gets
distributed to tool home dirs on `bootstrap` (or installed individually
by `ainb`).

```
skills/                 91 skills — agent-invokable SKILL.md bundles
agents/                 37 agents across 6 categories
├── design/             UI/UX designers
├── engineering/        backend, frontend, security, perf, code-review
├── meta/               agentmaker (create new agents)
├── orchestrators/      tech-lead, project-analyst, team-configurator
├── swarm/              worker/leader primitives for multi-agent work
└── universal/          backend-developer, frontend-developer, superstar-engineer
utilities/
├── config/             Shared tool config templates
├── hooks/              Event hooks (session-start, pre-commit, etc.)
├── output-styles/      Custom output formatters
├── reflections/        Session reflection templates
└── utils/              Shell utility libraries
workflows/
├── single-agent/       Guided plan → implement → validate flows
└── multi-agent/        Swarm/DAG orchestration commands
knowledge/
└── docs-solutions-template/
```

Per-tool config trees (`claude-code-4.5/`, `codex/`, `copilot/`,
`gemini/`, `amazonq/`, `cursor/`, `cline/`, `roo/`, `clawdhub/`, …) and
the shared `general-rules/` also live at the repo root.

> The **reflect** Claude Code plugin and the **reflect-kb** retrieval CLI
> are NOT in this repo — they live in the
> [agents-in-a-box](https://github.com/stevengonsalvez/agents-in-a-box)
> monorepo (`plugins/reflect/` and `reflect-kb/`). `bootstrap.js` installs
> reflect-kb via `uv tool install` by cloning that monorepo; see the
> `installReflectKb()` function for details.

### Skills at a glance (91 total, grouped by purpose)

<details>
<summary><b>Planning & Workflow</b> (15)</summary>

`plan` · `plan-gh` · `plan-tdd` · `implement` · `validate` · `workflow` · `discuss` · `brainstorm` · `interview` · `critique` · `research` · `handover` · `prime` · `recover-sessions` · `make-a-goal`
</details>

<details>
<summary><b>Coding & GitHub</b> (13)</summary>

`coding-agent` · `spawn-agent` · `attach-agent-worktree` · `list-agent-worktrees` · `cleanup-agent-worktree` · `merge-agent-work` · `do-issues` · `gh-issue` · `make-github-issues` · `find-missing-tests` · `commit` · `sync-learnings` · `git-history-surgery`
</details>

<details>
<summary><b>Multi-agent / Swarm</b> (7)</summary>

`swarm-create` · `swarm-join` · `swarm-status` · `swarm-inbox` · `swarm-shutdown` · `swarm-orchestration` · `swarm-agent-troubleshooting`
</details>

<details>
<summary><b>Session & Learning</b> (8)</summary>

`session-info` · `session-metrics` · `session-summary` · `health-check` · `instincts` · `reflect` · `compound-docs` · `research-cache`
</details>

<details>
<summary><b>Testing</b> (5)</summary>

`expect-test` · `webapp-testing` · `browser-verify` · `test-driven-development` · `mobile-e2e-mcp`
</details>

<details>
<summary><b>Design & UI</b> (13)</summary>

`frontend-design` · `frontend-slides` · `liquid-glass` · `tui-style-guide` · `ui-ux-pro-max` · `react-components` · `stitch-design` · `stitch-loop` · `shadcn-ui` · `design-md` · `enhance-prompt` · `remotion` · `remotion-best-practices`
</details>

<details>
<summary><b>Dev infra & tooling</b> (12)</summary>

`tmux-monitor` · `tmux-status` · `start-local` · `start-ios` · `start-android` · `expose` · `plugins` · `oracle` · `debug-bridge` · `media-processing` · `standup` · `tmux-message`
</details>

<details>
<summary><b>Security & Observability</b> (6)</summary>

`security-audit` · `security-scan` · `sentry-cli` · `posthog-replay-analysis` · `claude-langfuse` · `langfuse-setup`
</details>

<details>
<summary><b>Research & Knowledge</b> (4)</summary>

`crypto-research` · `nano-banana-pro` · `notebooklm` · `explain-to-me`
</details>

<details>
<summary><b>Productivity</b> (5)</summary>

`resume-formatter` · `ats-resume-matcher` · `retro-pdf` · `skill-creator` · `token-usage`
</details>

<details>
<summary><b>Meta / autonomous patterns</b> (5)</summary>

`autonomous-loops` · `agent-ops` · `cost-aware-pipeline` · `scrapling-official` · `fireworks-tech-graph`
</details>

---

## External dependencies (`external-dependencies.yaml`)

Skills and plugins authored elsewhere, installed by bootstrap into each
tool's home dir. Sections in the manifest:

| Section | Install mechanism | Target |
|---|---|---|
| `bundled-skills` | (included in `skills/`) | copied by bootstrap |
| `agent-skills` | `git clone <repo>` | `~/.TOOL/skills/<name>/` |
| `claude-plugins` | `claude plugin marketplace install` | Claude plugin cache |
| `npx-skills` | `npx skills add <pkg> --yes` | `~/.agents/skills/` (then symlinked into tool dirs) |
| `nanoclaw-skills` | Synced from `stevengonsalvez/nanoclaw` container/skills/ | `~/.claude/skills/` (shared with claude-code-4.5) |
| `security-skills` | Installed into security-focused agents | tool-specific |
| `mcp-servers` | `claude mcp add` (user scope) | `~/.claude.json` |
| `mcporter-servers` | `mcporter.json` | `~/.mcporter/` |
| `marketplaces` | `claude plugin marketplace add` | Claude plugin cache |

### Key manifest flags

- **`applies-to: [claude, codex, copilot, gemini, hermes-agent, nanoclaw]`** — controls which tools install this entry
- **`catalog-only: true`** — listed for discoverability, never installed (useful for documenting alternatives)
- **`subpath: <dir>`** — repo has `SKILL.md` under a subdirectory; bootstrap extracts just that
- **`multi-subpath: <dir>`** — repo bundles multiple skills under `<dir>/<name>/SKILL.md`; bootstrap flattens each as a sibling install

### How bootstrap uses it

1. `node bootstrap.js --tool=X` — writes tool-specific files to `~/.TOOL/` and generates `~/.TOOL/setup-external.sh`
2. `bash ~/.TOOL/setup-external.sh` — executes the external-install commands (git clones, npx installs, plugin marketplace adds)
3. `--verify` — checks every applicable manifest entry has its `SKILL.md` at the expected path, reports per-tool parity and orphans

---

## Supported tools

Run `bootstrap.js` with `--tool=<X>`:

| Tool key | Home dir | Notes |
|---|---|---|
| `claude-code-4.5` | `~/.claude/` | Primary. Plugins + npx-skills + agent-skills |
| `codex` | `~/.codex/` | AGENTS.md symlinked to claude-code-4.5/CLAUDE.md |
| `copilot` | `~/.copilot/` | GitHub Copilot CLI |
| `gemini` | `~/.gemini/` | Gemini CLI, project-scoped |
| `nanoclaw` | `~/.claude/` (shared) | Successor to OpenClaw, uses same Claude dir |
| `amazonq` | `PROJECT/.amazonq/rules/` | Project-scoped |
| `cursor` `cline` `roo` | `PROJECT/.<tool>/rules/` | Project-scoped rule files |
| `clawdhub` | workspace/skills/ | Clawdhub skill format |

---

## Workflow: add a new skill end-to-end

1. **Author** — create `skills/<name>/SKILL.md` with frontmatter `name`, `description`, and a matching body.
2. **Test locally** — copy to `~/.claude/skills/<name>/` and invoke via the skill harness. (Or just run `node bootstrap.js --tool=claude-code-4.5 --homeDir=$HOME` to reinstall.)
3. **Propagate** — `node bootstrap.js --tool=<each-target>` for every tool you care about. Or use `ainb skill install` per tool.
4. **Verify** — `node bootstrap.js --tool=<X> --verify` should report the skill present on every tool in its applies-to.
5. **Regenerate the catalog** — `bash bin/generate-catalog.sh` to refresh `catalog.yaml`.
6. **Commit** — canonical changes go in `skills/<name>/`.

For **externally-authored** skills (git clones), add an entry to
`external-dependencies.yaml` under `agent-skills:` and set `applies-to`
appropriately. Bootstrap will generate the `git clone` in each tool's
`setup-external.sh`.

---

## Spec-Driven Development (SDD)

Spec Kit integration — drives a spec → plan → tasks workflow via slash
commands in Claude Code.

```bash
# Install SDD assets into a project (clones Spec Kit to a temp folder)
node bootstrap.js --sdd --targetFolder=<project>

# Then in Claude Code within the project:
/specify "Your feature"
/plan
/tasks
```

- `SPEC_KIT_REPO` / `SPEC_KIT_REF` env vars point to a fork/branch
- Artifacts land under `specs/<feature-branch>/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md, tasks.md)
- Works on any `^[0-9]{3}-` feature branch

---

## References

- **Manifest**: [`external-dependencies.yaml`](external-dependencies.yaml)
- **Internal catalog**: [`catalog.yaml`](catalog.yaml) — auto-generated filesystem-derived manifest of every skill, agent, workflow, and utility this repo owns (the "internal" set; anything installed but not listed here is external). Regenerate with `bash bin/generate-catalog.sh`.
- **Bootstrap source**: [`bootstrap.js`](bootstrap.js)
- **Unit manager (`ainb`)**: [stevengonsalvez/agents-in-a-box](https://github.com/stevengonsalvez/agents-in-a-box)
