#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for concertmaster scripts. Sourced, never executed.
# Portable: bash 3.2 (macOS default) and Linux. No GNU-only flags.
#
# Config: one YAML file, found in this order:
#   $CM_CONFIG, <skill>/config.yaml (next to scripts/), $CM_HOME/config.yaml
# (CM_HOME here is the env value or ~/.concertmaster; config state_dir then
# moves it for everything else).
# It is read once per source with yq (mikefarah v4, or any yq that prints JSON
# with -o=json) into JSON, then queried with jq. An env var always beats the
# file, so tests and one-off runs can override any single value.
# No config and no env: every project value is empty and the org filter
# matches nothing, so teardown and discover fail closed.

_cm_home_env="${CM_HOME:-}"
CM_HOME="${CM_HOME:-$HOME/.concertmaster}"

_cm_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cm_warn() { printf 'concertmaster: %s\n' "$*" >&2; }

# cm_proc_root: where /proc is. CM_PROC_ROOT replaces it with CM_TEST=1 only (tests).
cm_proc_root() {
  if [ "${CM_TEST:-}" = 1 ] && [ -n "${CM_PROC_ROOT:-}" ]; then printf '%s' "$CM_PROC_ROOT"; else printf '/proc'; fi
}

# cm_claude_pids <proc-root> [pgrep options]: pids of real claude agents, one per line. `pgrep -x claude`
# matches the process NAME (comm) only, and Claude Code's Bash tool runs its embedded grep and find helpers
# by re-executing the claude binary with argv[0] = ugrep or bfs: comm is still claude, the helper lives 2 to
# 3 seconds in the cwd of whichever lane ran the grep, and it made a false "DUPLICATE live agents" row
# (seen on a live host). A pid counts only when comm is claude (pgrep) AND the basename of the first
# element of its NUL-separated cmdline is claude (a path with spaces is one element; a process title such
# as "claude --resume" counts by its first word). A pid that exited since pgrep is dropped; an empty cmdline
# (zombie) is dropped; a cmdline that cannot be read keeps the pid (it cannot be told apart, and "a claude
# may be alive" is the safe side for every caller). With no /proc (macOS) the pgrep list is returned as is.
# Extra arguments go to pgrep (-u UID). Returns 0 (also for no match), 127 with no pgrep, else pgrep's
# status above 1, so a caller can fail closed.
cm_claude_pids() {
  local root=$1 pids rc p a0
  shift
  command -v pgrep >/dev/null 2>&1 || return 127
  pids=$(pgrep "$@" -x claude 2>/dev/null); rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  if [ ! -d "$root" ]; then
    for p in $pids; do printf '%s\n' "$p"; done
    return 0
  fi
  for p in $pids; do
    [ -d "$root/$p" ] || continue
    if [ ! -r "$root/$p/cmdline" ]; then printf '%s\n' "$p"; continue; fi
    a0=""
    { IFS= read -r -d '' a0 < "$root/$p/cmdline"; } 2>/dev/null || true
    [ -n "$a0" ] || continue
    case "$a0" in   # claude, a path ending in /claude (spaces allowed), or a process title that starts that way
      claude|*/claude|claude\ *|*/claude\ *) printf '%s\n' "$p" ;;
    esac
  done
  return 0
}

# cm_config_file: print the config path in use, or return 1.
cm_config_file() {
  local f
  for f in "${CM_CONFIG:-}" "$_cm_lib_dir/../config.yaml" "$CM_HOME/config.yaml"; do
    if [ -n "$f" ] && [ -r "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

CM_CONFIG_FILE="$(cm_config_file || true)"
CM_CFG_JSON='{}'
if [ -n "$CM_CONFIG_FILE" ]; then
  if command -v yq >/dev/null 2>&1; then
    CM_CFG_JSON="$(yq -o=json -I=0 '.' "$CM_CONFIG_FILE" 2>/dev/null || printf '{}')"
    printf '%s' "$CM_CFG_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || {
      cm_warn "config $CM_CONFIG_FILE did not parse as a YAML map; using defaults"
      CM_CFG_JSON='{}'
    }
  else
    cm_warn "yq not found: config $CM_CONFIG_FILE ignored, using env and defaults"
  fi
fi

# cm_cfg <jq path> [default]: a scalar from the config, else the default.
# Lists come back space-joined. Example: cm_cfg .github.org
cm_cfg() {
  local v
  v="$(printf '%s' "$CM_CFG_JSON" | jq -r "($1) // empty | if type == \"array\" then join(\" \") elif type == \"object\" then tojson else tostring end" 2>/dev/null || true)"
  printf '%s' "${v:-${2:-}}"
}

# cm_cfg_json <jq path> [default-json]: a value as compact JSON.
cm_cfg_json() {
  local v
  v="$(printf '%s' "$CM_CFG_JSON" | jq -c "($1) // empty" 2>/dev/null || true)"
  printf '%s' "${v:-${2:-null}}"
}

# state_dir (config) moves CM_HOME unless CM_HOME came from the environment.
if [ -z "$_cm_home_env" ]; then
  _cm_sd="$(cm_cfg .state_dir)"
  # shellcheck disable=SC2088
  case "$_cm_sd" in "~/"*) _cm_sd="$HOME/${_cm_sd#\~/}" ;; esac
  [ -n "$_cm_sd" ] && CM_HOME="$_cm_sd"
fi

# Project values. Env wins over config.
CM_ORG="${CM_ORG:-$(cm_cfg .github.org)}"
CM_REPO="${CM_REPO:-$(cm_cfg .github.main_repo)}"
CM_PROJECT="${CM_PROJECT:-$(cm_cfg .project.name project)}"
# This project's id (config project.id), stamped on the ledger as `project` and checked by
# cm_ledger_guard. Unset: no ledger is judged foreign (legacy configs keep working).
CM_PROJECT_ID="${CM_PROJECT_ID:-$(cm_cfg .project.id)}"
CM_OWNER_NAME="${CM_OWNER_NAME:-$(cm_cfg .project.owner.name owner)}"
CM_OWNER_ID="${CM_OWNER_ID:-$(cm_cfg .project.owner.id owner)}"
CM_TZ="${CM_TZ:-$(cm_cfg .schedule.timezone UTC)}"
CM_TZ_LABEL="${CM_TZ_LABEL:-$(cm_cfg .schedule.timezone_label "$CM_TZ")}"
# Space-separated shell globs of org repo names that are never in scope.
CM_EXCLUDE_REPOS="${CM_EXCLUDE_REPOS-$(cm_cfg .github.exclude_repo_patterns)}"
# Extended regex matched against worktree paths (abrupt.sh, waiting.sh).
CM_PATH_MATCH="${CM_PATH_MATCH:-$(cm_cfg .worktrees.path_match)}"
# Space-separated, lowercase agent types that must not run on this project's work
# (config agents.forbidden). Empty = the forbidden-agent census is off.
CM_FORBIDDEN_AGENTS="${CM_FORBIDDEN_AGENTS-$(cm_cfg .agents.forbidden | tr '[:upper:]' '[:lower:]')}"
# The concertmaster's own worktree name: never torn down.
CM_SELF_WORKTREE="${CM_SELF_WORKTREE:-$(cm_cfg .worktrees.self_name concertmaster)}"

# Untracked paths that never make a worktree dirty (census.ignore_untracked): tool scratch that
# every lane writes. Space-separated globs. A leading "/" anchors at the repo root ("/dir/" is a
# prefix, "/a/*.x" matches one level, a "*" never crosses a "/"); otherwise a pattern ending in "/"
# is a directory prefix anywhere, one holding "/" matches the whole path (or its tail), and any
# other matches the file name. Env wins over config; an explicit empty list ignores nothing; an
# absent key takes the default.
# Default: tool scratch (.beads/*.jsonl, which also covers .auto-import-issues.jsonl; .agents/scratch/,
# .orca/, .wrangler/, *.log) and the bd runtime files a running bd writes: .beads/dolt.gate.lock,
# .beads/embeddeddolt.gate.lock, the .beads/embeddeddolt/ store, .beads/backup.lock, .beads/backup/ and
# the root-level .beads.gate.lock. All are root-anchored: a src/.beads/... lookalike stays real dirt.
# The runtime set matches teardown.sh BD_RUNTIME_PATH_RE and its remote allow-list (keep them in step).
# The *.jsonl entry is census-only: teardown.sh still treats an untracked bd export as precious and
# refuses without --salvage.
CM_IGNORE_UNTRACKED_DEFAULT='/.beads/*.jsonl /.beads/dolt.gate.lock /.beads/embeddeddolt/ /.beads/embeddeddolt.gate.lock /.beads/backup.lock /.beads/backup/ /.beads.gate.lock /.agents/scratch/ /.orca/ /.wrangler/ *.log'
if [ -z "${CM_IGNORE_UNTRACKED+x}" ]; then
  _cm_ign="$(cm_cfg_json .census.ignore_untracked)"
  if [ -z "$_cm_ign" ] || [ "$_cm_ign" = null ]; then
    CM_IGNORE_UNTRACKED="$CM_IGNORE_UNTRACKED_DEFAULT"
  else
    CM_IGNORE_UNTRACKED="$(printf '%s' "$_cm_ign" | jq -r 'if type == "array" then map(select((type == "string") and (length > 0) and (test("[[:space:]]") | not))) | join(" ") else "" end' 2>/dev/null || true)"
  fi
fi

# Which CLI drives the fleet: config key `cli`, `orca` (default) or `plugly`. CM_CLI_KIND in the
# environment beats the file, so a test or a one-off run can switch it. Any other value fails closed
# in cm_cli and cm_cli_host (a message on stderr, status 2, nothing printed).
CM_CLI_KIND="${CM_CLI_KIND:-$(cm_cfg .cli orca)}"

# cm_cli: print the command that runs the configured CLI.
#   orca:   $ORCA_CLI_COMMAND, else orca-ide on Linux outside an Orca terminal (bare `orca` there is
#           the GNOME screen reader), else orca. This is the resolution the orca-cli skill describes.
#   plugly: $PLUGLY_CLI_COMMAND, else plugly.
# Callers run it once: ORCA="$(cm_cli)" || exit 2.
cm_cli() {
  case "$CM_CLI_KIND" in
    orca)
      if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
        printf '%s\n' "$ORCA_CLI_COMMAND"
      elif [ "$(uname -s)" = "Linux" ] && [ "${TERM_PROGRAM:-}" != "Orca" ] && command -v orca-ide >/dev/null 2>&1; then
        printf '%s\n' orca-ide
      else
        printf '%s\n' orca
      fi ;;
    plugly)
      if [ -n "${PLUGLY_CLI_COMMAND:-}" ]; then printf '%s\n' "$PLUGLY_CLI_COMMAND"; else printf '%s\n' plugly; fi ;;
    *)
      cm_warn "unknown cli '$CM_CLI_KIND' (config key cli, or CM_CLI_KIND): use orca or plugly"
      return 2 ;;
  esac
}
# Older briefs and lanes still say cm_orca: keep the name working for one release.
cm_orca() { cm_cli "$@"; }

# cm_cli_host <host>: the host selector words for a CLI call, on one line (nothing for the local
# host). <host> is "local" for this machine, else the environment name.
#   orca:   local -> nothing;   other -> --environment <name>
#   plugly: local -> nothing;   other -> --environment <name>
# plugly's `host list` advertises `--host local` for this machine, but plugly 1.0.0 rejects --host on every
# command the scripts use ("Unknown flag --host for command: worktree list"; the bare call addresses the local
# runtime). Should a later plugly accept it, change the plugly arm here and cli-argv.sh/cli-parity.sh follow.
# Do not quote the result into one argument; use cm_cli_host_into to get an array.
cm_cli_host() {
  local h="${1-}"
  [ -n "$h" ] || { cm_warn "cm_cli_host: an empty host (use local for this machine)"; return 2; }
  case "$CM_CLI_KIND" in
    orca)   [ "$h" = local ] || printf -- '--environment %s\n' "$h" ;;
    plugly) [ "$h" = local ] || printf -- '--environment %s\n' "$h" ;;   # same as orca: see above
    *)      cm_warn "unknown cli '$CM_CLI_KIND' (config key cli, or CM_CLI_KIND): use orca or plugly"; return 2 ;;
  esac
}

# cm_cli_host_into <array-name> <host>: cm_cli_host as an array (empty for the local host), for
# "${arr[@]}" at the call. bash 3.2 has no namerefs, so the array is filled by name with eval. The host name stays
# ONE element, whatever characters it holds (an environment name may hold a space).
cm_cli_host_into() {
  local _cm_h="${2-}"
  case "$1" in ''|[0-9]*|_cm_*|*[!A-Za-z0-9_]*) cm_warn "cm_cli_host_into: bad array name '$1'"; return 2 ;; esac
  eval "$1=()"   # a refused host leaves an empty array, never the previous host's selector
  cm_cli_host "$_cm_h" >/dev/null || return $?
  if [ "$_cm_h" = local ]; then eval "$1=()"; else eval "$1=(--environment \"\$_cm_h\")"; fi
}

# cm_ssh_target <host>: what to give `ssh` to reach a non-local host. ONE rule for every script that opens an ssh session
# to a fleet host (cutover-host.sh, live-agent.sh, discover.sh). In order:
#   1. $CM_SSH_TARGET (one host's alias, given per run);
#   2. the ledger's hosts.<host>.sshTarget, an explicit ssh alias or address for a host whose ssh name differs from both its
#      Orca name and its hostname;
#   3. the ledger's hosts.<host>.hostname, but ONLY when it is an address (holds a dot or a colon: an FQDN, an IPv4 or
#      IPv6 address). A dotless word is what `hostname -s` prints: the host's identity (the thing teardown.sh and
#      live-agent.sh compare the remote `hostname -s` with), not something DNS or ssh_config has to know, and on a real
#      fleet it did not resolve ("Could not resolve hostname <word>");
#   4. the host name itself, as an ssh alias (an Orca environment name that ssh_config knows).
# The caller refuses a result that starts with a dash or holds whitespace (never an ssh option or a word list).
cm_ssh_target() {
  local h="${1-}" t="" L
  if [ -n "${CM_SSH_TARGET:-}" ]; then printf '%s\n' "$CM_SSH_TARGET"; return 0; fi
  L="$(cm_ledger_path)"
  if [ -n "$h" ] && [ -s "$L" ] && cm_ledger_guard "$L" 2>/dev/null; then
    t="$(jq -r --arg h "$h" '.hosts[$h].sshTarget // empty | tostring' "$L" 2>/dev/null)"
    if [ -n "$t" ]; then printf '%s\n' "$t"; return 0; fi
    t="$(jq -r --arg h "$h" '.hosts[$h].hostname // empty | tostring' "$L" 2>/dev/null)"
  fi
  case "$t" in *[.:]*) printf '%s\n' "$t" ;; *) printf '%s\n' "$h" ;; esac
}

# cm_timeout <seconds> <cmd...>: timeout(1), gtimeout(1), or a perl alarm.
cm_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  fi
}

cm_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Standing-lane names. ONE definition, used by teardown.sh (lead and concertmaster mode) and followups.sh
# (adoption), so a name one of them treats as a lane is never treated as a single-task child by another.
# A name is a standing lane when it is a configured lane (lanes[].name), a configured ownership lead
# (ownership.leads keys), or lane-shaped: it contains "-sweeper", ends in or continues after "-lead", or starts
# with "epic-" or "epic:". Documented single-task names stay ordinary workers: sweep-<pr>, research-<slug>,
# ops-<slug>. CM_LANE_SHAPE_RE is an ERE that jq (test) and grep -E both read.
CM_LANE_SHAPE_RE='-sweeper|-lead($|-)|^epic[-:]'

# cm_lane_names: configured lane names and ownership lead names, lowercased, one per line.
cm_lane_names() {
  { cm_cfg '.lanes[].name' 2>/dev/null; echo; printf '%s' "$CM_CFG_JSON" | jq -r '(.ownership.leads // {}) | keys[]' 2>/dev/null || true; } \
    | tr '[:upper:]' '[:lower:]' | sed '/^$/d'
}

# cm_lane_reason <name>: prints why the name is a standing lane (configured lane, ownership lead, lane-shaped
# name) and returns 0; returns 1 for any other name.
cm_lane_reason() {
  local l
  l="$(cm_lower "$1")"
  [ -n "$l" ] || return 1
  if cm_cfg '.lanes[].name' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' | grep -Fxq -- "$l"; then
    echo "configured lane"; return 0
  fi
  if printf '%s' "$CM_CFG_JSON" | jq -r '(.ownership.leads // {}) | keys[]' 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -Fxq -- "$l"; then
    echo "ownership lead"; return 0
  fi
  if printf '%s\n' "$l" | grep -Eq -- "$CM_LANE_SHAPE_RE"; then echo "lane-shaped name"; return 0; fi
  return 1
}

# cm_lane_shaped <name>: true when the name is a standing lane by any of those rules.
cm_lane_shaped() { cm_lane_reason "$1" >/dev/null; }


# cm_repo_excluded <name>: true when the repo name matches an exclude glob.
cm_repo_excluded() {
  local name pat
  name="$(cm_lower "$1")"
  set -f
  for pat in $CM_EXCLUDE_REPOS; do
    # shellcheck disable=SC2254
    case "$name" in $(cm_lower "$pat")) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# cm_org_slug <remote-url>: prints "owner/name" when the remote is a repo of
# the configured org ($CM_ORG) that no exclude glob matches, else prints
# nothing, returns 1. An empty $CM_ORG matches nothing (fail closed).
cm_org_slug() {
  local url slug owner name
  [ -n "$CM_ORG" ] || return 1
  url="$(cm_lower "$1")"
  case "$url" in
    *github.com[:/]*) ;;
    *) return 1 ;;
  esac
  slug="${url#*github.com}"
  slug="${slug#[:/]}"
  slug="${slug%.git}"
  slug="${slug%/}"
  owner="${slug%%/*}"
  name="${slug#*/}"
  [ "$owner" = "$(cm_lower "$CM_ORG")" ] || return 1
  [ -n "$name" ] || return 1
  cm_repo_excluded "$name" && return 1
  printf '%s/%s\n' "$owner" "$name"
}

# cm_file_fresh <file> <minutes>: true when the file exists and is younger.
cm_file_fresh() {
  [ -s "$1" ] || return 1
  [ -n "$(find "$1" -mmin "-$2" 2>/dev/null)" ]
}

cm_now_ms() { printf '%s000\n' "$(date +%s)"; }

# cm_status_dirt: stdin is `git status --porcelain --untracked-files=all`; prints "<real> <ignored>".
# A tracked change or an untracked source file is real dirt. An untracked path matching
# CM_IGNORE_UNTRACKED is ignored (counted, never dirty). Tracked changes are never ignored.
# Pattern forms: "/dir/" and "/a/*.x" are anchored at the repo root (a "*" never crosses a "/");
# "dir/" is a directory prefix anywhere; another pattern with "/" matches the path or its tail;
# a bare pattern matches the file name.
cm_status_dirt() {
  local line path pat rel hit pslash real=0 ign=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    hit=0
    case "$line" in
      '?? '*)
        path="${line#\?\? }"; path="${path#\"}"; path="${path%\"}"
        pslash="${path//[!\/]/}"   # the path's slashes only; the anchored one-level form compares counts
        set -f
        for pat in $CM_IGNORE_UNTRACKED; do
          # the unquoted $pat below is a glob on purpose
          # shellcheck disable=SC2254
          case "$pat" in
            /*/) case "$path" in "${pat#/}"*) hit=1 ;; esac ;;
            /*) rel="${pat#/}"   # anchored at the repo root; a "*" never crosses a "/"
                case "${rel//[!\/]/}" in "$pslash") case "$path" in $rel) hit=1 ;; esac ;; esac ;;
            */) case "$path" in "$pat"*|*/"$pat"*) hit=1 ;; esac ;;
            */*) case "$path" in $pat|*/$pat) hit=1 ;; esac ;;
            *) case "${path##*/}" in $pat) hit=1 ;; esac ;;
          esac
          [ "$hit" = 1 ] && break
        done
        set +f ;;
    esac
    if [ "$hit" = 1 ]; then ign=$((ign + 1)); else real=$((real + 1)); fi
  done
  printf '%s %s\n' "$real" "$ign"
}

# cm_transcript_mtime <worktree path>: newest Claude transcript mtime (epoch seconds) for the
# worktree, or "unknown" when the project dir or any transcript is missing (a lane we cannot see
# is never treated as idle). Claude keys the dir by the path with every non-alphanumeric as "-".
# Shared by boot-sweep.sh and runtime-check.sh. CM_CLAUDE_PROJECTS overrides ~/.claude/projects.
cm_transcript_mtime() {
  local dir f newest=0 m found=0
  dir="${CM_CLAUDE_PROJECTS:-$HOME/.claude/projects}/$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"
  [ -d "$dir" ] || { echo unknown; return; }
  for f in "$dir"/*.jsonl; do
    [ -e "$f" ] || continue
    found=1
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    [ "$m" -gt "$newest" ] && newest="$m"
  done
  if [ "$found" = 1 ]; then echo "$newest"; else echo unknown; fi
}

# Screen checks shared by boot-sweep.sh (same patterns resume.sh uses locally; judge only the
# bottom ~12 non-empty lines of a screen, never the replayed transcript above it).
# shellcheck disable=SC2034  # read by boot-sweep.sh
CM_MENU_RE='enter to select|enter to confirm|esc to cancel|arrow keys|tab/arrow'
# shellcheck disable=SC2034  # read by boot-sweep.sh
CM_CLAUDE_RE='claude code|\? for shortcuts|esc to interrupt|shift\+tab|bypass permissions|accept edits|auto-accept'

# The nudge that tells a restarted lane to re-arm the /loop its old terminal took with it. ONE definition:
# boot-sweep.sh (host restart, and its tick mode for an Orca runtime restart) and cutover-host.sh (a lane moved
# to a new terminal) send these words; CM_BOOT_NUDGE and CM_TICK_NUDGE still override them in boot-sweep.sh.
# shellcheck disable=SC2034  # read by boot-sweep.sh and cutover-host.sh
CM_NUDGE_BOOT='The VM restarted. Any /loop or ScheduleWakeup timer you had died with it. Check git status and your worktree comment, re-arm your standing /loop now with the same prompt as before (your brief under ~/.concertmaster/briefs lists it if you lost it), and carry on.'
# shellcheck disable=SC2034
CM_NUDGE_TICK='Orca restarted. Any /loop or ScheduleWakeup timer you had died with it. Check git status and your worktree comment, re-arm your standing /loop now with the same prompt as before (your brief under ~/.concertmaster/briefs lists it if you lost it), and carry on.'

# ---- ledger project guard ---------------------------------------------------------------------
# Two projects can share a host, each with its own state dir (~/.concertmaster, ~/.concertmaster-<other>).
# A CM_HOME or CM_LEDGER leaked from the other project's session made a lead here read the other
# project's ledger. cm_ledger_guard refuses a ledger that is not this project's.
#
# cm_project_state_dir: this project's default state dir (config state_dir, else ~/.concertmaster).
cm_project_state_dir() {
  local d
  d="$(cm_cfg .state_dir)"
  # shellcheck disable=SC2088
  case "$d" in "~/"*) d="$HOME/${d#\~/}" ;; esac
  printf '%s\n' "${d:-$HOME/.concertmaster}"
}

# _cm_realdir <dir>: the physical path of an existing directory, else the argument as given.
_cm_realdir() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# cm_ledger_guard [--create] [ledger path]: 0 when the ledger may be read or written by this project,
# 3 (with the reason on stderr) when it belongs to another project. Does nothing and returns 0 when
# the project id is unset (project.id / CM_PROJECT_ID) or the ledger does not exist yet (--create:
# the file is about to be made, so only its location is judged). Rules, first hit wins:
#   - the ledger has a `project` field: it must equal this project's id (case-insensitive);
#   - no field (a legacy ledger): the file must sit under this project's state dir
#     (cm_project_state_dir); then it is read with a warning and stamped by the next
#     cm_ledger_write. Outside that dir it is refused with how to proceed. A legacy ledger is
#     never rewritten by hand.
cm_ledger_guard() {
  local create=0 L have id def real dir
  if [ "${1:-}" = "--create" ]; then create=1; shift; fi
  L="${1:-$(cm_ledger_path)}"
  id="${CM_PROJECT_ID:-}"
  [ -n "$id" ] || return 0
  if [ ! -s "$L" ] && [ "$create" = 0 ]; then return 0; fi
  def="$(cm_project_state_dir)"
  if [ -s "$L" ]; then
    have="$(jq -r 'if type == "object" then (.project // "" | tostring) else "" end' "$L" 2>/dev/null || true)"
    if [ -n "$have" ]; then
      if [ "$(cm_lower "$have")" = "$(cm_lower "$id")" ]; then return 0; fi
      cm_warn "REFUSED: ledger $L belongs to project '$have'; this session runs project '$id'. Nothing was read or written. CM_HOME=${CM_HOME:-unset} CM_LEDGER=${CM_LEDGER:-unset} probably leaked in from the other project: unset them (this project's state dir is $def)."
      return 3
    fi
  fi
  dir="$(_cm_realdir "$(dirname "$L")")"; real="$(_cm_realdir "$def")"
  case "$dir/" in
    "$real/"*)
      if [ -s "$L" ]; then cm_warn "ledger $L has no project field (legacy file): read as project '$id' because it sits in this project's state dir; the next cm_ledger_write stamps it. Not rewritten by hand."; fi
      return 0 ;;
  esac
  if [ -s "$L" ]; then
    cm_warn "REFUSED: ledger $L has no project field and sits outside this project's state dir $def (project '$id'), so it may belong to another project. Nothing was read or written. If it is this project's, copy it to $def/ledger.json (it is stamped on its next write); otherwise unset CM_HOME and CM_LEDGER."
  else
    cm_warn "REFUSED: a new ledger would be created at $L, outside this project's state dir $def (project '$id'). Nothing was written. Unset CM_HOME and CM_LEDGER, or use $def."
  fi
  return 3
}

# ---- ledger writes ----------------------------------------------------------------------------
# EVERY write to the ledger goes through cm_ledger_write (references/ledger.md). 25 Oct 2026, 22:33Z:
# a filter produced no output, the guard `jq -s 'length == 1' l.tmp >/dev/null` exited 0 although it
# printed false, and an empty file replaced ledger.json. The checks below use jq -e and read the
# exit code; the old file is copied to a backup ring first.

# cm_ledger_path: the ledger file. CM_LEDGER (a path) overrides $CM_HOME/ledger.json.
cm_ledger_path() { printf '%s\n' "${CM_LEDGER:-$CM_HOME/ledger.json}"; }

# cm_ledger_bak_dir: the backup ring, next to the ledger ($CM_HOME/ledger.bak). CM_LEDGER_BAK overrides.
cm_ledger_bak_dir() { printf '%s\n' "${CM_LEDGER_BAK:-$(dirname "$(cm_ledger_path)")/ledger.bak}"; }

# cm_ledger_restore_hint: the one command that puts the newest backup back as the ledger.
cm_ledger_restore_hint() {
  # shellcheck disable=SC2016  # the $(...) is printed for the operator to run, not expanded here
  printf 'cp "$(ls -1 "%s"/[0-9]*T*Z*.json | LC_ALL=C sort | tail -1)" "%s"\n' "$(cm_ledger_bak_dir)" "$(cm_ledger_path)"
}

# _cm_ledger_bak_files: the ring's backups, oldest first. Only timestamp-named files count, so a
# file copied in by hand is never pruned and never picked as "newest".
_cm_ledger_bak_files() {
  local f
  for f in "$(cm_ledger_bak_dir)"/[0-9]*T*Z*.json; do
    if [ -e "$f" ]; then printf '%s\n' "$f"; fi
  done | LC_ALL=C sort
}

# The lock owner is a token written to <ledger>.lock/pid and kept in $_CM_LEDGER_LOCK_TOKEN. A bare
# pid is not enough: $$ is the same in every subshell of a script, so two parallel subshells would
# both look like the holder. A subshell inherits the token, so on bash 4+ the holder's $BASHPID is
# kept too and re-entry is the SAME shell only. On bash 3.2 (no BASHPID) a subshell of the holder
# counts as the holder: never start background writers while holding the lock.
_CM_LEDGER_LOCK_TOKEN=""
_CM_LEDGER_LOCK_SHELL=""

# _cm_ledger_lock_held: true when this shell took the ledger lock and nobody has stolen it since.
_cm_ledger_lock_held() {
  [ -n "$_CM_LEDGER_LOCK_TOKEN" ] && [ "$_CM_LEDGER_LOCK_SHELL" = "${BASHPID:-$$}" ] \
    && [ "$(cat "$(cm_ledger_path).lock/pid" 2>/dev/null)" = "$_CM_LEDGER_LOCK_TOKEN" ]
}

# cm_ledger_lock: take <ledger>.lock, a mkdir lock holding our token. Re-entrant: a shell that
# already holds it returns 0 at once. A lock older than 2 minutes is stale: it is renamed away
# (mv, so only one waiter wins) and the take is retried. Returns 1 after ~5s busy, nothing taken.
# mkdir, not flock: the lock must exclude every ledger writer on Linux and macOS (bash 3.2, no
# flock), and every writer takes this same directory.
cm_ledger_lock() {
  local lock i=0 tok
  lock="$(cm_ledger_path).lock"
  if _cm_ledger_lock_held; then return 0; fi
  if [ ! -d "$(dirname "$lock")" ]; then cm_warn "ledger directory $(dirname "$lock") missing: nothing written"; return 1; fi
  until mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && mv "$lock" "$lock.stale.$$.$RANDOM" 2>/dev/null; then
      rm -rf -- "${lock:?}".stale.*; continue
    fi
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then cm_warn "ledger lock $lock busy: nothing written"; return 1; fi
    sleep 0.1
  done
  tok="$$.$RANDOM$RANDOM.$(date +%s)"
  printf '%s\n' "$tok" > "$lock/pid"
  _CM_LEDGER_LOCK_TOKEN="$tok"
  _CM_LEDGER_LOCK_SHELL="${BASHPID:-$$}"
}

# cm_ledger_unlock: release the lock only when this shell still holds it (after a stale steal the
# old holder's exit must not remove the new holder's lock). Always returns 0, safe in an EXIT trap.
cm_ledger_unlock() {
  local lock
  lock="$(cm_ledger_path).lock"
  if _cm_ledger_lock_held; then
    rm -f -- "$lock/pid"; rmdir "$lock" 2>/dev/null || true
  fi
  _CM_LEDGER_LOCK_TOKEN=""; _CM_LEDGER_LOCK_SHELL=""
  return 0
}

# cm_ledger_write [--init] <jq-filter> [jq args...]
# Runs the filter against the current ledger and replaces the ledger with the result, or returns 1
# (2 on bad usage) with the ledger untouched and a reason on stderr. The write happens only when:
#   (a) the output is exactly one JSON object that has a "workers" key (jq -e, exit code read);
#   (b) the output is at least half the old file's bytes;
#   (c) the old ledger exists and is not empty.
# --init is the one way past (c), for a first boot: the filter runs with no input (jq -n, so it
# builds the whole document), and it refuses when a non-empty ledger exists, so it can never
# replace a live one. It also refuses when the backup ring holds copies (a lost ledger is restored,
# not re-created); CM_LEDGER_INIT_FORCE=1 overrides. Checks (a) still apply; (b) has nothing to compare with.
# Before replacing, the OLD file is copied to <ledger dir>/ledger.bak/<UTC timestamp>.json; the
# newest CM_LEDGER_BAK_KEEP (default 20) copies are kept. The new file is a temp file in the
# ledger's directory, moved over with mv (atomic). Holds the ledger lock (cm_ledger_lock) for the
# whole write, unless the caller already holds it.
# Safe under set -e and set -u: every step is tested explicitly, no step relies on set -e.
cm_ledger_write() {
  local init=0 L held=0 rc=0
  if [ "${1:-}" = "--init" ]; then init=1; shift; fi
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    cm_warn "cm_ledger_write: usage: cm_ledger_write [--init] <jq-filter> [jq args...]"; return 2
  fi
  command -v jq >/dev/null 2>&1 || { cm_warn "ledger write refused: jq missing"; return 1; }
  L="$(cm_ledger_path)"
  if [ "$init" = 1 ]; then
    cm_ledger_guard --create "$L" || return 3
    mkdir -p -- "$(dirname "$L")" 2>/dev/null || { cm_warn "ledger write refused: cannot create $(dirname "$L")"; return 1; }
  else
    cm_ledger_guard "$L" || return 3
  fi
  if _cm_ledger_lock_held; then held=1; fi
  cm_ledger_lock || return 1
  _cm_ledger_write_locked "$init" "$@" || rc=$?
  if [ "$held" = 0 ]; then cm_ledger_unlock; fi
  return "$rc"
}

# _cm_ledger_write_locked <init 0|1> <filter> [jq args...]: the body of cm_ledger_write, lock held.
_cm_ledger_write_locked() {
  local init="$1" filter="$2" L ring keep tmp err reason mode old_size=0 new_size ts bak seq last
  shift 2
  L="$(cm_ledger_path)"
  ring="$(cm_ledger_bak_dir)"
  keep="${CM_LEDGER_BAK_KEEP:-20}"
  case "$keep" in ''|*[!0-9]*) keep=20 ;; esac
  if [ "$keep" -lt 1 ]; then keep=1; fi

  # A write killed mid-way leaves its temp file: sweep the ones too old to belong to a live write.
  find "$(dirname "$L")" -maxdepth 1 -name "$(basename "$L").tmp.*" -mmin +2 -exec rm -f -- {} + 2>/dev/null || true

  if [ -f "$L" ] && [ -s "$L" ]; then
    if [ "$init" = 1 ]; then
      cm_warn "ledger write refused: --init but $L already exists and is not empty: ledger untouched"; return 1
    fi
    old_size="$(wc -c < "$L" | tr -d ' ')"
  elif [ -n "$(_cm_ledger_bak_files)" ] && [ "${CM_LEDGER_INIT_FORCE:-}" != 1 ]; then
    # A lost ledger with backups is a restore, not a first boot: --init would start a new history
    # and 20 writes later prune every good copy.
    cm_warn "ledger write refused: $L is missing or empty but $ring holds backups: this is a restore, not a first boot. Restore the newest backup with: $(cm_ledger_restore_hint) (CM_LEDGER_INIT_FORCE=1 overrides, only on the owner's word)"
    return 1
  elif [ "$init" = 0 ]; then
    cm_warn "ledger write refused: $L is missing or empty: nothing written. Pass --init on a first boot"
    return 1
  fi

  tmp="$(mktemp "$L.tmp.XXXXXX")" || { cm_warn "ledger write refused: cannot create a temp file next to $L: ledger untouched"; return 1; }
  if [ "$init" = 1 ]; then
    if ! err="$(jq -n ${@+"$@"} "$filter" 2>&1 >"$tmp")"; then
      rm -f -- "$tmp"; cm_warn "ledger write refused: jq failed (${err%%$'\n'*}): ledger untouched"; return 1
    fi
  else
    if ! err="$(jq ${@+"$@"} "$filter" "$L" 2>&1 >"$tmp")"; then
      rm -f -- "$tmp"; cm_warn "ledger write refused: jq failed (${err%%$'\n'*}): ledger untouched"; return 1
    fi
  fi

  # Stamp the ledger with this project's id when it has none (first boot, or a legacy file under this
  # project's state dir). A project field the filter set itself is left alone.
  if [ -n "${CM_PROJECT_ID:-}" ] && jq -e -s 'length == 1 and (.[0] | type == "object")' "$tmp" >/dev/null 2>&1; then
    if jq --arg p "$CM_PROJECT_ID" '.project //= $p' "$tmp" > "$tmp.stamp" 2>/dev/null; then mv -f -- "$tmp.stamp" "$tmp"; else rm -f -- "$tmp.stamp"; fi
  fi

  # (a) one object with a workers object (consumers read .workers as an object). jq -e exits non-zero on false; the exit code is tested here.
  if ! jq -e -s 'length == 1 and (.[0] | type == "object" and has("workers") and (.workers | type) == "object")' "$tmp" >/dev/null 2>&1; then
    if ! reason="$(jq -r -s 'if length == 0 then "the filter produced no output"
                             elif length > 1 then "the filter produced \(length) JSON documents, not one"
                             elif (.[0] | type) != "object" then "the output is a \(.[0] | type), not an object"
                             elif (.[0] | has("workers") | not) then "the output has no workers key"
                             elif (.[0].workers | type) != "object" then "workers is a \(.[0].workers | type), not an object"
                             else "the output failed validation" end' "$tmp" 2>/dev/null)"; then
      reason="the output is not valid JSON"
    fi
    rm -f -- "$tmp"; cm_warn "ledger write refused: $reason: ledger untouched"; return 1
  fi

  # (b) not under half the old size. Only an existing ledger has a size to compare with.
  new_size="$(wc -c < "$tmp" | tr -d ' ')"
  if [ "$old_size" -gt 0 ] && [ $((new_size * 2)) -lt "$old_size" ]; then
    rm -f -- "$tmp"
    cm_warn "ledger write refused: the new ledger is $new_size bytes, under half of the current $old_size: ledger untouched"; return 1
  fi

  # Keep the old mode (the temp file is 0600), back up the old file, prune the ring, then swap.
  if [ "$old_size" -gt 0 ]; then
    mode="$(stat -L -c %a "$L" 2>/dev/null || stat -L -f %Lp "$L" 2>/dev/null || echo 600)"
    chmod "$mode" "$tmp" 2>/dev/null || true
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    bak="$ring/$ts.json"
    # Same second: <ts>_002.json, <ts>_003.json ... sort after <ts>.json, so name order is write order.
    # One more than the newest name of this second, not the first free name: pruning can free the
    # oldest name of the second, and reusing it would make the newest copy sort as the oldest.
    last="$(_cm_ledger_bak_files | grep -F "$ring/$ts" | tail -1 || true)"
    if [ -e "$last" ]; then
      seq="${last##*_}"
      if [ "$last" = "$ring/$ts.json" ]; then seq=1; else seq="${seq%.json}"; fi
      bak="$ring/${ts}_$(printf '%03d' $((10#$seq + 1))).json"
    fi
    if ! { mkdir -p -- "$ring" && chmod 700 "$ring" && cp -- "$L" "$bak.part" && cmp -s -- "$L" "$bak.part" && mv -f -- "$bak.part" "$bak"; }; then
      rm -f -- "$tmp" "$bak.part"
      cm_warn "ledger write refused: cannot back up $L to $ring: ledger untouched"; return 1
    fi
    _cm_ledger_bak_files | LC_ALL=C sort -r | {
      n=0
      while IFS= read -r f; do
        n=$((n + 1))
        if [ "$n" -gt "$keep" ]; then rm -f -- "$f"; fi
      done
    }
  fi
  if ! _cm_ledger_lock_held; then
    rm -f -- "$tmp"; cm_warn "ledger write refused: the ledger lock was taken over mid-write: ledger untouched"; return 1
  fi
  if ! mv -f -- "$tmp" "$L"; then
    rm -f -- "$tmp"; cm_warn "ledger write refused: cannot move the new ledger into place at $L: ledger untouched"; return 1
  fi
  return 0
}

# ---- dead ledger records ----------------------------------------------------------------------
# A finished record (state gone or repurposed, or the old spelling torn-down) is dead: it holds no
# terminal handle and is ignored when a worktree path is matched. CM_JQ_STATE_DEFS puts the jq
# definition `cm_state_dead` in front of a jq program:
#   jq "$CM_JQ_STATE_DEFS"' .workers[] | select((.state // "running") | cm_state_dead | not)'
# shellcheck disable=SC2034  # read by lane-handles.sh
CM_JQ_STATE_DEFS='def cm_state_dead: type == "string" and IN("gone", "repurposed", "torn-down"); '

# ---- worker terminal handle setter ------------------------------------------------------------
# cm_worker_set_handle <worker-id> <handle>
# cm_worker_set_handle --by-path <host> <path> <handle>
# Refreshes workers.<id>.terminal (and terminalRefreshedAt) when the live agent process shows the
# ledger handle is stale (scripts/live-agent.sh, run by scripts/lane-handles.sh). The second
# form finds the worker by host and normalised path INSIDE the ledger lock: exactly one worker must
# match. Refuses (ledger untouched, reason on stderr) a handle that
# is not a plain token and a worker id the ledger does not hold. Also refuses a handle another worker
# already holds (an agent started from someone else's terminal inherits THAT terminal's handle).
# It changes nothing else, state included. Returns 0 written, 1 refused, 2 bad usage, 4 handle held by
# another worker, 5 no single worker for that host and path.
CM_JQ_NORMP='def normp: gsub("/\\.(?=/|$)"; "") | gsub("//+"; "/") | sub("(?<=.)/+$"; "");'
cm_worker_set_handle() {
  local id="" host="" path="" h="" held=0 rc=0 mode=id
  if [ "${1:-}" = "--by-path" ]; then
    mode=path
    if [ $# -ne 4 ] || [ -z "${2:-}" ] || [ -z "${3:-}" ] || [ -z "${4:-}" ]; then
      cm_warn "cm_worker_set_handle: usage: cm_worker_set_handle --by-path <host> <path> <handle>"; return 2
    fi
    host="$2"; path="$3"; h="$4"
  else
    id="${1:-}"; h="${2:-}"
    if [ $# -ne 2 ] || [ -z "$id" ] || [ -z "$h" ]; then
      cm_warn "cm_worker_set_handle: usage: cm_worker_set_handle <worker-id> <handle>"; return 2
    fi
  fi
  case "$h" in -*|*[!A-Za-z0-9._:-]*) cm_warn "cm_worker_set_handle: refused: \"$h\" is not a terminal handle"; return 1 ;; esac
  if _cm_ledger_lock_held; then held=1; fi
  cm_ledger_lock || return 1
  _cm_worker_set_handle_locked "$mode" "$id" "$host" "$path" "$h" || rc=$?
  if [ "$held" = 0 ]; then cm_ledger_unlock; fi
  return "$rc"
}

# _cm_worker_set_handle_locked <id|path> <worker-id> <host> <path> <handle>: the body of
# cm_worker_set_handle, lock held. Lookup and the held-by-another check happen here, under the lock.
_cm_worker_set_handle_locked() {
  local mode="$1" id="$2" host="$3" path="$4" h="$5" L other
  L="$(cm_ledger_path)"
  if [ "$mode" = path ]; then
    id="$(jq -r --arg h "$host" --arg p "$path" "$CM_JQ_NORMP"'
      [ (.workers // {}) | to_entries[] | select(.value | type == "object")
        | select((.value.host // "") == $h)
        | select(((.value.path // .value.worktree // .value.worktreePath // "") | normp) == ($p | normp))
        | .key ] | if length == 1 then .[0] else empty end' "$L" 2>/dev/null)"
    if [ -z "$id" ]; then cm_warn "cm_worker_set_handle: no single worker at $path on $host in $L"; return 5; fi
  fi
  if ! jq -e --arg id "$id" '(.workers | type) == "object" and (.workers[$id] | type) == "object"' "$L" >/dev/null 2>&1; then
    cm_warn "cm_worker_set_handle: refused: no worker \"$id\" in $L"; return 1
  fi
  # A ledger we cannot read for this question fails closed: no write.
  if ! other="$(jq -r --arg id "$id" --arg h "$h" "$CM_JQ_STATE_DEFS"'[ .workers | to_entries[] | select(.key != $id and (.value | type == "object") and .value.terminal == $h)
      | select((.value.state // "running") | cm_state_dead | not) | .key ] | .[0] // empty' "$L" 2>/dev/null)"; then
    cm_warn "cm_worker_set_handle: refused: cannot check which worker holds \"$h\""; return 1
  fi
  if [ -n "$other" ]; then cm_warn "cm_worker_set_handle: refused: worker \"$other\" already holds handle \"$h\""; return 4; fi
  # shellcheck disable=SC2016  # a jq program: $id, $h, $now are jq variables bound by --arg
  cm_ledger_write '.workers[$id].terminal = $h | .workers[$id].terminalRefreshedAt = $now | .workers[$id].updatedAt = $now | .updatedAt = $now' \
    --arg id "$id" --arg h "$h" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# cm_lane_for_path <host> <path>: the worker id of the one non-dead ledger worker at that host and path, else
# nothing (return 1). Same path normalisation as cm_worker_set_handle.
cm_lane_for_path() {
  local host="${1:-}" path="${2:-}" L out
  [ -n "$host" ] && [ -n "$path" ] || return 1
  L="$(cm_ledger_path)"
  out="$(jq -r --arg h "$host" --arg p "$path" "$CM_JQ_STATE_DEFS $CM_JQ_NORMP"'
    [ (.workers // {}) | to_entries[] | select(.value | type == "object")
      | select((.value.state // "running") | cm_state_dead | not)
      | select((.value.host // "local") == $h)
      | select(((.value.path // .value.worktree // .value.worktreePath // "") | normp) == ($p | normp))
      | .key ] | unique | if length == 1 then .[0] else empty end' "$L" 2>/dev/null)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# ---- per-lane handle file ---------------------------------------------------------------------
# $CM_HOME/lanes/<lane>/handle: ONE line, tab separated: terminal handle, host, agent, pid, written-at
# (UTC, ISO 8601). Written by scripts/lane-handles.sh from the LIVE agent process
# (scripts/live-agent.sh reads ORCA_TERMINAL_HANDLE from /proc/<pid>/environ), never from the ledger.
# A handle of "-" means "no usable live agent as of written-at" (none found, two agents, or an
# inherited handle another lane holds): a send must not happen. The file is not secret and never holds
# a token. Why it exists: a ledger terminal handle goes stale after a restart or a moved terminal, and a
# send that trusted it reached the wrong terminal or started a second agent in a live lane.
#
# <lane> in these names is the ledger WORKER ID (the key in workers, e.g. w-lane-a), a plain token. Not the
# worker's `lane` field: a lane is a group (the standing sweeper plus its spawned children, epic:* rows),
# a worker id is one agent, so it is the thing a handle belongs to.
CM_LANE_HANDLES_SH="$_cm_lib_dir/lane-handles.sh"
if [ -n "${CM_LANE_HANDLES:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then CM_LANE_HANDLES_SH="$CM_LANE_HANDLES"; else cm_warn "CM_LANE_HANDLES ignored (it needs CM_TEST=1)"; fi
fi

# cm_lane_dir <lane>: the lane's directory; refuses anything that is not a plain token.
cm_lane_dir() {
  case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) cm_warn "lane handle: \"${1:-}\" is not a lane name"; return 1 ;; esac
  # a symlinked lane directory would send the handle file (and its temp files) wherever the link points
  if [ -L "$CM_HOME/lanes" ] || [ -L "$CM_HOME/lanes/$1" ]; then cm_warn "lane handle: $CM_HOME/lanes/$1 is reached through a symlink: refused"; return 1; fi
  printf '%s/lanes/%s\n' "$CM_HOME" "$1"
}

# cm_lane_handle_max_age: seconds a handle file may be old and still be trusted for a send
# (handles.max_age_s, default 900: a few tick windows).
cm_lane_handle_max_age() {
  local v
  v="$(cm_cfg .handles.max_age_s 900)"
  case "$v" in ''|*[!0-9]*) v=900 ;; *) v=$((10#$v)) ;; esac
  [ "$v" -gt 0 ] || v=900
  printf '%s\n' "$v"
}

# cm_lane_handle_write <lane> <handle|-> <host> <agent> <pid|-> [observed-at]: atomic (temp file in the lane
# dir, then mv). Concurrent writers each write a whole line from their own temp file, so the file is never
# torn. observed-at (UTC ISO 8601, default now) is when the agent was OBSERVED, not when the file was
# written: a slow multi-host run must not make a file look fresher than the look it holds. A file already
# newer than observed-at is left alone (a concurrent run saw the agent later): return 3, NOT a failure,
# and the caller must not act on the older observation (no ledger update).
# A FAILED write fails closed: the old file is removed, and when that is not possible (an unwritable lane
# dir) a marker lanes/.failed/<lane> makes the reader distrust the old file until a write succeeds. The
# previous handle is known to be out of date, so it is never served for up to handles.max_age_s.
cm_lane_handle_write() {
  local lane="${1:-}" dir rc
  dir="$(cm_lane_dir "$lane")" || return 1
  _cm_lane_handle_write "$@"; rc=$?
  if [ "$rc" = 0 ]; then
    if [ ! -L "$CM_HOME/lanes/.failed" ]; then rm -f -- "${CM_HOME:?}/lanes/.failed/$lane" 2>/dev/null; fi
    return 0
  fi
  [ "$rc" = 3 ] && return 3   # superseded: the file is a newer observation, nothing failed
  [ "$rc" = 4 ] && return 4   # lock busy: another writer is mid-write, so the file is theirs to land: not touched
  rm -f -- "${dir:?}/handle" 2>/dev/null
  if ! { [ ! -L "$CM_HOME/lanes/.failed" ] && [ ! -L "$CM_HOME/lanes/.failed/$lane" ] && (umask 077; mkdir -p "$CM_HOME/lanes/.failed" && : > "$CM_HOME/lanes/.failed/$lane") 2>/dev/null; } && [ -e "$dir/handle" ]; then
    cm_warn "lane handle: $lane write failed and the old file could be neither removed nor marked: it may be served until it ages out"
  fi
  return 1
}

_cm_lane_handle_write() {
  local lane="${1:-}" h="${2:-}" host="${3:-}" agent="${4:-}" pid="${5:--}" at="${6:-}" dir
  dir="$(cm_lane_dir "$lane")" || return 1
  # "-" alone is the dead mark; any other handle is a plain token that does not start with "-" (it would be read as an option by `--terminal "$h"` users)
  case "$h" in -) ;; ''|-*|*[!A-Za-z0-9._:-]*) cm_warn "lane handle: refused: \"$h\" is not a terminal handle"; return 1 ;; esac
  case "$pid" in -|*[!0-9]*) [ "$pid" = - ] || pid=- ;; esac
  case "$at" in '') at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;; [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) cm_warn "lane handle: refused: \"$at\" is not a UTC time"; return 1 ;; esac
  host="$(printf '%s' "${host:-local}" | tr -c 'A-Za-z0-9._-' '_')"
  agent="$(printf '%s' "${agent:--}" | tr -c 'A-Za-z0-9._-' '_')"; [ -n "$agent" ] || agent=-
  (umask 077; mkdir -p "$dir") 2>/dev/null || { cm_warn "lane handle: cannot create $dir"; return 1; }
  # The newer-observation check and the mv are one step under a per-lane lock (mkdir is atomic): without it two
  # writers can both read the old file and the older observation's mv can land last. A lock older than a
  # minute is a dead writer's and is taken over by an atomic rename (one waiter wins; a claim that turns out
  # fresh is put back). Every pass that sees the lock counts as a try, so a lock that cannot be moved never
  # spins; passes that miss it (released mid-check) are bounded separately, 2 in a row. Not obtained in about 3 s
  # of contention (60 tries; up to 9 s if every try is also preceded by two misses): exit 4, nothing written and
  # the existing file left as it is (the holder is about to replace it).
  local lk="$dir/.lock" tries=0 misses=0 rc=0
  until mkdir "$lk" 2>/dev/null; do
    # mkdir failing with no lock there is not contention (a directory that cannot be written): a real failure.
    # But a holder can release between the failed mkdir and this test, and another writer can take the lock
    # again before the retry: one more mkdir decides each time, and only 3 misses in a row with the lock still
    # absent are a failure. Without the retry the loser of a race returns 1, and the fail-closed path then
    # removes the winner's file.
    if [ ! -e "$lk" ] && [ ! -L "$lk" ]; then
      if mkdir "$lk" 2>/dev/null; then break; fi
      misses=$((misses + 1))
      if [ "$misses" -ge 3 ]; then cm_warn "lane handle: cannot lock $dir"; return 1; fi
      sleep 0.05; continue
    fi
    misses=0
    if [ -n "$(find "$lk" -maxdepth 0 -mmin +1 2>/dev/null)" ] && mv -- "$lk" "$lk.old.$$" 2>/dev/null; then
      if [ -n "$(find "${lk:?}.old.$$" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf -- "${lk:?}.old.$$"
      elif [ ! -e "$lk" ] && [ ! -L "$lk" ] && mv -- "${lk:?}.old.$$" "$lk" 2>/dev/null; then :   # put back, never nested inside a newer lock
      else rm -rf -- "${lk:?}.old.$$"; fi
    fi
    tries=$((tries + 1)); if [ "$tries" -ge 60 ]; then cm_warn "lane handle: $lane is locked by another writer: not written"; return 4; fi
    sleep 0.05
  done
  _cm_lane_handle_commit "$lane" "$dir" "$h" "$host" "$agent" "$pid" "$at" || rc=$?
  rmdir "$lk" 2>/dev/null
  return "$rc"
}

# _cm_lane_handle_commit <lane> <dir> <handle> <host> <agent> <pid> <at>: the part of the write that runs under the lock
_cm_lane_handle_commit() {
  local lane="$1" dir="$2" h="$3" host="$4" agent="$5" pid="$6" at="$7" tmp oldat oldts
  if [ -s "$dir/handle" ]; then
    IFS=$'\t' read -r _ _ _ _ oldat < "$dir/handle" || true
    # only a well-formed time that is not a clock-skewed future one decides; ISO 8601 UTC strings of one shape sort as time
    oldts="$(jq -rn --arg t "$oldat" '$t | fromdateiso8601' 2>/dev/null)"
    case "$oldts" in ''|*[!0-9]*) ;; *) if [ "$oldts" -le "$(( $(date +%s) + 60 ))" ] && [[ "$oldat" > "$at" ]]; then return 3; fi ;; esac
  fi
  tmp="$(umask 077; mktemp "$dir/.handle.XXXXXX")" || { cm_warn "lane handle: cannot write in $dir"; return 1; }
  if ! { printf '%s\t%s\t%s\t%s\t%s\n' "$h" "$host" "$agent" "$pid" "$at" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dir/handle"; }; then
    rm -f -- "${tmp:?}"; cm_warn "lane handle: write failed for $lane"; return 1
  fi
}

# _cm_lane_agent_alive <pid> <handle>: the agent the file was written from is still the process holding that
# terminal: /proc/<pid> exists and its environ ORCA_TERMINAL_HANDLE is <handle>. No /proc on this host
# (macOS): cannot tell, 0 (lane-handles.sh's own live check exits 3 there too). A process entry that
# cannot be read fails closed. Returns 0 alive, 1 the pid is gone, 2 it carries another terminal, 3 its
# environ is unreadable (another uid, hidepid). What it proves: the process EXISTS and was STARTED with
# that terminal in its environment, not that Orca has not moved it since. CM_PROC_ROOT is honoured with
# CM_TEST=1 only, as in live-agent.sh. Files with a pid only come from live-agent.sh output, which needs
# /proc, so a host without it never holds a pid to check.
_cm_lane_agent_alive() {
  local root=/proc kv
  if [ "${CM_TEST:-}" = 1 ] && [ -n "${CM_PROC_ROOT:-}" ]; then root="$CM_PROC_ROOT"; fi
  [ -d "$root" ] || return 0
  [ -d "$root/$1" ] || return 1
  [ -r "$root/$1/environ" ] || return 3
  while IFS= read -r -d '' kv || [ -n "$kv" ]; do
    case "$kv" in ORCA_TERMINAL_HANDLE=*) if [ "${kv#ORCA_TERMINAL_HANDLE=}" = "$2" ]; then return 0; fi; return 2 ;; esac
  done < "$root/$1/environ"
  return 2
}

# _cm_lane_handle_read <lane>: sets LH_STATE (fresh | stale | bad | missing), LH_HANDLE, LH_AT, LH_AGE.
_cm_lane_handle_read() {
  local f h host agent pid at ts now max
  LH_STATE=missing; LH_HANDLE=""; LH_AT=""; LH_AGE=""; LH_WHY=""
  f="$(cm_lane_dir "$1")/handle" || { LH_STATE=bad; return; }
  # a failed write marked this lane: whatever file is still there is known to be out of date
  if [ -L "$CM_HOME/lanes/.failed" ]; then LH_STATE=bad; LH_WHY="lanes/.failed is a symlink: refused"; return; fi
  if [ -e "$CM_HOME/lanes/.failed/$1" ]; then LH_STATE=bad; return; fi
  [ -e "$f" ] || return 0
  [ -s "$f" ] || { LH_STATE=bad; return; }   # an empty file is not "never checked"
  IFS=$'\t' read -r h host agent pid at < "$f" || true
  case "$h" in -) ;; ''|-*|*[!A-Za-z0-9._:-]*) LH_STATE=bad; return ;; esac
  ts="$(jq -rn --arg t "$at" '$t | fromdateiso8601' 2>/dev/null)"
  case "$ts" in ''|*[!0-9]*) LH_STATE=bad; return ;; esac
  now="$(date +%s)"; max="$(cm_lane_handle_max_age)"
  LH_HANDLE="$h"; LH_AT="$at"; LH_AGE=$((now - ts))
  # a file dated in the future (clock skew) is not trusted either
  if [ "$LH_AGE" -ge -60 ] && [ "$LH_AGE" -le "$max" ]; then LH_STATE=fresh; else LH_STATE=stale; fi
  # A fresh file for a LOCAL agent whose process is gone, or no longer holds that terminal, is stale: the
  # agent exited or moved inside the window, and a send would land in the shell left in the terminal.
  if [ "$LH_STATE" = fresh ] && [ "$h" != - ] && [ "${host:-local}" = local ]; then
    case "$pid" in ''|-|*[!0-9]*) ;; *)
      _cm_lane_agent_alive "$pid" "$h"; case "$?" in
        0) ;;
        1) LH_STATE=stale; LH_WHY="agent pid $pid is gone" ;;
        2) LH_STATE=stale; LH_WHY="agent pid $pid does not carry terminal $h" ;;
        *) LH_STATE=stale; LH_WHY="agent pid $pid cannot be inspected (environ unreadable)" ;;
      esac ;;
    esac
  fi
}

# cm_lane_handle <lane>: prints the terminal handle to send to. A terminal send to a lane that has a lane file
# should read this, never the ledger. A caller that cannot (fleet-state.sh push_freeze messages the -sweeper
# lanes, which have no lane file) reads a live `terminal list` and sends only when the worktree has exactly
# one Claude terminal (the same two-agents rule).
#   file fresh, handle set      print it, 0. "Fresh" for a local agent also means its pid still exists and
#                               still holds that terminal (/proc/<pid>/environ); otherwise it is stale.
#   file fresh, handle "-"      no live agent (or not one agent): nothing printed, 1
#   file stale, bad (unparsable, empty, a failed write on record) or MISSING
#                               the live check is re-run for this lane first (lane-handles.sh --worker);
#                               still not fresh after that (nothing written: the check could not run, the
#                               lane is not in the ledger): nothing printed, 3. Never a handle from the
#                               ledger, never a stale or unverified one.
#   bad usage                   2
cm_lane_handle() {
  local lane="${1:-}" n
  [ -n "$lane" ] || { cm_warn "cm_lane_handle: usage: cm_lane_handle <lane>"; return 2; }
  case "$lane" in .*|*[!A-Za-z0-9._-]*) cm_warn "lane handle: \"$lane\" is not a lane name"; return 2 ;; esac
  cm_lane_dir "$lane" >/dev/null || return 3   # a symlinked lanes/ or lanes/<id>: not verifiable, no send
  _cm_lane_handle_read "$lane"
  if [ "$LH_STATE" != fresh ]; then
    cm_warn "lane handle: $lane file is $LH_STATE${LH_AGE:+ ($LH_AGE s old)}${LH_WHY:+, $LH_WHY}: re-checking the live agent"
    if [ ! -x "$CM_LANE_HANDLES_SH" ]; then cm_warn "lane handle: $CM_LANE_HANDLES_SH is missing or not executable: no re-check possible"; fi
    "$CM_LANE_HANDLES_SH" --worker "$lane" --quiet </dev/null >/dev/null 2>&1 || true
    _cm_lane_handle_read "$lane"
    if [ "$LH_STATE" != fresh ]; then
      cm_warn "lane handle: $lane has no fresh handle after the re-check ($LH_STATE): no send"; return 3
    fi
  fi
  case "$LH_STATE" in
    fresh)
      if [ "$LH_HANDLE" = - ]; then cm_warn "lane handle: $lane has no usable live agent as of $LH_AT: no send"; return 1; fi
      printf '%s\n' "$LH_HANDLE"; return 0 ;;
  esac
  n="${LH_STATE:-?}"; cm_warn "lane handle: $lane: unexpected state $n"; return 3
}

# A healthy Claude pane ends with one of these footers (boot-sweep.sh tick mode): the status line, the
# permissions line, the shortcuts hint, or a subagent/task row. A shell prompt (any style) or an error never does.
# shellcheck disable=SC2034  # read by boot-sweep.sh
CM_FOOTER_RE='⏵⏵|⏸|plan mode on|bypass permissions|accept edits on|auto-accept|\? for shortcuts|esc to interrupt|(·|•)[[:space:]]+eff(ort)?[[:space:]]+[a-z]+|ctx \[|^[[:space:]]*(◯|●|◐|◑|⎿|✻|✢|✳|✶|✽)[[:space:]]'
# One model/effort line of a Claude pane: the banner ("<Model> <ver> with <effort> effort") or the status line
# ("<model>-<ver> · eff <effort>"). spawn-verify.sh judges the bottom-most such line against the expected model.
# shellcheck disable=SC2034  # read by spawn-verify.sh
CM_ANY_MODEL_RE='[[:alpha:]]+[ -]?[0-9]+(\.[0-9]+)?[^[:alnum:]]{1,6}(with )?[a-z]*[ ]?(effort|eff )'

# cm_text_looks_secret: reads text on stdin, exit 0 when it looks like a credential, a brief or a private path.
# The ONE place a script that publishes free text (followups.sh escalate) asks "may this leave the host?". It is
# the union of (1) the shape list of scan-secrets.sh (RES there: RE_PK, RE_TP, RE_TPB with its BND left boundary,
# RE_SK, RE_JWT, RE_AWS, RE_URL, RE_PW, RE_BEARER), copied below with the length minimums lowered where a gate that
# refuses may be stricter than a counter, (2) the vendor prefixes programme-rollup.sh scrubs (glpat-, ghr_, xapp-,
# xoxa/xoxe), npm tokens and a plain "the password is ..." sentence, and (3) brief and private-path shapes. The text
# is checked as read AND with every non-ASCII byte removed, so a soft hyphen, a variation selector or a combining
# mark inside a key cannot split it. A heuristic, not a scanner: it refuses, it does not grade. Keep the shapes in
# step with scan-secrets.sh (test/followups-escalate.sh section 9 feeds one sample per shape).
_cm_ci() { printf '%s' "$1" | awk '{ o = ""; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c ~ /[A-Za-z]/) o = o "[" tolower(c) toupper(c) "]"; else o = o c } print o }'; }
_cm_secret_init() {   # lazy: building the case-insensitive names costs forks, and every script sources this file
  [ -z "${CM_RE_SECRET_READY:-}" ] || return 0
  CM_RE_SECRET_BND='(^|\\[ntr]|%[0-9A-Fa-f]{2}|[^A-Za-z0-9_-])'
  CM_RE_SECRET_PWNAME="($(_cm_ci PASSWORD)|$(_cm_ci PASSWD)|$(_cm_ci PWD)|$(_cm_ci PASSPHRASE)|$(_cm_ci SECRET)|$(_cm_ci API)_?$(_cm_ci KEY)|$(_cm_ci ACCESS)_?$(_cm_ci TOKEN)|$(_cm_ci AUTH)_?$(_cm_ci TOKEN))"
  # the scan-secrets.sh shapes (case-sensitive; the *_ci ones spell their letters out)
  CM_RE_SECRET_SCAN=(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    '(sk-ant-|sk-proj-|whsec_|ghp_|gho_|ghs_|ghu_|ghr_|github_pat_|xox[abeprs]-|sbp_|sb_secret_)[A-Za-z0-9_-]{16,}'
    # the Stripe-style keys end in a word that snake_case text also ends in (task_test_data): a letter before
    # the prefix means it is the tail of a longer word, not a key. Any other character before it (=, a space, an underscore, a digit)
    # is not, and neither is a JSON or URL escape (a literal \n, \t, %3D: they end in a letter but are not part of a word).
    '(^|\\[ntr]|%[0-9A-Fa-f]{2}|[^A-Za-z])(sk_live_|sk_test_|rk_live_|rk_test_)[A-Za-z0-9_-]{16,}'
    "${CM_RE_SECRET_BND}(sk-svcacct-|sk-admin-|sk-or-|sk-None-|AIza)[A-Za-z0-9_-]{16,}"
    "${CM_RE_SECRET_BND}sk-[A-Za-z0-9]{48}"
    'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    '(AKIA|ASIA)[A-Z0-9]{16}'
    "[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@\"']{0,64}:[^/[:space:]@\"']{1,}@"
    "${CM_RE_SECRET_PWNAME}[A-Za-z_]{0,12}[\\\\\"']{0,6}[[:space:]]*[:=][[:space:]]*[\\\\\"']{0,6}[^[:space:]\"',;)}\\\\]{10,}"
    "$(_cm_ci BEARER)[[:space:]]+[A-Za-z0-9._~+/=-]{24,}"
  )
  CM_RE_SECRET_READY=1
}
CM_RE_SECRET_CS='(AKIA|ASIA)[A-Z0-9]{12,}|npm_[A-Za-z0-9]{20,}'
CM_RE_SECRET_CI='(ghp|gho|ghs|ghu|ghr|github_pat)_[A-Za-z0-9_]{10,}|glpat-[A-Za-z0-9_-]{10,}|xapp-[A-Za-z0-9-]{8,}|xox[abeprs]-[A-Za-z0-9-]{8,}|(^|[^A-Za-z0-9-])sk-[A-Za-z0-9_-]{16,}|(^|\\[ntr]|%[0-9A-Fa-f]{2}|[^A-Za-z])[sr]k_(live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}|sb_(secret|publishable)_[A-Za-z0-9_-]{8,}|sbp_[A-Za-z0-9]{12,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.|AIza[0-9A-Za-z_-]{20,}|-----BEGIN|_authToken[[:space:]]*=[[:space:]]*[^[:space:]]{6,}|(password|passwd|passphrase|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*([A-Za-z0-9+/_.-]{3,}[0-9]|[A-Za-z0-9+/_.-]*[0-9][A-Za-z0-9+/_.-]{3,})|(password|passwd|passphrase|secret|api[_-]?key)[[:space:]]+(is|was|are|=)[[:space:]]+[^[:space:]]*[0-9][^[:space:]]*|(password|passwd|passphrase)[[:space:]]+(is|was)[[:space:]]+[^[:space:]]{8,}|\.secrets|(^|[^[:alnum:]_.])\.env([^[:alnum:]_]|$)|briefs?/|/home/[A-Za-z0-9._-]+/|/Users/[A-Za-z0-9._-]+/|/root/|~/|bearer [A-Za-z0-9._-]{12,}'
_cm_secret_hit() { # $1 = text; 0 when any shape matches (a newline is a line break for grep, so a key after one still counts)
  local re; _cm_secret_init
  for re in "${CM_RE_SECRET_SCAN[@]}"; do grep -Eq -e "$re" <<<"$1" && return 0; done
  grep -Eq -e "$CM_RE_SECRET_CS" <<<"$1" && return 0
  grep -Eqi -e "$CM_RE_SECRET_CI" <<<"$1"
}
cm_text_looks_secret() {
  local t a; t="$(cat)"
  _cm_secret_hit "$t" && return 0
  a="$(printf '%s' "$t" | LC_ALL=C tr -d '\200-\377')"
  [ "$a" = "$t" ] && return 1
  _cm_secret_hit "$a"
}

# ---- local Supabase stacks -----------------------------------------------------------------------
# The Supabase CLI keys a local stack by its project id (`project_id` in supabase/config.toml), and
# labels every container `com.supabase.cli.project=<id>`. Nothing ties a container to a worktree:
# the containers carry only that label and the compose project label, and
# their mounts are named volumes, so a stack outlives the worktree that started it. The checked-in id
# is shared by every worktree that does not override it, so an id alone never proves ownership.
#
# CM_SB_SCAN_SH: ONE fixed POSIX sh script, run on the target host with every worktree path as a
# positional argument (locally `sh -c "$CM_SB_SCAN_SH" sh <paths>`, over ssh `sh -s -- <paths>` with
# the script on stdin, teardown.sh through its rrun). Tab separated facts, then an end marker:
#   W <path> <project id>         the project_id in <path>/supabase/config.toml ("" when none)
#   D ok|nodocker|unreachable     whether docker could be read at all
#   CLI yes|no                    whether the supabase CLI is on PATH (only after D ok)
#   C <container id> <project id> a RUNNING container carrying the Supabase CLI label
#   M <container id> <source>     a bind mount of that container
#   END
# Over ssh the shell is non-interactive with a short PATH, so the usual docker and supabase install dirs are
# appended there (only when the shell is an ssh session). docker never reads this script's stdin (over ssh the script itself arrives there). A host with no docker, or a docker that does not answer, says so: callers never read that as "no
# stacks" (cm_sb_parse keeps it as docker=nodocker|unreachable). Read-only.
# shellcheck disable=SC2016,SC2034  # single quotes on purpose (the text runs on the target host); used by teardown.sh and discover.sh
CM_REMOTE_PATH_FIX='if [ -n "${SSH_CONNECTION:-}" ]; then PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/snap/bin"; export PATH; fi'
# shellcheck disable=SC2016,SC2034
CM_SB_SCAN_SH="$CM_REMOTE_PATH_FIX"'
q=$(printf "\047")
for p in "$@"; do
  id=$(sed -n -e "s/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" -e "s/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*$q\([^$q]*\)$q.*/\1/p" "$p/supabase/config.toml" 2>/dev/null | head -n 1)
  printf "W\t%s\t%s\n" "$p" "$id"
done
if ! command -v docker >/dev/null 2>&1; then printf "D\tnodocker\nEND\n"; exit 0; fi
t=""; command -v timeout >/dev/null 2>&1 && t="timeout 20"
if ! rows=$($t docker ps --filter label=com.supabase.cli.project --format "{{.ID}} {{.Label \"com.supabase.cli.project\"}}" 2>/dev/null </dev/null); then
  printf "D\tunreachable\nEND\n"; exit 0
fi
printf "D\tok\n"
if command -v supabase >/dev/null 2>&1; then printf "CLI\tyes\n"; else printf "CLI\tno\n"; fi
printf "%s\n" "$rows" | while read -r cid pid; do
  [ -n "$cid" ] && printf "C\t%s\t%s\n" "$cid" "$pid"
done
ids=$(printf "%s\n" "$rows" | awk "NF { printf \"%s \", \$1 }")
if [ -n "$ids" ]; then
  # One inspect for every container (a host can hold many): "<12 char id> <bind mount source>".
  # shellcheck disable=SC2086
  $t docker inspect -f "{{\$id := printf \"%.12s\" .Id}}{{range .Mounts}}{{if eq .Type \"bind\"}}{{\$id}} {{.Source}}{{\"\\n\"}}{{end}}{{end}}" $ids 2>/dev/null </dev/null | while read -r cid src; do
    [ -z "$src" ] || printf "M\t%s\t%s\n" "$cid" "$src"
  done
fi
printf "END\n"'

# cm_sb_id_ok <id>: a Supabase project id is safe to pass on a command line (the CLI allows
# letters, digits, dot, dash and underscore). Anything else is ignored with a warning, never run.
cm_sb_id_ok() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*|-*) return 1 ;; esac
  return 0
}

# cm_sb_parse: stdin = the CM_SB_SCAN_SH output; stdout = one JSON object
#   {complete, docker, worktrees:[{path, projectId}], stacks:[{projectId, containers, mounts:[...]}]}
# complete is false when the END marker is missing (cut off) or docker was not readable.
cm_sb_parse() {
  jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t")) as $r
    | ([$r[] | select(.[0] == "D") | .[1]] | first // "missing") as $d
    | ($r | map(select(.[0] == "END")) | length > 0) as $end
    | {complete: ($end and $d == "ok"),
       ended: $end,
       docker: $d,
       supabaseCli: (([$r[] | select(.[0] == "CLI") | .[1]] | first // "no") == "yes"),
       worktrees: [$r[] | select(.[0] == "W") | {path: .[1], projectId: (.[2] // "")}],
       stacks: ([$r[] | select(.[0] == "C") | {cid: .[1], projectId: (.[2] // "")}] as $c
         | [$r[] | select(.[0] == "M") | {cid: .[1], source: (.[2] // "")}] as $m
         | $c | group_by(.projectId)
         | map({projectId: .[0].projectId, containers: length,
                mounts: ([ .[] as $x | $m[] | select(.cid == $x.cid) | .source ] | unique)}))}'
}

# cm_sb_collect <host> <kind> <ssh-target> <truncated:true|false> <worktree path>...: one census entry
#   {host, ok, error, docker, truncated, worktrees:[{path, projectId}], stacks:[{projectId, containers, mounts}]}
# for a reachable host: the scan runs here when <kind> is local, over `ssh <ssh-target>` (key auth only,
# bounded) otherwise. ok is false when the scan did not finish (ssh failed, timed out, cut off); docker says
# ok, nodocker or unreachable, and neither of the last two is ever read as "no stacks" (classify.jq
# turns them into a CHECK INCOMPLETE gap). <truncated> says the host's worktree list was cut off.
cm_sb_collect() {
  local h="$1" kind="$2" target="$3" trunc="$4" raw="" rc=0 args="" a parsed
  shift 4
  if [ "$kind" = local ]; then
    raw="$(cm_timeout 40 sh -c "$CM_SB_SCAN_SH" sh "$@" 2>/dev/null)" || rc=$?
  else
    case "$target" in -*|*[[:space:]]*|'')
      jq -cn --arg h "$h" --arg t "$target" '{host:$h, ok:false, error:("invalid ssh target " + ($t | tojson)), docker:"unknown", truncated:false, worktrees:[], stacks:[]}'
      return 0 ;; esac
    for a in "$@"; do args="$args '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"; done
    raw="$(printf '%s\n' "$CM_SB_SCAN_SH" | cm_timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$target" "sh -s --$args" 2>/dev/null)" || rc=$?
  fi
  parsed="$(printf '%s\n' "$raw" | cm_sb_parse 2>/dev/null)" || parsed=""
  [ -n "$parsed" ] || parsed='{"ended":false,"docker":"missing","worktrees":[],"stacks":[]}'
  printf '%s' "$parsed" | jq -c --arg h "$h" --argjson rc "$rc" --argjson tr "$trunc" '
    {host: $h, ok: (.ended and $rc == 0),
     error: (if .ended and $rc == 0 then null
             elif $rc == 124 or $rc == 142 then "stack scan timed out"
             else "stack scan did not finish (exit \($rc))" end),
     docker: .docker, truncated: $tr, worktrees: .worktrees, stacks: .stacks}'
}
