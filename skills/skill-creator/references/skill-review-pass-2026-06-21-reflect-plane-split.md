# Skill review pass: Reflect/Fleet plane split

Date: 2026-06-21
Context: Stevie corrected a Reflect/Fleet consolidation paper. The first version said "selective graft" but did not clearly split storage/retrieval hooks from governance/control hooks.

## Durable lesson

For agent memory architecture explainers, always split into two planes before recommending consolidation:

1. **Memory substrate plane**
   - capture
   - normalize/write
   - store
   - index
   - retrieve
   - inject advisory context

2. **Governance/control plane**
   - inbox lifecycle
   - standing orders/session rules
   - repo manifests/worktree law
   - correction debt enforcement
   - ACP metrics/routing
   - BANK promotion policy
   - discovery gossip
   - sleep-cycle governance

## Boundary rule

Reflect may index governance artifacts as memory, but must not enforce governance. Current Fleet law wins over recalled memory.

## Explainer pattern

Use `22-options-paper.html` for consolidation choices unless a decision is already final. First section must contain the call:

> Use Reflect as engine. Keep Fleet as law.

Then show:
- two-plane diagram
- table of what consolidates into Reflect
- table of what stays Fleet law
- migration phases with gates
- acceptance tests proving plane separation

## Claimed-site update pattern

When updating an existing permanent here.now explainer:
- use the claimed-site API if the slug is owner-controlled
- publish `index.html` in place
- verify local SHA-256 equals remote SHA-256 with `curl | shasum`
- open in browser and check console errors

If the target repo main clone is dirty, do not clean it silently and do not force a worktree. Write the generated artifact outside the repo, for example `/tmp/<topic>/index.html`, publish from there, then report dirty paths.