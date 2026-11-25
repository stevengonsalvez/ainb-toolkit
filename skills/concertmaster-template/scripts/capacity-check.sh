#!/usr/bin/env bash
# capacity-check.sh: tick step 2, capacity. Counts the agent terminals on every host against the host's cap and, for a host over its cap,
# LISTS the terminals that are safe to tear down. It never removes anything: scripts/teardown.sh does the removal.
#
#   scripts/capacity-check.sh                          # text report, every host
#   scripts/capacity-check.sh --json                   # {hosts:[{host,count,cap,over,candidates:[...]}], over, complete, ...}
#   scripts/capacity-check.sh --classified FILE        # reuse the tick's `discover.sh | classify.sh` JSON instead of running it
#   scripts/capacity-check.sh --no-candidates          # counts and caps only, no classification run (boot-sweep.sh); the tick lists candidates
#
# Count: the terminals of `<cli> terminal list` per host (the hosts of `host list`; a failed host list reads the local host only)
# with a non-empty agentIdentity, the same census resume.sh and live-agent.sh use. Every such terminal on the host counts, this
# project or not: the cap is about the machine. A bare shell (no agentIdentity) is not counted.
# Cap, in the order queue.sh resolves it: hosts.per_host.<host>.maxWorkers, the ledger's hosts.<host>.maxWorkers,
# hosts.defaults.maxWorkers, else CM_CAPACITY_DEFAULT_CAP only when it is set. A host with NO cap anywhere is not counted against a
# guessed number: it is a CHECK INCOMPLETE row naming it. A host that is counted against the shared defaults cap (no per_host entry of
# its own) gets a WARN row saying so. Two hosts with an identical non-zero count that are one machine (same hostname, hosts.same_machine
# or a shared terminal handle) get a WARN row too (the counts are left as read). Over cap means count > cap.
#
# Teardown candidates, only for a host over its cap, only terminals of this project (path matches worktrees.path_match), one row
# each, with the reason:
#   task-done   an agent terminal in a worktree classified done-selfreported (every agent finished, PR not open)
#   pr-merged   an agent terminal in a worktree classified done-merged (its PR is MERGED or CLOSED)
#   bare-shell  a terminal with no agentIdentity in a worktree that is done, idle or untracked (no live agent, no open work)
# NEVER listed, whatever the reason: the concertmaster's own worktree (worktrees.self_name, self_path); a standing lane (a
# configured lane, an ownership lead, a lane-shaped name per lib.sh CM_LANE_SHAPE_RE, a ledger worker with standing:true, any row
# flagged standing, standing-unknown or cm:keep, any class standing-*); a worker with open work (an open PR, dirty or unpushed git,
# a beads-epic flag, a child agent or child worktree, awaiting-input, or any class other than the three above); a main checkout.
# A worktree the classification cannot place is never listed, as an agent candidate or as a bare shell: a shell whose path matches no
# classification row may be an operator's working shell, and only a row that positively says done, idle or orphan-git-only (no
# running process, no open work) makes a shell a candidate. With no classification (it could not be read), NO candidate is listed and the
# report says CANDIDATES UNKNOWN: a missing answer is never read as "safe".
#
# Output (default), paste as printed under the census line:
#   capacity: <n> of <h> hosts over cap (target 0)[ (CHECK INCOMPLETE: <host>: <why>)][ (WARN: <name>: <why>)]
#     HOST <host> claude=<count> cap=<cap> ok|OVER by <n>
#     CANDIDATE <host> <handle> <reason> <name>: <path>
#     NO SAFE CANDIDATES <host>: ... / CANDIDATES UNKNOWN <host>: ... / (none needed) for a host within its cap
#     NOTE <host>: <the beads-store limit below>   (printed after a host's CANDIDATE rows; --json: hosts[].candidatesNote)
# The list is built from the classification only and does NOT read a worktree's beads store: teardown.sh refuses on open beads, so a
# listed row can still be refused there. Dry-run teardown.sh (the default, no --apply) on a row before acting on it.
# Env: CM_HOST_TIMEOUT (default 60 s per call), CM_CAPACITY_BUDGET (80), CM_CAPACITY_LIST_TIMEOUT (20), CM_CAPACITY_DEFAULT_CAP (unset), CM_CAPACITY_CLASSIFY_CMD (a command that
# prints classify.sh JSON; default `discover.sh | classify.sh`, run only when a host is over cap and --classified is not given).
# Exit: 0 every host read is within its cap; 1 at least one host is over its cap; 2 usage. A host that cannot be read is listed in
# the CHECK INCOMPLETE suffix and is never read as "within cap" or as "over cap".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

MODE=text
CLASSIFIED=""
NOCAND=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE=json; shift ;;
    --no-candidates) NOCAND=1; shift ;;
    --classified)
      [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "capacity-check.sh: --classified needs a file"; exit 2; }
      CLASSIFIED="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "capacity-check.sh: unknown arg: $1"; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { cm_warn "capacity-check.sh: missing dependency: jq"; echo "capacity: unknown (CHECK INCOMPLETE: jq missing)"; exit 0; }
if [ -z "$CM_PATH_MATCH" ]; then
  cm_warn "capacity-check.sh: set worktrees.path_match in config.yaml (or CM_PATH_MATCH)"
  echo "capacity: unknown (CHECK INCOMPLETE: no worktrees.path_match)"; exit 0
fi
CLI="$(cm_cli)" || { echo "capacity: unknown (CHECK INCOMPLETE: no fleet CLI)"; exit 0; }
HT="${CM_HOST_TIMEOUT:-60}"
# Time budget of the host phase (CM_CAPACITY_BUDGET, default 80 s: under boot-sweep's 90 s kill): ONE host list (at most
# CM_CAPACITY_LIST_TIMEOUT, 20 s) and then every host read IN PARALLEL, each cut to what is left of the budget. The worst case is
# the list plus ONE read, not the list plus one read per host. A host that does not answer in time is a CHECK INCOMPLETE row.
BUDGET="${CM_CAPACITY_BUDGET:-80}"; LT="${CM_CAPACITY_LIST_TIMEOUT:-20}"; [ "$LT" -le "$HT" ] 2>/dev/null || LT="$HT"
T0="$(date +%s)"
# the built-in default cap is used only when asked for explicitly (CM_CAPACITY_DEFAULT_CAP set); a host with no cap anywhere is not counted
DEFCAP="${CM_CAPACITY_DEFAULT_CAP:-}"
case "$DEFCAP" in *[!0-9]*) cm_warn "capacity-check.sh: CM_CAPACITY_DEFAULT_CAP must be a number"; exit 2 ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-capacity.XXXXXX")" || { cm_warn "capacity-check.sh: cannot create a temp dir"; echo "capacity: unknown (CHECK INCOMPLETE: no temp dir)"; exit 0; }
trap 'rm -rf -- "${TMP:?}"' EXIT

# hosts: the same list discover.sh reads
: > "$TMP/hosts.tsv"; : > "$TMP/bad.tsv"
if cm_timeout "$LT" "$CLI" host list --json </dev/null > "$TMP/hostlist.json" 2>/dev/null && jq -e '.ok == true and (.result.hosts | type == "array")' "$TMP/hostlist.json" >/dev/null 2>&1; then
  jq -r '.result.hosts[] | (if .kind == "local" then "local" else .name end)' "$TMP/hostlist.json" > "$TMP/hosts.tsv"
else
  echo local > "$TMP/hosts.tsv"
  printf '%s\t%s\n' "(host list)" "the host list failed, only the local host was read" > "$TMP/bad.tsv"
fi

LEDGER="${CM_LEDGER:-$CM_HOME/ledger.json}"
# Data of ledger, classification or discover size is NEVER an argument (Linux caps one argument at 128 KiB: the live ledger is
# several times that and jq died with "Argument list too long"): it goes to jq as a file (--slurpfile or a file operand).
LFILE="$TMP/ledger.json"; echo '{}' > "$LFILE"
# A ledger that is not one JSON object, a workers that is not an object (false and [] included), an unparseable or truncated file and a repeated key under workers are UNREADABLE
# (lib.sh cm_workers_gate): no candidate is listed, whatever the rest says. Read as "{}" they listed a standing ledger lane as a candidate to close.
LEDGER_BAD=""
if [ -e "$LEDGER" ]; then LEDGER_BAD="$(cm_workers_gate "$LEDGER")" || LEDGER_BAD="${LEDGER_BAD:-the ledger cannot be read}"; fi
if [ -r "$LEDGER" ]; then
  if ! jq -c 'if type == "object" then . else {} end' "$LEDGER" > "$LFILE.new" 2>/dev/null; then
    printf '%s\t%s\n' "(ledger)" "the ledger could not be parsed: caps come from config only" >> "$TMP/bad.tsv"
  else mv -f "$LFILE.new" "$LFILE"; fi
fi

# terminals per host: {host, handle, path, agent, title, scope} rows; a failed or cut-off list makes the host incomplete.
# One background job per host (a job writes only its own files under $TMP/h/<n>), then the results are joined in host order.
mkdir -p "$TMP/h"
read_host() { # <n> <host>
  local n="$1" host="$2" d="$TMP/h/$1" rc=0 why cap hs=() left ht
  mkdir -p "$d"; : > "$d/terms.ndjson"; : > "$d/bad.tsv"; : > "$d/row.json"; : > "$d/warn.tsv"
  cm_cli_host_into hs "$host" || { printf '%s\t%s\n' "$host" "bad host name" >> "$d/bad.tsv"; return 0; }
  left=$(( BUDGET - ( $(date +%s) - T0 ) )); ht="$HT"; [ "$left" -ge "$ht" ] || ht="$left"; [ "$ht" -ge 1 ] || ht=1
  cm_timeout "$ht" "$CLI" terminal list ${hs[@]+"${hs[@]}"} --limit 500 --json </dev/null > "$d/tl.json" 2>"$d/tl.err" || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e '.ok == true and (.result.terminals | type == "array")' "$d/tl.json" >/dev/null 2>&1; then
    why="rc=$rc $(head -c 120 "$d/tl.err" 2>/dev/null | tr '\t\n' '  ')"; [ "$rc" -eq 124 ] && why="not checked: time budget (timeout after ${ht}s)"
    printf '%s\t%s\n' "$host" "$why" >> "$d/bad.tsv"; return 0
  fi
  if jq -e '.result.truncated == true' "$d/tl.json" >/dev/null 2>&1; then
    printf '%s\t%s\n' "$host" "terminal list truncated at 500: the count is a lower bound" >> "$d/bad.tsv"
  fi
  jq -c --arg host "$host" --arg re "$CM_PATH_MATCH" '
    .result.terminals[]
    | ((.worktreePath // "") | if type == "string" then sub("/+$"; "") else "" end) as $p
    | {host: $host, handle: (.handle // ""), path: $p, title: (.title // ""),
       agent: (((.agentIdentity // "") | tostring) != ""),
       scope: ($p != "" and ($p | test($re)))}' "$d/tl.json" >> "$d/terms.ndjson" 2>/dev/null \
    || { printf '%s\t%s\n' "$host" "the terminal list could not be parsed" >> "$d/bad.tsv"; : > "$d/terms.ndjson"; return 0; }
  # The cap of this host, in queue.sh's order: config per_host, the ledger's host, config defaults. Only a configured number counts.
  # No cap anywhere (and no explicit CM_CAPACITY_DEFAULT_CAP): the host is NOT counted against a guessed 2, it is CHECK INCOMPLETE
  # naming it (a host the config does not know by this name is often the same machine under another name). A lookup that FAILS is
  # a problem for this host too, never a default cap.
  cap="$(printf '%s' "$CM_CFG_JSON" | jq -r --arg h "$host" --slurpfile L "$LFILE" --arg d "$DEFCAP" \
        '(.hosts.per_host[$h].maxWorkers // $L[0].hosts[$h].maxWorkers // .hosts.defaults.maxWorkers // (if $d == "" then null else ($d | tonumber) end)) | if . == null then "none" else (tonumber | floor) end' 2>"$d/cap.err")" || cap=""
  case "$cap" in
    none) printf '%s\t%s\n' "$host" "no cap configured for this host name (hosts.per_host.$host.maxWorkers, the ledger hosts.$host.maxWorkers, hosts.defaults.maxWorkers): not compared, so it is never counted against a guessed cap; add it, or fix the name if it is another host's alias" >> "$d/bad.tsv"; return 0 ;;
    ''|*[!0-9]*) printf '%s\t%s\n' "$host" "cap lookup failed ($(head -c 100 "$d/cap.err" 2>/dev/null | tr '\t\n' '  ')): host not counted" >> "$d/bad.tsv"; return 0 ;;
  esac
  # a host with no entry of its own that is counted against the shared defaults cap: said, so a wrong name is seen
  if [ "$(printf '%s' "$CM_CFG_JSON" | jq -r --arg h "$host" '(.hosts.per_host[$h].maxWorkers // null) == null' 2>/dev/null)" = true ] \
     && [ "$(jq -r --arg h "$host" '(.hosts[$h].maxWorkers // null) == null' "$LFILE" 2>/dev/null)" = true ]; then
    printf '%s\t%s\n' "$host" "no hosts.per_host.$host entry: counted against the shared default cap $cap (check the host name against the config)" >> "$d/warn.tsv"
  fi
  jq -cn --arg host "$host" --argjson cap "$cap" '{host: $host, cap: $cap}' > "$d/row.json"
}
n=0; JOBS=()
while IFS= read -r host; do
  [ -n "$host" ] || continue
  n=$((n + 1)); read_host "$n" "$host" & JOBS+=("$!")
done < "$TMP/hosts.tsv"
for j in ${JOBS[@]+"${JOBS[@]}"}; do wait "$j" 2>/dev/null || true; done
: > "$TMP/terms.ndjson"; : > "$TMP/hostrows.ndjson"; : > "$TMP/warn.tsv"
for ((i = 1; i <= n; i++)); do
  d="$TMP/h/$i"; [ -d "$d" ] || continue
  cat "$d/terms.ndjson" >> "$TMP/terms.ndjson" 2>/dev/null; cat "$d/bad.tsv" >> "$TMP/bad.tsv" 2>/dev/null
  cat "$d/warn.tsv" >> "$TMP/warn.tsv" 2>/dev/null
  if [ -s "$d/row.json" ]; then cat "$d/row.json" >> "$TMP/hostrows.ndjson"; fi
done

# per-host count and over flag
jq -sc --slurpfile t "$TMP/terms.ndjson" '
  [ .[] | . as $h | ([ $t[] | select(.host == $h.host and .agent) ] | length) as $n
    | {host: $h.host, cap: $h.cap, count: $n, over: ($n > $h.cap)} ]' "$TMP/hostrows.ndjson" > "$TMP/counts.json" 2>/dev/null \
  || { echo '[]' > "$TMP/counts.json"; printf '%s\t%s\n' "(counts)" "the per-host count could not be computed" >> "$TMP/bad.tsv"; }
NOVER="$(jq 'map(select(.over)) | length' "$TMP/counts.json")"

# Same machine under two names (a live pair of hosts that each reported 29): two hosts that report an IDENTICAL non-zero count AND
# are the same machine by the config (the same hosts.per_host.<h>.hostname, or one group of hosts.same_machine) or by
# the evidence (a terminal handle both lists hold). A WARN row, never a merge: the counts stand as read. Mirrors queue.sh, which also
# says when the config names a host the census does not and the census names one the config does not.
# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
printf '%s' "$CM_CFG_JSON" | jq -r --slurpfile c "$TMP/counts.json" --slurpfile t "$TMP/terms.ndjson" '
  . as $cfg
  | ($c[0]) as $cnt
  | def groups($v): $v | if type == "array" then [.[] | arrays] else [] end;
    groups($cfg.hosts.same_machine) as $sm
  # deprecated: health.host_aliases as a list of name lists meant hosts.same_machine (its map form is hostname aliases only)
  | groups($cfg.health.host_aliases) as $legacy
  | def hn($h): ($cfg.hosts.per_host[$h].hostname // null);
    def together($gs; $a; $b): any($gs[]; (index($a) != null) and (index($b) != null));
    def shared($a; $b): ([ $t[] | select(.host == $a and .handle != "") | .handle ] as $ha
                         | any($t[]; .host == $b and .handle != "" and (.handle | IN($ha[]))));
  [ range(0; $cnt | length) as $i | range($i + 1; $cnt | length) as $j | $cnt[$i] as $x | $cnt[$j] as $y
    | select($x.count > 0 and $x.count == $y.count)
    | (if (hn($x.host) != null and hn($x.host) == hn($y.host)) then "the same hostname \(hn($x.host))"
       elif together($sm; $x.host; $y.host) then "hosts.same_machine"
       elif together($legacy; $x.host; $y.host) then "health.host_aliases, deprecated"
       elif shared($x.host; $y.host) then "a terminal handle both lists hold"
       else empty end) as $why
    | "\($y.host)\t\($x.host) and \($y.host) both report \($x.count) agent terminals and look like ONE machine (\($why)): counted twice, so the over-cap total is overstated; list one of them or fix the names (the counts are left as read)" ] | .[],
  ( ($cfg.hosts.per_host // {} | keys) as $cn | ([ $cnt[].host ]) as $rn
    | (($cn - $rn)) as $miss | (($rn - $cn - ["local"])) as $extra
    | select(($miss | length) > 0 and ($extra | length) > 0)
    | "(host names)\tconfig hosts \($miss | join(",")) were not read, read hosts \($extra | join(",")) are not in hosts.per_host: check the hosts.per_host names against the fleet host list" ),
  # an old same-machine entry in the map form ({ build-box: [build-box-2] }, the old example): once per entry whose
  # hosts report the same non-zero count and are not already in one hosts.same_machine group (an empty list is none)
  ( select(($cfg.health.host_aliases | type) == "object")
    | $cfg.health.host_aliases | to_entries[] | .key as $k | ([.key] + [.value | if type == "array" then .[] else . end | strings]) as $g
    | first([ range(0; $cnt | length) as $i | range($i + 1; $cnt | length) as $j | $cnt[$i] as $x | $cnt[$j] as $y
              | select($x.count > 0 and $x.count == $y.count and ($g | index($x.host)) != null and ($g | index($y.host)) != null
                       and (together($sm; $x.host; $y.host) | not))
              | [$x.host, $y.host, $x.count] ][])
    | "(config)\thealth.host_aliases.\($k) names \(.[0]) and \(.[1]), which both report \(.[2]) agent terminals: health.host_aliases is now only the names hostname -s answers as, so they are no longer treated as one machine; if they are, list them in hosts.same_machine" ),
  ( select(($legacy | length) > 0)
    | "(config)\thealth.host_aliases as a list of name lists is deprecated: move it to hosts.same_machine (health.host_aliases is a map of host to the names hostname -s answers as)" )
' >> "$TMP/warn.tsv" 2>/dev/null || printf '%s\t%s\n' "(warnings)" "the same-machine check could not run" >> "$TMP/warn.tsv"
jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], warning: (.[1] // "")})' "$TMP/warn.tsv" > "$TMP/warn.json" 2>/dev/null || echo '[]' > "$TMP/warn.json"

# classification: only when a host is over cap
CFILE="$TMP/cls.use.json"; echo null > "$CFILE"; CLSWHY=""
if [ "$NOVER" -gt 0 ] && [ "$NOCAND" = 0 ]; then
  if [ -n "$CLASSIFIED" ]; then
    if [ -r "$CLASSIFIED" ] && jq -e '.items | type == "array"' "$CLASSIFIED" >/dev/null 2>&1; then cp -- "$CLASSIFIED" "$CFILE"; else CLSWHY="--classified file unreadable or has no items"; fi
  else
    rc=0
    if [ -n "${CM_CAPACITY_CLASSIFY_CMD:-}" ]; then
      cm_timeout 300 bash -c "$CM_CAPACITY_CLASSIFY_CMD" </dev/null > "$TMP/cls.json" 2>"$TMP/cls.err" || rc=$?
    else
      { cm_timeout 300 "$HERE/discover.sh" </dev/null 2>"$TMP/cls.err" | cm_timeout 300 "$HERE/classify.sh" > "$TMP/cls.json" 2>>"$TMP/cls.err"; } || rc=$?
    fi
    if [ "$rc" -eq 0 ] && jq -e '.items | type == "array"' "$TMP/cls.json" >/dev/null 2>&1; then cp -- "$TMP/cls.json" "$CFILE"
    else CLSWHY="classification failed rc=$rc $(head -c 100 "$TMP/cls.err" 2>/dev/null | tr '\t\n' '  ')"; fi
  fi
fi

# exemption inputs, as in unlinked-worktrees.sh
cm_lane_names | jq -R . | jq -sc . > "$TMP/lanes.json" 2>/dev/null || echo '[]' > "$TMP/lanes.json"
[ -s "$TMP/lanes.json" ] || echo '[]' > "$TMP/lanes.json"
# a standing-path list that could not be computed exempts nothing: it is counted below as unreadable, never read as "no standing lane"
STAND_UNREAD=0
jq -c "$CM_JQ_STATE_DEFS"'[(.workers // {}) | to_entries[] | .value | select(type == "object" and (.standing | cm_standing_any)) | (.path, .worktree, .worktreePath) | select(type == "string" and . != "") | sub("/+$"; "")]' "$LFILE" > "$TMP/stand.json" 2>/dev/null || { echo '[]' > "$TMP/stand.json"; STAND_UNREAD=1; }
[ -s "$TMP/stand.json" ] || echo '[]' > "$TMP/stand.json"
# A standing row (or a row that is not an object, or whose host or path is not text) with NO path that is text cannot exempt its worktree: its path is read as "nothing there", and the
# lane would be listed as a candidate to close. It is counted here and the candidate pass is not run while there is one (the typed boundary: a wrong-typed row is held, never dropped).
STAND_BAD="$(jq -r "$CM_JQ_STATE_DEFS $CM_JQ_NAME_DEFS"'[(.workers // {}) | if type == "object" then to_entries[] else empty end
    | select((.value | type) != "object" or (((.value.state | cm_state_dead) | not) and ((.value | cm_wild) or ((.value.standing | cm_standing_any) and ([.value.path, .value.worktree, .value.worktreePath] | all(type != "string" or . == ""))))))] | length' "$LFILE" 2>/dev/null)"
# no number back means the count could not be computed (a ledger whose workers is not a map, a jq failure): that is unreadable (1), never "no bad row" (0)
[ -n "$STAND_BAD" ] || STAND_BAD=1
# anything but ONE whole number (a ledger of two JSON documents prints one count per document: "0" and "0") is unreadable too, never "none"
case "$STAND_BAD" in ''|*[!0-9]*) STAND_BAD=1 ;; esac
[ -z "$LEDGER_BAD" ] || [ "$STAND_BAD" != 0 ] || STAND_BAD=1
[ "$STAND_UNREAD" = 0 ] || [ "$STAND_BAD" != 0 ] || STAND_BAD=1
SELFPATH="${CM_SELF_PATH:-$(cm_cfg .worktrees.self_path "")}"; SELFPATH="${SELFPATH%/}"

# candidates, for the hosts over cap (one jq pass over the per-host rows)
# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
if [ "$STAND_BAD" = 0 ] && jq -c --slurpfile t "$TMP/terms.ndjson" --slurpfile clsf "$CFILE" --arg defer "$NOCAND" --arg self "$(cm_lower "$CM_SELF_WORKTREE")" --arg selfpath "$SELFPATH" \
      --arg shape "$CM_LANE_SHAPE_RE" --slurpfile lanesf "$TMP/lanes.json" --slurpfile standf "$TMP/stand.json" '
  ($clsf[0]) as $cls | ($lanesf[0]) as $lanes | ($standf[0]) as $stand |
  def base: (. | sub("/+$"; "") | split("/") | last // "");
  def protected_name: . as $p | ($p | base | ascii_downcase) as $n
    | ($n == $self) or ($selfpath != "" and $p == $selfpath)
      or any($lanes[]; . == $n) or ($n | test($shape)) or any($stand[]; . == $p);
  def open_flag: (.flags // []) | any(.[]; . == "standing" or . == "standing-unknown" or . == "cm:keep" or . == "awaiting-input"
                   or . == "has-children" or . == "has-child-agent" or . == "git-unknown" or . == "git-check-failed" or . == "terminals-unknown"
                   or . == "ORPHAN" or . == "LEAD-DEAD"
                   or startswith("beads-epic:") or startswith("dirty:") or startswith("unpushed:"));
  def pr_open: ((.pr.state // "") | ascii_upcase) == "OPEN" or ((.flags // []) | any(.[]; endswith(":OPEN")));
  map(. as $c
    | if ($c.over | not) then $c + {candidates: [], candidatesState: "none-needed"}
      elif $cls == null then $c + {candidates: [], candidatesState: (if $defer == "1" then "deferred" else "unknown" end)}
      else
        ([ $t[] | select(.host == $c.host and .scope) ]) as $rows
        | ([ $rows[] | . as $r
             | ($r.path) as $p
             | ([ $cls.items[] | select(.host == $c.host and ((.path // "") | sub("/+$"; "")) == $p) ] | first) as $it
             | if ($p | protected_name) then empty
               elif $r.agent then
                 if $it == null or ($it | open_flag) or ($it | pr_open) then empty
                 elif $it.class == "done-merged" then {handle: $r.handle, reason: "pr-merged", name: ($p | base), path: $p}
                 elif $it.class == "done-selfreported" then {handle: $r.handle, reason: "task-done", name: ($p | base), path: $p}
                 else empty end
               else
                 if $it == null then empty
                 elif ($it | open_flag) or ($it | pr_open) then empty
                 elif ($it.class | IN("done-merged", "done-selfreported", "idle", "orphan-git-only")) then {handle: $r.handle, reason: "bare-shell", name: ($p | base), path: $p}
                 else empty end
               end ]
           | sort_by(.reason, .path, .handle)) as $cand
        | $c + {candidates: $cand, candidatesState: (if ($cand | length) > 0 then "listed" else "none-safe" end)}
      end)' "$TMP/counts.json" > "$TMP/res.json" 2>"$TMP/res.err"; then :; else
  # the candidate pass failed: the counts still stand (an over-cap host is still over), the candidates are unknown, and it is said
  if [ "$STAND_BAD" != 0 ]; then
    printf '%s\t%s\n' "(ledger)" "$STAND_BAD ledger worker row(s) cannot be read (a row that is not an object, a host or path that is not text, or a standing row with no path that is text)${LEDGER_BAD:+; the ledger itself: $LEDGER_BAD}: a standing lane could be listed as a candidate, so none is listed, fix the ledger" >> "$TMP/bad.tsv"
    CLSWHY="a ledger worker row cannot be read"
  else
    printf '%s\t%s\n' "(candidates)" "the candidate pass failed ($(head -c 100 "$TMP/res.err" | tr '\t\n' '  ')): none listed" >> "$TMP/bad.tsv"
    CLSWHY="candidate pass failed"
  fi
  jq -c 'map(. + {candidates: [], candidatesState: (if .over then "unknown" else "none-needed" end)})' "$TMP/counts.json" > "$TMP/res.json" 2>/dev/null || echo '[]' > "$TMP/res.json"
fi
# no host at all (every host unread) is never an all-clear
[ "$(jq 'length' "$TMP/res.json" 2>/dev/null || echo 0)" -gt 0 ] || printf '%s\t%s\n' "(hosts)" "no host could be counted" >> "$TMP/bad.tsv"

jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], error: (.[1] // "")})' "$TMP/bad.tsv" > "$TMP/bad.json" 2>/dev/null || echo '[{"name":"(report)","error":"the problem list could not be built"}]' > "$TMP/bad.json"
OVER="$(jq 'map(select(.over)) | length' "$TMP/res.json")"
# The candidate list is built from the classification only: it does NOT read a worktree's beads store. teardown.sh refuses on open
# beads (it reads the store itself), so a row here can still be refused there; nothing is removed by this script. The smaller
# safe option was taken over filtering through a teardown.sh dry run: that script does ssh, git and bd reads per worktree plus a
# fleet-wide rival scan, which does not fit this check's budget, so the limit is said plainly instead.
CAND_NOTE="the candidate list does not read a worktree's beads store; scripts/teardown.sh refuses on open beads, so dry-run it (no --apply) before acting on any row"

if [ "$MODE" = json ]; then
  jq -c --slurpfile badf "$TMP/bad.json" --slurpfile warnf "$TMP/warn.json" --arg why "$CLSWHY" --arg note "$CAND_NOTE" '$badf[0] as $bad | {hosts: map(if ((.candidates // []) | length) > 0 then . + {candidatesNote: $note} else . end), over: (map(select(.over)) | length), hostsRead: length,
      classification: (if $why == "" then "ok" else $why end), problems: $bad, warnings: $warnf[0], complete: ($bad | length == 0)}' "$TMP/res.json"
  [ "$OVER" -gt 0 ] && exit 1
  exit 0
fi

suffix=""
[ "$(jq -r 'length' "$TMP/bad.json")" -gt 0 ] && suffix=" (CHECK INCOMPLETE: $(jq -r 'map("\(.name): \(.error)") | join("; ")' "$TMP/bad.json"))"
[ "$(jq -r 'length' "$TMP/warn.json")" -gt 0 ] && suffix="$suffix (WARN: $(jq -r 'map("\(.name): \(.warning)") | join("; ")' "$TMP/warn.json"))"
printf 'capacity: %s of %s hosts over cap (target 0)%s\n' "$OVER" "$(jq 'length' "$TMP/res.json")" "$suffix"
# one block per host: the HOST line, the state line, then its CANDIDATE rows
# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
jq -r --arg why "${CLSWHY:-no classification}" --arg note "$CAND_NOTE" '.[] | . as $c
  | "  HOST \(.host) claude=\(.count) cap=\(.cap) " + (if .over then "OVER by \(.count - .cap)" else "ok (none needed)" end),
    (if .candidatesState == "unknown" then "  CANDIDATES UNKNOWN \(.host): \($why | gsub("[\n\r]"; " "))"
     elif .candidatesState == "none-safe" then "  NO SAFE CANDIDATES \(.host): \(.count - .cap) over cap, every terminal here is a standing lane, the concertmaster or has open work; nothing may be torn down"
     else empty end),
    (.candidates[]? | "  CANDIDATE \($c.host) \(.handle) \(.reason) \(.name): \(.path)"),
    (if ((.candidates // []) | length) > 0 then "  NOTE \(.host): \($note)" else empty end)' "$TMP/res.json"
[ "$OVER" -gt 0 ] && exit 1
exit 0
