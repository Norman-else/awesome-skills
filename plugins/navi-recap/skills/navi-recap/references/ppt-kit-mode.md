# ppt-kit mode — richer decks on the vendored html-ppt design system

navi-recap can build a deck two ways. **Both are valid; pick per the user's need.**

| Mode | What you get | When |
|---|---|---|
| **Native single-file** (default) | One self-contained `.html`, navi-recap's green-mono house style, zero build, "随手一发就能开" | Default. Best when portability/single-file matters. Start from `examples/slide-skeleton.html` + `references/deck-design.md`. |
| **ppt-kit mode** | A `deck + assets/` folder built on the vendored `ppt-kit/` design system: 36 themes, 31 layouts, full animation library, **S-key presenter mode + 逐字稿**, `render.sh` PNG export | When the user wants presenter mode, theme variety, richer layouts, or PNG export. Multi-file (not single-file). |

The narrative work is identical in both modes — **Phases 1–3 (mine → verify flows → narrate) do not change, and neither do the two iron rules.** ppt-kit only changes how Phase 4 renders.

## What `ppt-kit/` is

`ppt-kit/` is auto-vendored from upstream [`lewislulu/html-ppt-skill`](https://github.com/lewislulu/html-ppt-skill) (MIT) by `scripts/update-ppt.sh` at the marketplace root. **Never hand-edit anything under `ppt-kit/`** — edits get overwritten on the next sync. navi-recap's own additions (this file, `themes/navi-signal.css`) live outside it.

```
ppt-kit/
├── assets/
│   ├── base.css            token-based design system (load first)
│   ├── fonts.css
│   ├── runtime.js          keyboard nav + S-key presenter mode (current/next/script/timer)
│   ├── themes/*.css        36 themes
│   └── animations/         animations.css (CSS) + fx/*.js + fx-runtime.js (canvas FX)
├── templates/single-page/  31 layout files with demo data
├── templates/full-decks/presenter-mode-reveal/   presenter-mode exemplar w/ 逐字稿
├── scripts/render.sh       headless-Chrome → PNG
└── references/             upstream catalogs (themes / layouts / animations / presenter-mode)
```

## Keep the navi-recap identity: the `navi-signal` house theme

Use `themes/navi-signal.css` (navi-recap-owned) so a ppt-kit deck still looks like navi-recap — signal-green on near-black, serif headlines, mono labels. Load it as the theme:

```html
<link rel="stylesheet" href="ppt-kit/assets/base.css">
<link rel="stylesheet" href="ppt-kit/assets/fonts.css">
<link rel="stylesheet" id="theme-link" href="themes/navi-signal.css">
<script src="ppt-kit/assets/runtime.js"></script>
```

The user can still press `T` to try other themes, but `navi-signal` is the default that preserves the house look.

## Page-type → layout map

navi-recap's narrative page types (from `deck-design.md`) map onto ppt-kit's single-page layouts:

| navi-recap page type | ppt-kit layout(s) |
|---|---|
| Cover | `cover.html` |
| Stat grid + agenda (TL;DR) | `stat-highlight.html` / `kpi-grid.html` + `toc.html` for the agenda |
| Analogy + compare table (old vs new) | `comparison.html` / `table.html` / `two-column.html` |
| Flow steps (who triggers → system does → user sees) | `process-steps.html` / `flow-diagram.html` |
| Pipeline track (deploy/promotion) | `flow-diagram.html` / `roadmap.html` |
| Lifecycle fork (state machine) | `flow-diagram.html` / `mindmap.html` |
| Card grid (parallel features/agents) | `three-column.html` / `two-column.html` / `kpi-grid.html` |
| Key-value rows (smaller improvements) | `bullets.html` / `table.html` |
| Closing metaphor | `thanks.html` / `big-quote.html` / `cta.html` |

Copy the `<section class="slide">…</section>` block from the layout file, then replace demo data with the narrated content. Don't author layouts from scratch.

## Presenter mode + 逐字稿

ppt-kit's runtime has presenter mode built in — press **S** to open a window with CURRENT / NEXT / SPEAKER-SCRIPT / TIMER cards. Put 150–300 words of 逐字稿 per slide inside `<div class="notes">…</div>` (or `<aside class="notes">`). This pairs naturally with navi-recap's "讲故事" output. See `ppt-kit/references/presenter-mode.md` for the script-writing rules. The `presenter-mode-reveal` template under `ppt-kit/templates/full-decks/` is a worked example with notes on every slide.

## Build + verify flow (ppt-kit mode)

1. Scaffold the deck folder under the main repo's `monthly_product/` (same output convention as native mode), copying `ppt-kit/` alongside the deck HTML so asset paths resolve.
2. Assemble slides from the layout map above; theme with `navi-signal`.
3. Write 逐字稿 into `.notes` if the user wants presenter mode.
4. **Phase 5 browser verification still applies** — read `references/mac-verification.md`, open in the system browser, screenshot each distinct layout, fix until clean. (`render.sh` is for PNG export, not a substitute for the visual pass.)
