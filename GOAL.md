# GOAL 34b: JS widgets everywhere, and agents see them

**End goal (owner, 2026-10-27):** "yup, please continue as 34b"; "we want first-class integration… first-class support to JS; AG-UI comes later": the rest of first-class JS cut from goal 34 (D-590).
Agent visibility first: the cover page now says every app is agent-usable, so a JS widget must not be a black box.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | Agents see JS widgets | a widget may declare `describe(el) -> {text, value, …}` and settable fields in `defineWidget`; the agent (MCP) host lists every WebComponent as tools like any component: reading it returns what it describes (CodeMirror's text, the counter's count), setting it (a tool with a typed argument) changes the widget and the change reaches `update()` as the widget's own event; a widget without `describe` is listed by its tag with "no description"; proven through the agent client against the widgets app on the web and GTK |
| M1 | A second library, no host changes | Apache ECharts from npm (pinned, lockfile) as a chart widget in examples/widgets, fed from Mojo (the word-count series as data), its click on a point reaching `update()`; added without changing any file in mojoui/hosts (the check is a receipt of the ECharts change set, a87c7cc..760bb66 pinned by SHA: it shows that change set touched no host file; it is not a regression guard for later host changes), under the same CSP with zero violations, on the web and GTK |
| M1b | First-class citizens | widgets wear the theme: the host hands every widget the Look's tokens (palette, fonts, corners, light or dark) as CSS variables and a `theme(el, tokens)` call, and CodeMirror and ECharts follow omxqua and switch light/dark live with the rest of the app (pictures on the web and GTK in both); keyboard focus moves between native controls and widgets with Tab and Shift+Tab in order, both ways; widgets appear in docs/components.md and in the gallery beside the native components |
| M1c | The developer loop | `scripts/dev.sh <app>` watches an app's web/ sources: saving a .ts/.js/.css file rebuilds the bundle and the open page reloads its widgets while the Mojo app keeps its state (a typed note survives the reload); a widget's thrown JS error reaches the app's log with its original file and line (source maps), on the web and GTK; debug builds can open WebKit's inspector on GTK and the Mac's widget views (release builds can't); docs/js.md walks the loop |
| M2 | The Mac, the same widgets | on the Mac each WebComponent runs in a WKWebView with the same bundle, runtime and CSP, no network or navigation; typing in the editor reaches `update()`, Mojo sets its text, the counter's command gets its reply, the chart draws; boxes within goal 32's parity of the web's; proven on GitHub's Mac runner (scripts/mac-ci, fresh against these sources) |
| M3 | Nothing regressed (minimal) | goal 34's M0–M3 and goal 33's M1, M4 pass |

## Out of bounds
React/Vue inside omxcode; run-time downloads; phones; pushing anything but mac-test and the mac-ci assets (D-400).

## Assumptions
- ECharts over Leaflet: it works offline with no tile server and makes a better showcase chart.
- Each milestone's proof is written before its work, from this table's words, never weaker.

## Done means
`scripts/check` PASS for M0–M3; the reviewer passes it; a short report with the editor and chart on web, GTK and Mac.
