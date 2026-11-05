#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# teardown-gates.sh: behaviour tests for teardown.sh's ledger, standing, beads and follow-up
# gates. Builds a throwaway repo whose origin is a local bare repo (so
# `git fetch` is real), linked worktrees, a ledger, and stubs for orca, gh and
# bd, then dry-runs teardown.sh per case and checks the exit code and output.
# Nothing outside a mktemp dir is touched. --apply runs only in the "apply"
# section, against sandbox worktrees, with HOME and CM_HOME inside the dir.
#
#   scripts/test/teardown-gates.sh            # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Hermetic config: never the project config.yaml next to scripts/.
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE
TD="$HERE/../teardown.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-gates.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; [ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/cmhome"
mkdir -p "$CM_HOME" "$ROOT/bin"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CM_BD_CMD=cm-no-such-bd
export MC_TOKEN_FILE="$ROOT/no-mc-token" MC_QUIET=1

# origin: a bare repo at a path that reads as a AcmeOrg GitHub repo.
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
{"id":"t-ep1.3","status":"in_progress","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-ep2","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-ep2.1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-ep2.2","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-par","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-kid-a","status":"closed","updated_at":"2026-10-01T00:00:00Z","dependencies":[{"issue_id":"t-kid-a","depends_on_id":"t-par","type":"parent-child"}]}
{"id":"t-kid-b","status":"open","updated_at":"2026-10-01T00:00:00Z","dependencies":[{"issue_id":"t-kid-b","depends_on_id":"t-par","type":"parent-child"}]}
{"id":"t-par2","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-mid","status":"closed","updated_at":"2026-10-01T00:00:00Z","dependencies":[{"issue_id":"t-mid","depends_on_id":"t-par2","type":"parent-child"}]}
{"id":"t-mid.1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-grand","status":"open","updated_at":"2026-10-01T00:00:00Z","dependencies":[{"issue_id":"t-grand","depends_on_id":"t-mid.1","type":"parent-child"}]}
{"id":"t-blk","status":"open","updated_at":"2026-10-01T00:00:00Z","dependencies":[{"issue_id":"t-blk","depends_on_id":"t-par3","type":"blocks"}]}
{"id":"t-par3","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-par4","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-par4.1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-par4.2","status":"tombstone","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-def","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-def.1","status":"deferred","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-tz","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-tz.1","status":"open","updated_at":"2026-10-05T05:00:00.123456Z"}
{"id":"t-late","status":"open","updated_at":"2026-10-01T00:00:00Z"}
{"id":"t-late.1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}
J
# The real repo ignores .beads/redirect (it is per-worktree); so does this one.
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
# wtcommit <wt>: commit the worktree's beads file and push the branch.
wtcommit() {
  git -C "$1" add .beads/issues.jsonl && git -C "$1" commit -qm beads --no-gpg-sign && git -C "$1" push -q origin HEAD >/dev/null 2>&1
}
# tbead <wt>: commit and push a tracked change under .beads (a closed bead: no open work). A worktree
# that never changed a tracked bead file is excused when bd cannot read its store (gap a); one that
# did is not, so the older-schema refusal cases below need this.
tbead() { printf '{"id":"t-tb-%s","status":"closed","updated_at":"2026-10-20T00:00:00Z"}\n' "${1##*/}" >> "$1/.beads/issues.jsonl"; wtcommit "$1"; }
# chmod-based cases mean nothing as root (permissions are ignored): skip them.
AS_ROOT=0; [ "$(id -u)" = 0 ] && AS_ROOT=1
skip() { printf 'SKIP %s (running as root)\n' "$1"; }
cat > "$ROOT/bin/gh" <<G
#!/usr/bin/env bash
# STUB_GH=none: the branch has no PR at all; default MERGED
if [ "\${STUB_GH:-}" = none ]; then echo '[]'; else echo '[{"number":1,"state":"MERGED","headRefOid":"$SHA"}]'; fi
G
cat > "$ROOT/bin/orca-stub" <<'O'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree ps") [ "${STUB_ORCA_NONE:-0}" = 1 ] && { echo '{"result":{"worktrees":[]}}'; exit 0; }
    jq -cn --arg p "$STUB_PATH" --arg n "${STUB_NAME:-x}" --arg id "${STUB_WID:-r::x}" --arg c "${STUB_COMMENT:-}" \
    '{result:{worktrees:[{path:$p,worktreeId:$id,displayName:$n,comment:$c,status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}]}}' ;;
  # STUB_TERM_FILE present = one live claude terminal; close removes it
  # unless STUB_TERM_STICKY=1. Closes are logged to STUB_BD_LOG for ordering.
  "terminal list") if [ -n "${STUB_TERM_FILE:-}" ] && [ -e "$STUB_TERM_FILE" ]; then
      echo '{"result":{"terminals":[{"handle":"term_a","agentIdentity":"claude"}]}}'
    else echo '{"result":{"terminals":[]}}'; fi ;;
  "terminal close") printf 'orca|terminal close %s\n' "$4" >> "${STUB_BD_LOG:-/dev/null}"
    [ "${STUB_TERM_STICKY:-0}" = 1 ] || rm -f "${STUB_TERM_FILE:-/nonexistent}" ;;
  # Orca without --force: a plain git worktree remove, which refuses untracked files.
  "worktree rm") [ -n "${STUB_ORCA_RM_MAIN:-}" ] || exit 0
    exec git -C "$STUB_ORCA_RM_MAIN" worktree remove "$STUB_PATH" ;;
esac
O
cat > "$ROOT/bin/bd-stub" <<'B'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "${STUB_BD_LOG:-/dev/null}"
# A call against the COPY teardown makes of a store it cannot read ("-C <CM_HOME>/tmp/beads-copy.XXXXXX"):
# STUB_COPY_MIGRATE_FAIL=1 fails the migrate, STUB_COPY_LIST_FAIL=1 fails the list, STUB_COPY_LIST is the
# list JSON (default: an empty array). The migrate drops a marker in the copy, never anywhere else.
case "$*" in *"/tmp/beads-copy."*)
  [ -z "${STUB_COPY_ENV_LOG:-}" ] || printf '%s\n' "BEADS_DOLT_DATA_DIR=${BEADS_DOLT_DATA_DIR:-unset} BEADS_DIR=${BEADS_DIR:-unset}" >> "$STUB_COPY_ENV_LOG"
  [ -z "${STUB_COPY_HOME_LOG:-}" ] || printf '%s\n' "HOME=$HOME XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-unset}" >> "$STUB_COPY_HOME_LOG"
  case " $* " in
    *" dolt commit"*) exit 0 ;;
    *" where "*)
      a="$*"; d="${a#*-C }"; d="${d%% *}"
      if [ -n "${STUB_COPY_WHERE_OUTSIDE:-}" ]; then printf '{"path":"%s","database_path":"%s"}\n' "$STUB_COPY_WHERE_OUTSIDE" "$STUB_COPY_WHERE_OUTSIDE/embeddeddolt"
      else printf '{"path":"%s/.beads","database_path":"%s/.beads/embeddeddolt"}\n' "$d" "$d"; fi
      exit 0 ;;
    *" migrate schema"*)
      if [ "${STUB_COPY_NEWDB:-0}" = 1 ]; then a="$*"; d="${a#*-C }"; d="${d%% *}"; mkdir -p "$d/.beads/embeddeddolt/freshdb"; fi
      if [ "${STUB_COPY_MIGRATE_FAIL:-0}" = 1 ]; then echo 'Error: migrate schema failed on the copy' >&2; exit 1; fi
      [ "${STUB_COPY_SERVER:-0}" != 1 ] || echo 'Using the shared server for this run' >&2
      a="$*"; d="${a#*-C }"; d="${d%% *}"; : > "$d/.beads/migrated"; exit 0 ;;
    *" list "*)
      if [ "${STUB_COPY_LIST_FAIL:-0}" = 1 ]; then echo 'Error: list failed on the copy' >&2; exit 1; fi
      # STUB_COPY_IMPORT=1: like bd, import the copy's issues.jsonl on first use (two open beads) when it has content
      a="$*"; d="${a#*-C }"; d="${d%% *}"
      if [ "${STUB_COPY_IMPORT:-0}" = 1 ] && [ -s "$d/.beads/issues.jsonl" ]; then echo '[{"id":"t-i1","status":"open"},{"id":"t-i2","status":"open"}]'; exit 0; fi
      printf '%s\n' "${STUB_COPY_LIST-[]}"; exit 0 ;;
  esac ;;
esac
case " $* " in *" where "*) [ -n "${STUB_BD_WHERE:-}" ] || exit 1; printf '%s\n' "$STUB_BD_WHERE"; exit 0 ;; esac
[ -n "${STUB_BD_SLEEP:-}" ] && sleep "$STUB_BD_SLEEP"
if [ -n "${STUB_BD_ERR:-}" ]; then printf 'Warning: noise\n%s\n' "$STUB_BD_ERR" >&2; exit 1; fi
[ "${STUB_BD_FAIL:-0}" = 1 ] && exit 1
cat "${STUB_BD_JSON:-/dev/null}"
B
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca-stub" "$ROOT/bin/bd-stub"
export PATH="$ROOT/bin:$PATH" ORCA_CLI_COMMAND="$ROOT/bin/orca-stub"

ledger() { printf '%s' "$1" > "$CM_HOME/ledger.json"; }
# w <path> [extra json fields]: a ledger worker on host local.
w() { printf '{"host":"local","path":"%s"%s}' "$1" "${2:+,$2}"; }
# one <path> [fields]: a ledger with exactly one worker w-a.
one() { ledger "{\"workers\":{\"w-a\":$(w "$1" "${2:-}")}}"; }

PASS=0; FAIL=0
run() { # run <label> <expect-exit> <grep-pattern> <path> [args...]
  local label="$1" want="$2" pat="$3" p="$4" out rc
  shift 4
  out="$(STUB_PATH="$p" "$TD" local "$p" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && grep -q -- "$pat" <<<"$out"; then
    PASS=$((PASS + 1)); printf 'PASS %-58s rc=%s\n' "$label" "$rc"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %-58s rc=%s want=%s\n%s\n' "$label" "$rc" "$want" "$out"
  fi
}

W1="$(mkwt deploy-1)"; W2="$(mkwt research-demos-2)"; W3="$(mkwt ops-a)"
W4="$(mkwt pr-sweeper)"; W5="$(mkwt ops-b)"; W6="$(mkwt ops-c)"; W7="$(mkwt ops-d)"
W8="$(mkwt ops-e)"; W9="$(mkwt ops-f)"; W10="$(mkwt ops-g)"; W11="$(mkwt ops-h)"
W12="$(mkwt ops-i)"; W13="$(mkwt ops-j)"; W14="$(mkwt ops-k)"
W15="$(mkwt ops-l)"; W16="$(mkwt ops-m)"; W17="$(mkwt ops-n)"; W18="$(mkwt ops-o)"
W19="$(mkwt ops-p)"; W20="$(mkwt ops-q)"

echo "== ledger: fail closed"
rm -f "$CM_HOME/ledger.json"
run "ledger missing"                                       3 'ledger missing or empty' "$W1"
: > "$CM_HOME/ledger.json"
run "ledger empty file"                                    3 'ledger missing or empty' "$W1"
run "ledger missing: points a lead at lead mode"           3 'teardown.sh local .* --owner <your-worktree>' "$W1"
run "ledger missing: cm:retire is only the fallback"       3 'cm:retire on the child' "$W1"
run "ledger missing: says not to build a ledger here"      3 'do not copy or build one here' "$W1"
ledger '{}'
run "ledger {}"                                            3 'malformed' "$W1"
ledger '{"workers":null}'
run "ledger workers:null"                                  3 'malformed' "$W1"
ledger 'null'
run "ledger null"                                          3 'malformed' "$W1"
ledger '{not json'
run "ledger not json"                                      3 'malformed' "$W1"
printf '%s\n%s\n' "{\"workers\":{\"w-a\":$(w "$W1" '"standing":false')}}" '{"workers":{}}' > "$CM_HOME/ledger.json"
run "two-document ledger"                                  3 'malformed' "$W1"
run "--no-ledger is gone"                                  2 'unknown arg' "$W1" --no-ledger
ledger '{"workers":{}}'
run "no ledger worker for the path"                        3 'standing state unknown: no live ledger worker' "$W1"
ledger "{\"workers\":{\"w-a\":{\"host\":\"remote-1\",\"path\":\"$W1\",\"standing\":false}}}"
run "worker on another host does not match"                3 'no live ledger worker' "$W1"

echo "== standing: ledger only"
one "$W1" '"standing":false'
run "standing:false single-task worker: clean"            0 'single-task worker' "$W1"
one "$W1" '"standing":true'
run "standing:true refuses"                                3 'standing lane (ledger standing:true' "$W1"
one "$W1" '"standing":null'
run "standing:null refuses as unknown"                     3 'standing state unknown on ledger worker(s) w-a' "$W1"
one "$W1"
run "standing missing refuses as unknown"                  3 'standing state unknown' "$W1"
one "$W1" '"standing":"yes"'
run "standing non-boolean refuses as unknown"              3 'standing state unknown' "$W1"
one "$W4" '"standing":false'
STUB_NAME=pr-sweeper run "sweeper name + standing:false: ledger wins" 0 'name looks like a lane, ledger wins' "$W4"
# the folder is ops-b, so only the display name (STUB_NAME) carries the shape under test
one "$W5" '"standing":false'
STUB_NAME=release-sweeper-host-a run "release-sweeper-style name + standing:false: noted as lane-shaped" 0 'name looks like a lane, ledger wins' "$W5"
STUB_NAME=research-notes run "research-<slug> + standing:false: a single-task worker, no lane note" 0 'ledger standing:false, single-task worker' "$W5"
STUB_NAME=sweep-101 run "sweep-<pr> + standing:false: a single-task worker, no lane note" 0 'ledger standing:false, single-task worker' "$W5"
one "$W2" '"standing":true'
STUB_NAME=feature-demo-sweeper run "incident shape: standing:true refuses" 3 'standing lane' "$W2"
ledger "{\"lanes\":{\"dev-sweeper\":{\"lead\":\"w-a\"}},\"workers\":{\"w-a\":$(w "$W1" '"standing":false')}}"
run "lane lead refuses even with standing:false"           3 'ledger lane lead w-a' "$W1"
ledger "{\"workers\":{\"w-x\":$(w "$W1" '"standing":false'),\"w-y\":$(w "$W1" '"standing":null')}}"
run "two live workers, one unknown: refuses"               3 'standing state unknown on ledger worker(s) w-y' "$W1"
ledger "{\"workers\":{\"w-old\":$(w "$W1" '"standing":true,"state":"gone","beadsEpic":"t-ep1"'),\"w-new\":$(w "$W1" '"standing":false')}}"
run "gone record on a reused path is ignored"              0 'live worker(s) w-new' "$W1"
ledger "{\"workers\":{\"w-old\":$(w "$W1" '"standing":false,"state":"repurposed"')}}"
run "only a repurposed record: unknown"                    3 'no live ledger worker' "$W1"
ledger "{\"workers\":{\"w-a\":{\"host\":\"local\",\"path\":\"/elsewhere\",\"worktreeId\":\"repo::wt-9\",\"standing\":true}}}"
STUB_WID=repo::wt-9 run "match by Orca worktreeId when paths differ" 3 'standing lane (ledger standing:true' "$W1"

echo "== --force-standing: structured, bound ask"
ask() { # ask <json fields>: ledger with worker w-a (standing true) on W2 and one ask
  ledger "{\"asks\":[{\"id\":\"ask-1\",\"state\":\"answered\",$1}],\"workers\":{\"w-a\":$(w "$W2" '"standing":true')}}"; }
ask "\"kind\":\"remove-standing\",\"decision\":\"approved\",\"host\":\"local\",\"path\":\"$W2\""
run "approved remove-standing for this path"              0 'Owner approved in ask ask-1' "$W2" --force-standing ask-1
ask "\"kind\":\"remove-standing\",\"decision\":\"approved\",\"host\":\"local\",\"worker\":\"w-a\""
run "approved remove-standing naming the worker"          0 'Owner approved in ask ask-1' "$W2" --force-standing ask-1
ask "\"kind\":\"remove-standing\",\"decision\":\"declined\",\"host\":\"local\",\"path\":\"$W2\""
run "declined ask refuses"                                 3 'not an unused, approved remove-standing ask' "$W2" --force-standing ask-1
ask "\"topic\":\"kill list\",\"answer\":\"approve all\""
run "unrelated answered ask refuses"                       3 'not an unused, approved' "$W2" --force-standing ask-1
ask "\"kind\":\"remove-standing\",\"decision\":\"approved\",\"host\":\"local\",\"path\":\"$W3\""
run "ask for another path refuses"                         3 'not an unused, approved' "$W2" --force-standing ask-1
ask "\"kind\":\"remove-standing\",\"decision\":\"approved\",\"host\":\"remote-1\",\"path\":\"$W2\""
run "ask for another host refuses"                         3 'not an unused, approved' "$W2" --force-standing ask-1
ask "\"kind\":\"remove-standing\",\"decision\":\"approved\",\"host\":\"local\",\"path\":\"$W2\",\"usedAt\":\"2026-10-10T09:00:00Z\""
run "used ask refuses (single use)"                        3 'not an unused, approved' "$W2" --force-standing ask-1
run "--force-standing needs an id"                         2 'Exit: 0 plan ok' "$W2" --force-standing

echo "== beads gate: epic"
ep() { one "$1" "\"standing\":false,\"beadsEpic\":\"$2\""; }
ep "$W3" t-ep1;   run "dotted children, 2 open"                   3 '2 open bead(s) under epic t-ep1' "$W3"
ep "$W3" t-par;   run "parent-linked open child (bd --parent)"   3 '1 open bead(s) under epic t-par' "$W3"
ep "$W3" t-par2;  run "grandchild via parent link and dotted id" 3 'open under t-par2 .*t-grand' "$W3"
ep "$W3" t-par3;  run "open epic with only a blocks dep"         3 'no children found' "$W3"
ep "$W3" t-par4;  run "tombstone child counts as closed"         0 'all 2 closed under t-par4' "$W3"
ep "$W3" t-def;   run "deferred child counts as open"            3 '1 open bead(s) under epic t-def' "$W3"
ep "$W3" nope-zz; run "epic found nowhere"                       3 'not found in any beads source' "$W3"
ep "$W3" 't-ep1; rm -rf /'; run "invalid epic id never executed" 3 'is not a bead id' "$W3"
one "$W3" '"standing":false,"beadsEpic":42'
run "non-string beadsEpic refuses"                         3 'beadsEpic on w-a is not a bead id' "$W3"
one "$W3" '"standing":false,"epicConflict":["t-ep1","t-par"]'
run "a recorded epic conflict refuses teardown"            3 'declare different epic= ids for w-a' "$W3"
one "$W3" '"standing":false,"epicConflict":[]'
run "an empty epicConflict does not block"                 0 'dry-run: nothing changed' "$W3"
ledger "{\"workers\":{\"w-a\":$(w "$W3" '"standing":false,"beadsEpic":"t-ep1"'),\"w-b\":$(w "$W3" '"standing":false,"beadsEpic":"t-par"')}}"
run "two workers: epics unioned"                           3 'under epic t-par:' "$W3"
ledger "{\"asks\":[{\"id\":\"ask-1\",\"state\":\"answered\",\"kind\":\"remove-standing\",\"decision\":\"approved\",\"host\":\"local\",\"path\":\"$W3\"}],\"workers\":{\"w-a\":$(w "$W3" '"standing":true,"beadsEpic":"t-ep1"')}}"
run "--force-standing never overrides beads"              3 '2 open bead(s)' "$W3" --force-standing ask-1
# branch closes t-ep2.2 with a newer timestamp: latest record wins
sed 's/"id":"t-ep2.2","status":"open","updated_at":"2026-10-01T00:00:00Z"/"id":"t-ep2.2","status":"closed","updated_at":"2026-10-05T00:00:00+00:00"/' \
  "$M/.beads/issues.jsonl" > "$W5/.beads/issues.jsonl"; wtcommit "$W5"
ep "$W5" t-ep2;   run "closed on branch with newer record: clean" 0 'all 2 closed under t-ep2' "$W5"
# +05:30: 10:00+05:30 is 04:30Z, older than the open 05:00Z record on main
sed 's/"id":"t-tz.1","status":"open","updated_at":"2026-10-05T05:00:00.123456Z"/"id":"t-tz.1","status":"closed","updated_at":"2026-10-05T10:00:00+05:30"/' \
  "$M/.beads/issues.jsonl" > "$W6/.beads/issues.jsonl"; wtcommit "$W6"
ep "$W6" t-tz;    run "mixed offsets compared as epoch, not text" 3 '1 open bead(s) under epic t-tz' "$W6"
one "$W3" '"standing":false,"beadsEpic":""'
run "empty-string beadsEpic refuses"                       3 'beadsEpic on w-a is not a bead id' "$W3"
if [ "$AS_ROOT" = 0 ]; then
  chmod 000 "$W7/.beads/issues.jsonl"
  ep "$W7" t-ep2; run "worktree beads file unreadable"           3 'source failed' "$W7"
  chmod 644 "$W7/.beads/issues.jsonl"; chmod 000 "$W7/.beads"
  ep "$W7" t-ep2; run "worktree .beads dir unreadable"           3 'worktree:failed' "$W7"
  chmod 755 "$W7/.beads"
else
  skip "worktree beads file unreadable"; skip "worktree .beads dir unreadable"
fi

echo "== beads gate: live sources"
# A child opened on origin after this worktree last fetched: the gate fetches.
C="$ROOT/clone"; git clone -q "$BARE" "$C"
printf '%s\n' '{"id":"t-late.2","status":"open","updated_at":"2026-10-09T00:00:00Z"}' >> "$C/.beads/issues.jsonl"
git -C "$C" commit -qam late --no-gpg-sign && git -C "$C" push -q origin main
ep "$W8" t-late;  run "new open child on origin is fetched"      3 '1 of 2 open under t-late .*t-late.2' "$W8"
if [ "$AS_ROOT" = 0 ]; then
  chmod 000 "$BARE"
  ep "$W8" t-late; run "fetch failure refuses"                   3 'fetch:failed' "$W8"
  chmod 755 "$BARE"
else
  skip "fetch failure refuses"
fi
# origin/HEAD naming a dash-prefixed "branch": must never reach git as an option.
printf '#!/bin/sh\ntouch "%s"\n' "$ROOT/pwned" > "$ROOT/pwn.sh"; chmod +x "$ROOT/pwn.sh"
git -C "$M" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/--upload-pack=$ROOT/pwn.sh"
ep "$W8" t-late;  run "origin/HEAD option injection refused"     3 'invalid branch name' "$W8"
if [ -e "$ROOT/pwned" ]; then FAIL=$((FAIL + 1)); echo "FAIL origin/HEAD payload ran"
else PASS=$((PASS + 1)); echo "PASS origin/HEAD payload never ran"; fi
git -C "$M" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

# The live working copy of the main checkout (what a redirect points at).
printf '%s\n' '{"id":"t-ep2.2","status":"closed","updated_at":"2026-10-06T00:00:00Z"}' \
  '{"id":"t-ep2.3","status":"open","updated_at":"2026-10-06T00:00:00Z"}' \
  '{"id":"t-new","status":"open","updated_at":"2026-10-09T00:00:00Z"}' >> "$M/.beads/issues.jsonl"
printf '[]' > "$ROOT/bd-empty.json"
printf '# live beads\n%s\n' "$M/.beads" > "$W9/.beads/redirect"
ep "$W9" t-ep2
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" run "redirect to main checkout: its open child counts" 3 'open under t-ep2 .*t-ep2.3' "$W9"
run "redirect present but bd missing refuses"              3 'bd:failed-missing-with-redirect' "$W9"
mkdir -p "$ROOT/live/.beads"
printf '%s\n' '{"id":"t-ep2.2","status":"closed","updated_at":"2099-01-01T00:00:00Z"}' > "$ROOT/live/.beads/issues.jsonl"
printf '%s\n' "$ROOT/live/.beads" > "$W9/.beads/redirect"
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" run "redirect outside the main checkout refuses" 3 'redirect:failed-outside-main-checkout' "$W9"
printf '%s\n' ".beads" > "$W9/.beads/redirect"
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" run "redirect to the worktree's own .beads refuses" 3 'redirect:failed-outside-main-checkout' "$W9"
printf '%s\n' "../../no-such/.beads" > "$W9/.beads/redirect"
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" run "redirect target missing refuses" 3 'redirect:failed' "$W9"
rm -f "$W9/.beads/redirect"
# bd, when installed: read-only, from /, pointed at the worktree with -C
printf '[{"id":"t-ep2.2","status":"closed","updated_at":"2026-10-07T00:00:00Z"},{"id":"t-ep2.9","status":"open","updated_at":"2026-10-07T00:00:00Z"}]' > "$ROOT/bd.json"
ep "$W9" t-ep2
: > "$ROOT/bd.log"
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd.json" STUB_BD_LOG="$ROOT/bd.log" run "bd reports an open child" 3 'open under t-ep2 .*t-ep2.9' "$W9"
if [ "$(cat "$ROOT/bd.log")" = "/|-C $W9 --readonly --sandbox list --all --limit 0 --json" ]; then
  PASS=$((PASS + 1)); echo "PASS bd ran read-only from / with -C <worktree>"
else
  FAIL=$((FAIL + 1)); echo "FAIL bd invocation: $(cat "$ROOT/bd.log")"
fi
if ! git -C "$W9" status --porcelain --ignored -- .beads | grep -v '^!! .beads/redirect$' | grep -q .; then
  PASS=$((PASS + 1)); echo "PASS dry run left the worktree .beads untouched"
else
  FAIL=$((FAIL + 1)); echo "FAIL dry run changed $W9/.beads"
fi
CM_BD_CMD=bd-stub STUB_BD_FAIL=1 run "bd installed but failing refuses"                3 'bd:failed' "$W9"
printf '[{"id":"t-ep2.2","status":"closed","updated_at":"2026-10-07T00:00:00Z"}]' > "$ROOT/bd.json"
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd.json" run "bd closes the last child: clean" 0 'all 2 closed under t-ep2' "$W9"

echo "== beads gate: no epic"
one "$W1" '"standing":false'
run "no epic, worktree matches origin: clean"              0 'no unmerged open beads' "$W1"
printf '%s\n' '{"id":"t-new","status":"open","updated_at":"2026-10-09T00:00:00Z"}' >> "$W10/.beads/issues.jsonl"; wtcommit "$W10"
one "$W10" '"standing":false'
run "no epic, open bead only on this branch"               3 'unmerged bead work' "$W10"
ledger "{\"asks\":[{\"id\":\"ask-2\",\"state\":\"answered\",\"kind\":\"accept-unmerged-beads\",\"decision\":\"approved\",\"host\":\"local\",\"path\":\"$W10\"}],\"workers\":{\"w-a\":$(w "$W10" '"standing":false')}}"
run "accept-unmerged-beads ask allows it"                  0 'accepted in ask ask-2' "$W10" --accept-unmerged-beads ask-2
ledger "{\"asks\":[{\"id\":\"ask-3\",\"state\":\"answered\",\"kind\":\"remove-standing\",\"decision\":\"approved\",\"host\":\"local\",\"path\":\"$W10\"}],\"workers\":{\"w-a\":$(w "$W10" '"standing":false')}}"
run "remove-standing ask cannot stand in for it"           3 'not an unused, approved accept-unmerged-beads' "$W10" --accept-unmerged-beads ask-3
printf '%s\n' "$M/.beads" > "$W11/.beads/redirect"
printf '%s\n' '{"id":"t-new","status":"open","updated_at":"2026-10-09T00:00:00Z"}' >> "$W11/.beads/issues.jsonl"; wtcommit "$W11"
one "$W11" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" run "no epic, bead also in the live DB: not unmerged" 0 'no unmerged open beads' "$W11" --salvage

echo "== bd runtime files"
# bdrt <wt>: the untracked files bd 1.3 leaves in a worktree (the embedded
# Dolt store, its backups and gate locks), as on branches older than the
# .gitignore entries for them.
bdrt() {
  : > "$1/.beads.gate.lock"; : > "$1/.beads/embeddeddolt.gate.lock"; : > "$1/.beads/backup.lock"; : > "$1/.beads/dolt.gate.lock"
  mkdir -p "$1/.beads/embeddeddolt/beads/.dolt" "$1/.beads/backup"
  printf '{}' > "$1/.beads/embeddeddolt/beads/.dolt/config.json"
  printf '{}\n' > "$1/.beads/backup/issues.jsonl"
}
bdrt "$W12"
one "$W12" '"standing":false'
run "only bd runtime files untracked: not dirty"          0 'untracked bd runtime only' "$W12" --salvage
run "bd runtime files still need --salvage"               3 're-run with --salvage' "$W12"
if STUB_PATH="$W12" "$TD" local "$W12" 2>&1 | grep -q 'dirty tree'; then
  FAIL=$((FAIL + 1)); echo "FAIL bd runtime files counted as dirty"
else
  PASS=$((PASS + 1)); echo "PASS bd runtime files never counted as dirty"
fi
: > "$W12/notes.txt"
run "real untracked file next to bd runtime: dirty"       3 'dirty tree (1 paths)' "$W12" --salvage
rm -f "$W12/notes.txt"; : > "$W12/.beads/embeddeddolt.gate.lock.bak"
run "near-miss bd runtime name: dirty"                    3 'dirty tree (1 paths)' "$W12" --salvage
rm -f "$W12/.beads/embeddeddolt.gate.lock.bak"
printf '%s\n' '{"id":"t-x","status":"open","updated_at":"2026-10-09T00:00:00Z"}' >> "$W12/.beads/issues.jsonl"
run "tracked beads change next to bd runtime: dirty"      3 'dirty tree (1 paths)' "$W12" --salvage
git -C "$W12" checkout -q -- .beads/issues.jsonl

echo "== bd with no database"
NODB='Error: no beads database found'
# where --json exactly as bd 1.3.1 prints it for a worktree with no store.
WHERE13="$(printf '{\n  "path": "%s/.beads",\n  "schema_version": 1\n}' "$W13")"
one "$W13" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="$WHERE13" \
  run "no database anywhere: bd absent, clean"             0 'no unmerged open beads (.*bd:absent' "$W13"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE='not json "path"' \
  run "no database, where output not JSON: refuses"        3 'bd:failed' "$W13"
# Ignored (not untracked) so the dirty gate stays out of these cases.
printf '.beads/config.yaml\n.beads/metadata.json\n' >> "$M/.git/info/exclude"
printf 'dolt.server-host: 10.0.0.9\n' >> "$W13/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="$WHERE13" \
  run "no database but config.yaml sets something: refuses" 3 'bd:failed .*may be configured' "$W13" --salvage
rm -f "$W13/.beads/config.yaml"
printf '{"database":"elsewhere.db"}' > "$W13/.beads/metadata.json"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="$WHERE13" \
  run "no database but metadata names another db: refuses" 3 'bd:failed' "$W13" --salvage
printf '{"database":"beads.db","jsonl_export":"issues.jsonl"}' > "$W13/.beads/metadata.json"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="$WHERE13" \
  run "default metadata.json: still absent"                0 'bd:absent' "$W13" --salvage
rm -f "$W13/.beads/metadata.json"
BEADS_DIR=/somewhere CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="$WHERE13" \
  run "no database but BEADS_DIR set: refuses"             3 'bd:failed' "$W13" --salvage
sed -i.bak '/^\.beads\/config\.yaml$/d; /^\.beads\/metadata\.json$/d' "$M/.git/info/exclude"; rm -f "$M/.git/info/exclude.bak"
CM_BD_SECS=1 CM_BD_CMD=bd-stub STUB_BD_SLEEP=5 STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "bd read times out: refuses, says so"                3 'bd:failed (bd said: timeout after 1s)' "$W13"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="{\"database_path\":\"$W13/.beads/embeddeddolt\",\"path\":\"$W13/.beads\"}" \
  run "no database but where names one: refuses"           3 'bd:failed' "$W13"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" \
  run "no database and where fails: refuses"               3 'bd:failed' "$W13"
mkdir -p "$W13/.beads/embeddeddolt"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="$WHERE13" \
  run "no database but a store on disk: refuses"           3 'bd:failed' "$W13" --salvage
rmdir "$W13/.beads/embeddeddolt"
printf '%s\n' "$M/.beads" > "$W13/.beads/redirect"
CM_BD_CMD=bd-stub STUB_BD_ERR="$NODB" STUB_BD_WHERE="$WHERE13" \
  run "no database behind a redirect: refuses"             3 'bd:failed-missing-with-redirect' "$W13" --salvage
rm -f "$W13/.beads/redirect"
# The deploy-20261010-1600 shape: a store --readonly cannot open. Fail closed
# and say why.
bdrt "$W14"
one "$W14" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_ERR='Error: search count issues: Error 1105: table "leases" does not have column "granted_node"' \
  run "store with pending migrations, no bead change: excused" 0 'excused, no tracked .beads change' "$W14" --salvage
ep "$W14" t-ep1
CM_BD_CMD=bd-stub STUB_BD_ERR='Error: search count issues: Error 1105: table "leases" does not have column "granted_node"' \
  run "same with an epic that has open beads: refuses"     3 '2 open bead(s) under epic t-ep1' "$W14" --salvage

echo "== bd runtime: always salvaged"
bdrt "$W15"; one "$W15" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "bd read ok, gate clean: store still needs --salvage" 3 're-run with --salvage' "$W15"
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "bd read ok, gate clean, --salvage: plan salvages it" 0 'salvage .* ignored path' "$W15" --salvage
# Ignored (new branches) is the same: still precious.
printf '.beads/embeddeddolt/\n.beads.gate.lock\n' >> "$M/.git/info/exclude"
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "ignored bd store: still needs --salvage"            3 're-run with --salvage' "$W15"
sed -i.bak '/^\.beads\/embeddeddolt\/$/d; /^\.beads\.gate\.lock$/d' "$M/.git/info/exclude"; rm -f "$M/.git/info/exclude.bak"
# The perl alarm fallback of cm_timeout (no coreutils, e.g. macOS) exits 142
# on SIGALRM; it must read as a timeout too.
mkdir -p "$ROOT/perlbin"
cat > "$ROOT/perlbin/timeout" <<'T'
#!/usr/bin/env bash
s=$1; shift
exec perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"
T
chmod +x "$ROOT/perlbin/timeout"
PATH="$ROOT/perlbin:$PATH" CM_BD_SECS=1 CM_BD_CMD=bd-stub STUB_BD_SLEEP=5 STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "perl alarm timeout (exit 142): refuses, says so"    3 'bd:failed (bd said: timeout after 1s)' "$W15" --salvage

echo "== apply (sandboxed)"
export HOME="$ROOT/home"; mkdir -p "$HOME"
exists() { # exists <label> <path> <yes|no>
  if { [ -e "$2" ] && [ "$3" = yes ]; } || { [ ! -e "$2" ] && [ "$3" = no ]; }; then
    PASS=$((PASS + 1)); echo "PASS $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $1 ($2 should exist: $3)"
  fi
}
# The premise: git refuses to remove a worktree holding untracked bd files.
bdrt "$W20"
if git -C "$M" worktree remove "$W20" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "FAIL premise: git removed a worktree with untracked files"
else
  PASS=$((PASS + 1)); echo "PASS premise: plain git worktree remove refuses untracked bd files"
fi
bdrt "$W16"; one "$W16" '"standing":false'
STUB_ORCA_NONE=1 CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "git-only, bd ok: --apply without --salvage refuses" 3 're-run with --salvage' "$W16" --apply
exists "git-only refused: bd store kept" "$W16/.beads/embeddeddolt" yes
# Orca-tracked with a live agent terminal named by --close-handle: the
# terminal closes first, then the re-run reads beads and salvages.
: > "$ROOT/term-16"; : > "$ROOT/seq.log"
STUB_TERM_FILE="$ROOT/term-16" STUB_ORCA_RM_MAIN="$M" CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" STUB_BD_LOG="$ROOT/seq.log" \
  run "agent terminal closes before the proof: --apply"   0 'done: .* torn down' "$W16" --apply --salvage --close-handle term_a
exists "agent terminal case: worktree gone" "$W16" no
if awk -F'|' '$1 == "orca" { c = NR } $2 ~ /list --all/ && c && NR > c { ok = 1 } END { exit !ok }' "$ROOT/seq.log"; then
  PASS=$((PASS + 1)); echo "PASS beads read again after the terminal closed"
else
  FAIL=$((FAIL + 1)); echo "FAIL no beads read after the terminal closed: $(tr '\n' ';' < "$ROOT/seq.log")"
fi
SALV16="$(find "$HOME/.concertmaster/salvage" -path '*b-ops-m-*/.beads/embeddeddolt' 2>/dev/null | head -n 1)"
exists "agent terminal case: store salvaged" "${SALV16:-$ROOT/none}" yes
bdrt "$W17"; one "$W17" '"standing":false'
STUB_ORCA_NONE=1 run "git-only, store kept: --apply --salvage removes it" 0 'removed untracked bd runtime files' "$W17" --apply --salvage
exists "git-only salvaged: worktree gone" "$W17" no
SALV="$(find "$HOME/.concertmaster/salvage" -path '*b-ops-n-*/.beads/embeddeddolt/beads/.dolt/config.json' 2>/dev/null | head -n 1)"
exists "git-only salvaged: store copied out first" "${SALV:-$ROOT/none}" yes
bdrt "$W18"; one "$W18" '"standing":false'
STUB_ORCA_RM_MAIN="$M" run "Orca-tracked (rm without --force): --apply --salvage" 0 'done: .* torn down' "$W18" --apply --salvage
exists "Orca-tracked: worktree gone" "$W18" no
bdrt "$W19"; : > "$W19/notes.txt"; one "$W19" '"standing":false'
STUB_ORCA_NONE=1 run "real untracked file: --apply still refuses" 3 'dirty tree (1 paths)' "$W19" --apply --salvage
exists "real untracked file: worktree kept" "$W19/notes.txt" yes
exists "real untracked file: bd store kept" "$W19/.beads/embeddeddolt" yes
rm -f "$W19/notes.txt"
# An agent terminal that survives the close: the re-run refuses, nothing removed.
: > "$ROOT/term-19"
STUB_TERM_FILE="$ROOT/term-19" STUB_TERM_STICKY=1 \
  run "terminal survives the close: re-run refuses"        3 'still open after closing' "$W19" --apply --salvage --close-handle term_a
exists "surviving terminal: worktree and store kept" "$W19/.beads/embeddeddolt" yes
rm -f "$ROOT/term-19"
# A delete that cannot finish stops loudly; the salvage is kept.
if [ "$AS_ROOT" = 0 ]; then
  chmod 555 "$W19/.beads/backup"; sleep 1
  STUB_ORCA_NONE=1 run "partial bd runtime delete: stops, salvage kept" 4 '' "$W19" --apply --salvage
  sleep 1; OUT19="$(STUB_PATH="$W19" STUB_ORCA_NONE=1 "$TD" local "$W19" --apply --salvage 2>&1)"
  if printf '%s' "$OUT19" | grep -q 'only partly removed (still present: .*\.beads/backup.*salvage kept at'; then
    PASS=$((PASS + 1)); echo "PASS partial delete names what is left and the salvage"
  else
    FAIL=$((FAIL + 1)); echo "FAIL partial delete message: $OUT19"
  fi
  exists "partial delete: worktree kept" "$W19/.beads/backup/issues.jsonl" yes
  chmod 755 "$W19/.beads/backup"
else
  skip "partial bd runtime delete"
fi

echo "== salvage verify: symlinks compare by target text, not by what they point at"
# diff -rq follows links, so a tree holding a dangling link used to fail the verify with a false
# "content mismatch" although cp copied the link correctly. A dangling link and a good link inside an
# ignored dir are salvaged and verified; a link whose target text, presence or count differs in the copy
# fails closed. The cp stub runs the real cp, then edits the copy as STUB_CP_TAMPER says.
# Each apply is spaced one second apart: the salvage dir is stamped to the second and a re-used one nests the copy.
cat > "$ROOT/bin/cp" <<'C'
#!/usr/bin/env bash
/bin/cp "$@" || exit
[ -n "${STUB_CP_TAMPER:-}" ] || exit 0
for dst; do :; done
case "$STUB_CP_TAMPER" in
  retarget:*) ln -sfn changed-target.md "$dst/${STUB_CP_TAMPER#retarget:}" ;;
  drop:*)     /bin/rm -f "$dst/${STUB_CP_TAMPER#drop:}" ;;
  add:*)      ln -s anywhere "$dst/${STUB_CP_TAMPER#add:}" ;;
esac
exit 0
C
chmod +x "$ROOT/bin/cp"
printf 'scratch-clone/\n' >> "$M/.git/info/exclude"
W31="$(mkwt salv-links)"
mkdir -p "$W31/scratch-clone/tool-b" "$W31/scratch-clone/docs"
printf 'real\n' > "$W31/scratch-clone/docs/real.md"
ln -s ../tool-a/NOTES.md "$W31/scratch-clone/tool-b/note.md"   # dangling: tool-a/ is absent from the clone
ln -s docs/real.md "$W31/scratch-clone/good.md"
mkdir -p "$ROOT/links-copy" && cp -Rp "$W31/scratch-clone" "$ROOT/links-copy/"
if diff -rq "$W31/scratch-clone" "$ROOT/links-copy/scratch-clone" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "FAIL premise: diff -rq passed a tree holding a dangling link"
else
  PASS=$((PASS + 1)); echo "PASS premise: diff -rq fails a tree holding a dangling link"
fi
one "$W31" '"standing":false'
STUB_CP_TAMPER="retarget:tool-b/note.md" STUB_ORCA_NONE=1 \
  run "link target text differs in the copy: fails closed" 4 'content mismatch on scratch-clone' "$W31" --apply --salvage
exists "retargeted link: worktree kept" "$W31/scratch-clone/docs/real.md" yes
sleep 1
STUB_CP_TAMPER="drop:good.md" STUB_ORCA_NONE=1 \
  run "link missing from the copy: fails closed" 4 'content mismatch on scratch-clone' "$W31" --apply --salvage
exists "missing link: worktree kept" "$W31/scratch-clone/docs/real.md" yes
sleep 1
STUB_CP_TAMPER="add:extra.md" STUB_ORCA_NONE=1 \
  run "extra link in the copy: fails closed" 4 'content mismatch on scratch-clone' "$W31" --apply --salvage
exists "extra link: worktree kept" "$W31/scratch-clone/docs/real.md" yes
sleep 1
OUT31="$(STUB_PATH="$W31" STUB_ORCA_NONE=1 "$TD" local "$W31" --apply --salvage 2>&1)"; RC31=$?
if [ "$RC31" = 0 ] && grep -q '^salvaged to ' <<<"$OUT31"; then
  PASS=$((PASS + 1)); echo "PASS dangling and good link: salvaged and verified"
else
  FAIL=$((FAIL + 1)); echo "FAIL dangling and good link: salvaged and verified rc=$RC31"; echo "$OUT31"
fi
exists "links case: worktree gone" "$W31" no
SALVDIR31="$(sed -n 's/^salvaged to \(.*\) on local$/\1/p' <<<"$OUT31" | tail -n 1)"
SALVDIR31="${SALVDIR31/#\~/$HOME}"   # the script prints the dir with a literal ~
SALV31="$SALVDIR31/scratch-clone/tool-b/note.md"; SALV31G="$SALVDIR31/scratch-clone/good.md"
[ -L "$SALV31" ] && [ "$(readlink "$SALV31")" = "../tool-a/NOTES.md" ] \
  && { PASS=$((PASS + 1)); echo "PASS links case: dangling link copied as a link, target text kept"; } \
  || { FAIL=$((FAIL + 1)); echo "FAIL links case: dangling link: ${SALV31:-none}"; }
[ -L "$SALV31G" ] && [ "$(readlink "$SALV31G")" = "docs/real.md" ] \
  && { PASS=$((PASS + 1)); echo "PASS links case: good link copied as a link"; } \
  || { FAIL=$((FAIL + 1)); echo "FAIL links case: good link: ${SALV31G:-none}"; }
rm -f "$ROOT/bin/cp"; hash -r   # the premise cp above may have hashed the stub

echo "== beads store unreadable by bd (store schema older than the installed bd)"
# Reproduction of the incident: bd 66 will not open a v53 store with --readonly and
# says so in an Error line; the gate used to refuse with no way forward. The stub prints
# that error; the store is never opened, migrated or written by the script.
BDV='Error: pending schema migrations: store is at v53, bd expects v66 (run bd migrate)'
W23="$(mkwt schema-a)"; W24="$(mkwt schema-b)"; W25="$(mkwt schema-c)"; W26="$(mkwt schema-d)"
one "$W23" '"standing":false'
tbead "$W23"; tbead "$W24"; tbead "$W25"; tbead "$W26"
: > "$ROOT/bd-schema.log"
export STUB_BD_LOG="$ROOT/bd-schema.log"   # every bd call in this section, --apply runs included
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "v53 store: refuses, names the bd error"             3 'bd said: Error: pending schema migrations' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "v53 store: refusal lists the state as UNKNOWN"      3 'beads store: its state is UNKNOWN' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "v53 store: refusal names the safe flag"             3 're-run with --salvage --beads-unreadable-ok' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag without --salvage: refuses"                    3 'needs --salvage' "$W23" --beads-unreadable-ok "v53 store bd v66"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag with --salvage, tree clean and pushed: plan ok" 0 'accepted by --beads-unreadable-ok (v53 store bd v66)' "$W23" --salvage --beads-unreadable-ok "v53 store bd v66"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag: plan copies the whole .beads dir out first"   0 'copy the WHOLE .beads dir to' "$W23" --salvage --beads-unreadable-ok "v53 store bd v66"
run "flag without a reason: usage"                         2 'needs a reason' "$W23" --beads-unreadable-ok
run "flag with an empty reason: usage"                     2 'needs a reason' "$W23" --beads-unreadable-ok ""
run "flag whose reason is another flag: usage"             2 'needs a reason' "$W23" --beads-unreadable-ok --salvage
run "flag with a punctuation-only reason: usage"           2 'letters or digits' "$W23" --beads-unreadable-ok "!!!"
# Every other gate still refuses with the flag.
: > "$W24/stray.txt"; one "$W24" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag, dirty tree: still refuses"                    3 'dirty tree' "$W24" --salvage --beads-unreadable-ok "v53 store bd v66"
rm -f "$W24/stray.txt"
printf '%s\n' 'x' > "$W24/more.txt"; git -C "$W24" add more.txt; git -C "$W24" commit -qm unpushed --no-gpg-sign
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag, unpushed commit: still refuses"              3 'unpushed commits' "$W24" --salvage --beads-unreadable-ok "v53 store bd v66"
ep "$W25" t-ep1
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag does not excuse open beads in readable sources" 3 '2 open bead(s) under epic t-ep1' "$W25" --salvage --beads-unreadable-ok "v53 store bd v66"
ep "$W25" nope-zz
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag does not excuse an epic found nowhere"         3 'not found in any beads source' "$W25" --salvage --beads-unreadable-ok "v53 store bd v66"
one "$W23" '"standing":true'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "flag does not excuse a standing lane"               3 'standing lane' "$W23" --salvage --beads-unreadable-ok "v53 store bd v66"
one "$W23" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "--retire-check ignores the flag"                    3 'RETIRE REFUSED:.*beads read failed\|beads read failed' "$W23" --retire-check --beads-unreadable-ok "v53 store bd v66"
# The flag excuses only "bd ran and printed an Error": not a bare bd failure, not bd
# missing behind a redirect (the live store is elsewhere), not a timeout.
CM_BD_CMD=bd-stub STUB_BD_FAIL=1 \
  run "flag does not excuse a bd failure with no Error line" 3 'bd:failed' "$W23" --salvage --beads-unreadable-ok "v53 store bd v66"
printf '%s\n' "$M/.beads" > "$W23/.beads/redirect"
CM_BD_CMD=cm-no-such-bd \
  run "flag does not excuse bd missing behind a redirect" 3 'bd:failed-missing-with-redirect' "$W23" --salvage --beads-unreadable-ok "v53 store bd v66"
rm -f "$W23/.beads/redirect"
# A hostile reason is reduced to a safe subset and never executed.
# shellcheck disable=SC2016  # the single quotes keep the hostile reason literal on purpose
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "reason with shell metacharacters is sanitized"      0 'accepted by --beads-unreadable-ok (a(touch .*pwned)bid)' "$W23" --salvage --beads-unreadable-ok 'a$(touch '"$ROOT"'/pwned)b;`id`'
exists "hostile reason was not executed" "$ROOT/pwned" no
# bd healthy: the flag changes nothing and does not demand --salvage.
CM_BD_CMD=bd-stub STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "bd reads fine: flag is a no-op, no --salvage needed" 0 'no unmerged open beads' "$W23" --beads-unreadable-ok "v53 store bd v66"
# A store BEHIND the installed bd ("schema version mismatch") gets a recovery hint in the
# refusal. It stays a refusal (exit 3, nothing migrated: the safety checks below cover these
# cases too); another bd error carries no such hint.
BDM='Error: bd: failed to open database: schema version mismatch: database is at v39, binary expects v66'
BDX='Error: dial tcp 127.0.0.1:3307: connect: connection refused'
run_without() { # run_without <label> <expect-exit> <absent-pattern> <path> [args...]
  local label="$1" want="$2" pat="$3" p="$4" out rc
  shift 4
  out="$(STUB_PATH="$p" "$TD" local "$p" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && ! grep -q -- "$pat" <<<"$out"; then
    PASS=$((PASS + 1)); printf 'PASS %-58s rc=%s\n' "$label" "$rc"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %-58s rc=%s want=%s\n%s\n' "$label" "$rc" "$want" "$out"
  fi
}
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDM" \
  run "schema mismatch: still a refusal, names the bd error" 3 'bd said: Error: bd: failed to open database: schema version mismatch' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDM" \
  run "schema mismatch: hint points at the recovery section" 3 "references/recovery.md, section 'Beads schema version mismatch at teardown'" "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDM" \
  run "schema mismatch: hint names the steps"                3 'back up .beads, then bd migrate schema, only with no live agent in the worktree, never wipe' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDM" \
  run "schema mismatch: existing unreadable hint kept"       3 're-run with --salvage --beads-unreadable-ok' "$W23"
BDN='Error: bd: failed to open database: schema version mismatch: database is at v70, binary expects v66'
BDU='Error: schema version mismatch (database v70, binary v66)'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDU" \
  run "mismatch with unreadable versions: still a refusal" 3 'bd said: Error: schema version mismatch (database v70' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDU" \
  run_without "mismatch with unreadable versions: no migrate hint" 3 'recovery.md' "$W23"
BDP='bd: failed to open database: schema version mismatch: database is at v39, binary expects v66'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDP" \
  run "mismatch with no Error line: unchanged, bd said exit 1" 3 'bd said: exit 1' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDP" \
  run_without "mismatch with no Error line: no hint, as before" 3 'recovery.md' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDP" \
  run "mismatch with no Error line: the flag still does not excuse it" 3 'bd:failed' "$W23" --salvage --beads-unreadable-ok "v39 store bd v66"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDN" \
  run "store newer than bd: still a refusal"                 3 'bd said: Error: bd: failed to open database: schema version mismatch' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDN" \
  run_without "store newer than bd: no migrate hint"         3 'recovery.md' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDM" \
  run_without "schema mismatch: no contradictory never-migrate text" 3 'never migrate the store or run bd writes' "$W23"
ep "$W25" t-ep1
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDM" \
  run "schema mismatch: epic gate carries the hint too"      3 "references/recovery.md, section 'Beads schema version mismatch at teardown'" "$W25"
one "$W23" '"standing":false'   # one() rewrites the ledger: put W23 back for the cases below
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDX" \
  run_without "other bd error: refuses with no schema hint"  3 'recovery.md' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDX" \
  run "other bd error: the existing hint is unchanged"       3 'bd cannot read this beads store: its state is UNKNOWN' "$W23"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run_without "older-schema pending-migration error: no schema hint" 3 'recovery.md' "$W23"
# Safety: every bd call against the LIVE worktree ran read-only and sandboxed, never a write or a migrate.
# The one sanctioned exception is the copy-read the --beads-unreadable-ok cases make: a migrate and a list
# on a COPY under $CM_HOME/tmp/beads-copy.* (never the worktree).
LIVE_LOG="$(grep -v '/tmp/beads-copy\.' "$ROOT/bd-schema.log" || true)"
if [ -n "$LIVE_LOG" ] && ! printf '%s\n' "$LIVE_LOG" | grep -v -e '--readonly --sandbox' | grep -q .; then
  PASS=$((PASS + 1)); echo "PASS live-store bd calls only ran with --readonly --sandbox (no migrate, no write)"
else
  FAIL=$((FAIL + 1)); echo "FAIL live-store bd invocations not all read-only: $LIVE_LOG"
fi
# match the bd verb words only, never the -C path (a worktree path may contain "close", say)
if printf '%s\n' "$LIVE_LOG" | sed -e 's/^[^|]*|//' -e 's/-C [^ ]* //' | grep -qiE '(^| )(migrate|init|update|create|close|import|dolt)( |$)'; then
  FAIL=$((FAIL + 1)); echo "FAIL a bd write-ish verb was run on the live store: $LIVE_LOG"
else
  PASS=$((PASS + 1)); echo "PASS no bd write-ish verb was run on the live store"
fi
if ! grep '/tmp/beads-copy\.' "$ROOT/bd-schema.log" | grep -v -F -e "-C $(cd "$CM_HOME" && pwd -P)/tmp/beads-copy." | grep -q .; then
  PASS=$((PASS + 1)); echo "PASS every copy-read bd call targets -C \$CM_HOME/tmp/beads-copy.*"
else
  FAIL=$((FAIL + 1)); echo "FAIL a copy-read bd call is not aimed at the copy: $(grep '/tmp/beads-copy\.' "$ROOT/bd-schema.log")"
fi
# bd hides gates, infra beads, wisps and templates unless asked: the copy list must ask for all four
if grep '/tmp/beads-copy\.' "$ROOT/bd-schema.log" | grep -F -e ' list ' | grep -q .; then
  if grep '/tmp/beads-copy\.' "$ROOT/bd-schema.log" | grep -F -e ' list ' | awk '!(/--include-gates/ && /--include-infra/ && /--include-ephemeral/ && /--include-templates/) {bad=1} END {exit bad}'; then
    PASS=$((PASS + 1)); echo "PASS every copy list asks for gates, infra beads, wisps and templates"
  else
    FAIL=$((FAIL + 1)); echo "FAIL a copy list leaves out a hidden bead kind"
  fi
else
  FAIL=$((FAIL + 1)); echo "FAIL no copy list call was logged"
fi
# --apply: the whole .beads dir (store and all) is copied out and verified, the reason is
# logged, then the worktree goes. The store files stay byte-identical in the copy.
bdrt "$W26"; one "$W26" '"standing":false'
printf 'v53-store-marker\n' > "$W26/.beads/embeddeddolt/beads/.dolt/noms-v53"
rm -f "$CM_HOME/teardown-beads-unreadable.log"
STUB_ORCA_NONE=1 CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "apply without --salvage: refuses, worktree kept"    3 'needs --salvage' "$W26" --apply --beads-unreadable-ok "v53 store bd v66"
exists "refused apply: worktree kept" "$W26/.beads/embeddeddolt" yes
STUB_ORCA_NONE=1 CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV" \
  run "apply with flag and --salvage: removes the worktree" 0 'done: .* torn down' "$W26" --apply --salvage --beads-unreadable-ok "v53 store bd v66"
BW="$(find "$HOME/.concertmaster/salvage/local" -type d -name beads-whole -path '*b-schema-d-*' 2>/dev/null | head -n 1)"
if [ -n "$BW" ] && [ -f "$BW/issues.jsonl" ] && [ "$(cat "$BW/embeddeddolt/beads/.dolt/noms-v53" 2>/dev/null)" = v53-store-marker ] && [ -f "$BW/backup/issues.jsonl" ]; then
  PASS=$((PASS + 1)); echo "PASS whole .beads dir copied out (issues, store, backup)"
else
  FAIL=$((FAIL + 1)); echo "FAIL whole .beads copy missing or incomplete: ${BW:-none}"
fi
exists "worktree removed after the copy" "$W26" no
if [ -f "$CM_HOME/teardown-beads-unreadable.log" ] \
   && jq -e '.reason == "v53 store bd v66" and .host == "local" and (.path | endswith("schema-d")) and (.bdError | contains("pending schema migrations")) and (.salvage | endswith("/beads-whole"))' "$CM_HOME/teardown-beads-unreadable.log" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "PASS reason, host, path, bd error and salvage dir logged"
else
  FAIL=$((FAIL + 1)); echo "FAIL log missing or wrong: $(cat "$CM_HOME/teardown-beads-unreadable.log" 2>&1)"
fi

unset STUB_BD_LOG
echo "== origin org match is case-insensitive"
# GitHub orgs and repos are case-insensitive. The config org here is AcmeOrg; an origin
# written in lower case (or any mix) must be accepted, and exclude globs must match whatever
# the case of the pattern or the repo name. Synthetic names only.
# shellcheck disable=SC1091
. "$HERE/../lib.sh"
slug_case() { # slug_case <label> <url> <want-slug-or-empty> [exclude globs]
  local got
  got="$(CM_ORG=AcmeOrg CM_EXCLUDE_REPOS="${4-mirror-*}" cm_org_slug "$2" || true)"
  if [ "$got" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$got" "$3"; fi
}
slug_case "lower-case https URL, mixed-case config org"   https://github.com/acmeorg/acme-app          acmeorg/acme-app
slug_case "upper-case URL"                                  https://github.com/ACMEORG/ACME-APP.git      acmeorg/acme-app
slug_case "mixed-case ssh URL"                              git@github.com:AcMeOrG/Acme-App.git          acmeorg/acme-app
slug_case "mixed-case host"                                 https://GitHub.com/acmeorg/acme-app          acmeorg/acme-app
slug_case "other org still refused"                         https://github.com/other-org/acme-app        ""
slug_case "org prefix is not the org"                       https://github.com/acmeorg-extra/acme-app    ""
slug_case "exclude glob matches a different case (repo)"    https://github.com/acmeorg/MIRROR-acme       ""
slug_case "exclude glob in upper case matches lower repo"   https://github.com/acmeorg/mirror-acme       "" "MIRROR-*"
slug_case "non-excluded repo with an exclude glob set"      https://github.com/acmeorg/acme-mirror       acmeorg/acme-mirror
# End to end: a worktree whose origin reads as a lower-case GitHub URL passes the repo gate.
LC="$ROOT/github.com/acmeorg/acme-lc.git"
git init -q --bare -b main "$LC"
M2="$ROOT/main-lc"; git init -q -b main "$M2"; git -C "$M2" remote add origin "$LC"
git -C "$M2" commit -q --allow-empty -m init --no-gpg-sign; git -C "$M2" push -q origin main
git -C "$M2" worktree add -q -b b-lc "$ROOT/wt/lc" main >/dev/null 2>&1; git -C "$ROOT/wt/lc" push -q origin b-lc >/dev/null 2>&1
WLC="$(cd "$ROOT/wt/lc" && pwd -P)"
one "$WLC" '"standing":false'
run "lower-case origin path: repo gate passes"             0 'repo .*acmeorg/acme-lc' "$WLC"

echo "== follow-up gate"
FUS="$HERE/../followups.sh"
fu() { # fu <worker> <id> [state]: one followUps[] row as JSON
  printf '{"id":"%s","worker":"%s","lane":"lane-a","owner":"owner","text":"choose a or b","state":"%s","openedAt":"2026-10-04T00:00:00Z","closedAt":null}' "$2" "$1" "${3:-open}"; }
ledger "{\"followUps\":[$(fu w-a item-ids)],\"workers\":{\"w-a\":$(w "$W1" '"standing":false')}}"
run "open follow-up on the worker refuses"                 3 'open follow-up(s) (w-a:item-ids)' "$W1"
run "open follow-up refuses --retire-check too"            3 'open follow-up(s) (w-a:item-ids)' "$W1" --retire-check
ledger "{\"followUps\":[$(fu w-child item-check)],\"workers\":{\"w-a\":$(w "$W1" '"standing":false'),\"w-child\":$(w /elsewhere '"standing":false,"parent":"w-a"')}}"
run "open follow-up on a child refuses the parent"         3 'open follow-up(s) (w-child:item-check)' "$W1"
ledger "{\"followUps\":[$(fu w-grand deep-item)],\"workers\":{\"w-a\":$(w "$W1" '"standing":false'),\"w-child\":$(w /elsewhere '"standing":false,"parent":"w-a"'),\"w-grand\":$(w /elsewhere2 '"state":"gone","parent":"w-child"')}}"
run "open follow-up on a grandchild refuses"               3 'w-grand:deep-item' "$W1"
ledger "{\"followUps\":[$(fu w-other other-item)],\"workers\":{\"w-a\":$(w "$W1" '"standing":false'),\"w-other\":$(w /elsewhere '"standing":false'),\"w-child\":$(w /elsewhere2 '"standing":false,"parent":"w-other"')}}"
run "open follow-up on an unrelated worker is ignored"     0 'none open' "$W1"
ledger "{\"followUps\":[$(fu w-a item-ids "done")],\"workers\":{\"w-a\":$(w "$W1" '"standing":false')}}"
run "done follow-up allows"                                0 'none open' "$W1"
ledger "{\"followUps\":[$(fu w-a fa-codes | sed 's/"closedAt":null/"closedAt":null,"issue":42,"issueUrl":"https:\/\/github.com\/AcmeOrg\/acme-app\/issues\/42"/')],\"workers\":{\"w-a\":$(w "$W1" '"standing":false')}}"
run "follow-up already escalated to a GitHub issue allows"  0 'none open' "$W1"
ledger "{\"followUps\":{\"id\":\"x\"},\"workers\":{\"w-a\":$(w "$W1" '"standing":false')}}"
run "followUps not an array refuses"                       3 'followUps is not an array' "$W1"
ledger "{\"followUps\":[$(fu w-a item-ids)],\"workers\":{\"w-a\":$(w "$W1" '"standing":false')}}"
printf '{"worktrees":[{"host":"local","path":"%s","comment":"cm:done\\ncm:followup-done item-ids"}]}' "$W1" > "$ROOT/disc-done.json"
LANEFIX='.workers["w-a"].lane = "lane-a"'
jq "$LANEFIX" "$CM_HOME/ledger.json" > "$ROOT/l.tmp" && mv "$ROOT/l.tmp" "$CM_HOME/ledger.json"
run "still open before the cm:followup-done line"          3 'w-a:item-ids' "$W1"
"$FUS" reconcile --discover "$ROOT/disc-done.json" >/dev/null 2>&1
run "allows after cm:followup-done is reconciled"          0 'none open' "$W1"

echo "== follow-up gate: live comment"
one "$W1" '"standing":false,"lane":"lane-a"'
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner not folded in yet' \
  run "open tag in the live comment, not in the ledger"    3 'open follow-up(s) in live comment (fresh-one)' "$W1"
STUB_COMMENT='cm:running | cm:followup fresh-one owner=owner t' \
  run "single-line comment is read too"                    3 'in live comment (fresh-one)' "$W1"
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner t' \
  run "live comment also refuses --retire-check"           3 'in live comment (fresh-one)' "$W1" --retire-check
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner t\ncm:followup-done fresh-one' \
  run "a done line in the comment allows"                  0 'none open' "$W1"
ledger "{\"followUps\":[$(fu w-a fresh-one "done" | sed 's/"worker":"w-a"/"worker":"w-gone"/')],\"workers\":{\"w-a\":$(w "$W1" '"standing":false,"lane":"lane-a"')}}"
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner choose a or b' \
  run "a done ledger row for the lane, same text, allows"  0 'none open' "$W1"
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner a NEW item still to do' \
  run "a done id reused with new text refuses"             3 'in live comment (fresh-one)' "$W1"
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner a NEW item still to do' \
  run "the reused id refuses --retire-check too"           3 'in live comment (fresh-one)' "$W1" --retire-check
ledger "{\"followUps\":[$(fu w-a fresh-one "done" | sed 's/"lane":"lane-a"/"lane":"lane-b"/')],\"workers\":{\"w-a\":$(w "$W1" '"standing":false,"lane":"lane-a"')}}"
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner choose a or b' \
  run "a done row in another lane still refuses"           3 'in live comment (fresh-one)' "$W1"
ledger "{\"followUps\":[$(fu w-a fresh-one | sed 's/"closedAt":null/"closedAt":null,"issue":42,"issueUrl":"https:\/\/github.com\/AcmeOrg\/acme-app\/issues\/42"/')],\"workers\":{\"w-a\":$(w "$W1" '"standing":false,"lane":"lane-a"')}}"
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner choose a or b' \
  run "an escalated row, same text, in the live comment allows" 0 'none open' "$W1"
STUB_COMMENT=$'cm:running\ncm:followup fresh-one owner=owner a NEW validation step still to do' \
  run "an escalated id reused with new text refuses"       3 'in live comment (fresh-one)' "$W1"
one "$W1" '"standing":false,"lane":"lane-a"'
STUB_COMMENT=$'cm:running\ncm:followup Bad-Id owner=owner t' \
  run "a malformed cm:followup line refuses"               3 'malformed follow-up line in live comment' "$W1"
STUB_COMMENT=$'cm:running\n- cm:followup x owner=owner t' \
  run "a prefixed cm:followup line refuses"                3 'malformed follow-up line in live comment' "$W1"
STUB_COMMENT='cm:running note; cm:followup a-b owner=owner t' \
  run "a tag after a semicolon refuses"                    3 'malformed follow-up line in live comment' "$W1"
STUB_COMMENT=$'cm:running\ncm:follow_up a-b owner=owner t' \
  run "a follow_up spelling refuses"                       3 'malformed follow-up line in live comment' "$W1"
ledger "{\"workers\":{\"w-a\":$(w "$W1" '"standing":false,"lane":"lane-a","worktreeId":"r::x"')}}"
STUB_ORCA_NONE=1 run "Orca row missing for a tracked worker refuses" 3 'Orca row missing' "$W1"
one "$W1" '"standing":false,"lane":"lane-a"'
STUB_ORCA_NONE=1 run "no worktreeId (git-only worker): no row is fine" 0 'none open' "$W1"
STUB_COMMENT='cm:running plain note' run "a comment with no tags is fine"     0 'none open' "$W1"

echo "== comment archive on --apply"
W21="$(mkwt cmt-a)"; W22="$(mkwt cmt-b)"
one "$W21" '"standing":false,"lane":"lane-a"'
STUB_COMMENT=$'cm:done\nnote to keep' STUB_NAME=cmt-a STUB_ORCA_RM_MAIN="$M" \
  run "apply archives the comment, then removes"           0 'done: .* torn down' "$W21" --apply
ARC="$(find "$CM_HOME/salvage/comments/local" -name 'cmt-a-*.txt' 2>/dev/null | head -n 1)"
if [ -n "$ARC" ] && [ "$(stat -c %a "$ARC" 2>/dev/null || stat -f %Lp "$ARC")" = 600 ] && grep -q 'note to keep' "$ARC"; then
  PASS=$((PASS + 1)); echo "PASS comment archived, mode 600, text intact"
else
  FAIL=$((FAIL + 1)); echo "FAIL comment archive missing or wrong mode: ${ARC:-none}"
fi
one "$W22" '"standing":false,"lane":"lane-a"'
mkdir -p "$CM_HOME/salvage"; rm -rf "$CM_HOME/salvage/comments"; : > "$CM_HOME/salvage/comments"
STUB_COMMENT=$'cm:done\nnote' STUB_NAME=cmt-b STUB_ORCA_RM_MAIN="$M" \
  run "archive write fails: nothing removed"               4 'comment archive (nothing removed)' "$W22" --apply
if [ -d "$W22" ]; then PASS=$((PASS + 1)); echo "PASS worktree kept after the archive failure"; else FAIL=$((FAIL + 1)); echo "FAIL worktree removed anyway"; fi
rm -f "$CM_HOME/salvage/comments"

echo "== --retire-check"
one "$W1" '"standing":true'
run "retire-check refuses a standing lane"                 3 'RETIRE REFUSED' "$W1" --retire-check
one "$W1" '"standing":false'
run "retire-check passes a clean single-task worker"       0 'retire-check: ok' "$W1" --retire-check
ep "$W3" t-ep1
run "retire-check refuses open beads"                      3 'RETIRE REFUSED' "$W3" --retire-check
one "$ROOT/wt/gone-lane" '"standing":true'
run "retire-check refuses a path that does not exist"     3 'path unresolved' "$ROOT/wt/gone-lane" --retire-check
one "$W1" '"standing":false'
run "retire-check refuses a subdirectory path"             3 'path unresolved' "$W1/.beads" --retire-check
ledger '{"workers":{}}'
run "retire-check refuses with no live ledger worker"      3 'RETIRE REFUSED' "$W1" --retire-check

echo "== gap (a): an old-schema store no tracked bead change touched is not a refusal"
BDV2='Error: pending schema migrations: store is at v18, bd expects v66'
W27="$(mkwt schema-e)"; W28="$(mkwt schema-f)"; W29="$(mkwt schema-g)"
: > "$ROOT/bd-gapa.log"
export STUB_BD_LOG="$ROOT/bd-gapa.log"   # every bd call in this section
one "$W27" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "fresh worktree, v18 store: excused with no flag"    0 'excused, no tracked .beads change' "$W27"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "excused: no --salvage needed, plan ok"              0 'dry-run: nothing changed' "$W27"
tbead "$W28"; one "$W28" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "tracked .beads change: still refused"               3 'beads-unreadable-ok' "$W28"
printf '{}\n' > "$W29/.beads/extra.jsonl"; one "$W29" '"standing":false'
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "untracked bead file: still refused"                 3 'beads-unreadable-ok' "$W29"
ep "$W27" t-ep1
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "excused, but an epic with open beads still refuses" 3 '2 open bead(s) under epic t-ep1' "$W27"
ep "$W27" t-par4
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "excused, epic fully closed: plan ok"                0 'all 2 closed under t-par4' "$W27"
CM_BD_CMD=bd-stub STUB_BD_ERR='Error: dial tcp 10.0.0.5:3306: connect: connection refused' \
  run "a non-schema bd Error (connection refused) is not excused" 3 'beads-unreadable-ok' "$W27"
CM_BD_CMD=bd-stub STUB_BD_ERR='Error: unsupported schema version v99: store is newer than this bd' \
  run "a NEWER-schema Error is not excused"                3 'beads-unreadable-ok' "$W27"
CM_BD_CMD=bd-stub STUB_BD_ERR='Error: cannot reach the schema registry: connection reset' \
  run "an Error that only names a schema is not excused"   3 'beads-unreadable-ok' "$W27"
CM_BD_CMD=bd-stub STUB_BD_FAIL=1 \
  run "a bd failure with no Error line is not excused"     3 'bd:failed' "$W27"
# The live store is never migrated or written: only calls aimed at a copy under $CM_HOME/tmp/beads-copy.* may.
if ! grep -v '/tmp/beads-copy\.' "$STUB_BD_LOG" | grep -qE ' (migrate|init|create|update|close|sync|import|export|dolt)( |$)'; then echo "PASS bd was never asked to migrate or write the live store"; PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL a bd write/migrate command ran on the live store"; fi

echo "== unreadable store: open beads are read on a migrated COPY, fail closed"
# The tracked-file diff cannot see open beads: they sit in the git-ignored embedded store, the thing bd could
# not read. The gate copies .beads under $CM_HOME/tmp, runs bd migrate schema there, lists the beads on the
# copy and refuses on any open bead or any failed step. The live store is never touched.
treesum() { # treesum <wt>: listing + content digest of everything under <wt>/.beads
  ( cd "$1/.beads" && find . \( -type f -o -type l -o -type d \) | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"
      if [ -L "$f" ]; then readlink "$f"; elif [ -f "$f" ]; then sha256sum < "$f"; else echo dir; fi
    done ) | sha256sum
}
COPY_OPEN1='[{"id":"t-a","status":"open"},{"id":"t-b","status":"in_progress"},{"id":"t-c","status":"closed"},{"id":"t-d","status":"tombstone"}]'
mkstore() { bdrt "$1"; printf 'live-store-marker\n' > "$1/.beads/embeddeddolt/beads/.dolt/noms-live"; one "$1" '"standing":false'; }
: > "$ROOT/bd-copy.log"
export STUB_BD_LOG="$ROOT/bd-copy.log"
C7="$(mkwt copy-g)"; C8="$(mkwt copy-h)"
C1="$(mkwt copy-a)"; C2="$(mkwt copy-b)"; C3="$(mkwt copy-c)"; C4="$(mkwt copy-d)"; C5="$(mkwt copy-e)"
mkstore "$C1"; SUM1="$(treesum "$C1")"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST="$COPY_OPEN1" \
  run "copy lists open + in-progress beads: refuses"        3 'lists 2 open or in-progress bead(s)' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST="$COPY_OPEN1" \
  run "copy lists open beads: the hint does not offer the flag" 3 'do not override this with --beads-unreadable-ok' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST='[{"id":"t-a","status":"deferred"}]' \
  run "a deferred bead on the copy is open work: refuses"   3 'lists 1 open or in-progress bead(s)' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_MIGRATE_FAIL=1 \
  run "copy migrate fails: refuses"                         3 'migrated copy failed (bd migrate schema failed on the copy' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST_FAIL=1 \
  run "copy list fails: refuses"                            3 'migrated copy failed (bd list failed on the migrated copy' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST='not json' \
  run "copy list is not JSON: refuses"                      3 'did not print a JSON array' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST='{"status":"open"}' \
  run "copy list is an object, not an array: refuses"       3 'did not print a JSON array' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST='[{"id":"t-nostatus"}]' \
  run "a bead with no status counts as open: refuses"       3 'lists 1 open or in-progress bead(s)' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST='[]' \
  run "copy lists 0 open: excused"                          0 'migrated COPY of the store lists 0 open beads' "$C1" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST='[{"id":"t-a","status":"closed"},{"id":"t-b","status":"tombstone"}]' \
  run "copy lists only closed and tombstone: excused"       0 'lists 0 open beads' "$C1" --salvage
if [ "$(treesum "$C1")" = "$SUM1" ] && [ ! -e "$C1/.beads/migrated" ]; then
  PASS=$((PASS + 1)); echo "PASS live .beads is byte-identical after every copy-read case (listing and checksums)"
else
  FAIL=$((FAIL + 1)); echo "FAIL the live .beads changed during a copy-read"
fi
if [ -z "$(find "$CM_HOME/tmp" -maxdepth 1 -name 'beads-copy.*' 2>/dev/null)" ]; then
  PASS=$((PASS + 1)); echo "PASS no copy is left behind under \$CM_HOME/tmp"
else
  FAIL=$((FAIL + 1)); echo "FAIL a copy was left behind: $(ls "$CM_HOME/tmp")"
fi
if grep -q ' migrate schema' "$STUB_BD_LOG" && ! grep -v '/tmp/beads-copy\.' "$STUB_BD_LOG" | grep -qE ' (migrate|dolt)( |$)'; then
  PASS=$((PASS + 1)); echo "PASS migrate ran on the copy and never on the live store"
else
  FAIL=$((FAIL + 1)); echo "FAIL migrate did not run on a copy, or ran on the live store"
fi
# tracked change: refused before any copy is made
tbead "$C2"; mkstore "$C2"
: > "$STUB_BD_LOG"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "tracked .beads change: refused, no copy made"       3 'beads-unreadable-ok' "$C2" --salvage
if ! grep -q 'beads-copy' "$STUB_BD_LOG"; then PASS=$((PASS + 1)); echo "PASS no copy-read when the tracked diff already refuses"; else FAIL=$((FAIL + 1)); echo "FAIL a copy-read ran for a refused worktree"; fi
# a symlink inside .beads: a copy could write through it
mkstore "$C3"; ln -s /nonexistent-target "$C3/.beads/embeddeddolt/link"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "symlink inside .beads: refuses"                      3 'a symlink inside .beads' "$C3" --salvage
# runtime files of a Dolt server in .beads: refuses before bd touches the copy
printf '/.beads/dolt-server*\n' >> "$M/.git/info/exclude"
C9="$(mkwt copy-i)"; mkstore "$C9"; printf '3306\n' > "$C9/.beads/dolt-server.port"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "dolt-server runtime file in .beads: refuses"         3 'a Dolt server runtime file' "$C9" --salvage
# a copy must be the store: a server-mode metadata.json, dolt options in config.yaml, a redirect and a
# bd that resolves a store outside the copy all refuse, and a leaked BEADS_DOLT_* env never reaches the copy's bd
# metadata.json and config.yaml are tracked in a normal repo; here they are just ignored (info/exclude), so the
# tracked diff stays empty and the copy-read is what judges them
printf '/.beads/metadata.json\n/.beads/config.yaml\n' >> "$M/.git/info/exclude"
mkstore "$C7"; printf '{"database":"beads.db","dolt_mode":"server","dolt_server_host":"db.example.test"}\n' > "$C7/.beads/metadata.json"
SUM7="$(treesum "$C7")"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "metadata.json names a server: refuses"               3 'metadata.json names a server' "$C7" --salvage
printf '{"database":"beads.db","jsonl_export":"issues.jsonl"}\n' > "$C7/.beads/metadata.json"; SUM7="$(treesum "$C7")"
printf 'dolt.shared-server: true\n' > "$C7/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "config.yaml sets dolt options: refuses"              3 'config.yaml sets options beyond issue-prefix' "$C7" --salvage
for CFG in '"dolt.shared-server": true' '{dolt: {shared-server: true}}' "'dolt': {shared-server: true}"; do
  printf '%s\n' "$CFG" > "$C7/.beads/config.yaml"
  CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
    run "config.yaml dolt option, form $CFG: refuses"       3 'config.yaml sets options beyond issue-prefix' "$C7" --salvage
done
for CFG in 'backup.enabled: true' 'backup.git-repo: /somewhere/else' 'sync-branch: beads-sync' '  nested: value' 'export.path: /x'; do
  printf '%s\n' "$CFG" > "$C7/.beads/config.yaml"
  CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
    run "config.yaml option outside the allowlist ($CFG): refuses" 3 'config.yaml sets options beyond issue-prefix' "$C7" --salvage
done
# bytes grep and the YAML parser could read differently (NUL, invalid UTF-8, a lone CR as a line break) must not
# hide a dolt option: a file with such bytes is refused outright, and a CR is a line break for the screen
printf 'issue-prefix: a\ndolt.shared-server: true\n# \000\n' > "$C7/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "config.yaml with a NUL byte: refuses"                3 'config.yaml has bytes beyond printable ASCII' "$C7" --salvage
printf 'issue-prefix: a\nx\377: 1\n' > "$C7/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "config.yaml with invalid UTF-8: refuses"             3 'config.yaml has bytes beyond printable ASCII' "$C7" --salvage
printf 'issue-prefix: a\n# note \342\200\250dolt.shared-server: true\n' > "$C7/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "config.yaml with a Unicode line break: refuses"      3 'config.yaml has bytes beyond printable ASCII' "$C7" --salvage
printf 'issue-prefix: a\n# x\rdolt.shared-server: true\n' > "$C7/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "config.yaml with a lone CR hiding a dolt option: refuses" 3 'config.yaml sets options beyond issue-prefix' "$C7" --salvage
printf '# Beads Configuration File\r\n# note\r\nissue-prefix: acme\r\n' > "$C7/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "config.yaml with CRLF line endings and issue-prefix: ok" 0 'lists 0 open beads' "$C7" --salvage
printf '# nothing set\nissue-prefix: "acme"\n' > "$C7/.beads/config.yaml"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_NEWDB=1 \
  run "bd created a new database in the copy: refuses"      3 'bd created a new database in the copy' "$C7" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_SERVER=1 \
  run "bd on the copy reports a shared server: refuses"     3 'talked to a Dolt server' "$C7" --salvage
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_IMPORT=1 \
  run "copy would re-import issues.jsonl: it is emptied, excused" 0 'lists 0 open beads' "$C7" --salvage
: > "$ROOT/copy-home.log"
HOME="$ROOT/real-home" XDG_CONFIG_HOME="$ROOT/real-home/.config" CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_HOME_LOG="$ROOT/copy-home.log" \
  run "user-level bd config is out of reach: excused"       0 'lists 0 open beads' "$C7" --salvage
if [ -s "$ROOT/copy-home.log" ] && ! grep -v -E "^HOME=.*/tmp/beads-copy\.[^/]+/home XDG_CONFIG_HOME=unset$" "$ROOT/copy-home.log" | grep -q .; then
  PASS=$((PASS + 1)); echo "PASS the copy's bd runs with its own HOME and no XDG_CONFIG_HOME"
else
  FAIL=$((FAIL + 1)); echo "FAIL copy bd HOME not isolated: $(cat "$ROOT/copy-home.log")"
fi
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_WHERE_OUTSIDE="$ROOT/elsewhere/.beads" \
  run "bd on the copy resolves a store outside it: refuses" 3 'resolves a store outside the copy' "$C7" --salvage
: > "$ROOT/copy-env.log"
BEADS_DOLT_DATA_DIR="$ROOT/elsewhere" BEADS_DIR="$ROOT/elsewhere/.beads" CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_ENV_LOG="$ROOT/copy-env.log" \
  run "leaked BEADS_* env: the copy-read still excuses"     0 'lists 0 open beads' "$C7" --salvage
if [ -s "$ROOT/copy-env.log" ] && ! grep -v -x 'BEADS_DOLT_DATA_DIR=unset BEADS_DIR=unset' "$ROOT/copy-env.log" | grep -q .; then
  PASS=$((PASS + 1)); echo "PASS no BEADS_* env reaches the copy's bd"
else
  FAIL=$((FAIL + 1)); echo "FAIL BEADS_* env leaked into the copy's bd: $(cat "$ROOT/copy-env.log")"
fi
printf '# live beads\n%s\n' "$M/.beads" > "$C7/.beads/redirect"
SUM7="$(treesum "$C7")"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_BD_JSON="$ROOT/bd-empty.json" \
  run "a .beads/redirect: the copy is not the store, refuses" 3 'puts the store outside this worktree' "$C7" --salvage
if [ "$(treesum "$C7")" = "$SUM7" ]; then PASS=$((PASS + 1)); echo "PASS live .beads of the server-mode fixture is untouched"; else FAIL=$((FAIL + 1)); echo "FAIL live .beads changed"; fi
# the copied dolt repo state must not keep the live backup dir or a remote
mkdir -p "$C8/.beads/embeddeddolt/beads/.dolt"; one "$C8" '"standing":false'
printf '{"head":"refs/heads/main","remotes":{"origin":{"url":"https://example.test/r"}},"backups":{"b":{"url":"file:///live/.beads/backup"}}}\n' > "$C8/.beads/embeddeddolt/beads/.dolt/repo_state.json"
# a second one under a directory name with a space and a glob character: it must stay ONE path
mkdir -p "$C8/.beads/embeddeddolt/odd name [x]*/.dolt"
cp "$C8/.beads/embeddeddolt/beads/.dolt/repo_state.json" "$C8/.beads/embeddeddolt/odd name [x]*/.dolt/repo_state.json"
SUM8="$(treesum "$C8")"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" \
  run "repo_state.json with backups and remotes (one under a spaced dir name): copy-read ok" 0 'lists 0 open beads' "$C8" --salvage
if [ "$(treesum "$C8")" = "$SUM8" ] && grep -q '"backups":{"b"' "$C8/.beads/embeddeddolt/beads/.dolt/repo_state.json" \
  && grep -q '"backups":{"b"' "$C8/.beads/embeddeddolt/odd name [x]*/.dolt/repo_state.json"; then
  PASS=$((PASS + 1)); echo "PASS live repo_state.json keeps its backups and remotes (only the copy is rewritten)"
else
  FAIL=$((FAIL + 1)); echo "FAIL live repo_state.json changed"
fi
# the flag stays an override, and says what it overrode
mkstore "$C4"; SUM4="$(treesum "$C4")"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST="$COPY_OPEN1" \
  run "flag with 2 open beads on the copy: still proceeds, says so" 0 'OVERRIDING 2 open or in-progress bead(s)' "$C4" --salvage --beads-unreadable-ok "v18 store bd v66"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST='[]' \
  run "flag with 0 open beads on the copy: says 0"          0 'copy of the store lists 0 open beads' "$C4" --salvage --beads-unreadable-ok "v18 store bd v66"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_MIGRATE_FAIL=1 \
  run "flag with a failed copy-read: proceeds, open UNKNOWN" 0 'open beads UNKNOWN, the migrated-copy read failed' "$C4" --salvage --beads-unreadable-ok "v18 store bd v66"
CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST="$COPY_OPEN1" \
  run "flag, dry run: the plan names the open count"        0 'open-bead count of a migrated copy (2)' "$C4" --salvage --beads-unreadable-ok "v18 store bd v66"
if [ "$(treesum "$C4")" = "$SUM4" ]; then PASS=$((PASS + 1)); echo "PASS flag path leaves the live .beads byte-identical"; else FAIL=$((FAIL + 1)); echo "FAIL flag path changed the live .beads"; fi
# --apply with the flag: the log records the count it found (or null when the read failed)
mkstore "$C5"
: > "$CM_HOME/teardown-beads-unreadable.log"
STUB_ORCA_NONE=1 CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_LIST="$COPY_OPEN1" \
  run "flag, apply, 2 open on the copy: torn down"          0 'done: .* torn down' "$C5" --apply --salvage --beads-unreadable-ok "v18 store bd v66"
if jq -e '.reason == "v18 store bd v66" and .copyRead == "ok" and .openBeads == 2' "$CM_HOME/teardown-beads-unreadable.log" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "PASS log records copyRead=ok and openBeads=2"
else
  FAIL=$((FAIL + 1)); echo "FAIL log lacks the open-bead count: $(cat "$CM_HOME/teardown-beads-unreadable.log" 2>&1)"
fi
C6="$(mkwt copy-f)"; mkstore "$C6"
: > "$CM_HOME/teardown-beads-unreadable.log"
STUB_ORCA_NONE=1 CM_BD_CMD=bd-stub STUB_BD_ERR="$BDV2" STUB_COPY_MIGRATE_FAIL=1 \
  run "flag, apply, copy-read fails: torn down, logged"     0 'done: .* torn down' "$C6" --apply --salvage --beads-unreadable-ok "v18 store bd v66"
if jq -e '.copyRead == "failed" and .openBeads == null and (.copyReadError | contains("migrate"))' "$CM_HOME/teardown-beads-unreadable.log" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "PASS log records a failed copy-read with openBeads null"
else
  FAIL=$((FAIL + 1)); echo "FAIL log wrong for a failed copy-read: $(cat "$CM_HOME/teardown-beads-unreadable.log" 2>&1)"
fi
unset STUB_BD_LOG

echo "== project guard: a ledger of another project is never read (synthetic projects project-a, project-b)"
SAVED_HOME="$CM_HOME"; SAVED_HOME_ENV="$HOME"
export CM_PROJECT_ID=project-a HOME="$ROOT/home-a"
mkdir -p "$HOME/.concertmaster"
one "$W1" '"standing":false'
printf '%s' "$(jq -c '. + {project: "project-b"}' "$CM_HOME/ledger.json")" > "$CM_HOME/ledger.json"
run "foreign ledger (project field project-b): refused"   3 "belongs to project 'project-b'; this session runs project 'project-a'" "$W1"
run "foreign ledger: nothing else is judged from it"      3 'ledger  *REFUSED (not this project' "$W1"
one "$W1" '"standing":false'
run "unstamped ledger outside the project state dir: refused" 3 'no project field and sits outside this project' "$W1"
printf '%s' "$(jq -c '. + {project: "project-a"}' "$CM_HOME/ledger.json")" > "$CM_HOME/ledger.json"
run "matching project field: ok, whatever the path"       0 'single-task worker' "$W1"
export CM_HOME="$HOME/.concertmaster"
one "$W1" '"standing":false'
run "legacy unstamped ledger in the state dir: ok, warns" 0 'has no project field' "$W1"
run "legacy unstamped ledger: the worker is still judged" 0 'single-task worker' "$W1"
printf '%s' "$(jq -c '. + {project: "project-b"}' "$CM_HOME/ledger.json")" > "$CM_HOME/ledger.json"
run "foreign field refused even inside the state dir"     3 "belongs to project 'project-b'" "$W1"
run "retire-check refuses a foreign ledger too"           3 'RETIRE REFUSED' "$W1" --retire-check
export CM_HOME="$ROOT/cmhome"
# lead mode (--owner) with a foreign CM_HOME: see teardown-owner.sh, which has the lead-mode harness

export CM_HOME="$SAVED_HOME" HOME="$SAVED_HOME_ENV"; unset CM_PROJECT_ID

echo "== --allow-no-pr: concertmaster mode unchanged, lead mode now accepts it"
export CM_HOME="$ROOT/cmhome"
NP1="$(mkwt nopr-a)"
one "$NP1" '"standing":false'
STUB_GH=none run "concertmaster mode, no PR, no flag: refused"             3 'no merged/closed PR' "$NP1"
STUB_GH=none run "concertmaster mode, no PR, --allow-no-pr: plan ok (unchanged)" 0 'approved kill-list item' "$NP1" --allow-no-pr
# --owner no longer rejects --allow-no-pr as a usage error (exit 2): the lead-mode gates judge it (here the
# lead cannot be found, a refusal, exit 3); the other combinations stay usage errors.
STUB_GH=none run "--owner with --allow-no-pr is not a usage error"         3 'REFUSED' "$NP1" --owner no-such-lead --allow-no-pr
STUB_GH=none run "--owner with --allow-no-pr: the refusal is not 'cannot be combined'" 3 'ownership unproven' "$NP1" --owner no-such-lead --allow-no-pr
run "--owner with --retire-check is still a usage error"                   2 'cannot be combined' "$NP1" --owner no-such-lead --retire-check
run "--owner with --force-standing is still a usage error"                 2 'cannot be combined' "$NP1" --owner no-such-lead --force-standing x
run "--owner with --accept-unmerged-beads is still a usage error"          2 'cannot be combined' "$NP1" --owner no-such-lead --accept-unmerged-beads x

echo "== detached HEAD (a review worktree), concertmaster mode: accepted only on the full fail-closed rule"
export CM_HOME="$ROOT/cmhome"
mkdet() {
  git -C "$M" worktree add -q --detach "$ROOT/wt/$1" "${2:-main}" >/dev/null 2>&1
  (cd "$ROOT/wt/$1" && pwd -P)
}
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do eval "DT$_i=\"\$(mkdet dt-$_i)\""; done
DGOOD='cm:retire review done'
dtled() { one "$1" '"standing":false'; }
dtled "$DT1"
STUB_COMMENT="$DGOOD" run "detached, all rules hold: plan ok"                      0 'dry-run: nothing changed' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: the request is reported on its own line"      0 'detach-retire .*cm:retire request: review done' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: clean tree reported on its own line"          0 'detach-clean .*no tracked change, no untracked file' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: ignored files reported on their own line"     0 'detach-ignored .*no precious ignored path' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: stash reported on its own line"               0 'detach-stash .*none in the repo' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: the remote ref is named on the check line"    0 'detach-remote .*is on origin/main' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: the plan line names the remote ref"           0 'contained in remote ref origin/main' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: no operation in progress, own line"           0 'detach-inprog .*none' "$DT1"
STUB_COMMENT="$DGOOD" run "accepted: reported as no PR (detached) on the nopr line" 0 'nopr .*no PR (detached)' "$DT1"
STUB_COMMENT="$DGOOD" STUB_GH=none run "no PR lookup is needed: the branch has none to find" 0 'dry-run: nothing changed' "$DT1"
OUT="$(STUB_PATH="$DT1" STUB_COMMENT="$DGOOD" "$TD" local "$DT1" 2>&1)"
if ! printf '%s' "$OUT" | grep -q 'MERGED'; then PASS=$((PASS + 1)); echo "PASS a merged-PR lookup never counts as the proof for a detached HEAD"; else FAIL=$((FAIL + 1)); echo "FAIL detached HEAD reported a merged PR"; echo "$OUT"; fi
# one refusal per rule, each on its own
dtled "$DT2"
STUB_COMMENT=$'cm:done review finished' run "no cm:retire: refused"                  3 'detach-retire .*NO cm:retire request' "$DT2"
run "no comment at all: refused"                                                     3 'detach-retire .*NO cm:retire request' "$DT2"
STUB_COMMENT=$'cm:running\ncm:retire later' run "cm:retire not on the first line: refused" 3 'detach-retire .*NO cm:retire request' "$DT2"
dtled "$DT3"; printf 'changed\n' >> "$DT3/.beads/.gitignore"
STUB_COMMENT="$DGOOD" run "dirty tracked file: refused"                              3 'detach-clean .*NO (1 changed or untracked paths)' "$DT3"
dtled "$DT4"; printf 'scratch\n' > "$DT4/notes.txt"
STUB_COMMENT="$DGOOD" run "untracked file: refused"                                  3 'detach-clean .*NO (1 changed or untracked paths)' "$DT4"
# an ignored file that is not regenerable noise (info/exclude is shared by every worktree of the repo)
printf 'review-notes.txt\n' >> "$M/.git/info/exclude"
dtled "$DT5"; printf 'secret\n' > "$DT5/review-notes.txt"
STUB_COMMENT="$DGOOD" run "ignored (precious) file, no --salvage: refused"           3 'detach-ignored .*1 precious path(s) and no --salvage' "$DT5"
STUB_COMMENT="$DGOOD" run "ignored file with --salvage: accepted, the salvage copies it" 0 'accepted only because --salvage copies and verifies them' "$DT5" --salvage
dtled "$DT6"; git -C "$DT6" commit -q --allow-empty -m local-only --no-gpg-sign
STUB_COMMENT="$DGOOD" run "HEAD only local (on no remote ref): refused"              3 'HEAD is not on any remote ref' "$DT6"
dtled "$DT7"; mv -- "$BARE" "$BARE.off"
STUB_COMMENT="$DGOOD" run "fetch of origin fails: refused, not read as contained"    3 'detach-remote .*UNKNOWN (git fetch or ls-remote of origin failed or timed out)' "$DT7"
mv -- "$BARE.off" "$BARE"
dtled "$DT8"; mkdir -- "$(git -C "$DT8" rev-parse --absolute-git-dir)/rebase-merge"
STUB_COMMENT="$DGOOD" run "rebase in progress: refused"                              3 'detach-inprog .*YES: rebase-merge' "$DT8"
dtled "$DT9"; dtled "$DT10"
printf 'wip\n' >> "$DT9/.beads/.gitignore"; git -C "$DT9" stash push -q -m wip
STUB_COMMENT="$DGOOD" run "a stash entry in the repo: refused"                       3 'stashes are shared per repo, not per worktree' "$DT10"
git -C "$DT9" stash drop -q
STUB_COMMENT="$DGOOD" run "stash dropped: the same worktree is accepted again"       0 'detach-stash .*none in the repo' "$DT10"
# a review worktree made from a PR head sha: the commit is on origin's branch but this checkout has no tracking ref yet,
# so it is on no known remote ref until the fresh fetch (a push to the URL, not the remote name, updates no tracking ref)
git -C "$M" worktree add -q --detach "$ROOT/wt/dt-late" main >/dev/null 2>&1
DTL="$(cd "$ROOT/wt/dt-late" && pwd -P)"
git -C "$DTL" commit -q --allow-empty -m pr-head --no-gpg-sign && git -C "$DTL" push -q "$BARE" HEAD:refs/heads/b-late >/dev/null 2>&1
dtled "$DTL"
STUB_COMMENT="$DGOOD" run "PR head not yet fetched: first run defers the unpushed check, accepted" 0 'unpushed .*judged again after the fresh fetch' "$DTL"
STUB_COMMENT="$DGOOD" run "PR head not yet fetched: once fetched, its remote ref is named" 0 'detach-remote .*is on origin/b-late' "$DTL"
STUB_COMMENT=$'cm:done review finished' run "an earlier detached refusal skips the fetch" 3 'detach-remote .*not checked' "$DT2"
# a branch deleted on origin must not keep "holding" the commit through a stale remote-tracking ref (fetch --prune)
git -C "$M" worktree add -q -b b-stale "$ROOT/wt/dt-stale" main >/dev/null 2>&1
DTS="$(cd "$ROOT/wt/dt-stale" && pwd -P)"
git -C "$DTS" commit -q --allow-empty -m only-on-the-branch --no-gpg-sign && git -C "$DTS" push -q origin b-stale >/dev/null 2>&1
git -C "$DTS" checkout -q --detach && git -C "$DTS" branch -q -D b-stale
dtled "$DTS"
STUB_COMMENT="$DGOOD" run "branch still on origin: HEAD is on its remote ref, accepted" 0 'detach-remote .*is on origin/b-stale' "$DTS"
git --git-dir="$BARE" update-ref -d refs/heads/b-stale
STUB_COMMENT="$DGOOD" run "branch deleted on origin (stale tracking ref kept): refused" 3 'HEAD is not on any remote ref' "$DTS"
if git -C "$DTS" show-ref --verify -q refs/remotes/origin/b-stale; then PASS=$((PASS + 1)); echo "PASS a dry run prunes nothing: the stale tracking ref is still there"; else FAIL=$((FAIL + 1)); echo "FAIL the dry run pruned a tracking ref"; fi
# over ssh (a stub that runs the remote command here): the branch rc, the bounded fetch and the stash read all go through it
cat > "$ROOT/bin/ssh" <<'S'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac; done
shift
exec bash -c "$*"
S
chmod +x "$ROOT/bin/ssh"
DT14="$(mkdet dt-14)"; DT15="$(mkdet dt-15)"; DT16="$(mkdet dt-16)"
git -C "$DT15" commit -q --allow-empty -m local-only --no-gpg-sign
rdt() { # rdt <label> <want> <pattern> <path>: the detached teardown over the stub ssh, concertmaster mode on host remote-1
  local label="$1" want="$2" pat="$3" p="$4" out rc
  ledger "{\"workers\":{\"w-a\":{\"host\":\"remote-1\",\"path\":\"$p\",\"standing\":false}}}"
  out="$(STUB_PATH="$p" STUB_COMMENT="$DGOOD" CM_SSH_TARGET=fleet-box CM_SSH_EXPECT_HOSTNAME="$(hostname -s)" "$TD" remote-1 "$p" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && grep -q -- "$pat" <<<"$out"; then PASS=$((PASS + 1)); printf 'PASS %-58s rc=%s\n' "$label" "$rc"
  else FAIL=$((FAIL + 1)); printf 'FAIL %-58s rc=%s want=%s\n%s\n' "$label" "$rc" "$want" "$out"; fi
}
rdt "remote host, detached, all rules hold: plan ok"                     0 'detach-remote .*is on origin/main' "$DT14"
rdt "remote host: the stash read goes through ssh"                       0 'detach-stash .*none in the repo' "$DT14"
rdt "remote host, HEAD only local: refused"                              3 'HEAD is not on any remote ref' "$DT15"
printf 'wip\n' >> "$DT16/.beads/.gitignore"; git -C "$DT16" stash push -q -m wip
rdt "remote host, a stash entry in the repo: refused"                    3 'stashes are shared per repo' "$DT14"
git -C "$DT16" stash drop -q
rm -f -- "$ROOT/bin/ssh"
# the ledger and standing gates still run for a detached HEAD
ledger '{"workers":{}}'
STUB_COMMENT="$DGOOD" run "detached, no live ledger worker: still refused"           3 'no live ledger worker' "$DT11"
one "$DT11" '"standing":true'
STUB_COMMENT="$DGOOD" run "detached, standing lane: still refused"                   3 'standing lane' "$DT11"
# the salvage dir of a detached worktree is named for the worktree and sha, so two salvages in one second cannot collide
DT13="$(mkdet dt-13)"; dtled "$DT13"; printf 'secret\n' > "$DT13/review-notes.txt"
STUB_COMMENT="$DGOOD" STUB_ORCA_RM_MAIN="$M" run "detached with an ignored file: --apply --salvage" 0 'done: .* torn down' "$DT13" --apply --salvage
SALV13="$(find "$HOME/.concertmaster/salvage" -path '*/detached-dt-13-*/review-notes.txt' 2>/dev/null | head -n 1)"
exists "detached salvage dir carries the worktree name and sha" "${SALV13:-$ROOT/none}" yes
# apply
dtled "$DT12"
: > "$ROOT/seq-detached.log"
STUB_BD_LOG="$ROOT/seq-detached.log" STUB_COMMENT='cm:done x' STUB_ORCA_RM_MAIN="$M" run "apply with no cm:retire: refused" 3 'detach-retire .*NO cm:retire request' "$DT12" --apply
exists "refused detached apply: worktree kept" "$DT12" yes
STUB_BD_LOG="$ROOT/seq-detached.log" STUB_COMMENT="$DGOOD" STUB_ORCA_RM_MAIN="$M" run "apply removes an accepted detached worktree" 0 'done: .* torn down' "$DT12" --apply
exists "accepted detached apply: worktree gone" "$DT12" no

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
