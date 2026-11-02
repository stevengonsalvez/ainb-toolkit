#!/usr/bin/env bash
# ledger-guard.sh: is the ledger this session would use this project's? Exit 0 yes (or the project
# id is unset, or there is no ledger yet), 3 no (the reason on stderr names the project the ledger
# belongs to and the one running). Reads one JSON field, writes nothing.
#
#   scripts/ledger-guard.sh [ledger path]     # default: $CM_LEDGER, else $CM_HOME/ledger.json
#
# Tick step 1 runs it first, before any script that reads the ledger (references/ledger.md § Project
# guard). Rules are cm_ledger_guard in lib.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
case "${1:-}" in -h|--help) sed -n '2,9p' "$0"; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { cm_warn "missing dependency: jq"; exit 1; }
cm_ledger_guard ${1:+"$1"}
