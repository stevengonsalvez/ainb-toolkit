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
unset CM_MIGRATIONS_DIR CM_DMC_WORKFLOWS CM_DMC_MAX_LOCK_MS CM_DMC_MAX_STATEMENT_MS   # the host's environment must not change a case
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
# RUNARGS: arguments put before the caller's own (empty = the strict PR merge gate; sections 42 to 53 set --caps-ref HEAD, deploy mode)
RUNARGS=()
run() { OUT="$(cd "$D" && bash "$SCRIPT" "$BASE" HEAD ${RUNARGS[@]+"${RUNARGS[@]}"} "$@" 2>&1)"; RC=$?; }
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
newrepo; addmig 88000000000002_a.sql "$(printf '%s %s %s;\n%s %s %s;\nSELECT 1;' "$SL" "$LK" "'3s'" "$SL" "$ST" "'30s'")"; run --caps-ref HEAD   # deploy mode: the deploy-time note
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
# 39. the migrations directory is configurable (deploy.migrations_dir, env CM_MIGRATIONS_DIR); default supabase/migrations
# otherrepo <dir>: like newrepo, but the old migration and the files under test live in <dir>
otherrepo() {
  N=$((N + 1)); D="$ROOT/r$N"; mkdir -p "$D/$1"
  ( cd "$D" && git init -q . && printf -- '-- old\n' > "$1/88000000000001_old.sql" \
    && git add . && git_q commit -q -m base ) >/dev/null
  BASE="$(git -C "$D" rev-parse HEAD)"
}
# addat <dir> <file> <content>
addat() { mkdir -p "$D/$1"; printf '%s\n' "$3" > "$D/$1/$2"; ( cd "$D" && git add . && git_q commit -q -m "add $2" ) >/dev/null; }
# runenv <dir>: run with CM_MIGRATIONS_DIR set
runenv() { OUT="$(cd "$D" && CM_MIGRATIONS_DIR="$1" bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?; }
otherrepo db/migrate; addat db/migrate 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; addat supabase/migrations 88000000000003_b.sql "no guard here"; runenv db/migrate
check "a custom directory: only its files are examined, exit 0" "$RC" 0
has "a custom directory: its file is read" "$OUT" "ok db/migrate/88000000000002_a.sql"
has "a custom directory: one file examined" "$OUT" "1 migration files examined"
hasnt "a custom directory: the default directory is not read" "$OUT" "supabase/migrations"
otherrepo db/migrate; addat db/migrate 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; runenv db/migrate/
check "a trailing slash on the directory is accepted" "$RC" 0; has "a trailing slash: the file is read" "$OUT" "ok db/migrate/88000000000002_a.sql"
otherrepo db/migrate; addat db/migrate 88000000000002_a.sql "no guard here"; runenv db/migrate
check "an unguarded file in a custom directory is a stop: exit 3" "$RC" 3
otherrepo db/migrate; addat db/migrate/sub 88000000000002_a.sql "no guard here"; runenv db/migrate
check "a file in a subdirectory of a custom directory is not examined: exit 0" "$RC" 0; has "a subdirectory: zero examined" "$OUT" "0 migration files examined"
# the dot in the directory name is literal: db/mxg is not db/m.g
otherrepo db/m.g; addat db/mxg 88000000000002_a.sql "no guard here"; runenv db/m.g
check "a dot in the directory name is literal (a sibling that only matches as a regex is not examined): exit 0" "$RC" 0
has "a literal dot: zero examined" "$OUT" "0 migration files examined"
# the default stays supabase/migrations when nothing is configured
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; run
has "no configuration: the default directory is read" "$OUT" "ok $F1"
# a well-formed directory that is not in the tree (a typo) fails closed: it must not read as "0 migration files examined"
otherrepo supabase/migrations; addat supabase/migrations 88000000000002_a.sql "no guard here"; runenv supabse/migrations
check "a typo in the migrations directory: exit 1, not a silent pass" "$RC" 1; has "a typo directory: names the missing directory" "$OUT" "'supabse/migrations' does not exist"
hasnt "a typo directory: never reports a clean run" "$OUT" "migration files examined"
otherrepo db/migrate; addat db/migrate 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; runenv db/migrate
check "the real directory still passes next to the typo case: exit 0" "$RC" 0
otherrepo db/migrate; addat db/migrate 88000000000002_a.sql "no guard here"; runenv db/migrate/missing
check "a missing subdirectory of a real directory: exit 1" "$RC" 1
# mutation: drop the existence check and the typo directory reads as a clean run
MUTD="$ROOT/mutant-missing-dir.sh"
sed -e "s|^HERE=.*|HERE=\"$(dirname "$SCRIPT")\"|" -e '/does not exist at \$TO/d' "$SCRIPT" > "$MUTD"
if cmp -s "$SCRIPT" "$MUTD"; then bad "mutation: the missing-directory sed no longer matches the script (update this test)"; else
  otherrepo supabase/migrations; addat supabase/migrations 88000000000002_a.sql "no guard here"
  MOUT="$(cd "$D" && CM_MIGRATIONS_DIR=supabse/migrations bash "$MUTD" "$BASE" HEAD 2>&1)"; MRC=$?
  if [ "$MRC" = 0 ] && case "$MOUT" in *"0 migration files examined"*) true ;; *) false ;; esac; then ok "mutation: without the existence check a typo directory exits 0 with 0 files examined, so the exit-1 tests above fail"
  else bad "mutation: the mutant still refused a missing directory (rc=$MRC)" "$MOUT"; fi
fi
# bad directories fail closed with exit 1
for bad in /abs/dir ../out a//b . ./a a/. a/./ 'a b' 'a*' 'a;b' '$(x)' 'a/../b'; do
  otherrepo db/migrate; addat db/migrate 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; runenv "$bad"
  check "bad migrations directory '$bad': exit 1" "$RC" 1; has "bad migrations directory '$bad': says so" "$OUT" "bad migrations directory"
done
# the config key is read through lib.sh (needs yq); the env var beats it
if command -v yq >/dev/null 2>&1; then
  printf 'schema: concertmaster.config/v1\ndeploy:\n  migrations_dir: db/migrate\n' > "$ROOT/mig-cfg.yaml"
  otherrepo db/migrate; addat db/migrate 88000000000002_a.sql "$(guard "'3s'" "'30s'")"
  OUT="$(cd "$D" && CM_CONFIG="$ROOT/mig-cfg.yaml" bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
  check "deploy.migrations_dir from the config: exit 0" "$RC" 0; has "the config directory is read" "$OUT" "ok db/migrate/88000000000002_a.sql"
  OUT="$(cd "$D" && CM_CONFIG="$ROOT/mig-cfg.yaml" CM_MIGRATIONS_DIR=other/dir bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
  check "the env var beats the config directory (which holds a guarded file): the other dir is missing, exit 1" "$RC" 1; has "env beats config: the missing directory is named" "$OUT" "'other/dir' does not exist"
  # fail closed: a config that cannot be read, or an empty key, never falls back to the default directory
  printf 'schema: concertmaster.config/v1\ndeploy:\n  migrations_dir: ""\n' > "$ROOT/mig-cfg-empty.yaml"
  OUT="$(cd "$D" && CM_CONFIG="$ROOT/mig-cfg-empty.yaml" bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
  check "an empty deploy.migrations_dir: exit 1" "$RC" 1; has "an empty deploy.migrations_dir: says so" "$OUT" "empty or not a string"
  # a deploy section that is not a map must not fall back to the default directory either
  for DEP in '"x"' '[]'; do
    printf 'schema: concertmaster.config/v1\ndeploy: %s\n' "$DEP" > "$ROOT/mig-cfg-shape.yaml"
    newrepo; addmig 88000000000002_a.sql "no guard here"
    OUT="$(cd "$D" && CM_CONFIG="$ROOT/mig-cfg-shape.yaml" bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
    check "a deploy section that is $DEP, not a map: exit 1, no silent default directory" "$RC" 1; has "a deploy section that is $DEP: says so" "$OUT" "not a map"
  done
  printf 'schema: [unclosed\n' > "$ROOT/mig-cfg-bad.yaml"
  OUT="$(cd "$D" && CM_CONFIG="$ROOT/mig-cfg-bad.yaml" bash "$SCRIPT" "$BASE" HEAD 2>&1)"; RC=$?
  check "a config that does not parse: exit 1, no silent default" "$RC" 1; has "unreadable config: says so" "$OUT" "could not be read"
else
  echo "SKIP the config-key cases: yq is not installed (they cover the config path)"
fi

# 40. the STOP note: merge-gate advice (edit the unmerged file) apart from deploy-time advice; the connection-level fix is the
# options= db-url form, never the PGOPTIONS env
newrepo; addmig 88000000000002_a.sql "no guard here"; run
check "an unguarded file, PR gate: exit 3" "$RC" 3
has "PR gate: the note says edit the unmerged file" "$OUT" "The file is not on the base branch yet: edit it"
has "PR gate: the note says the caps are not accepted here" "$OUT" "connection-level caps are not accepted here"
run --caps-ref HEAD
check "an unguarded file, deploy mode with no covering workflows: exit 3" "$RC" 3
has "deploy mode: the note is about an already-applied file" "$OUT" "If that version is already applied on staging"
has "deploy mode: the note names the options= db-url form with the 120000 cap" "$OUT" "options=-c lock_timeout=3s -c statement_timeout=120000"
has "deploy mode: the note says the PGOPTIONS env is not a substitute" "$OUT" "The PGOPTIONS env is not a substitute"
hasnt "deploy mode: the note no longer offers PGOPTIONS as the example fix" "$OUT" "for example PGOPTIONS="
has "deploy mode: the note keeps the in-file values at 30s" "$OUT" "the in-file SET LOCAL values stay 3s / 30s"
OUT="$(bash "$SCRIPT" --help 2>&1)"
has "the help names the db-url options= fix" "$OUT" "options=-c lock_timeout=3s -c statement_timeout=120000"
has "the help says the PGOPTIONS env was ignored when measured" "$OUT" "ignored it (lock_timeout=0)"
has "the help names the configurable directory" "$OUT" "deploy.migrations_dir"
has "the help names the PR merge gate range" "$OUT" "at the PR"

# 41. the docs carry the merge-gate rule and no issue number or absolute home path (text lint over the skill)
SKILL_DIR="$(cd "$HERE/../.." && pwd)"
LANES="$(cat "$SKILL_DIR/references/lanes.md")"; SKM="$(cat "$SKILL_DIR/SKILL.md")"
has "lanes.md: the pr-sweeper merge gate runs the migration check at the exact head" "$LANES" 'scripts/deploy-migration-check.sh $MB <PR head sha>'
has "lanes.md: the merge-base is of the PR's own base" "$LANES" 'MB=$(git merge-base origin/<base> <PR head sha>)'
has "lanes.md: an edited or deleted migration is held" "$LANES" "The edited or deleted list"
has "lanes.md: a STOP is never waived at the gate" "$LANES" "A STOP is never waived by the author"
has "lanes.md: the gate runs with no --caps-ref and shows its mode" "$LANES" "mode: pr-gate"
has "lanes.md: the deploy worker brief passes --caps-ref" "$LANES" "{{from_tag}} {{main_sha}} --caps-ref {{main_sha}}"
has "lanes.md: the directory and bases are placeholders" "$LANES" "{{migration_bases}}"
has "SKILL.md: merge gate item 3a points at the lane" "$SKM" "3a. **Migration check**"
has "SKILL.md: the already-applied fix is the options= form" "$SKM" "Use the connection URL's \`options=\` form"
hasnt "SKILL.md: PGOPTIONS is no longer the example fix" "$SKM" "(for example \`PGOPTIONS="
for f in "$SKILL_DIR/references/lanes.md" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/scripts/deploy-migration-check.sh" "$SKILL_DIR/config.example.yaml"; do
  if grep -n -E '#[0-9]{4}|/home/[a-z]|/Users/[a-z]' "$f" >/dev/null 2>&1; then bad "$(basename "$f"): an issue number or an absolute home path found" "$(grep -n -E '#[0-9]{4}|/home/[a-z]|/Users/[a-z]' "$f" | head -3)"; else ok "$(basename "$f"): no issue number or absolute home path"; fi
done

# From here to the end of section 53 the script runs in DEPLOY MODE (--caps-ref HEAD): the cover is a deploy-time rule only.
# Section 54 runs the same files in the strict PR-gate mode (no --caps-ref).
RUNARGS=(--caps-ref HEAD)
# 42. a STOP covered by the deploy workflows' connection-level caps (read from the --caps-ref tree): only the "no BEGIN; and
# COMMIT;" class, only when BOTH workflows cap the push, and every covered file is reported, never silent
WP=.github/workflows/deploy-production.yml; WS=.github/workflows/deploy-staging.yml
CAPPED_URL='DB_URL="postgresql://postgres@db.${DB_REF}.supabase.co:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"'
PUSH='supabase db push --include-all --db-url "$DB_URL"'
# wfput <path> <lines...>: write a workflow step (one line per argument), commit it and move BASE past it, so the workflows sit
# BEFORE the range under test (a range that edits them cannot vouch for them); WF_KEEP_BASE=1 leaves BASE alone
wfput() { local f="$1"; shift; mkdir -p "$D/$(dirname "$f")"; { printf 'steps:\n  - run: |\n'; for l in "$@"; do printf '      %s\n' "$l"; done; } > "$D/$f"; ( cd "$D" && git add . && git_q commit -q -m "wf $f" ) >/dev/null; [ "${WF_KEEP_BASE:-}" = 1 ] || BASE="$(git -C "$D" rev-parse HEAD)"; }
# covrepo <prod url line> <staging url line> [push line]: a repo with the two workflows and one plain (no transaction) migration
covrepo() { newrepo; wfput "$WP" "$1" "${3:-$PUSH}"; wfput "$WS" "$2" "${3:-$PUSH}"; addmig 88000000000002_a.sql "SELECT 1 FROM $MARK;"; run; }

covrepo "$CAPPED_URL" "$CAPPED_URL"
check "both workflows capped: a no-transaction file is covered, exit 0" "$RC" 0
has "covered: one line names the file" "$OUT" "covered (connection caps): $F1"
has "covered: the production workflow line is quoted with file:line" "$OUT" "$WP:"
has "covered: the staging workflow line is quoted with file:line" "$OUT" "$WS:"
has "covered: the decoded caps are shown" "$OUT" "lock_timeout=3000ms statement_timeout=120000ms"
has "covered: the summary counts it" "$OUT" "stop=0 covered=1"
has "covered: the summary lists the file again" "$OUT" "covered (not silent, reported on every run): $F1"
hasnt "covered: no stop line" "$OUT" "stop $F1"
hasnt "covered: no SQL body in the output" "$OUT" "$MARK"
has "covered: counts as examined" "$OUT" "1 migration files examined"

covrepo "$CAPPED_URL" "DB_URL=postgresql://postgres@db.x.supabase.co:5432/postgres"
check "staging uncapped: still a stop, exit 3" "$RC" 3; has "staging uncapped: the stop line" "$OUT" "stop $F1 reason=no BEGIN; and COMMIT;"
covrepo "DB_URL=postgresql://postgres@db.x.supabase.co:5432/postgres" "$CAPPED_URL"
check "production uncapped: still a stop, exit 3" "$RC" 3
covrepo "PGOPTIONS='-c lock_timeout=3s -c statement_timeout=120000'" "PGOPTIONS='-c lock_timeout=3s -c statement_timeout=120000'" 'supabase db push --include-all --db-url "$DB_URL"'
check "a PGOPTIONS env only (the pinned CLI ignores it): stop, exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D10s%20-c%20statement_timeout%3D120000"' "$CAPPED_URL"
check "lock_timeout 10s: stop, exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D5min"' "$CAPPED_URL"
check "statement_timeout 5min: stop, exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D0%20-c%20statement_timeout%3D120000"' "$CAPPED_URL"
check "lock_timeout 0 means no limit: stop, exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D0"' "$CAPPED_URL"
check "statement_timeout 0 means no limit: stop, exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s"' "$CAPPED_URL"
check "statement_timeout missing: stop, exit 3" "$RC" 3
covrepo '# DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"' "$CAPPED_URL"
check "a cap in a comment line only: stop, exit 3" "$RC" 3
covrepo 'echo "DB_URL=postgresql://x/p?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"' "$CAPPED_URL"
check "a cap inside an echo only: stop, exit 3" "$RC" 3

# encoded and decoded forms, and the unit forms
DEC_URL='DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c lock_timeout=3s -c statement_timeout=2min"'
covrepo "$DEC_URL" "$DEC_URL"
check "decoded form with 2min: covered, exit 0" "$RC" 0; has "2min decodes to 120000ms" "$OUT" "statement_timeout=120000ms"
MS_URL='DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3000ms%20-c%20statement_timeout%3D120s"'
covrepo "$MS_URL" "$MS_URL"
check "3000ms and 120s: covered, exit 0" "$RC" 0
covrepo "$CAPPED_URL" "$CAPPED_URL" 'supabase db push --include-all --db-url "postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"'
check "a literal --db-url in the push line: covered, exit 0" "$RC" 0
covrepo "$CAPPED_URL" "$CAPPED_URL" 'supabase db push --include-all \
  --db-url "$DB_URL"'
check "a --db-url on a continuation line: covered, exit 0" "$RC" 0
covrepo "$CAPPED_URL" "$CAPPED_URL" 'supabase db push --include-all'
check "a push with no --db-url: stop, exit 3" "$RC" 3
PWV="hun""ter2"   # a fake password, built from pieces so no literal credential sits in this file
AT='@'   # the @ of a fake URL is spliced in, so no scan-shaped user:password@host literal sits in this file
covrepo 'DB_URL="postgresql://deploy:'"$PWV$AT"'db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"' "$CAPPED_URL"
check "userinfo in the URL: covered, exit 0" "$RC" 0; hasnt "userinfo in the URL: the password is never printed" "$OUT" "$PWV"

# a second, uncapped push in one workflow keeps the stop
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH" 'supabase db push --db-url "postgresql://postgres@db.x:5432/postgres"'; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "SELECT 1;"; run
check "one uncapped push among two in a workflow: stop, exit 3" "$RC" 3
newrepo; addmig 88000000000002_a.sql "SELECT 1;"; run
check "no workflow files at all: stop, exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "one workflow file missing: stop, exit 3" "$RC" 3

# the workflows are read at the <to-ref> tree, not the working copy
newrepo; wfput "$WP" 'DB_URL=postgresql://x/p' "$PUSH"; wfput "$WS" 'DB_URL=postgresql://x/p' "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"
for w in "$WP" "$WS"; do printf '      %s\n      %s\n' "$CAPPED_URL" "$PUSH" > "$D/$w"; done
run
check "committed workflows uncapped, working copy capped: stop (read from the <to-ref> tree)" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"
for w in "$WP" "$WS"; do printf '      DB_URL=postgresql://x/p\n      %s\n' "$PUSH" > "$D/$w"; done
run
check "committed workflows capped, working copy uncapped: covered (read from the <to-ref> tree)" "$RC" 0
has "to-ref tree: reported as covered" "$OUT" "covered (connection caps): $F1"

# every other class stays what it was, with or without caps
covrepo "$CAPPED_URL" "$CAPPED_URL"
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "SELECT 1;"
addmig 88000000000003_b.sql "$(printf '%s\nROLLBACK;\n%s\n' "$BG" "$CM")"; run
check "a covered file next to a ROLLBACK shape stop: exit 3" "$RC" 3; has "the shape stop is still reported" "$OUT" "stop $F2 reason=shape: ROLLBACK"; has "the covered file is still reported" "$OUT" "covered (connection caps): $F1"
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$(printf 'SELECT 1;\nROLLBACK;\n')"; run
check "a plain file that holds a ROLLBACK is not covered: exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$(printf '%s\nSELECT 1;\n' "$BG")"; run
check "BEGIN with no COMMIT is not covered: exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"; run
check "an ask stays an ask with caps in place: exit 2" "$RC" 2; hasnt "an ask is never reported covered" "$OUT" "covered (connection caps)"
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; addmig 88000000000003_b.sql "$(guard "'3s'" "'30s'")"; run
check "a covered file next to an ok file: exit 0" "$RC" 0; has "covered and ok: both counted" "$OUT" "ok=1 exception=0 ask=0 stop=0 covered=1"
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; addmig 88000000000003_b.sql "$(guard "'5s'" "'120s'")"; run
check "a covered file next to an ask: exit 2" "$RC" 2
CM_DMC_WORKFLOWS="ci/one.yml ci/two.yml" covrepo "$CAPPED_URL" "$CAPPED_URL"
check "CM_DMC_WORKFLOWS names other paths: the default workflows are not read, stop, exit 3" "$RC" 3

# 43. review of the covered class: the file's own timeout changes, the options= parameter only, the tree the caps are read from
covfile() { covrepo "$CAPPED_URL" "$CAPPED_URL" >/dev/null 2>&1; addmig 88000000000003_b.sql "$1"; run; }
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf 'SET statement_timeout = 0;\nSELECT 1;\n')"; run
check "a plain file that sets statement_timeout itself is not covered: exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf "SELECT set_config('lock_timeout', '0', false);\n")"; run
check "a plain file that calls set_config on a timeout is not covered: exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf 'RESET lock_timeout;\nSELECT 1;\n')"; run
check "a plain file that resets lock_timeout is not covered: exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf 'DO $$ BEGIN PERFORM set_config(%s, %s, false); END $$;\n' "'$LK'" "'0'")"; run
check "a timeout named in a DO body is not covered: exit 3" "$RC" 3

APP_URL='DB_URL="postgresql://postgres@db.x:5432/postgres?application_name=lock_timeout=3s_statement_timeout=1&sslmode=require"'
covrepo "$APP_URL" "$APP_URL"
check "the caps only inside another URL parameter are not options=: stop, exit 3" "$RC" 3
PW_URL='DB_URL="postgresql://postgres:lock_timeout=3s_statement_timeout=1'"$AT"'db.x:5432/postgres"'
covrepo "$PW_URL" "$PW_URL"
check "the caps text inside the userinfo is not options=: stop, exit 3" "$RC" 3
AMP_URL='DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s&sslmode=require&x=-c%20statement_timeout%3D1000"'
covrepo "$AMP_URL" "$AMP_URL"
check "options= stops at the next &: a statement cap after it does not count: exit 3" "$RC" 3
TAIL_URL='DB_URL="postgresql://postgres@db.x:5432/postgres?sslmode=require&options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"'
covrepo "$TAIL_URL" "$TAIL_URL"
check "options= after another parameter still counts: exit 0" "$RC" 0

# the range must not edit the workflows, and --caps-ref picks the tree
newrepo; wfput "$WP" 'DB_URL=postgresql://x/p' "$PUSH"; wfput "$WS" 'DB_URL=postgresql://x/p' "$PUSH"
WF_KEEP_BASE=1 wfput "$WP" "$CAPPED_URL" "$PUSH"; WF_KEEP_BASE=1 wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run --caps-ref "$BASE"
check "a range that adds the caps to the workflows itself cannot vouch for them (gate passes --caps-ref base): exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
WF_KEEP_BASE=1 wfput "$WP" 'DB_URL=postgresql://x/p' "$PUSH"; WF_KEEP_BASE=1 wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run --caps-ref "$BASE"
check "a range that drops the caps (base has them, head does not): exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
WF_KEEP_BASE=1 wfput "$WP" "$CAPPED_URL" 'echo unrelated edit' "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run --caps-ref HEAD
check "an unrelated workflow edit in the range keeps the caps (deploy passes --caps-ref <pinned sha>): covered, exit 0" "$RC" 0
RUNARGS=(); run; RUNARGS=(--caps-ref HEAD)
check "the same range with no --caps-ref is not covered (strict PR gate): exit 3" "$RC" 3; has "the stop says why" "$OUT" "add the in-file guard"
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"
run --caps-ref "$(git -C "$D" rev-list --max-parents=0 HEAD)"
check "--caps-ref at the base commit that has no workflows: stop, exit 3" "$RC" 3
run --caps-ref HEAD
check "--caps-ref at the capped tree: covered, exit 0" "$RC" 0; has "covered line names the ref read" "$OUT" "read at HEAD"; has "covered line shows the active bounds" "$OUT" "bounds lock<=3000ms statement<=120000ms"
run --caps-ref nosuchref
check "--caps-ref with a bad ref: exit 1" "$RC" 1
CM_DMC_MAX_STATEMENT_MS=300000 covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D200000"' 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D200000"'
check "a bound raised from the environment is clamped to the default: stop, exit 3" "$RC" 3
CM_DMC_MAX_STATEMENT_MS=60000 covrepo "$CAPPED_URL" "$CAPPED_URL"
check "a bound tightened from the environment is honoured (120000 cap > 60000): stop, exit 3" "$RC" 3

# 44. review round: every bypass it reproduced must stay a STOP
capurl() { printf 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=%s"' "$1"; }
for o in '-c%20lock_timeout%3D1h%20-c%20statement_timeout%3D120000' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D2d' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-clock_timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20--lock-timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-c%20LOCK_TIMEOUT%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-c%20lock-timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-c%20Statement_Timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-c' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-c%20lock_timeout' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%0A-c%20lock_timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%09-c%20lock_timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%0B-c%20lock_timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%00-c%20lock_timeout%3D0' \
         '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%0D-c%20lock_timeout%3D0'; do
  covrepo "$(capurl "$o")" "$(capurl "$o")"
  check "options '$o': stop, exit 3" "$RC" 3
done
covrepo "$(capurl '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-c%20search_path%3Dpublic')" "$(capurl '-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000%20-c%20search_path%3Dpublic')"
check "an unrelated -c setting next to the caps still counts: exit 0" "$RC" 0
covrepo "$(capurl '-c%20lock_timeout%3D3s%20-c%20LOCK_TIMEOUT%3D2s%20-c%20statement_timeout%3D120000')" "$(capurl '-c%20lock_timeout%3D3s%20-c%20LOCK_TIMEOUT%3D2s%20-c%20statement_timeout%3D120000')"
check "a later same-name cap wins and is within bounds: exit 0" "$RC" 0

# SET LOCAL and the other ways a plain file changes its own timeouts
for sql in "SET LOCAL lock_timeout = 0;
SELECT 1;" "SET LOCAL statement_timeout = '10min';
SELECT 1;" "SET SESSION lock_timeout TO 0;
SELECT 1;" "SELECT 1;
RESET statement_timeout;"; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$sql"; run
  check "a plain file that changes its own timeout is not covered: exit 3 ($(printf '%s' "$sql" | head -1))" "$RC" 3
done

# the options key must be exactly options
covrepo 'DB_URL="postgresql://u:p'"$AT"'h:5432/db?application_options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D1000&options=-c%20lock_timeout%3D0"' 'DB_URL="postgresql://u:p'"$AT"'h:5432/db?application_options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D1000&options=-c%20lock_timeout%3D0"'
check "a longer key that ends in options is not options: exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://u:p'"$AT"'h:5432/db?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D1000&options=-c%20lock_timeout%3D0"' 'DB_URL="postgresql://u:p'"$AT"'h:5432/db?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D1000&options=-c%20lock_timeout%3D0"'
check "two options parameters: stop, exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres"' 'DB_URL="postgresql://postgres@db.x:5432/postgres"'
check "a URL with no query string: stop, exit 3" "$RC" 3

# workflow parsing fails closed
covrepo "$CAPPED_URL" "$CAPPED_URL" 'echo go && supabase db push --db-url "postgresql://x/p"'
check "a push chained after && is not a clean push: stop, exit 3" "$RC" 3
covrepo "$CAPPED_URL" "$CAPPED_URL" 'npx supabase@2.67.1 db push --db-url "$DB_URL"'
check "a push behind npx is not a clean push: stop, exit 3" "$RC" 3
covrepo "$CAPPED_URL" "$CAPPED_URL" 'supabase db push --db-url "$DB_URL" --db-url "postgresql://x/p"'
check "two --db-url flags: stop, exit 3" "$RC" 3
covrepo "$CAPPED_URL" "$CAPPED_URL" 'echo "next: supabase db push"'
check "any other line that mentions db push fails closed: stop, exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" 'DB_URL+="%20-c%20lock_timeout%3D0"' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "a NAME+= append: stop, exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" 'DB_URL=postgresql://x/p' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "the URL variable assigned twice in a step (if/else): stop, exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" 'echo no url here' "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "a variable with no assignment in the step: stop, exit 3" "$RC" 3

newrepo; wfput "$WP" "- name: Run supabase db push" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "a step name that mentions db push does not block a cover: exit 0" "$RC" 0
newrepo; wfput "$WP" "$CAPPED_URL" '- item' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "any shell the allowlist does not know inside the push step (a '- item' line) is refused: exit 3" "$RC" 3
newrepo; wfput "$WP" 'DB_URL="postgresql://u@h:5432/db?"' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "a URL that ends in ? (empty query): stop, exit 3, no crash" "$RC" 3
newrepo; wfput "$WP" 'DB_URL="postgresql://u@h:5432/db?options="' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "an empty options= value: stop, exit 3, no crash" "$RC" 3

newrepo; wfput "$WP" 'OPTIONAL_SECRETS+=("A=${B}")' "$CAPPED_URL" "$PUSH"; wfput "$WS" 'OPTIONAL_SECRETS+=("A=${B}")' "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "any shell the allowlist does not know inside the push step (an append) is refused: exit 3" "$RC" 3
newrepo; mkdir -p "$D/.github/workflows"
printf 'steps:\n  - run: |\n      OPTIONAL_SECRETS+=("A=${B}")\n  - run: |\n      %s\n      %s\n' "$CAPPED_URL" "$PUSH" > "$D/$WP"
printf 'steps:\n  - run: |\n      %s\n      %s\n' "$CAPPED_URL" "$PUSH" > "$D/$WS"; ( cd "$D" && git add . && git_q commit -q -m wf ) >/dev/null; BASE="$(git -C "$D" rev-parse HEAD)"
addmig 88000000000002_a.sql "SELECT 1;"; run
check "an append in ANOTHER step does not block a cover: exit 0" "$RC" 0

# 45. re-verdict: URL query keys, single-use plain variable, folded run, function SET clause
CAPS_Q='options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000'
urlq() { printf 'DB_URL="postgresql://postgres@db.x:5432/postgres?%s"' "$1"; }
for q in "$CAPS_Q&lock_timeout=0&statement_timeout=0" "sslmode=require#&$CAPS_Q" "%6Fptions=-c%20lock_timeout%3D0&$CAPS_Q" "$CAPS_Q&search_path=x" "$CAPS_Q&options=-c%20lock_timeout%3D0"; do
  covrepo "$(urlq "$q")" "$(urlq "$q")"
  check "query '$q': stop, exit 3" "$RC" 3
done
covrepo "$(urlq "sslmode=require&$CAPS_Q")" "$(urlq "application_name=x&$CAPS_Q")"
check "whitelisted sibling keys (sslmode, application_name) still cover: exit 0" "$RC" 0
for extra in 'declare DB_URL="postgresql://x/p"' 'printf -v DB_URL %s "postgresql://x/p"' '[ -n "$X" ] && DB_URL="postgresql://x/p"' 'export DB_URL'; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$extra" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
  check "the URL variable is touched again ($extra): stop, exit 3" "$RC" 3
done
newrepo; wfput "$WP" 'DB_URL="${SUPABASE_DB_URL:-postgresql://postgres@db.x:5432/postgres?'"$CAPS_Q"'}"' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "a ':-' default expansion in the URL value is not a plain literal: stop, exit 3" "$RC" 3
newrepo; wfput "$WP" 'DB_URL="postgresql://postgres@db.x:5432/postgres?'"$CAPS_Q"'$(cat /x)"' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "a command substitution in the URL value: stop, exit 3" "$RC" 3
newrepo; mkdir -p "$D/.github/workflows"
printf 'steps:\n  - env:\n      DB_URL: ${{ secrets.X }}\n    run: >\n      %s\n      %s\n' "$CAPPED_URL" "$PUSH" > "$D/$WP"; cp "$D/$WP" "$D/$WS"; ( cd "$D" && git add . && git_q commit -q -m wf ) >/dev/null; BASE="$(git -C "$D" rev-parse HEAD)"
addmig 88000000000002_a.sql "SELECT 1;"; run
check "a folded run: > block: stop, exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf 'CREATE FUNCTION f() RETURNS int LANGUAGE sql SET lock_timeout = 0 AS $$ SELECT 1 $$;\nSELECT f();\n')"; run
check "CREATE FUNCTION ... SET lock_timeout: not covered, exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf 'ALTER FUNCTION f() SET statement_timeout = 0;\n')"; run
check "ALTER FUNCTION ... SET statement_timeout: not covered, exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf -- '-- lock_timeout in a comment only\nSELECT 1;\n')"; run
check "a timeout named only in a comment does not block the cover: exit 0" "$RC" 0
CM_DMC_MAX_LOCK_MS=3000 covrepo "$CAPPED_URL" "$CAPPED_URL"
has "an environment override is announced in the covered lines" "$OUT" "come from CM_DMC_* in the environment"

# 46. second review: dynamic SQL, unquoted value with spaces, expansion in the query
for sql in "$(printf 'DO $$ BEGIN EXECUTE %s; END $$;\n' "'SET lock_' || 'timeout = 0'")" 'DISCARD ALL;' 'RESET ALL;' "$(printf 'DO $$ BEGIN PERFORM 1; END $$;\nEXECUTE x;\n')" "$(printf 'DO $$ DECLARE function_sql text; BEGIN function_sql := %s; EXECUTE function_sql; END $$;\n' "'SET statement_' || 'timeout = 0'")" "$(printf 'DO $$ DECLARE procedure_sql text; BEGIN procedure_sql := %s; EXECUTE procedure_sql; END $$;\n' "'SET lock_' || 'timeout = 0'")"; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$sql"; run
  check "dynamic SQL or a session reset is not covered ($(printf '%s' "$sql" | head -c 30)): exit 3" "$RC" 3
done
UNQ='DB_URL=postgresql://postgres@db.x:5432/postgres?options=-c lock_timeout=3s -c statement_timeout=120000'
covrepo "$UNQ" "$UNQ"
check "an unquoted URL value with spaces is not one shell word: exit 3" "$RC" 3
covrepo 'DB_URL="postgresql://postgres@db.${DB_REF}.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"' 'DB_URL="postgresql://postgres@db.${DB_REF}.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"'
check "an expansion in the host still covers: exit 0" "$RC" 0
covrepo 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000${EXTRA}"' 'DB_URL="postgresql://postgres@db.x:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000${EXTRA}"'
check "an expansion in the query is not covered: exit 3" "$RC" 3

# 47. third review: GRANT EXECUTE and strings are not dynamic SQL, a stale branch, one proof for many files, reasons
for sql in 'CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$; GRANT EXECUTE ON FUNCTION f() TO authenticated;' "COMMENT ON TABLE t IS 'I will execute this';" 'DO $$ BEGIN GRANT EXECUTE ON FUNCTION f() TO authenticated; END $$;'; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$sql"; run
  check "GRANT EXECUTE or a string saying execute does not block the cover ($(printf '%s' "$sql" | head -c 30)): exit 0" "$RC" 0
done
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; addmig 88000000000003_b.sql "SELECT 2;"; run
check "two covered files: exit 0" "$RC" 0
check "the workflow proof is printed once for two covered files" "$(printf '%s\n' "$OUT" | grep -c 'deploy-production.yml:')" 1
newrepo; wfput "$WP" 'DB_URL=postgresql://x/p' "$PUSH"; wfput "$WS" 'DB_URL=postgresql://x/p' "$PUSH"; STALE="$BASE"
wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; MAINT="$(git -C "$D" rev-parse HEAD)"
git -C "$D" checkout -q -b stale "$STALE"; addmig 88000000000002_a.sql "SELECT 1;"; BASE="$STALE"; run --caps-ref "$MAINT"
check "a branch behind main (stale workflows, range untouched) is judged by the caps ref: covered, exit 0" "$RC" 0
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$(printf 'SET lock_timeout = 0;\nSELECT 1;\n')"; run
has "a stop on a file that touches a timeout says why it is not covered" "$OUT" "not covered: the file touches a timeout"
newrepo; wfput "$WP" 'DB_URL=postgresql://x/p' "$PUSH"; wfput "$WS" 'DB_URL=postgresql://x/p' "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
has "a stop with no caps in the workflows says why" "$OUT" "not covered: the deploy workflows do not carry the caps"

# 48. fourth review: quoted bodies, forgotten --caps-ref, pooler, --no-cover, CM_DMC_WORKFLOWS, comments, EXECUTE FUNCTION, parser reason
for sql in "create function f() returns void language plpgsql as 'begin execute format(''set %s_timeout = 0'', ''lock''); end'; select f();" "create function f() returns void language plpgsql as 'begin reset all; end';" "DO 'begin reset all; end';"; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$sql"; run
  check "a function or DO body in a quoted string is not covered ($(printf '%s' "$sql" | head -c 30)): exit 3" "$RC" 3
done
newrepo; wfput "$WP" 'DB_URL=postgresql://x/p' "$PUSH"; wfput "$WS" 'DB_URL=postgresql://x/p' "$PUSH"
WF_KEEP_BASE=1 wfput "$WP" "$CAPPED_URL" "$PUSH"; WF_KEEP_BASE=1 wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; RUNARGS=(); run; RUNARGS=(--caps-ref HEAD)
check "PR adds the caps itself and --caps-ref is forgotten: exit 3" "$RC" 3
POOL='DB_URL="postgresql://postgres@aws-0-eu-west-2.pooler.supabase.com:6543/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000"'
covrepo "$POOL" "$POOL"
check "a pooler URL is not covered: exit 3" "$RC" 3; has "the stop names the pooler" "$OUT" "pooler host or port 6543"
covrepo "$CAPPED_URL" "$CAPPED_URL" ; run --no-cover
check "--no-cover turns the cover off: exit 3" "$RC" 3; has "--no-cover is named in the reason" "$OUT" "--no-cover was given"
CM_DMC_WORKFLOWS=".github/workflows/deploy-staging.yml" covrepo "$CAPPED_URL" "$CAPPED_URL"
check "an ambient CM_DMC_WORKFLOWS cannot drop a workflow from the cover: exit 3" "$RC" 3
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf 'CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$\nBEGIN\n-- callers execute it via rpc\nRETURN 1;\nEND $$;\n')"; run
check "a comment saying execute inside a body does not block the cover: exit 0" "$RC" 0
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
addmig 88000000000002_a.sql "$(printf 'DO $$ BEGIN CREATE TRIGGER t AFTER INSERT ON x FOR EACH ROW EXECUTE FUNCTION g(); END $$;\n')"; run
check "EXECUTE FUNCTION in a trigger inside a DO body does not block the cover: exit 0" "$RC" 0
newrepo; wfput "$WP" "$CAPPED_URL" 'echo "Using $DB_URL"' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "an extra mention of the URL variable fails closed: exit 3" "$RC" 3

# 49. independent verdict: CLI query decoding, a push line the parser cannot see, deploy callers pass --caps-ref
OPTS='options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000'
for sfx in '%20-c%20application_name%3Da;b' '%20-c%20application_name%3D%zz' '%20-c%20application_name%3Dx+-c+lock_timeout%3D0' '%20-c%20application_name%3D%2'; do
  U="DB_URL=\"postgresql://postgres@db.x:5432/postgres?$OPTS$sfx\""
  covrepo "$U" "$U"
  check "the CLI would drop or re-decode this query ($sfx): stop, exit 3" "$RC" 3
done
for pl in 'supabase "db" push --include-all' "supabase db 'push' --include-all" 'supabase db pu""sh --include-all'; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH" "$pl"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
  check "a second push in a shape the parser cannot read ($pl): stop, exit 3" "$RC" 3
done
DOCS="$HERE/../.."
if grep -q 'deploy-migration-check.sh {{from_tag}} {{main_sha}} --caps-ref {{main_sha}}' "$DOCS/references/lanes.md"; then check "the deploy worker brief passes --caps-ref" 0 0; else check "the deploy worker brief passes --caps-ref" 1 0; fi
if grep -q 'deploy-migration-check.sh <tag> <pinned sha> --caps-ref <pinned sha>' "$DOCS/SKILL.md"; then check "the SKILL.md deploy call passes --caps-ref" 0 0; else check "the SKILL.md deploy call passes --caps-ref" 1 0; fi

# 50. second independent verdict: the push step is an allowlist (N1 to N5)
n1() { newrepo; wfput "$WP" "$CAPPED_URL" "$@"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run; }
n1 "$PUSH || supabase db push --include-all"
check "N1 an uncapped fallback after the capped push: exit 3" "$RC" 3
newrepo; wfput "$WP" "DB_URL=\"postgresql://postgres@db.example.supabase.co:5432/postgres?options=-c%20lock_timeout%3D3s%20-c%20statement_timeout%3D120000\" DB_URL=\"postgresql://postgres@db.example.supabase.co:5432/postgres\"" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run
check "N2 two assignments on one line: exit 3" "$RC" 3
n1 'CMD=push' "$CAPPED_URL" "$PUSH" 'supabase db $CMD --include-all'
check "N3 the subcommand in a variable: exit 3" "$RC" 3
n1 'sb() { supabase "$@"; }' "$PUSH" 'sb db "push" --include-all'
check "N4 a wrapper function: exit 3" "$RC" 3
n1 "$PUSH" 'supabase migration up --linked --include-all'
check "N5 another command that applies migrations: exit 3" "$RC" 3
n1 "$PUSH" 'supabase db reset --linked'
check "supabase db reset: exit 3" "$RC" 3
n1 "$PUSH" 'psql "$X" -f supabase/migrations/a.sql'
check "psql -f: exit 3" "$RC" 3
n1 "$PUSH" 'psql "$X" -c "select 1"' 
check "psql -c in the push step is also refused (not on the allowlist): exit 3" "$RC" 3

# 51. third independent verdict: S1 to S4, byte-equal trees
# mstep <prod-yaml-file-content-printf-args...>: write both workflows from a multi-step layout, commit, move BASE past them
mwf() { newrepo; mkdir -p "$D/.github/workflows"; printf "$1" "${@:2}" > "$D/$WP"; cp "$D/$WP" "$D/$WS"; ( cd "$D" && git add . && git_q commit -q -m wf ) >/dev/null; BASE="$(git -C "$D" rev-parse HEAD)"; addmig 88000000000002_a.sql "SELECT 1;"; run; }
n1 'CMD=push' 'X="$(supabase db $CMD --include-all)"' "$CAPPED_URL" "$PUSH"
check "S1 a command substitution inside an assignment: exit 3" "$RC" 3
mwf 'steps:\n  - run: |\n      psql "$PSQL_URL" < supabase/migrations/88000000000002_a.sql\n  - run: |\n      %s\n      %s\n' "$CAPPED_URL" "$PUSH"
check "S2 psql reading a migration from stdin in another step: exit 3" "$RC" 3
n1 'true: || psql $PSQL_URL < supabase/migrations/88000000000002_a.sql' "$CAPPED_URL" "$PUSH"
check "S3 a shell line shaped like a YAML key inside the run block: exit 3" "$RC" 3
mwf 'steps:\n  - env:\n      BASH_ENV: ./ci/shim.sh\n    run: |\n      %s\n      %s\n' "$CAPPED_URL" "$PUSH"
check "S4 BASH_ENV in the push step env: exit 3" "$RC" 3
mwf 'steps:\n  - env:\n      PGPASSWORD: x\n      DB_REF: y\n    run: |\n      psql "$PSQL_URL" <<EOSQL\n      select 1;\n      EOSQL\n  - env:\n      PGPASSWORD: x\n    run: |\n      %s\n      %s\n' "$CAPPED_URL" "$PUSH"
check "a heredoc psql step and PGPASSWORD env still cover: exit 0" "$RC" 0
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
WF_KEEP_BASE=1 wfput "$WP" "$CAPPED_URL" 'echo unrelated edit' "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; run --caps-ref "$BASE"
check "a PR that edits a workflow (even keeping the caps) differs from the caps ref: exit 3" "$RC" 3; has "the stop says why" "$OUT" "the head differs from"

# 52. fourth verdict: set_config inside a dropped body
for sql in "$(printf 'CREATE FUNCTION public.tmp_relax() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM set_config(%s, %s, true); END $$;\nSELECT public.tmp_relax();\n' "'lock' || '_timeout'" "'0'")" "$(printf 'DO $$ BEGIN PERFORM set_config(%s, %s, true); END $$;\n' "'statement' || '_timeout'" "'0'")" "$(printf 'DO $$ BEGIN UPDATE pg_settings SET setting = %s; END $$;\n' "'0'")"; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$sql"; run
  check "set_config or pg_settings inside a dollar body is not covered ($(printf '%s' "$sql" | head -c 40 | tr '\n' ' ')): exit 3" "$RC" 3
done

# 53. fifth verdict: U& escaped identifiers inside a dollar body
for sql in "$(printf 'DO $$ BEGIN PERFORM U&"set\\005fconfig"(%s, %s, true); END $$;\n' "'lock' || '_timeout'" "'0'")" "$(printf 'DO $$ BEGIN SET LOCAL U&"lock\\005ftimeout" = 0; END $$;\n')" "$(printf 'CREATE FUNCTION public.tmp_r2() RETURNS void LANGUAGE plpgsql AS $$ BEGIN SET LOCAL U&"statement\\005ftimeout" = 0; END $$;\nSELECT public.tmp_r2();\n')"; do
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$sql"; run
  check "a U& escaped identifier inside a dollar body is not covered ($(printf '%s' "$sql" | head -c 40 | tr '\n' ' ')): exit 3" "$RC" 3
done

# the range check and the ref reading hold from a subdirectory
newrepo; WF_KEEP_BASE=1 wfput "$WP" "$CAPPED_URL" "$PUSH"; WF_KEEP_BASE=1 wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"
mkdir -p "$D/supabase"; OUT="$(cd "$D/supabase" && bash "$SCRIPT" "$BASE" HEAD --caps-ref "$BASE" 2>&1)"; RC=$?
check "a range that adds the caps is refused from a subdirectory too: exit 3" "$RC" 3
covrepo "$CAPPED_URL" "$CAPPED_URL"; OUT="$(cd "$D/supabase" || exit 1; bash "$SCRIPT" "$BASE" HEAD --caps-ref HEAD 2>&1)"; RC=$?
check "a covered file from a subdirectory: exit 0" "$RC" 0

# 54. TWO MODES: strict at the PR merge gate (no --caps-ref), cover at deploy time only (--caps-ref).
# The same unguarded file is STOP / exit 3 without --caps-ref and covered / exit 0 with it; a guarded file is ok in both.
# Both workflows carry the caps in every case below, so the ONLY thing that differs between the two runs is the mode.
fwindow() { # the shape of a real file that cost a deploy window: a long comment header, a SECURITY DEFINER function with a
          # plpgsql body, grants, a policy swap and a trigger; no transaction control and no timeout anywhere
  printf '%s\n' '-- Note writes need real standing in the group and a note belongs to the group of its author' \
    '-- WHY. an outsider who knows a group id can put a published note into that group board.' \
    'CREATE OR REPLACE FUNCTION public.can_write_note_for_group(p_group_id uuid) RETURNS boolean' \
    "LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS \$\$" \
    'BEGIN' '  IF auth.uid() IS NULL THEN RETURN false; END IF;' '  RETURN EXISTS (SELECT 1 FROM public.group_members gm WHERE gm.group_id = p_group_id);' 'END;' '$$;' \
    'REVOKE ALL ON FUNCTION public.can_write_note_for_group(uuid) FROM PUBLIC, anon;' \
    'GRANT EXECUTE ON FUNCTION public.can_write_note_for_group(uuid) TO authenticated;' \
    'DROP POLICY IF EXISTS notes_manage ON public.notes;' \
    'CREATE POLICY notes_manage ON public.notes USING (public.can_write_note_for_group(group_id)) WITH CHECK (public.can_write_note_for_group(group_id));' \
    'DROP TRIGGER IF EXISTS notes_guard_group ON public.notes;' \
    'CREATE TRIGGER notes_guard_group BEFORE INSERT OR UPDATE OF group_id ON public.notes FOR EACH ROW EXECUTE FUNCTION public.notes_guard_group_matches_author();'
}
modes() { # <label> <file text>: run the file in both modes, workflows capped; sets PR_RC PR_OUT DP_RC DP_OUT
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$2"
  RUNARGS=(); run; PR_RC=$RC; PR_OUT="$OUT"
  RUNARGS=(--caps-ref HEAD); run; DP_RC=$RC; DP_OUT="$OUT"
}
modes unguarded "SELECT 1 FROM $MARK;"
check "unguarded file, PR mode (no --caps-ref): STOP, exit 3" "$PR_RC" 3
has   "unguarded file, PR mode: the stop line" "$PR_OUT" "stop $F1 reason=no BEGIN; and COMMIT;"
has   "unguarded file, PR mode: the text tells the author to add the in-file guard" "$PR_OUT" "add the in-file guard: BEGIN; SET LOCAL lock_timeout = '3s'; SET LOCAL statement_timeout = '30s'"
hasnt "unguarded file, PR mode: never reported covered" "$PR_OUT" "covered (connection caps)"
hasnt "unguarded file, PR mode: the summary has no covered file" "$PR_OUT" "covered=1"
hasnt "unguarded file, PR mode: the caps are not offered as a way out (no options= or push step advice)" "$PR_OUT" "options="
hasnt "unguarded file, PR mode: the final note does not send the author to the push step" "$PR_OUT" "push step"
has   "unguarded file, PR mode: the final note says the gate is strict" "$PR_OUT" "strict"
has   "unguarded file, PR mode: the output names the mode" "$PR_OUT" "mode: pr-gate (strict"
has   "unguarded file, PR mode: the note keeps the applied-file caution" "$PR_OUT" "do NOT edit the file"
check "unguarded file, deploy mode (--caps-ref): covered, exit 0" "$DP_RC" 0
has   "unguarded file, deploy mode: the covered line" "$DP_OUT" "covered (connection caps): $F1"
has   "unguarded file, deploy mode: the output names the mode" "$DP_OUT" "mode: deploy (--caps-ref HEAD"

modes winloss "$(fwindow)"
check "window-loss-shaped file, PR mode: STOP, exit 3" "$PR_RC" 3
has   "window-loss-shaped file, PR mode: add the in-file guard" "$PR_OUT" "add the in-file guard"
hasnt "window-loss-shaped file, PR mode: never covered" "$PR_OUT" "covered (connection caps)"
check "window-loss-shaped file, deploy mode: covered, exit 0" "$DP_RC" 0
has   "window-loss-shaped file, deploy mode: the covered line" "$DP_OUT" "covered (connection caps): $F1"

modes guarded "$(guard "'3s'" "'30s'")"
check "guarded file, PR mode: ok, exit 0" "$PR_RC" 0; has "guarded file, PR mode: ok line" "$PR_OUT" "ok $F1"
check "guarded file, deploy mode: ok, exit 0" "$DP_RC" 0; has "guarded file, deploy mode: ok line" "$DP_OUT" "ok $F1"
hasnt "guarded file: not reported covered in either mode" "$PR_OUT$DP_OUT" "covered (connection caps)"

modes half "$(printf '%s\nSELECT 1;\n' "$BG")"
check "half transaction: STOP in PR mode" "$PR_RC" 3; check "half transaction: STOP in deploy mode too" "$DP_RC" 3

# --no-cover and a base branch other than the default one change nothing in PR mode; an explicit --caps-ref plus --no-cover is a stop with a reason
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"
RUNARGS=(); run --no-cover; check "PR mode with --no-cover: STOP, exit 3" "$RC" 3; has "PR mode with --no-cover: add the in-file guard" "$OUT" "add the in-file guard"
RUNARGS=(--caps-ref HEAD); run --no-cover; check "deploy mode with --no-cover: STOP, exit 3" "$RC" 3
# an ask is still an ask (exit 2) in both modes
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "$(guard "'5s'" "'120s'")"
RUNARGS=(); run; check "ask file, PR mode: exit 2" "$RC" 2
RUNARGS=(--caps-ref HEAD); run; check "ask file, deploy mode: exit 2" "$RC" 2

# Mutant helper (one place for every mutation check below): mutant <name> <sed args...> builds $ROOT/mutant-<name>.sh from the script with
# the HERE= line pinned to the real scripts directory (a copy under $ROOT cannot find lib.sh by dirname $0), then applies the sed args.
# Returns 1 when the sed args changed nothing, so a mutation that no longer matches the script fails loudly instead of passing vacuously.
mutant() {
  MUTF="$ROOT/mutant-$1.sh"; shift
  sed -e "s|^HERE=.*|HERE=\"$(dirname "$SCRIPT")\"|" "$SCRIPT" > "$MUTF.base"
  sed "$@" "$MUTF.base" > "$MUTF"
  ! cmp -s "$MUTF.base" "$MUTF"
}

# a plain file that touches a timeout or runs dynamic SQL: in PR mode the answer is the add-the-in-file-guard STOP and never "not covered"
# (that wording implies a cover exists); in deploy mode it is still "not covered: ..." with the reason
tamper_n=0
for sql in "$(printf 'SET lock_timeout = 0;\nSELECT 1;\n')" "$(printf 'DO $$ BEGIN EXECUTE %s; END $$;\n' "'SELECT 1'")" 'DISCARD ALL;' 'RESET ALL;'; do
  tamper_n=$((tamper_n + 1)); modes "tamper$tamper_n" "$sql"
  check "tamper file $tamper_n, PR mode: STOP, exit 3" "$PR_RC" 3
  has   "tamper file $tamper_n, PR mode: add the in-file guard" "$PR_OUT" "add the in-file guard: BEGIN; SET LOCAL lock_timeout = '3s'"
  hasnt "tamper file $tamper_n, PR mode: never says not covered" "$PR_OUT" "not covered"
  hasnt "tamper file $tamper_n, PR mode: never covered" "$PR_OUT" "covered (connection caps)"
  check "tamper file $tamper_n, deploy mode: STOP, exit 3" "$DP_RC" 3
  has   "tamper file $tamper_n, deploy mode: says why it is not covered" "$DP_OUT" "not covered: the file touches a timeout"
done

# mutation check: make the PR mode covered (the strict branch removed) and the PR-mode tests above must fail
if ! mutant pr-covered -e 's|if \[ "\$CAPS_EXPLICIT" = no \]; then|if false; then|'; then bad "mutation: the sed no longer matches the script (update this test)"; else
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1 FROM $MARK;"
  MOUT="$(cd "$D" && bash "$MUTF" "$BASE" HEAD 2>&1)"; MRC=$?
  if [ "$MRC" = 0 ] && case "$MOUT" in *"covered (connection caps)"*) true ;; *) false ;; esac; then ok "mutation: with the PR mode made covered the unguarded file exits 0, so the PR-mode STOP tests above fail"
  else bad "mutation: the mutant did not turn the PR mode covered (rc=$MRC)" "$MOUT"; fi
fi
# mutation check: put the tamper test back before the strict test (the old order) and the PR-mode tamper file prints "not covered"
if ! mutant tamper-first -e 's/if \[ "\$CAPS_EXPLICIT" = no \]; then/if timeout_tamper "$body"; then NOTCOV="not covered: the file touches a timeout or runs dynamic SQL (EXECUTE, DISCARD, RESET ALL)"; elif [ "$CAPS_EXPLICIT" = no ]; then/'; then bad "mutation: the tamper-first sed no longer matches the script (update this test)"; else
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "RESET ALL;"
  MOUT="$(cd "$D" && bash "$MUTF" "$BASE" HEAD 2>&1)"; MRC=$?
  if [ "$MRC" = 3 ] && case "$MOUT" in *"not covered"*) true ;; *) false ;; esac; then ok "mutation: with the tamper check first, PR mode prints \"not covered\", so the tamper PR-mode tests above fail"
  else bad "mutation: the tamper-first mutant did not print \"not covered\" in PR mode (rc=$MRC)" "$MOUT"; fi
fi
# mutation check: strip "EXECUTE function"/"EXECUTE procedure" by prefix again (the old regex) and a dynamic EXECUTE of a variable named function_sql reads as covered
if ! mutant exec-prefix -e 's|gsub(/execute\[ \\t\]+(function\|procedure)(\[ \\t\]\|\$)/, " ", lc)|gsub(/execute[ \\t]+(function\|procedure)/, "", lc)|'; then bad "mutation: the exec-prefix sed no longer matches the script (update this test)"
else
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"
  addmig 88000000000002_a.sql "$(printf 'DO $$ DECLARE function_sql text; BEGIN function_sql := %s; EXECUTE function_sql; END $$;\n' "'SET statement_' || 'timeout = 0'")"
  MOUT="$(cd "$D" && bash "$MUTF" "$BASE" HEAD --caps-ref HEAD 2>&1)"; MRC=$?
  if [ "$MRC" = 0 ] && case "$MOUT" in *"covered (connection caps)"*) true ;; *) false ;; esac; then ok "mutation: with the prefix strip, EXECUTE function_sql reads as covered, so the dynamic-SQL tests above fail"
  else bad "mutation: the exec-prefix mutant did not report the dynamic file as covered (rc=$MRC)" "$MOUT"; fi
fi
RUNARGS=()

# 55. an empty or whitespace-only --caps-ref is refused (exit 1) in either argument order; it must not turn deploy mode on
#     with the caps ref defaulting to the PR head (a PR that caps its own workflows would then read as covered)
newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"
raw() { OUT="$(cd "$D" && bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
for NAME in empty space tab; do
  case "$NAME" in empty) CV="" ;; space) CV="  " ;; tab) CV=$'\t' ;; esac
  raw "$BASE" HEAD --caps-ref "$CV"; check "empty --caps-ref [$NAME] after the refs: exit 1" "$RC" 1
  hasnt "empty --caps-ref [$NAME] after the refs: never covered" "$OUT" "covered (connection caps)"
  has   "empty --caps-ref [$NAME] after the refs: says why" "$OUT" "--caps-ref needs a non-empty ref"
  raw --caps-ref "$CV" "$BASE" HEAD; check "empty --caps-ref [$NAME] before the refs: exit 1" "$RC" 1
  hasnt "empty --caps-ref [$NAME] before the refs: never covered" "$OUT" "covered (connection caps)"
done
raw "$BASE" HEAD --caps-ref HEAD; check "--caps-ref HEAD stays valid deploy mode: covered, exit 0" "$RC" 0
has "--caps-ref HEAD stays valid deploy mode: covered line" "$OUT" "covered (connection caps): $F1"
raw --caps-ref HEAD "$BASE" HEAD; check "--caps-ref HEAD before the refs: covered, exit 0" "$RC" 0

# mutation check: remove the guard and the empty-value tests above must fail
if ! mutant empty-caps -e '/--caps-ref needs a non-empty ref/d'; then bad "mutation: the sed no longer matches the script (update this test)"; else
  MOUT="$(cd "$D" && bash "$MUTF" "$BASE" HEAD --caps-ref "" 2>&1)"; MRC=$?
  MOUT2="$(cd "$D" && bash "$MUTF" --caps-ref "" "$BASE" HEAD 2>&1)"; MRC2=$?
  if [ "$MRC" = 0 ] && [ "$MRC2" = 0 ] && case "$MOUT$MOUT2" in *"covered (connection caps)"*) true ;; *) false ;; esac; then ok "mutation: without the guard an empty --caps-ref exits 0 in both orders, so the exit-1 tests above fail"
  else bad "mutation: the mutant still refused an empty --caps-ref (rc=$MRC/$MRC2)" "$MOUT$MOUT2"; fi
fi

# 56. the cover follows the project's own layout: deploy.caps_workflows and deploy.migrations_dir (config or env)
RUNARGS=(--caps-ref HEAD)
if command -v yq >/dev/null 2>&1; then
  # two custom workflow paths, both capped: covered; one of them uncapped: a stop
  printf 'schema: concertmaster.config/v1\ndeploy:\n  caps_workflows:\n    - ci/ship-prod.yml\n    - ci/ship-stage.yml\n' > "$ROOT/caps-cfg.yaml"
  cfgrun() { OUT="$(cd "$D" && CM_CONFIG="$ROOT/caps-cfg.yaml" bash "$SCRIPT" "$BASE" HEAD --caps-ref HEAD 2>&1)"; RC=$?; }
  newrepo; wfput ci/ship-prod.yml "$CAPPED_URL" "$PUSH"; wfput ci/ship-stage.yml "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; cfgrun
  check "configured caps workflows, both capped: covered, exit 0" "$RC" 0; has "configured workflows: the first is quoted" "$OUT" "ci/ship-prod.yml:"; has "configured workflows: the second is quoted" "$OUT" "ci/ship-stage.yml:"
  newrepo; wfput ci/ship-prod.yml "$CAPPED_URL" "$PUSH"; wfput ci/ship-stage.yml 'DB_URL=postgresql://x/p' "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; cfgrun
  check "configured caps workflows, one uncapped: stop, exit 3" "$RC" 3
  # the default workflow paths are not read once the config names others
  newrepo; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"; cfgrun
  check "configured paths missing from the repo (defaults capped): stop, exit 3" "$RC" 3
  # one configured workflow is enough for a project with a single deploy workflow
  printf 'schema: concertmaster.config/v1\ndeploy:\n  caps_workflows: [ci/only.yml]\n' > "$ROOT/caps-cfg1.yaml"
  newrepo; wfput ci/only.yml "$CAPPED_URL" "$PUSH"; addmig 88000000000002_a.sql "SELECT 1;"
  OUT="$(cd "$D" && CM_CONFIG="$ROOT/caps-cfg1.yaml" bash "$SCRIPT" "$BASE" HEAD --caps-ref HEAD 2>&1)"; RC=$?
  check "a single configured caps workflow: covered, exit 0" "$RC" 0
  # a bad configured path fails closed
  for badwf in /abs/wf.yml ../out.yml 'a b.yml' 'a;b.yml'; do
    printf 'schema: concertmaster.config/v1\ndeploy:\n  caps_workflows: ["%s"]\n' "$badwf" > "$ROOT/caps-bad.yaml"
    newrepo; addmig 88000000000002_a.sql "SELECT 1;"
    OUT="$(cd "$D" && CM_CONFIG="$ROOT/caps-bad.yaml" bash "$SCRIPT" "$BASE" HEAD --caps-ref HEAD 2>&1)"; RC=$?
    check "bad caps workflow path '$badwf': exit 1" "$RC" 1; has "bad caps workflow path '$badwf': says so" "$OUT" "bad workflow path"
  done
else
  echo "skip the caps_workflows config cases: yq is not installed"
fi
# a custom migrations directory: the cover works there, and a psql read of that directory in a workflow refuses it
otherrepo db/migrate; wfput "$WP" "$CAPPED_URL" "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addat db/migrate 88000000000002_a.sql "SELECT 1;"
OUT="$(cd "$D" && CM_MIGRATIONS_DIR=db/migrate bash "$SCRIPT" "$BASE" HEAD --caps-ref HEAD 2>&1)"; RC=$?
check "a custom migrations directory, capped workflows: covered, exit 0" "$RC" 0; has "custom directory: the covered line names the file" "$OUT" "covered (connection caps): db/migrate/88000000000002_a.sql"
otherrepo db/migrate; wfput "$WP" "$CAPPED_URL" 'psql "$U" < db/migrate/88000000000001_old.sql' "$PUSH"; wfput "$WS" "$CAPPED_URL" "$PUSH"; addat db/migrate 88000000000002_a.sql "SELECT 1;"
OUT="$(cd "$D" && CM_MIGRATIONS_DIR=db/migrate bash "$SCRIPT" "$BASE" HEAD --caps-ref HEAD 2>&1)"; RC=$?
check "a workflow that feeds the custom migrations directory to psql: stop, exit 3" "$RC" 3
# the mode line and the covered count are always printed
newrepo; addmig 88000000000002_a.sql "$(guard "'3s'" "'30s'")"; RUNARGS=(); run
has "PR gate output names its mode" "$OUT" "mode: pr-gate"; has "PR gate output carries covered=0" "$OUT" "covered=0"
RUNARGS=(--caps-ref HEAD); run
has "deploy output names its mode" "$OUT" "mode: deploy (--caps-ref"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
