---
description: How to wait on a test run, CI job, or deploy without stalling the session.
applyTo: "**/.github/workflows/*.yml,**/.github/workflows/*.yaml,**/Makefile,**/*.sh"
---

- Waiting is never a stopping point. If a test run, CI job, build, or deploy is
  in flight, arm a wake mechanism before yielding. "CI is still running" is a
  stalled session, not a status report.
- Every wait carries a hard bound computed up front from the expected duration:
  a deadline and a maximum poll count. On breach, stop polling and report the
  last known status.
- The watch condition must match FAILURE states, not only success. Silence and
  "still running" look identical. Poll on terminal status
  (`success|failure|cancelled|timed_out|skipped`), never on the happy path.
- Poll remote APIs at 30s or slower to stay inside rate limits. Local file and
  port checks can poll at 0.5s to 1s.
- Keep working on anything that does not depend on the result while waiting.

```bash
n=0; until [ $n -ge 40 ]; do
  s=$(gh pr checks "$PR" --json name,bucket 2>/dev/null) || { sleep 30; n=$((n+1)); continue; }
  jq -e 'length > 0 and all(.[]; .bucket != "pending")' <<<"$s" >/dev/null && { jq -r '.[] | "\(.name): \(.bucket)"' <<<"$s"; break; }
  sleep 30; n=$((n+1))
done
if [ $n -ge 40 ]; then echo "TIMEOUT: checks still pending after 20m"; exit 1; fi
```

Source: `copilot/AGENTS.md` (never_idle_while_waiting).
