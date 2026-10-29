#!/usr/bin/env bash
# scan-secrets.sh: count secret-shaped strings in agent transcripts. COUNTS ONLY: it prints a
# pattern class, a file path and a number, never the matched text or any fragment of it.
#
#   scripts/scan-secrets.sh                     # scan the configured transcript dirs
#   scripts/scan-secrets.sh PATH...             # scan these files / dirs instead (CLI override)
#   scripts/scan-secrets.sh --since-days 2 ...  # only files modified in the last N (>= 1) days
#   scripts/scan-secrets.sh --strict ...        # advisory classes also decide the exit code
#
# Default dirs: config credentials.transcript_dirs (a list), else $CM_CLAUDE_PROJECTS, else
# ~/.claude/projects. A config that is unreadable or wrong-shaped exits 2. Symlinks are followed. A dir is searched for *.jsonl and *.log; a file argument is scanned as is.
# Classes (strict = decides the exit code):
#   private_key     strict    PEM block header
#   token_prefix    strict    vendor prefix + long body (sk-ant-, sk-None-, ghp_, whsec_, sbp_, ...), not inside a longer word
#   jwt             strict    three base64url parts, the first two starting eyJ
#   aws_key         strict    AKIA/ASIA + 16
#   url_credential  strict    scheme://user:password@host with a password-shaped password
#   bearer_token    strict    "Bearer <opaque value>" (24+ chars; under 32 it needs 3 character classes, so all-lowercase hex is not counted)
#   password_assign advisory  password/secret/api key/access token style name, then : or =, then a
#                             value of 10+ chars that mixes at least 3 of lower/upper/digit/symbol,
#                             or is a 32+ char token with letters and digits. Identifiers, paths,
#                             env names (STRIPE_SECRET_KEY) and plain words do not count. A heuristic:
#                             a hit is a lead to check, not proof. Pure-letter passwords are missed.
# Counts are occurrences: a repeated secret counts each time. Each class counts its own matches, so a
# URL or an assignment that carries a vendor token counts in url_credential or password_assign AND in
# token_prefix (never skipped: a strict class must match for a value to count as covered). The jwt class cannot tell a
# public anon key or a short session token from a service-role key: a hit is a lead.
#
# Output (tab separated, stdout):
#   CLASS <tab> TOTAL <tab> FILES <tab> strict|advisory   one row per class
#   FILE <tab> PATH <tab> CLASS <tab> COUNT               only where COUNT > 0
#   SUMMARY files=<n> hits=<strict n> advisory=<n> errors=<n>
# Exit 1 on a strict hit (advisory too with --strict). Else exit 2 when anything could not be read
# (a file, a dir, a grep failure), or nothing existed to scan: a scan that could not look is never
# "clean". Else 0.
# Safety: grep output goes to awk only, awk prints counts, stderr of grep is dropped, no xtrace.
# File paths ARE printed (a path is not a secret), so do not keep a secret in a file name.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

SINCE=""
STRICT=0
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    --strict) STRICT=1; shift ;;
    --since-days)
      case "${2:-}" in ''|0*|*[!0-9]*|[0-9][0-9][0-9][0-9][0-9][0-9]*) cm_warn "scan-secrets.sh: --since-days needs a whole number from 1 to 99999, no leading zero"; exit 2 ;; esac
      SINCE="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done ;;
    -*) cm_warn "scan-secrets.sh: unknown option: $1"; exit 2 ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

if [ "${#PATHS[@]}" -eq 0 ]; then
  # Default dirs come from config. A config that is named but unreadable, cannot be parsed, or holds
  # a wrong-shaped credentials / transcript_dirs must not fall back to the default dir quietly: that
  # would report "clean" for dirs the owner never asked to scan.
  if [ -n "${CM_CONFIG:-}" ] && [ -z "$CM_CONFIG_FILE" ]; then
    cm_warn "scan-secrets.sh: CM_CONFIG is set but unreadable; fix it or pass PATH arguments"; exit 2
  fi
  cfg_state=none
  if [ -n "$CM_CONFIG_FILE" ]; then
    if ! command -v jq >/dev/null 2>&1 || ! command -v yq >/dev/null 2>&1; then
      cm_warn "scan-secrets.sh: jq and yq are needed to read $CM_CONFIG_FILE; pass PATH arguments instead"; exit 2
    fi
    [ "$CM_CFG_JSON" != "{}" ] || { cm_warn "scan-secrets.sh: config $CM_CONFIG_FILE is empty or unreadable as YAML"; exit 2; }
    cfg_state="$(printf '%s' "$CM_CFG_JSON" | jq -r '
      if .credentials == null then "none"
      elif (.credentials | type) != "object" then "bad"
      elif (.credentials | has("transcript_dirs") | not) then "none"
      elif (.credentials.transcript_dirs | type) == "null" then "none"
      elif (.credentials.transcript_dirs | type) == "array" and (.credentials.transcript_dirs | all(type == "string")) then "ok"
      else "bad" end' 2>/dev/null)" || cfg_state=bad
    [ "$cfg_state" = ok ] || [ "$cfg_state" = none ] || { cm_warn "scan-secrets.sh: credentials.transcript_dirs in $CM_CONFIG_FILE must be a list of paths (and credentials a map)"; exit 2; }
  fi
  if [ "$cfg_state" = ok ]; then
    while IFS= read -r d; do
      case "$d" in \~/*) d="$HOME/${d#\~/}" ;; esac
      PATHS+=("$d")
    done < <(printf '%s' "$CM_CFG_JSON" | jq -r '.credentials.transcript_dirs[]')
  fi
  [ "${#PATHS[@]}" -gt 0 ] || PATHS+=("${CM_CLAUDE_PROJECTS:-$HOME/.claude/projects}")
fi

# ci <WORD>: a case-insensitive ERE for a word, each letter as [xX] (portable, no GNU sed \L \U).
ci() { printf '%s' "$1" | awk '{ o = ""; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c ~ /[A-Za-z]/) o = o "[" tolower(c) toupper(c) "]"; else o = o c } print o }'; }

# One grep pass per class (a single combined alternation is 50x slower on large transcripts); every
# match goes to one awk that classifies it and prints counts only.
# Split literals keep this file itself free of secret-shaped text.
RE_PK='-----BEGIN [A-Z ]*PRI''VATE KEY-----'
# Prefixes that cannot be ordinary kebab-case text or sit inside base64 match anywhere (a key glued to
# "key-", "%3D" or a JSON-escaped newline still counts). Prefixes that can (admin, or, svcacct, None,
# AIza, the legacy bare sk-48 key) need a left boundary: line start, a JSON/URL escape (\n \t \r %XX)
# or a char that is not alnum, _ or -. awk strips the boundary before classifying.
BND='(^|\\[ntr]|%[0-9A-Fa-f]{2}|[^A-Za-z0-9_-])'
RE_TP='(sk-ant-|sk-proj-|sk_live_|sk_test_|rk_live_|rk_test_|whsec_|ghp_|gho_|ghs_|ghu_|ghr_|github_pat_|xox[abeprs]-|sbp_|sb_secret_)[A-Za-z0-9_-]{16,}'
RE_TPB="${BND}(sk-svcacct-|sk-admin-|sk-or-|sk-None-|AIza)[A-Za-z0-9_-]{16,}"
RE_SK="${BND}sk-[A-Za-z0-9]{48}"
RE_JWT='eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
RE_AWS='(AKIA|ASIA)[A-Z0-9]{16}'
RE_URL="[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@\"']{1,64}:[^/[:space:]@\"']{6,}@"
PWNAME="($(ci PASSWORD)|$(ci PASSWD)|$(ci PWD)|$(ci SECRET)|$(ci API)_?$(ci KEY)|$(ci ACCESS)_?$(ci TOKEN)|$(ci AUTH)_?$(ci TOKEN))"
RE_PW="${PWNAME}[A-Za-z_]{0,12}[\\\\\"']{0,6}[[:space:]]*[:=][[:space:]]*[\\\\\"']{0,6}[^[:space:]\"',;)}\\\\]{10,}"
RE_BEARER="$(ci BEARER)[[:space:]]+[A-Za-z0-9._~+/=-]{24,}"
RES=("$RE_PK" "$RE_TP" "$RE_TPB" "$RE_SK" "$RE_JWT" "$RE_AWS" "$RE_URL" "$RE_PW" "$RE_BEARER")

# shellcheck disable=SC2016  # awk program, no shell expansion wanted
AWK_CLASSIFY='
function shape(v, min,    lo, up, di, ot, cls) {
  if (v == "") return 0
  if (v ~ /^[\/~$<{*%]/ || v ~ /:\/\// || v ~ /^[A-Z0-9_]+$/) return 0
  lo = (v ~ /[a-z]/); up = (v ~ /[A-Z]/); di = (v ~ /[0-9]/); ot = (v ~ /[^A-Za-z0-9_.-]/)
  cls = lo + up + di + ot
  if (cls >= min) return 1
  if (length(v) >= 32 && v ~ /^[A-Za-z0-9+=_-]+$/ && di && (lo || up)) return 1
  return 0
}
{
  m = $0
  if (m == "@@GREPFAIL") { c["@@fail"]++; next }
  # the boundary of a bounded-prefix match: an escape, then any run of non-key bytes (multibyte safe)
  if (m ~ /^(\\[ntr]|%[0-9A-Fa-f][0-9A-Fa-f])/) sub(/^(\\[ntr]|%[0-9A-Fa-f][0-9A-Fa-f])/, "", m)
  if (m ~ /^[^A-Za-z0-9_-]/) sub(/^[^A-Za-z0-9_-]+/, "", m)
  if (m ~ /^-----BEGIN/) c["private_key"]++
  else if (m ~ /^eyJ/) c["jwt"]++
  else if (m ~ /^(AKIA|ASIA)/) c["aws_key"]++
  else if (m ~ /^(sk-|sk_live_|sk_test_|rk_live_|rk_test_|whsec_|gh[poushr]_|github_pat_|xox|sbp_|sb_secret_|AIza)/) c["token_prefix"]++
  else if (tolower(m) ~ /^bearer[ \t]/) {
    v = m; sub(/^[Bb][Ee][Aa][Rr][Ee][Rr][ \t]+/, "", v)
    if (shape(v, 3)) c["bearer_token"]++
  } else if (m ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) {
    p = m; sub(/^[^:]*:\/\/[^:]*:/, "", p); sub(/@$/, "", p)
    if (shape(p, 2)) c["url_credential"]++
  } else {
    i = match(m, /[:=]/); v = substr(m, i + 1); sub(/^[ \t\\"\047]*/, "", v)
    if (shape(v, 3)) c["password_assign"]++
  }
}
END { for (k in c) print k "\t" c[k] }'

STRICT_CLASSES="private_key token_prefix jwt aws_key url_credential bearer_token"
ALL_CLASSES="$STRICT_CLASSES password_assign"

LIST="$(mktemp "${TMPDIR:-/tmp}/cm-scan-list.XXXXXX")" || { cm_warn "scan-secrets.sh: cannot create a temp file"; exit 2; }
trap 'rm -f -- "${LIST:?}" "${TMP:-}"' EXIT
FILES=()
errors=0
anydir=0
for p in "${PATHS[@]}"; do
  case "$p" in -*) p="./$p" ;; esac   # find would read a leading - as an expression
  if [ -f "$p" ]; then
    FILES+=("$p")
  elif [ -d "$p" ]; then
    anydir=1
    if [ ! -r "$p" ] || [ ! -x "$p" ]; then cm_warn "scan-secrets.sh: cannot read dir: $p"; errors=$((errors + 1)); continue; fi
    if [ -n "$SINCE" ]; then
      find -L "$p" \( -type f -o -type l \) \( -name '*.jsonl' -o -name '*.log' \) -mmin "-$((SINCE * 1440))" -print0 > "$LIST" 2>/dev/null
    else
      find -L "$p" \( -type f -o -type l \) \( -name '*.jsonl' -o -name '*.log' \) -print0 > "$LIST" 2>/dev/null
    fi || { cm_warn "scan-secrets.sh: could not list all of: $p"; errors=$((errors + 1)); }
    while IFS= read -r -d '' f; do FILES+=("$f"); done < "$LIST"
  else
    cm_warn "scan-secrets.sh: not found: $p"
    errors=$((errors + 1))
  fi
done
if [ "${#FILES[@]}" -eq 0 ] && [ "$anydir" -eq 0 ]; then
  cm_warn "scan-secrets.sh: nothing to scan"
  exit 2
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/cm-scan.XXXXXX")" || { cm_warn "scan-secrets.sh: cannot create a temp file"; exit 2; }
for f in ${FILES[@]+"${FILES[@]}"}; do
  case "$f" in
    *$'\t'*|*$'\n'*) cm_warn "scan-secrets.sh: path with a TAB or newline cannot be reported, counted as an error"; errors=$((errors + 1)); continue ;;
  esac
  # Only regular files (a symlink to one is fine). A FIFO, a socket or a broken link is an error: never opened.
  if [ ! -f "$f" ]; then cm_warn "scan-secrets.sh: not a regular file: $f"; errors=$((errors + 1)); continue; fi
  if [ ! -r "$f" ]; then cm_warn "scan-secrets.sh: cannot read file: $f"; errors=$((errors + 1)); continue; fi
  res="$({ for re in "${RES[@]}"; do grep -aoE -e "$re" -- "$f" 2>/dev/null; [ $? -le 1 ] || echo '@@GREPFAIL'; done; } | awk "$AWK_CLASSIFY"; printf 'rc=%s\n' "${PIPESTATUS[1]}")"
  rc="$(printf '%s\n' "$res" | tail -n 1)"
  if [ "$rc" != "rc=0" ] || printf '%s\n' "$res" | grep -q '^@@fail'; then
    cm_warn "scan-secrets.sh: scan failed for: $f"; errors=$((errors + 1)); continue
  fi
  printf '%s\n' "$res" | sed '$d' | CM_SCAN_F="$f" awk -F'\t' 'NF == 2 { printf "%s\t%s\t%s\n", ENVIRON["CM_SCAN_F"], $1, $2 }' >> "$TMP"
done

hits=0
adv=0
for c in $ALL_CLASSES; do
  t="$(awk -F'\t' -v c="$c" '$2 == c { s += $3; n++ } END { printf "%d %d", s, n }' "$TMP")"
  kind=strict
  case " $STRICT_CLASSES " in *" $c "*) hits=$((hits + ${t% *})) ;; *) kind=advisory; adv=$((adv + ${t% *})) ;; esac
  printf '%s\t%s\t%s\t%s\n' "$c" "${t% *}" "${t#* }" "$kind"
done
awk -F'\t' '{ printf "FILE\t%s\t%s\t%s\n", $1, $2, $3 }' "$TMP"
printf 'SUMMARY files=%d hits=%d advisory=%d errors=%d\n' "${#FILES[@]}" "$hits" "$adv" "$errors"
[ "$hits" -gt 0 ] && exit 1
[ "$STRICT" -eq 1 ] && [ "$adv" -gt 0 ] && exit 1
[ "$errors" -gt 0 ] && exit 2
exit 0
