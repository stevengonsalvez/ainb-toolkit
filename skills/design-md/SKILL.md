---
name: design-md
description: Analyze Stitch projects and synthesize a semantic design system into DESIGN.md files
allowed-tools:
  - "stitch*:*"
  - "Read"
  - "Write"
  - "web_fetch"
---

# Stitch DESIGN.md Skill

You are an expert Design Systems Lead. Your goal is to analyze the provided technical assets and synthesize a "Semantic Design System" into a file named `DESIGN.md`.

## Overview

This skill helps you create `DESIGN.md` files that serve as the "source of truth" for prompting Stitch to generate new screens that align perfectly with existing design language. Stitch interprets design through "Visual Descriptions" supported by specific color values.

## Prerequisites

- Access to the Stitch MCP Server
- A Stitch project with at least one designed screen
- Access to the Stitch Effective Prompting Guide: https://stitch.withgoogle.com/docs/learn/prompting/

## The Goal

The `DESIGN.md` file will serve as the "source of truth" for prompting Stitch to generate new screens that align perfectly with the existing design language. Stitch interprets design through "Visual Descriptions" supported by specific color values.

## Retrieval and Networking

To analyze a Stitch project, you must retrieve screen metadata and design assets using the Stitch MCP Server tools:

1. **Namespace discovery**: Run `list_tools` to find the Stitch MCP prefix. Use this prefix (e.g., `mcp_stitch:`) for all subsequent calls.

2. **Project lookup** (if Project ID is not provided):
   - Call `[prefix]:list_projects` with `filter: "view=owned"` to retrieve all user projects
   - Identify the target project by title or URL pattern
   - Extract the Project ID from the `name` field (e.g., `projects/13534454087919359824`)

3. **Screen lookup** (if Screen ID is not provided):
   - Call `[prefix]:list_screens` with the `projectId` (just the numeric ID, not the full path)
   - Review screen titles to identify the target screen (e.g., "Home", "Landing Page")
   - Extract the Screen ID from the screen's `name` field

4. **Metadata fetch**: 
   - Call `[prefix]:get_screen` with both `projectId` and `screenId` (both as numeric IDs only)
   - This returns the complete screen object including:
     - `screenshot.downloadUrl` - Visual reference of the design
     - `htmlCode.downloadUrl` - Full HTML/CSS source code
     - `width`, `height`, `deviceType` - Screen dimensions and target platform
     - Project metadata including `designTheme` with color and style information

5. **Asset download**:
   - Use `web_fetch` or `read_url_content` to download the HTML code from `htmlCode.downloadUrl`
   - Optionally download the screenshot from `screenshot.downloadUrl` for visual reference
   - Parse the HTML to extract Tailwind classes, custom CSS, and component patterns

6. **Project metadata extraction**:
   - Call `[prefix]:get_project` with the project `name` (full path: `projects/{id}`) to get:
     - `designTheme` object with color mode, fonts, roundness, custom colors
     - Project-level design guidelines and descriptions
     - Device type preferences and layout principles

## Analysis & Synthesis Instructions

### 1. Extract Project Identity (JSON)
- Locate the Project Title
- Locate the specific Project ID (e.g., from the `name` field in the JSON)

### 2. Define the Atmosphere (Image/HTML)
Evaluate the screenshot and HTML structure to capture the overall "vibe." Use evocative adjectives to describe the mood (e.g., "Airy," "Dense," "Minimalist," "Utilitarian").

### 3. Map the Color Palette (Tailwind Config/JSON)
Identify the key colors in the system. For each color, provide:
- A descriptive, natural language name that conveys its character (e.g., "Deep Muted Teal-Navy")
- The specific hex code in parentheses for precision (e.g., "#294056")
- Its specific functional role (e.g., "Used for primary actions")

### 4. Translate Geometry & Shape (CSS/Tailwind)
Convert technical `border-radius` and layout values into physical descriptions:
- Describe `rounded-full` as "Pill-shaped"
- Describe `rounded-lg` as "Subtly rounded corners"
- Describe `rounded-none` as "Sharp, squared-off edges"

### 5. Describe Depth & Elevation
Explain how the UI handles layers. Describe the presence and quality of shadows (e.g., "Flat," "Whisper-soft diffused shadows," or "Heavy, high-contrast drop shadows").

## Output Guidelines

- **Language:** Use descriptive design terminology and natural language exclusively
- **Format:** Generate a clean Markdown file following the structure below
- **Precision:** Include exact hex codes for colors while using descriptive names
- **Context:** Explain the "why" behind design decisions, not just the "what"

## Output Format (DESIGN.md Structure)

```markdown
# Design System: [Project Title]
**Project ID:** [Insert Project ID Here]

## 1. Visual Theme & Atmosphere
(Description of the mood, density, and aesthetic philosophy.)

## 2. Color Palette & Roles
(List colors by Descriptive Name + Hex Code + Functional Role.)

## 3. Typography Rules
(Description of font family, weight usage for headers vs. body, and letter-spacing character.)

## 4. Component Stylings
* **Buttons:** (Shape description, color assignment, behavior).
* **Cards/Containers:** (Corner roundness description, background color, shadow depth).
* **Inputs/Forms:** (Stroke style, background).

## 5. Layout Principles
(Description of whitespace strategy, margins, and grid alignment.)
```

## Multi-Surface Apps (Stitch-strict + per-surface YAML)

When the app ships **multiple distinct UI surfaces** under one brand (e.g. an editorial hub, a data-dense dashboard, a commerce locker, an AI chat) whose fonts, spacing density, or voice legitimately diverge, do NOT fork into per-surface files and do NOT flatten to a lowest-common-denominator token set. Use this layout inside one canonical `DESIGN.md`:

1. **YAML frontmatter** — global default tokens (colors, typography, rounded, spacing, elevation, components). Stitch / Claude Design read from here.
2. Canonical body sections — Overview, Colors, Typography, Layout, Elevation, Shapes, Components, Do's and Don'ts.
3. **§ Surfaces** — one subsection per surface. Each subsection contains a small **per-surface YAML override block** holding only the deltas (font stack, spacing scale, intentional pillar-color override), a **voice block** for tone, and component aliasing notes.
4. **§ Voice & Tone matrix** — cross-surface comparison.
5. **§ Roadmap / drift** — flag known divergences in the codebase that are *bugs* (e.g. an inverted pillar mapping in one surface) versus *intentional*. Bugs go here, NOT in per-surface overrides — promoting a bug to an override legitimizes it.
6. **§ Agent prompt guide** — explicit rules for Stitch / Claude Design / Cursor on how to read the file.

**Rule of thumb:** frontmatter holds *defaults*, Surfaces holds *deltas*. A token never appears in both.

**Skill-as-pointer corollary:** if a project also has a "visual tokens" skill (`*-brand-ui/SKILL.md`), rewrite it as a thin pointer to DESIGN.md the same day DESIGN.md is canonicalized. The skill keeps code-application rules (CSS-var fallback patterns, framework caveats, anti-patterns like duplicate headers) but stops duplicating tokens. Duplicate tokens drift the moment they exist.

**Anti-patterns specific to multi-surface DESIGN.md:**
- ❌ Splitting into `DESIGN-pulse.md`, `DESIGN-perform.md`, etc. — breaks Stitch / Claude Design which expect one canonical file.
- ❌ Flattening surfaces to one font stack / one spacing scale when product reality is divergent — loses surface character.
- ❌ Encoding bugs as per-surface overrides (e.g. promoting an inverted pillar mapping to a legitimate override block).
- ❌ Keeping the visual-tokens skill as source of truth and DESIGN.md as derivative — agents will prompt against one or the other inconsistently.

## YAML Frontmatter Gotchas

Field-tested while writing the SHOT Clubhouse DESIGN.md (PR #2667). All three issues failed bot review on first pass; encode here so future runs catch them at draft time.

- **Numeric-led keys MUST be quoted.** `"2xl": ...` not `2xl: ...`. YAML 1.1 parses numeric-led tokens ambiguously; PyYAML strict and several agent parsers (Stitch's included) fail without quotes. Same risk for `"3xl"`, `"4xl"`, `"5xl"`, and any spacing key that starts with a digit (`"0"`, `"1"`, …). Verify the whole frontmatter parses cleanly before committing:
  ```bash
  python3 -c "import yaml,sys; yaml.safe_load(open('DESIGN.md').read().split('---')[1]); print('OK')"
  ```

- **Per-surface `fontFamily` overrides need map shape, not string.** When a surface overrides typography, declare the full map: `fontFamily: { heading: "...", body: "..." }`. Assigning a single string collapses the whole map and downstream resolvers bind incorrectly (the `heading` slot ends up holding the entire stack, `body` becomes undefined).

- **Don't self-reference within an override block.** `{surface.pulse.foo}` referenced from inside Pulse's own override block is unresolvable — the override IS the surface block, you can't path back to yourself. Use the literal `inherit` marker (with an explanatory comment), a literal value, or a global token ref (e.g. `{typography.fontFamily.heading}`) that resolves against the frontmatter root.

## Drift Enforcement (parity test pattern)

A drift / roadmap section in DESIGN.md without an enforcing test is theatre — divergences accumulate silently between PRs. Ship one Vitest smoke test + standalone Node script (zero-dep, regex-based) alongside the spec:

1. Regex-extract hex values from the YAML frontmatter (handle one- and two-level nesting; `^ {2}key: "#HEX"` and `^ {4}key: "#HEX"`).
2. Regex-extract hex values from `tokens/*.ts` (single-line `key: '#HEX',` shape) and `--shot-*: #HEX;` from `styles/global-theme.css`.
3. Maintain an `expectedDrift` allow-list mapping each known divergence to a `DRIFT.md` D-number.
4. Fail on NEW drift; pass DOCUMENTED drift.
5. Cross-validate that every allow-list entry has a real `### D<N> —` section in DRIFT.md (catches stale allow-list entries when drift is resolved).

Reference implementation: `scripts/check-design-drift.mjs` + `scripts/check-design-drift.test.ts` in shotclubhouse PR #2667 (commit `76fefd81c`). Wire into `vitest.config.ts` `include` array so the normal test run picks it up.

**DRIFT.md Resolved-entry template trick:** embed the entry template as an HTML comment in the Resolved section — invisible on GitHub render, visible to file-readers (agents + humans on first move). Prevents the first author-of-a-fix from inventing the format under pressure.

## Skill-Trim Cross-Ref Sweep (extends Skill-as-pointer corollary)

When you execute the skill-as-pointer corollary above (rewriting `*-brand-ui/SKILL.md` as a pointer to DESIGN.md), also sweep references in the **same PR**:

1. `rg <skill-name>` across the repo + `{{HOME_TOOL_DIR}}/skills/` + project `docs/`
2. For each hit, update the reference to point at the canonical DESIGN.md section AND keep the skill mention where it covers code-application
3. Common ref sites: `AGENTS.md`, `CLAUDE.md`, `.clan/*`, `.impeccable.md`, project `docs/`, source files with `// See <skill-path>` comments, test files with `it('rule per <skill-name>')` names

**Why same PR:** bot reviewers (claude-bot, gemini-code-assist) catch dangling refs in re-review and demand a follow-up commit anyway. Cheaper to sweep up-front. Field-discovered on shotclubhouse PR #2667 (8 references to a trimmed skill, all updated in one cross-ref-sweep commit).

## Usage Example

To use this skill for the Furniture Collection project:

1. **Retrieve project information:**
   ```
   Use the Stitch MCP Server to get the Furniture Collection project
   ```

2. **Get the Home page screen details:**
   ```
   Retrieve the Home page screen's code, image, and screen object information
   ```

3. **Reference best practices:**
   ```
   Review the Stitch Effective Prompting Guide at:
   https://stitch.withgoogle.com/docs/learn/prompting/
   ```

4. **Analyze and synthesize:**
   - Extract all relevant design tokens from the screen
   - Translate technical values into descriptive language
   - Organize information according to the DESIGN.md structure

5. **Generate the file:**
   - Create `DESIGN.md` in the project directory
   - Follow the prescribed format exactly
   - Ensure all color codes are accurate
   - Use evocative, designer-friendly language

## Best Practices

- **Be Descriptive:** Avoid generic terms like "blue" or "rounded." Use "Ocean-deep Cerulean (#0077B6)" or "Gently curved edges"
- **Be Functional:** Always explain what each design element is used for
- **Be Consistent:** Use the same terminology throughout the document
- **Be Visual:** Help readers visualize the design through your descriptions
- **Be Precise:** Include exact values (hex codes, pixel values) in parentheses after natural language descriptions

## Tips for Success

1. **Start with the big picture:** Understand the overall aesthetic before diving into details
2. **Look for patterns:** Identify consistent spacing, sizing, and styling patterns
3. **Think semantically:** Name colors by their purpose, not just their appearance
4. **Consider hierarchy:** Document how visual weight and importance are communicated
5. **Reference the guide:** Use language and patterns from the Stitch Effective Prompting Guide

## Common Pitfalls to Avoid

- ❌ Using technical jargon without translation (e.g., "rounded-xl" instead of "generously rounded corners")
- ❌ Omitting color codes or using only descriptive names
- ❌ Forgetting to explain functional roles of design elements
- ❌ Being too vague in atmosphere descriptions
- ❌ Ignoring subtle design details like shadows or spacing patterns
