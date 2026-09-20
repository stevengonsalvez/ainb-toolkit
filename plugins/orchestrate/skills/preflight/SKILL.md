---
name: preflight
description: Report host capacity for a programme: disk free per host, how many lanes each carries, and which metrics rung answered. Use before placing a new lane or when a host looks full. The full metrics ladder, scoring and placement refusals are cut 2; this ships the probe rung and the recorded floors only.
---

# preflight

CUT 2 IS NOT BUILT. The Beszel hub rung, the placement score, the per-host
refusals and the ranking are not implemented. What exists is the bottom rung of
the ladder and the numbers it has collected.

## What works now

Each tick runs the Orca probe rung per environment and appends to
`hosts.jsonl`. To take a reading now, run a tick, or read what is there:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh status <programme>   # hosts section
jq -r '[.host, .src, .disk_free_gb, .lanes, .t] | @tsv' \
  ~/.claude/orchestrator/<programme>/hosts.jsonl | tail -20
```

`src` says which rung answered: `probe` means an Orca terminal ran `df` on that
host, `unknown` means no rung could answer and the number is missing rather than
guessed.

The floors are in `programme.yaml` under `placement.floors`. A tick prints a
`DISK:` line for any host under the disk floor. Cut 1 exists partly to collect
real numbers before cut 2 scores against them, so treat the floors in the
template as placeholders until this programme's hosts have reported.

## Judgment until cut 2 lands

Place a lane by hand, using the same rules cut 2 will encode:

1. Refuse any host under `placement.floors`. A large build must not land on a
   small box.
2. Refuse any host already at `placement.max_lanes_per_host`.
3. Refuse a host already running an `exclusive` resource the new lane needs, for
   example a second end-to-end suite. Two on one box produces false failures.
4. If every host refuses, do not place it. Ask, with the numbers.

Record the placement decision as an event so the next tick can see it:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh status <programme>   # then note it
```

## Not implemented

Beszel hub with history, weighted scoring, the ranking table with refusals, and
restart onto a healthier host. Do not claim a host was ranked when it was only
probed.
