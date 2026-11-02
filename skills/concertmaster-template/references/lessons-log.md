# Lessons log (seed)

One dated entry per merged lessons PR (SKILL.md § The tick, lessons loop), written by the concertmaster after the
merge. Lane-visible: a lead re-reads the section named in the nudge. `scripts/lessons-recon.sh` drops every lesson
id listed in the log, so an id is never proposed twice.

This file is the SEED and is empty on purpose. A toolkit sync overwrites `references/`, so copy it to the
project-owned path (config `lessons.log_file`, default `local/lessons-log.md`) and write entries there. Format,
newest first:

```text
## <YYYY-MM-DD>
- PR #<n>: <gap: instruction file + section> (L-<10 hex>, L-<10 hex>)
```

Do not edit an entry after it merges; a bad entry is rolled back through the blocklist
(`references/lessons-rejected.md`).
