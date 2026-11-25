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
#                       A fragment that is not a class phrase (no compile, an empty match, a wildcard, a negated
#                       class or a repeat) is dropped with a warning (fewer delegated classes: fail safe)
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
#     ask_kind                       the ask's kind: .kind, else .scope, a string, else ""
#     ask_bad($k)                    null for a well-formed ledger ask, else why it is the owner's before any text is
#                                    read: a non-text question, topic, lane, worker or path, a files[] that is not a
#                                    list of text, or those fields over 4000 characters as JSON
#     ask_owner_why($k; $workers; $allow; $never; $deny; $squash; $cred; $ask)
#                                    null when a ledger ask of kind $k may be decided without the owner, else why it is
#                                    owner-only. The one definition of "owner-only": scripts/stall.sh exempts these asks
#                                    as Blocked and scripts/digest.sh --full lists them under "Blocked on you", so the two
#                                    can never disagree. Delegated: release and deploy, only when the question and topic
#                                    are one configured class phrase end to end ($ask) and name no cutover, runbook step
#                                    or secret. Own-scope (code, design, test, scope, product): only past the
#                                    ask-timeout.sh gates and the deny scan above. secrets ALWAYS goes to the owner
#                                    (whether a key is shared with production is a property of the key, not of the
#                                    wording). Every other kind, and a missing or unknown one, is owner-only.
#                                    $cred is CM_ASK_DENY_CRED and $ask is CM_ASK_DELEGATED_ASK; ask_bad runs first.
#                                    $workers is the ledger .workers object (a noCode ask whose worker has a PR is refused).
#                                    Who is asking is also read, in the order ask-timeout.sh reads it, and each of these is
#                                    owner-only: a workers map that is not an object, a blank worker id, a worker row that
#                                    is not an object, a worker lane that is not text, and ask_scope_why. The worker row is
#                                    found by the trimmed id against the trimmed keys of the workers map (a padded key
#                                    " w-z " is the worker w-z), and an id that two keys share once trimmed is owner-only:
#                                    no row is picked. The owner is named in a reason by CM_ASK_OWNER_LABEL (exported here:
#                                    the configured owner name, else "the owner")
#
# The delegated ask, as a full match over its question and topic (joined, normalised, lowercased, whitespace folded):
# one class phrase and nothing else,
#   [verb] [the] <class> [build|release|bundle|update] [version] [to|on|in [the] <track> [channel|track]] [today|tonight|now]
# with no free words at all. Built from the classes, so they cannot drift. Any other wording (a second clause or action,
# a credential named some new way, a word spelled out, a named customer) is not a match and goes to the owner: an
# allowlist of the shape, not a denylist of words. The secret and cutover scans of scripts/stall.sh still run first,
# as a second layer. The shape has no free-text slot, so no credential or value can ride in one.

# _ask_cfg_alt <jq path> [valid]: a config list of regex fragments joined with |. With `valid`, a fragment that is not
# a class phrase (lib.sh CM_JQ_CLASS_PHRASE) is dropped with a warning: config-check may not have run. Empty list or no
# config: empty.
_ask_cfg_alt() {
  local f="$1" mode="${2:-}" l bad
  l="$(cm_cfg_json "$f" '[]' | jq -c 'if type == "array" then . else [] end | map(select(type == "string" and length > 0))' 2>/dev/null)" || l='[]'
  if [ "$mode" = valid ]; then
    bad="$(printf '%s' "$l" | jq -r "$CM_JQ_CLASS_PHRASE"'map(select(class_phrase | not)) | join(", ")' 2>/dev/null)" || bad="(unreadable)"
    [ -z "$bad" ] || cm_warn "ask-deny: $f: dropped, not a class phrase (scripts/config-check.sh): $bad"
    l="$(printf '%s' "$l" | jq -c "$CM_JQ_CLASS_PHRASE"'map(select(class_phrase))' 2>/dev/null)" || l='[]'
  fi
  printf '%s' "$l" | jq -r 'join("|")' 2>/dev/null || true
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
CM_ASK_OWNER_LABEL="${CM_OWNER_NAME:-}"
if [ -z "$CM_ASK_OWNER_LABEL" ] || [ "$CM_ASK_OWNER_LABEL" = owner ]; then CM_ASK_OWNER_LABEL="the owner"; fi
export CM_ASK_OWNER_LABEL
unset _ask_x _ask_owner

# shellcheck disable=SC2016  # jq program, not shell
CM_ASK_DENY_DEFS='def ask_norm: gsub("[\u2018\u2019\u201a\u2032]"; "'"'"'") | gsub("[\u201c\u201d\u201e\u2033]"; "\"")
        | gsub("[\u2010-\u2015\u2212]"; "-") | gsub("\u2026"; "...") | gsub("[\u2190-\u21ff]"; "->")
        | gsub("[\u00a0\u2000-\u200b\u202f]"; " ");
      def ask_files: .files | if type == "array" and all(.[]; type == "string" and length > 0) then . else [] end;
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
        else null end;
      # the kind is `kind`, else `scope` when there is NO kind. A kind that is present but not text (false included: `//` would
      # read it as absent and fall through to scope, so a merge ask carrying kind false and scope release would read as a
      # delegated release) is no kind at all, which is owner-only
      def ask_kind: ((if .kind != null then .kind else .scope end) | if type == "string" then ascii_downcase | gsub("^\\s+|\\s+$"; "") else "" end);
      def ask_known_kinds: ["release", "deploy", "secrets", "code", "design", "test", "scope", "product", "merge", "credentials",
                            "migration", "auth", "payments", "prod-data", "teardown", "owner", "remove-standing",
                            "accept-unmerged-beads"];
      def ask_bad($k):
          (if ($k | IN(ask_known_kinds[])) then $k else "unknown kind" end) as $ks
          | if ([.question, .topic] | any(. != null and type != "string")) then "of kind \($ks) with a non-text question or topic"
            elif ([.lane, .worker, .path] | any(. != null and type != "string")) then "of kind \($ks) with a non-text field"
            elif .files != null and ((.files | type) != "array" or any(.files[]; type != "string")) then
              "of kind \($ks) with an invalid files[]"
            elif ([.question, .topic, .lane, .worker, .path, .files] | tojson | length) > 4000 then
              "of kind \($ks) with an over-long ask text"
            else null end;
      # the workers map with its keys trimmed, as ask-timeout.sh reads it (a padded key " w-z " is the worker w-z), and the trimmed
      # ids that two or more keys share (dup): the ask of such a worker goes to the owner and no row is picked. A key that is only
      # white space keeps its own spelling
      def ask_wsnorm($workers):
          ($workers | if type == "object" then . else {} end | to_entries | map(. + {k: (.key | gsub("^\\s+|\\s+$"; ""))})) as $es
          | {ws: (reduce $es[] as $e ({}; .[(if $e.k == "" then $e.key else $e.k end)] = $e.value)),
             dup: ([$es[] | select(.k != "") | .k] | group_by(.) | map(select(length > 1) | .[0]))};
      def ask_owner_why($k; $workers; $allow; $never; $deny; $squash; $cred; $ask):
          ($ENV.CM_ASK_OWNER_LABEL // "the owner") as $owner
          | (if ($k | IN(ask_known_kinds[])) then $k else "unknown kind" end) as $ks
          | ask_bad($k) as $bad
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
              if $qlen > 200 then "of kind \($ks) with an over-long question or topic"
                else
              ask_text as $t
              | ($t | ascii_downcase) as $tl
              | ($tl | gsub("[\\n\\r\\t\\x0b\\f]+"; " ")) as $tlf
              | ([.question, .topic] | map(strings) | join(" ") | ask_norm | ascii_downcase | gsub("\\s+"; " ") | gsub("^ | $"; "")) as $qt
              # a go line starts after any line break: newline, carriage return, vertical tab (\x0b) or form feed
              | if ($t | explode | any(. > 127)) then "of kind \($ks) with non-ASCII text"
                elif ($tl | test("(^|[\\n\\r\\x0b\\f])[-*>`\\s]*go\\s+[a-z0-9-]+\\s+(staging|production)([^a-z0-9]|$)|cutover|runbook")) then
                  "of kind \($ks) naming a runbook or cutover (a go line, a cutover, a runbook step)"
                # the secret scan is the credential segment of the shared deny list (CM_ASK_DENY_CRED, passed as $cred, so
                # the two cannot drift) plus the release-only terms below; a short word (key, keys, pat, pats, cert, certs,
                # p8, p12, dsn, bearer) counts only as a word, so keyboard, monkey, pathfinder and patch do not.
                # Over-matching key or pats in lane or worker text is accepted: it only sends the ask to the owner
                elif ($tlf | test("\\b(" + $cred + ")\\b"))
                     or ($tlf | test("secret|credential|api.?key|token|password|passphrase|keystore|signing|private|account.?wide|org.?wide|repo.?level|service.?role|service.?account|access.?key|webhook|vault|provisioning|keychain|hmac|\\.env\\b|\\b(pem|jks)\\b|(^|[^a-z0-9])(keys?|pats?|certs?|certificates?|p8|p12|dsn|bearer)([^a-z0-9]|$)")) then
                  "of kind \($ks) naming a secret or an account-wide key"
                # default deny, by an allowlist of the shape and not a denylist of words: the question and topic must match
                # CM_ASK_DELEGATED_ASK (built from config drive.delegated_classes, passed as $ask) end to end: one class
                # phrase with no free words. Any other wording goes to the owner, and with no class configured every
                # release or deploy ask does. The cutover and secret scans above still run first
                elif ($qt | test($ask) | not) then
                  "of kind \($ks): a delegated ask must be one class phrase: <verb> the <class> <version> <track>; any other wording goes to the owner"
                else null end end
            # a secrets ask never ladders: a key shared with production (an OTA or store signing key, a CLI token, a repo-level
            # GitHub secret) reads the same as a test one, so the owner decides every one
            elif $k == "secrets" then "of kind secrets (a secrets ask always goes to the owner)"
            elif ($k | IN("code", "design", "test", "scope", "product")) then
              ask_text as $t | ask_bad_files($allow; $never) as $bf | ask_hits($deny; $squash) as $h
              # every ask that ask-timeout.sh keeps with the owner for who is asking (its "never" set), in the same order of reading:
              # the workers map, the worker id (trimmed, blank), the worker row, the lane of that row, and the lane of the ask itself
              # (else the lane of its worker row). A missing lane is an unknown asker and goes to the owner: it is never "no hold"
              | (.worker | if type == "string" then gsub("^\\s+|\\s+$"; "") else "" end) as $wk
              | ask_wsnorm($workers) as $wn
              | $wn.ws as $ws
              | $ws[$wk] as $wr
              | ($wr | if type == "object" then .lane else null end) as $wl
              | ((if .lane != null then .lane else $wl end) | if type == "string" then ascii_downcase | gsub("^\\s+|\\s+$"; "") else "" end) as $lane
              | ask_scope_why($lane; $owner) as $sw
              | if ($t | explode | any(. > 127)) then "of kind \($ks) with non-ASCII text"
                elif ($workers != null and ($workers | type) != "object") then "of kind \($ks) with a workers map that is not an object"
                elif (.worker != null and ($wn.dup | index($wk)) != null) then "of kind \($ks) whose worker id is the key of two worker rows once padding is trimmed"
                elif (.worker != null and ($wk | test("\\S") | not)) then "of kind \($ks) with a blank worker id"
                elif (($ws | has($wk)) and ($wr | type) != "object" and (.worker != null or $wr != null)) or ($wr != null and ($wr | type) != "object") then "of kind \($ks) whose worker row is not an object"
                elif ($wr | type) == "object" and $wr.lane != null and ($wr.lane | type) != "string" then "of kind \($ks) with a non-text worker lane"
                # no issue, no lane, the ops lanes, the epic leads, the PR sweeper and an epic "plan ready" approval never get an
                # autonomous verdict (ask-timeout.sh calls them never), so their asks go to the owner: without this the digest
                # dropped them from "Blocked on you" and stall laddered them, while the away timeout said they stay with the owner
                elif $sw != null then "of kind \($ks): \($sw)"
                elif .files != null and (.files != ask_files) then "of kind \($ks) with an invalid files[]"
                # as ask-timeout.sh: the changed paths are listed (files[]) unless noCode is true, and a noCode ask has no PR
                elif (ask_files | length) == 0 and .noCode != true then "of kind \($ks) with no files[] (list the changed paths, or set noCode)"
                elif (ask_files | length) == 0
                     and ((if .pr != null then .pr else ($wr | if type == "object" then .pr else null end) end) != null) then "of kind \($ks) with noCode but the worker has a PR"
                elif ($bf | length) > 0 then "of kind \($ks) touching \($bf[0])"
                elif ($h | length) > 0 then "of kind \($ks) naming \($h | join(","))"
                else null end
            elif $k == "" then "with no kind"
            else (if $ks == "unknown kind" then "of an unknown kind" else "of kind \($ks)" end) end;'
