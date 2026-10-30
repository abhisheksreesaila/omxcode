"""Agent host: a mojoui app as MCP tools, over stdio (D-160: the agent is a fifth host).

The app is the same Python module the web host serves (build/<app>/web/mojoui_app.so). The current screen
is read as a tree; every node a person could act on becomes a tool, named by its tag or its text (D-162) and
described by its tooltip. Four core tools always exist: screen (the tree and the tools), act (one tool by
name, with its value), read (the texts on screen; a canvas's content as text where the app offers it, D-163;
a list's rows) and render (a canvas as a PNG). The tool list follows the screen (D-164): after every call
the server sends notifications/tools/list_changed, so a dialog's or a context menu's items are tools only
while it is open. An agent can do nothing a person couldn't.

A canvas the app made settable (View.settable(unit, low, high): a video's scrubber, a dial) takes a plain number too: its
tool's `value` argument (seconds, say) arrives as the canvas's SET_TO gesture, no coordinates needed (goal 39 M6).

A JavaScript widget (WebComponent) is a tool pair (goal 34b): <name>-read returns what it describes (its describe() JSON)
and <name>-set sets the fields it declares, typed (a command to the widget; the widget reports the change as its own
event, so update() hears it). Widgets run only in a host with a web view, so to see them the agent attaches to a running
host through its agent link (MOJOUI_AGENT_SOCKET, docs/agent.md): the web host (a page open in a browser) or the GTK app.

Run:          pixi run python mojoui/hosts/agent.py build/kit/web             (its own session: no widgets run)
Attached:     pixi run python mojoui/hosts/agent.py --attach /run/user/1000/kit.sock   (the host's MOJOUI_AGENT_SOCKET)
Claude Code:  claude mcp add kit -- pixi run python mojoui/hosts/agent.py build/kit/web
The protocol is MCP's JSON-RPC over stdio (D-161): one JSON object per line; logs go to stderr.
"""

import base64
import ctypes
import importlib
import io
import json
import os
import re
import socket
import sys
import time
from pathlib import Path

from PIL import Image

# Mirrors mojoui/view.mojo.
(TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE, SEGMENTED, RADIO,
 TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, BOARD, OVERLAY, MENUBAR, MENU, ITEM, DIALOG, TOAST, POPOVER) = range(1, 33)
PARAGRAPH = 39  # styled runs: an agent reads its plain words (text)
WEBCOMP = 40  # a JavaScript widget (mojoui.webcomponent): hint = its tag, value = its id
JSON_TYPES = {"string": (str,), "number": (int, float), "integer": (int,), "boolean": (bool,), "array": (list,), "object": (dict,)}
CHECKED, DISABLED = 1, 2  # menu item flags (mojoui/menus.mojo)
GESTURES = {"pan": 1, "zoom": 2, "tap": 3, "press": 4, "release": 5, "double": 6, "key": 7, "secondary": 8}
SET_TO = 9  # a settable canvas (View.settable) set straight to a number: event.text = the number
MODIFIERS = {"shift": 1, "ctrl": 2, "alt": 4}
PROTOCOLS = ("2024-11-05", "2025-03-26", "2025-06-18")
CORE = ("screen", "act", "read", "render")
NO_ARGS = {"type": "object", "properties": {}}


def slug(text):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:48].rstrip("-")


def settable_range(n):
    """A canvas declared settable (View.settable: options = unit, low, high): (unit, low, high), else None."""
    o = n.get("options") or []
    if n["kind"] != CANVAS or len(o) < 3:
        return None
    try:
        return o[0], float(o[1]), float(o[2])
    except ValueError:
        return None


def prop(kind, description, **more):
    return dict({"type": kind, "description": description}, **more)


class Action:
    """One thing an agent can do on the current screen: a node, how to send it, and the tool that names it."""

    def __init__(self, name, node, kind, description, schema=None, how="msg", required=()):
        self.name, self.node, self.kind, self.description, self.how = name, node, kind, description, how
        self.schema = {"type": "object", "properties": schema or {}}
        if required:
            self.schema["required"] = list(required)

    def tool(self):
        return {"name": self.name, "description": self.description, "inputSchema": self.schema}


def fits(kind, value):
    """value (parsed JSON) is of JSON type `kind` (a bool is no number; a whole float counts as an integer)."""
    if isinstance(value, bool):
        return kind == "boolean"
    if kind == "integer" and isinstance(value, float):
        return value.is_integer()
    return isinstance(value, JSON_TYPES.get(kind, ()))


class Link:
    """A running host's agent link (MOJOUI_AGENT_SOCKET): one JSON request per line, one JSON answer per line. The host
    owns the session; this side only reads its tree and sends what a person could."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(str(path))
        self.buf = b""

    def call(self, op):
        self.sock.sendall((json.dumps(op) + "\n").encode())
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("the host closed its agent link")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def ok(self, op):
        r = self.call(op)
        if not r.get("ok"):
            raise ValueError(r.get("error") or f"the host refused {op.get('op')}")
        return r


class Host:
    def __init__(self, module_dir=None, attach=None):
        self.link = Link(attach) if attach else None
        self.mod = self.handle = None
        if self.link is None:
            sys.path.insert(0, str(Path(module_dir).resolve()))
            self.mod = importlib.import_module("mojoui_app")
            if hasattr(self.mod, "init_shared"):
                self.mod.init_shared()
            self.handle = self.mod.new_session()
            self.title = self.mod.title(self.handle)
        self.nodes = []
        self.actions = []
        self.widgets = {}  # (tag, id) → what the widget says about itself (attached hosts only)
        self.busy = False
        self.reload()

    # ---------- the tree ----------

    def reload(self):
        if self.link is not None:
            r = self.link.ok({"op": "view"})
            self.title, self.nodes, self.busy = r["title"], r["nodes"], bool(r.get("busy"))
            self.design = (r.get("design") or "native").capitalize()
            self.widgets = {(w.get("tag"), w.get("id")): w for w in r.get("widgets", []) if isinstance(w, dict)}
        else:
            self.nodes = json.loads(self.mod.view(self.handle))
            self.design = (self.mod.theme(self.handle).split("\x1f")[0] or "native").capitalize()  # the theme's id (D-260)
        self.actions = []
        self.names = set(CORE)
        self.walk(0, "")

    def unique(self, name):
        name = name or "view"
        base, k = name, 2
        while name in self.names:
            name = f"{base}-{k}"
            k += 1
        self.names.add(name)
        return name

    def add(self, name, i, description, schema=None, how="msg", required=(), prefix=""):
        n = self.nodes[i]
        if prefix and not n["name"] and n["kind"] != ITEM:  # inside a dialog or popover: its title first (tags stay as they are)
            name = prefix + name
        a = Action(self.unique(name), i, n["kind"], description, schema, how, required)
        self.actions.append(a)
        return a

    def walk(self, i, prefix):
        n = self.nodes[i]
        k, tag, tip, text = n["kind"], n["name"], n["tip"], n["text"]
        if k == MENUBAR:
            for c in n["children"]:
                self.walk(c, prefix)
        elif k == MENU:
            if n["style"] == 1:  # a context menu: its items stand alone; closing it is an action too
                if n["msg2"]:
                    self.add("close-menu", i, "Close the context menu without choosing", how="second")
                for c in n["children"]:
                    self.item(c, "")
            else:
                for c in n["children"]:
                    self.item(c, slug(text) + "-", [text])
        elif k == BUTTON:
            if n["msg2"] and n["options"]:  # a file picker
                self.add(tag or slug(text), i, (tip or f'"{text}": choose a file') + f" (accepts {n['options'][0] or 'any file'})",
                         {"path": prop("string", "the file's path on this machine")}, how="pick", required=("path",), prefix=prefix)
            elif n["msg"]:
                self.add(tag or slug(text), i, tip or f'Button "{text}"', prefix=prefix)
                if n["options"] and n["size"]:  # a pair's other face (View.alternate): its own tool, meaning one thing whatever the state
                    other = n["options"][0]
                    self.add(slug(other), i, f'"{other}": the other face of the "{text}" button (does nothing when already so)', how="second", prefix=prefix)
        elif k == FIELD:
            if n["msg"] or n["msg2"]:
                self.add(tag or slug(n["hint"] or text) or "field", i, tip or f'Text field "{n["hint"] or text}"',
                         {"text": prop("string", "the new contents"), "submit": prop("boolean", "press Return after typing")}, how="field", required=("text",), prefix=prefix)
        elif k == TEXTAREA:
            if n["msg"]:
                self.add(tag or slug(n["hint"]) or "textarea", i, tip or f'Text area "{n["hint"]}"', {"text": prop("string", "the new contents")}, how="text", required=("text",), prefix=prefix)
        elif k == TOGGLE:
            if n["msg"]:
                self.add(tag or slug(text), i, (tip or f'{"Checkbox" if n["style"] == 1 else "Switch"} "{text}"') + f" (now {'on' if n['value'] else 'off'})",
                         {"on": prop("boolean", "on or off")}, how="toggle", required=("on",), prefix=prefix)
        elif k in (DROPDOWN, SEGMENTED, RADIO, TABS):
            if n["msg"] and n["options"]:
                what = {DROPDOWN: "Dropdown", SEGMENTED: "Segmented control", RADIO: "Radio buttons", TABS: "Tabs"}[k]
                cur = n["options"][n["value"]] if 0 <= n["value"] < len(n["options"]) else ""
                self.add(tag or slug(" ".join(n["options"][:3])), i, (tip or what) + f' (now "{cur}")',
                         {"option": prop("string", "which option", enum=n["options"])}, how="option", required=("option",), prefix=prefix)
        elif k == SLIDER:
            if n["msg"]:
                self.add(tag or "slider", i, (tip or "Slider") + f" (now {n['value']})", {"value": prop("integer", "0 to 100")}, how="number", required=("value",), prefix=prefix)
        elif k == DATE:
            if n["msg"]:
                self.add(tag or "date", i, (tip or "Date picker") + f" (now {text})", {"date": prop("string", "YYYY-MM-DD")}, how="text", required=("date",), prefix=prefix)
        elif k == ALERT:
            self.add(tag or "alert", i, f'Answer the alert "{text}": {n["hint"]}', {"button": prop("string", "which button", enum=n["options"])}, how="option", required=("button",), prefix=prefix)
        elif k == LAZYLIST:
            if n["msg"]:
                self.add(tag or "list", i, (tip or "A list") + f" of {n['value']} rows: tap one", {"row": prop("integer", "the row's number, from 0")}, how="number", required=("row",), prefix=prefix)
        elif k == CANVAS:
            if n["msg"]:
                size = f"{n['w']}×{n['h']} points" if n["w"] and n["h"] else "fills its space"
                settable = settable_range(n)
                schema = {"gesture": prop("string", "what happened", enum=list(GESTURES) + (["set"] if settable else [])),
                          "x": prop("number", "points from the left"), "y": prop("number", "points from the top"),
                          "key": prop("string", 'for "key": the key\'s name (ArrowDown, Enter, Escape, F2, a, 7…)'),
                          "modifiers": prop("array", "for \"key\": shift, ctrl, alt", items={"type": "string"})}
                what = (tip or "A drawn view") + f" ({size}): tap, double, secondary (a right click), press, release, or a key" + ("; takes keys" if n["size"] else "")
                if settable:  # (View.settable: a value straight, no coordinates; the value alone is enough)
                    unit, lo, hi = settable
                    schema = {"value": prop("number", f"the {unit} to set it to, {lo:g} to {hi:g}"), **schema}
                    what = (tip or "A drawn control") + f": set it to a time or amount in {unit} ({lo:g} to {hi:g}) with value; or a gesture ({size})"
                self.add(tag or f"canvas-{n['style']}", i, what, schema, how="gesture", required=() if settable else ("gesture",), prefix=prefix)
        elif k == WEBCOMP:
            self.widget_tools(i, prefix)
        elif k == NAVBAR:
            if n["msg"]:
                self.add("back", i, f'Go back from "{text}"', prefix=prefix)
        elif k == TOAST:
            if n["msg"] and n["options"] and n["options"][0]:
                self.add(slug(n["options"][0]), i, f'The toast "{text}": {n["options"][0]}', prefix=prefix)
            if n["msg2"]:
                self.add("dismiss-toast", i, f'Dismiss the toast "{text}"', how="second", prefix=prefix)
        elif k == DIALOG:
            if n["msg2"]:
                self.add("close-dialog", i, f'Close the dialog "{text}"', how="second")
            for c in n["children"]:
                self.walk(c, slug(text) + "-")
        elif k == POPOVER:
            if n["msg2"]:
                self.add("close-popover", i, f'Close the popover "{n["hint"] or text}"', how="second")
            for c in n["children"]:
                self.walk(c, slug(n["hint"] or text) + "-")
        elif k in (VSTACK, HSTACK, SCROLL, GRID, BOARD, OVERLAY):  # containers: what's inside
            for c in n["children"]:
                self.walk(c, prefix)

    def widget(self, i):
        """What widget node i says about itself: its facts from the host (None: not running here, or not reported yet)."""
        n = self.nodes[i]
        return self.widgets.get((n["hint"], n["value"]))

    def widget_what(self, i):
        n, f = self.nodes[i], self.widget(i)
        what = (f or {}).get("description") or n["tip"]
        if f is None:
            return f"Widget {n['hint']}" + (f": {what}" if what else "") + (" (not running here: no web view in the agent's own session)" if self.link is None else " (not mounted yet)")
        if f.get("said") is None:
            return f"Widget {n['hint']}" + (f": {what}" if what else "") + " (no description)"
        return f"Widget {n['hint']}" + (f": {what}" if what else "")

    def widget_tools(self, i, prefix):
        """A WebComponent as tools (goal 34b): <name>-read always; <name>-set when it declares fields, one typed argument each."""
        n, f = self.nodes[i], self.widget(i)
        base = n["name"] or n["hint"]
        self.add(base + "-read", i, self.widget_what(i) + ". Read what it shows, as JSON (its describe())", how="widget-read", prefix=prefix)
        fields = (f or {}).get("fields") or {}
        fields = {k: v for k, v in fields.items() if isinstance(k, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:-]{0,63}", k) and v in JSON_TYPES}
        if fields and n["msg"]:
            self.add(base + "-set", i, self.widget_what(i) + ". Set " + ", ".join(f"{k} ({v})" for k, v in fields.items())
                     + ": the widget changes and tells the app, as if a person did it",
                     {k: prop(v, f"its new {k}") for k, v in fields.items()}, how="widget-set", prefix=prefix)

    def widget_read(self, i):
        n, f = self.nodes[i], self.widget(i)
        key = f"{n['hint']}#{n['value']}"
        if f is None:
            if self.link is None:
                return (f"{key}: not running in the agent's own session (it has no web view). Run the app with MOJOUI_AGENT_SOCKET=<path> "
                        "(the web host with a page open, or the GTK app) and start the agent with --attach <path> (docs/agent.md).")
            return f"{key}: not mounted yet"
        if f.get("said") is None:
            return f"{key}: no description"
        return f"{key}: " + json.dumps(f["said"], ensure_ascii=False)

    def item(self, i, prefix, path=()):
        n = self.nodes[i]
        if n["style"] in (1, 2) or n["value"] & DISABLED:  # a separator, a section label, or off
            return
        if n["children"]:  # a submenu
            for c in n["children"]:
                self.item(c, prefix + slug(n["text"]) + "-", [*path, n["text"]])
            return
        if not n["msg"]:
            return
        where = f" · in the {' › '.join(path)} menu" if path else " · in the context menu"
        self.add(prefix + slug(n["text"]), i, n["text"] + (f" ({n['options'][0]})" if n["options"] and n["options"][0] else "")
                 + (" · checked" if n["value"] & CHECKED else "") + where)

    def action(self, name):
        for a in self.actions:
            if a.name == name:
                return a
        return None

    def by_tag(self, name):
        for i, n in enumerate(self.nodes):
            if n["name"] == name:
                return i
        a = self.action(name)
        return a.node if a else -1

    # ---------- what's on screen, as text ----------

    def outline(self):
        out = []
        names = {a.node: a.name for a in self.actions}
        for a in self.actions:  # (a node with several actions: list them all)
            names[a.node] = ", ".join(x.name for x in self.actions if x.node == a.node)

        def arrow(i):
            return f" → {names[i]}" if i in names else ""

        def options(n):
            return "[" + ", ".join(("*" if j == n["value"] else "") + o for j, o in enumerate(n["options"])) + "]"

        def menu_items(i):
            parts = []
            for c in self.nodes[i]["children"]:
                m = self.nodes[c]
                if m["style"] == 1:
                    parts.append("—")
                elif m["style"] == 2:
                    parts.append(f"[{m['text']}]")
                elif m["children"]:
                    parts.append(f"{m['text']} ▸ ({menu_items(c)})")
                else:
                    parts.append(m["text"] + (f" ({m['options'][0]})" if m["options"] and m["options"][0] else "") + (" ✓" if m["value"] & CHECKED else "")
                                 + (" (off)" if m["value"] & DISABLED else "") + arrow(c))
            return ", ".join(parts)

        def line(depth, s):
            out.append("  " * depth + s)

        def walk(i, depth):
            n = self.nodes[i]
            k, text = n["kind"], n["text"]
            if k in (TEXT, PARAGRAPH):  # (a Paragraph: its plain words; its runs' looks don't reach an agent)
                line(depth, f'"{text}"')
            elif k == BUTTON:
                line(depth, f'Button "{text}"' + (" = on" if n["style"] in (6, 7) else "") + (f' ({n["tip"]})' if n["tip"] else "") + arrow(i))  # (TOOL_ON, ICON_ON: pressed)
            elif k == FIELD:
                line(depth, f'Field "{text}"' + (f' (placeholder "{n["hint"]}")' if n["hint"] else "") + arrow(i))
            elif k == TEXTAREA:
                line(depth, f'Text area "{text}"' + arrow(i))
            elif k == TOGGLE:
                line(depth, f'{"Checkbox" if n["style"] == 1 else "Switch"} "{text}" = {"on" if n["value"] else "off"}' + arrow(i))
            elif k in (DROPDOWN, SEGMENTED, RADIO, TABS):
                line(depth, {DROPDOWN: "Dropdown", SEGMENTED: "Segmented", RADIO: "Radio", TABS: "Tabs"}[k] + " " + options(n) + arrow(i))
            elif k == SLIDER:
                line(depth, f"Slider {n['value']}" + arrow(i))
            elif k == PROGRESS:
                line(depth, f"Progress {n['value']}%")
            elif k == DATE:
                line(depth, f"Date {text}" + arrow(i))
            elif k == IMAGE:
                line(depth, f"Image {n['spacing']}×{n['size']}")
            elif k == ICON:
                line(depth, f"Icon {text}")
            elif k == DIVIDER:
                line(depth, "—")
            elif k == ALERT:
                line(depth, f'Alert "{text}": {n["hint"]} {options(n)}' + arrow(i))
            elif k == NAVBAR:
                line(depth, f'Title bar "{text}"' + arrow(i))
            elif k == LAZYLIST:
                line(depth, f"List of {n['value']} rows (read it)" + arrow(i))
            elif k == CANVAS:
                size = f"{n['w']}×{n['h']}" if n["w"] and n["h"] else "fills"
                line(depth, f"Canvas {size} (render it; read it)" + arrow(i))
            elif k == WEBCOMP:
                f = self.widget(i)
                said = (f or {}).get("said")
                line(depth, f"{self.widget_what(i)} #{n['value']}" + (f": {said.get('text')}" if isinstance(said, dict) and said.get("text") else "") + arrow(i))
            elif k == MENUBAR:
                line(depth, "Menu bar: " + ", ".join(self.nodes[c]["text"] for c in n["children"]))
                for c in n["children"]:
                    line(depth + 1, f"{self.nodes[c]['text']}: {menu_items(c)}")
            elif k == MENU:
                line(depth, f"Context menu (open, on {text}): {menu_items(i)}" + arrow(i))
            elif k == DIALOG:
                line(depth, f'Dialog "{text}" (open)' + arrow(i))
                for c in n["children"]:
                    walk(c, depth + 1)
            elif k == POPOVER:
                line(depth, f'Popover "{n["hint"]}" (open, on {text})' + arrow(i))
                for c in n["children"]:
                    walk(c, depth + 1)
            elif k == TOAST:
                line(depth, f'Toast "{text}"' + arrow(i))
            elif k == BOARD:
                line(depth, "Board:")
                for c in n["children"]:
                    m = self.nodes[c]
                    line(depth + 1, f"Object [{m['name'] or '?'}] at {m['x']},{m['y']} {m['w']}×{m['h']}")
                    walk_children(c, depth + 2)
            elif n["name"]:  # a tagged container: its name groups what's inside
                line(depth, f"[{n['name']}]")
                walk_children(i, depth + 1)
            else:
                walk_children(i, depth)

        def walk_children(i, depth):
            for c in self.nodes[i]["children"]:
                walk(c, depth)

        walk(0, 0)
        return "\n".join(out)

    def screen(self):
        head = f"{self.title} · design: {self.design} · {len(self.actions)} tools on this screen"
        tools = "\n".join(f"  {a.name} — {a.description}" for a in self.actions)
        return f"{head}\n\n{self.outline()}\n\nTools (call them by name, or act with name + value):\n{tools}"

    def texts(self):
        out = []

        def walk(i, group):
            n = self.nodes[i]
            if n["kind"] in (TEXT, PARAGRAPH):
                out.append((group + ": " if group else "") + n["text"])
            for c in n["children"]:
                walk(c, n["name"] or group)
        walk(0, "")
        return out

    def overlays(self):
        return [(n["kind"], n["text"] or n["hint"]) for n in self.nodes if n["kind"] in (DIALOG, TOAST, POPOVER, ALERT) or (n["kind"] == MENU and n["style"] == 1)]

    # ---------- doing ----------

    # (the two backends: this process's own session, or a running host's agent link)
    def send_event(self, i, second, text, number):
        if self.link is not None:
            return self.link.ok({"op": "event", "node": i, "second": int(second), "text": text, "number": int(number)})
        return self.mod.event(self.handle, i, second, text, number)

    def send_gesture(self, i, kind, x, y, dx, dy, zoom):
        if self.link is not None:
            return self.link.ok({"op": "gesture", "node": i, "kind": kind, "x": x, "y": y, "dx": dx, "dy": dy, "zoom": zoom})
        return self.mod.gesture(self.handle, i, kind, x, y, dx, dy, zoom)

    def send_key(self, i, name, mods):
        if self.link is not None:
            return self.link.ok({"op": "key", "node": i, "name": name, "modifiers": mods})
        return self.mod.key(self.handle, i, name, mods)

    def widget_set(self, i, args):
        """A declared field set to a value of its type: the agent host checks, the host's runtime checks it's JSON, the
        page's runtime checks the field and type again and runs the widget's setter."""
        n, f = self.nodes[i], self.widget(i)
        fields = ((f or {}).get("fields") or {})
        if not args:
            raise ValueError(f"give one of its fields: {', '.join(f'{k} ({v})' for k, v in fields.items())}")
        for k, v in args.items():
            if k not in fields:
                raise ValueError(f"{n['hint']} has no settable field {k!r}; its fields: " + (", ".join(f"{a} ({b})" for a, b in fields.items()) or "none"))
            if not fits(fields[k], v):
                raise ValueError(f"{n['hint']}.{k} takes {fields[k]}, not {type(v).__name__}")
        if self.link is None:
            raise ValueError("widgets don't run in the agent's own session: attach to a running host (docs/agent.md)")
        for k, v in args.items():
            self.link.ok({"op": "set", "tag": n["hint"], "id": n["value"], "field": k, "value": json.dumps(v)})

    def dispatch(self, a, args):
        n = self.nodes[a.node]
        i = a.node
        if a.how == "widget-read":
            return None
        if a.how == "widget-set":
            return self.widget_set(i, args)
        if a.how == "msg":
            return self.send_event(i, 0, "", 0)
        if a.how == "second":
            return self.send_event(i, 1, "", 0)
        if a.how == "pick":
            return self.send_event(i, 1, str(args.get("path", "")), 0)
        if a.how == "field":
            text = str(args.get("text", ""))
            r = self.send_event(i, 0, text, 0) if n["msg"] else None
            if args.get("submit") and n["msg2"]:
                r = self.send_event(i, 1, text, 0)
            return r
        if a.how == "text":
            return self.send_event(i, 0, str(args.get("text", args.get("date", ""))), 0)
        if a.how == "toggle":
            return self.send_event(i, 0, "", 1 if args.get("on") else 0)
        if a.how == "number":
            return self.send_event(i, 0, "", int(args.get("value", args.get("row", 0))))
        if a.how == "option":
            want = str(args.get("option", args.get("button", "")))
            if want not in n["options"]:
                raise ValueError(f'no option "{want}": ' + ", ".join(n["options"]))
            return self.send_event(i, 0, "", n["options"].index(want))
        if a.how == "gesture":
            if settable_range(n) and (args.get("gesture") == "set" or ("value" in args and "gesture" not in args)):
                v = args.get("value")
                if isinstance(v, bool) or not isinstance(v, (int, float)):
                    raise ValueError(f"value takes a number of {settable_range(n)[0]}, not {v!r}")
                return self.send_event(i, 0, repr(float(v)), SET_TO)
            g = str(args.get("gesture", "tap"))
            if g not in GESTURES:
                raise ValueError(f'no gesture "{g}": ' + ", ".join(GESTURES))
            x, y = float(args.get("x", 0)), float(args.get("y", 0))
            if g == "key":
                mods = sum(MODIFIERS.get(str(m).lower(), 0) for m in args.get("modifiers", []) or [])
                return self.send_key(i, str(args.get("key", "")), mods)
            if g == "pan":
                return self.send_gesture(i, GESTURES[g], x, y, float(args.get("dx", 0)), float(args.get("dy", 0)), 1.0)
            if g == "zoom":
                return self.send_gesture(i, GESTURES[g], x, y, 0.0, 0.0, float(args.get("zoom", 2.0)))
            if g == "double":  # (a double click follows the tap of its first click, like every host)
                self.send_gesture(i, GESTURES["tap"], x, y, 0.0, 0.0, 1.0)
            return self.send_gesture(i, GESTURES[g], x, y, 0.0, 0.0, 1.0)
        raise ValueError(f"can't do {a.how}")

    def act(self, name, args):
        if self.link is not None:  # (a running host's screen moves on by itself: act on what it shows now)
            self.reload()
        a = self.action(name)
        if a is None:
            raise ValueError(f'no tool "{name}" on this screen; the tools are: ' + ", ".join(x.name for x in self.actions))
        if a.how == "widget-read":
            self.reload()
            return self.widget_read(a.node)
        before_texts, before_over, before_design, before_names = self.texts(), self.overlays(), self.design, {x.name for x in self.actions}
        before_said = {k: json.dumps(w.get("said"), sort_keys=True) for k, w in self.widgets.items()}
        self.dispatch(a, args)
        self.reload()
        self.settle(widget=(self.nodes[a.node]["hint"], self.nodes[a.node]["value"]) if a.how == "widget-set" else None, said=before_said)
        out = [f"Did {name}."]
        for key, w in self.widgets.items():
            if json.dumps(w.get("said"), sort_keys=True) != before_said.get(key) and isinstance(w.get("said"), dict):
                out.append(f"Now: {key[0]}#{key[1]}: {w['said'].get('text') or json.dumps(w['said'], ensure_ascii=False)[:300]}")
        gone = [t for t in before_texts if t not in self.texts()]
        new = [t for t in self.texts() if t not in before_texts]
        for t in new:
            out.append("Now: " + t)
        if gone and not new:
            out.append("Gone: " + "; ".join(gone[:6]))
        for kind, text in self.overlays():
            if (kind, text) not in before_over:
                out.append(f"Opened: {dict(((DIALOG, 'dialog'), (TOAST, 'toast'), (POPOVER, 'popover'), (ALERT, 'alert'), (MENU, 'context menu')))[kind]} \"{text}\"")
        for kind, text in before_over:
            if (kind, text) not in self.overlays():
                out.append(f"Closed: \"{text}\"")
        if self.design != before_design:
            out.append(f"Design: {self.design}")
        names = {x.name for x in self.actions}
        if names != before_names:
            added, removed = sorted(names - before_names), sorted(before_names - names)
            out.append(f"Tools now {len(names)}" + (f"; new: {', '.join(added)}" if added else "") + (f"; gone: {', '.join(removed)}" if removed else ""))
        return "\n".join(out)

    def settle(self, widget=None, said=None):
        """Display frames to the canvases that ask for them, until none does: an agent gets the settled screen. Work
        an app polls on its frames (a background job behind the island, D-283) lands before the tool answers. A canvas
        that animates for good gets 2 s; the island waits for its job (up to MOJOUI_AGENT_SETTLE_S, 300 s)."""
        if self.link is not None:  # (a running host draws its own frames: wait until its screen and widgets stop changing)
            return self.settle_link(widget, said or {})
        if not hasattr(self.mod, "frame"):
            return
        t0 = last = time.perf_counter()
        cap = float(os.environ.get("MOJOUI_AGENT_SETTLE_S", "300"))
        while True:
            wanting = [j for j, n in enumerate(self.nodes) if n["kind"] == CANVAS and n["msg2"]]
            if not wanting:
                return
            now = time.perf_counter()
            if now - t0 > 2.0:  # (past 2 s only the island keeps its frames: a canvas animating for good doesn't hold every action)
                wanting = [j for j in wanting if self.nodes[j]["name"] == "island"]
            if not wanting or now - t0 > cap:
                return
            us = int((now - last) * 1e6) or 16667
            last = now
            for j in wanting:
                if j < len(self.nodes) and self.nodes[j]["kind"] == CANVAS:
                    self.mod.frame(self.handle, j, us)
            self.reload()  # (frame()'s own answer isn't needed: whether a canvas still asks is in the tree, msg2)
            time.sleep(0.016)

    def settle_link(self, widget, said):
        """An attached host's screen settles: nothing pending for its page, the same tree and widget facts for 0.3 s; after
        a set, until the widget said something new (its own event has run through update()). At most 5 s."""
        t0, last, since = time.perf_counter(), None, time.perf_counter()
        while time.perf_counter() - t0 < 5.0:
            time.sleep(0.1)
            self.reload()
            sig = json.dumps([self.nodes, sorted(self.widgets.items(), key=str)], sort_keys=True, default=str)
            if sig != last:
                last, since = sig, time.perf_counter()
                continue
            waiting = widget is not None and json.dumps((self.widgets.get(widget) or {}).get("said"), sort_keys=True) == said.get(widget)
            if not self.busy and not waiting and time.perf_counter() - since >= 0.3:
                return

    def read(self, name, first, count):
        if not name:
            return "\n".join(self.texts()) or "(no text on screen)"
        i = self.by_tag(name)
        if i < 0:
            raise ValueError(f'nothing called "{name}" on this screen')
        n = self.nodes[i]
        if n["kind"] == WEBCOMP:
            return self.widget_read(i)
        if n["kind"] == CANVAS and self.link is not None:
            return self.link.ok({"op": "describe", "node": i, "first": int(first), "count": int(count)})["text"] or "This view has no text to offer."
        if n["kind"] == LAZYLIST and self.link is not None:
            rows = self.link.ok({"op": "rows", "node": i, "first": int(first), "count": int(count) if count > 0 else 50})["rows"]
            return "\n".join(f"{int(first) + k}\t{t}" for k, t in enumerate(rows)) or "(no rows)"
        if n["kind"] == CANVAS:
            if not hasattr(self.mod, "describe"):
                return "This app doesn't offer its drawn views as text; render it instead."
            text = self.mod.describe(self.handle, i, int(first), int(count))
            return text or "This view has no text to offer; render it instead."
        if n["kind"] == LAZYLIST:
            rows = json.loads(self.mod.rows(self.handle, i, int(first), int(count) if count > 0 else 50))
            return "\n".join(f"{int(first) + k}\t{t}" for k, t in enumerate(rows)) or "(no rows)"
        texts = []

        def walk(j):
            if self.nodes[j]["kind"] in (TEXT, PARAGRAPH):
                texts.append(self.nodes[j]["text"])
            for c in self.nodes[j]["children"]:
                walk(c)
        walk(i)
        return "\n".join(texts) or f'"{n["text"]}"'

    def render(self, name, width, height):
        if self.link is not None:
            raise ValueError("render draws in the agent's own session (agent.py <build dir>); an attached host draws its canvases itself")
        i = self.by_tag(name) if name else next((j for j, n in enumerate(self.nodes) if n["kind"] == CANVAS), -1)
        if i < 0 or self.nodes[i]["kind"] != CANVAS:
            raise ValueError(f'"{name}" is not a canvas on this screen; the canvases are: '
                             + ", ".join(n["name"] or f"canvas-{n['style']}" for n in self.nodes if n["kind"] == CANVAS))
        n = self.nodes[i]
        w = int(width or n["w"] or 800)
        h = int(height or n["h"] or 500)
        r = json.loads(self.mod.draw(self.handle, i, w, h, 1.0, 1))  # (still: an agent gets the settled picture)
        rgba = ctypes.string_at(r["address"], r["width"] * r["height"] * 4)
        picture = Image.frombuffer("RGBA", (r["width"], r["height"]), rgba, "raw", "RGBA", 0, 1).convert("RGB")
        out = io.BytesIO()
        picture.save(out, "PNG", compress_level=6)
        self.reload()
        return out.getvalue(), r["width"], r["height"]

    # ---------- MCP ----------

    def tools(self):
        if self.link is not None:
            self.reload()
        core = [
            {"name": "screen", "description": f"What {self.title} shows right now: every view as text, and the tools a person could use on it.", "inputSchema": NO_ARGS},
            {"name": "act", "description": "Use one tool on the screen by name (the same as calling it directly), with its value.",
             "inputSchema": {"type": "object", "properties": {"name": prop("string", "a tool's name from screen"), "value": prop("object", "its arguments, if any")}, "required": ["name"]}},
            {"name": "read", "description": "The texts on screen; or, with a name, one view's content: a drawn view's rows as tab-separated text (when the app offers it), a list's rows.",
             "inputSchema": {"type": "object", "properties": {"name": prop("string", "a view's tag or tool name; omit for every text on screen"),
                                                              "first": prop("integer", "first row, from 0"), "count": prop("integer", "how many rows (0: what fits on screen)")}}},
            {"name": "render", "description": "A drawn view as a PNG picture.",
             "inputSchema": {"type": "object", "properties": {"name": prop("string", "the canvas's tag (omit: the first canvas)"), "width": prop("integer", "pixels"), "height": prop("integer", "pixels")}}},
        ]
        return core + [a.tool() for a in self.actions]

    def call(self, name, args):
        args = args or {}
        if name == "screen":
            self.reload()
            return self.screen()
        if name == "act":
            return self.act(str(args.get("name", "")), args.get("value") or {})
        if name == "read":
            return self.read(str(args.get("name", "") or ""), int(args.get("first", 0) or 0), int(args.get("count", 0) or 0))
        if name == "render":
            png, w, h = self.render(str(args.get("name", "") or ""), args.get("width"), args.get("height"))
            return [{"type": "image", "data": base64.b64encode(png).decode(), "mimeType": "image/png"}, {"type": "text", "text": f"{w}×{h} PNG"}]
        return self.act(name, args)


def serve(host):
    proto = os.fdopen(os.dup(1), "wb")  # the protocol's channel; everything else the app prints goes to stderr
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    def send(obj):
        proto.write((json.dumps(obj, ensure_ascii=False) + "\n").encode())
        proto.flush()

    for raw in sys.stdin.buffer:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        rid, method, params = msg.get("id"), msg.get("method", ""), msg.get("params") or {}
        if method == "initialize":
            v = params.get("protocolVersion", PROTOCOLS[-1])
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": v if v in PROTOCOLS else PROTOCOLS[-1],
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": f"omxcode · {host.title}", "version": "0.1"},
                "instructions": (f"{host.title} is an omxcode app. Call screen to see what it shows and which tools a person could use right now; "
                                 "call a tool by its name (or act) to use it; read for the texts, a drawn view's rows, or a list's rows; render for a picture of a drawn view. "
                                 "The tools change with the screen (a dialog's or a menu's items exist while it is open): call screen again after acting.")}})
        elif method == "notifications/initialized" or method.startswith("notifications/"):
            continue
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": rid, "result": {"tools": host.tools()}})
        elif method == "tools/call":
            name = str(params.get("name", ""))
            try:
                result = host.call(name, params.get("arguments") or {})
                content = result if isinstance(result, list) else [{"type": "text", "text": str(result)}]
                send({"jsonrpc": "2.0", "id": rid, "result": {"content": content, "isError": False}})
            except Exception as ex:  # a wrong name or value is the agent's mistake, not the server's: tell it
                send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": f"{type(ex).__name__}: {ex}"}], "isError": True}})
            send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})  # D-164
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no method {method}"}})


if __name__ == "__main__":
    if len(sys.argv) < 2 or (sys.argv[1] == "--attach" and len(sys.argv) < 3):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    serve(Host(attach=sys.argv[2]) if sys.argv[1] == "--attach" else Host(sys.argv[1]))
