#!/usr/bin/env bash
# The receipt writer. Godmode phase explainers MUST publish through this
# wrapper: the publisher itself leaves no local proof, and the receipt file is
# the only artifact the Stop gate trusts.
#
# usage: explainer-publish.sh <html-file> <slug> <phase> [publisher args...]
#        (domain mode passes through: --path p --title t --desc d --category c)
set -euo pipefail

FILE="${1:?usage: explainer-publish.sh <html-file> <slug> <phase> [publisher args...]}"
SLUG="${2:?slug}"
PHASE="${3:?phase}"
shift 3

REPO="${GODMODE_REPO:-$PWD}"
SCRATCH="$REPO/.agents/scratch"
RECEIPTS="$SCRATCH/$SLUG-explainer-receipts.json"
PY="$HOME/.claude/skills/explain-to-me/scripts/publish_explainer.py"

URL=""
if [ -n "${GODMODE_EXPLAINER_CMD:-}" ]; then
  OUT="$("$GODMODE_EXPLAINER_CMD" "$FILE" "$@" 2>&1)" || { echo "$OUT" >&2; exit 1; }
  echo "$OUT"
  URL="$(echo "$OUT" | grep -oE 'https://[^ ]+' | head -1 || true)"
elif [ -f "$HOME/.herenow/explainers.json" ] && [ -f "$PY" ] && [ "$#" -gt 0 ]; then
  OUT="$(python3 "$PY" "$FILE" "$@" 2>&1)" || { echo "$OUT" >&2; exit 1; }
  echo "$OUT"
  URL="$(echo "$OUT" | sed -n 's/^live (KV lag[^:]*): \(https:.*\)$/\1/p' | head -1)"
  [ -n "$URL" ] || URL="$(echo "$OUT" | sed -n 's/^site: \(https:.*\)$/\1/p' | head -1)"
else
  PUB="${GODMODE_PUBLISH_CMD:-$HOME/.claude/skills/here-now/scripts/publish.sh}"
  OUT="$("$PUB" "$FILE" 2>&1)" || { echo "$OUT" >&2; exit 1; }
  echo "$OUT"
  URL="$(echo "$OUT" | grep -oE 'https://[^ ]+' | head -1 || true)"
fi

if [ -z "$URL" ]; then
  echo "explainer-publish: publish produced no URL, NO receipt written" >&2
  exit 1
fi

mkdir -p "$SCRATCH"
[ -f "$RECEIPTS" ] || echo '[]' > "$RECEIPTS"
TMP="$(mktemp)"
jq --arg p "$PHASE" --arg u "$URL" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + [{phase:$p, url:$u, ts:$ts}]' "$RECEIPTS" > "$TMP" && mv "$TMP" "$RECEIPTS"
echo "receipt: $PHASE -> $URL"
