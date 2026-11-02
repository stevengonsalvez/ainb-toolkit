#!/usr/bin/env bash
# asks.sh: every open blocker and ask in every lane's Orca worktree comment, on every host.
#
#   scripts/asks.sh                 # table: HOST WORKTREE TAG TEXT AGE, then unreachable hosts and a count
#   scripts/asks.sh --json          # the same as one JSON document
#   scripts/asks.sh --peek          # read only: do not update $CM_HOME/asks-seen.json
#
# Tags found: cm:ask, cm:blocked, cm:waiting-owner. Why EVERY line is read: a scan that read only
# lines STARTING with cm:ask missed cm:blocked, which lanes report
# often on line 2 of a multi-line comment or after a " | " on line 1, so blockers sat unseen
# for hours. So: EVERY comment line is read, a literal \n counts as a newline, and every line is
# also split on " | ". A tag must start its segment (a tag quoted mid-sentence is not a blocker).
#
# Hosts: `orca host list --json`, then per host `orca worktree list --json --repo name:<orca_repo>
# --limit 500` (with `--environment <host>` unless the host kind is local), each call bounded by
# CM_HOST_TIMEOUT (default 30s). A host that errors, times out or answers something that is not a
# worktree list is SKIPPED and listed, never read as "no blockers". The worktrees in
# worktrees.never_touch are not read.
#
# Age: $CM_HOME/asks-seen.json remembers each item (host, worktree, tag, text) with the time it was
# first seen and how many consecutive runs saw it. runs >= 2 is "older than 1 tick" (AGE shows
# "older-than-1-tick <minutes>m"); a first sighting is "new". An item that disappears is forgotten,
# except on an unreachable or truncated host, whose unseen items are kept as they were (absence there proves nothing); when the
# host list itself fails, the items of every host not read this run are kept the same way.
# Run it once per tick: two runs in one tick would age everything early.
#
# Exit: 0 when it ran (unreachable hosts are listed, not an error), 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/fleet-read.sh
. "$HERE/fleet-read.sh"

JSON=0; PEEK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --peek) PEEK=1 ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "asks.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

NEVER="${CM_NEVER_TOUCH:-$(cm_cfg .worktrees.never_touch)}"
SEEN="${CM_ASKS_SEEN:-$CM_HOME/asks-seen.json}"
NOW="$(date -u +%FT%TZ)"
NOWS="$(date -u +%s)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-asks.XXXXXX")" || { cm_warn "asks.sh: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
: > "$TMP/items.ndjson"
: > "$TMP/unreach.ndjson"
: > "$TMP/hosts.ndjson"

# Hosts: the shared reader (scripts/fleet-read.sh) writes hosts.ndjson, unreach.ndjson and one worktree list per host
# into $TMP/fleet. A failed host list still reads the local host, and says so (HLFAIL).
mkdir -p "$TMP/fleet"
cm_fleet_worktrees "$TMP/fleet"
cp -- "$TMP/fleet/hosts.ndjson" "$TMP/hosts.ndjson"; cp -- "$TMP/fleet/unreach.ndjson" "$TMP/unreach.ndjson"
HLFAIL=0
if jq -e 'select(.host == "host list")' "$TMP/unreach.ndjson" >/dev/null 2>&1; then HLFAIL=1; fi

# never_touch names, one per line, lowercase.
# shellcheck disable=SC2086  # NEVER is a space-joined list on purpose
printf '%s\n' $NEVER | tr '[:upper:]' '[:lower:]' | grep . | jq -R . | jq -sc . > "$TMP/never.json" 2>/dev/null || printf '[]\n' > "$TMP/never.json"

i=0
while IFS="$(printf '\t')" read -r hname wl; do
  i=$((i + 1))
  [ -n "$wl" ] || continue
  # Every comment line, split on " | ", a tag must start its segment. A comment that is not a string
  # (null, number, object, array) is read as empty, never as a crash.
  # shellcheck disable=SC2016  # jq program
  jq -c -L "$HERE" --arg host "$hname" --slurpfile never "$TMP/never.json" '
    include "comment-segs";
    def clean: tostring | gsub("[[:cntrl:]]+"; " ");
    .result.worktrees[]
    | . as $w
    | ($w.displayName // (($w.path // "") | split("/") | last) // "") as $n
    | select((($n | tostring | ascii_downcase) as $l | any($never[0][]; . == $l)) | not)
    | ($w.comment | comment_segs[])
    | capture("^cm:(?<tag>ask|blocked|waiting-owner)(?::|\\s+|$)\\s*(?<text>.*)$")
    | {host: $host, worktree: ($n | clean), path: ($w.path // null), tag: ("cm:" + .tag),
       text: ((.text | clean | sub("^\\s+"; "") | sub("\\s+$"; "")) | if . == "" then "(no text)" else .[0:300] end)}
  ' "$wl" >> "$TMP/items.ndjson" 2>"$TMP/jq-$i.err" || {
    jq -cn --arg h "$hname" --arg e "comments unreadable: $(head -c 120 "$TMP/jq-$i.err")" '{where:$h, host:$h, error:$e}' >> "$TMP/unreach.ndjson"
  }
done < <(jq -r '[.host, .file] | @tsv' "$TMP/hosts.ndjson")

# Age. The key is host, worktree, worktree path, tag and text (two worktrees that share a name stay two blockers); the previous file may be missing or damaged.
PREV="$TMP/prev.json"
if [ -s "$SEEN" ] && jq -e 'type == "object"' "$SEEN" >/dev/null 2>&1; then cp -- "$SEEN" "$PREV"; else printf '{}\n' > "$PREV"; fi
# unreachable hosts: their old items are kept. When the host LIST itself failed, every host that was
# not read this run is unknown, so all of their old items are kept too (absence proves nothing).
jq -r '.host // empty' "$TMP/unreach.ndjson" | sort -u | jq -R . | jq -sc . > "$TMP/unhosts.json"
jq -r '.host // empty' "$TMP/hosts.ndjson" | sort -u | jq -R . | jq -sc . > "$TMP/readhosts.json"

# shellcheck disable=SC2016  # jq program
jq -n --slurpfile items "$TMP/items.ndjson" --slurpfile prev "$PREV" --slurpfile unh "$TMP/unhosts.json" --slurpfile rh "$TMP/readhosts.json" \
  --arg now "$NOW" --argjson nows "$NOWS" --argjson hlfail "$HLFAIL" --argjson peek "$PEEK" '
  def key: [.host, .worktree, (.path // ""), .tag, .text] | join("\u0001");
  ($prev[0]) as $p
  | ($items | map(. + {key: key}) | unique_by(.key)) as $cur
  | ($cur | map(
      . as $i | ($p[$i.key] // null) as $o
      | $i + {firstSeen: ($o.firstSeen // $now),
         runs: (if $peek == 1 then ([($o.runs // 0), 1] | max) else (($o.runs // 0) + 1) end)}
      | . + {olderThanOneTick: (.runs >= 2),
             ageMinutes: ((($nows - ((.firstSeen | fromdateiso8601? ) // $nows)) / 60) | floor)})) as $rows
  | ($p | to_entries | map(select((.value.host // "") as $h
      | ((($unh[0] | index($h)) != null) or ($hlfail == 1 and (($rh[0] | index($h)) == null)))))
      | map(select(.key as $k | ($cur | map(.key) | index($k)) == null))) as $kept
  | { rows: $rows,
      seen: (([$rows[] | {key: .key, value: {host, worktree, tag, firstSeen, lastSeen: $now, runs}}] + ($kept | map({key, value}))) | from_entries) }
' > "$TMP/result.json" || { cm_warn "asks.sh: could not build the result"; exit 1; }

if [ "$PEEK" -eq 0 ]; then
  mkdir -p -- "$(dirname "$SEEN")" 2>/dev/null || true
  if jq '.seen' "$TMP/result.json" > "$SEEN.tmp.$$" 2>/dev/null; then
    mv -f -- "$SEEN.tmp.$$" "$SEEN" || cm_warn "asks.sh: could not write $SEEN (ages not saved)"
  else
    rm -f -- "$SEEN.tmp.$$"; cm_warn "asks.sh: could not write $SEEN (ages not saved)"
  fi
fi

if [ "$JSON" -eq 1 ]; then
  jq -n --slurpfile r "$TMP/result.json" --slurpfile u "$TMP/unreach.ndjson" --slurpfile h "$TMP/hosts.ndjson" --arg now "$NOW" '
    $r[0].rows as $rows
    | { generatedAt: $now,
        hostsRead: ($h | map(.host)),
        unreachable: ($u | map({host: (.host // .where), error})),
        count: ($rows | length),
        olderThanOneTick: ($rows | map(select(.olderThanOneTick)) | length),
        asks: ($rows | map({host, worktree, path, tag, text, firstSeen, runs, olderThanOneTick, ageMinutes})) }'
  exit 0
fi

printf 'HOST\tWORKTREE\tTAG\tTEXT\tAGE\n'
jq -r '.rows[] | [.host, .worktree, .tag, .text, (if .olderThanOneTick then "older-than-1-tick \(.ageMinutes)m" else "new" end)] | @tsv' "$TMP/result.json"
jq -r '"asks: \(.rows | length) open, \([.rows[] | select(.olderThanOneTick)] | length) older than 1 tick"' "$TMP/result.json"
jq -r '"unreachable: \(.host // .where) (\(.error))"' "$TMP/unreach.ndjson"
exit 0
