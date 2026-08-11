#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  POLICY="$REPO_ROOT/plugins/godmode/scripts/programme_policy.py"
  STATE="$BATS_TEST_TMPDIR/state.json"
}

write_state() {
  printf '%s' "$1" > "$STATE"
}

@test "finite backlog-dry completes" {
  write_state '{"phase":"ROADMAP","dashboard_slug":"policy-test","epics":{},"mode":"finite","termination":{"backlog_dry":true}}'
  run "$POLICY" next-action "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "complete"'
}

@test "perpetual empty backlog starts next discovery" {
  write_state '{"phase":"ROADMAP","dashboard_slug":"policy-test","epics":{},"mode":"perpetual","approval_policy":"none","termination":{"backlog_dry":false},"lanes":{"discovery":{"status":"idle"}}}'
  run "$POLICY" next-action "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "discover"'
}

@test "confirmed incident preempts all other next actions" {
  write_state '{"phase":"E02_EXECUTE","epics":{"e02":"EXECUTING"},"mode":"perpetual","approval_policy":"none","termination":{"backlog_dry":false},"incidents":[{"id":"repair-7","status":"confirmed"}],"lanes":{"regression":{"status":"queued"}}}'
  run "$POLICY" next-action "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "repair" and .reason == "repair-7"'
}

@test "shipped epic queues cumulative regression" {
  write_state '{"phase":"E02_SHIP","epics":{"e02":"SHIPPED"},"mode":"perpetual","approval_policy":"none","termination":{"backlog_dry":false}}'
  run "$POLICY" next-action "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "run_regression"'
}

@test "codex creative route pairs Codex with Claude" {
  printf '%s' '{"host":"codex","models":["codex:gpt-5.6","claude:fable"]}' > "$BATS_TEST_TMPDIR/availability.json"
  run "$POLICY" creative-route "$BATS_TEST_TMPDIR/availability.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ready" and .models == ["codex:gpt-5.6", "claude:fable"]'
}

@test "creative work defers without independent pair" {
  printf '%s' '{"host":"copilot","models":["copilot:gpt-5"]}' > "$BATS_TEST_TMPDIR/availability.json"
  run "$POLICY" creative-route "$BATS_TEST_TMPDIR/availability.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "deferred"'
}

@test "perpetual state rejects backlog-dry and pending human gate" {
  write_state '{"phase":"HUMAN_GATE","dashboard_slug":"policy-test","epics":{},"mode":"perpetual","approval_policy":"none","human_gate":"pending","termination":{"backlog_dry":true}}'
  run "$POLICY" validate-state "$STATE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot wait at human_gate"* ]]
}
