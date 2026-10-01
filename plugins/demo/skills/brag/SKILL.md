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

1. Confirm the upstream skill is present. It installs automatically as a dependency of this
   plugin, and appears in the skills list as `brag:brag`.
2. Invoke it with the Skill tool: `skill: "brag:brag"`, passing the user's own arguments
   through verbatim (it accepts flags such as `--tone`, `--format` and `--voice`).
3. Follow its instructions from there. Do not reimplement any part of it here, and do not
   paraphrase its steps: read what it says and do that.

If `brag:brag` is not in the skills list, the dependency did not install. Tell the user to run:

```bash
claude plugin install brag@ainb-toolkit
```

Then `/reload-plugins`. Do not fall back to writing a video pipeline by hand, and do not
vendor a copy of the upstream skill.

## Why it is wired this way

`demo` declares `"dependencies": ["brag"]` and the ainb-toolkit marketplace lists `brag` with
a github source pointing at `latent-spaces/brag`. Installing `demo` therefore installs brag
too, and dependencies resolve inside one marketplace without a cross-marketplace allowlist.

brag is pinned: the marketplace entry carries `"ref": "v0.3.0"` and
`"sha": "57ce4c9bb912f01a0078b154318bf67c5cbf780f"`, the commit that tag points to. An install
gets exactly that commit, whatever upstream pushes later.

To move the pin to a newer release, resolve the tag to its commit (annotated tags need the
second call to dereference), then update both fields together in `.claude-plugin/marketplace.json`:

```bash
T=$(gh api repos/latent-spaces/brag/git/refs/tags/vX.Y.Z --jq '.object.sha')
gh api repos/latent-spaces/brag/git/tags/$T --jq '.object.sha'   # the commit for "sha"
```

If the first call's `.object.type` is already `commit`, the tag is lightweight and its sha is
the commit.

## Credit

brag is by Shunit Haviv Hakimi, MIT licensed: https://github.com/latent-spaces/brag
