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
# Also denies a raw `orca worktree rm` / `orca worktree remove` (also as orca-ide, orca-dev, plugly, plugly-dev, plugly-ide, $ORCA_CLI_COMMAND or
# an $ORCA... variable; any flags; any position in a chain or pipeline; also inside an ssh / bash -c / sh -c
# string, $( ) and backticks, find -exec) when the session cwd or the command text is in the path match (worktrees.path_match). The
# teardown gates (beads, open follow-ups, salvage, parent and child worktrees) live in scripts/teardown.sh, which
# calls orca itself where this hook never looks; a raw removal skips all of them.
# Not covered (fail open, or by design): `git worktree remove` and `rm -rf <literal path>` (a person or an agent
# may clean its own scratch worktree), text piped into a shell (echo "orca worktree rm x" | bash), launchers such as
# parallel and xargs -I{} {}, ANSI-C escapes (\n, \x41) inside $'...', aliases and functions. A command with more
# than 20 ssh / shell pieces and substitutions ($(, backtick pairs, <( counted one by one; or 500 pieces naming worktree) is denied outright: reading them would outlast the 5 s hook timeout, and a timed-out
# hook allows the command.
#
# Parsing is deliberately simple and portable (bash 3.2, BSD and GNU sed/awk, no \n in sed):
#   1. heredoc bodies are dropped (text written to a file is not a command)
#   2. the command is split on ; & | and newlines, but NOT inside quotes
#   3. each piece loses its leading wrappers (then, do, else, !, {, (, sudo, env, nohup, nice,
#      time, timeout N, VAR=x, xargs and its options) so `for ..; do rm -rf $d; done` is seen
# Known limits of the rm rule (fail open, the built-in prompt still applies): $(...) and backtick bodies,
# aliases, rm hidden behind a function.
#
# Install: references/prompt-stalls.md. Exit code is always 0; the verdict is the JSON.
set -u
input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0
cmd="${cmd//[$'\001'$'\002'$'\003']/_}"   # the parser uses these bytes as boundary markers: input must not forge them
# backslash-newline joins lines, so "worktree \<newline> remove" is "worktree remove" (the segment parser below does the same)
norm="${cmd//\\$'\n'/}"; norm="${norm//[\"\']/}"; norm="${norm//\\/}"   # orca "worktree" "rm" is the same command
printf '%s' "$norm" | grep -qE '(^|[^[:alnum:]_.-])rm([[:space:]]|$)|worktree[[:space:]].*(rm|remove|delete)([^[:alnum:]_-]|$)' || exit 0

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
  if [ -n "$url" ] && cm_org_slug "$url" >/dev/null 2>&1; then in_scope=1; fi
fi
# The raw worktree removal rule also applies when the command itself names a path in the match.
cmd_scope=0
if [ -n "${CM_PATH_MATCH:-}" ]; then
  shopt -s nocasematch
  [[ "$cmd/" =~ $CM_PATH_MATCH ]] && cmd_scope=1
  shopt -u nocasematch
fi
[ "$in_scope" = 1 ] || [ "$cmd_scope" = 1 ] || exit 0

# 1. drop heredoc bodies, except those fed to ssh / bash / sh / zsh / dash / ksh: that body IS commands. A "<<" only
#    starts a body when it is a real heredoc operator: not inside quotes, a comment, $(( )) / (( )) / $[ ] arithmetic
#    (x=$((1<<n))), not a here-string (<<<). The scanner keeps quote and substitution state across lines. A line it
#    cannot read as a heredoc stays live, so a doubt scans more, never less.
cmd="$(printf '%s\n' "$cmd" | awk '
  function lex(line,   n, i, c, nx, top, pv, j, tg, uqt, cq) {
    n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1); nx = substr(line, i + 1, 1); top = (sp > 0 ? st[sp] : "C")
      if (top == "S") { if (c == "\047") sp--; continue }
      if (top == "A") { if (c == "(") par[sp]++; else if (c == ")") { par[sp]--; if (par[sp] <= 0) sp-- }; continue }
      if (top == "K") { if (c == "]") sp--; continue }
      if (top == "B") { if (c == "}") sp--; continue }
      if (c == "\\") { i++; continue }
      if (top == "D") {
        if (c == "\"") sp--
        else if (c == "$" && nx == "(") {
          if (substr(line, i + 2, 1) == "(") { sp++; st[sp] = "A"; par[sp] = 2; i += 2 } else { sp++; st[sp] = "C"; par[sp] = 1; i++ } }
        else if (c == "`") { sp++; st[sp] = "T" }
        continue }
      if (top == "T" && c == "`") { sp--; continue }
      if (c == "\047") { sp++; st[sp] = "S"; continue }
      if (c == "\"") { sp++; st[sp] = "D"; continue }
      if (c == "`") { sp++; st[sp] = "T"; continue }
      if (c == "#") { pv = (i > 1 ? substr(line, i - 1, 1) : " "); if (pv ~ /[ \t;&|(]/) break; continue }
      if (c == "$" && nx == "(") {
        if (substr(line, i + 2, 1) == "(") { sp++; st[sp] = "A"; par[sp] = 2; i += 2 } else { sp++; st[sp] = "C"; par[sp] = 1; i++ }
        continue }
      if (c == "$" && nx == "[") { sp++; st[sp] = "K"; i++; continue }
      if (c == "$" && nx == "{") { sp++; st[sp] = "B"; i++; continue }
      if (c == "(" && nx == "(") { pv = (i > 1 ? substr(line, i - 1, 1) : " "); if (pv ~ /[ \t;&|(]/) { sp++; st[sp] = "A"; par[sp] = 2; i++; continue } }
      if (c == "(" && sp > 0 && st[sp] == "C") { par[sp]++; continue }
      if (c == ")" && sp > 0 && st[sp] == "C") { par[sp]--; if (par[sp] <= 0) sp--; continue }
      if (c == "<" && nx == "<") {
        if (substr(line, i + 2, 1) == "<") { i += 2; continue }
        j = i + 2; if (substr(line, j, 1) == "-") j++
        while (substr(line, j, 1) ~ /[ \t]/) j++
        uqt = 1; tg = ""   # the delimiter is one shell word: quotes, $'EOF', backslashes and adjacent fragments are removed (E"O"F, <<'E'OF)
        while (j <= n) {
          d = substr(line, j, 1)
          if (d == "\\") { uqt = 0; j++; tg = tg substr(line, j, 1); j++; continue }
          if (d == "$" && substr(line, j + 1, 1) ~ /[\047"]/) { j++; continue }
          if (d == "\047" || d == "\"") { uqt = 0; cq = d; j++; while (j <= n && substr(line, j, 1) != cq) { tg = tg substr(line, j, 1); j++ }; j++; continue }
          if (d ~ /[ \t;&|<>()`]/) break
          tg = tg d; j++ }
        if (top == "T" && index(substr(line, j), "`") > 0) tg = ""   # `cat <<EOF` closed on this line has no body
        gsub(/^[ \t]+|[ \t]+$/, "", tg)   # the closing line is trimmed below; trim the tag the same way, so the hook closes a body at least as early as bash (<<"EOF ", <<\ EOF)
        if (tg != "" && ptag == "") { ptag = tg; puq = uqt }
        i = j - 1 } } }
  skip != "" { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == skip) { skip = ""; keep = 0; next }
    if (uq && ($0 ~ /\$\(/ || $0 ~ /`/)) keep = 1   # from the first substitution on, the rest of an unquoted body may be its multi-line command
    if (uq && keep) { l = $0; gsub(/\047/, "", l); print l }   # an unquoted heredoc still runs its substitutions, and a single quote in it is a plain character
    next }
  { print; ptag = ""; lex($0)
    if (ptag != "") {
      h = $0; sub(/[ \t]#.*/, "", h)   # a comment on the opening line does not name the consumer
      if (h !~ /(^|[ \t;&|(\/])(ssh|bash|sh|zsh|dash|ksh)([ \t]|<)/) { skip = ptag; uq = puq } } }')"

# 2. split on ; & | and newline, outside quotes only (one segment per output line). Newlines are
#    mapped to \001 first so quote state persists across lines (a newline inside quotes becomes ";", so a multi-line ssh / bash -c payload keeps its command boundaries); "\<newline>" continuations are joined.
cmd_joined="${cmd//\\$'\n'/$'\003'}"   # cmd may have been rewritten since the prefilter (heredoc bodies)
split_cmd() { awk '
  { line = $0; n = length(line); q = ""; out = ""
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1); wascm = cm; cm = 0
      if (c == "\003") {   # backslash-newline: a join, except that it does not continue a comment or hold inside single quotes
        if (q == "") { if (wascm) out = out "\n" }
        else if (q == "\047") out = out ";"
        continue }
      if (q == "") {
        if (c == "\047" || c == "\"") { q = c; out = out c }
        else if (c == "&" && (substr(line, i - 1, 1) ~ /[<>]/ || substr(line, i + 1, 1) == ">")) { out = out c }   # 2>&1, >&2, &>f are redirections
        else if (c == ";" || c == "&" || c == "|" || c == "\001" || c == "\002") { out = out "\n" }
        else if (c == "\\") {
          if (substr(line, i + 1, 1) == "\003") out = out c "\n"   # an escaped backslash, then a real newline (a\\<newline>): the next line runs
          else out = out c substr(line, i + 1, 1)
          i++ }
        else if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(\001\002]/)) { while (i < n && (nc = substr(line, i + 1, 1)) != "\001" && nc != "\002" && nc != "\003") i++; cm = 1 }   # a comment runs to the newline; an apostrophe in it opens no quote
        else out = out c
      } else {
        if (c == "\\" && q == "\"") { out = out c (substr(line, i + 1, 1) == "\003" ? "\002" : substr(line, i + 1, 1)); i++ }
        else { out = out (c == "\001" ? "\002" : c); if (c == q) q = "" }   # a newline inside quotes: \002, which a nested split treats like a newline
      }
    }
    print out }'; }
segs="$(printf '%s' "$cmd_joined" | tr '\n' '\001' | split_cmd)"

bad=""; rawwt=""; rm_n=0; heavy_n=0; over=""
# raw orca worktree removal. Scanned word by word, not with one big regex: a long option list made the regex
# backtrack for seconds. Three shapes: the command itself; a string handed to ssh / bash / sh / zsh where the
# command starts after -c and a quote, or after ; & | or ( ; ssh, where everything after the host is the remote command.
# A few wrappers may sit in front of orca (env, sudo, exec, nohup, time, timeout N, VAR=x), and orca global flags
# may take a value (orca --environment host-a worktree rm).
# The CLI is orca, orca-ide (cm_cli picks it on Linux outside an Orca terminal), plugly, plugly-dev, plugly-ide, or the basename of
# $ORCA_CLI_COMMAND or $PLUGLY_CLI_COMMAND.
cli_base="${ORCA_CLI_COMMAND:-}"; cli_base="${cli_base##*/}"
case "$cli_base" in *[!A-Za-z0-9._-]*) cli_base="" ;; esac
plugly_base="${PLUGLY_CLI_COMMAND:-}"; plugly_base="${plugly_base##*/}"
case "$plugly_base" in *[!A-Za-z0-9._-]*) plugly_base="" ;; esac
is_orca_bin() { local b="${1##*/}"; b="${b#\\}"; case "$1" in '$'*|'`'*) return 0 ;; esac; case "$b" in orca|orca-ide|orca-dev|plugly|plugly-dev|plugly-ide|cm_cli|cm_orca) return 0 ;; esac; { [ -n "$cli_base" ] && [ "$b" = "$cli_base" ]; } || { [ -n "$plugly_base" ] && [ "$b" = "$plugly_base" ]; }; }
# $1 = text; true when it starts (after wrappers) with <orca> [flags] worktree rm|remove|delete
starts_wt_rm() {
  local t="$1" i=0 n nx x wd; local -a w
  while :; do case "$t" in [[:space:]]*|\"*|\'*|\(*|\;*|\&*|\|*) t="${t:1}" ;; *) break ;; esac; done
  t="${t//[\"\'\\]/}"   # quotes and backslashes inside a word do not change the command: orca "worktree" "rm", or\ca, r\m
  read -ra w <<<"$t"; n=${#w[@]}
  local -a w0=(${w[@]+"${w[@]}"}); w=(); local k=0   # redirections may sit before or between command words: 2>/dev/null orca ..., orca worktree 2>&1 rm
  while [ "$k" -lt "$n" ]; do
    case "${w0[k]}" in
      [0-9]|[0-9][0-9]) [ "$k" -gt 0 ] && w+=("${w0[k]}") ;;   # first word only: what is left of 2>&1 once the splitter cut at & (timeout 30 keeps its 30)
      [0-9]*[\<\>]*|[\<\>]*|'&>'*) case "${w0[k]}" in *[\<\>]) k=$((k + 1)) ;; esac ;;   # an operator alone takes the next word as its target
      *[\<\>]*) w+=("${w0[k]%%[<>]*}") ;;   # worktree>/dev/null rm: the word is worktree
      *) w+=("${w0[k]}") ;;
    esac
    k=$((k + 1))
  done
  n=${#w[@]}
  while [ "$i" -lt "$n" ]; do
    wd="${w[i]}"; case "$wd" in */*) case "$wd" in *=*) ;; *) wd="${wd##*/}" ;; esac ;; esac   # /usr/bin/env is env
    case "$wd" in
      nohup|time|command|eval|setsid|stdbuf|watch|xargs|then|do|else|elif|if|while|until|'!'|'{') i=$((i + 1)) ;;
      -u|-g|-h|-p|-C|-D|-R|-T|-U|-k|-s|-n|-S|-I|-L|-E) i=$((i + 2)) ;;   # what is left of sudo -u x / env -u x once the caller stripped the wrapper
      -*) i=$((i + 1)) ;;
      exec|sudo|doas|env|nice|ionice|chrt|flock|taskset|timeout)   # wrappers whose options may take a value: sudo -u user-a, timeout -k 5 30, env -u X
        x="$wd"; i=$((i + 1))
        while [ "$i" -lt "$n" ]; do   # the options that take a value differ per wrapper (sudo -n is a switch, nice -n is not)
          case "$x:${w[i]}" in
            sudo:--user|sudo:--group|sudo:--host|sudo:--prompt|exec:-a|taskset:-c|taskset:-p|sudo:-*[ughpCDRTU]|doas:-u|env:-u|env:-C|env:-S|nice:-n|ionice:-[cnpPt]|flock:-w|flock:-E|timeout:-k|timeout:-s) i=$((i + 2)) ;;
            *:-*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        case "$x" in timeout|chrt|flock) i=$((i + 1)) ;; esac ;;   # the duration, the priority, the lock file
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] && is_orca_bin "${w[i]}" || return 1
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    case "${w[i]}" in
      worktree)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do   # flags, with their values, may sit before the subcommand
          nx="${w[i]%%[\"\';&|)<>]*}"   # rm</dev/null is rm
          case "$nx" in rm|remove|delete) return 0 ;; -*) i=$((i + 1)); case "${w[i]:-}" in ''|-*|rm|remove|delete|create|current|list|ps|set|show) ;; *) i=$((i + 1)) ;; esac ;; *) return 1 ;; esac
        done
        return 1 ;;
      -*) i=$((i + 1)); nx="${w[i]:-}"; case "$nx" in ''|-*|worktree) ;; *) i=$((i + 1)) ;; esac ;;
      *) return 1 ;;
    esac
  done
  return 1
}
# $1 = an ssh command line; prints what follows the host (skipping options and the values of the ones that take
# one), reading words with quote awareness: ssh -o "BatchMode yes" host cmd
ssh_rest() {
  S="$1" awk 'function rd(   c, q, w) {
      while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
      q = ""; w = ""
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (q == "") {
          if (c ~ /[ \t]/) break
          if (c == "\047" || c == "\"") { q = c; pos++; continue }
          if (c == "\\") { pos++; c = substr(s, pos, 1) }
        } else if (c == q) { q = ""; pos++; continue }
        w = w c; pos++
      }
      return w
    }
    BEGIN { s = ENVIRON["S"]; n = length(s); pos = 1; rd()
      while (1) {
        while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
        if (pos > n) exit 1
        w = rd()
        if (w ~ /^-[oipFJLRDbcEelmOQSWwBI]$/) { rd(); continue }
        if (substr(w, 1, 1) == "-") continue
        break
      }
      print substr(s, pos) }'
}
# $( ) and backticks run their body, unless they sit in single quotes or are escaped. The scanner prints each body
# (up to its matching close, quotes kept) on its own line; stdin is one line with newlines mapped to \001.
subst_bodies() {
  awk '{ s = $0; n = length(s); sq = 0; dq = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (sq) { if (c == "\047") sq = 0; continue }
      if (c == "\\") { i++; continue }
      if (c == "\047" && !dq) { sq = 1; continue }
      if (c == "\"") { dq = !dq; continue }
      if ((c == "$" || (!dq && (c == "<" || c == ">"))) && substr(s, i + 1, 1) == "(") {   # $( ) and process substitution <( ) >( )
        depth = 1; bsq = 0; bdq = 0
        for (j = i + 2; j <= n; j++) {
          d = substr(s, j, 1)
          if (bsq) { if (d == "\047") bsq = 0 }
          else if (d == "\\") j++
          else if (d == "\047" && !bdq) bsq = 1
          else if (d == "\"") bdq = !bdq
          else if (bdq) continue   # a parenthesis inside quotes does not nest or close
          else if (d == "(") depth++
          else if (d == ")") { depth--; if (depth == 0) break }
        }
        print substr(s, i + 2, j - i - 2); i = j
      } else if (c == "`") {
        for (j = i + 1; j <= n; j++) { d = substr(s, j, 1); if (d == "\\") j++; else if (d == "`") break }
        print substr(s, i + 1, j - i - 1); i = j
      }
    } }'
}
# $1 = text, $2 = depth. Every body is split and judged like any other command (ssh, cd x && orca ..., wrappers).
subst_wt_rm() {
  local b z
  if [ "${2:-0}" -ge 3 ]; then case "$1" in *worktree*rm*|*worktree*remove*|*worktree*delete*) return 0 ;; esac; return 1; fi   # at the depth cap a removal still in sight is denied
  case "$1" in *'$('*|*'`'*|*'<('*|*'>('*) ;; *) return 1 ;; esac
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    while IFS= read -r z; do [ -n "$z" ] && raw_wt_rm_seg "$z" $(( ${2:-0} + 1 )) && return 0; done < <(printf '%s' "$b" | split_cmd)
  done < <(printf '%s' "$1" | tr '\n' '\001' | subst_bodies)
  return 1
}
# $1 = a command; REPLY = the same command without its leading control words and wrappers (sudo -u x, timeout -k 5 30,
# env -u X, nice -n 5, VAR=x ...). Words are re-joined with single spaces.
unwrap_words() {
  local t="$1" i=0 n x wd; local -a w
  read -ra w <<<"$t"; n=${#w[@]}
  local -a w0=(${w[@]+"${w[@]}"}); w=(); local k=0   # redirections may sit before or between command words: 2>/dev/null orca ..., orca worktree 2>&1 rm
  while [ "$k" -lt "$n" ]; do
    # from a shell / ssh / eval word on, the rest is its quoted payload: a ">/dev/null;" in there must keep its ";"
    wd="${w0[k]//[\"\'\\]/}"; wd="${wd##*/}"
    case "$wd" in ssh|bash|sh|zsh|dash|ksh|ash|eval) while [ "$k" -lt "$n" ]; do w+=("${w0[k]}"); k=$((k + 1)); done; break ;; esac
    case "${w0[k]}" in
      [0-9]|[0-9][0-9]) [ "$k" -gt 0 ] && w+=("${w0[k]}") ;;   # first word only: what is left of 2>&1 once the splitter cut at & (timeout 30 keeps its 30)
      [0-9]*[\<\>]*|[\<\>]*|'&>'*) case "${w0[k]}" in *[\<\>]) k=$((k + 1)) ;; esac ;;   # an operator alone takes the next word as its target
      *[\<\>]*) w+=("${w0[k]%%[<>]*}") ;;   # worktree>/dev/null rm: the word is worktree
      *) w+=("${w0[k]}") ;;
    esac
    k=$((k + 1))
  done
  n=${#w[@]}
  while [ "$i" -lt "$n" ]; do
    wd="${w[i]}"; case "$wd" in */*) case "$wd" in *=*) ;; *) wd="${wd##*/}" ;; esac ;; esac
    case "$wd" in
      nohup|time|command|setsid|stdbuf|watch|xargs|then|do|else|elif|if|while|until|'!'|'{') i=$((i + 1)) ;;
      -u|-g|-h|-p|-C|-D|-R|-T|-U|-k|-s|-n|-S|-I|-L|-E) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      exec|sudo|doas|env|nice|ionice|chrt|flock|taskset|timeout)
        x="$wd"; i=$((i + 1))
        while [ "$i" -lt "$n" ]; do   # the options that take a value differ per wrapper (sudo -n is a switch, nice -n is not)
          case "$x:${w[i]}" in
            sudo:--user|sudo:--group|sudo:--host|sudo:--prompt|exec:-a|taskset:-c|taskset:-p|sudo:-*[ughpCDRTU]|doas:-u|env:-u|env:-C|env:-S|nice:-n|ionice:-[cnpPt]|flock:-w|flock:-E|timeout:-k|timeout:-s) i=$((i + 2)) ;;
            *:-*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        case "$x" in timeout|chrt|flock) i=$((i + 1)) ;; esac ;;
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  REPLY="${w[*]:i}"
}
# $1 = the arguments of ssh (after the host) or of eval; prints what the remote / eval shell receives: each word
# unquoted (one layer), joined with single spaces, local redirections (2>/dev/null, >f) and a trailing # comment dropped.
unquote_args() {
  S="$1" awk 'BEGIN { s = ENVIRON["S"]; n = length(s); pos = 1; out = ""; skip = 0
    while (1) {
      while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
      if (pos > n) break
      first = substr(s, pos, 1); w = ""; q = ""; raw = ""
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (q == "") {
          if (c ~ /[ \t]/) break
          if (c == "\047" || c == "\"") { q = c; pos++; continue }
          if (c == "$" && (substr(s, pos + 1, 1) == "\047" || substr(s, pos + 1, 1) == "\"")) { pos++; continue }   # $'...' and $"..."
          if (c == "\\") { pos++; c = substr(s, pos, 1) }
          raw = raw c
        } else if (c == q) { q = ""; pos++; continue }
        else if (q == "\"" && c == "\\") {
          d = substr(s, pos + 1, 1)
          if (d == "\"" || d == "\\" || d == "$" || d == "`") { c = d; pos++ }
        }
        w = w c; pos++
      }
      if (first == "#") break
      if (skip) { skip = 0; continue }
      if (first ~ /[0-9<>&]/ && raw ~ /^[0-9]*(&>|>>|>&|>|<&|<)/) { if (raw ~ /^[0-9]*(&>|>>|>&|>|<&|<)$/) skip = 1; continue }
      out = out (out == "" ? "" : " ") w
    }
    print out }'
}
# $1 = one segment, $2 = depth. A string handed to ssh / bash / sh / zsh is split again with the same quote-aware
# splitter, so a ; inside a quoted argument (echo "a; orca worktree rm") is not a command boundary.
raw_wt_rm_seg() {
  local s="$1" d="${2:-0}" h pay opay i n x y q mode=; local -a w
  starts_wt_rm "$s" && return 0
  case "$s" in
    find\ *-exec\ *|find\ *-execdir\ *|find\ *-ok\ *) x="$s"   # every -exec / -execdir / -ok action, not only the first: find . -exec echo {} \; -exec orca worktree rm ...
      while [[ "$x" =~ [[:space:]]-(exec|execdir|ok)[[:space:]]+(.*)$ ]]; do
        x="${BASH_REMATCH[2]}"
        starts_wt_rm "$x" && return 0; raw_wt_rm_seg "$x" $((d + 1)) && return 0
      done ;;
  esac
  subst_wt_rm "$s" "$d" && return 0
  if [ "$d" -ge 3 ]; then case "$s" in *worktree*rm*|*worktree*remove*|*worktree*delete*) return 0 ;; esac; return 1; fi
  if [[ "$s" == *'<<<'* ]]; then   # bash <<< "orca worktree rm ...", bash -s <<< ..., ssh host bash -s <<< ...: the string is the script
    x="${s%%<<<*}"; x=" ${x//[\"\']/} "
    if [[ "$x" =~ [[:space:]/](bash|sh|zsh|dash|ksh|ash)[[:space:]] ]]; then
      heavy_n=$((heavy_n + 1))
      pay="$(unquote_args "${s#*<<<}")"
      while IFS= read -r x; do
        [ -n "$x" ] || continue
        raw_wt_rm_seg "$x" $((d + 1)) && return 0
      done < <(printf '%s' "$pay" | tr '\n' '\001' | split_cmd)
    fi
  fi
  unwrap_words "$s"; s="$REPLY"   # a nested piece keeps its leading space, control words and wrappers: "  then sudo -u x bash -c ..."
  h="${s%% *}"; h="${h//[\"\'\\]/}"; h="${h##*/}"   # "bash" -c is bash -c
  case "$h" in ssh|bash|sh|zsh|dash|ksh|ash|eval) ;; *) return 1 ;; esac
  heavy_n=$((heavy_n + 1))
  pay=""
  if [ "$h" = ssh ]; then
    pay="$(ssh_rest "$s")" || return 1   # everything after the host
    pay="$(unquote_args "$pay")"; mode=args
  elif [ "$h" = eval ]; then
    pay="$(unquote_args "${s#eval}")"; mode=args   # eval runs its arguments as shell source
  elif [[ "$s" =~ (^|[[:space:]])-[A-Za-z]*c[A-Za-z]*[[:space:]]+(.*)$ ]]; then
    pay="${BASH_REMATCH[2]}"
    case "$pay" in '$'\'*|'$"'*) pay="${pay:1}" ;; esac   # bash -c $'...': plain text decodes the same; \n and \x escapes are a known limit
    # bash -c '<command>' [name [args]]: the command is the first word only, the rest are positional arguments
    q="${pay:0:1}"
    if [ "$q" = "'" ] || [ "$q" = '"' ]; then
      x=""; i=1; n=${#pay}; opay="$pay"
      while [ "$i" -lt "$n" ]; do
        y="${pay:i:1}"
        if [ "$q" = '"' ] && [ "$y" = "\\" ]; then x="$x$y${pay:i+1:1}"; i=$((i + 2)); continue; fi
        [ "$y" = "$q" ] && break
        x="$x$y"; i=$((i + 1))
      done
      if [ "$i" -lt "$n" ] && [ -n "${opay:i+1:1}" ] && [[ "${opay:i+1:1}" != [[:space:]] ]]; then
        pay="$(unquote_args "$opay")"; mode=args   # "orca"" worktree rm": adjacent quoted fragments are ONE word, so read the payload as words
      else
        pay="$q$x$q"
      fi
    fi
  else
    return 1
  fi
  # bash -c: the payload is one quoted string, or plain words (ssh and eval arguments are already unquoted)
  pay="${pay#"${pay%%[![:space:]]*}"}"
  q="${pay:0:1}"
  pay="${pay%"${pay##*[![:space:]]}"}"
  [ "$mode" = args ] && q=""
  case "$q" in
    \"|\')
      # enclosed only when ONE quoted string is the whole payload; otherwise (ssh host "orca" worktree rm) it is words
      x="${pay:1:${#pay}-2}"; y="$x"; [ "$q" = '"' ] && y="${y//\\\"/}"
      if [ "${#pay}" -ge 2 ] && [ "${pay: -1}" = "$q" ] && [ "${y#*"$q"}" = "$y" ]; then
        # inside double quotes the outer shell turns \" into " and \\ into \, so decode before the next scan
        [ "$q" = '"' ] && { x="${x//\\\"/\"}"; x="${x//\\\\/\\}"; x="${x//\\\$/\$}"; x="${x//\\\`/\`}"; }
        pay="$x"
      fi ;;
  esac
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    raw_wt_rm_seg "$x" $((d + 1)) && return 0
    case "$x" in *'\$('*) ;; *'$('*) starts_wt_rm "${x#*\$(}" && return 0 ;; esac   # \$( is text, $( runs
  done < <(printf '%s' "$pay" | tr '\n' '\001' | split_cmd)
  return 1
}

# count the pieces that will cost forks (ssh / shell / eval / here-string / substitution) with no fork at all, and refuse a command with
# more than 20 of them before reading any: on a loaded box 60 took 8 s, and the hook timeout is 5 s
heavy_pre=0; wt_pre=0; p_dol='$('; p_bt='`'; p_ps='<('
while IFS= read -r seg; do
  case "$seg" in *worktree*) ;; *) continue ;; esac
  wt_pre=$((wt_pre + 1))
  h=0; case "$seg" in *ssh*|*bash*|*zsh*|*dash*|*ksh*|*eval*|*' sh '*|*'<<<'*) h=1 ;; esac
  # every $( , backtick pair and <( costs a fork-heavy nested read, however many sit in one piece
  t="${seg//"$p_dol"/}"; nsub=$(((${#seg} - ${#t}) / 2))
  t="${seg//"$p_bt"/}"; nsub=$((nsub + (${#seg} - ${#t} + 1) / 2))
  t="${seg//"$p_ps"/}"; nsub=$((nsub + (${#seg} - ${#t}) / 2))
  heavy_pre=$((heavy_pre + h + nsub))
done <<<"$segs"
if [ "$heavy_pre" -gt 20 ]; then over=heavy; elif [ "$wt_pre" -gt 500 ]; then over=pieces; fi
# a first, cheap pass for the orca rule: pure bash, no forks, so a long chain of rm commands in front cannot push
# the removal past the hook timeout
while [ -z "$over" ] && IFS= read -r seg; do
  case "$seg" in *worktree*) ;; *) continue ;; esac
  if raw_wt_rm_seg "$seg" || subst_wt_rm "$seg" 0; then rawwt="$seg"; break; fi
  # each ssh / shell piece costs forks (35 s for 300 of them, 8 s for 60 on a loaded box); past the hook timeout a command is allowed, so refuse it
  if [ "$heavy_n" -gt 20 ]; then over=1; break; fi
done <<<"$segs"
heavy_n=0
if [ -z "$rawwt" ] && [ -z "$over" ]; then
while IFS= read -r seg; do
  case "$seg" in *rm*|*worktree*) ;; *) continue ;; esac   # nothing to judge, and the wrapper strip below forks sed
  seg0="$seg"   # before the wrapper strip: x=`orca ...` must not lose its backtick body to the VAR=x strip
  # 3. strip leading wrappers until stable. Only a segment that starts with something strippable is worth the
  #    sed forks: a plain `rm -f x` or `echo y` is judged as it is (1,500 of them took minutes otherwise)
  seg="${seg#"${seg%%[![:space:]]*}"}"
  seg0t="${seg//$'\t'/ }"; case "$seg0t" in /bin/rm\ *|/usr/bin/rm\ *) seg="$seg0t" ;; esac   # /usr/bin/rm<TAB>-rf: the path match below needs a space
  case "$seg" in
    [A-Za-z_]*=*|then*|do*|else*|elif*|if*|while*|until*|'!'*|'{'*|'('*|sudo*|exec*|command*|builtin*|nohup*|time*|env*|nice*|xargs*|eval*|-*|/*|\\*)
      prev=""; n=0
      while [ "$seg" != "$prev" ] && [ "$n" -lt 8 ]; do
        prev="$seg"; n=$((n + 1))
        seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^(then|do|else|elif|if|while|until|!|\{|\(|sudo|exec|command|builtin|nohup|time|env|nice)([[:space:]]+|$)//; s/^timeout[[:space:]]+[0-9.]+[smhd]?[[:space:]]+//; s/^-[A-Za-z0-9-]+[[:space:]]+[0-9]+[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//; s/^xargs[[:space:]]+//; s/^-[A-Za-z0-9-]+(\{\})?([[:space:]]+[0-9{}][^[:space:]]*)?[[:space:]]+//; s/^\(+//')"
        seg="$(printf '%s' "$seg" | sed -E "s/^eval[[:space:]]+[\"']?//")"
      done
      case "$seg" in /bin/rm\ *|/usr/bin/rm\ *) seg="rm ${seg#* }" ;; /bin/rm|/usr/bin/rm) seg="rm" ;; \\rm\ *) seg="rm ${seg#* }" ;; \\rm) seg="rm" ;; esac ;;
  esac
  seg="${seg//$'\t'/ }"
  # raw orca worktree removal: the segment IS the command, or an ssh / shell / eval string holds it
  if raw_wt_rm_seg "$seg" || raw_wt_rm_seg "$seg0" || subst_wt_rm "$seg0" 0; then rawwt="$seg0"; break; fi
  if [ "$heavy_n" -gt 20 ]; then over=1; break; fi
  [ "$in_scope" = 1 ] || continue
  case "$seg" in rm|rm\ *) ;; *) continue ;; esac
  risky=0
  # recursive is the risky flag; a lone -f on a plain path is not (the built-in check is about empty-variable trees)
  if [[ " $seg " =~ [[:space:]]-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]] ]] || [[ " $seg " == *" --recursive"* ]]; then risky=1; fi
  case "$seg" in *'*'*) risky=1 ;; esac
  [ "$risky" = 1 ] || continue
  case "$seg" in *'$'*) ;; *) continue ;; esac   # no expansion, nothing to be unguarded
  # Each one costs forks. A command with more than 60 of them would outlast the 5 s hook timeout, and a timed-out
  # hook allows the command, so refuse it instead (the orca check above already ran on every piece).
  rm_n=$((rm_n + 1))
  if [ "$rm_n" -gt 60 ]; then bad="(more than 60 recursive rm commands with expansions in one command: split it) $seg"; break; fi
  # drop guarded expansions, then any remaining $VAR / ${VAR...} / $( is unguarded
  stripped="$(printf '%s' "$seg" | sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}//g')"
  if printf '%s' "$stripped" | grep -qE '\$([A-Za-z_{(]|[0-9@*])'; then bad="$seg"; break; fi
done <<<"$segs"
fi

if [ -n "$over" ]; then
  if [ "$over" = pieces ]; then what="More than 500 command pieces naming worktree"; else what="More than 20 ssh / shell commands or substitutions"; fi
  reason="$what in one Bash command: the guard cannot read them all inside the hook timeout, and a timed-out hook allows the command. Split it into several commands. Raw orca worktree removal goes through the concertmaster skill: scripts/teardown.sh <host> <worktree-path>."
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi
if [ -n "$rawwt" ]; then
  reason="Raw orca worktree removal skips the teardown gates (beads, open follow-ups, salvage, parent and child worktrees). Run the sanctioned path instead: the concertmaster skill scripts/teardown.sh <host> <worktree-path> (dry run), then --apply --salvage; on a remote host run salv3.sh first. Command was: $rawwt"
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi
[ -n "$bad" ] || exit 0
reason="rm -r/-R/glob with an unguarded variable path may stop on an approval prompt nobody answers. Guard EVERY variable: rm -rf \"\${S:?}\"/name, and for a computed name assign it first (n=\$(...); rm -rf \"\${S:?}\"/\"\${n:?}\"). Or use the literal path. Command was: $bad"
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
