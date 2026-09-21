#!/usr/bin/env bash
# Test suite for antigravity/statusline.sh

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPT="${DIR}/statusline.sh"

echo "=== Test 1: Full Antigravity Payload (Gemini 3.8 Flash + Quota + Tasks) ==="
cat << 'EOF' | bash "$SCRIPT"
{
  "cwd": "/Users/stevengonsalvez/orca/workspaces/ainb-toolkit/antigravity-statusline",
  "conversation_id": "210d73e5-f632-4891-8b7d-cb70acf4def6",
  "session_id": "210d73e5-f632-4891-8b7d-cb70acf4def6",
  "transcript_path": "/Users/stevengonsalvez/.gemini/antigravity-cli/brain/210d73e5-f632-4891-8b7d-cb70acf4def6/.system_generated/logs/transcript.jsonl",
  "model": {
    "id": "Gemini 3.8 Flash (High)",
    "display_name": "Gemini 3.8 Flash (High)"
  },
  "workspace": {
    "current_dir": "/Users/stevengonsalvez/orca/workspaces/ainb-toolkit/antigravity-statusline",
    "project_dir": "/Users/stevengonsalvez/orca/workspaces/ainb-toolkit/antigravity-statusline"
  },
  "version": "1.0.13",
  "context_window": {
    "total_input_tokens": 88244,
    "total_output_tokens": 61074,
    "context_window_size": 1048576,
    "used_percentage": 14.24,
    "remaining_percentage": 85.76,
    "current_usage": {
      "input_tokens": 63382,
      "output_tokens": 346,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 20857
    }
  },
  "exceeds_200k_tokens": false,
  "product": "antigravity",
  "quota": {
    "gemini-5h": {
      "remaining_fraction": 0.96,
      "reset_time": "2026-07-06T07:50:32Z",
      "reset_in_seconds": 18000
    },
    "gemini-weekly": {
      "remaining_fraction": 0.9378,
      "reset_time": "2026-07-06T07:50:32Z",
      "reset_in_seconds": 560580
    }
  },
  "agent_state": "idle",
  "vcs": {
    "type": "git",
    "branch": "stevengonsalvez/antigravity-statusline",
    "dirty": false
  },
  "sandbox": {
    "enabled": false
  },
  "artifact_count": 2,
  "plan_tier": "Pro",
  "email": "stevengonsalvez@example.com",
  "task_count": 1,
  "terminal_width": 120,
  "execution_mode": "planning"
}
EOF

echo ""
echo "=== Test 1b: Full AGY 4-Bucket Quota (3p + gemini) ==="
cat << 'EOF' | bash "$SCRIPT"
{
  "cwd": "/Users/stevengonsalvez/orca/workspaces/ainb-toolkit/toolkit-intel",
  "model": {
    "id": "Gemini 3.8 Flash (High)",
    "display_name": "Gemini 3.8 Flash (High)"
  },
  "quota": {
    "3p-5h": { "remaining_fraction": 1.0, "reset_in_seconds": 17698 },
    "3p-weekly": { "remaining_fraction": 1.0, "reset_in_seconds": 604498 },
    "gemini-5h": { "remaining_fraction": 0.96, "reset_in_seconds": 17698 },
    "gemini-weekly": { "remaining_fraction": 0.57, "reset_in_seconds": 305688 }
  },
  "plan_tier": "Google AI Pro",
  "email": "lazymonkkmann@gmail.com"
}
EOF

echo ""
echo "=== Test 2: Claude Code Payload Compatibility ==="
cat << 'EOF' | bash "$SCRIPT"
{
  "cwd": "/Users/stevengonsalvez/orca/workspaces/ainb-toolkit/antigravity-statusline",
  "model": {
    "id": "claude-sonnet-4.6",
    "display_name": "Claude Sonnet 4.6"
  },
  "effort": {
    "level": "medium"
  },
  "fast_mode": true,
  "rate_limits": {
    "seven_day": {
      "used_percentage": 35.0,
      "resets_at": 1789000000
    }
  },
  "context_window": {
    "used_percentage": 42.0
  }
}
EOF

echo ""
echo "=== Test 3: Minimal Payload ==="
cat << 'EOF' | bash "$SCRIPT"
{
  "cwd": "/tmp"
}
EOF

echo ""
echo "=== Tests completed successfully ==="
