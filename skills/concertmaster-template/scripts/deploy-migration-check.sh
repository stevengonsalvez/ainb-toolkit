#!/usr/bin/env bash
# deploy-migration-check.sh: the deploy pre-check for the migrations a delta ADDS.
#
#   skills/concertmaster-template/scripts/deploy-migration-check.sh <from-ref> <to-ref> [--pr-body-file <file> --only <path>]...
#
# Run it from anywhere inside the repo (the pathspec is anchored at the repo top, so a subdirectory gives the same
# result as the root). <from-ref> is the last production tag, <to-ref> the pinned deploy sha (or origin/main). It lists
# only the files ADDED in that range under supabase/migrations/ (a modified older file is never re-flagged; a rename
# counts as added, because a new name is a new version that the push runs), reads each at <to-ref>, and prints one
# line per file:
#
#   ok         lock_timeout=3s statement_timeout=30s (or the equal forms 3000ms/3000 and 30000ms/30000; units are
#              case-sensitive, '3 s' and ' 3s' read as 3s), one BEGIN, one COMMIT, nothing but SET outside them
#   ask        a SET LOCAL lock_timeout that is not 3s, or a SET LOCAL statement_timeout that is not 30s, or one of the
#              two missing, a plain SET/RESET of either, a statement other than a SET before both SET LOCAL lines in
#              the window (guard=late), a set_config call naming either timeout, an UPDATE of pg_settings, any statement with a U& escaped name or string, or set_config with an E'..' string (set-timeout-call), a set_config call whose
#              first argument is not a plain quoted literal (set-config-dynamic), or either timeout named inside a
#              dollar-quoted string: in a CREATE/ALTER FUNCTION or PROCEDURE body (timeout-in-function), or in any
#              other one such as a DO block or COMMENT ... IS $$..$$ (timeout-in-body); an owner ASK, unless the PR
#              body records an exception
#   exception  an `ask` file whose PR body (--pr-body-file, which needs --only) has a line starting `timeout-exception:`
#              followed by a reason of 3 or more words; counts as ok. Lines inside fenced code (CommonMark rules: the
#              closer repeats the opener's character, at least as long, up to 3 spaces of indent, nothing after it)
#              and inside <!-- --> comments (at any column, across lines) are ignored
#   stop       no BEGIN; or no COMMIT; (COMMIT AND CHAIN is no COMMIT), or a shape that leaves a statement outside the timed window: a statement other
#              than a SET before BEGIN or after COMMIT (a NOTIFY after COMMIT is allowed), a second BEGIN, a COMMIT
#              before BEGIN, a ROLLBACK, a PREPARE TRANSACTION, COMMIT or END AND CHAIN (also split over lines); an exception
#              never covers a stop. Accepted forms: BEGIN [TRANSACTION|WORK] [modes], START
#              TRANSACTION [modes], COMMIT|END [TRANSACTION|WORK] [AND NO CHAIN]
#
# Every line reads `<status> <path> lock_timeout=<found|missing> statement_timeout=<found|missing>[ guard=late]
# [ set-timeout-call][ set-config-dynamic][ timeout-in-body][ timeout-in-function] exception=<recorded|none>` (a stop line reads `stop <path> reason=<what is wrong>`),
# then `<n> migration files examined` (always printed; 0 is fine when git reports no added migration), then a `summary:`
# line. A stop adds a `note:` line: if that version is already applied on staging, the migration file must NOT be edited
# (the migration runner tracks applied files by name and silently skips an edited one); the only fix is connection-level timeouts on
# the push step, for example PGOPTIONS='-c lock_timeout=3s -c statement_timeout=30s' in the workflow step that runs the
# push, or the db-url form (options=-c lock_timeout=3s -c statement_timeout=30s, URL-encoded). The CLI may ignore
# PGOPTIONS: prove the option reaches the session with a SHOW lock_timeout in the same session before relying on it.
# One recorded exception covers every flagged file the run examines, so --pr-body-file REQUIRES --only <path> for each file
# that PR added (repeatable; any other added file is skipped); for files from several PRs run it once per PR. The deploy
# worker does the same for each file the owner approved and treats any other exit 2 as an ask.
# The file is read one statement at a time: `/* */` (nested) and `--` comments are ignored, quoted strings are text, the
# body of a dollar-quoted string is dropped (but searched for either timeout name). An --only path that matches no added
# file is a bad argument (exit 1). A value that is not a plain token (letters, digits, dots) prints as <unparsed>: no
# SQL body is ever printed beyond the two timeout values.
#
# Exit: 0 every file ok or excepted (or no added migration), 2 any ask with no recorded exception, 3 any stop (outranks
#       2), 1 anything else: unreadable input, a bad range (a ref that does not resolve, or <from-ref> not an ancestor of
#       <to-ref>), a bad argument (an empty --only, one matching no added file, --pr-body-file without --only), an added
#       path git prints quoted, or a listing that disagrees with the full diff. ANY exit other than 0 blocks the window.
# NOT covered: a timeout set another way (ALTER ROLE/DATABASE, a function-level SET clause, dynamic SQL built from
# strings); a non-literal set_config inside a DO body (bodies are searched for the two timeout names only); anything
# after the first 4096 characters of one statement (SELECT '<5000 a>', set_config('lock_timeout', '0', true); reads ok);
# a session with standard_conforming_strings off (a backslash then escapes the quote in an ordinary string, which the
# scanner reads the standard way); a SQL-standard function body (BEGIN ATOMIC ... END, read as a stop); a guard added in
# the workflow step; and whether connection-level options reach the session. A SET LOCAL repeated in one file is
# judged on every occurrence, so one bad value flags the file.
# The migration directory is the supabase/migrations/ layout (files directly in it, ending .sql); a project with another
# layout changes the pathspec and MIG_RE below.
# Pure bash plus git, no network. Needs bash 3.2 or later. The deploy worker runs it on Linux (gawk or mawk); macOS
# one-true-awk is untested, and busybox awk does not finish a 10 MB one-line file in 240 s (a 1 MB line takes seconds).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { awk 'NR > 1 { if (/^#/) print; else exit }' "$0"; }

FROM=""; TO=""; BODY=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pr-body-file)
      [ $# -ge 2 ] || { cm_warn "deploy-migration-check.sh: --pr-body-file needs a file"; exit 1; }
      BODY="$2"; shift 2 ;;
    --only)
      [ $# -ge 2 ] || { cm_warn "deploy-migration-check.sh: --only needs a path"; exit 1; }
      [ -n "$2" ] || { cm_warn "deploy-migration-check.sh: --only needs a non-empty path"; exit 1; }
      ONLY="$ONLY$2"$'\n'; shift 2 ;;
    -*) cm_warn "deploy-migration-check.sh: unknown option: $1"; exit 1 ;;
    *)
      if [ -z "$FROM" ]; then FROM="$1"
      elif [ -z "$TO" ]; then TO="$1"
      else cm_warn "deploy-migration-check.sh: too many arguments"; exit 1; fi
      shift ;;
  esac
done
[ -n "$FROM" ] && [ -n "$TO" ] || { cm_warn "deploy-migration-check.sh: usage: <from-ref> <to-ref> [--pr-body-file <file>] [--only <path>]..."; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { cm_warn "deploy-migration-check.sh: not inside a git repository"; exit 1; }
for ref in "$FROM" "$TO"; do
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { cm_warn "deploy-migration-check.sh: bad ref: $ref"; exit 1; }
done
git merge-base --is-ancestor "$FROM" "$TO" 2>/dev/null || { cm_warn "deploy-migration-check.sh: bad range: $FROM is not an ancestor of $TO"; exit 1; }
if [ -n "$BODY" ] && [ ! -r "$BODY" ]; then cm_warn "deploy-migration-check.sh: PR body file not readable: $BODY"; exit 1; fi
if [ -n "$BODY" ] && [ -z "$ONLY" ]; then cm_warn "deploy-migration-check.sh: --pr-body-file needs --only <path> for each file that PR added (one exception line must not cover other PRs' files)"; exit 1; fi

# A recorded exception: a line that starts `timeout-exception:` followed by a reason of 3 or more words.
EXC=none
if [ -n "$BODY" ]; then
  n="$(tr -d '\r' < "$BODY" | awk '
    function fence(t,   n, c, k) {
      match(t, /^ */); n = RLENGTH; if (n > 3) return 0
      c = substr(t, n + 1, 1); if (c != "`" && c != "~") return 0
      k = 0; while (substr(t, n + k + 1, 1) == c) k++
      if (k < 3) return 0
      fch = c; flen = k; frest = substr(t, n + k + 1); return 1
    }
    function visible(t,   out, j) {
      out = ""
      while (t != "") {
        if (incm) { j = index(t, "-->"); if (!j) return out; t = substr(t, j + 3); incm = 0; continue }
        j = index(t, "<!--"); if (!j) return out t
        out = out substr(t, 1, j - 1); t = substr(t, j + 4); incm = 1
      }
      return out
    }
    infence { if (fence($0) && fch == ofch && flen >= olen && frest ~ /^[ \t]*$/) infence = 0; next }
    { v = visible($0) }
    fence(v) { infence = 1; ofch = fch; olen = flen; next }
    v ~ /^timeout-exception:/ { t = v; sub(/^timeout-exception:/, "", t); if (t ~ /[<>]/) next; c = split(t, w, " "); if (c > m) m = c }
    END { print m + 0 }')"
  [ "$n" -ge 3 ] && EXC=recorded
fi

# The file as one statement per line: CR, `--` comments and nested `/* */` comments removed, quoted strings (standard and
# E'..' escape strings) kept whole (a `/*`, `--` or `;` inside one is text), the body of a dollar-quoted string ($$ ... $$)
# dropped (a final `@@body-timeout-do` or `@@body-timeout-function` line says that a dropped DO-style or function body named either timeout), whitespace and newlines collapsed to one space, and a statement cut at each top-level `;` (the last one needs
# none). So a guard written only in a comment never counts, a second statement on one line is judged on its own, and a
# statement split over two lines is read whole. Text is scanned in runs through a 2048-character window (never a copy
# of the rest of the line) and only the first 4096 characters of real text of a statement are kept (whitespace does not
# count; every statement the checks read is far shorter), so a multi-megabyte INSERT is linear on gawk and mawk, even on
# one line (busybox awk reads a 1 MB line in seconds, but slows past a few MB on one line).
strip_sql() {
  LC_ALL=C awk '
    function emit(t) { gsub(/[ \t\r\f\v]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t); if (t != "" && t != ";") print t }
    function identch(ch) { return (ch ~ /[A-Za-z0-9_$]/ || ch > "\177") }
    function taglen(t,   j, ch) {
      for (j = 2; j <= 66; j++) {
        ch = substr(t, j, 1)
        if (ch == "$") return j
        if (ch ~ /[A-Za-z_]/ || ch > "\177") continue
        if (j > 2 && ch ~ /[0-9]/) continue
        return 0
      }
      return 0
    }
    function app(t) {
      if (length(cur) >= 4096) return
      gsub(/[ \t\r\f\v]+/, " ", t)
      if (t == "") return
      if (t == " " && (cur == "" || substr(cur, length(cur), 1) == " ")) return
      cur = cur t
    }
    BEGIN { st = 0; depth = 0; cur = ""; q = "\047"; reE = "[\\\\\047]"; reS = "\047"; W = 2048; K = 70 }
    { line = $0; sub(/\r$/, "", line); n = length(line); i = 1
      while (i <= n) {
        rest = substr(line, i, W); full = (length(rest) == W && i + W - 1 < n)
        if (st == 2) {
          if (!match(rest, /\/\*|\*\//)) { if (!full) break; i += W - 1; continue }
          if (substr(rest, RSTART, 2) == "*/") { depth--; if (depth == 0) { st = 0; app(" ") } } else depth++
          i += RSTART + 1; continue
        }
        if (st == 3 || st == 6) {
          if (!match(rest, st == 6 ? reE : reS)) { app(rest); if (!full) break; i += W; continue }
          p = RSTART
          app(substr(rest, 1, p))
          if (st == 6 && substr(rest, p, 1) == "\\") { app(substr(line, i + p, 1)); i += p + 1; continue }
          if (substr(line, i + p, 1) == q) { app(q); i += p + 1; continue }
          st = 0; i += p; continue
        }
        if (st == 4) {
          k = index(rest, "\"")
          if (!k) { app(rest); if (!full) break; i += W; continue }
          app(substr(rest, 1, k)); st = 0; i += k; continue
        }
        if (st == 5) {
          k = index(rest, tag)
          chunk = k ? substr(rest, 1, k - 1) : rest
          if (tolower(chunk) ~ /lock_timeout|statement_timeout/) { if (bodykind) hitfn = 1; else hitdo = 1 }
          if (!k) { if (!full) break; i += W - 70; continue }
          app(tag); st = 0; i += k + length(tag) - 1; continue
        }
        if (!match(rest, /[-\/\047"$;]/)) { app(rest); if (!full) break; i += W; continue }
        p = RSTART
        if (full && p > W - K) { app(substr(rest, 1, p - 1)); i += p - 1; continue }
        c = substr(rest, p, 1); c2 = substr(rest, p, 2)
        app(substr(rest, 1, p - 1))
        if (c2 == "--") break
        if (c2 == "/*") { st = 2; depth = 1; i += p + 1; continue }
        pc = (i + p - 2 >= 1) ? substr(line, i + p - 2, 1) : ""
        if (c == q) {
          ppc = (i + p - 3 >= 1) ? substr(line, i + p - 3, 1) : ""
          st = (pc ~ /[eE]/ && !identch(ppc)) ? 6 : 3
          app(q); i += p; continue
        }
        if (c == "\"") { st = 4; app(c); i += p; continue }
        if (c == "$") {
          s2 = substr(rest, p)
          tl = identch(pc) ? 0 : taglen(s2)
          if (tl) { tag = substr(s2, 1, tl); if (!kindset) { bodykind = (tolower(cur) ~ /^[ \t]*(create[ \t]+(or[ \t]+replace[ \t]+)?|alter[ \t]+)(function|procedure)/); kindset = 1 } app(tag); st = 5; i += p - 1 + tl; continue }
          app(c); i += p; continue
        }
        if (c == ";") { emit(cur ";"); cur = ""; kindset = 0; i += p; continue }
        app(c); i += p
      }
      app(" ")
    }
    END { emit(cur ";"); if (hitdo) print "@@body-timeout-do"; if (hitfn) print "@@body-timeout-function" }'
}
# Every value a SET LOCAL <key> gives, one per line, as written (case kept: units are case-sensitive), quotes, inner
# whitespace and the terminating `;` removed.
set_values() {
  awk -v key="$1" '
    { l = tolower($0); gsub(/"/, "", l); o = $0; gsub(/"/, "", o) }
    l ~ ("^[ \t]*set[ \t]+local[ \t]+" key "([ \t=]|$)") {
      match(l, ("^[ \t]*set[ \t]+local[ \t]+" key "[ \t]*"))
      s = substr(o, RLENGTH + 1)
      sub(/^(=|[Tt][Oo][ \t]+)[ \t]*/, "", s)
      sub(/[ \t]*;.*$/, "", s)
      gsub(/[\047]/, "", s)
      gsub(/[ \t]+/, "", s)
      print (s == "" ? "<empty>" : s)
    }'
}
# Transaction statement forms, as emitted by strip_sql (lower case, one statement, trailing `;`).
BEGIN_RE='^(begin([ \t]+(transaction|work))?|start[ \t]+transaction)([ \t]+[a-z][a-z ,]*)?[ \t]*;$'
COMMIT_RE='^(commit|end)([ \t]+(transaction|work))?([ \t]+and[ \t]+no[ \t]+chain)?[ \t]*;$'
# 0 when the file has a top-level statement matching the regex $1 (BEGIN or COMMIT forms), comments cut.
has_stmt() {
  awk -v re="$1" '
    { l = tolower($0); gsub(/"/, "", l) }
    l ~ re { found = 1 }
    END { exit found ? 0 : 1 }'
}
# Prints why the file leaves a statement outside the timed window and returns 0; returns 1 for a clean shape: exactly one
# BEGIN, then a COMMIT, nothing but SET/RESET outside them (a NOTIFY is also allowed after the COMMIT), no ROLLBACK,
# ABORT, PREPARE TRANSACTION or COMMIT/END AND CHAIN.
shape_violation() {
  awk -v bre="$BEGIN_RE" -v cre="$COMMIT_RE" '
    /^@@/ { next }
    { l = tolower($0); gsub(/"/, "", l) }
    l ~ bre { if (st != 0) { r = (st == 1 ? "second BEGIN" : "BEGIN after COMMIT"); exit } st = 1; next }
    l ~ cre { if (st != 1) { r = "COMMIT before BEGIN"; exit } st = 2; next }
    l ~ /^(rollback|abort)([ \t;]|$)/ { r = "ROLLBACK"; exit }
    l ~ /^(commit|end)([ \t]+(transaction|work))?[ \t]+and[ \t]+chain[ \t]*;$/ { r = "COMMIT AND CHAIN"; exit }
    l ~ /^prepare[ \t]+transaction([^a-z0-9_$]|$)/ { r = "PREPARE TRANSACTION"; exit }
    st == 1 { next }
    st == 2 && l ~ /^notify[ \t]/ { next }
    l ~ /^(set|reset)[ \t]/ { next }
    { r = (st == 0 ? "statement before BEGIN" : "statement after COMMIT"); exit }
    END { if (r != "") { print r; exit 0 } exit 1 }'
}
# 0 when a statement other than a SET comes after the first BEGIN and before both SET LOCAL timeouts: the guard must be
# the first thing in the window, or that statement runs unguarded.
guard_late() {
  awk -v bre="$BEGIN_RE" '
    /^@@/ { next }
    { l = tolower($0); gsub(/"/, "", l) }
    !b { if (l ~ bre) b = 1; next }
    l ~ /^set[ \t]/ {
      if (l ~ /^set[ \t]+local[ \t]+lock_timeout([ \t=]|$)/) k1 = 1
      if (l ~ /^set[ \t]+local[ \t]+statement_timeout([ \t=]|$)/) k2 = 1
      if (k1 && k2) exit
      next
    }
    { late = 1; exit }
    END { exit late ? 0 : 1 }'
}
# 0 when a statement calls set_config naming either timeout, touches pg_settings, uses a U& escaped name or string, or
# calls set_config with an E'..' string (an escaped name): each can change the guard from inside a statement the value
# checks never see.
has_set_config() {
  awk '
    /^@@/ { next }
    { l = tolower($0) }
    l ~ /set_config/ && l ~ /(lock|statement)_timeout/ { found = 1 }
    l ~ /pg_settings/ { found = 1 }
    l ~ /(^|[^a-z0-9_$])u&["\047]/ { found = 1 }
    l ~ /set_config/ && l ~ /(^|[^a-z0-9_$])e\047/ { found = 1 }
    END { exit found ? 0 : 1 }'
}
# 0 when a statement calls set_config with a first argument that is not a plain quoted literal ('lock' || '_timeout', a
# column of a VALUES list, a variable): the name cannot be read, so it may be either timeout. The text before each
# mention is walked one character at a time, tracking single-quote and double-quote state separately (an apostrophe inside
# "..." and a double quote inside '...' are text, a doubled '' or "" is an escape). A mention is skipped when it sits inside
# a single-quoted literal or inside a quoted identifier that is not the call name itself, or when it is part of a longer
# identifier (my_set_config); a quoted call name ("set_config"( or pg_catalog."set_config"( ) is the same call.
has_set_config_dynamic() {
  awk '
    /^@@/ { next }
    { l = tolower($0); pos = 1; sq = 0; dq = 0
      while ((k = index(substr(l, pos), "set_config")) > 0) {
        k += pos - 1
        for (; pos < k; pos++) {
          c = substr(l, pos, 1)
          if (sq) { if (c == "\047") { if (substr(l, pos + 1, 1) == "\047") pos++; else sq = 0 } }
          else if (dq) { if (c == "\"") { if (substr(l, pos + 1, 1) == "\"") pos++; else dq = 0 } }
          else if (c == "\047") sq = 1
          else if (c == "\"") dq = 1
        }
        prev = (k > 1) ? substr(l, k - 1, 1) : ""
        pos = k + 10
        if (sq) continue
        if (dq && prev != "\"") continue
        if (prev ~ /[a-z0-9_$]/) continue
        rest = substr(l, k + 10)
        if (dq) { if (substr(rest, 1, 1) != "\"") continue; rest = substr(rest, 2) }
        if (match(rest, /^[ \t]*\(/)) { a = substr(rest, RLENGTH + 1); if (a !~ /^[ \t]*\047[^\047]*\047[ \t]*,/) found = 1 }
      } }
    END { exit found ? 0 : 1 }'
}
# 0 when the file has a plain SET (no LOCAL) or a RESET of either timeout: it overrides the guard.
has_override() {
  awk '
    { l = tolower($0); gsub(/"/, "", l) }
    l ~ /^[ \t]*set[ \t]+(session[ \t]+)?(lock|statement)_timeout([ \t=]|$)/ { found = 1 }
    l ~ /^[ \t]*reset[ \t]+((lock|statement)_timeout|all)([ \t;]|$)/ { found = 1 }
    END { exit found ? 0 : 1 }'
}
# 0 when $1 is one of the accepted forms listed in $2.. ; 1 otherwise.
accepted() { local v="$1"; shift; for a in "$@"; do [ "$v" = "$a" ] && return 0; done; return 1; }
# Print a value only when it is a plain token: never any other text of the file.
shown() { case "$1" in ''|*[!A-Za-z0-9.]*) printf '<unparsed>' ;; *) [ "${#1}" -le 12 ] && printf '%s' "$1" || printf '<unparsed>' ;; esac; }

# Added files only. --no-renames: a renamed file is a new name, so a new version the push runs.
# ":(top)" anchors the pathspec at the repo root, so the listing is the same from any subdirectory.
GITLS=(git -c core.quotePath=false -c diff.relative=false diff --name-only --no-renames --diff-filter=A "$FROM..$TO")
LIST="$("${GITLS[@]}" -- ':(top)supabase/migrations/')" || { cm_warn "deploy-migration-check.sh: git diff failed for $FROM..$TO"; exit 1; }
ADDED_ALL="$("${GITLS[@]}")" || { cm_warn "deploy-migration-check.sh: git diff failed for $FROM..$TO"; exit 1; }
# The pathspec listing must agree with the full diff: if git reports added migrations that the listing lacks, fail closed.
MIG_RE='^supabase/migrations/[^/]*\.sql$'
n_all="$(printf '%s\n' "$ADDED_ALL" | grep -c "$MIG_RE")"; n_list="$(printf '%s\n' "$LIST" | grep -c "$MIG_RE")"
[ "$n_all" = "$n_list" ] || { cm_warn "deploy-migration-check.sh: the pathspec listing has $n_list added migrations but the full diff has $n_all: refusing to report"; exit 1; }

N_OK=0; N_ASK=0; N_STOP=0; N_EXC=0; N_EXAM=0; SEEN=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in \"*) cm_warn "deploy-migration-check.sh: git prints an added path quoted, cannot read it: $f"; exit 1 ;; esac
  case "$f" in supabase/migrations/*/*) continue ;; supabase/migrations/*.sql) ;; *) continue ;; esac   # a delta migration is a .sql file directly in the directory
  if [ -n "$ONLY" ]; then
    case $'\n'"$ONLY" in *$'\n'"$f"$'\n'*) ;; *) continue ;; esac   # --only: only the files named
    SEEN="$SEEN$f"$'\n'
  fi
  N_EXAM=$((N_EXAM + 1))
  raw="$(git show "$TO:$f" 2>/dev/null)" || { cm_warn "deploy-migration-check.sh: cannot read $f at $TO"; exit 1; }
  body="$(strip_sql <<<"$raw")"

  miss=""
  has_stmt "$BEGIN_RE" <<<"$body" || miss="BEGIN;"
  has_stmt "$COMMIT_RE" <<<"$body" || miss="${miss:+$miss and }COMMIT;"
  if [ -n "$miss" ]; then
    printf 'stop %s reason=no %s\n' "$f" "$miss"
    N_STOP=$((N_STOP + 1))
    continue
  fi
  if shape="$(shape_violation <<<"$body")"; then
    printf 'stop %s reason=shape: %s\n' "$f" "$shape"
    N_STOP=$((N_STOP + 1))
    continue
  fi

  bad=0; shown_l=""; shown_s=""
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    shown_l="${shown_l:+$shown_l,}$(shown "$v")"
    accepted "$v" 3s 3000ms 3000 || bad=1
  done < <(set_values lock_timeout <<<"$body")
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    shown_s="${shown_s:+$shown_s,}$(shown "$v")"
    accepted "$v" 30s 30000ms 30000 || bad=1
  done < <(set_values statement_timeout <<<"$body")
  if has_override <<<"$body"; then shown_s="${shown_s:+$shown_s,}override"; bad=1; fi
  GL=""
  if guard_late <<<"$body"; then GL=" guard=late"; bad=1; fi
  if has_set_config <<<"$body"; then GL="$GL set-timeout-call"; bad=1; fi
  if has_set_config_dynamic <<<"$body"; then GL="$GL set-config-dynamic"; bad=1; fi
  if grep -q '^@@body-timeout-do' <<<"$body"; then GL="$GL timeout-in-body"; bad=1; fi
  if grep -q '^@@body-timeout-function' <<<"$body"; then GL="$GL timeout-in-function"; bad=1; fi
  [ -n "$shown_l" ] || { shown_l=missing; bad=1; }
  [ -n "$shown_s" ] || { shown_s=missing; bad=1; }

  if [ "$bad" = 0 ]; then st=ok; N_OK=$((N_OK + 1))
  elif [ "$EXC" = recorded ]; then st=exception; N_EXC=$((N_EXC + 1))
  else st=ask; N_ASK=$((N_ASK + 1)); fi
  printf '%s %s lock_timeout=%s statement_timeout=%s%s exception=%s\n' "$st" "$f" "$shown_l" "$shown_s" "$GL" "$EXC"
done <<<"$LIST"

# An --only path that matched no added file is a typo, a ./ prefix or a stray space: fail closed, never a silent pass.
while IFS= read -r o; do
  [ -n "$o" ] || continue
  case $'\n'"$SEEN" in *$'\n'"$o"$'\n'*) ;; *) cm_warn "deploy-migration-check.sh: --only path is not an added migration in $FROM..$TO: $o"; exit 1 ;; esac
done <<<"$ONLY"
printf '%s migration files examined\n' "$N_EXAM"
printf 'summary: ok=%s exception=%s ask=%s stop=%s (added migrations in %s..%s)\n' "$N_OK" "$N_EXC" "$N_ASK" "$N_STOP" "$FROM" "$TO"
if [ "$N_STOP" -gt 0 ]; then
  printf 'note: a stop blocks the window. If that version is already applied on staging, do NOT edit the file (the migration runner tracks applied files by name and silently skips an edited one); the only fix is connection-level timeouts on the push step, for example PGOPTIONS='"'"'-c lock_timeout=3s -c statement_timeout=30s'"'"' in the workflow step that runs the push, or the db-url form (options=-c lock_timeout=3s -c statement_timeout=30s, URL-encoded); the CLI may ignore PGOPTIONS, so prove it with a SHOW lock_timeout in the same session.\n'
  exit 3
fi
[ "$N_ASK" -gt 0 ] && exit 2
exit 0
