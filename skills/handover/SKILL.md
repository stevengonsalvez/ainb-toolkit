---
name: handover
description: Generate a handover document for transferring work to another developer or spawning an async agent
user-invocable: true
---

# /handover - Generate Session Handover Document

Snapshot session state (git, todos, next steps) into a markdown file so another human, a resumed session, or a spawned agent can continue without re-deriving context.

## When NOT to use

| Want | Use instead |
|------|-------------|
| Current health / message count only | `/health-check` |
| Narrative recap of work done | `/session-summary` |
| Raw session stats | `/session-metrics` |
| To actually launch the agent now | `/spawn-agent` (it calls this — Step 5) |

## Usage

```bash
/handover                              # Standard (human / resume-later)
/handover "notes about current work"   # Standard + notes appended
/handover --agent-spawn "task desc"    # Agent-spawn (task-focused)
```

## Step 1 — Parse mode, set variables

`{{TOOL_DIR}}` is substituted at deploy time by bootstrap.js to the project-relative tool dir (`.claude`) — NOT `~/.claude` (that is `{{HOME_TOOL_DIR}}`). Leave both tokens literal — never replace by hand. Then route: `standard` → Step 2, `agent` → Step 3.

```bash
MODE="standard"; AGENT_TASK=""; NOTES="${1:-}"
if [[ "$1" == "--agent-spawn" ]]; then MODE="agent"; AGENT_TASK="${2:-}"; NOTES=""; fi
DISPLAY_TIME=$(date +"%Y-%m-%d %H:%M:%S")
FILENAME="handover-$(date +"%Y-%m-%d-%H-%M-%S").md"
PRIMARY_LOCATION="{{TOOL_DIR}}/session/${FILENAME}"; BACKUP_LOCATION="./${FILENAME}"
mkdir -p "{{TOOL_DIR}}/session"
```

## Step 2 — Standard handover content

Build `$CONTENT` from this template. Fill every `[bracketed]` slot from the live session (your todo list, what you were doing) — no brackets may remain. Shell `$(...)` runs at generation time.

```markdown
# Handover Document

**Generated**: ${DISPLAY_TIME}
**Session**: $(tmux display-message -p '#S' 2>/dev/null || echo 'unknown')

## Current Work

[What you're working on — 1-3 sentences]

## Task Progress

[Todo list with status: completed / in-progress / pending]

## Technical Context

**Current Branch**: $(git branch --show-current)
**Last Commit**: $(git log -1 --oneline)
**Modified Files**:
$(git status --short)

## Resumption Instructions

1. Review changes: git diff
2. Continue work on [specific task]
3. Test with: [test command]

## Notes

${NOTES}
```

Cold-handover variant: if a human picks this up days later and needs health status / JIRA ID / phase / progress %, copy `assets/template.md` and fill its `{{...}}` placeholders instead. Then go to Step 4.

## Step 3 — Agent-spawn handover content

Task-focused; omit session-health fields (a spawned agent starts fresh). Fill every `[bracketed]` slot.

```markdown
# Agent Handover - ${AGENT_TASK}

**Generated**: ${DISPLAY_TIME}
**Parent Session**: $(tmux display-message -p '#S' 2>/dev/null || echo 'unknown')
**Agent Task**: ${AGENT_TASK}

## Context Summary

**Current Work**: [What's in progress]
**Current Branch**: $(git branch --show-current)
**Last Commit**: $(git log -1 --oneline)

## Task Details

**Agent Mission**: ${AGENT_TASK}

**Requirements**:
- [Specific requirements / what needs doing]

**Success Criteria**:
- [How to know when done]

## Technical Context

**Stack**: [Technology stack]
**Key Files**:
$(git status --short)

**Modified Recently**:
$(git log --name-only -5 --oneline)

## Instructions for Agent

1. Review current implementation
2. Make specified changes
3. Add/update tests
4. Verify all tests pass
5. Commit with clear message

## References

**Documentation**: [Links to relevant docs]
**Related Work**: [Related PRs/issues]
```

## Step 4 — Write both files

The cwd backup survives if `{{TOOL_DIR}}` is on another volume or gets cleaned.

```bash
# Bind the filled template for the active mode into CONTENT first — printf on an
# unset CONTENT writes empty files.
if [ "$MODE" = "agent" ]; then
    CONTENT="<the filled Step 3 agent-spawn handover content>"
else
    CONTENT="<the filled Step 2 standard handover content>"
fi

printf '%s\n' "$CONTENT" > "$PRIMARY_LOCATION"
printf '%s\n' "$CONTENT" > "$BACKUP_LOCATION"
echo "Handover -> $PRIMARY_LOCATION (backup: $BACKUP_LOCATION)"
```

Gate — expect both files non-empty.
- `git branch --show-current` empty → detached HEAD / not a repo. Leave Branch blank, continue (do NOT abort).
- Write fails / file empty → confirm `{{TOOL_DIR}}/session` exists (Step 1 `mkdir`) and disk is writable, then retry.

**Output location (contract)**: primary `{{TOOL_DIR}}/session/handover-{timestamp}.md`, backup `./handover-{timestamp}.md`.

## Step 5 — Integration with spawn-agent (contract — do not change)

`/spawn-agent ... --with-handover` calls this skill in agent mode and copies the result into the agent worktree as `.agent-handover.md`:

```bash
/spawn-agent codex "refactor auth" --with-handover
# Internally calls: /handover --agent-spawn "refactor auth"
```

Keep the `--agent-spawn "<task>"` argument shape exactly — spawn-agent depends on it.
