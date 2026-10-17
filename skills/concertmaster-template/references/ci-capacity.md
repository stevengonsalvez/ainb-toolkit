# CI queue alert

A CI backlog can sit queued for hours with nobody told, and a shared GitHub token can hit its hourly
limit. This covers the first; the second is a note on per-lane tokens at the end.

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

## 2. Per-lane tokens or a GitHub App (needs a human)
Every lane sharing one personal token shares one hourly budget. A GitHub App installation token is a
separate bucket and keeps bot traffic off the personal token. One App is still one bucket, so for
per-group isolation create one App per group (for example: pr-sweeper, workers, ops).

Least privilege per group: Contents r (rw only for the group that pushes), Pull requests rw, Issues rw,
Actions r (rw only for the group that dispatches workflows), Checks r, Metadata r. No Workflows
permission (it lets a token rewrite workflow files, which is how production secrets are reached); keep
production secrets in GitHub Environments with required reviewers. Store the App ID, installation ID and
private key in your secret store (see `credentials.md`), never in a repo or a bead. A token minter (JWT,
then `POST /app/installations/<id>/access_tokens`, cached for 55 minutes) is not included: it cannot be
tested without a real App. Until then the budget rule stands: one `gh pr list --json` per tick, no
per-PR loops, check `gh api rate_limit` first (it is free).
