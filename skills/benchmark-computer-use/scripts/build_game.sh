#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${SKILL_ROOT}/assets/game-2048"

TARGET_BIN="${ASSETS_DIR}/2048-app"
SWIFT_SRC="${ASSETS_DIR}/main.swift"
HTML_SRC="${ASSETS_DIR}/index.html"

mkdir -p "${ASSETS_DIR}"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/stevengonsalvez/ainb-toolkit/main/skills/benchmark-computer-use/assets/game-2048"

# 1. Download HTML game if missing
if [[ ! -f "${HTML_SRC}" ]]; then
  echo "[setup_game] HTML asset missing. Downloading from upstream repository..."
  curl -fsSL "${GITHUB_RAW_BASE}/index.html" -o "${HTML_SRC}" || {
    echo "[setup_game] Error: Failed to download index.html" >&2
    exit 1
  }
  echo "[setup_game] Downloaded: ${HTML_SRC}"
fi

# 2. Download Swift host source if missing
if [[ ! -f "${SWIFT_SRC}" ]]; then
  echo "[setup_game] Swift source missing. Downloading from upstream repository..."
  curl -fsSL "${GITHUB_RAW_BASE}/main.swift" -o "${SWIFT_SRC}" || {
    echo "[setup_game] Error: Failed to download main.swift" >&2
    exit 1
  }
  echo "[setup_game] Downloaded: ${SWIFT_SRC}"
fi

# 3. Check / compile Cocoa WebKit binary
if [[ -f "${TARGET_BIN}" && -x "${TARGET_BIN}" ]]; then
  echo "[setup_game] 2048-app binary ready: ${TARGET_BIN}"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "[setup_game] Error: swiftc not found in PATH. Install Xcode Command Line Tools to compile native Cocoa host." >&2
  exit 1
fi

echo "[setup_game] Compiling Cocoa WebKit host: ${SWIFT_SRC} -> ${TARGET_BIN}"
swiftc -O "${SWIFT_SRC}" -o "${TARGET_BIN}"
chmod +x "${TARGET_BIN}"
echo "[setup_game] Successfully built ${TARGET_BIN}"
