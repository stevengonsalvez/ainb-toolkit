# Reflect/Fleet/BANK deep dive pattern

Use when an explainer compares AINB Reflect, Fleet hooks, BANK, or any memory/governance consolidation.

## Core framing

Do not stop at “Reflect owns memory; Fleet owns law.” Inventory artifacts and classify them:

1. **Reflect-owned memory substrate** — capture, document storage, sidecars, embeddings, GraphRAG/vector/BM25 retrieval, timeline, sourced recall.
2. **Bridge-owned learning artifacts** — patterns, discoveries, journals, skills, logged corrections. Reflect can store/index/rank them; Fleet decides trust/status/promotion.
3. **Fleet-owned governance/control** — correction debt, live inbox state, manifests/worktree gates, ACP/loop suppression, promotion/HOT thresholds, sleep-cycle policy.

## BANK artifact checklist

For BANK-adjacent explainers, include a table covering:

- `bank.db` + `bank_lookup.py` — retrieval/indexing. Mostly Reflect-native. Preserve injection order below law.
- `patterns.jsonl` / `patterns.md` — durable patterns. Store/index in Reflect; active/superseded/promotion policy stays Fleet unless Reflect has typed lifecycle.
- `discoveries.jsonl` / `discoveries-archive.jsonl` — cross-agent gossip and archive. Reflect can index/timeline; Fleet owns trust, recency windows, promotion/archive policy.
- `corrections.md` — operator correction ledger. Reflect indexes after write; Fleet detector owns unlogged debt.
- `pending-corrections.jsonl` — live correction state. Fleet only.
- `strikes.jsonl` + `.hot-promoted.json` — repeated correction signatures and HOT promotion. Fleet policy; Reflect can propose clusters.
- `MEMORY.md` HOT tier — always-loaded hardened behavior. Reflect can recommend; Fleet governs promotion.
- `JOURNAL.md` worktree journals — Reflect can index as documents; Fleet/worktree protocol requires creation/update.
- Skill library changes — Reflect can index/suggest; Fleet skill pipeline owns confirmation, inbox trail, and security review.
- Convex inbox records — live task contract. Fleet only; Reflect may store API gotchas/postmortems, never authoritative state.
- ACP metrics / loop suppression — deterministic protocol control. Fleet only.
- Manifest/worktree context — live repo law. Fleet loads first; Reflect provides supplemental prior pitfalls.
- Sleep-cycle audit — scheduler + promotion/archive policy. Fleet owns; Reflect may support candidate clustering.

## HTML shape

For updated explainers, prefer tabs when user asks for “new tab”, “deep dive”, “more comprehensive”, or “coverage matrix”:

- Summary
- BANK deep dive / artifact map
- Coverage matrix
- Migration gates / acceptance tests

Each tab should be directly linkable by hash (`#bank`, `#coverage`, etc.) and verified in browser after publish.

## Acceptance tests to include

- Correction debt: Reflect recall of an old correction does not satisfy required `corrections.md` logging.
- BANK replay: Reflect-backed lookup returns same critical gotchas as old `bank.db` for known prompts.
- Journal: worktree still creates/updates `JOURNAL.md`; Reflect indexes only after write.
- Ordering: standing orders → live manifest/worktree/inbox/correction state → Reflect recall.
- Staleness: live law beats stale recall.
- Failure: Reflect backend down leaves Fleet governance intact.
