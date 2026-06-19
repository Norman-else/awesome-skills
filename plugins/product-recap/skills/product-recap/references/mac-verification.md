# Verifying an HTML slide deck on macOS

Goal: visually confirm specific slides render correctly (layout, CJK fonts,
overflow) when the deck picks its slide from `location.hash` at load time.

## The traps (all observed in real sessions)

1. **`open "file:///path/deck.html#7"` does NOT work.** macOS LaunchServices
   strips both the `#fragment` and the `?query` from `file://` URLs before the
   browser sees them. The page loads with no hash, your JS falls back to slide
   1, and nothing errors. Same for `open -a "Google Chrome" <url>`.
2. **Headless Chrome is often dead on arrival.** In sandboxed agent
   environments `Google Chrome --headless --screenshot` may exit 1 with no
   output or be SIGKILLed (exit 137) even for `--version`. Also fails if the
   user's profile is locked by a running Chrome (use `--user-data-dir=/tmp/...`
   when you do try). Budget exactly one attempt, then switch to the GUI path.
3. **Browsers are "read" tier for computer-use.** You can screenshot but not
   click, type, or scroll. You cannot press `→` to advance slides. Do not work
   around this with AppleScript / System Events — that is forbidden, not clever.
4. **Multi-monitor:** the screenshot result names the captured display and
   lists the others; switch to the display that has the browser before
   concluding "nothing is on screen".

## The procedure that works

1. `open /path/deck.html` (plain path — this survives) to confirm slide 1.
2. Request computer-use access for the browser; screenshot; inspect.
3. To check slide N, make a throwaway copy hard-coded to start there AND to
   close its own tab after 2 minutes, e.g. if the deck boots via `syncHash();`:

   ```bash
   sed "s/syncHash();/go(N-1);setTimeout(()=>window.close(),120000);/" deck.html \
     > /tmp/check-N.html && open /tmp/check-N.html
   ```

   (`go()` is 0-indexed; one temp file per slide checked.) The `window.close()`
   works because a tab opened by `open` has a one-entry history, which Chrome
   allows scripts to close — verified empirically. This is the ONLY sanctioned
   way to clean up verification tabs: you cannot click the ✕ at "read" tier,
   and AppleScript is forbidden. Never inject the self-close into the real
   deck — temp copies only.

   Why copies instead of testing the final HTML directly: the real file always
   opens on slide 1 (`open` strips `#N`/`?s=N`, and you cannot press → at
   "read" tier), so reaching slide N requires changing the boot line — and
   mutating the deliverable to navigate is how a stray `go(6)` or self-close
   timer ends up in the deck someone presents. The real file is verified as-is
   for slide 1; every other slide is checked on a disposable copy. (If a
   Claude-in-Chrome MCP is connected, drive the real file directly instead —
   it can navigate tabs, making temp copies unnecessary.)
4. Screenshot ~1.5 s after opening. Verify one instance of each *distinct
   layout*, not every slide.
5. Clean up: `rm /tmp/check-*.html`, and tell the user the real deck path
   explicitly so they don't present from a temp copy.

## The verify–fix loop (exit criteria)

Verification is a loop, not a single pass:

1. `open <deck-path>` → screenshot → analyze.
2. Issue found (overflow, broken layout, missing font, unreadable contrast) →
   edit the HTML → `open <deck-path>` again to load the fixed version (this is
   the "refresh": you cannot press ⌘R at read tier) → re-inspect.
3. Loop until one full inspection pass finds nothing. Only then report done.

Never close the browser or the real deck's tab when finished — leave the deck
on screen for the user. Temp verification tabs clean themselves up via their
injected `window.close()` timer; their files (`/tmp/check-*.html`) still get
deleted with `rm`. If you regenerate a copy after a fix, the new tab gets a
fresh timer; stale tabs from before the fix close on their own schedule.

## Reading screenshots correctly

- A blank or faint slide is usually the **entry animation's first frames** —
  staggered reveals start at `opacity: 0`. Wait 2 s and re-shoot before
  declaring it broken.
- If the page number advances between your screenshots, **a human is driving**
  (the user is flipping through your deck in the same browser). That's a
  success signal, not a bug. Stop opening new tabs; verify from what they show.
- Each `open` call spawns a new tab in the user's browser. Keep the count low
  (3–5 layout checks), mention the tabs, clean up your temp files.
