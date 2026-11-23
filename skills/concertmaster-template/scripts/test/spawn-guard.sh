#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2016  # pass() always succeeds; check bodies are single-quoted on purpose
# spawn-guard.sh (test): "no ticket, no spawn", hermetic. A fake gh on PATH, no network.
# Covers: refused with no --issue, an empty value, a non-number, zero, a leading zero, "#12" and a URL (exit 1, the reason on
# stderr, gh never called); accepted with an open issue (exit 0, one gh call, the right repo); a CLOSED or MERGED issue and a PR number refused; a missing issue refused (exit 1); gh down, timing out, or not installed accepted as unverified (an outage is not a
# verdict); bad usage exits 2 (unknown arg, --issue with no value, --repo with no value); the spawn recipe in SKILL.md calls the
# guard before it creates the worktree and hands the same number to `worktree create --issue`. Mutants on a scratch copy of the
# script: the number check, the not-found refusal and the missing-issue refusal each removed must fail a case.
#
#   scripts/test/spawn-guard.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-spawnguard-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }
check() { if (eval "$2"); then pass "$1"; else fail "$1" "${3:-}"; fi; }

export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_SPAWN_REPO CM_GH_TIMEOUT
export CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }

# a fake gh: GH_MODE picks the answer; every call is logged with its argv
mkdir -p "$ROOT/bin" "$ROOT/nogh"
cat > "$ROOT/bin/gh" <<'E'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$1 $2" = "issue view" ] || { echo "unexpected gh call: $*" >&2; exit 9; }
n="$3"
case "${GH_MODE:-open}" in
  open)    printf '{"number":%s,"state":"OPEN","url":"https://github.com/o/r/issues/%s"}\n' "$n" "$n" ;;
  closed)  printf '{"number":%s,"state":"CLOSED","url":"https://github.com/o/r/issues/%s"}\n' "$n" "$n" ;;
  pullreq) printf '{"number":%s,"state":"OPEN","url":"https://github.com/o/r/pull/%s"}\n' "$n" "$n" ;;
  prmerged) printf '{"number":%s,"state":"MERGED","url":"https://github.com/o/r/pull/%s"}\n' "$n" "$n" ;;
  merged)  printf '{"number":%s,"state":"MERGED","url":"https://github.com/o/r/issues/%s"}\n' "$n" "$n" ;;
  weird)   printf '{"number":%s,"state":"DRAFT","url":"https://github.com/o/r/issues/%s"}\n' "$n" "$n" ;;
  missing) echo "GraphQL: Could not resolve to an issue or pull request with the number of $n. (repository.issue)" >&2; exit 1 ;;
  down)    echo "error connecting to api.github.com" >&2; exit 1 ;;
  hang)    sleep 30 ;;
  garbage) echo "not json" ;;
esac
E
chmod +x "$ROOT/bin/gh"
for t in jq bash env sed grep head tr cat mktemp rm dirname uname awk date timeout perl yq; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$ROOT/nogh/$t"; done
export GH_LOG="$ROOT/gh.log"
G="$SKILL/scripts/spawn-guard.sh"
# run <script> <args...>: RC, OUT (stdout), ERR (stderr); PATH holds the fake gh
run() { local s="$1"; shift; : > "$GH_LOG"; PATH="$ROOT/bin:$ROOT/nogh:/usr/bin:/bin" bash "$s" "$@" >"$ROOT/out" 2>"$ROOT/err"; RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"; }
calls() { wc -l < "$GH_LOG" | tr -d ' '; }

# ---- refused: no usable issue number, gh never asked ----
GH_MODE=open run "$G"
check "no --issue: refused (exit 1) with the rule in the reason, gh not called" '[ "$RC" = 1 ] && grep -q "no issue number given" <<<"$ERR" && grep -q "No ticket, no spawn" <<<"$ERR" && [ "$(calls)" = 0 ]' "rc=$RC err=$ERR"
GH_MODE=open run "$G" --issue ""
check "--issue with an empty value: refused (exit 1)" '[ "$RC" = 1 ] && grep -q "no issue number given" <<<"$ERR" && [ "$(calls)" = 0 ]' "rc=$RC err=$ERR"
for bad in abc 0 007 "#12" -5 12x "1 2" https://github.com/o/r/issues/12 1234567890; do
  GH_MODE=open run "$G" --issue "$bad"
  check "--issue '$bad': refused as not a positive number (exit 1), gh not called" '[ "$RC" = 1 ] && grep -q "is not a positive issue number" <<<"$ERR" && [ "$(calls)" = 0 ]' "rc=$RC err=$ERR"
done

# ---- accepted ----
GH_MODE=open run "$G" --issue 101
check "an open issue: accepted (exit 0), one gh call for that issue in the configured repo" '[ "$RC" = 0 ] && grep -q "ok issue #101 in AcmeOrg/acme-app (OPEN)" <<<"$OUT" && [ "$(calls)" = 1 ] && grep -q "^issue view 101 --repo AcmeOrg/acme-app" "$GH_LOG"' "rc=$RC out=$OUT err=$ERR log=$(cat "$GH_LOG")"
GH_MODE=open run "$G" --issue 7 --repo Other/repo
check "--repo overrides the configured repo" '[ "$RC" = 0 ] && grep -q "^issue view 7 --repo Other/repo" "$GH_LOG"' "rc=$RC log=$(cat "$GH_LOG")"
GH_MODE=open CM_SPAWN_REPO=Env/repo run "$G" --issue 8
check "CM_SPAWN_REPO is used when --repo is absent" '[ "$RC" = 0 ] && grep -q "^issue view 8 --repo Env/repo" "$GH_LOG"' "log=$(cat "$GH_LOG")"
GH_MODE=closed run "$G" --issue 102
check "a CLOSED issue: REFUSED (exit 1), reason says CLOSED and to reopen or open a new ticket, nothing on stdout" '[ "$RC" = 1 ] && grep -q "issue #102 in AcmeOrg/acme-app is CLOSED: reopen it" <<<"$ERR" && [ -z "$OUT" ]' "rc=$RC out=$OUT err=$ERR"
# a PR number is not a ticket, and a finished ticket is not one either
GH_MODE=pullreq run "$G" --issue 41 --repo acme/acme-app
check "a PULL REQUEST number (url holds /pull/): REFUSED (exit 1), says it is a pull request, nothing on stdout" '[ "$RC" = 1 ] && grep -q "is a pull request" <<<"$ERR" && [ -z "$OUT" ]' "rc=$RC out=$OUT err=$ERR"
GH_MODE=prmerged run "$G" --issue 5 --repo cli/cli
check "a MERGED number (a merged PR): REFUSED (exit 1), nothing on stdout" '[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "REFUSED" <<<"$ERR"' "rc=$RC out=$OUT err=$ERR"
GH_MODE=merged run "$G" --issue 11
check "state MERGED on an issue-shaped url: REFUSED too (the state check alone, not the url check)" '[ "$RC" = 1 ] && grep -q "is MERGED" <<<"$ERR"' "rc=$RC err=$ERR"
check "the gh call asks for number, state and url" 'grep -q -- "--json number,state,url" "$GH_LOG"' "$(cat "$GH_LOG")"
GH_MODE=weird run "$G" --issue 9
check "a state it does not know: accepted as unverified, never a refusal" '[ "$RC" = 0 ] && grep -q "(unverified)" <<<"$OUT"' "rc=$RC out=$OUT"

# ---- a missing issue is a verdict; an outage is not ----
GH_MODE=missing run "$G" --issue 999999
check "an issue that does not exist: refused (exit 1) naming the number and repo" '[ "$RC" = 1 ] && grep -q "issue #999999 does not exist in AcmeOrg/acme-app" <<<"$ERR"' "rc=$RC err=$ERR"
GH_MODE=down run "$G" --issue 103
check "gh cannot reach GitHub: accepted as unverified (exit 0), warning on stderr" '[ "$RC" = 0 ] && grep -q "unverified" <<<"$ERR" && grep -q "(unverified)" <<<"$OUT"' "rc=$RC err=$ERR"
GH_MODE=garbage run "$G" --issue 104
check "an unreadable gh answer: accepted as unverified" '[ "$RC" = 0 ] && grep -q "(unverified)" <<<"$OUT"' "rc=$RC out=$OUT"
GH_MODE=hang CM_GH_TIMEOUT=1 run "$G" --issue 105
check "a gh call that hangs is cut off by CM_GH_TIMEOUT: accepted as unverified, never a refusal" '[ "$RC" = 0 ] && grep -q "unverified" <<<"$ERR"' "rc=$RC err=$ERR"
# no gh at all on PATH
: > "$GH_LOG"; PATH="$ROOT/nogh" bash "$G" --issue 106 >"$ROOT/out" 2>"$ROOT/err"; RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
check "gh not installed: accepted as unverified" '[ "$RC" = 0 ] && grep -q "gh is not installed" <<<"$ERR"' "rc=$RC err=$ERR"
# a missing issue still never reaches the verdict without gh, but a bad number is refused even then
: > "$GH_LOG"; PATH="$ROOT/nogh" bash "$G" --issue abc >"$ROOT/out" 2>"$ROOT/err"; RC=$?
check "gh not installed and a bad number: still refused" '[ "$RC" = 1 ]' "rc=$RC"

# ---- usage ----
run "$G" --bogus
check "an unknown argument: exit 2" '[ "$RC" = 2 ] && grep -q "unknown arg" <<<"$ERR"' "rc=$RC err=$ERR"
run "$G" --issue
check "--issue as the last word, with no value: exit 2" '[ "$RC" = 2 ] && grep -q "needs a value" <<<"$ERR"' "rc=$RC err=$ERR"
run "$G" --issue 5 --repo
check "--repo with no value: exit 2" '[ "$RC" = 2 ]' "rc=$RC err=$ERR"
run "$G" -h
check "-h prints the usage and exits 0" '[ "$RC" = 0 ] && grep -q "no ticket, no spawn" <<<"$OUT"' "rc=$RC"

# ---- the spawn recipe calls the guard before it creates anything, and links the issue ----
BLOCK="$ROOT/recipe.sh"
awk '/^## Spawn recipe/{f=1;next} f&&/^```bash/{g=1;next} g&&/^```/{exit} g{print}' "$SKILL/SKILL.md" > "$BLOCK"
check "the recipe block calls scripts/spawn-guard.sh --issue and stops on a refusal" 'grep -qE "scripts/spawn-guard\.sh --issue \"?\\\$ISSUE\"?[^|]*\|\| exit" "$BLOCK"' "$(grep -n spawn-guard "$BLOCK")"
check "the guard line comes BEFORE the first worktree create (nothing is made for a refused spawn)" '[ "$(grep -n "spawn-guard.sh" "$BLOCK" | head -n1 | cut -d: -f1)" -lt "$(grep -n "worktree create" "$BLOCK" | head -n1 | cut -d: -f1)" ]'
check "worktree create passes the same issue (--issue \"\$ISSUE\"), which links it in the fleet CLI at creation" 'grep -A3 "worktree create" "$BLOCK" | grep -qF -- "--issue \"\$ISSUE\""'

# ---- mutants on a scratch copy of the script: each guard removed must fail a case ----
mkdir -p "$ROOT/mut/scripts" && cp "$SKILL/scripts/lib.sh" "$SKILL/scripts/spawn-guard.sh" "$ROOT/mut/scripts/" && cp "$SKILL/config.example.yaml" "$ROOT/mut/" 2>/dev/null
M="$ROOT/mut/scripts/spawn-guard.sh"
mutant() { # <label> <sed script> <cmd args> <what must happen: shell test over RC>
  cp "$SKILL/scripts/spawn-guard.sh" "$M"; sed -i -E "$2" "$M"
  if cmp -s "$SKILL/scripts/spawn-guard.sh" "$M"; then fail "mutant $1" "the edit changed nothing"; return; fi
  GH_MODE="$3" run "$M" "${@:5}"
  if (eval "$4"); then fail "mutant $1" "the mutated script still passed the case (rc=$RC)"; else pass "mutant $1 is caught"; fi
}
mutant "missing-issue refusal removed" 's/^\[ "\$HAVE_ISSUE" = 1 \] && \[ -n "\$ISSUE" \] \|\| refuse .*$/:/' open '[ "$RC" = 1 ] && grep -q "no issue number given" <<<"$ERR"' --issue ""
mutant "number check removed" 's/^\[\[ "\$ISSUE" =~ .*$/:/' open '[ "$RC" = 1 ]' --issue abc
mutant "PR refusal removed" 's/^    \*\/pull\/\*\) refuse .*$/    *\/pull\/*) : ;;/' pullreq '[ "$RC" = 1 ]' --issue 41
mutant "CLOSED/MERGED refusal removed" 's/^    CLOSED\|MERGED\) refuse .*$/    CLOSED|MERGED) : ;;/' closed '[ "$RC" = 1 ]' --issue 102
mutant "MERGED refusal removed" 's/^    CLOSED\|MERGED\) refuse .*$/    CLOSED) refuse "closed" ;;/' merged '[ "$RC" = 1 ]' --issue 5
mutant "not-found refusal removed" 's/^  refuse "issue #\$ISSUE does not exist in \$REPO"$/  :/' missing '[ "$RC" = 1 ]' --issue 999999

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
