#!/usr/bin/env bash
# handoff.sh: cross-host handoff helpers (SKILL.md hard rule 24, § Spawn recipe).
#
#   scripts/handoff.sh share <file.md|file.html> [--environment <sel>] [--allow <ERE>] [--no-check] [--no-secret-scan]
#       Share the file through Orca (`artifacts share <file> --json`) and print the link on stdout,
#       and nothing else there. A lane on another host cannot open a path on this host, so a plan,
#       a spec or evidence it must read goes as a link. Exit 1, with one clear line on stderr, when
#       the file is missing or is not .md/.html, the CLI fails or refuses, or the reply holds no link.
#       Only the CLI's own error message is echoed on failure, never the reply body (it may carry a
#       token). --environment picks the saved Orca server to share through. The file is first linted
#       like a brief (`check`), because its reader is on another host too: --allow <ERE> passes a
#       path that is remote on purpose (matched against the flagged text), --no-check skips the path lint, and a
#       secret scan (scan-secrets.sh) refuses a secret-shaped string, strict and advisory classes alike, unless --no-secret-scan.
#
#   scripts/handoff.sh check <file|-> [--target remote|local] [--allow <ERE>]
#       Lint text (a brief, a nudge, a comment; `-` is stdin) for host-local references that a
#       reader on another host cannot open: ~/.concertmaster, $CM_HOME, the configured state_dir,
#       /home/<user>/ and /Users/<user>/. Exit 0 clean, exit 1 listing each hit as
#       `line N: <pattern>: <text>`, exit 2 on usage or an unreadable file. --target local (the
#       brief goes to a worktree on this host) skips the check; the default is remote.
#       --allow <ERE> (repeatable) skips a hit whose line matches, for a path that is remote on
#       purpose (a CI runner path in a quoted log); it is an unanchored ERE matched against the flagged text (the
#       reference plus one boundary character), not the whole line, so a second host-local path on the
#       same line is still reported.
#
# The inbox and $CM_HOME stay local to the concertmaster's host by design: never tell a lane to
# read them. Durable content (plans, specs, evidence kept after the task) goes to a GitHub issue
# or Discussion instead of a shared file. Every Orca call goes through cm_orca, under cm_timeout.
# Env: CM_HOME, CM_CONFIG, ORCA_CLI_COMMAND, CM_HANDOFF_TIMEOUT (seconds for the CLI, default 60).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2; }
die() { printf 'handoff: %s\n' "$*" >&2; exit 1; }

cmd_share() {
  local file="" env_sel="" lower all json rc msg link orca nocheck=0 noscan=0 crc src_rc scan_err
  local -a allow_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --environment) [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }; env_sel="$2"; shift 2 ;;
      --environment=*) env_sel="${1#--environment=}"; [ -n "$env_sel" ] || { usage; exit 2; }; shift ;;
      --allow) [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
               printf '' | grep -qE -- "$2"; [ "$?" -ne 2 ] || { printf 'handoff: share: --allow %s is not a valid ERE\n' "$2" >&2; exit 2; }
               allow_args+=(--allow "$2"); shift 2 ;;
      --no-check) nocheck=1; shift ;;
      --no-secret-scan) noscan=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; [ $# -eq 1 ] && [ -z "$file" ] || { usage; exit 2; }; file="$1"; shift ;;
      -*) usage; exit 2 ;;
      *) [ -z "$file" ] || { usage; exit 2; }; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || { usage; exit 2; }
  [ -f "$file" ] || die "share: $file is not a file"
  lower="$(cm_lower "$file")"
  case "$lower" in
    *.md|*.html) ;;
    *) die "share: $file is not .md or .html (Orca shares only those two)" ;;
  esac

  # The shared file is read by a remote reader too: it gets the same host-local lint as a brief.
  if [ "$nocheck" -eq 0 ]; then
    bash "$HERE/handoff.sh" check ${allow_args[@]+"${allow_args[@]}"} -- "$file" >&2; crc=$?
    case "$crc" in
      0) ;;
      1) die "share: $file holds host-local references (listed above); fix them, pass --allow <ERE> (matches the flagged text), or --no-check" ;;
      *) die "share: the host-local check could not run on $file (exit $crc)" ;;
    esac
  fi
  # ...and the secret scan the skill already ships (counts only, never the matched text). Its own opt-out.
  if [ "$noscan" -eq 0 ]; then
    scan_err="$(bash "$HERE/scan-secrets.sh" --strict "$(case "$file" in -*) printf './%s' "$file" ;; *) printf '%s' "$file" ;; esac)" 2>&1 >/dev/null)"; src_rc=$?
    case "$src_rc" in
      0) ;;
      1) die "share: $file holds secret-shaped strings (scripts/scan-secrets.sh $file shows the counts); remove them or pass --no-secret-scan" ;;
      *) die "share: the secret scan could not run on $file (exit $src_rc${scan_err:+: $(printf '%s' "$scan_err" | head -c 200 | tr '\n' ' ')}); fix that, do not bypass it" ;;
    esac
  fi
  orca="$(cm_orca)"
  local -a args=(artifacts share "$(case "$file" in -*) printf './%s' "$file" ;; *) printf '%s' "$file" ;; esac)" --json)
  [ -z "$env_sel" ] || args+=(--environment "$env_sel")
  # stdout only, no temp file: stderr is dropped (it could carry a token, and a warning there could
  # break the parse). The JSON object is cut out of stdout from its first line that starts with `{`.
  all="$(cm_timeout "${CM_HANDOFF_TIMEOUT:-60}" "$orca" "${args[@]}" </dev/null 2>/dev/null)"; rc=$?
  # first object only: from a line starting with `{` to its end (same line, or the next line that is `}`)
  json="$(printf '%s\n' "$all" | awk '/^\{/ && !s { s = 1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next } s { print; if ($0 ~ /^\}/) exit }')"

  # The CLI prints its refusal as JSON with exit 1: take the message from there, else the raw text.
  # A message that looks like it carries a secret (lib.sh cm_text_looks_secret) is withheld.
  msg="$(printf '%s' "$json" | jq -r '(.error | if type == "object" then .message else . end)? // .message? // empty | strings' 2>/dev/null | head -c 300)"
  if [ -z "$msg" ] && ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    msg="output withheld (not JSON)"   # raw text could carry a token
  fi
  if [ -n "$msg" ] && printf '%s' "$msg" | cm_text_looks_secret; then msg="message withheld (secret-shaped)"; fi
  [ "$rc" -eq 0 ] || die "share: the Orca CLI failed (exit $rc)${msg:+: $msg}"
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || die "share: the Orca CLI reply was not JSON"
  if [ "$(printf '%s' "$json" | jq -r 'if .ok == false then "false" else "true" end' 2>/dev/null)" = false ]; then
    die "share: the Orca CLI refused${msg:+: $msg}"
  fi
  # The link: the first http(s) value of result.url, .link, .shareUrl, .publicUrl or the same under
  # result.artifact. Named fields only: a docs or warning URL elsewhere in the reply is never taken, and
  # an unknown shape fails loudly ("held no link") instead of printing a wrong link. The reply is never
  # printed, only the one link that is picked.
  link="$(printf '%s' "$json" | jq -r '
      def web: select(type == "string" and test("^https?://[^[:space:]]+$")
                      and (test("^https?://(localhost|127\\.|0\\.0\\.0\\.0|\\[::1\\]|10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)"; "i") | not));
      def pick: if type == "string" then web
                elif type == "object" then ([.url?, .link?, .shareUrl?, .publicUrl?, .artifact?.url?, .artifact?.link?, .artifact?.shareUrl?] | map(web) | first)
                else null end;
      [(.result? | pick), pick] | map(select(. != null)) | first // empty' 2>/dev/null | head -n 1)"
  [ -n "$link" ] || die "share: the Orca CLI reply held no link (the share may exist: check \`artifacts list\` before retrying)"
  printf '%s\n' "$link"
}

# _cm_allowed <line text>: true when the line matches one of the --allow patterns (array `allow` of cmd_check).
_cm_allowed() {
  local a
  for a in ${allow[@]+"${allow[@]}"}; do
    printf '%s' "$1" | grep -qE -- "$a" && return 0
  done
  return 1
}

cmd_check() {
  local src="" target=remote text_all n=0 pat label lno text sd rc=0 done_lines="" hits=""
  local -a allow=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || { usage; exit 2; }; target="$2"; shift 2 ;;
      --target=*) target="${1#--target=}"; shift ;;
      --allow) [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
               printf '' | grep -qE -- "$2"; [ "$?" -ne 2 ] || { printf 'handoff: check: --allow %s is not a valid ERE\n' "$2" >&2; exit 2; }
               allow+=("$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -) [ -z "$src" ] || { usage; exit 2; }; src="-"; shift ;;
      --) shift; [ $# -eq 1 ] && [ -z "$src" ] || { usage; exit 2; }; src="$1"; shift ;;
      -*) usage; exit 2 ;;
      *) [ -z "$src" ] || { usage; exit 2; }; src="$1"; shift ;;
    esac
  done
  [ -n "$src" ] || { usage; exit 2; }
  case "$target" in remote|local) ;; *) usage; exit 2 ;; esac
  if [ "$src" != "-" ] && ! { [ -f "$src" ] && [ -r "$src" ]; }; then printf 'handoff: check: cannot read %s\n' "$src" >&2; exit 2; fi
  if [ "$target" != remote ]; then   # a worktree on this host can open these paths
    [ "$src" != "-" ] || cat > /dev/null   # drain stdin so a producer in a pipe is not killed by SIGPIPE
    exit 0
  fi

  if [ "$src" = "-" ]; then text_all="$(cat)"; else text_all="$(cat -- "$src")" || { printf 'handoff: check: cannot read %s\n' "$src" >&2; exit 2; }; fi

  # Literal references, one label each. The configured state_dir and the resolved $CM_HOME count too.
  # shellcheck disable=SC2088,SC2016  # literal text to find, not an expansion
  local -a lits=('~/.concertmaster' '$HOME/.concertmaster' '${HOME}/.concertmaster' '/root/.concertmaster')
  sd="$(cm_cfg .state_dir 2>/dev/null || true)"
  case "$sd" in /*|"~"*) [ "${#sd}" -ge 8 ] && lits+=("$sd") ;; esac   # a relative or bare-word state_dir would match prose
  [ "${#CM_HOME}" -ge 8 ] && lits+=("$CM_HOME")   # a CM_HOME of `/` would match every path
  local -a seen=()
  for pat in "${lits[@]}"; do
    case " ${seen[*]-} " in *" $pat "*) continue ;; esac
    seen+=("$pat")
    while IFS=: read -r lno text; do
      [ -n "$lno" ] || continue
      _cm_allowed "$text" && continue
      case " $done_lines " in *" $lno "*) continue ;; esac
      done_lines="$done_lines $lno"
      hits="$hits$(printf 'line %s: %s: %s' "$lno" "$pat" "$(printf '%s' "$text" | cut -c1-160)")"$'\n'; n=$((n + 1))
    done < <(printf '%s\n' "$text_all" | grep -noF -- "$pat" 2>/dev/null)
  done
  # Patterns (ERE): $CM_HOME as a whole name, and the home directory of a named user. A bare /home/ or
  # /Users/ with no user part is not a hit, and a URL path (/home/ after a letter or dot) is not either.
  local -a eres=('\$\{?CM_HOME([^A-Za-z0-9_]|$)' '(^|[^A-Za-z0-9._-])/home/[A-Za-z0-9._-]+' '(^|[^A-Za-z0-9._-])/Users/[A-Za-z0-9._-]+' '(^|[^A-Za-z0-9._-])/root/[A-Za-z0-9._/-]*')
  local -a elabels=('$CM_HOME' '/home/<user>/' '/Users/<user>/' '/root/')
  local i
  for i in 0 1 2 3; do
    pat="${eres[$i]}"; label="${elabels[$i]}"
    while IFS=: read -r lno text; do
      [ -n "$lno" ] || continue
      _cm_allowed "$text" && continue
      case " $done_lines " in *" $lno "*) continue ;; esac
      done_lines="$done_lines $lno"
      hits="$hits$(printf 'line %s: %s: %s' "$lno" "$label" "$(printf '%s' "$text" | cut -c1-160)")"$'\n'; n=$((n + 1))
    done < <(printf '%s\n' "$text_all" | grep -noE -- "$pat" 2>/dev/null)
  done
  if [ "$n" -gt 0 ]; then
    printf '%s' "$hits" | sort -n -k2,2
    printf 'handoff: check: %s line(s) with host-local references: a reader on another host cannot open them. Share the file with `handoff.sh share` and use the link, or put durable content in a GitHub issue.\n' "$n" >&2
    rc=1
  fi
  return "$rc"
}

verb="${1:-}"
[ $# -eq 0 ] || shift
case "$verb" in
  share) cmd_share "$@" ;;
  check) cmd_check "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
