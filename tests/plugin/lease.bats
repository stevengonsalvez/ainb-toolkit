#!/usr/bin/env bats
load helpers

setup() {
  make_remote_and_clones
  seed_state "$CLONE_A" prog sessA
}

claim_a() { ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/lease.sh" claim "$PWD" prog "$@" ); }

@test "claim then same-host second-session claim is refused (exit 4)" {
  claim_a
  run env GODMODE_SESSION_ID=sessB "$SCRIPTS/lease.sh" claim "$CLONE_A" prog
  [ "$status" -eq 4 ]
  [[ "$output" == *"refused"* ]]
}

@test "stale heartbeat allows foreign takeover" {
  push_backdated_lease "$CLONE_A" prog "2026-01-01T00:00:00Z" "otherhost/other/x"
  run env GODMODE_SESSION_ID=sessB "$SCRIPTS/lease.sh" claim "$CLONE_B" prog
  [ "$status" -eq 0 ]
  [[ "$output" == *"held by"* ]]
}

@test "deposed holder refresh exits 5 and leaves lease-lost marker" {
  claim_a
  ( cd "$CLONE_B" && GODMODE_SESSION_ID=sessB "$SCRIPTS/lease.sh" claim "$PWD" prog --force )
  run env GODMODE_SESSION_ID=sessA "$SCRIPTS/lease.sh" refresh "$CLONE_A" prog
  [ "$status" -eq 5 ]
  [ -f "$CLONE_A/.agents/scratch/prog-lease-lost" ]
}

@test "zombie writer pushes nothing after losing the lease" {
  claim_a
  ( cd "$CLONE_B" && GODMODE_SESSION_ID=sessB "$SCRIPTS/lease.sh" claim "$PWD" prog --force )
  # A still has scratch state and tries to sync
  run env GODMODE_SESSION_ID=sessA bash -c "cd '$CLONE_A' && '$SCRIPTS/sync.sh' push prog"
  [ "$status" -eq 0 ]
  [ -f "$CLONE_A/.agents/scratch/prog-lease-lost" ]
  # remote lease still B's
  ( cd "$CLONE_B" && "$SCRIPTS/sidecar_remote.sh" pull "$PWD" prog )
  HOLDER="$(jq -r .holder "$CLONE_B/.agents/scratch/.godmode-sync/prog/lease.json")"
  [[ "$HOLDER" == */sessB ]]
}

@test "observer (no scratch state) push is inert" {
  run bash -c "cd '$CLONE_B' && '$SCRIPTS/sync.sh' push"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to push"* ]]
}

@test "adopt reconstructs state with machine-local fields nulled" {
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/sync.sh" push prog )
  ( cd "$CLONE_B" && "$SCRIPTS/sync.sh" adopt prog )
  [ "$(jq -r .driver_session_id "$CLONE_B/.agents/scratch/prog-state.json")" = "null" ]
  [ "$(jq -r .running_task "$CLONE_B/.agents/scratch/prog-state.json")" = "null" ]
  [ -f "$CLONE_B/.agents/goals/prog-charter.md" ]
}

@test "discover lists programme slugs" {
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/sync.sh" push prog )
  run bash -c "cd '$CLONE_B' && '$SCRIPTS/sync.sh' discover"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prog"* ]]
}

@test "debounce: unchanged state within TTL/2 pushes no second commit" {
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/sync.sh" push prog )
  run bash -c "cd '$CLONE_A' && GODMODE_SESSION_ID=sessA '$SCRIPTS/sync.sh' push prog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"debounced"* ]]
}

@test "unrelated ref movement between syncs does not cause false lease loss" {
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/sync.sh" push prog )
  # B (observer) cannot move the ref; move it as A with changed state, then
  # refresh from a stale local cache: refresh must re-pull and stay held.
  jq '.current_note="moved"' "$CLONE_A/.agents/scratch/prog-state.json" > "$CLONE_A/t" \
    && mv "$CLONE_A/t" "$CLONE_A/.agents/scratch/prog-state.json"
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA GODMODE_LEASE_TTL=1 sh -c 'sleep 2; "'"$SCRIPTS"'/sync.sh" push prog' )
  run env GODMODE_SESSION_ID=sessA "$SCRIPTS/lease.sh" refresh "$CLONE_A" prog
  [ "$status" -eq 0 ]
  [ ! -f "$CLONE_A/.agents/scratch/prog-lease-lost" ]
}

@test "hook-claimed lease survives model-side refresh (single identity source)" {
  # hook path: env session id seeds the token file at claim
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=uuid-hook-1 "$SCRIPTS/lease.sh" claim "$PWD" prog )
  [ "$(cat "$CLONE_A/.agents/scratch/prog-session-token")" = "uuid-hook-1" ]
  # model path: NO env var; must resolve the same identity via the file
  run "$SCRIPTS/lease.sh" refresh "$CLONE_A" prog
  [ "$status" -eq 0 ]
  [ ! -f "$CLONE_A/.agents/scratch/prog-lease-lost" ]
}

@test "GODMODE_SYNC=local disables lease and sync" {
  run env GODMODE_SYNC=local "$SCRIPTS/lease.sh" claim "$CLONE_A" prog
  [ "$status" -eq 0 ]
  [[ "$output" == *"local"* ]]
  run env GODMODE_SYNC=local bash -c "cd '$CLONE_A' && '$SCRIPTS/sync.sh' push prog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"local"* ]]
}
