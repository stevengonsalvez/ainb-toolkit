#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# census-supabase.sh (test): the census flags running local Supabase stacks that no live worktree names.
# docker and ssh are PATH stubs (no real container or host is read). The scan (cm_sb_collect, lib.sh) runs
# against fixture worktree dirs, its output goes through classify.sh --census / --table and digest.sh --full.
# Synthetic names only. Touches only a mktemp dir.
#
#   scripts/test/census-supabase.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-censussb.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
export CM_HOME="$ROOT/home"
mkdir -p "$CM_HOME" "$ROOT/bin" "$ROOT/sb"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE
printf '{"workers": {}}\n' > "$CM_HOME/ledger.json"

# fixture worktrees: each with its own project_id; one with a quoted-looking name to prove the ssh quoting holds
mkwt() { mkdir -p "$ROOT/wt/$1/supabase"; printf 'project_id = "%s"\n' "$2" > "$ROOT/wt/$1/supabase/config.toml"; printf '%s' "$ROOT/wt/$1"; }
W1="$(mkwt wt-live live-1)"; W2="$(mkwt wt-other "it's other")"; W3="$(mkwt wt-mount mount-holder)"
mkdir -p "$ROOT/wt/wt-none"; W4="$ROOT/wt/wt-none"   # a live worktree with no supabase/config.toml

# docker stub: containers "<cid> <project id>" and mounts "<cid> <source>" come from $ROOT/sb; STUB_DOCKER_DOWN=1: no answer
cat > "$ROOT/bin/docker" <<'D'
#!/usr/bin/env bash
case "$1" in
  ps) [ "${STUB_DOCKER_DOWN:-0}" = 1 ] && exit 1; cat "$STUB_SB_DIR/containers" 2>/dev/null; exit 0 ;;
  inspect) shift; [ "${1:-}" != -f ] || shift 2; for cid in "$@"; do awk -v c="$cid" '$1 == c { print $1, $2 }' "$STUB_SB_DIR/mounts" 2>/dev/null; done; exit 0 ;;
esac
exit 0
D
# ssh stub: runs the remote command locally (stdin carries the script); STUB_SSH_FAIL=1 exits 255 like an unreachable host
cat > "$ROOT/bin/ssh" <<'S'
#!/usr/bin/env bash
[ "${STUB_SSH_FAIL:-0}" = 1 ] && exit 255
printf '%s\n' "$*" >> "${STUB_SSH_LOG:-/dev/null}"
cmd="${*: -1}"
eval "$cmd"
S
chmod +x "$ROOT/bin/docker" "$ROOT/bin/ssh"
# a PATH with the plain tools but no docker
mkdir -p "$ROOT/binmin"
for t in sh bash env sed head jq cat timeout awk tr printf grep perl; do p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$ROOT/binmin/$t"; done
export STUB_SB_DIR="$ROOT/sb" PATH="$ROOT/bin:$PATH"
printf '%s\n' "c1 live-1" "c2 live-1" "c3 ghost-9" "c4 ghost-9" "c5 ghost-9" "c6 held-5" "c7 stray-6" \
  "c8 it's other" "c9 mount-holder" > "$STUB_SB_DIR/containers"
# held-5 has a mount inside wt-mount (not an orphan); stray-6's mount is in wt-mount-bar, a different dir (still an orphan)
printf '%s\n' "c6 $W3/supabase" "c7 ${W3}-bar/supabase" > "$STUB_SB_DIR/mounts"

# shellcheck source=SCRIPTDIR/../lib.sh
. "$HERE/../lib.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1: missing '$3' in: $2"; fi; }
hasnot() { if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1: unexpected '$3' in: $2"; else ok "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
# doc <hosts-json> <supabaseScope hosts json | null>: a minimal discover document
doc() { jq -cn --argjson h "$1" --argjson s "$2" '{generatedAtMs: 1791600000000, generatedAt: "t", hosts: $h, worktrees: [],
  gitScope: {hosts: []}} + (if $s == null then {} else {supabaseScope: {hosts: $s}} end)'; }
census() { "$HERE/../classify.sh" --census 2>/dev/null; }
LOCAL='[{"name":"local","kind":"local","reachable":true}]'

echo "== local scan -> census"
E1="$(cm_sb_collect local local "" false "$W1" "$W2" "$W3" "$W4")"
eq "scan ok, docker ok" "$(jq -r '"\(.ok) \(.docker)"' <<<"$E1")" "true ok"
eq "worktree project ids read (a quote in an id survives)" "$(jq -r '[.worktrees[] | .projectId] | join("|")' <<<"$E1")" "live-1|it's other|mount-holder|"
OUT="$(doc "$LOCAL" "[$E1]" | census)"
has "census line counts the orphans"        "$OUT" "supabase-stacks: orphans 2 (target 0)"
has "ghost stack named with its host"       "$OUT" "  supabase-stack: ghost-9 @ local: 3 containers, no live Orca worktree config or mount names it"
has "a stack whose mount is in <wt>-bar is an orphan (path boundary)" "$OUT" "  supabase-stack: stray-6 @ local"
hasnot "held-5 is not an orphan: no config names it but a mount does" "$OUT" "held-5"
hasnot "a stack matching a live worktree config is not flagged"       "$OUT" "live-1"
hasnot "a stack matching a config with a quote in its id is not flagged" "$OUT" "it's other"
hasnot "a complete check carries no INCOMPLETE suffix"                "$OUT" "CHECK INCOMPLETE"
has "the first line is still the worktree census line" "$(printf '%s\n' "$OUT" | head -1)" "census: orphans"

echo "== zero orphans prints zero"
printf '%s\n' "c1 live-1" > "$STUB_SB_DIR/containers"; : > "$STUB_SB_DIR/mounts"
E0="$(cm_sb_collect local local "" false "$W1")"
OUT0="$(doc "$LOCAL" "[$E0]" | census)"
has "no stack without a worktree: zero, complete" "$OUT0" "supabase-stacks: orphans 0 (target 0)"
hasnot "no row follows" "$OUT0" "supabase-stack:"
hasnot "and no INCOMPLETE" "$OUT0" "CHECK INCOMPLETE"
printf '%s\n' "c1 live-1" "c3 ghost-9" "c4 ghost-9" "c5 ghost-9" "c6 held-5" "c7 stray-6" > "$STUB_SB_DIR/containers"
printf '%s\n' "c6 $W3/supabase" "c7 ${W3}-bar/supabase" > "$STUB_SB_DIR/mounts"

echo "== docker unreadable is INCOMPLETE, never a false clean"
ED="$(STUB_DOCKER_DOWN=1 cm_sb_collect local local "" false "$W1")"
eq "docker down: scan finished, docker unreachable" "$(jq -r '"\(.ok) \(.docker)"' <<<"$ED")" "true unreachable"
OUTD="$(doc "$LOCAL" "[$ED]" | census)"
has "docker down: orphans 0 with CHECK INCOMPLETE and the reason" "$OUTD" "supabase-stacks: orphans 0 (target 0) (CHECK INCOMPLETE: local: docker did not answer, stacks not checked)"
EN="$(PATH="$ROOT/binmin" cm_sb_collect local local "" false "$W1")"
eq "no docker at all: nodocker" "$(jq -r .docker <<<"$EN")" "nodocker"
has "no docker: INCOMPLETE says it is not installed" "$(doc "$LOCAL" "[$EN]" | census)" "local: docker is not installed, stacks not checked"

echo "== other gaps"
has "document without Supabase data (older discover.sh)" "$(doc "$LOCAL" null | census)" "CHECK INCOMPLETE: discover document has no Supabase stack data"
has "an offline host is a gap" "$(doc '[{"name":"host-b","kind":"ssh","reachable":false}]' '[]' | census)" "host-b: host offline, stacks not listed"
has "a reachable host with no scan entry is a gap" "$(doc "$LOCAL" '[]' | census)" "local: stacks not listed"
ET="$(cm_sb_collect local local "" true "$W1")"
OUTT="$(doc "$LOCAL" "[$ET]" | census)"
has "a cut-off worktree list is a gap" "$OUTT" "local: worktree list cut off, stack ownership not provable"
has "and it emits no orphan row (a stack could belong to an unlisted worktree)" "$OUTT" "supabase-stacks: orphans 0 (target 0) (CHECK INCOMPLETE"
hasnot "no SUPABASE row for a cut-off host" "$OUTT" "supabase-stack:"

echo "== remote host over ssh"
REMOTE='[{"name":"host-b","kind":"ssh","reachable":true}]'
ER="$(STUB_SSH_LOG="$ROOT/ssh.log" cm_sb_collect host-b ssh host-b false "$W1" "$W2")"
eq "ssh scan ok, ids read through the quoting" "$(jq -r '"\(.ok) \(.docker) \([.worktrees[].projectId] | join("|"))"' <<<"$ER")" "true ok live-1|it's other"
has "ssh target and a sh -s command were used" "$(cat "$ROOT/ssh.log")" "-- host-b sh -s --"
has "remote orphan row names the remote host" "$(doc "$REMOTE" "[$ER]" | census)" "  supabase-stack: ghost-9 @ host-b"
EF="$(STUB_SSH_FAIL=1 cm_sb_collect host-b ssh host-b false "$W1")"
eq "ssh failure: ok false" "$(jq -r .ok <<<"$EF")" "false"
has "ssh failure: INCOMPLETE names the host and the failed scan" "$(doc "$REMOTE" "[$EF]" | census)" "host-b: stack scan did not finish (exit 255)"
EB="$(cm_sb_collect host-b ssh '-oProxyCommand=x' false "$W1")"
eq "an option-shaped ssh target is refused, never run" "$(jq -r .ok <<<"$EB")" "false"

echo "== --table and the ledger-backed digest"
TAB="$(doc "$LOCAL" "[$E1]" | "$HERE/../classify.sh" --table 2>/dev/null)"
has "table prints the count line" "$TAB" "supabase-stacks: 2"
has "table prints one SUPABASE-STACK row per orphan" "$TAB" "SUPABASE-STACK"
J="$(doc "$LOCAL" "[$E1]" | "$HERE/../classify.sh" 2>/dev/null)"
eq "JSON carries .supabaseStacks.orphans" "$(jq -r '.supabaseStacks.orphans | map(.projectId) | join(",")' <<<"$J")" "ghost-9,stray-6"
eq "JSON carries complete" "$(jq -r '.supabaseStacks.complete' <<<"$J")" "true"

# digest --full reads ledger.supabaseStacks (the tick copies classify's .supabaseStacks plus checkedAt, as for violationCheck).
# gh is a stub that fails: the digest then says "unknown (gh failed)" and the other sections still render.
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
NOWISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
dig() { jq -cn --argjson sb "$1" --arg at "$NOWISO" '{workers: {}, supabaseStacks: ($sb + {checkedAt: $at})}' > "$CM_HOME/ledger.json"
  "$HERE/../digest.sh" "${@:2}" --ledger "$CM_HOME/ledger.json" 2>/dev/null; }
DG="$(dig "$(jq -c .supabaseStacks <<<"$J")" --full)"
has "digest --full lists the orphan stack under its heading" "$DG" "Supabase stacks without a worktree"
has "digest --full names host, id and container count"       "$DG" "local ghost-9: 3 containers, no live Orca worktree names it"
DGI="$(dig '{"orphans":[],"complete":false,"gaps":["local: docker did not answer, stacks not checked"]}' --full)"
has "digest --full: an incomplete check is never read as none" "$DGI" "CHECK INCOMPLETE, not proof of none: local: docker did not answer, stacks not checked"
DGC="$(dig '{"orphans":[],"complete":true,"gaps":[]}' --full)"
hasnot "digest --full: a complete check with no orphans prints nothing" "$DGC" "Supabase stacks"
printf '{"workers":{}}\n' > "$CM_HOME/ledger.json"
DGN="$("$HERE/../digest.sh" --full --ledger "$CM_HOME/ledger.json" 2>/dev/null)"
has "digest --full: a ledger with no supabaseStacks says the check did not run" "$DGN" "CHECK NOT RUN: the ledger has no supabaseStacks"
DGG="$(dig "$(jq -c .supabaseStacks <<<"$J")")"
hasnot "the group digest (no --full) never shows it" "$DGG" "Supabase stacks"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
