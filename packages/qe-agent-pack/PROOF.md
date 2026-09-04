# Install proof

Both installs below were run for real on 2026-09-04 against APM CLI 0.29.0 from
empty temporary directories, installing the package from a git ref rather than a
local path so the lockfile pins a commit SHA. Nothing here is reconstructed.

Package ref: `stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-package`
Resolved commit: `bdd7a3a1136a3d53967b3b3cefb3f960cdcac21e`

Reproduce with:

```bash
pip install apm-cli==0.29.0
mkdir /tmp/qe-pack-copilot && cd /tmp/qe-pack-copilot
apm install 'stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-package' --target copilot
```

## Summary

| Check | copilot | claude |
|---|---|---|
| Skills deployed | 4, under `.agents/skills/` | 4, under `.claude/skills/` |
| Agents deployed | 4, under `.github/agents/` | 4, under `.claude/agents/` |
| Instructions deployed | 3, under `.github/instructions/` | 3, under `.claude/rules/` |
| MCP server configured | `playwright-test` in `.github/mcp.json` | `playwright-test` in `.mcp.json` |
| `apm.lock.yaml` commit pin | `bdd7a3a1136a3d53967b3b3cefb3f960cdcac21e` | same |
| `apm.lock.yaml` sha256 entries | 47 | 47 |
| `apm audit --ci` | all 10 checks passed | all 10 checks passed |

`claude` is APM's canonical target slug for the Claude Code harness. There is no
`claude-code` target name; `apm install --target claude` is what puts the pack
under `.claude/`.

On the copilot target, agents and instructions land under `.github/` and skills
land under `.agents/skills/`. That is APM's cross-tool skills convergence, where
seven harnesses share one skills directory, not a misconfiguration.

## Transcript: `--target copilot`

```console
$ apm --version
Agent Package Manager (APM) CLI version 0.29.0

$ pwd
<tmp>/proof-copilot

$ ls -A

$ apm install 'stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-package' --target copilot
[*] Created apm.yml
[i] Targets set: copilot (persisted to apm.yml)
[*] Validating 1 package...
[+] stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-package
[*] Updated apm.yml with 1 new package(s)
[>] Installing 1 new package...
[>] Resolving ainb-toolkit-qe-agent-pack...
[i] Targets: copilot  (source: --target flag)
  [+] 
github.com/stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-
package #f/slice-c-apm-qe-package @bdd7a3a1
  |-- 4 agents integrated -> .github/agents/
  |-- 3 instruction(s) integrated -> .github/instructions/
  |-- 4 skill(s) integrated -> .agents/skills/
[i] Added apm_modules/ to .gitignore
[i] Trusting direct dependency MCP 'playwright-test' from 'qe-agent-pack'
+- MCP Servers (1)
[i] Targeting specific runtime: copilot
|  [>]  playwright-test (self-defined, stdio)
|     +- Configuring for Copilot...
  + playwright-test
|  [+]  playwright-test -> Copilot (configured)
[*] Configured 1 server

[*] Installed 1 APM dependency and 1 MCP server in 0.7s.

$ find . -type f -not -path './apm_modules/*' | sort
./.agents/skills/expect-test/SKILL.md
./.agents/skills/find-missing-tests/SKILL.md
./.agents/skills/test-driven-development/SKILL.md
./.agents/skills/webapp-testing/examples/console_logging.py
./.agents/skills/webapp-testing/examples/element_discovery.py
./.agents/skills/webapp-testing/examples/multi_step_registration.py
./.agents/skills/webapp-testing/examples/static_html_automation.py
./.agents/skills/webapp-testing/LICENSE.txt
./.agents/skills/webapp-testing/scripts/with_server.py
./.agents/skills/webapp-testing/SKILL.md
./.agents/skills/webapp-testing/utils/browser_config.py
./.agents/skills/webapp-testing/utils/form_helpers.py
./.agents/skills/webapp-testing/utils/smart_selectors.py
./.agents/skills/webapp-testing/utils/supabase.py
./.agents/skills/webapp-testing/utils/ui_interactions.py
./.agents/skills/webapp-testing/utils/wait_strategies.py
./.github/agents/playwright-test-generator.agent.md
./.github/agents/playwright-test-healer.agent.md
./.github/agents/playwright-test-planner.agent.md
./.github/agents/test-engineer.agent.md
./.github/instructions/ci-wait-discipline.instructions.md
./.github/instructions/playwright-reports.instructions.md
./.github/instructions/test-strategy.instructions.md
./.github/mcp.json
./.gitignore
./apm.lock.yaml
./apm.yml

$ grep -E 'resolved_commit|resolved_ref|content_hash' apm.lock.yaml | head -3
  resolved_commit: bdd7a3a1136a3d53967b3b3cefb3f960cdcac21e
  resolved_ref: f/slice-c-apm-qe-package
  content_hash: sha256:feee26aade37822995010734f617f1260bc8148d95dba293df2ed5ae2895791e

$ grep -c sha256 apm.lock.yaml
47

$ apm audit --ci
│ [+]      │ includes-consent         │ No local content deployed -- includes  │
│          │                          │ consent check skipped                  │
│ [+]      │ drift                    │ no drift detected against lockfile     │
└──────────┴──────────────────────────┴────────────────────────────────────────┘

[*] All 10 check(s) passed
```

## Transcript: `--target claude`

```console
$ apm --version
Agent Package Manager (APM) CLI version 0.29.0

$ pwd
<tmp>/proof-claude

$ ls -A

$ apm install 'stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-package' --target claude
[*] Created apm.yml
[i] Targets set: claude (persisted to apm.yml)
[*] Validating 1 package...
[+] stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-package
[*] Updated apm.yml with 1 new package(s)
[>] Installing 1 new package...
[>] Resolving ainb-toolkit-qe-agent-pack...
[i] Targets: claude  (source: --target flag)
  [+] 
github.com/stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#f/slice-c-apm-qe-
package #f/slice-c-apm-qe-package @bdd7a3a1
  |-- 4 agents integrated -> .claude/agents/
  |-- 3 rule(s) integrated -> .claude/rules/
  |-- 4 skill(s) integrated -> .claude/skills/
[i] Added apm_modules/ to .gitignore
[i] Trusting direct dependency MCP 'playwright-test' from 'qe-agent-pack'
+- MCP Servers (1)
[i] Targeting specific runtime: claude
|  [>]  playwright-test (self-defined, stdio)
|     +- Configuring for Claude...
Successfully configured MCP server 'playwright-test' for Claude Code
  + playwright-test
|  [+]  playwright-test -> Claude (configured)
[*] Configured 1 server

[*] Installed 1 APM dependency and 1 MCP server in 0.6s.

$ find . -type f -not -path './apm_modules/*' | sort
./.claude/agents/playwright-test-generator.md
./.claude/agents/playwright-test-healer.md
./.claude/agents/playwright-test-planner.md
./.claude/agents/test-engineer.md
./.claude/rules/ci-wait-discipline.md
./.claude/rules/playwright-reports.md
./.claude/rules/test-strategy.md
./.claude/skills/expect-test/SKILL.md
./.claude/skills/find-missing-tests/SKILL.md
./.claude/skills/test-driven-development/SKILL.md
./.claude/skills/webapp-testing/examples/console_logging.py
./.claude/skills/webapp-testing/examples/element_discovery.py
./.claude/skills/webapp-testing/examples/multi_step_registration.py
./.claude/skills/webapp-testing/examples/static_html_automation.py
./.claude/skills/webapp-testing/LICENSE.txt
./.claude/skills/webapp-testing/scripts/with_server.py
./.claude/skills/webapp-testing/SKILL.md
./.claude/skills/webapp-testing/utils/browser_config.py
./.claude/skills/webapp-testing/utils/form_helpers.py
./.claude/skills/webapp-testing/utils/smart_selectors.py
./.claude/skills/webapp-testing/utils/supabase.py
./.claude/skills/webapp-testing/utils/ui_interactions.py
./.claude/skills/webapp-testing/utils/wait_strategies.py
./.gitignore
./.mcp.json
./apm.lock.yaml
./apm.yml

$ grep -E 'resolved_commit|resolved_ref|content_hash' apm.lock.yaml | head -3
  resolved_commit: bdd7a3a1136a3d53967b3b3cefb3f960cdcac21e
  resolved_ref: f/slice-c-apm-qe-package
  content_hash: sha256:feee26aade37822995010734f617f1260bc8148d95dba293df2ed5ae2895791e

$ grep -c sha256 apm.lock.yaml
47

$ apm audit --ci
│ [+]      │ includes-consent         │ No local content deployed -- includes  │
│          │                          │ consent check skipped                  │
│ [+]      │ drift                    │ no drift detected against lockfile     │
└──────────┴──────────────────────────┴────────────────────────────────────────┘

[*] All 10 check(s) passed
```

## Policy audit

Run from a clean-room consumer that declares `name`, `version`, `description`
and `license`, which is what `manifest.required_fields` in `apm-policy.yml`
demands of a consuming repo. This is the same sequence `.github/workflows/ci.yml`
runs on every pull request.

```console
$ apm install <repo>/packages/qe-agent-pack
[*] Installed 1 APM dependency and 1 MCP server in 1.9s.

$ apm audit --ci --policy <repo>/packages/qe-agent-pack/apm-policy.yml
[*] All 31 check(s) passed

$ apm audit --format sarif -o apm-audit.sarif
$ python3 -c "import json; d=json.load(open('apm-audit.sarif')); print(d['version'], len(d['runs'][0]['results']))"
2.1.0 10
```

The ten SARIF results are all `note` level: emoji variation selectors (U+FE0F)
inside the bundled skill bodies. They do not fail `apm audit --ci`.

## Conformance proof

```console
$ scripts/check-agentskills-conformance skills

checked 94 skills, 94 conform, 0 failed
$ echo $?
0

$ scripts/check-agentskills-conformance tests/fixtures/agentskills/broken
tests/fixtures/agentskills/broken/bad_Name/SKILL.md: name 'bad_Name' must be lowercase alphanumeric with single hyphens (pattern ^[a-z0-9]+(-[a-z0-9]+)*$)
tests/fixtures/agentskills/broken/dir-mismatch/SKILL.md: name 'some-other-name' does not match its directory 'dir-mismatch'
tests/fixtures/agentskills/broken/long-description/SKILL.md: description is 1703 characters, limit is 1024
tests/fixtures/agentskills/broken/no-frontmatter/SKILL.md: missing YAML frontmatter (file must start with a --- block)
tests/fixtures/agentskills/broken/underscore-tools/SKILL.md: key 'allowed_tools' must be spelled 'allowed-tools'

checked 5 skills, 0 conform, 5 failed
$ echo $?
1
```
