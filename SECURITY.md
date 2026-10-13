# Security policy

Report suspected vulnerabilities through [GitHub private vulnerability
reporting](https://github.com/stevengonsalvez/ainb-toolkit/security/advisories/new).
Do not open a public issue for a potential security vulnerability.

Include affected paths, reproduction steps, impact, and any safe mitigation.
Do not include live credentials in the report. Maintainers will acknowledge
and triage reports through GitHub.

The repository runs Gitleaks on all history in the security workflow. The
GitGuardian job performs a `ggshield secret scan ci` when its Actions secret is
configured, and emits a visible warning when it is not configured.
