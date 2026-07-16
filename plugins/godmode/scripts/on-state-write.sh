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
WEB_SLUG="$(jq -r '.dashboard_slug // empty' "$STATE" 2>/dev/null || true)"
PUB="${GODMODE_PUBLISH_CMD:-$HOME/.claude/skills/here-now/scripts/publish.sh}"
if [ -n "$WEB_SLUG" ]; then
  if [ -x "$PUB" ] || command -v "$PUB" >/dev/null 2>&1; then
    if ERR="$("$PUB" "$OUT_HTML" --slug "$WEB_SLUG" 2>&1)"; then
      rm -f "$PENDING" 2>/dev/null || true
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
