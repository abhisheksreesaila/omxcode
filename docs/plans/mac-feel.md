# The Mac, Linux and the web side by side: nobody can tell them apart

Owner, 2026-10-23, after the third Mac round: "if I can show them the Linux app and the Mac app next to each other and they can't tell the difference, that's the big win." It has to be the same Mojo code with the theme on top, with nothing written just for omxplorer: "we are developing a platform, not an app." iPhone and Android come later.

## Why the Mac looks plain

A `Theme` is two hand-written style sheets, `gtk_css` and `web_css` (about 77 KB across five themes), plus a palette. The AppKit host reads only the palette (`paint_native`), so the Mac never gets the Liquid or Omarchy look: the type scale, the islands' fills, corners and shadows, control heights, or padding. Every new host would need a third copy of each theme by hand.

The themes also style views by tag. Most of those tags come from framework components (`toolbar`, `status-bar`, `inspector`, `stat-card`, `kpi-note`), but four belong to omxplorer itself (`add-tile`, `app-mark`, `tile`, `chart-tile`). A notes app built from the same components wouldn't get that part of the look, so those four have to become components.

## The owner's list, ranked

| # | What | Kind | Step |
|---|---|---|---|
| 1 | No theme on the Mac (Liquid, Omarchy); title bar squeezed; tiny text | platform: themes are per-host CSS | M1–M3 |
| 2 | The chart sentence's choice popover: text squished, unusable | AppKit popover sizing | M4 |
| 3 | Report "+ Average / + Sum" tiles show only "+" | AppKit button title | M4 |
| 4 | Drag-select needs a hard press | AppKit Canvas mouse handling | M5 |
| 5 | A formula didn't work | unknown: reproduce in CI first | M5 |
| 6 | No file opener | NSOpenPanel (`FilePicker` ❌ on AppKit) | M6 |
| 7 | Start page: the disabled "Connect a database" sits off its column | alignment of disabled rows | M4 |
| 8 | GPU on Apple Silicon (Metal) | separate test apps, then the frame engine | M7, needs the owner's Mac |

## Steps

**M0 · The lever: see all three side by side.** One command runs the same steps on GTK (headless), the web (headless Chromium) and the Mac (GitHub runner) at the same window size, then puts the three pictures of each step next to each other in one page. It also lists each tagged view's size per host where it can: GTK and the Mac dump frames; the web gives bounding boxes. From then on, "can't tell the difference" is something I look at, not something I guess.
*Check:* the page shows omxplorer's start, sheet and Report on three hosts.

**M1 · A second app, so nothing overfits.** `examples/notes`: a list of notes, an editor, search, a settings sheet, built only from existing components, with no tags and no CSS of its own. It runs on all three hosts in M0's page. Any fix that helps omxplorer but not notes is the wrong fix.
*Check:* notes in M0's page on three hosts.

**M2 · Themes as data, read by every host.** A theme's look becomes Mojo values: a type scale, control sizes, padding, and fills, corners, rims and shadows per surface role. Each host renders those values: GTK writes CSS from them, the web writes CSS from them, and AppKit sets fonts, layer colours, corners, shadows and sizes. The hand-written CSS shrinks to what only one host has, such as GTK's keyframes and the web's hover rules. omxplorer's four tags become components (an add tile, the app mark, tiles) so every app gets them.
*Check:* GTK and the web pictures don't change (pixel diff against today's goldens); `scripts/check` green.

**M3 · Liquid and Omarchy on the Mac.** AppKit applies M2's values: Inter and the type scale, glass islands for the menu bar and toolbar, the chrome bar heights, button pills, cards.
*Check:* M0's page: omxplorer and notes, Liquid and Omarchy, the Mac next to GTK, no difference I can point to at a glance; then the owner's feel round.

**M4 · Popovers and buttons.** The sentence popover sizes to its content at the theme's type size; tool buttons keep their titles; disabled rows keep their column.
*Check:* M0 pictures of the open popover (drawn into the window on the runner, since the runner's screenshots miss popovers) and of the Report's add tiles.

**M5 · Pointer and formulas.** Canvas drag-select starts on the first press (`acceptsFirstMouse:`, the click threshold); reproduce the formula failure with CI steps and fix it.
*Check:* CI steps that drag and type a formula, with pictures matching GTK.

**M6 · Open a file.** `FilePicker` → NSOpenPanel.
*Check:* the owner opens a CSV.

**M7 · GPU on the Mac.** Small test apps for Metal through Mojo first, then the frame engine's GPU path. The runners have no GPU, so only the owner's Mac can prove this one.

## Constraints

- GTK and the web never get worse: M2 is a refactor with pixel goldens.
- No app-specific code in hosts or themes.
- Don't touch `../mojo-ui-apple-test`; nothing pushed to `main` without the owner's yes.
