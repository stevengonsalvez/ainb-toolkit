#!/usr/bin/env python3
"""Read Site Data answers back from an interactive explainer (owner API).

  read_decisions.py --name devon-board [--collection decisions] [--json]

Prints the newest answer per item (an insert-only collection means the latest
record is the standing answer), plus the full history when --all is passed.
"""
import argparse, json, os, sys, urllib.request, urllib.error

API = "https://here.now"


def key():
    k = os.environ.get("HERENOW_API_KEY")
    if k:
        return k.strip()
    p = os.path.expanduser("~/.herenow/credentials")
    if not os.path.exists(p):
        sys.exit("no API key in $HERENOW_API_KEY or ~/.herenow/credentials")
    return open(p).read().strip()


def fetch(slug, coll, k):
    out, cursor = [], None
    while True:
        url = f"{API}/api/v1/publishes/{slug}/data/{coll}?limit=100"
        if cursor:
            url += f"&cursor={cursor}"
        rq = urllib.request.Request(url, headers={"Authorization": f"Bearer {k}"})
        try:
            with urllib.request.urlopen(rq, timeout=30) as r:
                page = json.loads(r.read())
        except urllib.error.HTTPError as e:
            sys.exit(f"{e.code} reading {coll}: {e.read()[:200].decode()}")
        out += page.get("records", [])
        cursor = page.get("nextCursor")
        if not cursor:
            return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, help="pin name used by publish_interactive.py")
    ap.add_argument("--collection", default="decisions")
    ap.add_argument("--all", action="store_true", help="every record, not just the newest per item")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    pin = os.path.expanduser(f"~/.herenow/{a.name}-slug")
    if not os.path.exists(pin):
        sys.exit(f"no pinned slug at {pin} — publish with publish_interactive.py first")
    slug = open(pin).read().strip()

    recs = sorted(fetch(slug, a.collection, key()), key=lambda r: r["createdAt"])
    if not a.all:
        newest = {}
        for r in recs:                       # ascending, so the last write per item wins
            newest[r["data"].get("item")] = r
        recs = [newest[k] for k in sorted(newest)]

    if a.json:
        print(json.dumps(recs, indent=1))
        return
    if not recs:
        print(f"no records in '{a.collection}' for {slug}")
        return
    for r in recs:
        d = r["data"]
        answer = d.get("choice") or d.get("stance") or "?"
        print(f"{d.get('item',''):<8} {answer:<4} {d.get('who',''):<16} {r['createdAt'][:16]}")
        if d.get("note"):
            print(f"         └ {d['note']}")


if __name__ == "__main__":
    main()
