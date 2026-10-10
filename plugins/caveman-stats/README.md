# caveman-stats

Caveman mode lifecycle hooks for Claude Code.

## Overview

`caveman-stats` tracks estimated token savings in caveman mode and ensures caveman mode instructions survive context compaction.

- **`PostToolUse`**: Silently updates `.caveman-statusline-suffix` on each tool use. Uses a watermark to read only new JSONL lines from session history.
- **`PreCompact`**: Synchronously re-injects the caveman ruleset into the compaction summary so caveman mode remains active after context compaction.

## Installation

```bash
claude plugin marketplace add stevengonsalvez/ainb-toolkit
claude plugin install caveman-stats@ainb-toolkit
```

Pair with `caveman@caveman` for full caveman setup.
