#!/usr/bin/env bash
# Verification follow-ups, sourced by run.sh. Every block was red before the fix
# it guards. Uses, from run.sh: OS P D TMP STUB_STATE REPO BARE OK_SHA ok bad is
# has hasnt sect refused ev_has setcfg mkpr idle_screen

sect "NEW-1 ownership is a token the orchestrator holds, not a file it can read"
P3=prog3; D3="$ORCHESTRATE_HOME/$P3"
env -u ORCHESTRATE_SESSION "$OS" init "$P3" --trunk example-trunk --repo "$REPO" >/dev/null 2>&1
claim="$(env -u ORCHESTRATE_SESSION "$OS" takeover "$P3" 2>&1)"
TOK="$(printf '%s\n' "$claim" | sed -n 's/^export ORCHESTRATE_SESSION=//p' | tr -d '"' | head -1)"
is "takeover mints a token and prints it once" "$([ "${#TOK}" -ge 16 ] && echo minted)" minted
has "and prints the export line to use it" "$claim" "export ORCHESTRATE_SESSION="
is "owner.json holds a hash, never the token" \
  "$(grep -cF -- "$TOK" "$D3/owner.json" 2>/dev/null)" 0
is "no session file is left for another process to read" \
  "$([ -f "$D3/.session" ] && echo readable || echo none)" none

cat >> "$D3/lanes.jsonl" <<'JSON'
{"lane":"T1","env":"local","handle":"h-tok","worktree":"tokwt","branch":"t1","agent":"claude","title":"T1","status":"working","ctx_pct":"","last_seen":""}
JSON
idle_screen h-tok
printf 'h-tok\tT1\n' > "$STUB_STATE/terminals/tokwt"

env -u ORCHESTRATE_SESSION "$OS" send "$P3" T1 - "a message from a process with no token" >/dev/null 2>&1
is "a process without the token cannot send" "$?" 3
is "that refusal is an event" "$([ "$(grep -c '"what":"owner-no-token"' "$D3/events.jsonl")" -ge 1 ] && echo yes)" yes
hasnt "and nothing was typed" "$(cat "$STUB_STATE/sent/h-tok.txt" 2>/dev/null)" "a message from a process with no token"
env -u ORCHESTRATE_SESSION "$OS" merge "$P3" 201 "$OK_SHA" >/dev/null 2>&1
is "nor merge" "$?" 3
env -u ORCHESTRATE_SESSION "$OS" retire "$P3" T1 >/dev/null 2>&1
is "nor retire" "$?" 3
env -u ORCHESTRATE_SESSION "$OS" tick "$P3" >/dev/null 2>&1
is "nor tick" "$?" 3
ORCHESTRATE_SESSION=some-other-token "$OS" tick "$P3" >/dev/null 2>&1
is "a wrong token is refused too" "$?" 3

ORCHESTRATE_SESSION="$TOK" "$OS" tick "$P3" >/dev/null 2>&1
is "the holder works across separate invocations" "$?" 0
ORCHESTRATE_SESSION="$TOK" "$OS" send "$P3" T1 - "a message from the token holder" >/dev/null 2>&1
is "and can send" "$?" 0
"$OS" --session "$TOK" tick "$P3" >/dev/null 2>&1
is "the flag works as well as the variable" "$?" 0

ORCHESTRATE_SESSION="$TOK" "$OS" handover "$P3" "round done" >/dev/null 2>&1
ORCHESTRATE_SESSION="$TOK" "$OS" tick "$P3" >/dev/null 2>&1
is "handover invalidates the token" "$?" 3
is "the refusal says the programme is unclaimed" \
  "$([ "$(grep -c '"what":"owner-unclaimed"' "$D3/events.jsonl")" -ge 1 ] && echo yes)" yes

sect "NEW-2 an unrecognised PR state is undecidable, never 'not owed'"
"$OS" pr "$P" 401 A >/dev/null 2>&1
for state in null UNKNOWN_FUTURE_STATE '   '; do
  printf '%s' "$state" > "$STUB_STATE/state-override"
  out="$("$OS" owed "$P" 2>&1)"
  has "state [$state] is owed-unknown" "$out" "owed-unknown"
  out="$("$OS" tick "$P" 2>&1)"
  rc=$?
  has "and the tick will not call it finished [$state]" "$out" "exit=undecidable"
  is "and does not signal the exit condition [$state]" "$rc" 0
done
rm -f "$STUB_STATE/state-override"
printf 'OPEN' > "$STUB_STATE/state-override"
out="$("$OS" owed "$P" 2>&1)"
hasnt "a genuinely open PR is not owed a notice" "$out" "owed-unknown"
rm -f "$STUB_STATE/state-override"

sect "NEW-3 an unread counter is recorded as unread"
export STUB_GH_FAIL=1
"$OS" tick "$P" >/dev/null 2>&1
is "the tick event records null, not zero" \
  "$(jq -r 'select(.ev=="tick") | .open_prs' "$D/events.jsonl" | tail -1)" null
unset STUB_GH_FAIL

sect "NEW-5 an unresolvable repository is said out loud"
cp "$D/programme.yaml" "$TMP/cfg3.bak"
sed -i.bak "s#^repo:.*#repo: $TMP/no-origin#" "$D/programme.yaml" && rm -f "$D/programme.yaml.bak"
sed -i.bak 's#^gh_repo:.*#gh_repo: ""#' "$D/programme.yaml" && rm -f "$D/programme.yaml.bak"
rm -rf "$TMP/no-origin"; git init -q "$TMP/no-origin"
out="$("$OS" tick "$P" 2>&1)"
has "the tick says the repository could not be resolved" "$out" "GH_REPO"
is "and records it" "$([ "$(grep -c 'gh_repo unresolved' "$D/events.jsonl")" -ge 1 ] && echo yes)" yes
cp "$TMP/cfg3.bak" "$D/programme.yaml"

sect "M3 the scrubber covers the last two shapes"
printf 'reachable at box-one.tailnet-example.ts.net today\n' > "$D/reviews/ts.md"
"$OS" scrub "$P" "$D/reviews/ts.md" >/dev/null 2>&1
is "a tailnet hostname is refused" "$?" 3
printf 'set api_key=abcd1234efgh5678 in the env\n' > "$D/reviews/key.md"
"$OS" scrub "$P" "$D/reviews/key.md" >/dev/null 2>&1
is "a generic credential assignment is refused" "$?" 3
printf 'the build is green and the frames match\n' > "$D/reviews/fine.md"
"$OS" scrub "$P" "$D/reviews/fine.md" >/dev/null 2>&1
is "an ordinary report still passes" "$?" 0

sect "NEW-4 discovery does not stop at the first indexed lane in a worktree"
jq -nc '{result:{worktrees:[{id:"repo-1::/w/wt-a"}]}}' > "$STUB_STATE/worktrees.json"
printf 'h-a\tA\nh-second\ta second agent here\n' > "$STUB_STATE/terminals/wt-a"
idle_screen h-second
out="$("$OS" adopt "$P" --dry-run 2>&1)"
has "a second terminal in an indexed worktree is reported" "$out" "a second agent here"
is "and the indexed lane is still reported once" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "A"' | wc -l | tr -d ' ')" 1
rm -f "$STUB_STATE/worktrees.json"
printf 'h-a\tA\n' > "$STUB_STATE/terminals/wt-a"

sect "the surviving mutant: STOP is read during the wait, not only between ticks"
rm -f "$D/STOP"
( sleep 2; touch "$D/STOP" ) &
stopper=$!
start="$(date +%s)"
"$OS" loop "$P" --every 30s --max-ticks 5 >/dev/null 2>&1
took=$(( $(date +%s) - start ))
wait "$stopper" 2>/dev/null
is "a STOP arriving mid-gap ends the loop without waiting out the cadence" \
  "$([ "$took" -lt 12 ] && echo prompt || echo "waited ${took}s")" prompt
is "and the stop is recorded" \
  "$(jq -r 'select(.ev=="loop" and .action=="stop") | .reason' "$D/events.jsonl" | tail -1)" stop-file
rm -f "$D/STOP"
