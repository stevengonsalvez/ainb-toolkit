#!/usr/bin/env bash
# PostToolUse hook: the deterministic status pipeline.
# state.json written (Write/Edit tool) -> render dashboard -> publish -> sidecar
# push (holder-gated). Publish/sync infra failures mark pending and NEVER block
# (exit 0). The ONE model-visible failure is lease loss: exit 2 + stderr, so the
# deposed driver downgrades before its next destructive write.
set -uo pipefail

IN="$(cat 2>/dev/null || true)"
[ -n "$IN" ] || exit 0
FP="$(printf '%s' "$IN" | jq -r '.tool_input.file_path // .tool_output.file_path // empty' 2>/dev/null || true)"
case "$FP" in
  */.agents/scratch/*-state.json) ;;
  *) exit 0 ;;
esac

REPO="${FP%/.agents/scratch/*}"
SCRATCH="$REPO/.agents/scratch"
SLUG="$(basename "$FP" | sed 's/-state\.json$//')"
STATE="$SCRATCH/$SLUG-state.json"
[ -f "$STATE" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PENDING="$SCRATCH/$SLUG-publish.pending"
LOST="$SCRATCH/$SLUG-lease-lost"
SESSION_ID="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)"

mark() { # step, error
  jq -n --arg step "$1" --arg err "$2" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{step:$step, error:$err, ts:$ts}' > "$PENDING" 2>/dev/null || true
}

# ---- seed the session token file (single lease-identity source) ----
if [ ! -f "$SCRATCH/$SLUG-session-token" ] && [ -n "$SESSION_ID" ]; then
  mkdir -p "$SCRATCH"
  printf '%s' "$SESSION_ID" > "$SCRATCH/$SLUG-session-token" 2>/dev/null || true
fi

# ---- driver_session_id backfill (first writer wins) ----
# The model cannot know its own session_id; this hook does. The session that
# writes programme state IS the driver; record it so the Stop gate can scope.
DRIVER_CUR="$(jq -r '.driver_session_id // empty' "$STATE" 2>/dev/null || true)"
if [ -z "$DRIVER_CUR" ] || [ "$DRIVER_CUR" = "null" ]; then
  if [ -n "$SESSION_ID" ]; then
    TMPS="$(mktemp)"
    if jq --arg s "$SESSION_ID" '.driver_session_id = $s' "$STATE" > "$TMPS" 2>/dev/null; then
      mv "$TMPS" "$STATE"
    else
      rm -f "$TMPS"
    fi
  fi
fi

# ---- render (deterministic, local) ----
OUT_HTML="$REPO/explainers/$SLUG.html"
PENDING_ARG=()
[ -f "$PENDING" ] && PENDING_ARG=(--pending "$PENDING")
if ! ERR="$(python3 "$SCRIPT_DIR/render_dashboard.py" \
      --state "$STATE" --beads "$REPO/.beads/issues.jsonl" \
      --charter "$REPO/.agents/goals/$SLUG-charter.md" \
      --repo "$REPO" --out "$OUT_HTML" "${PENDING_ARG[@]}" 2>&1)"; then
  mark render "$ERR"
  exit 0
fi

# ---- publish (here.now; override for tests via GODMODE_PUBLISH_CMD) ----
# here.now semantics: --slug can only UPDATE an existing publish; creates get a
# server-assigned slug. First successful create's slug is remembered in the
# site file and reused for every update after.
WEB_SLUG="$(jq -r '.dashboard_slug // empty' "$STATE" 2>/dev/null || true)"
SITE_FILE="$SCRATCH/$SLUG-dashboard-site"
PUB="${GODMODE_PUBLISH_CMD:-$HOME/.claude/skills/here-now/scripts/publish.sh}"
if [ -n "$WEB_SLUG" ]; then
  if [ -x "$PUB" ] || command -v "$PUB" >/dev/null 2>&1; then
    TARGET_SLUG="$WEB_SLUG"
    [ -f "$SITE_FILE" ] && TARGET_SLUG="$(cat "$SITE_FILE")"
    if ERR="$("$PUB" "$OUT_HTML" --slug "$TARGET_SLUG" 2>&1)"; then
      printf '%s' "$TARGET_SLUG" > "$SITE_FILE" 2>/dev/null || true
      rm -f "$PENDING" 2>/dev/null || true
    elif printf '%s' "$ERR" | grep -qi 'not found'; then
      # slug never created: create fresh, remember the server-assigned slug
      if OUT_URL="$("$PUB" "$OUT_HTML" 2>&1)"; then
        URL="$(printf '%s\n' "$OUT_URL" | grep -oE 'https://[^ ]+' | tail -1)"
        NEW_SLUG="$(printf '%s' "$URL" | sed -n 's|https://\([^.]*\)\.here\.now.*|\1|p')"
        if [ -n "$NEW_SLUG" ]; then printf '%s' "$NEW_SLUG" > "$SITE_FILE"; fi
        echo "godmode: dashboard created at $URL (requested slug '$WEB_SLUG' unavailable: create assigns slugs)" >&2
        rm -f "$PENDING" 2>/dev/null || true
      else
        mark publish "$OUT_URL"
      fi
    else
      mark publish "$ERR"
    fi
  else
    mark publish "publish command missing: $PUB"
  fi
fi

# ---- sidecar push (holder-gated + debounced inside sync.sh) ----
SYNC="$SCRIPT_DIR/sync.sh"
if [ -x "$SYNC" ]; then
  GODMODE_REPO="$REPO" GODMODE_SESSION_ID="$SESSION_ID" "$SYNC" push "$SLUG" >/dev/null 2>&1 || true
fi

# ---- lease-lost surfacing: the one exit-2 path ----
if [ -f "$LOST" ]; then
  HOLDER="$(cat "$LOST" 2>/dev/null || echo unknown)"
  echo "godmode: lease lost to $HOLDER. Downgrade to read-only, post handoff note, stop re-arming." >&2
  exit 2
fi
exit 0
