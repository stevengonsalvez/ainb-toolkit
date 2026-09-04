# qe-agent-pack

A quality engineering agent pack, distributed through
[Microsoft APM](https://github.com/microsoft/apm). One `apm install` puts the
same four testing skills, four testing agents, three testing instructions and
one MCP server into GitHub Copilot or Claude Code.

Built and verified against APM CLI **0.29.0**.

## Contents

### Skills (4)

| Skill | What it does | Source |
|---|---|---|
| `expect-test` | AI-generated browser tests driven from the git diff, executed via expect-cli | `skills/expect-test` |
| `webapp-testing` | Python Playwright toolkit for driving local web apps, screenshots, console logs | `skills/webapp-testing` |
| `find-missing-tests` | Scans a codebase for test gaps and files a GitHub issue per gap | `skills/find-missing-tests` |
| `test-driven-development` | Enforces the RED, GREEN, REFACTOR cycle before implementation code is written | `skills/test-driven-development` |

### Agents (4)

| Agent | What it does | Source |
|---|---|---|
| `test-engineer` | Writes, runs, fixes and validates tests, and proves whether a green suite is telling the truth | `agents/engineering/test-engineer.md` |
| `playwright-test-planner` | Explores a running app and saves a structured test plan | `npx playwright init-agents` |
| `playwright-test-generator` | Turns one test plan item into a real Playwright spec by driving the browser | `npx playwright init-agents` |
| `playwright-test-healer` | Runs the suite, debugs failures and repairs broken specs | `npx playwright init-agents` |

The three Playwright agents are first-party Playwright definitions, generated
with `npx playwright init-agents --loop=claude` on Playwright 1.62.1 and checked
in verbatim under `.apm/agents/`. Regenerate them by rerunning that command in a
scratch project and copying the output, not by hand-editing.

### Instructions (3)

| Instruction | `applyTo` | Source |
|---|---|---|
| `test-strategy` | test and spec files | `copilot/AGENTS.md` Engineering Defaults, `agents/engineering/test-engineer.md` |
| `playwright-reports` | Playwright configs, specs, package.json, shell scripts | `general-rules/no-playwright-show-report-rule.mdc`, `copilot/AGENTS.md` |
| `ci-wait-discipline` | workflow files, Makefiles, shell scripts | `copilot/AGENTS.md` never_idle_while_waiting |

### MCP servers (1)

`playwright-test`, self-defined stdio, `npx playwright run-test-mcp-server`.
Declared in `apm.yml` so `apm install` wires it into the harness config
automatically. The three Playwright agents are inert without it: every tool
they name is an `mcp__playwright-test__*` tool.

## Install

From a clean directory, with APM on PATH:

```bash
# GitHub Copilot
apm install <path-or-git-ref>/packages/qe-agent-pack --target copilot

# Claude Code
apm install <path-or-git-ref>/packages/qe-agent-pack --target claude
```

`claude` is APM's canonical slug for the Claude Code harness; it deploys to
`.claude/`. There is no `claude-code` target name. Run
`apm targets` to see what APM resolved.

Both installs write `apm.lock.yaml` with a per-file `sha256` for everything
deployed, and a resolved commit SHA when the source is a git ref. Commit that
lockfile. `apm install --frozen` then reproduces it exactly in CI.

### Where things land

Verified by running both installs; see [PROOF.md](./PROOF.md) for the
transcripts.

| Primitive | `--target copilot` | `--target claude` |
|---|---|---|
| Skills | `.agents/skills/<name>/` | `.claude/skills/<name>/` |
| Agents | `.github/agents/<name>.agent.md` | `.claude/agents/<name>.md` |
| Instructions | `.github/instructions/<name>.instructions.md` | `.claude/rules/<name>.md` |
| MCP config | `.github/mcp.json` | `.mcp.json` |

Skills land under `.agents/skills/` on the Copilot target, not `.github/`. That
is APM's cross-tool skills convergence, not a misconfiguration: seven harnesses
share that directory.

## External dependencies

Nothing below is bundled. The pack ships instructions and prompts; the binaries
that actually drive a browser are the consumer's to install.

| Component | Needs | Install |
|---|---|---|
| `expect-test` | `expect-cli`, plus a Chromium matching the `playwright-core` version expect-cli pins | `npm install -g expect-cli@latest`, then `node $(npm root -g)/expect-cli/node_modules/playwright-core/cli.js install chromium` |
| `webapp-testing` | Python Playwright and its browsers | `pip install playwright && playwright install chromium` |
| `playwright-test-*` agents | `@playwright/test` in the consumer repo, its browsers, and the `playwright-test` MCP server | `npm install -D @playwright/test && npx playwright install`; APM wires the MCP server |
| `find-missing-tests` | GitHub CLI, authenticated, for `gh issue create` | `brew install gh && gh auth login` |
| `test-driven-development` | Nothing beyond the project's own test runner | none |

Do NOT run `npx playwright install` and expect `expect-test` to pick it up:
expect-cli resolves browsers against its own pinned `playwright-core`, so the
system-wide install is invisible to it. The second command in the `expect-test`
row is the one that works.

### Related but not bundled

`browser-verify` (in `skills/browser-verify`) pairs expect-cli with
`debug-bridge` for screenshots and DOM inspection. It is deliberately outside
this pack because `debug-bridge` needs a WebSocket bridge running against the
app's own browser (`npx debug-bridge-cli connect`), which is a per-project
runtime setup rather than a package dependency. Install the skill directly if
you want it.

## Known limitations

- **`webapp-testing/bin/browser-tools` does not travel.** APM's skill copier
  filters a skill-level `bin/` directory (`integration/skill_support.py`); its
  executable support is scoped to a package-root `bin/`. Because nothing in
  `bin/` could ever reach a consumer, the pack does not vendor it at all:
  `.apm/skills/webapp-testing/` holds the thirteen files that do deploy, and
  `scripts/sync-qe-agent-pack` excludes `bin/` from both the copy and the drift
  check. The deployed `SKILL.md` still documents `browser-tools`, so a consumer
  who wants the Chrome DevTools Protocol helper copies
  `skills/webapp-testing/bin/` across by hand. The Python path
  (`scripts/with_server.py` plus `utils/`) is fully deployed and is the primary
  interface.
- **Copilot and Claude Code are the whole supported surface.** `apm.yml`
  declares `targets: [copilot, claude]` and `apm-policy.yml` allows exactly that
  pair under `compilation.target.allow`. Nothing in the content is
  harness-specific beyond the deploy paths, so the pack would compile to Cursor,
  Codex or Gemini, but those are out of policy: widen
  `compilation.target.allow` in a reviewed change before installing to one.
- **That target allow list is weaker than it looks.** In APM 0.29.0
  `_check_compilation_target` (`policy/policy_checks.py:508`) reads the
  consuming repo's legacy singular `target:` key and ignores the plural
  `targets:` list that `apm init` writes today. A consumer declaring
  `targets: [cursor]` therefore passes `apm audit --ci --policy` clean; verified
  by running it. Treat the allow list as a documented intent that the tooling
  only partly enforces, not as a control.
- **`apm audit` reports info-level unusual-character findings.** These come from
  box-drawing characters and typographic dashes inside the bundled skill bodies.
  They are informational, do not fail `--ci`, and are visible with
  `apm audit --verbose`.

## Maintaining the pack

`.apm/skills/` and `.apm/agents/test-engineer.agent.md` are real copies of the
toolkit sources, not symlinks: APM refuses symlinks that escape the package root
("Only in-package symlinks are dereferenced"). `scripts/sync-qe-agent-pack` is
the single writer of those copies.

```bash
scripts/sync-qe-agent-pack           # re-vendor from skills/ and agents/
scripts/sync-qe-agent-pack --check   # fail if the copies have drifted
```

CI runs the `--check` form, so a change to `skills/expect-test` that is not
re-vendored fails the build rather than shipping a stale pack.

## Governance

`apm-policy.yml` is a repo-scoped, tighten-only policy: it pins the allowed
compilation targets, restricts MCP to the single stdio `playwright-test` server,
requires hashes in the lockfile, fails the audit on drift, and denies executable
primitives. APM merges policy chains tighten-only (allow lists intersect, deny
lists union, enforcement takes the stricter of the two), so adopting an
enterprise hub policy above this file can only make it stricter.

```bash
apm audit --ci --policy ./packages/qe-agent-pack/apm-policy.yml
apm audit --format sarif -o apm-audit.sarif
```
