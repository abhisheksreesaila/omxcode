# omxplorer · logo and colour (2026-10-19)

> **Superseded on colour (2026-11-02, D-4733):** omxplorer now wears one green, #0e7a43 (lifted to #5aeca2 in Liquid dark; logo fills #1f9d55), in every mode. The indigo and the per-mode tints below are history. Logo 1 stays.

Open `index.html` and reply with a logo number and a colour letter, for example "logo 1 + colour C".

## What's here
- `index.html`: the page to choose from. Logo concepts 1–8 (a colour picker recolours every mark), colour directions A–D with contrast numbers, mockups A1/A2 … D1/D2, and the recommendation.
- `logo-N-icon.svg` (1024 app-icon tile), `logo-N-icon-light.svg` (white tile), `logo-N-mark.svg` (mark alone), `logo-N-wordmark.svg` (the mark as the o of "omxplorer"), `logo-N-lockup.svg` (tile beside "omxplorer"). The files use the recommended indigo. The wordmark is Inter SemiBold turned into outlines, so the files don't need the font.
- `mockups/{A..D}-{sheet,report}.html` and `.png`: the goal-25 Sheet and Report screens at 1280×720, one per colour, each with a different logo in the menu bar.
- `stitch/`: Stitch's logo board for the same brief (`stitch-logos.png`/`.html`, project 15162298038433052241). It's shown on the page for reference only, because its marks are stock Material icons.
- `tools/`: `build.py` writes everything above, `marks.py` draws the eight marks on a 100-unit grid, `contrast.py` does the WCAG maths, `outline.py` outlines the wordmark, and `shoot.py` takes the PNGs.

## How it was made
- **Logos:** hand-drawn SVG geometry in `tools/marks.py` (Claude). Stitch was asked for the same board, but it only returns stock icon glyphs.
- **Colours:** picked by hand, then checked with `tools/contrast.py`. The rule: white text on the accent and accent text on its own 10% wash must both reach 4.5:1. Today's teal fails the wash test (4.33:1).
- **Mockups:** HTML/CSS rebuilt from `docs/goals/25/after-*.jpg` and the Liquid tokens (`docs/design/liquid/liquid.md`). Only `--acc*` and the mark change between directions. The one change in every direction: the active tool ("Format") becomes a solid accent pill with white text instead of the grey-teal wash.
- Rebuild: `python3 docs/design/brand/tools/build.py && pixi run python docs/design/brand/tools/shoot.py`. Re-outlining the wordmark needs `pixi exec -s fonttools -s python=3.12 python docs/design/brand/tools/outline.py`.

## Colour directions
| | Name | Accent | Hover | Pressed | Wash | On dark | White on accent | Accent on wash |
|---|---|---|---|---|---|---|---|---|
| A | Ledger green | #0e7a43 | #0c6a3a | #0a5a31 | rgba(14,122,67,.10) | #4ade80 | 5.41 | 4.71 |
| B | Signal red | #c8243f | #a91f35 | #8f1a2d | rgba(200,36,63,.10) | #fb7185 | 5.56 | 4.74 |
| C | Iris indigo | #4f46e5 | #4338ca | #3730a3 | rgba(79,70,229,.10) | #818cf8 | 6.29 | 5.39 |
| D | Deep lagoon | #00707e | #006570 | #005962 | rgba(0,112,126,.10) | #2dd4bf | 5.80 | 5.04 |

All four directions use white text on the accent. The selection ring is 2px of the accent, and the selection fill is the accent at 8%.

## Recommendation
**Logo 1 (Lens · bars) + colour C (Iris indigo).**
- **Logo 1:** it is the idea you described, it still reads at 16 px, and it works as the o in the wordmark. The con: it is literal and common, so it's not very ownable. Logo 5 (the selection ring with the fill handle) is the cleverer runner-up.
- **Colour C:** in a spreadsheet, green and red already mean true/false and good/error. Indigo leaves both free and has the most contrast headroom of the four. The cons: it is a common SaaS colour, the formula-value purple would have to move to cyan, and it isn't the green or red you leaned towards. A (green) is the honest second choice if looking like a spreadsheet matters most.

Nothing in the app has changed. Once you pick, the build updates the accent tokens in `docs/design/liquid/liquid.md` and the app's theme, and adds the mark to the menu bar and app icons.
