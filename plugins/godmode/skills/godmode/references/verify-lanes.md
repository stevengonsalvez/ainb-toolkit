# VERIFY lanes — surface-routed proof

VERIFY drives the real surface and reads the outcome. `/validate` checks a
spec; VERIFY proves a user-visible truth plus its side effects. Every epic
must pass its lane(s) before it ships. Human is the last gate on each epic.

## Surface detection

Classify EACH touched file; the epic runs the **UNION of all matched lanes**.
The row qualifiers describe pure single-surface epics only — a mixed epic
matches multiple rows. Worked example: an epic touching a Supabase edge
function AND React components runs the API lane (auth matrix on the function)
AND the Web UI lane (journey drive) — the web lane's DB probe is NOT a
substitute for the API lane's negative/role cases. The charter may
force/override lanes.

| Signal (per file) | Lane |
|---|---|
| React/Vue/Svelte components, index.html, vite/next config | **Web UI** |
| ratatui/ink/bubbletea/curses, terminal entrypoint | **TUI** |
| route handlers/edge functions/OpenAPI specs | **API** |
| pure modules with a public API, no runnable surface | **Library** |

## Cross-cutting doctrine (all lanes)

- **Mock ONLY the human**, at the input boundary: injected text/keystrokes/
  requests. Everything downstream is real (real services, real DB on the
  validation backend — never production).
- **Read the artefact, don't blank-check**: a pass asserts the CORRECT
  content (the right diff, the right row, the right pixel/text), never
  "something rendered" / "status 200".
- **Transduction proven once**: expensive/flaky input transforms (STT, OCR)
  get ONE round-trip proof; every other test injects post-transduction text.
- **Evidence or it didn't happen**: upload artifacts (GIFs, videos, frames,
  transcripts, query results) to here.now; link from the dashboard Evidence
  tab and the PR body.
- **Negative + role cases**: every permission/visibility claim gets the
  third-party/wrong-role probe, not just the happy path.

## Web UI lane

Harness: Playwright (headless, `CI=true`, fake-media flags for device APIs) or
browser-harness (screenshot → coordinate click → re-screenshot verify).
- Journeys from the epic's plan; one spec per journey.
- Assert rendered truth (visible text/state via the page, screenshots at
  settle points) AND the side effect (DB row via API/SQL probe).
- Seams for nondeterministic inputs (e.g. a test-only event emitter) must be
  double-gated behind env flags so they never ship active.
- Where the platform behaves this way (common on SPA + preview-deploy stacks
  like Vercel): navigate to the login route directly (landing pages often hide
  the form) and prefer password auth — magic links redirect to the canonical
  host, not your preview URL.

## TUI lane (the tmux-verify contract)

Harness: tmux + VHS. Six gates:
1. Automated tripwire test green ×3 (VT100-true asserts, non-flaky).
2. One `.tape` per user journey → `vhs` → GIF + MP4, `Screenshot` at each
   settle point. Quote paths containing `/` or `-`; `Key@500ms` is Type-only.
3. Extract frames (ffmpeg) and **READ them** — assert the exact user-visible
   outcome per journey. OCR is best-effort; eyes on the PNGs are the gate.
4. Fix loop until acceptance + tripwire green.
5. Explainer updated with the GIFs.
6. Human validates last.
- Drive via `tmux new-session -d` / `send-keys` / `capture-pane -p` for
  interactive probes; VHS for the recorded journeys.
- Isolated `HOME` with COMPLETE app seed files (a partial config that fails to
  deserialize re-triggers first-run modals that swallow keys — frames then
  record the wrong screen).
- tmux safety: only ever `tmux kill-session -t <exact-name>`.

## API lane

Harness: scripted real requests (curl suites as TAP-style scripts, httpie, or
a Postman collection when richer). Per endpoint/change:
- Happy path: status + body SHAPE (jq asserts on fields, not string equality
  on the whole body).
- Auth matrix: no-token, wrong-role token, right-role token — and where the
  platform distinguishes gateway-level vs function-level auth failures (e.g.
  Supabase), assert WHICH layer rejected, not just the status code.
- Side effects: query the store afterwards (row exists, right columns, no
  forbidden columns/PII leaked).
- Contract regressions: keep the suite cumulative — every epic's probes join
  the programme's regression spine and run on all later epics.
- jq trap: `//` treats `false` as empty — extract booleans with
  `if has("k") then (.k|tostring) else empty end`.

## Library lane

- Unit tests (behavioural, table-driven where the domain is enumerable).
- Property-based tests for parsers/normalizers/matchers (fast-check/jqwik).
- Mutation testing where the toolchain exists; otherwise adversarial review
  explicitly hunts test theatre (tests that pass without the fix).
- Pure modules: dependency-inject I/O (roster, clock, fs) — the suite runs
  with zero network.
