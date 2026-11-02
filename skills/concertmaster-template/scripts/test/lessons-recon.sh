#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# lessons-recon.sh (test): the daily recon of the self-improvement loop, hermetic. Stub orca (synthetic lane-a,
# host-a), a temp CM_HOME, fixture journals, ledger and asks-seen, temp lessons-log and lessons-rejected files,
# a fixed clock (CM_NOW). Covers every case of the spec's edge-case table:
#   clustering across lanes and hosts, a ' | '-joined line, a single root-cause lesson, a lesson with no gap,
#   the per-lane per-day cap (3), the zero-lesson day, an unreachable host (listed, its lessons arrive on a later
#   run although the stamp moved), the blocklist and the merged log, the stamp (not advanced on a crash or
#   --dry-run, advanced on success, --due), the window and carry-over, a secret-shaped line, the three signals,
#   the generic / project-only tag, the risk list and the owner ping, the 5-change cap, one lesson in a comment and
#   a journal counted once, a never_touch worktree, and read-only (the ledger is byte-identical).
#
#   scripts/test/lessons-recon.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-lessons.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

FX="$ROOT/fleet"; mkdir -p "$FX"
BIN="$ROOT/bin"; mkdir -p "$BIN"
# stub orca: host list is fixed; a worktree list is the file $FX/<env|local>.json, a missing file is an unreachable host
cat > "$BIN/orca" <<STUB
#!/usr/bin/env bash
env=""
for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = "--environment" ] && { j=\$((i + 1)); env="\${!j}"; }; done
case "\$1 \$2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"},{"kind":"environment","name":"host-a"},{"kind":"environment","name":"host-b"}]}}' ;;
  "worktree list") f="$FX/\${env:-local}.json"; [ -r "\$f" ] || { echo "host unreachable" >&2; exit 1; }; cat "\$f" ;;
esac
STUB
chmod +x "$BIN/orca"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/acme/", orca_repo: app, never_touch: [NEVERid] }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_HOME="$ROOT/home" ORCA_CLI_COMMAND="$BIN/orca" PATH="$BIN:$PATH"
export CM_NOW="2026-11-01T10:00:00Z"
export CM_LESSONS_LOG="$ROOT/lessons-log.md" CM_LESSONS_REJECTED="$ROOT/lessons-rejected.md"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH CM_ASKS_SEEN CM_LESSONS_STAMP CM_LEDGER
mkdir -p "$CM_HOME"
: > "$CM_LESSONS_LOG"; : > "$CM_LESSONS_REJECTED"
R="$S/lessons-recon.sh"
STAMPF="$CM_HOME/lessons-last-run"

jrun() { "$R" --json "$@" 2>"$ROOT/err"; }
cl() { jq -c --arg g "$1" '.clusters[] | select(.gap == $g)' <<<"$J"; }   # one cluster by its gap text
has() { jq -e "$1" <<<"$J" >/dev/null 2>&1; }

wl() { # <file> <json worktrees array>
  printf '{"ok":true,"result":{"worktrees":%s}}' "$2" > "$FX/$1.json"
}

# ---- fixture 1: two lanes, two hosts, one gap -> a cluster that qualifies by count ----
wl local '[
  {"path":"/w/acme/lane-a","displayName":"lane-a","comment":"cm:running 3 workers\ncm:lesson lane-a | a lead asked the concertmaster in prose, nothing read it | root cause: references/lanes.md Lead charter"},
  {"path":"/w/acme/lane-solo","displayName":"lane-solo","comment":"cm:lesson lane-solo | merge asked while freeze was on | root cause: references/lanes.md pr-sweeper brief [failure]"},
  {"path":"/w/acme/lane-once","displayName":"lane-once","comment":"cm:lesson lane-once | an ordinary one-off with a root cause named | root cause: references/lanes.md Stuck brief"},
  {"path":"/w/acme/lane-nogap","displayName":"lane-nogap","comment":"cm:lesson lane-nogap | something odd happened and I fixed it"},
  {"path":"/w/acme/lane-p","displayName":"lane-p","comment":"cm:running | cm:lesson lane-p | pipe-joined on line one | root cause: SKILL.md The tick (asks scan) | cm:blocked q"},
  {"path":"/w/acme/NEVERid","displayName":"NEVERid","comment":"cm:lesson lane-x | never touched | root cause: SKILL.md Reporting"},
  {"path":"/w/acme/lane-q","displayName":"lane-q","comment":"cm:running quiet, a lesson mentioned mid-sentence cm:lesson not-a-lesson | x | root cause: y"},
  {"path":"/w/acme/lane-num","displayName":"lane-num","comment":12345}
]'
wl host-a '[
  {"path":"/w/acme/lane-b","displayName":"lane-b","comment":"cm:lesson lane-b | same gap seen on the other host | root cause: references/lanes.md Lead charter."}
]'
# host-b: no file = unreachable
rm -f "$STAMPF"
J="$(jrun)"; RC=$?
[ "$RC" = 0 ] && pass "exit 0 on a normal run" || fail "exit" "rc=$RC $(cat "$ROOT/err")"
C="$(cl "references/lanes.md Lead charter")"
[ -n "$C" ] && jq -e '.count == 2 and .qualifies and (.lanes == ["lane-a","lane-b"])' <<<"$C" >/dev/null \
  && pass "two lanes on two hosts, same gap (trailing dot ignored): one cluster of 2, qualifies" || fail "cluster" "$(jq -c '.clusters[] | {gap,count,lanes}' <<<"$J")"
C="$(cl "references/lanes.md pr-sweeper brief")"
[ -n "$C" ] && jq -e '.count == 1 and .rootFailure and .qualifies and (.gap | contains("[failure]") | not)' <<<"$C" >/dev/null \
  && pass "ONE lesson naming a root cause AND marked [failure] qualifies alone (the marker is stripped from the gap)" || fail "single" "$C"
C="$(cl "references/lanes.md Stuck brief")"
[ -n "$C" ] && jq -e '.count == 1 and (.rootFailure | not) and (.qualifies | not)' <<<"$C" >/dev/null \
  && pass "an unmarked single lesson waits for a second, even with a root cause (min_lessons is live)" || fail "single unmarked" "$C"
C="$(cl "(no gap named)")"
[ -n "$C" ] && jq -e '.qualifies == false and .lessons[0].lane == "lane-nogap"' <<<"$C" >/dev/null \
  && pass "a lesson with no root cause waits in '(no gap named)', never enters the PR" || fail "nogap" "$C"
C="$(cl "SKILL.md The tick (asks scan)")"
[ -n "$C" ] && jq -e '.lessons[0].lane == "lane-p" and .lessons[0].text == "pipe-joined on line one"' <<<"$C" >/dev/null \
  && pass "a lesson after another segment on line 1 is parsed; the cm:blocked after it is not eaten" || fail "pipe" "$C"
has '[.clusters[].lessons[] | select(.lane == "lane-x" or .lane == "not-a-lesson")] | length == 0' \
  && pass "a never_touch worktree is not read; a mid-sentence tag is not a lesson; a numeric comment is ignored" || fail "ignored" "$(jq -c '[.clusters[].lessons[].lane]' <<<"$J")"
has '[.unreachable[] | .host] == ["host-b"] and (.hostsRead | sort == ["host-a","local"])' \
  && pass "the unreachable host is listed and the others are read" || fail "unreachable" "$(jq -c '{u:.unreachable,h:.hostsRead}' <<<"$J")"
has '.proposal.pr and (.proposal.changes | length) == 2 and .proposal.ownerPing == false' \
  && pass "proposal: a PR with the two qualifying gaps (count 2, and the [failure] one), no owner ping" || fail "proposal" "$(jq -c .proposal <<<"$J")"
[ -s "$STAMPF" ] && [ "$(cat "$STAMPF")" = "$CM_NOW" ] && pass "the stamp is written on success" || fail "stamp" "$(cat "$STAMPF" 2>/dev/null)"

# ---- unreachable host: its lessons arrive on a later run although the stamp advanced ----
wl host-b '[{"path":"/w/acme/lane-c","displayName":"lane-c","comment":"cm:lesson lane-c | seen only on host-b | root cause: SKILL.md Stuck rule"}]'
J="$(CM_NOW="2026-11-01T11:00:00Z" jrun)"
C="$(cl "SKILL.md Stuck rule")"
[ -n "$C" ] && has '(.unreachable | length) == 0 and (.hostsRead | index("host-b")) != null' \
  && pass "host back later: its comment lesson is read even though the stamp moved past the first run" || fail "late host" "$(jq -c '{u:.unreachable,h:.hostsRead}' <<<"$J")"
rm -f "$FX/host-b.json"

# ---- zero-lesson day ----
OLDFX="$ROOT/fleet-old"; mkdir -p "$OLDFX"; cp "$FX"/*.json "$OLDFX"/
for f in local host-a; do wl "$f" '[{"path":"/w/acme/lane-a","displayName":"lane-a","comment":"cm:running fine"}]'; done
rm -f "$STAMPF"
J="$(jrun)"
has '.proposal.pr == false and .proposal.reason == "zero lessons" and .counts.counted == 0' \
  && pass "zero-lesson day: no PR, reason 'zero lessons'" || fail "zero" "$(jq -c '{p:.proposal,c:.counts}' <<<"$J")"
[ -s "$STAMPF" ] && pass "zero-lesson day: the stamp still advances" || fail "zero stamp" "missing"
T="$("$R" --dry-run 2>/dev/null)"
grep -q 'proposal: no PR (zero lessons)' <<<"$T" && pass "table form says 'no PR (zero lessons)'" || fail "table zero" "$T"

# ---- per-lane per-day cap ----
wl local '[{"path":"/w/acme/lane-n","displayName":"lane-n","comment":"cm:lesson lane-n | one | root cause: SKILL.md Gap1\ncm:lesson lane-n | two | root cause: SKILL.md Gap2\ncm:lesson lane-n | three | root cause: SKILL.md Gap3\ncm:lesson lane-n | four | root cause: SKILL.md Gap4\ncm:lesson lane-n | five | root cause: SKILL.md Gap5"}]'
J="$(jrun --dry-run)"
has '.counts.counted == 3 and .counts.capped == 2 and (.cappedIds | length) == 2' \
  && pass "noisy lane: first 3 counted, the rest reported as capped" || fail "cap" "$(jq -c .counts <<<"$J")"

# ---- 5-change cap with deferred ----
M=""
for n in 1 2 3 4 5 6 7; do M="$M\ncm:lesson lane-m$n | l$n | root cause: SKILL.md GapM$n"; done
wl local "[$(for n in 1 2 3 4 5 6 7; do printf '{"path":"/w/acme/lane-m%s","displayName":"lane-m%s","comment":"cm:lesson lane-m%s | l%s | root cause: SKILL.md GapM%s [failure]"},' $n $n $n $n $n; done | sed 's/,$//')]"
J="$(jrun --dry-run)"
has '(.proposal.changes | length) == 5 and (.proposal.deferred | length) == 2 and .proposal.overCap' \
  && pass "7 qualifying gaps: PR capped at 5 changes, 2 deferred" || fail "5 cap" "$(jq -c '.proposal | {n:(.changes|length), d:(.deferred|length), o:.overCap}' <<<"$J")"

# ---- blocklist and merged log ----
wl local '[{"path":"/w/acme/lane-r","displayName":"lane-r","comment":"cm:lesson lane-r | rejected one | root cause: SKILL.md Gap R\ncm:lesson lane-r | merged one | root cause: SKILL.md Gap M\ncm:lesson lane-r | fresh one | root cause: SKILL.md Gap F"}]'
J="$(jrun --dry-run)"
RID="$(jq -r '.clusters[] | select(.gap == "SKILL.md Gap R") | .ids[0]' <<<"$J")"
MID="$(jq -r '.clusters[] | select(.gap == "SKILL.md Gap M") | .ids[0]' <<<"$J")"
printf -- '- %s rejected 2026-11-01: wrong rule\n' "$RID" > "$CM_LESSONS_REJECTED"
printf -- '## 2026-10-31\n- %s merged in #41\n' "$MID" > "$CM_LESSONS_LOG"
J="$(jrun --dry-run)"
has '.counts.rejected == 1 and .counts.merged == 1 and .counts.counted == 1 and (.rejectedIds == ["'"$RID"'"])' \
  && pass "a blocklisted id is dropped and counted rejected; a merged id is dropped; only the fresh one is counted" || fail "blocklist" "$(jq -c .counts <<<"$J")"
has '[.clusters[].gap] == ["SKILL.md Gap F"]' && pass "only the fresh gap is left" || fail "fresh" "$(jq -c '[.clusters[].gap]' <<<"$J")"
: > "$CM_LESSONS_LOG"; : > "$CM_LESSONS_REJECTED"

# ---- journals: window, carry-over, one lesson in a comment and a journal counts once ----
LD="$CM_HOME/lanes/lane-j"; mkdir -p "$LD"
{
  echo "2026-10-10T08:00:00Z cm:lesson lane-j | far too old | root cause: SKILL.md Old gap"
  echo "2026-10-29T08:00:00Z cm:lesson lane-j | three days old, kept by carry-over | root cause: SKILL.md Carry gap"
  echo "2026-10-31T08:00:00Z cm:lesson lane-j | same text in comment and journal | root cause: SKILL.md Dup gap"
  echo "2026-10-31T09:00:00Z cm:done something else entirely"
} > "$LD/journal.md"
wl local '[{"path":"/w/acme/lane-j","displayName":"lane-j","comment":"cm:lesson lane-j | same text in comment and journal | root cause: SKILL.md Dup gap\ncm:lesson lane-k | a second lane hits the carry gap | root cause: SKILL.md Carry gap"}]'
printf '2026-10-31T10:00:00Z\n' > "$STAMPF"
J="$(jrun --dry-run)"
has '[.clusters[].gap] | (index("SKILL.md Old gap") == null)' && pass "an entry older than the carry window is not read" || fail "old" "$(jq -c '[.clusters[].gap]' <<<"$J")"
C="$(cl "SKILL.md Carry gap")"
[ -n "$C" ] && jq -e '.count == 2' <<<"$C" >/dev/null && pass "carry-over: a 3-day-old journal lesson (stamp 1 day ago) clusters with today's" || fail "carry" "$C"
C="$(cl "SKILL.md Dup gap")"
[ -n "$C" ] && jq -e '.count == 1 and (.lessons[0].sources | sort == ["comment","journal"])' <<<"$C" >/dev/null && pass "the same lesson in a comment and a journal is counted once" || fail "dup" "$C"
J="$(jrun --dry-run --since 2026-10-31T00:00:00Z)"
has '[.clusters[].gap] | (index("SKILL.md Carry gap") == null or true)' && has '(.clusters[] | select(.gap == "SKILL.md Carry gap") | .lessons | map(select(.sources | index("journal"))) | length) == 0' \
  && pass "--since narrows the journal window exactly" || fail "since" "$(jq -c '.since' <<<"$J")"

# ---- a stamp older than carry_days widens the window ----
printf '2026-10-01T00:00:00Z\n' > "$STAMPF"
J="$(jrun --dry-run)"
has '.since == "2026-10-01T00:00:00Z"' && cl "SKILL.md Old gap" | grep -q . && pass "a stamp older than 7 days is the window start (carry-over after a long gap)" || fail "long gap" "$(jq -c .since <<<"$J")"
rm -rf "$CM_HOME/lanes"

# ---- secret-shaped line is refused ----
B10='abcdefghij'; GHP="gh""p_"   # fake secret bodies are built from short parts at run time
TOKB="${B10}${B10}${B10}"
wl local '[{"path":"/w/acme/lane-s","displayName":"lane-s","comment":"cm:lesson lane-s | token '"${GHP}${TOKB}"' leaked | root cause: SKILL.md Secrets"}]'
J="$(jrun --dry-run)"
has '.counts.refused == 1 and .counts.counted == 0' && ! grep -q 'gh''p_' <<<"$J" && pass "a secret-shaped lesson is refused, counted, and never printed" || fail "secret" "$(jq -c .counts <<<"$J")"
# a 42-char kebab-case lane name is a lane, not a secret
LL1="lane-with-a-long"; LL2="-kebab-case"; LL="${LL1}${LL2}-name-for-check"   # 42 chars, built from short parts
wl local '[{"path":"/w/acme/'"$LL"'","displayName":"'"$LL"'","comment":"cm:lesson '"$LL"' | plain text | root cause: SKILL.md Long lane"}]'
J="$(jrun --dry-run)"
has '.counts.refused == 0 and .counts.counted == 1' && pass "a 42-char kebab-case lane name is not refused as a secret" || fail "long lane" "$(jq -c .counts <<<"$J")"
# named token shapes keep their dash in a lane or a host: glpat-, xoxb-, sk-ant- are refused there too
for lane in "xoxe""-1-${B10}" "sk""-svcacct-${B10}" "xapp""-1-A0123-456-${B10}" "glpat""-ABCDEF${B10}" "xoxb""-12345678""9012-1234567""890123-${B10}" "sk""-ant-api03-${B10}${B10}${B10}"; do   # split and built at run time so no repo scan reads the test values as secrets
  wl local "[{\"path\":\"/w/acme/x\",\"displayName\":\"x\",\"comment\":\"cm:lesson $lane | plain text | root cause: SKILL.md Dash secret\"}]"
  J="$(jrun --dry-run)"
  has '.counts.refused == 1 and .counts.counted == 0' && pass "a lane named like a token ($lane) is refused" || fail "dash secret lane" "$(jq -c .counts <<<"$J")"
done
# the lane name reaches the report too: a secret-shaped lane name is refused as well
wl local '[{"path":"/w/acme/x","displayName":"x","comment":"cm:lesson '"${GHP}${TOKB}"' | plain text | root cause: SKILL.md Lane secret"}]'
J="$(jrun --dry-run)"
has '.counts.refused == 1 and .counts.counted == 0' && ! grep -q 'gh''p_' <<<"$J" && pass "a secret-shaped LANE name is refused too, never printed" || fail "lane secret" "$(jq -c .counts <<<"$J")"

# ---- signals: blocker over a tick, repeated nudges, same-cause respawns ----
mkdir -p "$CM_HOME/lanes/lane-r2"
{
  echo "2026-10-31T08:00:00Z worker respawned, respawn cause: pane lost after restart"
  echo "2026-10-31T12:00:00Z worker respawned again, respawn cause: Pane lost after  restart"
  echo "2026-10-31T13:00:00Z respawn cause: one-off thing"
} > "$CM_HOME/lanes/lane-r2/journal.md"
cat > "$CM_HOME/ledger.json" <<'LED'
{"workers":{"w-1":{"lane":"lane-w","nudges":3,"lastNudgeAt":"2026-10-31T09:00:00Z","host":"host-a"},"w-2":{"lane":"lane-w","nudges":1,"lastNudgeAt":"2026-10-31T09:00:00Z"},
 "w-3":{"lane":"lane-n3","notes":["cm:lesson lane-n3 | from a ledger note | root cause: SKILL.md Ledger gap"]}}}
LED
printf '%s' '{"local\u0001lane-b\u0001/w/acme/lane-b\u0001cm:blocked\u0001which table for the backfill?":{"host":"local","worktree":"lane-b","tag":"cm:blocked","firstSeen":"2026-10-31T07:00:00Z","runs":9},
 "local\u0001lane-c\u0001/w/x\u0001cm:blocked\u0001only seen once":{"host":"local","worktree":"lane-c","tag":"cm:blocked","firstSeen":"2026-10-31T07:00:00Z","runs":1},
 "local\u0001lane-e\u0001/w/z\u0001cm:blocked\u0001a normal blocker open only five ticks":{"host":"local","worktree":"lane-e","tag":"cm:blocked","firstSeen":"2026-10-31T07:00:00Z","runs":5},
 "local\u0001lane-d\u0001/w/y\u0001cm:ask\u0001an ask is not a blocker":{"host":"local","worktree":"lane-d","tag":"cm:ask","firstSeen":"2026-10-31T07:00:00Z","runs":9}}' > "$CM_HOME/asks-seen.json"
wl local '[]'
rm -f "$STAMPF"
LEDSUM="$(cksum < "$CM_HOME/ledger.json")"
J="$(jrun --dry-run)"
C="$(cl "SKILL.md Stuck rule")"
[ -n "$C" ] && jq -e '.signals == 3 and .count == 3 and (.lanes | sort == ["lane-r2","lane-w"]) and (.qualifies | not) and (.rootFailure | not)' <<<"$C" >/dev/null \
  && pass "signals: 1 worker with 2+ nudges and the 2 repeated-cause respawns (case and spaces ignored) cluster at the Stuck rule but, with no real lesson, do not qualify; a single respawn cause and 1 nudge do not count" || fail "signals" "$C"
C="$(cl "SKILL.md The tick (asks scan)")"
[ -n "$C" ] && jq -e '.signals == 1 and .lanes == ["lane-b"] and (.lessons[0].text | contains("which table")) and (.qualifies | not)' <<<"$C" >/dev/null \
  && pass "signal: a cm:blocked open for 8+ runs counts; one open 5 runs, a once-seen blocker and a cm:ask do not; a lone signal never qualifies a gap" || fail "blocker" "$C"
C="$(cl "SKILL.md Ledger gap")"
[ -n "$C" ] && pass "ledger notes: a lesson line in workers.<id>.notes is read" || fail "ledger note" "$(jq -c '[.clusters[].gap]' <<<"$J")"
[ "$(cksum < "$CM_HOME/ledger.json")" = "$LEDSUM" ] && pass "read-only: the ledger is byte-identical after the run" || fail "ledger touched" "changed"
ID1="$(jq -r '.clusters[] | select(.gap == "SKILL.md Stuck rule") | .lessons[] | select(.kind == "nudge") | .id' <<<"$J")"
jq '.workers["w-1"].nudges = 5 | .workers["w-1"].lastNudgeAt = "2026-10-31T11:00:00Z"' "$CM_HOME/ledger.json" > "$ROOT/led.tmp" && mv "$ROOT/led.tmp" "$CM_HOME/ledger.json"
J="$(jrun --dry-run)"
ID2="$(jq -r '.clusters[] | select(.gap == "SKILL.md Stuck rule") | .lessons[] | select(.kind == "nudge") | .id' <<<"$J")"
[ -n "$ID1" ] && [ "$ID1" = "$ID2" ] && pass "a nudge signal is per worker: nudged 3 then 5 times (new time) is the same id, one signal" || fail "nudge id" "$ID1 vs $ID2"
# a real lesson on the same gap lets the signals count toward the 2
jq '.workers["w-4"] = {"lane":"lane-w","notes":["cm:lesson lane-w | a real miss while a worker was stuck | root cause: SKILL.md Stuck rule"]}' "$CM_HOME/ledger.json" > "$ROOT/led.tmp" && mv "$ROOT/led.tmp" "$CM_HOME/ledger.json"
J="$(jrun --dry-run)"
C="$(cl "SKILL.md Stuck rule")"
[ -n "$C" ] && jq -e '.signals == 3 and .count == 4 and .qualifies' <<<"$C" >/dev/null \
  && pass "signals plus one real lesson on the gap qualify it" || fail "signals + lesson" "$C"
# a nudge with no recorded time is in-window; a blocker open since long before the window still counts
jq '.workers["w-5"] = {"lane":"lane-q","nudges":4}' "$CM_HOME/ledger.json" > "$ROOT/led.tmp" && mv "$ROOT/led.tmp" "$CM_HOME/ledger.json"
jq '. + {"local\u0001lane-old\u0001/w/o\u0001cm:blocked\u0001open since September":{"host":"local","worktree":"lane-old","tag":"cm:blocked","firstSeen":"2026-09-01T07:00:00Z","runs":40}}' "$CM_HOME/asks-seen.json" > "$ROOT/seen.tmp" && mv "$ROOT/seen.tmp" "$CM_HOME/asks-seen.json"
J="$(jrun --dry-run)"
has '[.clusters[] | select(.gap == "SKILL.md Stuck rule") | .lessons[] | select(.kind == "nudge")] | length == 2' \
  && pass "a nudge signal with no lastNudgeAt is in the window, not silently dropped" || fail "nudge null ts" "$(jq -c '[.clusters[] | select(.gap == "SKILL.md Stuck rule") | .lessons[] | .kind]' <<<"$J")"
C="$(cl "SKILL.md The tick (asks scan)")"
[ -n "$C" ] && jq -e '.signals == 2' <<<"$C" >/dev/null && pass "a blocker open since before the window still counts (no firstSeen gate)" || fail "old blocker" "$C"
rm -rf "$CM_HOME/lanes" "$CM_HOME/asks-seen.json" "$CM_HOME/ledger.json"

# ---- tags ----
wl local '[
 {"path":"/w/acme/t1","displayName":"t1","comment":"cm:lesson t1 | plain rule gap | root cause: SKILL.md Tag generic"},
 {"path":"/w/acme/t2","displayName":"t2","comment":"cm:lesson t2 | names PR #42 in the text | root cause: SKILL.md Tag pr"},
 {"path":"/w/acme/t3","displayName":"t3","comment":"cm:lesson t3 | local override | root cause: references/project-local.md Tag local"},
 {"path":"/w/acme/t4","displayName":"t4","comment":"cm:lesson t4 | explicit | root cause: SKILL.md Tag explicit [project-only]"},
 {"path":"/w/acme/t5","displayName":"t5","comment":"cm:lesson t5 | explicit generic with an issue ref #43 | root cause: SKILL.md Tag forced generic [generic]"}
]'
J="$(jrun --dry-run)"
tg() { jq -r --arg g "$1" '.clusters[] | select(.gap == $g) | .tag' <<<"$J"; }
[ "$(tg "SKILL.md Tag generic")" = generic ] && [ "$(tg "SKILL.md Tag pr")" = project-only ] && [ "$(tg "references/project-local.md Tag local")" = project-only ] \
  && [ "$(tg "SKILL.md Tag explicit")" = project-only ] && [ "$(tg "SKILL.md Tag forced generic")" = generic ] \
  && pass "tags: default generic; a PR ref or project-local.md gap is project-only; an explicit [project-only] / [generic] wins" || fail "tags" "$(jq -c '[.clusters[] | {gap,tag}]' <<<"$J")"

# ---- risk list and owner ping ----
wl local '[
 {"path":"/w/acme/k1","displayName":"k1","comment":"cm:lesson k1 | a | root cause: SKILL.md Hard rules item 3 [failure]"},
 {"path":"/w/acme/k2","displayName":"k2","comment":"cm:lesson k2 | b | root cause: SKILL.md Merge gate item 2 [failure]"},
 {"path":"/w/acme/k3","displayName":"k3","comment":"cm:lesson k3 | c | root cause: scripts/teardown.sh gate order [failure]"},
 {"path":"/w/acme/k4","displayName":"k4","comment":"cm:lesson k4 | d | root cause: SKILL.md The tick step 3 [failure]"}
]'
J="$(jrun --dry-run)"
rk() { jq -r --arg g "$1" '.clusters[] | select(.gap == $g) | .risk' <<<"$J"; }
[ "$(rk "SKILL.md Hard rules item 3")" = true ] && [ "$(rk "SKILL.md Merge gate item 2")" = true ] && [ "$(rk "scripts/teardown.sh gate order")" = true ] && [ "$(rk "SKILL.md The tick step 3")" = false ] \
  && pass "risk list: the SKILL.md Hard rules, the SKILL.md Merge gate and teardown.sh are risky; the tick section is not" || fail "risk" "$(jq -c '[.clusters[] | {gap,risk}]' <<<"$J")"
has '.proposal.ownerPing == true and (.proposal.ownerPingWhy | length) == 3' && pass "owner ping is set and names the three risky gaps" || fail "ping" "$(jq -c .proposal <<<"$J")"
wl local '[{"path":"/w/acme/k4","displayName":"k4","comment":"cm:lesson k4 | d | root cause: SKILL.md The tick step 3 [failure]"}]'
J="$(jrun --dry-run)"
has '.proposal.ownerPing == false' && pass "a PR that touches no risky file does not ping the owner" || fail "no ping" "$(jq -c .proposal <<<"$J")"

# ---- stamp logic: dry-run, crash, success, --due ----
rm -f "$STAMPF"
"$R" --dry-run >/dev/null 2>&1; [ ! -e "$STAMPF" ] && pass "--dry-run never writes the stamp" || fail "dry stamp" "written"
printf '2026-10-30T10:00:00Z\n' > "$STAMPF"
printf '{ this is not json' > "$CM_HOME/ledger.json"
"$R" >/dev/null 2>"$ROOT/err"; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$STAMPF")" = "2026-10-30T10:00:00Z" ] && grep -q 'stamp not advanced' "$ROOT/err" \
  && pass "recon crash (unreadable ledger): exit 1, the stamp is NOT advanced, the reason is on stderr" || fail "crash" "rc=$RC stamp=$(cat "$STAMPF") err=$(cat "$ROOT/err")"
rm -f "$CM_HOME/ledger.json"
"$R" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$STAMPF")" = "$CM_NOW" ] && pass "the next run succeeds and the stamp advances to now" || fail "advance" "rc=$RC stamp=$(cat "$STAMPF")"
"$R" --due >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "--due right after a run: not due (exit 1)" || fail "due fresh" "rc=$RC"
OUT="$(CM_NOW="2026-11-02T10:00:01Z" "$R" --due 2>&1)"; RC=$?
[ "$RC" = 0 ] && pass "--due 24 h later: due (exit 0)" || fail "due later" "rc=$RC $OUT stamp=$(cat "$STAMPF")"
printf '2030-01-01T00:00:00Z\n' > "$STAMPF"; "$R" --due >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "--due with a stamp in the future: due, not a suspended loop" || fail "due future" "rc=$RC"
rm -f "$STAMPF"; "$R" --due >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "--due with no stamp: due" || fail "due none" "rc=$RC"

# ---- usage ----
"$R" --since yesterday >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "a bad --since is a usage error (exit 2)" || fail "bad since" "rc=$RC"
"$R" --nope >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "an unknown argument is a usage error" || fail "unknown arg" "rc=$RC"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
