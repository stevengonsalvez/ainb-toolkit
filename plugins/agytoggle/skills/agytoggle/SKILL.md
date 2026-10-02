---
name: agytoggle
description: Multi-account credential manager and profile switcher for the Antigravity CLI (agy).
---

## Commands

```bash
agytoggle list                                # show all accounts + status
agytoggle current                             # show active account
agytoggle switch <index|email>                # switch to specific account
agytoggle rotate                              # advance to next healthy account (uses saved strategy)
agytoggle rotate --strategy=<s>               # one-time: round-robin | random | sticky | least-used
agytoggle rotate --force                      # advance even if only one healthy account
agytoggle strategy [round-robin|random|sticky|least-used]  # view or set default strategy
agytoggle cooldown [hours=4]                  # mark current exhausted, rotate to next
agytoggle import                              # import active session into pool
agytoggle add <email> <refreshToken>          # add account with refresh token to pool
agytoggle remove <index|email>                # remove account from pool
```

*(Note: `agysw` is supported as a direct CLI alias for `agytoggle`)*

## Shell integration

```bash
# ~/.zshrc or ~/.bashrc
agy() {
  agytoggle rotate > /dev/null 2>&1
  /path/to/agy "$@"
}

agycool() { agytoggle cooldown "${1:-4}"; }  # call when quota hit
```

## Rotation strategies

| Strategy | Behavior |
|---|---|
| `round-robin` | Advance to next healthy in sequence, wrap around *(default)* |
| `random` | Pick random healthy account |
| `sticky` | Stay on current if healthy, switch only when exhausted |
| `least-used` | Pick healthy account with oldest lastUsed timestamp |

## How it works

`agy` reads its active session from `~/.gemini/antigravity-cli/antigravity-oauth-token` (and system keyring).
`agytoggle` refreshes OAuth token for target account and writes credential envelope to both token file and platform keyring.

## Config

Default accounts database: `~/.gemini/antigravity-cli/antigravity-accounts.json`.
Override with `AGYTOGGLE_ACCOUNTS_PATH` or `AGYSW_ACCOUNTS_PATH`.
Active token location: `~/.gemini/antigravity-cli/antigravity-oauth-token`.
Override with `AGYTOGGLE_TOKEN_PATH` or `AGYSW_TOKEN_PATH`.
