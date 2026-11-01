#!/usr/bin/env bash
# teardown-owner.sh: behaviour tests for teardown.sh lead mode (--owner) and for the beads
# old-schema excuse. Hermetic: a throwaway repo whose origin is a local bare repo, linked
# worktrees as children, a stubbed orca (worktree ps / worktree list / terminal), gh and bd.
# Synthetic names only (lane-a, host-b). Nothing outside a mktemp dir is touched; there is NO
# ledger in lead-mode cases, and the tests prove none is created.
#
#   scripts/test/teardown-owner.sh            # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE
TD="$HERE/../teardown.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-owner.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/cmhome"
mkdir -p "$CM_HOME" "$ROOT/bin"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export MC_TOKEN_FILE="$ROOT/no-mc-token" MC_QUIET=1
export CM_BD_CMD=cm-no-such-bd

BARE="$ROOT/github.com/AcmeOrg/acme-app.git"
git init -q --bare -b main "$BARE"
M="$ROOT/main"
git init -q -b main "$M"
git -C "$M" remote add origin "$BARE"
mkdir -p "$M/.beads"
cat > "$M/.beads/issues.jsonl" <<'J'
{"id":"t-ep1","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-ep1.1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-ep1.2","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-par4","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-par4.1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-par4.2","status":"tombstone","updated_at":"2026-10-01T00:00:00Z"}
J
printf 'redirect\n' > "$M/.beads/.gitignore"
git -C "$M" add .beads/issues.jsonl .beads/.gitignore
git -C "$M" commit -qm init --no-gpg-sign
git -C "$M" push -q origin main
git -C "$M" remote set-head origin main >/dev/null 2>&1 || true
SHA="$(git -C "$M" rev-parse HEAD)"

mkwt() {
  git -C "$M" worktree add -q -b "b-$1" "$ROOT/wt/$1" main >/dev/null 2>&1
  git -C "$ROOT/wt/$1" push -q origin "b-$1" >/dev/null 2>&1
  (cd "$ROOT/wt/$1" && pwd -P)
}
cat > "$ROOT/bin/gh" <<G
#!/usr/bin/env bash
echo '[{"number":1,"state":"MERGED","headRefOid":"$SHA"}]'
G
cat > "$ROOT/bin/orca-stub" <<'O'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree ps") [ "${STUB_PS_FAIL:-0}" = 1 ] && exit 1
    jq -cn --arg p "$STUB_PATH" --arg n "${STUB_NAME:-x}" --arg id "${STUB_WID:-r::x}" --arg c "${STUB_COMMENT:-}" \
    --argjson two "${STUB_PS_TWO:-0}" --argjson cut "${STUB_PS_CUT:-0}" --argjson tr "${STUB_PS_TRUNC_WITH_ROW:-0}" '{result:((if $tr == 1 then {truncated:true,totalCount:900} else {} end) + ({worktrees:([{path:$p,worktreeId:$id,displayName:$n,comment:$c,status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}]
      + (if $two == 1 then [{path:"/elsewhere/kid-1",worktreeId:"r::y",displayName:$n,comment:"",status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}] else [] end))} + (if $cut == 1 then {truncated:true,totalCount:900,worktrees:[{path:"/elsewhere/other",worktreeId:"r::z",displayName:"other",comment:"",status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}]} else {} end)))}' ;;
  "worktree list")
    repo=""
    for a in "$@"; do [ "$a" = "--environment" ] && [ "${STUB_ENV_DOWN:-0}" = 1 ] && exit 1; case "$a" in name:*) repo="${a#name:}" ;; esac; done
    [ "${STUB_LIST_FAIL:-0}" = 1 ] && exit 1
    # --repo name:X keeps only the rows of that repo (a row without a repoName belongs to every repo)
    if [ -n "$repo" ]; then jq -c --arg r "$repo" '.result.worktrees |= map(select((.repoName // $r) == $r))' "$STUB_LIST"
    else cat "$STUB_LIST"; fi ;;
  "terminal list") echo '{"result":{"terminals":[]}}' ;;
  "terminal close") : ;;
  "worktree rm") [ -n "${STUB_ORCA_RM_MAIN:-}" ] || exit 0
    exec git -C "$STUB_ORCA_RM_MAIN" worktree remove "$STUB_PATH" ;;
esac
O
cat > "$ROOT/bin/bd-stub" <<'B'
#!/usr/bin/env bash
case " $* " in *" where "*) exit 1 ;; esac
if [ -n "${STUB_BD_ERR:-}" ]; then printf 'Warning: noise\n%s\n' "$STUB_BD_ERR" >&2; exit 1; fi
[ "${STUB_BD_FAIL:-0}" = 1 ] && exit 1
cat "${STUB_BD_JSON:-/dev/null}"
B
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca-stub" "$ROOT/bin/bd-stub"
export PATH="$ROOT/bin:$PATH" ORCA_CLI_COMMAND="$ROOT/bin/orca-stub"

# lists <lead comment> [other lead comment]: the worktree list of the lead's host.
LIST="$ROOT/list.json"
export STUB_LIST="$LIST"
lists() {
  jq -cn --arg a "$1" --arg b "${2:-}" --arg lp "$LA" '{result:{worktrees:[
    {path:$lp, displayName:"lane-a", comment:$a},
    {path:"/lead/lane-b", displayName:"lane-b", comment:$b}]}}' > "$LIST"
}

PASS=0; FAIL=0
# run <label> <want-exit> <grep-pattern> <child-path> [teardown args after the host and path]
run() {
  local label="$1" want="$2" pat="$3" p="$4" out rc
  shift 4
  out="$(STUB_PATH="$p" STUB_NAME="${p##*/}" "$TD" local "$p" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -q -- "$pat"; then
    PASS=$((PASS + 1)); printf 'PASS %-62s rc=%s\n' "$label" "$rc"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %-62s rc=%s want=%s\n%s\n' "$label" "$rc" "$want" "$out"
  fi
}
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }

K1="$(mkwt kid-1)"; K2="$(mkwt kid-2)"; K3="$(mkwt kid-3)"; K4="$(mkwt kid-4)"; K5="$(mkwt kid-5)"
LA="$(mkwt lane-a)"; K6="$(mkwt kid-6)"; K7="$(mkwt kid-7)"; K8="$(mkwt kid-8)"; SW="$(mkwt ops-sweeper)"; K9="$(mkwt kid-9)"
rm -f "$CM_HOME/ledger.json"

echo "== lead mode: ownership proof, no ledger"
lists $'cm:running 3 workers\ncm:child kid-1\ncm:child kid-2'
run "listed child (cm:child line): plan ok"                  0 'listed in the comment of lane-a' "$K1" --owner lane-a
run "listed child: ledger line says not used"                0 'ledger .*not used' "$K1" --owner lane-a
run "listed by absolute lead path"                           0 'listed in the comment' "$K2" --owner "$LA"
if [ ! -e "$CM_HOME/ledger.json" ] && [ -z "$(ls -A "$CM_HOME")" ]; then ok "no ledger or other state was created in CM_HOME"; else bad "lead mode wrote into CM_HOME" "$(ls -A "$CM_HOME")"; fi
# A foreign CM_HOME (another project's ledger leaked in) must not be read in lead mode (synthetic projects).
lists $'cm:running 3 workers\ncm:child kid-1\ncm:child kid-2'
printf '%s\n' '{"project":"project-b","workers":{"w-x":{"host":"local","path":"/nowhere","standing":false}}}' > "$CM_HOME/ledger.json"
SUM_BEFORE="$(cksum < "$CM_HOME/ledger.json")"
CM_PROJECT_ID=project-a run "foreign ledger in CM_HOME: lead mode still plans"   0 'listed in the comment of lane-a' "$K1" --owner lane-a
CM_PROJECT_ID=project-a run "foreign ledger: lead mode never reads it (not used)" 0 'ledger .*not used' "$K1" --owner lane-a
if [ "$(cksum < "$CM_HOME/ledger.json")" = "$SUM_BEFORE" ]; then ok "foreign ledger left untouched"; else bad "lead mode changed the foreign ledger"; fi
rm -f "$CM_HOME/ledger.json"
lists 'cm:running | WORKERS I OWN: kid-3 (fix a), kid-4 (fix b), kid-5'
run "WORKERS I OWN list: first item"                          0 'listed in the comment' "$K3" --owner lane-a
run "WORKERS I OWN list: middle item"                         0 'listed in the comment' "$K4" --owner lane-a
run "WORKERS I OWN list: last item, no parens"                0 'listed in the comment' "$K5" --owner lane-a
lists 'cm:running 1 worker \n cm:child kid-6 | cm:followup-done x'
run "literal \\n and ' | ' separated cm:child line"            0 'listed in the comment' "$K6" --owner lane-a
lists $'cm:running\ncm:child kid-1'
run "unlisted child refused"                                  3 'not listed in the comment of' "$K7" --owner lane-a
lists $'cm:running\ncm:child kid-1' $'cm:running\ncm:child kid-7'
run "listed by another lead: refusal names that lead"         3 "listed by 'lane-b'" "$K7" --owner lane-a
lists $'cm:running\ncm:child kid-1' $'cm:running\ncm:child kid-1 epic=ep-open'
run "two leads list the same child: no lead removes it alone" 3 "listed by both 'lane-a' and 'lane-b'" "$K1" --owner lane-a
lists $'cm:running\ncm:child kid-1'
run "a tag quoted mid-sentence is not a listing"              3 'not listed' "$K8" --owner lane-a
lists $'cm:running see cm:child kid-8 later'
run "cm:child inside prose is not a listing"                  3 'not listed' "$K8" --owner lane-a
lists $'cm:running\ncm:child ops-sweeper\ncm:child kid-9'

echo "== lead mode: standing, self, flags"
run "standing lane (sweeper name) refused even when listed"   3 'standing lane' "$SW" --owner lane-a
lists $'cm:running\ncm:child kid-1'
OUT="$(STUB_PATH="/elsewhere/kid-1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'more than one worktree'; then ok "a git-only target whose name a tracked worktree carries is ambiguous"; else bad "target not counted in ambiguity" "$OUT"; fi
FR="$(mkwt kid-other-repo)"
# linked worktrees share one origin, so the foreign URL is set for this case only and restored right after
ORIG_URL="$(git -C "$M" remote get-url origin)"
git -C "$FR" remote set-url origin https://github.com/AcmeOrg/other-app.git
lists $'cm:running\ncm:child kid-other-repo'
run "a worktree of another repo in the org is not torn down by a lead" 3 'lead mode tears down only acme-app' "$FR" --owner lane-a
git -C "$M" remote set-url origin "$ORIG_URL"
# lane-shaped names are the same set in both modes (lib.sh cm_lane_shaped): -sweeper, -lead, epic-/epic: prefix.
# Documented single-task names (sweep-<pr>, research-<slug>) are ordinary children.
for _ln in release-sweeper-host-a feature-lead-x epic-abc; do
  LS="$(mkwt "$_ln")"
  lists $'cm:running\ncm:child '"$_ln"
  OUT="$(STUB_PATH="$LS" STUB_NAME="$_ln" "$TD" local "$LS" --owner lane-a 2>&1)"; rc=$?
  if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'lane-shaped name'; then ok "lead mode refuses the lane-shaped name $_ln"; else bad "lane-shaped $_ln not refused" "$OUT"; fi
done
for _ln in sweep-101 research-cost-model; do
  LS="$(mkwt "$_ln")"
  lists $'cm:running\ncm:child '"$_ln"
  OUT="$(STUB_PATH="$LS" STUB_NAME="$_ln" "$TD" local "$LS" --owner lane-a 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then ok "lead mode tears down the single-task name $_ln"; else bad "single-task $_ln refused" "$OUT"; fi
done
DW="$(mkwt demo-weird-name)"
{ cat "$HERE/fixtures/config.test.yaml"; printf 'ownership:\n  leads:\n    demo-weird-name: demo-lane\n'; } > "$ROOT/config-leads.yaml"
lists $'cm:running\ncm:child demo-weird-name'
OUT="$(CM_CONFIG="$ROOT/config-leads.yaml" STUB_PATH="$DW" STUB_NAME=demo-weird-name "$TD" local "$DW" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'ownership lead'; then ok "a configured ownership lead with an unshaped name is refused"; else bad "ownership lead not protected" "$OUT"; fi
{ cat "$HERE/fixtures/config.test.yaml"; printf 'lanes:\n  - { name: triage, standing: true }\nownership:\n  leads:\n    demo-weird-name: demo-lane\n'; } > "$ROOT/config-both.yaml"
TR="$(mkwt triage)"
lists $'cm:running\ncm:child triage\ncm:child demo-weird-name'
OUT="$(CM_CONFIG="$ROOT/config-both.yaml" STUB_PATH="$TR" STUB_NAME=triage "$TD" local "$TR" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'configured lane'; then ok "the last configured lane name is still protected beside ownership leads"; else bad "lane name lost beside the leads" "$OUT"; fi
OUT="$(CM_CONFIG="$ROOT/config-both.yaml" STUB_PATH="$DW" STUB_NAME=demo-weird-name "$TD" local "$DW" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'ownership lead'; then ok "the first ownership lead is still protected beside lanes"; else bad "lead name lost beside the lanes" "$OUT"; fi
OUT="$(STUB_PATH="$DW" STUB_NAME=demo-weird-name "$TD" local "$DW" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "the same name is an ordinary child when no config lists it"; else bad "ordinary child refused" "$OUT"; fi
lists $'cm:running\ncm:child kid-1'
run "lead not found on its host: refused"                     3 "not found, or not unique" "$K1" --owner no-such-lead
lists $'cm:running\ncm:child lane-a'
run "the lead's own worktree is refused"                      3 'a lead is never torn down' "$LA" --owner lane-a
run "--owner with --force-standing is a usage error"          2 'cannot be combined' "$K1" --owner lane-a --force-standing x
run "--owner with --allow-no-pr is a usage error"             2 'cannot be combined' "$K1" --owner lane-a --allow-no-pr
run "--owner with --retire-check is a usage error"            2 'cannot be combined' "$K1" --owner lane-a --retire-check
run "--owner without a value is a usage error"                2 'needs the lead' "$K1" --owner

echo "== lead mode: safety gates still run"
lists $'cm:running\ncm:child kid-1'
echo scratch > "$K1/dirty.txt"
run "dirty child refused"                                     3 'REFUSED' "$K1" --owner lane-a
rm -f "$K1/dirty.txt"
run "clean child: plan ok again"                              0 'dry-run: nothing changed' "$K1" --owner lane-a
printf 'local\n' > "$K2/unpushed.txt"; git -C "$K2" add unpushed.txt; git -C "$K2" commit -qm local --no-gpg-sign
run "unpushed commit refused"                                 3 'REFUSED' "$K2" --owner lane-a
OUT="$(STUB_PATH="$K1" STUB_NAME=kid-1 STUB_COMMENT=$'cm:running\ncm:followup keep-me owner=owner-b keep this' "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q "open follow-up(s) in the child's comment"; then ok "open follow-up in the child's comment refused"; else bad "follow-up gate" "$OUT"; fi
OUT="$(STUB_PATH="$K1" STUB_NAME=kid-1 STUB_COMMENT=$'cm:running\ncm:followup keep-me owner=owner-b keep this\ncm:followup-done keep-me' "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "a follow-up closed in the same comment passes"; else bad "closed follow-up refused" "$OUT"; fi
OUT="$(STUB_PATH="$K1" STUB_NAME=kid-1 STUB_COMMENT=$'cm:done parent work finished\ncm:child grandchild' "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q "declares its own children (grandchild)"; then ok "a child that declares its own cm:child is refused"; else bad "descendant gate (cm:child)" "$OUT"; fi
OUT="$(STUB_PATH="$K1" STUB_NAME=kid-1 STUB_COMMENT=$'cm:done x\nWORKERS I OWN: gk-1, gk-2' "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q "declares its own children (gk-1, gk-2)"; then ok "a child with a WORKERS I OWN list is refused"; else bad "descendant gate (WORKERS I OWN)" "$OUT"; fi
OUT="$(STUB_PATH="$K1" STUB_NAME=kid-1 STUB_COMMENT=$'cm:done x\nWORKERS I OWN: none' "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "WORKERS I OWN: none does not block"; else bad "WORKERS I OWN none refused" "$OUT"; fi

echo "== lead mode: host unreachable"
OUT="$(STUB_LIST_FAIL=1 STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'unreachable or its worktree list unreadable'; then ok "lead's worktree list fails: refused"; else bad "owner list failure" "$OUT"; fi
OUT="$(STUB_ENV_DOWN=1 STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a --owner-host host-b 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'owner host host-b unreachable'; then ok "--owner-host down: refused"; else bad "owner host down" "$OUT"; fi
OUT="$(STUB_PS_FAIL=1 STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'unreachable'; then ok "child's Orca host down: refused"; else bad "child host down" "$OUT"; fi
lists $'cm:running\ncm:child kid-1@local'
run "--owner-host given and reachable: listed child ok"       0 'listed in the comment of lane-a on host-b' "$K1" --owner lane-a --owner-host host-b
lists $'cm:running\ncm:child kid-1'
run "unqualified name on another lead host: not this child"    3 'not listed in the comment of' "$K1" --owner lane-a --owner-host host-b

echo "== lead mode: a listing is bound to the child's host (same name on two hosts)"
lists $'cm:running\ncm:child kid-1@host-b'
run "child listed for host-b is not the local kid-1"           3 'not listed in the comment of' "$K1" --owner lane-a
lists $'cm:running\ncm:child kid-1@local'
run "child listed as name@local is the local kid-1"            0 'listed in the comment' "$K1" --owner lane-a
lists $'cm:running\nWORKERS I OWN: kid-3@host-b (x), kid-4@local (y)'
run "WORKERS I OWN name@host: other host refused"              3 'not listed in the comment of' "$K3" --owner lane-a
run "WORKERS I OWN name@host: this host ok"                    0 'listed in the comment' "$K4" --owner lane-a
lists $'cm:running\ncm:child kid-1@host-b epic=t-ep1'
run "an epic= on another host's listing is not applied here"   3 'not listed in the comment of' "$K1" --owner lane-a
jq -cn --arg lp "$LA" --arg k "$K1" '{result:{worktrees:[
  {path:$lp, displayName:"lane-a", comment:"cm:running\ncm:child kid-1"},
  {path:$k, displayName:"kid-1", comment:""},
  {path:"/other/kid-1", displayName:"kid-1", comment:""}]}}' > "$LIST"
run "two worktrees named kid-1 on the lead host: ambiguous"    3 'more than one worktree' "$K1" --owner lane-a
lists $'cm:running\ncm:child kid-1'
# the child's own host: two worktrees named kid-1 there (STUB_PS_TWO adds a second row to the ps answer)
OUT="$(STUB_PS_TWO=1 STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'more than one worktree on local'; then ok "two kid-1 on the child's host: ambiguous, refused"; else bad "child host ambiguity" "$OUT"; fi

OUT="$(STUB_PS_CUT=1 STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'census truncated and this worktree'; then ok "truncated child census with no row: refused, comment unknown"; else bad "truncated census accepted" "$OUT"; fi

echo "== lead mode: only this project's leads prove ownership; cut-off lists prove nothing"
jq -cn --arg k "$K1" '{result:{worktrees:[{path:"/lead/other-proj",displayName:"lane-f",repoName:"other-proj",comment:"cm:running\ncm:child kid-1"}]}}' > "$LIST"
OUT="$(CM_ORCA_REPO=acme-app STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-f 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'not found, or not unique'; then ok "a lead of another repo does not prove ownership"; else bad "foreign lead accepted" "$OUT"; fi
OUT="$(STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-f 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "no configured repo: the list is not filtered (unchanged)"; else bad "unfiltered list refused" "$OUT"; fi
jq -cn '{result:{truncated:true,totalCount:900,worktrees:[{path:"/lead/lane-a",displayName:"lane-a",comment:"cm:running\ncm:child kid-1"}]}}' > "$LIST"
OUT="$(STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'worktree list on local was truncated'; then ok "truncated owner list: refused"; else bad "truncated owner list accepted" "$OUT"; fi
lists $'cm:running\ncm:child kid-1'
OUT="$(STUB_PS_TRUNC_WITH_ROW=1 STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" local "$K1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'census on local was truncated'; then ok "truncated child census that includes the row: refused"; else bad "truncated census with row accepted" "$OUT"; fi

echo "== lead mode on a remote child: the configured hostname is expected, no ledger"
cat > "$ROOT/bin/ssh" <<'S'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac; done
shift
exec bash -c "$*"
S
chmod +x "$ROOT/bin/ssh"
SHORT="$(hostname -s)"
{ cat "$HERE/fixtures/config.test.yaml"; printf 'hosts:\n  per_host:\n    host-b: { role: general, maxWorkers: 2, hostname: %s }\n' "$SHORT"; } > "$ROOT/config-host.yaml"
lists $'cm:running\ncm:child kid-1@host-b'
OUT="$(CM_CONFIG="$ROOT/config-host.yaml" CM_SSH_TARGET=fleet-box STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" host-b "$K1" --owner lane-a 2>&1)"
if printf '%s' "$OUT" | grep -q "ssh .*fleet-box is $SHORT"; then ok "configured hosts.per_host hostname satisfies the ssh identity check in lead mode"; else bad "config hostname ignored in lead mode" "$OUT"; fi
OUT="$(CM_SSH_TARGET=fleet-box STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" host-b "$K1" --owner lane-a 2>&1)"
if printf '%s' "$OUT" | grep -q "ssh target is not host host-b"; then ok "no configured hostname: the host alias is still expected"; else bad "alias fallback lost" "$OUT"; fi
rm -f -- "$ROOT/bin/ssh"
lists $'cm:running\ncm:child kid-1'

echo "== lead mode: an epic the child owns is gated (declared as epic=<id> or --epic)"
E1="$(mkwt ekid-1)"; E2="$(mkwt ekid-2)"; E3="$(mkwt ekid-3)"
lists $'cm:running\ncm:child ekid-1 epic=t-ep1\ncm:child ekid-2 epic=t-par4\ncm:child ekid-3'
run "declared epic with an open bead: refused"                3 '1 open bead(s) under epic t-ep1' "$E1" --owner lane-a
run "declared epic fully closed: plan ok"                     0 'all 2 closed under t-par4' "$E2" --owner lane-a
run "--epic names an epic the line did not declare"           3 '1 open bead(s) under epic t-ep1' "$E3" --owner lane-a --epic t-ep1
run "--epic without --owner is a usage error"                 2 'only for --owner' "$E3" --epic t-ep1
run "--epic with a bad id is a usage error"                   2 'needs a bead id' "$E3" --owner lane-a --epic '-x'
run "an undeclared epic leaves only the unmerged-beads check" 0 'no unmerged open beads' "$E3" --owner lane-a

echo "== lead mode: apply tears down through Orca, leaves no ledger"
lists $'cm:running\ncm:child kid-9'
OUT="$(STUB_ORCA_RM_MAIN="$M" STUB_PATH="$K9" STUB_NAME=kid-9 "$TD" local "$K9" --owner lane-a --apply 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -d "$K9" ]; then ok "apply removed the listed child's worktree"; else bad "apply failed" "rc=$rc $OUT"; fi
# the comment archive lives under CM_HOME/salvage (host-local); the ledger and its backup ring must not exist
if [ ! -e "$CM_HOME/ledger.json" ] && [ ! -e "$CM_HOME/ledger.bak" ] && [ ! -e "$CM_HOME/ledger.json.lock" ]; then ok "apply wrote no ledger, no backup ring, no ledger lock"; else bad "apply touched the ledger" "$(ls -A "$CM_HOME")"; fi

echo "== beads store at an old schema (bd cannot read it)"
export CM_BD_CMD="$ROOT/bin/bd-stub" STUB_BD_ERR='Error: pending schema migrations: store at schema v53, bd expects v66'
N1="$(mkwt fresh-1)"; N2="$(mkwt fresh-2)"; N3="$(mkwt fresh-3)"; N4="$(mkwt fresh-4)"; N5="$(mkwt fresh-5)"
lists $'cm:running\ncm:child fresh-1\ncm:child fresh-2\ncm:child fresh-3\ncm:child fresh-4\ncm:child fresh-5'
run "fresh worktree, unreadable store: excused, plan ok"      0 'excused, no tracked .beads change' "$N1" --owner lane-a
run "excuse needs no flag and no --salvage"                   0 'dry-run: nothing changed' "$N1" --owner lane-a
printf '{"id":"t-new","status":"open","updated_at":"2026-10-20T00:00:00Z"}\n' >> "$N2/.beads/issues.jsonl"
git -C "$N2" add .beads/issues.jsonl; git -C "$N2" commit -qm bead --no-gpg-sign; git -C "$N2" push -q origin HEAD >/dev/null 2>&1
run "tracked .beads change: still refused, hint names the flag" 3 'beads-unreadable-ok' "$N2" --owner lane-a
printf '{}\n' > "$N3/.beads/extra.jsonl"
run "untracked bead file: still refused"                      3 'beads-unreadable-ok' "$N3" --owner lane-a
mkdir -p "$N4/.beads/embeddeddolt"; echo x > "$N4/.beads/embeddeddolt/data"
run "bd runtime store alone is not a bead change (salvage rules apply)" 3 'salvage' "$N4" --owner lane-a
run "bd runtime store with --salvage: plan ok"                0 'excused' "$N4" --owner lane-a --salvage
# an Error that is not about the schema (an external database refusing the connection) is unknown
# store state, not an old schema: never excused on its own
OUT="$(STUB_BD_ERR='Error: dial tcp 10.0.0.5:3306: connect: connection refused' STUB_PATH="$N5" STUB_NAME=fresh-5 "$TD" local "$N5" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'beads-unreadable-ok'; then ok "a connection error is not excused, the flag is named"; else bad "connection error was excused" "rc=$rc $OUT"; fi
# a bd that fails with no Error line (a crash, a timeout) is not an old-schema store: not excused
OUT="$(STUB_BD_ERR='' STUB_BD_FAIL=1 STUB_PATH="$N5" STUB_NAME=fresh-5 "$TD" local "$N5" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'beads source failed\|beads read failed'; then ok "a bd failure with no Error line is not excused"; else bad "bd failure was excused" "rc=$rc $OUT"; fi
echo "-- concertmaster mode keeps the open-bead check"
mkdir -p "$CM_HOME"
printf '{"workers":{"w-a":{"host":"local","path":"%s","standing":false,"beadsEpic":"t-ep1"},"w-b":{"host":"local","path":"%s","standing":false,"beadsEpic":"t-par4"}}}' "$N1" "$N5" > "$CM_HOME/ledger.json"
run "epic with open beads: refused even though bd is unreadable" 3 'open bead' "$N1"
run "closed epic, fresh worktree, unreadable store: ok"       0 'excused' "$N5"
run "explicit --beads-unreadable-ok still works there"        0 'beads-unread' "$N5" --salvage --beads-unreadable-ok 'schema older than bd'

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
