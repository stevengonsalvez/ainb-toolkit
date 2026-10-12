# test-writer-pack

Test authoring and repair, distributed through
[Microsoft APM](https://github.com/microsoft/apm). One `apm install` puts the
same skill and agent into GitHub Copilot or Claude Code.

Where `qe-agent-pack` ships a whole quality-engineering toolkit, this pack does
one job: write the tests a module is missing, or repair the ones that broke,
without weakening what they check.

## Contents

### Skills (1)

| Skill | What it does |
|---|---|
| `test-writer-fixer` | Reads the code under test, writes tests that assert on values and pin boundaries, runs them twice, and reports which behaviour is now pinned |

### Agents (1)

| Agent | What it does | Source |
|---|---|---|
| `test-writer-fixer` | The same job as a delegated agent, for harnesses that route work to subagents | `gemini/agents/engineering/test-writer-fixer.md` |

## Install

```console
$ apm install https://github.com/stevengonsalvez/ainb-toolkit --path packages/test-writer-pack
```

Targets are pinned to `copilot` and `claude`. Install for one of them with
`apm install -t claude`.

## The score

Two runs are recorded here, because a single candidate arm cannot separate what
this pack contains from whether a model ever reaches for it.

`eval-gate-report.json` is the gate's own output for the normal arm, committed
unedited. `eval-gate-report-forced.json` is the same thing for an arm told to
use the skill. Both were measured at the pack commit named in their `subject`.

### Routing: does the model reach for it

| Arm | Fired on the 11 testing cases | Stayed silent on the distractor |
|---|---|---|
| Normal | 0 of 11 | yes, correctly |
| Told to use it | 11 of 11 | yes, correctly |

Routing precision on this casebook is **0.00**. Left to itself the model never
invoked the skill once. The cases ask for pytest tests over a small,
conventional Python service, and a capable model writes those unaided. The
distractor result is the one good sign: even when told to use the skill, the
run correctly stayed silent on a question that was about licensing rather than
testing.

### Content: do the instructions make the tests better

No, on this fixture. With the skill forced to run, every mechanical quality
signal moved slightly the wrong way against the same model with no skill
installed:

| Signal | No skill | Skill forced | Delta |
|---|---:|---:|---:|
| mutation kill rate | 0.3103 | 0.2916 | -0.0187 |
| seeded defects caught | 0.4318 | 0.4250 | -0.0068 |
| assertion strength | 0.9223 | 0.9164 | -0.0059 |
| changed-line coverage | 0.7895 | 0.7847 | -0.0048 |

The gate's verdict on that arm is **regression**, on the guarded signals
`mutation_kill_rate` and `seeded_defects_caught`.

The forced arm's *composite* score rose a long way, 0.5641 to 0.8351, and that
rise is worth distrusting: it comes almost entirely from the activation slot
the benchmark scores, not from better tests. A composite that can be moved that
far by invoking a skill, while every quality measure falls, is measuring the
wrong thing.

The normal arm's verdict is `pass`, which in this gate means no regression
rather than a demonstrated gain: delta `+0.0003`, 95% CI `[-0.0102, +0.0105]`,
an interval containing zero.

### What would settle it

A casebook whose no-skill arm actually fails. This fixture is too easy to
separate a testing skill from a model that already tests well, in either
direction. Until that exists, this pack has an honest record of being measured
and no evidence of making anything better.

Both arms ran against the same fixture, the same model and the same twelve
cases, with the CLI pinned to project settings so neither could see the
operator's own installed skills.

Licensed MIT.
