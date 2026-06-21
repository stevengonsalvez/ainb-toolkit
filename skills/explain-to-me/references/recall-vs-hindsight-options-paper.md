# Case study: Lambda recall/reflect vs Hindsight options paper

Session: architecture/feature comparison explainer for Stevie deciding whether to replace custom Lambda recall/reflect plugin with Hindsight memory.

## User intent shape

This was not a generic explainer. It needed an options-paper artifact with:

- Architecture of both systems.
- Full feature comparison.
- Unbiased recommendation.
- Explicit weighting against user priorities:
  - self-improvement very important
  - temporal memory important, long-term memory less important
  - observability and correction/editability important
  - token usage important

Correct template: `22-options-paper.html`.

## Grounding pattern that worked

Use both local implementation evidence and upstream docs before writing decision content.

Local Lambda files used as evidence:

- `fleet-lambda/specs/fleet-hooks/behaviors/bank-lookup.md`
- `fleet-lambda/harnesses/hermes/plugins/fleet-hooks/bank_lookup.py`
- `fleet-lambda/harnesses/hermes/plugins/fleet-hooks/correction_detector.py`
- `fleet-lambda/harnesses/hermes/plugins/fleet-hooks/learning_sync.py`
- `fleet-lambda/harnesses/hermes/plugins/fleet-hooks/discovery_context.py`

Local Hermes Hindsight files used as evidence:

- `hermes-agent/plugins/memory/hindsight/README.md`
- `hermes-agent/plugins/memory/hindsight/__init__.py`
- `hermes-agent/tests/plugins/memory/test_hindsight_provider.py`

External Hindsight source used:

- `https://raw.githubusercontent.com/vectorize-io/hindsight/main/README.md`

Key Hindsight architecture claims from upstream README:

- Memory structures: World facts, Experiences, Mental Models.
- Memories stored in banks.
- `retain` uses LLM extraction for facts, temporal data, entities, relationships, then normalizes into canonical entities/time series/search indexes + metadata.
- `recall` runs semantic vector search, BM25 keyword search, graph entity/causal/temporal traversal, and temporal filtering in parallel.
- Results are fused/reranked, then trimmed to token budget.
- `reflect` performs deeper analysis across memories.

Key Hermes plugin implementation facts:

- Provider tools: `hindsight_retain`, `hindsight_recall`, `hindsight_reflect`.
- Recall sends `bank_id`, `query`, `budget`, `max_tokens`, optional `tags`, `tags_match`, `types`.
- `hindsight_retain` requires `content`, builds retain kwargs, calls `client.aretain`.
- `hindsight_reflect` calls `client.areflect(bank_id=..., query=..., budget=...)`.
- Shutdown closes client but intentionally does not stop module-global background event loop.

## Recommendation pattern

For this class of decision, do not recommend a binary migration if the systems solve different layers.

Recommended framing:

> Adopt Hindsight as temporal memory substrate, but keep Lambda’s self-improvement control plane: correction detector, learning sync, discovery gossip, inbox/journal/sleep-cycle rules, BANK/pattern observability, and HOT promotion.

Why:

- Hindsight wins on temporal recall and synthesis quality.
- Lambda wins on explicit correction workflow, governance, observability, fleet-specific self-improvement loops, and predictable local/token behavior.
- User’s priorities point to composition: Hindsight for memory substrate, Lambda for behavioral control plane.

## Token-usage comparison points

Include concrete token/cost mechanics, not vague “efficient” claims.

- Lambda BANK lookup has hard local injection cap (`BANK_LOOKUP_MAX_TOKENS`, observed default 2000) but HOT memory can create always-loaded prompt bloat.
- Hindsight has `recall_max_tokens` style caps and memory modes (`context`, `tools`, `hybrid`) but tool schemas, recall output, retain extraction, and reflect backend calls all have token/cost implications.
- Default recommendation for token-sensitive use: disable blanket prefetch/injection, use tool/context only when query-relevant, enforce low max_tokens, log actual per-turn memory tokens.

## Publishing result

Generated local artifact:

- `$HOME/explainers/recall-vs-hindsight-memory.html`

Published result:

- `https://proud-ritual-2hxq.here.now/`

The live URL was verified by browser navigation and page title check.
