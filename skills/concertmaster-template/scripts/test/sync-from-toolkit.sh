#!/usr/bin/env bash
# sync-from-toolkit.sh test: scratch project directories only. Asserts the engine is copied or
# refreshed, the project's config.yaml and other config.*.yaml are byte-identical afterwards, the
# SKILL.md frontmatter of the project survives, a dry run changes nothing, project-only files are
# kept unless --prune, a second run is a no-op, and bad input is refused.
#
#   scripts/test/sync-from-toolkit.sh         # exit 0 when every case passes
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
SYNC="$SRC/scripts/sync-from-toolkit.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-sync-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
tree_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs cksum | cksum); }

T="$ROOT/project/.agents/skills/concertmaster"
mkdir -p "$T"
printf 'schema: concertmaster.config/v1\nproject:\n  name: Acme\n' > "$T/config.yaml"
printf 'project:\n  name: Acme Staging\n' > "$T/config.staging.yaml"
CFG_BEFORE="$(cksum < "$T/config.yaml")"; CFG2_BEFORE="$(cksum < "$T/config.staging.yaml")"

# --- fresh project: only a config.yaml so far -----------------------------------------------
out="$("$SYNC" "$T" 2>&1)"; rc=$?
check "fresh target: exit 0" "$rc" "0"
check "fresh target: scripts copied" "$([ -x "$T/scripts/lib.sh" ] || [ -f "$T/scripts/lib.sh" ] && echo yes)" "yes"
check "fresh target: executable bit kept" "$([ -x "$T/scripts/mc-emit.sh" ] && echo yes)" "yes"
check "fresh target: references copied" "$([ -f "$T/references/lanes.md" ] && echo yes)" "yes"
check "fresh target: example config copied" "$([ -f "$T/config.example.yaml" ] && echo yes)" "yes"
check "fresh target: config.yaml untouched" "$(cksum < "$T/config.yaml")" "$CFG_BEFORE"
check "fresh target: config.staging.yaml untouched" "$(cksum < "$T/config.staging.yaml")" "$CFG2_BEFORE"
check "fresh target: no config.yaml created from the example" "$([ -f "$T/config.yaml" ] && grep -c Acme "$T/config.yaml")" "1"
check "fresh target: provenance file written" "$(grep -c '^synced:' "$T/.synced-from")" "1"
case "$out" in *"config.yaml untouched"*) echo "ok   fresh target: summary says config untouched" ;; *) echo "FAIL summary"; fail=1 ;; esac

# --- second run is a no-op ---------------------------------------------------------------------
out="$("$SYNC" "$T" 2>&1)"
case "$out" in *"0 added, 0 updated"*) echo "ok   second run changes nothing" ;; *) echo "FAIL second run: $out"; fail=1 ;; esac

# --- drift: edited engine file, deleted engine file, project frontmatter, project-only files ---
printf '# local edit\n' >> "$T/scripts/lib.sh"
rm -f -- "${T:?}/scripts/digest.sh"
printf -- '---\nname: concertmaster\ndescription: Acme concertmaster\n---\nstale body\n' > "$T/SKILL.md"
printf '#!/usr/bin/env bash\necho extra\n' > "$T/scripts/acme-extra.sh"
printf 'old\n' > "$T/scripts/lib.sh.bak-20260101"
printf 'project:\n  name: Acme Edited\n' > "$T/config.yaml"; CFG_BEFORE="$(cksum < "$T/config.yaml")"

before="$(tree_hash "$T")"
out="$("$SYNC" --dry-run "$T" 2>&1)"
check "dry run: tree unchanged" "$(tree_hash "$T")" "$before"
case "$out" in *"update  scripts/lib.sh"*"add     scripts/digest.sh"*|*"add     scripts/digest.sh"*"update  scripts/lib.sh"*) echo "ok   dry run: lists the update and the add" ;; *) echo "FAIL dry run listing: $out"; fail=1 ;; esac
case "$out" in *"keep    scripts/acme-extra.sh"*) echo "ok   dry run: project-only file is kept" ;; *) echo "FAIL keep listing"; fail=1 ;; esac

out="$("$SYNC" "$T" 2>&1)"
check "drift: edited script restored" "$(cmp -s "$T/scripts/lib.sh" "$SRC/scripts/lib.sh" && echo same)" "same"
check "drift: deleted script restored" "$([ -f "$T/scripts/digest.sh" ] && echo yes)" "yes"
check "drift: config.yaml untouched" "$(cksum < "$T/config.yaml")" "$CFG_BEFORE"
check "drift: project frontmatter kept" "$(sed -n 2p "$T/SKILL.md")" "name: concertmaster"
check "drift: project description kept" "$(sed -n 3p "$T/SKILL.md")" "description: Acme concertmaster"
check "drift: SKILL.md body replaced" "$(grep -c 'stale body' "$T/SKILL.md")" "0"
check "drift: SKILL.md body is the toolkit's" "$(grep -c '^# Concertmaster' "$T/SKILL.md")" "1"
check "drift: project-only script kept" "$([ -f "$T/scripts/acme-extra.sh" ] && echo yes)" "yes"
check "drift: backup file kept" "$([ -f "$T/scripts/lib.sh.bak-20260101" ] && echo yes)" "yes"
case "$out" in *"documents keys your config.yaml does not set"*"release_tester.prod_url"*) echo "ok   new config keys are reported" ;; *) echo "FAIL missing-key report: $out"; fail=1 ;; esac
out="$("$SYNC" "$T" 2>&1)"
case "$out" in *"0 added, 0 updated"*) echo "ok   run after drift repair changes nothing" ;; *) echo "FAIL repeat after drift: $out"; fail=1 ;; esac

# --- prune --------------------------------------------------------------------------------------
"$SYNC" --prune "$T" >/dev/null 2>&1
check "prune: project-only script removed" "$([ -f "$T/scripts/acme-extra.sh" ] && echo yes || echo no)" "no"
check "prune: backup file kept" "$([ -f "$T/scripts/lib.sh.bak-20260101" ] && echo yes)" "yes"
check "prune: config.yaml untouched" "$(cksum < "$T/config.yaml")" "$CFG_BEFORE"
check "prune: config.staging.yaml untouched" "$(cksum < "$T/config.staging.yaml")" "$CFG2_BEFORE"

# --- refusals ------------------------------------------------------------------------------------
"$SYNC" "$ROOT/nope" >/dev/null 2>&1; check "missing target refused (exit 2)" "$?" "2"
"$SYNC" "$SRC" >/dev/null 2>&1; check "source as target refused (exit 2)" "$?" "2"
"$SYNC" --source "$ROOT" "$T" >/dev/null 2>&1; check "non-template source refused (exit 2)" "$?" "2"
"$SYNC" >/dev/null 2>&1; check "no target prints usage (exit 2)" "$?" "2"
"$SYNC" --bogus "$T" >/dev/null 2>&1; check "unknown option refused (exit 2)" "$?" "2"

exit $fail
