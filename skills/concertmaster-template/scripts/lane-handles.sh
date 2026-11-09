#!/usr/bin/env bash
# lane-handles.sh: refresh each lane's handle file from the LIVE agent process, or read it.
#
#   scripts/lane-handles.sh                    # every non-dead ledger worker with a worktree
#   scripts/lane-handles.sh --worker <id>      # one worker (the ledger key, e.g. w-lane-a)
#   scripts/lane-handles.sh --dry-run          # same decisions, nothing written
#   scripts/lane-handles.sh --quiet            # no table on stdout (the reader's re-check)
#   scripts/lane-handles.sh --get <id>         # print the handle every terminal send must use
#
# A ledger terminal handle goes stale after a restart or a moved terminal, and a send that trusted one
# reached the wrong terminal or started a second agent in a live lane. This writes
# $CM_HOME/lanes/<worker-id>/handle (lib.sh, "per-lane handle file") from scripts/live-agent.sh, which
# reads ORCA_TERMINAL_HANDLE out of the agent's own /proc environment. A terminal send to a lane
# reads it through cm_lane_handle (lib.sh) or `--get`; a missing, empty, stale or unparsable file is re-checked
# (`--worker <id>`) and refused (exit 3) when that still gives no verified live agent: the ledger handle
# is never a fallback. Run it before a send that must reach a lane's current terminal, or once per tick.
#
# The file is keyed by the ledger worker id, not by the `lane` field: a lane is a group (a standing sweeper
# with its spawned children, epic:* lanes have several rows), a worker id is one agent.
# Per worker (ledger workers with a path, host defaulting to local, never a dead record), by what
# live-agent.sh finds:
#   one agent, one handle      refreshed: the file holds that handle (and the ledger terminal is
#                              brought in line when it differs)
#   no agent                   none: the file is MARKED dead ("-"), not removed. A missing file means
#                              "never checked" (a read re-checks it, then refuses if it cannot verify);
#                              a dead mark means "checked, nothing there" and sends stop
#   two agents, or one with    duplicate / no-handle: marked dead. Send to neither (rule 4)
#   and one without a handle
#   handle held by another     held: marked dead, every claimant (an agent started from someone else's
#   worker (ledger terminal,   terminal inherits THAT terminal's handle). Held = another worker's ledger
#   live in this run, or a     terminal, live in this run for two workers, or the fresh file of a worker
#   fresh file)                not looked at in this run
#   live-agent.sh cannot       unknown: the file is left as it is. It ages out, and a stale file is
#   tell (no /proc, ssh down)  never trusted for a send. The same row when the ledger cannot be read
#   while the run asks who else holds the handle: no write on a guess, and the run exits 1
#   two ids equal ignoring    ambiguous: marked dead (a case-insensitive file system would share one
#   case                      directory)
#   id not a plain token, or  invalid: no file (a newline in a ledger key would split its row and could
#   a control character in    hand one worker another's handle)
#   host, path or terminal
#   worker no longer a live   gone: its file is removed (full runs only), but only when the ledger
#   ledger record             could be READ and says so
#   ledger cannot be read     kept: the file is left as it is, one line each, and the run exits 1
#   while the run goes on     (a jq error is not an answer: "not a live record" is never guessed)
#   write did not land        failed: the old file is removed or marked, never served
# The file's written-at is when the agent was seen (phase 1), not when phase 3 wrote it.
#   newer observation on file superseded: not overwritten, and the ledger terminal is not touched
# A FRESH file (younger than handles.max_age_s) is served without a full live look, but for a local agent
# the reader still requires its pid to exist and to hold the file's handle (/proc/<pid>/environ); a file
# that fails that is stale. Stale, missing, empty or unparsable files are re-checked on read. Handles
# starting with "-" are refused everywhere; lane directories are 0700 and a symlinked one is refused.
#
# Output (TSV): id  handle  result  detail. Exit 0, 2 on usage (including an empty id), 1 when the ledger is
# unreadable (at the start, or part way through the run: then the files it would have judged are kept), jq or live-agent.sh is
# missing, or no temp dir can be made (stderr says which, even with --quiet), 3 when
# --worker names a worker whose lane directory is reached through a symlink (not verifiable).
# --get exits as cm_lane_handle does: 0 handle printed, 1 no live agent, 2 usage, 3 not verifiable.
# CM_HOME, CM_LEDGER, CM_LIVE_AGENT (tests: needs CM_TEST=1), CM_PROC_ROOT (tests, via live-agent.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0; QUIET=0; ONLY=""; GET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --quiet) QUIET=1 ;;
    --worker) [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "lane-handles.sh: --worker needs a non-empty id"; exit 2; }; ONLY="$2"; shift ;;
    --get) [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "lane-handles.sh: --get needs a non-empty worker id (an empty one would print the whole table)"; exit 2; }; GET="$2"; shift ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) cm_warn "lane-handles.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

if [ -n "$GET" ]; then cm_lane_handle "$GET"; exit $?; fi
if [ -n "$ONLY" ]; then
  case "$ONLY" in .*|*[!A-Za-z0-9._-]*) cm_warn "lane-handles.sh: \"$ONLY\" is not a worker id"; exit 2 ;; esac
  cm_lane_dir "$ONLY" >/dev/null || exit 3   # a symlinked lanes/ or lanes/<id>: not verifiable, as --get says
fi
# A symlinked lanes/ or lanes/.failed is never read or deleted through (the glob loops below skip it)
LANES_OK=1; if [ -L "$CM_HOME/lanes" ] || [ -L "$CM_HOME/lanes/.failed" ]; then LANES_OK=0; fi

command -v jq >/dev/null 2>&1 || { cm_warn "lane-handles.sh: missing dependency: jq"; exit 1; }
LEDGER="$(cm_ledger_path)"
if ! { [ -s "$LEDGER" ] && jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1; }; then
  cm_warn "lane-handles.sh: ledger $LEDGER missing or unreadable: nothing refreshed"; exit 1
fi

LIVE_AGENT="$HERE/live-agent.sh"
if [ -n "${CM_LIVE_AGENT:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then LIVE_AGENT="$CM_LIVE_AGENT"; else cm_warn "lane-handles.sh: CM_LIVE_AGENT ignored (it needs CM_TEST=1)"; fi
fi

# Without the observer every worker would read "unknown" and --quiet would hide it: a missing observer is a failure.
if [ ! -x "$LIVE_AGENT" ]; then cm_warn "lane-handles.sh: $LIVE_AGENT is missing or not executable: no lane can be observed"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-lane-handles.XXXXXX")" || { cm_warn "lane-handles.sh: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

# id, host, path, ledger terminal, dup flag, id (unit-separator joined), non-dead workers that have a path
# Rows are one line each, so a key, host, path or terminal holding a control character (a newline would
# split one row into two and forge a worker id) is never put in the row list. \A and \z, not ^ and $: in
# Oniguruma those match at every line break. The refused ones are listed apart, JSON-quoted, and reported.
JQ_WORKERS="$CM_JQ_STATE_DEFS"'
  [ (.workers // {}) | to_entries[] | select(.value | type == "object")
    | select((.value.state // "running") | cm_state_dead | not)
    | { id: .key, host: (.value.host // "local"),
        path: (.value.path // .value.worktree // .value.worktreePath // ""), term: (.value.terminal // "") }
    | select(.path != "")
    | . + { ok: (((.id | type) == "string") and (.id | test("\\A[A-Za-z0-9_-][A-Za-z0-9._-]*\\z"))
        and ([.host, .path, .term] | all(type == "string" and (test("[[:cntrl:]]") | not)))) } ]'
jq -r "$JQ_WORKERS"'
  | map(select(.ok)) | (map(.id | ascii_downcase) | group_by(.) | map(select(length > 1) | .[0])) as $dup
  | .[] | [ .id, .host, .path, .term, (if ((.id | ascii_downcase) | IN($dup[])) then "dup" else "" end), .id ] | join("\u001f")' "$LEDGER" > "$TMP/rows.tsv" 2>/dev/null \
  || { cm_warn "lane-handles.sh: cannot read the workers in $LEDGER"; exit 1; }
jq -r "$JQ_WORKERS"' | .[] | select(.ok | not) | .id | @json' "$LEDGER" 2>/dev/null > "$TMP/refused.txt" || true

emit() { [ "$QUIET" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
if [ -z "$ONLY" ]; then
  while IFS= read -r bad; do emit "$bad" - invalid "not a usable worker id, or a control character in its host, path or terminal: no file"; done < "$TMP/refused.txt"
fi
# write <id> <handle|-> <host> <agent> <pid>: honours --dry-run
put() { [ "$DRY" = 1 ] && return 0; cm_lane_handle_write "$@"; }   # rc 3: a newer observation is already on file

# ---- phase 1: look at every worker, decide, write nothing -----------------------------------------
# dec.tsv (unit-separator joined): id, host, path, ledger terminal, worker id, kind, handle, agent, pid, result, detail
US=$'\037'
decide() { printf '%s\n' "$(IFS=$US; printf '%s' "$*" "${US}${OBS:-}")" >> "$TMP/dec.tsv"; }   # lane host path term id kind handle agent pid result detail, then the time the agent was observed
: > "$TMP/dec.tsv"
while IFS=$US read -r lane host path term dup id <&3; do   # unit separator: an empty field must stay empty
  [ -n "$lane" ] || continue
  if [ -n "$ONLY" ] && [ "$lane" != "$ONLY" ]; then continue; fi
  OBS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$lane" in .*|*[!A-Za-z0-9._-]*) emit "$lane" - invalid "not a usable worker id: no file"; continue ;; esac
  if [ -n "$dup" ]; then decide "$lane" "$host" "$path" "$term" "$id" dead - - - ambiguous "two worker ids differ only by case: marked dead, no send"; continue; fi
  # CM_SSH_TARGET and CM_SSH_EXPECT_HOSTNAME name ONE host; a multi-host run must not apply them to all
  OBS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"   # the file records when the agent was looked at, not when phase 3 gets to write it
  out="$(env -u CM_SSH_TARGET -u CM_SSH_EXPECT_HOSTNAME "$LIVE_AGENT" "$path" --host "$host" 2>"$TMP/err")"; rc=$?
  case "$rc" in
    0) ;;
    1) decide "$lane" "$host" "$path" "$term" "$id" dead - - - none "no live agent in $path: marked dead, no send"; continue ;;
    *) emit "$lane" - unknown "live check could not run (exit $rc: $(head -c 100 "$TMP/err" | tr '\t\n' '  ')): file left as it is"; continue ;;
  esac
  handles="$(printf '%s\n' "$out" | cut -f2 | grep -v '^$' | sort -u)"
  nh="$(printf '%s' "$handles" | grep -c . || true)"
  blank=0; if printf '%s\n' "$out" | awk -F'\t' '$2 == "" { f = 1 } END { exit !f }'; then blank=1; fi
  if [ "$nh" -ge 2 ] || { [ "$nh" -ge 1 ] && [ "$blank" = 1 ]; }; then
    decide "$lane" "$host" "$path" "$term" "$id" dead - - - duplicate "several agent processes: marked dead, send to none, ask the owner"; continue
  fi
  if [ "$nh" = 0 ]; then
    decide "$lane" "$host" "$path" "$term" "$id" dead - - - no-handle "agent running without an Orca terminal handle: marked dead, no send"; continue
  fi
  # several processes can share the handle (a launcher beside the agent): record the lowest pid, the parent
  first="$(printf '%s\n' "$out" | sort -n -k1,1 | head -n 1)"
  pid="$(printf '%s\n' "$first" | cut -f1)"; agent="$(printf '%s\n' "$first" | cut -f3)"
  decide "$lane" "$host" "$path" "$term" "$id" live "$handles" "$agent" "$pid" refreshed "live agent pid $pid"
done 3< "$TMP/rows.tsv"

# ---- phase 2: one handle may belong to one worker ----------------------------------------------------
# An agent started from someone else's terminal inherits THAT terminal's ORCA_TERMINAL_HANDLE. A handle is
# held when (a) another worker's ledger row has it as its terminal, (b) another worker in this run found it
# live, or (c) another worker's FRESH handle file (a worker not looked at in this run) holds it. Every worker that
# claims a held handle is marked dead.
# live_record <id>: is there a non-dead worker with that id in the ledger? THREE answers, never two:
#   0 live      jq ran and said true
#   1 not live  jq ran and said false (a dead record), or the worker is absent from a readable ledger
#   2 unknown   the ledger could not be read, or jq failed (any exit status but 0 or 1, or no answer): jq -e exits 2 or more for an error,
#               and an error is NOT "the worker is gone". Callers that delete or claim on "not live" must not do it on 2.
# A ledger that is not ONE object with an object .workers (two documents, null, {}) raises an error here, so it is unknown,
# never "every worker is gone". A normal ledger answers exactly as before.
LH_JQ_WORKERS='def lh_workers: if length == 1 and (.[0] | type == "object" and (.workers | type) == "object") then .[0].workers else error("the ledger is not one object with a workers object") end; '
live_record() {
  local out rc
  out="$(jq -e -s --arg id "$1" "$CM_JQ_STATE_DEFS$LH_JQ_WORKERS"'lh_workers[$id] | type == "object" and ((.state // "running") | cm_state_dead | not)' "$LEDGER" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) [ "$out" = true ] && return 0; return 2 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}
# an unknown answer is counted in a file (held_by runs in a command substitution, where a variable would be lost) and ends the run with exit 1
note_unknown() { printf '%s\n' "$1" >> "$TMP/unknown.txt"; }
# held_by <id> <handle>: prints the other worker that holds the handle, if there is one. READ THE EXIT STATUS, not only the output:
#   0  the answer is complete: a holder printed, or nobody holds it
#   2  nothing printed and a check could not run (the ledger could not be read): the caller must not write on a guess
held_by() {
  local l="$1" h="$2" o f ln max now fhost fpid fr ts lr rc unk=0
  # a finished record (gone, repurposed, torn-down) no longer owns its terminal handle: only a non-dead worker holds one
  o="$(jq -r -s --arg l "$l" --arg h "$h" "$CM_JQ_STATE_DEFS$LH_JQ_WORKERS"'[ lh_workers | to_entries[] | select(.value | type == "object")
      | select((.value.state // "running") | cm_state_dead | not)
      | select(.key != $l and .value.terminal == $h) | .key ] | .[0] // empty' "$LEDGER" 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] || unk=1   # jq failed: that is not "nobody holds it"
  [ -z "$o" ] || { printf '%s (ledger terminal)' "$o"; return; }
  o="$(awk -F"$US" -v l="$l" -v h="$h" '$6 == "live" && $7 == h && $1 != l { print $1; exit }' "$TMP/dec.tsv")"
  [ -z "$o" ] || { printf '%s (live in this run)' "$o"; return; }
  max="$(cm_lane_handle_max_age)"; now="$(date +%s)"
  for f in "$CM_HOME"/lanes/*/handle; do
    [ "$LANES_OK" = 1 ] || break
    [ -s "$f" ] || continue
    ln="${f%/handle}"; ln="${ln##*/}"; [ "$ln" != "$l" ] || continue
    [ ! -L "${f%/handle}" ] || continue   # a symlinked lane directory is never read through
    [ ! -e "$CM_HOME/lanes/.failed/$ln" ] || continue   # a failed write on record: that file is not trusted
    [ "$(cut -f1 "$f")" = "$h" ] || continue   # cheap test first: only a file with this very handle can hold it
    live_record "$ln"; lr=$?
    if [ "$lr" = 2 ]; then unk=1; continue; fi   # cannot tell whether that file's worker holds it
    [ "$lr" = 0 ] || continue   # a gone or torn-down worker holds nothing (its file is removed by phase 4 of a full run)
    # a local agent that has exited (or whose pid now carries another terminal) holds nothing either: the same
    # test the reader applies, so a reused terminal is not "held" by the dead agent that used to have it
    IFS=$'\t' read -r _ fhost _ fpid _ < "$f" || true
    if [ "${fhost:-local}" = local ]; then case "$fpid" in ''|-|*[!0-9]*) ;; *) _cm_lane_agent_alive "$fpid" "$h"; fr=$?; if [ "$fr" = 1 ] || [ "$fr" = 2 ]; then continue; fi ;; esac; fi
    awk -F"$US" -v w="$ln" '$1 == w { f = 1 } END { exit !f }' "$TMP/dec.tsv" && continue   # looked at in this run: its decision counts, not its old file
    ts="$(jq -rn --arg t "$(cut -f5 "$f")" '$t | fromdateiso8601' 2>/dev/null)"
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    [ $((now - ts)) -le "$max" ] || continue
    printf '%s (fresh handle file)' "$ln"; return
  done
  [ "$unk" = 0 ] || return 2   # no holder FOUND, but a check could not run: the caller must not write on a guess
  return 0
}

# ---- phase 3: write ------------------------------------------------------------------------------
while IFS=$US read -r lane host path term id kind handle agent pid result detail obs <&4; do
  if [ "$kind" = live ]; then
    other="$(held_by "$lane" "$handle")"; hrc=$?
    if [ "$hrc" = 2 ]; then note_unknown "$lane"; emit "$lane" - unknown "ledger unreadable: cannot tell whether another worker holds handle $handle, file left as it is"; continue; fi
    if [ -n "$other" ]; then kind=dead; result=held; detail="live handle $handle is also worker $other: marked dead, no send"; handle=-; fi
  fi
  if [ "$kind" = dead ]; then
    put "$lane" - "$host" - - "$obs"; prc=$?
    case "$prc" in 0) emit "$lane" - "$result" "$detail" ;; 3) emit "$lane" - superseded "a newer observation is on file: not overwritten" ;; 4) emit "$lane" - busy "another writer holds the lane lock: not written, file left as it is" ;; *) emit "$lane" - failed "could not write the lane file" ;; esac
    continue
  fi
  put "$lane" "$handle" "$host" "$agent" "$pid" "$obs"; prc=$?
  if [ "$prc" = 3 ]; then emit "$lane" - superseded "a newer observation is on file: not overwritten, ledger not touched"; continue; fi
  if [ "$prc" = 4 ]; then emit "$lane" - busy "another writer holds the lane lock: not written, file left as it is"; continue; fi
  if [ "$prc" != 0 ]; then emit "$lane" "$handle" failed "could not write the lane file"; continue; fi
  if [ "$term" != "$handle" ] && [ "$DRY" = 0 ]; then
    if cm_worker_set_handle "$id" "$handle" 2>/dev/null; then detail="$detail, ledger terminal ${term:-none} brought to $handle"
    else detail="$detail, ledger terminal ${term:-none} left (refresh refused)"; fi
  fi
  emit "$lane" "$handle" "$result" "$detail"
done 4< "$TMP/dec.tsv"

# ---- phase 4: a file whose worker is no longer a live ledger record is removed ------------------------
# A gone or torn-down worker (or an id the ledger never held) keeps no handle: a removed file reads as
# "missing", which the reader re-checks and then refuses (exit 3), so nothing is sent to a finished worker.
# Only a full run does this: --worker looks at one id.
if [ -z "$ONLY" ] && [ "$LANES_OK" = 1 ]; then
  for f in "$CM_HOME"/lanes/*/handle; do
    [ -e "$f" ] || continue
    ln="${f%/handle}"; ln="${ln##*/}"
    awk -F"$US" -v w="$ln" '$1 == w { f = 1 } END { exit !f }' "$TMP/dec.tsv" && continue
    [ ! -L "${f%/handle}" ] || continue   # never delete through a symlinked lane directory
    live_record "$ln"; lr=$?
    if [ "$lr" = 0 ]; then continue; fi
    if [ "$lr" = 2 ]; then note_unknown "$ln"; emit "$ln" - kept "ledger unreadable: the file is left as it is"; continue; fi   # an error is not "gone"
    if [ "$DRY" = 1 ]; then emit "$ln" - gone "worker is not a live ledger record: its file would be removed"; continue; fi
    rm -f -- "${CM_HOME:?}/lanes/.failed/$ln" 2>/dev/null   # a failure marker dies with the worker's file
    if rm -f -- "$f"; then emit "$ln" - gone "worker is not a live ledger record: file removed"; else emit "$ln" - failed "could not remove the file of a finished worker"; fi
  done
  # Debris of an interrupted write: temp files older than 5 minutes (a live write finishes in milliseconds),
  # and failure markers whose worker is no longer a live ledger record. Never through a symlink.
  if [ "$DRY" != 1 ]; then
    for d in "$CM_HOME"/lanes/*/; do
      d="${d%/}"; [ -d "$d" ] && [ ! -L "$d" ] || continue
      find "$d" -maxdepth 1 -type f -name '.handle.*' -mmin +5 -delete 2>/dev/null
    done
    for m in "$CM_HOME"/lanes/.failed/*; do
      [ -e "$m" ] && [ ! -L "$m" ] || continue
      ln="${m##*/}"
      live_record "$ln"; lr=$?
      if [ "$lr" = 2 ]; then note_unknown "$ln"; emit "$ln" - kept "ledger unreadable: the failure marker is left as it is"; continue; fi
      [ "$lr" = 0 ] || rm -f -- "$m"
    done
  fi
fi
# "could not look" ends the run the way an unreadable ledger at the start does: exit 1, with stderr saying so (even with --quiet)
if [ -s "$TMP/unknown.txt" ]; then
  cm_warn "lane-handles.sh: the ledger could not be read part way through the run: $(sort -u "$TMP/unknown.txt" | wc -l | tr -d ' ') worker(s) could not be judged, a file that was to be judged is left as it is (exit 1)"
  exit 1
fi
exit 0
