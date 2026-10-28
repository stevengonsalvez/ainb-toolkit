# Project overlay

A project runs a synced copy of this engine. `scripts/sync-from-toolkit.sh`
overwrites the engine on every sync, so a project rule written into `SKILL.md`, a
reference or a script is lost the next time the project updates. Project rules go
into one project-owned file instead, `references/project-local.md`, and the engine
docs say where each part of it applies.

```text
 toolkit                           project skill dir
┌────────────────────┐  sync   ┌──────────────────────────────────┐
│ SKILL.md body      │────────▶│ engine: overwritten every sync   │
│ scripts/ refs/     │         │ (hook markers say where addenda  │
│ companions/        │         │  apply)                          │
└────────────────────┘         └──────────────────────────────────┘
          │ never written      ┌──────────────────────────────────┐
          └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ▶│ project-owned: config.yaml,      │
                               │ references/project-local.md,     │
                               │ local/ (outside engine dirs)     │
                               └──────────────────────────────────┘
```

## Who owns what

| path | owner | sync |
|---|---|---|
| `SKILL.md` body, `README.md`, `config.example.yaml`, `scripts/`, `references/`, `companions/` | toolkit | overwritten |
| `SKILL.md` frontmatter | project | kept |
| `config.yaml`, other `config.*.yaml` | project | never touched |
| `references/project-local.md` | project | created as a stub when missing, never written again, never pruned |
| anything outside the engine directories (for example `local/`) | project | never looked at, `--prune` included |

## Hook points

A hook point is a line in an engine doc holding only the marker
`<!-- project-local: <hook> -->`. The concertmaster reads `project-local.md` at boot
and after a compaction, and at each marker applies the section `## <hook>` as if it
were written there.

| hook | where | applied as |
|---|---|---|
| `hard-rules` | `SKILL.md`, end of § Hard rules | more hard rules, same weight as the template's |
| `boot` | `SKILL.md`, end of § Start | more boot steps, after step 5 and before step 6 arms the loop |
| `tick-extra` | `SKILL.md`, § The tick, last item of step 4 (Act) | more act steps, every tick, before Report |
| `merge-gate` | `SKILL.md`, end of § Merge gate | more merge requirements; the pr-sweeper brief carries them with the gate |
| `deploy` | `SKILL.md`, end of § Deploy windows | more rails or window steps; the deploy worker brief carries them |
| `teardown` | `SKILL.md`, end of § Retire and teardown | more checks before a retire or teardown; they can refuse, never unlock |
| `scripts` | `SKILL.md`, end of § Scripts | rows for the project's own scripts (kept outside the engine directories) |
| `brief-footer` | `references/lanes.md`, end of § Common footer | lines added to the rules block of every brief |
| `lane` | `references/lanes.md`, before § Placeholder map | `## lane: <label>` (for example `## lane: lane-a`) is appended to that lane's brief, last |

## File format

```markdown
# Project-local overlay

Free text up to the first `## ` heading: notes, never applied.

## tick-extra
- Every tick, read `$CM_HOME/inbox/acme-app-*.md` and put each in the report.

## lane: lane-a
- Run `local/acme-app-smoke.sh` before every cm:merge-ready.

## pending-upstream
- toolkit PR <link>: teardown refuses a worktree with a stale lock (local workaround: none)
```

- One section per hook, heading `## <hook>` or `## <hook>: <qualifier>`. An empty
  section adds nothing. Headings inside fenced code blocks are content, not sections.
- `## pending-upstream` is reserved: toolkit PRs the project is waiting on. It is
  read by people, never applied.
- Addenda add or tighten. One that would loosen a hard rule, the merge gate or a
  guardrail is not applied: the concertmaster surfaces it to the owner instead.
- After every sync the script lists hook points with no section yet (a new hook
  point is a new place you can add to) and sections whose hook no longer exists in
  the engine. The second list matters: those addenda are no longer applied
  anywhere, so move them to the right hook or delete them.

## Overlay or toolkit PR

| put it in `project-local.md` | send it to the toolkit as a PR |
|---|---|
| rules a session follows: database, secrets, copy, review etiquette | any change to `scripts/`, `*.jq`, hooks or tests |
| lane addenda: extra steps, checks, boundaries for one lane | a value a script reads: a new key in `config.example.yaml` with a neutral default |
| thresholds the concertmaster applies by judgment, that no script reads | a fix to an engine doc that is wrong for every project |
| extra merge, deploy or teardown checks that tighten the template | a new hook point (the marker plus a row in the table above) |
| pointers to the project's own scripts under `local/` | a bug in the engine, however small |
| | loosening anything in the template (make it a config key instead) |

A value a config key already covers belongs in `config.yaml`, not in the overlay.
Project-only code lives outside the engine directories (`local/` in the skill
dir, or the project's own scripts tree): sync never looks there and `--prune`
cannot remove it. It may call an engine script; it never patches or shadows one.

## Fixing the engine upstream

A local edit to an engine file is a patch that the next sync deletes, quietly.
Fix the toolkit instead:

1. Reproduce it on a toolkit checkout of `skills/concertmaster-template` with
   neutral fixtures (`acme-app`, `lane-a`, `host-a`), and write the failing case
   in `scripts/test/`.
2. Fix it, run every `scripts/test/*.sh` and `shellcheck -x scripts/*.sh
   scripts/hooks/*.sh scripts/test/*.sh`, and open a PR against the toolkit.
3. Note the PR under `## pending-upstream` in `project-local.md`.
4. Needed before it merges: sync from the PR branch, not by hand:
   `CM_TOOLKIT_URL=<fork url> scripts/sync-from-toolkit.sh --fetch --ref <branch> <target>`.
5. Once merged, sync from `main` again and drop the `pending-upstream` line.
