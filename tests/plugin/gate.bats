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
  # -n first: `jq -e` returns 0 on EMPTY input, so asserting on it alone passes
  # against a do-nothing stub. -s slurps, making empty fail. Both are required.
  [ -n "$output" ]
  echo "$output" | jq -se '.[0].decision == "block"'
  echo "$output" | jq -se '.[0].reason | test("without its explainer")'
}

@test "gate blocks only once per session and phase" {
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  # FIRST call must actually block (else 'blocks once' is indistinguishable
  # from 'never blocks') and must leave the session+phase marker
  [ -n "$output" ]
  echo "$output" | jq -se '.[0].decision == "block"'
  [ -f ".agents/scratch/godmode-test-slug-gate-blocked.sess-driver-1.E01_SHIP" ]
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
}

@test "NEGATIVE CONTROL: a do-nothing gate must FAIL this suite" {
  # The suite's own honesty check. Every exemption test asserts absence of
  # output, which a stub satisfies; this proves at least one test can tell a
  # real gate from a stub. If this ever passes with STUB=1, the suite is lying.
  printf '#!/usr/bin/env bash\nexit 0\n' > stub-gate.sh && chmod +x stub-gate.sh
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$PWD/stub-gate.sh'"
  [ -z "$output" ]
  run bash -c "echo '$output' | jq -se '.[0].decision == \"block\"'"
  [ "$status" -ne 0 ]
}

@test "gate exempts subagents and burns no marker" {
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event-subagent.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
  run bash -c "ls .agents/scratch/godmode-test-slug-gate-blocked.* 2>/dev/null"
  [ -z "$output" ]
}

@test "gate exempts agent_id even on a Stop event (the exemption itself, not the event name)" {
  # The subagent fixture is SubagentStop, so it exits on the event-name check
  # and never reaches the agent_id branch. This drives agent_id directly.
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c, agent_id:\"agent-7\"}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -z "$output" ]
  run bash -c "ls .agents/scratch/godmode-test-slug-gate-blocked.* 2>/dev/null"
  [ -z "$output" ]
  # ...and the identical event WITHOUT agent_id does block (proves the guard is why)
  run bash -c "jq --arg c '$REPO' '. + {cwd:\$c}' '$FX/stop-event.json' | '$SCRIPTS/explainer-gate.sh'"
  [ -n "$output" ]
  echo "$output" | jq -se '.[0].decision == "block"'
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
  # the guard must be WHY nothing happened: no render, no litter
  [ ! -d explainers ] || [ -z "$(ls explainers 2>/dev/null)" ]
}

@test "on-state-write ignores a FOREIGN tool's state file in shared scratch" {
  # .agents/scratch is the shared skill-scratch dir: a *-state.json there may
  # belong to another tool. Without a godmode signature check we rewrote it,
  # littered the repo, and pushed refs/godmode/<slug> for a foreign slug.
  echo '{"some":"other tool","items":[1,2]}' > .agents/scratch/othertool-state.json
  BEFORE="$(cat .agents/scratch/othertool-state.json)"
  EV="$(jq -n --arg fp "$REPO/.agents/scratch/othertool-state.json" \
      '{session_id:"sess-x",tool_name:"Write",tool_input:{file_path:$fp}}')"
  run bash -c "echo '$EV' | GODMODE_PUBLISH_CMD=/usr/bin/true GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$status" -eq 0 ]
  [ "$(cat .agents/scratch/othertool-state.json)" = "$BEFORE" ]   # not rewritten
  [ ! -f .agents/scratch/othertool-session-token ]                 # no litter
  [ ! -f explainers/othertool.html ]                               # no render
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

@test "on-state-write backfills driver_session_id from the hook event (first writer wins)" {
  jq '.driver_session_id = null' .agents/scratch/godmode-test-slug-state.json > t.json \
    && mv t.json .agents/scratch/godmode-test-slug-state.json
  EV="$(jq -n --arg fp "$REPO/.agents/scratch/godmode-test-slug-state.json" \
      '{session_id:"sess-new-driver",tool_name:"Write",tool_input:{file_path:$fp}}')"
  bash -c "echo '$EV' | GODMODE_PUBLISH_CMD=/usr/bin/true GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$(jq -r .driver_session_id .agents/scratch/godmode-test-slug-state.json)" = "sess-new-driver" ]
  # second session does NOT overwrite an established driver
  EV2="$(jq -n --arg fp "$REPO/.agents/scratch/godmode-test-slug-state.json" \
      '{session_id:"sess-usurper",tool_name:"Write",tool_input:{file_path:$fp}}')"
  bash -c "echo '$EV2' | GODMODE_PUBLISH_CMD=/usr/bin/true GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$(jq -r .driver_session_id .agents/scratch/godmode-test-slug-state.json)" = "sess-new-driver" ]
}

@test "on-state-write falls back to create when --slug update hits Not found, remembers site slug" {
  cat > stubpub.sh <<'EOF'
#!/bin/sh
if [ "$2" = "--slug" ]; then
  if [ "$3" = "three-word-abc" ]; then echo "updated three-word-abc"; exit 0; fi
  echo "error: Not found" >&2; exit 1
fi
echo "creating publish (1 files)..."
echo "https://three-word-abc.here.now"
EOF
  chmod +x stubpub.sh
  EV="$(jq -n --arg fp "$REPO/.agents/scratch/godmode-test-slug-state.json" \
      '{session_id:"sess-driver-1",tool_name:"Write",tool_input:{file_path:$fp}}')"
  run bash -c "echo '$EV' | GODMODE_PUBLISH_CMD='$PWD/stubpub.sh' GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$status" -eq 0 ]
  [ "$(cat .agents/scratch/godmode-test-slug-dashboard-site)" = "three-word-abc" ]
  [ ! -f .agents/scratch/godmode-test-slug-publish.pending ]
  # subsequent publish updates the remembered slug (stub succeeds only for it)
  run bash -c "echo '$EV' | GODMODE_PUBLISH_CMD='$PWD/stubpub.sh' GODMODE_SYNC=local '$SCRIPTS/on-state-write.sh'"
  [ "$status" -eq 0 ]
  [ ! -f .agents/scratch/godmode-test-slug-publish.pending ]
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
