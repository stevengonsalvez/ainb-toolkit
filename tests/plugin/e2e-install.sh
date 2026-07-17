#!/usr/bin/env bash
# Sandbox-HOME end-to-end: install the godmode plugin from this repo's
# marketplace into a throwaway HOME, then drive the INSTALLED hook scripts
# with fixture events (proves ${CLAUDE_PLUGIN_ROOT}-relative pathing survives
# install). Real ~/.claude is never touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FX="$REPO_ROOT/tests/plugin/fixtures"

command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB"

echo "== marketplace add (directory source) =="
claude plugin marketplace add "$REPO_ROOT" || { echo "SKIP: marketplace add failed headless"; exit 0; }
echo "== plugin install =="
claude plugin install godmode@ainb-toolkit || { echo "SKIP: plugin install failed headless"; exit 0; }

echo "== locate install =="
INSTALL="$(find "$SB/.claude/plugins" -type f -name 'hooks.json' -path '*godmode*' | head -1)"
[ -n "$INSTALL" ] || { echo "FAIL: installed hooks.json not found"; exit 1; }
PLUGIN_DIR="$(dirname "$(dirname "$INSTALL")")"
echo "installed at: $PLUGIN_DIR"
[ -f "$PLUGIN_DIR/skills/godmode/SKILL.md" ] || { echo "FAIL: skill missing in install"; exit 1; }
[ -x "$PLUGIN_DIR/scripts/explainer-gate.sh" ] || chmod +x "$PLUGIN_DIR/scripts/"*.sh || true

echo "== drive installed hooks with fixtures =="
W="$(mktemp -d)"; cd "$W"
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
echo x > f && git add f && git commit -qm init
mkdir -p .agents/scratch .agents/goals .beads explainers
cp "$FX/state-ship-complete.json" .agents/scratch/godmode-test-slug-state.json
cp "$FX/issues.jsonl" .beads/issues.jsonl
cp "$FX/charter.md" .agents/goals/godmode-test-slug-charter.md

# 1. gate blocks driver from the INSTALLED location
# NOTE: `jq -e` returns 0 on EMPTY input, so asserting on it alone would pass
# against a deleted gate. -n + -s (slurp) makes empty fail.
OUT="$(jq --arg c "$W" '. + {cwd:$c}' "$FX/stop-event.json" | "$PLUGIN_DIR/scripts/explainer-gate.sh")"
[ -n "$OUT" ] || { echo "FAIL: installed gate produced no output"; exit 1; }
echo "$OUT" | jq -se '.[0].decision == "block"' >/dev/null || { echo "FAIL: installed gate did not block"; exit 1; }
echo "PASS: installed gate blocks"

# 2. on-state-write renders + stub-publishes from the INSTALLED location
EV="$(jq -n --arg fp "$W/.agents/scratch/godmode-test-slug-state.json" \
  '{session_id:"sess-driver-1",tool_name:"Write",tool_input:{file_path:$fp}}')"
echo "$EV" | GODMODE_PUBLISH_CMD=/usr/bin/true GODMODE_SYNC=local "$PLUGIN_DIR/scripts/on-state-write.sh"
[ -f explainers/godmode-test-slug.html ] || { echo "FAIL: installed pipeline did not render"; exit 1; }
grep -qE '\{\{[A-Z_]+\}\}' explainers/godmode-test-slug.html && { echo "FAIL: tokens left"; exit 1; }
echo "PASS: installed pipeline renders"

# 3. no-op inertness from installed location
T0=$(date +%s)
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"}}' | "$PLUGIN_DIR/scripts/on-state-write.sh"
T1=$(date +%s)
[ $((T1 - T0)) -le 1 ] || { echo "FAIL: no-op too slow"; exit 1; }
echo "PASS: inert fast path"

echo "E2E: all green"
