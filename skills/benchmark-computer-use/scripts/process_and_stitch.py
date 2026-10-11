import argparse
import glob
import json
import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont, ImageStat

FONT_PATHS = [
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]

# Matches runner.ts: MOVE_POLICY=agent means agy picked the moves for these two arms.
_POLICY = "Gemini 3.8 Flash Low" if os.environ.get("MOVE_POLICY") == "agent" else "built-in policy"

ARM_METADATA = {
    "peekaboo": {
        "title": f"Peekaboo ({_POLICY})",
        "color": (37, 99, 235, 255),
    },
    "cuadriver": {
        "title": f"Cua Driver ({_POLICY})",
        "color": (5, 150, 105, 255),
    },
    "cua_jev": {
        "title": "Cua Driver + JEV System-One",
        "color": (124, 58, 237, 255),
    },
    "codex_cua": {
        "title": "Codex Computer Use (native input)",
        "color": (17, 94, 89, 255),
    },
    "copilot": {
        "title": "GitHub Copilot (Native Computer Use)",
        "color": (234, 88, 12, 255),
    },
}

def get_font(size):
    for fp in FONT_PATHS:
        if os.path.exists(fp):
            try:
                return ImageFont.truetype(fp, size)
            except Exception:
                continue
    return ImageFont.load_default()

def validate_frame(fpath):
    """Verify frame contains non-empty game visual rather than blank wallpaper."""
    try:
        if os.path.getsize(fpath) < 2000:
            return False, "File size under 2KB"
        with Image.open(fpath) as img:
            stat = ImageStat.Stat(img.convert("RGB"))
            variance = sum(stat.var) / len(stat.var)
            if variance < 5.0:
                return False, f"Flat single-color image (variance {variance:.1f})"
        return True, "Valid game capture"
    except Exception as e:
        return False, str(e)

def annotate_frames_for_arm(results_dir, arm_name, title, color_rgb):
    src_dir = os.path.join(results_dir, f"frames_{arm_name}")
    dst_dir = os.path.join(results_dir, f"annotated_{arm_name}")
    os.makedirs(dst_dir, exist_ok=True)

    trace_file = os.path.join(results_dir, f"{arm_name}_trace.jsonl")
    traces = {}
    if os.path.exists(trace_file):
        with open(trace_file, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    try:
                        d = json.loads(line)
                        traces[d.get("step", 0)] = d
                    except Exception:
                        pass

    files = sorted(glob.glob(os.path.join(src_dir, "*.png")))
    if not files:
        print(f"[process] No frames found for arm: {arm_name}")
        return 0

    print(f"[process] Validating and annotating {len(files)} frames for {arm_name}...")
    font_title = get_font(28)
    font_sub = get_font(20)

    for idx, fpath in enumerate(files):
        valid, reason = validate_frame(fpath)
        if not valid:
            print(f"[process] Warning: Frame {os.path.basename(fpath)} suspect: {reason}")

        img = Image.open(fpath).convert("RGBA")
        banner_height = 80
        new_img = Image.new("RGBA", (img.width, img.height + banner_height), color=(20, 20, 20, 255))
        draw = ImageDraw.Draw(new_img)

        draw.rectangle([0, 0, img.width, banner_height], fill=color_rgb)
        draw.text((20, 10), title, font=font_title, fill=(255, 255, 255, 255))

        step_idx = idx
        trace_info = traces.get(step_idx)
        if trace_info:
            sub_text = (
                f"Step {step_idx}: {trace_info.get('direction', '')} | "
                f"Latency: {trace_info.get('total_step_ms', 0):.0f}ms (Model: {trace_info.get('model_ms', 0):.0f}ms)"
            )
        elif step_idx == 0:
            sub_text = "Initial Board State"
        else:
            sub_text = f"Step {step_idx}"

        draw.text((20, 46), sub_text, font=font_sub, fill=(240, 240, 240, 255))
        new_img.paste(img, (0, banner_height))

        out_name = f"frame_{idx:04d}.png"
        new_img.save(os.path.join(dst_dir, out_name))

    return len(files)

def encode_arm_video(results_dir, arm_name, output_mp4):
    dst_dir = os.path.join(results_dir, f"annotated_{arm_name}")
    cmd = [
        "ffmpeg", "-y",
        "-framerate", "2",
        "-i", os.path.join(dst_dir, "frame_%04d.png"),
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-preset", "fast",
        "-crf", "20",
        output_mp4,
    ]
    subprocess.run(cmd, check=True)
    print(f"[process] Encoded {output_mp4}")

def stitch_videos(video_paths, out_mp4):
    num_vids = len(video_paths)
    if num_vids == 0:
        return
    if num_vids == 1:
        import shutil
        shutil.copyfile(video_paths[0], out_mp4)
        print(f"[process] Single arm video saved to {out_mp4}")
        return

    print(f"[process] Stitching {num_vids} videos horizontally...")
    scale_parts = []
    inputs_cmd = []
    stack_inputs = []

    for idx, v in enumerate(video_paths):
        inputs_cmd.extend(["-i", v])
        scale_parts.append(f"[{idx}:v]scale=480:720[v{idx}]")
        stack_inputs.append(f"[v{idx}]")

    filter_str = ";".join(scale_parts) + ";" + "".join(stack_inputs) + f"hstack=inputs={num_vids}[outv]"

    cmd = ["ffmpeg", "-y"] + inputs_cmd + [
        "-filter_complex", filter_str,
        "-map", "[outv]",
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-preset", "fast",
        "-crf", "22",
        out_mp4,
    ]
    subprocess.run(cmd, check=True)
    print(f"[process] Multi-arm video generated: {out_mp4}")

def generate_report(results_dir, active_arms):
    summary = {}
    for arm in active_arms:
        trace_path = os.path.join(results_dir, f"{arm}_trace.jsonl")
        title = ARM_METADATA.get(arm, {}).get("title", arm)
        if os.path.exists(trace_path):
            with open(trace_path, "r", encoding="utf-8") as f:
                lines = [json.loads(l) for l in f if l.strip()]
            if lines:
                summary[title] = {
                    "total_ms": sum(l["total_step_ms"] for l in lines) / len(lines),
                    "model_ms": sum(l["model_ms"] for l in lines) / len(lines),
                    "action_ms": sum(l["action_ms"] for l in lines) / len(lines),
                    "perception_ms": sum(l.get("perception_ms", 0) for l in lines) / len(lines),
                    "count": len(lines),
                }

    report_md = "# Computer Use Speed Benchmark Report\n\n"
    report_md += "## Environment & Test Specification\n"
    report_md += "- **Task**: `com.ainb.benchmark2048` (sequential moves)\n"
    report_md += "- **Decision**: Built-in alternating-axis policy except JEV arm\n"
    report_md += "- **Host**: Apple Silicon M-series (macOS Sequoia)\n"
    report_md += "- **Perception**: Direct Window State API (No Sequoia wallpaper blanking)\n"
    report_md += "- **Side-by-side Video**: `benchmark_side_by_side.mp4`\n\n"
    report_md += "## Benchmark Results\n\n"
    report_md += "| Tool / Stack | Perception (ms) | Model / Decision (ms) | Action Execution (ms) | Total / Move (ms) | Speedup |\n"
    report_md += "| :--- | :---: | :---: | :---: | :---: | :---: |\n"

    first_val = list(summary.values())[0]["total_ms"] if summary else 1.0
    for name, s in summary.items():
        speedup = f"{first_val / s['total_ms']:.2f}x" if s['total_ms'] > 0 else "1.00x"
        report_md += (
            f"| **{name}** | {s['perception_ms']:.1f} | {s['model_ms']:.1f} | "
            f"{s['action_ms']:.1f} | **{s['total_ms']:.1f}** | {speedup} |\n"
        )

    report_path = os.path.join(results_dir, "BENCHMARK_REPORT.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report_md)
    print(f"[process] Report written: {report_path}")

def main():
    parser = argparse.ArgumentParser(description="Process and stitch computer use benchmark frames.")
    parser.add_argument("--results-dir", default="./benchmark-results", help="Directory containing frames and traces")
    parser.add_argument("--arms", default="", help="Comma-separated list of arms to process")
    args = parser.parse_args()

    results_dir = os.path.abspath(args.results_dir)
    if not os.path.isdir(results_dir):
        print(f"[process] Error: results directory not found: {results_dir}")
        sys.exit(1)

    if args.arms:
        arm_list = [a.strip().replace("-", "_") for a in args.arms.split(",") if a.strip()]
    else:
        # Auto-detect from folders
        found = []
        for folder in os.listdir(results_dir):
            if folder.startswith("frames_"):
                found.append(folder.replace("frames_", ""))
        arm_list = found or ["peekaboo", "cuadriver", "cua_jev"]

    encoded_videos = []
    processed_arms = []

    for arm in arm_list:
        meta = ARM_METADATA.get(arm, {"title": f"Arm: {arm}", "color": (100, 100, 100, 255)})
        count = annotate_frames_for_arm(results_dir, arm, meta["title"], meta["color"])
        if count > 0:
            out_mp4 = os.path.join(results_dir, f"arm_{arm}.mp4")
            encode_arm_video(results_dir, arm, out_mp4)
            encoded_videos.append(out_mp4)
            processed_arms.append(arm)

    if encoded_videos:
        stitched_mp4 = os.path.join(results_dir, "benchmark_side_by_side.mp4")
        stitch_videos(encoded_videos, stitched_mp4)
        generate_report(results_dir, processed_arms)
        print("[process] All frame processing and video generation completed successfully.")

if __name__ == "__main__":
    main()
