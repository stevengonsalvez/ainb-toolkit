#!/usr/bin/env bash
# Close/annotate beads on the remote beads branch via git plumbing — no checkout touched.
# Safe to run from any worktree; safe under concurrent branches.
#
# Usage:
#   beads_remote.sh close <repo-dir> <commit-msg> <id1>[,<id2>,...] <note>
#   beads_remote.sh apply <repo-dir> <commit-msg> <python-edit-file>
#
# 'close': sets status=closed + closed_at/updated_at=now, APPENDS <note> to
#          existing notes (audit trail preserved) on each id.
# 'apply': runs your python file with BEADS_IN/BEADS_OUT env vars for arbitrary
#          JSONL edits (always edit with a JSON parser, never sed/awk).
# Default branch is main; set BEADS_BRANCH=master (etc.) to override. If the
# branch is push-protected, commit beads on your epic branch instead.
set -euo pipefail

MODE="${1:?mode: close|apply}"; REPO="${2:?repo dir}"; MSG="${3:?commit msg}"
BRANCH="${BEADS_BRANCH:-main}"
cd "$REPO"
git fetch origin "$BRANCH" --quiet
ORIGIN=$(git rev-parse "origin/$BRANCH")
TMP_IN=$(mktemp) TMP_OUT=$(mktemp) IDX=$(mktemp -u)
trap 'rm -f "$TMP_IN" "$TMP_OUT" "$IDX"' EXIT
git show "origin/$BRANCH":.beads/issues.jsonl > "$TMP_IN"

if [ "$MODE" = "close" ]; then
  IDS="${4:?comma-separated bead ids}"; NOTE="${5:?evidence note}"
  BEADS_IN="$TMP_IN" BEADS_OUT="$TMP_OUT" IDS="$IDS" NOTE="$NOTE" python3 - <<'PY'
import json, os, datetime
ids = set(os.environ['IDS'].split(','))
now = datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec='seconds')
out, hit = [], set()
lines = open(os.environ['BEADS_IN']).read().splitlines()
blanks = [i + 1 for i, l in enumerate(lines) if not l.strip()]
if blanks:
    raise SystemExit(f"corrupted input JSONL: blank line(s) at {blanks} — refusing to normalize")
for ln in lines:
    o = json.loads(ln)
    if o.get('id') in ids:
        o['status'] = 'closed'; o['closed_at'] = now; o['updated_at'] = now
        prior = (o.get('notes') or '').strip()
        o['notes'] = (prior + '\n---\n' if prior else '') + os.environ['NOTE']
        hit.add(o['id'])
    out.append(json.dumps(o, separators=(',', ':'), ensure_ascii=False))
missing = ids - hit
if missing:
    raise SystemExit(f"beads not found: {missing}")
open(os.environ['BEADS_OUT'], 'w').write('\n'.join(out) + '\n')
print(f"closed: {sorted(hit)}")
PY
elif [ "$MODE" = "apply" ]; then
  EDIT="${4:?python edit file}"
  BEADS_IN="$TMP_IN" BEADS_OUT="$TMP_OUT" python3 "$EDIT"
else
  echo "unknown mode: $MODE" >&2; exit 1
fi

# Sanity: parseable, no blank lines, line count sane
python3 - "$TMP_OUT" "$TMP_IN" <<'PY'
import json, sys
out_lines = [l for l in open(sys.argv[1])]
in_lines = [l for l in open(sys.argv[2]) if l.strip()]
assert all(l.strip() for l in out_lines), "blank line in output JSONL"
for l in out_lines: json.loads(l)
assert len(out_lines) >= len(in_lines), "output lost records"
print(f"validated {len(out_lines)} records")
PY

export GIT_INDEX_FILE="$IDX"
git read-tree "$ORIGIN"
BLOB=$(git hash-object -w "$TMP_OUT")
git update-index --cacheinfo 100644,"$BLOB",.beads/issues.jsonl
TREE=$(git write-tree)
C=$(git commit-tree "$TREE" -p "$ORIGIN" -m "$MSG")
unset GIT_INDEX_FILE
git push origin "$C":"$BRANCH"
echo "pushed $C -> $BRANCH"
