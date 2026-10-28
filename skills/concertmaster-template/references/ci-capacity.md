# CI queue alert

A CI backlog can sit queued for hours with nobody told, and a shared GitHub token can hit its hourly
limit. This covers the first, the rule that keeps the second from happening (section 2), and a note on
per-lane tokens (section 3).

## 1. Queue alert
`scripts/ci-queue-alert.sh` samples `actions/runs?status=queued` and alerts when MORE than 15 runs have
been queued for 15 minutes (config `ci.queue.threshold` and `ci.queue.minutes`, or `CM_QUEUE_THRESHOLD`
and `CM_QUEUE_MINUTES`). One alert per episode; the episode clears only after 2 consecutive samples at or
under the threshold (no flapping), with a "cleared" note.

- **Where it goes:** an inbox note `~/.concertmaster/inbox/ci-queue-alert-<alert|cleared|blind>-<UTC seconds>-<pid>.md`
  (one glob, `ci-queue-alert-*.md`, matches every kind) AND a telemetry event (`ci.queue.alert`,
  `.cleared`, `.blind`) through `mc-emit.sh`. The concertmaster tick reads the note (SKILL.md tick
  step 4); the event reaches the dashboard even when no tick is running.
- **It watches itself:** if no sample succeeds for 30 minutes (budget below `CM_QUEUE_MIN_BUDGET` = 20, no
  network, auth gone) a one-time `BLIND` alert fires, so a dead monitor is not mistaken for a quiet queue.
- **Cost:** ONE counted API call per run, 12 an hour (about 0.25% of a 5000/h budget). The `rate_limit`
  check before it is free. Each call has a 20 s timeout and the unit a 90 s one.
- **Limits:** it counts queued RUNS, not jobs, and does not look at the age of the oldest run.
- **Token:** `gh` finds its login in `~/.config/gh/hosts.yml` of the `User=` account (or `GH_TOKEN` in the
  unit's `Environment=`); under systemd `HOME` and `PATH` are set explicitly in the unit.
- **Repo and hint:** config `ci.queue.repo` (default `github.org/github.main_repo`). `ci.queue.hint` is
  the sentence the alert ends with: put your own first move there (which runner dashboard to open, which
  capacity setting to raise, when to flip to GitHub-hosted runners).
- Tests: `scripts/test/ci-queue-alert.sh` (stubbed gh, fake clock, dead telemetry URL).

The response is a human or concertmaster call: look at the runner fleet first, add capacity second, fall
back to GitHub-hosted runners third.

Install on the **concertmaster host only** (Linux with systemd; elsewhere run the script from a `/loop`
tick):
```bash
SRC="$(git rev-parse --show-toplevel)/.agents/skills/concertmaster"
mkdir -p ~/.concertmaster/bin ~/.local/state
cp "$SRC/scripts/ci-queue-alert.sh" "$SRC/scripts/mc-emit.sh" "$SRC/scripts/lib.sh" ~/.concertmaster/bin/ && chmod +x ~/.concertmaster/bin/*.sh
cp "$SRC/config.yaml" ~/.concertmaster/config.yaml   # lib.sh finds it there (CM_HOME/config.yaml)
# fill the @USER@ and @HOME@ tokens of the units for this host
for u in concertmaster-ci-queue.service concertmaster-ci-queue.timer; do
  sed "s|@USER@|$(id -un)|g; s|@HOME@|$HOME|g" "$SRC/references/systemd/$u" | sudo tee "/etc/systemd/system/$u" >/dev/null
done
sudo systemctl daemon-reload && sudo systemctl enable --now concertmaster-ci-queue.timer
# verify (read-only): prints the decision, writes nothing
~/.concertmaster/bin/ci-queue-alert.sh --dry-run
systemctl list-timers concertmaster-ci-queue.timer --no-pager
```

## 2. GitHub API budget rule
Every lane, watcher and script on one token spends from shared 5000/h budgets. There are two
buckets: REST `core` (spent by `gh api`) and `graphql` (spent by `gh pr list`, `gh pr view` and
`gh pr checks`). A few lane watchers polling in parallel can exhaust one, and then every call that
draws on it fails until the reset. These are defaults, not config keys; a script may take its own floor from an environment
variable (`CM_QUEUE_MIN_BUDGET` for `ci-queue-alert.sh`).

1. **Check the budget first.** `gh api rate_limit --jq '.resources | {core: .core.remaining,
   graphql: .graphql.remaining}'` is free. Run it at the start of each tick and before arming any
   watcher.
2. **Poll no faster than 180 s.** ONE watcher per run or PR; kill duplicates and never run several in
   parallel. Briefs for verdict agents say "at most a handful of `gh` calls".
3. **Scripted polls send conditional requests.** Keep the `ETag` from `gh api -i <endpoint>` and repeat
   with `-H 'If-None-Match: <etag>'`: `HTTP 304 Not Modified` means unchanged, and GitHub does not
   charge it to the limit (GitHub REST docs, "conditional requests"). Read a 304 as "no change", not
   as a failure: `gh api` exits 1 on a 304, so branch on the HTTP status line, not the exit code.
4. **Back off under 800 remaining in either bucket.** Poll every 10 minutes, not 180 s, and skip
   optional `gh` calls (use the tick's `scripts/discover.sh` output only). Under 500 make no PR calls until that
   bucket's reset time (`gh api rate_limit --jq .resources.graphql.reset`, or `.core.reset`).
5. **Never retry-loop a 403 or 429.** Check `rate_limit`, then wait for `reset`.
6. **One list, not many views.** ONE `gh pr list --state open --json
   number,headRefOid,mergeable,mergeStateStatus,baseRefName --limit 100` instead of per-PR
   `gh pr view`.

If it keeps recurring, ask the owner for a second fine-grained token or a GitHub App for the CI
watchers (section 3).

## 3. Per-lane tokens or a GitHub App (needs a human)
Every lane sharing one personal token shares one hourly budget. A GitHub App installation token is a
separate bucket and keeps bot traffic off the personal token. One App is still one bucket, so for
per-group isolation create one App per group (for example: pr-sweeper, workers, ops).

Least privilege per group: Contents r (rw only for the group that pushes), Pull requests rw, Issues rw,
Actions r (rw only for the group that dispatches workflows), Checks r, Metadata r. No Workflows
permission (it lets a token rewrite workflow files, which is how production secrets are reached); keep
production secrets in GitHub Environments with required reviewers. Store the App ID, installation ID and
private key in your secret store (see `credentials.md`), never in a repo or a bead. A token minter (JWT,
then `POST /app/installations/<id>/access_tokens`, cached for 55 minutes) is not included: it cannot be
tested without a real App. Until then the budget rule (section 2) stands.
