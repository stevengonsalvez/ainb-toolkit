# demo

Film any running app as real product footage, then compose that footage into a styled
walkthrough video. Three skills:

| Skill | Does |
|---|---|
| `demo:capture` | Drives a real browser through an app with Playwright and records it: real clicks, real navigation, sharp in-browser camera zooms. Emits per-chapter mp4 plus `events.json` (timed marks with element rects and the camera box). |
| `demo:compose` | Turns that output plus a small config into the finished video: spotlight and short label at each mark, chapter cards, silent. Renders with HyperFrames. |
| `demo:brag` | Routes to the upstream [brag](https://github.com/latent-spaces/brag) skill for a launch video read from a repository rather than a running app. |

```
beats.mjs ──▶ demo:capture ──▶ takes/<chapter>.mp4 + events.json ──▶ demo:compose ──▶ demo.mp4
                   │                                                      │
             real clicks, zooms                             spotlights, labels, cards
```

## Install

```bash
claude plugin marketplace add stevengonsalvez/ainb-toolkit
claude plugin install demo@ainb-toolkit
```

`brag` installs alongside it as a declared dependency, from its own repository.

Other harnesses:

```bash
# Codex
codex plugin marketplace add stevengonsalvez/ainb-toolkit
codex plugin add demo@ainb-toolkit

# Copilot CLI
copilot plugin marketplace add stevengonsalvez/ainb-toolkit
copilot plugin install demo@ainb-toolkit

# Antigravity (local path install, from a checkout of this repo)
agy plugin install ./plugins/demo
```

None of these resolve plugin dependencies, so `demo:brag` needs brag installed by hand there.
The commands per harness are in `skills/brag/SKILL.md`.

`demo:capture` drives Playwright, so install its dependencies once, inside the skill
directory, following the setup section of its SKILL.md. Browsers and `node_modules` are not
committed to this repository.

## Which skill

- A logged-in app whose UI you want to show: `demo:capture`, then `demo:compose`.
- A repository you want to announce: `demo:brag`.
- Re-cutting existing footage with different labels or branding: `demo:compose` alone. The
  capture stays annotation-free so annotations are re-timeable without re-recording.

## Design

Capture and composition are separate on purpose. HyperFrames renders video from HTML and
cannot drive an authenticated app, which is why the footage is captured first and composed
after. Nothing brand-specific lives in the code path: colours, fonts, chapter titles and card
copy come from a config file, and each skill ships a worked example.

## Third-party contents

| What | Where | Licence |
|---|---|---|
| brag | not vendored; installed from [latent-spaces/brag](https://github.com/latent-spaces/brag) as a plugin dependency | MIT |
| GSAP (`gsap.min.js`) | `skills/compose/assets/template/` | GSAP standard "no charge" licence |
| Poppins, Montserrat (woff2) | `skills/compose/examples/fonts/` | SIL Open Font Licence 1.1 |

The fonts are example assets for the worked config. Supply your own in your config's `theme.fonts`.
