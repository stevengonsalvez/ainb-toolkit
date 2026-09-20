#!/usr/bin/env bash
# Defects found dogfooding cut 1 against ten real lanes on three hosts, with a
# shim that passed reads through and refused every write. Sourced by run.sh.
# Uses, from run.sh: OS P D TMP STUB_STATE REPO BARE OK_SHA ok bad is has hasnt
# sect refused ev_has setcfg mkpr idle_screen label_of

sect "D1 PR counting is scoped to the programme's trunk"
# The repository this was dogfooded against had eleven open PRs on main and none
# on v2, and the tick reported eleven, so no exit condition could ever hold.
mkpr 501 main feat-ok "$OK_SHA"
mkpr 502 main feat-ok "$OK_SHA"
mkpr 503 example-trunk feat-ok "$OK_SHA"
out="$("$OS" tick "$P" 2>&1)"
has "only PRs against the trunk are counted" "$out" "open_prs=1"
"$OS" pr "$P" 501 A >/dev/null 2>&1
out="$("$OS" owed "$P" 2>&1)"
hasnt "a PR on another base is not this programme's to owe" "$out" "#501"
is "the base scoping is on every gh pr list in the scripts" \
  "$(grep -c 'gh pr list' "$PLUGIN"/scripts/*.sh | awk -F: '{s += $2} END {print s + 0}')" \
  "$(grep -c 'gh pr list .*--base' "$PLUGIN"/scripts/*.sh | awk -F: '{s += $2} END {print s + 0}')"
for n in 501 502 503; do rm -f "$STUB_STATE/prs/$n.json"; done

sect "D2 one probe terminal per host, reused, never littered"
rm -f "$STUB_STATE/created.txt"
setcfg disk_free_gb 99999999
"$OS" tick "$P" >/dev/null 2>&1
first="$(grep -c . "$STUB_STATE/created.txt" 2>/dev/null || echo 0)"
"$OS" tick "$P" >/dev/null 2>&1
"$OS" tick "$P" >/dev/null 2>&1
after="$(grep -c . "$STUB_STATE/created.txt" 2>/dev/null || echo 0)"
is "the first tick creates at most one probe per host" "$([ "$first" -le 2 ] && echo bounded || echo "$first")" bounded
is "later ticks reuse it and create nothing" "$after" "$first"
is "the probe handle is recorded so it can be found again" \
  "$(jq -r 'select(.host=="stubhost") | .probe' "$D/hosts.jsonl" | tail -1 | grep -c .)" 1
is "the reading still arrives" "$(jq -r 'select(.host=="stubhost") | .src' "$D/hosts.jsonl" | tail -1)" probe
setcfg disk_free_gb 20

sect "D3 a dry run and every read verb write nothing"
snapshot() { find "$D" -type f ! -name '*.lock' -exec sh -c 'printf "%s %s\n" "$1" "$(wc -c < "$1")"' _ {} \; | sort; }
before_dir="$(snapshot)"
: > "$STUB_STATE/calls.log"
before_ev="$(wc -l < "$D/events.jsonl" | tr -d ' ')"
"$OS" adopt "$P" --dry-run >/dev/null 2>&1
"$OS" discover >/dev/null 2>&1
"$OS" status "$P" >/dev/null 2>&1
"$OS" read "$P" A 5 >/dev/null 2>&1
"$OS" owed "$P" >/dev/null 2>&1
is "no file in the programme dir changed" "$(snapshot)" "$before_dir"
is "no event was appended" "$(wc -l < "$D/events.jsonl" | tr -d ' ')" "$before_ev"
is "no terminal was created" "$(grep -c 'terminal create' "$STUB_STATE/calls.log")" 0
is "no terminal was sent to" "$(grep -c 'terminal send' "$STUB_STATE/calls.log")" 0

sect "D4 observe mode measures without touching anything"
rm -f "$STUB_STATE/created.txt"; : > "$STUB_STATE/calls.log"
# A lane that would otherwise be restarted, and one that would be compacted.
cat >> "$D/lanes.jsonl" <<'JSON'
{"lane":"OBS-DEAD","env":"local","handle":"h-obsdead","worktree":"obswt","branch":"o1","agent":"claude","title":"OBS-DEAD","status":"working","ctx_pct":"","last_seen":""}
{"lane":"OBS-FULL","env":"local","handle":"h-obsfull","worktree":"obsfull","branch":"o2","agent":"claude","title":"OBS-FULL","status":"idle","ctx_pct":"","last_seen":""}
JSON
printf 'user@box ~/work %% \n' > "$STUB_STATE/screens/h-obsdead.txt"
printf 'work\nctx [#####] 97%%\n\xe2\x9d\xaf\n' > "$STUB_STATE/screens/h-obsfull.txt"
printf 'h-obsdead\tOBS-DEAD\n' > "$STUB_STATE/terminals/obswt"
printf 'h-obsfull\tOBS-FULL\n' > "$STUB_STATE/terminals/obsfull"
out="$("$OS" tick "$P" --observe 2>&1)"
is "observe sends nothing at all" "$(grep -c 'terminal send' "$STUB_STATE/calls.log")" 0
is "observe creates nothing" "$(grep -c 'terminal create' "$STUB_STATE/calls.log")" 0
has "it still classifies the dead lane" "$out" "OBS-DEAD"
has "and says it is only observing" "$out" "OBSERVE:"
is "the tick event records the mode" "$(jq -r 'select(.ev=="tick") | .observe' "$D/events.jsonl" | tail -1)" true
is "nothing was restarted" "$(jq -r 'select(.ev=="restart" and .lane=="OBS-DEAD")' "$D/events.jsonl" | wc -l | tr -d ' ')" 0
is "and the full lane was not compacted" \
  "$(jq -r 'select(.ev=="notified" and .lane=="OBS-FULL")' "$D/events.jsonl" | wc -l | tr -d ' ')" 0
has "it says what it would have done" "$out" "would"
# The same tick without observe does act, which is what makes the flag mean something.
"$OS" tick "$P" >/dev/null 2>&1
is "a normal tick does restart it" "$([ "$(grep -c 'terminal send' "$STUB_STATE/calls.log")" -ge 1 ] && echo acted)" acted
is "and that tick is not marked observe" "$(jq -r 'select(.ev=="tick") | .observe' "$D/events.jsonl" | tail -1)" false

sect "D4 takeover observes before it acts"
: > "$STUB_STATE/calls.log"
ORCHESTRATE_SESSION=session-one "$OS" takeover "$P" >/dev/null 2>&1
is "the tick a takeover runs sends nothing" "$(grep -c 'terminal send' "$STUB_STATE/calls.log")" 0
is "and is recorded as an observation" "$(jq -r 'select(.ev=="tick") | .observe' "$D/events.jsonl" | tail -1)" true

sect "the harness is detected, not guessed"
rm -f "$D/owner.json" "$D/.handed-over"
CLAUDECODE=1 ORCHESTRATE_SESSION=harness-flag "$OS" --harness agy tick "$P" >/dev/null 2>&1
is "an explicit harness beats detection" "$(jq -r .harness "$D/owner.json")" agy
rm -f "$D/owner.json"
( unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_COMPANION_SESSION_ID
  CLAUDECODE=1 ORCHESTRATE_SESSION=harness-probe "$OS" tick "$P" >/dev/null 2>&1 )
is "a Claude Code session is named" "$(jq -r .harness "$D/owner.json")" claude-code
rm -f "$D/owner.json"
( unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_COMPANION_SESSION_ID
  CODEX_HOME=/tmp/x ORCHESTRATE_SESSION=harness-probe2 "$OS" tick "$P" >/dev/null 2>&1 )
is "a Codex session is named" "$(jq -r .harness "$D/owner.json")" codex
rm -f "$D/owner.json"
( unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_COMPANION_SESSION_ID CODEX_HOME
  ORCHESTRATE_SESSION=harness-probe3 "$OS" tick "$P" >/dev/null 2>&1 )
is "a plain shell is named as one, not as unknown" "$(jq -r .harness "$D/owner.json")" shell
rm -f "$D/owner.json"
ORCHESTRATE_SESSION=session-one "$OS" takeover "$P" >/dev/null 2>&1

sect "the token refuses to degrade"
is "a mint with no random source refuses" \
  "$(ORCHESTRATE_NO_URANDOM=1 bash -c '. "'"$PLUGIN"'/scripts/lib.sh"; token_mint' 2>&1 | grep -c 'refus\|no random')" 1
is "a hash with no sha256 refuses" \
  "$(ORCHESTRATE_NO_SHA256=1 bash -c '. "'"$PLUGIN"'/scripts/lib.sh"; token_hash abc' 2>&1 | grep -c 'refus\|sha256')" 1
