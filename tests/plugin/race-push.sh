#!/usr/bin/env bash
# Concurrency harness for sidecar_remote.sh, run as a child of the bats test
# (background jobs do not survive bats' stdout capture reliably).
#
# usage: race-push.sh <scripts-dir> <clone> <slug> <n>
# prints: one exit code per racer, newline separated
set -uo pipefail
SCRIPTS="$1"; CLONE="$2"; SLUG="$3"; N="${4:-6}"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

for i in $(seq 1 "$N"); do
  (
    T="$D/src$i"; mkdir -p "$T"
    printf '{"phase":"E%s","epics":{}}' "$i" > "$T/state.json"
    "$SCRIPTS/sidecar_remote.sh" push "$CLONE" "$SLUG" "$T" >/dev/null 2>&1
    echo "$?" > "$D/rc$i"
  ) &
done
wait

for i in $(seq 1 "$N"); do
  cat "$D/rc$i" 2>/dev/null || echo "missing"
done
