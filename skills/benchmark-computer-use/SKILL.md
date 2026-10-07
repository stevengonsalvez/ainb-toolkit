---
name: benchmark-computer-use
description: Benchmark, record, and compare computer use speed across AI models and tool stacks (Peekaboo, Cua-Driver, Cua+JEV, GitHub Copilot) playing desktop apps on macOS with zero blank wallpaper.
---

# Computer Use Benchmark Skill

Benchmark and visually compare computer use speed across AI models and tool stacks playing desktop macOS applications.

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│  Target Game    │────▶│  Perception +    │────▶│  Video Stitched      │
│  (macOS 2048)   │     │  Action Harness  │     │  Side-by-Side MP4    │
└─────────────────┘     └──────────────────┘     └──────────────────────┘
         ▲                       ▲                          ▲
         │                       │                          │
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│  Pluggable Arms │     │  Zero Wallpaper  │     │  Latency Telemetry   │
│  JEV / Cua /    │     │  ScreenCaptureKit│     │  Perc / Model / Act  │
│  Peekaboo /     │     │  Window State    │     │  BENCHMARK_REPORT.md │
│  Copilot Native │     │                  │     │                      │
└─────────────────┘     └──────────────────┘     └──────────────────────┘
```

## Supported Benchmark Arms

| Arm ID | Decision Engine | Perception / Action Stack | Primary Focus |
| :--- | :--- | :--- | :--- |
| `peekaboo` | Gemini 2.5 Flash | Cua Window State + Peekaboo CLI (`/usr/local/bin/peekaboo press`) | Fast CLI keypress baseline |
| `cuadriver` | Gemini 2.5 Flash | Cua Window State + CuaDriver MCP (`press_key`) | Full Accessibility tree / MCP |
| `cua_jev` | TypeSafe JEV System-One | Cua Window State + CuaDriver MCP (`press_key`) | Ultra-low latency decision loop (<250ms) |
| `copilot` | GitHub Copilot / Models API | Cua Window State + CuaDriver MCP / Native Key | Copilot latency and native computer use |

---

## Quick Start: Single Command Execution

Run all three standard arms for 30 moves:

```bash
cd skills/benchmark-computer-use
./scripts/run.sh
```

Run specific arms with custom move counts:

```bash
# Compare Copilot against JEV and CuaDriver for 20 moves
./scripts/run.sh --arms copilot,cua_jev,cuadriver --moves 20

# Run single arm benchmark
./scripts/run.sh --arms copilot --moves 30 --out-dir ./benchmark-results
```

Run and automatically transfer results to another Mac:

```bash
./scripts/run.sh --arms peekaboo,cuadriver,cua_jev \
  --moves 30 \
  --transfer stevengonsalvez@100.98.203.32:~/Downloads/benchmark-computer-use/ \
  --ssh-key ~/.ssh/mb412_agent
```

---

## GitHub Copilot Integration Guide

When using GitHub Copilot to execute or participate in the benchmark:

### 1. Copilot as Test Orchestrator
GitHub Copilot can run the benchmark suite autonomously:
1. Run preflight verification:
   ```bash
   bash scripts/preflight.sh
   ```
2. Launch benchmark run:
   ```bash
   bash scripts/run.sh --arms copilot,cua_jev,cuadriver --moves 30
   ```
3. Read final summary report:
   ```bash
   cat benchmark-results/BENCHMARK_REPORT.md
   ```

### 2. Copilot as a Benchmark Subject Arm
When `--arms copilot` is included, the runner queries GitHub Models API (`https://models.inference.ai.azure.com`) using the local `gh auth token` or `GITHUB_TOKEN`.
- Measures Copilot model decision latency per turn.
- Measures action latency via CuaDriver keystroke injection.
- Generates `annotated_copilot/` frames with burned latency metrics.

---

## Key Guarantees and Architecture

### 1. Zero Blank Wallpaper Guarantee
macOS Sequoia blocks background shells from capturing screens via `/usr/sbin/screencapture`, returning empty desktop wallpapers.
This skill avoids that failure mode:
- Direct capture via `CuaDriver.app` MCP `get_window_state(screenshot_out_file: ...)`.
- Automated pixel validation in `process_and_stitch.py` (`validate_frame`) rejecting flat wallpaper captures.

### 2. Isolated Window Positioning
- Target window positioned automatically at `(x: 40, y: 40, width: 520, height: 750)`.
- Avoids macOS center-screen TCC authorization dialogs (`CoreServicesUIAgent`).

### 3. Alternating Axis Move Policy
- Avoids directional lockups (e.g. repeated "Down" moves when tiles are anchored).
- Alternates axes: Down/Left on odd turns, Right/Down on even turns.

---

## Generated Artifacts

Outputs are saved in `--out-dir` (default: `./benchmark-results`):

- `benchmark_side_by_side.mp4`: Synchronized side-by-side composite video (H.264, 480x720 per pane).
- `arm_<name>.mp4`: Individual video for each tested arm.
- `BENCHMARK_REPORT.md`: Markdown summary table with Perception, Model, Action, and Total latencies plus relative speedup.
- `<arm>_trace.jsonl`: Millisecond-level telemetry trace for every single move.
- `frames_<arm>/`: Raw PNG frame captures for each move.
- `annotated_<arm>/`: Frames with burned title and latency banners.

---

## References

- Troubleshooting and edge cases: [troubleshooting.md](references/troubleshooting.md)
- Game host source: [main.swift](assets/game-2048/main.swift)
- Runner implementation: [runner.ts](scripts/runner.ts)
