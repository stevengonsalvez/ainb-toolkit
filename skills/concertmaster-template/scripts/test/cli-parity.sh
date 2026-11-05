#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# cli-parity.sh (test): do the Orca CLI and the Plugly CLI answer with the JSON fields the scripts read? READ-ONLY:
# `host list`, `worktree list` and `terminal list` (all --json), plus one `terminal read` of a listed terminal. Nothing
# is written, created, sent or closed. Each CLI is resolved through cm_cli (CM_CLI_KIND=orca, then plugly), so
# ORCA_CLI_COMMAND and PLUGLY_CLI_COMMAND apply. It needs both CLIs on this host and a running runtime for each;
# when a CLI is missing or does not answer, the live part is skipped (exit 0, a message).
#
# What is checked (a FAIL):
#   hosts      .ok true, .result.hosts an array, every row has id, kind, name        (discover, abrupt, fleet-read)
#   worktrees  .result.worktrees an array, every row has id, path, displayName, comment   (fleet-read, fleet-state)
#   terminals  .result.terminals an array, every row has handle, worktreePath (agentIdentity, lastOutputAt and title
#              are read with defaults: a NOTE when no row carries one)
#   tail       `terminal read --terminal <first handle>` carries .result.terminal.tail   (pane-stalls, spawn-verify)
# A row field counts as present when the key exists, even with a null or empty value (a comment is often empty).
# An empty list proves no field and is reported as such, not as a failure.
#
#   selector   `worktree list` and `terminal list` with the local-host selector cm_cli_host prints (a flag the CLI rejects fails)
#
# What is only REPORTED (never a FAIL): the difference between the two CLIs. For each list, the field NAMES one CLI
# has and the other lacks, and the row COUNTS; for hosts also how many host names only one CLI knows (the two CLIs may list
# different hosts). Names of hosts, worktrees and terminals are never printed.
#
# The checker is also proven on synthetic JSON (a row without `path` must fail), so the "a missing field fails" rule
# holds on a host with no CLI at all.
#
#   scripts/test/cli-parity.sh     # exit 0 when every check passes or the live part is skipped
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-cli-parity.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
note() { printf 'NOTE %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# The fields the scripts read, per list.
HOSTS_FIELDS='id kind name'
WT_FIELDS='id path displayName comment'
TERM_FIELDS='handle worktreePath'
# Read with a default (`.agentIdentity // ""`): a plain shell terminal has no agentIdentity key, so these are not
# required on every row. They only have to show up on some row, which is reported as a NOTE, never a FAIL.
TERM_SEEN_FIELDS='agentIdentity lastOutputAt title'

# check_list <file> <array path> <required fields> -> prints "ok <rows>" | "empty" | "bad <why>"; rc 0 / 1
check_list() {
  local f="$1" path="$2" fields="$3" out
  out="$(jq -r --argjson need "$(printf '%s\n' $fields | jq -R . | jq -sc .)" "
    if .ok != true then \"bad .ok is not true\"
    elif (${path} | type) != \"array\" then \"bad $path is not an array\"
    elif (${path} | length) == 0 then \"empty\"
    else ([${path}[] | . as \$r | \$need[] | . as \$f | select(\$r | has(\$f) | not)] | unique) as \$miss
      | if (\$miss | length) > 0 then \"bad missing field(s): \" + (\$miss | join(\", \")) else \"ok \" + ((${path} | length) | tostring) end
    end" "$f" 2>/dev/null)" || out="bad not JSON"
  printf '%s\n' "$out"
  case "$out" in ok*|empty) return 0 ;; *) return 1 ;; esac
}

# ---- the checker itself, on synthetic JSON (no CLI needed) ------------------------------------------
SYN="$ROOT/syn"; mkdir -p "$SYN"
printf '{"ok":true,"result":{"worktrees":[{"id":"w1","path":"/p/a","displayName":"a","comment":""}]}}' > "$SYN/good.json"
printf '{"ok":true,"result":{"worktrees":[{"id":"w1","displayName":"a","comment":""}]}}' > "$SYN/nopath.json"
printf '{"ok":true,"result":{"worktrees":[{"id":"w1","path":"/p/a","displayName":"a"}]}}' > "$SYN/nocomment.json"
printf '{"ok":true,"result":{"worktrees":[]}}' > "$SYN/empty.json"
printf '{"ok":false,"error":{"message":"x"}}' > "$SYN/refused.json"
printf '{"ok":true,"result":{"worktrees":{}}}' > "$SYN/notarray.json"
printf 'not json' > "$SYN/garbage.json"
out="$(check_list "$SYN/good.json" .result.worktrees "$WT_FIELDS")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "ok 1" ] && pass "checker: a complete row passes (an empty comment counts as present)" || fail "checker good" "rc=$rc $out"
out="$(check_list "$SYN/nopath.json" .result.worktrees "$WT_FIELDS")"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "bad missing field(s): path" ] && pass "checker: a row without path FAILS and names the field" || fail "checker nopath" "rc=$rc $out"
out="$(check_list "$SYN/nocomment.json" .result.worktrees "$WT_FIELDS")"; rc=$?
[ "$rc" = 1 ] && case "$out" in *comment*) true ;; *) false ;; esac && pass "checker: a row without comment FAILS" || fail "checker nocomment" "rc=$rc $out"
out="$(check_list "$SYN/empty.json" .result.worktrees "$WT_FIELDS")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = empty ] && pass "checker: an empty list proves nothing and does not fail" || fail "checker empty" "rc=$rc $out"
out="$(check_list "$SYN/refused.json" .result.worktrees "$WT_FIELDS")"; rc=$?
[ "$rc" = 1 ] && pass "checker: ok:false FAILS" || fail "checker refused" "rc=$rc $out"
out="$(check_list "$SYN/notarray.json" .result.worktrees "$WT_FIELDS")"; rc=$?
[ "$rc" = 1 ] && pass "checker: a non-array list FAILS" || fail "checker notarray" "rc=$rc $out"
out="$(check_list "$SYN/garbage.json" .result.worktrees "$WT_FIELDS")"; rc=$?
[ "$rc" = 1 ] && pass "checker: non-JSON FAILS" || fail "checker garbage" "rc=$rc $out"

# ---- the live part ------------------------------------------------------------------------------------
export CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH CM_LEDGER CM_CLI_KIND
resolve_cli() { # <kind> -> the command, or nothing when it is not on this host
  local c
  c="$(CM_CLI_KIND="$1" bash -c ". '$S/lib.sh'; cm_cli" 2>/dev/null)" || return 0
  [ -n "$c" ] || return 0
  command -v "$c" >/dev/null 2>&1 && printf '%s\n' "$c"
  return 0
}
ORCA_CMD="$(resolve_cli orca)"; PLUGLY_CMD="$(resolve_cli plugly)"
if [ -z "$ORCA_CMD" ] || [ -z "$PLUGLY_CMD" ]; then
  missing=""; [ -n "$ORCA_CMD" ] || missing="orca"; [ -n "$PLUGLY_CMD" ] || missing="$missing plugly"
  note "skipped the live part: CLI not found on this host:$missing"
  printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
  [ "$FAIL" = 0 ]; exit $?
fi

# grab <kind> <cmd> <name> <args...>: run one read-only call, keep stdout in $ROOT/<kind>.<name>.json
grab() {
  local kind="$1" cmd="$2" name="$3"; shift 3
  if cm_timeout "${CM_PARITY_TIMEOUT:-60}" "$cmd" "$@" </dev/null > "$ROOT/$kind.$name.json" 2>"$ROOT/$kind.$name.err" && jq -e . "$ROOT/$kind.$name.json" >/dev/null 2>&1; then return 0; fi
  return 1
}
# shellcheck source=SCRIPTDIR/../lib.sh
. "$S/lib.sh"

LIVE=1
for kind in orca plugly; do
  if [ "$kind" = orca ]; then cmd="$ORCA_CMD"; else cmd="$PLUGLY_CMD"; fi
  if ! grab "$kind" "$cmd" hosts host list --json; then
    note "skipped the live part: the $kind CLI did not answer host list (is its runtime up?)"; LIVE=0; break
  fi
done
if [ "$LIVE" = 0 ]; then
  printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
  [ "$FAIL" = 0 ]; exit $?
fi

for kind in orca plugly; do
  if [ "$kind" = orca ]; then cmd="$ORCA_CMD"; else cmd="$PLUGLY_CMD"; fi
  grab "$kind" "$cmd" wt worktree list --json --limit 500 || fail "$kind worktree list" "the call failed: $(head -c 120 "$ROOT/$kind.wt.err")"
  grab "$kind" "$cmd" term terminal list --json --limit 500 || fail "$kind terminal list" "the call failed: $(head -c 120 "$ROOT/$kind.term.err")"
  for spec in "hosts:.result.hosts:$HOSTS_FIELDS" "wt:.result.worktrees:$WT_FIELDS" "term:.result.terminals:$TERM_FIELDS"; do
    name="${spec%%:*}"; rest="${spec#*:}"; apath="${rest%%:*}"; fields="${rest#*:}"
    [ -s "$ROOT/$kind.$name.json" ] || continue
    out="$(check_list "$ROOT/$kind.$name.json" "$apath" "$fields")"; rc=$?
    case "$name" in hosts) label="host list" ;; wt) label="worktree list" ;; *) label="terminal list" ;; esac
    if [ "$rc" = 0 ]; then
      case "$out" in
        empty) note "$kind $label: no rows, so no row field was checked" ;;
        *) pass "$kind $label: every row has [$fields] ($out rows)" ;;
      esac
    else fail "$kind $label" "$out"; fi
  done
  # the local-host selector the scripts would send (cm_cli_host), on a real call: a flag this CLI rejects fails here
  CM_CLI_KIND="$kind"; sel=(); cm_cli_host_into sel local
  for sub in "worktree list" "terminal list"; do
    # shellcheck disable=SC2086  # $sub is two words on purpose
    if grab "$kind" "$cmd" selcall $sub ${sel[@]+"${sel[@]}"} --limit 1 --json && jq -e '.ok == true' "$ROOT/$kind.selcall.json" >/dev/null 2>&1; then
      pass "$kind $sub accepts the local-host selector [${sel[*]-}]"
    else fail "$kind $sub with the local-host selector [${sel[*]-}]" "$(jq -r '.error.message // empty' "$ROOT/$kind.selcall.json" 2>/dev/null | head -c 160)"; fi
  done
  if [ -s "$ROOT/$kind.term.json" ] && [ "$(jq '.result.terminals | length' "$ROOT/$kind.term.json" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    for fld in $TERM_SEEN_FIELDS; do
      jq -e --arg f "$fld" 'any(.result.terminals[]; has($f))' "$ROOT/$kind.term.json" >/dev/null 2>&1 \
        || note "$kind terminal list: no row carries $fld (the scripts read it with a default)"
    done
  fi
  # tail: one terminal read of the first listed terminal (read-only)
  h="$(jq -r '.result.terminals[0].handle // empty' "$ROOT/$kind.term.json" 2>/dev/null)"
  if [ -z "$h" ]; then note "$kind terminal read: no terminal listed, so .result.terminal.tail was not checked"
  elif grab "$kind" "$cmd" tail terminal read --terminal "$h" --json; then
    if jq -e '.ok == true and (.result.terminal | has("tail"))' "$ROOT/$kind.tail.json" >/dev/null 2>&1; then pass "$kind terminal read: .result.terminal.tail is present"
    else fail "$kind terminal read" "no .result.terminal.tail"; fi
  else fail "$kind terminal read" "the call failed: $(head -c 120 "$ROOT/$kind.tail.err")"; fi
done

# ---- the report: differences between the two CLIs, field names and counts only -----------------------
printf '\n== parity report (reported, not a failure) ==\n'
fieldnames() { jq -r "[$2[]? | keys[]] | unique | .[]" "$1" 2>/dev/null; }
for spec in "hosts:.result.hosts:host list" "wt:.result.worktrees:worktree list" "term:.result.terminals:terminal list"; do
  name="${spec%%:*}"; rest="${spec#*:}"; apath="${rest%%:*}"; label="${rest#*:}"
  [ -s "$ROOT/orca.$name.json" ] && [ -s "$ROOT/plugly.$name.json" ] || continue
  fieldnames "$ROOT/orca.$name.json" "$apath" > "$ROOT/orca.$name.fields"
  fieldnames "$ROOT/plugly.$name.json" "$apath" > "$ROOT/plugly.$name.fields"
  only_o="$(comm -23 "$ROOT/orca.$name.fields" "$ROOT/plugly.$name.fields" | paste -sd, -)"
  only_p="$(comm -13 "$ROOT/orca.$name.fields" "$ROOT/plugly.$name.fields" | paste -sd, -)"
  no="$(jq "$apath | length" "$ROOT/orca.$name.json" 2>/dev/null)"; np="$(jq "$apath | length" "$ROOT/plugly.$name.json" 2>/dev/null)"
  printf '%s: rows orca=%s plugly=%s; fields only in orca: [%s]; only in plugly: [%s]\n' "$label" "${no:-?}" "${np:-?}" "$only_o" "$only_p"
done
if [ -s "$ROOT/orca.hosts.json" ] && [ -s "$ROOT/plugly.hosts.json" ]; then
  jq -r '.result.hosts[]? | .name' "$ROOT/orca.hosts.json" | sort -u > "$ROOT/orca.hostnames"
  jq -r '.result.hosts[]? | .name' "$ROOT/plugly.hosts.json" | sort -u > "$ROOT/plugly.hostnames"
  printf 'host list: %s host name(s) only orca knows, %s only plugly knows (names not printed)\n' \
    "$(comm -23 "$ROOT/orca.hostnames" "$ROOT/plugly.hostnames" | grep -c .)" "$(comm -13 "$ROOT/orca.hostnames" "$ROOT/plugly.hostnames" | grep -c .)"
fi

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
