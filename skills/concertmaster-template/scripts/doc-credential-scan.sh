#!/usr/bin/env bash
# doc-credential-scan.sh: refuse an email address AND a password-looking value on ONE added line of a
# tracked doc. A login written as `user@host.tld / Value` is not caught by key-shape scanners; this is the
# check for exactly that shape.
#
#   scripts/doc-credential-scan.sh --staged              # lines added to the index (pre-commit hook)
#   scripts/doc-credential-scan.sh --range <base>..<head> # lines added by a range (CI; <base>...<head> also works)
#   scripts/doc-credential-scan.sh --all                  # tracked files: COUNTS PER FILE; hits never fail it
#
# Exit: 0 clean (or --all finished), 1 a blocking hit, 2 could not look (not a repo, bad range, unreadable
# input). A scan that could not look is never clean.
#
# SCOPE: tracked docs and text files only, any directory: *.md *.mdx *.txt *.yaml *.yml *.json, minus
# lockfiles and node_modules. Source code and tests (*.ts, *.tsx, *.sh, *.sql ...) are OUT OF SCOPE for this
# rule, and gitleaks has no email-plus-password rule either, so such a line in source is NOT caught by this check.
#
# THE RULE: one ADDED line (diff modes only look at added lines) that holds
#   1. an email address whose domain is not a placeholder (example.com, example.org, example.net, test.invalid,
#      localhost, and subdomains of the first four), AND
#   2. a password-looking value in one of these shapes:
#      named-password-value    `password` `passwd` `pwd` `pass` `pw` `passphrase` `passcode` `login` `credentials`, then `:` `=` `=>` `->` `/` `|`
#                              or `is`, then a value of 8+ characters that mixes at least 3 of lower/upper/digit/symbol
#                              (JSON keys, YAML, table cells, bold or backticked values included)
#      named-password-letters  as above, but only after password, passwd, pwd, passphrase or passcode: a pure-letter value of 8+
#      email-value-pair        the email, then `/` `|` `:` `=>` or `->`, then a mixed 8+ value (`email / value`, a table
#                              row `| email | value |`, `email:value`)
#      url-credentials         `email:value@host`, an email as the user part of a URL
#      table-row-value         a table row (starts with `|`) with a mixed 8+ value in ANY cell, when the row holds a
#                              password-ish word or an earlier added row of the same table does (a header like
#                              `| Email | Password |`; only password, passwd, pwd, passphrase or passcode count as that word,
#                              not pass, pw or login, which head unrelated columns)
#   A password word followed by plain whitespace ("with password Value1!", "(pw Value1!)", "password `Value1!`") counts
#   too, for a mixed value only; a pure-letter value still needs a real separator. A value that starts with `/` is a
#   path, and a value is rejected as an email only when it looks like one (`P@ssw0rd!` is a value).
#   Placeholders never count as a value: <...> ${...} $VAR {{...}} %VAR% xxx... ***** ... changeme example password
#   redacted REDACTED your/my-password (exact words, so ChangeMe2024! is still a value). UUIDs, dates, versions, hashes, file
# names, URLs and word-like identifiers (letters with - _ . only, no digit) are not values.
#
# ALLOWLIST: an added line carrying `credential-ok:` followed by a reason of 3 or more words is skipped. The skip is
# counted and printed as `path:line: allowed: <reason>`; a reason with digits, symbols or the matched value is printed as
# "reason withheld" so the allowlist cannot leak what it excuses (a reason is printed only when it is plain words: no
# digits, dots, symbols or email-shaped token). Known local-only test users are allowed ONLY this way, never by name
# here. When GITHUB_ACTIONS=true each allowed line is also a `::warning file=,line=::` annotation (path, line and the
# same safe reason) so a reviewer sees every use. JSON has no comments: put the marker in a string value on the SAME
# line (a one-line object with a "_note" key); a line the marker cannot reach moves to a .md file. Pretty-printed JSON
# with the email and the password on separate lines is a different shape and is not caught by this per-line rule.
#
# OUTPUT: path, line number and rule only. The matched line, the email and the value are NEVER printed, not even a
# fragment. Tools used: bash, git, awk, grep, mktemp, rm, cat, sort (nothing else, so the hook works on a bare PATH).
# Not covered: a credential split over several lines, source files, images, and a value with no password-ish name and no
# email beside it; fullwidth characters, a `;` or `-` or arrow before a value, html wrappers, values with spaces, a
# letter-only value after `login:`, and .rst .csv .toml .html .mdc .ipynb files. A row added under an UNCHANGED
# password header has no header line in the diff, so only its own password word or an added header triggers the row rule. A line added and removed inside one range is not seen
# (net diff; where a PR lands as merge commits, such a first commit stays in history). A lowercase-plus-digits value is
# caught after password, passwd, pwd, passphrase or passcode with a real separator, not after pass, pw or login. Unless the
# project makes the CI step a required status check, a red job is only a signal a human reads; the pre-commit hook is the
# only layer that stops a commit.
set -uo pipefail
export LC_ALL=C

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "doc-credential-scan: $*" >&2; exit 2; }

MODE=""; RANGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) [ -z "$MODE" ] || usage; MODE=staged ;;
    --all)    [ -z "$MODE" ] || usage; MODE=all ;;
    --range)  [ -z "$MODE" ] || usage; [ $# -ge 2 ] || usage; MODE=range; RANGE="$2"; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done
[ -n "$MODE" ] || usage

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree"
cd "$TOP" || die "cannot enter $TOP"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/doc-cred-scan.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "${TMP:?}"' EXIT

# ---- the detector (awk; ASCII only, no gawk extensions, no {n} intervals so mawk works too) -------------------
cat > "$TMP/detect.awk" <<'AWK'
BEGIN {
  nkw = split("password passwd pwd passphrase passcode pass pw login credentials", KW, " ")
  stoplist = " required optional mandatory disabled enabled hidden masked hashed encrypted entered provided supplied unchanged unknown "
  inhunk = 0; ln = 0; hdr = 0
}
function classes(v,   n) {
  n = 0
  if (v ~ /[a-z]/) n++
  if (v ~ /[A-Z]/) n++
  if (v ~ /[0-9]/) n++
  if (v ~ /[^A-Za-z0-9]/) n++
  return n
}
function is_ph_domain(d) {
  d = tolower(d)
  if (d == "example.com" || d == "example.org" || d == "example.net" || d == "test.invalid" || d == "localhost") return 1
  if (d ~ /\.example\.(com|org|net)$/ || d ~ /\.test\.invalid$/) return 1
  return 0
}
function is_placeholder(v,   lv, c2) {
  lv = tolower(v); c2 = substr(v, 1, 2)
  if (substr(v, 1, 1) == "<") return 1
  if (c2 == "${" || c2 == "{{") return 1
  if (v ~ /^\$[A-Z_][A-Z0-9_]*$/) return 1
  if (v ~ /^%[A-Za-z_]+%$/) return 1
  if (v ~ /^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$/) return 1                          # a secret NAME (E2E_PASSWORD_2), not a value
  if (lv ~ /^[x-]+$/ && length(lv) >= 3) return 1
  if (v ~ /^[*]+$/ || v ~ /^[.]+$/) return 1
  if (lv == "changeme" || lv == "change-me" || lv == "change_me" || lv == "example" || lv == "placeholder" || lv == "redacted") return 1
  if (lv == "password" || lv == "yourpassword" || lv == "your-password" || lv == "your_password" || lv == "mypassword") return 1
  return 0
}
function not_pw_shape(v,   lv) {
  lv = tolower(v)
  if (length(v) == 36 && lv ~ /^[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+$/) return 1   # uuid
  if (lv ~ /^[0-9a-f]+$/ && length(v) >= 16) return 1                                            # hash, long hex id
  if (v ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return 1                                # date, timestamp
  if (v ~ /^[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9]-[0-9][0-9][0-9][0-9]$/) return 1                  # Mon-DD-YYYY
  if (v ~ /^[0-9][0-9]?:[0-9][0-9]/) return 1                                                    # 10:30AM-Mon
  if (v ~ /^[vV]?[0-9]+\.[0-9]+\.[0-9]+/) return 1                                               # version
  if (lv ~ /^[a-z0-9._-]+\.(md|mdx|txt|ts|tsx|js|jsx|sh|sql|json|ya?ml|png|jpe?g|svg|css|html)$/) return 1   # file name
  return 0
}
function judge(v, pwname, strict, loose,   n) {
  if (v == "" || v ~ /[ \t\r]/) return ""
  if (is_placeholder(v)) return ""
  if (v ~ /@[A-Za-z0-9-]+[.][A-Za-z]/ || v ~ /:\/\// || not_pw_shape(v)) return ""      # an email, not a value with an @ in it
  if (v ~ /^\//) return ""                                                                  # a path (/auth/v1/recover)
  if (strict && v ~ /\//) return ""
  if (strict && v ~ /^[a-z][a-z][a-z]?[a-z]?[a-z]?_[A-Za-z0-9]+$/) return ""     # a prefixed id (cus_Nf8aKz2Qw1, usr_8fK2mQ9x)
  if (strict && v ~ /^[a-z0-9]+([-_.][a-z0-9]+)+$/) return ""     # a slug in a table cell (reset-flow-2024)
  n = length(v)
  # a word-like identifier (Super-Admin, Reset-Password-Flow) has no digit and no symbol beyond - _ .
  if (n >= 8 && classes(v) >= 3 && (v ~ /[0-9]/ || v ~ /[^A-Za-z0-9_.-]/)) return "M"
  # a strong password word with a real separator also takes letters+digits only (password: hunter2024abc)
  if (loose && n >= 8 && v ~ /^[A-Za-z0-9]+$/ && v ~ /[0-9]/ && v ~ /[A-Za-z]/) return "M"
  if (pwname && n >= 8 && v ~ /^[A-Za-z]+$/ && index(stoplist, " " tolower(v) " ") == 0) return "L"
  return ""
}
# the value at the start of s: skips spaces and markdown wrappers, honours a quote or backtick, else runs to a delimiter
function take(s,   c, i, n, t, e) {
  while (s != "") {
    c = substr(s, 1, 1)
    if (c == " " || c == "\t" || c == "*" || c == "(" || c == "[") s = substr(s, 2); else break
  }
  c = substr(s, 1, 1)
  if (c == "`" || c == "'" || c == "\"") {
    s = substr(s, 2); e = index(s, c)
    if (e > 0) return substr(s, 1, e - 1)
    return s
  }
  n = length(s); t = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c ~ /[ \t\r|]/) break
    t = t c
  }
  while (t != "" && substr(t, length(t), 1) ~ /[].,;:)*`'"]/) t = substr(t, 1, length(t) - 1)
  return t
}
function find_emails(s,   rest, off, st, len, em, dom, k) {
  nem = 0; real = 0; off = 0; rest = s
  while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/)) {
    st = RSTART; len = RLENGTH
    em = substr(rest, st, len); dom = substr(em, index(em, "@") + 1)
    k = dom; sub(/^.*\./, "", k)
    if (k ~ /^[A-Za-z][A-Za-z]+$/) {
      nem++; ES[nem] = off + st; EE[nem] = off + st + len
      EP[nem] = is_ph_domain(dom)
      if (!EP[nem]) real = 1
    }
    off += st + len - 1
    rest = substr(rest, st + len)
  }
}
function rule_pair(line,   i, rest, c, tok, r, direct, at, kind, m) {
  for (i = 1; i <= nem; i++) {
    if (EP[i]) continue
    rest = substr(line, EE[i])
    direct = (substr(rest, 1, 1) == ":")
    while (rest != "" && substr(rest, 1, 1) ~ /[]`'">* \t)]/) rest = substr(rest, 2)
    c = substr(rest, 1, 1)
    if (substr(rest, 1, 2) == "=>" || substr(rest, 1, 2) == "->") rest = substr(rest, 3)
    else if (c == "/" || c == "|" || c == ":") rest = substr(rest, 2)
    else continue
    tok = take(rest); kind = "email-value-pair"
    if (direct && c == ":") {
      at = 0; for (m = length(tok); m >= 1; m--) if (substr(tok, m, 1) == "@") { at = m; break }
      if (at > 0 && substr(tok, at + 1) ~ /[.:\/]/) { tok = substr(tok, 1, at - 1); kind = "url-credentials" }    # user:value@host
    }
    r = judge(tok, 0, 1)
    if (r != "") { VAL = tok; return kind }
  }
  return ""
}
# true when a STRONG password word (password passwd pwd passphrase passcode; not pass, pw, login, which head
# unrelated columns) is on the line, with the word boundaries of rule_named
function has_kw(line,   low, k, pos, j, st, en, pc, fc) {
  low = tolower(line)
  for (k = 1; k <= 5; k++) {
    pos = 1
    while ((j = index(substr(low, pos), KW[k])) > 0) {
      st = pos + j - 1; en = st + length(KW[k]); pos = st + 1
      if (st > 1) {
        pc = substr(line, st - 1, 1); fc = substr(line, st, 1)
        if (pc ~ /[0-9]/) continue
        if (pc ~ /[A-Za-z]/ && !(pc ~ /[a-z]/ && fc ~ /[A-Z]/)) continue
      }
      if (substr(line, en, 1) ~ /[A-Za-z]/) continue
      return 1
    }
  }
  return 0
}
# a table row under a password-ish header (an earlier added row) or holding a password-ish word: any cell with a mixed value
function rule_row(line,   n, cells, i, c, r) {
  if (line !~ /^[ \t]*\|/) return ""
  if (!hdr && !has_kw(line)) return ""
  n = split(line, cells, "|")
  for (i = 1; i <= n; i++) {
    c = take(cells[i])
    r = judge(c, 0, 1)
    if (r != "") { VAL = c; return "table-row-value" }
  }
  return ""
}
function rule_named(line,   low, k, name, isp, pos, j, st, en, pc, fc, rest, w, tok, r, gap, nosep, strong) {
  low = tolower(line)
  for (k = 1; k <= nkw; k++) {
    name = KW[k]; isp = (k <= 7); strong = (k <= 5); pos = 1
    while ((j = index(substr(low, pos), name)) > 0) {
      st = pos + j - 1; en = st + length(name); pos = st + 1
      if (st > 1) {
        pc = substr(line, st - 1, 1); fc = substr(line, st, 1)
        if (pc ~ /[0-9]/) continue
        if (pc ~ /[A-Za-z]/ && !(pc ~ /[a-z]/ && fc ~ /[A-Z]/)) continue
      }
      if (substr(line, en, 1) ~ /[A-Za-z]/) continue
      rest = substr(line, en); gap = length(rest); nosep = 0
      while (rest != "" && substr(rest, 1, 1) ~ /[]`'"* \t]/) rest = substr(rest, 2)
      gap = (length(rest) < gap)
      w = substr(rest, 1, 2)
      if (w == ":=" || w == "=>" || w == "->" || w == "==") rest = substr(rest, 3)
      else if (!strong && substr(rest, 1, 1) ~ /[\/|]/) continue    # Pass | Fail columns, Pass/Fail, login/signup
      else if (substr(rest, 1, 1) ~ /[:=\/|]/) rest = substr(rest, 2)
      else if (tolower(rest) ~ /^is([ \t:]|$)/) { rest = substr(rest, 3); if (substr(rest, 1, 1) == ":") rest = substr(rest, 2) }
      else if (tolower(rest) ~ /^was([ \t:]|$)/) { rest = substr(rest, 4); if (substr(rest, 1, 1) == ":") rest = substr(rest, 2) }
      else if (tolower(rest) ~ /^are([ \t:]|$)/) { rest = substr(rest, 4); if (substr(rest, 1, 1) == ":") rest = substr(rest, 2) }
      else if (isp && gap) nosep = 1        # "password Value1!", "(pw Hunter2024!)": plain whitespace, mixed values only
      else continue
      tok = take(rest)
      r = judge(tok, isp, !strong, strong && !nosep)      # pass, pw, login, credentials: a word-like value (1Password/Ops, a slug, a path) is not a password
      if (nosep && r != "M") r = ""
      if (r == "L" && !strong) r = ""         # pass / pw: a letters-only word is too often prose (a Pass column)
      if (r != "") { VAL = tok; return (r == "L") ? "named-password-letters" : "named-password-value" }
    }
  }
  return ""
}
# the reason after `credential-ok:`, trimmed; prints "" when it is under 3 words
function reason_of(line,   mk, r, nw, i, ws, n) {
  mk = index(line, "credential-ok:")
  if (mk == 0) return ""
  r = substr(line, mk + 14)
  sub(/[ \t]*(-->|\*\/|%>|\}\}).*$/, "", r)
  sub(/[]"`}].*$/, "", r)                                   # the end of a JSON string value or a closing bracket
  sub(/'+[ \t]*$/, "", r)                                      # a closing single quote; an apostrophe inside the reason stays
  gsub(/[ \t\r]+/, " ", r); sub(/^ /, "", r); sub(/ $/, "", r)
  n = split(r, ws, " "); nw = 0
  for (i = 1; i <= n; i++) if (ws[i] ~ /[A-Za-z0-9]/) nw++
  return (nw >= 3) ? r : ""
}
function check(line, num,   rule, rsn) {
  if (line ~ /^[ \t]*\|/) { if (has_kw(line)) hdr = 1 } else hdr = 0     # a table whose header row names a password
  if (index(line, "@") == 0) return
  find_emails(line)
  if (!real) return
  VAL = ""
  rule = rule_pair(line)
  if (rule == "") rule = rule_row(line)
  if (rule == "") rule = rule_named(line)
  if (rule == "") return
  rsn = reason_of(line)
  if (rsn != "") {
    if (rsn !~ /^[A-Za-z ,'-]+$/ || length(rsn) > 80 || (VAL != "" && index(tolower(rsn), tolower(VAL)) > 0)) rsn = "reason withheld"
    print "A\t" num "\t" rsn
    return
  }
  print "H\t" num "\t" rule
}
{
  if (mode == "diff") {
    if ($0 ~ /^diff --git /) { inhunk = 0; hdr = 0; next }
    if ($0 ~ /^@@ /) { hdr = 0; if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; inhunk = 1; next }
    if (inhunk && substr($0, 1, 1) == "+") { check(substr($0, 2), ln); ln++ }
    next
  }
  check($0, NR)
}
AWK

# ---- scope --------------------------------------------------------------------------------------------------
in_scope() { # in_scope <path>
  case "$1" in node_modules/*|*/node_modules/*) return 1 ;; esac
  case "${1##*/}" in
    package-lock.json|npm-shrinkwrap.json|pnpm-lock.yaml|yarn.lock|*.lock|*-lock.json|*-lock.yaml|*-lock.yml|*.lock.json) return 1 ;;
    *.[mM][dD]|*.[mM][dD][xX]|*.[tT][xX][tT]|*.[yY][aA][mM][lL]|*.[yY][mM][lL]|*.[jJ][sS][oO][nN]) return 0 ;;
  esac
  return 1
}
ann_esc() { # escape a workflow-command property or message
  local s="$1"; s="${s//'%'/%25}"; s="${s//$'\r'/%0D}"; s="${s//$'\n'/%0A}"; s="${s//:/%3A}"; s="${s//,/%2C}"
  printf '%s' "$s"
}
clean_path() { printf '%s' "${1//[^[:print:]]/?}"; }

run_detect() { # run_detect <mode diff|file> : stdin -> $TMP/out ; returns 2 when awk failed
  awk -v mode="$1" -f "$TMP/detect.awk" > "$TMP/out" || return 2
}

HITS=0; ALLOWED=0; BADFILES=0; FILES=0; HITFILES=0

# ---- diff modes ---------------------------------------------------------------------------------------------
if [ "$MODE" = "staged" ] || [ "$MODE" = "range" ]; then
  if [ "$MODE" = "range" ]; then
    case "$RANGE" in -*) die "bad range" ;; esac
    case "$RANGE" in
      *...*) A="${RANGE%%...*}"; B="${RANGE#*...}" ;;
      *..*)  A="${RANGE%%..*}";  B="${RANGE#*..}" ;;
      *) die "bad range '<base>..<head>' expected" ;;
    esac
    [ -n "$A" ] && [ -n "$B" ] || die "bad range: both ends are required"
    git rev-parse --verify --quiet "${A}^{commit}" >/dev/null 2>&1 || die "bad range: base is not a commit here"
    git rev-parse --verify --quiet "${B}^{commit}" >/dev/null 2>&1 || die "bad range: head is not a commit here"
    DIFFARGS=("$RANGE")
  else
    DIFFARGS=(--cached)
  fi
  git diff "${DIFFARGS[@]}" --name-only -z --no-renames --diff-filter=d --no-ext-diff --no-textconv > "$TMP/names" 2>/dev/null \
    || die "git diff failed, nothing was scanned"
  while IFS= read -r -d '' p; do
    in_scope "$p" || continue
    FILES=$((FILES + 1))
    git --literal-pathspecs diff -U0 --no-color --text --no-renames --no-ext-diff --no-textconv "${DIFFARGS[@]}" -- "$p" > "$TMP/d" 2>/dev/null \
      || { echo "doc-credential-scan: cannot read the diff of $(clean_path "$p")" >&2; BADFILES=$((BADFILES + 1)); continue; }
    run_detect diff < "$TMP/d" || { echo "doc-credential-scan: detector failed on $(clean_path "$p")" >&2; BADFILES=$((BADFILES + 1)); continue; }
    fh=0
    while IFS=$'\t' read -r kind n what; do
      case "$kind" in
        H) printf '%s:%s: %s\n' "$(clean_path "$p")" "$n" "$what"; HITS=$((HITS + 1)); fh=1 ;;
        A) printf '%s:%s: allowed: %s\n' "$(clean_path "$p")" "$n" "$what"; ALLOWED=$((ALLOWED + 1))
           [ "${GITHUB_ACTIONS:-}" != "true" ] || printf '::warning file=%s,line=%s::doc-credential-scan: allowed by a credential-ok marker (%s), a reviewer should confirm it\n' "$(ann_esc "$(clean_path "$p")")" "$n" "$(ann_esc "$what")" ;;
      esac
    done < "$TMP/out"
    HITFILES=$((HITFILES + fh))
  done < "$TMP/names"
  if [ "$BADFILES" -gt 0 ]; then echo "doc-credential-scan: $BADFILES file(s) could not be scanned (exit 2)" >&2; exit 2; fi
  if [ "$HITS" -gt 0 ]; then
    echo "doc-credential-scan: $HITS blocking hit(s) in $HITFILES file(s) (path:line:rule only, the line is never printed), $ALLOWED allowed." >&2
    echo "  Remove the email-plus-password line: describe WHERE the login lives (a secret store, a file path), never the value." >&2
    echo "  A documented local-only test user may carry 'credential-ok: <reason of 3+ words>' on the same line." >&2
    exit 1
  fi
  echo "doc-credential-scan: clean ($FILES doc file(s) with added lines checked, $ALLOWED allowed)"
  exit 0
fi

# ---- --all: counts per file, reports and never blocks ---------------------------------------------------------
git grep --cached -I -l -z -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+[.][A-Za-z]' -- \
  '*.[mM][dD]' '*.[mM][dD][xX]' '*.[tT][xX][tT]' '*.[yY][aA][mM][lL]' '*.[yY][mM][lL]' '*.[jJ][sS][oO][nN]' > "$TMP/cands" 2>/dev/null
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || die "git grep failed (exit $rc), nothing was scanned"
echo "doc-credential-scan --all: hits and allowed lines per file (counts only; hits never fail this mode, exit 2 only when a file cannot be read)"
while IFS= read -r -d '' p; do
  in_scope "$p" || continue
  FILES=$((FILES + 1))
  git cat-file blob ":$p" > "$TMP/blob" 2>/dev/null || { echo "doc-credential-scan: cannot read the index copy of $(clean_path "$p")" >&2; BADFILES=$((BADFILES + 1)); continue; }
  run_detect file < "$TMP/blob" || { echo "doc-credential-scan: detector failed on $(clean_path "$p")" >&2; BADFILES=$((BADFILES + 1)); continue; }
  h=0; a=0
  while IFS=$'\t' read -r kind _n _what; do
    case "$kind" in H) h=$((h + 1)) ;; A) a=$((a + 1)) ;; esac
  done < "$TMP/out"
  if [ $((h + a)) -gt 0 ]; then
    printf '%s: %s hit(s), %s allowed\n' "$(clean_path "$p")" "$h" "$a"
    HITS=$((HITS + h)); ALLOWED=$((ALLOWED + a)); HITFILES=$((HITFILES + 1))
  fi
done < "$TMP/cands"
echo "total: $HITS hit(s) in $HITFILES file(s), $ALLOWED allowed, $FILES candidate file(s) read"
if [ "$BADFILES" -gt 0 ]; then echo "doc-credential-scan: $BADFILES file(s) could not be scanned (exit 2)" >&2; exit 2; fi
exit 0
