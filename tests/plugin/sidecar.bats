#!/usr/bin/env bats
load helpers

setup() {
  make_remote_and_clones
}

@test "first push creates root commit on refs/godmode/<slug>, main untouched" {
  seed_state "$CLONE_A" prog sessA
  MAIN_BEFORE="$(git -C "$CLONE_A" rev-parse origin/main)"
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/sync.sh" push prog )
  git -C "$CLONE_A" fetch -q origin '+refs/godmode/prog:refs/t'
  [ "$(git -C "$CLONE_A" rev-list refs/t --count)" -eq 1 ]
  git -C "$CLONE_A" fetch -q origin main
  [ "$(git -C "$CLONE_A" rev-parse origin/main)" = "$MAIN_BEFORE" ]
}

@test "single commit carries state, charter, and lease together" {
  seed_state "$CLONE_A" prog sessA
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/sync.sh" push prog )
  git -C "$CLONE_A" fetch -q origin '+refs/godmode/prog:refs/t'
  FILES="$(git -C "$CLONE_A" show refs/t --stat --format= | awk '{print $1}')"
  echo "$FILES" | grep -q state.json
  echo "$FILES" | grep -q charter.md
  echo "$FILES" | grep -q lease.json
}

@test "round-trip: durable subset identical on second clone" {
  seed_state "$CLONE_A" prog sessA
  ( cd "$CLONE_A" && GODMODE_SESSION_ID=sessA "$SCRIPTS/sync.sh" push prog )
  ( cd "$CLONE_B" && "$SCRIPTS/sidecar_remote.sh" pull "$PWD" prog )
  diff \
    <(jq -S 'del(.running_task,.running_run_id,.driver_session_id)' "$CLONE_A/.agents/scratch/prog-state.json") \
    <(jq -S . "$CLONE_B/.agents/scratch/.godmode-sync/prog/state.json")
}

@test "corrupt json is refused before any push" {
  seed_state "$CLONE_A" prog sessA
  TMP="$(mktemp -d)"; echo '{' > "$TMP/state.json"
  run "$SCRIPTS/sidecar_remote.sh" push "$CLONE_A" prog "$TMP"
  [ "$status" -eq 2 ]
}

@test "protected remote fails CLOSED with exit 6 and touches nothing else" {
  cat > "$REMOTE/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read old new ref; do
  case "$ref" in refs/godmode/*) echo "blocked" >&2; exit 1;; esac
done
exit 0
EOF
  chmod +x "$REMOTE/hooks/pre-receive"
  seed_state "$CLONE_A" prog sessA
  TMP="$(mktemp -d)"; cp "$FX/state.json" "$TMP/state.json"
  run "$SCRIPTS/sidecar_remote.sh" push "$CLONE_A" prog "$TMP"
  [ "$status" -eq 6 ]
  [[ "$output" == *"not pushable"* ]]
  # nothing landed on main or any branch
  [ -z "$(git -C "$REMOTE" for-each-ref 'refs/godmode/*')" ]
}

@test "CAS refuses to clobber a foreign lease when NONE was expected (__none__)" {
  # Cold-start / release->reclaim: we saw no holder, but a foreign claim landed
  # in the pull->fetch TOCTOU window. An empty expectation used to SKIP the CAS
  # and fast-forward-clobber it (split brain). __none__ must refuse.
  seed_state "$CLONE_A" prog sessA
  # a foreign holder is already on the ref
  TMP="$(mktemp -d)"
  jq -n '{holder:"foreignHost/foo/sessFOREIGN", machine:"m", heartbeat_ts:"2026-07-18T00:00:00Z", held_since:"x"}' > "$TMP/lease.json"
  cp "$FX/state.json" "$TMP/state.json"
  "$SCRIPTS/sidecar_remote.sh" push "$CLONE_A" prog "$TMP" >/dev/null
  # we push expecting NO holder
  MINE="$(mktemp -d)"; cp "$FX/state.json" "$MINE/state.json"
  jq -n '{holder:"myHost/me/sessMINE", machine:"m", heartbeat_ts:"2026-07-18T01:00:00Z", held_since:"y"}' > "$MINE/lease.json"
  run env GODMODE_EXPECT_HOLDER=__none__ "$SCRIPTS/sidecar_remote.sh" push "$CLONE_A" prog "$MINE"
  [ "$status" -eq 5 ]
  # the foreign lease survives
  ( cd "$CLONE_B" && "$SCRIPTS/sidecar_remote.sh" pull "$PWD" prog >/dev/null )
  [ "$(jq -r .holder "$CLONE_B/.agents/scratch/.godmode-sync/prog/lease.json")" = "foreignHost/foo/sessFOREIGN" ]
}

@test "CAS with __none__ allows the push when the ref truly has no holder" {
  seed_state "$CLONE_A" prog sessA
  MINE="$(mktemp -d)"; cp "$FX/state.json" "$MINE/state.json"
  jq -n '{holder:"myHost/me/sessMINE", machine:"m", heartbeat_ts:"t", held_since:"y"}' > "$MINE/lease.json"
  run env GODMODE_EXPECT_HOLDER=__none__ "$SCRIPTS/sidecar_remote.sh" push "$CLONE_A" prog "$MINE"
  [ "$status" -eq 0 ]
}

@test "pull of absent ref is a clean no-op" {
  run "$SCRIPTS/sidecar_remote.sh" pull "$CLONE_B" ghost
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref absent"* ]]
}

@test "unchanged content push is a no-op (no second commit)" {
  seed_state "$CLONE_A" prog sessA
  TMP="$(mktemp -d)"; cp "$FX/state.json" "$TMP/state.json"
  "$SCRIPTS/sidecar_remote.sh" push "$CLONE_A" prog "$TMP"
  run "$SCRIPTS/sidecar_remote.sh" push "$CLONE_A" prog "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* ]]
  git -C "$CLONE_A" fetch -q origin '+refs/godmode/prog:refs/t'
  [ "$(git -C "$CLONE_A" rev-list refs/t --count)" -eq 1 ]
}
