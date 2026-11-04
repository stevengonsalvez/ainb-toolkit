#!/usr/bin/env bash
# abrupt.sh: list in-scope sessions that were cut off by a restart: background
# work that "didn't finish before the previous session ended", a stale /loop
# resume line with no tick after it, or an agent terminal that fell back to a
# shell. Also flags two live claude processes in one worktree (one
# conversation forked by a resume): a pid counts only when it is a real claude agent
# (lib.sh cm_claude_pids: argv[0] basename claude, so Claude Code's embedded ugrep/bfs helper is not one)
# and alive in two samples CM_ABRUPT_RESAMPLE seconds apart (default 3, 0 = one sample), `claude -p`
# ignored.
#
#   scripts/abrupt.sh        # TSV: host  orca-session-name  handle  reason
#                            # a DUPLICATE row is followed by one `DUPLICATE detail:` evidence row per pid
#
# Scope: worktree paths matching config worktrees.path_match (CM_PATH_MATCH,
# an extended regex such as "/acme/"). It never sends or closes; its one write is the
# DUPLICATE evidence log $CM_HOME/abrupt-duplicates.log (best effort, only when a duplicate is flagged).
# Run it every tick; nudge or resume what it lists (SKILL.md § Stuck rule,
# § Resume), never while resume.lock exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/secret-shape.sh
. "$HERE/secret-shape.sh"
[ -n "$CM_PATH_MATCH" ] || { cm_warn "abrupt.sh: set worktrees.path_match in config (or CM_PATH_MATCH)"; exit 2; }
ORCA="$(cm_orca)"
# Remote Orca JSON can carry lone UTF-16 surrogates and raw control characters that make
# jq fail and silently hide the session: sanitize before jq, flatten pane text with jstrings.
SAN="$HERE/jsanitize"; STR="$HERE/jstrings"
export ORCA SAN STR CM_PATH_MATCH

# CM_PROC_ROOT replaces /proc (tests only, it needs CM_TEST=1)
PROC=/proc
if [ -n "${CM_PROC_ROOT:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then PROC="$CM_PROC_ROOT"; else cm_warn "abrupt.sh: CM_PROC_ROOT ignored (it needs CM_TEST=1)"; fi
fi

scan() {
  local host=$1; shift
  local names; names=$("$ORCA" worktree ps "$@" --json 2>/dev/null </dev/null | "$SAN" | jq -c '[.result.worktrees[]? | {key:.path, value:(.displayName // (.path|split("/")|last))}] | from_entries')
  "$ORCA" terminal list "$@" --json 2>/dev/null </dev/null | "$SAN" \
    | jq -r --arg re "$CM_PATH_MATCH" '.result.terminals[]? | select((.worktreePath//"")|test($re)) | "\(.handle)\t\(.worktreePath)\t\(.agentIdentity // "")"' \
    | while IFS=$'\t' read -r h wt agent; do
        s=$("$ORCA" terminal read --terminal "$h" "$@" --json 2>/dev/null </dev/null | "$STR" | grep -v '^\s*$' | tail -40)
        name=$(jq -r --arg p "$wt" '.[$p] // ($p|split("/")|last)' <<<"$names")
        r=""
        grep -qE "didn't finish before the previous session ended" <<<"$s" && r="background work cut off by restart"
        if [ -z "$r" ] && grep -qE 'Claude resuming /loop wakeup' <<<"$s" && ! grep -qE '✻ .*· done' <<<"$(grep -A50 'Claude resuming /loop wakeup' <<<"$s" | tail -n +2)" && ! grep -qE '… \(|esc to interrupt' <<<"$(tail -12 <<<"$s")"; then r="loop resume pending"; fi
        # A worktree can hold a shell tab next to the live agent tab; only call it
        # "agent gone" when no claude process (local scan) has its cwd in the worktree.
        if [ -z "$r" ] && [ "$agent" = "claude" ] && ! grep -qE 'bypass permissions|ctx \[|✻|esc to interrupt' <<<"$s" && grep -qE '❯\s*$' <<<"$s"; then
          live=0
          if [ "$host" = local ]; then
            for p in $(cm_claude_pids "$PROC"); do [ "$(readlink "$PROC/$p/cwd" 2>/dev/null)" = "$wt" ] && { live=1; break; }; done
          fi
          [ $live -eq 0 ] && r="agent gone, bare shell"
        fi
        [ -n "$r" ] && printf '%s\t%s\t%s\t%s\n' "$host" "$name" "$h" "$r"
      done
}

scan local
for e in $("$ORCA" host list --json 2>/dev/null </dev/null | "$SAN" | jq -r '.result.hosts[]? | select(.name!="this machine") | .name'); do
  cm_timeout 90 bash -c "$(declare -f scan); scan \"\$1\" --environment \"\$1\"" _ "$e" 2>/dev/null
done

# Duplicate live claude agents in one worktree (Linux /proc; local host only).
# One pgrep sample is not enough: a hook or a `claude -p` child lives a few seconds and made a
# false DUPLICATE alarm more than once. A pid counts only when it is alive, with the same cwd,
# in two samples CM_ABRUPT_RESAMPLE seconds apart (default 3, under 10; 0 = one sample, the old
# behaviour; the wait and second sample run only when the first holds a shared cwd),
# and a headless one-shot (`claude -p`, `claude --print`) is never counted. A worktree is reported
# only when two or more counted pids share its cwd. CM_PROC_ROOT replaces /proc (tests only, it
# needs CM_TEST=1).
export LC_ALL=C   # sort, comm and uniq must agree on one byte order
RESAMPLE="${CM_ABRUPT_RESAMPLE:-3}"
case "$RESAMPLE" in ''|*[!0-9.]*|*.*.*|.|[1-9][0-9]|[1-9][0-9][0-9.]*|[0-9][0-9][0-9]*)   # a bad value or 10+ seconds (a stalled tick) is the default, said on stderr
    [ -z "${CM_ABRUPT_RESAMPLE:-}" ] || cm_warn "abrupt.sh: CM_ABRUPT_RESAMPLE='$CM_ABRUPT_RESAMPLE' is not a wait under 10 seconds: using 3"
    RESAMPLE=3 ;;
esac

# claude_samples: one line per counted pid, "pid<TAB>cwd", sorted. Skips a pid with no readable cwd
# (it exited) and a headless one-shot (-p, --print or --print=... among its arguments).
claude_samples() {
  local p cwd arg headless
  for p in $(cm_claude_pids "$PROC"); do
    headless=0
    # the group, not the redirect, carries 2>/dev/null: a pid that exits between pgrep and this
    # read must not leak "No such file or directory" into the tick output
    { while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        case "$arg" in -p|--print|--print=*) headless=1; break ;; esac
      done < "$PROC/$p/cmdline"; } 2>/dev/null
    [ $headless -eq 1 ] && continue
    cwd=$(readlink "$PROC/$p/cwd" 2>/dev/null) || continue
    [ -n "$cwd" ] && printf '%s\t%s\n' "$p" "$cwd"
  done | sort
}

# Evidence for a recurring false DUPLICATE (the row still fired after the one-shot filter, and the second pid was
# gone a minute later, so it is not a short one-shot and its spawner is unknown). Counting rules are NOT changed
# here. For every pid in a DUPLICATE row, read at flag time: ppid, parent and grandparent (pid, comm,
# cmdline), age (ps etimes), controlling tty and its own cmdline. Control characters are stripped (a tab
# would break the TSV) and each cmdline is cut to 200 characters. Printed as one `DUPLICATE detail:` row per
# pid after the unchanged DUPLICATE row, and appended with a UTC timestamp to $CM_HOME/abrupt-duplicates.log
# (best effort, never fatal, owner-only, kept under ~200 KB by dropping the oldest lines).
DUP_LOG_MAX=204800   # bytes; past this the oldest lines go
DUP_LOG_KEEP=153600  # bytes kept after a trim

# redact_argv <pid>: the argv of a pid joined by spaces, with whole arguments redacted where the argv
# boundaries still exist (they are lost once the NULs become spaces): the argument after a flag named like
# --token, --password, --api-key, --auth-token, -u or --user (a value with spaces stays whole), the value of
# NAME=value or --flag=value when the name ends in key, token, secret, password, pass, cred or auth and the
# argument has no space, and a header argument that starts with Authorization:, X-Api-Key: and the like.
redact_argv() {
  local a red=0 out="" nc
  nc=$(shopt -p nocasematch); shopt -s nocasematch
  { while IFS= read -r -d '' a || [ -n "$a" ]; do
      if [ $red -eq 1 ]; then a="<redacted>"; red=0
      elif [[ $a =~ ^(-u|--user|--?[A-Za-z_-]*(token|password|passwd|secret|key|auth|cred))$ ]]; then
        # --no-auth, --skip-key and the like are switches: keep the next argument (the spawner). The marker
        # -~- hides the switch from the word level rules below; it is turned back into -- at the end.
        if [[ $a == --no-* || $a == --skip-* || $a == --bypass-* || $a == --disable-* ]]; then a="-~-${a#--}"; else red=1; fi
      elif [[ $a != *" "* && $a =~ ^([A-Za-z0-9_-]*(key|token|secret|password|passwd|pass|cred|auth))=.* ]]; then a="${BASH_REMATCH[1]}=<redacted>"
      elif [[ $a =~ ^([A-Za-z-]*(authorization|token|password|secret|key|auth|cred)):[[:space:]]*.+ ]]; then a="${BASH_REMATCH[1]}: <redacted>"
      fi
      out+="${out:+ }$a"
    done < "$PROC/$1/cmdline"; } 2>/dev/null
  eval "$nc"
  printf '%s' "$out"
}
# proc_cmd <pid>: the cmdline of a pid as one line, NULs as spaces, control characters dropped, secrets
# redacted, cut to 200 chars. A secret often sits early in an argv (an env prefix on bash -lc, a --token
# flag), so redaction runs on the whole line before the cut: NAME=value where NAME holds KEY, TOKEN,
# SECRET, PASS, CRED or AUTH, the value after any flag named like --token, --password, --api-key or --auth-token,
# a Bearer/Basic/Authorization value, and the whole line when it holds a named credential shape (a URL with
# user:pass@ included; scripts/secret-shape.sh, the shared predicate). Best effort, not a guarantee.
proc_cmd() {
  local c q="'" val
  val="(${q}[^${q}]*${q}|\"[^\"]*\"|${q}[^${q}]*$|\"[^\"]*$|[^ ]*)"   # a quoted value (to the end of the line when the quote never closes) or one word
  c=$({ redact_argv "$1" | tr -d '[:cntrl:]' | tr -c '\040-\176' '?' \
        | sed -E -e "s/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASS|PASSWORD|PASSWD|CRED|AUTH)=)$val/\\1<redacted>/gI" \
                 -e "s/((^| )--?[A-Za-z_-]*(token|password|passwd|secret|key|auth|cred)[= ])$val/\\1<redacted>/gI" \
                 -e "s/(([A-Za-z]+-)*(token|password|passwd|secret|key|auth|cred):[ ]*)$val/\\1<redacted>/gI" \
                 -e "s/((^| )(-u|--user)[= ])$val/\\1<redacted>/gI" \
                 -e "s/((^| )Bearer[ =]+)$val/\\1<redacted>/gI" \
                 -e "s/((^| )Basic[ =]+)[A-Za-z0-9+\/=._-]{8,}/\\1<redacted>/gI" \
                 -e "s/(Authorization[: =]+)$val/\\1<redacted>/gI" -e 's/-~-/--/g'; } 2>/dev/null)
  if secret_shaped_prefix "$c"; then
    # redact the token that carries the shape and keep the rest (the spawner is what the row is for);
    # blank the line only when a shape survives that
    c=$(printf '%s' "$c" | sed -E "s#($_SS_PREFIX)[A-Za-z0-9_.+/=-]*#<redacted>#g" 2>/dev/null)   # # not /: the URL shape holds slashes
    if [ -z "$c" ] || secret_shaped_prefix "$c"; then printf '[redacted: credential shape]'; return 0; fi
  fi
  printf '%s' "$c" | cut -c1-200 | sed 's/ *$//'
}
# proc_status <pid> <key>: one field of status (Name, PPid).
proc_status() {
  { sed -n "s/^$2:[[:space:]]*//p" "$PROC/$1/status" | head -n 1 | tr -d '[:cntrl:]'; } 2>/dev/null
}
# proc_ppid <pid>: the parent pid, from status, else from stat (the fields after the last ") ").
proc_ppid() {
  local pp; pp=$(proc_status "$1" PPid)
  [ -n "$pp" ] || pp=$({ sed 's/^.*) //' "$PROC/$1/stat" | awk '{ print $2 }'; } 2>/dev/null)
  case "$pp" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pp"
}
# proc_tty <pid>: "set:<tty_nr>[/<name>]" when the process has a controlling terminal (the name, such as
# pts/3, from ps when it has one), "none" when tty_nr is 0.
proc_tty() {
  local t n; t=$({ sed 's/^.*) //' "$PROC/$1/stat" | awk '{ print $5 }'; } 2>/dev/null)
  case "$t" in
    ''|*[!0-9]*) printf '?' ;;
    0) printf 'none' ;;
    *) n=$({ ps -o tty= -p "$1" | tr -d '[:space:]'; } 2>/dev/null)
       case "$n" in ''|'?'|'-') printf 'set:%s' "$t" ;; *) printf 'set:%s/%s' "$t" "$n" ;; esac ;;
  esac
}
# proc_ident <pid>: "pid:comm:cmdline", or "pid:gone" when /proc has no entry for it.
proc_ident() {
  [ -n "$1" ] && [ -d "$PROC/$1" ] || { printf '%s:gone' "${1:-?}"; return 0; }
  printf '%s:%s:%s' "$1" "$(proc_status "$1" Name)" "$(proc_cmd "$1")"
}
# dup_detail <pid> <worktree>: the detail text for one flagged pid. wt=[path] is last: the DUPLICATE row
# names the worktree by basename only, so two worktrees with one leaf name need the full path to tell apart.
dup_detail() {
  local pid=$1 wt pp gp age
  wt=$(printf '%s' "$2" | tr -d '[:cntrl:]')
  [ -d "$PROC/$pid" ] || { printf 'pid=%s gone=1 wt=[%s]' "$pid" "$wt"; return 0; }
  pp=$(proc_ppid "$pid") || pp=""
  gp=""; [ -n "$pp" ] && [ -d "$PROC/$pp" ] && gp=$(proc_ppid "$pp")
  age=$({ ps -o etimes= -p "$pid" | tr -d '[:space:]'; } 2>/dev/null)
  printf 'pid=%s ppid=%s age=%ss tty=%s comm=[%s] cmd=[%s] parent=[%s] grandparent=[%s] wt=[%s]' \
    "$pid" "${pp:-?}" "${age:-?}" "$(proc_tty "$pid")" "$(proc_status "$pid" Name)" "$(proc_cmd "$pid")" \
    "$(proc_ident "$pp")" "$(proc_ident "$gp")" "$wt"
}
# dup_log <host> <worktree> <detail>...: append one timestamped line per detail to the evidence log, for a
# pid not logged yet (a pair that persists for hours would otherwise fill the cap with repeats and push out
# the first sighting, which holds the evidence). A pid counts as logged when the log holds its "pid=N ppid=M"
# for this worktree. Best effort: any failure is swallowed. The file is created 0600 and never followed
# through a symlink.
dup_log() {
  local f="$CM_HOME/abrupt-duplicates.log" ts line key wt sz tmp new=()
  {
    [ -L "$f" ] && return 0
    ( umask 077; mkdir -p "$CM_HOME" ) && [ -d "$CM_HOME" ] || return 0
    wt=$(printf '%s' "$2" | tr -d '[:cntrl:]')
    for line in "${@:3}"; do
      case "$line" in
        *" age="*) key="${line%% age=*} age=" ;;   # pid and ppid identify the sighting, not its age
        *)         key="$line" ;;                  # a gone pid has no age: the whole line is the key
      esac
      if [ -f "$f" ] && grep -F -- "$key" "$f" | grep -qF -- "wt=[$wt]"; then continue; fi
      new+=("$line")
    done
    [ "${#new[@]}" -gt 0 ] || return 0
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ( umask 077; for line in "${new[@]}"; do printf '%s\t%s\t%s\t%s\n' "$ts" "$1" "$wt" "$line"; done >> "$f" )
    chmod 600 "$f"
    sz=$(wc -c < "$f" | tr -d '[:space:]')
    if [ "${sz:-0}" -gt "$DUP_LOG_MAX" ]; then
      # tail -c may cut the first line mid-way: drop that partial line. Rewritten in place (no temp
      # file to leak); the empty-result guard keeps a failed read from truncating the log to nothing.
      tmp=$(tail -c "$DUP_LOG_KEEP" "$f" | sed 1d)
      [ -n "$tmp" ] && printf '%s\n' "$tmp" > "$f"
    fi
  } 2>/dev/null
  return 0
}

first=$(claude_samples)
# The wait and the second sample run only when the first sample holds an in-scope cwd (path_match)
# shared by two pids (almost never): an ordinary tick pays no delay and no snapshot. A zero wait (0, 00, 0.0) is one sample.
# shared_cwds <samples>: in-scope cwds held by two or more pids in one sample.
shared_cwds() { printf '%s\n' "$1" | awk -F'\t' 'NF == 2 { print $2 }' | grep -E "$CM_PATH_MATCH" | sort | uniq -d; }
# snapshot <samples> <shared cwds>: "pid<TAB>detail" for every pid of the samples whose cwd is shared.
snapshot() {
  printf '%s\n' "$1" | while IFS=$'\t' read -r p c; do
    [ -n "$p" ] && grep -qxF -- "$c" <<<"$2" && printf '%s\t%s\n' "$p" "$(dup_detail "$p" "$c")"
  done
}
shared=""
[ -n "${RESAMPLE//[0.]/}" ] && shared=$(shared_cwds "$first")
snap=""
if [ -n "$shared" ]; then
  # Evidence first: read every candidate pid now, before the wait, and again right after the second
  # sample (a pid that only shows up in the second sample has no first snapshot). A pid that is gone by
  # flag time (the recurring case: it lived past the resample, then exited) still leaves its parent chain in
  # the report. Later snapshot lines come first: the flag loop takes the first line of a pid.
  snap=$(snapshot "$first" "$shared")
  sleep "$RESAMPLE"
  second=$(claude_samples)
  snap="$(snapshot "$second" "$(shared_cwds "$second")")"$'\n'"$snap"
  agents=$(comm -12 <(printf '%s\n' "$first") <(printf '%s\n' "$second"))
else
  agents="$first"
fi

printf '%s\n' "$agents" | awk -F'\t' 'NF == 2 { print $2 }' | grep -E "$CM_PATH_MATCH" | sort | uniq -d \
  | while IFS= read -r d; do
      pids=$(printf '%s\n' "$agents" | D="$d" awk -F'\t' '$2 == ENVIRON["D"] { print $1 }' | sort -n)
      name=$(basename "$d")
      # the path goes in through ENVIRON: awk -v would turn a backslash in it into an escape
      printf 'local\t%s\t-\tDUPLICATE live agents: %s\n' "$name" "$(paste -sd' ' - <<<"$pids")"
      details=()
      for p in $pids; do
        det=$(dup_detail "$p" "$d")
        case "$det" in
          "pid=$p gone=1 "*)   # exited between the samples and now: report what a sample saw
            old=$(awk -F'\t' -v p="$p" '$1 == p && $2 !~ /^pid=[0-9]+ gone=1 / { print $2; exit }' <<<"$snap")
            [ -n "$old" ] && det="$old exited-before-flag=1" ;;
        esac
        details+=("$det")
      done
      for x in "${details[@]}"; do printf 'local\t%s\t-\tDUPLICATE detail: %s\n' "$name" "$x"; done
      dup_log local "$d" "${details[@]/#/DUPLICATE detail: }"
    done
