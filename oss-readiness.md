# OSS readiness audit

Audit date: 2026-10-13

Repository: `stevengonsalvez/ainb-toolkit`

The public default branch is not ready to declare complete until the linked
pull requests merge and the remaining owner decisions below are resolved.

| thread | state | next |
| --- | --- | --- |
| secrets | PASS: no real credential found | merge cleanup PR |
| history | PASS: fixture alert only | no rewrite needed |
| GitGuardian | FAIL: API key absent | add Actions secret |
| license | FAIL: root MIT unmerged | merge PR 129 |
| third-party | FAIL: provenance gaps remain | decide removals |
| internal references | FAIL: cleanup unmerged | merge PR 130 |
| docs | FAIL: community docs unmerged | merge PR 131 |
| CI | PASS: required PR checks green | keep checks required |

## Pull requests

| Pull request | Head SHA | Scope | Checks |
| --- | --- | --- | --- |
| [#129](https://github.com/stevengonsalvez/ainb-toolkit/pull/129) | `1533f2379aa9052c512388a38c7bc97b42fba2f7` | MIT license and third-party inventory | all required checks passed |
| [#130](https://github.com/stevengonsalvez/ainb-toolkit/pull/130) | `5cb019abf92dca01206e55bf41cd07058436edb7` | public cleanup and generated catalog | all required checks passed |
| [#131](https://github.com/stevengonsalvez/ainb-toolkit/pull/131) | `79cc73b0d868ac3813f39f4db7b22545c98c6daf` | contributor, security, conduct, issue, and PR docs | all required checks passed |

## Secrets and history

- Gitleaks 8.21.2 scanned the working tree and full reachable history. It
  reported one history finding in commit `af9a450c34519275e350352d65b14cce681284fb`:
  `plugins/orchestrate/tests/hardening.sh`, GitHub PAT rule, first four
  characters `ghp_`.
- That value is a deliberate `secret_refused` test fixture beside fake AWS,
  Slack, bearer-token, and private-key examples. It is not a live credential.
- The working-tree scan reported seven instructional or test fixtures. No
  tracked `.env`, private-key, keystore, or credential file was found.
- No credential rotation or history rewrite is required from these results.

## GitGuardian

`.github/workflows/security.yml` already contains the fork-safe model. It
checks out full history, exposes `GITGUARDIAN_API_KEY` only from Actions
secrets, emits a visible warning and exits successfully when the key is absent,
otherwise installs `ggshield` on Python 3.12 and runs `ggshield secret scan ci`.

No `.gitguardian.yaml` exists. The latest GitGuardian check succeeded, but its
log confirms that the API key was absent, so it took the visible skip path. No
GitGuardian organization App linkage could be established from repository files
or public check status.

The same workflow runs Gitleaks 8.24.3 against a full checkout.

## License and third-party material

The first and latest reachable commits are both from 2026 and name Steven
Gonsalvez as author. PR #129 adds the canonical MIT text with that copyright
holder. Its SHA-256 is:

```text
c60f7454aeb83d30260d866b48e5b83b1cb4701a66258f30784cd3d325b56a42
```

The file matches GitHub's MIT template after substituting the owner and year.
The default branch still has no root license, and GitHub reports no detected
license until PR #129 merges.

`docs/THIRD-PARTY.md` in PR #129 records bundled Apache-2.0, BSD-3-Clause, MIT,
and GreenSock material; source-only installer references; attribution duties;
and unresolved provenance. It does not relicense third-party work.

## Internal references and cleanup

PR #130 removes a private implementation plan and a tracked Python cache. It
replaces personal paths and personal test addresses with neutral fixtures,
removes deployment-specific project mapping and local env discovery, and
expands `.gitignore` for credentials, logs, caches, local state, and editor
output. It also corrects a public evaluation source that was incorrectly marked
internal, then regenerates the Backstage catalog.

## Documentation

PR #131 adds `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, a bug
report form, a pull request template, and an honest README status section.
`SECURITY.md` directs vulnerability reports to GitHub private vulnerability
reporting and does not publish an email address.

## Verification

| Command | Result |
| --- | --- |
| `scripts/check-agentskills-conformance skills packages/qe-agent-pack/.apm/skills packages/test-writer-pack/.apm/skills` | pass, 101 conforming skills |
| `scripts/generate-backstage-catalog --check` | pass |
| `scripts/sync-qe-agent-pack --check` | pass |
| `bats tests/plugin` | pass, 76 cases with one explicit skip |
| `python3 -m pytest tests/e2e/test_backstage_catalog.py` | pass, 16 passed and 2 skipped |
| clean-room `apm install` and `apm audit --ci --policy` | pass, all 31 policy checks |
| `npm test` after `npm ci` | fail, existing Jest ESM parsing failure in `plugins/agytoggle/agytoggle.test.js` |

All required GitHub checks are green on each readiness pull request:
`agentskills.io conformance`, `APM install and audit`, `apm-audit`, `bats`,
`gitleaks secret scan`, and `gitguardian ggshield scan`.

## Decisions for Stevie

1. Add the `GITGUARDIAN_API_KEY` repository Actions secret, then confirm a
   GitGuardian job executes a real scan rather than the skip path.
2. Enable GitHub private vulnerability reporting if it is not already enabled.
   This audit did not change repository settings.
3. Confirm GreenSock Standard no-charge license permits redistribution of the
   bundled `gsap.min.js`, or approve its replacement with an install-time
   dependency.
4. Record public upstream sources for `skill-creator`, `webapp-testing`, and
   `agytoggle`, or approve their removal before a separately packaged release.
5. Merge PRs #129, #130, and #131. No credential rotation or history rewrite is
   required by this audit.
