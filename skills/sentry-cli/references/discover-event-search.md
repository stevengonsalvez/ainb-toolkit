# Discover Event Search via Sentry API

Use this when issue search is too coarse and incident needs exact user/session evidence: URL sequence, event IDs, breadcrumbs, fetch status, transaction, or user identifiers.

## Why

`sentry issue list` finds grouped issues, not necessarily latest individual events for one user. `sentry api` does authenticated Discover/Event API calls, but query parameters must live in URL. There is no `sentry api --query` flag.

## Recipe

1. Find numeric project ID if needed:

```bash
sentry project view <org>/<project> --json | jq '.id'
```

2. Search events with explicit fields:

```bash
python3 - <<'PY'
import json, subprocess, urllib.parse
org='my-org'
project_id='123456'
query='user.email:person@example.com ("Auth recovery failed" OR AbortError OR url:/perform)'
fields=['id','timestamp','title','message','transaction','user.display']
endpoint=(f'/organizations/{org}/events/?project={project_id}&environment=production&per_page=20&'
          + '&'.join(f'field={f}' for f in fields)
          + '&query=' + urllib.parse.quote(query))
r=subprocess.run(['sentry','api',endpoint],text=True,capture_output=True,check=True)
for e in json.loads(r.stdout).get('data',[]):
    print(e.get('timestamp'), e.get('user.display'), e.get('transaction'), e.get('title'), e.get('message'), e.get('id'))
PY
```

3. Fetch exact event details:

```bash
sentry api /projects/<org>/<project>/events/<event-id>/ > /tmp/event.json
```

4. Extract user, key tags, recent breadcrumbs, and exception frames:

```bash
python3 - <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print('user', d.get('user'))
print('tags', [(t.get('key'), t.get('value')) for t in d.get('tags', []) if t.get('key') in ['url','transaction','browser','os','environment','release','level']])
for ent in d.get('entries', []):
    if ent.get('type') == 'breadcrumbs':
        vals = ent.get('data', {}).get('values', [])
        for c in vals[-30:]:
            data = c.get('data') or {}
            keep = {k:data.get(k) for k in ['status','status_code','path','method','ms','url'] if k in data}
            print(c.get('timestamp'), c.get('level'), c.get('category'), c.get('message'), keep)
    if ent.get('type') == 'exception':
        for v in ent.get('data', {}).get('values', []):
            print(v.get('type'), v.get('value'))
            for fr in (v.get('stacktrace', {}).get('frames') or [])[-12:]:
                print(fr.get('filename'), fr.get('function'), fr.get('lineno'), fr.get('colno'))
PY /tmp/event.json
```

## Incident reading pattern

- User-specific forced logout evidence: search `user.email:<email> "Auth recovery failed"` and fetch event JSON.
- Route-to-login evidence: compare event `transaction`, tag `url`, and breadcrumbs around navigation/auth state.
- Abort noise: `AbortError: signal is aborted without reason` with stack frames through deliberate abort helpers may be caller cancellation, not logout. Confirm via breadcrumbs and code before calling it root cause.
- If project asks for PostHog too and no PostHog token is present, state that PostHog is blocked by missing credential; do not imply replay checked.
