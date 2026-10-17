# Credentials index and weekly check

A token that has expired is usually found only when a deploy needs it. This keeps an index of what the
fleet depends on and a weekly probe of whether each one still works.

```text
┌───────────────────────────┐   weekly    ┌───────────────┐   one read-only call    ┌──────────────┐
│ Bitwarden index secret    │────────────▶│ cred-check.sh │────────────────────────▶│ provider API │
│ (names only)              │  timer      │ token via     │◀──── 200 / 401 / 403 ───│              │
└───────────────────────────┘             │ stdin, never  │                         └──────────────┘
                                          │ printed       │──▶ inbox note: OK / INVALID / UNKNOWN
                                          └───────────────┘
```

## The index
JSON, seed at `references/credentials-index.seed.json`. One entry per credential: `name`, `source`
(`bws:<secret key>` or `file:<path>`), `kind` (how to probe it), `owner`, `usedBy`, `rotate` (the steps).
It holds NO values. `cred-check.sh --publish` refuses a file that contains anything shaped like a key.
Source of truth is the Bitwarden secret named by config `credentials.index_key`, created in the
Bitwarden project named by `credentials.bws_project` (both are config values; no project name is built in).
Add a credential: edit the JSON, run `scripts/cred-check.sh --publish FILE`.

## The check
`scripts/cred-check.sh` (tests: `scripts/test/cred-check.sh`, stubbed bws and curl). Run it on the
**concertmaster host only**: that is where the inbox note is read (SKILL.md, the tick). Per `kind`:

| kind | probe (read-only) | tokens it will send |
|---|---|---|
| supabase-pat | `GET api.supabase.com/v1/projects?limit=1` | `sbp_...` candidates (up to 5) |
| github | `GET api.github.com/rate_limit` (free) | `ghp_`/`gho_`/`ghs_`/`ghu_`/`ghr_`/`github_pat_` candidates |
| sentry | `GET sentry.io/api/0/organizations/` | `sntrys_`/`sntryu_`, or ONE bare 64-hex run (never when a second hex run is present: it could be another service's key) |
| stripe-test | `GET api.stripe.com/v1/balance` | `sk_test_...` only |
| cloudflare | `GET /client/v4/user/tokens/verify` | ONE standalone 40-character token, else nothing |
| vercel | `GET api.vercel.com/v2/user` | ONE standalone 24-character token, else nothing |
| manual, or `"probe": "skip"` | none | nothing |

Cloudflare and Vercel tokens have no distinctive prefix, so they are probed only when exactly one
standalone token of the exact length is in the value and it carries no other provider's prefix
(`sbp_`, `ghp_`, `eyJ`, ...). The value is first split into whole runs of token characters, so two adjacent look-alike tokens (`A B`, `A,B`) are never mistaken for one: with more than one candidate nothing is sent. A fragment of another secret is never sent to the wrong provider.

Result per entry: `OK` (200), `INVALID` (401/403 on every candidate), `MISSING` (the secret or file named in the index is not there any more, so nothing was checked), `UNKNOWN` (no confident token,
no network, other status, manual or skipped). An account-owned Cloudflare token or a team-scoped Vercel
token can be refused by this probe although it works: set `"probe": "skip"` on that index entry.
The token goes to curl on stdin, never argv, and is never printed, logged or written.

Run result: the table on stdout, and ALWAYS an inbox note `~/.concertmaster/inbox/cred-check-<UTC with seconds>-<pid>.md`,
also for a FATAL. Exit codes: 0 all fine, 1 at least one INVALID or MISSING, 3 FATAL (no jq, no usable index, a
Bitwarden access token that no longer works), 2 bad usage. The systemd unit shows failed on 1 and 3, which is
the point. The concertmaster tick surfaces `INVALID` and `FATAL` rows from the note (SKILL.md, tick step 4).
Index lookup order: the Bitwarden index secret, `~/.concertmaster/credentials-index.json`,
`~/.concertmaster/credentials-index.seed.json` (the install copies the seed there), the skill's seed.

## Install on the concertmaster host (Linux with systemd; macOS is out of scope)
```bash
mkdir -p ~/.concertmaster/bin ~/.local/state
cp scripts/cred-check.sh scripts/lib.sh ~/.concertmaster/bin/ && chmod +x ~/.concertmaster/bin/cred-check.sh
cp references/credentials-index.seed.json ~/.concertmaster/credentials-index.seed.json
cp config.yaml ~/.concertmaster/config.yaml   # lib.sh finds it there (CM_HOME/config.yaml)
# fill the @USER@ and @HOME@ tokens of the units; the PATH line must reach bws (~/.local/bin is
# missing from systemd's default PATH)
for u in concertmaster-cred-check.service concertmaster-cred-check.timer; do
  sed "s|@USER@|$(id -un)|g; s|@HOME@|$HOME|g" "references/systemd/$u" | sudo tee "/etc/systemd/system/$u" >/dev/null
done
sudo systemctl daemon-reload && sudo systemctl enable --now concertmaster-cred-check.timer
# verify (read-only, prints the table, writes no note): needs bws and ~/.secrets/bws-access-token
~/.concertmaster/bin/cred-check.sh --dry-run
systemctl list-timers concertmaster-cred-check.timer --no-pager
```
Re-copy the two scripts after each merge; a copied script does not update itself.
