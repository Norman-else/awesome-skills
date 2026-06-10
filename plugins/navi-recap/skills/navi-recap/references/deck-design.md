# Deck design system

A recap deck is a presentation, not a webpage: one theme per slide, driven by
keyboard, readable from the back of a room.

## Aesthetic direction

- **Echo the product's own visual identity.** If the product's console is dark
  minimal-mono, the deck should feel like a sibling of it — same accent color
  family, same mood. Never default to generic AI aesthetics (purple gradients,
  Inter-on-white, cookie-cutter cards).
- **CJK typography pairing** (Chinese decks): serif display for headlines
  (`Noto Serif SC` 900), sans for body (`Noto Sans SC` 300–500), monospace for
  labels/numbers/eyebrows (`JetBrains Mono`). The serif-headline + mono-label
  contrast is what makes it feel designed.
- One dominant accent color with semantic variants (e.g. signal green for
  "good/new", amber for "manual gate", red for "failure"). Texture via subtle
  grain + scanline overlays, not gradients.

## Engineering checklist (all mandatory)

- Single self-contained HTML file; Google Fonts is the only network dependency.
- Navigation: `←`/`→`/Space/PageUp/PageDown, Home/End, `F` fullscreen,
  on-screen arrow buttons, touch swipe.
- Progress bar + `NN / NN` mono counter.
- Deep links: read `#N` on load **and listen to `hashchange`** (without the
  listener, editing the URL bar does nothing), plus `?s=N` fallback.
- Staggered entrance reveals: elements carry `class="rv" style="--d:n"`;
  `.slide.active .rv` animates with `animation-delay: calc(var(--d)*90ms)`.
  Re-triggers on every slide entry.
- Responsive fallback below ~900px: single column, slide scrolls vertically.

## Page-type component library

Build every slide from these proven types (see `../examples/slide-skeleton.html`
for working markup of the starred ones):

| Type | Use for |
|---|---|
| Cover ★ | title, period, headline mono metrics |
| Stat grid + agenda ★ | TL;DR slide: N big numbers + section index |
| Analogy + compare table | "old way vs new way" themes; analogy in a bordered callout, `||` table with the new column accented |
| Flow steps ★ | numbered `01..0N` steps with connector line; each step = who triggers → system does → user sees |
| Pipeline track | deploy/promotion flows: nodes + `→` links; gates in amber, prod in accent green |
| Lifecycle fork | state machines (e.g. 👀 → ✅/❌/🚫): one source state, arrow, stacked outcome states |
| Card grid ★ | 2–4 parallel features or new agents |
| Key-value rows | dense lists of smaller improvements |
| Closing | one serif metaphor sentence + recap rows + thank-you |

## Content rules

- Slide 1 cover, slide 2 TL;DR with numbers, last slide a closing metaphor that
  compresses the whole story (e.g. "this month we gave it a ledger, a brake, a
  gatekeeper, and a guardrail").
- Flows never exceed ~5 steps on a slide; split or simplify.
- Body text in plain language; technical nouns allowed in mono tags
  (`REDIS STREAM`, `FAIL-CLOSED`) where they add credibility without prose.
