#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=========================================================="
echo " PREFLIGHT: Computer Use Benchmark Environment Check"
echo "=========================================================="

ERRORS=0

# 1. Check binaries
check_cmd() {
  local cmd="$1"
  local desc="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  [OK] %-15s : found (%s)\n" "$cmd" "$desc"
  else
    printf "  [FAIL] %-13s : MISSING (%s)\n" "$cmd" "$desc"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "1. Core CLI Dependencies:"
check_cmd "node" "Node.js runtime"
check_cmd "npm" "Node package manager"
check_cmd "python3" "Python 3 runtime"
check_cmd "ffmpeg" "Video encoding / hstack"
check_cmd "swiftc" "Swift compiler for native Cocoa host"

# Check PIL
if python3 -c "import PIL" >/dev/null 2>&1; then
  printf "  [OK] %-15s : found (Pillow image processing)\n" "python3-PIL"
else
  printf "  [FAIL] %-13s : MISSING (run: pip3 install pillow)\n" "python3-PIL"
  ERRORS=$((ERRORS + 1))
fi

# 2. Check CuaDriver App
echo ""
echo "2. CuaDriver Native Driver:"
CUA_APP="/Applications/CuaDriver.app"
CUA_BIN="/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
if [[ -d "$CUA_APP" && -x "$CUA_BIN" ]]; then
  printf "  [OK] %-15s : installed at %s\n" "CuaDriver" "$CUA_APP"
else
  printf "  [FAIL] %-13s : not found at %s\n" "CuaDriver" "$CUA_APP"
  ERRORS=$((ERRORS + 1))
fi

# 3. Check Game App
echo ""
echo "3. Desktop Game Target (2048 macOS Cocoa App):"
GAME_BIN="${SKILL_ROOT}/assets/game-2048/2048-app"
HTML_SRC="${SKILL_ROOT}/assets/game-2048/index.html"
SWIFT_SRC="${SKILL_ROOT}/assets/game-2048/main.swift"

if [[ ! -f "$HTML_SRC" || ! -f "$SWIFT_SRC" || ! -x "$GAME_BIN" ]]; then
  echo "  [INFO] Target game asset(s) missing or uncompiled. Running auto-download & build..."
  bash "${SCRIPT_DIR}/build_game.sh"
fi

if [[ -x "$GAME_BIN" && -f "$HTML_SRC" ]]; then
  printf "  [OK] %-15s : 2048 macOS Desktop Game ready (%s)\n" "Game Target" "$GAME_BIN"
else
  printf "  [FAIL] %-13s : failed to build or download 2048 app\n" "Game Target"
  ERRORS=$((ERRORS + 1))
fi

# 4. Computer Use Tool Drivers & Agent Context
echo ""
echo "4. Computer Use Tool Drivers & Agent Context:"
printf "  [INFO] %-13s : moves come from the built-in policy; MOVE_POLICY=agent uses agy (gemini-3.8-flash-low)\n" "Move policy"

# Peekaboo CLI
if command -v peekaboo >/dev/null 2>&1; then
  printf "  [OK] %-15s : installed at %s\n" "Peekaboo CLI" "$(which peekaboo)"
else
  printf "  [INFO] %-13s : not installed (fallback to native macOS events)\n" "Peekaboo CLI"
fi

# Typesafe JEV (optional fast-path)
JEV_KEY="${TYPESAFE_API_KEY:-}"
if [[ -z "$JEV_KEY" && -f ~/.secrets/bw-master ]]; then
  # Password by file and session by env: neither belongs on argv, where ps exposes it.
  BW_S=$(bw unlock --passwordfile ~/.secrets/bw-master --raw 2>/dev/null || true)
  if [[ -n "$BW_S" ]]; then
    JEV_KEY=$(BW_SESSION="$BW_S" bw get item "TYPESAFE_API_KEY" 2>/dev/null | jq -r '.fields[] | select(.name=="KEY") | .value' 2>/dev/null || true)
  fi
fi
if [[ -n "$JEV_KEY" ]]; then
  if (cd "${SKILL_ROOT}" && node -e '
import("@typesafe-ai/sdk").then(async ({ TypeSafeClient, choice }) => {
  const c = new TypeSafeClient({ apiKey: process.env.TYPESAFE_API_KEY, baseURL: "https://api.typesafe.ai" });
  await c.systemOne({ model: "jev-latest", state: {}, questions: { q: choice("ping", { a: "1", b: "2" }) } });
  process.exit(0);
}).catch(() => process.exit(1));
') >/dev/null 2>&1; then
    printf "  [OK] %-15s : authenticated (System-One fast-path ready)\n" "TypeSafe JEV"
  else
    printf "  [INFO] %-13s : authentication failed (skips JEV arm)\n" "TypeSafe JEV"
  fi
else
  printf "  [INFO] %-13s : TYPESAFE_API_KEY not set (optional fast-path)\n" "TypeSafe JEV"
fi

# GitHub CLI only; this does not authenticate native Copilot computer use.
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    printf "  [OK] %-15s : authenticated via gh cli\n" "GitHub CLI"
  else
    printf "  [INFO] %-13s : gh cli installed but not logged in\n" "GitHub CLI"
  fi
else
  printf "  [INFO] %-13s : gh cli not found\n" "GitHub CLI"
fi

echo "=========================================================="
if [[ $ERRORS -eq 0 ]]; then
  echo " STATIC PREFLIGHT PASSED: Verify live permissions, capture, and one move per arm."
  echo "=========================================================="
  exit 0
else
  echo " PREFLIGHT FAILED: $ERRORS critical dependency issue(s)."
  echo "=========================================================="
  exit 1
fi
