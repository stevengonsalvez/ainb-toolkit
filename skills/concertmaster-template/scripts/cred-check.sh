#!/usr/bin/env bash
# cred-check.sh: weekly validity check of the fleet credentials listed in the index.
#
#   scripts/cred-check.sh                       # check every entry, write the inbox note
#   scripts/cred-check.sh --index FILE          # use FILE instead of the default index
#   scripts/cred-check.sh --dry-run             # print the table, write no inbox note
#   scripts/cred-check.sh --publish [FILE]      # create/update the Bitwarden secret
#                                               # index secret from FILE (names only)
#
# Run it on the concertmaster host only: that is where the inbox is read (SKILL.md, the tick).
# Index, first found: the Bitwarden secret named by config credentials.index_key, $CM_HOME/credentials-index.json,
# $CM_HOME/credentials-index.seed.json, the seed next to this skill. It lists names, owners and
# checks, never a value. For each entry the value is read from its `source` (bws:<secret key> or
# file:<path>), token-shaped strings are extracted, and ONE read-only API call per candidate decides
# OK, INVALID (401/403 on every candidate), MISSING (secret or file not there) or UNKNOWN (no confident token, no network, other status,
# manual, or `"probe": "skip"`). The token goes to curl on stdin (-K -), never argv, and is never
# printed, logged or written. Providers with no distinctive token prefix (Cloudflare, Vercel) are
# only probed when exactly one standalone token of the exact length is found, otherwise UNKNOWN and
# nothing is sent: a fragment of another secret must never reach the wrong provider.
#
# Output: a table on stdout and ALWAYS an inbox note $CM_HOME/inbox/cred-check-<UTC with seconds>.md
# (also for a FATAL). Exit: 0 all fine, 1 at least one INVALID or MISSING, 3 FATAL (no usable index, no jq, a dead
# Bitwarden token), 2 bad usage. A non-zero exit makes the systemd unit show failed.
# Env: BWS_ACCESS_TOKEN (else ~/.secrets/bws-access-token), CM_HOME, CM_BWS_PROJECT (config
# credentials.bws_project), CM_CRED_INDEX_KEY (config credentials.index_key), CM_CRED_CURL (test hook).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0; INDEX=""; PUBLISH=0; PUBFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --index) INDEX="${2:-}"; shift ;;
    --publish) PUBLISH=1; if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then PUBFILE="$2"; shift; fi ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) cm_warn "cred-check.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

NOTE="$CM_HOME/inbox/cred-check-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
fatal() { # $1 = reason; always leaves an inbox note, exit 3
  cm_warn "cred-check.sh: FATAL: $1"
  if [ "$DRY" = 0 ]; then mkdir -p "$CM_HOME/inbox" 2>/dev/null; printf '# cred-check %s: FATAL\n\n%s\n' "$(date -u +%FT%TZ)" "$1" > "$NOTE" 2>/dev/null; fi
  exit 3
}
command -v jq >/dev/null 2>&1 || fatal "jq is not installed on this host, no credential could be checked"
CURL="${CM_CRED_CURL:-curl}"
[ -n "${BWS_ACCESS_TOKEN:-}" ] || { [ -r "$HOME/.secrets/bws-access-token" ] && BWS_ACCESS_TOKEN="$(cat "$HOME/.secrets/bws-access-token")"; }
export BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-}"
INDEX_KEY="${CM_CRED_INDEX_KEY:-$(cm_cfg .credentials.index_key CONCERTMASTER-CREDENTIALS-INDEX)}"
PROJECT_NAME="${CM_BWS_PROJECT:-$(cm_cfg .credentials.bws_project)}"
SEED="$HERE/../references/credentials-index.seed.json"

# One Bitwarden probe up front: a dead access token is FATAL, not "not found" for every entry.
BWS_OK=0; BWS_LIST="[]"
if command -v bws >/dev/null 2>&1 && [ -n "$BWS_ACCESS_TOKEN" ]; then
  if BWS_LIST="$(cm_timeout 60 bws secret list -o json </dev/null 2>/dev/null)" && printf '%s' "$BWS_LIST" | jq -e 'type=="array"' >/dev/null 2>&1; then BWS_OK=1; else BWS_LIST="[]"; fi
fi
bws_find() { printf '%s' "$BWS_LIST" | jq -r --arg k "$1" '[.[]|select(.key==$k)][0] | select(.) | "\(.id)\t\(.revisionDate[0:10])"'; }
bws_value() { cm_timeout 60 bws secret get "$1" -o json </dev/null 2>/dev/null | jq -r '.value // empty'; }

if [ "$PUBLISH" = 1 ]; then
  f="${PUBFILE:-$SEED}"; [ -r "$f" ] || { cm_warn "cred-check.sh: cannot read $f"; exit 2; }
  jq -e '.entries|type=="array"' "$f" >/dev/null 2>&1 || { cm_warn "cred-check.sh: $f is not an index"; exit 2; }
  # the index holds names only: refuse anything shaped like a key (known prefixes, JWTs, 64 hex, or
  # any unbroken run of 40+ token characters, which also catches unprefixed Cloudflare/Vercel tokens)
  vals="$(jq -r '..|strings' "$f" | grep -vE '^(file|bws):' || true)"
  if grep -Eq '(sbp_|sb_secret_|sk_live_|sk_test_|rk_live_|rk_test_|whsec_|ghp_|gho_|ghs_|ghu_|ghr_|github_pat_|sntrys_|sntryu_|cfut_|cfat_|AKIA[0-9A-Z]{12}|eyJ[A-Za-z0-9_-]{10,}|[A-Fa-f0-9]{64}|[A-Za-z0-9_-]{40,})' <<<"$vals"; then
    cm_warn "cred-check.sh: refusing to publish, $f looks like it holds a secret value"; exit 2
  fi
  [ "$BWS_OK" = 1 ] || { cm_warn "cred-check.sh: Bitwarden is not reachable with this access token, cannot publish"; exit 3; }
  found="$(bws_find "$INDEX_KEY" | cut -f1)"
  pid="$(cm_timeout 60 bws project list -o json </dev/null 2>/dev/null | jq -r --arg n "$PROJECT_NAME" '[.[]|select(.name==$n)][0].id // empty')"
  val="$(jq -c . "$f")"
  if [ -n "$found" ]; then
    if cm_timeout 60 bws secret edit "$found" --value "$val" -o none </dev/null >/dev/null 2>&1; then echo "updated $INDEX_KEY"; else cm_warn "cred-check.sh: update failed"; exit 3; fi
  else
    [ -n "$PROJECT_NAME" ] || { cm_warn "cred-check.sh: set credentials.bws_project in config.yaml (or CM_BWS_PROJECT) to create the index secret"; exit 3; }
    [ -n "$pid" ] || { cm_warn "cred-check.sh: Bitwarden project '$PROJECT_NAME' not found, nothing created"; exit 3; }
    if cm_timeout 60 bws secret create "$INDEX_KEY" "$val" "$pid" -o none </dev/null >/dev/null 2>&1; then echo "created $INDEX_KEY"; else cm_warn "cred-check.sh: create failed"; exit 3; fi
  fi
  exit 0
fi

# ---- load the index -------------------------------------------------------------
idx=""
if [ -n "$INDEX" ]; then idx="$(cat "$INDEX" 2>/dev/null)"
else
  if [ "$BWS_OK" = 1 ]; then r="$(bws_find "$INDEX_KEY")"; [ -n "$r" ] && idx="$(bws_value "$(cut -f1 <<<"$r")")"; fi
  [ -n "$idx" ] || idx="$(cat "$CM_HOME/credentials-index.json" 2>/dev/null)"
  [ -n "$idx" ] || idx="$(cat "$CM_HOME/credentials-index.seed.json" 2>/dev/null)"
  [ -n "$idx" ] || idx="$(cat "$SEED" 2>/dev/null)"
fi
jq -e '.entries|type=="array"' <<<"$idx" >/dev/null 2>&1 || fatal "no usable credentials index (looked in Bitwarden $INDEX_KEY, $CM_HOME/credentials-index.json and .seed.json, and the skill seed)"
if grep -q '"source": *"bws:' <<<"$idx" && [ "$BWS_OK" = 0 ] && [ -z "$INDEX" ]; then
  fatal "Bitwarden did not answer with this access token (dead, expired, or bws missing): every bws: credential is unchecked"
fi

# ---- per-kind: token pattern, URL, auth scheme (@@-separated; regexes may contain |) --------
# fields: regex @@ url @@ scheme @@ mode   mode=prefixed (try all candidates) | exact (send only a lone standalone match)
spec() {
  case "$1" in
    supabase-pat) echo 'sbp_[A-Za-z0-9]{20,}@@https://api.supabase.com/v1/projects?limit=1@@Bearer@@prefixed' ;;
    github)       echo '(github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,})@@https://api.github.com/rate_limit@@Bearer@@prefixed' ;;
    sentry)       echo '(sntry[us]_[A-Za-z0-9+/=_-]{20,}|[a-f0-9]{64})@@https://sentry.io/api/0/organizations/?per_page=1@@Bearer@@prefixed' ;;
    stripe-test)  echo 'sk_test_[A-Za-z0-9]{20,}@@https://api.stripe.com/v1/balance@@Bearer@@prefixed' ;;
    cloudflare)   echo '[A-Za-z0-9_-]{40}@@https://api.cloudflare.com/client/v4/user/tokens/verify@@Bearer@@exact' ;;
    vercel)       echo '[A-Za-z0-9]{24}@@https://api.vercel.com/v2/user@@Bearer@@exact' ;;
    *) echo "" ;;
  esac
}
# Prefixes of OTHER providers' secrets: a candidate carrying one is never sent to an unprefixed provider.
FOREIGN_RE='(sbp_|sb_secret_|sb_publishable_|sk_live_|sk_test_|rk_live_|rk_test_|whsec_|ghp_|gho_|ghs_|ghu_|ghr_|github_pat_|sntrys_|sntryu_|eyJ|AKIA)'

rows=""
n_ok=0; n_bad=0; n_unk=0; n_miss=0
US=$'\x1f'
while IFS="$US" read -r name source kind owner probe; do
  status=UNKNOWN; why=""; rev=-
  sp="$(spec "$kind")"
  [ "$probe" = skip ] && sp=""
  src_kind="${source%%:*}"; src_ref="${source#*:}"
  raw=""
  case "$src_kind" in
    bws) if [ "$BWS_OK" = 1 ]; then
           if r="$(bws_find "$src_ref")" && [ -n "$r" ]; then rev="$(cut -f2 <<<"$r")"; [ -n "$sp" ] && raw="$(bws_value "$(cut -f1 <<<"$r")")"
           else status=MISSING; why="not found in Bitwarden: renamed or deleted?"; fi
         else why="Bitwarden not reachable"; fi ;;
    file) p="${src_ref/#\~/$HOME}"; if [ -r "$p" ]; then rev="$(date -u -r "$p" +%F 2>/dev/null || echo -)"; [ -n "$sp" ] && raw="$(cat "$p")"; else status=MISSING; why="file missing"; fi ;;
    *) why="unknown source" ;;
  esac
  if [ "$status" = MISSING ]; then :
  elif [ -z "$sp" ]; then
    [ "$probe" = skip ] && why="probe not applicable for this credential" || why="${why:-manual check, no safe read-only probe}"
  elif [ -n "$raw" ]; then
    re="${sp%%@@*}"; rest="${sp#*@@}"; url="${rest%%@@*}"; rest="${rest#*@@}"; scheme="${rest%%@@*}"; mode="${rest##*@@}"
    # Split the value into WHOLE runs of token characters first (a separator is never consumed), keep the
    # runs that match this provider's pattern exactly, then drop any run carrying ANOTHER provider's prefix.
    runs="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_-' '\n' | grep -xE "$re" | awk '!seen[$0]++')"
    case "$kind" in
      cloudflare|vercel) fr="$FOREIGN_RE" ;;
      sentry) fr="$(printf '%s' "$FOREIGN_RE" | sed -E 's/sntrys_\|sntryu_\|//')" ;;
      *) fr="" ;;   # prefixed kinds: the provider's own prefix in the pattern already limits what can match
    esac
    if [ -n "$fr" ]; then cands="$(printf '%s\n' "$runs" | grep -vE "$fr" | grep . || true)"; else cands="$(printf '%s\n' "$runs" | grep . || true)"; fi
    # unprefixed kinds (cloudflare, vercel) and the bare-hex sentry fallback are only sent when exactly ONE
    # candidate is left; a second look-alike run means we cannot tell which is the token
    if [ "$mode" = exact ] || [ "$kind" = sentry ]; then
      [ "$(printf '%s\n' "$cands" | grep -c .)" -eq 1 ] || cands=""
    else
      cands="$(printf '%s\n' "$cands" | head -5)"
    fi
    if [ -z "$cands" ]; then why="no confident token in the stored value, nothing sent"
    else
      tried=0; refused=0
      while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        tried=$((tried + 1))
        code="$(printf 'header = "Authorization: %s %s"\nurl = "%s"\nsilent\noutput = "/dev/null"\nwrite-out = "%%{http_code}"\nmax-time = 20\n' "$scheme" "$tok" "$url" | "$CURL" -K - 2>/dev/null || true)"
        case "$code" in
          200) status=OK; break ;;
          401|403) refused=$((refused + 1)); why="HTTP $code" ;;
          *) why="HTTP ${code:-none}" ;;
        esac
      done <<<"$cands"
      if [ "$status" != OK ] && [ "$refused" -gt 0 ] && [ "$refused" -eq "$tried" ]; then status=INVALID; why="${why}, all $tried candidate(s) refused (an account-owned or team-scoped token can be refused by this probe: set \"probe\":\"skip\" in the index if so)"; fi
      [ "$status" = OK ] && why=""
    fi
    tok=""
  elif [ -z "$why" ]; then status=MISSING; why="empty value"; fi
  raw=""
  case "$status" in OK) n_ok=$((n_ok+1)) ;; INVALID) n_bad=$((n_bad+1)) ;; MISSING) n_miss=$((n_miss+1)) ;; *) n_unk=$((n_unk+1)) ;; esac
  rows="$rows$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$name" "$kind" "$owner" "$status" "$rev" "$why")"$'\n'
done < <(jq -r --arg us "$US" '.entries[] | [(.name // "?"), (.source // "none:none"), (.kind // "manual"), (.owner // "-"), (.probe // "")] | join($us)' <<<"$idx")

printf '%s' "$rows" | awk -F'\t' 'BEGIN{printf "%-32s %-13s %-9s %-8s %-11s %s\n","credential","kind","owner","status","updated","note"} {printf "%-32s %-13s %-9s %-8s %-11s %s\n",$1,$2,$3,$4,$5,$6}'
echo "credentials: $n_ok ok, $n_bad invalid, $n_miss missing, $n_unk unknown or manual"
if [ "$DRY" = 0 ]; then
  mkdir -p "$CM_HOME/inbox" 2>/dev/null
  {
    printf '# cred-check %s: %s ok, %s INVALID, %s MISSING, %s unknown or manual\n\n' "$(date -u +%FT%TZ)" "$n_ok" "$n_bad" "$n_miss" "$n_unk"
    printf 'credential | kind | owner | status | updated | note\n--- | --- | --- | --- | --- | ---\n'
    printf '%s' "$rows" | awk -F'\t' '{printf "%s | %s | %s | %s | %s | %s\n",$1,$2,$3,$4,$5,$6}'
    [ "$n_miss" -gt 0 ] && printf '\nMISSING means the secret or file in the index is not there any more (renamed, deleted, wrong source): fix the index or restore it, nothing was checked.\n'
    [ "$n_bad" -gt 0 ] && printf '\nINVALID means the provider refused the token: rotate it (see the index `rotate` field) and update the Bitwarden secret.\n'
  } > "$NOTE" 2>/dev/null
fi
[ "$n_bad" -gt 0 ] || [ "$n_miss" -gt 0 ] && exit 1
exit 0
