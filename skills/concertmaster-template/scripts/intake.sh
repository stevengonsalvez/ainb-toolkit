#!/usr/bin/env bash
# intake.sh: deterministic half of `/concertmaster intake <chat> [--since <time>]`.
# The procedure and the judgment calls are in references/intake.md; this script
# does the parts that must not vary run to run. The chat adapter here is wacli
# (WhatsApp); another chat source plugs in by writing a wacli-shaped export and
# passing it with `fetch --from-file`. It only READS: wacli reads, gh
# reads, bd reads, ledger reads. It creates beads (`beads --apply`) and writes
# tracker and state files under $CM_HOME. It never posts, sends or files.
#
#   intake.sh chat <chat>                       resolve a name or jid -> JSON
#   intake.sh since <chat> [--since T]          the since-time this run would use
#   intake.sh fetch <chat> [--since T] [--no-sync] [--from-file F] [--limit N]
#                          [--from JID] [--include-mine]      -> envelope JSON
#   intake.sh plan [--issues gh|F] [--beads bd|F] [--ledger F] [--media-map F]
#                  [--overrides F] [--now ISO] [--dup N] [--rel N] [--gap S] [--media-gap S]  < envelope
#   intake.sh beads [--apply] [--ops-epic ID] [--dev-epic ID] [--map-out F]   < plan
#   intake.sh tracker [--out FILE|-] [--beads-map F] [--commit [--accept-gap]
#                     [--accept-unbeaded] [--accept-replay]]                   < plan
#   intake.sh ask                                                             < plan
#   intake.sh media <chat> <full-msg-id> [--out DIR]    one named message only
#   intake.sh upload <image> --reviewed [--id FULL-MSG-ID --map F]   imgbb, key never on argv
#
# Env: CM_HOME (~/.concertmaster), CM_WACLI (wacli), CM_INTAKE_REPO (config
# intake.issue_repo, else github.org/github.main_repo), CM_INTAKE_ISSUE_LIMIT
# (1000), CM_INTAKE_NOW (ISO, tests), CM_OPS_EPIC, CM_DEV_EPIC (config
# beads.ops_epic, beads.dev_epic), IMGBB_API_KEY (else the file named by
# config intake.media.key_env_file).
set -euo pipefail
# chat text and media are private: new files and dirs under $CM_HOME are owner-only
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

JQ_RULES="$HERE/intake.jq"
WACLI="${CM_WACLI:-wacli}"
REPO="${CM_INTAKE_REPO:-$(cm_cfg .intake.issue_repo "$CM_ORG/$CM_REPO")}"
STATE="$CM_HOME/intake-state.json"
REGISTRY="$CM_HOME/intake-beads.json"
OVERLAP_S="${CM_INTAKE_OVERLAP_S:-86400}"
OPS_EPIC_DEFAULT="$(cm_cfg .beads.ops_epic)"
DEV_EPIC_DEFAULT="$(cm_cfg .beads.dev_epic)"
CHAT_SOURCE="$(cm_cfg .intake.source_label chat)"

die() { printf 'intake: %s\n' "$*" >&2; exit "${2:-1}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"; }
need jq

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-intake.XXXXXX")"
LOCK_DIR="$CM_HOME/.intake.lock"; LOCK_HELD=0
lock_release() { if [ "$LOCK_HELD" = 1 ]; then rmdir "$LOCK_DIR" 2>/dev/null || true; LOCK_HELD=0; fi; }
trap 'lock_release; rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# lock_run <cmd...>: run a read-modify-write under a mkdir lock so two intake
# runs cannot overwrite each other's state or registry. A lock older than 5
# minutes is treated as left by a crash.
lock_acquire() {
  [ "$LOCK_HELD" = 0 ] || return 0
  local n=0
  mkdir -p "$CM_HOME"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$LOCK_DIR" 2>/dev/null || true; continue; fi
    n=$((n + 1)); [ "$n" -le 100 ] || die "another intake run holds $LOCK_DIR; try again in a moment"
    sleep 0.1
  done
  LOCK_HELD=1
}

# lock_run <cmd...>: run under the lock (re-entrant: already held means just run)
lock_run() {
  local was="$LOCK_HELD" rc=0
  lock_acquire
  "$@" || rc=$?
  [ "$was" = 1 ] || lock_release
  return "$rc"
}

now_iso() { printf '%s\n' "${CM_INTAKE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

# ------------------------------------------------------------------ wacli guard

# The only door to wacli. Allow-list of subcommands, of the flags each may
# carry, and of what each flag's value may look like: sync --once, messages
# list, chats list, media download (one named message). No send, no --follow,
# no --download-media, no --webhook, ever. Times are read in UTC.
cm_wacli() {
  local a v skip=0 rest=() cmd args=() bools vals need seen=" " i=0 sub=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; rest+=("$a"); continue; fi
    # global flags are recognised only BEFORE the subcommand tokens
    if [ "$sub" -lt 2 ] && [ "${rest[0]:-}" != sync ]; then
      case "$a" in
        --read-only|--json|--full|--events) continue ;;
        --store|--account|--lock-wait|--timeout) skip=1; rest+=("$a"); continue ;;
      esac
    fi
    rest+=("$a")
    case "$a" in -*) ;; *) sub=$((sub + 1)) ;; esac
  done
  # drop the global flags (and their values) collected above, keep the rest
  local clean=() j=0
  while [ "$j" -lt "${#rest[@]}" ]; do
    case "${rest[$j]}" in
      --store|--account|--lock-wait|--timeout) j=$((j + 2)); continue ;;
    esac
    clean+=("${rest[$j]}"); j=$((j + 1))
  done
  case "${clean[0]:-}" in
    sync) cmd=sync; args=("${clean[@]:1}") ;;
    *) cmd="${clean[0]:-} ${clean[1]:-}"; args=("${clean[@]:2}") ;;
  esac
  case "$cmd" in
    sync)             bools=" --once ";                vals=" --idle-exit ";                                   need=" --once " ;;
    "messages list")  bools=" --asc --from-them ";     vals=" --chat --after --before --limit --sender ";       need=" --chat " ;;
    "chats list")     bools=" ";                       vals=" --limit --query ";                               need=" " ;;
    "media download") bools=" ";                       vals=" --chat --id --output ";                          need=" --chat --id " ;;
    *) die "refused: wacli $* (intake reads only: sync --once, messages list, chats list, media download)" ;;
  esac
  while [ "$i" -lt "${#args[@]}" ]; do
    a="${args[$i]}"
    case "$bools" in *" $a "*) seen="$seen$a " ;;
      *) case "$vals" in
           *" $a "*)
             i=$((i + 1)); v="${args[$i]:-}"
             case "$a" in
               --limit) [[ "$v" =~ ^[0-9]+$ ]] || die "refused: wacli $a is not a number" ;;
               --after|--before) [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+(Z|[+-][0-9:]+))?$ ]] || die "refused: wacli $a is not a date or RFC3339 time" ;;
               --chat|--sender) is_jid "$v" || die "refused: wacli $a is not a jid" ;;
               --id) [[ "$v" =~ ^[0-9A-Za-z]+$ ]] || die "refused: wacli --id is not a message id" ;;
               --output) [[ "$v" =~ ^/[^[:cntrl:]]*$ ]] || die "refused: wacli --output must be an absolute path without control characters"
                         case "$v" in *..*) die "refused: wacli --output may not contain .." ;; esac ;;
               --idle-exit) [[ "$v" =~ ^[0-9]+[sm]$ ]] || die "refused: wacli --idle-exit is not a duration" ;;
               --query) ;;
             esac
             seen="$seen$a " ;;
           *) die "refused: wacli $cmd flag or argument '$a' is not on the allow-list" ;;
         esac ;;
    esac
    i=$((i + 1))
  done
  for a in $need; do
    case "$seen" in *" $a "*) ;; *) die "refused: wacli $cmd needs $a" ;; esac
  done
  TZ=UTC cm_timeout "${WT:-120}" "$WACLI" "$@"
}

# ------------------------------------------------------------------ chat + since

# is_jid <s>: a whole-string match. [[ =~ ]] sees the entire value, so an
# embedded newline cannot smuggle a second line past the anchors.
is_jid() { [[ "$1" =~ ^[0-9A-Za-z._:-]+@(g\.us|s\.whatsapp\.net|lid)$ ]]; }

chat_table() { # config intake.chats, overridden per key by $CM_HOME/intake-chats.json
  local extra='{}'
  [ -s "$CM_HOME/intake-chats.json" ] && extra="$(cat "$CM_HOME/intake-chats.json")"
  jq -n --argjson base "$(cm_cfg_json .intake.chats '{}')" --argjson extra "$extra" '
    $base + $extra'
}

resolve_chat() { # <name|jid> -> {jid, slug, title}; slug is safe in a file name
  local q="$1" table
  table="$(chat_table)"
  case "$q" in
    *@g.us|*@s.whatsapp.net|*@lid)
      is_jid "$q" || die "'$(printf '%s' "$q" | head -n 1 | cut -c1-60)' is not a valid chat jid" 2
      jq -nc --arg jid "$q" --argjson t "$table" '
        ($t | to_entries | map(select(.value.jid == $jid))[0]) as $hit
        | ($jid | split("@")[0] | .[:8] | gsub("[^A-Za-z0-9]"; "")) as $short
        | {jid: $jid, slug: (($hit.key // ("chat-" + $short)) | gsub("[^A-Za-z0-9._-]"; "-")),
           title: ($hit.value.title // ("chat " + $short))}' ;;
    *)
      jq -nc --arg q "$q" --argjson t "$table" '
        ($q | ascii_downcase | gsub("[ _]+"; "-")) as $k
        | if $t[$k] then {jid: $t[$k].jid, slug: ($k | gsub("[^a-z0-9._-]"; "-")), title: ($t[$k].title // $k)}
          else empty end' | { grep . || true; } | head -n 1 > "$TMP/chat.json"
      if [ ! -s "$TMP/chat.json" ]; then
        # unknown name: exactly one match in wacli's chat list, else stop
        local hits
        hits="$(cm_wacli --read-only --json chats list --limit 500 2>/dev/null \
          | jq -c --arg q "$q" 'select(.success == true) | (.data // []) as $all
              | ([$all[] | select((.name // "" | ascii_downcase) == ($q | ascii_downcase))]) as $exact
              | if ($exact | length) > 0 then $exact
                else [$all[] | select((.name // "" | ascii_downcase) | contains($q | ascii_downcase))] end' 2>/dev/null)" || hits=""
        [ -n "$hits" ] || die "unknown chat '$q', and wacli chats list failed or is unavailable (not the same as zero matches). Known aliases: $(printf '%s' "$table" | jq -r 'keys | join(", ")'). Pass the group jid (...@g.us) instead." 2
        if [ "$(printf '%s' "$hits" | jq 'length')" = 1 ]; then
          printf '%s' "$hits" | jq -c '.[0] | {jid, slug: ((.name // "chat") | ascii_downcase | gsub("[^a-z0-9._-]+"; "-") | gsub("^-+|-+$"; "")), title: .name}' > "$TMP/chat.json"
        else
          die "unknown chat '$q' ($(printf '%s' "$hits" | jq 'length') wacli matches). Known aliases: $(printf '%s' "$table" | jq -r 'keys | join(", ")'). Pass the group jid (...@g.us) instead." 2
        fi
      fi
      cat "$TMP/chat.json" ;;
  esac
}

# parse_since <spec> <now-iso> -> ISO UTC. 90m, 24h, 3d, 1w, 2026-10-12, 2026-10-12T03:00Z, "2026-10-12 03:00".
parse_since() {
  jq -nr --arg s "$1" --arg now "$2" '
    ($now | sub("\\.[0-9]+"; "") | fromdateiso8601) as $n
    | ($s | gsub("^\\s+|\\s+$"; "")) as $s
    | if ($s | test("^[0-9]+[smhdw]$")) then
        ($s | capture("^(?<n>[0-9]+)(?<u>[smhdw])$")) as $c
        | ({s: 1, m: 60, h: 3600, d: 86400, w: 604800}[$c.u]) as $mul
        | ($n - (($c.n | tonumber) * $mul)) | todate
      elif ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then
        ($s + "T00:00:00Z") | fromdateiso8601 | todate
      elif ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?$")) then
        ($s | sub(" "; "T") | sub("Z$"; "") | if test("T[0-9]{2}:[0-9]{2}$") then . + ":00" else . end | . + "Z")
        | fromdateiso8601 | todate
      else error("cannot parse --since " + $s) end' 2>/dev/null \
    || die "cannot parse --since '$1' (use 90m, 24h, 3d, 1w, 2026-10-12 or 2026-10-12T03:00Z)" 2
}

# default_since <jid> <now-iso>: the last intake for the chat minus an overlap
# window (a message stamped earlier can reach the store after a sync), else 24h.
# Messages already read are dropped by id in fetch, so the overlap costs nothing.
default_since() {
  local last=""
  if [ -s "$STATE" ]; then
    last="$(jq -r --arg j "$1" '.chats[$j].lastMessageAt // empty' "$STATE" 2>/dev/null || true)"
  fi
  if [ -n "$last" ]; then
    jq -nr --arg t "$last" --argjson o "$OVERLAP_S" '($t | fromdateiso8601) - $o | todate'
  else
    parse_since 24h "$2"
  fi
}

# ------------------------------------------------------------------ fetch

cmd_chat() { [ $# -ge 1 ] || die "usage: chat <name|jid>" 2; resolve_chat "$1"; }

cmd_since() {
  [ $# -ge 1 ] || die "usage: since <chat> [--since T]" 2
  local chat="$1" spec="" now jid; shift
  while [ $# -gt 0 ]; do
    case "$1" in --since) [ $# -ge 2 ] || die "--since needs a value" 2; spec="$2"; shift 2 ;; *) die "since: unknown arg $1" 2 ;; esac
  done
  now="$(now_iso)"; jid="$(resolve_chat "$chat" | jq -r .jid)"
  if [ -n "$spec" ]; then parse_since "$spec" "$now"; else default_since "$jid" "$now"; fi
}

cmd_fetch() {
  [ $# -ge 1 ] || die "usage: fetch <chat> [--since T] [--no-sync] [--from-file F] [--limit N] [--from JID] [--include-mine]" 2
  local chat="$1" spec="" sync=1 file="" limit=500 limit_set=0 from="" mine=0; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die "$1 needs a value" 2; spec="$2"; shift 2 ;;
      --no-sync) sync=0; shift ;;
      --from-file) [ $# -ge 2 ] || die "$1 needs a value" 2; file="$2"; shift 2 ;;
      --limit) [ $# -ge 2 ] || die "$1 needs a value" 2; limit="$2"; limit_set=1; shift 2 ;;
      --from) [ $# -ge 2 ] || die "$1 needs a value" 2; from="$2"; shift 2 ;;
      --include-mine) mine=1; shift ;;
      *) die "fetch: unknown arg $1" 2 ;;
    esac
  done
  case "$limit" in ''|*[!0-9]*) die "fetch: --limit must be a number" 2 ;; esac
  local now cj jid since synced="" raw fromstate=0 truncated=false
  now="$(now_iso)"; cj="$(resolve_chat "$chat")"; jid="$(printf '%s' "$cj" | jq -r .jid)"
  if [ -n "$spec" ]; then since="$(parse_since "$spec" "$now")"; else since="$(default_since "$jid" "$now")"; fromstate=1; fi

  if [ -n "$file" ]; then
    [ -r "$file" ] || die "cannot read $file"
    raw="$(jq -c '(if type == "array" then . elif (.data | type) == "object" then .data.messages
       elif (.messages | type) == "array" then .messages else [] end)' "$file")" || die "cannot parse $file"
  else
    need "$WACLI"
    if [ "$sync" = 1 ]; then
      WT=240 cm_wacli --lock-wait 30s sync --once >&2 || die "wacli sync --once failed or timed out"
      synced="$now"
    fi
    local args=(--read-only --json messages list --chat "$jid" --after "$since" --asc --limit "$limit")
    [ "$mine" = 1 ] || args+=(--from-them)
    [ -z "$from" ] || args+=(--sender "$from")
    raw="$(WT=120 cm_wacli "${args[@]}" | jq -ce 'if .success == true then (.data.messages // []) else error("wacli reported failure: " + ((.error // "no message") | tostring)) end')" \
      || die "wacli messages list failed (a failed read is not an empty chat)"
  fi
  # Reaching the limit BEFORE any filtering means older messages were cut off.
  if { [ -z "$file" ] || [ "$limit_set" = 1 ]; } && [ "$(printf '%s' "$raw" | jq 'length')" -ge "$limit" ]; then
    truncated=true; cm_warn "read hit --limit $limit: the window is truncated; raise --limit before trusting or committing this run"
  fi
  # Every timestamp becomes UTC "...Z" once, here, so later comparisons are
  # plain string order. An unparseable time stops the run.
  printf '%s' "$raw" > "$TMP/raw.json"
  raw="$(IN_F="$TMP/raw.json" jq_rules utcfix -c)" || die "a message has a timestamp that is not RFC3339"
  raw="$(printf '%s' "$raw" | jq -c --arg since "$since" --arg jid "$jid" 'map(select((.ChatJID // $jid) == $jid and .Timestamp > $since))')"
  # A since-time taken from the state file overlaps the last run: drop what it
  # already read. An explicit --since reads everything it asks for.
  if [ "$fromstate" = 1 ] && [ -s "$STATE" ]; then
    raw="$(printf '%s' "$raw" | jq -c --arg j "$jid" --slurpfile st "$STATE" '
      ($st[0].chats[$j].seen // {}) as $seen | map(select($seen[.MsgID] | not))')"
  fi
  printf '%s' "$raw" > "$TMP/raw-final.json"
  jq -n --argjson chat "$cj" --arg since "$since" --arg now "$now" --arg synced "$synced" --arg from "$from" \
    --slurpfile rawf "$TMP/raw-final.json" --argjson trunc "$truncated" --arg source "$([ -n "$file" ] && echo file || echo wacli)" '
    $rawf[0] as $raw
    | {schema: "concertmaster.intake-envelope/v1", chat: $chat, since: $since, until: $now, now: $now,
     syncedAt: (if $synced == "" then null else $synced end),
     senderFilter: (if $from == "" then null else $from end),
     truncated: $trunc, source: $source,
     latestTs: ($raw | map(.Timestamp) | max // null),
     messages: $raw}'
}

# ------------------------------------------------------------------ plan

snapshot_issues() { # gh | file -> JSON array on stdout. OPEN and CLOSED are listed
  # separately so a big closed history never hides an older open issue.
  local caps=()
  if [ "$1" = gh ]; then
    need gh
    local open closed ol cl
    ol="${CM_INTAKE_OPEN_LIMIT:-5000}"; cl="${CM_INTAKE_ISSUE_LIMIT:-1000}"
    open="$(gh issue list --repo "$REPO" --state open --limit "$ol" --json number,title,body,state)" \
      || die "gh issue list (open) failed: dedupe needs the issue list. Pass --issues <file> to use a saved one."
    closed="$(gh issue list --repo "$REPO" --state closed --limit "$cl" --json number,title,body,state)" \
      || die "gh issue list (closed) failed: dedupe needs the issue list. Pass --issues <file> to use a saved one."
    [ "$(printf '%s' "$open" | jq 'length')" -lt "$ol" ] || { caps+=("open issues (limit $ol)"); cm_warn "open issue list hit its cap ($ol); older open issues were not checked"; }
    [ "$(printf '%s' "$closed" | jq 'length')" -lt "$cl" ] || { caps+=("closed issues (limit $cl)"); cm_warn "closed issue list hit its cap ($cl); older closed issues were not checked"; }
    printf '%s\n' "${caps[@]:-}" | jq -R -s -c 'split("\n") | map(select(. != ""))' > "$TMP/caps.json"
    # via files: one argv string is capped near 128KB, far below 1000 issue bodies
    printf '%s' "$open" > "$TMP/issues-open.json"; printf '%s' "$closed" > "$TMP/issues-closed.json"
    jq -c -s '.[0] + .[1]' "$TMP/issues-open.json" "$TMP/issues-closed.json"
  else
    [ -r "$1" ] || die "cannot read issues file $1"
    printf '[]' > "$TMP/caps.json"
    jq -c . "$1"
  fi
}

snapshot_beads() { # bd | file -> JSON array on stdout (array or JSONL accepted)
  local src="$1" out
  if [ "$src" = bd ]; then
    if command -v bd >/dev/null 2>&1 && out="$(bd list --all --json --limit 0 2>/dev/null)" && [ "$(printf '%s' "$out" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
      printf '%s\n' "$out"; return 0
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [ -r "$root/.beads/issues.jsonl" ]; then
      cm_warn "bd has no local database here (run: bd bootstrap); reading $root/.beads/issues.jsonl instead"
      src="$root/.beads/issues.jsonl"
    else
      die "no bead evidence: bd list is empty and no .beads/issues.jsonl. Run bd bootstrap, or pass --beads <file>."
    fi
  fi
  [ -r "$src" ] || die "cannot read beads file $src"
  jq -sc 'if (length == 1 and (.[0] | type) == "array") then .[0] else . end' "$src"
}

# Beads intake created in a worktree whose .beads has not reached main yet are
# invisible to bd list elsewhere; the registry remembers them by message id.
registry_json() { if [ -s "$REGISTRY" ] && jq -e 'type == "object"' "$REGISTRY" >/dev/null 2>&1; then cat "$REGISTRY"; else printf '{}'; fi; }

# save_map: write $TMP/beadmap.json to $mapout atomically (no-op without a map file)
save_map() {
  [ -n "$mapout" ] || return 0
  cp "$TMP/beadmap.json" "$mapout.tmp" && mv "$mapout.tmp" "$mapout"
}
save_map_if_missing() { [ -z "$mapout" ] || [ -s "$mapout" ] || save_map; }

# registry_add <bead> <title>: merge the item's full ids (in $TMP/ids.json) into the registry
registry_add() {
  registry_json > "$TMP/registry.json"
  jq --slurpfile ids "$TMP/ids.json" --arg b "$1" --arg t "$2" --arg at "$(now_iso)" \
     'reduce $ids[0][] as $x (.; .[$x] = {bead: $b, title: $t, at: $at})' "$TMP/registry.json" > "$TMP/registry.new" \
    && cp "$TMP/registry.new" "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
}

cmd_plan() {
  local issues=gh beads=bd ledger="$CM_HOME/ledger.json" mmap="" over="" now="" dup=0.6 rel=0.4 back=0.3 gap=120 mgap=600
  while [ $# -gt 0 ]; do
    case "$1" in
      --issues) [ $# -ge 2 ] || die "$1 needs a value" 2; issues="$2"; shift 2 ;;
      --beads) [ $# -ge 2 ] || die "$1 needs a value" 2; beads="$2"; shift 2 ;;
      --ledger) [ $# -ge 2 ] || die "$1 needs a value" 2; ledger="$2"; shift 2 ;;
      --media-map) [ $# -ge 2 ] || die "$1 needs a value" 2; mmap="$2"; shift 2 ;;
      --overrides) [ $# -ge 2 ] || die "$1 needs a value" 2; over="$2"; shift 2 ;;
      --now) [ $# -ge 2 ] || die "$1 needs a value" 2; now="$2"; shift 2 ;;
      --dup) [ $# -ge 2 ] || die "$1 needs a value" 2; dup="$2"; shift 2 ;;
      --rel) [ $# -ge 2 ] || die "$1 needs a value" 2; rel="$2"; shift 2 ;;
      --back) [ $# -ge 2 ] || die "$1 needs a value" 2; back="$2"; shift 2 ;;
      --gap) [ $# -ge 2 ] || die "$1 needs a value" 2; gap="$2"; shift 2 ;;
      --media-gap) [ $# -ge 2 ] || die "$1 needs a value" 2; mgap="$2"; shift 2 ;;
      *) die "plan: unknown arg $1" 2 ;;
    esac
  done
  [ -r "$ledger" ] || die "cannot read ledger $ledger: routing reads live lanes from it"
  jq -e 'type == "object"' "$ledger" >/dev/null || die "ledger $ledger is not a JSON object"
  cat > "$TMP/env.json"
  jq -e '.messages | type == "array"' "$TMP/env.json" >/dev/null || die "stdin is not an intake envelope (run: intake.sh fetch ...)"
  snapshot_issues "$issues" > "$TMP/issues.json"
  snapshot_beads "$beads" > "$TMP/beads.json"
  registry_json > "$TMP/reg.json"
  if [ -n "$mmap" ] && [ -s "$mmap" ]; then cp "$mmap" "$TMP/mmap.json"; else printf '{}' > "$TMP/mmap.json"; fi
  if [ -n "$over" ]; then
    [ -r "$over" ] || die "cannot read overrides $over"
    jq -e 'type == "object"' "$over" >/dev/null || die "overrides must be a JSON object keyed by first message id"
    cp "$over" "$TMP/ov.json"
  else printf '{}' > "$TMP/ov.json"; fi
  jq --arg n "$now" --slurpfile caps "$TMP/caps.json" '(if $n != "" then .now = $n else . end) | .evidenceCaps = $caps[0]' "$TMP/env.json" > "$TMP/env2.json" \
    && mv "$TMP/env2.json" "$TMP/env.json"
  DUP="$dup" REL="$rel" BACK="$back" GAP="$gap" MGAP="$mgap" IN_F="$TMP/env.json" ISSUES_F="$TMP/issues.json" \
    BEADS_F="$TMP/beads.json" REG_F="$TMP/reg.json" LEDGER_F="$ledger" MURLS_F="$TMP/mmap.json" OV_F="$TMP/ov.json" \
    jq_rules plan
}

# jq_rules <mode> [jq args]: run intake.jq. Inputs come from the *_F variables;
# anything unset defaults to an empty array or object.
jq_rules() {
  local mode="$1"; shift
  [ -s "$TMP/empty.json" ] || printf '[]' > "$TMP/empty.json"
  [ -s "$TMP/obj.json" ] || printf '{}' > "$TMP/obj.json"
  jq -n -f "$JQ_RULES" --arg mode "$mode" --arg dup "${DUP:-0.6}" --arg rel "${REL:-0.4}" --arg back "${BACK:-0.3}" \
    --arg gap "${GAP:-120}" --arg mgap "${MGAP:-600}" \
    --arg ownerId "$CM_OWNER_ID" --arg ownerName "$CM_OWNER_NAME" --arg chatSource "$CHAT_SOURCE" \
    --slurpfile in "${IN_F:?}" --slurpfile issues "${ISSUES_F:-$TMP/empty.json}" --slurpfile beads "${BEADS_F:-$TMP/empty.json}" \
    --slurpfile reg "${REG_F:-$TMP/obj.json}" --slurpfile ledger "${LEDGER_F:-$TMP/obj.json}" \
    --slurpfile murls "${MURLS_F:-$TMP/obj.json}" --slurpfile bmap "${BMAP_FILE:-$TMP/obj.json}" \
    --slurpfile ov "${OV_F:-$TMP/obj.json}" "$@"
}

# run_mode <mode> [extra jq args]: stdin plan -> jq rules output
run_mode() {
  local mode="$1"; shift
  cat > "$TMP/plan.json"
  IN_F="$TMP/plan.json" jq_rules "$mode" "$@"
}

# ------------------------------------------------------------------ beads

cmd_beads() {
  local apply=0 ops="${CM_OPS_EPIC:-$OPS_EPIC_DEFAULT}" dev="${CM_DEV_EPIC:-$DEV_EPIC_DEFAULT}" mapout=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --ops-epic) [ $# -ge 2 ] || die "$1 needs a value" 2; ops="$2"; shift 2 ;;
      --dev-epic) [ $# -ge 2 ] || die "$1 needs a value" 2; dev="$2"; shift 2 ;;
      --map-out) [ $# -ge 2 ] || die "$1 needs a value" 2; mapout="$2"; shift 2 ;;
      *) die "beads: unknown arg $1" 2 ;;
    esac
  done
  [ -n "$ops" ] && [ -n "$dev" ] || die "beads: set beads.ops_epic and beads.dev_epic in config (or --ops-epic, --dev-epic)" 2
  cat > "$TMP/planb.json"
  local specs n i
  specs="$(IN_F="$TMP/planb.json" jq_rules beads)"
  n="$(printf '%s' "$specs" | jq 'length')"
  # --apply always keeps a map, default beside the tracker, so any run that
  # stops half way can be repeated without creating a bead twice.
  if [ "$apply" = 1 ] && [ -z "$mapout" ]; then
    mkdir -p "$CM_HOME/inbox"
    mapout="$CM_HOME/inbox/$(jq -r '.chat.slug' "$TMP/planb.json")-beadmap-$(jq -r '.now[:10]' "$TMP/planb.json").json"
    cm_warn "bead map: $mapout (pass --map-out to choose)"
  fi
  if [ -n "$mapout" ] && [ -s "$mapout" ]; then cp "$mapout" "$TMP/beadmap.json"; else printf '{}' > "$TMP/beadmap.json"; fi
  save_map_if_missing
  if [ "$n" = 0 ]; then cat "$TMP/beadmap.json"; return 0; fi
  if [ "$apply" = 1 ]; then
    need bd
    lock_acquire   # one apply at a time: read-check-create must not interleave
    # re-read the map under the lock, another run may have added to it
    if [ -n "$mapout" ] && [ -s "$mapout" ]; then cp "$mapout" "$TMP/beadmap.json"; fi
    bd list --limit 1 --json >/dev/null 2>&1 \
      || die "bd has no usable local database in this worktree. Run: bd bootstrap (then retry)."
    # only the epics this run will use
    local e
    for e in $(printf '%s' "$specs" | jq -r --arg o "$ops" --arg d "$dev" 'map(if .parent == "ops" then $o else $d end) | unique | .[]'); do
      bd show "$e" >/dev/null 2>&1 || die "epic $e not found in this bd database (bd bootstrap, or pass --ops-epic/--dev-epic)"
    done
  fi
  registry_json > "$TMP/registry.json"
  i=0
  while [ "$i" -lt "$n" ]; do
    local key mkey title type assignee parent desc known
    key="$(printf '%s' "$specs" | jq -r ".[$i].key")"
    mkey="$(printf '%s' "$specs" | jq -r ".[$i].mapKey")"
    title="$(printf '%s' "$specs" | jq -r ".[$i].title")"
    type="$(printf '%s' "$specs" | jq -r ".[$i].type")"
    assignee="$(printf '%s' "$specs" | jq -r ".[$i].assignee")"
    parent="$(printf '%s' "$specs" | jq -r ".[$i].parent")"
    desc="$(printf '%s' "$specs" | jq -r ".[$i].description")"
    if [ "$parent" = ops ]; then parent="$ops"; else parent="$dev"; fi
    # a bead already made for any of this item's message ids, here or in another worktree
    known="$(jq -r --argjson ids "$(printf '%s' "$specs" | jq -c ".[$i].fullIds")" --slurpfile r "$TMP/registry.json" --slurpfile m "$TMP/beadmap.json" \
      '($ids | map(. as $id | ([$m[0][$id], $r[0][$id].bead] | map(select(. != null and . != "PENDING")) | first // empty)) | first) // empty' -n)"
    # A PENDING entry means an earlier create may have written the bead and then
    # failed. Ask bd for a bead that already carries this full message id before
    # creating another.
    if [ -z "$known" ] && [ "$apply" = 1 ] && [ "$(jq -r --arg k "$mkey" '.[$k] // empty' "$TMP/beadmap.json")" = PENDING ]; then
      known="$(bd list --all --desc-contains "$mkey" --json --limit 0 2>/dev/null | jq -r 'first(.[]? | .id) // empty' 2>/dev/null || true)"
      [ -z "$known" ] || cm_warn "$key ($mkey): an earlier create had already written $known"
    fi
    if [ -n "$known" ]; then
      cm_warn "skip $key ($mkey): already has bead $known"
      jq --arg k "$mkey" --arg v "$known" '. + {($k): $v}' "$TMP/beadmap.json" > "$TMP/beadmap.tmp" && mv "$TMP/beadmap.tmp" "$TMP/beadmap.json"
      if [ "$apply" = 1 ]; then
        save_map
        printf '%s' "$specs" | jq -c ".[$i].fullIds" > "$TMP/ids.json"
        lock_run registry_add "$known" "$title" || die "could not record $known in the registry"
      fi
    elif [ "$apply" = 1 ]; then
      local id
      # mark PENDING first: a crash or a failed create leaves a trace to check on re-run
      jq --arg k "$mkey" '. + {($k): "PENDING"}' "$TMP/beadmap.json" > "$TMP/beadmap.tmp" && mv "$TMP/beadmap.tmp" "$TMP/beadmap.json"
      save_map
      id="$(printf '%s' "$desc" | bd create --json --title "$title" --type "$type" --priority 2 \
              --parent "$parent" --assignee "$assignee" --body-file - 2>"$TMP/bd.err" | jq -r '.id // empty')" \
        || die "bd create failed for $key ($mkey): $(head -n 1 "$TMP/bd.err" | cut -c1-160). Beads created so far are in $mapout; re-run with the same --map-out to continue."
      printf '%s' "$id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "bd create returned '$(printf '%s' "$id" | cut -c1-60)', not a bead id, for $key ($mkey)"
      jq --arg k "$mkey" --arg v "$id" '. + {($k): $v}' "$TMP/beadmap.json" > "$TMP/beadmap.tmp" && mv "$TMP/beadmap.tmp" "$TMP/beadmap.json"
      save_map
      # remember every id of the item, so a later run in any worktree sees it as filed
      printf '%s' "$specs" | jq -c ".[$i].fullIds" > "$TMP/ids.json"
      lock_run registry_add "$id" "$title" || die "could not record $id in the registry"
      printf 'created %s (%s) -> %s, parent %s, assignee %s\n' "$id" "$key" "$title" "$parent" "$assignee" >&2
    else
      printf 'DRY RUN %s: bd create --json --title %q --type %s --priority 2 --parent %s --assignee %q --body-file -\n' \
        "$key" "$title" "$type" "$parent" "$assignee" >&2
      printf '%s\n\n' "$desc" | sed 's/^/    | /' >&2
    fi
    i=$((i + 1))
  done
  lock_release
  cat "$TMP/beadmap.json"
}

# ------------------------------------------------------------------ tracker

cmd_tracker() {
  local out="" bmap="" commit=0 gapok=0 unbeaded=0 replay=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || die "$1 needs a value" 2; out="$2"; shift 2 ;;
      --beads-map) [ $# -ge 2 ] || die "$1 needs a value" 2; bmap="$2"; shift 2 ;;
      --commit) commit=1; shift ;;
      --accept-gap) gapok=1; shift ;;
      --accept-unbeaded) unbeaded=1; shift ;;
      --accept-replay) replay=1; shift ;;
      *) die "tracker: unknown arg $1" 2 ;;
    esac
  done
  [ -z "$bmap" ] || { [ -r "$bmap" ] || die "cannot read beads map $bmap"
                      jq -e 'type == "object"' "$bmap" >/dev/null 2>&1 || die "beads map $bmap is not a JSON object (corrupt or truncated?)"
                      BMAP_FILE="$bmap"; }
  local text slug date jid latest
  cat > "$TMP/planin.json"
  jid="$(jq -r '.chat.jid' "$TMP/planin.json")"
  if [ "$commit" = 1 ]; then
    # --commit moves the chat's cursor, so refuse when that could skip messages
    [ "$(jq -r '.senderFilter // empty' "$TMP/planin.json")" = "" ] \
      || die "refusing --commit: this plan read one sender only (--from), so moving the chat's cursor would skip everyone else. Drop --commit, or re-run fetch without --from."
    [ "$(jq -r '.truncated // false' "$TMP/planin.json")" = false ] \
      || die "refusing --commit: the read hit its message limit, so older messages in the window were never read. Re-run fetch with a higher --limit."
    [ "$replay" = 1 ] || [ "$(jq -r '.source // "wacli"' "$TMP/planin.json")" != file ] \
      || die "refusing --commit: this plan came from --from-file, a replay, not a live read. Pass --accept-replay if you mean it."
    if [ "$unbeaded" = 0 ]; then
      [ -s "$TMP/obj.json" ] || printf '{}' > "$TMP/obj.json"
      local missing pending
      missing="$(jq -r --slurpfile b "${BMAP_FILE:-$TMP/obj.json}" '
        [.items[] | select(.type != "question") | select((($b[0][.fullIds[0]] // null) == null) or ($b[0][.fullIds[0]] == "PENDING"))] | length' "$TMP/planin.json")" \
        || die "cannot evaluate the beads map against the plan, so --commit would be unsafe"
      [[ "$missing" =~ ^[0-9]+$ ]] || die "cannot evaluate the beads map against the plan, so --commit would be unsafe"
      if [ "$missing" != 0 ]; then
        pending="$(jq -r '[.[] | select(. == "PENDING")] | length' "${BMAP_FILE:-$TMP/obj.json}")"
        die "refusing --commit: $missing item(s) have no bead ($pending create(s) are PENDING after a failure), so the cursor would pass them for good. Re-run: beads --apply --map-out F, then tracker --beads-map F. Or pass --accept-unbeaded."
      fi
    fi
    if [ "$gapok" = 0 ] && [ -s "$STATE" ]; then
      local prev
      prev="$(jq -r --arg j "$jid" '.chats[$j].lastMessageAt // empty' "$STATE")"
      if [ -n "$prev" ] && [ "$(jq -nr --arg since "$(jq -r .since "$TMP/planin.json")" --arg prev "$prev" --argjson o "$OVERLAP_S" \
            '(($since | fromdateiso8601) > (($prev | fromdateiso8601) - $o)) | tostring')" = true ]; then
        die "refusing --commit: this read started at $(jq -r .since "$TMP/planin.json"), after the last intake's cursor ($prev) less the ${OVERLAP_S}s overlap, so messages in between were never read. Re-run fetch without --since, or pass --accept-gap."
      fi
    fi
  fi
  text="$(run_mode tracker -r < "$TMP/planin.json")"
  slug="$(jq -r '.chat.slug' "$TMP/planin.json")"; date="$(jq -r '.now[:10]' "$TMP/planin.json")"
  latest="$(jq -r '.latestTs // empty' "$TMP/planin.json")"
  if [ "$out" = "-" ]; then
    printf '%s' "$text"
    [ "$commit" = 0 ] || cm_warn "--commit ignored with --out -: no tracker file was written"
    return 0
  fi
  if [ -z "$out" ]; then
    mkdir -p "$CM_HOME/inbox"
    out="$CM_HOME/inbox/$slug-tracker-$date.md"
    local n=2
    while [ -e "$out" ]; do out="$CM_HOME/inbox/$slug-tracker-$date-$n.md"; n=$((n + 1)); done
  else
    [ ! -e "$out" ] || die "refusing to overwrite $out"
    mkdir -p "$(dirname "$out")"
  fi
  printf '%s' "$text" > "$out.tmp" && mv "$out.tmp" "$out"
  if [ "$commit" = 1 ]; then
    lock_run commit_state || die "tracker written to $out but the cursor was NOT moved (state update failed). Fix and run again with --accept-gap if needed."
  fi
  printf '%s\n' "$out"
}

# commit_state: move the chat's cursor and seen ids (uses $jid $latest $out $TMP/planin.json from cmd_tracker)
commit_state() {
    mkdir -p "$CM_HOME"
    [ -s "$STATE" ] || printf '{"schema":"concertmaster.intake/v1","chats":{}}' > "$STATE"
    # Cursor = newest message ever read (never moves back). seen = ids read in
    # the last 2x overlap, so the overlap window in default_since reads none twice.
    jq --arg j "$jid" --arg t "$latest" --arg f "$out" --arg at "$(now_iso)" --arg since "$(jq -r .since "$TMP/planin.json")" \
       --argjson keep "$((OVERLAP_S * 2))" --slurpfile plan "$TMP/planin.json" '
       (.chats[$j] // {}) as $prev
       | ([$prev.lastMessageAt, (if $t == "" then null else $t end)] | map(select(. != null)) | max // $since) as $cursor
       | ($plan[0].read | map({(.id): .ts}) | add // {}) as $new
       | (($prev.seen // {}) + $new | with_entries(select(.value > (($cursor | fromdateiso8601) - $keep | todate)))) as $seen
       | .chats[$j] = {lastMessageAt: $cursor, lastRunAt: $at, tracker: $f, seen: $seen}' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

cmd_ask() { run_mode ask; }

# ------------------------------------------------------------------ media + upload

cmd_media() {
  [ $# -ge 2 ] || die "usage: media <chat> <full-msg-id> [--out DIR]  (one named message that carries media a bead needs)" 2
  local chat="$1" id="$2" out="" cj jid slug; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --out) [ $# -ge 2 ] || die "--out needs a value" 2; out="$2"; shift 2 ;; *) die "media: unknown arg $1" 2 ;; esac
  done
  cj="$(resolve_chat "$chat")"; jid="$(printf '%s' "$cj" | jq -r .jid)"; slug="$(printf '%s' "$cj" | jq -r .slug)"
  [ -n "$out" ] || out="$CM_HOME/inbox/$slug-media"
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  mkdir -p "$out"
  WT=180 cm_wacli media download --chat "$jid" --id "$id" --output "$out" >&2 || die "wacli media download failed for $id"
  printf '%s\n' "$out"
}

imgbb_key() { # prints the key; never echoes it anywhere else
  { set +x; } 2>/dev/null
  if [ -n "${IMGBB_API_KEY:-}" ]; then printf '%s' "$IMGBB_API_KEY"; return 0; fi
  local root f k rel
  # config intake.media.key_env_file: a NON-production env file, relative to
  # the repo root; chat media never uses a production credential.
  rel="$(cm_cfg .intake.media.key_env_file)"
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  f=""
  [ -n "$rel" ] && f="$root/$rel"
  if [ -n "$f" ] && [ -r "$f" ]; then
    k="$(grep -E '^IMGBB_API_KEY=' "$f" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d "\"'" || true)"
    case "$k" in ''|U2FsdGVk*) ;; *) printf '%s' "$k"; return 0 ;; esac
  fi
  die "no IMGBB_API_KEY (set it in the environment, or make config intake.media.key_env_file readable)"
}

# Escape a value for a curl config file string.
curl_cfg_escape() { # backslash, quote, and the control characters that would end a config line
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '[:cntrl:]'
}

cmd_upload() {
  { set +x; } 2>/dev/null   # a bash -x run must not trace the key into stderr
  [ $# -ge 1 ] || die "usage: upload <image> --reviewed [--id FULL-MSG-ID --map FILE]" 2
  local file="$1" id8="" map="" reviewed=0; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --id|--id8) [ $# -ge 2 ] || die "$1 needs a value" 2; id8="$2"; shift 2 ;;
      --map) [ $# -ge 2 ] || die "--map needs a value" 2; map="$2"; shift 2 ;;
      --reviewed) reviewed=1; shift ;;
      *) die "upload: unknown arg $1" 2 ;;
    esac
  done
  [ "$reviewed" = 1 ] || die "refusing to upload without --reviewed. imgbb URLs are public. Look at the image first ($(cm_cfg .intake.media.privacy_note 'the chat may carry personal data')): no faces, names, emails or phone numbers of people unless redacted, and nothing you would not put on a public page. Then pass --reviewed." 2
  case "$file" in *[[:cntrl:]]*) die "refusing a file path with control characters" ;; esac
  [ -r "$file" ] || die "cannot read $file"
  local ext
  case "$(cm_lower "$file")" in
    *.png) ext=png ;; *.jpg|*.jpeg) ext=jpg ;; *.gif) ext=gif ;; *.bmp) ext=bmp ;; *.webp) ext=webp ;; *.tif|*.tiff) ext=tif ;;
    *) die "imgbb takes images only. For video, extract frames first (ffmpeg -i in.mp4 -vf fps=1/3 frame-%02d.png) and upload each frame." ;;
  esac
  local bytes
  bytes="$(wc -c < "$file" | tr -d ' ')"
  [ "$bytes" -le 33554432 ] || die "$file is over imgbb's 32MB limit"
  # A chat-supplied file name never reaches the curl config: upload a copy under a fixed name.
  local safe="$TMP/upload.$ext"
  cp -- "$file" "$safe"
  # imgbb accepts 60s..180d; default 30 days: ops evidence is used within days
  local exp="${CM_IMGBB_EXPIRATION:-2592000}"
  [[ "$exp" =~ ^[0-9]+$ ]] && [ "$exp" -ge 60 ] && [ "$exp" -le 15552000 ] || die "CM_IMGBB_EXPIRATION must be 60 to 15552000 seconds"
  need curl
  local key resp url
  key="$(imgbb_key)"
  # Config on stdin: the key and path never appear in any process argv.
  resp="$(printf 'url = "https://api.imgbb.com/1/upload"\nform = "key=%s"\nform = "expiration=%s"\nform = "image=@%s"\n' \
            "$(curl_cfg_escape "$key")" "$exp" "$safe" | curl -sS --max-time 90 -K -)" \
    || die "imgbb upload failed (network)"
  url="$(printf '%s' "$resp" | jq -r 'select(.success == true) | .data.url // empty' 2>/dev/null || true)"
  [ -n "$url" ] || die "imgbb rejected the upload: $(printf '%s' "$resp" | jq -r '.error.message // "no message"' 2>/dev/null | cut -c1-120)"
  # keep the takedown link, owner-only, never in a bead
  local del
  del="$(printf '%s' "$resp" | jq -r '.data.delete_url // empty' 2>/dev/null || true)"
  if [ -n "$del" ]; then
    mkdir -p "$CM_HOME"
    [ -s "$CM_HOME/imgbb-deletes.json" ] || printf '{}' > "$CM_HOME/imgbb-deletes.json"
    jq --arg u "$url" --arg d "$del" '. + {($u): $d}' "$CM_HOME/imgbb-deletes.json" > "$CM_HOME/imgbb-deletes.json.tmp" \
      && mv "$CM_HOME/imgbb-deletes.json.tmp" "$CM_HOME/imgbb-deletes.json"
  fi
  if [ -n "$id8" ] && [ -n "$map" ]; then
    [ -s "$map" ] || printf '{}' > "$map"
    jq --arg k "$id8" --arg u "$url" '. + {($k): $u}' "$map" > "$map.tmp" && mv "$map.tmp" "$map"
  fi
  printf '%s\n' "$url"
}

# ------------------------------------------------------------------ main

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
  chat) cmd_chat "$@" ;;
  since) cmd_since "$@" ;;
  fetch) cmd_fetch "$@" ;;
  plan) cmd_plan "$@" ;;
  beads) cmd_beads "$@" ;;
  tracker) cmd_tracker "$@" ;;
  ask) cmd_ask "$@" ;;
  media) cmd_media "$@" ;;
  upload) cmd_upload "$@" ;;
  -h|--help|help|'') usage ;;
  *) die "unknown command '$cmd' (try --help)" 2 ;;
esac
