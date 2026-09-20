# programme.yaml

One file per programme, at `${ORCHESTRATE_HOME:-~/.claude/orchestrator}/<programme>/`.
Everything specific to a programme lives here: trunk, signing key, hosts, review
policy. The plugin itself holds none of it, so a second programme needs no code
change.

## Ownership is not in this file

`ORCHESTRATE_SESSION` holds the token that proves ownership, minted and printed
once by `orchestrate:takeover` and stored nowhere. `owner.json` keeps only its
hash and a derived label. Every verb that writes needs the token, in the
environment or as `--session`. See the takeover skill.

## What reads it

Read by a small flat parser, not a YAML library. It understands top-level
scalars, nested blocks, inline maps and inline lists. It does NOT process escape
sequences: write a regular expression with single backslashes, as in
`agents.yaml`. Block lists (`- ...`) are skipped by the parser deliberately; the
review classes are read by you, as text, not by the scripts.

## Keys

| key | read by | meaning |
|---|---|---|
| `trunk` | merge gate | the only branch a merge may target |
| `never_merge_into` | merge gate | branches that refuse before anything else is checked |
| `autonomy` | merge gate | `merge_on_verdict` merges on a passing verdict; `ask` stops at the gate and exits 4. Set it deliberately at adopt time |
| `signing.required` | merge gate | true refuses any commit in the range that is not signed |
| `signing.key` | merge gate | the ONLY signer accepted. A good signature from any other key is refused. Left as the `<...>` placeholder it is treated as unset, and any good signature passes. Never used to sign automatically |
| `attribution_guard`, `attribution_patterns` | merge gate | refuses commit messages matching the pattern. Anchor it to the shape of a trailer: a bare substring such as `generated with` refuses an honest body like `Generated with UPDATE_PARITY_FRAMES=1 so the frames match.` |
| `ci` | merge gate | `gate` reads the checks in code and refuses anything not green; `ignore` leaves CI to your judgment |
| `repo` | merge gate | REQUIRED. The local checkout the gate reads evidence from. Never defaulted: an unset `repo` refuses the merge rather than reading the caller's cwd |
| `gh_repo` | merge gate | exported as `GH_REPO` so gh resolves the right repository |
| `allow_fork_prs` | merge gate | a fork head is refused unless this is `true` |
| `send.max_chars` | send path | a message is one sanitised line, capped at this many characters |
| `default_agent` | adopt | agent kind assumed for a lane discovered with no profile |
| `loop.every` | tick, loop | cadence. Also the watchdog's unit: a gap past twice this is reported |
| `loop.max_ticks`, `loop.max_hours` | loop | bounds, `0` for none |
| `loop.tick_timeout` | loop | seconds a single tick may take before it is stopped and the loop moves on. Defaults to twice the cadence |
| `compact.at_pct`, `compact.keep` | tick | an idle lane over this percentage of context used is sent its compact command with the keep list |
| `handover.credit_threshold_pct` | you | NO code reads this. Run handover yourself once your harness reports usage over it; where a harness exposes no usage number, this key does nothing |
| `exit` | tick | see below |
| `placement.*` | preflight, cut 2 | floors, weights, lane cap, exclusive resources |
| `metrics.*` | cut 2 | Beszel hub rung. Empty means the Orca probe rung |
| `scrub.deny` | scrubber | pattern that refuses a post outright. Defaults to `attribution_patterns` |
| `review.*` | you | see `review-policy.md` |

## The exit expression

Evaluated once per tick. It may use only these counters:

| token | value |
|---|---|
| `open_prs` | open PRs on the repository |
| `owed` | lanes never told their PR merged or closed |
| `lanes_done` | lanes whose status is `done` |
| `lanes_total` | rows in `lanes.jsonl` |
| `scope_done` | 1 when a `SCOPE_DONE` file exists in the programme dir, else 0 |

Comparison and boolean operators only. Anything else makes the expression
`undecidable`, which is reported and never treated as true. A true expression
makes the tick exit 10 and the loop stop with reason `exit-condition`.

Marking scope finished is deliberate and manual:

```bash
touch ~/.claude/orchestrator/<programme>/SCOPE_DONE
```

## A filled example

```yaml
trunk: release-2
never_merge_into: [main, master]
autonomy: merge_on_verdict
signing: {required: true, key: "ABCD1234EF567890"}
attribution_guard: true
attribution_patterns: "^[[:space:]]*co-authored-by:[[:space:]]|^[[:space:]]*generated with acme-tool"
ci: ignore
allow_fork_prs: false
repo: /home/example/work/my-project
gh_repo: example-org/my-project
send: {max_chars: 2000}

default_agent: claude

loop: {mode: self_paced, every: 20m, max_ticks: 0, max_hours: 12}
compact: {at_pct: 85, keep: "keep the goal, the branch, the open PR and the last decision"}
handover: {credit_threshold_pct: 85, notify: true}

exit: "open_prs == 0 && owed == 0 && scope_done"

placement:
  floors: {disk_free_gb: 20, mem_free_gb: 4}
  weights: {disk: 40, ram: 30, load: 20, lanes: 10}
  max_lanes_per_host: 6
  exclusive: [e2e, proof]

metrics: {beszel_hub: "", token_ref: ""}

scrub:
  deny: "^[[:space:]]*co-authored-by:[[:space:]]|acme-tool"

review:
  default: {mode: orchestrator, kinds: [code], verdict: "line1 in {MERGE, MERGE WITH FOLLOW-UPS}"}
  nudge: {stale_pr: "PR #{pr} has had no review for {age}. Run {how} and post the verdict."}
  classes:
    - {match: {paths: ["**/proto/**", "**/migrations/**"]}, mode: orchestrator, kinds: [code, security]}
    - {match: {label: docs}, mode: none}
```

## Checking what the parser sees

```bash
awk '...'   # not needed: source the library and ask
bash -c '. scripts/lib.sh; prog_open <programme>; cfg trunk; cfg placement.floors.disk_free_gb'
```

A key that reads empty when you expected a value is almost always an inline map
nested more deeply than two levels, or an escape sequence the parser did not
process. Flatten it, or quote it plainly.
