---
description: Playwright reporter rules that keep test runs non-blocking for agents and CI.
applyTo: "**/playwright.config.*,**/*.spec.ts,**/*.spec.js,**/package.json,**/*.sh"
---

- NEVER wire `playwright show-report` or `--reporter=html` into a script, a
  config, an npm script, or a CI step. Both open a blocking report server: the
  agent stalls and the CI job hangs until it is killed.
- Run Playwright with `--reporter=json` piped to a log file, then parse the
  results with `jq`. That output is machine readable and terminates.
- Long test runs go inside tmux, never in the foreground and never as a `&`
  background job. Foreground blocks the agent; `&` does not survive.
- If an existing script calls `playwright show-report`, remove the call rather
  than guarding it behind a flag.

```bash
npx playwright test --reporter=json > playwright-results.json
jq -r '.suites[].specs[] | "\(.title): \(.ok)"' playwright-results.json
```

Source: `general-rules/no-playwright-show-report-rule.mdc` and
`copilot/AGENTS.md` (Background Process Management).
