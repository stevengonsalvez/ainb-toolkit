#!/usr/bin/env bash
# Code review findings, sourced by run.sh. Every block was red before the fix it
# guards. Uses, from run.sh: OS P D TMP STUB_STATE REPO BARE OK_SHA ok bad is
# has hasnt sect refused ev_has setcfg mkpr

sect "C1 the same orchestrator can run two commands in a row"
# No ORCHESTRATE_SESSION anywhere: this is how an agent actually invokes it.
P2=prog2; D2="$ORCHESTRATE_HOME/$P2"
env -u ORCHESTRATE_SESSION "$OS" init "$P2" --trunk example-trunk --repo "$REPO" >/dev/null 2>&1
env -u ORCHESTRATE_SESSION "$OS" takeover "$P2" >/dev/null 2>&1
env -u ORCHESTRATE_SESSION "$OS" tick "$P2" >/dev/null 2>&1
is "a tick after a takeover is not refused" "$?" 0
env -u ORCHESTRATE_SESSION "$OS" mark "$P2" nosuch idle >/dev/null 2>&1
is "a later verb is not refused either" "$([ "$?" = 3 ] && echo refused || echo allowed)" allowed
is "the identity is persisted, not regenerated per process" \
  "$(cat "$D2/.session" 2>/dev/null)" "$(jq -r .session "$D2/owner.json" 2>/dev/null)"
out="$(ORCHESTRATE_SESSION=a-different-orchestrator "$OS" tick "$P2" 2>&1)"
is "an explicitly different orchestrator is still refused" "$?" 3
has "and told who holds it" "$out" "REFUSED owner-held"

sect "MAJ-6 the owner claim is atomic under concurrency"
rm -f "$D2/owner.json"
( . "$PLUGIN/scripts/lib.sh"; prog_open "$P2"
  rm -f "$TMP/wins"; touch "$TMP/wins"
  for i in 1 2 3 4 5 6; do
    ( ORCHESTRATE_SESSION="racer-$i" owner_claim_new >/dev/null 2>&1 && printf 'win\n' >> "$TMP/wins" ) &
  done
  wait ) >/dev/null 2>&1
is "exactly one of six concurrent claims wins" "$(grep -c win "$TMP/wins" 2>/dev/null || echo 0)" 1
is "and one owner file names one session" "$(jq -r '.session' "$D2/owner.json" | wc -l | tr -d ' ')" 1

sect "C2 re-adopt preserves what adopt does not own"
"$OS" mark "$P" A idle >/dev/null 2>&1
tmpl="$(mktemp)"
jq -c 'if .lane == "A" then .branch = "feat/lane-a" | .goal = "ship the gate" | .exclusive = ["e2e"] else . end' \
  "$D/lanes.jsonl" > "$tmpl" && mv "$tmpl" "$D/lanes.jsonl"
"$OS" adopt "$P" >/dev/null 2>&1
"$OS" adopt "$P" >/dev/null 2>&1
is "branch survives two re-adopts"    "$(jq -r 'select(.lane=="A") | .branch' "$D/lanes.jsonl")" feat/lane-a
is "goal survives"                    "$(jq -r 'select(.lane=="A") | .goal' "$D/lanes.jsonl")" "ship the gate"
is "exclusive survives"               "$(jq -r 'select(.lane=="A") | .exclusive[0]' "$D/lanes.jsonl")" e2e
is "the screen-derived fields still update" \
  "$(jq -r 'select(.lane=="A") | if .last_seen == "" then "stale" else "fresh" end' "$D/lanes.jsonl")" fresh

sect "C2 retire refuses a lane whose branch it does not know"
tmpl="$(mktemp)"
jq -c 'if .lane == "A" then .branch = "" else . end' "$D/lanes.jsonl" > "$tmpl" && mv "$tmpl" "$D/lanes.jsonl"
"$OS" retire "$P" A >/dev/null 2>&1
is "an unknown branch is refused, not waved through" "$?" 3
is "that refusal is an event" "$(refused retire-unknown-branch)" 1
tmpl="$(mktemp)"
jq -c 'if .lane == "A" then .branch = "feat/lane-a" else . end' "$D/lanes.jsonl" > "$tmpl" && mv "$tmpl" "$D/lanes.jsonl"

sect "C3 a handle is bound to its lane, and ambiguity refuses"
cat >> "$D/lanes.jsonl" <<'JSON'
{"lane":"SWEEP-1","env":"local","handle":"gone-1","worktree":"sweep","branch":"s1","agent":"claude","title":"SWEEP-1","status":"working","ctx_pct":"","last_seen":""}
{"lane":"SWEEP-2","env":"local","handle":"gone-2","worktree":"sweep","branch":"s2","agent":"claude","title":"SWEEP-2","status":"working","ctx_pct":"","last_seen":""}
{"lane":"SWEEP-3","env":"local","handle":"gone-3","worktree":"sweep","branch":"s3","agent":"claude","title":"","status":"working","ctx_pct":"","last_seen":""}
JSON
printf 'term-a\tSWEEP-1\nterm-b\tSWEEP-2\nterm-c\tother work\n' > "$STUB_STATE/terminals/sweep"
for h in term-a term-b term-c; do idle_screen "$h"; done
"$OS" tick "$P" >/dev/null 2>&1
is "a titled lane binds to its own terminal"   "$(jq -r 'select(.lane=="SWEEP-1") | .handle' "$D/lanes.jsonl")" term-a
is "so does the second"                        "$(jq -r 'select(.lane=="SWEEP-2") | .handle' "$D/lanes.jsonl")" term-b
is "an untitled lane in a crowded worktree is not guessed at" \
  "$(jq -r 'select(.lane=="SWEEP-3") | .handle' "$D/lanes.jsonl")" gone-3
is "it is marked for rebinding"                "$(jq -r 'select(.lane=="SWEEP-3") | .status' "$D/lanes.jsonl")" needs-rebind
is "the ambiguity is a refusal event"          "$([ "$(refused rebind-ambiguous)" -ge 1 ] && echo yes)" yes
before="$(cat "$STUB_STATE/sent/term-a.txt" 2>/dev/null | wc -l | tr -d ' ')"
"$OS" send "$P" SWEEP-3 - "SWEEP-3 only: stop the sweep" >/dev/null 2>&1
is "a lane that needs rebinding is never sent to" "$?" 3
is "and nothing reached another lane's terminal" \
  "$(cat "$STUB_STATE/sent/term-a.txt" 2>/dev/null | wc -l | tr -d ' ')" "$before"
is "no lane is bound to a handle another lane holds" \
  "$(jq -r '.handle' "$D/lanes.jsonl" | sort | uniq -d | wc -l | tr -d ' ')" 0

sect "C4 delivery is confirmed against the screen before the send"
idle_screen h-quiet
printf 'h-quiet\n' > "$STUB_STATE/terminals/quiet"
touch "$STUB_STATE/noecho/h-quiet"
cat >> "$D/lanes.jsonl" <<'JSON'
{"lane":"QUIET","env":"local","handle":"h-quiet","worktree":"quiet","branch":"q","agent":"claude","title":"QUIET","status":"working","ctx_pct":"","last_seen":""}
JSON
out="$("$OS" send "$P" QUIET - "a plain instruction the composer swallowed" 2>&1)"
has "a terminal that shows nothing back is unconfirmed" "$out" "unconfirmed -> QUIET"
is "and it is recorded unconfirmed" \
  "$(jq -r 'select(.ev=="notified" and .lane=="QUIET") | .result' "$D/events.jsonl" | tail -1)" unconfirmed
out="$("$OS" send "$P" QUIET - "   " 2>&1)"
is "a message with nothing in it is refused" "$?" 3
is "that refusal is an event" "$(refused send-empty)" 1
printf 'a plain instruction the composer swallowed\n' >> "$STUB_STATE/screens/h-quiet.txt"
out="$("$OS" send "$P" QUIET - "a plain instruction the composer swallowed" 2>&1)"
is "text already on screen before the send does not count as delivery" \
  "$(printf '%s' "$out" | grep -c 'unconfirmed -> QUIET')" 1

sect "C5 a tool that cannot answer makes the counters unknown, never zero"
"$OS" pr "$P" 301 A >/dev/null 2>&1
export STUB_GH_FAIL=1
out="$("$OS" owed "$P" 2>&1)"
has "owed says it could not ask" "$out" "owed-unknown"
hasnt "owed does not report zero" "$out" "0 owed"
out="$("$OS" tick "$P" 2>&1)"
has "the tick reports the counter as unknown" "$out" "open_prs=?"
has "and the exit expression is undecidable, never true" "$out" "exit=undecidable"
is "the tick did not claim the programme finished" "$?" 0
is "the degradation is an event" "$([ "$(ev_has degraded)" -ge 1 ] && echo yes)" yes
rm -f "$D/STOP"
out="$("$OS" loop "$P" --every 1s --max-ticks 1 2>&1)"
hasnt "the loop does not stop on an unreachable tool" "$out" "exit condition holds"
unset STUB_GH_FAIL

sect "C7 a missing autonomy key is not permission to merge"
cp "$D/programme.yaml" "$TMP/cfg2.bak"
sed -i.bak '/^autonomy:/d' "$D/programme.yaml" && rm -f "$D/programme.yaml.bak"
mkpr 230 example-trunk feat-ok "$OK_SHA"
"$OS" merge "$P" 230 "$OK_SHA" >/dev/null 2>&1
is "an absent autonomy key refuses the merge" "$?" 3
is "that refusal is an event" "$(refused merge-autonomy-unset)" 1
cp "$TMP/cfg2.bak" "$D/programme.yaml"

sect "MAJ-7 the attribution guard matches trailers, not sentences"
git -C "$REPO" checkout -q example-trunk
git -C "$REPO" checkout -qb feat-falsepos 2>/dev/null || git -C "$REPO" checkout -q feat-falsepos
printf 'frames\n' > "$REPO/frames.txt"
git -C "$REPO" add frames.txt
git -C "$REPO" commit -qm "$(printf 'fix: match the frames\n\nGenerated with UPDATE_PARITY_FRAMES=1 so the frames match.\n')"
git -C "$REPO" push -q -f origin feat-falsepos
FP_SHA="$(git -C "$REPO" rev-parse feat-falsepos)"
git -C "$REPO" checkout -q example-trunk
mkpr 220 example-trunk feat-falsepos "$FP_SHA"
setcfg autonomy merge_on_verdict
fpout="$("$OS" merge "$P" 220 "$FP_SHA" 2>&1)"
is "a variable assignment in a commit body is not attribution" "$?" 0
[ -n "$fpout" ] && printf '       (merge said: %s)\n' "$(printf '%s' "$fpout" | head -1)"
mkpr 221 example-trunk feat-attr "$ATTR_SHA"
"$OS" merge "$P" 221 "$ATTR_SHA" >/dev/null 2>&1
is "a real trailer is still refused" "$?" 3

sect "MAJ-9 a policy file with carriage returns still parses its walls"
printf 'trunk: example-trunk\r\nnever_merge_into: [main, master]\r\nautonomy: ask\r\n' > "$TMP/crlf.yaml"
is "the trunk has no carriage return" "$(yaml_flat "$TMP/crlf.yaml" | awk -F'\t' '$1=="trunk"{print $2}' | cat -A | grep -c '\^M')" 0
is "the list is not split on the bracket" "$(yaml_flat "$TMP/crlf.yaml" | awk -F'\t' '$1=="never_merge_into"{print $2}')" "main master"

sect "MAJ-3 a host with no timeout binary still bounds its calls"
is "the bounded runner returns the timeout code" "$(ORCHESTRATE_FORCE_WATCHDOG=1 run_bounded 1 sleep 5; echo $?)" 124
is "and passes a fast command straight through" "$(ORCHESTRATE_FORCE_WATCHDOG=1 run_bounded 5 printf ok)" ok

sect "MAJ-5 two ticks do not run over each other"
( "$OS" tick "$P" >/dev/null 2>&1 ) &
sleep 0.2
"$OS" tick "$P" >/dev/null 2>&1
is "the second tick is refused while the first runs" "$?" 3
wait
is "that refusal is an event" "$([ "$(refused tick-running)" -ge 1 ] && echo yes)" yes
is "no lock is left behind" "$([ -d "$D/.tick.lock" ] && echo held || echo free)" free

sect "MAJ-4 a wedged tick does not hang the loop, and STOP still works"
rm -f "$D/STOP"
start="$(date +%s)"
out="$("$OS" loop "$P" --every 1s --max-ticks 2 --tick-timeout 2 --agent-cmd 'sleep 30' 2>&1)"
took=$(( $(date +%s) - start ))
is "the loop finished on its own" "$([ "$took" -lt 25 ] && echo bounded || echo hung)" bounded
is "each wedged tick is recorded" "$([ "$(ev_has tick-timeout)" -ge 1 ] && echo yes)" yes
has "and the loop ran to its bound" "$out" "max-ticks reached"

sect "MAJ-2 adopt still finds a lane nobody indexed"
jq -nc '{result:{worktrees:[{id:"repo-1::/w/wt-a"},{id:"repo-1::/w/unindexed-lane"}]}}' > "$STUB_STATE/worktrees.json"
printf 'h-new\tan unindexed agent\n' > "$STUB_STATE/terminals/unindexed-lane"
idle_screen h-new
out="$("$OS" adopt "$P" --dry-run 2>&1)"
has "an unindexed worktree with a live agent is reported" "$out" unindexed-lane
has "and marked as a proposal rather than adopted silently" "$out" UNINDEXED
is "it is not written without being asked for" \
  "$(jq -r 'select(.worktree=="unindexed-lane")' "$D/lanes.jsonl" | wc -l | tr -d ' ')" 0
"$OS" adopt "$P" --include-new >/dev/null 2>&1
is "and is written when it is asked for" \
  "$(jq -r 'select(.worktree=="unindexed-lane") | .lane' "$D/lanes.jsonl" | wc -l | tr -d ' ')" 1
rm -f "$STUB_STATE/worktrees.json"
