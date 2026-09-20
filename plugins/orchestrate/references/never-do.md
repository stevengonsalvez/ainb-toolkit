# Never do

Hard refusals. Configuration cannot lift any of them. Each is enforced in code,
not only here, and each refusal appends a `refuse` event naming what and why.

| refusal | enforced by | exit |
|---|---|---|
| merge into anything but the declared `trunk` | `merge_gate` compares the PR's base to `trunk` | 3 |
| merge into a `never_merge_into` branch | checked before the trunk comparison, so the message names the wall | 3 |
| merge an unsigned commit | `git log --format=%G?` over the range, any commit not `G` or `U` refuses | 3 |
| merge an attributed commit | `attribution_patterns` over every commit message in the range | 3 |
| merge a head that moved since the verdict | the reviewed sha is compared to the PR's current head | 3 |
| force-push | there is no code path. No `--force`, no `--force-with-lease`, anywhere | n/a |
| bulk or server-level kills | no `tmux kill-server`, no `pkill`, no `killall`, anywhere. The tmux driver names exactly one session | n/a |
| delete under a live lane | `retire` refuses unless merged, clean and idle; disk pressure asks the owning lane to clean | 3 |
| ssh, of any kind | Orca is the only transport. An unreachable host is reported and skipped | n/a |
| type into a dead shell | the dead-shell guard reads the screen before every send; only the resume command is ever typed into a shell prompt | recorded |
| post a report carrying host paths, vendor words or U+2014 | the scrubber strips paths and refuses on any remaining hit. Nothing is posted after a refusal | 3 |
| two orchestrators on one programme | the owner lock refuses a second session unless the lock is stale or a takeover is asked for | 3 |

The three with no exit code have no code path at all, which is stronger than a
check. The test suite asserts their absence from the source.

## Refusals that stay refusals

A refusal is a finding, not an obstacle. Report it and stop. Do not:

- pass `--takeover` to get past an owner refusal you have not understood
- remove a worktree by hand because `retire` refused
- edit a commit message to slip past the attribution guard without saying so
- rewrite a report to slip past the scrubber without fixing what it caught
- re-target a PR's base to get past the trunk wall

## Ask first, even under full autonomy

Outward or irreversible acts are a structured question to the human every time,
whatever `autonomy` says: a new repository, publishing anything, deleting a
remote branch, closing issues in bulk, adding a host, and force-push. Force-push
additionally requires the human to ask for it in that session, and the event
records their words.

## Why each of these exists

Every row cost time or correctness in a real programme. Messages typed into a
dead shell, a review posted with host paths in it, a false outage raised by an
ssh probe, disk filled to the point that every tool failed, a lane left for
hours awaiting a verdict on a merged PR. The refusals are the scar tissue.
