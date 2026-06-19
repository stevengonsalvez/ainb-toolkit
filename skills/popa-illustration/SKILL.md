---
name: popa-illustration
description: Generate Popa-style hand-drawn explanatory illustrations. Use when the user asks for "popa"/"illustration"/"explainer image"/"shot list"/"diagram but fun" assets for articles, blog posts, LinkedIn/X posts, READMEs, websites, slides, architecture explainers, methodologies, processes, states, or metaphors. Defaults to the Popa IP (pink blob, green sprout, notepad), crude hand-drawn line art on soft pastel scenes, deadpan-absurd humor, strict-minimal density.
user-invocable: true
---

# Popa Illustrations

## Core positioning

Design and generate hand-drawn explanatory illustrations for anything Stevie writes or builds: articles, social posts, READMEs, slides, and architecture explainers. The goal is not commercial illustration or PPT infographics — it is to turn a key judgment, process, structure, state, or metaphor into one clean, funny, readable-but-not-instructional hand-drawn image on a soft pastel scene.

The visual IP is **Popa**: a pink round blob with a green sprout on its head, big glossy black eyes, a tiny smile, and a notepad + pen. Popa is earnest, slightly bureaucratic, and fully committed to whatever absurd system job the image requires. The cuteness is the setup; the deadpan absurd labor is the punchline. Popa must carry the core action of the image — never decorate it.

## Read these references first

Read on demand per task; do not stuff them all into context at once:

- `references/style-dna.md`: pastel + crude-line visual law, color roles, taboos.
- `references/popa-ip.md`: Popa's anchors, personality, action library, the notepad gag, and taboos.
- `references/composition-patterns.md`: structure types, format presets, the architecture-series pattern, original-metaphor method.
- `references/prompt-template.md`: per-image generation prompt template (multi-aspect).
- `references/qa-checklist.md`: post-generation checks and iteration rules.
- `assets/popa-ref/`: Popa's source renders from popajob — character reference only, NOT the target render style.
- `assets/examples/`: low-frequency visual calibration only. Do not copy these compositions, objects, or labels.

## Workflow

### 1. Digest the source

Read whatever the user gives: article, README, codebase, diagram, idea, or rant. Extract:

- The core argument or system
- Which parts carry the cognitive turns
- What's image-worthy vs better left as text

Do not illustrate evenly. Pick cognitive anchors: the core judgment, breakpoints, input/output loops, splits, before/after contrasts, common pitfalls, state changes, the one weird part of the architecture everyone trips on.

### 2. Shot list first

If the user asks for strategy ("where should images go / how to illustrate this"), output a shot list. Per image:

- Placement (after which section)
- Theme and core idea
- Structure type and format preset (aspect)
- What Popa is doing (the absurd job)
- Suggested elements and label words
- Optional: the notepad gag line

Default 4-8 images for articles; 1 for social; series-of-3-to-5 for architecture.

### 3. Generate

If the user asks to generate, don't stop for confirmation. Generate each image separately via the available image backend (nano-banana-pro / `image_gen`); never collage. Fill `references/prompt-template.md` with the right aspect preset.

Every prompt must carry the four Popa anchors (sprout, pink blob, glossy eyes + tiny smile, notepad somewhere in scene) and the pastel-scene DNA.

Invent a fresh metaphor per image from the current source. Never reuse example compositions unless explicitly asked.

### 4. Check and iterate

Run `references/qa-checklist.md`. Regenerate or locally edit when: Popa is decoration, an anchor is missing, the frame is crowded, it reads as PPT/mascot-poster, labels exceed 8, or the aspect drifted.

### 5. Save and deliver

Copy finals to `assets/<slug>-illustrations/`, numbered `01-topic-name.png`. Keep originals; never overwrite existing assets without being asked.

Delivery report: how many, what each is for, save paths, which are solid vs optional. Short. Let the images do the talking.
