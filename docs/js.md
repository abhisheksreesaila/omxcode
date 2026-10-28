# JavaScript in a mojoui app (goal 34)

A Mojo app can place any JavaScript widget (an editor, a map, a chart library) in its screen. The widget is a custom
element; Mojo gives it **props** (JSON), hears its **events** in `update()`, and can call its **commands** (the answer
comes back to `update()` later, as an HTTP reply does). The app keeps every line of state; the widget keeps only its own
(a cursor, a scroll position, a counter's count). Runs on the web, on GTK (§6) and on the Mac (§7).

The example is `examples/widgets` (a note in mojoui's shared CodeMirror 6 editor, a word count drawn by mojoui and by
the shared Apache ECharts chart, and a plain-JS counter of its own).

## 0. Use a shared widget (any app)

mojoui ships widgets any app can use, in `mojoui/widgets/` with their own pinned `package.json` and `package-lock.json`:

| Name | Tag | Library | Props | Events |
|---|---|---|---|---|
| `editor` | `mx-editor` | CodeMirror 6 | `doc`, `rev`, `placeholder` | `change {text}` (commands: `focus`, `selection`, `text`; agents set `text`) |
| `chart` | `mx-chart` | Apache ECharts 6 (line) | `series` (a JSON list of numbers) | `pick {index, value}` |

To add one to your app, pick it by name and list its bundles:

```
examples/<app>/web/shared.json        {"widgets": ["editor", "chart"]}
```
```mojo
    @staticmethod
    def web_assets() -> List[String]:
        return ["editor.js", "editor.css", "chart.js", "chart.css"]    # beside your own widgets' names
```

Then place it like any widget (`WebComponent("mx-editor", 1, Props().text("doc", self.note)…)`, §3). The build bundles
the picked widgets with your own (their npm packages come from mojoui/widgets' lockfile, installed once into
`build/_shared/npm`); they wear your theme (`theme(el, tokens)`), speak to agents (`describe`, fields) and run on the
web, GTK and the Mac like your own. A name you also have in `web/widgets/` fails the build; nothing is bundled that the
app doesn't pick and list. `scripts/dev.sh <app>` watches the shared files the app picks too.

## 1. Add a package

```
examples/<app>/web/package.json        your npm dependencies, pinned (commit it)
examples/<app>/web/package-lock.json   commit it too; node_modules never goes in git
examples/<app>/web/widgets/*.js|.ts|.css   one bundle per file
```

Add a package once, by name, with the pixi env's npm (Node comes from conda-forge):

```
cd examples/<app>/web && pixi run npm install --package-lock-only --ignore-scripts @codemirror/view
```

`scripts/build.sh <app> web` does the rest (`scripts/web_assets.py`): `npm ci --ignore-scripts` from the lockfile into
`build/<app>/npm/` (no package runs code at install time; the first install, or one after the lockfile changes, downloads
the pinned packages from the npm registry unless npm's cache already has them), then esbuild bundles and minifies each
file in `web/widgets/` with no network (TypeScript too: esbuild strips the types; it doesn't check them) into
`build/<app>/web/assets/<name>.<hash>.js` with a `manifest.json`. No CDN, nothing downloaded when the app runs.

## 2. Write a widget

`scripts/new_widget.sh <name> [<app>]` writes `examples/<app>/web/widgets/<name>.js` from a template (`--ts` for
TypeScript). A widget is one call:

```js
mojoui.defineWidget({
  tag: 'mx-counter',                       // a custom element's name: lower case, with a hyphen
  events: ['click'],                       // what it may emit (others are refused)
  mount(el, props, emit) {                 // once, when it first appears: build its DOM inside el
    el.count = 0;
    const b = document.createElement('button');
    b.textContent = String(props.label);   // textContent, never innerHTML with props
    b.addEventListener('click', () => emit('click', { count: ++el.count }));
    el.append(b);
  },
  update(el, props) { el.querySelector('button').textContent = String(props.label); },  // new props; el stays
  destroy(el) {},                          // it left the screen for good
  commands: { read(el, args) { return { count: el.count }; } },  // the value (or a Promise of it) is the reply
  describe(el) { return `count ${el.count}`; },                  // one line for tests and agents
});
```

**Agents see it** (goal 34b, docs/agent.md): `describe(el)` returns JSON data, `{text, value, …}` (`text`: one line
about it; `value`: its value; anything else it wants to say); a string is read as `{text}`. `description` is one sentence
for the agent's tool. `fields` lists what an agent may set, each with its JSON type (`string`, `number`, `integer`,
`boolean`, `array`, `object`) and a setter that changes the widget and **emits the widget's own event**, so `update()`
hears the change as from a person:

```js
  description: 'A counter: its count is its own',
  fields: { count: { type: 'integer', set(el, value) { el.count = value; render(el); el.emit('change', { count: value }); } } },
  describe(el) { return { text: `count ${el.count}`, value: el.count, count: el.count }; },
```

The agent host lists the widget as `<name>-read` and `<name>-set` tools; the page's runtime runs a set (the built-in
command `mojoui.set`) only for a declared field with a value of its declared type. Without `describe` the agent sees the
widget by its tag with "no description".

**It wears the app's theme** (goal 34b M1b): the page carries the Look's tokens as CSS variables (`--o-card`, `--o-ink`,
`--o-ink2`, `--o-accent`, `--o-data`, `--o-line`, `--o-font`, `--o-mono`, `--o-font-size`, `--o-radius-card`,
`--o-radius-button`, `--o-radius-field`) for the widget's CSS, and the runtime calls `theme(el, tokens)` with the same
values as JSON data (`{id, dark, palette: {card, ink, ink2, accent, wash, data: […], …}, font: {family, mono, size},
corners: {card, button, field}}`) after mount and whenever the app's theme changes (light/dark, live). Restyle in place:
CodeMirror reconfigures a `Compartment` with `EditorView.theme({...}, {dark})`, ECharts calls `setOption` again.
`mojoui.tokens` holds the latest.

**Keyboard**: a widget is in the page's Tab order with its own focusable parts (CodeMirror's text, the counter's button).
One with nothing focusable inside (a chart) says `focusable: true`: the element takes Tab itself, labelled by its
`description`, and handles keys in `mount` (the chart: arrows move along the points, Enter picks one). On GTK the host
carries Tab and Shift+Tab across its views: inside a view the page moves to its next stop (after the widget had its
chance to keep the key), past the last it hands the keyboard back, and a view Tab enters focuses its first or last stop.

The host mounts it once per key (tag + id) and **keeps it**: a props change calls `update()`, and a rebuild of the whole
page moves the live element into the new screen (`Element.moveBefore`: focus, selection and scroll stay). Its CSS can
read the theme's palette (`var(--o-accent)`, `--o-card`, `--o-ink`, `--o-line`…), so it wears the app's theme.

`emit(name, payload, { latest: true })` replaces an unsent event of the same name (a whole text on every keystroke).
TypeScript widgets get types from `mojoui/hosts/static/mojoui-widgets.d.ts` (`/// <reference path=…>`).

### A second library: Apache ECharts (goal 34b)
`mojoui/widgets/chart.ts` is ECharts 6 from npm (`"echarts": "6.1.0"`, exact, in mojoui/widgets' lockfile), added
with no change to the hosts: `npm install --package-lock-only --ignore-scripts --save-exact echarts@6.1.0`, one widget
file, two names in `web_assets()` (it was examples/widgets' own until D-675 made it shared, §0). Import it **tree-shaken** (`echarts/core` plus the chart, components and renderer you
use: `LineChart`, `GridComponent`, `SVGRenderer`), so the bundle carries only those; ECharts needs no `eval` or
`new Function`, so it runs under the CSP as it is. Mojo owns the data (`Props().raw("series", …)`); the widget reads the
theme's palette (`--o-data`, `--o-card`, `--o-ink2`, `--o-line`) and the page's font, and a click on a point emits
`pick {index, value}`.

### The developer loop (goal 34b M1c)

```
scripts/dev.sh widgets              # http://127.0.0.1:5001/  (--port N for another)
```

`scripts/dev.sh <app>` builds the app for the web as a **debug build** (`MOJOUI_DEBUG=1`: each bundle gets a source
map), serves it on **127.0.0.1 only**, and watches `examples/<app>/web/`. Save a `.ts`, `.js` or `.css` file and it
rebuilds the bundles (about 0.3 s) and every open page loads the new code: a style sheet is swapped, a script's widgets
are torn down (`destroy`) and mounted again from the props Mojo gives them now. The Mojo app is never restarted, so its
state stays (the note you typed is still the note: the editor's `doc` prop is Mojo's text). A change to `app.mojo` needs
a restart.

A widget's uncaught error (or one thrown in `mount`, `update` or `theme`) reaches the app's log as one line, with the
**original file and line** read from the bundle's source map:

```
JS ERROR: widgets/counter.js:24:32: Uncaught Error: boom from the counter
```

On GTK the same line comes from the widget's view (with its key, `(mx-counter#1)`). Release builds have no source maps,
so the line names the bundle's own position.

**WebKit's inspector** for a widget's view on GTK: build with `MOJOUI_DEBUG=1 scripts/build.sh <app> linux` and
right-click the widget, *Inspect Element* (the test step `inspect:<tag>#<id>` opens it too). A release build
(`scripts/build.sh <app> linux`) has no inspector: the choice is made when the app is compiled
(`mojoui/hosts/devtools.mojo`, `-D MOJOUI_DEBUG`), not at run time. The Mac takes the same switch:
`MOJOUI_DEBUG=1 scripts/build.sh <app> mac` makes each widget's WKWebView inspectable from Safari's Develop menu
(`isInspectable`, macOS 13.3+) and ships the source maps. That debug build is proven to compile (M1c checks it names
`setInspectable:`, the release build doesn't); it has not been run on a Mac yet, only the release build has (M2).

What stays the same in the loop: the Content-Security-Policy (the dev server sends the release one), bundles by
content hash with SRI, and nothing from another origin. The dev endpoints (`/dev/assets`, `/dev/wait`, `/dev/reload`,
the last one only with dev.sh's random token) and source maps exist only when the server runs with `MOJOUI_DEV=1`, which
only dev.sh sets. They answer 127.0.0.1 alone, and the host refuses to start with `MOJOUI_DEV=1` unless the app's build
is a debug build (its manifest names a source map for every bundle). **Never set `MOJOUI_DEV` on a deployed host**: a
deployed app is a release build, served by `mojoui/hosts/web.py` without it.

## 3. Use it from Mojo

```mojo
from mojoui.webcomponent import WebComponent, Props, Command, Widgets

struct Main(App):
    var widgets: Widgets                              # the outbox for commands

    @staticmethod
    def web_assets() -> List[String]:                 # the bundles this app's page loads (and nothing else)
        return ["counter.js", "counter.css"]

    def view(self) -> View:
        return WebComponent("mx-counter", Props().text("label", "Clicks").number("step", self.step), on_event=COUNTER, id=1)

    def update(mut self, e: Event):
        if e.message == COUNTER:                      # e.id = 1, e.name = "click", e.text = '{"count":3}' (JSON)
            var j = Json.parse(e.text)
        elif e.message == ASK:
            self.widgets.call(Command("mx-counter", 1, "read", reply=READ))
        elif e.message == READ:                       # e.text = the reply (JSON); e.error = why there is none
            ...

    def commands(mut self) -> List[Command]:
        return self.widgets.take()
```

`Props()` has `.text`, `.number`, `.real`, `.flag` and `.raw` (JSON you built). A widget whose value both sides can
change (an editor's text) takes Mojo's value with a version: `Props().text("doc", self.loaded).number("rev", self.rev)`;
the widget replaces its text only when `rev` moves on, so typing is never undone by its own echo.

## 4. Commands

`Command(tag, widget_id, name, args="null", reply=MSG).tagged(id)`: the runtime numbers it, the page runs the widget's
`commands[name](el, args)`, and its answer reaches `update()` as `Event(MSG, text=reply JSON, id=id, name=name)`.
No widget, no such command, a throw, or a reply that isn't JSON: `event.error` says so. `reply=NO_MSG`: no answer.
Arguments that aren't JSON never leave the runtime (an error Event instead).

## 5. Security rules (what the host enforces)

- **Content-Security-Policy** on every page: `default-src 'self'; script-src 'self'` (no inline script, no inline
  handler, no `eval`, no other origin), `object-src 'none'`, `base-uri 'none'`, `form-action 'self'`,
  `frame-ancestors 'self'`, `img-src 'self' data:`, `font-src 'self'`, `connect-src 'self'`, `frame-src 'self' http: https:`.
  `style-src 'self' 'unsafe-inline'`: each view's layout is a `style` attribute and the theme's sheet is a `<style>`
  swapped in live; CSS runs no script, and what it could load stays on our origin (img-src, font-src). Also
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`, `X-Frame-Options: SAMEORIGIN`, COOP same-origin.
- **Assets by content hash** from our origin (`/static/…`, `/assets/<name>.<hash>.js`), cached a year, `immutable`, with
  SRI `integrity`. The build's lint (`scripts/web_assets.py --lint`) fails on a listed name nobody bundled, a bundle
  nobody listed, or any file in `assets/` the bundler didn't make; the server refuses to start on a mismatch.
- **Agents** set only the fields a widget declares, with a value of the declared JSON type (checked by the agent host,
  the runtime and the page); on the web a widget's description goes to the server only while an agent is attached
  (`MOJOUI_AGENT_SOCKET`), and the link is a Unix socket of the user's (0600), not a network port.
- **JSON only**: props are JSON the host parses before the page sees them (attributes are escaped); a payload, reply or
  argument that isn't JSON, an event name that isn't a word, or a tag that isn't a custom element's name is refused.
  Nothing crossing is eval'd or written as HTML: write text with `textContent`.
- **WebFrame** (an iframe) is sandboxed: `allow-scripts allow-forms`, no `allow-same-origin` (its page gets an origin
  of its own), http(s) URLs only. An app can add `allow-popups`, `allow-modals`, `allow-downloads`, and
  `allow-same-origin` only for a page on another origin (Jupyter keeps its own cookies; with ours it could lift its
  sandbox): `WebFrame(url, v, instead, sandbox="allow-same-origin")`. "Another origin" is decided by parsing the URL
  (scheme, host in lower case, port with the default filled in; user info, query and fragment don't change it), and
  two names of this machine on the same port count as ours. When the host can't be sure of its own origin (behind a
  proxy that sends X-Forwarded-* or Forwarded headers) it never grants allow-same-origin.
  **Not a guarantee:** this checks the URL the frame starts at. A page on another origin can redirect or navigate the
  frame to our origin, and it then runs there with allow-same-origin and could lift its sandbox. Only grant it to a
  page you trust as much as your own (the console's local Jupyter).
  The iframe gets no permissions (no `allow=`) unless the app asks: `WebFrame(…, allow="clipboard-read clipboard-write")`
  (clipboard-read, clipboard-write and fullscreen; anything else is dropped).
- Widgets from people you don't trust: only in a WebFrame of their own origin, never as a WebComponent (a widget runs
  with the page's rights).

## 6. On GTK (Linux)

Each WebComponent gets a **WebKitGTK 6.0** view of its own (`mojoui/hosts/gtk_webview.mojo`), loading the **same files**
as the web: `scripts/build.sh <app> linux` runs the same esbuild step into `build/<app>/linux/webview/assets/` (same
bytes, same hashed names) and copies the web host's `mojoui-widgets.js` and `mojoui.css` beside them. Your widget code
doesn't change: `mojoui-widgets.js` sees the WebKit message handler and talks to the GTK host instead of htmx.

- **The page** is `mojoui://app/widget.html`, served by the host from that folder: the host's sheet, the app's theme
  (palette and sheet, as on the web), the runtime and the bundles `web_assets()` lists, with SRI. The origin serves
  those files and the app's fonts, nothing else.
- **Props** go in as JSON through one function call, `mojoui.native.receive(m)`, with the message as its argument (a
  string, never code); the widget's `update()` runs, it is never mounted again. A rebuild of the screen moves the live
  view into the new box (keyed by tag and id, as on the web), so typing, focus and the widget's own state stay.
- **Events and replies** come back through WebKit's script message handler `mojoui` as JSON text; the host refuses a
  message that isn't a string holding a JSON object, names another widget, or carries a payload that isn't JSON, then
  hands the rest to `update()` exactly as the web does (`Event(on_event, text=payload, id, name)`). Commands work the same.
- **The view's height** is the widget's height in its page (a ResizeObserver tells the host); its width is the box's.
- **Security**: the web's CSP (with `frame-src 'none'`) on every file; no network (an ephemeral session whose requests go
  to a proxy that isn't there); no navigation away and no new windows (decide-policy); no file access beyond the bundle;
  no developer tools. `MOJOUI_TRACE=1` prints the page's console.
- **Getting WebKitGTK**: it is loaded the first time a WebComponent shows (apps without one never need it). Install your
  distribution's `webkitgtk-6.0`; where it isn't installed (and you can't), `scripts/webkitgtk.sh` fetches Arch Linux's
  package once, checks its pinned SHA-256 and unpacks it into `build/webkitgtk-6.0/`, and `build.sh` makes
  `build/<app>/linux/<app>` a launcher that lays it over `/usr/lib` with bubblewrap (no root; WebKit's own sandbox still
  runs inside). The launcher checks at run time and runs the app directly when it can't use that copy (an installed
  WebKitGTK, no bubblewrap, a bubblewrap older than 0.10); an offline build skips it with a warning. conda-forge has no
  WebKitGTK for GTK 4. Without WebKitGTK a WebComponent shows its `instead` view.
- **A crashed widget**: if its web process ends, the page loads again once and the widget mounts afresh with Mojo's
  props (its own state is lost); a second time, the WebComponent shows its `instead` view.


## 7. On the Mac (AppKit)

Each WebComponent gets a **WKWebView** of its own (`mojoui/hosts/appkit_webview.mojo`), loading the **same files** as
the web and GTK: `scripts/build.sh <app> mac` runs the same esbuild step into the app's `Contents/Resources/webview/`
(same bytes, same hashed names, the web host's `mojoui-widgets.js` and `mojoui.css` beside them). Your widget code
doesn't change: WKWebView offers the same `window.webkit.messageHandlers.mojoui` that WebKitGTK does.

- **The page** is `mojoui://app/widget.html`, the same page GTK builds, answered by a `WKURLSchemeHandler` from that
  folder: the page, the runtime, the host's sheet, the bundles `web_assets()` lists (with SRI) and the app's fonts,
  nothing else (any other path fails). Every answer carries the web's CSP with `frame-src 'none'`, nosniff and an
  explicit type.
- **Props, the theme and commands** go in through `callAsyncJavaScript` with the message as its argument `m` (data,
  never code): `return mojoui.native.receive(m)`. A rebuild moves the live view into the new box (keyed by tag and id),
  so typing, focus and the widget's own state stay; it is never loaded again.
- **Events and replies** come back through the `mojoui` `WKScriptMessageHandler`: only a string holding a JSON object,
  from the page's main frame, naming the view's own widget; a reply only from the widget its command went to, once.
  The same rules as GTK, counted when refused.
- **Security**: the CSP holds the page to its origin; a content rule list blocks every http(s), ws(s), ftp and file
  load besides; a non-persistent data store (nothing on disk); the navigation delegate allows only the page itself in
  its main frame (no navigation away, no target=_blank), the UI delegate opens no window, and JavaScript can't open
  windows. No inspector in release builds (a debug build, `MOJOUI_DEBUG=1 scripts/build.sh <app> mac`, compiles one; not yet run on a Mac).
- **A crashed widget**: if its web content process ends, the page loads again once and the widget mounts afresh with
  Mojo's props; a second time, the WebComponent shows its `instead` view.
- **WebKit.framework** is loaded (NSBundle) the first time a WebComponent shows; it is part of macOS, so nothing to
  install, and the app links no new C function (Objective-C goes by name).
- **Test steps** (MOJOUI_TEST, GitHub's Macs through `scripts/mac-ci`): `webtype:<tag>#<id>=text` (a click into the
  view, then real key events), `webclick:<tag>#<id>=<CSS selector>` (a real click on that element), `webjs:` and
  `webkill:` as on GTK. The report's pictures draw each view in from WebKit's own snapshot (a WKWebView draws out of
  process, so AppKit's picture of the window leaves it blank).
