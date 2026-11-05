#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
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
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; [ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
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
# STUB_GH: none (no PR at all), open (an OPEN PR), closed; default MERGED
case "\${STUB_GH:-}" in
  none) echo '[]' ;;
  open) echo '[{"number":2,"state":"OPEN","headRefOid":"$SHA"}]' ;;
  closed) echo '[{"number":3,"state":"CLOSED","headRefOid":"$SHA"}]' ;;
  *) echo '[{"number":1,"state":"MERGED","headRefOid":"$SHA"}]' ;;
esac
G
cat > "$ROOT/bin/orca-stub" <<'O'
#!/usr/bin/env bash
[ -z "${STUB_LOG:-}" ] || printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "host list") [ "${STUB_HOSTS_FAIL:-0}" = 1 ] && exit 1
    jq -cn --arg h "${STUB_HOSTS:-}" '{ok:true,result:{hosts:([{kind:"local",name:"this machine"}] + [$h | split(" ")[] | select(length > 0) | {kind:"ssh",name:.}])}}' ;;
  "worktree ps") [ "${STUB_PS_FAIL:-0}" = 1 ] && exit 1
    jq -cn --arg p "$STUB_PATH" --arg n "${STUB_NAME:-x}" --arg id "${STUB_WID:-r::x}" --arg c "${STUB_COMMENT:-}" \
    --argjson two "${STUB_PS_TWO:-0}" --argjson cut "${STUB_PS_CUT:-0}" --argjson tr "${STUB_PS_TRUNC_WITH_ROW:-0}" '{result:((if $tr == 1 then {truncated:true,totalCount:900} else {} end) + ({worktrees:([{path:$p,worktreeId:$id,displayName:$n,comment:$c,status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}]
      + (if $two == 1 then [{path:"/elsewhere/kid-1",worktreeId:"r::y",displayName:$n,comment:"",status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}] else [] end))} + (if $cut == 1 then {truncated:true,totalCount:900,worktrees:[{path:"/elsewhere/other",worktreeId:"r::z",displayName:"other",comment:"",status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}]} else {} end)))}' ;;
  "worktree list")
    repo=""; envh=0
    for a in "$@"; do [ "$a" = "--environment" ] && envh=1; [ "$a" = "--environment" ] && [ "${STUB_ENV_DOWN:-0}" = 1 ] && exit 1; case "$a" in name:*) repo="${a#name:}" ;; esac; done
    [ "${STUB_LIST_FAIL:-0}" = 1 ] && exit 1
    # STUB_ENV_NOREPO=1: a remote host with no repo of this project answers the repo-scoped list with repo_not_found;
    # STUB_ENV_ERRCODE=<code>: it answers that other error code. Both exit 1 with a JSON error, as the real CLI does.
    if [ "$envh" = 1 ] && [ -n "$repo" ] && { [ "${STUB_ENV_NOREPO:-0}" = 1 ] || [ -n "${STUB_ENV_ERRCODE:-}" ]; }; then
      jq -cn --arg c "$([ "${STUB_ENV_NOREPO:-0}" = 1 ] && echo repo_not_found || echo "$STUB_ENV_ERRCODE")" '{ok:false,error:{code:$c,message:"stub"}}'; exit 1
    fi
    # the local host reads STUB_LIST_LOCAL, any other host STUB_LIST_ENV; both default to STUB_LIST
    f="$STUB_LIST"
    if [ "$envh" = 1 ]; then f="${STUB_LIST_ENV:-$STUB_LIST}"
      [ "${STUB_ENV_GARBAGE:-0}" != 1 ] || { echo 'not json'; exit 0; }
    else f="${STUB_LIST_LOCAL:-$STUB_LIST}"; fi
    # --repo name:X keeps only the rows of that repo (a row without a repoName belongs to every repo)
    { if [ -n "$repo" ]; then jq -c --arg r "$repo" '.result.worktrees |= map(select((.repoName // $r) == $r))' "$f"
      else cat "$f"; fi; } | jq -c --argjson tr "$([ "$envh" = 1 ] && echo "${STUB_ENV_TRUNC:-0}" || echo 0)" \
        '. + {ok:true} | if $tr == 1 then .result += {truncated:true,totalCount:900} else . end' ;;
  "repo list") [ "${STUB_REPOS_FAIL:-0}" = 1 ] && { echo '{"ok":false,"error":{"code":"internal","message":"stub"}}'; exit 1; }
    if [ -n "${STUB_REPOS:-}" ]; then cat "$STUB_REPOS"; else echo '{"ok":true,"result":{"repos":[{"id":"r1","displayName":"other-app","path":"/rival/other-app","kind":"git"}]}}'; fi ;;
  "terminal list")
    if [ "${STUB_TERMS:-0}" = 1 ] && { [ -z "${STUB_CLOSED:-}" ] || [ ! -e "$STUB_CLOSED" ]; }; then echo '{"result":{"terminals":[{"handle":"term-1"}]}}'
    else echo '{"result":{"terminals":[]}}'; fi ;;
  "terminal close") [ -z "${STUB_CLOSED:-}" ] || : > "$STUB_CLOSED"
    # a rival claim that appears while the terminals are being closed
    [ -z "${STUB_FLIP_ENV_LIST:-}" ] || cp -- "$STUB_FLIP_ENV_LIST" "$STUB_LIST_ENV" ;;
  "worktree rm") [ -n "${STUB_ORCA_RM_MAIN:-}" ] || exit 0
    exec git -C "$STUB_ORCA_RM_MAIN" worktree remove "$STUB_PATH" ;;
esac
O
cat > "$ROOT/bin/bd-stub" <<'B'
#!/usr/bin/env bash
# A call against the COPY teardown makes of an unreadable store ("-C <CM_HOME>/tmp/beads-copy.XXXXXX"):
# migrate and list succeed unless STUB_COPY_MIGRATE_FAIL=1; STUB_COPY_LIST is the list JSON (default: []).
case "$*" in *"/tmp/beads-copy."*)
  case " $* " in
    *" dolt commit"*) exit 0 ;;
    *" where "*) a="$*"; d="${a#*-C }"; d="${d%% *}"; printf '{"path":"%s/.beads","database_path":"%s/.beads/embeddeddolt"}\n' "$d" "$d"; exit 0 ;;
    *" migrate schema"*) [ "${STUB_COPY_MIGRATE_FAIL:-0}" = 1 ] && { echo 'Error: migrate failed on the copy' >&2; exit 1; }; exit 0 ;;
    *" list "*) printf '%s\n' "${STUB_COPY_LIST-[]}"; exit 0 ;;
  esac ;;
esac
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
  if [ "$rc" = "$want" ] && grep -q -- "$pat" <<<"$out"; then
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
echo '{"result":{"worktrees":[]}}' > "$ROOT/empty.json"
STUB_HOSTS=host-b STUB_LIST_LOCAL="$ROOT/empty.json" run "--owner-host given and reachable: listed child ok" 0 'listed in the comment of lane-a on host-b' "$K1" --owner lane-a --owner-host host-b
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
# A child on ANOTHER host must be listed as name@host: a bare name only matches a child on the lead's own host.
remote_owner() { CM_CONFIG="$ROOT/config-host.yaml" CM_SSH_TARGET="fleet-box" STUB_PATH="$K1" STUB_NAME=kid-1 "$TD" host-b "$K1" --owner lane-a 2>&1; }
lists $'cm:running\ncm:child kid-1'
OUT="$(remote_owner)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'not listed in the comment of'; then ok "remote child listed by bare name: refused as not listed"; else bad "remote child bare name accepted" "rc=$rc $OUT"; fi
lists $'cm:running\nWORKERS I OWN: kid-1 (x)'
OUT="$(remote_owner)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'not listed in the comment of'; then ok "remote child in WORKERS I OWN by bare name: refused as not listed"; else bad "remote child bare WORKERS I OWN accepted" "rc=$rc $OUT"; fi
lists $'cm:running\ncm:child kid-1@host-b'
OUT="$(remote_owner)"; rc=$?
if printf '%s' "$OUT" | grep -q 'listed in the comment of lane-a' && ! printf '%s' "$OUT" | grep -q 'not listed'; then ok "remote child listed as name@host: accepted"; else bad "remote child name@host refused" "rc=$rc $OUT"; fi
lists $'cm:running\nWORKERS I OWN: kid-1@host-b (x)'
OUT="$(remote_owner)"; rc=$?
if printf '%s' "$OUT" | grep -q 'listed in the comment of lane-a' && ! printf '%s' "$OUT" | grep -q 'not listed'; then ok "remote child in WORKERS I OWN as name@host: accepted"; else bad "remote child WORKERS I OWN name@host refused" "rc=$rc $OUT"; fi
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

echo "== lead mode: cross-host rival-claim scan"
RV1="$(mkwt rv-1)"; RV2="$(mkwt rv-2)"; RV3="$(mkwt rv-3)"
lists $'cm:running\ncm:child rv-1\ncm:child rv-2\ncm:child rv-3'
echo '{"result":{"worktrees":[]}}' > "$ROOT/empty.json"
envlist() { jq -cn --arg c "$1" '{result:{worktrees:[{path:"/rival/lane-z",displayName:"lane-z",comment:$c}]}}' > "$ROOT/env.json"; }
rv() { STUB_HOSTS=host-b STUB_LIST_ENV="$ROOT/env.json" run "$@"; }
run "one host, census complete: plan ok, scan reports clean"       0 'no other worktree on any host claims this name' "$RV1" --owner lane-a
envlist 'cm:running'
rv "second host without a claim: plan ok"                          0 'census complete' "$RV1" --owner lane-a
envlist $'cm:running\ncm:child rv-1'
rv "cross-host claim (cm:child) refuses and names the rival"       3 'RIVAL: claimed by lane-z@host-b' "$RV1" --owner lane-a
envlist $'cm:running\ncm:child rv-1@local'
rv "cross-host claim as name@host refuses"                         3 'RIVAL: claimed by lane-z@host-b' "$RV1" --owner lane-a
envlist 'cm:running | WORKERS I OWN: rv-1 (fix a), other-x'
rv "cross-host claim in a WORKERS I OWN list refuses"              3 'RIVAL: claimed by lane-z@host-b' "$RV1" --owner lane-a
envlist $'cm:running\ncm:child rv-1'
rv "a claim on another child leaves this one alone"                0 'census complete' "$RV2" --owner lane-a
for _c in $'cm:running\nno longer cm:child rv-1' $'cm:running\n(cm:child rv-1)' $'cm:running\ncm:child rv-10' $'cm:running\ncm:child my-rv-1' \
          $'cm:running | WORKERS I OWN: rv-11, xrv-1' $'cm:running\nsee rv-1 in the notes' $'cm:running rv-1 is mine'; do
  envlist "$_c"
  rv "ignored claim (negated, parenthesised or substring): $(printf '%s' "$_c" | tr '\n' '|' | cut -c 1-44)" 0 'census complete' "$RV3" --owner lane-a
done
envlist $'cm:running\ncm:child rv-3'
rv "the same child name claimed by a lead on the other host: refuses" 3 'RIVAL' "$RV3" --owner lane-a
echo "-- incomplete census refuses"
envlist 'cm:running'
OUT="$(STUB_HOSTS=host-b STUB_ENV_DOWN=1 STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'UNKNOWN: the census of all hosts is incomplete'; then ok "a host that is offline: refused, not read as empty"; else bad "offline host accepted" "rc=$rc $OUT"; fi
OUT="$(STUB_HOSTS=host-b STUB_ENV_GARBAGE=1 STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'census of all hosts is incomplete'; then ok "a host that answers garbage: refused"; else bad "malformed host accepted" "rc=$rc $OUT"; fi
OUT="$(STUB_HOSTS=host-b STUB_ENV_TRUNC=1 STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'truncated'; then ok "a host list cut off at the limit: refused"; else bad "truncated host accepted" "rc=$rc $OUT"; fi
OUT="$(STUB_HOSTS=host-b STUB_HOSTS_FAIL=1 STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'orca host list failed'; then ok "the host list itself failing: refused"; else bad "host list failure accepted" "rc=$rc $OUT"; fi
echo "-- a host with no repo of this project (repo_not_found) is complete only when proven; the dry run of a child does not refuse because of it"
envlist 'cm:running'
# CM_ORCA_REPO=acme-app on each case below scopes every list to the project repo, as production does (config worktrees.orca_repo)
LOGNR="$ROOT/norepo.log"; : > "$LOGNR"
OUT="$(CM_ORCA_REPO=acme-app STUB_LOG="$LOGNR" STUB_HOSTS=host-b STUB_ENV_NOREPO=1 STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'census complete' && ! printf '%s' "$OUT" | grep -q 'incomplete' \
   && grep -E -q -- '^repo list .*host-b' "$LOGNR" && grep -E -- '^worktree list .*host-b' "$LOGNR" | grep -q -v -- '--repo'; then ok "host-b has no repo (proven): census complete, the child's dry run is not refused"; else bad "repo_not_found host refused or not complete" "rc=$rc $OUT"; fi
jq -cn '{ok:true,result:{repos:[{id:"r9",displayName:"renamed-app",path:"/w/acme/main",kind:"git"}]}}' > "$ROOT/repos-match.json"
OUT="$(CM_ORCA_REPO=acme-app STUB_HOSTS=host-b STUB_ENV_NOREPO=1 STUB_REPOS="$ROOT/repos-match.json" STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'census of all hosts is incomplete' && printf '%s' "$OUT" | grep -q '/w/acme/main'; then ok "repo_not_found but the repo exists under another name: refused, reason names its path"; else bad "renamed repo not caught" "rc=$rc $OUT"; fi
jq -cn '{result:{worktrees:[{path:"/w/acme/lane-q",displayName:"lane-q",comment:"cm:running"}]}}' > "$ROOT/env-match.json"
OUT="$(CM_ORCA_REPO=acme-app STUB_HOSTS=host-b STUB_ENV_NOREPO=1 STUB_LIST_ENV="$ROOT/env-match.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'census of all hosts is incomplete' && printf '%s' "$OUT" | grep -q '/w/acme/lane-q'; then ok "repo_not_found but a worktree matches path_match: refused, reason names its path"; else bad "matching worktree not caught" "rc=$rc $OUT"; fi
OUT="$(CM_ORCA_REPO=acme-app STUB_HOSTS=host-b STUB_ENV_NOREPO=1 STUB_REPOS_FAIL=1 STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'census of all hosts is incomplete'; then ok "repo_not_found and the repo list fails: refused (fail closed)"; else bad "failed repo list accepted" "rc=$rc $OUT"; fi
OUT="$(CM_ORCA_REPO=acme-app STUB_HOSTS=host-b STUB_ENV_ERRCODE=unauthorized STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'census of all hosts is incomplete'; then ok "a different error code (unauthorized) on a host: refused"; else bad "other error code accepted" "rc=$rc $OUT"; fi
echo "-- no destructive call after a refusal; the scan repeats after the terminals are closed"
OUT="$(STUB_HOSTS=host-b STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$OUT" | grep -q 'repeats on the re-run'; then ok "no terminals to close: the plan does not promise a re-run scan"; else bad "plan promises a re-run with no terminals" "rc=$rc $OUT"; fi
OUT="$(STUB_TERMS=1 STUB_HOSTS=host-b STUB_LIST_ENV="$ROOT/env.json" STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'repeats on the re-run'; then ok "terminals to close: the plan says the scan repeats after they close"; else bad "plan lacks the re-run scan note" "rc=$rc $OUT"; fi
envlist $'cm:running\ncm:child rv-1'
LOG1="$ROOT/log-refused"
OUT="$(STUB_LOG="$LOG1" STUB_ORCA_RM_MAIN="$M" STUB_HOSTS=host-b STUB_LIST_ENV="$ROOT/env.json" STUB_TERMS=1 STUB_PATH="$RV1" STUB_NAME=rv-1 "$TD" local "$RV1" --owner lane-a --apply 2>&1)"; rc=$?
if [ "$rc" = 3 ] && [ -d "$RV1" ] && ! grep -q 'worktree rm\|terminal close' "$LOG1" 2>/dev/null; then ok "apply after a rival refusal closes no terminal and removes nothing"; else bad "destructive call after a refusal" "rc=$rc $OUT $(cat "$LOG1" 2>/dev/null)"; fi
envlist 'cm:running'
printf '%s\n' '{"result":{"worktrees":[{"path":"/rival/lane-z","displayName":"lane-z","comment":"cm:running\ncm:child rv-2"}]}}' > "$ROOT/env-claim.json"
LOG2="$ROOT/log-flip"
OUT="$(STUB_LOG="$LOG2" STUB_CLOSED="$ROOT/closed-flip" STUB_FLIP_ENV_LIST="$ROOT/env-claim.json" STUB_ORCA_RM_MAIN="$M" STUB_HOSTS=host-b STUB_LIST_ENV="$ROOT/env.json" STUB_TERMS=1 STUB_PATH="$RV2" STUB_NAME=rv-2 "$TD" local "$RV2" --owner lane-a --apply 2>&1)"; rc=$?
if [ "$rc" = 3 ] && [ -d "$RV2" ] && printf '%s' "$OUT" | grep -q 'closed terminals' && printf '%s' "$OUT" | grep -q 'RIVAL: claimed by lane-z@host-b' \
   && grep -q 'terminal close' "$LOG2" && ! grep -q 'worktree rm' "$LOG2"; then
  ok "a claim that appears while terminals close is caught by the re-run: nothing removed"
else bad "rival after the self-exec not caught" "rc=$rc $OUT $(cat "$LOG2" 2>/dev/null)"; fi

echo "== lead mode: --allow-no-pr (retirement of an owned child that never had a PR)"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do eval "NP$_i=\"\$(mkwt np-$_i)\""; done
NPS="$(mkwt np-sweeper)"
lists $'cm:running\ncm:child np-1\ncm:child np-2\ncm:child np-3\ncm:child np-4\ncm:child np-5\ncm:child np-6\ncm:child np-7 epic=t-ep1\ncm:child np-9\ncm:child np-10\ncm:child np-11\ncm:child np-12\ncm:child np-13\ncm:child np-sweeper'
GOOD='cm:retire template port never needed a PR'
nopr() { STUB_GH=none run "$@"; }
STUB_COMMENT="$GOOD" nopr "valid request, no PR, clean, 0 ahead: plan ok"        0 'cm:retire request: template port never needed a PR' "$NP1" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" nopr "valid request: reports 0 commits ahead and a dry run"  0 '0 commits ahead of refs/remotes/origin/main' "$NP1" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" nopr "valid request: the plan says why there is no PR"       0 'retired on the child.s own cm:retire request' "$NP1" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" nopr "no PR and no --allow-no-pr still refuses"               3 'no merged/closed PR' "$NP2" --owner lane-a
STUB_COMMENT=$'cm:done finished' nopr "no cm:retire marker: refused"              3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
nopr "no comment at all: refused"                                                 3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
STUB_COMMENT='cm:retire' nopr "cm:retire with no reason: refused"                 3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
STUB_COMMENT='cm:retire     ' nopr "cm:retire with a blank reason: refused"       3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
STUB_COMMENT='cm:retire ... -- !!' nopr "cm:retire whose reason has no letter or digit: refused" 3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
STUB_COMMENT=$'cm:running\ncm:retire later' nopr "cm:retire not at the comment start (unanchored): refused" 3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
STUB_COMMENT='cm:running | cm:retire later' nopr "cm:retire after a pipe on the first line: refused" 3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
STUB_COMMENT='not cm:retire done' nopr "a negated or embedded cm:retire: refused"  3 'NO cm:retire request' "$NP2" --owner lane-a --allow-no-pr
echo scratch > "$NP3/dirty.txt"
STUB_COMMENT="$GOOD" nopr "dirty tree: refused"                                    3 'dirty tree' "$NP3" --owner lane-a --allow-no-pr
rm -f "$NP3/dirty.txt"
printf 'ahead\n' > "$NP4/ahead.txt"; git -C "$NP4" add ahead.txt; git -C "$NP4" commit -qm ahead --no-gpg-sign; git -C "$NP4" push -q origin HEAD >/dev/null 2>&1
STUB_COMMENT="$GOOD" nopr "1 commit ahead of origin/main (pushed to its branch): refused" 3 '1 commit(s) ahead' "$NP4" --owner lane-a --allow-no-pr
mv -- "$BARE" "$BARE.off"
STUB_COMMENT="$GOOD" nopr "fetch of origin fails: refused, ahead count unknown"   3 'commits ahead of it are unknown' "$NP5" --owner lane-a --allow-no-pr
mv -- "$BARE.off" "$BARE"
STUB_COMMENT="$GOOD" STUB_GH=open run "an open PR: refused"                       3 'open PR' "$NP6" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" nopr "child with an open bead under its epic: refused"       3 'open bead(s) under epic t-ep1' "$NP7" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" STUB_TERMS=1 nopr "terminals still open: refused"            3 'terminals already closed' "$NP9" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" STUB_TERMS=1 nopr "terminals open and named with --close-handle: still refused" 3 'does not apply here' "$NP9" --owner lane-a --allow-no-pr --close-handle term-1
STUB_COMMENT="$GOOD" nopr "a standing (lane-shaped) child: refused"               3 'standing lane' "$NPS" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" nopr "a child the lead does not list: refused"               3 'not listed in the comment' "$NP8" --owner lane-a --allow-no-pr
STUB_COMMENT=$'cm:retire open work\ncm:followup keep-me owner=owner-a keep this' nopr "an open follow-up still refuses" 3 "open follow-up" "$NP10" --owner lane-a --allow-no-pr
STUB_COMMENT=$'cm:retire declares kids\ncm:child grandchild' nopr "a child with children of its own still refuses" 3 'declares its own children' "$NP10" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" run "a merged PR: --allow-no-pr changes nothing, plan ok"    0 'MERGED' "$NP11" --owner lane-a --allow-no-pr
STUB_COMMENT='cm:done no retire marker needed' run "a merged PR needs no cm:retire request" 0 'MERGED' "$NP11" --owner lane-a --allow-no-pr
STUB_COMMENT="$GOOD" STUB_GH=closed run "a closed PR: --allow-no-pr changes nothing"  0 'CLOSED' "$NP11" --owner lane-a --allow-no-pr
LOG3="$ROOT/log-nopr-refused"
OUT="$(STUB_LOG="$LOG3" STUB_GH=none STUB_COMMENT='cm:done x' STUB_ORCA_RM_MAIN="$M" STUB_PATH="$NP12" STUB_NAME=np-12 "$TD" local "$NP12" --owner lane-a --allow-no-pr --apply 2>&1)"; rc=$?
if [ "$rc" = 3 ] && [ -d "$NP12" ] && ! grep -q 'worktree rm\|terminal close' "$LOG3" 2>/dev/null; then ok "apply with no cm:retire request: nothing removed, no destructive call"; else bad "destructive call after a no-PR refusal" "rc=$rc $OUT"; fi
LOG4="$ROOT/log-nopr-apply"
OUT="$(STUB_LOG="$LOG4" STUB_GH=none STUB_COMMENT="$GOOD" STUB_ORCA_RM_MAIN="$M" STUB_PATH="$NP13" STUB_NAME=np-13 "$TD" local "$NP13" --owner lane-a --allow-no-pr --apply 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -d "$NP13" ] && grep -q 'worktree rm' "$LOG4"; then ok "apply retires the no-PR child through Orca"; else bad "no-PR apply failed" "rc=$rc $OUT"; fi
if [ ! -e "$CM_HOME/ledger.json" ]; then ok "no-PR retirement wrote no ledger"; else bad "ledger created" "$(ls -A "$CM_HOME")"; fi

echo "== lead mode: detached HEAD (a review worktree) is accepted only on the full fail-closed rule"
# A review worktree is created detached on purpose. mkdet <name> [rev]: detached at rev (default: main, which origin holds).
mkdet() {
  git -C "$M" worktree add -q --detach "$ROOT/wt/$1" "${2:-main}" >/dev/null 2>&1
  (cd "$ROOT/wt/$1" && pwd -P)
}
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do eval "DT$_i=\"\$(mkdet dt-$_i)\""; done
DTB="$(mkwt dt-branch)"
lists $'cm:running\ncm:child dt-1\ncm:child dt-2\ncm:child dt-3\ncm:child dt-4\ncm:child dt-5\ncm:child dt-6\ncm:child dt-7\ncm:child dt-8\ncm:child dt-9\ncm:child dt-10\ncm:child dt-11\ncm:child dt-12\ncm:child dt-13\ncm:child dt-14\ncm:child dt-15\ncm:child dt-16\ncm:child dt-branch\ncm:child dt-stale\ncm:child dt-late'
DGOOD='cm:retire review done'
# accepted: every rule holds
STUB_COMMENT="$DGOOD" run "detached, all rules hold: plan ok"                      0 'dry-run: nothing changed' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: the request is reported on its own line"      0 'detach-retire .*cm:retire request: review done' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: clean tree reported on its own line"          0 'detach-clean .*no tracked change, no untracked file' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: ignored files reported on their own line"     0 'detach-ignored .*no precious ignored path' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: stash reported on its own line"               0 'detach-stash .*none in the repo' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: the remote ref is named on the check line"    0 'detach-remote .*is on origin/main' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: the plan line names the remote ref"           0 'contained in remote ref origin/main' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: no operation in progress, own line"           0 'detach-inprog .*none' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: reported as no PR (detached) on the nopr line" 0 'nopr .*no PR (detached)' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" run "accepted: reported as no PR (detached) in the plan"     0 'no PR (detached): not a merged-PR proof' "$DT1" --owner lane-a
STUB_COMMENT="$DGOOD" STUB_GH=open run "an OPEN PR for the sha is never consulted (no branch to look up)" 0 'dry-run: nothing changed' "$DT1" --owner lane-a
OUT="$(STUB_PATH="$DT1" STUB_NAME=dt-1 STUB_COMMENT="$DGOOD" "$TD" local "$DT1" --owner lane-a 2>&1)"
if ! printf '%s' "$OUT" | grep -q 'MERGED'; then ok "a merged-PR lookup never counts as the proof for a detached HEAD"; else bad "detached HEAD reported a merged PR" "$OUT"; fi
# one refusal per rule, each on its own
STUB_COMMENT=$'cm:done review finished' run "no cm:retire: refused"                  3 'detach-retire .*NO cm:retire request' "$DT2" --owner lane-a
STUB_COMMENT=$'cm:done review finished' run "no cm:retire: the refusal says why"      3 "detached HEAD: needs the child's comment to start with 'cm:retire" "$DT2" --owner lane-a
run "no comment at all: refused"                                                     3 'detach-retire .*NO cm:retire request' "$DT2" --owner lane-a
STUB_COMMENT='cm:retire     ' run "cm:retire with a blank reason: refused"           3 'detach-retire .*NO cm:retire request' "$DT2" --owner lane-a
STUB_COMMENT=$'cm:running\ncm:retire later' run "cm:retire not on the first line: refused" 3 'detach-retire .*NO cm:retire request' "$DT2" --owner lane-a
printf 'changed\n' >> "$DT3/.beads/.gitignore"
STUB_COMMENT="$DGOOD" run "dirty tracked file: refused"                              3 'detach-clean .*NO (1 changed or untracked paths)' "$DT3" --owner lane-a
STUB_COMMENT="$DGOOD" run "dirty tracked file: the refusal says the tree is not clean" 3 'detached HEAD: the tree is not clean' "$DT3" --owner lane-a
printf 'scratch\n' > "$DT4/notes.txt"
STUB_COMMENT="$DGOOD" run "untracked file: refused"                                  3 'detach-clean .*NO (1 changed or untracked paths)' "$DT4" --owner lane-a
# an ignored file that is not regenerable noise (info/exclude is shared by every worktree of the repo)
printf 'review-notes.txt\n' >> "$M/.git/info/exclude"
printf 'secret\n' > "$DT5/review-notes.txt"
STUB_COMMENT="$DGOOD" run "ignored (precious) file, no --salvage: refused"           3 'detach-ignored .*1 precious path(s) and no --salvage' "$DT5" --owner lane-a
STUB_COMMENT="$DGOOD" run "ignored file: the refusal names the detached rule"        3 'detached HEAD: ignored files would be deleted' "$DT5" --owner lane-a
STUB_COMMENT="$DGOOD" run "ignored file with --salvage: accepted, the salvage copies it" 0 'accepted only because --salvage copies and verifies them' "$DT5" --owner lane-a --salvage
STUB_COMMENT="$DGOOD" run "ignored file with --salvage: the plan carries the salvage" 0 'salvage 1 ignored path(s)' "$DT5" --owner lane-a --salvage
git -C "$DT6" commit -q --allow-empty -m local-only --no-gpg-sign
STUB_COMMENT="$DGOOD" run "HEAD only local (on no remote ref): refused"              3 'HEAD is not on any remote ref' "$DT6" --owner lane-a
STUB_COMMENT="$DGOOD" run "HEAD only local: reported on its own line"                3 'detach-remote .*is on no live remote-tracking ref of origin' "$DT6" --owner lane-a
mv -- "$BARE" "$BARE.off"
STUB_COMMENT="$DGOOD" run "fetch of origin fails: refused, not read as contained"    3 'detach-remote .*UNKNOWN (git fetch or ls-remote of origin failed or timed out)' "$DT7" --owner lane-a
STUB_COMMENT="$DGOOD" run "fetch failure: the refusal names the fetch"               3 'the fetch of origin failed or timed out' "$DT7" --owner lane-a
mv -- "$BARE.off" "$BARE"
mkdir -- "$(git -C "$DT8" rev-parse --absolute-git-dir)/rebase-merge"
STUB_COMMENT="$DGOOD" run "rebase in progress: refused"                              3 'detach-inprog .*YES: rebase-merge' "$DT8" --owner lane-a
STUB_COMMENT="$DGOOD" run "rebase in progress: the refusal names the operation"      3 'git operation in progress (rebase-merge' "$DT8" --owner lane-a
# a stash entry is repo-wide (refs/stash is shared by every worktree), so it refuses a clean, pushed, requested HEAD
printf 'wip\n' >> "$DT9/.beads/.gitignore"; git -C "$DT9" stash push -q -m wip
STUB_COMMENT="$DGOOD" run "a stash entry in the repo: refused"                       3 'detach-stash .*1 entr(y/ies) in the repo' "$DT10" --owner lane-a
STUB_COMMENT="$DGOOD" run "a stash entry: the refusal says stashes are shared per repo" 3 'stashes are shared per repo, not per worktree' "$DT10" --owner lane-a
git -C "$DT9" stash drop -q
STUB_COMMENT="$DGOOD" run "stash dropped: the same worktree is accepted again"       0 'detach-stash .*none in the repo' "$DT10" --owner lane-a
# a review worktree made from a PR head sha: the commit is on origin's branch but this checkout has no tracking ref yet,
# so it is on no known remote ref until the fresh fetch (a push to the URL, not the remote name, updates no tracking ref)
git -C "$M" worktree add -q --detach "$ROOT/wt/dt-late" main >/dev/null 2>&1
DTL="$(cd "$ROOT/wt/dt-late" && pwd -P)"
git -C "$DTL" commit -q --allow-empty -m pr-head --no-gpg-sign && git -C "$DTL" push -q "$BARE" HEAD:refs/heads/b-late >/dev/null 2>&1

STUB_COMMENT="$DGOOD" run "PR head not yet fetched: first run defers the unpushed check, accepted" 0 'unpushed .*judged again after the fresh fetch' "$DTL" --owner lane-a
STUB_COMMENT="$DGOOD" run "PR head not yet fetched: once fetched, its remote ref is named" 0 'detach-remote .*is on origin/b-late' "$DTL" --owner lane-a
STUB_COMMENT=$'cm:done review finished' run "an earlier detached refusal skips the fetch" 3 'detach-remote .*not checked' "$DT2" --owner lane-a
# a branch deleted on origin must not keep "holding" the commit through a stale remote-tracking ref (fetch --prune)
git -C "$M" worktree add -q -b b-stale "$ROOT/wt/dt-stale" main >/dev/null 2>&1
DTS="$(cd "$ROOT/wt/dt-stale" && pwd -P)"
git -C "$DTS" commit -q --allow-empty -m only-on-the-branch --no-gpg-sign && git -C "$DTS" push -q origin b-stale >/dev/null 2>&1
git -C "$DTS" checkout -q --detach && git -C "$DTS" branch -q -D b-stale

STUB_COMMENT="$DGOOD" run "branch still on origin: HEAD is on its remote ref, accepted" 0 'detach-remote .*is on origin/b-stale' "$DTS" --owner lane-a
git --git-dir="$BARE" update-ref -d refs/heads/b-stale
STUB_COMMENT="$DGOOD" run "branch deleted on origin (stale tracking ref kept): refused" 3 'HEAD is not on any remote ref' "$DTS" --owner lane-a
if git -C "$DTS" show-ref --verify -q refs/remotes/origin/b-stale; then ok "a dry run prunes nothing: the stale tracking ref is still there"; else bad "the dry run pruned a tracking ref"; fi
# the other gates still run for a detached HEAD
lists $'cm:running\ncm:child dt-11 epic=t-ep1'
STUB_COMMENT="$DGOOD" run "detached: the epic beads gate still refuses"          3 'open bead(s) under epic t-ep1' "$DT11" --owner lane-a
lists $'cm:running\ncm:child dt-1\ncm:child dt-2\ncm:child dt-3\ncm:child dt-4\ncm:child dt-5\ncm:child dt-6\ncm:child dt-7\ncm:child dt-8\ncm:child dt-9\ncm:child dt-10\ncm:child dt-11\ncm:child dt-12\ncm:child dt-13\ncm:child dt-14\ncm:child dt-15\ncm:child dt-16\ncm:child dt-branch\ncm:child dt-stale\ncm:child dt-late'
STUB_COMMENT=$'cm:retire done\ncm:followup keep-me owner=owner-a keep this' run "detached: an open follow-up still refuses" 3 'open follow-up' "$DT11" --owner lane-a
# a branch worktree is unchanged: no detach-* lines, no cm:retire needed
OUT="$(STUB_PATH="$DTB" STUB_NAME=dt-branch STUB_COMMENT='cm:done x' "$TD" local "$DTB" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$OUT" | grep -q 'detach-'; then ok "a branch worktree is unchanged: merged PR, no cm:retire needed, no detach-* lines"; else bad "branch worktree changed" "rc=$rc $OUT"; fi
# apply
LOG5="$ROOT/log-detached-refused"
OUT="$(STUB_LOG="$LOG5" STUB_COMMENT='cm:done x' STUB_ORCA_RM_MAIN="$M" STUB_PATH="$DT12" STUB_NAME=dt-12 "$TD" local "$DT12" --owner lane-a --apply 2>&1)"; rc=$?
if [ "$rc" = 3 ] && [ -d "$DT12" ] && ! grep -q 'worktree rm\|terminal close' "$LOG5" 2>/dev/null; then ok "apply with no cm:retire: nothing removed, no destructive call"; else bad "destructive call after a detached refusal" "rc=$rc $OUT"; fi
LOG6="$ROOT/log-detached-apply"
OUT="$(STUB_LOG="$LOG6" STUB_COMMENT="$DGOOD" STUB_ORCA_RM_MAIN="$M" STUB_PATH="$DT13" STUB_NAME=dt-13 "$TD" local "$DT13" --owner lane-a --apply 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -d "$DT13" ] && grep -q 'worktree rm' "$LOG6"; then ok "apply removes an accepted detached worktree through Orca"; else bad "detached apply failed" "rc=$rc $OUT"; fi
if [ ! -e "$CM_HOME/ledger.json" ]; then ok "detached retirement wrote no ledger"; else bad "ledger created" "$(ls -A "$CM_HOME")"; fi

echo "== beads store at an old schema (bd cannot read it)"
export CM_BD_CMD="$ROOT/bin/bd-stub" STUB_BD_ERR='Error: pending schema migrations: store at schema v53, bd expects v66'
N1="$(mkwt fresh-1)"; N2="$(mkwt fresh-2)"; N3="$(mkwt fresh-3)"; N4="$(mkwt fresh-4)"; N5="$(mkwt fresh-5)"
lists $'cm:running\ncm:child fresh-1\ncm:child fresh-2\ncm:child fresh-3\ncm:child fresh-4\ncm:child fresh-5'
run "fresh worktree, unreadable store: excused, plan ok"      0 'excused, no tracked .beads change' "$N1" --owner lane-a
run "excuse needs no flag and no --salvage"                   0 'dry-run: nothing changed' "$N1" --owner lane-a
# the excusal also reads the store on a migrated COPY: an open bead there, or a failed step, refuses
STUB_COPY_LIST='[{"id":"t-o","status":"open"}]' run "copy of the store lists an open bead: refused" 3 'lists 1 open or in-progress bead(s)' "$N1" --owner lane-a
STUB_COPY_MIGRATE_FAIL=1 run "copy migrate fails: refused"       3 'migrated copy failed' "$N1" --owner lane-a
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
