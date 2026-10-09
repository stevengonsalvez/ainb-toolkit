#!/usr/bin/env bash
# List known inboxes. Usage: list.sh [--json]
source "$(dirname "$0")/_lib.sh"

shopt -s nullglob
FILES=("$(inbox_dir)"/*.json)
if [ "${1:-}" = "--json" ]; then
  jq -s . "${FILES[@]}" </dev/null
elif [ ${#FILES[@]} -eq 0 ]; then
  echo "No inboxes."
else
  jq -rs '.[] | [.slug, .provider, .address, .created_at, .purpose] | @tsv' "${FILES[@]}" \
    | column -t -s "$(printf '\t')"
fi
