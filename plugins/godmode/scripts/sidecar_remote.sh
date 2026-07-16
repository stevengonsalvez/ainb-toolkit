#!/usr/bin/env bash
# godmode sidecar plumbing: pull/push {state.json,charter.md,lease.json} on a
# dedicated ref refs/godmode/<slug>, checkout-free (GIT_INDEX_FILE), ONE commit
# per push. The lease lives on the same ref pulls read: never fall back to a
# branch (a lock invisible to its readers is split-brain, not a lock).
#
# usage: sidecar_remote.sh pull <repo-dir> <slug>
#        sidecar_remote.sh push <repo-dir> <slug> <src-dir>
# env:   GODMODE_SYNC_REF (default refs/godmode/<slug>)
#        GODMODE_SYNC_CACHE (pull target, default .agents/scratch/.godmode-sync/<slug>)
#        GODMODE_SYNC_MSG (push commit message)
# exit:  0 ok/nothing-to-do · 2 usage/validation · 3 non-fast-forward (CAS raced)
#        6 ref not pushable (fail CLOSED: protected/declined/unknown)
set -euo pipefail

MODE="${1:-}"; REPO="${2:-}"; SLUG="${3:-}"; SRC="${4:-}"
[ -n "$MODE" ] && [ -n "$REPO" ] && [ -n "$SLUG" ] || {
  echo "usage: sidecar_remote.sh pull|push <repo-dir> <slug> [src-dir]" >&2; exit 2; }

REF="${GODMODE_SYNC_REF:-refs/godmode/$SLUG}"
LOCAL_REF="refs/godmode-sync/$SLUG"
FILES=(state.json charter.md lease.json)

cd "$REPO"

fetch_tip() {
  git fetch --quiet origin "+$REF:$LOCAL_REF" 2>/dev/null || true
  git rev-parse --verify --quiet "$LOCAL_REF" 2>/dev/null || true
}

case "$MODE" in
  pull)
    TIP="$(fetch_tip)"
    OUT="${GODMODE_SYNC_CACHE:-$REPO/.agents/scratch/.godmode-sync/$SLUG}"
    mkdir -p "$OUT"
    if [ -z "$TIP" ]; then
      echo "sidecar: ref absent ($REF)"
      exit 0
    fi
    for f in "${FILES[@]}"; do
      if git cat-file -e "$TIP:$f" 2>/dev/null; then
        git show "$TIP:$f" > "$OUT/$f"
      else
        rm -f "$OUT/$f"
      fi
    done
    echo "sidecar: pulled $REF -> $OUT"
    ;;

  push)
    [ -n "$SRC" ] && [ -d "$SRC" ] || { echo "sidecar: push needs <src-dir>" >&2; exit 2; }
    for f in "${FILES[@]}"; do
      [ -f "$SRC/$f" ] || continue
      case "$f" in
        *.json) jq empty "$SRC/$f" >/dev/null 2>&1 || { echo "sidecar: invalid JSON in $f" >&2; exit 2; } ;;
        *)      [ -s "$SRC/$f" ] || { echo "sidecar: empty $f" >&2; exit 2; } ;;
      esac
    done

    TIP="$(fetch_tip)"
    IDX="$(mktemp)"
    trap 'rm -f "$IDX"' EXIT
    export GIT_INDEX_FILE="$IDX"
    if [ -n "$TIP" ]; then git read-tree "$TIP"; else git read-tree --empty; fi

    CHANGED=0
    for f in "${FILES[@]}"; do
      [ -f "$SRC/$f" ] || continue
      BLOB="$(git hash-object -w "$SRC/$f")"
      git update-index --add --cacheinfo "100644,$BLOB,$f"
      CHANGED=1
    done
    if [ "$CHANGED" = 0 ]; then
      unset GIT_INDEX_FILE
      echo "sidecar: nothing to push"
      exit 0
    fi

    TREE="$(git write-tree)"
    if [ -n "$TIP" ] && [ "$(git rev-parse "$TIP^{tree}")" = "$TREE" ]; then
      unset GIT_INDEX_FILE
      echo "sidecar: unchanged"
      exit 0
    fi
    MSG="${GODMODE_SYNC_MSG:-chore(godmode): sidecar sync $SLUG}"
    if [ -n "$TIP" ]; then
      C="$(git commit-tree "$TREE" -p "$TIP" -m "$MSG")"
    else
      C="$(git commit-tree "$TREE" -m "$MSG")"
    fi
    unset GIT_INDEX_FILE

    ERR="$(mktemp)"
    if git push --quiet origin "$C:$REF" 2>"$ERR"; then
      rm -f "$ERR"
      echo "sidecar: pushed $C -> $REF"
      exit 0
    fi
    # Classify BEFORE any verdict; hook-declined mentions "rejected" too, so
    # check the fail-closed class first.
    if grep -qiE 'pre-receive hook declined|hook declined|protected|permission denied|not permitted|access denied' "$ERR"; then
      cat "$ERR" >&2; rm -f "$ERR"
      echo "cross-machine sync disabled: refs/godmode/* not pushable on this remote" >&2
      exit 6
    fi
    if grep -qiE 'non-fast-forward|fetch first|\[rejected\]' "$ERR"; then
      rm -f "$ERR"
      exit 3
    fi
    cat "$ERR" >&2; rm -f "$ERR"
    echo "cross-machine sync disabled: refs/godmode/* not pushable on this remote" >&2
    exit 6
    ;;

  *) echo "sidecar: unknown mode '$MODE'" >&2; exit 2 ;;
esac
