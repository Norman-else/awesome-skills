---
name: navi-recap
description: Use when the user asks to turn git commit history into a product-evolution story or presentation (in any language) — e.g. "summarize last month's product changes from git history", "monthly recap", "make a PPT/slide deck of what shipped to share", "navi-recap". Defaults to the Navi + engineering-agent-registry repos but works for any repo and time window.
---

# Navi Recap — git history → product story → slide deck

## Overview

Turn a window of git commits (across one or more repos) into a story a
non-engineer can follow, optionally rendered as a single-file HTML slide deck.

Two iron rules:

1. **Commit messages are leads, not facts.** Any feature you will draw as a
   flow must be verified end-to-end in the code first. (Real failure: a commit
   said "authorization gating" — the message read like a user whitelist; the
   code was an LLM classifier. The deck would have been wrong.)
2. **Final states only, never intermediate ones.** Twenty UI-fix commits on the
   same panel = one bullet describing the final behavior. No week-by-week
   timeline, no "then we refactored" — the audience sees what the product *is
   now* vs what it was.

## Inputs (defaults — confirm or override)

| Input | Default |
|---|---|
| Repos | `~/Infras/Navi` **and** `~/Infras/engineering-agent-registry` |
| Branch | always `master` (local if checked out on it; else the remote master) |
| Window | past month; a start (`--since`) **or a closed range** (`--since` + `--until`) |
| Audience | non-engineers; plain language + analogies; write in the user's language |
| Stop point | ask: Markdown story only, or full HTML deck |

## Phase 1 — Mine

**Mine the canonical `master`, never the current checkout.** A clone may be
parked on a feature branch; the recap must reflect what actually shipped. Fetch
master, then log `origin/master` — this reads the **remote** master regardless of
which branch the working copy is on.

```bash
git -C <repo> fetch --quiet origin master
git -C <repo> log --since="<start>" [--until="<end>"] --pretty=format:"%h|%ad|%s" --date=short origin/master
git -C <repo> log --since="<start>" [--until="<end>"] --pretty=format:"%h %s" --shortstat origin/master  # size = feature vs fix signal
```

- **Window** — default past month (`--since` only, end = today). The user may
  give just a start, or a **closed range** with both ends ("April only",
  "2026.04.01–2026.05.01") via `--until`. The output filename's date range must
  match the actual window (open-ended → end = today).
- **Reading code at master (Phase 2).** If the checkout is already on `master`,
  read in place. If it's on another branch, don't read the diverged working tree
  — add a throwaway worktree at the fetched master and read from there:

  ```bash
  git -C <repo> worktree add --detach /tmp/navi-recap-<name>-master origin/master
  # ... explore/verify flows here ...
  git -C <repo> worktree remove --force /tmp/navi-recap-<name>-master
  ```

- **Sweep sibling repos.** Prompts, agent definitions, and CI pipelines often
  live outside the main repo. Ask the user / check neighbors before concluding.
- Group commits by product theme. Discard merge commits and pure-fix noise.

## Phase 2 — Verify flows

For every theme that needs a flow diagram, dispatch a read-only explore
subagent (or read the code yourself) to confirm the end-to-end behavior:
**who triggers → what the system does → what the user sees**. Ask it to flag
where reality differs from your draft description, and keep the corrections.

## Phase 3 — Narrate

- Open with a one-sentence TL;DR + headline numbers (commits, repos, new
  capabilities).
- Per theme: *what problem* → *analogy in plain language* → *flow as numbered
  steps* → *old vs new comparison table* where it helps.
- End with a priority order ("if you only have 10 minutes, present these").
- One theme per future slide. Group ruthlessly; see iron rule 2.

## Phase 4 — Build the deck (if requested)

Two output forms — both build on the ppt-kit design system, so **both support
theme choice** (37 themes; default `navi-signal` green-mono; press **T** to
cycle live). The forms differ only in packaging. **Default to single-file.**
Phases 1–3 and the two iron rules are identical either way. **navi-recap does
not use presenter mode / 逐字稿 — don't offer it in either form.**

- **Single-file — THE DEFAULT.** Copy `examples/themed-single-skeleton.html` —
  one self-contained HTML with `base.css` + all 37 themes + the nav/T runtime
  inlined (zero external files, maximally portable). Fill in slides by pasting
  `<section class="slide">` blocks from `ppt-kit/templates/single-page/*.html`
  and replacing the demo data. Default theme is `navi-signal`; the user can
  press **T** to cycle all 37. Read `references/deck-design.md` for the
  aesthetic + content rules.
- **ppt-kit folder form — opt-in only.** A `deck + assets/` folder that links
  `ppt-kit/` directly. Use only when the user needs things that don't inline
  cleanly: the canvas-FX animation library or `render.sh` PNG export. Multi-file.
  Guide: `references/ppt-kit-mode.md`.

**Theme selection (both forms):** recommend a theme by audience (`navi-signal`
default + alternatives) — see `references/ppt-kit-mode.md` → "Choosing a theme".
The user can always press **T**. The single-file template and `ppt-kit/` are
auto-vendored/generated from upstream by `scripts/update-ppt.sh` — never
hand-edit `ppt-kit/` or `examples/themed-single-skeleton.html`; re-run the script.

**Output location (fixed convention):** save the deck under the main repo's
root in a `monthly_product/` directory — create it if it doesn't exist:

```bash
mkdir -p <main-repo-root>/monthly_product
```

**Filename:** `Navi-Product_<date-range>.html`, where the date range is the
analysis window as `YYYY.MM.DD-YYYY.MM.DD`. Example:

```
~/Infras/Navi/monthly_product/Navi-Product_2026.05.10-2026.06.10.html
```

For a non-Navi repo, substitute the product name: `<Product>-Product_<date-range>.html`.
Never leave the final deck in `/tmp` (temp verification copies only — see
Phase 5).

## Phase 5 — Verify in the browser until clean (mandatory)

Building the file is not the end of the task. Read
`references/mac-verification.md` **before** trying to screenshot the deck —
macOS has silent traps (`open` strips `#fragment` and `?query` from file URLs;
headless Chrome may be SIGKILLed; browsers are screenshot-only at "read" tier).

Then run this loop until the deck is visually clean:

1. **Open** the deck in the system browser: `open <deck-path>` (plain path).
2. **Inspect** via screenshots: layout, CJK font rendering, overflow/clipping,
   contrast, animation end-state. Cover one instance of each distinct slide
   layout, not every slide.
3. **Found a problem?** Fix the HTML yourself, then **refresh by re-running
   `open <deck-path>`** (you cannot click reload at "read" tier; re-opening
   loads the updated file), and go back to step 2.
4. **Repeat** until a full pass finds no issues.

Only after a clean pass may you tell the user the deck is done — never declare
completion on an unverified or known-broken deck. **Leave the browser open**
with the real deck showing — the user takes over from there. Temp verification
copies carry an injected self-close timer so their tabs disappear on their own
(see the reference doc); delete their files and never let the timer or a
hard-coded start slide leak into the real deck.

## Common mistakes

| Mistake | Reality |
|---|---|
| Mining the current checkout | A clone may sit on a feature branch; fetch + log `origin/master` (and read code via a master worktree) so the recap reflects what shipped |
| Trusting commit messages for flow diagrams | Messages compress and mislead; verify in code (Phase 2) |
| Only mining the main repo | Prompts/CI live in sibling repos; the recap silently misses whole features |
| Timeline / week-by-week organization | Audience needs themes and final states, not chronology |
| `open "file:///deck.html#7"` to check slide 7 | macOS strips the fragment — you land on slide 1 every time |
| Headless Chrome for screenshots | Often SIGKILLed in sandboxed envs; budget one attempt, then use the GUI path |
| Declaring a blank screenshot "broken" | Entry animations + a human may be driving the browser; re-shoot after a pause |
| Leaving temp verification copies around | User may share the wrong file; delete them and state the real path |
