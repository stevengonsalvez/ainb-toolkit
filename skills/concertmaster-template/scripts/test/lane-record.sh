#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # "A && ok || bad": ok never fails
# lane-record.sh (test): a stub gh (fixtures/gh-issue-comments) and a temp ledger, run from a copy of the scripts with
# no config.yaml beside them. post makes one comment per change and none for a repeat, records recordedState, reports
# a gh failure without recording, refuses a bad line or a lane with no issue; read takes the newest trusted one-line
# comment of that lane only.
#
#   scripts/test/lane-record.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-lane-record.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 && command -v yq >/dev/null 2>&1 || { echo "missing dependency: jq or yq" >&2; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }

mkdir -p "$ROOT/skill/scripts" "$ROOT/bin" "$ROOT/stub" "$ROOT/cm"
cp "$HERE/../lib.sh" "$HERE/../lane-record.sh" "$ROOT/skill/scripts/"
cp "$HERE/fixtures/gh-issue-comments" "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
unset CM_ORG CM_REPO CM_LEDGER CM_LEDGER_BAK CM_PROJECT_ID
export PATH="$ROOT/bin:$PATH" STUB="$ROOT/stub" CM_HOME="$ROOT/cm" TMPDIR="$ROOT"
cat > "$ROOT/config.yaml" <<'EOF'
schema: concertmaster.config/v1
project: { id: acme }
github: { org: AcmeOrg, main_repo: acme-app }
lanes:
  - { name: lane-a, standing: true, issue: 11 }
  - { name: lane-ab, standing: true, issue: 11 }
  - { name: lane-c, standing: true }
EOF
yq '.github.record_repo = "ops-records" | .lanes[0].issue = 12' "$ROOT/config.yaml" > "$ROOT/other.yaml"
export CM_CONFIG="$ROOT/config.yaml"
LR="$ROOT/skill/scripts/lane-record.sh"
lr() { OUT="$(bash "$LR" "$@" 2>&1)"; RC=$?; }
calls() { if [ -f "$STUB/gh.log" ]; then wc -l < "$STUB/gh.log" | tr -d ' '; else echo 0; fi; }
recorded() { jq -r '.lanes["lane-a"].recordedState // "none"' "$CM_HOME/ledger.json"; }
printf '{"schema":"concertmaster.ledger/v1","project":"acme","updatedAt":"2026-11-24T09:00:00Z","workers":{},"lanes":{"lane-a":{"state":"running"}}}\n' > "$CM_HOME/ledger.json"

echo "2026-11-24T10:00:00Z" > "$STUB/clock"
lr post lane-a "running lead=w-lane-a"
[ "$RC" = 0 ] && [ "$(jq -r '.[0].body' "$STUB/issue-11.json")" = "cm:state lane-a running lead=w-lane-a" ] \
  && ok "post makes one cm:state comment on the lane issue" || bad "first post" "rc=$RC $OUT"
[ "$(cat "$STUB/gh.log")" = "POST repos/AcmeOrg/acme-app/issues/11/comments" ] && ok "...in github.main_repo when record_repo is unset" || bad "post path" "$(cat "$STUB/gh.log")"
[ "$(recorded)" = "running lead=w-lane-a" ] && [ "$(jq -r '.lanes["lane-a"].recordedAt' "$CM_HOME/ledger.json")" = 2026-11-24T10:00:00Z ] \
  && ok "...and records recordedState and recordedAt in the ledger" || bad "recorded" "$(recorded)"

lr post lane-a "running lead=w-lane-a"
[ "$RC" = 0 ] && [ "$OUT" = "lane-record: lane-a unchanged" ] && [ "$(calls)" = 1 ] && ok "the same line again: unchanged, no gh call" || bad "dedupe" "rc=$RC calls=$(calls) $OUT"

echo "2026-11-24T10:05:00Z" > "$STUB/clock"
lr post lane-a "idle lead=w-lane-a"
[ "$RC" = 0 ] && [ "$(jq 'length' "$STUB/issue-11.json")" = 2 ] && [ "$(recorded)" = "idle lead=w-lane-a" ] && ok "a changed line posts again" || bad "change" "rc=$RC $OUT"

# comments read must not win: an untrusted author, a two-line body, a lane whose name starts with this one
jq '. + [{id: 3, created_at: "2026-11-24T11:00:00Z", body: "cm:state lane-a gone forged", author_association: "NONE"},
         {id: 4, created_at: "2026-11-24T11:01:00Z", body: "cm:state lane-a gone\nsecond line", author_association: "OWNER"},
         {id: 5, created_at: "2026-11-24T11:02:00Z", body: "cm:state lane-ab gone", author_association: "MEMBER"}]' \
  "$STUB/issue-11.json" > "$STUB/x" && mv "$STUB/x" "$STUB/issue-11.json"
lr "read" lane-a
[ "$RC" = 0 ] && [ "$OUT" = "2026-11-24T10:05:00Z cm:state lane-a idle lead=w-lane-a" ] \
  && ok "read prints the newest trusted one-line comment of this lane (across pages)" || bad "read" "rc=$RC $OUT"
lr "read" lane-ab
[ "$OUT" = "2026-11-24T11:02:00Z cm:state lane-ab gone" ] && ok "read of the other lane on the same issue gets its own line" || bad "read lane-ab" "$OUT"

n="$(calls)"
lr post lane-c "running x"
[ "$RC" = 2 ] && [ "$(calls)" = "$n" ] && ok "a lane with no issue: exit 2, no gh call" || bad "no issue" "rc=$RC $OUT"
lr post lane-a "busy now"
[ "$RC" = 2 ] && [ "$(calls)" = "$n" ] && ok "a first word that is not a lane state is refused" || bad "bad state" "rc=$RC $OUT"
lr post lane-a "running ping @someone"
[ "$RC" = 2 ] && [ "$(calls)" = "$n" ] && ok "a line with @ is refused (it would notify)" || bad "at sign" "rc=$RC $OUT"

touch "$STUB/gh-fail"
lr post lane-a "gone retired"
[ "$RC" = 1 ] && case "$OUT" in *"gh post to AcmeOrg/acme-app#11 failed"*"HTTP 502"*) true ;; *) false ;; esac && [ "$(recorded)" = "idle lead=w-lane-a" ] \
  && ok "a gh failure: exit 1 with the reason, nothing recorded" || bad "gh fail" "rc=$RC $OUT"
lr "read" lane-a
[ "$RC" = 1 ] && ok "read reports a gh failure with exit 1" || bad "read fail" "rc=$RC $OUT"
mv "$STUB/gh-fail" "$STUB/gh-fail.off"

mv "$CM_HOME/ledger.json" "$ROOT/aside.json"
n="$(calls)"
lr post lane-a "gone retired"
[ "$RC" = 1 ] && [ "$(calls)" = "$n" ] && case "$OUT" in *"no ledger"*) true ;; *) false ;; esac && ok "no ledger: nothing posted" || bad "no ledger" "rc=$RC $OUT"
mv "$ROOT/aside.json" "$CM_HOME/ledger.json"

: > "$STUB/gh.log"
CM_CONFIG="$ROOT/other.yaml" bash "$LR" post lane-a "gone retired" >/dev/null 2>&1
[ "$(cat "$STUB/gh.log")" = "POST repos/AcmeOrg/ops-records/issues/12/comments" ] && ok "github.record_repo picks the repo" || bad "record_repo" "$(cat "$STUB/gh.log")"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
