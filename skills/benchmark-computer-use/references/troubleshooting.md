# Computer Use Benchmark: Troubleshooting and Edge Cases

## 1. Empty Wallpaper / Blank Capture Bug (macOS Sequoia)

### Symptom
Captured frames show only the macOS wallpaper background, with no window contents, even though the application is visible on screen.

### Root Cause
Under macOS Sequoia (15.x), non-interactive subshells and CLI child processes spawned by background workers lack the direct `TCC: kTCCServiceScreenCapture` permission entitlement. Calling `/usr/sbin/screencapture` returns empty desktop wallpaper bytes.

### Solution
Always use `CuaDriver.app` MCP tool `get_window_state` with argument `screenshot_out_file: "/path/to/frame.png"`. Because `CuaDriver.app` is an installed macOS application bundle with verified Screen Recording and Accessibility permissions, ScreenCaptureKit renders real window pixels.

---

## 2. macOS System Modal Dialogs (TCC and ScreenCaptureKit)

### Symptom
Simulated mouse clicks or keyboard events fail to dismiss permission dialogs or click buttons.

### Root Cause
macOS kernel blocks synthetic CoreGraphics and Accessibility events targeting system dialogs (`CoreServicesUIAgent` or system authorization sheets) to protect against UI spoofing.

### Solution
Position the target application window at `(x: 40, y: 40, width: 520, height: 750)`. macOS system dialogs center themselves on screen (`x: ~700, y: ~450`), keeping the target window and its buttons ("New Game", tiles) completely outside the collision zone.

---

## 3. Directional Stalling in 2048

### Symptom
Model chooses "Down" 30 times in a row, score stops increasing after move 4 because tiles cannot slide further down.

### Root Cause
Without axis rotation heuristics, greedy prompts anchor tiles at the bottom wall and produce no-op actions.

### Solution
Alternate candidate move options across turns:
- Odd steps: Choose between `Down` and `Left`
- Even steps: Choose between `Right` and `Down`

This packs tiles toward the bottom-right corner while forcing horizontal and vertical merges on alternating frames.

---

## 4. FFmpeg drawtext / libfreetype Filter Missing

### Symptom
`ffmpeg -vf "drawtext=..."` fails with error: `No such filter: 'drawtext'`.

### Root Cause
Default Homebrew or macOS builds of FFmpeg often omit `libfreetype` and fontconfig dependencies.

### Solution
Use `process_and_stitch.py` which annotates frames using Python's Pillow library (`PIL.ImageDraw`), then invokes FFmpeg only for scaling, `hstack`, and `libx264` encoding.
