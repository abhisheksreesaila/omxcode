# JavaScript in a mojoui app (goal 34)

A Mojo app can place any JavaScript widget (an editor, a map, a chart library) in its screen. The widget is a custom
element; Mojo gives it **props** (JSON), hears its **events** in `update()`, and can call its **commands** (the answer
comes back to `update()` later, as an HTTP reply does). The app keeps every line of state; the widget keeps only its own
(a cursor, a scroll position, a counter's count). Runs on the web and on GTK (§6); the Mac shows `instead` until 34b.

The example is `examples/widgets` (a note in CodeMirror 6, a word count drawn by mojoui and by Apache ECharts, and a
plain-JS counter).

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

The host mounts it once per key (tag + id) and **keeps it**: a props change calls `update()`, and a rebuild of the whole
page moves the live element into the new screen (`Element.moveBefore`: focus, selection and scroll stay). Its CSS can
read the theme's palette (`var(--o-accent)`, `--o-card`, `--o-ink`, `--o-line`…), so it wears the app's theme.

`emit(name, payload, { latest: true })` replaces an unsent event of the same name (a whole text on every keystroke).
TypeScript widgets get types from `mojoui/hosts/static/mojoui-widgets.d.ts` (`/// <reference path=…>`).

### A second library: Apache ECharts (goal 34b)
`examples/widgets/web/widgets/chart.ts` is ECharts 6 from npm (`"echarts": "6.1.0"`, exact, in the lockfile), added
with no change to the hosts: `npm install --package-lock-only --ignore-scripts --save-exact echarts@6.1.0`, one widget
file, two names in `web_assets()`. Import it **tree-shaken** (`echarts/core` plus the chart, components and renderer you
use: `LineChart`, `GridComponent`, `SVGRenderer`), so the bundle carries only those; ECharts needs no `eval` or
`new Function`, so it runs under the CSP as it is. Mojo owns the data (`Props().raw("series", …)`); the widget reads the
theme's palette (`--o-data`, `--o-card`, `--o-ink2`, `--o-line`) and the page's font, and a click on a point emits
`pick {index, value}`.

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

