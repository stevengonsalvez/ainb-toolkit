#!/usr/bin/env bash
# List known inboxes. Usage: list.sh [--json]
source "$(dirname "$0")/_lib.sh"

shopt -s nullglob
FILES=("$(inbox_dir)"/*.json)
# Empty-array guard first: bash 3.2 treats "${FILES[@]}" as unbound under set -u.
if [ ${#FILES[@]} -eq 0 ]; then
  [ "${1:-}" = "--json" ] && echo "[]" || echo "No inboxes."
elif [ "${1:-}" = "--json" ]; then
  jq -s . "${FILES[@]}"
else
  jq -rs '.[] | [.slug, .provider, .address, .created_at, .purpose] | @tsv' "${FILES[@]}" \
    | column -t -s "$(printf '\t')"
fi
