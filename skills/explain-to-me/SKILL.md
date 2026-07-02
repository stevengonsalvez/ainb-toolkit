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

## What it does

Takes a topic (a feature, a concept, a decision, a plan, an incident, …)
and produces a single self-contained HTML file styled in Claude's brand,
using whichever bundled template best fits the topic's shape. By default
it then publishes the file via `/here-now` and returns the shareable URL.

All 22 templates use Claude's palette (`#FAF9F5` ivory, `#141413` slate,
`#D97757` clay, `#E3DACC` oat, `#788C5D` olive). The skill applies
[`assets/claude-theme.css`](assets/claude-theme.css) on top for typography +
brand badge.

## Trigger

- `/explain-to-me <topic>` — primary (publishes per `~/.herenow/explainers.json`)
- `/explain-to-me <topic> --local` — skip publishing, just write the file
- `/explain-to-me <topic> --gist [--public]` — publish as gist (secret by default)
- `/explain-to-me` (no args) — ask the user what to explain
- Natural language: "explain X to me as a webpage", "make an HTML
  explainer for X", "render this concept as HTML", "ADR for choosing X",
  "options paper on Y", "give me a visual writeup of Z"

## Flow

### 1. Lock the topic and intent

If `$ARGUMENTS` is non-empty, use it as the topic. Otherwise ask one
question via `AskUserQuestion`: "What should I explain? One line."

Then classify the topic against this table — this drives template
choice. **Pick exactly one template; do not merge.**

Templates are tagged **★** when they are visual-first (diagrams, charts,
SVG flows). When two templates fit, prefer the **★** one unless the
topic is intrinsically prose-heavy.

| Topic shape | Template | Visual |
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

Full per-template detail lives in [`references/template-catalog.md`](references/template-catalog.md).
Read it only when the topic doesn't cleanly match, or you need to know
which interactive elements a template ships with.

For sourced options papers comparing agent memory / learning architectures,
load [`references/sourced-options-paper-memory-systems.md`](references/sourced-options-paper-memory-systems.md)
and apply its required source pass: inspect local implementation, inspect
external docs/integration code, include token economics, observability,
correction, self-improvement, and a decision rule. Decision rule for Stevie:
avoid recommending two active memory substrates unless one is explicitly
being retired; split-brain memory is operational waste. Separate memory
substrate from deterministic control plane/governance hooks.

For architecture consolidation papers built from source inspection, load
[`references/architecture-options-paper-from-source.md`](references/architecture-options-paper-from-source.md).
It captures the proven shape: current A diagram, current B diagram,
proposed consolidated diagram, explicit gap table, and first-section
recommendation. For agent memory/governance consolidation specifically,
apply the Reflect/Fleet plane split: storage/retrieval hooks consolidate
into the memory substrate; governance/control hooks remain deterministic
law.

For Reflect/Fleet/BANK explainers or updates, also load
[`references/reflect-fleet-bank-deep-dive.md`](references/reflect-fleet-bank-deep-dive.md).
Do a full artifact inventory, not only the slogan. Cover corrections,
pending correction debt, patterns, discoveries, archives, strikes/HOT
promotion, journals, skills, inbox state, ACP/loop control,
manifest/worktree gates, and sleep-cycle policy. If the user asks for
"new tab", "deep dive", or "more comprehensive", add a hash-linkable
HTML tab plus coverage matrix and migration/acceptance gates.

### 1.5 Announce the choice

### 1.5 Announce the choice

Before generating anything, tell Stevie which template you picked and
why, in one line:

> Picking `21-adr.html` — you described a decision with options and
> rationale; this template gives you status badge, options cards with
> pros/cons + score bars, decision callout, and resulting architecture
> diagram.

This is a transparency step. If the choice is wrong, Stevie can redirect
before you spend tokens generating content.

### 2. Gather content

Treat the template as the *shape* of the answer. For each named region
in the template (TL;DR, steps, options, scores, FAQ, glossary, timeline,
consequences, etc.), produce real content for the user's topic. Pull
from:

- Files in the current repo (for code/feature/PR/ADR templates)
- The user's prior conversation
- Your own knowledge of the concept

Do not invent file paths or commit hashes. If a region of the template
expects a concrete artifact you don't have, drop the region rather
than fake it.

### 3. Augment with visual sister skills

Many templates have a *big diagram* slot. If the topic is technical and
the diagram would carry real weight, generate one inline via a sister
skill rather than hand-drawing SVG:

| Diagram need | Reach for | Output |
|---|---|---|
| Architecture · data flow · sequence · agent/memory · concept map | `/fireworks-tech-graph` | SVG + PNG (drop SVG inline) |
| Knowledge graph from code/docs/papers — clustered, communities | `/graphify` | HTML / JSON / SVG |

For small bespoke SVG (decorative icons, hero glyphs, simple
illustrations) — author the inline SVG directly. You're capable of it
and it keeps the file self-contained.

Workflow:

1. Decide which template region needs the diagram (e.g. ADR step 04
   "Resulting architecture"; concept-explainer's hero figure;
   implementation-plan's data-flow block).
2. Invoke the sister skill with a tight prompt describing exactly the
   diagram you want (boxes, arrows, labels). Tell it to return an
   inlineable SVG when possible.
3. Replace the template's placeholder SVG with the generated one.
   Keep the `viewBox` and outer `<svg>` wrapper sizing so the layout
   doesn't shift.
4. Cite the generator at the bottom of the section (e.g. "diagram
   generated via /fireworks-tech-graph").

Use this only when the diagram is load-bearing. Don't replace the small
mini-architecture SVGs in ADR option cards — those are intentionally
sketch-like to read at a glance.

### 4. Render

1. **Copy** the chosen template to `./explainers/<slug>.html` (create
   `./explainers/` if missing). `<slug>` is hyphen-case of the topic
   and identifies the *local file only*. The here.now URL is
   server-assigned (see §5) — they do not match.
2. **Update** the `<title>`, the `.eyebrow` text, and the `h1`.
3. **Replace** placeholder content (acme/*, ADR-0023, PR #247, "rate
   limiting" strings, sample names) with the user's real topic.
4. **Strip** any region that you couldn't fill — better to ship a
   shorter explainer than a fake one. Don't invent file paths to fill
   the nav rail; if there are none, delete the `nav .files` block.
5. **Inject the Claude theme** by running
   `scripts/inject_theme.py <output.html>` from the skill directory.
   The script inserts `assets/claude-theme.css` as a second `<style>`
   block (marked `data-claude-theme="injected"`) right after the
   template's existing `</style>`, and is idempotent on re-runs. The
   overlay only touches typography, focus states, and adds the brand
   badge — layout untouched.
6. **Preserve** every `<script>` block verbatim unless changing the
   demo's data shape.

### 5. Publish (config-driven)

Three targets — the flag picks; the local file is written in all cases:

1. `--local` → stop after writing the file.
2. `--gist` (optionally `--public`) → gist.
3. Default → **here.now**:
   - `~/.herenow/explainers.json` exists → domain mode: publish +
     password-lock per its protect rule + mount on the custom domain +
     append to the searchable index.
   - no config → plain 3-word URL, then offer the one-time config
     setup (bootstrap flow in the reference; template ships at
     `assets/explainers.template.json`). Ask once per session, drop it
     if declined.

**Load [`references/publishing.md`](references/publishing.md) before
publishing** — it has the config schema, per-target pipelines, the
bootstrap flow, and troubleshooting.

For `herenow-domain`, the whole pipeline is one tested script:

```
python3 scripts/publish_explainer.py ./explainers/<slug>.html \
  --path <mount-path-≤30-chars> --title "<title>" --desc "<one-liner>" \
  --category <key-from-config> [--lock]
```

Judgment stays with you: pick `--path` and `--category`, and evaluate
the config's `protect_rule` against the content to decide `--lock`
(when ambiguous: lock and say so — unlocking is one PATCH). The script
handles mechanics: publish, password, mount/repoint, and **append-only
upsert** into the live index's `data.json` — it never clobbers other
entries.

For the no-config here.now flow and gist details (including
`publish.sh` slug semantics and gist rendered-preview links), see the
reference.

If publishing fails, fall back to local-only and surface the path.
Tell Stevie what happened — don't pretend you published.

### 6. Hand off

Report to Stevie in this exact shape:

> **Explainer ready.**
> - Template: `21-adr.html` — *why this one*
> - Local: `./explainers/<slug>.html`
> - Live: `https://<domain>/<path>/`  *(or `https://<slug>.here.now`, gist link, or "skipped, --local")*
> - Index: added under `<category>` · locked/open  *(herenow-domain only)*
> - Diagrams: from /fireworks-tech-graph  *(omit line if none)*

On `herenow-domain`, always state whether the page was locked and why
(the `protect_rule` clause that matched, or "no rule matched — open").

## Customisation rules

- **Palette is fixed.** The templates *are* the Claude theme. Don't
  rewrite the CSS variables unless the user explicitly asks for a
  different look.
- **One template per output.** Do not merge two templates into one
  page; pick the better fit and commit.
- **No framework, no build.** Static HTML + inline `<style>` +
  inline `<script>`. If the user wants React, that's a different
  skill (`frontend-engineer`).
- **Strip, don't pad.** A 3-section explainer that's all real beats
  a 7-section one that's half fake.
- **Visual over textual.** When the topic admits a diagram, generate
  one via a sister skill rather than describing the architecture in
  prose.

## Anti-patterns (and the fix)

- **Picking a template by aesthetic, not by topic shape.** The reader
  gets a pretty page that doesn't fit the content. → Re-read the
  selection table and pick the closest shape; the styling is identical
  across all 22 anyway.
- **Inventing file paths / line numbers / commit hashes** to fill
  citations the template expects. → Drop the citation region.
- **Skipping the theme overlay** because "it already looks Claude-y".
  The overlay adds the brand badge and the focus ring — keep it.
- **Skipping the publish step** silently. → If `/here-now` fails, say
  so explicitly. Don't return only a local path when Stevie expected
  a URL.
- **Passing `--slug` on a first publish.** That flag means *update an
existing publish at this slug*, not *choose a URL*. The server
returns `Not found` and the agent often misreads it as a real
failure. → Omit `--slug` on first publish; let the server assign a
three-word slug. Only use `--slug` together with `--claim-token`
for a deliberate rename. If the update returns `Unauthorized. Provide claimToken to update anonymous site`, you are not authorized to update that slug; create a new publish without `--slug` unless you have the claim token.
- **Regenerating or hand-editing the domain index page.** The index is
  data-driven (`data.json`); `publish_explainer.py` upserts entries.
  Rebuilding index.html from scratch loses the other 80+ entries. →
  Only ever touch the index through the script.
- **Pasting the here.now token into chat or config.** Token lives in
  `~/.herenow/credentials` (0600) only. If Stevie pastes one, save it
  there and don't echo it.
- **Skipping the lock decision.** Every herenow-domain publish must
  evaluate the config `protect_rule` — silence is how sensitive pages
  end up public. State the verdict in the hand-off.
- **Hand-drawing a complex SVG architecture diagram** when
  `/fireworks-tech-graph` could produce a cleaner one. → Delegate.
- **Verifying a here.now page with `curl URL | python3 - <<'PY'`.** The heredoc consumes stdin, so Python sees empty page content and can report false failure. → `curl -o "$tmp" URL`, then have Python read the temp file.
- **Putting the output inside the toolkit repo.** Always write to the
  user's current working directory under `./explainers/`.
- **Treating this skill as a deliverable because Stevie asked whether it is available.**
  A capability check means use `/explain-to-me` to explain the topic, not copy the skill into the repo or canonicalize it. Only move/install this skill when the user explicitly asks for skill packaging or consolidation.

## Output location

- Default: `./explainers/<slug>.html` relative to the user's cwd
  (where `<slug>` is the local file slug). Published to a
  server-assigned URL `https://<three-word-slug>.here.now/` — not
  derived from the local filename.
- `--local`: skip the publish; just leave the file at the path above.
- If `./explainers/` is awkward (e.g. the cwd is read-only), put the
  file in `$CLAUDE_JOB_DIR` (or `/tmp`) and tell the user the
  absolute path.
