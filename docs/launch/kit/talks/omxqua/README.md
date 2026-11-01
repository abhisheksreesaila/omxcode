# omxqua · the talk (one part, about 5 min)

Deck: [index.html](index.html), 14 slides, speaker notes on every slide (press `S`). Source: `../_src/omxqua.html`,
rebuilt with `pixi run python docs/launch/kit/talks/build.py`. Length: 763 words of notes ≈ 5:05 at 150 words a minute.

## YouTube titles (≤ 60 characters)
1. omxqua: Google's surfaces, Apple's springs, three files (55)
2. A design language with real springs in plain CSS (48)
3. Solid cards, frosted nav: the design language of omxlabs (56)

**Thumbnail:** `img/omxqua-families.png` (the same app in four themes) on the right, darkened left; big text
**SOLID SURFACES, REAL SPRINGS**; small mono line under it: `3 files · no build · 4.5:1 checked`.

## Description

```
omxqua is the design language every omxlabs app wears: Google's opaque tonal surfaces and one soft shadow, Apple's spring motion, rebuilt from scratch with our own names. Three files (tokens.css, components.css, omxqua.js), about 19 KB gzipped, no framework and no build step. Four families (developer, travel, kids, money) and four skins, one root class apart; on main, 51 tests hold every text and state colour to 4.5:1 (icons and data marks to 3:1), and the script injects no styles, so it works under a strict CSP. Springs are real damped springs written as CSS linear() curves. It ships as a skill and a Claude Code plugin, so an agent builds screens in the real parts.

Try it in Claude Code: /plugin install omxqua --marketplace abhisheksreesaila/omxqua

Code (MIT, fonts SIL OFL 1.1): https://github.com/abhisheksreesaila/omxqua
Showcase: https://abhisheksreesaila.github.io/omxqua/docs/showcase.html
omxlabs: https://omxlabs.tech

Chapters
0:00 What omxqua is
0:15 Why: most apps feel like forms
0:38 Borrowed honestly
1:05 Four layers
1:22 One class repaints everything
1:40 The markup
2:05 Springs as CSS linear()
2:20 The motion budget
2:39 Families and skins
3:01 4.5:1, checked by a test
3:18 Built for agents
3:46 Where it's used
4:09 The honest edges
4:33 Try it
```

**Tags:** design system, design language, CSS, CSS linear(), spring animation, web design, UI design, design tokens,
accessibility, WCAG contrast, Claude Code plugin, omxqua, omxlabs

*Chapters are estimated from the notes at 150 words a minute; re-time them to the final cut. Numbers: 51 tests
(`node --test tests/` on main in ~/Projects/omxqua, 2026-11-01; the v0.1.5 tag has 11), 19.4 KiB gzipped (gzip of the three files, same day),
everything else from README.md, LANGUAGE.md, AGENTS.md, CHANGELOG.md and src/tokens.css as each slide's source line says.*
