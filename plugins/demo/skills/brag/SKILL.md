---
name: brag
description: Turn the project in the current directory into a short, shareable launch video, by delegating to the upstream brag skill. Use when someone says "brag about this", "make a launch video", "turn this project into a video", "announce what I built", or wants a hype clip for a repo rather than a walkthrough of a running app. For filming an app's real UI, use demo:capture and demo:compose instead.
---

# demo:brag

A launch video for the project you just built. This skill is a router: the work is done by
[brag](https://github.com/latent-spaces/brag) by latent-spaces (MIT), which reads the project
code and renders a video with HyperFrames.

Nothing of brag is copied here. It is installed from its own repository, so it stays current
with upstream.

## Pick the right skill first

```
   project code, no running app        a running app you can click
   "announce what I built"             "show how the feature works"
            │                                    │
            ▼                                    ▼
      demo:brag ──▶ brag:brag            demo:capture ──▶ demo:compose
      launch/hype video                  real footage ──▶ styled walkthrough
```

| You want | Use |
|---|---|
| A launch or hype video for a repo, read from the code | this skill |
| Footage of an app's real UI, driven by real clicks | `demo:capture` |
| Spotlights, labels, chapter cards over that footage | `demo:compose` |
| A walkthrough of a feature in a logged-in app | `demo:capture` then `demo:compose` |

Both paths render with HyperFrames. They differ in the input: brag reads the repository,
capture drives a browser.

## How to run it

The upstream skill's name depends on the harness you are running in:

| Harness | Upstream skill | Install it if missing (pinned to `v0.3.0`) |
|---|---|---|
| Claude Code | `brag:brag` | `claude plugin install brag@ainb-toolkit`, then `/reload-plugins` |
| Codex | `brag:brag` | `codex plugin marketplace add latent-spaces/brag --ref v0.3.0` then `codex plugin add brag@brag` |
| Copilot CLI | `brag` | `git clone --branch v0.3.0 https://github.com/latent-spaces/brag` then `copilot plugin marketplace add ./brag` then `copilot plugin install brag@brag` |
| Antigravity | `brag` | `git clone --branch v0.3.0 https://github.com/latent-spaces/brag` then `agy plugin install ./brag` |

1. Find the upstream skill for your harness in the skills list. On Claude Code it installs
   automatically as a dependency of this plugin; everywhere else it is a manual install.
2. Invoke it the way your harness invokes skills (on Claude Code, the Skill tool:
   `skill: "brag:brag"`), passing the user's own arguments through verbatim (it accepts flags
   such as `--tone`, `--format` and `--voice`).
3. Follow its instructions from there. Do not reimplement any part of it here, and do not
   paraphrase its steps: read what it says and do that.

If the upstream skill is not in the skills list, show the user the install command from the
row for the harness you are running in, and stop. Do not fall back to writing a video pipeline
by hand, and do not vendor a copy of the upstream skill.

### Never invoke this skill from itself

Copilot CLI and Antigravity do not namespace skills, so this router is also named `brag`
there. The target is always the `brag` whose description does NOT say it delegates to the
upstream brag skill. This skill must never invoke itself. If the only `brag` in the list is
this one, upstream is missing: show the install command above.

Notes on the manual installs:

- Copilot CLI: the route above follows GitHub's documented forms (a local path for
  `marketplace add`, and `install PLUGIN@MARKETPLACE`), where the local clone is what holds
  the version. It has not been run against a live Copilot CLI. The plain
  `copilot plugin marketplace add latent-spaces/brag` also works per the docs but tracks the
  upstream default branch; the documented command shows no ref option.
- Antigravity: `agy plugin validate` rejects the upstream checkout ("missing plugin.json")
  but `agy plugin install` accepts it, placing the skill under
  `~/.gemini/config/plugins/brag/skills/brag/`. Upstream also ships extra SKILL.md copies
  under `.agents/`, `.claude/` and `.opencode/`, and the install copies those too.

## Why it is wired this way

`demo` declares `"dependencies": ["brag"]` in `.claude-plugin/plugin.json` only; the Codex
and portable manifests leave it out, since those harnesses do not resolve it. The ainb-toolkit
marketplace lists `brag` with a github source pointing at `latent-spaces/brag`. On Claude
Code, installing `demo` therefore installs brag too, and dependencies resolve inside one
marketplace without a cross-marketplace allowlist.

To hold brag at a known version, pin the marketplace entry with `ref` or `sha`. Unpinned, it
tracks the upstream default branch.

## Credit

brag is by Shunit Haviv Hakimi, MIT licensed: https://github.com/latent-spaces/brag
