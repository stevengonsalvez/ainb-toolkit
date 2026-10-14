# OpenClaw Agents: Usage Sync Hook

Real-time Claude Code session usage tracking. Fires on `Stop` and `SubagentStop` events, parses the session JSONL transcript, and pushes aggregated usage data (tokens, cost, model, duration) to a Convex HTTP endpoint for dashboard display.

## Prerequisites

- A Convex deployment with a `sessionUsage` table and an HTTP POST endpoint at
  `/api/usage`
- `uv` installed (for running the hook script)
- `python-dotenv` (auto-installed via inline script metadata)

## Installation

1. Copy the hook script:
   ```bash
   cp hooks/usage_sync.py ~/.claude/hooks/usage_sync.py
   chmod +x ~/.claude/hooks/usage_sync.py
   ```

2. Chain into your `~/.claude/settings.json` Stop and SubagentStop hooks (see `settings.json` in this directory for the exact entries to add).

3. Set the Convex URL via one of:
   - `CONVEX_URL` environment variable
   - `NEXT_PUBLIC_CONVEX_URL` environment variable
   - `OPENCLAW_ENV_FILE` pointing to a local env file

   Set `OPENCLAW_AGENT_ID` when the deployment needs a fixed agent identifier.
   No project path or session-slug inference is performed.

## What it tracks

| Field | Source |
|-------|--------|
| `tokensIn/Out` | `message.usage.input_tokens / output_tokens` |
| `cacheRead/Write` | `message.usage.cache_read_input_tokens / cache_creation_input_tokens` |
| `costTotal` | Calculated from token counts x model pricing |
| `messageCount` | Count of assistant messages with usage data |
| `toolUseCount` | Count of `tool_use` content blocks |
| `durationMs` | First timestamp to last timestamp |
| `model` | From `message.model` (skips `<synthetic>` from compacted sessions) |

## Agent identification

Sessions use `OPENCLAW_AGENT_ID` when it is set. Otherwise the hook reports
`unknown`; deployments can group that value at the destination.

## Model pricing (per million tokens, USD)

| Model | Input | Output | Cache Read | Cache Write |
|-------|-------|--------|------------|-------------|
| claude-opus-4-6 | $15.00 | $75.00 | $1.50 | $18.75 |
| claude-sonnet-4-5 | $3.00 | $15.00 | $0.30 | $3.75 |
| claude-haiku-4-5 | $0.80 | $4.00 | $0.08 | $1.00 |

## Local backup

All usage data is always appended to `~/.claude/usage/sessions.jsonl` regardless of whether the Convex push succeeds.
