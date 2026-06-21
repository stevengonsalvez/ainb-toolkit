# Secret-bearing backup research

Use when researching backups, agent profiles, auth stores, browser profiles, cron configs, memory exports, or migration inventories.

## Problem

Backup repos and docs often contain secrets even when filenames look harmless (`backup-system.md`, `auth-profiles.json`, browser profile files, cron payloads, memory notes). Raw file reads can expose tokens, OAuth refresh values, passwords, cookies, webhook secrets, or private identifiers into tool output and conversation history.

## Safe workflow

1. Treat backup roots as secret-bearing by default.
2. Do not raw-read auth/profile/browser/credential/memory backup files unless user explicitly needs exact text and exposure risk is acceptable.
3. Use a secret-aware summarizer that emits only:
   - file path
   - section headings
   - provider/integration names
   - presence/absence booleans
   - expiry timestamps
   - account IDs only as `present`, unless user explicitly asks for the identifier
   - schedule/channel/script names after scanning payloads
4. Redact by key name and value shape. Denylist at minimum:
   - `access`, `refresh`, `token`, `apiKey`, `api_key`, `clientSecret`, `client_secret`, `secret`, `password`, `cookie`, `authorization`, `bearer`, `webhook`, `connectionString`
   - long opaque strings, JWT-like values, Slack/GitHub/OpenAI/Anthropic-style prefixes
5. For markdown docs in backup repos, extract headings and non-secret bullets first. Skip fenced blocks and lines containing secret-like keys or long opaque values.
6. Never copy leaked values into final artifacts, memory, skills, issues, PRs, or Discord.
7. If a tool leaks a secret, immediately stop copying output, log correction, rotate/revoke if appropriate, and continue only with presence-only summaries.

## Output pattern

Good:

```markdown
Auth profiles present:
- openai-codex OAuth profile: present, expires <timestamp>, accountId present
- slack bot token: present [REDACTED]
- WhatsApp pairing file: present [REDACTED]
```

Bad:

```markdown
refresh_token: <actual value>
backup password: <actual value>
```

## Migration inventory checklist

- Channels: names, enabled flags, allowlist shape, delivery targets; no tokens.
- Crons: IDs, names, schedules, delivery channels, script/prompt hints after redaction.
- Auth: provider/type/expiry/presence only.
- Memory/docs: durable facts only; no passwords, recovery phrases, private IDs, or raw personal logs.
- Browser profiles: existence and purpose only; never dump cookies/local storage.
