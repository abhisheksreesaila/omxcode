# GOAL 34: first-class JS

**End goal (owner, 2026-10-25/27):** "we need first-class JS support or else web dev will be stalled on this
framework… start on the JS widget component and prove it with an app (simple app for now). iframe is not secure. We
also need to manage minification of JS and the security part." And: "check only minimal and move on… I want to wrap up
in a few hours… once we reach a good stable point, then run all of them." Draft: docs/goals/34-draft.md.

## Milestones (this cut: the web and Linux; 34b adds the Mac's webview, agent visibility and a second library)
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The seam, in a simple app | `mojoui/webcomponent.mojo`: `WebComponent(tag, props, on_event)`, commands (Mojo calls a widget's method) and replies, `App.web_assets()`; a JS side `defineWidget({props, events, commands, mount, update})` in the web host; `examples/widgets` (a note: a live editor, a word count, a small chart) on the web: a vendored counter widget mounts, takes props from Mojo, its clicks reach `update()`, a props change reaches it without remounting (its own state survives), a command gets a reply; its own test |
| M1 | npm and TypeScript | `examples/widgets/web/package.json` + lockfile: CodeMirror 6 from npm, bundled offline by esbuild at build time (Node and esbuild from pixi); a widget written in TypeScript compiles in the same build; typing in the editor reaches `update()` (the word count follows), Mojo sets the text and the editor shows it, the cursor survives an unrelated rebuild; `scripts/new_widget.sh` makes a working widget from a template; `docs/js.md` walks it |
| M2 | Secure by default | the page sends a strict CSP (no inline script, no eval, script-src only our hashed files); every asset is served by its content hash from our origin; the app runs with zero CSP violations (read from the browser); props and events are JSON data only; a lint fails the build on an asset not listed by `web_assets()` or not bundled; `WebFrame` is sandboxed by default (no allow-same-origin), http(s) only |
| M3 | Linux, the same widget | the same app on GTK: the widget runs in a WebKitGTK view for that one component, gets the same bundle, typing reaches `update()`, Mojo sets its text; the widget's box matches the web's (goal 32's parity) |
| M4 | Nothing regressed (minimal) | goal 33's M1, M2, M4 and M5 pass (the full chain waits for the next stable point: owner) |

## Out of bounds
A JS framework inside omxcode (React, Vue); run-time downloads or CDNs; the Mac and phones (34b); pushing; touching
`../mojo-ui-apple-test` or other worktrees' envs (this worktree has its own .pixi).

## Assumptions (instead of asking)
- Node and esbuild come from conda-forge through pixi (this worktree's own env; .pixi is skip-worktree in git here).
- npm installs run at build time from the committed lockfile (`npm ci`), with node_modules outside git; the bundle is
  the artifact, hashed and served from our origin.
- Each milestone's proof is written in scripts/check.py before its work starts, from this table's words, never weaker.

## Done means
`scripts/check` prints PASS for M0–M4; the reviewer passes it; a short report with shots of the editor in the widgets
app on the web and GTK. Committed on `goal-34-js`, nothing pushed.
