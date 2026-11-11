#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2016  # check bodies are single-quoted on purpose: they are eval-ed later
# lane-health.sh (test): behaviour tests for scripts/lane-health.sh, scripts/cm-status.sh, the asleep state in
# roster.sh, and the lead refusal in teardown.sh. Stubbed orca and plugly CLIs (one script, the runtime is its name),
# stubbed ssh, hostname, uptime, last, journalctl, systemctl and curl, a fake /proc per host (CM_PROC_ROOT and
# CM_HEALTH_REMOTE_PROC_ROOT, CM_TEST=1), fake transcripts and a temp CM_HOME. Synthetic names only: lead-a, task-1,
# host-b. Covers: each status word, the reboot and preemption causes and hostEvents, a daemon restart, auto-resume once
# and verified (and never a second time), the settle wait, the lead teardown refusal, unknown-worker sleep and the
# lead-shaped unknown that is never slept, duplicate detection, alert dedup, the sleep and wake subcommands, roster.sh
# skipping asleep rows, lead mode (--lead, --line) and the cm-status view. Nothing outside the mktemp dir; no network.
#
#   scripts/test/lane-health.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE \
      CM_SSH_TARGET CM_LEDGER CM_IGNORE_UNTRACKED CM_CLI_KIND ORCA_CLI_COMMAND PLUGLY_CLI_COMMAND CM_HEALTH_SEND CM_PROJECT_ID
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-lane-health.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
for t in jq yq git; do command -v "$t" >/dev/null 2>&1 || { echo "missing dependency: $t" >&2; exit 1; }; done
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_TEST=1
STUB="$ROOT/stub"; BIN="$ROOT/bin"; P="$ROOT/proc"; PR="$ROOT/proc-b"; W="$ROOT/acme"; DEAD="$ROOT/dead"
PROJ="$HOME/.claude/projects"
mkdir -p "$HOME" "$CM_HOME/cache" "$STUB" "$BIN" "$P" "$PR" "$W" "$DEAD" "$PROJ"
export STUB P PR DEAD PROJ
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | head -n 40; }
check() { if (eval "$2"); then ok "$1"; else bad "$1" "${3:-}"; fi; }

# ---- config ---------------------------------------------------------------------------------------
cat > "$ROOT/config.yaml" <<EOF
schema: concertmaster.config/v1
project: { name: Acme, owner: { name: Owner, id: owner } }
github: { org: AcmeOrg, main_repo: acme-app }
schedule: { timezone: UTC, timezone_label: UTC }
worktrees: { path_match: "/acme/", self_name: concertmaster, orca_repo: acme-app, never_touch: [other-thing] }
lanes:
  - { name: pr-sweeper, standing: true }
messaging: { owner_digest: { adapter: none, to: self, send: "true" } }
health:
  settle_minutes: 5
  stuck_minutes: 30
  cloud: gce
  daemon_units: [orca-serve.service]
EOF
export CM_CONFIG="$ROOT/config.yaml"

# ---- fake processes -------------------------------------------------------------------------------
# mkproc <root> <pid> <ppid> <cwd> <environ-kv|""> <argv...>: a pid dir as the kernel writes it (a pty, state S)
cat > "$ROOT/fake.sh" <<'EOF'
mkproc() {
  local root="$1" pid="$2" ppid="$3" cwd="$4" env="$5" tty="${FAKE_TTY:-34816}"; shift 5
  case "${1##*/}" in orca-serve|node) tty=0 ;; esac
  mkdir -p "$root/$pid"
  printf '%s (%s) S %s %s %s %s -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 1000 1\n' "$pid" "${1##*/}" "$ppid" "$pid" "$pid" "$tty" > "$root/$pid/stat"
  printf '%s\n' "${1##*/}" > "$root/$pid/comm"
  ln -sfn "$cwd" "$root/$pid/cwd"
  printf '%s\0' "$@" > "$root/$pid/cmdline"
  if [ -n "$env" ]; then printf 'HOME=/h\0%s\0' "$env" > "$root/$pid/environ"; else printf 'HOME=/h\0' > "$root/$pid/environ"; fi
}
munge() { printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g'; }
isoz() { jq -nr --argjson t "$1" '$t | todate'; }   # portable: no GNU date -d
transcript() { # <worktree> <sid> <epoch>
  mkdir -p "$PROJ/$(munge "$1")"; : > "$PROJ/$(munge "$1")/$2.jsonl"
  touch -t "$(jq -nr --argjson t "$3" '$t | localtime | strflocaltime("%Y%m%d%H%M.%S")')" "$PROJ/$(munge "$1")/$2.jsonl"
}
EOF
# shellcheck source=/dev/null
. "$ROOT/fake.sh"
NOW="$(date +%s)"
export CM_NOW="$NOW"
setboot() { printf 'cpu 1 2 3\nbtime %s\n' "$2" > "$1/stat"; }   # <proc root> <epoch>
runtimes() { # the two daemons every fake agent hangs off
  mkproc "$1" 1000 1 / "" /opt/orca/orca-serve --port 1
  mkproc "$1" 2000 1 / "" node /opt/plugly/daemon.js
}
reset_world() {
  local d
  for d in "$P" "$PR"; do mv "$d" "$DEAD/w.$RANDOM$RANDOM" 2>/dev/null; mkdir -p "$d"; runtimes "$d"; done
  setboot "$P" $((NOW - 86400)); setboot "$PR" $((NOW - 86400))
  mv "$STUB" "$DEAD/s.$RANDOM$RANDOM"; mkdir -p "$STUB"; : > "$STUB/calls.log"
  mv "$CM_HOME" "$DEAD/c.$RANDOM$RANDOM"; mkdir -p "$CM_HOME/cache"
  mv "$PROJ" "$DEAD/p.$RANDOM$RANDOM"; mkdir -p "$PROJ"
  printf '{"ok":true,"result":{"hosts":[{"kind":"local","name":"this machine"}]}}\n' > "$STUB/hosts.json"
}

# ---- stub CLI, one script for orca and plugly ---------------------------------------------------------
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$STUB/../fake.sh"
kind="$(basename "$0")"; host=local; cmd=""; handle=""; wt=""; comment=""
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --environment) host="${args[$((i + 1))]}" ;;
    --command) cmd="${args[$((i + 1))]}" ;;
    --terminal) handle="${args[$((i + 1))]}" ;;
    --worktree) wt="${args[$((i + 1))]}" ;;
    --comment) comment="${args[$((i + 1))]}" ;;
  esac
  i=$((i + 1))
done
echo "$kind $1 $2 host=$host handle=$handle wt=$wt cmd=$cmd" >> "$STUB/calls.log"
case "$1 $2" in
  "host list") cat "$STUB/hosts.json" ;;
  "worktree list") if [ -f "$STUB/wl-$host.json" ]; then cat "$STUB/wl-$host.json"; else echo '{"ok":true,"result":{"worktrees":[]}}'; fi ;;
  "terminal read")
    [ -f "$STUB/pane-$handle.txt" ] || { echo '{"ok":false,"error":{"message":"no such terminal"}}'; exit 1; }
    jq -Rs '{ok:true, result:{terminal:{tail:(split("\n"))}}}' "$STUB/pane-$handle.txt" ;;
  "terminal create")
    [ ! -f "$STUB/create-fail" ] || { echo '{"ok":false}'; exit 1; }
    n=$(( $(cat "$STUB/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/seq"; h="term_new_$n"
    path="${wt#path:}"; sid="$(printf '%s\n' "$cmd" | sed -n 's/.*--resume \([^ ]*\).*/\1/p')"
    root="$P"; [ "$host" = local ] || root="$PR"
    ppid=1000; [ "$kind" = plugly ] && ppid=2000
    if [ ! -f "$STUB/resume-dies" ]; then
      # shellcheck disable=SC2086
      hv=ORCA_TERMINAL_HANDLE; [ "$kind" = plugly ] && hv=PLUGLY_TERMINAL_HANDLE
      mkproc "$root" $((9000 + n)) "$ppid" "$path" "$hv=$h" $cmd
      transcript "$path" "$sid" "$(date +%s)"
      printf '> \n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' > "$STUB/pane-$h.txt"
    fi
    printf '{"ok":true,"result":{"terminal":{"handle":"%s"}}}\n' "$h" ;;
  "terminal close") echo '{"ok":true,"result":{"closed":true}}' ;;
  "worktree show")
    f="$STUB/wl-$host.json"
    case "$wt" in path:*) ;; *) echo '{"ok":false,"error":{"message":"stub: selector must be path:"}}'; exit 1 ;; esac
    jq -e --arg p "${wt#path:}" 'any(.result.worktrees[]; .path == $p)' "$f" >/dev/null 2>&1 || { echo '{"ok":false,"error":{"message":"no such worktree"}}'; exit 1; }
    jq --arg p "${wt#path:}" '{ok: true, result: {worktree: (.result.worktrees[] | select(.path == $p))}}' "$f" ;;
  "worktree set")
    f="$STUB/wl-$host.json"
    case "$wt" in path:*) ;; *) echo '{"ok":false,"error":{"message":"stub: selector must be path:"}}'; exit 1 ;; esac
    jq -e --arg p "${wt#path:}" 'any(.result.worktrees[]; .path == $p)' "$f" >/dev/null 2>&1 || { echo '{"ok":false,"error":{"message":"no such worktree"}}'; exit 1; }
    printf '%s' "$comment" > "$STUB/set-comment-$host.txt"
    jq --arg p "${wt#path:}" --arg c "$comment" '.result.worktrees |= map(if .path == $p then .comment = $c else . end)' "$f" > "$f.n" && mv "$f.n" "$f"
    echo '{"ok":true,"result":{}}' ;;
  *) echo '{"ok":false,"error":{"message":"stub: unhandled"}}'; exit 1 ;;
esac
EOF
chmod +x "$BIN/orca"; cp "$BIN/orca" "$BIN/plugly"
cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac; done
t="$1"; shift
echo "ssh $t $*" >> "$STUB/calls.log"
[ ! -f "$STUB/ssh-down-$t" ] || { echo "ssh: connect to host $t: Connection refused" >&2; exit 255; }
FAKE_HOST="$t" exec bash -s
EOF
printf '#!/usr/bin/env bash\necho "${FAKE_HOST:-testbox}"\n' > "$BIN/hostname"
printf '#!/usr/bin/env bash\necho "2026-11-11 10:27:00"\n' > "$BIN/uptime"
printf '#!/usr/bin/env bash\necho "reboot   system boot  6.8.0 Wed Nov 11 10:27   still running"\necho "shutdown system down  6.8.0 Wed Nov 11 10:20"\n' > "$BIN/last"
printf '#!/usr/bin/env bash\ncat "$STUB/powerkey-${FAKE_HOST:-local}" 2>/dev/null; exit 0\n' > "$BIN/journalctl"
printf '#!/usr/bin/env bash\ncase "$*" in *preempted*) cat "$STUB/preempted-${FAKE_HOST:-local}" 2>/dev/null || echo FALSE ;; *provisioning-model*) echo SPOT ;; esac\n' > "$BIN/curl"
printf '#!/usr/bin/env bash\ncase "$*" in *ActiveEnterTimestamp*) cat "$STUB/daemon-${FAKE_HOST:-local}" 2>/dev/null ;; esac\nexit 0\n' > "$BIN/systemctl"
printf '#!/usr/bin/env bash\necho "kill $1" >> "$STUB/calls.log"\nmv "$P/$1" "$DEAD/k.$1.$RANDOM" 2>/dev/null\n' > "$BIN/fakekill"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" ORCA_CLI_COMMAND="$BIN/orca" PLUGLY_CLI_COMMAND="$BIN/plugly"
export CM_PROC_ROOT="$P" CM_HEALTH_REMOTE_PROC_ROOT="$PR" CM_HEALTH_KILL_CMD="$BIN/fakekill" CM_HEALTH_AGENT_BIN=/opt/claude/bin/claude
export CM_HEALTH_VERIFY_S=4 CM_HEALTH_POLL_S=1 CM_HEALTH_SEND='printf "%s|%s\n" {to} {text} >> "$STUB/sent.log"'
LH="$SCRIPTS/lane-health.sh"

# ledger <workers-json>: a fresh ledger with these workers
ledger() { jq -n --argjson w "$1" '{schema: "concertmaster.ledger/v1", workers: $w, hosts: {"host-b": {hostname: "host-b"}}}' > "$CM_HOME/ledger.json"; }
row() { # <path> <extra json>
  jq -nc --arg p "$1" --argjson x "${2:-{\}}" '{host: "local", path: $p, state: "running", standing: false, agent: "claude", lane: "lane-a"} + $x'
}
lhj() { "$LH" "$@" --json 2>"$ROOT/lh.err"; }
word() { jq -r --arg k "$2" '.sessions[] | select(.key == $k or .name == $k) | .word' <<<"$1"; }
meaning() { jq -r --arg k "$2" '.sessions[] | select(.key == $k or .name == $k) | .meaning // ""' <<<"$1"; }
creates() { grep -c 'terminal create' "$STUB/calls.log"; }
mkdir -p "$W/lead-a" "$W/task-1" "$W/task-2" "$W/task-3" "$W/task-4"
LEAD_A="$W/lead-a"; T1="$W/task-1"; T2="$W/task-2"; T3="$W/task-3"; T4="$W/task-4"
SID_A=aaaaaaaa-0000-4000-8000-000000000001; SID_1=11111111-0000-4000-8000-000000000001

echo "--- the seven words"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}'),
         \"w-task-1\":$(row "$T1" '{"parent":"w-lead-a"}'),
         \"w-task-2\":$(row "$T2" '{"parent":"w-lead-a"}'),
         \"w-task-3\":$(row "$T3" '{"parent":"w-lead-a"}'),
         \"w-task-4\":$(row "$T4" '{"parent":"w-lead-a","state":"asleep","asleepAt":"2026-11-10T09:00:00Z"}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --dangerously-skip-permissions --resume "$SID_A" --model claude-x-1-0 --effort high
transcript "$LEAD_A" "$SID_A" "$NOW"
printf 'working\n  esc to interrupt\n' > "$STUB/pane-term_a.txt"
mkproc "$P" 102 2000 "$T1" "PLUGLY_TERMINAL_HANDLE=term_1" claude --model claude-x-1-0
transcript "$T1" "$SID_1" $((NOW - 3600))
printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_1.txt"
mkproc "$P" 103 1000 "$T2" "ORCA_TERMINAL_HANDLE=term_2" claude
printf 'Which option?\n  1. yes\n  2. no\nEnter to select · Tab/Arrow keys to navigate · Esc to cancel\n' > "$STUB/pane-term_2.txt"
mkproc "$P" 104 1000 "$T3" "ORCA_TERMINAL_HANDLE=term_3" claude
printf 'You have hit your usage limit. Resets at 5pm\n  1. Stop and wait for limit to reset\n  2. Switch to usage credits\nEnter to confirm\n' > "$STUB/pane-term_3.txt"
mkdir -p "$W/stray-1"; mkproc "$P" 105 1000 "$W/stray-1" "ORCA_TERMINAL_HANDLE=term_s" claude
printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_s.txt"
printf '{"ok":true,"result":{"worktrees":[{"path":"%s","comment":"cm:running route-guard PR #10\\ncm:child task-1"}]}}\n' "$LEAD_A" > "$STUB/wl-local.json"
OUT="$(lhj --all)"
# shellcheck disable=SC2034  # RC is read inside an eval-ed check below
RC=$?
check "running: a busy pane" '[ "$(word "$OUT" w-lead-a)" = running ]' "$OUT"
check "the last task line is the first line of the worktree comment" '[ "$(jq -r ".sessions[] | select(.key == \"w-lead-a\") | .task" <<<"$OUT")" = "cm:running route-guard PR #10" ]'
check "live facts: pid, session id from --resume, orca from the parent chain, model, effort, handle" \
  '[ "$(jq -c ".sessions[] | select(.key == \"w-lead-a\") | .live | [.pid, .sessionId, .sessionSource, .runtime, .model, .effort, .handle]" <<<"$OUT")" = "[101,\"$SID_A\",\"cmdline\",\"orca\",\"claude-x-1-0\",\"high\",\"term_a\"]" ]' "$OUT"
check "idle: a quiet pane and an hour-old transcript; session id from the single transcript; plugly runtime" \
  '[ "$(word "$OUT" w-task-1)" = idle ] && [ "$(jq -c ".sessions[] | select(.key == \"w-task-1\") | .live | [.sessionId, .sessionSource, .runtime]" <<<"$OUT")" = "[\"$SID_1\",\"transcript\",\"plugly\"]" ]' "$OUT"
check "waiting on you: a question menu" '[ "$(word "$OUT" w-task-2)" = "waiting on you" ] && meaning "$OUT" w-task-2 | grep -q "question menu"'
check "stuck: a usage limit with the credits menu" '[ "$(word "$OUT" w-task-3)" = stuck ] && meaning "$OUT" w-task-3 | grep -q "account limit"'
check "asleep: an asleep row with no process" '[ "$(word "$OUT" w-task-4)" = asleep ]'
check "unknown: an agent in a project worktree no ledger row holds" '[ "$(word "$OUT" stray-1)" = unknown ]'
check "exit 3: something needs a look" '[ "$RC" = 3 ]'
check "nothing typed into any pane, nothing created without --act" '! grep -q "terminal send" "$STUB/calls.log" && [ "$(creates)" = 0 ]'
check "facts recorded in the ledger through cm_ledger_write (a backup in the ring)" \
  '[ "$(jq -r ".workers[\"w-lead-a\"].live.sessionId" "$CM_HOME/ledger.json")" = "$SID_A" ] && [ "$(jq -r ".workers[\"w-task-3\"].health.word" "$CM_HOME/ledger.json")" = stuck ] && ls "$CM_HOME/ledger.bak/" | grep -q json'
check "the menu is stuck once it has waited 30 min" 'jq ".workers[\"w-task-2\"].health.paneSince = \"$(isoz $((NOW - 2400)))\"" "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json" \
  && { O2="$(lhj --all)"; true; } && [ "$(word "$O2" w-task-2)" = stuck ] && meaning "$O2" w-task-2 | grep -q "waited 40 min"'

echo "--- stopped, the cause, hostEvents"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a","health":{"word":"running","healthySince":"2026-11-01T00:00:00Z"},"live":{"sessionId":"'"$SID_A"'","runtime":"orca","model":"claude-x-1-0","effort":"high"}}')}"
jq --arg b "$(isoz $((NOW - 86400 * 2)))" '.hosts.local = {bootAt: $b}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json"
transcript "$LEAD_A" "$SID_A" $((NOW - 1200))
setboot "$P" $((NOW - 900))
OUT="$(lhj --all)"
check "stopped: should run, no process" '[ "$(word "$OUT" w-lead-a)" = stopped ]' "$OUT"
check "cause reboot: the boot is after its last transcript write" '[ "$(jq -r ".sessions[0].cause" <<<"$OUT")" = reboot ] && meaning "$OUT" w-lead-a | grep -q "server restarted at"'
check "a reboot event in hostEvents, marked watched (the host was seen up before)" \
  '[ "$(jq -r "[.hostEvents[] | select(.host == \"local\" and .kind == \"reboot\")] | length" "$CM_HOME/ledger.json")" = 1 ] && [ "$(jq -r "[.hostEvents[] | select(.host == \"local\")][0].watched" "$CM_HOME/ledger.json")" = true ] && jq -r "[.hostEvents[] | select(.host == \"local\")][0].evidence" "$CM_HOME/ledger.json" | grep -q "last -x"'
check "lastStopAt, lastStopCause and stopHistory recorded" \
  '[ "$(jq -r ".workers[\"w-lead-a\"] | [.lastStopCause, (.stopHistory | length), (.lastStopAt != null)] | @tsv" "$CM_HOME/ledger.json")" = "$(printf "reboot\t1\ttrue")" ]'
OUT="$(lhj --all)"
check "a second pass adds no second event and keeps the episode" \
  '[ "$(jq -r "[.hostEvents[] | select(.host == \"local\")] | length" "$CM_HOME/ledger.json")" = 1 ] && [ "$(jq -r ".workers[\"w-lead-a\"].stopHistory | length" "$CM_HOME/ledger.json")" = 1 ]'
printf 'Nov 11 10:26:58 host systemd-logind[1]: Power key pressed short.\n' > "$STUB/powerkey-local"
jq '.hostEvents = [] | .workers["w-lead-a"].health.word = "running" | .hosts = {}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json"
OUT="$(lhj --all)"
check "cause preemption: a power-key press logged by the previous boot" '[ "$(jq -r ".sessions[0].cause" <<<"$OUT")" = preemption ] && meaning "$OUT" w-lead-a | grep -q "Spot preemption"'
check "a host seen for the first time: its boot is recorded, not watched (no alert for an old boot)" '[ "$(jq -r "[.hostEvents[] | select(.host == \"local\")][0].watched" "$CM_HOME/ledger.json")" = false ]'
rm_pk() { mv "$STUB/powerkey-local" "$DEAD/pk.$RANDOM"; }; rm_pk
setboot "$P" $((NOW - 86400))
jq -nr --argjson t $((NOW - 600)) '$t | strftime("%a %Y-%m-%d %H:%M:%S UTC")' > "$STUB/daemon-local"
jq '.hostEvents = [] | .workers["w-lead-a"].health.word = "running"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json"
OUT="$(lhj --all)"
check "cause daemon restart: the runtime unit restarted after the last write" '[ "$(jq -r ".sessions[0].cause" <<<"$OUT")" = "daemon restart" ] && jq -e "any(.hostEvents[]; .kind == \"daemon-restart\")" "$CM_HOME/ledger.json" >/dev/null'
mv "$STUB/daemon-local" "$DEAD/d.$RANDOM"
jq '.hostEvents = [] | .workers["w-lead-a"].health.word = "running"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json"
OUT="$(lhj --all)"
check "cause crash: no boot or restart after its last write" '[ "$(jq -r ".sessions[0].cause" <<<"$OUT")" = crash ]'

echo "--- auto-resume once"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a","health":{"word":"running","healthySince":"2026-11-11T00:00:00Z"},"live":{"sessionId":"'"$SID_A"'","runtime":"plugly","model":"claude-x-1-0","effort":"high"}}')}"
jq --arg b "$(isoz $((NOW - 86400 * 3)))" '.hosts.local = {bootAt: $b}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json"
transcript "$LEAD_A" "$SID_A" $((NOW - 1200))
setboot "$P" $((NOW - 120))
OUT="$(lhj --all --act)"
check "settle: no resume within 5 min of the boot" '[ "$(creates)" = 0 ] && meaning "$OUT" w-lead-a | grep -q "settle"' "$OUT"
check "no lead-stopped alert while it waits to settle" '[ ! -s "$STUB/sent.log" ]'
export CM_NOW=$((NOW + 780))   # 15 min after the boot: settled
OUT="$(lhj --all --act)"
check "resumed once, in its owner runtime (plugly), with --dangerously-skip-permissions --resume <id>, model and effort" \
  '[ "$(creates)" = 1 ] && grep "terminal create" "$STUB/calls.log" | grep -q "^plugly terminal create .*wt=path:$LEAD_A cmd=/opt/claude/bin/claude --dangerously-skip-permissions --resume $SID_A --model claude-x-1-0 --effort high"' "$(cat "$STUB/calls.log")"
check "verified: the action says one process, bypass footer, same transcript; the word is running" \
  '[ "$(jq -r ".actions[] | select(.kind == \"resume\") | .result" <<<"$OUT")" = resumed ] && jq -r ".actions[0].detail" <<<"$OUT" | grep -q "one process on $SID_A, bypass footer, same transcript" && [ "$(word "$OUT" w-lead-a)" = running ] && [ "$(jq -r ".workers[\"w-lead-a\"].resumeAttempts" "$CM_HOME/ledger.json")" = 1 ]' "$OUT"
check "one reboot alert, sent once the host settled, lists what came back" '[ "$(grep -c "local restarted at .*Came back: 1 (lead-a). Not back: 0" "$STUB/sent.log")" = 1 ]' "$(cat "$STUB/sent.log" 2>/dev/null)"
# it stops again soon after: never a second try, one alert, deduplicated
mv "$P/9001" "$DEAD/again"
OUT="$(lhj --all --act)"
check "stopped again inside the reset window: no second resume" '[ "$(creates)" = 1 ] && meaning "$OUT" w-lead-a | grep -q "retry 1 already used"' "$OUT"
check "lead-stopped alert sent once, with the reason" '[ "$(grep -c "lead lead-a on local is stopped" "$STUB/sent.log")" = 1 ]' "$(cat "$STUB/sent.log" 2>/dev/null)"
check "an inbox note for the alert" 'ls "$CM_HOME/inbox/" | grep -q "^lane-health-lead-stopped-"'
OUT="$(lhj --all --act)"
check "the same event never alerts twice" '[ "$(grep -c "lead lead-a on local is stopped" "$STUB/sent.log")" = 1 ] && [ "$(creates)" = 1 ] && [ "$(grep -c "restarted at" "$STUB/sent.log")" = 1 ]'
export CM_NOW="$NOW"
# a resume that does not come up: one try, failed, alerted
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a","health":{"word":"idle"},"live":{"sessionId":"'"$SID_A"'","runtime":"orca"}}')}"
transcript "$LEAD_A" "$SID_A" $((NOW - 1200)); touch "$STUB/resume-dies"
OUT="$(lhj --all --act)"
check "a resume that never shows a process: failed, counted, alerted" \
  '[ "$(creates)" = 1 ] && meaning "$OUT" w-lead-a | grep -q "retry 1 failed" && [ "$(jq -r ".workers[\"w-lead-a\"].resumeAttempts" "$CM_HOME/ledger.json")" = 1 ] && grep -q "lead lead-a on local is stopped" "$STUB/sent.log"' "$OUT"
OUT="$(lhj --all --act)"
check "and is not tried a second time" '[ "$(creates)" = 1 ]'
# a session id it cannot know: no resume, alert
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a","health":{"word":"running"}}')}"
transcript "$LEAD_A" "$SID_A" $((NOW - 1200)); transcript "$LEAD_A" "$SID_1" $((NOW - 1300))
OUT="$(lhj --all --act)"
check "two transcripts and no recorded id: not resumed, said plainly" '[ "$(creates)" = 0 ] && meaning "$OUT" w-lead-a | grep -q "no session id recorded"'
# a child of a live lead is the lead's to resume
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}'),\"w-task-1\":$(row "$T1" '{"parent":"w-lead-a","health":{"word":"running"},"live":{"sessionId":"'"$SID_1"'"}}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --resume "$SID_A"; printf '  esc to interrupt\n' > "$STUB/pane-term_a.txt"
transcript "$T1" "$SID_1" $((NOW - 1200))
OUT="$(lhj --all --act)"
check "--all leaves a lead's child to the lead" '[ "$(creates)" = 0 ] && meaning "$OUT" w-task-1 | grep -q "its lead w-lead-a resumes it"' "$OUT"
OUT="$("$LH" --lead w-lead-a --act --json 2>/dev/null)"
check "--lead resumes its own child once (and writes no ledger)" \
  '[ "$(creates)" = 1 ] && [ "$(word "$OUT" w-task-1)" = running ] && [ -s "$CM_HOME/cache/lane-health-lead-w-lead-a.json" ] && [ "$(jq -r ".workers[\"w-task-1\"].resumeAttempts // 0" "$CM_HOME/ledger.json")" = 0 ]' "$OUT"
LINE="$("$LH" --lead w-lead-a --line --no-write 2>/dev/null)"
check "--line prints one cm:health line for the lead comment" 'printf "%s" "$LINE" | grep -Eq "^cm:health 1/1 ok \| at "' "$LINE"

echo "--- duplicates"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --resume "$SID_A"
mkproc "$P" 106 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_b" claude --resume "$SID_A"
OUT="$(lhj --all --act)"
check "two processes on one worktree: waiting on you, nothing touched" \
  '[ "$(word "$OUT" w-lead-a)" = "waiting on you" ] && meaning "$OUT" w-lead-a | grep -q "two copies" && ! grep -qE "kill|terminal (create|close|send)" "$STUB/calls.log"' "$OUT"
check "a duplicate alert, once" '[ "$(grep -c "two copies of lead-a" "$STUB/sent.log")" = 1 ] && "$LH" --all --act >/dev/null 2>&1; [ "$(grep -c "two copies of lead-a" "$STUB/sent.log")" = 1 ]'
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}'),\"w-task-1\":$(row "$T1" '{}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --resume "$SID_A"
mkproc "$P" 107 1000 "$T1" "ORCA_TERMINAL_HANDLE=term_c" claude --resume "$SID_A"
OUT="$(lhj --all)"
check "one session id in two worktrees: a duplicate too" '[ "$(word "$OUT" w-lead-a)" = "waiting on you" ] && meaning "$OUT" w-task-1 | grep -q "two copies of session aaaaaaaa"' "$OUT"

echo "--- unknown sessions: sleep a merged clean worker, never a lead"
reset_world
ledger '{}'
git init -q --bare -b main "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/acme/main-co" 2>/dev/null
( cd "$ROOT/acme/main-co" && git checkout -q -b main 2>/dev/null; echo one > a.txt && git add a.txt && git commit -q -m init && git push -q origin main 2>/dev/null )
git -C "$ROOT/acme/main-co" worktree add -q -b done-9 "$W/done-9" main 2>/dev/null
( cd "$W/done-9" && echo two > b.txt && git add b.txt && git commit -q -m work )
( cd "$ROOT/acme/main-co" && git merge -q --no-ff -m merge done-9 && git push -q origin main 2>/dev/null && git fetch -q origin )
git -C "$ROOT/acme/main-co" remote set-head origin main >/dev/null 2>&1
git -C "$ROOT/acme/main-co" worktree add -q -b fresh-7 "$W/fresh-7" main 2>/dev/null
git -C "$ROOT/acme/main-co" worktree add -q -b epic-big "$W/epic-big" done-9 2>/dev/null
mkproc "$P" 201 1000 "$W/done-9" "ORCA_TERMINAL_HANDLE=term_d" claude --resume "$SID_1"
transcript "$W/done-9" "$SID_1" $((NOW - 7200)); printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_d.txt"
mkproc "$P" 202 1000 "$W/fresh-7" "ORCA_TERMINAL_HANDLE=term_f" claude
transcript "$W/fresh-7" bbbbbbbb-0000-4000-8000-000000000002 $((NOW - 7200))
mkproc "$P" 203 1000 "$W/epic-big" "ORCA_TERMINAL_HANDLE=term_e" claude
transcript "$W/epic-big" cccccccc-0000-4000-8000-000000000003 $((NOW - 7200))
mkdir -p "$W/other-thing"; mkproc "$P" 204 1000 "$W/other-thing" "" claude
wlrow() { jq -n --arg p "$1" --arg c "$2" '{ok: true, result: {worktrees: [{path: $p, comment: $c}]}}'; }   # $2 holds a literal \n
wlrow "$W/done-9" 'cm:done shipped\nnotes' > "$STUB/wl-local.json"
OUT="$(lhj --all)"
check "read-only pass: the merged clean worker would be slept, nothing killed" \
  'meaning "$OUT" done-9 | grep -q "put to sleep" && ! grep -q "^kill" "$STUB/calls.log"' "$OUT"
check "a worktree on the main line is not merged work: not slept" 'meaning "$OUT" fresh-7 | grep -q "main line"'
check "a lead-shaped unknown is never slept, the owner is asked" 'meaning "$OUT" epic-big | grep -q "looks like a lead"'
check "never_touch worktrees are not even listed" '[ -z "$(word "$OUT" other-thing)" ]'
OUT="$(lhj --all --act)"
check "--act: killed by exact pid, terminal closed, an asleep ledger row adopted" \
  'grep -q "^kill 201$" "$STUB/calls.log" && grep -q "terminal close .*handle=term_d" "$STUB/calls.log" && [ "$(jq -r ".workers[\"w-done-9\"] | [.state, .standing, .live.sessionId] | @tsv" "$CM_HOME/ledger.json")" = "$(printf "asleep\tfalse\t%s" "$SID_1")" ]' "$OUT"
check "the lead-shaped and main-line ones are untouched" '! grep -qE "^kill (202|203)$" "$STUB/calls.log"'
check "the slept worker's comment is marked cm:asleep with its adopted id, the rest kept byte for byte" \
  '[ "$(cat "$STUB/set-comment-local.txt")" = "$(printf "cm:asleep %s put to sleep by lane-health; wake with scripts/lane-health.sh wake w-done-9 --apply\n%s" "$(isoz "$NOW")" "cm:done shipped\\nnotes")" ]' "$(cat "$STUB/set-comment-local.txt" 2>/dev/null)"
reset_world
ledger '{}'
mkproc "$P" 201 1000 "$W/done-9" "ORCA_TERMINAL_HANDLE=term_d" claude --resume "$SID_1"
transcript "$W/done-9" "$SID_1" $((NOW - 7200)); printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_d.txt"
OUT="$(lhj --all --act)"
check "a comment that cannot be marked cm:asleep: the worker is not slept (fail closed)" '! grep -q "^kill" "$STUB/calls.log" && meaning "$OUT" done-9 | grep -q "could not be marked"' "$OUT"

echo "--- sleep and wake a lead, the resume path and teardown"
reset_world
git -C "$ROOT/acme/main-co" worktree add -q -b lead-g "$W/lead-g" main 2>/dev/null
LEAD_A="$W/lead-g"
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}')}"
wlrow "$LEAD_A" 'cm:running plan\ncm:child task-1' > "$STUB/wl-local.json"
mkproc "$P" 101 2000 "$LEAD_A" "PLUGLY_TERMINAL_HANDLE=term_a" claude --dangerously-skip-permissions --resume "$SID_A" --model claude-x-1-0
transcript "$LEAD_A" "$SID_A" "$NOW"; printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_a.txt"
OUT="$("$LH" sleep w-lead-a 2>&1)"
check "sleep is a dry run by default" 'printf "%s" "$OUT" | grep -q "dry run" && ! grep -q "^kill" "$STUB/calls.log"' "$OUT"
OUT="$("$LH" sleep w-lead-a --apply 2>&1)"
check "sleep --apply: process stopped, terminal closed, state asleep, session id kept" \
  'grep -q "^kill 101$" "$STUB/calls.log" && grep -q "^plugly terminal close .*handle=term_a" "$STUB/calls.log" && [ "$(jq -r ".workers[\"w-lead-a\"] | [.state, .asleepFrom, .live.sessionId] | @tsv" "$CM_HOME/ledger.json")" = "$(printf "asleep\trunning\t%s" "$SID_A")" ]' "$OUT"
check "sleep marks the worktree comment cm:asleep first and keeps the rest byte for byte" \
  '[ "$(jq -r --arg p "$LEAD_A" ".result.worktrees[] | select(.path == \$p) | .comment" "$STUB/wl-local.json" | head -n 1 | cut -c1-9)" = "cm:asleep" ] && [ "$(jq -r --arg p "$LEAD_A" ".result.worktrees[] | select(.path == \$p) | .comment" "$STUB/wl-local.json" | tail -n 1)" = '"'"'cm:running plan\ncm:child task-1'"'"' ]'
check "roster.sh leaves an asleep row out (resume.sh never revives it)" '"$SCRIPTS/roster.sh" --stdout | grep -q "^\[\]$"'
OUT="$(lhj --all --act)"
check "an asleep lead is never resumed by the check" '[ "$(creates)" = 0 ] && [ "$(word "$OUT" w-lead-a)" = asleep ]'
check "teardown.sh refuses a standing row and says only the owner cleans up a lead" \
  'T="$("$SCRIPTS/teardown.sh" local "$LEAD_A" 2>&1)"; printf "%s" "$T" | grep -q "only Owner cleans up a lead"' "$("$SCRIPTS/teardown.sh" local "$LEAD_A" 2>&1 | tail -n 5)"
OUT="$("$LH" wake w-lead-a --apply 2>&1)"
check "wake --apply resumes the same session id, sets the state back and drops the cm:asleep line" \
  '[ "$(creates)" = 1 ] && grep "terminal create" "$STUB/calls.log" | grep -q -- "--resume $SID_A --model claude-x-1-0" && [ "$(jq -r ".workers[\"w-lead-a\"].state" "$CM_HOME/ledger.json")" = running ] \
   && [ "$(jq -r ".result.worktrees[0].comment" "$STUB/wl-local.json")" = '"'"'cm:running plan\ncm:child task-1'"'"' ]' "$OUT"

LEAD_A="$W/lead-a"
echo "--- remote hosts"
reset_world
ledger "{\"w-b\":$(row "$T1" '{"host":"host-b"}'),\"w-c\":$(row "$T2" '{"host":"host-c"}')}"
mkproc "$PR" 301 1000 "$T1" "ORCA_TERMINAL_HANDLE=term_r" claude --resume "$SID_1"; transcript "$T1" "$SID_1" "$NOW"
printf '  esc to interrupt\n' > "$STUB/pane-term_r.txt"
touch "$STUB/ssh-down-host-c"
OUT="$(lhj --all)"
check "a remote host is read over ssh; its pane through --environment" \
  '[ "$(word "$OUT" w-b)" = running ] && grep -q "^ssh host-b" "$STUB/calls.log" && grep -q "terminal read host=host-b handle=term_r" "$STUB/calls.log"' "$OUT"
check "an unreachable host: unknown, host down" '[ "$(word "$OUT" w-c)" = unknown ] && meaning "$OUT" w-c | grep -q "did not answer"'
reset_world
ledger "{\"w-c\":$(row "$T2" '{"host":"host-c","standing":true,"health":{"word":"running"},"live":{"sessionId":"'"$SID_1"'","runtime":"orca"}}')}"
transcript "$T2" "$SID_1" $((NOW - 1800)); touch "$STUB/ssh-down-host-c"
OUT="$(lhj --all --act)"
check "--act with the host down: never resumed anywhere, and the last verdict is kept" \
  '[ "$(creates)" = 0 ] && [ "$(jq -r ".workers[\"w-c\"].health.word" "$CM_HOME/ledger.json")" = running ]' "$OUT"
mv "$STUB/ssh-down-host-c" "$DEAD/up.$RANDOM"
OUT="$(lhj --all --act)"
check "the host is back: the session that ran fine before is resumed there, over --environment" \
  '[ "$(creates)" = 1 ] && grep -q "^orca terminal create host=host-c" "$STUB/calls.log" && [ "$(word "$OUT" w-c)" = running ]' "$OUT"

echo "--- review cases: what must never be slept, resumed or run"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --resume "$SID_A"; transcript "$LEAD_A" "$SID_A" "$NOW"
printf '  esc to interrupt\n' > "$STUB/pane-term_a.txt"
mkproc "$P" 401 1000 "$W/done-9" "ORCA_TERMINAL_HANDLE=term_x" codex
mkproc "$P" 402 1000 "$W/epic-big" "" claude --resume "$SID_A"
OUT="$(lhj --all --act)"
check "an unknown agent with no transcript (codex) is never slept, even merged and clean" \
  'meaning "$OUT" done-9 | grep -q "no session id" && ! grep -q "^kill 401" "$STUB/calls.log"' "$OUT"
check "an unknown running a ledger session id is a duplicate, never slept" \
  '! grep -q "^kill 402" "$STUB/calls.log" && [ "$(word "$OUT" w-lead-a)" = "waiting on you" ]' "$OUT"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a","health":{"word":"running"},"live":{"sessionId":"'"$SID_A"'"}}')}"
transcript "$LEAD_A" "$SID_A" $((NOW - 1800))
mkdir -p "$P/499"; printf 'x' > "$P/499/stat"; chmod 000 "$P/499/stat"
OUT="$(lhj --all --act)"
chmod 600 "$P/499/stat"
check "an unreadable process entry: the scan is incomplete, nothing is resumed" '[ "$(creates)" = 0 ] && [ "$(word "$OUT" w-lead-a)" = unknown ]' "$OUT"
reset_world
ledger "{\"w-task-1\":$(row "$T1" '{"health":{"word":"idle"},"live":{"sessionId":"'"$SID_1"'"}}')}"
transcript "$T1" "$SID_1" $((NOW - 1800))
printf '{"ok":true,"result":{"worktrees":[{"path":"%s","comment":"cm:done shipped PR #9"}]}}\n' "$T1" > "$STUB/wl-local.json"
OUT="$(lhj --all --act)"
check "a worker whose comment says cm:done is not stopped and not resumed" '[ "$(creates)" = 0 ] && [ -z "$(word "$OUT" w-task-1)" ]' "$OUT"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --resume "$SID_A"
transcript "$LEAD_A" "$SID_A" $((NOW - 3600)); transcript "$LEAD_A" "$SID_1" $((NOW - 60))
printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_a.txt"
OUT="$(lhj --all)"
check "after /clear the newer transcript is the session the process is on" \
  '[ "$(jq -r ".sessions[0].live | [.sessionId, .sessionSource] | @tsv" <<<"$OUT")" = "$(printf "%s\tnewest-transcript" "$SID_1")" ]' "$OUT"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --resume "$SID_A"
mkproc "$P" 106 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_b" claude --resume "$SID_A"
printf '  esc to interrupt\n' > "$STUB/pane-term_a.txt"
export CM_HEALTH_SEND='printf "%s\n" {text} >> "$STUB/sent.log"'
jq '.workers["w-lead-a"].path = "'"$W"'/lead-a;$(touch '"$STUB"'/pwned)"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json"
mkdir -p "$W/lead-a;\$(touch $STUB/pwned)"
mkproc "$P" 107 1000 "$W/lead-a;\$(touch $STUB/pwned)" "" claude --resume "$SID_1"
mkproc "$P" 108 1000 "$W/lead-a;\$(touch $STUB/pwned)" "" claude --resume "$SID_1"
OUT="$(lhj --all --act)"
check "alert text that holds shell syntax is sent as data, never run" '[ ! -e "$STUB/pwned" ] && grep -q "touch" "$STUB/sent.log"' "$(cat "$STUB/sent.log" 2>/dev/null)"
export CM_HEALTH_SEND='printf "%s|%s\n" {to} {text} >> "$STUB/sent.log"'
# a lead on a host with no ledger reads its children from its own comment: a slept child stays asleep
reset_world
printf '{"ok":true,"result":{"worktrees":[{"path":"%s","comment":"cm:running\\ncm:child task-1"},{"path":"%s","comment":"cm:running work"}]}}\n' "$LEAD_A" "$T1" > "$STUB/wl-local.json"
mkproc "$P" 102 1000 "$T1" "ORCA_TERMINAL_HANDLE=term_1" claude --resume "$SID_1"; transcript "$T1" "$SID_1" "$NOW"
printf '  esc to interrupt\n' > "$STUB/pane-term_1.txt"
OUT="$(CM_LEDGER="$ROOT/no-ledger.json" "$LH" --lead lead-a --json 2>&1)"
check "--lead with no ledger: children come from its cm:child lines" '[ "$(word "$OUT" task-1@local)" = running ]' "$OUT"
mv "$P/102" "$DEAD/t1.$RANDOM"
jq --arg p "$T1" '.result.worktrees |= map(if .path == $p then .comment = "cm:asleep 2026-11-11T10:00:00Z put to sleep by lane-health" else . end)' "$STUB/wl-local.json" > "$ROOT/w.json" && cp "$ROOT/w.json" "$STUB/wl-local.json"
OUT="$(CM_LEDGER="$ROOT/no-ledger.json" "$LH" --lead lead-a --act --json 2>&1)"
check "--lead with no ledger: a child whose comment says cm:asleep is asleep, never resumed" '[ "$(word "$OUT" task-1@local)" = asleep ] && [ "$(creates)" = 0 ]' "$OUT"
# a retired record on the same path as a live lead never takes its process (and so never gets it slept)
reset_world
ledger "{\"w-old\":$(row "$W/epic-big" '{"state":"retired"}'),\"w-lead-e\":$(row "$W/epic-big" '{"standing":true,"lane":"epic-big"}')}"
mkproc "$P" 203 1000 "$W/epic-big" "ORCA_TERMINAL_HANDLE=term_e" claude --resume "$SID_A"; transcript "$W/epic-big" "$SID_A" $((NOW - 7200))
printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_e.txt"
OUT="$(lhj --all --act)"
check "a live lead wins its path over a retired record: idle, never slept" '[ "$(word "$OUT" w-lead-e)" = idle ] && ! grep -q "^kill" "$STUB/calls.log"' "$OUT"

reset_world
ledger "{\"w-task-1\":$(row "$T1" '{"health":{"word":"running"},"live":{"sessionId":"'"$SID_1"'"}}')}"
transcript "$T1" "$SID_1" $((NOW - 1800))
printf '{"ok":true,"result":{"worktrees":[{"path":"%s","comment":"cm:running\\ncm:child task-1"}]}}\n' "$W/far-lead" > "$STUB/wl-local.json"
OUT="$(lhj --all --act)"
check "a row no ledger parent names, but a lead comment claims: left to that lead" '[ "$(creates)" = 0 ] && meaning "$OUT" w-task-1 | grep -q "its lead far-lead resumes it"' "$OUT"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a","health":{"word":"running"},"live":{"sessionId":"'"$SID_A"'"}}')}"
transcript "$LEAD_A" "$SID_A" $((NOW - 1800))
OUT="$(CM_HEALTH_RUN_BUDGET_S=10 "$LH" --all --act --json 2>/dev/null)"
check "a resume whose worst case would pass the run budget is deferred, not started" \
  '[ "$(creates)" = 0 ] && jq -r ".actions[0].detail" <<<"$OUT" | grep -q "deferred to the next pass"' "$OUT"

reset_world
ledger "{\"w-task-1\":$(row "$T1" '{"health":{"word":"running"},"live":{"sessionId":"'"$SID_1"'"}}')}"
transcript "$T1" "$SID_1" $((NOW - 1800))
FAKE_TTY=0 mkproc "$P" 501 1000 "$T1" "" claude -p --resume "$SID_1" "summarise"
OUT="$(lhj --all --act)"
check "a headless agent on the session (no terminal) is a copy: not judged, never resumed beside it" '[ "$(creates)" = 0 ] && [ "$(word "$OUT" w-task-1)" = unknown ]' "$OUT"
reset_world
ledger "{\"w-task-1\":$(row "$T1" '{"health":{"word":"running"},"live":{"sessionId":"'"$SID_1"'"}}'),\"w-lead-b\":$(row "$T3" '{"host":"host-b","standing":true,"lane":"lead-b"}')}"
transcript "$T1" "$SID_1" $((NOW - 1800))
mkproc "$PR" 601 1000 "$T3" "ORCA_TERMINAL_HANDLE=term_lb" claude --resume "$SID_A"; printf '  esc to interrupt\n' > "$STUB/pane-term_lb.txt"
printf '{"ok":false,"error":{"message":"timed out"}}\n' > "$STUB/wl-host-b.json"
OUT="$(lhj --all --act)"
check "a host whose comments could not be read may hold a cm:child claim: a parentless worker is not resumed" \
  '[ "$(creates)" = 0 ] && meaning "$OUT" w-task-1 | grep -q "comments of host-b were not read"' "$OUT"
reset_world
ledger "{\"w-done-9\":$(row "$W/done-9" '{"state":"gone"}')}"
mkproc "$P" 201 1000 "$W/done-9" "ORCA_TERMINAL_HANDLE=term_d" claude --resume "$SID_1"
transcript "$W/done-9" "$SID_1" $((NOW - 7200)); printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_d.txt"
wlrow "$W/done-9" 'cm:done shipped' > "$STUB/wl-local.json"
OUT="$(lhj --all --act)"
check "an adopted id never overwrites a dead ledger record of the same name" \
  '[ "$(jq -r ".workers[\"w-done-9\"].state" "$CM_HOME/ledger.json")" = gone ] && [ "$(jq -r ".workers[\"w-done-9-local\"].state" "$CM_HOME/ledger.json")" = asleep ]' "$OUT"

echo "--- cm-status view"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}'),
         \"w-task-1\":$(row "$T1" '{"parent":"w-lead-a"}'),
         \"w-task-2\":$(row "$T2" '{"parent":"w-lead-a","health":{"word":"running"},"live":{"sessionId":"'"$SID_1"'"}}')}"
mkproc "$P" 101 1000 "$LEAD_A" "ORCA_TERMINAL_HANDLE=term_a" claude --resume "$SID_A"; printf '  esc to interrupt\n' > "$STUB/pane-term_a.txt"
mkproc "$P" 102 1000 "$T1" "ORCA_TERMINAL_HANDLE=term_1" claude; printf '> \n  ? for shortcuts\n' > "$STUB/pane-term_1.txt"
transcript "$T1" "$SID_1" $((NOW - 3600)); transcript "$T2" "$SID_1" $((NOW - 3600)); transcript "$LEAD_A" "$SID_A" "$NOW"
cp "$CM_HOME/ledger.json" "$ROOT/before.json"
V="$("$SCRIPTS/cm-status.sh" 2>&1)"
check "cm-status: NEEDS A LOOK box first, with the stopped child and its meaning" \
  'printf "%s\n" "$V" | head -n 1 | grep -q "^NEEDS A LOOK (1)" && printf "%s\n" "$V" | sed -n 2p | grep -q "✗ task-2 .*stopped"' "$V"
check "cm-status: a tree of host, lead and the sessions it owns" \
  'printf "%s\n" "$V" | grep -q "^local" && printf "%s\n" "$V" | grep -q "^  lead-a .*● running" && printf "%s\n" "$V" | grep -q "├ task-1 .*○ idle" && printf "%s\n" "$V" | grep -q "└ task-2 .*✗ stopped"' "$V"
check "cm-status writes nothing" 'cmp -s "$ROOT/before.json" "$CM_HOME/ledger.json"'
V="$("$SCRIPTS/cm-status.sh" --detail 2>&1)"
check "cm-status --detail adds pid, session, handle, runtime and the host events log" \
  'printf "%s\n" "$V" | grep -q "pid 101 · session $SID_A · handle term_a · orca" && printf "%s\n" "$V" | grep -q "^Host events"' "$V"

echo "--- digest fleet health"
reset_world
ledger "{\"w-lead-a\":$(row "$LEAD_A" '{"standing":true,"lane":"lead-a"}')}"
transcript "$LEAD_A" "$SID_A" $((NOW - 1200))
"$LH" --all >/dev/null 2>&1
D="$(CM_DIGEST_GH_TIMEOUT=1 PATH="$BIN:$PATH" "$SCRIPTS/digest.sh" 2>/dev/null)"
check "digest: a Fleet health section with counts and no names" 'printf "%s\n" "$D" | grep -q "^Fleet health" && printf "%s\n" "$D" | grep -q "1 stopped" && ! printf "%s\n" "$D" | grep -q "lead-a"' "$D"
DF="$(CM_DIGEST_GH_TIMEOUT=1 "$SCRIPTS/digest.sh" --full 2>/dev/null)"
check "digest --full: names the session that needs a look" 'printf "%s\n" "$DF" | grep -q "lead-a on local: stopped"' "$DF"
jq '.health.checkedAt = "2026-01-01T00:00:00Z"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && cp "$ROOT/l.json" "$CM_HOME/ledger.json"
D="$(CM_DIGEST_GH_TIMEOUT=1 "$SCRIPTS/digest.sh" 2>/dev/null)"
check "digest: an old check says the concertmaster check is missing" 'printf "%s\n" "$D" | grep -q "concertmaster check missing"' "$D"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
