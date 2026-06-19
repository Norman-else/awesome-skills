---
name: product-recap
description: Use when an engineer wants to turn one or more local repos' git history into a product-evolution story or HTML slide deck — for ANY repo, not just Navi. Run it from any directory (defaults to the current repo); name extra sibling repos to merge into one deck, optionally scope to a sub-path, and give a time window. Mines the canonical branch (origin/default, so a feature-branch checkout is fine), verifies flows in code, narrates for non-engineers, and builds a single-file HTML deck. Triggers on "summarize this repo's commits into a deck", "recap the changes under services/x last quarter", "make a slide deck of what shipped across these two repos", "product-recap".
---

# Product Recap — git history → product story → slide deck

## Overview

Turn a window of git commits (across one or more local repos) into a story a
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
| Repo(s) | the current repo if cwd is a git work tree; else ask |
| Branch | `origin/<default-branch>` per repo (auto-detected; overridable) |
| Window | past month (`--since`) |
| Path scope | none (optional `-- <subpath>` per repo) |
| Audience | non-engineers; plain language + analogies; write in the user's language |
| Theme | `navi-signal` (press **T** to cycle 37) |
| Stop point | ask: Markdown story only, or full HTML deck |

## Running location & repo resolution

Runs from **any directory** — there is no "must be inside a repo" gate. Resolve
the repos to mine like this:

- If **cwd is inside a git work tree**, that repo is the default repo to mine.
- The engineer may name **additional** repo paths (and may name repos explicitly
  even when cwd is not a repo).
- Validate each resolved repo: `git -C <repo> rev-parse --is-inside-work-tree`
  must print `true`; if one doesn't, stop and name which path failed.
- If cwd is not a repo **and** no repo was named, ask which repo(s) to recap
  rather than guessing.

## Phase 1 — Mine

**Always mine the canonical branch, never the current checkout.** A local clone
may be parked on a feature branch; the recap must reflect what actually shipped.
Per repo: fetch, resolve the default branch, then log against the `origin/` ref.

```bash
git -C <repo> fetch --quiet origin
# default branch via origin/HEAD; if unset, fall back to main then master:
BR=$(git -C <repo> symbolic-ref --quiet --short refs/remotes/origin/HEAD | sed 's#^origin/##')
git -C <repo> log --since="<date>" --pretty=format:"%h|%ad|%s" --date=short "origin/$BR" [-- <path>]
git -C <repo> log --since="<date>" --pretty=format:"%h %s" --shortstat "origin/$BR" [-- <path>]  # size = feature vs fix signal
```

- The branch is overridable (e.g. a release branch); default is `origin/HEAD`.
- **Tag every commit with the repo it came from** — Phase 2 needs to know which
  repo's code to read, and the deck merges across repos (see below).
- **Sweep sibling repos.** Prompts, agent definitions, and CI pipelines often
  live outside the main repo. Ask the user / check neighbors before concluding.
- Group commits by product theme. Discard merge commits and pure-fix noise.

### Cross-repo merge (one deck from N repos)

Engineers often span two repos (an API repo + a prompts/CI repo) but want **one**
deck. Merge **by product theme, never by repo**:

- A capability whose backend is in repo A and whose prompts/CI are in repo B
  becomes **one slide** describing the end-to-end behavior.
- Repos are an implementation detail — never make "repo A" / "repo B" top-level
  sections. The non-engineer audience should see products, not repository
  structure (iron rule 2 applied across repos).
- Headline numbers aggregate across repos (total commits, "N repos").

## Phase 2 — Verify flows

For every theme that needs a flow diagram, dispatch a read-only explore
subagent (or read the code yourself) to confirm the end-to-end behavior:
**who triggers → what the system does → what the user sees**. The agent reads
code in whichever repo(s) the flow touches. Ask it to flag where reality differs
from your draft description, and keep the corrections.

## Phase 3 — Narrate

- Open with a one-sentence TL;DR + headline numbers (commits, repos, new
  capabilities).
- Per theme: *what problem* → *analogy in plain language* → *flow as numbered
  steps* → *old vs new comparison table* where it helps.
- End with a priority order ("if you only have 10 minutes, present these").
- One theme per future slide. Group ruthlessly; see iron rule 2.

## Phase 4 — Build the deck (if requested)

Two output forms — both build on the ppt-kit design system, so **both support
theme choice** (37 themes; default `navi-signal`; press **T** to cycle live).
The forms differ only in packaging. **Default to single-file.** Phases 1–3 and
the two iron rules are identical either way. **product-recap does not use
presenter mode / 逐字稿 — don't offer it in either form.**

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
vendored from upstream — never hand-edit `ppt-kit/` or
`examples/themed-single-skeleton.html`; re-vendor from upstream instead.

**Output location (deterministic rule):**

```
<base>/recap/<slug>-recap_<YYYY.MM.DD>-<YYYY.MM.DD>.html
```

1. **`<base>`** — if cwd is inside a git work tree, the repo top level
   (`git rev-parse --show-toplevel`); otherwise the invocation cwd itself
   (never write into a repo the engineer only named to mine but didn't `cd` into).
2. **Folder** — always `recap/` under `<base>` (`mkdir -p <base>/recap`).
3. **`<slug>`** — repo basename (e.g. `api`); path-scoped →
   `<repo>-<lastPathSegment>` (e.g. `monorepo-billing`); multi-repo → a combined
   name the user confirms (e.g. `navi`).
4. **Dates** — the analysis window as `YYYY.MM.DD`.

Examples:

```
~/work/api/recap/api-recap_2026.05.01-2026.06.01.html        # run inside api repo
~/Infras/Navi/recap/navi-recap_2026.05.01-2026.06.01.html    # Navi + sibling repo, one deck
~/reports/recap/billing-recap_2026.05.01-2026.06.01.html     # run from a non-repo dir
```

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
| Mining the current checkout | A clone may sit on a feature branch; fetch + log `origin/<default>` so the recap reflects what shipped |
| Trusting commit messages for flow diagrams | Messages compress and mislead; verify in code (Phase 2) |
| Only mining the main repo | Prompts/CI live in sibling repos; the recap silently misses whole features |
| Sectioning the deck by repo | Merge by product theme; the audience sees products, not repository structure |
| Timeline / week-by-week organization | Audience needs themes and final states, not chronology |
| `open "file:///deck.html#7"` to check slide 7 | macOS strips the fragment — you land on slide 1 every time |
| Headless Chrome for screenshots | Often SIGKILLed in sandboxed envs; budget one attempt, then use the GUI path |
| Declaring a blank screenshot "broken" | Entry animations + a human may be driving the browser; re-shoot after a pause |
| Leaving temp verification copies around | User may share the wrong file; delete them and state the real path |
