#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# fleet-state.sh (test): the shared `cm:state` line, hermetic. Stub orca (synthetic concertmaster, lane-a, host-a,
# an unreachable host-b), a temp CM_HOME, a fixed clock (CM_NOW). The stub keeps one comment file per worktree;
# `orca worktree list` on the local host is built from those files, so write and read always see the same text.
# Covers: first write; replace keeps every other line, the state line goes last and a leading cm:merge-ready stays
# first; a pipe-embedded old line is replaced not duplicated; unchanged fields keep their value; ledger fallback;
# freeze unknown refused; bad token refused; --dry-run; read-back; --push (freeze on only, Claude terminals of
# every -sweeper lane, others and terminal-less lanes skipped); check: fresh off GO, fresh on BLOCK, exactly 30 min
# fresh and 31 stale, missing, invalid, future, concertmaster worktree not found, two hosts (or two lines) are ambiguous and block, a pinned self_host,
# an unreachable host listed; --apply adds and removes `cm:blocked cm:state stale` idempotently; override: audit
# line in the lane journal, lifts the stale rule only, never a fresh freeze=on and never a stale freeze=on, ends
# at its `until` and at the first fresh line, needs a reason, a secret-shaped reason records nothing.
#
#   scripts/test/fleet-state.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-fstate.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

FX="$ROOT/fx"; mkdir -p "$FX/own" "$FX/term"
BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/orca" <<STUB
#!/usr/bin/env bash
FX="$FX"
env=""; wt=""; comment=""; term=""; text=""
for ((i = 1; i <= \$#; i++)); do
  case "\${!i}" in
    --environment) j=\$((i + 1)); env="\${!j}" ;;
    --worktree) j=\$((i + 1)); wt="\${!j}" ;;
    --comment) j=\$((i + 1)); comment="\${!j}" ;;
    --terminal) j=\$((i + 1)); term="\${!j}" ;;
    --text) j=\$((i + 1)); text="\${!j}" ;;
  esac
done
[ "\$wt" != active ] || wt="name:\${STUB_ACTIVE:-concertmaster}"
name="\${wt#name:}"; name="\${name#path:/w/acme/}"
case "\$1 \$2" in
  "host list") if [ -e "\$FX/hl-kindless" ]; then printf '{"ok":true,"result":{"hosts":[{"name":"host-a"}]}}'; exit 0; fi
     printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"},{"kind":"environment","name":"host-a"},{"kind":"environment","name":"host-b"}]}}' ;;
  "worktree list")
    if [ -z "\$env" ]; then
      for f in "\$FX"/own/*.comment; do n="\$(basename "\$f" .comment)"; jq -cn --arg n "\$n" --rawfile c "\$f" '{path:("/w/acme/"+\$n), displayName:\$n, comment:(\$c | sub("\\n\$";""))}'; done | jq -sc '{ok:true,result:{worktrees:.}}'
    else f="\$FX/\$env.json"; [ -r "\$f" ] || { echo "host unreachable" >&2; exit 1; }; cat "\$f"; fi ;;
  "worktree show") f="\$FX/own/\$name.comment"; [ -r "\$f" ] || { echo "no such worktree" >&2; exit 1; }
     jq -cn --arg n "\$name" --rawfile c "\$f" '{ok:true,result:{worktree:{displayName:\$n, path:("/w/acme/"+\$n), comment:(\$c | sub("\\n\$";""))}}}' ;;
  "worktree set") [ ! -e "\$FX/set-fails" ] || { echo '{"ok":false}'; exit 0; }
     printf '%s\n' "\$comment" > "\$FX/own/\$name.comment"; echo "set \$name" >> "\$FX/set.log"; echo '{"ok":true}' ;;
  "terminal list") f="\$FX/term/\$name.json"; if [ -r "\$f" ]; then cat "\$f"; else echo '{"ok":true,"result":{"terminals":[]}}'; fi ;;
  "terminal send") printf '%s\t%s\n' "\$term" "\$text" >> "\$FX/sent.log"; echo '{"ok":true}' ;;
esac
STUB
chmod +x "$BIN/orca"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/acme/", orca_repo: app, self_name: concertmaster, never_touch: [NEVERid] }
CFG
export CM_CONFIG="$ROOT/config.yaml" CM_HOME="$ROOT/home" ORCA_CLI_COMMAND="$BIN/orca" PATH="$BIN:$PATH"
export CM_NOW="2026-11-01T10:00:00Z"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH CM_LEDGER CM_STATE_STALE_MIN CM_STATE_WORKTREE
mkdir -p "$CM_HOME"
F="$S/fleet-state.sh"
CMF="$FX/own/concertmaster.comment"
LEADF="$FX/own/lane-a.comment"
cmtext() { sed '$!b' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
setcm() { printf '%s\n' "$1" > "$CMF"; }
setlead() { printf '%s\n' "$1" > "$LEADF"; }
st() { printf 'cm:state freeze=%s window=%s prod=%s at=%s' "$1" "${2:-2026-11-01T15:00Z}" "${3:-v1.4.57}" "$4"; }
export STUB_ACTIVE=concertmaster
: > "$LEADF"

# ---- validate ----
"$F" validate "$(st on 2026-11-01T15:00Z v1.4.57 2026-11-01T10:00:00Z)" >/dev/null 2>&1 && pass "validate: a well-formed line" || fail "validate ok" "rejected"
for bad in "cm:state freeze=maybe window=x prod=y at=2026-11-01T10:00:00Z" "cm:state freeze=on window=x prod=y at=yesterday" "cm:state freeze=on window=x prod=y" "cm:state freeze=on window=a b prod=y at=2026-11-01T10:00:00Z" "x cm:state freeze=on window=x prod=y at=2026-11-01T10:00:00Z" "cm:running | cm:state freeze=on window=x prod=y at=2026-11-01T10:00:00Z"; do
  "$F" validate "$bad" >/dev/null 2>&1 && fail "validate bad" "$bad accepted" || :
done
pass "validate: bad freeze, bad time, missing field, spaced value, other prefix and a pipe-joined line are all refused"

# ---- write ----
setcm ""
"$F" write --freeze off >/dev/null 2>"$ROOT/err"; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$CMF")" = "cm:state freeze=off window=unknown prod=unknown at=$CM_NOW" ] && pass "first write: freeze off, window and prod unknown, at = now" || fail "first write" "rc=$RC $(cat "$CMF") $(cat "$ROOT/err")"
setcm "cm:merge-ready #41 abcdef123456
cm:running 2 workers
WORKERS I OWN: w-1
$(st on 2026-11-01T12:00Z v1.4.56 2026-11-01T09:00:00Z)
cm:child w-2"
"$F" write --window 2026-11-01T15:00Z --prod v1.4.57 >/dev/null 2>&1; RC=$?
EXP="cm:merge-ready #41 abcdef123456
cm:running 2 workers
WORKERS I OWN: w-1
cm:child w-2
cm:state freeze=on window=2026-11-01T15:00Z prod=v1.4.57 at=2026-11-01T10:00:00Z"
[ "$RC" = 0 ] && [ "$(cmtext "$CMF")" = "$EXP" ] && pass "write replaces the old line, keeps every other line in order, the state line goes last and merge-ready stays first; freeze keeps its last value (on)" || fail "replace" "rc=$RC
$(cat "$CMF")"
setcm "cm:running | $(st off 2026-11-01T12:00Z v1.4.56 2026-11-01T09:00:00Z) | cm:child w-2"
"$F" write --freeze on >/dev/null 2>&1
[ "$(grep -c 'cm:state' "$CMF")" = 1 ] && grep -q '^cm:running | cm:child w-2$' "$CMF" && grep -q 'freeze=on window=2026-11-01T12:00Z prod=v1.4.56 at=2026-11-01T10:00:00Z$' "$CMF" \
  && pass "an old line embedded after ' | ' is cut out, not duplicated; window and prod keep their last values" || fail "embedded" "$(cat "$CMF")"
setcm "cm:running"
"$F" write >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && [ "$(cat "$CMF")" = "cm:running" ] && pass "freeze unknown (no flag, no old line, no ledger): refused, comment untouched" || fail "freeze unknown" "rc=$RC"
"$F" write --freeze on --prod 'v 1' >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "a value with a space is refused" || fail "token" "rc=$RC"
"$F" write --freeze maybe >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "--freeze maybe is refused" || fail "freeze arg" "rc=$RC"
cat > "$CM_HOME/ledger.json" <<'LED'
{"workers":{},"freeze":{"state":"on","window":"2026-11-01T15:00"},"deployWindows":[{"id":"a","state":"done","tag":"v1.4.55"},{"id":"b","state":"done","tag":"v1.4.57"},{"id":"c","state":"planned","tag":"v1.4.99"}]}
LED
LB="$(cksum < "$CM_HOME/ledger.json")"
"$F" write >/dev/null 2>&1
grep -q '^cm:state freeze=on window=2026-11-01T15:00 prod=v1.4.57 at=' "$CMF" && pass "ledger fallback: freeze.state, freeze.window and the newest done deploy tag" || fail "ledger" "$(cat "$CMF")"
[ "$(cksum < "$CM_HOME/ledger.json")" = "$LB" ] && pass "write never touches the ledger" || fail "ledger touched" "changed"
rm -f "$CM_HOME/ledger.json"
setcm "cm:running"
OUT="$("$F" write --freeze off --dry-run 2>&1)"
[ "$(cat "$CMF")" = "cm:running" ] && grep -q '^cm:state freeze=off' <<<"$OUT" && pass "--dry-run prints the new comment and sets nothing" || fail "dry" "$OUT"
touch "$FX/set-fails"
"$F" write --freeze off >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "a refused orca worktree set exits 1" || fail "set refused" "rc=$RC"
rm -f "$FX/set-fails"
: > "$FX/set.log"
"$F" write --freeze off >/dev/null 2>&1
[ "$(wc -l < "$FX/set.log" | tr -d ' ')" = 1 ] && pass "one write is ONE orca worktree set call" || fail "one call" "$(cat "$FX/set.log")"

# ---- push ----
cat > "$FX/own/pr-sweeper.comment" <<<"cm:running"
cat > "$FX/own/dev-sweeper.comment" <<<"cm:running"
cat > "$FX/own/lane-a.comment" <<<"cm:running"
cat > "$FX/own/epic-x.comment" <<<"cm:running"
echo '{"ok":true,"result":{"terminals":[{"handle":"term_pr","agentIdentity":"claude"},{"handle":"term_shell","agentIdentity":""}]}}' > "$FX/term/pr-sweeper.json"
: > "$FX/sent.log"
OUT="$("$F" write --freeze on --push 2>&1)"
[ "$(wc -l < "$FX/sent.log" | tr -d ' ')" = 1 ] && grep -q '^term_pr	\[cm-freeze-' "$FX/sent.log" && grep -q 'merge freeze is ON' "$FX/sent.log" \
  && pass "--push with freeze on: ONE terminal send, to the Claude terminal of pr-sweeper" || fail "push" "$(cat "$FX/sent.log") / $OUT"
grep -q 'push: dev-sweeper@local no Claude terminal, skipped' <<<"$OUT" && ! grep -q 'lane-a\|epic-x' <<<"$OUT" \
  && pass "a sweeper without a Claude terminal is skipped and reported; a non-sweeper lane is not messaged" || fail "push skip" "$OUT"
echo '{"ok":true,"result":{"terminals":[{"handle":"term_d1","agentIdentity":"claude"},{"handle":"term_d2","agentIdentity":"claude"}]}}' > "$FX/term/dev-sweeper.json"
: > "$FX/sent.log"
OUT="$("$F" write --freeze on --push 2>&1)"
grep -q 'push: dev-sweeper@local more than one Claude terminal, skipped' <<<"$OUT" && ! grep -q 'term_d' "$FX/sent.log" && grep -q '^term_pr	' "$FX/sent.log" \
  && pass "a sweeper with two Claude terminals is skipped and reported (the reader refuses two agents); the other sweeper still gets its message" || fail "push two claude" "$(cat "$FX/sent.log") / $OUT"
rm -f "$FX/term/dev-sweeper.json"
: > "$FX/sent.log"
"$F" write --freeze off --push >/dev/null 2>&1
[ ! -s "$FX/sent.log" ] && pass "freeze off pushes nothing (leads read the line)" || fail "push off" "$(cat "$FX/sent.log")"
rm -f "$FX/own/pr-sweeper.comment" "$FX/own/dev-sweeper.comment" "$FX/own/epic-x.comment"

# ---- check: fresh, stale, boundary ----
setcm "cm:running
$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:50:00Z)"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -q '^GO freeze=off' <<<"$OUT" && pass "check: fresh freeze=off (10 min old) is GO, exit 0" || fail "fresh off" "rc=$RC $OUT"
setcm "$(st on 2026-11-01T15:00Z v1.4.57 2026-11-01T09:50:00Z)"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q '^BLOCK freeze=on' <<<"$OUT" && pass "check: fresh freeze=on is BLOCK, exit 1" || fail "fresh on" "rc=$RC $OUT"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:30:00Z)"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "check: exactly 30 minutes old is still fresh" || fail "boundary fresh" "rc=$RC"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:29:00Z)"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'cm:state stale' <<<"$OUT" && grep -q 'act as freeze=on' <<<"$OUT" && pass "check: 31 minutes old is stale: act as freeze=on, post 'cm:blocked cm:state stale'" || fail "stale" "rc=$RC $OUT"
CM_STATE_STALE_MIN=60 "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "fleet_state.stale_minutes / CM_STATE_STALE_MIN moves the limit" || fail "stale cfg" "rc=$RC"
setcm "cm:running no state line here"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'missing' <<<"$OUT" && pass "check: no cm:state line at all is missing, so BLOCK" || fail "missing" "rc=$RC $OUT"
setcm "cm:state freeze=maybe window=x prod=y at=2026-11-01T09:59:00Z"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'invalid' <<<"$OUT" && pass "check: a malformed line is invalid, so BLOCK" || fail "invalid" "rc=$RC $OUT"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T11:00:00Z)"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'future' <<<"$OUT" && pass "check: a line dated an hour in the future (clock skew) is not trusted" || fail "future" "rc=$RC $OUT"
mv "$CMF" "$ROOT/cm.keep"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'not found on any host' <<<"$("$F" read 2>&1)" && pass "no concertmaster worktree on any host read: BLOCK, and read says so" || fail "no worktree" "rc=$RC $OUT"
mv "$ROOT/cm.keep" "$CMF"

# ---- read: two hosts, an unreachable host ----
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:00:00Z)"
jq -cn --arg c "cm:running
$(st on 2026-11-01T15:00Z v1.4.58 2026-11-01T09:58:00Z)" '{ok:true,result:{worktrees:[{path:"/w/acme/concertmaster",displayName:"concertmaster",comment:$c}]}}' > "$FX/host-a.json"
OUT="$("$F" read 2>&1)"
grep -q 'ambiguous freeze=on .* (2 worktrees named for the concertmaster, 2 cm:state lines: the newest is NOT trusted, the gate blocks)' <<<"$OUT" && pass "read: two hosts each hold a concertmaster worktree with a cm:state line: ambiguous, the newest is not trusted" || fail "ambiguous" "$OUT"
grep -q '^unreachable: host-b' <<<"$OUT" && pass "read: the unreachable host is listed, not read as empty" || fail "unreach" "$OUT"
"$F" read --json 2>/dev/null | jq -e '.status == "ambiguous" and .worktreeCount == 2 and .validCount == 2 and (.hostsRead | sort == ["host-a","local"]) and (.unreachable[0].host == "host-b")' >/dev/null \
  && pass "read --json carries status, counts, hosts read and unreachable" || fail "json" "$("$F" read --json 2>&1)"
# M1 (a): a second worktree with the same name says freeze=off, newer, while the real one says freeze=on: must BLOCK
setcm "$(st on 2026-11-01T15:00Z v1.4.57 2026-11-01T09:50:00Z)"
jq -cn --arg c "$(st off 2026-11-01T15:00Z v1.4.58 2026-11-01T09:55:00Z)" '{ok:true,result:{worktrees:[{path:"/w/acme/Concertmaster",displayName:"Concertmaster",comment:$c}]}}' > "$FX/host-a.json"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q '^BLOCK act as freeze=on: cm:state ambiguous' <<<"$OUT" && ! grep -q '^GO' <<<"$OUT" \
  && pass "fail closed: a second 'Concertmaster' worktree on another host with a newer freeze=off cannot outvote the real freeze=on" || fail "M1 two worktrees" "rc=$RC $OUT"
# an override never lifts an ambiguous state
setlead "cm:override continue until=2026-11-01T12:00:00Z"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "ambiguous + override: still BLOCK (the override lifts a stale line only)" || fail "ambiguous override" "rc=$RC"
setlead ""
rm -f "$FX/host-a.json"
# M1 (b): a relayed cm:state line above the real one in the concertmaster comment
setcm "cm:merge-ready #41 abc123abc123 | $(st off 2026-11-01T15:00Z v1.4.58 2026-11-01T09:58:00Z)
$(st on 2026-11-01T15:00Z v1.4.57 2026-11-01T09:50:00Z)"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'cm:state ambiguous' <<<"$OUT" && pass "fail closed: two valid cm:state lines in one comment (a relayed freeze=off above the real freeze=on) is ambiguous: BLOCK" || fail "M1 relayed line" "rc=$RC $OUT"
# M2: a DAMAGED freeze=on line next to a valid freeze=off line is ambiguous too, not a GO on the valid one
setcm "cm:state freeze=on window=2026-11-01T15:00Z prod=v1 at=2026-11-01T09:50:00Z garbage
cm:state freeze=off window=x prod=v1 at=2026-11-01T09:58:00Z"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'cm:state ambiguous' <<<"$OUT" && ! grep -q '^GO' <<<"$OUT" && pass "fail closed: a damaged freeze=on line beside a valid freeze=off line is ambiguous: BLOCK" || fail "M2 damaged line" "rc=$RC $OUT"
setcm "cm:state freeze=ON window=x prod=v1 at=2026-11-01T09:50:00Z
cm:state freeze=off window=x prod=v1 at=2026-11-01T09:58:00Z"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "fail closed: a freeze=ON (wrong case) line beside a valid freeze=off line blocks" || fail "M2 case" "rc=$RC"
# m7: the real comment has NO line, a fake 'Concertmaster' on another host has a fresh freeze=off: BLOCK (the worktree-count half)
setcm "cm:running"
jq -cn --arg c "$(st off 2026-11-01T15:00Z v1.4.58 2026-11-01T09:58:00Z)" '{ok:true,result:{worktrees:[{path:"/w/acme/Concertmaster",displayName:"Concertmaster",comment:$c}]}}' > "$FX/host-a.json"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'cm:state ambiguous' <<<"$OUT" && pass "fail closed: no line in the real comment plus a fake worktree with a fresh freeze=off is ambiguous: BLOCK" || fail "m7 fake only" "rc=$RC $OUT"
# m6: pinned to the real host, the fake is not heard; an unread pinned host blocks
OUT="$(CM_SELF_HOST=local "$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'cm:state missing' <<<"$OUT" && pass "pinned self_host=local: the fake on host-a is ignored, the real comment has no line: BLOCK (missing)" || fail "m6 pinned local" "rc=$RC $OUT"
OUT="$(CM_SELF_HOST=host-b "$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'cm:state host-unread' <<<"$OUT" && pass "pinned self_host=host-b (unreachable): BLOCK host-unread, the fresh line on host-a is not used" || fail "m6 unread" "rc=$RC $OUT"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:58:00Z)"
jq -cn --arg c "$(st on 2026-11-01T15:00Z v1.4.58 2026-11-01T09:59:00Z)" '{ok:true,result:{worktrees:[{path:"/w/acme/concertmaster",displayName:"concertmaster",comment:$c}]}}' > "$FX/host-a.json"
OUT="$(CM_SELF_HOST=local "$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -q '^GO freeze=off' <<<"$OUT" && pass "pinned self_host=local: only the real host's line counts (a copy elsewhere neither blocks nor opens the gate)" || fail "m6 pinned ok" "rc=$RC $OUT"
rm -f "$FX/host-a.json"
T="$(printf '\t')"
# M3: a freeze=on line damaged at its START, next to a fresh valid freeze=off line, is ambiguous too
GOOD="$(st off 2026-11-01T15:00Z v1.4.58 2026-11-01T09:58:00Z)"
BADON="freeze=on window=2026-11-01T15:00Z prod=v1.4.57 at=2026-11-01T09:50:00Z"
M3OK=1
for pre in "x cm:state " "- cm:state " "CM:STATE " "cm:state:" "cm:running|cm:state " '`cm:state ' "cm:state${T}"; do
  setcm "${pre}${BADON}
$GOOD"
  "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
  [ "$RC" = 1 ] || { M3OK=0; fail "M3 prefix '$pre'" "rc=$RC"; }
done
[ "$M3OK" = 1 ] && pass "fail closed: a freeze=on line damaged at its start (prefix, dash, upper case, colon, pipe with no spaces, backtick, tab) beside a valid freeze=off blocks" || :
# the blocker a lead posts is not a state line: it must not make a healthy comment ambiguous
setcm "cm:blocked cm:state stale
$GOOD"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "a 'cm:blocked cm:state stale' segment is not counted as a state line: GO on the one valid fresh line" || fail "blocker not counted" "rc=$RC"
# M1: the blocker exemption is end-anchored: a damaged state line placed AFTER the blocker text is still counted and healed
M1OK=1
for sep in "$T" " " ""; do
  setcm "cm:blocked cm:state stale${sep}cm:state ${BADON}
$GOOD"
  "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
  [ "$RC" = 1 ] || { M1OK=0; fail "M1 sep" "rc=$RC"; }
  "$F" write --freeze off >/dev/null 2>&1
  [ "$(grep -ci 'cm:state' "$CMF")" = 1 ] || { M1OK=0; fail "M1 heal" "$(cat "$CMF")"; }
done
[ "$M1OK" = 1 ] && pass "a damaged freeze=on line after 'cm:blocked cm:state stale' (tab, space, nothing) is still counted: BLOCK, and write heals it" || :
# m11: a tab-damaged line is counted AND removed by write, so the next write heals it (no permanent ambiguity)
setcm "cm:state${T}${BADON}
$GOOD"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "a tab-damaged state line beside a valid one is ambiguous: BLOCK" || fail "tab ambiguous" "rc=$RC"
"$F" write --freeze off >/dev/null 2>&1
[ "$(grep -ci 'cm:state' "$CMF")" = 1 ] && "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "write drops the damaged line it counted: one line again and the gate opens (liveness)" || fail "heal tab" "rc=$RC $(cat "$CMF")"
# m10: a self_path without a self_host pins nothing: refused, the gate blocks
CM_SELF_PATH=/w/acme/concertmaster "$F" check --worktree name:lane-a >/dev/null 2>"$ROOT/err"; RC=$?
[ "$RC" = 1 ] && grep -q 'self_path needs worktrees.self_host' "$ROOT/err" && pass "self_path without self_host is refused (exit 1)" || fail "half pin" "rc=$RC $(cat "$ROOT/err")"
# m12: the path filter itself: same host, other path = not the worktree
setcm "$GOOD"
CM_SELF_HOST=local CM_SELF_PATH=/w/acme/elsewhere "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "pinned host and a path that does not match: BLOCK (missing)" || fail "path mismatch" "rc=$RC"
CM_SELF_HOST=local CM_SELF_PATH=/w/acme/concertmaster "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "pinned host and the exact path: GO on the real line" || fail "path match" "rc=$RC"
"$F" write --freeze on >/dev/null 2>&1
[ "$(grep -c 'cm:state' "$CMF")" = 1 ] && "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'freeze=on' "$CMF" && pass "a fresh write heals the ambiguity: one line again, and freeze=on blocks" || fail "heal" "rc=$RC $(cat "$CMF")"
rm -f "$FX/host-a.json"

# ---- check --apply ----
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:00:00Z)"
setlead "cm:running 1 worker
cm:child w-9"
: > "$FX/set.log"
"$F" check --worktree name:lane-a --apply >/dev/null 2>&1
[ "$(cat "$LEADF")" = "cm:running 1 worker
cm:child w-9
cm:blocked cm:state stale" ] && pass "--apply while stale: adds 'cm:blocked cm:state stale', keeps the lead's other lines" || fail "apply stale" "$(cat "$LEADF")"
: > "$FX/set.log"
"$F" check --worktree name:lane-a --apply >/dev/null 2>&1
[ ! -s "$FX/set.log" ] && [ "$(grep -c 'cm:state stale' "$LEADF")" = 1 ] && pass "--apply twice is idempotent: no second line, no second set" || fail "apply twice" "$(cat "$LEADF")"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:58:00Z)"
"$F" check --worktree name:lane-a --apply >/dev/null 2>&1
[ "$(cat "$LEADF")" = "cm:running 1 worker
cm:child w-9" ] && pass "--apply on the next fresh line: the stale blocker is removed (recovers)" || fail "apply fresh" "$(cat "$LEADF")"

# ---- override ----
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:00:00Z)"
setlead "cm:running"
OUT="$("$F" override --worktree name:lane-a owner said continue, state writer is down 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -q '^cm:override continue until=2026-11-01T12:00:00Z$' "$LEADF" && grep -q 'until 2026-11-01T12:00:00Z (journal lane lane-a)' <<<"$OUT" \
  && pass "override: records 'cm:override continue until=<now+2h>' in the lead's own comment" || fail "override line" "rc=$RC $OUT / $(cat "$LEADF")"
J="$("$S/lane-journal.sh" tail lane-a 5)"
grep -q 'cm:override continue until=2026-11-01T12:00:00Z reason: owner said continue, state writer is down' <<<"$J" \
  && pass "override: the audit line with the reason is in the lane journal" || fail "audit" "$J"
OUT="$("$F" check --worktree name:lane-a 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -q '^GO state stale, override active until 2026-11-01T12:00:00Z' <<<"$OUT" && pass "stale + active override: GO on the last known state (stale rule lifted)" || fail "override go" "rc=$RC $OUT"
setcm "$(st on 2026-11-01T15:00Z v1.4.57 2026-11-01T09:00:00Z)"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "stale freeze=on + override: still BLOCK (go on from the last known state)" || fail "override stale on" "rc=$RC"
setcm "$(st on 2026-11-01T15:00Z v1.4.57 2026-11-01T09:59:00Z)"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "FRESH freeze=on + override: still BLOCK, an override never lifts a fresh freeze" || fail "override fresh on" "rc=$RC"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:59:00Z)"
OUT="$("$F" check --worktree name:lane-a --apply 2>&1)"; RC=$?
grep -q 'override: expired-fresh-state' <<<"$OUT" && ! grep -q 'cm:override' "$LEADF" && pass "override ends at the first fresh cm:state and --apply removes the line" || fail "override fresh end" "$OUT / $(cat "$LEADF")"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:00:00Z)"
setlead "cm:running
cm:override continue until=2026-11-01T09:59:00Z"
OUT="$("$F" check --worktree name:lane-a --apply 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'override: expired-time' <<<"$OUT" && ! grep -q 'cm:override' "$LEADF" && grep -q 'cm:blocked cm:state stale' "$LEADF" \
  && pass "override past its until: expired, BLOCK again, the line is removed and the stale blocker posted" || fail "override expired" "rc=$RC $OUT / $(cat "$LEADF")"
setlead "cm:running"
"$F" override --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ! grep -q 'cm:override' "$LEADF" && pass "override without a reason is a usage error, nothing recorded" || fail "no reason" "rc=$RC"
B10='abcdefghij'; GHP="gh""p_"   # fake secret bodies are built from short parts at run time
"$F" override --worktree name:lane-a "token ${GHP}${B10}${B10}${B10} please" >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && ! grep -q 'cm:override' "$LEADF" && pass "a secret-shaped reason is refused by the journal and no override is recorded" || fail "secret reason" "rc=$RC $(cat "$LEADF")"
"$F" override --worktree name:lane-a --ttl-min 30 short one >/dev/null 2>&1
grep -q 'until=2026-11-01T10:30:00Z' "$LEADF" && pass "--ttl-min sets the expiry" || fail "ttl" "$(cat "$LEADF")"
setlead "cm:running"
"$F" override --worktree name:lane-a --bogus a reason >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ! grep -q 'cm:override' "$LEADF" && pass "override: an unknown --flag is a usage error, not part of the reason" || fail "override flag" "rc=$RC $(cat "$LEADF")"
"$F" override --worktree name:lane-a --ttl-min 721 too long >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ! grep -q 'cm:override' "$LEADF" && pass "override: a TTL over 12 hours is refused" || fail "ttl cap" "rc=$RC $(cat "$LEADF")"
"$F" override --worktree name:lane-a --ttl-min 0 none >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "override: a TTL of 0 is refused" || fail "ttl zero" "rc=$RC"
# m1: a hand-typed far-future until is not honoured on read
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T08:00:00Z)"
setlead "cm:override continue until=2099-01-01T00:00:00Z"
OUT="$("$F" check --worktree name:lane-a --apply 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'override: invalid-until' <<<"$OUT" && ! grep -q 'cm:override' "$LEADF" && pass "an override whose until is more than 12 h away is invalid: BLOCK, and --apply removes it" || fail "far until" "rc=$RC $OUT / $(cat "$LEADF")"
setlead ""
# write only into the concertmaster's own worktree comment
setcm "cm:running"
"$F" write --freeze on --worktree name:lane-a >/dev/null 2>"$ROOT/err"; RC=$?
[ "$RC" != 0 ] && ! grep -q 'cm:state' "$LEADF" && grep -q 'not the concertmaster worktree' "$ROOT/err" && pass "write: a worktree that is not the concertmaster's own is refused, nothing written" || fail "write target" "rc=$RC $(cat "$ROOT/err") / $(cat "$LEADF")"
# a host row with no kind is still read (and listed if it fails), never silently skipped
touch "$FX/hl-kindless"
KD="$ROOT/kindless"; mkdir -p "$KD"
# shellcheck source=/dev/null
( . "$S/lib.sh"; . "$S/fleet-read.sh"; cm_fleet_worktrees "$KD" ) >/dev/null 2>&1
if jq -e -s 'map(select(.host == "host-a")) | length == 1' "$KD/hosts.ndjson" "$KD/unreach.ndjson" >/dev/null 2>&1; then pass "fleet-read: a host row with no kind is read, not dropped"; else fail "kindless host" "$(cat "$KD/hosts.ndjson" "$KD/unreach.ndjson" 2>&1)"; fi
rm -f "$FX/hl-kindless"

# ---- review fixes: stale limit from the tick delays, ledger beats the old comment, override lifts STALE only, \n kept ----
cat > "$ROOT/config-quiet.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { path_match: "/acme/", orca_repo: app, self_name: concertmaster }
schedule: { tick_delays_s: { busy: 600, running: 1200, quiet: 1800 } }
CFG
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T09:20:00Z)"   # 40 minutes old
setlead "cm:running"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "default (no schedule in config): 40 minutes old is stale (30 minute floor)" || fail "floor" "rc=$RC"
CM_CONFIG="$ROOT/config-quiet.yaml" "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "quiet tick delay 1800 s: the limit is 2 ticks = 60 minutes, so a healthy line 40 minutes old is fresh (a fixed 30 would flap)" || fail "derived limit" "rc=$RC"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T08:50:00Z)"   # 70 minutes old
CM_CONFIG="$ROOT/config-quiet.yaml" "$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "...and 70 minutes old is stale even then" || fail "derived stale" "rc=$RC"

setcm "$(st off 2026-11-01T12:00Z v1.4.56 2026-11-01T09:50:00Z)"
cat > "$CM_HOME/ledger.json" <<'LED'
{"workers":{},"freeze":{"state":"on","window":"2026-11-01T15:00"},"deployWindows":[{"id":"b","state":"done","tag":"v1.4.57"}]}
LED
"$F" write >/dev/null 2>&1
grep -q '^cm:state freeze=on window=2026-11-01T15:00 prod=v1.4.57 at=' "$CMF" && pass "a bare every-tick write publishes a ledger change over the old comment value (freeze off -> on, new window, new prod)" || fail "ledger wins" "$(cat "$CMF")"
rm -f "$CM_HOME/ledger.json"
setcm "$(st on 2026-11-01T12:00Z v1.4.56 2026-11-01T09:50:00Z)"
"$F" write --freeze off >/dev/null 2>&1
grep -q '^cm:state freeze=off window=2026-11-01T12:00Z prod=v1.4.56 at=' "$CMF" && pass "no ledger: a flag wins and the other fields keep their last comment value" || fail "flag wins" "$(cat "$CMF")"

# an override lifts a STALE line only
setlead "cm:running
cm:override continue until=2026-11-01T12:00:00Z"
setcm "cm:running no state line"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "override + MISSING line: still BLOCK (no trustworthy last state to go on from)" || fail "override missing" "rc=$RC"
setcm "cm:state freeze=maybe window=x prod=y at=2026-11-01T09:59:00Z"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "override + INVALID line: still BLOCK" || fail "override invalid" "rc=$RC"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T11:00:00Z)"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && pass "override + FUTURE-dated line: still BLOCK" || fail "override future" "rc=$RC"
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T08:00:00Z)"
"$F" check --worktree name:lane-a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "override + STALE freeze=off line: GO (the one case it lifts)" || fail "override stale" "rc=$RC"

# other tools' lines are not rewritten: a literal backslash-n comment is byte-identical after a write that drops nothing
printf '%s\n' 'cm:running x\ncm:child foo' > "$CMF"
"$F" write --freeze off >/dev/null 2>&1
head -n1 "$CMF" | grep -qxF 'cm:running x\ncm:child foo' && pass "a literal \\n line of another tool is kept byte for byte by write" || fail "literal n" "$(cat "$CMF")"
setlead 'cm:running x\ncm:child foo'
setcm "$(st off 2026-11-01T15:00Z v1.4.57 2026-11-01T05:00:00Z)"
"$F" check --worktree name:lane-a --apply >/dev/null 2>&1
grep -qF 'cm:running x\ncm:child foo' "$LEADF" && grep -q '^cm:blocked cm:state stale$' "$LEADF" && pass "...and by check --apply while it adds the stale blocker" || fail "literal n apply" "$(cat "$LEADF")"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
