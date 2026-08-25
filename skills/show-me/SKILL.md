---
name: show-me
description: 'Render the situation as ASCII diagrams, minimal prose, and one NEXT line. Two lanes, inferred unless forced. STATUS lane for a thing that exists - "/show-me", "where are we", "what''s the state of X", "is it green" - every cell grounded in a command run this turn. IDEA lane for a thing that does not exist yet - "/show-me --idea", "what is this issue", "explain your proposal", "what are the options", "explain this visually" - requirement and proposal drawn as boxes, with claims about existing code still grounded. NOT for "show me <file>", "show me the diff", "show me that function": those are plain reads.'
---

# show-me

Scannable in five seconds. Diagram for shape, table for facts, one line for what
happens next.

**Prose is the failure mode.** If a paragraph is forming, it belongs in a box, a
cell, or the bin.

## Lane selection

Two lanes. A flag forces one; with no flag, infer.

```
                      /show-me
                          │
                  ┌───────┴───────┐
                  │ flag given?   │
                  └───┬───────┬───┘
                  yes │       │ no
                      ▼       ▼
              ┌──────────┐  ┌──────────────────┐
              │ obey it  │  │ subject EXISTS?  │
              └──────────┘  └───┬──────────┬───┘
                            yes │          │ no
                                ▼          ▼
                          ┌─────────┐  ┌────────┐
                          │ STATUS  │  │  IDEA  │
                          └─────────┘  └────────┘
```

| flag | lane | subject |
|------|------|---------|
| `--status` | status | branch, PR, CI run, service, file on disk, running job |
| `--idea` | idea | issue, requirement, proposal, options, design not yet built |
| none | infer | exists → status; does not exist yet → idea |

**Both live and neither named → ask which.** Guessing the lane wastes the whole
render, same as guessing the subject.

Signals that the subject does not exist yet, so the lane is IDEA: the invoking
message says *what is*, *explain*, *propose*, *options*, *should we*; the
subject is an issue number with no branch; nothing has been built.

Everything below to `## Idea lane` is the STATUS lane. The IDEA lane keeps the
prose ban, the bullet cap, and the NEXT line, and re-targets grounding.

## Status lane — order (fixed)

```
┌─────────┐  ┌─────────┐  ┌─────────┐  ┌──────┐  ┌─────────┐
│ PROBLEM │─▶│ BEFORE/ │─▶│  TABLE  │─▶│ NEXT │─▶│ bullets │
│ diagram │  │  AFTER  │  │ evidence│  │  →   │  │  ≤5     │
└─────────┘  └─────────┘  └─────────┘  └──────┘  └─────────┘
              only if                             optional,
              changed                             residual facts
```

## Subject

Draw the thread the invoking message names. **If several are live and none is
named, ask which — do not guess.** Guessing the subject wastes the whole render.

This output REPLACES the usual turn-end state block. Never emit both.

## Step 1 — ground every row, this turn

**An evidence cell may only cite a command whose output appears in this
turn's tool calls.** Not remembered, not inferred from an earlier turn, not
reconstructed in the right format. A cell you cannot back with a this-turn tool
result is `UNVERIFIED`. Run at least one grounding command per row before
drawing anything.

**Quote a value from the output, never a bare verdict.** A count, a sha, an exit
code, a run id — `23/0`, `exit 1`, `1f8a6312`, `total_count=20`. A cell holding
only `green` / `ok` / `idle` is a verdict, and a verdict is what gets
backfilled from memory without noticing. A cell that cannot quote a value from
this turn's output is `UNVERIFIED`.

That is the whole defence: running the command and then transcribing a
remembered number is the failure this skill exists to stop, and specific values
are far costlier to fabricate than verdict words.

This rule is the skill. Everything else is layout.

Before any CI / merged / released row, `git fetch --quiet` first — remote-tracking
refs are stale until you do, and a stale ref reports merged work as unmerged.
Use `git fetch --tags --quiet` for a released row: a fresh release tag is
otherwise missed and reads as a false negative. Fetch counts as a read. Skip it
entirely when the subject is not a git repo (a service, a config posture, a
fleet).

Common cases; any read command qualifies.

| claim | command | keyed on |
|-------|---------|----------|
| branch / commit | `git log --oneline -1`, `git rev-list --count A..B` | — |
| **CI green** | `gh run list --commit <sha>` or `gh api repos/{o}/{r}/commits/<sha>/check-runs` | **exact sha** |
| PR checks | `gh pr checks N` | PR head |
| merged | `gh pr view N --json state,mergeCommit`, `git branch -r --contains <sha>` | ancestry |
| released | `git tag --contains <sha>` | ancestry |
| mergeable | `gh pr view N --json mergeable,mergeStateStatus` | PR |
| file / config | `test -f`, `grep -c <pat> <file>` **only when the file exists** | — |
| tests | run under a 60s timeout; on timeout `UNVERIFIED (not run; settle with: <cmd>)` | — |

`grep -c` on a missing file exits 2 with a warning, it does not print `0`. Prove
absence with `test -f`.

Reads only. `/show-me` never merges, pushes, closes, or writes.

### Exact-sha for CI, ancestry for containment

Two different questions, two different predicates. Conflating them is the
classic wrong call.

```
"is it green?"          "is it merged / released?"
      │                           │
 exact sha match            ancestry is fine
      │                           │
 run head == subject      merge-base --is-ancestor
      │                     <sha> <main|tag>
 else UNVERIFIED
```

**Ancestor-green proves nothing about HEAD** — a green run on `HEAD~5` says
nothing about whether the five commits since broke it, and that is the question
you are asking. `gh run list --branch main --limit 1` is branch-keyed and returns the
newest run of *any* workflow: never cite it for a specific sha.

### UNVERIFIED and pending are first-class values

| value | means | render |
|-------|-------|--------|
| `UNVERIFIED` | could not be grounded this turn | say what would settle it |
| `pending` | check running, not yet terminal | ARM a read-only watch, then render |

Never drop an ungroundable row and never show a stale value as fact. A dropped
row reads as "nothing there"; a stale row reads as truth.

```
| main CI | UNVERIFIED | no run for this sha (path-filtered) |
```

## Step 2 — PROBLEM diagram

Box-and-arrow, ≤80 chars, technical labels inside boxes, never sentences.
Glyphs `┌─┐ │ └─┘ ─▶ ◀── ▼ ▲`. Show the mechanism, not the story.

## Step 3 — BEFORE / AFTER

**Only when something actually changed** — a fix, a migration, a transition.
Omit for an explanation or a plain status read; never draw an empty AFTER. A
table is the fallback when the change is data posture (counts, versions, sizes)
rather than flow.

## Step 4 — evidence table

Pipe table, ≤8 rows. One column is always **how it was checked this turn**.

When more than 8 rows qualify, the survivors are those **needing action or
carrying risk**; collapse the rest into one row (`+6 others idle`). Never drop a
risky row to fit — collapse the boring ones instead. The collapse row carries its
own checked-this-turn cell: the one command that enumerated them.

## Step 5 — NEXT

One line, one action, naming a concrete artifact — a PR number, a command, a
file. Never "continue work on X". At most two hops:
`NEXT → merge #707, then → cut 1.22.3`.

Legal terminals:

| situation | line |
|-----------|------|
| work outstanding | `NEXT → merge #707 (green 23/0, CLEAN)` |
| nothing left | `NEXT → nothing. merged 1f8a6312, main CI 20/20` |
| explanation only | `NEXT → none (explanatory read)` |
| blocked | `NEXT → blocked: <what>`, naming who unblocks it |
| checks running | `NEXT → wait: checks pending` — arm the watch, do not just offer it |

A merge NEXT requires `mergeable` + `mergeStateStatus`, not green checks alone —
a PR can be green and unmergeable.

When NEXT names an action, **offer to run it** via the structured question tool,
never a prose "say go". The three terminals with nothing to run — `nothing`,
`none`, `blocked` — get no offer. Stevie is the gate; the skill does not execute writes on its own
initiative. Never pad NEXT with unasked work to avoid saying "done".

## Step 6 — bullets

Residual facts that fit neither diagram nor table. Optional, ≤5, one line each,
tagged `[fact]` or `[inference]`. Not a prose channel: if a bullet needs a
second line, cut it.

## Idea lane

For a thing that does not exist yet: a requirement, a proposal, a fork.
Same ban on prose, same bullet cap, same one NEXT line, different shape. Like
the status lane, this output REPLACES the usual turn-end state block; never
emit both. Reads only, same as the status lane.

### Order (fixed)

```
┌───────────┐  ┌──────────┐  ┌───────────┐  ┌──────┐  ┌──────┐  ┌─────────┐
│REQUIREMENT│─▶│  TODAY   │─▶│ TRADE-OFF │─▶│ COST │─▶│ NEXT │─▶│ bullets │
│  diagram  │  │    vs    │  │  one per  │  │      │  │  →   │  │   ≤5    │
│           │  │ PROPOSED │  │   axis    │  │      │  │      │  │         │
└───────────┘  └──────────┘  └───────────┘  └──────┘  └──────┘  └─────────┘
                              only if a               omit if
                              real fork               none
```

| block | draw | omit when |
|-------|------|-----------|
| REQUIREMENT | what is being asked, as boxes | never |
| TODAY vs PROPOSED | the two shapes side by side | nothing exists to compare |
| TRADE-OFF | one diagram per axis of choice | no real fork |
| COST | what the recommendation gives up | it gives up nothing |

Lead with the recommendation inside the diagram, not in a sentence above it.
Label the recommended branch in the box.

### Grounding re-targets, it does not vanish

The rule that makes the status lane trustworthy applies here to every claim
about code that **already exists**. Only the proposal itself is exempt.

```
 claim about EXISTING code
   "get_entitlement has 3 branches"   ──▶ GROUND IT this turn
   "prod has duplicate club names"    ──▶ GROUND IT this turn
   "that trigger is ungated"          ──▶ GROUND IT this turn
          │
          └── cannot ground ──▶ render UNVERIFIED, do not drop

 claim about the PROPOSAL
   "a computed branch auto-revokes"   ──▶ tag [inference]
```

An ungrounded claim about existing code is the failure this lane invites: it
reads as analysis and ships as fact. Run the grep before drawing the box.

A **claims table** appears only when existing-code claims are load-bearing —
same `checked this turn` column as the status lane, ≤8 rows. No claims about
existing code, no table.

### NEXT in the idea lane

| situation | line |
|-----------|------|
| decision needed | `NEXT → pick grant model, then → write spec` |
| ready to build | `NEXT → run /interview on #3584` |
| pure explanation | `NEXT → none (explanatory read)` |

When NEXT names a decision, put it in the structured question tool with the
recommended option first — never a prose "which do you want?".

## Hard limits

| element | status lane | idea lane |
|---------|-------------|-----------|
| diagrams | PROBLEM, plus BEFORE/AFTER only if changed | ≤6 |
| tables | 1 evidence table, plus optional before/after table | claims table only when existing-code claims are load-bearing |
| bullets | ≤5, one line each | ≤5, one line each |
| prose paragraphs | **0** | **0** |
| HTML / artifacts | **never** — terminal only | **never** — terminal only |

Over the cap: **cut it, do not relocate it.** Not into a file, an artifact, or a
follow-up message. If it does not fit, it was not the key point.

## Why grounding is not optional

Four real calls from one session, each **true when first observed, false when
repeated** — rendering from memory reproduces all four by design:

| reported | actual |
|----------|--------|
| "fails all ubuntu, macOS 0" | had hit macOS twice that evening |
| "109 procs unkillable, needs reboot" | uninterruptible I/O, cleared themselves; reboot was authorised on the stale reading and was not needed |
| "PR #738 failing" | failure belonged to a head predating the fix |
| "main health unknown" | red, and knowable with one command |

A status view that is confidently wrong is worse than none: it stops people
looking.

## Worked example — status lane

```
PROBLEM
┌──────────┐   ┌──────────┐   ┌──────────┐
│ launchd  │──▶│ ainb     │──▶│ exit 1   │
│ plist ok │   │ bridge   │   │ no cfg   │
└──────────┘   └──────────┘   └──────────┘

BEFORE                AFTER
┌────────────┐        ┌────────────┐
│ err: no    │        │ err: names │
│ [fleet.br] │───────▶│ file+keys  │
└────────────┘        └────────────┘

| thing    | state      | checked this turn            |
|----------|------------|------------------------------|
| config   | absent     | test -f → missing            |
| service  | looping    | launchctl list → exit 1      |
| PR #707  | green      | gh pr checks → 23/0          |
| main CI  | UNVERIFIED | no run for this sha          |

NEXT → merge #707 (green 23/0, CLEAN), then → brew upgrade ainb

- config path is the user one, project-level is not read [fact]
- service respawns until config exists [inference]
```
