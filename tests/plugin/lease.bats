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

@test "hook-claimed lease survives model-side refresh (identity resolves the same)" {
  # Real shape: the hook backfills driver_session_id to the driver's OWN id, so
  # env (hook path) and driver_session_id (model-side, no env) agree. When they
  # diverged, the driver evicted itself — that shipped once (2026-07-16).
  jq '.driver_session_id = "uuid-hook-1"' "$CLONE_A/.agents/scratch/prog-state.json" > "$CLONE_A/t" \
    && mv "$CLONE_A/t" "$CLONE_A/.agents/scratch/prog-state.json"
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=uuid-hook-1 "$SCRIPTS/lease.sh" claim "$PWD" prog )
  # model path: NO env var; must resolve the same identity via driver_session_id
  run "$SCRIPTS/lease.sh" refresh "$CLONE_A" prog
  [ "$status" -eq 0 ]
  [ ! -f "$CLONE_A/.agents/scratch/prog-lease-lost" ]
}

@test "two sessions in ONE checkout do not share a lease identity (A2)" {
  # The old bug: identity fell back to a checkout-global token file, so a
  # co-located bystander session heartbeated the driver's lease under the
  # driver's identity — keeping a CRASHED driver alive and blocking takeover.
  jq '.driver_session_id = "sess-driver"' "$CLONE_A/.agents/scratch/prog-state.json" > "$CLONE_A/t" \
    && mv "$CLONE_A/t" "$CLONE_A/.agents/scratch/prog-state.json"
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sess-driver "$SCRIPTS/lease.sh" claim "$PWD" prog )
  # bystander session in the SAME checkout must push nothing
  run env GODMODE_SESSION_ID=sess-bystander bash -c "cd '$CLONE_A' && '$SCRIPTS/sync.sh' push prog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the driver session"* ]]
  # ...and must not have created a false lease-lost alarm for the driver
  [ ! -f "$CLONE_A/.agents/scratch/prog-lease-lost" ]
}

@test "a crashed driver's lease goes stale despite a live co-located session" {
  jq '.driver_session_id = "sess-driver"' "$CLONE_A/.agents/scratch/prog-state.json" > "$CLONE_A/t" \
    && mv "$CLONE_A/t" "$CLONE_A/.agents/scratch/prog-state.json"
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sess-driver "$SCRIPTS/lease.sh" claim "$PWD" prog )
  # driver "crashes"; backdate its heartbeat past TTL
  push_backdated_lease "$CLONE_A" prog "2026-01-01T00:00:00Z" "$(hostname -s)/${USER}/sess-driver"
  # bystander keeps living in the checkout and its Stop hooks fire
  env GODMODE_SESSION_ID=sess-bystander bash -c "cd '$CLONE_A' && '$SCRIPTS/sync.sh' push --if-active prog" >/dev/null 2>&1 || true
  # the foreign machine MUST still be able to take over
  run env GODMODE_SESSION_ID=sess-foreign "$SCRIPTS/lease.sh" claim "$CLONE_B" prog
  [ "$status" -eq 0 ]
  [[ "$output" == *"held by"* ]]
}

@test "concurrent first-ever pushes race (exit 3), never fail closed (exit 6)" {
  # Ref-lock contention ("cannot lock ref ... reference already exists") is what
  # two machines racing to CREATE the ref looks like. Misclassifying it as 6
  # told operators to run GODMODE_SYNC=local — i.e. straight into split brain.
  run bash "$(dirname "$BATS_TEST_FILENAME")/race-push.sh" "$SCRIPTS" "$CLONE_A" racer 6
  [ "$status" -eq 0 ]
  echo "exit codes: $output"
  [ "$(echo "$output" | grep -c '^6$')" -eq 0 ]        # never fail closed
  [ "$(echo "$output" | grep -c '^0$')" -ge 1 ]        # someone wins
  [ "$(echo "$output" | grep -c '^3$')" -ge 1 ]        # and someone LOSES:
  # 6 racers cannot all create the same ref. Without this line the test passes
  # when the classifier reports every rejection as success (mutant S3 survived
  # exactly that way), which would silently swallow lost CAS races.
  [ "$(echo "$output" | grep -cE '^(0|3)$')" -eq 6 ]
  # exactly one commit reached the ref: the losers really did not land
  git -C "$CLONE_A" fetch -q origin '+refs/godmode/racer:refs/rt'
  [ "$(git -C "$CLONE_A" rev-list refs/rt --count)" -eq 1 ]
}

@test "a deposed driver cannot fast-forward-clobber the new holder's lease" {
  # Push CAS guarantees ref linearity, not lease ownership: without a content
  # check, a commit parented on the current tip is accepted whatever lease it
  # carries, so the old driver could silently steal the lock back.
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/lease.sh" claim "$PWD" prog )
  ( cd "$CLONE_B" && GODMODE_SESSION_ID=sessB "$SCRIPTS/lease.sh" claim "$PWD" prog --force )
  # A parents on the CURRENT tip (fresh fetch) but carries its own stale holder
  run env GODMODE_EXPECT_HOLDER="$(hostname -s)/${USER}/sessA" bash -c "
    T=\"$BATS_TEST_TMPDIR/zombie\"; mkdir -p \"\$T\"
    printf '{\"holder\":\"%s/%s/sessA\",\"machine\":\"m\",\"heartbeat_ts\":\"2026-07-17T12:00:00Z\",\"held_since\":\"x\"}' \
      '$(hostname -s)' '$USER' > \"\$T/lease.json\"
    '$SCRIPTS/sidecar_remote.sh' push '$CLONE_A' prog \"\$T\""
  [ "$status" -eq 5 ]
  [[ "$output" == *"refusing to clobber"* ]]
  # remote lease is still B's
  ( cd "$CLONE_B" && rm -rf .agents/scratch/.godmode-sync/prog && "$SCRIPTS/sidecar_remote.sh" pull "$PWD" prog >/dev/null )
  [[ "$(jq -r .holder "$CLONE_B/.agents/scratch/.godmode-sync/prog/lease.json")" == */sessB ]]
}

@test "GODMODE_SYNC=local disables lease and sync" {
  run env GODMODE_SYNC=local "$SCRIPTS/lease.sh" claim "$CLONE_A" prog
  [ "$status" -eq 0 ]
  [[ "$output" == *"local"* ]]
  run env GODMODE_SYNC=local bash -c "cd '$CLONE_A' && '$SCRIPTS/sync.sh' push prog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"local"* ]]
}
