#!/usr/bin/env bash
# spawn-verify.sh: the two guards for a claude session started in a terminal (SKILL.md § Spawn recipe).
#
#   scripts/spawn-verify.sh resolve [--ssh <target>]
#       Print the ABSOLUTE path of a working claude binary and exit 0; exit 1 with the reason
#       on stderr when there is none. A new Orca terminal can have a PATH without claude
#       ("claude not on PATH"), so the spawn command uses this path, never a bare `claude`.
#       Order: `command -v claude` in a login shell, then ~/.local/bin, ~/.npm-global/bin,
#       /usr/local/bin, the linuxbrew bin. A candidate must be executable and not a stub: a
#       half-finished self-update can leave ~/.npm-global/bin/claude missing or a ~500 byte
#       stub (fix: npm install -g @anthropic-ai/claude-code@<current version>, then re-run).
#       --ssh runs the same lookup on that host (ssh BatchMode, bash -s); local otherwise.
#
#   scripts/spawn-verify.sh check (--terminal <handle> [--environment <host>] [--wait <s>]
#                                  | --file <screen.txt>) [--model <m>] [--effort <e>]
#       Read the pane and exit 0 ONLY when the Claude UI shows the expected model: a banner
#       line like "<Model> <ver> with <effort> effort" or a status line like
#       "<model>-<ver> · eff <effort>" (model and effort from --model/--effort, else
#       cfg.spawn.expected_model and cfg.spawn.expected_effort). Send the brief only on exit 0.
#       `orca terminal wait --for tui-idle` is NOT proof: a plain shell prompt satisfies it
#       (the brief gets typed into the shell and the claude line is only echoed). The echoed
#       command line (`--model <api-id> --effort <level>`) never matches: the display form
#       differs from the API id (a dot, not a dash, in the version). Exit 1 = not verified,
#       with one line `verify: FAIL <reason>` (shell-prompt, command-not-found, wrong-model,
#       claude-not-running, claude-dialog, no-banner); exit 2 = usage or unreadable pane.
#       --wait polls every 2s up to that many seconds (the banner takes a few seconds);
#       without it the pane is read once.
#
# Defaults come from config: cfg.spawn.expected_model and cfg.spawn.expected_effort (config.example.yaml).
# With neither a flag nor a config value, check exits 2. Read-only: it never sends, creates or
# closes anything. Env: CM_HOME, ORCA_CLI_COMMAND (via lib.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

# CM_FOOTER_RE: the footer a live Claude pane ends with (status line, permissions line, shortcuts
# hint, subagent row); a shell prompt or an error never matches. Defined here only when lib.sh
# (or the environment) does not already provide it.
if [ -z "${CM_FOOTER_RE:-}" ]; then
  # shellcheck disable=SC2034
  CM_FOOTER_RE='⏵⏵|⏸|plan mode on|bypass permissions|accept edits on|auto-accept|\? for shortcuts|esc to interrupt|(·|•)[[:space:]]+eff(ort)?[[:space:]]+[a-z]+|ctx \[|^[[:space:]]*(◯|●|◐|◑|⎿|✻|✢|✳|✶|✽)[[:space:]]'
fi

usage() { sed -n '2,29p' "$0"; }

# Body of `resolve`, also shipped over ssh (declare -f), so it must stay self-contained.
cm_resolve_claude() {
  local min=100000 c p size seen=""
  local -a cands=()
  p="$(bash -lc 'command -v claude' 2>/dev/null | tail -n 1)"
  case "$p" in /*) cands+=("$p") ;; esac
  cands+=("$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" /usr/local/bin/claude /home/linuxbrew/.linuxbrew/bin/claude)
  for c in "${cands[@]}"; do
    [ -e "$c" ] || continue
    seen="$seen $c"
    [ -x "$c" ] || continue
    size="$(wc -c < "$c" 2>/dev/null | tr -d ' ')"
    if [ "${size:-0}" -ge "$min" ]; then printf '%s\n' "$c"; return 0; fi
    printf 'spawn-verify: %s is %s bytes: a stub, not claude (half-finished self-update?)\n' "$c" "${size:-0}" >&2
  done
  if [ -z "$seen" ]; then printf 'spawn-verify: no claude binary found (command -v, ~/.local/bin, ~/.npm-global/bin)\n' >&2; fi
  printf 'spawn-verify: fix: npm install -g @anthropic-ai/claude-code@<current version>, then re-run\n' >&2
  return 1
}

# Everything below judges the BOTTOM of the pane only (last 12 non-empty lines, like resume.sh:
# scrollback above proves nothing). Patterns use alternation, never a bracket holding multibyte
# characters, so they behave the same under the C locale (cron, systemd, non-interactive ssh).

screen_win() { grep -v '^[[:space:]]*$' "$1" | tail -n 12; }

# model_re <model> <effort>: "<Model> <ver> with <effort> effort" (banner) or "<model>-<ver> · eff <effort>"
# (status line, a real separator: an echoed `--model <model>-<ver> --effort <effort>` never matches).
model_re() {
  local m
  m="$(printf '%s' "$1" | sed 's/[.]/\\./g; s/-/[ -]/g')"
  printf '(%s with %s effort)|(%s[[:space:]]+(·|•|\\|)[[:space:]]+eff(ort)?[[:space:]]+%s([^[:alnum:]]|$))' "$m" "$2" "$m" "$2"
}

# screen_ok <file> <model> <effort>: 0 when the window shows a Claude UI line with the model at the
# effort AND the last line is a Claude footer, so a banner left above a crash or a shell prompt fails.
screen_ok() {
  local win last
  win="$(screen_win "$1")"
  # the BOTTOM-most model line is the live one: an older line (a transcript quoting another model) never counts
  printf '%s\n' "$win" | grep -iE "$CM_ANY_MODEL_RE" | tail -n 1 | grep -qiE "$(model_re "$2" "$3")" || return 1
  last="$(printf '%s\n' "$win" | tail -n 1)"
  printf '%s\n' "$last" | grep -qiE "$CM_FOOTER_RE"
}

# screen_reason <file> <model> <effort>: why a pane is not a verified Claude pane.
screen_reason() {
  local win other
  win="$(screen_win "$1")"
  if printf '%s\n' "$win" | grep -qiE 'command not found|no such file or directory|not on PATH|permission denied'; then echo command-not-found; return; fi
  other="$(printf '%s\n' "$win" | grep -iE "$CM_ANY_MODEL_RE" | tail -n 1)"
  if printf '%s\n' "$win" | grep -qiE 'Enter to (select|confirm)|Esc to (cancel|exit)'; then echo "claude-dialog: a menu is open, answer or cancel it first (Claude is live)"; return; fi
  if printf '%s\n' "$other" | grep -qiE "$(model_re "$2" "$3")"; then
    echo "claude-not-running: the model line is on screen but the last line is not a Claude footer (exited, crashed or stale scrollback)"; return
  fi
  if [ -n "$other" ]; then echo "wrong-model: $(printf '%s' "$other" | tr -s ' ' | cut -c1-80)"; return; fi
  if printf '%s\n' "$win" | tail -n 1 | grep -qE '[%$#>]|❯|➜' && ! printf '%s\n' "$win" | grep -qiE "$CM_CLAUDE_RE"; then echo shell-prompt; return; fi
  echo no-banner
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  resolve)
    target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --ssh) [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; target="$2"; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    if [ -z "$target" ]; then cm_resolve_claude; exit $?; fi
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$target" "bash -s" < <(declare -f cm_resolve_claude; echo cm_resolve_claude)
    exit $?
    ;;
  check)
    term=""; envsel=""; file=""; wait_s=0
    model="$(cm_cfg .spawn.expected_model)"; effort="$(cm_cfg .spawn.expected_effort)"
    while [ $# -gt 0 ]; do
      case "$1" in
        --terminal|--environment|--file|--wait|--model|--effort)
          [ $# -ge 2 ] || { usage >&2; exit 2; }
          case "$1" in
            --terminal) term="$2" ;; --environment) envsel="$2" ;; --file) file="$2" ;;
            --wait) wait_s="$2" ;; --model) model="$2" ;; --effort) effort="$2" ;;
          esac
          shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [[ "$wait_s" =~ ^[0-9]+$ ]] || { cm_warn "spawn-verify: --wait takes seconds"; exit 2; }
    if [ -z "$model" ] || [ -z "$effort" ]; then
      cm_warn "spawn-verify: no expected model/effort: pass --model and --effort, or set spawn.expected_model and spawn.expected_effort in the config"
      exit 2
    fi
    if [ -n "$file" ]; then
      [ -r "$file" ] || { cm_warn "spawn-verify: cannot read $file"; exit 2; }
    elif [ -z "$term" ]; then
      usage >&2; exit 2
    fi
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cm-spawn-verify.XXXXXX")" || exit 2
    trap 'rm -rf -- "${TMPD:?}"' EXIT
    SCREEN="$TMPD/screen.txt"
    ORCA="$(cm_orca)"
    deadline=$(( $(date +%s) + wait_s ))
    while :; do
      if [ -n "$file" ]; then
        cp "$file" "$SCREEN"
      else
        envargs=(); [ -z "$envsel" ] || envargs=(--environment "$envsel")
        out="$(cm_timeout 30 "$ORCA" terminal read --terminal "$term" --screen ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null)" || out=""
        # The live CLI returns .result.terminal.tail (lines); older shapes carry a text field.
        printf '%s' "$out" | jq -r 'if .ok == true then
            ((.result.terminal.tail // empty | if type == "array" then join("\n") else tostring end)
             // .result.screen // .result.text // .result.output // "") else "" end' > "$SCREEN" 2>/dev/null || : > "$SCREEN"
        if [ ! -s "$SCREEN" ] && [ "$(date +%s)" -ge "$deadline" ]; then
          echo "verify: FAIL pane unreadable"; exit 2
        fi
      fi
      if [ -s "$SCREEN" ] && screen_ok "$SCREEN" "$model" "$effort"; then
        echo "verify: ok $model effort $effort"; exit 0
      fi
      [ "$(date +%s)" -ge "$deadline" ] && break
      sleep 2
    done
    echo "verify: FAIL $(screen_reason "$SCREEN" "$model" "$effort")"
    exit 1
    ;;
  -h|--help|help|'') usage; [ -n "$cmd" ] || exit 2; exit 0 ;;
  *) cm_warn "spawn-verify: unknown command: $cmd"; usage >&2; exit 2 ;;
esac
