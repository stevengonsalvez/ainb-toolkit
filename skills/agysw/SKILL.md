---
name: agysw
description: Multi-account credential manager and switcher for the Antigravity CLI (agy).
---

## Commands

```bash
agysw list                                # show all accounts + status
agysw current                             # show active account
agysw switch <index|email>                # switch to specific account
agysw rotate                              # advance to next healthy account (uses saved strategy)
agysw rotate --strategy=<s>               # one-time: round-robin | random | sticky | least-used
agysw rotate --force                      # advance even if only one healthy account
agysw strategy [round-robin|random|sticky|least-used]  # view or set default strategy
agysw cooldown [hours=4]                  # mark current exhausted, rotate to next
agysw import                              # import active session into pool
agysw add <email> <refreshToken>          # add account with refresh token to pool
agysw remove <index|email>                # remove account from pool
```

## Shell integration

```bash
# ~/.zshrc or ~/.bashrc
agy() {
  agysw rotate > /dev/null 2>&1
  /path/to/agy "$@"
}

agycool() { agysw cooldown "${1:-4}"; }  # call when quota hit
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
`agysw` refreshes OAuth token for target account and writes credential envelope to both token file and platform keyring.

## Config

Default accounts database: `~/.gemini/antigravity-cli/antigravity-accounts.json`.
Override with `AGYSW_ACCOUNTS_PATH`.
Active token location: `~/.gemini/antigravity-cli/antigravity-oauth-token`.
Override with `AGYSW_TOKEN_PATH`.
