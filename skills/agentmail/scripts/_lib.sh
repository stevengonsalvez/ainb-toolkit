#!/usr/bin/env bash
# Shared helpers for agentmail scripts. Source, do not execute.
#
# Providers:
#   agents-inbox  primary. https://agents-inbox.com open tier: no signup, no key.
#                 Any <local>@agents-inbox.com receives mail; read via one GET.
#   inboxapi      backup. https://inboxapi.ai through its CLI (@inboxapi/cli).
#                 One persistent mailbox per machine, shared by every slug.
#
# Every provider is normalised to a JSON array, newest first, of
#   {id, from, from_name, subject, text, html, received_at, trust_level, marker}
# `from` is the bare sender address, so --from filters cannot be satisfied by a
# spoofed display name. trust_level is InboxAPI's sender verdict (null on agents-inbox).
# marker: InboxAPI "datamarks" untrusted subject/text by replacing spaces with
# this string, a prompt-injection defence. It stays marked in output; matching
# and extraction read through the jq `plain` def below.
JQ_PLAIN='def plain(f): (.marker // "") as $m | (f // "") | if $m == "" then . else split($m) | join(" ") end;'


set -euo pipefail

AGENTMAIL_AGENTS_INBOX_API="${AGENTMAIL_AGENTS_INBOX_API:-https://agents-inbox.com/api/v1}"

die() { echo "ERROR: $*" >&2; exit 1; }
usage_err() { echo "ERROR: $*" >&2; exit 2; }
require_int() { case "$1" in ''|*[!0-9]*) usage_err "$2 takes an integer" ;; esac; }

for bin in curl jq openssl; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not installed"
done

# State dir: $AGENTMAIL_STATE_DIR > <git root>/.agents/agentmail > ~/.cache/agentmail
state_dir() {
  local root
  if [ -n "${AGENTMAIL_STATE_DIR:-}" ]; then
    echo "$AGENTMAIL_STATE_DIR"
  elif root=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "$root/.agents/agentmail"
  else
    echo "$HOME/.cache/agentmail"
  fi
}

inbox_dir() { echo "$(state_dir)/inboxes"; }

# Path of the state file for slug $1. Validating here keeps slugs out of ../ paths.
state_file() {
  case "$1" in ''|*[!a-zA-Z0-9_-]*) usage_err "slug must match [a-zA-Z0-9_-]+" ;; esac
  echo "$(inbox_dir)/$1.json"
}

# True when state file $1 names a current provider (pre-2026-10 files do not).
known_provider() { jq -e '.provider == "agents-inbox" or .provider == "inboxapi"' "$1" >/dev/null 2>&1; }

# Print the state file for slug $1, or die if it is missing or from an old provider.
require_state() {
  local f; f=$(state_file "$1") || exit 2
  [ -f "$f" ] || die "no inbox '$1' (run create.sh $1 first)"
  known_provider "$f" || die "inbox '$1' uses a retired provider (run create.sh $1 --force)"
  echo "$f"
}

inboxapi_bin() {
  local bin="${AGENTMAIL_INBOXAPI_BIN:-$(command -v inboxapi 2>/dev/null || true)}"
  [ -n "$bin" ] || die "inboxapi CLI missing. Install: npm install -g @inboxapi/cli@latest"
  echo "$bin"
}

# GET the open-tier message list for local part $1 (raw provider JSON).
agents_inbox_get() {
  curl -fsS --max-time 20 "$AGENTMAIL_AGENTS_INBOX_API/public/inboxes/$1/messages"
}

inboxapi_whoami() { "$(inboxapi_bin)" whoami 2>/dev/null | awk -F': ' '/^Email: / {print $2; exit}' || true; }

# Mint an address for slug $2 on provider $1. Prints "address<TAB>local".
new_address() {
  local local_part address
  case "$1" in
    agents-inbox)
      # 64 random bits: open-tier inboxes are readable by anyone who knows the name.
      # 15 + 1 + 16 chars keeps the local part inside the 32-char limit.
      local_part="$(printf '%s' "$2" | tr 'A-Z_' 'a-z-' | cut -c1-15)-$(openssl rand -hex 8)"
      agents_inbox_get "$local_part" >/dev/null || return 1
      printf '%s@agents-inbox.com\t%s\n' "$local_part" "$local_part" ;;
    inboxapi)
      address=$(inboxapi_whoami)
      if [ -z "$address" ]; then
        "$(inboxapi_bin)" login --name "agentmail-$2" >/dev/null
        address=$(inboxapi_whoami)
      fi
      [ -n "$address" ] || die "inboxapi whoami returned no address"
      printf '%s\t\n' "$address" ;;
    *) usage_err "--provider must be auto, agents-inbox or inboxapi" ;;
  esac
}

# Print normalised messages for the inbox in state file $1. Empty text falls
# back to tag-stripped HTML; &amp; is decoded so links parse.
fetch_messages() {
  provider_messages "$1" | jq -c 'map(
    .html |= gsub("&amp;"; "&")
    | .text = (if .text != "" then .text
               else .html | gsub("<(style|script)[^>]*>.*?</(style|script)>"; " "; "gip") | gsub("<[^>]*>"; " ")
               end | gsub("&amp;"; "&")))'
}

provider_messages() {
  local state="$1" provider
  provider=$(jq -r '.provider' "$state")
  case "$provider" in
    agents-inbox)
      agents_inbox_get "$(jq -r '.local' "$state")" | jq -c '
        map({
          id: ._id,
          from: (.fromAddress // ""),
          from_name: (.fromName // ""),
          subject: (.subject // ""),
          text: (.textBody // ""),
          html: (.htmlBody // ""),
          received_at: (.receivedAt / 1000 | floor | todate),
          trust_level: null,
          marker: ""
        }) | sort_by(.received_at) | reverse'
      ;;
    inboxapi)
      # The mailbox is shared, so only mail received after create.sh belongs to
      # this slug.
      "$(inboxapi_bin)" get-emails --limit 100 | jq -c --arg since "$(jq -r '.created_at' "$state")" '
        (.spotlight.marker // "") as $m
        | def unmark: if $m == "" then (. // "") else ((. // "") | split($m) | join(" ")) end;
        (if type == "array" then . else (.emails // []) end)
        | map(select((.direction // "inbound") == "inbound"))
        | map({
            id: .message_id,
            # Last <addr> wins: a fake "<addr>" in the display name comes first.
            from: ((.from | unmark) as $f | ([$f | scan("<([^<>]+)>")] | last | .[0]?) // $f | ascii_downcase),
            from_name: "",
            subject: (.subject // ""),
            text: (.body // ""),
            html: "",
            received_at: ((.date // "")[0:19] + "Z"),
            trust_level: (.trust_level // null),
            marker: $m
          })
        | map(select(.received_at >= $since)) | sort_by(.received_at) | reverse'
      ;;
    *) die "unknown provider '$provider' in $state" ;;
  esac
}
