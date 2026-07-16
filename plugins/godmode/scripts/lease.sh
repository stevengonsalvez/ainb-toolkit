#!/usr/bin/env bash
# godmode single-driver lease. Lives in lease.json on the sidecar ref; push
# rejection is the CAS primitive. Identity = machine/user/SESSION so two
# sessions on one host contend like two machines.
#
# usage: lease.sh claim|refresh|check|release <repo-dir> <slug> [--force]
# env:   GODMODE_LEASE_TTL (s, default 1800) · GODMODE_SESSION_ID (session token
#        override; hooks pass the Claude session_id) · GODMODE_SYNC=local (no-op)
# exit:  0 ok/held/claimable · 3 CAS raced out (claim) · 4 refused (foreign
#        fresh lease) · 5 lease lost (refresh) · 6 sync disabled (unpushable ref)
set -euo pipefail

ACTION="${1:-}"; REPO="${2:-}"; SLUG="${3:-}"; FORCE="${4:-}"
[ -n "$ACTION" ] && [ -n "$REPO" ] && [ -n "$SLUG" ] || {
  echo "usage: lease.sh claim|refresh|check|release <repo-dir> <slug> [--force]" >&2; exit 2; }

if [ "${GODMODE_SYNC:-remote}" = "local" ]; then
  echo "lease: GODMODE_SYNC=local, lease disabled (single-machine mode)"
  exit 0
fi

TTL="${GODMODE_LEASE_TTL:-1800}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDE="$SCRIPT_DIR/sidecar_remote.sh"
CACHE="${GODMODE_SYNC_CACHE:-$REPO/.agents/scratch/.godmode-sync/$SLUG}"
SCRATCH="$REPO/.agents/scratch"
TOKEN_FILE="$SCRATCH/$SLUG-session-token"
LOST_MARKER="$SCRATCH/$SLUG-lease-lost"

session_token() {
  if [ -n "${GODMODE_SESSION_ID:-}" ]; then echo "$GODMODE_SESSION_ID"; return; fi
  if [ -f "$TOKEN_FILE" ]; then cat "$TOKEN_FILE"; return; fi
  mkdir -p "$SCRATCH"
  local t; t="$PPID-$(date -u +%s)"
  printf '%s' "$t" > "$TOKEN_FILE"
  echo "$t"
}
identity() { echo "$(hostname -s)/${USER}/$(session_token)"; }

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_of() { # ISO8601 Z -> epoch; BSD then GNU date
  date -j -u -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || echo 0
}

pull_lease() { GODMODE_SYNC_CACHE="$CACHE" "$SIDE" pull "$REPO" "$SLUG" >/dev/null; }
holder()     { jq -r '.holder // empty' "$CACHE/lease.json" 2>/dev/null || true; }
heartbeat()  { jq -r '.heartbeat_ts // empty' "$CACHE/lease.json" 2>/dev/null || true; }
held_since() { jq -r '.held_since // empty' "$CACHE/lease.json" 2>/dev/null || true; }
lease_age() {
  local hb; hb="$(heartbeat)"
  [ -n "$hb" ] || { echo 999999999; return; }
  echo $(( $(date -u +%s) - $(epoch_of "$hb") ))
}
is_stale() { [ "$(lease_age)" -gt "$TTL" ]; }
is_self()  { [ "$(holder)" = "$(identity)" ]; }
has_lease(){ [ -f "$CACHE/lease.json" ] && [ -n "$(holder)" ]; }

push_lease() { # $1 = held_since to preserve (empty -> now)
  local since="${1:-}"; [ -n "$since" ] || since="$(iso_now)"
  local tmp; tmp="$(mktemp -d)"
  jq -n --arg h "$(identity)" --arg m "$(hostname -s)" \
        --arg ts "$(iso_now)" --arg since "$since" \
        '{holder:$h, machine:$m, heartbeat_ts:$ts, held_since:$since}' > "$tmp/lease.json"
  local rc=0
  GODMODE_SYNC_MSG="chore(godmode): lease $SLUG" "$SIDE" push "$REPO" "$SLUG" "$tmp" || rc=$?
  rm -rf "$tmp"
  return $rc
}

mkdir -p "$SCRATCH"

case "$ACTION" in
  claim)
    pull_lease
    if has_lease && ! is_self && ! is_stale && [ "$FORCE" != "--force" ]; then
      echo "lease: refused, held by $(holder) (heartbeat $(lease_age)s ago, TTL ${TTL}s)"
      exit 4
    fi
    SINCE=""; is_self && SINCE="$(held_since)"
    rc=0; push_lease "$SINCE" || rc=$?
    if [ "$rc" = 3 ]; then
      pull_lease
      if is_self; then echo "lease: claimed (race resolved to us)"; else
        echo "lease: raced out, held by $(holder)"; exit 3
      fi
    elif [ "$rc" != 0 ]; then
      exit "$rc"
    fi
    rm -f "$LOST_MARKER"
    echo "lease: held by $(identity)"
    ;;

  refresh)
    pull_lease
    if ! has_lease || ! is_self; then
      printf '%s' "${GODMODE_LEASE_HOLDER_OVERRIDE:-$(holder)}" > "$LOST_MARKER"
      echo "lease: lost to $(holder || echo '(none)')" >&2
      exit 5
    fi
    rc=0; push_lease "$(held_since)" || rc=$?
    if [ "$rc" = 3 ]; then
      pull_lease
      if is_self; then
        rc=0; push_lease "$(held_since)" || rc=$?
        [ "$rc" = 0 ] || { printf '%s' "$(holder)" > "$LOST_MARKER"; echo "lease: lost (race)" >&2; exit 5; }
      else
        printf '%s' "$(holder)" > "$LOST_MARKER"
        echo "lease: lost to $(holder)" >&2
        exit 5
      fi
    elif [ "$rc" != 0 ]; then
      exit "$rc"
    fi
    echo "lease: refreshed ($(identity))"
    ;;

  check)
    pull_lease
    if ! has_lease; then echo "lease: none"; exit 0; fi
    STATE="fresh"; is_stale && STATE="stale"
    echo "lease: holder=$(holder) age=$(lease_age)s state=$STATE self=$(is_self && echo yes || echo no)"
    if ! is_self && [ "$STATE" = "fresh" ]; then exit 4; fi
    ;;

  release)
    pull_lease
    if ! is_self; then echo "lease: not held by us, nothing to release"; exit 0; fi
    tmp="$(mktemp -d)"
    jq -n --arg ts "$(iso_now)" '{holder:"", released_at:$ts}' > "$tmp/lease.json"
    GODMODE_SYNC_MSG="chore(godmode): lease release $SLUG" "$SIDE" push "$REPO" "$SLUG" "$tmp" || true
    rm -rf "$tmp"
    echo "lease: released"
    ;;

  *) echo "lease: unknown action '$ACTION'" >&2; exit 2 ;;
esac
