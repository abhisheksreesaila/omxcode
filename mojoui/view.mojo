# The declarative layer: a screen is a value (a View) built from small pieces.
#
#   VStack(Text("Hello", style=TITLE), TextField(self.name, placeholder="Your name", on_change=NAME))
#
# A View is a flat list of nodes; node 0 is the root and containers list their
# children by index. (Mojo can't yet put a List[View] inside View; flat lists
# are also easy to compare and to pair with native widgets.)

# Node kinds
comptime TEXT = 1
comptime BUTTON = 2
comptime VSTACK = 3
comptime HSTACK = 4
comptime SPACER = 5
comptime FIELD = 6  # one-line text input
comptime TOGGLE = 7  # on/off switch with a label
comptime DROPDOWN = 8  # pick one of several options
comptime SLIDER = 9  # 0–100
comptime PROGRESS = 10  # 0–100, read-only
comptime DIVIDER = 11
comptime SCROLL = 12  # one child, scrolls when taller than `size`
comptime IMAGE = 13  # pixels (RGBA), `spacing` x `size` in size
comptime SEGMENTED = 14  # pick one of a few options, shown side by side
comptime RADIO = 15  # pick one option from a vertical list
comptime TEXTAREA = 16  # several lines of text; `size` = height
comptime ALERT = 17  # a modal question: text = title, hint = message, options = buttons
comptime TABS = 18  # switch between sections: options = section names
comptime NAVBAR = 19  # a screen's title bar; msg = back (0: no back button)
comptime DATE = 20  # text = "YYYY-MM-DD"
comptime ICON = 21  # text = icon name (see ICON_NAMES); size = points
comptime GRID = 22  # children in rows of `value` columns; spacing = gap
comptime LAZYLIST = 23  # value = row count, msg2 = list id, size = height, spacing = row height
comptime CANVAS = 24  # drawn by the app's draw(): style = canvas id, value = version, msg = on_gesture, msg2 = on_frame
comptime BOARD = 25  # children at absolute positions (.at(x, y), sized with .width/.height): msg = on_move, msg2 = on_resize; spacing = width, size = height; value = reveal (see Board)
comptime OVERLAY = 26  # first child fills it; the others float over it, pinned to an edge or corner (.pin(h, v): x = h, y = v)
comptime MENUBAR = 27  # a row of menus (mojoui.menus): children = MENU nodes
comptime MENU = 28  # text = title; children = ITEM nodes; style 1 = a context menu: text = the anchor's tag, x/y = where in it, msg2 = on_close
comptime DIALOG = 30  # a modal panel over a dimmed page (mojoui.overlays): text = title, child = content, msg2 = on_close, w = width
comptime TOAST = 31  # a short message at the bottom: text, options[0] = action title, msg = on_action, msg2 = on_close, size = seconds
comptime CLIPBOARD = 33  # puts `text` on the system clipboard whenever `value` (a version, from 1) changes; nothing on screen (mojoui.overlays.Clipboard)
comptime POPOVER = 32  # a panel attached to the view tagged `text`: hint = title, child = content, msg2 = on_close, x/y = where in the anchor
comptime TABLE = 34  # rows and columns that size to their content (web: a real <table>): value = columns; children = the header's cells, then
#   the body's, row by row; hint = one letter per column (L left, R right: figures, mono); text = one letter per body row (1: selected)
comptime ROUTE = 35  # where the app is (a path, "/models/qwen/logs"): text; nothing on screen. The web keeps it in the URL's hash (read
#   on load, written on change, Back and Forward) and sends msg (event.text = the new path); elsewhere it's state (mojoui.route)
comptime DRAG = 36  # its one child can be dragged (mojoui.dragdrop.Draggable): text = what it carries (a model's name, a list as JSON)
comptime DROP = 37  # its one child takes drops (mojoui.dragdrop.DropTarget): msg = on_drop, event.text = what was dropped
comptime EMBED = 38  # a web page in the screen (mojoui.embed.WebFrame): text = its URL, value = a version (from 1), size = height;
#   the web shows it in an iframe; GTK and the Mac open it in the browser when the version moves on and show the child instead
comptime PARAGRAPH = 39  # styled runs the host wraps as text (mojoui.paragraph.Paragraph): text = the plain words, msg = on_link,
#   options = 4 strings per run (flags "b" "i" "c" "l", role, href, text)
comptime WEBCOMP = 40  # a JavaScript widget (mojoui.webcomponent.WebComponent): hint = its custom element's tag, value = its id,
#   text = its props (a JSON object), msg = on_event (event.id = the id, event.name = the event, event.text = its JSON payload);
#   its one child is what hosts without a web view show. The web mounts the widget once per (tag, id) and keeps it
comptime ITEM = 29  # a menu item: text = title, msg, hint = icon, options[0] = shortcut, value = flags (1 checked, 2 disabled, 4 danger); style 1 = separator, 2 = section label; children = a submenu

# Canvas gestures (event.number)
comptime PAN = 1  # event.dx, dy: movement in points; event.x, y: where the pointer is
comptime ZOOM = 2  # event.zoom: scale factor (2 = twice as big) around event.x, y
comptime TAP = 3  # event.x, y
comptime PRESS = 4  # the pointer went down at event.x, y; a TAP or PANs follow (where a drag starts)
comptime RELEASE = 5  # a drag (PANs) ended at event.x, y (not sent after a plain TAP)
comptime DOUBLE = 6  # a double click / double tap at event.x, y (after the TAP of its first click)
comptime SECONDARY = 8  # a right click (or a long press) at event.x, y: the place to open a context menu
comptime KEY = 7  # a key pressed while the canvas has focus (a click gives it focus): event.text = the key's name
comptime SET_TO = 9  # a drawn control set straight to a value (an agent, an accessibility tool): event.text = the number, in the unit .settable() names
#   ("ArrowDown", "Enter", "Escape", "Tab", "Backspace", "Delete", "PageDown", "Home", "F2", …, the web's names)
#   or the character it typed ("7", "a", " "); event.dx = the modifiers held: SHIFT + CTRL + ALT
comptime SHIFT = 1
comptime CTRL = 2  # (Command on a Mac)
comptime ALT = 4

# Icon names every host understands (each maps them to its platform's own icons).
comptime ICON_NAMES: List[String] = [
    "star", "trash", "gear", "plus", "check", "calendar", "search", "heart", "home", "person",
    "travel", "food", "fun", "chart",
    # Lucide icons drawn the same on every host (GTK loads the same SVGs)
    "table", "pivot", "chart-bar", "note", "undo", "save", "open", "close", "sort", "filter-off", "row-plus", "row-minus",
    "view", "zoom", "category", "formula", "comment", "shape", "text", "organise", "format", "share", "import", "database", "sample", "grid", "sheet", "file", "export", "upload", "chevron",
    "bold", "italic", "underline", "strikethrough", "text-colour", "fill", "align-left", "align-center", "align-right", "currency", "percent", "decimals-less", "decimals-more", "clear-format", "rename", "settings", "chevron-right", "back", "copy",
    "box", "gauge", "scroll-text", "book-open", "key-round", "route", "lock", "sliders-horizontal", "layout-grid", "list", "square", "rotate-cw", "trash-2", "terminal", "play", "pause", "x", "laptop", "external-link", "loader-circle", "download", "ellipsis", "zap", "cpu",
    "unlock", "sun", "moon",  # (the console's Security and Settings, goal 33 M6)
    "video", "image",  # (omxplorer's video and picture cards, goal 39 M6)
]

# Text styles (each platform maps them to its own type scale)
comptime BODY = 0
comptime TITLE = 1
comptime HEADLINE = 2
comptime CAPTION = 3

# Text tones (a Text's `value`, set with .tone()): colour from the design language
comptime TONE_NONE = 0
comptime TONE_WARN = 1  # needs attention (a finding)
comptime TONE_GOOD = 2
comptime TONE_STRONG = 3  # bold (totals)
comptime TONE_ACCENT = 4

# Container styles (on a VStack's `style`): hosts that know them draw them, others show a plain stack
comptime CARD = 1  # a raised panel: the platform's own card look
comptime CARD_WARN = 2  # a card that asks for attention (an agent's finding): the theme's warning tint
comptime CARD_GOOD = 3  # a card that confirms something went right: the theme's success tint

# Themes are not here: an app hands its hosts a mojoui.theme.Theme (App.theme()), built outside the framework (D-260).

# Button styles
comptime PLAIN = 0
comptime PROMINENT = 1
comptime DESTRUCTIVE = 2
comptime SUBTLE = 3  # quiet: no fill until hovered (toolbars, card actions)
comptime ICON_ONLY = 4  # quiet and only its icon shows; the title is its tooltip and accessible name
comptime TOOL = 5  # a toolbar button: the icon above a small title (Numbers, Keynote)
comptime TOOL_ON = 6  # the same, shown as the active tool
comptime ICON_ON = 7  # ICON_ONLY shown pressed (a toggle that is on: Bold, Align left)
comptime TOOL_INLINE = 8  # a toolbar button: its icon beside a small title, on one line with icon-only toggles
comptime TOOL_INLINE_ON = 9  # the same, shown as the active tool
comptime TOKEN = 10  # a word inside a sentence that opens its choices (mojoui.sentence): inline, the accent's colour, no fill
comptime TOKEN_LIT = 11  # the same, just changed: themes mark it for a moment


def as_tool(style: Int) -> Int:
    """TOOL_INLINE as TOOL (and its ON), for hosts that draw only the icon-above-title tool."""
    return TOOL if style == TOOL_INLINE else (TOOL_ON if style == TOOL_INLINE_ON else style)

comptime NO_MSG = 0

# Layout (flexbox names; each host maps them onto its own layout system)
comptime AUTO = 0  # the host's default
comptime START = 1
comptime CENTER = 2
comptime END = 3
comptime STRETCH = 4  # align only
comptime BETWEEN = 5  # justify only
comptime BASELINE = 6  # align only: a row's children on their first line's baseline (a number and its unit; GTK and the Mac: centred)

# The theme's spacing scale (D-412): pass these as a stack's spacing or a view's padding and the runtime puts the theme's
# value in (Look.space; with no theme 2, 4, 8, 12, 16, 24, 32 points). An app that spaces with them changes with its theme
# and writes no sizes of its own.
comptime SPACE_XXS = -1
comptime SPACE_XS = -2
comptime SPACE_S = -3
comptime SPACE_M = -4
comptime SPACE_L = -5
comptime SPACE_XL = -6
comptime SPACE_XXL = -7


def space_value(v: Int, scale: List[Int]) -> Int:
    """A spacing or padding token (SPACE_…) as points on `scale`; a value of 0 or more is itself."""
    if v >= 0:
        return v
    var k = -v - 1
    return scale[k] if k < len(scale) else 0


struct Node(Copyable, Movable, Equatable, Writable):
    var kind: Int
    var text: String  # label text, button title, field contents, toggle label
    var msg: Int  # message sent on tap / change / toggle / select
    var style: Int
    var spacing: Int  # stacks: gap between children
    var children: List[Int]
    var value: Int  # toggle 0/1, dropdown index, slider/progress 0–100
    var options: List[String]  # dropdown choices
    var hint: String  # field placeholder
    var msg2: Int  # field: message sent on Return
    var size: Int  # scroll: visible height in points; image: height; field: message sent on Escape; canvas: 1 = takes keys
    var pixels: List[UInt32]  # image: RGBA bytes, one UInt32 per pixel (R in the low byte)
    # Layout settings (0 = not set). Sizes include padding (border-box) on every host.
    var pad_v: Int  # padding top and bottom
    var pad_h: Int  # padding left and right
    var w: Int  # fixed width
    var h: Int  # fixed height
    var min_w: Int
    var max_w: Int
    var grows: Bool  # take the free space along the parent's direction
    var fills: Bool  # stretch across the parent's direction
    var align_items: Int  # stacks: cross-axis alignment of children (START/CENTER/END/STRETCH)
    var justify_items: Int  # stacks: main-axis placement of children (START/CENTER/END/BETWEEN)
    var name: String  # a tag for tests and accessibility
    # Set by the parent stack: whether its fill/grow decides this view's width / height
    # (fill in a VStack or grow in an HStack sets width; the reverse sets height).
    var width_from_parent: Bool
    var height_from_parent: Bool
    var x: Int  # position inside a Board
    var y: Int
    var tip: String  # a tooltip (.tooltip())
    var label: String  # what a screen reader calls it when nothing on screen says so (.label()); never shown

    def __init__(
        out self,
        kind: Int,
        text: String = "",
        msg: Int = NO_MSG,
        style: Int = BODY,
        spacing: Int = 0,
        var children: List[Int] = [],
        value: Int = 0,
        var options: List[String] = [],
        hint: String = "",
        msg2: Int = NO_MSG,
        size: Int = 0,
        var pixels: List[UInt32] = [],
    ):
        self.kind = kind
        self.text = text
        self.msg = msg
        self.style = style
        self.spacing = spacing
        self.children = children^
        self.value = value
        self.options = options^
        self.hint = hint
        self.msg2 = msg2
        self.size = size
        self.pixels = pixels^
        self.pad_v = 0
        self.pad_h = 0
        self.w = 0
        self.h = 0
        self.min_w = 0
        self.max_w = 0
        self.grows = False
        self.fills = False
        self.align_items = AUTO
        self.justify_items = AUTO
        self.name = ""
        self.width_from_parent = False
        self.height_from_parent = False
        self.x = 0
        self.y = 0
        self.tip = ""
        self.label = ""

    def __eq__(self, other: Self) -> Bool:
        return (
            self.kind == other.kind
            and self.text == other.text
            and self.msg == other.msg
            and self.style == other.style
            and self.spacing == other.spacing
            and self.children == other.children
            and self.value == other.value
            and self.options == other.options
            and self.hint == other.hint
            and self.msg2 == other.msg2
            and self.size == other.size
            and self.pixels == other.pixels
            and self.same_layout(other)
        )

    def same_layout(self, other: Self) -> Bool:
        return self.same_layout_but(other, False, False)

    def same_layout_but(self, other: Self, sizes: Bool, place: Bool) -> Bool:
        """same_layout, ignoring the sizes (w, h, min_w, max_w) and/or the place on a Board (x, y) when asked."""
        return (
            self.pad_v == other.pad_v and self.pad_h == other.pad_h
            and (sizes or (self.w == other.w and self.h == other.h and self.min_w == other.min_w and self.max_w == other.max_w))
            and self.grows == other.grows
            and self.fills == other.fills and self.align_items == other.align_items
            and self.justify_items == other.justify_items and self.name == other.name
            and self.width_from_parent == other.width_from_parent
            and self.height_from_parent == other.height_from_parent
            and (place or (self.x == other.x and self.y == other.y)) and (self.tip == other.tip or (self.kind == CANVAS and other.kind == CANVAS))  # (a canvas's tooltip, its words, is a patch: SET_TIP)
            and (self.label == other.label or (self.kind == CANVAS and other.kind == CANVAS))  # (a new label is a new layout; a canvas's is a patch, SET_TIP: its picture stays)
        )

    def sized_width(self) -> Bool:
        """Whether the app's layout decides this view's width (so a control drops its default)."""
        return self.w != 0 or self.width_from_parent

    def sized_height(self) -> Bool:
        return self.h != 0 or self.height_from_parent

    def write_to(self, mut writer: Some[Writer]):
        writer.write("Node(kind=", self.kind, ", '", self.text, "', msg=", self.msg, ", value=", self.value, ", children=", self.children, ")")


@fieldwise_init
struct View(Copyable, Movable):
    var nodes: List[Node]

    # Layout settings: chain them on any view, e.g. Text("Hi").padding(8).grow().
    # They apply to the view itself (node 0).

    def padding(var self, all: Int) -> View:
        """Space inside the view's edges, on all four sides."""
        self.nodes[0].pad_v = all
        self.nodes[0].pad_h = all
        return self^

    def padding(var self, vertical: Int, horizontal: Int) -> View:
        """Space inside the view's edges: top/bottom and left/right."""
        self.nodes[0].pad_v = vertical
        self.nodes[0].pad_h = horizontal
        return self^

    def width(var self, points: Int) -> View:
        """A fixed width (including padding)."""
        self.nodes[0].w = points
        return self^

    def height(var self, points: Int) -> View:
        """A fixed height (including padding)."""
        self.nodes[0].h = points
        return self^

    def min_width(var self, points: Int) -> View:
        self.nodes[0].min_w = points
        return self^

    def max_width(var self, points: Int) -> View:
        """At most this wide; text wraps to fit."""
        self.nodes[0].max_w = points
        return self^

    def grow(var self) -> View:
        """Take the free space along the parent stack's direction (flex-grow)."""
        self.nodes[0].grows = True
        return self^

    def fill(var self) -> View:
        """Stretch across the parent stack's direction (align-self: stretch)."""
        self.nodes[0].fills = True
        return self^

    def align(var self, how: Int) -> View:
        """On a stack: line children up across its direction (START, CENTER, END, STRETCH). On a button (or a FilePicker):
        START puts its icon and title at the leading edge, as a sidebar's rows read."""
        self.nodes[0].align_items = how
        return self^

    def justify(var self, how: Int) -> View:
        """On a stack: place children along its direction (START, CENTER, END, BETWEEN)."""
        self.nodes[0].justify_items = how
        return self^

    def tag(var self, name: String) -> View:
        """Names the view, for tests and accessibility."""
        self.nodes[0].name = name
        return self^

    def pin(var self, h: Int, v: Int) -> View:
        """Where an Overlay island floats: h = START, CENTER or END; v = START or END."""
        self.nodes[0].x = h
        self.nodes[0].y = v
        return self^

    def alternate(var self, title: String, msg: Int) -> View:
        """On a Button that is one face of a pair (play / pause, mute / unmute): its other face is `title`, sending `msg`.
        People see one button; an agent gets both faces as tools, each meaning one thing whatever the state (a pause while
        paused changes nothing), so it never has to read the state before acting. Hosts draw nothing new."""
        self.nodes[0].options = [title]
        self.nodes[0].size = msg
        return self^

    def settable(var self, unit: String, low: Float64, high: Float64) -> View:
        """On a Canvas that draws a control with a value (a scrubber, a dial): it can be set straight to a number from `low`
        to `high` in `unit` ("seconds"). An agent sees a `value` argument on the canvas's tool; setting it sends the canvas's
        on_gesture with event.number = SET_TO and event.text = the number. The app clamps and applies it as it would a drag."""
        self.nodes[0].options = [unit, String(low), String(high)]
        return self^

    def tooltip(var self, text: String) -> View:
        """A short explanation shown when the pointer rests on the view (hosts print it as TIP: in tests)."""
        self.nodes[0].tip = text
        return self^

    def label(var self, text: String) -> View:
        """The name a screen reader says for this view when what's on screen doesn't say it: an icon, a drawn chart,
        a dropdown with no words beside it. Never shown (a tooltip is shown and is also a name: mojoui.a11y)."""
        self.nodes[0].label = text
        return self^

    def tone(var self, t: Int) -> View:
        """A Text's colour or weight: TONE_WARN, TONE_GOOD, TONE_STRONG, TONE_ACCENT."""
        self.nodes[0].value = t
        return self^

    def focused(var self) -> View:
        """A TextField that takes the keyboard when it appears, its text selected (an in-place editor)."""
        self.nodes[0].value = 1
        return self^

    def echo(var self) -> View:
        """An in-place editor that shows text another view types into it (a grid that keeps the keyboard while you
        type a value): it doesn't take the keyboard until it's clicked."""
        self.nodes[0].value = 3
        return self^

    def passthrough(var self) -> View:
        """On a Canvas: it only shows (lines over a page, a highlight): presses go to whatever is under it, and the parts
        it leaves unpainted show what's beneath (hosts keep its alpha)."""
        self.nodes[0].size = 2
        return self^

    def at(var self, x: Int, y: Int) -> View:
        """Where the view sits inside a Board (points from its top-left)."""
        self.nodes[0].x = x
        self.nodes[0].y = y
        return self^


def _one(var node: Node) -> View:
    var nodes = List[Node]()
    nodes.append(node^)
    return View(nodes^)


# ---------- leaves ----------

def Text(text: String, style: Int = BODY) -> View:
    """A label. Styles: BODY, TITLE, HEADLINE, CAPTION."""
    return _one(Node(TEXT, text, style=style))


def Button(title: String, on_tap: Int, style: Int = PLAIN, icon: String = "") -> View:
    """Sends `on_tap` when tapped. Styles: PLAIN, PROMINENT, DESTRUCTIVE, SUBTLE, ICON_ONLY, ICON_ON, TOOL, TOOL_ON.
    `icon`: one of ICON_NAMES, shown before the title (or alone, with ICON_ONLY)."""
    return _one(Node(BUTTON, title, on_tap, style=style, hint=icon))


def FilePicker(title: String, on_pick: Int, style: Int = PLAIN, icon: String = "", accept: String = "") -> View:
    """A button that asks for a file: the platform's own file dialog (GTK), an upload (web). Sends `on_pick`
    with event.text = the file's path on the machine the app runs on. `accept`: extensions, e.g. ".csv,.parquet"."""
    return _one(Node(BUTTON, title, NO_MSG, style=style, hint=icon, msg2=on_pick, options=[accept]))


def TextField(value: String, placeholder: String = "", on_change: Int = NO_MSG, on_submit: Int = NO_MSG, on_cancel: Int = NO_MSG) -> View:
    """One line of text. Sends `on_change` (event.text = new text) as you type, `on_submit` when Return
    is pressed and `on_cancel` when Escape is (event.text = the text, unchanged by the app)."""
    return _one(Node(FIELD, value, on_change, hint=placeholder, msg2=on_submit, size=on_cancel))


def Toggle(label: String, on: Bool, on_toggle: Int) -> View:
    """An on/off switch. Sends `on_toggle` with event.number = 1 (on) or 0 (off)."""
    return _one(Node(TOGGLE, label, on_toggle, value=1 if on else 0))


def Dropdown(options: List[String], selected: Int, on_select: Int) -> View:
    """Pick one option. Sends `on_select` with event.number = index, event.text = option."""
    return _one(Node(DROPDOWN, "", on_select, value=selected, options=options.copy()))


def Slider(value: Int, on_change: Int) -> View:
    """A 0–100 slider. Sends `on_change` with event.number = the new value."""
    return _one(Node(SLIDER, "", on_change, value=value))


def ProgressBar(value: Int) -> View:
    """Shows 0–100 progress."""
    return _one(Node(PROGRESS, value=value))


def Image(pixels: List[UInt32], width: Int, height: Int) -> View:
    """A picture from RGBA pixels (row by row; each UInt32 holds R, G, B, A from the low byte up).
    If there aren't exactly width × height pixels, it shows a transparent picture of that size."""
    var w = max(width, 1)  # at least 1×1: a 0-sized PNG isn't valid
    var h = max(height, 1)
    if len(pixels) != w * h:
        return _one(Node(IMAGE, spacing=w, size=h, pixels=List[UInt32](length=w * h, fill=0)))
    return _one(Node(IMAGE, spacing=w, size=h, pixels=pixels.copy()))


def Segmented(options: List[String], selected: Int, on_select: Int) -> View:
    """A row of joined buttons, one selected. Sends `on_select` (event.number = index, event.text = option)."""
    return _one(Node(SEGMENTED, "", on_select, value=selected, options=options.copy()))


def Radio(options: List[String], selected: Int, on_select: Int) -> View:
    """Radio buttons, one selected. Sends `on_select` (event.number = index, event.text = option)."""
    return _one(Node(RADIO, "", on_select, value=selected, options=options.copy()))


def TextArea(value: String, placeholder: String = "", on_change: Int = NO_MSG, height: Int = 120) -> View:
    """Several lines of text. Sends `on_change` (event.text = all the text) as you type."""
    return _one(Node(TEXTAREA, value, on_change, hint=placeholder, size=height))


def Alert(title: String, message: String, buttons: List[String], on_choose: Int) -> View:
    """A modal question, shown for as long as it's in the view.
    Choosing a button sends `on_choose` (event.number = button index, event.text = its title)."""
    return _one(Node(ALERT, title, on_choose, hint=message, options=buttons.copy()))


def Tabs(sections: List[String], selected: Int, on_select: Int) -> View:
    """Switch between sections. Sends `on_select` (event.number = index, event.text = section)."""
    return _one(Node(TABS, "", on_select, value=selected, options=sections.copy()))


def NavBar(title: String, on_back: Int = NO_MSG) -> View:
    """A screen's title bar, with a Back button when `on_back` is given."""
    return _one(Node(NAVBAR, title, on_back))


def DatePicker(date: String, on_change: Int) -> View:
    """Pick a date. `date` and event.text are "YYYY-MM-DD"."""
    return _one(Node(DATE, date, on_change))


def Icon(name: String, size: Int = 24) -> View:
    """One of the shared icons (ICON_NAMES), drawn with each platform's own icon set."""
    return _one(Node(ICON, name, size=size))


def LazyList(count: Int, list_id: Int, on_tap: Int = NO_MSG, height: Int = 320, row_height: Int = 48) -> View:
    """A long list: only the rows on screen are built, asking the app's `row(list_id, index)`
    for their text. Tapping a row sends `on_tap` (event.number = row index).
    Hosts ask for the visible rows again after every update, so edited rows refresh."""
    return _one(Node(LAZYLIST, "", on_tap, value=count, msg2=list_id, size=height, spacing=row_height))


def Canvas(id: Int, version: Int, on_gesture: Int = NO_MSG, on_frame: Int = NO_MSG, keys: Bool = False) -> View:
    """A surface the app paints itself: hosts call the app's `draw(id, surface)` at the canvas's
    real pixel size, and again whenever `version` changes or the canvas is resized.
    Drags, pinches, wheel zooms and taps send `on_gesture` (event.number = PAN, ZOOM or TAP).
    With `on_frame`, it sends one event per display frame (event.number = microseconds since the last).
    With `keys=True` it takes the keyboard when pressed and sends `on_gesture` with event.number = KEY for each
    key (a canvas without it never holds the keyboard: Tab moves on past it).
    Size it with layout settings, e.g. `Canvas(0, v).grow().fill()`."""
    return _one(Node(CANVAS, "", on_gesture, style=id, value=version, msg2=on_frame, size=1 if keys else 0))


def Divider() -> View:
    return _one(Node(DIVIDER))


def Spacer() -> View:
    return _one(Node(SPACER))


# ---------- containers ----------

def _container(var root: Node, items: List[View]) -> View:
    var vertical = root.kind != HSTACK  # VStack, Scroll (and Grid cells) stack downwards
    var nodes = List[Node]()
    nodes.append(root^)
    for item in items:
        var base = len(nodes)
        nodes[0].children.append(base)
        for k in range(len(item.nodes)):
            var copy = item.nodes[k].copy()
            if k == 0 and nodes[0].kind != GRID and nodes[0].kind != TABLE:  # the child itself: which size does this stack decide?
                copy.width_from_parent = (copy.fills and vertical) or (copy.grows and not vertical)
                copy.height_from_parent = (copy.grows and vertical) or (copy.fills and not vertical)
            for i in range(len(copy.children)):
                copy.children[i] += base
            nodes.append(copy^)
    return View(nodes^)


def Overlay(base: View, *islands: View) -> View:
    """`base` fills the overlay; each island floats over it where its .pin(h, v) says
    (h: START, CENTER or END; v: START or END), a small margin in from the edge. For canvas apps:
    the page scrolls underneath, the chrome stays put."""
    var items = List[View]()
    items.append(base.copy())
    for item in islands:
        items.append(item.copy())
    var v = _container(Node(OVERLAY), items)
    return v^


def Board(items: List[View], width: Int, height: Int, on_move: Int = NO_MSG, on_resize: Int = NO_MSG,
          reveal: Int = -1, reveal_count: Int = 0, tones: List[Int] = [], on_hold: Int = NO_MSG) -> View:
    """A page: children sit where their .at(x, y) says, sized by .width/.height (a Numbers-style
    free-flow layout). Dragging a child's edge area moves it (on_move: event.number = child index,
    event.dx/dy = how far); dragging its bottom-right corner resizes it (on_resize, the same fields).
    Hosts narrower than 720 points show the children as a full-width list instead.
    The Board scrolls when it's bigger than the space it's given (grow/fill it to give it the space).
    reveal: a child to scroll into view, done once per new reveal_count (count up each time).
    tones: per child, how it stands while something is shown about the page (goal 41 M8, a peek or a drop): BOARD_PLAIN,
    BOARD_DIM (steps back: dimmed, grey, a little smaller; never blurred), BOARD_LIFT (rises, ringed in the accent),
    BOARD_SOURCE (the one held), BOARD_TARGET (a drop would land here); hosts ease between tones, and a change is a
    patch (nothing is built again). on_hold: pressing a child and holding still for HOLD_MS sends it with
    event.number = the child's index and event.text = "hold"; letting go afterwards sends it again with "release"."""
    var n = Node(BOARD, msg=on_move, msg2=on_resize, spacing=width, size=height,
                 value=reveal_count * 64 + reveal + 1 if 0 <= reveal < 63 else 0)
    var any = False
    for t in tones:
        if t != BOARD_PLAIN:
            any = True
    if any:  # (all plain: no options, so a page that never peeks reads as it always did)
        for t in tones:
            n.options.append(String(t))
    if on_hold != NO_MSG:
        n.hint = String(on_hold)
    var v = _container(n^, items)
    return v^


comptime BOARD_PLAIN = 0  # a Board child's tone (Board(tones=…)): as it is
comptime BOARD_DIM = 1  # stepped back (a peek's unrelated cards)
comptime BOARD_LIFT = 2  # raised and ringed (a peek's linked cards)
comptime BOARD_SOURCE = 3  # the card held
comptime BOARD_TARGET = 4  # under a drag: a drop lands here
comptime HOLD_MS = 350  # how long a press on a Board child must stay still to be a hold


def VStack(*items: View, spacing: Int = 16) -> View:
    """Children top to bottom."""
    var list = List[View]()
    for item in items:
        list.append(item.copy())
    return _container(Node(VSTACK, spacing=spacing), list)


def VStack(items: List[View], spacing: Int = 16) -> View:
    """Children top to bottom, from a list (for rows that come and go)."""
    return _container(Node(VSTACK, spacing=spacing), items)


def Card(*items: View, spacing: Int = 12, tone: Int = CARD) -> View:
    """A raised panel holding its children top to bottom, left-aligned (padded 16). Hosts draw their own card look;
    hosts that don't know cards show it as a plain VStack. tone: CARD, CARD_WARN (a finding) or CARD_GOOD."""
    var list = List[View]()
    for item in items:
        list.append(item.copy())
    var v = _container(Node(VSTACK, spacing=spacing, style=tone), list)
    return v^.padding(16).align(START)


def Card(items: List[View], spacing: Int = 12, tone: Int = CARD) -> View:
    """A card from a list of children (for panels whose rows come and go)."""
    var v = _container(Node(VSTACK, spacing=spacing, style=tone), items)
    return v^.padding(16).align(START)


def HStack(*items: View, spacing: Int = 8) -> View:
    """Children left to right."""
    var list = List[View]()
    for item in items:
        list.append(item.copy())
    return _container(Node(HSTACK, spacing=spacing), list)


def HStack(items: List[View], spacing: Int = 8) -> View:
    return _container(Node(HSTACK, spacing=spacing), items)


def Grid(items: List[View], columns: Int, spacing: Int = 12, fit: Bool = False, end: Bool = False, shares: List[Int] = []) -> View:
    """Items in rows of `columns`, the columns equal; `fit`: every column but the last as wide as its widest item, the
    last the rest (a definition list's keys and values; style 1); `end`: the last column's items at its trailing edge
    (hint "E": figures and values read from the right, D-474); `shares`: each column's share of the width (52, 48: a
    key column 52 % wide; options), over `fit`."""
    var opts = List[String]()
    for s in shares:
        opts.append(String(s))
    return _container(Node(GRID, style=1 if fit else 0, spacing=spacing, value=max(columns, 1), options=opts^, hint="E" if end else ""), items)


def Scroll(content: View, height: Int = 320, pinned: Bool = False) -> View:
    """Shows `content`, scrolling when it's taller than `height` points (0: as tall as its stack gives it: grow() it). `pinned`: it stays at its end as the content
    grows (a log), unless the person scrolls up; back at the end, it follows again."""
    var list = List[View]()
    list.append(content.copy())
    return _container(Node(SCROLL, size=height, value=1 if pinned else 0), list)


def TableGrid(var cells: List[View], columns: Int, align: String = "", selected: String = "", dense: Bool = False,
              var limits: List[String] = [], compact: Bool = False) -> View:
    """The raw table (mojoui.table.Table builds it): `cells` = the header's `columns` cells, then the body's, row by row;
    `align` one letter per column (L, R); `selected` one letter per body row ("1": selected); `dense`: the dense cells
    (style 1; 2 dense and compact); `limits` per column: "" none, "W" its cells wrap, a number its cells' widest (they stay on one line, cut),
    "T" a tick column (as narrow as its box); a trailing "S": its cells snug (role table-dense-snug). Table writes C and N
    for the theme's widths, which the runtime turns into numbers (mojoui.look.resolve_layout)."""
    var cols = max(columns, 1)
    var a = String("")
    for k in range(cols):
        a += String(align[byte=k]) if k < align.byte_length() and String(align[byte=k]) == "R" else String("L")
    return _container(Node(TABLE, selected, style=(2 if compact else 1) if dense else 0, value=cols, options=limits^, hint=a), cells)
