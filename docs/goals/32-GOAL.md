# GOAL 32: one look on Linux, the web and the Mac, from components and a theme

**Why (owner, 2026-10-24):** "the claim is one language, button to kernel… it has to look identical and each
component has to look polished… if I just drop those components and hook up the connections and databases it should
just work out of the box, except for the custom components… if you say one language plus custom CSS, people will lose
interest." Then speed: NVIDIA on Linux, Apple's GPU on the Mac (MAX's source is open now), the browser's GPU on the web.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The measure | `scripts/side.py` shoots ci/mac/side.txt's screens on GTK and the web at 1440×640 (the Mac runner's screen holds no taller window) and reads the newest Mac run, which must be built from this checkout's sources (its stamp); the Mac's view dump and the web's carry each view's tag; `scripts/parity.py` lists every tagged view's rect on both and the difference |
| M1 | A theme is data | `mojoui/theme.mojo` has a `Look`: a type scale, control sizes (button, tool, icon, field) and surfaces (fill, corners, margin, padding, rim, shadow) by framework role; Liquid and Omarchy declare one; the GTK and web rules for those roles are written from it (no hand-written copy left in themes/); GTK and web pictures of every side.txt screen differ from the goldens taken before the change by ≤ 0.5 % of pixels; themes style only tags a framework component sets (a lint) |
| M2 | The toolbar, the same | on the Mac, omxplorer's sheet and Report toolbars: titled tools (title beside the icon), 34 pt icon toggles, Lucide icons, dividers, the floating island from M1's look; every toolbar view's rect within 4 pt of the web's, and every button's title fits its frame |
| M3 | Every surface the same | the in-window header row, formula bar, inspector, segmented controls, fields, sheet tabs, status bar, the table's card and Report tiles follow M1's look on the Mac; every tagged view in side.txt's screens within 4 pt (or 3 %) of the web's; each Mac picture's difference from the web's is no more than 1.5 × GTK's difference from the web's |
| M4 | Popovers, tiles and rows | the chart sentence's choice popover (its own picture on the Mac), the Report's add tiles with their titles, the start page's disabled row in its column: within M3's tolerances |
| M5 | The Mac's hands | CI steps on the Mac: a drag selects cells on its first press, a formula column computes the same figures as on GTK, Open reads a CSV through the file panel's test path |
| M6 | Speed, mapped | every GPU kernel in mojoui/ and vendor/ fits Apple's 32 KB of threadgroup memory (a scan); a small Mac test app built in CI runs a MAX kernel on the GPU if the runner has one and says which device it ran on; `docs/plans/speed.md`: NVIDIA (job streams), Mac (Metal through MAX), web (WebGPU in the browser), and what's needed from MX frame |
| M7 | Nothing regressed | goal 30's checks (M0–M5; every earlier goal inside them) |

## Out of bounds
App-specific CSS or host code (an app's own components excepted); iPhone and Android; a second app (later, as a
proof); pushing main (the mac-test branch and the mac-ci release assets are fine: owner, 2026-10-23); paid services;
touching `../mojo-ui-apple-test`.

## Assumptions (instead of asking)
- The web is the reference picture: GTK already matches it, and a browser reports every view's box exactly.
- The Mac keeps its menus in the system menu bar (a Mac app without one isn't a Mac app); the in-window row keeps the
  app's mark and status, so that row differs by the menu titles only.
- Fonts are the theme's (Inter); text renders a little differently per platform, which the picture threshold allows.
- GitHub's Mac runners prove the Mac's look; only the owner's Mac proves the GPU on Apple Silicon.

## Done means
PASS for M0–M7, the reviewer passes it, a short `docs/report.md`; committed locally, nothing pushed to main. Budget:
80 turns.
