---
name: cm-status
description: Plain-words status of the whole agent fleet the concertmaster runs. Shows a NEEDS A LOOK box first, then every host, every lead on it and the sessions each lead owns, each with a mark and one word (running, idle, waiting on you, stuck, stopped, asleep, unknown) and a one-line meaning for anything not running, such as "stopped: the server restarted at 10:27 and this one did not come back; I will retry once". Use when the owner asks what is running, what stopped, whether a lead is alive, or after a reboot. Read-only. Template copy: place at .agents/skills/cm-status/SKILL.md next to the concertmaster skill.
argument-hint: "[--detail] [--lead <worker-id>]"
---

# /cm-status

Read-only. One fresh `lane-health.sh` pass that writes nothing, rendered for a human.

```bash
SKILL=.agents/skills/concertmaster        # the concertmaster skill directory in this repo
"$SKILL/scripts/cm-status.sh"             # attention box, then host > lead > sessions
"$SKILL/scripts/cm-status.sh" --detail    # plus pid, session id, handle, runtime, model, effort, last write, host events
"$SKILL/scripts/cm-status.sh" --lead <id> # one lead's children only (a lead on its own host)
```

Run it with a 600000 ms timeout: each host is read once (over ssh for a remote one) and each agent pane once.

## How to read it

```text
NEEDS A LOOK (3)
  ✗ lead-a            stopped         the server restarted at 10:27 and this one did not come back; retry 1 failed
  ? review-b          waiting on you  a question menu is open: Which option?
  · old-task          unknown         not in the ledger; branch merged and tree clean: put to sleep

host-a (Spot, rebooted 10:27)
  epic-lead           ● running        cm:running route guard PR #10
    ├ task-1          ● running        cm:running review of PR #12
    └ task-2          ○ idle           fine, nothing to do
```

| mark | word | means |
|---|---|---|
| ● | running | doing work now |
| ○ | idle | fine, nothing to do |
| ? | waiting on you | needs the owner: a question menu, a `cm:blocked` ask, or two copies of one session |
| ⚠ | stuck | a usage limit, an error, or a menu that has waited 30 minutes |
| ✗ | stopped | should run, but no process; the meaning says why and what happens next |
| z | asleep | put to sleep on purpose; never resumed by the check or a reboot |
| · | unknown | not in the ledger, or the host did not answer |

## Rules

- Report the view as printed. Lead the turn-end report with the NEEDS A LOOK rows; each gets a thread row.
- The view never acts. Resuming, sleeping and alerts are `lane-health.sh --all --act` (the concertmaster tick) and
  `lane-health.sh --lead <id> --act` (each lead's loop): `references/lane-health.md`.
- Never clean up, retire or tear down a lead from what this view shows. Only the owner cleans up a lead, after
  confirming it; a lead that must stop is put to sleep (`lane-health.sh sleep <id> --apply`, concertmaster hard rule 27).
- Exit 3 means something needs a look; 1 means the pass could not run (no ledger here: use `--lead <id>` on a lead's host).
