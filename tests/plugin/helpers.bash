# Shared helpers for godmode plugin bats suites.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/godmode/scripts"
FX="$REPO_ROOT/tests/plugin/fixtures"

make_remote_and_clones() {
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init --bare -q "$REMOTE"
  for c in A B; do
    git clone -q "$REMOTE" "$BATS_TEST_TMPDIR/$c" 2>/dev/null
    git -C "$BATS_TEST_TMPDIR/$c" config user.email t@t
    git -C "$BATS_TEST_TMPDIR/$c" config user.name t
    git -C "$BATS_TEST_TMPDIR/$c" config commit.gpgsign false
  done
  CLONE_A="$BATS_TEST_TMPDIR/A"
  CLONE_B="$BATS_TEST_TMPDIR/B"
  ( cd "$CLONE_A" && echo hi > README.md && git add README.md \
    && git commit -qm init && git branch -M main && git push -q origin main )
}

# seed_state <clone> <slug> <session>
seed_state() {
  mkdir -p "$1/.agents/scratch" "$1/.agents/goals"
  jq --arg s "$3" '.driver_session_id = $s' "$FX/state.json" \
    > "$1/.agents/scratch/$2-state.json"
  cp "$FX/charter.md" "$1/.agents/goals/$2-charter.md"
}

# stop_event_for <clone> [fixture]  -> stdout: Stop JSON with cwd set
stop_event_for() {
  jq --arg c "$1" '. + {cwd: $c}' "${2:-$FX/stop-event.json}"
}

# push_backdated_lease <clone> <slug> <iso-ts> <holder>
push_backdated_lease() {
  local tmp; tmp="$(mktemp -d)"
  jq -n --arg h "$4" --arg ts "$3" \
    '{holder:$h, machine:"m", heartbeat_ts:$ts, held_since:$ts}' > "$tmp/lease.json"
  "$SCRIPTS/sidecar_remote.sh" push "$1" "$2" "$tmp" >/dev/null
}
