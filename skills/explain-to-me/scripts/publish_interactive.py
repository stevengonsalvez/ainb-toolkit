#!/usr/bin/env python3
"""Publish an explainer that carries Site Data, to a STABLE slug.

WHY THIS EXISTS
---------------
publish_explainer.py calls publish_site(files, key) with slug=None, which POSTs
/api/v1/publish and mints a BRAND-NEW Site on every run. The mount is then repointed,
so the URL looks stable while the slug underneath changes each time.

Site Data records are scoped to a slug. With the default publisher, every republish
silently strands every recorded answer on an orphaned slug. Nothing errors; the page
just comes back empty.

This pins the slug in ~/.herenow/<name>-slug and PUTs to it, so records survive.

USAGE
  publish_interactive.py page.html --name devon-board --path devon-decisions \
      --title "T" --desc "D" --category shot [--manifest .herenow/data.json] [--lock]
"""
import argparse, datetime, importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pub", os.path.join(HERE, "publish_explainer.py"))
pub = importlib.util.module_from_spec(spec); spec.loader.exec_module(pub)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--name", required=True,
                    help="stable pin name; slug is remembered in ~/.herenow/<name>-slug")
    ap.add_argument("--path", required=True, help="mount path on the domain (<=30 chars)")
    ap.add_argument("--title", required=True)
    ap.add_argument("--desc", default="")
    ap.add_argument("--category", default="other")
    ap.add_argument("--manifest", help="path to .herenow/data.json (enables Site Data)")
    ap.add_argument("--lock", action="store_true")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args()

    cfg, key = pub.load_cfg()
    if a.category not in cfg.get("categories", {}):
        pub.die(f"--category '{a.category}' not in config: {list(cfg['categories'])}")
    if len(a.path) > 30:
        pub.die(f"--path is {len(a.path)} chars; here.now limit is 30")

    # Resolve the password BEFORE publishing. This check used to sit after
    # publish_site(), so --lock on a category declared open died with the page
    # already live and UNLOCKED — the exact failure the flag exists to prevent.
    lock_pw = pub.password_for(cfg, a.category) if a.lock else None
    if a.lock and not lock_pw:
        pub.die(f"--lock set but category '{a.category}' is declared open in config "
            f"(passwords.{a.category} is null). Set a password there, or drop --lock.")

    pin = os.path.expanduser(f"~/.herenow/{a.name}-slug")
    slug = open(pin).read().strip() if os.path.exists(pin) else None

    files = {"index.html": open(a.file, "rb").read()}
    if a.manifest:
        files[".herenow/data.json"] = open(a.manifest, "rb").read()

    try:
        new = pub.publish_site(files, key, slug=slug)
    except Exception as ex:
        if not slug:
            raise
        # The pinned Site is gone (deleted, or expired). Mint a fresh one, but be loud:
        # any answers recorded against the old slug are NOT coming with us.
        print(f"WARNING: update of {slug} failed ({ex}); minting a new Site", file=sys.stderr)
        new = pub.publish_site(files, key, slug=None)

    if new != slug:
        os.makedirs(os.path.dirname(pin), exist_ok=True)
        open(pin, "w").write(new)
        msg = f"slug pinned: {new}"
        if slug:
            msg += f"  (was {slug} — RECORDS DID NOT CARRY OVER, reconcile before anyone answers again)"
        print(msg)
    else:
        print(f"slug reused: {slug} (records preserved)")

    if a.lock:
        pub.req("PATCH", f"{pub.API}/api/v1/publish/{new}/metadata", key, {"password": lock_pw})
        print(f"locked (category password: {a.category})")

    pub.mount(cfg, key, a.path, new)

    # The index is the front door to every explainer. Whether it should be gated is a
    # judgement recorded in the config (passwords.index set => expected to be locked);
    # warn only when the live state disagrees with that intent, so a silent flip in
    # either direction is caught but a deliberate lock is not nagged about.
    try:
        pol = pub.req("GET", f"{pub.API}/api/v1/publish/{cfg['index_slug']}/access", key)
        mode = (pol.get("access") or {}).get("mode")
        want_locked = bool((cfg.get("passwords") or {}).get("index"))
        is_locked = mode not in (None, "anyone_with_link")
        if want_locked and not is_locked:
            print(f"WARNING: index {cfg['index_slug']} is OPEN ('{mode}') but the config expects it "
                  f"locked. Every explainer title and description is public. Re-lock with:\n"
                  f"  curl -X PATCH {pub.API}/api/v1/publish/{cfg['index_slug']}/metadata "
                  f"-H \"Authorization: Bearer $HERENOW_API_KEY\" -H 'content-type: application/json' "
                  f"-d '{{\"password\":\"<passwords.index>\"}}'", file=sys.stderr)
        elif is_locked and not want_locked:
            print(f"WARNING: index {cfg['index_slug']} is locked ('{mode}') but no passwords.index is "
                  f"set in the config. Record the password there or clear the lock.", file=sys.stderr)
    except Exception as ex:
        print(f"note: could not read index access policy ({ex})", file=sys.stderr)

    html, data = pub.fetch_index(cfg, key)
    verb = pub.upsert_entry(data, {"path": a.path, "title": a.title, "desc": a.desc,
                                   "date": a.date, "locked": a.lock, "cat": a.category})
    pub.save_index(cfg, key, html, data)
    print(f"index: {verb} /{a.path}/")
    print(f"live (KV lag <=60s): https://{cfg['domain']}/{a.path}/")


if __name__ == "__main__":
    main()
