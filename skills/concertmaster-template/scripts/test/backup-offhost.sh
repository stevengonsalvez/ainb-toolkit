#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# backup-offhost.sh (test): behaviour tests for scripts/backup-offhost.sh, the nightly off-host
# backup. Runs against temp dirs only (--dest local-path mode, and a fake ssh for the host path);
# the real ~/.concertmaster and every real peer are never touched. Covers: the include list copies
# exactly the control plane; mc.env, salvage/, *.env, secrets, tmp.*, outbox*.jsonl and unlisted
# files never copy (also when planted inside an included dir); dated generations hard-linked
# against the previous one; keep N prunes the peer only; the local tree is byte-identical after a
# run; --dry-run writes nothing; an unreachable peer exits 3 with a message; an overlapping run
# exits 5; a missing ledger and missing config are refused; config keys are read; the ssh path.
# The copied set is ledger.json, ledger.bak/ and handovers/ only (inbox/, briefs/, lanes/ never
# copy), the secret scanner runs on that exact set first (here a stub that honours the scanner's
# CLI and exit codes; the real scripts/scan-secrets.sh too when it is present; the stub never
# echoes content, so only the real-scanner block proves the scanner's own output is clean): a planted fake
# secret (built from split strings at runtime) blocks every copy and never shows in any output; a
# missing scanner or a scanner error blocks too; an unset backup.host exits 2.
#
#   scripts/test/backup-offhost.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-backup-offhost.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
for c in rsync jq yq; do command -v "$c" >/dev/null 2>&1 || { echo "missing dependency: $c" >&2; exit 1; }; done
unset CM_BACKUP_HOST CM_BACKUP_REMOTE_DIR CM_BACKUP_KEEP CM_BACKUP_SSH CM_BACKUP_NOW
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME"

# The script under test runs from a scratch copy so the scanner next to it can be a stub, absent
# or the real one. lib.sh comes along; nothing else is needed.
SD="$ROOT/skill/scripts"; mkdir -p "$SD"
cp "$HERE/../backup-offhost.sh" "$HERE/../lib.sh" "$SD/"
BK="$SD/backup-offhost.sh"
STUBLOG="$ROOT/stub-args.log"
# Stub scanner: same CLI as scan-secrets.sh (--strict, --, FILE...), same output rows, same exit
# codes (0 clean, 1 hit, 2 error). A "hit" is the marker FAKESECRET_ plus 12+ alphanumerics.
cat > "$SD/scan-secrets.sh" <<'STUBEOF'
#!/usr/bin/env bash
files=()
while [ $# -gt 0 ]; do case "$1" in --strict) ;; --) shift; files=("$@"); break ;; *) files+=("$1") ;; esac; shift; done
printf '%s\n' "${files[@]}" >> "${STUB_LOG:-/dev/null}"
[ -z "${STUB_RC:-}" ] || { printf 'SUMMARY files=%s hits=0 advisory=0 errors=1\n' "${#files[@]}"; exit "$STUB_RC"; }
hits=0
rows=""
for f in "${files[@]}"; do
  n=$(grep -aoE 'FAKESECRET_[A-Za-z0-9]{12,}' -- "$f" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && { hits=$((hits + n)); rows="${rows}FILE\t$f\ttoken_prefix\t$n\n"; }
done
printf 'token_prefix\t%s\t1\tstrict\n' "$hits"
printf "$rows"
printf 'SUMMARY files=%s hits=%s advisory=0 errors=0\n' "${#files[@]}" "$hits"
[ "$hits" -gt 0 ] && exit 1
exit 0
STUBEOF
chmod +x "$SD/scan-secrets.sh"
export STUB_LOG="$STUBLOG"
# a fake secret built at runtime from split strings: this file never holds the whole value
FAKE_SECRET="FAKE""SECRET_""a1b2c3d4e5f6g7h8"
REAL_SECRET="gh""p_""$(printf '%s%s%s' 'A1b2C3d4E5f6' 'G7h8I9j0K1l2' 'M3n4O5p6Q7r8')"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
check() { # label, want, got
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2], got [$3]"; fi
}

# seed: a CM_HOME with every kind of file the backup must take or leave.
seed() {
  rm -rf -- "${CM_HOME:?}"; mkdir -p "$CM_HOME"
  (
    cd "$CM_HOME" || exit 1
    echo '{"schema":"concertmaster.ledger/v1","workers":{}}' > ledger.json
    mkdir -p ledger.bak briefs handovers inbox lanes salvage/hostA tmp.XYZ .secrets
    echo '{"n":1}' > ledger.bak/20261001T000000Z.json
    echo brief > briefs/w-1.md
    echo 'MC_TENANT_ID=planted' > briefs/planted.env
    echo handover > handovers/w-1-h.md
    echo 'MC_TENANT_ID=planted' > handovers/planted.env
    echo note > inbox/n.md
    echo lane > lanes/l.json
    echo 'MC_TENANT_ID=acme' > mc.env
    echo salv > salvage/hostA/file
    echo t > tmp.XYZ/f
    echo k > .secrets/token
    echo line > outbox.jsonl
    echo line > outbox.dead.jsonl
    echo x > some.env
    echo d > digest.txt
    echo d > last-discover.json
    echo -----BEGIN > briefs/leaked.pem
  )
}
# the lock file and the success stamp are the only things a run writes in CM_HOME
snap() { (cd "$CM_HOME" && find . -type f ! -name '.backup-offhost.lock' ! -path './cache/backup-offhost.json' ! -path './cache/backup-offhost.json.*' -exec cksum {} + | LC_ALL=C sort); }
gens() { find "$1" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*T*Z' | LC_ALL=C sort; }
files_of() { (cd "$1" && find . -type f | LC_ALL=C sort); }

# --- the copy ------------------------------------------------------------------------------------
seed; D="$ROOT/peer1"
before="$(snap)"
out="$(CM_BACKUP_NOW=20261028T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "first run exits 0" 0 "$rc"
G="$D/20261028T030000Z"
[ -d "$G" ] && pass "a dated generation directory exists" || fail "generation dir" "$out"
want="./BACKUP-INFO
./handovers/w-1-h.md
./ledger.bak/20261001T000000Z.json
./ledger.json"
check "the generation holds exactly ledger.json, the ring and handovers" "$want" "$(files_of "$G")"
[ ! -e "$G/briefs" ] && [ ! -e "$G/inbox" ] && [ ! -e "$G/lanes" ] && pass "briefs/, inbox/ and lanes/ never copy" || fail "narrow set" "$(files_of "$G")"
[ ! -e "$G/mc.env" ] && pass "mc.env never copies" || fail "mc.env" "copied"
[ ! -e "$G/salvage" ] && pass "salvage/ never copies" || fail "salvage" "copied"
[ -z "$(find "$D" \( -name '*.env' -o -name '*.pem' -o -name 'outbox*' -o -name 'tmp.*' -o -name '.secrets' -o -name salvage \) 2>/dev/null)" ] \
  && pass "no env, key, outbox, tmp or secrets path anywhere on the peer (also planted in handovers/)" || fail "forbidden" "$(find "$D" -name '*.env' -o -name 'outbox*')"
check "local tree byte-identical after the run" "$before" "$(snap)"
[ "$(readlink "$D/latest")" = "20261028T030000Z" ] && pass "latest points at the new generation" || fail "latest" "$(readlink "$D/latest")"
perm="$(stat -c %a "$D" 2>/dev/null || stat -f %Lp "$D")"
check "peer backup root is mode 700" 700 "$perm"

# --- generations, hard links, keep N ----------------------------------------------------------------
echo '{"n":2}' > "$CM_HOME/ledger.bak/20261002T000000Z.json"
CM_BACKUP_NOW=20261029T030000Z "$BK" --dest "$D" >/dev/null 2>&1
G2="$D/20261029T030000Z"
check "second run adds a second generation" 2 "$(gens "$D" | wc -l | tr -d ' ')"
i1="$(stat -c %i "$G/handovers/w-1-h.md" 2>/dev/null || stat -f %i "$G/handovers/w-1-h.md")"
i2="$(stat -c %i "$G2/handovers/w-1-h.md" 2>/dev/null || stat -f %i "$G2/handovers/w-1-h.md")"
check "unchanged file is hard-linked against the previous generation" "$i1" "$i2"
[ -f "$G2/ledger.bak/20261002T000000Z.json" ] && [ ! -e "$G/ledger.bak/20261002T000000Z.json" ] \
  && pass "a new ring file lands in the new generation only" || fail "ring" "generation contents wrong"
before="$(snap)"
for day in 20261030 20261031 20261101 20261102; do
  CM_BACKUP_NOW="${day}T030000Z" "$BK" --dest "$D" --keep 3 >/dev/null 2>&1
done
check "keep 3 leaves three generations" 3 "$(gens "$D" | wc -l | tr -d ' ')"
check "the newest generations are the ones kept" "20261031T030000Z 20261101T030000Z 20261102T030000Z" "$(gens "$D" | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//')"
check "pruning never touches the local tree" "$before" "$(snap)"
[ -s "$D/20261102T030000Z/ledger.json" ] && pass "the kept generation is complete (ledger.json non-empty)" || fail "kept generation" "ledger.json missing"

# --- refusals -----------------------------------------------------------------------------------------
seed; D="$ROOT/peer2"
rm -f "$CM_HOME/ledger.json"
out="$("$BK" --dest "$D" 2>&1)"; rc=$?
check "missing ledger is refused (exit 1)" 1 "$rc"
[ ! -e "$D" ] && pass "nothing is created on the peer for a missing ledger" || fail "refusal" "peer dir created"
: > "$CM_HOME/ledger.json"
"$BK" --dest "$D" >/dev/null 2>&1; rc=$?
check "an empty ledger is refused too" 1 "$rc"

seed
out="$("$BK" 2>&1)"; rc=$?
check "no host configured: exit 2" 2 "$rc"
case "$out" in *"backup.host is not set: the owner chooses the target host"*) pass "the message says the owner chooses the host" ;; *) fail "message" "$out" ;; esac
out="$("$BK" --remote-dir bk 2>&1)"; rc=$?
check "a remote dir but no host: still exit 2, no default host" 2 "$rc"
printf 'backup:\n  host: ""\n  remote_dir: bk\n' > "$ROOT/host-empty.yaml"
out="$(CM_CONFIG="$ROOT/host-empty.yaml" "$BK" 2>&1)"; rc=$?
check "backup.host: \"\" in the config exits 2" 2 "$rc"
case "$out" in *"backup.host is not set"*) pass "an empty host in the config gives the same message" ;; *) fail "empty host" "$out" ;; esac
out="$("$BK" --host h 2>&1)"; rc=$?
check "a host but no remote dir exits 2" 2 "$rc"
case "$out" in *backup.remote_dir*) pass "the message names backup.remote_dir" ;; *) fail "message" "$out" ;; esac
out="$("$BK" --remote-dir 'a b' --host h 2>&1)"; rc=$?
check "a remote dir with a space is refused" 2 "$rc"
out="$("$BK" --remote-dir ../x --host h 2>&1)"; rc=$?
check "a remote dir with .. is refused" 2 "$rc"
out="$("$BK" --dest "$ROOT/p" --keep 0 2>&1)"; rc=$?
check "keep 0 is refused" 2 "$rc"

# --- unreachable peer ---------------------------------------------------------------------------------
seed; before="$(snap)"
out="$(CM_BACKUP_SSH=false "$BK" --host some-peer --remote-dir bk 2>&1)"; rc=$?
check "unreachable peer exits 3" 3 "$rc"
case "$out" in *"some-peer"*unreachable*|*unreachable*"some-peer"*) pass "the message names the peer and says unreachable" ;; *) fail "message" "$out" ;; esac
check "local tree untouched after an unreachable peer" "$before" "$(snap)"

# --- --check: the config and the peer, nothing written ------------------------------------------------
# A fake ssh on PATH records what the script gives it, so the DEFAULT command line (no CM_BACKUP_SSH) is
# what is tested: BatchMode, so a host that wants a password fails at once instead of hanging under cron.
mkdir -p "$ROOT/cronbin" "$ROOT/emptycm"
cat > "$ROOT/cronbin/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
while [ "$1" = "-o" ]; do shift 2; done
shift
[ -n "$SSH_FAIL" ] && { echo "Permission denied (publickey)." >&2; exit 255; }
[ "$*" = "true" ] && exit 0
exec sh -c "$*"
EOF
chmod +x "$ROOT/cronbin/ssh"
for c in yq jq rsync; do ln -sf "$(command -v "$c")" "$ROOT/cronbin/$c"; done
export SSH_LOG="$ROOT/ssh.log" SSH_FAIL=""
mkdir -p "$ROOT/peer-chk/20261026T030000Z" "$ROOT/peer-chk/20261027T030000Z"
: > "$SSH_LOG"
out="$(PATH="$ROOT/cronbin:$PATH" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir "$ROOT/peer-chk" 2>&1)"; rc=$?
check "--check with a reachable peer exits 0, with no ledger needed" 0 "$rc"
case "$out" in "peer-ok: peerx"*"newest generation: 20261027T030000Z"*) pass "--check prints peer-ok, the dir and the newest generation" ;; *) fail "check output" "$out" ;; esac
case "$(cat "$SSH_LOG")" in *"-o BatchMode=yes"*"-o ConnectTimeout=10"*peerx*) pass "the default ssh line is BatchMode with a connect timeout" ;; *) fail "ssh line" "$(cat "$SSH_LOG")" ;; esac
check "--check writes nothing in CM_HOME (no lock file either)" "" "$(ls -A "$ROOT/emptycm")"
out="$(PATH="$ROOT/cronbin:$PATH" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir "$ROOT/peer-none" 2>&1)"
case "$out" in *"newest generation: none yet"*) pass "--check says so when the peer has no generation yet" ;; *) fail "check none" "$out" ;; esac
[ ! -e "$ROOT/peer-none" ] && pass "--check does not create the remote dir" || fail "check" "remote dir created"
SSH_FAIL=1 out="$(PATH="$ROOT/cronbin:$PATH" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir bk 2>&1)"; rc=$?
check "--check with an unreachable peer exits 3" 3 "$rc"
case "$out" in *"peerx"*"unreachable"*"Permission denied"*) pass "the ssh error is shown" ;; *) fail "check unreachable" "$out" ;; esac
# ssh true succeeds, the listing connection fails: that is not "no generation yet"
cat > "$ROOT/cronbin/ssh-listfail" <<'EOF'
#!/bin/sh
while [ "$1" = "-o" ]; do shift 2; done
shift
[ "$*" = "true" ] && exit 0
echo "Connection reset by peer" >&2; exit 255
EOF
chmod +x "$ROOT/cronbin/ssh-listfail"
out="$(CM_BACKUP_SSH="$ROOT/cronbin/ssh-listfail" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir bk 2>&1)"; rc=$?
check "--check exits 3 when the listing fails after ssh true worked" 3 "$rc"
case "$out" in *"peer-ok"*) fail "check listing" "printed peer-ok: $out" ;; *"listing"*"failed"*"Connection reset"*) pass "and says the listing failed, with the ssh error" ;; *) fail "check listing" "$out" ;; esac
# ssh's own notices stay out of the result: stderr is not part of the listing
cat > "$ROOT/cronbin/ssh-noisy" <<'EOF'
#!/bin/sh
while [ "$1" = "-o" ]; do shift 2; done
shift
[ "$*" = "true" ] && exit 0
echo "Warning: Permanently added 'peerx' (ED25519) to the list of known hosts." >&2
printf '%s\n' "${NOISY_LINE:-20261101T030000Z}"
EOF
chmod +x "$ROOT/cronbin/ssh-noisy"
out="$(CM_BACKUP_SSH="$ROOT/cronbin/ssh-noisy" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir bk 2>&1)"; rc=$?
check "--check: a known_hosts notice on stderr is not the newest generation" "peer-ok: peerx, remote dir bk, newest generation: 20261101T030000Z" "$out"
out="$(NOISY_LINE="$(printf 'hello\033[31m red')" CM_BACKUP_SSH="$ROOT/cronbin/ssh-noisy" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir bk 2>&1)"
case "$out" in *"(unreadable: hello"*) pass "--check: a last line that is not a generation name is shown as unreadable, control bytes replaced" ;; *) fail "unreadable line" "$out" ;; esac
case "$out" in *$'\033'*) fail "control bytes" "an escape byte reached the output" ;; *) pass "and no escape byte reaches the terminal" ;; esac
# --check leaves no temp file behind, on success or on a failed listing
TDC="$ROOT/tdcheck"; mkdir -p "$TDC"
TMPDIR="$TDC" CM_BACKUP_SSH="$ROOT/cronbin/ssh-noisy" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir bk >/dev/null 2>&1
TMPDIR="$TDC" CM_BACKUP_SSH="$ROOT/cronbin/ssh-listfail" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir bk >/dev/null 2>&1
check "--check leaves nothing in TMPDIR after a good listing and after a failed one" "" "$(ls -A "$TDC")"
out="$(CM_HOME="$ROOT/emptycm" "$BK" --check 2>&1)"; rc=$?
check "--check with no host configured exits 2" 2 "$rc"
out="$("$BK" --check --dest "$ROOT/peer-chk" 2>&1)"; rc=$?
check "--check in local-path mode has no ssh to test (exit 0)" 0 "$rc"
# cron's environment: nothing but the PATH of the crontab line. Without yq the config cannot be read.
# (run only when yq is really missing from that PATH: with yq present this would reach the real ssh)
if ! PATH=/usr/bin:/bin command -v yq >/dev/null 2>&1; then
  out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin CM_CONFIG="$CM_CONFIG" "$BK" --check --host peerx --remote-dir bk 2>&1)"; rc=$?
  check "--check under env -i with no yq on PATH exits 2" 2 "$rc"
  case "$out" in *"yq is not on PATH"*) pass "and says that yq is the problem" ;; *) fail "cron env" "$out" ;; esac
fi
out="$(env -i HOME="$HOME" PATH="$ROOT/cronbin:/usr/bin:/bin" CM_CONFIG="$CM_CONFIG" SSH_LOG="$SSH_LOG" SSH_FAIL="" CM_HOME="$ROOT/emptycm" "$BK" --check --host peerx --remote-dir "$ROOT/peer-chk" 2>&1)"; rc=$?
check "--check under env -i with yq, jq, rsync and ssh on PATH exits 0" 0 "$rc"

# --- the documented install steps and cron line --------------------------------------------------
DOC="$HERE/../../references/recovery.md"; 
cron="$(grep -E '^[0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ PATH=' "$DOC")"
check "recovery.md holds exactly one crontab line" 1 "$(printf '%s\n' "$cron" | grep -c .)"
cron_re='^[0-9*/,-]+ [0-9*/,-]+ \* \* \* PATH=([^ ]+) ([^ ]+/scripts/backup-offhost\.sh) >> ([^ ]+) 2>&1$'
if [[ $cron =~ $cron_re ]]; then
  cpath="${BASH_REMATCH[1]}"; cscript="${BASH_REMATCH[2]}"; clog="${BASH_REMATCH[3]}"
  pass "the crontab line is: schedule, PATH=, the script, then a log with stderr"
  case ":$cpath:" in *:/usr/bin:*) case ":$cpath:" in *:/bin:*) pass "the cron PATH holds /usr/bin and /bin (rsync, ssh, jq)" ;; *) fail "cron PATH" "no /bin in $cpath" ;; esac ;; *) fail "cron PATH" "no /usr/bin in $cpath" ;; esac
  case "$cscript" in /*) pass "the script path is absolute" ;; *) fail "cron script" "$cscript" ;; esac
  case "$cscript" in */scripts/backup-offhost.sh) pass "the script path ends in the skill's scripts/backup-offhost.sh" ;; *) fail "cron script" "$cscript" ;; esac
  [ -f "$HERE/../backup-offhost.sh" ] && pass "the script the line names exists in this checkout" || fail "cron script" "missing"
  case "$clog" in /*) pass "the log path is absolute" ;; *) fail "cron log" "$clog" ;; esac
else
  fail "crontab line shape" "$cron"
fi
for want in 'backup-offhost.sh --check' 'backup-offhost.sh --dry-run' 'env -i'; do
  grep -qF -- "$want" "$DOC" && pass "recovery.md names: $want" || fail "recovery.md" "missing: $want"
done
"$BK" --help 2>&1 | grep -q -- '--check' && pass "--help documents --check" || fail "help" "no --check"

# --- dry run ------------------------------------------------------------------------------------------
seed; D="$ROOT/peer3"
out="$("$BK" --dest "$D" --dry-run 2>&1)"; rc=$?
check "dry run exits 0" 0 "$rc"
[ ! -e "$D" ] && pass "dry run creates nothing on the peer (first backup)" || fail "dry run" "peer dir created: $(find "$D" | head -3)"
case "$out" in *ledger.json*) pass "dry run lists ledger.json" ;; *) fail "dry run list" "$out" ;; esac
case "$out" in *mc.env*|*salvage*) fail "dry run list" "mentions an excluded path: $out" ;; *) pass "dry run never lists mc.env or salvage" ;; esac
CM_BACKUP_NOW=20261028T030000Z "$BK" --dest "$D" >/dev/null 2>&1
echo changed >> "$CM_HOME/handovers/w-1-h.md"
n1="$(gens "$D" | wc -l | tr -d ' ')"
out="$("$BK" --dest "$D" --dry-run 2>&1)"
case "$out" in *handovers/w-1-h.md*) pass "dry run shows the file that would change" ;; *) fail "dry run diff" "$out" ;; esac
check "dry run adds no generation" "$n1" "$(gens "$D" | wc -l | tr -d ' ')"

# --- overlapping runs -----------------------------------------------------------------------------------
if command -v flock >/dev/null 2>&1; then
  seed; D="$ROOT/peer4"
  flock "$CM_HOME/.backup-offhost.lock" -c 'sleep 4' & holder=$!
  sleep 1
  out="$("$BK" --dest "$D" 2>&1)"; rc=$?
  check "an overlapping run exits 5" 5 "$rc"
  case "$out" in *"holds"*) pass "the message says a run holds the lock" ;; *) fail "lock message" "$out" ;; esac
  [ ! -e "$D" ] && pass "the skipped run wrote nothing" || fail "lock" "peer dir created"
  wait "$holder" 2>/dev/null
  "$BK" --dest "$D" >/dev/null 2>&1; rc=$?
  check "the lock is free once the holder exits" 0 "$rc"
fi

# --- the ssh path, with a fake ssh and config keys ------------------------------------------------------
FAKE="$ROOT/fake-ssh"
cat > "$FAKE" <<'EOF'
#!/bin/sh
# fake ssh: drop the host (and any -o options), run the rest locally
while [ "$1" = "-o" ]; do shift 2; done
shift
exec sh -c "$*"
EOF
chmod +x "$FAKE"
seed; P="$ROOT/peer-home"; mkdir -p "$P"
CFG="$ROOT/config.yaml"
printf 'backup:\n  host: peerx\n  remote_dir: %s/bk\n  keep: 2\n' "$P" > "$CFG"
for s in 1 2 3; do
  CM_CONFIG="$CFG" CM_BACKUP_SSH="$FAKE" CM_BACKUP_NOW="2026110${s}T030000Z" "$BK" >/dev/null 2>&1; rc=$?
done
check "host mode runs through the ssh command with host, dir and keep from config" 0 "$rc"
check "config keep 2 is honoured over ssh" 2 "$(gens "$P/bk" | wc -l | tr -d ' ')"
[ -s "$P/bk/latest/ledger.json" ] && [ ! -e "$P/bk/latest/mc.env" ] && [ ! -e "$P/bk/latest/salvage" ] \
  && pass "over ssh: ledger copied, mc.env and salvage not" || fail "ssh copy" "$(files_of "$P/bk/latest")"
out="$(CM_CONFIG="$CFG" CM_BACKUP_SSH="$FAKE" CM_BACKUP_NOW=20261104T030000Z "$BK" --remote-dir "$P/other" 2>&1)"
[ -s "$P/other/latest/ledger.json" ] && pass "--remote-dir beats the config value" || fail "flag beats config" "$out"

# --- third wall: a forbidden file that reaches the copy anyway removes the copy ---------------------
seed; D="$ROOT/peer5"; WRAP="$ROOT/rsync-plant"
cat > "$WRAP" <<'EOF'
#!/bin/sh
# real rsync, then plant an env file in the destination (the last argument)
rsync "$@"; rc=$?
for last; do :; done
case "$last" in *:*) ;; *) echo planted > "${last%/}/mc.env" ;; esac
exit $rc
EOF
chmod +x "$WRAP"
out="$(CM_BACKUP_RSYNC="$WRAP" CM_BACKUP_NOW=20261028T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a forbidden file in the copy exits 6" 6 "$rc"
check "no generation is kept after a forbidden file" 0 "$(gens "$D" | wc -l | tr -d ' ')"
[ -z "$(find "$D" -name mc.env 2>/dev/null)" ] && pass "the planted mc.env is gone from the peer" || fail "planted" "still there"

# --- review findings ------------------------------------------------------------------------------
# cron's PATH has no yq: the config cannot be read, and the message says why (exit 2).
seed
out="$(env -i HOME="$HOME" CM_HOME="$CM_HOME" CM_CONFIG="$CFG" CM_BACKUP_SSH=/bin/false PATH=/usr/bin:/bin /bin/bash "$BK" 2>&1)"; rc=$?
if command -v yq >/dev/null 2>&1 && ! PATH=/usr/bin:/bin command -v yq >/dev/null 2>&1; then
  check "no yq on PATH: exit 2" 2 "$rc"
  case "$out" in *"yq is not on PATH"*) pass "the message names yq and PATH" ;; *) fail "yq message" "$out" ;; esac
  out="$(env -i HOME="$HOME" CM_HOME="$CM_HOME" CM_CONFIG="$CFG" CM_BACKUP_SSH=/bin/false PATH=/usr/bin:/bin /bin/bash "$BK" --remote-dir bk 2>&1)"; rc=$?
  check "no yq on PATH with --remote-dir given: still exit 2, not a misleading host message" 2 "$rc"
  case "$out" in *"yq is not on PATH"*) pass "the yq message wins when the config cannot be read" ;; *) fail "yq with remote-dir" "$out" ;; esac
fi
# remote dir and host values that would escape the backup root
# shellcheck disable=SC2088  # a literal tilde is the point
for bad in - -x '~' '~/x' 'a:b' 'a=b' '/' '.' '..' 'a/../b'; do
  "$BK" --remote-dir "$bad" --host h >/dev/null 2>&1; rc=$?
  check "remote dir [$bad] is refused" 2 "$rc"
done
"$BK" --remote-dir ok --host -oProxyCommand=x >/dev/null 2>&1; rc=$?
check "a host starting with - is refused" 2 "$rc"
# a peer directory that cannot be entered: the run fails (exit 1) and leaves nothing behind in the cwd
seed; RO="$ROOT/ro"; mkdir -p "$RO"; chmod 500 "$RO"
WORK="$ROOT/cwd"; mkdir -p "$WORK"
( cd "$WORK" && "$BK" --dest "$RO/sub" >/dev/null 2>&1 ); rc=$?
chmod 700 "$RO"
if [ "$(id -u)" != 0 ]; then
  check "an unusable peer directory fails with exit 1" 1 "$rc"
  [ -z "$(find "$WORK" -mindepth 1 2>/dev/null)" ] && pass "nothing is staged in the working directory" || fail "stray staging" "$(find "$WORK" -mindepth 1)"
fi
# clock went back: a stamp older than the newest generation is refused, nothing is pruned
seed; D="$ROOT/peer6"
CM_BACKUP_NOW=20261105T030000Z "$BK" --dest "$D" >/dev/null 2>&1
out="$(CM_BACKUP_NOW=20261104T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a stamp older than the newest generation exits 1" 1 "$rc"
case "$out" in *"not newer"*) pass "the message says the stamp is not newer" ;; *) fail "clock message" "$out" ;; esac
check "the newest generation survives" 1 "$(gens "$D" | wc -l | tr -d ' ')"
# a relative remote dir over ssh (relative to the peer's home) and the exit code stays out of the message
seed; cd "$P" || exit 1
CM_BACKUP_SSH="$FAKE" CM_BACKUP_NOW=20261106T030000Z "$BK" --host peerx --remote-dir rel/bk >/dev/null 2>&1; rc=$?
check "a relative remote dir works over ssh" 0 "$rc"
[ -s "$P/rel/bk/latest/ledger.json" ] && pass "the relative dir lands under the peer's cwd/home" || fail "relative dir" "$(find "$P" -maxdepth 3 | head)"
out="$(CM_BACKUP_SSH=false "$BK" --host some-peer --remote-dir bk 2>&1)"
case "$out" in *"left untouched. 3"*|*"untouched.  3"*|*". 3") fail "exit code leaked into the message" "$out" ;; *) pass "the error message does not end with the exit code" ;; esac
cd "$HERE" || exit 1

# a remote dir or host holding a newline must not smuggle a second command to the peer
seed; INJ="$ROOT/INJECTED"
"$BK" --remote-dir "$ROOT/bk-nl
touch $INJ" --host peerx >/dev/null 2>&1; rc=$?
check "a remote dir with a newline is refused" 2 "$rc"
CM_BACKUP_SSH="$FAKE" "$BK" --remote-dir "$ROOT/bk-nl2
touch $INJ" --host peerx >/dev/null 2>&1
[ ! -e "$INJ" ] && pass "nothing ran on the peer from a newline in the remote dir" || fail "injection" "INJECTED was created"
# BACKUP-INFO names the source host without stray characters
seed; D="$ROOT/peer7"
CM_BACKUP_NOW=20261107T030000Z "$BK" --dest "$D" >/dev/null 2>&1
want_from="$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9_.-')"
check "BACKUP-INFO names the source host" "from: ${want_from:-unknown}" "$(grep '^from:' "$D/20261107T030000Z/BACKUP-INFO")"
# the transfer reads a stable snapshot, so ANY non-zero rsync exit (24 included) fails the run
seed; D="$ROOT/peer8"; W24="$ROOT/rsync-24"
printf '#!/bin/sh\nrsync "$@"; exit 24\n' > "$W24"; chmod +x "$W24"
CM_BACKUP_RSYNC="$W24" CM_BACKUP_NOW=20261108T030000Z "$BK" --dest "$D" >/dev/null 2>&1; rc=$?
check "rsync exit 24 on the transfer fails the run (the source is a snapshot)" 1 "$rc"
[ ! -e "$D/20261108T030000Z" ] && pass "no generation is published after exit 24" || fail "exit 24" "generation exists"
W23="$ROOT/rsync-23"; printf '#!/bin/sh\nexit 23\n' > "$W23"; chmod +x "$W23"
CM_BACKUP_RSYNC="$W23" CM_BACKUP_NOW=20261109T030000Z "$BK" --dest "$D" >/dev/null 2>&1; rc=$?
check "rsync exit 23 fails the run (exit 1)" 1 "$rc"
[ ! -e "$D/20261109T030000Z" ] && pass "no generation is published after a failed rsync" || fail "exit 23" "generation exists"

# --- the secret scan: runs first, on the exact set, and blocks every copy --------------------------
seed; D="$ROOT/peer9"; : > "$STUBLOG"
CM_BACKUP_NOW=20261110T030000Z "$BK" --dest "$D" >/dev/null 2>&1; rc=$?
check "clean set: scan passes and the copy is made" 0 "$rc"
sorted="$(sed 's#^/.*/cm-backup-snap\.[^/]*/##' "$STUBLOG" | LC_ALL=C sort | tr '\n' ' ')"
check "the scanner got exactly ledger.json, the ring and handovers (from the snapshot, not the live tree)" "handovers/w-1-h.md ledger.bak/20261001T000000Z.json ledger.json " "$sorted"
for where in ledger.json ledger.bak/20261001T000000Z.json handovers/w-1-h.md handovers/new.md; do
  seed; D="$ROOT/peer-scan"; rm -rf -- "${D:?}"
  printf 'line one\ntoken %s\n' "$FAKE_SECRET" >> "$CM_HOME/$where"
  before="$(snap)"
  out="$(CM_BACKUP_NOW=20261111T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
  check "a planted secret in $where blocks the copy (exit 4)" 4 "$rc"
  [ ! -e "$D" ] && pass "nothing was created on the peer ($where)" || fail "blocked copy" "peer dir exists: $(find "$D" | head -3)"
  case "$out" in *"$FAKE_SECRET"*|*"${FAKE_SECRET#FAKESECRET_}"*) fail "secret in output ($where)" "the output holds the secret" ;; *) pass "the output never contains the secret ($where)" ;; esac
  case "$out" in *"refused the copy"*"token_prefix: 1"*) pass "the output reports the refusal with the class count ($where)" ;; *) fail "refusal message" "$out" ;; esac
  check "local tree untouched after a blocked copy ($where)" "$before" "$(snap)"
done
# the scan reads a snapshot and the snapshot is what is sent: a token appended to the source AFTER
# the scan (here: by the rsync wrapper, just before the transfer) never reaches the peer
seed; D="$ROOT/peer-toctou"; WT="$ROOT/rsync-toctou"
# shellcheck disable=SC2016  # the wrapper script expands $CM_HOME and "$@" itself
printf '#!/bin/sh\nprintf "late %%s\\n" "%s" >> "$CM_HOME/handovers/w-1-h.md"\nexec rsync "$@"\n' "$FAKE_SECRET" > "$WT"; chmod +x "$WT"
out="$(CM_BACKUP_RSYNC="$WT" CM_BACKUP_NOW=20261114T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a token appended after the scan: the run still exits 0 (the snapshot was clean)" 0 "$rc"
grep -q -- "${FAKE_SECRET#FAKESECRET_}" "$CM_HOME/handovers/w-1-h.md" && pass "the wrapper really changed the source after the scan" || fail "toctou setup" "source unchanged"
! grep -rq -- "${FAKE_SECRET#FAKESECRET_}" "$D" 2>/dev/null && pass "the late token never reaches the peer" || fail "toctou leak" "found on the peer"
# a planted secret blocks a dry run too, and the same over the ssh path
seed; D="$ROOT/peer-scan2"; printf 'x %s\n' "$FAKE_SECRET" >> "$CM_HOME/handovers/w-1-h.md"
"$BK" --dest "$D" --dry-run >/dev/null 2>&1; rc=$?
check "a planted secret blocks a dry run (exit 4)" 4 "$rc"
CM_BACKUP_SSH="$FAKE" "$BK" --host peerx --remote-dir "$ROOT/peer-scan3" >/dev/null 2>&1; rc=$?
check "a planted secret blocks the ssh path (exit 4)" 4 "$rc"
[ ! -e "$ROOT/peer-scan3" ] && pass "nothing was created on the peer over ssh" || fail "ssh blocked" "dir exists"
# a secret outside the copied set (inbox/, briefs/) is neither scanned nor copied
seed; D="$ROOT/peer-scan4"; printf 'x %s\n' "$FAKE_SECRET" > "$CM_HOME/inbox/pasted.md"; printf 'x %s\n' "$FAKE_SECRET" > "$CM_HOME/briefs/b.md"
CM_BACKUP_NOW=20261112T030000Z "$BK" --dest "$D" >/dev/null 2>&1; rc=$?
check "a secret in inbox/ and briefs/ does not block (they are not in the set)" 0 "$rc"
! grep -rq -- "${FAKE_SECRET#FAKESECRET_}" "$D" 2>/dev/null && pass "the secret in inbox/ and briefs/ never reaches the peer" || fail "leak" "found on the peer"
# a scanner error (exit 2) refuses; a missing scanner refuses
seed; D="$ROOT/peer-scan5"
STUB_RC=2 "$BK" --dest "$D" >/dev/null 2>&1; rc=$?
check "a scanner error refuses the copy (exit 4)" 4 "$rc"
[ ! -e "$D" ] && pass "nothing was created after a scanner error" || fail "scanner error" "dir exists"
SD2="$ROOT/noscan/scripts"; mkdir -p "$SD2"; cp "$SD/backup-offhost.sh" "$SD/lib.sh" "$SD2/"
out="$("$SD2/backup-offhost.sh" --dest "$D" 2>&1)"; rc=$?
check "a missing scanner refuses the copy (exit 4)" 4 "$rc"
case "$out" in *"scanner not found"*"refuses to run without it"*) pass "the message names the scanner and says the backup refuses to run without it" ;; *) fail "missing scanner message" "$out" ;; esac
[ ! -e "$D" ] && pass "nothing was created without a scanner" || fail "no scanner" "dir exists"
# the real scanner, when this tree has it (it ships next to the script): same cases against the real thing
if [ -f "$HERE/../scan-secrets.sh" ]; then
  SD3="$ROOT/realscan/scripts"; mkdir -p "$SD3"; cp "$SD/backup-offhost.sh" "$SD/lib.sh" "$HERE/../scan-secrets.sh" "$SD3/"
  seed; D="$ROOT/peer-real1"
  CM_BACKUP_NOW=20261113T030000Z "$SD3/backup-offhost.sh" --dest "$D" >/dev/null 2>&1; rc=$?
  check "real scanner: a clean set copies" 0 "$rc"
  seed; D="$ROOT/peer-real2"; printf 'token %s\n' "$REAL_SECRET" >> "$CM_HOME/handovers/w-1-h.md"
  out="$("$SD3/backup-offhost.sh" --dest "$D" 2>&1)"; rc=$?
  check "real scanner: a planted token blocks the copy (exit 4)" 4 "$rc"
  case "$out" in *"$REAL_SECRET"*) fail "real scanner output" "the output holds the secret" ;; *) pass "real scanner: the output never contains the secret" ;; esac
  [ ! -e "$D" ] && pass "real scanner: nothing was created on the peer" || fail "real scanner" "dir exists"
else
  printf 'SKIP real scanner cases: %s not present\n' "$HERE/../scan-secrets.sh"
fi

# --- hardening: existing remote dir, dry run over ssh, symlinked handovers, refusal paths ---------------
# a remote dir that already exists keeps its mode (it may be shared; only a warning), generations are 700
seed; D="$ROOT/peer-existing"; mkdir -p "$D"; chmod 755 "$D"
out="$(CM_BACKUP_NOW=20261115T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "an existing remote dir: the run succeeds" 0 "$rc"
check "an existing 755 remote dir is left at 755" 755 "$(stat -c %a "$D" 2>/dev/null || stat -f %Lp "$D")"
case "$out" in *"readable by group or other"*) pass "an existing 755 remote dir draws a warning" ;; *) fail "mode warning" "$out" ;; esac
check "its generation directory is 700" 700 "$(stat -c %a "$D/20261115T030000Z" 2>/dev/null || stat -f %Lp "$D/20261115T030000Z")"
# a remote dir that is a symlink to a shared directory: the target's mode is never changed
seed; SH="$ROOT/shared"; mkdir -p "$SH"; chmod 755 "$SH"; ln -s "$SH" "$ROOT/bk-link"
CM_BACKUP_NOW=20261117T030000Z "$BK" --dest "$ROOT/bk-link" >/dev/null 2>&1; rc=$?
check "a symlinked remote dir: the run succeeds" 0 "$rc"
check "the symlink target's mode is not changed" 755 "$(stat -c %a "$SH" 2>/dev/null || stat -f %Lp "$SH")"
# a dry run over ssh writes nothing on the peer
seed; PD="$ROOT/peer-dry-ssh"
out="$(CM_BACKUP_SSH="$FAKE" "$BK" --host peerx --remote-dir "$PD" --dry-run 2>&1)"; rc=$?
check "dry run over ssh exits 0" 0 "$rc"
[ ! -e "$PD" ] && pass "dry run over ssh creates nothing on the peer" || fail "dry run ssh" "peer dir created"
case "$out" in *ledger.json*) pass "dry run over ssh lists ledger.json" ;; *) fail "dry run ssh list" "$out" ;; esac
# a symlinked handovers/ is reported on stderr and left out; the ledger still backs up
seed; D="$ROOT/peer-symlink"; mv "$CM_HOME/handovers" "$ROOT/real-handovers"; ln -s "$ROOT/real-handovers" "$CM_HOME/handovers"
: > "$STUBLOG"
out="$(CM_BACKUP_NOW=20261116T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a symlinked handovers/ does not fail the run" 0 "$rc"
case "$out" in *"handovers is a symlink"*) pass "the symlinked handovers/ is reported" ;; *) fail "symlink warning" "$out" ;; esac
! grep -q -- "/handovers\$" "$STUBLOG" && pass "the scanner is not handed the symlinked handovers/" || fail "symlink scan" "scanner got the link"
[ -s "$D/20261116T030000Z/ledger.json" ] && [ ! -e "$D/20261116T030000Z/handovers" ] && pass "ledger copied, symlinked handovers/ left out" || fail "symlink copy" "$(files_of "$D/20261116T030000Z")"
# the refusal names files relative to CM_HOME, not the snapshot that is already deleted
seed; D="$ROOT/peer-names"; printf 'x %s\n' "$FAKE_SECRET" >> "$CM_HOME/handovers/w-1-h.md"
out="$("$BK" --dest "$D" 2>&1)"; rc=$?
case "$out" in *"cm-backup-snap"*) fail "refusal paths" "names the deleted snapshot: $out" ;; *"handovers/w-1-h.md"*) pass "the refusal names the file relative to CM_HOME" ;; *) fail "refusal paths" "$out" ;; esac

# --- pr-sweeper review: nested forbidden names, junk generation names, scanner errors ----------------------
# --help prints the whole header, through the exit codes
out="$("$BK" --help 2>&1)"
case "$out" in *"Exit: 0 done"*"reached the generation"*) pass "--help prints the header through the exit codes" ;; *) fail "--help" "$out" ;; esac
# a name with glob characters is not expanded against the cwd (only a real forbidden name is skipped)
seed; D="$ROOT/peer-glob"; mkdir -p "$CM_HOME/handovers/inbox-notes" "$CM_HOME/handovers/inbo?"
echo ok > "$CM_HOME/handovers/inbox-notes/a.md"; echo ok > "$CM_HOME/handovers/inbo?/b.md"
out="$(cd "$CM_HOME" && CM_BACKUP_NOW=20261119T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "glob characters in names: the run succeeds" 0 "$rc"
[ -s "$D/20261119T030000Z/handovers/inbox-notes/a.md" ] && [ -s "$D/20261119T030000Z/handovers/inbo?/b.md" ] \
  && pass "names that only look like a forbidden name through a glob are copied" || fail "glob names" "$out"
# a forbidden name nested inside handovers/ is left out and named; the run succeeds (no exit 6 every night)
seed; D="$ROOT/peer-nested"; mkdir -p "$CM_HOME/handovers/inbox" "$CM_HOME/handovers/sub"
echo "x" > "$CM_HOME/handovers/inbox/creds.txt"; echo "x" > "$CM_HOME/handovers/sub/notes.pem"; echo ok > "$CM_HOME/handovers/sub/fine.md"
out="$(CM_BACKUP_NOW=20261120T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a nested inbox/ and a .pem inside handovers/: the run still succeeds" 0 "$rc"
case "$out" in *"forbidden name): handovers/inbox/creds.txt"*) pass "the nested inbox file is named on stderr" ;; *) fail "nested warning" "$out" ;; esac
G="$D/20261120T030000Z"
[ ! -e "$G/handovers/inbox" ] && [ ! -e "$G/handovers/sub/notes.pem" ] && [ -s "$G/handovers/sub/fine.md" ] \
  && pass "forbidden nested names are not copied, the rest of handovers/ is" || fail "nested copy" "$(files_of "$G")"
# the scanner is never handed a forbidden nested name
! grep -q "creds.txt" "$STUBLOG" && pass "the scanner is not handed the nested forbidden file" || fail "nested scan" "scanner got creds.txt"
# a dangling symlink and a name with a newline are left out and named, not a silent exit 4
seed; D="$ROOT/peer-odd"; ln -s /nonexistent-target "$CM_HOME/handovers/dangling.md"
printf 'x\n' > "$CM_HOME/handovers/$(printf 'two\nlines.md')"
out="$(CM_BACKUP_NOW=20261121T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a dangling symlink and a newline name: the run succeeds" 0 "$rc"
case "$out" in *"dangling symlink): handovers/dangling.md"*) pass "the dangling symlink is named" ;; *) fail "dangling warning" "$out" ;; esac
case "$out" in *"name has a newline): handovers/two?lines.md"*) pass "the newline name is named, newline shown as ?" ;; *) fail "newline warning" "$out" ;; esac
# the scanner's own error lines are shown (cleaned, snapshot prefix stripped), still no match values
seed; D="$ROOT/peer-scanerr"
mkdir -p "$ROOT/skill-err/scripts"; cp "$BK" "$SD/lib.sh" "$ROOT/skill-err/scripts/"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "cannot read %%s\\n" "$(echo "$@" | tr " " "\\n" | tail -n 1)" >&2\nprintf "SUMMARY files=1 hits=0 advisory=0 errors=1\\n"\nexit 2\n' > "$ROOT/skill-err/scripts/scan-secrets.sh"
out="$("$ROOT/skill-err/scripts/backup-offhost.sh" --dest "$D" 2>&1)"; rc=$?
check "scanner exit 2 still refuses (exit 4)" 4 "$rc"
case "$out" in *"scanner: cannot read "*) pass "the scanner's error line is shown" ;; *) fail "scanner stderr" "$out" ;; esac
case "$out" in *cm-backup-snap*) fail "scanner stderr" "snapshot path leaked: $out" ;; *) pass "the snapshot prefix is stripped from the scanner's error line" ;; esac
# a peer that answers the generation listing with junk never reaches rsync's --link-dest
seed; D="$ROOT/peer-junk"; : > "$STUBLOG"
JUNK="$ROOT/junk-ssh"; cat > "$JUNK" <<'EOF'
#!/bin/sh
while [ "$1" = "-o" ]; do shift 2; done
shift
case "$*" in *"ls -1"*) echo "../../..; touch /tmp/never"; exit 0 ;; esac
exec sh -c "$*"
EOF
chmod +x "$JUNK"
out="$(CM_BACKUP_SSH="$JUNK" CM_BACKUP_NOW=20261122T030000Z "$BK" --host peerx --remote-dir "$D" 2>&1)"; rc=$?
check "a junk newest-generation answer from the peer fails the run (exit 1)" 1 "$rc"
case "$out" in *"unexpected newest generation name"*) pass "the junk answer is reported" ;; *) fail "junk prev" "$out" ;; esac
[ ! -e "$D/20261122T030000Z" ] && pass "nothing was published after the junk answer" || fail "junk prev" "generation exists"

# --- the success stamp that scripts/backup-stale.sh reads ------------------------------------------------
# Host mode only (the fake ssh runs the peer commands and rsync locally): a --dest run is a local copy and must
# not vouch for the off-host one.
seed; D="$ROOT/peer-stamp"; ST="$CM_HOME/cache/backup-offhost.json"
bkp() { CM_BACKUP_SSH="$FAKE" "$BK" --host peerx --remote-dir "$D" "$@"; }
CM_BACKUP_NOW=20261028T030000Z bkp --dry-run >/dev/null 2>&1
[ ! -e "$ST" ] && pass "a dry run writes no stamp" || fail "stamp" "dry run wrote it"
STUB_RC=2 CM_BACKUP_NOW=20261028T030000Z bkp >/dev/null 2>&1
[ ! -e "$ST" ] && pass "a refused scan writes no stamp" || fail "stamp" "refused run wrote it"
CM_BACKUP_NOW=20261028T030000Z "$BK" --dest "$ROOT/peer-stamp-local" >/dev/null 2>&1
[ ! -e "$ST" ] && pass "a --dest (local copy) run writes no stamp" || fail "stamp" "a local copy wrote it"
out="$(CM_BACKUP_NOW=20261028T030000Z bkp 2>&1)"; rc=$?
check "a good run to a peer exits 0" 0 "$rc"
check "the stamp names the generation" 20261028T030000Z "$(jq -r .generation "$ST" 2>/dev/null)"
check "the stamp names the peer host" peerx "$(jq -r .host "$ST" 2>/dev/null)"
check "the stamp time is the generation time, in epoch seconds" "$(date -u -d 2026-10-28T03:00:00Z +%s 2>/dev/null || date -u -j -f %Y%m%dT%H%M%SZ 20261028T030000Z +%s)" "$(jq -r .ok_at "$ST" 2>/dev/null)"
check "the stamp names the remote dir" "$D" "$(jq -r .remote_dir "$ST" 2>/dev/null)"
check "no stamp temp file is left behind" "" "$(find "$CM_HOME/cache" -name 'backup-offhost.json.*' | head -1)"
case "$out" in *"except the stamp"*) pass "the final line says the stamp was written" ;; *) fail "stamp line" "$out" ;; esac
if [ "$(id -u)" != 0 ]; then   # root can write into a read-only directory
  chmod 500 "$CM_HOME/cache"
  out="$(CM_BACKUP_NOW=20261029T030000Z bkp 2>&1)"; rc=$?
  chmod 700 "$CM_HOME/cache"
  check "a stamp that cannot be written does not fail the backup" 0 "$rc"
  case "$out" in *"could not write"*"stale-backup check"*) pass "and says so" ;; *) fail "stamp warning" "$out" ;; esac
fi

# --- temp files: every one comes from mktemp, and none is left behind -------------------------------
# The rewritten file list used to be named "<list>.2", a name anyone who could see the first temp
# file could plant. Both lists now come from mktemp; the wrapper records every template it is given.
seed; D="$ROOT/peer-mk"; TD="$ROOT/tmpd"; mkdir -p "$TD" "$ROOT/mkbin"
REAL_MKTEMP="$(command -v mktemp)"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$ROOT/mktemp.log" "$REAL_MKTEMP" > "$ROOT/mkbin/mktemp"
chmod +x "$ROOT/mkbin/mktemp"; : > "$ROOT/mktemp.log"
out="$(PATH="$ROOT/mkbin:$PATH" TMPDIR="$TD" CM_BACKUP_NOW=20261123T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a run with a recording mktemp exits 0" 0 "$rc"
check "the file list and its rewrite both come from mktemp" 2 "$(grep -c 'cm-backup-list\.XXXXXX' "$ROOT/mktemp.log")"
check "no temp file is left in TMPDIR after a good run" "" "$(ls -A "$TD")"
seed; D="$ROOT/peer-mk2"; : > "$ROOT/mktemp.log"
out="$(STUB_RC=2 PATH="$ROOT/mkbin:$PATH" TMPDIR="$TD" CM_BACKUP_NOW=20261123T040000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a refused scan exits 4" 4 "$rc"
check "no temp file is left in TMPDIR after a refused scan" "" "$(ls -A "$TD")"

# --- the peer directory mode check also sees an ACL ----------------------------------------------------
# ls shows a trailing + on a directory that carries an ACL: the mode bits then say nothing about who can
# read it. The stub answers `ls -ld .` the way ls does for such a directory and passes everything else on.
seed; D="$ROOT/peer-acl"; mkdir -p "$ROOT/aclbin"
# shellcheck disable=SC2016  # the stub's own $ expansions must stay literal
printf '#!/bin/sh\nif [ "$1" = "-ld" ]; then echo "drwx------+ 2 peer peer 4096 Nov  2 12:00 ."; exit 0; fi\nexec "%s" "$@"\n' "$(command -v ls)" > "$ROOT/aclbin/ls"
chmod +x "$ROOT/aclbin/ls"
out="$(PATH="$ROOT/aclbin:$PATH" CM_BACKUP_NOW=20261124T030000Z "$BK" --dest "$D" 2>&1)"; rc=$?
check "a peer directory with an ACL still gets its generation (exit 0)" 0 "$rc"
case "$out" in *"has an ACL"*"getfacl"*) pass "the ACL is named in a warning" ;; *) fail "acl warning" "$out" ;; esac
case "$out" in *"readable by group or other"*) fail "acl warning" "the mode warning fired for a 700 directory" ;; *) pass "no mode warning for a 700 directory with an ACL" ;; esac
seed; D="$ROOT/peer-noacl"
out="$(CM_BACKUP_NOW=20261124T040000Z "$BK" --dest "$D" 2>&1)"
case "$out" in *"has an ACL"*) fail "acl warning" "fired without an ACL: $out" ;; *) pass "no ACL warning for a plain 700 directory" ;; esac

# --- restore: the documented rsync pulls the newest generation back into a fresh dir -----------------
R="$ROOT/restored"; mkdir -p "$R"
rsync -a --exclude BACKUP-INFO "$P/bk/latest/" "$R/" >/dev/null 2>&1; rc=$?
check "restore from latest/ exits 0" 0 "$rc"
[ "$(jq -r .schema "$R/ledger.json" 2>/dev/null)" = "concertmaster.ledger/v1" ] && [ -f "$R/handovers/w-1-h.md" ] && [ -f "$R/ledger.bak/20261001T000000Z.json" ] \
  && pass "the restored tree has the ledger, the ring and the handovers" || fail "restore" "$(files_of "$R")"
[ ! -e "$R/BACKUP-INFO" ] && [ ! -e "$R/mc.env" ] && [ ! -e "$R/salvage" ] && pass "the restored tree has no BACKUP-INFO, mc.env or salvage" || fail "restore extras" "$(files_of "$R")"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
