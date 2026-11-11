#!/usr/bin/env bash
# lane-health.sh: is every lane really running? One shared check for the concertmaster and for each lead.
#
#   scripts/lane-health.sh --all  [--act] [--no-write] [--json|--line]   # concertmaster: every lead, worker and unknown
#   scripts/lane-health.sh --lead <worker-id> [--act] [--no-write] [--json|--line]   # a lead: its own children only
#   scripts/lane-health.sh sleep <worker-id> [--apply]   # stop a session on purpose: process and terminal, keep the rest
#   scripts/lane-health.sh wake  <worker-id> [--apply]   # resume an asleep session on its own session id
#
# Per host (this machine directly, any other over ssh to cm_ssh_target, the same way live-agent.sh does) it reads:
#   live agent processes   pid, cwd, session id (the cmdline `--resume <id>`, else the ONE transcript of that cwd),
#                          runtime (orca or plugly, from the parent process chain, else the handle variable),
#                          model and effort (cmdline flags, else the ledger), terminal handle (environ), last transcript write
#   host events            boot time (/proc/stat btime, else `uptime -s`), `last -x`, a Spot preemption where the GCE
#                          metadata server says so or the previous boot logged a power-key press (health.cloud: gce), and a
#                          restart of the runtime daemon after boot (health.daemon_units, systemd ActiveEnterTimestamp)
#   panes                  the bottom 12 non-empty lines of each agent's terminal: busy, idle, menu, usage limit, error
# then compares that with the ledger workers{} and gives every session ONE word:
#   running ● doing work now        idle ○ fine, nothing to do     waiting on you ? needs the owner
#   stuck ⚠ menu 30 min, limit, error   stopped ✗ should run, no process   asleep z put to sleep on purpose
#   unknown · not in the ledger, or the host did not answer
# with a one-line meaning for anything not running. A stop gets a cause: reboot, preemption, daemon restart, limit,
# crash or unknown (a boot or daemon restart after the session's last transcript write, else what the pane last showed).
#
# Default: read and record. --all writes the live facts, expected state, last task line and stop history of each
# session into the ledger (cm_ledger_write) and appends host events to hostEvents[]; --lead keeps the same record in
# $CM_HOME/cache/lane-health-lead-<id>.json and never writes the ledger (the ledger has one writer). No session is
# touched and nothing is sent without --act. --no-write writes nothing at all (scripts/cm-status.sh uses it).
#
# --act (references/lane-health.md):
#   stopped, healthy before   resumed ONCE in its owner runtime: `<agent> --dangerously-skip-permissions --resume <full id>
#                             [--model m] [--effort e]` in the same worktree, then verified (exactly one process on that
#                             id, the bypass footer on the pane, the same transcript written); a second stop inside
#                             health.resume_reset_hours of healthy running is never retried. --all resumes leads and
#                             unowned sessions; a lead's own children are its own (`--lead`), so two checkers never race.
#   a fresh boot or daemon    nothing is resumed on that host until health.settle_minutes (5) have passed: the host's
#   restart                   own resume runs first; the duplicate check runs again right before any create
#   unknown worker (--all)    put to sleep (process stopped by exact pid, terminal closed, an asleep ledger row added)
#                             only when it is not lead-shaped, its tree is clean, its branch is merged (HEAD reached
#                             from origin/<default> through a merge, not on its first-parent line) and its transcript
#                             is health.unknown_idle_minutes old; anything that looks like a lead is flagged, never slept
#   duplicate                 alert only, nothing touched (SKILL.md hard rule 4)
#   stuck                     alert after health.stuck_minutes; a usage-credits or limit menu is never answered
#   alerts (--all only)       lead stopped after its one try, host rebooted or preempted (one message: what came back
#                             and what did not), stuck 30 min, two copies of one session; one per event, deduplicated in
#                             ledger health.alerted; an inbox note $CM_HOME/inbox/lane-health-<kind>-<UTC>-<pid>.md and the
#                             send hook (health.alerts.send, else messaging.owner_digest.send)
# Leads (standing: true, a lane-shaped name, the concertmaster itself) are never slept, cleaned up or torn down by
# this script except through the explicit `sleep` subcommand, which an operator runs on the owner's word.
#
# Output: one TSV row per session (host, lead, session, word, meaning), then action and alert rows; --json the whole
# document; --line one `cm:health ...` line for a lead's worktree comment. Exit 0 all healthy; 3 something needs a look;
# 1 cannot run (no ledger in --all, sleep or wake); 2 usage; 4 another lane-health --act run holds the lock.
# Env: CM_HOME, CM_NOW (clock), CM_HEALTH_* overrides of the health.* keys, CM_HEALTH_SEND (send command),
# CM_HEALTH_AGENT_BIN (the agent binary to launch; default spawn-verify.sh resolve), CM_CLAUDE_PROJECTS.
# Tests only (CM_TEST=1): CM_PROC_ROOT, CM_HEALTH_REMOTE_PROC_ROOT, CM_HEALTH_KILL_CMD.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,7p' "$0" >&2; exit 2; }
MODE=""; LEAD=""; ACT=0; NOWRITE=0; OUTFMT=tsv; APPLY=0; TARGET=""
case "${1:-}" in
  sleep|wake) MODE="$1"; TARGET="${2:-}"; [ -n "$TARGET" ] || { cm_warn "lane-health.sh $1: a worker id is required"; usage; }; shift 2 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --all) [ -z "$MODE" ] || usage; MODE=all ;;
    --lead) [ -z "$MODE" ] && [ $# -ge 2 ] && [ -n "$2" ] || usage; MODE=lead; LEAD="$2"; shift ;;
    --act) ACT=1 ;;
    --no-write) NOWRITE=1 ;;
    --json) OUTFMT=json ;;
    --line) OUTFMT=line ;;
    --apply) APPLY=1 ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) cm_warn "lane-health.sh: unknown arg: $1"; usage ;;
  esac
  shift
done
[ -n "$MODE" ] || usage
case "$MODE" in sleep|wake) [ "$ACT$NOWRITE" = 00 ] || { cm_warn "lane-health.sh $MODE takes --apply only"; usage; } ;; *) [ "$APPLY" = 0 ] || usage ;; esac
# an acting pass must record what it did (the one-try count and the alert dedup live in the record)
[ "$ACT$NOWRITE" != 11 ] || { cm_warn "lane-health.sh: --act and --no-write do not go together"; usage; }
case "$LEAD$TARGET" in *[!A-Za-z0-9._:@-]*) cm_warn "lane-health.sh: a worker id is a plain token"; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { cm_warn "lane-health.sh: missing dependency: jq"; exit 1; }

isint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
cfgint() { # <env value> <config path> <default>
  local v="${1:-}"; [ -n "$v" ] || v="$(cm_cfg "$2" "$3")"
  if isint "$v"; then printf '%s' "$((10#$v))"; else cm_warn "lane-health.sh: $2 must be a whole number (got '$v'): using $3"; printf '%s' "$3"; fi
}
SETTLE_MIN="$(cfgint "${CM_HEALTH_SETTLE_MIN:-}" .health.settle_minutes 5)"
STUCK_MIN="$(cfgint "${CM_HEALTH_STUCK_MIN:-}" .health.stuck_minutes 30)"
RUNNING_S="$(cfgint "${CM_HEALTH_RUNNING_S:-}" .health.running_seconds 120)"
UNKNOWN_IDLE_MIN="$(cfgint "${CM_HEALTH_UNKNOWN_IDLE_MIN:-}" .health.unknown_idle_minutes 60)"
RESET_H="$(cfgint "${CM_HEALTH_RESET_H:-}" .health.resume_reset_hours 6)"
VERIFY_S="$(cfgint "${CM_HEALTH_VERIFY_S:-}" .health.verify_seconds 90)"
POLL_S="$(cfgint "${CM_HEALTH_POLL_S:-}" .health.verify_poll_seconds 3)"; [ "$POLL_S" -ge 1 ] || POLL_S=1
SSH_S="$(cfgint "${CM_HEALTH_SSH_S:-}" .health.ssh_seconds 40)"; [ "$SSH_S" -ge 1 ] || SSH_S=40
CLOUD="${CM_HEALTH_CLOUD:-$(cm_cfg .health.cloud none)}"
case "$CLOUD" in gce|none) ;; *) cm_warn "lane-health.sh: health.cloud must be gce or none (got '$CLOUD'): using none"; CLOUD=none ;; esac
UNITS="${CM_HEALTH_DAEMON_UNITS-$(cm_cfg .health.daemon_units)}"
case "$UNITS" in *[!A-Za-z0-9@._:\ -]*) cm_warn "lane-health.sh: health.daemon_units holds a character outside [A-Za-z0-9@._:-]: ignored"; UNITS="" ;; esac
AGENTS="$(cm_cfg .respawn.live_agents "claude codex agy")"
case "$AGENTS" in *[!A-Za-z0-9._\ -]*|'') cm_warn "lane-health.sh: respawn.live_agents must be a plain word list"; exit 2 ;; esac
LIMIT_RE="$(cm_cfg .health.limit_regex 'usage limit|limit reached|rate limit|resets? at|weekly limit|out of (extra )?usage|usage credits')"
ERROR_RE="$(cm_cfg .health.error_regex 'api error|internal server error|overloaded_error|request timed out|unable to connect to api')"
NOW="${CM_NOW:-$(date +%s)}"; isint "$NOW" || { cm_warn "lane-health.sh: CM_NOW must be an epoch"; exit 2; }
NEVER_TOUCH="$(cm_cfg_json .worktrees.never_touch '[]')"
LANE_NAMES="$(cm_lane_names | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
SELF="$CM_SELF_WORKTREE"
LEDGER="$(cm_ledger_path)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-lane-health.XXXXXX")" || { cm_warn "lane-health.sh: cannot create a temp dir"; exit 1; }
LOCK=""; HAVE_LOCK=0   # set once the record is known: one lock per record (--all, or one lead)
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  if [ "${HAVE_RLOCK:-0}" = 1 ] && [ "$(cat "$RESUME_LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf -- "${RESUME_LOCK:?}"; fi
  if [ "$HAVE_LOCK" = 1 ] && [ -n "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf -- "${LOCK:?}"; fi
  [ -z "$TMP" ] || rm -rf -- "${TMP:?}"
  return 0
}
trap cleanup EXIT
iso() { jq -nr --argjson t "$1" '$t | floor | todate'; }

# ---- the probe: runs on the host it reads (streamed over ssh with `declare -f`), so it uses nothing from lib.sh but
# cm_status_dirt, which is shipped with it. One line per fact, tab separated, every field cleaned of tabs and newlines:
#   H <key> <value>     host facts (hostname, now, boot, uptime_s, lastx, powerkey, preempted, spot)
#   D <unit> <epoch>    a daemon unit and the time it last became active
#   P <pid> <cwd> <sid> <sid-source> <runtime> <model> <effort> <handle> <transcript mtime> <bypass 0|1> <agent>
#     <git top> <branch> <dirty count> <merged 0|1> <on first-parent 0|1> <newest session id in that cwd> <its mtime>
#     <process start epoch>
#   T <path> <newest transcript mtime> <transcript count> <single session id> <newest session id>
#   Q <cwd> <sid>       an agent process with no terminal: counted as a copy, never judged or touched
#   W <what> <detail>   the scan was incomplete (an unreadable process entry); E <what> <detail> the probe could not run
# shellcheck disable=SC2329  # shipped to bash -s with declare -f
lh_probe() {
  local proc="$1" projects="${2:-}" agents="$3" expect="$4" units="$5" cloud="$6" pre="$7"
  shift 7
  [ -n "$projects" ] || projects="$HOME/.claude/projects"
  _lhf() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-400; }
  _lhmt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
  _lhdir() { printf '%s/%s' "$projects" "$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"; }
  _lhtinfo() {
    local ff mm
    LH_NEW=""; LH_NSID=""; LH_CNT=0; LH_ONE=""
    for ff in "$1"/*.jsonl; do
      [ -e "$ff" ] || continue
      LH_CNT=$((LH_CNT + 1)); mm="$(_lhmt "$ff")"
      if [ -z "$LH_NEW" ] || [ "$mm" -gt "$LH_NEW" ]; then LH_NEW="$mm"; LH_NSID="$(basename "$ff" .jsonl)"; fi
    done
    if [ "$LH_CNT" = 1 ]; then LH_ONE="$LH_NSID"; fi
  }
  _lhagent() {   # <comm> <argv...>: the configured agent name the command is (live-agent.sh agent_of)
    local b a c="$1"
    shift
    for a in $agents; do [ "$c" = "$a" ] && { printf '%s' "$a"; return; }; done
    b="${1##*/}"
    case "$b" in
      node|nodejs|bun|deno)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -e|--eval|-p|--print) break ;;
            -r|--require|--import|--loader|--experimental-loader|-C|--conditions) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) b="${1##*/}"; break ;;
          esac
        done ;;
    esac
    for a in $agents; do [ "$b" = "$a" ] && { printf '%s' "$a"; return; }; done
  }
  local now got boot up lastx pk pm sp u t e d pid stat rest state ppid tty argv arg comm agent cwd sid src model eff byp
  local headless i n kv hp ho sph sho h rt anc depth acomm acmd a1 a1d st2 r2 top br dirty ref merged onmain head s tdir tm p stt pst hz
  now="$(date +%s)"
  got="$(hostname -s 2>/dev/null || hostname 2>/dev/null)"; got="$(printf '%s' "${got%%.*}" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$expect" ] && [ "$got" != "$(printf '%s' "${expect%%.*}" | tr '[:upper:]' '[:lower:]')" ]; then
    printf 'E\twrong-host\tthis host answered as %s, expected %s\n' "$(_lhf "$got")" "$(_lhf "$expect")"; return 3
  fi
  if [ ! -d "$proc" ] || { [ "$proc" = /proc ] && [ ! -d /proc/self ]; }; then printf 'E\tno-proc\tno %s on this host (Linux only)\n' "$proc"; return 3; fi
  printf 'H\thostname\t%s\nH\tnow\t%s\n' "$(_lhf "$got")" "$now"
  boot="$(awk '$1 == "btime" { print $2; exit }' "$proc/stat" 2>/dev/null)"
  up="$(uptime -s 2>/dev/null || true)"
  if [ -z "$boot" ] && [ -n "$up" ]; then boot="$(date -d "$up" +%s 2>/dev/null || true)"; fi
  printf 'H\tboot\t%s\nH\tuptime_s\t%s\n' "$(_lhf "$boot")" "$(_lhf "$up")"
  lastx="$(last -x reboot shutdown 2>/dev/null | grep -Ev '^(wtmp|[[:space:]]*$)' | head -n 4 | tr -s ' ' | tr '\n' ';' || true)"
  printf 'H\tlastx\t%s\n' "$(_lhf "$lastx")"
  pk=""
  if command -v journalctl >/dev/null 2>&1; then
    pk="$(journalctl -b -1 -q --no-pager -t systemd-logind 2>/dev/null | grep -i -m1 'power key' || true)"
  fi
  printf 'H\tpowerkey\t%s\n' "$(_lhf "$pk")"
  pm=""; sp=""
  if [ "$cloud" = gce ] && command -v curl >/dev/null 2>&1; then
    pm="$(curl -s -m 2 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/preempted 2>/dev/null || true)"
    sp="$(curl -s -m 2 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/scheduling/provisioning-model 2>/dev/null || true)"
    case "$pm" in TRUE|FALSE) ;; *) pm="" ;; esac
    case "$sp" in *[!A-Za-z_]*) sp="" ;; esac
  fi
  printf 'H\tpreempted\t%s\nH\tspot\t%s\n' "$pm" "$sp"
  for u in $units; do
    t=""
    if command -v systemctl >/dev/null 2>&1; then
      t="$(systemctl --user show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)"
      case "$t" in ''|n/a) t="$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)" ;; esac
    fi
    case "$t" in ''|n/a) continue ;; esac
    e="$(date -d "$t" +%s 2>/dev/null || true)"
    case "$e" in ''|*[!0-9]*) continue ;; esac
    printf 'D\t%s\t%s\n' "$(_lhf "$u")" "$e"
  done
  for d in "$proc"/[0-9]*; do
    [ -d "$d" ] || continue
    pid="${d##*/}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -O "$d" ] || continue
    if ! stat="$(cat "$d/stat" 2>/dev/null)"; then [ -e "$d" ] && printf 'W\tunreadable\tstat of %s\n' "$pid"; continue; fi
    rest="${stat##*) }"
    read -r state ppid _ _ tty _ <<< "$rest"
    case "$state" in Z|X|x) continue ;; esac
    # a process with no terminal (a daemon, a headless `claude -p` run) is never a lane; an agent among them is only
    # counted per cwd (Q), so its transcript is never taken for a lane's own session
    headless=0
    case "$tty" in ''|*[!0-9]*) printf 'W\tunreadable\ttty of %s\n' "$pid"; continue ;; 0) headless=1 ;; esac
    argv=()
    while IFS= read -r -d '' arg || [ -n "$arg" ]; do argv+=("$arg"); done < "$d/cmdline" 2>/dev/null || true
    if [ "${#argv[@]}" -eq 0 ]; then [ "$headless" = 1 ] || [ -r "$d/cmdline" ] || { [ -e "$d" ] && printf 'W\tunreadable\tcmdline of %s\n' "$pid"; }; continue; fi
    comm=""; [ -r "$d/comm" ] && IFS= read -r comm < "$d/comm" 2>/dev/null
    agent="$(_lhagent "$comm" "${argv[@]}")"
    [ -n "$agent" ] || continue
    cwd="$(readlink "$d/cwd" 2>/dev/null)" || { [ "$headless" = 1 ] || { [ -e "$d" ] && printf 'W\tunreadable\tcwd of %s\n' "$pid"; }; continue; }
    cwd="${cwd%/}"; [ -n "$cwd" ] || cwd=/
    sid=""; src=""; model=""; eff=""; byp=0
    n="${#argv[@]}"; i=0
    while [ "$i" -lt "$n" ]; do
      case "${argv[$i]}" in
        --resume|-r|--session-id) [ $((i + 1)) -lt "$n" ] && { sid="${argv[$((i + 1))]}"; src=cmdline; } ;;
        --resume=*|--session-id=*) sid="${argv[$i]#*=}"; src=cmdline ;;
        --model) [ $((i + 1)) -lt "$n" ] && model="${argv[$((i + 1))]}" ;;
        --model=*) model="${argv[$i]#*=}" ;;
        --effort) [ $((i + 1)) -lt "$n" ] && eff="${argv[$((i + 1))]}" ;;
        --effort=*) eff="${argv[$i]#*=}" ;;
        --dangerously-skip-permissions) byp=1 ;;
      esac
      i=$((i + 1))
    done
    case "$sid" in *[!A-Za-z0-9._-]*|-*) sid=""; src="" ;; esac
    if [ "$headless" = 1 ]; then printf 'Q\t%s\t%s\n' "$(_lhf "$cwd")" "$sid"; continue; fi
    case "$model" in *[!A-Za-z0-9._-]*) model="" ;; esac
    case "$eff" in *[!a-z]*) eff="" ;; esac
    tdir="$(_lhdir "$cwd")"
    _lhtinfo "$tdir"
    if [ -z "$sid" ] && [ -n "$LH_ONE" ]; then sid="$LH_ONE"; src=transcript; fi
    # the last write of THAT session; with no id at all, of the worktree (never another session's file for a known id)
    tm=""
    if [ -n "$sid" ] && [ -e "$tdir/$sid.jsonl" ]; then tm="$(_lhmt "$tdir/$sid.jsonl")"; elif [ -z "$sid" ]; then tm="$LH_NEW"; fi
    # process start (stat field 22, clock ticks after boot): lets the caller tell a session this process began after
    # /clear (newer transcript, written after the start) from one of another process
    pst=""
    read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ stt _ <<< "$rest"
    if isnum_lh "${stt:-}" && isnum_lh "${boot:-}"; then hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"; isnum_lh "$hz" || hz=100; pst=$((boot + stt / hz)); fi
    # handle: PLUGLY_TERMINAL_HANDLE first, else ORCA_TERMINAL_HANDLE; both set and different = ambiguous, none
    hp=""; ho=""; sph=0; sho=0; h=""
    if [ -r "$d/environ" ]; then
      while IFS= read -r -d '' kv || [ -n "$kv" ]; do
        case "$kv" in
          PLUGLY_TERMINAL_HANDLE=*) if [ "$sph" = 0 ]; then sph=1; hp="${kv#PLUGLY_TERMINAL_HANDLE=}"; fi ;;
          ORCA_TERMINAL_HANDLE=*) if [ "$sho" = 0 ]; then sho=1; ho="${kv#ORCA_TERMINAL_HANDLE=}"; fi ;;
        esac
      done < "$d/environ"
    fi
    if [ -n "$hp" ] && [ -n "$ho" ] && [ "$hp" != "$ho" ]; then h=""; elif [ -n "$hp" ]; then h="$hp"; else h="$ho"; fi
    case "$h" in -*|*[!A-Za-z0-9._:-]*) h="" ;; esac
    # runtime: the first ancestor whose process name, argv[0] basename, or the script an interpreter (node, bun) runs
    # is a plugly or orca program. Never a substring of a whole command line: a shell whose arguments name an
    # .../orca/workspaces/... path is not the runtime.
    rt=""; anc="$ppid"; depth=0
    while isnum_lh "$anc" && [ "$anc" -gt 1 ] && [ "$depth" -lt 15 ]; do
      acomm=""; [ -r "$proc/$anc/comm" ] && IFS= read -r acomm < "$proc/$anc/comm" 2>/dev/null
      acmd=""; a1=""
      { IFS= read -r -d '' acmd; IFS= read -r -d '' a1; } < "$proc/$anc/cmdline" 2>/dev/null || true
      case "${acomm##*/}" in node|nodejs|bun|deno) acomm="" ;; esac
      a1d=""; case "${acmd##*/}" in node|nodejs|bun|deno) a1d="${a1%/*}"; a1d="${a1d##*/}"; a1="${a1##*/}" ;; *) a1="" ;; esac
      for e in "$acomm" "${acmd##*/}" "$a1" "$a1d"; do
        case "$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')" in
          "plugly"|"plugly-"*|"plugly."*) rt="plugly"; break ;;
          "orca"|"orca-"*|"orca."*) rt="orca"; break ;;
        esac
      done
      [ -z "$rt" ] || break
      st2="$(cat "$proc/$anc/stat" 2>/dev/null)" || break
      r2="${st2##*) }"; read -r _ anc _ <<< "$r2"
      depth=$((depth + 1))
    done
    if [ -z "$rt" ]; then
      if [ -n "$hp" ] && [ -z "$ho" ]; then rt=plugly; elif [ -n "$ho" ] && [ -z "$hp" ]; then rt=orca; fi
    fi
    top=""; br=""; dirty=""; merged=""; onmain=""
    if [ -n "$pre" ] && printf '%s\n' "$cwd" | grep -Eq -- "$pre" && command -v git >/dev/null 2>&1; then
      top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
      if [ -n "$top" ]; then
        br="$(git -C "$top" symbolic-ref -q --short HEAD 2>/dev/null || true)"
        if s="$(git -C "$top" status --porcelain --untracked-files=all 2>/dev/null)"; then dirty="$(printf '%s\n' "$s" | cm_status_dirt | cut -d' ' -f1)"; fi
        ref="$(git -C "$top" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"; [ -n "$ref" ] || ref=origin/main
        head="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null || true)"
        if [ -n "$head" ] && git -C "$top" rev-parse -q --verify "$ref" >/dev/null 2>&1; then
          if git -C "$top" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then merged=1; else merged=0; fi
          if git -C "$top" rev-list --first-parent "$ref" 2>/dev/null | grep -qxF -- "$head"; then onmain=1; else onmain=0; fi
        fi
      fi
    fi
    printf 'P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$(_lhf "$cwd")" "$sid" "$src" "$rt" "$model" "$eff" "$h" \
      "$tm" "$byp" "$agent" "$(_lhf "$top")" "$(_lhf "$br")" "$dirty" "$merged" "$onmain" "$LH_NSID" "$LH_NEW" "$pst"
  done
  for p in "$@"; do
    _lhtinfo "$(_lhdir "$p")"
    printf 'T\t%s\t%s\t%s\t%s\t%s\n' "$(_lhf "$p")" "$LH_NEW" "$LH_CNT" "$LH_ONE" "$LH_NSID"
  done
  return 0
}
# shellcheck disable=SC2329  # shipped with lh_probe
isnum_lh() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# expect_hostname <host>: what `hostname -s` must answer there (live-agent.sh's rule): CM_SSH_EXPECT_HOSTNAME, else the
# ledger hosts.<h>.hostname, else the host name. Status 1 for a value that is not a plain host name.
expect_hostname() {
  local e="${CM_SSH_EXPECT_HOSTNAME:-}"
  if [ -z "$e" ] && [ -s "$LEDGER" ]; then e="$(jq -r --arg h "$1" '.hosts[$h].hostname // empty' "$LEDGER" 2>/dev/null)"; fi
  e="${e:-$1}"
  case "$e" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  printf '%s\n' "$e"
}
# probe_host <host> <out-file> [path...]: the probe's lines in <out-file>, a JSON host document in <out-file>.json.
probe_host() {
  local host="$1" out="$2" rc=0 target expect remote_proc err
  shift 2
  if [ "$host" = local ]; then
    {
      declare -f cm_status_dirt lh_probe isnum_lh
      printf 'CM_IGNORE_UNTRACKED=%q\n' "$CM_IGNORE_UNTRACKED"
      printf 'lh_probe'; printf ' %q' "$(cm_proc_root)" "${CM_CLAUDE_PROJECTS:-}" "$AGENTS" "" "$UNITS" "$CLOUD" "$CM_PATH_MATCH" "$@"; printf '\n'
    } | cm_timeout "$SSH_S" bash -s > "$out" 2>"$out.err" || rc=$?
  else
    target="$(cm_ssh_target "$host")"
    case "$target" in -*|*[[:space:]]*|'') printf 'E\tbad-target\tinvalid ssh target for %s\n' "$host" > "$out"; rc=3 ;; esac
    if [ "$rc" = 0 ]; then
      expect="$(expect_hostname "$host")" || { printf 'E\tbad-hostname\tinvalid expected hostname for %s\n' "$host" > "$out"; rc=3; }
    fi
    if [ "$rc" = 0 ]; then
      remote_proc=/proc
      if [ "${CM_TEST:-}" = 1 ] && [ -n "${CM_HEALTH_REMOTE_PROC_ROOT:-}" ]; then remote_proc="$CM_HEALTH_REMOTE_PROC_ROOT"; fi
      {
        declare -f cm_status_dirt lh_probe isnum_lh
        printf 'CM_IGNORE_UNTRACKED=%q\n' "$CM_IGNORE_UNTRACKED"
        printf 'lh_probe'; printf ' %q' "$remote_proc" "${CM_HEALTH_REMOTE_PROJECTS:-}" "$AGENTS" "$expect" "$UNITS" "$CLOUD" "$CM_PATH_MATCH" "$@"; printf '\n'
      } | cm_timeout "$SSH_S" ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$target" bash -s > "$out" 2>"$out.err" || rc=$?
    fi
  fi
  err="$(awk -F'\t' '$1 == "E" { print $3; exit }' "$out" 2>/dev/null)"
  if [ -z "$err" ] && [ "$rc" != 0 ]; then err="$(head -c 120 "$out.err" 2>/dev/null | tr '\t\n' '  ')"; err="probe exit $rc${err:+: $err}"; fi
  jq -R -s --arg host "$host" --arg err "$err" '
    def nn: if . == null or . == "" then null else . end;
    def num: if . == null or . == "" then null else (tonumber? // null) end;
    split("\n") | map(select(length > 0) | split("\t")) as $l
    | if $err != "" then {host: $host, ok: false, error: $err}
      else {host: $host, ok: true, error: null,
            incomplete: ([$l[] | select(.[0] == "W")] | length > 0),
            facts: ([$l[] | select(.[0] == "H") | {(.[1]): (.[2] | nn)}] | add // {}),
            daemons: [$l[] | select(.[0] == "D") | {unit: .[1], at: (.[2] | num)}],
            headless: [$l[] | select(.[0] == "Q") | {cwd: .[1], sid: (.[2] | nn)}],
            procs: [$l[] | select(.[0] == "P")
                    | {pid: (.[1] | num), cwd: .[2], sid: (.[3] | nn), sidsrc: (.[4] | nn), runtime: (.[5] | nn), model: (.[6] | nn),
                       effort: (.[7] | nn), handle: (.[8] | nn), tmtime: (.[9] | num), bypass: (.[10] == "1"), agent: (.[11] | nn),
                       top: (.[12] | nn), branch: (.[13] | nn), dirty: (.[14] | num), merged: (.[15] | nn), onMain: (.[16] | nn),
                       nsid: (.[17] | nn), nmt: (.[18] | num), start: (.[19] | num)}],
            trans: ([$l[] | select(.[0] == "T") | {(.[1]): {mtime: (.[2] | num), count: (.[3] | num), single: (.[4] | nn), newest: (.[5] | nn)}}] | add // {})} end' \
    "$out" > "$out.json" 2>/dev/null || jq -n --arg host "$host" '{host: $host, ok: false, error: "probe output unreadable"}' > "$out.json"
}

# cli_for <runtime>: the CLI command for that runtime (orca or plugly), else the configured one.
cli_for() { case "${1:-}" in orca|plugly) CM_CLI_KIND="$1" cm_cli ;; *) cm_cli ;; esac; }

# pane_bottom <host> <runtime> <handle>: the bottom 12 non-empty lines of the pane; status 1 when unreadable.
pane_bottom() {
  local cli txt
  local -a hs
  cli="$(cli_for "$2")" || return 1
  cm_cli_host_into hs "$1" || return 1
  txt="$(cm_timeout 30 "$cli" terminal read --terminal "$3" --screen ${hs[@]+"${hs[@]}"} --json </dev/null 2>/dev/null \
    | jq -r 'if .ok == true then (((.result.terminal.tail // empty) | if type == "array" then join("\n") else tostring end | select(length > 0)) // .result.screen // .result.text // .result.output // "") | tostring else "" end' 2>/dev/null)"
  txt="$(printf '%s\n' "$txt" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 12)"
  [ -n "$txt" ] || return 1
  printf '%s\n' "$txt"
}
# pane_state <bottom text>: "<state><TAB><line>"; limit (also the usage-credits menu), error, menu, busy, idle, shell, other.
pane_state() {   # a limit or an error is judged on the bottom 6 lines only: the agent's own text above may quote one
  local b="$1" l b6
  b6="$(printf '%s\n' "$b" | tail -n 6)"
  if printf '%s\n' "$b" | grep -qE 'esc to interrupt'; then printf 'busy\t\n'; return; fi   # a working agent may print "resets at" itself
  if l="$(printf '%s\n' "$b6" | grep -iE -- "$LIMIT_RE")" && [ -n "$l" ]; then   # the line naming the reset time, when there is one
    printf 'limit\t%s\n' "$({ printf '%s\n' "$l" | grep -i 'reset' || printf '%s\n' "$l"; } | head -n 1)"; return
  fi
  if l="$(printf '%s\n' "$b6" | grep -iE -- "$ERROR_RE" | tail -n 1)" && [ -n "$l" ]; then printf 'error\t%s\n' "$l"; return; fi
  if l="$(printf '%s\n' "$b" | grep -iE -- "$CM_MENU_RE" | tail -n 1)" && [ -n "$l" ]; then printf 'menu\t%s\n' "$(printf '%s\n' "$b" | grep -E '[?]' | tail -n 1)"; return; fi
  if printf '%s\n' "$b" | tail -n 1 | grep -qE '^[^[:space:]]*[$#%] *$'; then printf 'shell\t\n'; return; fi
  if printf '%s\n' "$b" | grep -qiE -- "$CM_FOOTER_RE|$CM_CLAUDE_RE"; then printf 'idle\t\n'; return; fi
  printf 'other\t\n'
}

# ---- ledger and store ---------------------------------------------------------------------------
HAVE_LEDGER=0
if [ -s "$LEDGER" ]; then
  cm_ledger_guard "$LEDGER" || exit 3
  if jq -e 'type == "object" and ((.workers // null) | type) == "object"' "$LEDGER" >/dev/null 2>&1; then HAVE_LEDGER=1; fi
fi
case "$MODE" in
  all|sleep|wake) [ "$HAVE_LEDGER" = 1 ] || { cm_warn "lane-health.sh: no readable ledger at $LEDGER: --all, sleep and wake run on the concertmaster host only (a lead uses --lead)"; exit 1; } ;;
esac
if [ "$MODE" = lead ]; then STORE="$CM_HOME/cache/lane-health-lead-$(printf '%s' "$LEAD" | tr -c 'A-Za-z0-9._-' '_').json"; else STORE="$LEDGER"; fi

# take_mkdir_lock <dir> <args-regex>: a mkdir lock holding our pid (written by temp file and mv). Held by another
# while that pid is alive and its command line matches the regex (a reused pid is not), or while the lock has no pid
# and is under a minute old. A stale lock is renamed away under a unique name and checked before it is dropped, so a
# lock another run took in between is put back. Returns 0 taken, 1 held by another.
take_mkdir_lock() {
  local d="$1" re="$2" p moved
  mkdir -p "$(dirname "$d")" 2>/dev/null
  if ! mkdir "$d" 2>/dev/null; then
    p="$(cat "$d/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { ! ps -p "$p" -o args= >/dev/null 2>&1 || ps -p "$p" -o args= 2>/dev/null | grep -qE -- "$re"; }; then return 1; fi
    if [ -z "$p" ] && [ -n "$(find "$d" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then return 1; fi
    moved="$d.stale.$$.$RANDOM"
    mv "$d" "$moved" 2>/dev/null || return 1
    if [ "$(cat "$moved/pid" 2>/dev/null || true)" != "$p" ]; then mv "$moved" "$d" 2>/dev/null || rm -rf -- "${moved:?}"; return 1; fi
    rm -rf -- "${moved:?}"
    mkdir "$d" 2>/dev/null || return 1
  fi
  { printf '%s\n' "$$" > "$d/pid.$$" && mv "$d/pid.$$" "$d/pid"; } 2>/dev/null
  [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ]
}
RESUME_LOCK="$CM_HOME/resume.lock"; HAVE_RLOCK=0
if [ "$MODE" = lead ]; then LOCK="$STORE.lock"; else LOCK="$CM_HOME/lane-health.lock"; fi
# one writing run per record (the ledger for --all, one cache file per lead), taken BEFORE the record is read: a plain
# recording pass that overlapped an acting pass would write its older copy of the one-try count back. Leads on this host
# each hold their own, so they never block the tick; creates and kills are serialised by resume.lock instead.
if [ "$NOWRITE" = 0 ] && { [ "$ACT" = 1 ] || [ "$MODE" = all ] || [ "$MODE" = lead ] || [ "$APPLY" = 1 ]; }; then
  take_mkdir_lock "$LOCK" 'lane-health' || { cm_warn "lane-health.sh: another run holds $LOCK: nothing done"; exit 4; }
  HAVE_LOCK=1
fi
if [ -s "$STORE" ] && jq -e 'type == "object"' "$STORE" >/dev/null 2>&1; then cp "$STORE" "$TMP/store.json"; else echo '{"workers":{}}' > "$TMP/store.json"; fi
# others_acting: why a create or a kill must not happen now. While acting this run holds resume.lock itself
# (resume.sh and the cutover scripts then stand down), so only a cutover can still be in the way.
others_acting() {
  if [ "$HAVE_RLOCK" = 0 ] && cm_resume_lock_held; then echo "resume.sh is running"; return 0; fi
  if [ -d "$CM_HOME/cutover-host.lock" ]; then echo "a cutover is running"; return 0; fi
  return 1
}
owns_locks() { # every create or kill re-checks that both locks are still this run's
  [ "$HAVE_RLOCK" = 1 ] && [ "$(cat "$RESUME_LOCK/pid" 2>/dev/null)" = "$$" ] \
    && { [ "$HAVE_LOCK" = 0 ] || [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; }
}
take_resume_lock() { # held for the whole acting phase: resume.sh never creates beside us, nor we beside it
  [ "$HAVE_RLOCK" = 1 ] && return 0
  take_mkdir_lock "$RESUME_LOCK" 'resume[.-]|lane-health' || return 1
  HAVE_RLOCK=1
}

# ---- sessions in scope ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # jq programs below: $x are jq variables
ROWS_JQ="$CM_JQ_STATE_DEFS $CM_JQ_NORMP"'
  [ (.workers // {}) | to_entries[] | select(.value | type == "object")
    | select((.value.state // "running") | cm_state_dead | not)
    | .key as $id | .value as $w
    | { id: $id, host: (($w.host // "local") | tostring),
        path: (($w.path // $w.worktree // $w.worktreePath // "") | tostring | normp),
        lane: ($w.lane // null), parent: (if ($w.parent | type) == "string" then $w.parent else null end),
        standing: ($w.standing == true), state: (($w.state // "running") | tostring),
        agent: ($w.agent // null), model: ($w.model // null), effort: ($w.effort // null),
        lastComment: ($w.lastComment // null), blockedQuestion: ($w.blockedQuestion // null), task: ($w.current // $w.task // null),
        live: ($w.live // {}), health: ($w.health // {}), resumeAttempts: ($w.resumeAttempts // 0),
        lastStopAt: ($w.lastStopAt // null), lastStopCause: ($w.lastStopCause // null), stopHistory: ($w.stopHistory // []),
        asleepAt: ($w.asleepAt // null) }
    | select(.path | startswith("/")) ]'

lead_rows_from_comment() { # no ledger here: the lead's own `cm:child <name>[@host]` lines, resolved on each host
  local cli top j hosts h
  local -a hs
  cli="$(cm_cli)" || return 1
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  j="$(cm_timeout 30 "$cli" worktree list --json --limit 500 </dev/null 2>/dev/null)"
  printf '%s' "$j" | jq -e '.result.worktrees | type == "array"' >/dev/null 2>&1 || { cm_warn "lane-health.sh --lead: the local worktree list did not answer"; return 1; }
  printf '%s' "$j" | jq -r --arg top "$top" --arg lead "$LEAD" '
    [ .result.worktrees[] | select(.path == $top or (.path | split("/") | last) == $lead or (.displayName // "") == $lead
                                    or ("w-" + (.path | split("/") | last)) == $lead) ] | first | (.comment // "") | gsub("\\\\n"; "\n")
    | split("\n")[] | (capture("^\\s*(cm:[A-Za-z-]+\\s+)?cm:child\\s+[\\[`'"'"'\"]?(?<n>[A-Za-z0-9][A-Za-z0-9._-]*)(@(?<h>[A-Za-z0-9._-]+))?") // empty)
    | "\(.n)\t\((.h // "local") | sub("\\s+$"; ""))"' 2>/dev/null > "$TMP/kids.tsv"
  hosts="$(cut -f2 "$TMP/kids.tsv" | sort -u)"
  echo '[]' > "$TMP/rows.json"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    cm_cli_host_into hs "$h" || continue
    cm_timeout 30 "$cli" worktree list --json --limit 500 ${hs[@]+"${hs[@]}"} </dev/null > "$TMP/wl.json" 2>/dev/null || echo '{}' > "$TMP/wl.json"
    jq -c --arg h "$h" --arg lead "$LEAD" --rawfile kids "$TMP/kids.tsv" '
      (.result.worktrees // []) as $w
      | [ $kids | split("\n")[] | select(length > 0) | split("\t") | select(.[1] == $h) | .[0] as $n
          | ([ $w[] | select((.path | split("/") | last) == $n or (.displayName // "") == $n) ] | first) as $r
          | { id: "\($n)@\($h)", host: $h, path: ($r.path // ""), lane: null, parent: $lead, standing: false,
              state: (if (($r.comment // "") | test("^cm:asleep\\b")) then "asleep"
                      elif (($r.comment // "") | test("^cm:(done|retire)\\b")) then "done" else "running" end),
              agent: "claude", model: null, effort: null, lastComment: ($r.comment // null), blockedQuestion: null, task: null,
              live: {}, health: {}, resumeAttempts: 0, lastStopAt: null, lastStopCause: null, stopHistory: [], asleepAt: null,
              missing: ($r == null) } ]' "$TMP/wl.json" > "$TMP/rows.h.json" 2>/dev/null || echo '[]' > "$TMP/rows.h.json"
    jq -s 'add' "$TMP/rows.json" "$TMP/rows.h.json" > "$TMP/rows.n.json" && mv "$TMP/rows.n.json" "$TMP/rows.json"
  done <<< "$hosts"
}

case "$MODE" in
  all|sleep|wake) jq "$ROWS_JQ" "$LEDGER" > "$TMP/rows.json" || { cm_warn "lane-health.sh: cannot read the ledger workers"; exit 1; } ;;
  lead)
    if [ "$HAVE_LEDGER" = 1 ]; then jq --arg lead "$LEAD" "$ROWS_JQ"' | map(select(.parent == $lead))' "$LEDGER" > "$TMP/rows.json"
    else lead_rows_from_comment || exit 1; fi
    # the lead keeps its own record of its children (it never writes the ledger)
    jq --slurpfile S "$TMP/store.json" 'map(. as $r | ($S[0].workers[$r.id] // {}) as $c
        | $r + ($c | {live, health, resumeAttempts, lastStopAt, lastStopCause, stopHistory} | with_entries(select(.value != null))))' \
      "$TMP/rows.json" > "$TMP/rows.n.json" && mv "$TMP/rows.n.json" "$TMP/rows.json" ;;
esac
case "$MODE" in sleep|wake)
  jq -e --arg t "$TARGET" 'any(.[]; .id == $t)' "$TMP/rows.json" >/dev/null 2>&1 || { cm_warn "lane-health.sh $MODE: no live ledger worker \"$TARGET\""; exit 1; }
  jq --arg t "$TARGET" 'map(select(.id == $t))' "$TMP/rows.json" > "$TMP/rows.n.json" && mv "$TMP/rows.n.json" "$TMP/rows.json" ;;
esac

# hosts: every host a live session in scope lives on; --all and wake add every host the CLI lists (an unknown session, or
# a second copy of the session being woken, can be anywhere). health.ignore_hosts (hosts gone for good) are never read.
jq -r '.[] | select(.state | IN("retired", "done", "teardown") | not) | .host' "$TMP/rows.json" > "$TMP/hosts.txt"
if [ "$MODE" = all ] || [ "$MODE" = wake ]; then
  echo local >> "$TMP/hosts.txt"
  if CLI0="$(cm_cli)"; then
    cm_timeout 30 "$CLI0" host list --json </dev/null 2>/dev/null \
      | jq -r '.result.hosts[]? | if (.kind // "") == "local" or .name == "this machine" then "local" else (.name // empty) end' >> "$TMP/hosts.txt" 2>/dev/null || true
  fi
fi
IGNORE_HOSTS="${CM_HEALTH_IGNORE_HOSTS-$(cm_cfg .health.ignore_hosts)}"
sort -u "$TMP/hosts.txt" | grep -v '^$' | while IFS= read -r h; do
  case " $IGNORE_HOSTS " in *" $h "*) ;; *) printf '%s\n' "$h" ;; esac
done > "$TMP/hosts.u" || true

# ---- probe every host ----------------------------------------------------------------------------
i=0; : > "$TMP/hostfiles"
while IFS= read -r h; do
  i=$((i + 1))
  paths=()
  while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(jq -r --arg h "$h" '.[] | select(.host == $h and .path != "") | .path' "$TMP/rows.json")
  probe_host "$h" "$TMP/probe-$i" ${paths[@]+"${paths[@]}"}
  printf '%s\n' "$TMP/probe-$i.json" >> "$TMP/hostfiles"
done < "$TMP/hosts.u"
if [ -s "$TMP/hostfiles" ]; then xargs jq -s '.' < "$TMP/hostfiles" > "$TMP/hosts.json"; else echo '[]' > "$TMP/hosts.json"; fi

# ---- panes: every agent we judge (a matched session, or an in-scope unknown in --all) -------------
PATHRE="$CM_PATH_MATCH"
jq -r --slurpfile R "$TMP/rows.json" --arg mode "$MODE" --arg re "$PATHRE" '
  def under($p): . as $c | ($p | length) > 0 and ($c == $p or ($c | startswith($p + "/")));
  .[] | select(.ok) | .host as $h | .procs[] | . as $p
  | select((any($R[0][]; .path as $rp | .host == $h and ($p.cwd | under($rp)))) or ($mode == "all" and $re != "" and ($p.cwd | test($re))))
  | select(.handle != null) | [$h, (.pid | tostring), (.runtime // "-"), .handle] | @tsv' "$TMP/hosts.json" > "$TMP/panes.tsv" 2>/dev/null || : > "$TMP/panes.tsv"
: > "$TMP/panes.ndjson"
while IFS=$'\t' read -r ph ppid prt phd; do
  [ -n "$ph" ] || continue
  if b="$(pane_bottom "$ph" "$prt" "$phd")"; then
    st="$(pane_state "$b")"
    jq -nc --arg k "$ph|$ppid" --arg s "${st%%$'\t'*}" --arg l "${st#*$'\t'}" '{($k): {state: $s, line: ($l | .[0:120])}}' >> "$TMP/panes.ndjson"
  else
    jq -nc --arg k "$ph|$ppid" '{($k): {state: "unread", line: ""}}' >> "$TMP/panes.ndjson"
  fi
done < "$TMP/panes.tsv"
jq -s 'add // {}' "$TMP/panes.ndjson" > "$TMP/panes.json"

# ---- last task line: the first line of each worktree comment (the ledger copy when the host list does not answer) ---
: > "$TMP/comments.ndjson"; : > "$TMP/claims.ndjson"; : > "$TMP/comments-read.txt"; : > "$TMP/dnames.ndjson"
# host aliases for claims: every ledger host by its own name and its hostname, and this machine's hostname -s as local
HOST_ALIASES="$(jq -c --arg me "$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" \
  '((.hosts // {}) | to_entries | map({key: (.key | ascii_downcase), value: .key}, (select((.value.hostname | type) == "string") | {key: (.value.hostname | ascii_downcase | split(".")[0]), value: .key})))
   + (if $me != "" then [{key: $me, value: "local"}] else [] end) | from_entries' "$TMP/store.json" 2>/dev/null || echo '{}')"
if [ "${CM_HEALTH_NO_COMMENTS:-}" != 1 ] && CLI0="$(cm_cli)"; then
  REPO_SEL=(); ORCA_REPO="$(cm_cfg .worktrees.orca_repo)"; [ -z "$ORCA_REPO" ] || REPO_SEL=(--repo "name:$ORCA_REPO")
  while IFS= read -r h; do
    cm_cli_host_into HS "$h" || continue
    cm_timeout 30 "$CLI0" worktree list --json ${REPO_SEL[@]+"${REPO_SEL[@]}"} --limit 500 ${HS[@]+"${HS[@]}"} </dev/null > "$TMP/wl.$$.json" 2>/dev/null || continue
    jq -e '.result.worktrees | type == "array"' "$TMP/wl.$$.json" >/dev/null 2>&1 || continue
    printf '%s\n' "$h" >> "$TMP/comments-read.txt"
    jq -c --arg h "$h" "$CM_JQ_NORMP"'[.result.worktrees[]? | select((.path | type) == "string")
          | {key: "\($h)|\(.path | normp)", value: ((.comment // "") | gsub("\\\\n"; "\n") | split("\n")[0] | .[0:160])}] | from_entries' \
      "$TMP/wl.$$.json" >> "$TMP/comments.ndjson" 2>/dev/null || true
    # every `cm:child <name>[@host]` line on this host: {name, host, by}. `@local` means the host the comment is on; any
    # other name is mapped to its ledger host through HOST_ALIASES (an Orca name, a hostname -s, this machine's own name)
    jq -c --arg h "$h" --argjson al "$HOST_ALIASES" '.result.worktrees[]? | select((.path | type) == "string") | (.path | split("/") | last) as $by
          | (.comment // "") | gsub("\\\\n"; "\n") | split("\n")[]
          | (capture("^\\s*(cm:[A-Za-z-]+\\s+)?cm:child\\s+[\\[`'"'"'\"]?(?<n>[A-Za-z0-9][A-Za-z0-9._-]*)(@(?<o>[A-Za-z0-9._-]+))?") // empty)
          | {name: (.n | ascii_downcase), host: (if (.o // "local") == "local" then $h else ($al[.o | ascii_downcase] // .o) end), by: $by}' "$TMP/wl.$$.json" >> "$TMP/claims.ndjson" 2>/dev/null || true
    # displayName of each worktree: a lead may write that name on its cm:child line
    jq -c --arg h "$h" "$CM_JQ_NORMP"'[.result.worktrees[]? | select((.path | type) == "string" and (.displayName | type) == "string")
          | {key: "\($h)|\(.path | normp)", value: (.displayName | ascii_downcase)}] | from_entries' "$TMP/wl.$$.json" >> "$TMP/dnames.ndjson" 2>/dev/null || true
  done < "$TMP/hosts.u"
fi
jq -s 'add // {}' "$TMP/comments.ndjson" > "$TMP/comments.json"
# every host (in scope) whose comment list did not answer, or all of them with CM_HEALTH_NO_COMMENTS=1: a cm:child claim
# there may be unread, so a parentless worker is not resumed or slept this pass (its lead may be resuming it)
# unread counts only hosts that hold a live ledger worker or a lead: a lead that could claim a worker lives there
jq -r '.[] | select(.standing or (.state | IN("retired", "done", "teardown", "asleep", "queued") | not)) | .host' "$TMP/rows.json" | sort -u > "$TMP/hosts.live"
jq -s --arg self "$CM_SELF_WORKTREE" --rawfile read "$TMP/comments-read.txt" --rawfile all "$TMP/hosts.u" --rawfile live "$TMP/hosts.live" --slurpfile dn <(jq -s 'add // {}' "$TMP/dnames.ndjson") \
  'def lines: split("\n") | map(select(length > 0));
   {claims: map(select(.by != $self)), dnames: $dn[0],
    unread: (($all | lines) - ($read | lines) | map(select(. as $h | ($live | lines) | index($h))))}' \
  "$TMP/claims.ndjson" > "$TMP/claims.json" 2>/dev/null || jq -n --rawfile all "$TMP/hosts.u" '{claims: [], dnames: {}, unread: ($all | split("\n") | map(select(length > 0)))}' > "$TMP/claims.json"

# resume markers: an attempt is written to disk right after its create, so a run killed before the store write still counts it
MARKS="$CM_HOME/cache/lane-health-attempts"
[ "$NOWRITE" = 1 ] || [ ! -d "$MARKS" ] || find "$MARKS" -maxdepth 1 -type f -mmin +$((RESET_H * 120 + 60)) -exec rm -f -- {} + 2>/dev/null || true
: > "$TMP/marks.ndjson"
for f in "$MARKS"/*; do
  [ -f "$f" ] || continue
  k="$(sed -n 1p "$f")"; t="$(sed -n 2p "$f")"
  isint "$t" && jq -nc --arg k "$k" --argjson t "$t" '{($k): $t}' >> "$TMP/marks.ndjson"
done
jq -s 'add // {}' "$TMP/marks.ndjson" > "$TMP/marks.json"

# every standing ledger worker, whatever its path looks like: an unknown process on one of these is never slept
if [ "$HAVE_LEDGER" = 1 ]; then
  jq '[(.workers // {}) | to_entries[] | select(.value | type == "object") | select(.value.standing == true)] as $s
      | {names: [$s[] | ((.value.path // .value.worktree // "") | tostring | split("/") | last // "" | ascii_downcase), (.key | ascii_downcase), (.key | ascii_downcase | ltrimstr("w-"))] | map(select(length > 0)) | unique,
         sids: [$s[] | .value.live.sessionId // empty | strings] | unique}' "$LEDGER" > "$TMP/standing.json" 2>/dev/null || echo '{"names":[],"sids":[]}' > "$TMP/standing.json"
else echo '{"names":[],"sids":[]}' > "$TMP/standing.json"; fi

# ---- classify -----------------------------------------------------------------------------------
# shellcheck disable=SC2016  # a jq program
CLASSIFY_JQ="$CM_JQ_NORMP"'
def nn: if . == null or . == "" then null else . end;
def num: if . == null or . == "" then null elif type == "number" then . else (tostring | tonumber? // null) end;
def iso: if . == null then null else (floor | todate) end;
def ep: if . == null then null elif type == "number" then . else (tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) end;
def under($p): . as $c | ($p | length) > 0 and ($c == $p or ($c | startswith($p + "/")));
def absv: if . < 0 then -. else . end;
def base: split("/") | map(select(length > 0)) | last // "";
def hhmm: if . == null then "?" else (localtime | strflocaltime("%H:%M")) end;
def healthyw: IN("running", "idle", "waiting on you");
def markof: {"running": "●", "idle": "○", "waiting on you": "?", "stuck": "⚠", "stopped": "✗", "asleep": "z", "unknown": "·"}[.] // "·";
def shouldrun: IN("asleep", "retired", "done", "teardown", "queued") | not;
def leadlike($n): ($n | ascii_downcase) as $l | (($laneNames | index($l)) != null) or ($l | test($laneRe)) or ($l == ($self | ascii_downcase));
$ST[0].names as $standingNames | $ST[0].sids as $standingSids
| $S[0] as $store | $RW[0] as $rows | $HS[0] as $hosts | $PN[0] as $panes | $CO[0] as $comments | $MK[0] as $marks
| ($store.health.alerted // {}) as $alerted
| ($rows | map({key: .id, value: .}) | from_entries) as $byId
| ([ $rows[] | select(.live.sessionId != null) | {sid: .live.sessionId, id} ] | group_by(.sid) | map(select(length > 1)) | map({key: .[0].sid, value: map(.id)}) | from_entries) as $rowSid
| ($hosts | map(. as $h | ($h.facts.boot | num) as $boot
     | ([($h.daemons // [])[] | select(.at != null and ($boot == null or .at > $boot + 120)) | .at] | max) as $dat
     | {key: $h.host, value: ($h + {boot: $boot, daemonAt: $dat,
          preempted: ((($h.facts.preempted // "") | ascii_upcase) == "TRUE" or (($h.facts.powerkey // "") != "")),
          spot: ((($h.facts.spot // "") | ascii_upcase) == "SPOT"),
          settled: ($h.ok and ($boot == null or ($now - $boot) >= $settle * 60) and ($dat == null or ($now - $dat) >= $settle * 60))})})
   | from_entries) as $H
| [ $hosts[] | select(.ok) | .host as $hn | .procs as $all | (.headless // []) as $hl | .procs[]
    # /clear starts a new session in the same process while the cmdline keeps the old id: take the newest
    # transcript instead, only when this is the one agent in that cwd and the file was written after it started
    | . as $q
    | (if ($q.sidsrc == "cmdline" or $q.sid == null) and $q.nsid != null and $q.nsid != $q.sid and $q.nmt != null and $q.start != null
          and $q.nmt > $q.start and ($q.sid == null or $q.nmt > ($q.tmtime // 0)) and ([$all[] | select(.cwd == $q.cwd)] | length) == 1
          and ([$hl[] | select(.cwd == $q.cwd)] | length) == 0
       then . + {sid: $q.nsid, sidsrc: "newest-transcript", tmtime: $q.nmt} else . end)
    | . + {host: $hn, key: "\($hn)|\(.pid)", pane: ($panes["\($hn)|\(.pid)"] // {state: "unread", line: ""})}
    | . as $p | ([ $rows[] | .path as $rp | select(.host == $p.host and ($p.cwd | under($rp))) ]
                 | max_by([(.path | length), (if (.state | IN("retired", "done", "teardown")) then 0 else 1 end)])) as $r
    | . + {row: ($r.id // null)} ] as $P
| ([ ($P[] | select(.sid != null) | {sid, at: "\(.host):\(.pid)"}),
     ($hosts[] | select(.ok) | .host as $hn | (.headless // [])[] | select(.sid != null) | {sid, at: "\($hn):headless"}) ]
   | group_by(.sid) | map(select(length > 1)) | map({key: .[0].sid, value: map(.at)}) | from_entries) as $sidDup
# a headless agent under the worktree of a row is a copy of it too
| ([ $hosts[] | select(.ok) | .host as $hn | (.headless // [])[] | {host: $hn, cwd} ]) as $HL
| $CL[0].claims as $claims | $CL[0].unread as $unread | ($CL[0].dnames // {}) as $dnames
| def claimant($r): ($r.path | split("/") | last // "" | ascii_downcase) as $n | ($dnames["\($r.host)|\($r.path)"] // $n) as $dn
    | [ $claims[] | select((.name == $n or .name == $dn) and .host == $r.host and (.by | ascii_downcase) != $n) | .by ] | first;
  def owned($r): $mode == "lead" or (($r.parent == null or ($byId[$r.parent] == null)) and claimant($r) == null);
  # a parentless worker (never a lead) may be a cm:child of some lead on a host whose comments were not read
  def claimsunread($r): $mode == "all" and ($r.standing | not) and ($r.parent == null) and ($unread | length) > 0;
  def cause($h; $lt; $ph):
    if $lt != null and $h.boot != null and $h.boot > $lt then (if $h.preempted then "preemption" else "reboot" end)
    elif $lt != null and $h.daemonAt != null and $h.daemonAt > $lt then "daemon restart"
    elif (($ph.paneState // "") == "limit") then "limit"
    elif $lt == null then "unknown" else "crash" end;
  def causetext($c; $h; $rt):
    if $c == "reboot" then "the server restarted at \($h.boot | hhmm) and this one did not come back"
    elif $c == "preemption" then "the cloud provider stopped the server (Spot preemption) at \($h.boot | hhmm) and this one did not come back"
    elif $c == "daemon restart" then "the \($rt // "terminal") daemon restarted at \($h.daemonAt | hhmm) and this one did not come back"
    elif $c == "limit" then "it stopped on an account usage limit"
    elif $c == "crash" then "the process ended with no restart seen since its last write"
    else "no record of its last write, cause unknown" end;
[ $rows[] | . as $r
  | ($H[$r.host] // {ok: false, error: "not checked"}) as $h
  | [ $P[] | select(.row == $r.id) ] as $mine
  | ([ $HL[] | select(.host == $r.host and (.cwd | under($r.path))) ] | length) as $hcount
  | ($r.health // {}) as $ph | ($r.live // {}) as $pl
  | (($h.trans // {})[$r.path] // {}) as $tr
  | ($mine | length) as $n
  | (if $n == 1 then $mine[0] else null end) as $p
  | $r.state as $st
  | ((($comments["\($r.host)|\($r.path)"] // null) | nn) // (($r.lastComment // "") | tostring | split("\n")[0] | nn) // $r.task) as $task
  | (if $p != null then
       {host: $r.host, runtime: ($p.runtime // $pl.runtime // null), pid: $p.pid,
        # a recorded id is carried only for the SAME process: a new process (a --continue resume, a respawn) may be on
        # another session, and resuming the old id would bring back the wrong conversation
        sessionId: ($p.sid // (if $pl.pid == $p.pid then $pl.sessionId else null end) // null),
        sessionSource: (if $p.sid != null then $p.sidsrc elif $pl.pid == $p.pid then ($pl.sessionSource // null) else null end), handle: $p.handle,
        model: ($p.model // $pl.model // $r.model), effort: ($p.effort // $pl.effort // $r.effort), agent: ($p.agent // $pl.agent // $r.agent),
        lastTranscriptAt: (($p.tmtime // ($pl.lastTranscriptAt | ep)) | iso), checkedAt: ($now | iso)}
     elif $h.ok and ($h.incomplete | not) and $n == 0 then
       $pl + {host: $r.host, pid: null, handle: null, checkedAt: ($now | iso),
              sessionId: ($pl.sessionId // ($tr.single | nn)), sessionSource: ($pl.sessionSource // (if $tr.single != null then "transcript" else null end)),
              model: ($pl.model // $r.model), effort: ($pl.effort // $r.effort), agent: ($pl.agent // $r.agent),
              lastTranscriptAt: ([($pl.lastTranscriptAt | ep), ($tr.mtime | num)] | map(select(. != null)) | max | iso)}
     else $pl end) as $live
  | ($live.lastTranscriptAt | ep) as $lt
  | (if $p != null then $p.pane.state else null end) as $ps
  | (if $ps != null and $ps == ($ph.paneState // null) and ($ph.paneSince | ep) != null then $ph.paneSince else ($now | iso) end) as $paneSince
  | (($now - ($paneSince | ep)) // 0) as $paneAge
  | ((($task // "") | tostring | test("^cm:(blocked|waiting-owner|ask)\\b")) or $st == "blocked-on-owner") as $asks
  | (($st | shouldrun) and ((($task // "") | tostring | test("^cm:(done|retire)\\b")) | not)) as $should
  | (if ($h.ok | not) then {w: "unknown", keep: true, m: "host \($r.host) did not answer\(if $h.error then " (" + ($h.error | tostring | .[0:80]) + ")" else "" end): not checked, and nothing is moved to another host"}
     elif ($r.missing // false) then {w: "unknown", keep: true, m: "listed as a child, but no worktree of that name answers on \($r.host)"}
     elif $n >= 2 then {w: "waiting on you", dup: true, m: "two copies are running here (pids \($mine | map(.pid | tostring) | join(", "))): pick the one that keeps going; nothing was touched"}
     elif $n == 0 and $hcount > 0 and ($st | IN("asleep") | not) then {w: "unknown", keep: true, m: "an agent with no terminal runs in this worktree: not judged, never resumed beside it"}
     elif $p != null and $p.sid != null and (($sidDup[$p.sid] // []) | length) > 1 then
       {w: "waiting on you", dup: true, m: "two copies of session \($p.sid | .[0:8]) are running (\($sidDup[$p.sid] | join(", "))): pick the one that keeps going; nothing was touched"}
     elif $p != null then
       (if ($st | IN("retired", "done", "teardown")) then {w: "unknown", back: true, m: "\($st) work came back (pid \($p.pid))"}
        elif $ps == "limit" then {w: "stuck", sk: "limit", m: "account limit on screen\(if ($p.pane.line | test("reset"; "i")) then ": " + ($p.pane.line | .[0:70]) else "" end); the check never answers it"}
        elif $ps == "error" then {w: "stuck", sk: "error", m: "an error is on screen: \($p.pane.line | .[0:70])"}
        elif $ps == "menu" then
          (if $paneAge >= $stuckMin * 60 then {w: "stuck", sk: "menu", m: "a question menu has waited \($paneAge / 60 | floor) min\(if ($p.pane.line // "") != "" then ": " + ($p.pane.line | .[0:60]) else "" end)"}
           else {w: "waiting on you", m: "a question menu is open\(if ($p.pane.line // "") != "" then ": " + ($p.pane.line | .[0:60]) else "" end)"} end)
        elif $ps == "busy" then {w: "running"}
        elif $asks then {w: "waiting on you", m: "it asks: \(($r.blockedQuestion // $task // "see its comment") | tostring | .[0:80])"}
        elif $lt != null and ($now - $lt) <= $runningS then {w: "running"}
        else {w: "idle", m: (if $ps == "shell" then "the pane shows a shell prompt; its handle may be stale"
                            elif ($ps // "unread") | IN("unread", "other") then "fine, nothing to do (pane not read; judged by its transcript)"
                            else "fine, nothing to do" end)} end)
       | if $st == "asleep" then .m = "marked asleep, but a process runs here (pid \($p.pid)); " + (.m // "awake") else . end
     elif ($h.incomplete // false) then {w: "unknown", keep: true, m: "the process scan on \($r.host) was incomplete: not judged, never resumed"}
     elif $st == "asleep" then {w: "asleep", m: "put to sleep on purpose\(if ($r.asleepAt | ep) != null then " at " + ($r.asleepAt | ep | hhmm) else "" end); never resumed by the check or a reboot"}
     elif $should then {w: "stopped"}
     else null end) as $v
  | select($v != null)
  | ($ph.word // null) as $pw
  | (if $v.w == "stopped" then
       (if $pw == "stopped" then {at: ($r.lastStopAt // ($now | iso)), cause: ($r.lastStopCause // cause($h; $lt; $ph)), fromHealthy: ($ph.stopFromHealthy // false), fresh: false}
        else {at: ($now | iso), cause: cause($h; $lt; $ph), fromHealthy: ($pw != null and ($pw | healthyw)), fresh: true} end)
     else null end) as $epi
  | (if $epi != null and $epi.fresh then
       (if ($ph.healthySince | ep) != null and ($now - ($ph.healthySince | ep)) >= $resetH * 3600 then 0 else ($r.resumeAttempts // 0) end)
     else ($r.resumeAttempts // 0) end) as $att0
  | (if $epi != null and ($marks[$r.id] // null) != null and ($marks[$r.id] > $now - $resetH * 3600) then ([$att0, 1] | max) else $att0 end) as $att
  | ($live.sessionId // null) as $sid
  | (if $v.w != "stopped" then null
     elif $pw == null and ($epi.fromHealthy | not) then "no health record from before it stopped, so it is not resumed automatically: have a look"
     elif ($epi.fromHealthy | not) then "it was not healthy before it stopped, so it is not resumed: have a look"
     elif $att >= 1 then "retry 1 already used\(if ($ph.lastResumeAt | ep) != null then " at " + ($ph.lastResumeAt | ep | hhmm) else "" end), it did not stay up: needs a hand"
     elif (owned($r) | not) then "its lead \($r.parent // claimant($r)) resumes it"
     elif claimsunread($r) then "the worktree comments of \($unread | join(", ")) were not read (a lead there may own it): not resumed this pass"
     elif $sid == null then "no session id recorded: resume it by hand"
     elif ($live.agent // null) == null then "agent unknown in the ledger: resume it by hand"
     elif $live.agent != "claude" then "agent \($live.agent): resume it by hand"
     elif ($h.settled | not) then "waiting \($settle) min for the server\u0027s own resume to settle, then I retry once"
     elif any($P[]; .sid == $sid) or any($hosts[] | select(.ok) | (.headless // [])[]; .sid == $sid) then "session \($sid | .[0:8]) already runs somewhere else"
     elif (($rowSid[$sid] // []) | length) > 1 then "ledger rows \($rowSid[$sid] | join(", ")) share session \($sid | .[0:8]): resume one by hand"
     else "ok" end) as $why
  | ($v + (if $v.w == "stopped" then {m: "\(causetext($epi.cause; $h; $live.runtime)); \(if $why == "ok" then "I will retry once" else $why end)"} else {} end)) as $v
  | { key: $r.id, rowId: $r.id, name: (if $r.path == "" then ($r.id | split("@")[0]) else ($r.path | base) end), host: $r.host, path: $r.path, lane: $r.lane, parent: $r.parent,
      isLead: $r.standing, state: $st, word: $v.w, mark: ($v.w | markof), meaning: ($v.m // null), dup: ($v.dup // false),
      stuckKind: ($v.sk // null), task: $task, live: $live, pids: ($mine | map(.pid)),
      cause: ($epi.cause // null), resume: ($why == "ok"), resumeWhy: $why, attempts: $att, paneAge: $paneAge,
      sleep: false, sleepWhy: null,
      store: { live: $live,
               kind: (if $st == "asleep" then "asleep" elif ($st | IN("retired", "done", "teardown")) then "retired" elif $r.standing then "standing" else "worker" end),
               shouldRun: $should, lastTask: $task,
               resumeAttempts: $att,
               lastStopAt: (if $epi != null then $epi.at else $r.lastStopAt end),
               lastStopCause: (if $epi != null then $epi.cause else $r.lastStopCause end),
               stopHistory: (if $epi != null and $epi.fresh then (($r.stopHistory // []) + [{at: $epi.at, cause: $epi.cause}]) | .[-10:] else ($r.stopHistory // []) end),
               health: (if ($v.keep // false) then ($ph + {lastUnjudgedAt: ($now | iso), unjudgedWhy: ($v.m // null)})
                        else (($ph | {lastResumeAt}) + {word: $v.w, meaning: ($v.m // null), paneState: $ps, paneSince: (if $ps != null then $paneSince else null end),
                         stopFromHealthy: (if $epi != null then $epi.fromHealthy else null end),
                         healthySince: (if ($v.w | healthyw) then (if (($pw // "") | healthyw) and $ph.healthySince != null then $ph.healthySince else ($now | iso) end) else null end),
                         checkedAt: ($now | iso)}) end) } } ] as $rowS
# unknown sessions: an agent in this project that no live ledger worker holds (--all only, path_match required)
| (if $mode != "all" or $pathRe == "" then [] else
    [ $P[] | select(.row == null) | select(.cwd | test($pathRe)) | . + {wt: (.top // .cwd)} ]
    | map(select((.wt | base) as $b | ($neverTouch | index($b)) == null))
    | group_by("\(.host)|\(.wt)")
    | map(. as $g | $g[0] as $p | ($p.wt | base) as $name | ($g | length) as $n
        | (leadlike($name) or ($standingNames | index($name | ascii_downcase)) != null
           or ($p.sid != null and ($standingSids | index($p.sid)) != null)) as $ll
        | (if $p.tmtime == null then null else ($now - $p.tmtime) end) as $idle
        | (if $n >= 2 then "two copies are running here: pick the one that keeps going"
           elif $ll then "looks like a lead (\($name)): never slept; ask the owner whether it belongs in the ledger"
           elif $p.sid != null and (($sidDup[$p.sid] // []) | length) > 1 then "its session \($p.sid | .[0:8]) also runs elsewhere (\($sidDup[$p.sid] | join(", "))): two copies, nothing touched"
           elif ([ $claims[] | select(.name == ($name | ascii_downcase) and .host == $p.host) ] | length) > 0 then "a lead claims it (cm:child in \([ $claims[] | select(.name == ($name | ascii_downcase) and .host == $p.host) | .by ] | first)): left to that lead"
           elif ($unread | length) > 0 then "the worktree comments of \($unread | join(", ")) were not read (a lead there may own it)"
           elif $p.sid == null then "no session id, so it could not be woken again"
           elif $idle == null then "its last write is unknown"
           elif ($p.pane.state // "") == "busy" then "mid-turn"
           elif $p.dirty == null or $p.merged == null then "git state not readable"
           elif $p.dirty > 0 then "\($p.dirty) uncommitted change(s)"
           elif $p.merged != "1" then "branch not merged"
           elif $p.onMain == "1" then "no work of its own on the branch (HEAD is on the main line)"
           elif $idle < $unknownIdleMin * 60 then "transcript written \($idle / 60 | floor) min ago"
           else "ok" end) as $why
        | { key: "u:\($p.host):\($p.wt)", rowId: null, adoptId: null, name: $name, host: $p.host, path: $p.wt, lane: null, parent: null,
            isLead: false, unknown: true, leadLike: $ll, state: null, word: (if $n >= 2 then "waiting on you" else "unknown" end),
            mark: (if $n >= 2 then "?" else "·" end), dup: ($n >= 2 or ($p.sid != null and (($sidDup[$p.sid] // []) | length) > 1)),
            meaning: (if $n >= 2 then "not in the ledger, and \($why) (pids \($g | map(.pid | tostring) | join(", ")))"
                      elif $why == "ok" then "not in the ledger; branch merged and tree clean: put to sleep"
                      elif $ll then "not in the ledger and \($why)"
                      else "not in the ledger; not slept: \($why)" end),
            task: null, pids: ($g | map(.pid)), resume: false, sleep: ($why == "ok" and $n == 1), sleepWhy: $why,
            live: {host: $p.host, runtime: $p.runtime, pid: $p.pid, sessionId: $p.sid, sessionSource: $p.sidsrc, handle: $p.handle,
                   model: $p.model, effort: $p.effort, agent: $p.agent, lastTranscriptAt: ($p.tmtime | iso), checkedAt: ($now | iso)},
            branch: $p.branch } )
    # one adopt id each, unique against EVERY ledger key (dead records too) and within this pass
    | reduce .[] as $u ({out: [], used: $allKeys};
        . as $st
        | ("w-" + ($u.name | gsub("[^A-Za-z0-9._-]"; "-"))) as $ab
        | ([$ab, "\($ab)-\($u.host)"] + [range(2; 50) | "\($ab)-\($u.host)-\(.)"] | map(select(. as $c | ($c | test("\\A[A-Za-z0-9._-]+\\z")) and (($st.used | index($c)) == null))) | first) as $id
        | .out += [$u + {adoptId: $id, sleep: ($u.sleep and $id != null)}] | .used += [$id])
    | .out end) as $unk
# retired rows that came back are judged like unknowns for the sleep rule
| ($rowS | map(if (.word == "unknown" and (.state // "" | IN("retired", "done", "teardown")) and (.pids | length) == 1) then
      (.pids[0]) as $pid | .host as $sh | ([$P[] | select(.host == $sh and .pid == $pid)] | first) as $p
      | (if $p == null then . else
          .name as $nm
          | ((leadlike($nm)) or .isLead or ($standingNames | index($nm | ascii_downcase)) != null
           or ($p.sid != null and ($standingSids | index($p.sid)) != null)) as $ll
          | (if $ll then "looks like a lead: never slept; ask the owner"
             elif ($neverTouch | index($nm)) != null then "in worktrees.never_touch: never touched"
             elif ($nm | ascii_downcase) as $sn | ([ $claims[] | select(.name == $sn and .host == $sh) ] | length) > 0 then "a lead claims it: left to that lead"
             elif ($unread | length) > 0 then "the worktree comments of \($unread | join(", ")) were not read (a lead there may own it)"
             elif .dup then "two copies: nothing touched"
             elif $p.sid == null then "no session id, so it could not be woken again"
             elif $p.tmtime == null then "its last write is unknown"
             elif ($p.pane.state // "") == "busy" then "mid-turn"
             elif $p.dirty == null or $p.merged == null then "git state not readable"
             elif $p.dirty > 0 then "\($p.dirty) uncommitted change(s)"
             elif $p.merged != "1" then "branch not merged"
             elif $p.onMain == "1" then "no work of its own on the branch (HEAD is on the main line)"
             elif (($now - ($p.tmtime // 0))) < $unknownIdleMin * 60 then "transcript written \((($now - ($p.tmtime // 0)) / 60) | floor) min ago"
             else "ok" end) as $why
          | . + {leadLike: $ll, sleep: ($why == "ok"), sleepWhy: $why,
                 meaning: (.meaning + (if $why == "ok" then "; branch merged and tree clean: put to sleep" else "; not slept: " + $why end))} end)
    else . end)) as $rowS
# host events: a boot (reboot or preemption) and a daemon restart after boot, each recorded once
| ($store.hostEvents // []) as $prevEv
| [ $H[] | select(.ok) | . as $h
    | (if $h.boot != null then [{host: $h.host, at: ($h.boot | iso), kind: (if $h.preempted then "preemption" else "reboot" end),
          evidence: ("boot \($h.facts.uptime_s // ($h.boot | iso))" + (if ($h.facts.lastx // "") != "" then "; last -x: " + ($h.facts.lastx | .[0:160]) else "" end)
                     + (if ($h.facts.powerkey // "") != "" then "; " + ($h.facts.powerkey | .[0:120]) else "" end)
                     + (if ($h.facts.preempted // "") == "TRUE" then "; GCE metadata: preempted" else "" end)),
          watched: ((($store.hosts // {})[$h.host].bootAt | ep) as $pb | $pb != null and (($pb - $h.boot) | absv) > 120)}] else [] end)
      + [ ($h.daemons // [])[] | select(.at != null and ($h.boot == null or .at > $h.boot + 120))
          | {host: $h.host, at: (.at | iso), kind: "daemon-restart", evidence: "\(.unit) active since \(.at | iso)", watched: true} ]
    | .[] | . as $e
    | select(any($prevEv[]; .host == $e.host and ((.kind == $e.kind) or ((.kind | IN("reboot", "preemption")) and ($e.kind | IN("reboot", "preemption"))))
                and (((.at | ep) - ($e.at | ep)) | absv) <= 120) | not)
    | . + {seenAt: ($now | iso)} ] as $newEv
| { generatedAt: ($now | iso), mode: $mode, lead: (if $mode == "lead" then $lead else null end),
    hosts: [ $H[] | {host, ok, error, incomplete: (.incomplete // false), bootAt: (.boot | iso), settled, spot, preempted: (.preempted // false),
                     daemonAt: (.daemonAt | iso)} ],
    sessions: ($rowS + $unk), newEvents: $newEv, hostEvents: (($prevEv + $newEv) | .[-200:]), alertedPrev: $alerted }'

jq -n --slurpfile S "$TMP/store.json" --slurpfile RW "$TMP/rows.json" --slurpfile HS "$TMP/hosts.json" \
  --slurpfile PN "$TMP/panes.json" --slurpfile CO "$TMP/comments.json" --slurpfile MK "$TMP/marks.json" \
  --argjson now "$NOW" --argjson settle "$SETTLE_MIN" --argjson stuckMin "$STUCK_MIN" --argjson runningS "$RUNNING_S" \
  --argjson resetH "$RESET_H" --argjson unknownIdleMin "$UNKNOWN_IDLE_MIN" --arg mode "$MODE" --arg lead "$LEAD" \
  --arg pathRe "$PATHRE" --argjson neverTouch "$NEVER_TOUCH" --argjson laneNames "$LANE_NAMES" --arg laneRe "$CM_LANE_SHAPE_RE" \
  --arg self "$SELF" --slurpfile ST "$TMP/standing.json" --slurpfile CL "$TMP/claims.json" --argjson allKeys "$(jq -c '(.workers // {}) | keys' "$TMP/store.json" 2>/dev/null || echo '[]')" "$CLASSIFY_JQ" > "$TMP/doc.json" 2>"$TMP/classify.err" \
  || { cm_warn "lane-health.sh: classify failed: $(head -c 300 "$TMP/classify.err")"; exit 1; }

# ---- actions --------------------------------------------------------------------------------------
: > "$TMP/actions.ndjson"
action() { # <key> <kind> <result> <detail> [json extra]
  local x="${5:-}"; [ -n "$x" ] || x='{}'
  jq -nc --arg k "$1" --arg kind "$2" --arg r "$3" --arg d "$4" --argjson x "$x" '{key: $k, kind: $kind, result: $r, detail: $d} + $x' >> "$TMP/actions.ndjson"
}
procs_on() { # <host-doc> <path> <sid>: count of live agent processes under the path or on the session id
  jq -r --arg p "$2" --arg s "$3" 'def under($p): . as $c | ($p | length) > 0 and ($c == $p or ($c | startswith($p + "/")));
    if .ok and ((.incomplete // false) | not) then [(.procs[], (.headless // [])[]) | select((.cwd | under($p)) or ($s != "" and .sid == $s))] | length else "x" end' "$1" 2>/dev/null
}
agent_bin() { # <host>: the agent binary to launch there
  if [ -n "${CM_HEALTH_AGENT_BIN:-}" ]; then printf '%s\n' "$CM_HEALTH_AGENT_BIN"; return 0; fi
  if [ "$1" = local ]; then cm_timeout 30 "$HERE/spawn-verify.sh" resolve 2>/dev/null; else cm_timeout "$SSH_S" "$HERE/spawn-verify.sh" resolve --ssh "$(cm_ssh_target "$1")" 2>/dev/null; fi
}
mark_attempt() { # <session key>: written BEFORE the create is checked, so a killed run still counts its try
  local f
  mkdir -p "$MARKS" 2>/dev/null || return 0
  f="$MARKS/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s\n%s\n' "$1" "$NOW" > "$f" 2>/dev/null || true
}
# resume_session <key> <host> <path> <sid> <runtime> <model> <effort>: sets RS_OK (1 verified) and RS_WHY
resume_session() {
  local key="$1" host="$2" path="$3" sid="$4" rt="$5" model="$6" eff="$7" bin cmd cli out h waited n bottom tsid why
  local -a hs
  RS_OK=0; RS_WHY=""; RS_HANDLE=""
  if why="$(others_acting)"; then RS_WHY="$why: not resumed this pass"; return; fi
  case "$sid" in ''|-*|*[!A-Za-z0-9._-]*) RS_WHY="session id \"$sid\" is not a plain id"; return ;; esac
  probe_host "$host" "$TMP/re-$$" "$path"
  n="$(procs_on "$TMP/re-$$.json" "$path" "$sid")"
  case "$n" in 0) ;; x) RS_WHY="host stopped answering, or its process scan was incomplete, before the resume: left alone"; return ;; *) RS_WHY="a process appeared here since the check: left alone"; RS_OK=2; return ;; esac
  bin="$(agent_bin "$host" | head -n 1)"
  case "$bin" in /*) ;; *) RS_WHY="no working agent binary found on $host (spawn-verify.sh resolve)"; return ;; esac
  case "$bin" in *[!A-Za-z0-9._/+-]*) RS_WHY="agent binary path \"$bin\" holds characters a terminal command must not carry"; return ;; esac
  cmd="$bin --dangerously-skip-permissions --resume $sid"
  case "$model" in [A-Za-z]*) case "$model" in *[!A-Za-z0-9._-]*) ;; *) cmd="$cmd --model $model" ;; esac ;; esac
  case "$eff" in [a-z]*) case "$eff" in *[!a-z]*) ;; *) cmd="$cmd --effort $eff" ;; esac ;; esac
  cli="$(cli_for "$rt")" || { RS_WHY="no CLI for runtime $rt"; return; }
  cm_cli_host_into hs "$host" || { RS_WHY="bad host $host"; return; }
  owns_locks || { RS_WHY="lost the resume lock before the create: left alone"; return; }
  mark_attempt "$key"
  out="$(cm_timeout 60 "$cli" terminal create --worktree "path:$path" --title resume --command "$cmd" ${hs[@]+"${hs[@]}"} --json </dev/null 2>/dev/null)"
  h="$(printf '%s' "$out" | jq -r '.result.terminal.handle // .result.handle // .result.startupTerminal.handle // empty' 2>/dev/null)"
  case "$h" in ''|-*|*[!A-Za-z0-9._:-]*) RS_WHY="the terminal did not start ($cli terminal create)"; return ;; esac
  RS_HANDLE="$h"
  local t0=$SECONDS
  while :; do
    sleep "$POLL_S"; waited=$((SECONDS - t0))
    probe_host "$host" "$TMP/rv-$$" "$path"
    n="$(jq -r --arg s "$sid" 'if .ok and ((.incomplete // false) | not) then [(.procs[], (.headless // [])[]) | select(.sid == $s)] | length else "x" end' "$TMP/rv-$$.json" 2>/dev/null)"
    tsid="$(jq -r --arg p "$path" 'if .ok then (.trans[$p].newest // "") else "" end' "$TMP/rv-$$.json" 2>/dev/null)"
    bottom="$(pane_bottom "$host" "$rt" "$h" 2>/dev/null || true)"
    if [ "$n" = 1 ] && [ "$tsid" = "$sid" ] && printf '%s\n' "$bottom" | grep -qi 'bypass permissions'; then RS_OK=1; RS_WHY="verified after ${waited}s: one process on $sid, bypass footer, same transcript"; return; fi
    waited=$((SECONDS - t0))
    if [ "$waited" -ge "$VERIFY_S" ]; then
      why=""
      [ "$n" = 1 ] || why="$why${why:+, }$n process(es) on the session id"
      [ "$tsid" = "$sid" ] || why="$why${why:+, }newest transcript is ${tsid:-none}"
      printf '%s\n' "$bottom" | grep -qi 'bypass permissions' || why="$why${why:+, }no bypass footer on the pane"
      RS_WHY="not verified after ${VERIFY_S}s ($why); terminal $h left open, look at it"; return
    fi
  done
}
# mark_comment <host> <path> <on|off> [worker-id]: while a session sleeps its worktree comment starts with a `cm:asleep`
# line, so a lead on a host with no ledger (it reads only comments) never takes a slept child for a stopped one. Best
# Status 1 when the comment could not be read or written: the callers then do not stop the session at all.
# The rest of the comment is kept byte for byte (a literal \n stays as written); the marker line is our own, ended by a
# real newline, and only it is added or taken off. No write when nothing would change.
mark_comment() {
  local host="$1" path="$2" how="$3" id="${4:-}" cli j cur rest new
  local -a hs
  cli="$(cm_cli)" || return 1
  cm_cli_host_into hs "$host" || return 1
  j="$(cm_timeout 30 "$cli" worktree show --worktree "path:$path" ${hs[@]+"${hs[@]}"} --json </dev/null 2>/dev/null)" || return 1
  # a trailing byte keeps the comment's own trailing newlines through the $( )
  cur="$(printf '%s' "$j" | jq -er 'if .ok == true and (.result.worktree | type == "object") then ((.result.worktree.comment // "") | if type == "string" then . else error("comment") end) + "." else error("no worktree") end' 2>/dev/null)" || return 1
  cur="${cur%.}"
  rest="$cur"
  case "$cur" in cm:asleep*) case "$cur" in *$'\n'*) rest="${cur#*$'\n'}" ;; *) rest="" ;; esac ;; esac
  if [ "$how" = on ]; then
    new="cm:asleep $(iso "$NOW") put to sleep by lane-health; wake with scripts/lane-health.sh wake ${id:-<worker-id>} --apply"$'\n'"$rest"
  else
    new="$rest"
  fi
  [ "$new" != "$cur" ] || return 0
  j="$(cm_timeout 30 "$cli" worktree set --worktree "path:$path" --comment "$new" ${hs[@]+"${hs[@]}"} --json </dev/null 2>/dev/null)" || return 1
  printf '%s' "$j" | jq -e '.ok == true' >/dev/null 2>&1
}
# stop_session <host> <pid> <path> <handle> <runtime>: stops the process by exact pid (its cwd checked first), closes the
# terminal; sets SS_OK (1 stopped) and SS_WHY
stop_session() {
  local host="$1" pid="$2" path="$3" h="$4" rt="$5" proc c i cli out
  local -a hs
  SS_OK=0; SS_WHY=""
  case "$pid" in ''|*[!0-9]*) SS_WHY="no pid"; return ;; esac
  owns_locks || { SS_WHY="lost the resume lock before the kill: left alone"; return; }
  if [ "$host" = local ]; then
    proc="$(cm_proc_root)"
    c="$(readlink "$proc/$pid/cwd" 2>/dev/null)" || { SS_WHY="pid $pid is gone already"; SS_OK=1; }
    if [ "$SS_OK" = 0 ]; then
      case "${c%/}" in "$path"|"$path"/*) ;; *) SS_WHY="pid $pid now runs in $c, not $path: left alone"; return ;; esac
      if [ "${CM_TEST:-}" = 1 ] && [ -n "${CM_HEALTH_KILL_CMD:-}" ]; then sh -c "$CM_HEALTH_KILL_CMD \"\$1\"" _ "$pid" || true; else kill -TERM "$pid" 2>/dev/null || true; fi
      i=0; while [ -d "$proc/$pid" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
      if [ -d "$proc/$pid" ]; then SS_WHY="pid $pid did not stop within 10s of TERM: left running, look at it"; return; fi
      SS_OK=1
    fi
  else
    local ex tg
    ex="$(expect_hostname "$host")" || { SS_WHY="no valid expected hostname for $host: left alone"; return; }
    tg="$(cm_ssh_target "$host")"
    case "$tg" in -*|*[[:space:]]*|'') SS_WHY="invalid ssh target for $host: left alone"; return ;; esac
    # the remote side checks it is the right machine (a Spot VM can come back on another address) and the cwd, then TERMs
    # shellcheck disable=SC2016  # the remote side expands these
    out="$(printf 'e=%q; p=%q; w=%q; g="$(hostname -s 2>/dev/null || hostname)"; g="$(printf "%%s" "${g%%%%.*}" | tr "[:upper:]" "[:lower:]")"; [ "$g" = "$(printf "%%s" "${e%%%%.*}" | tr "[:upper:]" "[:lower:]")" ] || exit 7; c="$(readlink /proc/$p/cwd 2>/dev/null)" || exit 0; case "${c%%/}" in "$w"|"$w"/*) kill -TERM "$p" || exit 5 ;; *) exit 4 ;; esac; i=0; while [ -d /proc/$p ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done; [ ! -d /proc/$p ] || exit 6\n' "$ex" "$pid" "$path" \
      | cm_timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$tg" bash -s 2>&1)"
    case $? in
      0) SS_OK=1 ;;
      7) SS_WHY="the ssh target for $host answered as another machine: left alone"; return ;;
      4) SS_WHY="pid $pid no longer runs in $path: left alone"; return ;;
      6) SS_WHY="pid $pid did not stop within 10s of TERM: left running"; return ;;
      *) SS_WHY="could not stop pid $pid on $host: ${out:0:80}"; return ;;
    esac
  fi
  if [ -n "$h" ]; then
    cli="$(cli_for "$rt")" && cm_cli_host_into hs "$host" \
      && out="$(cm_timeout 30 "$cli" terminal close --terminal "$h" ${hs[@]+"${hs[@]}"} --json </dev/null 2>/dev/null)" \
      && [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" = true ] \
      || SS_WHY="process stopped; terminal $h did not close, close it by hand"
  fi
}

NOACT=""
if [ "$ACT" = 1 ] && jq -e 'any(.sessions[]; .resume or .sleep)' "$TMP/doc.json" >/dev/null 2>&1; then
  take_resume_lock || NOACT="resume.sh holds $RESUME_LOCK: no resume and no sleep this pass"
fi
RUN_BUDGET="$(cfgint "${CM_HEALTH_RUN_BUDGET_S:-}" .health.run_budget_seconds 540)"
RESUME_WORST=$((VERIFY_S + POLL_S + 60 + 3 * SSH_S + 30 + 30))   # re-probe, binary lookup, create, verify (one more poll and pane read)
SLEEP_WORST=$((2 * SSH_S + 30 + 30 + 30))                # re-probe, comment, kill, close
if [ "$ACT" = 1 ]; then
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    k="$(jq -r '.key' <<<"$s")"
    # fail closed: without resume.lock nothing is created or killed; past the budget the rest waits for the next pass
    if [ -n "$NOACT" ]; then action "$k" "$(jq -r 'if .resume then "resume" else "sleep" end' <<<"$s")" skipped "$NOACT"; continue; fi
    worst="$SLEEP_WORST"; [ "$(jq -r '.resume' <<<"$s")" = true ] && worst="$RESUME_WORST"
    if [ $((SECONDS + worst)) -gt "$RUN_BUDGET" ]; then
      action "$k" "$(jq -r 'if .resume then "resume" else "sleep" end' <<<"$s")" skipped "deferred to the next pass: ${SECONDS}s in, its worst case ${worst}s would pass the ${RUN_BUDGET}s run budget"; continue
    fi
    if [ "$(jq -r '.resume' <<<"$s")" = true ]; then
      resume_session "$k" "$(jq -r '.host' <<<"$s")" "$(jq -r '.path' <<<"$s")" "$(jq -r '.live.sessionId // ""' <<<"$s")" \
        "$(jq -r '.live.runtime // ""' <<<"$s")" "$(jq -r '.live.model // ""' <<<"$s")" "$(jq -r '.live.effort // ""' <<<"$s")"
      case "$RS_OK" in
        1) action "$k" resume resumed "$RS_WHY" "$(jq -nc --arg h "$RS_HANDLE" '{handle: $h, attempted: true}')" ;;
        2) action "$k" resume skipped "$RS_WHY" ;;
        *) action "$k" resume failed "$RS_WHY" "$(jq -nc --arg h "$RS_HANDLE" '{handle: $h, attempted: ($h != "")}')" ;;
      esac
    elif [ "$MODE" = all ] && [ "$(jq -r '.sleep' <<<"$s")" = true ]; then
      if why="$(others_acting)"; then action "$k" sleep skipped "$why"; continue; fi
      # judged minutes ago (resumes ran since): probe again, and sleep only if nothing moved in the meantime
      sh_="$(jq -r '.host' <<<"$s")"; sp_="$(jq -r '.live.pid' <<<"$s")"
      probe_host "$sh_" "$TMP/sl-$$" "$(jq -r '.path' <<<"$s")"
      now_t="$(jq -r --argjson p "$sp_" 'if .ok and ((.incomplete // false) | not) then ([.procs[] | select(.pid == $p)] | first | .tmtime // "gone") else "x" end' "$TMP/sl-$$.json" 2>/dev/null)"
      was_t="$(jq -r '.live.lastTranscriptAt // "" | if . == "" then "" else (sub("\\.[0-9]+"; "") | fromdateiso8601 | tostring) end' <<<"$s" 2>/dev/null)"
      if [ "$now_t" != "$was_t" ]; then action "$k" sleep skipped "it changed since the check (transcript ${now_t:-?} vs ${was_t:-?}): not slept"; continue; fi
      hd_="$(jq -r '.live.handle // ""' <<<"$s")"
      if [ -n "$hd_" ] && b_="$(pane_bottom "$sh_" "$(jq -r '.live.runtime // ""' <<<"$s")" "$hd_")" && [ "$(pane_state "$b_" | cut -f1)" = busy ]; then
        action "$k" sleep skipped "it is mid-turn now: not slept"; continue
      fi
      if ! mark_comment "$sh_" "$(jq -r '.path' <<<"$s")" on "$(jq -r '.adoptId // .rowId // ""' <<<"$s")"; then
        action "$k" sleep skipped "its worktree comment could not be marked cm:asleep: not slept"; continue
      fi
      stop_session "$(jq -r '.host' <<<"$s")" "$(jq -r '.live.pid' <<<"$s")" "$(jq -r '.path' <<<"$s")" "$(jq -r '.live.handle // ""' <<<"$s")" "$(jq -r '.live.runtime // ""' <<<"$s")"
      if [ "$SS_OK" = 1 ]; then action "$k" sleep slept "${SS_WHY:-process stopped, terminal closed}"
      else mark_comment "$sh_" "$(jq -r '.path' <<<"$s")" off || true; action "$k" sleep failed "$SS_WHY"; fi
    fi
  done < <(jq -c '.sessions[] | select(.resume or .sleep)' "$TMP/doc.json")
fi

# ---- sleep and wake (explicit, one worker) -------------------------------------------------------
if [ "$MODE" = sleep ] || [ "$MODE" = wake ]; then
  s="$(jq -c '.sessions[0] // empty' "$TMP/doc.json")"
  [ -n "$s" ] || { cm_warn "lane-health.sh $MODE: $TARGET is not a session that can be judged (retired, done or queued)"; exit 1; }
  host="$(jq -r '.host' <<<"$s")"; path="$(jq -r '.path' <<<"$s")"; word="$(jq -r '.word' <<<"$s")"
  npid="$(jq -r '.pids | length' <<<"$s")"; sid="$(jq -r '.live.sessionId // ""' <<<"$s")"; state="$(jq -r '.state' <<<"$s")"
  NOWI="$(iso "$NOW")"
  if [ "$MODE" = sleep ]; then
    [ "$word" != unknown ] || { echo "sleep $TARGET: host $host not judged ($(jq -r '.meaning' <<<"$s")): nothing done"; exit 3; }
    [ "$npid" -le 1 ] || { echo "sleep $TARGET: $npid processes in $path (duplicate, hard rule 4): nothing done, ask $CM_OWNER_NAME which one keeps going"; exit 3; }
    [ "$(jq -r '.dup' <<<"$s")" != true ] || { echo "sleep $TARGET: $(jq -r '.meaning' <<<"$s") (hard rule 4): nothing done"; exit 3; }
    [ -n "$sid" ] || { echo "sleep $TARGET: no session id known for it, so it could not be woken on the same session: nothing done"; exit 3; }
    if [ "$state" = asleep ] && [ "$npid" = 0 ]; then echo "sleep $TARGET: already asleep"; exit 0; fi
    if [ "$APPLY" = 0 ]; then
      echo "sleep $TARGET (dry run): $([ "$npid" = 1 ] && echo "stop pid $(jq -r '.pids[0]' <<<"$s") in $path on $host, close terminal $(jq -r '.live.handle // "none"' <<<"$s"), " )set state asleep; keep worktree, branch, transcript ($sid) and ledger row. Add --apply."
      exit 0
    fi
    # order matters: the comment mark and the ledger row say asleep BEFORE the process stops, so no checker (the --all
    # pass here, or a lead elsewhere that reads only comments) can take it for stopped and resume it; a failed stop
    # takes both back
    if [ "$npid" = 1 ]; then
      take_resume_lock || { echo "sleep $TARGET: resume.sh is running: nothing done"; exit 4; }
      if why="$(others_acting)"; then echo "sleep $TARGET: $why: nothing done"; exit 4; fi
    fi
    mark_comment "$host" "$path" on "$TARGET" || { echo "sleep $TARGET: its worktree comment could not be marked cm:asleep (a lead on another host would take it for stopped): nothing done"; exit 3; }
    # shellcheck disable=SC2016
    if ! cm_ledger_write '.workers[$id] |= (. + {state: "asleep", asleepAt: $now, asleepFrom: (if (.state // "running") == "asleep" then (.asleepFrom // "running") else (.state // "running") end), updatedAt: $now,
          live: ((.live // {}) + $live + {pid: null, handle: null}), kind: "asleep", shouldRun: false}) | .updatedAt = $now' \
      --arg id "$TARGET" --arg now "$NOWI" --argjson live "$(jq -c '.live' <<<"$s")"; then
      mark_comment "$host" "$path" off "$TARGET" || true
      echo "sleep $TARGET: the ledger write was refused (reason above): nothing stopped"; exit 1
    fi
    if [ "$npid" = 1 ]; then
      stop_session "$host" "$(jq -r '.pids[0]' <<<"$s")" "$path" "$(jq -r '.live.handle // ""' <<<"$s")" "$(jq -r '.live.runtime // ""' <<<"$s")"
      if [ "$SS_OK" != 1 ]; then
        # shellcheck disable=SC2016
        cm_ledger_write '.workers[$id] |= (. + {state: (.asleepFrom // "running"), asleepAt: null, kind: null, shouldRun: true, updatedAt: $now}) | .updatedAt = $now' --arg id "$TARGET" --arg now "$NOWI" || true
        mark_comment "$host" "$path" off "$TARGET" || true
        echo "sleep $TARGET: $SS_WHY (state and comment put back)"; exit 3
      fi
    fi
    echo "sleep $TARGET: asleep${SS_WHY:+ ($SS_WHY)}; wake it with: scripts/lane-health.sh wake $TARGET --apply"
    exit 0
  fi
  # wake
  [ "$state" = asleep ] || { echo "wake $TARGET: state is $state, not asleep: nothing done"; exit 3; }
  [ -n "$sid" ] || { echo "wake $TARGET: no session id recorded: resume it by hand"; exit 3; }
  if [ "$npid" -ge 1 ]; then
    [ "$APPLY" = 1 ] || { echo "wake $TARGET (dry run): a process already runs in $path: would set the state back"; exit 0; }
    # shellcheck disable=SC2016
    cm_ledger_write '.workers[$id] |= (. + {state: (.asleepFrom // "running"), asleepAt: null, updatedAt: $now}) | .updatedAt = $now' --arg id "$TARGET" --arg now "$NOWI" || exit 1
    mark_comment "$host" "$path" off "$TARGET" || true
    echo "wake $TARGET: already running; state set back"; exit 0
  fi
  # the same session id must not run anywhere else (two copies of one session, hard rule 4)
  elsewhere="$(jq -r --arg s "$sid" '[.[] | select(.ok) | .host as $h | (.procs[] | select(.sid == $s) | "\($h):\(.pid)"), ((.headless // [])[] | select(.sid == $s) | "\($h):headless")] | join(", ")' "$TMP/hosts.json")"
  [ -z "$elsewhere" ] || { echo "wake $TARGET: session $sid already runs at $elsewhere: nothing done"; exit 3; }
  down="$(jq -r '[.[] | select(.ok | not) | .host] | join(", ")' "$TMP/hosts.json")"
  [ -z "$down" ] || echo "wake $TARGET: note: host(s) $down did not answer, so a copy there cannot be ruled out"
  if [ "$APPLY" = 0 ]; then echo "wake $TARGET (dry run): resume session $sid in $path on $host; add --apply"; exit 0; fi
  take_resume_lock || { echo "wake $TARGET: resume.sh is running: nothing done"; exit 4; }
  resume_session "$TARGET" "$host" "$path" "$sid" "$(jq -r '.live.runtime // ""' <<<"$s")" "$(jq -r '.live.model // ""' <<<"$s")" "$(jq -r '.live.effort // ""' <<<"$s")"
  [ "$RS_OK" = 1 ] || { echo "wake $TARGET: $RS_WHY (state stays asleep)"; exit 3; }
  # shellcheck disable=SC2016
  cm_ledger_write '.workers[$id] |= (. + {state: (.asleepFrom // "running"), asleepAt: null, updatedAt: $now}) | .updatedAt = $now' --arg id "$TARGET" --arg now "$NOWI" || exit 1
  mark_comment "$host" "$path" off "$TARGET" || echo "wake $TARGET: note: the cm:asleep line could not be taken off its comment; remove it by hand"
  echo "wake $TARGET: resumed ($RS_WHY)"; exit 0
fi

# ---- finalize: action results, alerts, the store patch -------------------------------------------
jq -s '.' "$TMP/actions.ndjson" > "$TMP/actions.json"
# shellcheck disable=SC2016  # a jq program
FINAL_JQ='
def ep: if . == null then null elif type == "number" then . else (tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) end;
def iso: if . == null then null else (floor | todate) end;
def hhmm: if . == null then "?" else (localtime | strflocaltime("%H:%M")) end;
def healthyw: IN("running", "idle", "waiting on you");
($actions | map({key: .key, value: .}) | from_entries) as $A
| .sessions |= map(. as $s | ($A[$s.key] // null) as $a
    | if $a == null then .
      elif $a.kind == "resume" and $a.result == "resumed" then
        .word = "running" | .mark = "●" | .meaning = "resumed after: \(.meaning | split("; ")[0])"
        | .store.resumeAttempts = ((.store.resumeAttempts // 0) + 1) | .store.health.lastResumeAt = ($now | iso)
        | .store.health.word = "running" | .store.health.healthySince = ($now | iso)
        | .store.live = (.store.live + {handle: $a.handle})
      elif $a.kind == "resume" and $a.result == "failed" then
        .meaning = "\(.meaning | split("; ")[0]); retry 1 failed: \($a.detail)"
        | (if $a.attempted then .store.resumeAttempts = ((.store.resumeAttempts // 0) + 1) | .store.health.lastResumeAt = ($now | iso) else . end)
        | .attempts = .store.resumeAttempts | .resumeFailed = $a.attempted
      elif $a.kind == "resume" then .meaning = "\(.meaning | split("; ")[0]); \($a.detail)"
      elif $a.kind == "sleep" and $a.result == "slept" then
        .word = "asleep" | .mark = "z" | .slept = true
        | .meaning = (if (.unknown // false) then "was not in the ledger, branch merged and tree clean: put to sleep (\($a.detail))"
                      else "\(.state) work came back, branch merged and tree clean: put to sleep (\($a.detail))" end)
        | (if .rowId != null then .store += {state: "asleep", asleepAt: ($now | iso), asleepFrom: .state, kind: "asleep", shouldRun: false}
                                  | .store.live = ((.store.live // {}) + {pid: null, handle: null}) else . end)
      elif $a.kind == "sleep" then .meaning = "\(.meaning); sleep failed: \($a.detail)"
      else . end
    | .store.health.meaning = .meaning)
| . as $doc
| ($doc.sessions | map(select(.unknown | not) | {key: .rowId, value: .}) | from_entries) as $byRow
| ($doc.hosts | map({key: .host, value: .}) | from_entries) as $H
| (if $mode != "all" then [] else
    [ $doc.sessions[] | select(.isLead and .word == "stopped")
        | select((.resumeFailed // false) or ((.resumeWhy != "ok") and ((.resumeWhy // "") | test("^waiting|^its lead") | not)))
      | {key: "lead-stopped:\(.key):\(.store.lastStopAt):try\(.store.resumeAttempts // 0)", kind: "lead-stopped",
         text: "\($project): lead \(.name) on \(.host) is stopped: \(.meaning)."} ]
    + [ $doc.sessions[] | select(.word == "stuck" and (.store.health.paneSince | ep) != null and ($now - (.store.health.paneSince | ep)) >= $stuckMin * 60)
      | {key: "stuck:\(.key):\(.store.health.paneSince)", kind: "stuck",
         text: "\($project): \(.name) on \(.host) is stuck for \(($now - (.store.health.paneSince | ep)) / 60 | floor) min: \(.meaning)."} ]
    + [ $doc.sessions[] | select(.dup) | {key: "dup:\(.host):\(.path):\(.pids | sort | map(tostring) | join(","))", kind: "duplicate",
         text: "\($project): two copies of \(.name) on \(.host) (pids \(.pids | map(tostring) | join(", "))). Nothing was touched; say which one keeps going."} ]
    + [ $doc.hostEvents[] | select(.watched and (.kind | IN("reboot", "preemption")) and (($now - (.at | ep)) < 86400)) | . as $e
        | select(($H[$e.host].settled // false))
        | [ $doc.sessions[] | select(.host == $e.host and (.unknown | not) and .store.shouldRun) ] as $ss
        | ([ $ss[] | select(.word | healthyw) | .name ]) as $back | ([ $ss[] | select(.word | healthyw | not) | "\(.name) (\(.word))" ]) as $not
        | {key: "host:\($e.host):\($e.kind):\($e.at)", kind: "host-\($e.kind)",
           text: "\($project): \($e.host) \(if $e.kind == "preemption" then "was preempted (Spot)" else "restarted" end) at \($e.at | ep | hhmm). Came back: \($back | length)\(if ($back | length) > 0 then " (" + ($back | join(", ")) + ")" else "" end). Not back: \($not | length)\(if ($not | length) > 0 then " (" + ($not | join(", ")) + ")" else "" end)."} ]
  end) as $all
| ($all | map(select(($doc.alertedPrev[.key].sent // false) | not) | select(($doc.alertedPrev[.key].tries // 0) < 3))) as $alerts
| .alerts = $alerts
| .summary = (reduce (["running", "idle", "waiting on you", "stuck", "stopped", "asleep", "unknown"][]) as $w ({}; .[$w] = ([$doc.sessions[] | select(.word == $w)] | length)))
| .attention = [ .sessions[] | select(.word | IN("running", "idle", "asleep") | not) | {name, host, word, mark, meaning} ]'

jq --slurpfile A "$TMP/actions.json" --argjson now "$NOW" --arg mode "$MODE" --arg project "$CM_PROJECT" --argjson stuckMin "$STUCK_MIN" \
  '$A[0] as $actions | . as $d | $d | ('"$FINAL_JQ"')' "$TMP/doc.json" > "$TMP/final.json" 2>"$TMP/final.err" \
  || { cm_warn "lane-health.sh: finalize failed: $(head -c 300 "$TMP/final.err")"; exit 1; }

# ---- alerts (--act, --all) ------------------------------------------------------------------------
SEND_CMD=""
SEND_JSON="$(cm_cfg_json .health.alerts.send)"
if [ -n "${CM_HEALTH_SEND+x}" ]; then SEND_CMD="$CM_HEALTH_SEND"
elif [ "$SEND_JSON" = null ]; then
  if [ "$(cm_cfg .messaging.owner_digest.adapter none)" != none ]; then SEND_CMD="$(cm_cfg .messaging.owner_digest.send)"; fi
else SEND_CMD="$(jq -r 'tostring' <<<"$SEND_JSON")"; fi
SEND_TO="$(cm_cfg .health.alerts.to)"; [ -n "$SEND_TO" ] || SEND_TO="$(cm_cfg .messaging.owner_digest.to)"
send_text() { # <text>: 0 when the send hook accepted it. {to} and {text} become "$CM_ALERT_TO" and "$CM_ALERT_TEXT":
  # the values reach the command as environment, never as command text, so nothing in a pane line can run
  local c
  [ -n "$SEND_CMD" ] || return 1
  shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: an & in the replacement must stay literal
  c="$SEND_CMD"
  # shellcheck disable=SC2016  # the command text names the variables; bash -c expands them
  local qto='"$CM_ALERT_TO"' qtext='"$CM_ALERT_TEXT"'
  c="${c//\{to\}/$qto}"
  c="${c//\{text\}/$qtext}"
  CM_ALERT_TO="$SEND_TO" CM_ALERT_TEXT="$1" cm_timeout 30 bash -c "$c" </dev/null >/dev/null 2>&1
}
: > "$TMP/alerted.ndjson"
if [ "$ACT" = 1 ] && [ "$MODE" = all ]; then
  mkdir -p "$CM_HOME/inbox" 2>/dev/null
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    k="$(jq -r '.key' <<<"$a")"; kind="$(jq -r '.kind' <<<"$a")"; text="$(jq -r '.text' <<<"$a")"
    # past the run budget an alert waits for the next pass (nothing is recorded for it, so it is sent then)
    if [ $((SECONDS + 30)) -gt $((RUN_BUDGET + 40)) ]; then cm_warn "lane-health.sh: alert $k waits for the next pass (run budget)"; continue; fi
    tries="$(jq -r --arg k "$k" '.alertedPrev[$k].tries // 0' "$TMP/final.json")"
    if [ "$tries" = 0 ]; then
      printf '# lane-health %s %s\n\n%s\n' "$kind" "$(iso "$NOW")" "$text" > "$CM_HOME/inbox/lane-health-$kind-$(date -u +%Y%m%dT%H%M%SZ)-$$.md" 2>/dev/null || true
    fi
    sent=false; send_text "$text" && sent=true
    jq -nc --arg k "$k" --arg at "$(iso "$NOW")" --argjson sent "$sent" --argjson tries "$((tries + 1))" --arg via "${SEND_CMD:+send}" \
      '{($k): {at: $at, sent: (if $via == "" then true else $sent end), tries: $tries, via: (if $via == "" then "inbox" else "send" end)}}' >> "$TMP/alerted.ndjson"
  done < <(jq -c '.alerts[]' "$TMP/final.json")
fi
jq -s 'add // {}' "$TMP/alerted.ndjson" > "$TMP/alerted.json"

# ---- store write ------------------------------------------------------------------------------------
# shellcheck disable=SC2016  # a jq program
PATCH='
def ep: if . == null then null elif type == "number" then . else (tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) end;
($F[0]) as $f | ($AL[0]) as $al
| reduce ($f.sessions[] | select(.rowId != null)) as $s (.; .workers[$s.rowId] |= ((. // {}) + $s.store))
| reduce ($f.sessions[] | select(.unknown and (.slept // false) and .adoptId != null)) as $s (.;
    ($s.adoptId) as $id
    | if .workers[$id] != null then . else .workers[$id] = {host: $s.host, path: $s.path, state: "asleep", standing: false, adopted: true, agent: ($s.live.agent // null),
                       lane: null, parent: null, beadsEpic: null, asleepAt: ($now | todate), asleepFrom: "running",
                       live: ($s.live + {pid: null, handle: null}), kind: "asleep", shouldRun: false,
                       task: "adopted by lane-health: was not in the ledger, branch \($s.branch // "?") merged, tree clean",
                       spawnedAt: null, updatedAt: ($now | todate)} end)
| .hostEvents = ((.hostEvents // []) + $f.newEvents | .[-200:])
| reduce ($f.hosts[] | select(.ok and .bootAt != null)) as $h (.; .hosts[$h.host] = ((.hosts[$h.host] // {}) + {bootAt: $h.bootAt, healthCheckedAt: ($now | todate)}))
| .health = ((.health // {}) + {checkedAt: ($now | todate), mode: $f.mode, summary: $f.summary, attention: ($f.attention | .[0:30]),
             alerted: (((.health.alerted // {}) + $al) | with_entries(select((.value.at | ep // 0) > $now - 604800)))})
| .updatedAt = ($now | todate)'
if [ "$NOWRITE" = 0 ]; then
  if [ "$MODE" = all ]; then
    cm_ledger_write "$PATCH" --slurpfile F "$TMP/final.json" --slurpfile AL "$TMP/alerted.json" --argjson now "$NOW" \
      || cm_warn "lane-health.sh: the ledger write was refused (reason above): this pass is not recorded"
  else
    mkdir -p "$(dirname "$STORE")" 2>/dev/null
    if jq --slurpfile F "$TMP/final.json" --slurpfile AL "$TMP/alerted.json" --argjson now "$NOW" '(if (.workers | type) == "object" then . else . + {workers: {}} end) | '"$PATCH" \
         "$TMP/store.json" > "$TMP/store.new" 2>/dev/null && [ -s "$TMP/store.new" ]; then
      mv -f "$TMP/store.new" "$STORE.tmp.$$" && mv -f "$STORE.tmp.$$" "$STORE"
    else cm_warn "lane-health.sh: could not write $STORE"; fi
  fi
fi

# ---- output ---------------------------------------------------------------------------------------
NEED="$(jq -r '.attention | length' "$TMP/final.json")"
case "$OUTFMT" in
  json) jq --slurpfile AL "$TMP/alerted.json" --slurpfile AC "$TMP/actions.json" --argjson act "$ACT" '. + {act: ($act == 1), actions: $AC[0], alertResults: $AL[0]} | del(.alertedPrev)' "$TMP/final.json" ;;
  line) jq -r --argjson now "$NOW" '
          ([.sessions[] | select(.word | IN("running", "idle"))] | length) as $ok
          | . as $d
          | "cm:health \($ok)/\(.sessions | length) ok"
            + ([["stopped", "stopped"], ["stuck", "stuck"], ["waiting on you", "waiting"], ["unknown", "unknown"], ["asleep", "asleep"]]
               | map(. as $p | [$d.sessions[] | select(.word == $p[0]) | .name] | select(length > 0) | " | \($p[1]): " + join(", ")) | join(""))
            + " | at \($now | todate)"' "$TMP/final.json" ;;
  *)
    jq -r '"lane-health \(.mode)\(if .lead then " " + .lead else "" end) \(.generatedAt): \(.sessions | length) sessions, \(.attention | length) need a look",
           (.sessions[] | [.host, (if .isLead then .key elif .parent then .parent else "-" end), .name, .word, (.meaning // .task // "")] | @tsv),
           (.hosts[] | select(.ok | not) | ["host", .host, "unreachable", (.error // "")] | @tsv)' "$TMP/final.json"
    jq -r '.[] | ["action", .kind, .key, .result, .detail] | @tsv' "$TMP/actions.json"
    jq -r --slurpfile AL "$TMP/alerted.json" --argjson act "$ACT" --arg mode "$MODE" '.alerts[] | . as $a
           | ["alert", .kind, (if $act == 1 and $mode == "all" then (if ($AL[0][$a.key].via // "") == "inbox" then "inbox only" elif $AL[0][$a.key].sent then "sent" else "send failed, retried next pass" end) else "would send (--act)" end), .text] | @tsv' "$TMP/final.json" ;;
esac
[ "$NEED" = 0 ] || exit 3
exit 0
