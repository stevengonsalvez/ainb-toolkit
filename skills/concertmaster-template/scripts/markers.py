#!/usr/bin/env python3
# Print every genuine `cm:merge-ready` pair from an Orca worktree list reply.
#
#   orca worktree list --json [--environment <host>] | scripts/markers.py
#
# Output TSV: worktree-name  #pr  sha. Rules (references/lanes.md, Reporting contract):
#  - the marker counts only at the START of the comment or right after ` | `, as the whole
#    token `cm:merge-ready` (so `converting to cm:merge-ready per PR` and
#    `cm:merge-ready-pending` are NOT markers);
#  - the first `#<pr> <hex7-40>` pair may follow some prose ("for after the freeze (x): #90830 ...")
#    but only before the next `cm:` token;
#  - further pairs follow only when separated by whitespace, `|`, commas or parenthesised
#    notes; any other prose (e.g. `in review: #90914 ...`) ends the list.
# A pair names the exact head to gate: if the live head differs, the marker is stale (the
# caller checks `gh pr view <n> --json headRefOid`). A merged PR's marker also stays listed
# until a later comment replaces it: check the PR state before gating.
import sys
sys.path.pop(0)  # never import a planted module from the script directory
import json, re

raw = sys.stdin.buffer.read().decode("utf-8", "replace")
try:
    d = json.loads(raw, strict=False)
except Exception:
    sys.exit(0)
r = d.get("result", d) if isinstance(d, dict) else d
wts = r.get("worktrees", []) if isinstance(r, dict) else r
marker = re.compile(r"(?:^|\|\s*)cm:merge-ready(?![\w-])")
pair = re.compile(r"#(\d+)\s+([0-9a-f]{7,40})\b")
sep = re.compile(r"(?:\s|\||,|\([^)]*\))*")
for w in wts:
    c = (w.get("comment") or "").replace("\n", " ").strip()
    name = (w.get("path") or "").rstrip("/").split("/")[-1]
    for m in marker.finditer(c):
        rest = c[m.end():]
        nxt = re.search(r"cm:[a-z]", rest)
        if nxt:
            rest = rest[:nxt.start()]
        p = pair.search(rest)
        while p:
            print(f"{name}\t#{p.group(1)}\t{p.group(2)}")
            rest = rest[p.end():]
            s = sep.match(rest)
            rest = rest[s.end():]
            p = pair.match(rest)
