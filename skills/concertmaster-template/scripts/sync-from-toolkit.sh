#!/usr/bin/env bash
# sync-from-toolkit.sh: pull the concertmaster engine from the toolkit into a project's
# concertmaster skill directory WITHOUT touching the project's own config.
#
#   scripts/sync-from-toolkit.sh [--dry-run] [--prune] [--source DIR | --fetch [--ref REF]] <target-skill-dir>
#
#   <target-skill-dir>   the project's copy, e.g. <repo>/.agents/skills/concertmaster
#   --source DIR         the toolkit's skills/concertmaster-template (default: the tree this
#                        script sits in; also CM_TOOLKIT_SKILL)
#   --fetch              shallow-clone the toolkit into a temp dir and use that instead
#                        (CM_TOOLKIT_URL, default https://github.com/stevengonsalvez/ainb-toolkit)
#   --ref REF            branch or tag for --fetch (default main)
#   --dry-run            print what would change, change nothing
#   --prune              also remove engine files (under scripts/, references/, companions/)
#                        that the toolkit no longer ships; files only the project has are
#                        listed otherwise, never deleted
#
# Never touched in the target: config.yaml, every other config.*.yaml (config.example.yaml
# excepted, it is documentation and is refreshed), *.bak* files, anything outside the engine
# directories and files. SKILL.md keeps the target's own frontmatter (name, description); only
# its body is replaced. After the copy it lists config keys the example now documents that the
# target's config.yaml lacks, and writes <target>/.synced-from (source revision and date).
# references/project-local.md is the project's overlay (references/overlay.md): never
# overwritten and never pruned; when missing it is created as a stub with one section per
# hook point the engine docs declare. Each run (dry runs included) lists it as create or
# keep, then names hook points it has no section for and sections that match no hook point.
# Re-copy the installed hook scripts separately (references/hooks-install.md): this updates the
# skill tree, not ~/.concertmaster/bin.
# Exit: 0 done, 1 failed, 2 bad usage.
set -uo pipefail

die() { printf 'sync-from-toolkit: %s\n' "$*" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^# Exit:/p' "$0"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${CM_TOOLKIT_SKILL:-$(cd "$HERE/.." && pwd)}"
URL="${CM_TOOLKIT_URL:-https://github.com/stevengonsalvez/ainb-toolkit}"
DRY=0; PRUNE=0; FETCH=0; REF=main; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --prune) PRUNE=1 ;;
    --source) [ $# -ge 2 ] || die "--source needs a directory" 2; SRC="$2"; shift ;;
    --fetch) FETCH=1 ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a branch or tag" 2; REF="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" 2 ;;
    *) [ -z "$TARGET" ] || die "one target directory only" 2; TARGET="$1" ;;
  esac
  shift
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }
command -v tar >/dev/null 2>&1 || die "tar is required"
[ -d "$TARGET" ] || die "target is not a directory: $TARGET (create it and put your config.yaml there first)" 2
TARGET="$(cd "$TARGET" && pwd)"

TMP=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { [ -z "$TMP" ] || rm -rf -- "${TMP:?}"; }
trap cleanup EXIT

if [ "$FETCH" = 1 ]; then
  command -v git >/dev/null 2>&1 || die "git is required for --fetch"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-sync.XXXXXX")" || die "cannot create a temp dir"
  git clone -q --depth 1 --branch "$REF" "$URL" "$TMP/toolkit" 2>/dev/null || die "cannot clone $URL at $REF"
  SRC="$TMP/toolkit/skills/concertmaster-template"
fi
[ -f "$SRC/SKILL.md" ] && [ -d "$SRC/scripts" ] || die "not a concertmaster template tree: $SRC" 2
SRC="$(cd "$SRC" && pwd)"
[ "$SRC" != "$TARGET" ] || die "source and target are the same directory" 2
case "$TARGET/" in "$SRC"/*) die "target is inside the source tree" 2 ;; esac

# ---- what is the engine -----------------------------------------------------------
# Directories copied whole, and the top-level files copied one by one. Everything else in the
# source (and anything the project keeps beside them) is out of scope.
ENGINE_DIRS="scripts references companions"
ENGINE_FILES="SKILL.md README.md config.example.yaml"
# The project's overlay: owned by the project, never copied, overwritten or pruned.
OVERLAY="references/project-local.md"
QUALIFIED_HOOKS="lane"          # sections named "## <hook>: <qualifier>" only, no stub heading
RESERVED_SECTIONS="pending-upstream"

excluded() { # $1 = path relative to the skill root
  case "$1" in
    *.bak|*.bak-*|*.bak.*|*/.git/*|.git/*|*.orig|*.rej) return 0 ;;
    config.yaml|config.local.yaml) return 0 ;;
    "$OVERLAY") return 0 ;;
    config.example.yaml) return 1 ;;
    config.*.yaml|*/config.yaml) return 0 ;;
  esac
  return 1
}

list_source() { # relative paths of every engine file in the source
  local d f
  for f in $ENGINE_FILES; do [ -f "$SRC/$f" ] && printf '%s\n' "$f"; done
  for d in $ENGINE_DIRS; do
    [ -d "$SRC/$d" ] && (cd "$SRC" && find "$d" -type f | LC_ALL=C sort)
  done
}

# Cannot be fooled by a config file the project keeps: its hash before and after must match.
cfg_hash() { if [ -f "$TARGET/config.yaml" ]; then cksum < "$TARGET/config.yaml"; else echo none; fi; }
BEFORE="$(cfg_hash)"
ov_hash() { if [ -f "$TARGET/$OVERLAY" ]; then cksum < "$TARGET/$OVERLAY"; else echo none; fi; }
OV_BEFORE="$(ov_hash)"

# ---- overlay ------------------------------------------------------------------------
# hook ids declared by the engine docs under $1: lines holding only the marker
# <!-- project-local: <id> -->, SKILL.md first, in document order
hook_points() {
  local f
  for f in "$1/SKILL.md" "$1"/references/*.md; do
    [ -f "$f" ] || continue
    case "$f" in */"$OVERLAY") continue ;; esac
    sed -n 's/^[[:space:]]*<!-- project-local: \([a-z0-9][a-z0-9-]*\) -->[[:space:]]*$/\1/p' "$f"
  done | awk '!seen[$0]++'
}
# hook part of every "## <hook>[: <qualifier>]" heading in an overlay, fenced code skipped
overlay_sections() {
  awk '/^(```|~~~)/ { fence = !fence; next }
       !fence && /^## / { s = substr($0, 4); sub(/:.*/, "", s); sub(/[ \t]+$/, "", s); if (s != "" && !seen[s]++) print s }' "$1"
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
write_stub() { # $1 = file to write
  {
    cat <<'EOF'
# Project-local overlay

Owned by this project. scripts/sync-from-toolkit.sh created this file and never writes
it again; the engine files beside it are overwritten on every sync, so project rules
belong here, not in SKILL.md or another engine file.

Each "## <hook>" section below is applied where the engine docs carry the hook marker
for <hook> (SKILL.md § Project overlay). Lane brief addenda go in "## lane: <label>"
sections, one per lane. An empty section adds nothing. Addenda add or tighten; they
never loosen a hard rule, the merge gate or a guardrail. Text above the first section
is never applied.

What may go here and what must be a toolkit PR instead: references/overlay.md.
List toolkit PRs this project waits on under "## pending-upstream".
EOF
    hook_points "$SRC" | while IFS= read -r h; do
      in_list "$h" "$QUALIFIED_HOOKS" && continue
      printf '\n## %s\n' "$h"
    done
    printf '\n## pending-upstream\n'
  } > "$1"
}
overlay_report() { # hook points with no section, sections with no hook point
  local hooks secs missing orphan h
  [ -f "$TARGET/$OVERLAY" ] || return 0
  hooks="$(hook_points "$SRC")"; secs="$(overlay_sections "$TARGET/$OVERLAY")"
  missing=""; orphan=""
  for h in $hooks; do
    in_list "$h" "$QUALIFIED_HOOKS" && continue
    printf '%s\n' "$secs" | grep -qxF -- "$h" || missing="$missing $h"
  done
  for h in $secs; do
    in_list "$h" "$RESERVED_SECTIONS" && continue
    printf '%s\n' "$hooks" | grep -qxF -- "$h" || orphan="$orphan $h"
  done
  if [ -n "$missing" ]; then
    printf '%s has no section for these hook points (nothing is added there until you write one):\n' "$OVERLAY"
    for h in $missing; do printf '  %s\n' "$h"; done
  fi
  if [ -n "$orphan" ]; then
    printf '%s sections that match no hook point in the engine (never applied; move or delete them):\n' "$OVERLAY"
    for h in $orphan; do printf '  %s\n' "$h"; done
  fi
}

# line number of the closing --- of a file's frontmatter, empty when it has none
fm_end() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{print NR; exit}' "$1"; }

added=0; updated=0; same=0; skipped=0
PLAN="$(mktemp "${TMPDIR:-/tmp}/cm-sync-plan.XXXXXX")" || die "cannot create a temp file"
trap 'cleanup; rm -f -- "${PLAN:?}"' EXIT

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if excluded "$rel"; then skipped=$((skipped + 1)); continue; fi
  if [ "$rel" = SKILL.md ] && [ -f "$TARGET/SKILL.md" ]; then
    # keep the target's frontmatter, take the source's body
    t_end="$(fm_end "$TARGET/SKILL.md")"; s_end="$(fm_end "$SRC/SKILL.md")"
    if [ -n "$t_end" ] && [ -n "$s_end" ]; then
      { head -n "$t_end" "$TARGET/SKILL.md"; tail -n +"$((s_end + 1))" "$SRC/SKILL.md"; } > "$PLAN.skill"
      if cmp -s "$PLAN.skill" "$TARGET/SKILL.md"; then same=$((same + 1)); rm -f -- "${PLAN:?}.skill"
      else updated=$((updated + 1)); printf 'update  SKILL.md (body only, your frontmatter kept)\n'; printf 'SKILL.md\n' >> "$PLAN.splice"; fi
      continue
    fi
  fi
  if [ ! -e "$TARGET/$rel" ]; then added=$((added + 1)); printf 'add     %s\n' "$rel"; printf '%s\n' "$rel" >> "$PLAN"
  elif cmp -s "$SRC/$rel" "$TARGET/$rel"; then same=$((same + 1))
  else updated=$((updated + 1)); printf 'update  %s\n' "$rel"; printf '%s\n' "$rel" >> "$PLAN"; fi
done < <(list_source)

# files only the project has inside the engine directories
extra=0
for d in $ENGINE_DIRS; do
  [ -d "$TARGET/$d" ] || continue
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    excluded "$rel" && continue
    [ -e "$SRC/$rel" ] && continue
    extra=$((extra + 1))
    if [ "$PRUNE" = 1 ]; then printf 'prune   %s\n' "$rel"; printf '%s\n' "$rel" >> "$PLAN.prune"
    else printf 'keep    %s (not in the toolkit; --prune removes it)\n' "$rel"; fi
  done < <(cd "$TARGET" && find "$d" -type f | LC_ALL=C sort)
done

overlay_new=0
if [ -e "$TARGET/$OVERLAY" ] || [ -L "$TARGET/$OVERLAY" ]; then
  printf 'keep    %s (project-owned overlay, never synced)\n' "$OVERLAY"
else
  overlay_new=1; printf 'create  %s (overlay stub; the project owns it from now on)\n' "$OVERLAY"
fi

if [ "$DRY" = 1 ]; then
  overlay_report
  printf 'dry run: %s to add, %s to update, %s unchanged, %s excluded, %s extra. Nothing written.\n' "$added" "$updated" "$same" "$skipped" "$extra"
  rm -f -- "${PLAN:?}.skill" "${PLAN:?}.splice" "${PLAN:?}.prune"
  exit 0
fi

# ---- apply ------------------------------------------------------------------------
if [ -s "$PLAN" ]; then
  (cd "$SRC" && tar -cf - -T "$PLAN") | (cd "$TARGET" && tar -xf -) || die "copy failed"
fi
if [ -f "$PLAN.splice" ]; then cat "$PLAN.skill" > "$TARGET/SKILL.md" || die "SKILL.md write failed"; fi
if [ -f "$PLAN.prune" ]; then
  while IFS= read -r rel; do [ -n "$rel" ] && rm -f -- "${TARGET:?}/${rel:?}"; done < "$PLAN.prune"
  for d in $ENGINE_DIRS; do [ -d "$TARGET/$d" ] && find "${TARGET:?}/$d" -type d -empty -delete 2>/dev/null; done
fi
rm -f -- "${PLAN:?}.skill" "${PLAN:?}.splice" "${PLAN:?}.prune"
if [ "$overlay_new" = 1 ]; then
  mkdir -p "$TARGET/references" || die "cannot create $TARGET/references"
  write_stub "$TARGET/$OVERLAY" || die "cannot write $OVERLAY"
fi

# provenance
rev="unknown"
if command -v git >/dev/null 2>&1 && git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then rev="$(git -C "$SRC" rev-parse --short HEAD)"; fi
printf 'source: %s\nrevision: %s\nsynced: %s\n' "$URL" "$rev" "$(date -u +%FT%TZ)" > "$TARGET/.synced-from"

AFTER="$(cfg_hash)"
[ "$BEFORE" = "$AFTER" ] || die "config.yaml changed during the sync, which must never happen: restore it from version control"
[ "$overlay_new" = 1 ] || [ "$OV_BEFORE" = "$(ov_hash)" ] || die "$OVERLAY changed during the sync, which must never happen: restore it from version control"

printf 'synced %s: %s added, %s updated, %s unchanged, %s excluded, %s extra. config.yaml untouched.\n' "$TARGET" "$added" "$updated" "$same" "$skipped" "$extra"
overlay_report

# config keys the example documents that the project's config.yaml does not have yet
if [ -f "$TARGET/config.yaml" ] && command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  keys() { yq -o=json -I=0 '.' "$1" 2>/dev/null | jq -r '[paths(type != "object") | select(all(type == "string")) | join(".")] | unique | .[]' 2>/dev/null; }
  missing="$(comm -23 <(keys "$TARGET/config.example.yaml" | LC_ALL=C sort) <(keys "$TARGET/config.yaml" | LC_ALL=C sort))"
  if [ -n "$missing" ]; then
    printf 'config.example.yaml documents keys your config.yaml does not set (defaults apply until you add them):\n'
    printf '%s\n' "$missing" | while IFS= read -r k; do printf '  %s\n' "$k"; done
  fi
fi
printf 'next: re-copy the installed hook scripts on each host (references/hooks-install.md), then run the tests in %s/scripts/test/\n' "$TARGET"
exit 0
