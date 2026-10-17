#!/usr/bin/env bash
# teardown-gates.sh: behaviour tests for teardown.sh's ledger, standing and
# beads gates. Builds a throwaway repo whose origin is a local bare repo (so
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
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf -- "${ROOT:?}"' EXIT
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
# chmod-based cases mean nothing as root (permissions are ignored): skip them.
AS_ROOT=0; [ "$(id -u)" = 0 ] && AS_ROOT=1
skip() { printf 'SKIP %s (running as root)\n' "$1"; }
cat > "$ROOT/bin/gh" <<G
#!/usr/bin/env bash
echo '[{"number":1,"state":"MERGED","headRefOid":"$SHA"}]'
G
cat > "$ROOT/bin/orca-stub" <<'O'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree ps") [ "${STUB_ORCA_NONE:-0}" = 1 ] && { echo '{"result":{"worktrees":[]}}'; exit 0; }
    jq -cn --arg p "$STUB_PATH" --arg n "${STUB_NAME:-x}" --arg id "${STUB_WID:-r::x}" \
    '{result:{worktrees:[{path:$p,worktreeId:$id,displayName:$n,status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}]}}' ;;
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
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -q -- "$pat"; then
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
  : > "$1/.beads.gate.lock"; : > "$1/.beads/embeddeddolt.gate.lock"; : > "$1/.beads/backup.lock"
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
  run "store with pending migrations: refuses, says why"   3 'bd said: Error: search count issues.*granted_node' "$W14" --salvage
ep "$W14" t-ep1
CM_BD_CMD=bd-stub STUB_BD_ERR='Error: search count issues: Error 1105: table "leases" does not have column "granted_node"' \
  run "same with an epic: refuses"                         3 'a beads source failed' "$W14" --salvage

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

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
