#!/usr/bin/env bash
# ~/.gemini/antigravity-cli/statusline.sh: Antigravity CLI rich two-line statusline
# Line 1: cwd · git branch+changes · reflect errors · beads · caveman
# Line 2: model · mode/eff · session health · ctx bar · quota bar · tasks · artifacts · HR · RTK
#
# Reads JSON session state from stdin (Antigravity CLI schema).
# Single-pass jq parse + file-based micro-cache keeps execution < 80ms.
# All slow external commands are timeout-guarded with silent fallbacks.

set -o pipefail

# ── ANSI colour codes ────────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'

FG_GREEN='\033[32m'
FG_YELLOW='\033[33m'
FG_RED='\033[31m'
FG_CYAN='\033[36m'
FG_BLUE='\033[34m'
FG_MAGENTA='\033[35m'
FG_GREY='\033[90m'

SEP="${FG_GREY}·${RESET}"

# ── 10-second file cache for slow commands ───────────────────────────────────
CACHE_DIR="/tmp/antigravity-statusline-cache-${USER}"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_TTL=10

_cache_get() {
  local f="$CACHE_DIR/$1"
  [[ -f "$f" ]] || return
  local now mtime
  now=$(date +%s)
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  if (( (now - mtime) < CACHE_TTL )); then
    cat "$f" 2>/dev/null
  fi
}

_cache_set() {
  printf '%s' "$2" > "$CACHE_DIR/$1" 2>/dev/null || true
}

# ── Unicode progress bar ──────────────────────────────────────────────────────
# Usage: _bar <percent 0-100> [amber_at=60] [red_at=85]
# RAG: green < amber_at, amber <= pct < red_at, red >= red_at (6 blocks wide)
_bar() {
  local pct=${1:-0}
  local amber=${2:-60}
  local red=${3:-85}
  local total=6
  local filled=$(( pct * total / 100 ))
  (( filled > total )) && filled=$total
  local empty=$(( total - filled ))
  local col
  if   (( pct < amber )); then col=$FG_GREEN
  elif (( pct < red   )); then col=$FG_YELLOW
  else                         col=$FG_RED
  fi
  local bar="" i
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done
  printf "${col}[${bar}] ${pct}%%${RESET}"
}

# ── Format a Unix epoch as local time ─────────────────────────────────────────
# Usage: _fmt_epoch <epoch-seconds> <strftime-fmt>. Empty on bad input.
_fmt_epoch() {
  [[ "$1" =~ ^[0-9]+$ ]] || return
  date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null || true
}

# ── timeout wrapper ───────────────────────────────────────────────────────────
_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then _TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then _TIMEOUT_BIN="gtimeout"
fi

_to() {
  if [[ -n "$_TIMEOUT_BIN" ]]; then "$_TIMEOUT_BIN" "$@"
  else shift; "$@"; fi
}

# ── Count un-acked reflect errors ─────────────────────────────────────────────
_reflect_err_count() {
  local f="$HOME/.reflect/errors.json"
  if [[ -f "$f" ]]; then
    # Fast regex count of un-acked errors
    local count
    count=$(grep -c '"acked": false' "$f" 2>/dev/null || true)
    if [[ -n "$count" && "$count" =~ ^[0-9]+$ ]]; then
      echo "$count"
      return
    fi
    if command -v jq >/dev/null 2>&1; then
      jq -r '[.errors[]? | select(.acked != true)] | length' "$f" 2>/dev/null && return
    fi
  fi
  if command -v reflect >/dev/null 2>&1; then
    reflect errors count 2>/dev/null && return
  fi
  echo 0
}

# ── Read JSON from stdin once & parse in a single jq pass ─────────────────────
INPUT=$(cat)

eval "$(printf '%s' "$INPUT" | jq -r '
. as $root |
def bucket_fields(prefix):
  (($root.quota // {}) | to_entries) as $entries |
  (
    ($entries[]? | select(.key == (prefix + "-5h"))) //
    ($entries[]? | select((.key | test(prefix)) and (.key | test("5h|five")))) //
    ($entries[]? | select(.key | test("5h|five"))) //
    null
  ) as $b5 |
  (
    ($entries[]? | select(.key == (prefix + "-weekly"))) //
    ($entries[]? | select((.key | test(prefix)) and (.key | test("week|7d")))) //
    ($entries[]? | select(.key | test("week|7d"))) //
    null
  ) as $bw |
  [
    ("Q_" + prefix + "_5H_FRAC=" + ($b5.value.remaining_fraction // "" | tostring | @sh)),
    ("Q_" + prefix + "_5H_R_SECS=" + ($b5.value.reset_in_seconds // "" | tostring | @sh)),
    ("Q_" + prefix + "_5H_R_TIME=" + ($b5.value.reset_time // "" | tostring | @sh)),
    ("Q_" + prefix + "_WK_FRAC=" + ($bw.value.remaining_fraction // "" | tostring | @sh)),
    ("Q_" + prefix + "_WK_R_SECS=" + ($bw.value.reset_in_seconds // "" | tostring | @sh)),
    ("Q_" + prefix + "_WK_R_TIME=" + ($bw.value.reset_time // "" | tostring | @sh))
  ];

[
  @sh "MODEL_DISPLAY=\($root.model.display_name // "")",
  @sh "MODEL_ID=\($root.model.id // "")",
  @sh "EXEC_MODE=\($root.execution_mode // "")",
  @sh "EFFORT_LEVEL=\($root.effort.level // "")",
  @sh "FAST_MODE=\($root.fast_mode // false)",
  @sh "CWD=\($root.workspace.current_dir // $root.cwd // "")",
  @sh "TERM_COLS=\($root.terminal_width // $root.terminal.width // "")",
  @sh "TRANSCRIPT_PATH=\($root.transcript_path // "")",
  @sh "VCS_BRANCH=\($root.vcs.branch // "")",
  @sh "VCS_DIRTY=\($root.vcs.dirty // false)",
  @sh "CTX_USED_PCT=\($root.context_window.used_percentage // "")",
  @sh "INPUT_TOKENS=\($root.context_window.current_usage.input_tokens // "")",
  @sh "CTX_WINDOW_SIZE=\($root.context_window.context_window_size // "")",
  @sh "EXCEEDS_200K=\($root.exceeds_200k_tokens // false)",
  @sh "SESSION_COST=\($root.cost.total_cost_usd // "")",
  @sh "PLAN_TIER=\($root.plan_tier // "")",
  @sh "EMAIL=\($root.email // "")",
  @sh "TASK_COUNT=\($root.task_count // "")",
  @sh "ARTIFACT_COUNT=\($root.artifact_count // "")",
  @sh "SANDBOX_ENABLED=\($root.sandbox.enabled // false)",
  @sh "VIM_MODE=\($root.vim.mode // "")",
  @sh "PROJECT_DIR=\($root.workspace.project_dir // "")",
  @sh "HAS_AGY_QUOTA=\(if ($root.quota // {}) != {} then "true" else "" end)",
  @sh "RL_5H_PCT=\($root.rate_limits.five_hour.used_percentage // "")",
  @sh "RL_5H_RESETS_AT=\($root.rate_limits.five_hour.resets_at // "")",
  @sh "RL_WK_PCT=\($root.rate_limits.seven_day.used_percentage // "")",
  @sh "RL_WK_RESETS_AT=\($root.rate_limits.seven_day.resets_at // "")"
] + bucket_fields("gemini") + bucket_fields("3p") | .[]
')"

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 1: Model short name and effort
# ════════════════════════════════════════════════════════════════════════════
EFFORT_FROM_MODEL=""
CLEANED_MODEL="$MODEL_DISPLAY"
[[ -z "$CLEANED_MODEL" ]] && CLEANED_MODEL="$MODEL_ID"

# Extract effort if embedded in parens, e.g. "Gemini 3.8 Flash (High)" -> "high"
if [[ "$CLEANED_MODEL" =~ \(([A-Za-z]+)\) ]]; then
  EFFORT_FROM_MODEL=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
  CLEANED_MODEL=$(printf '%s' "$CLEANED_MODEL" | sed -E 's/\s*\([^)]+\)//g')
fi

# Parse short model name
MODEL_SHORT=$(printf '%s' "$CLEANED_MODEL" | awk '{
  raw = tolower($0)
  n = split(raw, a, " ")
  tier = ""; ver = ""; is_gemini = 0; is_claude = 0
  for (i=1; i<=n; i++) {
    if (a[i] ~ /gemini/) is_gemini = 1
    if (a[i] ~ /claude/) is_claude = 1
    if (a[i] ~ /flash|pro|ultra|haiku|sonnet|opus/) tier = a[i]
    if (a[i] ~ /^[0-9]/) ver = a[i]
  }
  if (is_gemini == 1 && tier != "" && ver != "") print "gemini-" ver "-" tier
  else if (is_gemini == 1 && tier != "" && ver != "") print "gemini-" tier
  else if (tier != "" && ver != "") print tier "-" ver
  else if (tier != "" && tier != raw) print tier
  else print raw
}')
[[ -z "$MODEL_SHORT" ]] && MODEL_SHORT="antigravity"

# Context window variant tag (1M)
CTX_VARIANT=""
if printf '%s' "$MODEL_ID $MODEL_DISPLAY" | grep -qi '1m'; then
  CTX_VARIANT="·1m"
fi
MODEL_SHORT="${MODEL_SHORT}${CTX_VARIANT}"

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 1b: Reasoning effort, execution mode, and fast flag
# ════════════════════════════════════════════════════════════════════════════
[[ -z "$EFFORT_LEVEL" ]] && EFFORT_LEVEL="$EFFORT_FROM_MODEL"

FAST_FLAG=""
if [[ "$FAST_MODE" == "true" || "$EXEC_MODE" == "fast" ]]; then
  FAST_FLAG="⚡"
fi

EFFORT_DISPLAY=""
if [[ -n "$EFFORT_LEVEL" ]]; then
  case "$EFFORT_LEVEL" in
    low)    EFFORT_TAG="lo"   ; EFFORT_FG=$FG_GREY   ;;
    medium) EFFORT_TAG="med"  ; EFFORT_FG=$FG_GREEN  ;;
    high)   EFFORT_TAG="high" ; EFFORT_FG=$FG_YELLOW ;;
    xhigh)  EFFORT_TAG="xhi"  ; EFFORT_FG=$FG_MAGENTA;;
    *)      EFFORT_TAG="$EFFORT_LEVEL" ; EFFORT_FG=$FG_CYAN ;;
  esac
  EFFORT_DISPLAY="eff ${EFFORT_FG}${BOLD}${EFFORT_TAG}${RESET}${FAST_FLAG}"
fi

MODE_DISPLAY=""
if [[ -n "$EXEC_MODE" && "$EXEC_MODE" != "normal" && "$EXEC_MODE" != "fast" ]]; then
  case "$EXEC_MODE" in
    planning) MODE_TAG="plan" ;;
    *)        MODE_TAG="$EXEC_MODE" ;;
  esac
  MODE_DISPLAY="mode ${FG_CYAN}${MODE_TAG}${RESET}"
fi

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 2: Working directory (~ collapsed and adaptively shortened)
# ════════════════════════════════════════════════════════════════════════════
[[ -z "$CWD" ]] && CWD=$(pwd 2>/dev/null || echo "?")
CWD_DISPLAY="${CWD/#$HOME/\~}"

[[ -z "$TERM_COLS" || "$TERM_COLS" -lt 20 ]] && TERM_COLS=$(tput cols 2>/dev/null || echo 120)

_shorten_path() {
  local p=$1
  local keep=$2
  local IFS='/'; read -r -a parts <<< "$p"
  local n=${#parts[@]}
  (( n <= keep )) && { printf '%s' "$p"; return; }
  local tail="" i
  for (( i=n-keep; i<n; i++ )); do tail+="/${parts[i]}"; done
  printf '…%s' "$tail"
}

CWD_LEN=${#CWD_DISPLAY}
if   (( TERM_COLS < 80 ))  && (( CWD_LEN > 25 )); then
  CWD_DISPLAY=$(_shorten_path "$CWD_DISPLAY" 1)
elif (( TERM_COLS < 120 )) && (( CWD_LEN > 40 )); then
  CWD_DISPLAY=$(_shorten_path "$CWD_DISPLAY" 2)
elif                            (( CWD_LEN > 80 )); then
  CWD_DISPLAY=$(_shorten_path "$CWD_DISPLAY" 2)
fi

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 3: Git: branch, ahead/behind, staged+unstaged, untracked
# ════════════════════════════════════════════════════════════════════════════
GIT_BRANCH=""
GIT_AHEAD_BEHIND=""
GIT_CHANGES=""

CWD_HASH=$(printf '%s' "$CWD" | tr '/. ' '---')
GIT_CACHE_VAL=$(_cache_get "git_${CWD_HASH}")

if [[ -n "$GIT_CACHE_VAL" ]]; then
  # Parse cached git output: branch \n ahead_behind \n changes
  IFS=$'\n' read -r -d '' GIT_BRANCH GIT_AHEAD_BEHIND GIT_CHANGES <<< "$GIT_CACHE_VAL" || true
elif git -C "$CWD" rev-parse --git-dir &>/dev/null 2>&1; then
  # Single fast git command: status with porcelain -b
  RAW_GIT_STATUS=$(_to 0.3 git -C "$CWD" status --porcelain -b 2>/dev/null || true)
  if [[ -n "$RAW_GIT_STATUS" ]]; then
    PARSED_GIT=$(printf '%s\n' "$RAW_GIT_STATUS" | awk '
      NR == 1 {
        sub(/^## /, "", $0)
        split($0, parts, /\.\.\./)
        branch = parts[1]
        sub(/^[ \t]+|[ \t]+$/, "", branch)
        if ($0 ~ /ahead [0-9]+/) {
          match($0, /ahead [0-9]+/)
          ahead = substr($0, RSTART+6, RLENGTH-6)
        }
        if ($0 ~ /behind [0-9]+/) {
          match($0, /behind [0-9]+/)
          behind = substr($0, RSTART+7, RLENGTH-7)
        }
        next
      }
      $0 !~ /^[ ?]/ { staged++ }
      substr($0, 2, 1) !~ /[ ?]/ { unstaged++ }
      /^\?\?/ { untracked++ }
      END {
        ab = ""
        if (ahead > 0 || behind > 0) ab = " ↑" (ahead+0) "↓" (behind+0)
        ch = ""
        delta = staged + unstaged
        if (delta > 0) ch = "±" delta
        if (untracked > 0) ch = (ch ? ch " " : "") "?" untracked
        printf "%s\n%s\n%s", branch, ab, ch
      }
    ')
    IFS=$'\n' read -r -d '' GIT_BRANCH GIT_AHEAD_BEHIND GIT_CHANGES <<< "$PARSED_GIT" || true
    _cache_set "git_${CWD_HASH}" "$PARSED_GIT"
  else
    # Fallback to Antigravity .vcs object if git status timed out
    GIT_BRANCH="$VCS_BRANCH"
    if [[ "$VCS_DIRTY" == "true" ]]; then
      GIT_CHANGES="±"
    fi
  fi
else
  # Fallback to Antigravity .vcs object if not raw git or git CLI blocked
  GIT_BRANCH="$VCS_BRANCH"
  if [[ "$VCS_DIRTY" == "true" ]]; then
    GIT_CHANGES="±"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 4: Session health from transcript user turns
# ════════════════════════════════════════════════════════════════════════════
MSG_COUNT=0
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
  # Fast counting: supports Antigravity USER_INPUT and Claude role:user
  AGY_COUNT=$(grep -c -E '"type"\s*:\s*"USER_INPUT"|"source"\s*:\s*"USER_EXPLICIT"' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
  if [[ "$AGY_COUNT" =~ ^[0-9]+$ ]] && (( AGY_COUNT > 0 )); then
    MSG_COUNT=$AGY_COUNT
  else
    MSG_COUNT=$(grep -c -E '"role"\s*:\s*"user"' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
  fi
  [[ -z "$MSG_COUNT" || "$MSG_COUNT" == "null" ]] && MSG_COUNT=0
fi

if   (( MSG_COUNT <= 30 )); then HEALTH_EMOJI="🟢"
elif (( MSG_COUNT <= 45 )); then HEALTH_EMOJI="🟡"
else                              HEALTH_EMOJI="🔴"
fi
HEALTH_DISPLAY="${HEALTH_EMOJI} ${MSG_COUNT}/50"

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 5: Beads ready count (bd) - cached
# ════════════════════════════════════════════════════════════════════════════
BD_DISPLAY=""
BD_COUNT=$(_cache_get "bd")
if [[ -z "$BD_COUNT" ]]; then
  if command -v bd >/dev/null 2>&1; then
    BD_COUNT=$(_to 0.5 bash -c 'bd ready --json 2>/dev/null | jq "length" 2>/dev/null' || true)
  fi
  [[ -z "$BD_COUNT" ]] && BD_COUNT=0
  _cache_set "bd" "$BD_COUNT"
fi
if [[ "$BD_COUNT" =~ ^[0-9]+$ ]] && (( BD_COUNT > 0 )); then
  BD_DISPLAY="${FG_CYAN}bd:${BD_COUNT}▸${RESET}"
fi

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 6: Context window used %
# ════════════════════════════════════════════════════════════════════════════
CTX_PCT=0
if [[ -n "$CTX_USED_PCT" ]]; then
  CTX_PCT=$(printf "%.0f" "$CTX_USED_PCT" 2>/dev/null || echo 0)
else
  [[ -z "$CTX_WINDOW_SIZE" || "$CTX_WINDOW_SIZE" == "0" ]] && CTX_WINDOW_SIZE=1048576
  if [[ "$EXCEEDS_200K" == "true" && "$CTX_WINDOW_SIZE" -le 200000 ]]; then
    CTX_PCT=95
  elif [[ -n "$INPUT_TOKENS" && "$INPUT_TOKENS" =~ ^[0-9]+$ && "$INPUT_TOKENS" -gt 0 ]]; then
    CTX_PCT=$(( INPUT_TOKENS * 100 / CTX_WINDOW_SIZE ))
    (( CTX_PCT > 100 )) && CTX_PCT=100
  fi
fi
# Context window bar: green <50, amber 50-80, red >=80
CTX_BAR=$(_bar "$CTX_PCT" 50 80)

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 7: Quota and Rate Limits (5-hour and weekly usage bars)
# ════════════════════════════════════════════════════════════════════════════
FIVE_HR_BAR=""
FIVE_HR_RESET_FMT=""
WEEK_BAR=""
WEEK_RESET_FMT=""

PROVIDER_PREFIX="gemini"
if [[ "$MODEL_SHORT" =~ (claude|sonnet|haiku|opus|gpt|o1|o3|3p) ]]; then
  PROVIDER_PREFIX="3p"
fi

if [[ -n "$HAS_AGY_QUOTA" ]]; then
  if [[ "$PROVIDER_PREFIX" == "3p" ]]; then
    FRAC="${Q_3p_5H_FRAC:-$Q_gemini_5H_FRAC}"
    R_SECS="${Q_3p_5H_R_SECS:-$Q_gemini_5H_R_SECS}"
    R_TIME="${Q_3p_5H_R_TIME:-$Q_gemini_5H_R_TIME}"
  else
    FRAC="${Q_gemini_5H_FRAC:-$Q_3p_5H_FRAC}"
    R_SECS="${Q_gemini_5H_R_SECS:-$Q_3p_5H_R_SECS}"
    R_TIME="${Q_gemini_5H_R_TIME:-$Q_3p_5H_R_TIME}"
  fi
  if [[ -n "$FRAC" ]]; then
    PCT=$(awk -v rf="$FRAC" 'BEGIN { printf "%.0f", (1.0 - rf) * 100 }')
    FIVE_HR_BAR="5h $(_bar "$PCT" 60 85)"
    if [[ -n "$R_SECS" && "$R_SECS" =~ ^[0-9]+$ ]]; then
      NOW=$(date +%s)
      FIVE_HR_RESET_FMT=$(_fmt_epoch "$(( NOW + R_SECS ))" '%H:%M')
    elif [[ -n "$R_TIME" ]]; then
      FIVE_HR_RESET_FMT="$R_TIME"
    fi
  fi

  if [[ "$PROVIDER_PREFIX" == "3p" ]]; then
    FRAC="${Q_3p_WK_FRAC:-$Q_gemini_WK_FRAC}"
    R_SECS="${Q_3p_WK_R_SECS:-$Q_gemini_WK_R_SECS}"
    R_TIME="${Q_3p_WK_R_TIME:-$Q_gemini_WK_R_TIME}"
  else
    FRAC="${Q_gemini_WK_FRAC:-$Q_3p_WK_FRAC}"
    R_SECS="${Q_gemini_WK_R_SECS:-$Q_3p_WK_R_SECS}"
    R_TIME="${Q_gemini_WK_R_TIME:-$Q_3p_WK_R_TIME}"
  fi
  if [[ -n "$FRAC" ]]; then
    PCT=$(awk -v rf="$FRAC" 'BEGIN { printf "%.0f", (1.0 - rf) * 100 }')
    WEEK_BAR="wk $(_bar "$PCT" 70 90)"
    if [[ -n "$R_SECS" && "$R_SECS" =~ ^[0-9]+$ ]]; then
      NOW=$(date +%s)
      WEEK_RESET_FMT=$(_fmt_epoch "$(( NOW + R_SECS ))" '%b %e %H:%M' | tr -s ' ')
    elif [[ -n "$R_TIME" ]]; then
      WEEK_RESET_FMT="$R_TIME"
    fi
  fi
fi

# Fallback: Claude Code style .rate_limits
if [[ -z "$FIVE_HR_BAR" && -z "$WEEK_BAR" ]]; then
  if [[ -n "$RL_5H_PCT" ]]; then
    FIVE_HR_PCT=$(printf "%.0f" "$RL_5H_PCT" 2>/dev/null || echo 0)
    FIVE_HR_RESET_FMT=$(_fmt_epoch "$RL_5H_RESETS_AT" '%H:%M')
    FIVE_HR_BAR="5h $(_bar "$FIVE_HR_PCT" 60 85)"
  fi
  if [[ -n "$RL_WK_PCT" ]]; then
    WEEK_PCT=$(printf "%.0f" "$RL_WK_PCT" 2>/dev/null || echo 0)
    WEEK_RESET_FMT=$(_fmt_epoch "$RL_WK_RESETS_AT" '%b %e %H:%M' | tr -s ' ')
    WEEK_BAR="wk $(_bar "$WEEK_PCT" 70 90)"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 8: Cost, Subscription Tier, and Account
# ════════════════════════════════════════════════════════════════════════════
SESSION_COST="$SESSION_COST"
COST_DISPLAY=""
COST_COLOR="$FG_GREY"

TIER_SHORT=""
if [[ -n "$PLAN_TIER" ]]; then
  TIER_SHORT=$(printf '%s' "$PLAN_TIER" | sed -E 's/^[Gg]oogle[[:space:]]+[Aa][Ii][[:space:]]*//' | tr -d '\r\n')
  TIER_SHORT="${TIER_SHORT#"${TIER_SHORT%%[![:space:]]*}"}"
  TIER_SHORT="${TIER_SHORT%"${TIER_SHORT##*[![:space:]]}"}"
fi

ACCOUNT_NAME=""
if [[ -n "$EMAIL" ]]; then
  ACCOUNT_NAME="${EMAIL%%@*}"
fi

if [[ -n "$SESSION_COST" && "$SESSION_COST" =~ ^[0-9] ]]; then
  COST_DISPLAY=$(printf "\$%.2f" "$SESSION_COST" 2>/dev/null || echo "")
  COST_COLOR="$FG_GREEN"
elif [[ -n "$ACCOUNT_NAME" && -n "$TIER_SHORT" ]]; then
  COST_DISPLAY="${ACCOUNT_NAME} (${TIER_SHORT})"
  COST_COLOR="$FG_GREY"
elif [[ -n "$ACCOUNT_NAME" ]]; then
  COST_DISPLAY="${ACCOUNT_NAME}"
  COST_COLOR="$FG_GREY"
elif [[ -n "$PLAN_TIER" ]]; then
  COST_DISPLAY="${PLAN_TIER}"
  COST_COLOR="$FG_GREY"
fi

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 9: Antigravity-specific Badges (Tasks, Artifacts, Sandbox)
# ════════════════════════════════════════════════════════════════════════════
TASKS_DISPLAY=""
if [[ "$TASK_COUNT" =~ ^[0-9]+$ ]] && (( TASK_COUNT > 0 )); then
  TASKS_DISPLAY="${FG_CYAN}tasks:${TASK_COUNT}${RESET}"
fi

ARTIFACT_DISPLAY=""
if [[ "$ARTIFACT_COUNT" =~ ^[0-9]+$ ]] && (( ARTIFACT_COUNT > 0 )); then
  ARTIFACT_DISPLAY="${FG_BLUE}art:${ARTIFACT_COUNT}${RESET}"
fi

SANDBOX_DISPLAY=""
if [[ "$SANDBOX_ENABLED" == "true" ]]; then
  SANDBOX_DISPLAY="${FG_YELLOW}🔒sb${RESET}"
fi

# ════════════════════════════════════════════════════════════════════════════
# SIGNAL 10: Caveman mode badge + savings
# ════════════════════════════════════════════════════════════════════════════
CAVEMAN_BADGE=""
CAVEMAN_SAVINGS=""
CAVEMAN_MODE=""

_CAVEMAN_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"
[[ ! -f "$_CAVEMAN_FLAG" ]] && _CAVEMAN_FLAG="$HOME/.gemini/antigravity-cli/.caveman-active"
_CAVEMAN_SUFFIX="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-statusline-suffix"
[[ ! -f "$_CAVEMAN_SUFFIX" ]] && _CAVEMAN_SUFFIX="$HOME/.gemini/antigravity-cli/.caveman-statusline-suffix"

if [[ -f "$_CAVEMAN_FLAG" ]] && [[ ! -L "$_CAVEMAN_FLAG" ]]; then
  CAVEMAN_MODE=$(head -c 64 "$_CAVEMAN_FLAG" 2>/dev/null | tr -d '\n\r' | tr -cd 'a-z0-9-')
  case "$CAVEMAN_MODE" in
    off|lite|full|ultra|wenyan-lite|wenyan|wenyan-full|wenyan-ultra|commit|review|compress)
      if [[ "$CAVEMAN_MODE" == "full" ]] || [[ -z "$CAVEMAN_MODE" ]]; then
        CAVEMAN_BADGE="🪨"
      else
        CAVEMAN_BADGE="🪨:$(printf '%s' "$CAVEMAN_MODE" | tr '[:lower:]' '[:upper:]')"
      fi
      ;;
    *) CAVEMAN_MODE="" ;;
  esac
fi
if [[ -n "$CAVEMAN_MODE" ]] && [[ -f "$_CAVEMAN_SUFFIX" ]] && [[ ! -L "$_CAVEMAN_SUFFIX" ]]; then
  CAVEMAN_SAVINGS=$(head -c 64 "$_CAVEMAN_SUFFIX" 2>/dev/null | tr -d '\000-\037')
fi

# ════════════════════════════════════════════════════════════════════════════
# POWERLINE RENDER
# ════════════════════════════════════════════════════════════════════════════
PL_SEP=$'\ue0b0'
PL_SEP_THIN=$'\ue0b1'

_fg() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
_bg() { printf '\033[48;2;%d;%d;%dm' "$1" "$2" "$3"; }

# Dracula-inspired true-color palette
C_WHITE="248;248;242"
C_BLACK="40;42;54"
C_PURPLE="189;147;249"
C_BLUE="98;114;164"
C_CYAN="139;233;253"
C_GREEN="80;250;123"
C_YELLOW="241;250;140"
C_ORANGE="255;184;108"
C_PINK="255;121;198"
C_RED="255;85;85"
C_GREY="68;71;90"
C_CAVE="176;98;38"

_seg() {
  local bg=$1 fg=$2 text=$3 prev_bg=$4
  local out=""
  if [[ -n "$prev_bg" ]]; then
    if [[ "$prev_bg" == "$bg" ]]; then
      out+=$(_bg ${bg//;/ }; _fg ${fg//;/ })" ${PL_SEP_THIN} "
    else
      out+=$(_fg ${prev_bg//;/ }; _bg ${bg//;/ })"$PL_SEP"
    fi
  fi
  out+=$(_bg ${bg//;/ }; _fg ${fg//;/ })" ${text} "
  printf '%s' "$out"
}

_seg_end() {
  local last_bg=$1
  printf '%b' "\033[0m$(_fg ${last_bg//;/ })${PL_SEP}\033[0m"
}

# ── Build Line 1 (Powerline: CWD · Git · Reflect · Beads · Caveman) ──────────
L1=""
prev=""

# CWD segment (blue)
L1+=$(_seg "$C_BLUE" "$C_WHITE" "$CWD_DISPLAY" "$prev")
prev="$C_BLUE"

# Git segment (cyan if clean, orange if dirty)
if [[ -n "$GIT_BRANCH" ]]; then
  git_text="${GIT_BRANCH}${GIT_AHEAD_BEHIND}"
  [[ -n "$GIT_CHANGES" ]] && git_text+=" ${GIT_CHANGES}"
  if [[ -n "$GIT_CHANGES" ]]; then
    L1+=$(_seg "$C_ORANGE" "$C_BLACK" "$git_text" "$prev")
    prev="$C_ORANGE"
  else
    L1+=$(_seg "$C_CYAN" "$C_BLACK" "$git_text" "$prev")
    prev="$C_CYAN"
  fi
fi

# Reflect error badge (red, only when unacked errors exist)
REFLECT_ERR_COUNT=$(_cache_get "reflect_err_count")
if [[ -z "$REFLECT_ERR_COUNT" ]]; then
  REFLECT_ERR_COUNT=$(_reflect_err_count)
  _cache_set "reflect_err_count" "${REFLECT_ERR_COUNT:-0}"
fi
REFLECT_ERR_COUNT=${REFLECT_ERR_COUNT:-0}
if [[ "$REFLECT_ERR_COUNT" =~ ^[0-9]+$ ]] && (( REFLECT_ERR_COUNT > 0 )); then
  L1+=$(_seg "$C_RED" "$C_WHITE" "⚠${REFLECT_ERR_COUNT} /reflect:errors-ack" "$prev")
  prev="$C_RED"
fi

# Beads (pink)
if [[ -n "$BD_DISPLAY" ]]; then
  bd_text="bd:${BD_COUNT}▸"
  L1+=$(_seg "$C_PINK" "$C_BLACK" "$bd_text" "$prev")
  prev="$C_PINK"
fi

# Caveman badge (dark orange)
if [[ -n "$CAVEMAN_BADGE" ]]; then
  cave_text="$CAVEMAN_BADGE"
  [[ -n "$CAVEMAN_SAVINGS" ]] && cave_text+=" ${CAVEMAN_SAVINGS}"
  L1+=$(_seg "$C_CAVE" "$C_WHITE" "$cave_text" "$prev")
  prev="$C_CAVE"
fi

# Vim mode indicator (if active)
if [[ -n "$VIM_MODE" ]]; then
  L1+=$(_seg "$C_GREEN" "$C_BLACK" "$VIM_MODE" "$prev")
  prev="$C_GREEN"
fi

L1+=$(_seg_end "$prev")

# ── Build Line 2 (Detail Line: Model · Mode/Eff · Health · CTX · Quota · Badges) ──
case "$HEALTH_EMOJI" in
  🟡) HEALTH_FG=$FG_YELLOW ;;
  🔴) HEALTH_FG=$FG_RED    ;;
  *)  HEALTH_FG=$FG_GREEN  ;;
esac

L2="${BOLD}${FG_MAGENTA}${MODEL_SHORT}${RESET}"
[[ -n "$MODE_DISPLAY" ]] && L2+=" ${SEP} ${MODE_DISPLAY}"
[[ -n "$EFFORT_DISPLAY" ]] && L2+=" ${SEP} ${EFFORT_DISPLAY}"
L2+=" ${SEP} ${HEALTH_FG}${HEALTH_EMOJI} ${MSG_COUNT}/50${RESET}"
L2+=" ${SEP} ctx ${CTX_BAR}"
[[ -n "$FIVE_HR_BAR" ]] && L2+=" ${SEP} ${FIVE_HR_BAR}"
if [[ -n "$WEEK_BAR" ]]; then
  L2+=" ${SEP} ${WEEK_BAR}"
  [[ -n "$WEEK_RESET_FMT" ]] && L2+=" ${FG_GREY}↻ ${WEEK_RESET_FMT}${RESET}"
elif [[ -n "$FIVE_HR_RESET_FMT" ]]; then
  L2+=" ${FG_GREY}↻ ${FIVE_HR_RESET_FMT}${RESET}"
fi
[[ -n "$COST_DISPLAY" ]] && L2+=" ${SEP} ${COST_COLOR}${COST_DISPLAY}${RESET}"
[[ -n "$TASKS_DISPLAY" ]] && L2+=" ${SEP} ${TASKS_DISPLAY}"
[[ -n "$ARTIFACT_DISPLAY" ]] && L2+=" ${SEP} ${ARTIFACT_DISPLAY}"
[[ -n "$SANDBOX_DISPLAY" ]] && L2+=" ${SEP} ${SANDBOX_DISPLAY}"

# ── Headroom routing badge ──────────────────────────────────────────────────
_HR_PORT="${AINB_HEADROOM_PORT:-8787}"
_HR_URLS="${ANTHROPIC_BASE_URL}${OPENAI_BASE_URL}${GEMINI_BASE_URL}"
if [[ "$_HR_URLS" == *"127.0.0.1:${_HR_PORT}"* || "$_HR_URLS" == *"localhost:${_HR_PORT}"* ]]; then
  if (exec 3<>"/dev/tcp/127.0.0.1/${_HR_PORT}") 2>/dev/null; then
    _hr_bg="$C_GREEN"; _hr_fg="$C_BLACK"
  else
    _hr_bg="$C_GREY";  _hr_fg="$C_WHITE"
  fi
  _hr_capL=$'\ue0b6'; _hr_capR=$'\ue0b4'
  L2+=" \033[38;2;${_hr_bg}m${_hr_capL}\033[48;2;${_hr_bg}m\033[38;2;${_hr_fg}m HR ${RESET}\033[38;2;${_hr_bg}m${_hr_capR}${RESET}"
fi

# ── RTK badge ───────────────────────────────────────────────────────────────
_RTK_DIR="${PROJECT_DIR:-$CWD}"
if grep -qsF 'rtk hook' "${_RTK_DIR}/.claude/settings.json" 2>/dev/null \
   || grep -qsF 'rtk hook' "$HOME/.claude/settings.json" 2>/dev/null \
   || grep -qsF 'rtk hook' "$HOME/.gemini/antigravity-cli/settings.json" 2>/dev/null; then
  _rtk_capL=$'\ue0b6'; _rtk_capR=$'\ue0b4'
  L2+=" \033[38;2;${C_GREEN}m${_rtk_capL}\033[48;2;${C_GREEN}m\033[38;2;${C_BLACK}m RTK ${RESET}\033[38;2;${C_GREEN}m${_rtk_capR}${RESET}"
fi

# ── Output (clean 2 lines) ───────────────────────────────────────────────────
printf '%b\n %b\n' "$L1" "$L2"
exit 0
