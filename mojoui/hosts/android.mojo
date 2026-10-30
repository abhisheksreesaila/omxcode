# Android host: draws a mojoui View with real Android views (TextView, Button, EditText,
# Switch, Spinner, SeekBar, LinearLayout…), created and changed from Mojo through JNI.
#
# Android calls back only Java objects, so mojoui/hosts/android/MojoActivity.java (the
# framework's one Java file) forwards every callback here: event() for taps, typing and
# choices, touch() for canvases, frame() once per display frame, row() for long lists.
# Each view's id is its node index + 1, so a callback names the node it came from.

from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from std.math import sqrt

from mojoui.view import (
    TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE,
    SEGMENTED, RADIO, TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, PARAGRAPH, PAN, ZOOM, TAP,
    START, CENTER, END, STRETCH, BETWEEN, AUTO, Node,
    TITLE, HEADLINE, CAPTION, PROMINENT, DESTRUCTIVE,
)
from mojoui.diff import Diff, SET_TEXT, SET_VALUE, SET_IMAGE, SET_FRAMES
from mojoui.app import App, Event, Runtime, budget_from_env
from mojoui.canvas import Surface
from mojoui.hosts.jni import Jni, fbits, log, utf16_length

comptime ACTIVITY = "dev/mojoui/MojoActivity"
comptime CONTEXT = "(Landroid/content/Context;)V"
comptime CHARS = "(Ljava/lang/CharSequence;)V"
comptime MATCH = -1  # ViewGroup.LayoutParams.MATCH_PARENT
comptime WRAP = -2  # WRAP_CONTENT
# Gravity
comptime LEFT = 3
comptime RIGHT = 5
comptime TOP = 48
comptime BOTTOM = 80
comptime CENTER_H = 1
comptime CENTER_V = 16
comptime CENTERED = 17
comptime OPTION_IDS = 1_000_000  # option j of a radio group has id OPTION_IDS + j (never a node's id)


struct DroidCanvas(Copyable, Movable):
    """One Canvas on screen: its ImageView, the pixels last drawn, and the touch in progress."""

    var node: Int
    var view: Int  # global reference
    var pixels: List[UInt32]
    var wpx: Int
    var hpx: Int
    var drawn: Int
    var last_x: Float64
    var last_y: Float64
    var fresh: Bool  # no previous point to measure a drag from
    var moved: Bool
    var spread: Float64  # distance between two fingers (0: not pinching)
    var last_ns: Int
    var bitmap: Int  # global reference to a mutable Bitmap the size of the canvas, reused every frame

    def __init__(out self, node: Int, view: Int):
        self.node = node
        self.view = view
        self.pixels = List[UInt32]()
        self.wpx = 0
        self.hpx = 0
        self.drawn = -1
        self.last_x = 0
        self.last_y = 0
        self.fresh = True
        self.moved = False
        self.spread = 0
        self.last_ns = 0
        self.bitmap = 0


struct AndroidHost[A: App](Movable):
    var rt: Runtime[Self.A]
    var jni: Jni
    var activity: Int  # global reference to the MojoActivity
    var widgets: List[Int]  # a global reference per node (0: none)
    var density: Float64  # pixels per dp (Android's point)
    var focus: Int  # text field to keep focused across the next rebuild (-1: none)
    var canvases: List[DroidCanvas]
    var ticking: Bool  # a frame callback is posted

    def __init__(out self, env: Int, activity: Int):
        Self.A.init_shared()
        self.rt = Runtime(Self.A())
        self.rt.watch(budget_from_env())  # MOJOUI_BUDGET_MS: the slow-frame watchdog (SLOW: lines on stdout)
        self.jni = Jni(env)
        self.activity = self.jni.keep(activity)
        self.widgets = List[Int]()
        self.focus = -1
        self.canvases = List[DroidCanvas]()
        self.ticking = False
        var res = self.jni.call(activity, "android/content/Context", "getResources", "()Landroid/content/res/Resources;")
        var metrics = self.jni.call(res, "android/content/res/Resources", "getDisplayMetrics", "()Landroid/util/DisplayMetrics;")
        self.density = self.jni.float_field(metrics, "android/util/DisplayMetrics", "density")
        self.jni.drop(metrics)
        self.jni.drop(res)

    def dp(self, points: Int) -> Int:
        return Int(Float64(points) * self.density + 0.5)

    def quiet(mut self, on: Bool):
        """While we change views ourselves, their listeners stay quiet (a Java field: callbacks
        arrive re-entrantly, so the flag can't be a Mojo field; see docs/lessons.md)."""
        self.jni.set_bool_field(self.activity, ACTIVITY, "quiet", on)

    # ---------- small view helpers ----------

    def set_text(mut self, v: Int, text: String):
        var s = self.jni.string(text)
        _ = self.jni.call(v, "android/widget/TextView", "setText", CHARS, [s])
        self.jni.drop(s)

    def describe(mut self, v: Int, text: String):
        """The accessibility description (screen readers; tests read values and tags from it)."""
        var s = self.jni.string(text)
        _ = self.jni.call(v, "android/view/View", "setContentDescription", CHARS, [s])
        self.jni.drop(s)

    def listen(mut self, v: Int, class_name: String, setter: String, listener: String):
        _ = self.jni.call(v, class_name, setter, "(L" + listener + ";)V", [self.activity])

    def view_of(mut self, class_name: String) -> Int:
        return self.jni.new(class_name, CONTEXT, [self.activity])

    # ---------- building ----------

    def build(mut self, i: Int) -> Int:
        """Creates the Android view for node i (and its children); returns a local reference."""
        var node = self.rt.shown.nodes[i].copy()
        var v: Int
        if node.kind == TEXT or node.kind == PARAGRAPH or node.kind == ICON or node.kind == DATE or node.kind == ALERT:  # (a Paragraph: its plain words; its runs' looks: not yet)
            v = self.view_of("android/widget/TextView")
            var look = "TextAppearance_DeviceDefault_Small" if node.style == CAPTION else (
                "TextAppearance_DeviceDefault_Large" if node.style == TITLE or node.style == HEADLINE else "TextAppearance_DeviceDefault")
            _ = self.jni.call(v, "android/widget/TextView", "setTextAppearance", "(I)V", [self.jni.static_int("android/R$style", look)])
            self.set_text(v, node.text)
            _ = self.jni.call(v, "android/widget/TextView", "setGravity", "(I)V", [CENTERED])
            var size = 16.0
            if node.style == TITLE:
                size = 28.0
            elif node.style == HEADLINE:
                size = 18.0
            elif node.style == CAPTION:
                size = 13.0
                _ = self.jni.call(v, "android/widget/TextView", "setTextColor", "(I)V", [0xFF8E8E93])
            _ = self.jni.call(v, "android/widget/TextView", "setTextSize", "(F)V", [fbits(size)])
            if node.style == TITLE or node.style == HEADLINE:
                _ = self.jni.call(v, "android/widget/TextView", "setTypeface", "(Landroid/graphics/Typeface;I)V", [0, 1])
            if node.max_w != 0:
                _ = self.jni.call(v, "android/widget/TextView", "setMaxWidth", "(I)V", [self.dp(node.max_w)])
                if node.fills:  # fill + max width: exactly the max (when there's room), like the other hosts
                    _ = self.jni.call(v, "android/widget/TextView", "setMinWidth", "(I)V", [self.dp(node.max_w)])
            if node.kind == ALERT:  # (alerts come in a later goal)
                _ = self.jni.call(v, "android/view/View", "setVisibility", "(I)V", [8])
        elif node.kind == BUTTON:
            v = self.view_of("android/widget/Button")
            self.set_text(v, node.text)
            _ = self.jni.call(v, "android/widget/TextView", "setAllCaps", "(Z)V", [0])
            if node.style == PROMINENT:
                var tint = self.jni.static_call("android/content/res/ColorStateList", "valueOf", "(I)Landroid/content/res/ColorStateList;", [0xFF0A84FF])
                _ = self.jni.call(v, "android/view/View", "setBackgroundTintList", "(Landroid/content/res/ColorStateList;)V", [tint])
                _ = self.jni.call(v, "android/widget/TextView", "setTextColor", "(I)V", [0xFFFFFFFF])
                self.jni.drop(tint)
            elif node.style == DESTRUCTIVE:
                _ = self.jni.call(v, "android/widget/TextView", "setTextColor", "(I)V", [0xFFFF453A])
            self.listen(v, "android/view/View", "setOnClickListener", "android/view/View$OnClickListener")
        elif node.kind == FIELD or node.kind == TEXTAREA:
            v = self.view_of("android/widget/EditText")
            self.set_text(v, node.text)
            var hint = self.jni.string(node.hint)
            _ = self.jni.call(v, "android/widget/TextView", "setHint", CHARS, [hint])
            self.jni.drop(hint)
            if node.kind == FIELD:
                _ = self.jni.call(v, "android/widget/TextView", "setSingleLine", "(Z)V", [1])
                _ = self.jni.call(v, "android/widget/TextView", "setImeOptions", "(I)V", [6])  # Done
                self.listen(v, "android/widget/TextView", "setOnEditorActionListener", "android/widget/TextView$OnEditorActionListener")
            else:
                _ = self.jni.call(v, "android/widget/TextView", "setMinLines", "(I)V", [3])
            var watcher = self.jni.call(self.activity, ACTIVITY, "typing", "(I)Landroid/text/TextWatcher;", [i + 1])
            _ = self.jni.call(v, "android/widget/TextView", "addTextChangedListener", "(Landroid/text/TextWatcher;)V", [watcher])
            self.jni.drop(watcher)
        elif node.kind == TOGGLE:
            v = self.view_of("android/widget/Switch")
            self.set_text(v, node.text)
            _ = self.jni.call(v, "android/widget/CompoundButton", "setChecked", "(Z)V", [node.value])
            self.listen(v, "android/widget/CompoundButton", "setOnCheckedChangeListener", "android/widget/CompoundButton$OnCheckedChangeListener")
        elif node.kind == DROPDOWN:
            v = self.view_of("android/widget/Spinner")
            var items = self.jni.strings(node.options)
            var layout = self.jni.static_int("android/R$layout", "simple_spinner_dropdown_item")
            var adapter = self.jni.new("android/widget/ArrayAdapter", "(Landroid/content/Context;I[Ljava/lang/Object;)V", [self.activity, layout, items])
            _ = self.jni.call(v, "android/widget/AdapterView", "setAdapter", "(Landroid/widget/Adapter;)V", [adapter])
            _ = self.jni.call(v, "android/widget/AbsSpinner", "setSelection", "(IZ)V", [node.value, 0])
            self.listen(v, "android/widget/AdapterView", "setOnItemSelectedListener", "android/widget/AdapterView$OnItemSelectedListener")
            self.jni.drop(adapter)
            self.jni.drop(items)
        elif node.kind == SLIDER:
            v = self.view_of("android/widget/SeekBar")
            _ = self.jni.call(v, "android/widget/ProgressBar", "setMax", "(I)V", [100])
            _ = self.jni.call(v, "android/widget/ProgressBar", "setProgress", "(I)V", [node.value])
            _ = self.jni.call(v, "android/widget/AbsSeekBar", "setKeyProgressIncrement", "(I)V", [1])
            self.describe(v, String(node.value))
            self.listen(v, "android/widget/SeekBar", "setOnSeekBarChangeListener", "android/widget/SeekBar$OnSeekBarChangeListener")
        elif node.kind == PROGRESS:
            var style = self.jni.static_int("android/R$attr", "progressBarStyleHorizontal")
            v = self.jni.new("android/widget/ProgressBar", "(Landroid/content/Context;Landroid/util/AttributeSet;I)V", [self.activity, 0, style])
            _ = self.jni.call(v, "android/widget/ProgressBar", "setMax", "(I)V", [100])
            _ = self.jni.call(v, "android/widget/ProgressBar", "setProgress", "(I)V", [node.value])
            self.describe(v, String(node.value))
        elif node.kind == DIVIDER or node.kind == SPACER:
            v = self.view_of("android/view/View")
            if node.kind == DIVIDER:
                _ = self.jni.call(v, "android/view/View", "setBackgroundColor", "(I)V", [0x40888888])
        elif node.kind == IMAGE:
            v = self.view_of("android/widget/ImageView")
            self.show_pixels(v, node.pixels, node.spacing, node.size)
            self.describe(v, String(node.spacing) + "x" + String(node.size))
        elif node.kind == CANVAS:
            v = self.view_of("android/widget/ImageView")
            var fit = self.jni.static_object("android/widget/ImageView$ScaleType", "FIT_XY", "Landroid/widget/ImageView$ScaleType;")
            _ = self.jni.call(v, "android/widget/ImageView", "setScaleType", "(Landroid/widget/ImageView$ScaleType;)V", [fit])
            self.jni.drop(fit)
            self.listen(v, "android/view/View", "setOnTouchListener", "android/view/View$OnTouchListener")
            self.canvases.append(DroidCanvas(i, self.jni.keep(v)))
        elif node.kind == SEGMENTED or node.kind == TABS or node.kind == RADIO:
            v = self.view_of("android/widget/RadioGroup")
            _ = self.jni.call(v, "android/widget/LinearLayout", "setOrientation", "(I)V", [1 if node.kind == RADIO else 0])
            for j in range(len(node.options)):
                var b = self.view_of("android/widget/RadioButton")
                self.set_text(b, node.options[j])
                if node.kind != RADIO:  # segments: no circles; the chosen one is highlighted
                    _ = self.jni.call(b, "android/widget/CompoundButton", "setButtonDrawable", "(Landroid/graphics/drawable/Drawable;)V", [0])
                    var pad = self.dp(14)
                    _ = self.jni.call(b, "android/view/View", "setPadding", "(IIII)V", [pad, self.dp(10), pad, self.dp(10)])
                    var states = self.jni.new("android/graphics/drawable/StateListDrawable", "()V", [])
                    var checked = self.jni.ints([Int32(self.jni.static_int("android/R$attr", "state_checked"))])
                    var fill = self.jni.new("android/graphics/drawable/ColorDrawable", "(I)V", [0x330A84FF])
                    _ = self.jni.call(states, "android/graphics/drawable/StateListDrawable", "addState", "([ILandroid/graphics/drawable/Drawable;)V", [checked, fill])
                    _ = self.jni.call(b, "android/view/View", "setBackground", "(Landroid/graphics/drawable/Drawable;)V", [states])
                    self.jni.drop(fill)
                    self.jni.drop(checked)
                    self.jni.drop(states)
                _ = self.jni.call(b, "android/view/View", "setId", "(I)V", [OPTION_IDS + j])
                _ = self.jni.call(v, "android/view/ViewGroup", "addView", "(Landroid/view/View;)V", [b])
                self.jni.drop(b)
            _ = self.jni.call(v, "android/widget/RadioGroup", "check", "(I)V", [OPTION_IDS + node.value])
            self.listen(v, "android/widget/RadioGroup", "setOnCheckedChangeListener", "android/widget/RadioGroup$OnCheckedChangeListener")
            self.describe(v, "segmented" if node.kind == SEGMENTED else ("tabs" if node.kind == TABS else "radio"))
        elif node.kind == LAZYLIST:
            v = self.view_of("android/widget/ListView")
            var adapter = self.jni.call(self.activity, ACTIVITY, "rows", "(II)Landroid/widget/BaseAdapter;", [i + 1, node.value])
            _ = self.jni.call(v, "android/widget/ListView", "setAdapter", "(Landroid/widget/ListAdapter;)V", [adapter])
            self.jni.drop(adapter)
            self.listen(v, "android/widget/AdapterView", "setOnItemClickListener", "android/widget/AdapterView$OnItemClickListener")
        elif node.kind == SCROLL:
            v = self.view_of("android/widget/ScrollView")
            for c in node.children:
                var child = self.build(c)
                var params = self.params(node, self.rt.shown.nodes[c].copy(), 0)
                _ = self.jni.call(v, "android/view/ViewGroup", "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", [child, params])
                self.jni.drop(params)
                self.jni.drop(child)
        else:  # stacks, grids and nav bars: LinearLayouts
            v = self.view_of("android/widget/LinearLayout")
            var vertical = node.kind == VSTACK or node.kind == GRID
            _ = self.jni.call(v, "android/widget/LinearLayout", "setOrientation", "(I)V", [1 if vertical else 0])
            _ = self.jni.call(v, "android/widget/LinearLayout", "setGravity", "(I)V", [self.gravity(node, vertical)])
            var between = node.justify_items == BETWEEN
            for c in node.children:
                if self.rt.shown.nodes[c].grows:
                    between = False  # a growing child takes the free space itself
            if node.kind == NAVBAR and node.msg != 0:
                var back = self.view_of("android/widget/Button")
                self.set_text(back, "‹ Back")
                _ = self.jni.call(back, "android/view/View", "setId", "(I)V", [i + 1])
                self.listen(back, "android/view/View", "setOnClickListener", "android/view/View$OnClickListener")
                _ = self.jni.call(v, "android/view/ViewGroup", "addView", "(Landroid/view/View;)V", [back])
                self.jni.drop(back)
            if node.kind == NAVBAR:
                var title = self.view_of("android/widget/TextView")
                self.set_text(title, node.text)
                _ = self.jni.call(title, "android/widget/TextView", "setTextSize", "(F)V", [fbits(22)])
                _ = self.jni.call(v, "android/view/ViewGroup", "addView", "(Landroid/view/View;)V", [title])
                self.jni.drop(title)
            for k in range(len(node.children)):
                var c = node.children[k]
                if between and k > 0:
                    var gap = self.view_of("android/view/View")
                    var gp = self.jni.new("android/widget/LinearLayout$LayoutParams", "(IIF)V", [0, 0, fbits(1)])
                    _ = self.jni.call(v, "android/view/ViewGroup", "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", [gap, gp])
                    self.jni.drop(gp)
                    self.jni.drop(gap)
                var child = self.build(c)
                var params = self.params(node, self.rt.shown.nodes[c].copy(), k)
                _ = self.jni.call(v, "android/view/ViewGroup", "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", [child, params])
                self.jni.drop(params)
                self.jni.drop(child)
        if node.kind != NAVBAR:
            _ = self.jni.call(v, "android/view/View", "setId", "(I)V", [i + 1])
        if node.pad_v != 0 or node.pad_h != 0:
            _ = self.jni.call(v, "android/view/View", "setPadding", "(IIII)V", [self.dp(node.pad_h), self.dp(node.pad_v), self.dp(node.pad_h), self.dp(node.pad_v)])
        if node.min_w != 0:
            _ = self.jni.call(v, "android/view/View", "setMinimumWidth", "(I)V", [self.dp(node.min_w)])
        if node.name != "" and node.kind != SLIDER and node.kind != PROGRESS and node.kind != IMAGE:
            self.describe(v, node.name)
        self.widgets[i] = self.jni.keep(v)
        return v

    def gravity(self, node: Node, vertical: Bool) -> Int:
        """A stack's align (across it) and justify (along it) as Android gravity."""
        var cross = CENTER_H if vertical else CENTER_V
        if node.align_items == START:
            cross = LEFT if vertical else TOP
        elif node.align_items == END:
            cross = RIGHT if vertical else BOTTOM
        var along = TOP if vertical else LEFT
        if node.justify_items == CENTER:
            along = CENTER_V if vertical else CENTER_H
        elif node.justify_items == END:
            along = BOTTOM if vertical else RIGHT
        return cross | along

    def default_width(self, n: Node) -> Int:
        """A control's own width when the app doesn't size it (as on the other hosts)."""
        if n.kind == FIELD:
            return 220
        if n.kind == SLIDER or n.kind == PROGRESS:
            return 240
        if n.kind == DIVIDER:
            return 280
        if n.kind == LAZYLIST:
            return 340
        if n.kind == CANVAS:
            return 320
        return 0

    def params(mut self, parent: Node, n: Node, k: Int) -> Int:
        """LinearLayout.LayoutParams for child n of `parent` (k-th child): the child's layout settings."""
        var vertical = parent.kind != HSTACK
        var w = WRAP
        var h = WRAP
        var weight = 0.0
        if n.w != 0:
            w = self.dp(n.w)
        elif (n.fills and vertical) or (parent.align_items == STRETCH and vertical) or n.kind == SCROLL and vertical:
            w = MATCH
        elif n.grows and not vertical:
            w = 0
            weight = 1
        elif self.default_width(n) != 0:
            w = self.dp(self.default_width(n))
        if n.h != 0:
            h = self.dp(n.h)
        elif (n.fills and not vertical) or (parent.align_items == STRETCH and not vertical):
            h = MATCH
        elif n.grows and vertical:
            h = 0
            weight = 1
        elif n.kind == DIVIDER:
            h = self.dp(1)
        elif n.kind == SCROLL or n.kind == LAZYLIST:
            h = self.dp(n.size)
        elif n.kind == IMAGE:
            h = self.dp(n.size)
            w = self.dp(n.spacing) if n.w == 0 else w
        elif n.kind == CANVAS:
            h = self.dp(240)
        if n.kind == SPACER:
            weight = 1
        if n.fills and n.max_w != 0 and vertical:  # as wide as its max (the text view sizes itself)
            w = WRAP
        var p = self.jni.new("android/widget/LinearLayout$LayoutParams", "(IIF)V", [w, h, fbits(weight)])
        if k > 0 and parent.kind != SCROLL:
            var gap = self.dp(parent.spacing)
            _ = self.jni.call(p, "android/view/ViewGroup$MarginLayoutParams", "setMargins", "(IIII)V", [0 if vertical else gap, gap if vertical else 0, 0, 0])
        return p

    def add_flexible_space(mut self, parent: Int):
        var gap = self.view_of("android/view/View")
        var gp = self.jni.new("android/widget/LinearLayout$LayoutParams", "(IIF)V", [0, 0, fbits(1)])
        _ = self.jni.call(parent, "android/view/ViewGroup", "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", [gap, gp])
        self.jni.drop(gp)
        self.jni.drop(gap)

    def show(mut self):
        """(Re)builds the whole screen from rt.shown."""
        self.quiet(True)
        for w in self.widgets:
            self.jni.forget(w)
        for ref c in self.canvases:
            self.jni.forget(c.view)
            self.jni.forget(c.bitmap)
        self.widgets = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.canvases = List[DroidCanvas]()
        var root = self.build(0)
        var full = self.rt.shown.nodes[0].grows or self.rt.shown.nodes[0].fills
        if full:  # the screen fills the window
            var frame = self.view_of("android/widget/FrameLayout")  # takes the system bars' insets (as padding),
            _ = self.jni.call(frame, "android/view/View", "setFitsSystemWindows", "(Z)V", [1])  # keeping the root's own padding
            _ = self.jni.call(frame, "android/view/ViewGroup", "addView", "(Landroid/view/View;)V", [root])
            _ = self.jni.call(self.activity, "android/app/Activity", "setContentView", "(Landroid/view/View;)V", [frame])
            self.jni.drop(frame)
        else:  # centred, scrolling if taller than the screen
            # (Flexible space above and below centres it when it fits and shrinks to nothing
            # when it doesn't; centring by gravity would push its top off screen, unscrollable.)
            var holder = self.view_of("android/widget/LinearLayout")
            _ = self.jni.call(holder, "android/widget/LinearLayout", "setOrientation", "(I)V", [1])
            _ = self.jni.call(holder, "android/widget/LinearLayout", "setGravity", "(I)V", [CENTER_H])
            self.add_flexible_space(holder)
            var pad = self.dp(24)
            _ = self.jni.call(holder, "android/view/View", "setPadding", "(IIII)V", [pad, pad, pad, pad])
            ref top = self.rt.shown.nodes[0]  # the screen's own size settings
            var p = self.jni.new("android/widget/LinearLayout$LayoutParams", "(II)V", [self.dp(top.w) if top.w != 0 else WRAP, self.dp(top.h) if top.h != 0 else WRAP])
            _ = self.jni.call(holder, "android/view/ViewGroup", "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", [root, p])
            self.add_flexible_space(holder)
            var scroll = self.view_of("android/widget/ScrollView")
            _ = self.jni.call(scroll, "android/widget/ScrollView", "setFillViewport", "(Z)V", [1])
            _ = self.jni.call(scroll, "android/view/View", "setFitsSystemWindows", "(Z)V", [1])  # Android 15+ draws edge to edge
            _ = self.jni.call(scroll, "android/view/ViewGroup", "addView", "(Landroid/view/View;)V", [holder])
            _ = self.jni.call(self.activity, "android/app/Activity", "setContentView", "(Landroid/view/View;)V", [scroll])
            self.jni.drop(p)
            self.jni.drop(holder)
            self.jni.drop(scroll)
        self.jni.drop(root)
        if 0 <= self.focus < len(self.widgets) and self.rt.shown.nodes[self.focus].kind == FIELD:
            var f = self.widgets[self.focus]  # keep typing in the new field, cursor at the end
            _ = self.jni.call_bool(f, "android/view/View", "requestFocus", "()Z")
            _ = self.jni.call(f, "android/widget/EditText", "setSelection", "(I)V", [utf16_length(self.rt.shown.nodes[self.focus].text)])
        self.focus = -1
        self.quiet(False)
        self.tick_soon()

    def apply(mut self, d: Diff):
        if d.rebuild:
            self.show()
            return
        self.quiet(True)
        for p in d.patches:
            var v = self.widgets[p.node]
            var kind = self.rt.shown.nodes[p.node].kind
            if v == 0:
                continue
            if p.op == SET_TEXT and (kind == TEXT or kind == BUTTON or kind == TOGGLE or kind == ICON or kind == DATE):
                self.set_text(v, p.text)
            elif p.op == SET_TEXT and (kind == FIELD or kind == TEXTAREA):
                var current = self.jni.call(v, "android/widget/TextView", "getText", "()Ljava/lang/CharSequence;")
                var s = self.jni.call(current, "java/lang/Object", "toString", "()Ljava/lang/String;")
                if self.jni.text(s) != p.text:  # don't fight the typist
                    self.set_text(v, p.text)
                    _ = self.jni.call(v, "android/widget/EditText", "setSelection", "(I)V", [utf16_length(p.text)])
                self.jni.drop(s)
                self.jni.drop(current)
            elif p.op == SET_VALUE and kind == TOGGLE:
                _ = self.jni.call(v, "android/widget/CompoundButton", "setChecked", "(Z)V", [p.number])
            elif p.op == SET_VALUE and kind == DROPDOWN:
                _ = self.jni.call(v, "android/widget/AbsSpinner", "setSelection", "(IZ)V", [p.number, 0])
            elif p.op == SET_VALUE and (kind == SLIDER or kind == PROGRESS):
                _ = self.jni.call(v, "android/widget/ProgressBar", "setProgress", "(I)V", [p.number])
                self.describe(v, String(p.number))
            elif p.op == SET_VALUE and (kind == SEGMENTED or kind == TABS or kind == RADIO):
                _ = self.jni.call(v, "android/widget/RadioGroup", "check", "(I)V", [OPTION_IDS + p.number])
            elif p.op == SET_VALUE and kind == LAZYLIST:
                var adapter = self.jni.call(self.activity, ACTIVITY, "rows", "(II)Landroid/widget/BaseAdapter;", [p.node + 1, p.number])
                _ = self.jni.call(v, "android/widget/ListView", "setAdapter", "(Landroid/widget/ListAdapter;)V", [adapter])
                self.jni.drop(adapter)
            elif p.op == SET_IMAGE:
                ref img = self.rt.shown.nodes[p.node]
                var pixels = img.pixels.copy()
                self.show_pixels(v, pixels, img.spacing, img.size)
        # Long lists ask for their visible rows again: row text isn't part of the view.
        for k in range(len(self.rt.shown.nodes)):
            if self.rt.shown.nodes[k].kind == LAZYLIST and self.widgets[k] != 0:
                var adapter = self.jni.call(self.widgets[k], "android/widget/AdapterView", "getAdapter", "()Landroid/widget/Adapter;")
                _ = self.jni.call(adapter, "android/widget/BaseAdapter", "notifyDataSetChanged", "()V")
                self.jni.drop(adapter)
        self.quiet(False)
        self.tick_soon()

    def send(mut self, node: Int, second: Bool, text: String, number: Int):
        """A view changed: build the event, run update(), change the views."""
        if node < 0 or node >= len(self.rt.shown.nodes):
            return
        ref n = self.rt.shown.nodes[node]
        var message = n.msg2 if second else n.msg
        if message == 0:
            return
        var event_text = text
        if n.kind == DROPDOWN or n.kind == SEGMENTED or n.kind == TABS or n.kind == RADIO:
            if number == n.value or number < 0 or number >= len(n.options):
                return  # Android reports the selection it was given, too
            event_text = n.options[number]
        if (n.kind == TOGGLE or n.kind == SLIDER) and number == n.value:
            return
        if (n.kind == FIELD or n.kind == TEXTAREA) and not second and text == n.text:
            return
        self.focus = node if n.kind == FIELD else -1
        var d = self.rt.dispatch(Event(message, event_text, number))
        self.apply(d)

    # ---------- pixels, canvases and frames ----------

    def show_pixels(mut self, view: Int, pixels: List[UInt32], w: Int, h: Int):
        """Puts RGBA pixels (R in the low byte) into an ImageView as an ARGB Bitmap."""
        if w <= 0 or h <= 0 or len(pixels) < w * h:
            return
        var argb = List[Int32](length=w * h, fill=0)
        for k in range(w * h):
            var c = pixels[k]
            argb[k] = Int32(((c & 0xFF000000) | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)).cast[DType.int32]())
        var arr = self.jni.ints(argb)
        var config = self.jni.static_object("android/graphics/Bitmap$Config", "ARGB_8888", "Landroid/graphics/Bitmap$Config;")
        var bitmap = self.jni.static_call("android/graphics/Bitmap", "createBitmap", "([IIILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;", [arr, w, h, config])
        _ = self.jni.call(view, "android/widget/ImageView", "setImageBitmap", "(Landroid/graphics/Bitmap;)V", [bitmap])
        self.jni.drop(bitmap)
        self.jni.drop(config)
        self.jni.drop(arr)

    def canvas_at(self, node: Int) -> Int:
        for k in range(len(self.canvases)):
            if self.canvases[k].node == node:
                return k
        return -1

    def needs_frames(self) -> Bool:
        for ref c in self.canvases:
            if self.rt.shown.nodes[c.node].msg2 != 0 or c.drawn != self.rt.shown.nodes[c.node].value or c.wpx == 0:
                return True
        return False

    def tick_soon(mut self):
        """Asks for one display-frame callback (Choreographer) if a canvas needs drawing."""
        if self.ticking or not self.needs_frames():
            return
        self.ticking = True
        var choreographer = self.jni.static_call("android/view/Choreographer", "getInstance", "()Landroid/view/Choreographer;")
        _ = self.jni.call(choreographer, "android/view/Choreographer", "postFrameCallback", "(Landroid/view/Choreographer$FrameCallback;)V", [self.activity])
        self.jni.drop(choreographer)

    def frame(mut self, nanos: Int):
        """One display frame: frame events for canvases that asked, then redraws."""
        self.ticking = False
        var k = 0
        while k < len(self.canvases):
            var node = self.canvases[k].node
            if self.rt.shown.nodes[node].msg2 != 0:
                var last = self.canvases[k].last_ns
                self.canvases[k].last_ns = nanos
                var d = self.rt.frame(node, (nanos - last) // 1000 if last > 0 else 16667)
                self.apply(d)
                if d.rebuild:
                    return
            else:
                self.canvases[k].last_ns = 0
            self.draw_canvas(k)
            k += 1
        self.tick_soon()

    def draw_canvas(mut self, k: Int):
        var view = self.canvases[k].view
        var node = self.canvases[k].node
        var wpx = self.jni.call_int(view, "android/view/View", "getWidth", "()I")
        var hpx = self.jni.call_int(view, "android/view/View", "getHeight", "()I")
        var version = self.rt.shown.nodes[node].value
        if wpx <= 0 or hpx <= 0 or (wpx == self.canvases[k].wpx and hpx == self.canvases[k].hpx and version == self.canvases[k].drawn):
            return
        if len(self.canvases[k].pixels) != wpx * hpx:
            self.canvases[k].pixels = List[UInt32](length=wpx * hpx, fill=0)
        var surface = Surface(Int(self.canvases[k].pixels.unsafe_ptr()), wpx, hpx, self.density)
        var d = self.rt.draw(node, surface)
        if self.canvases[k].bitmap == 0 or wpx != self.canvases[k].wpx or hpx != self.canvases[k].hpx:
            self.jni.forget(self.canvases[k].bitmap)
            var config = self.jni.static_object("android/graphics/Bitmap$Config", "ARGB_8888", "Landroid/graphics/Bitmap$Config;")
            var bm = self.jni.static_call("android/graphics/Bitmap", "createBitmap", "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;", [wpx, hpx, config])
            # (Views only draw premultiplied bitmaps: translucent canvas pixels show as if
            # premultiplied. Opaque pictures, like the lens, are exact.)
            self.canvases[k].bitmap = self.jni.keep(bm)
            _ = self.jni.call(view, "android/widget/ImageView", "setImageBitmap", "(Landroid/graphics/Bitmap;)V", [bm])
            self.jni.drop(bm)
            self.jni.drop(config)
        # ARGB_8888 bitmaps hold R, G, B, A bytes in memory: our pixels' layout, copied as they are.
        var buffer = self.jni.direct_buffer(Int(self.canvases[k].pixels.unsafe_ptr()), wpx * hpx * 4)
        _ = self.jni.call(self.canvases[k].bitmap, "android/graphics/Bitmap", "copyPixelsFromBuffer", "(Ljava/nio/Buffer;)V", [buffer])
        self.jni.drop(buffer)
        _ = self.jni.call(view, "android/view/View", "invalidate", "()V")
        self.canvases[k].wpx = wpx
        self.canvases[k].hpx = hpx
        self.canvases[k].drawn = version
        self.apply(d)

    def touch(mut self, node: Int, action: Int, x: Float64, y: Float64, x2: Float64, y2: Float64, pointers: Int):
        """Touches on a canvas → PAN (one finger), ZOOM (two), TAP (a press that didn't move). Points are dp."""
        var k = self.canvas_at(node)
        if k < 0:
            return
        var px = x / self.density
        var py = y / self.density
        if action == 0:  # down
            self.canvases[k].last_x = px
            self.canvases[k].last_y = py
            self.canvases[k].fresh = False
            self.canvases[k].moved = False
            self.canvases[k].spread = 0
        elif action == 5 and pointers >= 2:  # a second finger
            self.canvases[k].spread = sqrt((x2 - x) * (x2 - x) + (y2 - y) * (y2 - y))
            self.canvases[k].moved = True
        elif action == 6 or action == 3:  # a finger lifted (of several), or cancelled: measure drags afresh
            self.canvases[k].spread = 0
            self.canvases[k].fresh = True
        elif action == 2 and pointers >= 2 and self.canvases[k].spread > 0:  # pinch
            var spread = sqrt((x2 - x) * (x2 - x) + (y2 - y) * (y2 - y))
            var factor = spread / self.canvases[k].spread
            self.canvases[k].spread = spread
            var d = self.rt.gesture(node, ZOOM, (x + x2) / 2 / self.density, (y + y2) / 2 / self.density, 0, 0, factor)
            self.apply(d)
        elif action == 2 and pointers == 1:
            if self.canvases[k].fresh:
                self.canvases[k].fresh = False
            else:
                var dx = px - self.canvases[k].last_x
                var dy = py - self.canvases[k].last_y
                if abs(dx) + abs(dy) > 0:
                    if abs(dx) + abs(dy) > 3:
                        self.canvases[k].moved = True
                    var d = self.rt.gesture(node, PAN, px, py, dx, dy, 1)
                    self.apply(d)
            self.canvases[k].last_x = px
            self.canvases[k].last_y = py
        elif action == 1 and not self.canvases[k].fresh:  # up: the rest of a drag, or a tap if it never moved
            var dx = px - self.canvases[k].last_x
            var dy = py - self.canvases[k].last_y
            if not self.canvases[k].moved and abs(dx) + abs(dy) <= 3:
                var d = self.rt.gesture(node, TAP, px, py, 0, 0, 1)
                self.apply(d)
            elif abs(dx) + abs(dy) > 0:
                var d = self.rt.gesture(node, PAN, px, py, dx, dy, 1)
                self.apply(d)


def host_at[A: App](addr: Int) -> Pointer[AndroidHost[A], MutUntrackedOrigin]:
    return Pointer[AndroidHost[A], MutUntrackedOrigin](unsafe_from_address=addr)


# ---------- called from MojoActivity (through hosts/android_main.mojo's exports) ----------

def android_create[A: App](env: Int, activity: Int) -> Int:
    var host = alloc(Layout[AndroidHost[A]].single()).unsafe_leak()  # lives as long as the activity
    host.unsafe_write(AndroidHost[A](env, activity))
    var title = host[].rt.app.title()
    var t = host[].jni.string(title)
    _ = host[].jni.call(activity, "android/app/Activity", "setTitle", CHARS, [t])
    host[].jni.drop(t)
    host[].show()
    log(title + ": started, " + String(len(host[].rt.shown.nodes)) + " nodes")
    return Int(host)


def android_event[A: App](env: Int, addr: Int, view: Int, kind: Int, text: Int, number: Int):
    """kind: 0 tap, 1 on/off, 2 choice, 3 slider, 4 row tap, 5 Return, 6 typing (MojoActivity.java)."""
    if addr == 0:
        return
    var host = host_at[A](addr)
    host[].jni.env = env
    var t = host[].jni.text(text)
    host[].send(view - 1, kind == 5, t, number)


def android_touch[A: App](env: Int, addr: Int, view: Int, action: Int, x: Float64, y: Float64, x2: Float64, y2: Float64, pointers: Int):
    if addr == 0:
        return
    var host = host_at[A](addr)
    host[].jni.env = env
    host[].touch(view - 1, action, x, y, x2, y2, pointers)


def android_frame[A: App](env: Int, addr: Int, nanos: Int):
    if addr == 0:
        return
    var host = host_at[A](addr)
    host[].jni.env = env
    host[].frame(nanos)


def android_row[A: App](env: Int, addr: Int, view: Int, index: Int) -> Int:
    if addr == 0:
        return 0
    var host = host_at[A](addr)
    host[].jni.env = env
    var node = view - 1
    var text = String("")
    if 0 <= node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].kind == LAZYLIST:
        text = host[].rt.app.row(host[].rt.shown.nodes[node].msg2, index)
    return host[].jni.string(text)


def android_destroy[A: App](env: Int, addr: Int):
    """The activity is gone: release its views and the app."""
    if addr == 0:
        return
    var host = host_at[A](addr)
    host[].jni.env = env
    for w in host[].widgets:
        host[].jni.forget(w)
    for ref c in host[].canvases:
        host[].jni.forget(c.view)
        host[].jni.forget(c.bitmap)
    host[].jni.forget(host[].activity)
    for c in host[].jni.classes:
        host[].jni.forget(c)
    host.unsafe_deinit_pointee()
    host.unsafe_free()
