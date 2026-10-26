# GOAL 34 (draft, 2026-10-25): the JS ecosystem as components

**Why (owner, 2026-10-25):** "I thought FastHTML gave us access to JS… we need that… that's a big gap, we will lose an
entire JS ecosystem." Today the web host draws a fixed list of component kinds; `WebFrame` (goal 33) only shows a page
in an iframe. A Mojo app can't place a JS widget, feed it values, or hear its events. After goal 33.

## The idea
One generic view, `WebComponent(tag, props, on_event)`: on the web the host mounts any registered Web Component or JS
widget (an editor, a map, a chart library) as a custom element, streams its props down from Mojo, and posts its events
back as ordinary `Event`s into `update()`, as `mojoui.http` replies arrive. Apps list their scripts and styles with
`App.web_assets()`; nothing goes into the host per app. On GTK and the Mac the same widget runs in a small native
webview for that one view (WebKitGTK, WKWebView), or a native stand-in where one exists.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The seam | `WebComponent` and `App.web_assets()` in mojoui; a test widget (a counter Web Component in plain JS, vendored) mounts on the web, gets props from Mojo, and its clicks reach `update()`; props changed in Mojo reach it without remounting it (its own state survives) |
| M1 | A real library | one familiar widget from npm, vendored with its licence (proposed: CodeMirror 6, an editor), on the web: type, the text reaches `update()`; set the text from Mojo, the editor shows it; the cursor survives an unrelated rebuild |
| M2 | Native, the same widget | the same app on GTK (WebKitGTK) and the Mac (WKWebView, through GitHub's runners): the editor mounts, typing reaches `update()`, Mojo sets its text; the widget's box matches the web's (goal 32's parity) |
| M3 | Agents still see it | the agent (MCP) host lists a WebComponent with what it reports (`describe()` from the widget: e.g. its text), and an agent can set its value |
| M4 | A second library | a map or a chart library (proposed: Leaflet with offline tiles, or Apache ECharts) through the same seam, no host changes: the proof that it's generic |
| M5 | Nothing regressed | goal 33's checks |

## Out of bounds
A JS framework inside omxcode (React, Vue); network downloads at run time (assets are vendored); iPhone and Android
webviews (later); pushing anything but the mac-test branch.

## Cons to weigh
A webview widget inside a native app won't look native; each widget adds a webview's memory on GTK and the Mac; the
agent sees only what the widget reports; each library needs testing on each host.
