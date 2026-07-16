#!/usr/bin/env bats
load helpers

setup() {
  cd "$BATS_TEST_TMPDIR"
  git init -q repo && cd repo
  git config user.email t@t && git config user.name t && git config commit.gpgsign false
  echo x > f && git add f && git commit -qm init
  mkdir -p .agents/scratch .agents/goals .beads
  cp "$FX/state-ship-complete.json" .agents/scratch/godmode-test-slug-state.json
  cp "$FX/issues.jsonl" .beads/issues.jsonl
  cp "$FX/charter.md" .agents/goals/godmode-test-slug-charter.md
  REPO="$PWD"
}

@test "gate fails open on empty stdin" {
  run bash -c "echo '' | '$SCRIPTS/explainer-gate.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gate blocks driver on transition phase without receipt" {
  run bash -c "stop_json=\$(jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json'); echo \"\$stop_json\" | '$SCRIPTS/explainer-gate.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"'
}

@test "gate blocks only once per session and phase" {
  bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'" >/dev/null
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
}

@test "gate exempts subagents and burns no marker" {
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event-subagent.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
  run bash -c "ls .agents/scratch/godmode-test-slug-gate-blocked.* 2>/dev/null"
  [ -z "$output" ]
}

@test "gate exempts bystander sessions" {
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event-bystander.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
}

@test "gate exempts non-transition phases" {
  cp "$FX/state.json" .agents/scratch/godmode-test-slug-state.json
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
}

@test "gate fails open while publishing machinery is broken" {
  echo '{"step":"publish","error":"x","ts":"t"}' > .agents/scratch/godmode-test-slug-publish.pending
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
}

@test "gate clears once the phase receipt exists" {
  echo '[{"phase":"E01_SHIP","url":"https://x","ts":"t"}]' \
    > .agents/scratch/godmode-test-slug-explainer-receipts.json
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
}

@test "gate respects stop_hook_active loop guard" {
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c, stop_hook_active:true}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
}

@test "on-state-write ignores unrelated writes" {
  run bash -c "echo '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/nope.txt\"}}' | '$SCRIPTS/on-state-write.sh'"
  [ "$status" -eq 0 ]
}

@test "on-state-write full path: publish success clears pending, failure marks it" {
  EV="$(jq -n --arg fp "$REPO/.agents/scratch/godmode-test-slug-state.json" \
      '{session_id:"sess-driver-1",tool_name:"Write",tool_input:{file_path:$fp}}')"
  run bash -c "echo '$EV' | GODMODE_PUBLISH_CMD=/usr/bin/false GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$status" -eq 0 ]
  [ -f .agents/scratch/godmode-test-slug-publish.pending ]
  run bash -c "echo '$EV' | GODMODE_PUBLISH_CMD=/usr/bin/true GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$status" -eq 0 ]
  [ ! -f .agents/scratch/godmode-test-slug-publish.pending ]
  [ -f explainers/godmode-test-slug.html ]
}

@test "on-state-write surfaces lease loss with exit 2" {
  echo "other/holder/x" > .agents/scratch/godmode-test-slug-lease-lost
  EV="$(jq -n --arg fp "$REPO/.agents/scratch/godmode-test-slug-state.json" \
      '{session_id:"sess-driver-1",tool_name:"Write",tool_input:{file_path:$fp}}')"
  run bash -c "echo '$EV' | GODMODE_PUBLISH_CMD=/usr/bin/true GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"lease lost to other/holder/x"* ]]
}

@test "explainer-publish writes receipt on success, none on failure" {
  printf '#!/bin/sh\necho "https://stub.here.now/abc"\n' > okpub.sh && chmod +x okpub.sh
  GODMODE_REPO="$REPO" GODMODE_EXPLAINER_CMD="$PWD/okpub.sh" \
    "$SCRIPTS/explainer-publish.sh" /dev/null godmode-test-slug E01_SHIP
  jq -e '.[0].phase == "E01_SHIP"' .agents/scratch/godmode-test-slug-explainer-receipts.json
  printf '#!/bin/sh\necho boom >&2; exit 1\n' > failpub.sh && chmod +x failpub.sh
  run env GODMODE_REPO="$REPO" GODMODE_EXPLAINER_CMD="$PWD/failpub.sh" \
    "$SCRIPTS/explainer-publish.sh" /dev/null godmode-test-slug E02_SHIP
  [ "$status" -eq 1 ]
  run jq -e 'map(select(.phase=="E02_SHIP")) | length > 0' .agents/scratch/godmode-test-slug-explainer-receipts.json
  [ "$status" -ne 0 ]
}
