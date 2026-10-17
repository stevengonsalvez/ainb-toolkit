# Permission-prompt stalls

Subagents can sit for hours on "Dangerous rm operation on possibly-empty variable path". Nobody
answers a prompt overnight, so one prompt stops a lane.

Three layers, cheapest first:

| Layer | What | Where |
|---|---|---|
| 1 Brief rule | Every brief tells the agent to write `rm -rf "${S:?}"/x` or a literal path | `references/lanes.md` common footer, `SKILL.md` hard rule 7 |
| 2 Deny hook | A PreToolUse hook denies an unguarded `rm` instantly with the fix, so the agent corrects itself in one turn instead of waiting | `scripts/hooks/rm-guard-hook.sh` |
| 3 Allowlist | A few read-only commands never ask | snippet below, optional |

## Premise, still to be verified on a live host
The hook and the brief rule assume Claude Code's built-in check accepts `rm -rf "${S:?}"/x`
without a prompt. That is not yet verified. Before relying on it, run one unattended session
that executes `rm -rf "${S:?}"/x` against a scratch path and confirm no prompt appears, then
record the Claude Code version here: `verified on: ______`. If it does prompt, the only fix is
to avoid `rm` of variable paths (use `find "${S:?}/x" -delete` or a literal path).

## The hook
Denies a Bash command only when an `rm` has a recursive flag (`-r`, `-R`, `--recursive`) or a glob
and an argument with a `$VAR` (or `$1`, `$@`, `$*`) that is not `${VAR:?}`, and only when the
session cwd is one of this project's checkouts (config `worktrees.path_match`, case-insensitive, or
a git origin in `github.org` that no exclude pattern matches). The hook sources `lib.sh` for that, so
copy `lib.sh` and `config.yaml` next to it (install below); without them it allows everything. A lone `rm -f "$file"` is allowed. Text inside quotes (single or multi-line) and heredocs
is ignored. It sees `rm` (also `/bin/rm`, `\rm`, tab-separated) after `then`, `do`, `else`, `if`,
`while`, `until`, `{`, `(`, `&`, `|`, `nohup`, `env`, `nice`, `time`, `timeout N`, `sudo` and a
leading `xargs`; backslash-newline continuations are joined. Known blind spots, all fail open (the
built-in prompt still applies): `$(...)` and backtick bodies, `eval` / `bash -c` strings, functions,
`sudo -u x` and `timeout --foreground` style options, `xargs` that is not the first word.
Always exits 0; the verdict is the JSON. The deny reason says the prompt "may" stop the lane, not that it will.
Tests: `scripts/test/rm-guard-hook.sh`, portable awk/sed only. Run it on a Mac before installing on
one; it is not run by CI.

Install, per host (explicit step). Idempotent and safe to re-run; it keeps every existing hook:
```bash
command -v jq >/dev/null || { echo "install jq first"; exit 1; }
SRC="$(git rev-parse --show-toplevel)/.agents/skills/concertmaster/scripts/hooks/rm-guard-hook.sh"
mkdir -p ~/.concertmaster/bin
cp "$SRC" "$(dirname "$SRC")/../lib.sh" ~/.concertmaster/bin/ && chmod +x ~/.concertmaster/bin/rm-guard-hook.sh
cp "$(dirname "$SRC")/../../config.yaml" ~/.concertmaster/config.yaml   # scope: worktrees.path_match, github.org
SETTINGS="$(readlink -f ~/.claude/settings.json 2>/dev/null || echo ~/.claude/settings.json)"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.bak-rmguard" ] || cp "$SETTINGS" "$SETTINGS.bak-rmguard"
HOOK="$HOME/.concertmaster/bin/rm-guard-hook.sh"
jq --arg h "$HOOK" '
  .hooks.PreToolUse = ((.hooks.PreToolUse // [])
    | map(.hooks = ((.hooks // []) | map(select(.command != $h))))
    | map(select((.hooks | length) > 0))
    + [{"matcher":"Bash","hooks":[{"type":"command","command":$h,"timeout":5}]}])' \
  "$SETTINGS" > "$SETTINGS.new" && mv "$SETTINGS.new" "$SETTINGS"
# verify: must print "deny"
# (use a cwd that matches your worktrees.path_match)
printf '%s' "{\"cwd\":\"$PWD\",\"tool_input\":{\"command\":\"rm -rf \$S/x\"}}" | "$HOOK" | jq -r .hookSpecificOutput.permissionDecision
```
It takes effect for sessions started after the change, so running standing lanes need a restart
(or a re-spawn) to pick it up. Codex and agy sessions do not read Claude settings: they only get
layer 1, the brief rule. The hook file is trusted code run on every Bash call: keep
`~/.concertmaster/bin` writable only by the agent user and re-run the copy above after each merge.
Rollback: restore `settings.json.bak-rmguard`.

## The allowlist (optional, narrow)
Prefix rules accept any flags, so only commands with no program-running or file-writing flags are
listed. This is "no known execution or write flag", not a proof of read-only. Prefer the project's
`.claude/settings.local.json` over user scope, because the hook is scoped to this project and an allowlist
at user level applies to every repo on the host.
```json
[
  "Bash(git status:*)", "Bash(git rev-parse:*)", "Bash(git merge-tree:*)",
  "Bash(gh pr view:*)", "Bash(gh pr list:*)", "Bash(gh pr checks:*)",
  "Bash(gh run list:*)", "Bash(gh run view:*)", "Bash(gh issue view:*)",
  "Bash(ls:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(date:*)", "Bash(pwd)",
  "Bash(orca worktree list:*)", "Bash(orca worktree show:*)", "Bash(orca worktree ps:*)",
  "Bash(orca terminal read:*)", "Bash(orca terminal list:*)", "Bash(orca host list:*)",
  "Bash(bd show:*)", "Bash(bd list:*)", "Bash(bd ready:*)"
]
```
Deliberately NOT listed. Each can run a program or write a file through a flag, or send data out:
`cat` and `gh api` (arguments such as `-R HOST/...` or a hostile URL can read a file and ship it
elsewhere when an agent is steered by untrusted PR or issue text; `gh api rate_limit` is free but is
left to the normal prompt for that reason), `git fetch`
(`--upload-pack`), `rg` (`--pre`), `sort` (`--compress-program`, `-o`), `uniq` (output file),
`git branch` (`-D`, `-m`), `git diff`/`log`/`show` (`--output`, `--ext-diff`) and `jq`. Also not listed: `git push`, `gh pr merge`, `gh pr create`, `rm`, `supabase`, `wrangler`,
`orca terminal send`.
