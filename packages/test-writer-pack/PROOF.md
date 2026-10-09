# Install proof

Run on a clean consumer directory, APM CLI 0.29.0, 2026-10-09.

## Clean-room install into both harnesses

```console
$ mkdir /tmp/c7-consumer && cd /tmp/c7-consumer
$ cat > apm.yml <<'YAML'
name: test-writer-pack-c7-consumer
version: 1.0.0
description: Clean-room consumer used to verify the test-writer pack installs into both harnesses.
license: MIT
targets:
  - copilot
  - claude
YAML
$ apm install <path>/packages/test-writer-pack
[i] Targets: claude, copilot  (source: apm.yml)
  |-- 2 agents integrated -> .claude/agents/, .github/agents/
  |-- 1 skill(s) integrated -> .agents/skills/, .claude/skills/
[*] Installed 1 APM dependency in 0.1s.
```

What landed:

```console
$ find .claude .github .agents -type f | sort
.agents/skills/test-writer-fixer/SKILL.md
.claude/agents/test-writer-fixer.md
.claude/skills/test-writer-fixer/SKILL.md
.github/agents/test-writer-fixer.agent.md
```

Both harnesses get the skill and the agent. "2 agents" is one per target, not a
duplicate inside one.

## What this proof caught

The first attempt failed outright: `apm.yml` declared `type: agent`, which APM
rejects. The valid types are `instructions`, `skill`, `hybrid` and `prompts`,
and there is no separate agent type, so a package shipping skills and agents is
a `skill` package. The manifest now says so and the install succeeds.

Noted and not fixed here: APM logs a YAML parse warning against the agent
file's `description`, which is a single long escaped string carrying `<example>`
blocks. It installs correctly regardless. The file is a verbatim copy of
`gemini/agents/engineering/test-writer-fixer.md`, so rewriting its frontmatter
belongs with that source rather than with the vendored copy.

## Not proven here

A Copilot live run. The Copilot CLI (1.0.94) on this machine refuses every
model in the pack's allow-list:

```console
$ copilot -p 'Reply with the single word OK.' --model gpt-4.1 --allow-all-tools
Error: Access denied by policy settings
```

The same refusal comes back for `gpt-5.4-mini` and `claude-sonnet-4.6`, so this
is an organisation policy or subscription limit rather than anything about the
pack. It needs a person with Copilot administration access, not a code change.
