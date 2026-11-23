#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # sourced: the callers read every variable here
# ask-deny.sh: the one "does this ledger ask name an owner-only subject" scan. Sourced after lib.sh, never executed.
# Used by scripts/ask-timeout.sh (an own-scope ask that names one never times out) and scripts/stall.sh (an own-scope
# ask that names one is owner-only: Blocked, never laddered), so both read an ask the same way.
#
#   CM_ASK_DENY         word-boundary ERE over the normalised, lowercased text: migrations and schema, RLS and
#                       grants, auth, sessions and tokens, secrets and keys, payments, releases and deploys (OTA, stores,
#                       ship, publish, revert, rollback), merges and teardowns, deletes, prod, and personal data (PII,
#                       GDPR, consent, DOB). The owner's name and config away.deny_extra (a list of regex fragments)
#                       are added. False hits fail safe (owner-only).
#   CM_ASK_DENY_CRED    the credential and secret terms of CM_ASK_DENY (auth, oauth, login, jwt, secrets, passwords,
#                       API keys, service role, env vars, access/refresh/bearer tokens), one segment that CM_ASK_DENY
#                       is built from, so scripts/stall.sh can scan release and deploy asks with exactly these terms
#                       and the two can never drift
#   CM_ASK_DELEGATED_CLASSES  the release or deploy classes the concertmaster may decide itself on the drive ladder
#                       (scripts/stall.sh), from config drive.delegated_classes (a list of regex fragments, each
#                       matched as a whole phrase). Default: none, so every release or deploy ask goes to the owner.
#                       A fragment that is not a valid regex is dropped (fewer delegated classes: fail safe)
#   CM_ASK_DELEGATED_ASK      the whole-text allowlist built from the classes: a delegated release or deploy ask's
#                       question and topic must match it end to end, else the owner decides. With no class it matches
#                       nothing
#   CM_ASK_SQUASH       the same text with every non-alphanumeric removed, for split words ("se-cret")
#   CM_ASK_ALLOW        changed paths a verdict may cover: an allowlist, closed by default (config away.allow_paths)
#   CM_ASK_NEVER_PATHS  changed paths that stay with the owner even inside the allowlist (plus config away.never_paths)
#   CM_ASK_DENY_DEFS    jq defs, prepended to a jq program that gets the four strings above as --arg:
#     ask_norm                       typographic quotes, dashes, ellipsis, arrows and odd spaces to ASCII
#     ask_files                      the ask's files[] when it is a list of non-empty strings, else []
#     ask_text                       question, topic, lane, worker, path and files[], normalised, one line
#     ask_hits($deny; $squash)       on ask_text: the deny and squash hits, unique (empty: no owner-only subject)
#     ask_bad_files($allow; $never)  files[] outside the allowlist or on a never path
#     ask_scope_why($lane; $owner)   why the ask is not the concertmaster's to decide, whatever its text: no issue number, no
#                                    lane, an ops, epic or pr-sweeper lane, or an epic "plan ready" approval; null when none
#                                    applies. The lane is the ask's lane, else its ledger worker's, lowercased and trimmed
#
# The delegated ask, as a full match over its question and topic (joined, normalised, lowercased, whitespace folded):
# one class phrase and nothing else,
#   [verb] [the] <class> [build|release|bundle|update] [version] [to|on|in [the] <track> [channel|track]] [today|tonight|now]
# with no free words at all. Built from the classes, so they cannot drift. Any other wording (a second clause or action,
# a credential named some new way, a word spelled out, a named customer) is not a match and goes to the owner: an
# allowlist of the shape, not a denylist of words. The secret and cutover scans of scripts/stall.sh still run first,
# as a second layer. The shape has no free-text slot, so no credential or value can ride in one.

# _ask_cfg_alt <jq path> [valid]: a config list of regex fragments joined with |. With `valid`, a fragment that does
# not compile is dropped. Empty list or no config: empty.
_ask_cfg_alt() {
  local f="$1" mode="${2:-}"
  if [ "$mode" = valid ]; then
    cm_cfg_json "$f" '[]' | jq -r 'if type == "array" then . else [] end
      | map(select(type == "string" and length > 0 and (. as $re | try ("" | test($re) | true) catch false))) | join("|")' 2>/dev/null || true
  else
    cm_cfg_json "$f" '[]' | jq -r 'if type == "array" then . else [] end | map(select(type == "string" and length > 0)) | join("|")' 2>/dev/null || true
  fi
}

CM_ASK_DENY_CRED='auth(entic\w*|ori[sz]\w*|n|z)?|oauth|unauthenticated|login|jwt|magic link|secrets?|credentials?|passwords?|api ?keys?|service.?role|env vars?|(access|refresh|api|auth|bearer)[ _-]?tokens?'
_ASK_DENY_BODY='migrat\w*|schema|alter|truncat\w*|rls|row level|polic(y|ies)|grant\w*|privilege\w*|security definer|'"$CM_ASK_DENY_CRED"'|stripe|payments?|billing|subscriptions?|paywall|checkout|webhooks?|deploy\w*|merg(e|es|ed|ing)|prod|production|teardown|delet\w*|drop (table|column|index)|ota|app store|play store|testflight|force.?push|revert\w*|rollback|pii|coppa|gdpr|consent|minors?|dob|date of birth|sql|database|triggers?|constraints?|index(es)?|rpc|access|permissions?|roles?|admin\w*|visib\w*|vault|package\.json|ios|android|codeowners|kill\w*|(send|email|message|dm|notify|ping) (the |a |an )?(users?|customers?|members?|admins?|owner|maintainers?|author)|wipe|purge|destroy|rebase|release (build|to|cut)|publish (to|the app)|ship (to|it|this)|waiv\w*|overrid\w*|bypass\w*|--admin|skip\w* (the )?(gate|review|checks?|ci|tests?)'
# The configured owner's name is an owner-only subject too; away.deny_extra adds project terms.
_ask_owner="${CM_OWNER_NAME:-}"
if [ -z "$_ask_owner" ] || [ "$_ask_owner" = owner ]; then _ask_owner="the owner"; fi
_ask_owner="$(cm_lower "$_ask_owner" | tr -c 'a-z0-9 \n' ' ' | sed 's/^ *//; s/ *$//')"
if [ -n "$_ask_owner" ] && [ "$_ask_owner" != "the owner" ]; then _ASK_DENY_BODY="$_ASK_DENY_BODY|$_ask_owner"; fi
_ask_x="$(_ask_cfg_alt .away.deny_extra)"
if [ -n "$_ask_x" ]; then _ASK_DENY_BODY="$_ASK_DENY_BODY|$_ask_x"; fi
CM_ASK_DENY="\\b($_ASK_DENY_BODY)\\b"
CM_ASK_SQUASH='secret|password|migration|rls|rowlevel|servicerole|apikey|stripe|coppa|securitydefiner|accesstoken|refreshtoken'
# Changed paths a verdict may cover: an allowlist, closed by default.
CM_ASK_ALLOW="$(_ask_cfg_alt .away.allow_paths)"
if [ -z "$CM_ASK_ALLOW" ]; then CM_ASK_ALLOW='^(src/|tests?/|e2e/|docs/|public/)|^[^/]*\.md$'; fi
CM_ASK_NEVER_PATHS='(^|/)(CLAUDE|AGENTS)\.md$|auth|rls|stripe|payment|\.env'
_ask_x="$(_ask_cfg_alt .away.never_paths)"
if [ -n "$_ask_x" ]; then CM_ASK_NEVER_PATHS="$CM_ASK_NEVER_PATHS|$_ask_x"; fi

# The delegated classes of the drive ladder (config drive.delegated_classes). None configured: nothing is delegated.
CM_ASK_DELEGATED_CLASSES="$(_ask_cfg_alt .drive.delegated_classes valid)"
if [ -n "$CM_ASK_DELEGATED_CLASSES" ]; then
  CM_ASK_DELEGATED_ASK='^(((ship|open|run|push|submit|start|approve|promote|roll out|turn on|switch on) )?(the )?('"$CM_ASK_DELEGATED_CLASSES"')( build| release| bundle| update)?( v?[0-9]+(\.[0-9]+){0,3})?( (to|on|in) (the )?(production|staging|beta|internal|alpha)( channel| track)?)?( (today|tonight|now))?)$'
else
  CM_ASK_DELEGATED_ASK='a^'
fi
unset _ask_x _ask_owner

# shellcheck disable=SC2016  # jq program, not shell
CM_ASK_DENY_DEFS='def ask_norm: gsub("[\u2018\u2019\u201a\u2032]"; "'"'"'") | gsub("[\u201c\u201d\u201e\u2033]"; "\"")
        | gsub("[\u2010-\u2015\u2212]"; "-") | gsub("\u2026"; "...") | gsub("[\u2190-\u21ff]"; "->")
        | gsub("[\u00a0\u2000-\u200b\u202f]"; " ");
      def ask_files: (.files // null) | if type == "array" and all(.[]; type == "string" and length > 0) then . else [] end;
      def ask_text: ([.question, .topic, .lane, .worker, .path] + ask_files | map(select(. != null) | tostring) | join(" ") | ask_norm);
      def ask_hits($deny; $squash): (ask_text | ascii_downcase) as $low
        | ([$low | match($deny; "g") | .string] + [$low | gsub("[^a-z0-9]"; "") | match($squash; "g") | .string]) | unique;
      def ask_bad_files($allow; $never): [ask_files[] | select((test($allow) | not) or test($never; "i"))];
      def ask_scope_why($lane; $owner):
        if ((.issue // null) | type) != "number" then "no issue to record a verdict on"
        elif $lane == "" then "no lane (ask or ledger worker): unknown asker stays with \($owner)"
        elif ($lane | startswith("ops")) or ($lane | startswith("epic")) or ($lane | startswith("pr-sweep")) then
          "\($lane) asks stay with \($owner)"
        elif ((.question // "") | tostring | test("^\\s*(cm:blocked\\s+)?plan ready"; "i")) then
          "epic plan approval stays with \($owner)"
        else null end;'
