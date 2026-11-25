#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# stall.sh (test): the drive ladder check, hermetic. Fixture classify, discover, asks and ledger files in a mktemp dir,
# the clock injected with CM_NOW, and orca, plugly and gh stubs first on PATH (and as the CLI commands) that log
# every call and fail loudly: stall.sh reads files only, so the log must stay empty. Covers each rung boundary
# (29, 30, 59, 60, 89, 90 min), a rung reached only after the one below was acted, the ladder never skipping (a
# verdict recorded first counts as rung 1), the PR head sha first-seen reset, every exempt class, unverified hosts
# never stalled, NO-ACTION exit 4 against acted exit 0, stale or missing input exit 3, usage exit 2, the --act enum
# and the secret refusal, the verdict decisions[] record, resume.lock held suppressing rung 2, and no CLI call. Section 13
# holds one case per review finding: owner-only ask kinds and held items exempt, a secrets ask never laddered (any
# project, any wording), an own-scope ask the deny scan stops kept Blocked, asks hosts not read unverified, comment
# times not progress, a below-rung action not clearing NO-ACTION, the added secret shapes (built at run time from split
# strings), actions matched by host, a granted queue entry not idle.
#
#   scripts/test/stall.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../stall.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-stall-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_ORG CM_REPO CM_PROJECT CM_PROJECT_ID CM_NEVER_TOUCH CM_TZ CM_TZ_LABEL CM_OWNER_NAME

# CLI stubs: any call is logged and fails
mkdir -p "$ROOT/bin" "$ROOT/hm"
CALLS="$ROOT/cli-calls.log"; : > "$CALLS"
for t in orca plugly gh ssh; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\necho "stall test: %s must never be called" >&2\nexit 99\n' "$t" "$CALLS" "$t" > "$ROOT/bin/$t"
  chmod +x "$ROOT/bin/$t"
done
export HOME="$ROOT/hm" PATH="$ROOT/bin:$PATH"
export ORCA_CLI_COMMAND="$ROOT/bin/orca" PLUGLY_CLI_COMMAND="$ROOT/bin/plugly"

# config: the hermetic fixture plus the keys stall.sh reads
sed -e 's/^  timezone_label: UTC$/&\n  tick_delays_s: { busy: 600, running: 1200, quiet: 1800 }\n  stall_rungs_min: [30, 60, 90]/' \
    -e 's/^  self_name: concertmaster$/&\n  never_touch: [nt-lane]/' \
    "$HERE/fixtures/config.test.yaml" > "$ROOT/config.yaml"
printf 'messaging:\n  collaborators:\n    - { name: Peer One, github: peer-1 }\n' >> "$ROOT/config.yaml"
# the delegated release and deploy classes: none by default, so the fixture lists the usual ones
cat >> "$ROOT/config.yaml" <<'EOF2'
drive:
  delegated_classes:
    - 'native (release|build|app release)'
    - 'store submission'
    - 'store build'
    - 'app ?listing'
    - 'play ?listing'
    - 'listing console'
    - 'ota (release|bundle|update)'
    - 'over[ -]?the[ -]?air'
    - '(daily |production )?deploy window'
    - 'feature switch[ -]?on( (of|for) (the )?(chat widget|beta banner))?'
    - '(turn(ed|ing)?|switch(ed|ing)?) on (the )?(chat widget|beta banner)'
    - '(chat widget|beta banner) (flag|global flip)'
    - 'beta go[ .-]?live'
EOF2
export CM_CONFIG="$ROOT/config.yaml"

PASS=0; FAIL=0
# rep <text> <n>: the text n times, and GHP the prefix of a hosted-git token: no token-shaped run sits in this file
rep() { local o="" i; for ((i = 0; i < $2; i++)); do o+="$1"; done; printf '%s' "$o"; }
GHP="gh""p_"
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi
}
has() { case "$2" in *"$3"*) PASS=$((PASS + 1)); printf 'PASS %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s: "%s" not in:\n%s\n' "$1" "$3" "$2" ;; esac; }

T0="2026-11-16T12:00:00Z"
ago() { jq -nr --arg t "$T0" --argjson m "$1" '$t | fromdateiso8601 - ($m * 60) | todate'; }
export CM_NOW="$T0"
SINCE="$(ago 2)"

# item <name> <class> <idle|null> [host] [ownerSource] [pr json] [owner]
item() {
  jq -nc --arg n "$1" --arg c "$2" --argjson i "$3" --arg h "${4:-local}" --arg os "${5:-prefix}" --argjson pr "${6:-null}" --arg o "${7:-dev-sweeper}" \
    '{host: $h, class: $c, path: ("/w/wt/" + $n), repo: "repo", branch: ("b-" + $n), worktreeId: ("id-" + $n),
      inOrca: true, idleMinutes: $i, pr: $pr, flags: [], reason: "r", suggest: "s", name: $n, owner: $o, ownerSource: $os}'
}
# pr <number> <sha> <updated min ago> [repo|null] [author] [labels json]
pr() {
  jq -nc --argjson n "$1" --arg s "$2" --arg u "$(ago "$3")" --argjson r "${4:-null}" --arg a "${5:-author-1}" --argjson l "${6:-[]}" \
    '{number: $n, title: "t\($n)", isDraft: false, createdAt: $u, updatedAt: $u, url: "u", headRefName: "b\($n)", headRefOid: $s, author: $a, repo: $r, labels: $l}'
}
arr() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -sc .; fi; }

# gen <dir>: writes the four input files from ITEMS PRS WTS ASKS UNREACH HREAD HOSTS LED DEAD ERRS GEN
gen() {
  local d="$1"; mkdir -p "$d"
  jq -n --arg g "${GEN:-$T0}" --argjson items "${ITEMS:-[]}" --argjson dead "${DEAD:-[]}" \
    '{schema: "concertmaster.classify/v1", generatedAt: $g, items: $items, ownership: {configured: true, leadDead: $dead}}' > "$d/cls.json"
  local hosts="${HOSTS:-}"; [ -n "$hosts" ] || hosts='[{"name":"local","reachable":true,"truncated":false}]'
  jq -n --arg g "${GEN:-$T0}" --argjson h "$hosts" \
    --argjson w "${WTS:-[]}" --argjson p "${PRS:-[]}" --argjson e "${ERRS:-[]}" \
    '{schema: "concertmaster.discover/v1", generatedAt: $g, mainRepo: "org/repo", hosts: $h, worktrees: $w, prs: {open: $p}, errors: $e}' > "$d/disc.json"
  jq -n --arg g "${GEN:-$T0}" --argjson a "${ASKS:-[]}" --argjson u "${UNREACH:-[]}" --argjson hr "${HREAD:-[\"local\"]}" \
    '{generatedAt: $g, hostsRead: $hr, unreachable: $u, count: ($a | length), asks: $a}' > "$d/asks.json"
  if [ -n "${LED:-}" ]; then printf '%s\n' "$LED" > "$d/led.json"; else printf '{"workers":{}}\n' > "$d/led.json"; fi
}
# run <dir> [args]: sets OUT and RC
run() {
  local d="$1"; shift
  OUT="$(CM_HOME="$d/cm" bash "$SCRIPT" --classify "$d/cls.json" --discover "$d/disc.json" --asks "$d/asks.json" --ledger "$d/led.json" --since "$SINCE" "$@" 2>"$d/err")"; RC=$?
}
runj() { run "$@" --json; }
field() { jq -r --arg n "$1" --arg f "$2" '[.rows[] | select(.name == $n) | .[$f]] | if length == 0 then "absent" else (.[0] | tostring) end' <<<"$OUT"; }
exr() { jq -r --arg n "$1" '[.exempt[] | select(.name == $n) | .code] | if length == 0 then "absent" else .[0] end' <<<"$OUT"; }
act() { # act <dir> <at> <kind> <name> <verb> <text> [--host H] [--path P]
  local d="$1" at="$2"; shift 2
  CM_HOME="$d/cm" CM_NOW="$at" bash "$SCRIPT" --act "$1" "$2" "$3" "$4" --ledger "$d/led.json" "${@:5}" >/dev/null 2>"$d/act.err"
}
reset() { ITEMS='[]'; PRS='[]'; WTS='[]'; ASKS='[]'; UNREACH='[]'; HREAD='["local"]'; HOSTS=''; LED=''; DEAD='[]'; ERRS='[]'; GEN="$T0"; }
f22base() { reset; W="$ROOT/f22"; rm -rf -- "${W:?}"; ITEMS="$(arr "$(item la idle 95)")"; }
f22chk() { # f22chk <label> <gap text>: exit 3, la unverified (never laddered, never exempt as held), the gap names the field
  gen "$W"; runj "$W"
  check "F22 $1: exit 3" "$RC" "3"
  check "F22 $1: la is unverified, never laddered and never held" "$(exr la)$(field la rung)" "unverifiedabsent"
  has "F22 $1: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "$2"
}

# ---- 1. rung boundaries, no action yet ----------------------------------------------------------------------------
reset; W="$ROOT/c1"
ITEMS="$(arr "$(item l29 idle 29)" "$(item l30 idle 30)" "$(item l59 idle 59)" "$(item l60 idle 60)" "$(item l89 idle 89)" "$(item l90 idle 90)")"
gen "$W"; runj "$W"
check "29 min: not stalled (no row)" "$(field l29 rung)" "absent"
check "30 min: rung 1" "$(field l30 rung)" "1"
check "30 min: due a nudge" "$(field l30 action)" "nudge"
check "59 min: age rung 1" "$(field l59 ageRung)" "1"
check "60 min: age rung 2" "$(field l60 ageRung)" "2"
check "89 min: age rung 2" "$(field l89 ageRung)" "2"
check "90 min: age rung 3" "$(field l90 ageRung)" "3"
check "60 min, nothing acted: the ladder starts at rung 1" "$(field l60 rung)" "1"
check "90 min, nothing acted: the ladder starts at rung 1" "$(field l90 rung)" "1"
check "29 min is still checked" "$(jq -r '.checked' <<<"$OUT")" "6"
check "due rows with no action this tick: exit 4" "$RC" "4"
check "--json noAction is true" "$(jq -r '.noAction' <<<"$OUT")" "true"
check "--json has rows, exempt, unverified, noAction" "$(jq -r '[has("rows"), has("exempt"), has("unverified"), has("noAction")] | all' <<<"$OUT")" "true"
run "$W"
check "table: exit 4" "$RC" "4"
has "table: the header" "$(head -n 1 <<<"$OUT")" "KIND"
has "table: header columns" "$(head -n 1 <<<"$OUT" | tr -s ' ')" "KIND NAME HOST AGE RUNG DUE ACTED"
has "table: a summary line" "$OUT" "stall: 5 stalled (5 due, 0 acted this tick)"
has "table: the NO-ACTION line" "$OUT" "NO-ACTION 5 due row(s)"

# ---- 2. the ladder climbs one acted rung at a time ----------------------------------------------------------------
# progress at T0-60 for l60 and T0-90 for l90; actions inside the episode, in earlier ticks
act "$W" "$(ago 29)" lane l60 nudge "nudged: run the failing test"; check "--act nudge records: exit 0" "$?" "0"
act "$W" "$(ago 59)" lane l90 nudge "nudged: next step is the migration test"
act "$W" "$(ago 29)" lane l90 restart "restarted through resume.sh"
act "$W" "$(ago 10)" lane l30 nudge "nudged in the last tick"
runj "$W"
check "60 min after a nudge: rung 2" "$(field l60 rung)" "2"
check "rung 2 offers restart or re-place" "$(field l60 action)" "restart|replace"
check "90 min after nudge and restart: rung 3" "$(field l90 rung)" "3"
check "rung 3 offers a verdict" "$(field l90 action)" "verdict"
check "30 min, nudged last tick: acted, not due" "$(field l30 action)" "acted"
check "30 min, nudged last tick: not a NO-ACTION row" "$(field l30 noAction)" "false"
check "the last action is shown" "$(jq -r '.rows[] | select(.name == "l90") | .acted.verb' <<<"$OUT")" "restart"
# an action from before the row's last progress is another episode: it does not count
act "$W" "$(ago 70)" lane l59 nudge "an old episode"
runj "$W"
check "an action before the last progress does not lift the rung" "$(field l59 rung)" "1"

# ---- 3. the ladder never skips --------------------------------------------------------------------------------------
reset; W="$ROOT/c3"
ITEMS="$(arr "$(item skip idle 95)")"
gen "$W"; runj "$W"
check "95 min, no action: rung 1, not 3" "$(field skip rung)" "1"
act "$W" "$(ago 20)" lane skip verdict "reviewer one: unblock; reviewer two: unblock; action: rebased"
runj "$W"
check "a verdict recorded first counts as rung 1: next is rung 2" "$(field skip rung)" "2"
check "the decision went to ledger decisions[]" "$(jq -r '.decisions | length' "$W/led.json")" "1"
check "the decision names its subject" "$(jq -r '.decisions[0].subject | "\(.kind) \(.name)"' "$W/led.json")" "lane skip"
check "the decision says stall.sh wrote it" "$(jq -r '.decisions[0].source' "$W/led.json")" "stall.sh"

# ---- 4. NO-ACTION against acted -------------------------------------------------------------------------------------
reset; W="$ROOT/c4"
ITEMS="$(arr "$(item due1 idle 40)")"
gen "$W"; run "$W"
check "one due row, no action: exit 4" "$RC" "4"
has "NO-ACTION names the row" "$OUT" "lane due1 (rung 1, nudge)"
act "$W" "$(ago 1)" lane due1 nudge "nudged with the exact next action"
run "$W"
check "the row acted this tick: exit 0" "$RC" "0"
has "the acted mark" "$OUT" "nudge@11:59Z*"
# rung 2 due, only a rung-1 action from an earlier tick: NO-ACTION again
reset; W="$ROOT/c4b"
ITEMS="$(arr "$(item due2 idle 70)")"
gen "$W"; act "$W" "$(ago 35)" lane due2 nudge "nudged last tick"
run "$W"
check "rung 2 due, rung 1 acted in an older tick: exit 4" "$RC" "4"
act "$W" "$(ago 1)" lane due2 nudge "nudged again"
run "$W"
check "rung 2 due, only a rung-1 action this tick: still NO-ACTION, exit 4" "$RC" "4"
act "$W" "$(ago 1)" lane due2 restart "restarted through resume.sh"
run "$W"
check "rung 2 due, a rung-2 action this tick clears NO-ACTION: exit 0" "$RC" "0"
reset; W="$ROOT/c4c"; ITEMS="$(arr "$(item fresh idle 5)")"; gen "$W"; run "$W"
check "nothing stalled: exit 0" "$RC" "0"
has "nothing stalled: summary" "$OUT" "stall: 0 stalled"

# ---- 5. PR head sha first seen ------------------------------------------------------------------------------------
reset; W="$ROOT/c5"
PRS="$(arr "$(pr 7 aaaa111 180)")"
gen "$W"; runj "$W"
check "PR first seen: starts at updatedAt (180 min old), stalled" "$(field '#7' ageMinutes)" "180"
check "the first-seen file holds the sha" "$(jq -r '.prs["repo#7"].sha' "$W/cm/stall-seen.json")" "aaaa111"
CM_NOW="$(jq -nr --arg t "$T0" '$t | fromdateiso8601 + 600 | todate')" runj "$W"
check "same sha 10 min later: older" "$(field '#7' ageMinutes)" "190"
PRS="$(arr "$(pr 7 bbbb222 180)")"; gen "$W"; runj "$W"
check "new sha: the clock resets (no row)" "$(field '#7' rung)" "absent"
check "new sha: first seen is now" "$(jq -r '.prs["repo#7"].firstSeen' "$W/cm/stall-seen.json")" "$T0"
PRS="$(arr "$(pr 8 cccc333 5)")"; gen "$W"; runj "$W"
check "a closed PR leaves the first-seen file" "$(jq -r '.prs | keys | join(",")' "$W/cm/stall-seen.json")" "repo#8"
# a lane with an old idle but a fresh PR head is not stalled
reset; W="$ROOT/c5b"
mkdir -p "$W/cm"; printf '{"prs":{"repo#9":{"sha":"dddd","firstSeen":"%s"}}}\n' "$(ago 5)" > "$W/cm/stall-seen.json"
PRS="$(arr "$(pr 9 dddd 200)")"
ITEMS="$(arr "$(item withpr idle 120 local prefix '{"number":9,"state":"OPEN","author":"author-1"}')")"
gen "$W"; runj "$W"
check "lane: a PR head 5 min old is progress" "$(field withpr rung)" "absent"
check "PR: the head first seen 5 min ago wins over updatedAt" "$(field '#9' rung)" "absent"

# ---- 6. comment times ----------------------------------------------------------------------------------------------
reset; W="$ROOT/c6"
ITEMS="$(arr "$(item ctime idle 120)" "$(item cfuture idle 120)")"
WTS="$(jq -nc --arg a "cm:running tests green at $(ago 10)" --arg b "cm:keep until 2026-11-20T00:00Z" \
  '[{host: "local", path: "/w/wt/ctime", comment: $a}, {host: "local", path: "/w/wt/cfuture", comment: $b}]')"
gen "$W"; runj "$W"
check "a time written in a comment is not progress (no comment-changed time in discover)" "$(field ctime ageMinutes)" "120"
check "a future time in a comment is not progress either" "$(field cfuture ageMinutes)" "120"

# ---- 7. exempt classes ---------------------------------------------------------------------------------------------
reset; W="$ROOT/c7"
ITEMS="$(arr \
  "$(item off host-offline null h-off)" \
  "$(item cut idle 200 h-cut)" \
  "$(item askbad idle 200 h-askbad)" \
  "$(item nosig idle null)" \
  "$(item mainco main-checkout 200)" \
  "$(item otherp other-project 200)" \
  "$(item merged done-merged 200)" \
  "$(item selfrep done-selfreported 200)" \
  "$(item nt-lane idle 200)" \
  "$(item concertmaster running 200 local self)" \
  "$(item sleepy idle 200)" \
  "$(item quiet standing-idle 200 local standing null quiet-lane)" \
  "$(item busyq standing-idle 200 local standing null busy-lane)" \
  "$(item parked1 idle 200)" \
  "$(item owner1 idle 200)" \
  "$(item waits idle 200)" \
  "$(item asked idle 200)" \
  "$(item ledasked idle 200)" \
  "$(item kid idle 200 local comment:lead-a)" \
  "$(item orphankid idle 200 local comment:lead-b)" \
  "$(item plain stuck 200)" \
  "$(item wlane idle 5 local prefix '{"number":21,"state":"OPEN","author":"author-1"}')")"
HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"h-off","reachable":false},{"name":"h-cut","reachable":true,"truncated":true},{"name":"h-askbad","reachable":true,"truncated":false}]'
UNREACH='[{"host":"h-askbad","error":"timeout"}]'
DEAD='[{"lane":"lane-b","lead":"lead-b","open":["orphankid"]}]'
WTS="$(jq -nc '[{host: "local", path: "/w/wt/waits", comment: "cm:running\ncm:waiting-owner approve the copy"},
                {host: "local", path: "/w/wt/wlane", comment: "cm:waiting-owner on the PR"}]')"
ASKS="$(jq -nc --arg f "$(ago 50)" '[{host: "local", worktree: "asked", path: "/w/wt/asked", tag: "cm:ask", text: "which table?", firstSeen: $f, runs: 3},
  {host: "local", worktree: "plain2", path: "/w/wt/plain2", tag: "cm:waiting-owner", text: "needs the owner", firstSeen: $f, runs: 3}]')"
LED="$(jq -nc --arg f "$(ago 50)" '{workers: {
    "w-sleepy": {path: "/w/wt/sleepy", host: "local", state: "asleep"},
    "w-parked": {path: "/w/wt/parked1", host: "local", state: "parked"},
    "w-owner": {path: "/w/wt/owner1", host: "local", state: "blocked-on-owner"},
    "w-ledasked": {path: "/w/wt/ledasked", host: "local", state: "running"}},
  queue: {items: [{id: "q-1", lane: "busy-lane", state: "queued"}]},
  asks: [{id: "ask-1", askedAt: $f, kind: "code", issue: 5, lane: "dev-1", worker: "w-ledasked", question: "keep both?", noCode: true, state: "open"},
         {id: "ask-2", askedAt: $f, kind: "owner", question: "approve spend?", state: "open"},
         {id: "ask-3", askedAt: $f, kind: "code", issue: 5, lane: "dev-1", question: "old", state: "answered"}]}')"
PRS="$(arr "$(pr 20 e1 200 null author-1 '["do-not-merge"]')" "$(pr 21 e2 200)" "$(pr 23 e4 200 null peer-1)" "$(pr 24 e5 200)")"
gen "$W"; runj "$W"
check "host-offline: unverified" "$(exr off)" "unverified"
check "truncated host: unverified" "$(exr cut)" "unverified"
check "a host asks.sh could not read: unverified" "$(exr askbad)" "unverified"
check "no progress time at all: unverified" "$(exr nosig)" "unverified"
check "unverified rows are never stalled" "$(field off rung)$(field cut rung)$(field askbad rung)$(field nosig rung)" "absentabsentabsentabsent"
check "unverified count" "$(jq -r '.unverified' <<<"$OUT")" "4"
check "main-checkout exempt" "$(exr mainco)" "class"
check "other-project exempt" "$(exr otherp)" "class"
check "done-merged exempt" "$(exr merged)" "class"
check "done-selfreported exempt" "$(exr selfrep)" "class"
check "never_touch name exempt" "$(exr nt-lane)" "class"
check "the concertmaster itself exempt" "$(exr concertmaster)" "self"
check "a ledger worker asleep: exempt" "$(exr sleepy)" "asleep"
check "standing-idle, empty queue: exempt" "$(exr quiet)" "idle"
check "standing-idle with queued work: stalled" "$(field busyq rung)" "1"
check "parked worker exempt" "$(exr parked1)" "parked"
check "blocked-on-owner worker exempt" "$(exr owner1)" "owner"
check "cm:waiting-owner on line 2: exempt" "$(exr waits)" "owner"
check "a lane with an open ask listed: exempt" "$(exr asked)" "ask"
check "a lane whose worker has an open ledger ask: exempt" "$(exr ledasked)" "ask"
check "a live lead's child: exempt" "$(exr kid)" "child"
check "a dead lead's child: stalled" "$(field orphankid rung)" "1"
check "a stuck lane: stalled" "$(field plain rung)" "1"
check "a lane's cm:ask is owner-only, not a row (an asks.sh row has no kind)" "$(jq -r '[.rows[] | select(.kind == "ask" and (.name | startswith("asked/ask@")))] | length' <<<"$OUT")$(jq -r '[.exempt[] | select(.kind == "ask" and (.name | startswith("asked/ask@"))) | .code] | first' <<<"$OUT")" "0owner"
check "a ledger ask due a relay" "$(field ask-1 action)" "relay"
check "cm:waiting-owner ask: exempt (Blocked)" "$(jq -r '[.exempt[] | select(.kind == "ask" and (.name | startswith("plain2/"))) | .code] | first' <<<"$OUT")" "owner"
check "ledger open ask: a row" "$(field ask-1 rung)" "1"
check "ledger ask of kind owner: exempt" "$(exr ask-2)" "owner"
check "ledger answered ask: not judged" "$(field ask-3 rung)$(exr ask-3)" "absentabsent"
check "do-not-merge PR exempt" "$(exr '#20')" "label"
check "the PR of a waiting lane: exempt" "$(exr '#21')" "lane"
check "collaborator PR exempt" "$(exr '#23')" "human"
check "an ordinary old PR: stalled" "$(field '#24' rung)" "1"
LED="$(jq -c --arg ttl "$(ago -60)" '. + {freeze: {state: "on", window: "2026-11-16T11:00", ttl: $ttl}}' <<<"$LED")"; gen "$W"; runj "$W"
check "freeze on: every PR exempt" "$(exr '#24')" "freeze"
LED="$(jq -c --arg ttl "$(ago 10)" '.freeze.ttl = $ttl' <<<"$LED")"; gen "$W"; runj "$W"
check "a freeze past its ttl holds nothing" "$(field '#24' rung)" "1"
# a blocked record takes the row out of the ladder until it makes progress
act "$W" "$(ago 1)" lane plain blocked "needs the cloud console: Blocked row"; runj "$W"
check "recorded blocked: exempt" "$(exr plain)" "recorded"

# ---- 8. resume.lock held ---------------------------------------------------------------------------------------------
reset; W="$ROOT/c8"
ITEMS="$(arr "$(item r2 idle 70)" "$(item r1 idle 40)")"
gen "$W"; act "$W" "$(ago 35)" lane r2 nudge "nudged last tick"
mkdir -p "$W/cm/resume.lock"
runj "$W"
check "lock held: rung 2 shows held" "$(field r2 action)" "held:resume.lock"
check "lock held: rung 2 is not due" "$(field r2 due)" "false"
check "lock held: rung 1 still due" "$(field r1 action)" "nudge"
act "$W" "$(ago 0)" lane r2 restart "restarted"; RCA=$?
check "lock held: --act restart refused (exit 1)" "$RCA" "1"
has "lock held: the refusal names the lock" "$(cat "$W/act.err")" "resume.lock is held"
act "$W" "$(ago 0)" lane r1 nudge "nudged"
runj "$W"
check "lock held, rung 1 acted: exit 0 (held rung 2 is not NO-ACTION)" "$RC" "0"
rmdir "$W/cm/resume.lock"
runj "$W"
check "lock released: rung 2 is due again" "$(field r2 action)" "restart|replace"

# ---- 9. --act: enum, secrets, ledger ---------------------------------------------------------------------------------
W="$ROOT/c9"; reset; gen "$W"
act "$W" "$T0" lane x bogus "text"; check "--act unknown verb: exit 2" "$?" "2"
act "$W" "$T0" worker x nudge "text"; check "--act unknown kind: exit 2" "$?" "2"
act "$W" "$T0" lane "two words" nudge "text"; check "--act name with a space: exit 2" "$?" "2"
act "$W" "$T0" lane x nudge "   "; check "--act empty text: exit 2" "$?" "2"
CM_HOME="$W/cm" bash "$SCRIPT" --act lane x nudge >/dev/null 2>&1; check "--act with no text: exit 2" "$?" "2"
act "$W" "$T0" lane x nudge "use ${GHP}$(rep ab 15) to push"; check "--act GitHub token in the text: refused, exit 1" "$?" "1"
act "$W" "$T0" lane x verdict "key s""k-ant-$(rep abcdefghij 3)"; check "--act key in a verdict: refused, exit 1" "$?" "1"
check "refused: nothing recorded" "$( [ -s "$W/cm/stall-actions.ndjson" ] && echo written || echo none)" "none"
check "refused verdict: no ledger decision" "$(jq -r '.decisions // [] | length' "$W/led.json")" "0"
for v in nudge relay restart replace close-ask verdict blocked; do act "$W" "$T0" pr '#5' "$v" "did $v"; check "--act verb $v accepted" "$?" "0"; done
check "one line per action" "$(wc -l < "$W/cm/stall-actions.ndjson" | tr -d ' ')" "7"
check "each line carries kind, name, verb, rung, at" "$(jq -sr 'map("\(.kind) \(.name) \(.verb) \(.rung) \(.at)") | .[5]' "$W/cm/stall-actions.ndjson")" "pr #5 verdict 3 $T0"
check "a 40-hex commit id in the text is not a secret" "$(act "$W" "$T0" pr '#5' nudge "rebased on $(rep 0123456789abcdef 2)01234567"; echo $?)" "0"
printf '{"workers":{},"decisions":"oops"}\n' > "$W/led.json"
act "$W" "$T0" pr '#5' verdict "a verdict"; check "decisions[] not a list: verdict refused, exit 1" "$?" "1"
check "refused verdict: no action line" "$(wc -l < "$W/cm/stall-actions.ndjson" | tr -d ' ')" "8"

# ---- 10. stale, missing and bad input --------------------------------------------------------------------------------
reset; W="$ROOT/c10"; ITEMS="$(arr "$(item a idle 40)")"
GEN="$(ago 61)"; gen "$W"; run "$W"
check "inputs 61 min old (over 2 ticks): exit 3" "$RC" "3"
has "STALE-INPUT says which" "$OUT" "STALE-INPUT classify"
GEN="$(ago 59)"; gen "$W"; run "$W"
check "inputs 59 min old: judged (exit 4)" "$RC" "4"
GEN="$T0"; gen "$W"; printf 'not json' > "$W/disc.json"; run "$W"
check "unparsable discover: exit 3" "$RC" "3"
gen "$W"; printf '{"generatedAt":"%s"}\n' "$T0" > "$W/asks.json"; run "$W"
check "asks without an asks list: exit 3" "$RC" "3"
gen "$W"; jq '.schema = "other"' "$W/cls.json" > "$W/x" && mv "$W/x" "$W/cls.json"; run "$W"
check "classify of the wrong schema: exit 3" "$RC" "3"
gen "$W"; jq 'del(.generatedAt)' "$W/cls.json" > "$W/x" && mv "$W/x" "$W/cls.json"; run "$W"
check "classify with no generatedAt: exit 3" "$RC" "3"
gen "$W"; : > "$W/led.json"; run "$W"
check "empty ledger: exit 3" "$RC" "3"
gen "$W"; OUT="$(CM_HOME="$W/cm" bash "$SCRIPT" --classify "$W/none.json" --discover "$W/disc.json" --asks "$W/asks.json" --ledger "$W/led.json" --since "$SINCE" 2>/dev/null)"; RC=$?
check "a missing input file: exit 3" "$RC" "3"

# ---- 11. usage -------------------------------------------------------------------------------------------------------
gen "$W"
bash "$SCRIPT" >/dev/null 2>&1; check "no args: exit 2" "$?" "2"
CM_HOME="$W/cm" bash "$SCRIPT" --classify "$W/cls.json" --discover "$W/disc.json" --asks "$W/asks.json" --ledger "$W/led.json" >/dev/null 2>&1
check "no --since: exit 2" "$?" "2"
run "$W" --bogus; check "unknown arg: exit 2" "$RC" "2"
OUT="$(CM_HOME="$W/cm" bash "$SCRIPT" --classify "$W/cls.json" --discover "$W/disc.json" --asks "$W/asks.json" --ledger "$W/led.json" --since yesterday 2>&1)"
check "--since not ISO: exit 2" "$?" "2"
CM_NOW=noon bash "$SCRIPT" --help >/dev/null 2>&1; check "a bad CM_NOW: exit 2" "$?" "2"
bash "$SCRIPT" --help >/dev/null 2>&1; check "--help: exit 0" "$?" "0"

# ---- 12. a bad rung config falls back to the defaults -----------------------------------------------------------------
sed 's/^  stall_rungs_min: .*/  stall_rungs_min: [90, 60]/' "$ROOT/config.yaml" > "$ROOT/config-bad.yaml"
reset; W="$ROOT/c12"; ITEMS="$(arr "$(item b30 idle 30)")"; gen "$W"
OUT="$(CM_CONFIG="$ROOT/config-bad.yaml" CM_HOME="$W/cm" bash "$SCRIPT" --classify "$W/cls.json" --discover "$W/disc.json" --asks "$W/asks.json" --ledger "$W/led.json" --since "$SINCE" --json 2>"$W/err")"
check "bad stall_rungs_min: defaults used" "$(jq -c '.rungs' <<<"$OUT")" "[30,60,90]"
has "bad stall_rungs_min: a warning" "$(cat "$W/err")" "stall_rungs_min"
sed 's/^  stall_rungs_min: .*/  stall_rungs_min: [10, 20, 40]/' "$ROOT/config.yaml" > "$ROOT/config-short.yaml"
OUT="$(CM_CONFIG="$ROOT/config-short.yaml" CM_HOME="$W/cm" bash "$SCRIPT" --classify "$W/cls.json" --discover "$W/disc.json" --asks "$W/asks.json" --ledger "$W/led.json" --since "$SINCE" --json 2>/dev/null)"
check "config rungs [10, 20, 40]: 30 min is age rung 2" "$(field b30 ageRung)" "2"

# ---- 13. review findings ------------------------------------------------------------------------
# F1 owner-only ledger ask kinds are Blocked; delegated and own-scope kinds ladder
reset; W="$ROOT/f1"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: (([
    "credentials", "payments", "prod-data", "migration", "auth", "teardown", "merge", "owner",
    "merge-gate-override", "remove-standing", "accept-unmerged-beads", "no-such-kind",
    "release", "deploy", "secrets", "code"] | map({id: ("k-" + .), kind: ., issue: 5, lane: "dev-1", askedAt: $f, question: "q", noCode: true, state: "open"}))
  + [{id: "k-none", askedAt: $f, question: "q", state: "open"}, {id: "k-scope", scope: "merge", askedAt: $f, question: "q", state: "open"}])}')"
gen "$W"; runj "$W"
for k in credentials payments prod-data migration auth teardown merge owner merge-gate-override remove-standing accept-unmerged-beads no-such-kind none; do
  check "F1 ledger ask kind $k: exempt owner, not laddered" "$(exr "k-$k")$(field "k-$k" rung)" "ownerabsent"
done
check "F1 ledger ask with the kind in .scope (merge): exempt owner" "$(exr k-scope)" "owner"
check "F1 ledger ask kind code: laddered (rung 1)" "$(field k-code rung)" "1"
for k in release deploy; do check "F1 ledger ask kind $k naming no delegated class (question q): exempt owner (default deny)" "$(exr "k-$k")$(field "k-$k" rung)" "ownerabsent"; done
check "F1 secrets ask: exempt owner, not laddered" "$(exr k-secrets)$(field k-secrets rung)" "ownerabsent"

# F1b a secrets ask never ladders, whatever project or wording it carries: a key shared with production reads like a test one
reset; W="$ROOT/f1b"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "s-none", kind: "secrets", askedAt: $f, question: "store the key for the test persona", state: "open"},
    {id: "s-test", kind: "secrets", project: "test", askedAt: $f, question: "store the key for the test persona", state: "open"},
    {id: "s-staging", kind: "secrets", project: "Staging", askedAt: $f, question: "store the key for the test persona", state: "open"},
    {id: "s-preview", kind: "secrets", project: "preview", askedAt: $f, question: "store the key for the test persona", state: "open"},
    {id: "s-prodproj", kind: "secrets", project: "production", askedAt: $f, question: "store the key for the test persona", state: "open"},
    {id: "s-numproj", kind: "secrets", project: 1, askedAt: $f, question: "store the key for the test persona", state: "open"},
    {id: "s-prodtext", kind: "secrets", project: "staging", askedAt: $f, question: "rotate the production key", state: "open"},
    {id: "s-acct", kind: "secrets", project: "test", askedAt: $f, question: "set the account-wide key", state: "open"},
    {id: "s-live", kind: "secrets", project: "preview", askedAt: $f, question: "copy the live key here", state: "open"},
    {id: "s-envlive", kind: "secrets", project: "staging", askedAt: $f, question: "set PAYMENT_LIVE_SECRET_KEY", state: "open"},
    {id: "s-envprod", kind: "secrets", project: "staging", askedAt: $f, question: "rotate PROD_DB_SERVICE_ROLE_KEY", state: "open"},
    {id: "s-sklive", kind: "secrets", project: "test", askedAt: $f, question: "store the live payment key", state: "open"},
    {id: "s-ref", kind: "secrets", project: "staging", askedAt: $f, question: "set the key on qzxwvutsrqponmlkjihg", state: "open"},
    {id: "s-repo", kind: "secrets", project: "staging", askedAt: $f, question: "set the repo-level webhook secret", state: "open"},
    {id: "s-org", kind: "secrets", project: "test", askedAt: $f, question: "set the org-wide npm token", state: "open"},
    {id: "s-hyph", kind: "secrets", project: "test", askedAt: $f, question: "set the pro-duction key", state: "open"},
    {id: "s-textf", kind: "secrets", project: "test", askedAt: $f, question: "store the key", text: "production", state: "open"},
    {id: "s-envf", kind: "secrets", project: "test", askedAt: $f, question: "store the key", env: "production", state: "open"},
    {id: "s-keyf", kind: "secrets", project: "test", askedAt: $f, question: "store the key", meta: {live: true}, state: "open"},
    {id: "s-qarr", kind: "secrets", project: "test", askedAt: $f, question: ["store the key"], state: "open"},
    {id: "s-camelkey", kind: "secrets", project: "staging", askedAt: $f, question: "store the key", env: {payLiveKey: "x"}, state: "open"},
    {id: "s-camel", kind: "secrets", project: "staging", askedAt: $f, question: "set payLiveSecretKey", state: "open"},
    {id: "s-camelprod", kind: "secrets", project: "test", askedAt: $f, question: "set prodServiceRoleKey", state: "open"},
    {id: "s-deep", kind: "secrets", project: "preview", askedAt: $f, question: "store the key", meta: [{x: [{deep: "production"}]}], state: "open"},
    {id: "s-zwsp", kind: "secrets", project: "preview", askedAt: $f, question: "rotate the pre\u200bview key", state: "open"},
    {id: "s-nbsp", kind: "secrets", project: "preview", askedAt: $f, question: "rotate the\u00a0preview key", state: "open"},
    {id: "s-homo", kind: "secrets", project: "preview", askedAt: $f, question: "copy the l\u0456ve key", state: "open"},
    {id: "s-spaced", kind: "secrets", project: "staging", askedAt: $f, question: "copy the p r o d key", state: "open"},
    {id: "s-prod", kind: "secrets", project: "staging", askedAt: $f, question: "set the key on the pro-d box", state: "open"},
    {id: "s-orglevel", kind: "secrets", project: "staging", askedAt: $f, question: "set the org level token", state: "open"},
    {id: "s-organis", kind: "secrets", project: "staging", askedAt: $f, question: "set the organisation-wide token", state: "open"},
    {id: "s-repolevel", kind: "secrets", project: "preview", askedAt: $f, question: "set it at the repository level", state: "open"},
    {id: "s-prd", kind: "secrets", project: "preview", askedAt: $f, question: "set PRD_PAY_KEY", state: "open"},
    {id: "s-prod2", kind: "secrets", project: "preview", askedAt: $f, question: "set the prod2 key", state: "open"},
    {id: "s-livemode", kind: "secrets", project: "preview", askedAt: $f, question: "set the livemode key", state: "open"},
    {id: "s-livemodekey", kind: "secrets", project: "preview", askedAt: $f, question: "set the key", livemode: true, state: "open"},
    {id: "s-host", kind: "secrets", project: "preview", askedAt: $f, question: "set the key on the production host", state: "open"},
    {id: "s-real", kind: "secrets", project: "staging", askedAt: $f, question: "paste the real payment key", state: "open"},
    {id: "s-main", kind: "secrets", project: "staging", askedAt: $f, question: "use the main payment account key", state: "open"},
    {id: "s-alive", kind: "secrets", project: "preview", askedAt: $f, question: "keep the token alive, deliver it, product olive", state: "open"},
    {id: "s-mailkey", kind: "secrets", project: "Preview", askedAt: $f, question: "rotate the preview mail vendor key", state: "open"},
    {id: "s-noq", kind: "secrets", project: "test", askedAt: $f, state: "open"},
    {id: "s-emptyq", kind: "secrets", project: "test", askedAt: $f, question: "", state: "open"},
    {id: "b01", kind: "secrets", project: "test", askedAt: $f, question: "set EDGE_API_TOKEN for the store build OTA channel", state: "open"},
    {id: "b02", kind: "secrets", project: "staging", askedAt: $f, question: "I need DB_ACCESS_TOKEN to run the staging deploy", state: "open"},
    {id: "b03", kind: "secrets", project: "staging", askedAt: $f, question: "set VITE_STORE_API_KEY for the staging build", state: "open"},
    {id: "b04", kind: "secrets", project: "staging", askedAt: $f, question: "run gh secret set LLM_API_KEY (repo secret) so staging picks it up", state: "open"},
    {id: "b05", kind: "secrets", project: "staging", askedAt: $f, question: "set it as an org secret", state: "open"},
    {id: "b06", kind: "secrets", project: "test", askedAt: $f, question: "rotate the store console API key for the store build upload", state: "open"},
    {id: "b07", kind: "secrets", project: "test", askedAt: $f, question: "need the mobile upload keystore password to test the release build", state: "open"},
    {id: "b08", kind: "secrets", project: "test", askedAt: $f, question: "rotate OTA_SIGNING_PRIVATE_KEY_PEM", state: "open"},
    {id: "b09", kind: "secrets", project: "staging", askedAt: $f, question: "set the APNs auth key", state: "open"}]}')"
gen "$W"; runj "$W"
for k in s-none s-test s-staging s-preview s-mailkey s-noq s-emptyq s-prodproj s-numproj s-prodtext s-acct s-live s-envlive \
         s-envprod s-sklive s-ref s-repo s-org s-hyph s-textf s-envf s-keyf s-qarr s-camelkey s-camel s-camelprod s-deep \
         s-zwsp s-nbsp s-homo s-spaced s-prod s-orglevel s-organis s-repolevel s-prd s-prod2 s-livemode s-livemodekey \
         s-host s-real s-main s-alive b01 b02 b03 b04 b05 b06 b07 b08 b09; do
  check "F1b secrets $k: exempt owner, not laddered" "$(exr "$k")$(field "$k" rung)" "ownerabsent"
done
has "F1b a plain test-project secrets ask: the reason says secrets always go to the owner" \
  "$(jq -r '.exempt[] | select(.name == "s-mailkey") | .reason' <<<"$OUT")" "always goes to the owner"

# F1c own-scope kinds pass the ask-timeout.sh deny scan (scripts/ask-deny.sh): an owner-only subject stays Blocked
reset; W="$ROOT/f1c"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "c-plain", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card list into two components?", noCode: true, state: "open"},
    {id: "c-mig", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "add a migration for the new column?", noCode: true, state: "open"},
    {id: "c-rls", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "loosen the RLS policy on the roster table?", noCode: true, state: "open"},
    {id: "c-split", kind: "design", issue: 5, lane: "dev-1", askedAt: $f, question: "rotate the se-cret on the card?", noCode: true, state: "open"},
    {id: "c-file", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "keep the helper?", files: ["db/migrations/1_x.sql"], state: "open"},
    {id: "c-outside", kind: "test", issue: 5, lane: "dev-1", askedAt: $f, question: "keep the helper?", files: ["scripts/x.sh"], state: "open"},
    {id: "c-okfile", kind: "test", issue: 5, lane: "dev-1", askedAt: $f, question: "keep the helper?", files: ["src/components/Card.tsx"], state: "open"},
    {id: "c-uni", kind: "scope", issue: 5, lane: "dev-1", askedAt: $f, question: "drop the m\u0456gration step?", noCode: true, state: "open"},
    {id: "c-nofiles", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card list into two components?", state: "open"},
    {id: "c-emptyfiles", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card list into two components?", files: [], state: "open"},
    {id: "c-nocodepr", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card list into two components?", noCode: true, pr: 12, state: "open"},
    {id: "c-topic", kind: "product", issue: 5, lane: "dev-1", topic: "checkout copy", askedAt: $f, question: "which wording?", noCode: true, state: "open"}]}')"
gen "$W"; runj "$W"
check "F1c a plain code ask with noCode: laddered (rung 1)" "$(exr c-plain)$(field c-plain rung)" "absent1"
check "F1c a code ask with no files[] and no noCode: exempt owner, not laddered" "$(exr c-nofiles)$(field c-nofiles rung)" "ownerabsent"
check "F1c a code ask with files [] and no noCode: exempt owner, not laddered" "$(exr c-emptyfiles)$(field c-emptyfiles rung)" "ownerabsent"
check "F1c a noCode code ask with a PR: exempt owner, not laddered" "$(exr c-nocodepr)$(field c-nocodepr rung)" "ownerabsent"
check "F1c a code ask naming a migration: exempt owner, not laddered" "$(exr c-mig)$(field c-mig rung)" "ownerabsent"
has "F1c a code ask naming a migration: the reason names the hit" "$(jq -r '.exempt[] | select(.name == "c-mig") | .reason' <<<"$OUT")" "naming migration"
check "F1c a code ask naming an RLS policy: exempt owner, not laddered" "$(exr c-rls)$(field c-rls rung)" "ownerabsent"
check "F1c a design ask with a split word (se-cret): exempt owner" "$(exr c-split)$(field c-split rung)" "ownerabsent"
check "F1c a code ask listing a migration file: exempt owner" "$(exr c-file)$(field c-file rung)" "ownerabsent"
check "F1c a test ask listing a file outside the allowlist: exempt owner" "$(exr c-outside)$(field c-outside rung)" "ownerabsent"
check "F1c a test ask listing an allowlisted file: laddered (rung 1)" "$(exr c-okfile)$(field c-okfile rung)" "absent1"
check "F1c a scope ask with a homoglyph: exempt owner" "$(exr c-uni)$(field c-uni rung)" "ownerabsent"
check "F1c a product ask whose topic names checkout: exempt owner" "$(exr c-topic)$(field c-topic rung)" "ownerabsent"

# F1d the ask-timeout.sh scope gates (scripts/ask-deny.sh ask_scope_why): no issue, no lane, an ops, epic or pr-sweeper
# lane and an epic plan-ready approval stay with the owner, whatever the text says; a plain ask of a dev lane ladders
reset; W="$ROOT/f1d"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {
    "wops": {path: "/w/wt/child-o", host: "local", state: "running", lane: "ops-sweeper"},
    "wdev": {path: "/w/wt/child-v", host: "local", state: "running", lane: "dev-sweeper"}},
  asks: [
    {id: "d-ok", kind: "code", issue: 5, lane: "dev-sweeper", askedAt: $f, question: "split the card list?", noCode: true, state: "open"},
    {id: "d-noissue", kind: "code", lane: "dev-sweeper", askedAt: $f, question: "split the card list?", files: ["src/a.ts"], state: "open"},
    {id: "d-strissue", kind: "code", issue: "5", lane: "dev-sweeper", askedAt: $f, question: "split the card list?", noCode: true, state: "open"},
    {id: "d-ops", kind: "code", issue: 8, lane: "ops-sweeper", askedAt: $f, question: "split the card list?", files: ["src/a.ts"], state: "open"},
    {id: "d-epic", kind: "scope", issue: 7, lane: "epic-frameworks", askedAt: $f, question: "plan ready: approve the epic plan", noCode: true, state: "open"},
    {id: "d-epiclane", kind: "design", issue: 7, lane: "Epic-Data", askedAt: $f, question: "split the card list?", noCode: true, state: "open"},
    {id: "d-prsweep", kind: "test", issue: 7, lane: "pr-sweeper", askedAt: $f, question: "split the card list?", noCode: true, state: "open"},
    {id: "d-plan", kind: "scope", issue: 7, lane: "dev-sweeper", askedAt: $f, question: "  plan ready for review", noCode: true, state: "open"},
    {id: "d-nolane", kind: "code", issue: 5, askedAt: $f, question: "split the card list?", noCode: true, state: "open"},
    {id: "d-wops", kind: "code", issue: 5, worker: "wops", askedAt: $f, question: "split the card list?", noCode: true, state: "open"},
    {id: "d-wdev", kind: "code", issue: 5, worker: "wdev", askedAt: $f, question: "split the card list?", noCode: true, state: "open"}]}')"
gen "$W"; runj "$W"
check "F1d a dev-lane code ask with an issue: laddered (rung 1)" "$(exr d-ok)$(field d-ok rung)" "absent1"
for k in d-noissue d-strissue d-ops d-epic d-epiclane d-prsweep d-plan d-nolane d-wops; do
  check "F1d $k: exempt owner, not laddered" "$(exr $k)$(field $k rung)" "ownerabsent"
done
check "F1d a ledger worker of a dev lane gives the lane: laddered (rung 1)" "$(exr d-wdev)$(field d-wdev rung)" "absent1"
has "F1d no issue: the reason says so" "$(jq -r '.exempt[] | select(.name == "d-noissue") | .reason' <<<"$OUT")" "no issue to record a verdict on"
has "F1d an ops lane: the reason names the lane" "$(jq -r '.exempt[] | select(.name == "d-ops") | .reason' <<<"$OUT")" "ops-sweeper asks stay with"
has "F1d a plan-ready approval: the reason names the epic plan" "$(jq -r '.exempt[] | select(.name == "d-epic") | .reason' <<<"$OUT")" "epic-frameworks asks stay with"
has "F1d a plan-ready approval of a dev lane: the reason names the epic plan" "$(jq -r '.exempt[] | select(.name == "d-plan") | .reason' <<<"$OUT")" "epic plan approval stays with"
has "F1d no lane: the reason says the asker is unknown" "$(jq -r '.exempt[] | select(.name == "d-nolane") | .reason' <<<"$OUT")" "no lane"

# F2 cm:blocked in the concertmaster's own worktree is a held item; a lane's cm:blocked is Blocked; a lane's cm:ask ladders
reset; W="$ROOT/f2"
ITEMS="$(arr "$(item epic-cm-upgrade running 5 local self)" "$(item lb idle 200)" "$(item la idle 200)")"
ASKS="$(jq -nc --arg f "$(ago 65)" '[
  {host: "local", worktree: "epic-cm-upgrade", path: "/w/wt/epic-cm-upgrade", tag: "cm:blocked", text: "define lease", firstSeen: $f, runs: 3},
  {host: "local", worktree: "epic-cm-upgrade", path: "/w/wt/epic-cm-upgrade", tag: "cm:ask", text: "confirm readings", firstSeen: $f, runs: 3},
  {host: "local", worktree: "concertmaster", path: "/w/wt/concertmaster", tag: "cm:blocked", text: "beta go-live", firstSeen: $f, runs: 3},
  {host: "local", worktree: "lb", path: "/w/wt/lb", tag: "cm:blocked", text: "cloud console?", firstSeen: $f, runs: 3},
  {host: "local", worktree: "la", path: "/w/wt/la", tag: "cm:ask", text: "which test?", firstSeen: $f, runs: 3}]')"
gen "$W"; runj "$W"
exk() { jq -r --arg p "$1" '[.exempt[] | select(.kind == "ask" and (.name | startswith($p))) | .code] | if length == 0 then "absent" else .[0] end' <<<"$OUT"; }
rwk() { jq -r --arg p "$1" '[.rows[] | select(.kind == "ask" and (.name | startswith($p))) | .rung | tostring] | if length == 0 then "absent" else .[0] end' <<<"$OUT"; }
check "F2 cm:blocked in the concertmaster's own worktree (classify self item): held" "$(exk epic-cm-upgrade/blocked@)$(rwk epic-cm-upgrade/blocked@)" "heldabsent"
check "F2 cm:ask in the concertmaster's own worktree: held" "$(exk epic-cm-upgrade/ask@)" "held"
check "F2 cm:blocked in the worktrees.self_name worktree: held" "$(exk concertmaster/blocked@)" "held"
check "F2 a lane's cm:blocked: exempt owner (Blocked, not stalled)" "$(exk lb/blocked@)$(rwk lb/blocked@)" "ownerabsent"
check "F2 the lane with the cm:blocked: exempt (open ask)" "$(exr lb)" "ask"
check "F2 a lane's cm:ask: exempt owner (no kind, so owner-only), not laddered" "$(exk la/ask@)$(rwk la/ask@)" "ownerabsent"
check "F2 no held or Blocked item is a NO-ACTION row" "$(jq -r '[.rows[] | select(.noAction) | .name] | map(select(startswith("la/") | not)) | length' <<<"$OUT")" "0"

# F3 asks.sh host list failed: hosts missing from hostsRead are unverified; an ask with no host is unverified
reset; W="$ROOT/f3"
HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"gce-1","reachable":true,"truncated":false}]'
UNREACH='[{"host":"host list","error":"orca host list failed"}]'; HREAD='["local"]'
ITEMS="$(arr "$(item remote1 idle 40 gce-1)" "$(item local1 idle 40)")"
ASKS="$(jq -nc --arg f "$(ago 40)" '[{host: "gce-1", worktree: "r9", tag: "cm:ask", text: "t", firstSeen: $f},
  {host: null, worktree: "x", tag: "cm:ask", text: "t", firstSeen: $f}]')"
gen "$W"; runj "$W"
check "F3 a lane on a host asks.sh did not read: unverified" "$(exr remote1)$(field remote1 rung)" "unverifiedabsent"
check "F3 a lane on a host asks.sh read: judged" "$(field local1 rung)" "1"
check "F3 an ask on a host missing from hostsRead: unverified" "$(exk r9/)" "unverified"
check "F3 an ask with host null: unverified" "$(exk x/)$(rwk x/)" "unverifiedabsent"
check "F3 unverified count" "$(jq -r '.unverified' <<<"$OUT")" "3"

# F4 a time inside a comment is never progress (a just-passed deadline must not reset a 3h idle lane)
reset; W="$ROOT/f4"
ITEMS="$(arr "$(item eta1 idle 180)")"
WTS='[{"host":"local","path":"/w/wt/eta1","comment":"cm:eta 2026-11-16T11:58:00Z PR ready (written 09:00)"}]'
gen "$W"; runj "$W"
check "F4 a deadline 2 min ago in a comment: the age stays 180" "$(field eta1 ageMinutes)" "180"

# F5 repeated nudges do not hide a missed restart: only an action at the due rung clears NO-ACTION
reset; W="$ROOT/f5"
ITEMS="$(arr "$(item rep idle 150)")"
gen "$W"
for m in 120 90 60 30 1; do act "$W" "$(ago "$m")" lane rep nudge "n$m"; done
runj "$W"
check "F5 five nudges, 150 min idle: rung 2 due" "$(field rep rung)$(field rep due)" "2true"
check "F5 a nudge this tick below the due rung: NO-ACTION" "$(field rep noAction)" "true"
check "F5 exit 4" "$RC" "4"

# F6 --act refuses more credential shapes (all built at run time from split strings)
W="$ROOT/f6"; reset; gen "$W"
U1="5c0d1e2f"; U2="6a7b-4c8d-9e0f"; U3="1a2b3c4d5e6f"
S_BW="0.$U1-$U2-$U3.Xy9KqLmN""oPqRsTuV:QUJDREVG""R0hJSktMTU5PUA=="
S_BEARER="Bear""er 0123456789""abcdef0123""456789abcdef""01234567"
S_PW="pass""word is Hunter2""Correct!Horse"
S_LOGIN="persona log""in qa-user Zx9Qm4""Lp2"
S_DASH="AbCdEfGhIjKlMnOpQrSt""-UvWxYz0123456789abcd"
for s in "$S_BW" "$S_BEARER" "$S_PW" "$S_LOGIN" "$S_DASH"; do
  act "$W" "$T0" lane x nudge "did it with $s"; check "F6 --act refuses: ${s:0:12}...: exit 1" "$?" "1"
done
act "$W" "$T0" lane "$S_DASH" nudge "a token as the name"; check "F6 --act refuses a 41-char mixed token as the name" "$?" "1"
check "F6 refused: nothing recorded" "$( [ -s "$W/cm/stall-actions.ndjson" ] && echo written || echo none)" "none"
act "$W" "$T0" lane x nudge "password is required on staging, login page 2 fixed"; check "F6 plain words about a password are not a secret" "$?" "0"
act "$W" "$T0" lane feature-long-kebab-lane-name-for"-the-epic-x" nudge "nudged"; check "F6 a 44-char kebab lane name is not a secret" "$?" "0"

# F7 two lanes with one name on two hosts: an action carries its host and exempts only that one
reset; W="$ROOT/f7"
HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"h2","reachable":true,"truncated":false}]'; HREAD='["local","h2"]'
ITEMS="$(arr "$(item twin idle 70 local)" "$(item twin idle 70 h2)")"
gen "$W"
act "$W" "$(ago 1)" lane twin blocked "needs the console" --host local; check "F7 --act --host accepted: exit 0" "$?" "0"
check "F7 the action line carries the host" "$(jq -r '.host' "$W/cm/stall-actions.ndjson")" "local"
runj "$W"
check "F7 the twin on local: recorded" "$(jq -r '[.exempt[] | select(.name == "twin" and .host == "local") | .code] | first // "absent"' <<<"$OUT")" "recorded"
check "F7 the twin on h2: still stalled" "$(jq -r '[.rows[] | select(.name == "twin" and .host == "h2") | .rung | tostring] | first // "absent"' <<<"$OUT")" "1"
act "$W" "$(ago 1)" lane twin nudge "which one?"; runj "$W"
check "F7 an action with no host on an ambiguous name matches neither" "$(jq -r '[.rows[] | select(.name == "twin" and .host == "h2") | .actedThisTick | tostring] | first // "absent"' <<<"$OUT")" "false"
act "$W" "$T0" lane twin nudge "x" --host "two words;rm"; check "F7 --host must be a plain token: exit 2" "$?" "2"

# F8 a granted queue entry is work in flight: a standing-idle lane holding one is not exempt
reset; W="$ROOT/f8"
ITEMS="$(arr "$(item devl standing-idle 120 local standing null dev)")"
LED='{"workers":{},"queue":{"items":[{"id":"q-9","lane":"dev","state":"granted"}]}}'
gen "$W"; runj "$W"
check "F8 standing-idle with a granted queue entry: stalled" "$(field devl rung)$(exr devl)" "1absent"

# F9 (B1) a comment ask is kindless: owner-only, never laddered, even next to the ledger ask filed for it
reset; W="$ROOT/f9"
ITEMS="$(arr "$(item lq running 5)")"
ASKS="$(jq -nc --arg f "$(ago 65)" '[{host: "local", worktree: "lq", path: "/w/wt/lq", tag: "cm:ask", text: "need the production payment secret key set", firstSeen: $f, runs: 3}]')"
LED="$(jq -nc --arg f "$(ago 65)" '{workers: {}, asks: [{id: "q-sec", kind: "secrets", lane: "lq", askedAt: $f, question: "need the production payment secret key set", state: "open"}]}')"
gen "$W"; runj "$W"
check "F9 the cm:ask row: exempt owner, not a row" "$(exk lq/ask@)$(rwk lq/ask@)" "ownerabsent"
check "F9 the ledger secrets ask: exempt owner" "$(exr q-sec)" "owner"
check "F9 nothing due: exit 0, not NO-ACTION" "$RC$(jq -r '.noAction' <<<"$OUT")" "0false"

# F10 (B2) a ledger ask names its lane by asks[].lane: the lane and its PR are exempt, not nudged
reset; W="$ROOT/f10"
ITEMS="$(arr "$(item la idle 95 local prefix '{"number":41,"state":"OPEN"}')" "$(item lc idle 95 local prefix '{"number":43,"state":"OPEN"}')")"
PRS="$(arr "$(pr 41 sha41 200)" "$(pr 43 sha43 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "la-sec", kind: "secrets", lane: " LA ", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F10 the lane named by asks[].lane (any case, trimmed): exempt ask, not nudged" "$(exr la)$(field la rung)" "askabsent"
check "F10 its PR: exempt (lane waits), not laddered" "$(exr '#41')$(field '#41' rung)" "laneabsent"
check "F10 a lane with no ask: still stalled" "$(field lc rung)" "1"
check "F10 its PR: still stalled" "$(field '#43' rung)" "1"

# F11 an owner-only ledger ask that names a PR (asks[].pr) exempts that PR, in every accepted form
reset; W="$ROOT/f11"
PRS="$(arr "$(pr 51 s51 200)" "$(pr 52 s52 200)" "$(pr 53 s53 200)" "$(pr 55 s55 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "p-num", kind: "secrets", pr: 51, askedAt: $f, question: "q", state: "open"},
    {id: "p-hash", kind: "merge", pr: "#52", askedAt: $f, question: "q", state: "open"},
    {id: "p-repo", kind: "owner", pr: "org/repo#53", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F11 asks[].pr as a number: the PR is exempt" "$(exr '#51')$(field '#51' rung)" "askabsent"
check "F11 asks[].pr as #n: the PR is exempt" "$(exr '#52')$(field '#52' rung)" "askabsent"
check "F11 asks[].pr as owner/repo#n: the PR is exempt" "$(exr '#53')$(field '#53' rung)" "askabsent"
check "F11 a PR no ask names: still stalled" "$(field '#55' rung)" "1"

# F12 a lane with a recorded blocked action: its PR is exempt too (checked before PRs are judged)
reset; W="$ROOT/f12"
ITEMS="$(arr "$(item lbk idle 95 local prefix '{"number":61,"state":"OPEN"}')")"
PRS="$(arr "$(pr 61 s61 200)")"
gen "$W"
act "$W" "$(ago 1)" lane lbk blocked "waiting on the console login" --host local; check "F12 --act blocked recorded: exit 0" "$?" "0"
runj "$W"
check "F12 the blocked lane: recorded" "$(exr lbk)" "recorded"
check "F12 its PR: exempt (lane), not laddered" "$(exr '#61')$(field '#61' rung)" "laneabsent"

# F13 ledger asks get the own-worktree check comment asks get: a held item, whatever the kind
reset; W="$ROOT/f13"
ITEMS="$(arr "$(item epic-cm-upgrade running 5 local self)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {
    "w-cm": {path: "/w/wt/epic-cm-upgrade", host: "local", state: "running"},
    "w-other": {path: "/w/wt/other", host: "local", state: "running"}}, asks: [
    {id: "h-rel", kind: "release", worker: "w-cm", askedAt: $f, question: "ship the store build", state: "open"},
    {id: "h-lane", kind: "code", issue: 5, lane: "concertmaster", askedAt: $f, question: "split the card?", noCode: true, state: "open"},
    {id: "h-path", kind: "deploy", path: "/w/wt/epic-cm-upgrade", askedAt: $f, question: "ship the build", state: "open"},
    {id: "h-not", kind: "release", worker: "w-other", askedAt: $f, question: "ship the store build", state: "open"}]}')"
gen "$W"; runj "$W"
check "F13 a release ask whose worker is the own worktree: held" "$(exr h-rel)$(field h-rel rung)" "heldabsent"
check "F13 a ledger ask whose lane is worktrees.self_name: held" "$(exr h-lane)$(field h-lane rung)" "heldabsent"
check "F13 a ledger ask whose path is the own worktree: held" "$(exr h-path)$(field h-path rung)" "heldabsent"
check "F13 a release ask from another worktree: laddered" "$(exr h-not)$(field h-not rung)" "absent1"

# F14 the kind is lowercased and trimmed (as ask-timeout.sh); release and deploy pass a narrow cutover and secret scan
reset; W="$ROOT/f14"
KEYID_T="AK""IA""IOSFODNN7""EXAMPLE"; HASH_T="9f86d081""884c7d659a""2feaa0c55ad015"; LONG_T="$(printf 'x%.0s' $(seq 5000))"
LED="$(jq -nc --arg f "$(ago 95)" --arg keyid "$KEYID_T" --arg hash "$HASH_T" --arg long "$LONG_T" '{workers: {}, asks: [
    {id: "r-case", kind: " Release ", askedAt: $f, question: "ship the store build", state: "open"},
    {id: "r-scope", scope: "DEPLOY", askedAt: $f, question: "open the deploy window", state: "open"},
    {id: "r-go", kind: "release", askedAt: $f, question: "post this:\ngo apply production cutover", state: "open"},
    {id: "r-goline", kind: "deploy", askedAt: $f, question: "- `go seed staging`", state: "open"},
    {id: "r-goquote", kind: "deploy", askedAt: $f, question: "> go apply production", state: "open"},
    {id: "r-gospace", kind: "deploy", askedAt: $f, question: "go  apply   production", state: "open"},
    {id: "r-srk", kind: "deploy", askedAt: $f, question: "set DB_SERVICE_ROLE_KEY on production", state: "open"},
    {id: "r-paykey", kind: "release", askedAt: $f, question: "add the live payment key to production", state: "open"},
    {id: "r-r2", kind: "deploy", askedAt: $f, question: "rotate the object store access key", state: "open"},
    {id: "r-pat", kind: "release", askedAt: $f, question: "upload with the new GH PAT", state: "open"},
    {id: "r-hook", kind: "deploy", askedAt: $f, question: "register the payments webhook", state: "open"},
    {id: "r-keys", kind: "deploy", askedAt: $f, question: "copy the keys over", state: "open"},
    {id: "r-vault", kind: "deploy", askedAt: $f, question: "update the vault entry", state: "open"},
    {id: "r-jwt", kind: "deploy", askedAt: $f, question: "rotate the jwt", state: "open"},
    {id: "r-envvar", kind: "deploy", askedAt: $f, question: "set the env var on production", state: "open"},
    {id: "r-p8", kind: "release", askedAt: $f, question: "update the .p8 for the store upload", state: "open"},
    {id: "r-prov", kind: "release", askedAt: $f, question: "new provisioning profile for the release", state: "open"},
    {id: "r-keychain", kind: "release", askedAt: $f, question: "unlock the keychain", state: "open"},
    {id: "r-p12", kind: "release", askedAt: $f, question: "upload the p12 cert", state: "open"},
    {id: "r-dsn", kind: "deploy", askedAt: $f, question: "add the DSN to production", state: "open"},
    {id: "r-oauth", kind: "deploy", askedAt: $f, question: "set the OAuth client for prod", state: "open"},
    {id: "r-bearer", kind: "deploy", askedAt: $f, question: "add the new bearer for prod", state: "open"},
    {id: "r-keyboard", kind: "release", askedAt: $f, question: "ship the store build", lane: "keyboard-shortcuts", state: "open"},
    {id: "r-pathf", kind: "release", askedAt: $f, question: "ship the store build", worker: "pathfinder-fix", state: "open"},
    {id: "r-patch", kind: "release", askedAt: $f, question: "ship the store build", path: "/w/wt/patch-notes", state: "open"},
    {id: "v1", kind: "deploy", askedAt: $f, question: "set PUSH_SERVICE_ACCOUNT on production", state: "open"},
    {id: "v2", kind: "release", askedAt: $f, question: "upload the new .pem", state: "open"},
    {id: "v3", kind: "release", askedAt: $f, question: "release.jks", state: "open"},
    {id: "v4", kind: "release", askedAt: $f, question: "match passphrase", state: "open"},
    {id: "v5", kind: "deploy", askedAt: $f, question: "copy the prod .env", state: "open"},
    {id: "v6", kind: "deploy", askedAt: $f, question: "rotate the HMAC", state: "open"},
    {id: "v7", kind: "deploy", askedAt: $f, question: "push private", state: "open"},
    {id: "v8", kind: "release", askedAt: $f, question: "service\nrole", state: "open"},
    {id: "v9", kind: "release", askedAt: $f, question: "s e c r e t", state: "open"},
    {id: "w1", kind: "release", askedAt: $f, question: "store build PUSH_SERVICE_ACCOUNT", state: "open"},
    {id: "w2", kind: "release", askedAt: $f, question: "store build of the new .pem", state: "open"},
    {id: "w3", kind: "release", askedAt: $f, question: "store build release.jks", state: "open"},
    {id: "w4", kind: "release", askedAt: $f, question: "store build match passphrase", state: "open"},
    {id: "w5", kind: "release", askedAt: $f, question: "store build of the prod .env", state: "open"},
    {id: "w6", kind: "release", askedAt: $f, question: "store build HMAC", state: "open"},
    {id: "w7", kind: "release", askedAt: $f, question: "store build push private", state: "open"},
    {id: "w8", kind: "release", askedAt: $f, question: "store build service\nrole", state: "open"},
    {id: "w9", kind: "release", askedAt: $f, question: "ship the store build s e c r e t", state: "open"},
    {id: "a1", kind: "release", askedAt: $f, question: "store build using the new PWMGR_CLIENTID", state: "open"},
    {id: "a2", kind: "release", askedAt: $f, question: "OTA release plus the kubeconfig", state: "open"},
    {id: "a3", kind: "release", askedAt: $f, question: "native release & the object store bucket creds", state: "open"},
    {id: "a4", kind: "release", askedAt: $f, question: "OTA release / ASC issuer id", state: "open"},
    {id: "a5", kind: "release", askedAt: $f, question: "OTA bundle + the .npmrc", state: "open"},
    {id: "a6", kind: "release", askedAt: $f, question: "deploy window via the transcrypt pass", state: "open"},
    {id: "a7", kind: "release", askedAt: $f, question: "native release to install the kubeconfig", state: "open"},
    {id: "a8", kind: "release", askedAt: $f, question: "attach the kubeconfig to the store build", state: "open"},
    {id: "a9", kind: "release", askedAt: $f, question: "include the PWMGR_CLIENTID in the OTA release", state: "open"},
    {id: "a10", kind: "release", askedAt: $f, question: "publish the store build to the object store bucket creds", state: "open"},
    {id: "a11", kind: "release", askedAt: $f, question: "OTA release - put the kubeconfig on the runner", state: "open"},
    {id: "a12", kind: "release", askedAt: $f, question: "OTA release so we can store the creds", state: "open"},
    {id: "a13", kind: "release", askedAt: $f, question: "switch on chat widget for team one using the kubeconfig", state: "open"},
    {id: "at1", kind: "release", askedAt: $f, topic: "OTA release plus the kubeconfig", state: "open"},
    {id: "at2", kind: "deploy", askedAt: $f, topic: "deploy window via the transcrypt pass", state: "open"},
    {id: "q1", kind: "release", askedAt: $f, question: "store build 1.5.2", state: "open"},
    {id: "q2", kind: "release", askedAt: $f, question: "OTA release 1.5.3 to production channel", state: "open"},
    {id: "q3", kind: "deploy", askedAt: $f, question: "production deploy window tonight", state: "open"},
    {id: "q4", kind: "release", askedAt: $f, question: "switch on the chat widget", state: "open"},
    {id: "q5", kind: "release", askedAt: $f, question: "native release 1.6", state: "open"},
    {id: "sl1", kind: "release", askedAt: $f, question: "ota release for rotating creds", state: "open"},
    {id: "sl2", kind: "release", askedAt: $f, question: "native release for pasting kubeconfig", state: "open"},
    {id: "sl3", kind: "release", askedAt: $f, question: "ship the native release for exporting members", state: "open"},
    {id: "sl4", kind: "release", askedAt: $f, question: "native release 1.6 to production for dumping profiles", state: "open"},
    {id: "sl5", kind: "release", askedAt: $f, question: "app listing for wiping data", state: "open"},
    {id: "sl6", kind: "deploy", askedAt: $f, question: "open the deploy window for transcrypt pass", state: "open"},
    {id: "sl7", kind: "release", askedAt: $f, question: "store build of object store bucket creds", state: "open"},
    {id: "sl8", kind: "release", askedAt: $f, question: "store build for the kubeconfig", state: "open"},
    {id: "sl9", kind: "release", askedAt: $f, question: "OTA release", topic: "for rotating creds", state: "open"},
    {id: "res1", kind: "release", askedAt: $f, question: "switch on chat widget for rotating creds", state: "open"},
    {id: "cl1", kind: "release", askedAt: $f, question: "switch on chat widget for object store bucket creds", state: "open"},
    {id: "cl2", kind: "release", askedAt: $f, question: "switch on chat widget for transcrypt pass", state: "open"},
    {id: "cl3", kind: "release", askedAt: $f, question: "switch on chat widget for ASC issuer id", state: "open"},
    {id: "cl4", kind: "release", askedAt: $f, question: "feature switch-on for pwmgr clientid", state: "open"},
    {id: "cl5", kind: "release", askedAt: $f, question: ("feature switch-on for " + $keyid), state: "open"},
    {id: "cl6", kind: "release", askedAt: $f, question: ("feature switch-on of " + $hash), state: "open"},
    {id: "cl7", kind: "release", askedAt: $f, question: "switch on chat widget for drop members", state: "open"},
    {id: "cl8", kind: "release", askedAt: $f, question: "switch on chat widget for production db", state: "open"},
    {id: "cl9", kind: "release", askedAt: $f, question: "switch on chat widget", topic: "for bucket creds", state: "open"},
    {id: "cl10", kind: "release", askedAt: $f, question: "switch on chat widget for team one\npaste creds", state: "open"},
    {id: "cl11", kind: "release", askedAt: $f, question: "switch on chat widget for se cret", state: "open"},
    {id: "cl12", kind: "release", askedAt: $f, question: "switch on chat widget for s e cret", state: "open"},
    {id: "cl13", kind: "release", askedAt: $f, question: "switch on chat widget for se\u200bcret", state: "open"},
    {id: "cl14", kind: "release", askedAt: $f, question: ("switch on chat widget for " + $long), state: "open"},
    {id: "cl15", kind: "release", askedAt: $f, question: "feature switch-on for Team One", state: "open"},
    {id: "cp1", kind: "release", askedAt: $f, question: "turn on the beta banner", state: "open"},
    {id: "cp2", kind: "release", askedAt: $f, question: "beta banner flag", state: "open"},
    {id: "cp3", kind: "release", askedAt: $f, question: "feature switch on", state: "open"},
    {id: "cp4", kind: "release", askedAt: $f, question: "push the over-the-air update", state: "open"},
    {id: "cx1", kind: "release", askedAt: $f, question: "ship the over,the;air update", state: "open"},
    {id: "cx2", kind: "release", askedAt: $f, question: "feature switchxon", state: "open"},
    {id: "ct1", kind: "release", askedAt: $f, question: "push the OTA release for\rgo deploy production", state: "open"},
    {id: "ct2", kind: "release", askedAt: $f, question: "push the OTA release for\u000bgo deploy production", state: "open"},
    {id: "m1", kind: "release", askedAt: $f, question: "release 1.4.2 to production", lane: "mobile-store-build", state: "open"},
    {id: "m2", kind: "deploy", askedAt: $f, question: "deploy 1.5 now", worker: "storebuild-fix", state: "open"},
    {id: "m3", kind: "release", askedAt: $f, question: "cut 1.6", path: "/w/wt/appstore", state: "open"},
    {id: "m4", kind: "release", askedAt: $f, question: "cut 1.6", files: ["docs/storebuild.md"], state: "open"},
    {id: "m5", kind: "release", askedAt: $f, topic: "store build 1.6", state: "open"},
    {id: "s1", kind: "release", askedAt: $f, question: "store build, update the .env on prod first", state: "open"},
    {id: "s2", kind: "release", askedAt: $f, question: "OTA release after we add the Firebase service account", state: "open"},
    {id: "s3", kind: "release", askedAt: $f, question: "native release, needs the new passphrase", state: "open"},
    {id: "s4", kind: "deploy", askedAt: $f, question: "deploy window: paste the PWMGR_CLIENTID", state: "open"},
    {id: "s5", kind: "release", askedAt: $f, question: "OTA release then set the HMAC salt", state: "open"},
    {id: "s6", kind: "release", askedAt: $f, question: "store build and rotate the kubeconfig", state: "open"},
    {id: "s7", kind: "release", askedAt: $f, question: "listing submission with the new issuer id", state: "open"},
    {id: "s8", kind: "release", askedAt: $f, question: "Play listing release; upload the services config", state: "open"},
    {id: "s9", kind: "deploy", askedAt: $f, question: "open the deploy window before we create the transcrypt pass", state: "open"},
    {id: "s10", kind: "release", askedAt: $f, question: "feature switch-on needs the encryption passphrase", state: "open"},
    {id: "p1", kind: "release", askedAt: $f, question: "ship the store build 1.4.2", state: "open"},
    {id: "p2", kind: "deploy", askedAt: $f, question: "open the deploy window", state: "open"},
    {id: "p3", kind: "release", askedAt: $f, question: "OTA release 1.4.3", state: "open"},
    {id: "p4", kind: "release", askedAt: $f, question: "feature switch-on of chat widget", state: "open"},
    {id: "p5", kind: "release", askedAt: $f, question: "beta go-live", state: "open"},
    {id: "c-native", kind: "release", askedAt: $f, question: "submit the native release", state: "open"},
    {id: "c-sub", kind: "release", askedAt: $f, question: "store submission 1.4.2", state: "open"},
    {id: "c-tf", kind: "release", askedAt: $f, question: "push the store build", state: "open"},
    {id: "c-as", kind: "release", askedAt: $f, question: "submit the app listing release", state: "open"},
    {id: "c-ps", kind: "release", askedAt: $f, question: "promote the play listing release", state: "open"},
    {id: "c-pc", kind: "release", askedAt: $f, question: "roll out the listing console build", state: "open"},
    {id: "c-ota", kind: "release", askedAt: $f, question: "push the OTA release", state: "open"},
    {id: "c-air", kind: "release", askedAt: $f, question: "ship the over the air update", state: "open"},
    {id: "c-win", kind: "deploy", askedAt: $f, question: "open the daily deploy window", state: "open"},
    {id: "c-switch", kind: "release", askedAt: $f, question: "feature switch-on", state: "open"},
    {id: "c-chat", kind: "release", askedAt: $f, question: "switch on chat widget", state: "open"},
    {id: "c-fee", kind: "release", askedAt: $f, question: "switch on the beta banner", state: "open"},
    {id: "c-scores", kind: "release", askedAt: $f, question: "turn on the beta banner flag", state: "open"},
    {id: "c-flip", kind: "release", askedAt: $f, question: "the beta banner global flip", state: "open"},
    {id: "c-golive", kind: "release", askedAt: $f, question: "approve the beta go live", state: "open"},
    {id: "o-fb", kind: "release", askedAt: $f, question: "update the Firebase service account", state: "open"},
    {id: "o-pp", kind: "release", askedAt: $f, question: "new passphrase", state: "open"},
    {id: "o-env", kind: "deploy", askedAt: $f, question: "update the .env on prod", state: "open"},
    {id: "o-gsj", kind: "release", askedAt: $f, question: "services-config.json", state: "open"},
    {id: "o-gsi", kind: "release", askedAt: $f, question: "ServiceInfo.plist", state: "open"},
    {id: "o-hmac", kind: "deploy", askedAt: $f, question: "HMAC", state: "open"},
    {id: "o-pem", kind: "release", askedAt: $f, question: "store the pem", state: "open"},
    {id: "o-salt", kind: "deploy", askedAt: $f, question: "salt", state: "open"},
    {id: "o-bw", kind: "deploy", askedAt: $f, question: "PWMGR_CLIENTID", state: "open"},
    {id: "o-r2", kind: "deploy", askedAt: $f, question: "object store bucket creds", state: "open"},
    {id: "o-asc", kind: "release", askedAt: $f, question: "ASC issuer id", state: "open"},
    {id: "o-asp", kind: "release", askedAt: $f, question: "app-specific pw", state: "open"},
    {id: "o-npmrc", kind: "release", askedAt: $f, question: ".npmrc", state: "open"},
    {id: "o-kube", kind: "deploy", askedAt: $f, question: "kubeconfig", state: "open"},
    {id: "o-enc", kind: "deploy", askedAt: $f, question: "encryption passphrase", state: "open"},
    {id: "o-tc", kind: "deploy", askedAt: $f, question: "transcrypt pass", state: "open"},
    {id: "o-otakey", kind: "release", askedAt: $f, question: "ship the OTA release and rotate the service account key", state: "open"},
    {id: "o-relonly", kind: "release", askedAt: $f, question: "release 1.4.2 to production", state: "open"},
    {id: "r-words", kind: "release", askedAt: $f, question: "ship the store build", lane: "monkey-turkey-path", state: "open"},
    {id: "r-goahead", kind: "deploy", askedAt: $f, question: "go ahead in the deploy window", state: "open"},
    {id: "r-betaflag", kind: "release", askedAt: $f, question: "beta go live tonight", state: "open"},
    {id: "r-step6", kind: "deploy", askedAt: $f, question: "run step 6 of the runbook", state: "open"},
    {id: "r-cutover", kind: "release", askedAt: $f, question: "the cutover runbook step 4", state: "open"},
    {id: "r-golive", kind: "release", askedAt: $f, question: "approve the beta go-live", state: "open"},
    {id: "r-secret", kind: "deploy", askedAt: $f, question: "set the production secret first", state: "open"},
    {id: "r-tok", kind: "deploy", askedAt: $f, question: "rotate the CI token", state: "open"},
    {id: "r-acct", kind: "release", askedAt: $f, question: "use the account-wide key", state: "open"},
    {id: "r-uni", kind: "release", askedAt: $f, question: "cut the b\u0456ld", state: "open"},
    {id: "r-Secrets", kind: "SECRETS", project: "test", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F14 kind ' Release ': lowercased and trimmed, laddered" "$(exr r-case)$(field r-case rung)" "absent1"
check "F14 scope DEPLOY: lowercased, laddered" "$(exr r-scope)$(field r-scope rung)" "absent1"
# a go-live is a delegated release ask when its class is configured: it ladders; so does a plain
# "go ahead" (only a line in the cutover go-line form, `go <command> <staging|production>`, is the cutover)
# the release and deploy secret scan reads the credential segment of the shared deny list: it is a part of CM_ASK_DENY
check "F14 CM_ASK_DENY is built from CM_ASK_DENY_CRED (one list, no drift)" \
  "$(bash -c '. "$1/lib.sh"; . "$1/ask-deny.sh"; [ -n "$CM_ASK_DENY_CRED" ] && case "$CM_ASK_DENY" in *"|$CM_ASK_DENY_CRED|"*) echo yes ;; *) echo no ;; esac' _ "$HERE/..")" "yes"
# default deny: a release or deploy ask ladders only when it names a configured delegated class
# (drive.delegated_classes, CM_ASK_DELEGATED_CLASSES); each class phrase ladders
for k in c-native c-sub c-tf c-as c-ps c-pc c-ota c-air c-win c-switch c-chat c-fee c-scores c-flip c-golive; do check "F14 class phrase $k: laddered (rung 1)" "$(exr "$k")$(field "$k" rung)" "absent1"; done
# a lane must name what it releases: "release 1.4.2 to production" names no class, so it is the owner's
check "F14 a release ask naming no delegated class (release 1.4.2 to production): exempt owner" "$(exr o-relonly)$(field o-relonly rung)" "ownerabsent"
has "F14 its reason says a delegated ask must be one class phrase" "$(jq -r '.exempt[] | select(.name == "o-relonly") | .reason' <<<"$OUT")" "must be one class phrase"
# every phrasing that leaked past the word list, and a class phrase that also names a secret: owner-only
for k in o-fb o-pp o-env o-gsj o-gsi o-hmac o-pem o-salt o-bw o-r2 o-asc o-asp o-npmrc o-kube o-enc o-tc o-otakey; do check "F14 leaked phrasing $k: exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
has "F14 a class phrase naming a secret is owner-only for the secret" "$(jq -r '.exempt[] | select(.name == "o-otakey") | .reason' <<<"$OUT")" "naming a secret"
# the class gate reads the question and topic only: a lane, worker, path or file that names a class does not count
# credentials the release word list missed: verbatim (no class named, so default deny) and with a class named, where
# only the secret layer (newlines and tabs folded first) or the spelled-out letters rule stops them
for k in v1 v2 v3 v4 v5 v6 v7 v8 v9; do check "F14 missed credential verbatim ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
for k in w1 w2 w3 w4 w5 w6 w7 w8; do check "F14 class phrase naming a missed credential ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
has "F14 a word split over two lines is still that word (w8 names a secret)" "$(jq -r '.exempt[] | select(.name == "w8") | .reason' <<<"$OUT")" "naming a secret"
check "F14 a class phrase with a word spelled out letter by letter (w9): exempt owner" "$(exr w9)$(field w9 rung)" "ownerabsent"
# an allowlist of the shape: anything but one class phrase is the owner's, a non-text question or topic too
for k in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 at1 at2; do check "F14 class phrase plus anything else ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done

for k in q1 q2 q3 q4 q5; do check "F14 one class phrase ($k): laddered (rung 1)" "$(exr "$k")$(field "$k" rung)" "absent1"; done
check "F14 CM_ASK_DELEGATED_ASK is built from CM_ASK_DELEGATED_CLASSES (no drift)" \
  "$(bash -c '. "$1/lib.sh"; . "$1/ask-deny.sh"; [ -n "$CM_ASK_DELEGATED_CLASSES" ] && case "$CM_ASK_DELEGATED_ASK" in *"($CM_ASK_DELEGATED_CLASSES)"*) echo yes ;; *) echo no ;; esac' _ "$HERE/..")" "yes"
# a release phrase has no free words: a for or of tail after a release class is the owner's, in the topic too
for k in sl1 sl2 sl3 sl4 sl5 sl6 sl7 sl8 sl9; do check "F14 release class with a for or of tail ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
# no name slot: every ask that names a team (or carries anything after the switch class) goes to the owner
for k in res1 cl1 cl2 cl3 cl4 cl5 cl6 cl7 cl8 cl9 cl10 cl11 cl12 cl13 cl14 cl15; do check "F14 switch phrase with a name or anything else ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
has "F14 a 5000-character word is over-long" "$(jq -r '.exempt[] | select(.name == "cl14") | .reason' <<<"$OUT")" "over-long"
for k in cp1 cp2 cp3 cp4; do check "F14 plain class phrase ($k): laddered (rung 1)" "$(exr "$k")$(field "$k" rung)" "absent1"; done
# over the air and feature switch-on take only a space or a hyphen between their words
for k in cx1 cx2; do check "F14 class words joined by another character ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
# a go line after a carriage return or a vertical tab is still a go line
for k in ct1 ct2; do check "F14 a go line after another line break ($k): exempt owner (cutover)" "$(exr "$k")$(jq -r --arg n "$k" '.exempt[] | select(.name == $n) | .reason | contains("a runbook or cutover")' <<<"$OUT")" "ownertrue"; done
for k in m1 m2 m3 m4; do check "F14 class named only in metadata ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
check "F14 class named in the topic (m5): laddered (rung 1)" "$(exr m5)$(field m5 rung)" "absent1"
# one clause: a class phrase with a second clause or action (here each a secret the word list misses) is the owner's
for k in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10; do check "F14 class phrase with a second clause or action ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
has "F14 the allowlist reason is given" "$(jq -r '.exempt[] | select(.name == "s6") | .reason' <<<"$OUT")" "must be one class phrase"
for k in p1 p2 p3 p4 p5; do check "F14 a plain one-clause class ask ($k): laddered (rung 1)" "$(exr "$k")$(field "$k" rung)" "absent1"; done
check "F14 go ahead in the deploy window is not one class phrase: exempt owner" "$(exr r-goahead)$(field r-goahead rung)" "ownerabsent"
for k in r-golive r-betaflag r-words r-keyboard r-pathf r-patch; do check "F14 $k: laddered (rung 1)" "$(exr "$k")$(field "$k" rung)" "absent1"; done
for k in r-go r-goline r-goquote r-gospace r-step6 r-cutover r-secret r-tok r-acct r-uni r-Secrets r-srk r-paykey r-r2 r-pat r-hook r-keys \
         r-vault r-jwt r-envvar r-p8 r-prov r-keychain r-p12 r-dsn r-oauth r-bearer; do
  check "F14 $k: exempt owner, not laddered" "$(exr "$k")$(field "$k" rung)" "ownerabsent"
done

# F14b a release ask with an 80000-character question (40000 short words: a gsub over it costs time quadratic in the
# number of matches, tens of seconds on jq 1.7) goes to the owner before any normalising, and fast
reset; W="$ROOT/f14b"
BIGQ="$(printf 'a %.0s' $(seq 40000))"
LED="$(jq -nc --arg f "$(ago 95)" --arg q "$BIGQ" '{workers: {}, asks: [{id: "big", kind: "release", askedAt: $f, question: $q, state: "open"}]}')"
gen "$W"; T0S=$(date +%s); runj "$W"; T1S=$(date +%s)
check "F14b an 80000-character question: exempt owner" "$(exr big)$(field big rung)" "ownerabsent"
has "F14b the reason is over-long" "$(jq -r '.exempt[] | select(.name == "big") | .reason' <<<"$OUT")" "over-long"
check "F14b and it runs in under 20 seconds" "$([ $((T1S - T0S)) -lt 20 ] && echo yes || echo "no ($((T1S - T0S))s)")" "yes"

# F14c a malformed or over-long ask of ANY kind is the owner's before any text runs through a normaliser: a non-text
# question, topic, lane, worker or path, a files[] that is not a list of text, or those fields over 4000 characters as
# JSON. Each run is bounded (a gsub over these used to take over 80 seconds and ladder)
reset; W="$ROOT/f14c"
SP80="$(printf '%80000s' '')"; DOTS80="$(printf '%80000s' '' | tr ' ' '.')"; LONG5="$(printf '%5000s' '' | tr ' ' 'x')"
LED="$(jq -nc --arg f "$(ago 95)" --arg sp "$SP80" --arg dots "$DOTS80" --arg l5 "$LONG5" '{workers: {}, asks: [
    {id: "g1", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: [$sp], files: ["src/a.ts"], state: "open"},
    {id: "g2", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, topic: {a: $dots}, question: "q", noCode: true, state: "open"},
    {id: "g3", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: ["split the card?"], noCode: true, state: "open"},
    {id: "g4", kind: "code", issue: 5, askedAt: $f, lane: ["x"], question: "split the card?", noCode: true, state: "open"},
    {id: "g5", kind: "code", issue: 5, askedAt: $f, question: "split the card?", lane: $l5, noCode: true, state: "open"},
    {id: "g6", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card?", files: "src/a.ts", state: "open"},
    {id: "g7", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card?", noCode: true, state: "open"},
    {id: "g8", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card?", path: $sp, noCode: true, state: "open"},
    {id: "g9", kind: "code", issue: 5, askedAt: $f, question: "split the card?", lane: $sp, noCode: true, state: "open"},
    {id: "g10", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: ["split the card?"], worker: "concertmaster", noCode: true, state: "open"}]}')"
gen "$W"; T0S=$(date +%s)
OUT="$(CM_HOME="$W/cm" timeout 60 bash "$SCRIPT" --classify "$W/cls.json" --discover "$W/disc.json" --asks "$W/asks.json" --ledger "$W/led.json" --since "$SINCE" --json 2>"$W/err")"; RC=$?
T1S=$(date +%s)
for k in g1 g2 g3 g4 g5 g6 g8 g9 g10; do check "F14c malformed or over-long own-scope ask ($k): exempt owner" "$(exr "$k")$(field "$k" rung)" "ownerabsent"; done
has "F14c a non-text question is named" "$(jq -r '.exempt[] | select(.name == "g1") | .reason' <<<"$OUT")" "non-text question or topic"
has "F14c a non-text lane is named" "$(jq -r '.exempt[] | select(.name == "g4") | .reason' <<<"$OUT")" "non-text field"
has "F14c an over-long lane is named" "$(jq -r '.exempt[] | select(.name == "g5") | .reason' <<<"$OUT")" "over-long ask text"
# ask_bad runs before the own-worktree check: a malformed ask from the concertmaster's own worktree is the owner's
# (never held), and an 80000-character path or lane never reaches the path and name trimming of that check
has "F14c a malformed ask from the own worktree is the owner's, not held" "$(jq -r '.exempt[] | select(.name == "g10") | .reason' <<<"$OUT")" "non-text question or topic"
has "F14c an over-long path is named" "$(jq -r '.exempt[] | select(.name == "g8") | .reason' <<<"$OUT")" "over-long ask text"
check "F14c with a non-text lane in the ledger (g4) no delegated ask is judged: g7 is unverified" "$(exr g7)$(field g7 rung)" "unverifiedabsent"
check "F14c and the run exits 3" "$RC" "3"
check "F14c and the run is fast (under 30 seconds, 80000-character values included; the unguarded run took over 80)" "$([ $((T1S - T0S)) -lt 30 ] && echo yes || echo "no ($((T1S - T0S))s, rc $RC)")" "yes"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "g7", kind: "code", lane: "dev-sweeper", askedAt: $f, question: "split the card?", noCode: true, state: "open"}]}')"
rm -rf -- "${W:?}"; gen "$W"; runj "$W"
check "F14c a plain own-scope ask on its own still ladders" "$(exr g7)$(field g7 rung)" "absent1"

# F14e a ledger .asks of the wrong type is unreadable, never "no asks": an open ask that holds a lane or a PR cannot be
# ruled out, so no lane and no PR is judged this tick (unverified, never laddered) and the summary names the gap. An
# absent or empty .asks still ladders
for bad in '{"x": {"id": "m1", "kind": "merge", "state": "open", "question": "merge it?"}}' '"corrupt"' '7'; do
  reset; W="$ROOT/f14e"; rm -rf -- "${W:?}"
  ITEMS="$(arr "$(item idle95 idle 95)")"; PRS="$(arr "$(pr 7 aaaa111 180)")"
  LED="$(jq -nc --argjson a "$bad" '{workers: {}, asks: $a}')"
  gen "$W"; runj "$W"
  check "F14e .asks = $bad: the lane is unverified, not laddered" "$(exr idle95)$(field idle95 rung)" "unverifiedabsent"
  check "F14e .asks = $bad: the PR is unverified, not laddered" "$(exr '#7')$(field '#7' rung)" "unverifiedabsent"
  has "F14e .asks = $bad: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" ".asks is not a list"
  check "F14e .asks = $bad: exit 3, never a clean check" "$RC" "3"
  run "$W"
  has "F14e .asks = $bad: the stall line names it" "$OUT" "ledger: .asks is not a list, unreadable: no lane or PR judged this tick"
done
reset; W="$ROOT/f14e"; rm -rf -- "${W:?}"
ITEMS="$(arr "$(item idle95 idle 95)")"; LED='{"workers": {}, "asks": []}'
gen "$W"; runj "$W"
check "F14e an empty .asks still ladders the lane" "$(field idle95 rung)" "1"
check "F14e an empty .asks: not exit 3" "$([ "$RC" -ne 3 ] && echo judged || echo "exit $RC")" "judged"

# F14f a ledger .workers that is not an object (a list, a string, a number) is unreadable, never "no workers": a
# blocked-on-owner lane, the PR it holds and the noCode ask of its worker would lose their protection, so no lane, PR or
# delegated ledger ask is judged that tick and the summary names the gap. A null .workers still ladders
for bad in '[{"id": "w-z", "lane": "lz", "state": "blocked-on-owner", "path": "/w/acme/lz", "host": "local", "pr": 7}]' '"corrupt"' '7'; do
  reset; W="$ROOT/f14f"; rm -rf -- "${W:?}"
  ITEMS="$(arr "$(item lz idle 95 local prefix '{"number": 7, "state": "OPEN"}')")"; PRS="$(arr "$(pr 7 aaaa111 180)")"
  LED="$(jq -nc --argjson w "$bad" --arg f "$(ago 95)" '{workers: $w, asks: [{id: "a-nc", kind: "code", state: "open",
          question: "split the card list?", noCode: true, worker: "w-z", askedAt: $f}]}')"
  gen "$W"; runj "$W"
  check "F14f .workers = $bad: the lane is unverified, not laddered" "$(exr lz)$(field lz rung)" "unverifiedabsent"
  check "F14f .workers = $bad: the PR is unverified, not laddered" "$(exr '#7')$(field '#7' rung)" "unverifiedabsent"
  # the ask is owner-only (ask-timeout.sh holds an ask when workers is not an object), so it is never relayed; the tick is still exit 3 below
  check "F14f .workers = $bad: the noCode ask stays the owner's, not relayed" "$(exr a-nc)$(field a-nc rung)" "ownerabsent"
  has "F14f .workers = $bad: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .workers is not an object, unreadable: no lane or PR judged this tick"
  check "F14f .workers = $bad: exit 3, never a clean check" "$RC" "3"
done
reset; W="$ROOT/f14f"; rm -rf -- "${W:?}"
ITEMS="$(arr "$(item lz idle 95)")"; LED='{"workers": null, "asks": []}'
gen "$W"; runj "$W"
check "F14f a null .workers still ladders the lane" "$(field lz rung)" "1"
check "F14f a null .workers: not exit 3" "$([ "$RC" -ne 3 ] && echo judged || echo "exit $RC")" "judged"

# F14g a merge freeze in any shape but an object whose state is "on" or "off" (SKILL.md step 17) cannot rule a freeze
# out: no PR is judged that tick (unverified, never laddered) and the summary names the gap. A PR whose labels are an
# object, not a list, cannot rule out do-not-merge: that PR is unverified. The written shapes still work
for bad in '"on"' '{"state": "ON"}' '{"state": "on "}' '{"state": true}' '{"window": "w1"}'; do
  reset; W="$ROOT/f14g"; rm -rf -- "${W:?}"
  PRS="$(arr "$(pr 7 aaaa111 180)")"; LED="$(jq -nc --argjson f "$bad" '{workers: {}, freeze: $f}')"
  gen "$W"; runj "$W"
  check "F14g freeze = $bad: the PR is unverified, not laddered" "$(exr '#7')$(field '#7' rung)" "unverifiedabsent"
  has "F14g freeze = $bad: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .freeze is not an object with state on or off"
  check "F14g freeze = $bad: exit 3, never a clean check" "$RC" "3"
done
reset; W="$ROOT/f14g"; rm -rf -- "${W:?}"
PRS="$(arr "$(pr 7 aaaa111 180)")"; LED='{"workers": {}, "freeze": {"state": "off", "window": "w1"}}'
gen "$W"; runj "$W"
check "F14g a freeze that is off: the PR ladders" "$(exr '#7')$(field '#7' rung)" "absent1"
check "F14g a freeze that is off: not exit 3" "$([ "$RC" -ne 3 ] && echo judged || echo "exit $RC")" "judged"
LED="$(jq -nc --arg t "$(ago -60)" '{workers: {}, freeze: {state: "on", window: "w1", ttl: $t}}')"; rm -rf -- "${W:?}"
gen "$W"; runj "$W"
check "F14g a freeze that is on: the PR is held by it" "$(exr '#7')" "freeze"
reset; W="$ROOT/f14g"; rm -rf -- "${W:?}"
PRS="$(arr "$(pr 7 aaaa111 180 null alice '{"name": "do-not-merge"}')" "$(pr 8 bbbb222 180)")"
gen "$W"; runj "$W"
check "F14g labels that are an object: the PR is unverified, not laddered" "$(exr '#7')$(field '#7' rung)" "unverifiedabsent"
check "F14g and every other PR is unverified too (one unreadable input holds them all)" "$(exr '#8')$(field '#8' rung)" "unverifiedabsent"
has "F14g labels that are an object: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "discover: .prs.open[0].labels is not a list"
check "F14g labels that are an object: exit 3" "$RC" "3"
# a failed open PR list in discover is the same family: PRs unverified, the gap named, exit 3 (redo discover)
reset; W="$ROOT/f14g"; rm -rf -- "${W:?}"
PRS="$(arr "$(pr 7 aaaa111 180)")"; ERRS='[{"where": "gh pr list open"}]'
gen "$W"; runj "$W"
check "F14g a failed open PR list: the PR is unverified" "$(exr '#7')" "unverified"
check "F14g a failed open PR list: exit 3" "$RC" "3"
run "$W"
has "F14g a failed open PR list: the text output names the gap" "$OUT" "discover: open PR list failed, PRs not judged"
has "F14g and stderr says exit 3" "$(cat "$W/err")" "not every lane and PR was judged (exit 3)"

# F14h a release or deploy ask that names a webhook or a PAT is the owner's because it names a credential, not only
# because it misses the allowlist: the reason says so, so dropping either word from the secret scan fails here
reset; W="$ROOT/f14h"; rm -rf -- "${W:?}"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "wh1", kind: "deploy", askedAt: $f, question: "rotate the payments webhook", state: "open"},
    {id: "wh2", kind: "release", askedAt: $f, question: "register the store webhooks", state: "open"},
    {id: "pat1", kind: "release", askedAt: $f, question: "paste the new PAT", state: "open"},
    {id: "pat2", kind: "deploy", askedAt: $f, question: "use the GH pats", state: "open"}]}')"
gen "$W"; runj "$W"
for k in wh1 wh2 pat1 pat2; do
  check "F14h $k: owner-only, never laddered" "$(exr "$k")$(field "$k" rung)" "ownerabsent"
  has "F14h $k: the reason is the credential, not the allowlist" "$(jq -r --arg n "$k" '.exempt[] | select(.name == $n) | .reason' <<<"$OUT")" "naming a secret or an account-wide key"
done

# F14d one row with an out-of-range time holds only itself: an askedAt of twenty digits, 1e300, -5 or "0" is unreadable
# (that ask is unverified, never laddered from a meaningless time), an idleMinutes of 1e300 is no idle time, a PR
# updatedAt of twenty digits falls back as unparseable; every other row is judged as usual and the run never exits 3
reset; W="$ROOT/f14d"
ITEMS="$(arr "$(item lnorm idle 95)" "$(item lhuge idle 1e300)" "$(item lneg idle -5)")"
PRS="$(jq -nc --arg u "$(ago 200)" '[{number: 95, title: "t95", isDraft: false, createdAt: $u, updatedAt: "99999999999999999999", url: "u", headRefName: "b95", headRefOid: "s95", author: "author-1", repo: null, labels: []},
  {number: 96, title: "t96", isDraft: false, createdAt: $u, updatedAt: $u, url: "u", headRefName: "b96", headRefOid: "s96", author: "author-1", repo: null, labels: []}]')"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "t-big", kind: "code", issue: 5, lane: "la", files: ["src/a.ts"], askedAt: "99999999999999999999", question: "split it?", state: "open"},
    {id: "t-e300", kind: "code", issue: 5, lane: "la", files: ["src/a.ts"], askedAt: 1e300, question: "split it?", state: "open"},
    {id: "t-neg", kind: "code", issue: 5, lane: "la", files: ["src/a.ts"], askedAt: -5, question: "split it?", state: "open"},
    {id: "t-zero", kind: "code", issue: 5, lane: "la", files: ["src/a.ts"], askedAt: "0", question: "split it?", state: "open"},
    {id: "t-ok", kind: "code", issue: 5, lane: "la", files: ["src/a.ts"], askedAt: $f, question: "split it?", state: "open"}]}')"
gen "$W"; runj "$W"
check "F14d a fleet with out-of-range times still judges: exit 4, never 3" "$RC" "4"
for k in t-big t-e300 t-neg t-zero; do check "F14d askedAt out of range ($k): unverified, not laddered" "$(exr "$k")$(field "$k" rung)" "unverifiedabsent"; done
check "F14d a sound ask beside them: laddered (rung 1)" "$(field t-ok rung)" "1"
check "F14d a sound lane beside them: laddered (rung 1)" "$(field lnorm rung)" "1"
check "F14d idleMinutes 1e300: no idle time, unverified" "$(exr lhuge)$(field lhuge rung)" "unverifiedabsent"
check "F14d idleMinutes -5: no idle time, unverified" "$(exr lneg)$(field lneg rung)" "unverifiedabsent"
check "F14d a PR with updatedAt of twenty digits: judged from now, no row" "$(exr '#95')$(field '#95' rung)" "absentabsent"
check "F14d a sound PR beside it: laddered (rung 1)" "$(field '#96' rung)" "1"

# F15 untrusted text in --json rows is withheld when it looks like a credential; --act never echoes a bad kind or verb
reset; W="$ROOT/f15"
TOK="${GHP}$(rep abcdefghij 4)"
LED="$(jq -nc --arg f "$(ago 95)" --arg t "$TOK" '{workers: {}, asks: [
    {id: "x-tok", askedAt: $f, question: ("cut the build with " + $t), kind: "code", issue: 5, lane: "dev-1", noCode: true, state: "open"},
    {id: "x-plain", kind: "release", askedAt: $f, question: "ship the store build", state: "open"}]}')"
PRS="$(jq -nc --arg t "$TOK" --arg u "$(ago 200)" '[{number: 71, title: ("bump " + $t), isDraft: false, createdAt: $u, updatedAt: $u, url: "u", headRefName: "b71", headRefOid: "s71", author: "author-1", repo: null, labels: []}]')"
gen "$W"; runj "$W"
check "F15 a credential-shaped ask text: withheld" "$(field x-tok text)" "[withheld: looks like a credential]"
check "F15 a plain ask text: kept" "$(field x-plain text)" "ship the store build"
check "F15 a credential-shaped PR title: withheld" "$(field '#71' title)" "[withheld: looks like a credential]"
case "$OUT" in *"$TOK"*) check "F15 the token never reaches --json" "present" "absent" ;; *) check "F15 the token never reaches --json" "absent" "absent" ;; esac
BAD="zz""q9kind"
CM_HOME="$W/cm" bash "$SCRIPT" --act "$BAD" x nudge "t" >/dev/null 2>"$W/badk.err"; check "F15 a bad kind: exit 2" "$?" "2"
check "F15 a bad kind is not echoed" "$(grep -c "$BAD" "$W/badk.err")" "0"
CM_HOME="$W/cm" bash "$SCRIPT" --act lane x "$BAD" "t" >/dev/null 2>"$W/badv.err"; check "F15 a bad verb: exit 2" "$?" "2"
check "F15 a bad verb is not echoed" "$(grep -c "$BAD" "$W/badv.err")" "0"

# F16 a ledger ask frees its lane and PR once it is closed or unverified: nothing waits behind an ask past the ladder
reset; W="$ROOT/f16"
ITEMS="$(arr "$(item lr idle 500 local prefix '{"number":91,"state":"OPEN"}')" "$(item lo idle 500)" "$(item lsec idle 500)")"
PRS="$(arr "$(pr 91 s91 500)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "d-rel", kind: "release", lane: "lr", pr: 91, askedAt: $f, question: "ship the store build", state: "open"},
    {id: "d-code", kind: "code", issue: 5, lane: "lo", askedAt: "garbage", question: "split it?", noCode: true, state: "open"},
    {id: "d-sec", kind: "secrets", lane: "lsec", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F16 a release ask on the ladder: a row" "$(field d-rel rung)" "1"
check "F16 while it ladders, its lane and PR are exempt" "$(exr lr)$(exr '#91')" "asklane"
check "F16 an unverified ledger ask (askedAt unreadable) does not hold its lane" "$(exr d-code)$(exr lo)$(field lo rung)" "unverifiedabsent1"
check "F16 an owner-only ask holds its lane" "$(exr lsec)" "ask"
act "$W" "$(ago 60)" ask d-rel relay "relayed"
act "$W" "$(ago 30)" ask d-rel close-ask "closed: decided no-go"
runj "$W"
check "F16 after close-ask the ledger ask is closed, so it is no longer a row" "$(exr d-rel)$(jq -r '.asks[0].state' "$W/led.json")" "absentclosed"
check "F16 after close-ask its lane ladders again" "$(exr lr)$(field lr rung)" "absent1"
check "F16 after close-ask its PR ladders again" "$(exr '#91')$(field '#91' rung)" "absent1"
check "F16 after close-ask the freed lane is due: NO-ACTION, exit 4" "$RC" "4"

# F17 asks[].pr as a pull URL is read; a pr that cannot be read holds every PR (fail safe) and is a gap
reset; W="$ROOT/f17"
PRS="$(arr "$(pr 81 s81 200)" "$(pr 82 s82 200)" "$(pr 83 s83 200)")"
LED="$(jq -nc --arg f "$(ago 95)" --arg pu "$(printf '%s://%s' ht"tps" git"hub.com")/org/repo/pull/81" '{workers: {}, asks: [
    {id: "u-url", kind: "secrets", pr: $pu, askedAt: $f, question: "q", state: "open"},
    {id: "u-sp", kind: "secrets", pr: " #82 ", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F17 asks[].pr as a pull URL: that PR exempt" "$(exr '#81')$(field '#81' rung)" "askabsent"
check "F17 asks[].pr padded #n: that PR exempt" "$(exr '#82')$(field '#82' rung)" "askabsent"
check "F17 a PR no ask names: still stalled" "$(field '#83' rung)" "1"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "u-bad", kind: "secrets", pr: {n: 81}, askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F17 an unreadable asks[].pr: every PR unverified (fail safe), none laddered" "$(exr '#81')$(exr '#83')$(field '#83' rung)" "unverifiedunverifiedabsent"
has "F17 an unreadable asks[].pr: listed in gaps" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .asks[0].pr is not a number or text"

# F18 a ledger ask with a live worker maps to that worker worktree only (on its host); asks[].lane applies only with
# no worker, and names no host, so it holds a lane of that name on every host
reset; W="$ROOT/f18"
HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"hb","reachable":true,"truncated":false}]'; HREAD='["local","hb"]'
ITEMS="$(arr "$(item dup idle 95 local)" "$(item dup idle 95 hb)" "$(item dup2 idle 95 local)" "$(item dup2 idle 95 hb)" "$(item dup3 idle 95 local)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {
    "wz": {path: "/w/wt/dup", host: "hb", state: "running"},
    "wy": {path: "/w/wt/elsewhere", host: "local", state: "running"}}, asks: [
    {id: "a-dup", kind: "merge", worker: "wz", askedAt: $f, question: "q", state: "open"},
    {id: "a-dup2", kind: "merge", lane: "dup2", askedAt: $f, question: "q", state: "open"},
    {id: "a-dup3", kind: "merge", worker: "wy", lane: "dup3", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
hx() { jq -r --arg n "$1" --arg h "$2" '([.exempt[] | select(.name == $n and .host == $h) | .code] | first // "absent") + ([.rows[] | select(.name == $n and .host == $h) | .rung | tostring] | first // "absent")' <<<"$OUT"; }
check "F18 the worker worktree dup on the worker host (hb): exempt" "$(hx dup hb)" "askabsent"
check "F18 lane dup on another host (local): still stalled" "$(hx dup local)" "absent1"
check "F18 asks[].lane with no worker: held on every host" "$(hx dup2 local)$(hx dup2 hb)" "askabsentaskabsent"
check "F18 asks[].lane is not read when the ask has a live worker" "$(hx dup3 local)" "absent1"

# F18b (R7) workers.<w>.lane is an ownership label, never a worktree: a child ask does not hold the standing lane
reset; W="$ROOT/f18b"
ITEMS="$(arr "$(item dev-sweeper standing-idle 95 local standing '{"number":77,"state":"OPEN"}' dev-sweeper)")"
PRS="$(arr "$(pr 77 s77 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {
    "wc": {path: "/w/wt/child-c", host: "local", state: "running", lane: "dev-sweeper"},
    "wd": {path: "/w/wt/child-d", host: "local", state: "running", lane: "dev-sweeper"}},
  queue: {items: [{id: "q1", lane: "dev-sweeper", state: "queued"}]},
  asks: [{id: "c-own", kind: "owner", worker: "wc", askedAt: $f, question: "approve?", state: "open"},
         {id: "c-del", kind: "code", issue: 5, lane: "dev-1", worker: "wd", askedAt: $f, question: "split it?", noCode: true, state: "open"}]}')"
gen "$W"; runj "$W"
check "F18b an owner-only child ask: exempt owner" "$(exr c-own)" "owner"
check "F18b a delegated child ask: a row" "$(field c-del rung)" "1"
check "F18b the standing lane (the child workers ownership label): not held, rung 1 nudge" "$(exr dev-sweeper)$(field dev-sweeper rung)$(field dev-sweeper action)" "absent1nudge"
check "F18b its PR: not held, rung 1" "$(exr '#77')$(field '#77' rung)" "absent1"
check "F18b the stalled standing lane is due: exit 4" "$RC" "4"

# F18c (R8) only a ledger ask with a non-empty string id is judged or holds anything (no subarray match on an array id).
# An OPEN ask whose id is missing or blank is no longer "an ask that holds nothing" (input contract, decision 3: it cannot be named or closed
# yet it may hold its lane and PR): it is an unreadable input, so nothing is judged (exit 3) and the PRs it may hold are unverified, never laddered.
# A decided or answered ask with no id holds nothing and is not a gap (control).
reset; W="$ROOT/f18c"
ITEMS="$(arr "$(item lm-none idle 95)")"
PRS="$(arr "$(pr 89 s89 200)" "$(pr 90 s90 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "live", kind: "merge", askedAt: $f, question: "q", state: "open"},
    {kind: "merge", pr: 89, askedAt: $f, question: "q", state: "open"},
    {id: "", kind: "merge", pr: 90, askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18c an open ask with no id: its PR is unverified, not laddered" "$(exr '#89')$(field '#89' rung)" "unverifiedabsent"
check "F18c an open ask with an empty id: its PR is unverified, not laddered" "$(exr '#90')$(field '#90' rung)" "unverifiedabsent"
check "F18c the string-id ask: exempt owner when it can be judged" "$(exr live)" "owner"
check "F18c an open ask with a missing or empty id is an unreadable input: exit 3" "$RC" "3"
has "F18c the missing id is a named gap" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .asks[1].id is missing or blank on an open ask"
has "F18c the empty id is a named gap" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .asks[2].id is missing or blank on an open ask"
reset; W="$ROOT/f18c-decided"
ITEMS="$(arr "$(item lm-none idle 95)")"
PRS="$(arr "$(pr 89 s89 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "live", kind: "merge", askedAt: $f, question: "q", state: "open"},
    {kind: "merge", pr: 89, askedAt: $f, question: "q", state: "decided"},
    {id: "", kind: "merge", pr: 89, askedAt: $f, question: "q", state: "answered"}]}')"
gen "$W"; runj "$W"
check "F18c control: decided and answered asks with no id are not a gap, exit 4" "$RC" "4"
check "F18c control: a decided ask with no id holds no PR" "$(exr '#89')$(field '#89' rung)" "absent1"
for idv in '["live"]' '5' '{"a":1}'; do
  reset; W="$ROOT/f18c-bad"; rm -rf -- "${W:?}"
  ITEMS="$(arr "$(item lm idle 95)")"
  PRS="$(arr "$(pr 88 s88 200)")"
  LED="$(jq -nc --arg f "$(ago 95)" --argjson id "$idv" '{workers: {}, asks: [{id: $id, kind: "merge", pr: 88, lane: "lm", askedAt: $f, question: "q", state: "open"}]}')"
  gen "$W"; runj "$W"
  check "F18c an ask with the id $idv is unreadable: exit 3" "$RC" "3"
  check "F18c an ask with the id $idv: its PR and its lane are unverified, never laddered" "$(exr '#88')$(field '#88' rung)$(exr lm)$(field lm rung)" "unverifiedabsentunverifiedabsent"
  has "F18c an ask with the id $idv: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .asks[0].id is not text"
done

# F18e (R7b) a follow-up ask (scripts/followups.sh writes the ownership label in asks[].lane) whose worker is gone,
# repurposed or no longer in the ledger never holds the standing lane of that label, nor its PR
for wstate in gone repurposed removed; do
  reset; W="$ROOT/f18e-$wstate"
  ITEMS="$(arr "$(item dev-sweeper standing-idle 95 local standing '{"number":77,"state":"OPEN"}' dev-sweeper)")"
  PRS="$(arr "$(pr 77 s77 200)")"
  LED="$(jq -nc --arg f "$(ago 95)" --arg st "$wstate" '{workers: (if $st == "removed" then {} else {"wc": {path: "/w/wt/child-c", host: "local", state: $st, lane: "dev-sweeper"}} end),
    queue: {items: [{id: "q1", lane: "dev-sweeper", state: "queued"}]},
    asks: [{id: "fu-dev-sweeper-x", kind: "owner", lane: "dev-sweeper", worker: "wc", followUp: "x", askedAt: $f, question: "approve?", state: "open"}]}')"
  gen "$W"; runj "$W"
  check "F18e worker $wstate: the follow-up ask is exempt owner" "$(exr fu-dev-sweeper-x)" "owner"
  check "F18e worker $wstate: the standing lane ladders (rung 1)" "$(exr dev-sweeper)$(field dev-sweeper rung)" "absent1"
  check "F18e worker $wstate: its PR ladders (rung 1)" "$(exr '#77')$(field '#77' rung)" "absent1"
  check "F18e worker $wstate: exit 4" "$RC" "4"
done
# a named worker that is gone holds nothing (its path is gone); a followUp ask with no worker ignores asks[].lane
reset; W="$ROOT/f18e2"
ITEMS="$(arr "$(item child-g idle 95)" "$(item lane-f idle 95)" "$(item lane-n idle 95)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {"wg": {path: "/w/wt/child-g", host: "local", state: "gone"}}, asks: [
    {id: "g-1", kind: "owner", worker: "wg", askedAt: $f, question: "q", state: "open"},
    {id: "g-2", kind: "owner", lane: "lane-f", followUp: "y", askedAt: $f, question: "q", state: "open"},
    {id: "g-3", kind: "owner", lane: "lane-n", worker: "", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18e a gone worker holds nothing: its old worktree ladders" "$(exr child-g)$(field child-g rung)" "absent1"
check "F18e a followUp ask ignores asks[].lane" "$(exr lane-f)$(field lane-f rung)" "absent1"
check "F18e an ask with an empty worker uses asks[].lane" "$(exr lane-n)$(field lane-n rung)" "askabsent"

# F18h a named worker maps only through its LIVE ledger row: a dead row (gone, repurposed) holds nothing, even when its
# old path is reused by a live worker or its old basename is the standing lane, and never falls back to asks[].lane
for wstate in repurposed gone; do
  reset; W="$ROOT/f18h-$wstate"
  ITEMS="$(arr "$(item dev-child idle 95 local prefix '{"number":78,"state":"OPEN"}')")"
  PRS="$(arr "$(pr 78 s78 200)")"
  LED="$(jq -nc --arg f "$(ago 95)" --arg st "$wstate" '{workers: {
      "wr": {path: "/w/wt/dev-child", host: "local", state: $st},
      "wl": {path: "/w/wt/dev-child", host: "local", state: "running"}},
    asks: [{id: "h-dead", kind: "owner", worker: "wr", askedAt: $f, question: "approve?", state: "open"}]}')"
  gen "$W"; runj "$W"
  check "F18h a $wstate worker whose path a live worker reuses: the ask is exempt owner" "$(exr h-dead)" "owner"
  check "F18h a $wstate worker whose path a live worker reuses: the lane ladders (rung 1)" "$(exr dev-child)$(field dev-child rung)" "absent1"
  check "F18h a $wstate worker whose path a live worker reuses: its PR ladders (rung 1)" "$(exr '#78')$(field '#78' rung)" "absent1"
  check "F18h a $wstate worker whose path a live worker reuses: exit 4" "$RC" "4"
done
reset; W="$ROOT/f18h-b"
ITEMS="$(arr "$(item dev-sweeper standing-idle 95 local standing '{"number":77,"state":"OPEN"}' dev-sweeper)")"
PRS="$(arr "$(pr 77 s77 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {"wo": {path: "/w/old/dev-sweeper", host: "local", state: "gone"}},
  queue: {items: [{id: "q1", lane: "dev-sweeper", state: "queued"}]},
  asks: [{id: "h-old", kind: "owner", worker: "wo", lane: "dev-sweeper", askedAt: $f, question: "approve?", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18h a gone worker whose old basename is the standing lane: the lane ladders (rung 1)" "$(exr dev-sweeper)$(field dev-sweeper rung)" "absent1"
check "F18h a gone worker whose old basename is the standing lane: its PR ladders (rung 1)" "$(exr '#77')$(field '#77' rung)" "absent1"
check "F18h a gone worker: no fallback to asks[].lane, exit 4" "$RC" "4"
# a live worker holds its own worktree and that PR; a live worker with no path holds nothing and has no lane fallback
reset; W="$ROOT/f18h-live"
ITEMS="$(arr "$(item own-l idle 95 local prefix '{"number":79,"state":"OPEN"}')" "$(item lane-np idle 95 local prefix '{"number":80,"state":"OPEN"}')")"
PRS="$(arr "$(pr 79 s79 200)" "$(pr 80 s80 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {
    "wlv": {path: "/w/wt/own-l", host: "local", state: "running"},
    "wnp": {host: "local", state: "running"}}, asks: [
    {id: "h-live", kind: "owner", worker: "wlv", askedAt: $f, question: "approve?", state: "open"},
    {id: "h-nopath", kind: "owner", worker: "wnp", lane: "lane-np", askedAt: $f, question: "approve?", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18h a live worker: its own worktree and its PR are held" "$(exr own-l)$(field own-l rung)$(exr '#79')$(field '#79' rung)" "askabsentlaneabsent"
check "F18h a live worker with no path: its lane and PR ladder (no asks[].lane fallback)" "$(exr lane-np)$(field lane-np rung)$(exr '#80')$(field '#80' rung)" "absent1absent1"

# F18i a token-shaped lane name reaches no field of --json (path, owner and host are withheld like name); a padded
# worker still names its live worker; a waiting lane exempts the PR of that worktree only (name AND host)
reset; W="$ROOT/f18i"
TOKN="x-${GHP}$(rep abcdefghij 4)"; TOKO="${GHP}$(rep zyxwvutsrq 4)"
ITEMS="$(arr "$(item "$TOKN" idle 95 local prefix null "$TOKO")")"
gen "$W"; runj "$W"
check "F18i a token-shaped lane is still judged (exit 4)" "$RC" "4"
TOKC="${GHP}class$(rep abcdefghij 3)"
ITEMS="$(arr "$(item lcls "$TOKC" 95)")"
gen "$W"; runj "$W"
check "F18i a token-shaped class: withheld in rows[].class" "$(field lcls class)" "[withheld: looks like a credential]"
case "$OUT" in *classabcdefghij*) check "F18i the token-shaped class reaches no field of --json" "present" "absent" ;; *) check "F18i the token-shaped class reaches no field of --json" "absent" "absent" ;; esac
ITEMS="$(arr "$(item "$TOKN" idle 95 local prefix null "$TOKO")")"
gen "$W"; runj "$W"
check "F18i the token-shaped lane row: name, path and owner withheld" "$(jq -r '[.rows[] | select(.kind == "lane") | .name, .path, .owner] | unique | join(",")' <<<"$OUT")" "[withheld: looks like a credential]"
case "$OUT" in *abcdefghij*|*zyxwvutsrq*) check "F18i no part of the token reaches any field of --json" "present" "absent" ;; *) check "F18i no part of the token reaches any field of --json" "absent" "absent" ;; esac
reset; W="$ROOT/f18i2"
ITEMS="$(arr "$(item pad-l idle 95 local prefix '{"number":66,"state":"OPEN"}')")"
PRS="$(arr "$(pr 66 s66 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {"wc": {path: "/w/wt/pad-l", host: "local", state: "running"}}, asks: [
    {id: "pad-sec", kind: "secrets", worker: " wc ", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18i a padded worker names its live worker: its lane and PR are held" "$(exr pad-l)$(field pad-l rung)$(exr '#66')$(field '#66' rung)" "askabsentlaneabsent"
reset; W="$ROOT/f18i3"
HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"hb","reachable":true,"truncated":false}]'; HREAD='["local","hb"]'
ITEMS="$(arr "$(item twin idle 95 local prefix '{"number":77,"state":"OPEN"}')" "$(item twin idle 95 hb prefix '{"number":78,"state":"OPEN"}')")"
PRS="$(arr "$(pr 77 s77 200)" "$(pr 78 s78 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {"wt": {path: "/w/wt/twin", host: "local", state: "running"}}, asks: [
    {id: "tw-own", kind: "owner", worker: "wt", askedAt: $f, question: "approve?", state: "open"}]}')"
gen "$W"; runj "$W"
hy() { jq -r --arg n "$1" --arg h "$2" '([.exempt[] | select(.name == $n and .host == $h) | .code] | first // "absent") + ([.rows[] | select(.name == $n and .host == $h) | .rung | tostring] | first // "absent")' <<<"$OUT"; }
check "F18i twin@local (the ask worker): held" "$(hy twin local)" "askabsent"
check "F18i its PR #77: held (lane)" "$(exr '#77')$(field '#77' rung)" "laneabsent"
check "F18i twin@hb (unrelated, same name): ladders" "$(hy twin hb)" "absent1"
check "F18i its PR #78: ladders" "$(exr '#78')$(field '#78' rung)" "absent1"

# F18j a padded worker id is trimmed in the noCode-with-a-PR check and in the own-worktree check; a live worker row with
# no host holds nothing (it would match that worktree name on every host)
reset; W="$ROOT/f18j"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {"wc": {path: "/w/wt/nc-l", host: "local", state: "running", pr: 66}}, asks: [
    {id: "nc-raw", kind: "code", issue: 5, lane: "dev-1", noCode: true, worker: "wc", askedAt: $f, question: "split it?", state: "open"},
    {id: "nc-pad", kind: "code", issue: 5, lane: "dev-1", noCode: true, worker: " wc ", askedAt: $f, question: "split it?", state: "open"},
    {id: "self-raw", kind: "release", worker: "concertmaster", askedAt: $f, question: "ship the store build", state: "open"},
    {id: "self-pad", kind: "release", worker: " concertmaster ", askedAt: $f, question: "ship the store build", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18j a noCode ask whose worker has a PR: exempt owner" "$(exr nc-raw)$(field nc-raw rung)" "ownerabsent"
check "F18j the same with a padded worker id: exempt owner" "$(exr nc-pad)$(field nc-pad rung)" "ownerabsent"
has "F18j the padded one is refused for the PR" "$(jq -r '.exempt[] | select(.name == "nc-pad") | .reason' <<<"$OUT")" "noCode but the worker has a PR"
check "F18j an ask from the concertmaster worktree: held" "$(exr self-raw)$(field self-raw rung)" "heldabsent"
check "F18j the same with a padded self name: held" "$(exr self-pad)$(field self-pad rung)" "heldabsent"
reset; W="$ROOT/f18j2"
HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"hb","reachable":true,"truncated":false}]'; HREAD='["local","hb"]'
ITEMS="$(arr "$(item twin idle 95 local prefix '{"number":77,"state":"OPEN"}')" "$(item twin idle 95 hb prefix '{"number":78,"state":"OPEN"}')")"
PRS="$(arr "$(pr 77 s77 200)" "$(pr 78 s78 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {"wnh": {path: "/w/wt/twin", state: "running"}}, asks: [
    {id: "nh-own", kind: "owner", worker: "wnh", askedAt: $f, question: "approve?", state: "open"}]}')"
gen "$W"; runj "$W"
hz() { jq -r --arg n "$1" --arg h "$2" '([.exempt[] | select(.name == $n and .host == $h) | .code] | first // "absent") + ([.rows[] | select(.name == $n and .host == $h) | .rung | tostring] | first // "absent")' <<<"$OUT"; }
check "F18j a live worker row with no host: twin@local ladders" "$(hz twin local)" "absent1"
check "F18j a live worker row with no host: twin@hb ladders" "$(hz twin hb)" "absent1"
check "F18j and both PRs ladder" "$(field '#77' rung)$(field '#78' rung)" "11"

# F18f liveness is per ask row: a closed delegated ask frees its PR even when an owner-only ask shares its id
reset; W="$ROOT/f18f"
PRS="$(arr "$(pr 96 s96 200)" "$(pr 97 s97 200)")"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "dup-id", kind: "merge", pr: 96, askedAt: $f, question: "q", state: "open"},
    {id: "dup-id", kind: "release", pr: 97, askedAt: $f, question: "ship the store build", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18f before close-ask: both PRs held" "$(exr '#96')$(exr '#97')" "askask"
act "$W" "$(ago 40)" ask dup-id relay "relayed"
act "$W" "$(ago 20)" ask dup-id close-ask "closed: decided"
runj "$W"
check "F18f after close-ask: the owner-only ask still holds its PR" "$(exr '#96')" "ask"
check "F18f after close-ask: the closed ask frees its PR" "$(exr '#97')$(field '#97' rung)" "absent1"

# F18g each element of rows[].lanes is scanned; the scan fails closed (every free-text field withheld)
reset; W="$ROOT/f18g"
TOK="${GHP}$(rep abcdefghij 4)"
ITEMS="$(arr "$(item "$TOK" idle 5 local prefix '{"number":95,"state":"OPEN"}')")"
PRS="$(arr "$(pr 95 s95 200)")"
gen "$W"; runj "$W"
check "F18g a credential-shaped lane name in rows[].lanes: withheld" "$(field '#95' lanes)" '["[withheld: looks like a credential]"]'
case "$OUT" in *abcdefghij*) check "F18g no credential reaches --json" "present" "absent" ;; *) check "F18g no credential reaches --json" "absent" "absent" ;; esac
reset; W="$ROOT/f18g2"
ITEMS="$(arr "$(item plain-l idle 95 local prefix '{"number":98,"state":"OPEN"}')")"
PRS="$(arr "$(pr 98 s98 200)")"
gen "$W"
OUT="$(CM_TEST=1 CM_TEST_FAIL_WITHHOLD=1 CM_HOME="$W/cm" bash "$SCRIPT" --classify "$W/cls.json" --discover "$W/disc.json" --asks "$W/asks.json" --ledger "$W/led.json" --since "$SINCE" --json 2>"$W/err")"; RC=$?
check "F18g a failed scan: every row name withheld" "$(jq -r '[.rows[].name] | unique | join(",")' <<<"$OUT")" "[withheld: looks like a credential]"
check "F18g a failed scan: PR title and lanes withheld" "$(jq -r '[.rows[] | select(.kind == "pr") | .title, .lanes[]] | unique | join(",")' <<<"$OUT")" "[withheld: looks like a credential]"
has "F18g a failed scan: a warning names it" "$(cat "$W/err")" "credential scan failed"
check "F18g a failed scan: the run still judges (exit 4)" "$RC" "4"

# F18d (R9) an unknown kind never prints, and a credential-shaped id or name is withheld in exempt[] as in rows[]
reset; W="$ROOT/f18d"
TOK="${GHP}$(rep abcdefghij 4)"
LED="$(jq -nc --arg f "$(ago 95)" --arg t "$TOK" '{workers: {}, asks: [
    {id: "k-bad", kind: $t, askedAt: $f, question: "q", state: "open"},
    {id: $t, kind: "merge", askedAt: $f, question: "q", state: "open"},
    {id: "k-odd", kind: "frobnicate", askedAt: $f, question: "q", state: "open"}]}')"
gen "$W"; runj "$W"
check "F18d a credential-shaped kind: exempt owner" "$(exr k-bad)" "owner"
has "F18d a credential-shaped kind: the reason says unknown kind" "$(jq -r '.exempt[] | select(.name == "k-bad") | .reason' <<<"$OUT")" "unknown kind"
has "F18d any unknown kind prints as unknown kind" "$(jq -r '.exempt[] | select(.name == "k-odd") | .reason' <<<"$OUT")" "unknown kind"
check "F18d a credential-shaped ask id: its name is withheld" "$(jq -r '[.exempt[] | select(.name == "[withheld: looks like a credential]")] | length' <<<"$OUT")" "1"
case "$OUT" in *abcdefghij*) check "F18d no credential reaches --json" "present" "absent" ;; *) check "F18d no credential reaches --json" "absent" "absent" ;; esac

# F19 credential-shaped worker, and a secret past the first 120 characters, are withheld; extra --act args never echoed
reset; W="$ROOT/f19"
TOK="${GHP}$(rep abcdefghij 4)"
RUNS="Zq8Lm3Rt$(rep 7Vx2Nk5Wp 4)"
FILL="$(printf 'word %.0s' $(seq 1 20))"
LED="$(jq -nc --arg f "$(ago 95)" --arg t "$TOK" --arg r "$RUNS" --arg fill "$FILL" '{workers: {}, asks: [
    {id: "w-tok", kind: "release", worker: $t, askedAt: $f, question: "ship the store build", state: "open"},
    {id: "w-long", kind: "code", issue: 5, lane: "dev-1", noCode: true, askedAt: $f, question: ($fill + " " + $r), state: "open"},
    {id: "w-ok", kind: "release", worker: "w-plain", askedAt: $f, question: "ship the store build", state: "open"}]}')"
gen "$W"; runj "$W"
check "F19 a credential-shaped worker: withheld" "$(field w-tok worker)" "[withheld: looks like a credential]"
check "F19 a credential past 120 characters: the text is withheld" "$(field w-long text)" "[withheld: looks like a credential]"
check "F19 a plain worker: kept" "$(field w-ok worker)" "w-plain"
TFILL="$(printf 'word %.0s' $(seq 1 12))"
PRS="$(jq -nc --arg r "$RUNS" --arg fill "$TFILL" --arg u "$(ago 200)" '[{number: 72, title: ($fill + " " + $r), isDraft: false, createdAt: $u, updatedAt: $u, url: "u", headRefName: "b72", headRefOid: "s72", author: "author-1", repo: null, labels: []},
  {number: 73, title: "bump the card", isDraft: false, createdAt: $u, updatedAt: $u, url: "u", headRefName: "b73", headRefOid: "s73", author: "author-1", repo: null, labels: []}]')"
gen "$W"; runj "$W"
check "F19 a credential past 80 characters of a PR title: withheld" "$(field '#72' title)" "[withheld: looks like a credential]"
check "F19 a plain PR title: kept" "$(field '#73' title)" "bump the card"
check "F19 no _full field reaches --json" "$(jq -r '[.rows[] | has("_full")] | any' <<<"$OUT")" "false"
case "$OUT" in *"$TOK"*|*"$RUNS"*) check "F19 no credential reaches --json" "present" "absent" ;; *) check "F19 no credential reaches --json" "absent" "absent" ;; esac
CM_HOME="$W/cm" bash "$SCRIPT" --act lane x nudge "t" "$TOK" >/dev/null 2>"$W/xa.err"; check "F19 an extra --act arg: exit 2" "$?" "2"
check "F19 an extra --act arg is not echoed" "$(grep -c "abcdefghij" "$W/xa.err")" "0"
CM_HOME="$W/cm" bash "$SCRIPT" "$TOK" >/dev/null 2>"$W/xb.err"; check "F19 an unknown arg: exit 2" "$?" "2"
check "F19 an unknown arg is not echoed" "$(grep -c "abcdefghij" "$W/xb.err")" "0"

# F20 a malformed asks.sh row or ledger question never stops the tick nor puts its value in the output
reset; W="$ROOT/f20"
ASKS="$(jq -nc --arg f "$(ago 65)" --arg t "$TOK" '[{host: "local", worktree: {a: $t}, tag: "cm:ask", text: $t, firstSeen: $f}]')"
LED="$(jq -nc --arg f "$(ago 95)" --arg t "$TOK" '{workers: {}, asks: [{id: "m-q", kind: "release", askedAt: $f, question: {x: $t}, state: "open"}]}')"
gen "$W"; runj "$W"
# the comment ask with an object worktree does not say which lane asks, so nothing can be ruled out: unreadable, exit 3
# (it was read as "?" and the run exited 0); the ledger ask with no text is the owner's on its own
check "F20 malformed rows: the comment ask worktree is unreadable, exit 3 (it names no lane to hold)" "$RC" "3"
case "$OUT$(cat "$W/err")" in *abcdefghij*) check "F20 the token reaches neither --json nor stderr" "present" "absent" ;; *) check "F20 the token reaches neither --json nor stderr" "absent" "absent" ;; esac
check "F20 the comment ask with an object worktree: exempt owner as ?/ask" "$(jq -r '[.exempt[] | select(.kind == "ask" and (.name | startswith("?/ask@"))) | .code] | first // "absent"' <<<"$OUT")" "owner"

# F21 fuzz: ONE value of the wrong shape, at every top-level and second-level field this script reads in the ledger,
# classify, discover, asks, seen and actions inputs, holds only itself: the run judges (exit 0 or 4) and never exits 3,
# and a mutated seen file is rewritten clean, so the run after it is not 3 either. The exceptions are the values the
# validation stage of stall.sh reads to protect a lane or PR (a row, its host, path, name, class, owner, state, lane,
# the freeze, the hosts read): those exit 3 by design and must, with nothing judged (F14e-g, scripts/test/stall-fuzz.sh).
# Deterministic, no network, bounded
reset; W="$ROOT/fz"
ITEMS="$(arr "$(item la idle 95 local prefix '{"number":41,"state":"OPEN"}')" "$(item dev-sweeper standing-idle 95)" "$(item kid idle 95 local 'comment:la')")"
PRS="$(arr "$(pr 41 s41 200)" "$(pr 42 s42 200 null author-2 '[{"name":"x"}]')")"
WTS='[{"host":"local","path":"/w/wt/la","comment":"cm:waiting-owner no | lane la"}]'
ASKS="$(jq -nc --arg f "$(ago 65)" '[{host:"local", worktree:"la", path:"/w/wt/la", tag:"cm:ask", text:"q", firstSeen:$f}]')"
LED="$(jq -nc --arg f "$(ago 95)" '{workers:{"w1":{path:"/w/wt/la",host:"local",state:"running",lane:"la",pr:41}}, freeze:{state:"off",ttl:"2026-11-17T00:00:00Z",window:"w"},
  queue:{items:[{id:"q1",lane:"dev-sweeper",state:"queued"}]}, lanes:{"dev-sweeper":{queue:["a"]}},
  asks:[{id:"a1", kind:"release", askedAt:$f, question:"store build 1.5.2", pr:41, state:"open"},
        {id:"a2", kind:"code", askedAt:$f, question:"split the card?", files:["src/a.ts"], worker:"w1", lane:"la", issue:5, state:"open"},
        {id:"a3", kind:"secrets", askedAt:$f, question:"q", lane:"la", followUp:"x", state:"open"}]}')"
DEAD='[{"lead":"lx","open":["kid"]}]'
gen "$W"; mkdir -p "$W/cm"; act "$W" "$(ago 10)" lane la nudge "nudged" --host local --path /w/wt/la; runj "$W"
check "F21 fuzz base: judged (exit 4)" "$RC" "4"
cat > "$ROOT/fz-one.sh" <<'FZ'
#!/usr/bin/env bash
# fz-one.sh <base> <script> <since> <doc> <jq path> <json value>: one mutation, prints "<rc> <rc2> <doc> <path> <value>"
b="$1"; sc="$2"; si="$3"; doc="$4"; pa="$5"; va="$6"
d="$(mktemp -d "$b.fz.XXXXXX")"; cp -R "$b/." "$d/"
case "$doc" in
  seen) f="$d/cm/stall-seen.json" ;; act) f="$d/cm/stall-actions.ndjson" ;; *) f="$d/$doc.json" ;;
esac
if [ "$doc" = act ]; then
  { head -n 1 "$f" | jq -c --argjson v "$va" "$pa = \$v"; tail -n +2 "$f"; } > "$f.t" && mv "$f.t" "$f"
else
  jq --argjson v "$va" "$pa = \$v" "$f" > "$f.t" && mv "$f.t" "$f"
fi
one() { CM_HOME="$d/cm" timeout 60 bash "$sc" --classify "$d/cls.json" --discover "$d/disc.json" --asks "$d/asks.json" \
          --ledger "$d/led.json" --since "$si" --json >/dev/null 2>&1; echo $?; }
r1="$(one)"; r2=-; [ "$doc" = seen ] && r2="$(one)"
rm -rf -- "${d:?}"
printf '%s %s %s %s %s\n' "$r1" "$r2" "$doc" "$pa" "$va"
FZ
# one wrong-type value per field: a text where a list or object belongs, an object where a text belongs, and 1e300 where
# a number or time is read. The full grid (every field, every JSON type, deep nesting, huge values) runs out of tree;
# this is the bounded regression set
{
  for pth in .workers .workers.w1 .freeze .queue .queue.items '.queue.items[0]' .lanes '.lanes["dev-sweeper"]' \
             '.lanes["dev-sweeper"].queue' .asks '.asks[0]'; do printf 'led\t%s\t"x"\n' "$pth"; done
  for pth in .workers.w1.state .freeze.state .freeze.ttl '.queue.items[0].lane' '.asks[1].worker'; do printf 'led\t%s\t{"a":[1]}\n' "$pth"; done
  for pth in '.items[0]' '.items[0].pr' .ownership '.ownership.leadDead[0]'; do printf 'cls\t%s\t"x"\n' "$pth"; done
  for pth in '.items[0].host' '.items[0].name' '.items[0].repo' '.items[2].ownerSource'; do printf 'cls\t%s\t{"a":[1]}\n' "$pth"; done
  for pth in '.hosts[0]' .worktrees '.prs.open[0]' .errors; do printf 'disc\t%s\t"x"\n' "$pth"; done
  for pth in .mainRepo '.worktrees[0].host' '.prs.open[0].repo' '.prs.open[0].author' '.prs.open[1].labels[0]'; do printf 'disc\t%s\t{"a":[1]}\n' "$pth"; done
  for pth in '.asks[0]' .unreachable .hostsRead; do printf 'asks\t%s\t"x"\n' "$pth"; done
  printf 'asks\t%s\t{"a":[1]}\n' '.asks[0].host'
  for pth in .prs '.prs[(.prs | keys[0])]'; do printf 'seen\t%s\t"x"\n' "$pth"; done
  printf 'act\t%s\t"x"\n' .; printf 'act\t%s\t{"a":[1]}\n' .at .kind
  printf 'cls\t%s\t1e300\n' '.items[0].idleMinutes'; printf 'led\t%s\t1e300\n' '.asks[0].askedAt'
  printf 'disc\t%s\t1e300\n' '.prs.open[0].updatedAt' '.prs.open[0].number'
  printf 'seen\t%s\t1e300\n' '.prs[(.prs | keys[0])].firstSeen'; printf 'act\t%s\t1e300\n' '.at'
} > "$ROOT/fz-jobs.tsv"
FZN="$(wc -l < "$ROOT/fz-jobs.tsv" | tr -d ' ')"
tr '\t\n' '\0\0' < "$ROOT/fz-jobs.tsv" | timeout 300 xargs -0 -n 3 -P 8 bash "$ROOT/fz-one.sh" "$W" "$SCRIPT" "$SINCE" > "$ROOT/fz-out.txt" 2>/dev/null
check "F21 fuzz: every mutation ran inside the bound ($FZN)" "$(wc -l < "$ROOT/fz-out.txt" | tr -d ' ')" "$FZN"
# the mutations that only time or print a row (or touch the state files) hold only themselves: exit 0 or 4
F21_OK='^(cls \.items\[0\]\.idleMinutes|led \.asks\[0\]\.askedAt|disc \.prs\.open\[0\]\.(updatedAt|number|author)|disc \.prs\.open\[1\]\.labels\[0\]|seen |act )'
check "F21 fuzz: a timing or display value, or a state file, holds only itself (exit 0 or 4)" "$(awk '{print $3, $4, $1}' "$ROOT/fz-out.txt" | grep -E "$F21_OK" | awk '$3 != 0 && $3 != 4' | head -3 | tr '\n' ';')" ""
check "F21 fuzz: every protective value of the wrong type exits 3, nothing judged" "$(awk '{print $3, $4, $1}' "$ROOT/fz-out.txt" | grep -Ev "$F21_OK" | awk '$3 != 3' | head -3 | tr '\n' ';')" ""
check "F21 fuzz: a mutated seen file is rewritten clean, the next run is not 3 either" "$(awk '$3 == "seen" && $2 != 0 && $2 != 4' "$ROOT/fz-out.txt" | head -3 | tr '\n' ';')" ""

# F21b sanitising never widens: a worker or comment-ask host of the wrong type never reads as null (which would match
# every host and park, block or exempt a real lane everywhere): it is an unreadable input, so nothing is judged and the
# run exits 3; a null comment-ask host still exempts nothing; an action host or path of the wrong type is dropped
fzh() { jq -r --arg n "$1" --arg h "$2" '([.exempt[] | select(.name == $n and .host == $h) | .code] | first // "absent") + ([.rows[] | select(.name == $n and .host == $h) | .rung | tostring] | first // "absent")' <<<"$OUT"; }
for st in parked blocked-on-owner; do
  for hv in 5 '["hb"]' false; do
    reset; W="$ROOT/f21b-$st-$(printf '%s' "$hv" | tr -cd 'a-z0-9')"
    HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"hb","reachable":true,"truncated":false}]'; HREAD='["local","hb"]'
    ITEMS="$(arr "$(item la idle 95 local)" "$(item la idle 95 hb)")"
    LED="$(jq -nc --arg st "$st" --argjson h "$hv" '{workers: {"w1": {path: "/w/wt/la", host: $h, state: $st}}}')"
    gen "$W"; runj "$W"
    check "F21b a $st worker with host $hv: la@local is unverified, never parked or held" "$(fzh la local)" "unverifiedabsent"
    check "F21b a $st worker with host $hv: la@hb is unverified, never parked or held" "$(fzh la hb)" "unverifiedabsent"
    check "F21b a $st worker with host $hv: exit 3" "$RC" "3"
  done
done
reset; W="$ROOT/f21b-local"
HOSTS='[{"name":"local","reachable":true,"truncated":false},{"name":"hb","reachable":true,"truncated":false}]'; HREAD='["local","hb"]'
ITEMS="$(arr "$(item la idle 95 local)" "$(item la idle 95 hb)")"
LED='{"workers":{"w1":{"path":"/w/wt/la","host":"local","state":"parked"}}}'
gen "$W"; runj "$W"
check "F21b a parked worker on host local: only la@local is parked" "$(fzh la local)$(fzh la hb)" "parkedabsentabsent1"
# a comment ask with no or a wrong-typed host is unverified and exempts no lane on any host
reset; W="$ROOT/f21b-ask"
ITEMS="$(arr "$(item lq idle 95 local)")"
ASKS="$(jq -nc --arg f "$(ago 65)" '[{host: null, worktree: "lq", tag: "cm:ask", text: "t", firstSeen: $f}]')"
gen "$W"; runj "$W"
check "F21b a comment ask with a null host: the lane still ladders" "$(fzh lq local)" "absent1"
ASKS="$(jq -nc --arg f "$(ago 65)" '[{host: 5, worktree: "lq", tag: "cm:ask", text: "t", firstSeen: $f}]')"
rm -rf -- "${W:?}"; gen "$W"; runj "$W"
check "F21b a comment ask with a numeric host: unreadable, the lane is unverified, exit 3" "$(fzh lq local)$RC" "unverifiedabsent3"
# an action whose host or path is not text is dropped, never read as no host (which would match the lane by name)
reset; W="$ROOT/f21b-act"
ITEMS="$(arr "$(item lu idle 95 local)")"
gen "$W"; mkdir -p "$W/cm"
jq -nc --arg at "$(ago 1)" '{at: $at, kind: "lane", name: "lu", host: false, path: null, verb: "blocked", rung: 3, text: "t", by: "concertmaster"}' > "$W/cm/stall-actions.ndjson"
runj "$W"
check "F21b an action with host false: dropped, the lane still ladders" "$(fzh lu local)" "absent1"

# F21c a wrong-typed value never becomes null where null defaults to a real value: a repo would default to the main
# repo (and collide with a real PR), a lane path would match any action path, an owner would fall back to the lane name.
# Each is an unreadable input now: nothing is judged on a guess, the run exits 3
reset; W="$ROOT/f21c-pr"
PRS="$(jq -nc --arg u "$(ago 200)" --arg n "$(ago 0)" '[
  {number: 41, title: "t41", isDraft: false, createdAt: $u, updatedAt: $u, url: "u", headRefName: "b41", headRefOid: "s41", author: "author-1", repo: null, labels: []},
  {number: 41, title: "twin", isDraft: false, createdAt: $n, updatedAt: $n, url: "u", headRefName: "bz", headRefOid: "zz", author: "author-1", repo: 5, labels: []}]')"
gen "$W"; runj "$W"
check "F21c an open PR with a numeric repo: #41 is unverified, exit 3" "$(exr '#41')$RC" "unverified3"
runj "$W"
check "F21c and on the second run (the seen file was not taken over by the twin)" "$(exr '#41')$RC" "unverified3"
reset; W="$ROOT/f21c-item"
ITEMS="$(arr "$(item ly idle 95 local prefix '{"number":41,"state":"OPEN"}')" "$(item lx idle 95 local prefix '{"number":41,"state":"OPEN"}' | jq -c '.repo = 5')")"
PRS="$(arr "$(pr 41 s41 200)")"
LED='{"workers":{"wx":{"path":"/w/wt/lx","host":"local","state":"parked"}}}'
gen "$W"; runj "$W"
check "F21c a lane with a numeric repo never claims the main repo PR: #41 is unverified, exit 3" "$(exr '#41')$RC" "unverified3"
reset; W="$ROOT/f21c-path"
ITEMS="$(arr "$(item lp idle 95 local | jq -c '.path = 5')")"
gen "$W"; mkdir -p "$W/cm"
act "$W" "$(ago 1)" lane lp blocked "waiting on the console" --host local --path /w/wt/lp
runj "$W"
check "F21c a lane with a numeric path is never matched by an action for a real path: unverified, exit 3" "$(exr lp)$(field lp rung)$RC" "unverifiedabsent3"
reset; W="$ROOT/f21c-owner"
ITEMS="$(arr "$(item lo standing-idle 95 local standing null dev-sweeper | jq -c '.owner = 5')")"
gen "$W"; runj "$W"
check "F21c a standing-idle lane whose owner cannot be read is never exempt as idle: unverified, exit 3" "$(exr lo)$(field lo rung)$RC" "unverifiedabsent3"

# F22 a value of the wrong type in a field that PROTECTS a lane or a PR is unreadable, never "nothing there": the
# validation stage of stall.sh (V spec) names it in gaps[], marks every lane, PR and delegated ask unverified and exits
# 3. Each group has a control (the legal value protects: exit 0, exempt) and one named row per field, so reverting the
# check for a field shows up here (scripts/test/stall-fuzz.sh mutates every field of every input as well)
# worktree comments (discover .worktrees): a cm:waiting-owner lane must never be nudged
f22base; WTS0="$(jq -nc '[{host: "local", path: "/w/acme/la", comment: "cm:waiting-owner pick the club"}]')"
WTS="$WTS0"; gen "$W"; runj "$W"
check "F22 control: a cm:waiting-owner lane is exempt, exit 0" "$(exr la)$RC" "owner0"
f22w() { WTS="$(jq -c "$2" <<<"$WTS0")"; f22chk "$1" "$3"; }
f22w "discover .worktrees as text" '"x"' "discover: .worktrees is not a list"
f22w "discover .worktrees as an object" '{}' "discover: .worktrees is not a list"
f22w "a worktree row that is a number" '.[0] = 7' "discover: .worktrees[0] is not an object"
f22w "a worktree comment that is a list" '.[0].comment = ["cm:waiting-owner"]' "discover: .worktrees[0].comment is not text"
f22w "a worktree host that is a number" '.[0].host = 7' "discover: .worktrees[0].host is not text"
f22w "a worktree path that is an object" '.[0].path = {}' "discover: .worktrees[0].path is not text"
# the hosts asks.sh read: null (or absent) is every host read, anything else that is not a list of text is unreadable
f22base; WTS='[]'; HREAD='null'; gen "$W"; runj "$W"
check "F22 control: hostsRead null is every host read, la ladders (rung 1, exit 4)" "$(field la rung)$RC" "14"
for hv in '"local"' '7' '{}'; do f22base; HREAD="$hv"; f22chk "asks .hostsRead as $hv" "asks: .hostsRead is not a list"; done
f22base; HREAD='[7]'; f22chk "asks .hostsRead[0] as a number" "asks: .hostsRead[0] is not text"
# comment asks (asks.json rows)
f22base; ASKS0="$(jq -nc --arg f "$(ago 65)" '[{host: "local", worktree: "la", tag: "cm:ask", text: "t", firstSeen: $f}]')"
ASKS="$ASKS0"; gen "$W"; runj "$W"
check "F22 control: a comment ask holds its lane, exit 0" "$(exr la)$RC" "ask0"
f22a() { ASKS="$(jq -c "$2" <<<"$ASKS0")"; f22chk "$1" "$3"; }
f22base; f22a "an asks row that is a number" '.[0] = 7' "asks: .asks[0] is not an object"
f22base; f22a "an asks row worktree that is a number" '.[0].worktree = 7' "asks: .asks[0].worktree is not text"
f22base; f22a "an asks row host that is a list" '.[0].host = ["local"]' "asks: .asks[0].host is not text"
f22base; f22a "an asks row tag that is an object" '.[0].tag = {}' "asks: .asks[0].tag is not text"
# ledger asks: an open ask that holds its lane
f22base; LED0="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "la", question: "merge it?", askedAt: $f}]}')"
LED="$LED0"; gen "$W"; runj "$W"
check "F22 control: an open owner-only ask holds its lane, exit 0" "$(exr la)$RC" "ask0"
f22l() { LED="$(jq -c "$2" <<<"$LED0")"; f22chk "$1" "$3"; }
f22base; f22l "a ledger ask row that is a number" '.asks += [7]' "ledger: .asks[1] is not an object"
f22base; f22l "a ledger ask state that is a list" '.asks[0].state = ["open"]' "ledger: .asks[0].state is not text"
f22base; f22l "a ledger ask id that is a number" '.asks[0].id = 7' "ledger: .asks[0].id is not text"
f22base; f22l "a ledger ask lane that is an object" '.asks[0].lane = {}' "ledger: .asks[0].lane is not text"
f22base; f22l "a ledger ask worker that is a number" '.asks[0].worker = 7' "ledger: .asks[0].worker is not text"
# a delegated ask (release, on the ladder) holds its lane only while it is judged: an askedAt that is neither text nor a
# number leaves the ask unverified, which frees the lane, so it is unreadable (exit 3), never a lane that ladders
f22base; LED0="$(jq -nc --arg f "$(ago 5)" '{workers: {}, asks: [{id: "a2", kind: "release", state: "open", lane: "la", question: "push the OTA release", askedAt: $f}]}')"
LED="$LED0"; gen "$W"; runj "$W"
check "F22 control: a delegated ask on the ladder holds its lane, exit 0" "$(exr la)$RC" "ask0"
f22base; f22l "a ledger ask askedAt that is true" '.asks[0].askedAt = true' "ledger: .asks[0].askedAt is not text or a number"
f22base; f22l "a ledger ask askedAt that is an object" '.asks[0].askedAt = {}' "ledger: .asks[0].askedAt is not text or a number"
f22base; f22l "a ledger ask askedAt that is a list" '.asks[0].askedAt = []' "ledger: .asks[0].askedAt is not text or a number"
# ledger workers: a parked or blocked-on-owner worker holds its lane
f22base; LED0='{"workers":{"w1":{"path":"/w/acme/la","host":"local","state":"parked"}}}'
LED="$LED0"; gen "$W"; runj "$W"
check "F22 control: a parked worker holds its lane, exit 0" "$(exr la)$RC" "parked0"
f22base; f22l "a worker row that is a list" '.workers["w1"] = []' "ledger: .workers.w1 is not an object"
f22base; f22l "a worker state that is a list" '.workers.w1.state = ["parked"]' "ledger: .workers.w1.state is not text"
f22base; f22l "a worker host that is a list" '.workers.w1.host = ["local"]' "ledger: .workers.w1.host is not text"
f22base; f22l "a worker path that is a number" '.workers.w1.path = 7' "ledger: .workers.w1.path is not text"
f22base; f22l "a worker lane that is an object" '.workers.w1.lane = {}' "ledger: .workers.w1.lane is not text"
f22base; f22l "a worker worktreeId that is a number" '.workers.w1.worktreeId = 7' "ledger: .workers.w1.worktreeId is not text"
# S1: a noCode ask whose worker has a PR is the owner's (ask-timeout.sh gates). The worker row with a host that is not
# text used to be dropped before the ask check read it, so the ask was relayed at rung 1 and its lane laddered while
# the digest still listed it under Blocked on you
reset; W="$ROOT/f22s1"; rm -rf -- "${W:?}"
ITEMS="$(arr "$(item lz idle 95)")"
LED0="$(jq -nc --arg f "$(ago 95)" '{workers: {"w-z": {state: "running", path: "/w/acme/lz", host: "local", pr: 7}},
  asks: [{id: "a-z", kind: "code", noCode: true, worker: "w-z", state: "open", question: "split the card?", askedAt: $f}]}')"
LED="$LED0"; gen "$W"; runj "$W"
check "F22 S1 control: a noCode ask whose worker has a PR stays owner-only, never relayed (exit 0)" "$(exr a-z)$(field a-z rung)$RC" "ownerabsent0"
for hv in 7 '["local"]' '{}'; do
  LED="$(jq -c --argjson h "$hv" '.workers["w-z"].host = $h' <<<"$LED0")"; gen "$W"; runj "$W"
  check "F22 S1 worker host $hv: exit 3" "$RC" "3"
  check "F22 S1 worker host $hv: the ask is never relayed (no ladder row)" "$(field a-z rung)" "absent"
  check "F22 S1 worker host $hv: the ask stays the owner's, not on the ladder" "$(exr a-z)" "owner"
  check "F22 S1 worker host $hv: its lane is unverified" "$(exr lz)" "unverified"
  has "F22 S1 worker host $hv: the gap names the host" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .workers.w-z.host is not text"
done
LED="$(jq -c '.workers["w-z"] = []' <<<"$LED0")"; gen "$W"; runj "$W"
# a worker row that is not an object is owner-only for ask-timeout.sh, so the ask is the owner's and never relayed
check "F22 S1 worker row [] : exit 3, the ask stays the owner's and is never relayed" "$RC$(exr a-z)$(field a-z rung)" "3ownerabsent"
has "F22 S1 worker row [] : the gap names the row" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .workers.w-z is not an object"
# S2: PR labels whose members are not text or an object with a text name read as no labels, so a do-not-merge PR was nudged
reset; W="$ROOT/f22s2"; rm -rf -- "${W:?}"
for lv in '[{"name":["do-not-merge"]}]' '[7]' '[["do-not-merge"]]' '[{"name":7}]'; do
  PRS="$(arr "$(pr 7 aaaa111 180 null alice "$lv")" "$(pr 8 bbbb222 180)")"; gen "$W"; runj "$W"
  check "F22 S2 labels $lv: #7 is unverified, never nudged" "$(exr '#7')$(field '#7' rung)" "unverifiedabsent"
  check "F22 S2 labels $lv: exit 3" "$RC" "3"
  has "F22 S2 labels $lv: the gap names the label" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "discover: .prs.open[0].labels[0]"
done
for lv in '{"name":"do-not-merge"}' '"do-not-merge"' '7'; do
  PRS="$(arr "$(pr 7 aaaa111 180 null alice "$lv")" "$(pr 8 bbbb222 180)")"; gen "$W"; runj "$W"
  check "F22 S2 labels $lv (not a list): #7 is unverified, never nudged, exit 3" "$(exr '#7')$(field '#7' rung)$RC" "unverifiedabsent3"
  has "F22 S2 labels $lv (not a list): the gap names the list" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "discover: .prs.open[0].labels is not a list"
done
PRS="$(arr "$(pr 7 aaaa111 180 null alice '[{"name":"do-not-merge"}, null]')")"; gen "$W"; runj "$W"
check "F22 S2 control: a null label member is legal, the do-not-merge label holds the PR (exit 0)" "$(exr '#7')$RC" "label0"
# the merge freeze: ttl is text, never epoch seconds (a number would be read as one)
reset; W="$ROOT/f22fz"; rm -rf -- "${W:?}"
PRS="$(arr "$(pr 7 aaaa111 180)")"
LED="$(jq -nc --arg t "$(ago -60)" '{workers: {}, freeze: {state: "on", window: "w1", ttl: $t}}')"; gen "$W"; runj "$W"
check "F22 control: a freeze with a text ttl holds the PR, exit 0" "$(exr '#7')$RC" "freeze0"
LED="$(jq -nc '{workers: {}, freeze: {state: "on", window: "w1", ttl: 4102444800}}')"; gen "$W"; runj "$W"
check "F22 a freeze ttl that is a number (epoch seconds) is unreadable: #7 unverified, exit 3" "$(exr '#7')$RC" "unverified3"
has "F22 a freeze ttl that is a number: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .freeze.ttl is not text"
# classify items: the class, owner source, owner and name decide whether a lane is held, idle or exempt
reset; W="$ROOT/f22c"
f22i() { ITEMS="$(arr "$(item la idle 95 local prefix null dev-sweeper | jq -c "$2")")"; f22chk "$1" "$3"; }
f22base; ITEMS="$(arr "$(item la idle 95 local self)")"; gen "$W"; runj "$W"
check "F22 control: the concertmaster own lane is exempt (self), exit 0" "$(exr la)$RC" "self0"
f22base; f22i "a classify ownerSource that is a list" '.ownerSource = ["self"]' "classify: .items[0].ownerSource is not text"
f22base; f22i "a classify class that is a number" '.class = 7' "classify: .items[0].class is not text"
f22base; f22i "a classify owner that is an object" '.owner = {}' "classify: .items[0].owner is not text"
f22base; f22i "a classify worktreeId that is a list" '.worktreeId = []' "classify: .items[0].worktreeId is not text"
f22base; f22i "a classify host that is a number" '.host = 7' "classify: .items[0].host is not text"
f22base; f22i "a classify pr that is text" '.pr = "x"' "classify: .items[0].pr is not an object"
f22base; ITEMS="$(arr 7 "$(item la idle 95)")"; gen "$W"; runj "$W"
check "F22 a classify item that is a number: la is unverified, exit 3" "$(exr la)$(field la rung)$RC" "unverifiedabsent3"
has "F22 a classify item that is a number: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "classify: .items[0] is not an object"
# exit 3 keeps the NO-ACTION line: a failed open PR list (exit 3) with a due lane prints it in the text report
reset; W="$ROOT/f22n"; rm -rf -- "${W:?}"
ITEMS="$(arr "$(item ln idle 95)")"; ERRS='[{"where":"gh pr list open"}]'; gen "$W"; run "$W"
check "F22 exit 3 (failed PR list) with a due lane: exit 3" "$RC" "3"
has "F22 exit 3 with a due lane: the text report still prints the NO-ACTION line" "$OUT" "NO-ACTION 1 due row(s)"

# a wrong-typed files is a named gap now (round 5): the whole run is unverified, exit 3, never read as "no files"
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "c-badfiles", kind: "code", lane: "la", askedAt: $f, question: "keep the helper?", files: "src/a.ts", state: "open"}]}')"; f22chk "F1c a code ask with files[] not a list" "ledger: .asks[0].files is not a list"
# a non-text question is a named gap now (round 5): exit 3, the run is unverified, nothing laddered (was: read as a secret risk)
for nq in '["paste the kubeconfig and rotate everything"]' '{"do": "set the PWMGR_CLIENTID, then upload"}' '42'; do
  f22base; LED="$(jq -nc --arg f "$(ago 95)" --argjson q "$nq" '{workers: {}, asks: [{id: "n1", kind: "release", lane: "la", askedAt: $f, question: $q, topic: "store build", state: "open"}]}')"; f22chk "F14 a non-text question ($nq)" "ledger: .asks[0].question is not text"
done
# F23 round 5: every field a ledger ask is read by to hold, route or time something is type-checked, and a state that reads
# like a known one is not. Repro map (H1 to H3 and A to G of the round-5 review): H1/A followUp, H2 pr, H3 kind and scope, B a
# credential-shaped map key in a gap, C a digit-only freeze ttl, E the queue, lanes, leadDead, unreachable and truncated guards,
# G a near-miss state and a padded worker key. Each group has its controls (the legal value keeps working).
f23ask() { # f23ask <label> <ask json patch (jq)> <gap text>: one owner-only merge ask holds lane la; the patch makes it wrong
  f22base; LED0="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "la", question: "merge it?", askedAt: $f}]}')"
  LED="$(jq -c ".asks[0] |= ($2)" <<<"$LED0")"; f22chk "$1" "$3"
}
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "la", question: "merge it?", askedAt: $f, followUp: null}]}')"
gen "$W"; runj "$W"
check "F23 H1 control: an owner-only ask with a null followUp holds its lane, exit 0" "$(exr la)$RC" "ask0"
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "la", question: "merge it?", askedAt: $f, followUp: "fu-1"}]}')"
gen "$W"; runj "$W"
check "F23 H1 control: a text followUp (the ownership label of a follow-up ask) releases the lane, which ladders (documented)" "$(field la rung)$RC" "14"
for fv in 7 true false '{}' '[]'; do
  f23ask "H1 ledger ask followUp $fv" ".followUp = $fv" "ledger: .asks[0].followUp is not text"
done
# the asks.sh rows (asks.json) never read followUp, pr or kind: whatever they carry, the lane stays held and the run is clean
for f in followUp pr kind scope; do for fv in 7 true false '{}'; do
  f22base; ASKS="$(jq -nc --arg f "$(ago 65)" --argjson v "$fv" --arg k "$f" '[{host: "local", worktree: "la", tag: "cm:ask", text: "t", firstSeen: $f} + {($k): $v}]')"
  gen "$W"; runj "$W"
  check "F23 H1 an asks.json row with an unread $f = $fv still holds its lane (owner, exit 0)" "$(exr la)$RC" "ask0"
done; done
# H2: the ask pr is a number or text (#n, repo#n, a pull URL); false read as "no pr" and let the PR ladder
f23pr() { f22base; PRS="$(arr "$(pr 7 s7 200)")"; LED="$(jq -nc --arg f "$(ago 95)" --argjson p "$1" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "lq", question: "merge it?", askedAt: $f, pr: $p}]}')"; gen "$W"; runj "$W"; }
f23pr 7; check "F23 H2 control: pr 7 holds PR #7 (exempt ask), exit 4 for the lane lz only" "$(exr '#7')$(field '#7' rung)" "askabsent"
f23pr '"#7"'; check "F23 H2 control: pr \"#7\" holds PR #7" "$(exr '#7')" "ask"
f23pr null; check "F23 H2 control: pr null holds nothing, PR #7 ladders" "$(exr '#7')$(field '#7' rung)" "absent1"
for pv in false true '{}' '[]'; do
  f23pr "$pv"
  check "F23 H2 pr $pv: PR #7 is unverified, never laddered" "$(exr '#7')$(field '#7' rung)" "unverifiedabsent"
  has "F23 H2 pr $pv: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .asks[0].pr is not a number or text"
  check "F23 H2 pr $pv: exit 3" "$RC" "3"
done
# H3: kind false read as no kind and fell through to scope (a merge ask with scope release was a delegated release)
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", scope: "release", state: "open", lane: "la", question: "push the OTA release", askedAt: $f}]}')"
gen "$W"; runj "$W"
check "F23 H3 control: kind merge with scope release stays owner-only, never relayed (exit 0)" "$(exr a1)$(field a1 rung)$RC" "ownerabsent0"
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: null, scope: "release", state: "open", lane: "la", question: "push the OTA release", askedAt: $f}]}')"
gen "$W"; runj "$W"
check "F23 H3 control: no kind and scope release is the delegated release ask (relay, rung 1)" "$(field a1 rung)$(field a1 action)" "1relay"
for kv in false true 7 '{}' '[]'; do
  f22base; LED="$(jq -nc --arg f "$(ago 95)" --argjson k "$kv" '{workers: {}, asks: [{id: "a1", kind: $k, scope: "release", state: "open", lane: "la", question: "push the OTA release", askedAt: $f}]}')"
  gen "$W"; runj "$W"
  check "F23 H3 kind $kv with scope release: never relayed, the ask is not on the ladder" "$(field a1 rung)" "absent"
  has "F23 H3 kind $kv: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .asks[0].kind is not text"
  check "F23 H3 kind $kv: exit 3, la unverified" "$RC$(exr la)" "3unverified"
done
f23ask "H3 scope as a number" '.scope = 7' "ledger: .asks[0].scope is not text"
# the other fields an ask owner scan reads: a wrong type is named, never read as absent
f23ask "ask question as false" '.question = false' "ledger: .asks[0].question is not text"
f23ask "ask topic as a number" '.topic = 7' "ledger: .asks[0].topic is not text"
f23ask "ask noCode as text" '.noCode = "true"' "ledger: .asks[0].noCode is not true or false"
f23ask "ask files as false" '.files = false' "ledger: .asks[0].files is not a list"
f23ask "ask files member as a number" '.files = [7]' "ledger: .asks[0].files[0] is not text"
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {"w-z": {state: "running", path: "/w/acme/la", host: "local", pr: false}}, asks: []}')"
gen "$W"; runj "$W"
check "F23 H2 a worker pr of false is named (a noCode ask whose worker has a PR is the owner's): exit 3" "$RC" "3"
has "F23 H2 the worker pr gap" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .workers.w-z.pr is not a number or text"
# C: a freeze ttl of digits only is read as epoch seconds (1970, expired): it is unreadable, an ISO time still works
reset; W="$ROOT/f23c"; rm -rf -- "${W:?}"; PRS="$(arr "$(pr 13 s13 200)")"
LED="$(jq -nc --arg t "$(ago -60)" '{workers: {}, freeze: {state: "on", window: "w1", ttl: $t}}')"; gen "$W"; runj "$W"
check "F23 C control: an ISO ttl in the future holds PR #13 (freeze), exit 0" "$(exr '#13')$RC" "freeze0"
LED="$(jq -nc --arg t "$(ago 60)" '{workers: {}, freeze: {state: "on", window: "w1", ttl: $t}}')"; gen "$W"; runj "$W"
check "F23 C control: an ISO ttl in the past is an expired freeze, PR #13 ladders" "$(field '#13' rung)" "1"
for tv in '"7"' '"1700000000"' '"0"'; do
  LED="$(jq -nc --argjson t "$tv" '{workers: {}, freeze: {state: "on", window: "w1", ttl: $t}}')"; gen "$W"; runj "$W"
  check "F23 C ttl $tv (digits only, read as epoch seconds): PR #13 is unverified, never laddered, exit 3" "$(exr '#13')$(field '#13' rung)$RC" "unverifiedabsent3"
  has "F23 C ttl $tv: the gap names it" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .freeze.ttl is digits only"
done
# G: a state that is a known one in another case or padded is matched exactly, so it read as "not that state"
f23ask "G ask state Open (near miss of open)" '.state = "Open"' "ledger: .asks[0].state is a near miss of a known state"
f23ask "G ask state ' open ' (padded)" '.state = " open "' "ledger: .asks[0].state is a near miss of a known state"
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "answered", lane: "la", question: "merge it?", askedAt: $f}]}')"
gen "$W"; runj "$W"
check "F23 G control: a known other state (answered) is legal: the ask holds nothing, la ladders (exit 4)" "$(field la rung)$RC" "14"
# P1: EVERY documented ask state (references/ledger.md, iv_ask_states in input-view.jq: open answered in-progress decided closed) is legal. A narrower list marked a closed or an
# in-progress ask unreadable, set anyBad and put the whole judgment at exit 3 every tick. The same ledger with and without a second ask in that state must give the same rows, gaps and exit.
f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "la", question: "merge it?", askedAt: $f}]}')"
gen "$W"; runj "$W"; ASK_BASE_RC="$RC"; ASK_BASE_OUT="$(jq -c '{rows, gaps, exempt}' <<<"$OUT")"
for ast in answered in-progress decided closed; do
  f22base; LED="$(jq -nc --arg f "$(ago 95)" --arg st "$ast" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "la", question: "merge it?", askedAt: $f}, {id: "a2", kind: "merge", state: $st, lane: "lz", question: "old one", askedAt: $f}]}')"
  gen "$W"; runj "$W"
  check "P1 documented ask state '$ast' is legal: exit and judgment equal the ledger without it" "$RC $(jq -c '{rows, gaps, exempt}' <<<"$OUT")" "$ASK_BASE_RC $ASK_BASE_OUT"
done
# mutant: the narrow list again (open answered decided) must fail the cases above
mkdir -p "$ROOT/mut-ask" && cp "$HERE"/../*.sh "$HERE"/../*.jq "$ROOT/mut-ask/" 2>/dev/null
sed -i 's/^CM_ASK_STATES="open answered in-progress decided closed"$/CM_ASK_STATES="open answered decided"/' "$ROOT/mut-ask/lib.sh"
if ! cmp -s "$HERE/../lib.sh" "$ROOT/mut-ask/lib.sh"; then
  SAVE_SCRIPT="$SCRIPT"; SCRIPT="$ROOT/mut-ask/stall.sh"
  f22base; LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [{id: "a1", kind: "merge", state: "open", lane: "la", question: "merge it?", askedAt: $f}, {id: "a2", kind: "merge", state: "closed", lane: "lz", question: "old one", askedAt: $f}]}')"
  gen "$W"; runj "$W"; SCRIPT="$SAVE_SCRIPT"
  check "P1 mutant: with the narrow ask list a closed ask is unreadable again (exit 3), the case is caught" "$RC" "3"
else check "P1 mutant: the sed matches lib.sh" "no" "yes"; fi
# round 2, B3: a key written twice in a worker row or an ask row. jq reads the LAST of the two, so "state":"parked","state":"running" read as a running lane (rung 1, a nudge due,
# exit 4) where the single "parked" is exempt (exit 0), and an ask "state":"open","state":"answered" freed the lane it holds. The row is unknown: a gap, exit 3, no nudge, no rung.
f22base; LED='{"workers":{"w1":{"path":"/w/acme/la","host":"local","state":"parked"}}}'; gen "$W"; runj "$W"
check "B3 control: a single state parked is exempt as parked, exit 0, no rung" "$(exr la)$(field la rung)$RC" "parkedabsent0"
f22base; LED='{"workers":{"w1":{"path":"/w/acme/la","host":"local","state":"parked","state":"running"}}}'
f22chk "B3 worker state parked then running" "ledger: .workers.w1.state writes the same key twice"
check "B3 worker repeat: no nudge is due (exit 3, not 4) and the gap list is not empty" "$RC $(jq -r '.gaps | length > 0' <<<"$OUT")" "3 true"
f22base; LED='{"workers":{"w1":{"path":"/w/acme/la","host":"local","state":"running","state":"parked"}}}'
f22chk "B3 worker state running then parked (the other order)" "ledger: .workers.w1.state writes the same key twice"
f22base; LED='{"workers":{"w1":{"path":"/w/acme/la","host":"local","state":"parked"},"w1":{"path":"/w/acme/zz","host":"local","state":"running"}}}'
f22chk "B3 the same worker id twice" "ledger: .workers.w1 writes the same key twice"
B3ASK="{\"id\":\"a1\",\"kind\":\"merge\",\"lane\":\"la\",\"question\":\"merge it?\",\"askedAt\":\"$(ago 95)\""
f22base; LED="{\"workers\":{},\"asks\":[$B3ASK,\"state\":\"open\"}]}"; gen "$W"; runj "$W"
check "B3 control: a single open ask holds lane la (not laddered), exit 0" "$(field la rung)$RC" "absent0"
f22base; LED="{\"workers\":{},\"asks\":[$B3ASK,\"state\":\"open\",\"state\":\"answered\"}]}"
f22chk "B3 ask state open then answered" "ledger: .asks.0.state writes the same key twice"
check "B3 ask repeat: the lane is not freed into a nudge (exit 3, not 4)" "$RC" "3"
f22base; LED="{\"workers\":{},\"asks\":[$B3ASK,\"state\":\"open\",\"kind\":\"design\"}]}"
f22chk "B3 ask kind written twice" "ledger: .asks.0.kind writes the same key twice"
# mutant: a copy of the scripts (cp -R, so scripts/jdupkeys comes along) with the new reasons switched off. The lane is laddered again, the harm the cases above pin
mutcp() { mkdir -p "$1" && cp -R "$HERE"/../. "$1"/; }
mutcp "$ROOT/mut-b3"
sed -i 's/select((\.\[0\] | tostring) | IN("workers", "asks", "freeze", "queue", "lanes"))/select(false)/' "$ROOT/mut-b3/stall.sh"
if ! cmp -s "$HERE/../stall.sh" "$ROOT/mut-b3/stall.sh"; then
  SAVE_SCRIPT="$SCRIPT"; SCRIPT="$ROOT/mut-b3/stall.sh"
  f22base; LED='{"workers":{"w1":{"path":"/w/acme/la","host":"local","state":"parked","state":"running"}}}'; gen "$W"; runj "$W"
  check "B3 mutant (worker repeat): without the reason la is laddered again at rung 1 with a nudge due (exit 4), the harm" "$(field la rung)$(field la action)$RC" "1nudge4"
  f22base; LED="{\"workers\":{},\"asks\":[$B3ASK,\"state\":\"open\",\"state\":\"answered\"}]}"; gen "$W"; runj "$W"
  check "B3 mutant (ask repeat): without the reason the answered ask frees la into a nudge (exit 4), the harm" "$(field la rung)$RC" "14"
  SCRIPT="$SAVE_SCRIPT"
else check "B3 mutant: the sed matches stall.sh" "no" "yes"; fi
# rounds 3 and 4: an open own-scope ask that ask-timeout.sh keeps with the owner is OWNER-ONLY for stall too (ask_owner_why in ask-deny.sh): an ops, epic or pr-sweep lane (on the ask or only on its worker row), an epic
# "plan ready" approval, no lane at all, a blank worker id. The lane is held as "ask" either way, but the ASK ROW changes: owner-only gives an exempt row with code "owner" and no ladder row (exit 0), where the old
# predicate gave a laddered ask row (rung 1, exit 4) and no exempt row. So every case asserts the ask rows: exempt ask codes == ["owner"] and no ask row. A merge ask (already owner-only) is the control.
OPSASK='"kind":"code","state":"open","question":"split the card?","files":["src/components/Card.tsx"]'
op_ask() { jq -c '[[.exempt[] | select(.kind == "ask") | .code], [.rows[] | select(.kind == "ask") | .name]]' <<<"$OUT"; }
op_case() { # <label> <item name> <ledger json> <want ask exempt+rows json>
  reset; W="$ROOT/r3"; rm -rf -- "${W:?}"; ITEMS="$(arr "$(item "$2" idle 95)")"; LED="$3"; gen "$W"; runj "$W"
  check "R3 $1: the ask is exempt as owner and is not a ladder row" "$(op_ask)" "${4:-[[\"owner\"],[]]}"
}
OA="\"askedAt\":\"$(ago 95)\""
op_case "ops-sweeper ask (lane on the ask)" ops-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"ops-sweeper\",$OPSASK,$OA}]}"
op_case "ops-sweeper ask (lane only on the worker row)" ops-sweeper "{\"workers\":{\"w-ops\":{\"lane\":\"ops-sweeper\",\"path\":\"/w/acme/ops-sweeper\",\"host\":\"local\",\"state\":\"running\"}},\"asks\":[{\"id\":\"a1\",\"worker\":\"w-ops\",$OPSASK,$OA}]}"
op_case "epic lead ask" epic-cm-upgrade "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"epic-cm-upgrade\",$OPSASK,$OA}]}"
op_case "pr-sweep lane ask" pr-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"pr-sweeper\",$OPSASK,$OA}]}"
op_case "plan ready approval from a dev lane" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",\"kind\":\"design\",\"state\":\"open\",\"question\":\"plan ready: approve the epic plan?\",\"files\":[\"docs/plan.md\"],$OA}]}"
op_case "(a) no lane on the ask or its worker row" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",$OPSASK,$OA}]}"
op_case "(b) a blank worker id" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",\"worker\":\"  \",$OPSASK,$OA}]}"
op_case "control: an already owner-only merge ask" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",\"kind\":\"merge\",\"state\":\"open\",\"question\":\"merge it?\",$OA}]}"
op_case "control: a dev-sweeper own-scope ask with valid files stays a ladder row (not owner-only)" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",$OPSASK,$OA}]}" '[[],["a1"]]'
# (c) a worker row that is not an object and (d) a non-text worker lane: ask_owner_why calls them owner-only (digest-report-shape.sh pins that), but stall already stops judging ANY ask that tick on those rows (the
# input gap: exit 3, every ask unverified), so here the cases only pin that the ask is not laddered and the run says so. No mutant can tell them apart in stall.
reset; W="$ROOT/r3"; rm -rf -- "${W:?}"; ITEMS="$(arr "$(item dev-sweeper idle 95)")"
LED="{\"workers\":{\"w-bad\":false},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",\"worker\":\"w-bad\",$OPSASK,$OA}]}"; gen "$W"; runj "$W"
check "R3 (c) a worker row that is not an object: exit 3, the ask is not laddered" "$RC $(jq -c '[.rows[] | select(.kind == "ask")] | length' <<<"$OUT")" "3 0"
LED="{\"workers\":{\"w-nt\":{\"lane\":7,\"path\":\"/w/acme/dev-sweeper\",\"host\":\"local\",\"state\":\"running\"}},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",\"worker\":\"w-nt\",$OPSASK,$OA}]}"; gen "$W"; runj "$W"
check "R3 (d) a non-text worker lane: exit 3, the ask is not laddered" "$RC $(jq -c '[.rows[] | select(.kind == "ask")] | length' <<<"$OUT")" "3 0"
# mutants (cp -R, so scripts/jdupkeys comes along): each owner-only hold turned off alone puts the ask back on the ladder (rung 1, a due row, exit 4), the harm. The python edit turns the one elif that names the hold into false.
r4_mut() { # <dir> <message fragment of the hold, "pr-sweep", "ops", "plan">
  python3 - "$1/ask-deny.sh" "$2" <<'PY'
import sys,re
p,key=sys.argv[1],sys.argv[2]
t=open(p).read()
if key=='pr-sweep': t=t.replace(' or ($lane | startswith("pr-sweep"))',' or false')
elif key=='ops': t=t.replace('elif ($lane | startswith("ops")) or ($lane | startswith("epic"))','elif false or ($lane | startswith("epic"))')
else:
    out=[]
    for l in t.split('\n'):
        if 'elif ' in l and key in l: l=re.sub(r'elif .* then "of kind','elif false then "of kind',l,count=1)
        out.append(l)
    t='\n'.join(out)
open(p,'w').write(t)
PY
}
r4_case() { # <label> <hold key> <item name> <ledger json>
  local m="$ROOT/mut-r4-${2// /_}"; mkdir -p "$m" && cp -R "$HERE"/../. "$m"/ && r4_mut "$m" "$2"
  if cmp -s "$HERE/../ask-deny.sh" "$m/ask-deny.sh"; then check "R3 mutant $1: the edit changed ask-deny.sh" "no" "yes"; return; fi
  SAVE_SCRIPT="$SCRIPT"; SCRIPT="$m/stall.sh"
  reset; W="$ROOT/r3"; rm -rf -- "${W:?}"; ITEMS="$(arr "$(item "$3" idle 95)")"; LED="$4"; gen "$W"; runj "$W"
  SCRIPT="$SAVE_SCRIPT"
  check "R3 mutant $1: with the hold off the ask is a ladder row again (exit 4), the harm" "$RC $(op_ask)" '4 [[],["a1"]]'
}
r4_case "ops lane (on the ask)" ops ops-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"ops-sweeper\",$OPSASK,$OA}]}"
r4_case "ops lane (only on the worker row)" ops ops-sweeper "{\"workers\":{\"w-ops\":{\"lane\":\"ops-sweeper\",\"path\":\"/w/acme/ops-sweeper\",\"host\":\"local\",\"state\":\"running\"}},\"asks\":[{\"id\":\"a1\",\"worker\":\"w-ops\",$OPSASK,$OA}]}"
r4_case "pr-sweep lane" pr-sweep pr-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"pr-sweeper\",$OPSASK,$OA}]}"
r4_case "plan ready approval" "that is an epic plan approval" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",\"kind\":\"design\",\"state\":\"open\",\"question\":\"plan ready: approve the epic plan?\",\"files\":[\"docs/plan.md\"],$OA}]}"
r4_case "(a) no lane" "with no lane on the ask" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",$OPSASK,$OA}]}"
r4_case "(b) blank worker id" "with a blank worker id" dev-sweeper "{\"workers\":{},\"asks\":[{\"id\":\"a1\",\"lane\":\"dev-sweeper\",\"worker\":\"  \",$OPSASK,$OA}]}"
# round 6: a padded workers key is the worker its trimmed id names (its PR is seen), and two keys that trim to one id are no row, so a noCode ask of such a worker is the owner's. A padded key is also an input gap
# (exit 3), so the ask is never a ladder row either way; what the mutant changes is the exemption: with the exact-key lookup the ask is judged as an ask a worker with no PR could have asked, and it is "unverified", not "owner"
R6W='"path":"/w/acme/dev-sweeper","host":"local","state":"running"'
R6A='"kind":"code","state":"open","question":"split the card?","noCode":true,"lane":"dev-sweeper"'
r6_ask() { jq -c '[[.exempt[] | select(.kind == "ask") | .code], [.rows[] | select(.kind == "ask") | .name]]' <<<"$OUT"; }
r6_case() { # <label> <ledger json> <want> [<old text> <new text> to mutate ask-deny.sh with]
  local sv="$SCRIPT"
  if [ -n "${4:-}" ]; then
    local m="$ROOT/mut-r6-${1// /_}"; mkdir -p "$m" && cp -R "$HERE"/../. "$m"/
    python3 - "$m/ask-deny.sh" "$4" "$5" <<'PY'
import sys
p,old,new=sys.argv[1:4]
t=open(p).read()
if old in t: open(p,'w').write(t.replace(old,new,1))
PY
    if cmp -s "$HERE/../ask-deny.sh" "$m/ask-deny.sh"; then check "R6 mutant $1: the edit changed ask-deny.sh" "no" "yes"; return; fi
    SCRIPT="$m/stall.sh"
  fi
  reset; W="$ROOT/r6"; rm -rf -- "${W:?}"; ITEMS="$(arr "$(item dev-sweeper idle 95)")"; LED="$2"; gen "$W"; runj "$W"
  SCRIPT="$sv"
  check "R6 $1" "$RC $(r6_ask)" "$3"
}
R6PAD="{\"workers\":{\" w-r6p \":{\"lane\":\"dev-sweeper\",$R6W,\"pr\":5}},\"asks\":[{\"id\":\"a1\",\"worker\":\"w-r6p\",$R6A,$OA}]}"
R6TWO="{\"workers\":{\"w-r6d\":{\"lane\":\"dev-sweeper\",$R6W,\"pr\":6},\" w-r6d \":{\"lane\":\"dev-sweeper\",$R6W}},\"asks\":[{\"id\":\"a1\",\"worker\":\"w-r6d\",$R6A,$OA}]}"
r6_case "a noCode ask whose worker is a padded workers key with a PR: exempt owner, no ladder row (exit 3, the padded key is a gap)" "$R6PAD" '3 [["owner"],[]]'
r6_case "two workers keys that trim to one id: the ask is exempt owner, no ladder row" "$R6TWO" '3 [["owner"],[]]'
r6_case "mutant exact key: the padded key is not found, the ask is not owner-only (the harm)" "$R6PAD" '3 [["unverified"],[]]' '$wn.ws as $ws' '($workers | if type == "object" then . else {} end) as $ws'
r6_case "mutant two keys: the last row wins, the ask is not owner-only (the harm)" "$R6TWO" '3 [["unverified"],[]]' '($wn.dup | index($wk)) != null' 'false'
# B4 C1: a state that is no known state at all (a typo, "", spaces) holds nothing, so a hold keyed on it would vanish: it is named, exit 3
for ast in weird '' ' ' mystery; do
  f23ask "B4 C1 ask state '$ast'" ".state = \"$ast\"" "ledger: .asks[0].state is not a known state"
done
for wst in mystery '' ' ' 'on-hold'; do
  f22base; LED="$(jq -nc --arg st "$wst" '{workers: {"w1": {path: "/w/acme/la", host: "local", state: $st}}}')"; f22chk "B4 C1 worker state '$wst'" "ledger: .workers.w1.state is not a known state"
done
f22base; LED='{"workers":{"w1":{"path":"/w/acme/la","host":"local"}}}'; gen "$W"; runj "$W"
check "B4 C1 control: a worker with no state is the legacy running, judged (not exit 3)" "$([ "$RC" -ne 3 ] && echo judged || echo "exit $RC")" "judged"
# B4 C2: a null member of a list or a map drops the hold it would give: named, exit 3
f22base; LED='{"workers":{"w1":null}}'; f22chk "B4 C2 workers.w1 null" "ledger: .workers.w1 is null"
f22base; LED='{"workers":{},"asks":[null]}'; f22chk "B4 C2 asks [null]" "ledger: .asks[0] is null"
f22base; LED='{"workers":{}}'; ASKS='[null]'; f22chk "B4 C2 asks.json asks [null]" "asks: .asks[0] is null"
f22base; WTS='[null]'; LED='{"workers":{}}'; f22chk "B4 C2 discover worktrees [null]" "discover: .worktrees[0] is null"
# B4 C3: a blank id, host, path or class matches nothing, so the hold on it is lost: named, exit 3
for fld in path host lane worktreeId; do
  f22base; LED="$(jq -nc --arg f "$fld" '{workers: {"w1": ({path: "/w/acme/la", host: "local", state: "parked"} + {($f): "  "})}}')"; f22chk "B4 C3 parked worker $fld blank" "ledger: .workers.w1.$fld is blank text"
done
# (a ledger ask with a blank id, worker or lane is NOT unreadable: F18c and F18e keep it as a documented design, an ask is real only with a non-empty string id)
f22base; ITEMS="$(arr "$(item la idle 95 | jq -c '.class = ""')")"; f22chk "B4 C3 classification class blank" "classify: .items[0].class is blank text"
# B4 O2: a standing-unknown-state lane (classify.jq) is never nudged: unverified, never laddered
f22base; ITEMS="$(arr "$(item la standing-unknown-state 95 local standing)")"; LED='{"workers":{}}'; gen "$W"; runj "$W"
check "B4 O2 a standing-unknown-state lane is unverified and never laddered" "$(exr la)$(field la rung)" "unverifiedabsent"
for wst in Parked Blocked-On-Owner ' parked ' RUNNING; do
  f22base; LED="$(jq -nc --arg st "$wst" '{workers: {"w1": {path: "/w/acme/la", host: "local", state: $st}}}')"; f22chk "G worker state '$wst'" "ledger: .workers.w1.state is a near miss of a known state"
done
f22base; LED='{"workers":{"w1":{"path":"/w/acme/la","host":"local","state":"torn-down"}}}'; gen "$W"; runj "$W"
check "F23 G control: a legacy spelling (torn-down) is a known state, read as gone: no gap, exit 0" "$(jq -r ".gaps | length" <<<"$OUT")$RC" "00"
for qst in Queued GRANTED ' queued'; do
  f22base; LED="$(jq -nc --arg st "$qst" '{workers: {}, queue: {items: [{id: "q1", lane: "dev-sweeper", state: $st}]}}')"; f22chk "G queue item state '$qst'" "ledger: .queue.items[0].state is a near miss of a known state"
done
# G2: a worker id is matched exactly, an ask names its worker trimmed: a padded key is never found, so a noCode ask whose worker
# has a PR (the owner's) fell through to the ladder
reset; W="$ROOT/f23g2"; rm -rf -- "${W:?}"; ITEMS="$(arr "$(item lz idle 95)")"
LED0="$(jq -nc --arg f "$(ago 95)" '{workers: {"w-z": {state: "running", path: "/w/acme/lz", host: "local", pr: 7}},
  asks: [{id: "a-z", kind: "code", noCode: true, worker: "w-z", state: "open", question: "split the card?", askedAt: $f}]}')"
LED="$LED0"; gen "$W"; runj "$W"
check "F23 G2 control: the noCode ask whose worker w-z has a PR stays the owner's (exit 0)" "$(exr a-z)$(field a-z rung)$RC" "ownerabsent0"
LED="$(jq -c '.workers = {" w-z ": .workers["w-z"]}' <<<"$LED0")"; gen "$W"; runj "$W"
check "F23 G2 a worker key padded with spaces: exit 3, the ask is never relayed, lz is unverified" "$RC$(field a-z rung)$(exr lz)" "3absentunverified"
has "F23 G2 the gap names the padded key" "$(jq -r '.gaps | join(";")' <<<"$OUT")" 'ledger: .workers[" w-z "] is a worker id with surrounding white space'
# B: a map key is part of a gap path and may be a credential: it is withheld from --json, stderr and the text report
rep() { printf "%${2}s" '' | tr ' ' "$1"; }
KEY="gh""p_$(rep Q 36)"
reset; W="$ROOT/f23b"; rm -rf -- "${W:?}"; ITEMS="$(arr "$(item la idle 95)")"
for shape in workers lanes; do
  if [ "$shape" = workers ]; then LED="$(jq -nc --arg k "$KEY" '{workers: {($k): {host: 7, path: "/w/acme/la", state: "running"}}}')"
  else LED="$(jq -nc --arg k "$KEY" '{workers: {}, lanes: {($k): {queue: "x"}}}')"; fi
  gen "$W"; runj "$W"; J="$OUT"; run "$W"; T="$OUT"
  check "F23 B a credential-shaped $shape key: exit 3 (the value under it is unreadable)" "$RC" "3"
  has "F23 B $shape key: the gap is still reported" "$(jq -r '.gaps | join(";")' <<<"$J")" "[withheld: looks like a credential]"
  case "$J$T$(cat "$W/err")" in *"${KEY:0:12}"*) check "F23 B $shape key: no part of the key is in --json, the text report or stderr" "present" "absent" ;; *) check "F23 B $shape key: no part of the key is in --json, the text report or stderr" "absent" "absent" ;; esac
done
LED='{"workers":{"w-plain":{"host":7,"path":"/w/acme/la","state":"running"}}}'; gen "$W"; runj "$W"
has "F23 B control: a plain worker key is still named in the gap" "$(jq -r '.gaps | join(";")' <<<"$OUT")" "ledger: .workers.w-plain.host is not text"
# E: each guard has its own named row: removing the guard turns it red (revert-checked in the round-5 report)
f22base; LED='{"workers":{},"queue":{"items":[7]}}'; f22chk "E queue.items member as a number" "ledger: .queue.items[0] is not an object"
f22base; LED='{"workers":{},"queue":{"items":[{"lane":7,"state":"queued"}]}}'; f22chk "E queue item lane as a number" "ledger: .queue.items[0].lane is not text"
f22base; LED='{"workers":{},"lanes":{"dev-sweeper":{"queue":"x"}}}'; f22chk "E lanes.<lane>.queue as text" "ledger: .lanes.dev-sweeper.queue is not a list"
f22base; DEAD='[{"lead":"lx","open":"kid"}]'; f22chk "E ownership.leadDead[0].open as text" "classify: .ownership.leadDead[0].open is not a list"
f22base; DEAD='[{"lead":"lx","open":[7]}]'; f22chk "E ownership.leadDead[0].open member as a number" "classify: .ownership.leadDead[0].open[0] is not text"
f22base; UNREACH='[{"host":7}]'; f22chk "E asks unreachable[0].host as a number" "asks: .unreachable[0].host is not text"
f22base; HOSTS='[{"name":"local","reachable":true,"truncated":"true"}]'; f22chk "E discover hosts[0].truncated as text (a cut-off worktree list)" "discover: .hosts[0].truncated is not true or false"
f22base; HOSTS='[{"name":"local","reachable":true,"truncated":true}]'; gen "$W"; runj "$W"
check "F23 E control: truncated true makes la unverified by the host (no gap, exit 0)" "$(exr la)$RC" "unverified0"
f22base; HOSTS='[{"name":"local","reachable":true,"truncated":false}]'; gen "$W"; runj "$W"
check "F23 E control: truncated false: la ladders" "$(field la rung)" "1"

# F22 the delegated classes come from config only: no drive key (or one that is not a list) delegates nothing, so every
# release or deploy ask is the owner's; a fragment that does not compile is dropped and the others still count
sed '/^drive:/,$d' "$ROOT/config.yaml" > "$ROOT/config-nodrive.yaml"
{ sed '/^drive:/,$d' "$ROOT/config.yaml"; printf 'drive:\n  delegated_classes:\n    - "(unclosed"\n    - "store build"\n'; } > "$ROOT/config-badfrag.yaml"
{ sed '/^drive:/,$d' "$ROOT/config.yaml"; printf 'drive:\n  delegated_classes: "store build"\n'; } > "$ROOT/config-notlist.yaml"
{ sed '/^drive:/,$d' "$ROOT/config.yaml"; printf 'drive:\n  delegated_classes: []\n'; } > "$ROOT/config-empty.yaml"
reset; W="$ROOT/f22"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "e-rel", kind: "release", askedAt: $f, question: "ship the store build", state: "open"},
    {id: "e-dep", kind: "deploy", askedAt: $f, question: "approve the store build", state: "open"},
    {id: "e-any", kind: "release", askedAt: $f, question: "cut the next one", state: "open"},
    {id: "e-code", kind: "code", issue: 5, lane: "dev-1", askedAt: $f, question: "split the card list?", noCode: true, state: "open"}]}')"
gen "$W"
CM_CONFIG="$ROOT/config-nodrive.yaml" runj "$W"
check "F22 no drive key: a release ask is the owner's" "$(exr e-rel)$(field e-rel rung)" "ownerabsent"
check "F22 no drive key: a deploy ask is the owner's" "$(exr e-dep)$(field e-dep rung)" "ownerabsent"
check "F22 no drive key: a free-wording release ask is the owner's" "$(exr e-any)$(field e-any rung)" "ownerabsent"
check "F22 no drive key: an own-scope code ask still ladders" "$(exr e-code)$(field e-code rung)" "absent1"
CM_CONFIG="$ROOT/config-empty.yaml" runj "$W"
check "F22 an empty class list: a release ask is the owner's" "$(exr e-rel)$(field e-rel rung)" "ownerabsent"
check "F22 an empty class list: a free-wording release ask is the owner's" "$(exr e-any)$(field e-any rung)" "ownerabsent"
CM_CONFIG="$ROOT/config-notlist.yaml" runj "$W"
check "F22 a class list that is not a list: a release ask is the owner's" "$(exr e-rel)$(field e-rel rung)" "ownerabsent"
CM_CONFIG="$ROOT/config-badfrag.yaml" runj "$W"
check "F22 an invalid fragment is dropped, the valid class still counts: laddered" "$(exr e-rel)$(field e-rel rung)" "absent1"
check "F22 an invalid fragment is dropped: a deploy ask of the valid class ladders" "$(exr e-dep)$(field e-dep rung)" "absent1"
check "F22 an invalid fragment is dropped: free wording is still the owner's" "$(exr e-any)$(field e-any rung)" "ownerabsent"
check "F22 an invalid fragment does not stop the run (rows are listed)" "$(jq -r '.rows | length > 0' <<<"$OUT")" "true"
# F22b a fragment config-check refuses (a bracket class with a repeat) is dropped at runtime too, with a warning: it would
# let a free-wording release ask pass as the class ("ship the store foo bar baz build to production")
{ sed '/^drive:/,$d' "$ROOT/config.yaml"; printf 'drive:\n  delegated_classes:\n    - "store [a-z ]+"\n    - "ship [^x]*"\n    - "store build"\n'; } > "$ROOT/config-repfrag.yaml"
reset; W="$ROOT/f22b"
LED="$(jq -nc --arg f "$(ago 95)" '{workers: {}, asks: [
    {id: "e-wide", kind: "release", askedAt: $f, question: "ship the store foo bar baz build to production", state: "open"},
    {id: "e-rel", kind: "release", askedAt: $f, question: "ship the store build", state: "open"}]}')"
gen "$W"
CM_CONFIG="$ROOT/config-repfrag.yaml" runj "$W"
check "F22b a repeated bracket class is dropped: a free-wording release ask is the owner's" "$(exr e-wide)$(field e-wide rung)" "ownerabsent"
check "F22b ...the valid class still ladders" "$(exr e-rel)$(field e-rel rung)" "absent1"
has "F22b ...and the dropped fragments are named in a warning" "$(cat "$W/err")" "dropped, not a class phrase (scripts/config-check.sh): store [a-z ]+, ship [^x]*"

# ---- 13b. an ask climbs the ladder and its resolution reaches the ledger ----------------------------------------------
# F23 rung 2 of an ask has a non-closing action (escalate), so the ladder reaches the rung 3 verdict; close-ask and verdict
# set the ledger ask's state in the same write, so ask-timeout.sh stops reporting the ask VERDICT DUE
ASKT="$(dirname "$SCRIPT")/ask-timeout.sh"
due() { CM_HOME="$1/cm" CM_CONFIG=/nonexistent CM_NOW="$T0" bash "$ASKT" --ledger "$1/led.json" 2>/dev/null | grep -o '^due=[0-9]*'; }
reset; W="$ROOT/f23"
LED="$(jq -nc --arg f "$(ago 95)" --arg t "$(ago 65)" '{workers: {}, asks: [
    {id: "d-esc", kind: "code", issue: 5, lane: "lx", askedAt: $f, timeoutAt: $t, question: "split it?", noCode: true, state: "open"}]}')"
gen "$W"; runj "$W"
check "F23 a delegated ask starts on rung 1: relay" "$(field d-esc rung)$(field d-esc action)" "1relay"
check "F23 it is verdict-due for the away timeout" "$(due "$W")" "due=1"
act "$W" "$(ago 40)" ask d-esc relay "relayed"; runj "$W"
check "F23 after the relay: rung 2 offers escalate or close-ask" "$(field d-esc rung)$(field d-esc action)" "2escalate|close-ask"
act "$W" "$(ago 20)" ask d-esc escalate "escalated to the owner again"; check "F23 --act escalate on an ask: accepted" "$?" "0"
runj "$W"
check "F23 after escalate: rung 3 offers the verdict, the ask is still open" "$(field d-esc rung)$(field d-esc action)$(jq -r '.asks[0].state' "$W/led.json")" "3verdictopen"
act "$W" "$T0" lane lx escalate "no"; check "F23 escalate on a lane is refused, exit 2" "$?" "2"
act "$W" "$(ago 5)" ask d-esc verdict "independent verdict: go"; check "F23 --act verdict on an ask: accepted" "$?" "0"
check "F23 the verdict resolves the ledger ask: state decided" "$(jq -r '.asks[0] | "\(.state) \(.decidedBy)"' "$W/led.json")" "decided concertmaster"
check "F23 the ledger ask names the decision it was decided by" "$(jq -r '.asks[0].decisionRef == .decisions[0].id' "$W/led.json")" "true"
check "F23 ask-timeout.sh no longer reports it VERDICT DUE" "$(due "$W")" "due=0"
reset; W="$ROOT/f23b"
LED="$(jq -nc --arg f "$(ago 95)" --arg t "$(ago 65)" '{workers: {}, asks: [
    {id: "d-cls", kind: "code", issue: 6, lane: "ly", askedAt: $f, timeoutAt: $t, question: "split it?", noCode: true, state: "open"},
    {id: "d-twin", kind: "code", issue: 7, lane: "lz", askedAt: $f, timeoutAt: $t, question: "q", noCode: true, state: "open"},
    {id: "d-twin", kind: "code", issue: 8, lane: "lz", askedAt: $f, timeoutAt: $t, question: "q", noCode: true, state: "open"}]}')"
gen "$W"; runj "$W"
act "$W" "$(ago 40)" ask d-cls relay "relayed"
act "$W" "$(ago 20)" ask d-cls close-ask "closed: decided no-go"; check "F23b --act close-ask on an ask: accepted" "$?" "0"
check "F23b close-ask closes the ledger ask" "$(jq -r '.asks[0] | "\(.state) \(.closedBy) \(.closeReason)"' "$W/led.json")" "closed concertmaster closed: decided no-go"
check "F23b ask-timeout.sh no longer reports the closed ask VERDICT DUE" "$(CM_HOME="$W/cm" CM_CONFIG=/nonexistent CM_NOW="$T0" bash "$ASKT" --ledger "$W/led.json" 2>/dev/null | grep -c 'VERDICT DUE d-cls')" "0"
act "$W" "$(ago 20)" ask d-twin close-ask "closed"
check "F23b a duplicate open id is ambiguous: the action is recorded, the ledger asks stay open" "$(jq -r '[.asks[1:][] | .state] | join(",")' "$W/led.json")" "open,open"

# F24 an ask whose verdict is claimed is held while the claim lasts; a long kebab lane name is not a credential
reset; W="$ROOT/f24"
LONG="feature-long-kebab-lane-name-for-the-epic-x"
ITEMS="$(arr "$(item "$LONG" idle 500)")"
LED="$(jq -nc --arg f "$(ago 120)" --arg c "$(ago 1)" --arg o "$(ago 45)" '{workers: {}, asks: [
    {id: "d-claim", kind: "code", issue: 5, lane: "lc", askedAt: $f, verdictStartedAt: $c, question: "split it?", noCode: true, state: "open"},
    {id: "d-old", kind: "code", issue: 6, lane: "lo2", askedAt: $f, verdictStartedAt: $o, question: "split it?", noCode: true, state: "open"}]}')"
gen "$W"; runj "$W"
check "F24 a long kebab lane name is shown, not withheld" "$(field "$LONG" name)" "$LONG"
check "F24 an ask with a fresh verdict claim is held, not laddered" "$(exr d-claim)$(field d-claim rung)" "heldabsent"
check "F24 an ask whose claim expired ladders again" "$(exr d-old)$(field d-old rung)" "absent1"
check "F24 the held ask reason names the claim" "$(jq -r '.exempt[] | select(.name == "d-claim") | .reason | contains("verdict claimed")' <<<"$OUT")" "true"

# ---- 13c. the mkdir fallback lock of --act (no flock, stock macOS) -------------------------------------------------------
# F25 a lock a killed run left (over a minute old, owner pid gone) is reclaimed and the action recorded; a lock whose owner is
# alive stays busy and nothing is recorded. PATH holds every tool but flock, so the fallback runs.
NOFLOCK="$ROOT/noflock"; mkdir -p "$NOFLOCK"
IFS=: read -r -a _pdirs <<<"$PATH"
for _d in "${_pdirs[@]}"; do for _f in "$_d"/*; do
  _n="${_f##*/}"; [ "$_n" = flock ] || [ -e "$NOFLOCK/$_n" ] || ln -s "$_f" "$NOFLOCK/$_n" 2>/dev/null
done; done
DEADPID="$(sh -c 'echo $$')"
reset; W="$ROOT/f24"; LED='{"workers":{}}'; gen "$W"; mkdir -p "$W/cm"
mkdir "$W/cm/stall-actions.lock.d"; echo "$DEADPID" > "$W/cm/stall-actions.lock.d/pid"; touch -t 202001010000 "$W/cm/stall-actions.lock.d"
PATH="$NOFLOCK" act "$W" "$T0" lane l60 nudge "nudged: after a killed run"; RCA=$?
check "F25 a stale lock (old, owner dead) is reclaimed: recorded, lock released" "$RCA/$(wc -l < "$W/cm/stall-actions.ndjson" | tr -d ' ')/$(find "$W/cm" -maxdepth 1 -name "stall-actions.lock.d*" | wc -l | tr -d ' ')" "0/1/0"
mkdir "$W/cm/stall-actions.lock.d"; echo "$$" > "$W/cm/stall-actions.lock.d/pid"; touch -t 202001010000 "$W/cm/stall-actions.lock.d"
PATH="$NOFLOCK" act "$W" "$T0" lane l90 nudge "nudged: lock held"; RCA=$?
check "F25 an old lock whose owner is alive stays busy: nothing recorded, the lock is left" "$RCA/$(wc -l < "$W/cm/stall-actions.ndjson" | tr -d ' ')/$(cat "$W/cm/stall-actions.lock.d/pid")" "1/1/$$"
has "F25 ...and the refusal says busy" "$(cat "$W/act.err")" "busy: nothing recorded"
rm -rf -- "${W:?}/cm/stall-actions.lock.d"

# F26 the reclaim race: the stale lock is judged, then (staged at the rename) a killed lock is replaced by a live
# owner's fresh one, so the rename moves the live lock. The tombstone is judged again: not the lock judged, so it is
# kept, never deleted, and the run retries before it enters. A holder whose lock was taken away records nothing.
sleep 120 & LIVE=$!
LOCKD="$W/cm/stall-actions.lock.d"
mkdir "$LOCKD"; echo "$DEADPID" > "$LOCKD/pid"; touch -t 202001010000 "$LOCKD"
: > "$W/cm/stall-actions.ndjson"
# shellcheck disable=SC2016  # the hook is an sh -c program: its $1 and $2 are its own
CM_TEST=1 CM_TEST_ACT_LOCK_HOOK='[ "$1" = retire ] && [ ! -e "$2.c" ] && rm -rf -- "$2" && mkdir "$2" && echo '"$LIVE"' > "$2/pid" && : > "$2.c"' \
  PATH="$NOFLOCK" act "$W" "$T0" lane l60 nudge "nudged: after a reclaim race"; RCA=$?
TOMB="$(find "$W/cm" -maxdepth 1 -name 'stall-actions.lock.d.dead.*' | head -n 1)"
check "F26 a live lock moved by a racing reclaim is kept as a tombstone with its owner pid, never deleted" "$([ -n "$TOMB" ] && cat "$TOMB/pid")" "$LIVE"
check "F26 ...the run retried and entered only after the move: one line, lock released" "$RCA/$(wc -l < "$W/cm/stall-actions.ndjson" | tr -d ' ')/$([ -e "$LOCKD" ] && echo held || echo free)" "0/1/free"
rm -rf -- "${LOCKD:?}" "$LOCKD.c" "$W"/cm/stall-actions.lock.d.dead.*
# shellcheck disable=SC2016  # the hook is an sh -c program: its $1 and $2 are its own
CM_TEST=1 CM_TEST_ACT_LOCK_HOOK='[ "$1" = held ] && mv "$2" "$2.away" && mkdir "$2" && echo '"$LIVE"' > "$2/pid"' \
  PATH="$NOFLOCK" act "$W" "$T0" lane l60 nudge "nudged: lock taken away"; RCA=$?
check "F26 a holder whose lock was taken over records nothing and leaves the new owner's lock" "$RCA/$(wc -l < "$W/cm/stall-actions.ndjson" | tr -d ' ')/$(cat "$LOCKD/pid")" "1/1/$LIVE"
has "F26 ...and says so" "$(cat "$W/act.err")" "was taken over while held: nothing recorded"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
rm -rf -- "${LOCKD:?}" "$LOCKD.away"
# F27 the owner pid cannot be written: the append fails and says why, and the lock it made is released
if [ "$(id -u)" != 0 ]; then
  # shellcheck disable=SC2016  # the hook is an sh -c program: its $1 and $2 are its own
  CM_TEST=1 CM_TEST_ACT_LOCK_HOOK='[ "$1" = made ] && chmod 500 "$2"' \
    PATH="$NOFLOCK" act "$W" "$T0" lane l60 nudge "nudged: pid unwritable"; RCA=$?
  check "F27 an unwritable owner pid: nothing recorded, the lock released" "$RCA/$(wc -l < "$W/cm/stall-actions.ndjson" | tr -d ' ')/$([ -e "$LOCKD" ] && echo held || echo free)" "1/1/free"
  has "F27 ...and the reason is given" "$(cat "$W/act.err")" "cannot write the owner pid into"
fi

# ---- 14. no fleet CLI, no gh --------------------------------------------------------------------------------------------
check "orca, plugly, gh and ssh were never called" "$(wc -l < "$CALLS" | tr -d ' ')" "0"

printf 'stall: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
