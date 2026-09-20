# agents.yaml

How each agent kind is driven, and what its screen looks like in each state.
Patterns live here rather than in code, because a TUI change should be a config
edit. A lane's `agent` field selects the profile; everything after the first
word is ignored, so `claude opus` and `claude fable` both use the `claude`
profile.

## Fields

| field | used by | meaning |
|---|---|---|
| `start` | spawn | command that starts a fresh agent |
| `resume` | tick, send | command typed to bring a dead lane back. Typed into a shell prompt is the ONLY thing ever typed into a shell prompt |
| `headless` | loop | non-interactive invocation, for a driver that feeds it the tick prompt |
| `compact` | tick | the command that compacts context, sent with `compact.keep` appended |
| `idle` | classify | screen is at a prompt, nothing running |
| `busy` | classify | a turn is in progress |
| `asking` | classify | the agent is waiting on an answer |
| `ctx` | classify | matches the context readout; the LAST number in the match is taken |
| `ctx_means` | classify | `used` or `left`. A `left` reading is inverted so every caller compares context USED |
| `shell_prompt` | dead-shell guard | the screen is a shell, not an agent. Nothing is typed into it |

Patterns are extended regular expressions, matched against the tail of a screen
read. Write single backslashes: the parser does not process escape sequences.

## Provenance

Nothing here is invented. `observed` means it was matched against a live lane's
screen while this file was written. `cli-help` means it came from that binary's
own `--help`. `UNVERIFIED` means neither, and the file marks those inline too.

| profile | field | value | source |
|---|---|---|---|
| claude | start, resume, headless, compact | `claude`, `claude --continue`, `claude -p`, `/compact` | cli-help |
| claude | idle | prompt marker on its own line | observed |
| claude | busy | `esc to interrupt` | observed |
| claude | asking | numbered choice, or `Do you want` | cli-help |
| claude | ctx, ctx_means | bar-and-percentage readout, `used` | observed on lanes running a custom status line |
| codex | start, resume, headless | `codex`, `codex resume --last`, `codex exec` | cli-help |
| codex | compact, idle, busy, asking, ctx, ctx_means | as written | UNVERIFIED |
| agy | start, resume, headless | `agy`, `agy --continue`, `agy --print` | cli-help |
| agy | compact, idle, busy, asking, ctx | as written, `ctx` left empty rather than guessed | UNVERIFIED |
| gemini | idle | prompt marker, or its shortcut hint line | observed |
| gemini | start, resume, headless, compact, busy, asking, ctx | as written | UNVERIFIED |

A profile whose `ctx` is empty reports no context percentage rather than a wrong
one, and the compact step never fires for it. That is deliberate: a wrong
reading compacts a lane mid-task or lets one die full.

## The context readout, and getting it backwards

Two shapes exist in the wild. A plain status line reports context LEFT until
auto-compaction; a custom status line usually reports a percentage USED. They
look identical and mean the opposite, so set `ctx_means` from a real screen:

```bash
orchestrate.sh read <programme> <lane> 40
```

Watch the number as the lane works. Rising means `used`. Falling means `left`.
Getting it backwards makes the compact step fire at the wrong end, which either
wastes a lane's context or lets it run out mid-task.

## Adding or fixing a profile

1. Read a real lane of that kind in each state you care about.
2. Pick the shortest line that is present in that state and absent in the others.
   Prefer a literal phrase over a layout guess: box drawing and padding change
   between versions, phrasing changes less often.
3. Test the pattern before trusting it:

```bash
orchestrate.sh read <programme> <lane> 40 | grep -E '<your pattern>'
```

4. Put it in the programme's own `agents.yaml`, and mark anything you could not
   observe as UNVERIFIED rather than leaving it looking checked.

`classify` tries `shell_prompt`, then `asking`, then `busy`, then `idle`, and
returns `unknown` when none match. `unknown` is a signal that a pattern needs
fixing, not a state to act on.
