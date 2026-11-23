# Weekly usage and the account switch

Hard rule 29 in `SKILL.md` points here. Agent plans carry a weekly usage allowance. When the
account a host is signed in to runs out, every lane on that host stalls. This page is how the
concertmaster watches the figure and moves the fleet to a fresh account BEFORE that happens.

## The rule

1. **Record the weekly figure every tick, per host.** Read it from the weekly footer of a live
   agent pane on that host, or from the account-switch tool's own listing. A host that cannot be
   read is "unread", never "low" (hard rule 6: silence proves nothing).
2. **At 75% on the active account of any permitted host, switch the permitted hosts to an
   account under 75%.** 75% is the documented default and there is no config key for it: a
   project that wants another figure says so in its overlay (`references/project-local.md`).
   The 75% leaves headroom, so a switch is done while every lane is still running, not after a
   limit banner.
3. **Permitted hosts** are the hosts of `hosts.per_host` (`config.yaml`) whose `role` is
   `general`. A host with any other role, or not on that list, keeps its account; the tick names
   it. The destinations in the script below are those hosts, by the ssh target of
   `scripts/lib.sh` `cm_ssh_target` (the name `scripts/teardown.sh` uses). The script runs on
   `hosts.home`, where the account store lives; home is switched last.
4. **Switch by account identity, never by slot number.** Slot numbers differ per host, and an
   import that keeps each destination's own numbers (the `--force`-style import most tools
   offer) leaves number 2 on one host as a different account on another. The script turns the
   number you read from the tool's listing on the home host into that account's identity ONCE,
   there, and every host is switched by that identity.
5. **Never print an identity.** An identity is normally an email. The output of the tool's
   `export`, `import`, `switch` and `list` names accounts, so the script discards it, and the
   tick reads the result from the listing's "active" marker only. No identity goes in a note,
   a ledger row, a report or a PR.
6. **Never spend usage credits** to avoid a switch: stop and wait, or switch.
7. A fleet operation the concertmaster runs itself. A project that wants an owner ask first
   says so in its overlay.

## The script

One script, so the cleanup is armed before any token is written. Set `NUM` to the account's
slot number from the home host's listing, save the script to a file and run
`NUM=<n> bash <file>`.

Design, each line of it deliberate:

- The token export holds every account's login tokens. It is written mode 600 in a directory forced to 700,
  copied to each destination, deleted on every destination right after its import, and
  deleted again on the source and on every destination by the EXIT trap whatever happened
  (including a failed or half-written copy).
- The trap is armed BEFORE the export file exists. `exit 130` on INT or TERM stops the script
  before any further switch and the EXIT trap still runs. `cleanup` ignores INT and TERM, so a
  second signal cannot cut the delete short.
- Every step ends `|| exit 1`, not `set -e`: zsh does not run the EXIT trap under `set -e`.
- Each command stays on ONE line. A line break inside quotes ends the remote command and the
  remote delete silently fails.
- `ssh` and `scp` run with `BatchMode=yes` (never wait on a password prompt) and
  `ConnectTimeout=10` (a dead host fails in ten seconds, not never).
- The tool's output is discarded (`>/dev/null 2>&1`) because it names accounts. A failure is
  read from the exit code.
- The `case` guards check that `NUM` is digits and that the identity is a plain
  email-shaped token that does not start with `-`, BEFORE the identity is put in a remote
  command string or any token is written.

The first section is the only part to edit: it holds every command of the account-switch tool
(`acct-tool` stands for it; the subcommands and flags are the tool's own) and the destination
list. `tool_identity` must print the identity of slot `$1` from the home host's listing and
nothing else; the example reads a JSON listing with `jq`. `R_IMPORT` and `R_SWITCH` are the
commands run ON a destination, as strings, because they travel through `ssh`. The import must
overwrite the destination's own entry for the same identity, keep its other accounts and keep
its own slot numbers, and `R_SWITCH` is followed by the identity in single quotes.

```bash account-switch
# tool-command section: the only lines to edit
TOOL=acct-tool                                   # <account-switch tool>, on PATH on every host
DESTS=(host-a host-b)                            # role: general hosts of hosts.per_host, minus the home host
tool_identity() { "$TOOL" list --json 2>/dev/null | jq -r --argjson n "$1" '.accounts[] | select(.number==$n) | .email // empty' 2>/dev/null; }
tool_export() { "$TOOL" export "$1" >/dev/null 2>&1; }
tool_switch() { "$TOOL" switch "$1" >/dev/null 2>&1; }
R_IMPORT="$TOOL import ~/.secrets/acct-export.json --force >/dev/null 2>&1"
R_SWITCH="$TOOL switch"
# end of the tool-command section
case $NUM in ''|*[!0-9]*) exit 1;; esac
ACCT=$(tool_identity "$NUM")
case $ACCT in ''|-*|*[!A-Za-z0-9._%+@-]*) exit 1;; esac
umask 077
mkdir -p ~/.secrets && chmod 700 ~/.secrets || exit 1
rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$@"; }
rcp() { scp -p -o BatchMode=yes -o ConnectTimeout=10 "$@"; }
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
cleanup() { trap '' INT TERM; find ~/.secrets -maxdepth 1 -name 'acct-export.json*' -delete; for h in "${DESTS[@]}"; do rsh "$h" '[ -d ~/.secrets ] || exit 0; find ~/.secrets -maxdepth 1 -name "acct-export.json*" -delete' || echo "token export may remain on $h"; done; }
trap cleanup EXIT
trap 'exit 130' INT TERM
for h in "${DESTS[@]}"; do rsh "$h" 'mkdir -p ~/.secrets && chmod 700 ~/.secrets' || exit 1; done
tool_export ~/.secrets/acct-export.json || exit 1
[ "$(perm ~/.secrets/acct-export.json)" = 600 ] || exit 1
for h in "${DESTS[@]}"; do rcp ~/.secrets/acct-export.json "$h:~/.secrets/acct-export.json" || exit 1; done
for h in "${DESTS[@]}"; do [ "$(rsh "$h" 'stat -c %a ~/.secrets/acct-export.json 2>/dev/null || stat -f %Lp ~/.secrets/acct-export.json')" = 600 ] || exit 1; done
for h in "${DESTS[@]}"; do rsh "$h" "$R_IMPORT && find ~/.secrets -maxdepth 1 -name 'acct-export.json*' -delete && $R_SWITCH '$ACCT' >/dev/null 2>&1" || exit 1; done
find ~/.secrets -maxdepth 1 -name 'acct-export.json*' -delete
tool_switch "$ACCT" || exit 1
```

Notes on the script:

- **bash and zsh.** An unquoted `$VAR` does not word-split in zsh, so the script uses an array
  and functions, and `find` instead of a bare glob (an empty glob is an error in zsh). Run it as
  `bash <file>`; it was also dry-run under zsh with stub `ssh`, `scp` and tool commands
  (`scripts/test/account-switch.sh` does both).
- **Destinations** are host names on `hosts.per_host`; a name not on that list is never a
  target. Where a host's ssh name differs, use what `cm_ssh_target` returns for it. If the home
  host does not have the `general` role, delete the last line (the home host keeps its account).
- **Partial failure.** A failure before the import loop (the `mkdir`, the export, the mode
  check, a copy) changes no account. A failure INSIDE the import loop leaves the destinations
  already switched on the new account and the rest on the old one, and the home host unswitched
  (it goes last). The tick then names each host's account from the listing's active marker
  (no tokens, no identities) and the next run finishes the move. An interrupt inside the import
  loop leaves the same state. Never retry the import in a loop: a host signed out after a switch
  (a refresh token rotated) needs a normal login on that host.
- **Running sessions.** Whether a running agent session picks up the new account without a
  restart depends on the agent and the tool, so check the host's weekly footer after the switch.
  A session that keeps its old account is restarted with its resume command (`references/resume.md`),
  which keeps the conversation.
- **Overnight**, do not spawn work for or nudge lanes that hold no active priority, so the
  priority work keeps the headroom. No script does this: the pause and the switch are manual
  tick steps.

## The check, after every run

A SEPARATE command, run after the script whatever its exit code (a SIGKILL or a tool timeout
skips the trap): on the home host, and then once per destination `<host>`. It prints names
only, never the file, and empty output means clean.

```bash switch-check
find ~/.secrets -maxdepth 1 -name 'acct-export.json*'
ssh -o BatchMode=yes -o ConnectTimeout=10 <host> '[ -d ~/.secrets ] || exit 0; find ~/.secrets -maxdepth 1 -name "acct-export.json*"'
```

A file left behind is deleted and named in the tick (path only). A host unreachable at that
time is recorded as "token export may remain" (path and host name only) and its delete is
retried every tick until the check comes back empty. The export holds every account's login
tokens: never print it, and never put it in a repo, a shared scratch path, a PR or a note.
