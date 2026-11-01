#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2119  # check bodies are single-quoted on purpose: they are eval-ed later
# census-remote-git.sh (test): rule 1 of the census-to-zero work. Git state on a remote host is
# collected through a short-lived Orca terminal (ssh when Orca cannot), read to an end marker and
# closed by its exact handle. unknown-git only when Orca AND ssh both fail, and the reason says which;
# a timeout is listed, never clean, never gone. The stub orca runs the typed command in a local shell
# against fixture git repos, so the real remote script is what answers. Touches only a mktemp dir.
#
#   scripts/test/census-remote-git.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/fixtures/census-harness.sh
. "$HERE/fixtures/census-harness.sh"
census_init remote

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1"; fi; }

# One fixture repo per host, each with the same shape: lane-a clean, lane-b tracked change,
# lane-c an unpushed commit, lane-d only untracked tool scratch, plus a spaced path.
mkhost() { # mkhost <host>
  local h="$1" base="$ROOT/hosts/$1"
  mkdir -p "$base"
  census_repo "$base/acme-app"
  local b
  for b in lane-a lane-b lane-c lane-d; do census_worktree "$base/acme-app" "$base/$b" "$b"; done
  printf 'two\n' >> "$base/lane-b/tracked.txt"
  printf 'more\n' > "$base/lane-c/extra.txt"; git -C "$base/lane-c" add extra.txt; git -C "$base/lane-c" commit -q -m local
  mkdir -p "$base/lane-d/.beads"; printf 'x\n' > "$base/lane-d/.beads/i.jsonl"; printf 'x\n' > "$base/lane-d/run.log"
  census_worktree "$base/acme-app" "$base/lane with space" lane-sp
  {
    census_row acme-app "$base/acme-app" main main
    for b in lane-a lane-b lane-c lane-d; do census_row acme-app "$base/$b" "$b"; done
    census_row acme-app "$base/lane with space" lane-sp
  } > "$ROOT/rows-$h.ndjson"
}
for h in host-a host-b host-c host-d; do mkhost "$h"; done
census_hosts host-a host-b host-c host-d
for h in host-a host-b host-c host-d; do
  mapfile -t R < "$ROOT/rows-$h.ndjson" 2>/dev/null || { R=(); while IFS= read -r l; do R+=("$l"); done < "$ROOT/rows-$h.ndjson"; }
  census_ps "$h" "${R[@]}"
done
# an Orca row whose worktree the host does not list: lane-gone on host-a
{ cat "$ROOT/rows-host-a.ndjson"; census_row acme-app "$ROOT/hosts/host-a/lane-gone" lane-gone; } | jq -sc '{ok:true, result:{totalCount:length, truncated:false, worktrees:.}}' > "$STUB/ps-host-a.json"
census_ps local

touch "$STUB/create-fail-host-b" "$STUB/ssh-ok-host-b"     # host-b: Orca fails, ssh works
touch "$STUB/create-fail-host-c"                           # host-c: Orca and ssh fail
touch "$STUB/hang-host-d"                                  # host-d: terminal never prints; ssh fails
DOC="$ROOT/doc.json"
census_discover > "$DOC" 2>"$ROOT/err" || { echo "discover.sh failed"; cat "$ROOT/err"; exit 1; }
gv() { jq -r --arg h "$1" --arg n "$2" --arg f "$3" '.worktrees[] | select(.host == $h and (.path | endswith("/" + $n))) | (.git | if . == null then "null" else .[$f] | tostring end)' "$DOC"; }

# ---- host-a: through an Orca terminal ----
check "host-a (Orca): clean worktree is dirty 0, unpushed 0" '[ "$(gv host-a lane-a dirty)" = 0 ] && [ "$(gv host-a lane-a unpushed)" = 0 ]'
check "host-a (Orca): tracked change is dirty 1" '[ "$(gv host-a lane-b dirty)" = 1 ]'
check "host-a (Orca): unpushed commit is unpushed 1" '[ "$(gv host-a lane-c unpushed)" = 1 ]'
check "host-a (Orca): untracked tool scratch is dirty 0, ignored 2" '[ "$(gv host-a lane-d dirty)" = 0 ] && [ "$(gv host-a lane-d ignoredUntracked)" = 2 ]'
check "host-a (Orca): a path with a space is read" '[ "$(gv host-a "lane with space" statusOk)" = true ]'
check "host-a (Orca): collected via orca" '[ "$(gv host-a lane-a via)" = orca ]'
check "host-a (Orca): a listed row the host has no worktree for is exists:false, not clean" '[ "$(gv host-a lane-gone exists)" = false ]'
check "host-a: no ssh attempted when Orca worked" '! grep -q "^ssh .*host-a" "$STUB/calls.log"'
check "host-a: one terminal created, closed by its exact handle" '
  [ "$(grep -c "^terminal create host=host-a" "$STUB/calls.log")" = 1 ] &&
  grep -q "^terminal close host=host-a handle=term_host-a_" "$STUB/calls.log"'
check "no terminal left open on any host" '! ls "$STUB"/*.open >/dev/null 2>&1'
check "the terminal was not run on the local host and nothing used --all" '! grep -q -- "--all" "$STUB/calls.log"'

# ---- host-b: Orca fails, ssh works ----
check "host-b (ssh fallback): collected via ssh" '[ "$(gv host-b lane-a via)" = ssh ] && [ "$(gv host-b lane-b dirty)" = 1 ]'
check "host-b: scope says it fell back to ssh and why" 'jq -e ".gitScope.hosts[] | select(.host == \"host-b\") | .ok == true and .via == \"ssh\" and (.error | test(\"orca terminal\"))" "$DOC" >/dev/null'

# ---- host-c: Orca and ssh both fail ----
check "host-c (both fail): git is null, never clean" '[ "$(gv host-c lane-a dirty)" = null ]'
check "host-c: scope names Orca and ssh and ok:false" 'jq -e ".gitScope.hosts[] | select(.host == \"host-c\") | .ok == false and (.error | test(\"orca terminal\") and test(\"ssh\"))" "$DOC" >/dev/null'

# ---- host-d: the terminal never answers ----
check "host-d (timeout): git is null and the scope says timed out" '[ "$(gv host-d lane-a dirty)" = null ] && jq -e ".gitScope.hosts[] | select(.host == \"host-d\") | .ok == false and (.error | test(\"timed out\"))" "$DOC" >/dev/null'
check "host-d: the hung terminal was still closed" '! ls "$STUB"/term_host-d_*.open >/dev/null 2>&1 && grep -q "^terminal close host=host-d" "$STUB/calls.log"'

# ---- classify ----
CLS="$ROOT/cls.json"
"$SCRIPTS/classify.sh" < "$DOC" > "$CLS" 2>/dev/null || { echo "classify.sh failed"; exit 1; }
cl() { jq -r --arg h "$1" --arg n "$2" '.items[] | select(.host == $h and (.path | endswith("/" + $n))) | .class' "$CLS"; }
rs() { jq -r --arg h "$1" --arg n "$2" '.items[] | select(.host == $h and (.path | endswith("/" + $n))) | .reason' "$CLS"; }
check "classify: host-a clean worktree is not unknown-git" '[ "$(cl host-a lane-a)" = idle ]'
check "classify: host-a tracked change is dirty-or-unpushed" '[ "$(cl host-a lane-b)" = dirty-or-unpushed ]'
check "classify: host-a noise-only worktree is clean (idle)" '[ "$(cl host-a lane-d)" = idle ]'
check "classify: host-a row Orca lists but git does not is unknown-git (path gone)" '[ "$(cl host-a lane-gone)" = unknown-git ] && rs host-a lane-gone | grep -q "path gone"'
check "classify: host-b via ssh is classified, not unknown-git" '[ "$(cl host-b lane-a)" = idle ]'
check "classify: host-c is unknown-git and the reason names Orca and ssh" '[ "$(cl host-c lane-a)" = unknown-git ] && rs host-c lane-a | grep -q "orca terminal" && rs host-c lane-a | grep -q "ssh"'
check "classify: host-d is unknown-git with the timeout in the reason" '[ "$(cl host-d lane-a)" = unknown-git ] && rs host-d lane-a | grep -q "timed out"'
check "classify: the host-d rows are listed, none is host-offline" '[ "$(cl host-d lane-b)" = unknown-git ] && ! jq -e ".items[] | select(.class == \"host-offline\")" "$CLS" >/dev/null'

# ---- a terminal that cannot be closed is reported ----
touch "$STUB/close-fail-host-a"
census_discover 2>/dev/null | jq -e '.errors[] | select(.where == "git census host-a" and (.message | test("could not close terminal")))' >/dev/null
check "a terminal close failure is an error row naming the handle" '[ $? = 0 ]'

# ---- a file name that carries the output marker cannot forge git facts ----
rm -f "$STUB"/create-fail-* "$STUB"/hang-* "$STUB"/close-fail-* "$STUB"/ssh-ok-*
for h in host-e host-f; do mkhost "$h"; done
printf 'x\n' > "$ROOT/hosts/host-e/lane-a/x@@CMG@@ H dead"
census_hosts host-e host-f
for h in host-e host-f; do
  mapfile -t R < "$ROOT/rows-$h.ndjson" 2>/dev/null || { R=(); while IFS= read -r l; do R+=("$l"); done < "$ROOT/rows-$h.ndjson"; }
  census_ps "$h" "${R[@]}"
done
touch "$STUB/lose-handle-host-f"                           # host-f: terminal made, handle lost
DOC="$ROOT/doc2.json"
census_discover > "$DOC" 2>"$ROOT/err" || { echo "discover.sh failed"; cat "$ROOT/err"; exit 1; }
check "host-e: an untracked file named with the marker still counts as dirt, once" '[ "$(gv host-e lane-a dirty)" = 1 ] && [ "$(gv host-e lane-a statusOk)" = true ]'
check "host-e: the marker in a file name does not overwrite HEAD" '[ "$(gv host-e lane-a head)" != dead ]'
check "host-e: the other worktrees on the host are unharmed" '[ "$(gv host-e lane-b dirty)" = 1 ] && [ "$(gv host-e lane-c unpushed)" = 1 ]'

# ---- a create that loses its handle leaves no terminal behind ----
check "host-f (lost handle): unknown git, error names the create failure" '[ "$(gv host-f lane-a dirty)" = null ] && jq -e ".gitScope.hosts[] | select(.host == \"host-f\") | .ok == false and (.error | test(\"terminal create failed\"))" "$DOC" >/dev/null'
check "host-f: the stray terminal was found by its unique title and closed" '! ls "$STUB"/term_host-f_*.open >/dev/null 2>&1 && grep -q "^terminal close host=host-f handle=term_host-f_" "$STUB/calls.log"'
check "host-f: the sweep only touched this run's terminal (title carries the pid)" 'grep -l "cm-git-census-" "$STUB"/term_host-f_*.title >/dev/null'

# ---- ssh: a repo path with two spaces in a row survives the remote shell ----
rm -f "$STUB"/create-fail-* "$STUB"/lose-handle-*
G="$ROOT/hosts/host-g"; mkdir -p "$G"
census_repo "$G/acme  app"
census_worktree "$G/acme  app" "$G/lane-a" lane-a
{ census_row acme-app "$G/acme  app" main main; census_row acme-app "$G/lane-a" lane-a; } > "$ROOT/rows-host-g.ndjson"
# ---- Orca: a terminal strips trailing spaces, so a detached HEAD's empty branch line is a bare "B" ----
mkhost host-i
git -C "$ROOT/hosts/host-i/lane-a" checkout -q --detach
census_hosts host-g host-i
for h in host-g host-i; do
  mapfile -t R < "$ROOT/rows-$h.ndjson" 2>/dev/null || { R=(); while IFS= read -r l; do R+=("$l"); done < "$ROOT/rows-$h.ndjson"; }
  census_ps "$h" "${R[@]}"
done
touch "$STUB/create-fail-host-g" "$STUB/ssh-ok-host-g"
DOC="$ROOT/doc3.json"
census_discover > "$DOC" 2>"$ROOT/err" || { echo "discover.sh failed"; cat "$ROOT/err"; exit 1; }
check "host-g (ssh): a repo path with two spaces in a row is listed and read" '[ "$(gv host-g lane-a statusOk)" = true ] && [ "$(gv host-g lane-a via)" = ssh ]'
check "host-i (Orca): a detached HEAD has a null branch, not the tag letter" '[ "$(gv host-i lane-a branch)" = null ] && [ "$(gv host-i lane-b branch)" = lane-b ]'

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
