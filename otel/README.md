# OTEL dashboards

Grafana dashboards for the Claude Code / Codex OpenTelemetry pipeline
(`Claude Code → local Grafana Alloy → Grafana Cloud`).

| File | Dashboard |
|------|-----------|
| `dashboards/claude-code.json` | Claude Code — Full Telemetry (32 panels: cost/tokens, lines of code, commits/PRs, edit accept-rate, cache-hit, API latency/errors, tool usage, logs, traces) |
| `dashboards/codex.json` | Codex usage |

## Import

Grafana Cloud → Dashboards → New → Import → upload the JSON (or paste it),
then pick your Prometheus datasource for `DS_PROMETHEUS`. The Loki/Tempo panels
expect datasource UIDs `grafanacloud-logs` / `grafanacloud-traces` (rename in
the JSON if yours differ). The dashboard `uid` is stable, so re-importing
overwrites in place rather than duplicating.

## Setup

`ainb otel setup` (in the agents-in-a-box repo) wires the whole pipeline —
installs Grafana Alloy, writes the OTLP config + creds, and drops a copy of
these dashboards into `~/.agents-in-a-box/otel/dashboards/`. The `ainb` binary
embeds its own copy of these JSON files for that flow; the copies here are the
standalone, importable mirror — keep them in sync when editing.

> Note: the log-derived panels (API latency, tool usage, errors) assume the
> OTLP→Loki path exposes event attributes as structured metadata
> (`event_name`, `duration_ms`, `tool_name`, `success`). If your Loki maps them
> differently, adjust those panel queries.
