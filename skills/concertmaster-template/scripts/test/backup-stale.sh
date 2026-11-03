#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && ok || bad": ok never fails
# backup-stale.sh test: a fake clock (CM_NOW), a stamp file written by hand, a dead telemetry URL.
# Asserts: no host configured stays quiet; a fresh stamp is fine; a stamp over the limit alerts ONCE
# (inbox note + outbox event) and not again; a new good stamp sends one "cleared"; no stamp counts from
# the first run of the check, so a new setup has the limit to make its first backup; the limit comes
# from CM_BACKUP_MAX_AGE_HOURS or config backup.max_age_hours; --dry-run writes nothing even over the
# limit; garbage state and a garbage stamp read as a fresh start; bad numbers are a usage error.
#
#   scripts/test/backup-stale.sh         # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/backup-stale.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-backup-stale-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ -n "${CM_TEST_KEEP_TMP:-}" ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/home" HOME="$ROOT/home" MC_BASE_URL="http://127.0.0.1:9" MC_QUIET=1
export CM_CONFIG=/nonexistent
unset CM_BACKUP_HOST CM_BACKUP_MAX_AGE_HOURS CM_NOW
mkdir -p "$CM_HOME/cache"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
notes() { find "$CM_HOME/inbox" -name "backup-stale-$1-*.md" 2>/dev/null | wc -l | tr -d ' '; }
events() { grep -c "$1" "$CM_HOME/outbox.jsonl" 2>/dev/null || true; }
T0=1800000000; H=3600
stamp() { jq -n --argjson t "$1" '{ok_at:$t,generation:"20271015T034100Z",host:"peer",remote_dir:"bk"}' > "$CM_HOME/cache/backup-offhost.json"; }
at() { CM_BACKUP_HOST=peer CM_NOW=$((T0 + $1 * H)) "$SCRIPT"; }

out="$(CM_NOW=$T0 "$SCRIPT")"
case "$out" in *"backup.host is not set"*) echo "ok   no host: says no backup is expected" ;; *) echo "FAIL no host: $out"; fail=1 ;; esac
check "no host: no note" "$(notes alert)" "0"

stamp "$T0"
out="$(at 10)"; case "$out" in *"10 h ago"*"fine"*) echo "ok   a 10 h old stamp is fine" ;; *) echo "FAIL fresh: $out"; fail=1 ;; esac
check "fresh: no alert" "$(notes alert)" "0"
# the default is 50 h, so ONE missed night (the cron runs once a day: up to 48 h between two good stamps) is quiet and two alarm
at 47 >/dev/null; check "47 h is under the 50 h default (one missed night): no alert" "$(notes alert)" "0"
out="$(at 51)"; check "51 h: one alert note" "$(notes alert)" "1"
case "$out" in *"20271015T034100Z"*"51 h ago"*) echo "ok   the alert names the last good generation and the age" ;; *) echo "FAIL alert text: $out"; fail=1 ;; esac
check "the alert reaches the telemetry outbox" "$(events backup.stale)" "1"
at 60 >/dev/null; check "still stale: no second alert" "$(notes alert)" "1"
# every file in the inbox is one of ours, named the way the one glob the tick reads expects (kind, UTC time, pid)
bad="$(find "$CM_HOME/inbox" -type f ! -name 'backup-stale-*.md' | wc -l | tr -d ' ')"
check "nothing but backup-stale-*.md in the inbox" "$bad" "0"
badname="$(find "$CM_HOME/inbox" -type f -name 'backup-stale-*.md' | while read -r f; do basename "$f" | grep -Eq '^backup-stale-(alert|cleared|config)-[0-9]{8}T[0-9]{6}Z-[0-9]+\.md$' || echo "$f"; done | wc -l | tr -d ' ')"
check "and each is named kind, UTC time, pid" "$badname" "0"
[ "$(find "$CM_HOME/inbox" -type f | wc -l | tr -d ' ')" -ge 1 ] && echo "ok   the glob finds at least the alert" || { echo "FAIL glob finds nothing"; fail=1; }
stamp $((T0 + 70 * H)); at 71 >/dev/null
check "a new good stamp sends one cleared note" "$(notes cleared)" "1"
check "and a cleared event" "$(events backup.fresh)" "1"
at 72 >/dev/null; check "fresh again: no second cleared note" "$(notes cleared)" "1"
at 125 >/dev/null; check "a second episode alerts again" "$(notes alert)" "2"

# the limit: env beats config, default 50
printf 'backup:\n  host: peer\n  max_age_hours: 12\n' > "$ROOT/c.yaml"
stamp "$T0"; rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"
CM_CONFIG="$ROOT/c.yaml" CM_NOW=$((T0 + 13 * H)) "$SCRIPT" >/dev/null; check "config backup.max_age_hours 12: 13 h alerts" "$(notes alert)" "1"
rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"
CM_CONFIG="$ROOT/c.yaml" CM_BACKUP_MAX_AGE_HOURS=48 CM_NOW=$((T0 + 13 * H)) "$SCRIPT" >/dev/null; check "the env limit 48 beats the config: 13 h is fine" "$(notes alert)" "0"

# no stamp: the clock starts the first time the check sees none
rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json" "$CM_HOME/cache/backup-offhost.json"
out="$(at 0)"; case "$out" in *"no good backup recorded"*"0 h ago"*) echo "ok   no stamp: starts counting" ;; *) echo "FAIL no stamp: $out"; fail=1 ;; esac
at 40 >/dev/null; check "no stamp, 40 h in: no alert yet" "$(notes alert)" "0"
at 51 >/dev/null; check "no stamp, 51 h in: one alert" "$(notes alert)" "1"

# --dry-run
rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"; stamp "$T0"
CM_BACKUP_HOST=peer CM_NOW=$((T0 + 80 * H)) "$SCRIPT" --dry-run >/dev/null
check "--dry-run over the limit writes no note" "$(notes alert)" "0"
[ ! -e "$CM_HOME/cache/backup-stale.json" ] && echo "ok   --dry-run writes no state" || { echo "FAIL --dry-run state"; fail=1; }

# a stamp written for another host says nothing about the configured one
stamp "$T0"; rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"
CM_BACKUP_HOST=other-peer CM_NOW=$((T0 + 2 * H)) "$SCRIPT" >/dev/null
check "a stamp for another host is ignored: counting starts from this check" "$(jq -r .first_seen "$CM_HOME/cache/backup-stale.json")" "$((T0 + 2 * H))"
out="$(CM_BACKUP_HOST=other-peer CM_NOW=$((T0 + 2 * H)) "$SCRIPT")"
case "$out" in *"names host 'peer', not 'other-peer'"*) echo "ok   and says so" ;; *) echo "FAIL other host: $out"; fail=1 ;; esac

# an alert is ended by a good backup for this host, not by a changed host or a new grace period
stamp "$T0"; rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"
CM_BACKUP_HOST=peer CM_NOW=$((T0 + 50 * H)) "$SCRIPT" >/dev/null
check "setup for the host-change case: one alert" "$(notes alert)" "1"
CM_BACKUP_HOST=other-peer CM_NOW=$((T0 + 51 * H)) "$SCRIPT" >/dev/null
check "backup.host changed after an alert: no cleared note (nothing good happened)" "$(notes cleared)" "0"
check "the state starts again for the new host: no open episode" "$(jq -r .alerted "$CM_HOME/cache/backup-stale.json")" "false"
check "and its grace period starts at the change, not at the old time" "$(jq -r .first_seen "$CM_HOME/cache/backup-stale.json")" "$((T0 + 51 * H))"
CM_BACKUP_HOST=other-peer CM_NOW=$((T0 + 52 * H)) "$SCRIPT" >/dev/null
check "and it does not alarm at once" "$(notes alert)" "1"

# a stamp that was deleted: the grace period starts when the check sees no stamp, not at the last time it did
stamp "$T0"; rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"
at 1 >/dev/null; rm -f "$CM_HOME/cache/backup-offhost.json"
at 200 >/dev/null
check "a deleted stamp: no alarm on the first check without it" "$(notes alert)" "0"
check "and the count starts then" "$(jq -r .first_seen "$CM_HOME/cache/backup-stale.json")" "$((T0 + 200 * H))"

# a stamp from the future (clock change): counted as new, and said so
stamp $((T0 + 10 * H)); rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"
out="$(at 0)"; case "$out" in *"in the future"*"0 h old"*) echo "ok   a future stamp is noted" ;; *) echo "FAIL future stamp: $out"; fail=1 ;; esac

# an inbox note that cannot be written is not counted as sent: the episode stays closed and the next tick tries again
stamp "$T0"; rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"; : > "$CM_HOME/inbox"
at 80 >/dev/null 2>&1; rc=$?
check "an unwritable inbox: exit 0" "$rc" "0"
check "and the alert is not marked sent" "$(jq -r .alerted "$CM_HOME/cache/backup-stale.json")" "false"
rm -f "$CM_HOME/inbox"; mkdir -p "$CM_HOME/inbox"
at 81 >/dev/null; check "the next tick writes the alert" "$(notes alert)" "1"
check "and marks it sent" "$(jq -r .alerted "$CM_HOME/cache/backup-stale.json")" "true"

# robustness
printf 'not json' > "$CM_HOME/cache/backup-stale.json"; printf 'also not json' > "$CM_HOME/cache/backup-offhost.json"
at 5 >/dev/null; check "garbage state and stamp read as a fresh start" "$(jq -r .alerted "$CM_HOME/cache/backup-stale.json")" "false"
check "no leftover temp state files" "$(find "$CM_HOME/cache" -name '*.tmp.*' | wc -l | tr -d ' ')" "0"
rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"
CM_BACKUP_MAX_AGE_HOURS=36h CM_BACKUP_HOST=peer "$SCRIPT" >/dev/null 2>&1; check "a typo such as 36h is a usage error" "$?" "2"
check "and it writes one note, so the tick shows it" "$(notes config)" "1"
CM_BACKUP_MAX_AGE_HOURS=36h CM_BACKUP_HOST=peer "$SCRIPT" >/dev/null 2>&1
check "the same typo again writes no second note" "$(notes config)" "1"
CM_BACKUP_MAX_AGE_HOURS=abc CM_BACKUP_HOST=peer "$SCRIPT" >/dev/null 2>&1; check "another bad value is a usage error" "$?" "2"
check "and gets its own note" "$(notes config)" "2"
CM_BACKUP_MAX_AGE_HOURS=0 CM_BACKUP_HOST=peer "$SCRIPT" >/dev/null 2>&1; check "a limit of 0 is a usage error" "$?" "2"
CM_BACKUP_MAX_AGE_HOURS=36h "$SCRIPT" >/dev/null 2>&1; check "a bad limit with no host configured stays quiet" "$?" "0"
"$SCRIPT" --nope >/dev/null 2>&1; check "an unknown argument is a usage error" "$?" "2"
# the telemetry event is queued, not flushed: this check makes no network call (a stub mc-emit.sh records MC_NO_FLUSH)
SD="$ROOT/skill/scripts"; mkdir -p "$SD"
cp "$SCRIPT" "$(dirname "$SCRIPT")/lib.sh" "$SD/"
# shellcheck disable=SC2016  # the stub's own $ expansions must stay literal
printf '#!/bin/sh\nprintf "%%s\n" "${MC_NO_FLUSH:-unset}" >> "%s/flush.log"\n' "$ROOT" > "$SD/mc-emit.sh"; chmod +x "$SD/mc-emit.sh"
rm -rf -- "${CM_HOME:?}/inbox" "$CM_HOME/cache/backup-stale.json"; stamp "$T0"
CM_BACKUP_HOST=peer CM_NOW=$((T0 + 80 * H)) "$SD/backup-stale.sh" >/dev/null
check "the alert event is emitted with MC_NO_FLUSH=1" "$(cat "$ROOT/flush.log" 2>/dev/null)" "1"
exit $fail
