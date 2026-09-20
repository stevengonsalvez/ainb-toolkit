#!/usr/bin/env bash
# Behavioural tests for the orchestrate plugin. Plain bash, no framework.
# Nothing here touches a real Orca host, a real repository or GitHub: the stubs
# in ./stubs are first on PATH and every file lives in a temp ORCHESTRATE_HOME.
#
#   tests/run.sh            run everything, then re-run once under zsh
#   ORCH_TEST_ZSH=1 run.sh  the inner run, no zsh recursion
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "$HERE")"
OS="$PLUGIN/scripts/orchestrate.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "no [$3] in: $(printf '%s' "$2" | head -3 | tr '\n' ' ')"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "unwanted [$3]"; else ok "$1"; fi; }
sect() { printf '\n== %s\n' "$1"; }

# --------------------------------------------------------------- environment

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export ORCHESTRATE_HOME="$TMP/home"
export STUB_STATE="$TMP/stub"
export PATH="$HERE/stubs:$PATH"
export SEND_SETTLE_S=0 RESUME_SETTLE_S=0
export ORCHESTRATE_HARNESS=test
export ORCHESTRATE_SESSION=session-one
mkdir -p "$STUB_STATE/screens" "$STUB_STATE/terminals" "$STUB_STATE/prs" "$STUB_STATE/noecho"

P=prog
D="$ORCHESTRATE_HOME/$P"
ev_has() { grep -c "\"ev\":\"$1\"" "$D/events.jsonl" 2>/dev/null | tr -d ' '; }
refused() { grep -c "\"what\":\"$1\"" "$D/events.jsonl" 2>/dev/null | tr -d ' '; }
# Ownership is a token; owner.json holds only its hash and a label derived from
# it, so a test names the expected owner by hashing the token it used.
label_of() { printf 'orch-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-12)"; }
# Set a key whether it sits on its own line or inside an inline map.
setcfg() {
  local k="$1" v="$2"
  sed -i.bak -E "s#^([ ]*)$k:[^{].*#\1$k: $v#; s#([{,] ?)$k: [^,}]*#\1$k: $v#" "$D/programme.yaml"
  rm -f "$D/programme.yaml.bak"
}

idle_screen()  { printf 'some work happened\n>\n❯\n' > "$STUB_STATE/screens/$1.txt"; }
shell_screen() { printf 'build finished\nuser@box ~/work %% \n' > "$STUB_STATE/screens/$1.txt"; }

sect "init"
out="$("$OS" init "$P" --trunk example-trunk --never-merge-into main,master 2>&1)"
is "init does not claim ownership, it points at takeover" \
  "$([ -f "$D/owner.json" ] && echo claimed || echo unclaimed)" unclaimed
has "and says so" "$out" "takeover"
is "init creates the programme dir" "$([ -f "$D/programme.yaml" ] && echo yes)" yes
has "init copies agents.yaml" "$(ls "$D")" agents.yaml
is "init writes the trunk" "$(grep -c '^trunk: example-trunk' "$D/programme.yaml")" 1
"$OS" takeover "$P" >/dev/null 2>&1
is "takeover claims it with the exported token" \
  "$(jq -r .session "$D/owner.json")" "$(label_of session-one)"

sect "tiny yaml parser"
# shellcheck source=../scripts/lib.sh
. "$PLUGIN/scripts/lib.sh"
prog_open "$P"
is "flat scalar"        "$(cfg trunk)" example-trunk
is "inline list"        "$(cfg never_merge_into)" "main master"
is "inline map value"   "$(cfg loop.every)" 20m
is "nested inline map"  "$(cfg placement.floors.disk_free_gb)" 20
is "quoted value keeps its colons" "$(cfg review.nudge.stale_pr)" "PR #{pr} has had no review for {age}. Run {how} and post the verdict."
is "trailing comment stripped" "$(cfg autonomy)" ask
is "default when absent" "$(cfg nope fallback)" fallback
is "agent profile"      "$(agent_cfg claude resume)" "claude --continue"
is "agent kind ignores the model suffix" "$(agent_cfg "claude opus" resume)" "claude --continue"
is "unknown kind falls back to default" "$(agent_cfg martian compact)" /compact

sect "exit expression"
is "true when the counters hold"  "$(exit_eval 'open_prs == 0 && owed == 0' 0 0 1 1)" true
is "false when they do not"       "$(exit_eval 'open_prs == 0' 2 0 1 1)" false
is "scope_done reads the file"    "$(exit_eval 'scope_done' 0 0 0 0)" false
touch "$D/SCOPE_DONE"
is "scope_done true once present" "$(exit_eval 'scope_done' 0 0 0 0)" true
rm -f "$D/SCOPE_DONE"
is "an unknown token is undecidable, never true" "$(exit_eval 'rm -rf /' 0 0 0 0)" undecidable

sect "lanes, owed audit and the send path"
cat > "$D/lanes.jsonl" <<'JSON'
{"lane":"A","env":"local","handle":"h-a","worktree":"wt-a","branch":"feat-ok","agent":"claude opus","goal":"","exclusive":[],"status":"working","ctx_pct":"","last_seen":""}
{"lane":"B","env":"local","handle":"h-b","worktree":"wt-b","branch":"","agent":"claude opus","goal":"","exclusive":[],"status":"working","ctx_pct":"","last_seen":""}
{"lane":"C","env":"stubhost","handle":"h-stale","worktree":"wt-c","branch":"","agent":"claude opus","goal":"","exclusive":[],"status":"working","ctx_pct":"","last_seen":""}
JSON
idle_screen h-a
shell_screen h-b
idle_screen h-fresh
printf 'h-fresh\n' > "$STUB_STATE/terminals/wt-c"
printf 'h-b\n' > "$STUB_STATE/terminals/wt-b"
jq -nc '{number:100,state:"MERGED",baseRefName:"example-trunk",headRefName:"feat-ok",headRefOid:"deadbeef"}' > "$STUB_STATE/prs/100.json"

"$OS" pr "$P" 100 A >/dev/null
out="$("$OS" owed "$P" 2>&1)"
has "owed finds a merged PR whose lane was never told" "$out" "OWED: lane A was never told #100 is MERGED"
has "owed counts it" "$out" "1 owed"

out="$("$OS" send "$P" A 100 "Orchestrator notice: #100 is merged, nothing awaits a verdict" 2>&1)"
has "send confirms delivery on the screen" "$out" "delivered -> A"
out="$("$OS" owed "$P" 2>&1)"
has "owed clears after a delivered send" "$out" "0 owed"

sect "dead-shell guard"
out="$("$OS" send "$P" B - "this text must never be typed into a shell" 2>&1)"
has "a shell prompt is refused, not typed into" "$out" "dead-shell -> B"
hasnt "the message never reaches the shell" "$(cat "$STUB_STATE/sent/h-b.txt" 2>/dev/null)" "this text must never be typed"
has "the resume command is what gets typed" "$(cat "$STUB_STATE/sent/h-b.txt" 2>/dev/null)" "claude --continue"
is "both attempts are recorded" "$(grep -c '"result":"dead-shell"' "$D/events.jsonl")" 2

sect "stale handle re-resolved"
out="$("$OS" tick "$P" 2>&1)"
is "the row is rewritten with the live handle" "$(jq -r 'select(.lane=="C") | .handle' "$D/lanes.jsonl")" h-fresh
is "the re-resolve is an event" "$(grep -c '"action":"rehandle"' "$D/events.jsonl")" 1
has "the tick says it rehandled" "$out" rehandled
is "a tick event is appended" "$([ "$(ev_has tick)" -ge 1 ] && echo yes)" yes

sect "watchdog"
jq -nc --arg t "$(date -u -d '-2 hours' +%FT%TZ 2>/dev/null || date -u -v-2H +%FT%TZ)" \
  '{t:$t,ev:"tick",n:1,lanes:{working:1,idle:0,asking:0,done:0,dead:0},open_prs:0,owed:0,gap_s:0}' >> "$D/events.jsonl"
out="$("$OS" tick "$P" 2>&1)"
has "a gap past twice the cadence is reported first" "$out" WATCHDOG

sect "host disk floor"
setcfg disk_free_gb 99999999
out="$("$OS" tick "$P" 2>&1)"
has "a host under the floor is reported" "$out" "DISK: local"
has "the remote rung answers through an Orca probe" "$out" "DISK: stubhost"
hasnt "nothing is ever deleted under a lane" "$out" deleted
setcfg disk_free_gb 20
is "hosts.jsonl records which rung answered" "$(jq -r 'select(.host=="stubhost") | .src' "$D/hosts.jsonl" | tail -1)" probe

sect "owner lock, takeover and handover"
ORCHESTRATE_SESSION=session-one "$OS" takeover "$P" >/dev/null 2>&1
is "the first session owns it" "$(jq -r .session "$D/owner.json")" "$(label_of session-one)"
is "the token itself is never written down" "$(grep -cF -- session-one "$D/owner.json")" 0
out="$(ORCHESTRATE_SESSION=session-two "$OS" tick "$P" 2>&1)"; rc=$?
is "a second orchestrator is refused" "$rc" 3
has "the refusal says who holds it" "$out" "REFUSED owner-held"
is "the refusal is an event" "$(refused owner-held)" 1

jq --arg t "$(date -u -d '-3 hours' +%FT%TZ 2>/dev/null || date -u -v-3H +%FT%TZ)" '.last_tick = $t' "$D/owner.json" > "$D/owner.tmp" && mv "$D/owner.tmp" "$D/owner.json"
ORCHESTRATE_SESSION=session-two "$OS" takeover "$P" >/dev/null 2>&1
is "takeover succeeds once the lock is stale" "$(jq -r .session "$D/owner.json")" "$(label_of session-two)"
is "the takeover is recorded" "$(ev_has takeover)" 1
is "it names the outgoing session" "$(jq -r 'select(.ev=="takeover") | .outgoing' "$D/events.jsonl" | tail -1)" "$(label_of session-one)"

out="$(ORCHESTRATE_SESSION=session-two "$OS" handover "$P" "credits low" 2>&1)"
is "handover writes the brief" "$([ -f "$D/HANDOVER.md" ] && echo yes)" yes
has "the brief is generated from the index" "$(cat "$D/HANDOVER.md")" "| A | local | wt-a |"
has "the brief names the resume command" "$(cat "$D/HANDOVER.md")" "orchestrate:takeover prog"
has "the brief carries a next action" "$(cat "$D/HANDOVER.md")" "## Next action"
is "handover releases the lock" "$([ -f "$D/owner.json" ] && echo held || echo released)" released
is "handover is recorded with its reason" "$(jq -r 'select(.ev=="handover") | .reason' "$D/events.jsonl" | tail -1)" "credits low"

sect "scrubber"
mkdir -p "$D/reviews"
setcfg deny '"bannedvendor"'
{ printf 'Read /home/someone/dev/proj/src/app.ts and\n'
  printf '/tmp/agent-1000/abc/scratchpad/notes.md before merging.\n'; } > "$D/reviews/1-code.md"
out="$("$OS" scrub "$P" "$D/reviews/1-code.md" 2>&1)"
has "a clean report passes" "$out" "1-code-clean.md"
# shellcheck disable=SC2088  # a literal expectation, not a path to expand
has "host paths are stripped to a tilde" "$(cat "$D/reviews/1-code-clean.md")" "~/dev/proj/src/app.ts"
hasnt "scratch paths are stripped entirely" "$(cat "$D/reviews/1-code-clean.md")" "/tmp/agent-1000"
printf 'reviewed by bannedvendor\n' > "$D/reviews/2-code.md"
out="$("$OS" scrub "$P" "$D/reviews/2-code.md" 2>&1)"; rc=$?
is "a report naming a vendor is refused" "$rc" 3
is "the refusal is an event" "$(refused scrub-vendor)" 1
printf 'a line with an em dash %b here\n' '\0342\0200\0224' > "$D/reviews/3-code.md"
out="$("$OS" scrub "$P" "$D/reviews/3-code.md" 2>&1)"; rc=$?
is "U+2014 is refused" "$rc" 3
is "that refusal is an event too" "$(refused scrub-emdash)" 1

sect "merge gate"
# Handover spent the token a moment ago, so picking the programme back up is a
# takeover, which is recorded, not a tick silently re-claiming it.
"$OS" takeover "$P" >/dev/null 2>&1
REPO="$TMP/repo"; BARE="$TMP/origin.git"
git init -q --bare "$BARE"
git init -q "$REPO" && git -C "$REPO" remote add origin "$BARE"
git -C "$REPO" config user.email dev@example.invalid && git -C "$REPO" config user.name "Test Dev"
git -C "$REPO" config commit.gpgsign false
printf 'base\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt && git -C "$REPO" commit -qm "chore: base"
git -C "$REPO" branch -M example-trunk && git -C "$REPO" push -q origin example-trunk
git -C "$REPO" checkout -qb feat-ok
printf 'clean change\n' >> "$REPO/file.txt"
git -C "$REPO" commit -qam "feat: a clean change" && git -C "$REPO" push -q origin feat-ok
git -C "$REPO" checkout -q example-trunk && git -C "$REPO" checkout -qb feat-attr
printf 'other\n' > "$REPO/other.txt"
git -C "$REPO" add other.txt
git -C "$REPO" commit -qm "$(printf 'feat: a change\n\nCo-authored-by: Someone <s@example.invalid>\n')"
git -C "$REPO" push -q origin feat-attr
git -C "$REPO" checkout -q example-trunk
OK_SHA="$(git -C "$REPO" rev-parse feat-ok)"
# shellcheck disable=SC2034  # read by hardening.sh, which run.sh sources below
ATTR_SHA="$(git -C "$REPO" rev-parse feat-attr)"
# shellcheck disable=SC2034  # read by hardening.sh

TRUNK_SHA="$(git -C "$REPO" rev-parse example-trunk)"
sed -i.bak "s#^repo:.*#repo: $REPO#" "$D/programme.yaml" && rm -f "$D/programme.yaml.bak"
mkdir -p "$STUB_STATE/checks"
printf '[{"name":"build","bucket":"pass"}]\n' > "$STUB_STATE/checks/default.json"

# The gate fetches refs/pull/<n>/head, which is what binds its evidence to the
# commit the PR actually proposes rather than to a branch name.
mkpr() {
  jq -nc --arg b "$2" --arg h "$3" --arg s "$4" --arg n "$1" \
    '{number:($n|tonumber), state:"OPEN", isDraft:false, isCrossRepository:false,
      baseRefName:$b, headRefName:$h, headRefOid:$s}' > "$STUB_STATE/prs/$1.json"
  git -C "$BARE" update-ref "refs/pull/$1/head" "$4" 2>/dev/null
}
mkpr 201 example-trunk feat-ok "$OK_SHA"
mkpr 202 main feat-ok "$OK_SHA"
mkpr 203 some-release-branch feat-ok "$OK_SHA"

"$OS" merge "$P" 201 "$OK_SHA" >/dev/null 2>&1; is "an unsigned commit is refused" "$?" 3
is "the unsigned refusal is an event" "$(refused merge-unsigned)" 1
setcfg required false

"$OS" merge "$P" 202 "$OK_SHA" >/dev/null 2>&1; is "a never_merge_into base is refused" "$?" 3
is "that refusal is an event" "$(refused merge-never-base)" 1
"$OS" merge "$P" 203 "$OK_SHA" >/dev/null 2>&1; is "a base that is not the trunk is refused" "$?" 3
is "that refusal is an event" "$(refused merge-wrong-base)" 1
is "nothing was merged while refusing" "$([ -f "$STUB_STATE/merged.txt" ] && echo merged || echo none)" none

out="$("$OS" merge "$P" 201 "$OK_SHA" 2>&1)"; is "autonomy ask stops short of merging" "$?" 4
has "it says so plainly" "$out" "ASK: #201"

sect "post goes through the scrubber"
printf 'verdict: MERGE. See /home/someone/dev/proj/src/app.ts\n' > "$D/reviews/201-code.md"
"$OS" post "$P" 201 "$D/reviews/201-code.md" >/dev/null 2>&1
hasnt "the posted body carries no host path" "$(cat "$STUB_STATE/posted/201.md")" /home/someone
printf 'verdict: bannedvendor said so\n' > "$D/reviews/202-code.md"
"$OS" post "$P" 202 "$D/reviews/202-code.md" >/dev/null 2>&1; is "a dirty report is not posted" "$?" 3
is "nothing was posted for it" "$([ -f "$STUB_STATE/posted/202.md" ] && echo posted || echo none)" none

sect "retire is guarded"
"$OS" mark "$P" A working >/dev/null
"$OS" retire "$P" A >/dev/null 2>&1; is "a lane that is still working is not retired" "$?" 3
is "that refusal is an event" "$(refused retire-busy)" 1
"$OS" mark "$P" A idle >/dev/null
mkpr 206 example-trunk feat-ok "$OK_SHA"
"$OS" retire "$P" A >/dev/null 2>&1; is "a lane with an open PR is not retired" "$?" 3
is "that refusal is an event" "$(refused retire-unmerged)" 1
is "the worktree still exists" "$([ -f "$STUB_STATE/removed.txt" ] && echo gone || echo kept)" kept

sect "loop driver"
touch "$D/STOP"
out="$("$OS" loop "$P" --every 1s --max-ticks 3 2>&1)"
has "a STOP already present refuses to arm" "$out" "refusing to arm"
is "no loop was started" "$(ev_has loop)" 0
rm -f "$D/STOP"
out="$("$OS" loop "$P" --every 1s --max-ticks 5 --agent-cmd "touch $D/STOP" 2>&1)"
has "a STOP written mid-run ends the loop" "$out" "STOP file present, loop ends"
is "the stop is recorded with its reason" "$(jq -r 'select(.ev=="loop" and .action=="stop") | .reason' "$D/events.jsonl" | tail -1)" stop-file
rm -f "$D/STOP"
out="$("$OS" loop "$P" --every 1s --max-ticks 1 2>&1)"
has "max-ticks bounds the loop" "$out" "max-ticks reached"

# shellcheck source=./hardening.sh
. "$HERE/hardening.sh"
# shellcheck source=./review.sh
. "$HERE/review.sh"
# shellcheck source=./followups.sh
. "$HERE/followups.sh"

sect "hard refusals have no code path at all"
src="$(cat "$PLUGIN"/scripts/*.sh)"
hasnt "no force-push"        "$src" "--force"
hasnt "no force-with-lease"  "$src" force-with-lease
hasnt "no tmux kill-server"  "$src" kill-server
hasnt "no pkill"             "$src" pkill
hasnt "no killall"           "$src" killall
code="$(grep -hvE '^[[:space:]]*#' "$PLUGIN"/scripts/*.sh)"
is "no ssh transport anywhere" "$(printf '%s\n' "$code" | grep -cE '(^|[^a-z-])ssh ')" 0
is "no --no-gpg-sign"        "$(grep -c -- '--no-gpg-sign' "$PLUGIN"/scripts/*.sh | awk -F: '{s += $2} END {print s + 0}')" 0

sect "scripts are bash-clean"
for f in "$PLUGIN"/scripts/*.sh "$HERE"/run.sh "$HERE"/stubs/*; do
  bash -n "$f" 2>/dev/null && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$PLUGIN"/scripts/*.sh >/dev/null 2>&1 && ok "shellcheck scripts" || bad "shellcheck scripts"
fi

# Honest scope: every script here carries a bash shebang and is executed by
# bash, so re-running this file from zsh would prove nothing about parsing. The
# real hazard is a zsh CALLER, whose arguments do not word split the way a bash
# caller's do, handing values to the entry script.
if command -v zsh >/dev/null 2>&1; then
  printf '\n== a zsh caller hands arguments over intact\n'
  idle_screen h-zsh
  printf 'h-zsh\tZSH\n' > "$STUB_STATE/terminals/zshwt"
  cat >> "$D/lanes.jsonl" <<'JSON'
{"lane":"ZSH","env":"local","handle":"h-zsh","worktree":"zshwt","branch":"z","agent":"claude","title":"ZSH","status":"working","ctx_pct":"","last_seen":""}
JSON
  zsh -f -c '
    msg="two  spaces, a glob * and a \$dollar"
    "$1" send "$2" ZSH - "$msg" >/dev/null 2>&1
  ' zsh "$OS" "$P"
  has "a value with spaces, a glob and a dollar arrives byte for byte" \
    "$(cat "$STUB_STATE/sent/h-zsh.txt" 2>/dev/null)" 'two  spaces, a glob * and a $dollar'
  is "it arrives as exactly one line" "$(wc -l < "$STUB_STATE/sent/h-zsh.txt" | tr -d ' ')" 1
  zsh -f -c '
    "$1" read "$2" ZSH 3 >/dev/null 2>&1
  ' zsh "$OS" "$P"
  is "a read from a zsh caller does not error" "$?" 0
fi

if [ -n "${ORCH_TEST_MUTANTS:-}" ]; then
  printf '\n== mutation check\n'
  if "$HERE/mutants.sh" >"$TMP/mut.log" 2>&1; then
    while read -r line; do ok "$line"; done < <(grep '^killed ' "$TMP/mut.log")
  else
    bad "mutation check"; tail -20 "$TMP/mut.log"
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
