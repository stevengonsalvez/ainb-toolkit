---
name: sync-learnings
description: Sync user-level agent config changes back to the ainb-toolkit repo (works for Claude, Codex, Copilot)
user-invocable: true
---

# Sync Learnings

Bidirectionally sync `{{HOME_TOOL_DIR}}/` (deployed user-level config) with the **ainb-toolkit repo** (canonical source). Skills/agents/utilities live flattened at the repo root. `/reflect` writes learnings into user-level files; this skill pushes them back to the repo (and pulls newer repo files down).

- **→repo**: new/richer file in `{{HOME_TOOL_DIR}}` → ainb-toolkit repo
- **→home**: newer file in ainb-toolkit repo → `{{HOME_TOOL_DIR}}`

```
{{HOME_TOOL_DIR}}/  <--sync-->  ainb-toolkit repo  --bootstrap.js deploys-->  {{HOME_TOOL_DIR}}/
 (deployed copy)     (canonical: skills/ agents/ utilities/ + claude-code-4.5/)
```

`bootstrap.js` deploys repo → home, substituting `{{TOOL_DIR}}`/`{{HOME_TOOL_DIR}}` placeholders per tool. `claude-code-4.5/CLAUDE.md` is the canonical agent-instructions file; codex/copilot symlink their `AGENTS.md` to it.

## When NOT to use

| Situation | Use instead |
|-----------|-------------|
| Capture a new learning INTO an agent/skill file | `/reflect` |
| Index learnings into the global knowledge base | `/ingest` (`reflect:ingest`) |
| Merge orphaned worktree memory dirs | `/consolidate` (`reflect:consolidate`) |
| Sync config files repo↔home | **this skill** |

## Step 0 — Resolve repo location & cd there (MANDATORY first action)

The repo is a SEPARATE sibling checkout, NOT a subdir of the current project. Every repo-relative path below assumes this ran:

```bash
TOOLKIT_REPO="${AINB_TOOLKIT_DIR:-$HOME/d/git/ainb-toolkit}"
[ -d "$TOOLKIT_REPO/.git" ] || { echo "ainb-toolkit not found at $TOOLKIT_REPO — set AINB_TOOLKIT_DIR"; exit 1; }
cd "$TOOLKIT_REPO"
git fetch origin   # compare against origin/main, not just local HEAD
```

TO_REPO commits land in THIS repo. The `{{HOME_TOOL_DIR}}/` side is NOT a git repo — with ONE exception: own-marketplace plugin clones (see Step 0b). Ship via branch → PR → merge on `main`, then redeploy: `node "$TOOLKIT_REPO/bootstrap.js"`.

### Step 0b — Own-plugin git flow (v2)

Skills that migrated into `plugins/<name>/` (manifest flag `own-plugin: true`, e.g. godmode) do NOT sync by copy-diff. Their deployed copies are git artifacts:

```bash
bash "$TOOLKIT_REPO/skills/sync-learnings/scripts/own-plugin-sync.sh"
```

The script resolves own marketplaces from `~/.claude/plugins/known_marketplaces.json` `installLocation` (covers BOTH github-cloned marketplaces under `plugins/marketplaces/` AND directory-source local-path installs, which never get a clone dir), then diffs the installed CACHE copy (`~/.claude/plugins/cache/<mkt>/<name>/<ver>/`) against the marketplace clone HEAD — in-session hot-fixes land in the cache and are DESTROYED by the next `claude plugin update` unless surfaced here.

For candidates it emits: edit in the marketplace clone (own code, own repo), then `git add plugins/<name>/ && git commit && git push` (or branch → PR per this skill's conventions), then `claude plugin update <name>@ainb-toolkit` on other machines. Bump the plugin version per the godmode version policy (all provider manifests move together).

## Runbook

1. **Refresh catalog**: `bash bin/generate-catalog.sh` (regenerates `catalog.yaml` snapshot of the internal set to HEAD).
2. **Diff** each category (Step 5 commands). Decide direction by CONTENT ASYMMETRY, never mtime (Step 4).
3. **Reverse scan** for orphans (Step 2).
4. **Plugin audit** against `external-dependencies.yaml` (Step 3).
5. **Emit the assessment** in the exact tidied format (Step 6). Ask `Proceed? [Y/n]` ONCE.
6. On `Y`: copy files (Step 7 interpolation rules), commit, print the receipt.

---

## Directory Mappings — route each file to its repo target

| Source (user-level) | Target (repo) |
|---------------------|---------------|
| `{{HOME_TOOL_DIR}}/agents/{engineering,universal,orchestrators,design,meta,swarm}/` | `agents/<same>/` |
| `{{HOME_TOOL_DIR}}/agents/*.md` (root) | `agents/` |
| `{{HOME_TOOL_DIR}}/skills/` | `skills/` |
| `{{HOME_TOOL_DIR}}/utils/` | `utilities/utils/` |
| `{{HOME_TOOL_DIR}}/hooks/` | `utilities/hooks/` |
| `{{HOME_TOOL_DIR}}/output-styles/` | `utilities/output-styles/` |
| `{{HOME_TOOL_DIR}}/CLAUDE.md` | `claude-code-4.5/CLAUDE.md` (reverse-interp, Step 7) |
| `{{HOME_TOOL_DIR}}/settings.json` | `claude-code-4.5/settings.json` (reverse-interp) |
| `{{HOME_TOOL_DIR}}/statusline.sh` | `claude-code-4.5/statusline.sh` (+x preserved) |
| `~/.codex/config.toml` | `codex/config.toml` — sole Codex preferences file; repo-ward only through the filter below |

Notes:
- **Commands are NOT synced.** No `commands/` or `workflows/*/commands/` in the repo — they migrated to skills. Workflows are single files at `workflows/<name>/WORKFLOW.md`.
- **No `utilities/templates/`.** Skill-owned templates live inside the skill (e.g. `skills/explain-to-me/assets/templates/`) and sync as part of that skill.

## Exclusion Categories (never sync)

| Category | Pattern | Reason |
|----------|---------|--------|
| Personal instrumentation | `hooks/*.py` with Langfuse/telemetry/personal API | don't pollute shared repo |
| Project-specific commands | `commands/data-setup-*.md`, `commands/load-frameworks.md` | private-project only |
| Session/ephemeral | `session/`, `reflections/`, `plans/`, `*.json` session files | runtime state |
| Machine-local override | `settings.local.json` | host-specific; NEVER sync |
| Plugin-managed | `plugins/` cache, skills provided by plugins | tracked in `external-dependencies.yaml`, not in `skills/`+`agents/` |

`settings.json` (no `.local`) IS synced — canonical shared config; reverse-interpolate paths.

### Files bootstrap will NOT redeploy over (`PRESERVE_IF_EXISTS`)

Keyed **per tool**, not by bare filename:

| Tool | Preserved | Machine-side writer |
|------|-----------|---------------------|
| `codex` | `config.toml` | codex appends project trust levels, hook state, app-injected MCP servers |
| `claude-code-4.5` | `settings.json`, `statusline.sh` | e.g. AgentPeek rewrites `statusLine` in place |

Everything else still deploys normally — `gemini/settings.json` is repo-authored with no machine-side
writer, so scoping by tool keeps maintainer fixes flowing there.

On a machine that already has one of these, bootstrap keeps the live file and prints what it skipped,
naming the differing top-level keys for JSON. It keeps exactly **one** backup
(`<file>.pre-bootstrap-backup-<stamp>`, older ones pruned) and writes **no** backup when the live file
is byte-identical to the repo copy or was authored by that same run — otherwise routine re-runs would
pile up full copies of a file holding `env` vars and hook commands.

Consequence: **repo-side changes to these files do not propagate automatically.** This skill's
repo-ward diff is how they travel, and adopting one on an existing machine is a hand-merge.
`CLAUDE.md` / `AGENTS.md` are deliberately NOT preserved — they are repo-authored and must keep
propagating.

### `~/.codex/config.toml` — filtered, one-way, never redeployed over a live file

Codex has no `config.local.toml`, so the ONE file mixes preferences with runtime state. A live copy is
~25 KB of which ~99% is machine junk: a `[projects."<abs path>"]` trust block per directory ever
approved (temp worktrees included), `[hooks.state.*]`, `[marketplaces.*]` / `[plugins."..."]` install
state, and `[mcp_servers.*]` + `[shell_environment_policy]` injected by the ChatGPT desktop app with
absolute `/Applications` paths and build SHAs. **This repo is public.** Never copy the whole file.

```bash
bash skills/sync-learnings/scripts/codex-config-shareable.sh --out codex/config.toml   # then review the diff
bash skills/sync-learnings/scripts/codex-config-shareable.sh --self-check              # verify the filter
```

Use `--out`, never `> codex/config.toml`: the shell truncates a redirect target *before* the script
runs, so a fail-closed refusal would leave the baseline empty and look like a clean sync. `--out`
writes a temp file and moves it into place only on success.

The filter is an **allow-list**: only `[tui]`, `[notice]`, `[features]`, `[desktop]` and a fixed set of
top-level preference keys survive, including compact-TUI preferences (`model_verbosity`,
`model_reasoning_summary`, `hide_agent_reasoning`). Anything else — including a
section that postdates this script, such as `[model_providers]` with an internal `base_url`/`env_key` —
is dropped and NAMED on stderr, so a genuinely shareable new preference gets noticed and added
deliberately rather than published by default. Comments are emitted only when what FOLLOWS them is
kept, so a note above `[projects."/work/acme"]` dies with its section.

`$HOME` is reverse-interpolated, and a credential-shaped value that somehow survives makes the script
exit non-zero reporting **line numbers only** — printing the matched line would move the secret from
the repo into the session transcript and CI logs.

Note `[otel]` is NOT shareable: it points at a `localhost:4318` collector that exists on one machine
and turns on `log_user_prompt`, which no one should inherit by default.

### Category 5b — bundled vs pulled: presence in the manifest is NOT "external"

A skill appearing in `external-dependencies.yaml` does NOT mean "don't sync". The **section+key** discriminate, not mere presence. Why: a misclassification here cost real cycles 2026-06-05.

| Manifest shape | Meaning | Sync? |
|----------------|---------|-------|
| `bundled-skills:` with `path: skills/<name>` | committed in repo, deployed FROM repo | **YES — both directions** |
| `agent-skills:` with `repo:` + `multi-subpath:` | git-cloned into `~/.{tool}/skills` at bootstrap | NO — external; use update-externals |
| `nanoclaw-skills:` | synced from nanoclaw fork (`container/skills/`) | NO — edit in the fork |

Discriminator = **`path:` → bundled → sync** vs **`repo:`/`multi-subpath:` → cloned → skip**. `source:` is provenance ONLY, never an exclusion marker (e.g. `media-processing` has both `source:` and `path:` — it IS bundled and DOES sync). Before dropping a skill that exists in BOTH `~/.claude` and repo `skills/`, grep its manifest entry: if it has `path:`, sync it.

### Category 5c — own plugins: never copy-diff, always git flow

| Manifest shape | Meaning | Sync? |
|----------------|---------|-------|
| `claude-plugins:` with `own-plugin: true` | source of truth in THIS repo under `plugins/<name>/`; deployed via `claude plugin install`, not bootstrap | NO copy-diff — git flow via Step 0b (`own-plugin-sync.sh`) |

A lingering `~/.claude/skills/<name>` copy of an own-plugin skill is a MIGRATION LEFTOVER, not a sync candidate: bootstrap removes it when pristine and backs it up (`.godmode.pre-plugin-backup-<date>/`) when locally edited. Reconcile backups by porting their edits into `plugins/<name>/` in the repo, then delete the backup.

## Step 2 — Reverse scan (orphan detection)

Enumerate `{{HOME_TOOL_DIR}}/` items not owned by this repo, surface ONLY genuine orphans. Internal set = `skills/*/` (dirs) ∪ `agents/**/*.md`. The **reflect** plugin sub-skills (`reflect`, `recall`, `consolidate`, `ingest`, `reflect-status`) live in agents-in-a-box `plugins/reflect/`, deploy via that plugin → treat as external (in `REFLECT_SUBSKILLS`).

Run `bash bin/generate-catalog.sh` FIRST, then:

```bash
REFLECT_SUBSKILLS=$'reflect\nrecall\nconsolidate\ningest\nreflect-status'

internal_skills=$(
  {
    find skills -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
    # own-plugin sub-skills (plugins/<name>/skills/*) are internal too:
    # catalog.yaml components.plugins mirrors this on regen
    find plugins -mindepth 3 -maxdepth 3 -path 'plugins/*/skills/*' -type d -exec basename {} \; 2>/dev/null
    echo "$REFLECT_SUBSKILLS"
  } | sort -u
)

echo "=== Orphan Detection: Skills ==="
for skill_dir in "$HOME"/.claude/skills/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  grep -qx "$skill_name" <<< "$internal_skills" && continue                       # internal → skip
  grep -q "^[[:space:]]*-[[:space:]]*name:[[:space:]]*$skill_name\b\|^[[:space:]]*-[[:space:]]*$skill_name:" \
     external-dependencies.yaml 2>/dev/null && continue                            # tracked external → skip
  echo "ORPHAN: skills/$skill_name (not internal, not in external-dependencies.yaml)"
done

echo "=== Orphan Detection: Agents ==="
for agent_file in "$HOME"/.claude/agents/**/*.md; do
  rel_path="${agent_file#$HOME/.claude/}"
  [ -f "$rel_path" ] || echo "ORPHAN: $rel_path (in ~/.claude only, missing from repo)"
done
```

Classify surviving orphans:

| Class | Meaning | Action |
|-------|---------|--------|
| SYNC TO REPO | generic reusable skill/agent | copy to matching dir, re-run catalog generator |
| EXTERNAL (untracked) | real external missing from manifest | add entry to `external-dependencies.yaml` |
| PERSONAL | user-specific tooling | ignore |
| DEPRECATED | no longer needed | candidate for removal from `{{HOME_TOOL_DIR}}/` |

## Step 3 — Plugin & external-dependency audit

```bash
MANIFEST="external-dependencies.yaml"

echo "=== Plugin Audit ==="
for plugin_dir in "$HOME"/.claude/plugins/cache/*/; do
  plugin_name=$(basename "$plugin_dir" | sed 's/-marketplace$//')
  grep -q "name: $plugin_name" "$MANIFEST" 2>/dev/null || echo "UNTRACKED PLUGIN: $plugin_name"
done

echo "=== Dependency Cross-Check (skills needing 'bd'/Beads CLI) ==="
for skill_dir in skills/*/; do
  skill_file="$skill_dir/SKILL.md"; [ -f "$skill_file" ] || continue
  if grep -qE '\bbd\b.*(show|ready|create|swarm)' "$skill_file"; then
    echo "EXTERNAL DEP: $(basename "$skill_dir") → requires 'bd' (Beads)"
    grep -q "name: beads" "$MANIFEST" 2>/dev/null || echo "  WARNING: beads not tracked"
  fi
done
```

## Step 4 — Decide sync direction by CONTENT ASYMMETRY (never mtime)

Why: bulk deploys cluster-touch mtimes, so "newer→older" is wrong. Canonicalize both sides, then count unique lines:

```bash
canon() { perl -pe '
  s|\{\{HOME_TOOL_DIR\}\}|@H@|g; s|\$HOME/\{\{TOOL_DIR\}\}|@H@|g;
  s|/Users/[^/]+/\.claude|@H@|g; s|~/\.claude|@H@|g; s|\$HOME/\.claude|@H@|g;
  s|\{\{TOOL_DIR\}\}|.claude|g;' "$1"; }

only_repo=$(diff <(canon REPO_FILE) <(canon HOME_FILE) | grep -c '^<')
only_home=$(diff <(canon REPO_FILE) <(canon HOME_FILE) | grep -c '^>')
```

| Result | Direction |
|--------|-----------|
| `only_home > only_repo` | home richer → **→repo** |
| `only_repo > only_home` | repo richer → **→home** |
| both sides have unique lines | REAL bidirectional divergence → inspect/merge, NEVER blind-overwrite |

## Step 5 — Diff commands

```bash
# Tool-specific config files (use canon() to hide false path diffs)
diff <(canon claude-code-4.5/CLAUDE.md) <(canon "$HOME/.claude/CLAUDE.md")
diff claude-code-4.5/settings.json "$HOME/.claude/settings.json"
diff claude-code-4.5/statusline.sh "$HOME/.claude/statusline.sh"

# Directory diffs
diff -rq "$HOME/.claude/agents/" agents/ 2>/dev/null
diff -rq "$HOME/.claude/skills/" skills/ 2>/dev/null | head -20
diff -rq "$HOME/.claude/agents/" agents/ 2>/dev/null | grep "Only in $HOME"   # →repo candidates

# Orphans (in ~/.claude but not in repo)
comm -23 <(ls -1 "$HOME/.claude/skills/" 2>/dev/null | sort) <(ls -1 skills/ 2>/dev/null | sort)
comm -23 \
  <(find "$HOME/.claude/agents/" -name '*.md' -exec basename {} \; 2>/dev/null | sort) \
  <(find agents/ -name '*.md' -exec basename {} \; 2>/dev/null | sort)

# Skills referencing 'bd' (Beads)
grep -rl '\bbd\b' skills/*/SKILL.md 2>/dev/null
```

## Step 6 — Assessment output contract (EXACT — do not regress)

Stevie explicitly requested terse output. These rules are a contract, not taste:

1. **One combined plan table** with `dir | file | target | note`, covering both directions. No separate SYNC-TO-REPO / SYNC-TO-HOME sub-sections. `note` = one word: `new`/`updated`/`newer`/`older`.
2. **One line per file.** No `**Purpose:**`/`**Action:**` multi-bullet blocks.
3. **Hide empty sections.** Omit orphans/plugin-audit/don't-sync entirely if zero items — no "✓ none" lines. Plan table always shows (empty → single line `Nothing to sync.`).
4. **Single Y/n gate.** Show plan, ask `Proceed? [Y/n]` ONCE. No per-section prompts.
5. **Silent execution.** Don't echo each `cp`. After sync, print the 3-line receipt.
6. **Orphans + plugin audit are INFORMATIONAL, not gated.** The Y/n covers ONLY plan-table file-sync rows. Orphans + untracked-plugin rows go under `## Informational`, acted on only if the user explicitly asks. Treating them as part of the plan is a regression (corrected 2026-05-19).

**Output template:**

```markdown
# Sync Assessment

| dir   | file                      | target                        | note    |
|-------|---------------------------|-------------------------------|---------|
| →repo | skills/foo/SKILL.md       | skills/foo/                   | new     |
| →repo | agents/engineering/bar.md | agents/engineering/           | updated |
| →home | skills/baz/SKILL.md       | ~/.claude/skills/baz/         | newer   |

Proceed? [Y/n]

## Informational (NOT part of the gate above)

[Orphans / Plugin audit / Drift — ONLY if non-empty, each a small one-row-per-item table.]
```

**Receipt template (after execution):**

```
Receipt:
  N files → repo
  M files → home
  commit <sha> on <branch>
```

**Anti-patterns (never emit):** top-level count-only summary table; `### 1. file.md (NEW)` + multi-bullet blocks; "✓ none" placeholders; per-section Y/n; per-`cp` echo during execution.

## Step 7 — Execution & interpolation

### Reverse interpolation (→repo — CRITICAL)

User-level files have resolved paths (`~/.claude`, `$HOME/.claude`). Convert them BACK to placeholders before writing to the repo.

> The replacement side MUST emit literal `{{HOME_TOOL_DIR}}`/`{{TOOL_DIR}}`. In THIS SKILL.md source those placeholders are written ESCAPED (`\{\{HOME_TOOL_DIR\}\}`) so the deploy-time (TO_HOME) perl pass does NOT eat the example. If you ever see `s|...|~/.claude|g` in this section, the example was corrupted by a buggy reverse-interp pass — restore from git history.

```bash
# .md docs (use ~/ form):
perl -pe 's|~/\.claude|\{\{HOME_TOOL_DIR\}\}|g' \
  "$HOME/.claude/CLAUDE.md" > claude-code-4.5/CLAUDE.md

# .sh/.py code (use $HOME form):
perl -pe 's|\$HOME/\.claude\b|\$HOME/\{\{TOOL_DIR\}\}|g; s|~/\.claude\b|\{\{HOME_TOOL_DIR\}\}|g' \
  "$HOME/.claude/skills/some-skill/scripts/script.sh" > skills/some-skill/scripts/script.sh

# Mixed files (doc text + bash, like CLAUDE.md) — order: $HOME first (most specific), then ~/, then bare:
perl -pe '
  s|\$HOME/\.claude\b|\$HOME/\{\{TOOL_DIR\}\}|g;
  s|~/\.claude\b|\{\{HOME_TOOL_DIR\}\}|g;
  s|`\.claude/|`\{\{TOOL_DIR\}\}/|g;
  s|"\.claude/|"\{\{TOOL_DIR\}\}/|g;
' SOURCE > DEST
```

Verify (must return ZERO hits in the toolkit-side file):

```bash
grep -nE '~/\.claude\b|\$HOME/\.claude\b' claude-code-4.5/CLAUDE.md
```

Bulk fixup when a regression stripped placeholders from many synced files (review `git diff` before committing):

```bash
perl -i -pe '
  s|\$HOME/\.claude\b|\$HOME/\{\{TOOL_DIR\}\}|g;
  s|~/\.claude\b|\{\{HOME_TOOL_DIR\}\}|g;
' skills/*/SKILL.md skills/*/scripts/*.sh
```

Do NOT reverse-interpolate `.claude` used as a plain directory-name segment (e.g. `Check .claude/session/`), nor `.claude` inside an unrelated word/domain.

### Forward interpolation (→home — CRITICAL)

Repo files use `{{HOME_TOOL_DIR}}`/`{{TOOL_DIR}}` cross-tool placeholders. Substitute BEFORE writing to a tool's home dir — never leave literals.

| Template | Claude Code | Codex | Copilot |
|----------|-------------|-------|---------|
| `{{HOME_TOOL_DIR}}` | `$HOME/.claude` | `~/.codex` | `~/.copilot` |
| `{{TOOL_DIR}}` | `.claude` | `.codex` | `.copilot` |

```bash
# Claude Code target:
perl -pi -e 's/\{\{HOME_TOOL_DIR\}\}/$ENV{HOME}\/.claude/g; s/\{\{TOOL_DIR\}\}/.claude/g' \
  "$HOME/.claude/path/to/SKILL.md"
```

Verify: `grep -n "HOME_TOOL_DIR\|TOOL_DIR" "$HOME/.claude/..."` must return nothing.

### Copy operations (use `\cp` to bypass the `cp -i` alias)

```bash
\cp "$HOME/.claude/agents/engineering/new-agent.md" agents/engineering/
\cp -R "$HOME/.claude/skills/new-skill/" skills/
\cp "$HOME/.claude/hooks/new-hook.py" utilities/hooks/
```

### Commit format

```
chore: sync learnings to repo

- Add [new-file]: [brief description]
- Update [updated-file]: [what changed]
```

## Safety Checks (gate before any overwrite)

- **Assess first** — never overwrite without an assessment.
- **Direction by content asymmetry, not mtime** (Step 4). Unique on BOTH sides → merge, don't blind-copy.
- **Bundled vs pulled before any drop** — `bundled-skills` + `path:` DOES sync; only `agent-skills`/`nanoclaw-skills` are external. `source:` is provenance (Category 5b).
- **Compare against `origin/main`** when local is behind (`git fetch` done in Step 0) to avoid clobbering syncs.
- **Tool-specific files (statusline.sh, settings.json, CLAUDE.md) can diverge BOTH ways** — if each side has unique blocks, do a surgical per-block merge by content anchor; never overwrite.
- **Deleting a bundled skill = 4 steps:** (1) remove skill dir, (2) remove its `bundled-skills` entry from `external-dependencies.yaml`, (3) remove skill-specific handling in `bootstrap.js`, (4) regenerate `catalog.yaml`. Then grep the toolkit for dangling refs.
- **Skip binaries** — never `perl -i` a compiled file; copy raw.
- **Validate** markdown frontmatter before copying agent files.

## Example Session

```
User: /sync-learnings

Claude:
# Sync Assessment

| dir   | file                                | target                                    | note  |
|-------|-------------------------------------|-------------------------------------------|-------|
| →repo | agents/engineering/new-validator.md | agents/engineering/                       | new   |
| →repo | skills/new-helper/SKILL.md          | skills/new-helper/                        | new   |
| →home | skills/sync-learnings/SKILL.md      | {{HOME_TOOL_DIR}}/skills/sync-learnings/  | newer |

Proceed? [Y/n]

User: Y

Claude:
Receipt:
  2 files → repo
  1 file  → home
  commit a1b2c3d on main
```

If orphans/untracked plugins exist, append them UNDER the plan table as small one-row-per-item tables in `## Informational` — never bundled into the gated plan.

## Automation Tip

Session-start hook for auto-detection:

```bash
# In hooks/session-start (run after cd "$TOOLKIT_REPO")
DIFF_COUNT=$(diff -rq "$HOME/.claude/agents/" agents/ 2>/dev/null | grep -c "differ")
[ "$DIFF_COUNT" -gt 0 ] && echo "  $DIFF_COUNT agent files differ from the repo. Run /sync-learnings."
```
