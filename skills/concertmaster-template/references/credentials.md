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

## Scan transcripts for leaked secrets (counts only)

`scripts/scan-secrets.sh` counts secret-shaped strings per class and per transcript file and prints
counts, never the matched text. Strict classes decide the exit code: private key, vendor token prefix,
JWT, AWS key, URL password, Bearer value. The advisory class (`password=` style assignment) is a noisy
heuristic that only counts with `--strict`. Run it after a session that touched credentials or env files,
and when a lane reports a pasted secret.

- Exit 1: a strict class hit. Exit 2: something could not be read, or nothing existed to scan; never read 2 as clean.
- A hit is a lead, not proof: a transcript that discusses a key shape counts too, and the `jwt` class cannot
  tell a public anon key or a short session token from a service-role key.
- Take the file from the `FILE` rows and give it to the owner for rotation. Rotate nothing yourself. Never open
  the transcript to look at the value and never quote it in an issue, PR or note.
- Dirs come from config `credentials.transcript_dirs`; pass paths to override; `--since-days n` bounds a run.
- Test: `scripts/test/scan-secrets.sh` (synthetic secrets are built at run time from split strings).

## Keep a login out of a tracked doc (doc credential scan)

Secret scanners know key shapes; none of them has a rule for a login written out in prose, such as a
Markdown line giving an address and a password side by side. `scripts/doc-credential-scan.sh` is that
check. It is a repo-level guard: copy it into the project repository (for example under `scripts/ci/`),
not a concertmaster tick step. The commit skill (`SKILL.md` hard rule 25) and this guard are the two layers.

- **What it refuses:** an ADDED line of a tracked `*.md`, `*.mdx`, `*.txt`, `*.yaml`, `*.yml` or `*.json`
  file (lockfiles and `node_modules` excluded) that holds an email address AND a password-looking value:
  `email / value`, `email: x, password: y`, a table row, a backticked value, `email:value@host`, or a value
  after a password word (`password`, `passwd`, `pwd`, `passphrase`, `passcode`, `pass`, `pw`, `login`,
  `credentials`). A value is 8 or more characters mixing 3 of lower, upper, digit and symbol; a pure-letter or
  lowercase-plus-digit value counts only after the strong password words with a real separator. Placeholders
  (`<...>`, `${...}`, `$NAME`, `xxx`, `changeme`, `redacted`), example addresses (`example.com`,
  `example.org`, `example.net`, `test.invalid`, `localhost`), ids, dates, versions and paths do not count.
- **Modes:** `--staged` (the lines added to the index), `--range <base>..<head>` (the lines a range adds)
  and `--all` (tracked files, counts per file only; hits never fail it).
- **Exit codes:** 0 clean (or `--all` finished), 1 a hit, 2 it could not look (not a repo, bad range,
  unreadable input, a failing awk). Never read 2 as clean.
- **Output:** path, line number and rule only. The line, the address and the value are never printed.
- **Marker:** a line carrying `credential-ok:` and a reason of 3 or more words is skipped, counted and printed
  as `path:line: allowed: <reason>` (a reason that is not plain words prints as "reason withheld"; with
  `GITHUB_ACTIONS=true` each use is also a `::warning` annotation). Nothing is allowed by name. JSON has no
  comments, so put the marker in a string value on the same line, or move the line to a `.md` file.
- **A red CI job is not a gate unless it is required.** Wired as a CI step it is only a red job a human must read
  unless the project makes it a required status check (or lists it in the merge gate). A green tick is not proof
  that no credential was added. The pre-commit hook is the only layer that stops a commit.
- **Not covered:** a credential added in one commit and removed in a later commit of the same PR (the range
  check sees the net diff, and with merge commits the first commit stays in history); source files and tests
  (neither this guard nor a key-shape rule looks for the shape there); a login split over several lines;
  a lowercase-plus-digit value after a weak word (`pass`, `pw`, `login`); a table row added under an unchanged
  password header; a passphrase with spaces; `.rst`, `.csv`, `.toml`, `.html` files.
- **Wiring (generic):** in the project's pre-commit hook, `bash scripts/ci/doc-credential-scan.sh --staged || exit 1`
  (skip it while a merge is in progress, where the index diff holds the other side's lines). In CI, with the
  scanner read from the default branch so a PR cannot weaken it:

  ```yaml
  - uses: actions/checkout@v4
    with: { fetch-depth: 0 }
  - name: Doc credential scan
    env:
      HEAD_SHA: ${{ github.event.pull_request.head.sha }}
    run: |
      set -euo pipefail
      BASE="$(git merge-base origin/main "$HEAD_SHA")"
      git show origin/main:scripts/ci/doc-credential-scan.sh > "$RUNNER_TEMP/doc-credential-scan.sh"
      bash "$RUNNER_TEMP/doc-credential-scan.sh" --range "$BASE..$HEAD_SHA"
  ```

  Run its test (`scripts/test/doc-credential-scan.sh`) as a separate required step so a change that breaks
  the detector goes red. The step must not use a path filter, or a docs-only change would skip the check.
- Tests: `scripts/test/doc-credential-scan.sh` (fixture credentials are built at run time from split strings)
  and `scripts/test/brief-commit-rule.sh` (the commit rule is in every brief template).

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
