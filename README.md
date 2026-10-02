# agysw: Antigravity CLI Account Switcher

Manages multiple Google accounts for the **Antigravity CLI (`agy`)**. When one account hits its daily quota, `agysw` rotates to the next healthy account automatically (no re-login required).

**Platforms:** Linux (token file + Secret Service if present), macOS (Keychain)

---

## How it works

`agy` reads its active session from `~/.gemini/antigravity-cli/antigravity-oauth-token` (and the system keyring under `service=gemini`, `account=antigravity`).  
`agysw` refreshes the OAuth token for the target account and writes it directly to both the token file and the keyring.  
The next `agy` command picks it up instantly.

---

## Installation & Setup

**In ainb-toolkit:**

Link binary to user path:
```bash
ln -sf "$(pwd)/plugins/agysw/agysw.js" ~/.local/bin/agysw
chmod +x plugins/agysw/agysw.js
```

**Import your active session:**
```bash
agysw import
```

**Recommended shell wrapper** (add to `~/.zshrc` or `~/.bashrc`):
```bash
# Rotates to next account before every agy session
agy() {
  agysw rotate > /dev/null 2>&1
  /path/to/agy "$@"
}

# Run this when agy says "Individual quota reached"
agycool() {
  agysw cooldown "${1:-4}"
}
```

---

## Commands

| Command | What it does |
|---|---|
| `agysw list` | Show all accounts with active/cooldown status |
| `agysw current` | Show which account is active right now |
| `agysw switch <n\|email>` | Switch to account by index or email address |
| `agysw rotate` | Advance to the next healthy account (uses saved strategy) |
| `agysw rotate --strategy=<s>` | Rotate with specific strategy override |
| `agysw rotate --force` | Advance even if only one healthy account exists |
| `agysw cooldown [hours]` | Mark current account exhausted for N hours, then rotate |
| `agysw strategy [name]` | View or set default rotation strategy |
| `agysw import` | Import current active session from `antigravity-oauth-token` |
| `agysw add <email> <token>` | Add account with refresh token to pool |
| `agysw remove <n\|email>` | Remove account from pool |

---

## Rotation strategies

Set default with `agysw strategy <name>`, or override per call with `agysw rotate --strategy=<name>`.

| Strategy | Behavior |
|---|---|
| `round-robin` | Advance to next healthy account in order, wrap around at end *(default)* |
| `random` | Pick random healthy account each time |
| `sticky` | Stay on current account until exhausted, then switch |
| `least-used` | Always pick whichever healthy account was used longest ago |

```bash
agysw strategy random              # set default
agysw rotate --strategy=sticky     # one-time override
agysw rotate --force               # advance even if only one healthy account exists
```

---

## Handling quota exhaustion

When `agy` returns `Individual quota reached`:

```bash
agycool        # marks current account exhausted for 4h, switches to next healthy account
agycool 2      # same but 2h cooldown
```

Cooldowns are stored in the accounts database and respected by all rotate strategies.

---

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `AGYSW_ACCOUNTS_PATH` | `~/.gemini/antigravity-cli/antigravity-accounts.json` | Path to accounts database |
| `AGYSW_TOKEN_PATH` | `~/.gemini/antigravity-cli/antigravity-oauth-token` | Path to active token file |
| `ANTIGRAVITY_CLIENT_ID` | *(bundled)* | Override OAuth client ID |
| `ANTIGRAVITY_CLIENT_SECRET` | *(bundled)* | Override OAuth client secret |
