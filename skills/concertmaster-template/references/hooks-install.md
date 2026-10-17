# Worker hooks: install guide (optional)

Optional. Only useful when the project runs a telemetry sink (a
mission-control style dashboard) and sets `cfg.telemetry.base_url`. The
concertmaster works without it: the tick reads Orca directly. Nothing here is
installed by the template; installing is a separate, explicit step the owner
approves per host.

```text
┌─────────────┐ stdin JSON ┌───────────────────┐ org repo?  ┌────────────┐
│ Claude Code │───────────▶│ mc-worker-hook.sh │──── no ───▶│ exit 0     │
│ hook event  │            └─────────┬─────────┘            └────────────┘
└─────────────┘                      │ yes, detached
                                     ▼
                           ┌───────────────────┐ 2xx  ┌─────────────────┐
                           │ mc-emit.sh        │─────▶│ telemetry sink  │
                           │ outbox.jsonl      │◀─────│ (keeps on fail) │
                           └───────────────────┘      └─────────────────┘
```

Events: `SessionStart` (status `active`), `Stop` (status `idle`, a turn ended),
`Notification` (status `idle`, carries the notification text: a permission
prompt or "waiting for input"). Each sends one `/api/events` line and one
`/api/fleet/upsert` line. The fleet `agentId` is `<short-hostname>:<session_id>`.

Global hooks fire for every repo on a shared host. The hook exits silently
unless the session's cwd has an `origin` in `github.com/<cfg.github.org>/`
(case-insensitive, `cfg.github.exclude_repo_patterns` excluded), via
`cm_org_slug` in `lib.sh`, so every other repo emits nothing. It prints nothing
to stdout (SessionStart stdout would be injected into the session) and always
exits 0.

## Prerequisites per host

- `bash`, `git`, `jq`, `yq`, `curl` (macOS: `brew install jq yq`; system bash
  3.2 is fine).
- A project checkout on `main` to copy the scripts from.
- A sink token in the file named by `cfg.telemetry.token_file`, mode 600.
- The tenant id (`cfg.telemetry.tenant_id` or `MC_TENANT_ID`), if the sink
  needs one, and the project id (`cfg.telemetry.project_id` or `MC_PROJECT_ID`)
  when the token is project-bound.

## Settings snippet

The entries `{{HOME_TOOL_DIR}}/settings.json` needs (merged, never replacing existing
hooks):

```json
{
  "hooks": {
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "$HOME/.concertmaster/bin/mc-worker-hook.sh", "timeout": 10 } ] } ],
    "Stop":         [ { "hooks": [ { "type": "command", "command": "$HOME/.concertmaster/bin/mc-worker-hook.sh", "timeout": 10 } ] } ],
    "Notification": [ { "hooks": [ { "type": "command", "command": "$HOME/.concertmaster/bin/mc-worker-hook.sh", "timeout": 10 } ] } ]
  }
}
```

(Use your `cfg.state_dir` in place of `$HOME/.concertmaster` if it differs.)

Idempotent merge (backs up first, appends once, keeps every other hook):

```bash
S={{HOME_TOOL_DIR}}/settings.json
cp "$S" "$S.bak.$(date +%Y%m%d%H%M%S)"
jq --arg cmd '$HOME/.concertmaster/bin/mc-worker-hook.sh' '
  .hooks = (.hooks // {})
  | reduce ("SessionStart", "Stop", "Notification") as $e (.;
      .hooks[$e] = (
        ((.hooks[$e] // []) | map(select(([.hooks[]?.command] | index($cmd)) | not)))
        + [ { "hooks": [ { "type": "command", "command": $cmd, "timeout": 10 } ] } ]))
' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
```

## Common install steps (run ON the host)

```bash
SRC=<project checkout on main>/.agents/skills/concertmaster
mkdir -p ~/.concertmaster/bin && chmod 700 ~/.concertmaster
cp "$SRC/scripts/lib.sh" "$SRC/scripts/mc-emit.sh" "$SRC/scripts/hooks/mc-worker-hook.sh" ~/.concertmaster/bin/
cp "$SRC/config.yaml" ~/.concertmaster/config.yaml   # lib.sh finds it as $CM_HOME/config.yaml
chmod 755 ~/.concertmaster/bin/*.sh
mkdir -p ~/.secrets && chmod 700 ~/.secrets          # token copied in separately, mode 600
grep -m1 '^MC_EMIT_VERSION=' ~/.concertmaster/bin/mc-emit.sh   # must be 3 or later; works on any copy
# (never run `--version` on an unknown copy: a v1 copy takes it as an event type and flushes)
# optional overrides, parsed (never sourced) by mc-emit.sh; a placeholder value is ignored:
#   printf 'MC_TENANT_ID=%s\nMC_BASE_URL=%s\nMC_PROJECT_ID=%s\n' "$TENANT_ID" "$BASE_URL" "$PROJECT_ID" > ~/.concertmaster/mc.env && chmod 600 ~/.concertmaster/mc.env
# then the settings merge above
```

Copying (not symlinking) keeps hooks working while the checkout switches
branches. Re-copy after the skill's scripts or config change on `main`, on every host:
the copies share `~/.concertmaster/outbox.jsonl`, and a copy older than
`MC_EMIT_VERSION` 2 POSTs `tenantId: null` and dead-letters lines a newer copy
kept (recover them with `mc-emit.sh --requeue-dead` once the tenant is set); one
older than 3 never sends a projectId, so a project-bound token answers 400 to
every event it flushes (same recovery once the project id is set: plain
`--requeue-dead` then takes those lines too, although that copy filled their tenant in).
`scripts/sync-from-toolkit.sh` does the copy for the skill tree; the installed
`~/.concertmaster/bin` copy is a separate `cp`.

## Per host

Fill one row per Orca host (`orca host list`) in the project's copy:

| host | how to get a shell | checkout to copy from | notes |
|---|---|---|---|
| `<home host>` | the concertmaster's own Orca terminal | `<path>` | |
| `<remote host>` | `ssh <host>` or an Orca terminal on it | `<path>` | copy the token with `scp -p`, then `chmod 600` |

On hosts whose checkouts sit idle, `git -C <checkout> pull --ff-only` first.

## Verify on each host (no real traffic needed for the filter)

```bash
H=~/.concertmaster/bin/mc-worker-hook.sh
# 1. repo outside the org: nothing queued
printf '{"hook_event_name":"Stop","cwd":"%s","session_id":"t1"}' "$HOME" | "$H"; sleep 2
wc -l ~/.concertmaster/outbox.jsonl 2>/dev/null || echo "no outbox: correct"
# 2. org repo: two lines, flushed on 2xx
printf '{"hook_event_name":"SessionStart","cwd":"%s","session_id":"t2","source":"startup"}' \
  <project checkout> | "$H"; sleep 6
wc -l ~/.concertmaster/outbox.jsonl 2>/dev/null || echo "outbox empty: both lines accepted"
```

A line still queued after step 2 means the sink refused it (or no base URL is
set): read it with `tail -1 ~/.concertmaster/outbox.jsonl`, and
`~/.concertmaster/bin/mc-emit.sh --flush` prints the HTTP code on stderr.

## Rollback

```bash
S={{HOME_TOOL_DIR}}/settings.json
cp "$S" "$S.bak.$(date +%Y%m%d%H%M%S)"
jq --arg cmd '$HOME/.concertmaster/bin/mc-worker-hook.sh' '
  .hooks |= with_entries(.value |= map(select(([.hooks[]?.command] | index($cmd)) | not)))
' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
```

Queued lines in `~/.concertmaster/outbox.jsonl` are harmless and can be left or
deleted.
