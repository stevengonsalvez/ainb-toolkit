# Replay access blockers

Use when a user asks to "check PostHog" but the runtime may not have UI/session auth.

## What happened

A SHOTclubhouse investigation needed replay evidence for a Liam-reported Perform issue. Repo/GitHub evidence was available, but PostHog replay verification was blocked.

Observed blockers:

```text
Chrome launch failed: No usable sandbox / DevToolsActivePort
Hint: try --args "--no-sandbox"
agent-browser: command not found
No POSTHOG_PERSONAL_API_KEY / PH_TOKEN / PH_PROJECT_ID found in searched .env/.secrets paths
Only VITE_PUBLIC_POSTHOG_HOST and VITE_PUBLIC_POSTHOG_KEY variable names were visible
```

## Rule

Do not say PostHog was checked unless a replay/API query actually succeeded.

Safe report shape:

```text
PostHog: blocked. No personal API token or authenticated browser state in this runtime; public project key is ingest-only. Code/GitHub evidence says <finding>. Replay confirmation still pending.
```

## Why

PostHog public keys identify the project for event ingestion. They do not authorize session replay reads. Replay API needs a personal API key with `session_recording:read` and numeric project id, or an authenticated UI session.
