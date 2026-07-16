#!/usr/bin/env bash
# own-plugin-sync.sh: read-only report of own-plugin drift for /sync-learnings v2.
#
# Enumerates marketplaces from known_marketplaces.json installLocation (covers
# github-cloned AND directory-source local-path installs), keeps the ones whose
# clone/dir is THIS toolkit repo, then reports:
#   1. clone drift:  marketplace clone vs its origin (unpushed local edits)
#   2. cache drift:  installed plugin cache vs the clone HEAD (in-session
#      hot-fixes; DESTROYED by the next `claude plugin update` unless ported)
# Emits candidates; never pushes, never edits.
#
# env: KNOWN_MARKETPLACES_FILE (default ~/.claude/plugins/known_marketplaces.json)
#      PLUGIN_CACHE_DIR        (default ~/.claude/plugins/cache)
#      TOOLKIT_REMOTE_MATCH    (default stevengonsalvez/ainb-toolkit)
set -euo pipefail

KM="${KNOWN_MARKETPLACES_FILE:-$HOME/.claude/plugins/known_marketplaces.json}"
CACHE="${PLUGIN_CACHE_DIR:-$HOME/.claude/plugins/cache}"
MATCH="${TOOLKIT_REMOTE_MATCH:-stevengonsalvez/ainb-toolkit}"

[ -f "$KM" ] || { echo "own-plugin-sync: no known_marketplaces.json at $KM"; exit 0; }
command -v jq >/dev/null || { echo "own-plugin-sync: jq required" >&2; exit 1; }

FOUND=0
while IFS=$'\t' read -r NAME LOC SRC; do
  [ -n "$LOC" ] && [ -d "$LOC" ] || continue
  OWN=0
  if [ -d "$LOC/.git" ]; then
    REMOTE="$(git -C "$LOC" remote get-url origin 2>/dev/null || true)"
    case "$REMOTE" in *"$MATCH"*) OWN=1 ;; esac
  fi
  # directory-source installs may be the repo itself (or a worktree of it)
  case "$LOC" in *ainb-toolkit*) OWN=1 ;; esac
  [ "$OWN" = 1 ] || continue
  FOUND=1
  echo "== own marketplace: $NAME ($SRC) at $LOC"

  # 1. clone drift vs origin
  if [ -d "$LOC/.git" ]; then
    git -C "$LOC" fetch --quiet origin 2>/dev/null || true
    DIRTY="$(git -C "$LOC" status --porcelain -- plugins/ 2>/dev/null || true)"
    [ -n "$DIRTY" ] && { echo "  CANDIDATE (uncommitted clone edits under plugins/):"; echo "$DIRTY" | sed 's/^/    /'; }
    AHEAD="$(git -C "$LOC" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    [ "$AHEAD" != "0" ] && echo "  CANDIDATE: $AHEAD unpushed commit(s) in the clone — push or PR them"
  fi

  # 2. cache drift vs clone HEAD, per installed plugin version
  MKT_CACHE="$CACHE/$NAME"
  [ -d "$MKT_CACHE" ] || continue
  for PDIR in "$MKT_CACHE"/*/*/; do
    [ -d "$PDIR" ] || continue
    PLUGIN="$(basename "$(dirname "$PDIR")")"
    SRC_DIR="$LOC/plugins/$PLUGIN"
    [ -d "$SRC_DIR" ] || continue
    if ! diff -rq \
        --exclude '.git' \
        "$PDIR" "$SRC_DIR" >/dev/null 2>&1; then
      echo "  CANDIDATE (cache drift, WILL BE LOST on plugin update): $PDIR"
      diff -rq --exclude '.git' "$PDIR" "$SRC_DIR" 2>/dev/null | head -10 | sed 's/^/    /'
    fi
  done
done < <(jq -r 'to_entries[] | [.key, .value.installLocation, .value.source.source] | @tsv' "$KM")

[ "$FOUND" = 1 ] || echo "own-plugin-sync: no own marketplaces registered"
exit 0
