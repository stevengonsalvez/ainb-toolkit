#!/usr/bin/env bash
# Create (or reuse) a disposable inbox and print its address.
# Usage: create.sh <slug> [--purpose "text"] [--provider auto|agents-inbox|inboxapi] [--force]
source "$(dirname "$0")/_lib.sh"

SLUG="" PURPOSE="" PROVIDER="${AGENTMAIL_PROVIDER:-auto}" FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purpose)  PURPOSE="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,3p' "$0"; exit 0 ;;
    -*)         usage_err "unknown flag $1" ;;
    *)          [ -z "$SLUG" ] || usage_err "extra arg $1"; SLUG="$1"; shift ;;
  esac
done

STATE=$(state_file "$SLUG")
if [ -f "$STATE" ] && [ "$FORCE" = 0 ] && known_provider "$STATE"; then
  jq -r '.address' "$STATE"
  exit 0
fi

if [ "$PROVIDER" = auto ]; then
  if MINTED=$(new_address agents-inbox "$SLUG"); then PROVIDER=agents-inbox
  else
    echo "WARN: agents-inbox.com unreachable, falling back to inboxapi" >&2
    PROVIDER=inboxapi; MINTED=$(new_address inboxapi "$SLUG")
  fi
else
  MINTED=$(new_address "$PROVIDER" "$SLUG") || die "$PROVIDER unreachable"
fi
IFS=$'\t' read -r ADDRESS LOCAL <<<"$MINTED" || true

mkdir -p "$(inbox_dir)"
# Open-tier addresses are readable by anyone holding them: never commit state.
[ -f "$(inbox_dir)/.gitignore" ] || echo '*' > "$(inbox_dir)/.gitignore"
jq -n --arg slug "$SLUG" --arg provider "$PROVIDER" --arg address "$ADDRESS" \
  --arg local "$LOCAL" --arg purpose "$PURPOSE" --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{slug: $slug, provider: $provider, address: $address, local: $local, purpose: $purpose, created_at: $created_at}' \
  > "$STATE"
echo "$ADDRESS"
