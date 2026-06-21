# Sourced options-paper pattern: agent memory systems

Use when `/explain-to-me` asks for a decision/options paper comparing an in-house agent memory/learning system with an external memory provider.

## Required source pass

1. Inspect local implementation, not just docs:
   - provider/plugin entrypoints
   - hook scripts
   - storage paths
   - retrieval/rerank/token-budget code
   - correction/deletion surfaces
2. Inspect external project docs and integration code:
   - retain/write path
   - recall/retrieval path
   - reflection/consolidation path
   - storage/backends
   - monitoring/observability
   - configuration defaults and token-budget knobs
3. Preserve secrets. If command output includes env examples or tokens, quote as `[REDACTED]` or omit.

## Minimum explainer sections

For memory-system comparisons, include these even if the chosen template does not explicitly ask for them:

- Architecture diagram for both systems.
- Full feature comparison table.
- Token economics section with cheap vs expensive configurations.
- Observability/correction section: inspect, edit, delete, trace, replay, source citation.
- Self-improvement section: how corrections become behavior changes, patterns, or skills.
- Recommendation with decision rule, not just a vibe.
- Pilot acceptance tests if recommending migration/hybrid adoption.

## Scoring guidance

Weight criteria to the user's stated priorities. For Stevie's Lambda memory work, default weights are:

- self-improvement fit: 0.25
- temporal fidelity: 0.22
- observability/correction: 0.22
- token efficiency: 0.20
- maintenance drag: 0.08
- portability: 0.03

Do not let generic long-term memory dominate the scoring if the user says they do not care about it.

## Token-cost pitfall

Memory systems often look cheap if you only evaluate retrieval. Evaluate both:

- write-side LLM extraction/consolidation cost
- read-side context injection cost

Call out dangerous defaults like auto-retain every turn plus large auto-recall context. Recommend tools-only or low-budget mode for pilots when token usage is a hard constraint.

## Verification before handoff

After publishing:

- fetch the live URL
- verify HTTP 200
- verify the title/core recommendation text is present
- report permanent vs anonymous publish mode from publish output
