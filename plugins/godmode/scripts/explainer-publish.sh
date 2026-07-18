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
# URL parse is deliberately tight: a receipt with a WRONG url still clears the
# Stop gate, so a loose grab (trailing punctuation, a claim link, an unrelated
# URL in diagnostics) would launder a bad proof into a real one. Stop at any
# whitespace, quote, bracket, or trailing sentence punctuation, and reject
# /claim/ links.
url_from() {
  # Extract candidate URLs, strip trailing punctuation, drop /claim/ links,
  # then PREFER a here.now URL (the real receipt contract) so an unrelated
  # diagnostic URL printed earlier in the output cannot launder a bad receipt.
  # Trailing-punctuation strip: ] MUST be first in the bracket class or it
  # closes the class early (that bug once left a trailing '.' on the receipt).
  local cands hn
  cands="$(printf '%s\n' "$1" \
    | grep -oE 'https://[A-Za-z0-9._~%:@!$&*+,;=/-]+' \
    | sed -E 's/[].,;:)}>"'\''[:space:]]+$//' \
    | grep -v '/claim/')"
  [ -n "$cands" ] || return 0
  hn="$(printf '%s\n' "$cands" | grep -E 'https://[A-Za-z0-9.-]+\.here\.now' | head -1)"
  if [ -n "$hn" ]; then printf '%s\n' "$hn"; else printf '%s\n' "$cands" | head -1; fi
}
if [ -n "${GODMODE_EXPLAINER_CMD:-}" ]; then
  OUT="$("$GODMODE_EXPLAINER_CMD" "$FILE" "$@" 2>&1)" || { echo "$OUT" >&2; exit 1; }
  echo "$OUT"
  URL="$(url_from "$OUT" || true)"
elif [ -f "$HOME/.herenow/explainers.json" ] && [ -f "$PY" ] && [ "$#" -gt 0 ]; then
  OUT="$(python3 "$PY" "$FILE" "$@" 2>&1)" || { echo "$OUT" >&2; exit 1; }
  echo "$OUT"
  # prefer the explicit 'live' line, else 'site:', else any tight match
  LIVE_LINE="$(printf '%s\n' "$OUT" | sed -n 's/^live (KV lag[^:]*)://p; s/^site://p' | head -1 || true)"
  URL="$(url_from "$LIVE_LINE")"
  [ -n "$URL" ] || URL="$(url_from "$OUT" || true)"
else
  PUB="${GODMODE_PUBLISH_CMD:-$HOME/.claude/skills/here-now/scripts/publish.sh}"
  OUT="$("$PUB" "$FILE" 2>&1)" || { echo "$OUT" >&2; exit 1; }
  echo "$OUT"
  URL="$(url_from "$OUT" || true)"
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
