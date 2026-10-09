#!/usr/bin/env bash
# Offline check of both providers with fake curl and inboxapi binaries.
# Usage: test-providers.sh   (exit 0 = all pass)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fake agents-inbox: one message, epoch-ms timestamp, HTML-only body.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_CURL_FAIL:-}" ] && exit 7
cat <<'JSON'
[{"_id":"m1","fromAddress":"noreply@example.test","fromName":"Example","subject":"Your code","textBody":"","htmlBody":"<style>p{color:#333333}</style><p>Code <b>654321</b></p><a href=\"https://example.test/v?a=1&amp;b=2\">go</a>","receivedAt":1791549511299,"seen":false}]
JSON
EOF

# Fake InboxAPI: datamarked bodies (spaces replaced by "~~") and one stale mail.
cat > "$TMP/bin/inboxapi" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  login) exit 0 ;;
  whoami) echo "Email: test-agent@inboxapi.test" ;;
  get-emails) cat <<'JSON'
{"spotlight":{"marker":"~~"},"emails":[
 {"message_id":"new","from":"\"<firebase@example.test>\" <evil@attacker.test>","subject":"Verify~~email","body":"Your~~code~~is~~123456~~https://example.test/link","direction":"inbound","date":"2099-01-01T00:00:00+00:00"},
 {"message_id":"old","from":"firebase@example.test","subject":"Old","body":"code~~999999","direction":"inbound","date":"2000-01-01T00:00:00+00:00"}]}
JSON
  ;;
esac
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:$PATH" AGENTMAIL_STATE_DIR="$TMP/state"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

addr=$("$HERE/create.sh" ai --purpose test)
check "agents-inbox address" "${addr#*@}" "agents-inbox.com"
check "create is idempotent" "$("$HERE/create.sh" ai)" "$addr"
check "wait matches" "$("$HERE/wait.sh" ai --timeout 5 --from example | jq -r .id)" "m1"
check "otp from html" "$("$HERE/read.sh" ai --extract verification)" "654321"
check "link decoded" "$("$HERE/read.sh" ai --extract magic-link)" "https://example.test/v?a=1&b=2"

check "fallback address" "$(FAKE_CURL_FAIL=1 "$HERE/create.sh" fb 2>/dev/null)" "test-agent@inboxapi.test"
check "fallback provider" "$(jq -r .provider "$TMP/state/inboxes/fb.json")" "inboxapi"
check "datamark kept in raw" "$("$HERE/read.sh" fb | jq -r .subject)" "Verify~~email"
check "subject match unmarks" "$("$HERE/wait.sh" fb --timeout 5 --subject "verify email" | jq -r .id)" "new"
check "stale mail hidden" "$("$HERE/read.sh" fb --index 1 2>/dev/null || echo none)" "none"
check "inboxapi otp" "$("$HERE/read.sh" fb --extract verification)" "123456"
check "inboxapi link" "$("$HERE/read.sh" fb --extract magic-link)" "https://example.test/link"
check "spoofed name loses" "$("$HERE/read.sh" fb | jq -r .from)" "evil@attacker.test"
echo '{"slug":"old","address":"x@retired.test"}' > "$TMP/state/inboxes/old.json"
check "legacy state blocked" "$("$HERE/read.sh" old 2>&1 >/dev/null | grep -c retired)" "1"
check "legacy state re-minted" "$("$HERE/create.sh" old | sed 's/.*@//')" "agents-inbox.com"
check "state gitignored" "$(cat "$TMP/state/.gitignore")" "*"
check "list count" "$("$HERE/list.sh" --json | jq length)" "3"
"$HERE/expire.sh" fb >/dev/null
check "expire" "$("$HERE/address.sh" fb 2>/dev/null || echo gone)" "gone"
check "expire idempotent" "$("$HERE/expire.sh" fb >/dev/null; echo $?)" "0"
set +e; FAKE_CURL_FAIL=1 "$HERE/wait.sh" ai --timeout 1 --interval 1 2>/dev/null; rc=$?; set -e
check "timeout exit" "$rc" "124"

exit "$fail"
