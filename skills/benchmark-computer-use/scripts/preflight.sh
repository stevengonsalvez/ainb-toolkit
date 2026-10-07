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
echo "3. Desktop 2048 Game Target:"
GAME_BIN="${SKILL_ROOT}/assets/game-2048/2048-app"
if [[ -x "$GAME_BIN" ]]; then
  printf "  [OK] %-15s : compiled binary ready\n" "2048-app"
else
  echo "  [WARN] 2048-app binary not found, running build_game.sh..."
  bash "${SCRIPT_DIR}/build_game.sh"
fi

# 4. Check API Keys / Auth
echo ""
echo "4. Model & Platform Credentials:"

# Gemini
GEMINI_KEY="${GEMINI_API_KEY:-}"
if [[ -n "$GEMINI_KEY" ]]; then
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_KEY}" -H "Content-Type: application/json" -d '{"contents":[{"parts":[{"text":"ping"}]}]}' || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    printf "  [OK] %-15s : HTTP %s (valid)\n" "Gemini API" "$STATUS"
  else
    printf "  [WARN] %-13s : HTTP %s\n" "Gemini API" "$STATUS"
  fi
else
  printf "  [WARN] %-13s : GEMINI_API_KEY not set in environment\n" "Gemini API"
fi

# Typesafe JEV
JEV_KEY="${TYPESAFE_API_KEY:-}"
if [[ -n "$JEV_KEY" ]]; then
  if (cd "${SKILL_ROOT}" && node -e '
import("@typesafe-ai/sdk").then(async ({ TypeSafeClient, choice }) => {
  const c = new TypeSafeClient({ apiKey: process.env.TYPESAFE_API_KEY || "'"${JEV_KEY}"'", baseURL: "https://api.typesafe.ai" });
  await c.systemOne({ model: "jev-latest", state: {}, questions: { q: choice("ping", { a: "1", b: "2" }) } });
  process.exit(0);
}).catch(() => process.exit(1));
') >/dev/null 2>&1; then
    printf "  [OK] %-15s : authenticated (System-One ready)\n" "TypeSafe JEV"
  else
    printf "  [WARN] %-13s : authentication failed\n" "TypeSafe JEV"
  fi
else
  printf "  [WARN] %-13s : TYPESAFE_API_KEY not set in environment\n" "TypeSafe JEV"
fi

# GitHub Copilot / gh CLI
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    printf "  [OK] %-15s : authenticated via gh cli\n" "GitHub Copilot"
  else
    printf "  [INFO] %-13s : gh cli installed but not logged in\n" "GitHub Copilot"
  fi
else
  printf "  [INFO] %-13s : gh cli not found\n" "GitHub Copilot"
fi

echo "=========================================================="
if [[ $ERRORS -eq 0 ]]; then
  echo " PREFLIGHT PASSED: All requirements satisfied."
  echo "=========================================================="
  exit 0
else
  echo " PREFLIGHT FAILED: $ERRORS critical dependency issue(s)."
  echo "=========================================================="
  exit 1
fi
