# Install proof

Both installs below were run for real on 2026-09-04 against APM CLI 0.29.0 from
empty temporary directories. The package is pinned to an immutable commit SHA
rather than a branch, so these commands keep working after the branch is merged
and deleted. Nothing here is reconstructed.

Package ref: `stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c9688121e40f0a260b17f50001`

Reproduce with:

```bash
pip install apm-cli==0.29.0
mkdir /tmp/qe-pack-copilot && cd /tmp/qe-pack-copilot
apm install 'stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c9688121e40f0a260b17f50001' --target copilot
```

## Summary

| Check | copilot | claude |
|---|---|---|
| Skills deployed | 4, under `.agents/skills/` | 4, under `.claude/skills/` |
| Agents deployed | 4, under `.github/agents/` | 4, under `.claude/agents/` |
| Instructions deployed | 3, under `.github/instructions/` | 3, under `.claude/rules/` |
| MCP server configured | `playwright-test` in `.github/mcp.json` | `playwright-test` in `.mcp.json` |
| `apm.lock.yaml` commit pin | `c2fce145e08863c9688121e40f0a260b17f50001` | same |
| `apm.lock.yaml` sha256 entries | 47 | 47 |
| `apm install --frozen` replay | reproduces, exit 0 | reproduces, exit 0 |
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
<tmp>/proof2-copilot

$ ls -A

$ apm install 'stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c9688121e40f0a260b17f50001' --target copilot
[*] Created apm.yml
[i] Targets set: copilot (persisted to apm.yml)
[*] Validating 1 package...
[+] 
stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c9688121e40f0a
260b17f50001
[*] Updated apm.yml with 1 new package(s)
[>] Installing 1 new package...
[>] Resolving ainb-toolkit-qe-agent-pack...
[i] Targets: copilot  (source: --target flag)
  [+] 
github.com/stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c96
88121e40f0a260b17f50001 #c2fce145e08863c9688121e40f0a260b17f50001 @c2fce145
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

[*] Installed 1 APM dependency and 1 MCP server in 2.4s.

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
  resolved_commit: c2fce145e08863c9688121e40f0a260b17f50001
  resolved_ref: c2fce145e08863c9688121e40f0a260b17f50001
  content_hash: sha256:e394b47745ec983d9abb0e3d041d94301289b4991f1c76095d1707d5a8341d54

$ grep -c sha256 apm.lock.yaml
47

$ apm install --frozen

[*] Installed 1 APM dependency in 0.5s.
[i] Lockfile presence verified. Run 'apm audit' for on-disk content integrity.

$ apm audit --ci
└──────────┴──────────────────────────┴────────────────────────────────────────┘

[*] All 10 check(s) passed
```

## Transcript: `--target claude`

```console
$ apm --version
Agent Package Manager (APM) CLI version 0.29.0

$ pwd
<tmp>/proof2-claude

$ ls -A

$ apm install 'stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c9688121e40f0a260b17f50001' --target claude
[*] Created apm.yml
[i] Targets set: claude (persisted to apm.yml)
[*] Validating 1 package...
[+] 
stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c9688121e40f0a
260b17f50001
[*] Updated apm.yml with 1 new package(s)
[>] Installing 1 new package...
[>] Resolving ainb-toolkit-qe-agent-pack...
[i] Targets: claude  (source: --target flag)
  [+] 
github.com/stevengonsalvez/ainb-toolkit/packages/qe-agent-pack#c2fce145e08863c96
88121e40f0a260b17f50001 #c2fce145e08863c9688121e40f0a260b17f50001 @c2fce145
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

[*] Installed 1 APM dependency and 1 MCP server in 0.7s.

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
  resolved_commit: c2fce145e08863c9688121e40f0a260b17f50001
  resolved_ref: c2fce145e08863c9688121e40f0a260b17f50001
  content_hash: sha256:e394b47745ec983d9abb0e3d041d94301289b4991f1c76095d1707d5a8341d54

$ grep -c sha256 apm.lock.yaml
47

$ apm install --frozen

[*] Installed 1 APM dependency in 0.8s.
[i] Lockfile presence verified. Run 'apm audit' for on-disk content integrity.

$ apm audit --ci
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

One caveat found while testing the policy rather than assuming it: a consumer
declaring `targets: [cursor]`, outside `compilation.target.allow`, also passes
all 31 checks. APM 0.29.0's `_check_compilation_target`
(`policy/policy_checks.py:508`) reads the legacy singular `target:` key and
ignores the plural `targets:` list. The allow list is documented intent, not an
enforced control. Recorded in the package README under Known limitations.

## Conformance proof

```console
$ scripts/check-agentskills-conformance skills packages/qe-agent-pack/.apm/skills

checked 98 skills, 98 conform, 0 failed
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

The 98 count is the 94 shipped skills plus the 4 vendored copies under the pack.

## A note on the recorded commit

The transcripts pin the commit immediately before this file was rewritten.
`PROOF.md` lives inside the package, so committing the transcript changes the
package tree the transcript describes and would move the SHA it records. The
recorded ref is exact and reproducible as written; the package's primitives
(`apm.yml`, `apm-policy.yml`, `.apm/`) are unchanged since that commit.
