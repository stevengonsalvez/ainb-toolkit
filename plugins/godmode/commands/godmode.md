---
description: "Godmode programme factory: init <north-star> | run [--take-over] | status | pause"
---
Invoke the godmode skill with arguments: {{args}}

Provider guard: preflight scheduler and peer-model capability before init/run.
Claude uses its native scheduler. Codex requires native automation. Copilot
requires a configured external scheduler adapter. When capability is missing,
defer the driving lane visibly, print lease + sidecar status, and continue only
safe observer work (use `${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh discover` and
`.../lease.sh check`). Never claim autonomous driving without its scheduler.
