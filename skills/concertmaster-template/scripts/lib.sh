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

# Resolve the Orca CLI per the orca-cli skill: $ORCA_CLI_COMMAND, else
# orca-ide on Linux outside an Orca terminal (bare `orca` there is the GNOME
# screen reader), else orca.
cm_orca() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    printf '%s\n' "$ORCA_CLI_COMMAND"
  elif [ "$(uname -s)" = "Linux" ] && [ "${TERM_PROGRAM:-}" != "Orca" ] && command -v orca-ide >/dev/null 2>&1; then
    printf '%s\n' orca-ide
  else
    printf '%s\n' orca
  fi
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
    mkdir -p -- "$(dirname "$L")" 2>/dev/null || { cm_warn "ledger write refused: cannot create $(dirname "$L")"; return 1; }
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
# A healthy Claude pane ends with one of these footers (boot-sweep.sh tick mode): the status line, the
# permissions line, the shortcuts hint, or a subagent/task row. A shell prompt (any style) or an error never does.
# shellcheck disable=SC2034  # read by boot-sweep.sh
CM_FOOTER_RE='⏵⏵|⏸|plan mode on|bypass permissions|accept edits on|auto-accept|\? for shortcuts|esc to interrupt|(·|•)[[:space:]]+eff(ort)?[[:space:]]+[a-z]+|ctx \[|^[[:space:]]*(◯|●|◐|◑|⎿|✻|✢|✳|✶|✽)[[:space:]]'
# One model/effort line of a Claude pane: the banner ("<Model> <ver> with <effort> effort") or the status line
# ("<model>-<ver> · eff <effort>"). spawn-verify.sh judges the bottom-most such line against the expected model.
# shellcheck disable=SC2034  # read by spawn-verify.sh
CM_ANY_MODEL_RE='[[:alpha:]]+[ -]?[0-9]+(\.[0-9]+)?[^[:alnum:]]{1,6}(with )?[a-z]*[ ]?(effort|eff )'
