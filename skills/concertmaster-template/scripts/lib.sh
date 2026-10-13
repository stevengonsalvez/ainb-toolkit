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
