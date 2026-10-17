#!/usr/bin/env bash
# cred-check.sh test: stubbed bws and curl, a synthetic index. Asserts OK / INVALID / UNKNOWN per
# case, that the CALLS curl receives never include a fragment of another provider's secret, that no
# token appears in stdout or the inbox note (with a negative control proving the check can fail),
# FATAL on a dead Bitwarden token and on no index (both leave an inbox note and exit 3), exit 1 on an
# INVALID credential, probe:skip, the seed fallback after install, and the publish guard.
#
#   scripts/test/cred-check.sh         # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cred-check.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-cred-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_CONFIG=/nonexistent CM_BWS_PROJECT=fleet CM_HOME="$ROOT/home" HOME="$ROOT/home" STUB_DIR="$ROOT/stub"; mkdir -p "$ROOT/bin" "$CM_HOME/.secrets" "$STUB_DIR"
rep() { local c="$1" n="$2"; printf "%${n}s" '' | tr ' ' "$c"; }
CF2="$(rep d 40)"; HX1="$(rep a 64)"; HX2="$(rep b 64)"; SB="sbp_$(rep A 30)"; CF="$(rep c 40)"; ST="sk_test_$(rep S 30)"; GH="ghp_$(rep G 36)"; VC="$(rep v 24)"
printf '%s' "$ST" > "$CM_HOME/.secrets/stripe"
cat > "$ROOT/bin/bws" <<S
#!/usr/bin/env bash
[ "\$BWS_ACCESS_TOKEN" = test ] || exit 1
case "\$1 \$2" in
  "secret list") echo '[{"id":"id-sb","key":"sb-key","revisionDate":"2026-10-13T00:00:00Z"},{"id":"id-cf","key":"cf-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-gh","key":"gh-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-gh2","key":"gh2-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-vc","key":"vc-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-mix","key":"mix-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-skip","key":"skip-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-two","key":"two-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-two2","key":"two2-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-hex1","key":"hex1-key","revisionDate":"2026-09-12T00:00:00Z"},{"id":"id-hex2","key":"hex2-key","revisionDate":"2026-09-12T00:00:00Z"}]' ;;
  "secret get") case "\$3" in
      id-sb) echo '{"value":"\nnotes:\nexport supabase_access_token=$SB"}' ;;
      id-cf) echo '{"value":"$CF"}' ;;
      id-gh) echo '{"value":"nothing useful here"}' ;;
      id-gh2) echo '{"value":"export GITHUB_TOKEN=$GH"}' ;;
      id-vc) echo '{"value":"VERCEL_TOKEN=$VC"}' ;;
      id-mix) echo '{"value":"a $GH b $SB c"}' ;;
      id-skip) echo '{"value":"$CF"}' ;;
      id-two) echo '{"value":"$CF $CF2"}' ;;
      id-two2) echo '{"value":"$CF,$CF2"}' ;;
      id-hex1) echo '{"value":"SENTRY=$HX1"}' ;;
      id-hex2) echo '{"value":"SENTRY=$HX1 R2=$HX2"}' ;;
    esac ;;
  "project list") echo '[{"id":"proj-0","name":"other"},{"id":"proj-1","name":"fleet"}]' ;;
  "secret create") echo "create \$*" >> "$STUB_DIR/bws-writes.log" ;;
  "secret edit") echo "edit \$*" >> "$STUB_DIR/bws-writes.log" ;;
esac
S
cat > "$ROOT/bin/curl" <<S
#!/usr/bin/env bash
cfg="\$(cat)"
printf '%s\n' "\$(printf '%s' "\$cfg" | tr '\n' ' ')" >> "$STUB_DIR/curl-configs.log"
case "\$cfg" in
  *$SB*) printf 200 ;;
  *$GH*) printf 200 ;;
  *$CF*) printf 403 ;;
  *$VC*|*$HX1*) printf 200 ;;
  *$ST*) printf 000 ;;
esac
S
chmod +x "$ROOT/bin/bws" "$ROOT/bin/curl"; export PATH="$ROOT/bin:$PATH" BWS_ACCESS_TOKEN=test
cat > "$ROOT/index.json" <<EOF2
{"schema":1,"entries":[
 {"name":"Supabase PAT","source":"bws:sb-key","kind":"supabase-pat","owner":"alex"},
 {"name":"Cloudflare","source":"bws:cf-key","kind":"cloudflare","owner":"alex"},
 {"name":"Cloudflare skipped","source":"bws:skip-key","kind":"cloudflare","owner":"alex","probe":"skip"},
 {"name":"Vercel","source":"bws:vc-key","kind":"vercel","owner":"alex"},
 {"name":"GitHub empty","source":"bws:gh-key","kind":"github","owner":"alex"},
 {"name":"GitHub real","source":"bws:gh2-key","kind":"github","owner":"alex"},
 {"name":"Mixed value as Vercel","source":"bws:mix-key","kind":"vercel","owner":"alex"},
 {"name":"Two cf tokens space","source":"bws:two-key","kind":"cloudflare","owner":"alex"},
 {"name":"Two cf tokens comma","source":"bws:two2-key","kind":"cloudflare","owner":"alex"},
 {"name":"Sentry one hex","source":"bws:hex1-key","kind":"sentry","owner":"alex"},
 {"name":"Sentry two hex","source":"bws:hex2-key","kind":"sentry","owner":"alex"},
 {"name":"Stripe test","source":"file:$CM_HOME/.secrets/stripe","kind":"stripe-test","owner":"alex"},
 {"name":"Transcrypt","source":"file:$CM_HOME/.secrets/stripe","kind":"manual","owner":"alex"},
 {"name":"Gone file","source":"file:/nonexistent","kind":"manual","owner":"alex"},
 {"name":"Missing","source":"bws:not-there","kind":"github","owner":"alex"}
]}
EOF2
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
leaks() { # prints yes when any token appears in the text given on stdin
  local t txt; txt="$(cat)"; for t in "$SB" "$CF" "$ST" "$GH" "$VC" "$CF2" "$HX1" "$HX2"; do printf '%s' "$txt" | grep -qF -- "$t" && { echo yes; return; }; done; echo no; }
check "leak check has a working negative control" "$(printf 'x %s y' "$SB" | leaks)" "yes"

OUT="$("$SCRIPT" --index "$ROOT/index.json")"; RC=$?
st() { printf '%s\n' "$OUT" | awk -v n="$1" '{ if (index($0, n " ") == 1) { for (i = 1; i <= NF; i++) if ($i=="OK"||$i=="INVALID"||$i=="UNKNOWN"||$i=="MISSING") { print $i; exit } } }'; }
check "supabase token is OK" "$(st 'Supabase PAT')" "OK"
check "github token (regex with alternation) is OK" "$(st 'GitHub real')" "OK"
check "two adjacent look-alike tokens (space) send nothing" "$(st 'Two cf tokens space')" "UNKNOWN"
check "two adjacent look-alike tokens (comma) send nothing" "$(st 'Two cf tokens comma')" "UNKNOWN"
check "a lone bare-hex sentry token is probed" "$(st 'Sentry one hex')" "OK"
check "two bare-hex runs send nothing (could be an R2 key)" "$(st 'Sentry two hex')" "UNKNOWN"
check "refused standalone cloudflare token is INVALID" "$(st 'Cloudflare')" "INVALID"
check "probe skip is UNKNOWN and sends nothing" "$(st 'Cloudflare skipped')" "UNKNOWN"
check "lone 24-char vercel token is OK" "$(st 'Vercel')" "OK"
check "github entry without a token is UNKNOWN" "$(st 'GitHub empty')" "UNKNOWN"
check "network failure is UNKNOWN" "$(st 'Stripe test')" "UNKNOWN"
check "manual entry is UNKNOWN" "$(st 'Transcrypt')" "UNKNOWN"
check "a missing file is MISSING even for a manual entry" "$(st 'Gone file')" "MISSING"
check "missing secret is MISSING" "$(st 'Missing')" "MISSING"
check "a Vercel entry holding other providers' keys is UNKNOWN" "$(st 'Mixed value as Vercel')" "UNKNOWN"
check "exit 1 when a credential is INVALID or MISSING" "$RC" "1"
# one curl record per call (single line): did any call send another provider's token to vercel/cloudflare?
foreign_sent() { grep -E 'api\.(vercel|cloudflare)\.com' "$1" | grep -cE "$GH|$SB|$CF2" || true; }
printf 'url = "https://api.vercel.com/v2/user" header = "Authorization: Bearer %s"\n' "$GH" > "$ROOT/control.log"
check "negative control: the foreign-secret check can fail" "$(foreign_sent "$ROOT/control.log")" "1"
check "curl was called once per probed credential, one record each" "$(grep -c . "$STUB_DIR/curl-configs.log" | tr -d ' ')" "$(grep -c 'url = ' "$STUB_DIR/curl-configs.log" | tr -d ' ')"
check "no foreign secret was ever sent to vercel or cloudflare" "$(foreign_sent "$STUB_DIR/curl-configs.log")" "0"
check "no token in stdout" "$(printf '%s' "$OUT" | leaks)" "no"
note="$(find "$CM_HOME/inbox" -name 'cred-check-*.md' | head -1)"
check "inbox note written" "$([ -n "$note" ] && echo yes)" "yes"
check "no token in the inbox note" "$(cat "$note" | leaks)" "no"

# dead Bitwarden token: FATAL, a note, exit 3
rm -rf "${CM_HOME:?}/inbox"
BWS_ACCESS_TOKEN=dead "$SCRIPT" >/dev/null 2>&1; rc=$?
check "dead bitwarden token exits 3 (FATAL)" "$rc" "3"
check "FATAL leaves an inbox note" "$(grep -l FATAL "$CM_HOME"/inbox/cred-check-*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
# no usable index at all: FATAL
rm -rf "${CM_HOME:?}/inbox"
"$SCRIPT" --index "$ROOT/nope.json" >/dev/null 2>&1; check "no usable index exits 3" "$?" "3"
# seed fallback after install: no index file given, no bws secret, seed copied into CM_HOME
cp "$ROOT/index.json" "$CM_HOME/credentials-index.seed.json"
SEEDOUT="$(BWS_ACCESS_TOKEN=test "$SCRIPT" --dry-run)"
check "seed in CM_HOME is used after install" "$(printf '%s\n' "$SEEDOUT" | grep -c 'Supabase PAT')" "1"
# publish guard
printf '{"entries":[{"name":"x","source":"bws:k","note":"%s"}]}' "$SB" > "$ROOT/bad1.json"
printf '{"entries":[{"name":"x","source":"bws:k","note":"%s"}]}' "$CF" > "$ROOT/bad2.json"
"$SCRIPT" --publish "$ROOT/bad1.json" >/dev/null 2>&1; check "publish refuses a prefixed token" "$?" "2"
"$SCRIPT" --publish "$ROOT/bad2.json" >/dev/null 2>&1; check "publish refuses a bare 40-char token" "$?" "2"
check "publish accepts a clean index and picks the project by name" "$("$SCRIPT" --publish "$ROOT/index.json" 2>/dev/null | cut -d' ' -f1; grep -c 'proj-1' "$STUB_DIR/bws-writes.log")" "$(printf 'created\n1')"
exit $fail
