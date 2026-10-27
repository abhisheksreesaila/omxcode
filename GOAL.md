# GOAL 34b: JS widgets everywhere, and agents see them

**End goal (owner, 2026-10-27):** "yup, please continue as 34b": the rest of first-class JS cut from goal 34 (D-590).
Agent visibility first: the cover page now says every app is agent-usable, so a JS widget must not be a black box.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | Agents see JS widgets | a widget may declare `describe(el) -> {text, value, …}` and settable fields in `defineWidget`; the agent (MCP) host lists every WebComponent as tools like any component: reading it returns what it describes (CodeMirror's text, the counter's count), setting it (a tool with a typed argument) changes the widget and the change reaches `update()` as the widget's own event; a widget without `describe` is listed by its tag with "no description"; proven through the agent client against the widgets app on the web and GTK |
| M1 | A second library, no host changes | Apache ECharts from npm (pinned, lockfile) as a chart widget in examples/widgets, fed from Mojo (the word-count series as data), its click on a point reaching `update()`; added without changing any file in mojoui/hosts (the check diffs them against goal 34's), under the same CSP with zero violations, on the web and GTK |
| M2 | The Mac, the same widgets | on the Mac each WebComponent runs in a WKWebView with the same bundle, runtime and CSP, no network or navigation; typing in the editor reaches `update()`, Mojo sets its text, the counter's command gets its reply, the chart draws; boxes within goal 32's parity of the web's; proven on GitHub's Mac runner (scripts/mac-ci, fresh against these sources) |
| M3 | Nothing regressed (minimal) | goal 34's M0–M3 and goal 33's M1, M4 pass |

## Out of bounds
React/Vue inside omxcode; run-time downloads; phones; pushing anything but mac-test and the mac-ci assets (D-400).

## Assumptions
- ECharts over Leaflet: it works offline with no tile server and makes a better showcase chart.
- Each milestone's proof is written before its work, from this table's words, never weaker.

## Done means
`scripts/check` PASS for M0–M3; the reviewer passes it; a short report with the editor and chart on web, GTK and Mac.
