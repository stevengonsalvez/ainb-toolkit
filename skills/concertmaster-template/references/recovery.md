# Recovery: off-host backup of the control plane

The concertmaster's own state (`$CM_HOME`, default `~/.concertmaster`) is the one part of the
system that git cannot rebuild. This file covers the copy of that state kept on a second host,
the alarm that fires when the copy stops, and the restore onto a fresh host. It also covers what `teardown.sh` stops
before a worktree goes: its local Supabase stack and leftover codex processes.

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

## Leftover local Supabase stacks

A worker that ran `supabase start` in its worktree leaves the stack running when the worktree goes. The
stack is keyed by its project id (`project_id` in `supabase/config.toml`, or an id the worker passed), not
by the path, and the Supabase CLI labels each container `com.supabase.cli.project=<id>` and nothing more:
no path label, named volumes, usually no bind mount into the worktree. A host can accumulate
orphan containers this way.

- `teardown.sh --apply` stops the stack that is provably the torn-down worktree's, before the worktree is
  removed: `supabase stop --project-id <id>` for the id in its `config.toml`, or for any container with a bind
  mount inside the worktree. It never passes `--no-backup`: the leak is the running containers (CPU, ports,
  memory), so the data volumes are kept and a stack stopped by mistake can be started again.
- The checked-in default id is shared by every worktree that does not override it. A shared id is never
  stopped: an id is stopped only when no other live worktree (Orca rows and the repo's git worktrees on that
  host) carries it and that list was read in full, and a bind mount inside the worktree does not override
  this. Otherwise teardown warns (`supabase  WARNING stack <id> ... NOT stopped`) and leaves it. A separate
  clone of the repo on the same host that is in neither list is not seen, so its stack can be stopped when it
  shares an id: keep clones off the default id.
- No docker, a docker that does not answer, or no `supabase` CLI is a warning, never a refusal. The census
  (`classify.sh --census`) then says `CHECK INCOMPLETE` for that host instead of a clean zero.
- A stack left behind shows as `supabase-stack: <id> @ <host>` in the census. Before stopping one by hand,
  confirm no live worktree uses that id (`grep project_id` in the live worktrees' `supabase/config.toml`),
  then `supabase stop --project-id <id>`. Never stop the shared default id while another worktree is live. A
  stopped stack's volumes stay: list them with `docker volume ls --filter name=<id>` and remove them only with
  the owner's agreement.
- Other projects' stacks that run in an Orca worktree are matched to that worktree and are never flagged or
  touched by teardown. Only Orca-tracked worktrees count as live, so a stack started in a checkout Orca does not
  list (a personal clone) is reported by the census too: read an orphan row as "nothing Orca tracks owns it" and
  check who started it before stopping it. A host with no docker, or whose docker is silent, is reported as
  `CHECK INCOMPLETE` on every tick until docker is readable; that is deliberate (never a false clean).
- A live worker that started its stack with `--project-id <id>` and no matching `config.toml` id is not
  attributable: teardown leaves its stack alone and the census shows it as an orphan while the worker runs.
  Check for a live worker before stopping any orphan row.
- The shared default id is carried by the main checkout, so a leaked stack under it is not reported as an orphan:
  it cannot be told apart from a live one. The leak this section fixes is the per-worker ids. A host whose
  worktree list was cut off reports no orphan rows (only `CHECK INCOMPLETE`).
- Stopped stacks leave their data volumes behind (teardown never passes `--no-backup`). The census flags only
  running stacks, so review `docker volume ls` on a worker host now and then.

## Leftover codex processes at teardown

A codex app-server, and the node or shell children it spawned, can outlive the terminal that started it and
keep burning CPU after the worktree is removed. Before `orca worktree rm`, `teardown.sh --apply` stops them:

- Which processes: those whose cwd resolves inside the worktree (a path boundary match, so `/x/foo` never
  matches `/x/foo-bar`; `.agents/scratch/...` is inside the worktree) AND that are a codex process (argv[0] is
  `codex` or `codex.js`, or an interpreter such as node or sh with a PATH to a file named `codex` or `codex.js` among its first arguments; a bare word `codex` after a script is an argument and does not count) or a descendant of one. A codex
  process whose cwd is elsewhere is never touched. Any other non-shell process in the worktree still refuses the
  teardown, as before. This covers the process gate only: a terminal that still hosts an agent is closed with
  `--close-handle <h>` first, exactly as before.
- How: by exact pid, deepest children first. TERM, a bounded wait (`CM_TD_PROC_WAIT`, default 10 seconds), then
  KILL for the survivors. Each pid is re-checked (still alive, cwd still inside) just before it is signalled, so
  a reused pid is left alone. Never `pkill`, never by name. The pids stopped are printed
  (`stopped codex processes on <host> by pid (TERM): ...`, `(KILL after Ns): ...`). A process that survives KILL
  fails the teardown before anything is removed. The stop is not undone if a later step refuses or fails (the
  worktree stays, its processes already stopped); it is safe to repeat.
- The dry run lists the pids it would stop (`codex  leftover codex processes ... (children first): <pid>:<name>`).
  If the process list cannot be read on the host, the dry run says so and the existing non-shell process gate
  still decides.

## Detached review worktree at teardown

Symptom: a finished review worktree (created detached on purpose, a reviewer checked out a PR head sha) is refused
by `scripts/teardown.sh`. Do not run `orca worktree rm` by hand: it skips every gate. `teardown.sh` is the only
way, and it accepts a detached HEAD only when ALL of these hold (each is a `detach-*` line in the dry run):

- The child's own comment starts with `cm:retire <reason>` (`detach-retire`). Post it, then re-run.
- No tracked change and no untracked file (`detach-clean`): commit and push what matters, or discard it by hand.
- No precious ignored path (`detach-ignored`): pass `--salvage` so it is copied out and verified first.
- No stash entry anywhere in the repo (`detach-stash`): stashes are shared per repo, not per worktree, so an entry
  may be another session's work. Read `git stash list`, find the owner, and never drop one to get past this
  check; keep the worktree until the stashes are gone.
- HEAD is contained in a remote-tracking ref of origin after a fresh `git fetch` (`detach-remote`; the plan
  line names the ref; a branch already deleted on origin does not count, nothing is pruned). `HEAD is not on any remote ref` means a commit only this worktree holds: push it or keep the worktree.
  A failed or timed-out fetch refuses too (`UNKNOWN`): fix the network or remote and re-run.
- No rebase, merge, cherry-pick, revert or bisect in progress (`detach-inprog`): finish or abort it.

The line `nopr  no PR (detached)` is expected: there is no branch to look a PR up by, and it never counts as a
merged-PR proof. Live processes, codex leftovers, open terminals, owner listing and the beads gate still apply as
for any worktree.

## Beads schema version mismatch at teardown

Symptom: `scripts/teardown.sh` refuses at the beads gate and the refusal quotes `bd: failed to open database: schema version mismatch: database is at vN, binary expects vM`.

Why: a worktree normally holds its own embedded Dolt store under `.beads/`. The store is git-ignored; the tracked `.beads/issues.jsonl` is the truth. A store created by an older bd sits behind a newer bd binary (N lower than M; hosts on bd 0.49 hit this once bd 1.x is installed there, and stores from the 1.1 and 1.2 line sit below the current schema too). Teardown opens the store read-only, and a read-only open cannot migrate. A live agent in that worktree self-migrates the store on its next bd write, so only a worktree with no agent needs the steps below.

If N is higher than M, the store is newer than the installed bd. Do not migrate: upgrade bd on that host instead.

Steps, in order. Run every bd command with `-C <worktree>` so it acts on that worktree and not on the directory you are standing in.

1. Check that no live agent, and no `bd`, `node` or `claude` process, has its cwd in that worktree or holds its store open (`lsof -a -d cwd`, then look for the worktree path; also `lsof +D <worktree>/.beads`; this shows an idle shell or tmux pane that could start bd mid-migration). If one does, STOP: do not migrate under a running agent.
2. Back up first, before any bd command: `cp -a <worktree>/.beads <backup-dir>`. Put the backup dir outside the worktree, on the same host. It must not exist yet, so the copy lands as a full `.beads` tree and never merges into an older backup.
3. STOP and hand to the owner if any of these is true: `<worktree>/.beads/redirect` exists or `bd -C <worktree> --readonly --sandbox where` shows a path outside the worktree (the store is shared, so the backup above missed it and the migration would hit a store other worktrees use); a Dolt remote is configured (`bd -C <worktree> --readonly --sandbox dolt remote list` shows one); that command itself errors (the remote is unknown).
4. `bd -C <worktree> dolt commit`. A plain `bd migrate schema` refuses on a dirty Dolt working set. "Nothing to commit" is fine.
5. `bd -C <worktree> migrate schema` with a generous timeout (minutes under load; do not kill it early).
6. `bd -C <worktree> --readonly --sandbox list --limit 1 --json` must open and print JSON. If it does not, stop and keep the backup.
7. bd may leave an untracked `.beads/.auto-import-issues.jsonl`. Move it into the backup dir with `mv -n` (under a new name if one is already there) so `git status` is clean.

Then re-run the teardown dry-run: the beads gate reads the store normally.

You do not have to migrate by hand just to learn whether the store holds open work. When bd's Error says the store is behind in a way `teardown.sh` recognises as an older schema (a pending migration, or a column the new bd expects is missing; the `schema version mismatch` error above is NOT one of them and stays a plain refusal), `teardown.sh` itself reads it on a COPY: it copies `.beads` to a `mktemp -d` dir under `$CM_HOME/tmp`, runs `bd migrate schema` there, lists every bead on the copy and removes the copy. The refusal then says either `a migrated COPY of it lists N open or in-progress bead(s)` (finish, close or hand over that work, then migrate the live store with the steps above) or `the read of a migrated copy failed (<reason>)` (open beads could not be ruled out; the usual causes are a `.beads/redirect`, a `metadata.json` that names a Dolt server, shared server or external data dir, a `config.yaml` with any option beyond `issue-prefix` or any non-ASCII byte, a symlink inside `.beads`, a remote-backed store that refuses to migrate, or a timeout, which `CM_BD_MIGRATE_SECS` extends). Only a clean read of 0 open beads excuses the unreadable store, and the live store is never migrated or written by the script.

Never wipe the store, never recreate it, never run `bd init`: the store can hold bead state not yet exported to `issues.jsonl`. `teardown.sh` itself never migrates the live store; it only refuses and points here.
