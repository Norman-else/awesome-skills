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
3. To check slide N, make a throwaway copy hard-coded to start there, e.g. if
   the deck boots via `syncHash();`:

   ```bash
   sed "s/syncHash();/go(N-1);/" deck.html > /tmp/check-N.html && open /tmp/check-N.html
   ```

   (`go()` is 0-indexed; one temp file per slide checked.)
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

Never close the browser or its tabs when finished — leave the deck on screen
for the user. Temp per-slide copies (`/tmp/check-*.html`) still get deleted.

## Reading screenshots correctly

- A blank or faint slide is usually the **entry animation's first frames** —
  staggered reveals start at `opacity: 0`. Wait 2 s and re-shoot before
  declaring it broken.
- If the page number advances between your screenshots, **a human is driving**
  (the user is flipping through your deck in the same browser). That's a
  success signal, not a bug. Stop opening new tabs; verify from what they show.
- Each `open` call spawns a new tab in the user's browser. Keep the count low
  (3–5 layout checks), mention the tabs, clean up your temp files.
