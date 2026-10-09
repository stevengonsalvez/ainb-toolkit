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

`eval-gate-report.json` in this directory, once published, is the output of the
wololo-evals QE gate, written by the gate itself and committed unedited. It
records the mutation kill rate and the seeded-defect catch rate this pack
scored against a fixture service, next to what the same model scored on the
same cases with no skill installed.

Read it as what it is: one benchmark, one fixture, one run, and
`subject.commit` says which commit of this pack was measured.
