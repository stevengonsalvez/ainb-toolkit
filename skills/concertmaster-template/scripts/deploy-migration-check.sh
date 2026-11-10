#!/usr/bin/env bash
# deploy-migration-check.sh: the deploy pre-check for the migrations a delta ADDS.
#
#   scripts/deploy-migration-check.sh <from-ref> <to-ref> [--pr-body-file <file> --only <path>]... [--caps-ref <ref>] [--no-cover]
#   (--caps-ref = deploy mode, the only mode in which a stop can be reported as `covered`; no --caps-ref = strict PR-gate mode)
#
# Run it from anywhere inside the repo (the pathspec is anchored at the repo top, so a subdirectory gives the same
# result as the root). <from-ref> is the last production tag, <to-ref> the pinned deploy sha (or origin/main); at the PR
# merge gate <from-ref> is the merge-base of the PR's own base branch and the PR head, <to-ref> the PR head sha (the PR gate passes no --caps-ref: strict, see `covered`). It lists
# only the files ADDED in that range under the migrations directory (deploy.migrations_dir in config.yaml, default
# supabase/migrations; env CM_MIGRATIONS_DIR wins) (a modified older file is never re-flagged; a rename
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
#   covered    DEPLOY MODE ONLY (--caps-ref given). There are two modes. The deploy worker (the window pre-check) passes
#              --caps-ref <pinned sha> and may get `covered`. The pr-sweeper merge gate passes NO --caps-ref and is STRICT: an
#              unguarded file stays a `stop` (exit 3) whose text tells the author to add the in-file guard (BEGIN; SET LOCAL
#              lock_timeout = '3s'; SET LOCAL statement_timeout = '30s'; ... COMMIT;); the caps are never offered as a
#              substitute there. Why: at the gate the file is not applied yet and can still get the stronger in-file guard
#              (atomic, 3s / 30s). The output names its mode (`mode: pr-gate` or `mode: deploy`), so a sweeper that wrongly
#              passes --caps-ref is visible in the merge line.
#              What can be covered: only a file with NO transaction control at all (no BEGIN;, no COMMIT;, no ROLLBACK, no
#              SAVEPOINT), and only while EVERY workflow in the caps workflow list (deploy.caps_workflows in config.yaml, default
#              .github/workflows/deploy-production.yml and .github/workflows/deploy-staging.yml), read at --caps-ref, caps the
#              `supabase db push` --db-url. The caps are the options= query parameter (up to the next &, URL-decoded):
#              lock_timeout and statement_timeout, each above 0 and at most 3s / 120000ms (units ms, s, min, or a bare number =
#              ms). The URL must be one plain literal assigned once (no expansion, command substitution, declare/printf -v/
#              export/+=, folded run: >), with one options= and no query key but options, sslmode, application_name, no ; + or
#              malformed %, no # and no control character or %00. A pooler URL (pooler host or port 6543) is never covered.
#              The step that runs the push is an ALLOWLIST (YAML keys before the run block, then only echo, a `: "${X:?..}"`
#              check, one plain NAME=value, the plain `supabase db push [--include-all] --db-url ...`): any other shell in it
#              (a `||` fallback, a second assignment, a variable subcommand, a wrapper function, BASH_ENV or PATH in env:) is
#              refused, and so is `supabase migration up`, `supabase db reset` or `psql -f` anywhere in a workflow.
#              --caps-ref is the tree that will deploy (the briefs pass the pinned sha, equal to <to-ref>). When it is a
#              different ref and the range edits a workflow, the workflows at <to-ref> must equal --caps-ref byte for byte (a
#              range that edits a workflow cannot add the caps for itself). --no-cover (deploy mode only) and an env override of
#              the workflow list (CM_DMC_WORKFLOWS) turn the cover off; CM_DMC_MAX_LOCK_MS and CM_DMC_MAX_STATEMENT_MS can only
#              tighten the bounds, never loosen them past 3000 and 120000.
#              The file itself must not touch a timeout: no plain SET/RESET, no set_config, no lock_timeout or statement_timeout
#              named anywhere (a function SET clause included), no EXECUTE, DISCARD or RESET ALL, no set_config/pg_settings/U&
#              identifier in a dollar body, no function or DO body written as a quoted string.
#              Printed as `covered (connection caps): <file>` plus the workflow line that carries options= (file:line, userinfo
#              hidden) and the decoded caps; counts as ok for the exit code (it no longer blocks the window) but is always
#              printed, in the summary (covered=N) and again as a final `covered (not silent...)` line. A stop that was not
#              covered says why. A covered file next to an ask still exits 2, next to a stop still exits 3. Every other stop
#              class (a half transaction, a ROLLBACK, any shape stop) is never covered.
#              A file that changes the SESSION timeouts (a plain SET or RESET, set_config, dynamic SQL) is never covered, and neither is any
#              file after it in the push: the migrations share one connection, so the change outlives the file. This also holds for an
#              earlier file that --only leaves out.
#              Residual, not detected: the cover reads the push steps only. A push step that is skipped by an `if:` (for example
#              `if: false`), or migrations that a later `uses:` action step applies, are not seen: the capped push step is still
#              read as the push, so the file reads covered. The same goes for anything set outside the push step: a workflow- or
#              job-level `env:` (BASH_ENV and the like) and `defaults.run.shell` are not read. Inside the push step a custom
#              `shell:` (anything but bash or sh) and a backslash in the options are refused. A human reads the workflow when it
#              changed. (Tests pin this, so a change to it is deliberate.)
#              Residual, not detected: a plain file that calls an EXISTING database function which itself sets a timeout (for
#              example one that runs set_config('lock_timeout', ...)); the cover cannot see inside functions it does not define.
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
# the push step: the db-url form (options=-c lock_timeout=3s -c statement_timeout=120000, URL-encoded) in the workflow step
# that runs the push. The PGOPTIONS env is not a substitute: when measured against a pinned Supabase CLI the push session
# ignored it (lock_timeout=0), while the options= db-url form reached the session (3s / 2min). Re-measure on your own
# pinned CLI version. The in-file SET LOCAL values stay 3s / 30s; 120000 is the connection-level cap only. Prove any option
# reaches the session with a SHOW lock_timeout in the same session before relying on it.
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
#       <to-ref>), a bad argument (an empty --only, an empty or blank --caps-ref, one matching no added file, --pr-body-file without --only), an added
#       path git prints quoted, or a listing that disagrees with the full diff. ANY exit other than 0 blocks the window.
# NOT covered by the caps check: a workflow that builds the URL from another file or step, a push inside a script the
# workflow calls, anything but plain NAME=value assignments and literal --db-url values, a migration tool other than
# `supabase db push`, and whether the options reach the session (prove it with a SHOW lock_timeout in the same session).
# NOT covered by the file check: a timeout set another way (ALTER ROLE/DATABASE, a function-level SET clause, dynamic SQL built from
# strings); a non-literal set_config inside a DO body (bodies are searched for the two timeout names only); anything
# after the first 4096 characters of one statement (SELECT '<5000 a>', set_config('lock_timeout', '0', true); reads ok);
# a session with standard_conforming_strings off (a backslash then escapes the quote in an ordinary string, which the
# scanner reads the standard way); a SQL-standard function body (BEGIN ATOMIC ... END, read as a stop); a guard added in
# the workflow step; and whether connection-level options reach the session. A SET LOCAL repeated in one file is
# judged on every occurrence, so one bad value flags the file.
# The migration directory holds the delta files directly in it, ending .sql (a file in a subdirectory is not examined);
# it comes from deploy.migrations_dir (default supabase/migrations) or env CM_MIGRATIONS_DIR: a relative path of letters,
# digits, dot, dash, underscore and slash, no `.` or `..` component, no leading or doubled slash (anything else is exit 1). A
# config that exists but cannot be read, or an empty deploy.migrations_dir, is also exit 1 (never a silent fallback).
# A well-formed directory that does not exist at <to-ref> is exit 1 too (a typo must not read as 0 files examined).
# Pure bash plus git, no network. Needs bash 3.2 or later. The deploy worker runs it on Linux (gawk or mawk); macOS
# one-true-awk is untested, and busybox awk does not finish a 10 MB one-line file in 240 s (a 1 MB line takes seconds).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

# Deploy workflows whose `supabase db push --db-url` must ALL carry the connection-level caps (deploy.caps_workflows in
# config.yaml, a list of repo-relative paths; default the two below). CM_DMC_WORKFLOWS (a space-separated list) in the
# environment replaces the list and turns the cover off, so an ambient export cannot drop a workflow from the requirement.
# Caps allowed (> 0, because 0 means no limit): lock_timeout up to CM_DMC_MAX_LOCK_MS, statement_timeout up to
# CM_DMC_MAX_STATEMENT_MS; the environment can only tighten them (3000 and 120000 are the ceiling).
# Why 120000: it is a push-session cap on the whole migration run, so it is looser than the 30 s in-file value that bounds one
# window; it only has to stop a statement that never ends. A project that wants it tighter sets CM_DMC_MAX_STATEMENT_MS.
DEFAULT_WORKFLOWS=".github/workflows/deploy-production.yml .github/workflows/deploy-staging.yml"
# Each entry is validated on its own BEFORE the list is joined: an entry with a space must not split into two plain paths.
WORKFLOWS=""
if [ -n "${CM_DMC_WORKFLOWS:-}" ]; then read -ra _wf_arr <<<"$CM_DMC_WORKFLOWS"; _wf_src="$(printf '%s\n' "${_wf_arr[@]}")"   # read -ra: no glob expansion
else
  _wf_src="$(printf '%s' "$CM_CFG_JSON" | jq -r '(.deploy.caps_workflows // []) | if type == "array" then .[] | tostring else "<not a list>" end' 2>/dev/null)"
fi
while IFS= read -r _wf; do
  [ -n "$_wf" ] || continue
  case "$_wf" in
    /*|./*|*/./*|*//*|*..*|*[!A-Za-z0-9._/-]*) cm_warn "deploy-migration-check.sh: bad workflow path (deploy.caps_workflows or CM_DMC_WORKFLOWS): $_wf"; exit 1 ;;
  esac
  WORKFLOWS="${WORKFLOWS:+$WORKFLOWS }$_wf"
done <<<"$_wf_src"
[ -n "$WORKFLOWS" ] || WORKFLOWS="$DEFAULT_WORKFLOWS"
MAX_LOCK_MS="${CM_DMC_MAX_LOCK_MS:-3000}"
MAX_STATEMENT_MS="${CM_DMC_MAX_STATEMENT_MS:-120000}"
# The bounds can be tightened from the environment, never loosened past the defaults (an ambient export must not widen the gate).
[[ "$MAX_LOCK_MS" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$MAX_LOCK_MS))" -le 3000 ] || MAX_LOCK_MS=3000
[[ "$MAX_STATEMENT_MS" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$MAX_STATEMENT_MS))" -le 120000 ] || MAX_STATEMENT_MS=120000

usage() { awk 'NR > 1 { if (/^#/) print; else exit }' "$0"; }

# The migration directory: relative to the repo top, plain characters only (it goes into a git pathspec and a regex).
MIGDIR="${CM_MIGRATIONS_DIR:-$(cm_cfg .deploy.migrations_dir supabase/migrations)}"
while [ "${MIGDIR%/}" != "$MIGDIR" ]; do MIGDIR="${MIGDIR%/}"; done
# A config that exists but could not be read (yq missing, bad YAML) or a migrations_dir set to nothing must not fall back to
# the default directory: that would examine the wrong directory and pass with 0 files. Fail closed (the env var is explicit).
if [ -z "${CM_MIGRATIONS_DIR:-}" ] && [ -n "$CM_CONFIG_FILE" ]; then
  if [ -s "$CM_CONFIG_FILE" ] && [ "$CM_CFG_JSON" = '{}' ]; then
    cm_warn "deploy-migration-check.sh: config $CM_CONFIG_FILE exists but could not be read (is yq installed and the YAML valid?): refusing to guess the migrations directory"; exit 1
  fi
  if printf '%s' "$CM_CFG_JSON" | jq -e '(.deploy // {}) | type != "object"' >/dev/null 2>&1; then
    cm_warn "deploy-migration-check.sh: the deploy section of the config is not a map: refusing to guess the migrations directory"; exit 1
  fi
  if printf '%s' "$CM_CFG_JSON" | jq -e '(.deploy // {}) | has("migrations_dir") and ((.migrations_dir | type) != "string" or .migrations_dir == "")' >/dev/null 2>&1; then
    cm_warn "deploy-migration-check.sh: deploy.migrations_dir is set but empty or not a string"; exit 1
  fi
fi
case "$MIGDIR" in
  ''|.|/*|./*|*/.|*/./*|*//*|*..*|*[!A-Za-z0-9._/-]*)
    cm_warn "deploy-migration-check.sh: bad migrations directory (deploy.migrations_dir or CM_MIGRATIONS_DIR): must be a plain relative path, no '..', no leading or doubled slash"; exit 1 ;;
esac

FROM=""; TO=""; BODY=""; ONLY=""; CAPS_REF=""; CAPS_EXPLICIT=no; NO_COVER=no
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
    --caps-ref)
      [ $# -ge 2 ] || { cm_warn "deploy-migration-check.sh: --caps-ref needs a ref"; exit 1; }
      [ -n "${2//[[:space:]]/}" ] || { cm_warn "deploy-migration-check.sh: --caps-ref needs a non-empty ref (an empty value would turn deploy mode on and default the caps ref to the PR head)"; exit 1; }
      CAPS_REF="$2"; CAPS_EXPLICIT=yes; shift 2 ;;
    --no-cover) NO_COVER=yes; shift ;;
    -*) cm_warn "deploy-migration-check.sh: unknown option: $1"; exit 1 ;;
    *)
      if [ -z "$FROM" ]; then FROM="$1"
      elif [ -z "$TO" ]; then TO="$1"
      else cm_warn "deploy-migration-check.sh: too many arguments"; exit 1; fi
      shift ;;
  esac
done
[ -n "$FROM" ] && [ -n "$TO" ] || { cm_warn "deploy-migration-check.sh: usage: <from-ref> <to-ref> [--pr-body-file <file>] [--only <path>]... [--caps-ref <ref>] [--no-cover]"; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { cm_warn "deploy-migration-check.sh: not inside a git repository"; exit 1; }
[ -n "$CAPS_REF" ] || CAPS_REF="$TO"
for ref in "$FROM" "$TO" "$CAPS_REF"; do
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { cm_warn "deploy-migration-check.sh: bad ref: $ref"; exit 1; }
done
git merge-base --is-ancestor "$FROM" "$TO" 2>/dev/null || { cm_warn "deploy-migration-check.sh: bad range: $FROM is not an ancestor of $TO"; exit 1; }
# A well-formed directory that is not in the tree being checked is a typo (config or CM_MIGRATIONS_DIR), not "no migrations":
# examining nothing would pass every file unread. Fail closed.
[ "$(git cat-file -t "$TO:$MIGDIR" 2>/dev/null)" = tree ] || { cm_warn "deploy-migration-check.sh: migrations directory '$MIGDIR' does not exist at $TO (typo in deploy.migrations_dir or CM_MIGRATIONS_DIR?): refusing to examine nothing"; exit 1; }
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
          lc = tolower(chunk); gsub(/(grant|revoke)[ \t]+execute/, "", lc); gsub(/execute[ \t]+(function|procedure)[ \t]+([a-z_][a-z0-9_$]*|"[^"]*")(\.([a-z_][a-z0-9_$]*|"[^"]*"))*[ \t]*\(/, " (", lc)
          if (lc ~ /^[ \t]*--/) lc = ""
          if (lc ~ /(^|[^a-z_])(execute|discard)([^a-z_]|$)|reset[ \t]+all|set_config|pg_settings|(^|[^a-z0-9_$])u&["\047]/) hitdyn = 1
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
    END { emit(cur ";"); if (hitdo) print "@@body-timeout-do"; if (hitfn) print "@@body-timeout-function"; if (hitdyn) print "@@body-dynamic" }'
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

# Milliseconds for a plain PostgreSQL duration (digits then ms, s, min or nothing = ms); prints nothing for any other form.
to_ms() {
  local n u
  [[ "$1" =~ ^([0-9]{1,9})(ms|s|min)?$ ]] || return 1
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  case "$u" in ''|ms) printf '%s' "$((10#$n))" ;; s) printf '%s' "$((10#$n * 1000))" ;; min) printf '%s' "$((10#$n * 60000))" ;; esac
}
# Reads one workflow text on stdin and prints one tab-separated record per `supabase db push` command: push line number, push
# text, the --db-url value ("-" when there is none), the line number and text where that URL is assigned. Comment lines are
# skipped and `\` continuations joined. A "$VAR" argument resolves to the one NAME=value line above it in the same step (a
# step starts at a `- ` line). It FAILS CLOSED: any line that mentions `db push` but is not a plain `supabase db push` command
# (chained after `&&`, behind `npx`, inside an echo), a second --db-url, or the URL variable appended to (`NAME+=`) or assigned more than
# once in the step prints one `UNPARSED` record, which makes the caller refuse to cover.
push_records() {
  awk -v mig="$MIGDIR" '
    function trim(t) { gsub(/\t/, " ", t); sub(/^[ ]+/, "", t); sub(/[ ]+$/, "", t); return t }
    # A value is plain when its only expansions are simple ${NAME}: no operator (:-), no command substitution, no backtick.
    function plainvalue(v,   r) { r = v; gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\}/, "", r); return (r !~ /[$`\\]/) }
    # Lines of the current step that mention the variable at all: it must be assigned once and used once, nowhere else.
    function mentions(nm,   i, c, re, rc) { c = 0; re = "(^|[^A-Za-z0-9_])" nm "($|[^A-Za-z0-9_])"; rc = "^:[ ]+\"\\$\\{" nm ":\\?"; for (i = 1; i <= nsb; i++) if (sb[i] ~ re && sb[i] !~ rc) c++; return c }
    function bad(t) { print "UNPARSED\t" start "\t-\t0\t" t }
    # The step that runs the push is an ALLOWLIST: every line of it must be a YAML key, an echo, a `: "${X:?..}"` check, one plain
    # NAME=value assignment, or the plain push itself. Any other shell (a `||` fallback, a second assignment on a line, a variable
    # subcommand, a wrapper function, another migration command) means the push this script reads is not the only way the step
    # applies migrations, so the step is refused rather than guessed at.
    function allowed_shell(l) {
      if (l ~ /^echo([ ]+[^;&|`$<>()\\]*)?$/) return 1
      if (l ~ /^:[ ]+"\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^"`$]*\}"$/) return 1
      if (l ~ /^(BASH_ENV|ENV|PATH|LD_[A-Z_]*|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND|IFS|CDPATH|GLOBIGNORE|PGOPTIONS|PGSERVICE|PGSERVICEFILE|NODE_OPTIONS)=/) return 0
      if (l ~ /^[A-Za-z_][A-Za-z0-9_]*=("([^"$`]|\$\{[A-Za-z_][A-Za-z0-9_]*\})*"|\047[^\047]*\047|[^ \t"\047;&|$`<>()\\]*)$/) return 1
      if (l ~ /^(- )?(run: )?supabase[ ]+db[ ]+push[ ]+(--include-all[ ]+)?--db-url[ ]+("\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"|"[^"$`]*")$/) return 1
      return 0
    }
    # Before the run block only: step keys and env entries (never the dangerous startup variables).
    function allowed_yaml(l) {
      if (l ~ /^(- )?(name|id|if|continue-on-error|working-directory|timeout-minutes):/) return 1
      if (l ~ /^(- )?env:$/) return 1
      if (l ~ /^(- )?env:[ ]*[^ ]/) return 0
      if (l ~ /^(- )?shell:/) return (l ~ /^(- )?shell:[ ]+(bash|sh)$/)
      if (l ~ /^(BASH_ENV|ENV|PATH|LD_[A-Z_]*|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND|IFS|CDPATH|GLOBIGNORE|PGOPTIONS|PGSERVICE|PGSERVICEFILE|NODE_OPTIONS):/) return 0
      if (l ~ /^[A-Za-z_][A-Za-z0-9_]*:[ ]/) return 1
      return 0
    }
    function stepend(   i, inrun, l, ok) {
      if (!haspush) return
      inrun = 0
      for (i = 1; i <= nsb; i++) {
        l = sb[i]
        if (l ~ /^(- )?run:[ ]*\|[-+]?$/) { inrun = 1; continue }
        ok = inrun ? allowed_shell(l) : (allowed_yaml(l) || allowed_shell(l))
        if (inrun == 0 && l ~ /^(- )?run:[ ]/) inrun = 1
        if (!ok) { print "UNPARSED\t" stepstart "\t-\t0\t" l; haspush = 0; return }
      }
      haspush = 0
    }
    function flush(   t, name, a, m, url, ul, ut, n, tmp, u) {
      t = trim(cur); cur = ""
      if (t == "" || t ~ /^#/) return
      if (t ~ /^- [A-Za-z_-]+:/) { stepend(); stepstart = start; stepind = curind; delete val; delete vline; delete vtext; delete vcount; delete vplus; delete vbad; delete sb; nsb = 0; folded = 0 }
      if (t ~ /(^|[ ])run:[ ]*>[-+]?[ ]*$/) folded = 1
      sb[++nsb] = t
      if (match(t, /^(export[ ]+)?[A-Za-z_][A-Za-z0-9_]*\+=/)) {
        name = t; sub(/\+=.*$/, "", name); sub(/^export[ ]+/, "", name); vplus[name]++
      }
      if (match(t, /^(export[ ]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        name = t; sub(/=.*$/, "", name); sub(/^export[ ]+/, "", name)
        a = substr(t, RLENGTH + 1)
        if (a !~ /^["\047]/ && a ~ /[ ]/) vbad[name] = 1
        gsub(/^["\047]|["\047]$/, "", a)
        val[name] = a; vline[name] = start; vtext[name] = t; vcount[name]++
      }
      if (t ~ /^- name:/) return
      u = t; gsub(/["\047\\]/, "", u)
      if (u ~ /supabase/ && u ~ /(migration[ ]+up|db[ ]+reset)/) { bad(t); return }
      if (u ~ /psql/ && (u ~ /(^| )(-f|--file)([ =]|$)/ || u ~ /(^|[^<])<([^<]|$)/ || u ~ /\\i /)) { bad(t); return }
      if (index(u, mig) > 0 && (u ~ /psql/ || u ~ /\|/ || u ~ /xargs/ || u ~ /(^|[^<])<([^<]|$)/)) { bad(t); return }
      if (u ~ /supabase/ && u ~ /push/) haspush = 1
      if (!(u ~ /supabase/ && u ~ /push/) && t !~ /db[ ]+push/) return
      if (t !~ /^(- )?(run: )?supabase[ ]+db[ ]+push([ ]|$)/) { bad(t); return }
      tmp = t; n = gsub(/--db-url/, "", tmp)
      if (n > 1) { bad(t); return }
      url = "-"; ul = start; ut = t
      if (match(t, /--db-url[= ]+("[^"]*"|\047[^\047]*\047|[^ ]+)/)) {
        a = substr(t, RSTART, RLENGTH); sub(/^--db-url[= ]+/, "", a); gsub(/^["\047]|["\047]$/, "", a)
        if (a ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) {
          m = a; gsub(/[${}]/, "", m)
          if (m in val) { if (vcount[m] > 1 || vplus[m] > 0 || vbad[m] || folded || !plainvalue(val[m]) || mentions(m) != 2) { bad(t); return } url = val[m]; ul = vline[m]; ut = vtext[m] }
        } else url = a
      }
      if (url == "") url = "-"
      print start "\t" t "\t" url "\t" ul "\t" ut
    }
    BEGIN { stepind = -1 }
    { line = $0
      if (cur == "") {
        start = NR; match(line, /^[ \t]*/); curind = RLENGTH
        # A line less indented than the dash of the step leaves the step, so a job that follows the push job is never read as shell
        # of the push step.
        if (nsb > 0 && line !~ /^[ \t]*(#|$)/ && curind < stepind) { stepend(); nsb = 0 }
      }
      if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); cur = cur " " line; next }
      cur = cur " " line; flush() }
    END { if (cur != "") flush(); stepend() }'
}
# Hide URL userinfo before a workflow line is quoted in the output.
scrub() { sed -E 's#(://)[^/ "]*@#\1***@#g'; }
# Deploy mode only (--caps-ref given). Sets CAPS_OK (yes|no) and CAPS_LINES (the quoted proof) once per run: BOTH workflows, read at $CAPS_REF (the ref that will deploy) AND, when the range edits a workflow, at <to-ref>, must have a
# `supabase db push` whose --db-url carries options= with lock_timeout and statement_timeout caps inside the allowed bounds.
CAPS_OK=""; CAPS_LINES=""
caps_covered() {
  [ -z "$CAPS_OK" ] || return 0
  CAPS_OK=no; CAPS_LINES=""; CAPS_WHY=""
  # Two modes. Deploy mode is --caps-ref given: the caps are read from that pinned tree. The PR merge gate passes no
  # --caps-ref and is STRICT, so the caller never gets here without --caps-ref (an unguarded file stays a STOP).
  # --no-cover (deploy mode, for a base the caps do not protect) and an env override of the workflow list (an ambient
  # CM_DMC_WORKFLOWS must not drop a workflow from the ALL requirement) turn the cover off: every plain file stays a STOP.
  [ "$NO_COVER" = no ] || { CAPS_WHY="--no-cover was given"; return 0; }
  [ -z "${CM_DMC_WORKFLOWS:-}" ] || { CAPS_WHY="CM_DMC_WORKFLOWS is set in the environment, the cover needs the configured caps workflows"; return 0; }
  [ -n "$WORKFLOWS" ] || { CAPS_WHY="no caps workflow is configured (deploy.caps_workflows)"; return 0; }
  local wf text recs seen pl url ul ut dec lk st lkms stms lines="" q part opt nopt tok want name val lname l
  local ref; local -a refs=() specs=() parts=() toks=()
  # The caps must hold in $CAPS_REF (the tree that deploys; the briefs pass the pinned sha, equal to $TO, so the deploy tree vouches
  # for itself) and, when $CAPS_REF is a different ref and the range edits a workflow, $TO must equal it (then a range that weakens
  # or adds caps is not covered). When $CAPS_REF equals $TO the comparison below is skipped, as the header says. An unrelated edit
  # to a workflow earlier in the range no longer costs the window when the head equals $CAPS_REF. ":(top)" anchors each path at the repo root, from any subdirectory.
  [ -n "$WORKFLOWS" ] || return 0
  # The head tree is checked only when the range edits a workflow: a branch that is merely behind main (stale copy of the
  # workflows, range untouched) is judged by $CAPS_REF alone.
  refs=("$CAPS_REF")
  specs=(); for wf in $WORKFLOWS; do specs+=(":(top)$wf"); done
  if [ "$TO" != "$CAPS_REF" ]; then
    # A range that edits a workflow is covered only when the workflows at the head equal the caps ref byte for byte: the tree
    # that was reviewed is then the tree that runs, and a PR cannot change the push step it relies on.
    if ! git diff --quiet "$FROM" "$TO" -- "${specs[@]}" 2>/dev/null; then
      git diff --quiet "$CAPS_REF" "$TO" -- "${specs[@]}" 2>/dev/null || { CAPS_WHY="the range edits a deploy workflow and the head differs from $CAPS_REF"; return 0; }
    fi
  fi
  for ref in "${refs[@]}"; do
   for wf in $WORKFLOWS; do
    text="$(git show "$ref:$wf" 2>/dev/null)" || return 0
    recs="$(push_records <<<"$text")"; seen=0
    [ -n "$recs" ] || return 0
    while IFS=$'\t' read -r pl pstart url ul ut; do
      [ -n "$pl" ] || continue
      [ "$pl" != UNPARSED ] || { CAPS_WHY="$wf:$pstart is a db push step the parser does not accept: $(printf '%s' "$ut" | scrub | cut -c1-120)"; return 0; }
      seen=1
      [ "$url" != "-" ] || return 0
      # Only the options= query parameter counts: split the query on &, exactly one key equal to options, every key a literal
      # from the whitelist (a sibling lock_timeout=... or an encoded key could override it), and no #fragment (it cuts the query).
      case "$url" in *'#'*) return 0 ;; esac
      # A transaction-mode pooler (Supavisor, port 6543) rejects or ignores startup options: only a direct host is covered.
      # A host or port that is an expansion cannot be judged here (a secret may hold a pooler host or port 6543): the port must be
      # a literal, and the host must keep a literal part with a dot in it once every ${...} is removed.
      _auth="${url#*://}"; _auth="${_auth%%\?*}"; _auth="${_auth%%/*}"; _hostport="${_auth##*@}"
      _host="${_hostport%%:*}"; _port=""; case "$_hostport" in *:*) _port="${_hostport##*:}" ;; esac
      _lit="$(printf '%s' "$_host" | sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*\}//g')"
      case "$_port" in *'$'*) CAPS_WHY="$wf:$ul builds the port from an expansion, which may be a pooler port"; return 0 ;; esac
      case "$_lit" in *.*) ;; *) CAPS_WHY="$wf:$ul builds the host from an expansion, which may be a pooler host"; return 0 ;; esac
      case "$url" in *pooler*|*:6543*) CAPS_WHY="$wf:$ul uses a pooler host or port 6543, which may ignore options="; return 0 ;; esac
      case "$url" in *'?'*) q="${url#*\?}" ;; *) return 0 ;; esac
      # The CLI parses the query with Go url.Query(): a pair holding ";" or a bad %-escape is silently dropped, and "+" is a space.
      # This script does not model that, so any of them in the query is refused.
      case "$q" in *';'*|*'+'*) CAPS_WHY="$wf:$ul has ; or + in the URL query, which the CLI decodes differently"; return 0 ;; esac
      if [[ "$q" =~ %([^0-9A-Fa-f]|.[^0-9A-Fa-f]|.?$) ]]; then CAPS_WHY="$wf:$ul has a malformed %-escape in the URL query"; return 0; fi
      # An expansion in the query could bring a cap override from an env: block this parser does not read; only the host may expand.
      case "$q" in *'$'*) return 0 ;; esac
      nopt=0; opt=""
      IFS='&' read -ra parts <<<"$q"
      for part in ${parts[@]+"${parts[@]}"}; do
        case "${part%%=*}" in
          options) nopt=$((nopt + 1)); opt="${part#options=}" ;;
          sslmode|application_name) ;;
          *) return 0 ;;
        esac
      done
      [ "$nopt" = 1 ] || return 0
      # %00 would vanish in the decode and join two tokens; any other control character (a decoded newline, tab, \v, \f, \r) is a
      # separator the server honours but a line-based read would not see, so both are refused outright.
      case "$opt" in *%00*) return 0 ;; esac
      # A backslash is refused both raw and decoded (%5C): the server's option splitter removes a backslash escape, so lock%5C_timeout=0
      # is a later lock_timeout=0 that a line-based read would not recognise as the name.
      case "$opt" in *'\'*) return 0 ;; esac
      dec="$(printf '%b' "${opt//%/\\x}")"
      case "$dec" in *[[:cntrl:]]*|*'\'*) return 0 ;; esac
      # Tokenise like the server: only "-c name=value" pairs set a timeout; any other token that names one (any case, - or _),
      # a -cNAME or a --long form is refused, so the later-wins spellings (-clock_timeout=0, --lock-timeout=0) cannot hide.
      lk=""; st=""; want=0
      IFS=$' \t\n' read -ra toks <<<"$dec"
      for tok in ${toks[@]+"${toks[@]}"}; do
        if [ "$want" = 1 ]; then
          want=0
          name="${tok%%=*}"; val="${tok#*=}"
          [ "$name" != "$tok" ] || return 0
          lname="$(printf '%s' "$name" | tr 'A-Z-' 'a-z_')"
          case "$lname" in lock_timeout) lk="$val" ;; statement_timeout) st="$val" ;; esac
          continue
        fi
        case "$tok" in
          -c) want=1 ;;
          *) l="$(printf '%s' "$tok" | tr 'A-Z' 'a-z')"
             case "$l" in *timeout*) return 0 ;; esac
             case "$tok" in -c*|--*) return 0 ;; esac ;;
        esac
      done
      [ "$want" = 0 ] || return 0
      [ -n "$lk" ] && [ -n "$st" ] || return 0
      lkms="$(to_ms "$lk")" && stms="$(to_ms "$st")" || return 0
      [ "$lkms" -ge 1 ] && [ "$lkms" -le "$MAX_LOCK_MS" ] && [ "$stms" -ge 1 ] && [ "$stms" -le "$MAX_STATEMENT_MS" ] || return 0
      [ "$ref" = "$CAPS_REF" ] && lines="$lines  $wf:$ul: $(printf '%s' "$ut" | scrub) [push at line $pl; decoded caps lock_timeout=${lkms}ms statement_timeout=${stms}ms; read at $CAPS_REF; bounds lock<=${MAX_LOCK_MS}ms statement<=${MAX_STATEMENT_MS}ms]"$'\n'
    done <<<"$recs"
    [ "$seen" = 1 ] || return 0
   done
  done
  if [ -n "${CM_DMC_WORKFLOWS:-}${CM_DMC_MAX_LOCK_MS:-}${CM_DMC_MAX_STATEMENT_MS:-}" ]; then
    lines="$lines  note: the covered bounds or the workflow list come from CM_DMC_* in the environment, not the defaults"$'\n'
  fi
  CAPS_OK=yes; CAPS_LINES="$lines"
  return 0
}
# 0 when the file itself touches the timeouts (a plain SET/RESET, a SET LOCAL, a set_config call, a timeout named in a dollar-quoted body):
# such a file is never covered, because it can undo the connection-level caps the cover relies on.
timeout_tamper() {
  # Any mention of either timeout in the comment-stripped text (a CREATE/ALTER FUNCTION ... SET clause, an ALTER ROLE, a string
  # that feeds EXECUTE) means the file speaks about the caps it relies on: never covered.
  grep -qiE '(lock|statement)_timeout' <<<"$1" && return 0
  # Dynamic SQL can rebuild a timeout name from pieces ('lock_' || 'timeout'): EXECUTE, DISCARD and RESET ALL anywhere (a dropped
  # dollar-quoted body included, via @@body-dynamic) mean the file may undo the caps without ever naming them.
  # Statement-level only (one statement per line): GRANT/REVOKE EXECUTE and a string that says "execute" are not dynamic SQL.
  grep -qiE '^(execute|discard)([^A-Za-z_]|$)|^reset[[:space:]]+all|\\gexec' <<<"$1" && return 0
  # A function or DO body written as a quoted string (not $$) is not scanned for dynamic SQL: never covered.
  grep -qiE "^create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?(function|procedure)[[:space:]].*[[:space:]]as[[:space:]]+e?'|^do[[:space:]]+(language[[:space:]]+(\"[^\"]*\"|[a-z_]+)[[:space:]]+)?e?'" <<<"$1" && return 0
  grep -q '^@@body-dynamic' <<<"$1" && return 0
  has_override <<<"$1" || has_set_config <<<"$1" || has_set_config_dynamic <<<"$1" \
    || [ -n "$(set_values lock_timeout <<<"$1")" ] || [ -n "$(set_values statement_timeout <<<"$1")" ] \
    || grep -q '^@@body-timeout-do' <<<"$1" || grep -q '^@@body-timeout-function' <<<"$1"
}
# 0 when the file changes the SESSION timeouts (a plain SET/RESET, set_config, dynamic SQL, an unscanned quoted body). The migrations of one push
# share one connection, so such a change outlives the file and the connection-level caps no longer hold for the files after it.
session_taint() {
  has_override <<<"$1" && return 0
  has_set_config <<<"$1" && return 0
  has_set_config_dynamic <<<"$1" && return 0
  grep -q '^@@body-dynamic' <<<"$1" && return 0
  grep -q '^@@body-timeout-do' <<<"$1" && return 0         # a DO block that names a timeout runs at once
  grep -q '^@@body-timeout-function' <<<"$1" && return 0   # a function that names a timeout may be called later in the same file
  grep -qiE '^(execute|discard)([^A-Za-z_]|$)|\\gexec' <<<"$1" && return 0
  grep -qiE "^create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?(function|procedure)[[:space:]].*[[:space:]]as[[:space:]]+e?'|^do[[:space:]]+(language[[:space:]]+(\"[^\"]*\"|[a-z_]+)[[:space:]]+)?e?'" <<<"$1" && return 0
  return 1
}
# 0 when the file holds any transaction-control statement: such a file is never a plain no-transaction file.
has_txn_control() {
  awk '
    { l = tolower($0); gsub(/"/, "", l) }
    l ~ /^(begin|start[ \t]+transaction|commit|end|rollback|abort|prepare[ \t]+transaction|savepoint|release)([ \t;]|$)/ { found = 1 }
    END { exit found ? 0 : 1 }'
}

# Added files only. --no-renames: a renamed file is a new name, so a new version the push runs.
# ":(top)" anchors the pathspec at the repo root, so the listing is the same from any subdirectory.
GITLS=(git -c core.quotePath=false -c diff.relative=false diff --name-only --no-renames --diff-filter=A "$FROM..$TO")
LIST="$("${GITLS[@]}" -- ":(top)$MIGDIR/")" || { cm_warn "deploy-migration-check.sh: git diff failed for $FROM..$TO"; exit 1; }
ADDED_ALL="$("${GITLS[@]}")" || { cm_warn "deploy-migration-check.sh: git diff failed for $FROM..$TO"; exit 1; }
# The pathspec listing must agree with the full diff: if git reports added migrations that the listing lacks, fail closed.
MIG_RE="^${MIGDIR//./\\.}/[^/]*\\.sql\$"
n_all="$(printf '%s\n' "$ADDED_ALL" | grep -c "$MIG_RE")"; n_list="$(printf '%s\n' "$LIST" | grep -c "$MIG_RE")"
[ "$n_all" = "$n_list" ] || { cm_warn "deploy-migration-check.sh: the pathspec listing has $n_list added migrations but the full diff has $n_all: refusing to report"; exit 1; }

# Deploy mode: the first added migration (any, also one --only leaves out) that changes the session timeouts. Every file after it is refused the
# cover: its change stays on the shared push connection. Unreadable counts as a change (fail closed).
TAINT_FILE=""
if [ "$CAPS_EXPLICIT" = yes ]; then
  while IFS= read -r tf; do
    case "$tf" in "$MIGDIR"/*/*) continue ;; "$MIGDIR"/*.sql) ;; *) continue ;; esac
    traw="$(git show "$TO:$tf" 2>/dev/null)" || { TAINT_FILE="$tf"; break; }
    if session_taint "$(strip_sql <<<"$traw")"; then TAINT_FILE="$tf"; break; fi
  done <<<"$LIST"
fi
N_OK=0; N_ASK=0; N_STOP=0; N_EXC=0; N_COV=0; N_EXAM=0; SEEN=""; COVERED_FILES=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in \"*) cm_warn "deploy-migration-check.sh: git prints an added path quoted, cannot read it: $f"; exit 1 ;; esac
  case "$f" in "$MIGDIR"/*/*) continue ;; "$MIGDIR"/*.sql) ;; *) continue ;; esac   # a delta migration is a .sql file directly in the directory
  if [ -n "$ONLY" ]; then
    case $'\n'"$ONLY" in *$'\n'"$f"$'\n'*) ;; *) continue ;; esac   # --only: only the files named
    SEEN="$SEEN$f"$'\n'
  fi
  N_EXAM=$((N_EXAM + 1))
  raw="$(git show "$TO:$f" 2>/dev/null)" || { cm_warn "deploy-migration-check.sh: cannot read $f at $TO"; exit 1; }
  body="$(strip_sql <<<"$raw")"

  miss=""; NOTCOV=""
  has_stmt "$BEGIN_RE" <<<"$body" || miss="BEGIN;"
  has_stmt "$COMMIT_RE" <<<"$body" || miss="${miss:+$miss and }COMMIT;"
  if [ -n "$miss" ]; then
    # Only a plain file with no transaction control at all (the "no BEGIN; and COMMIT;" class) can be covered by the workflows'
    # connection-level caps; a half transaction, a ROLLBACK and every shape stop stay a STOP.
    if [ "$miss" = "BEGIN; and COMMIT;" ] && ! has_txn_control <<<"$body"; then
      if [ "$CAPS_EXPLICIT" = no ]; then
        # PR merge gate (no --caps-ref): strict, checked FIRST so no "not covered" text (which implies a cover exists) is ever printed here,
        # whatever the file contains. The author adds the in-file guard; the workflow caps are not offered as a substitute.
        NOTCOV="add the in-file guard: BEGIN; SET LOCAL lock_timeout = '3s'; SET LOCAL statement_timeout = '30s'; <your statements>; COMMIT;"
      elif timeout_tamper "$body"; then
        NOTCOV="not covered: the file touches a timeout or runs dynamic SQL (EXECUTE, DISCARD, RESET ALL)"
      elif [ -n "$TAINT_FILE" ] && [ "$f" != "$TAINT_FILE" ] && [ "$(printf '%s\n%s\n' "$TAINT_FILE" "$f" | LC_ALL=C sort | head -n 1)" = "$TAINT_FILE" ]; then
        NOTCOV="not covered: an earlier migration in this push ($TAINT_FILE) changes the session timeouts, and they stay changed on the shared connection for the files after it"
      else
        caps_covered
        if [ "$CAPS_OK" = yes ]; then
          printf 'covered (connection caps): %s\n' "$f"
          if [ "$N_COV" = 0 ]; then printf '%s' "$CAPS_LINES"; else printf '  (workflow proof as for the first covered file)\n'; fi
          N_COV=$((N_COV + 1)); COVERED_FILES="$COVERED_FILES $f"
          continue
        fi
        NOTCOV="not covered: the deploy workflows do not carry the caps in the shape the header describes (read at $CAPS_REF)${CAPS_WHY:+; $CAPS_WHY}"
      fi
    fi
    printf 'stop %s reason=no %s\n' "$f" "$miss"
    [ -z "$NOTCOV" ] || printf '  %s\n' "$NOTCOV"
    NOTCOV=""
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
if [ "$CAPS_EXPLICIT" = yes ]; then printf 'mode: deploy (--caps-ref %s: a plain unguarded file may be reported covered; the PR merge gate must not pass --caps-ref)\n' "$CAPS_REF"
else printf 'mode: pr-gate (strict: no --caps-ref, nothing is reported covered)\n'; fi
printf '%s migration files examined\n' "$N_EXAM"
printf 'summary: ok=%s exception=%s ask=%s stop=%s covered=%s (added migrations in %s..%s)\n' "$N_OK" "$N_EXC" "$N_ASK" "$N_STOP" "$N_COV" "$FROM" "$TO"
[ "$N_COV" -gt 0 ] && printf 'covered (not silent, reported on every run):%s\n' "$COVERED_FILES"
if [ "$N_STOP" -gt 0 ] && [ "$CAPS_EXPLICIT" = no ]; then
  printf 'note: a stop blocks the merge. The file is not on the base branch yet: edit it so one BEGIN; ... COMMIT; window holds every statement, with SET LOCAL lock_timeout = '"'3s'"' and SET LOCAL statement_timeout = '"'30s'"' first, and no ROLLBACK, COMMIT AND CHAIN, PREPARE TRANSACTION or statement outside the window (see the reason= above). The PR merge gate is strict: the deploy workflows'"'"' connection-level caps are not accepted here. If this version is already applied on staging, do NOT edit the file (the migration runner silently skips an edited applied file): that is a deploy-time case, run the window pre-check with --caps-ref <pinned sha>.\n'
  exit 3
fi
if [ "$N_STOP" -gt 0 ]; then
  printf 'note: a stop blocks the window. If that version is already applied on staging, do NOT edit the file (the migration runner tracks applied files by name and silently skips an edited one); the only fix is connection-level timeouts on the push step: the db-url form (options=-c lock_timeout=3s -c statement_timeout=120000, URL-encoded) in the workflow step that runs the push. The PGOPTIONS env is not a substitute: measured against a pinned Supabase CLI the push session ignored it (lock_timeout=0), so do not rely on it; the in-file SET LOCAL values stay 3s / 30s, 120000 is the connection-level cap only; prove the options reach the session with a SHOW lock_timeout in the same session.\n'
  exit 3
fi
[ "$N_ASK" -gt 0 ] && exit 2
exit 0
