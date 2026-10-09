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

`eval-gate-report.json` in this directory is the output of the wololo-evals QE
gate, written by the gate itself and committed unedited.

**Read the verdict precisely. It says this pack did not make things worse, not
that it made them better.** The gate's `pass` is a no-regression verdict. On
the run recorded here the benchmark-score delta against the same model with no
skill installed was `+0.0003`, with a 95% confidence interval of
`[-0.0102, +0.0105]`. That interval contains zero, so there is no demonstrated
improvement. The mechanical signals moved the same small amount: mutation kill
rate 0.3103 to 0.3201, seeded defects caught 0.4318 to 0.4545.

Two things are worth knowing before anyone quotes those numbers.

The skill never activated. Across eleven treatment cases the model wrote the
tests itself and never invoked the skill, in either arm. The cases ask for
pytest tests over a small, conventional Python service, and a capable model
does not need help with that. This benchmark cannot currently show a
test-authoring skill beating a model that already knows how to write tests;
a case set the no-skill arm actually fails on would be needed for that.

Both arms ran against the same fixture, same model, same twelve cases, with the
CLI pinned to project settings so neither arm could see the operator's own
installed skills. `subject.commit` names the commit of this pack that was
measured.

Licensed MIT.
