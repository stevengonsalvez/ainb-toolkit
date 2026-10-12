---
name: test-writer-fixer
description: Write tests for code that has none, and repair tests that broke, without weakening what they check. Use when code changed and its tests need to follow, when a module has no tests, when a suite is failing, or when a green suite is suspected of proving nothing.
user-invocable: true
---

Write the tests the code is missing, or repair the ones that broke, so the suite
catches real defects rather than turning green.

A suite that cannot fail is worth nothing. Every test written here has to be
able to go red for a real reason, and the quickest way to weaken a suite is to
edit the code under test until its tests pass.

## Step 1: Read before writing

Read the code under test and the suite that already covers it. Name, before
writing anything:

- the behaviour to pin, in terms of inputs and outputs, not function names
- the input that would break that behaviour if it regressed
- what the existing tests already cover, so the new ones add something

Never edit the code under test to make a test pass. If the code looks wrong,
say so and leave it: a test that documents a bug is worth more than a green run
that hides one.

## Step 2: Write the tests

- Follow the conventions of the suite already in the repository: same runner,
  same layout, same naming.
- Assert on values, not on the fact that a call returned. `assert quote(...) ==
  842` catches a regression; `assert quote(...) is not None` catches nothing.
- Pin boundaries on the boundary itself and on both sides of it. Off-by-one is
  the defect this catches and nothing else will.
- Cover the error path as deliberately as the happy path: a rejected input, a
  malformed body, a value out of range.
- One behaviour per test, with a name that says what it pins.
- No sleeps, no dependence on clock, ordering or network. A test that fails
  every fiftieth run teaches the team to ignore failures.

## Step 3: Run what you wrote

Run the new tests, then run them again. A suite that passes once and fails the
second time is not finished.

If a test fails, decide which of the three it is before touching anything:

| The failure means | Do |
|---|---|
| The code genuinely changed behaviour | Update the expectation, keep the intent |
| The test was brittle | Make the test robust, keep what it checked |
| The code has a bug | Report it, leave the test red, change no source |

## Step 4: Report what is now pinned

Say which behaviour the tests pin and which input would break it. "Added five
tests" tells a reviewer nothing. "Pins the surcharge threshold at 20 kg, and a
parcel of exactly 20 kg now fails the old rounding path" tells them what they
gained.
