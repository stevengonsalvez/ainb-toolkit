#!/usr/bin/env python3
"""
Bash Auto-Background Hook (PreToolUse:Bash)

Sets run_in_background=true on commands that are known to be slow, so the
agent never blocks in the foreground and nobody has to hit Ctrl+B twice.
The harness re-invokes the agent when the command exits.

Contract: PreToolUse hooks may return
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": {...}}}
updatedInput is validated against the tool schema; a bad shape is ignored and
the original input is used.
"""

import json
import re
import sys

# ponytail: flat allowlist, not a classifier. Add a line when something new
# turns out to be slow. Anything unmatched stays foreground on purpose.
LONG_RUNNING = re.compile(
    r"""
      \b(pytest|vitest|jest|mocha)\b
    | \bnpm\ (run\ )?(test|build)\b
    | \b(pnpm|yarn|bun)\ (run\ )?(test|build)\b
    | \bplaywright\ test\b
    | \bcargo\ (test|build|clippy)\b
    | \bgo\ (test|build)\b
    | \b(xcodebuild|gradlew?|mvn)\b
    | \bdocker\ (build|compose\ up)\b
    | \bterraform\ (plan|apply)\b
    | \bgh\ (run\ watch|pr\ checks)\b
    | \b(npm|pnpm|yarn|bun|pip|pip3|uv|brew|cargo)\ install\b
    | \bwhile\ true\b
    | ^\s*until\b | ;\s*until\b | &&\s*until\b
    | \bsleep\ \d{2,}\b
    """,
    re.IGNORECASE | re.VERBOSE,
)

# Never background these even if a pattern above matches: the agent needs the
# output in the same turn, or the command wants a terminal.
NEVER = re.compile(r"\b(tmux|git\s+rebase\s+-i|--watch\b|-w\b.*--interactive)\b", re.IGNORECASE)


def main() -> None:
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return

    if data.get("tool_name") != "Bash":
        return

    tool_input = data.get("tool_input") or {}
    command = tool_input.get("command", "")

    if not command or tool_input.get("run_in_background"):
        return
    if NEVER.search(command) or not LONG_RUNNING.search(command):
        return

    updated = dict(tool_input)
    updated["run_in_background"] = True
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "updatedInput": updated,
            },
            "systemMessage": "[hook] backgrounded long-running command",
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
