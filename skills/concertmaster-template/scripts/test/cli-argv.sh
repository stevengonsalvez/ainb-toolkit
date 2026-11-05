#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# cm_cli / cm_cli_host (test): which CLI the scripts drive, and with which argv. A stub CLI records the argv of
# every call and answers with canned JSON (synthetic host-a, one -sweeper lane, no real names).
#   1. cm_cli resolution: orca (ORCA_CLI_COMMAND, orca-ide outside an Orca terminal, else orca), plugly
#      (PLUGLY_CLI_COMMAND, else plugly), the config key `cli`, CM_CLI_KIND beating the file, cm_orca as an alias,
#      an unknown value failing closed (status 2, a message, no call).
#   2. cm_cli_host / cm_cli_host_into: both CLIs print nothing for local and --environment <name> otherwise
#      (plugly's `host list` advertises --host local, but plugly 1.0.0 rejects --host on every command the scripts use).
#   3. argv of representative calls under `cli: orca` (host list, worktree list, worktree ps, worktree show,
#      worktree set, terminal list, terminal read, terminal send, automations list), driven through fleet-state.sh
#      (write --push), automations-audit.sh, waiting.sh and pane-stalls.sh. The orca expectation is the argv those
#      scripts produced BEFORE the cm_cli change: it was recorded by running this same harness on the tree at
#      origin/main, so "no behaviour change while cli is orca" is a byte comparison, not a promise. Under plugly the
#      argv is the same, since the local host needs no selector.
#   4. an unknown `cli` stops every script that reaches the CLI with status 2 before any CLI call (each one also makes
#      calls under `cli: orca`, so a 2 caused by anything else is told apart), and every `ORCA=$(cm_cli)` is guarded.
# CM_ARGV_SCRIPTS=<dir> drives another copy of scripts/ (that is how the orca expectation was recorded).
#
#   scripts/test/cli-argv.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$(cd "${CM_ARGV_SCRIPTS:-$HERE/..}" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-cli-argv.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

BIN="$ROOT/bin"; mkdir -p "$BIN"
STATE="$ROOT/state"; mkdir -p "$STATE"
LOG="$ROOT/argv.log"

# The stub CLI. Both names (orca-stub, plugly-stub) are this one script; it logs "<args>" per call.
cat > "$BIN/stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
env=""; wt=""; comment=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    --environment) j=$((i + 1)); env="${!j}" ;;
    --worktree) j=$((i + 1)); wt="${!j}" ;;
    --comment) j=$((i + 1)); comment="${!j}" ;;
  esac
done
cf="$STUB_STATE/concertmaster.comment"
case "$1 $2" in
  "host list") printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"},{"kind":"environment","name":"host-a"}]}}' ;;
  "worktree list"|"worktree ps")
     printf '{"ok":true,"result":{"worktrees":[{"path":"/w/acme/concertmaster","displayName":"concertmaster","comment":""},{"path":"/w/acme/lane-sweeper","displayName":"lane-sweeper","comment":""}]}}' ;;
  "worktree show") c=""; [ ! -r "$cf" ] || c="$(cat "$cf")"
     jq -cn --arg c "$c" '{ok:true,result:{worktree:{displayName:"concertmaster", path:"/w/acme/concertmaster", comment:$c}}}' ;;
  "worktree set") printf '%s' "$comment" > "$cf"; echo '{"ok":true}' ;;
  "terminal list") printf '{"ok":true,"result":{"terminals":[{"handle":"t-1","worktreePath":"/w/acme/lane-sweeper","agentIdentity":"claude","lastOutputAt":1000}]}}' ;;
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":["quiet pane"]}}}' ;;
  "terminal send") echo '{"ok":true}' ;;
  "automations list") printf '{"ok":true,"result":{"automations":[]}}' ;;
  *) echo '{"ok":true}' ;;
esac
STUB
chmod +x "$BIN/stub"
ln -s stub "$BIN/orca-stub"; ln -s stub "$BIN/plugly-stub"

cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
project: { name: Acme }
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/acme/", orca_repo: app, self_name: concertmaster, never_touch: [] }
CFG
cat > "$ROOT/config-plugly.yaml" <<'CFG'
schema: concertmaster.config/v1
cli: plugly
project: { name: Acme }
github: { org: Acme, main_repo: app }
worktrees: { path_match: "/acme/", orca_repo: app, self_name: concertmaster, never_touch: [] }
CFG

export STUB_LOG="$LOG" STUB_STATE="$STATE"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH CM_LEDGER CM_STATE_WORKTREE CM_CLI_KIND ORCA_CLI_COMMAND PLUGLY_CLI_COMMAND
export CM_HOME="$ROOT/home" CM_NOW="2030-01-01T10:00:00Z" CM_PROC_ROOT="$ROOT/noproc" HOME="$ROOT"
mkdir -p "$CM_HOME"

# ---- 1. cm_cli resolution -------------------------------------------------------------------------------
# lib <env assignments...> -- <shell snippet>: run the snippet with lib.sh sourced, in a clean subshell.
lib() {
  local -a envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -u CM_CLI_KIND -u ORCA_CLI_COMMAND -u PLUGLY_CLI_COMMAND -u TERM_PROGRAM "${envs[@]}" CM_CONFIG="${LIB_CFG:-$ROOT/config.yaml}" \
    bash -c ". '$S/lib.sh'; $1" 2>&1
}
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}
FAKEBIN="$ROOT/fakebin"; mkdir -p "$FAKEBIN"; printf '#!/bin/sh\n' > "$FAKEBIN/orca-ide"; chmod +x "$FAKEBIN/orca-ide"
# NOIDE: a PATH with only what lib.sh needs, so "orca-ide is absent" holds on a host that has one installed.
TOOLS="$ROOT/tools"; mkdir -p "$TOOLS"
for t in bash uname dirname jq yq cat tr sed; do
  tp="$(command -v "$t" 2>/dev/null)" && ln -sf "$tp" "$TOOLS/$t"
done
NOIDE="$TOOLS"
check "orca (default): ORCA_CLI_COMMAND wins"            "/x/my-orca"  "$(lib ORCA_CLI_COMMAND=/x/my-orca -- 'cm_cli')"
check "orca: orca-ide on Linux outside an Orca terminal" "orca-ide"    "$(lib "PATH=$FAKEBIN:$NOIDE" -- 'cm_cli')"
check "orca: bare orca inside an Orca terminal"          "orca"        "$(lib "PATH=$FAKEBIN:$NOIDE" TERM_PROGRAM=Orca -- 'cm_cli')"
check "orca: bare orca when orca-ide is absent"          "orca"        "$(lib "PATH=$NOIDE" -- 'cm_cli')"
check "cm_orca is an alias of cm_cli (orca)"             "/x/my-orca"  "$(lib ORCA_CLI_COMMAND=/x/my-orca -- 'cm_orca')"
check "plugly: PLUGLY_CLI_COMMAND wins"                  "/x/my-plugly" "$(lib CM_CLI_KIND=plugly PLUGLY_CLI_COMMAND=/x/my-plugly -- 'cm_cli')"
check "plugly: bare plugly by default"                   "plugly"      "$(lib CM_CLI_KIND=plugly "PATH=$FAKEBIN:$NOIDE" -- 'cm_cli')"
check "plugly: ORCA_CLI_COMMAND is ignored"              "plugly"      "$(lib CM_CLI_KIND=plugly ORCA_CLI_COMMAND=/x/my-orca -- 'cm_cli')"
check "cm_orca is an alias of cm_cli (plugly)"           "plugly"      "$(lib CM_CLI_KIND=plugly -- 'cm_orca')"
check "config key cli: plugly is read"                   "plugly"      "$(LIB_CFG="$ROOT/config-plugly.yaml" lib -- 'cm_cli')"
check "CM_CLI_KIND beats the config key"                 "/x/my-orca"  "$(LIB_CFG="$ROOT/config-plugly.yaml" lib CM_CLI_KIND=orca ORCA_CLI_COMMAND=/x/my-orca -- 'cm_cli')"
out="$(lib CM_CLI_KIND=bogus -- 'cm_cli; echo "rc=$?"')"
case "$out" in *"unknown cli 'bogus'"*"use orca or plugly"*"rc=2") pass "an unknown cli fails closed: message and status 2, nothing printed on stdout" ;; *) fail "unknown cli" "$out" ;; esac
out="$(lib CM_CLI_KIND=bogus -- 'cm_cli_host local; echo "rc=$?"')"
case "$out" in *"unknown cli 'bogus'"*"rc=2") pass "cm_cli_host fails closed on an unknown cli" ;; *) fail "unknown cli (host)" "$out" ;; esac
out="$(lib CM_CLI_KIND=Orca -- 'cm_cli; echo "rc=$?"')"
case "$out" in *"unknown cli 'Orca'"*"rc=2") pass "the value is exact (Orca is not orca)" ;; *) fail "case" "$out" ;; esac

# ---- 2. cm_cli_host ---------------------------------------------------------------------------------------
check "orca: local host -> nothing"                      ""                         "$(lib CM_CLI_KIND=orca -- 'cm_cli_host local')"
check "orca: remote host -> --environment <name>"        "--environment host-a"     "$(lib CM_CLI_KIND=orca -- 'cm_cli_host host-a')"
check "plugly: local host -> nothing (plugly 1.0.0 rejects --host)" ""                 "$(lib CM_CLI_KIND=plugly -- 'cm_cli_host local')"
check "plugly: remote host -> --environment <name>"      "--environment host-a"     "$(lib CM_CLI_KIND=plugly -- 'cm_cli_host host-a')"
check "an empty host is refused (rc 2), never read as local" "rc=2"                "$(lib CM_CLI_KIND=orca -- 'cm_cli_host "" 2>/dev/null; echo "rc=$?"' | tail -1)"
check "cm_cli_host_into: an empty host leaves an empty array" "n=0 rc=2"           "$(lib CM_CLI_KIND=orca -- 'a=(stale --environment x); cm_cli_host_into a "" 2>/dev/null; echo "n=${#a[@]} rc=$?"' | tail -1)"
check "cm_cli_host_into refuses its own variable name"   "rc=2"          "$(lib CM_CLI_KIND=orca -- 'cm_cli_host_into _cm_h host-a 2>/dev/null; echo "rc=$?"' | tail -1)"
check "cm_cli_host_into: orca local is an empty array"   "n=0"                      "$(lib CM_CLI_KIND=orca -- 'cm_cli_host_into a local; echo "n=${#a[@]}"')"
check "cm_cli_host_into: orca remote is two words"       "n=2 --environment|host-a" "$(lib CM_CLI_KIND=orca -- 'cm_cli_host_into a host-a; echo "n=${#a[@]} ${a[0]}|${a[1]}"')"
check "cm_cli_host_into: plugly local is an empty array" "n=0"                      "$(lib CM_CLI_KIND=plugly -- 'cm_cli_host_into a local; echo "n=${#a[@]}"')"
check "cm_cli_host_into: a local array of the caller"    "n=2 --environment|host-a" "$(lib CM_CLI_KIND=plugly -- 'f() { local -a sel; cm_cli_host_into sel host-a; echo "n=${#sel[@]} ${sel[0]}|${sel[1]}"; }; f')"
check "cm_cli_host_into keeps a host name with a space as one element" "n=2 --environment|host a" "$(lib CM_CLI_KIND=orca -- 'cm_cli_host_into a "host a"; echo "n=${#a[@]} ${a[0]}|${a[1]}"')"
check "cm_cli_host_into refuses a bad array name"        "rc=2"                     "$(lib CM_CLI_KIND=orca -- 'cm_cli_host_into "a b" local 2>/dev/null; echo "rc=$?"' | tail -1)"
check "cm_cli_host_into passes the failure on"           "rc=2"                     "$(lib CM_CLI_KIND=bogus -- 'cm_cli_host_into a local 2>/dev/null; echo "rc=$?"' | tail -1)"

# ---- 3. argv of representative calls -------------------------------------------------------------------
# drive <kind>: run the four scripts against the stub with cli=<kind>; leave the argv in $LOG.
drive() {
  local kind="$1" cli="$2" sc
  : > "$LOG"; rm -f "$STATE/concertmaster.comment"
  export CM_CONFIG="$ROOT/config.yaml" CM_CLI_KIND="$kind"
  if [ "$kind" = plugly ]; then export PLUGLY_CLI_COMMAND="$cli"; unset ORCA_CLI_COMMAND; else export ORCA_CLI_COMMAND="$cli"; unset PLUGLY_CLI_COMMAND; fi
  # CM_CLI_KIND is meaningless to a tree that predates cm_cli: it simply runs ORCA_CLI_COMMAND.
  for sc in fleet-state automations-audit waiting pane-stalls; do
    echo "## $sc" >> "$LOG"
    case "$sc" in
      fleet-state) bash "$S/fleet-state.sh" write --freeze on --window 2030-01-01T15:00Z --prod v9.9.9 --push ;;
      *)           bash "$S/$sc.sh" ;;
    esac >/dev/null 2>&1
  done
  # the stub's own path is not part of the argv; only "<args>" is logged
  sed 's/\[cm-freeze-[0-9]*\]/[cm-freeze-HHMM]/' "$LOG" > "$ROOT/argv.$kind.log"   # the push text carries the clock
}

cat > "$ROOT/want.orca" <<'EOF'
## fleet-state
worktree show --worktree active --json
worktree show --worktree active --json
worktree set --worktree active --comment cm:state freeze=on window=2030-01-01T15:00Z prod=v9.9.9 at=2030-01-01T10:00:00Z --json
worktree show --worktree active --json
host list --json
worktree list --json --limit 500 --repo name:app
worktree list --json --limit 500 --repo name:app --environment host-a
terminal list --worktree path:/w/acme/lane-sweeper --json
terminal send --terminal t-1 --text [cm-freeze-HHMM] merge freeze is ON until prod verifies (window 2030-01-01T15:00Z). No merge ask, no deploy; read cm:state in the concertmaster worktree comment each tick. --enter --json
terminal list --worktree path:/w/acme/lane-sweeper --environment host-a --json
terminal send --terminal t-1 --text [cm-freeze-HHMM] merge freeze is ON until prod verifies (window 2030-01-01T15:00Z). No merge ask, no deploy; read cm:state in the concertmaster worktree comment each tick. --enter --environment host-a --json
## automations-audit
host list --json
automations list --json
automations list --environment host-a --json
## waiting
worktree ps --json
terminal list --json
terminal read --terminal t-1 --json
host list --json
worktree ps --environment host-a --json
terminal list --environment host-a --json
terminal read --terminal t-1 --environment host-a --json
## pane-stalls
host list --json
worktree list --json --limit 500 --repo name:app
worktree list --json --limit 500 --repo name:app --environment host-a
terminal list --json
terminal read --terminal t-1 --screen --json
terminal list --json --environment host-a
terminal read --terminal t-1 --screen --json --environment host-a
EOF
cat > "$ROOT/want.plugly" <<'EOF'
## fleet-state
worktree show --worktree active --json
worktree show --worktree active --json
worktree set --worktree active --comment cm:state freeze=on window=2030-01-01T15:00Z prod=v9.9.9 at=2030-01-01T10:00:00Z --json
worktree show --worktree active --json
host list --json
worktree list --json --limit 500 --repo name:app
worktree list --json --limit 500 --repo name:app --environment host-a
terminal list --worktree path:/w/acme/lane-sweeper --json
terminal send --terminal t-1 --text [cm-freeze-HHMM] merge freeze is ON until prod verifies (window 2030-01-01T15:00Z). No merge ask, no deploy; read cm:state in the concertmaster worktree comment each tick. --enter --json
terminal list --worktree path:/w/acme/lane-sweeper --environment host-a --json
terminal send --terminal t-1 --text [cm-freeze-HHMM] merge freeze is ON until prod verifies (window 2030-01-01T15:00Z). No merge ask, no deploy; read cm:state in the concertmaster worktree comment each tick. --enter --environment host-a --json
## automations-audit
host list --json
automations list --json
automations list --environment host-a --json
## waiting
worktree ps --json
terminal list --json
terminal read --terminal t-1 --json
host list --json
worktree ps --environment host-a --json
terminal list --environment host-a --json
terminal read --terminal t-1 --environment host-a --json
## pane-stalls
host list --json
worktree list --json --limit 500 --repo name:app
worktree list --json --limit 500 --repo name:app --environment host-a
terminal list --json
terminal read --terminal t-1 --screen --json
terminal list --json --environment host-a
terminal read --terminal t-1 --screen --json --environment host-a
EOF

drive orca "$BIN/orca-stub"
if diff -u "$ROOT/want.orca" "$ROOT/argv.orca.log" > "$ROOT/diff.orca"; then
  pass "cli: orca keeps the argv byte for byte (host list, worktree list/ps/show/set, terminal list/read/send, automations list)"
else fail "cli: orca argv changed" "$(head -40 "$ROOT/diff.orca")"; fi

drive plugly "$BIN/plugly-stub"
if diff -u "$ROOT/want.plugly" "$ROOT/argv.plugly.log" > "$ROOT/diff.plugly"; then
  pass "cli: plugly sends the same argv (no selector for the local host, --environment <name> for the rest)"
else fail "cli: plugly argv" "$(head -40 "$ROOT/diff.plugly")"; fi
# ---- 4. an unknown cli stops a script before any call --------------------------------------------------
# Each entry reaches the CLI under cli: orca (the positive control), so a status 2 under a bogus cli comes from cm_cli.
# gh, ssh, docker, supabase and curl are stubs that fail at once, so check4 never reaches the network (discover.sh
# calls gh, ssh and docker for real otherwise); the stub dir shadows them on PATH for the scripts only.
EXT="$ROOT/ext"; mkdir -p "$EXT"
for t in gh ssh docker supabase curl; do printf '#!/bin/sh\nexit 1\n' > "$EXT/$t"; chmod +x "$EXT/$t"; done
check4() { # <script> [args...]
  local sc="$1" rc calls; shift
  : > "$LOG"
  PATH="$EXT:$PATH" CM_CLI_KIND=orca ORCA_CLI_COMMAND="$BIN/orca-stub" CM_CONFIG="$ROOT/config.yaml" bash "$S/$sc.sh" "$@" >/dev/null 2>&1 </dev/null
  calls="$(wc -l < "$LOG" | tr -d ' ')"
  if [ "$calls" -gt 0 ]; then pass "$sc.sh: reaches the CLI under cli: orca ($calls calls)"; else fail "$sc.sh control" "no CLI call under cli: orca"; return; fi
  : > "$LOG"
  PATH="$EXT:$PATH" CM_CLI_KIND=bogus ORCA_CLI_COMMAND="$BIN/orca-stub" CM_CONFIG="$ROOT/config.yaml" bash "$S/$sc.sh" "$@" >/dev/null 2>"$ROOT/bogus.err" </dev/null; rc=$?
  calls="$(wc -l < "$LOG" | tr -d ' ')"
  if [ "$rc" = 2 ] && [ "$calls" = 0 ]; then pass "$sc.sh: an unknown cli exits 2 and makes no CLI call"; else fail "$sc.sh unknown cli" "rc=$rc calls=$calls $(head -c 200 "$ROOT/bogus.err")"; fi
}
check4 fleet-state read
check4 automations-audit
check4 waiting
check4 pane-stalls
check4 abrupt
check4 asks
check4 lessons-recon
check4 discover
check4 boot-sweep --dry-run
# asks.sh must not touch its state file on an unknown cli (it once rewrote asks-seen.json to {}): the control run above
# wrote the file, so compare it before and after a bogus run.
mkdir -p "$CM_HOME"; before="$(cat "$CM_HOME/asks-seen.json" 2>/dev/null; echo end)"
out="$(CM_CLI_KIND=bogus CM_CONFIG="$ROOT/config.yaml" bash "$S/asks.sh" 2>&1 </dev/null)"
case "$out" in *"unknown cli 'bogus'"*) pass "and the message says why" ;; *) fail "unknown cli message" "$out" ;; esac
after="$(cat "$CM_HOME/asks-seen.json" 2>/dev/null; echo end)"
[ "$before" = "$after" ] && pass "asks.sh leaves asks-seen.json untouched under an unknown cli" || fail "asks-seen.json" "changed under an unknown cli"
# Scripts the stub setup cannot drive (they need a ledger or a worktree): every ORCA=$(cm_cli) must be guarded.
unguarded="$(grep -nE 'ORCA="\$\(cm_cli\)"|orca="\$\(cm_cli\)"' "$S"/*.sh | grep -v '||' || true)"
[ -z "$unguarded" ] && pass "every ORCA=\$(cm_cli) assignment in scripts/ ends in || exit/return 2" || fail "unguarded cm_cli assignment" "$unguarded"
n="$(grep -cE 'ORCA="\$\(cm_cli\)"|orca="\$\(cm_cli\)"' "$S"/*.sh | awk -F: '{t+=$2} END{print t}')"
[ "$n" -ge 15 ] && pass "and there are $n of them (resume, queue-audit, runtime-check, teardown included)" || fail "assignment count" "only $n"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
