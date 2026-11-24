#!/usr/bin/env bash
# input-migrate-manifest.sh: the DRY-RUN migration manifest of the typed input boundary (references/input-contract.md, section 8).
# For the ledger it lists what must be settled before a later stamp verb may set schemaVersion 2: per worker the keys missing (state, standing,
# host), a path alias (worktree, worktreePath) to move to `path`, a legacy state spelling, invalid fields and unreadable rows; the follow-ups whose
# `issue` is text ("#12", "12"); the asks with no usable id (blank, missing, duplicate); the rows that have a terminal and no path; a repeated key;
# EVERY member of asks, followUps, lanes, hosts and deployWindows that is unreadable, invalid or lacks a required field (with its identity and
# reason); and a required container (workers, asks, followUps, lanes) that is absent or null.
# It READS the ledger and WRITES NOTHING (no ledger write, no lock, no backup). Exit 0 when the ledger is clean (nothing to settle), 1 when there
# is something to settle, 2 when the ledger cannot be read.
#
#   scripts/input-migrate-manifest.sh [--json] [ledger]     # default: $CM_LEDGER, else $CM_HOME/ledger.json
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
JSON=0
case "${1:-}" in -h|--help) sed -n '2,9p' "$0"; exit 0 ;; --json) JSON=1; shift ;; esac
command -v jq >/dev/null 2>&1 || { cm_warn "missing dependency: jq"; exit 2; }
L="${1:-$(cm_ledger_path)}"
[ -r "$L" ] || { cm_warn "cannot read the ledger $L"; exit 2; }
# ONE read: the view, the document and the repeated-key scan all come from the same snapshot (cm_input_bundle)
bundle="$(cm_input_bundle "$L")" || { cm_warn "the ledger $L is not one readable JSON object (or the repeated-key scan failed)"; exit 2; }
view="$(cm_input_view_of "$bundle")" || { cm_warn "the ledger $L could not be typed"; exit 2; }
vf="$(mktemp "${TMPDIR:-/tmp}/cm-manifest.XXXXXX")" || { cm_warn "no temp file"; exit 2; }
printf '%s' "$view" > "$vf"
out="$(printf '%s' "$bundle" | jq -c -L "$HERE" --slurpfile v "$vf" 'include "input-view"; . as $b | iv_manifest($b.doc; $v[0]) | .repeatedKeys = ($b.dups | map(map(tostring) | join("."))) | .clean = (.clean and ($b.dups | length) == 0) | .counts.repeatedKeys = ($b.dups | length)')" || { rm -f -- "$vf"; cm_warn "manifest failed"; exit 2; }
rm -f -- "$vf"
if [ "$JSON" = 1 ]; then printf '%s\n' "$out"
else
  printf '%s' "$out" | jq -r '
    "migration manifest (dry run, nothing written): schemaVersion \(if .schemaVersionStatus == "missing" then "absent (legacy, 1)" else (.schemaVersion // "invalid" | tostring) end), \(.counts.workers) workers",
    (.workers[] | "  worker \(.worker): " + ([ (if .rowBad then "unreadable row (\(.rowBad))" else empty end),
        (if (.missing | length) > 0 then "missing " + (.missing | join(", ")) else empty end),
        (if .aliasToMove then "move \(.aliasToMove.from) to path" else empty end),
        (if .stateSpelling then "state spelling \(.stateSpelling.from) is \(.stateSpelling.to)" else empty end),
        (if (.invalid | length) > 0 then "invalid " + ([.invalid[] | "\(.field) (\(.reason))"] | join(", ")) else empty end),
        (if .terminalOnly then "terminal and no path" else empty end) ] | join("; "))),
    (.parentProblems[] | "  worker \(.worker): \(.why) (parent \(.parent | tojson))"),
    (.danglingParents[] | "  worker \(.worker): parent \(.parent) has no row (treated as the root of its own family; reported, not a blocker)"),
    (.duplicateFollowUpIds[] | "  follow-up id \(.id) is used \(.count) times"),
    (.followUpIssues[] | "  follow-up \(.followUp): issue \"\(.issue)\" is text, write \(.asNumber)"),
    (.asksWithoutId[] | "  ask \(.ask): \(.reason)"),
    (.containerIssues[] | "  \(.sourcePath): \(.reason)"),
    (.missingContainers[] | "  \(.): absent or null, a stamped ledger needs it (an empty one is fine)"),
    (.members[] | "  \(.member): " + ([ (if .rowBad then "unreadable (\(.rowBad))" else empty end),
        (if (.missing | length) > 0 then "missing " + (.missing | join(", ")) else empty end),
        (if (.invalid | length) > 0 then "invalid " + ([.invalid[] | "\(.field) (\(.reason))"] | join(", ")) else empty end) ] | join("; "))),
    (.repeatedKeys[] | "  key written twice: \(.)"),
    (if .clean then "clean: nothing to settle before schemaVersion 2" else "not clean: \(.counts.workersToSettle) workers, \(.counts.followUpIssuesToFix) follow-up issues, \(.counts.asksToFix) asks, \(.counts.membersToSettle) other members, \(.counts.containerIssues) containers, \(.counts.missingContainers) missing containers, \(.counts.repeatedKeys) repeated keys, \(.counts.parentProblems) parent chains, \(.counts.duplicateFollowUpIds) repeated follow-up ids to settle" end)'
fi
printf '%s' "$out" | jq -e '.clean' >/dev/null 2>&1
