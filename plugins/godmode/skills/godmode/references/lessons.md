# Lessons — operational catches from live godmode runs

Consult before authoring any stage workflow, and whenever a stage result looks
wrong. Append new catches here after every programme (this file is the
machine's institutional memory — future adversarial prompts should cite it).

## Planning / review stage

- **Verify the revise actually edited the plan files.** A revise agent once
  updated only the charter and left the plan/goal artifacts untouched; the
  build stage would have shipped a P1 regression. Driver checks mtime AND
  content-vs-findings after every revise; patch gaps yourself before Execute.
- **Stale backlog items are common — court them.** Three consecutive backlog
  beads turned out already-fixed in-tree (fix present in the original commit,
  verified via `git show` + live probe). Every "fix X" item gets a
  is-it-already-fixed check FIRST; close-with-citation beats re-fix, and the
  charter records "do NOT re-fix" so later stages can't regress it.
- **Adversarial review must verify in-repo, not argue from the plan.** The
  catches above came from reviewers running `git show`/`grep`, not reasoning.

## Execute stage

- **Reviewer-not-author matters.** The adversarial reviewer caught a HIGH the
  builder AND the pair both missed (a playback loop that could hear and answer
  itself). Never let the builder review its own epic.
- **Pair disagreements are signal.** Force "surface disagreements, don't
  silently resolve" into the pair prompt.
- **Workstreams share one worktree.** Two builders editing simultaneously need
  provably disjoint file sets; otherwise serialise workstreams inside the
  workflow (sequential awaits), and serialise epics on stacked branches.

## Validation stage

- **Never pipe a long build's stdout** (`| tail`) — output buffers until exit
  and the agent's window closes on silence, reporting INCONCLUSIVE. Run
  `cmd > /tmp/x.log 2>&1` backgrounded; gate on an explicit `EXIT=$?` line.
- **Deploy flags matter mid-validation.** A redeploy with `--no-verify-jwt`
  flipped a gateway-401 contract test to a function-401 and "broke" the suite.
  Read the platform config (e.g. `config.toml verify_jwt`) before deploying.
- **Pre-existing failures must be PROVEN pre-existing** — merge-base diff
  showing the failing files untouched by the epic — then reported as such,
  never silently absorbed into "mostly green".
- **jq `//` swallows `false`.** Boolean extraction:
  `if has("k") then (.k|tostring) else empty end`. A correct `false` verdict
  once read as a test failure.
- **Moderation/LLM-backed asserts flake.** Borderline text can flip between
  refusal codes across runs; a single immediate re-run distinguishing flake
  from defect is legitimate — document it in the report.

## Driver / infrastructure

- **Commit-before-inspect trap:** agents may leave files pre-staged (MM in
  `git status`); a `git add X && git commit` then sweeps them in. Commit with
  explicit pathspec (`git commit -- <paths>`) or unstage first; always list
  the commit's files afterwards.
- **Never rebase onto a moved origin/main to re-sign** — base on `HEAD~N`.
  Never spawn GUI pinentry from the headless shell; sign only when the gpg
  cache is warm, else `--no-gpg-sign` + batch re-sign later.
- **Edit JSONL with a JSON parser, never sed/awk** — one bad shell edit
  blanked a record; validate zero empty lines before pushing.
- **Background-notification discipline:** harness-tracked work re-invokes you;
  don't poll it. ScheduleWakeup is the dashboard cadence + fallback heartbeat,
  not a poller.
- **Version-pinned runtimes:** know which suites need which runtime (e.g. a
  component suite that only passes under Node 22 via nvm) and bake it into the
  validation prompt.
- **Workflow results can truncate** — the full return lives in the task output
  file, per-agent detail in the run's `journal.jsonl`. Read those before
  diagnosing an "empty" stage.
- **Lease pushes never replay.** A rejected lease push means the CAS was lost,
  not "refetch and try the same write again"; blind replay would defeat the
  lock. State/charter may retry once, only after re-verifying the holder.
- **Explainer receipts are the only publish proof.** The domain publisher
  writes zero local state on success; godmode publishes phase explainers ONLY
  through explainer-publish.sh so the Stop gate has a receipt to check.
