# Lessons rejected (seed)

The blocklist of the self-improvement loop (SKILL.md § The tick, lessons loop). A lesson id listed in the project's
copy is dropped by `scripts/lessons-recon.sh` and counted as rejected; it is never proposed again. One line per id,
added in the revert PR of a bad lessons PR (or on the owner's word).

This file is the SEED and is empty on purpose. A toolkit sync overwrites `references/`, so copy it to the
project-owned path (config `lessons.rejected_file`, default `local/lessons-rejected.md`) and add lines there. Format:

```text
- L-<10 hex> <YYYY-MM-DD> <PR #n reverted, or "owner"> <one-line reason>
```
