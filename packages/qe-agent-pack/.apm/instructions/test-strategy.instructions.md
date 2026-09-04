---
description: Test design defaults for this repository, applied to every test file.
applyTo: "**/*.test.*,**/*.spec.*,**/test_*.py,**/*_test.go,**/tests/**"
---

- Favour behavioural and integration tests that verify flows and outcomes over
  unit tests that pin internal wiring. A test that breaks on a refactor with no
  behaviour change is a liability, not coverage.
- One assertion subject per test. Name the test after the behaviour it proves,
  not the function it calls.
- Test the trust boundary: input validation, error paths that prevent data loss,
  and security checks are never simplified away.
- Non-trivial logic (a branch, a loop, a parser, a money or security path)
  leaves at least one runnable check behind. Trivial one-liners need no test.
- Property-based coverage belongs on edge-case-rich logic: parsers, money maths,
  state machines. Reach for it there, not everywhere.
- A green suite is a claim, not a proof. When a report says PASS but behaviour
  looks wrong, verify the artefacts before trusting the status.

Source: `copilot/AGENTS.md` (Engineering Defaults) and `agents/engineering/test-engineer.md`.
