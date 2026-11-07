#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2034  # check bodies are single-quoted on purpose (eval-ed later); A && pass || fail is if-then-else
# clock-check.sh (test): a stubbed clock (CM_NOW), a temp config and a temp ledger. The window in force, the minutes to it,
# the deploy worker lookup and the picker verdict, with the window passed, in flight, finished and the ledger unreadable.
#
#   scripts/test/clock-check.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-clock-check.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1: ${3:-}"; fi; }

export CM_HOME="$ROOT/cm"; mkdir -p "$CM_HOME"
unset CM_LEDGER CM_TZ
printf 'schedule:\n  timezone: UTC\n  deploy_windows: ["11:00", "16:00"]\n' > "$ROOT/utc.yaml"
printf 'schedule:\n  timezone: Europe/London\n  deploy_windows: ["11:00", "16:00"]\n' > "$ROOT/london.yaml"
printf 'schedule:\n  timezone: UTC\n' > "$ROOT/nokey.yaml"
printf 'schedule:\n  timezone: UTC\n  deploy_windows: []\n' > "$ROOT/none.yaml"
printf 'schedule: [::bad\n' > "$ROOT/bad.yaml"
: > "$ROOT/empty.yaml"
printf 'schedule:\n  timezone: UTC\n  deploy_windows: ["9:00", "nonsense"]\n' > "$ROOT/pad.yaml"
printf 'schedule:\n  timezone: UTC\n  deploy_windows: ["nonsense", "25"]\n' > "$ROOT/badall.yaml"
CC="$SCRIPTS/clock-check.sh"
run() { # <config> <CM_NOW>: sets OUT, RC
  OUT="$(CM_TEST=1 CM_CONFIG="$ROOT/$1" CM_NOW="$2" bash "$CC" 2>&1)"; RC=$?
}
val() { printf '%s\n' "$OUT" | sed -n "s/^$1: //p"; }
ledger() { printf '%s\n' "$1" > "$CM_HOME/ledger.json"; }
W_ROW='{"id":"2000-01-01T11:00","at":"2000-01-01T11:00:00Z","state":"%s","worker":"%s"}'

echo "--- no deploy worker on record"
ledger '{"workers":{},"deployWindows":[]}'
run utc.yaml 2000-01-01T06:00:00Z
check "6h out: the 11:00 window is upcoming, 300 minutes, a picker is allowed, exit 0" '[ "$RC" = 0 ] && [ "$(val state)" = upcoming ] && [ "$(val minutes)" = 300 ] && [ "$(val picker)" = allowed ] && [ "$(val window)" = "2000-01-01T11:00 at 2000-01-01T11:00:00Z" ]' "$OUT"
run utc.yaml 2000-01-01T09:30:00Z
check "90 minutes out with no deploy worker: inside-2h, deploy-worker none, the ask is a WAITING row only" '[ "$(val state)" = inside-2h ] && [ "$(val minutes)" = 90 ] && [ "$(val deploy-worker)" = none ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
run utc.yaml 2000-01-01T09:00:00Z
check "exactly 2 hours out is inside the window" '[ "$(val state)" = inside-2h ] && [ "$(val minutes)" = 120 ]' "$OUT"
run utc.yaml 2000-01-01T08:59:00Z
check "121 minutes out is not yet" '[ "$(val state)" = upcoming ] && [ "$(val minutes)" = 121 ]' "$OUT"
run utc.yaml 2000-01-01T12:00:00Z
check "the window passed with no deploy worker and no outcome: missed (-60), still in force, WAITING row only" '[ "$(val state)" = missed ] && [ "$(val minutes)" = -60 ] && [ "$(val picker)" = WAITING-row-only ] && [ "$(val window)" = "2000-01-01T11:00 at 2000-01-01T11:00:00Z" ]' "$OUT"
ledger '{"workers":{},"deployWindows":[]}'
run utc.yaml 2000-01-01T14:30:00Z
check "a missed 11:00 and the 16:00 inside 2 hours are BOTH checked (14:30): neither has a worker, so WAITING row only; the first window shown is the 11:00" '[ "$(val window)" = "2000-01-01T11:00 at 2000-01-01T11:00:00Z" ] && [ "$(val picker)" = WAITING-row-only ] && [ "$(printf "%s\n" "$OUT" | grep -c "^window-check:")" = 2 ] && printf "%s\n" "$OUT" | grep -q "^window-check: 2000-01-01T16:00 inside-2h worker none not live$"' "$OUT"
run utc.yaml 2000-01-01T13:59:00Z
check "...but not before: at 13:59 (121 minutes to the 16:00) the missed 11:00 is still the window in force" '[ "$(val window)" = "2000-01-01T11:00 at 2000-01-01T11:00:00Z" ] && [ "$(val state)" = missed ]' "$OUT"
run utc.yaml 2000-01-01T08:59:30Z
check "2 hours and 30 seconds out is not yet inside 2 hours (the boundary is in seconds)" '[ "$(val state)" = upcoming ] && [ "$(val minutes)" = 120 ]' "$OUT"
run utc.yaml 2000-01-01T23:30:00Z
check "a missed window stays in force for 12 hours: at 23:30 the 16:00 one (missed), the 11:00 one is too old" '[ "$(val window)" = "2000-01-01T16:00 at 2000-01-01T16:00:00Z" ] && [ "$(val state)" = missed ]' "$OUT"
run utc.yaml 2000-01-02T04:30:00Z
check "...then the next window takes over: 04:30 next day, the 11:00 one, upcoming (390 minutes)" '[ "$(val window)" = "2000-01-02T11:00 at 2000-01-02T11:00:00Z" ] && [ "$(val state)" = upcoming ] && [ "$(val minutes)" = 390 ]' "$OUT"

echo "--- a deploy worker"
ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "staging" w-deploy-a)" '{workers: {"w-deploy-a": {state: "running"}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T09:30:00Z
check "inside 2h with the deploy worker listed in the ledger: it is named, a picker is allowed (the wake is still the caller's)" '[ "$(val deploy-worker)" = "w-deploy-a (running)" ] && [ "$(val picker)" = allowed ] && [ "$(val state)" = inside-2h ]' "$OUT"
run utc.yaml 2000-01-01T11:30:00Z
check "the window is under way with a deploy worker: in-flight, picker allowed" '[ "$(val state)" = in-flight ] && [ "$(val picker)" = allowed ]' "$OUT"
ledger "$(jq -cn --argjson r "$(printf "$W_ROW" staging w-deploy-a)" '{workers: {}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T09:30:00Z
check "the window row names a worker the ledger does not list: not enough for a picker (WAITING row only)" '[ "$(val deploy-worker)" = "w-deploy-a (named by the window row, not listed in workers)" ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "done" w-deploy-a)" '{workers: {"w-deploy-a": {state: "done"}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T12:00:00Z
check "the 11:00 window is done: the 16:00 window is the one in force, 240 minutes, upcoming" '[ "$(val window)" = "2000-01-01T16:00 at 2000-01-01T16:00:00Z" ] && [ "$(val minutes)" = 240 ] && [ "$(val state)" = upcoming ]' "$OUT"
ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "skipped" "")" '{workers: {}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T10:00:00Z
check "a skipped window (no delta) is finished too" '[ "$(val window)" = "2000-01-01T16:00 at 2000-01-01T16:00:00Z" ]' "$OUT"

ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "staging" w-deploy-a)" '{workers: {"w-deploy-a": {state: "gone"}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T11:30:00Z
check "the window row names a worker the ledger lists as gone: not a live worker, WAITING row only" '[ "$(val deploy-worker)" = "w-deploy-a (gone, not a live worker)" ] && [ "$(val picker)" = WAITING-row-only ] && [ "$(val state)" = worker-dead ]' "$OUT"

ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "staging" w-deploy-a)" '{workers: {"w-deploy-a": {state: "done"}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T11:30:00Z
check "a worker the ledger lists as done is not a live deploy worker for a window still under way: WAITING row only" '[ "$(val deploy-worker)" = "w-deploy-a (done, not a live worker)" ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
run utc.yaml 2000-01-01T15:30:00Z
check "...and a window whose worker died is still checked next to the 16:00 (15:30): worker-dead and inside-2h, WAITING row only" '[ "$(val state)" = worker-dead ] && [ "$(val picker)" = WAITING-row-only ] && printf "%s\n" "$OUT" | grep -q "^window-check: 2000-01-01T16:00 inside-2h worker none not live$"' "$OUT"
ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "staging" w-deploy-a)" '{workers: {"w-deploy-a": {state: "blocked-on-owner"}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T11:30:00Z
check "a deploy worker blocked on the owner is still a live worker" '[ "$(val picker)" = allowed ] && [ "$(val state)" = in-flight ]' "$OUT"
ledger '{"workers":{},"deployWindows":[]}'
run utc.yaml 2000-01-01T11:00:30Z
check "30 seconds past the window reads -1 minutes (floor), not 0" '[ "$(val minutes)" = -1 ] && [ "$(val state)" = missed ]' "$OUT"
check "a stubbed clock says so on the now line" 'printf "%s\n" "$OUT" | grep -q "^now: 2000-01-01T11:00:30Z (stubbed by CM_NOW: not the real clock)$"' "$OUT"
printf 'schedule:\n  timezone: UTC\n  deploy_windows: ["*", "11:00"]\n' > "$ROOT/glob.yaml"
( cd "$SCRIPTS" && CM_TEST=1 CM_CONFIG="$ROOT/glob.yaml" CM_NOW=2000-01-01T09:30:00Z bash "$CC" ) > "$ROOT/glob.out" 2>&1
check "a deploy_windows entry of * is one bad entry, not the file names of the current directory" '[ "$(grep -c "^warning:" "$ROOT/glob.out")" = 1 ] && grep -q "^warning: deploy_windows entry .\*. is not HH:MM, skipped" "$ROOT/glob.out"' "$(cat "$ROOT/glob.out")"

ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "staging" w-deploy-a)" '{workers: {"w-deploy-a": {}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-01T11:30:00Z
check "a worker row with no state is not a live worker (fail closed): WAITING row only" '[ "$(val picker)" = WAITING-row-only ] && [ "$(val state)" = worker-dead ]' "$OUT"

W_ROW2='{"id":"2000-01-01T11:00","at":"2000-01-01T11:00:00Z","state":"prod","worker":"w-deploy-a","tag":"v1.2.3","prodRunId":456}'
ledger "$(jq -cn --argjson r "$W_ROW2" '{workers: {"w-deploy-a": {state: "blocked-on-owner"}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-02T05:00:00Z
check "a window with a live deploy worker stays in force past 12 hours (18 hours on, still in-flight)" '[ "$(val window)" = "2000-01-01T11:00 at 2000-01-01T11:00:00Z" ] && [ "$(val state)" = in-flight ]' "$OUT"
check "the row's state, tag and prod run id are printed, so a message about the release can be checked" '[ "$(val row)" = "state prod, tag v1.2.3, prod run 456" ]' "$OUT"
ledger "$(jq -cn --argjson r "$W_ROW2" '{workers: {"w-deploy-a": {state: "gone"}}, deployWindows: [$r]}')"
run utc.yaml 2000-01-02T05:00:00Z
check "...and not once its worker is gone: the next window takes over" '[ "$(val window)" = "2000-01-02T11:00 at 2000-01-02T11:00:00Z" ]' "$OUT"

echo "--- every window that matters needs its own live worker"
W_Y='{"id":"2000-11-05T21:00","at":"2000-11-05T21:00:00Z","state":"validating","worker":"w-dep-y"}'
printf 'schedule:\n  timezone: Europe/London\n  deploy_windows: ["21:00"]\n' > "$ROOT/london21.yaml"
ledger "$(jq -cn --argjson r "$W_Y" '{workers: {"w-dep-y": {state: "running"}}, deployWindows: [$r]}')"
run london21.yaml 2000-11-06T19:25:00Z
check "yesterday's window has a live running worker but tonight's (95 minutes out) has none: not allowed" '[ "$(val picker)" = WAITING-row-only ] && printf "%s\n" "$OUT" | grep -q "^window-check: 2000-11-05T21:00 in-flight worker w-dep-y live$" && printf "%s\n" "$OUT" | grep -q "^window-check: 2000-11-06T21:00 inside-2h worker none not live$"' "$OUT"
printf 'schedule:\n  timezone: UTC\n  deploy_windows: ["11:00", "12:00"]\n' > "$ROOT/close.yaml"
ledger "$(jq -cn '{workers: {"w-a": {state: "running"}}, deployWindows: [{id: "2000-01-01T11:00", state: "staging", worker: "w-a"}]}')"
run close.yaml 2000-01-01T11:30:00Z
check "two close windows: 11:00 has a running worker, 12:00 has none, at 11:30 the picker is not allowed (a worker never covers another window)" '[ "$(val picker)" = WAITING-row-only ] && printf "%s\n" "$OUT" | grep -q "^window-check: 2000-01-01T12:00 inside-2h worker none not live$"' "$OUT"
ledger "$(jq -cn '{workers: {"w-a": {state: "running"}, "w-b": {state: "running"}}, deployWindows: [{id: "2000-01-01T11:00", state: "staging", worker: "w-a"}, {id: "2000-01-01T12:00", state: "pending", worker: "w-b"}]}')"
run close.yaml 2000-01-01T11:30:00Z
check "...each with its own live worker: allowed, with a reminder that the wake and the pin are not visible to the script" '[ "$(val picker)" = allowed ] && [ "$(printf "%s\n" "$OUT" | grep -c "^window-check:")" = 2 ] && printf "%s\n" "$OUT" | grep -q "^note: arm the wake"' "$OUT"
ledger "$(jq -cn '{workers: {"w-a": {state: "running"}}, deployWindows: [{id: "2000-01-01T11:00", state: "staging", worker: "w-a"}, {id: "2000-01-01T12:00", state: "pending", worker: "w-a"}]}')"
run close.yaml 2000-01-01T11:30:00Z
check "one worker named by two unfinished window rows covers neither: WAITING row only, and the worker line says why" '[ "$(val picker)" = WAITING-row-only ] && [ "$(val deploy-worker)" = "w-a (named by 2 unfinished window rows: one worker never covers two windows)" ]' "$OUT"
ledger "$(jq -cn '{workers: {"w-a": {state: "running"}}, deployWindows: [{id: "2000-01-01T11:00", state: "done", worker: "w-a"}, {id: "2000-01-01T12:00", state: "staging", worker: "w-a"}]}')"
run close.yaml 2000-01-01T12:30:00Z
check "...but a worker whose earlier window is finished may serve the next one (only unfinished rows count)" '[ "$(val picker)" = allowed ] && [ "$(val deploy-worker)" = "w-a (running)" ]' "$OUT"
ledger "$(jq -cn '{workers: {"w-a": {state: "stuck"}}, deployWindows: [{id: "2000-01-01T11:00", state: "pending", worker: "w-a"}]}')"
run utc.yaml 2000-01-01T10:00:00Z
check "a row pending with a STUCK worker at 60 minutes out: stuck is not spawned, the picker is not allowed" '[ "$(val picker)" = WAITING-row-only ] && [ "$(val state)" = inside-2h ]' "$OUT"
ledger "$(jq -cn '{workers: {"w-a": {state: "stuck"}}, deployWindows: [{id: "2000-01-01T11:00", state: "pending", worker: "w-a"}]}')"
run utc.yaml 2000-01-01T10:00:00Z
check "...and the window line says the worker is not live" 'printf "%s\n" "$OUT" | grep -q "^window-check: 2000-01-01T11:00 inside-2h worker w-a not live$"' "$OUT"
ledger "$(jq -cn '{workers: {}, deployWindows: [{id: "2000-01-01T11:00", state: "stopped"}]}')"
run utc.yaml 2000-01-01T12:00:00Z
check "a stopped window is finished: the 16:00 is the window shown, upcoming" '[ "$(val window)" = "2000-01-01T16:00 at 2000-01-01T16:00:00Z" ] && [ "$(val state)" = upcoming ] && [ "$(val picker)" = allowed ]' "$OUT"

echo "--- a config that was not read is unknown, never allowed"
ledger '{"workers":{},"deployWindows":[]}'
OUT="$(CM_TEST=1 CM_CONFIG="$ROOT/nonexist.yaml" CM_NOW=2000-01-01T10:00:00Z bash "$CC" 2>&1)"; RC=$?
check "a config file that does not exist: unknown and WAITING row only, 60 minutes before a window" '[ "$RC" = 0 ] && [ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
run bad.yaml 2000-01-01T10:00:00Z
check "a config that does not parse: unknown and WAITING row only" '[ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
run empty.yaml 2000-01-01T10:00:00Z
check "an empty config file: unknown and WAITING row only" '[ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
run nokey.yaml 2000-01-01T10:00:00Z
check "a config with no deploy_windows key: unknown and WAITING row only" '[ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
mkdir -p "$ROOT/badyq"; printf '#!/bin/sh\nexit 1\n' > "$ROOT/badyq/yq"; chmod +x "$ROOT/badyq/yq"
OUT="$(PATH="$ROOT/badyq:$PATH" CM_TEST=1 CM_CONFIG="$ROOT/utc.yaml" CM_NOW=2000-01-01T10:00:00Z bash "$CC" 2>&1)"; RC=$?
check "yq failing: the config is not read, unknown and WAITING row only" '[ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"

echo "--- a ledger row no configured window made, and a leaked CM_NOW"
ledger "$(jq -cn '{workers: {"w-old": {state: "blocked-on-owner"}}, deployWindows: [{id: "1999-12-30T11:00", at: "1999-12-30T11:00:00Z", state: "prod", worker: "w-old", tag: "v9"}]}')"
run utc.yaml 2000-01-01T06:00:00Z
check "an unfinished row two days old with a live worker is still seen (in-flight) although no configured window made it" 'printf "%s\n" "$OUT" | grep -q "^window-check: 1999-12-30T11:00 in-flight worker w-old live$" && [ "$(val window)" = "1999-12-30T11:00 at 1999-12-30T11:00:00Z" ] && [ "$(val picker)" = allowed ]' "$OUT"
ledger "$(jq -cn '{workers: {"w-old": {state: "gone"}}, deployWindows: [{id: "1999-12-30T11:00", at: "1999-12-30T11:00:00Z", state: "prod", worker: "w-old"}]}')"
run utc.yaml 2000-01-01T06:00:00Z
check "...and not once its worker is gone and it is past 12 hours: dropped" '! printf "%s\n" "$OUT" | grep -q "1999-12-30" && [ "$(val state)" = upcoming ]' "$OUT"
ledger '{"workers":{},"deployWindows":[]}'
OUT="$(env -u CM_TEST CM_CONFIG="$ROOT/utc.yaml" CM_NOW=2000-01-01T09:30:00Z bash "$CC" 2>&1)"; RC=$?
check "CM_NOW without CM_TEST=1 is ignored with a warning (the real clock is used, no stubbed mark)" '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "^warning: CM_NOW is set but CM_TEST is not 1" && ! printf "%s\n" "$OUT" | grep -q "stubbed by CM_NOW" && ! printf "%s\n" "$OUT" | grep -q "^now: 2000-01-01"' "$OUT"

echo "--- time zone, no window, bad ledger, bad clock"
ledger '{"workers":{},"deployWindows":[]}'
HAVE_ZI=0; [ -d /usr/share/zoneinfo/Europe ] && HAVE_ZI=1
[ "$HAVE_ZI" = 1 ] || echo "SKIP time zone cases: no /usr/share/zoneinfo on this host"
if [ "$HAVE_ZI" = 1 ]; then
run london.yaml 2000-07-01T08:30:00Z
check "Europe/London in summer: 11:00 local is 10:00Z, so 08:30Z is 90 minutes out" '[ "$(val window)" = "2000-07-01T11:00 at 2000-07-01T10:00:00Z" ] && [ "$(val minutes)" = 90 ] && [ "$(val state)" = inside-2h ]' "$OUT"
else echo "SKIP london summer: no /usr/share/zoneinfo"; fi
if [ "$HAVE_ZI" = 1 ]; then
run london.yaml 2000-01-01T08:30:00Z
check "...and in winter 11:00 local is 11:00Z" '[ "$(val window)" = "2000-01-01T11:00 at 2000-01-01T11:00:00Z" ] && [ "$(val minutes)" = 150 ]' "$OUT"
else echo "SKIP london winter: no /usr/share/zoneinfo"; fi
run pad.yaml 2000-01-01T06:30:00Z
check "an entry written 9:00 is read as 09:00, and a bad entry is reported and skipped (not silently)" '[ "$(val window)" = "2000-01-01T09:00 at 2000-01-01T09:00:00Z" ] && printf "%s\n" "$OUT" | grep -q "^warning: deploy_windows entry .nonsense. is not HH:MM, skipped"' "$OUT"
run badall.yaml 2000-01-01T09:30:00Z
check "windows configured but none usable: unknown and WAITING row only (not allowed), exit 0" '[ "$RC" = 0 ] && [ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
printf 'schedule:\n  timezone: UTC\n  deploy_windows: ["11:00", "16:75", "24:00"]\n' > "$ROOT/range.yaml"
run range.yaml 2000-01-01T09:30:00Z
check "an out-of-range entry (16:75, 24:00) is reported and skipped, not dropped silently" '[ "$(printf "%s\n" "$OUT" | grep -c "^warning:")" = 2 ] && [ "$(val window)" = "2000-01-01T11:00 at 2000-01-01T11:00:00Z" ]' "$OUT"
printf 'schedule:\n  timezone: Europe/Londn\n  deploy_windows: ["11:00"]\n' > "$ROOT/typo.yaml"
printf 'schedule:\n  timezone: Europe/London\n  deploy_windows: ["01:30"]\n' > "$ROOT/gap.yaml"
if [ "$HAVE_ZI" = 1 ]; then
run gap.yaml 2000-03-25T23:30:00Z
check "a window time that does not exist (01:30 the day the clocks go forward): unknown and WAITING row only, not dropped" '[ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ] && printf "%s\n" "$OUT" | grep -q "does not exist on 2000-03-26"' "$OUT"
else echo "SKIP clock change: no /usr/share/zoneinfo"; fi
if [ "$HAVE_ZI" = 1 ]; then
run typo.yaml 2000-07-01T08:30:00Z
check "a time zone that does not exist is unknown, not silently UTC" '[ "$RC" = 0 ] && [ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
else echo "SKIP zone typo: no /usr/share/zoneinfo"; fi
if [ "$HAVE_ZI" = 1 ]; then
OUT="$(CM_TEST=1 CM_TZ=Europe/London CM_CONFIG="$ROOT/utc.yaml" CM_NOW=2000-07-01T08:30:00Z bash "$CC" 2>&1)"; RC=$?
check "CM_TZ wins over the config time zone, as for every other script: London 11:00 in July is 10:00Z, 90 minutes from 08:30Z" '[ "$(val window)" = "2000-07-01T11:00 at 2000-07-01T10:00:00Z" ] && [ "$(val minutes)" = 90 ]' "$OUT"
else echo "SKIP CM_TZ: no /usr/share/zoneinfo"; fi
run none.yaml 2000-01-01T09:30:00Z
check "an EMPTY deploy_windows list is really no window: window none, state none, picker allowed, exit 0" '[ "$RC" = 0 ] && [ "$(val window)" = none ] && [ "$(val state)" = none ] && [ "$(val picker)" = allowed ]' "$OUT"
printf '{ not json' > "$CM_HOME/ledger.json"
run utc.yaml 2000-01-01T09:30:00Z
check "an unreadable ledger: deploy-worker unknown, inside 2h so WAITING row only, exit 0" '[ "$RC" = 0 ] && [ "$(val deploy-worker)" = "unknown (ledger unreadable or missing)" ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
mv "$CM_HOME/ledger.json" "$ROOT/ledger.moved"
run utc.yaml 2000-01-01T09:30:00Z
run utc.yaml 2000-01-01T12:00:00Z
check "a window already past while the ledger is missing reads unknown, not missed (whether it shipped is not known), WAITING row only" '[ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ] && printf "%s\n" "$OUT" | grep -q "^window-check: 2000-01-01T11:00 unknown worker none not live$"' "$OUT"
run utc.yaml 2000-01-01T09:30:00Z
check "a missing ledger reads the same way" '[ "$RC" = 0 ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
printf '{ not json' > "$CM_HOME/ledger.json"
run utc.yaml 2000-11-06T06:00:00Z
check "an unreadable ledger more than 2 hours before the window is fine: upcoming, picker allowed (nothing is past or inside 2 hours)" '[ "$(val state)" = upcoming ] && [ "$(val picker)" = allowed ]' "$OUT"
rm -f "$CM_HOME/ledger.json"
run utc.yaml "not a time"
check "a clock it cannot read: the state is unknown, WAITING row only, exit 0" '[ "$RC" = 0 ] && [ "$(val state)" = unknown ] && [ "$(val picker)" = WAITING-row-only ]' "$OUT"
check "--help prints the header and exits 0" '[ "$(bash "$CC" --help | head -n 1)" = "clock-check.sh: the clock and the deploy state, for the two deploy-window ask rules of SKILL.md (The tick: No owner question before a deploy is spawned; Deploy windows)" ]'
ledger "$(jq -cn --argjson r "$(printf "$W_ROW" "staging" w-deploy-a)" '{workers: {"w-deploy-a": {state: "running"}}, deployWindows: [$r]}')"
before="$(cd "$CM_HOME" && find . -type f -exec sha256sum {} + | sort | sha256sum; ls -A "$CM_HOME" | tr '\n' ' ')"
run utc.yaml 2000-01-01T09:30:00Z
after="$(cd "$CM_HOME" && find . -type f -exec sha256sum {} + | sort | sha256sum; ls -A "$CM_HOME" | tr '\n' ' ')"
check "it changes nothing under CM_HOME (a ledger present is byte for byte the same, no file added)" '[ -n "$before" ] && [ "$before" = "$after" ]' "$before / $after"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
