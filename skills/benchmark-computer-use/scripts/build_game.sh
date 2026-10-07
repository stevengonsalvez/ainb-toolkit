#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/../assets/game-2048" && pwd)"

TARGET_BIN="${ASSETS_DIR}/2048-app"
SWIFT_SRC="${ASSETS_DIR}/main.swift"

if [[ -f "${TARGET_BIN}" && -x "${TARGET_BIN}" ]]; then
  echo "[build_game] 2048-app already compiled at ${TARGET_BIN}"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "[build_game] Error: swiftc not found in PATH. Install Xcode Command Line Tools." >&2
  exit 1
fi

echo "[build_game] Compiling Cocoa WebKit host: ${SWIFT_SRC} -> ${TARGET_BIN}"
swiftc -O "${SWIFT_SRC}" -o "${TARGET_BIN}"
chmod +x "${TARGET_BIN}"
echo "[build_game] Successfully built ${TARGET_BIN}"
