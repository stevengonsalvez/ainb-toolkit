#!/usr/bin/env bash
# fleet-state.sh: the shared fleet state line `cm:state`, one fixed line in the concertmaster's OWN Orca
# worktree comment (no file, no new channel). Why: a lane believed "main frozen" 12 hours after the lift because
# only the merge lane was told; lanes had no state they could read themselves.
#
#   cm:state freeze=<on|off> window=<UTC time> prod=<version> at=<UTC yyyy-mm-ddThh:mm:ssZ>
#
#   scripts/fleet-state.sh write [--freeze on|off] [--window <UTC time>] [--prod <version>] [--push] [--dry-run]
#   scripts/fleet-state.sh read  [--json]
#   scripts/fleet-state.sh check [--worktree <selector>] [--apply] [--json]
#   scripts/fleet-state.sh override <reason...> [--ttl-min 120] [--worktree <selector>]
#   scripts/fleet-state.sh validate "<line>"
#
# write   (the concertmaster only) rewrites the line in its own comment, in the same call as any other comment
#         change, and keeps every other line. Run it in the same step as a freeze flip or a finished deploy, and
#         once every tick. A field not given comes from the ledger (freeze.state, freeze.window, the newest done
#         deployWindows[].tag), else keeps its last value in the comment, else `unknown` (freeze must be given or known).
#         The line goes last, so a leading cm:merge-ready stays first. --push (a freeze flipping to on): one
#         `orca terminal send` to every lane whose name matches fleet_state.push_match (default `-sweeper`, so
#         pr-sweeper is included) and that has a Claude terminal. Freeze-off needs
#         no push: leads read the line. It reads the comment back and exits 1 if the line is not what it wrote.
# read    finds the concertmaster worktree (worktrees.self_name) on EVERY host and prints its state, its age and
#         fresh|stale|missing|invalid|future|ambiguous|host-unread. An unreachable host is listed, never read as "no line".
#         ambiguous = more than one worktree answers to self_name, or more than one cm:state segment (valid or damaged)
#         is in the comment: the newest is never trusted, the gate blocks. With worktrees.self_host (and self_path) set
#         only that host's worktree answers, and the gate blocks (host-unread) while that host cannot be read.
# check   what a lead or sweeper runs each tick before any merge ask or deploy. Exit 0: may go on. Exit 1: must not.
#           fresh, freeze=on                  exit 1 (a fresh freeze is never overridden)
#           fresh, freeze=off                 exit 0
#           stale (at older than 2 ticks of the slowest tick delay: 60 min with the quiet delay of 1800 s, never under
#           30 min; fleet_state.stale_minutes overrides), missing, invalid, ambiguous, host-unread or dated in the future
#                                             exit 1: act as freeze=on and post `cm:blocked cm:state stale`
#           ... with an active `cm:override continue until=<UTC>` in your own comment: the stale rule is lifted and
#           you go on from the last known state (freeze=on there still blocks). It lifts a STALE line only: a missing,
#           malformed or future-dated line has no trustworthy last state and still blocks
#         --apply keeps your own comment in step: adds `cm:blocked cm:state stale` while stale, removes it (and an
#         override) on the next fresh line. The override ends at its `until` or at the first fresh cm:state.
# override  records `cm:override continue until=<now + ttl>` in your own comment (default 2 h) and an audit line with
#         the reason in your lane journal. The concertmaster (on the owner's word) triggers it by typing
#         `cm:override continue <reason>` into the lead's terminal with `orca terminal send`.
# validate  exit 0 when the argument is exactly one well-formed cm:state line.
#
# Env: CM_NOW (clock), CM_STATE_STALE_MIN (minutes), CM_HOST_TIMEOUT, CM_SELF_HOST / CM_SELF_PATH (the pin), CM_FREEZE_PUSH_MATCH. Exit: 0 ok; 1 failed or blocked; 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/fleet-read.sh
. "$HERE/fleet-read.sh"

ORCA="$(cm_orca)"
NOW="${CM_NOW:-$(date -u +%FT%TZ)}"
# Stale limit: 2 ticks of the SLOWEST tick delay (schedule.tick_delays_s, quiet 1800 s = 60 min), never under 30 min.
# A fixed 30 min is one quiet tick, so a healthy line would go stale just before the next refresh.
STALE_MIN="${CM_STATE_STALE_MIN:-$(cm_cfg .fleet_state.stale_minutes)}"
case "$STALE_MIN" in ''|*[!0-9]*)
  STALE_MIN="$(cm_cfg_json .schedule.tick_delays_s '{}' | jq -r '[.[]? | numbers] | (max // 900) | ((. / 60 | ceil) * 2) | if . < 30 then 30 else . end' 2>/dev/null)"
  case "$STALE_MIN" in ''|*[!0-9]*) STALE_MIN=30 ;; esac ;;
esac
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
usage() { sed -n '2,/^set -uo/{/^#/p;}' "$0" >&2; exit 2; }
die() { cm_warn "fleet-state.sh: $*"; exit "${2:-1}"; }
epoch() { jq -nr --arg t "$1" '$t | fromdateiso8601' 2>/dev/null; }
printf '%s' "$NOW" | grep -Eq "$TS_RE" || die "bad CM_NOW: $NOW" 2

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-fstate.XXXXXX")" || die "cannot create a temp dir"
trap 'rm -rf -- "${TMP:?}"' EXIT

# One definition of the line: parse every cm:state segment of a comment into JSON.
# [{valid, raw, freeze, window, prod, at}] ; a segment that starts `cm:state` but does not fit is valid:false.
# shellcheck disable=SC2016  # jq program
# ONE predicate for "this segment is a cm:state line, valid or damaged": it names cm:state ANYWHERE in the segment, any case,
# except the `cm:blocked cm:state stale` blocker a lead posts. `states` counts it and `write` drops it, so a damaged line
# (a prefix, a tab, a case change, a pipe with no spaces) is ambiguous AND healed by the next write.
# The exemption is END-anchored: only the exact blocker segment is exempt, never a segment that merely starts with its text.
STATE_SEG_RE='^(?!\s*cm:blocked\s+cm:state\s+stale\s*$).*cm:state'
STATE_SEG_JQ="${STATE_SEG_RE//\\/\\\\}"   # the same regex as a jq string literal (backslashes doubled): one definition, two uses
# shellcheck disable=SC2016  # jq program
STATE_JQ='include "comment-segs";
  def states: comment_segs | map(select(test("'"$STATE_SEG_JQ"'"; "i")))
    | map( . as $raw | (capture("^cm:state freeze=(?<freeze>on|off) window=(?<window>[^\\s|]+) prod=(?<prod>[^\\s|]+) at=(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$") // null)
           | if . == null then {valid: false, raw: $raw} else . + {valid: true, raw: $raw} end );
  def override: comment_segs | map(select(test("^cm:override continue until=")))
    | map(capture("^cm:override continue until=(?<until>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$")?) | map(select(. != null));'

# ---- own worktree comment (selector active unless --worktree) -----------------------------------
own_comment() { # <selector> -> prints the comment text; dies when unreadable
  local wsel="$1" out
  out="$(cm_timeout "${CM_HOST_TIMEOUT:-30}" "$ORCA" worktree show --worktree "$wsel" --json </dev/null 2>"$TMP/show.err")" \
    || die "orca worktree show $wsel failed: $(head -c 160 "$TMP/show.err")"
  printf '%s' "$out" | jq -er 'if .ok == true and (.result.worktree | type == "object") then (.result.worktree.comment // "" | if type == "string" then . else "" end) else error("not a worktree") end' 2>/dev/null \
    || die "orca worktree show $wsel: not a worktree reply"
}
own_name() { # <selector>
  cm_timeout "${CM_HOST_TIMEOUT:-30}" "$ORCA" worktree show --worktree "$1" --json </dev/null 2>/dev/null | jq -r '.result.worktree.displayName // empty'
}
set_comment() { # <selector> <text>
  cm_timeout "${CM_HOST_TIMEOUT:-30}" "$ORCA" worktree set --worktree "$1" --comment "$2" --json </dev/null >"$TMP/set.out" 2>"$TMP/set.err" \
    || die "orca worktree set $1 failed: $(head -c 160 "$TMP/set.err")"
  jq -e '.ok != false' "$TMP/set.out" >/dev/null 2>&1 || die "orca worktree set $1 was refused: $(head -c 160 "$TMP/set.out")"
}
# drop_segments <comment> <regex> [flags]: remove every segment (line, or piece of a pipe-joined line) matching the regex; other lines kept as they are.
drop_segments() {
  local fl="${3:-}"
  # Nothing matches: return the comment byte for byte (a literal backslash-n or odd spacing in other tools' lines
  # is never rewritten). Only a comment that loses a segment is rebuilt, line by line.
  if ! printf '%s' "$1" | jq -Rse -L "$HERE" --arg re "$2" --arg fl "$fl" 'include "comment-segs"; comment_segs | any(.[]; test($re; $fl))' >/dev/null 2>&1; then
    printf '%s' "$1"; return 0
  fi
  printf '%s' "$1" | jq -Rrs --arg re "$2" --arg fl "$fl" 'gsub("\\\\n"; "\n") | split("\n")
    | map(split(" | ") | map(select((sub("^\\s+"; "") | test($re; $fl)) | not)) | join(" | "))
    | map(select(length > 0)) | join("\n")'
}

# ---- validate ---------------------------------------------------------------------------------
cmd_validate() {
  [ $# -eq 1 ] || usage
  local r
  r="$(printf '%s' "$1" | jq -Rs -L "$HERE" "$STATE_JQ"' states | (length == 1 and .[0].valid)' 2>/dev/null)"
  # exactly one segment, and the whole argument is that segment
  [ "$r" = true ] && [ "$(printf '%s' "$1" | jq -Rs '(gsub("\\\\n"; "\n") | contains("\n") or contains(" | ")) | not')" = true ] || { echo "invalid: $1" >&2; return 1; }
  echo "valid"
}

# ---- write ------------------------------------------------------------------------------------
cmd_write() {
  local freeze="" window="" prod="" push=0 dry=0 wsel="${CM_STATE_WORKTREE:-active}" tname cur prev lf lw lp old new
  while [ $# -gt 0 ]; do
    case "$1" in
      --freeze) [ $# -ge 2 ] || usage; freeze="$2"; shift ;;
      --window) [ $# -ge 2 ] || usage; window="$2"; shift ;;
      --prod) [ $# -ge 2 ] || usage; prod="$2"; shift ;;
      --worktree) [ $# -ge 2 ] || usage; wsel="$2"; shift ;;
      --push) push=1 ;;
      --dry-run) dry=1 ;;
      *) usage ;;
    esac
    shift
  done
  case "$freeze" in ''|on|off) ;; *) die "--freeze must be on or off" 2 ;; esac
  for v in "$window" "$prod"; do
    case "$v" in *[[:space:]\|]*) die "window and prod are single tokens (no space or pipe): '$v'" 2 ;; esac
  done
  # the line lives in the concertmaster's OWN worktree comment (worktrees.self_name): refuse any other target, or lanes
  # would read a stale line there while a bogus one sits in a worker's comment
  tname="$(own_name "$wsel")"
  [ "$(printf '%s' "$tname" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$CM_SELF_WORKTREE" | tr '[:upper:]' '[:lower:]')" ] \
    || die "target worktree '${tname:-unknown}' is not the concertmaster worktree '$CM_SELF_WORKTREE': nothing written"
  cur="$(own_comment "$wsel")" || exit 1
  prev="$(printf '%s' "$cur" | jq -Rs -L "$HERE" "$STATE_JQ"' states | map(select(.valid)) | sort_by(.at) | last // empty')"
  # precedence per field: the flag, then the ledger (the concertmaster's source of truth), then the last value in the
  # comment, then unknown. A bare every-tick `write` therefore publishes a ledger change at once.
  lf="$(jq -r '.freeze // empty' <<<"${prev:-null}" 2>/dev/null)"; lw="$(jq -r '.window // empty' <<<"${prev:-null}" 2>/dev/null)"; lp="$(jq -r '.prod // empty' <<<"${prev:-null}" 2>/dev/null)"
  local led v; led="$(cm_ledger_path)"
  if [ -s "$led" ] && jq -e 'type == "object"' "$led" >/dev/null 2>&1; then
    v="$(jq -r '.freeze.state // empty' "$led")"; case "$v" in on|off) lf="$v" ;; esac
    v="$(jq -r '.freeze.window // empty' "$led" | tr -d ' ')"; [ -z "$v" ] || lw="$v"
    v="$(jq -r '[(.deployWindows // [])[] | select(.state == "done" and (.tag // "") != "")] | last | .tag // empty' "$led")"; [ -z "$v" ] || lp="$v"
  fi
  freeze="${freeze:-$lf}"; window="${window:-${lw:-unknown}}"; prod="${prod:-${lp:-unknown}}"
  case "$freeze" in on|off) ;; *) die "freeze is unknown: pass --freeze on|off" 2 ;; esac
  case "$window" in *[[:space:]\|]*|'') window=unknown ;; esac
  case "$prod" in *[[:space:]\|]*|'') prod=unknown ;; esac
  new="cm:state freeze=$freeze window=$window prod=$prod at=$NOW"
  cmd_validate "$new" >/dev/null || die "built an invalid line: $new"
  old="$(drop_segments "$cur" "$STATE_SEG_RE" i)"
  if [ -n "$old" ]; then new="$old"$'\n'"$new"; fi
  if [ "$dry" -eq 1 ]; then printf '%s\n' "$new"; return 0; fi
  set_comment "$wsel" "$new"
  # read back: the line we wrote must be the newest valid one
  local back; back="$(own_comment "$wsel")" || exit 1
  printf '%s' "$back" | jq -Rs -L "$HERE" --arg at "$NOW" --arg f "$freeze" "$STATE_JQ"' states | any(.[]; .valid and .at == $at and .freeze == $f)' | grep -q true \
    || die "read back after the write: the cm:state line is not in the comment"
  echo "fleet-state: wrote freeze=$freeze window=$window prod=$prod at=$NOW"
  if [ "$push" -eq 1 ] && [ "$freeze" = on ]; then push_freeze "$window"; fi
  return 0
}

# push_freeze <window>: one terminal send to every lane matching fleet_state.push_match on every host (a freeze going ON only).
push_freeze() {
  local msg f h n=0 sent=0 skipped=0 row path name env handles hn pushre
  pushre="${CM_FREEZE_PUSH_MATCH:-$(cm_cfg .fleet_state.push_match "-sweeper")}"
  [ -n "$pushre" ] || pushre="-sweeper"
  msg="[cm-freeze-$(date -u +%H%M)] merge freeze is ON until prod verifies (window $1). No merge ask, no deploy; read cm:state in the concertmaster worktree comment each tick."
  mkdir -p "$TMP/push"; cm_fleet_worktrees "$TMP/push"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    h="$(jq -r '.host' <<<"$row")"; f="$(jq -r '.file' <<<"$row")"
    while IFS="$(printf '\t')" read -r name path; do
      [ -n "$path" ] || continue
      n=$((n + 1))
      if [ "$h" = local ]; then env=(); else env=(--environment "$h"); fi
      handles="$(cm_timeout 30 "$ORCA" terminal list --worktree "path:$path" ${env[@]+"${env[@]}"} --json </dev/null 2>/dev/null | jq -r '[.result.terminals[]? | select((.agentIdentity // "") == "claude") | .handle] | first // empty')"
      if [ -z "$handles" ]; then skipped=$((skipped + 1)); echo "push: $name@$h no Claude terminal, skipped"; continue; fi
      if cm_timeout 60 "$ORCA" terminal send --terminal "$handles" --text "$msg" --enter ${env[@]+"${env[@]}"} --json </dev/null >/dev/null 2>&1; then
        sent=$((sent + 1)); echo "push: $name@$h sent"
      else skipped=$((skipped + 1)); echo "push: $name@$h send failed, skipped"; fi
    done < <(jq -r --arg re "$pushre" '.result.worktrees[] | select(((.displayName // "") | ascii_downcase) | test($re)) | [(.displayName // ""), (.path // "")] | @tsv' "$f")
  done < "$TMP/push/hosts.ndjson"
  hn="$(jq -r '.host' "$TMP/push/unreach.ndjson" 2>/dev/null | paste -sd, -)"
  echo "push: $sent sent, $skipped skipped of $n matching lane(s)${hn:+; unreachable hosts: $hn}"
}

# ---- read -------------------------------------------------------------------------------------
# resolve: fills $TMP/resolved.json = {status, state, ageMin, host, worktree, worktreeCount, validCount, unreachable[], hostsRead[]}
# FAIL CLOSED: the gate must never say GO during a freeze. More than one worktree answering to self_name, or more than one
# cm:state segment (valid or damaged) in the comment, is "ambiguous" and blocks exactly like a missing line: a second copy, a test or a
# relayed line must not be able to outvote the real one, so "newest wins" is never used to pick between them.
resolve() {
  local self selfhost selfpath
  self="$(printf '%s' "$CM_SELF_WORKTREE" | tr '[:upper:]' '[:lower:]')"
  # optional pin (config worktrees.self_host / self_path): only THAT host's worktree answers, and the gate blocks while that host is unread
  selfhost="${CM_SELF_HOST:-$(cm_cfg .worktrees.self_host "")}"; selfpath="${CM_SELF_PATH:-$(cm_cfg .worktrees.self_path "")}"
  # a path without a host would pin nothing: refuse the half pin, the gate blocks (exit 1)
  if [ -n "$selfpath" ] && [ -z "$selfhost" ]; then die "worktrees.self_path needs worktrees.self_host (a path alone pins nothing)"; fi
  mkdir -p "$TMP/res"; cm_fleet_worktrees "$TMP/res"
  : > "$TMP/res/found.ndjson"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    jq -c -L "$HERE" --arg host "$(jq -r '.host' <<<"$row")" --arg self "$self" --arg shost "$selfhost" --arg spath "$selfpath" "$STATE_JQ"'
      .result.worktrees[] | select(((.displayName // (.path // "" | split("/") | last)) | tostring | ascii_downcase) == $self)
      | select($shost == "" or $host == $shost) | select($spath == "" or (.path // "") == $spath)
      | {host: $host, worktree: (.displayName // ""), states: (.comment | states)}' "$(jq -r '.file' <<<"$row")" >> "$TMP/res/found.ndjson"
  done < "$TMP/res/hosts.ndjson"
  jq -n --slurpfile f "$TMP/res/found.ndjson" --slurpfile u "$TMP/res/unreach.ndjson" --slurpfile h "$TMP/res/hosts.ndjson" \
    --arg now "$NOW" --argjson stale "$STALE_MIN" --arg shost "$selfhost" '
    def ep: fromdateiso8601;
    ($f | map(.states[] as $s | {host, worktree, s: $s})) as $all
    | ($all | map(select(.s.valid)) | sort_by(.s.at) | last) as $best
    | ($all | map(select(.s.valid)) | length) as $nvalid
    | ($all | length) as $nseg
    | { hostsRead: ($h | map(.host)), unreachable: ($u | map({host, error})),
        worktreeFound: (($f | length) > 0), worktreeCount: ($f | length), validCount: $nvalid, stateCount: $nseg,
        hostUnread: ($shost != "" and (($h | map(.host) | index($shost)) == null)),
        invalidSeen: (($all | map(select(.s.valid | not)) | length) > 0),
        best: $best }
    | . as $r
    | if $r.hostUnread then . + {status: "host-unread", state: null, ageMin: null, host: null}
      elif $best == null then . + {status: (if $r.invalidSeen then "invalid" else "missing" end), state: null, ageMin: null, host: null}
      else ((($now | ep) - ($best.s.at | ep)) / 60 | floor) as $age
        | . + {state: ($best.s | {freeze, window, prod, at}), host: $best.host, worktree: $best.worktree, ageMin: $age,
               status: (if ($r.worktreeCount > 1 or $r.stateCount > 1) then "ambiguous"
                        elif $age < -5 then "future" elif $age > $stale then "stale" else "fresh" end)} end
    | del(.best)' > "$TMP/resolved.json" || die "could not resolve the concertmaster state"
}

cmd_read() {
  local json=0
  while [ $# -gt 0 ]; do case "$1" in --json) json=1 ;; *) usage ;; esac; shift; done
  resolve
  if [ "$json" -eq 1 ]; then cat "$TMP/resolved.json"; return 0; fi
  jq -r '
    (if .state == null then "fleet-state: \(.status) (\(if .hostUnread then "the pinned concertmaster host was not read" elif .worktreeFound then "no valid cm:state line in the concertmaster comment" else "concertmaster worktree: not found on any host read" end))"
     else "fleet-state: \(.status) freeze=\(.state.freeze) window=\(.state.window) prod=\(.state.prod) at=\(.state.at) age=\(.ageMin)m host=\(.host)\(if .status == "ambiguous" then " (\(.worktreeCount) worktrees named for the concertmaster, \(.stateCount) cm:state lines: the newest is NOT trusted, the gate blocks)" else "" end)" end),
    (.unreachable[] | "unreachable: \(.host) (\(.error))")' "$TMP/resolved.json"
}

# ---- check ------------------------------------------------------------------------------------
cmd_check() {
  local apply=0 json=0 wsel="active" cur status freeze ovu ovstate="none" verdict rc=0 new
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;; --json) json=1 ;;
      --worktree) [ $# -ge 2 ] || usage; wsel="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  resolve
  status="$(jq -r '.status' "$TMP/resolved.json")"; freeze="$(jq -r '.state.freeze // ""' "$TMP/resolved.json")"
  cur="$(own_comment "$wsel")" || exit 1
  ovu="$(printf '%s' "$cur" | jq -Rrs -L "$HERE" "$STATE_JQ"' override | sort_by(.until) | last | .until // empty')"
  if [ -n "$ovu" ]; then
    if [ "$status" = fresh ]; then ovstate="expired-fresh-state"
    elif [ "$(epoch "$ovu")" -gt $(($(epoch "$NOW") + 720 * 60)) ]; then ovstate="invalid-until"   # hand-typed far-future until: the 12 h cap of `override` holds on read too
    elif [ "$(epoch "$ovu")" -gt "$(epoch "$NOW")" ]; then ovstate="active"
    else ovstate="expired-time"; fi
  fi
  case "$status" in
    fresh)
      if [ "$freeze" = on ]; then verdict="BLOCK freeze=on (fresh cm:state)"; rc=1; else verdict="GO freeze=off (fresh cm:state)"; fi ;;
    *)
      if [ "$ovstate" = active ] && [ "$status" = stale ]; then
        if [ "$freeze" = on ]; then verdict="BLOCK last known freeze=on, state $status, override active (a freeze is never overridden)"; rc=1
        else verdict="GO state $status, override active until $ovu (stale rule lifted)"; fi
      else verdict="BLOCK act as freeze=on: cm:state $status; post: cm:blocked cm:state stale"; rc=1; fi ;;
  esac
  if [ "$apply" -eq 1 ]; then
    new="$cur"
    if [ "$status" = fresh ]; then
      new="$(drop_segments "$new" '^cm:blocked cm:state stale')"
      [ -z "$ovu" ] || new="$(drop_segments "$new" '^cm:override continue until=')"
    else
      if ! printf '%s' "$new" | jq -Rs -L "$HERE" 'include "comment-segs"; comment_segs | any(.[]; test("^cm:blocked cm:state stale"))' | grep -q true; then
        new="${new:+$new$'\n'}cm:blocked cm:state stale"
      fi
      case "$ovstate" in expired-time|invalid-until) new="$(drop_segments "$new" '^cm:override continue until=')" ;; esac
    fi
    [ "$new" = "$cur" ] || set_comment "$wsel" "$new"
  fi
  if [ "$json" -eq 1 ]; then
    jq --arg v "$verdict" --arg o "$ovstate" --argjson rc "$rc" '. + {verdict: $v, override: $o, mayProceed: ($rc == 0)}' "$TMP/resolved.json"
  else
    echo "$verdict"
    echo "override: $ovstate${ovu:+ (until $ovu)}"
    if [ "$ovstate" = expired-fresh-state ] && [ "$apply" -ne 1 ]; then echo "note: a fresh line ends the override, but only --apply removes it; run check with --apply every tick"; fi
    jq -r '.unreachable[] | "unreachable: \(.host) (\(.error))"' "$TMP/resolved.json"
  fi
  return "$rc"
}

# ---- override ---------------------------------------------------------------------------------
cmd_override() {
  local ttl=120 wsel="active" reason="" cur until_ts new name jl
  while [ $# -gt 0 ]; do
    case "$1" in
      --ttl-min) [ $# -ge 2 ] || usage; ttl="$2"; shift ;;
      --worktree) [ $# -ge 2 ] || usage; wsel="$2"; shift ;;
      --*) die "unknown option for override: $1 (the reason is plain words)" 2 ;;
      *) reason="${reason:+$reason }$1" ;;
    esac
    shift
  done
  case "$ttl" in ''|*[!0-9]*) die "--ttl-min must be a number" 2 ;; esac
  [ "$ttl" -ge 1 ] && [ "$ttl" -le 720 ] || die "--ttl-min must be 1 to 720 (12 hours): an override is a short-lived toggle" 2
  [ -n "$reason" ] || die "a reason is required: override <reason...>" 2
  until_ts="$(jq -nr --arg n "$NOW" --argjson m "$ttl" '($n | fromdateiso8601) + $m * 60 | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  cur="$(own_comment "$wsel")" || exit 1
  name="$(own_name "$wsel")"   # a second read of the same worktree: its name, for the journal lane
  jl="$("$HERE/lane-journal.sh" name "$name" 2>/dev/null)" || die "no journal lane name for the worktree '$name'"
  # audit first: a reason the journal refuses (secret-shaped) stops the override
  "$HERE/lane-journal.sh" append "$jl" "cm:override continue until=$until_ts reason: $reason" || die "the audit line was refused by the journal: no override recorded"
  new="$(drop_segments "$cur" '^cm:override continue until=')"
  new="${new:+$new$'\n'}cm:override continue until=$until_ts"
  set_comment "$wsel" "$new"
  echo "fleet-state: override recorded until $until_ts (journal lane $jl)"
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  write) cmd_write "$@" ;;
  read) cmd_read "$@" ;;
  check) cmd_check "$@" ;;
  override) cmd_override "$@" ;;
  validate) cmd_validate "$@" ;;
  -h|--help) usage ;;
  *) cm_warn "fleet-state.sh: unknown command: $sub"; usage ;;
esac
