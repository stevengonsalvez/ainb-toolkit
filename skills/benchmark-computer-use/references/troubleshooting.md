# Computer Use Benchmark: Troubleshooting

## Wallpaper or blank capture

If a frame shows only desktop wallpaper, confirm the selected capture process has Screen Recording permission, target the current game window, capture again, and inspect the pixels. Cua Driver `get_window_state` is one capture path, not a guarantee. Do not include a blank frame as evidence.

## Permission dialog or blocked action

Check the live Accessibility and Screen Recording prompts for the exact app doing capture or control. Grant access in macOS settings, then repeat a one-move preflight. Repositioning the game window cannot grant permission or bypass a system dialog.

## Directional stalls

A requested direction can be a no-op even if the tool call succeeds. Reobserve the board and move counter after every action. Generate only legal directions from the current board and count only +1 counter changes. Do not use fixed odd/even directions for Jev; give it the current board and bounded legal choices.

## Stale PID or AX element token

Resolve PID and window ID from the current `com.ainb.benchmark2048` instance. AX element tokens belong to a particular observation. After reset, app restart, stale-token error, or intervening UI change, capture fresh state and rebuild candidate actions.

## Video encoder lacks drawtext

If FFmpeg lacks `drawtext`, annotate frames using the existing Pillow postprocessor, then encode with FFmpeg. Validate frame contents and labels before publishing. Replay duration is not wall-clock benchmark time.

