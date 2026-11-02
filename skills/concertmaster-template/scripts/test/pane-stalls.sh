#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# pane-stalls.sh (test): the tick finds agent panes that sit on a permission prompt ("Do you want to proceed?"),
# hermetic. Why it exists: review subagents stalled for hours on a "Dangerous rm operation" prompt that no
# worktree comment shows. Covers: a hit (lane, host, matched line), no hit (one quiet line), the prompt far up in
# old scrollback (not a hit), an unreadable pane (UNREAD, never clean), a host whose terminals cannot be listed and a
# host the fleet reader cannot reach (UNREAD), a remote host hit (--environment used, handle re-resolved from the
# worktree path), never_touch / shell tabs / out-of-scope paths skipped, a credential-shaped matched line withheld,
# --json, a usage error, and read-only (no send, no close, no key).
# Stub Orca, synthetic names (lane-a, host-a), a mktemp dir; touches nothing else.
#
#   scripts/test/pane-stalls.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-pstall-t.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

FX="$ROOT/fx"; BIN="$ROOT/bin"; mkdir -p "$FX/panes" "$BIN"
cat > "$BIN/orca" <<STUB
#!/usr/bin/env bash
FX="$FX"
env=""; term=""
for ((i = 1; i <= \$#; i++)); do
  case "\${!i}" in
    --environment) j=\$((i + 1)); env="\${!j}" ;;
    --terminal) j=\$((i + 1)); term="\${!j}" ;;
  esac
done
echo "\$*" >> "\$FX/calls.log"
host="\${env:-local}"
case "\$1 \$2" in
  "host list") { printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}'; for h in \$(cat "\$FX/hosts" 2>/dev/null); do printf ',{"kind":"environment","name":"%s"}' "\$h"; done; printf ']}}'; } ;;
  "worktree list") f="\$FX/wl-\$host.json"; [ -r "\$f" ] || { echo "host unreachable" >&2; exit 1; }; cat "\$f" ;;
  "terminal list") f="\$FX/tl-\$host.json"; [ -r "\$f" ] || { echo "terminals unavailable" >&2; exit 1; }; cat "\$f" ;;
  "terminal read") f="\$FX/panes/\$term"; [ -r "\$f" ] || { echo "no such terminal" >&2; exit 1; }
     jq -Rs '{ok:true,result:{terminal:{tail:(split("\n"))}}}' "\$f" ;;
  *) echo "unexpected: \$*" >&2; exit 9 ;;
esac
STUB
chmod +x "$BIN/orca"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/acme/", orca_repo: app, self_name: concertmaster, never_touch: [NEVERid] }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_HOME="$ROOT/home" ORCA_CLI_COMMAND="$BIN/orca" PATH="$BIN:$PATH"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH CM_STALL_REGEX CM_STALL_LINES
mkdir -p "$CM_HOME"
X="$S/pane-stalls.sh"

wl() { # <host> <worktrees json array>
  jq -cn --argjson w "$2" '{ok:true,result:{worktrees:$w}}' > "$FX/wl-$1.json"
}
tl() { # <host> <terminals json array>
  jq -cn --argjson t "$2" '{ok:true,result:{terminals:$t}}' > "$FX/tl-$1.json"
}
pane() { printf '%s\n' "$2" > "$FX/panes/$1"; }
# a pane: a banner, the prompt at the bottom
PROMPT='  Bash command
    rm -rf /tmp/x
  Dangerous rm operation on possibly-empty variable path
 Do you want to proceed?
 ❯ 1. Yes
   2. No'
BUSY='  ● Reading 3 files
  ✻ Thinking... (esc to interrupt)
  sonnet-5.5 · eff high · ctx [█░░░░░] 31%
  ⏵⏵ bypass permissions on (shift+tab to cycle)'

# ---- one host, one stalled lane and one busy lane ----
wl local '[{"path":"/w/acme/lane-a","displayName":"lane-a"},{"path":"/w/acme/lane-b","displayName":"lane-b"}]'
tl local '[{"handle":"t-a","worktreePath":"/w/acme/lane-a","agentIdentity":"claude"},{"handle":"t-b","worktreePath":"/w/acme/lane-b","agentIdentity":"claude"}]'
pane t-a "$PROMPT"; pane t-b "$BUSY"
OUT="$("$X" 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -qP '^STALL\tlane-a\tlocal\tt-a\tDo you want to proceed\?$' <<<"$OUT" && pass "a hit: a STALL row with lane, host, handle and the matched line" || fail "hit" "rc=$RC $OUT"
! grep -q 'lane-b' <<<"$(grep -P '^(STALL|UNREAD)' <<<"$OUT")" && pass "the busy lane is not listed" || fail "busy listed" "$OUT"

# ---- no hit: one quiet line ----
pane t-a "$BUSY"
OUT="$("$X" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(wc -l <<<"$OUT" | tr -d ' ')" = 1 ] && grep -q '^pane-stalls: 0 stalls, 2 panes read$' <<<"$OUT" && pass "no hit: exactly one quiet line, nothing else" || fail "no hit" "rc=$RC $OUT"

# ---- the prompt text far up in old scrollback is not a hit ----
pane t-a "$(printf ' Do you want to proceed?\n'; for i in $(seq 1 40); do echo "  work line $i"; done)"
OUT="$("$X" 2>&1)"
grep -q '^pane-stalls: 0 stalls' <<<"$OUT" && pass "a prompt more than 25 non-empty lines up is old scrollback, not a stall" || fail "scrollback" "$OUT"
OUT="$(CM_STALL_LINES=60 "$X" 2>&1)"
grep -qP '^STALL\tlane-a' <<<"$OUT" && pass "CM_STALL_LINES widens the window" || fail "lines window" "$OUT"
pane t-a "$BUSY"

# ---- an unreadable pane is listed, never clean ----
rm -f "$FX/panes/t-b"
OUT="$("$X" 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -qP '^UNREAD\tlane-b\tlocal\tt-b\tpane not readable$' <<<"$OUT" && grep -q '^pane-stalls: 0 stalls, 1 unread (unknown, not clean), 1 panes read$' <<<"$OUT" \
  && pass "an unreadable pane: an UNREAD row and a count line that says unknown, not clean" || fail "unread pane" "rc=$RC $OUT"
pane t-b "$BUSY"

# ---- hosts: a remote hit, a host with no terminal list, a host the fleet cannot reach ----
echo "host-a host-b host-c" > "$FX/hosts"
wl host-a '[{"path":"/w/acme/lane-r","displayName":"lane-r"}]'
tl host-a '[{"handle":"r-1","worktreePath":"/w/acme/lane-r","agentIdentity":"claude"}]'
pane r-1 "$PROMPT"
wl host-c '[{"path":"/w/acme/lane-c","displayName":"lane-c"}]'
# host-c has a worktree list but no terminal list; host-b has neither
: > "$FX/calls.log"
OUT="$("$X" 2>&1)"; RC=$?
grep -qP '^STALL\tlane-r\thost-a\tr-1\t' <<<"$OUT" && pass "a remote host hit: host-a, handle r-1" || fail "remote hit" "$OUT"
grep -q 'terminal read --terminal r-1 --screen --json --environment host-a' "$FX/calls.log" && pass "the remote pane is read with --environment host-a" || fail "env arg" "$(cat "$FX/calls.log")"
grep -qP '^UNREAD\t-\thost-c\t-\tterminals not listed' <<<"$OUT" && pass "a host whose terminals cannot be listed: UNREAD, panes not read" || fail "no terminal list" "$OUT"
grep -qP '^UNREAD\t-\thost-b\t-\thost not read' <<<"$OUT" && pass "a host the fleet reader cannot reach: UNREAD, not clean" || fail "unreachable host" "$OUT"

# ---- the handle is re-resolved from the worktree path every run, never cached ----
tl host-a '[{"handle":"r-2","worktreePath":"/w/acme/lane-r","agentIdentity":"claude"}]'
pane r-2 "$BUSY"
OUT="$("$X" 2>&1)"
! grep -qP '^STALL\tlane-r' <<<"$OUT" && grep -q 'terminal read --terminal r-2' "$FX/calls.log" && pass "a new handle for the same worktree is the one read (re-resolved each run)" || fail "re-resolve" "$OUT"
rm -f "$FX/wl-host-a.json" "$FX/tl-host-a.json" "$FX/wl-host-c.json"
echo > "$FX/hosts"

# ---- skipped: never_touch, a shell tab, an out-of-scope path ----
wl local '[{"path":"/w/acme/lane-a","displayName":"lane-a"},{"path":"/w/acme/NEVERid","displayName":"NEVERid"}]'
tl local '[{"handle":"t-a","worktreePath":"/w/acme/lane-a","agentIdentity":"claude"},{"handle":"t-n","worktreePath":"/w/acme/NEVERid","agentIdentity":"claude"},{"handle":"t-s","worktreePath":"/w/acme/lane-a","agentIdentity":""},{"handle":"t-o","worktreePath":"/other/place","agentIdentity":"claude"}]'
pane t-n "$PROMPT"; pane t-s "$PROMPT"; pane t-o "$PROMPT"; pane t-a "$BUSY"
OUT="$("$X" 2>&1)"
! grep -qP '^STALL' <<<"$OUT" && grep -q '^pane-stalls: 0 stalls, 1 panes read$' <<<"$OUT" && pass "never_touch, a shell tab (no agent) and a path outside path_match are not read" || fail "skipped" "$OUT"

# ---- a credential-shaped matched line is withheld ----
export CM_STALL_REGEX='token'
B10='abcdefghij'; GHP="gh""p_"   # fake secret bodies are built from short parts at run time
pane t-a "  paste the token ${GHP}${B10}${B10}${B10} here"
OUT="$("$X" 2>&1)"
grep -qP '^STALL\tlane-a\tlocal\tt-a\t\[matched line withheld: credential-shaped\]$' <<<"$OUT" && ! grep -q 'gh''p_' <<<"$OUT" && pass "a credential-shaped matched line is withheld, never printed" || fail "secret" "$OUT"
unset CM_STALL_REGEX
pane t-a "$BUSY"

# ---- a hostile pane line: control characters (ESC, BEL) never reach the tick output ----
pane t-a "$(printf ' \033[31mDo you want to proceed?\007\033]0;x\007')"
OUT="$("$X" 2>&1)"
grep -qP '^STALL\tlane-a' <<<"$OUT" && ! grep -qP '[\x00-\x08\x0b-\x1f]' <<<"$OUT" && pass "ESC and BEL in a matched pane line are stripped before printing" || fail "control chars" "$(printf '%s' "$OUT" | od -c | head -3)"

# ---- --json, usage, read only ----
pane t-a "$PROMPT"
echo "host-b" > "$FX/hosts"
J="$("$X" --json 2>/dev/null)"
jq -e '.counts.stalls == 1 and .counts.unread == 1 and .counts.panesRead == 1 and .stalls[0].lane == "lane-a" and .stalls[0].host == "local" and .stalls[0].handle == "t-a"' <<<"$J" >/dev/null \
  && pass "--json carries stalls, unread and counts" || fail "json" "$J"
"$X" --bogus >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "an unknown argument is a usage error" || fail "usage" "rc=$RC"
! grep -qE 'terminal (send|close|create)|worktree set' "$FX/calls.log" && pass "read only: no send, no close, no create, no worktree set" || fail "read only" "$(grep -E 'terminal (send|close|create)|worktree set' "$FX/calls.log")"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
