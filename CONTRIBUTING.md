# Contributing

Thanks for improving ainb-toolkit.

## Before opening a pull request

1. Keep each pull request focused on one concern.
2. Do not commit credentials, local configuration, personal paths, logs, or
   generated runtime state.
3. Preserve third-party licenses and attribution. See
   [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md) after the licensing pull request
   is merged.
4. Update generated catalogue files only through their generator.

## Local checks

Install JavaScript dependencies with `npm ci`, then run relevant checks:

```bash
npm test
scripts/generate-backstage-catalog --check
scripts/check-agentskills-conformance skills packages/qe-agent-pack/.apm/skills packages/test-writer-pack/.apm/skills
bats tests/plugin
```

The APM workflow also runs `scripts/sync-qe-agent-pack --check` and clean-room
package installation. Run it locally when `apm` is available.

## Pull request expectations

Describe the change, its verification, and any new external dependency. Do
not include unrelated formatting, generated drift, or private operational
details.
