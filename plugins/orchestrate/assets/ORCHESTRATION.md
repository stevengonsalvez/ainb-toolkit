# House rules for this programme

Free text. The tick reads this file every time, so anything written here reaches
the next orchestrator even when it is a different agent on a different box.
Replace every line below with the real rules of the programme.

## What this programme is trying to finish

One paragraph. The exit condition in programme.yaml is the mechanical half of
this; say the human half here.

## Who decides what

| topic | decided by |
|---|---|
| design inside a lane's own goal | the lane |
| a seam between two lanes | the orchestrator, recorded as a decision event |
| anything outward or irreversible | a structured question to the human, always |

## How to nudge

- A lane that has been idle past one cadence with an open PR: ask it for the
  review report named in the review policy, quoting sha and command.
- A lane that is asking: answer from this file and from its goal. Escalate only
  what is genuinely the human's to decide.
- A correction to an earlier steer is a NEW decision event that names the one it
  replaces. Never edit history.

## Verdict rule

A lane's own claim is not a verdict unless the review policy for that PR class
is `lane`. Evidence must name the commit sha and the command that produced it.

## Standing answers

Write the answers that keep coming up, so the next tick does not ask again.
