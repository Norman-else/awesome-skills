# ppt-kit mode — richer decks on the vendored html-ppt design system

product-recap can build a deck two ways — **both build on ppt-kit, so both support
all 37 themes (press T to cycle; default `navi-signal`).** The forms differ only
in packaging. **Single-file is the default. When in doubt, single-file.**

> product-recap does **not** use presenter mode. It is intentionally left out of
> this skill — don't write 逐字稿/speaker-notes or point users at the S key.

| Form | What you get | When |
|---|---|---|
| **Single-file** (DEFAULT) | One self-contained `.html` with `base.css` + all 37 themes + nav/T runtime inlined; theme choice + T-cycle built in; zero external files, "随手一发就能开" | The default. Copy `examples/themed-single-skeleton.html`, paste layout blocks from `ppt-kit/templates/single-page/`. See `references/deck-design.md`. |
| **ppt-kit folder form** (opt-in only) | A `deck + assets/` folder linking `ppt-kit/` directly | ONLY when the user needs things that don't inline cleanly: the canvas-FX animation library or `render.sh` PNG export. Multi-file. |

The narrative work is identical in both modes — **Phases 1–3 (mine → verify flows → narrate) do not change, and neither do the two iron rules.** ppt-kit only changes how Phase 4 renders.

## What `ppt-kit/` is

`ppt-kit/` is vendored from upstream [`lewislulu/html-ppt-skill`](https://github.com/lewislulu/html-ppt-skill) (MIT); see `ppt-kit/UPSTREAM.json` for the pinned ref. **Never hand-edit anything under `ppt-kit/`** — re-vendor from upstream instead so edits don't get lost. product-recap's own additions (this file, `themes/navi-signal.css`) live outside it.

```
ppt-kit/
├── assets/
│   ├── base.css            token-based design system (load first)
│   ├── fonts.css
│   ├── runtime.js          keyboard nav (← → / T theme / F fullscreen / O overview)
│   ├── themes/*.css        36 themes
│   └── animations/         animations.css (CSS) + fx/*.js + fx-runtime.js (canvas FX)
├── templates/single-page/  31 layout files with demo data
├── scripts/render.sh       headless-Chrome → PNG
└── references/             upstream catalogs (themes / layouts / animations)
```

(`runtime.js` is upstream's and technically still has an S-key presenter view,
but product-recap does not use or document it — ignore it.)

## Choosing a theme (recommend → let the user pick)

Once the user is in ppt-kit mode, **don't silently apply a theme — recommend
`navi-signal` plus 2–3 audience-appropriate alternatives and let them choose.**
When running interactively, surface this as a quick pick (e.g. an
AskUserQuestion); if they don't care, fall back to `navi-signal`. The user can
always press `T` in the browser to cycle through all 36 themes live.

| Audience / tone | Recommend |
|---|---|
| **Default — keeps the product-recap identity** | `navi-signal` (signal-green on near-black, serif headlines, mono labels) |
| Exec / formal / non-engineer readability | `swiss-grid`, `corporate-clean`, `minimal-white` |
| Engineering / tech sharing | `tokyo-night`, `dracula`, `terminal-green` |
| Narrative / editorial storytelling | `editorial-serif`, `magazine-bold` |
| 小红书图文 | `xiaohongshu-white`, `soft-pastel` |

Full catalog with when-to-use: `ppt-kit/references/themes.md`. Load the chosen
theme via the `theme-link` stylesheet (house theme shown):

```html
<link rel="stylesheet" href="ppt-kit/assets/base.css">
<link rel="stylesheet" href="ppt-kit/assets/fonts.css">
<link rel="stylesheet" id="theme-link" href="themes/navi-signal.css">
<!-- or an upstream theme: href="ppt-kit/assets/themes/tokyo-night.css" -->
<script src="ppt-kit/assets/runtime.js"></script>
```

`navi-signal` lives in `themes/` (product-recap-owned); the other 36 live in
`ppt-kit/assets/themes/` (vendored). Whatever the user picks, the narrative and
iron rules are unchanged.

## Page-type → layout map

product-recap's narrative page types (from `deck-design.md`) map onto ppt-kit's single-page layouts:

| product-recap page type | ppt-kit layout(s) |
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

## Build + verify flow (ppt-kit mode)

1. Scaffold the deck folder under `<base>/recap/` (same output rule as the single-file form — see SKILL.md "Output location"), copying `ppt-kit/` alongside the deck HTML so asset paths resolve.
2. Assemble slides from the layout map above; theme with the chosen theme (default `navi-signal`).
3. **Phase 5 browser verification still applies** — read `references/mac-verification.md`, open in the system browser, screenshot each distinct layout, fix until clean. (`render.sh` is for PNG export, not a substitute for the visual pass.)
