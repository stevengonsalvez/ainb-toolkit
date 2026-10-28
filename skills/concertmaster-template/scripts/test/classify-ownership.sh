#!/usr/bin/env bash
# classify-ownership.sh: behaviour tests for classify's ownership accounting.
# Feeds a synthetic discover document, a ledger and a fixture config to
# classify.sh and checks each row's owner, ownerSource and ORPHAN / LEAD-DEAD
# flags. Touches nothing outside a mktemp dir.
#
#   scripts/test/classify-ownership.sh        # exit 0 when every case passes
#   OWNERSHIP_SAMPLE=<file> scripts/test/classify-ownership.sh   # also write the --table output
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-ownership.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT"
export CM_CONFIG="$HERE/fixtures/ownership/config.yaml"
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
# the config is YAML: lib.sh reads it with yq (mikefarah v4)
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
cfgjson() { yq -o=json -I=0 '.' "$1"; }

cat > "$ROOT/ledger.json" <<'J'
{"lanes": {"lane-a-ledger": {"lead": "w-dev"}, "only-in-ledger-lane": {"lead": "w-lo"}, "lane-b": {"lead": "w-ops"}},
 "workers": {
  "w-dev": {"host": "local", "path": "/w/lead-a", "standing": true},
  "w-lo": {"host": "local", "path": "/w/only-in-ledger-lead", "standing": true},
  "w-ops": {"host": "local", "path": "/w/lead-b", "standing": true},
  "w-solo": {"host": "local", "path": "/w/standing-solo", "standing": true},
  "w-idle": {"host": "local", "path": "/w/idle-orphan", "standing": false},
  "w-led": {"host": "local", "path": "/w/zz-ledger-owned", "standing": false, "lane": "ledger-lane"},
  "w-stale": {"host": "local", "path": "/w/odd-stale", "standing": false, "lane": "stale-ledger-lane"}}}
J
NOW=1791600000000; OLD=$((NOW - 600000))
row() { # row <name> <repo> <comment> <agents: live|none|done> <extra-json>
  jq -cn --arg n "$1" --arg repo "$2" --arg c "$3" --arg a "$4" --argjson x "${5:-{\}}" --argjson old "$OLD" '
    ({host: "local", path: ("/w/" + $n), displayName: $n, repo: $repo, status: "idle", comment: $c, source: "orca",
      worktreeId: null, isMainWorktree: false, childWorktreeIds: [], inOrca: true,
      liveTerminalCount: (if $a == "live" then 1 else 0 end),
      agents: (if $a == "live" then [{state: "working", paneKey: "p1", updatedAt: $old}]
               elif $a == "done" then [{state: "done", paneKey: "p1", updatedAt: $old}] else [] end),
      lastOutputAt: $old, lastActivityAt: $old,
      git: {exists: true, statusOk: true, dirty: 0, unpushed: 0}, pr: null}) + $x'
}
S=acme-app
{
  # leads: lead-a live, lists workers in three marker styles; lead-b session gone
  row lead-a $S "WORKERS I OWN (plain): odd-beta (PR 7), n9 (never), odd-stale (re-homed) | ORCHESTRATED (Orca): odd-eta (ctx_1) | MERGED today: late-theta" live
  row lead-b $S "OWNED (lead-b): [1] lead-b (this) [2] fixed-iota (#9 merged), after-merge-kappa; SWEEP DONE: torn down torn-zeta" none
  row concertmaster $S "" live
  row release-tester $S "cm:idle" live
  # owned by prefix
  row wa-alpha $S "cm:working" live
  # owned only by a lead's comment list (no prefix matches), incl. after a parenthesised "merged"
  row odd-beta $S "cm:working" live
  row odd-eta $S "cm:working" live
  row fixed-iota $S "cm:working" live
  row after-merge-kappa $S "cm:working" live
  # open work under the dead lead (prefix wb-)
  row only-in-ledger-lead $S "cm:idle" live
  row odd-stale $S "cm:working" live
  row self-lead $S "I OWN: x-claimed" live
  row x-claimed $S "" live
  row a-one $S "" live
  row a-two $S "" live
  row a-three $S "" live
  row wb-delta $S "cm:merge-ready #1" live
  row m-one $S "" live
  row m-two $S "" live
  row m-three $S "" live
  row m-four $S "" live
  row neg2 $S "" live
  row c-one $S "" live
  row c-two $S "" live
  row c-three $S "" live
  row c-five $S "" live
  row par-a $S "" live
  row par-b $S "" live
  row neg-a $S "" live
  row neg-b $S "" live
  row nxt-b $S "" live
  row nxt-c $S "" live
  row standing-solo $S "cm:idle" live
  row idle-orphan $S "" none
  row ghost-w $S "cm:working" live
  row wa-v2.x $S "" live
  row scratch-v2 $S "" none '{"path": "/tmp/agent-1000/-home-user-workspaces-acme-app-wa-v2-x/abc/scratchpad/scratch-v2", "source": "git", "inOrca": false}'
  row scratch-sub $S "" none '{"path": "/tmp/agent-1000/-home-user-workspaces-acme-app-Wa-Alpha-src/abc/scratchpad/scratch-sub", "source": "git", "inOrca": false}'
  # lists name after SWEEP DONE: not owned; "MERGED today" list is not a marker: not owned
  row torn-zeta $S "" live
  row late-theta $S "" live
  # ledger lane
  row zz-ledger-owned $S "" live
  # orphan: no lead lists it, no prefix covers it
  row zzz-gamma $S "cm:working" live
  row contest-x $S "" live
  row lead-aaa $S "OWNED: contest-x" live
  row prose-victim $S "" live
  # contested: two leads list it
  row shared-lambda $S "cm:working" live
  # git-only worktree inside a worker's scratch dir
  row scratch-wt $S "" none '{"path": "/tmp/agent-1000/-home-user-workspaces-acme-app-wa-alpha/abc/scratchpad/scratch-wt", "source": "git", "inOrca": false}'
  # a git-only worktree whose scratch parent is gone: orphan
  row lost-wt $S "" none '{"path": "/tmp/agent-1000/-home-user-workspaces-acme-app-vanished-worker/abc/scratchpad/lost-wt", "source": "git", "inOrca": false}'
  # never-touch: by repo and by worktree name, never owner, never flagged
  row other-x other-repo "" live
  row nx $S "" live
  # main checkout: no owner, no flag
  row acme-app $S "" none '{"isMainWorktree": true}'
} > "$ROOT/rows.ndjson"
# patch comments: a second lead lists shared-lambda; a list with "(cm: nudged)" inside a
# parenthesis; NOT OWNED, not-owned and no longer owned lists; a parenthesised name; a Next: header;
# a census line naming a worker inside a parenthesis
# the dead lead's comment, plus a second lead listing shared-lambda: patch comments
jq -c 'if .displayName == "lead-a" then .comment += " | OWNED: contest-x | OWNED: shared-lambda | WORKERS I OWN: a-one (cm: nudged, note: x), a-two | NOT OWNED: a-three (ask ops) | WORKERS I OWN: par-a (replaced par-b, torn down), nxt-b Next: nxt-c | not-owned: neg-a | no longer owned: neg-b | HOSTS READ: local: 31 (ghost-w merge-ready) | PR #90021 owned by prose-victim, next: x | cm:working WORKERS I OWN: m-one, m-two | sweeping, owned: m-three | cm: idle - orchestrated: m-four | ORCHESTRATED (not owned): neg2 | OWNED: c-one, c-two. Not c-three | owned by lead-aaa: c-five" elif .displayName == "lead-b" then .comment += " | OWNED: shared-lambda" else . end' "$ROOT/rows.ndjson" > "$ROOT/rows2.ndjson"

jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t", hosts: [{name: "local", reachable: true}], worktrees: .}' \
  "$ROOT/rows2.ndjson" > "$ROOT/discover.json"
OUT="$("$HERE/../classify.sh" < "$ROOT/discover.json" 2>"$ROOT/err")" || { echo "classify.sh failed"; cat "$ROOT/err"; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
# row_field <name> <jq expr over the row>
row_field() { printf '%s' "$OUT" | jq -r --arg n "$1" ".items[] | select(.name == \$n) | $2"; }
# eq <label> <got> <want> [detail]
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got \"$2\" ${4:-}"; fi; }
expect_owner() { # expect_owner <label> <name> <owner> <source-pattern>
  local got
  got="$(row_field "$2" '"\(.owner)\t\(.ownerSource)"')"
  if [ "${got%%	*}" = "$3" ] && printf '%s' "${got#*	}" | grep -Eq -- "$4"; then pass "$1"; else fail "$1" "got \"$got\""; fi
}
expect_flag() { # expect_flag <label> <name> <flag> <yes|no>
  local has
  has="$(row_field "$2" "(.flags | index(\"$3\")) != null")"
  if { [ "$4" = yes ] && [ "$has" = true ]; } || { [ "$4" = no ] && [ "$has" = false ]; }; then pass "$1"; else fail "$1" "flag $3 present=$has"; fi
}

expect_owner "owned by prefix (wa-)"                              wa-alpha lane-a '^prefix$'
expect_owner "owned by a lead's comment list (WORKERS I OWN)"        odd-beta lane-a '^comment:lead-a$'
expect_owner "owned via the ORCHESTRATED marker after a pipe"        odd-eta lane-a '^comment:lead-a$'
expect_owner "name after a parenthesised 'merged' still claimed"     after-merge-kappa lane-b '^comment:lead-b$'
expect_owner "name before it claimed too"                            fixed-iota lane-b '^comment:lead-b$'
expect_owner "ledger worker lane beats prefix and no-comment"        zz-ledger-owned ledger-lane '^ledger$'
expect_owner "a lead's fresher comment wins over a stale ledger lane" odd-stale lane-a '^comment:lead-a$'
expect_owner "a lead that exists only in the ledger owns itself"     only-in-ledger-lead only-in-ledger-lane '^lead$'
expect_owner "stop word inside parentheses does not cut the list"   a-one lane-a '^comment:lead-a$'
expect_owner "name after '(cm: nudged, note: x),' still claimed"     a-two lane-a '^comment:lead-a$'
expect_flag  "mid-sentence prose (PR owned by x) is not a header: orphan" prose-victim ORPHAN yes
expect_owner "marker after a cm:<state> prefix is a header"          m-one lane-a '^comment:lead-a$'
expect_owner "marker after a comma (weak boundary, followed by a colon)" m-three lane-a '^comment:lead-a$'
expect_owner "marker after ' - ' (weak boundary)"                    m-four lane-a '^comment:lead-a$'
expect_flag  "ORCHESTRATED (not owned): is a negation: orphan"        neg2 ORPHAN yes
expect_owner "a list ends at the end of the sentence (OWNED: a, b.)"  c-two lane-a '^comment:lead-a$'
expect_flag  "a name after the sentence end is not claimed: orphan"   c-three ORPHAN yes
expect_flag  "'owned by <lane lead>:' is not a header: orphan"       c-five ORPHAN yes
expect_flag  "NOT OWNED list is a negation: orphan"                  a-three ORPHAN yes
expect_flag  "not-owned: is a negation: orphan"                       neg-a ORPHAN yes
expect_flag  "no longer owned: is a negation: orphan"                 neg-b ORPHAN yes
expect_owner "name before a parenthesis claimed"                     par-a lane-a '^comment:lead-a$'
expect_flag  "a name inside a parenthesis is not claimed: orphan"    par-b ORPHAN yes
expect_owner "name before a Next: header claimed"                    nxt-b lane-a '^comment:lead-a$'
expect_flag  "a name after a Next: header is not claimed: orphan"    nxt-c ORPHAN yes
expect_owner "a census line (local: 31 (ghost-w ...)) claims nothing: ghost-w by prefix" ghost-w lane-g '^prefix$'
expect_owner "ledger-standing worktree with no other owner owns itself" standing-solo standing-solo '^standing$'
expect_owner "scratch parent with a dot in its name (encoded to -)"  scratch-v2 lane-a '^scratch-of:wa-v2.x$'
expect_owner "scratch dir started in a subdirectory, other case"      scratch-sub lane-a '^scratch-of:wa-alpha$'
expect_flag  "a worktree cannot promote itself to lead by 'I OWN:'"  x-claimed ORPHAN yes
expect_owner "self-declared lead gets no lead ownership"             self-lead null '^none$'
expect_owner "lead row owns itself (config lead)"                    lead-a lane-a '^lead$'
expect_owner "concertmaster worktree owns itself"                    concertmaster concertmaster '^self$'
expect_owner "release-tester lane in the prefix map and lead map"    release-tester release-tester '^(lead|prefix)$'
expect_owner "git-only worktree in a worker scratch dir inherits"    scratch-wt lane-a '^scratch-of:wa-alpha$'
expect_flag  "orphan: no lead lists it, no prefix covers it"         zzz-gamma ORPHAN yes
expect_flag  "orphan: scratch parent is gone"                        lost-wt ORPHAN yes
expect_flag  "name after 'SWEEP DONE:' is not claimed: orphan"       torn-zeta ORPHAN yes
expect_flag  "name after 'MERGED today:' is not a marker list: orphan" late-theta ORPHAN yes
expect_flag  "owned rows are not orphans"                            odd-beta ORPHAN no
expect_owner "contested tie-break sorts by lane label, not lead name (lead-aaa < lead-a but lane-zzz > lane-a)" contest-x lane-a '^comment:'
expect_flag  "two leads list it: contested"                          shared-lambda owner-contested:lane-a,lane-b yes
expect_flag  "never_touch name (n9 listed by a lead) is not claimed, not flagged" nx ORPHAN no
eq "never_touch repo row has no owner" "$(row_field other-x '.owner')" null
eq "never_touch name row has no owner" "$(row_field nx '.owner')" null
expect_flag  "main checkout: not flagged"                            acme-app ORPHAN no
eq "main checkout is labelled, never owned" "$(row_field acme-app '.ownerSource')" main-checkout
# ORPHAN suggest: teardown hint only for an idle, non-standing class, never for running
got="$(row_field idle-orphan '"\(.class)|\(.suggest)"')"
case "$got" in idle\|*"tear down per the teardown gates (SKILL.md § Ownership)"*) pass "idle non-standing orphan: teardown hint, cites § Ownership" ;; *) fail "idle orphan hint" "$got" ;; esac
got="$(row_field zzz-gamma '.suggest')"
case "$got" in *"never teardown on this class"*) pass "running orphan: never teardown" ;; *) fail "running orphan hint" "$got" ;; esac
# LEAD-DEAD: lead-b has no live session and owns open work (wb-delta, fixed-iota, ...)
expect_flag  "dead lead (no agent, no terminal) owning open work: LEAD-DEAD" lead-b LEAD-DEAD yes
expect_flag  "live lead is not LEAD-DEAD"                            lead-a LEAD-DEAD no
got="$(printf '%s' "$OUT" | jq -r '.ownership.leadDead[] | select(.lead == "lead-b") | "\(.lane)|\(.reason)|\(.open | index("wb-delta") != null)"')"
eq "leadDead entry names the lane, reason and open work" "$got" "lane-b|lead session gone|true"
got="$(row_field lead-b '"\(.class)|\(.suggest)"')"
n="$(printf '%s' "$got" | grep -o 'respawn in place' | wc -l | tr -d ' ')"
case "$got" in standing-dead\|*) eq "standing-dead lead keeps ONE respawn suggest (no duplicate from LEAD-DEAD)" "$n" 1 ;; *) fail "lead-b class" "$got" ;; esac
# a lead named in config but absent from a fully reachable census, owning open work
got="$(printf '%s' "$OUT" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-g")] | length')"
eq "ghost lead with nothing owned is not LEAD-DEAD" "$got" 0
# the summary
got="$(printf '%s' "$OUT" | jq -r '"\(.ownership.configured) orphans=\(.ownership.orphans)"')"
eq "summary counts the 16 orphans" "$got" "true orphans=16"

# --- lead with no worktree: only a ledger-recorded lead on a host that answered in full ---
jq -c 'select(.displayName != "lead-b")' "$ROOT/rows2.ndjson" \
  | jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t", hosts: [{name: "local", reachable: true}], worktrees: .}' > "$ROOT/d2.json"
OUT2="$("$HERE/../classify.sh" < "$ROOT/d2.json" 2>/dev/null)"
got="$(printf '%s' "$OUT2" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-b") | .reason] | first // "none"')"
eq "ledger lead missing, its host answered in full: LEAD-DEAD" "$got" "lead worktree not in the census (ledger lead, its host answered in full)"
got="$(printf '%s' "$OUT2" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-g")] | length')"
eq "config-only lead with no worktree and a prefixed worker is NOT dead (spawn-at-2)" "$got" 0
jq -c '.hosts[0].truncated = true' "$ROOT/d2.json" > "$ROOT/d3.json"
OUT3="$("$HERE/../classify.sh" < "$ROOT/d3.json" 2>"$ROOT/err3")"
got="$(printf '%s' "$OUT3" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-b")] | length')"
eq "lead missing but its host answer was truncated: never called dead" "$got" 0 "$(tail -2 "$ROOT/err3")"
jq -c '.hosts[0].reachable = false | .hosts[0].error = "timeout"' "$ROOT/d2.json" > "$ROOT/d3b.json"
OUT3B="$("$HERE/../classify.sh" < "$ROOT/d3b.json" 2>/dev/null)"
got="$(printf '%s' "$OUT3B" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-b")] | length')"
eq "lead missing but its host is offline: never called dead" "$got" 0
# open work excludes rows whose PR is merged: a dead lead with only merged work is not LEAD-DEAD
jq -c 'if (.displayName | IN("wb-delta", "fixed-iota", "after-merge-kappa")) then .pr = {number: 9, state: "MERGED"} else . end' "$ROOT/rows2.ndjson" \
  | jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t", hosts: [{name: "local", reachable: true}], worktrees: .}' > "$ROOT/d5.json"
OUT5="$("$HERE/../classify.sh" < "$ROOT/d5.json" 2>/dev/null)"
got="$(printf '%s' "$OUT5" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-b")] | length')"
eq "dead lead whose owned PRs are all merged is not LEAD-DEAD" "$got" 0

# --- two leads on one lane label: open work is counted per lead ---
jq -c '.' "$ROOT/rows2.ndjson" > "$ROOT/rows6.ndjson"
row lead-b2 $S "cm:idle" live >> "$ROOT/rows6.ndjson"
tod6() { jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t", hosts: [{name: "local", reachable: true}], worktrees: .}'; }
# A: the dead lead claimed nothing itself; its prefix-owned work belongs to the live sibling
jq -c 'if .displayName == "lead-b" then .comment = "" else . end' "$ROOT/rows6.ndjson" | tod6 > "$ROOT/d6a.json"
OUT6="$("$HERE/../classify.sh" < "$ROOT/d6a.json" 2>/dev/null)"
got="$(printf '%s' "$OUT6" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-b")] | length')"
eq "dead lead sharing a lane label with a LIVE lead does not inherit the label's prefix-owned work" "$got" 0
got="$(printf '%s' "$OUT6" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-b2")] | length')"
eq "the live sibling lead is not LEAD-DEAD" "$got" 0
# B: the dead lead's OWN comment claims still count (and only those, not the label's prefix work)
tod6 < "$ROOT/rows6.ndjson" > "$ROOT/d6b.json"
OUT6B="$("$HERE/../classify.sh" < "$ROOT/d6b.json" 2>/dev/null)"
got="$(printf '%s' "$OUT6B" | jq -r '[.ownership.leadDead[] | select(.lead == "lead-b") | .open | ((index("fixed-iota") != null) and (index("wb-delta") == null))] | first // "none"')"
eq "dead lead keeps the work its own comment claimed, not the live sibling's label work" "$got" true
# null and empty paths do not crash classify (one odd remote row must not blind the tick)
{ jq -c '.' "$ROOT/rows2.ndjson"; row nullpath $S "" live '{"path": null}'; row emptypath $S "" live '{"path": ""}'; } \
  | jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t", hosts: [{name: "local", reachable: true}], worktrees: .}' > "$ROOT/d7.json"
OUT7="$("$HERE/../classify.sh" < "$ROOT/d7.json" 2>"$ROOT/err7")" || OUT7=""
eq "null and empty worktree paths do not crash classify" "$(printf '%s' "$OUT7" | jq -r '.ownership.configured // "crashed"')" true "$(tail -1 "$ROOT/err7")"
# ownership off is surfaced as an error string, not a silent false
o="$(CM_CONFIG="$ROOT/nope.yaml" "$HERE/../classify.sh" < "$ROOT/discover.json" 2>/dev/null)"
eq "ownership off carries an error string for the tick alert" "$(printf '%s' "$o" | jq -r '.ownership.error | test("not readable")')" true
case "$("$HERE/../classify.sh" --table < "$ROOT/discover.json" 2>/dev/null | grep -m1 '^ownership:')" in
  "ownership: orphans="*) pass "--table: ownership line when configured" ;; *) fail "--table ownership line" "" ;; esac
case "$(CM_CONFIG="$ROOT/nope.yaml" "$HERE/../classify.sh" --table < "$ROOT/discover.json" 2>/dev/null | grep -m1 '^ownership:')" in
  "ownership: NOT CONFIGURED, ownership is off: "*) pass "--table: NOT CONFIGURED alert line when off" ;; *) fail "--table not-configured line" "" ;; esac

# --- malformed or unusable config: ownership skipped, classify still runs ---
badcfg() { # badcfg <label> <jq edit on the config JSON>
  cfgjson "$CM_CONFIG" | jq "$2" > "$ROOT/bad.json"
  yq -P '.' "$ROOT/bad.json" > "$ROOT/bad.yaml" 2>/dev/null || cp "$ROOT/bad.json" "$ROOT/bad.yaml"
  local o
  o="$(CM_CONFIG="$ROOT/bad.yaml" "$HERE/../classify.sh" < "$ROOT/discover.json" 2>"$ROOT/errbad")" || { fail "$1" "classify exited non-zero: $(tail -1 "$ROOT/errbad")"; return; }
  eq "$1" "$(printf '%s' "$o" | jq -r '.ownership.configured')" false "$(tail -1 "$ROOT/errbad")"
}
badcfg "list-typed leads: ownership skipped, no crash"            '.ownership.leads = ["lead-a"]'
badcfg "empty comment_markers: ownership skipped, no claim-all"   '.ownership.comment_markers = []'
badcfg "a marker that is an empty string: skipped"                '.ownership.comment_markers = [""]'
badcfg "null prefix value: skipped"                               '.ownership.prefixes["wa-"] = null'
badcfg "non-string never_touch entry: skipped"                    '.worktrees.never_touch = [true]'
o="$(CM_CONFIG="$ROOT/nope.yaml" "$HERE/../classify.sh" < "$ROOT/discover.json" 2>/dev/null)"
eq "CM_CONFIG set but unreadable: ownership skipped, no silent fallback" "$(printf '%s' "$o" | jq -r '.ownership.configured')" false
# a bad scratch regex is dropped, ownership stays on
cfgjson "$CM_CONFIG" | jq '.ownership.scratch_path_regex = "([unclosed"' > "$ROOT/sr.yaml"
o="$(CM_CONFIG="$ROOT/sr.yaml" "$HERE/../classify.sh" < "$ROOT/discover.json" 2>/dev/null)" || o=""
eq "an invalid scratch_path_regex is dropped, ownership stays on" "$(printf '%s' "$o" | jq -r '.ownership.configured // "crashed"')" true

# --- a census line naming hosts must not claim a worker; prefixes hold ---
{
  row lead-pr $S "HOSTS READ: local: 31, host-a: 9 (wa-ppv-a merge-ready) | not-owned: wa-ppv-b" live
  row wa-ppv-a $S "" live
  row wa-ppv-b $S "" live
} | jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t", hosts: [{name: "local", reachable: true}], worktrees: .}' > "$ROOT/dcensus.json"
OUTR="$("$HERE/../classify.sh" < "$ROOT/dcensus.json" 2>/dev/null)"
got="$(printf '%s' "$OUTR" | jq -r '[.items[] | select(.name | startswith("wa-ppv")) | "\(.owner)/\(.ownerSource)"] | unique | join(",")')"
eq "census line (host names, a parenthesised worker) claims nothing: workers stay with their prefix lane" "$got" "lane-a/prefix"

# --- no config: ownership skipped, nothing guessed ---
OUT4="$(CM_CONFIG="$ROOT/nope.yaml" "$HERE/../classify.sh" < "$ROOT/discover.json" 2>/dev/null)"
got="$(printf '%s' "$OUT4" | jq -r '"\(.ownership.configured) \([.items[] | select(.flags | index("ORPHAN"))] | length)"')"
eq "no config: ownership skipped, no ORPHAN guessed" "$got" "false 0"

# --- table output carries the owner column and the flags ---
TABLE="$("$HERE/../classify.sh" --table < "$ROOT/discover.json" 2>/dev/null)"
if printf '%s' "$TABLE" | grep -q '^ownership: orphans=16 lead-dead=1'; then pass "--table prints the ownership line"; else fail "--table prints the ownership line" ""; fi
if printf '%s' "$TABLE" | grep -E 'zzz-gamma' | grep -q 'ORPHAN'; then pass "--table shows the ORPHAN flag on the row"; else fail "--table shows the ORPHAN flag on the row" ""; fi

if [ -n "${OWNERSHIP_SAMPLE:-}" ]; then printf '%s\n' "$TABLE" > "$OWNERSHIP_SAMPLE"; fi
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
