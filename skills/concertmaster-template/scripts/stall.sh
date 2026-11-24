#!/usr/bin/env bash
# stall.sh: the drive ladder check (SKILL.md § Autonomy and guardrails, references/drive-ladder.md). Run every tick,
# after discover, classify and asks. Lists every lane, PR and ask with no progress for 30 minutes or more, the rung
# it is on and the action taken, and flags a tick that left a due row without an action.
#
#   scripts/stall.sh --classify F --discover F --asks F --ledger F --since <tick-start ISO> [--json]
#   scripts/stall.sh --act <kind> <name> <verb> <text> [--host H] [--path P] [--ledger F]
#
# Reads files only: it never calls orca, plugly, gh or ssh. Inputs: `classify.sh` JSON (items[]), `discover.sh` JSON
# (hosts[], worktrees[] for the comments, prs.open[]), `asks.sh --json` and the ledger (workers, asks, queue, freeze).
# Clock: CM_NOW (ISO 8601 or epoch seconds) overrides now, for tests.
#
# Progress, per kind (the age is now minus the newest progress time):
#   lane  the newest of: classify idleMinutes (taken at the classify document's generatedAt) and the first-seen time of
#         the head of its open PR. A worktree comment change is not read as progress: discover and classify carry no
#         comment-changed time, and a time written inside the comment text (an old note, a deadline just passed) says
#         nothing about when the lane last moved, so it is never used
#   pr    the newest of: the first-seen time of its headRefOid, kept in $CM_HOME/stall-seen.json (a new sha resets
#         it; a PR seen for the first time starts at its updatedAt), and updatedAt
#   ask   asks.sh firstSeen, or a ledger ask's askedAt (state open)
# Rungs (config schedule.stall_rungs_min, default [30, 60, 90]): age >= 30 rung 1 (nudge; an ask: relay or reply),
# >= 60 rung 2 (restart through scripts/resume.sh or lane-health.sh, or re-place; an ask: escalate or close it),
# >= 90 rung 3 (an independent verdict, then act). rung = min(age rung, last rung acted in this episode + 1), so a
# ladder never skips a rung; an episode is the actions recorded since the row last made progress, and in time order an
# action counts at most one rung above the one before it (a verdict recorded first counts as rung 1). While
# $CM_HOME/resume.lock is held a lane or PR on rung 2 is `held`: no restart is offered and it is not due.
# A row is due when its rung is above the last rung acted. NO-ACTION: a due row with no action AT OR ABOVE ITS RUNG
# recorded since --since (a nudge every tick never hides a missed restart or verdict). A `blocked` or `close-ask` action
# in the episode moves the row to exempt until it makes progress. An action belongs to a row by kind, name and host (and
# path when both carry one); an action recorded without --host matches a row only when no other host has that name.
#
# Never stalled (listed in exempt[] with a reason): host-offline, a host whose worktree list was cut off, a host
# asks.sh could not read (in its unreachable list, or missing from its hostsRead, as when its host list failed and only
# local was read), an asks row with no host, a row with no progress time at all (these count in `unverified`),
# main-checkout, other-project, a worktrees.never_touch name, done-merged, done-selfreported, the concertmaster itself,
# a lane the ledger holds asleep, standing-idle (or cm:keep) with nothing queued or granted for it in the ledger queue
# (a granted entry is work in flight), a ledger worker parked or blocked-on-owner, a cm:waiting-owner comment, a lane
# with an open ask (a comment ask in its worktree; a ledger ask with a non-empty string id that names a worker by that
# worker live ledger row only, by the last part of its path on its host; a dead row (gone, repurposed: its path is gone
# or belongs to another worker), no row or no path holds no lane and never falls back to asks[].lane; one that names no
# worker and carries no followUp by asks[].lane on every host (scripts/followups.sh writes the ownership label there,
# and workers.<w>.lane is never read); each while that ask row is owner-only, held, or on the ladder with no close-ask
# or blocked recorded; a closed or unverified ledger ask frees its lane and PR), a lead's child (claimed in a live lead's
# comment); asks: EVERY asks.sh row (cm:ask, cm:blocked, cm:waiting-owner) is owner-only, Blocked, not stalled: it has
# no kind, so no deny scan can clear it, and a delegated question ladders as its ledger ask; an asks row or a ledger
# ask in the concertmaster's own worktree (a classify self item or the worktrees.self_name name, matched for a ledger
# ask by its worker id, worker path, lane, worktree or path) is a `held` item for the owner; owner-only ledger asks (the
# kind is read from `kind`, else `scope`, lowercased and trimmed). A ledger ask ladders only when it is one of:
# release or deploy, and delegated (config drive.delegated_classes, none by default) whose plain ASCII text names no
# runbook or cutover (a line `go <command> <staging|production> ...`, also quoted with > or spaced out, cutover, a
# runbook step) and no secret: no term of CM_ASK_DENY_CRED (the credential segment of the scripts/ask-deny.sh deny list:
# auth, oauth, login, jwt, secrets, passwords, API keys, service role, env vars, access/refresh/bearer tokens) and no
# release-only term (token, keystore, signing, private key, access key, webhook, vault, provisioning, keychain, account-,
# org- or repo-wide, and as a word key, keys, pat, pats, cert, certs, certificate, p8, p12, dsn, bearer). And default
# deny, by an allowlist of the shape: a question or topic that is not text is the owner's, and the question and topic
# (joined, normalised, lowercased, whitespace folded; never a lane, worker, path or file name) must match
# CM_ASK_DELEGATED_ASK (scripts/ask-deny.sh) end to end: one configured class phrase, with no free words ([verb] [the]
# <class> [build|release|bundle|update] [version] [to|on|in <track>] [today|tonight|now]). Any other wording, a bare
# `release 1.4.2 to production` included, is the owner's, and with no class configured every release or deploy ask is;
# so is a question and topic over 200 characters. For every kind, a non-text question, topic, lane, worker or path, a
# files[] that is not a list of text, or those fields over 4000 characters as JSON, is the owner's before any
# normalising runs. Or an own-scope kind (code, design, test, scope, product) that passes the same gates as
# ask-timeout.sh: files[] a non-empty list of paths unless noCode is true (and a noCode ask with no PR on it or its
# worker), no listed file outside the allowlist or on a never path, and a plain ASCII text (question, topic, lane,
# worker, path, files[]) with no owner-only subject in the scripts/ask-deny.sh scan (RLS, a migration, auth, payments
# and the rest). A secrets ask ALWAYS goes to the owner, whatever project it names: whether a key is shared with
# production is a property of the key, not of the wording, so no marker or word scan can clear one. Every other ask is
# owner-only too. PRs: labelled do-not-merge (discover.sh prs.open[].labels, names), every PR while the ledger freeze
# is on, PRs authored by a collaborator (messaging.collaborators), the PR of a waiting lane (that worktree, by name and
# host; parked, owner, an open ask, asleep, or a `blocked` action recorded in its episode, checked before PRs are
# judged), and a PR a live ledger ask names (asks[].pr: n, #n, repo#n or a pull URL; a pr that is set but cannot be read
# holds every PR and is listed in gaps[]).
#
# --act records what was done for a row: one JSON line appended to $CM_HOME/stall-actions.ndjson under a lock
# (flock, or a mkdir lock where flock is missing), with the row's HOST column as --host (a lane name can repeat across
# hosts) and optionally its worktree --path. kind: lane, pr, ask. verb: nudge, relay (rung 1), restart, replace,
# escalate (an ask only), close-ask (rung 2), verdict, blocked (rung 3). A text, name, host or path that looks like a credential is refused
# (scripts/secret-shape.sh on the text as written and with dashes read as spaces: token prefixes, a long run, Bearer, a
# password manager access token, a password or login phrase). A verdict also appends a decisions[] record to the ledger through
# cm_ledger_write (references/ledger.md), first; nothing is recorded when that write is refused. On a ledger ask, a
# close-ask sets the ask state closed (closedBy, closedAt, closeReason) and a verdict sets it decided (decidedBy,
# decidedAt, decisionRef = the decisions[] id), in that same write, so ask-timeout.sh stops reporting it VERDICT DUE.
# Only an ask with exactly one open ledger row of that id is changed. escalate is the non-closing rung 2 action of an
# ask: it relays the ask up again, so the ladder reaches rung 3 (the verdict) at the third rung's age. restart and replace are
# refused while resume.lock is held. A bad kind, verb or extra argument is refused without repeating the value given.
#
# Output: the table KIND NAME HOST AGE RUNG DUE ACTED (stalled rows only), one summary line, then a NO-ACTION line
# when flagged. --json: {schema, now, since, rungs, rows, exempt[], unverified, gaps[], noAction, checked}; in rows[]
# and exempt[], each name, text, title, worker, reason, path, owner, host, class or rows[].lanes element that looks
# like a credential (scripts/secret-shape.sh, a row text or title read in full before it is cut to 120 or 80 characters)
# is printed as "[withheld: looks like a credential]" (when that scan fails, all of them are), and a kind outside the
# known list prints as "unknown kind". No usage message repeats an argument given, and a jq error that looks like a
# credential is not printed.
# Inputs are sanitised once at the top of the judge: a row or field of the wrong shape is dropped, so one bad value
# holds only itself (stall-seen.json is rewritten clean). Exit: 0 clean, 4 NO-ACTION, 3 an input missing, unparsable,
# of the wrong shape (not a JSON object, or without its top-level list) or older than 2 ticks
# (2 x the longest schedule.tick_delays_s), 2 usage; --act: 0 recorded, 1 refused, 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/secret-shape.sh
. "$HERE/secret-shape.sh"
# shellcheck source=SCRIPTDIR/ask-deny.sh
. "$HERE/ask-deny.sh"

usage() { cm_warn "stall.sh: ${1:-usage error} (stall.sh --help)"; exit 2; }

# ts_of <ISO|epoch>: epoch seconds, or nothing. A time without a zone is refused, and so is one outside real epoch
# seconds (0 or less, or after 9999-12-31T23:59:59Z): such a value reads as unreadable, so one bad row (an askedAt of
# 1e300, a PR updatedAt of twenty digits) is unverified on its own and never stops the tick in a todate
# shellcheck disable=SC2016  # jq program
TS_DEF='def ts: (if type == "number" then floor elif type != "string" then null
  elif test("^[0-9]+$") then tonumber
  else (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<h>[0-9]{2}):(?<m>[0-9]{2})(:(?<s>[0-9]{2}))?(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$") // null) as $c
    | if $c == null then null
      else (("\($c.d)T\($c.h):\($c.m):\($c.s // "00")Z") | (try fromdateiso8601 catch null)) as $b
        | if $b == null then null elif $c.z == "Z" then $b
          else ($c.z | capture("^(?<g>[+-])(?<oh>[0-9]{2}):?(?<om>[0-9]{2})$")) as $o
            | (($o.oh | tonumber) * 3600 + ($o.om | tonumber) * 60) as $off
            | if $o.g == "+" then $b - $off else $b + $off end end end end)
  | if . == null or (type != "number") or . <= 0 or . > 253402300799 then null else . end;'
ts_of() { jq -nr --arg v "$1" "$TS_DEF"' $v | ts // empty' 2>/dev/null; }

NOW="$(ts_of "${CM_NOW:-$(date -u +%s)}")"
[ -n "$NOW" ] || usage "CM_NOW is not ISO 8601 (with a zone) or epoch seconds"
NOW_ISO="$(jq -nr --argjson n "$NOW" '$n | todate')"

mkdir -p -- "$CM_HOME" 2>/dev/null || true
ACTIONS="$CM_HOME/stall-actions.ndjson"
SEEN="$CM_HOME/stall-seen.json"

VERBS="nudge relay escalate restart replace close-ask verdict blocked"
verb_rung() { case "$1" in nudge|relay) echo 1 ;; escalate|restart|replace|close-ask) echo 2 ;; verdict|blocked) echo 3 ;; *) return 1 ;; esac; }
# looks_secret_text <text>: secret_shaped on the text as written AND with dashes read as spaces (a token split by a dash is
# caught as written; scripts/secret-shape.sh also holds the phrase shapes: Bearer, a password manager access token, password, login)
looks_secret_text() { secret_shaped "$1" || secret_shaped "${1//-/ }"; }
# looks_secret_name <token>: a lane, host or path. A kebab name of 40 or more characters is a long run but not a secret, so the
# long-run rule reads dashes as spaces; a run of 40 or more that mixes upper case and digits is refused as written
looks_secret_name() {
  { secret_shaped_prefix "$1" || secret_shaped "${1//-/ }"; } && return 0
  local r
  for r in $(printf '%s' "$1" | grep -oE '[A-Za-z0-9_-]{40,}'); do
    [[ "$r" =~ [A-Z] ]] && [[ "$r" =~ [0-9] ]] && return 0
  done
  return 1
}

# ---- --act -------------------------------------------------------------------------------------
act_append() { # <json line>: append under a lock
  local line="$1" lock="$CM_HOME/stall-actions.lock" i=0
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 5 9 || { cm_warn "stall.sh: $lock busy: nothing recorded"; exit 1; }
      printf '%s\n' "$line" >> "$ACTIONS" || exit 1
    ) 9>>"$lock"
    return
  fi
  # no flock (stock macOS): a mkdir lock holding its owner pid. It is held for one append, so one over a minute old whose
  # owner is gone was left by a killed run: retired by rename (one reclaimer wins) and judged again on the tombstone, as
  # codemode-recover.sh take_lock does. A live lock moved by mistake is never deleted: its tombstone waits for the sweep.
  local d="$lock.d" p t
  until mkdir "$d" 2>/dev/null; do
    for t in "$d".dead.*; do if [ -d "$t" ] && act_lock_stale "$t"; then rm -rf -- "${t:?}"; fi; done
    p="$(cat -- "$d/pid" 2>/dev/null || true)"; t="$d.dead.$$"
    if act_lock_stale "$d" && [ ! -e "$t" ] && mv "$d" "$t" 2>/dev/null; then
      if [ "$(cat -- "$t/pid" 2>/dev/null || true)" = "$p" ] && act_lock_stale "$t"; then rm -rf -- "${t:?}"; fi
      continue
    fi
    i=$((i + 1)); [ "$i" -gt 50 ] && { cm_warn "stall.sh: $d busy: nothing recorded"; return 1; }
    sleep 0.1
  done
  printf '%s\n' "$$" > "$d/pid" 2>/dev/null
  printf '%s\n' "$line" >> "$ACTIONS"; local rc=$?
  if [ "$(cat -- "$d/pid" 2>/dev/null || true)" = "$$" ]; then rm -f -- "$d/pid"; rmdir "$d" 2>/dev/null || true; fi
  return "$rc"
}
# act_lock_stale <dir>: over a minute old and its owner pid (or no pid at all) names no live process
act_lock_stale() {
  local p
  [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
  p="$(cat -- "$1/pid" 2>/dev/null || true)"
  [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null
}

do_act() { # <kind> <name> <verb> <text> <host|""> <path|"">
  local kind="$1" name="$2" verb="$3" text="$4" host="$5" path="$6" rung rec
  case "$kind" in lane|pr|ask) ;; *) usage "--act: kind must be lane, pr or ask (the value given is not repeated)" ;; esac
  case " $VERBS " in *" $verb "*) ;; *) usage "--act: verb must be one of: $VERBS (the value given is not repeated)" ;; esac
  { [ "$verb" != escalate ] || [ "$kind" = ask ]; } || usage "--act: escalate is an ask verb (a lane or PR restarts or is re-placed at rung 2)"
  [[ "$name" =~ ^[A-Za-z0-9._#:@/+-]{1,160}$ ]] || usage "--act: name must be one plain token (letters, digits, . _ # : @ / + -)"
  if [ -n "$host" ]; then
    [[ "$host" =~ ^[A-Za-z0-9._:@+-][A-Za-z0-9._:@+\ -]{0,99}$ ]] || usage "--act: --host must be a host name (letters, digits, space, . _ : @ + -)"
  fi
  if [ -n "$path" ]; then
    [[ "$path" =~ ^/[A-Za-z0-9._~@+/\ -]{0,400}$ ]] || usage "--act: --path must be an absolute worktree path (letters, digits, space, . _ ~ @ + / -)"
  fi
  text="$(printf '%s' "$text" | tr '\000-\037\177' '  ' | sed -e 's/^ *//' -e 's/ *$//')"
  [ -n "$text" ] || usage "--act: the text says what was done, it cannot be empty"
  [ "${#text}" -le 500 ] || usage "--act: text over 500 characters"
  if looks_secret_text "$text" || looks_secret_name "$name" || { [ -n "$host" ] && looks_secret_name "$host"; } \
     || { [ -n "$path" ] && looks_secret_name "$path"; }; then
    cm_warn "REFUSED: the text, name, host or path looks like a credential; nothing recorded. Say what was done without the value."
    exit 1
  fi
  if { [ "$verb" = restart ] || [ "$verb" = replace ]; } && cm_resume_lock_held; then
    cm_warn "REFUSED: $CM_HOME/resume.lock is held: no restart or re-place runs now (rung 2 waits); nothing recorded"
    exit 1
  fi
  rung="$(verb_rung "$verb")"
  rec="$(jq -nc --arg at "$NOW_ISO" --arg k "$kind" --arg n "$name" --arg v "$verb" --argjson r "$rung" --arg t "$text" \
    --arg h "$host" --arg p "$path" \
    '{at: $at, kind: $k, name: $n, host: (if $h == "" then null else $h end), path: (if $p == "" then null else $p end),
      verb: $v, rung: $r, text: $t, by: "concertmaster"}')" || exit 1
  # a close-ask or a verdict on a ledger ask resolves that ask in the ledger in the same write, so ask-timeout.sh
  # (VERDICT DUE) and this script read one state: the ask is no longer open. Only an ask with exactly one open ledger row
  # of that id is touched (a duplicate id is ambiguous: the action is recorded, the ledger is left alone).
  if [ "$verb" = verdict ] || { [ "$verb" = close-ask ] && [ "$kind" = ask ]; }; then
    if [ -n "${LEDGER:-}" ]; then export CM_LEDGER="$LEDGER"; fi
    local d="" did="" ast="" prog
    if [ "$verb" = verdict ]; then
      did="d-$NOW-$$-$RANDOM"
      d="$(jq -c --arg id "$did" '{id: $id, at, subject: ({kind, name} + (if .host == null then {} else {host} end)), rung, text, source: "stall.sh", by}' <<<"$rec")" || exit 1
      ast=decided
    else
      ast=closed
    fi
    # shellcheck disable=SC2016  # jq program
    prog='(if $kind == "ask" and (.asks | type) == "array" and ([.asks[] | select(type == "object" and .id == $aid and .state == "open")] | length) == 1
           then .asks |= map(if type == "object" and .id == $aid and .state == "open"
                             then . + {state: $ast} + (if $ast == "decided" then {decidedBy: "concertmaster", decidedAt: $at, decisionRef: $did} else {closedBy: "concertmaster", closedAt: $at, closeReason: $text} end)
                             else . end)
           else . end)'
    if [ -n "$d" ]; then
      # shellcheck disable=SC2016  # jq program
      prog='.decisions = (((.decisions // []) | if type == "array" then . else error("decisions is not a list") end) + [$d]) | '"$prog"
    else
      d='null'
    fi
    if ! cm_ledger_write "$prog" --argjson d "$d" --arg kind "$kind" --arg aid "$name" --arg ast "$ast" --arg at "$NOW_ISO" --arg did "$did" --arg text "$text"; then
      cm_warn "REFUSED: the $verb could not be written to the ledger; nothing recorded"
      exit 1
    fi
  fi
  act_append "$rec" || { cm_warn "stall.sh: could not append to $ACTIONS"; exit 1; }
  printf 'recorded %s %s%s %s (rung %s) at %s\n' "$kind" "$name" "${host:+@$host}" "$verb" "$rung" "$NOW_ISO"
  exit 0
}

# ---- args --------------------------------------------------------------------------------------
CLS=""; DISC=""; ASKS=""; LEDGER=""; SINCE=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --classify|--discover|--asks|--ledger|--since)
      [ $# -ge 2 ] && [ -n "$2" ] || usage "$1 needs a value"
      case "$1" in --classify) CLS="$2" ;; --discover) DISC="$2" ;; --asks) ASKS="$2" ;; --ledger) LEDGER="$2" ;; --since) SINCE="$2" ;; esac
      shift 2 ;;
    --json) JSON=1; shift ;;
    --act)
      [ $# -ge 5 ] || usage "--act needs <kind> <name> <verb> <text>"
      A_KIND="$2"; A_NAME="$3"; A_VERB="$4"; A_TEXT="$5"; A_HOST=""; A_PATH=""; shift 5
      while [ $# -gt 0 ]; do
        case "$1" in
          --ledger) [ $# -ge 2 ] || usage "--ledger needs a file"; LEDGER="$2"; shift 2 ;;
          --host) [ $# -ge 2 ] && [ -n "$2" ] || usage "--host needs a host name"; A_HOST="$2"; shift 2 ;;
          --path) [ $# -ge 2 ] && [ -n "$2" ] || usage "--path needs a worktree path"; A_PATH="$2"; shift 2 ;;
          *) usage "unknown arg after --act (the value given is not repeated)" ;;
        esac
      done
      do_act "$A_KIND" "$A_NAME" "$A_VERB" "$A_TEXT" "$A_HOST" "$A_PATH" ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) usage "unknown arg (the value given is not repeated)" ;;
  esac
done
[ -n "$CLS" ] && [ -n "$DISC" ] && [ -n "$ASKS" ] && [ -n "$LEDGER" ] && [ -n "$SINCE" ] \
  || usage "--classify, --discover, --asks, --ledger and --since are all required"
SINCE_S="$(ts_of "$SINCE")"
[ -n "$SINCE_S" ] || usage "--since is not ISO 8601 with a zone (or epoch seconds): $SINCE"

# ---- config ------------------------------------------------------------------------------------
RUNGS="$(cm_cfg_json .schedule.stall_rungs_min '[30,60,90]')"
if ! jq -e 'type == "array" and length == 3 and all(.[]; type == "number" and . > 0 and . == floor) and .[0] < .[1] and .[1] < .[2]' <<<"$RUNGS" >/dev/null 2>&1; then
  cm_warn "stall.sh: schedule.stall_rungs_min must be 3 rising whole minutes; using [30, 60, 90]"
  RUNGS='[30,60,90]'
fi
TICK_S="$(cm_cfg_json .schedule.tick_delays_s '{}' | jq -r '[.[]? | numbers] | max // 1800' 2>/dev/null)"
case "$TICK_S" in ''|*[!0-9]*) TICK_S=1800 ;; esac
MAX_AGE_S=$((2 * TICK_S))
NEVER="$(cm_cfg_json .worktrees.never_touch '[]')"
COLLAB="$(cm_cfg_json .messaging.collaborators '[]' | jq -c '[.[]? | .github? // empty | strings | ascii_downcase]' 2>/dev/null || echo '[]')"
HELD=false; if cm_resume_lock_held; then HELD=true; fi

# ---- inputs: present, parsable, the right shape, fresh -----------------------------------------
stale() { printf 'STALE-INPUT %s\n' "$1"; cm_warn "stall.sh: $1: nothing judged (rerun discover, classify and asks this tick)"; exit 3; }
check_doc() { # <label> <file> <jq shape test>
  local label="$1" f="$2" shape="$3" g gs
  [ -r "$f" ] && [ -s "$f" ] || stale "$label $f is missing or empty"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || stale "$label $f is not a JSON object"
  jq -e "$shape" "$f" >/dev/null 2>&1 || stale "$label $f does not have the expected shape"
  g="$(jq -r '.generatedAt // empty | tostring' "$f" 2>/dev/null)"
  gs="$(ts_of "$g")"
  [ -n "$gs" ] || stale "$label $f has no readable generatedAt"
  [ $((NOW - gs)) -le "$MAX_AGE_S" ] || stale "$label $f is $(( (NOW - gs) / 60 ))m old (over 2 ticks, ${MAX_AGE_S}s)"
}
check_doc classify "$CLS" '.schema == "concertmaster.classify/v1" and (.items | type == "array")'
check_doc discover "$DISC" '.schema == "concertmaster.discover/v1" and (.hosts | type == "array") and (.prs.open | type == "array")'
check_doc asks "$ASKS" '(.asks | type == "array")'
[ -r "$LEDGER" ] && [ -s "$LEDGER" ] || stale "ledger $LEDGER is missing or empty"
jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1 || stale "ledger $LEDGER is not a JSON object"
cm_ledger_guard "$LEDGER" || stale "ledger $LEDGER belongs to another project"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-stall.XXXXXX")" || { cm_warn "stall.sh: cannot create a temp dir"; exit 3; }
trap 'rm -rf -- "${TMP:?}"' EXIT
if [ -s "$ACTIONS" ]; then jq -cR 'fromjson? | select(type == "object")' "$ACTIONS" > "$TMP/acts.ndjson" 2>/dev/null || : > "$TMP/acts.ndjson"; else : > "$TMP/acts.ndjson"; fi
if [ -s "$SEEN" ] && jq -e 'type == "object"' "$SEEN" >/dev/null 2>&1; then cp -- "$SEEN" "$TMP/seen.json"; else printf '{}\n' > "$TMP/seen.json"; fi

# ---- judge -------------------------------------------------------------------------------------
# shellcheck disable=SC2016  # jq program
PROG="$TS_DEF"'
def lc: ascii_downcase;
def normpath: if type == "string" then sub("/+$"; "") else "" end;
def agem($p): ((($now - $p) / 60) | floor);
# ---- sanitise: every input is normalised ONCE here, before anything reads it, so one value of the wrong shape (a
# freeze that is a string, a queue item whose lane is a number, a seen entry that is a list) drops that value or row
# and never stops the tick for the fleet. jq // does not catch a type error, so no later default could. Rows keep only
# the fields this program reads, each of the type it expects (null when it was anything else). Never widening: where a
# null would match MORE (a null host matches every host, a null action host or path matches any), a value of the wrong
# type drops its row, or becomes a sentinel that matches nothing ("(invalid host)": a host never read, so unverified)
def s_str: if type == "string" then . else null end;
def s_num: if type == "number" then . else null end;
def s_obj: if type == "object" then . else {} end;
def s_objs: if type == "array" then map(select(type == "object")) else [] end;
def s_strs: if type == "array" then map(select(type == "string")) else [] end;
def s_pr: if type == "object" and (.number | type) == "number" then {number: .number, state: (.state | s_str)} else null end;
def s_ok: . == null or type == "string";
def s_host: if s_ok then . else "(invalid host)" end;
# s_mark($m): a value of the wrong type becomes the never-matching marker $m, never null (null defaults to a real value
# in this program: a null repo to the main repo, a null path to any path, a null owner to the lane name)
def s_mark($m): if s_ok then . else $m end;
($cls[0] | s_obj) as $C0
| {generatedAt: $C0.generatedAt,
   items: [ $C0.items | s_objs[]
            | {host: (.host | s_host), name: (.name | s_mark("(invalid name)")), path: (.path | s_mark("(invalid path)")),
               class: (.class | s_str), reason: (.reason | s_str), worktreeId: (.worktreeId | s_str), idleMinutes: (.idleMinutes | s_num),
               pr: (.pr | s_pr), repo: (.repo | s_mark("(invalid repo)")), owner: (.owner | s_mark("(invalid owner)")),
               ownerSource: (.ownerSource | s_str)} ],
   ownership: {leadDead: [ ($C0.ownership | s_obj).leadDead | s_objs[] | {open: (.open | s_strs)} ]}} as $C
| ($disc[0] | s_obj) as $D0
| {mainRepo: ($D0.mainRepo | s_str),
   hosts: [ $D0.hosts | s_objs[] | {name: (.name | s_str), truncated: (.truncated == true)} ],
   worktrees: [ $D0.worktrees | s_objs[] | select((.host | s_ok) and (.path | s_ok))
                | {host, path, comment: (.comment | s_str)} ],
   # an open PR whose repo is present but not text is dropped: a null repo reads as the main repo and would collide
   prs: {open: [ ($D0.prs | s_obj).open | s_objs[] | select((.number | type) == "number" and (.repo | s_ok))
                 | {number, title: (.title | s_str), headRefOid: (.headRefOid | s_str), updatedAt, repo: (.repo | s_str),
                    author: (.author | if type == "object" then (.login | s_str) else s_str end),
                    labels: [ .labels | if type == "array" then .[] else empty end
                              | if type == "object" then (.name | s_str // empty) elif type == "string" then . else empty end ]} ]},
   errors: [ $D0.errors | s_objs[] | {where: (.where | s_str)} ]} as $D
| ($asksDoc[0] | s_obj) as $A0
| {asks: [ $A0.asks | s_objs[] | {host: (.host | s_host), worktree, path: (.path | s_str), tag, text: (.text | s_str), firstSeen} ],
   unreachable: [ $A0.unreachable | s_objs[] | {host: (.host | s_str)} ],
   hostsRead: ($A0.hostsRead | if type == "array" then map(s_str // empty) else null end)} as $A
| ($led[0] | s_obj) as $L0
| ($L0 + {workers: ($L0.workers | s_obj | with_entries(select(.value | type == "object" and (.host | s_ok))
                     | .value |= (. + {state: (.state | s_str), path: (.path | s_str), host: (.host | s_str),
                                       lane: (.lane | s_str), worktreeId: (.worktreeId | s_str)}))),
          asks: ($L0.asks | s_objs),
          freeze: ($L0.freeze | s_obj),
          queue: {items: [ ($L0.queue | s_obj).items | s_objs[] | select((.lane | type) == "string" and (.state | type) == "string") ]},
          lanes: ($L0.lanes | s_obj | with_entries(select(.value | type == "object")
                   | .value.queue |= (if type == "array" then . else [] end)))}) as $L
| ($C.generatedAt | ts) as $cgen
| ($rungs[0]) as $r1 | ($rungs[1]) as $r2 | ($rungs[2]) as $r3
| ($never | map(lc)) as $nt
| ([ $D.hosts[]? | select(.truncated == true) | .name ]) as $trunc
| ([ $A.unreachable[]? | (.host // empty) ]) as $askBad
# asks.sh hostsRead: a host missing from it (its host list failed, so only local was read) is not read in full
| ($A.hostsRead | if type == "array" then . else null end) as $hostsRead
| def unread($h): ($h == null) or (($askBad | index($h)) != null) or ($hostsRead != null and ($hostsRead | index($h)) == null); .
| ((($D.mainRepo // "") | split("/") | last // "") | lc) as $mainRepo
| ([ ($D.errors // [])[] | select((.where // "") | startswith("gh pr list open")) ] | length > 0) as $prFail
| ([ ($D.worktrees // [])[] | {key: ((.host // "") + "\u0000" + (.path | normpath)), value: (.comment // "")} ] | from_entries) as $comments
| ([ (($L.workers // {}) | if type == "object" then . else {} end) | to_entries[]
     | select(.value | type == "object") | select((.value.state | cm_state_dead) | not) ]) as $lw
| ([ ($L.asks // [])[]? | select(type == "object" and .state == "open") ]) as $lasks
# the own worktree of the concertmaster: classify self items (host + path or name) and worktrees.self_name on any host
| ([ $C.items[]? | select(type == "object" and (.ownerSource // "") == "self")
     | {host: (.host // null), name: ((.name // "") | lc), path: (.path | normpath)} ]) as $selfItems
| ($selfName | lc) as $sn
# names and paths are trimmed first, so a padded " concertmaster " is the concertmaster as well
| def isSelf($h; $w; $pth): (($w | lc | gsub("^\\s+|\\s+$"; "")) as $wl
    | ($pth | if type == "string" then gsub("^\\s+|\\s+$"; "") else . end | normpath) as $pp
    | ($sn != "" and $wl == $sn) or any($selfItems[]; (.host == null or $h == null or .host == $h) and ((.name != "" and .name == $wl) or (.path != "" and .path == $pp)))); .
# the worker row of a ledger ask (live ledger workers only), its lane (asks[].lane only: workers.<worker>.lane is an
# ownership label such as dev-sweeper, not a worktree name, so it is never read here),
# and the PR it names (asks[].pr: a number, "#n", "n", "repo#n" or a github.com/<owner>/<repo>/pull/<n> URL), as a
# lowercased "repo#n" key; a pr that is set but cannot be read is "?" (fail safe: every PR is held while it stands)
| def askWorker: ((.worker // "") | tostring | gsub("^\\s+|\\s+$"; "")) as $w
    | if $w == "" then null else ([ $lw[] | select(.key == $w) | .value ] | first) end; .
| def askLane: ((.lane // "") | tostring | lc | gsub("^\\s+|\\s+$"; "")); .
| def askPrKey: (.pr // null)
    | if . == null then null
      elif type == "number" then (if . == floor and . > 0 then $mainRepo + "#" + (floor | tostring) else "?" end)
      elif type == "string" then
        ((capture("^\\s*ht" + "tps?://git" + "hub\\.com/[A-Za-z0-9._-]+/(?<r>[A-Za-z0-9._-]+)/pull/(?<n>[0-9]+)([/?#].*)?\\s*$")
          // capture("^\\s*((?<r>[A-Za-z0-9._/-]+)#|#)?(?<n>[0-9]+)\\s*$")) // null)
        | if . == null then "?" else (((.r // $mainRepo) | lc | split("/") | last) + "#" + .n) end
      else "?" end; .
# a comment ask row: its worktree, tag and firstSeen as strings (any other type reads as "?", "cm:ask", ""), so a
# malformed asks.sh row never stops the tick nor puts its value in a name
| def awt: (.worktree | if type == "string" then . else "?" end); .
| def atag: (.tag | if type == "string" then . else "cm:ask" end); .
| def afs: (.firstSeen | if type == "string" then . else "" end); .
# a ledger ask from the own worktree of the concertmaster (by its worker id, the path or name of the worker worktree,
# its lane, or a worktree or path field on the ask): a held item, as for a comment ask there
| def askSelf: askWorker as $wv
    | ([ (.worker // empty | tostring), (.lane // empty | tostring), (.worktree // empty | tostring),
         ($wv | if . == null then empty else ((.path | normpath | split("/") | last) // empty) end) ]) as $names
    | ([ (.path // empty | tostring), ($wv | if . == null then empty else (.path // empty | tostring) end) ]) as $paths
    | (($wv | if . == null then null else .host end) // null) as $h
    | any($names[]; isSelf($h; .; "")) or any($paths[]; isSelf($h; ""; .)); .
# a ledger ask the ladder may act on: null, else why it is owner-only (Blocked, not stalled). release and deploy are
# delegated (config drive.delegated_classes); an own-scope kind (references/away-timeout.md) only past the
# ask-timeout.sh gates and deny scan (scripts/ask-deny.sh); secrets, every other kind, a missing kind and an unknown
# one is owner-only
# the kinds this script names in a reason (references/ledger.md asks[].kind); any other value prints as "unknown kind"
# so a credential-shaped kind never reaches the output
| def knownKinds: ["release", "deploy", "secrets", "code", "design", "test", "scope", "product", "merge", "credentials",
                   "migration", "auth", "payments", "prod-data", "teardown", "owner", "remove-standing",
                   "accept-unmerged-beads"]; .
# a malformed or over-long ledger ask, for EVERY kind, before anything reads its text: question, topic, lane, worker
# and path must be text and files a list of text, else owner-only; then the fields as JSON may not run over 4000
# characters (linear: tojson of text only). Nothing that normalises or scans text (ask_norm, gsub, the own-worktree
# check) runs on such an ask: a gsub over tens of thousands of characters is slow enough to stall the tick
| def askBad($k):
    (if ($k | IN(knownKinds[])) then $k else "unknown kind" end) as $ks
    | if ([.question, .topic] | any(. != null and type != "string")) then "of kind \($ks) with a non-text question or topic"
      elif ([.lane, .worker, .path] | any(. != null and type != "string")) then "of kind \($ks) with a non-text field"
      elif (.files // null) != null and ((.files | type) != "array" or any(.files[]; type != "string")) then
        "of kind \($ks) with an invalid files[]"
      elif ([.question, .topic, .lane, .worker, .path, .files] | tojson | length) > 4000 then
        "of kind \($ks) with an over-long ask text"
      else null end; .
| def askOwnerWhy($k):
    (if ($k | IN(knownKinds[])) then $k else "unknown kind" end) as $ks
    | askBad($k) as $bad
    | ([.question, .topic] | map(strings) | join(" ") | length) as $qlen
    | if $bad != null then $bad
      elif ($k | IN("release", "deploy")) then
        # narrow scan: a runbook or cutover stays with the owner: a go line (a line `go <command> <staging|production>
        # ...`), cutover or a runbook step; so does any secret or account-wide key. A false hit only sends the ask to
        # the owner
        # $tl: the whole ask text (question, topic, lane, worker, path, files) for the cutover and secret scans, where
        # extra text can only fail safe; $qt: the question and topic alone, the only text the allowlist
        # reads, so a lane, worker, path or file name can never name the class for the ask
        # newlines and tabs fold to spaces before the secret scan and the allowlist (a word split over two lines is
        # still that word); the cutover scan keeps the lines, since a go line is a line. $qt also loses its outer
        # whitespace and runs of spaces, so the allowlist reads the words, not their spacing
        # a release phrase is short: a question and topic over 200 characters go to the owner before any normalising
        ([.question, .topic] | any(. != null and type != "string")) as $nontext
        | if $nontext then "of kind \($ks) with a non-text question or topic"
          elif $qlen > 200 then "of kind \($ks) with an over-long question or topic"
          else
        ask_text as $t
        | ($t | ascii_downcase) as $tl
        | ($tl | gsub("[\\n\\r\\t\\x0b\\f]+"; " ")) as $tlf
        | ([.question, .topic] | map(strings) | join(" ") | ask_norm | ascii_downcase | gsub("\\s+"; " ") | gsub("^ | $"; "")) as $qt
        # a go line starts after any line break: newline, carriage return, vertical tab (\x0b) or form feed
        | if ($t | explode | any(. > 127)) then "of kind \($ks) with non-ASCII text"
          elif ($tl | test("(^|[\\n\\r\\x0b\\f])[-*>`\\s]*go\\s+[a-z0-9-]+\\s+(staging|production)([^a-z0-9]|$)|cutover|runbook")) then
            "of kind \($ks) naming a runbook or cutover (a go line, a cutover, a runbook step)"
          # the secret scan is the credential segment of the shared deny list (CM_ASK_DENY_CRED in scripts/ask-deny.sh,
          # passed as $askCred, so the two cannot drift) plus the release-only terms below; a short word (key, keys, pat,
          # pats, cert, certs, p8, p12, dsn, bearer) counts only as a word, so keyboard, monkey, pathfinder and patch do
          # not. Over-matching key or pats in lane or worker text is accepted: it only sends the ask to the owner
          elif ($tlf | test("\\b(" + $askCred + ")\\b"))
               or ($tlf | test("secret|credential|api.?key|token|password|passphrase|keystore|signing|private|account.?wide|org.?wide|repo.?level|service.?role|service.?account|access.?key|webhook|vault|provisioning|keychain|hmac|\\.env\\b|\\b(pem|jks)\\b|(^|[^a-z0-9])(keys?|pats?|certs?|certificates?|p8|p12|dsn|bearer)([^a-z0-9]|$)")) then
            "of kind \($ks) naming a secret or an account-wide key"
          # default deny, by an allowlist of the shape and not a denylist of words: the question and topic must match
          # CM_ASK_DELEGATED_ASK (scripts/ask-deny.sh, built from config drive.delegated_classes, passed as $askAsk)
          # end to end: one class phrase with no free words. Any other wording goes to the owner, and with no class
          # configured every release or deploy ask does. The cutover and secret scans above still run first
          elif ($qt | test($askAsk) | not) then
            "of kind \($ks): a delegated ask must be one class phrase: <verb> the <class> <version> <track>; any other wording goes to the owner"
          else null end end
      # a secrets ask never ladders: a key shared with production (an OTA or store signing key, a CLI token, a repo-level
      # GitHub secret) reads the same as a test one, so the owner decides every one
      elif $k == "secrets" then "of kind secrets (a secrets ask always goes to the owner)"
      elif ($k | IN("code", "design", "test", "scope", "product")) then
        ask_text as $t | ask_bad_files($askAllow; $askNever) as $bf | ask_hits($askDeny; $askSquash) as $h
        # the lane gate of ask-timeout.sh: the ask lane, else the ledger worker lane (an ownership label such as
        # dev-sweeper), lowercased and trimmed; ask_scope_why refuses no issue, no lane, an ops, epic or pr-sweeper lane
        # and an epic plan-ready approval, whatever the text says
        | ((.lane // ((($L.workers // {}) | if type == "object" then . else {} end)[(.worker // "") | tostring | gsub("^\\s+|\\s+$"; "")]
                      | if type == "object" then .lane else null end) // "") | tostring | ascii_downcase | gsub("^\\s+|\\s+$"; "")) as $sl
        | ask_scope_why($sl; $askOwner) as $sw
        | if $sw != null then "of kind \($ks): \($sw)"
          elif ($t | explode | any(. > 127)) then "of kind \($ks) with non-ASCII text"
          elif (.files // null) != null and (.files != ask_files) then "of kind \($ks) with an invalid files[]"
          # as ask-timeout.sh: the changed paths are listed (files[]) unless noCode is true, and a noCode ask has no PR
          elif (ask_files | length) == 0 and .noCode != true then "of kind \($ks) with no files[] (list the changed paths, or set noCode)"
          elif (ask_files | length) == 0
               and ((.pr // ((($L.workers // {}) | if type == "object" then . else {} end)[(.worker // "") | tostring | gsub("^\\s+|\\s+$"; "")]
                             | if type == "object" then .pr else null end)) != null) then "of kind \($ks) with noCode but the worker has a PR"
          elif ($bf | length) > 0 then "of kind \($ks) touching \($bf[0])"
          elif ($h | length) > 0 then "of kind \($ks) naming \($h | join(","))"
          else null end
      elif $k == "" then "with no kind"
      else (if $ks == "unknown kind" then "of an unknown kind" else "of kind \($ks)" end) end; .
| ($L.freeze // {}) as $fz
| (($fz.state // "") == "on" and ((($fz.ttl // null) | ts) as $t | $t == null or $now < $t)) as $frozen
# PR head first-seen: a new sha resets it; first sight starts at updatedAt (the push was at or before it)
# a seen entry that is not an object with a text sha is dropped (the file is rewritten clean on this run)
| (($seen[0] | s_obj).prs | s_obj | with_entries(select(.value | type == "object" and (.sha | type) == "string"))) as $oldSeen
| ([ $D.prs.open[]? | select(.number != null)
     | (((.repo // $mainRepo) | lc) + "#" + (.number | tostring)) as $k
     | ($oldSeen[$k] // null) as $o
     | select((.headRefOid | type) == "string" and (.headRefOid | length) > 0)
     | {key: $k, value: (if $o != null and $o.sha == .headRefOid then $o + {lastSeen: $nowIso}
                         else {sha: .headRefOid, firstSeen: (if $o == null then ((.updatedAt | ts // $now) | todate) else $nowIso end), lastSeen: $nowIso} end)} ]
   | from_entries) as $curSeen
| (if $prFail then $oldSeen + $curSeen else $curSeen end) as $newSeen
| [ $acts[] | select(type == "object" and (.at | type) == "string" and (.host | s_ok) and (.path | s_ok)) | . + {t: (.at | ts)}
    | select(.t != null and (.kind | type) == "string" and (.name | type) == "string") ] as $A2
# a name on more than one host: an action recorded without --host matches none of them
| ([ ($C.items[]? | select(type == "object") | {k: ("lane\u0000" + (if (.name // "") == "" then (.host // "?") else .name end)), h: (.host // null)}),
     ($A.asks[]? | select(type == "object")
      | {k: ("ask\u0000" + (awt + "/" + (atag | sub("^cm:"; "")) + "@" + (afs | gsub("[-:]"; "")))), h: (.host // null)}) ]
   | group_by(.k) | map(select((map(.h) | unique | length) > 1) | .[0].k)) as $ambig
| def mine($kind; $name; $host; $path):
    select(.kind == $kind and .name == $name)
    | select(if $host == null then true elif (.host // null) == null then ($ambig | index($kind + "\u0000" + $name)) == null
             else .host == $host end)
    | select(if $path == null or (.path // null) == null then true else ((.path | normpath) == ($path | normpath)) end); .
# judge one row: kind, name, host, progress time (epoch), extra fields
| def judge($kind; $name; $host; $p; $extra):
    agem($p) as $age
    | (if $age >= $r3 then 3 elif $age >= $r2 then 2 elif $age >= $r1 then 1 else 0 end) as $ageRung
    | [ $A2[] | mine($kind; $name; $host; ($extra.path // null)) ] as $mine
    | [ $mine[] | select(.t >= $p) ] as $ep
    # the ladder never skips: in time order, an action counts at most one rung above the one before it
    # (a verdict recorded first counts as rung 1)
    | (reduce ($ep | sort_by(.t))[] as $a (0; ([(($a.rung // 0) | numbers), . + 1] | min) as $x | [., $x] | max)) as $last
    | ([ $mine[] | select(.t >= $since) ] | length > 0) as $tick
    | ($ep | sort_by(.t) | last) as $la
    | ([ $ageRung, $last + 1 ] | min) as $rung
    # NO-ACTION counts only an action at or above the due rung: a nudge every tick never hides a missed restart or verdict
    | ([ $mine[] | select(.t >= $since and (((.rung // 0) | numbers) >= $rung)) ] | length > 0) as $tickDue
    | ($held and $rung == 2 and $kind != "ask") as $isHeld
    | ($rung >= 1 and $last < $rung and ($isHeld | not)) as $due
    | {kind: $kind, name: $name, host: $host, ageMinutes: $age, progressAt: ($p | todate), ageRung: $ageRung, rung: $rung,
       due: $due,
       action: (if $rung == 0 then "-" elif $isHeld then "held:resume.lock" elif $due | not then "acted"
                elif $kind == "ask" then ({"1": "relay", "2": "escalate|close-ask", "3": "verdict"}[$rung | tostring])
                else ({"1": "nudge", "2": "restart|replace", "3": "verdict"}[$rung | tostring]) end),
       acted: (if $la == null then null else {verb: $la.verb, at: $la.at, rung: $la.rung} end),
       actedThisTick: $tick, noAction: ($due and ($tickDue | not)),
       closedBy: ([ $ep[] | select(.verb == "blocked" or .verb == "close-ask") ] | sort_by(.t) | last)} + $extra;
  def ex($kind; $name; $host; $code; $why): {kind: $kind, name: $name, host: $host, code: $code, reason: $why};
# ---- asks ----
  ([ $A.asks[]? | select(type == "object")
     | (awt + "/" + (atag | sub("^cm:"; "")) + "@" + (afs | gsub("[-:]"; ""))) as $n
     | if (.host // null) == null then ex("ask"; $n; null; "unverified"; "asks row with no host")
       elif unread(.host) then ex("ask"; $n; .host; "unverified"; "asks of host \(.host) not read in full")
       elif isSelf(.host; awt; (.path | if type == "string" then . else "" end)) then ex("ask"; $n; .host; "held"; "\(atag) in the own worktree of the concertmaster: a held item, the owner decides (Blocked, not stalled)")
       elif atag == "cm:waiting-owner" then ex("ask"; $n; .host; "owner"; "cm:waiting-owner: waiting on the owner (Blocked, not stalled)")
       # an asks.sh row (cm:ask, cm:blocked) has no kind, so no deny scan can clear it: owner-only, never laddered. A
       # delegated question ladders as its ledger ask, which carries the kind
       else ex("ask"; $n; .host; "owner"; "\(atag) from a lane: an asks.sh row has no kind, so it is owner-only (Blocked, not stalled); a delegated one ladders as a ledger ask") end ]
   + [ $lasks | to_entries[] | .key as $li | .value | select((.id | type) == "string" and (.id | length) > 0)
     | (.askedAt | ts) as $p
     | ((.kind // .scope // "") | if type == "string" then ascii_downcase | gsub("^\\s+|\\s+$"; "") else "" end) as $k
     | askBad($k) as $bad
     | (if $bad != null then $bad else askOwnerWhy($k) end) as $ow
     | if $bad != null then ex("ask"; .id; null; "owner"; "ledger ask \($bad): owner-only, the owner decides (Blocked)")
       elif askSelf then ex("ask"; .id; null; "held"; "ledger ask from the own worktree of the concertmaster: a held item, the owner decides (Blocked, not stalled)")
       elif $ow != null then ex("ask"; .id; null; "owner"; "ledger ask \($ow): owner-only, the owner decides (Blocked)")
       elif $p == null then ex("ask"; .id; null; "unverified"; "askedAt missing or unreadable")
       elif ((.verdictStartedAt | ts) as $vc | $vc != null and $now < $vc + $claimMin * 60) then ex("ask"; .id; null; "held"; "verdict claimed (verdictStartedAt) less than \($claimMin) minutes ago: the claimed verdict is running, no second verdict, relay or close")
       else judge("ask"; .id; null; $p; {worker: (.worker // null | if . == null then null else tostring end),
                                          text: (.question | if type == "string" then .[0:120] else "" end),
                                          _full: {text: (.question | if type == "string" then . else null end), worker: (.worker // null | if . == null then null else tostring end)}}) end
     | . + {_li: $li} ]) as $askRows
# an ask exempts its lane and the PR it names only while the ask row itself is held for the owner or still on the
# ladder, so nothing waits behind an ask past the ladder: a comment ask always (owner-only, held or unverified, by its
# worktree); a ledger ask while it is owner-only, held, or judged with no close-ask or blocked recorded in its episode.
# A closed ledger ask, or one with an unreadable askedAt (unverified), frees its lane and PR to ladder again. A ledger
# ask matches a lane row by name. When it names a worker (asks[].worker set), only that worker counts: its LIVE ledger
# row, by the last part of its path on its host. A dead row (gone, repurposed: ledger.md says its path is gone or now
# belongs to another worker), no ledger row, or a row with no path holds no lane, and never falls back to asks[].lane. asks[].lane is read only when the ask names no worker and carries no followUp, because
# scripts/followups.sh writes the ownership label of the asking worker (dev-sweeper) there; it names no host, so it
# matches a lane of that name on every host. Its PR is asks[].pr. Liveness is per ask row (its index in asks[]), not per
# id, and a ledger ask with no non-empty string id is never judged, so it holds nothing
| ([ $askRows[] | select(._li != null and ((.code? // "") as $c | $c == "owner" or $c == "held" or ($c == "" and .closedBy == null))) | ._li ]) as $liveIdx
| ([ $liveIdx[] as $j | $lasks[$j] ]) as $liveL
| ([ $A.asks[]? | select((.host | type) == "string") | {host, worktree: (awt | lc)} ]
   + [ $liveL[] | ((.worker // "") | tostring | gsub("^\\s+|\\s+$"; "")) as $wn
       | if $wn != "" then
           askWorker as $wr
           # a worker row with no host would match that worktree name on every host: it holds nothing
           | if ($wr | type) == "object" and (($wr.path | normpath) != "") and (($wr.host // null) | type) == "string" and ($wr.host | length) > 0
             then {host: $wr.host, worktree: (($wr.path | normpath | split("/") | last // "") | lc)} else empty end
         elif (.followUp // null) != null then empty
         else (askLane | if . == "" then empty else {host: null, worktree: .} end) end ]) as $askLanes
| ([ $liveL[] | askPrKey | select(. != null) ] | unique) as $askPrs
| ([ ($C.ownership.leadDead // [])[]? | .open[]? | lc ]) as $orphanedKids
| ([ ($L.queue.items // [])[]? | select(type == "object" and (.state | IN("queued", "granted"))) | (.lane // "") | lc ]
   + [ (($L.lanes // {}) | if type == "object" then to_entries else [] end)[] | select(((.value.queue // []) | length) > 0) | .key | lc ]) as $queued
# ---- lanes ----
| ([ $C.items[]? | select(type == "object")
     | . as $i
     | ((if (.name // "") == "" then (.host // "?") else .name end)) as $n
     | ($n | lc) as $nl
     | ([ $lw[] | select(.value.host == null or .value.host == $i.host)
          | select(((($i.worktreeId // "") != "") and .value.worktreeId == $i.worktreeId) or ((.value.path | normpath) != "" and (.value.path | normpath) == ($i.path | normpath)))
          | .value.state | cm_state_norm ]) as $states
     | ($comments[(($i.host // "") + "\u0000" + ($i.path | normpath))] // "") as $cm
     | ([ $cm | comment_segs[] | select(test("^cm:waiting-owner(\\s|:|$)")) ] | length > 0) as $waitOwner
     | (if $i.pr != null and ($i.pr.state // "") == "OPEN" then ((($i.repo // $mainRepo) | lc) + "#" + ($i.pr.number | tostring)) else null end) as $prKey
     | if .class == "host-offline" then ex("lane"; $n; .host; "unverified"; "host offline: \(.reason // "unreachable")")
       elif ($trunc | index($i.host)) != null then ex("lane"; $n; .host; "unverified"; "host \(.host) worktree list cut off")
       elif unread($i.host) then ex("lane"; $n; .host; "unverified"; "asks of host \(.host) not read: an open ask cannot be ruled out")
       elif (.class | IN("main-checkout", "other-project", "done-merged", "done-selfreported")) then ex("lane"; $n; .host; "class"; "class \(.class)")
       elif ($nt | index($nl)) != null then ex("lane"; $n; .host; "class"; "worktrees.never_touch")
       elif (.ownerSource // "") == "self" then ex("lane"; $n; .host; "self"; "the concertmaster itself")
       elif ($states | index("asleep")) != null then ex("lane"; $n; .host; "asleep"; "ledger worker asleep: stopped on purpose")
       elif ($states | index("parked")) != null then ex("lane"; $n; .host; "parked"; "ledger worker parked")
       elif ($states | index("blocked-on-owner")) != null then ex("lane"; $n; .host; "owner"; "ledger worker blocked-on-owner (Blocked)")
       elif $waitOwner then ex("lane"; $n; .host; "owner"; "cm:waiting-owner (Blocked)")
       elif ([ $askLanes[] | select(.worktree == $nl and (.host == null or .host == $i.host)) ] | length > 0) then ex("lane"; $n; .host; "ask"; "an open ask is listed: the ask row carries the ladder")
       elif .class == "standing-idle" and $i.owner != "(invalid owner)" and (($queued | index(($i.owner // $n) | lc)) == null) then ex("lane"; $n; .host; "idle"; "standing-idle, nothing queued or granted for it")
       elif ((.ownerSource // "") | startswith("comment:")) and (($orphanedKids | index($nl)) == null) then ex("lane"; $n; .host; "child"; "child of lead \(.ownerSource | sub("^comment:"; "")): the lead drives it")
       else
         # no time written inside a comment counts: discover and classify carry no comment-changed time, and a time in the
         # text (an old note, a deadline just passed) says nothing about when the lane last moved
         # idleMinutes is bounded (0 up to 1e7 minutes, about 19 years); any other value is no idle time at all
         ([ (if (.idleMinutes | type) == "number" and .idleMinutes >= 0 and .idleMinutes < 10000000 and $cgen != null
             then $cgen - (.idleMinutes * 60) else empty end),
            (if $prKey != null then ($newSeen[$prKey].firstSeen // null | ts // empty) else empty end) ] | max) as $p
         | if $p == null then ex("lane"; $n; .host; "unverified"; "no progress time (no idle or PR head)")
           else judge("lane"; $n; .host; [$p, $now] | min; {class: .class, path: .path, owner: (.owner // null), pr: (.pr.number // null)}) end
       end ]) as $laneRows
# a lane that waits (parked, owner, an open ask, asleep, or a recorded `blocked` action in its episode) exempts its PR;
# the recorded check runs here, before PR judging, so the PR of a blocked lane never ladders
# a waiting lane is a worktree (name AND host): its PR is the PR of that worktree only, so a waiting twin@local never
# exempts the PR of an unrelated twin@hb
| ([ $laneRows[] | select(.code? and (.code | IN("parked", "owner", "ask", "asleep"))) ]
   + [ $laneRows[] | select(.code? == null and (.closedBy.verb? // "") == "blocked")
       | {name, host, reason: "recorded blocked at \(.closedBy.at)"} ]) as $waitLanes
# ---- PRs ----
| ([ $D.prs.open[]? | select(.number != null)
     | . as $pr
     | ((.repo // $mainRepo) | lc) as $rp
     | ((if .repo == null or ($rp == $mainRepo) then "" else .repo end) + "#" + (.number | tostring)) as $n
     | ($rp + "#" + (.number | tostring)) as $k
     | ([ .labels[]? | if type == "object" then (.name // "") else tostring end | lc ]) as $labels
     | ([ $C.items[]? | select(.pr != null and .pr.number == $pr.number and ((.repo // $mainRepo) | lc) == $rp)
          | {name: ((if (.name // "") == "" then (.host // "?") else .name end) | lc), host: (.host // null)} ]) as $prItems
     | ([ $prItems[] | .name ]) as $prLanes
     | ([ $waitLanes[] | ((.name // "") | lc) as $x | (.host // null) as $h
          | select(any($prItems[]; .name == $x and .host == $h)) ] | first) as $wl
     | if $prFail then ex("pr"; $n; null; "unverified"; "open PR list failed in discover")
       elif ($labels | index("do-not-merge")) != null then ex("pr"; $n; null; "label"; "label do-not-merge")
       elif $frozen then ex("pr"; $n; null; "freeze"; "held by the merge freeze (window \($fz.window // "?"))")
       elif (((.author // "") | lc) as $au | $collab | index($au)) != null then ex("pr"; $n; null; "human"; "collaborator PR (\(.author)): waiting on a human")
       elif $wl != null then ex("pr"; $n; null; "lane"; "its lane \($wl.name) is exempt: \($wl.reason)")
       elif ($askPrs | index($k)) != null then ex("pr"; $n; null; "ask"; "an open ledger ask names it (asks[].pr): the ask carries the ladder")
       elif ($askPrs | index("?")) != null then ex("pr"; $n; null; "ask"; "an open ledger ask names a PR that cannot be read (asks[].pr): every PR is held until it is fixed")
       else
         ([ ($newSeen[$k].firstSeen // null | ts // empty), (.updatedAt | ts // empty) ] | max) as $p
         | if $p == null then ex("pr"; $n; null; "unverified"; "no head sha and no updatedAt")
           else judge("pr"; $n; null; [$p, $now] | min; {title: (.title | if type == "string" then .[0:80] else "" end), lanes: $prLanes,
                                                             _full: {title: (.title | if type == "string" then . else null end)}}) end
       end ]) as $prRows
| ($askRows + $laneRows + $prRows) as $all
| ([ $all[] | select(.code? == null and .closedBy != null) ]) as $closed
| ([ $all[] | select(.code? == null and .closedBy == null) ]) as $judged
| ($judged | map(select(.rung >= 1)) | sort_by(-.rung, -.ageMinutes, .kind, .name) | map(del(.closedBy, ._li))) as $rows
| ([ $all[] | select(.code? != null) | del(._li) ]
   + [ $closed[] | ex(.kind; .name; .host; "recorded"; "recorded \(.closedBy.verb) at \(.closedBy.at): out of the ladder until it makes progress") ]) as $exempt
| ([ (if $prFail then "discover: open PR list failed, PRs not judged" else empty end),
     (if ($askPrs | index("?")) != null then "ledger: an open ask has an unreadable asks[].pr, every PR held" else empty end) ]) as $gaps
| { schema: "concertmaster.stall/v1", now: $nowIso, since: ($since | todate), rungs: $rungs, resumeLockHeld: $held,
    checked: ($judged | length), rows: $rows, exempt: $exempt,
    unverified: ([ $exempt[] | select(.code == "unverified") ] | length),
    gaps: $gaps,
    noAction: ([ $rows[] | select(.noAction) ] | length > 0),
    seen: {prs: $newSeen} }'

# the state words: lib.sh's cm_state_dead, and a cm_state_norm that leaves a state as it is when lib.sh has none
STATE_DEFS="$CM_JQ_STATE_DEFS"
case "$STATE_DEFS" in *cm_state_norm*) ;; *) STATE_DEFS='def cm_state_norm: .; '"$STATE_DEFS" ;; esac
# an ask whose verdict is claimed (asks[].verdictStartedAt, scripts/ask-timeout.sh --claim) less than this many minutes ago is
# held while the claimed verdict runs: no second verdict, relay or close. Same default and variable as ask-timeout.sh
CLAIM_MIN="${CM_VERDICT_CLAIM_MIN:-30}"
case "$CLAIM_MIN" in ''|*[!0-9]*) cm_warn "stall.sh: CM_VERDICT_CLAIM_MIN must be whole minutes; using 30"; CLAIM_MIN=30 ;; esac
ASK_OWNER="${CM_OWNER_NAME:-}"
if [ -z "$ASK_OWNER" ] || [ "$ASK_OWNER" = owner ]; then ASK_OWNER="the owner"; fi
if ! jq -n -L "$HERE" --slurpfile cls "$CLS" --slurpfile disc "$DISC" --slurpfile asksDoc "$ASKS" --slurpfile led "$LEDGER" \
     --slurpfile acts "$TMP/acts.ndjson" --slurpfile seen "$TMP/seen.json" \
     --argjson claimMin "$CLAIM_MIN" --argjson now "$NOW" --arg nowIso "$NOW_ISO" --argjson since "$SINCE_S" --argjson rungs "$RUNGS" --argjson held "$HELD" \
     --argjson never "$NEVER" --argjson collab "$COLLAB" --arg selfName "${CM_SELF_WORKTREE:-}" \
     --arg askDeny "$CM_ASK_DENY" --arg askCred "$CM_ASK_DENY_CRED" --arg askAsk "$CM_ASK_DELEGATED_ASK" --arg askSquash "$CM_ASK_SQUASH" --arg askAllow "$CM_ASK_ALLOW" --arg askNever "$CM_ASK_NEVER_PATHS" --arg askOwner "$ASK_OWNER" \
     -f <(printf 'include "comment-segs";\n%s\n%s\n%s\n' "$STATE_DEFS" "$CM_ASK_DENY_DEFS" "$PROG") > "$TMP/out.json" 2>"$TMP/jq.err"; then
  JQERR="$(head -c 200 "$TMP/jq.err" | tr '\n' ' ')"
  if looks_secret_text "$JQERR"; then JQERR="the jq error is withheld: it looks like a credential"; fi
  stale "inputs could not be judged ($JQERR)"
fi

# untrusted text copied into the output (a ledger ask id, question and worker, a PR title and its lanes, a lane or
# worktree name, path or owner, a host, an exempt reason), in rows[] and exempt[]: each field (name, text, title,
# worker, reason, path, owner, host, class, and each element of lanes) whose FULL value (row._full holds the text before it was cut to 120 or 80 characters) looks like a
# credential (scripts/secret-shape.sh, as --act checks it: the name predicate for an identifier, so a long kebab lane name
# stays readable, the text predicate for free text) is withheld; _full never reaches the output. Fail
# closed: when the scan itself fails, every one of those fields is withheld (CM_TEST=1 with CM_TEST_FAIL_WITHHOLD=1
# forces that path, for tests)
WH='[withheld: looks like a credential]'
scan_withheld() {
  if [ "${CM_TEST:-}" = 1 ] && [ -n "${CM_TEST_FAIL_WITHHOLD:-}" ]; then return 1; fi
  jq -r '("rows", "exempt") as $a | (.[$a] // []) | to_entries[] | .key as $i | .value as $e
    | (("name", "text", "title", "worker", "reason", "path", "owner", "host", "class") as $f | (($e._full // {})[$f] // $e[$f]) | select(. != null) | tostring
        | [$a, ($i | tostring), $f, "-"] + [.]),
      (($e.lanes // []) | if type == "array" then . else [.] end | to_entries[] | .key as $j | .value | select(. != null) | tostring
        | [$a, ($i | tostring), "lanes", ($j | tostring)] + [.])
    | (.[4] |= gsub("[\t\n\r]"; " ")) | join("\t")' "$TMP/out.json" \
  | while IFS="$(printf '\t')" read -r a i f j v; do
      [ -n "$v" ] || continue
      # an identifier (a lane, host, path, owner, class, worker or lane element) may be a long kebab name: the name
      # predicate, as --act applies it; free text (text, title, reason) keeps the stricter text predicate
      case "$f" in
        name|path|host|owner|class|worker|lanes) looks_secret_name "$v" || continue ;;
        *) looks_secret_text "$v" || continue ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "$a" "$i" "$f" "$j"
    done | sort -u \
  | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {a: .[0], i: (.[1] | tonumber), f: .[2], j: (.[3] | if . == "-" then null else tonumber end)})'
}
if WITHHELD="$(scan_withheld 2>/dev/null)" && [ -n "$WITHHELD" ]; then
  # shellcheck disable=SC2016  # jq program
  PASS_PROG='reduce $w[] as $x (.; if $x.j == null then .[$x.a][$x.i][$x.f] = $wh else .[$x.a][$x.i].lanes[$x.j] = $wh end)'
else
  cm_warn "stall.sh: the credential scan failed: every name, text, title, worker, reason, path, owner, host, class and lane is withheld"
  WITHHELD="[]"
  # shellcheck disable=SC2016  # jq program
  PASS_PROG='(.rows, .exempt) |= map(with_entries(if (.key | IN("name", "text", "title", "worker", "reason", "path", "owner", "host", "class")) and .value != null then .value = $wh
       elif .key == "lanes" and (.value | type) == "array" then .value |= map($wh) else . end))'
fi
if ! jq --argjson w "$WITHHELD" --arg wh "$WH" "$PASS_PROG"' | .rows |= map(del(._full))' \
     "$TMP/out.json" > "$TMP/out.red.json" 2>/dev/null; then
  stale "could not withhold a credential-shaped text"
fi
mv -f -- "$TMP/out.red.json" "$TMP/out.json"

# the PR head first-seen times: atomic replace
if jq '.seen' "$TMP/out.json" > "$SEEN.tmp.$$" 2>/dev/null; then
  mv -f -- "$SEEN.tmp.$$" "$SEEN" || cm_warn "stall.sh: could not write $SEEN (PR head ages not saved)"
else
  rm -f -- "$SEEN.tmp.$$"; cm_warn "stall.sh: could not write $SEEN (PR head ages not saved)"
fi

RC=0
if jq -e '.noAction' "$TMP/out.json" >/dev/null 2>&1; then RC=4; fi
if [ "$JSON" -eq 1 ]; then
  jq 'del(.seen)' "$TMP/out.json"
  exit "$RC"
fi
{
  printf 'KIND\tNAME\tHOST\tAGE\tRUNG\tDUE\tACTED\n'
  jq -r '.rows[] | [.kind, .name, (.host // "-"), "\(.ageMinutes)m", (.rung | tostring), .action,
    (if .acted == null then "-" else "\(.acted.verb)@\(.acted.at | .[11:16])Z" end + (if .actedThisTick then "*" else "" end))] | @tsv' "$TMP/out.json"
} | { if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi; }
jq -r '"stall: \(.rows | length) stalled (\([.rows[] | select(.due)] | length) due, \([.rows[] | select(.actedThisTick)] | length) acted this tick), \(.exempt | length) exempt, \(.unverified) unverified, \(.checked) checked"
  + (if .resumeLockHeld then ", resume.lock held (rung 2 waits)" else "" end)
  + (if (.gaps | length) > 0 then " (gaps: \(.gaps | join("; ")))" else "" end)' "$TMP/out.json"
if [ "$RC" -eq 4 ]; then
  jq -r '"NO-ACTION \([.rows[] | select(.noAction)] | length) due row(s) with no action since \(.since): " + ([.rows[] | select(.noAction) | "\(.kind) \(.name) (rung \(.rung), \(.action))"] | join(", "))' "$TMP/out.json"
fi
exit "$RC"
