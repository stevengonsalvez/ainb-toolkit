#!/usr/bin/env python3
"""Publish an explainer HTML to a here.now custom domain and register it in the index.

Pipeline: publish file as its own here.now site -> optional password lock ->
mount at /<path>/ on the domain -> append/update entry in the index site's
data.json (never clobbers other entries) -> republish index.

Config: ~/.herenow/explainers.json  (domain, index_slug, password, categories)
Auth:   ~/.herenow/credentials or $HERENOW_API_KEY

Usage:
  publish_explainer.py file.html --path my-explainer --title "T" --desc "D" \
      --category ainb [--lock] [--date YYYY-MM-DD] [--dry-run]
  publish_explainer.py --remove my-explainer          # unmount + drop index entry

The agent decides --category and --lock (using config's protect_rule);
this script only executes mechanics. Exit non-zero on any failure.
"""
import argparse, datetime, hashlib, json, os, re, sys, urllib.error, urllib.request

API = "https://here.now"
CFG_PATH = os.path.expanduser("~/.herenow/explainers.json")
CRED_PATH = os.path.expanduser("~/.herenow/credentials")


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def req(method, url, key=None, body=None, raw=False, ctype="application/json"):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
    r = urllib.request.Request(url, data=data, method=method)
    if key:
        r.add_header("Authorization", f"Bearer {key}")
    if data is not None:
        r.add_header("Content-Type", ctype)
    r.add_header("X-HereNow-Client", "claude-code/publish-explainer")
    # Cloudflare 403s the default Python-urllib UA on *.here.now site fetches
    r.add_header("User-Agent", "Mozilla/5.0 (publish-explainer)")
    with urllib.request.urlopen(r, timeout=60) as resp:
        out = resp.read()
    return out if raw else (json.loads(out) if out else {})


def load_cfg():
    if not os.path.exists(CFG_PATH):
        die(f"missing config {CFG_PATH} — see explain-to-me references/publishing.md")
    cfg = json.load(open(CFG_PATH))
    key = os.environ.get("HERENOW_API_KEY") or (
        open(CRED_PATH).read().strip() if os.path.exists(CRED_PATH) else None)
    if not key:
        die(f"no API key in $HERENOW_API_KEY or {CRED_PATH}")
    for f in ("domain", "index_slug"):
        if not cfg.get(f):
            die(f"config missing '{f}'")
    return cfg, key


def publish_site(files, key, slug=None):
    """files: {relpath: bytes}. Returns slug. slug=None creates, else updates."""
    manifest = []
    for p, b in files.items():
        ct = "text/html; charset=utf-8" if p.endswith(".html") else \
             "application/json; charset=utf-8" if p.endswith(".json") else \
             "application/octet-stream"
        manifest.append({"path": p, "size": len(b), "contentType": ct,
                         "hash": hashlib.sha256(b).hexdigest()})
    if slug:
        r = req("PUT", f"{API}/api/v1/publish/{slug}", key, {"files": manifest})
    else:
        r = req("POST", f"{API}/api/v1/publish", key, {"files": manifest})
    slug = r["slug"]
    up = r["upload"]
    for u in up["uploads"]:
        rq = urllib.request.Request(u["url"], data=files[u["path"]], method=u.get("method", "PUT"))
        for h, v in (u.get("headers") or {}).items():
            rq.add_header(h, v)
        urllib.request.urlopen(rq, timeout=120).read()
    req("POST", up["finalizeUrl"], key, {"versionId": up["versionId"]})
    return slug


def fetch_index(cfg):
    """Return (index_html_bytes, data_dict) from the live index site."""
    base = f"https://{cfg['index_slug']}.here.now"
    cb = f"?cb={os.urandom(6).hex()}"  # bust CDN cache; stale data.json loses entries
    html = req("GET", f"{base}/{cb}", raw=True)
    data = json.loads(req("GET", f"{base}/data.json{cb}", raw=True))
    if "entries" not in data:
        die("index data.json has no 'entries' — refusing to touch it")
    return html, data


def upsert_entry(data, entry):
    for i, e in enumerate(data["entries"]):
        if e["path"] == entry["path"]:
            data["entries"][i] = entry
            return "updated"
    data["entries"].append(entry)
    data["entries"].sort(key=lambda e: e["date"], reverse=True)
    return "added"


def save_index(cfg, key, html, data):
    publish_site({"index.html": html,
                  "data.json": json.dumps(data, indent=1, ensure_ascii=False).encode()},
                 key, slug=cfg["index_slug"])


def mount(cfg, key, path, slug):
    body = {"location": path, "slug": slug, "domain": cfg["domain"]}
    try:
        req("POST", f"{API}/api/v1/links", key, body)
    except urllib.error.HTTPError:
        # location exists -> repoint. PATCH /links/:loc only targets handles
        # ("No handle found"), so for custom domains: delete + recreate.
        req("DELETE", f"{API}/api/v1/links/{path}?domain={cfg['domain']}", key)
        req("POST", f"{API}/api/v1/links", key, body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?")
    ap.add_argument("--path", help="mount path on domain (<=30 chars, hyphen-case)")
    ap.add_argument("--title")
    ap.add_argument("--desc", default="")
    ap.add_argument("--category", default="other")
    ap.add_argument("--lock", action="store_true")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--remove", metavar="PATH", help="unmount + remove index entry")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    cfg, key = load_cfg()

    if a.remove:
        html, data = fetch_index(cfg)
        n0 = len(data["entries"])
        data["entries"] = [e for e in data["entries"] if e["path"] != a.remove]
        if a.dry_run:
            print(f"DRY: would unmount /{a.remove}/ and drop {n0-len(data['entries'])} index entry")
            return
        try:
            req("DELETE", f"{API}/api/v1/links/{a.remove}?domain={cfg['domain']}", key)
        except urllib.error.HTTPError as e:
            print(f"warn: unmount: {e}", file=sys.stderr)
        save_index(cfg, key, html, data)
        print(f"removed /{a.remove}/ (index entries {n0} -> {len(data['entries'])})")
        return

    if not (a.file and a.path and a.title):
        die("need file, --path, --title (or --remove)")
    if len(a.path) > 30:
        die(f"--path '{a.path}' is {len(a.path)} chars; here.now limit is 30")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", a.path):
        die("--path must be lowercase hyphen-case")
    if a.category not in cfg.get("categories", {}):
        die(f"--category '{a.category}' not in config: {list(cfg['categories'])}")
    content = open(a.file, "rb").read()

    if a.dry_run:
        print(f"DRY: publish {a.file} -> new site; lock={a.lock}; "
              f"mount /{a.path}/ on {cfg['domain']}; index upsert "
              f"{{path:{a.path}, cat:{a.category}, date:{a.date}}}")
        return

    slug = publish_site({"index.html": content}, key)
    print(f"site: https://{slug}.here.now/")
    if a.lock:
        if not cfg.get("password"):
            die("--lock set but no 'password' in config")
        req("PATCH", f"{API}/api/v1/publish/{slug}/metadata", key,
            {"password": cfg["password"]})
        print("locked")
    mount(cfg, key, a.path, slug)
    html, data = fetch_index(cfg)
    verb = upsert_entry(data, {"path": a.path, "title": a.title, "desc": a.desc,
                               "date": a.date, "locked": a.lock, "cat": a.category})
    save_index(cfg, key, html, data)
    print(f"index: {verb} /{a.path}/ ({len(data['entries'])} entries)")
    print(f"live (KV lag <=60s): https://{cfg['domain']}/{a.path}/")


if __name__ == "__main__":
    main()
