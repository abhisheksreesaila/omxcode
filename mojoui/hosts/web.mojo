# Web host, Mojo side: the app runs inside the Python web server (FastHTML).
# Python calls three functions per app (see hosts/web_main.mojo): start a
# session, get the screen as JSON, and send an event (getting back what changed).
# The HTML is made in Python by mojoui/hosts/web.py.

from mojoui.look import look_web_css
from std.memory import Pointer
from std.memory.alloc import alloc, Layout

from mojoui.view import View, DROPDOWN, IMAGE, SEGMENTED, RADIO, TABS, ALERT, LAZYLIST, CANVAS, PARAGRAPH
from mojoui.paragraph import link_href
from mojoui.diff import Diff
from mojoui.app import App, Event, Runtime
from mojoui.webcomponent import commands_json, assets_json
from mojoui.canvas import Surface
from mojoui.theme import Palette, hex_of, palette_css, tokens_css, theme_tokens
from mojoui.clock import now_ns


def json_str(s: String) -> String:
    """A JSON string literal."""
    var out = String('"')
    for c in s.codepoint_slices():
        if c == '"':
            out += '\\"'
        elif c == "\\":
            out += "\\\\"
        elif c == "\n":
            out += "\\n"
        elif c == "\r":
            out += "\\r"
        elif c == "\t":
            out += "\\t"
        elif c.byte_length() == 1 and Int(c.as_bytes()[0]) < 0x20:  # other control characters
            var b = Int(c.as_bytes()[0])
            out += "\\u00" + String("0123456789abcdef"[byte = b // 16]) + String("0123456789abcdef"[byte = b % 16])
        else:
            out += c
    return out + '"'


def view_to_json(v: View) -> String:
    var out = String("[")
    for i in range(len(v.nodes)):
        ref n = v.nodes[i]
        if i > 0:
            out += ","
        out += '{"kind":' + String(n.kind) + ',"text":' + json_str(n.text) + ',"msg":' + String(n.msg)
        out += ',"style":' + String(n.style) + ',"spacing":' + String(n.spacing) + ',"value":' + String(n.value)
        out += ',"hint":' + json_str(n.hint) + ',"msg2":' + String(n.msg2) + ',"size":' + String(n.size)
        out += ',"pad_v":' + String(n.pad_v) + ',"pad_h":' + String(n.pad_h) + ',"w":' + String(n.w) + ',"h":' + String(n.h)
        out += ',"min_w":' + String(n.min_w) + ',"max_w":' + String(n.max_w) + ',"grows":' + ("true" if n.grows else "false")
        out += ',"fills":' + ("true" if n.fills else "false") + ',"align_items":' + String(n.align_items)
        out += ',"justify_items":' + String(n.justify_items) + ',"name":' + json_str(n.name) + ',"tip":' + json_str(n.tip)
        out += ',"width_from_parent":' + ("true" if n.width_from_parent else "false") + ',"height_from_parent":' + ("true" if n.height_from_parent else "false")
        out += ',"x":' + String(n.x) + ',"y":' + String(n.y)
        out += ',"options":['
        for j in range(len(n.options)):
            if j > 0:
                out += ","
            out += json_str(n.options[j])
        out += '],"children":['
        for j in range(len(n.children)):
            if j > 0:
                out += ","
            out += String(n.children[j])
        out += "]}"
    return out + "]"


def diff_to_json(d: Diff, shown: View) -> String:
    if d.rebuild:
        return '{"rebuild":true,"nodes":' + view_to_json(shown) + "}"
    var out = String('{"rebuild":false,"patches":[')
    for i in range(len(d.patches)):
        ref p = d.patches[i]
        if i > 0:
            out += ","
        out += '{"op":' + String(p.op) + ',"node":' + String(p.node) + ',"text":' + json_str(p.text) + ',"number":' + String(p.number) + "}"
    return out + "]}"


struct WebSession[A: App](Movable):
    """One browser tab: the app, plus the pixels of the canvas frame last drawn."""

    var rt: Runtime[Self.A]
    var pixels: List[UInt32]

    def __init__(out self):
        self.rt = Runtime(Self.A())
        self.pixels = List[UInt32]()


def tab_at[A: App](handle: Int) -> Pointer[WebSession[A], MutUntrackedOrigin]:
    return Pointer[WebSession[A], MutUntrackedOrigin](unsafe_from_address=handle)


def session_at[A: App](handle: Int) -> Pointer[Runtime[A], MutUntrackedOrigin]:
    return Pointer(to=tab_at[A](handle)[].rt).unsafe_origin_cast[MutUntrackedOrigin]()


def web_init_shared[A: App]():
    """Builds the app's shared data once per server process (before any session)."""
    A.init_shared()


def web_new[A: App]() -> Int:
    """Starts one app session (one browser tab) and returns its handle."""
    var tab = alloc(Layout[WebSession[A]].single()).unsafe_leak()
    tab.unsafe_write(WebSession[A]())
    return Int(tab)


def web_title[A: App](handle: Int) -> String:
    return session_at[A](handle)[].app.title()


def web_theme_key[A: App](handle: Int) -> String:
    """The app's theme's key (Theme.key): the page restyles when it changes."""
    return session_at[A](handle)[].app.theme().key()


def web_theme[A: App](handle: Int) -> String:
    """The app's theme for the page, as five parts split by U+001F: its id, its body classes, its palette, fonts and
    corners as CSS variables (--o-page, --o-accent, --o-font, --o-radius-card…: what theme style sheets and widgets read),
    its style sheet (D-260), and its tokens as JSON for widgets' theme(el, tokens) (goal 34b)."""
    var t = session_at[A](handle)[].app.theme()
    var sheet = t.web_css + (look_web_css(t.look, "body." + t.id + " ") if t.id != "" else String(""))  # (the look's rules after the theme's own: hover and :focus rules stay more specific)
    var vars = (palette_css(t.palette) + tokens_css(t)) if t.id != "" else String("")
    return t.id + chr(31) + t.classes + chr(31) + vars + chr(31) + sheet + chr(31) + theme_tokens(t)


def web_logo[A: App](handle: Int) -> String:
    return session_at[A](handle)[].app.logo()


def web_view[A: App](handle: Int) -> String:
    return view_to_json(session_at[A](handle)[].shown)


def web_draw[A: App](handle: Int, node: Int, width: Int, height: Int, scale: Float64, still: Bool = False) -> String:
    """Paints canvas node `node` at width × height pixels. Returns
    {"address", "width", "height", "diff"}: where the RGBA pixels are (valid until the next
    call for this tab) and what else changed on screen."""
    var tab = tab_at[A](handle)
    var w = min(max(width, 1), 4096)
    var h = min(max(height, 1), 4096)
    if len(tab[].pixels) != w * h:
        tab[].pixels = List[UInt32](length=w * h, fill=0)
    var surface = Surface(Int(tab[].pixels.unsafe_ptr()), w, h, scale if scale > 0 else 1.0)
    surface.still = still  # (the page asked for reduced motion, or an agent wants the settled picture)
    var d = tab[].rt.draw(node, surface)
    return ('{"address":' + String(Int(tab[].pixels.unsafe_ptr())) + ',"width":' + String(w) + ',"height":' + String(h)
            + ',"again":' + ("true" if surface.again else "false") + ',"diff":' + diff_to_json(d, tab[].rt.shown) + "}")


def web_gesture[A: App](handle: Int, node: Int, kind: Int, x: Float64, y: Float64, dx: Float64, dy: Float64, zoom: Float64) -> String:
    var rt = session_at[A](handle)
    var d = rt[].gesture(node, kind, x, y, dx, dy, zoom)
    return diff_to_json(d, rt[].shown)


def web_key[A: App](handle: Int, node: Int, name: String, modifiers: Int) -> String:
    var rt = session_at[A](handle)
    var d = rt[].key(node, name, modifiers)
    return diff_to_json(d, rt[].shown)


def web_cancel[A: App](handle: Int, node: Int, text: String) -> String:
    var rt = session_at[A](handle)
    var d = rt[].cancel(node, text)
    return diff_to_json(d, rt[].shown)


def web_resize[A: App](handle: Int, width: Int, height: Int) -> String:
    """The page's viewport is width × height CSS pixels (on load, and when the window changes): App.resize."""
    var rt = session_at[A](handle)
    var d = rt[].resize(width, height)
    return diff_to_json(d, rt[].shown)


def web_appearance[A: App](handle: Int, dark: Bool) -> String:
    """The browser's colour scheme (prefers-color-scheme), on load and when it changes: App.appearance."""
    var rt = session_at[A](handle)
    var d = rt[].appearance(dark)
    return diff_to_json(d, rt[].shown)


def web_frame[A: App](handle: Int, node: Int, microseconds: Int) -> String:
    var rt = session_at[A](handle)
    var d = rt[].frame(node, microseconds)
    return diff_to_json(d, rt[].shown)


def web_event[A: App](handle: Int, node: Int, second: Bool, text: String, number: Int) -> String:
    """A control changed: look its message up in the current screen (like the native
    hosts do), run update(), and return what changed. Bad node → nothing happens."""
    var rt = session_at[A](handle)
    var e = control_event(rt[].shown, node, second, text, number)
    if e.message == 0:
        return '{"ignored":true}'
    var d = rt[].dispatch(e)
    return diff_to_json(d, rt[].shown)


def control_event(shown: View, node: Int, second: Bool, text: String, number: Int) -> Event:
    """The event a control of the shown screen sends (node, its second message or not, the text and number it reports);
    message 0: no such node, it doesn't listen, or a link with no href. An option's text and a link's href come from the
    screen, never from the sender (the web host, the agent link)."""
    if node < 0 or node >= len(shown.nodes):
        return Event(0, "", 0)
    ref n = shown.nodes[node]
    var message = n.msg2 if second else n.msg
    if message == 0:
        return Event(0, "", 0)
    var event_text = text
    if n.kind == DROPDOWN or n.kind == SEGMENTED or n.kind == RADIO or n.kind == TABS or n.kind == ALERT:
        # the option's text comes from the screen, not the browser
        event_text = n.options[number] if 0 <= number < len(n.options) else String("")
    elif n.kind == PARAGRAPH:  # a link's tap: its href from the screen (number = the run), never the browser's word
        event_text = link_href(n, number)
        if event_text == "":
            return Event(0, "", 0)
    return Event(message, event_text, number)


def web_widget_event[A: App](handle: Int, node: Int, name: String, payload: String) -> String:
    """Widget node `node` emitted `name` with `payload` (JSON): its on_event through update(); what changed."""
    var rt = session_at[A](handle)
    if not rt[].accepts_widget_event(node, name, payload):
        return '{"ignored":true}'
    var d = rt[].widget_event(node, name, payload)
    return diff_to_json(d, rt[].shown)


def web_reply[A: App](handle: Int, seq: Int, text: String, error: String) -> String:
    """A widget's answer to command `seq` (or why there's none) through update(); what changed."""
    var rt = session_at[A](handle)
    if not rt[].knows_reply(seq):
        return '{"ignored":true}'
    var d = rt[].reply(seq, text, error)
    return diff_to_json(d, rt[].shown)


def web_commands[A: App](handle: Int) -> String:
    """The widget commands the app asked for since the last call, as JSON: [{seq, tag, widget, name, args}]."""
    return commands_json(session_at[A](handle)[].take_commands())


def web_set_widget[A: App](handle: Int, tag: String, id: Int, field: String, value: String) -> Bool:
    """An agent's set (Runtime.set_widget): the widget's mojoui.set command, taken with the next web_commands."""
    return session_at[A](handle)[].set_widget(tag, id, field, value)


def web_assets[A: App]() -> String:
    """App.web_assets() as a JSON list of bundle names."""
    return assets_json(A.web_assets())


def web_poll[A: App](handle: Int) -> String:
    """The tab's effects (HTTP replies, timer ticks) that are due, through update(); what changed (web.py's clock
    thread calls it when web_wake_in said so)."""
    var rt = session_at[A](handle)
    var d = rt[].poll(now_ns() // 1000)
    return diff_to_json(d, rt[].shown)


def web_wake_in[A: App](handle: Int) -> Int:
    """Microseconds until web_poll has something to do (-1: nothing until the next event)."""
    return session_at[A](handle)[].wake_in(now_ns() // 1000)


def web_rows[A: App](handle: Int, node: Int, first: Int, count: Int) -> String:
    """JSON list of row texts first..first+count of a LazyList (asked for on demand)."""
    var rt = session_at[A](handle)
    if node < 0 or node >= len(rt[].shown.nodes) or rt[].shown.nodes[node].kind != LAZYLIST:
        return "[]"
    ref n = rt[].shown.nodes[node]
    var out = String("[")
    var last = min(first + count, n.value)
    for i in range(max(first, 0), last):
        if i > max(first, 0):
            out += ","
        out += json_str(rt[].app.row(n.msg2, i))
    return out + "]"


def web_describe[A: App](handle: Int, node: Int, first: Int, count: Int) -> String:
    """Canvas node `node`'s content as text (App.describe, D-163): "" for anything else."""
    var rt = session_at[A](handle)
    if node < 0 or node >= len(rt[].shown.nodes) or rt[].shown.nodes[node].kind != CANVAS:
        return ""
    return rt[].app.describe(rt[].shown.nodes[node].style, first, count)


def web_image[A: App](handle: Int, node: Int) -> String:
    """Where an image's RGBA pixels are: "address width height bytes" (valid until the next event)."""
    var rt = session_at[A](handle)
    if node < 0 or node >= len(rt[].shown.nodes) or rt[].shown.nodes[node].kind != IMAGE:
        return "0 0 0 0"
    ref n = rt[].shown.nodes[node]
    var nbytes = len(n.pixels) * 4
    return String(Int(n.pixels.unsafe_ptr())) + " " + String(n.spacing) + " " + String(n.size) + " " + String(nbytes)


def web_close[A: App](handle: Int):
    var tab = tab_at[A](handle)
    tab.unsafe_deinit_pointee()
    tab.unsafe_free()
