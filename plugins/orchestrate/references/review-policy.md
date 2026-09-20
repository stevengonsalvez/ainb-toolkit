# Review policy

Projects review in different places. The `review` block in `programme.yaml` says
where, per class of PR, and the orchestrator nudges to match. The modes are the
whole of it.

```
                 ┌──────────────┐
   open PR ─────▶│ match class  │
                 └──────┬───────┘
      ┌─────────────┬───┴────────┬─────────────┐
      ▼             ▼            ▼             ▼
┌───────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│orchestrat.│ │  lane    │ │   ci     │ │  none    │
│review here│ │ask lane  │ │head sha  │ │ no gate  │
└─────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
      └────────────┴────────────┴────────────┘
                         ▼
               ┌──────────────────┐
               │ verdict rule     │──▶ merge gate, or post findings
               └──────────────────┘
```

## The four modes

| mode | who produces the verdict | what you nudge |
|---|---|---|
| `orchestrator` | you, or a reviewer you run | nothing to nudge. If a review is outstanding past a cadence, run it |
| `lane` | the owning lane's own report | ask the lane for its report, quoting the sha and the command that produced it. Use `review.nudge.stale_pr` |
| `ci` | the head sha's checks | wait on checks for THAT sha. A green run on an older sha is not a verdict |
| `none` | nobody | merge per the class's own rule. Documentation classes usually sit here |

## Matching a class

`review.classes` is a block list, so the scripts do not read it: you do. Match
in order, first match wins, and fall back to `review.default`. A class matches
on changed paths or on a label. Protocol, migration, updater and wire-format
changes are the usual reasons to widen `kinds` to include a security read.

## The verdict rule

`review.default.verdict` states the rule, for example that the report's first
line must be one of an approved set. Two things are not verdicts:

- A lane's claim that its work is fine, unless the mode for that class is `lane`.
- Evidence that names no sha and no command. A gate that ran on a different
  commit proves nothing about this one, and a summary of a run is not the run.

## Running a review in `orchestrator` mode

Prefer parallel native subagents where the harness has them: several finished in
minutes where a single serial read took far longer, and an independent reader
caught a data-loss bug that the author's own read missed. Where the harness has
no subagents, a short-lived reviewer lane does the same job; spawn it, take the
report, retire it. A small delta is faster to read directly than to delegate.

## What to do with the verdict

Passing, and `autonomy` is `merge_on_verdict`:

```bash
orchestrate.sh merge <programme> <pr> <the-sha-you-reviewed>
```

Passing the sha matters: the gate refuses if the head moved since the verdict,
which is the case where a lane pushed while you were reading. With `autonomy:
ask` the gate stops at exit 4 and tells you it passed, so ask.

Failing: write `reviews/<pr>-<kind>.md`, then

```bash
orchestrate.sh post <programme> <pr> reviews/<pr>-<kind>.md
```

which strips host paths and refuses outright on a vendor word or a U+2014, so
nothing half-clean is ever posted. Send the findings to the lane as well, and
record the decision, so the next tick knows the lane was told.

## After every merge

Tell the owning lane. A lane left awaiting a verdict on a merged PR is what the
owed audit exists to catch, and it is the most expensive thing to leave behind.
