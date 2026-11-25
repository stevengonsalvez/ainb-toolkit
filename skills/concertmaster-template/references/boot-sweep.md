# Boot sweep: re-arm lanes after a VM restart

A VM restart kills every `/loop` and `ScheduleWakeup` timer. Without this, each restart needs hand nudges.

```text
┌──────────┐   ┌──────────────┐   ┌────────────────┐   ┌──────────────────────┐
│ VM boot  │──▶│ orca-serve   │──▶│ orca-resume    │──▶│ concertmaster-boot-  │
└──────────┘   └──────────────┘   │ reopen + nudge │   │ sweep.service        │
                                  └────────────────┘   │ nudge only lanes that│
                                                       │ ran NO turn since    │
                                                       │ boot, confirm, report│
                                                       └──────────────────────┘
```

## What already existed
Many hosts run a resume unit (for example a systemd `orca-resume.service`, pulled in by every
`orca-serve` start) that reopens each dead session by id and sends one generic nudge to sessions that
were mid-turn or waiting on a dead timer. Those nudges can come back `UNCONFIRMED` (input accepted, no
turn started), and the text never tells a lane to re-arm its `/loop`.

## What this adds
`scripts/boot-sweep.sh`, run as its own service (`Type=exec`, so it neither delays boot completion nor has a start timeout that could kill it before it reports) after the resume unit, on THIS host only (each
host that runs lanes runs its own; a remote host is never scanned from here).

The signal is positive: a lane needs a nudge only when its newest Claude transcript
(`~/.claude/projects/<worktree path with / and . as ->/*.jsonl`) was last written BEFORE boot. A lane
that orca-resume already got going has a newer transcript and is skipped, so it never gets a second
`/loop` chain. Stale text left on screen plays no part.

| Lane state | Action |
|---|---|
| the concertmaster session itself (worktree path ending `/<worktrees.self_name>`, or the ledger row `workers.<worktrees.self_name>` with `standing: true`) | treated as a lane and sent exactly `/loop /concertmaster tick`, under every check below. A lost ledger does not exempt it. If it cannot be re-armed (menu, busy, unconfirmed...) the unit log says `CONCERTMASTER NOT RE-ARMED` and the inbox note opens with `NEEDS A HUMAN` |
| not a standing local lane in `~/.concertmaster/ledger.json` (a dev or epic worker) | never read or nudged, `not-standing` |
| no readable ledger | every lane except the concertmaster is `no-ledger` and never nudged; the inbox note says the ledger is missing. With no concertmaster terminal either, nothing is sent and a note says why |
| no Claude transcript visible for the worktree | `unknown`, not nudged (a lane we cannot see is never treated as idle) |
| transcript written since boot | skipped, `active since boot` |
| question menu at the bottom of the screen | not typed into, `menu` |
| shell prompt, or no sign of Claude, or screen unreadable | not typed into, reported (resume.sh respawns) |
| mid-turn (`esc to interrupt`) | left alone, `busy` |
| two terminals in one worktree | reported only |
| otherwise | ONE nudge: timers died, re-arm your standing `/loop`, carry on |
| nudge sent | counted only when the transcript advances within 60 s; else `unconfirmed`, one retry on the next sweep, then `gave-up` (the concertmaster tick takes over) |

The screen checks reuse resume.sh's patterns (`CM_MENU_RE`, `CM_CLAUDE_RE` in `lib.sh`) and judge only
the bottom 12 non-empty lines. Output: TSV on stdout (the unit log) and
`~/.concertmaster/inbox/boot-sweep-<UTC with seconds>-<pid>.md`, which the concertmaster reads on its next
tick. `--dry-run` decides and prints but sends and writes nothing.

## Install on a host (explicit step, per host that runs lanes, Linux with systemd)
Scope comes from config `worktrees.path_match`: only terminals whose worktree path matches it are
read. Unset, the script does nothing.
```bash
mkdir -p ~/.concertmaster/bin ~/.local/state
cp scripts/boot-sweep.sh scripts/lib.sh scripts/cm-worktree-sync.sh scripts/capacity-check.sh scripts/jdupkeys ~/.concertmaster/bin/ \
  && chmod +x ~/.concertmaster/bin/boot-sweep.sh ~/.concertmaster/bin/cm-worktree-sync.sh ~/.concertmaster/bin/capacity-check.sh ~/.concertmaster/bin/jdupkeys
# jdupkeys: lib.sh cm_workers_gate scans the ledger for a key written twice with it; without it boot-sweep holds every nudge and says so
# What holds every nudge (lib.sh cm_workers_gate, one reason line in the unit log): a ledger file of zero bytes, a ledger that is not exactly one JSON document (two documents, truncated), not an object,
# a workers that is not an object, a key written twice under workers, or no jdupkeys. A missing file is "no ledger" and holds nothing. The hold is the whole ledger, see references/input-contract.md 6a.
# scripts/runtime-check.sh (tick step 2) takes the same gate: it checks and sends nothing, prints one `unreadable` row with the reason and exits 1.
cp config.yaml ~/.concertmaster/config.yaml          # lib.sh finds it there (CM_HOME/config.yaml)
# fill the @USER@ and @HOME@ tokens of the unit for this host, and check the PATH line: it must
# reach the Orca CLI (orca-ide lives in ~/.local/bin, which systemd's default PATH lacks)
sed "s|@USER@|$(id -un)|g; s|@HOME@|$HOME|g" references/systemd/concertmaster-boot-sweep.service \
  | sudo tee /etc/systemd/system/concertmaster-boot-sweep.service >/dev/null
sudo systemctl daemon-reload && sudo systemctl enable concertmaster-boot-sweep.service
# verify (read-only): must list the lanes and decide, sending nothing
~/.concertmaster/bin/boot-sweep.sh --dry-run --no-wait
systemctl is-enabled concertmaster-boot-sweep.service   # enabled
```
The resume unit is not touched. macOS hosts have no systemd unit: not covered, install only where
`systemctl cat orca-resume.service` (or your equivalent) works. Test without rebooting:
`sudo systemctl start concertmaster-boot-sweep.service` (acts for real on lanes with no turn since the
real boot; run the dry run first).

## The concertmaster worktree at boot
`scripts/boot-sweep.sh` also runs `scripts/cm-worktree-sync.sh` (not in tick mode: the tick runs it in step 1). A
concertmaster worktree can fall far behind its remote while a stale, empty `index.lock` blocks the fast-forward and
nothing notices, so merged fixes never run. The script prints nothing when the worktree is level; a fast-forward or a
blocker is one row `(worktree-sync)` in the sweep output, and a blocker is also written to the unit log and at the top
of the inbox note (`**BLOCKER: the concertmaster worktree is not level with its remote: ...**`). Stale-lock rule:
removed only when empty, older than 10 minutes and no live process holds it; otherwise reported with age and holder
and left alone (SKILL.md hard rule 30). A copy in no git worktree finds the concertmaster worktree by its name
(`worktrees.self_name`) through the fleet CLI, but only a worktree of the MAIN repo: its path sits under a
`/<worktrees.orca_repo>/` directory (never an extra managed repo, which `worktrees.path_match` may also cover), a row
that names its repo names that one, and its `origin` url is `github.org/github.main_repo`. The skill directory inside
the repo is `skill_sync.path`. Otherwise (none, several, another repo, repo or path not configured) the row is
`cm-worktree-sync: INFO not configured` (an info row, never a blocker) and nothing is fetched or moved.
Time budget: boot-sweep kills `cm-worktree-sync.sh` at 90 s, so the script keeps its own `CM_SYNC_BUDGET` (80 s) over
the lookup (`CM_SYNC_LOOKUP_TIMEOUT`, 15 s), the fetch (`CM_SYNC_FETCH_TIMEOUT`, 50 s, cut to what is left) and the
merge (`CM_SYNC_MERGE_TIMEOUT`, 30 s, cut to what is left). With under `CM_SYNC_MIN_FF` (20 s) left it does not start
the fast-forward: `cm-worktree-sync: DEFERRED time budget ...` (exit 0, nothing moved, the next tick retries), so a
kill never cuts a checkout in half.

## Capacity at boot
`scripts/boot-sweep.sh` also runs `scripts/capacity-check.sh --no-candidates` (not in tick mode: the tick runs it in
step 2 with the teardown candidates). It counts the agent terminals per host against the host cap and is silent when
every host is within its cap and read. A host over its cap, an unread host or a crashed check is one row `(capacity)`
in the sweep output naming the host, its count and its cap. Boot never removes anything and never lists candidates:
`scripts/teardown.sh` is the only remover. `capacity-check.sh --no-candidates` keeps an 80 s budget the same way
(`CM_CAPACITY_BUDGET`: one host list, then every host read in parallel). The two boot checks run one after the other,
so they add at most about 170 s before the first nudge; the unit has no start timeout (`Type=exec`).
Both scripts must sit in `~/.concertmaster/bin/` next to `boot-sweep.sh` and `lib.sh` (the cp line above); after any
change to them, re-run it on every host, or the fix never runs (`scripts/test/boot-sweep.sh` runs the installed copy
from exactly that list).

## Tick mode
`boot-sweep.sh --since <epoch> [--lanes <path,path>]` runs the same decision and nudge core with "since" =
a lane's expected wake time instead of boot time, for an Orca RUNTIME restart (no reboot). It is driven by
`scripts/runtime-check.sh` (`references/runtime-check.md`), not by systemd: no Orca wait, no settle, no inbox
note, and a pane is typed into only when its last line is a Claude footer.

## Env
`CM_BOOT_SETTLE_S` (45), `CM_BOOT_ORCA_WAIT_S` (300), `CM_BOOT_CONFIRM_S` (60), `CM_BOOT_NUDGE` (text),
`CM_SELF_PATH_RE` (concertmaster worktree path regex, default built from `worktrees.self_name`), `CM_CLAUDE_PROJECTS`, `CM_BOOT_EPOCH` (tests), `CM_PATH_MATCH`, `CM_HOME`. Tests: `scripts/test/boot-sweep.sh` (stubbed
orca and transcripts, no network).
