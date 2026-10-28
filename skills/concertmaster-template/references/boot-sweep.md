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
cp scripts/boot-sweep.sh scripts/lib.sh ~/.concertmaster/bin/ && chmod +x ~/.concertmaster/bin/boot-sweep.sh
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

## Tick mode
`boot-sweep.sh --since <epoch> [--lanes <path,path>]` runs the same decision and nudge core with "since" =
a lane's expected wake time instead of boot time, for an Orca RUNTIME restart (no reboot). It is driven by
`scripts/runtime-check.sh` (`references/runtime-check.md`), not by systemd: no Orca wait, no settle, no inbox
note, and a pane is typed into only when its last line is a Claude footer.

## Env
`CM_BOOT_SETTLE_S` (45), `CM_BOOT_ORCA_WAIT_S` (300), `CM_BOOT_CONFIRM_S` (60), `CM_BOOT_NUDGE` (text),
`CM_SELF_PATH_RE` (concertmaster worktree path regex, default built from `worktrees.self_name`), `CM_CLAUDE_PROJECTS`, `CM_BOOT_EPOCH` (tests), `CM_PATH_MATCH`, `CM_HOME`. Tests: `scripts/test/boot-sweep.sh` (stubbed
orca and transcripts, no network).
