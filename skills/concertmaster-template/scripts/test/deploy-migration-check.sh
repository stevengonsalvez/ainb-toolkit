#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # "A && ok || bad": ok never fails
# deploy-migration-check.sh test: every case builds its own throwaway git repo in a mktemp dir (a base commit with one old
# migration, then the files under test added in a second commit) and runs the real script against base..HEAD. Fixture SQL is
# assembled at run time from split strings, so no file of this repo holds a literal migration guard line.
# Asserts: 3s/30s ok; 5s/120s ask; 120s statement only ask; a missing timeout ask; 3000ms/30000ms and bare-millisecond forms
# ok; no BEGIN/COMMIT stop; BEGIN without COMMIT stop; a flagged file with a timeout-exception reason of 3+ words reports
# exception and exits 0; a 2-word reason is still ask; an exception never covers a stop; a modified old file is ignored; a
# renamed file counts as added; stop outranks ask in the exit code; a bad range, a bad option and an unreadable PR body
# file exit 1; no added file exits 0; no SQL body text appears in the output; block comments never carry a guard; a plain
# SET/RESET of a timeout is an ask; --only scopes a run; a swapped range and a quoted path exit 1; a placeholder reason is no exception.
#
#   scripts/test/deploy-migration-check.sh     # exit 0 when every case passes
#   CM_DMC_SCRIPT=<path> scripts/test/deploy-migration-check.sh   # run against a copy (mutation checks)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${CM_DMC_SCRIPT:-$HERE/../deploy-migration-check.sh}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-dmc-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export HOME="$ROOT/home" CM_HOME="$ROOT/home" CM_CONFIG=/nonexistent
mkdir -p "$HOME"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$3' got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }

# fixture text, built from pieces
SL="SET ""LOCAL"; LK="lock_""timeout"; ST="statement_""timeout"; BG="BEG""IN;"; CM="COM""MIT;"
MARK="probe_marker_""table"                  # a word the output must never echo
guard() { printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT 1 FROM %s;\n%s\n' "$BG" "$SL" "$LK" "$1" "$SL" "$ST" "$2" "$MARK" "$CM"; }

# gx <lock> <stmt> <extra>: a guarded window with <extra> text inside it, before the COMMIT
gx() { printf '%s\n%s %s = %s;\n%s %s = %s;\n%s\n%s\n' "$BG" "$SL" "$LK" "$1" "$SL" "$ST" "$2" "$3" "$CM"; }

N=0
git_q() { git -c commit.gpgsign=false -c tag.gpgsign=false -c user.name=t -c user.email=t@example.invalid "$@"; }
# newrepo: sets D to a fresh repo whose first commit holds one old migration; BASE is that commit
newrepo() {
  N=$((N + 1)); D="$ROOT/r$N"; mkdir -p "$D/supabase/migrations"
  ( cd "$D" && git init -q . && printf -- '-- old\n' > supabase/migrations/88000000000001_old.sql \
    && git add supabase && git_q commit -q -m base ) >/dev/null
  BASE="$(git -C "$D" rev-parse HEAD)"
}
# addmig <file> <content>: write a new migration and commit it
addmig() { printf '%s\n' "$2" > "$D/supabase/migrations/$1"; ( cd "$D" && git add supabase && git_q commit -q -m "add $1" ) >/dev/null; }
# run [args...]: runs the script in $D over BASE..HEAD, sets OUT and RC
run() { OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" HEAD "$@" 2>&1)"; RC=$?; }
F1=supabase/migrations/88000000000002_a.sql
F2=supabase/migrations/88000000000003_b.sql

# 1. ok
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; run
check "3s/30s: exit 0" "$RC" 0; has "3s/30s: reported ok" "$OUT" "ok $F1 lock_timeout=3s statement_timeout=30s"

# 2. both wrong
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"; run
check "5s/120s: exit 2" "$RC" 2; has "5s/120s: reported ask with both found values" "$OUT" "ask $F1 lock_timeout=5s statement_timeout=120s exception=none"

# 3. statement only
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'120s'")"; run
check "120s statement only: exit 2" "$RC" 2; has "120s statement only: ask, lock value shown as found" "$OUT" "ask $F1 lock_timeout=3s statement_timeout=120s"

# 3b. lock only
newrepo; addmig 88000000000002_a.sql "$(guard "'10s'" "'30s'")"; run
check "10s lock only: exit 2" "$RC" 2; has "10s lock only: ask" "$OUT" "ask $F1 lock_timeout=10s statement_timeout=30s"

newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'30s'")"; run
check "5s lock only: exit 2" "$RC" 2; has "5s lock only: ask" "$OUT" "ask $F1 lock_timeout=5s statement_timeout=30s"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s -- tight\n;\n%s %s = %s; -- fine\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "a trailing comment after the value does not change it: exit 0" "$RC" 0

# 4. a missing timeout
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s %s;\nSELECT 1;\n%s' "$BG" "$SL" "$LK" "'3s'" "$CM")"; run
check "statement_timeout missing: exit 2" "$RC" 2; has "statement_timeout missing: ask, shown as missing" "$OUT" "ask $F1 lock_timeout=3s statement_timeout=missing"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s %s;\nSELECT 1;\n%s' "$BG" "$SL" "$ST" "'30s'" "$CM")"; run
check "lock_timeout missing: exit 2" "$RC" 2; has "lock_timeout missing: ask, shown as missing" "$OUT" "ask $F1 lock_timeout=missing statement_timeout=30s"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\nSELECT 1;\n%s' "$BG" "$CM")"; run
check "both timeouts missing: exit 2" "$RC" 2; has "both timeouts missing: ask" "$OUT" "ask $F1 lock_timeout=missing statement_timeout=missing"

# 5. equal forms
newrepo; addmig 88000000000002_a.sql "$(guard "'3000ms'" "'30000ms'")"; run
check "3000ms/30000ms: exit 0" "$RC" 0; has "3000ms/30000ms: ok" "$OUT" "ok $F1"
newrepo; addmig 88000000000002_a.sql "$(guard "3000" "30000")"; run
check "bare 3000/30000: exit 0" "$RC" 0; has "bare 3000/30000: ok" "$OUT" "ok $F1"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s %s TO %s;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "= and TO spellings: exit 0" "$RC" 0; has "= and TO spellings: ok" "$OUT" "ok $F1"
newrepo; addmig 88000000000002_a.sql "$(guard "'0'" "'30s'")"; run
check "lock_timeout 0 (no limit) is not accepted: exit 2" "$RC" 2

# 6. no BEGIN and no COMMIT
newrepo; addmig 88000000000002_a.sql "$(printf '%s %s %s;\n%s %s %s;\nSELECT 1;' "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'")"; run
check "no BEGIN/COMMIT: exit 3" "$RC" 3; has "no BEGIN/COMMIT: stop line" "$OUT" "stop $F1 reason=no BEGIN; and COMMIT;"
has "no BEGIN/COMMIT: the stop note forbids editing an applied file" "$OUT" "do NOT edit the file"
has "no BEGIN/COMMIT: the stop note names connection-level timeouts on the push step" "$OUT" "connection-level timeouts on the push step"
has "no BEGIN/COMMIT: the stop note gives the reason (tracked by name, edit skipped)" "$OUT" "tracks applied files by name and silently skips an edited one"

# 7. BEGIN without COMMIT, and COMMIT without BEGIN
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s %s;\n%s %s %s;\nSELECT 1;' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'")"; run
check "BEGIN without COMMIT: exit 3" "$RC" 3; has "BEGIN without COMMIT: stop line names COMMIT" "$OUT" "stop $F1 reason=no COMMIT;"
newrepo; addmig 88000000000002_a.sql "$(printf '%s %s %s;\n%s %s %s;\nSELECT 1;\n%s' "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "COMMIT without BEGIN: exit 3" "$RC" 3; has "COMMIT without BEGIN: stop line names BEGIN" "$OUT" "stop $F1 reason=no BEGIN;"
newrepo; addmig 88000000000002_a.sql "$(printf -- '-- %s\n%s %s %s;\n%s %s %s;\nSELECT 1;\n-- %s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "BEGIN and COMMIT only in comments: exit 3" "$RC" 3

# 8. exception recorded with a reason of 3+ words
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"
printf 'Summary\n\ntimeout-exception: long backfill approved by owner\n' > "$ROOT/body.md"; run --pr-body-file "$ROOT/body.md" --only "$F1"
check "exception with a 5-word reason: exit 0" "$RC" 0; has "exception: reported exception with the found values" "$OUT" "exception $F1 lock_timeout=5s statement_timeout=120s exception=recorded"
printf 'timeout-exception: three word reason\r\n' > "$ROOT/body3.md"; run --pr-body-file "$ROOT/body3.md" --only "$F1"
check "exception with exactly 3 words (CRLF body): exit 0" "$RC" 0
printf 'timeout-exception: owner approved \r\n' > "$ROOT/bodycr.md"; run --pr-body-file "$ROOT/bodycr.md" --only "$F1"
check "2 words plus a CR is still 2 words: exit 2" "$RC" 2

# 9. a 2-word reason, a bare marker, an indented marker: still ask
printf 'timeout-exception: owner approved\n' > "$ROOT/body2.md"; run --pr-body-file "$ROOT/body2.md" --only "$F1"
check "2-word reason: exit 2" "$RC" 2; has "2-word reason: still ask, exception=none" "$OUT" "ask $F1 lock_timeout=5s statement_timeout=120s exception=none"
printf 'timeout-exception:\n' > "$ROOT/body0.md"; run --pr-body-file "$ROOT/body0.md" --only "$F1"
check "marker with no reason: exit 2" "$RC" 2
printf '  timeout-exception: long backfill approved by owner\nnote timeout-exception: long backfill approved by owner\n' > "$ROOT/bodyi.md"; run --pr-body-file "$ROOT/bodyi.md" --only "$F1"
check "marker not at the start of a line: exit 2" "$RC" 2

# 10. an exception never covers a stop
newrepo; addmig 88000000000002_a.sql "$(printf 'SELECT 1;')"; run --pr-body-file "$ROOT/body.md" --only "$F1"
check "exception does not cover a stop: exit 3" "$RC" 3; has "exception does not cover a stop: stop line" "$OUT" "stop $F1"

# 11. a modified old file is ignored; a rename is an added file
newrepo; printf 'SELECT 1;\n' > "$D/supabase/migrations/88000000000001_old.sql"
( cd "$D" && git add supabase && git_q commit -q -m modify ) >/dev/null; run
check "modified old file with no guard: exit 0" "$RC" 0; hasnt "modified old file is not listed" "$OUT" "88000000000001_old.sql"
has "modified old file: nothing added" "$OUT" "ok=0 exception=0 ask=0 stop=0"
newrepo; ( cd "$D" && git mv supabase/migrations/88000000000001_old.sql supabase/migrations/88000000000004_old.sql && git_q commit -q -m rename ) >/dev/null; run
check "renamed file with no guard counts as added: exit 3" "$RC" 3; has "renamed file is listed under its new name" "$OUT" "stop supabase/migrations/88000000000004_old.sql"

# 12. stop outranks ask
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"; addmig 88000000000003_b.sql "$(printf 'SELECT 1;')"; run
check "one ask and one stop: exit 3" "$RC" 3
has "one ask and one stop: ask line printed" "$OUT" "ask $F1"; has "one ask and one stop: stop line printed" "$OUT" "stop $F2"
has "summary counts both" "$OUT" "ok=0 exception=0 ask=1 stop=1"
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; addmig 88000000000003_b.sql "$(guard "'5s'" "'120s'")"; run
check "one ok and one ask: exit 2" "$RC" 2; has "one ok and one ask: ok line" "$OUT" "ok $F1"; has "one ok and one ask: ask line" "$OUT" "ask $F2"

# 13. bad input
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'30s'")"
OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" no-such-ref 2>&1)"; RC=$?
check "bad to-ref: exit 1" "$RC" 1; has "bad to-ref: names the ref" "$OUT" "bad ref: no-such-ref"
OUT="$(cd "$D" && bash "$SCRIPT" no-such-ref HEAD 2>&1)"; RC=$?
check "bad from-ref: exit 1" "$RC" 1
OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" 2>&1)"; RC=$?
check "one argument: exit 1" "$RC" 1
OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" HEAD --nope 2>&1)"; RC=$?
check "unknown option: exit 1" "$RC" 1
run --pr-body-file "$ROOT/no-such-body.md" --only "$F1"
check "unreadable PR body file: exit 1" "$RC" 1
OUT="$(cd "$ROOT" && bash "$SCRIPT" a b 2>&1)"; RC=$?
check "outside a git repository: exit 1" "$RC" 1; has "outside a git repository: says so" "$OUT" "not inside a git repository"
OUT="$(bash "$SCRIPT" --help 2>&1)"; RC=$?
check "--help: exit 0" "$RC" 0; has "--help prints the exit codes" "$OUT" "Exit: 0 every file ok"

# 14. nothing added
newrepo; ( cd "$D" && git_q commit -q --allow-empty -m empty ) >/dev/null; run
check "no added migration: exit 0" "$RC" 0; has "no added migration: summary says zero" "$OUT" "ok=0 exception=0 ask=0 stop=0"
newrepo; mkdir -p "$D/supabase/migrations/nested"; printf 'SELECT 1;\n' > "$D/supabase/migrations/nested/x.sql"; printf 'x\n' > "$D/supabase/migrations/README.md"
( cd "$D" && git add supabase && git_q commit -q -m extra ) >/dev/null; run
check "a nested .sql and a non-sql file are not delta migrations: exit 0" "$RC" 0

# 15. no SQL body in the output
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"; addmig 88000000000003_b.sql "$(printf 'SELECT * FROM %s;\nDROP TABLE %s;' "$MARK" "$MARK")"
run --pr-body-file "$ROOT/body.md" --only "$F1" --only "$F2"
hasnt "no SQL body text in the output (ask, exception and stop files)" "$OUT" "$MARK"; hasnt "no SELECT in the output" "$OUT" "SELECT"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s %s;\n%s %s %s;\n%s' "$BG" "$SL" "$LK" "'3s' || $MARK" "$SL" "$ST" "'30s'" "$CM")"; run
check "a value that is not a plain token: exit 2" "$RC" 2; has "an odd value prints as unparsed" "$OUT" "lock_timeout=<unparsed>"
hasnt "an odd value never echoes the SQL text" "$OUT" "$MARK"
newrepo; addmig 88000000000002_a.sql "$(guard "'x|y'" "'30s'")"; run
has "a short odd value prints as unparsed" "$OUT" "lock_timeout=<unparsed>"; hasnt "a short odd value is never echoed" "$OUT" "x|y"

# 16. comments: a guard written only inside a block comment does not count; a bad value inside one does not either
newrepo; addmig 88000000000002_a.sql "$(printf '/*\n%s\n%s %s = %s;\n%s %s = %s;\n%s\n*/\nSELECT 1;' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "guard only inside a block comment: exit 3" "$RC" 3; has "guard only inside a block comment: stop" "$OUT" "stop $F1"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n/* %s %s = %s; */\n%s %s = %s; /* tight */\n%s %s = %s;\n%s' "$BG" "$SL" "$LK" "'99s'" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "a bad value inside a block comment and a mid-line comment: exit 0" "$RC" 0; has "block comments are ignored for the values" "$OUT" "ok $F1 lock_timeout=3s statement_timeout=30s"

# 17. plain SET or RESET of a timeout overrides the guard
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'SET %s = 0;\n' "$ST")")"; run
check "a plain SET statement_timeout after the guard: exit 2" "$RC" 2; has "plain SET: ask, shown as override" "$OUT" "ask $F1 lock_timeout=3s statement_timeout=30s,override"
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'RESET %s;\n' "$LK")")"; run
check "a RESET lock_timeout after the guard: exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'RESET ALL;\n')")"; run
check "RESET ALL after the guard: exit 2" "$RC" 2

# 18. --only scopes a run to the named files (exception per PR)
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"; addmig 88000000000003_b.sql "$(guard "'0'" "'0'")"
run --pr-body-file "$ROOT/body.md" --only "$F1"
check "--only on one of two flagged files: exit 0" "$RC" 0; has "--only: the named file is excepted" "$OUT" "exception $F1"; hasnt "--only: the other file is not examined" "$OUT" "$F2"
run --pr-body-file "$ROOT/body.md" --only "$F2" --only "$F1"
has "--only twice: both files examined" "$OUT" "exception $F2"; has "--only twice: the first file too" "$OUT" "exception $F1"
run --only "$F2"
check "--only without a body: the file stays an ask, exit 2" "$RC" 2; hasnt "--only without a body: the other file is not examined" "$OUT" "$F1"
run --only "supabase/migrations/88000000000003_b.sql.x"
check "--only naming a file that is not in the range: exit 1, never a silent pass" "$RC" 1; has "--only naming nothing: says which path" "$OUT" "--only path is not an added migration"
run --only "./$F2"
check "--only with a ./ prefix: exit 1" "$RC" 1
run --only "$F2 "
check "--only with a trailing space: exit 1" "$RC" 1
run --only "$F2" --only "supabase/migrations/nope.sql"
check "--only with one match and one typo: exit 1" "$RC" 1
OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" HEAD --only '' 2>&1)"; RC=$?
check "--only with an empty path: exit 1" "$RC" 1
OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" HEAD --only 2>&1)"; RC=$?
check "--only with no path: exit 1" "$RC" 1

# 19. the range must run from an ancestor to a descendant
newrepo; addmig 88000000000002_a.sql "$(printf 'SELECT 1;')"
OUT="$(cd "$D" && bash "$SCRIPT" HEAD "$BASE" 2>&1)"; RC=$?
check "swapped range: exit 1" "$RC" 1; has "swapped range: says not an ancestor" "$OUT" "is not an ancestor of"

# 20. paths: a non-ASCII name is read, a name git prints quoted is refused
newrepo; addmig "88000000000002_caf$(printf '\303\251').sql" "$(printf 'SELECT 1;')"; run
check "a non-ASCII file name with no guard: exit 3" "$RC" 3; has "a non-ASCII file name is listed as written" "$OUT" "stop supabase/migrations/88000000000002_caf$(printf '\303\251').sql"
newrepo; addmig '88000000000002_q"x.sql' "$(printf 'SELECT 1;')"; run
check "a file name git prints quoted: exit 1, not silently skipped" "$RC" 1

# 21. a placeholder reason is not a recorded exception
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"
printf 'timeout-exception: <reason of three words>\n' > "$ROOT/bodyph.md"; run --pr-body-file "$ROOT/bodyph.md" --only "$F1"
check "a template placeholder reason: exit 2" "$RC" 2

# 22. one statement per line: a second statement on a line, a split statement and a quoted key are all read
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'SELECT 1; SET %s = 0;\n' "$ST")")"; run
check "a second statement on one line overrides the guard: exit 2" "$RC" 2; has "same-line SET: ask, shown as override" "$OUT" "override"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s; %s %s = %s;\n%s %s = %s;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$LK" "'0'" "$SL" "$ST" "'30s'" "$CM")"; run
check "two SET LOCAL lock_timeout on one line, the second bad: exit 2" "$RC" 2; has "both values are read" "$OUT" "lock_timeout=3s,0"
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'SET\n  %s = 0;\n' "$ST")")"; run
check "a SET split over two lines: exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'SET "%s" = 0;\n' "$ST")")"; run
check "a quoted key: exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'ALTER ROLE authenticated\n  SET %s = %s;\n' "$ST" "'8s'")")"; run
check "ALTER ROLE ... SET on two lines is not an override: exit 0" "$RC" 0
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT %s;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "'[a-z0-9+.(),:/*_-]+'" "$CM")"; run
check "a /* inside a quoted string is text: exit 0" "$RC" 0; has "a /* inside a quoted string: ok" "$OUT" "ok $F1"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT %s;\nSET %s = 0;\nSELECT %s;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "'a/*'" "$ST" "'*/'" "$CM")"; run
check "quotes hiding a SET between two fake comment marks: exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n/* old /* nested */ still a comment\n%s %s = %s;\n%s %s = %s;\n*/\nSELECT 1;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "a guard inside a nested block comment does not count: exit 2" "$RC" 2; has "nested comment: both timeouts missing" "$OUT" "lock_timeout=missing statement_timeout=missing"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nCREATE FUNCTION f() RETURNS void LANGUAGE plpgsql AS $$\nBEGIN\nPERFORM 1;\n%s\nEND $$;' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "a COMMIT inside a dollar-quoted body is not the file's COMMIT: exit 3" "$RC" 3; has "dollar-quoted COMMIT: stop names COMMIT" "$OUT" "stop $F1 reason=no COMMIT;"

# 23. E'..' escape strings, identifier-adjacent $, odd whitespace, a final COMMIT with no semicolon, a very large statement
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nCOMMENT ON TABLE t IS E%s;\nSET %s = 0; -- do%st remove\nSELECT 1;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "'Customer\\'s table'" "$ST" "'" "$CM")"; run
check "an E'..' string with an escaped quote does not hide a later SET: exit 2" "$RC" 2; has "E string: the override is seen" "$OUT" "override"
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'SELECT %s;\nSET %s = 0;\nSELECT %s;\n' "'C:\\'" "$ST" "'x'")")"; run
check "a standard string ending in a backslash closes at the quote: exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'CREATE TABLE t$x$ (id int); SET %s = 0; CREATE TABLE u$x$ (id int);\n' "$ST")")"; run
check "t\$x\$ is an identifier, not a dollar quote: exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'SET\f%s = 0;\n' "$ST")")"; run
check "a form feed between SET and the key: exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT 1;\nCOMMIT' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'")"; run
check "a final COMMIT without a semicolon is still a COMMIT: exit 0" "$RC" 0
newrepo; { printf '%s\n%s %s = %s;\n%s %s = %s;\nINSERT INTO t VALUES\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'"; awk 'BEGIN { for (i = 0; i < 20000; i++) printf "(%d, \047row %d\047, \047it\047\047s\047),\n", i, i; print "(0, \047z\047, \047z\047);" }'; printf '%s\n' "$CM"; } > "$D/supabase/migrations/88000000000002_a.sql"
( cd "$D" && git add supabase && git_q commit -q -m big ) >/dev/null
OUT="$(cd "$D" && timeout 60 bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
check "a 1 MB single INSERT is read in time and is ok: exit 0" "$RC" 0; has "the big file is ok" "$OUT" "ok $F1"
# the same file under each other awk this host has: mawk and busybox awk are quadratic on a statement that is kept whole
for other in mawk busybox; do
  command -v "$other" >/dev/null 2>&1 || { echo "skip the 1 MB file under $other: not installed"; continue; }
  mkdir -p "$ROOT/awk-$other"
  if [ "$other" = busybox ]; then printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$ROOT/awk-$other/awk"; else printf '#!/bin/sh\nexec %s "$@"\n' "$other" > "$ROOT/awk-$other/awk"; fi
  chmod +x "$ROOT/awk-$other/awk"
  OUT="$(cd "$D" && PATH="$ROOT/awk-$other:$PATH" timeout 20 bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
  check "a 1 MB single INSERT under $other awk finishes in 20 s and is ok: exit 0" "$RC" 0
done

# 24. whitespace never counts toward the statement cap: 500 indented comment lines before a SET change nothing
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(awk 'BEGIN { for (i = 0; i < 700; i++) print "        -- previous version kept for reference" }'; printf 'SET %s = 0;\n' "$ST")")"; run
check "700 indented comment lines before a plain SET: still an ask, exit 2" "$RC" 2; has "padded SET: override seen" "$OUT" "override"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n' "$BG"; awk 'BEGIN { for (i = 0; i < 500; i++) print "        -- old" }'; printf '%s %s = %s;\n%s %s = %s;\nSELECT 1;\n%s\n' "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "a good guard after 500 comment lines is still read: exit 0" "$RC" 0
newrepo; addmig 88000000000002_a.sql "$(gx "'3s'" "'30s'" "$(printf 'SET\n'; awk 'BEGIN { for (i = 0; i < 4200; i++) print "" }'; printf '%s = 0;\n' "$ST")")"; run
check "a SET padded with 4200 blank lines: exit 2" "$RC" 2

# 25. the guard comes first in the window
newrepo; addmig 88000000000002_a.sql "$(printf '%s\nALTER TABLE t ADD COLUMN c int;\n%s %s = %s;\n%s %s = %s;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "DDL before the guard inside the window: exit 2" "$RC" 2; has "DDL before the guard: guard=late" "$OUT" "statement_timeout=30s guard=late exception=none"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\nALTER TABLE t ADD COLUMN c int;\n%s %s = %s;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "DDL between the two timeouts: exit 2" "$RC" 2; has "DDL between the timeouts: guard=late" "$OUT" "guard=late"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\nSET LOCAL search_path = public;\n%s %s = %s;\n%s %s = %s;\nSELECT 1;\n%s' "$BG" "$SL" "$ST" "'30s'" "$SL" "$LK" "'3s'" "$CM")"; run
check "a SET before the guard, statement_timeout first: exit 0" "$RC" 0
newrepo; addmig 88000000000002_a.sql "$(printf 'CREATE EXTENSION IF NOT EXISTS x;\n%s\n%s %s = %s;\n%s %s = %s;\nSELECT 1;\n%s' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"; run
check "a statement before BEGIN (outside the window) is a shape stop: exit 3" "$RC" 3; has "a statement before BEGIN: stop names it" "$OUT" "stop $F1 reason=shape: statement before BEGIN"

# 26. a single line of ~900 KB under every awk the host has (the scan must not copy the rest of the line)
newrepo; { printf '%s\n%s %s = %s;\n%s %s = %s;\nINSERT INTO t VALUES ' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'"; awk 'BEGIN { for (i = 0; i < 60000; i++) printf "(%d,\047r\047),", i; print "(0,\047z\047);" }'; printf '%s\n' "$CM"; } > "$D/supabase/migrations/88000000000002_a.sql"
( cd "$D" && git add supabase && git_q commit -q -m oneline ) >/dev/null
OUT="$(cd "$D" && timeout 30 bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
check "a ~900 KB single-line INSERT under the default awk finishes in 30 s: exit 0" "$RC" 0
for other in mawk busybox; do
  [ -x "$ROOT/awk-$other/awk" ] || { echo "skip the single-line file under $other: not installed"; continue; }
  OUT="$(cd "$D" && PATH="$ROOT/awk-$other:$PATH" timeout 30 bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
  check "a ~900 KB single-line INSERT under $other awk finishes in 30 s: exit 0" "$RC" 0
done

# 27. tokens that straddle the 2048-character scan window are read the same at every offset
mkpad() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "a" }'; }
newrepo; for off in $(seq 2030 2070); do
  printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT %s%s;\nSET %s = 0;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "'$(mkpad "$off")''b'" "" "$ST" "$CM" > "$D/supabase/migrations/8800000000$(printf '%04d' "$off")_q.sql"
done
( cd "$D" && git add supabase && git_q commit -q -m straddle1 ) >/dev/null; run
check "a doubled quote at every offset around the window edge: all 41 files seen as ask" "$(printf '%s\n' "$OUT" | grep -c '^ask .*override')" 41
newrepo; for off in $(seq 2030 2070); do
  printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT 1 %s /* ; SET %s = 0; */;\nSELECT 2;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$(mkpad "$off")" "$ST" "$CM" > "$D/supabase/migrations/8800000000$(printf '%04d' "$off")_c.sql"
done
( cd "$D" && git add supabase && git_q commit -q -m straddle2 ) >/dev/null; run
check "a block comment opening at every offset around the window edge: all 41 files ok" "$(printf '%s\n' "$OUT" | grep -c '^ok ')" 41
newrepo; for off in $(seq 2030 2070); do
  printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT %s -- ; SET %s = 0;\nSELECT 2;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$(mkpad "$off")" "$ST" "$CM" > "$D/supabase/migrations/8800000000$(printf '%04d' "$off")_d.sql"
done
( cd "$D" && git add supabase && git_q commit -q -m straddle3 ) >/dev/null; run
check "a line comment starting at every offset around the window edge: all 41 files ok" "$(printf '%s\n' "$OUT" | grep -c '^ok ')" 41
newrepo; for off in $(seq 2030 2070); do
  printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT 1 %s $abc$ ; ROLLBACK; $abc$;\nSELECT 2;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$(mkpad "$off")" "$CM" > "$D/supabase/migrations/8800000000$(printf '%04d' "$off")_e.sql"
done
( cd "$D" && git add supabase && git_q commit -q -m straddle4 ) >/dev/null; run
check "a dollar quote opening at every offset around the window edge: all 41 files ok" "$(printf '%s\n' "$OUT" | grep -c '^ok ')" 41
newrepo; for off in $(seq 2030 2070); do
  printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT E%s ; SET %s = 0; SELECT 1; -- %s;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "'$(mkpad "$off")''x\\'y'" "$ST" "'" "$CM" > "$D/supabase/migrations/8800000000$(printf '%04d' "$off")_f.sql"
done
( cd "$D" && git add supabase && git_q commit -q -m straddle5 ) >/dev/null; run
check "an E string with a doubled quote and an escaped quote at every offset around the window edge: all 41 files seen as ask" "$(printf '%s\n' "$OUT" | grep -c '^ask .*override')" 41

# 28. item 1: the listing is anchored at the repo top, so a subdirectory gives the same answer; the examined count is always printed
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"; addmig 88000000000003_b.sql "$(guard "'3s'" "'30s'")"
run; ROOT_OUT="$OUT"; ROOT_RC="$RC"
check "from the repo root: exit 2 and two files" "$ROOT_RC" 2; has "from the repo root: the examined count is printed" "$ROOT_OUT" "2 migration files examined"
for sub in supabase supabase/migrations; do
  OUT="$(cd "$D/$sub" && bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
  check "from $sub: the same exit code as the root" "$RC" "$ROOT_RC"; check "from $sub: the same output as the root" "$OUT" "$ROOT_OUT"
done
mkdir -p "$D/elsewhere"; OUT="$(cd "$D/elsewhere" && bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
check "from an unrelated subdirectory: the same output as the root" "$OUT" "$ROOT_OUT"
newrepo; ( cd "$D" && git_q commit -q --allow-empty -m empty ) >/dev/null; run
check "no added migration: exit 0" "$RC" 0; has "no added migration: says 0 files examined" "$OUT" "0 migration files examined"
OUT="$(cd "$D/supabase" && bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
check "no added migration, from a subdirectory: exit 0, not 1" "$RC" 0; has "no added migration, from a subdirectory: 0 files examined" "$OUT" "0 migration files examined"
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; run --only "$F1"
has "--only: the examined count counts judged files" "$OUT" "1 migration files examined"

# 29. item 3: --pr-body-file needs --only; example lines in fences, comments and quotes are not exceptions
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"
OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" HEAD --pr-body-file "$ROOT/body.md" 2>&1)"; RC=$?
check "--pr-body-file without --only: exit 1" "$RC" 1; has "--pr-body-file without --only: says why" "$OUT" "needs --only"
printf 'Example:\n\n```\ntimeout-exception: a reason of many words\n```\n' > "$ROOT/bodyf.md"; run --pr-body-file "$ROOT/bodyf.md" --only "$F1"
check "an exception line only inside a triple-backtick fence: exit 2" "$RC" 2
printf '~~~text\ntimeout-exception: a reason of many words\n~~~\n' > "$ROOT/bodyt.md"; run --pr-body-file "$ROOT/bodyt.md" --only "$F1"
check "an exception line only inside a triple-tilde fence: exit 2" "$RC" 2
printf '```\nexample\n```\n\ntimeout-exception: a real reason here\n' > "$ROOT/bodyfr.md"; run --pr-body-file "$ROOT/bodyfr.md" --only "$F1"
check "a fenced example, then a real line after the fence closes: exit 0" "$RC" 0
printf '<!--\ntimeout-exception: a reason of many words\n-->\n' > "$ROOT/bodyc.md"; run --pr-body-file "$ROOT/bodyc.md" --only "$F1"
check "an exception line inside an HTML comment: exit 2" "$RC" 2
printf '> timeout-exception: a reason of many words\n    timeout-exception: a reason of many words\n' > "$ROOT/bodyq.md"; run --pr-body-file "$ROOT/bodyq.md" --only "$F1"
check "a quoted line and an indented-code line: exit 2" "$RC" 2
newrepo; for k in 1 2 3 4 5 6 7 8; do addmig "8800000000000${k}_x.sql" "$(guard "'5s'" "'120s'")"; done
run --pr-body-file "$ROOT/bodyf.md" --only supabase/migrations/88000000000001_x.sql
check "one fenced example line does not turn asks into exceptions: exit 2" "$RC" 2; hasnt "no exception reported" "$OUT" "exception supabase"

# 30. item 4: shape. exactly one BEGIN, a COMMIT, nothing but SET outside them, no ROLLBACK
shape() { newrepo; addmig 88000000000002_a.sql "$1"; run; }
shape "$(printf 'CREATE TABLE t (id int);\n'; guard "'3s'" "'30s'")"
check "a statement before BEGIN: exit 3" "$RC" 3; has "statement before BEGIN: reason" "$OUT" "reason=shape: statement before BEGIN"
shape "$(guard "'3s'" "'30s'"; printf 'ALTER TABLE t ADD COLUMN c int;\n')"
check "a statement after COMMIT: exit 3" "$RC" 3; has "statement after COMMIT: reason" "$OUT" "reason=shape: statement after COMMIT"
shape "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nROLLBACK;\nALTER TABLE t ADD COLUMN c int;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"
check "ROLLBACK, a statement, then COMMIT: exit 3" "$RC" 3; has "ROLLBACK: reason" "$OUT" "reason=shape: ROLLBACK"
shape "$(printf '%s\n%s\n%s %s = %s;\n%s %s = %s;\n' "$CM" "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'")"
check "COMMIT before BEGIN, the window never committed: exit 3" "$RC" 3; has "COMMIT before BEGIN: reason" "$OUT" "reason=shape: COMMIT before BEGIN"
shape "$(guard "'3s'" "'30s'"; guard "'3s'" "'30s'")"
check "two windows: exit 3" "$RC" 3; has "two windows: reason" "$OUT" "reason=shape: BEGIN after COMMIT"
shape "$(printf '%s\n%s %s = %s;\n%s %s = %s;\n%s\n%s %s = %s;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$BG" "$SL" "$LK" "'3s'" "$CM")"
check "a second BEGIN inside the window: exit 3" "$RC" 3; has "second BEGIN: reason" "$OUT" "reason=shape: second BEGIN"
shape "$(printf 'SET search_path = public;\n'; guard "'3s'" "'30s'"; printf 'RESET search_path;\n')"
check "only SET and RESET outside the window: exit 0" "$RC" 0
shape "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT 1;\nABORT;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$CM")"
check "ABORT inside the window: exit 3" "$RC" 3

# 31. item 5: set_config and timeouts named inside dollar-quoted bodies
shape "$(gx "'3s'" "'30s'" "$(printf 'SELECT set_config(%s, %s, true);' "'lock_timeout'" "'0'")")"
check "set_config of lock_timeout inside the window: exit 2" "$RC" 2; has "set_config: flagged" "$OUT" "set-timeout-call"
shape "$(gx "'3s'" "'30s'" "$(printf 'SELECT set_config(%s, %s, false);' "'statement_timeout'" "'0'")")"
check "session-level set_config of statement_timeout: exit 2" "$RC" 2
shape "$(gx "'3s'" "'30s'" "$(printf 'DO $$ BEGIN SET LOCAL %s = 0; END $$;' "$LK")")"
check "SET LOCAL lock_timeout inside a DO block: exit 2" "$RC" 2; has "DO block: flagged" "$OUT" "timeout-in-body"
shape "$(gx "'3s'" "'30s'" "$(printf 'CREATE FUNCTION f() RETURNS void LANGUAGE plpgsql AS $fn$ BEGIN PERFORM set_config(%s, %s, true); END $fn$;' "'$ST'" "'0'")")"
check "a function body naming statement_timeout: exit 2" "$RC" 2
shape "$(gx "'3s'" "'30s'" "$(printf 'SELECT set_config(%s, %s, true);' "'search_path'" "'public'")")"
check "set_config of an unrelated setting: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf 'DO $$ BEGIN PERFORM 1; END $$;')")"
check "a DO block that names no timeout: exit 0" "$RC" 0
newrepo; for off in $(seq 2030 2070); do
  printf '%s\n%s %s = %s;\n%s %s = %s;\nDO $$ %s %s $$;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$(mkpad "$off")" "$LK" "$CM" > "$D/supabase/migrations/8800000000$(printf '%04d' "$off")_g.sql"
done
( cd "$D" && git add supabase && git_q commit -q -m bodyedge ) >/dev/null; run
check "a timeout name straddling the window edge inside a dollar body: all 41 files flagged" "$(printf '%s\n' "$OUT" | grep -c 'timeout-in-body')" 41

# 32. item 6: valid PostgreSQL transaction forms
fmt() { newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s %s = %s;\nSELECT 1;\n%s\n' "$1" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$2")"; run; }
fmt "START TRANSACTION;" "COMMIT;"; check "START TRANSACTION ... COMMIT: exit 0" "$RC" 0
fmt "BEGIN ISOLATION LEVEL SERIALIZABLE;" "COMMIT;"; check "BEGIN ISOLATION LEVEL ... : exit 0" "$RC" 0
fmt "BEGIN TRANSACTION READ WRITE;" "COMMIT TRANSACTION;"; check "BEGIN TRANSACTION READ WRITE ... COMMIT TRANSACTION: exit 0" "$RC" 0
fmt "START TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY;" "COMMIT WORK;"; check "START TRANSACTION with two modes ... COMMIT WORK: exit 0" "$RC" 0
fmt "BEGIN;" "END;"; check "BEGIN ... END: exit 0" "$RC" 0
fmt "begin work;" "end transaction;"; check "begin work ... end transaction: exit 0" "$RC" 0
fmt "BEGIN;" "COMMIT AND NO CHAIN;"; check "COMMIT AND NO CHAIN: exit 0" "$RC" 0

# 33. item 7: PostgreSQL units are case-sensitive; inner and outer spaces in the value are accepted
newrepo; addmig 88000000000002_a.sql "$(guard "'3S'" "'30s'")"; run
check "'3S' (upper-case unit): exit 2" "$RC" 2; has "'3S' is shown as written" "$OUT" "lock_timeout=3S"
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'30S'")"; run
check "'30S': exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(guard "'3000MS'" "'30000ms'")"; run
check "'3000MS': exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(guard "'3 s'" "' 30s '")"; run
check "'3 s' and ' 30s ' read as 3s and 30s: exit 0" "$RC" 0; has "spaces are removed from the shown value" "$OUT" "lock_timeout=3s statement_timeout=30s"

# 34. review round 9: calls and catalogues that change a timeout, byte-class identifiers, CommonMark fences, COMMIT AND CHAIN
shape "$(gx "'3s'" "'30s'" "$(printf "UPDATE pg_settings SET setting = '0' WHERE name = '%s';" "$LK")")"
check "an UPDATE of pg_settings inside the window: exit 2" "$RC" 2; has "pg_settings: flagged" "$OUT" "set-timeout-call"
shape "$(gx "'3s'" "'30s'" "$(printf 'SET LOCAL U&"lock\\005ftimeout" = %s;' "'0'")")"
check "a SET LOCAL with a U& escaped timeout name: exit 2" "$RC" 2; has "U& escape: flagged" "$OUT" "set-timeout-call"
E="$(printf '\303\251')"
shape "$(guard "'3s'" "'30s'"; printf "SET x.y = \$%s\$'\$%s\$;\nALTER TABLE big ADD COLUMN c int;\nSET x.z = \$%s\$'\$%s\$;\n" "$E" "$E" "$E" "$E")"
check "a non-ASCII dollar tag is read as a tag: the ALTER after COMMIT is a stop, exit 3" "$RC" 3
shape "$(guard "'3s'" "'30s'"; printf 'SET x.w TO %s$$;\nALTER TABLE big ADD COLUMN d int;\nSET x.v TO $$x$$;\n' "$E")"
check "a non-ASCII byte before \$\$ is part of an identifier: the ALTER after COMMIT is a stop, exit 3" "$RC" 3
fmt "BEGIN;" "COMMIT AND CHAIN;"; check "COMMIT AND CHAIN is not a closing COMMIT: exit 3" "$RC" 3; has "COMMIT AND CHAIN: names COMMIT" "$OUT" "reason=no COMMIT;"
shape "$(gx "'3s'" "'30s'" "$(printf 'RESET U&"lock\\005ftimeout";')")"
check "a RESET with a U& escaped timeout name: exit 2" "$RC" 2; has "RESET U&: flagged" "$OUT" "set-timeout-call"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT set_config(U&'lock\\\\005ftimeout', '0', true);")")"
check "set_config with a U& escaped name: exit 2" "$RC" 2
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT set_config(E'lock\\\\137timeout', '0', true);")")"
check "set_config with an E'..' escaped name: exit 2" "$RC" 2
shape "$(gx "'3s'" "'30s'" "$(printf "UPDATE U&\"pg\\\\005fsettings\" SET setting = '0' WHERE name = U&'lock\\\\005ftimeout';")")"
check "an UPDATE of an escaped pg_settings: exit 2" "$RC" 2
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT set_config('search_path', E'public', true);")")"
check "set_config of an unrelated setting with an E'..' value: still an ask (conservative), exit 2" "$RC" 2
newrepo; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"
body() { printf '%b' "$1" > "$ROOT/bodyx.md"; run --pr-body-file "$ROOT/bodyx.md" --only "$F1"; }
body '```\n~~~\ntimeout-exception: a reason of many words\n```\n'
check "a tilde line does not close a backtick fence: exit 2" "$RC" 2
body '```\n    ```\ntimeout-exception: a reason of many words\n```\n'
check "a fence line indented 4 spaces does not close a fence: exit 2" "$RC" 2
body '````\n```\ntimeout-exception: a reason of many words\n````\n'
check "three backticks do not close a four-backtick fence: exit 2" "$RC" 2
body 'Notes for review <!--\ntimeout-exception: a reason of many words\n-->\n'
check "a comment opened mid-line hides the next lines: exit 2" "$RC" 2
body '<!-- a --> <!--\ntimeout-exception: a reason of many words\n-->\n'
check "a second comment opened after a closed one hides the next lines: exit 2" "$RC" 2
body '```\n```bash\ntimeout-exception: a reason of many words\n```\n'
check "a fence line with an info string does not close a fence: exit 2" "$RC" 2
body '````\n```\nx\n````\n\ntimeout-exception: a real reason here\n'
check "a real line after a four-backtick fence closes properly: exit 0" "$RC" 0
body 'Intro <!-- hidden --> text\ntimeout-exception: a real reason here\n'
check "a closed inline comment does not hide the next line: exit 0" "$RC" 0

# 35. follow-up (u88): COMMIT/END AND CHAIN inside the window, NOTIFY after COMMIT, dynamic set_config, body kinds, PREPARE TRANSACTION
chain() { shape "$(printf '%s\n%s %s = %s;\n%s %s = %s;\n%s\nALTER TABLE t ADD COLUMN c int;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'" "$1" "$CM")"; }
chain "COMMIT AND CHAIN;"
check "COMMIT AND CHAIN inside the window: exit 3" "$RC" 3; has "COMMIT AND CHAIN: shape reason" "$OUT" "reason=shape: COMMIT AND CHAIN"
chain "END AND CHAIN;"
check "END AND CHAIN inside the window: exit 3" "$RC" 3; has "END AND CHAIN: shape reason" "$OUT" "reason=shape: COMMIT AND CHAIN"
chain "$(printf 'commit\n  and\n  chain;')"
check "a COMMIT AND CHAIN split over three lines, lower case: exit 3" "$RC" 3
chain "COMMIT TRANSACTION AND CHAIN;"
check "COMMIT TRANSACTION AND CHAIN: exit 3" "$RC" 3
chain "COMMIT AND NO CHAIN;"
check "COMMIT AND NO CHAIN is a normal COMMIT (the ALTER after it is a stop only as a statement after COMMIT): exit 3" "$RC" 3; has "AND NO CHAIN: reason is a statement after COMMIT" "$OUT" "reason=shape: statement after COMMIT"
fmt "BEGIN;" "COMMIT AND NO CHAIN;"
check "COMMIT AND NO CHAIN alone closes the window: exit 0" "$RC" 0

shape "$(guard "'3s'" "'30s'"; printf "NOTIFY pgrst, 'reload schema';\n")"
check "a NOTIFY after COMMIT: exit 0" "$RC" 0; has "NOTIFY after COMMIT: ok" "$OUT" "ok $F1"
shape "$(guard "'3s'" "'30s'"; printf "NOTIFY pgrst, 'reload schema';\nNOTIFY pgrst, 'reload config';\n")"
check "two NOTIFY statements after COMMIT: exit 0" "$RC" 0
shape "$(printf "NOTIFY pgrst, 'reload schema';\n"; guard "'3s'" "'30s'")"
check "a NOTIFY before BEGIN is still a stop: exit 3" "$RC" 3; has "NOTIFY before BEGIN: reason" "$OUT" "reason=shape: statement before BEGIN"
shape "$(guard "'3s'" "'30s'"; printf "NOTIFY pgrst, 'reload schema';\nALTER TABLE t ADD COLUMN c int;\n")"
check "a NOTIFY and then an ALTER after COMMIT: exit 3" "$RC" 3; has "ALTER after a NOTIFY: reason" "$OUT" "reason=shape: statement after COMMIT"
shape "$(guard "'3s'" "'30s'"; printf "SELECT pg_notify('pgrst', 'reload schema');\n")"
check "SELECT pg_notify after COMMIT is not a NOTIFY: exit 3" "$RC" 3

shape "$(gx "'3s'" "'30s'" "$(printf "SELECT set_config('lock' || '_timeout', '0', true);")")"
check "set_config with a concatenated name: exit 2" "$RC" 2; has "concatenated name: tagged" "$OUT" "set-config-dynamic"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT set_config(k, '0', true) FROM (VALUES ('%s')) v(k);" "$LK")")"
check "set_config with a VALUES column as the name: exit 2" "$RC" 2; has "VALUES column name: tagged" "$OUT" "set-config-dynamic"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT set_config('search_path', 'public', true), set_config(v, '1', false);")")"
check "one literal call and one dynamic call: exit 2" "$RC" 2
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT set_config ( 'search_path' , 'public', true);")")"
check "set_config with a plain literal name and odd spacing: exit 0" "$RC" 0

shape "$(gx "'3s'" "'30s'" "$(printf "CREATE FUNCTION f() RETURNS void LANGUAGE plpgsql AS \$fn\$ BEGIN PERFORM set_config('%s', '3s', true); END \$fn\$;" "$LK")")"
check "a function body naming a timeout: exit 2" "$RC" 2; has "function body: its own tag" "$OUT" "timeout-in-function"; hasnt "function body: not the DO tag" "$OUT" "timeout-in-body"
shape "$(gx "'3s'" "'30s'" "$(printf 'DO $$ BEGIN SET LOCAL %s = 0; END $$;' "$LK")")"
check "a DO body naming a timeout: exit 2" "$RC" 2; has "DO body: its own tag" "$OUT" "timeout-in-body"; hasnt "DO body: not the function tag" "$OUT" "timeout-in-function"
shape "$(gx "'3s'" "'30s'" "$(printf 'CREATE OR REPLACE PROCEDURE p() LANGUAGE plpgsql AS $$ BEGIN SET LOCAL %s = 0; END $$;' "$ST")")"
check "a procedure body naming a timeout: exit 2" "$RC" 2; has "procedure body: function tag" "$OUT" "timeout-in-function"
shape "$(gx "'3s'" "'30s'" "$(printf 'DO $$ BEGIN SET LOCAL %s = 0; END $$; CREATE FUNCTION g() RETURNS void LANGUAGE plpgsql AS $$ BEGIN SET LOCAL %s = 0; END $$;' "$LK" "$ST")")"
check "a DO body and a function body in one file: exit 2" "$RC" 2; has "both kinds: DO tag" "$OUT" "timeout-in-body"; has "both kinds: function tag" "$OUT" "timeout-in-function"

shape "$(gx "'3s'" "'30s'" "PREPARE TRANSACTION 'x';")"
check "PREPARE TRANSACTION inside the window: exit 3" "$RC" 3; has "PREPARE TRANSACTION: shape reason" "$OUT" "reason=shape: PREPARE TRANSACTION"

OUT="$(bash "$SCRIPT" --help 2>&1)"; RC=$?
has "the help names the Linux deploy worker and untested macOS awk" "$OUT" "macOS"

# 36. review of u88 (round 2): quoted function names, word boundaries, calls inside literals, COMMENT bodies
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT \"set_config\"('lock' || '_timeout', '0', true);")")"
check "a double-quoted set_config name with a concatenated timeout name: exit 2" "$RC" 2; has "quoted set_config: tagged" "$OUT" "set-config-dynamic"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT pg_catalog.\"set_config\"('statement' || '_timeout', '0', true);")")"
check "a schema-qualified quoted set_config name: exit 2" "$RC" 2; has "qualified quoted set_config: tagged" "$OUT" "set-config-dynamic"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT pg_catalog.set_config('search_path', 'public', true);")")"
check "a schema-qualified set_config with a plain literal name: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf 'PREPARE transaction_fetch (int) AS SELECT $1;')")"
check "PREPARE transaction_fetch is a prepared statement, not PREPARE TRANSACTION: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf "PREPARE TRANSACTION 'x';")")"
check "PREPARE TRANSACTION with a literal still stops: exit 3" "$RC" 3
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT my_set_config(x, '1');")")"
check "my_set_config is another function, not set_config: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf "COMMENT ON TABLE t IS 'call set_config(name, v) to change it';")")"
check "set_config( inside a quoted literal is not a call: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT 'set_config(', set_config(k, '1', true);")")"
check "a real dynamic call after a literal that mentions set_config: exit 2" "$RC" 2; has "real call after a literal: tagged" "$OUT" "set-config-dynamic"
shape "$(gx "'3s'" "'30s'" "$(printf 'COMMENT ON TABLE t IS $$ %s $$;' "$LK")")"
check "a timeout name inside a COMMENT ... IS \$\$..\$\$ string: exit 2" "$RC" 2; has "COMMENT body: the non-function tag" "$OUT" "timeout-in-body"; hasnt "COMMENT body: not the function tag" "$OUT" "timeout-in-function"

# 37. review of u88 (round 3): quote state is tracked separately for ' and "
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT 1 AS \"a'b\", set_config('lock' || '_timeout', '0', true);")")"
check "an apostrophe in a double-quoted identifier before a dynamic call: exit 2" "$RC" 2; has "apostrophe in an identifier: dynamic call tagged" "$OUT" "set-config-dynamic"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT 1 AS \"a'b\", set_config('%s', '0', true);" "$LK")")"
check "an apostrophe in a double-quoted identifier before a literal-name call: exit 2" "$RC" 2; has "apostrophe in an identifier: named call tagged" "$OUT" "set-timeout-call"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT 'it''s', set_config(k, '1', true);")")"
check "a balanced literal with an escaped apostrophe before a dynamic call: exit 2" "$RC" 2; has "escaped apostrophe: dynamic call tagged" "$OUT" "set-config-dynamic"
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT 'a\"b', set_config(k, '1', true);")")"
check "a double quote inside a literal before a dynamic call: exit 2" "$RC" 2
shape "$(gx "'3s'" "'30s'" "$(printf "COMMENT ON TABLE t IS 'it''s: call set_config(name, v)';")")"
check "set_config( inside a literal that holds an escaped apostrophe is not a call: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf "COMMENT ON TABLE t IS 'say \"set_config\"(name, v)';")")"
check "a quoted call name inside a single-quoted literal is not a call: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf "SELECT 1 AS \"x set_config(y\", 2;")")"
check "set_config( inside a quoted identifier is not a call: exit 0" "$RC" 0
shape "$(gx "'3s'" "'30s'" "$(printf 'SELECT "x set_config"(y);')")"
check "a quoted function name that only ends in set_config is not set_config: exit 0" "$RC" 0

# 38. a window holding only one of the two SET LOCAL lines and nothing else: only the missing-value rule can flag it
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s\n' "$BG" "$SL" "$ST" "'30s'" "$CM")"; run
check "only statement_timeout in the window: exit 2" "$RC" 2; has "only statement_timeout: lock_timeout shown as missing" "$OUT" "lock_timeout=missing statement_timeout=30s"
newrepo; addmig 88000000000002_a.sql "$(printf '%s\n%s %s = %s;\n%s\n' "$BG" "$SL" "$LK" "'3s'" "$CM")"; run
check "only lock_timeout in the window: exit 2" "$RC" 2; has "only lock_timeout: statement_timeout shown as missing" "$OUT" "lock_timeout=3s statement_timeout=missing"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
