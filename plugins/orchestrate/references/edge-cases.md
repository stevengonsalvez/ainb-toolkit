# Edge cases

What each situation looks like, and what already happens without you.

| situation | what happens | what is left to you |
|---|---|---|
| remote `terminal list` comes back empty while lanes are alive | ignored. Every indexed handle is read directly, so liveness never depends on a listing | nothing |
| a handle no longer resolves | re-resolved from the lane's worktree, the row is rewritten, a `restart` event with `action: rehandle` is appended | nothing, unless the re-resolve also fails: then the worktree is gone, so check the host |
| a send lands on a shell prompt | recorded `dead-shell`, the agent's resume command is typed instead, the message is resent once. Both attempts are events | if the second attempt is also `dead-shell`, the agent is not starting. Read the screen |
| a send returns without confirmation | recorded `unconfirmed`, not `delivered`. The owed audit still counts it as never told | read the lane and resend, or confirm by screen and note it |
| the host restarted and the orchestrator resumed | the watchdog reports the gap first, and every handle is re-verified before any send | re-read anything time sensitive before acting on it |
| a host is over the disk floor | a `DISK:` line names it | ask the owning lanes to clean. Never delete under a live lane |
| the host reading needs a terminal | ONE probe terminal per host, titled `orchestrate-probe`, found by that title and reused. It is a plain shell and the command is typed into it, because Orca documents `--command` as a startup command without saying whether it is shell-interpreted | nothing. If you see more than one probe terminal on a host, the title was changed or the recorded handle was lost; close the extras through Orca |
| the repository has open PRs on other bases | they are not counted, not audited and not retired against: every PR question is scoped to `trunk` | nothing. A long tail of PRs on another base would otherwise make every exit condition permanently false |
| you want to look without touching | `tick --observe`, and `status`, `read`, `owed`, `discover` and `adopt --dry-run`, all write nothing | use observe for the first tick after a takeover or a gap |
| the metrics rung cannot answer | `hosts.jsonl.src` records `unknown` and the number is absent, not guessed | say the reading is missing rather than assuming capacity |
| two suites that need the same exclusive resource | the resource is recorded per lane in `lanes.jsonl` | the second request waits or goes elsewhere. Cut 2 enforces this |
| a lane quotes gates that do not cover what it names | the verdict rule requires a sha and a command in the evidence | a lane's claim is not a verdict unless the review mode for that class is `lane` |
| you steered a lane wrongly | nothing automatic | record a NEW `decision` event naming the one it replaces. Never edit history |
| a report still carries host paths or vendor words | the scrubber refuses and nothing is posted | fix what it caught, in the report, not in the guard |
| a second orchestrator starts | refused unless the lock is stale past twice the cadence, or `--takeover` is passed. Refusal and takeover are both events | if the refusal surprises you, find the other session before forcing it |
| the loop stalled and no tick ran | the watchdog reports the gap on the next tick | re-arm the loop. The last action of every tick is to re-arm |
| a lane runs out of context mid-task | an idle lane over `compact.at_pct` is sent its compact command with a keep list | a busy lane is not compacted mid-task. Wait for it to go idle, or ask it to checkpoint first |
| the caller's shell is zsh | every script is bash with explicit argument reads and no reliance on word splitting | nothing. The test suite runs itself from zsh to prove it |
| a PR merged while its lane was never told | the owed audit finds it every tick | tell the lane, then drive `owed` to zero before the tick ends |

## Reading a screen that classifies as `unknown`

The agent's patterns in `agents.yaml` do not match what that TUI shows now.
Read the raw screen, fix the pattern, and do not fix it in code:

```bash
orchestrate.sh read <programme> <lane> 40
```

A UI change is expected to break a pattern. That is why the patterns are config.
`discover` and `adopt` report unmatched screens rather than guessing a state.
