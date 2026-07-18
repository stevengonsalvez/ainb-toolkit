# Godmode Plugin Implementation Plan

## Overview

Repackage `/godmode` as the first plugin in an ainb-toolkit in-repo marketplace: hook-enforced status publishing (deterministic dashboard + Stop-gated /explain-to-me at phase transitions) and cross-machine run sync via a git sidecar on a dedicated ref, with a single-driver heartbeat lease.

Spec: `.agents/specs/2026-07-16-godmode-plugin.md` (approved 2026-07-16; amendments A1-A5 appended post-critique, same date).

## Current State Analysis

- godmode lives at `skills/godmode/` (SKILL.md 178 lines, 5 references, `scripts/beads_remote.sh`, `assets/programme-dashboard.html`), bootstrap-synced to `~/.claude/skills/godmode`.
- Root `.claude-plugin/plugin.json` declares the whole repo as legacy plugin "claudecode-bootstrap" (non-standard `paths` field, never installed; only `scripts/build-catalog.sh:65` references the name). No `marketplace.json` exists; `scripts/update-externals.sh:139` already anticipates one at root.
- Bootstrap sync is additive-only (`bootstrap.js:705-782`): deleting `skills/godmode` leaves a stale `~/.claude/skills/godmode` on every machine. Only deletion precedent: deprecated-dirs cleanup at `bootstrap.js:1679-1687`.
- Two recreation vectors after the move: (a) generated `setup-external.sh` copies plugin-cache skills into `~/.claude/skills/<name>` (`bootstrap.js:1434-1447`); (b) `/sync-learnings` orphan scan builds its internal set from `skills/*/` only (`skills/sync-learnings/SKILL.md:103-127`) and would offer the stale home copy as a "→repo new" candidate.
- `bin/generate-catalog.sh:85-104` ALREADY emits a `plugins:` section from `plugins/<name>/skills/` on regen.
- `{{HOME_TOOL_DIR}}` in `skills/godmode/SKILL.md:80` is substituted by bootstrap at copy time; a plugin install does NOT run that substitution, so the token must go.
- Dashboard publish today is model-driven (SKILL.md:103-105 LOOP step 3), the exact skippability complaint.
- `beads_remote.sh` hardcodes `.beads/issues.jsonl` in 2 places (lines 24, 72), uses `update-index --cacheinfo` WITHOUT `--add` (fails for new paths), and its validation is JSONL-count-specific. Push-reject doctrine is refetch+replay (`state-and-beads.md:76-80`); a lease write must NOT replay (reject = CAS loss).
- `publish_explainer.py` writes NO local state on success; success evidence is exit 0 + stdout `live (KV lag <=60s): https://<domain>/<path>/`. The stable URL is the domain mount path, not the per-publish here.now slug. A Stop-hook gate therefore needs a receipt file written by a wrapper, not a filesystem artifact of the publisher.
- Auth for non-interactive publish: `$HERENOW_API_KEY` or `~/.herenow/credentials` (0600); both scripts self-load. No keychain anywhere.
- Manifest schemas verified from installed ponytail/caveman clones: Claude `marketplace.json` {name, owner{name,url}, plugins[{name, source, description, category}]}; Claude `plugin.json` minimal {name, version, description, author}; Codex adapter `.codex-plugin/plugin.json` with `"skills": "./skills/"` + `interface` block, hooks reused from Claude-format `hooks/hooks.json` (env `PLUGIN_DATA` detection); Copilot manifests under `.github/plugin/` with `hooks/copilot-hooks.json` ({version:1, camelCase events, bash/powershell/timeoutSec, ${PLUGIN_ROOT}}). Copilot evidences ONLY `sessionStart` + `userPromptSubmitted` events.
- Hook contracts (official docs): Stop blocks via stdout `{"decision":"block","reason":"..."}` or exit 2; PostToolUse stdin carries `tool_name` + `tool_input.file_path`, matcher `Write|Edit`; SessionStart matchers `startup|resume|clear|compact`; PreCompact exists (`manual|auto`); plugins expand `${CLAUDE_PLUGIN_ROOT}`.
- Test infra: jest for bootstrap only (`bootstrap.test.js`); `tests/` is an empty stale pytest scaffold; NO bats, NO CI workflows.

## Desired End State

`claude plugin marketplace add stevengonsalvez/ainb-toolkit && claude plugin install godmode@ainb-toolkit` yields a working /godmode whose dashboard publishes deterministically on every state write, whose phase-transition explainers cannot be skipped (Stop gate, driver-session-scoped), and whose run state syncs machine-to-machine through sidecar files `state.json/charter.md/lease.json` on the dedicated ref `refs/godmode/<slug>` under a heartbeat lease (full identity: machine/user/session).

Verify: bats suite green, sandbox e2e green, real install on a second machine shows `/godmode status` reading the sidecar.

### Key Discoveries:
- `bin/generate-catalog.sh:85-104` makes `plugins/godmode/skills/` self-registering in catalog.yaml
- `bootstrap.js:1679-1687` is the slot for stale-skill cleanup
- `bootstrap.js:1434-1447` plugin skill copy-back must exempt own plugins
- Non-fast-forward push rejection is the CAS primitive for lease.json (`state-and-beads.md:76-80`)
- Never-commit-state rule exists in THREE places to amend: `SKILL.md:171-174`, `charter-template.md:47`, `stage-workflows.md:10-11`
- Explainer receipt must be hook-written: publisher leaves no local proof

## What We're NOT Doing

- Dual-driver merge (two machines driving concurrently)
- Family carve-up migrations (engineering/media/crypto plugins): direction only
- ainb TUI integration (lease/runs in Daemons screen)
- Degraded Codex/Copilot drive loop (they get status + sync parity; `run` refuses)
- Dashboard visual redesign (template carries over, tokens mechanized)
- CI wiring (repo has no workflows today; tests run via npm scripts)
- Retiring root legacy `.claude-plugin/plugin.json` (inert; separate cleanup later)
- Vendoring a publish client into the plugin (dependency on sibling here-now/explain-to-me skills stays, made VISIBLE via preflight + docs; vendoring noted as future work)

## Implementation Approach

Strangler: add marketplace + `plugins/godmode/` without touching the legacy skills/ sync for anything else. Hard-move the skill in the same PR, with both recreation vectors closed in the same wave. New hook scripts are self-contained POSIX shell + one Python renderer, all rooted at `${CLAUDE_PLUGIN_ROOT}` (Codex: `${PLUGIN_ROOT}`/`PLUGIN_DATA` detection). Enforcement is fail-open on infra errors, fail-closed only on model skips. Every phase lands with runnable proof.

Post-critique hardening (adversarial review 2026-07-16, spec amendments A1-A5): sidecar rides a DEDICATED ref `refs/godmode/<slug>` with ONE commit per sync (never origin/main, never an epic-branch fallback); every mutating push is lease-holder-gated; lease identity includes a session token; observers are structurally read-only (`status` never reconstructs local state, only `run`/`--take-over` adopts); state.json is Write/Edit-tool-only with a Stop-hook heartbeat backstop; bootstrap cleanup is diff-gated with backup.

---

## Phase 1: Marketplace scaffold + hard move
<!-- wave: 1 | depends_on: [] | files: [.claude-plugin/marketplace.json, plugins/godmode/.claude-plugin/plugin.json, plugins/godmode/.codex-plugin/plugin.json, .github/plugin/marketplace.json, .github/plugin/plugin.json, plugins/godmode/commands/godmode.md, plugins/godmode/skills/godmode/**, catalog.yaml] -->

### Overview
Create the in-repo marketplace, the godmode plugin manifests for all three providers, move the skill wholesale, fix the templating token, regenerate the catalog.

### Changes Required:

#### 1. Marketplace manifest
**File**: `.claude-plugin/marketplace.json` (new; coexists with legacy plugin.json, which no marketplace entry references)

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "ainb-toolkit",
  "description": "Plugins from the ainb-toolkit: agent orchestration and delivery machinery",
  "owner": { "name": "Steven Gonsalvez", "url": "https://github.com/stevengonsalvez" },
  "plugins": [
    {
      "name": "godmode",
      "source": "./plugins/godmode",
      "description": "Autonomous product factory: hook-enforced status, beads-synced cross-machine state, single-driver lease",
      "category": "orchestration"
    }
  ]
}
```

#### 2. Claude plugin manifest
**File**: `plugins/godmode/.claude-plugin/plugin.json` (new)

```json
{
  "name": "godmode",
  "version": "0.1.0",
  "description": "Autonomous product factory with hook-enforced status and cross-machine sync",
  "author": { "name": "Steven Gonsalvez", "url": "https://github.com/stevengonsalvez" }
}
```

#### 3. Codex adapter
**File**: `plugins/godmode/.codex-plugin/plugin.json` (new; ponytail pattern: skills path + interface block, hooks discovered from hooks/hooks.json by convention, host detected via `PLUGIN_DATA`)

```json
{
  "name": "godmode",
  "version": "0.1.0",
  "description": "Godmode status + sync parity for Codex (driving the loop is Claude-only)",
  "author": { "name": "Steven Gonsalvez", "url": "https://github.com/stevengonsalvez" },
  "skills": "./skills/",
  "interface": {
    "displayName": "Godmode",
    "shortDescription": "Programme status, dashboard publish, cross-machine sync",
    "category": "orchestration",
    "capabilities": ["Instructions", "Lifecycle hooks"],
    "defaultPrompt": ["/godmode status"]
  }
}
```

#### 4. Copilot adapter
**Files**: `.github/plugin/marketplace.json`, `.github/plugin/plugin.json` (new; ponytail layout, entries carry string paths into the plugin dir)

```json
{
  "name": "godmode",
  "version": "0.1.0",
  "description": "Godmode status + sync parity for Copilot CLI",
  "author": { "name": "Steven Gonsalvez", "url": "https://github.com/stevengonsalvez" },
  "commands": "plugins/godmode/commands/",
  "skills": "plugins/godmode/skills/",
  "hooks": "plugins/godmode/hooks/copilot-hooks.json"
}
```

marketplace.json mirrors Claude's with the same per-entry path fields. NOTE: ponytail is single-plugin-at-root; subdir paths are unverified against Copilot CLI. If install rejects subdir paths, fall back to documenting Copilot install as manual hook registration (parity table already allows it).

#### 5. Hard move
**Files**: `plugins/godmode/skills/godmode/**` (from `skills/godmode/**`)

```bash
mkdir -p plugins/godmode/skills
git mv skills/godmode plugins/godmode/skills/godmode
```

`beads_remote.sh` stays at `plugins/godmode/skills/godmode/scripts/beads_remote.sh` (skill-relative references in SKILL.md stay valid). New hook scripts go to `plugins/godmode/scripts/` (Phase 2/3).

In `plugins/godmode/skills/godmode/SKILL.md` line 80: replace `{{HOME_TOOL_DIR}}/skills/here-now/scripts/publish.sh` with `$HOME/.claude/skills/here-now/scripts/publish.sh` (bootstrap substitution never runs on plugin installs; Phase 5 rewrites this section anyway, this keeps the file valid in between).

#### 6. Slash command
**File**: `plugins/godmode/commands/godmode.md` (new; markdown command per official docs)

```markdown
---
description: "Godmode programme factory: init <north-star> | run [--take-over] | status | pause"
---
Invoke the godmode skill with arguments: {{args}}

Provider guard: if this host is not Claude Code (no Workflow/ScheduleWakeup tools),
only `status` is permitted; for init/run/pause reply that driving is Claude-only
and print the lease + sidecar status instead.
```

#### 7. Catalog regen

```bash
bash bin/generate-catalog.sh
```

godmode disappears from `components.skills`, appears under `components.plugins` (generator already supports `plugins/`).

### Success Criteria:

#### Automated Verification:
- [ ] `jq -e .plugins[0].name .claude-plugin/marketplace.json` = "godmode"
- [ ] `jq -e .name plugins/godmode/.claude-plugin/plugin.json` = "godmode"
- [ ] `test ! -d skills/godmode && test -f plugins/godmode/skills/godmode/SKILL.md`
- [ ] `! grep -r "HOME_TOOL_DIR" plugins/godmode/`
- [ ] `grep -A2 "plugins:" catalog.yaml | grep godmode` and `! grep -E "^\s+- godmode$" catalog.yaml` under skills
- [ ] `npm test` (jest bootstrap suite still green)
- [ ] `claude plugin marketplace add "$(pwd)" && claude plugin install godmode@ainb-toolkit` succeeds locally (then uninstall/remove to leave machine clean)

#### Manual Verification:
- [ ] `/godmode status` resolves via the installed plugin in a fresh session

---

## Phase 2: Status pipeline (deterministic publish + Stop gate)
<!-- wave: 2 | depends_on: [Phase 1] | files: [plugins/godmode/scripts/render_dashboard.py, plugins/godmode/scripts/on-state-write.sh, plugins/godmode/scripts/explainer-publish.sh, plugins/godmode/scripts/explainer-gate.sh, plugins/godmode/hooks/hooks.json, plugins/godmode/hooks/copilot-hooks.json, plugins/godmode/assets/programme-dashboard.html] -->

### Overview
Hooks own the mechanical status surface. Every state write renders + publishes the dashboard and pushes the sidecar; phase transitions demand a model-authored explainer, receipt-checked by a Stop gate.

### Changes Required:

#### 1. Deterministic renderer
**File**: `plugins/godmode/scripts/render_dashboard.py` (new)
**Changes**: stdin-free CLI: `render_dashboard.py --state <state.json> --beads <.beads/issues.jsonl> --charter <charter.md> --out explainers/<slug>.html [--pending <marker.json>]`. `--pending` (optional) stamps the staleness banner from the pending-publish marker; this is the banner's ONLY data path. Rework the moved template's exemplar rows ({{E0 name}}, emoji RAG cells) into loop markers (`<!-- row:epic -->...<!-- /row:epic -->`) the renderer expands from state.epics + beads records + `git log --oneline -15`. Driver-authored prose fields come from new optional state.json keys (`current_note`, per-epic `validation_summary`), rendered verbatim or defaulted to "(no note)". Template edits land in `plugins/godmode/assets/programme-dashboard.html` (same file, mechanized tokens).

#### 2. State-write hook
**File**: `plugins/godmode/scripts/on-state-write.sh` (new; PostToolUse)
**Changes**:

```bash
# stdin: PostToolUse JSON. jq -r '.tool_input.file_path // .tool_output.file_path'
# no match on .agents/scratch/*-state.json  -> exit 0
# match:
#   render_dashboard.py --pending <marker-if-present> -> explainers/<slug>.html
#   publish: $HOME/.claude/skills/here-now/scripts/publish.sh explainers/<slug>.html \
#            --slug "$(jq -r .dashboard_slug state.json)"   (auth self-loads from ~/.herenow/credentials)
#   sync push: scripts/sync.sh push <slug>   (holder-gated, single-commit, debounced; Phase 3)
# marker lifecycle: successful publish DELETES .agents/scratch/<slug>-publish.pending;
#   failure (re)writes it {step, error, ts}. Publish/sync infra failures ALWAYS exit 0.
# EXCEPTION, lease lost: sync.sh left <slug>-lease-lost marker -> exit 2 with stderr
#   "godmode: lease lost to <holder>. Downgrade to read-only, post handoff note, stop
#   re-arming." (exit 2 feeds stderr to Claude; the ONE failure the model must see)
```

Publish failure never blocks (pending marker + `--pending` banner on next render). Lease loss DOES surface (exit 2): the spec's "old holder downgrades to read-only" edge needs wiring that reaches the model BEFORE its next destructive write, and this is it.

#### 3. Explainer wrapper (the receipt writer)
**File**: `plugins/godmode/scripts/explainer-publish.sh` (new)
**Changes**: wraps `$HOME/.claude/skills/explain-to-me/scripts/publish_explainer.py` (domain mode) else `publish.sh` (plain mode). On exit 0 AND stdout containing `live (KV lag` (domain) or a siteUrl (plain), append `{phase, url, ts}` to `.agents/scratch/<slug>-explainer-receipts.json`. The model MUST publish phase explainers through this wrapper (SKILL.md amendment, Phase 5). Receipt is the only artifact the gate trusts; publisher leaves no local proof (verified: `publish_explainer.py` writes zero local state).

#### 4. Stop gate
**File**: `plugins/godmode/scripts/explainer-gate.sh` (new; Stop hook)
**Changes**:

```bash
# stdin: Stop JSON. Fail OPEN (exit 0) on: jq/read errors, missing state file, no active programme.
# SCOPE, driver session only: exit 0 when stdin carries agent_id or hook_event_name !=
#        "Stop" (Workflow subagents surface as SubagentStop) OR session_id !=
#        state.driver_session_id (recorded by /godmode init|run at lease claim).
#        Bystander sessions in the same worktree are never gated and cannot burn the marker.
# Guard loops: .stop_hook_active == true -> exit 0 (belt) AND marker
#        .agents/scratch/<slug>-gate-blocked.<session_id>.<phase> allows exactly ONE
#        block per driver-session+phase (braces).
# Predicate: state.phase is a transition phase (per-epic SHIP completed, HUMAN_GATE, DONE)
#        AND no receipt for that phase in <slug>-explainer-receipts.json
#        AND machinery healthy (simply: no publish.pending marker present; fail open while
#        publishing is broken; the age comparison was uncomputable and is dropped)
# -> stdout {"decision":"block","reason":"Phase <X> shipped without its explainer.
#    Write the phase explainer and publish via ${CLAUDE_PLUGIN_ROOT}/scripts/explainer-publish.sh, then stop."}
```

#### 5. Hook wiring
**File**: `plugins/godmode/hooks/hooks.json` (new; Claude format, also consumed by Codex per ponytail portability convention)

```json
{ "hooks": {
  "SessionStart": [{ "matcher": "startup|resume|compact", "hooks": [{ "type": "command",
    "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh\" pull || exit 0", "timeout": 15,
    "statusMessage": "godmode: pulling run state" }]}],
  "PostToolUse": [{ "matcher": "Write|Edit", "hooks": [{ "type": "command",
    "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/on-state-write.sh\"", "timeout": 60 }]}],
  "Stop": [{ "hooks": [{ "type": "command",
    "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/explainer-gate.sh\"", "timeout": 10 },
    { "type": "command",
    "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh\" push --if-active || exit 0",
    "timeout": 30, "statusMessage": "godmode: heartbeat" }]}],
  "PreCompact": [{ "matcher": "manual|auto", "hooks": [{ "type": "command",
    "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh\" push --if-active || exit 0", "timeout": 30 }]}]
}}
```

All scripts no-op fast (<50 ms) when no godmode programme is active (no `.agents/scratch/*-state.json`), so the plugin is inert in non-godmode sessions. The Stop-entry `sync.sh push --if-active` is the HEARTBEAT BACKSTOP: driver turns end every tick, so quiet multi-tick workflows and Bash-written state (which never fire PostToolUse) cannot starve the lease into a false-stale takeover.

#### 6. Copilot hooks
**File**: `plugins/godmode/hooks/copilot-hooks.json` (new; only two evidenced events)

```json
{ "version": 1, "hooks": {
  "sessionStart": [{ "type": "command",
    "bash": "\"${PLUGIN_ROOT}/scripts/sync.sh\" pull || exit 0", "timeoutSec": 15 }],
  "userPromptSubmitted": [{ "type": "command",
    "bash": "\"${PLUGIN_ROOT}/scripts/staleness-note.sh\"", "timeoutSec": 5 }]
}}
```

`staleness-note.sh` (tiny, same file set): prints one line if sidecar heartbeat is stale, else silent.

### Success Criteria:

#### Automated Verification:
- [ ] `python3 plugins/godmode/scripts/render_dashboard.py --state tests/plugin/fixtures/state.json --beads tests/plugin/fixtures/issues.jsonl --charter tests/plugin/fixtures/charter.md --out /tmp/dash.html && grep -q E01 /tmp/dash.html` (no {{tokens}} remain: `! grep -o '{{[A-Z_]*}}' /tmp/dash.html`)
- [ ] `echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/nope.txt"}}' | plugins/godmode/scripts/on-state-write.sh; test $? -eq 0` (no-op path)
- [ ] `echo '{}' | plugins/godmode/scripts/explainer-gate.sh; test $? -eq 0` (fail-open path)
- [ ] gate blocks: fixture state at SHIP-complete phase, empty receipts, stdin Stop JSON with `session_id == driver_session_id` → stdout contains `"decision":"block"`
- [ ] gate scoping: same fixture but stdin carries `agent_id` (subagent) → exit 0, NO marker written; `session_id != driver_session_id` (bystander) → exit 0, NO marker
- [ ] gate loop guard: second invocation same driver-session+phase → exit 0
- [ ] gate fail-open on broken machinery: publish.pending present → exit 0 even with missing receipt
- [ ] marker lifecycle: failed publish writes pending marker; next successful run deletes it
- [ ] `jq -e .hooks.Stop plugins/godmode/hooks/hooks.json` shows both gate and heartbeat entries

#### Manual Verification:
- [ ] With a real `~/.herenow/credentials`, a fixture state write publishes an updated dashboard at the fixture slug

### Checkpoints (if applicable): none (Phase 7 carries the human-verify)

---

## Phase 3: Sidecar sync + lease
<!-- wave: 2 | depends_on: [Phase 1] | files: [plugins/godmode/scripts/sidecar_remote.sh, plugins/godmode/scripts/sync.sh, plugins/godmode/scripts/lease.sh, plugins/godmode/scripts/staleness-note.sh] -->

### Overview
Cross-machine state rides a DEDICATED ref `refs/godmode/<slug>` (spec amendment A1; never origin/main, never an epic-branch fallback): sidesteps branch protection and CI-on-main triggers, keeps main history free of heartbeat commits, keeps push rejection as the CAS primitive. ONE commit per sync carries state.json + charter.md + lease.json together. Every mutating push is holder-gated; observers are structurally read-only.

### Changes Required:

#### 1. Generalized plumbing
**File**: `plugins/godmode/scripts/sidecar_remote.sh` (new; plumbing pattern lifted from beads_remote.sh, which stays untouched for beads)
**Changes**: `sidecar_remote.sh pull|push <repo-dir> <slug>`. Ref: `refs/godmode/<slug>` (`GODMODE_SYNC_REF` override). Pull: `git fetch origin +refs/godmode/<slug>:refs/godmode-sync/<slug>` then `git show` per file from the fetched tip (absent ref/file = empty, not error). Push: build ONE commit containing ALL changed sidecar files via GIT_INDEX_FILE plumbing with `update-index --add --cacheinfo` (`--add` REQUIRED, paths new; verified gap in beads_remote.sh), parent = fetched tip (root commit when ref absent), `git push origin <c>:refs/godmode/<slug>`. Per-type validation (`jq empty` for *.json, non-empty charter.md; NO JSONL count checks). Rejection is CLASSIFIED before any verdict: remote-rejected/hook-declined/protected → exit 6, fail CLOSED, print "cross-machine sync disabled: refs/godmode/* not pushable on this remote" and write NOTHING anywhere else (the lease must live exactly where pulls read; the beads epic-branch fallback is categorically unsound for a lock). Non-fast-forward → exit 3 (CAS raced); NO blind replay mode exists, the only retry lives in the callers below AFTER re-verifying the lease holder from the refetched tree.

#### 2. Lease manager
**File**: `plugins/godmode/scripts/lease.sh` (new)
**Changes**: `lease.sh claim|refresh|check|release <repo-dir> <slug> [--force]`. Identity = `<hostname -s>/<USER>/<session-token>` (spec amendment A2): token from hook stdin `session_id` when invoked by a hook, else from `.agents/scratch/<slug>-session-token` (written at claim: PPID + start-ts). FULL-identity compare: same host + user, different session = foreign holder, contention like any other. `claim`: pull; lease empty or heartbeat older than `GODMODE_LEASE_TTL` (default 1800 s) → push ours; fresh + foreign → exit 4 refused, printing holder + age; `--force` bypasses freshness (command layer confirms with the human first). Claim also records `driver_session_id` for the Stop gate. `refresh`: pull, verify holder == self FIRST (mismatch → exit 5 "lease lost" + touch `.agents/scratch/<slug>-lease-lost` marker, push nothing); then heartbeat push; exit 3 race → re-pull, re-verify holder, ONE retry; still foreign → exit 5. `check`: read-only holder/age/fresh|stale, exit 0/4. Timestamps ISO-8601 UTC via `date -u`.

#### 3. Sync orchestrator
**File**: `plugins/godmode/scripts/sync.sh` (new)
**Changes**: `sync.sh pull|push|adopt|discover [--if-active] [slug]`.
- `pull`: slug autodetected from `.agents/scratch/*-state.json` (none → exit 0 in <1 s, the inert-session guarantee); fetch sidecar into cache `.agents/scratch/.godmode-sync/<slug>/`. NEVER writes `<slug>-state.json`.
- `discover`: `git ls-remote origin 'refs/godmode/*'` → slug list. The fresh-machine entry point (resolves the contradiction the spec's SessionStart diagram had: hooks stay local-inert; the COMMAND layer discovers).
- `adopt <slug>`: explicit reconstruction of `.agents/scratch/<slug>-state.json` + charter from sidecar (machine-local fields `running_task`/`running_run_id`/`driver_session_id` re-initialized). Called ONLY by `/godmode run` after a successful lease claim or confirmed `--take-over`. `/godmode status` reads the sync cache directly and never adopts: observers hold no scratch state, so observer machines structurally CANNOT trigger mutating hooks (kills the PreCompact-clobber vector at the root, spec amendment A3).
- `push`: holder-gate FIRST via `lease.sh refresh` (exit 5 → push NOTHING, keep the lease-lost marker for on-state-write.sh to surface, exit 0 toward the hook); then derive durable subset (drop machine-local fields), single-commit push via sidecar_remote.sh. Debounce: skip entirely when durable subset unchanged AND heartbeat younger than TTL/2 (at most ~1 heartbeat commit per tick even if state was written twice). `--if-active`: only when phase != DONE. `GODMODE_SYNC=local` (charter/env toggle, spec amendment A5) disables all remote sync: single-machine programmes pay zero push cost.

### Success Criteria:

#### Automated Verification:
- [ ] Round-trip vs throwaway bare remote on `refs/godmode/<slug>`: push from clone A, pull from clone B, state.json identical; remote `main` history untouched
- [ ] First-ever push works (ref absent → root commit; proves `--add`)
- [ ] Single-commit invariant: one sync push advances the ref by exactly one commit carrying all changed files
- [ ] CAS: two clones claim same lease concurrently; exactly one exit 0, other exit 3/4
- [ ] Same-host two-session contention: second session token claims → exit 4 refused
- [ ] Stale takeover: heartbeat backdated > TTL → foreign claim succeeds
- [ ] Zombie writer: clone A loses lease to B, A runs `sync.sh push` → remote state still B's content, A gains lease-lost marker, A pushed nothing
- [ ] Unrelated-commit race: dummy commit lands on the ref between A's fetch and push → refresh re-verifies + retries once, succeeds, NO false lease-lost
- [ ] Protected remote: bare remote with `pre-receive` rejecting `refs/godmode/*` → exit 6 fail-closed message, nothing written to any other ref/branch
- [ ] Inert paths: `sync.sh pull` with no state file exits 0 in <1 s; `sync.sh push` on an observer (no scratch state) exits 0 pushing nothing
- [ ] Corrupt-json push refused: `echo '{' > state.json` → push exits non-zero, remote unchanged
- [ ] Debounce: two state writes within one tick window produce one sidecar commit

#### Manual Verification:
- [ ] Second clone simulating machine B: `discover` → `status` (reads cache, no adopt) → `run --take-over` (confirm → claim → adopt) flow behaves per amended spec

---

## Phase 4: Close the recreation vectors (bootstrap + sync-learnings + manifests)
<!-- wave: 2 | depends_on: [Phase 1] | files: [bootstrap.js, bootstrap.test.js, external-dependencies.yaml, skills/sync-learnings/SKILL.md, skills/sync-learnings/scripts/own-plugin-sync.sh] -->

### Overview
Stop every mechanism that would resurrect `~/.claude/skills/godmode` or fight the plugin install; teach /sync-learnings the git-native own-marketplace flow.

### Changes Required:

#### 1. Stale-skill cleanup
**File**: `bootstrap.js`
**Changes**: add `const MIGRATED_TO_PLUGINS = ['godmode'];` and, in the deprecated-dirs cleanup slot (~line 1679-1687), DIFF-GATED cleanup across ALL provider homes bootstrap synced to (claude AND codex/copilot targetSubdirs, which also carry the stale drive-capable copy): content-identical to `plugins/godmode/skills/godmode` (canon() normalization from sync-learnings Step 4) → remove; DIVERGENT (possible unsynced /reflect learnings, exactly what the learnings pipeline protects) → move to `~/.claude/skills/.godmode.pre-plugin-backup-<date>/` and print "local edits preserved at ..., reconcile via /sync-learnings v2". Never plain-delete divergent content.

#### 2. Own-plugin copy-back exemption
**File**: `bootstrap.js` (~1434-1447)
**Changes**: in the setup-external.sh generation loop: (a) skip the plugin-cache→`~/.claude/skills` copy when the dep entry has `own-plugin: true` (plugin skills must live ONLY in the plugin install; the flat copy is what sync-learnings diffs against); (b) emit SCOPED install `claude plugin install <name>@<marketplace_id>` (unscoped `install godmode` is ambiguous across the 12 registered marketplaces) followed by `claude plugin update <name>@<marketplace_id> || true` so already-installed machines refresh instead of silently no-op'ing (bootstrap used to force-sync skill updates; plugin installs don't).

#### 3. Dependency manifest entry
**File**: `external-dependencies.yaml`
**Changes**: add under `claude-plugins` (mirrors the reflect precedent fields, plus the new flag):

```yaml
  - name: godmode
    own-plugin: true
    marketplace: stevengonsalvez/ainb-toolkit
    marketplace_id: ainb-toolkit
    in-repo-marketplace: ".claude-plugin/marketplace.json at repo root"
    plugin-source: "plugins/godmode/.claude-plugin/plugin.json"
    install: |
      claude plugin marketplace add stevengonsalvez/ainb-toolkit
      claude plugin install godmode@ainb-toolkit
    purpose: Autonomous product factory (own plugin; source of truth in this repo)
    has_skills: true
```

This also satisfies the orphan-scan grep (`- name: godmode`), so a lingering stale home copy is suppressed rather than offered as "→repo new".

#### 4. sync-learnings v2
**Files**: `skills/sync-learnings/SKILL.md`, `skills/sync-learnings/scripts/own-plugin-sync.sh` (new)
**Changes**:
- Ship detection as a SCRIPT, not prose (prose-only enforcement is the skippability class this whole plugin exists to kill): `own-plugin-sync.sh` resolves own-marketplace installs from `~/.claude/plugins/known_marketplaces.json` `installLocation` (covers BOTH github-cloned marketplaces under `marketplaces/` AND directory-source local-path installs, which never appear there; globbing `marketplaces/*/` alone misses the latter, exactly what Phase 1's own success criterion creates with `marketplace add "$(pwd)"`), matches remote/path against this repo, and emits sync candidates.
- Cache-drift step in the same script: diff the installed cache copy (`~/.claude/plugins/cache/ainb-toolkit/godmode/<version>/`) against the marketplace clone HEAD; in-session hot-fixes land in the CACHE, are invisible to clone-only diffing, and are destroyed by the next `claude plugin update`; surface them as sync candidates.
- SKILL.md Step 0 fork: for own-marketplace skills the sync mechanism is git (`git -C <clone> add plugins/<p>/ && git commit && git push`, or branch+PR per existing convention), then `claude plugin update <p>@ainb-toolkit` on other machines. Remove/caveat the "home side is NOT a git repo" assertion (lines 30-41).
- Internal-set computation (lines 103-127): union in plugin sub-skills from catalog.yaml `components.plugins`.
- Category 5c (after 5b, lines 72-94): `own-plugin: true` in external-dependencies.yaml → never copy-diff; git flow via the script.

#### 5. Bootstrap test
**File**: `bootstrap.test.js`
**Changes**: three tests: (a) seed sandbox home with a PRISTINE copy of the plugin skill → run bootstrap → assert dir removed; (b) seed a MODIFIED copy (edited SKILL.md) → assert moved to `.godmode.pre-plugin-backup-<date>/`, NOT deleted; (c) generated setup-external.sh contains `install godmode@ainb-toolkit` + `update godmode@ainb-toolkit` and NO copy line for godmode skills.

### Success Criteria:

#### Automated Verification:
- [ ] `npm test` green including the three new tests
- [ ] `node bootstrap.js --dump-config` unchanged shape (jest single-source contract intact)
- [ ] `grep -n "own-plugin: true" external-dependencies.yaml`
- [ ] `bash -n` passes on regenerated `~/.claude/setup-external.sh` in sandbox run AND on `skills/sync-learnings/scripts/own-plugin-sync.sh`
- [ ] `own-plugin-sync.sh` finds a directory-source marketplace in a fixture known_marketplaces.json (local-path coverage)

#### Manual Verification:
- [ ] Run real `node bootstrap.js` on this machine: `~/.claude/skills/godmode` gone, plugin copy untouched

---

## Phase 5: Constitution amendments (SKILL.md + references)
<!-- wave: 3 | depends_on: [Phase 2, Phase 3] | files: [plugins/godmode/skills/godmode/SKILL.md, plugins/godmode/skills/godmode/references/state-and-beads.md, plugins/godmode/skills/godmode/references/charter-template.md, plugins/godmode/skills/godmode/references/stage-workflows.md, plugins/godmode/skills/godmode/references/lessons.md] -->

### Overview
Rewrite the doctrine so the model's contract matches what the hooks now do; amend all three never-commit-rule copies consistently.

### Changes Required:

#### 1. SKILL.md
**File**: `plugins/godmode/skills/godmode/SKILL.md`
**Changes**:
- LOOP step 3 (was lines 103-105): dashboard publish is hook-owned; driver only keeps state.json truthful and writes `current_note`. On pending-publish marker: mention on dashboard, keep going.
- LOOP step 5 + INIT: lease protocol. INIT/run claims lease (records `driver_session_id` + writes the session token file); EVERY wake runs `lease.sh refresh` unconditionally, state changed or not (refresh subsumes check; quiet multi-tick workflows must not starve the heartbeat). Exit 5 or a `<slug>-lease-lost` marker → post handoff note, downgrade read-only, stop re-arming. `/godmode run` on non-holder: refuse with holder info unless stale (auto-claim) or `--take-over` (AskUserQuestion confirm, then `sync.sh adopt`).
- NEW non-negotiable: "state.json is written ONLY via the Write/Edit tool, never Bash redirection/jq/mv: the status + heartbeat hooks key on the PostToolUse event" (belt: Stop-hook heartbeat backstop; braces: refresh path compares state mtime vs last sidecar push and runs render+publish catch-up when Bash slipped through).
- `/godmode status` procedure: preflight (publish script present? credentials resolvable? else print "status publishing DISABLED on this machine: missing <X>"); fresh machine: `sync.sh discover` → pick slug → read sync cache directly. status NEVER adopts (observer model, amendment A3).
- Phase-transition duty: after SHIP/HUMAN_GATE/DONE, flip phase AND stamp `phase_since` (ISO ts), write phase explainer via `/explain-to-me`, publish through `${CLAUDE_PLUGIN_ROOT}/scripts/explainer-publish.sh` (receipt feeds the Stop gate). Name the gate so the model understands why a stop was blocked.
- state.json schema additions: `driver_session_id`, `phase_since`, `current_note`, optional per-epic `validation_summary`.
- Entry modes table: add `--take-over`; add provider-parity table (Claude full; Codex/Copilot status+sync only).
- Scripts section: document sidecar_remote.sh / sync.sh / lease.sh / explainer-publish.sh; beads_remote.sh unchanged for beads.
- Non-negotiables (lines 171-174): amend to "... never commit charters/state/dashboards/scratch/env files, EXCEPT the sidecar mirror on `refs/godmode/<slug>`, which hooks maintain via git plumbing".
- Version policy (resolves spec open question 6): semver; ANY change under `plugins/godmode/**` requires at least a patch bump; all three provider manifests carry the SAME version (bats-enforced, Phase 6).
- Driver re-entry prompt: unchanged path (`.agents/scratch/<slug>-state.json` stays the working copy; sidecar is the mirror).

#### 2. state-and-beads.md
**Changes**: replace `## Durability caveats` (lines 82-91) with `## Sidecar sync + lease` documenting: mirror layout on the dedicated ref `refs/godmode/<slug>` (single commit per sync, `GODMODE_SYNC=local` opt-out for single-machine runs), durable-subset rule (machine-local fields never sync), lease semantics (TTL 1800 s, CAS via push-reject, FULL identity machine/user/session so same-host sessions contend), observer model (status reads cache; only run/take-over adopts), resume-on-another-machine procedure (`sync.sh discover` → `run` → claim → `adopt`). Resume procedure section: add step 0 "sync.sh pull". Keep the root-bead durable-minimum note as fallback when the sync ref is unreachable.

#### 3. charter-template.md
**Changes**: line 47 never-commit amended same as SKILL.md; lines 49-59 LIVE DASHBOARD/LOOP PROTOCOL reference hook-owned publishing + lease check.

#### 4. stage-workflows.md
**Changes**: GROUND preamble (lines 10-11) never-commit amended; SHIP step 4 "Update dashboard + state" becomes "update state.json (hook publishes) + write phase explainer via explainer-publish.sh".

#### 5. lessons.md
**Changes**: append two entries: "lease pushes never replay (CAS)"; "explainer receipts are the only publish proof; publisher writes no local state".

### Success Criteria:

#### Automated Verification:
- [ ] `! grep -rn "never commit charters" plugins/godmode | grep -v "EXCEPT"` (all three copies amended)
- [ ] `grep -q "take-over" plugins/godmode/skills/godmode/SKILL.md` and `grep -q "Write/Edit tool" plugins/godmode/skills/godmode/SKILL.md`
- [ ] `grep -q "phase_since" plugins/godmode/skills/godmode/references/state-and-beads.md`
- [ ] `! grep -rn "{{HOME_TOOL_DIR}}\|{{TOOL_DIR}}" plugins/godmode/`
- [ ] SKILL.md line count within +60 of current 178 (constitution stays tight)

#### Manual Verification:
- [ ] Read-through: LOOP protocol steps match what hooks.json actually wires (no phantom duties left on the model)

---

## Phase 6: Test harness (bats + fixtures + sandbox e2e)
<!-- wave: 3 | depends_on: [Phase 2, Phase 3] | files: [tests/plugin/render.bats, tests/plugin/sidecar.bats, tests/plugin/lease.bats, tests/plugin/gate.bats, tests/plugin/manifests.bats, tests/plugin/e2e-install.sh, tests/plugin/fixtures/**, package.json] -->

### Overview
Net-new shell-test infra (none exists): bats units per script, fixture set, and a sandbox-HOME install e2e.

### Changes Required:

#### 1. Fixtures
**Files**: `tests/plugin/fixtures/{state.json,issues.jsonl,charter.md,stop-event.json,stop-event-subagent.json,stop-event-bystander.json,posttooluse-event.json,known_marketplaces.json}` covering: mid-programme state, SHIP-complete state, empty receipts, one populated receipt, subagent/bystander Stop events, directory-source marketplace entry.

#### 2. Unit suites
**Files**: `tests/plugin/{render,sidecar,lease,gate,manifests}.bats`
**Changes**: encode every Phase 2/3 automated criterion as a bats case (including the contention matrix: unrelated-commit race, protected remote fail-closed, zombie writer, same-host session contention, observer inertness, debounce); sidecar/lease suites build throwaway `git init --bare` remotes in `$BATS_TEST_TMPDIR`, protected-remote cases install a `pre-receive` hook there. `manifests.bats`: the three provider manifest versions are EQUAL, marketplace.json parses and points at `./plugins/godmode`. Guard: `command -v bats || { echo "brew install bats-core"; exit 1; }`.

#### 3. Sandbox e2e
**File**: `tests/plugin/e2e-install.sh`
**Changes**: `HOME=$(mktemp -d)` sandbox; `claude plugin marketplace add <repo-dir>` + `claude plugin install godmode@ainb-toolkit` (skip-if-no-claude-CLI guard); assert install path contains hooks/hooks.json + skills/godmode/SKILL.md; then drive hook scripts directly with fixture JSON on stdin from the INSTALLED location (proves ${CLAUDE_PLUGIN_ROOT}-relative pathing survives install); assert gate block + publish pending marker behavior (network publish stubbed via `HERENOW_API_KEY=stub` + `GODMODE_PUBLISH_CMD` override env in on-state-write.sh, default real).

#### 4. npm wiring
**File**: `package.json`
**Changes**: `"test:plugin": "bats tests/plugin"`, `"test:plugin:e2e": "bash tests/plugin/e2e-install.sh"`.

### Success Criteria:

#### Automated Verification:
- [ ] `npm run test:plugin` green
- [ ] `npm run test:plugin:e2e` green
- [ ] `npm test` still green

#### Manual Verification:
- [ ] none (this phase IS the verification net)

---

## Phase 7: Real-machine verification + docs
<!-- wave: 4 | depends_on: [Phase 4, Phase 5, Phase 6] | files: [README.md, docs/godmode-plugin.md] -->

### Overview
Prove the whole loop on the real machine, document install + cross-machine flow.

### Changes Required:

#### 1. Docs
**File**: `README.md`
**Changes**: new "Plugins" section: marketplace add/install lines, strangler note (skills/ legacy vs plugins/), pointer to docs.
**File**: `docs/godmode-plugin.md` (new)
**Changes**: install per provider, PREREQUISITES section (here-now + explain-to-me skills via bootstrap or manual, `~/.herenow/credentials` 0600; preflight prints "publishing DISABLED: missing <X>" when absent), hook inventory table, sidecar layout (`refs/godmode/<slug>`, `GODMODE_SYNC=local` opt-out), lease lifecycle diagram, machine-B runbook (discover / status / take-over), version-bump policy, troubleshooting (pending markers, lease lost, backup dirs from migration, orphan cleanup).

#### 2. Live verification (this machine)
Run: real `node bootstrap.js` (stale copy removed or backed up), real marketplace add + install from the repo, fixture programme in a scratch git repo with a throwaway remote: state write → dashboard published to a test slug, phase flip → Stop gate blocks → explainer-publish → stop allowed, sidecar visible on the throwaway remote's `refs/godmode/<slug>` (main untouched), `lease.sh check` correct from a second clone.

#### 3. Plugin-update semantics verification (resolves the sync-back delivery question)
On the real machine: (a) content change WITHOUT version bump → `claude plugin marketplace update ainb-toolkit && claude plugin update godmode@ainb-toolkit` → record whether the change arrives; (b) same with a patch bump → assert it arrives. Whichever way (a) lands, docs/godmode-plugin.md states the rule ("bump required" or "update suffices") from OBSERVED behavior, not assumption.

### Success Criteria:

#### Automated Verification:
- [ ] All previous phases' automated criteria re-run green (`npm test && npm run test:plugin && npm run test:plugin:e2e`)

#### Manual Verification:
- [ ] Dashboard URL loads with fresh timestamp after a state write, with NO model involvement
- [ ] Stop gate message reads sensibly when it blocks
- [ ] Second-clone `/godmode status` view matches machine A state

### Checkpoints (if applicable):
- **`[CHECKPOINT:human-verify]`**: Review the installed plugin end-to-end before merge
  - What was built: godmode plugin installed from the local marketplace, hooks live, sidecar on a throwaway remote
  - How to verify: 1) open the test dashboard URL, confirm fresh timestamp; 2) in the scratch session, flip fixture phase + attempt stop, confirm block + explainer flow; 3) `bash plugins/godmode/scripts/lease.sh check <scratch-repo> <slug>` from a second clone shows holder
  - Resume: Type "approved" or describe issues

---

## Testing Strategy

### Unit Tests: renderer (token completeness, row expansion, empty-beads edge, pending banner), sidecar plumbing (first-push --add, single-commit invariant, corrupt-json refusal, protected-remote fail-closed, main untouched), lease (CAS race, same-host session contention, TTL expiry, unrelated-commit race, refresh-after-loss, zombie-writer inertness), gate (fail-open matrix: bad stdin/no state/no programme/pending-marker; subagent + bystander exemption; block-once-per-session+phase), manifests (version equality)
### Integration Tests: hook wiring from INSTALLED plugin location; sync round-trip across two clones on refs/godmode/<slug>; publish pending-marker lifecycle with stubbed publisher; observer clone pushes nothing
### Manual Testing Steps:
1. Real install on this machine, fixture programme, watch dashboard update on state write with no model turn
2. Phase flip → stop → observe block reason → publish explainer via wrapper → stop succeeds
3. Second clone: status, stale-lease takeover after backdating heartbeat

## Performance Considerations

Hook budget: on-state-write.sh does render+publish+push inline (up to ~5 s on slow network) but ONLY on state.json writes (~once per tick); all other Write/Edit events exit in <50 ms via the file-path guard. Stop/SessionStart guards exit <50 ms when no programme is active, so the plugin adds no perceptible latency to normal sessions.

## Migration Notes

Per machine, once: `node bootstrap.js` (removes stale `~/.claude/skills/godmode` when pristine; DIVERGENT copies are backed up to `~/.claude/skills/.godmode.pre-plugin-backup-<date>/` for /sync-learnings reconciliation, never deleted), then `claude plugin marketplace add stevengonsalvez/ainb-toolkit && claude plugin install godmode@ainb-toolkit`. In-flight programmes: none expected; if one exists, finish it pre-merge or hand-copy its scratch state (sidecar adopt makes this a one-time non-event). Learnings flow for godmode changes moves to the git-native path (edit marketplace clone → push → `claude plugin update` elsewhere; version bump per the Phase 5 policy).

## References

- Original requirements: `.agents/specs/2026-07-16-godmode-plugin.md`
- Research journal (5-agent fan-out, file:line evidence): `~/.claude/projects/-Users-stevengonsalvez--agents-in-a-box-worktrees-by-name-ainb-toolkit--f-godmode--c3ac1178/7418daa3-e885-4de2-b272-7823c6fc9ce5/subagents/workflows/wf_6d1cfa05-3fc/journal.jsonl`
- Manifest exemplars: `~/.claude/plugins/marketplaces/ponytail/` (all four provider manifests), `~/.claude/plugins/marketplaces/caveman/`
- Plumbing pattern: `plugins/godmode/skills/godmode/scripts/beads_remote.sh` (post-move path)
- Hook contracts: https://code.claude.com/docs/en/hooks, https://code.claude.com/docs/en/plugin-marketplaces
