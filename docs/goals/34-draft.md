# GOAL 34 (draft, 2026-10-25): the JS ecosystem as components

**Why (owner, 2026-10-25):** "after you finish this today, start on the JS widget component and prove it with an app (simple app for now). iframe is not secure. We also need to manage minification of JS and the security part." Earlier: "I thought FastHTML gave us access to JS… we need that… that's a big gap, we will lose an
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
| M0 | The seam, in a simple app | `examples/widgets`, a small app (a note with a live editor and a chart of word counts) is the proof app for every milestone;  `WebComponent` and `App.web_assets()` in mojoui; a test widget (a counter Web Component in plain JS, vendored) mounts on the web, gets props from Mojo, and its clicks reach `update()`; props changed in Mojo reach it without remounting it (its own state survives) |
| M1 | A real library | one familiar widget from npm, vendored with its licence (proposed: CodeMirror 6, an editor), on the web: type, the text reaches `update()`; set the text from Mojo, the editor shows it; the cursor survives an unrelated rebuild |
| M2 | Native, the same widget | the same app on GTK (WebKitGTK) and the Mac (WKWebView, through GitHub's runners): the editor mounts, typing reaches `update()`, Mojo sets its text; the widget's box matches the web's (goal 32's parity) |
| M3 | Agents still see it | the agent (MCP) host lists a WebComponent with what it reports (`describe()` from the widget: e.g. its text), and an agent can set its value |
| M4 | A second library | a map or a chart library (proposed: Leaflet with offline tiles, or Apache ECharts) through the same seam, no host changes: the proof that it's generic |
| M5 | Nothing regressed | goal 33's checks |

| M6 | Security and size | every widget's JS and CSS is vendored at a pinned version, bundled and minified at build time (esbuild from conda-forge), served from our origin with its hash; the page sends a strict CSP (no inline script, no eval, script-src only our hashed files) and the proof app runs under it with no CSP violations; props cross as JSON data, never code; a lint fails the build on an unvendored, unhashed or unlisted asset; untrusted widgets only in a sandboxed iframe (no allow-same-origin) speaking postMessage; WebFrame gains a sandbox by default |

## Out of bounds
A JS framework inside omxcode (React, Vue); network downloads at run time (assets are vendored); iPhone and Android
webviews (later); pushing anything but the mac-test branch.

## Cons to weigh
A webview widget inside a native app won't look native; each widget adds a webview's memory on GTK and the Mac; the
agent sees only what the widget reports; each library needs testing on each host.

## Next after this (goal 35, proposed)
Mojo 1.2, then a native Mojo web host on flare (ehsanmok/flare: HTTP server, WebSocket, SSE, TLS): one binary with no
Python, no Mojo↔Python bridge per update, server push instead of a held /wait request, and flare behind `mojoui.http`
for HTTPS. Cons: the 1.2 upgrade touches every example and check; Starlette's maturity traded for a younger server;
web.py's ~1,200 lines rewritten (the browser side stays).
