#!/usr/bin/env python3
"""Pin every dependency in an apm manifest to the commit apm resolved for it.

Usage: apm-pin.py apm/apm.yml ~/.apm/apm.lock.yaml
Entries under stevengonsalvez/ are our own and move with this repo, so they are left unpinned.
Run after `apm install -g` from an unpinned or stale manifest; the manifest then installs the same commits
everywhere, so a skill cannot change under us between hosts. Pinned is not reviewed: read a skill before
trusting it with credentials. Comments and layout in the manifest are kept.
"""
import re
import sys

import yaml

manifest, lockfile = sys.argv[1], sys.argv[2]
lock = {}
for e in yaml.safe_load(open(lockfile))["dependencies"]:
    key = (e["repo_url"].lower(), (e.get("virtual_path") or "").strip("/"))
    if e.get("resolved_commit"):
        lock[key] = e["resolved_commit"]

DEP = re.compile(r"^(\s+- )([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/[^#\s]+)?(#\S+)?\s*$")
out, pinned, missing = [], 0, []
for line in open(manifest).read().splitlines():
    m = DEP.match(line)
    if m and m.group(2).lower().startswith("stevengonsalvez/"):
        line = re.sub(r"#\S+$", "", line)
    elif m:
        sub = (m.group(3) or "").strip("/")
        sha = lock.get((m.group(2).lower(), sub))
        if sha:
            line = f"{m.group(1)}{m.group(2)}{m.group(3) or ''}#{sha}"
            pinned += 1
        else:
            missing.append(line.strip())
    out.append(line)
open(manifest, "w").write("\n".join(out) + "\n")
print(f"pinned {pinned}; no lock entry for {len(missing)}")
for m in missing:
    print("  unpinned:", m)
