#!/usr/bin/env bash
# ledger-rebuild.sh: `boot --rebuild` (SKILL.md § Start step 4). Rebuilds the ledger from what outlives a host: the
# lane issues on GitHub and the fleet itself (references/ledger.md § Rebuild).
#
#   scripts/ledger-rebuild.sh            # dry run: says whether a rebuild is due and prints the ledger it would write
#   scripts/ledger-rebuild.sh --apply    # writes it through cm_ledger_write (lib.sh), the one ledger write path
#
# Due when the ledger is missing (or empty), or older (its updatedAt) than the newest `cm:state` comment on any lane
# issue (scripts/lane-record.sh read). Otherwise it prints `ledger current` and exits 0 without reading the fleet.
#   lanes    every config lane with an `issue`: issue, state (first word of the newest cm:state), recordedState, recordedAt,
#            lead (the worker whose worktree classify names that lane's lead)
#   hosts    the fleet CLI host list; role, maxWorkers and hostname seeded from hosts.per_host / hosts.defaults
#   workers  `<cli> worktree list` on every reachable host (scripts/fleet-read.sh), matched to lanes by classify.sh's
#            ownership rules; id `w-<worktree name>` (`-<host>` on a clash), the concertmaster's own row is
#            worktrees.self_name. state from the worktree's own first comment line (cm:asleep is asleep, so a lead
#            put to sleep before the loss is never revived), standing true for a lead, false for a cm:child claim
#            (as followups.sh adopts one), else null; adopted true
# A missing ledger is created whole (cm_ledger_write --init, which refuses while ledger.bak/ holds copies: restore one
# first, references/ledger.md § Write rules). A present, older ledger keeps everything it has: lane fields GitHub
# answered are replaced (GitHub wins), hosts and worktrees it does not know are added, nothing is removed.
# Never adopts a ledger file found on another host (an off-host backup generation, an old state dir): such a copy is
# a stale snapshot, at best a night old, and taking it silently would bring back lane states GitHub has moved past.
# An operator restores one on purpose (references/recovery.md); this script then overlays the newer GitHub state.
# An unreachable host is reported and left out (the tick adopts its worktrees once it answers). A lane issue that
# could not be read is reported; --apply then writes nothing (exit 1). Ownership not configured: no workers.
# Exit: 0 printed, written or current; 1 a read or the write failed; 2 usage or config; 3 another project's ledger.
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
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
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

# 1. lanes, from their issues
GHFAIL=0; : > "$TMP/lanes.ndjson"
cm_cfg_json '.lanes' '[]' | jq -r '.[]? | select((.issue | type) != "number") | .name' \
  | while IFS= read -r n; do [ -z "$n" ] || say "lane $n: no lanes[].issue, not rebuilt"; done
while IFS="$(printf '\t')" read -r name issue; do
  [ -n "$name" ] || continue
  if ! out="$("$HERE/lane-record.sh" read "$name" 2>"$TMP/lr.err")"; then
    GHFAIL=1; say "lane $name: $(head -c 300 "$TMP/lr.err" | tr '\n' ' ')"; out=""
  fi
  [ -n "$out" ] || [ "$GHFAIL" = 1 ] || say "lane $name: no cm:state comment on issue #$issue yet, state unknown"
  jq -cn --arg l "$name" --argjson i "$issue" --arg o "$out" --argjson st "$STATES" '
    ($o | capture("^(?<at>\\S+) cm:state \\S+ (?<line>.+)$") // {}) as $c
    | {key: $l, value: {issue: $i, state: (($c.line // "") | split(" ")[0] | if ($st | index(.)) then . else null end),
                        recordedState: ($c.line // null), recordedAt: ($c.at // null)}}' >> "$TMP/lanes.ndjson"
done < <(cm_cfg_json '.lanes' '[]' | jq -r '.[]? | select((.issue | type) == "number") | [.name, .issue] | @tsv')
LANES="$(jq -sc 'from_entries' "$TMP/lanes.ndjson")"

# 2. due?
if [ -s "$L" ]; then
  jq -e 'type == "object"' "$L" >/dev/null 2>&1 || die "ledger $L is not a JSON object: restore it (references/ledger.md § Write rules)"
  read -r upd newest < <(jq -r --argjson lanes "$LANES" '[(.updatedAt // "-"), ([$lanes[].recordedAt | strings] | max // "-")] | @tsv' "$L")
  if [ "$newest" = "-" ] || { [ "$upd" != "-" ] && ! [[ "$newest" > "$upd" ]]; }; then
    say "ledger current (updatedAt $upd, newest cm:state ${newest/#-/none}): nothing to rebuild"; exit 0
  fi
  MODE=merge; say "ledger older than the lane record (updatedAt $upd, newest cm:state $newest): merging"
else
  MODE=init; say "no ledger at $L: rebuilding it"
fi

# 3. the fleet: hosts and worktrees, through the shared reader
cm_fleet_worktrees "$TMP" || die "the fleet CLI could not be resolved" 2
while IFS= read -r u; do say "host $(jq -r '.host' <<<"$u"): $(jq -r '.error' <<<"$u"); its worktrees are not in the rebuild"; done < "$TMP/unreach.ndjson"
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

# 4. the rebuilt document
OLD='{}'; [ "$MODE" = init ] || OLD="$L"
jq -n --arg now "$NOW" --arg self "$CM_SELF_WORKTREE" --argjson lanes "$LANES" --argjson hcfg "$(cm_cfg_json '.hosts' '{}')" \
  --slurpfile cls "$TMP/classify.json" --slurpfile rows "$TMP/rows.ndjson" --slurpfile hl "$TMP/hostlist.json" \
  --slurpfile ok "$TMP/hosts.ndjson" --slurpfile old <(if [ "$MODE" = init ]; then echo '{}'; else cat "$OLD"; fi) '
  def segs: (if type == "string" then . else "" end) | gsub("\\\\n"; "\n") | [split("\n")[] | split(" | ")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0)];
  # the followups.sh tagstate table, plus cm:asleep (lane-health.sh marks a sleeping session with it)
  def cstate: (segs | first // "") as $l
    | if $l == "" then null
      elif ($l | test("^cm:asleep\\b")) then "asleep"
      elif ($l | startswith("cm:") | not) then "spawning"
      else (([$l | capture("^cm:(?<t>[a-z-]+)") | .t] | first) // "") as $t
        | ({"blocked": "blocked-on-owner", "waiting-owner": "blocked-on-owner", "done": "done", "retire": "retired",
            "failed": "stuck", "keep": "parked", "running": "running", "idle": "idle", "spawning": "spawning",
            "stuck": "stuck", "parked": "parked", "queued": "queued"}[$t] // "running") end;
  ($cls[0]) as $c | ($ok | map(.host)) as $okh
  | ([$rows[] | {key: "\(.host)\t\(.path)", value: .}] | from_entries) as $byPath
  | [$c.items[]? | select(.ownerSource != null and (.ownerSource | IN("main-checkout", "out-of-scope") | not))] as $mine
  # a worktree the present ledger already holds keeps its key, so a lead found here names the row the ledger has
  | ([($old[0].workers // {}) | to_entries[] | select(.value | type == "object")
      | select((.value.state // "") | IN("gone", "repurposed") | not)
      | {key: "\(.value.host)\t\((.value.path // "") | sub("/+$"; ""))", value: .key}] | from_entries) as $oldKey
  | (reduce $mine[] as $i ({used: (($old[0].workers // {}) | keys), out: {}};
      (if $i.ownerSource == "self" then $self else "w-" + ($i.name | gsub("[^A-Za-z0-9._-]"; "-")) end) as $b
      | . as $st
      | ($oldKey["\($i.host)\t\($i.path | sub("/+$"; ""))"]
         // ([$b, "\($b)-\($i.host)"] + [range(2; 50) | "\($b)-\($i.host)-\(.)"] | map(select(. as $k | ($st.used | index($k)) == null)) | first)) as $id
      | ($byPath["\($i.host)\t\($i.path)"].comment // "") as $cm
      | .used += [$id]
      | .out[$id] = {host: $i.host, path: $i.path, worktreeId: $i.worktreeId, lane: $i.owner, state: ($cm | cstate),
          standing: (if ($i.ownerSource | IN("lead", "self")) then true elif ($i.ownerSource | startswith("comment:")) then false else null end),
          agent: null, beadsEpic: null, parent: null, adopted: true, lastComment: (($cm | segs | first // "") | .[0:200]), rebuiltAt: $now})
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
  # never older than the record it was built from, or a clock behind GitHub would call it stale again
  | {schema: "concertmaster.ledger/v1", createdAt: $now, updatedAt: ([$now, ($lanes[].recordedAt | strings)] | max), rebuiltAt: $now,
     hosts: $hosts, lanes: $lanesOut, workers: $workers}' > "$TMP/doc.json" || die "could not build the rebuilt ledger"

MERGE='$d[0] as $d
  | .lanes = (reduce ($d.lanes | to_entries[]) as $e ((.lanes // {}); .[$e.key] = ((.[$e.key] // {}) + ($e.value | with_entries(select(.value != null))))))
  | .hosts = ($d.hosts + (.hosts // {}))
  | ([(.workers // {})[] | objects | select((.state // "") | IN("gone", "repurposed") | not) | "\(.host)\t\((.path // "") | sub("/+$"; ""))"]) as $known
  | .workers = (reduce ($d.workers | to_entries[]) as $e ((.workers // {});
      if ($known | index("\($e.value.host)\t\($e.value.path | sub("/+$"; ""))")) != null then . else .[$e.key] = $e.value end))
  | .updatedAt = $d.updatedAt | .rebuiltAt = $d.rebuiltAt'
summary="$(jq -r '"\(.lanes | length) lanes, \(.hosts | length) hosts, \(.workers | length) workers"' "$TMP/doc.json")"
if [ "$APPLY" = 0 ]; then
  if [ "$MODE" = init ]; then jq . "$TMP/doc.json"; else jq --slurpfile d "$TMP/doc.json" "$MERGE" "$L"; fi
  say "dry run, $MODE: $summary rebuilt; nothing written (--apply writes it)"
  exit 0
fi
[ "$GHFAIL" = 0 ] || die "a lane issue could not be read (above): nothing written, run it again once gh answers"
if [ "$MODE" = init ]; then
  cm_ledger_write --init '$d[0]' --slurpfile d "$TMP/doc.json" || die "the ledger write was refused (reason above)"
else
  cm_ledger_write "$MERGE" --slurpfile d "$TMP/doc.json" || die "the ledger write was refused (reason above)"
fi
say "written, $MODE: $summary rebuilt into $L"
