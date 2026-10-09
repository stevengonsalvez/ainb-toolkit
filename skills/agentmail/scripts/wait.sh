#!/usr/bin/env bash
# Poll until a matching message arrives; print it as JSON.
# Usage: wait.sh <slug> [--timeout 120] [--interval 5] [--from text] [--subject text] [--min-count N]
#   --from: case-insensitive substring of the sender address (not display name).
#   --subject: case-insensitive substring match.
#   --min-count N: only succeed once the inbox holds more than N messages (next OTP).
# Exit: 0 found, 124 timeout, 1 error, 2 bad args.
source "$(dirname "$0")/_lib.sh"

SLUG="" TIMEOUT=120 INTERVAL=5 FROM="" SUBJECT="" MIN_COUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --from)      FROM="$2"; shift 2 ;;
    --subject)   SUBJECT="$2"; shift 2 ;;
    --min-count) MIN_COUNT="$2"; shift 2 ;;
    -h|--help)   sed -n '2,6p' "$0"; exit 0 ;;
    -*)          usage_err "unknown flag $1" ;;
    *)           [ -z "$SLUG" ] || usage_err "extra arg $1"; SLUG="$1"; shift ;;
  esac
done
require_int "$TIMEOUT" --timeout; require_int "$INTERVAL" --interval; require_int "$MIN_COUNT" --min-count

STATE=$(require_state "$SLUG")
DELAY="$INTERVAL"
while [ "$SECONDS" -lt "$TIMEOUT" ]; do
  if MESSAGES=$(fetch_messages "$STATE"); then
    DELAY="$INTERVAL"
    MATCH=$(jq -c --arg from "$FROM" --arg subject "$SUBJECT" --argjson min "$MIN_COUNT" '
      select(length > $min)
      | map(select((.from | ascii_downcase | contains($from | ascii_downcase))
               and (.subject | ascii_downcase | contains($subject | ascii_downcase)))) | .[0] // empty' <<<"$MESSAGES")
    [ -n "$MATCH" ] && { echo "$MATCH"; exit 0; }
  else
    # ponytail: any fetch failure (network, 429, 5xx) backs off to 30s; no status parsing.
    DELAY=$(( DELAY * 2 > 30 ? 30 : DELAY * 2 ))
  fi
  LEFT=$(( TIMEOUT - SECONDS ))
  sleep $(( DELAY < LEFT ? DELAY : LEFT > 0 ? LEFT : 0 ))
done
echo "TIMEOUT: no matching message after ${TIMEOUT}s" >&2
exit 124
