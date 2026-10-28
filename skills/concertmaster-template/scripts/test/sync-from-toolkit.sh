#!/usr/bin/env bash
# sync-from-toolkit.sh test: scratch project directories only. Asserts the engine is copied or
# refreshed, the project's config.yaml and other config.*.yaml are byte-identical afterwards, the
# SKILL.md frontmatter of the project survives, a dry run changes nothing, project-only files are
# kept unless --prune, a second run is a no-op, and bad input is refused. The project overlay
# (references/project-local.md) is created as a stub with one section per hook point, then never
# written, listed or pruned again, and the sync reports hook points it lacks and sections that
# match no hook point; every hook marker in the engine docs is documented in references/overlay.md.
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

# --- overlay: stub on first sync, one section per hook point --------------------------------
OV="$T/references/project-local.md"
marker_re='^[[:space:]]*<!-- project-local: \([a-z0-9][a-z0-9-]*\) -->[[:space:]]*$'
HOOKS="$(sed -n "s/$marker_re/\\1/p" "$SRC/SKILL.md" "$SRC"/references/*.md | awk '!seen[$0]++')"
check "overlay: engine docs declare hook points" "$([ "$(printf '%s\n' "$HOOKS" | grep -c .)" -ge 5 ] && echo yes)" "yes"
check "overlay: SKILL.md has a tick-extra hook" "$(printf '%s\n' "$HOOKS" | grep -cx tick-extra)" "1"
check "overlay: lanes.md has a brief-footer hook" "$(sed -n "s/$marker_re/\\1/p" "$SRC/references/lanes.md" | grep -cx brief-footer)" "1"
check "overlay: stub created" "$([ -f "$OV" ] && echo yes)" "yes"
case "$out" in *"create  references/project-local.md"*) echo "ok   overlay: first sync says it creates the stub" ;; *) echo "FAIL create line: $out"; fail=1 ;; esac
missing_sec=""; undocumented=""
for h in $HOOKS; do
  [ "$h" = lane ] && continue
  grep -qx "## $h" "$OV" || missing_sec="$missing_sec $h"
done
for h in $HOOKS; do grep -qF "| \`$h\` |" "$SRC/references/overlay.md" || undocumented="$undocumented $h"; done
check "overlay: stub has a section for every hook point" "$missing_sec" ""
check "overlay: every hook point is documented in overlay.md" "$undocumented" ""
check "overlay: stub has the pending-upstream section" "$(grep -cx '## pending-upstream' "$OV")" "1"
check "overlay: stub has no bare lane section" "$(grep -c '^## lane' "$OV")" "0"
check "overlay: SKILL.md points at the overlay" "$(grep -c 'references/project-local.md' "$T/SKILL.md" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"

# --- second run is a no-op ---------------------------------------------------------------------
STUB_HASH="$(cksum < "$OV")"
out="$("$SYNC" "$T" 2>&1)"
case "$out" in *"0 added, 0 updated"*) echo "ok   second run changes nothing" ;; *) echo "FAIL second run: $out"; fail=1 ;; esac
check "second run: stub untouched" "$(cksum < "$OV")" "$STUB_HASH"
case "$out" in *"keep    references/project-local.md (project-owned"*) echo "ok   second run: overlay listed as kept" ;; *) echo "FAIL keep overlay line: $out"; fail=1 ;; esac
case "$out" in *"has no section"*|*"match no hook point"*) echo "FAIL fresh stub reported as incomplete: $out"; fail=1 ;; *) echo "ok   second run: complete stub reports nothing" ;; esac

# --- the project fills its overlay: never overwritten, gaps and orphans reported ---------------
sed -i.tmp '/^## merge-gate$/d' "$OV" && rm -f -- "${OV:?}.tmp"
cat >> "$OV" <<'EOF'

## lane: lane-a
- Run local/acme-app-smoke.sh before every cm:merge-ready.

## retired-hook
- An addendum whose hook point the engine no longer has.

## brief-footer
```text
## not-a-section
```
EOF
OV_HASH="$(cksum < "$OV")"
out="$("$SYNC" --dry-run "$T" 2>&1)"
case "$out" in *"has no section for these hook points"*"  merge-gate"*) echo "ok   dry run: missing hook section reported" ;; *) echo "FAIL missing section report: $out"; fail=1 ;; esac
case "$out" in *"match no hook point"*"  retired-hook"*) echo "ok   dry run: orphaned section reported" ;; *) echo "FAIL orphan report: $out"; fail=1 ;; esac
case "$out" in *"  not-a-section"*) echo "FAIL fenced heading read as a section"; fail=1 ;; *) echo "ok   dry run: headings in code fences are content" ;; esac
case "$out" in *"  lane"*|*"  pending-upstream"*) echo "FAIL lane or pending-upstream reported: $out"; fail=1 ;; *) echo "ok   dry run: lane and pending-upstream sections are valid" ;; esac
case "$out" in *"keep    references/project-local.md (not in the toolkit"*) echo "FAIL overlay listed as a prunable extra"; fail=1 ;; *) echo "ok   dry run: overlay is not an extra file" ;; esac

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
check "drift: project overlay untouched" "$(cksum < "$OV")" "$OV_HASH"
case "$out" in *"documents keys your config.yaml does not set"*"release_tester.prod_url"*) echo "ok   new config keys are reported" ;; *) echo "FAIL missing-key report: $out"; fail=1 ;; esac
out="$("$SYNC" "$T" 2>&1)"
case "$out" in *"0 added, 0 updated"*) echo "ok   run after drift repair changes nothing" ;; *) echo "FAIL repeat after drift: $out"; fail=1 ;; esac

# --- prune --------------------------------------------------------------------------------------
"$SYNC" --prune "$T" >/dev/null 2>&1
check "prune: project-only script removed" "$([ -f "$T/scripts/acme-extra.sh" ] && echo yes || echo no)" "no"
check "prune: backup file kept" "$([ -f "$T/scripts/lib.sh.bak-20260101" ] && echo yes)" "yes"
check "prune: config.yaml untouched" "$(cksum < "$T/config.yaml")" "$CFG_BEFORE"
check "prune: config.staging.yaml untouched" "$(cksum < "$T/config.staging.yaml")" "$CFG2_BEFORE"
check "prune: project overlay kept, byte-identical" "$(cksum < "$OV" 2>/dev/null)" "$OV_HASH"

# --- dry run on a fresh project: announces the stub, writes nothing ------------------------------
T2="$ROOT/project2/.agents/skills/concertmaster"
mkdir -p "$T2"; printf 'project:\n  name: Acme\n' > "$T2/config.yaml"
out="$("$SYNC" --dry-run "$T2" 2>&1)"
case "$out" in *"create  references/project-local.md"*) echo "ok   fresh dry run: lists the stub it would create" ;; *) echo "FAIL fresh dry run: $out"; fail=1 ;; esac
check "fresh dry run: no stub written" "$([ -e "$T2/references/project-local.md" ] && echo yes || echo no)" "no"

# --- refusals ------------------------------------------------------------------------------------
"$SYNC" "$ROOT/nope" >/dev/null 2>&1; check "missing target refused (exit 2)" "$?" "2"
"$SYNC" "$SRC" >/dev/null 2>&1; check "source as target refused (exit 2)" "$?" "2"
"$SYNC" --source "$ROOT" "$T" >/dev/null 2>&1; check "non-template source refused (exit 2)" "$?" "2"
"$SYNC" >/dev/null 2>&1; check "no target prints usage (exit 2)" "$?" "2"
"$SYNC" --bogus "$T" >/dev/null 2>&1; check "unknown option refused (exit 2)" "$?" "2"

exit $fail
