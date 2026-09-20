# Antigravity Statusline

Custom statusline script for Google Antigravity CLI (`agy`), designed for visual and functional parity with Claude Code statusline in `ainb-toolkit`.

## Features

- **Line 1 (Powerline - Nerd Font glyphs)**:
  - Adaptive CWD (shortens automatically on narrow terminals)
  - Git branch, ahead/behind counters (`↑X↓Y`), and change counters (`±N ?N`)
  - Reflect KB un-acked error counter (`⚠N /reflect:errors-ack`)
  - Beads ready counter (`bd:N▸`)
  - Caveman mode active state and token savings (`🪨 ⛏ 2.3M`)
  - Vim mode indicator (`NORMAL` / `INSERT`) if vim mode enabled

- **Line 2 (ANSI detail line)**:
  - Model short name (`gemini-3.8-flash`, `gemini-3.1-pro`, `sonnet-4.6`, etc.)
  - Planning mode (`mode plan`) and reasoning effort badge (`eff high`, `eff med`, `⚡` for fast mode)
  - Session health turn counter (`🟢 1/50`, `🟡`, `🔴`) parsed directly from conversation transcript
  - Context window usage bar (`ctx [██░░░░] 14%`)
  - Quota / rate limit progress bar (`wk [░░░░░░] 6% ↻ Sep 27 09:00`)
  - Plan tier (`Pro`) or session cost
  - Active background task counter (`tasks:N`)
  - Artifacts counter (`art:N`)
  - Sandbox status (`🔒sb`)
  - Headroom proxy pill (`HR`) and RTK token killer pill (`RTK`)

- **Line 3+ (Reflect timeline)**:
  - Reflect token timeline dashboard if the reflect plugin helper is installed.

## Installation

1. Link or copy the script to `~/.gemini/antigravity-cli/statusline.sh`:
   ```bash
   mkdir -p ~/.gemini/antigravity-cli
   ln -sf "$(pwd)/antigravity/statusline.sh" ~/.gemini/antigravity-cli/statusline.sh
   chmod +x ~/.gemini/antigravity-cli/statusline.sh
   ```

2. Enable in `~/.gemini/antigravity-cli/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.gemini/antigravity-cli/statusline.sh",
       "padding": 0
     }
   }
   ```

## Testing

Run the test suite:
```bash
./antigravity/test_statusline.sh
```
