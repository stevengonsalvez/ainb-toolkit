#!/usr/bin/env bash
# scan-secrets.sh test: synthetic secrets are BUILT AT RUN TIME from split strings, so this file
# holds no secret-shaped literal. Asserts the per-class and per-file counts, the strict / advisory
# split and exit codes (0 clean, 1 strict hit, 2 could not read or nothing to scan), single and
# double JSON-escaped assignments, URL credentials, more vendor prefixes, that identifier / path /
# env-name noise is NOT counted, unreadable files and dirs failing closed, the CLI override beating
# config, config dirs with spaces, --since-days, and, the point of the script, that stdout and
# stderr NEVER contain a secret or any 8-character fragment of one (with a negative control that
# runs the detector over real script output plus an injected secret).
#
#   scripts/test/scan-secrets.sh         # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scan-secrets.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-scan-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf -- "${ROOT:?}"' EXIT
export HOME="$ROOT/home" CM_HOME="$ROOT/cmhome"
unset CM_CLAUDE_PROJECTS
mkdir -p "$HOME" "$CM_HOME"
# A readable config without credentials.transcript_dirs: zero-arg runs fall back to the default dir.
# (Zero-arg and config cases need yq; without it they are skipped and CLI-path cases still run.)
printf 'project:\n  name: Acme\n' > "$ROOT/base.yaml"
export CM_CONFIG="$ROOT/base.yaml"
HAVE_YQ=0; command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && HAVE_YQ=1

fail=0
check() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi
}
rep() { printf "%${2}s" '' | tr ' ' "$1"; }

# Secrets, distinct bodies so a fragment of one cannot be mistaken for another.
PV="PRIV"; DASH="-"
KEYHDR="-----BEGIN RSA ${PV}ATE KEY-----"
TOK="gh""p_$(rep Q 36)"
ANT="sk-""ant-$(rep R 30)"
WHS="wh""sec_$(rep W 30)"
LEG="sk""-$(rep L 48)"
JWT="ey""J$(rep h 20).ey""J$(rep p 24).$(rep s 24)"
AWS="AK""IA$(rep Z 16)"
PWV="Zx9$(rep w 12)Kq"
PWS="Ab1!$(rep m 6)#Cd2"
URLPW="Tr0ub$(rep d 6)Xy9"
PWKEY="pass""word"
SVC="sk-""svcacct-$(rep V 46)"
ADM="sk-""admin-$(rep M 46)"
ORK="sk-""or-v1-$(rep O 46)"
NONE="sk-""None-$(rep N 48)"
BHEX="$(rep a 20)$(rep 1 20)"
BMIX="Ab3$(rep k 30)Zq9"
XOXS="xo""xs-$(rep X 24)"
STEST="sk_""test_$(rep T 30)"
SECRETS="$STEST $TOK $ANT $WHS $LEG $JWT $AWS $PWV $PWS $URLPW $KEYHDR $SVC $ADM $ORK $NONE $BHEX $BMIX $XOXS"

D="$ROOT/proj"; mkdir -p "$D/a" "$D/b"
# file 1: every strict class (a token three times in all) plus a plain assignment
printf '%s\n' "{\"text\":\"$KEYHDR\"}" "{\"t\":\"x $TOK y $TOK\"}" "{\"k\":\"$ANT\"}" "{\"j\":\"$JWT\"}" \
  "{\"a\":\"$AWS\"}" "{\"c\":\"run ${PWKEY}=$PWV now\"}" > "$D/a/one.jsonl"
# file 2: single-escaped, double-escaped and symbol-rich assignments
{
  printf '{"c":"{\\"%s\\": \\"%s\\"}"}\n' "$PWKEY" "$PWV"
  printf '{"c":"{\\\\\\"%s\\\\\\": \\\\\\"%s\\\\\\"}"}\n' "$PWKEY" "$PWV"
  printf '{"c":"%s: %s"}\n' "$PWKEY" "$PWS"
} > "$D/b/two.jsonl"
# file 3: more prefixes and a URL credential
printf '%s\n' "{\"w\":\"$WHS\"}" "{\"l\":\"$LEG\"}" "{\"u\":\"postgresql://app:$URLPW@dbhost:5432/x\"}" > "$D/b/three.jsonl"
# file 4: noise that must NOT count (identifiers, env names, paths, words, short digits, placeholders)
ENVREF="\$DB_PW"
{
  printf '{"t":"use sb""p_ prefix, set PASS""WORD=%s or %s=<redacted>, token: short"}\n' "$ENVREF" "$PWKEY"
  printf '{"t":"ey""J is how a jwt starts; AK""IA keys are 20 chars"}\n'
  printf '{"tokenizer":"cl100k_base","secretName":"STRIPE_SECRET_KEY_LIVE","tokens:":123456789}\n'
  printf '{"t":"api_key=/opt/app/conf/some/path/file","secret: somelongplainword","token_type":"bearer"}\n'
  printf '{"t":"%s=changemechangeme and %s: lowercaseonlywords"}\n' "$PWKEY" "$PWKEY"
  printf '{"u":"postgresql://app:password@localhost:5432/x","h":"https://example.com:8443/some/very/long/path/here"}\n'
} > "$D/b/clean.jsonl"
# a non-jsonl file in a dir is ignored by the dir walk
printf '%s\n' "$TOK" > "$D/a/notes.txt"

OUT="$ROOT/out"; ERR="$ROOT/err"
run() { "$SCRIPT" "$@" > "$OUT" 2> "$ERR"; echo $?; }
row() { awk -F'\t' -v c="$1" '$1 == c { print $2 "/" $3 "/" $4 }' "$OUT"; }
frow() { FP="$1" awk -F'\t' -v c="$2" '$1 == "FILE" && $2 == ENVIRON["FP"] && $3 == c { print $4 }' "$OUT"; }

check "strict hits exit 1" "$(run "$D")" "1"
check "private_key" "$(row private_key)" "1/1/strict"
check "token_prefix (3 in file 1, whsec + legacy in file 3)" "$(row token_prefix)" "5/2/strict"
check "jwt" "$(row jwt)" "1/1/strict"
check "aws_key" "$(row aws_key)" "1/1/strict"
check "url_credential" "$(row url_credential)" "1/1/strict"
check "password_assign advisory, three forms plus one in file 1" "$(row password_assign)" "4/2/advisory"
check "per-file token count" "$(frow "$D/a/one.jsonl" token_prefix)" "3"
check "per-file password count, single + double escape + symbols" "$(frow "$D/b/two.jsonl" password_assign)" "3"
check "per-file url credential" "$(frow "$D/b/three.jsonl" url_credential)" "1"
check "noise file has no FILE row" "$(grep -c "clean.jsonl" "$OUT" | tr -d ' ')" "0"
check "txt file ignored in a dir walk" "$(grep -c "notes.txt" "$OUT" | tr -d ' ')" "0"
check "summary" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=4 hits=9 advisory=4 errors=0"

# the point: no secret and no 8-char fragment of one on stdout or stderr
leaks() { # file...: count of 8-char fragments (every 4th offset) of any secret found in the files
  local n=0 s i frag
  for s in $SECRETS; do
    i=0
    while [ $((i + 8)) -le "${#s}" ]; do
      frag="${s:$i:8}"
      grep -qF -- "$frag" "$@" && n=$((n + 1))
      i=$((i + 4))
    done
  done
  echo "$n"
}
run "$D" >/dev/null
check "output holds no secret fragment" "$(leaks "$OUT" "$ERR")" "0"
# negative control: the detector fires on real script output plus an injected secret
{ cat "$OUT"; printf 'leak %s\n' "$TOK"; } > "$ROOT/leaky"
nc="$(leaks "$ROOT/leaky")"; [ "$nc" -gt 0 ] && nc=detected
check "negative control detects an injected secret" "$nc" "detected"

# advisory-only input: exit 0, exit 1 with --strict
mkdir -p "$ROOT/adv"; printf '{"c":"%s=%s"}\n' "$PWKEY" "$PWV" > "$ROOT/adv/x.jsonl"
check "advisory-only exits 0" "$(run "$ROOT/adv")" "0"
check "advisory counted" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=1 hits=0 advisory=1 errors=0"
check "--strict makes advisory exit 1" "$(run --strict "$ROOT/adv")" "1"
# noise-only input: exit 0 even with --strict
mkdir -p "$ROOT/clean"; cp "$D/b/clean.jsonl" "$ROOT/clean/"
check "noise-only exits 0 with --strict" "$(run --strict "$ROOT/clean")" "0"
check "noise-only summary" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=1 hits=0 advisory=0 errors=0"
# a single file argument is scanned even if not .jsonl
check "file arg scanned as is" "$(run "$D/a/notes.txt")" "1"
check "file arg counts" "$(row token_prefix)" "1/1/strict"
# empty dir: exit 0, zero files
mkdir -p "$ROOT/empty"
check "empty dir exits 0" "$(run "$ROOT/empty")" "0"
# nothing readable: exit 2 and a warning
check "missing path exits 2" "$(run "$ROOT/nope")" "2"
check "missing path warns" "$(grep -c 'nothing to scan\|not found' "$ERR" | tr -d ' ')" "2"
check "missing path beside a clean dir still exits 2" "$(run "$ROOT/clean" "$ROOT/nope")" "2"
check "bad option exits 2" "$(run --bogus)" "2"
check "bad --since-days exits 2" "$(run --since-days x "$D")" "2"
check "--since-days 0 exits 2" "$(run --since-days 0 "$D")" "2"

# fail closed: an unreadable file or dir is never reported clean (skipped as root, which reads anyway)
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$ROOT/lock/sub"; printf '%s\n' "$TOK" > "$ROOT/lock/sub/x.jsonl"; cp "$D/b/clean.jsonl" "$ROOT/lock/y.jsonl"
  chmod 000 "$ROOT/lock/sub/x.jsonl"
  check "unreadable file exits 2" "$(run "$ROOT/lock/sub/x.jsonl")" "2"
  check "unreadable file counted as an error" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=1 hits=0 advisory=0 errors=1"
  check "unreadable file in a dir exits 2, not clean" "$(run "$ROOT/lock")" "2"
  chmod 000 "$ROOT/lock/sub"
  check "unreadable subdir exits 2, not clean" "$(run "$ROOT/lock")" "2"
  chmod 000 "$ROOT/lock"
  check "unreadable dir exits 2" "$(run "$ROOT/lock")" "2"
  check "unreadable dir counted" "$(grep -c 'errors=1' "$OUT" | tr -d ' ')" "1"
  chmod -R u+rwx "$ROOT/lock"
  check "a hit still wins over an error (exit 1)" "$(run "$D" "$ROOT/nope")" "1"
else
  echo "skip unreadable cases: running as root"
fi

# --since-days: an old file drops out, a fresh one stays
touch -t 202001010000 "$D/a/one.jsonl"
check "--since-days skips an old file" "$(run --since-days 2 "$D")" "1"
check "--since-days file count" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=3 hits=3 advisory=3 errors=0"
touch "$D/a/one.jsonl"

# defaults: CM_CLAUDE_PROJECTS, then home, then config credentials.transcript_dirs, CLI beats config
mkdir -p "$HOME/.claude/projects"; cp "$D/b/clean.jsonl" "$HOME/.claude/projects/"
if [ "$HAVE_YQ" = 1 ]; then
  check "CM_CLAUDE_PROJECTS default" "$(CM_CLAUDE_PROJECTS="$D" run)" "1"
  check "home default dir" "$(run)" "0"
  mkdir -p "$ROOT/with space"; cp "$D/a/one.jsonl" "$ROOT/with space/"
  printf 'credentials:\n  transcript_dirs: ["%s", "%s"]\n' "$D" "$ROOT/with space" > "$ROOT/cfg.yaml"
  check "config transcript_dirs" "$(CM_CONFIG="$ROOT/cfg.yaml" run)" "1"
  check "config dir with a space is scanned whole" "$(frow "$ROOT/with space/one.jsonl" token_prefix)" "3"
  check "CLI path beats config" "$(CM_CONFIG="$ROOT/cfg.yaml" run "$ROOT/clean")" "0"
else
  echo "skip config cases: no yq"
fi

# --since-days validation: leading zeros and zero are refused, never read as octal or zero files
for v in 00 08 09 010 0; do check "--since-days $v exits 2" "$(run --since-days "$v" "$D")" "2"; done
check "--since-days 1 is accepted" "$(run --since-days 1 "$D")" "1"

# symlinks: a symlinked start dir, symlinked files and a symlinked dir inside the tree
mkdir -p "$ROOT/real" "$ROOT/links"
printf '%s\n' "$TOK" > "$ROOT/real/a.jsonl"
ln -s "$ROOT/real" "$ROOT/linkdir"
ln -s "$ROOT/real/a.jsonl" "$ROOT/links/b.jsonl"
ln -s "$ROOT/real" "$ROOT/links/dirlink.jsonl"
check "symlinked start dir is scanned" "$(run "$ROOT/linkdir")" "1"
check "symlinked start dir counted" "$(row token_prefix)" "1/1/strict"
[ "$HAVE_YQ" = 1 ] && check "CM_CLAUDE_PROJECTS as a symlink is scanned" "$(CM_CLAUDE_PROJECTS="$ROOT/linkdir" run)" "1"
check "symlinked file in a dir is scanned" "$(run "$ROOT/links")" "1"
check "a symlinked subdir is followed (file link + dir link, no error)" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=2 hits=2 advisory=0 errors=0"
check "no secret fragment after symlink runs" "$(leaks "$OUT" "$ERR")" "0"
ln -s "$ROOT/nowhere" "$ROOT/links/broken.log"
check "a broken symlink is an error, not clean" "$(run "$ROOT/links")" "1"
check "broken symlink counted" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=3 hits=2 advisory=0 errors=1"
mkfifo "$ROOT/links/pipe-target"; ln -s "$ROOT/links/pipe-target" "$ROOT/links/pipe.log"
check "a symlink to a FIFO does not hang the scan" "$(timeout 20 "$SCRIPT" "$ROOT/links" >"$OUT" 2>"$ERR"; echo $?)" "1"
check "a FIFO is not a transcript: skipped, only the broken link is an error" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=3 hits=2 advisory=0 errors=1"
check "a FIFO given as a file argument is an error, never opened" "$(timeout 20 "$SCRIPT" "$ROOT/links/pipe.log" >"$OUT" 2>"$ERR"; echo $?)" "2"

# paths with a TAB or a backslash escape must not corrupt the report
mkdir -p "$ROOT/odd"
printf '%s\n' "$TOK" > "$ROOT/odd/x\\ty.jsonl"
printf '%s\n' "$TOK" > "$ROOT/odd/$(printf 'a\tb').jsonl"
check "TAB path is an error, backslash path still counted" "$(run "$ROOT/odd")" "1"
check "backslash path counted whole" "$(frow "$ROOT/odd/x\\ty.jsonl" token_prefix)" "1"
check "TAB path counted as an error" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=2 hits=1 advisory=0 errors=1"

# a tool failing mid-scan is an error, never clean: grep and awk stubs that fail
REALGREP="$(command -v grep)"; REALAWK="$(command -v awk)"
mkdir -p "$ROOT/stub"
printf '#!/bin/sh\ncase "$*" in *-aoE*) exit 2 ;; esac\nexec %s "$@"\n' "$REALGREP" > "$ROOT/stub/grep"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in *shape*) exit 2 ;; esac\nexec %s "$@"\n' "$REALAWK" > "$ROOT/stub/awk"
chmod +x "$ROOT/stub/grep" "$ROOT/stub/awk"
mkdir -p "$ROOT/okdir"; cp "$D/b/clean.jsonl" "$ROOT/okdir/"
check "grep failing mid-scan exits 2" "$(PATH="$ROOT/stub:$PATH" run "$ROOT/okdir")" "2"
rm -f "$ROOT/stub/grep"
check "awk failing mid-scan exits 2" "$(PATH="$ROOT/stub:$PATH" run "$ROOT/okdir")" "2"
rm -f "$ROOT/stub/awk"

# the report never leaks on the error, strict and file-arg paths either
run --strict "$D" "$ROOT/nope" >/dev/null
check "no secret fragment on a strict run with an error" "$(leaks "$OUT" "$ERR")" "0"
run "$D/a/one.jsonl" >/dev/null
check "no secret fragment on a file-arg run" "$(leaks "$OUT" "$ERR")" "0"

# config that exists but is unusable fails closed instead of scanning the default dir
if command -v yq >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude/projects"; cp "$D/b/clean.jsonl" "$HOME/.claude/projects/"
  printf 'credentials:\n  transcript_dirs: "%s"\n' "$D" > "$ROOT/scalar.yaml"
  check "scalar transcript_dirs exits 2" "$(CM_CONFIG="$ROOT/scalar.yaml" run)" "2"
  printf 'credentials: [unclosed\n  - x: {\n' > "$ROOT/bad.yaml"
  check "invalid YAML config exits 2" "$(CM_CONFIG="$ROOT/bad.yaml" run)" "2"
  printf 'project:\n  name: Acme\n' > "$ROOT/nokey.yaml"
  check "config without the key falls back to the default dir" "$(CM_CONFIG="$ROOT/nokey.yaml" run)" "0"
  check "default dir was scanned" "$(grep -c 'SUMMARY files=1' "$OUT" | tr -d ' ')" "1"
  printf 'credentials:\n  transcript_dirs: [1, 2]\n' > "$ROOT/nums.yaml"
  check "non-string transcript_dirs entries exit 2" "$(CM_CONFIG="$ROOT/nums.yaml" run)" "2"
fi

# --since-days cap and a newline in a CLI path
check "--since-days with a huge number exits 2" "$(run --since-days 99999999999999999999 "$D")" "2"
NLP="$ROOT/odd/nl
x.jsonl"; printf '%s\n' "$TOK" > "$NLP"
check "a newline path is an error, not a corrupt row" "$(run "$NLP")" "2"
check "newline path counted" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=1 hits=0 advisory=0 errors=1"

# an unreadable CM_CONFIG fails closed (no PATH args); with PATH args it is not consulted
check "unreadable CM_CONFIG exits 2" "$(CM_CONFIG="$ROOT/no-such.yaml" run)" "2"
check "unreadable CM_CONFIG does not block explicit paths" "$(CM_CONFIG="$ROOT/no-such.yaml" run "$ROOT/clean")" "0"

# config shapes that must fail closed
if [ "$HAVE_YQ" = 1 ]; then
  for shape in 'credentials: oops' 'credentials: [a, b]' 'credentials: {transcript_dirs: false}' 'credentials: {transcript_dirs: {a: b}}'; do
    printf '%s\n' "$shape" > "$ROOT/shape.yaml"
    check "config '$shape' exits 2" "$(CM_CONFIG="$ROOT/shape.yaml" run)" "2"
  done
  printf 'credentials: {transcript_dirs: []}\n' > "$ROOT/empty-list.yaml"
  check "an empty list falls back to the default dir" "$(CM_CONFIG="$ROOT/empty-list.yaml" run)" "0"
  # the real skill config.yaml next to SKILL.md, no CM_CONFIG: still falls back when it has no key
  SKILL_CFG="$(cd "$(dirname "$SCRIPT")/.." && pwd)/config.yaml"
  if [ ! -r "$SKILL_CFG" ] || ! grep -q 'transcript_dirs' "$SKILL_CFG"; then
    check "zero-arg run against the real skill config" "$(unset CM_CONFIG; CM_CLAUDE_PROJECTS="$D" run)" "1"
  fi
fi

# OpenAI service-account / admin and OpenRouter keys: bare, and as an assignment (which must not read clean)
mkdir -p "$ROOT/oai"
printf '%s\n' "{\"a\":\"$SVC\"}" "{\"b\":\"$ADM\"}" "{\"c\":\"$ORK\"}" > "$ROOT/oai/bare.jsonl"
check "bare sk-svcacct / sk-admin / sk-or-v1 keys are strict hits" "$(run "$ROOT/oai")" "1"
check "all three counted as token_prefix" "$(row token_prefix)" "3/1/strict"
rm -f "$ROOT/oai/bare.jsonl"
printf '{"e":"OPENAI_API_KEY=%s"}\n' "$SVC" > "$ROOT/oai/a1.jsonl"
printf '{"e":"OPENROUTER_API_KEY=%s"}\n' "$ORK" > "$ROOT/oai/a2.jsonl"
printf '{"e":"OPENAI_ADMIN_KEY=%s"}\n' "$ADM" > "$ROOT/oai/a3.jsonl"
check "key assignments with those prefixes are not clean (exit 1)" "$(run "$ROOT/oai")" "1"
check "each assignment counted as a strict token_prefix" "$(row token_prefix)" "3/3/strict"
check "no secret fragment after the OpenAI/OpenRouter runs" "$(leaks "$OUT" "$ERR")" "0"
mkdir -p "$ROOT/oai2"; printf '{"e":"api_key=sk-%s"}\n' "$(rep s 12)Ab1" > "$ROOT/oai2/short.jsonl"
check "a sk- value no strict regex matches still shows as advisory" "$(run "$ROOT/oai2")" "0"
check "advisory counted" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=1 hits=0 advisory=1 errors=0"

# sk-None- keys, Bearer values, the other Slack token kinds: strict, however they are written
mkdir -p "$ROOT/shapes"
printf '%s\n' "{\"a\":\"$NONE\"}" > "$ROOT/shapes/none.jsonl"
check "sk-None- key is a strict hit" "$(run "$ROOT/shapes")" "1"
check "sk-None- counted as token_prefix" "$(row token_prefix)" "1/1/strict"
for v in "$BHEX" "$BMIX"; do
  printf '{"h":"Authorization: Bearer %s"}\n' "$v" > "$ROOT/shapes/none.jsonl"
  check "Bearer ${#v}-char opaque value is a strict hit" "$(run --strict "$ROOT/shapes")" "1"
  check "counted as bearer_token" "$(row bearer_token)" "1/1/strict"
done
printf '{"h":"authorization: bearer %s"}\n' "$BMIX" > "$ROOT/shapes/none.jsonl"
check "lower-case bearer is a strict hit" "$(run "$ROOT/shapes")" "1"
printf '{"x":"%s"}\n' "$XOXS" > "$ROOT/shapes/none.jsonl"
check "xoxs- Slack token is a strict hit" "$(run "$ROOT/shapes")" "1"
# left boundary: every way a real key sits next to other text still hits
for w in "{\"k\":\"$NONE\"}" "k=$NONE" "key: $NONE" "($NONE)" "$NONE"; do
  printf '%s\n' "$w" > "$ROOT/shapes/none.jsonl"
  check "key beside '${w%%sk-*}' is found" "$(run "$ROOT/shapes")" "1"
done
# kebab-case text and prefixes inside a longer word or base64 are not keys
printf '%s\n' "{\"b\":\"fix/task-admin-permissions${DASH}check-for-everyone\"}" \
  "{\"b\":\"risk-or-reward${DASH}trade-off-matrix-long-name\"}" "{\"b\":\"helpdesk-svcacct-$(rep a 24)\"}" \
  "{\"b\":\"QUJD""AIza$(rep Q 40)\"}" "{\"b\":\"the bearer token scheme with authentication${DASH}middleware-configuration\"}" > "$ROOT/shapes/none.jsonl"
check "kebab-case, in-word prefixes and bearer prose are clean" "$(run --strict "$ROOT/shapes")" "0"
check "no secret fragment after the shape runs" "$(leaks "$OUT" "$ERR")" "0"

# a newline inside a file name found by the dir walk is an error, never a silent miss
mkdir -p "$ROOT/nldir"; printf '%s\n' "$TOK" > "$ROOT/nldir/evil
foo.jsonl"; cp "$D/b/clean.jsonl" "$ROOT/nldir/foo.jsonl"
check "newline in a walked file name exits 2, not clean" "$(run "$ROOT/nldir")" "2"
check "newline name counted as an error" "$(grep '^SUMMARY' "$OUT")" "SUMMARY files=2 hits=0 advisory=0 errors=1"

# a key glued to JSON-escaped newlines/tabs, URL escapes, "key-" or multibyte marks is still found:
# one file per case, one scan, every file must hold exactly one hit
rm -rf "$ROOT/glue"; mkdir -p "$ROOT/glue"
ANTK="sk-""ant-api03-$(rep Q 40)"
GHPK="gh""p_$(rep G 36)"
n=0
for pre in '\n' '\t' '\r\n' '     1\t' '%3D' '%22' '“' '→' '：' ' '; do
  for k in "$ANTK" "$GHPK" "$NONE" "$SVC" "$LEG" "$STEST"; do
    n=$((n + 1)); printf '{"o":"line1%s%s"}\n' "$pre" "$k" > "$ROOT/glue/g$n.jsonl"
  done
done
for pre in 'key-' 'KEY_'; do
  for k in "$ANTK" "$GHPK" "$STEST"; do
    n=$((n + 1)); printf '{"o":"%s%s"}\n' "$pre" "$k" > "$ROOT/glue/g$n.jsonl"
  done
done
printf '{"h":"BEARER %s"}\n' "$BMIX" > "$ROOT/glue/g$((n + 1)).jsonl"; n=$((n + 1))
check "every glued key shape is a strict hit" "$(run "$ROOT/glue")" "1"
check "one hit per glued file, none missed" "$(grep '^SUMMARY' "$OUT" | sed -E 's/ advisory=[0-9]+//')" "SUMMARY files=$n hits=$n errors=0"
mkdir -p "$ROOT/glue1"; printf '{"o":"x\\n%s"}\n' "$NONE" > "$ROOT/glue1/g.jsonl"
check "sk-None- after a JSON newline counts as token_prefix" "$(run "$ROOT/glue1" >/dev/null; row token_prefix)" "1/1/strict"
check "no secret fragment after the glue runs" "$(leaks "$OUT" "$ERR")" "0"

# a path starting with - is a path, not a find expression
mkdir -p "$ROOT/dash/-print"; printf '%s\n' "$TOK" > "$ROOT/dash/-print/x.jsonl"
check "a dir named -print is scanned as a path" "$(cd "$ROOT/dash" && "$SCRIPT" -- -print >"$OUT" 2>"$ERR"; echo $?)" "1"
check "dash dir counted" "$(row token_prefix)" "1/1/strict"

# --help shows the whole header including the exit codes and the safety note
check "--help prints the exit codes and safety lines" "$("$SCRIPT" --help 2>/dev/null | grep -c 'Exit 1 on a strict hit\|Safety:')" "2"

exit $fail
