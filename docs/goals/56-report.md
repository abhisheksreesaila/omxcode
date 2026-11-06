# Goal 56 report: omxplorer on the owner's Mac, and omxqua's latest details

`scripts/check` (docs/goals/56-check.py): M0–M5 PASS (2026-11-06).

| # | Result |
|---|---|
| M0 | `sentence_lines` = the lines `Sentence` draws at widths 4–200; a chart card's title bar follows its lines; a run past a comma may break after it |
| M1 | the owner's Mac (Apple M4, macOS 27.2), native Metal build through `scripts/mac-ssh`: 1440 wide through the import, 1920 → 1440 lands at 1440, light and dark both, 42 chart sentences above their bodies with no word squeezed, no overlap, close by tag, a corner drag of -100 changes the table by -100, dragcard swaps exactly, the island says "Apple M4 · ready" |
| M2 | omxqua's focus ring from the Look: GTK accent 2–4 px outside a focused button on all four sides, none before; web outline 2px solid in the app's accent, offset 2px |
| M3 | tabular figures on GTK too: "1,111.11" = "8,888.88" = 58 px under Liquid (42 vs 62 without); the web's body says tnum |
| M4 | tiling, boardtiles, sentence tests; goal 54 M1–M3 |
| M5 | docs/omxplorer.html "The look": the same tiled board in Liquid dark on the Mac, Linux and the web (docs/img/omxplorer-shell-{mac,linux,web}.jpg) |

## What changed
- **The Mac, for real:** `scripts/mac-ssh` (D-5601). Fixed on it: the import shrank the window (D-5603), a chart's title ran under its chart (D-5604, D-5613), 1920 → 1440 stuck at 1529 (D-5605), test steps by tag (D-5606) and the appearance switch (D-5607).
- **Cards say they resize:** a grip in every tiled card's corner on GTK, the web and the Mac, the accent on hover; GTK's pointer shows resize/move (D-5610). The Mac's tiled Board now resizes and swaps like GTK's (D-5611).
- **omxqua v0.1.6:** Look.focus (D-5608) and tabular figures on GTK (D-5609), for every Liquid app.
- **omxcore:** already its newest stable (834ef9a); nothing vendored (D-5602).

## Found, not fixed
- Video on the Mac: VideoSource needs ffmpeg's command line, which a Mac doesn't have and the app doesn't carry (D-5612). Next: AVFoundation decoding.
- The page's videos (hero, robots, sentence) still show the old floating shell: they need a choreographed re-record.
- The Mac keeps its native focus ring; its pan recognizer is driven in checks by its end event, not a real pointer drag (a real one would move the owner's pointer).
