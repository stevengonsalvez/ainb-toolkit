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

## Backstage catalogue

`catalog-info.yaml` describes the whole pack in the Backstage catalog model so
that Roadie, or any Backstage, lists every skill and agent as a catalogued
asset with provenance and an eval score. It is generated, never hand-edited:

| Entity | Kind | One per |
|---|---|---|
| `qe-agent-pack` | `System` | the pack; carries the eval summary in its description and links to the gate report |
| `expect-test`, `webapp-testing`, `find-missing-tests`, `test-driven-development` | `AiResource`, `spec.type: skill` | skill under `.apm/skills/` |
| `test-engineer`, `playwright-test-planner`, `playwright-test-generator`, `playwright-test-healer` | `AiResource`, `spec.type: skill`, category `agent` | agent under `.apm/agents/` |
| `playwright-test` | `API`, `spec.type: mcp-server` | entry in `dependencies.mcp` of `apm.yml` |

The `AiResource` kind ships with Backstage's
`@backstage/plugin-catalog-backend-module-ai-model` (catalog-model 1.10.0,
Backstage 1.51 and later). Its documented spec types are `skill`, `rule`,
`plugin` and `marketplace`; there is no `agent` type, so agents are
`type: skill` with `agent` in `spec.categories`, which keeps them inside the
validated skill schema rather than an undocumented type.

```bash
scripts/generate-backstage-catalog            # regenerate catalog-info.yaml and .well-known/skills/index.json
scripts/generate-backstage-catalog --check    # exit 1 if either file drifts from apm.yml, .apm/ or eval-score.json
scripts/validate-backstage-catalog packages/qe-agent-pack/catalog-info.yaml   # Backstage entity model check
```

CI runs `--check`, validates the file with the validators that
`@backstage/catalog-model` itself exports (entity policies plus the System, API,
mcp-server and AiResource skill schemas), and proves the validator rejects
`tests/fixtures/backstage/invalid-catalog-info.yaml`. The generator needs only
Python 3 and PyYAML; the validator needs `npm ci` at the repo root.

### Registering it in Roadie or Backstage

Either route works; both read the file straight from GitHub, so nothing is
built or hosted here.

- **Catalog location.** Register the raw file URL once, from the catalog
  import page or `app-config.yaml`:

  ```yaml
  catalog:
    locations:
      - type: url
        target: https://github.com/stevengonsalvez/ainb-toolkit/blob/main/packages/qe-agent-pack/catalog-info.yaml
  ```

- **Discovery.** A GitHub discovery provider that scans for `catalog-info.yaml`
  (the default filename) picks it up with no per-file registration; add the
  repository or organisation to the provider's filters. Roadie's GitHub
  autodiscovery does the same from its Roadie Settings page.

Two prerequisites on the catalog side: the `AiResource` kind must be
registered (the ai-model backend module, or the equivalent toggle on a hosted
Backstage such as Roadie), and the owner `user:stevengonsalvez` should exist
as a User entity or the `ownedBy` relation shows as unresolved. The `System`
and `API` entities load on any Backstage without either.

The multi-document file is split on `---`, and the `System` entity comes first
so the `partOf` relations from every skill, agent and MCP server resolve in the
same ingestion pass.

### Annotation vocabulary

| Annotation | On | Value |
|---|---|---|
| `backstage.io/source-location` | every entity | `url:` plus the GitHub `tree` (directory) or `blob` (file) URL at the exact commit sha the entity was generated from; skills point at their directory, agents at their `.agent.md`, the MCP server at `apm.yml`, the System at the pack root |
| `wololo.dev/eval-score` | the System | compact JSON with `metrics` (candidate and baseline per signal), `recorded` date, `source` URL of the gate report, `sourceVisibility` and `verdict`, copied from `eval-score.json` |
| `wololo.dev/eval-score-ref` | every other entity | entity reference to the System that carries the score, so the numbers are stored once |
| `wololo.dev/apm-package` | every entity | `<name>@<version>` from `apm.yml` |
| `wololo.dev/mcp-servers` | agents whose `tools` name `mcp__<server>__*` tools | comma-separated server names; the generator fails if a named server is not declared in `apm.yml` |
| `wololo.dev/agent-model` | agents that declare a `model` | the `model` field from the agent frontmatter |

The source-location sha is the last commit that touched `apm.yml`, `.apm/` or
`eval-score.json`, not the commit that regenerated the file, so the URL always
resolves to the bytes the entity describes. The generator refuses to run while
those sources have uncommitted changes (`--allow-dirty` overrides). `--check`
reads the sha already pinned in `catalog-info.yaml`, requires that commit to
exist and the sources on disk to match it byte for byte, then compares the
regenerated output, so a change to the sources without regenerating fails CI
whichever way the pull request was checked out.

Merge pull requests that touch the pack with a merge commit. A squash or
rebase merge rewrites the pinned commit: the drift check on `main` then reports
the commit as unreachable and every published source-location URL breaks.

### Derived versus supplied

| Value | Source |
|---|---|
| Entity names, titles, descriptions | derived: skill and agent frontmatter, `apm.yml` for the System and MCP server |
| `spec.owner` | derived: `author` in `apm.yml`, as `user:<author>` |
| `spec.system`, tags, `wololo.dev/apm-package` | derived: `name`, `keywords`, `version` in `apm.yml` |
| `spec.agents` | derived: `targets` in `apm.yml`, mapped `claude` to `claude-code` and `copilot` to `github-copilot` |
| `spec.license`, `spec.allowedTools` | derived: skill frontmatter, falling back to the `apm.yml` license |
| MCP `remotes` and `definition` | derived: the `dependencies.mcp` entry, `command` plus `args` for stdio |
| Eval score, gate report URL, date, verdict | supplied: `eval-score.json`, validated by the generator (required signals, numbers in `[0, 1]`, ISO date, https URL, and a `PASS` verdict only when every guarded signal holds its baseline) |
| `spec.lifecycle` (`experimental`), `spec.disciplines` (`quality-engineering`), categories (`testing`, `agent`) | supplied: constants at the top of `scripts/generate-backstage-catalog` |

`eval-score.json` records the `qe-skill` benchmark gate for this pack from
wololo-evals: mutation kill rate 0.3012 against a 0.2373 no-agent baseline,
seeded-defect catch 0.3636 against 0.2500, flake resistance 1.0. Those numbers
are recomputed at gate time from real mutation and seeded-defect runs; the
recorded trajectories in that corpus are hand-authored fixtures, and the file
says so. Update the file when a new gate run lands, then regenerate.

The gate report lives in a private repository. `eval-score.json` marks it
`"visibility": "internal"`, the annotation carries that as
`sourceVisibility`, and the System's link is titled accordingly: the URL is
the real location of the report, it resolves for anyone with access to that
repository, and it returns 404 to an unauthenticated fetch. No public mirror
exists, so none is claimed.

### Skills index

`.well-known/skills/index.json` follows the Backstage skills convention
(`{"skills": [{"name", "description", "files"}]}`, the same shape as
`backstage.io/.well-known/skills/index.json`) so a skills installer can list
the pack's skills without parsing `apm.yml`. Names match the skill directories,
descriptions match the `SKILL.md` frontmatter, and `files` lists every file in
the skill directory. It is generated and drift-checked alongside
`catalog-info.yaml`. To serve it from a domain, publish the `.well-known/skills`
directory together with the skill directories from `.apm/skills/`.

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
