# Fleet skill review pass — 2026-06-05

## Session signal
Stevie corrected the consolidation workflow: asking whether `/explain-to-me` was available meant "use it to explain how the repos are organized," not "copy `/explain-to-me` into the canonical source repo."

## Skill updates made

- Patched `fleet-docs-and-config-boundaries` with a pitfall: tool availability checks are not migration requests.
- Added `references/two-repo-consolidation-fleet-lambda-2026-06-05.md` with reusable details for future Lambda/Hermes repo consolidation.
- Patched `explain-to-me` anti-patterns: do not treat skill availability as a deliverable/canonicalization request.

## Reusable lessons

1. Capability check ≠ scope inclusion.
2. Use external skills as task tools unless the user explicitly requests skill packaging or source migration.
3. For repo consolidation, keep the deliverable surface restricted to artifacts named in the desired state.
4. PR body and docs must be corrected immediately when scope is corrected.

## Related gotchas captured elsewhere

- Explicitly pass `freeman` to `fleet-worktree-start`; default environment can choose wrong branch prefix.
- Run `fleet-assert-worktree` inside the created worktree, not from the caller cwd.
- `gh pr edit` can fail on GraphQL `projectCards`; use REST `gh api repos/<owner>/<repo>/pulls/<pr> -X PATCH --raw-field body=...`.
