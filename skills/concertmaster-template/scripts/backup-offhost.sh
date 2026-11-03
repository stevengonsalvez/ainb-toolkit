#!/usr/bin/env bash
# backup-offhost.sh: nightly off-host copy of the concertmaster's control plane to a peer host.
#
#   scripts/backup-offhost.sh [--check | --dry-run] [--dest DIR | --host HOST] [--remote-dir DIR] [--keep N]
#
# Copies from $CM_HOME (default ~/.concertmaster): ledger.json, the ledger ring (ledger.bak/) and
# handovers/. Nothing else (not inbox/, briefs/ or lanes/: they can hold credential paths and
# pasted values). handovers/ is NOT known to be clean: each handover holds the task, the brief and
# a pane summary, so it can carry pasted text. The scan below is a heuristic (it catches a pure-letter
# password only after the name password, passwd, pwd or passphrase; it misses bare values and every other form, and
# knows nothing of personal data about people); the handover rule in
# SKILL.md forbids pasting either into a handover, and this backup relies on that rule too.
# Files and directories inside handovers/ named like a forbidden name (inbox, briefs, lanes, salvage,
# outbox*, tmp.*, env, secret and key files) are left out and named on stderr. Four walls, in order:
#   1. the exact file set is first copied into a private snapshot, and the secret scanner
#      (scan-secrets.sh, next to this script) runs on THAT snapshot BEFORE anything leaves the host.
#      A hit, a scan error or a missing scanner: nothing is copied, exit 4, only counts, file paths
#      and the scanner's own error lines are printed, never a match;
#   2. what goes to the peer is the scanned snapshot, byte for byte: a file that changes after the
#      scan (the ledger is rewritten every tick) is not what is sent;
#   3. an exclude list (mc.env, *.env, salvage/, secrets, tmp.*, outbox*, keys) sits in front of
#      the include list;
#   4. the finished generation is scanned for forbidden names on the peer (exit 6).
#
# Each run writes one dated generation, <remote-dir>/<UTC yyyymmddThhmmssZ>/, hard-linked against
# the previous one (rsync --link-dest), so unchanged files cost no space. The newest N (default 7)
# are kept on the peer; older ones are removed there. Nothing is deleted from $CM_HOME; a finished run writes
# one small stamp, $CM_HOME/cache/backup-offhost.json, which scripts/backup-stale.sh reads. Give each source
# host its own remote_dir: the start of a run removes stale .incoming-* copies in it.
# <remote-dir>/latest points at the newest generation.
#
#   --host HOST         peer to ssh to (config backup.host; env CM_BACKUP_HOST)
#   --remote-dir DIR    directory on the peer, relative to its home or absolute
#                       (config backup.remote_dir; env CM_BACKUP_REMOTE_DIR)
#   --dest DIR          local-path mode: DIR plays the peer, no ssh. Used by the tests
#   --keep N            generations to keep (config backup.keep, default 7)
#   --check             read the config and ssh to the peer (BatchMode, 10s connect timeout), list its
#                       newest generation, print peer-ok, exit 0. Needs no ledger and writes nothing, here
#                       or on the peer. Run it under `env -i` with the PATH of the cron line to test cron's
#                       environment (references/recovery.md). Exit 2 not configured, 3 peer unreachable
#   --dry-run           rsync -n against the newest generation: lists what would change, writes
#                       nothing on the peer (the reachability check and a directory listing run)
# Env: CM_BACKUP_SSH   the ssh command (default: ssh -o BatchMode=yes -o ConnectTimeout=10 ...)
#      CM_BACKUP_RSYNC the rsync command (tests); CM_BACKUP_NOW a fixed UTC stamp (tests)
# Config (config.yaml): backup: { host, remote_dir, keep }. The host has NO default: the owner
# chooses it. Unset means exit 2.
# Exit: 0 done, 1 failed, 2 bad usage or not configured, 3 peer unreachable, 4 the secret scan
# refused the copy (hits, errors or no scanner), 5 another run holds the lock, 6 a forbidden file
# reached the generation (it is removed; nothing is kept).
# shellcheck disable=SC2016  # the peer-side scripts are single-quoted on purpose: they expand on the peer
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

die() { printf 'backup-offhost: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^# shellcheck/{/^# shellcheck/d;p;}' "$0"; }

HOST="${CM_BACKUP_HOST:-$(cm_cfg .backup.host)}"
RDIR="${CM_BACKUP_REMOTE_DIR:-$(cm_cfg .backup.remote_dir)}"
KEEP="${CM_BACKUP_KEEP:-$(cm_cfg .backup.keep 7)}"
DEST=""; DRY=0; CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --check) CHECK=1 ;;
    --host) [ $# -ge 2 ] || die "--host needs a name" 2; HOST="$2"; shift ;;
    --remote-dir) [ $# -ge 2 ] || die "--remote-dir needs a path" 2; RDIR="$2"; shift ;;
    --dest) [ $# -ge 2 ] || die "--dest needs a directory" 2; DEST="$2"; shift ;;
    --keep) [ $# -ge 2 ] || die "--keep needs a number" 2; KEEP="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
  shift
done

case "$KEEP" in ''|*[!0-9]*) die "keep must be a whole number, got: $KEEP" 2 ;; esac
[ "$KEEP" -ge 1 ] || die "keep must be 1 or more" 2
if [ -n "$DEST" ]; then RDIR="$DEST"; HOST=""; fi
if [ -z "$DEST" ] && [ -n "$CM_CONFIG_FILE" ] && ! command -v yq >/dev/null 2>&1; then
  die "yq is not on PATH ($PATH), so config.yaml ($CM_CONFIG_FILE) cannot be read. Under cron put the directory holding yq on PATH (references/recovery.md)" 2
fi
[ -n "$DEST" ] || [ -n "$HOST" ] || die "backup.host is not set: the owner chooses the target host (config.yaml backup.host, or --host)" 2
[ -n "$RDIR" ] || die "no backup target: set backup.remote_dir in config.yaml, or pass --remote-dir (or --dest DIR)" 2
# A plain path: no spaces or shell characters, no .., not the root, no leading - ~ or : . It is
# spliced into remote commands and handed to rsync, so it is checked, not quoted.
case "$RDIR" in /|.|..|*/../*|../*|*/..) die "remote dir is not a usable directory: $RDIR" 2 ;; esac
# [[ =~ ]] matches the whole value, a newline included (grep checks line by line).
re_dir='^(/|\./)?[A-Za-z0-9_][A-Za-z0-9_./-]*$'
[[ $RDIR =~ $re_dir ]] \
  || die "remote dir must be a plain path of letters, digits and _ . / - (not starting with - or ~): $RDIR" 2
re_host='^[A-Za-z0-9_][A-Za-z0-9_.@-]*$'
[ -z "$HOST" ] || [[ $HOST =~ $re_host ]] \
  || die "host has characters outside A-Za-z0-9_.@-, or starts with -: $HOST" 2
RDIR="${RDIR%/}"

# ---- transport ---------------------------------------------------------------------------
SSH_CMD="${CM_BACKUP_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3}"
TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 3600"

# peer_sh <script> [args...]: run a POSIX sh script on the peer (or here in --dest mode).
# Arguments are plain (checked above), joined into one remote command line.
peer_sh() {
  local script="$1"; shift
  if [ -n "$DEST" ]; then sh -c "$script" peer-sh "$@"
  else
    # shellcheck disable=SC2086  # SSH_CMD is a command line on purpose
    $TMO $SSH_CMD "$HOST" "sh -c '$script' peer-sh $*"
  fi
}

# newest existing generation on the peer, empty when none (read only)
LIST='cd "$1" 2>/dev/null && ls -1 | grep -E "^[0-9]{8}T[0-9]{6}Z$" | sort | tail -n 1; exit 0'
peer_reachable() {
  local err
  # shellcheck disable=SC2086
  if ! err="$($SSH_CMD "$HOST" true 2>&1)"; then
    die "peer $HOST is unreachable over ssh (BatchMode, 10s connect timeout): ${err:-no output}. Nothing was copied; the local files are untouched." 3
  fi
}

# ---- --check: the config and the peer, nothing else ---------------------------------------------
if [ "$CHECK" = 1 ]; then
  if [ -n "$DEST" ]; then printf 'backup-offhost: check: local-path mode (--dest %s), no ssh to test\n' "$DEST"; exit 0; fi
  peer_reachable
  # the listing exits 0 for a missing directory (nothing there yet), so a non-zero status is the connection or the shell failing
  # stdout is the listing and nothing else; ssh's own messages (a known_hosts notice) go to a file and are shown only on failure
  LERR="$(mktemp "${TMPDIR:-/tmp}/cm-backup-lerr.XXXXXX")" || die "cannot create a temp file"
  lrc=0; lst="$(peer_sh "$LIST" "$RDIR" 2>"$LERR")" || lrc=$?
  lmsg="$(tail -n 1 "$LERR" | LC_ALL=C tr -c '[:print:]' '?' | cut -c1-160)"
  rm -f -- "${LERR:?}"; LERR=""   # this branch exits before the cleanup trap below is set
  [ "$lrc" = 0 ] || die "peer $HOST answered ssh but the listing of $RDIR failed: $lmsg" 3
  PREV="$(printf '%s\n' "$lst" | tail -n 1)"
  case "$PREV" in ''|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;; *) PREV="(unreadable: $(printf '%s' "$PREV" | LC_ALL=C tr -c '[:print:]' '?' | cut -c1-60))" ;; esac
  printf 'peer-ok: %s, remote dir %s, newest generation: %s\n' "$HOST" "$RDIR" "${PREV:-none yet}"
  exit 0
fi

SRC="$CM_HOME"
[ -d "$SRC" ] || die "CM_HOME is not a directory: $SRC" 2
[ -s "$SRC/ledger.json" ] || die "no ledger at $SRC/ledger.json (missing or empty): nothing worth backing up, refusing to publish an empty generation" 1

# ---- lock: one run at a time -------------------------------------------------------------
LOCKF="$SRC/.backup-offhost.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKF" || die "cannot open the lock file $LOCKF"
  flock -n 9 || die "another backup-offhost run holds $LOCKF; skipping this one" 5
else
  LOCKD="$LOCKF.d"
  mkdir "$LOCKD" 2>/dev/null || die "another backup-offhost run holds $LOCKD (no flock here; remove it only if no run is active)" 5
fi
LISTF=""; LIST2=""; SNAP=""; SCANERR=""; STAMPT=""; LERR=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ -z "${LOCKD:-}" ] || rmdir "$LOCKD" 2>/dev/null
  [ -z "$LISTF" ] || rm -f -- "${LISTF:?}"
  [ -z "$LIST2" ] || rm -f -- "${LIST2:?}"
  [ -z "$SNAP" ] || rm -rf -- "${SNAP:?}"
  [ -z "$SCANERR" ] || rm -f -- "${SCANERR:?}"
  [ -z "$STAMPT" ] || rm -f -- "${STAMPT:?}"
  [ -z "$LERR" ] || rm -f -- "${LERR:?}"
}
trap cleanup EXIT

# ---- the exact file set, scanned before anything is copied -------------------------------------
SCANNER="$HERE/scan-secrets.sh"
[ -f "$SCANNER" ] || die "secret scanner not found: $SCANNER. Nothing was copied: the scanner ships next to this script and the backup refuses to run without it" 4
for d in ledger.bak handovers; do
  [ ! -L "$SRC/$d" ] || printf 'backup-offhost: warning: %s/%s is a symlink and is not backed up (replace the symlink with the real directory)\n' "$SRC" "$d" >&2
done
LISTF="$(mktemp "${TMPDIR:-/tmp}/cm-backup-list.XXXXXX")" || die "cannot create a temp file"
(cd "$SRC" && find ledger.json ledger.bak handovers \( -type f -o -type l \) -print0 2>/dev/null) > "$LISTF"
[ -s "$LISTF" ] || die "no files to back up" 1
# A private snapshot of exactly that set: the scan and the transfer both read the snapshot, so a file
# that changes between them cannot send unscanned bytes. 24 = a file vanished while copying.
SNAP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/cm-backup-snap.XXXXXX")" || die "cannot create a temp dir"
rsync -a --files-from="$LISTF" --from0 "$SRC/" "$SNAP/" 2>/dev/null; rc=$?
{ [ "$rc" = 0 ] || [ "$rc" = 24 ]; } || die "cannot snapshot the files to scan (rsync exit $rc); nothing was copied" 1
(cd "$SNAP" && find ledger.json ledger.bak handovers \( -type f -o -type l \) -print0 2>/dev/null) > "$LISTF"
# A symlink to a directory (a symlinked handovers/) is neither scanned nor sent: the scanner would
# follow it out of the snapshot. Rebuild the list without it.
# Also left out, with the name on stderr: a dangling symlink, a name with a newline, and any path with
# a component named like a forbidden name (the peer would refuse the whole copy for it, exit 6).
skip() { printf 'backup-offhost: warning: not backed up (%s): %s\n' "$1" "$(printf '%s' "$2" | LC_ALL=C tr -c '[:print:]' '?')" >&2; }
forbidden_component() { # forbidden_component <relative path>
  local IFS=/ c
  set -f   # a name with a glob character must not expand against the current directory
  for c in $1; do
    case "$c" in mc.env|*.env|.env*|salvage|briefs|inbox|lanes|outbox*|tmp.*|.secrets|secrets|*.pem|*.key) set +f; return 0 ;; esac
  done
  set +f
  return 1
}
SET=(); LIST2="$(mktemp "${TMPDIR:-/tmp}/cm-backup-list.XXXXXX")" || die "cannot create a temp file"   # not "$LISTF.2": a name made from another one can be planted
while IFS= read -r -d '' f; do
  { [ -L "$SNAP/$f" ] && [ -d "$SNAP/$f" ]; } && continue
  case "$f" in *$'\n'*) skip "name has a newline" "$f"; continue ;; esac
  [ ! -L "$SNAP/$f" ] || [ -e "$SNAP/$f" ] || { skip "dangling symlink" "$f"; continue; }
  ! forbidden_component "$f" || { skip "forbidden name" "$f"; continue; }
  SET+=("$SNAP/$f"); printf '%s\0' "$f" >> "$LIST2"
done < "$LISTF"
mv -f -- "$LIST2" "$LISTF"
[ -f "$SNAP/ledger.json" ] || die "ledger.json vanished while snapshotting; nothing was copied" 1
# --strict: the advisory password class blocks too. Output is counts and paths, never a match.
SCANERR="$(mktemp "${TMPDIR:-/tmp}/cm-backup-scanerr.XXXXXX")" || die "cannot create a temp file"
scan_out="$(bash "$SCANNER" --strict -- "${SET[@]}" 2>"$SCANERR")"; scan_rc=$?
if [ "$scan_rc" != 0 ]; then
  {
    printf 'backup-offhost: the secret scan refused the copy (scanner exit %s). Nothing was copied. Counts only:\n' "$scan_rc"
    # file rows name paths under the snapshot, which is deleted at exit: show them relative to $CM_HOME
    printf '%s\n' "$scan_out" | SNAPP="$SNAP/" awk -F'\t' '$1 == "SUMMARY" || /^SUMMARY / { print "  " $0; next } NF == 4 && $1 != "FILE" && $2 > 0 { print "  " $1 ": " $2 } $1 == "FILE" && ++n <= 10 { f = $2; snap = ENVIRON["SNAPP"]; if (index(f, snap) == 1) f = substr(f, length(snap) + 1); print "  " f " " $3 " x" $4 }'
    # the scanner's own error lines (they name the file it could not read), cleaned and capped
    SNAPP="$SNAP/" awk 'NR <= 5 { l = $0; snap = ENVIRON["SNAPP"]; while ((i = index(l, snap)) > 0) l = substr(l, 1, i - 1) substr(l, i + length(snap)); gsub(/[^[:print:]]/, "?", l); print "  scanner: " substr(l, 1, 200) }' "$SCANERR"
    printf '  Fix the files named above (or the scanner), then rerun.\n'
  } >&2
  exit 4
fi

[ -n "$DEST" ] || peer_reachable

TS="${CM_BACKUP_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"
case "$TS" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;; *) die "bad generation stamp: $TS" 2 ;; esac

PREV="$(peer_sh "$LIST" "$RDIR" 2>/dev/null | tail -n 1)"
# The peer's answer becomes a --link-dest path: it must be a generation name, nothing else.
{ [ -z "$PREV" ] || [[ $PREV =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; } || die "the peer answered with an unexpected newest generation name; nothing copied" 1
# A stamp that is not newer than the newest generation (the clock went back) would be pruned at once.
if [ "$DRY" = 0 ] && [ -n "$PREV" ] && [[ ! "$TS" > "$PREV" ]]; then
  die "this run's stamp $TS is not newer than the newest generation $PREV on the peer (clock went back?); nothing copied" 1
fi

# ---- what is copied -----------------------------------------------------------------------
# Excludes first (rsync takes the first match), then the include list, then everything else out.
FILTERS=(
  --exclude='mc.env' --exclude='*.env' --exclude='.env*'
  --exclude='salvage/' --exclude='salvage'
  --exclude='.secrets' --exclude='secrets' --exclude='*.pem' --exclude='*.key'
  --exclude='tmp.*' --exclude='outbox*.jsonl' --exclude='outbox*'
  --exclude='.backup-offhost.lock*'
  --include='/ledger.json'
  --include='/ledger.bak/' --include='/ledger.bak/**'
  --include='/handovers/' --include='/handovers/**'
  --exclude='*'
)
# shellcheck disable=SC2206  # CM_BACKUP_RSYNC is a command line on purpose (tests)
RSYNC_BASE=(${CM_BACKUP_RSYNC:-rsync} -a --no-owner --no-group --timeout=120 --itemize-changes
  --files-from="$LISTF" --from0 "${FILTERS[@]}")
SRC_COPY="$SNAP"
[ -z "$DEST" ] && RSYNC_BASE+=(-e "$SSH_CMD")
TARGET_PREFIX=""; [ -z "$DEST" ] && TARGET_PREFIX="$HOST:"

if [ "$DRY" = 1 ]; then
  if [ -n "$PREV" ]; then CMP="$RDIR/$PREV"; else CMP="$RDIR/.dry-run-no-generation-yet"; fi
  printf 'dry run against %s%s (nothing is written on the peer):\n' "$TARGET_PREFIX" "$CMP"
  $TMO "${RSYNC_BASE[@]}" -n "$SRC_COPY/" "$TARGET_PREFIX$CMP/" || die "dry run failed"
  exit 0
fi

# ---- copy into a staging dir, then rename it into place ---------------------------------------
INC=".incoming-$TS"
PREP='umask 077; if [ ! -d "$1" ]; then mkdir -p "$1" || exit 1; fi; cd "$1" || exit 1
for d in .incoming-*; do [ -d "$d" ] && rm -rf "./${d:?}"; done
case "$(ls -ld . | cut -c5-10)" in ------) ;; *) echo "backup-offhost: warning: $PWD on the peer is readable by group or other (mode left as is); chmod 700 it" >&2 ;; esac
case "$(ls -ld . | cut -c11)" in +) echo "backup-offhost: warning: $PWD on the peer has an ACL (ls shows +): its mode bits do not say who can read it; run getfacl on it and remove the entries for other users" >&2 ;; esac
mkdir "$2"'
peer_sh "$PREP" "$RDIR" "$INC" || die "cannot prepare $RDIR on the peer"
LINK=()
[ -n "$PREV" ] && LINK=(--link-dest="../$PREV")
$TMO "${RSYNC_BASE[@]}" ${LINK[@]+"${LINK[@]}"} "$SRC_COPY/" "$TARGET_PREFIX$RDIR/$INC/"; rc=$?
if [ "$rc" != 0 ]; then
  die "rsync to the peer failed (exit $rc); the partial copy stays in $RDIR/$INC and is removed by the next run. Local files untouched." 1
fi

# Final checks and the swap, on the peer. Any forbidden name in the generation: remove it, exit 6.
FINISH='
cd "$1" || exit 1
inc="$2"; gen="$3"; keep="$4"; from="$5"
bad=$(find "$inc" \( -name mc.env -o -name "*.env" -o -name ".env*" -o -name salvage -o -name briefs -o -name inbox -o -name lanes -o -name "outbox*" -o -name "tmp.*" -o -name .secrets -o -name secrets -o -name "*.pem" -o -name "*.key" \) 2>/dev/null | head -n 5)
if [ -n "$bad" ]; then printf "forbidden files in the copy:\n%s\n" "$bad" >&2; rm -rf "./${inc:?}"; exit 6; fi
[ -s "$inc/ledger.json" ] || { echo "copy has no ledger.json" >&2; rm -rf "./${inc:?}"; exit 7; }
printf "generation: %s\nfrom: %s\n" "$gen" "$from" > "$inc/BACKUP-INFO"
[ ! -e "$gen" ] || { echo "generation $gen already exists" >&2; rm -rf "./${inc:?}"; exit 8; }
mv "$inc" "$gen" || exit 1
ln -sfn "$gen" latest
n=0
for g in $(ls -1 | grep -E "^[0-9]{8}T[0-9]{6}Z$" | sort -r); do
  n=$((n + 1))
  [ "$n" -gt "$keep" ] && rm -rf "./${g:?}"
done
exit 0'
FROM="$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9_.-')"
peer_sh "$FINISH" "$RDIR" "$INC" "$TS" "$KEEP" "${FROM:-unknown}"; rc=$?
case "$rc" in
  0) ;;
  6) die "a forbidden file (env, secret, salvage, briefs, inbox, lanes, outbox, tmp) reached the copy; it was removed and no generation was kept" 6 ;;
  *) die "could not finish the generation on the peer (exit $rc)" 1 ;;
esac
# The success stamp scripts/backup-stale.sh reads. Only a copy to a peer host counts: a --dest run is a local copy
# and must not vouch for the off-host one. A failed write only warns: the backup itself is done.
if [ -n "$DEST" ]; then
  printf 'backup-offhost: %s written (local-path mode: no stamp, this is not an off-host copy). Local files untouched.\n' "$RDIR/$TS"
  exit 0
fi
ok_at="$(jq -n --arg t "$TS" '$t | strptime("%Y%m%dT%H%M%SZ") | mktime' 2>/dev/null)"
case "$ok_at" in ''|*[!0-9]*) ok_at="$(date +%s)" ;; esac
STAMP="$SRC/cache/backup-offhost.json"
if mkdir -p "$SRC/cache" 2>/dev/null && STAMPT="$(mktemp "$STAMP.XXXXXX" 2>/dev/null)" \
  && jq -n --argjson t "$ok_at" --arg g "$TS" --arg h "$HOST" --arg d "$RDIR" '{ok_at:$t,generation:$g,host:$h,remote_dir:$d}' > "$STAMPT" 2>/dev/null \
  && mv -f -- "$STAMPT" "$STAMP"; then :; else
  [ -z "${STAMPT:-}" ] || rm -f -- "${STAMPT:?}"
  printf 'backup-offhost: warning: could not write %s: the stale-backup check will not see this run\n' "$STAMP" >&2
fi
printf 'backup-offhost: %s%s/%s written (kept newest %s). Local files untouched except the stamp %s.\n' "$TARGET_PREFIX" "$RDIR" "$TS" "$KEEP" "$STAMP"
exit 0
