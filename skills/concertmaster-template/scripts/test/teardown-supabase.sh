#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# teardown-supabase.sh: behaviour tests for teardown.sh stopping the worktree's local Supabase stack.
# Hermetic: a throwaway repo whose origin is a local bare repo, linked worktrees, a stubbed orca, gh,
# docker and supabase (all PATH stubs: no real container is ever read or stopped). Lead mode (--owner),
# so no ledger. Synthetic names only. Nothing outside a mktemp dir is touched.
#
#   scripts/test/teardown-supabase.sh         # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE
TD="$HERE/../teardown.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-sbstop.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
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
mkdir -p "$M/.beads" "$M/supabase"
printf '{"id":"t-x1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}\n' > "$M/.beads/issues.jsonl"
printf 'redirect\n' > "$M/.beads/.gitignore"
printf 'project_id = "shared-default"\n' > "$M/supabase/config.toml"
git -C "$M" add .beads supabase
git -C "$M" commit -qm init --no-gpg-sign
git -C "$M" push -q origin main
git -C "$M" remote set-head origin main >/dev/null 2>&1 || true
SHA="$(git -C "$M" rev-parse HEAD)"

# mkwt <name> [project id]: a linked worktree, pushed, with its own project_id when one is given.
mkwt() {
  git -C "$M" worktree add -q -b "b-$1" "$ROOT/wt/$1" main >/dev/null 2>&1
  if [ -n "${2:-}" ]; then
    printf 'project_id = "%s"\n' "$2" > "$ROOT/wt/$1/supabase/config.toml"
    git -C "$ROOT/wt/$1" add supabase/config.toml && git -C "$ROOT/wt/$1" commit -qm "id $2" --no-gpg-sign
  fi
  git -C "$ROOT/wt/$1" push -q origin "b-$1" >/dev/null 2>&1
  (cd "$ROOT/wt/$1" && pwd -P)
}

cat > "$ROOT/bin/gh" <<G
#!/usr/bin/env bash
echo '[{"number":1,"state":"MERGED","headRefOid":"$SHA"}]'
G
# orca: one row for the worktree under test, plus STUB_PS_EXTRA (a JSON array of more rows).
# worktree list answers the lead's comment from STUB_LIST. worktree rm is logged (ordering) and a no-op.
cat > "$ROOT/bin/orca-stub" <<'O'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") jq -cn '{ok:true,result:{hosts:[{kind:"local",name:"this machine"}]}}' ;;
  "worktree ps")
    jq -cn --arg p "$STUB_PATH" --arg n "${STUB_NAME:-x}" --argjson extra "${STUB_PS_EXTRA:-[]}" --argjson tr "${STUB_PS_TRUNC:-0}" \
      '{ok:true,result:(({worktrees:([{path:$p,worktreeId:("r::" + $n),displayName:$n,comment:"",status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}] + $extra)})
        + (if $tr == 1 then {truncated:true,totalCount:900} elif $tr == 2 then {totalCount:900} else {} end))}' ;;
  "worktree list") jq -c '. + {ok:true}' "$STUB_LIST" ;;
  "terminal list") echo '{"result":{"terminals":[]}}' ;;
  "terminal close") : ;;
  "worktree rm") printf 'orca worktree rm\n' >> "${STUB_LOG:-/dev/null}"; exit 0 ;;
esac
O
# docker: containers/mounts come from files in STUB_SB_DIR; STUB_DOCKER_DOWN=1 makes the daemon unreachable.
cat > "$ROOT/bin/docker" <<'D'
#!/usr/bin/env bash
case "$1" in
  ps) [ "${STUB_DOCKER_DOWN:-0}" = 1 ] && exit 1
      cat "$STUB_SB_DIR/containers" 2>/dev/null; exit 0 ;;
  inspect) shift; [ "${1:-}" != -f ] || shift 2; for cid in "$@"; do awk -v c="$cid" '$1 == c { print $1, $2 }' "$STUB_SB_DIR/mounts" 2>/dev/null; done; exit 0 ;;
esac
exit 0
D
# supabase: `stop --project-id <id>` is logged with its cwd and drops that project's containers.
cat > "$ROOT/bin/supabase" <<'S'
#!/usr/bin/env bash
if [ "$1" = stop ] && [ "$2" = --project-id ]; then
  printf 'supabase stop %s cwd=%s args=%s\n' "$3" "$PWD" "$*" >> "${STUB_LOG:-/dev/null}"
  [ "${STUB_SUPABASE_FAIL:-0}" = 1 ] && exit 1
  [ "${STUB_SUPABASE_KEEP:-0}" = 1 ] && exit 0   # exits 0 but leaves the containers running
  awk -v id="$3" '$2 != id' "$STUB_SB_DIR/containers" > "$STUB_SB_DIR/containers.new" && mv "$STUB_SB_DIR/containers.new" "$STUB_SB_DIR/containers"
  exit 0
fi
exit 0
S
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca-stub" "$ROOT/bin/docker" "$ROOT/bin/supabase"
export PATH="$ROOT/bin:$PATH" ORCA_CLI_COMMAND="$ROOT/bin/orca-stub"
# A PATH with the same stubs and the plain tools teardown.sh needs, but no docker at all.
mkdir -p "$ROOT/binmin"
for t in env bash sh git jq sed awk tr cut head tail sort uniq cat date mkdir dirname basename readlink realpath printf grep sleep ps wc \
         chmod ls find expr xargs timeout diff cp mv touch tee hostname uname id ssh column yq mktemp rm python3 perl; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$ROOT/binmin/$t"
done
for t in gh orca-stub supabase; do ln -sf "$ROOT/bin/$t" "$ROOT/binmin/$t"; done

LIST="$ROOT/list.json"
export STUB_LIST="$LIST" STUB_SB_DIR="$ROOT/sb"
mkdir -p "$STUB_SB_DIR"
lists() { jq -cn --arg c "$1" '{result:{worktrees:[{path:"/lead/lane-a",displayName:"lane-a",comment:$c}]}}' > "$LIST"; }
# stacks <file lines...>: replace the fake docker state. containers: "<cid> <project id>"; mounts: "<cid> <source>".
setc() { : > "$STUB_SB_DIR/containers"; : > "$STUB_SB_DIR/mounts"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$STUB_SB_DIR/containers"; done; }
setm() { : > "$STUB_SB_DIR/mounts"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$STUB_SB_DIR/mounts"; done; }

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
# td <wt> [env assignments...] -- [teardown args]: runs teardown.sh in lead mode against <wt>, output in $OUT, status in $rc.
OUT=""; rc=0
td() {
  local p="$1"; shift
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" != -- ] || shift
  OUT="$(env STUB_PATH="$p" STUB_NAME="${p##*/}" "${envs[@]}" "$TD" local "$p" --owner lane-a "$@" 2>&1)"; rc=$?
}
has() { grep -qF -- "$1" <<<"$OUT"; }

MAIN_ROW="[{\"path\":\"$M\",\"worktreeId\":\"r::main\",\"displayName\":\"main-checkout\",\"comment\":\"\",\"status\":\"idle\",\"agents\":[],\"childWorktreeIds\":[],\"liveTerminalCount\":0}]"

echo "== a stack whose id belongs to this worktree alone is stopped before the worktree goes"
A="$(mkwt sb-a sbuniq-a)"
lists $'cm:running\ncm:child sb-a'
setc "c1 sbuniq-a" "c2 sbuniq-a" "c3 other-proj" "c4 other-proj" "c5 shared-default"
td "$A" STUB_PS_EXTRA="$MAIN_ROW"
if [ "$rc" = 0 ] && has "stack sbuniq-a (2 containers)" && has "no other live worktree has it" && has "supabase stop --project-id sbuniq-a"; then ok "dry-run names the stack and the stop it would run"; else bad "dry-run plan" "$OUT"; fi
if [ "$(wc -l < "$STUB_SB_DIR/containers")" = 5 ]; then ok "dry-run stops nothing"; else bad "dry-run changed the containers"; fi
LOG="$ROOT/log-a"; : > "$LOG"
td "$A" STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if [ "$rc" = 0 ] && has "stopped supabase stack sbuniq-a on local"; then ok "apply reports the stack stopped"; else bad "apply output" "$OUT"; fi
if [ "$(grep -c '^supabase stop' "$LOG")" = 1 ] && [ "$(sed -n 1p "$LOG" | cut -d' ' -f1-3)" = "supabase stop sbuniq-a" ] && [ "$(sed -n 2p "$LOG")" = "orca worktree rm" ]; then
  ok "supabase stop --project-id runs once, BEFORE orca worktree rm"; else bad "ordering" "$(cat "$LOG")"; fi
if ! grep -q -- '--no-backup' "$LOG" && grep -q 'cwd=/ ' "$LOG"; then ok "no --no-backup (volumes kept) and run from /, not from the worktree"; else bad "stop flags or cwd" "$(cat "$LOG")"; fi
if ! grep -q sbuniq-a "$STUB_SB_DIR/containers" && grep -q 'other-proj' "$STUB_SB_DIR/containers" && grep -q 'shared-default' "$STUB_SB_DIR/containers"; then
  ok "only this worktree's stack went; other projects and the shared default id keep running"; else bad "wrong containers stopped" "$(cat "$STUB_SB_DIR/containers")"; fi

echo "== the shared default id is left alone while another live worktree has it"
B="$(mkwt sb-b)"
lists $'cm:running\ncm:child sb-b'
setc "c1 shared-default" "c2 shared-default"
LOG="$ROOT/log-b"; : > "$LOG"
td "$B" STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if [ "$rc" = 0 ] && has "WARNING stack shared-default (2 containers) NOT stopped" && has "live worktree(s) main "; then ok "warns, names the live worktree that shares the id"; else bad "shared id warning" "$OUT"; fi
if ! grep -q '^supabase stop' "$LOG" && grep -q '^orca worktree rm' "$LOG"; then ok "no stop, the teardown still completes"; else bad "shared id was stopped or teardown stopped" "$(cat "$LOG")"; fi
setc "c1 dup-id"
C1="$(mkwt sb-c1 dup-id)"; mkwt sb-c2 dup-id >/dev/null
lists $'cm:running\ncm:child sb-c1'
td "$C1" STUB_PS_EXTRA="$MAIN_ROW"
if [ "$rc" = 0 ] && has "NOT stopped" && has "sb-c2"; then ok "a non-default id shared by two worktrees is not stopped either"; else bad "dup id" "$OUT"; fi

echo "== a mount inside this worktree never overrides a shared id"
D="$(mkwt sb-d)"
lists $'cm:running\ncm:child sb-d'
setc "c1 shared-default" "c2 shared-default"
setm "c1 $D/supabase"
LOG="$ROOT/log-d"; : > "$LOG"
td "$D" STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if [ "$rc" = 0 ] && has "NOT stopped" && has "does not override" && ! grep -q '^supabase stop' "$LOG"; then ok "shared id with a mount in this worktree: warned, left running"; else bad "mount vs shared id" "$OUT"; fi
echo "== a mount inside this worktree proves ownership of an unshared id"
D2="$(mkwt sb-d2)"
lists $'cm:running\ncm:child sb-d2'
setc "c1 mountonly-1" "c2 mountonly-1"
setm "c1 $D2/supabase"
LOG="$ROOT/log-d2"; : > "$LOG"
td "$D2" STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if [ "$rc" = 0 ] && has "a mount is inside this worktree" && grep -q '^supabase stop mountonly-1' "$LOG"; then ok "unshared id proven by a mount: stopped"; else bad "mount proof" "$OUT"; fi
if ! has "still has running containers"; then ok "a clean stop prints no leftover warning"; else bad "false leftover warning" "$OUT"; fi
echo "== a stop that exits 0 but leaves containers running is reported"
D4="$(mkwt sb-d4)"
lists $'cm:running\ncm:child sb-d4'
setc "c1 mountonly-4"
setm "c1 $D4/supabase"
LOG="$ROOT/log-d4"; : > "$LOG"
td "$D4" STUB_LOG="$LOG" STUB_SUPABASE_KEEP=1 STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if has "WARNING supabase stack mountonly-4 still has running containers"; then ok "after-stop check reports containers still running"; else bad "after-stop check" "$OUT"; fi
echo "== a failed git worktree list is a partial view: left running"
mkdir -p "$ROOT/bin-gitfail"
printf '#!/bin/sh\ncase "$*" in *"worktree list"*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$ROOT/bin-gitfail/git"; chmod +x "$ROOT/bin-gitfail/git"
G4="$(mkwt sb-g4 sbuniq-g4)"
lists $'cm:running\ncm:child sb-g4'
setc "c1 sbuniq-g4"
LOG="$ROOT/log-g4"; : > "$LOG"
td "$G4" STUB_LOG="$LOG" PATH="$ROOT/bin-gitfail:$PATH" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if has "NOT stopped" && has "cut off" && ! grep -q '^supabase stop' "$LOG"; then ok "git worktree list failed: the stack is left running"; else bad "git list failure" "$OUT"; fi

echo "== a worktree with no project_id does not own a stack with an empty id label"
E0="$(mkwt sb-e0)"
git -C "$E0" rm -q supabase/config.toml && git -C "$E0" commit -qm "no config" --no-gpg-sign && git -C "$E0" push -q origin b-sb-e0 >/dev/null 2>&1
lists $'cm:running\ncm:child sb-e0'
setc "c1 "
LOG="$ROOT/log-e0"; : > "$LOG"
td "$E0" STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if ! has "is not a plain project id" && ! grep -q '^supabase stop' "$LOG"; then ok "empty id label is not attributed to a worktree without a project_id"; else bad "empty id label" "$OUT"; fi

echo "== a mount inside this worktree never overrides a cut-off worktree list"
D3="$(mkwt sb-d3)"
lists $'cm:running\ncm:child sb-d3'
setc "c1 mountonly-3"
setm "c1 $D3/supabase"
LOG="$ROOT/log-d3"; : > "$LOG"
td "$D3" STUB_LOG="$LOG" STUB_PS_TRUNC=1 -- --apply
if [ "$rc" = 3 ] && has "NOT stopped" && has "cut off" && ! grep -q '^supabase stop' "$LOG"; then ok "cut-off list with a mount: left running"; else bad "mount vs cut-off" "$OUT"; fi
echo "== the mount match is on a path boundary"
E="$(mkwt sb-e)"
lists $'cm:running\ncm:child sb-e'
setc "c1 shared-default"
setm "c1 ${E}-bar/supabase"
LOG="$ROOT/log-e"; : > "$LOG"
td "$E" STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if [ "$rc" = 0 ] && has "NOT stopped" && ! grep -q '^supabase stop' "$LOG"; then ok "a mount in <worktree>-bar does not prove <worktree>"; else bad "boundary" "$OUT"; fi

echo "== a cut-off worktree list never proves an id unshared"
F="$(mkwt sb-f sbuniq-f)"
lists $'cm:running\ncm:child sb-f'
setc "c1 sbuniq-f"
td "$F" STUB_PS_TRUNC=1
# A cut-off list also makes lead mode refuse the teardown (rc 3, nothing removed): the stack is warned about and left running.
if [ "$rc" = 3 ] && has "NOT stopped" && has "cut off"; then ok "truncated worktree list: warned, left running"; else bad "truncated list" "$OUT"; fi

echo "== totalCount above the rows listed is a cut-off list too (no truncated flag)"
F2="$(mkwt sb-f2 sbuniq-f2)"
lists $'cm:running\ncm:child sb-f2'
setc "c1 sbuniq-f2"
td "$F2" STUB_PS_TRUNC=2
if [ "$rc" = 3 ] && has "NOT stopped" && has "cut off"; then ok "totalCount beyond the rows: treated as cut off, left running"; else bad "totalCount cut-off" "$OUT"; fi

echo "== a single-quoted project_id in config.toml is read"
F3="$(mkwt sb-f3)"
printf "project_id = 'sbuniq-f3'\n" > "$F3/supabase/config.toml"
git -C "$F3" add supabase/config.toml && git -C "$F3" commit -qm "id single" --no-gpg-sign && git -C "$F3" push -q origin b-sb-f3 >/dev/null 2>&1
lists $'cm:running\ncm:child sb-f3'
setc "c1 sbuniq-f3"
td "$F3" STUB_PS_EXTRA="$MAIN_ROW"
if [ "$rc" = 0 ] && has "supabase stop --project-id sbuniq-f3"; then ok "single-quoted id: the stack is attributed and planned for stop"; else bad "single-quoted id" "$OUT"; fi

echo "== no docker, or no answer from it, is a warning and not a failure"
G="$(mkwt sb-g sbuniq-g)"
lists $'cm:running\ncm:child sb-g'
setc "c1 sbuniq-g"
LOG="$ROOT/log-g"; : > "$LOG"
OUT="$(env PATH="$ROOT/binmin" ORCA_CLI_COMMAND="$ROOT/bin/orca-stub" STUB_LOG="$LOG" STUB_PATH="$G" STUB_NAME=sb-g STUB_PS_EXTRA="$MAIN_ROW" "$TD" local "$G" --owner lane-a --apply 2>&1)"; rc=$?
if [ "$rc" = 0 ] && has "WARNING docker is not installed" && grep -q '^orca worktree rm' "$LOG" && ! grep -q '^supabase stop' "$LOG"; then ok "docker missing: warns, teardown completes"; else bad "no docker" "$OUT"; fi
H="$(mkwt sb-h sbuniq-h)"
lists $'cm:running\ncm:child sb-h'
LOG="$ROOT/log-h"; : > "$LOG"
td "$H" STUB_DOCKER_DOWN=1 STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if [ "$rc" = 0 ] && has "WARNING docker did not answer" && grep -q '^orca worktree rm' "$LOG"; then ok "docker unreachable: warns, teardown completes"; else bad "docker down" "$OUT"; fi

echo "== no supabase CLI on the host: warned, stack left running"
G2="$(mkwt sb-g2 sbuniq-g2)"
mkdir -p "$ROOT/bincli"
for t in env bash sh git jq sed awk tr cut head tail sort uniq cat date mkdir dirname basename readlink realpath printf grep sleep ps wc \
         chmod ls find expr xargs timeout diff cp mv touch tee hostname uname id ssh column yq mktemp rm python3 perl; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$ROOT/bincli/$t"
done
for t in gh orca-stub docker; do ln -sf "$ROOT/bin/$t" "$ROOT/bincli/$t"; done
lists $'cm:running\ncm:child sb-g2'
setc "c1 sbuniq-g2"
OUT="$(env PATH="$ROOT/bincli" ORCA_CLI_COMMAND="$ROOT/bin/orca-stub" STUB_PATH="$G2" STUB_NAME=sb-g2 STUB_PS_EXTRA="$MAIN_ROW" "$TD" local "$G2" --owner lane-a 2>&1)"; rc=$?
if [ "$rc" = 0 ] && has "the supabase CLI is not on local: left running" && ! has "supabase stop --project-id"; then ok "no CLI: warns, plans no stop, teardown not refused"; else bad "no supabase CLI" "$OUT"; fi

echo "== a failed stop is a warning and the teardown goes on"
I="$(mkwt sb-i sbuniq-i)"
lists $'cm:running\ncm:child sb-i'
setc "c1 sbuniq-i"
LOG="$ROOT/log-i"; : > "$LOG"
td "$I" STUB_SUPABASE_FAIL=1 STUB_LOG="$LOG" STUB_PS_EXTRA="$MAIN_ROW" -- --apply
if [ "$rc" = 0 ] && has "may still be running" && grep -q '^orca worktree rm' "$LOG"; then ok "stop failure: warned, worktree still removed"; else bad "stop failure" "$OUT"; fi

echo "== no stack for this worktree"
J="$(mkwt sb-j sbuniq-j)"
lists $'cm:running\ncm:child sb-j'
setc "c1 other-proj"
td "$J" STUB_PS_EXTRA="$MAIN_ROW"
if [ "$rc" = 0 ] && has "no running Supabase stack for this worktree"; then ok "says so, touches nothing"; else bad "no stack" "$OUT"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
