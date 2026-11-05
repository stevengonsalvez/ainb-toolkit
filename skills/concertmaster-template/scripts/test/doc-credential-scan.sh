#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# Behavioural test of scripts/doc-credential-scan.sh in throwaway git repos.
#
#   bash scripts/test/doc-credential-scan.sh        # exit 0 when every case passes
#
# Hermetic: a mktemp -d fixture repo per case, `git -c commit.gpgsign=false` for the FIXTURE repo only, no network.
# Every fixture credential is built at run time from pieces (rep and split strings), so no complete email-plus-password
# literal sits in this file and no secret scanner can flag the test itself. Fixture addresses use a reserved .test
# domain (acme-demo.test) because example.com is on the scanner's placeholder list; values are invented.
# Failure messages print the case name and exit code only, never a fixture value.
set -uo pipefail
SCAN="$(cd "$(dirname "$0")/.." && pwd)/doc-credential-scan.sh"
[ -r "$SCAN" ] || { echo "no scanner at $SCAN" >&2; exit 2; }
# hermetic: no global or system git config (a global core.hooksPath, init template or signing setup), no real HOME
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
T="$(mktemp -d "${TMPDIR:-/tmp}/doc-cred-test.XXXXXX")" || exit 2
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $T" >&2 || rm -rf -- "${T:?}"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
OUT="$T/out"; ALL="$T/all-output"; : > "$ALL"
PASS=0; FAIL=0; N=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

rep() { local s="" i; for ((i = 0; i < $2; i++)); do s="$s$1"; done; printf '%s' "$s"; }
LOCALPART="fixture.$(rep u 1)ser$(rep 7 1)"          # not a real address; the domain below is reserved
E="${LOCALPART}@acme-demo.test"
V="$(rep Q 2)$(rep 7 2)k!$(rep z 3)"                 # 9 chars: upper, digit, lower, symbol
VS="$(rep Q 1)$(rep 7 1)k!z"                          # 5 chars: too short to be a value
V2="$(rep a 5)$(rep b 3)$(rep 1 1)"                  # 9 chars: lower and digit only (2 classes)
VD="\$ecret$(rep 1 1)234"                              # lowercase $name: not an env var placeholder
VC="Change""Me20""24!"                                # a default password, not the word changeme
VA="P@ss""w0rd!"                                      # an @ inside the value
VAT="Hunter""@2024"
VQ="O""'Brien""$(rep 2 1)024!"                          # a quote inside the value
VQ2="Ab12\"cd""efg!"                                  # a double quote inside the value
VLD="hunter""2024abc"                                    # lowercase letters and digits only
VL="Sunrise""Meadow"                                  # 13 letters, no digit or symbol
EX="${LOCALPART}@example.com"

newrepo() { # newrepo <name> : fixture repo with a base commit, cwd moved into it
  R="$T/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q -b main --template= . && git config core.hooksPath /dev/null && git config user.email t@t.invalid && git config user.name fixture \
      && echo base > README.md && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1 || { echo "fixture repo failed" >&2; exit 2; }
  cd "$R" || exit 2
}
commit_all() { git add -A && git -c commit.gpgsign=false commit -qm "$1" >/dev/null 2>&1; }
scan() { bash "$SCAN" "$@" > "$OUT" 2>&1; RC=$?; cat "$OUT" >> "$ALL"; }
want_rc() { [ "$RC" = "$2" ] && pass "$1" || fail "$1" "exit $RC, wanted $2"; }
want_out() { grep -q -- "$2" "$OUT" && pass "$1" || fail "$1" "output lacks the expected line"; }

# both <desc> <want-rc> <path> <line> : the same added line, seen through --staged and through --range
both() {
  N=$((N + 1)); newrepo "pair-$N"; mkdir -p "$(dirname "$3")"; printf '%s\n' "$4" > "$3"; git add -A
  scan --staged; want_rc "$1 (staged)" "$2"
  commit_all change
  scan --range HEAD~1..HEAD; want_rc "$1 (range)" "$2"
}

# ---- the headline shape: an email, then a password-looking value, on one Markdown line ----------------
both "the login-line shape (email / value) is refused" 1 docs/login.md "- prod login: \`${E}\` / \`${V}\`"
both "a table row with the value in the next cell is refused" 1 docs/users.md "| ${E} | ${V} |"
both "email: x, password: y is refused" 1 docs/creds.md "email: ${E}, password: ${V}"
both "a backticked value after password is is refused" 1 docs/creds.md "The password is \`${V}\` for ${E}."
both "a pure-letter value after password is refused" 1 docs/creds.md "${E} password: ${VL}"
both "email:value@host (an email as the URL user) is refused" 1 docs/db.md "connect with https://${E}:${V}@db.internal.test/app"
both "a JSON line with email and password keys in a .json file is refused" 1 config/seed.json "{\"email\":\"${E}\",\"password\":\"${V}\"}"
both "a .yaml line is refused" 1 ops/users.yaml "login: ${E} / ${V}"
both "a .txt file is refused" 1 notes/n.txt "${E} / ${V}"

# ---- what must pass -------------------------------------------------------------------------------------------
both "an email with no password value passes" 0 docs/contact.md "Ask ${E} about the rota."
both "a password with no email passes" 0 docs/creds.md "password: ${V}"
both "a value shorter than 8 characters passes" 0 docs/creds.md "${E} password: ${VS}"
both "a value with only 2 character classes passes" 0 docs/creds.md "${E} / ${V2}"
both "a placeholder in angle brackets passes" 0 docs/creds.md "${E} / <the password>"
both "a \${VAR} placeholder passes" 0 docs/creds.md "${E} password: \${SEED_PASSWORD}"
both "a \$VAR placeholder passes" 0 docs/creds.md "${E} password: \$SEED_PASSWORD"
both "changeme passes" 0 docs/creds.md "${E} password: changeme"
both "REDACTED passes" 0 docs/creds.md "${E} password: REDACTED"
both "a run of stars passes" 0 docs/creds.md "${E} password: *****"
both "an example.com address passes" 0 docs/creds.md "${EX} / ${V}"
both "a named password beside only an example.com address passes" 0 docs/creds.md "${EX} password: ${V}"
both "a named password and no @ anywhere passes" 0 docs/creds.md "user at acme-demo dot test password: ${V}"
both "a lowercase \$name value is refused (only \$UPPER names are placeholders)" 1 docs/creds.md "${E} password: ${VD}"
both "ChangeMe plus digits and a symbol is refused (only the bare word is a placeholder)" 1 docs/creds.md "${E} / ${VC}"
both "an email in angle brackets then / value is refused" 1 docs/creds.md "<${E}> / ${V}"
both "a hyphenated role word in the next cell passes" 0 docs/users.md "| ${E} | Super-Admin |"
both "a path-like word after login/ passes" 0 docs/nav.md "Contact ${E}, see /login/Reset-Password-Flow"
both "password was <value> is refused (the was branch consumes the whole word)" 1 docs/creds.md "${E} password was ${V}"
both "a lowercase slug with a digit in the next cell passes" 0 docs/users.md "| ${E} | reset-flow-2024 |"
NL=$'\n'
both "an @ inside the value does not hide it (email / P@ssw0rd!)" 1 docs/creds.md "${E} / ${VA}"
both "an @ inside the value does not hide it (password: Hunter@2024)" 1 docs/creds.md "${E} password: ${VAT}"
both "a value that looks like an email is still not a password" 0 docs/creds.md "${E} / other.fixture@acme-demo.test"
both "password then a backticked value, whitespace only, is refused" 1 docs/creds.md "${E}, password \`${V}\`"
both "(pw value) with whitespace only is refused" 1 docs/creds.md "(pw ${V}) for ${E}"
both "with password value, whitespace only, is refused" 1 docs/creds.md "${E} with password ${V}"
both "password reset link prose passes" 0 docs/creds.md "Send ${E} the password reset link"
both "a pure-letter value after password with no separator passes" 0 docs/creds.md "${E} password ${VL}"
both "a mixed value in the 3rd cell under a password header is refused" 1 docs/users.md "| Email | Role | Password |${NL}| --- | --- | --- |${NL}| ${E} | prod | ${V} |"
both "a mixed value in the 3rd cell of a row that has a pwd word is refused" 1 docs/users.md "| ${E} | prod | ${V} | pwd |"
both "a login or Pass column is not a password header" 0 docs/users.md "| User | Last login | Pass |${NL}| ${E} | prod | ${V} |"
both "the same row with no password-ish header or word passes (conservative)" 0 docs/users.md "| ${E} | prod | ${V} |"
both "a table whose header is not password-ish passes" 0 docs/users.md "| Email | Role | Notes |${NL}| ${E} | prod | ${V} |"
both "a paragraph between the header and the row ends the table" 0 docs/users.md "| Email | Role | Password |${NL}${NL}text${NL}| ${E} | prod | ${V} |"
both "a value that starts with / is a path, not a password" 0 docs/users.md "${E} | Admin | Reset password: /auth/v1/recover"
both "a one-line JSON object with a _note marker passes" 0 config/seed.json "{\"email\":\"${E}\",\"password\":\"${V}\",\"_note\":\"credential-ok: local seeded test user\"}"
both "a single quote inside the value does not cut it short" 1 docs/creds.md "${E} password: ${VQ}"
both "a double quote inside the value does not cut it short" 1 docs/creds.md "${E} password: ${VQ2}"
both "passphrase: value is refused" 1 docs/creds.md "${E} passphrase: ${V}"
both "passcode = value is refused" 1 docs/creds.md "${E} passcode = ${V}"
both "a Pass column with a plain word beside an email passes" 0 docs/qa.md "| ${E} | Pass | Redirects to home |"
both "pass = word beside an email passes" 0 docs/qa.md "${E}: pass = Redirected"
both "email:value where the value holds an @ and no host is refused" 1 docs/creds.md "${E}:${VA}"
both "email:value@host is still the url shape" 1 docs/db.md "postgres://${E}:${V}@db.internal.test/app"
both "a value with an @ before the host is cut at the LAST @" 1 docs/db.md "postgres://${E}:${VA}@db.internal.test/app"
DMY="$(printf '%s-%s-%s' Jan 02 2001)"; TS="$(printf '%s-%s-%sT%s:%s:%sZ' 2001 02 03 04 05 06)"     # synthetic dates, built at run time
both "a Mon-DD-YYYY date cell passes" 0 docs/audit.md "| ${E} | ${DMY} |"
both "a Stripe-style prefixed id in the next cell passes" 0 docs/ids.md "| ${E} | cus_Nf8aKz$(rep 2 1)Qw1 |"
both "password: lowercase-plus-digits is refused (strong word, real separator)" 1 docs/creds.md "${E} password: ${VLD}"
both "pw: lowercase-plus-digits stays out (weak word)" 0 docs/creds.md "${E} pw: ${VLD}"
both "a secret NAME (E2E_PASSWORD_2) after password: is a placeholder" 0 docs/creds.md "${E} password: E2E_""PASSWORD_2"
both "| email | PASS | Build-42a | passes (a PASS cell is not a password word)" 0 docs/qa.md "| ${E} | PASS | Build-42a |"
both "Credentials: 1Password/Ops passes (a word-like value)" 0 docs/creds.md "${E} Credentials: 1Password/Ops"
both "email | 10:30AM-Mon passes (a time)" 0 docs/sched.md "| ${E} | 10:30AM-Mon |"
both "email: 10:30AM-Mon passes (a time)" 0 docs/sched.md "${E}: 10:30AM-Mon"
both "a uuid in the next cell passes" 0 docs/ids.md "| ${E} | 550e8400-e29b-41d4-a716-446655440000 |"
both "a timestamp in the next cell passes" 0 docs/ids.md "| ${E} | ${TS} |"
both "a .ts file is out of scope" 0 src/seed.ts "const row = ['${E}', '${V}']; // password: ${V}"
both "a .sql file is out of scope" 0 db/seed.sql "insert into u values ('${E}', '${V}'); -- password: ${V}"
both "package-lock.json is out of scope" 0 package-lock.json "{\"email\":\"${E}\",\"password\":\"${V}\"}"
both "a file under node_modules is out of scope" 0 node_modules/x/doc.md "${E} / ${V}"

# ---- the allowlist marker -----------------------------------------------------------------------------------------
newrepo marker; mkdir docs; printf '%s\n' "${E} / ${V} <!-- credential-ok: local seeded test user -->" > docs/m.md
git add -A; scan --staged
want_rc "a credential-ok line with a 3-word reason passes" 0
want_out "and the skip is printed with path, line and reason" '^docs/m.md:1: allowed: local seeded test user$'
want_out "and the skip is counted" '1 allowed'
newrepo marker2; mkdir docs; printf '%s\n' "${E} / ${V} <!-- credential-ok: local only -->" > docs/m.md; git add -A; scan --staged
want_rc "a credential-ok marker with a 2-word reason still blocks" 1
newrepo marker3; mkdir docs; printf '%s\n' "${E} / ${V} <!-- credential-ok: the seeded value ${V} is fine -->" > docs/m.md; git add -A; scan --staged
want_rc "a marker whose reason carries the value passes but withholds the reason" 0
want_out "and the reason is withheld in the output" 'allowed: reason withheld'
newrepo marker4; mkdir docs; printf '%s\n' "Nothing secret here credential-ok: just a plain note" > docs/m.md; git add -A; scan --staged
want_rc "a marker on a line with no hit is neutral" 0
grep -q ': allowed: ' "$OUT" && fail "a marker on a clean line is not counted" "it was printed as allowed" || pass "a marker on a clean line is not counted"

newrepo ann; mkdir docs; printf '%s\n' "${E} / ${V} <!-- credential-ok: local seeded test user -->" > docs/m.md; git add -A
GITHUB_ACTIONS=true scan --staged
want_out "in CI an allowed line is a ::warning annotation with path and line" '^::warning file=docs/m.md,line=1::doc-credential-scan: allowed by a credential-ok marker (local seeded test user)'
GITHUB_ACTIONS=false scan --staged                      # CI exports GITHUB_ACTIONS=true; force it off here
grep -q '^::warning' "$OUT" && fail "no annotation outside CI" "printed" || pass "no annotation outside CI"
newrepo jsonmk; mkdir config; printf '%s\n' "{\"email\":\"${E}\",\"password\":\"${V}\",\"_note\":\"credential-ok: local seeded test user\"}" > config/seed.json; git add -A; scan --staged
want_out "a JSON marker reason stops at the closing quote" '^config/seed.json:1: allowed: local seeded test user$'
newrepo apos; mkdir docs; printf '%s\n' "${E} / ${V} <!-- credential-ok: it's a local test user -->" > docs/m.md; git add -A; scan --staged
want_out "an apostrophe inside a reason does not cut it short" "^docs/m.md:1: allowed: it's a local test user\$"
newrepo dotted; mkdir docs; printf '%s\n' "${E} / ${V} <!-- credential-ok: ask fixture.person for access -->" > docs/m.md; git add -A; scan --staged
want_out "a reason with a dotted name (email local part shape) is withheld" 'allowed: reason withheld$'
newrepo dotted2; mkdir docs; printf '%s\n' "${E} / ${V} <!-- credential-ok: ask ${LOCALPART} for access -->" > docs/m.md; git add -A; scan --staged
want_out "a reason carrying the address local part is withheld" 'allowed: reason withheld$'

# ---- only ADDED lines count ----------------------------------------------------------------------------------------
newrepo removed; mkdir docs; printf '%s\n' "line one" "${E} / ${V}" "line three" > docs/r.md; commit_all seed
printf '%s\n' "line one" "line three" > docs/r.md; git add -A
scan --staged; want_rc "a REMOVED line with a hit does not block (staged)" 0
commit_all drop; scan --range HEAD~1..HEAD; want_rc "a REMOVED line with a hit does not block (range)" 0
newrepo context; mkdir docs; printf '%s\n' "line one" "${E} / ${V}" "line three" > docs/c.md; commit_all seed
printf '%s\n' "line ONE" "${E} / ${V}" "line three" > docs/c.md; git add -A
scan --staged; want_rc "an unchanged context line with a hit does not block (staged)" 0
commit_all edit; scan --range HEAD~1..HEAD; want_rc "an unchanged context line with a hit does not block (range)" 0
newrepo moved; mkdir docs; printf '%s\n' "${E} / ${V}" > docs/old.md; commit_all seed; git mv docs/old.md docs/new.md >/dev/null 2>&1; git add -A
scan --staged; want_rc "a pre-existing hit in a renamed file counts as added (staged)" 1

newrepo untouched; mkdir docs; printf '%s\n' "${E} / ${V}" > docs/old.md; commit_all seed
printf '%s\n' "a clean line" > docs/new.md; git add -A
scan --staged; want_rc "a pre-existing hit in an untouched file does not block (staged)" 0
commit_all clean; scan --range HEAD~1..HEAD; want_rc "a pre-existing hit in an untouched file does not block (range)" 0
scan --all; want_rc "--all exits 0 even with a hit in the tree" 0
want_out "--all counts the pre-existing hit per file" '^docs/old.md: 1 hit(s), 0 allowed$'
want_out "--all says hits never fail it and only an unreadable file exits 2" 'exit 2 only when a file cannot be read'
want_out "--all prints a total" '^total: 1 hit(s) in 1 file(s)'
newrepo allclean; mkdir docs; printf '%s\n' "${E} contact" > docs/ok.md; commit_all seed; scan --all
want_rc "--all on a clean tree exits 0" 0
want_out "--all on a clean tree reports zero" '^total: 0 hit(s) in 0 file(s)'

# ---- usage, bad input, and the "could not look" exit ---------------------------------------------------------------
newrepo usage; scan; want_rc "no mode is a usage error (exit 2)" 2
scan --range; want_rc "--range with no value is exit 2" 2
scan --range nonexistent-ref..HEAD; want_rc "a bad range (unknown base) exits 2" 2
scan --range HEAD; want_rc "a range with no .. exits 2" 2
scan --range "..HEAD"; want_rc "a range with an empty base exits 2" 2
scan --range "--output=x..HEAD"; want_rc "a range that looks like an option exits 2" 2
scan --staged --all; want_rc "two modes at once is exit 2" 2
NOREPO="$T/not-a-repo"; mkdir -p "$NOREPO"; cd "$NOREPO" || exit 2
GIT_CEILING_DIRECTORIES="$T" scan --staged; want_rc "outside a git work tree exits 2 (never clean)" 2

# ---- a failing detector is exit 2, never clean; a busybox awk host still catches the login-line shape -----------------------
newrepo awkfail; mkdir docs; printf '%s\n' "${E} / ${V}" > docs/x.md; git add -A
AWKBIN="$T/awk-fail-bin"; mkdir -p "$AWKBIN"; printf '#!/bin/sh\nexit 1\n' > "$AWKBIN/awk"; chmod +x "$AWKBIN/awk"
PATH="$AWKBIN:$PATH" scan --staged; want_rc "a failing awk is exit 2 (a scan that could not look is never clean)" 2
if command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN { exit 0 }' >/dev/null 2>&1; then
  BBBIN="$T/bb-bin"; mkdir -p "$BBBIN"; ln -s "$(command -v busybox)" "$BBBIN/awk"
  newrepo bbawk; mkdir docs; printf '%s\n' "- prod login: \`${E}\` / \`${V}\`" "${E} password is \`${V}\`" > docs/x.md; git add -A
  PATH="$BBBIN:$PATH" scan --staged; want_rc "busybox awk: the login-line shape is refused" 1
else
  printf 'SKIP busybox awk not available on this host\n'
fi

# ---- the output never carries what it found --------------------------------------------------------------------------
for secret in "$E" "$LOCALPART" "acme-demo" "$V" "$VL" "$V2" "$VD" "$VC" "$VA" "$VAT" "$VQ" "$VQ2" "fixture.person"; do
  if grep -qF -- "$secret" "$ALL"; then fail "output never contains a fixture email or value" "a fixture string appeared in the scanner output"; else pass "output never contains a fixture string (${#secret} chars checked)"; fi
done
grep -q '^docs/login.md:1: email-value-pair$' "$ALL" && pass "the output names path, line and rule" || fail "path:line:rule" "the expected shape was not seen"

printf -- '---- passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
