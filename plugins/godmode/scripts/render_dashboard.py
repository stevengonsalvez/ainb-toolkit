#!/usr/bin/env python3
"""Deterministic godmode dashboard renderer.

Reads state.json + beads issues.jsonl + charter.md (+ optional pending marker)
and expands the mechanized template (assets/programme-dashboard.html) into a
static HTML page. No model involvement: this is the hook-owned status surface.

Row loop markers in the template:
    <!-- row:NAME
    <tr>... {field} ...</tr>
    -->
    <!-- rows:NAME -->
The comment carries the row template; the `rows:` placeholder receives the
expanded rows.
"""
import argparse
import html
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def esc(v):
    return html.escape(str(v)) if v is not None else ""


def load_json(path):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return {}


def load_jsonl(path):
    rows = []
    try:
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    except Exception:
        pass
    return rows


def epic_emoji(status):
    s = (status or "").upper()
    if s.startswith("SHIPPED"):
        return "\U0001F7E2"  # green
    if "BLOCK" in s or "FAIL" in s:
        return "\U0001F534"  # red
    if s in ("", "PENDING", "PARKED"):
        return "⚪"      # white
    return "\U0001F7E1"      # amber: in some stage


def feature_rag(status):
    s = (status or "").lower()
    if s == "closed":
        return "\U0001F7E2"
    if s == "in_progress":
        return "\U0001F7E1"
    if s == "blocked":
        return "\U0001F534"
    return "⚪"


def git_commits(repo, n=15):
    try:
        out = subprocess.run(
            ["git", "-C", repo, "log", "--oneline", f"-{n}"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        sha, _, msg = line.partition(" ")
        rows.append({"sha": esc(sha), "message": esc(msg)})
    return rows


def expand_rows(tpl_html, name, rows):
    m = re.search(
        r"<!--\s*row:" + name + r"\n(.*?)\n\s*-->", tpl_html, re.S)
    row_tpl = m.group(1) if m else None
    rendered = ""
    if row_tpl and rows:
        for r in rows:
            try:
                rendered += row_tpl.format(**r) + "\n"
            except (KeyError, IndexError):
                continue
    return re.sub(
        r"<!--\s*rows:" + name + r"\s*-->",
        lambda _: rendered,
        tpl_html,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--beads", required=True)
    ap.add_argument("--charter", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--pending", default=None,
                    help="pending-publish marker file (renders staleness banner)")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--template", default=None)
    args = ap.parse_args()

    state = load_json(args.state)
    if not state:
        print(f"render: unreadable state {args.state}", file=sys.stderr)
        return 1
    beads = load_jsonl(args.beads)

    tpl_path = args.template or str(
        Path(__file__).resolve().parent.parent
        / "skills" / "godmode" / "assets" / "programme-dashboard.html")
    tpl = Path(tpl_path).read_text()

    charter_title = None
    try:
        for line in Path(args.charter).read_text().splitlines():
            if line.startswith("# "):
                charter_title = line[2:].strip()
                break
    except Exception:
        pass

    epics = state.get("epics") or {}
    shipped = sum(1 for v in epics.values()
                  if str(v).upper().startswith("SHIPPED"))
    term = state.get("termination") or {}
    term_bits = []
    if term.get("backlog_dry"):
        term_bits.append("backlog-dry")
    if term.get("budget_tokens"):
        term_bits.append(
            f"budget {term.get('spent_tokens_estimate', 0)}/{term['budget_tokens']}")
    if term.get("deadline"):
        term_bits.append(f"deadline {term['deadline']}")
    pr_links = ", ".join(
        f"{k}:{v}" for k, v in epics.items()
        if "PR" in str(v).upper()) or "-"

    banner = ""
    if args.pending and Path(args.pending).exists():
        p = load_json(args.pending)
        banner = (
            '<div class="note" style="border-left-color:var(--red)">'
            f'⚠ status publishing degraded since {esc(p.get("ts", "?"))} '
            f'(step: {esc(p.get("step", "?"))}). Showing freshest local render; '
            'retrying every tick.</div>')

    scalars = {
        "PROGRAMME_TITLE": esc(charter_title or state.get("dashboard_slug", "godmode")),
        "TIMESTAMP": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ"),
        "CHARTER_PATH": esc(args.charter),
        "BASE_BRANCH": esc(state.get("branch", "main")),
        "PHASE": esc(state.get("phase", "?")),
        "CURRENT_NOTE": esc(state.get("current_note") or "(no note)"),
        "HUMAN_GATE_STATUS": esc(state.get("human_gate", "?")),
        "EPICS_SHIPPED": str(shipped),
        "EPICS_TOTAL": str(len(epics)),
        "TERMINATION_STATUS": esc("; ".join(term_bits) or "unbounded"),
        "OPEN_PR_LINKS": esc(pr_links),
        "STOP_RULE_COUNTERS": esc(json.dumps(state.get("stop_counters", {}))),
        "PENDING_BANNER": banner,
    }
    for k, v in scalars.items():
        tpl = tpl.replace("{{" + k + "}}", v)

    epic_rows = [
        {"name": esc(k), "emoji": epic_emoji(str(v)), "detail": esc(v),
         "size": esc((state.get("epic_sizes") or {}).get(k, "-"))}
        for k, v in epics.items()
    ]
    feature_rows = [
        {"name": esc(b.get("title", b.get("id", "?"))),
         "verdict": esc((b.get("notes") or "-").splitlines()[0][:120] if b.get("notes") else "-"),
         "epic": esc(b.get("id", "-")),
         "rag": feature_rag(b.get("status"))}
        for b in beads if b.get("issue_type") in ("task", "feature")
    ]
    testing_rows = [
        {"suite": esc(t.get("suite", "?")), "date": esc(t.get("date", "?")),
         "result": esc(t.get("result", "?"))}
        for t in state.get("testing", [])
    ]
    evidence_rows = [
        {"epic": esc(e.get("epic", "?")), "url": esc(e.get("url", "#")),
         "name": esc(e.get("name", "artifact")),
         "proves": esc(e.get("proves", ""))}
        for e in state.get("evidence", [])
    ]

    tpl = expand_rows(tpl, "epic", epic_rows)
    tpl = expand_rows(tpl, "feature", feature_rows)
    tpl = expand_rows(tpl, "testing", testing_rows)
    tpl = expand_rows(tpl, "commit", git_commits(args.repo))
    tpl = expand_rows(tpl, "evidence", evidence_rows)

    leftover = re.findall(r"\{\{[A-Z_]+\}\}", tpl)
    if leftover:
        print(f"render: unresolved tokens {sorted(set(leftover))}",
              file=sys.stderr)
        return 1

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(tpl)
    print(f"render: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
