#!/usr/bin/env bats
load helpers

@test "all three provider manifests carry the same version" {
  V1="$(jq -r .version "$REPO_ROOT/plugins/godmode/.claude-plugin/plugin.json")"
  V2="$(jq -r .version "$REPO_ROOT/plugins/godmode/.codex-plugin/plugin.json")"
  V3="$(jq -r .version "$REPO_ROOT/.github/plugin/plugin.json")"
  [ "$V1" = "$V2" ]
  [ "$V1" = "$V3" ]
}

@test "Godmode 0.3.0 removes false Claude-only driving claims" {
  jq -e '.version == "0.3.0"' "$REPO_ROOT/plugins/godmode/.claude-plugin/plugin.json"
  jq -e '.version == "0.3.0"' "$REPO_ROOT/plugins/godmode/.codex-plugin/plugin.json"
  jq -e '.version == "0.3.0"' "$REPO_ROOT/.github/plugin/plugin.json"
  ! grep -qi 'driving the loop is Claude-only' "$REPO_ROOT/plugins/godmode/.codex-plugin/plugin.json"
  ! grep -qi 'driving the loop is Claude-only' "$REPO_ROOT/.github/plugin/marketplace.json"
}

@test "Godmode ships its deterministic programme policy" {
  POLICY="$REPO_ROOT/plugins/godmode/scripts/programme_policy.py"
  [ -x "$POLICY" ]
  grep -q 'validate-state' "$REPO_ROOT/plugins/godmode/scripts/on-state-write.sh"
  grep -q 'creative-route' "$REPO_ROOT/plugins/godmode/skills/godmode/SKILL.md"
}

@test "marketplace declares godmode sourced from ./plugins/godmode" {
  jq -e '.plugins[] | select(.name == "godmode") | .source == "./plugins/godmode"' \
    "$REPO_ROOT/.claude-plugin/marketplace.json"
}

@test "Copilot marketplace entry has a source (its absence broke copilot install)" {
  # copilot plugin marketplace add rejects an entry with no source:
  # "Invalid marketplace.json: plugins.0.source: Invalid input". Paths are
  # relative to that source, so they must be plugin-dir-relative, not repo-root.
  M="$REPO_ROOT/.github/plugin/marketplace.json"
  jq -e '.plugins[0].source == "./plugins/godmode"' "$M"
  jq -e '.plugins[0].skills == "skills/"' "$M"
  jq -e '.plugins[0].hooks == "hooks/copilot-hooks.json"' "$M"
}

@test "hooks.json wires gate AND heartbeat on Stop, sync on SessionStart/PreCompact" {
  H="$REPO_ROOT/plugins/godmode/hooks/hooks.json"
  jq -e '.hooks.Stop[0].hooks | length == 2' "$H"
  jq -e '.hooks.Stop[0].hooks[0].command | contains("explainer-gate.sh")' "$H"
  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("sync.sh")' "$H"
  jq -e '.hooks.PostToolUse[0].matcher == "Write|Edit"' "$H"
}

@test "MUTATING hooks route through sync-hook.sh so the session id is threaded" {
  # Stop/PreCompact fire in EVERY session; without the firing session's id they
  # fell back to a checkout-global token and a bystander heartbeated the
  # driver's lease (A2). SessionStart is pull-only, so it needs no id.
  H="$REPO_ROOT/plugins/godmode/hooks/hooks.json"
  jq -e '.hooks.Stop[0].hooks[1].command | contains("sync-hook.sh")' "$H"
  jq -e '.hooks.PreCompact[0].hooks[0].command | contains("sync-hook.sh")' "$H"
  [ -x "$REPO_ROOT/plugins/godmode/scripts/sync-hook.sh" ]
  # and the wrapper actually exports what it read from stdin
  grep -q 'GODMODE_SESSION_ID="\$SID"' "$REPO_ROOT/plugins/godmode/scripts/sync-hook.sh"
}

@test "copilot hooks use the copilot schema (camelCase, bash/timeoutSec)" {
  C="$REPO_ROOT/plugins/godmode/hooks/copilot-hooks.json"
  jq -e '.version == 1' "$C"
  jq -e '.hooks.sessionStart[0].bash | length > 0' "$C"
  jq -e '.hooks.userPromptSubmitted[0].timeoutSec' "$C"
}

@test "own-plugin-sync.sh finds directory-source own marketplaces" {
  T="$BATS_TEST_TMPDIR/ainb-toolkit"; mkdir -p "$T"
  jq --arg p "$T" '.["ainb-toolkit"].installLocation = $p' \
    "$FX/known_marketplaces.json" > "$BATS_TEST_TMPDIR/km.json"
  run env KNOWN_MARKETPLACES_FILE="$BATS_TEST_TMPDIR/km.json" \
      PLUGIN_CACHE_DIR=/nonexistent \
      bash "$REPO_ROOT/skills/sync-learnings/scripts/own-plugin-sync.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"own marketplace: ainb-toolkit (directory)"* ]]
}
