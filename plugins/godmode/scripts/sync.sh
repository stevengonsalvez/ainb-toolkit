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
  local f
  f="$(ls "$SCRATCH"/*-state.json 2>/dev/null | head -1 || true)"
  [ -n "$f" ] || return 1
  basename "$f" | sed 's/-state\.json$//'
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

    if [ "$IF_ACTIVE" = 1 ]; then
      PHASE="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
      [ -n "$PHASE" ] && [ "$PHASE" != "DONE" ] || exit 0
    fi

    CACHE="$REPO/.agents/scratch/.godmode-sync/$SLUG"
    # ---- holder gate FIRST: read-only check against freshly pulled lease ----
    RC=0
    GODMODE_SYNC_CACHE="$CACHE" "$LEASE" check "$REPO" "$SLUG" >/dev/null || RC=$?
    if [ "$RC" = 4 ]; then
      HOLDER="$(jq -r '.holder // "unknown"' "$CACHE/lease.json" 2>/dev/null || echo unknown)"
      printf '%s' "$HOLDER" > "$SCRATCH/$SLUG-lease-lost"
      echo "godmode sync: lease held by $HOLDER, pushing NOTHING (lease-lost marker set)" >&2
      exit 0
    elif [ "$RC" = 6 ]; then
      echo "godmode sync: remote unpushable, sync disabled" >&2
      exit 0
    fi

    # ---- our identity (must match lease.sh's) ----
    TOKEN_FILE="$SCRATCH/$SLUG-session-token"
    TOKEN="${GODMODE_SESSION_ID:-}"
    [ -n "$TOKEN" ] || { [ -f "$TOKEN_FILE" ] && TOKEN="$(cat "$TOKEN_FILE")" || TOKEN="$PPID-$(date -u +%s)"; }
    IDENT="$(hostname -s)/${USER}/$TOKEN"

    # ---- debounce: durable subset unchanged AND our own fresh heartbeat -> skip ----
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    jq -S 'del(.running_task, .running_run_id, .driver_session_id)' "$STATE" > "$TMP/state.json"
    CHARTER="$REPO/.agents/goals/$SLUG-charter.md"
    [ -f "$CHARTER" ] && cp "$CHARTER" "$TMP/charter.md"
    HB="$(jq -r '.heartbeat_ts // empty' "$CACHE/lease.json" 2>/dev/null || true)"
    REMOTE_HOLDER="$(jq -r '.holder // empty' "$CACHE/lease.json" 2>/dev/null || true)"
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

    RC=0
    GODMODE_SYNC_MSG="chore(godmode): sync $SLUG $(jq -r .phase "$TMP/state.json" 2>/dev/null || echo '?')" \
      "$SIDE" push "$REPO" "$SLUG" "$TMP" || RC=$?
    if [ "$RC" = 3 ]; then
      # raced: refetch, re-verify holder, single retry
      GODMODE_SYNC_CACHE="$CACHE" "$SIDE" pull "$REPO" "$SLUG" >/dev/null || true
      NEWHOLDER="$(jq -r '.holder // empty' "$CACHE/lease.json" 2>/dev/null || true)"
      if [ -n "$NEWHOLDER" ] && [ "$NEWHOLDER" != "$(hostname -s)/${USER}/$TOKEN" ]; then
        printf '%s' "$NEWHOLDER" > "$SCRATCH/$SLUG-lease-lost"
        echo "godmode sync: lease lost to $NEWHOLDER during push, NOT retrying" >&2
        exit 0
      fi
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
