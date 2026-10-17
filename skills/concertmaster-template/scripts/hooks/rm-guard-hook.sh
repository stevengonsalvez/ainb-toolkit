#!/usr/bin/env bash
# rm-guard-hook.sh: Claude Code PreToolUse hook (matcher: Bash) that turns the
# "Dangerous rm operation on possibly-empty variable path" approval prompt into an
# instant, self-correcting denial.
#
# Why: with nobody at the keyboard that prompt stalls a lane or a verdict subagent
# for hours. A denial with a fix hint costs the agent one turn instead.
#
# Denies a Bash command only when an `rm` has a recursive or force flag (or a glob)
# AND an argument holding a variable expansion that is not guarded with `${VAR:?}`.
# Allowed: literal paths, "${VAR:?}"/x, rm of a plain "$file" with no -r/-f/glob.
# Everything else, any parse doubt, a missing jq or lib.sh, no command, or a session outside
# this project's checkouts: exit 0, allow. Scope comes from config: the session cwd matches
# worktrees.path_match, or its git origin is a repo of github.org (exclude patterns left out).
#
# Parsing is deliberately simple and portable (bash 3.2, BSD and GNU sed/awk, no \n in sed):
#   1. heredoc bodies are dropped (text written to a file is not a command)
#   2. the command is split on ; & | and newlines, but NOT inside quotes
#   3. each piece loses its leading wrappers (then, do, else, !, {, (, sudo, env, nohup, nice,
#      time, timeout N, VAR=x, xargs and its options) so `for ..; do rm -rf $d; done` is seen
# Known limits (fail open, the built-in prompt still applies): $(...) and backtick bodies,
# eval/bash -c strings, aliases, rm hidden behind a function.
#
# Install: references/prompt-stalls.md. Exit code is always 0; the verdict is the JSON.
set -u
input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0
printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_.-])rm([[:space:]]|$)' || exit 0

# Scope: this project's checkouts only (a global hook must not change other projects). The
# config loader sits next to the hook, one level up (skill tree) or in ~/.concertmaster/bin.
here="$(cd "$(dirname "$0")" && pwd)"
lib=""
for c in "$here/lib.sh" "$here/../lib.sh" "$HOME/.concertmaster/bin/lib.sh"; do
  if [ -r "$c" ]; then lib="$c"; break; fi
done
[ -n "$lib" ] || exit 0
# shellcheck source=SCRIPTDIR/../lib.sh
. "$lib" 2>/dev/null || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
in_scope=0
if [ -n "${CM_PATH_MATCH:-}" ] && [ -n "$cwd" ]; then
  shopt -s nocasematch
  [[ "$cwd/" =~ $CM_PATH_MATCH ]] && in_scope=1
  shopt -u nocasematch
fi
if [ "$in_scope" = 0 ] && [ -n "$cwd" ] && [ -d "$cwd" ] && command -v git >/dev/null 2>&1; then
  url="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  [ -z "$url" ] || cm_org_slug "$url" >/dev/null 2>&1 && in_scope=1
fi
[ "$in_scope" = 1 ] || exit 0

# 1. drop heredoc bodies
cmd="$(printf '%s\n' "$cmd" | awk '
  skip != "" { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == skip) skip = ""; next }
  { print }
  $0 !~ /<<</ && match($0, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/) {
    tag = substr($0, RSTART, RLENGTH); gsub(/^<<-?[ \t]*[\047"]?|[\047"]?$/, "", tag); skip = tag }')"

# 2. split on ; & | and newline, outside quotes only (one segment per output line). Newlines are
#    mapped to \001 first so quote state persists across lines; "\<newline>" continuations are joined.
segs="$(printf '%s' "$cmd" | tr '\n' '\001' | sed -e 's/\\\001//g' | awk '
  { line = $0; n = length(line); q = ""; out = ""
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (q == "") {
        if (c == "\047" || c == "\"") { q = c; out = out c }
        else if (c == ";" || c == "&" || c == "|" || c == "\001") { out = out "\n" }
        else if (c == "\\") { out = out c substr(line, i + 1, 1); i++ }
        else out = out c
      } else {
        if (c == "\\" && q == "\"") { out = out c substr(line, i + 1, 1); i++ }
        else { out = out (c == "\001" ? " " : c); if (c == q) q = "" }
      }
    }
    print out }')"

bad=""
while IFS= read -r seg; do
  # 3. strip leading wrappers until stable
  prev=""; n=0
  while [ "$seg" != "$prev" ] && [ "$n" -lt 8 ]; do
    prev="$seg"; n=$((n + 1))
    seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^(then|do|else|elif|if|while|until|!|\{|\(|sudo|exec|command|builtin|nohup|time|env|nice)([[:space:]]+|$)//; s/^timeout[[:space:]]+[0-9.]+[smhd]?[[:space:]]+//; s/^-[A-Za-z0-9-]+[[:space:]]+[0-9]+[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//; s/^xargs[[:space:]]+//; s/^-[A-Za-z0-9-]+([[:space:]]+[0-9{}][^[:space:]]*)?[[:space:]]+//')"
  done
  seg="$(printf '%s' "$seg" | sed -E 's#^(/usr)?/bin/rm([[:space:]]|$)#rm\2#; s#^\\rm([[:space:]]|$)#rm\1#')"
  seg="$(printf '%s' "$seg" | tr '\t' ' ')"
  case "$seg" in rm|rm\ *) ;; *) continue ;; esac
  risky=0
  # recursive is the risky flag; a lone -f on a plain path is not (the built-in check is about empty-variable trees)
  if [[ " $seg " =~ [[:space:]]-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]] ]] || [[ " $seg " == *" --recursive"* ]]; then risky=1; fi
  case "$seg" in *'*'*) risky=1 ;; esac
  [ "$risky" = 1 ] || continue
  # drop guarded expansions, then any remaining $VAR / ${VAR...} / $( is unguarded
  stripped="$(printf '%s' "$seg" | sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}//g')"
  if printf '%s' "$stripped" | grep -qE '\$([A-Za-z_{(]|[0-9@*])'; then bad="$seg"; break; fi
done <<<"$segs"

[ -n "$bad" ] || exit 0
reason="rm -r/-R/glob with an unguarded variable path may stop on an approval prompt nobody answers. Guard EVERY variable: rm -rf \"\${S:?}\"/name, and for a computed name assign it first (n=\$(...); rm -rf \"\${S:?}\"/\"\${n:?}\"). Or use the literal path. Command was: $bad"
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
