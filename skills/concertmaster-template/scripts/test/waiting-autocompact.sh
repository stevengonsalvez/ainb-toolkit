#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# waiting-autocompact.sh (test): waiting.sh must report the Claude Code autocompact dialog ("We
# recommend compacting earlier", "Autocompact at <N> tokens", footer ending "esc not now") as a
# blocked prompt, keep listing AskUserQuestion menus, and NOT report a status line, quoted text,
# a repo doc shown mid-session or a dialog on a session that was active under 2 minutes ago.
# Stub Orca CLI, one pane screen per terminal handle; touches nothing outside a mktemp dir.
#
#   scripts/test/waiting-autocompact.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-waitac.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
# terminal read answers per handle (--terminal <handle>), everything else is fixed.
handle=""
for ((i = 1; i <= $#; i++)); do [ "${!i}" = "--terminal" ] && { j=$((i + 1)); handle="${!j}"; }; done
DIALOG='We recommend compacting earlier\\n  Autocompact at \u2039 400k \u203a tokens\\n  Keep 1m\\n  \u2191/\u2193 choose \u00b7 \u2190/\u2192 change size \u00b7 enter confirm \u00b7 esc not now'
NOW=$(( $(date +%s) * 1000 ))
case "$1 $2" in
  "host list") printf '{"result":{"hosts":[{"name":"this machine"}]}}' ;;
  "worktree ps") printf '{"result":{"worktrees":[{"path":"/w/acme/compact","displayName":"Compact-lane"},{"path":"/w/acme/menu","displayName":"Menu-lane"},{"path":"/w/acme/status","displayName":"Status-lane"},{"path":"/w/acme/quoted","displayName":"Quoted-lane"},{"path":"/w/acme/doc","displayName":"Doc-lane"},{"path":"/w/acme/fresh","displayName":"Fresh-lane"},{"path":"/w/acme/idle","displayName":"Idle-lane"}]}}' ;;
  "terminal list") printf '{"result":{"terminals":[{"handle":"h-compact","worktreePath":"/w/acme/compact","lastOutputAt":1},{"handle":"h-menu","worktreePath":"/w/acme/menu","lastOutputAt":1},{"handle":"h-status","worktreePath":"/w/acme/status","lastOutputAt":1},{"handle":"h-quoted","worktreePath":"/w/acme/quoted","lastOutputAt":1},{"handle":"h-doc","worktreePath":"/w/acme/doc","lastOutputAt":1},{"handle":"h-fresh","worktreePath":"/w/acme/fresh","lastOutputAt":%s},{"handle":"h-idle","worktreePath":"/w/acme/idle","lastOutputAt":1}]}}' "$NOW" ;;
  "terminal read")
    case "$handle" in
      h-compact) printf '{"result":{"screen":"%s"}}' "$DIALOG" ;;
      h-fresh) printf '{"result":{"screen":"%s"}}' "$DIALOG" ;;
      h-menu) printf '{"result":{"screen":"Which approach?\\n  Enter to select \u00b7 arrow keys to navigate"}}' ;;
      h-status) printf '{"result":{"screen":"opus-5.5 \u00b7 ctx 33%% \u00b7 Autocompact at 400k tokens\\n  bypass permissions on"}}' ;;
      h-quoted) printf '{"result":{"screen":"the rule says dismiss it with esc not now when the footer shows Autocompact at 400k tokens and then nudge"}}' ;;
      h-doc) printf '{"result":{"screen":"Autocompact at 400k tokens and a footer ending esc not now\\n1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\n10\\n11\\n12\\n13\\n14\\n15\\n16\\nworking on the next step"}}' ;;
      *) printf '{"result":{"screen":"working..."}}' ;;
    esac ;;
esac
STUB
chmod +x "$BIN/orca"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/acme/", orca_repo: app }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_HOME="$ROOT/home" ORCA_CLI_COMMAND="$BIN/orca" PATH="$BIN:$PATH"
mkdir -p "$CM_HOME"

out="$("$S/waiting.sh" 2>/dev/null)"; rc=$?
row() { grep -F "$1" <<<"$out" | head -1; }

r="$(row h-compact)"
[ -n "$r" ] && grep -q 'Compact-lane' <<<"$r" && grep -q 'BLOCKED PROMPT: autocompact' <<<"$r" \
  && pass "the real autocompact dialog is reported as a blocked prompt" || fail "autocompact prompt" "row: ${r:-none}"
grep -q 'Esc dismisses' <<<"$r" && grep -q 'never change the setting' <<<"$r" \
  && pass "the row says to dismiss with Esc and not to touch the setting" || fail "row hint" "row: ${r:-none}"
printf '%s\n' "$r" | awk -F'\t' 'NF==5 {ok=1} END {exit !ok}' \
  && pass "the row keeps the five-column TSV shape" || fail "tsv shape" "row: ${r:-none}"

r="$(row h-menu)"
[ -n "$r" ] && grep -q 'Menu-lane' <<<"$r" && ! grep -q 'BLOCKED PROMPT' <<<"$r" \
  && pass "an AskUserQuestion menu is still listed as a menu" || fail "menu row" "row: ${r:-none}"

[ -z "$(row h-status)" ] && pass "a status line that only says Autocompact at is not reported" || fail "status line" "row: $(row h-status)"
[ -z "$(row h-quoted)" ] && pass "quoted text with both phrases mid-sentence is not reported" || fail "quoted text" "row: $(row h-quoted)"
[ -z "$(row h-doc)" ] && pass "text with both phrases above the last 15 lines is not reported" || fail "doc text" "row: $(row h-doc)"
[ -z "$(row h-fresh)" ] && pass "the dialog on a session active under 2 minutes ago is not reported" || fail "fresh session" "row: $(row h-fresh)"
[ -z "$(row h-idle)" ] && pass "a working session is not reported" || fail "idle" "row: $(row h-idle)"
[ "$rc" -eq 0 ] && pass "waiting.sh exits 0" || fail "exit status" "rc=$rc"
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
  && pass "exactly two rows (the dialog and the menu)" || fail "row count" "out: $out"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
