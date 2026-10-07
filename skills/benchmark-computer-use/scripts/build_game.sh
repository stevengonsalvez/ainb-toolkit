#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${SKILL_ROOT}/assets/game-2048"

TARGET_BIN="${ASSETS_DIR}/2048-app"
SWIFT_SRC="${ASSETS_DIR}/main.swift"
HTML_SRC="${ASSETS_DIR}/index.html"
APP_BUNDLE="${ASSETS_DIR}/2048 Benchmark Game.app"

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

# 3. Compile standalone Mach-O binary if needed
if ! command -v swiftc >/dev/null 2>&1; then
  echo "[setup_game] Error: swiftc not found in PATH. Install Xcode Command Line Tools to compile native Cocoa host." >&2
  exit 1
fi

echo "[setup_game] Compiling Cocoa WebKit binary: ${SWIFT_SRC} -> ${TARGET_BIN}"
swiftc -O "${SWIFT_SRC}" -o "${TARGET_BIN}"
chmod +x "${TARGET_BIN}"

# 4. Construct first-class macOS .app bundle for accessibility/list_apps
echo "[setup_game] Packaging native bundle: ${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${TARGET_BIN}" "${APP_BUNDLE}/Contents/MacOS/2048-app"
cp "${HTML_SRC}" "${APP_BUNDLE}/Contents/Resources/index.html"

cat << 'EOF' > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>2048-app</string>
    <key>CFBundleIdentifier</key>
    <string>com.ainb.benchmark2048</string>
    <key>CFBundleName</key>
    <string>2048 Benchmark Game</string>
    <key>CFBundleDisplayName</key>
    <string>2048 Benchmark Game</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Register with macOS LaunchServices
if [[ -d "${HOME}/Applications" ]]; then
  ln -sfn "${APP_BUNDLE}" "${HOME}/Applications/2048 Benchmark Game.app" 2>/dev/null || true
fi

echo "[setup_game] Successfully packaged ${APP_BUNDLE}"
