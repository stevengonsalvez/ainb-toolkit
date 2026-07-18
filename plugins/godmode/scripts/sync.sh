#!/usr/bin/env bash
# godmode sync orchestrator.
#   pull      fetch sidecar into cache (never writes scratch state; observer-safe)
#   discover  list programme slugs on the remote (fresh-machine entry point)
#   adopt     reconstruct local scratch state from sidecar (DRIVER-ONLY; called by
#             /godmode run after lease claim / --take-over; status never adopts)
#   push      holder-gated single-commit push of durable state + charter + fresh
#             lease heartbeat; debounced
#
# usage: sync.sh pull|push|adopt|discover [--if-active] [slug]
# env:   GODMODE_SYNC=local (disable all remote ops) · GODMODE_REPO (default $PWD)
#        GODMODE_LEASE_TTL · GODMODE_SESSION_ID (see lease.sh)
# exit:  0 in every hook-facing path except real usage errors (2). Infra failures
#        are logged + marked, never propagated to the hook (fail open); the ONE
#        model-visible failure (lease lost) is surfaced by on-state-write.sh via
#        the marker this script leaves.
set -euo pipefail

ACTION="${1:-}"; shift || true
[ -n "$ACTION" ] || { echo "usage: sync.sh pull|push|adopt|discover [--if-active] [slug]" >&2; exit 2; }

IF_ACTIVE=0; SLUG=""
for a in "$@"; do
  case "$a" in
    --if-active) IF_ACTIVE=1 ;;
    *) SLUG="$a" ;;
  esac
done

REPO="${GODMODE_REPO:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDE="$SCRIPT_DIR/sidecar_remote.sh"
LEASE="$SCRIPT_DIR/lease.sh"
SCRATCH="$REPO/.agents/scratch"
TTL="${GODMODE_LEASE_TTL:-1800}"

if [ "${GODMODE_SYNC:-remote}" = "local" ]; then
  echo "godmode sync: GODMODE_SYNC=local, remote sync disabled"
  exit 0
fi

autodetect_slug() {
  # Pick the first GODMODE-SIGNED state file, not merely the first *-state.json:
  # .agents/scratch is shared, so a foreign tool's state file sorting first
  # would otherwise shadow a real godmode programme in the same repo.
  local f
  for f in "$SCRATCH"/*-state.json; do
    [ -f "$f" ] || continue
    jq -e '.phase and (.epics or .dashboard_slug)' "$f" >/dev/null 2>&1 || continue
    basename "$f" | sed 's/-state\.json$//'
    return 0
  done
  return 1
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_of() {
  date -j -u -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null || echo 0
}

case "$ACTION" in
  discover)
    cd "$REPO"
    git ls-remote origin 'refs/godmode/*' 2>/dev/null \
      | awk '{print $2}' | sed 's|^refs/godmode/||' | sort -u
    ;;

  pull)
    [ -n "$SLUG" ] || SLUG="$(autodetect_slug || true)"
    [ -n "$SLUG" ] || exit 0   # inert: no programme in this checkout
    "$SIDE" pull "$REPO" "$SLUG" || echo "godmode sync: pull failed (will retry)" >&2
    ;;

  adopt)
    [ -n "$SLUG" ] || { echo "adopt needs an explicit slug (from sync.sh discover)" >&2; exit 2; }
    CACHE="$REPO/.agents/scratch/.godmode-sync/$SLUG"
    GODMODE_SYNC_CACHE="$CACHE" "$SIDE" pull "$REPO" "$SLUG" >/dev/null
    [ -f "$CACHE/state.json" ] || { echo "adopt: no sidecar state for '$SLUG' on remote" >&2; exit 2; }
    mkdir -p "$SCRATCH" "$REPO/.agents/goals"
    # machine-local fields never travel; the new driver re-establishes them
    jq '.running_task = null | .running_run_id = null | .driver_session_id = null' \
      "$CACHE/state.json" > "$SCRATCH/$SLUG-state.json"
    [ -f "$CACHE/charter.md" ] && cp "$CACHE/charter.md" "$REPO/.agents/goals/$SLUG-charter.md"
    echo "adopt: reconstructed $SCRATCH/$SLUG-state.json (+charter) from sidecar"
    ;;

  push)
    [ -n "$SLUG" ] || SLUG="$(autodetect_slug || true)"
    [ -n "$SLUG" ] || { echo "godmode sync: no local programme, nothing to push"; exit 0; }
    STATE="$SCRATCH/$SLUG-state.json"
    [ -f "$STATE" ] || { echo "godmode sync: no scratch state, observer mode, nothing to push"; exit 0; }

    # ---- godmode signature required (same guard as on-state-write.sh) ----
    # The Stop/PreCompact heartbeat autodetects the slug, so a foreign tool's
    # *-state.json in the shared .agents/scratch would otherwise get pushed to
    # refs/godmode/<its-slug> on the remote. Never sync a non-godmode file.
    jq -e '.phase and (.epics or .dashboard_slug)' "$STATE" >/dev/null 2>&1 \
      || { echo "godmode sync: no godmode signature, nothing to push"; exit 0; }

    # ---- only the DRIVER's session may mutate ----
    # Stop/PreCompact hooks fire in every session in the checkout. A bystander
    # session must not heartbeat (it would keep a crashed driver's lease alive
    # and block foreign takeover, spec A2). sync-hook.sh threads the firing
    # session's id; model-side runs have no env and are the driver by
    # definition (they are the session that owns the loop).
    DRIVER_SID="$(jq -r '.driver_session_id // empty' "$STATE" 2>/dev/null || true)"
    if [ -n "${GODMODE_SESSION_ID:-}" ] && [ -n "$DRIVER_SID" ] && [ "$DRIVER_SID" != "null" ] \
       && [ "$GODMODE_SESSION_ID" != "$DRIVER_SID" ]; then
      echo "godmode sync: not the driver session, nothing to push"
      exit 0
    fi

    if [ "$IF_ACTIVE" = 1 ]; then
      PHASE="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
      [ -n "$PHASE" ] && [ "$PHASE" != "DONE" ] || exit 0
    fi

    CACHE="$REPO/.agents/scratch/.godmode-sync/$SLUG"

    # ---- our identity (MUST match lease.sh session_token(): token file only) ----
    TOKEN_FILE="$SCRATCH/$SLUG-session-token"
    if [ -f "$TOKEN_FILE" ]; then
      TOKEN="$(cat "$TOKEN_FILE")"
    elif [ -n "${GODMODE_SESSION_ID:-}" ]; then
      TOKEN="$GODMODE_SESSION_ID"
      printf '%s' "$TOKEN" > "$TOKEN_FILE" 2>/dev/null || true
    else
      TOKEN="$PPID-$(date -u +%s)"
      printf '%s' "$TOKEN" > "$TOKEN_FILE" 2>/dev/null || true
    fi
    IDENT="$(hostname -s)/${USER}/$TOKEN"

    # ---- holder gate FIRST, against a freshly pulled lease ----
    # ANY foreign holder blocks, stale or fresh. Gating on freshness (lease.sh
    # check, which only refuses foreign+FRESH) let a background heartbeat push
    # silently RECLAIM a stale foreign lease — making takeover a side effect of
    # a Stop hook rather than an explicit act. Takeover belongs to `lease.sh
    # claim` via /godmode run (auto on stale, or --take-over), where it is
    # recorded. No lease at all = nothing to respect (pre-claim INIT), push on.
    RC=0
    GODMODE_SYNC_CACHE="$CACHE" "$SIDE" pull "$REPO" "$SLUG" >/dev/null 2>&1 || RC=$?
    if [ "$RC" = 6 ]; then
      echo "godmode sync: remote unpushable, sync disabled" >&2
      exit 0
    fi
    REMOTE_HOLDER="$(jq -r '.holder // empty' "$CACHE/lease.json" 2>/dev/null || true)"
    if [ -n "$REMOTE_HOLDER" ] && [ "$REMOTE_HOLDER" != "$IDENT" ]; then
      printf '%s' "$REMOTE_HOLDER" > "$SCRATCH/$SLUG-lease-lost"
      echo "godmode sync: lease held by $REMOTE_HOLDER, pushing NOTHING (lease-lost marker set)" >&2
      exit 0
    fi

    # ---- debounce: durable subset unchanged AND our own fresh heartbeat -> skip ----
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    jq -S 'del(.running_task, .running_run_id, .driver_session_id)' "$STATE" > "$TMP/state.json"
    CHARTER="$REPO/.agents/goals/$SLUG-charter.md"
    [ -f "$CHARTER" ] && cp "$CHARTER" "$TMP/charter.md"
    HB="$(jq -r '.heartbeat_ts // empty' "$CACHE/lease.json" 2>/dev/null || true)"
    if [ -f "$CACHE/state.json" ] && [ -n "$HB" ] && [ "$REMOTE_HOLDER" = "$IDENT" ]; then
      AGE=$(( $(date -u +%s) - $(epoch_of "$HB") ))
      if diff -q <(jq -S . "$CACHE/state.json" 2>/dev/null) <(jq -S . "$TMP/state.json") >/dev/null 2>&1 \
         && [ "$AGE" -lt $(( TTL / 2 )) ]; then
        echo "godmode sync: debounced (state unchanged, heartbeat ${AGE}s)"
        exit 0
      fi
    fi

    # ---- fresh lease heartbeat rides the SAME single commit ----
    SINCE="$(jq -r '.held_since // empty' "$CACHE/lease.json" 2>/dev/null || true)"
    [ -n "$SINCE" ] || SINCE="$(iso_now)"
    jq -n --arg h "$IDENT" --arg m "$(hostname -s)" \
          --arg ts "$(iso_now)" --arg since "$SINCE" \
          '{holder:$h, machine:$m, heartbeat_ts:$ts, held_since:$since}' > "$TMP/lease.json"

    # We hold the lease (holder == IDENT) or saw none. Either way a FOREIGN
    # holder appearing on the tip means we were deposed in the TOCTOU window:
    # expect exactly what we saw (__none__ when empty), refuse to clobber.
    EXPECT="$REMOTE_HOLDER"; [ -n "$EXPECT" ] || EXPECT="__none__"
    RC=0
    GODMODE_EXPECT_HOLDER="$EXPECT" \
    GODMODE_SYNC_MSG="chore(godmode): sync $SLUG $(jq -r .phase "$TMP/state.json" 2>/dev/null || echo '?')" \
      "$SIDE" push "$REPO" "$SLUG" "$TMP" || RC=$?
    if [ "$RC" = 5 ]; then
      # lease moved between our holder-gate and the push: we are deposed
      GODMODE_SYNC_CACHE="$CACHE" "$SIDE" pull "$REPO" "$SLUG" >/dev/null 2>&1 || true
      printf '%s' "$(jq -r '.holder // "unknown"' "$CACHE/lease.json" 2>/dev/null || echo unknown)" \
        > "$SCRATCH/$SLUG-lease-lost"
      echo "godmode sync: lease moved during push, pushed nothing" >&2
      exit 0
    fi
    if [ "$RC" = 3 ]; then
      # raced: refetch, re-verify holder, single retry
      GODMODE_SYNC_CACHE="$CACHE" "$SIDE" pull "$REPO" "$SLUG" >/dev/null || true
      NEWHOLDER="$(jq -r '.holder // empty' "$CACHE/lease.json" 2>/dev/null || true)"
      if [ -n "$NEWHOLDER" ] && [ "$NEWHOLDER" != "$IDENT" ]; then
        printf '%s' "$NEWHOLDER" > "$SCRATCH/$SLUG-lease-lost"
        echo "godmode sync: lease lost to $NEWHOLDER during push, NOT retrying" >&2
        exit 0
      fi
      # retry carries the SAME content-CAS as the main push (was unguarded)
      RETRY_EXPECT="$NEWHOLDER"; [ -n "$RETRY_EXPECT" ] || RETRY_EXPECT="__none__"
      GODMODE_EXPECT_HOLDER="$RETRY_EXPECT" \
        "$SIDE" push "$REPO" "$SLUG" "$TMP" || { echo "godmode sync: push retry failed" >&2; exit 0; }
    elif [ "$RC" = 6 ]; then
      echo "godmode sync: remote unpushable, sync disabled" >&2
      exit 0
    elif [ "$RC" != 0 ]; then
      echo "godmode sync: push failed rc=$RC (will retry next tick)" >&2
      exit 0
    fi
    # success refreshes the local cache view
    GODMODE_SYNC_CACHE="$CACHE" "$SIDE" pull "$REPO" "$SLUG" >/dev/null || true
    rm -f "$SCRATCH/$SLUG-lease-lost" 2>/dev/null || true
    echo "godmode sync: pushed $SLUG"
    ;;

  *) echo "godmode sync: unknown action '$ACTION'" >&2; exit 2 ;;
esac
