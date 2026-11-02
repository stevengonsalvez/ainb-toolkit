#!/usr/bin/env bash
# lessons-recon.sh: the daily recon of the self-improvement loop. Read-only: it never writes the ledger,
# a journal, a comment or a skill file. Its one write is the stamp $CM_HOME/lessons-last-run, and only on success.
#
#   scripts/lessons-recon.sh [--since <UTC stamp>] [--json]   # report: clusters, counts, unreachable hosts
#   scripts/lessons-recon.sh --dry-run                        # the same report, change nothing (no stamp)
#   scripts/lessons-recon.sh --due                            # exit 0 when 24 h passed since the stamp (or none), else 1
#
# What it reads (every host: `orca host list`, each call bounded by CM_HOST_TIMEOUT, 30 s):
#   comments   `cm:lesson <lane> | <what happened and the fix> | root cause: <gap>` lines in every worktree
#              comment (cut on newline and " | ", scripts/lesson-parse.jq). An unreachable host is LISTED and
#              retried next run; comments carry no timestamp, so they are never skipped by the stamp.
#   journals   the same lines in the lane journals (scripts/lane-journal.sh tail), entries since the window start;
#              `respawn cause: <text>` lines are the same-cause respawn signal.
#   ledger     optional `workers.<id>.notes` (lesson lines) and `nudges` >= 2 (repeated-nudge signal).
#   asks       asks-seen.json: a cm:blocked item seen on lessons.blocker_min_runs [8] or more runs, about two hours
#              at the busy tick (a blocker open over ONE tick is normal operation, not a lesson).
# Window start: --since, else the EARLIER of the stamp and now minus lessons.carry_days (7), so a single weak
# lesson waits for its second instead of ageing out the day after the stamp moved. Ids already in
# the lessons log (merged) or the blocklist are dropped. Both are PROJECT-OWNED files, because a toolkit sync overwrites
# references/: config `lessons.log_file` (default local/lessons-log.md) and `lessons.rejected_file` (default
# local/lessons-rejected.md), relative to the skill directory. A missing file is an empty list. The seeds that
# ship in references/lessons-log.md and references/lessons-rejected.md describe the format; copy them to start.
#
# Rules (config lessons.*, defaults in brackets):
#   per_lane_per_day [3]  lessons counted per lane per UTC day; the rest are reported as capped
#   min_lessons [2]       a gap enters the PR with 2+ lessons (signals count toward the 2 but never qualify a gap
#                         without at least one real lesson), or with ONE lesson that names a root cause
#                         AND carries `[failure]` (the "root-cause failure": the lead says the miss was a failure, not
#                         a one-off). An unmarked single lesson waits for a second.
#   max_changes [5]       the PR size cap; qualifying gaps beyond it are deferred to the next run
#   risk_paths            gaps that touch these force an owner ping: SKILL.md "hard rules", SKILL.md "merge gate",
#                         scripts/teardown.sh (`file` or `file#section words`)
# Tag: `[project-only]` or `[generic]` on the line wins; otherwise a gap in references/project-local.md or config.yaml,
# or text naming a PR or issue (#123) or the project path (worktrees.path_match), is project-only; everything else is
# generic (a candidate for the toolkit).
# A lesson line that looks like a secret is refused (scripts/secret-shape.sh) and counted.
#
# Exit: 0 report produced (stamp written unless --dry-run); 1 crash (unreadable ledger, journal or jq failure:
# stamp NOT advanced, the tick posts cm:blocked and reruns next tick); 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/fleet-read.sh
. "$HERE/fleet-read.sh"
# shellcheck source=SCRIPTDIR/secret-shape.sh
. "$HERE/secret-shape.sh"

JSON=0; DRY=0; DUE=0; SINCE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --dry-run) DRY=1 ;;
    --due) DUE=1 ;;
    --since) [ $# -ge 2 ] || { cm_warn "lessons-recon.sh: --since needs a UTC stamp"; exit 2; }; SINCE_ARG="$2"; shift ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "lessons-recon.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done
case "$SINCE_ARG" in
  ''|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
  *) cm_warn "lessons-recon.sh: --since must be UTC like 2026-11-01T09:00:00Z"; exit 2 ;;
esac

SKILL_DIR="$(cd "$HERE/.." && pwd)"
STAMP="${CM_LESSONS_STAMP:-$CM_HOME/lessons-last-run}"
# the project-owned files: an absolute config value is used as is, a relative one is under the skill directory
proj_file() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$SKILL_DIR" "$1" ;; esac; }
LOG="${CM_LESSONS_LOG:-$(proj_file "$(cm_cfg .lessons.log_file local/lessons-log.md)")}"
REJ="${CM_LESSONS_REJECTED:-$(proj_file "$(cm_cfg .lessons.rejected_file local/lessons-rejected.md)")}"
PATHRE="${CM_PATH_MATCH:-}"
LEDGER="$(cm_ledger_path)"
SEEN="${CM_ASKS_SEEN:-$CM_HOME/asks-seen.json}"
NOW="${CM_NOW:-$(date -u +%FT%TZ)}"
NOWS="$(jq -nr --arg n "$NOW" '$n | fromdateiso8601')" || { cm_warn "lessons-recon.sh: bad CM_NOW"; exit 2; }

num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac; }
P_LANE_DAY="$(num "$(cm_cfg .lessons.per_lane_per_day 3)" 3)"
P_MIN="$(num "$(cm_cfg .lessons.min_lessons 2)" 2)"
P_MAX="$(num "$(cm_cfg .lessons.max_changes 5)" 5)"
P_CARRY="$(num "$(cm_cfg .lessons.carry_days 7)" 7)"
P_BLOCKER_RUNS="$(num "$(cm_cfg .lessons.blocker_min_runs 8)" 8)"
RISK_JSON="$(cm_cfg_json .lessons.risk_paths '["SKILL.md#hard rules","SKILL.md#merge gate","scripts/teardown.sh"]')"

# --due: the tick gate.
stamp_ts=""
if [ -s "$STAMP" ]; then
  stamp_ts="$(head -n1 "$STAMP" | tr -d '[:space:]')"
  jq -e -n --arg s "$stamp_ts" '$s | fromdateiso8601 | . > 0' >/dev/null 2>&1 || stamp_ts=""
fi
if [ "$DUE" -eq 1 ]; then
  if [ -z "$stamp_ts" ]; then echo "due: no stamp"; exit 0; fi
  age_s=$((NOWS - $(jq -nr --arg s "$stamp_ts" '$s | fromdateiso8601')))
  # a stamp in the future (clock skew, hand edit) is due: never a loop suspended by a bad stamp
  if [ "$age_s" -lt 0 ] || [ "$age_s" -ge 86400 ]; then echo "due: last run ${stamp_ts}"; exit 0; fi
  echo "not due: last run ${stamp_ts}, $((age_s / 3600))h ago"; exit 1
fi

# Window start.
if [ -n "$SINCE_ARG" ]; then
  SINCE="$SINCE_ARG"
else
  carry="$(jq -nr --argjson n "$NOWS" --argjson d "$P_CARRY" '($n - $d * 86400) | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  if [ -n "$stamp_ts" ] && [ "$stamp_ts" \< "$carry" ]; then SINCE="$stamp_ts"; else SINCE="$carry"; fi
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-lessons.XXXXXX")" || { cm_warn "lessons-recon.sh: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
crash() { cm_warn "lessons-recon.sh: $* (stamp not advanced)"; exit 1; }
: > "$TMP/cand.ndjson"

# lane label -> journal-style name (lower case, ":" to "-"), done in jq with this def.
# shellcheck disable=SC2016  # jq program
LANE_DEF='def lane_norm: ascii_downcase | gsub(":"; "-") | gsub("[^a-z0-9._-]"; "-") | .[0:64];'

# 1. comments, every host.
cm_fleet_worktrees "$TMP"
NEVER="${CM_NEVER_TOUCH:-$(cm_cfg .worktrees.never_touch)}"
# shellcheck disable=SC2086
printf '%s\n' $NEVER | tr '[:upper:]' '[:lower:]' | grep . | jq -R . | jq -sc . > "$TMP/never.json" 2>/dev/null || printf '[]\n' > "$TMP/never.json"
HOSTS_READ=()
while IFS= read -r row; do
  [ -n "$row" ] || continue
  h="$(jq -r '.host' <<<"$row")"; f="$(jq -r '.file' <<<"$row")"
  HOSTS_READ+=("$h")
  # shellcheck disable=SC2016  # jq program
  jq -c -L "$HERE" --arg host "$h" --slurpfile never "$TMP/never.json" "include \"lesson-parse\"; $LANE_DEF"'
    .result.worktrees[]
    | . as $w
    | ($w.displayName // (($w.path // "") | split("/") | last) // "") as $n
    | select((($n | tostring | ascii_downcase) as $l | any($never[0][]; . == $l)) | not)
    | ($w.comment | lessons_in[])
    | {src: "comment", host: $host, ts: null, lane: (.lane | lane_norm), text: .text, root: .root}
  ' "$f" >> "$TMP/cand.ndjson" 2>"$TMP/jq-c.err" || crash "comments of host $h unreadable: $(head -c 120 "$TMP/jq-c.err")"
done < "$TMP/hosts.ndjson"

# 2. journals (through lane-journal.sh), since the window start.
: > "$TMP/sig-respawn.ndjson"
if [ -d "$CM_HOME/lanes" ] && [ ! -L "$CM_HOME/lanes" ]; then
  for d in "$CM_HOME"/lanes/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; jl="${d##*/}"
    "$HERE/lane-journal.sh" name "$jl" >/dev/null 2>&1 || continue
    "$HERE/lane-journal.sh" tail "$jl" 500 > "$TMP/jt.txt" 2>"$TMP/jt.err" || crash "journal of lane $jl unreadable: $(head -c 120 "$TMP/jt.err")"
    # shellcheck disable=SC2016  # jq program
    jq -Rc -L "$HERE" --arg jl "$jl" --arg since "$SINCE" "include \"lesson-parse\"; $LANE_DEF"'
      select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z "))
      | {ts: .[0:20], rest: .[21:]}
      | select(.ts >= $since)
      | . as $e
      | ( ($e.rest | lessons_in[]) | {src: "journal", host: "local", ts: $e.ts, lane: (.lane | lane_norm), text: .text, root: .root} ),
        ( ($e.rest | capture("respawn cause: (?<cause>.+)$"; "i")?) | {kind: "respawn", src: "signal", host: "local", ts: $e.ts, lane: ($jl | lane_norm), cause: (.cause | sub("\\s+$"; ""))} )
    ' "$TMP/jt.txt" > "$TMP/jt.out" 2>"$TMP/jq-j.err" || crash "journal of lane $jl unparsable: $(head -c 120 "$TMP/jq-j.err")"
    jq -c 'select(.kind == null)' "$TMP/jt.out" >> "$TMP/cand.ndjson"
    jq -c 'select(.kind == "respawn")' "$TMP/jt.out" >> "$TMP/sig-respawn.ndjson"
  done
fi

# 3. ledger notes and nudges.
if [ -s "$LEDGER" ]; then
  jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1 || crash "ledger $LEDGER is not readable JSON"
  # shellcheck disable=SC2016  # jq program
  jq -c -L "$HERE" --arg since "$SINCE" "include \"lesson-parse\"; $LANE_DEF"'
    (.workers // {}) | to_entries[]
    | .key as $id | .value as $w
    | ( ( ($w.notes // empty) | (if type == "array" then .[] else . end) | lessons_in[]
          | {src: "ledger", host: ($w.host // "local"), ts: null, lane: (.lane | lane_norm), text: .text, root: .root} ),
        ( select((($w.nudges // 0) | tonumber? // 0) >= 2 and ($since == "" or ($w.lastNudgeAt == null) or (($w.lastNudgeAt // "") >= $since)))
          | {kind: "nudge", src: "signal", host: ($w.host // "local"), ts: ($w.lastNudgeAt // null), lane: (($w.lane // $id) | tostring | lane_norm),
             text: ("worker " + $id + " nudged repeatedly without progress"),
             root: "SKILL.md Stuck rule"} ) )
  ' "$LEDGER" > "$TMP/led.out" 2>"$TMP/jq-l.err" || crash "ledger unreadable: $(head -c 120 "$TMP/jq-l.err")"
  cat "$TMP/led.out" >> "$TMP/cand.ndjson"
elif [ -e "$LEDGER" ] && [ ! -s "$LEDGER" ]; then
  crash "ledger $LEDGER is empty"
fi

# 4. blocker history: cm:blocked open for lessons.blocker_min_runs runs. No window gate: a blocker open for ten days is the
#    strongest signal, and it stops coming once the lesson is in the log or the blocklist.
if [ -s "$SEEN" ] && jq -e 'type == "object"' "$SEEN" >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # jq program
  jq -c --arg since "$SINCE" --argjson minruns "$P_BLOCKER_RUNS" "$LANE_DEF"'
    to_entries[]
    | select(.value.tag == "cm:blocked" and ((.value.runs // 0) >= $minruns))
    | {kind: "blocker", src: "signal", host: (.value.host // "local"), ts: .value.firstSeen, lane: ((.value.worktree // "unknown") | lane_norm),
       text: ("blocker open over " + ($minruns | tostring) + " ticks: " + ((.key | split("\u0001") | last) | .[0:120])),
       root: "SKILL.md The tick (asks scan)"}
  ' "$SEEN" >> "$TMP/cand.ndjson" 2>"$TMP/jq-s.err" || crash "asks-seen unreadable: $(head -c 120 "$TMP/jq-s.err")"
fi

# 5. same-cause respawns become signals when a cause repeats.
if [ -s "$TMP/sig-respawn.ndjson" ]; then
  jq -sc '
    group_by(.cause | ascii_downcase | gsub("\\s+"; " ")) | map(select(length >= 2)) | .[] | .[]
    | {kind: "respawn", src: "signal", host: .host, ts: .ts, lane: .lane, text: ("respawn cause repeated: " + (.cause[0:120])), root: "SKILL.md Stuck rule"}
  ' "$TMP/sig-respawn.ndjson" >> "$TMP/cand.ndjson" 2>"$TMP/jq-r.err" || crash "respawn signals unparsable"
fi

# 6. id and secret check per candidate.
sha10() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-10; }
: > "$TMP/ided.ndjson"; REFUSED=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # the lane name and host reach the report too. A name gets the named-shape check on the RAW text (glpat-, xoxb-, sk-ant-
  # keep their dash) and the full check with dashes read as spaces, so a 42-char kebab-case lane is not a "long token".
  txt="$(jq -r '[.text, .root] | join(" ")' <<<"$line")"
  names="$(jq -r '[.lane, (.host // "")] | join(" ")' <<<"$line")"
  if secret_shaped "$txt" || secret_shaped_prefix "$names" || secret_shaped "$(printf '%s' "$names" | tr '-' ' ')"; then REFUSED=$((REFUSED + 1)); continue; fi
  # a signal is one event: its time is part of the id, so two respawns for one cause are two signals, not one.
  # A nudge signal is per worker (no time, no count in the id): one worker nudged 2 then 3 times stays ONE signal.
  key="$(jq -r '[.lane, (.text | ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")), (.root | ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")), (if .src == "signal" and .kind != "nudge" then (.ts // "") else "" end)] | join("|")' <<<"$line")"
  id="L-$(printf '%s' "$key" | sha10)"
  jq -c --arg id "$id" '. + {id: $id}' <<<"$line" >> "$TMP/ided.ndjson"
done < "$TMP/cand.ndjson"

# 7. blocklist and merged log: ids anywhere in the file.
ids_in() { [ -r "$1" ] || { echo '[]'; return; }; grep -Eo 'L-[0-9a-f]{10}' "$1" 2>/dev/null | sort -u | jq -R . | jq -sc .; }
ids_in "$REJ" > "$TMP/rej.json"; ids_in "$LOG" > "$TMP/log.json"
printf '%s\n' "${HOSTS_READ[@]+"${HOSTS_READ[@]}"}" | grep . | jq -R . | jq -sc . > "$TMP/hostsread.json" 2>/dev/null || printf '[]\n' > "$TMP/hostsread.json"

# 8. dedup, drop, cap, cluster, propose.
# shellcheck disable=SC2016  # jq program
jq -n --slurpfile cand "$TMP/ided.ndjson" --slurpfile rej "$TMP/rej.json" --slurpfile log "$TMP/log.json" \
  --slurpfile hr "$TMP/hostsread.json" --slurpfile un "$TMP/unreach.ndjson" \
  --arg since "$SINCE" --arg now "$NOW" --argjson refused "$REFUSED" --arg pathre "$PATHRE" \
  --argjson perday "$P_LANE_DAY" --argjson minl "$P_MIN" --argjson maxc "$P_MAX" --argjson risk "$RISK_JSON" '
  def squash: ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | sub("\\.$"; "");
  def tagof: (.root + " " + .text) | if test("\\[project-only\\]"; "i") then "project-only" elif test("\\[generic\\]"; "i") then "generic" else null end;
  def stripTag: gsub("\\s*\\[(project-only|generic|failure)\\]"; ""; "i") | sub("\\s+$"; "");
  def isfail: (.root + " " + .text) | test("\\[failure\\]"; "i");
  def projectish: (.root | ascii_downcase | test("project-local\\.md|config\\.yaml")) or ((.text + " " + .root) | test("#[0-9]{2,}"))
    or ($pathre != "" and ((.text + " " + .root) | test($pathre)));
  def touches($gap): ($gap | ascii_downcase) as $g
    | any($risk[]; (split("#") ) as $p | ($p[0] | ascii_downcase) as $f
        | (($g | contains($f)) or ($g | contains(($f | split("/") | last)))) and (($p | length) < 2 or ($g | contains($p[1] | ascii_downcase))));
  ($rej[0]) as $rejIds | ($log[0]) as $logIds
  # dedup by id: keep the earliest timestamp, remember the sources
  | ($cand | group_by(.id) | map(. as $g | ($g | sort_by(.ts // "9999") | .[0]) + {sources: ($g | map(.src) | unique)})) as $all
  | ($all | map(select(.id as $i | ($rejIds | index($i)) != null))) as $rejected
  | ($all | map(select(.id as $i | (($rejIds | index($i)) == null) and (($logIds | index($i)) != null)))) as $merged
  | ($all | map(select(.id as $i | (($rejIds | index($i)) == null) and (($logIds | index($i)) == null)))
      | map(. + {fail: isfail})
      | map(. + {day: ((.ts // $now)[0:10]), root: (.root | stripTag), text: (.text | stripTag), tag: (tagof // (if projectish then "project-only" else "generic" end))})) as $live
  # per lane per day cap
  | ($live | group_by([.lane, .day]) | map(sort_by([(.ts // $now), .id]) | to_entries | map(.value + {counted: (.key < $perday)})) | flatten) as $capped
  | ($capped | map(select(.counted))) as $counted
  | ($capped | map(select(.counted | not))) as $over
  # clusters by normalised gap
  | ($counted | map(. + {gapKey: (if .root == "" then "(no gap named)" else (.root | squash) end),
        rootFailure: (.src != "signal" and .root != "" and .fail)})
      | group_by(.gapKey)
      | map({ gap: (.[0].root | if . == "" then "(no gap named)" else . end),
              key: .[0].gapKey,
              named: (.[0].root != ""),
              count: length,
              rootFailure: (any(.[]; .rootFailure)),
              lanes: (map(.lane) | unique),
              tag: (if all(.[]; .tag == "generic") then "generic" else "project-only" end),
              ids: (map(.id) | unique),
              signals: (map(select(.src == "signal")) | length),
              risk: touches(.[0].root),
              lessons: map({id, lane, host, ts, text, root, tag, sources, kind: (.kind // "lesson")}) })
      | map(. + {qualifies: (.named and (.rootFailure or ((.count - .signals) >= 1 and .count >= $minl)))})
      | sort_by([(-.count), .gap])) as $clusters
  | ($clusters | map(select(.qualifies))) as $q
  | ($q[0:$maxc]) as $sel
  | { since: $since, now: $now,
      hostsRead: $hr[0],
      unreachable: ($un | map({host, error})),
      counts: { counted: ($counted | length), capped: ($over | length), rejected: ($rejected | length), merged: ($merged | length), refused: $refused,
                signals: ($counted | map(select(.src == "signal")) | length) },
      cappedIds: ($over | map(.id)),
      rejectedIds: ($rejected | map(.id)),
      clusters: $clusters,
      proposal: { pr: (($sel | length) > 0),
                  reason: (if ($counted | length) == 0 then "zero lessons" elif ($q | length) == 0 then "no gap qualifies yet" else "ok" end),
                  maxChanges: $maxc,
                  changes: ($sel | map({gap, tag, ids, lanes, risk})),
                  deferred: ($q[$maxc:] | map({gap, ids})),
                  overCap: (($q | length) > $maxc),
                  ownerPing: (any($sel[]; .risk)),
                  ownerPingWhy: ($sel | map(select(.risk) | .gap)) } }
' > "$TMP/result.json" 2>"$TMP/jq-f.err" || crash "could not build the report: $(head -c 200 "$TMP/jq-f.err")"

# 9. output, then the stamp (last, only on success, never with --dry-run).
if [ "$JSON" -eq 1 ]; then
  cat "$TMP/result.json"
else
  jq -r '
    "lessons-recon: window \(.since) .. \(.now) | hosts read: \(.hostsRead | join(",")) | unreachable: \(if (.unreachable | length) == 0 then "none" else (.unreachable | map(.host) | join(",")) end)",
    "lessons: \(.counts.counted) counted (\(.counts.signals) signals), \(.counts.capped) capped, \(.counts.rejected) rejected, \(.counts.merged) already merged, \(.counts.refused) refused (secret-shaped)",
    (.clusters[] | "CLUSTER \(.count) | \(.gap) | tag \(.tag) | \(if .qualifies then "qualifies" else "waits" end) | risk \(if .risk then "yes" else "no" end) | lanes \(.lanes | join(",")) | ids \(.ids | join(","))"),
    (.unreachable[] | "unreachable: \(.host) (\(.error))"),
    (if .proposal.pr then "proposal: PR with \(.proposal.changes | length) change(s) (cap \(.proposal.maxChanges))\(if .proposal.overCap then ", \(.proposal.deferred | length) deferred" else "" end) | owner ping: \(if .proposal.ownerPing then "yes (" + (.proposal.ownerPingWhy | join("; ")) + ")" else "no" end)"
     else "proposal: no PR (\(.proposal.reason))" end)
  ' "$TMP/result.json"
fi
if [ "$DRY" -eq 0 ]; then
  mkdir -p -- "$(dirname "$STAMP")" 2>/dev/null || true
  if ! { printf '%s\n' "$NOW" > "$STAMP.tmp.$$" && mv -f -- "$STAMP.tmp.$$" "$STAMP"; }; then
    rm -f -- "$STAMP.tmp.$$"; crash "could not write the stamp"
  fi
fi
exit 0
