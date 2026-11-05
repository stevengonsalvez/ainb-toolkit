#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# Guard: no non-test script under scripts/ may run `orca` / `orca-ide` / `orca-dev` / `plugly` / `plugly-dev` / `plugly-ide` directly. Every CLI call
# goes through cm_cli (scripts/lib.sh), so a switch of CLI is the config key `cli` only (and bare `orca` on Linux is the
# screen reader). The scan reads code, not prose: comments, quoted text (an echo, printf, fail or die message), here-
# document bodies, case labels and the cm_cli definition in lib.sh are ignored. It flags a command word that is orca or
# plugly (also behind env, timeout, cm_timeout, command, exec, sudo, nohup, a VAR=x prefix, `$(`, a backtick or a pipe),
# a plain `ORCA=orca` / `ORCA=plugly` assignment, and either as the payload of `sh -c '...'` / `bash -lc "..."`. Not seen:
# a call on another host through ssh (it runs there, with that host's PATH) and an indirect name such as
# `$(command -v orca) ...`. Proof it bites: a temp copy of scripts/ gets seeded violations and each one must be found.
# Touches nothing outside a mktemp dir. No network.
#
#   scripts/test/no-bare-orca.sh         # exit 0 when the tree is clean and the seeded copy is caught
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-no-bare-orca.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }

SCAN="$ROOT/scan.py"
cat > "$SCAN" <<'PY'
import os, re, sys

ORCA_WORDS = {"orca", "orca-ide", "orca-dev", "plugly", "plugly-dev", "plugly-ide"}
WRAPPERS = {"env", "command", "exec", "sudo", "nohup", "time", "builtin", "xargs", "nice", "ionice", "stdbuf", "!", "then", "do", "else", "elif", "if", "while", "until", "{"}
TIMEOUTS = {"timeout", "gtimeout", "cm_timeout"}
FLAG_VALUE = {"-u", "-g", "-n", "-s", "-k", "-C"}   # option letters that take a separate value
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHC_RAW = re.compile(r"""\b(?:ba|z)?sh\s+-[A-Za-z]*c\s+(?:['"])\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:timeout\s+\S+\s+|cm_timeout\s+\S+\s+)?(orca-ide|orca-dev|orca|plugly-ide|plugly-dev|plugly)\b""")
DEFAULT_RAW = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*:?-(orca-ide|orca-dev|orca|plugly-ide|plugly-dev|plugly)\}")
ASSIGN_RAW = re.compile(r"^\s*(?:export\s+)?ORCA=[\"']?(orca|orca-ide|orca-dev|plugly-ide|plugly-dev|plugly)[\"']?\s*(?:#.*)?$")
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def code_only(line, carry=None):
    """Return (code, carry): the line with comments and quoted text blanked, and the quote ("'" or '"')
    still open at the end of the line, which blanks the start of the next one. $( ) and backticks
    inside double quotes are kept."""
    out = []
    i, n = 0, len(line)
    mode = []  # stack: 'd' inside double quotes, 'c' inside $( ), 'b' inside backticks
    sq_open = False
    if carry:
        j = i
        while j < n:
            if line[j] == "\\" and carry == '"':
                j += 2; continue
            if line[j] == carry:
                break
            j += 1
        if j >= n:
            return "", carry
        i = j + 1
    while i < n:
        ch = line[i]
        top = mode[-1] if mode else None
        if top == "d":
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                mode.pop(); out.append(" "); i += 1; continue
            if line.startswith("$(", i):
                mode.append("c"); out.append(" $( "); i += 2; continue
            if ch == "`":
                mode.append("b"); out.append(" ` "); i += 1; continue
            i += 1; continue
        if top == "b" and ch == "`":
            mode.pop(); out.append(" ` "); i += 1; continue
        # code context (top level, inside $( ), inside backticks)
        if ch == "\\":
            out.append("  "); i += 2; continue
        if ch == "'":
            j = line.find("'", i + 1)
            if j < 0:
                sq_open = True
            i = n if j < 0 else j + 1
            out.append(" "); continue
        if ch == '"':
            mode.append("d"); out.append(" "); i += 1; continue
        if ch == "#" and (not out or out[-1] in " \t;|&("):
            break
        if line.startswith("$(", i):
            mode.append("c"); out.append(" $( "); i += 2; continue
        if ch == "`":
            mode.append("b"); out.append(" ` "); i += 1; continue
        if ch == ")" and top == "c":
            mode.pop(); out.append(" ) "); i += 1; continue
        out.append(ch); i += 1
    left = None
    if mode and mode[0] == "d":
        left = '"'
    elif sq_open:
        left = "'"
    return "".join(out), left


def segments(code):
    """Split code into command segments. A ) with no open ( ends a case pattern: its segment is dropped."""
    segs, cur, depth = [], [], 0
    i, n = 0, len(code)
    while i < n:
        two = code[i:i + 2]
        ch = code[i]
        if two in ("&&", "||", ";;"):
            segs.append("".join(cur)); cur = []; i += 2; continue
        if ch in ";|&\n`{":
            if ch == "{" and not (i + 1 >= n or code[i + 1] in " \t"):
                cur.append(ch); i += 1; continue
            segs.append("".join(cur)); cur = []; i += 1; continue
        if code.startswith("$(", i):
            segs.append("".join(cur)); cur = []; depth += 1; i += 2; continue
        if ch == "(":
            segs.append("".join(cur)); cur = []; depth += 1; i += 1; continue
        if ch == ")":
            if depth > 0:
                depth -= 1; segs.append("".join(cur)); cur = []
            else:
                cur = []  # case pattern terminator: what came before is a pattern, not a command
            i += 1; continue
        cur.append(ch); i += 1
    segs.append("".join(cur))
    return segs


def is_orca(word):
    return os.path.basename(word.strip("\\")) in ORCA_WORDS


def verdict(seg):
    words = seg.split()
    k = 0
    while k < len(words):
        w = words[k]
        if ASSIGN.match(w):
            k += 1; continue
        if w in WRAPPERS:
            if w == "command" and k + 1 < len(words) and words[k + 1] in ("-v", "-V"):
                return None   # `command -v orca` looks the name up, it does not run it
            k += 1
            while k < len(words) and words[k].startswith("-"):
                k += 2 if words[k] in FLAG_VALUE and k + 1 < len(words) else 1
            continue
        if w in TIMEOUTS:
            k += 1
            while k < len(words) and (words[k].startswith("-") or re.match(r"^[0-9.]+[smhd]?$", words[k])):
                k += 2 if words[k] in FLAG_VALUE and k + 1 < len(words) else 1
            continue
        break
    if k < len(words) and is_orca(words[k]):
        return words[k]
    for q, w in enumerate(words[:-1]):   # find ... -exec orca ...
        if w in ("-exec", "-execdir", "-ok") and is_orca(words[q + 1]):
            return words[q + 1]
    return None


def scan_file(path, rel):
    hits = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return hits
    if not rel.endswith(".sh") and not (lines and re.match(r"#!.*\b(ba)?sh\b", lines[0])):
        return hits
    heredoc = None
    carry = None
    in_def = False
    for no, raw in enumerate(lines, 1):
        if heredoc:
            if raw.strip() == heredoc:
                heredoc = None
            continue
        if rel == "lib.sh":
            if raw.startswith("cm_cli() {"):
                in_def = True
            if in_def:
                if raw.startswith("}"):
                    in_def = False
                continue
        am = ASSIGN_RAW.match(raw)
        if am:
            hits.append((rel, no, "ORCA=" + am.group(1), raw.strip()[:120]))
        dm = DEFAULT_RAW.search(raw)
        if dm and not raw.lstrip().startswith("#"):
            hits.append((rel, no, dm.group(1), raw.strip()[:120]))
        sm = SHC_RAW.search(raw)
        if sm and not raw.lstrip().startswith("#"):
            hits.append((rel, no, sm.group(1), raw.strip()[:120]))
        code, carry = code_only(raw, carry)
        # a here-document opens only when << sits in code (not in a quoted string or a comment); the
        # delimiter itself is read from the raw line, because code_only blanks a quoted delimiter
        m = None
        if "<<" in code and "((" not in raw:
            m = HEREDOC.search(raw)
        for seg in segments(code):
            v = verdict(seg)
            if v:
                hits.append((rel, no, v, raw.strip()[:120]))
        if m:
            heredoc = m.group(2)
    return hits


def main(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath == root:
            dirnames[:] = [d for d in dirnames if d != "test"]   # only the top-level test dir is exempt
        for f in sorted(filenames):
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, root)
            found.extend(scan_file(full, rel))
    for rel, no, v, text in found:
        print("%s:%d: bare %s: %s" % (rel, no, v, text))
    return 1 if found else 0


sys.exit(main(sys.argv[1]))
PY

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

# 1. the real tree is clean
out="$(python3 -I "$SCAN" "$SCRIPTS" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "no non-test script under scripts/ runs orca / orca-ide directly" || bad "bare orca in the tree" "$out"
n="$(find "$SCRIPTS" -path "$SCRIPTS/test" -prune -o -type f -name '*.sh' -print | wc -l | tr -d ' ')"
[ "$n" -ge 30 ] && ok "scanned $n shell scripts" || bad "script count" "only $n"

# 2. a seeded copy is caught, violation by violation
SEED="$ROOT/seed"; mkdir -p "$SEED/hooks"
cat > "$SEED/seeded.sh" <<'E'
#!/usr/bin/env bash
# comment: orca worktree list is fine here
echo "run orca worktree list by hand"
printf 'orca %s\n' x
fail "orca terminal close failed"
case "$via" in
  orca) via=orca ;;
esac
ORCA="$(cm_cli)"
cm_timeout 30 "$ORCA" worktree list --json
command -v orca-ide >/dev/null
cat <<'DOC'
orca worktree list
DOC
orca worktree list --json
timeout 30 orca-ide terminal list
x="$(orca host list --json)"
y=`orca terminal list`
env FOO=1 orca repo list
[ -n "$z" ] && orca worktree set --comment x
ORCA=orca
ORCA="orca-ide"
read -r a <<< "here-string"
cat <<"EOF"
orca documented in a quoted heredoc
EOF
x=$(( 1 << n ))
orca worktree set --comment after-shift
xargs orca terminal close
bash -lc "orca worktree list"
sh -c 'cm_timeout 5 orca-ide host list'
ssh host-a orca worktree list
echo "usage: cmd <<EOF"
sudo -u deploy orca worktree list
nice -n 5 orca-ide host list
timeout --signal=KILL 5 orca terminal list
env -i orca repo list
ORCA="${ORCA_CLI_COMMAND:-orca}"
find . -name x -exec orca worktree list \;
msg='first line of help
orca documented across a quoted line'
die "usage:
  orca worktree list"
orca worktree set --comment after-multiline
plugly worktree list --json
echo "run plugly host list by hand"
command -v plugly >/dev/null
# comment: plugly terminal list is fine here
timeout 30 plugly terminal list
x="$(plugly host list --json)"
ORCA="plugly"
ORCA=plugly
bash -lc "plugly host list"
ORCA="${PLUGLY_CLI_COMMAND:-plugly}"
cm_timeout 20 plugly --host local worktree ps
plugly-dev worktree list --json
timeout 5 plugly-dev host list
ORCA="plugly-dev"
plugly-ide worktree list --json
y="${CLI:-plugly-ide}"
ORCA="plugly-ide"
E
printf 'orca worktree list\n' > "$SEED/hooks/noshebang.sh"
mkdir -p "$SEED/hooks/test"; printf '#!/usr/bin/env bash\norca host list\n' > "$SEED/hooks/test/deep.sh"
expected=(
  "seeded.sh:15: bare orca"
  "seeded.sh:16: bare orca-ide"
  "seeded.sh:17: bare orca"
  "seeded.sh:18: bare orca"
  "seeded.sh:19: bare orca"
  "seeded.sh:20: bare orca"
  "seeded.sh:21: bare ORCA=orca"
  "seeded.sh:22: bare ORCA=orca-ide"
  "seeded.sh:28: bare orca"
  "seeded.sh:29: bare orca"
  "seeded.sh:30: bare orca"
  "seeded.sh:31: bare orca-ide"
  "seeded.sh:34: bare orca"
  "seeded.sh:35: bare orca-ide"
  "seeded.sh:36: bare orca"
  "seeded.sh:37: bare orca"
  "seeded.sh:38: bare orca"
  "seeded.sh:39: bare orca"
  "seeded.sh:44: bare orca"
  "seeded.sh:45: bare plugly"
  "seeded.sh:49: bare plugly"
  "seeded.sh:50: bare plugly"
  "seeded.sh:51: bare ORCA=plugly"
  "seeded.sh:52: bare ORCA=plugly"
  "seeded.sh:53: bare plugly"
  "seeded.sh:54: bare plugly"
  "seeded.sh:55: bare plugly"
  "seeded.sh:56: bare plugly-dev"
  "seeded.sh:57: bare plugly-dev"
  "seeded.sh:58: bare ORCA=plugly-dev"
  "seeded.sh:59: bare plugly-ide"
  "seeded.sh:60: bare plugly-ide"
  "seeded.sh:61: bare ORCA=plugly-ide"
  "hooks/noshebang.sh:1: bare orca"
  "hooks/test/deep.sh:2: bare orca"
)
out="$(python3 -I "$SCAN" "$SEED" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "a seeded copy fails the scan" || bad "seeded copy not flagged" "rc=$rc $out"
for e in "${expected[@]}"; do
  case "$out" in *"$e"*) ok "seeded violation found: $e" ;; *) bad "seeded violation missed: $e" "$out" ;; esac
done
cnt="$(printf '%s\n' "$out" | grep -c 'bare ')"
[ "$cnt" = "${#expected[@]}" ] && ok "and nothing else in it is flagged (comment, strings, case label, here-doc, command -v)" || bad "false positives" "$cnt hits: $out"

# 3. a seeded violation inside a copy of the real tree is caught too (the real scripts stay untouched)
COPY="$ROOT/copy"; mkdir -p "$COPY"
cp -R "$SCRIPTS"/. "$COPY"/
printf '\norca worktree list --json\n' >> "$COPY/spawn-verify.sh"
out="$(python3 -I "$SCAN" "$COPY" 2>&1)"; rc=$?
[ "$rc" = 1 ] && case "$out" in *"spawn-verify.sh:"*"bare orca"*) true ;; *) false ;; esac \
  && ok "a bare call appended to a copy of spawn-verify.sh is flagged" || bad "copy not flagged" "rc=$rc $out"
cp "$SCRIPTS/spawn-verify.sh" "$COPY/spawn-verify.sh"
printf '\nplugly worktree list --json\n' >> "$COPY/spawn-verify.sh"
out="$(python3 -I "$SCAN" "$COPY" 2>&1)"; rc=$?
[ "$rc" = 1 ] && case "$out" in *"spawn-verify.sh:"*"bare plugly"*) true ;; *) false ;; esac \
  && ok "a bare plugly call appended to a copy of spawn-verify.sh is flagged" || bad "copy not flagged (plugly)" "rc=$rc $out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
