# The agent host: an omxcode app as MCP tools

The agent is a fifth host (D-160). GTK, the web, the iPad and the Mac each turn an app's tree of views into their own
widgets; `mojoui/hosts/agent.py` turns it into tools for an agent, over MCP on stdio, from the same `mojoui_app` module
the web host serves. An app changes nothing to be driven by an agent: the tag names the tool, the tooltip describes it,
the message is the call. **An agent can do nothing a person couldn't:** a disabled item is no tool, a dialog's or a
context menu's items are tools only while it is open.

## Give an app to Claude Code
```
scripts/agent.sh omxplorer          # builds build/omxplorer/web if needed, prints the one command:
claude mcp add omxplorer -- pixi run python …/mojoui/hosts/agent.py …/build/omxplorer/web
```
Any MCP client works the same way (the server speaks JSON-RPC over stdio, one object per line; D-161). By hand:
```
pixi run python scripts/agent_client.py build/kit/web screen
pixi run python scripts/agent_client.py build/kit/web open-dialog
pixi run python scripts/agent_client.py build/omxplorer/web read name=grid count=5
```

## The tools
Four are always there:
- **screen** · what the app shows right now, as text: every view, the menus with their items and shortcuts, the open
  dialog, toast or popover, and the list of tools a person could use on it.
- **act** · one tool by name, with its value (`{"name": "settings-ledger-graphite-blueprint", "value": {"option": "Graphite"}}`).
  The same as calling the tool directly.
- **read** · the texts on screen (grouped by their tagged container, e.g. `status-bar: Sum 114,007,922.00`); with a
  name, one view's content: a drawn view's rows as tab-separated text where the app offers them (`App.describe`,
  D-163: omxplorer's grid), or a list's rows.
- **render** · a drawn view as a PNG (`{"name": "grid", "width": 900, "height": 400}`), for an agent that can see.

The rest come from the screen (D-162):
| On screen | Tool | Value |
|---|---|---|
| A menu item | `file-save`, `view-skin-graphite` (menu › submenu › item) | — |
| A button with a tag | its tag: `popover-button` | — |
| A button without one | a slug of its title: `open-dialog` | — |
| A file picker | its title: `open-file` | `path` |
| A text field | its tag or placeholder | `text`, `submit` |
| A checkbox or switch | its label: `show-grid-lines` | `on` |
| Segmented, radio, dropdown, tabs | its tag or its options: `ledger-graphite-blueprint` | `option` |
| A slider, a list | its tag | `value`, `row` |
| A canvas | its tag: `canvas`, `grid` | `gesture` (tap, double, secondary, press, release, key, pan, zoom), `x`, `y`, `key`, `modifiers` |
| A context menu's items | the item: `sort-z-a`; `close-menu` | — |
| A dialog's or popover's content | its title first: `settings-done`, `settings-show-grid-lines`; `close-dialog`, `close-popover` | as above |
| A toast | its action: `undo`; `dismiss-toast` | — |

After every call the server sends `notifications/tools/list_changed` (D-164): call `screen` or `tools/list` again to
see what the screen offers now. A wrong name or value comes back as an error result that lists the tools, so the agent
can correct itself.

## JavaScript widgets, and attaching to a running host (goal 34b)
A `WebComponent` is a tool pair, named by its tag (or, without one, its custom element's tag):
- **`<name>-read`** · what the widget describes: its `describe(el)` result as JSON (`{text, value, …}`). The editor:
  `mx-editor#1: {"text": "42 characters, cursor at 42: …", "value": "Agents can write here\nand on a second line", "lines": 2, …}`.
  A widget without `describe` reads `mx-plain#3: no description`.
- **`<name>-set`** · only when the widget declares `fields` in `defineWidget`: one typed argument per field
  (`editor-set {"text": "…"}`, `counter-set {"count": 42}`). The set goes to the widget as the built-in command
  `mojoui.set {field, value}`; the widget's setter changes it and the widget emits its own event, so `update()` hears it
  exactly as from a person (the note's word count follows). An undeclared field or a value of the wrong JSON type is
  refused by the agent host, by the runtime (JSON only) and again by the page's runtime (declared fields only).

Widgets run only where there is a web view, so an agent sees them by **attaching** to a running host instead of running
its own session (D-631). Start the host with `MOJOUI_AGENT_SOCKET=<path>` and the agent with `--attach <path>`:
```
MOJOUI_AGENT_SOCKET=/run/user/$UID/widgets.sock pixi run python mojoui/hosts/web.py build/widgets/web   # then open the page
MOJOUI_AGENT_SOCKET=/run/user/$UID/widgets.sock build/widgets/linux/widgets                             # or the GTK app
claude mcp add widgets -- pixi run python mojoui/hosts/agent.py --attach /run/user/$UID/widgets.sock
```
**The agent link** is the host's side: a Unix socket (mode 0600, only when the variable is set), one JSON request per
line, one JSON answer per line. `{"op":"view"}` → `{ok, title, design, nodes, widgets, busy}` (the tree every host
reads, plus what each widget says about itself); `event {node, second, text, number}`, `gesture {node, kind, x, y, dx,
dy, zoom}`, `key {node, name, modifiers}`, `set {tag, id, field, value: JSON text}`, `describe {node, first, count}`,
`rows {node, first, count}`. The web host serves it from web.py for the newest open page and pushes changes to the page
as effects do (`/wait`); the GTK host from its main loop (`mojoui/hosts/agent_link.mojo`, `g_unix_fd_add`). On the web
the widgets report what they show to the server only while an agent is attached (`data-agent` on the page).
Attached, `render` isn't offered (the host draws its own canvases); everything else works as in the agent's own session.

## What an agent gets back from act
What changed, in words: the new texts (`Now: status-bar: Saved kit.omx`), what opened or closed (`Opened: dialog "Settings"`),
a design change, and the tools that appeared or went. Enough to carry on without a second call.

## What it can't do yet
- Attached to a host: `render` (it draws in the agent's own session only), and the Mac's host has no agent link yet.
- Read cells on any app but omxplorer (the others don't `describe` their canvases); omxplorer reads the shown rows, not a range.
- Move Board objects, drag, or scroll a grid by gesture beyond what `pan` sends.
- Generate UI: that is AG-UI, after MX frame (the operations log is its state).

## What it costs in tokens
Measured 2026-10-22 on omxplorer with `build/data/orders_1m.csv`, through `scripts/agent_client.py` (tokens estimated as characters ÷ 4):

| Call | Characters | ≈ Tokens |
|---|---|---|
| `ask` "revenue by product, largest first, top 5" (what changed) | 256 | 60 |
| `read` (the screen's texts) | 916 | 230 |
| `insert-chart` | 1,063 | 270 |
| `create-table`, `choose-a-file` | 2,500–2,600 | 650 |
| `screen` (everything, a busy screen with 100 tools) | 11,393 | 2,800 |
| `tools/list` (104 tools, as JSON) | 17,437 | 4,400 |

For comparison, one screenshot costs a vision model about 1,600 tokens (Claude: width × height ÷ 750, after resizing to about 1.15 megapixels), and a screen-scraping agent takes one after every action to see what happened. So a call that answers in words is 2–25× cheaper than that screenshot; a full `screen` or a fresh tool list is not, and is worth asking for only when the screen changed a lot.
