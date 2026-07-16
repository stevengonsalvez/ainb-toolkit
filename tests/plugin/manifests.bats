#!/usr/bin/env bats
load helpers

@test "all three provider manifests carry the same version" {
  V1="$(jq -r .version "$REPO_ROOT/plugins/godmode/.claude-plugin/plugin.json")"
  V2="$(jq -r .version "$REPO_ROOT/plugins/godmode/.codex-plugin/plugin.json")"
  V3="$(jq -r .version "$REPO_ROOT/.github/plugin/plugin.json")"
  [ "$V1" = "$V2" ]
  [ "$V1" = "$V3" ]
}

@test "marketplace declares godmode sourced from ./plugins/godmode" {
  jq -e '.plugins[] | select(.name == "godmode") | .source == "./plugins/godmode"' \
    "$REPO_ROOT/.claude-plugin/marketplace.json"
}

@test "hooks.json wires gate AND heartbeat on Stop, sync on SessionStart/PreCompact" {
  H="$REPO_ROOT/plugins/godmode/hooks/hooks.json"
  jq -e '.hooks.Stop[0].hooks | length == 2' "$H"
  jq -e '.hooks.Stop[0].hooks[0].command | contains("explainer-gate.sh")' "$H"
  jq -e '.hooks.Stop[0].hooks[1].command | contains("sync.sh")' "$H"
  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("sync.sh")' "$H"
  jq -e '.hooks.PreCompact[0].hooks[0].command | contains("sync.sh")' "$H"
  jq -e '.hooks.PostToolUse[0].matcher == "Write|Edit"' "$H"
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
