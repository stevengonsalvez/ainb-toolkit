# Decision capture — interview-style questions inside an explainer

Turns a read-only explainer into a page people **answer on**. Options with a marked
recommendation, one click to choose, answers stored server-side and readable back by
an agent. No backend, no database to run, no API key in the page.

Built on **here.now Site Data**: a published Site declares collections in a
`.herenow/data.json` manifest, and the page reads and writes them from browser JS
against a *relative* URL on its own origin.

## When to use

Use it when the explainer's job is to get a decision made, not just understood:
options papers, triage of a backlog, a plan someone must approve, anything where the
honest last line is "which of these do you want?".

Do NOT bolt it onto a pure reference page. A page nobody has to answer should stay
static — the controls are noise.

---

## THE TRAP: read this before anything else

`scripts/publish_explainer.py` calls `publish_site(files, key)` with **`slug=None`**,
which POSTs `/api/v1/publish` and **mints a brand-new Site every single run**. The
mount is then repointed at the new slug, so the URL looks stable while the slug
underneath changes on every republish.

**Site Data records are scoped to a slug.** So with the default publisher:

```
publish  -> slug A -> visitor records 6 decisions into slug A
republish-> slug B -> page now reads slug B -> ZERO records. Silently.
```

Nothing errors. The page just shows an empty log and the decisions are stranded on a
slug nothing points at any more.

**Always publish an interactive explainer with `scripts/publish_interactive.py`**,
which pins the slug in `~/.herenow/<name>-slug` and PUTs to it. It prints
`slug reused: <slug> (records preserved)` — if it ever prints `slug pinned:` with a
`RECORDS DID NOT CARRY OVER` warning, stop and reconcile before anyone answers again.

---

## Build flow

```
┌──────────────┐   ┌──────────────────┐   ┌───────────────┐
│ browser page │──▶│ ./.herenow/data/ │──▶│ Site Data     │
│ (no API key) │   │ <collection>     │   │ validated     │
└──────────────┘   └──────────────────┘   └───────┬───────┘
   same-origin          Origin-checked            │
   relative URL         rate-limited        owner API + key
                                                  ▼
                                            agent reads back
```

1. Copy `assets/decision-data.json` to `<sitedir>/.herenow/data.json` and edit the fields.
2. Copy `assets/decision-widget.css` into the page's `<style>`, `assets/decision-widget.js`
   into a `<script>` at the end of `<body>`.
3. Emit a `.decision` block per question and (optionally) a `.feedback` block per item.
4. Publish with `scripts/publish_interactive.py <file.html> --name <pin-name> --path <mount>`.
5. Read answers back with `scripts/read_decisions.py --name <pin-name>`.

## Manifest

Up to **10 collections**, **50 fields** each. Collection and field names must match
`^[a-z][a-z0-9_]*$`, max 64 chars.

Field types: `string`, `number`, `integer`, `boolean`, `url`, `email`, `datetime`,
`array`, `object`. String/array/object take size caps; number/integer take
`minimum`/`maximum`; url takes `allowedProtocols`.

**Reserved field names — do not declare these:** `id`, `site_slug`, `collection`,
`data`, `status`, `created_at`, `updated_at`, `created_by_account_id`. `created_at`
is stamped for you, so never add your own timestamp field.

### Access

Per action, one of `public` / `owner` / `none`. Defaults are read `public`,
insert/update/delete `owner`.

- Public writes require the request `Origin` to match the Site origin, so another
  site cannot post into your collection.
- Public `update`/`delete` are opt-in **twice**: set the action to `public` *and*
  set `publicMutation: "open"`.
- **Keep collections insert-only.** An append log means nobody can quietly rewrite
  someone else's decision, and the newest record per item is the standing answer.
  Correcting a decision = recording a new one, which is the audit trail you want.
- Always set `rateLimit` (e.g. `"60/hour/ip"`).

## Browser API

Endpoints are **relative to the published page**, never to `https://here.now`. Use a
relative URL so the same page works on the slug URL, a handle, a custom domain, and a
mounted path.

```js
// list (paginate with nextCursor)
const r = await fetch('./.herenow/data/decisions?limit=100');
const { records, nextCursor } = await r.json();

// create — Idempotency-Key makes a retried submit safe
await fetch('./.herenow/data/decisions', {
  method: 'POST',
  headers: { 'content-type': 'application/json', 'Idempotency-Key': crypto.randomUUID() },
  body: JSON.stringify({ item: 'B4', choice: 'A', who: 'liam', note: '' })
});
```

Create and read return `{ record }`; list returns `{ records, nextCursor }`. Errors
carry `code`, `message`, and sometimes `retry_after`.

### Password-protected Sites

The data endpoints sit behind the same password gate as the page. A visitor who has
entered the password holds the session cookie, and the fetch is same-origin, so the
cookie rides along and the calls just work. Verified: unlock → `GET` 200 → `POST` 201.

`curl` without that cookie gets 401 on the data endpoints — that is expected, not a
bug. To test from a shell, POST the password to `/` with a cookie jar first:

```bash
curl -s -c jar.txt -X POST "https://<slug>.here.now/" --data-urlencode "password=$PW"
curl -s -b jar.txt "https://<slug>.here.now/.herenow/data/decisions?limit=5"
```

## Reading answers back (agent side)

Owner API, needs the API key, talks to `https://here.now`:

```
GET    /api/v1/publishes/:slug/data/:collection?limit=100&cursor=…
POST   /api/v1/publishes/:slug/data/:collection
GET    /api/v1/publishes/:slug/data/:collection/:recordId
PATCH  /api/v1/publishes/:slug/data/:collection/:recordId
DELETE /api/v1/publishes/:slug/data/:collection/:recordId
```

`scripts/read_decisions.py` wraps the list calls and prints the newest answer per item.
Signed-in owners can also use the dashboard: a Site's Manage view → Database section.

## Identity

The shared password is **access control, not identity** — every answer is pseudonymous
unless the page asks for a name, and a typed name is self-declared and unverifiable.
Say so plainly when you hand over the page; do not let a decision log imply more
provenance than it has.

For real identity, switch the Site to restricted access and invite people by email —
each person then authenticates as themselves, no account needed:

```
GET/PATCH /api/v1/publish/:slug/access        # mode: restricted, email allowlist
POST      /api/v1/publish/:slug/access/invites
```

`PATCH` **replaces** the whole allowlist: read, merge, then write.

---

## Every decision gets a figure

A decision presented as prose plus radio buttons gets skimmed. **Lead each decision
with a rendered figure that shows why the decision exists**, then the options.

Inline SVG is the default — it needs no library, survives the static host, and prints.
Mermaid is fine where the renderer supports it (GitHub does natively; on a here.now
page it needs `mermaid` from cdnjs), but never make the argument depend on a script
that may not load.

The figure must carry the *evidence*, not decoration. The pattern that works:

```
┌──────────────┐        relationship        ┌──────────────┐
│  OPTION A    │ ·········  ✗  ···········▶ │  OPTION B    │
│  what it is  │      why it is broken      │  what it is  │
└──────┬───────┘                            └──────┬───────┘
       ▼                                           ▼
┌──────────────┐                            ┌──────────────┐
│ real numbers │                            │ real numbers │
│ measured     │                            │ measured     │
└──────────────┘                            └──────────────┘
┌────────────────────────────────────────────────────────────┐
│        the one sentence that forces the decision           │
└────────────────────────────────────────────────────────────┘
```

Rules that make it read as evidence rather than an illustration:

- **Real measured numbers only**, with the date measured. Never a placeholder, never
  a rounded guess. A figure with invented numbers is worse than no figure.
- **Colour carries meaning**: clay `#D97757` / `#B85C3E` for the side that is failing
  or the zero that matters, olive `#788C5D` for the healthy side, grey `#87867F` for
  context. Do not colour for variety.
- **The banner at the bottom states the cost of not deciding**, in one sentence, with
  the number in it.
- Give the `<svg>` a `viewBox` with room for outermost labels, an explicit `fill` on
  every shape, and a real `role="img"` + `aria-label` describing the finding.
- Mono type for figures and identifiers, serif for the box titles — same as the
  templates.

Skeleton to fill: `assets/decision-figure-template.svg` — replace every uppercase slot.
