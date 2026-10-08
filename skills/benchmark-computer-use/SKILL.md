---
name: benchmark-computer-use
description: Benchmark macOS 2048 computer use with a choice of fastest 30 accepted moves or highest score after 60 accepted moves. Covers Peekaboo, Cua Driver, native Codex Computer Use, model-assisted arms, and bounded TypeSafe Jev.
---

# Computer Use Benchmark

Run against the open `com.ainb.benchmark2048` app. If the user has not chosen a test, ask for **fastest 30 moves** or **highest point 60 moves**. A move means the game's counter increased by exactly one, not an attempted keypress, click, or model decision. Never label a partial run complete.

| Test | Primary result | Secondary results | Default comparison |
| --- | --- | --- | --- |
| Fastest 30 moves | Wall time to 30 accepted moves | Time per accepted move, attempted actions, stalls | Peekaboo, Cua Driver, native Codex Computer Use |
| Highest point 60 moves | Score after 60 accepted moves | Best tile, wall time, model cost | Peekaboo + Luna, Cua Driver + Luna, Cua Driver + Jev |

## Current recorded arms (8 October 2026)

| Test | Arms | Recorded state |
| --- | --- | --- |
| 30 speed, tool-only | Peekaboo; Cua Driver without Jev; native Codex Computer Use | Three distinct recordings |
| 30 speed, model-assisted | Gemini 3.8 Flash Low + Peekaboo; Gemini 3.8 Flash Low + Cua Driver; Gemini 2.5 Flash + Peekaboo; Gemini 2.5 Flash + Cua Driver | Four distinct 30-input recordings; accepted move counts not audited |
| 30 speed, Copilot | GitHub Copilot through `computer-use-mcp` | Earlier partial 11/30; later 30/60-call files stall at game move 5; all unranked |
| 60 score | Peekaboo + GPT-5.6 Luna; Cua Driver + GPT-5.6 Luna; Cua Driver + TypeSafe Jev | Three completed 60-move recordings from one shared opening board; subsequent spawns random |

## Arm definitions

| Arm ID | Decision Engine | Perception / Action Stack | Primary Focus |
| :--- | :--- | :--- | :--- |
| `peekaboo` | Built-in policy; Gemini 3.8 Flash Low via agy with `MOVE_POLICY=agent` | Cua Window State + Peekaboo CLI (`/usr/local/bin/peekaboo press`) | Fast CLI keypress baseline |
| `cuadriver` | Built-in policy; Gemini 3.8 Flash Low via agy with `MOVE_POLICY=agent` | Cua Window State + CuaDriver MCP (`press_key`) | Full Accessibility tree / MCP |
| `cua_jev` | TypeSafe JEV System-One | Cua Window State + CuaDriver MCP (`press_key`) | Ultra-low latency decision loop (<250ms) |
| `copilot` | GitHub Copilot Native | Cua Window State + CuaDriver MCP / Native Key | Copilot latency and native computer use |

> Peekaboo and Cua Driver arms use a fixed move policy by default, so their timings measure the computer-use stack alone. Set `MOVE_POLICY=agent` to let agy (Gemini 3.8 Flash Low) choose moves for model-assisted runs. Computer use tools are the benchmark targets. Zero external model API keys required.

Use the same game build and initial board for each arm. Record whether the random generator was actually seeded; a seed label in a folder or trace does not prove deterministic spawns. Record app version, exact model, tool version, control path, capture path, and timing boundaries. Reset and verify the move counter is zero before each arm. Resolve PID and window ID from the **current** app instance by bundle ID; never reuse an old PID.

## Preflight for either test

1. Confirm app window, live board, score, move counter, New Game control, and working Screen Recording and Accessibility permission for each selected tool.
2. For each arm, make one reversible test move and verify exactly one game move, visible board change, and usable frame. Then reset to the shared start. A permission listing alone is insufficient.
3. Confirm selected model or TypeSafe endpoint responds before timing. Keep keys out of logs and screenshots. Jev needs `TYPESAFE_API_KEY`; load it from Bitwarden item `TYPESAFE_API_KEY`, custom field `KEY`, using the existing `~/.secrets/bitwarden-credentials` and `~/.secrets/bw-master` setup if not already exported. No Gemini key is required for default comparisons.
4. Capture the app window. Inspect sample frames for wallpaper, permission dialogs, stale frames, and legible score/move text. `get_window_state` and video encoding alone do not guarantee clean capture.
5. Set finite action and decision budgets. Record no-ops, refusals, retries, crashes, and resets. Mark `partial` if game over or tool failure prevents the target count.

`scripts/preflight.sh` checks some dependencies and credentials. It does **not** prove a selected tool can observe and move the game. Complete the live checks above.

## Test 1: fastest 30 moves

- Goal: minimize wall time from the verified reset/first observation through confirmation of the 30th **accepted** move. Include perception, decision, action, verification, and normal settling. Report attempted actions separately.
- Use one fixed, documented move policy for the three tool-only arms. Apply it to each observed board, choose a legal move, and count only accepted moves. Do not give one arm a smarter policy.
- Main arms: Peekaboo `press` for movement; Cua Driver observation and action; built-in Codex Computer Use for native control. If Cua Driver records the Codex arm, label it as capture only.
- Describe control paths precisely: Peekaboo is a Swift macOS CLI using screenshots and Accessibility, not SwiftUI-only. The recorded PID-scoped keypress path kept the game frontmost; Peekaboo also supports exact-window background input. Codex used its built-in computer-use input and app-state reads; its underlying OS implementation is not public. Cua Driver reads a specific window's Accessibility state and can send supported actions in the background without taking focus, with foreground fallback when required. Background delivery is best effort, not universal.
- Keep model-assisted panels separate from the tool-only speed ranking. Current additional arms: Gemini 3.8 Flash Low + Peekaboo, Gemini 3.8 Flash Low + Cua Driver, Gemini 2.5 Flash + Peekaboo, and Gemini 2.5 Flash + Cua Driver. Their elapsed time includes model decisions; label the exact model and access path.
- GitHub Copilot through intermediary `computer-use-mcp` is a separate arm. The earlier recording reached 11/30 moves, with six interrupted calls and user-reported nudges. Show `PARTIAL` with a red border if included; leave unranked until complete. This is Copilot using an MCP bridge, not direct native OS control. These observations do not isolate MCP itself as the cause of interruptions.
- Later supplied `copilot-30` and `copilot-60` folders contain 30 and 60 successful-call rows, but both games stop at move 5. Their fixed 120 ms, 0.8-confidence Down/Right pattern matches the legacy runner's heuristic fallback. Do not claim they are completed Copilot runs, model timings, or evidence of actual Copilot decisions. No defensible Copilot wall time or cost comes from these files.
- Keep Jev out of the standard 30-move speed grid. Its decision loop optimizes a different task. If requested, run it separately with the bounded protocol below.
- Use one distinct run per video panel. An eight-panel, two-row grid fits the current three tool-only, four Gemini, and one Copilot recordings. Align completed 30-move comparisons by **accepted move**. If mixing runs that only recorded attempted inputs, align by input index and label that difference; do not rank those panels together. Show measured timing in captions. Playback length is not benchmark time.

Current speed grid: `outputs/benchmark-computer-use/benchmark_speed_grid_8up_no_jev.mp4`, with `SPEED_GRID_README.md` beside it in the benchmark workspace. That historical video aligns by step index and shows measured mean time per input; audit accepted counts before citing it as a completed 30-move ranking. The Gemini 2.5 `arm1`/`arm2` clips were duplicate presentations and were omitted.

## Test 2: highest point 60 moves

- Goal: maximize score on the 60th **accepted** move. Run each arm from the same initial board and game build. If a controlled common seed is required, implement and verify deterministic spawning; the current game uses random spawns after the common opening board. Record score, best tile, accepted count, wall time, token usage, and cost. Early game over is `partial` with final score and accepted count.
- Current comparison arms: Peekaboo + GPT-5.6 Luna, Cua Driver + GPT-5.6 Luna, Cua Driver + TypeSafe Jev. Use the model actually available and record its exact name. Never silently substitute. Prior Luna runs invoked `codex exec` once per decision, so time and tokens include CLI startup and injected context.
- Observe board and generate legal moves only. After acting, reobserve and verify the move counter advanced by one, board continuity, legal slide, exact merge-score delta, and one spawned tile. Log no-ops without counting them toward 60.
- Rank by score within each run. Show wall time and cost separately; do not infer intrinsic model speed from whole-harness timing. One run per arm with random later spawns does not establish a general score ranking. Use multiple controlled starts for a broader claim.
- Align replay by accepted move and label playback rate. Preserve real elapsed timings in the report. Show cache-aware and no-cache API-equivalent estimates when usage is available. Distinguish estimates from actual provider charges.

Current 60-move example: `outputs/benchmark-computer-use/score-60-seed-20261007/COMPARISON_REPORT.md`, `comparison.json`, and `outputs/benchmark-score60-linkedin.mp4` in the benchmark workspace. All three completed 60 accepted moves; scores were 504, 472, and 500 respectively. The directory's seed label is historical metadata, not proof of seeded spawns.

## Correct Cua Driver + Jev path

```text
┌─────────┐    ┌───────────────┐    ┌──────────────┐
│ Game AX │───▶│ Legal move IDs│───▶│ TypeSafe Jev │
└─────────┘    └───────────────┘    └──────┬───────┘
      ▲                                      │ one ID
      │                                      ▼
┌─────────┐                         ┌──────────────┐
│ Verify  │◀────────────────────────│ Cua Driver   │
└─────────┘                         └──────────────┘
```

Follow the official [Cua jev-use example](https://github.com/trycua/cua/tree/main/libs/cua-driver/examples/jev-use). **Cua Driver owns observation and action; Jev chooses one bounded candidate ID. The runner owns the loop.** Jev is the only model decision maker in this arm.

1. Observe current board, score, move counter, and AX controls through Cua Driver. Capture a snapshot ID and current element tokens.
2. Project the 2048 slide for each direction. Supply Jev only legal candidate IDs with merge gain, empty cells, projected board, plus actual board, score, move count, goal, and short action history. Ask it to maximize score at 60 accepted moves.
3. Call the official bounded TypeSafe Jev adapter. Validate returned ID is in the supplied set and belongs to the same snapshot. If invalid or stale, reobserve and retry within budget; do not silently substitute a heuristic or another model.
4. Execute the selected AX action with Cua Driver. Try scoped background delivery first; use foreground only after a structured background refusal. Reobserve and verify move and score. Log model, confidence, candidate set, action, outcome, timing, and any returned usage.
5. Calculate Jev cost from actual usage when available. If missing, sample or reconstruct requests and label an estimate. Check current TypeSafe list price. Account for SDK retries before claiming a bill. Jev decision time, Driver action time, and whole-loop time are different metrics.

The old `scripts/runner.ts` Jev branch sends only a step number and alternates fixed directions. That is **not** this protocol and must not produce an official Jev result. Its `copilot` branch uses GitHub Models API or a heuristic fallback; it is **not** native GitHub Copilot computer use. Its hard-coded PID and attempted-input count also make `scripts/run.sh` unsuitable for either official test until corrected. Use the validated workflow and saved traces as implementation references; do not present legacy script output as a completed benchmark.

## Output contract

Save one directory per attempt with mode, arm, date, and verified seed or opening-board identifier in its name. Include raw frames, individual MP4, JSONL trace, summary JSON, and comparison report/video for completed groups. Each trace entry needs observed board and counters before/after, accepted or no-op outcome, direction, capture/action provenance, elapsed components, and model usage if available. Report primary metric, completion status, wall time, and cost method. Keep duplicate recordings out of final grid.

## Publishing the two current comparisons

LinkedIn allows one video per post. Use the prepared 30 fps exports in the benchmark workspace: `outputs/benchmark-speed-grid-linkedin.mp4` for the speed/control-path story, then `outputs/benchmark-score60-linkedin.mp4` for the score/time/cost story. The first video contains eight panels: three completed fixed-policy tool-only arms, four Gemini 30-input arms, and one partial Copilot arm. Its 16-second, step-aligned replay is not elapsed benchmark time. The second video aligns 60 accepted moves per arm; its 30.5-second replay is not elapsed time either.

Current fixed-policy 30-move means: Codex 0.70 s/input, Peekaboo 0.85, Cua Driver 1.51. Gemini 2.5 Flash means: Peekaboo 2.80 and Cua Driver 3.59 s/input; Gemini 3.8 Flash Low: Peekaboo 6.83 and Cua Driver 6.81 s/input. The Gemini figures cover inputs, not verified 30-move finishes. Current 60-move score/time/API-equivalent cost: Peekaboo + Luna 504/437.8 s/$0.1936, Cua Driver + Luna 472/421.5 s/$0.0986, Cua Driver + Jev 500/132.1 s/~$0.00242. Use saved reports as the source of truth if new runs supersede these snapshots.

Write two connected, first-person posts. For Stevie's voice, read `~/d/git/stevengonsalvez.github.io/.claude/skills/humanizer/SKILL.md`, `.claude/skills/review-blog/SKILL.md`, and a relevant published comparison such as `_devto/22-07-2026-measure-cost-by-outcomes.md`. Lead with what happened on screen, show the measured result, explain the control loop, then state the limitation and take. Use plain paragraphs and specific receipts rather than a feature list. Current drafts are `outputs/linkedin-speed-post.txt` and `outputs/linkedin-cost-post.txt` in the benchmark workspace.

For the speed post, keep fixed-policy tool times separate from Gemini decision-inclusive times. State that Copilot's MCP-mediated attempt was partial and needed nudges in this setup; do not claim the MCP protocol itself caused the failures. For the cost post, show accepted moves, final score, complete-run wall time, and API-equivalent cost. Explain that Luna invoked a fresh Codex CLI per decision, its two cache-aware estimates differ mostly through reported caching, and Jev's cost is sampled rather than billed. Avoid general rankings from one game per arm.

See [troubleshooting](references/troubleshooting.md) for capture and move-stall guidance. `assets/game-2048/main.swift` describes game mechanics.
