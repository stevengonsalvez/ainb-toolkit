# Permission-prompt stalls

Subagents can sit for hours on "Dangerous rm operation on possibly-empty variable path". Nobody
answers a prompt overnight, so one prompt stops a lane.

Detection (every tick): `scripts/pane-stalls.sh` reads every in-scope agent pane for `Do you want to proceed`,
because a subagent's prompt shows in no worktree comment. See `SKILL.md` § The tick, step 4 (Act), pane-stall scan.

Three layers, cheapest first:

| Layer | What | Where |
|---|---|---|
| 1 Brief rule | Every brief tells the agent: never run `rm`; `mktemp -d` under the scratchpad and leave it (even a guarded `rm` in a test harness raised the prompt) | `references/lanes.md` Lead charter 8, worker and review-subagent briefs, common footer; `SKILL.md` hard rule 18; the test scripts honour `CM_TEST_KEEP_TMP=1` (sixth wave below) |
| 2 Deny hook | A PreToolUse hook denies an unguarded `rm` instantly with the fix, so the agent corrects itself in one turn instead of waiting | `scripts/hooks/rm-guard-hook.sh` |
| 3 Allowlist | A few read-only commands never ask | snippet below, optional |

## Premise, now refuted
The hook assumed Claude Code's built-in check accepts `rm -rf "${S:?}"/x` without a prompt. It does
not hold for an `rm` inside `bash -c` or a heredoc in a test harness: two review subagents stalled on
the "Dangerous rm operation" prompt. So the brief rule is now "never run rm; mktemp -d under the
scratchpad and leave it". The hook below stays as a cheap second layer for a guarded form that still
slips through; the pane scan (`scripts/pane-stalls.sh`) is the net.

## Sixth wave: the rule did not reach every brief, and our tests run rm traps
A review subagent stalled on "This shell -c script runs rm and could not be checked". Two causes:

1. The no-rm rule lived only in this skill (`lanes.md` Lead charter 8, the briefs, this file). A brief built by a
   different review or sweep tool that has its own prompts never carried it. Fix: put the rule in ONE shared
   shell-safety block that tool owns, and have each of its verbs and adapters point at it. Check with
   `git grep -n -iE "never run rm|mktemp -d under"` over that tool's directory.
2. A reviewer who runs one of our test scripts also runs its `EXIT` trap, and a trap or a `bash -c` string with an
   `rm` in it cannot be checked, so it prompts. The deny hook cannot help: it never sees inside `bash -c`.
   Fix: every test script that has `trap '... rm -rf ...' EXIT` carries the header line `# cm-test: rm-cleanup`
   and skips that `rm -rf` when `CM_TEST_KEEP_TMP=1` (it prints the directory it left). `test/keep-tmp.sh` checks
   every such script and runs one both ways. A reviewer greps a script for `\brm\b` first and runs it by its path
   only with the marker and `CM_TEST_KEEP_TMP=1`; a script with an `rm` and no marker is read, not run. The switch
   covers the exit trap. An `rm` a test runs mid-script on its own temp dir stays: the script runs it, not a command
   the reviewer submitted. That the permission layer reads only the submitted command line (so a script run by path
   is not parsed for `rm`) is inferred from observed stalls, each of which came from `rm` text inside a
   `bash -c` or heredoc command; it is not from Claude Code documentation. If a prompt shows for a script run by
   path, the inference is wrong: the agent reports it and stops.

If a prompt shows anyway, the agent reports the text and stops; `pane-stalls.sh` still catches it.

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
The hook also denies a raw `orca worktree rm` / `orca worktree remove` (as `orca`, `orca-ide`, `orca-dev`, `plugly`, `cm_cli`, `cm_orca`, `$ORCA_CLI_COMMAND`, `$PLUGLY_CLI_COMMAND`, any command word that starts with `$` or a backtick, or a name with backslashes such as `or\ca`; any flags; any place in a chain or pipeline; behind `sudo` (also `-iu x`), `doas`, `env`, `nice`, `ionice`, `chrt`, `flock`, `timeout`, `setsid`, `stdbuf`, `watch`, by bare name or full path; also inside an `ssh` / `bash -c` / `sh` / `zsh` / `dash` / `ksh` string, a here-string fed to a shell (`bash <<< "..."`), a heredoc fed to a shell, `$( )`, backticks, `<( )` and every `find -exec`) when the session cwd or the command names a path in `worktrees.path_match`. A raw removal skips the beads, follow-up, salvage and parent gates; `teardown.sh` holds them and calls orca itself, where this hook never looks, so there is no exemption for a command that names teardown.sh. The deny reason points at `teardown.sh`. A `<<` opens a heredoc body (dropped, unless a shell reads it) only as a real operator: not inside quotes, a comment or arithmetic. More than 20 ssh / shell pieces and substitutions (each `$(`, backtick pair and `<(` counts) in one command, or more than 500 pieces that name `worktree`, are denied (the hook would outlast its 5 s timeout, and a timed-out hook allows the command). Not seen (fail open): text piped into a shell (`echo "orca worktree rm x" | bash`), `parallel` and `xargs -I{} {}` style launchers, ANSI-C escapes (`\n`, `\x41`) inside `$'...'`, aliases, functions, `git worktree remove` and `rm -rf <literal path>` (an agent may remove its own scratch worktree). Printed text that holds a single-quoted `$(orca worktree rm ...)` is still denied (fails closed).
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

## The autocompact prompt
Claude Code's "We recommend compacting earlier" dialog (an "Autocompact at <N> tokens" size
picker, footer ending "esc not now") blocks an idle session until someone dismisses it, and
nobody does overnight. `scripts/waiting.sh` reports a pane whose last 15 lines show that footer
and "Autocompact at" as a `BLOCKED PROMPT: autocompact recommendation` row, only when the session
has been idle 2 minutes or more, so a working session is never hit. It is not a question for
anyone, so it is cleared in every mode:
1. Send Escape once (`--text $'\e'`, no Enter). Two quick Escapes on an idle prompt open rewind.
2. Re-read the pane after about 2 seconds to confirm the dialog closed.
3. Nudge the session to run its tick. For a session that waits on the owner by design
   (a `cm:blocked` comment) Escape is still safe but send no nudge.
Never change the autocompact setting and never accept the suggested size.

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
