# Third-party software and content

Reviewed: 2026-10-13

The root [MIT license](../LICENSE) covers original ainb-toolkit contributions
only. It does not change the license of third-party material. Retain the
licenses, copyright notices, and attribution below when redistributing a
listed component.

## Bundled material

| Path | Upstream | License | Required action |
| --- | --- | --- | --- |
| `skills/react-components/` | [google-labs-code/stitch-skills](https://github.com/google-labs-code/stitch-skills) | Apache-2.0 | Preserve Google copyright headers. Apache terms are present in `skills/webapp-testing/LICENSE.txt`; no upstream NOTICE file was found. |
| `skills/scrapling-official/` | [D4Vinci/Scrapling](https://github.com/D4Vinci/Scrapling) | BSD-3-Clause | Preserve `LICENSE.txt`, copyright, and non-endorsement clause. |
| `skills/notebooklm/` | [PleasePrompto/notebooklm-skill](https://github.com/PleasePrompto/notebooklm-skill) | MIT | Preserve upstream attribution and MIT terms. Upstream is archived. |
| `skills/ui-ux-pro-max/` | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | MIT | Preserve upstream attribution and MIT terms. |
| `skills/media-processing/` | [mrgoonie/claudekit-skills](https://github.com/mrgoonie/claudekit-skills/tree/main/.claude/skills/media-processing) | MIT | Preserve upstream attribution and MIT terms. |
| `skills/skill-creator/` | [anthropics/skills at `ef740771`](https://github.com/anthropics/skills/tree/ef740771ac901e03fbca3ce4e1c453a96010f30a/skills/skill-creator) | Apache-2.0 text included | Source components proven by exact Git blob hashes: `LICENSE.txt` `7a4a3ea`, `scripts/package_skill.py` `5cd36cb`, and `scripts/quick_validate.py` `d9fbeb7`. Other files are locally modified or added. Preserve Apache terms and do not relicense. |
| `skills/webapp-testing/` | [anthropics/skills at `ef740771`](https://github.com/anthropics/skills/tree/ef740771ac901e03fbca3ce4e1c453a96010f30a/skills/webapp-testing) | Apache-2.0 text included | Source components proven by exact Git blob hashes: `LICENSE.txt` `7a4a3ea`, `examples/console_logging.py` `9329b5e`, `examples/static_html_automation.py` `90bbedc`, and `scripts/with_server.py` `431f2eb`. Other files are locally modified or added. Preserve Apache terms and do not relicense. |
| `plugins/agytoggle/` | Source not recorded, creator named in package metadata | MIT | Preserve creator attribution and MIT metadata. Establish public upstream before material change. |

`plugins/demo/skills/capture/scripts/motion.mjs` records Cap renderer behaviour
and its source commit for provenance. It states that its implementation is
independent and that no Cap code is copied. Cap's repository is AGPL-3.0 for
content not separately identified as MIT, so Cap material is not bundled here.

## Runtime-loaded dependency

| Use | Upstream | License | Required action |
| --- | --- | --- | --- |
| Generated `plugins/demo/skills/compose` HTML | [GreenSock GSAP 3.14.2](https://www.npmjs.com/package/gsap/v/3.14.2) | [GSAP Standard no-charge license](https://gsap.com/standard-license/) | Not bundled. Generated HTML fetches the pinned jsDelivr artifact with SRI `sha384-sG0Hv1tP1lZCk9KQmrIbY/XNwi+OY84GQqhMscbnsoBFqAz8KNCil1kvfL3Hbbk2`; GreenSock's license applies to that fetched package. |

## Referenced installers, not bundled source

`external-dependencies.yaml` is an installation catalogue. It does not vendor
the repositories below. Their licenses were checked at their public upstream
repositories on 2026-10-13. Installers must retain each upstream license in the
consumer environment.

| Entry | Upstream | License |
| --- | --- | --- |
| `apm-cli` | [microsoft/apm](https://github.com/microsoft/apm) | MIT |
| `ui-ux-pro-max` | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | MIT |
| `notebooklm` | [PleasePrompto/notebooklm-skill](https://github.com/PleasePrompto/notebooklm-skill) | MIT |
| `scrapling-official` | [D4Vinci/Scrapling](https://github.com/D4Vinci/Scrapling) | BSD-3-Clause |
| `fireworks-tech-graph` | [yizhiyanhua-ai/fireworks-tech-graph](https://github.com/yizhiyanhua-ai/fireworks-tech-graph) | MIT |
| `antv-infographic` | [antvis/Infographic](https://github.com/antvis/Infographic) | MIT |
| `architecture-diagram` | [Cocoon-AI/architecture-diagram-generator](https://github.com/Cocoon-AI/architecture-diagram-generator) | MIT |
| `stitch-skills` | [google-labs-code/stitch-skills](https://github.com/google-labs-code/stitch-skills) | Apache-2.0 |
| `mcporter` | [openclaw/mcporter](https://github.com/openclaw/mcporter) | MIT |
| `graphify` | [safishamsi/graphify](https://github.com/safishamsi/graphify) | Apache-2.0 |
| `caveman` | [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | Apache-2.0 |
| `agent-browser` | [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | Apache-2.0 |
| `obsidian-skills` | [kepano/obsidian-skills](https://github.com/kepano/obsidian-skills) | MIT |
| `impeccable` | [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | Apache-2.0 |
| `archify` | [tt-a1i/archify](https://github.com/tt-a1i/archify) | MIT |
| `cloudflare-skills` | [cloudflare/skills](https://github.com/cloudflare/skills) | Apache-2.0 |
| `higgsfield-skills` | [higgsfield-ai/skills](https://github.com/higgsfield-ai/skills) | MIT |
| `gogcli-skills` | [openclaw/gogcli](https://github.com/openclaw/gogcli) | MIT |
| `claude-peers` | [louislva/claude-peers-mcp](https://github.com/louislva/claude-peers-mcp) | MIT |
| `brag` | [latent-spaces/brag](https://github.com/latent-spaces/brag) | MIT |

The following catalogue entries have no public source URL or license pin in
`external-dependencies.yaml`: `reflect-kb`, `browserbase-skills`, `gws-skills`,
`here-now`, `find-skills`, `summarize`, `agent-skills`, `claude-in-mobile`, and
the registry-only Claude plugin entries. They are not copied into this
repository. Their source and license must be verified before an installer is
changed to vendor them.

## Decisions still required

1. Record public upstream locations for `skill-creator`, `webapp-testing`, and
   `agytoggle`, or remove those components before a separately packaged release.
2. Pin source and license metadata for every unpinned installer entry before
   claiming a fully reproducible third-party supply chain.
