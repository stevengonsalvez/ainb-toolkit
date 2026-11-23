#!/usr/bin/env bash
# shellcheck shell=bash
# secret-shape.sh: the one "does this text look like a credential" predicate. Sourced, never executed.
# The lane journal writer refuses such text in an entry; the lessons recon refuses it in a lesson line.
# The token shapes are the ones scripts/cred-check.sh refuses in its index, plus the vendor prefixes of
# scripts/scan-secrets.sh; the phrase shapes below are extra.

# Two parts, so a NAME (a lane, a host) can be checked without tripping the long-token rule:
#   prefix shapes  = a token that names itself (a vendor prefix, a URL with user:pass@, a JWT, 64 hex, a key block)
#   long run       = 40 or more of [A-Za-z0-9_-] in a row (any unknown token)
# A kebab-case lane of 42 characters is a long run but not a secret, so a lane or host is checked with
# secret_shaped_prefix on the raw text AND secret_shaped on the text with dashes read as spaces.
#
# The prefixes are written split ('gh''p_') so this file holds no literal token-shaped string for a
# secret scanner to trip on; the shell joins the pieces before grep sees the pattern.
_SS_PREFIX='sb''p_|sb_sec''ret_|sk_li''ve_|sk_te''st_|rk_li''ve_|rk_te''st_|whs''ec_|gh''p_|gh''o_|gh''s_|gh''u_|gh''r_|github_''pat_|sntr''ys_|sntr''yu_|cf''ut_|cf''at_|AK''IA[0-9A-Z]{12}|AS''IA[0-9A-Z]{12}|gl''pat-|xo''x[abeprs]-|xa''pp-|sk-(an''t|pr''oj|sv''cacct|No''ne)-|[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]@]+:[^/[:space:]@]+@|ey''J[A-Za-z0-9_-]{10,}|[A-Fa-f0-9]{64}|-----BEGIN [A-Z ]*PRI''VATE KEY-----'
_SS_LONG='[A-Za-z0-9_-]{40,}'
# Phrase shapes, read on the RAW text (before a 40-hex commit id is blanked, so `Bearer <40 hex>` is still seen), and part of
# both predicates below:
#   raw ERE   `Bearer <20+ token chars>`; a password manager access token `0.<uuid>.<secret>:<key>`
#   password  `password|passwd|passphrase` then `is`, `was`, `set to`, `=` or `:` (or `=`/`:` joined), then a value of 6+
#             characters with a letter and a digit or one of !@#$%^&*+?~= (so "password is required" is plain words)
#   login     `login|signin|sign-in <user> <value>`, the value 6+ characters with a lower, an upper and a digit, or with a
#             letter, a digit and one of !@#$%^&*+?~= (so "login page 2 fixed" is plain words)
_SS_BEARER='[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
_SS_RAW='(^|[^A-Za-z0-9.])0\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.[A-Za-z0-9]{8,}:[A-Za-z0-9+/=]{8,}'
_SS_SYM='[!#$%^&*+?~=]'   # strict (login) check: no @ (an e-mail address) and no / (a path)
_SS_SYM_LOOSE='[!@#$%^&*+?~=]'   # loose (password) check: an @ inside a password value counts

# _ss_value <value> <loose|strict>: 0 when the word after a password or login keyword looks like a real value
_ss_value() {
  local v="$1"
  v="${v#[\"\'\`]}"; v="${v%[\"\'\`.,;:)]}"; v="${v%[\"\'\`]}"
  [ "${#v}" -ge 6 ] && [[ "$v" =~ [A-Za-z] ]] || return 1
  if [ "$2" = strict ]; then
    { [[ "$v" =~ [a-z] ]] && [[ "$v" =~ [A-Z] ]] && [[ "$v" =~ [0-9] ]]; } || { [[ "$v" =~ [0-9] ]] && [[ "$v" =~ $_SS_SYM ]]; }
  else
    [[ "$v" =~ [0-9] ]] || [[ "$v" =~ $_SS_SYM_LOOSE ]]
  fi
}

# _ss_phrase <text>: 0 when a phrase shape is present. bash 3.2 safe (no ${x,,}, no empty "${a[@]}").
_ss_phrase() {
  printf '%s' "$1" | grep -Eq -- "$_SS_RAW" && return 0
  local bt
  while IFS= read -r bt; do   # `Bearer <token>`: a 20+ character token that carries a digit (else it is hyphenated words)
    [ -n "$bt" ] && [[ "${bt##*[[:space:]]}" =~ [0-9] ]] && return 0
  done < <(printf '%s' "$1" | grep -Eo -- "$_SS_BEARER")
  local IFS=$' \t\n' i j n k
  local -a w l
  read -r -d '' -a w < <(printf '%s' "$1" | tr '\r' ' ') || true
  read -r -d '' -a l < <(printf '%s' "$1" | tr '\r' ' ' | tr '[:upper:]' '[:lower:]') || true
  n=${#w[@]}
  for ((i = 0; i < n; i++)); do
    k="${l[$i]}"; k="${k#[\"\'\`]}"
    case "$k" in
      password[=:]?*|passwd[=:]?*|passphrase[=:]?*)
        _ss_value "${w[$i]#*[=:]}" loose && return 0 ;;
      password|passwd|passphrase|password[=:]|passwd[=:]|passphrase[=:])
        j=$((i + 1))
        case "${l[$j]:-}" in is|was|=|:) j=$((j + 1)) ;; set) [ "${l[$((j + 1))]:-}" = to ] && j=$((j + 2)) ;; esac
        if [ "$j" -gt $((i + 1)) ] || [[ "$k" == *[=:] ]]; then _ss_value "${w[$j]:-}" loose && return 0; fi ;;
      login|signin|sign-in)
        case "${l[$((i + 1))]:-}" in as|with|via|on|to|in|for|at|by|from|using|into|after|page|is|was|works|failed|fails) ;;
          *) _ss_value "${w[$((i + 2))]:-}" strict && return 0 ;; esac ;;
    esac
  done
  return 1
}


# _ss_blank40 <text>: each 40-hex commit id is blanked; repeat, because two ids one space apart share the boundary character
_ss_blank40() {
  local t prev
  t="$1"
  while :; do
    prev="$t"
    t="$(printf '%s' "$t" | sed -E 's/(^|[^A-Za-z0-9_-])[0-9a-f]{40}([^A-Za-z0-9_-]|$)/\1 \2/g')"
    [ "$t" != "$prev" ] || break
  done
  printf '%s' "$t"
}

# secret_shaped <text>: 0 when it looks like a credential (a phrase shape, a prefix shape or a long run). A 40-hex
# commit id is removed first, for the token shapes only.
secret_shaped() {
  _ss_phrase "$1" && return 0
  _ss_blank40 "$1" | grep -Eq "($_SS_PREFIX|$_SS_LONG)"
}

# secret_shaped_prefix <text>: 0 when a phrase shape or a named credential shape is present (no long-run rule).
secret_shaped_prefix() {
  _ss_phrase "$1" && return 0
  _ss_blank40 "$1" | grep -Eq "($_SS_PREFIX)"
}
