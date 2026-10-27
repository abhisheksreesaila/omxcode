# JavaScript in a mojoui app (goal 34)

A Mojo app can place any JavaScript widget (an editor, a map, a chart library) in its screen. The widget is a custom
element; Mojo gives it **props** (JSON), hears its **events** in `update()`, and can call its **commands** (the answer
comes back to `update()` later, as an HTTP reply does). The app keeps every line of state; the widget keeps only its own
(a cursor, a scroll position, a counter's count). Runs on the web today; GTK shows a stand-in until goal 34's M3.

The example is `examples/widgets` (a note in CodeMirror 6, a word count, a chart, and a plain-JS counter).

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
`build/<app>/npm/` (no package runs code at install time), then esbuild bundles and minifies each file in `web/widgets/`
offline (TypeScript too: esbuild strips the types; it doesn't check them) into
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

The host mounts it once per key (tag + id) and **keeps it**: a props change calls `update()`, and a rebuild of the whole
page moves the live element into the new screen (`Element.moveBefore`: focus, selection and scroll stay). Its CSS can
read the theme's palette (`var(--o-accent)`, `--o-card`, `--o-ink`, `--o-line`…), so it wears the app's theme.

`emit(name, payload, { latest: true })` replaces an unsent event of the same name (a whole text on every keystroke).
TypeScript widgets get types from `mojoui/hosts/static/mojoui-widgets.d.ts` (`/// <reference path=…>`).

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
- **JSON only**: props are JSON the host parses before the page sees them (attributes are escaped); a payload, reply or
  argument that isn't JSON, an event name that isn't a word, or a tag that isn't a custom element's name is refused.
  Nothing crossing is eval'd or written as HTML: write text with `textContent`.
- **WebFrame** (an iframe) is sandboxed: `allow-scripts allow-forms`, no `allow-same-origin` (its page gets an origin
  of its own), http(s) URLs only. An app can add `allow-popups`, `allow-modals`, `allow-downloads`, and
  `allow-same-origin` only for a page on another origin (Jupyter keeps its own cookies; with ours it could lift its
  sandbox): `WebFrame(url, v, instead, sandbox="allow-same-origin")`.
- Widgets from people you don't trust: only in a WebFrame of their own origin, never as a WebComponent (a widget runs
  with the page's rights).
