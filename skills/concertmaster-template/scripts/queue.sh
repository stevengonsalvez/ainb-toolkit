#!/usr/bin/env bash
# queue.sh: the concertmaster work queue in the ledger (.queue). New work waits
# here for a free slot instead of spawning past capacity (references/queue.md).
#
#   scripts/queue.sh list  [--json]
#   scripts/queue.sh add   <issue> <lane> [--priority P0|urgent|normal] [--host <name>]
#   scripts/queue.sh grant (--discover <file> | --live <host>=<n>[,<host>=<n>...]) [--dry-run]
#   scripts/queue.sh mark  <id> done|dropped|queued   # queued: a failed hand-off
#   scripts/queue.sh depth                 # one line: depth and the next 3 items
#
# Order: P0 (security or prod) first, then urgent, then the oldest addedAt.
# add prints "queued, position N" (an item already queued for the same issue and
# lane is not added twice). grant counts live agent sessions per host (agent
# panes in a live terminal under config worktrees.path_match, from a discover.sh
# document, or given with --live), then grants the top item whose host has a
# free slot while the total is under the cap, and repeats until a cap is hit.
# An item with no host goes to the reachable `general` host with the most free
# slots. Each grant prints one line; the concertmaster hands those items to
# their lanes in the same tick.
# Caps: total = config queue.cap, else ledger .queue.cap; per host = config
# hosts.per_host.<h>.maxWorkers, else ledger hosts.<h>.maxWorkers, else config
# hosts.defaults.maxWorkers. No total cap anywhere: nothing is granted (exit 2).
# Items granted within queue.grant_hold_minutes (default 30) count as live on
# their host (shown "+n"), so a slow spawn is never granted twice; a hand-off
# that failed goes back with `mark <id> queued` (keeps its addedAt).
# A host that is unreachable or truncated in the discover document counts as
# full (its live count is unknown, shown "?"). A configured host missing from
# the census (not attached, not in --live) counts 0 and gets no grant ("-").
# Writes: under <ledger>.lock (a mkdir, stolen after 2 minutes), to a temp file
# that must hold exactly ONE JSON object (cm_ledger_write), then mv. A
# filter that emits several documents, or an empty one, leaves the ledger untouched.
# Needs the guarded ledger writer (cm_ledger_write, cm_ledger_lock, cm_ledger_unlock in
# lib.sh, references/ledger.md) for add, mark and a real grant; without it they refuse with a
# message and exit 1. list, depth and grant --dry-run need none of it.
# Env: CM_HOME (ledger dir), CM_LEDGER (ledger path), CM_NOW (ISO-8601 UTC, for
# tests). Exit: 0 done, 1 ledger unreadable or write refused, 2 bad usage or no cap.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

LEDGER="${CM_LEDGER:-$CM_HOME/ledger.json}"
NOW_ISO="${CM_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
POLICY="P0, then urgent, then oldest addedAt"

die() { cm_warn "queue: $1"; exit "${2:-1}"; }
usage() { sed -n "2,36p" "$0"; }

# write_ledger <jq filter> [jq args...]: one guarded, atomic rewrite (cm_ledger_write in lib.sh:
# one object with a workers key, not under half the old size, old file backed up). Refuses, and
# leaves the ledger untouched, otherwise.
# shellcheck disable=SC2034  # read by cm_ledger_path in lib.sh
CM_LEDGER="$LEDGER"
# need_writer: refuse clearly when this lib.sh has no guarded ledger writer (reads still work).
need_writer() {
  if ! { declare -F cm_ledger_write && declare -F cm_ledger_lock && declare -F cm_ledger_unlock; } >/dev/null 2>&1; then
    die "writing the queue needs cm_ledger_write, cm_ledger_lock and cm_ledger_unlock from scripts/lib.sh (the guarded ledger writer, references/ledger.md); this lib.sh does not define them: nothing written"
  fi
}
write_ledger() { need_writer; cm_ledger_write "$@"; }

# lock_ledger: hold <ledger>.lock until exit (cm_ledger_lock in lib.sh: an owner-token mkdir lock,
# stolen after 2 minutes). cm_ledger_write inside it re-enters the lock; an exit never removes a
# lock another process holds.
lock_ledger() {
  need_writer
  cm_ledger_lock || exit 1
  trap cm_ledger_unlock EXIT
}

# Shared jq: the queue order and the queued items in it.
# shellcheck disable=SC2016  # jq program, not shell
DEFS='def prank: {"P0": 0, "urgent": 1}[.priority // "normal"] // 2;
      def queued: [(.queue.items // [])[] | select(.state == "queued")] | sort_by(prank, (.addedAt // ""), (.id // ""));'

need_ledger() {
  [ -r "$LEDGER" ] || die "no ledger at $LEDGER"
  jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1 || die "ledger $LEDGER is not one JSON object"
}

cmd_list() {
  need_ledger
  if [ "${1:-}" = --json ]; then
    jq -c "$DEFS"' queued | to_entries | map(.value + {position: (.key + 1)})' "$LEDGER"
    return
  fi
  jq -r "$DEFS"' queued | to_entries
    | (["pos", "id", "issue", "lane", "priority", "host", "addedAt"] | @tsv),
      (.[] | [(.key + 1), .value.id, "#\(.value.issue)", .value.lane, (.value.priority // "normal"),
              (.value.host // "-"), (.value.addedAt // "-")] | map(tostring) | @tsv)' "$LEDGER" | {
    if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
  }
}

cmd_depth() {
  need_ledger
  jq -r "$DEFS"' queued as $q
    | "queue: depth=\($q | length)" + (if ($q | length) == 0 then "" else
        " next: " + ($q[0:3] | map("#\(.issue) \(.lane) \(.priority // "normal")") | join(", ")) end)' "$LEDGER"
}

cmd_add() {
  local issue="" lane="" prio=normal host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --priority) [ $# -ge 2 ] || die "--priority needs a value" 2; prio="$2"; shift ;;
      --host) [ $# -ge 2 ] || die "--host needs a value" 2; host="$2"; shift ;;
      -*) die "unknown option: $1" 2 ;;
      *) if [ -z "$issue" ]; then issue="${1#\#}"; elif [ -z "$lane" ]; then lane="$1"; else die "extra argument: $1" 2; fi ;;
    esac
    shift
  done
  case "$issue" in ''|*[!0-9]*) die "issue must be a number, got '$issue'" 2 ;; esac
  printf '%s' "$lane" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9:._-]*$' || die "lane must be a lane name, got '$lane'" 2
  case "$prio" in P0|urgent|normal) ;; *) die "priority must be P0, urgent or normal, got '$prio'" 2 ;; esac
  [ -z "$host" ] || printf '%s' "$host" | grep -Eq '^[A-Za-z0-9._-]+$' || die "bad host name '$host'" 2
  need_ledger
  lock_ledger
  local pos
  pos="$(jq -r --argjson issue "$issue" --arg lane "$lane" "$DEFS"' queued
          | [to_entries[] | select(.value.issue == $issue and .value.lane == $lane) | .key + 1] | first // empty' "$LEDGER")"
  if [ -n "$pos" ]; then
    printf 'already queued, position %s: #%s %s\n' "$pos" "$issue" "$lane"; return 0
  fi
  local cap
  cap="$(cm_cfg .queue.cap)"
  # shellcheck disable=SC2016  # jq program, not shell
  write_ledger '
    .queue = ((.queue // {}) | .items = (.items // []) | .policy = $policy
              | if $cap != "" then .cap = ($cap | tonumber) else .cap = (.cap // null) end)
    | ([.queue.items[].id // "" | ltrimstr("q-") | tonumber? ] | max // 0) as $max
    | .queue.items += [{id: "q-\($max + 1)", issue: $issue, lane: $lane, priority: $prio,
                        addedAt: $now, state: "queued", grantedAt: null,
                        host: (if $host == "" then null else $host end)}]
    | .updatedAt = $now' \
    --argjson issue "$issue" --arg lane "$lane" --arg prio "$prio" --arg host "$host" \
    --arg now "$NOW_ISO" --arg cap "$cap" --arg policy "$POLICY" || exit 1
  pos="$(jq -r --argjson issue "$issue" --arg lane "$lane" "$DEFS"' queued
          | [to_entries[] | select(.value.issue == $issue and .value.lane == $lane) | .key + 1] | first' "$LEDGER")"
  printf 'queued, position %s: #%s %s %s\n' "$pos" "$issue" "$lane" "$prio"
}

cmd_mark() {
  local id="${1:-}" st="${2:-}"
  [ -n "$id" ] || die "mark needs an item id" 2
  case "$st" in done|dropped|queued) ;; *) die "mark state must be done, dropped or queued" 2 ;; esac
  need_ledger
  jq -e --arg id "$id" '[(.queue.items // [])[] | select(.id == $id)] | length == 1' "$LEDGER" >/dev/null \
    || die "no queue item $id" 2
  lock_ledger
  # shellcheck disable=SC2016  # jq program, not shell
  write_ledger '.queue.items |= map(if .id != $id then .
      elif $st == "queued" then .state = "queued" | .grantedAt = null
      else .state = $st | .closedAt = $now end) | .updatedAt = $now' \
    --arg id "$id" --arg st "$st" --arg now "$NOW_ISO" || exit 1
  printf 'marked %s %s\n' "$id" "$st"
}

cmd_grant() {
  local disc="" live="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --discover) [ $# -ge 2 ] || die "--discover needs a file" 2; disc="$2"; shift ;;
      --live) [ $# -ge 2 ] || die "--live needs host=n pairs" 2; live="$2"; shift ;;
      --dry-run) dry=1 ;;
      *) die "unknown option: $1" 2 ;;
    esac
    shift
  done
  [ -n "$disc" ] || [ -n "$live" ] || die "grant needs --discover <file> or --live <host>=<n>,..." 2
  need_ledger

  # counts: {host: {live, known}}. known=false means count it as full.
  local counts
  if [ -n "$disc" ]; then
    [ -n "$CM_PATH_MATCH" ] || die "config worktrees.path_match is empty: cannot tell project sessions apart" 2
    counts="$(jq -c --arg re "$CM_PATH_MATCH" '
      (reduce (.hosts // [])[] as $h ({}; .[$h.name] = {live: 0, known: ($h.reachable == true and $h.truncated != true)})) as $base
      | reduce ((.worktrees // [])[] | select((.path // "") | test($re))
                | select((.liveTerminalCount // 0) > 0 and (.isArchived // false) != true)) as $w
          ($base; .[$w.host].live += ([($w.agents // []) | to_entries[] | .value.paneKey // "i\(.key)"] | unique | length)
                  | if .[$w.host].known == null then .[$w.host].known = true else . end)' "$disc")" || die "cannot read discover document $disc" 2
  else
    printf '%s' "$live" | grep -Eq '^[A-Za-z0-9._-]+=[0-9]+(,[A-Za-z0-9._-]+=[0-9]+)*$' \
      || die "--live wants host=n[,host=n...], got '$live'" 2
    counts="$(printf '%s' "$live" | tr ',' '\n' | jq -R -s -c '
      split("\n") | map(select(length > 0) | split("=") | {key: .[0], value: {live: (.[1] | tonumber), known: true}}) | from_entries')"
  fi

  local cfg_hosts cfg_cap hold
  cfg_hosts="$(cm_cfg_json .hosts '{}')"
  cfg_cap="$(cm_cfg .queue.cap)"
  hold="$(cm_cfg .queue.grant_hold_minutes 30)"
  case "$hold" in ''|*[!0-9]*) die "queue.grant_hold_minutes must be a whole number, got '$hold'" 2 ;; esac
  # Plan and write under one lock, so two grants never both fill the last slot.
  [ "$dry" = 1 ] || lock_ledger

  # One pure jq pass: {cap, totalBefore, grants, hosts}; the write applies grants by id.
  local plan
  # shellcheck disable=SC2016  # jq program, not shell
  plan="$(jq -c --argjson counts "$counts" --argjson ch "$cfg_hosts" --arg cfgCap "$cfg_cap" \
      --arg now "$NOW_ISO" --argjson hold "$hold" "$DEFS"'
    . as $L
    | ($now | fromdateiso8601) as $nowS
    # Granted within the hold but maybe not live yet: count them, or a slow spawn is granted twice.
    | (reduce ((.queue.items // [])[] | select(.state == "granted" and .host != null)
               | select(((.grantedAt // "") | try fromdateiso8601 catch null) as $t
                        | $t != null and $nowS - $t < $hold * 60)) as $g
        ({}; .[$g.host] += 1)) as $pending
    | (if $cfgCap != "" then ($cfgCap | tonumber) else ($L.queue.cap // null) end) as $cap
    | ((($ch.per_host // {}) | keys) + (($L.hosts // {}) | keys) + ($counts | keys) | unique) as $names
    | (reduce $names[] as $h ({};
        .[$h] = {
          max: ($ch.per_host[$h].maxWorkers // $L.hosts[$h].maxWorkers // $ch.defaults.maxWorkers // 0),
          role: ($ch.per_host[$h].role // $L.hosts[$h].role // $ch.defaults.role // "general"),
          live: ($counts[$h].live // 0),
          seen: ($counts | has($h)),
          known: ($counts[$h].known // false),
          pending: ($pending[$h] // 0)
        }
        | .[$h].used = (if .[$h].seen | not then 0 elif .[$h].known then .[$h].live + .[$h].pending else .[$h].max end))) as $hosts0
    | if $cap == null then {error: "no queue cap (config queue.cap or ledger .queue.cap)"}
      else
        (reduce (queued[]) as $it ({hosts: $hosts0, grants: []};
          (([.hosts[] | .used] | add) // 0) as $total
          | if $total >= $cap then .
            else
              (if $it.host != null then $it.host
               else ([.hosts | to_entries[] | select(.value.known and .value.role == "general" and .value.used < .value.max)]
                     | sort_by(-(.value.max - .value.used), .key) | first | .key // null) end) as $h
              | if $h != null and .hosts[$h] != null and .hosts[$h].known and .hosts[$h].used < .hosts[$h].max
                then .hosts[$h].used += 1 | .grants += [$it + {host: $h}]
                else . end
            end)) as $r
        | {cap: $cap,
           totalBefore: (([$hosts0[] | .used] | add) // 0),
           grants: $r.grants,
           hosts: ($hosts0 | map_values({live, pending, max, seen, known})),
           unmatched: {config: [($ch.per_host // {}) | keys[] | . as $k | select($counts | has($k) | not)],
                       census: [$counts | keys[] | . as $k | select($ch.per_host // {} | has($k) | not)]}}
      end' "$LEDGER")" || die "grant plan failed" 1

  if jq -e 'has("error")' <<<"$plan" >/dev/null; then
    die "$(jq -r .error <<<"$plan"): nothing granted" 2
  fi
  local n
  n="$(jq '.grants | length' <<<"$plan")"
  jq -r '"live=\(.totalBefore)/\(.cap) hosts: " + (.hosts | to_entries
          | map("\(.key) " + (if .value.seen | not then "-" elif .value.known then "\(.value.live)" else "?" end)
              + (if .value.pending > 0 then "+\(.value.pending)" else "" end) + "/\(.value.max)") | join(", "))' <<<"$plan"
  # A config host the census never names, while the census names a host the config does not:
  # likely the same machine under another name, so its maxWorkers is not applied.
  jq -r '.unmatched | select((.config | length) > 0 and (.census | length) > 0)
    | "queue: config hosts \(.config | join(",")) not in the census, census hosts \(.census | join(",")) not in config: check hosts.per_host names"' \
    <<<"$plan" >&2
  if [ "$n" -gt 0 ] && [ "$dry" = 0 ]; then
    # shellcheck disable=SC2016  # jq program, not shell
    write_ledger '.queue.cap = $p.cap
      | reduce $p.grants[] as $g (.; .queue.items |= map(if .id == $g.id
          then .state = "granted" | .grantedAt = $now | .host = $g.host else . end))
      | .updatedAt = $now' --argjson p "$plan" --arg now "$NOW_ISO" || exit 1
  fi
  jq -r --arg tag "$([ "$dry" = 1 ] && echo 'would grant' || echo granted)" \
    '.grants[] | "\($tag) \(.id) #\(.issue) \(.lane) \(.priority // "normal") -> \(.host)"' <<<"$plan"
  [ "$n" -gt 0 ] || echo "granted nothing"
}

# Sourced (tests): define the functions only.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  add) shift; cmd_add "$@" ;;
  grant) shift; cmd_grant "$@" ;;
  mark) shift; cmd_mark "$@" ;;
  depth) shift; cmd_depth ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
