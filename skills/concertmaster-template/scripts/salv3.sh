#!/usr/bin/env bash
# salv3.sh: salvage a worktree's unsaved work to $CM_HOME/salvage before it is removed.
# The guard before `orca worktree rm` on remote hosts (teardown.sh covers the local host).
#
#   scripts/salv3.sh <worktree-name-or-absolute-path>...
#
# RUN IT ON THE HOST THAT OWNS THE WORKTREE. It reads the local filesystem only: run
# against a remote worktree's name on the wrong host it reports ABSENT, never a removal
# signal. Standalone (no lib.sh), so it can be streamed over ssh:
#
#   ssh <hosts.<name>.hostname> 'CM_WORKTREE_BASE=<dir holding the worktrees> bash -s -- <name>...' \
#     < scripts/salv3.sh
#
# A bare name is looked up under CM_WORKTREE_BASE (default: the directory that holds the
# worktree this script's skill is checked out in, when run from a checkout). Per worktree it
# prints ONE line:
#   RESULT <w> branch=<b> dirty=<n> ahead_main=<n> unpushed_vs_remote=<n|none> salvage=<dir>
#   RESULT <w> ABSENT | NO-BASE | FAILED <what>
# and writes untracked.tgz, ignored.tgz, dirty.diff and branch.bundle (commits not on
# origin/main) into $CM_HOME/salvage/<hostname>/<worktree>-<branch>-<utc>/ (mode 700); every
# tarball is verified with `tar -tzf`.
#
# EXIT CODE: 0 only when every worktree was found and every archive verified. Non-zero (1)
# on ABSENT, NO-BASE or FAILED: the caller must NOT run `orca worktree rm` after a non-zero
# exit, and removes only worktrees whose RESULT shows dirty=0 and ahead_main=0 (or whose
# branch is proven an ancestor of the merge target for a `noupstream` branch).
# Exit 2: bad usage.
#
# Rules baked in: never run git diff with textconv here (a decrypting git filter such as
# transcrypt would write decrypted values into the salvage); never copy credential paths (a
# `password` or `.transcrypt_password` file, signing keys `.keys/`, `keystores/`,
# `playwright/auth/`, plus every name in CM_SALVAGE_EXCLUDE, space-separated: a bare name matches
# at any depth, a name with a slash is a path from the worktree root; pass it over ssh like
# CM_WORKTREE_BASE); directory mode 700 (gitignored env files ARE kept: teardown rules treat them
# as precious, and they already sit decrypted on this same host). Needs GNU tar.
set -uo pipefail
umask 077
CM_HOME="${CM_HOME:-$HOME/.concertmaster}"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
TOP="$(git -C "${HERE:-.}" rev-parse --show-toplevel 2>/dev/null || true)"
BASE="${CM_WORKTREE_BASE:-${TOP:+$(dirname "$TOP")}}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
[ $# -gt 0 ] || { sed -n '2,35p' "$0" >&2; exit 2; }
# Credential paths never copied: defaults plus CM_SALVAGE_EXCLUDE. XRE filters git's ignored-file
# list; the tar flags repeat it, because git lists an untracked parent directory whole.
XNAMES="password .transcrypt_password .keys keystores playwright/auth ${CM_SALVAGE_EXCLUDE:-}"
XRE='(^|/)(node_modules|dist|\.vite|coverage|\.git)(/|$)'; XTAR=()
set -f
for n in $XNAMES; do
  e="${n//./\\.}"
  case "$n" in
    */*) XRE="$XRE|^$e/" ;;
    *) XRE="$XRE|(^|/)$e(/|\$)" ;;
  esac
  XTAR+=("--exclude=$n")
done
set +f
rc=0
fail() { echo "RESULT $1 FAILED $2"; rc=1; }
for w in "$@"; do
  case "$w" in
    /*) d="$w" ;;
    *) if [ -z "$BASE" ]; then echo "RESULT $w NO-BASE (set CM_WORKTREE_BASE or pass an absolute path)"; rc=1; continue; fi; d="$BASE/$w" ;;
  esac
  if ! { [ -d "$d" ] && git -C "$d" rev-parse --git-dir >/dev/null 2>&1; }; then echo "RESULT $w ABSENT (looked in $d, on host $(hostname))"; rc=1; continue; fi
  dirty=$(git -C "$d" status --porcelain --untracked-files=normal | wc -l | tr -d ' ')
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD)
  git -C "$d" fetch --quiet origin main 2>/dev/null
  ahead=$(git -C "$d" rev-list --count origin/main..HEAD 2>/dev/null || echo ?)
  pushed=$(git -C "$d" ls-remote --exit-code --heads origin "$br" >/dev/null 2>&1 && git -C "$d" rev-list --count "origin/$br..HEAD" 2>/dev/null || echo none)
  name="$(basename "$d")"
  out="$CM_HOME/salvage/$(hostname)/${name//[^A-Za-z0-9._-]/_}-${br//[^A-Za-z0-9._-]/_}-$TS"
  mkdir -p "$out" || { fail "$w" "cannot create $out"; continue; }
  git -C "$d" ls-files --others --exclude-standard -z > "$out/untracked.list"
  bad=""
  if [ -s "$out/untracked.list" ]; then
    (cd "$d" && tar --null -T "$out/untracked.list" -czf "$out/untracked.tgz" 2>/dev/null) || bad="$bad untracked-tar"
    tar -tzf "$out/untracked.tgz" >/dev/null 2>&1 || bad="$bad untracked-verify"
  fi
  git -C "$d" ls-files --others --ignored --exclude-standard --directory -z \
    | grep -zv -E "$XRE" > "$out/ignored.list" || true
  # git lists an untracked parent directory whole, so also exclude credential paths in tar itself
  # (GNU tar: --exclude must come BEFORE -T to apply to its entries).
  (cd "$d" && tar --exclude=node_modules "${XTAR[@]}" \
    --null -T "$out/ignored.list" -czf "$out/ignored.tgz" 2>/dev/null) || bad="$bad ignored-tar"
  tar -tzf "$out/ignored.tgz" >/dev/null 2>&1 || bad="$bad ignored-verify"
  git -C "$d" diff --no-textconv HEAD > "$out/dirty.diff" 2>/dev/null || bad="$bad diff"
  if [ "$ahead" != "0" ]; then
    range="origin/main..HEAD"; [ "$ahead" = "?" ] && range="HEAD"   # no origin/main: keep all of HEAD
    git -C "$d" bundle create "$out/branch.bundle" "$range" >/dev/null 2>&1 || bad="$bad bundle"
  fi
  if [ -n "$bad" ]; then fail "$w" "$bad (salvage=$out)"; continue; fi
  echo "RESULT $w branch=$br dirty=$dirty ahead_main=$ahead unpushed_vs_remote=$pushed salvage=$out"
done
exit "$rc"
