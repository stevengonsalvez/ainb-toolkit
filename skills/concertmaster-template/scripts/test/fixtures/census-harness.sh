# shellcheck shell=bash
# Sourced by the census tests (census-*.sh). Hermetic harness: a temp CM_HOME, fixture git repos,
# a stubbed `orca` and `ssh` on PATH. Synthetic names only: lane-a, lane-b, host-a, host-b.
#
#   census_init <label>            temp dir, env, org cache, stub dirs; sets ROOT STUB BIN
#   census_repo <dir>              a clone of a fresh bare origin with one pushed commit on main
#   census_worktree <repo> <dir> <branch>   a linked worktree on a new branch (equal to origin/main)
#   census_hosts <name>...         `orca host list` answer: local plus the named environments
#   census_ps <host|local> <json-row>...    `orca worktree ps` answer for a host (rows built by census_row)
#   census_row <repo> <path> <branch> [main] one Orca worktree row
#   census_discover [args]         run discover.sh --no-prs, document on stdout
# The stub orca `terminal create` runs the --command text in a shell (what a remote host would do),
# writes the echoed command line plus its output to a file, and `terminal read` answers from it.
# Switches (touch the file under $STUB): create-fail-<host>, hang-<host>, close-fail-<host>,
# lose-handle-<host> (the terminal is made but the create call reports failure, as after a timeout).
# Calls are logged to $STUB/calls.log, one line each.

census_init() {
  HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SCRIPTS="$(cd "$HARNESS_DIR/../.." && pwd)"
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-census-$1.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
  [ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
  # shellcheck disable=SC2064
  trap "rm -rf -- '${ROOT:?}'" EXIT
  command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
  command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
  export CM_CONFIG="${CM_CONFIG:-$HARNESS_DIR/config.test.yaml}"
  unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH \
        CM_SELF_WORKTREE CM_IGNORE_UNTRACKED CM_SSH_TARGET CM_LEDGER
  export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_TEST=1
  STUB="$ROOT/stub"; BIN="$ROOT/bin"
  mkdir -p "$HOME" "$CM_HOME/cache" "$STUB" "$BIN"
  printf '[{"name":"acme-app","isArchived":false},{"name":"other-app","isArchived":false}]\n' > "$CM_HOME/cache/org-repos.json"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export STUB
  export CM_HOST_TIMEOUT=10 CM_GIT_TIMEOUT=6
  cat > "$BIN/orca" <<'STUBEOF'
#!/usr/bin/env bash
# stub orca: answers from $STUB, runs a created terminal's command locally.
set -uo pipefail
host=local; args=("$@"); cmd=""; handle=""; title=""
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --environment) host="${args[$((i + 1))]}" ;;
    --command) cmd="${args[$((i + 1))]}" ;;
    --terminal) handle="${args[$((i + 1))]}" ;;
    --title) title="${args[$((i + 1))]}" ;;
  esac
  i=$((i + 1))
done
echo "$1 $2 host=$host handle=$handle" >> "$STUB/calls.log"
case "$1 $2" in
  "host list") cat "$STUB/hosts.json" ;;
  "worktree ps")
    [ -f "$STUB/ps-$host.json" ] || { echo '{"ok":false,"error":{"message":"host unreachable"}}'; exit 1; }
    cat "$STUB/ps-$host.json" ;;
  "terminal list")
    for f in "$STUB"/term_"$host"_*.open; do
      [ -e "$f" ] || continue
      b="$(basename "$f" .open)"; printf '%s\t%s\n' "$b" "$(cat "$STUB/$b.title" 2>/dev/null)"
    done | jq -Rsc '{ok:true, result:{terminals:(split("\n") | map(select(. != "") | split("\t") | {handle: .[0], title: (.[1] // "")})), truncated:false}}' ;;
  "terminal create")
    if [ -f "$STUB/create-fail-$host" ]; then echo '{"ok":false,"error":{"message":"orca runtime for host not reachable"}}'; exit 1; fi
    n=$(( $(cat "$STUB/term.seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/term.seq"
    h="term_${host}_$n"
    {
      printf '$ %s\r\n' "$cmd"
      if [ ! -f "$STUB/hang-$host" ]; then bash -c "$cmd" 2>&1 | sed 's/[ ]*$//; s/$/\r/'; fi   # a terminal drops trailing spaces
    } > "$STUB/$h.out"
    touch "$STUB/$h.open"; printf '%s' "$title" > "$STUB/$h.title"
    if [ -f "$STUB/lose-handle-$host" ]; then echo '{"ok":false,"error":{"message":"create timed out"}}'; exit 1; fi
    printf '{"ok":true,"result":{"terminal":{"handle":"%s"}}}\n' "$h" ;;
  "terminal read")
    [ -f "$STUB/$handle.open" ] || { echo '{"ok":false,"error":{"message":"no such terminal"}}'; exit 1; }
    jq -Rs '{ok:true, result:{terminal:{tail:(split("\n"))}}}' "$STUB/$handle.out" ;;
  "terminal close")
    if [ -f "$STUB/close-fail-$host" ]; then echo '{"ok":false,"error":{"message":"close failed"}}'; exit 1; fi
    rm -f "$STUB/$handle.open"; echo '{"ok":true,"result":{"closed":true}}' ;;
  *) echo '{"ok":false,"error":{"message":"stub: unhandled"}}'; exit 1 ;;
esac
STUBEOF
  chmod +x "$BIN/orca"
  # ssh stub: fails like an unreachable Mac unless $STUB/ssh-ok-<target> exists, then runs the stdin script locally.
  cat > "$BIN/ssh" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
echo "ssh $*" >> "$STUB/calls.log"
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac; done
target="$1"; shift
[ -f "$STUB/ssh-ok-$target" ] || { echo "ssh: connect to host $target port 22: Connection refused" >&2; exit 255; }
exec sh -c "$*"   # real ssh joins the words and the remote shell parses them again
STUBEOF
  chmod +x "$BIN/ssh"
  export PATH="$BIN:$PATH" ORCA_CLI_COMMAND="$BIN/orca"
  : > "$STUB/calls.log"
}

# census_repo <dir>: clone of a bare origin; main pushed, one tracked file.
census_repo() {
  local dir="$1" bare="$1.origin.git"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$dir" 2>/dev/null
  git -C "$dir" checkout -q -b main 2>/dev/null || true
  printf 'one\n' > "$dir/tracked.txt"
  git -C "$dir" add tracked.txt
  git -C "$dir" commit -q -m init
  git -C "$dir" push -q origin main 2>/dev/null
}

# census_worktree <repo> <dir> <branch>
census_worktree() { git -C "$1" worktree add -q -b "$3" "$2" main 2>/dev/null; }

census_hosts() {
  local out='{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine","id":"local"}'
  local h
  for h in "$@"; do out="$out"',{"kind":"environment","name":"'"$h"'","id":"'"$h"'"}'; done
  printf '%s]}}\n' "$out" > "$STUB/hosts.json"
}

# census_row <repo> <path> <branch> [main]
census_row() {
  jq -cn --arg repo "$1" --arg p "$2" --arg b "$3" --arg main "${4:-}" '
    {worktreeId: ($repo + "::" + $p), repoId: $repo, repo: $repo, path: $p, branch: $b,
     displayName: ($p | split("/") | last), isMainWorktree: ($main == "main"), status: "idle",
     comment: "", liveTerminalCount: 0, agents: []}'
}

# census_ps <host|local> <row>...
census_ps() {
  local host="$1"; shift
  printf '%s\n' "$@" | jq -sc '{ok:true, result:{totalCount:length, truncated:false, worktrees:.}}' > "$STUB/ps-$host.json"
}

census_discover() { "$SCRIPTS/discover.sh" --no-prs "$@"; }
