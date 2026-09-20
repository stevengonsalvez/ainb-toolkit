#!/usr/bin/env bash
# Security hardening assertions, sourced by run.sh after the base suite has
# built its fixtures. Every block here was red before the fix it guards.
#
# Uses, from run.sh: OS P D TMP STUB_STATE REPO BARE ok bad is has hasnt sect
# ev_has refused setcfg mkpr idle_screen

sect "H4 ownership is required, not optional"
base_unclaimed="$(refused owner-unclaimed)"
rm -f "$D/owner.json"
out="$("$OS" send "$P" A - "nobody owns this programme" 2>&1)"; rc=$?
is "an unowned programme refuses a send" "$rc" 3
has "the refusal names the claim command" "$out" "orchestrate.sh takeover"
is "the refusal is an event" "$(( $(refused owner-unclaimed) - base_unclaimed ))" 1
hasnt "nothing was typed" "$(cat "$STUB_STATE/sent/h-a.txt" 2>/dev/null)" "nobody owns this programme"
"$OS" merge "$P" 201 "$OK_SHA" >/dev/null 2>&1; is "an unowned programme refuses a merge" "$?" 3
"$OS" retire "$P" A >/dev/null 2>&1; is "an unowned programme refuses a retire" "$?" 3
"$OS" tick "$P" >/dev/null 2>&1
is "a tick claims the lock rather than proceeding without one" "$(jq -r .session "$D/owner.json" 2>/dev/null)" session-one
# shellcheck source=../scripts/lib.sh
. "$PLUGIN/scripts/lib.sh"; prog_open "$P"
ORCHESTRATE_SESSION=someone-else owner_claim_new >/dev/null 2>&1
is "a claim on a held lock loses atomically" "$(jq -r .session "$D/owner.json")" session-one

sect "H3 a message is one sanitised line or it is refused"
before="$(wc -c < "$STUB_STATE/sent/h-a.txt" 2>/dev/null || echo 0)"
out="$("$OS" send "$P" A - "$(printf 'line one\nline two')" 2>&1)"; rc=$?
is "a newline is refused" "$rc" 3
is "the refusal is an event" "$(refused send-multiline)" 1
out="$("$OS" send "$P" A - "$(printf 'carriage\rreturn')" 2>&1)"
is "a carriage return is refused" "$?" 3
out="$("$OS" send "$P" A - "-rf looks like a flag" 2>&1)"
is "a leading dash is refused" "$?" 3
is "that refusal is an event" "$(refused send-leading-dash)" 1
is "none of the three reached the transport" "$(wc -c < "$STUB_STATE/sent/h-a.txt" 2>/dev/null || echo 0)" "$before"
out="$("$OS" send "$P" A - "$(printf 'clean \033[31mtext\033[0m here')" 2>&1)"
is "an escape sequence is stripped, not refused" "$?" 0
hasnt "no ESC reaches the transport" "$(cat "$STUB_STATE/sent/h-a.txt")" "$(printf '\033')"
has "the readable part survives" "$(cat "$STUB_STATE/sent/h-a.txt")" "clean text here"
long="$(head -c 4000 < /dev/zero | tr '\0' 'x')"
"$OS" send "$P" A - "$long" >/dev/null 2>&1
is "an overlong message is capped" "$(awk 'END {print (length($0) <= 2000) ? "capped" : "uncapped"}' "$STUB_STATE/sent/h-a.txt")" capped
is "the event records the sanitised text, not the raw text" \
  "$(jq -r 'select(.ev=="notified" and .msg != null) | .msg' "$D/events.jsonl" | grep -c "$(printf '\033')")" 0

sect "M7 only a good signature counts, and the signer is checked"
is "G with no configured key is accepted"     "$(sig_row_ok G ABCDEF1234567890 ''; echo $?)" 0
is "U is refused, unknown validity is not trust" "$(sig_row_ok U ABCDEF1234567890 ''; echo $?)" 1
is "N is refused"                             "$(sig_row_ok N '' ''; echo $?)" 1
is "E is refused"                             "$(sig_row_ok E '' ''; echo $?)" 1
is "B is refused"                             "$(sig_row_ok B '' ''; echo $?)" 1
is "a matching signer is accepted"            "$(sig_row_ok G ABCDEF1234567890 4567890; echo $?)" 0
is "a different signer is refused"            "$(sig_row_ok G ABCDEF1234567890 DEADBEEF; echo $?)" 1
is "a placeholder key is treated as unset"    "$(sig_row_ok G ABCDEF1234567890 '<your-signing-key-id>'; echo $?)" 0

sect "H1 the gate inspects the PR head commit, never a branch name"
setcfg required false
git -C "$BARE" update-ref "refs/pull/204/head" "$ATTR_SHA"
mkpr 204 example-trunk feat-ok "$ATTR_SHA"
"$OS" merge "$P" 204 "$ATTR_SHA" >/dev/null 2>&1
is "a clean branch name does not clear a dirty head" "$?" 3
is "the attribution refusal names the head" "$(refused merge-attributed)" 1
is "nothing was merged" "$(grep -c '^204$' "$STUB_STATE/merged.txt" 2>/dev/null || echo 0)" 0

git -C "$BARE" update-ref "refs/pull/207/head" "$TRUNK_SHA"
mkpr 207 example-trunk feat-ok "$TRUNK_SHA"
"$OS" merge "$P" 207 "$TRUNK_SHA" >/dev/null 2>&1
is "an empty commit range is refused, not vacuously passed" "$?" 3
is "that refusal is an event" "$(refused merge-empty-range)" 1

mkpr 208 example-trunk feat-ok "$OK_SHA"
git -C "$BARE" update-ref -d "refs/pull/208/head" 2>/dev/null
"$OS" merge "$P" 208 "$OK_SHA" >/dev/null 2>&1
is "a head ref that cannot be fetched is refused" "$?" 3
is "that refusal is an event" "$(refused merge-no-head-ref)" 1

git -C "$BARE" update-ref "refs/pull/206/head" "$OK_SHA"
jq -nc --arg s "$OK_SHA" '{number:206,state:"OPEN",isDraft:false,isCrossRepository:true,
  baseRefName:"example-trunk",headRefName:"feat-ok",headRefOid:$s}' > "$STUB_STATE/prs/206.json"
"$OS" merge "$P" 206 "$OK_SHA" >/dev/null 2>&1
is "a fork head is refused by default" "$?" 3
is "that refusal is an event" "$(refused merge-fork)" 1

sect "H2 the reviewed sha is required, exact, and carried into the merge"
git -C "$BARE" update-ref "refs/pull/201/head" "$OK_SHA"
mkpr 201 example-trunk feat-ok "$OK_SHA"
"$OS" merge "$P" 201 >/dev/null 2>&1
is "a merge with no reviewed sha is refused" "$?" 3
is "that refusal is an event" "$(refused merge-sha-required)" 1
"$OS" merge "$P" 201 "${OK_SHA:0:2}" >/dev/null 2>&1
is "a sha prefix is refused" "$?" 3
is "that refusal is an event" "$(refused merge-sha-format)" 1
"$OS" merge "$P" 201 "$(printf '%040d' 0)" >/dev/null 2>&1
is "a full sha that is not the head is refused" "$?" 3
is "that refusal is an event" "$(refused merge-sha-mismatch)" 1

sect "H2 a head that moves between the gate and the merge is refused"
setcfg autonomy merge_on_verdict
git -C "$BARE" update-ref "refs/pull/211/head" "$OK_SHA"
mkpr 211 example-trunk feat-ok "$OK_SHA"
touch "$STUB_STATE/prs/211.move"
"$OS" merge "$P" 211 "$OK_SHA" >/dev/null 2>&1
is "a push during the gate is caught by the re-read" "$?" 3
is "that refusal is an event" "$(refused merge-moved)" 1
is "and nothing was merged" "$(grep -c '^211$' "$STUB_STATE/merged.txt" 2>/dev/null || echo 0)" 0
setcfg autonomy ask

sect "M4 a draft is not silently made ready"
git -C "$BARE" update-ref "refs/pull/205/head" "$OK_SHA"
jq -nc --arg s "$OK_SHA" '{number:205,state:"OPEN",isDraft:true,isCrossRepository:false,
  baseRefName:"example-trunk",headRefName:"feat-ok",headRefOid:$s}' > "$STUB_STATE/prs/205.json"
"$OS" merge "$P" 205 "$OK_SHA" >/dev/null 2>&1
is "a draft PR is refused" "$?" 3
is "that refusal is an event" "$(refused merge-draft)" 1
is "the gate never flips a draft to ready" "$([ -f "$STUB_STATE/readied.txt" ] && echo flipped || echo untouched)" untouched
is "no gh pr ready call anywhere in the scripts" "$(grep -c 'pr ready' "$PLUGIN"/scripts/*.sh | awk -F: '{s += $2} END {print s + 0}')" 0

sect "L3 a PR number is validated before it reaches gh"
"$OS" merge "$P" --flag "$OK_SHA" >/dev/null 2>&1
is "a PR number that is not digits is refused" "$?" 3
is "that refusal is an event" "$(refused merge-pr-format)" 1

sect "ci mode is gated in code, not in prose"
setcfg ci gate
printf '[{"name":"build","bucket":"fail"}]\n' > "$STUB_STATE/checks/201.json"
"$OS" merge "$P" 201 "$OK_SHA" >/dev/null 2>&1
is "a failing check refuses the merge when ci gates" "$?" 3
is "that refusal is an event" "$(refused merge-ci)" 1
printf '[{"name":"build","bucket":"pending"}]\n' > "$STUB_STATE/checks/201.json"
"$OS" merge "$P" 201 "$OK_SHA" >/dev/null 2>&1
is "a pending check refuses the merge when ci gates" "$?" 3
printf '[{"name":"build","bucket":"pass"}]\n' > "$STUB_STATE/checks/201.json"
setcfg ci ignore

sect "the merge that should pass, still passes"
setcfg autonomy merge_on_verdict
out="$("$OS" merge "$P" 201 "$OK_SHA" 2>&1)"
is "a reviewed, clean, pinned PR merges" "$?" 0
has "the merge names the trunk" "$out" "#201 merged into example-trunk"
has "the merge call pins the head commit" "$(cat "$STUB_STATE/merge-args.txt")" "--match-head-commit $OK_SHA"

sect "M6 the evidence repo is required and verified"
cp "$D/programme.yaml" "$TMP/cfg.bak"
sed -i.bak "s#^repo: .*#repo: $TMP/not-a-checkout#" "$D/programme.yaml" && rm -f "$D/programme.yaml.bak"
mkdir -p "$TMP/not-a-checkout"
git -C "$BARE" update-ref "refs/pull/210/head" "$OK_SHA"
mkpr 210 example-trunk feat-ok "$OK_SHA"
"$OS" merge "$P" 210 "$OK_SHA" >/dev/null 2>&1
is "a repo that is not a checkout is refused" "$?" 3
is "that refusal is an event" "$(refused merge-repo)" 1
sed -i.bak "s#^repo: .*#repo:#" "$D/programme.yaml" && rm -f "$D/programme.yaml.bak"
"$OS" merge "$P" 210 "$OK_SHA" >/dev/null 2>&1
is "an unset repo is refused, not defaulted to the cwd" "$?" 3
cp "$TMP/cfg.bak" "$D/programme.yaml"

sect "M3 the scrubber refuses secrets, and strips more path shapes"
secret_refused() {
  printf '%s\n' "$2" > "$D/reviews/sec.md"
  "$OS" scrub "$P" "$D/reviews/sec.md" >/dev/null 2>&1
  is "$1" "$?" 3
}
secret_refused "a personal access token is refused"  'token ghp_0123456789abcdefghijklmnopqrstuvwxyz'
secret_refused "a fine-grained token is refused"     'github_pat_11ABCDEFG0abcdefghijklmn'
secret_refused "an access key id is refused"         'AKIAIOSFODNN7EXAMPLE is the key'
secret_refused "a bearer header is refused"          'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9'
secret_refused "a private key block is refused"      '-----BEGIN OPENSSH PRIVATE KEY-----'
secret_refused "a slack token is refused"            'xoxb-1234-5678-abcdefghijkl'
is "each secret refusal is an event" "$([ "$(refused scrub-secret)" -ge 6 ] && echo yes)" yes
{ printf 'see /private/tmp/build/x.log and C:\\Users\\someone\\proj\\a.ts\n'
  printf 'and /Users/someone for the rest, plus %%2Fhome%%2Fsomeone%%2Fwork\n'; } > "$D/reviews/paths.md"
"$OS" scrub "$P" "$D/reviews/paths.md" >/dev/null 2>&1
clean="$(cat "$D/reviews/paths-clean.md" 2>/dev/null)"
hasnt "a private tmp path is stripped"    "$clean" /private/tmp/build
hasnt "a windows user path is stripped"   "$clean" 'C:\Users\someone'
hasnt "a bare user path is stripped"      "$clean" /Users/someone
hasnt "an encoded home path is stripped"  "$clean" '%2Fhome%2Fsomeone'

sect "M5 the scrubber will not write through a symlink"
printf 'harmless\n' > "$D/reviews/target.md"
printf 'nothing to see\n' > "$D/reviews/sym.md"
ln -sf "$D/reviews/target.md" "$D/reviews/sym-clean.md"
"$OS" scrub "$P" "$D/reviews/sym.md" >/dev/null 2>&1
is "a symlinked output path is refused" "$?" 3
is "that refusal is an event" "$(refused scrub-unsafe-output)" 1
is "the symlink target is untouched" "$(cat "$D/reviews/target.md")" harmless

sect "M2 the loop driver builds an argv, not a command string"
src="$(cat "$PLUGIN"/scripts/*.sh)"
hasnt "no shell string is handed to tmux"        "$src" "2>&1 | tee '"
hasnt "no agent command is taken from the env"   "$src" 'ORCHESTRATE_AGENT_CMD'
setcfg every "20m'; touch $TMP/pwned; '"
"$OS" loop "$P" --tmux >/dev/null 2>&1
is "the cadence arrives as one argv element" \
  "$(grep -A1 -x -- '--every' "$STUB_STATE/tmux-args.txt" | tail -1)" "20m'; touch $TMP/pwned; '"
is "a quote in the cadence runs nothing" "$([ -f "$TMP/pwned" ] && echo pwned || echo safe)" safe
setcfg every 20m

sect "L2 the programme dir is not world readable"
is "the dir is private" "$(stat -c '%a' "$D" 2>/dev/null || stat -f '%Lp' "$D")" 700

sect "L6 classification reads the prompt, not the scrollback"
printf 'Do you want to remove this file? see the README below\n' > "$STUB_STATE/screens/h-noise.txt"
for i in $(seq 1 12); do printf 'line %s of output\n' "$i" >> "$STUB_STATE/screens/h-noise.txt"; done
printf '\xe2\x9d\xaf\n' >> "$STUB_STATE/screens/h-noise.txt"
is "old text far up the screen does not make a lane ask" \
  "$(classify claude "$(cat "$STUB_STATE/screens/h-noise.txt")")" idle

sect "the data boundary is written down"
for f in "$PLUGIN/assets/tick-prompt.md" "$PLUGIN/references/never-do.md" "$PLUGIN/skills/tick/SKILL.md"; do
  if grep -qiE 'never (an )?instruction|data, not instruction|untrusted' "$f"; then
    ok "$(basename "$(dirname "$f")")/$(basename "$f") says screen and PR text are data"
  else
    bad "$(basename "$(dirname "$f")")/$(basename "$f") says screen and PR text are data"
  fi
done
