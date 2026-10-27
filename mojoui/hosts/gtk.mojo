# Linux host: draws a mojoui View with real GTK4 widgets (styled by libadwaita).
#
# Test mode (used by scripts/check): MOJOUI_TEST="tap:Greet;type:Your name=Ada;
# submit:Your name;toggle:Notifications;select:0=Large;slide:0=70" drives the
# real widgets through their normal APIs (so their real signals fire), then
# prints each widget's state as GTK reports it and quits. The window isn't
# shown unless MOJOUI_SHOT=<file.png> asks GTK to render it to a PNG.

from mojoui.look import look_gtk_css
from std.ffi import external_call, c_int, c_char, c_uint
from std.memory import Pointer
from std.memory.alloc import alloc, Layout

from mojoui.menus import items_text, CHECKED, DISABLED, DANGER
from mojoui.view import (
    CLIPBOARD, TABLE, ROUTE, DRAG, DROP, EMBED, WEBCOMP, PARAGRAPH, View, TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE,
    SEGMENTED, RADIO, TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, BOARD, MENUBAR, MENU, ITEM, DIALOG, TOAST, POPOVER, SECONDARY, PAN, ZOOM, TAP,
    START, CENTER, END, STRETCH, BETWEEN, AUTO, Node, CARD, CARD_WARN, CARD_GOOD,
    TITLE, HEADLINE, CAPTION, PROMINENT, DESTRUCTIVE, OVERLAY, PRESS, RELEASE, DOUBLE, SUBTLE, ICON_ONLY, ICON_ON, TOOL, TOOL_ON, TOOL_INLINE, TOOL_INLINE_ON, TOKEN, TOKEN_LIT, KEY, SHIFT, CTRL, ALT,
)
from mojoui.diff import Diff, Patch, SET_TEXT, SET_VALUE, SET_IMAGE, SET_PLACE, SET_SIZE, SET_TIP
from mojoui.app import App, Event, Runtime, ms
from mojoui.canvas import Surface, rgba
from mojoui.scene import Scene, OP_RECT, OP_CIRCLE, OP_LINE, OP_TEXT, OP_FILL, OP_CLIP, OP_UNCLIP, OP_IMAGE
from std.collections import Dict
from mojoui.icons_data import LUCIDE_NAMES, lucide_svg
from mojoui.theme import Palette, Theme, Look, hex_of, mix
from mojoui.embed import is_web_url
from mojoui.webcomponent import is_widget_tag
from mojoui.json import json_string
from mojoui.view import NO_MSG
from mojoui.hosts.gtk_webview import (
    WebViews, Inbound, webviews_at, start as webviews_start, new_view, send as webview_send, probe as webview_probe, drop as webview_drop,
    take_message, theme_message, IN_EVENT, IN_REPLY,
)
from mojoui.paragraph import pango_markup, link_href, runs_of
from mojoui.linebreak import css_breaks, plain_words, label_words
from std.math import log2
from std.time import perf_counter_ns, sleep

comptime G_APPLICATION_NON_UNIQUE = 32
comptime G_PRIORITY_DEFAULT = 0
comptime G_PRIORITY_DEFAULT_IDLE = 200
comptime HORIZONTAL = 0
comptime VERTICAL = 1
comptime ALIGN_CENTER = 3
comptime RTLD_DEFAULT = 0  # glibc
comptime NODE_KEY = "mojoui-node"
comptime DRAG_KEY = "mojoui-drag-source"  # a Draggable's box → its GtkDragSource
comptime DROP_KEY = "mojoui-drop-target"  # a DropTarget's box → its GtkDropTarget
comptime G_TYPE_STRING = 64  # G_TYPE_MAKE_FUNDAMENTAL(16)
comptime GDK_ACTION_COPY = 1


# ---------- small C helpers ----------

def c_str(addr: Int) -> String:
    """Copies a NUL-terminated C string into a Mojo String."""
    if addr == 0:
        return ""
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


def getenv(name: String) -> String:
    var n = name
    return c_str(external_call["getenv", Int](n.as_c_string_span()))


def is_set(name: String) -> Bool:
    """Whether an environment variable is set at all (even to "")."""
    var n = name
    return external_call["getenv", Int](n.as_c_string_span()) != 0


def ccall[T: RegisterPassable = Int, *A: AnyType](name: String, *args: *A) -> T:
    """Calls a C function found at run time, with this call's argument types.
    (For functions we need with several signatures, e.g. g_signal_connect_data.)"""
    var n = name
    var addr = external_call["dlsym", Int](RTLD_DEFAULT, n.as_c_string_span())
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def connect(obj: Int, signal: String, callback: def(Int, Int) thin abi("C"), data: Int):
    var s = signal
    _ = ccall("g_signal_connect_data", obj, s.as_c_string_span(), callback, data, 0, 0)


def connect3(obj: Int, signal: String, callback: def(Int, Int, Int) thin abi("C"), data: Int):
    var s = signal
    _ = ccall("g_signal_connect_data", obj, s.as_c_string_span(), callback, data, 0, 0)


def connect_any[F: AnyType](obj: Int, signal: String, callback: F, data: Int):
    """g_signal_connect for a callback of any C signature (doubles, return values…)."""
    var s = signal
    _ = ccall("g_signal_connect_data", obj, s.as_c_string_span(), callback, data, 0, 0)


def remove_class(widget: Int, name: String):
    var n = name
    external_call["gtk_widget_remove_css_class", NoneType](widget, n.as_c_string_span())


def set_tone(widget: Int, tone: Int):
    """A label's tone class (Text(…).tone()): one of mui-tone-warn/good/strong/accent, or none."""
    var names: List[String] = ["", "mui-tone-warn", "mui-tone-good", "mui-tone-strong", "mui-tone-accent"]
    var native: List[String] = ["", "warning", "success", "", "accent"]  # (libadwaita's own colours: the look with no theme)
    for k in range(1, 5):
        remove_class(widget, names[k])
        if native[k] != "":
            remove_class(widget, native[k])
    if 1 <= tone <= 4:
        add_class(widget, names[tone])
        if native[tone] != "":
            add_class(widget, native[tone])


def tone_of(widget: Int) -> String:
    """The tone a label shows (for the test report): "warn", "good", "strong", "accent" or ""."""
    var names: List[String] = ["warn", "good", "strong", "accent"]
    for n in names:
        var cls = "mui-tone-" + n
        if external_call["gtk_widget_has_css_class", c_int](widget, cls.as_c_string_span()) != 0:
            return n
    return ""


def add_class(widget: Int, name: String):
    var n = name
    external_call["gtk_widget_add_css_class", NoneType](widget, n.as_c_string_span())


def mark_button_labels(widget: Int):
    """A button's own labels (its title, AdwButtonContent's, a tool's) marked mui-in-button: a role's type around the
    button doesn't reach them, as on the web, where a role's words rule is for its .text views, not a button's title
    (the console's text action took its sidebar head's mono and tracking: 102 wide for 76, D-511)."""
    var c = external_call["gtk_widget_get_first_child", Int](widget)
    while c != 0:
        if c_str(external_call["gtk_widget_get_css_name", Int](c)) == "label":
            add_class(c, "mui-in-button")
        mark_button_labels(c)
        c = external_call["gtk_widget_get_next_sibling", Int](c)


def app_data(name: String) -> Int:
    var key = name
    return external_call["g_object_get_data", Int](external_call["g_application_get_default", Int](), key.as_c_string_span())


def set_app_data(name: String, value: Int):
    var key = name
    external_call["g_object_set_data", NoneType](external_call["g_application_get_default", Int](), key.as_c_string_span(), value)


def set_node(widget: Int, node: Int):
    """Ties a widget to node `node` through the node's id, which stays the same while a partial rebuild renumbers
    the nodes around it (so the widgets that stay need no new data)."""
    var key = String(NODE_KEY)
    var id = -1
    if node >= 0 and node < app_data("mojoui-ids-n"):
        id = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=app_data("mojoui-ids")).unsafe_offset(node)[]
    external_call["g_object_set_data", NoneType](widget, key.as_c_string_span(), id + 1)  # +1: never NULL


def get_node(widget: Int) -> Int:
    """The node a widget stands for now (-1: none, or gone)."""
    var key = String(NODE_KEY)
    var id = external_call["g_object_get_data", Int](widget, key.as_c_string_span()) - 1
    if id < 0 or id >= app_data("mojoui-id-node-n"):
        return -1
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=app_data("mojoui-id-node")).unsafe_offset(id)[]


def set_busy(on: Bool):
    """Marks that the host itself is changing widgets, so their signals are ignored.

    Kept on the GApplication (a real C call), not in a Mojo field: the signals
    arrive re-entrantly while a `mut self` method runs, and the compiler may
    assume nothing else reads that field in between.
    """
    var key = String("mojoui-busy")
    var app = external_call["g_application_get_default", Int]()
    external_call["g_object_set_data", NoneType](app, key.as_c_string_span(), 1 if on else 0)


def busy() -> Bool:
    var key = String("mojoui-busy")
    var app = external_call["g_application_get_default", Int]()
    return external_call["g_object_get_data", Int](app, key.as_c_string_span()) != 0


def texture(pixels: List[UInt32], w: Int, h: Int) -> Int:
    """A GdkMemoryTexture holding a copy of the RGBA pixels."""
    comptime GDK_MEMORY_R8G8B8A8 = 5
    var n = len(pixels) * 4
    var bytes = external_call["g_bytes_new", Int](Int(pixels.unsafe_ptr()), n)  # copies
    var tex = external_call["gdk_memory_texture_new", Int](c_int(w), c_int(h), c_int(GDK_MEMORY_R8G8B8A8), bytes, w * 4)
    external_call["g_bytes_unref", NoneType](bytes)
    return tex


def width(widget: Int, w: Int):
    """A control's default width (a GTK minimum). build() skips it when the app sizes the view."""
    external_call["gtk_widget_set_size_request", NoneType](widget, c_int(w), c_int(-1))


comptime INDEX_KEY = "mojoui-index"


def set_index(obj: Int, index: Int):
    var key = String(INDEX_KEY)
    external_call["g_object_set_data", NoneType](obj, key.as_c_string_span(), index + 1)


def get_index(obj: Int) -> Int:
    var key = String(INDEX_KEY)
    return external_call["g_object_get_data", Int](obj, key.as_c_string_span()) - 1


def count_up(name: String):
    """A counter kept on the GApplication (safe to bump from re-entrant callbacks)."""
    var key = name
    var app = external_call["g_application_get_default", Int]()
    var n = external_call["g_object_get_data", Int](app, key.as_c_string_span())
    external_call["g_object_set_data", NoneType](app, key.as_c_string_span(), n + 1)


def counter(name: String) -> Int:
    var key = name
    var app = external_call["g_application_get_default", Int]()
    return external_call["g_object_get_data", Int](app, key.as_c_string_span())


def gtk_icon(name: String) -> String:
    """mojoui icon names → Adwaita symbolic icons."""
    if name == "star": return "starred-symbolic"
    if name == "trash": return "user-trash-symbolic"
    if name == "gear": return "emblem-system-symbolic"
    if name == "plus": return "list-add-symbolic"
    if name == "check": return "object-select-symbolic"
    if name == "calendar": return "x-office-calendar-symbolic"
    if name == "search": return "system-search-symbolic"
    if name == "heart": return "emblem-favorite-symbolic"
    if name == "home": return "go-home-symbolic"
    if name == "person": return "avatar-default-symbolic"
    if name == "travel": return "airplane-mode-symbolic"
    if name == "food": return "emoji-food-symbolic"
    if name == "fun": return "emoji-activities-symbolic"
    if name == "chart": return "x-office-spreadsheet-symbolic"
    if name == "app-logo": return "mojoui-app-logo"  # (the app's own mark: App.logo, installed by install_icons)
    for n in materialize[LUCIDE_NAMES]():
        if n == name:
            return "mojoui-" + name  # the same Lucide SVG as the web (written by install_icons)
    return "image-missing-symbolic"


def install_icons(theme: Theme, logo: String):
    """Writes the Lucide icons as SVG files in the theme's ink (and its ink on filled, accent buttons) to a cache folder
    and adds it to the display's icon theme: icons named "mojoui-<name>" and "mojoui-<name>-light"."""
    var ink = hex_of(theme.icon_ink)
    var on_accent = hex_of(theme.icon_on_accent)
    var base = c_str(external_call["g_get_user_cache_dir", Int]()) + "/mojoui/icons-" + (theme.id if theme.id != "" else "1") + "-" + String(ink[byte=1:]) + String(on_accent[byte=1:])
    _ = external_call["g_mkdir_with_parents", c_int](base.as_c_string_span(), c_int(0o755))
    for n in materialize[LUCIDE_NAMES]():
        var svg = lucide_svg(n)
        for variant in [("", ink), ("-light", on_accent)]:
            var path = base + "/mojoui-" + n + variant[0] + ".svg"
            try:
                with open(path, "w") as f:
                    f.write(svg.replace("currentColor", variant[1]))
            except:
                pass
    if logo != "":  # the app's own mark, in its own colours (not recoloured: "app-logo", not a symbolic icon)
        try:
            with open(base + "/mojoui-app-logo.svg", "w") as f:
                f.write(logo)
        except:
            pass
    var display = external_call["gdk_display_get_default", Int]()
    var icon_theme = external_call["gtk_icon_theme_get_for_display", Int](display)
    external_call["gtk_icon_theme_add_search_path", NoneType](icon_theme, base.as_c_string_span())


def mojo_icon(gtk_name: String) -> String:
    if gtk_name.startswith("mojoui-"):
        return String(gtk_name[byte=7:])
    for n in ["star", "trash", "gear", "plus", "check", "calendar", "search", "heart", "home", "person", "travel", "food", "fun", "chart"]:
        if gtk_icon(n) == gtk_name:
            return n
    return "?"


def parse_date(text: String) -> Tuple[Int, Int, Int]:
    """ "YYYY-MM-DD" → (year, month, day); (2000, 1, 1) if it doesn't parse."""
    try:
        var parts = text.split("-")
        if len(parts) == 3:
            return (Int(String(parts[0])), Int(String(parts[1])), Int(String(parts[2])))
    except:
        pass
    return (2000, 1, 1)


def one_decimal(v: Float32) -> String:
    var tenths = Int(Float64(v) * 10 + (0.5 if v >= 0 else -0.5))
    var sign = "-" if tenths < 0 else ""
    tenths = abs(tenths)
    return sign + String(tenths // 10) + "." + String(tenths % 10)


def two(n: Int) -> String:
    return ("0" if n < 10 else "") + String(n)


def calendar_date(cal: Int) -> String:
    var dt = external_call["gtk_calendar_get_date", Int](cal)
    var y = Int(external_call["g_date_time_get_year", c_int](dt))
    var m = Int(external_call["g_date_time_get_month", c_int](dt))
    var d = Int(external_call["g_date_time_get_day_of_month", c_int](dt))
    external_call["g_date_time_unref", NoneType](dt)
    return String(y) + "-" + two(m) + "-" + two(d)


def calendar_select(cal: Int, text: String):
    var ymd = parse_date(text)
    var dt = external_call["g_date_time_new_local", Int](c_int(ymd[0]), c_int(ymd[1]), c_int(ymd[2]), c_int(0), c_int(0), Float64(0))
    external_call["gtk_calendar_select_day", NoneType](cal, dt)
    external_call["g_date_time_unref", NoneType](dt)


def buffer_text(buffer: Int) -> String:
    """All the text in a GtkTextBuffer."""
    var start = List[Int](length=16, fill=0)  # GtkTextIter is ~80 bytes; 128 is plenty
    var end = List[Int](length=16, fill=0)
    external_call["gtk_text_buffer_get_bounds", NoneType](buffer, Int(start.unsafe_ptr()), Int(end.unsafe_ptr()))
    var raw = external_call["gtk_text_buffer_get_text", Int](buffer, Int(start.unsafe_ptr()), Int(end.unsafe_ptr()), c_int(0))
    # Keep the iterator buffers alive until here: Mojo frees values right after their
    # last use, and turning a pointer into an Int doesn't count as a use.
    _ = len(start)
    _ = len(end)
    var text = c_str(raw)
    external_call["g_free", NoneType](raw)
    return text


def fresh_rows(list: Int, count: Int):
    """Gives a GtkListView a new model of `count` placeholder items, so every visible
    row is bound again (asking the app for its text); the scroll position is kept."""
    var model = external_call["gtk_string_list_new", Int](0)
    var empty = String("")
    for _ in range(count):
        external_call["gtk_string_list_append", NoneType](model, empty.as_c_string_span())
    var selection = external_call["gtk_list_view_get_model", Int](list)
    external_call["gtk_no_selection_set_model", NoneType](selection, model)
    external_call["g_object_unref", NoneType](model)


def refresh_rows(list: Int, count: Int):
    """Re-binds the rows on screen: fresh items over the range of rows GTK drew since the
    last refresh (cheap; keeps the scroll position and row widgets), or a new model if the
    row count changed."""
    var selection = external_call["gtk_list_view_get_model", Int](list)
    var model = external_call["gtk_no_selection_get_model", Int](selection)
    if Int(external_call["g_list_model_get_n_items", c_uint](model)) != count:
        fresh_rows(list, count)
        return
    var app = external_call["g_application_get_default", Int]()
    var lo = String("mojoui-bound-lo")
    var hi = String("mojoui-bound-hi")
    var first = external_call["g_object_get_data", Int](app, lo.as_c_string_span()) - 1
    var last = external_call["g_object_get_data", Int](app, hi.as_c_string_span()) - 1
    external_call["g_object_set_data", NoneType](app, lo.as_c_string_span(), 0)  # start tracking afresh:
    external_call["g_object_set_data", NoneType](app, hi.as_c_string_span(), 0)  # the splice re-binds what's shown
    var n = min(last + 1, count) - max(first, 0)
    if first < 0 or n <= 0:
        return
    first = max(first, 0)
    var empty = String("")
    var additions = List[Int](length=n + 1, fill=Int(empty.unsafe_ptr()))  # n pointers to "" + NULL
    additions[n] = 0
    _ = empty.as_c_string_span()  # make sure "" is NUL-terminated
    external_call["gtk_string_list_splice", NoneType](model, c_uint(first), c_uint(n), Int(additions.unsafe_ptr()))
    _ = len(additions)  # keep the pointer array alive past the call
    _ = empty.byte_length()


def spacer(orientation: Int) -> Int:
    """An empty widget that soaks up free space (for justify)."""
    var s = external_call["gtk_box_new", Int](c_int(orientation), c_int(0))
    if orientation == HORIZONTAL:
        external_call["gtk_widget_set_hexpand", NoneType](s, c_int(1))
    else:
        external_call["gtk_widget_set_vexpand", NoneType](s, c_int(1))
    return s


def escape_newlines(text: String) -> String:
    return text.replace("\n", "\\n")


# ---------- the host ----------

struct GtkCanvas(Copyable, Movable):
    """One Canvas on screen: its GtkPicture, gesture controllers and the pixels last drawn."""

    var node: Int
    var widget: Int  # GtkPicture showing the pixels as a texture
    var drag: Int  # GtkGestureDrag
    var scroll: Int  # GtkEventControllerScroll
    var click: Int  # GtkGestureClick
    var secondary: Int  # GtkGestureClick for the right button (SECONDARY: a context menu)
    var keys: Int  # GtkEventControllerKey (the canvas takes focus when pressed)
    var motion_ctl: Int  # GtkEventControllerMotion
    var pinch_ctl: Int  # GtkGestureZoom
    var pixels: List[UInt32]
    var wpx: Int
    var hpx: Int
    var scale: Float64
    var drawn: Int  # the version last drawn (-1: none yet)
    var draws: Int
    var draw_ms: Float64  # how long the last draw took (paint + upload), for GLIDE
    var paint_ms: Float64  # of which the app's drawing (and the screen catching up)
    var upload_ms: Float64  # of which handing the pixels to GTK (a texture, a paintable)
    var frames: Int  # frame events sent
    var first_us: Int  # frame-clock time of the first and last frame event (for FRAMES)
    var last_us: Int
    var drag_x: Float64  # the drag's offset so far
    var drag_y: Float64
    var start_x: Float64  # where the drag started (canvas points)
    var start_y: Float64
    var ptr_x: Float64  # where the pointer is (-1: unknown)
    var ptr_y: Float64
    var pinch: Float64  # the pinch's scale so far
    var moved: Bool  # the current press became a drag (so it's not a tap)
    var armed: Bool  # a tick callback is running (only while frames, a redraw or a resize may be due)
    var quiet: Int  # idle ticks in a row (layout can change after ticks, so wait before stopping)
    var spare: Scene  # the list before that, recycled for the next frame (its memory, not its content)
    var prev: Scene  # the display list last drawn (MOJOUI_SCENE): a layer that comes again unchanged keeps its nodes
    var layer_nodes: List[Int]  # the GskRenderNode built for each of prev's layers

    def __init__(out self, node: Int, widget: Int):
        self.node = node
        self.widget = widget
        self.drag = 0
        self.scroll = 0
        self.click = 0
        self.secondary = 0
        self.keys = 0
        self.motion_ctl = 0
        self.pinch_ctl = 0
        self.pixels = List[UInt32]()
        self.wpx = 0
        self.hpx = 0
        self.scale = 1
        self.drawn = -1
        self.draws = 0
        self.draw_ms = 0
        self.paint_ms = 0
        self.upload_ms = 0
        self.frames = 0
        self.first_us = 0
        self.last_us = 0
        self.drag_x = 0
        self.drag_y = 0
        self.start_x = 0
        self.start_y = 0
        self.ptr_x = -1
        self.ptr_y = -1
        self.pinch = 1
        self.moved = False
        self.armed = False
        self.quiet = 0
        self.prev = Scene(0, 0, 1)
        self.spare = Scene(0, 0, 1)
        self.layer_nodes = List[Int]()


struct BoardChild(Copyable, Movable):
    """One object on a Board: dragged by its header (move) or its bottom-right corner (resize)."""

    var board: Int  # the Board node
    var node: Int  # the child node
    var index: Int  # its index among the board's children
    var widget: Int
    var fixed: Int  # the GtkFixed holding it
    var drag: Int  # GtkGestureDrag
    var active: Bool
    var resizing: Bool

    def __init__(out self, board: Int, node: Int, index: Int, widget: Int, fixed: Int, drag: Int):
        self.board = board
        self.node = node
        self.index = index
        self.widget = widget
        self.fixed = fixed
        self.drag = drag
        self.active = False
        self.resizing = False


struct GtkHost[A: App](Movable):
    var rt: Runtime[Self.A]
    var canvases: List[GtkCanvas]
    var boards: List[BoardChild]
    var window_w: Int  # the window's width in points (boards narrower than 720 become lists)
    var board_list: Bool  # the last build showed boards as lists
    var board_scrollers: List[Tuple[Int, Int]]  # (Board node, its GtkScrolledWindow)
    var board_drags: List[Tuple[Int, Int]]  # (Board node, its drag gesture): a Board whose objects all change keeps it
    var revealed: Int  # the last Board reveal token scrolled to (Board's value)
    var clip_version: Int  # the Clipboard view's version last copied
    var embed_version: Int  # the WebFrame's version last opened in the browser
    var paint_t0: Int  # the frame clock's before-paint time (ns), and every frame's paint phase since bench started (ms)
    var frame_paints: List[Float64]
    var frame_times: List[Int]  # when each frame was painted (ns): the intervals between them say whether frames were on time
    var key_draws: Int  # draws of canvases that take keys (the grid), across rebuilds: GLIDE counts them
    var key_draw_ms: Float64
    var clip_text: String  # (tests print it: the clipboard itself is asynchronous)
    var reveal_pending: Int  # a Board node waiting for its layout to scroll a child into view, or -1
    var window: Int
    var widgets: List[Int]  # the GTK widget drawn for each node of rt.shown
    var outers: List[Int]  # what each node's widget sits in its parent as (the widget, or a clamp around it)
    var kinds: List[Int]  # each shown node's kind (a partial rebuild closes what went: dialogs, popovers)
    var ids: List[Int]  # each shown node's id (set_node stores ids: they survive renumbering)
    var id_node: List[Int]  # id → the node it is now (-1: gone)
    var content_w: Int  # the content area's size last told to the app (App.resize)
    var content_h: Int
    var echo_node: Int  # the field whose event the app just answered (-1: none), and the text it sent
    var echo_text: String
    var release_node: Int  # a canvas whose drag ended while the host was busy (-1: none): it gets its RELEASE after
    var release_x: Float64
    var release_y: Float64
    var pending: Diff  # a partial rebuild waiting for the next idle turn
    var has_pending: Bool
    var partial_ok: Bool
    var scene_mode: Bool  # (MOJOUI_SCENE=0 turns it off) canvases that record a display list are drawn by GTK's renderer (goal 26)
    var layouts: Dict[String, Int]  # PangoLayouts by text, face and size (an index into the lists below), kept across frames
    var layout_w: List[Float64]  # each layout's width and baseline (pixels), measured once
    var layout_base: List[Float64]
    var key_suffix: String  # the last text's face, size and colour as a key suffix (and what it was made from)
    var key_weight: Int
    var key_size: Float64
    var key_color: UInt32
    var key_slant: Float64
    var layout_nodes: List[Int]  # each one's text as a render node, built once (its colour is part of the key)
    var pango: Int  # the PangoContext text is laid out in
    var scratch: List[Float32]  # GdkRGBA, graphene rects and points, GskRoundedRect handed to GTK by address
    var nodes_built: Int  # layers built into render nodes, and layers reused untouched (bench reports them)
    var nodes_reused: Int
    var cells_built: Int  # the "cells" layer built into nodes (not reused), and pixel textures handed to GTK: bench reports them
    var uploads: Int
    var new_layouts: Int  # text laid out for the first time, and how long that took (ns): the replay's own trace
    var new_layout_ns: Int
    var dialog: Int  # the open alert dialog, if any
    var popovers: List[Int]  # context-menu popovers parented to anchors (unparented at the next rebuild)
    var popups: List[Int]  # popovers to pop up once the new screen is in the window
    var shortcut_keys: Int  # the window's key controller: menu shortcuts (Ctrl+S) from anywhere
    var toast_overlay: Int  # AdwToastOverlay around the screen (toasts float over it)
    var page: Int  # GtkScrolledWindow inside it: a screen taller than the window scrolls, as a web page does
    var toast: Int  # the toast showing, if any (kept across rebuilds while its node stays)
    var toast_text: String
    var toast_claimed: Bool  # the new screen still has the toast's node
    var skin_provider: Int  # the theme's CSS provider (replaced when App.theme() changes: Settings → Appearance, a mode's tint)
    var skin_key: String  # the theme that provider is for (Theme.key)
    var skin_classes: String  # the CSS classes it put on the window
    var dark_told: Int  # what App.appearance last said (1 dark, 0 light, -1 not yet): only a change is told again
    var forcing_scheme: Bool  # set while the host itself changes light/dark (a theme forcing one): not the person's change
    var icons_key: String  # the ink the icons were written in
    var fonts: Bool  # the app's own fonts (Inter, JetBrains Mono) were handed to fontconfig
    var css: Int  # one GtkCssProvider for padding classes
    var css_rules: String
    var one_line: List[String]  # the look's roles whose words stay on one line, cut with an ellipsis
    var breaks_words: List[String]  # the look's roles whose long words break anywhere (PANGO_WRAP_WORD_CHAR)
    var look: Look  # the theme's look (a Paragraph's runs take their roles' type from it, as Pango markup)
    var gap_roles: List[String]  # the look's roles with a column gap of their own (a grid's: Surface.column_gap), and
    var gap_cols: List[Int]  # that gap
    var focus: Int  # text field to keep focused across the next rebuild (-1: none)
    var key_node: Int  # the canvas node that had the keyboard last (it gets it back when an in-place editor closes)
    var editor_keys: Int  # the in-place editor's key controller (test steps press Escape through it)
    var editor_open: Bool  # the last build showed an in-place editor
    var picker_node: Int  # the FilePicker whose dialog is open
    var editor_node: Int  # (its node there)
    var fx_source: Int  # the GLib timeout that next polls the runtime's effects (HTTP replies, timers; 0: none)
    var fx_due: Int  # when it fires (µs, g_get_monotonic_time)
    var webviews: Int  # the WebComponents' WebKitGTK views (mojoui/hosts/gtk_webview.mojo), on the heap: its address
    var webview_focus: Int  # a view that had the keyboard when a rebuild moved it (it gets it back), or 0

    def __init__(out self, var app: Self.A):
        self.rt = Runtime(app^)
        self.rt.trace = getenv("MOJOUI_TRACE") != ""
        self.partial_ok = getenv("MOJOUI_NO_PARTIAL") == ""
        self.scene_mode = getenv("MOJOUI_SCENE") != "0"  # (the default since goal 27, D-261; 0: the pixel path)
        self.layouts = Dict[String, Int]()
        self.layout_w = List[Float64]()
        self.layout_base = List[Float64]()
        self.layout_nodes = List[Int]()
        self.key_suffix = ""
        self.key_weight = -1
        self.key_size = -1
        self.key_color = 0
        self.key_slant = 0
        self.pango = 0
        self.scratch = List[Float32](length=32, fill=0)
        self.nodes_built = 0
        self.nodes_reused = 0
        self.new_layouts = 0
        self.new_layout_ns = 0
        self.cells_built = 0
        self.uploads = 0  # (MOJOUI_NO_PARTIAL=1: every shape change rebuilds the window, to compare)
        self.canvases = List[GtkCanvas]()
        self.boards = List[BoardChild]()
        self.window_w = 0
        self.board_list = False
        self.board_scrollers = List[Tuple[Int, Int]]()
        self.board_drags = List[Tuple[Int, Int]]()
        self.revealed = 0
        self.reveal_pending = -1
        self.clip_version = 0
        self.embed_version = 0
        self.key_draws = 0
        self.paint_t0 = 0
        self.frame_paints = List[Float64]()
        self.frame_times = List[Int]()
        self.key_draw_ms = 0
        self.clip_text = ""
        self.window = 0
        self.widgets = List[Int]()
        self.outers = List[Int]()
        self.kinds = List[Int]()
        self.ids = List[Int]()
        self.id_node = List[Int]()
        self.content_w = 0
        self.content_h = 0
        self.echo_node = -1
        self.echo_text = ""
        self.release_node = -1
        self.release_x = 0
        self.release_y = 0
        self.pending = Diff(False, List[Patch]())
        self.has_pending = False
        self.dialog = 0
        self.popovers = List[Int]()
        self.popups = List[Int]()
        self.shortcut_keys = 0
        self.toast_overlay = 0
        self.page = 0
        self.toast = 0
        self.toast_text = ""
        self.toast_claimed = False
        self.skin_provider = 0
        self.skin_key = "?"
        self.skin_classes = ""
        self.forcing_scheme = False
        self.dark_told = -1
        self.icons_key = ""
        self.fonts = False
        self.css = 0
        self.css_rules = ""
        self.one_line = List[String]()
        self.look = Look.none()
        self.breaks_words = List[String]()
        self.gap_roles = List[String]()
        self.gap_cols = List[Int]()
        self.focus = -1
        self.key_node = -1
        self.editor_keys = 0
        self.editor_open = False
        self.picker_node = -1
        self.editor_node = -1
        self.fx_source = 0
        self.fx_due = 0
        var wv = alloc(Layout[WebViews].single()).unsafe_leak()  # (lives as long as the window: WebKit's callbacks hold its address)
        wv.unsafe_write(WebViews())
        self.webviews = Int(wv)
        self.webview_focus = 0

    def schedule_effects(mut self, self_addr: Int):
        """Arms one GLib timeout for when the runtime next has something to hand over (a reply, a timer's tick):
        Runtime.wake_in. An earlier need replaces a later timeout; nothing to wait for arms nothing."""
        var now = Int(external_call["g_get_monotonic_time", Int64]())
        var w = self.rt.wake_in(now)
        if w < 0:
            return
        var due = now + w
        if self.fx_source != 0:
            if self.fx_due <= due:
                return
            _ = external_call["g_source_remove", c_int](c_uint(self.fx_source))
        self.fx_due = due
        # A timer's tick at the default priority (they're far apart, and late ticks are wrong ticks); the few-ms polls
        # for replies below GTK's redraw (120), so they never starve the frames (D-323)
        var prio = G_PRIORITY_DEFAULT if self.rt.timer_wake_in(now) == w else G_PRIORITY_DEFAULT_IDLE
        self.fx_source = Int(external_call["g_timeout_add_full", c_uint](c_int(prio), c_uint((w + 999) // 1000), on_effects[Self.A], self_addr, Int(0)))

    def padding_class(mut self, v: Int, h: Int) -> String:
        """A CSS class giving `v`/`h` padding (GTK has no padding setter; CSS does it)."""
        return self.layout_class("mui-p-" + String(v) + "-" + String(h), "padding: " + String(v) + "px " + String(h) + "px;")

    def layout_class(mut self, name: String, body: String) -> String:
        """A CSS class with layout-only rules (sizes, padding: never colours, which are the theme's), loaded once."""
        if ("." + name + " ") not in self.css_rules:
            if self.css == 0:
                self.css = external_call["gtk_css_provider_new", Int]()
                var display = external_call["gdk_display_get_default", Int]()
                external_call["gtk_style_context_add_provider_for_display", NoneType](display, self.css, c_uint(800))
            self.css_rules += "." + name + " { " + body + " }\n"
            var rules = self.css_rules
            external_call["gtk_css_provider_load_from_string", NoneType](self.css, rules.as_c_string_span())
        return name

    def apply_layout(mut self, i: Int, w: Int) -> Int:
        """Maps node i's own layout settings onto its GTK widget; returns what goes into the parent."""
        var node = self.rt.shown.nodes[i].copy()
        if node.pad_v != 0 or node.pad_h != 0:
            add_class(w, self.padding_class(node.pad_v, node.pad_h))
        if node.name != "":  # a tagged view can be styled by the design's CSS (.mui-tag-toolbar)
            add_class(w, "mui-tag-" + node.name)
            if node.kind == TEXT and node.name in self.one_line:  # (the look's one-line words: cut with an ellipsis, never wrapped)
                external_call["gtk_label_set_wrap", NoneType](w, c_int(0))
                external_call["gtk_label_set_ellipsize", NoneType](w, c_int(3))  # PANGO_ELLIPSIZE_END
                external_call["gtk_label_set_xalign", NoneType](w, Float32(0))
            if self.ends_row(node.name):  # (the role sits at its row's end, the free room before it: the web's margin-left auto)
                external_call["gtk_widget_set_hexpand", NoneType](w, c_int(1))
                external_call["gtk_widget_set_halign", NoneType](w, c_int(2))  # GTK_ALIGN_END
            if node.kind == TEXT and node.name in self.breaks_words:  # (a long word breaks anywhere, as the web's overflow-wrap: anywhere)
                external_call["gtk_label_set_wrap_mode", NoneType](w, c_int(2))  # PANGO_WRAP_WORD_CHAR
                external_call["gtk_label_set_natural_wrap_mode", NoneType](w, c_int(0))  # (INHERIT: one-line naturals with char wrapping made boxes ask for more height than their natural)
                external_call["gtk_label_set_xalign", NoneType](w, Float32(0))
        if node.tip != "":
            var tip = node.tip
            external_call["gtk_widget_set_tooltip_text", NoneType](w, tip.as_c_string_span())
        var want_w = max(node.w, node.min_w)
        if want_w != 0 or node.h != 0:
            external_call["gtk_widget_set_size_request", NoneType](w, c_int(want_w if want_w != 0 else -1), c_int(node.h if node.h != 0 else -1))
        # GTK size requests are minimums; AdwClamp caps the width: at max_w, or exactly at a
        # fixed width (so a fixed-width view never grows past it, as on the other hosts).
        if node.h != 0 and node.kind == BUTTON:  # a button given a height is that high, padding and all (the look's mui-fixed-h)
            add_class(w, "mui-fixed-h")
        if node.w != 0:  # a fixed width never takes spare room (GTK passes children's expand up)
            external_call["gtk_widget_set_hexpand", NoneType](w, c_int(0))
        if node.h != 0:
            external_call["gtk_widget_set_vexpand", NoneType](w, c_int(0))
        var cap = node.max_w if node.max_w != 0 else node.w
        if cap == 0 and node.kind != TEXT and self.measured(node):
            cap = UNMEASURED  # (a measured box or paragraph, as the web's max-width in ch: fit_measures sets its clamp to the measure, D-524, D-525)
        if cap != 0:
            var clamp = external_call["adw_clamp_new", Int]()
            external_call["adw_clamp_set_maximum_size", NoneType](clamp, c_int(cap))
            external_call["adw_clamp_set_tightening_threshold", NoneType](clamp, c_int(cap))
            external_call["adw_clamp_set_child", NoneType](clamp, w)
            return clamp
        return w

    def regrid(mut self, j: Int, kept: List[Int], self_addr: Int) -> Int:
        """A grid whose children changed: the ones that stay move to their new cells (never taken out, so they don't
        arrive again), the ones that went are removed, new ones are built and attached. Returns how many were built."""
        var grid = self.widgets[j]
        var cols = max(self.rt.shown.nodes[j].value, 1)
        var want = List[Int]()
        var built = 0
        var children = self.rt.shown.nodes[j].children.copy()
        for c in children:
            want.append(self.outers[c] if kept[c] >= 0 else 0)
        var cur = external_call["gtk_widget_get_first_child", Int](grid)
        while cur != 0:
            var next = external_call["gtk_widget_get_next_sibling", Int](cur)
            if cur not in want:
                external_call["gtk_grid_remove", NoneType](grid, cur)
            cur = next
        var layout = external_call["gtk_widget_get_layout_manager", Int](grid)
        for k in range(len(children)):
            if want[k] != 0:
                var lc = external_call["gtk_layout_manager_get_layout_child", Int](layout, want[k])
                external_call["gtk_grid_layout_child_set_column", NoneType](lc, c_int(k % cols))
                external_call["gtk_grid_layout_child_set_row", NoneType](lc, c_int(k // cols))
            else:
                var child = self.build(children[k], self_addr)
                self.place_in_grid(j, children[k], child)
                external_call["gtk_grid_attach", NoneType](grid, child, c_int(k % cols), c_int(k // cols), c_int(1), c_int(1))
                built += 1
        return built

    def column_gap(self, role: String, spacing: Int) -> Int:
        """A grid's column gap: its role's own (Surface.column_gap, D-495), else its spacing."""
        for g in range(len(self.gap_roles)):
            if self.gap_roles[g] == role:
                return self.gap_cols[g]
        return spacing

    def place_in_grid(self, grid: Int, c: Int, child: Int):
        """A fitted grid's item (style 1) from its start, centred down: the web's justify-items: start, align-items:
        center (a key's or a value's box its words' width, not the column's, D-495). An item told to fill fills."""
        if self.rt.shown.nodes[grid].style != 1:
            return
        if not self.rt.shown.nodes[c].fills:
            external_call["gtk_widget_set_halign", NoneType](child, c_int(1))
        external_call["gtk_widget_set_valign", NoneType](child, c_int(3))

    def board_drag(self, board: Int) -> Bool:
        """Whether Board node `board` (current numbering) has its drag gesture on record."""
        for bd in self.board_drags:
            if bd[0] == board:
                return True
        return False

    def reboard(mut self, j: Int, kept: List[Int], self_addr: Int) -> Int:
        """A Board whose objects changed (an in-place editor opening, a chart added): the objects that stay stay put
        (the grid keeps its canvas, its keyboard and its drag), the ones that went are removed, new ones are put
        where they say. Returns how many were built."""
        var fixed = self.widgets[j]
        var drag = 0
        for bd in self.board_drags:
            if bd[0] == j:
                drag = bd[1]
        var children = self.rt.shown.nodes[j].children.copy()
        var want = List[Int]()
        for c in children:
            want.append(self.outers[c] if kept[c] >= 0 else 0)
        var cur = external_call["gtk_widget_get_first_child", Int](fixed)
        while cur != 0:
            var next = external_call["gtk_widget_get_next_sibling", Int](cur)
            if cur not in want:
                external_call["gtk_fixed_remove", NoneType](fixed, cur)
            cur = next
        var mine = List[BoardChild]()
        var built = 0
        for k in range(len(children)):
            var c = children[k]
            var child = want[k]
            var entry = BoardChild(j, c, k, child, fixed, drag)
            if child == 0:
                child = self.build(c, self_addr)
                external_call["gtk_fixed_put", NoneType](fixed, child, Float64(self.rt.shown.nodes[c].x), Float64(self.rt.shown.nodes[c].y))
                # (in node order: what draws on top is what a drag picks)
                external_call["gtk_widget_insert_after", NoneType](child, fixed, mine[len(mine) - 1].widget if len(mine) > 0 else 0)
                entry.widget = child
                want[k] = child
                built += 1
            else:
                var dragging = drag != 0 and external_call["gtk_gesture_is_active", c_int](drag) != 0
                for b in self.boards:
                    if b.board == j and b.node == c and dragging:  # (a drag that ended while busy left them set)
                        entry.active = b.active
                        entry.resizing = b.resizing
            mine.append(entry^)
        var boards = List[BoardChild]()
        for b in self.boards:
            if b.board != j:
                boards.append(b.copy())
        for e in mine:
            boards.append(e.copy())
        var last = 0
        for k in range(len(boards)):  # (each board's drag knows its first object's place in the list)
            if boards[k].drag != last:
                set_index(boards[k].drag, k)
                last = boards[k].drag
        self.boards = boards^
        return built

    def resize_widget(self, i: Int):
        """A SET_SIZE patch: node i's sizes onto the widget apply_layout() sized (inside its clamp, if it has one)."""
        ref node = self.rt.shown.nodes[i]
        var outer = self.outers[i]
        if outer == 0:
            return
        var target = outer
        var cap = node.max_w if node.max_w != 0 else node.w
        if cap != 0 and Int(external_call["g_type_check_instance_is_a", c_int](outer, external_call["adw_clamp_get_type", Int]())) != 0:
            external_call["adw_clamp_set_maximum_size", NoneType](outer, c_int(cap))
            external_call["adw_clamp_set_tightening_threshold", NoneType](outer, c_int(cap))
            target = external_call["adw_clamp_get_child", Int](outer)
        var want_w = max(node.w, node.min_w)
        external_call["gtk_widget_set_size_request", NoneType](target, c_int(want_w if want_w != 0 else -1), c_int(node.h if node.h != 0 else -1))

    def full_page(self):
        """For a picture (MOJOUI_SHOT), after the test's report: the page scroller stops scrolling, so a screen taller
        than the window shows whole (the window grows to it), as the web's full-page screenshot shows its whole page.
        Before D-440 the window always grew; the boxes reported before this are the window's own size's (D-461)."""
        if self.page != 0:
            external_call["gtk_scrolled_window_set_policy", NoneType](self.page, c_int(2), c_int(2))  # NEVER, NEVER

    def fit_shares(self, k: Int):
        """A Grid with column shares (52, 48): each cell asks for its column's share of the grid's width, so the columns
        add up to it exactly (GTK has no fractional columns; the web's are fr). After each layout, as fit_measures."""
        var grid = self.widgets[k]
        var total = Int(external_call["gtk_widget_get_width", c_int](grid))
        if total <= 0:
            return
        ref n = self.rt.shown.nodes[k]
        var cols = max(n.value, 1)
        var shares = List[Int]()
        var sum = 0
        for c in range(cols):
            var v = 1
            if c < len(n.options):
                try:
                    v = max(Int(n.options[c]), 1)
                except:
                    v = 1
            shares.append(v)
            sum += v
        var room = total - self.column_gap(n.name, n.spacing) * (cols - 1)
        var used = 0
        for c in range(cols):
            var want = room - used if c == cols - 1 else room * shares[c] // sum
            used += want
            for r in range((len(n.children) + cols - 1) // cols):
                var cell = external_call["gtk_grid_get_child_at", Int](grid, c_int(c), c_int(r))
                if cell == 0:
                    continue
                var have = List[c_int](length=2, fill=0)
                external_call["gtk_widget_get_size_request", NoneType](cell, Int(have.unsafe_ptr()), Int(have.unsafe_ptr()) + 4)
                if Int(have[0]) != want:
                    external_call["gtk_widget_set_size_request", NoneType](cell, c_int(want), have[1])

    def fit_blocks(self, k: Int):
        """Block words with a max width in block-flow column k: as wide as the column up to that width, from its leading
        edge (a trailing margin takes the rest; place_child uncapped their clamp). After each layout, as fit_measures."""
        ref n = self.rt.shown.nodes[k]
        for c in n.children:
            if c >= len(self.widgets) or self.widgets[c] == 0 or not self.block_words(n, self.rt.shown.nodes[c]):
                continue
            var cap = self.rt.shown.nodes[c].max_w
            if cap <= 0:
                continue
            var label = self.widgets[c]
            var width = Int(external_call["gtk_widget_get_width", c_int](label))
            if width <= 0:
                continue
            var room = width + Int(external_call["gtk_widget_get_margin_end", c_int](label))
            var margin = c_int(max(room - cap, 0))
            if external_call["gtk_widget_get_margin_end", c_int](label) != margin:
                external_call["gtk_widget_set_margin_end", NoneType](label, margin)

    def fit_measures(self):
        """A paragraph whose role has a measure (Surface.max_chars) is at most that many "0"s of its font wide (measured
        in the label's own font, CSS's ch), from its leading edge, as the web's max-width in ch: a trailing margin takes
        what's left of its room (D-472; GTK's max-width-chars counts an average character and its natural width for
        wrapped words balances the lines, so the layout never settled). Runs after each layout; a change asks for another."""
        for k in range(min(len(self.kinds), len(self.widgets), len(self.rt.shown.nodes))):
            if self.kinds[k] == GRID and self.widgets[k] != 0 and len(self.rt.shown.nodes[k].options) > 0:
                self.fit_shares(k)
                continue
            if self.kinds[k] == VSTACK and self.flows(self.rt.shown.nodes[k].name):
                self.fit_blocks(k)
                continue
            if self.widgets[k] == 0 or not self.measured(self.rt.shown.nodes[k]):
                continue
            var boxed = self.kinds[k] != PARAGRAPH and self.kinds[k] != TEXT
            var clamped = k < len(self.outers) and self.outers[k] != 0 and Int(external_call["g_type_check_instance_is_a", c_int](self.outers[k], external_call["adw_clamp_get_type", Int]())) != 0
            if boxed and not clamped:
                continue
            var label = self.widgets[k]
            var width = Int(external_call["gtk_widget_get_width", c_int](label))
            if width <= 0:
                continue
            var zero = String("0")
            var layout = external_call["gtk_widget_create_pango_layout", Int](label, zero.as_c_string_span())  # ("0" in the label's own font: CSS's ch)
            if boxed:  # (a box's own font isn't its role's, which its words wear: the role's family and size, as CSS's ch)
                ref sf = self.look.surfaces[self.look.surface(self.rt.shown.nodes[k].name)]
                var spec = (sf.font if sf.font != "" else self.look.type.family) + " " + String(sf.font_size if sf.font_size > 0 else self.look.type.body) + "px"
                var desc = external_call["pango_font_description_from_string", Int](spec.as_c_string_span())
                external_call["pango_layout_set_font_description", NoneType](layout, desc)
                external_call["pango_font_description_free", NoneType](desc)
            var size = List[c_int](length=2, fill=0)
            external_call["pango_layout_get_pixel_size", NoneType](layout, Int(size.unsafe_ptr()), Int(size.unsafe_ptr()) + 4)
            var ch = Float64(Int(size[0]))
            var extents = List[c_int](length=8, fill=0)  # (sub-pixel: the ink and logical rects in Pango units)
            external_call["pango_layout_get_extents", NoneType](layout, Int(0), Int(extents.unsafe_ptr()))
            if Int(extents[2]) > 0:
                ch = Float64(Int(extents[2])) / 1024.0
            external_call["g_object_unref", NoneType](layout)
            if ch <= 0:
                continue
            var chars = self.look.surfaces[self.look.surface(self.rt.shown.nodes[k].name)].max_chars
            if boxed:  # (a box: its clamp at the measure; it hugs at most that, from its leading edge)
                var most_box = c_int(Int(ch * Float64(chars) + 0.5))
                if external_call["adw_clamp_get_maximum_size", c_int](self.outers[k]) != most_box:
                    external_call["adw_clamp_set_maximum_size", NoneType](self.outers[k], most_box)
                    external_call["adw_clamp_set_tightening_threshold", NoneType](self.outers[k], most_box)
                continue
            var most = Int(ch * Float64(chars) + 0.5)
            if clamped:  # (its clamp caps its natural width at the measure, so a column that hugs it is the web's width; in
                # a column wider than the measure the clamp would centre it: then the clamp takes the column and the margin
                # below holds the measure from the leading edge, D-525)
                var outer = self.outers[k]
                var cap_now = Int(external_call["adw_clamp_get_maximum_size", c_int](outer))
                var given = Int(external_call["gtk_widget_get_width", c_int](outer))
                var want = cap_now
                if cap_now == UNMEASURED:
                    want = most
                elif given > max(cap_now, most) + 1:
                    want = given
                if want != cap_now:
                    external_call["adw_clamp_set_maximum_size", NoneType](outer, c_int(want))
                    external_call["adw_clamp_set_tightening_threshold", NoneType](outer, c_int(want))
            var room = width + Int(external_call["gtk_widget_get_margin_end", c_int](label))
            var margin = c_int(max(room - most, 0))
            if external_call["gtk_widget_get_margin_end", c_int](label) != margin:
                external_call["gtk_widget_set_margin_end", NoneType](label, margin)

    def one_line_words(self, n: Int):
        """The words in view n (and in its views) stay on one line, cut with an ellipsis: a dense table's cell (the web's
        table.dense td .text: nowrap, overflow hidden, text-overflow ellipsis)."""
        if n < 0 or n >= len(self.rt.shown.nodes) or n >= len(self.widgets):
            return
        var kids = self.rt.shown.nodes[n].children.copy()
        if self.rt.shown.nodes[n].kind == TEXT and self.widgets[n] != 0:
            external_call["gtk_label_set_wrap", NoneType](self.widgets[n], c_int(0))
            external_call["gtk_label_set_ellipsize", NoneType](self.widgets[n], c_int(3))  # PANGO_ELLIPSIZE_END
        for c in kids:
            self.one_line_words(c)

    def fit_tables(self):
        """Each Table's columns share its width as a browser's automatic table layout does (the web's is a <table>):
        every column at least its widest cell's narrowest (min-content), then the room up to each one's widest
        (max-content) shared by how much each wants, then any more room by their widest. Runs after each layout; a
        change asks for another (D-442)."""
        for k in range(min(len(self.kinds), len(self.widgets), len(self.rt.shown.nodes))):
            if self.kinds[k] != TABLE or self.widgets[k] == 0:
                continue
            var grid = self.widgets[k]
            var holder = external_call["gtk_widget_get_parent", Int](grid)
            if holder == 0:
                continue
            var room = Int(external_call["gtk_widget_get_width", c_int](holder))
            if room <= 0:
                continue
            var cols = max(self.rt.shown.nodes[k].value, 1)
            var rows = len(self.rt.shown.nodes[k].children) // cols
            var lo = List[Int](length=cols, fill=0)
            var hi = List[Int](length=cols, fill=0)
            var m = List[c_int](length=2, fill=0)
            var fixed = List[Bool](length=cols, fill=False)  # (a column of a set width: no share of more room)
            var dense = self.rt.shown.nodes[k].style == 1 or self.rt.shown.nodes[k].style == 2
            for c in range(cols):
                var lim = self.rt.shown.nodes[k].options[c] if c < len(self.rt.shown.nodes[k].options) else String("")
                var cap = 0  # (a cut column's widest, the web's td max-width: border-box, a cap on its cells' widths)
                if dense and lim != "W" and not lim.startswith("T"):
                    var digits = String(lim[byte = 0 : lim.byte_length() - 1]) if lim.endswith("S") else lim
                    try:
                        cap = Int(digits) if digits != "" else 0
                    except:
                        cap = 0
                for r in range(rows):
                    var cell = external_call["gtk_grid_get_child_at", Int](grid, c_int(c), c_int(r))
                    if cell == 0:
                        continue
                    external_call["gtk_widget_measure", NoneType](cell, c_int(HORIZONTAL), c_int(-1), Int(m.unsafe_ptr()), Int(m.unsafe_ptr()) + 4, Int(0), Int(0))
                    var a, b = Int(m[0]), max(Int(m[1]), Int(m[0]))
                    if dense and lim != "W":  # (a dense cell's words are one line: its narrowest is its widest, as the
                        a = b                # browser's nowrap; GTK's cut labels would measure an ellipsis)
                        if cap > 0 and not (r == 0):  # (the head's words aren't cut: the web's max-width is on the td)
                            a, b = min(a, cap), min(b, cap)
                    lo[c] = max(lo[c], a)
                    hi[c] = max(hi[c], b)
                if lim.startswith("T") and lim.byte_length() > 1:  # the tick column: the theme's width overall, its box when wider (the web's th width, border-box)
                    try:
                        var tw = Int(lim[byte=1:])
                        lo[c], hi[c] = max(lo[c], tw), max(lo[c], tw)
                        fixed[c] = True
                    except:
                        pass
            var sum_lo = 0
            var sum_hi = 0
            var free_hi = 0  # (the columns more room goes to: all but a set width's, unless every one is set)
            for c in range(cols):
                sum_lo += lo[c]
                sum_hi += hi[c]
                if not fixed[c]:
                    free_hi += hi[c]
            var all_fixed = free_hi == 0
            if all_fixed:
                free_hi = sum_hi
            # Each column's exact share, then whole pixels by rounding where each column ends (its edge is the
            # browser's to half a pixel): the floors' remainder, up to a pixel a column, all went to the last one, and
            # the models table's ACCESS column stood 126 for the web's 121.3 (D-550).
            var want = List[Int](length=cols, fill=0)
            var exact = Float64(0)
            var edge = 0
            for c in range(cols):
                var v = Float64(lo[c])
                if room >= sum_hi and sum_hi > 0:
                    v = Float64(hi[c]) + (Float64(room - sum_hi) * Float64(hi[c]) / Float64(free_hi) if all_fixed or not fixed[c] else 0.0)
                elif room > sum_lo and sum_hi > sum_lo:
                    v = Float64(lo[c]) + Float64(room - sum_lo) * Float64(hi[c] - lo[c]) / Float64(sum_hi - sum_lo)
                exact += v
                var next = Int(exact + 0.5)
                want[c] = next - edge
                edge = next
            for c in range(cols):
                var spacer = external_call["gtk_grid_get_child_at", Int](grid, c_int(c), c_int(-1))
                if spacer == 0:
                    continue
                external_call["gtk_widget_get_size_request", NoneType](spacer, Int(m.unsafe_ptr()), Int(m.unsafe_ptr()) + 4)
                if Int(m[0]) != want[c]:
                    external_call["gtk_widget_set_size_request", NoneType](spacer, c_int(want[c]), c_int(0))
            _ = len(m)

    def build_child(mut self, parent: Int, c: Int, self_addr: Int) -> Int:
        """Builds child c of stack `parent` and aligns it in the stack."""
        var child = self.build(c, self_addr)
        var node = self.rt.shown.nodes[parent].copy()
        self.place_child(node, self.rt.shown.nodes[c], child)
        if node.kind == HSTACK and self.rt.shown.nodes[c].kind == DIVIDER and not self.rt.shown.nodes[c].sized_width():
            # a Divider between a row's parts stands up: 1 px wide, a control high, 6 px each side (the web's .hstack > hr)
            # (its room is the look's Controls.divider_side: GTK's own is none, as before D-440)
            var sep = self.widgets[c]
            var dn = self.rt.shown.nodes[c].copy()
            external_call["gtk_orientable_set_orientation", NoneType](sep, c_int(VERTICAL))
            external_call["gtk_widget_set_size_request", NoneType](sep, c_int(-1), c_int(dn.h if dn.h != 0 else (-1 if dn.height_from_parent else 28)))
            external_call["gtk_widget_set_valign", NoneType](sep, c_int(ALIGN_CENTER))
            var plain = String("mui-divider")
            external_call["gtk_widget_remove_css_class", NoneType](sep, plain.as_c_string_span())
            add_class(sep, "mui-divider-up")
        if node.kind == VSTACK and self.rt.shown.nodes[c].kind == TEXT and node.align_items == START:
            external_call["gtk_label_set_justify", NoneType](self.widgets[c], c_int(0))  # left-aligned lines too
            external_call["gtk_label_set_xalign", NoneType](self.widgets[c], Float32(0))
        return child

    def ends_row(self, role: String) -> Bool:
        var k = self.look.surface(role) if role != "" else -1
        return k >= 0 and self.look.surfaces[k].ends_row

    def flows(self, role: String) -> Bool:
        """Whether a role lays its children as block flow (Surface.block_flow)."""
        var k = self.look.surface(role) if role != "" else -1
        return k >= 0 and self.look.surfaces[k].block_flow

    def block_words(self, parent: Node, child: Node) -> Bool:
        """Words (a Text or Paragraph) in a block-flow column: a block, as wide as the column, at most their max width
        (the web's display: block with max-width), not their words' width (D-523)."""
        return (child.kind == TEXT or child.kind == PARAGRAPH) and parent.kind == VSTACK and self.flows(parent.name)

    def measured(self, node: Node) -> Bool:
        """Whether the role a view wears gives it a measure (Surface.max_chars)."""
        var k = self.look.surface(node.name) if node.name != "" else -1
        return k >= 0 and self.look.surfaces[k].max_chars > 0

    def place_child(self, parent: Node, child_node: Node, child: Int):
        """Aligns a stack's child: the stack's align, then the child's own fill/grow."""
        var vertical = parent.kind == VSTACK or parent.kind == DRAG or parent.kind == DROP or parent.kind == EMBED or parent.kind == WEBCOMP  # (one child, stacked down)
        var cross = ALIGN_CENTER
        if parent.align_items == START:
            cross = 1  # GTK_ALIGN_START
        elif parent.align_items == END:
            cross = 2  # GTK_ALIGN_END
        var wrapper = parent.kind == DRAG or parent.kind == DROP or parent.kind == EMBED or parent.kind == WEBCOMP  # (its one view across it, as the web's align-items: stretch, D-494)
        var spans = vertical and child_node.kind == SCROLL  # (a Scroll spans its column: the web's .scroll { width: 100% }, D-502)
        var block = self.block_words(parent, child_node)
        if parent.align_items == STRETCH or child_node.fills or child_node.kind == SPACER or wrapper or spans or block:
            cross = 0  # GTK_ALIGN_FILL
        if block and child_node.max_w > 0 and Int(external_call["g_type_check_instance_is_a", c_int](child, external_call["adw_clamp_get_type", Int]())) != 0:
            # (AdwClamp centres a capped child: the cap is fit_measures' trailing margin instead, from the leading edge)
            external_call["adw_clamp_set_maximum_size", NoneType](child, c_int(10000))
            external_call["adw_clamp_set_tightening_threshold", NoneType](child, c_int(10000))
        if block and child_node.kind == TEXT:  # (a block's lines read from its leading edge)
            var label = child
            if Int(external_call["g_type_check_instance_is_a", c_int](child, external_call["adw_clamp_get_type", Int]())) != 0:
                label = external_call["adw_clamp_get_child", Int](child)
            external_call["gtk_label_set_xalign", NoneType](label, Float32(0))
            external_call["gtk_label_set_justify", NoneType](label, c_int(0))
        # A spacer takes room only along its stack (else a Spacer in a toolbar makes the whole bar tall); a view
        # with a fixed size along the stack never takes spare room there (as on the other hosts).
        if vertical:
            external_call["gtk_widget_set_halign", NoneType](child, c_int(cross))
            if child_node.kind == SPACER:
                external_call["gtk_widget_set_hexpand", NoneType](child, c_int(0))
            if child_node.grows and child_node.h == 0:
                external_call["gtk_widget_set_vexpand", NoneType](child, c_int(1))
                external_call["gtk_widget_set_valign", NoneType](child, c_int(0))
        else:
            external_call["gtk_widget_set_valign", NoneType](child, c_int(cross))
            if child_node.kind == SPACER:
                external_call["gtk_widget_set_vexpand", NoneType](child, c_int(0))
            if child_node.grows and child_node.w == 0:
                external_call["gtk_widget_set_hexpand", NoneType](child, c_int(1))
                external_call["gtk_widget_set_halign", NoneType](child, c_int(0))

    def build(mut self, i: Int, self_addr: Int) -> Int:
        """Creates the GTK widget for node i (and its children)."""
        var node = self.rt.shown.nodes[i].copy()  # copy: building children mutates self
        # A control's built-in width yields when the app sizes it (fill, grow or width).
        var sized = node.sized_width()
        var w: Int
        if node.kind == TEXT:
            var t = label_words(self.rt.shown.nodes, i)  # (the browser's line breaks and ends, D-548, D-549)
            w = external_call["gtk_label_new", Int](t.as_c_string_span())
            external_call["gtk_label_set_wrap", NoneType](w, c_int(1))
            external_call["gtk_label_set_natural_wrap_mode", NoneType](w, c_int(1))  # prefer one line; wrap only when squeezed
            external_call["gtk_label_set_justify", NoneType](w, c_int(2))  # centre
            if node.w > 0:  # a text given a width is a column of a row (a table's cell): it reads from the leading edge, as on the web
                external_call["gtk_label_set_justify", NoneType](w, c_int(0))
                external_call["gtk_label_set_xalign", NoneType](w, Float32(0))
            if node.style == TITLE:
                add_class(w, "title-1")
            elif node.style == HEADLINE:
                add_class(w, "title-4")
            elif node.style == CAPTION:
                add_class(w, "caption")
                add_class(w, "dim-label")
            set_tone(w, node.value)
        elif node.kind == PARAGRAPH:  # one wrapping label: the runs as Pango markup (escaped), GTK breaks the lines (D-470)
            var empty = String("")
            w = external_call["gtk_label_new", Int](empty.as_c_string_span())
            var markup = pango_markup(node, self.look)
            external_call["gtk_label_set_markup", NoneType](w, markup.as_c_string_span())
            external_call["gtk_label_set_wrap", NoneType](w, c_int(1))
            external_call["gtk_label_set_wrap_mode", NoneType](w, c_int(2))  # PANGO_WRAP_WORD_CHAR: words, a long one broken (the web's overflow-wrap: anywhere)
            external_call["gtk_label_set_natural_wrap_mode", NoneType](w, c_int(1))  # (as a Text: one line when there's room)
            external_call["gtk_label_set_justify", NoneType](w, c_int(0))
            external_call["gtk_label_set_xalign", NoneType](w, Float32(0))
            add_class(w, "mui-paragraph")
            var role = self.look.surface(node.name) if node.name != "" else -1
            set_node(w, i)
            connect_any(w, "activate-link", on_activate_link[Self.A], self_addr)
        elif node.kind == BUTTON:
            var t = node.text
            if node.hint != "" and (node.style == ICON_ONLY or node.style == ICON_ON):  # just the icon; the title is the tooltip
                var icon = gtk_icon(node.hint)
                w = external_call["gtk_button_new_from_icon_name", Int](icon.as_c_string_span())
                external_call["gtk_widget_set_tooltip_text", NoneType](w, t.as_c_string_span())
                if node.style == ICON_ON:
                    add_class(w, "mui-tool-on")
            elif node.style == TOOL or node.style == TOOL_ON or node.style == TOOL_INLINE or node.style == TOOL_INLINE_ON:  # the icon above (or beside) a small title
                var inline = node.style == TOOL_INLINE or node.style == TOOL_INLINE_ON
                w = external_call["gtk_button_new", Int]()
                var box = external_call["gtk_box_new", Int](c_int(HORIZONTAL if inline else VERTICAL), c_int(6 if inline else 2))
                if node.hint != "":
                    var icon = gtk_icon(node.hint)
                    _ = external_call["gtk_box_append", NoneType](box, external_call["gtk_image_new_from_icon_name", Int](icon.as_c_string_span()))
                var label = external_call["gtk_label_new", Int](t.as_c_string_span())
                add_class(label, "mui-tool-label")
                external_call["gtk_box_append", NoneType](box, label)
                external_call["gtk_button_set_child", NoneType](w, box)
                add_class(w, "mui-tool")
                if inline:
                    add_class(w, "mui-tool-inline")
                if node.style == TOOL_ON or node.style == TOOL_INLINE_ON:
                    add_class(w, "mui-tool-on")
            elif node.hint != "":  # icon + title
                w = external_call["gtk_button_new", Int]()
                var content = external_call["adw_button_content_new", Int]()
                var icon = gtk_icon(node.hint) + ("-light" if node.style == PROMINENT and node.hint != "" else "")
                external_call["adw_button_content_set_icon_name", NoneType](content, icon.as_c_string_span())
                external_call["adw_button_content_set_label", NoneType](content, t.as_c_string_span())
                external_call["gtk_button_set_child", NoneType](w, content)
            else:
                w = external_call["gtk_button_new_with_label", Int](t.as_c_string_span())
                var words = external_call["gtk_button_get_child", Int](w)  # a squeezed title wraps, as the web's does
                if words != 0:
                    external_call["gtk_label_set_wrap", NoneType](words, c_int(1))
                    external_call["gtk_label_set_natural_wrap_mode", NoneType](words, c_int(1))  # (one line when there's room)
                    if node.align_items == START:
                        external_call["gtk_label_set_xalign", NoneType](words, Float32(0))
            if node.align_items == START and node.style != ICON_ONLY and node.style != ICON_ON:  # its content at the leading edge (a sidebar row)
                var child = external_call["gtk_button_get_child", Int](w)
                if child != 0:
                    external_call["gtk_widget_set_halign", NoneType](child, c_int(1))  # GTK_ALIGN_START
            mark_button_labels(w)
            if node.style == PROMINENT:
                add_class(w, "suggested-action")
                if node.hint == "":
                    add_class(w, "pill")
            elif node.style == DESTRUCTIVE:
                add_class(w, "destructive-action")
            elif node.style == SUBTLE or node.style == ICON_ONLY or node.style == ICON_ON or node.style == TOOL or node.style == TOOL_ON or node.style == TOOL_INLINE or node.style == TOOL_INLINE_ON:
                add_class(w, "flat")
            elif node.style == TOKEN or node.style == TOKEN_LIT:  # a word in a sentence: flat, tight, in the accent (libadwaita's own accent colour)
                add_class(w, "flat")
                if node.style == TOKEN_LIT:
                    add_class(w, "mui-token-lit")  # (just changed: a theme marks it for a moment)
                add_class(w, self.layout_class("mui-token", "padding: 0 3px; min-height: 0; min-width: 0; border-radius: 4px;"))
                var label = external_call["gtk_button_get_child", Int](w)
                if label != 0:
                    add_class(label, "accent")
                    add_class(label, "mui-token-label")
            connect(w, "clicked", on_clicked[Self.A], self_addr)
        elif node.kind == FIELD:
            w = external_call["gtk_entry_new", Int]()
            if node.value >= 1:
                add_class(w, "mui-cell-editor")
            if node.size != 0:  # on_cancel: Escape
                var esc = external_call["gtk_event_controller_key_new", Int]()
                set_node(esc, i)
                connect_any(esc, "key-pressed", on_field_key[Self.A], self_addr)
                external_call["gtk_widget_add_controller", NoneType](w, esc)
                if node.value >= 1:
                    self.editor_keys = esc
            var t = node.text
            var h = node.hint
            external_call["gtk_editable_set_text", NoneType](w, t.as_c_string_span())
            external_call["gtk_entry_set_placeholder_text", NoneType](w, h.as_c_string_span())
            if not sized:
                width(w, 220)
            connect(w, "changed", on_field_changed[Self.A], self_addr)
            connect(w, "activate", on_field_submit[Self.A], self_addr)
        elif node.kind == TOGGLE:
            var t = node.text
            w = external_call["gtk_check_button_new_with_label", Int](t.as_c_string_span())
            external_call["gtk_check_button_set_active", NoneType](w, c_int(node.value))
            connect(w, "toggled", on_toggled[Self.A], self_addr)
        elif node.kind == DROPDOWN:
            var model = external_call["gtk_string_list_new", Int](0)
            for o in node.options:
                var s = o
                external_call["gtk_string_list_append", NoneType](model, s.as_c_string_span())
            w = external_call["gtk_drop_down_new", Int](model, 0)
            external_call["gtk_drop_down_set_selected", NoneType](w, c_uint(node.value))
            connect3(w, "notify::selected", on_selected[Self.A], self_addr)
        elif node.kind == SLIDER:
            w = external_call["gtk_scale_new_with_range", Int](c_int(HORIZONTAL), Float64(0), Float64(100), Float64(1))
            external_call["gtk_range_set_value", NoneType](w, Float64(node.value))
            if not sized:
                width(w, 240)
            connect(w, "value-changed", on_slid[Self.A], self_addr)
        elif node.kind == PROGRESS:
            w = external_call["gtk_progress_bar_new", Int]()
            external_call["gtk_progress_bar_set_fraction", NoneType](w, Float64(node.value) / 100.0)
            if not sized:
                width(w, 240)
        elif node.kind == DIVIDER:
            w = external_call["gtk_separator_new", Int](c_int(HORIZONTAL))
            if not sized:
                width(w, 280)
            add_class(w, "mui-divider")  # (its room above and below: the look's Controls.divider_gap; GTK's own is none)
        elif node.kind == IMAGE:
            var tex = texture(node.pixels, node.spacing, node.size)
            w = external_call["gtk_picture_new_for_paintable", Int](tex)
            external_call["g_object_unref", NoneType](tex)
            external_call["gtk_picture_set_can_shrink", NoneType](w, c_int(0))
            external_call["gtk_picture_set_content_fit", NoneType](w, c_int(3))  # scale-down: never bigger than its pixels
            external_call["gtk_widget_set_halign", NoneType](w, c_int(ALIGN_CENTER))
            external_call["gtk_widget_set_valign", NoneType](w, c_int(ALIGN_CENTER))
            external_call["gtk_widget_set_size_request", NoneType](w, c_int(node.spacing), c_int(node.size))
        elif node.kind == CANVAS:
            w = external_call["gtk_picture_new", Int]()
            external_call["gtk_picture_set_can_shrink", NoneType](w, c_int(1))  # its size comes from the layout
            external_call["gtk_picture_set_content_fit", NoneType](w, c_int(0))  # fill: the pixels match its size
            external_call["gtk_widget_set_size_request", NoneType](w, c_int(-1 if sized else 320), c_int(-1 if node.sized_height() else 240))
            var ci = len(self.canvases)
            var c = GtkCanvas(i, w)
            set_index(w, ci)
            var drag = external_call["gtk_gesture_drag_new", Int]()
            set_index(drag, ci)
            connect_any(drag, "drag-begin", on_drag_begin[Self.A], self_addr)
            connect_any(drag, "drag-update", on_drag_update[Self.A], self_addr)
            connect_any(drag, "drag-end", on_drag_end[Self.A], self_addr)
            external_call["gtk_widget_add_controller", NoneType](w, drag)
            var scroll = external_call["gtk_event_controller_scroll_new", Int](c_int(1))  # vertical
            set_index(scroll, ci)
            connect_any(scroll, "scroll", on_scroll[Self.A], self_addr)
            external_call["gtk_widget_add_controller", NoneType](w, scroll)
            var motion = external_call["gtk_event_controller_motion_new", Int]()
            set_index(motion, ci)
            connect_any(motion, "motion", on_motion[Self.A], self_addr)
            external_call["gtk_widget_add_controller", NoneType](w, motion)
            var pinch = external_call["gtk_gesture_zoom_new", Int]()
            set_index(pinch, ci)
            connect3(pinch, "begin", on_pinch_begin[Self.A], self_addr)
            connect_any(pinch, "scale-changed", on_pinch[Self.A], self_addr)
            external_call["gtk_widget_add_controller", NoneType](w, pinch)
            var click = external_call["gtk_gesture_click_new", Int]()
            set_index(click, ci)
            connect_any(click, "released", on_click_released[Self.A], self_addr)
            external_call["gtk_widget_add_controller", NoneType](w, click)
            var secondary = external_call["gtk_gesture_click_new", Int]()  # the right button: SECONDARY (a context menu)
            external_call["gtk_gesture_single_set_button", NoneType](secondary, c_uint(3))
            set_index(secondary, ci)
            connect_any(secondary, "released", on_secondary_released[Self.A], self_addr)
            external_call["gtk_widget_add_controller", NoneType](w, secondary)
            var keys = 0
            if node.size == 1:  # Canvas(keys=True): a press gives it the keyboard
                external_call["gtk_widget_set_focusable", NoneType](w, c_int(1))
                keys = external_call["gtk_event_controller_key_new", Int]()
                set_index(keys, ci)
                connect_any(keys, "key-pressed", on_key_pressed[Self.A], self_addr)
                external_call["gtk_widget_add_controller", NoneType](w, keys)
            c.drag = drag
            c.scroll = scroll
            c.click = click
            c.secondary = secondary
            c.keys = keys
            c.motion_ctl = motion
            c.pinch_ctl = pinch
            self.canvases.append(c^)
            self.arm(ci, self_addr)
            # A picture asks for its texture's size in pixels, which would grow the canvas each
            # redraw on a scaled screen: a scrolled window that never scrolls takes no size from it.
            self.widgets[i] = w
            var holder = external_call["gtk_scrolled_window_new", Int]()
            external_call["gtk_scrolled_window_set_policy", NoneType](holder, c_int(3), c_int(3))  # GTK_POLICY_EXTERNAL
            external_call["gtk_scrolled_window_set_child", NoneType](holder, w)
            external_call["gtk_widget_set_size_request", NoneType](holder, c_int(-1 if sized else 320), c_int(-1 if node.sized_height() else 240))
            external_call["gtk_widget_set_size_request", NoneType](w, c_int(-1), c_int(-1))
            w = holder
        elif node.kind == SEGMENTED or node.kind == TABS:
            w = external_call["adw_toggle_group_new", Int]()  # GNOME's own segmented control
            for j in range(len(node.options)):
                var t = external_call["adw_toggle_new", Int]()
                var label = node.options[j]
                external_call["adw_toggle_set_label", NoneType](t, label.as_c_string_span())
                external_call["adw_toggle_group_add", NoneType](w, t)
            external_call["adw_toggle_group_set_active", NoneType](w, c_uint(node.value))
            if node.kind == TABS:
                add_class(w, "round")
            connect3(w, "notify::active", on_toggle_group[Self.A], self_addr)
        elif node.kind == RADIO:
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(4))
            var first = 0
            for j in range(len(node.options)):
                var label = node.options[j]
                var b = external_call["gtk_check_button_new_with_label", Int](label.as_c_string_span())
                if first == 0:
                    first = b
                else:
                    external_call["gtk_check_button_set_group", NoneType](b, first)  # radio look
                external_call["gtk_check_button_set_active", NoneType](b, c_int(1 if j == node.value else 0))
                set_node(b, i)
                set_index(b, j)
                connect(b, "toggled", on_radio[Self.A], self_addr)
                external_call["gtk_box_append", NoneType](w, b)
        elif node.kind == TEXTAREA:
            var view = external_call["gtk_text_view_new", Int]()
            external_call["gtk_text_view_set_wrap_mode", NoneType](view, c_int(2))  # GTK_WRAP_WORD
            external_call["gtk_text_view_set_left_margin", NoneType](view, c_int(8))
            external_call["gtk_text_view_set_top_margin", NoneType](view, c_int(8))
            var buffer = external_call["gtk_text_view_get_buffer", Int](view)
            var t = node.text
            external_call["gtk_text_buffer_set_text", NoneType](buffer, t.as_c_string_span(), c_int(-1))
            set_node(buffer, i)
            connect(buffer, "changed", on_text_changed[Self.A], self_addr)
            self.widgets[i] = view
            w = external_call["gtk_scrolled_window_new", Int]()
            external_call["gtk_scrolled_window_set_child", NoneType](w, view)
            add_class(w, "card")
            external_call["gtk_widget_set_size_request", NoneType](w, c_int(-1 if sized else 320), c_int(node.size))
        elif node.kind == ALERT:
            var heading = node.text
            var body = node.hint
            w = external_call["adw_alert_dialog_new", Int](heading.as_c_string_span(), body.as_c_string_span())
            for j in range(len(node.options)):
                var id = String(j)
                var label = node.options[j]
                external_call["adw_alert_dialog_add_response", NoneType](w, id.as_c_string_span(), label.as_c_string_span())
            var cancel = String("0")  # Escape answers with the first button (Cancel), as on Apple platforms
            external_call["adw_alert_dialog_set_close_response", NoneType](w, cancel.as_c_string_span())
            set_node(w, i)
            connect3(w, "response", on_alert_response[Self.A], self_addr)
            _ = external_call["g_object_ref_sink", Int](w)
            self.dialog = w
            self.widgets[i] = w
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))  # nothing in the layout itself
        elif node.kind == NAVBAR:
            w = external_call["gtk_box_new", Int](c_int(HORIZONTAL), c_int(8))
            if node.msg != 0:
                var icon = String("go-previous-symbolic")
                var back = external_call["gtk_button_new_from_icon_name", Int](icon.as_c_string_span())
                add_class(back, "flat")
                var tip = String("Back")
                external_call["gtk_widget_set_tooltip_text", NoneType](back, tip.as_c_string_span())  # also its accessible name
                set_node(back, i)
                connect(back, "clicked", on_clicked[Self.A], self_addr)
                external_call["gtk_box_append", NoneType](w, back)
            var t = node.text
            var title = external_call["gtk_label_new", Int](t.as_c_string_span())
            add_class(title, "title-2")
            external_call["gtk_box_append", NoneType](w, title)
        elif node.kind == DATE:
            w = external_call["gtk_calendar_new", Int]()
            calendar_select(w, node.text)
            connect(w, "day-selected", on_day_selected[Self.A], self_addr)
        elif node.kind == ICON:
            var name = gtk_icon(node.text)
            w = external_call["gtk_image_new_from_icon_name", Int](name.as_c_string_span())
            external_call["gtk_image_set_pixel_size", NoneType](w, c_int(node.size))
        elif node.kind == GRID:
            w = external_call["gtk_grid_new", Int]()
            external_call["gtk_grid_set_row_spacing", NoneType](w, c_uint(node.spacing))
            var col_gap = self.column_gap(node.name, node.spacing)  # (a role's column gap, as the web's column-gap: D-495)
            external_call["gtk_grid_set_column_spacing", NoneType](w, c_uint(col_gap))
            external_call["gtk_grid_set_column_homogeneous", NoneType](w, c_int(0 if node.style == 1 or len(node.options) > 0 else 1))  # (fitted: columns to their content; shares: fit_measures() sizes them)
            for k in range(len(node.children)):
                var child = self.build(node.children[k], self_addr)
                self.place_in_grid(i, node.children[k], child)
                var last = k % node.value == node.value - 1
                if node.style == 1 and not last and self.rt.shown.nodes[node.children[k]].kind == TEXT:
                    external_call["gtk_label_set_wrap", NoneType](self.widgets[node.children[k]], c_int(0))  # (a fitted column is as wide as its widest words, never wrapped: the web's max-content)
                if node.hint == "E" and last:  # (the last column's items at its trailing edge)
                    external_call["gtk_widget_set_halign", NoneType](child, c_int(2))  # GTK_ALIGN_END
                external_call["gtk_grid_attach", NoneType](w, child, c_int(k % node.value), c_int(k // node.value), c_int(1), c_int(1))
        elif node.kind == LAZYLIST:
            var model = external_call["gtk_string_list_new", Int](0)
            var empty = String("")
            for _ in range(node.value):  # placeholders only; row text is asked for when a row is shown
                external_call["gtk_string_list_append", NoneType](model, empty.as_c_string_span())
            var selection = external_call["gtk_no_selection_new", Int](model)
            var factory = external_call["gtk_signal_list_item_factory_new", Int]()
            set_node(factory, i)
            connect3(factory, "setup", on_row_setup[Self.A], self_addr)
            connect3(factory, "bind", on_row_bind[Self.A], self_addr)
            connect3(factory, "unbind", on_row_unbind, self_addr)
            var list = external_call["gtk_list_view_new", Int](selection, factory)
            external_call["gtk_list_view_set_single_click_activate", NoneType](list, c_int(1))
            add_class(list, "boxed-list")
            set_node(list, i)
            connect3(list, "activate", on_row_activate[Self.A], self_addr)
            self.widgets[i] = list
            w = external_call["gtk_scrolled_window_new", Int]()
            external_call["gtk_scrolled_window_set_child", NoneType](w, list)
            external_call["gtk_scrolled_window_set_policy", NoneType](w, c_int(2), c_int(1))
            external_call["gtk_widget_set_size_request", NoneType](w, c_int(-1 if sized else 340), c_int(node.size))
        elif node.kind == SPACER:
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
            external_call["gtk_widget_set_hexpand", NoneType](w, c_int(1))
            external_call["gtk_widget_set_vexpand", NoneType](w, c_int(1))
        elif node.kind == SCROLL:
            w = external_call["gtk_scrolled_window_new", Int]()
            external_call["gtk_scrolled_window_set_policy", NoneType](w, c_int(2), c_int(1))  # never, automatic
            external_call["gtk_scrolled_window_set_max_content_height", NoneType](w, c_int(node.size if node.size > 0 else -1))  # (0: as tall as it is given)
            external_call["gtk_scrolled_window_set_propagate_natural_height", NoneType](w, c_int(1))
            external_call["gtk_scrolled_window_set_propagate_natural_width", NoneType](w, c_int(1))
            for c in node.children:
                var content = self.build(c, self_addr)
                external_call["gtk_widget_set_valign", NoneType](content, c_int(1))  # its own height: a taller scroll doesn't stretch it
                external_call["gtk_scrolled_window_set_child", NoneType](w, content)
            if node.value == 1:  # pinned: it follows its end as the content grows, unless scrolled up
                var adj = external_call["gtk_scrolled_window_get_vadjustment", Int](w)
                connect(adj, "changed", on_pin_changed, 0)
                connect(adj, "value-changed", on_pin_moved, 0)
        elif node.kind == DIALOG:
            var dlg = external_call["adw_dialog_new", Int]()
            var title = node.text
            external_call["adw_dialog_set_title", NoneType](dlg, title.as_c_string_span())
            external_call["adw_dialog_set_content_width", NoneType](dlg, c_int(node.w if node.w > 0 else 560))
            var box = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
            add_class(box, "mui-dialog")
            var head = external_call["gtk_box_new", Int](c_int(HORIZONTAL), c_int(12))
            add_class(head, "mui-dialog-head")
            var label = external_call["gtk_label_new", Int](title.as_c_string_span())
            add_class(label, "title-4")
            external_call["gtk_label_set_xalign", NoneType](label, Float32(0))
            external_call["gtk_widget_set_hexpand", NoneType](label, c_int(1))
            external_call["gtk_box_append", NoneType](head, label)
            var close_icon = String("window-close-symbolic")
            var close = external_call["gtk_button_new_from_icon_name", Int](close_icon.as_c_string_span())
            add_class(close, "flat")
            add_class(close, "circular")
            var close_tip = String("Close")
            external_call["gtk_widget_set_tooltip_text", NoneType](close, close_tip.as_c_string_span())
            set_node(close, i)
            connect(close, "clicked", on_overlay_close[Self.A], self_addr)
            external_call["gtk_box_append", NoneType](head, close)
            external_call["gtk_box_append", NoneType](box, head)
            for c in node.children:
                var content = self.build(c, self_addr)
                add_class(content, "mui-dialog-body")
                external_call["gtk_box_append", NoneType](box, content)
            external_call["adw_dialog_set_child", NoneType](dlg, box)
            set_node(dlg, i)
            connect(dlg, "closed", on_dialog_closed[Self.A], self_addr)
            _ = external_call["g_object_ref_sink", Int](dlg)
            self.dialog = dlg
            self.widgets[i] = dlg
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))  # nothing in the layout itself
        elif node.kind == CLIPBOARD or node.kind == ROUTE:  # nothing on screen (a Route is state here: no URL)
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
        elif node.kind == TABLE:  # a grid whose columns size to their content; each cell in a box wearing its role
            w = external_call["gtk_grid_new", Int]()
            add_class(w, "mui-table")  # (a theme's rules for what's in a table: its tick boxes, D-492)
            if node.style == 2:
                add_class(w, "mui-table-compact")
            var cols = max(node.value, 1)
            for k in range(len(node.children)):
                var child = self.build(node.children[k], self_addr)
                var col = k % cols
                var row = k // cols
                var cell = external_call["gtk_box_new", Int](c_int(HORIZONTAL), c_int(0))
                add_class(cell, "mui-tag-table-head" if row == 0 else "mui-tag-table-cell")
                # a dense table's cells wear the dense roles too, as the web's (D-493): table-dense-head/-cell, on a phone
                # the compact ones over them, a snug column's cells table-dense-snug; their words stay on one line, cut,
                # but in a column that wraps ("W")
                var lim = node.options[col] if col < len(node.options) else String("")
                if node.style == 1 or node.style == 2:
                    var compact = node.style == 2
                    var snug = row > 0 and not lim.startswith("T") and lim.endswith("S")
                    add_class(cell, "mui-tag-table-dense-head" if row == 0 else "mui-tag-table-dense-cell")
                    if compact:
                        add_class(cell, "mui-tag-table-dense-compact-head" if row == 0 else "mui-tag-table-dense-compact-cell")
                    if snug:
                        add_class(cell, "mui-tag-table-dense-snug")
                        if compact:
                            add_class(cell, "mui-tag-table-dense-compact-snug")
                    if lim != "W":
                        self.one_line_words(node.children[k])
                var num = col < node.hint.byte_length() and String(node.hint[byte=col]) == "R"
                if num:
                    add_class(cell, "mui-tag-table-num")
                if row > 0 and row - 1 < node.text.byte_length() and String(node.text[byte = row - 1]) == "1":
                    add_class(cell, "mui-tag-table-selected")
                external_call["gtk_widget_set_hexpand", NoneType](cell, c_int(1))
                # a cell's view fills the cell, as a block in the web's <td> does (words keep to their side); a button or a
                # tick box keeps its own width at its side
                var ck = self.rt.shown.nodes[node.children[k]].kind
                var keeps = ck == BUTTON or ck == TOGGLE
                external_call["gtk_widget_set_halign", NoneType](child, c_int((2 if num else 1) if keeps else 0))  # end, start or fill
                if ck == TEXT:
                    external_call["gtk_label_set_xalign", NoneType](self.widgets[node.children[k]], Float32(1 if num else 0))
                external_call["gtk_widget_set_valign", NoneType](child, c_int(3))  # centre
                external_call["gtk_widget_set_hexpand", NoneType](child, c_int(1))
                external_call["gtk_box_append", NoneType](cell, child)
                external_call["gtk_grid_attach", NoneType](w, cell, c_int(col), c_int(row), c_int(1), c_int(1))
            for col in range(cols):  # row -1: an empty box per column whose width fit_tables() sets (the column's share)
                external_call["gtk_grid_attach", NoneType](w, external_call["gtk_box_new", Int](c_int(HORIZONTAL), c_int(0)), c_int(col), c_int(-1), c_int(1), c_int(1))
            # in a scroller that never shows a bar: the columns' shares are minimums, and they mustn't hold the window
            # at its width when it gets narrower (the next layout shares the new width)
            self.widgets[i] = w
            var holder = external_call["gtk_scrolled_window_new", Int]()
            external_call["gtk_scrolled_window_set_policy", NoneType](holder, c_int(3), c_int(2))  # EXTERNAL across, NEVER down
            external_call["gtk_scrolled_window_set_propagate_natural_width", NoneType](holder, c_int(1))
            external_call["gtk_scrolled_window_set_propagate_natural_height", NoneType](holder, c_int(1))
            external_call["gtk_scrolled_window_set_child", NoneType](holder, w)
            w = holder
        elif node.kind == TOAST:
            if self.toast != 0 and self.toast_text == node.text:  # the same toast, still up: keep it
                set_node(self.toast, i)
            else:
                if self.toast != 0:
                    set_node(self.toast, -1)
                    external_call["adw_toast_dismiss", NoneType](self.toast)
                    external_call["g_object_unref", NoneType](self.toast)
                var t = node.text
                var toast = external_call["adw_toast_new", Int](t.as_c_string_span())
                if len(node.options) > 0:
                    var action = node.options[0]
                    external_call["adw_toast_set_button_label", NoneType](toast, action.as_c_string_span())
                external_call["adw_toast_set_timeout", NoneType](toast, c_uint(node.size if node.size > 0 else 6))
                _ = external_call["g_object_ref", Int](toast)
                set_node(toast, i)
                connect(toast, "button-clicked", on_toast_action[Self.A], self_addr)
                connect(toast, "dismissed", on_toast_dismissed[Self.A], self_addr)
                self.toast = toast
                self.toast_text = node.text
                if self.toast_overlay != 0:
                    external_call["adw_toast_overlay_add_toast", NoneType](self.toast_overlay, toast)
            self.toast_claimed = True
            self.widgets[i] = self.toast
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
        elif node.kind == POPOVER:
            var box = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(8))
            add_class(box, "mui-popover")
            if node.hint != "":
                var title = node.hint
                var label = external_call["gtk_label_new", Int](title.as_c_string_span())
                add_class(label, "title-4")
                external_call["gtk_label_set_xalign", NoneType](label, Float32(0))
                external_call["gtk_box_append", NoneType](box, label)
            for c in node.children:
                external_call["gtk_box_append", NoneType](box, self.build(c, self_addr))
            var popover = external_call["gtk_popover_new", Int]()
            external_call["gtk_popover_set_child", NoneType](popover, box)
            external_call["gtk_popover_set_position", NoneType](popover, c_int(3))  # GTK_POS_BOTTOM
            add_class(popover, "mui-popover-surface")
            connect(popover, "map", on_popover_map, 0)  # (once it shows, the keyboard goes in: arrows and Return pick)
            var arrows = external_call["gtk_event_controller_key_new", Int]()
            connect_any(arrows, "key-pressed", on_popover_key, popover)
            external_call["gtk_widget_add_controller", NoneType](popover, arrows)
            var anchor = self.window
            for k in range(len(self.rt.shown.nodes)):
                if self.rt.shown.nodes[k].name == node.text and k < len(self.widgets) and self.widgets[k] != 0:
                    anchor = self.widgets[k]
            external_call["gtk_widget_set_parent", NoneType](popover, anchor)
            if node.x != 0 or node.y != 0:
                var rect = List[Int32](length=4, fill=0)
                rect[0] = Int32(node.x)
                rect[1] = Int32(node.y)
                rect[2] = 1
                rect[3] = 1
                external_call["gtk_popover_set_pointing_to", NoneType](popover, Int(rect.unsafe_ptr()))
                _ = len(rect)
            set_node(popover, i)
            connect(popover, "closed", on_menu_closed[Self.A], self_addr)
            self.popovers.append(popover)
            self.popups.append(popover)
            self.widgets[i] = popover
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
        elif node.kind == MENUBAR:
            w = external_call["gtk_box_new", Int](c_int(HORIZONTAL), c_int(2))
            add_class(w, "mui-menubar")
            for c in node.children:
                external_call["gtk_box_append", NoneType](w, self.build(c, self_addr))
        elif node.kind == MENU:
            var box = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
            add_class(box, "mui-menu-items")
            for c in node.children:
                external_call["gtk_box_append", NoneType](box, self.build(c, self_addr))
            var popover = external_call["gtk_popover_new", Int]()
            external_call["gtk_popover_set_child", NoneType](popover, box)
            external_call["gtk_popover_set_has_arrow", NoneType](popover, c_int(0))
            external_call["gtk_popover_set_position", NoneType](popover, c_int(3))  # GTK_POS_BOTTOM
            add_class(popover, "mui-menu-popover")
            if node.style == 1:  # a context menu: over its anchor at (x, y); closing it (not through an item) is on_close
                var anchor = self.window
                for k in range(len(self.rt.shown.nodes)):
                    if self.rt.shown.nodes[k].name == node.text and k < len(self.widgets) and self.widgets[k] != 0:
                        anchor = self.widgets[k]
                var rect = List[Int32](length=4, fill=0)
                rect[0] = Int32(node.x)
                rect[1] = Int32(node.y)
                rect[2] = 1
                rect[3] = 1
                external_call["gtk_widget_set_parent", NoneType](popover, anchor)
                external_call["gtk_popover_set_pointing_to", NoneType](popover, Int(rect.unsafe_ptr()))
                _ = len(rect)
                set_node(popover, i)
                connect(popover, "closed", on_menu_closed[Self.A], self_addr)
                self.popovers.append(popover)
                self.popups.append(popover)
                self.widgets[i] = popover
                w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))  # nothing in the layout itself
            else:
                var t = node.text
                w = external_call["gtk_menu_button_new", Int]()
                external_call["gtk_menu_button_set_label", NoneType](w, t.as_c_string_span())
                external_call["gtk_menu_button_set_popover", NoneType](w, popover)
                add_class(w, "flat")
                add_class(w, "mui-menu")
        elif node.kind == ITEM:
            if node.style == 1:
                w = external_call["gtk_separator_new", Int](c_int(HORIZONTAL))
                add_class(w, "mui-menu-sep")
            elif node.style == 2:
                var t = node.text
                w = external_call["gtk_label_new", Int](t.as_c_string_span())
                external_call["gtk_label_set_xalign", NoneType](w, Float32(0))
                add_class(w, "mui-menu-label")
            else:
                var row = external_call["gtk_box_new", Int](c_int(HORIZONTAL), c_int(10))
                var lead: Int
                if node.value & CHECKED != 0:
                    var check = String("object-select-symbolic")
                    lead = external_call["gtk_image_new_from_icon_name", Int](check.as_c_string_span())
                elif node.hint != "":
                    var icon = gtk_icon(node.hint)
                    lead = external_call["gtk_image_new_from_icon_name", Int](icon.as_c_string_span())
                else:
                    lead = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
                external_call["gtk_widget_set_size_request", NoneType](lead, c_int(16), c_int(-1))
                external_call["gtk_box_append", NoneType](row, lead)
                var t = node.text
                var label = external_call["gtk_label_new", Int](t.as_c_string_span())
                external_call["gtk_label_set_xalign", NoneType](label, Float32(0))
                external_call["gtk_widget_set_hexpand", NoneType](label, c_int(1))
                external_call["gtk_box_append", NoneType](row, label)
                if len(node.children) > 0:  # a submenu: its own popover, opening to the right
                    var arrow = String("›")
                    var tail = external_call["gtk_label_new", Int](arrow.as_c_string_span())
                    add_class(tail, "mui-menu-key")
                    external_call["gtk_box_append", NoneType](row, tail)
                    var box = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
                    add_class(box, "mui-menu-items")
                    for c in node.children:
                        external_call["gtk_box_append", NoneType](box, self.build(c, self_addr))
                    var sub = external_call["gtk_popover_new", Int]()
                    external_call["gtk_popover_set_child", NoneType](sub, box)
                    external_call["gtk_popover_set_has_arrow", NoneType](sub, c_int(0))
                    external_call["gtk_popover_set_position", NoneType](sub, c_int(1))  # GTK_POS_RIGHT
                    add_class(sub, "mui-menu-popover")
                    w = external_call["gtk_menu_button_new", Int]()
                    external_call["gtk_menu_button_set_child", NoneType](w, row)
                    external_call["gtk_menu_button_set_popover", NoneType](w, sub)
                    external_call["gtk_menu_button_set_direction", NoneType](w, c_int(1))  # GTK_ARROW_RIGHT
                else:
                    if len(node.options) > 0:
                        var key = node.options[0]
                        var tail = external_call["gtk_label_new", Int](key.as_c_string_span())
                        add_class(tail, "mui-menu-key")
                        external_call["gtk_box_append", NoneType](row, tail)
                    w = external_call["gtk_button_new", Int]()
                    external_call["gtk_button_set_child", NoneType](w, row)
                    connect(w, "clicked", on_item_clicked[Self.A], self_addr)
                add_class(w, "flat")
                add_class(w, "mui-menu-item")
                if node.value & DANGER != 0:
                    add_class(w, "mui-danger")
                if node.value & DISABLED != 0:
                    external_call["gtk_widget_set_sensitive", NoneType](w, c_int(0))
        elif node.kind == OVERLAY:
            w = external_call["gtk_overlay_new", Int]()
            for k in range(len(node.children)):
                var c = node.children[k]
                var child = self.build(c, self_addr)
                if k == 0:
                    external_call["gtk_widget_set_hexpand", NoneType](child, c_int(1))
                    external_call["gtk_widget_set_vexpand", NoneType](child, c_int(1))
                    external_call["gtk_overlay_set_child", NoneType](w, child)
                else:  # an island: pinned to an edge, 12 pt in, its natural size
                    ref pin = self.rt.shown.nodes[c]
                    external_call["gtk_widget_set_halign", NoneType](child, c_int(1 if pin.x == START else (2 if pin.x == END else ALIGN_CENTER)))
                    external_call["gtk_widget_set_valign", NoneType](child, c_int(2 if pin.y == END else 1))
                    external_call["gtk_widget_set_margin_top", NoneType](child, c_int(12))
                    external_call["gtk_widget_set_margin_bottom", NoneType](child, c_int(12))
                    external_call["gtk_widget_set_margin_start", NoneType](child, c_int(12))
                    external_call["gtk_widget_set_margin_end", NoneType](child, c_int(12))
                    add_class(child, "mui-island")
                    external_call["gtk_overlay_add_overlay", NoneType](w, child)
        elif node.kind == BOARD:
            var inner: Int
            if self.window_w != 0 and self.window_w < 720:  # a phone-width window: the objects as a list
                self.board_list = True
                inner = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(16))
                for c in node.children:
                    if self.rt.shown.nodes[c].kind == FIELD and self.rt.shown.nodes[c].value >= 1:
                        continue  # an in-place editor has no cell to sit over in the list
                    var child = self.build(c, self_addr)
                    external_call["gtk_widget_set_halign", NoneType](child, c_int(0))  # fill the width
                    external_call["gtk_widget_set_hexpand", NoneType](child, c_int(1))
                    external_call["gtk_box_append", NoneType](inner, child)
            else:
                inner = external_call["gtk_fixed_new", Int]()
                external_call["gtk_widget_set_size_request", NoneType](inner, c_int(node.spacing), c_int(node.size))
                external_call["gtk_widget_set_hexpand", NoneType](inner, c_int(1))  # at least the visible page (its dotted
                external_call["gtk_widget_set_vexpand", NoneType](inner, c_int(1))  # background); positions stay absolute
                # One drag gesture on the board itself (never on the object it moves: a gesture
                # measures from the widget it's attached to, so a moving widget would measure
                # against itself and jitter); drag-begin finds the object under the pointer.
                var drag = external_call["gtk_gesture_drag_new", Int]()
                set_index(drag, len(self.boards))  # its first child in self.boards
                connect_any(drag, "drag-begin", on_board_drag_begin[Self.A], self_addr)
                connect_any(drag, "drag-update", on_board_drag_update[Self.A], self_addr)
                connect_any(drag, "drag-end", on_board_drag_end[Self.A], self_addr)
                external_call["gtk_widget_add_controller", NoneType](inner, drag)
                self.board_drags.append((i, drag))
                for k in range(len(node.children)):
                    var c = node.children[k]
                    var child = self.build(c, self_addr)
                    external_call["gtk_fixed_put", NoneType](inner, child, Float64(self.rt.shown.nodes[c].x), Float64(self.rt.shown.nodes[c].y))
                    self.boards.append(BoardChild(i, c, k, child, inner, drag))
            # The page scrolls when it's bigger than the room it's given (both ways).
            w = external_call["gtk_scrolled_window_new", Int]()
            external_call["gtk_scrolled_window_set_policy", NoneType](w, c_int(1), c_int(1))  # automatic, automatic
            external_call["gtk_scrolled_window_set_child", NoneType](w, inner)
            add_class(inner, "mui-board")
            self.widgets[i] = inner  # patches move and size the board's own widget
            self.board_scrollers.append((i, w))
            if node.value != 0 and node.value != self.revealed:
                self.reveal_pending = i
        elif node.kind == DRAG or node.kind == DROP or node.kind == EMBED or node.kind == WEBCOMP:  # one child, in a box that drags, takes drops, or stands in for a page
            w = external_call["gtk_box_new", Int](c_int(VERTICAL), c_int(0))
            for c in node.children:
                external_call["gtk_box_append", NoneType](w, self.build_child(i, c, self_addr))
            if node.kind == DRAG:  # a GtkDragSource carrying the payload as a string (a local drop reads it straight)
                var src = external_call["gtk_drag_source_new", Int]()
                external_call["gtk_drag_source_set_actions", NoneType](src, c_int(GDK_ACTION_COPY))
                var gv = List[Int](length=3, fill=0)  # (a GValue: its type, then two words)
                _ = external_call["g_value_init", Int](Int(gv.unsafe_ptr()), Int(G_TYPE_STRING))
                var payload = node.text
                external_call["g_value_set_string", NoneType](Int(gv.unsafe_ptr()), payload.as_c_string_span())
                var provider = external_call["gdk_content_provider_new_for_value", Int](Int(gv.unsafe_ptr()))
                external_call["g_value_unset", NoneType](Int(gv.unsafe_ptr()))
                _ = gv[0]  # (keeps the GValue's memory alive through the calls above: an address doesn't)
                external_call["gtk_drag_source_set_content", NoneType](src, provider)
                external_call["g_object_unref", NoneType](provider)
                external_call["gtk_widget_add_controller", NoneType](w, src)
                var key = String(DRAG_KEY)
                external_call["g_object_set_data", NoneType](w, key.as_c_string_span(), src)
            elif node.kind == DROP:  # a GtkDropTarget for strings: its drop sends the node's on_drop with the text
                var target = external_call["gtk_drop_target_new", Int](Int(G_TYPE_STRING), c_int(GDK_ACTION_COPY))
                set_node(target, i)
                connect_any(target, "drop", on_drop[Self.A], self_addr)
                external_call["gtk_widget_add_controller", NoneType](w, target)
                var key = String(DROP_KEY)
                external_call["g_object_set_data", NoneType](w, key.as_c_string_span(), target)
            elif node.kind == WEBCOMP:  # its widget in a WebKitGTK view of its own (kept across rebuilds), else `instead`
                self.place_webview(i, w, self_addr)
            elif node.size > 0 and not node.sized_height():
                external_call["gtk_widget_set_size_request", NoneType](w, c_int(-1), c_int(node.size))
        else:
            var orientation = VERTICAL if node.kind == VSTACK else HORIZONTAL
            w = external_call["gtk_box_new", Int](c_int(orientation), c_int(node.spacing))
            if node.kind == VSTACK and (node.style == CARD or node.style == CARD_WARN or node.style == CARD_GOOD):
                add_class(w, "card")  # libadwaita's own card look
                add_class(w, "mui-card")
                if node.style == CARD_WARN:
                    add_class(w, "mui-warn")
                elif node.style == CARD_GOOD:
                    add_class(w, "mui-good")
            if node.kind == HSTACK:
                external_call["gtk_widget_set_halign", NoneType](w, c_int(ALIGN_CENTER))
                var growers = 0
                for c in node.children:
                    if self.rt.shown.nodes[c].grows and self.rt.shown.nodes[c].w == 0:
                        growers += 1
                if growers >= 2 and growers == len(node.children):  # (all growing from zero, as the web's flex: 1 1 0: equal shares)
                    external_call["gtk_box_set_homogeneous", NoneType](w, c_int(1))
            # justify: GtkBox packs from the start; invisible expanding spacers do the rest.
            var j = node.justify_items
            for c in node.children:  # a growing child takes all the free space: no spacers
                if self.rt.shown.nodes[c].grows:
                    j = AUTO
            if j == CENTER or j == END:
                external_call["gtk_box_append", NoneType](w, spacer(orientation))
            for k in range(len(node.children)):
                var c = node.children[k]
                if j == BETWEEN and k > 0:
                    external_call["gtk_box_append", NoneType](w, spacer(orientation))
                var child = self.build_child(i, c, self_addr)
                external_call["gtk_box_append", NoneType](w, child)
            if j == CENTER:
                external_call["gtk_box_append", NoneType](w, spacer(orientation))
        set_node(w, i)
        if self.widgets[i] == 0:  # (some branches already stored an inner control)
            self.widgets[i] = w
        var outer = self.apply_layout(i, w)
        self.outers[i] = outer
        return outer

    def show(mut self, self_addr: Int):
        """(Re)builds the window's content from rt.shown."""
        var t_show = perf_counter_ns()
        set_busy(True)
        if self.dialog != 0:  # the previous screen's alert (or dialog) goes with it
            set_node(self.dialog, -1)  # (closing now isn't on_close: the screen is being replaced)
            _ = external_call["adw_dialog_force_close", c_int](self.dialog)
            external_call["g_object_unref", NoneType](self.dialog)
            self.dialog = 0
        for pop in self.popovers:  # and its context menus (parented to anchors, not in the layout)
            set_node(pop, -1)  # (closing now isn't on_close: the screen is being replaced)
            external_call["gtk_popover_popdown", NoneType](pop)
            external_call["gtk_widget_unparent", NoneType](pop)
        self.popovers = List[Int]()
        self.popups = List[Int]()
        self.has_pending = False  # (a full rebuild covers any partial one waiting)
        self.widgets = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.outers = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.kinds = List[Int](capacity=len(self.rt.shown.nodes))
        self.ids = List[Int](capacity=len(self.rt.shown.nodes))
        self.id_node = List[Int](capacity=len(self.rt.shown.nodes))
        for k in range(len(self.rt.shown.nodes)):
            self.kinds.append(self.rt.shown.nodes[k].kind)
            self.ids.append(k)
            self.id_node.append(k)
        self.publish_ids()
        self.release_canvases(List[Bool]())
        self.canvases = List[GtkCanvas]()
        self.boards = List[BoardChild]()
        self.board_scrollers = List[Tuple[Int, Int]]()
        self.board_drags = List[Tuple[Int, Int]]()
        self.release_node = -1  # (a release from the old screen names a canvas that's gone)
        self.echo_node = -1
        var root = self.build(0, self_addr)
        if self.rt.shown.nodes[0].grows or self.rt.shown.nodes[0].fills:  # the screen fills the window
            external_call["gtk_widget_set_valign", NoneType](root, c_int(0))
            external_call["gtk_widget_set_halign", NoneType](root, c_int(0))
        else:
            external_call["gtk_widget_set_valign", NoneType](root, c_int(ALIGN_CENTER))
            external_call["gtk_widget_set_margin_top", NoneType](root, c_int(32))
            external_call["gtk_widget_set_margin_bottom", NoneType](root, c_int(32))
            external_call["gtk_widget_set_margin_start", NoneType](root, c_int(32))
            external_call["gtk_widget_set_margin_end", NoneType](root, c_int(32))
        if self.toast_overlay == 0:  # toasts float over whatever screen is up
            self.toast_overlay = external_call["adw_toast_overlay_new", Int]()
            external_call["gtk_window_set_child", NoneType](self.window, self.toast_overlay)
            # (a screen taller than the window scrolls instead of growing the window past the size asked for, as the
            # web's page does; across, the screen's own minimum still holds: D-440)
            self.page = external_call["gtk_scrolled_window_new", Int]()
            external_call["gtk_scrolled_window_set_policy", NoneType](self.page, c_int(2), c_int(1))  # NEVER across, AUTOMATIC down
            external_call["adw_toast_overlay_set_child", NoneType](self.toast_overlay, self.page)
        external_call["gtk_scrolled_window_set_child", NoneType](self.page, root)
        if self.toast != 0 and not self.toast_claimed:  # the new screen has no toast: the old one goes
            set_node(self.toast, -1)
            external_call["adw_toast_dismiss", NoneType](self.toast)
            external_call["g_object_unref", NoneType](self.toast)
            self.toast = 0
            self.toast_text = ""
        self.toast_claimed = False
        if self.reveal_pending >= 0:
            _ = external_call["gtk_widget_add_tick_callback", c_uint](root, on_reveal_tick[Self.A], self_addr, 0)
        if self.dialog != 0 and (getenv("MOJOUI_TEST") == "" or getenv("MOJOUI_SHOT") != ""):  # plain tests drive it unseen
            external_call["adw_dialog_present", NoneType](self.dialog, self.window)
        for pop in self.popups:  # a context menu opens once its anchor is in the window
            external_call["gtk_popover_popup", NoneType](pop)
        self.popups = List[Int]()
        self.focus_after_build(List[Bool](length=len(self.rt.shown.nodes), fill=True))
        self.sync_webviews(self_addr)
        set_busy(False)
        if self.rt.trace:
            print("TRACE: rebuild " + ms(perf_counter_ns() - t_show) + " widgets " + String(len(self.rt.shown.nodes)))

    def focus_after_build(mut self, fresh: List[Bool]):
        """After new widgets went up: an in-place editor takes the keyboard, or it goes back to the canvas that had it.
        fresh: which nodes were just built (an editor that stayed keeps its text and caret)."""
        var editor = False
        for k in range(len(self.rt.shown.nodes)):  # an in-place editor (.focused()) takes the keyboard, its text selected
            if self.rt.shown.nodes[k].kind == FIELD and self.rt.shown.nodes[k].value >= 1 and self.widgets[k] != 0:
                editor = True
                self.editor_node = k
                if not fresh[k]:
                    continue
                if self.rt.shown.nodes[k].value == 1:
                    _ = external_call["gtk_widget_grab_focus", c_int](self.widgets[k])
                    external_call["gtk_editable_select_region", NoneType](self.widgets[k], c_int(0), c_int(-1))
                else:  # .echo(): the canvas typing into it keeps the keyboard
                    external_call["gtk_editable_set_position", NoneType](self.widgets[k], c_int(-1))  # (a click goes on from the end)
                    for c in self.canvases:
                        if c.node == self.key_node:
                            self.grab_quietly(c.widget)
                self.focus = -1
        if not editor:
            self.editor_keys = 0
            if self.editor_open and (self.focus < 0 or self.focus == self.editor_node):  # an in-place editor closed (not
                self.focus = -1  # by someone typing in another field): the keyboard goes back to the canvas it came from
                for c in self.canvases:
                    if c.node == self.key_node:
                        self.grab_quietly(c.widget)
        self.editor_open = editor
        if not editor and self.focus < 0:  # no text field has the keyboard: a canvas that takes keys gets it (arrows work at once)
            var root_focus = external_call["gtk_root_get_focus", Int](self.window) if self.window != 0 else 0
            var typing = root_focus != 0 and Int(external_call["g_type_check_instance_is_a", c_int](root_focus, external_call["gtk_editable_get_type", Int]())) != 0
            if not typing:
                for c in self.canvases:
                    if c.keys != 0:
                        self.grab_quietly(c.widget)
                        self.key_node = c.node
                        break
        if 0 <= self.focus < len(self.widgets) and self.rt.shown.nodes[self.focus].kind == FIELD:
            _ = external_call["gtk_entry_grab_focus_without_selecting", c_int](self.widgets[self.focus])  # keep typing
        self.focus = -1

    def grab_quietly(self, widget: Int):
        """Gives `widget` the keyboard without scrolling a board to it: the host's own focus moves (the keyboard back to
        the grid after a popover) mustn't move the page under the person; their Tab still scrolls as GTK does."""
        var viewports = List[Int]()
        for bs in self.board_scrollers:
            var child = external_call["gtk_scrolled_window_get_child", Int](bs[1])
            if child != 0 and Int(external_call["g_type_check_instance_is_a", c_int](child, external_call["gtk_viewport_get_type", Int]())) != 0:
                external_call["gtk_viewport_set_scroll_to_focus", NoneType](child, c_int(0))
                viewports.append(child)
        _ = external_call["gtk_widget_grab_focus", c_int](widget)
        for v in viewports:
            external_call["gtk_viewport_set_scroll_to_focus", NoneType](v, c_int(1))

    def publish_ids(self):
        """Hands set_node()/get_node() the id tables (kept on the GApplication: they're free functions)."""
        set_app_data("mojoui-ids", Int(self.ids.unsafe_ptr()))
        set_app_data("mojoui-ids-n", len(self.ids))
        set_app_data("mojoui-id-node", Int(self.id_node.unsafe_ptr()))
        set_app_data("mojoui-id-node-n", len(self.id_node))

    def update_part(mut self, self_addr: Int):
        """A partial rebuild (Diff.partial): the widgets the diff kept stay as they are (with their hover, scroll,
        focus, animations and a drag in progress); only the new parts are built, and only the stacks whose children
        changed lay them out again."""
        var t0 = perf_counter_ns()
        set_busy(True)
        self.has_pending = False
        for j in self.pending.resync:  # a Board shown as a list (a narrow window), or one with no objects yet: whole
            if self.rt.shown.nodes[j].kind == BOARD and (self.board_list or not self.board_drag(self.pending.kept[j])):
                self.show(self_addr)
                return
        var key_before = self.key_node
        var kept = self.pending.kept.copy()
        var resync = self.pending.resync.copy()
        var patches = self.pending.patches.copy()
        ref nodes = self.rt.shown.nodes
        var n = len(nodes)
        var old_n = len(self.widgets)
        var new_of_old = List[Int](length=old_n, fill=-1)
        for j in range(n):
            if kept[j] >= 0:
                new_of_old[kept[j]] = j
        # What went: its dialog closes, its popovers go (the rest goes with the widgets that held it).
        for o in range(old_n):
            if new_of_old[o] >= 0 or self.widgets[o] == 0:
                continue
            var kind = self.kinds[o]
            if (kind == DIALOG or kind == ALERT) and self.widgets[o] == self.dialog:
                set_node(self.dialog, -1)  # (closing now isn't on_close: the app took it away)
                _ = external_call["adw_dialog_force_close", c_int](self.dialog)
                external_call["g_object_unref", NoneType](self.dialog)
                self.dialog = 0
            elif kind == POPOVER or kind == MENU:
                var rest = List[Int]()
                for pop in self.popovers:
                    if pop == self.widgets[o]:
                        set_node(pop, -1)
                        external_call["gtk_popover_popdown", NoneType](pop)
                        external_call["gtk_widget_unparent", NoneType](pop)
                    else:
                        rest.append(pop)
                self.popovers = rest^
        # Ids: the kept nodes keep theirs (their widgets' data stays right); the rest are new.
        var free = List[Int]()  # (the ids of nodes that went: their widgets are gone, so the ids can be used again)
        for o in range(old_n):
            if new_of_old[o] < 0 and o < len(self.ids) and 0 <= self.ids[o] < len(self.id_node):
                self.id_node[self.ids[o]] = -1
                free.append(self.ids[o])
        var ids = List[Int](length=n, fill=-1)
        for j in range(n):
            if kept[j] >= 0:
                ids[j] = self.ids[kept[j]]
                self.id_node[ids[j]] = j
            elif len(free) > 0:
                ids[j] = free.pop()
                self.id_node[ids[j]] = j
            else:
                ids[j] = len(self.id_node)
                self.id_node.append(j)
        self.ids = ids^
        self.publish_ids()
        var widgets = List[Int](length=n, fill=0)
        var outers = List[Int](length=n, fill=0)
        var kinds = List[Int](capacity=n)
        for j in range(n):
            kinds.append(nodes[j].kind)
            if kept[j] >= 0:
                widgets[j] = self.widgets[kept[j]]
                outers[j] = self.outers[kept[j]]
        self.widgets = widgets^
        self.outers = outers^
        self.kinds = kinds^
        # Canvases and boards that stay are renumbered (and their controllers told their new place in the list).
        var staying = List[Bool](length=len(self.canvases), fill=False)
        for k in range(len(self.canvases)):
            var cn = self.canvases[k].node
            staying[k] = cn >= 0 and cn < old_n and new_of_old[cn] >= 0
        self.release_canvases(staying)
        var canvases = List[GtkCanvas]()
        for ref c in self.canvases:
            if c.node >= 0 and c.node < old_n and new_of_old[c.node] >= 0:
                var moved = c.copy()
                moved.node = new_of_old[c.node]
                var ci = len(canvases)
                for ctl in [moved.widget, moved.drag, moved.scroll, moved.click, moved.secondary, moved.keys, moved.motion_ctl, moved.pinch_ctl]:
                    if ctl != 0:
                        set_index(ctl, ci)
                canvases.append(moved^)
        self.canvases = canvases^
        var boards = List[BoardChild]()
        var last_drag = 0
        for ref b in self.boards:
            if b.board >= 0 and b.board < old_n and new_of_old[b.board] >= 0 and new_of_old[b.node] >= 0:
                var moved = b.copy()
                moved.board = new_of_old[b.board]
                moved.node = new_of_old[b.node]
                if moved.drag != last_drag:  # (a board's drag knows its first child's place in the list)
                    set_index(moved.drag, len(boards))
                    last_drag = moved.drag
                boards.append(moved^)
        self.boards = boards^
        var scrollers = List[Tuple[Int, Int]]()
        for bs in self.board_scrollers:
            if 0 <= bs[0] < old_n and new_of_old[bs[0]] >= 0:
                scrollers.append((new_of_old[bs[0]], bs[1]))
        self.board_scrollers = scrollers^
        var drags = List[Tuple[Int, Int]]()
        for bd in self.board_drags:
            if 0 <= bd[0] < old_n and new_of_old[bd[0]] >= 0:
                drags.append((new_of_old[bd[0]], bd[1]))
        self.board_drags = drags^
        self.focus = new_of_old[self.focus] if 0 <= self.focus < old_n else -1
        self.key_node = new_of_old[self.key_node] if 0 <= self.key_node < old_n else -1
        self.editor_node = new_of_old[self.editor_node] if 0 <= self.editor_node < old_n else -1
        self.picker_node = new_of_old[self.picker_node] if 0 <= self.picker_node < old_n else -1
        self.reveal_pending = new_of_old[self.reveal_pending] if 0 <= self.reveal_pending < old_n else -1
        self.release_node = new_of_old[self.release_node] if 0 <= self.release_node < old_n else -1
        self.echo_node = new_of_old[self.echo_node] if 0 <= self.echo_node < old_n else -1
        # The stacks whose children changed: build the new children, drop the old, put them in order.
        var moving = List[Int]()  # kept popovers whose anchor is being built again: held, then moved to the new one
        for j in range(n):
            if kept[j] >= 0 and (self.kinds[j] == POPOVER or (self.kinds[j] == MENU and self.rt.shown.nodes[j].style == 1)) and self.widgets[j] != 0:
                var stays = external_call["gtk_widget_get_parent", Int](self.widgets[j]) == self.window  # (no anchor: it sits on the window, which stays)
                for k in range(n):
                    if self.rt.shown.nodes[k].name == self.rt.shown.nodes[j].text and kept[k] >= 0 and self.widgets[k] != 0:
                        stays = external_call["gtk_widget_get_parent", Int](self.widgets[j]) == self.widgets[k]
                if not stays:
                    _ = external_call["g_object_ref", Int](self.widgets[j])
                    external_call["gtk_widget_unparent", NoneType](self.widgets[j])
                    moving.append(j)
        var dialog_before = self.dialog
        var built = 0
        self.toast_claimed = False
        for j in resync:
            var box = self.widgets[j]
            if self.rt.shown.nodes[j].kind == GRID:
                built += self.regrid(j, kept, self_addr)
                continue
            if self.rt.shown.nodes[j].kind == BOARD:
                built += self.reboard(j, kept, self_addr)
                continue
            var want = List[Int]()
            for c in self.rt.shown.nodes[j].children.copy():
                if kept[c] >= 0:
                    want.append(self.outers[c])
                else:
                    want.append(self.build_child(j, c, self_addr))
                    built += 1
            var cur = external_call["gtk_widget_get_first_child", Int](box)
            while cur != 0:
                var next = external_call["gtk_widget_get_next_sibling", Int](cur)
                if cur not in want and not is_webview(cur):  # (a WebComponent's view stays: sync_webviews owns it)
                    external_call["gtk_box_remove", NoneType](box, cur)
                cur = next
            var prev = 0
            for child in want:
                if external_call["gtk_widget_get_parent", Int](child) == box:
                    external_call["gtk_box_reorder_child_after", NoneType](box, child, prev)
                else:
                    external_call["gtk_box_insert_child_after", NoneType](box, child, prev)
                prev = child
        var toast_shown = False
        for j in range(n):
            if self.kinds[j] == TOAST and self.widgets[j] == self.toast and self.toast != 0:
                toast_shown = True
        if self.toast != 0 and not toast_shown:  # its node went: the toast goes
            set_node(self.toast, -1)
            external_call["adw_toast_dismiss", NoneType](self.toast)
            external_call["g_object_unref", NoneType](self.toast)
            self.toast = 0
            self.toast_text = ""
        self.toast_claimed = False
        if self.dialog != 0 and self.dialog != dialog_before and (getenv("MOJOUI_TEST") == "" or getenv("MOJOUI_SHOT") != ""):
            external_call["adw_dialog_present", NoneType](self.dialog, self.window)
        for pop in self.popups:  # a new context menu opens once its anchor is in the window
            external_call["gtk_popover_popup", NoneType](pop)
        self.popups = List[Int]()
        if self.reveal_pending >= 0:
            _ = external_call["gtk_widget_add_tick_callback", c_uint](self.window, on_reveal_tick[Self.A], self_addr, 0)
        for j in moving:  # a kept popover whose anchor was built again moves to the new anchor
            var anchor = self.window
            for k in range(n):
                if self.rt.shown.nodes[k].name == self.rt.shown.nodes[j].text and self.widgets[k] != 0:
                    anchor = self.widgets[k]
            external_call["gtk_widget_set_parent", NoneType](self.widgets[j], anchor)
            external_call["g_object_unref", NoneType](self.widgets[j])
            external_call["gtk_popover_popup", NoneType](self.widgets[j])
        if self.key_node < 0 and key_before >= 0:  # the canvas that had the keyboard was built again: the new one has it
            for c in self.canvases:
                if c.keys != 0:
                    self.key_node = c.node
                    break
        var fresh = List[Bool](length=n, fill=False)
        for j in range(n):
            fresh[j] = kept[j] < 0
        self.focus_after_build(fresh)  # (a kept field keeps its text and caret: someone may be typing in it)
        self.apply_patches(patches, self_addr, fresh)
        if self.release_node >= 0:  # a drag ended while this was pending: the app still hears it
            var node = self.release_node
            self.release_node = -1
            for k in range(len(self.canvases)):
                if self.canvases[k].node == node:
                    self.canvas_send(k, RELEASE, self.release_x, self.release_y, 0, 0, 1, self_addr)
                    break
        if self.rt.trace:
            print("TRACE: partial " + ms(perf_counter_ns() - t0) + " built " + String(built) + " of " + String(n) + " in " + String(len(resync)) + " stacks")

    def tell_size(mut self, self_addr: Int):
        """The content area's size, if it changed, goes to the app (App.resize); the screen follows as patches."""
        var area = self.toast_overlay if self.toast_overlay != 0 else self.window
        var w = Int(external_call["gtk_widget_get_width", c_int](area))
        var h = Int(external_call["gtk_widget_get_height", c_int](area))
        if w <= 0 or h <= 0 or (w == self.content_w and h == self.content_h):
            return
        self.content_w = w
        self.content_h = h
        var t0 = perf_counter_ns()
        var d = self.rt.resize(w, h)
        self.trace_diff("resize " + String(w) + "x" + String(h), t0, d)
        self.apply(d, self_addr)

    def scroller_of(self, board: Int) -> Int:
        for bs in self.board_scrollers:
            if bs[0] == board:
                return bs[1]
        return 0

    def reveal(mut self) -> Bool:
        """Scrolls the pending Board so its reveal child shows (clear of the islands). Returns
        False while the page isn't laid out yet (try again next frame)."""
        var i = self.reveal_pending
        if i < 0 or i >= len(self.rt.shown.nodes) or self.rt.shown.nodes[i].kind != BOARD:
            self.reveal_pending = -1
            return True
        ref b = self.rt.shown.nodes[i]
        var k = b.value % 64 - 1
        var sw = self.scroller_of(i)
        if sw == 0 or k < 0 or k >= len(b.children):
            self.reveal_pending = -1
            return True
        var vadj = external_call["gtk_scrolled_window_get_vadjustment", Int](sw)
        var hadj = external_call["gtk_scrolled_window_get_hadjustment", Int](sw)
        var page = external_call["gtk_adjustment_get_page_size", Float64](vadj)
        var upper = external_call["gtk_adjustment_get_upper", Float64](vadj)
        if page <= 0 or (not self.board_list and upper < Float64(b.size)):
            return False
        # where the card really is (on the page, or stacked in the narrow list): its widget's bounds
        var rect = List[Float32](length=4, fill=0)  # graphene_rect_t: x, y, width, height
        var inner = self.widgets[i]
        if external_call["gtk_widget_compute_bounds", c_int](self.widgets[b.children[k]], inner, Int(rect.unsafe_ptr())) == 0:
            return False
        var cx = Float64(rect[0])
        var cy = Float64(rect[1])
        var cw = Float64(rect[2])
        var ch = Float64(rect[3])
        if cw <= 0 or ch <= 0:  # (an object just put on the Board isn't laid out yet: next frame)
            return False
        _ = len(rect)
        var v = external_call["gtk_adjustment_get_value", Float64](vadj)
        if cy < v + 72 or cy + min(ch, page - 160) > v + page - 56:  # (clear of the top and bottom islands)
            external_call["gtk_adjustment_set_value", NoneType](vadj, max(cy - 88, 0.0))
        var hv = external_call["gtk_adjustment_get_value", Float64](hadj)
        var hpage = external_call["gtk_adjustment_get_page_size", Float64](hadj)
        if cx < hv or cx + min(cw, hpage - 48) > hv + hpage:
            external_call["gtk_adjustment_set_value", NoneType](hadj, max(cx - 24, 0.0))
        self.revealed = b.value
        self.reveal_pending = -1
        return True

    def in_view(self, board: Int) -> List[String]:
        """Tags of the Board's children whose header (top-left 44 pt) is inside the visible page."""
        var out = List[String]()
        var sw = self.scroller_of(board)
        if sw == 0:
            return out^
        var vadj = external_call["gtk_scrolled_window_get_vadjustment", Int](sw)
        var hadj = external_call["gtk_scrolled_window_get_hadjustment", Int](sw)
        var v = external_call["gtk_adjustment_get_value", Float64](vadj)
        var vp = external_call["gtk_adjustment_get_page_size", Float64](vadj)
        var h = external_call["gtk_adjustment_get_value", Float64](hadj)
        var hp = external_call["gtk_adjustment_get_page_size", Float64](hadj)
        for c in self.rt.shown.nodes[board].children:
            ref n = self.rt.shown.nodes[c]
            if Float64(n.y) >= v - 1 and Float64(n.y + 44) <= v + vp + 1 and Float64(n.x) >= h - 1 and Float64(n.x + 44) <= h + hp + 1:
                out.append(n.name)
        sort(out)
        return out^

    def install_fonts(mut self):
        """Hands the app's own fonts (mojoui/hosts/static/fonts, copied next to the binary by scripts/build.sh as
        fonts/) to fontconfig, so GTK can use Inter and JetBrains Mono whether or not the system has them (D-155)."""
        var dir = getenv("MOJOUI_FONTS")
        if dir == "":
            var self_exe = String("/proc/self/exe")
            var exe = c_str(external_call["g_file_read_link", Int](self_exe.as_c_string_span(), 0))
            var slash = exe.rfind("/")
            dir = (String(exe[byte=:slash]) if slash > 0 else String(".")) + "/fonts"
        var config = external_call["FcConfigGetCurrent", Int]()
        for name in ["Inter-Regular.ttf", "Inter-Medium.ttf", "Inter-SemiBold.ttf", "JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf",
                     "Geist-Variable.ttf", "GeistMono-Variable.ttf"]:  # (Geist: the omxqua theme, D-331)
            var path = dir + "/" + name
            if external_call["FcConfigAppFontAddFile", c_int](config, path.as_c_string_span()) != 0:
                self.fonts = True

    def apply_design(mut self, self_addr: Int):
        """Styles the window with the app's theme (App.theme()): once at start, and again when it changes (a skin
        picked in Settings, a mode's tint): the old provider goes, the new one loads, so the switch is live (D-156).
        The host knows no theme: no theme is libadwaita as the system has it (D-260)."""
        var theme = self.rt.app.theme()
        var key = theme.key()
        if key == self.skin_key:
            return
        self.skin_key = key
        var display = external_call["gdk_display_get_default", Int]()
        if self.skin_provider != 0:
            external_call["gtk_style_context_remove_provider_for_display", NoneType](display, self.skin_provider)
            external_call["g_object_unref", NoneType](self.skin_provider)
            self.skin_provider = 0
        for old in self.skin_classes.split(" "):
            var name = String(old)
            if name != "":
                external_call["gtk_widget_remove_css_class", NoneType](self.window, name.as_c_string_span())
        self.skin_classes = theme.classes
        var manager = external_call["adw_style_manager_get_default", Int]()
        self.forcing_scheme = True  # (the dark/light change this causes is ours, not the person's: on_dark_changed skips it)
        external_call["adw_style_manager_set_color_scheme", NoneType](manager, c_int((4 if theme.palette.dark else 1) if theme.id != "" else 0))  # a theme: FORCE_DARK / FORCE_LIGHT; none: the system's (DEFAULT)
        self.forcing_scheme = False
        if theme.id == "":  # (back to the system's: tell the app what that is now, on the next idle turn)
            _ = external_call["g_idle_add", c_uint](on_idle_appearance[Self.A], self_addr)
        self.one_line = List[String]()
        self.look = theme.look.copy()
        self.breaks_words = List[String]()
        self.gap_roles = List[String]()
        self.gap_cols = List[Int]()
        for sf in theme.look.surfaces:
            if sf.breaks_words:
                self.breaks_words.append(sf.role)
            if sf.one_line:
                self.one_line.append(sf.role)
            if sf.column_gap >= 0:
                self.gap_roles.append(sf.role)
                self.gap_cols.append(sf.column_gap)
        var sheet = theme.gtk_css + (look_gtk_css(theme.look, "window." + theme.id + " ") if theme.id != "" else String(""))  # (the look's rules after the theme's own)
        if sheet != "":
            self.skin_provider = external_call["gtk_css_provider_new", Int]()
            external_call["gtk_css_provider_load_from_string", NoneType](self.skin_provider, sheet.as_c_string_span())
            external_call["gtk_style_context_add_provider_for_display", NoneType](display, self.skin_provider, c_uint(801))
        for c in theme.classes.split(" "):
            var name = String(c)
            if name != "":
                add_class(self.window, name)
        var ink = theme.id + hex_of(theme.icon_ink) + hex_of(theme.icon_on_accent)
        if ink != self.icons_key:  # (the icons' ink doesn't follow the accent: a tab switch doesn't rewrite them)
            self.icons_key = ink
            install_icons(theme, self.rt.app.logo())
            if self.rt.app.logo() != "" and self.window != 0:
                var icon = String("mojoui-app-logo")
                external_call["gtk_window_set_icon_name", NoneType](self.window, icon.as_c_string_span())  # (the window's icon, where the desktop shows one)

    def apply(mut self, d: Diff, self_addr: Int):
        self.schedule_effects(self_addr)  # (every event comes through here: what it asked for gets its poll)
        self.send_commands(self_addr)  # (and the widget commands it asked for go to their pages)
        self.apply_design(self_addr)
        self.copy_if_asked()
        self.open_if_asked()
        if d.rebuild and d.partial and self.partial_ok and not self.has_pending and len(self.widgets) > 0 and not busy():
            # Only the parts that changed, on the next idle turn (never inside a signal handler: a widget that goes
            # may be the one that sent the signal). Events wait until then.
            self.pending = d.copy()
            self.has_pending = True
            set_busy(True)
            _ = external_call["g_idle_add", c_uint](on_idle_partial[Self.A], self_addr)
            return
        if d.rebuild:
            # Rebuild on the next idle turn, never inside a signal handler: the widget
            # that sent the signal would be destroyed while GTK is still using it.
            self.has_pending = False  # (the full rebuild covers it)
            set_busy(True)  # ignore events until the new widgets are up
            _ = external_call["g_idle_add", c_uint](on_idle_rebuild[Self.A], self_addr)
            return
        if self.has_pending:  # the widgets are still the old screen's: these patches wait for the partial rebuild
            for p in d.patches:
                self.pending.patches.append(p.copy())
            return
        self.apply_patches(d.patches, self_addr)

    def apply_patches(mut self, patches: List[Patch], self_addr: Int, fresh: List[Bool] = List[Bool]()):
        """The patches onto the widgets; then every long list's rows again (fresh: nodes just built, which skip that)."""
        set_busy(True)
        for p in patches:
            var w = self.widgets[p.node]
            var kind = self.rt.shown.nodes[p.node].kind
            if p.op == SET_TEXT:
                var t = p.text
                if kind == TEXT:
                    var shown = label_words(self.rt.shown.nodes, p.node) if self.rt.shown.nodes[p.node].text == t else css_breaks(t)
                    external_call["gtk_label_set_text", NoneType](w, shown.as_c_string_span())
                elif kind == BUTTON and self.rt.shown.nodes[p.node].hint != "":
                    if self.rt.shown.nodes[p.node].style == TOOL or self.rt.shown.nodes[p.node].style == TOOL_ON or self.rt.shown.nodes[p.node].style == TOOL_INLINE or self.rt.shown.nodes[p.node].style == TOOL_INLINE_ON:
                        external_call["gtk_label_set_text", NoneType](external_call["gtk_widget_get_last_child", Int](external_call["gtk_button_get_child", Int](w)), t.as_c_string_span())
                    elif self.rt.shown.nodes[p.node].style == ICON_ONLY or self.rt.shown.nodes[p.node].style == ICON_ON:
                        if self.rt.shown.nodes[p.node].tip == "":  # (a tooltip of its own stays)
                            external_call["gtk_widget_set_tooltip_text", NoneType](w, t.as_c_string_span())
                    else:
                        external_call["adw_button_content_set_label", NoneType](external_call["gtk_button_get_child", Int](w), t.as_c_string_span())
                elif kind == BUTTON or kind == TOGGLE:
                    external_call["gtk_button_set_label", NoneType](w, t.as_c_string_span()) if kind == BUTTON else external_call["gtk_check_button_set_label", NoneType](w, t.as_c_string_span())
                elif kind == FIELD:
                    if c_str(external_call["gtk_editable_get_text", Int](w)) != p.text:  # don't fight the typist
                        external_call["gtk_editable_set_text", NoneType](w, t.as_c_string_span())
            if p.op == SET_TEXT and kind == TABLE:  # which rows are selected
                var cols = max(self.rt.shown.nodes[p.node].value, 1)
                var r = 0
                while True:
                    var first = external_call["gtk_grid_get_child_at", Int](w, c_int(0), c_int(r + 1))
                    if first == 0:
                        break
                    var on = r < p.text.byte_length() and String(p.text[byte=r]) == "1"
                    for k in range(cols):
                        var cell = external_call["gtk_grid_get_child_at", Int](w, c_int(k), c_int(r + 1))
                        if cell != 0:
                            var name = String("mui-tag-table-selected")
                            if on:
                                external_call["gtk_widget_add_css_class", NoneType](cell, name.as_c_string_span())
                            else:
                                external_call["gtk_widget_remove_css_class", NoneType](cell, name.as_c_string_span())
                    r += 1
            if p.op == SET_TEXT and kind == TEXTAREA:
                var buffer = external_call["gtk_text_view_get_buffer", Int](w)
                if buffer_text(buffer) != p.text:  # don't fight the typist
                    var t = p.text
                    external_call["gtk_text_buffer_set_text", NoneType](buffer, t.as_c_string_span(), c_int(-1))
            elif p.op == SET_TEXT and kind == DATE:
                if calendar_date(w) != p.text:
                    calendar_select(w, p.text)
            elif p.op == SET_TEXT and kind == NAVBAR:
                var title = external_call["gtk_widget_get_last_child", Int](w)
                var t = p.text
                external_call["gtk_label_set_text", NoneType](title, t.as_c_string_span())
            elif p.op == SET_VALUE and (kind == SEGMENTED or kind == TABS):
                external_call["adw_toggle_group_set_active", NoneType](w, c_uint(p.number))
            elif p.op == SET_VALUE and kind == RADIO:
                var b = external_call["gtk_widget_get_first_child", Int](w)
                var j = 0
                while b != 0:
                    external_call["gtk_check_button_set_active", NoneType](b, c_int(1 if j == p.number else 0))
                    b = external_call["gtk_widget_get_next_sibling", Int](b)
                    j += 1
            elif p.op == SET_VALUE and kind == TEXT:  # a label's tone changed
                set_tone(w, self.rt.shown.nodes[p.node].value)
            elif p.op == SET_VALUE and kind == BOARD:
                var token = self.rt.shown.nodes[p.node].value
                if token != 0 and token != self.revealed:
                    self.reveal_pending = p.node
                    _ = external_call["gtk_widget_add_tick_callback", c_uint](self.window, on_reveal_tick[Self.A], self_addr, 0)
            elif p.op == SET_VALUE and kind == LAZYLIST:
                pass  # the refresh below hands it a model of the new length
            elif p.op == SET_VALUE:
                if kind == TOGGLE:
                    external_call["gtk_check_button_set_active", NoneType](w, c_int(p.number))
                elif kind == DROPDOWN:
                    external_call["gtk_drop_down_set_selected", NoneType](w, c_uint(p.number))
                elif kind == SLIDER:
                    external_call["gtk_range_set_value", NoneType](w, Float64(p.number))
                elif kind == PROGRESS:
                    external_call["gtk_progress_bar_set_fraction", NoneType](w, Float64(p.number) / 100.0)
            elif p.op == SET_IMAGE:
                ref img = self.rt.shown.nodes[p.node]
                var tex = texture(img.pixels, img.spacing, img.size)
                external_call["gtk_picture_set_paintable", NoneType](w, tex)
                external_call["g_object_unref", NoneType](tex)
            elif p.op == SET_SIZE:
                self.resize_widget(p.node)
            elif p.op == SET_TIP:  # a canvas's words (its tooltip and accessible name), in place: the picture stays
                var tip = p.text
                external_call["gtk_widget_set_tooltip_text", NoneType](w, tip.as_c_string_span())
            elif p.op == SET_PLACE and not self.board_list:  # (a list ignores positions)
                ref n = self.rt.shown.nodes[p.node]
                if kind == BOARD:
                    external_call["gtk_widget_set_size_request", NoneType](w, c_int(n.spacing), c_int(n.size))
                else:
                    for b in self.boards:
                        if b.node == p.node:
                            external_call["gtk_fixed_move", NoneType](b.fixed, b.widget, Float64(n.x), Float64(n.y))
            # SET_MSG needs nothing: events look the message up in rt.shown.
        # Ask for the visible rows of every long list again: row text isn't part of the
        # view, so an edit that keeps the row count wouldn't show otherwise. GTK only
        # re-binds rows whose items changed, so the list gets fresh items (scroll is kept).
        for k in range(len(self.rt.shown.nodes)):
            if self.rt.shown.nodes[k].kind == LAZYLIST and self.widgets[k] != 0 and not (k < len(fresh) and fresh[k]):
                refresh_rows(self.widgets[k], self.rt.shown.nodes[k].value)
        if 0 <= self.echo_node < len(self.rt.shown.nodes) and self.widgets[self.echo_node] != 0:
            # The app answered a field's event with another value than was typed (it cleared the field after Return,
            # say): the field shows the app's. A diff can't see it when the app's own value didn't change.
            ref en = self.rt.shown.nodes[self.echo_node]
            var ew = self.widgets[self.echo_node]
            var want = en.text
            if en.kind == FIELD and want != self.echo_text and c_str(external_call["gtk_editable_get_text", Int](ew)) != want:
                external_call["gtk_editable_set_text", NoneType](ew, want.as_c_string_span())
            elif en.kind == TEXTAREA and want != self.echo_text:
                var buffer = external_call["gtk_text_view_get_buffer", Int](ew)
                if buffer_text(buffer) != want:
                    external_call["gtk_text_buffer_set_text", NoneType](buffer, want.as_c_string_span(), c_int(-1))
        self.echo_node = -1
        self.arm_all(self_addr)  # a new version, frames starting, or a layout change: canvases look again
        self.sync_webviews(self_addr)
        set_busy(False)

    # ---------- WebComponents (goal 34 M3: mojoui/hosts/gtk_webview.mojo) ----------

    def place_webview(mut self, i: Int, box: Int, self_addr: Int):
        """WebComponent node i's view into its box: the one its key (tag, id) already has (moved from the old screen's
        box: it is never loaded again), or a new one. Without WebKitGTK the box keeps its `instead` view."""
        ref n = self.rt.shown.nodes[i]
        if not is_widget_tag(n.hint) or not webviews_start(self.webviews, Self.A.web_assets()):
            return
        var wv = webviews_at(self.webviews)
        var k = wv[].slot_of(n.hint, n.value)
        if k < 0:
            k = new_view(self.webviews, n.hint, n.value, on_webview_message[Self.A], self_addr)
        var view = wv[].slots[k].view
        var parent = external_call["gtk_widget_get_parent", Int](view)
        if parent != box:
            if parent != 0:
                var root = external_call["gtk_widget_get_root", Int](view)
                var focus = external_call["gtk_root_get_focus", Int](root) if root != 0 else 0
                if focus != 0 and (focus == view or external_call["gtk_widget_is_ancestor", c_int](focus, view) != 0):
                    self.webview_focus = view  # (someone is typing in it: the keyboard follows it into the new screen)
                external_call["gtk_box_remove", NoneType](parent, view)
            external_call["gtk_box_append", NoneType](box, view)
        var c = external_call["gtk_widget_get_first_child", Int](box)
        while c != 0:  # (the stand-in stays built, hidden: patches still find it)
            if c != view:
                external_call["gtk_widget_set_visible", NoneType](c, c_int(0))
            c = external_call["gtk_widget_get_next_sibling", Int](c)

    def sync_webviews(mut self, self_addr: Int):
        """After a build or patches: each shown WebComponent's page gets the theme and its props when they changed (JSON,
        through mojoui.native.receive; the widget's update(), never a remount), and views whose key left go."""
        var wv = webviews_at(self.webviews)
        if wv[].state != 1:
            return
        for ref slot in wv[].slots:
            slot.seen = False
        var theme_key = String("")
        var theme_msg = String("")
        for i in range(len(self.rt.shown.nodes)):
            ref n = self.rt.shown.nodes[i]
            if n.kind != WEBCOMP or i >= len(self.widgets) or self.widgets[i] == 0:
                continue
            var k = wv[].slot_of(n.hint, n.value)
            if k < 0:
                continue
            wv[].slots[k].seen = True
            if theme_msg == "":
                var t = self.rt.app.theme()
                theme_key = t.key()
                theme_msg = theme_message(t)
            if wv[].slots[k].theme != theme_key:
                wv[].slots[k].theme = theme_key
                webview_send(self.webviews, k, theme_msg)
            if wv[].slots[k].props != n.text:
                wv[].slots[k].props = n.text
                webview_send(self.webviews, k, '{"widget":{"tag":' + json_string(n.hint) + ',"id":' + String(n.value) + ',"props":' + json_string(n.text) + "}}")
        var k = len(wv[].slots) - 1
        while k >= 0:
            if not wv[].slots[k].seen:
                if wv[].slots[k].view == self.webview_focus:
                    self.webview_focus = 0
                webview_drop(self.webviews, k)
            k -= 1
        if self.webview_focus != 0 and external_call["gtk_widget_get_root", Int](self.webview_focus) != 0:
            _ = external_call["gtk_widget_grab_focus", c_int](self.webview_focus)
            self.webview_focus = 0
        self.send_commands(self_addr)

    def send_commands(mut self, self_addr: Int):
        """The widget commands the app asked for, each to its widget's page; one whose widget isn't on the screen is
        answered with an error (through the inbox, on the next idle turn, as a page's reply is)."""
        var commands = self.rt.take_commands()
        if len(commands) == 0:
            return
        var wv = webviews_at(self.webviews)
        for c in commands:
            var k = wv[].slot_of(c.tag, c.widget) if wv[].state == 1 else -1
            if k >= 0:
                webview_send(self.webviews, k, '{"commands":[' + c.json() + "]}")
            elif c.reply != NO_MSG:
                var why = "no widget " + c.tag + "#" + String(c.widget) + " on the screen" + ("" if wv[].state == 1 else " (WebKitGTK isn't installed)")
                wv[].inbox.append(Inbound(IN_REPLY, c.tag, c.widget, "", "null", c.seq, why))
                arm_webview_inbox[Self.A](self_addr)

    def webview_inbox(mut self, self_addr: Int) -> Bool:
        """Hands the pages' events and replies to update(), in order, while the screen is the shown one (True: some wait)."""
        var wv = webviews_at(self.webviews)
        while len(wv[].inbox) > 0:
            if busy() or self.has_pending:
                return True
            var m = wv[].inbox.pop(0)
            if m.kind == IN_EVENT:  # (by its key, not a node number: the screen may have been rebuilt since, D-595)
                for i in range(len(self.rt.shown.nodes)):
                    if self.rt.shown.nodes[i].kind == WEBCOMP and self.rt.shown.nodes[i].hint == m.tag and self.rt.shown.nodes[i].value == m.id:
                        self.apply(self.rt.widget_event(i, m.name, m.data), self_addr)
                        break
            elif self.rt.knows_reply(m.seq):
                self.apply(self.rt.reply(m.seq, m.data, m.error), self_addr)
        return False

    # ---------- canvases ----------

    def arm(mut self, ci: Int, self_addr: Int):
        """Ticks canvas ci on every display frame until it's idle again (no frames asked for,
        current version drawn at the current size): idle canvases don't wake the CPU."""
        if 0 <= ci < len(self.canvases):
            self.canvases[ci].quiet = 0
        if 0 <= ci < len(self.canvases) and not self.canvases[ci].armed:
            self.canvases[ci].armed = True
            _ = external_call["gtk_widget_add_tick_callback", c_uint](self.canvases[ci].widget, on_tick[Self.A], self_addr, 0)

    def arm_all(mut self, self_addr: Int):
        for k in range(len(self.canvases)):
            self.arm(k, self_addr)

    def idle(self, ci: Int) -> Bool:
        ref c = self.canvases[ci]
        if self.rt.shown.nodes[c.node].msg2 != 0:
            return False
        var w = Int(external_call["gtk_widget_get_width", c_int](c.widget))
        var h = Int(external_call["gtk_widget_get_height", c_int](c.widget))
        return w > 0 and c.drawn == self.rt.shown.nodes[c.node].value and c.wpx == Int(Float64(w) * c.scale + 0.5) and c.hpx == Int(Float64(h) * c.scale + 0.5)

    def canvas_send(mut self, ci: Int, kind: Int, x: Float64, y: Float64, dx: Float64, dy: Float64, zoom: Float64, self_addr: Int):
        if ci < 0 or ci >= len(self.canvases):
            return
        var t0 = perf_counter_ns()
        var d = self.rt.gesture(self.canvases[ci].node, kind, x, y, dx, dy, zoom)
        self.trace_diff("event gesture", t0, d)
        self.apply(d, self_addr)

    def canvas_key(mut self, ci: Int, name: String, modifiers: Int, self_addr: Int):
        if ci < 0 or ci >= len(self.canvases):
            return
        var t0 = perf_counter_ns()
        var d = self.rt.key(self.canvases[ci].node, name, modifiers)
        self.trace_diff("event key " + name, t0, d)
        self.apply(d, self_addr)

    def pointer(self, ci: Int) -> Tuple[Float64, Float64]:
        """Where the pointer is over canvas ci (its centre if it hasn't been seen)."""
        ref c = self.canvases[ci]
        if c.ptr_x >= 0:
            return (c.ptr_x, c.ptr_y)
        return (Float64(Int(external_call["gtk_widget_get_width", c_int](c.widget))) / 2,
                Float64(Int(external_call["gtk_widget_get_height", c_int](c.widget))) / 2)

    def tick(mut self, ci: Int, clock: Int, self_addr: Int) -> Bool:
        """Every display frame: send a frame event if the canvas asked for them, then redraw if
        needed. Returns whether to keep ticking."""
        if ci < 0 or ci >= len(self.canvases):
            return False
        var node = self.canvases[ci].node
        var now = Int(external_call["gdk_frame_clock_get_frame_time", Int64](clock))
        if self.rt.shown.nodes[node].msg2 != 0:
            var last = self.canvases[ci].last_us
            self.canvases[ci].last_us = now
            if self.canvases[ci].frames == 0:
                self.canvases[ci].first_us = now
            self.canvases[ci].frames += 1
            var t0 = perf_counter_ns()
            var d = self.rt.frame(node, now - last if last > 0 else 16667)
            self.trace_diff("event frame", t0, d)
            var widget = self.canvases[ci].widget
            self.apply(d, self_addr)
            if d.rebuild:
                # the new widgets get their own ticks; a canvas a partial rebuild kept loses this callback, so it
                # isn't armed any more (else arm() skips it and its frames stop: maccheck's ticker, 2026-10-22)
                for k in range(len(self.canvases)):
                    if self.canvases[k].widget == widget:
                        self.canvases[k].armed = False
                        self.arm(k, self_addr)
                return False
        else:
            self.canvases[ci].last_us = 0
        self.draw_canvas(ci, self_addr)
        if ci < len(self.canvases) and self.idle(ci):
            self.canvases[ci].quiet += 1
            if self.canvases[ci].quiet >= 30:  # (~0.5 s: lets late relayouts, e.g. lists filling in, settle)
                self.canvases[ci].armed = False
                return False
        elif ci < len(self.canvases):
            self.canvases[ci].quiet = 0
        return True

    def draw_canvas(mut self, ci: Int, self_addr: Int):
        """Asks the app to paint canvas ci at its real pixel size (if its size or version changed)."""
        var widget = self.canvases[ci].widget
        var node = self.canvases[ci].node
        var w = Int(external_call["gtk_widget_get_width", c_int](widget))
        var h = Int(external_call["gtk_widget_get_height", c_int](widget))
        var native = external_call["gtk_widget_get_native", Int](widget)
        if w <= 0 or h <= 0 or native == 0:
            return
        var scale = external_call["gdk_surface_get_scale", Float64](external_call["gtk_native_get_surface", Int](native))
        var wpx = Int(Float64(w) * scale + 0.5)
        var hpx = Int(Float64(h) * scale + 0.5)
        var version = self.rt.shown.nodes[node].value
        if wpx == self.canvases[ci].wpx and hpx == self.canvases[ci].hpx and version == self.canvases[ci].drawn:
            return
        var t0 = perf_counter_ns()
        var again = False
        var d = Diff(False, List[Patch]())
        var t1 = t0
        var drew_scene = False
        if self.scene_mode:  # the display list, drawn by GTK's own renderer (render nodes; GPU on a real display)
            var sc = Scene(0, 0, 1)
            swap(sc, self.canvases[ci].spare)
            sc.reset(wpx, hpx, scale)
            sc.is_still = not animations_enabled()
            var r = self.rt.draw_scene(node, sc)
            if r[0]:
                drew_scene = True
                d = r[1].copy()
                again = sc.again
                t1 = perf_counter_ns()
                self.replay(ci, sc^, wpx, hpx)
        if not drew_scene:
            if len(self.canvases[ci].pixels) != wpx * hpx:
                self.canvases[ci].pixels = List[UInt32](length=wpx * hpx, fill=0)
            var surface = Surface(Int(self.canvases[ci].pixels.unsafe_ptr()), wpx, hpx, scale)
            surface.still = not animations_enabled()  # (GNOME's "reduce animation": animations jump to their end)
            d = self.rt.draw(node, surface)
            again = surface.again
            t1 = perf_counter_ns()
            var tex = texture(self.canvases[ci].pixels, wpx, hpx)
            external_call["gtk_picture_set_paintable", NoneType](widget, tex)
            external_call["g_object_unref", NoneType](tex)
            self.uploads += 1
        self.trace_diff("refresh after draw", t0, d)
        var t2 = perf_counter_ns()
        self.canvases[ci].paint_ms = Float64(Int(t1 - t0)) / 1e6
        self.canvases[ci].upload_ms = Float64(Int(t2 - t1)) / 1e6
        self.canvases[ci].draw_ms = Float64(Int(t2 - t0)) / 1e6
        if self.canvases[ci].keys != 0:
            self.key_draws += 1
            self.key_draw_ms = self.canvases[ci].draw_ms
        self.canvases[ci].wpx = wpx
        self.canvases[ci].hpx = hpx
        self.canvases[ci].scale = scale
        self.canvases[ci].drawn = version if not again else -1  # mid-animation: draw again next frame
        self.canvases[ci].draws += 1
        if self.rt.trace:
            print("TRACE: draw canvas " + String(self.rt.shown.nodes[node].style) + " " + String(wpx) + "x" + String(hpx) + " " + String(self.canvases[ci].draw_ms) + " ms (paint "
                  + String(self.canvases[ci].paint_ms) + ", upload " + String(self.canvases[ci].upload_ms) + ")")
        self.apply(d, self_addr)

    # ---------- the display list (goal 26): render nodes, drawn by GTK's renderer ----------

    def at(self, k: Int) -> Int:
        """The address of scratch float k (structs handed to GTK by pointer)."""
        return Int(self.scratch.unsafe_ptr()) + k * 4

    def put_rgba(mut self, c: UInt32):
        self.scratch[0] = Float32(Int(c & 255)) / 255
        self.scratch[1] = Float32(Int((c >> 8) & 255)) / 255
        self.scratch[2] = Float32(Int((c >> 16) & 255)) / 255
        self.scratch[3] = Float32(Int((c >> 24) & 255)) / 255

    def put_rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        self.scratch[4] = Float32(x)
        self.scratch[5] = Float32(y)
        self.scratch[6] = Float32(w)
        self.scratch[7] = Float32(h)

    def snap_rect(mut self, snap: Int, x: Float64, y: Float64, w: Float64, h: Float64, c: UInt32, radius: Float64):
        if w <= 0 or h <= 0:
            return
        self.put_rgba(c)
        self.put_rect(x, y, w, h)
        if radius <= 0:
            external_call["gtk_snapshot_append_color", NoneType](snap, self.at(0), self.at(4))
            return
        _ = external_call["gsk_rounded_rect_init_from_rect", Int](self.at(8), self.at(4), Float32(radius))  # (12 floats at 8)
        external_call["gtk_snapshot_push_rounded_clip", NoneType](snap, self.at(8))
        external_call["gtk_snapshot_append_color", NoneType](snap, self.at(0), self.at(4))
        external_call["gtk_snapshot_pop", NoneType](snap)

    def layout_of(mut self, text: String, size: Float64, weight: Int, slant: Float64, color: UInt32) -> Int:
        """The text laid out in the app's own fonts (Inter, JetBrains Mono) and turned into a render node once; kept
        for the next frames (a scroll brings a few new rows; everything else is placed again as it was)."""
        if weight != self.key_weight or size != self.key_size or color != self.key_color or slant != self.key_slant:  # (most cells share these)
            self.key_weight = weight
            self.key_size = size
            self.key_color = color
            self.key_slant = slant
            self.key_suffix = "\x1f" + String(weight) + "\x1f" + String(Int(size * 100)) + "\x1f" + String(color) + ("\x1fi" if slant != 0 else "")
        var key = text + self.key_suffix
        var hit = self.layouts.get(key)
        if hit:
            return hit.value()
        self.new_layouts += 1
        var t_new = perf_counter_ns()
        if len(self.layout_nodes) > 30000:  # (scrolled through a lot: start over rather than grow without end)
            for ln in self.layout_nodes:
                if ln != 0:
                    external_call["gsk_render_node_unref", NoneType](ln)
            self.layouts = Dict[String, Int]()
            self.layout_nodes = List[Int]()
            self.layout_w = List[Float64]()
            self.layout_base = List[Float64]()
        if self.pango == 0:
            self.pango = external_call["gtk_widget_create_pango_context", Int](self.window)
        var layout = external_call["pango_layout_new", Int](self.pango)
        var desc = external_call["pango_font_description_new", Int]()
        var family = String("JetBrains Mono") if weight >= 2 else String("Inter")
        external_call["pango_font_description_set_family", NoneType](desc, family.as_c_string_span())
        external_call["pango_font_description_set_weight", NoneType](desc, c_int(500 if weight == 1 else (700 if weight == 3 else 400)))
        external_call["pango_font_description_set_absolute_size", NoneType](desc, Float64(size * 1024))
        if slant != 0:
            external_call["pango_font_description_set_style", NoneType](desc, c_int(2))  # PANGO_STYLE_ITALIC
        external_call["pango_layout_set_font_description", NoneType](layout, desc)
        external_call["pango_font_description_free", NoneType](desc)
        var t = text
        external_call["pango_layout_set_text", NoneType](layout, t.as_c_string_span(), c_int(t.byte_length()))
        var wh = List[Int32](length=2, fill=0)
        external_call["pango_layout_get_pixel_size", NoneType](layout, Int(wh.unsafe_ptr()), Int(wh.unsafe_ptr()) + 4)
        self.put_rgba(color)
        var ts = external_call["gtk_snapshot_new", Int]()
        external_call["gtk_snapshot_append_layout", NoneType](ts, layout, self.at(0))
        self.layout_nodes.append(external_call["gtk_snapshot_free_to_node", Int](ts))
        self.layout_w.append(Float64(Int(wh[0])))
        self.layout_base.append(Float64(Int(external_call["pango_layout_get_baseline", c_int](layout))) / 1024)
        external_call["g_object_unref", NoneType](layout)  # (the layout itself isn't needed again: its node and measures are kept)
        self.layouts[key] = len(self.layout_nodes) - 1
        self.new_layout_ns += Int(perf_counter_ns()) - Int(t_new)
        return len(self.layout_nodes) - 1

    def snap_text(mut self, snap: Int, text: String, x: Float64, baseline: Float64, size: Float64, c: UInt32, weight: Int, align: Int, slant: Float64):
        var li = self.layout_of(text, size, weight, slant, c)
        var node = self.layout_nodes[li]
        if node == 0:
            return
        var tw = self.layout_w[li]
        var base = self.layout_base[li]
        var left = x - (tw if align == 2 else (tw / 2 if align == 1 else 0))
        self.scratch[20] = Float32(left)
        self.scratch[21] = Float32(baseline - base)
        self.scratch[22] = -self.scratch[20]
        self.scratch[23] = -self.scratch[21]
        external_call["gtk_snapshot_translate", NoneType](snap, self.at(20))  # (there and back: cheaper than save/restore)
        external_call["gtk_snapshot_append_node", NoneType](snap, node)
        external_call["gtk_snapshot_translate", NoneType](snap, self.at(22))

    def build_layer(mut self, sc: Scene, i: Int) -> Int:
        """Layer i of the scene as one render node (0 when it draws nothing)."""
        var snap = external_call["gtk_snapshot_new", Int]()
        var r = sc.layer_range(i)
        for op in range(r[0], r[1]):
            var kind = Int(sc.kinds[op])
            var c = sc.colors[op]
            if kind == OP_FILL or kind == OP_RECT:
                self.snap_rect(snap, sc.num(op, 0), sc.num(op, 1), sc.num(op, 2), sc.num(op, 3), c, sc.num(op, 4) if kind == OP_RECT else 0)
            elif kind == OP_CIRCLE:
                var rr = sc.num(op, 2)
                self.snap_rect(snap, sc.num(op, 0) - rr, sc.num(op, 1) - rr, 2 * rr, 2 * rr, c, rr)
            elif kind == OP_LINE:  # (the grid's lines are straight across or down: thin rects)
                var x0 = sc.num(op, 0)
                var y0 = sc.num(op, 1)
                var x1 = sc.num(op, 2)
                var y1 = sc.num(op, 3)
                var lw = max(sc.num(op, 4), 1.0)
                if x0 == x1:
                    self.snap_rect(snap, x0 - lw / 2, min(y0, y1), lw, abs(y1 - y0), c, 0)
                elif y0 == y1:
                    self.snap_rect(snap, min(x0, x1), y0 - lw / 2, abs(x1 - x0), lw, c, 0)
                else:  # (any other line: a stroked path)
                    var b = external_call["gsk_path_builder_new", Int]()
                    external_call["gsk_path_builder_move_to", NoneType](b, Float32(x0), Float32(y0))
                    external_call["gsk_path_builder_line_to", NoneType](b, Float32(x1), Float32(y1))
                    var path = external_call["gsk_path_builder_free_to_path", Int](b)
                    var stroke = external_call["gsk_stroke_new", Int](Float32(lw))
                    self.put_rgba(c)
                    external_call["gtk_snapshot_append_stroke", NoneType](snap, path, stroke, self.at(0))
                    external_call["gsk_stroke_free", NoneType](stroke)
                    external_call["gsk_path_unref", NoneType](path)
            elif kind == OP_CLIP:
                self.put_rect(sc.num(op, 0), sc.num(op, 1), sc.num(op, 2), sc.num(op, 3))
                external_call["gtk_snapshot_push_clip", NoneType](snap, self.at(4))
            elif kind == OP_UNCLIP:
                external_call["gtk_snapshot_pop", NoneType](snap)
            elif kind == OP_IMAGE:  # (pixels made elsewhere: a texture, scaled by the renderer)
                var pw = Int(sc.num(op, 5))
                ref px = sc.images[Int(sc.num(op, 4))]
                var tex = texture(px, pw, len(px) // pw)
                self.put_rect(sc.num(op, 0), sc.num(op, 1), sc.num(op, 2), sc.num(op, 3))
                external_call["gtk_snapshot_append_texture", NoneType](snap, tex, self.at(4))
                external_call["g_object_unref", NoneType](tex)
            elif kind == OP_TEXT:
                self.snap_text(snap, sc.text_at(op), sc.num(op, 0), sc.num(op, 1), sc.num(op, 2), c, Int(sc.num(op, 4)), Int(sc.num(op, 5)), sc.num(op, 3))
        return external_call["gtk_snapshot_free_to_node", Int](snap)

    def release_canvases(mut self, staying: List[Bool]):
        """The render nodes of the canvases that go (all of them when `staying` is empty)."""
        for k in range(len(self.canvases)):
            if k < len(staying) and staying[k]:
                continue
            for n in self.canvases[k].layer_nodes:
                if n != 0:
                    external_call["gsk_render_node_unref", NoneType](n)
            self.canvases[k].layer_nodes = List[Int]()

    def replay(mut self, ci: Int, var sc: Scene, wpx: Int, hpx: Int):
        """The display list onto canvas ci's picture: each layer becomes a render node, and a layer that came again
        unchanged keeps last frame's node (no new nodes, and GTK's renderer sees the same node: nothing to redraw)."""
        var t_replay = perf_counter_ns()
        self.new_layouts = 0
        self.new_layout_ns = 0
        var nodes = List[Int]()
        for i in range(sc.layers()):
            var node = 0
            if i < len(self.canvases[ci].layer_nodes) and i < self.canvases[ci].prev.layers() and sc.same_layer(i, self.canvases[ci].prev, i):
                node = self.canvases[ci].layer_nodes[i]
                if node != 0:
                    _ = external_call["gsk_render_node_ref", Int](node)
                self.nodes_reused += 1
            else:
                node = self.build_layer(sc, i)
                self.nodes_built += 1
                if sc.layer_keys[i] == "cells":
                    self.cells_built += 1
            nodes.append(node)
        var snap = external_call["gtk_snapshot_new", Int]()
        for n in nodes:
            if n != 0:
                external_call["gtk_snapshot_append_node", NoneType](snap, n)
        self.scratch[24] = Float32(wpx)
        self.scratch[25] = Float32(hpx)
        var paintable = external_call["gtk_snapshot_free_to_paintable", Int](snap, self.at(24))
        if paintable != 0:
            external_call["gtk_picture_set_paintable", NoneType](self.canvases[ci].widget, paintable)
            external_call["g_object_unref", NoneType](paintable)
        for n in self.canvases[ci].layer_nodes:
            if n != 0:
                external_call["gsk_render_node_unref", NoneType](n)
        self.canvases[ci].layer_nodes = nodes^
        swap(self.canvases[ci].spare, self.canvases[ci].prev)  # (the old list's memory becomes next frame's)
        if self.rt.trace:
            print("TRACE: replay " + String(sc.ops()) + " ops, " + String(self.new_layouts) + " new layouts in " + ms(self.new_layout_ns) + " ms, all "
                  + ms(Int(perf_counter_ns()) - Int(t_replay)) + " ms")
        self.canvases[ci].prev = sc^

    def copy_if_asked(mut self):
        """A Clipboard view whose version moved on: its text goes on the system clipboard."""
        for ref n in self.rt.shown.nodes:
            if n.kind == CLIPBOARD and n.value > 0 and n.value != self.clip_version:
                self.clip_version = n.value
                var t = n.text
                var display = external_call["gdk_display_get_default", Int]()
                external_call["gdk_clipboard_set_text", NoneType](external_call["gdk_display_get_clipboard", Int](display), t.as_c_string_span())
                self.clip_text = t

    def open_if_asked(mut self):
        """A WebFrame whose version moved on: its page opens in the browser (xdg-open, or the command in $MOJOUI_OPENER)."""
        for ref n in self.rt.shown.nodes:
            if n.kind == EMBED and n.value > 0 and n.value != self.embed_version:
                self.embed_version = n.value
                open_url(n.hint if n.hint != "" else n.text)

    def canvases_drawn(self) -> Bool:
        """Whether every canvas shows its current version at its current size."""
        for ref c in self.canvases:
            var w = Int(external_call["gtk_widget_get_width", c_int](c.widget))
            var h = Int(external_call["gtk_widget_get_height", c_int](c.widget))
            if c.drawn != self.rt.shown.nodes[c.node].value or c.wpx == 0 or c.wpx != Int(Float64(w) * c.scale + 0.5) or c.hpx != Int(Float64(h) * c.scale + 0.5):
                return False
        return True

    def trace_diff(self, what: String, t0: Int, d: Diff):
        """MOJOUI_TRACE: one line per change the app made (its kind and how long the app took)."""
        if self.rt.trace:
            print("TRACE: " + what + " " + ms(perf_counter_ns() - t0) + " nodes " + String(len(self.rt.shown.nodes))
                  + (" REBUILD" if d.rebuild else " patches " + String(len(d.patches))))

    def send(mut self, node: Int, second: Bool, text: String, number: Int, self_addr: Int):
        """A widget changed: build the event, run update(), patch the widgets."""
        ref n = self.rt.shown.nodes[node]
        var message = n.msg2 if second else n.msg
        if message == 0:
            return
        self.focus = node if n.kind == FIELD else -1
        var typed = n.kind == FIELD or n.kind == TEXTAREA
        var t0 = perf_counter_ns()
        var d = self.rt.dispatch(Event(message, text, number))
        self.trace_diff("event " + String(message), t0, d)
        if typed:  # (controlled input: if the app's value isn't what was typed, the field shows the app's)
            self.echo_node = node
            self.echo_text = text
        self.apply(d, self_addr)


def on_drop[A: App](target: Int, value: Int, x: Float64, y: Float64, host_addr: Int) abi("C") -> c_int:
    """A string let go over a DropTarget: its on_drop, with event.text = the string."""
    var node = get_node(target)
    if node < 0 or busy():
        return 0
    var text = c_str(external_call["g_value_get_string", Int](value))
    host_at[A](host_addr)[].send(node, False, text, 0, host_addr)
    return 1


def open_url(url: String):
    """A page in the browser: xdg-open, or the command in $MOJOUI_OPENER (checks read what it was given)."""
    if not is_web_url(url):  # (http and https only, D-576)
        print("mojoui: refused to open " + String(url.split(":")[0]) + ": (not an http or https URL)")
        return
    var opener = getenv("MOJOUI_OPENER")
    if opener == "":
        opener = "xdg-open"
    var u = url
    var quoted = external_call["g_shell_quote", Int](u.as_c_string_span())
    var cmd = opener + " " + c_str(quoted)
    external_call["g_free", NoneType](quoted)
    if external_call["g_spawn_command_line_async", c_int](cmd.as_c_string_span(), Int(0)) == 0:
        print("mojoui: could not run " + cmd)


def on_activate_link[A: App](label: Int, uri: Int, host_addr: Int) abi("C") -> c_int:
    """A Paragraph's link tapped (GTK's activate-link: uri = the run's index, set by pango_markup): its on_link with
    event.number = the run and event.text = its href from the screen; with no on_link, the href opens in the browser."""
    var node = get_node(label)
    var host = host_at[A](host_addr)
    if node < 0 or node >= len(host[].rt.shown.nodes) or busy():
        return 1
    var index = 0
    for c in c_str(uri).as_bytes():
        if c < 48 or c > 57:
            return 1
        index = index * 10 + Int(c - 48)
    var href = link_href(host[].rt.shown.nodes[node], index)
    if href == "":
        return 1
    if host[].rt.shown.nodes[node].msg == 0:
        open_url(href)
        return 1
    host[].send(node, False, href, index, host_addr)
    return 1


def is_webview(widget: Int) -> Bool:
    var key = String("mojoui-webview")
    return external_call["g_object_get_data", Int](widget, key.as_c_string_span()) != 0


def arm_webview_inbox[A: App](host_addr: Int):
    var host = host_at[A](host_addr)
    var wv = webviews_at(host[].webviews)
    if not wv[].armed:
        wv[].armed = True
        _ = external_call["g_idle_add", c_uint](on_webview_inbox[A], host_addr)


def on_webview_message[A: App](ucm: Int, value: Int, host_addr: Int) abi("C"):
    """A page's message (the "mojoui" script message handler): checked in gtk_webview.take_message; events and replies
    reach update() on the next idle turn (never inside WebKit's callback)."""
    var host = host_at[A](host_addr)
    if take_message(host[].webviews, ucm, value):
        arm_webview_inbox[A](host_addr)


def on_webview_inbox[A: App](host_addr: Int) abi("C") -> c_int:
    var host = host_at[A](host_addr)
    if host[].webview_inbox(host_addr):
        return 1  # (the screen is being rebuilt: again on the next idle turn)
    webviews_at(host[].webviews)[].armed = False
    return 0


def host_at[A: App](addr: Int) -> Pointer[GtkHost[A], MutUntrackedOrigin]:
    return Pointer[GtkHost[A], MutUntrackedOrigin](unsafe_from_address=addr)


# ---------- signal handlers (GTK calls these) ----------

def on_live_report[A: App](host_addr: Int) abi("C") -> c_int:
    report[A](host_addr)
    print("LIVE: reported", flush=True)
    return 1  # G_SOURCE_CONTINUE: again at the next signal


def on_effects[A: App](host_addr: Int) abi("C") -> c_int:
    """The runtime's effects are due: replies and ticks go to update(), the screen catches up, the next poll is armed."""
    var host = host_at[A](host_addr)
    host[].fx_source = 0
    if busy():  # (a rebuild is on its way: hand them over just after it)
        host[].fx_due = Int(external_call["g_get_monotonic_time", Int64]()) + 5000
        host[].fx_source = Int(external_call["g_timeout_add_full", c_uint](c_int(G_PRIORITY_DEFAULT_IDLE), c_uint(5), on_effects[A], host_addr, Int(0)))
        return 0
    var t0 = perf_counter_ns()
    var d = host[].rt.poll(Int(external_call["g_get_monotonic_time", Int64]()))
    if len(d.patches) > 0 or d.rebuild:
        host[].trace_diff("event effects", t0, d)
    host[].apply(d, host_addr)  # (arms the next poll)
    return 0  # G_SOURCE_REMOVE: each poll arms its own


def on_idle_partial[A: App](host_addr: Int) abi("C") -> c_int:
    var host = host_at[A](host_addr)
    if host[].has_pending:  # (a full rebuild may have come first)
        host[].update_part(host_addr)  # update_part() clears the busy flag (apply_patches)
    return 0


def on_idle_rebuild[A: App](host_addr: Int) abi("C") -> c_int:
    host_at[A](host_addr)[].show(host_addr)  # show() clears the busy flag
    return 0  # G_SOURCE_REMOVE: run once


def intervals(times: List[Int]) -> List[Float64]:
    """The gaps between consecutive frames (ms); a pause over 100 ms (the bench waiting) isn't a frame interval."""
    var out = List[Float64]()
    for k in range(1, len(times)):
        var g = Float64(times[k] - times[k - 1]) / 1e6
        if g > 0 and g < 100:
            out.append(g)
    return out^


def share_within(xs: List[Float64], limit: Float64) -> Float64:
    """The share (percent) of xs at or under limit (frames on time for 120 Hz: 9.5 ms, a little slack on 8.3)."""
    if len(xs) == 0:
        return 0
    var n = 0
    for x in xs:
        if x <= limit:
            n += 1
    return 100.0 * Float64(n) / Float64(len(xs))


def pct(xs: List[Float64], q: Float64) -> Float64:
    """The q-th quantile of xs (0 when empty)."""
    if len(xs) == 0:
        return 0
    var v = xs.copy()
    sort(v)
    return v[min(len(v) - 1, Int(q * Float64(len(v))))]


def settle():
    """Runs pending GTK work (such as a deferred rebuild) before the next test step; at most a second of it, so a view
    that draws every frame (an island while work runs in the background) doesn't hold the steps until the work ends."""
    var by = perf_counter_ns() + 1_000_000_000
    while external_call["g_main_context_pending", c_int](0) != 0 and perf_counter_ns() < by:
        _ = external_call["g_main_context_iteration", c_int](0, c_int(0))

def on_reveal_tick[A: App](widget: Int, clock: Int, host_addr: Int) abi("C") -> c_int:
    """Each frame until the Board is laid out: scroll its reveal child into view, then stop."""
    return 0 if host_at[A](host_addr)[].reveal() else 1


def on_tick[A: App](widget: Int, clock: Int, host_addr: Int) abi("C") -> c_int:
    if busy():
        return 1  # G_SOURCE_CONTINUE: try again next frame
    return 1 if host_at[A](host_addr)[].tick(get_index(widget), clock, host_addr) else 0  # 0: G_SOURCE_REMOVE


# (These two only set flags and add tick callbacks, so they're safe even while the host is busy.)
def on_window_resized[A: App](window: Int, pspec: Int, host_addr: Int) abi("C"):
    host_at[A](host_addr)[].arm_all(host_addr)  # canvases redraw at their new size
    queue_resize[A](host_addr)


def on_popover_map(popover: Int, data: Int) abi("C"):
    """A popover just showed: on the next idle turn (it can't take focus while it's still mapping) its first control
    takes the keyboard, so arrows move through its choices and Return picks one, as in a native menu."""
    _ = external_call["g_object_ref", Int](popover)  # (held until the idle turn: a rebuild may drop it before then)
    _ = external_call["g_idle_add", c_uint](on_popover_focus, popover)


def on_popover_focus(popover: Int) abi("C") -> c_int:
    if external_call["gtk_widget_get_mapped", c_int](popover) != 0:
        _ = external_call["gtk_widget_child_focus", c_int](popover, c_int(0))  # GTK_DIR_TAB_FORWARD
    external_call["g_object_unref", NoneType](popover)
    return 0


def on_popover_key(controller: Int, keyval: c_uint, keycode: c_uint, state: c_uint, popover: Int) abi("C") -> c_int:
    """Up and Down move between a popover's controls (a popover isn't a window: GTK gives it no arrow keys)."""
    if keyval == 0xff54:  # Down
        _ = external_call["gtk_widget_child_focus", c_int](popover, c_int(0))  # GTK_DIR_TAB_FORWARD
        return 1
    if keyval == 0xff52:  # Up
        _ = external_call["gtk_widget_child_focus", c_int](popover, c_int(1))  # GTK_DIR_TAB_BACKWARD
        return 1
    return 0


def on_dark_changed[A: App](styles: Int, pspec: Int, host_addr: Int) abi("C"):
    """The system went dark or light: App.appearance on the next idle turn (this signal can fire inside apply_design,
    which the host's own scheme changes cause: those it skips)."""
    if host_at[A](host_addr)[].forcing_scheme:
        return
    _ = external_call["g_idle_add", c_uint](on_idle_appearance[A], host_addr)


def on_idle_appearance[A: App](host_addr: Int) abi("C") -> c_int:
    """Tells the app the system's light or dark (App.appearance); the canvases draw again. Once (G_SOURCE_REMOVE)."""
    var host = host_at[A](host_addr)
    if busy():  # (a rebuild is under way: try again in 50 ms, rather than spinning on every idle turn)
        _ = external_call["g_timeout_add", c_uint](c_uint(50), on_idle_appearance[A], host_addr)
        return 0
    var styles = external_call["adw_style_manager_get_default", Int]()
    var dark = external_call["adw_style_manager_get_dark", c_int](styles) != 0
    if (1 if dark else 0) == host[].dark_told:  # (the app already knows: nothing to redo, no list re-bound)
        return 0
    host[].dark_told = 1 if dark else 0
    var d = host[].rt.appearance(dark)
    host[].arm_all(host_addr)
    if d.rebuild or len(d.patches) > 0:
        host[].apply(d, host_addr)
    return 0


comptime UNMEASURED = 10000  # a measured view's clamp before fit_measures has measured it


def on_clock_layout[A: App](clock: Int, host_addr: Int) abi("C"):
    if not busy():
        host_at[A](host_addr)[].fit_tables()
        host_at[A](host_addr)[].fit_measures()


def on_surface_layout[A: App](surface: Int, width: c_int, height: c_int, host_addr: Int) abi("C"):
    host_at[A](host_addr)[].arm_all(host_addr)  # the compositor resized the window (e.g. tiling)
    queue_resize[A](host_addr)


def queue_resize[A: App](host_addr: Int):
    """Tells the app the window's new size on the next idle turn (once, however many signals came)."""
    if app_data("mojoui-resize-queued") == 0:
        set_app_data("mojoui-resize-queued", 1)
        _ = external_call["g_idle_add", c_uint](on_idle_resize[A], host_addr)


def on_idle_resize[A: App](host_addr: Int) abi("C") -> c_int:
    if busy():
        return 1  # G_SOURCE_CONTINUE: after the widgets are up
    set_app_data("mojoui-resize-queued", 0)
    host_at[A](host_addr)[].tell_size(host_addr)
    return 0


def on_before_paint[A: App](clock: Int, host_addr: Int) abi("C"):
    host_at[A](host_addr)[].paint_t0 = Int(perf_counter_ns())


def on_after_paint[A: App](clock: Int, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    if host[].paint_t0 > 0:
        host[].frame_paints.append(Float64(Int(perf_counter_ns()) - host[].paint_t0) / 1e6)
        host[].frame_times.append(Int(external_call["gdk_frame_clock_get_frame_time", Int64](clock)) * 1000)
        if len(host[].frame_times) > 4096:
            host[].frame_times = List[Int]()
        if len(host[].frame_paints) > 4096:
            host[].frame_paints = List[Float64]()


def on_window_realize[A: App](window: Int, host_addr: Int) abi("C"):
    var clock = external_call["gtk_widget_get_frame_clock", Int](window)
    if clock != 0 and host_at[A](host_addr)[].rt.trace:  # (MOJOUI_TRACE: the paint phase of every frame, for bench steps)
        connect(clock, "before-paint", on_before_paint[A], host_addr)
        connect(clock, "after-paint", on_after_paint[A], host_addr)
    if clock != 0:  # (after each layout: tables share their width as the web's do)
        connect(clock, "layout", on_clock_layout[A], host_addr)
    var surface = external_call["gtk_native_get_surface", Int](window)
    if surface != 0:
        connect_any(surface, "layout", on_surface_layout[A], host_addr)
        connect3(surface, "notify::scale", on_window_resized[A], host_addr)  # moved to a screen with another scale


def on_drag_begin[A: App](drag: Int, x: Float64, y: Float64, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    var ci = get_index(drag)
    if ci < 0 or ci >= len(host[].canvases):
        return
    host[].canvases[ci].drag_x = 0
    host[].canvases[ci].drag_y = 0
    host[].canvases[ci].start_x = x
    host[].canvases[ci].start_y = y
    host[].canvases[ci].moved = False
    if host[].canvases[ci].keys != 0:  # keys go to the canvas pressed last
        _ = external_call["gtk_widget_grab_focus", c_int](host[].canvases[ci].widget)
        host[].key_node = host[].canvases[ci].node
    if not busy():
        host[].canvas_send(ci, PRESS, x, y, Float64(mods_of(drag)), 0, 1, host_addr)  # where a drag (or a tap) starts (dx: modifiers)


def on_drag_end[A: App](drag: Int, off_x: Float64, off_y: Float64, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    var ci = get_index(drag)
    if busy():  # (mid-update: the release still counts; it's sent once the widgets are up, if they stay)
        if 0 <= ci < len(host[].canvases) and host[].canvases[ci].moved and host[].has_pending:
            host[].release_node = host[].canvases[ci].node
            host[].release_x = host[].canvases[ci].start_x + off_x
            host[].release_y = host[].canvases[ci].start_y + off_y
        return
    if ci < 0 or ci >= len(host[].canvases) or not host[].canvases[ci].moved:
        return  # (a plain tap: the click gesture sends TAP)
    host[].canvas_send(ci, RELEASE, host[].canvases[ci].start_x + off_x, host[].canvases[ci].start_y + off_y, 0, 0, 1, host_addr)


def on_drag_update[A: App](drag: Int, off_x: Float64, off_y: Float64, host_addr: Int) abi("C"):
    if busy():
        return
    var host = host_at[A](host_addr)
    var ci = get_index(drag)
    if ci < 0 or ci >= len(host[].canvases):
        return
    var dx = off_x - host[].canvases[ci].drag_x
    var dy = off_y - host[].canvases[ci].drag_y
    host[].canvases[ci].drag_x = off_x
    host[].canvases[ci].drag_y = off_y
    if abs(off_x) + abs(off_y) > 3:
        host[].canvases[ci].moved = True
    # where the pointer is now: the drag's start plus its offset (exact, and the same in test runs)
    host[].canvas_send(ci, PAN, host[].canvases[ci].start_x + off_x, host[].canvases[ci].start_y + off_y, dx, dy, 1, host_addr)


def on_scroll[A: App](scroll: Int, dx: Float64, dy: Float64, host_addr: Int) abi("C") -> c_int:
    """Mouse wheel / touchpad scroll: zoom around the pointer (4 notches = 2×)."""
    if busy():
        return 1
    var host = host_at[A](host_addr)
    var ci = get_index(scroll)
    if ci < 0 or ci >= len(host[].canvases) or dy == 0:
        return 1
    var at = host[].pointer(ci)
    # A mouse wheel scrolls in notches; touchpads in surface pixels (100 px = 4 notches = 2×).
    var notches = dy / 25.0 if external_call["gtk_event_controller_scroll_get_unit", c_int](scroll) == 1 else dy
    host[].canvas_send(ci, ZOOM, at[0], at[1], 0, 0, 2.0 ** (-notches / 4.0), host_addr)
    return 1


def on_motion[A: App](motion: Int, x: Float64, y: Float64, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    var ci = get_index(motion)
    if 0 <= ci < len(host[].canvases):
        host[].canvases[ci].ptr_x = x
        host[].canvases[ci].ptr_y = y


def on_pinch_begin[A: App](pinch: Int, sequence: Int, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    var ci = get_index(pinch)
    if 0 <= ci < len(host[].canvases):
        host[].canvases[ci].pinch = 1


def on_pinch[A: App](pinch: Int, scale: Float64, host_addr: Int) abi("C"):
    if busy() or scale <= 0:
        return
    var host = host_at[A](host_addr)
    var ci = get_index(pinch)
    if ci < 0 or ci >= len(host[].canvases):
        return
    var factor = scale / host[].canvases[ci].pinch
    host[].canvases[ci].pinch = scale
    var xy = List[Float64](length=2, fill=0)
    if external_call["gtk_gesture_get_bounding_box_center", c_int](pinch, Int(xy.unsafe_ptr()), Int(xy.unsafe_ptr()) + 8) == 0:
        var at = host[].pointer(ci)
        xy[0] = at[0]
        xy[1] = at[1]
    host[].canvas_send(ci, ZOOM, xy[0], xy[1], 0, 0, factor, host_addr)
    _ = len(xy)


comptime GDK_NAMES: List[String] = ["Down", "Up", "Left", "Right", "Return", "KP_Enter", "Escape", "Tab", "ISO_Left_Tab",
                                     "BackSpace", "Delete", "Page_Down", "Page_Up", "Home", "End"]
comptime KEY_NAMES: List[String] = ["ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight", "Enter", "Enter", "Escape", "Tab", "Tab",
                                    "Backspace", "Delete", "PageDown", "PageUp", "Home", "End"]


def key_name(keyval: Int) -> String:
    """A GDK key as the web names it ("ArrowDown", "Enter", …), or the character it types."""
    var gdk = c_str(external_call["gdk_keyval_name", Int](c_uint(keyval)))
    var gdk_names = materialize[GDK_NAMES]()
    var names = materialize[KEY_NAMES]()
    for i in range(len(gdk_names)):
        if gdk == gdk_names[i]:
            return names[i]
    if gdk.startswith("F") and gdk.byte_length() <= 3 and gdk != "F":
        return gdk  # F1 … F12
    var cp = Int(external_call["gdk_keyval_to_unicode", c_uint](c_uint(keyval)))
    if cp >= 32 and cp != 127:
        return chr(cp)
    return gdk  # Shift_L, Control_L, … (apps ignore them)


def gdk_keyval(name: String) -> Int:
    """The other way (test steps): a web key name or a character → a GDK keyval."""
    var gdk_names = materialize[GDK_NAMES]()
    var names = materialize[KEY_NAMES]()
    for i in range(len(names)):
        if name == names[i]:
            var g = gdk_names[i]
            return Int(external_call["gdk_keyval_from_name", c_uint](g.as_c_string_span()))
    if name.startswith("F") and name.byte_length() <= 3 and name != "F":
        var f = name
        return Int(external_call["gdk_keyval_from_name", c_uint](f.as_c_string_span()))
    for ch in name.codepoint_slices():
        return Int(external_call["gdk_unicode_to_keyval", c_uint](c_uint(Int(ord(String(ch))))))
    return 0


def holds_keyboard(w: Int) -> Bool:
    """The window's keyboard focus is w or inside it (a GtkEntry focuses its own inner text widget)."""
    var root = external_call["gtk_widget_get_root", Int](w)
    if root == 0:
        return False
    var f = external_call["gtk_root_get_focus", Int](root)
    return f != 0 and (f == w or Int(external_call["gtk_widget_is_ancestor", c_int](f, w)) != 0)


def on_key_pressed[A: App](keys: Int, keyval: c_uint, keycode: c_uint, state: c_uint, host_addr: Int) abi("C") -> c_int:
    if busy():
        return c_int(0)
    var host = host_at[A](host_addr)
    var ci = get_index(keys)
    if ci < 0 or ci >= len(host[].canvases):
        return c_int(0)
    var s = Int(state)
    var mods = (SHIFT if (s & 1) != 0 else 0) + (CTRL if (s & 4) != 0 else 0) + (ALT if (s & 8) != 0 else 0)
    var name = key_name(Int(keyval))
    host[].canvas_key(ci, name, mods, host_addr)
    # handled (so Tab and the arrows don't move focus away), except shortcuts the window may own
    return c_int(0 if (mods & (CTRL | ALT)) != 0 and name != "Home" and name != "End" else 1)


def on_field_key[A: App](keys: Int, keyval: c_uint, keycode: c_uint, state: c_uint, host_addr: Int) abi("C") -> c_int:
    """Escape in a field with on_cancel."""
    if busy() or key_name(Int(keyval)) != "Escape":
        return c_int(0)
    var host = host_at[A](host_addr)
    var node = get_node(keys)
    if node < 0 or node >= len(host[].widgets) or host[].widgets[node] == 0:
        return c_int(0)
    var text = c_str(external_call["gtk_editable_get_text", Int](host[].widgets[node]))
    var d = host[].rt.cancel(node, text)
    host[].apply(d, host_addr)
    return c_int(1)


def on_secondary_released[A: App](click: Int, presses: c_int, x: Float64, y: Float64, host_addr: Int) abi("C"):
    """A right click on a canvas: SECONDARY at (x, y), where the app may open a context menu."""
    if busy():
        return
    var host = host_at[A](host_addr)
    var ci = get_index(click)
    if ci < 0 or ci >= len(host[].canvases):
        return
    host[].canvas_send(ci, SECONDARY, x, y, 0, 0, 1, host_addr)


def on_item_clicked[A: App](button: Int, host_addr: Int) abi("C"):
    """A menu item: close the menu it's in, then send its message like a button."""
    if busy():
        return
    var host = host_at[A](host_addr)
    var popover = external_call["gtk_widget_get_ancestor", Int](button, external_call["gtk_popover_get_type", Int]())
    while popover != 0:  # a submenu's popover sits inside the menu's: close them all
        var outer = external_call["gtk_widget_get_parent", Int](popover)
        set_node(popover, -1)  # (closing by choosing isn't on_close)
        external_call["gtk_popover_popdown", NoneType](popover)
        popover = external_call["gtk_widget_get_ancestor", Int](outer, external_call["gtk_popover_get_type", Int]()) if outer != 0 else 0
    var node = get_node(button)
    if node >= 0:
        host[].send(node, False, "", 0, host_addr)


def on_menu_closed[A: App](popover: Int, host_addr: Int) abi("C"):
    """A context menu or popover dismissed (a click elsewhere, Escape): the app's on_close takes it out of the view."""
    if busy():
        return
    var node = get_node(popover)
    if node < 0:
        return
    var host = host_at[A](host_addr)
    if node < len(host[].rt.shown.nodes) and (host[].rt.shown.nodes[node].kind == MENU or host[].rt.shown.nodes[node].kind == POPOVER):
        host[].send(node, True, "", 0, host_addr)


def on_overlay_close[A: App](button: Int, host_addr: Int) abi("C"):
    """A dialog's ✕: on_close."""
    if busy():
        return
    var node = get_node(button)
    var host = host_at[A](host_addr)
    if node >= 0:
        host[].send(node, True, "", 0, host_addr)


def on_dialog_closed[A: App](dialog: Int, host_addr: Int) abi("C"):
    """A dialog closed by Escape (or its ✕): on_close, unless the screen is being replaced."""
    if busy():
        return
    var node = get_node(dialog)
    if node < 0:
        return
    var host = host_at[A](host_addr)
    if node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].kind == DIALOG:
        host[].send(node, True, "", 0, host_addr)


def on_toast_action[A: App](toast: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var node = get_node(toast)
    if node >= 0:
        host_at[A](host_addr)[].send(node, False, "", 0, host_addr)


def on_toast_dismissed[A: App](toast: Int, host_addr: Int) abi("C"):
    """The toast's time ran out (or its ✕): on_close takes it out of the view."""
    if busy():
        return
    var node = get_node(toast)
    var host = host_at[A](host_addr)
    if node >= 0 and node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].kind == TOAST:
        host[].send(node, True, "", 0, host_addr)


def shortcut_name(keyval: Int, state: Int) -> String:
    """A key press as a menu shortcut ("Ctrl+Shift+S", "F5"); "" when it's plain typing."""
    var ctrl = state & 4 != 0
    var shift = state & 1 != 0
    var alt = state & 8 != 0
    var name = key_name(keyval)
    var fkey = name.startswith("F") and name.byte_length() <= 3 and name != "F"
    if not (ctrl or alt or fkey):
        return ""
    if name.byte_length() == 1:
        name = name.upper()
    elif name == ",":
        name = ","
    return ("Ctrl+" if ctrl else "") + ("Shift+" if shift else "") + ("Alt+" if alt else "") + name


def on_shortcut_pressed[A: App](controller: Int, keyval: c_uint, keycode: c_uint, state: c_uint, host_addr: Int) abi("C") -> c_int:
    """A key pressed anywhere in the window: the menu item declaring it as its shortcut fires (and the key stops here)."""
    if busy():
        return 0
    var name = shortcut_name(Int(keyval), Int(state))
    if name == "":
        return 0
    var host = host_at[A](host_addr)
    if name == "Ctrl+C" or name == "Ctrl+X" or name == "Ctrl+V" or name == "Ctrl+A" or name == "Ctrl+Z":
        var focus = external_call["gtk_root_get_focus", Int](host[].window)
        if focus != 0 and (external_call["g_type_check_instance_is_a", c_int](focus, external_call["gtk_editable_get_type", Int]()) != 0
                           or external_call["g_type_check_instance_is_a", c_int](focus, external_call["gtk_text_view_get_type", Int]()) != 0):
            return 0  # a text field's own copy, cut, paste, select all and undo
    for i in range(len(host[].rt.shown.nodes)):
        ref n = host[].rt.shown.nodes[i]
        if n.kind == ITEM and len(n.options) > 0 and n.options[0] == name and n.value & DISABLED == 0 and n.msg != 0:
            host[].send(i, False, "", 0, host_addr)
            return 1
    return 0


def animations_enabled() -> Bool:
    """GtkSettings' gtk-enable-animations (off when the person asked for less motion)."""
    var settings = external_call["gtk_settings_get_default", Int]()
    if settings == 0:
        return True
    var on = List[c_int](length=1, fill=1)
    var name = String("gtk-enable-animations")
    external_call["g_object_get", NoneType, num_fixed_args=2](settings, name.as_c_string_span(), Int(on.unsafe_ptr()), 0)
    var result = on[0] != 0
    _ = len(on)
    return result


def mods_of(controller: Int) -> Int:
    """SHIFT, CTRL and ALT held during the controller's current event (a Shift+click extends a selection)."""
    var st = Int(external_call["gtk_event_controller_get_current_event_state", c_uint](controller))
    return (SHIFT if (st & 1) != 0 else 0) + (CTRL if (st & 4) != 0 else 0) + (ALT if (st & 8) != 0 else 0)


def on_click_released[A: App](click: Int, presses: c_int, x: Float64, y: Float64, host_addr: Int) abi("C"):
    if busy():
        return
    var host = host_at[A](host_addr)
    var ci = get_index(click)
    if ci < 0 or ci >= len(host[].canvases) or host[].canvases[ci].moved:
        return
    host[].canvas_send(ci, DOUBLE if presses == 2 else TAP, x, y, Float64(mods_of(click)), 0, 1, host_addr)  # (the first click of a double was a TAP; dx: modifiers)


def board_object[A: App](host: Pointer[GtkHost[A], MutUntrackedOrigin], drag: Int) -> Int:
    """The object this board gesture is dragging (its index in host.boards), or -1."""
    var bi = get_index(drag)
    while 0 <= bi < len(host[].boards) and host[].boards[bi].drag == drag:
        if host[].boards[bi].active:
            return bi
        bi += 1
    return -1


def on_board_drag_begin[A: App](drag: Int, x: Float64, y: Float64, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    var first = get_index(drag)
    if first < 0 or first >= len(host[].boards):
        return
    var last = first
    while last + 1 < len(host[].boards) and host[].boards[last + 1].drag == drag:
        last += 1
    var bi = last  # the topmost object under the pointer (later children draw above earlier ones)
    while bi >= first:
        ref b = host[].boards[bi]
        ref n = host[].rt.shown.nodes[b.node]
        var w = Float64(Int(external_call["gtk_widget_get_width", c_int](b.widget)))
        var h = Float64(Int(external_call["gtk_widget_get_height", c_int](b.widget)))
        var lx = x - Float64(n.x)
        var ly = y - Float64(n.y)
        if 0.0 <= lx and lx < w and 0.0 <= ly and ly < h:
            if n.kind == FIELD:  # an in-place editor floating on the page: it's typed in, never dragged
                external_call["gtk_gesture_set_state", c_int](drag, c_int(2))
                return
            host[].boards[bi].resizing = lx > w - 24 and ly > h - 24
            host[].boards[bi].active = host[].boards[bi].resizing or ly < 44  # the header moves it; the rest is the object's own
            if not host[].boards[bi].active:
                external_call["gtk_gesture_set_state", c_int](drag, c_int(2))  # GTK_EVENT_SEQUENCE_DENIED
            return
        bi -= 1
    external_call["gtk_gesture_set_state", c_int](drag, c_int(2))  # nothing under it


def on_board_drag_update[A: App](drag: Int, off_x: Float64, off_y: Float64, host_addr: Int) abi("C"):
    if busy():
        return
    var host = host_at[A](host_addr)
    var bi = board_object[A](host, drag)
    if bi < 0:
        return
    ref b = host[].boards[bi]
    ref n = host[].rt.shown.nodes[b.node]
    if b.resizing:  # live feedback; the app decides the final size on drag-end
        external_call["gtk_widget_set_size_request", NoneType](b.widget, c_int(max(n.w + Int(off_x), 120)), c_int(max(n.h + Int(off_y), 80)))
    else:
        external_call["gtk_fixed_move", NoneType](b.fixed, b.widget, Float64(max(n.x + Int(off_x), 0)), Float64(max(n.y + Int(off_y), 0)))


def on_board_drag_end[A: App](drag: Int, off_x: Float64, off_y: Float64, host_addr: Int) abi("C"):
    if busy():
        return
    var host = host_at[A](host_addr)
    var bi = board_object[A](host, drag)
    if bi < 0:
        return
    host[].boards[bi].active = False
    var b = host[].boards[bi].copy()
    var d = host[].rt.gesture(b.board, ZOOM if b.resizing else PAN, Float64(b.index), 0, off_x, off_y, 1)
    host[].apply(d, host_addr)


def on_clicked[A: App](button: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var host = host_at[A](host_addr)
    var node = get_node(button)
    if 0 <= node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].msg2 != 0:  # a FilePicker: the platform's file dialog
        host[].picker_node = node
        var dialog = external_call["gtk_file_dialog_new", Int]()
        var title = host[].rt.shown.nodes[node].text
        external_call["gtk_file_dialog_set_title", NoneType](dialog, title.as_c_string_span())
        var accept = host[].rt.shown.nodes[node].options[0] if len(host[].rt.shown.nodes[node].options) > 0 else String("")
        if accept != "":  # the picker's file types (".csv,.omx") as the dialog's filter
            var filter = external_call["gtk_file_filter_new", Int]()
            var name = String("Files it opens (") + accept + ")"
            external_call["gtk_file_filter_set_name", NoneType](filter, name.as_c_string_span())
            for ext in accept.split(","):
                var suffix = String(String(ext).strip().lstrip("."))
                if suffix != "":
                    external_call["gtk_file_filter_add_suffix", NoneType](filter, suffix.as_c_string_span())
            external_call["gtk_file_dialog_set_default_filter", NoneType](dialog, filter)
            external_call["g_object_unref", NoneType](filter)
        external_call["gtk_file_dialog_open", NoneType](dialog, host[].window, 0, on_file_picked[A], host_addr)
        return
    host[].send(node, False, "", 0, host_addr)


def on_file_picked[A: App](dialog: Int, result: Int, host_addr: Int) abi("C"):
    """The file dialog closed: its file's path goes to the FilePicker's on_pick (nothing if cancelled)."""
    var host = host_at[A](host_addr)
    var err = List[Int](length=1, fill=0)
    var file = external_call["gtk_file_dialog_open_finish", Int](dialog, result, Int(err.unsafe_ptr()))
    if err[0] != 0:
        external_call["g_error_free", NoneType](err[0])  # (cancelled, or the dialog failed)
    external_call["g_object_unref", NoneType](dialog)
    if file == 0:
        return
    var raw = external_call["g_file_get_path", Int](file)
    var path = c_str(raw)
    external_call["g_free", NoneType](raw)
    external_call["g_object_unref", NoneType](file)
    var node = host[].picker_node
    if path != "" and 0 <= node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].msg2 != 0:
        host[].send(node, True, path, 0, host_addr)


def on_field_changed[A: App](entry: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var text = c_str(external_call["gtk_editable_get_text", Int](entry))
    host_at[A](host_addr)[].send(get_node(entry), False, text, 0, host_addr)


def on_field_submit[A: App](entry: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var text = c_str(external_call["gtk_editable_get_text", Int](entry))
    host_at[A](host_addr)[].send(get_node(entry), True, text, 0, host_addr)


def on_toggled[A: App](check: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var on = Int(external_call["gtk_check_button_get_active", c_int](check))
    host_at[A](host_addr)[].send(get_node(check), False, "", on, host_addr)


def on_selected[A: App](dropdown: Int, pspec: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var index = Int(external_call["gtk_drop_down_get_selected", c_uint](dropdown))
    var host = host_at[A](host_addr)
    var node = get_node(dropdown)
    var text = String("")
    if index < len(host[].rt.shown.nodes[node].options):
        text = host[].rt.shown.nodes[node].options[index]
    host[].send(node, False, text, index, host_addr)


def on_toggle_group[A: App](group: Int, pspec: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var host = host_at[A](host_addr)
    var node = get_node(group)
    var index = Int(external_call["adw_toggle_group_get_active", c_uint](group))
    ref opts = host[].rt.shown.nodes[node].options
    if index < 0 or index >= len(opts):
        return
    host[].send(node, False, opts[index], index, host_addr)


def on_radio[A: App](button: Int, host_addr: Int) abi("C"):
    if busy() or external_call["gtk_check_button_get_active", c_int](button) == 0:
        return  # (the button being switched off also fires)
    var host = host_at[A](host_addr)
    var node = get_node(button)
    var index = get_index(button)
    host[].send(node, False, host[].rt.shown.nodes[node].options[index], index, host_addr)


def on_text_changed[A: App](buffer: Int, host_addr: Int) abi("C"):
    if busy():
        return
    host_at[A](host_addr)[].send(get_node(buffer), False, buffer_text(buffer), 0, host_addr)


def on_alert_response[A: App](dialog: Int, response: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var host = host_at[A](host_addr)
    var node = get_node(dialog)
    if node < 0 or node >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[node].kind != ALERT:
        return  # (an alert the app already took away)
    var index = 0
    try:
        index = Int(c_str(response))
    except:
        return
    if index < 0 or index >= len(host[].rt.shown.nodes[node].options):
        return
    host[].send(node, False, host[].rt.shown.nodes[node].options[index], index, host_addr)


def pin_key() -> String:
    return "mojoui-unpinned"


def on_pin_changed(adj: Int, data: Int) abi("C"):
    """A pinned Scroll's content (or size) changed: back to its end, unless the person scrolled up."""
    var key = pin_key()
    if external_call["g_object_get_data", Int](adj, key.as_c_string_span()) != 0:
        return
    var end = external_call["gtk_adjustment_get_upper", Float64](adj) - external_call["gtk_adjustment_get_page_size", Float64](adj)
    if external_call["gtk_adjustment_get_value", Float64](adj) != end:
        external_call["gtk_adjustment_set_value", NoneType](adj, end)


def on_pin_moved(adj: Int, data: Int) abi("C"):
    """It scrolled: away from the end it stops following; back at the end it follows again."""
    var key = pin_key()
    var end = external_call["gtk_adjustment_get_upper", Float64](adj) - external_call["gtk_adjustment_get_page_size", Float64](adj)
    var away = end - external_call["gtk_adjustment_get_value", Float64](adj) > 4.0
    external_call["g_object_set_data", NoneType](adj, key.as_c_string_span(), 1 if away else 0)


def on_day_selected[A: App](cal: Int, host_addr: Int) abi("C"):
    if busy():
        return
    host_at[A](host_addr)[].send(get_node(cal), False, calendar_date(cal), 0, host_addr)


def on_row_setup[A: App](factory: Int, item: Int, host_addr: Int) abi("C"):
    var empty = String("")
    var label = external_call["gtk_label_new", Int](empty.as_c_string_span())
    external_call["gtk_label_set_xalign", NoneType](label, Float32(0))
    external_call["gtk_widget_set_margin_start", NoneType](label, c_int(12))
    external_call["gtk_widget_set_margin_top", NoneType](label, c_int(10))
    external_call["gtk_widget_set_margin_bottom", NoneType](label, c_int(10))
    external_call["gtk_list_item_set_child", NoneType](item, label)
    count_up("mojoui-rows-built")  # a row widget was made (GTK reuses them while scrolling)


def on_row_bind[A: App](factory: Int, item: Int, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    var node = get_node(factory)
    if node < 0 or node >= len(host[].rt.shown.nodes):
        return
    var position = Int(external_call["gtk_list_item_get_position", c_uint](item))
    var text = host[].rt.app.row(host[].rt.shown.nodes[node].msg2, position)  # asked for on demand
    count_up("mojoui-rows-bound")
    # Track the range of rows drawn since the last refresh (stored +1; 0 = none yet).
    var app = external_call["g_application_get_default", Int]()
    var lo = String("mojoui-bound-lo")
    var hi = String("mojoui-bound-hi")
    var low = external_call["g_object_get_data", Int](app, lo.as_c_string_span())
    if low == 0 or position + 1 < low:
        external_call["g_object_set_data", NoneType](app, lo.as_c_string_span(), position + 1)
    if position + 1 > external_call["g_object_get_data", Int](app, hi.as_c_string_span()):
        external_call["g_object_set_data", NoneType](app, hi.as_c_string_span(), position + 1)
    if position == 0:  # (for the test report: what row 0 shows right now)
        var key = String("mojoui-row0")
        var app = external_call["g_application_get_default", Int]()
        var free_name = String("g_free")
        var g_free = external_call["dlsym", Int](0, free_name.as_c_string_span())
        external_call["g_object_set_data_full", NoneType](app, key.as_c_string_span(),
            external_call["g_strdup", Int](text.as_c_string_span()), g_free)
        var owner = String("mojoui-row0-item")
        external_call["g_object_set_data", NoneType](app, owner.as_c_string_span(), item)
    var label = external_call["gtk_list_item_get_child", Int](item)
    external_call["gtk_label_set_text", NoneType](label, text.as_c_string_span())


def on_row_unbind(factory: Int, item: Int, host_addr: Int) abi("C"):
    var owner = String("mojoui-row0-item")
    var app = external_call["g_application_get_default", Int]()
    if external_call["g_object_get_data", Int](app, owner.as_c_string_span()) == item:  # row 0's widget left
        var key = String("mojoui-row0")
        external_call["g_object_set_data", NoneType](app, key.as_c_string_span(), 0)
        external_call["g_object_set_data", NoneType](app, owner.as_c_string_span(), 0)


def on_row_activate[A: App](list: Int, position: Int, host_addr: Int) abi("C"):
    if busy():
        return
    # `position` is a C guint: only the low 32 bits of the register are defined.
    host_at[A](host_addr)[].send(get_node(list), False, "", position & 0xFFFFFFFF, host_addr)


def on_slid[A: App](scale: Int, host_addr: Int) abi("C"):
    if busy():
        return
    var value = Int(external_call["gtk_range_get_value", Float64](scale) + 0.5)
    host_at[A](host_addr)[].send(get_node(scale), False, "", value, host_addr)


# ---------- test mode ----------

def find(host: GtkHost, kind: Int, label: String, nth: Int, by_hint: Bool = False) -> Int:
    """The nth node of `kind` whose text (or hint) is `label` ("" = any). Canvases count the content's: the island
    (window chrome, mojoui.island) is left out of the numbers and found by its tag (canvas_node)."""
    var seen = 0
    for i in range(len(host.rt.shown.nodes)):
        ref n = host.rt.shown.nodes[i]
        var name = n.hint if by_hint else n.text
        if kind == CANVAS and n.name == "island":
            continue
        if n.kind == kind and (label == "" or name == label):
            if seen == nth:
                return i
            seen += 1
    return -1


def canvas_node(host: GtkHost, which: String) -> Int:
    """A canvas step's target: the nth content canvas ("0", "1"…) or the canvas tagged `which` ("island")."""
    var digits = which != ""
    for c in which.codepoints():
        if c < Codepoint.ord("0") or c > Codepoint.ord("9"):
            digits = False
    if digits:
        return find(host, CANVAS, "", to_int(which))
    for i in range(len(host.rt.shown.nodes)):
        if host.rt.shown.nodes[i].kind == CANVAS and host.rt.shown.nodes[i].name == which:
            return i
    return -1


def first_label(w: Int) -> Int:
    """The first GtkLabel at or under widget w (depth first), 0 if none."""
    if w == 0:
        return 0
    if external_call["g_type_check_instance_is_a", c_int](w, external_call["gtk_label_get_type", Int]()) != 0:
        return w
    var c = external_call["gtk_widget_get_first_child", Int](w)
    while c != 0:
        var found = first_label(c)
        if found != 0:
            return found
        c = external_call["gtk_widget_get_next_sibling", Int](c)
    return 0


def report_menu_rows(host: GtkHost, menu: Int):
    """MENUROW: title height font-size for each item of an open menu (submenus included): rows must share one height and type."""
    for c in host.rt.shown.nodes[menu].children:
        ref n = host.rt.shown.nodes[c]
        if n.kind != ITEM or n.style != 0 or c >= len(host.widgets) or host.widgets[c] == 0:
            continue
        var w = host.widgets[c]
        if external_call["gtk_widget_get_mapped", c_int](w) != 0:
            var label = first_label(w)
            var size = Int(external_call["gtk_widget_get_height", c_int](label)) if label != 0 else 0  # (a label's height: its type's size and line)
            print("MENUROW: " + n.text + " " + String(Int(external_call["gtk_widget_get_height", c_int](w))) + " " + String(size))
        if len(n.children) > 0:
            report_menu_rows(host, c)


def report_buttons(host: GtkHost, node: Int, tag: String):
    """BOX: tag/Title for each button inside tagged container `node` (not inside a tagged container within it): the
    checks measure tools and remove buttons without tagging them (a tag renames a button's agent tool, D-228)."""
    for c in host.rt.shown.nodes[node].children:
        ref n = host.rt.shown.nodes[c]
        if n.kind == BUTTON and c < len(host.widgets) and host.widgets[c] != 0:
            var rect = List[Float32](length=4, fill=0)
            if external_call["gtk_widget_compute_bounds", c_int](host.widgets[c], host.window, Int(rect.unsafe_ptr())) != 0 and rect[2] > 0:
                print("BOX: " + tag + "/" + n.text + " " + one_decimal(rect[0]) + " " + one_decimal(rect[1]) + " " + one_decimal(rect[2]) + " " + one_decimal(rect[3]))
            _ = len(rect)
        elif n.name == "":
            report_buttons(host, c, tag)


def find_item(host: GtkHost, menu: Int, title: String) -> Int:
    """The ITEM node titled `title` inside menu node `menu` (submenus included)."""
    for c in host.rt.shown.nodes[menu].children:
        ref n = host.rt.shown.nodes[c]
        if n.kind == ITEM and n.text == title and n.style == 0 and len(n.children) == 0:
            return c
        if len(n.children) > 0:
            var inner = find_item(host, c, title)
            if inner >= 0:
                return inner
    return -1


def split_at(s: String, sep: String) -> Tuple[String, String]:
    var i = s.find(sep)
    if i < 0:
        return (s, String(""))
    return (String(s[byte=:i]), String(s[byte = i + sep.byte_length() :]))


def to_int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


def pump():
    """One turn of the main loop for a test's wait, never sleeping past its caller's deadline: a blocking turn waits
    for the next event, and with nothing scheduled (no timer, no frame asked for, as when the island has settled) that
    is forever, so the caller's deadline is never read again (a 15-minute hang in goal 14's save run, D-286)."""
    if external_call["g_main_context_iteration", c_int](0, c_int(0)) == 0:
        sleep(0.001)


def wait_frame(window: Int):
    """Lets the shown window's frame clock tick once (up to 300 ms), so a step's layout (a new tab
    page, a rebuilt board) is allocated before the next step or the report measures it. On X11 the
    tick is a timer, which `settle()` (pending work only) doesn't wait for."""
    var clock = external_call["gtk_widget_get_frame_clock", Int](window)
    if clock == 0:
        return
    var before = external_call["gdk_frame_clock_get_frame_counter", Int64](clock)
    external_call["gdk_frame_clock_request_phase", NoneType](clock, c_int(1 << 3))  # GDK_FRAME_CLOCK_PHASE_LAYOUT
    var deadline = perf_counter_ns() + 300_000_000
    while external_call["gdk_frame_clock_get_frame_counter", Int64](clock) == before and perf_counter_ns() < deadline:
        pump()


def wait_allocated(widget: Int):
    """Runs pending main-loop work until the widget has a size (the first step may come before the
    first layout pass). Never blocks: an unshown test window has nothing pending, so it gives up."""
    var deadline = perf_counter_ns() + 3_000_000_000
    while external_call["gtk_widget_get_width", c_int](widget) == 0 and perf_counter_ns() < deadline:
        if external_call["g_main_context_iteration", c_int](0, c_int(0)) == 0:
            return  # nothing pending: nothing will change


def run_step[A: App](host_addr: Int, step: String):
    var host = host_at[A](host_addr)
    var verb_rest = split_at(step, ":")
    var verb = verb_rest[0]
    var rest = verb_rest[1]
    if verb == "tap":
        var t = split_at(rest, "@")
        var i = find(host[], BUTTON, t[0], to_int(t[1]))
        if i < 0:
            print("TEST: no button", rest)
            return
        var s = String("clicked")
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[i], s.as_c_string_span())
    elif verb == "pick":  # pick:Title=/path: a FilePicker's dialog returning that file (a native dialog can't be driven)
        var kv = split_at(rest, "=")
        var i = find(host[], BUTTON, kv[0], 0)
        if i < 0 or host[].rt.shown.nodes[i].msg2 == 0:
            print("TEST: no file picker", kv[0])
            return
        host[].send(i, True, kv[1], 0, host_addr)
    elif verb == "type" or verb == "submit" or verb == "enter":
        var kv = split_at(rest, "=")
        var i = find(host[], FIELD, kv[0], 0, by_hint=True)
        if i < 0:
            print("TEST: no field", kv[0])
            return
        if verb == "type" or verb == "enter":
            var t = kv[1]
            external_call["gtk_editable_set_text", NoneType](host[].widgets[i], t.as_c_string_span())
        if verb == "submit" or verb == "enter":  # "enter": Return straight after typing
            var s = String("activate")
            external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[i], s.as_c_string_span())
    elif verb == "link":  # link:Text: a Paragraph's link of that text, through the label's own activate-link signal (as a click sends it)
        var found = False
        for i in range(len(host[].rt.shown.nodes)):
            if host[].rt.shown.nodes[i].kind != PARAGRAPH:
                continue
            var runs = runs_of(host[].rt.shown.nodes[i])
            for k in range(len(runs)):
                if runs[k].href != "" and runs[k].text == rest and not found:
                    found = True
                    var s = String("activate-link")
                    var uri = String(k)
                    var ret = List[c_int](length=1, fill=0)
                    external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[i], s.as_c_string_span(), uri.as_c_string_span(), Int(ret.unsafe_ptr()))
                    _ = len(ret)
        if not found:
            print("TEST: no link", rest)
    elif verb == "tick":  # tick:TAG: the tick box tagged TAG (a table's row has no label to find it by)
        var i = -1
        for k in range(len(host[].rt.shown.nodes)):
            if host[].rt.shown.nodes[k].kind == TOGGLE and host[].rt.shown.nodes[k].name == rest:
                i = k
                break
        if i < 0:
            print("TEST: no tick box", rest)
            return
        var w = host[].widgets[i]
        var on = external_call["gtk_check_button_get_active", c_int](w)
        external_call["gtk_check_button_set_active", NoneType](w, c_int(1) - on)
    elif verb == "dragto":  # dragto:SRC=DST: the Draggable tagged SRC's content (read from its GtkDragSource) dropped on the
        var kv = split_at(rest, "=")  # DropTarget tagged DST through its GtkDropTarget's drop handler (a pointer drag can't be driven headless)
        var si = -1
        var di = -1
        for k in range(len(host[].rt.shown.nodes)):
            ref n = host[].rt.shown.nodes[k]
            if n.kind == DRAG and n.name == kv[0]:
                si = k
            if n.kind == DROP and n.name == kv[1]:
                di = k
        if si < 0 or di < 0:
            print("TEST: no draggable", kv[0], "or drop target", kv[1])
            return
        var key = String(DRAG_KEY)
        var src = external_call["g_object_get_data", Int](host[].widgets[si], key.as_c_string_span())
        var dkey = String(DROP_KEY)
        var target = external_call["g_object_get_data", Int](host[].widgets[di], dkey.as_c_string_span())
        var gv = List[Int](length=3, fill=0)
        _ = external_call["g_value_init", Int](Int(gv.unsafe_ptr()), Int(G_TYPE_STRING))
        var provider = external_call["gtk_drag_source_get_content", Int](src)
        if src == 0 or target == 0 or external_call["gdk_content_provider_get_value", c_int](provider, Int(gv.unsafe_ptr()), Int(0)) == 0:
            print("TEST: the drag source holds no text")
            return
        _ = on_drop[A](target, Int(gv.unsafe_ptr()), 0, 0, host_addr)
        external_call["g_value_unset", NoneType](Int(gv.unsafe_ptr()))
        _ = gv[0]  # (keeps the GValue's memory alive through the calls above)
    elif verb == "toggle":
        var i = find(host[], TOGGLE, rest, 0)
        if i < 0:
            print("TEST: no toggle", rest)
            return
        var w = host[].widgets[i]
        var on = external_call["gtk_check_button_get_active", c_int](w)
        external_call["gtk_check_button_set_active", NoneType](w, c_int(1) - on)
    elif verb == "select":
        var kv = split_at(rest, "=")
        var i = find(host[], DROPDOWN, "", to_int(kv[0]))
        if i < 0:
            print("TEST: no dropdown", kv[0])
            return
        var index = -1
        ref opts = host[].rt.shown.nodes[i].options
        for j in range(len(opts)):
            if opts[j] == kv[1]:
                index = j
        if index < 0:
            print("TEST: no option", kv[1])
            return
        external_call["gtk_drop_down_set_selected", NoneType](host[].widgets[i], c_uint(index))
    elif verb == "slide":
        var kv = split_at(rest, "=")
        var i = find(host[], SLIDER, "", to_int(kv[0]))
        if i < 0:
            print("TEST: no slider", kv[0])
            return
        external_call["gtk_range_set_value", NoneType](host[].widgets[i], Float64(to_int(kv[1])))
    elif verb == "segment" or verb == "tab" or verb == "radio":
        var kv = split_at(rest, "=")
        var kind = SEGMENTED if verb == "segment" else (TABS if verb == "tab" else RADIO)
        var i = find(host[], kind, "", to_int(kv[0]))
        if i < 0:
            print("TEST: no", verb, kv[0])
            return
        var index = -1
        ref opts = host[].rt.shown.nodes[i].options
        for j in range(len(opts)):
            if opts[j] == kv[1]:
                index = j
        if index < 0:
            print("TEST: no option", kv[1])
            return
        if kind == RADIO:
            var b = external_call["gtk_widget_get_first_child", Int](host[].widgets[i])
            for _ in range(index):
                b = external_call["gtk_widget_get_next_sibling", Int](b)
            external_call["gtk_check_button_set_active", NoneType](b, c_int(1))
        else:
            external_call["adw_toggle_group_set_active", NoneType](host[].widgets[i], c_uint(index))
    elif verb == "textarea":
        var kv = split_at(rest, "=")
        var i = find(host[], TEXTAREA, "", to_int(kv[0]))
        if i < 0:
            print("TEST: no textarea", kv[0])
            return
        var t = kv[1].replace("\\n", "\n")
        var buffer = external_call["gtk_text_view_get_buffer", Int](host[].widgets[i])
        external_call["gtk_text_buffer_set_text", NoneType](buffer, t.as_c_string_span(), c_int(-1))
    elif verb == "menu":  # menu:File>Save: the bar's File menu's Save item; menu:>Item: the open context menu's item
        var t = split_at(rest, ">")
        var menu = -1
        for k in range(len(host[].rt.shown.nodes)):
            ref n = host[].rt.shown.nodes[k]
            if n.kind == MENU and ((t[0] == "" and n.style == 1) or (t[0] != "" and n.style == 0 and n.text == t[0])):
                menu = k
        if menu < 0:
            print("TEST: no menu", t[0])
            return
        var item = find_item(host[], menu, t[1])
        if item < 0:
            print("TEST: no menu item", t[1])
            return
        var s = String("clicked")
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[item], s.as_c_string_span())
    elif verb == "glide":  # glide:Down: a key on the grid (the first canvas that takes keys), then frames until its ring settles
        var gi = -1
        for k in range(len(host[].canvases)):
            if host[].canvases[k].keys != 0:
                gi = k
                break
        if gi < 0:
            print("TEST: no canvas takes keys")
            return
        var name = "Arrow" + rest if rest == "Down" or rest == "Up" or rest == "Left" or rest == "Right" else rest
        var ready_by = perf_counter_ns() + 1_000_000_000  # (the ring must be on screen before it can glide)
        while host[].canvases[gi].drawn != host[].rt.shown.nodes[host[].canvases[gi].node].value and perf_counter_ns() < ready_by:
            _ = external_call["g_main_context_iteration", c_int](0, c_int(0))
            sleep(0.002)
        host[].canvas_key(gi, name, 0, host_addr)
        var before = host[].key_draws
        var worst = 0.0
        var until = perf_counter_ns() + 2_000_000_000
        var last = before
        while Int(perf_counter_ns()) < until:
            _ = external_call["g_main_context_iteration", c_int](0, c_int(0))
            if host[].key_draws != last:
                last = host[].key_draws
                worst = max(worst, host[].key_draw_ms)
            var settled = True
            for ref cv in host[].canvases:
                if cv.keys != 0 and cv.drawn != host[].rt.shown.nodes[cv.node].value:
                    settled = False
            if settled and last > before:
                break
            sleep(0.002)
        var done = True
        for ref cv in host[].canvases:
            if cv.keys != 0 and cv.drawn != host[].rt.shown.nodes[cv.node].value:
                done = False
        print("GLIDE: frames " + String(host[].key_draws - before) + " max_ms " + one_decimal(Float32(worst)) + " settled " + ("yes" if done else "no"))
    elif verb == "bench":  # bench:scroll=60 / bench:glide=10: the grid scrolls 3 rows a frame (or moves the selection) that many times; percentiles of the costs
        var kv = split_at(rest, "=")
        var count = to_int(kv[1])
        var gi = -1
        for k in range(len(host[].canvases)):
            if host[].canvases[k].keys != 0:
                gi = k
        if gi < 0:
            print("TEST: no canvas takes keys")
            return
        var ready_by = perf_counter_ns() + 2_000_000_000
        while perf_counter_ns() < ready_by:  # (from a quiet window: the grid drawn, and no canvas still moving, such as the
            var quiet = host[].canvases[gi].drawn == host[].rt.shown.nodes[host[].canvases[gi].node].value  # island's morph to the
            for ref cv in host[].canvases:  # document after Create table, whose frames would count as the bench's uploads)
                if cv.armed:
                    quiet = False
            if quiet:
                break
            pump()
        var paints = List[Float64]()
        var uploads = List[Float64]()
        host[].frame_paints = List[Float64]()
        host[].frame_times = List[Int]()
        var draws0 = host[].canvases[gi].draws
        host[].nodes_built = 0
        host[].nodes_reused = 0
        host[].cells_built = 0
        host[].uploads = 0
        var t_start = perf_counter_ns()
        for _ in range(count):
            var before = host[].canvases[gi].draws
            if kv[0] == "scroll":
                var w = Float64(Int(external_call["gtk_widget_get_width", c_int](host[].canvases[gi].widget)))
                host[].canvas_send(gi, PAN, w / 2, 200, 0, -3 * 26, 1, host_addr)
            else:
                host[].canvas_key(gi, "ArrowDown", 0, host_addr)
            var by = perf_counter_ns() + 1_000_000_000
            while perf_counter_ns() < by:  # (until it has drawn and settled: a glide draws several frames)
                _ = external_call["g_main_context_iteration", c_int](0, c_int(0))
                if host[].canvases[gi].draws != before:
                    paints.append(host[].canvases[gi].paint_ms)
                    uploads.append(host[].canvases[gi].upload_ms)
                    before = host[].canvases[gi].draws
                if host[].canvases[gi].drawn == host[].rt.shown.nodes[host[].canvases[gi].node].value and not host[].canvases[gi].armed:
                    break
        var secs = Float64(Int(perf_counter_ns() - t_start)) / 1e9
        var c = host[].canvases[gi].copy()
        print("BENCH: " + kv[0] + " " + String(count) + " at " + String(c.wpx) + "x" + String(c.hpx) + " px draws " + String(c.draws - draws0)
              + " paint p50 " + one_decimal(Float32(pct(paints, 0.5))) + " p95 " + one_decimal(Float32(pct(paints, 0.95)))
              + " upload p50 " + one_decimal(Float32(pct(uploads, 0.5))) + " p95 " + one_decimal(Float32(pct(uploads, 0.95)))
              + " frame-paint p50 " + one_decimal(Float32(pct(host[].frame_paints, 0.5))) + " p95 " + one_decimal(Float32(pct(host[].frame_paints, 0.95)))
              + " interval p50 " + one_decimal(Float32(pct(intervals(host[].frame_times), 0.5))) + " p99 " + one_decimal(Float32(pct(intervals(host[].frame_times), 0.99)))
              + " within-9.5ms " + one_decimal(Float32(share_within(intervals(host[].frame_times), 9.5))) + "%"
              + " cells built " + String(host[].cells_built) + " uploads " + String(host[].uploads)
              + " layers built " + String(host[].nodes_built) + " reused " + String(host[].nodes_reused) + " seconds " + one_decimal(Float32(secs)))
    elif verb == "webjs":  # webjs:<tag>#<id>=<expression>: its value (awaited) in that widget's page, printed as JS: <json>
        var kv = split_at(rest, "=")
        var key = split_at(kv[0], "#")
        var wv = webviews_at(host[].webviews)
        var k = wv[].slot_of(key[0], to_int(key[1])) if wv[].state == 1 else -1
        if k < 0:
            print("TEST: no web view", kv[0])
            return
        webview_probe(host[].webviews, k, kv[1])
        var by = perf_counter_ns() + 10_000_000_000
        while not webviews_at(host[].webviews)[].probe_done and perf_counter_ns() < by:
            pump()
        print("JS: " + (webviews_at(host[].webviews)[].probe_result if webviews_at(host[].webviews)[].probe_done else String('"timed out"')))
    elif verb == "pause":  # pause:3000: keep the main loop running that long (a screen grab of the display can catch popovers)
        var until = perf_counter_ns() + to_int(rest) * 1_000_000
        while Int(perf_counter_ns()) < until:
            _ = external_call["g_main_context_iteration", c_int](0, c_int(0))
            sleep(0.01)
    elif verb == "open":  # open:Format, open:Format>Text colour: pops the bar's menu (or its submenu) up and leaves it open, for screenshots
        var t = split_at(rest, ">")
        var menu = -1
        for k in range(len(host[].rt.shown.nodes)):
            ref n = host[].rt.shown.nodes[k]
            if n.kind == MENU and n.style == 0 and n.text == t[0]:
                menu = k
        if menu < 0:
            print("TEST: no menu", t[0])
            return
        var target = menu
        if t[1] != "":
            target = -1
            for c in host[].rt.shown.nodes[menu].children:
                if host[].rt.shown.nodes[c].text == t[1] and len(host[].rt.shown.nodes[c].children) > 0:
                    target = c
        if target < 0:
            print("TEST: no menu item", t[1])
            return
        external_call["gtk_menu_button_popup", NoneType](host[].widgets[target])
    elif verb == "toast":  # toast:Undo: the toast's button, through its own signal
        var i = find(host[], TOAST, "", 0)
        if i < 0 or host[].toast == 0 or len(host[].rt.shown.nodes[i].options) == 0 or host[].rt.shown.nodes[i].options[0] != rest:
            print("TEST: no toast with", rest)
            return
        var s = String("button-clicked")
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].toast, s.as_c_string_span())
    elif verb == "dismiss":  # dismiss: Escape on what floats: a popover or context menu closes, else the dialog
        var done = False
        var floating = List[Int]()  # (closing one sends on_close, which replaces the screen: collect first)
        for k in range(len(host[].rt.shown.nodes)):
            ref n = host[].rt.shown.nodes[k]
            if (n.kind == POPOVER or (n.kind == MENU and n.style == 1)) and k < len(host[].widgets) and host[].widgets[k] != 0:
                floating.append(host[].widgets[k])
        for pop in floating:
            external_call["gtk_popover_popdown", NoneType](pop)
            done = True
        if not done and host[].dialog != 0:
            _ = external_call["adw_dialog_close", c_int](host[].dialog)
            done = True
        if not done:
            print("TEST: nothing to dismiss")
    elif verb == "shortcut":  # shortcut:Ctrl+S: the window's key controller's own signal, as a real press sends it
        var name = rest
        var state = 0
        while True:
            if name.startswith("Ctrl+"):
                state |= 4
                var cut = String(name[byte=5:])
                name = cut
            elif name.startswith("Shift+"):
                state |= 1
                var cut = String(name[byte=6:])
                name = cut
            elif name.startswith("Alt+"):
                state |= 8
                var cut = String(name[byte=4:])
                name = cut
            else:
                break
        var keyval = gdk_keyval(name.lower() if name.byte_length() == 1 else name)
        var handled = List[c_int](length=1, fill=0)
        var signal = String("key-pressed")
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].shortcut_keys, signal.as_c_string_span(), c_uint(keyval), c_uint(0), c_uint(state), Int(handled.unsafe_ptr()))
        if handled[0] == 0:
            print("TEST: no item with shortcut", rest)
        _ = len(handled)
    elif verb == "rightclick":  # rightclick:K=fx,fy: the right button's click gesture's own signal at (x, y) thousandths
        var kv = split_at(rest, "=")
        var node = canvas_node(host[], kv[0])
        var ci = -1
        for k in range(len(host[].canvases)):
            if host[].canvases[k].node == node:
                ci = k
        if ci < 0:
            print("TEST: no canvas", kv[0])
            return
        var xy = split_at(kv[1], ",")
        var cw = Float64(Int(external_call["gtk_widget_get_width", c_int](host[].canvases[ci].widget)))
        var chh = Float64(Int(external_call["gtk_widget_get_height", c_int](host[].canvases[ci].widget)))
        var released = String("released")
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].secondary, released.as_c_string_span(), c_int(1),
            Float64(to_int(xy[0])) / 1000.0 * cw, Float64(to_int(xy[1])) / 1000.0 * chh)
    elif verb == "alert":
        var i = find(host[], ALERT, "", 0)
        if i < 0:
            print("TEST: no alert")
            return
        var index = -1
        ref opts = host[].rt.shown.nodes[i].options
        for j in range(len(opts)):
            if opts[j] == rest:
                index = j
        var id = String(index)
        if rest == "Escape":  # what AdwAlertDialog sends on Escape: its close response
            id = c_str(external_call["adw_alert_dialog_get_close_response", Int](host[].widgets[i]))
        elif index < 0:
            print("TEST: no alert button", rest)
            return
        var signal = String("response")
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[i], signal.as_c_string_span(), id.as_c_string_span())
    elif verb == "back":
        var i = find(host[], NAVBAR, "", 0)
        if i < 0:
            print("TEST: no navbar")
            return
        var back = external_call["gtk_widget_get_first_child", Int](host[].widgets[i])
        if host[].rt.shown.nodes[i].msg == 0 or back == external_call["gtk_widget_get_last_child", Int](host[].widgets[i]):
            print("TEST: no back button")
            return
        var s = String("clicked")
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](back, s.as_c_string_span())
    elif verb == "date":
        var kv = split_at(rest, "=")
        var i = find(host[], DATE, "", to_int(kv[0]))
        if i < 0:
            print("TEST: no date picker", kv[0])
            return
        calendar_select(host[].widgets[i], kv[1])
        if calendar_date(host[].widgets[i]) == kv[1] and host[].rt.shown.nodes[i].text != kv[1]:
            var s = String("day-selected")  # make sure the selection is reported like a click
            external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[i], s.as_c_string_span())
    elif verb == "scroll" or verb == "row":
        var kv = split_at(rest, "=")
        var i = find(host[], LAZYLIST, "", to_int(kv[0]))
        if i < 0:
            print("TEST: no list", kv[0])
            return
        var position = to_int(kv[1])
        if verb == "scroll":
            external_call["gtk_list_view_scroll_to", NoneType](host[].widgets[i], c_uint(position), c_int(0), 0)
        else:
            var s = String("activate")
            external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[i], s.as_c_string_span(), c_uint(position))
    elif verb == "key" or verb == "typekeys":  # the key controller's own signal, as a real key press sends it
        var kv = split_at(rest, "=")
        var node = canvas_node(host[], kv[0])
        var ci = -1
        for k in range(len(host[].canvases)):
            if host[].canvases[k].node == node:
                ci = k
        if ci < 0:
            print("TEST: no canvas", kv[0])
            return
        var presses = List[String]()
        var state = 0
        if verb == "typekeys":  # typekeys:K=text: one press per character
            for ch in kv[1].codepoint_slices():
                var c = String(ch)
                presses.append("Enter" if c == "⏎" else ("Escape" if c == "⎋" else c))  # (⏎ Enter, ⎋ Escape, as in drive.py)
        else:  # key:K=shift+ctrl+Name
            var name = kv[1]
            while True:
                if name.startswith("shift+"):
                    state |= 1
                    var cut = String(name[byte=6:])
                    name = cut
                elif name.startswith("ctrl+"):
                    state |= 4
                    var cut = String(name[byte=5:])
                    name = cut
                elif name.startswith("alt+"):
                    state |= 8
                    var cut = String(name[byte=4:])
                    name = cut
                else:
                    break
            presses.append(name)
        var signal = String("key-pressed")
        for p in presses:
            # a typist's next key comes after the screen has caught up: wait out a rebuild (up to 3 s), whose idle turn waits
            # behind every frame while the island moves; a key sent while busy is dropped by the handlers (D-288)
            var free_by = perf_counter_ns() + 3_000_000_000
            while (busy() or host[].has_pending) and perf_counter_ns() < free_by:
                pump()
            if busy() or host[].has_pending:
                print("TEST: " + p + " pressed while the window was still rebuilding (it would be dropped)")
            var editor = -1  # an in-place editor open: it has the keyboard, as it would for a person
            for k in range(len(host[].rt.shown.nodes)):
                if host[].rt.shown.nodes[k].kind == FIELD and host[].rt.shown.nodes[k].value >= 1 and k < len(host[].widgets) and host[].widgets[k] != 0:
                    editor = k
            var handled = List[c_int](length=1, fill=0)
            # a person's keys go where the focus is: the editor if it has it, else the canvas (say so if neither)
            if editor >= 0 and host[].rt.shown.nodes[editor].value == 3:
                editor = -1  # (an editor that echoes the canvas's typing: the canvas has the keyboard)
            var canvas_w = 0
            for k in range(len(host[].canvases)):
                if host[].canvases[k].node == node:
                    canvas_w = host[].canvases[k].widget
            if editor >= 0 and not holds_keyboard(host[].widgets[editor]):
                print("TEST: " + p + " pressed, but the editor doesn't have the keyboard")
            elif editor < 0 and (canvas_w == 0 or not holds_keyboard(canvas_w)):
                print("TEST: " + p + " pressed, but canvas " + kv[0] + " doesn't have the keyboard")
            if editor >= 0 and p == "Enter":
                var activate = String("activate")
                external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].widgets[editor], activate.as_c_string_span())
            elif editor >= 0 and p == "Escape":
                if host[].editor_keys != 0:
                    external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].editor_keys, signal.as_c_string_span(),
                        c_uint(gdk_keyval(p)), c_uint(0), c_uint(state), Int(handled.unsafe_ptr()))
            elif editor >= 0:  # a character typed into the editor where a person's would go: over the selection, at the caret
                var ed = host[].widgets[editor]
                _ = external_call["gtk_editable_delete_selection", NoneType](ed)
                var pos = List[c_int](length=1, fill=external_call["gtk_editable_get_position", c_int](ed))
                var ch = p
                external_call["gtk_editable_insert_text", NoneType](ed, ch.as_c_string_span(), c_int(ch.byte_length()), Int(pos.unsafe_ptr()))
                external_call["gtk_editable_set_position", NoneType](ed, pos[0])
                _ = len(pos)
            else:
                var cs = ci
                for k in range(len(host[].canvases)):  # (the canvas list is rebuilt when the screen's shape changes)
                    if host[].canvases[k].node == node:
                        cs = k
                if host[].canvases[cs].keys != 0:
                    external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[cs].keys, signal.as_c_string_span(),
                        c_uint(gdk_keyval(p)), c_uint(0), c_uint(state), Int(handled.unsafe_ptr()))
            _ = len(handled)
            settle()
    elif verb == "drag" or verb == "dragat" or verb == "doubletap" or verb == "zoom" or verb == "frames" or verb == "tapat":
        var kv = split_at(rest, "=")
        var node = canvas_node(host[], kv[0])
        var ci = -1
        for k in range(len(host[].canvases)):
            if host[].canvases[k].node == node:
                ci = k
        if ci < 0:
            print("TEST: no canvas", kv[0])
            return
        wait_allocated(host[].canvases[ci].widget)
        var drawn_by = perf_counter_ns() + 3_000_000_000  # and drawn once: a person can't tap what isn't on screen yet
        while not host[].canvases_drawn() and perf_counter_ns() < drawn_by:
            if external_call["g_main_context_iteration", c_int](0, c_int(0)) == 0 and getenv("MOJOUI_SHOT") == "":
                break  # unshown window: it will never draw
        if verb == "tapat":  # a click at (x, y) thousandths of the canvas: the click gesture's own signal
            var xy = split_at(kv[1], ",")
            var cw = Float64(Int(external_call["gtk_widget_get_width", c_int](host[].canvases[ci].widget)))
            var chh = Float64(Int(external_call["gtk_widget_get_height", c_int](host[].canvases[ci].widget)))
            var released = String("released")
            var pressed = String("drag-begin")  # a real click presses first (the drag gesture begins: PRESS)
            external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].drag, pressed.as_c_string_span(),
                Float64(to_int(xy[0])) / 1000.0 * cw, Float64(to_int(xy[1])) / 1000.0 * chh)
            host[].canvases[ci].moved = False
            external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].click, released.as_c_string_span(), c_int(1),
                Float64(to_int(xy[0])) / 1000.0 * cw, Float64(to_int(xy[1])) / 1000.0 * chh)
        elif verb == "doubletap":  # a double click at (x, y) thousandths: press, click 1, press, click 2
            var xy = split_at(kv[1], ",")
            var px = Float64(to_int(xy[0])) / 1000.0 * Float64(Int(external_call["gtk_widget_get_width", c_int](host[].canvases[ci].widget)))
            var py = Float64(to_int(xy[1])) / 1000.0 * Float64(Int(external_call["gtk_widget_get_height", c_int](host[].canvases[ci].widget)))
            var released = String("released")
            var pressed = String("drag-begin")
            for n_press in range(1, 3):
                external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].drag, pressed.as_c_string_span(), px, py)
                host[].canvases[ci].moved = False
                external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].click, released.as_c_string_span(), c_int(n_press), px, py)
                settle()
        elif verb == "drag" or verb == "dragat":  # the drag gesture's own signals, as a real drag sends them
            var sx = 10.0
            var sy = 10.0
            var rest2 = kv[1]
            if verb == "dragat":  # dragat:K=fx,fy,dx,dy: start at (fx, fy) thousandths of the canvas
                var a = split_at(rest2, ",")
                var b = split_at(a[1], ",")
                sx = Float64(to_int(a[0])) / 1000.0 * Float64(Int(external_call["gtk_widget_get_width", c_int](host[].canvases[ci].widget)))
                sy = Float64(to_int(b[0])) / 1000.0 * Float64(Int(external_call["gtk_widget_get_height", c_int](host[].canvases[ci].widget)))
                rest2 = b[1]
            var xy = split_at(rest2, ",")
            var dx = Float64(to_int(xy[0]))
            var dy = Float64(to_int(xy[1]))
            var begin = String("drag-begin")
            var update = String("drag-update")
            external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].drag, begin.as_c_string_span(), sx, sy)
            # a hand's moves come after the screen has caught up with its press: the handlers drop a move sent while a
            # rebuild runs, so the test's moves were lost and its drag selected one cell (the Mac's: 3 × 3; D-304)
            for half in range(2):
                var free_by = perf_counter_ns() + 3_000_000_000
                while (busy() or host[].has_pending) and perf_counter_ns() < free_by:
                    pump()
                external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].drag, update.as_c_string_span(), dx * Float64(half + 1) / 2, dy * Float64(half + 1) / 2)
        elif verb == "zoom":  # the scroll controller's signal: 4 notches up = 2×
            var factor = Float64(to_int(kv[1]))
            var handled = List[c_int](length=1, fill=0)
            var signal = String("scroll")
            external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](host[].canvases[ci].scroll, signal.as_c_string_span(), Float64(0), -4.0 * log2(factor), Int(handled.unsafe_ptr()))
            _ = len(handled)
        else:  # frames: let the display run n frames, then report the rate
            var n = to_int(kv[1])
            var start = host[].canvases[ci].frames
            var draws = host[].canvases[ci].draws
            var first = 0
            var deadline = perf_counter_ns() + 20_000_000_000
            while perf_counter_ns() < deadline:
                pump()
                if ci >= len(host[].canvases):
                    break
                var done = host[].canvases[ci].frames - start
                if done == 1 and first == 0:
                    first = host[].canvases[ci].last_us
                    draws = host[].canvases[ci].draws
                if done > n:
                    break
            var ms = Float64(host[].canvases[ci].last_us - first) / 1000.0
            var got = host[].canvases[ci].frames - start - 1
            var fps = Float64(got) / (ms / 1000.0) if ms > 0 else 0.0
            print("FRAMES: " + String(got) + " in " + one_decimal(Float32(ms)) + " ms = " + one_decimal(Float32(fps)) + " fps, draws " + String(host[].canvases[ci].draws - draws))
    elif verb == "say":  # say:TAG: what the view tagged TAG says now (its tooltip, a drawn view's words), mid-run
        var said = False
        for ref n in host[].rt.shown.nodes:
            if n.name == rest:
                print("SAYS: " + rest + " = " + n.tip)
                said = True
                break
        if not said:
            print("TEST: nothing tagged", rest)
    elif verb == "gaps":  # gaps:start forgets the frames painted so far; gaps:N runs the main loop N ms, then prints the longest gap between painted frames (MOJOUI_TRACE)
        if rest == "start":
            host[].frame_times = List[Int]()
            return
        var until = Int(perf_counter_ns()) + to_int(rest) * 1_000_000
        while Int(perf_counter_ns()) < until:
            _ = external_call["g_main_context_iteration", c_int](0, c_int(0))
        var worst = 0.0  # (every gap, the long ones too: intervals() leaves out a bench's pauses, which is what this looks for)
        for k in range(1, len(host[].frame_times)):
            worst = max(worst, Float64(host[].frame_times[k] - host[].frame_times[k - 1]) / 1e6)
        print("GAPS: " + String(len(host[].frame_times)) + " frames, longest " + one_decimal(Float32(worst)) + " ms")
    elif verb == "move" or verb == "resize":  # a board object dragged by its header (or its corner), as a real drag sends it
        var kv = split_at(rest, "=")
        var xy = split_at(kv[1], ",")
        var dx = Float64(to_int(xy[0]))
        var dy = Float64(to_int(xy[1]))
        var bi = -1
        for k in range(len(host[].boards)):
            if host[].rt.shown.nodes[host[].boards[k].node].name == kv[0]:
                bi = k
        if bi < 0:
            print("TEST: no board object", kv[0])
            return
        wait_allocated(host[].boards[bi].widget)
        var w = Float64(Int(external_call["gtk_widget_get_width", c_int](host[].boards[bi].widget)))
        var h = Float64(Int(external_call["gtk_widget_get_height", c_int](host[].boards[bi].widget)))
        ref n = host[].rt.shown.nodes[host[].boards[bi].node]
        var sx = Float64(n.x) + (w - 8 if verb == "resize" else 20.0)  # in the board's coordinates
        var sy = Float64(n.y) + (h - 8 if verb == "resize" else 16.0)
        var begin = String("drag-begin")
        var update = String("drag-update")
        var end = String("drag-end")
        var g = host[].boards[bi].drag
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](g, begin.as_c_string_span(), sx, sy)
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](g, update.as_c_string_span(), dx / 2, dy / 2)
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](g, update.as_c_string_span(), dx, dy)
        external_call["g_signal_emit_by_name", NoneType, num_fixed_args=2](g, end.as_c_string_span(), dx, dy)
    else:
        print("TEST: unknown step", step)


def wait_webviews[A: App](host_addr: Int):
    """(Test runs) Until every WebComponent's page has loaded and its widget mounted and measured (up to 20 s): steps
    and the report then see the widgets, as the web's checks wait for theirs."""
    var host = host_at[A](host_addr)
    var by = perf_counter_ns() + 20_000_000_000
    while perf_counter_ns() < by:
        var wv = webviews_at(host[].webviews)
        var waiting = False
        for ref slot in wv[].slots:
            if not slot.loaded or slot.mounts < 1 or slot.height < 0:
                waiting = True
        if not waiting:
            break
        pump()
    settle()


def report[A: App](host_addr: Int):
    """Prints every widget's state as GTK reports it, in screen order (alerts last,
    since they float above the page on every host)."""
    report_pass[A](host_addr, False)
    report_pass[A](host_addr, True)


def report_pass[A: App](host_addr: Int, alerts: Bool):
    var host = host_at[A](host_addr)
    if not alerts:
        print("NATIVE: GTK " + String(external_call["gtk_get_major_version", c_int]()) + "." + String(external_call["gtk_get_minor_version", c_int]()))
        if host[].window != 0 and external_call["gtk_window_get_icon_name", Int](host[].window) != 0:
            print("WINDOW-ICON: " + c_str(external_call["gtk_window_get_icon_name", Int](host[].window)))
        var theme = host[].rt.app.theme()
        if theme.id != "":
            print("DESIGN: " + theme.id)
        print("THEME: " + (theme.id if theme.id != "" else "none") + " sheet=" + ("none" if host[].skin_provider == 0 else String(theme.gtk_css.byte_length()) + " bytes"))  # (what the host loaded, not what it was told)
        if theme.paint_native and host[].fonts:  # (a theme that sets the app's own fonts on native controls)
            print("FONT: Inter, JetBrains Mono (the app's own)")
        if external_call["gtk_widget_get_mapped", c_int](host[].window) != 0:  # laid out, so measurable
            for i in range(len(host[].rt.shown.nodes)):
                if host[].rt.shown.nodes[i].name != "":
                    var rect = List[Float32](length=4, fill=0)  # graphene_rect_t: x, y, width, height
                    var measured = host[].widgets[i]
                    if i == 0 and (host[].rt.shown.nodes[0].grows or host[].rt.shown.nodes[0].fills) and host[].page != 0:
                        # a screen that fills the window: its box is the page it fills, what the window shows (the web's
                        # root is the window high and a taller screen overflows it, scrolling the page; GTK's root is as
                        # tall as its content inside the page scroller: models 716 for the web's 640, D-551)
                        measured = host[].page
                    var ok = external_call["gtk_widget_compute_bounds", c_int](measured, host[].window, Int(rect.unsafe_ptr()))
                    if ok != 0:
                        print("BOX: " + host[].rt.shown.nodes[i].name + " " + one_decimal(rect[0]) + " " + one_decimal(rect[1])
                              + " " + one_decimal(rect[2]) + " " + one_decimal(rect[3]))
                    _ = len(rect)
                    report_buttons(host[], i, host[].rt.shown.nodes[i].name)
    if not alerts:  # each WebComponent's view, as the host saw it, and the widget's own line (the web's WIDGET:)
        var wv = webviews_at(host[].webviews)
        for ref slot in wv[].slots:
            var ready = slot.loaded and slot.mounts >= 1
            print("WEBVIEW: " + slot.key() + (" ready" if ready else " loading") + " mounts=" + String(slot.mounts) + " csp=" + String(slot.csp)
                  + " refused=" + String(slot.refused) + " blocked=" + String(slot.blocked) + " h=" + String(slot.height))
            print("WIDGET: " + slot.key() + ": " + slot.describe)
    for i in range(len(host[].rt.shown.nodes)):
        if host[].rt.shown.nodes[i].kind == BOARD and not alerts:
            print("LAYOUT: " + ("list" if host[].board_list else "board"))
            for c in host[].rt.shown.nodes[i].children:
                ref ch = host[].rt.shown.nodes[c]
                if not host[].board_list:
                    print("BOARD: " + ch.name + " at " + String(ch.x) + "," + String(ch.y) + " " + String(ch.w) + "x" + String(ch.h))
            if not host[].board_list and getenv("MOJOUI_SHOT") != "":  # (only a shown window has a visible part)
                var seen = host[].in_view(i)
                var line = String("INVIEW: ")
                for k in range(len(seen)):
                    line += (", " if k > 0 else "") + seen[k]
                print(line)
    for i in range(len(host[].rt.shown.nodes)):
        ref n = host[].rt.shown.nodes[i]
        var w = host[].widgets[i]
        if (n.kind == ALERT) != alerts:
            continue
        if n.kind == PARAGRAPH:  # its words as the label shows them (markup parsed), then each run's (as the web reports them)
            var links = 0
            for r in runs_of(n):
                links += 1 if r.href != "" else 0
            var said = plain_words(c_str(external_call["gtk_label_get_text", Int](w)))
            print("PARAGRAPH: " + said + " (" + String(len(runs_of(n))) + " runs, " + String(links) + " links)")
            print("LABEL: " + said)  # (its words whole, then each run's when it has several, as the web reports them)
            if len(runs_of(n)) > 1:
                for r in runs_of(n):
                    print("LABEL: " + r.text)
        elif n.kind == TEXT:
            # (the app's words when the label shows them, its end spaces included, as the web's report reads its text:
            # D-549 drops them only from what's drawn; "row 1,000,001 · " read differently on the two hosts)
            var shown = plain_words(c_str(external_call["gtk_label_get_text", Int](w)))
            var said = n.text if shown == plain_words(label_words(host[].rt.shown.nodes, i)) else shown
            print("LABEL: " + said)
            var tone = tone_of(w)
            if tone != "":
                print("TONE: " + said + " = " + tone)
        elif n.kind == BUTTON:
            if n.style == TOOL or n.style == TOOL_ON or n.style == TOOL_INLINE or n.style == TOOL_INLINE_ON:
                print("BUTTON: " + c_str(external_call["gtk_label_get_text", Int](external_call["gtk_widget_get_last_child", Int](external_call["gtk_button_get_child", Int](w)))))
            elif n.hint != "" and (n.style == ICON_ONLY or n.style == ICON_ON):
                print("BUTTON: " + n.text)  # (only its icon shows; its own tooltip, when it has one, replaces the title there)
            elif n.hint != "":
                print("BUTTON: " + c_str(external_call["adw_button_content_get_label", Int](external_call["gtk_button_get_child", Int](w))))
            else:
                print("BUTTON: " + c_str(external_call["gtk_button_get_label", Int](w)))
            if n.tip != "":
                print("TIP: " + n.text + " = " + n.tip)
        elif n.kind == FIELD:
            print("FIELD: " + c_str(external_call["gtk_editable_get_text", Int](w)))
        elif n.kind == TOGGLE:
            var on = external_call["gtk_check_button_get_active", c_int](w) != 0
            print(("CHECK: " if n.style == 1 else "TOGGLE: ") + c_str(external_call["gtk_check_button_get_label", Int](w)) + ("=on" if on else "=off"))
        elif n.kind == DROPDOWN:
            var model = external_call["gtk_drop_down_get_model", Int](w)
            var sel = external_call["gtk_drop_down_get_selected", c_uint](w)
            print("DROPDOWN: " + c_str(external_call["gtk_string_list_get_string", Int](model, sel)))
        elif n.kind == SLIDER:
            print("SLIDER: " + String(Int(external_call["gtk_range_get_value", Float64](w) + 0.5)))
        elif n.kind == PROGRESS:
            print("PROGRESS: " + String(Int(external_call["gtk_progress_bar_get_fraction", Float64](w) * 100.0 + 0.5)))
        elif n.kind == SEGMENTED or n.kind == TABS:
            var index = external_call["adw_toggle_group_get_active", c_uint](w)
            var t = external_call["adw_toggle_group_get_toggle", Int](w, index)
            print(("SEGMENTED: " if n.kind == SEGMENTED else "TABS: ") + c_str(external_call["adw_toggle_get_label", Int](t)))
        elif n.kind == RADIO:
            var b = external_call["gtk_widget_get_first_child", Int](w)
            while b != 0:
                if external_call["gtk_check_button_get_active", c_int](b) != 0:
                    print("RADIO: " + c_str(external_call["gtk_check_button_get_label", Int](b)))
                b = external_call["gtk_widget_get_next_sibling", Int](b)
        elif n.kind == TEXTAREA:
            print("TEXTAREA: " + escape_newlines(buffer_text(external_call["gtk_text_view_get_buffer", Int](w))))
        if n.kind == ALERT:
            var line = c_str(external_call["adw_alert_dialog_get_heading", Int](w)) + " | " + c_str(external_call["adw_alert_dialog_get_body", Int](w)) + " | "
            for j in range(len(n.options)):
                var id = String(j)
                line += (", " if j > 0 else "") + c_str(external_call["adw_alert_dialog_get_response_label", Int](w, id.as_c_string_span()))
            print("ALERT: " + line)
            if getenv("MOJOUI_SHOT") != "":
                print("ALERTSHOWN: " + ("yes" if external_call["gtk_widget_get_mapped", c_int](w) != 0 else "no"))
        elif n.kind == DIALOG:
            print("DIALOG: " + n.text)
            if getenv("MOJOUI_SHOT") != "":
                print("DIALOGSHOWN: " + ("yes" if external_call["gtk_widget_get_mapped", c_int](w) != 0 else "no"))
        elif n.kind == ROUTE:
            print("ROUTE: " + (n.text if n.text != "" else String("/")))
        elif n.kind == TABLE:
            var cols = max(n.value, 1)
            var rows = (len(n.children) - cols) // cols
            var picked = 0
            for k in range(min(rows, n.text.byte_length())):
                if String(n.text[byte=k]) == "1":
                    picked += 1
            print("TABLE: " + n.name + " " + String(rows) + " rows, " + String(cols) + " columns, " + String(picked) + " selected")
        elif n.kind == SCROLL and n.value == 1:
            var adj = external_call["gtk_scrolled_window_get_vadjustment", Int](w)
            var end = external_call["gtk_adjustment_get_upper", Float64](adj) - external_call["gtk_adjustment_get_page_size", Float64](adj)
            print("PINNED: " + (n.name if n.name != "" else String("?")) + (" at end" if end - external_call["gtk_adjustment_get_value", Float64](adj) <= 4.0 else " not at end"))
        elif n.kind == CLIPBOARD:
            if host[].clip_version > 0:
                print("CLIPBOARD: " + host[].clip_text.replace("\t", "\\t").replace("\n", "\\n"))
        elif n.kind == TOAST:
            print("TOAST: " + n.text + (" | " + n.options[0] if len(n.options) > 0 else ""))
        elif n.kind == POPOVER:
            print("POPOVER: " + n.hint)
            if getenv("MOJOUI_SHOT") != "":
                print("POPOVERSHOWN: " + ("yes" if external_call["gtk_widget_get_mapped", c_int](w) != 0 else "no"))
        elif n.kind == MENU:
            print("MENU: " + ("context" if n.style == 1 else n.text) + ": " + items_text(host[].rt.shown, i))
            report_menu_rows(host[], i)
            if n.style == 1 and getenv("MOJOUI_SHOT") != "":  # (a popover is its own surface: not in the window's screenshot)
                print("MENUSHOWN: " + ("yes" if external_call["gtk_widget_get_mapped", c_int](w) != 0 else "no"))
        elif n.kind == NAVBAR:
            var title = external_call["gtk_widget_get_last_child", Int](w)
            var has_back = external_call["gtk_widget_get_first_child", Int](w) != title
            print("NAV: " + c_str(external_call["gtk_label_get_text", Int](title)) + (" (back)" if has_back else ""))
        elif n.kind == DATE:
            print("DATE: " + calendar_date(w))
        elif n.kind == ICON:
            print("ICON: " + mojo_icon(c_str(external_call["gtk_image_get_icon_name", Int](w))))
        elif n.kind == GRID:
            var count = 0
            var c = external_call["gtk_widget_get_first_child", Int](w)
            while c != 0:
                count += 1
                c = external_call["gtk_widget_get_next_sibling", Int](c)
            print("GRID: " + String(n.value) + " columns, " + String(count) + " items")
        elif n.kind == LAZYLIST:
            var selection = external_call["gtk_list_view_get_model", Int](w)
            print("LIST: " + String(external_call["g_list_model_get_n_items", c_uint](selection)) + " rows")
            print("LISTBUILT: " + String(counter("mojoui-rows-built")))
            print("LISTBOUND: " + String(counter("mojoui-rows-bound")))
            var key = String("mojoui-row0")
            var app = external_call["g_application_get_default", Int]()
            var row0 = external_call["g_object_get_data", Int](app, key.as_c_string_span())
            if row0 != 0:  # only while row 0 is on screen (as on the web)
                print("LISTROW: " + c_str(row0))
        elif n.kind == CANVAS:
            for ref c in host[].canvases:
                if c.node == i and c.wpx > 0:
                    print("CANVAS: " + String(Int(external_call["gtk_widget_get_width", c_int](w))) + "x" + String(Int(external_call["gtk_widget_get_height", c_int](w)))
                          + " pt " + String(c.wpx) + "x" + String(c.hpx) + " px scale " + one_decimal(Float32(c.scale)) + " colours "
                          + String(colours(c.pixels)) + " draws " + String(c.draws) + " painted " + String(painted(c.pixels)))
            if n.tip != "":  # (a drawn view's words: its tooltip, which is also its accessible name)
                print("TIP: " + n.name + " = " + n.tip)
        elif n.kind == IMAGE:
            var paintable = external_call["gtk_picture_get_paintable", Int](w)
            print("IMAGE: " + String(external_call["gdk_texture_get_width", c_int](paintable)) + "x" + String(external_call["gdk_texture_get_height", c_int](paintable)))


def colours(pixels: List[UInt32]) -> Int:
    """How many different colours a sample of the pixels has (to tell a picture from a blank)."""
    var sample = List[UInt32]()
    var step = max(len(pixels) // 20000, 1)
    for i in range(0, len(pixels), step):
        sample.append(pixels[i])
    sort(sample)
    var n = 0
    for i in range(len(sample)):
        if i == 0 or sample[i] != sample[i - 1]:
            n += 1
    return n


def painted(pixels: List[UInt32]) -> Int:
    """The share (percent) of a sample of the pixels that differ clearly from the most common colour,
    the background: a blank canvas is ~0, a drawn map or chart tens of percent (goal 7's measure, D-70).
    Colour counts depend on the renderer's antialiasing; this doesn't."""
    var sample = List[UInt32]()
    var step = max(len(pixels) // 20000, 1)
    for i in range(0, len(pixels), step):
        sample.append(pixels[i])
    if len(sample) == 0:
        return 0
    var sorted_ = sample.copy()
    sort(sorted_)
    var background = sorted_[0]
    var best = 0
    var run_start = 0
    for i in range(1, len(sorted_) + 1):
        if i == len(sorted_) or sorted_[i] != sorted_[run_start]:
            if i - run_start > best:
                best = i - run_start
                background = sorted_[run_start]
            run_start = i
    var n = 0
    for px in sample:
        var d = 0
        for shift in [0, 8, 16]:
            d += abs(Int((px >> UInt32(shift)) & 0xFF) - Int((background >> UInt32(shift)) & 0xFF))
        if d > 30:
            n += 1
    return n * 100 // len(sample)


def save_png(window: Int, path: String):
    """Asks GTK to render the window (as drawn on screen) into a PNG file."""
    var by = perf_counter_ns() + 5_000_000_000  # wait until the window is on screen (up to 5 s: a loaded display)
    while external_call["gtk_widget_get_mapped", c_int](window) == 0 and perf_counter_ns() < by:
        pump()
    for _ in range(60):  # let layout and drawing settle (~300 ms of frames)
        settle()
        external_call["g_usleep", NoneType](c_uint(5000))
    var paintable = external_call["gtk_widget_paintable_new", Int](window)
    var w = external_call["gtk_widget_get_width", c_int](window)
    var h = external_call["gtk_widget_get_height", c_int](window)
    var snap = external_call["gtk_snapshot_new", Int]()
    external_call["gdk_paintable_snapshot", NoneType](paintable, snap, Float64(Int(w)), Float64(Int(h)))
    var node = external_call["gtk_snapshot_free_to_node", Int](snap)
    if node == 0:  # nothing drawn yet (e.g. a dialog window took the first frame)
        print("SHOT: skipped (window had no frame to capture)")
        return
    var renderer = external_call["gtk_native_get_renderer", Int](window)
    var texture = external_call["gsk_renderer_render_texture", Int](renderer, node, 0)
    var p = path
    var ok = external_call["gdk_texture_save_to_png", c_int](texture, p.as_c_string_span())
    print("SHOT:", path if ok != 0 else "failed")


def on_activate[A: App](gapp: Int, host_addr: Int) abi("C"):
    var host = host_at[A](host_addr)
    host[].window = external_call["gtk_application_window_new", Int](gapp)
    var title = host[].rt.app.title()
    external_call["gtk_window_set_title", NoneType](host[].window, title.as_c_string_span())
    host[].install_fonts()
    host[].apply_design(host_addr)
    host[].shortcut_keys = external_call["gtk_event_controller_key_new", Int]()  # menu shortcuts, before anything else sees the key
    external_call["gtk_event_controller_set_propagation_phase", NoneType](host[].shortcut_keys, c_int(1))  # GTK_PHASE_CAPTURE
    connect_any(host[].shortcut_keys, "key-pressed", on_shortcut_pressed[A], host_addr)
    external_call["gtk_widget_add_controller", NoneType](host[].window, host[].shortcut_keys)
    var size = host[].rt.app.window_size()
    var forced = getenv("MOJOUI_WINDOW")  # tests: "1280x800" checks a smaller laptop screen
    if forced != "":
        var wh = split_at(forced, "x")
        size = (to_int(wh[0]), to_int(wh[1]))
    external_call["gtk_window_set_default_size", NoneType](host[].window, c_int(size[0]), c_int(size[1]))
    host[].window_w = size[0]
    host[].rt.app.resize(size[0], size[1])  # (its real size follows once the window is laid out: App.resize again)
    var styles = external_call["adw_style_manager_get_default", Int]()
    host[].dark_told = 1 if external_call["adw_style_manager_get_dark", c_int](styles) != 0 else 0
    host[].rt.app.appearance(host[].dark_told == 1)  # (and again when the person switches)
    connect3(styles, "notify::dark", on_dark_changed[A], host_addr)
    host[].rt.shown = host[].rt.view()  # (its spacing tokens in the theme's points)
    for prop in ["notify::default-width", "notify::default-height", "notify::maximized", "notify::fullscreened"]:
        connect3(host[].window, prop, on_window_resized[A], host_addr)
    connect(host[].window, "realize", on_window_realize[A], host_addr)
    if getenv("MOJOUI_LIVE_REPORT") != "":  # (scripts/live.py: SIGUSR1 prints the widgets' state, as a test run's end does)
        _ = external_call["g_unix_signal_add", c_uint](c_int(10), on_live_report[A], host_addr)
    host[].show(host_addr)
    host[].schedule_effects(host_addr)  # (what the starting state asked for)
    var steps = getenv("MOJOUI_TEST")
    var testing = is_set("MOJOUI_TEST")  # set, even to "": report the widgets' state
    var shot = getenv("MOJOUI_SHOT")
    if testing:
        # Test windows ignore the real keyboard and mouse: the checks drive the widgets
        # themselves, and someone working at the desktop mustn't type into them by accident.
        # On the checks' private display (scripts/headless.py) nobody types, so the keyboard focus is real
        # there: key steps check that the canvas or editor they press keys into really has it.
        if getenv("MOJOUI_PRIVATE_DISPLAY") != "1":
            external_call["gtk_widget_set_can_focus", NoneType](host[].window, c_int(0))
        external_call["gtk_widget_set_can_target", NoneType](host[].window, c_int(0))
        # A fixed size, so measurements don't depend on how the desktop tiles windows.
        external_call["gtk_window_set_resizable", NoneType](host[].window, c_int(0))
        var title = String("mojoui test window (closes by itself)")
        external_call["gtk_window_set_title", NoneType](host[].window, title.as_c_string_span())
    if not testing or shot != "":
        external_call["gtk_window_present", NoneType](host[].window)
    if testing and shot != "":
        # On X11 (the headless display) the first layout waits for the server's map event, which
        # isn't pending yet: block for it, up to 3 s, so steps and measurements see a laid-out window.
        var up_by = perf_counter_ns() + 3_000_000_000
        while external_call["gtk_widget_get_width", c_int](host[].window) == 0 and perf_counter_ns() < up_by:
            pump()
        settle()
    if testing:
        wait_webviews[A](host_addr)
        for step in steps.split(";"):
            if String(step) != "":
                run_step[A](host_addr, String(step))
            settle()
            if shot != "":
                wait_frame(host[].window)
                var by = perf_counter_ns() + 1_000_000_000
                while host[].reveal_pending >= 0 and perf_counter_ns() < by:  # a scroll into view waits for layout
                    pump()
        if shot != "" and len(host[].canvases) > 0:  # on screen: let canvases draw what they show now
            var deadline = perf_counter_ns() + 5_000_000_000
            while not host[].canvases_drawn() and perf_counter_ns() < deadline:
                pump()
            settle()
        report[A](host_addr)
    if shot != "":
        host[].full_page()
        save_png(host[].window, shot)
    if testing or shot != "":
        external_call["g_application_quit", NoneType](gapp)


def run[A: App]() -> Int:
    """Opens the app in a native GTK window and runs until it's closed."""
    var host = alloc(Layout[GtkHost[A]].single()).unsafe_leak()  # lives as long as the app
    A.init_shared()
    host.unsafe_write(GtkHost[A](A()))
    var id = String("dev.mojoui.App")
    var gapp = external_call["adw_application_new", Int](id.as_c_string_span(), c_int(G_APPLICATION_NON_UNIQUE))
    connect(gapp, "activate", on_activate[A], Int(host))
    return Int(external_call["g_application_run", c_int](gapp, c_int(0), 0))
