#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# references/account-switch.md (test): the fenced "account-switch" script is extracted from the doc and run
# under bash and under zsh (when installed) against stub ssh, scp and account tool commands. Each "host" is a
# directory used as HOME, so the remote ~/.secrets is a real directory. Hermetic: no network, no real tool.
# Covers: a clean run (every host on the new identity, home last, no export file left anywhere, no identity or
# token text in the output); the guards (bad NUM, a leading-dash identity: nothing written); a failed export, a
# failed copy and a half-written copy (no account changed, no file left); a failed import on the second host
# (the first stays switched, the second and home do not, no file left); SIGTERM mid import (exit 130, cleanup
# ran); the check block (empty when clean, names a leftover); the trap is armed before the export is written.
#
#   scripts/test/account-switch.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="$HERE/../../references/account-switch.md"
[ -r "$DOC" ] || { echo "no doc at $DOC" >&2; exit 2; }
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-acctswitch.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# the fixture identity is built at run time so no address literal sits in this file
AT='@'; IDENT="fixture.person${AT}acme-demo.test"; OTHER="fixture.other${AT}acme-demo.test"
TOKEN="TOKEN-FIXTURE-$$"

# ---- extract the fenced blocks ----
fence() { awk -v tag="$1" '$0 == "```bash " tag {f=1; next} f && $0 == "```" {exit} f' "$DOC"; }
fence account-switch > "$ROOT/script.sh"
fence switch-check > "$ROOT/check.sh"
[ -s "$ROOT/script.sh" ] && pass "the doc has an account-switch script block" || { fail "script block" "empty"; exit 1; }
[ -s "$ROOT/check.sh" ] && pass "the doc has a check block" || fail "check block" "empty"

# ---- stubs ----
BIN="$ROOT/bin"; mkdir -p "$BIN" "$ROOT/hosts"
cat > "$ROOT/accounts.json" <<EOF
{"accounts":[{"number":1,"email":"$OTHER"},{"number":2,"email":"$IDENT"}]}
EOF
cat > "$BIN/acct-tool" <<'EOF'
#!/usr/bin/env bash
# stub: state lives under $HOME (one directory per host); every command names the accounts on stdout
case "$1" in
  list) cat "$STUB_ROOT/accounts.json"; echo "active: $(cat "$HOME/active" 2>/dev/null)" ;;
  export) [ -z "${FAIL_EXPORT:-}" ] || { echo "export failed for $OTHER"; exit 1; }
          printf '%s\n' "$STUB_TOKEN" > "$2"; echo "exported accounts $OTHER and $STUB_IDENT" ;;
  import) [ -r "$2" ] || exit 1
          [ "${FAIL_IMPORT_HOST:-}" != "$(basename "$HOME")" ] || { echo "import failed"; exit 1; }
          if [ "${SLOW_IMPORT_HOST:-}" = "$(basename "$HOME")" ]; then
            : > "$STUB_ROOT/importing"; n=0; while [ ! -e "$STUB_ROOT/go" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
          fi
          echo imported > "$HOME/imported"; echo "imported $STUB_IDENT" ;;
  switch) echo "$2" > "$HOME/active"; echo "switched to $2" ;;
  *) exit 2 ;;
esac
EOF
cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
while [ "$1" = -o ]; do shift 2; done
h="$1"; shift
[ "${FAIL_SSH_HOST:-}" != "$h" ] || exit 255
HOME="$STUB_ROOT/hosts/$h" exec bash -c "$1"
EOF
cat > "$BIN/scp" <<'EOF'
#!/usr/bin/env bash
while [ "$1" = -p ] || [ "$1" = -o ]; do [ "$1" = -o ] && shift 2 || shift; done
src="$1"; h="${2%%:*}"; dst="${2#*:}"; dst="$STUB_ROOT/hosts/$h/${dst#\~/}"
if [ "${FAIL_SCP_HOST:-}" = "$h" ]; then head -c 3 "$src" > "$dst.tmp"; exit 1; fi
cp -p "$src" "$dst"
EOF
chmod +x "$BIN"/*

# run <shell> <outfile> [env assignments...]: a fresh set of host directories, then the script
# (hosts: home = the machine running the script, host-a, host-b = the destinations)
run() {
  local sh="$1" out="$2"; shift 2
  rm -rf -- "${ROOT:?}/hosts"; mkdir -p "$ROOT/hosts/home" "$ROOT/hosts/host-a" "$ROOT/hosts/host-b"
  printf 'old\n' > "$ROOT/hosts/home/active"; printf 'old\n' > "$ROOT/hosts/host-a/active"; printf 'old\n' > "$ROOT/hosts/host-b/active"
  rm -f "$ROOT/importing" "$ROOT/go"
  env "$@" HOME="$ROOT/hosts/home" PATH="$BIN:$PATH" STUB_ROOT="$ROOT" STUB_TOKEN="$TOKEN" STUB_IDENT="$IDENT" OTHER="$OTHER" \
    "$sh" "$ROOT/script.sh" > "$out" 2>&1
}
left() { find "$ROOT/hosts" -name '*export.json*' 2>/dev/null; }      # any export file, any suffix, any host
act() { cat "$ROOT/hosts/$1/active" 2>/dev/null; }
quiet() { ! grep -q -e "$IDENT" -e "$OTHER" -e "$TOKEN" "$1"; }     # no identity, no token in the output

SHELLS="bash"; command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"
for SH in $SHELLS; do
  echo "--- under $SH"
  O="$ROOT/out.$SH"
  run "$SH" "$O" NUM=2; RC=$?
  [ "$RC" = 0 ] && pass "$SH: clean run exits 0" || fail "$SH clean rc" "rc=$RC"
  [ "$(act host-a)" = "$IDENT" ] && [ "$(act host-b)" = "$IDENT" ] && [ "$(act home)" = "$IDENT" ] && pass "$SH: every host is on the chosen identity" || fail "$SH identities" "$(act host-a) $(act host-b) $(act home)"
  [ -z "$(left)" ] && pass "$SH: no export file left on any host" || fail "$SH leftovers" "$(left)"
  quiet "$O" && pass "$SH: no identity or token text in the output" || fail "$SH output" "an identity or token reached the output"
  [ ! -s "$O" ] && pass "$SH: the clean run prints nothing" || fail "$SH silence" "$(wc -c < "$O") bytes"

  run "$SH" "$O" NUM=; RC=$?
  [ "$RC" = 1 ] && [ ! -d "$ROOT/hosts/home/.secrets" ] && [ "$(act host-a)" = old ] && pass "$SH: an empty NUM stops before anything is written" || fail "$SH empty NUM" "rc=$RC"
  run "$SH" "$O" 'NUM=2;touch x'; RC=$?
  [ "$RC" = 1 ] && [ ! -d "$ROOT/hosts/home/.secrets" ] && pass "$SH: a non-numeric NUM stops before anything is written" || fail "$SH bad NUM" "rc=$RC"
  run "$SH" "$O" NUM=9; RC=$?
  [ "$RC" = 1 ] && [ ! -d "$ROOT/hosts/home/.secrets" ] && [ "$(act host-a)" = old ] && pass "$SH: an unknown slot (no identity) stops before anything is written" || fail "$SH unknown NUM" "rc=$RC"
  printf '{"accounts":[{"number":2,"email":"-bad%sacme-demo.test"}]}\n' "$AT" > "$ROOT/accounts.json.dash"
  cp "$ROOT/accounts.json" "$ROOT/accounts.json.keep"; cp "$ROOT/accounts.json.dash" "$ROOT/accounts.json"
  run "$SH" "$O" NUM=2; RC=$?
  cp "$ROOT/accounts.json.keep" "$ROOT/accounts.json"
  [ "$RC" = 1 ] && [ ! -d "$ROOT/hosts/home/.secrets" ] && pass "$SH: an identity starting with a dash stops before anything is written" || fail "$SH dash identity" "rc=$RC"

  run "$SH" "$O" NUM=2 FAIL_EXPORT=1; RC=$?
  [ "$RC" = 1 ] && [ "$(act host-a)" = old ] && [ "$(act host-b)" = old ] && [ "$(act home)" = old ] && [ -z "$(left)" ] && quiet "$O" && pass "$SH: a failed export changes no account and leaves no file" || fail "$SH export fail" "rc=$RC left=$(left)"
  run "$SH" "$O" NUM=2 FAIL_SCP_HOST=host-b; RC=$?
  [ "$RC" != 0 ] && [ "$(act host-a)" = old ] && [ "$(act host-b)" = old ] && [ "$(act home)" = old ] && [ -z "$(left)" ] && quiet "$O" && pass "$SH: a failed or half-written copy changes no account and leaves no file (the .tmp sibling too)" || fail "$SH scp fail" "rc=$RC left=$(left)"
  run "$SH" "$O" NUM=2 FAIL_IMPORT_HOST=host-b; RC=$?
  [ "$RC" != 0 ] && [ "$(act host-a)" = "$IDENT" ] && [ "$(act host-b)" = old ] && [ "$(act home)" = old ] && [ -z "$(left)" ] && quiet "$O" && pass "$SH: a failed import leaves the first host switched, the rest and home not, and no file" || fail "$SH import fail" "rc=$RC a=$(act host-a) b=$(act host-b) left=$(left)"
  run "$SH" "$O" NUM=2 FAIL_SSH_HOST=host-b; RC=$?
  [ "$RC" != 0 ] && [ "$(act home)" = old ] && [ -z "$(left)" ] && grep -q 'token export may remain on host-b' "$O" && quiet "$O" && pass "$SH: an unreachable host is named as 'may remain' by host name only" || fail "$SH ssh fail" "rc=$RC"

  # SIGTERM while host-a is inside its import: exit 130, host-b and home never switched, cleanup ran
  rm -rf -- "${ROOT:?}/hosts"; mkdir -p "$ROOT/hosts/home" "$ROOT/hosts/host-a" "$ROOT/hosts/host-b"
  for h in home host-a host-b; do printf 'old\n' > "$ROOT/hosts/$h/active"; done
  rm -f "$ROOT/importing" "$ROOT/go"
  env NUM=2 HOME="$ROOT/hosts/home" PATH="$BIN:$PATH" STUB_ROOT="$ROOT" STUB_TOKEN="$TOKEN" STUB_IDENT="$IDENT" OTHER="$OTHER" SLOW_IMPORT_HOST=host-a \
    "$SH" "$ROOT/script.sh" > "$O" 2>&1 &
  PID=$!; n=0; while [ ! -e "$ROOT/importing" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  kill -TERM "$PID" 2>/dev/null; : > "$ROOT/go"; wait "$PID"; RC=$?
  [ "$RC" = 130 ] && pass "$SH: SIGTERM exits 130" || fail "$SH sigterm rc" "rc=$RC"
  [ "$(act host-b)" = old ] && [ "$(act home)" = old ] && [ -z "$(left)" ] && quiet "$O" && pass "$SH: SIGTERM switches nothing further and the cleanup removed every export file" || fail "$SH sigterm state" "b=$(act host-b) home=$(act home) left=$(left)"

  # the check block: empty when clean, names a leftover, by path only
  run "$SH" "$O" NUM=2
  CHK="$ROOT/check.run.sh"; sed 's/<host>/host-a/' "$ROOT/check.sh" > "$CHK"
  OUTC="$(env HOME="$ROOT/hosts/home" PATH="$BIN:$PATH" STUB_ROOT="$ROOT" "$SH" "$CHK" 2>&1)"
  [ -z "$OUTC" ] && pass "$SH: the check prints nothing after a clean run" || fail "$SH check clean" "$OUTC"
  mkdir -p "$ROOT/hosts/host-a/.secrets"; printf 'x\n' > "$ROOT/hosts/host-a/.secrets/acct-export.json.tmp"
  OUTC="$(env HOME="$ROOT/hosts/home" PATH="$BIN:$PATH" STUB_ROOT="$ROOT" "$SH" "$CHK" 2>&1)"
  case "$OUTC" in *acct-export.json.tmp*) pass "$SH: the check names a leftover on a destination" ;; *) fail "$SH check leftover" "$OUTC" ;; esac
done

# ---- static: ordering and hygiene of the documented script ----
trap_line="$(grep -n '^trap cleanup EXIT$' "$ROOT/script.sh" | head -1 | cut -d: -f1)"
exp_line="$(grep -n '^tool_export ' "$ROOT/script.sh" | head -1 | cut -d: -f1)"
[ -n "$trap_line" ] && [ -n "$exp_line" ] && [ "$trap_line" -lt "$exp_line" ] && pass "the EXIT trap is armed before the token export is written" || fail "trap order" "trap=$trap_line export=$exp_line"
grep -q "^trap 'exit 130' INT TERM$" "$ROOT/script.sh" && grep -q "trap '' INT TERM" "$ROOT/script.sh" && pass "INT and TERM exit 130 and are ignored inside the cleanup" || fail "signal traps" "missing"
grep -q 'BatchMode=yes' "$ROOT/script.sh" && grep -q 'ConnectTimeout=10' "$ROOT/script.sh" && pass "ssh and scp run with BatchMode and a ConnectTimeout" || fail "ssh options" "missing"
! grep -q 'set -e' "$ROOT/script.sh" && pass "the script does not rely on set -e" || fail "set -e" "present"
! grep -nE '(echo|printf)[^|]*\$ACCT' "$ROOT/script.sh" >/dev/null && pass "the script never prints the identity" || fail "print identity" "found"
! LC_ALL=C grep -q $'\xe2\x80\x94' "$DOC" && pass "the doc has no em-dash" || fail "em-dash" "present"
command -v shellcheck >/dev/null 2>&1 && { { printf '#!/usr/bin/env bash\nNUM=2\n'; cat "$ROOT/script.sh"; } > "$ROOT/sc.sh"; shellcheck -s bash "$ROOT/sc.sh" >"$ROOT/sc.out" 2>&1 && pass "the documented script is shellcheck clean" || fail "shellcheck" "$(head -5 "$ROOT/sc.out")"; }

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
