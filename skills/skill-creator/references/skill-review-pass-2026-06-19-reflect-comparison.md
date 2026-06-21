# Skill review pass: reflect comparison session (2026-06-19)

Session produced reusable process learnings while building an `/explain-to-me` options paper with `/fireworks-tech-graph` diagrams.

## Updates made

- `explain-to-me/SKILL.md`
  - Added pointer to `references/architecture-options-paper-from-source.md`.
  - Added pitfall for the `curl URL | python3 - <<'PY'` verification trap.
- `explain-to-me/references/architecture-options-paper-from-source.md`
  - New reference for architecture consolidation papers based on source inspection.
  - Captures evidence checklist, diagram set, scoring dimensions, gap table pattern, and here.now verification rule.
- `convex-inbox-api-handshake/SKILL.md`
  - Hardened skill-library review inbox-first rule.
  - Strengthened `/complete` pitfall: use `inboxId`/`agentId` and `result`, not `id`/`agent`/`summary`.
- `skill-creator/SKILL.md`
  - Added protocol guard: create+ACK inbox before skill_manage/memory/fact-store edits when fleet rules apply.
  - Added memory failure handling: switch substrate or free space after capacity/ambiguous-match failures; do not retry loops.

## Corrections from pass

- I patched skill files before creating+ACKing the required inbox item. Fixed by hardening `convex-inbox-api-handshake` and `skill-creator`, and logging correction.
- I retried an ambiguous `memory.replace(old_text="X")` after a failure. Fixed by adding memory-loop guidance to `skill-creator`.

## Reusable principle

For source-backed architecture papers: inspect actual implementation, diagram both current states plus proposed consolidated state, separate substrate from governance/control plane, make recommendation in section 1, then publish and verify live artifact with file-based curl verification.
