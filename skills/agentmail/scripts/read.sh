#!/usr/bin/env bash
# Read a message and optionally extract a code or link.
# Usage: read.sh <slug> [--index N | --message ID] [--extract raw|verification|magic-link]
#   --index 0 (default) is the newest message.
#   raw          message JSON (default)
#   verification first standalone 6-digit code in subject or body
#   magic-link   first https:// URL in body
source "$(dirname "$0")/_lib.sh"

SLUG="" INDEX=0 ID="" EXTRACT=raw
while [ $# -gt 0 ]; do
  case "$1" in
    --index)   INDEX="$2"; shift 2 ;;
    --message) ID="$2"; shift 2 ;;
    --extract) EXTRACT="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    -*)        usage_err "unknown flag $1" ;;
    *)         [ -z "$SLUG" ] || usage_err "extra arg $1"; SLUG="$1"; shift ;;
  esac
done
require_int "$INDEX" --index

STATE=$(require_state "$SLUG")
MSG=$(fetch_messages "$STATE" | jq -c --arg id "$ID" --argjson i "$INDEX" \
  'if $id != "" then map(select(.id == $id)) | .[0] else .[$i] end // empty')
[ -n "$MSG" ] || die "no message found in '$SLUG'"

case "$EXTRACT" in
  raw) echo "$MSG" ;;
  verification)
    CODE=$(jq -r '.subject, .text' <<<"$MSG" \
      | grep -oE '(^|[^0-9])[0-9]{6}([^0-9]|$)' | tr -cd '0-9\n' | head -1 || true)
    [ -n "$CODE" ] || die "no verification code found"
    echo "$CODE" ;;
  magic-link)
    LINK=$(jq -r '.text, .html' <<<"$MSG" | grep -oE 'https://[^[:space:]"<>'"'"')]+' | head -1 || true)
    [ -n "$LINK" ] || die "no https link found"
    echo "$LINK" ;;
  *) usage_err "--extract must be raw, verification or magic-link" ;;
esac
