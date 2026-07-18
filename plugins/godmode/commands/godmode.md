---
description: "Godmode programme factory: init <north-star> | run [--take-over] | status | pause"
---
Invoke the godmode skill with arguments: {{args}}

Provider guard: if this host is not Claude Code (no Workflow/ScheduleWakeup tools),
only `status` is permitted; for init/run/pause reply that driving is Claude-only
and print the lease + sidecar status instead (use
`${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh discover` and `.../lease.sh check`).
