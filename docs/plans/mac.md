# omxplorer on the Mac: from "it runs" to "it looks right"

First run on real hardware: 2026-10-22, owner's Apple Silicon Mac, the `omxplorer-mac-arm64-untested.zip` from the v0.1.0-alpha pre-release. **It runs.** The start screen, the sample (1,000,000 rows on the CPU, 3–5 ms per query), the inspector, the Report's tiles and the status bar all work. It doesn't look right yet.

## What the screenshots show

| # | What's wrong | Likely cause (unverified until the Mac confirms) |
|---|---|---|
| 1 | **The grid never shows**: "orders · 1,000,000 rows", then an empty page | `DataGrid` has never run on AppKit (docs/components.md: ❌). Its Canvas most likely gets no height inside the page's stack, or never receives its first frame |
| 2 | **Old text stays under new text**: the formula bar's cell name reads "revenue 2" over "freight 4"; the bottom tabs draw twice | when a patch replaces a text or a button, the host adds the new view without removing the old one |
| 3 | **The Report's chart is empty**: the sentence and its words show, the bars don't | the same Canvas problem as 1, inside a card |
| 4 | **The toolbar**: tiny icons spread across the width; after switching to the Report, only the chart icon is left | toolbar buttons (`TOOL`) are ❌ on AppKit; the Lucide icons map to SF Symbols one by one, and the missing ones vanish |
| 5 | **Small things**: the side column's buttons are centred, not left-aligned; the logo and Settings show "?"; the CPU card's text is cut off; the inspector has a large gap under Table/Cell; Column stats are centred | alignment and SF Symbol names in the AppKit host |
| 6 | **Choose a file does nothing** (expected) | the file picker isn't built on AppKit (❌) |

## The rule for these sessions

Each step below fits a short session: one fix, a Mac build, one check by the owner. The Mac can't be seen from Linux, so the first step builds the tool that makes every later step checkable without a long back and forth (Build the Lever).

## Steps

**M0 · The Mac reports on itself.** `OMXPLORER_SELFTEST=<dir>` runs omxplorer's existing test steps (open the sample, select a cell, open the Report, open the inspector) and, after each one, writes:
- a PNG of the window (`bitmapImageRepForCachingDisplayInRect:`);
- a text dump of every view: its class, frame and text.

Then the app quits. `apple/mac_selftest.sh` runs it and zips the folder. The owner runs one command and sends one zip; I read sizes and overlaps from the dump instead of guessing from screenshots.
*Check:* the zip has a PNG and a dump per step; the dump of today's build shows the grid's canvas size (it should explain problem 1).

**M1 · The grid shows.** Fix whatever M0's dump shows: most likely the canvas's height inside the page, or its first frame.
*Check:* the self-test's "sample" PNG shows rows and column headers; scrolling moves them.

**M2 · No stale text.** A patch that replaces a view removes the old one.
*Check:* after selecting two cells, the dump has one cell-name label and one set of bottom tabs.

**M3 · The Report's chart draws.** Most likely fixed by M1; if not, the card's canvas gets the same fix.
*Check:* the "report" PNG shows bars.

**M4 · The toolbar.** Toolbar buttons at their GTK size and spacing; every Lucide name used by omxplorer has an SF Symbol, and a test fails when one is missing.
*Check:* the toolbar matches GTK's order and grouping in the PNG; the test lists no missing symbol.

**M5 · Polish.** Left-aligned side column, the logo and Settings icons, the CPU card's text wraps, no gap in the inspector, Column stats aligned.
*Check:* the start and inspector PNGs, side by side with GTK's.

**M6 · Choose a file.** The file picker opens `NSOpenPanel`.
*Check:* the owner opens a CSV on the Mac (only the owner can check this one).

**M7 · The Mac's own Liquid Glass (later, the owner's call).** The owner's macOS 26 shows maccheck with the older look (2026-10-22). The binary is already stamped SDK 26.0, so that isn't the cause. Glass on macOS 26 comes mostly from system pieces the host doesn't use yet: a real `NSToolbar` with a unified title bar, a sidebar from `NSSplitViewController`, and `NSGlassEffectView` behind floating bars. On top of that, the skinned themes paint an opaque page over everything. Open question for the owner: the house style (omxqua) says no glass or blur, so native glass would be an opt-in look, e.g. a "Mac native" theme that doesn't paint the page.
*Check:* the toolbar and the side column sit on glass in the owner's screenshot, with GTK and the web unchanged.

## Constraints

- Linux and web stay green: `scripts/check` after every step.
- Don't touch `../mojo-ui-apple-test`.
- Each step ships as a release asset only when the owner asks.
- The start screen's "Coming with MX frame" is the rename thread's job, not this plan's.
