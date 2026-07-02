---
name: explain-to-me
description: |
  Produce a self-contained, richly styled HTML explainer for any topic the
  user asks about. Picks the right template from a bundled set of 22
  visual patterns (feature explainer, concept explainer, module map, PR
  review, ADR, options paper / trade-off analysis, system diagram, flow-
  chart, status report, slide deck, prototype, editor, etc.), fills it
  with real content, augments with inline diagrams via sister skills
  (/fireworks-tech-graph for architecture / flow / sequence diagrams,
  /graphify for knowledge graphs), applies a Claude-brand polish layer,
  and publishes it: by default onto the configured here.now custom
  domain (path mount + searchable categorised index + password lock
  per the config's protect rule, driven by ~/.herenow/explainers.json),
  or a plain here.now URL, or a GitHub gist (--gist / --gist --public).
  Local-only output is available with --local. Use when Stevie says
  "/explain-to-me", "explain-to-me X", "make me an explainer for X",
  "give me an HTML explainer", "render this as a webpage", "ADR for X",
  "options paper for X", or asks for a rich visual writeup. The skill
  picks the template, names the choice up-front, and reaches for
  diagrams whenever the content shape needs them.
argument-hint: "[topic — e.g. 'how rate limiting works in our api'] [--local] [--gist [--public]]"
---

# /explain-to-me — rich HTML explainers

Turn a topic into ONE self-contained HTML file, Claude-branded, using the
best-fit bundled template, then publish it and return a shareable URL.

**Fixed constraints (do not violate):**
- Palette is fixed: `#FAF9F5` ivory, `#141413` slate, `#D97757` clay, `#E3DACC` oat, `#788C5D` olive. Do not rewrite CSS variables unless the user explicitly asks for a different look.
- ONE template per output. Never merge two templates.
- Static HTML only — inline `<style>` + inline `<script>`. No framework, no build. (User wants React → that's `frontend-engineer`, not this skill.)
- Strip regions you can't fill with real content. A 3-section real explainer beats a 7-section half-fake one.
- Never invent file paths, line numbers, or commit hashes to fill a citation region — drop the region instead.

## When NOT to use

- User asks whether this skill *exists* / is available → that is a capability check. Use `/explain-to-me` to explain the requested topic. Do NOT copy, move, install, or canonicalize the skill into the repo. Only package/consolidate the skill when the user explicitly asks for skill packaging.
- User wants a React/component app → use `frontend-engineer`.

## Runbook

### 1. Lock topic + template

1. Topic = `$ARGUMENTS` if non-empty. Else ask ONE `AskUserQuestion`: "What should I explain? One line."
2. Classify the topic against the table below and pick EXACTLY ONE template. `★` = visual-first; when two fit, prefer `★` unless the topic is intrinsically prose-heavy.

| Topic shape | Template (in `assets/templates/`) | Visual |
|---|---|---|
| Architecture / design decision with options + rationale | `21-adr.html` | ★ |
| Options paper / trade-off analysis (no decision yet) | `22-options-paper.html` | ★ |
| Implementation plan with milestones + diagrams | `16-implementation-plan.html` | ★ |
| Pipeline / process flowchart | `13-flowchart-diagram.html` | ★ |
| Mental model of an unfamiliar repo/module | `04-code-understanding.html` | ★ |
| Inline SVG figure sheet | `10-svg-illustrations.html` | ★ |
| Abstract concept / algorithm with interactive demo | `15-research-concept-explainer.html` | ★ |
| Concrete feature in a codebase ("how X works in repo Y") | `14-research-feature-explainer.html` | |
| PR review (reviewer perspective) | `03-code-review-pr.html` | |
| PR writeup (author perspective) | `17-pr-writeup.html` | |
| N approaches compared (code) | `01-exploration-code-approaches.html` | |
| N visual directions compared | `02-exploration-visual-designs.html` | ★ |
| Weekly / sprint status | `11-status-report.html` | ★ |
| Incident post-mortem | `12-incident-report.html` | ★ |
| Component variant matrix | `06-component-variants.html` | ★ |
| Design system reference | `05-design-system.html` | ★ |
| Animation / micro-interaction demo | `07-prototype-animation.html` | ★ |
| Multi-screen clickable prototype | `08-prototype-interaction.html` | |
| Slide deck (arrow-key, one file) | `09-slide-deck.html` | |
| Ticket triage / kanban | `18-editor-triage-board.html` | |
| Feature flag editor | `19-editor-feature-flags.html` | |
| Prompt template tuner | `20-editor-prompt-tuner.html` | |

If the topic doesn't cleanly match, or you need each template's interactive elements → read [`references/template-catalog.md`](references/template-catalog.md).

**Extra source-pass references — load only when the topic matches:**

| Topic | Load |
|---|---|
| Sourced options paper on agent memory / learning architectures | [`references/sourced-options-paper-memory-systems.md`](references/sourced-options-paper-memory-systems.md) |
| Architecture consolidation paper built from source inspection | [`references/architecture-options-paper-from-source.md`](references/architecture-options-paper-from-source.md) |
| Reflect / Fleet / BANK explainer or deep dive | [`references/reflect-fleet-bank-deep-dive.md`](references/reflect-fleet-bank-deep-dive.md) |

Decision rule for memory-architecture papers: do NOT recommend two active memory substrates unless one is explicitly being retired (split-brain memory = operational waste). Keep the memory substrate separate from the deterministic control/governance plane.

### 2. Announce the choice (one line, before generating)

Tell Stevie the template and why, so a wrong pick can be redirected before you spend tokens. Format:

> Picking `21-adr.html` — you described a decision with options and rationale; this template gives status badge, options cards with pros/cons + score bars, decision callout, and resulting architecture diagram.

### 3. Gather real content

Treat the template as the SHAPE. For each named region (TL;DR, steps, options, scores, FAQ, glossary, timeline, consequences…), fill with real content from: current repo files → prior conversation → your own knowledge. Drop any region you can't fill honestly.

### 4. Augment with diagrams (only when load-bearing)

If a template has a big-diagram slot and the diagram carries real weight, generate it via a sister skill instead of hand-drawing SVG:

| Diagram need | Skill | Output |
|---|---|---|
| Architecture · data flow · sequence · agent/memory · concept map | `/fireworks-tech-graph` | SVG + PNG (drop SVG inline) |
| Knowledge graph from code/docs/papers (clustered) | `/graphify` | HTML / JSON / SVG |

Steps: (1) pick the region needing the diagram; (2) invoke the skill with a tight prompt (boxes, arrows, labels) asking for inlineable SVG; (3) replace the placeholder SVG, keeping the outer `<svg>` `viewBox`/sizing so layout holds; (4) cite the generator at the section bottom.

Do NOT delegate small bespoke SVG (icons, hero glyphs) — author inline. Do NOT replace the intentionally sketch-like mini-architecture SVGs in ADR option cards.

### 5. Render

1. Copy the chosen template from `assets/templates/<name>.html` to `./explainers/<slug>.html` (create `./explainers/` if missing). `<slug>` = hyphen-case of the topic; it names the LOCAL file only — the here.now URL is server-assigned and will differ.
2. Update `<title>`, `.eyebrow` text, and `h1`.
3. Replace all placeholder content (acme/*, ADR-0023, PR #247, "rate limiting" strings, sample names) with the real topic.
4. Strip regions you couldn't fill. No file paths for the nav rail → delete the `nav .files` block.
5. Inject the Claude theme — from the skill directory run:
   ```
   python3 scripts/inject_theme.py ./explainers/<slug>.html
   ```
   Inserts `assets/claude-theme.css` as a second `<style>` block (`data-claude-theme="injected"`) after the template's `</style>`. Idempotent; touches only typography, focus states, and the brand badge — layout untouched.
6. Preserve every `<script>` block verbatim unless you're changing the demo's data shape.

Expected: valid HTML at `./explainers/<slug>.html` with the injected theme block. If `./explainers/` can't be written (read-only cwd) → write to `$CLAUDE_JOB_DIR` (or `/tmp`) and report the absolute path.

### 6. Publish

The local file is always written. The flag picks the target:

| Flag | Target |
|---|---|
| `--local` | Stop after writing the file. |
| `--gist` (opt `--public`) | GitHub gist (secret by default). See publishing reference. |
| (none, config present) | here.now domain mode — publish + password-lock per `protect_rule` + mount on custom domain + append to searchable index. |
| (none, no config) | Plain 3-word here.now URL, then offer one-time config setup once per session (template: `assets/explainers.template.json`); drop it if declined. |

**Read [`references/publishing.md`](references/publishing.md) before publishing** — config schema, per-target pipelines, bootstrap flow, troubleshooting.

For here.now domain mode, the whole pipeline is one script:

```
python3 scripts/publish_explainer.py ./explainers/<slug>.html \
  --path <mount-path-≤30-chars> --title "<title>" --desc "<one-liner>" \
  --category <key-from-config> [--lock]
```

Your judgment: pick `--path` and `--category`; evaluate the config's `protect_rule` against the content to decide `--lock`. When ambiguous → lock and say so (unlocking is one PATCH). The script handles publish, password, mount/repoint, and append-only upsert into the live index `data.json` (never clobbers other entries).

**Publish failure branches:**
- Any publish error → fall back to local-only, surface the path, tell Stevie what happened. Never claim you published when you didn't.
- `Not found` after passing `--slug` on a FIRST publish → `--slug` means *update existing slug*, not *choose a URL*. Omit `--slug` on first publish; let the server assign one. Use `--slug` only with `--claim-token` for a deliberate rename.
- `Unauthorized. Provide claimToken to update anonymous site` → you can't update that slug. Create a new publish without `--slug` unless you hold the claim token.

### 7. Hand off — report in this EXACT shape

> **Explainer ready.**
> - Template: `21-adr.html` — *why this one*
> - Local: `./explainers/<slug>.html`
> - Live: `https://<domain>/<path>/`  *(or `https://<slug>.here.now`, gist link, or "skipped, --local")*
> - Index: added under `<category>` · locked/open  *(herenow-domain only)*
> - Diagrams: from /fireworks-tech-graph  *(omit line if none)*

On herenow-domain, ALWAYS state whether the page was locked and the `protect_rule` clause that matched (or "no rule matched — open"). Silence is how sensitive pages leak public.

## Gotchas

- **Verifying a here.now page:** never `curl URL | python3 - <<'PY'` — the heredoc eats stdin so Python sees an empty page and reports a false failure. Instead `curl -o "$tmp" URL`, then read `$tmp` in Python.
- **Never regenerate/hand-edit the domain index page.** It's data-driven; `publish_explainer.py` upserts into `data.json`. Rebuilding index.html loses the other 80+ entries.
- **Never paste the here.now token into chat or config.** It lives only in `~/.herenow/credentials` (0600). If Stevie pastes one, save it there and don't echo it.
- **Output goes in the user's cwd `./explainers/`, never inside the toolkit repo.**
