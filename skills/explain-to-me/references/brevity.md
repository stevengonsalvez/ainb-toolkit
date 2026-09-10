# Brevity — the house style for explainer content

Default was ~500 words per finding. Target is ~50. Same information, less text.

## The block

```
ID  Title                          INDICATOR · EFFORT · bead
    first read: X  →  after challenge: Y        (only if it flipped)

    thing ──▶ thing ✗                           what breaks, one line

    ┌─ side A ──────────┐   ┌─ side B ──────────┐   only when two things differ
    │ 3 lines max       │   │ ⚠ marks the risk  │
    └───────────────────┘   └───────────────────┘

    DO       the action                          ≤3 lines
    SPLIT    if it is two tickets                ≤3 lines
    ⚠        what contradicts the obvious read   ≤3 lines
    BLOCKED  what stops it                       ≤2 lines

    [evidence ▸]                                 collapsed, uncapped
```

## Rules

- **Cut, never compress.** Over budget → drop the point. Do not rewrite it smaller.
- **Flows beat sentences.** `A ──▶ B ✗` says more than a paragraph about A and B.
- **Boxes only for contrast.** Two systems, two states, before/after. Never one box.
- **Red/clay marks the problem only** — the ✗, the ⚠, the zero that matters. Never decoration.
- **Evidence collapses.** Citations and live results go behind `[evidence ▸]`, uncapped.
  Not deleted: 16 of 23 first readings were overturned this session, and evidence is
  what caught them.
- **No preamble.** No "It is worth noting that", no restating the title.

## Too complex for the block?

Draw it. Flowchart, complex region filled `#B85C3E`, one line naming why it is hard.
A finding that needs three flows is three findings.

```
  parse ──▶ ┌───────────┐ ──▶ write
            │ 2 clubs   │  ← red: the hard part
            │ unmapped  │
            └───────────┘
```

## The bar

If someone must read a sentence twice, it failed. If they can act from the block
without opening evidence, it worked.
