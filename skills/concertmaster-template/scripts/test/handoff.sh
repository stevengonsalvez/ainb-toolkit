#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# handoff.sh test: a STUBBED Orca CLI (ORCA_CLI_COMMAND), synthetic files, no real share. `share` prints the link
# and only the link, passes --environment through, and fails with a clear stderr line on a missing file, a file that is
# not .md/.html, a CLI that exits non-zero, a refusal (ok:false), a reply that is not JSON and a reply with no link;
# it never prints the reply body. `check` flags each host-local pattern (~/.concertmaster, $CM_HOME, the configured
# state_dir, /home/<user>/, /Users/<user>/) with its line number, passes a clean brief, reads stdin, and honours
# --target local. Touches nothing outside a mktemp dir. No network.
#
#   scripts/test/handoff.sh         # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HF="$HERE/../handoff.sh"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-handoff-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }

# Stub Orca CLI. STUB_MODE picks the reply; every call's argv is appended to $STUB_LOG.
STUB="$ROOT/stub-orca"
cat > "$STUB" <<'E'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG:?}"
case "${STUB_MODE:-ok}" in
  ok)        printf '{"id":"x","ok":true,"result":{"url":"https://example.test/a/abc123","token":"SECRET-TOKEN-1"}}\n' ;;
  nested)    printf '{"ok":true,"result":{"artifact":{"id":"i","url":"https://example.test/a/nested"}}}\n' ;;
  anywhere)  printf '{"ok":true,"result":{"shared":{"where":[{"href":"https://example.test/a/deep"}]}}}\n' ;;
  otherurl)  printf '{"ok":true,"result":{"docs":"https://example.test/docs","warnings":["https://example.test/warn"],"id":"i"}}\n' ;;
  multiline) printf '{\n  "ok": true,\n  "result": {\n    "url": "https://example.test/a/pretty"\n  }\n}\n' ;;
  trailing)  printf '{"ok":true,"result":{"url":"https://example.test/a/before-notice"}}\nupdate available: run orca update\n{ not json' ;;
  warn)      printf 'warning: slow link\n{ "level": "warn" }\n' >&2; printf '{"ok":true,"result":{"link":"https://example.test/a/warned"}}\n' ;;
  fail)      printf '{"ok":false,"error":{"code":"artifact_sharing_disabled","message":"Publishing artifacts is off"}}\n'; exit 1 ;;
  toplevel)  printf '{"ok":true,"result":{"id":"i"},"url":"https://example.test/a/top"}\n' ;;
  strerr)    printf '{"ok":false,"error":"not signed in"}\n'; exit 1 ;;
  refuse)    printf '{"ok":false,"error":{"message":"refused with exit zero"}}\n' ;;
  nolink)    printf '{"ok":true,"result":{"id":"i","token":"SECRET-TOKEN-2","note":"no url here"}}\n' ;;
  notjson)   printf 'this is not json SECRET-TOKEN-3\n' ;;
  stderr)    printf 'connection refused\n' >&2; exit 3 ;;
  leak)      printf 'auth failed token=SECRET-TOKEN-4\n'; exit 2 ;;
  notice)    printf '{"ok":true,"result":{"notice":{"href":"https://example.test/docs"},"artifact":{"url":"https://example.test/a/real"}}}\n' ;;
  barestr)   printf '{"ok":true,"result":"https://example.test/a/bare"}\n' ;;
  loopback)  printf '{"ok":true,"result":{"url":"http://127.0.0.1:6768/artifacts/abc"}}\n' ;;
  tokenmsg)  printf '{"ok":false,"error":{"message":"invalid token=%s%s for request"}}\n' abc123 def456; exit 1 ;;
  badlink)   printf '{"ok":true,"result":{"url":"javascript:alert(1)"}}\n' ;;
esac
E
chmod +x "$STUB"
export ORCA_CLI_COMMAND="$STUB" STUB_LOG="$ROOT/stub.log"

F="$ROOT/plan.md"; printf '# plan\n\nbody\n' > "$F"
H="$ROOT/page.html"; printf '<p>x</p>\n' > "$H"
T="$ROOT/notes.txt"; printf 'x\n' > "$T"

run() { # run <mode> <args...>: sets OUT (stdout), ERR (stderr), RC
  local mode="$1"; shift
  : > "$STUB_LOG"
  OUT="$(STUB_MODE="$mode" bash "$HF" "$@" 2>"$ROOT/err")"; RC=$?
  ERR="$(cat "$ROOT/err")"
}

# ---- share ----
run ok share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/abc123" ] && ok "share prints the link on stdout" || bad "share link" "rc=$RC out=$OUT err=$ERR"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && ok "and only the link (one line)" || bad "extra stdout" "$OUT"
case "$OUT$ERR" in *SECRET-TOKEN*) bad "token printed" "$OUT $ERR" ;; *) ok "the token in the reply is never printed" ;; esac
grep -qx "artifacts share $F --json" "$STUB_LOG" && ok "it runs: artifacts share <file> --json (through the ORCA_CLI_COMMAND stub = cm_orca)" || bad "argv" "$(cat "$STUB_LOG")"

run ok share "$H"
[ "$RC" = 0 ] && ok "an .html file is accepted" || bad "html" "rc=$RC $ERR"

run ok share "$F" --environment host-a
grep -qx "artifacts share $F --json --environment host-a" "$STUB_LOG" && [ "$RC" = 0 ] && ok "--environment <sel> is passed to the CLI" || bad "environment" "rc=$RC $(cat "$STUB_LOG")"
run ok share --environment host-b "$F"
grep -q -- "--environment host-b" "$STUB_LOG" && [ "$RC" = 0 ] && ok "--environment may come before the file" || bad "environment first" "$(cat "$STUB_LOG")"
run ok share "$F" --environment
[ "$RC" = 2 ] && ok "--environment with no value is a usage error (exit 2)" || bad "environment no value" "rc=$RC"

run nested share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/nested" ] && ok "a link under result.artifact.url is found" || bad "nested" "rc=$RC out=$OUT"
run anywhere share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"no link"*) true ;; *) false ;; esac && ok "an unknown reply shape fails loudly: no guessing a link from a deep field" || bad "anywhere" "rc=$RC out=$OUT"
run ok share "$F" --environment host-a
run otherurl share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "other URLs in the reply (docs, warnings) are never taken for the link" || bad "other url" "rc=$RC out=$OUT"
run multiline share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/pretty" ] && ok "a pretty-printed reply is read" || bad "multiline" "rc=$RC out=$OUT $ERR"
run trailing share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/before-notice" ] && ok "a notice line after the JSON does not break the parse" || bad "trailing" "rc=$RC out=$OUT $ERR"
run warn share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/warned" ] && ok "a warning on stderr (even one that starts with a brace) does not break the parse" || bad "warn" "rc=$RC out=$OUT"

printf '# plan\nsee $CM_HOME/briefs/x.md\n' > "$ROOT/leaky.md"
run ok share "$ROOT/leaky.md"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"line 2:"*"holds host-local references"*) true ;; *) false ;; esac && ok "share lints the file first and refuses one with host-local references" || bad "share lint" "rc=$RC err=$ERR"
[ ! -s "$STUB_LOG" ] && ok "and the CLI was not called" || bad "CLI called for a leaky file" "$(cat "$STUB_LOG")"
printf 'token ghp_%s\n' "$(printf 'a%.0s' {1..40})" > "$ROOT/secret.md"
run ok share "$ROOT/secret.md"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"secret-shaped"*) true ;; *) false ;; esac && ok "share refuses a file with a secret-shaped string (scan-secrets.sh)" || bad "secret scan" "rc=$RC err=$ERR"
case "$ERR" in *ghp_aaaa*) bad "secret printed" "$ERR" ;; *) ok "and never prints it" ;; esac
[ ! -s "$STUB_LOG" ] && ok "and the CLI was not called" || bad "CLI called for a secret file" "$(cat "$STUB_LOG")"
run ok share "$ROOT/secret.md" --no-check
[ "$RC" = 1 ] && ok "--no-check does not skip the secret scan" || bad "no-check keeps scan" "rc=$RC $ERR"
printf 'password: Hunter2Hunter!x\n' > "$ROOT/advisory.md"
run ok share "$ROOT/advisory.md"
[ "$RC" = 1 ] && case "$ERR" in *"secret-shaped"*) true ;; *) false ;; esac && ok "an advisory-class hit (password assignment) is refused too (--strict)" || bad "advisory" "rc=$RC err=$ERR"
run ok share "$ROOT/secret.md" --no-secret-scan
[ "$RC" = 0 ] && ok "--no-secret-scan skips only the secret scan" || bad "no-secret-scan" "rc=$RC $ERR"
run ok share "$ROOT/leaky.md" --no-check
[ "$RC" = 0 ] && ok "--no-check skips the path lint" || bad "no-check" "rc=$RC $ERR"
run ok share "$ROOT/leaky.md" --allow 'CM_HOME'
[ "$RC" = 0 ] && ok "--allow <ERE> passes a line that is remote on purpose" || bad "share allow" "rc=$RC $ERR"

printf '# t\n' > "$ROOT/locked.md"; chmod 000 "$ROOT/locked.md"
if [ ! -r "$ROOT/locked.md" ]; then
  run ok share "$ROOT/locked.md"
  [ "$RC" = 1 ] && case "$ERR" in *"could not run"*"exit 2"*) true ;; *) false ;; esac && ok "an unreadable file is 'check could not run', not 'host-local references'" || bad "check rc2" "rc=$RC err=$ERR"
else
  printf 'SKIP unreadable-file case (file still readable, running as root?)\n'
fi
run ok share "$ROOT/missing.md"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"is not a file"*) true ;; *) false ;; esac && ok "a missing file fails with a clear message" || bad "missing" "rc=$RC err=$ERR"
[ ! -s "$STUB_LOG" ] && ok "and the CLI was not called" || bad "CLI called for a missing file" "$(cat "$STUB_LOG")"
run ok share "$T"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *".md or .html"*) true ;; *) false ;; esac && ok "a .txt file is refused (only .md/.html)" || bad "txt" "rc=$RC err=$ERR"
[ ! -s "$STUB_LOG" ] && ok "and the CLI was not called" || bad "CLI called for a .txt" "$(cat "$STUB_LOG")"
run ok share
[ "$RC" = 2 ] && ok "no file is a usage error (exit 2)" || bad "no file" "rc=$RC"

run fail share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"Orca CLI failed"*"Publishing artifacts is off"*) true ;; *) false ;; esac && ok "a CLI that exits non-zero fails with the CLI's own message" || bad "cli fail" "rc=$RC err=$ERR"
run stderr share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"exit 3"*"withheld"*) true ;; *) false ;; esac && ok "a stderr-only failure is reported without its text" || bad "stderr fail" "rc=$RC err=$ERR"
run leak share "$F"
[ "$RC" = 1 ] && case "$OUT$ERR" in *SECRET-TOKEN*) false ;; *"exit 2"*) true ;; *) false ;; esac && ok "a non-JSON failure never echoes the CLI text (token)" || bad "leak" "rc=$RC err=$ERR"
run notice share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/real" ] && ok "result.artifact.url wins over an href in a notice" || bad "notice order" "rc=$RC out=$OUT"
run ok share -- "$F"
[ "$RC" = 0 ] && ok "share accepts -- before the file" || bad "share --" "rc=$RC $ERR"
run refuse share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"refused"*) true ;; *) false ;; esac && ok "ok:false with exit 0 is a failure" || bad "refuse" "rc=$RC err=$ERR"
run toplevel share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/top" ] && ok "a link beside result (top level) is read" || bad "toplevel" "rc=$RC out=$OUT"
run strerr share "$F"
[ "$RC" = 1 ] && case "$ERR" in *"not signed in"*) true ;; *) false ;; esac && ok "an error given as a plain string is reported" || bad "string error" "rc=$RC err=$ERR"
run nolink share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"no link"*) true ;; *) false ;; esac && ok "JSON without a link fails" || bad "no link" "rc=$RC err=$ERR"
case "$OUT$ERR" in *SECRET-TOKEN*) bad "token printed on a no-link failure" "$ERR" ;; *) ok "and the reply body (with its token) is not echoed" ;; esac
run notjson share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && case "$ERR" in *"not JSON"*) true ;; *) false ;; esac && ok "a reply that is not JSON fails" || bad "not json" "rc=$RC err=$ERR"
case "$OUT$ERR" in *SECRET-TOKEN*) bad "token printed on a non-JSON failure" "$ERR" ;; *) ok "and its text is not echoed" ;; esac
run barestr share "$F"
[ "$RC" = 0 ] && [ "$OUT" = "https://example.test/a/bare" ] && ok "a result that is a bare URL string is read" || bad "barestr" "rc=$RC out=$OUT"
run loopback share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "a loopback or private-network link is never printed (the other host cannot open it)" || bad "loopback" "rc=$RC out=$OUT"
run tokenmsg share "$F"
[ "$RC" = 1 ] && case "$ERR" in *abc123def456*) false ;; *"withheld"*) true ;; *) false ;; esac && ok "a CLI error message that looks like a secret is withheld" || bad "token msg" "rc=$RC err=$ERR"
run badlink share "$F"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "a non-http(s) value is not taken for a link" || bad "bad link" "rc=$RC out=$OUT"

# a CLI that cannot be found at all
OUT="$(ORCA_CLI_COMMAND="$ROOT/no-such-cli" bash "$HF" share "$F" 2>"$ROOT/err")"; RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "a missing CLI fails (exit 1, no stdout)" || bad "no cli" "rc=$RC out=$OUT $(cat "$ROOT/err")"

# ---- check ----
BR="$ROOT/brief.md"
cat > "$BR" <<'E'
# Brief
Read ~/.concertmaster/inbox/plan.md first.
Then $CM_HOME/briefs/w-1.md.
And ${CM_HOME}/ledger.json.
State lives in /srv/cm-state-test/data.
See /home/someone/work/x.
And /Users/someone/work/y.
A bare /home/ or /Users/ is not a hit, nor is a link https://example.test/a/1.
E
CM_STATE_CFG="$ROOT/cfg.yaml"
printf 'state_dir: /srv/cm-state-test\n' > "$CM_STATE_CFG"

run_check() { # run_check <args...>: stdout+stderr in OUT, status in RC; config with a state_dir
  OUT="$(CM_CONFIG="$CM_STATE_CFG" bash "$HF" check "$@" 2>&1)"; RC=$?
}
run_check "$BR"
[ "$RC" = 1 ] && ok "a brief with host-local references exits 1" || bad "check exit" "rc=$RC $OUT"
case "$OUT" in *"line 2: ~/.concertmaster:"*) ok "flags ~/.concertmaster with its line number" ;; *) bad "tilde" "$OUT" ;; esac
case "$OUT" in *'line 3: $CM_HOME:'*) ok 'flags $CM_HOME with its line number' ;; *) bad "CM_HOME" "$OUT" ;; esac
case "$OUT" in *'line 4: $CM_HOME:'*) ok 'flags ${CM_HOME} with its line number' ;; *) bad "CM_HOME braces" "$OUT" ;; esac
case "$OUT" in *"line 5: /srv/cm-state-test:"*) ok "flags the configured state_dir" ;; *) bad "state_dir" "$OUT" ;; esac
case "$OUT" in *"line 6: /home/<user>/:"*) ok "flags /home/<user>/" ;; *) bad "home" "$OUT" ;; esac
case "$OUT" in *"line 7: /Users/<user>/:"*) ok "flags /Users/<user>/" ;; *) bad "Users" "$OUT" ;; esac
case "$OUT" in *"line 8:"*) bad "bare /home/ or a link flagged" "$OUT" ;; *) ok "a bare /home/, /Users/ and a link are not flagged" ;; esac

CLEAN="$ROOT/clean.md"
printf '# Brief\nRead https://example.test/a/plan and the issue.\nWork in the repo root; report with cm:running.\n' > "$CLEAN"
run_check "$CLEAN"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "a clean brief exits 0 with no output" || bad "clean" "rc=$RC $OUT"

OUT="$(printf 'ok line\nuse ~/.concertmaster/x\n' | CM_CONFIG="$CM_STATE_CFG" bash "$HF" check - 2>&1)"; RC=$?
[ "$RC" = 1 ] && case "$OUT" in *"line 2: ~/.concertmaster:"*) true ;; *) false ;; esac && ok "check - reads stdin" || bad "stdin" "rc=$RC $OUT"

printf 'runner: /home/runner/work/x\nmine: /home/someone/y\n' > "$ROOT/allow.md"
run_check "$ROOT/allow.md" --allow '/home/runner'
[ "$RC" = 1 ] && case "$OUT" in *"line 2: /home/<user>/:"*"/home/someone"*) true ;; *) false ;; esac && ok "--allow skips a line that matches, others still flag" || bad "allow partial" "rc=$RC $OUT"
printf 'CI /home/runner/work/x and also ~/.concertmaster/inbox/y\n' > "$ROOT/sameline.md"
run_check "$ROOT/sameline.md" --allow '/home/runner'
[ "$RC" = 1 ] && case "$OUT" in *"~/.concertmaster"*) true ;; *) false ;; esac && ok "--allow matches the flagged text: a second host-local path on the same line is still reported" || bad "allow same line" "rc=$RC $OUT"
printf 'two: /home/ci/build /home/owner-a/plan.md\n' > "$ROOT/two.md"
run_check "$ROOT/two.md" --allow 'home/ci'
[ "$RC" = 1 ] && case "$OUT" in *"/home/owner-a"*) true ;; *) false ;; esac && ok "an allowed path does not hide the next path one space away" || bad "adjacent paths" "rc=$RC $OUT"
printf 'quoted log: /home/runner/work/x\n' > "$ROOT/allow2.md"
run_check "$ROOT/allow2.md" --allow '/home/runner'
[ "$RC" = 0 ] && ok "--allow makes a line of only allowed paths pass" || bad "allow all" "rc=$RC $OUT"
run_check "$ROOT/allow2.md" --allow '['
[ "$RC" = 2 ] && case "$OUT" in *"not a valid ERE"*) true ;; *) false ;; esac && ok "an invalid --allow ERE is a usage error, not a silent no-match" || bad "allow bad ere" "rc=$RC $OUT"
run_check "$ROOT/allow2.md" --allow
[ "$RC" = 2 ] && ok "--allow with no value is a usage error" || bad "allow no value" "rc=$RC"
printf 'dot . and slash / and a/b path\nnothing here\n' > "$ROOT/short.md"
OUT="$(CM_CONFIG="$ROOT/short.yaml" bash "$HF" check "$ROOT/short.md" 2>&1)"; RC=$?
printf 'state_dir: .\n' > "$ROOT/short.yaml"
OUT="$(CM_CONFIG="$ROOT/short.yaml" bash "$HF" check "$ROOT/short.md" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "a too short state_dir (.) does not flag every line" || bad "short state_dir" "rc=$RC $OUT"
OUT="$(bash "$HF" check --help 2>&1)"
case "$OUT" in *"--target local"*"--allow <ERE>"*"Every Orca call goes through cm_orca"*) ok "--help prints the whole header" ;; *) bad "usage cut off" "$OUT" ;; esac

mkdir -p "$ROOT/adir"
run_check "$ROOT/adir"
[ "$RC" = 2 ] && ok "a directory is exit 2, never a silent pass" || bad "directory" "rc=$RC $OUT"
printf 'a $HOME/.concertmaster/x\nb ${HOME}/.concertmaster/y\nc /root/.concertmaster/z\nd ~/.secrets/ok\n' > "$ROOT/home.md"
run_check "$ROOT/home.md"
[ "$RC" = 1 ] && case "$OUT" in *"line 1:"*"line 2:"*"line 3:"*) true ;; *) false ;; esac && case "$OUT" in *"line 4:"*) false ;; *) true ;; esac && ok '$HOME, ${HOME} and /root .concertmaster paths are flagged; ~/.secrets is not' || bad "home variants" "rc=$RC $OUT"
printf 'v ${CM_HOME:-x}/a\nr /root/work/plan.md\n' > "$ROOT/more.md"
run_check "$ROOT/more.md"
[ "$RC" = 1 ] && case "$OUT" in *"line 1: \$CM_HOME:"*"line 2: /root/:"*) true ;; *) false ;; esac && ok '${CM_HOME:-x} and /root/... are flagged' || bad "more patterns" "rc=$RC $OUT"
printf 'see file:///home/user-a/x/plan.md\n' > "$ROOT/fileurl.md"
run_check "$ROOT/fileurl.md"
[ "$RC" = 1 ] && ok "a file:///home/<user>/ URL is flagged" || bad "file url" "rc=$RC $OUT"
run ok share -- "$ROOT/leaky.md" --no-check
printf '# t\n' > "$ROOT/-dash.md"
( cd "$ROOT" && STUB_MODE=ok STUB_LOG="$STUB_LOG" bash "$HF" share -- -dash.md ) >/dev/null 2>"$ROOT/err"; drc=$?
[ "$drc" = 0 ] && ok "share -- -dash.md works (the nested check gets the -- too)" || bad "dash file" "rc=$drc $(cat "$ROOT/err")"
( cd "$ROOT" \
  && : > "$STUB_LOG" && STUB_MODE=ok bash "$HF" share -- -dash.md ) >/dev/null 2>&1
grep -qx "artifacts share ./-dash.md --json" "$STUB_LOG" && ok "a dash-leading file reaches the CLI as ./-dash.md" || bad "dash to cli" "$(cat "$STUB_LOG")"

printf 'x /home/me/.concertmaster/y $CM_HOME\n' > "$ROOT/multi.md"
run_check "$ROOT/multi.md"
[ "$(printf '%s\n' "$OUT" | grep -c '^line ')" = 1 ] && case "$OUT" in *"1 line(s)"*) true ;; *) false ;; esac && ok "a line matching several patterns is reported once" || bad "dedupe" "$OUT"
printf 'logs in /home/user-a. And cd /Users/user-b\nurl https://app.example.test/home/page/x\nvar $CM_HOME_FOO and $CM_HOMEX\n' > "$ROOT/edge.md"
run_check "$ROOT/edge.md"
[ "$RC" = 1 ] && case "$OUT" in *"line 1: /home/<user>/:"*) true ;; *) false ;; esac && case "$OUT" in *"line 2:"*|*"line 3:"*) false ;; *) true ;; esac && ok "a home dir without a trailing slash is flagged; a URL /home/ path and \$CM_HOME_FOO are not" || bad "edge cases" "rc=$RC $OUT"
( set -o pipefail; seq 1 300000 | bash "$HF" check - --target local ); drc=$?
[ "$drc" = 0 ] && ok "--target local drains stdin (no SIGPIPE for a producer under pipefail)" || bad "drain" "rc=$drc"
printf 'the build state is fine\n' > "$ROOT/prose.md"
printf 'state_dir: state\n' > "$ROOT/rel.yaml"
OUT="$(CM_CONFIG="$ROOT/rel.yaml" bash "$HF" check "$ROOT/prose.md" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "a relative state_dir (a plain word) does not flag prose" || bad "relative state_dir" "rc=$RC $OUT"

run_check "$BR" --target local
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "--target local skips the check (exit 0, no output)" || bad "target local" "rc=$RC $OUT"
run_check --target local "$BR"
[ "$RC" = 0 ] && ok "--target may come first" || bad "target first" "rc=$RC $OUT"
run_check "$BR" --target remote
[ "$RC" = 1 ] && ok "--target remote checks" || bad "target remote" "rc=$RC $OUT"
run_check "$BR" --target elsewhere
[ "$RC" = 2 ] && ok "an unknown --target is a usage error (exit 2)" || bad "target bad" "rc=$RC $OUT"
run_check "$ROOT/missing.md"
[ "$RC" = 2 ] && ok "an unreadable file is exit 2" || bad "check missing" "rc=$RC $OUT"
OUT="$(bash "$HF" 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "no verb is a usage error (exit 2)" || bad "no verb" "rc=$RC"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
