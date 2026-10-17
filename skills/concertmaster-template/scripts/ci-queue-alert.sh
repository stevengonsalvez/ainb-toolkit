#!/usr/bin/env bash
# ci-queue-alert.sh: alert when more than N workflow runs have been queued for M minutes.
#
#   scripts/ci-queue-alert.sh              # one sample, update state, alert once per episode
#   scripts/ci-queue-alert.sh --dry-run    # print the decision; no note, no state, no telemetry event
#
# Defaults: N=15 (CM_QUEUE_THRESHOLD, config ci.queue.threshold), M=15 (CM_QUEUE_MINUTES, config
# ci.queue.minutes). A backlog can sit queued for hours with nobody told. Run it on the concertmaster host every 5 minutes (systemd
# timer, references/ci-capacity.md): ONE counted API call per run (12 an hour; the rate-limit check
# before it is free), skipped when the shared budget is under CM_QUEUE_MIN_BUDGET (20).
#
# Where the alert goes: an inbox note $CM_HOME/inbox/ci-queue-alert-<alert|cleared|blind>-<UTC seconds>-<pid>.md (ONE glob, ci-queue-alert-*.md, covers all three kinds, which is what the
# concertmaster tick reads, SKILL.md tick step 4) AND a telemetry event via mc-emit.sh
# (ci.queue.alert / ci.queue.cleared / ci.queue.blind). The monitor reports its own blindness: if no
# sample has succeeded for 30 minutes (budget, network, auth) a "blind" alert fires once.
# State: $CM_HOME/cache/ci-queue.json {since, alerted, low, last_ok, blind_alerted}, written atomically.
# The queue clears only after 2 consecutive samples at or under N (no flapping). Limits: it counts
# queued RUNS, not jobs, and does not look at the age of the oldest run. Exit 0 always except bad usage (2).
# Repo: CM_QUEUE_REPO, else config ci.queue.repo, else github.org/github.main_repo. The alert text ends
# with config ci.queue.hint (what to check or do first); the default is generic.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  "") ;;
  *) cm_warn "ci-queue-alert.sh: unknown arg: $1"; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { cm_warn "ci-queue-alert.sh: missing jq"; exit 0; }
command -v gh >/dev/null 2>&1 || { cm_warn "ci-queue-alert.sh: missing gh"; exit 0; }

REPO="${CM_QUEUE_REPO:-$(cm_cfg .ci.queue.repo)}"
[ -n "$REPO" ] || { [ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] && REPO="$CM_ORG/$CM_REPO"; }
[ -n "$REPO" ] || { cm_warn "ci-queue-alert.sh: set ci.queue.repo or github.org and github.main_repo in config.yaml (or CM_QUEUE_REPO)"; exit 0; }
THR="${CM_QUEUE_THRESHOLD:-$(cm_cfg .ci.queue.threshold 15)}"; MINS="${CM_QUEUE_MINUTES:-$(cm_cfg .ci.queue.minutes 15)}"
MIN_BUDGET="${CM_QUEUE_MIN_BUDGET:-20}"
BLIND_MIN="${CM_QUEUE_BLIND_MINUTES:-30}"
HINT="$(cm_cfg .ci.queue.hint 'Check the runner fleet; adding runner capacity or flipping to GitHub-hosted runners is the concertmaster call.')"
NOW="${CM_NOW:-$(date +%s)}"
STATE="$CM_HOME/cache/ci-queue.json"
mkdir -p "$CM_HOME/cache" "$CM_HOME/inbox" 2>/dev/null
isint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for v in THR MINS MIN_BUDGET BLIND_MIN NOW; do isint "${!v}" || { cm_warn "ci-queue-alert.sh: $v must be a whole number"; exit 2; }; done

# ---- state, normalised: garbage or an empty file reads as a fresh start ----------
num() { local v; v="$(jq -r --arg k "$1" '.[$k] // 0' "$STATE" 2>/dev/null)"; isint "$v" && echo "$v" || echo 0; }
boo() { local v; v="$(jq -r --arg k "$1" '.[$k] // false' "$STATE" 2>/dev/null)"; [ "$v" = true ] && echo true || echo false; }
since="$(num since)"; low="$(num low)"; last_ok="$(num last_ok)"; alerted="$(boo alerted)"; blind_alerted="$(boo blind_alerted)"
[ "$last_ok" -gt 0 ] || last_ok="$NOW"   # first run: the blind clock starts now

ts() { jq -n --argjson t "$NOW" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
note() { # $1 kind, $2 text, $3 meta json
  [ "$DRY" = 1 ] && return
  printf '# ci-queue %s %s\n\n%s\n' "$1" "$(ts)" "$2" > "$CM_HOME/inbox/ci-queue-alert-$1-$(date -u +%Y%m%dT%H%M%SZ)-$$.md" 2>/dev/null
  local meta="${3:-}"; [ -n "$meta" ] || meta="{}"
  if [ -x "$HERE/mc-emit.sh" ]; then "$HERE/mc-emit.sh" "ci.queue.$1" "$2" "$meta" >/dev/null 2>&1 || true; fi
}
save() {
  [ "$DRY" = 1 ] && return
  jq -n --argjson s "$since" --argjson l "$low" --argjson k "$last_ok" --argjson a "$alerted" --argjson b "$blind_alerted" \
    '{since:$s,low:$l,last_ok:$k,alerted:$a,blind_alerted:$b}' > "$STATE.tmp.$$" 2>/dev/null && mv "$STATE.tmp.$$" "$STATE"
}

# ---- one sample ------------------------------------------------------------------
skip_reason=""
left="$(cm_timeout 20 gh api rate_limit --jq .resources.core.remaining 2>/dev/null || true)"
if isint "$left" && [ "$left" -lt "$MIN_BUDGET" ]; then skip_reason="GitHub budget $left < $MIN_BUDGET"; fi
count=""
if [ -z "$skip_reason" ]; then
  count="$(cm_timeout 20 gh api "repos/$REPO/actions/runs?status=queued&per_page=1" --jq .total_count 2>/dev/null || true)"
  isint "$count" || { skip_reason="queue sample failed (network or auth)"; count=""; }
fi

if [ -z "$count" ]; then
  # blind: report our own blindness once per episode
  blind_for=$(( (NOW - last_ok) / 60 ))
  echo "ci-queue: $skip_reason, nothing changed (blind for ${blind_for} min)"
  if [ "$blind_for" -ge "$BLIND_MIN" ] && [ "$blind_alerted" != true ]; then
    msg="BLIND: no successful queue sample for ${blind_for} min ($skip_reason). The CI queue is NOT being watched."
    echo "ci-queue: $msg"; note blind "$msg" "{\"blind_min\":$blind_for}"; blind_alerted=true
  fi
  save; exit 0
fi
last_ok="$NOW"; blind_alerted=false

if [ "$count" -gt "$THR" ]; then
  low=0
  [ "$since" -gt 0 ] || since="$NOW"
  waited=$(( (NOW - since) / 60 ))
  if [ "$waited" -ge "$MINS" ] && [ "$alerted" != true ]; then
    msg="ALERT: $count runs queued (threshold $THR) for $waited min in $REPO. $HINT"
    echo "ci-queue: $msg"; note alert "$msg" "{\"queued\":$count,\"waited_min\":$waited}"; alerted=true
  else
    echo "ci-queue: $count queued, over $THR for $waited min (alert at $MINS)$([ "$alerted" = true ] && echo ', already alerted')"
  fi
else
  low=$((low + 1))
  if [ "$low" -ge 2 ]; then
    if [ "$alerted" = true ]; then msg="CLEARED: queue is $count (threshold $THR)."; echo "ci-queue: $msg"; note cleared "$msg" "{\"queued\":$count}"; else echo "ci-queue: $count queued, at or under $THR"; fi
    since=0; alerted=false; low=2
  else
    echo "ci-queue: $count queued, at or under $THR (1 low sample, clearing needs 2)"
  fi
fi
save
exit 0
