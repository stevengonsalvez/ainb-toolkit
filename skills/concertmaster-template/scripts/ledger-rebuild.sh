#!/usr/bin/env bash
# ledger-rebuild.sh: `boot --rebuild` (SKILL.md § Start step 4). Rebuilds the ledger from what outlives a host: the
# lane issues on GitHub and the fleet itself (references/ledger.md § Rebuild).
#
#   scripts/ledger-rebuild.sh            # dry run: says whether a rebuild is due and prints the ledger it would write
#   scripts/ledger-rebuild.sh --apply    # writes it through cm_ledger_write (lib.sh), the one ledger write path
#
# Due when the ledger is missing (or empty), or when a lane's newest trusted `cm:state` comment
# (scripts/lane-record.sh read) is newer than that lane's ledger recordedAt (GitHub's clock on both sides). Otherwise it
# prints `ledger current` and exits 0 without reading the fleet. Any lane issue gh cannot read: exit 1, nothing judged.
#   lanes    every config lane with an `issue`: issue, state (first word of the newest cm:state), recordedState, recordedAt,
#            lead (the one standing worker classify names that lane's lead)
#   hosts    the fleet CLI host list; role, maxWorkers and hostname seeded from hosts.per_host / hosts.defaults
#   workers  `<cli> worktree list` on every reachable host (scripts/fleet-read.sh), matched to lanes by classify.sh's
#            ownership rules; an orphan (no owner) is left to the tick. Id `w-<worktree name>` (`-<host>` on a clash),
#            the concertmaster's own row worktrees.self_name, a worktree the ledger holds keeps its key. state from the
#            worktree's own first comment line (cm:asleep is asleep, so a lead put to sleep before the loss is never
#            revived), standing true for a lead, false for a cm:child claim on a name that is not lane-shaped (the
#            followups.sh rule), else null; adopted true
# A missing ledger is created whole (cm_ledger_write --init). While ledger.bak/ holds copies it refuses and prints the
# restore command; with no lane record at all it exits 4: that is first boot, not a rebuild. A present, older ledger
# keeps everything it has: a lane takes GitHub's state only when its record is newer, keeps a lead that still names a
# live row, hosts and worktrees it lacks are added, a row whose comment says cm:asleep is put back to asleep, and
# nothing is removed.
# Never adopts a ledger file found on another host (an off-host backup generation, an old state dir): such a copy is
# a stale snapshot, at best a night old, and taking it silently would bring back lane states GitHub has moved past.
# An operator restores one on purpose (references/recovery.md); this script then overlays the newer GitHub state.
# An unreachable host is reported and left out (the tick adopts its worktrees once it answers). Ownership not
# configured: no workers.
# Exit: 0 printed, written or current; 1 a read or the write failed, or a ring to restore; 2 usage or config;
# 3 another project's ledger; 4 nothing to rebuild (first boot).
# Env: CM_HOST_TIMEOUT, CM_FLEET_LIMIT (fleet-read.sh), CM_GH_TIMEOUT (lane-record.sh).
# shellcheck disable=SC2016  # the single-quoted filters are jq programs, not shell
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/fleet-read.sh
. "$HERE/fleet-read.sh"

say() { printf 'ledger-rebuild: %s\n' "$1" >&2; }
die() { say "$1"; exit "${2:-1}"; }
APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
  '') ;;
  *) die "unknown arg: $1 (use --apply, or nothing for a dry run)" 2 ;;
esac
[ -n "$CM_CONFIG_FILE" ] || die "no config.yaml found (CM_CONFIG, next to SKILL.md, or \$CM_HOME)" 2
command -v jq >/dev/null 2>&1 || die "jq not found" 2
L="$(cm_ledger_path)"
cm_ledger_guard "$L" || exit 3
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-ledger-rebuild.XXXXXX")" || die "cannot create a temp dir"
trap 'rm -rf -- "${TMP:?}"' EXIT
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATES='["absent","spawning","running","idle","draining","gone"]'

# 1. lanes, from their issues. One unreadable issue and nothing is judged: a stale ledger would pass as current.
GHFAIL=0; : > "$TMP/lanes.ndjson"
cm_cfg_json '.lanes' '[]' | jq -r '.[]? | select((.issue | type) != "number") | .name' \
  | while IFS= read -r n; do [ -z "$n" ] || say "lane $n: no lanes[].issue, not rebuilt"; done
while IFS="$(printf '\t')" read -r name issue; do
  [ -n "$name" ] || continue
  if ! out="$("$HERE/lane-record.sh" read "$name" 2>"$TMP/lr.err")"; then
    GHFAIL=1; say "lane $name: $(head -c 300 "$TMP/lr.err" | tr '\n' ' ')"; continue
  fi
  [ -n "$out" ] || say "lane $name: no cm:state comment on issue #$issue yet, state unknown"
  jq -cn --arg l "$name" --argjson i "$issue" --arg o "$out" --argjson st "$STATES" '
    ($o | capture("^(?<at>\\S+) cm:state \\S+ (?<line>.+)$") // {}) as $c
    | {key: $l, value: {issue: $i, state: (($c.line // "") | split(" ")[0] | if ($st | index(.)) then . else null end),
                        recordedState: ($c.line // null), recordedAt: ($c.at // null)}}' >> "$TMP/lanes.ndjson"
done < <(cm_cfg_json '.lanes' '[]' | jq -r '.[]? | select((.issue | type) == "number") | [.name, .issue] | @tsv')
[ "$GHFAIL" = 0 ] || die "a lane issue could not be read (above): nothing judged or written, run it again once gh answers"
LANES="$(jq -sc 'from_entries' "$TMP/lanes.ndjson")"

# 2. due? Judged per lane on GitHub's clock: a record newer than the ledger's recordedAt for that lane.
if [ -s "$L" ]; then
  jq -e 'type == "object"' "$L" >/dev/null 2>&1 || die "ledger $L is not a JSON object: restore it (references/ledger.md § Write rules)"
  due="$(jq -r --argjson lanes "$LANES" '. as $L | [$lanes | to_entries[] | select((.value.recordedAt // "") > ((($L.lanes // {})[.key].recordedAt) // "")) | .key] | join(" ")' "$L")" \
    || die "ledger $L could not be compared with the lane record"
  [ -n "$due" ] || { say "ledger current: no lane record newer than the ledger's: nothing to rebuild"; exit 0; }
  MODE=merge; say "ledger older than the lane record of: $due: merging"
else
  if [ -n "$(_cm_ledger_bak_files)" ]; then die "no ledger, but $(cm_ledger_bak_dir) holds copies: restore the newest first, then run this again: $(cm_ledger_restore_hint)"; fi
  jq -e 'any(.[]; .recordedAt != null)' <<<"$LANES" >/dev/null 2>&1 \
    || die "no ledger and no lane issue holds a cm:state record: nothing to rebuild, this is first boot (SKILL.md § First boot)" 4
  MODE=init; say "no ledger at $L: rebuilding it"
fi

# 3. the fleet: hosts and worktrees, through the shared reader
cm_fleet_worktrees "$TMP" || die "the fleet CLI could not be resolved" 2
while IFS= read -r u; do
  h="$(jq -r '.host' <<<"$u")"
  if grep -qF "\"host\":$(jq -c '.host' <<<"$u")," "$TMP/hosts.ndjson"; then say "host $h: listed but cut off, some of its worktrees may be missing"
  else say "host $h: $(jq -r '.error' <<<"$u"); its worktrees are not in the rebuild"; fi
done < "$TMP/unreach.ndjson"
REPO="$(cm_cfg .worktrees.orca_repo)"
: > "$TMP/rows.ndjson"
while IFS="$(printf '\t')" read -r h f; do
  jq -c --arg h "$h" --arg repo "$REPO" '.result.worktrees[]? | select(.isArchived != true)
    | {host: $h, source: "orca", inOrca: true, worktreeId: (.worktreeId // .id // null), repo: $repo, path: (.path // null),
       branch: ((.branch // "") | sub("^refs/heads/"; "") | if . == "" then null else . end), displayName: (.displayName // null),
       isMainWorktree: (.isMainWorktree // false), comment: (.comment // ""), agents: [],
       childWorktreeIds: (.childWorktreeIds // []), parentWorktreeId: (.parentWorktreeId // null)}' "$f" >> "$TMP/rows.ndjson" \
    || die "host $h: its worktree list could not be read"
done < <(jq -r '[.host, .file] | @tsv' "$TMP/hosts.ndjson")
jq -n --argjson ms "$(cm_now_ms)" --slurpfile ok "$TMP/hosts.ndjson" --slurpfile un "$TMP/unreach.ndjson" --slurpfile rows "$TMP/rows.ndjson" '
  ($ok | map(.host)) as $okh
  | {generatedAtMs: $ms, worktrees: $rows,
     hosts: ([$okh[] | {name: ., reachable: true}]
             + [$un[] | .host as $h | select($h != "host list" and (($okh | index($h)) == null)) | {name: $h, reachable: false, error}])}' > "$TMP/discover.json"
# a ledger of this or any other state dir never decides ownership here: classify runs with an empty CM_HOME
mkdir -p "$TMP/nohome"
CM_HOME="$TMP/nohome" CM_CONFIG="$CM_CONFIG_FILE" "$HERE/classify.sh" < "$TMP/discover.json" > "$TMP/classify.json" 2>"$TMP/classify.err" \
  || die "classify.sh failed: $(head -c 300 "$TMP/classify.err" | tr '\n' ' ')"
jq -e '.ownership.configured' "$TMP/classify.json" >/dev/null 2>&1 \
  || say "ownership not configured ($(jq -r '.ownership.error // "?"' "$TMP/classify.json")): no workers rebuilt, the tick adopts them"
jq -r '.items[]? | select(.ownerSource == "none") | "worktree \(.name) @ \(.host): no owner (ORPHAN), not rebuilt: the tick census lists it"' "$TMP/classify.json" \
  | while IFS= read -r m; do say "$m"; done

# 4. the rebuilt document
jq -n -L "$HERE" --arg now "$NOW" --arg self "$CM_SELF_WORKTREE" --argjson lanes "$LANES" --argjson hcfg "$(cm_cfg_json '.hosts' '{}')" \
  --argjson lanenames "$(cm_lane_names | jq -R . | jq -sc .)" --arg laneshape "$CM_LANE_SHAPE_RE" \
  --slurpfile cls "$TMP/classify.json" --slurpfile rows "$TMP/rows.ndjson" --slurpfile hl "$TMP/hostlist.json" \
  --slurpfile ok "$TMP/hosts.ndjson" --slurpfile old <(if [ "$MODE" = init ]; then echo '{}'; else cat "$L"; fi) '
  include "comment-segs";
  # the followups.sh tagstate table, plus cm:asleep (lane-health.sh marks a sleeping session with it)
  def cstate: (comment_segs | first // "") as $l
    | if $l == "" then null
      elif ($l | test("^cm:asleep\\b")) then "asleep"
      elif ($l | startswith("cm:") | not) then "spawning"
      else (([$l | capture("^cm:(?<t>[a-z-]+)") | .t] | first) // "") as $t
        | ({"blocked": "blocked-on-owner", "waiting-owner": "blocked-on-owner", "done": "done", "retire": "retired",
            "failed": "stuck", "keep": "parked", "running": "running", "idle": "idle", "spawning": "spawning",
            "stuck": "stuck", "parked": "parked", "queued": "queued"}[$t] // "running") end;
  # the followups.sh laneish rule: a lane-shaped name is never written standing false (teardown would take it)
  def laneish: ascii_downcase as $n | ($lanenames | index($n)) != null or ($n | test($laneshape));
  def npath: (. // "") | sub("/+$"; "");
  ($cls[0]) as $c | ($ok | map(.host)) as $okh
  | ([$rows[] | {key: "\(.host)\t\(.path)", value: .}] | from_entries) as $byPath
  | [$c.items[]? | select(.owner != null and (.ownerSource | IN("main-checkout", "out-of-scope") | not))] as $mine
  # a worktree the present ledger already holds (by path or worktree id) keeps its key, so the merge finds it
  | ([($old[0].workers // {}) | to_entries[] | select(.value | type == "object")
      | select((.value.state // "") | IN("gone", "repurposed") | not)
      | {key: "\(.value.host)\t\(.value.path | npath)", value: .key},
        (select((.value.worktreeId // "") != "") | {key: "id:\(.value.worktreeId)", value: .key})] | from_entries) as $oldKey
  | (reduce $mine[] as $i ({used: (($old[0].workers // {}) | keys), out: {}};
      (if $i.ownerSource == "self" then $self else "w-" + ($i.name | gsub("[^A-Za-z0-9._-]"; "-")) end) as $b
      | . as $st
      | ($oldKey["\($i.host)\t\($i.path | npath)"] // $oldKey["id:\($i.worktreeId // "")"]
         // ([$b, "\($b)-\($i.host)"] + [range(2; 50) | "\($b)-\($i.host)-\(.)"] | map(select(. as $k | ($st.used | index($k)) == null)) | first)) as $id
      | ($byPath["\($i.host)\t\($i.path)"].comment // "") as $cm
      | .used += [$id]
      | .out[$id] = {host: $i.host, path: $i.path, worktreeId: $i.worktreeId, lane: $i.owner, state: ($cm | cstate),
          standing: (if ($i.ownerSource | IN("lead", "self")) then true
                     elif ($i.ownerSource | startswith("comment:")) and ($i.name | laneish | not) then false else null end),
          agent: null, beadsEpic: null, parent: null, adopted: true, lastComment: (($cm | comment_segs | first // "") | .[0:200]), rebuiltAt: $now})
    | .out) as $workers
  | ($lanes | with_entries(.key as $l
      | .value.lead = ([$workers | to_entries[] | select(.value.lane == $l and .value.standing == true and .key != $self)] as $ld
                       | if ($ld | length) == 1 then $ld[0].key else null end))) as $lanesOut
  | ([$hl[0].result.hosts[]? | select((.name // "") != "")
      | (if .kind == "local" then "local" else .name end) as $k
      | (($hcfg.per_host // {})[$k] // {}) as $p
      | {key: $k, value: {kind: (if $k == "local" then "local" else "environment" end),
          selector: (if $k == "local" then "" else "--environment \($k)" end),
          reachable: (($okh | index($k)) != null), lastSeenAt: (if ($okh | index($k)) != null then $now else null end),
          offlineSince: (if ($okh | index($k)) != null then null else $now end),
          role: ($p.role // $hcfg.defaults.role // null), maxWorkers: ($p.maxWorkers // $hcfg.defaults.maxWorkers // null),
          hostname: ($p.hostname // null)}}] | from_entries) as $hosts
  | {schema: "concertmaster.ledger/v1", createdAt: $now, updatedAt: $now, rebuiltAt: $now,
     hosts: $hosts, lanes: $lanesOut, workers: $workers}' > "$TMP/doc.json" || die "could not build the rebuilt ledger"

# Merge into a present ledger: a lane takes GitHub's fields only when its record is newer, keeps a lead that still
# names a live row, hosts and worktrees are only added, and asleep only tightens (a row asleep on its comment is asleep).
MERGE='$d[0] as $d | (.workers // {}) as $W
  | .lanes = (reduce ($d.lanes | to_entries[]) as $e ((.lanes // {});
      (.[$e.key] // {}) as $o
      | .[$e.key] = ($o + {issue: $e.value.issue}
          + (if ($e.value.recordedAt // "") > ($o.recordedAt // "")
             then ($e.value | {state, recordedState, recordedAt} | with_entries(select(.value != null))) else {} end)
          + (if ($o.lead // null) != null and ($W[$o.lead] | type) == "object" and ((($W[$o.lead].state // "") | IN("gone", "repurposed")) | not) then {}
             elif $e.value.lead != null then {lead: $e.value.lead} else {} end))))
  | .hosts = ($d.hosts + (.hosts // {}))
  | .workers = (reduce ($d.workers | to_entries[]) as $e ((.workers // {});
      if has($e.key) then
        (if $e.value.state == "asleep" and (.[$e.key].state // "") != "asleep"
         then .[$e.key].asleepFrom = .[$e.key].state | .[$e.key].state = "asleep" else . end)
      else .[$e.key] = $e.value end))
  | .updatedAt = $d.updatedAt | .rebuiltAt = $d.rebuiltAt'
summary="$(jq -r '"\(.lanes | length) lanes, \(.hosts | length) hosts, \(.workers | length) workers"' "$TMP/doc.json")"
if [ "$APPLY" = 0 ]; then
  if [ "$MODE" = init ]; then jq . "$TMP/doc.json"; else jq --slurpfile d "$TMP/doc.json" "$MERGE" "$L"; fi
  say "dry run, $MODE: $summary rebuilt; nothing written (--apply writes it)"
  exit 0
fi
if [ "$MODE" = init ]; then
  cm_ledger_write --init '$d[0]' --slurpfile d "$TMP/doc.json" || die "the ledger write was refused (reason above)"
else
  cm_ledger_write "$MERGE" --slurpfile d "$TMP/doc.json" || die "the ledger write was refused (reason above)"
fi
say "written, $MODE: $summary rebuilt into $L"
