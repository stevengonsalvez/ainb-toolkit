#!/usr/bin/env bash
# shellcheck shell=bash
# secret-shape.sh: the one "does this text look like a credential" predicate. Sourced, never executed.
# The lane journal writer refuses such text in an entry; the lessons recon refuses it in a lesson line.
# The same shapes scripts/cred-check.sh refuses in its index, plus the vendor prefixes of scripts/scan-secrets.sh.

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

# secret_shaped <text>: 0 when it looks like a credential. A 40-hex commit id is removed first.
secret_shaped() {
  _ss_blank40 "$1" | grep -Eq "($_SS_PREFIX|$_SS_LONG)"
}

# secret_shaped_prefix <text>: 0 when a named credential shape is present (no long-run rule).
secret_shaped_prefix() {
  _ss_blank40 "$1" | grep -Eq "($_SS_PREFIX)"
}
