# Recovery: off-host backup of the control plane

The concertmaster's own state (`$CM_HOME`, default `~/.concertmaster`) is the one part of the
system that git cannot rebuild. This file covers the copy of that state kept on a second host,
the alarm that fires when the copy stops, and the restore onto a fresh host.

## What is in git, what is not

| item | where |
|---|---|
| rules, the tick, the state machine, the merge gate | `SKILL.md`, `references/` |
| project config (names only, no secrets) | `config.yaml` (doctor: `scripts/config-check.sh`) |
| all deterministic tooling | `scripts/` |
| `$CM_HOME`: `ledger.json`, `ledger.bak/`, `handovers/`, `roster.yaml`, `inbox/`, `briefs/`, `salvage/`, `outbox.jsonl` | **not in git.** `ledger.json`, `ledger.bak/` and `handovers/` are copied nightly to a peer host once the owner has set `backup.host` (below). The rest is created empty on first boot (`SKILL.md` § First boot); the first census rebuilds the truth from the running worktrees. `salvage/` on a dead host is lost, and so are `handovers/` until a backup exists: acceptable, the work itself is in git and PRs |
| secrets (token files under `~/.secrets`) | provided by the owner on the host; never written into the skill (`references/credentials.md`) |

## Off-host backup of the control plane

`scripts/backup-offhost.sh` copies the part of `$CM_HOME` that cannot be rebuilt from git to a peer
host over ssh + rsync, nightly. Peer and directory come from `config.yaml` (`backup.host`,
`backup.remote_dir`, `backup.keep`). **The owner chooses the target host: `backup.host` has no
default in `config.example.yaml`.** A config with no host makes the script exit 2 with
`backup.host is not set: the owner chooses the target host`. Nothing runs nightly until the cron
line below is installed on the concertmaster host.

The backup runs `scripts/scan-secrets.sh` before it copies anything and refuses (exit 4) when the
scanner is missing.

```
┌─────────────────────┐  scan   ┌───────────┐  ssh+rsync  ┌───────────────────────────────┐
│ $CM_HOME (this host)│───────▶│ scan-     │───────────▶│ peer: <remote_dir>/<stamp>/   │
│  ledger.json        │ exact   │ secrets   │ only the   │   ledger.json  ledger.bak/    │
│  ledger.bak/        │ file    │ hits, an  │ scanned    │   handovers/  BACKUP-INFO     │
│  handovers/         │ set     │ error or  │ files      │ latest -> newest, keep 7      │
└─────────────────────┘         │ no scanner│            └───────────────────────────────┘
                                │ = exit 4  │
                                └───────────┘
```

| rule | how |
|---|---|
| what is copied | `ledger.json`, the ring `ledger.bak/` and `handovers/`, nothing else. `inbox/`, `briefs/` and `lanes/` are not copied: they can hold credential paths and pasted values. **`handovers/` is not known to be clean**: each handover holds the task, the brief and a pane summary, so it can carry pasted text. The scan is a heuristic (it catches a pure-letter password only after the name `password`, `passwd`, `pwd` or `passphrase`, in the `name: value`, `name=value` or `name is 'value'` forms; it misses bare values and every other form and knows nothing of personal data about people), so the handover rule (`SKILL.md`, stuck-rule step 4) bans pasting credential values and personal data into a handover, and the backup relies on that rule as well as the scan. Anything inside `handovers/` named `inbox`, `briefs`, `lanes`, `salvage`, `outbox*`, `tmp.*`, an env, secret or key file is left out and named on stderr, as is a dangling symlink or a name with a newline. They are rebuilt on boot |
| scan first | before any copy the exact file set is snapshotted and the snapshot goes to `scripts/scan-secrets.sh --strict` (next to `backup-offhost.sh`, found by path, no override). A hit, a scan error or a missing scanner: nothing is copied, exit 4, and only counts and file paths are printed, never a match. The scan runs on a private snapshot of the exact set, and that snapshot is what goes to the peer (`rsync --files-from`): a file that changes after the scan (the ledger is rewritten every tick) cannot send unscanned bytes, and a file created after the snapshot waits for the next night |
| what never leaves | `mc.env`, `*.env`, `salvage/`, `secrets`, `.secrets`, `*.pem`, `*.key`, `tmp.*`, `outbox*`, as an exclude list in front of the include list. The finished copy is scanned on the peer for these names and for `briefs`, `inbox`, `lanes`: a hit removes the copy and exits 6 |
| generations | each run writes `<remote_dir>/<yyyymmddThhmmssZ>/`, hard-linked to the previous one (`--link-dest`), staged as `.incoming-*` and renamed into place only when complete. The newest `keep` (default 7) stay on the peer; older ones are deleted there. `latest` points at the newest |
| peer directory | an existing `remote_dir` keeps its mode (it may be shared): the run only warns on stderr when group or other can read it, or when `ls` shows an ACL on it (a trailing `+`: the mode bits then do not say who can read it), so make it `chmod 700` and check `getfacl` yourself. Generations are always 700. A symlinked `handovers/` or `ledger.bak/` on this host is reported on stderr and not backed up: replace the symlink with the real directory |
| local files | `$CM_HOME` is only read: the script writes the lock file `$CM_HOME/.backup-offhost.lock` and, when a generation is finished on a peer host (not in `--dest` local-path mode), the stamp `$CM_HOME/cache/backup-offhost.json` (`ok_at`, `generation`, `host`; `backup-stale.sh` ignores a stamp that names another host), and deletes nothing from it. During a run a private snapshot sits in `$TMPDIR` (mode 700, removed at exit; a SIGKILLed run leaves it behind, so delete stale `cm-backup-snap.*`, `cm-backup-list.*` and `cm-backup-scanerr.*` by hand). Give each source host its own `remote_dir`: a run removes stale `.incoming-*` copies in it |
| overlap | `flock -n` on that lock file: a second run exits 5 and does nothing |
| peer down | `ssh -o BatchMode=yes -o ConnectTimeout=10` check first; unreachable exits 3 with the peer name and the ssh error, before anything is copied. The rsync itself has a 120 s I/O timeout |
| exit codes | 0 done, 1 failed (also a missing or empty ledger), 2 not configured (no `backup.host`, no `backup.remote_dir`) or bad argument, 3 peer unreachable, 4 the secret scan refused, 5 another run holds the lock, 6 a forbidden file reached the copy |

Check the peer without a ledger: `scripts/backup-offhost.sh --check`. Check a copy without writing to the peer: `scripts/backup-offhost.sh --dry-run` (the scan runs; rsync `-n`
against the newest generation; the reachability check and one directory listing still run). Test:
`scripts/test/backup-offhost.sh` (temp dirs and a scanner stub, no network).

### Install the nightly job

Do not install the job while `backup.host` is empty: it would exit 2 every night. From the
concertmaster host, in this order:

```bash
S=.agents/skills/concertmaster/scripts   # the scripts directory of your install
$S/backup-offhost.sh --check     # reads the config, ssh to the peer in BatchMode, lists its newest generation
$S/backup-offhost.sh --dry-run   # runs the secret scan, then rsync -n against the newest generation
```

`--check` writes nothing here or on the peer and needs no ledger. It must print `peer-ok: ...` with no
prompt: cron has no terminal, so a host that needs a password or a first-use confirmation fails every
night with exit 3 (fix it with a key and `ssh <host> true` once by hand). `--dry-run` must exit 0.
Then run the check the way cron will, with nothing in the environment but the `PATH=` of the cron line
below (`env -i` drops everything else, as cron does); exit 2 with "yq is not on PATH" means that PATH
lacks the directory holding `yq`:

```bash
env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin $S/backup-offhost.sh --check
```

Then one line in that host's crontab (`crontab -e`), 03:41 server time, log appended. Replace the two
absolute paths with your checkout and your state directory. The `PATH=` prefix is needed for the same
reason: cron's PATH lacks the directory holding `yq` (add it to the line if it is not in
`/usr/local/bin`), and without it the config cannot be read (the script then exits 2 and says so).
`scripts/test/backup-offhost.sh` parses this line (schedule, `PATH=`, an absolute script path ending in
`scripts/backup-offhost.sh`, a log with stderr), so change the line and the test together:

```
41 3 * * * PATH=/usr/local/bin:/usr/bin:/bin /srv/acme/checkout/.agents/skills/concertmaster/scripts/backup-offhost.sh >> /srv/acme/.concertmaster/backup-offhost.log 2>&1
```

**Stale-backup alarm.** The tick runs `scripts/backup-stale.sh` (`SKILL.md` tick, backup check). It reads the stamp above: older than `backup.max_age_hours` (config, default 50, so one missed night is quiet and two alert; a value that is not a whole number of hours writes one `backup-stale-config-*.md` note and exits 2) writes one inbox note `backup-stale-alert-*.md` and one `backup.stale` event, and the next good backup writes one `backup-stale-cleared-*.md`. With no stamp yet it counts from the first time it ran, so a new setup has the limit to make its first backup. A host with no `backup.host` stays quiet. Test: `scripts/test/backup-stale.sh`.

Check it the morning after: `tail -3` on the cron log and
`scripts/backup-offhost.sh --check` (it prints the newest generation on the peer). A non-zero exit
(3 peer down, 4 secret scan, 6 forbidden file) is a finding for the next tick; exit 5 once in a
while is harmless, repeated means a hung run.

### Restore onto a fresh host

1. Install the skill checkout, `rsync`, `jq` and `yq`, and make sure the new host can ssh to the peer
   with a key (`ssh -o BatchMode=yes "$PEER" true`). Peer and directory are in `config.yaml`
   `backup.host` and `backup.remote_dir`.
2. Create the target and pull the newest generation (the trailing slashes matter):

   ```bash
   CFG=.agents/skills/concertmaster/config.yaml
   PEER="$(yq '.backup.host' "$CFG")"; RDIR="$(yq '.backup.remote_dir' "$CFG")"
   mkdir -p ~/.concertmaster
   rsync -a --exclude BACKUP-INFO -e 'ssh -o BatchMode=yes' "$PEER:$RDIR/latest/" ~/.concertmaster/
   ```

   For an older generation, list them (`ssh "$PEER" "ls -1 $RDIR"`) and use
   `$RDIR/<yyyymmddThhmmssZ>/` in place of `$RDIR/latest/`.
3. Check the ledger parses and has workers: `jq '.workers | length' ~/.concertmaster/ledger.json`.
   With `ledger.json` back, `--init` is not needed and is refused; run the concertmaster boot.
4. Re-provide what the backup never carries: `mc.env`, anything under `~/.secrets`, and the cron line
   above. `briefs/` are regenerated from `references/lanes.md`; `inbox/`, `salvage/` and the outbox are
   gone by design, the work is in git and PRs.
5. Continue with `SKILL.md` § First boot; the first census reconciles the restored ledger with what is
   actually running.
