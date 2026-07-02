# Publishing targets — config, pipelines, troubleshooting

## Contents
- [Target model](#target-model)
- [Config file](#config-file)
- [Target: here.now with config (domain mode)](#target-herenow-with-config-domain-mode)
- [Target: here.now without config (plain)](#target-herenow-without-config-plain)
- [Target: gist](#target-gist)
- [Bootstrap (one-time setup)](#bootstrap)
- [Troubleshooting](#troubleshooting)

## Target model

Three targets. The **flag** picks the target; the config only shapes the
here.now path:

| Target | Trigger | Behaviour |
|---|---|---|
| here.now | default (no flag) | config exists → domain mode (mount + index + lock rule); no config → plain 3-word URL + one-time setup offer |
| gist | `--gist [--public]` | secret/public gist + rendered-preview link |
| local | `--local` | stop after writing the file |

The local file is written in all three cases — local just stops there.

## Config file

`~/.herenow/explainers.json` — shapes the default here.now target only.
Template ships with the skill: [`assets/explainers.template.json`](../assets/explainers.template.json).
API token lives separately in `~/.herenow/credentials` (or `$HERENOW_API_KEY`);
never in the config, never in chat.

```json
{
  "domain": "explainers.stevengonsalvez.com",
  "index_slug": "urban-garden-2tyb",
  "password": "explainedtech",
  "protect_rule": "<prose rule: which content gets locked>",
  "categories": { "shot": "…", "ainb": "…", "other": "…" },
  "gist_index_id": null
}
```

- `protect_rule`: prose predicate the **agent** evaluates against the explainer's
  content to decide `--lock`. The script never guesses; judgment is the agent's.
- `categories`: allowed `--category` values (key → human description). The agent
  classifies; the script validates the key exists.
- `index_slug`: the here.now site serving the domain root index
  (`index.html` + `data.json`). `data.json` schema:
  `{"cats": [[key,name,desc],…], "entries": [{path,title,desc,date,locked,cat},…]}`

## Target: here.now with config (domain mode)

One script does the whole pipeline (publish → optional lock → mount at
`/<path>/` → upsert index entry → republish index). It never overwrites the
index — it fetches live `data.json`, appends/updates one entry, republishes.

```bash
python3 scripts/publish_explainer.py ./explainers/<slug>.html \
  --path <mount-path> --title "<title>" --desc "<one-liner>" \
  --category <key> [--lock] [--date YYYY-MM-DD] [--dry-run]
```

Agent responsibilities before calling:
1. Pick `--path`: hyphen-case, **≤30 chars** (hard API limit), stable/memorable.
2. Pick `--category` from config `categories` keys.
3. Evaluate config `protect_rule` against the content → add `--lock` or not.
   When ambiguous, lock and tell Stevie (unlocking is one PATCH).

Removal / repoint:
- `--remove <path>` unmounts and drops the index entry (does not delete the site).
- Re-running with the same `--path` publishes a fresh site, repoints the mount,
  and updates the index entry in place (safe for explainer updates).

## Target: here.now without config (plain)

Standalone `https://<3-word-slug>.here.now/` URL, no domain, no index. This is
what the default target does when `~/.herenow/explainers.json` is missing, or
when Stevie asks for a throwaway link. Use
`{{HOME_TOOL_DIR}}/skills/here-now/scripts/publish.sh` (no `--slug` on first publish).

After a plain publish caused by *missing config*, offer setup **once per
session**: "Want a custom-domain index for these? One-time setup." If yes →
[Bootstrap](#bootstrap). If no/silence → don't ask again.

## Target: gist

For `--gist` (secret, default) or `--gist --public`:

```bash
gh gist create ./explainers/<slug>.html --desc "<title>" [--public]
```

- Gists show **source**, not rendered HTML. Always also give the rendered link:
  `https://htmlpreview.github.io/?<raw-gist-url>` (raw URL from
  `gh gist view <id> --files` → `https://gist.githubusercontent.com/<user>/<id>/raw/<file>`).
- Secret gist = unlisted URL, not authenticated protection. If content matches
  `protect_rule`, say so — a secret gist is weaker than a here.now password;
  recommend herenow-domain for locked content.
- Index: if `gist_index_id` set in config, append one markdown line
  (`- [title](rendered-url) — desc · date · category`) to that gist:
  `gh gist edit <gist_index_id>` flow — fetch current content
  (`gh gist view <id> -f index.md`), append line, write temp file, update with
  `gh gist edit <id> index.md` replaced by the temp file. Never rewrite existing lines.
  If `gist_index_id` null, skip index and mention it.

## Bootstrap

One-time setup when Stevie accepts the offer (or asks for it):

1. Ask via AskUserQuestion (one round, multi-question): which domain (must
   already be an active custom domain on the here.now account — check
   `GET /api/v1/domains`)? password + protect rule (or "never lock")?
   category taxonomy (offer sensible defaults from his projects)?
2. Token: if `~/.herenow/credentials` missing, ask for the API key and write it
   (`chmod 600`). Never echo the key back or store it in the config.
3. Copy [`assets/explainers.template.json`](../assets/explainers.template.json)
   to `~/.herenow/explainers.json` and fill every field with the answers —
   no placeholders left.
4. Index: **never overwrite an existing root index.**
   `GET https://<domain>/data.json` (cache-busted, browser UA) — if valid JSON
   with `entries`, that's the index; find its slug via `GET /api/v1/domains`
   (mount_path `""`) and put it in `index_slug`. Only if the root has no index:
   publish a fresh site with `index.html` (fetches `data.json?v=` cache-busted)
   + `data.json` (`{"cats":[…],"entries":[]}`), mount at `location: ""`, and
   set `index_slug` to the new slug.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| 403 fetching `*.here.now` from Python | Cloudflare blocks default urllib UA — script already sends `User-Agent: Mozilla/5.0`; keep it |
| `Location must be at most 30 characters` | Shorten `--path` |
| 409 on `POST /api/v1/links` | Path already mounted — script auto-repoints (DELETE `?domain=` + re-POST). `PATCH /links/:loc` does NOT work for custom domains ("No handle found") |
| Index entry count went DOWN after publish | Stale CDN read — script cache-busts `data.json`; if hand-editing, always fetch with `?cb=<random>` |
| `Unauthorized. Provide claimToken` | Site was published anonymously — use the claim token or publish fresh |
| Mount live but 404 on domain | Cloudflare KV propagation, wait ≤60s |
| `jq`/`cut` vanish in piped zsh loops | Write a script file with `export PATH=…` at top; don't inline via xargs |
