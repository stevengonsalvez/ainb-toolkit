# PR critique evidence pattern: Fleet Lambda PR #4

Session learning from a comprehensive `/critique` review of a harness monorepo PR.

## What worked

A good critique did not trust the PR description or green spec tests. It checked:

- PR metadata, changed-file list, diff stat, and commit list.
- Repo instructions/manifest fallback before inspecting code.
- Local spec tests and compile checks.
- Runtime import/startup smoke checks.
- Installer/cron path consistency.
- Live service API contracts for payload enums/routes.
- Stale docs/repo-name references.
- CI/workflow presence.

## Failure shapes found despite passing tests

- Spec tests passed but runtime validator loaded the wrong schema path.
- `py_compile` passed but Python 3.9 runtime import failed on evaluated modern annotations.
- Collectors compiled but failed before argparse because a shared client module was not promoted.
- Cron installer and cron template used incompatible script locations.
- Docs described installer/CLI paths that did not exist in the PR.
- Live API rejected payload fields/enums that code emitted.

## Reusable critique move

For infrastructure/agent monorepo PRs, treat "tests pass" as a starting signal, not a confidence signal. Ask: can a fresh machine install it, can cron run it, can runtime import it under the oldest supported interpreter, and will the receiving API accept its payloads?
