# Mac host: draws a mojoui View with real AppKit controls.
#
# Events: every control's tag packs the host's address and the node index
# ((host << 16) | node), and its target is one MojoTarget object whose methods
# (tap:, submit:, toggle:, select:, slide:, controlTextDidChange:) are Mojo
# functions. AppKit doesn't send actions when we set values ourselves, so there's
# no echo to guard against (unlike GTK).

from std.ffi import c_int, external_call
from std.memory import Pointer
from std.memory.alloc import alloc, Layout

from mojoui.browser import open_url as browser_open_url
from mojoui.view import FIELD_SECRET, IME_COMMIT, IME_PREEDIT, PASTE, HOVER
from mojoui.shared import put_shared, get_shared

comptime SLOT_MAC_IME = 238  # (D-7979) mojoui.shared slot: 1 when the canvas class is an NSTextInputClient (bridge/mac_ime.m)
from mojoui.view import (
    TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE,
    SEGMENTED, RADIO, TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, BOARD, OVERLAY,
    MENUBAR, MENU, ITEM, DIALOG, TOAST, POPOVER, CLIPBOARD, TABLE, ROUTE, DRAG, DROP, EMBED, WEBCOMP, PARAGRAPH, PAN, ZOOM, TAP, PRESS, RELEASE, DOUBLE, SECONDARY, KEY, WHEEL,
    START, CENTER, END, STRETCH, BETWEEN, Node, NO_MSG,
    TITLE, HEADLINE, CAPTION, PROMINENT, DESTRUCTIVE, SUBTLE, ICON_ONLY, ICON_ON, TOOL, TOOL_ON, TOOL_INLINE, TOOL_INLINE_ON, TOKEN, TOKEN_LIT,
    TONE_WARN, TONE_GOOD, TONE_STRONG, TONE_ACCENT, CARD, CARD_WARN, CARD_GOOD,
)
from mojoui.menus import CHECKED, DISABLED, DANGER
from mojoui.theme import BUTTON_ICON, Palette, Theme, mix
from mojoui.theme import Look
from mojoui.look import text_only
from mojoui.linebreak import css_breaks, label_words, WJ
from mojoui.paragraph import Run, runs_of, link_href
from mojoui.embed import is_web_url
from mojoui.icons_data import lucide_svg
from mojoui.a11y import explicit_name
from mojoui.diff import Diff, SET_TEXT, SET_VALUE, SET_IMAGE, SET_PLACE, SET_SIZE
from mojoui.png import encode_png
from mojoui.app import App, Event, Runtime, budget_from_env
from mojoui.clock import now_ns
from std.math import sin
from mojoui.canvas import Surface, MAC_GPU
from mojoui.gpu2d import fill_batches, execute_cpu
from mojoui.gpu2d_metal import MetalCanvas2D, metal_device_name, read_iosurface
from mojoui.gpu2d_backend import set_backend_name
from mojoui.hosts.apple_canvas import CGPoint, CGRect, cfunc, cg_image, io_surface, AppleCanvas, MISSES
from mojoui.hosts.mac_report import MacReport, MAX_SHOTS, pts
from mojoui.hosts.appkit_webview import (
    MacWebViews, mac_at, start as webviews_start, new_view as webview_new, send as webview_send, drop as webview_drop,
    show_instead as webview_instead, report_lines as webview_report, probe as webview_probe, kill as webview_kill,
    type_text as webview_type, click as webview_click, step_busy as webview_busy, pages_ready as webviews_ready,
    shoot as webview_shoot, arm_inbox as webview_arm,
)
from mojoui.hosts.gtk_webview import Inbound, IN_EVENT, IN_REPLY, theme_message
from mojoui.webcomponent import is_widget_tag
from mojoui.json import json_string
from mojoui.macactivity import InputActivity
from mojoui.hosts.objc import (
    cls, sel, msg, new, ns_string, ns_data, ns_array, ns_number, ns_date, date_text, sf_symbol, from_ns, constrain, prefer,
    new_class, add_method, add_protocol, register_class, pool_push, fn_address, RTLD_DEFAULT,
)

comptime NODE_BITS = 16
comptime MASK_SHIFT = 1 << 17  # NSEventModifierFlags
comptime MASK_OPTION = 1 << 19
comptime MASK_COMMAND = 1 << 20


def tag_for(host_addr: Int, node: Int) -> Int:
    return (host_addr << NODE_BITS) | node


def ns_color(c: UInt32) -> Int:
    """An NSColor from a palette colour (R in the low byte)."""
    return msg(cls("NSColor"), "colorWithSRGBRed:green:blue:alpha:", Float64(Int(c & 255)) / 255.0, Float64(Int((c >> 8) & 255)) / 255.0,
               Float64(Int((c >> 16) & 255)) / 255.0, Float64(1))


def ns_rgba(c: UInt32) -> Int:
    """An NSColor with the colour's own alpha (a look's glass: white at 62 %)."""
    return msg(cls("NSColor"), "colorWithSRGBRed:green:blue:alpha:", Float64(Int(c & 255)) / 255.0, Float64(Int((c >> 8) & 255)) / 255.0,
               Float64(Int((c >> 16) & 255)) / 255.0, Float64(Int((c >> 24) & 255)) / 255.0)


# What AppKit leaves between a button's image and its title on its own (read from run 40423006656's pictures: about 2 pt
# where the web's role gap is 7), so a role's gap is opened by the difference (D-561)
comptime APPKIT_IMAGE_GAP = 2.0
comptime ICON_GAP_MARK = "\u200a"  # a hair space: the room before a role button's words, kerned to its gap


comptime QUIET_KEY = "mojoQuietLabel"  # (an associated object's key, a selector's stable address: set while a label's
# words change without changing its size, MojoLabel then skips the intrinsic-size invalidation, D-7582)


def quiet_label(w: Int) -> Bool:
    """Label w can take words without invalidating its size: it's a MojoLabel (a plain NSTextField becomes one here:
    the subclass adds no storage, only the three gated methods). False for any other class (its own setter is used)."""
    var c = cfunc("object_getClass", w)
    if c == cls("MojoLabel"):
        return True
    if c != cls("NSTextField") or cls("MojoLabel") == 0:
        return False
    _ = cfunc("object_setClass", w, cls("MojoLabel"))
    return True


def on_label_invalidate(view: Int, cmd: Int) abi("C"):
    """MojoLabel's invalidateIntrinsicContentSize: NSTextField's own, unless its words are changing in place."""
    if cfunc("objc_getAssociatedObject", view, sel(QUIET_KEY)) != 0:
        return
    var parent = List[Int](length=2, fill=0)  # struct objc_super { receiver, super_class }
    parent[0] = view
    parent[1] = cls("NSTextField")
    cfunc[NoneType]("objc_msgSendSuper", Int(parent.unsafe_ptr()), cmd)
    _ = len(parent)


def on_label_invalidate_cell(view: Int, cmd: Int, cell: Int) abi("C"):
    """MojoLabel's invalidateIntrinsicContentSizeForCell: (NSControl calls it when its cell's value changes): the
    same rule."""
    if cfunc("objc_getAssociatedObject", view, sel(QUIET_KEY)) != 0:
        return
    var parent = List[Int](length=2, fill=0)
    parent[0] = view
    parent[1] = cls("NSTextField")
    cfunc[NoneType]("objc_msgSendSuper", Int(parent.unsafe_ptr()), cmd, cell)
    _ = len(parent)


def on_label_needs_layout(view: Int, cmd: Int, flag: Int8) abi("C"):
    """MojoLabel's setNeedsLayout: (NSTextField's setter asks for its own layout too; with its size unchanged that
    layout changes nothing): the same rule."""
    if flag != 0 and cfunc("objc_getAssociatedObject", view, sel(QUIET_KEY)) != 0:
        return
    var parent = List[Int](length=2, fill=0)
    parent[0] = view
    parent[1] = cls("NSTextField")
    cfunc[NoneType]("objc_msgSendSuper", Int(parent.unsafe_ptr()), cmd, flag)
    _ = len(parent)


def same_room(w: Int, had: Int, words: Int) -> Bool:
    """Label w's new attributed words need exactly the room its old ones had (D-7582): the same one-line size in whole
    points, and, for a label that wraps, both fit its frame's width on one line (so neither wraps)."""
    var a = msg[CGPoint](had, "size")  # (an NSSize: width, height)
    var b = msg[CGPoint](words, "size")
    if up(a.x) != up(b.x) or up(a.y) != up(b.y):
        return False
    var cell = msg(w, "cell")
    if cell != 0 and (msg(cell, "wraps") & 0xFF) != 0:
        var room = msg[CGRect](w, "frame").width - 4  # (the cell's own inset, 2 pt a side)
        return b.x <= room and a.x <= room
    return True


def up(v: Float64) -> Int:
    """v rounded up to a whole point."""
    var i = Int(v)
    return i + 1 if Float64(i) < v else i


def cut_with_ellipsis(w: Int):
    """Label w on one line, cut at its end with "…" where it doesn't fit (the web's text-overflow: ellipsis). The cell's
    mode alone isn't enough: a label whose words carry a paragraph style (the look's line height) breaks by that style's
    mode, word wrapping, and was cut bare at a break ("sentence-transformers/all-"), so the style's mode is set too and
    kept by later text patches, which reuse the words' attributes."""
    _ = msg(w, "setLineBreakMode:", 4)  # NSLineBreakByTruncatingTail
    _ = msg(w, "setMaximumNumberOfLines:", 1)
    var said = msg(w, "attributedStringValue")
    if said == 0 or msg(said, "length") == 0:
        return
    var style = msg(said, "attribute:atIndex:effectiveRange:", ns_string("NSParagraphStyle"), 0, 0)
    if style == 0:
        return  # (no style of its own: the cell's mode holds)
    var cut = msg(style, "mutableCopy")
    _ = msg(cut, "setLineBreakMode:", 4)
    var words = msg(said, "mutableCopy")
    _ = msg(words, "addAttribute:value:range:", ns_string("NSParagraphStyle"), cut, 0, msg(words, "length"))  # (NSRange in two registers)
    _ = msg(w, "setAttributedStringValue:", words)


def svg_icon(name: String, size: Float64) -> Int:
    """A Lucide icon, the same drawing GTK and the web show, as a template NSImage (tinted like a symbol; NSImage reads
    SVG itself on macOS 14+); 0 if the name isn't one of mojoui's icons."""
    var svg = lucide_svg(name)
    if svg == "":
        return 0
    var bytes = List[UInt8](svg.replace("currentColor", "#000000").as_bytes())
    var image = msg(msg(cls("NSImage"), "alloc"), "initWithData:", ns_data(bytes))
    if image == 0:
        return 0
    _ = msg(image, "setSize:", size, size)
    _ = msg(image, "setTemplate:", 1)
    return image


def look_font(family: String, weight: Int, size: Float64, tabular: Bool = False) -> Int:
    """A look's font by family and weight: the faces the app registered (Inter Regular, Medium, SemiBold; JetBrains Mono
    Regular, Bold), the nearest one for a weight between."""
    if family == "JetBrains Mono":
        return skin_font("JetBrainsMono-Bold" if weight >= 600 else "JetBrainsMono-Regular", size)
    if family == "Geist" or family == "Geist Mono":  # (variable faces: the weight itself on the wght axis, as CSS asks)
        return variable_font("GeistMono-Regular" if family == "Geist Mono" else "Geist-Regular", weight if weight > 0 else 400, size, tabular)
    return skin_font("Inter-SemiBold" if weight >= 600 else ("Inter-Medium" if weight >= 500 else "Inter-Regular"), size, tabular)


def variable_font(name: String, weight: Int, size: Float64, tabular: Bool = False) -> Int:
    """A registered variable font (Geist) at `weight` on its wght axis; the system font if it isn't there."""
    var f = skin_font(name, size, tabular)
    if weight == 400 or msg(f, "fontName") == 0:
        return f
    var axes = new("NSMutableDictionary")
    _ = msg(axes, "setObject:forKey:", ns_number(weight), ns_number(0x77676874))  # 'wght'
    var attrs = new("NSMutableDictionary")
    _ = msg(attrs, "setObject:forKey:", axes, ns_string("NSCTFontVariationAttribute"))
    var desc = msg(msg(f, "fontDescriptor"), "fontDescriptorByAddingAttributes:", attrs)
    var v = msg(cls("NSFont"), "fontWithDescriptor:size:", desc, size)
    return v if v != 0 else f


def skin_font(name: String, size: Float64, tabular: Bool = False) -> Int:
    """The app's own font if it was registered (Inter, JetBrains Mono), else the system font; with tabular figures
    when the look asks (TypeScale.tabular: the web's font-feature-settings "tnum")."""
    var f = msg(cls("NSFont"), "fontWithName:size:", ns_string(name), size)
    if f == 0:
        f = msg(cls("NSFont"), "systemFontOfSize:", size)
    elif tabular:  # kNumberSpacingType (6) · kMonospacedNumbersSelector (0)
        var feature = new("NSMutableDictionary")
        _ = msg(feature, "setObject:forKey:", ns_number(6), ns_string("CTFeatureTypeIdentifier"))
        _ = msg(feature, "setObject:forKey:", ns_number(0), ns_string("CTFeatureSelectorIdentifier"))
        var features = new("NSMutableArray")
        _ = msg(features, "addObject:", feature)
        var attrs = new("NSMutableDictionary")
        _ = msg(attrs, "setObject:forKey:", features, ns_string("NSCTFontFeatureSettingsAttribute"))
        var desc = msg(msg(f, "fontDescriptor"), "fontDescriptorByAddingAttributes:", attrs)
        var tab = msg(cls("NSFont"), "fontWithDescriptor:size:", desc, size)
        if tab != 0:
            f = tab
    return f


def key_equivalent(shortcut: String) -> Tuple[String, Int]:
    """"Ctrl+Shift+S" → ("s", ⌘⇧): Ctrl means ⌘ on a Mac (D-159). Arrows become their NSMenuItem characters."""
    var name = shortcut
    var mask = 0
    while True:
        if name.startswith("Ctrl+"):
            mask |= MASK_COMMAND
            var cut = String(name[byte=5:])
            name = cut
        elif name.startswith("Shift+"):
            mask |= MASK_SHIFT
            var cut = String(name[byte=6:])
            name = cut
        elif name.startswith("Alt+"):
            mask |= MASK_OPTION
            var cut = String(name[byte=4:])
            name = cut
        else:
            break
    if name == "↑":
        return (String(chr(0xF700)), mask)  # NSUpArrowFunctionKey
    if name == "↓":
        return (String(chr(0xF701)), mask)
    if name == "←":
        return (String(chr(0xF702)), mask)
    if name == "→":
        return (String(chr(0xF703)), mask)
    if name.startswith("F") and name.byte_length() <= 3 and name != "F":
        try:
            return (String(chr(0xF704 + Int(String(name[byte=1:])) - 1)), mask)  # NSF1FunctionKey…
        except:
            return (String(""), mask)
    if name.byte_length() == 1:
        return (name.lower(), mask)
    return (String(""), mask)


def key_name_of(event: Int) -> String:
    """An NSEvent key press → the web's key names (what the GTK and web hosts send)."""
    var code = msg(event, "keyCode") & 0xFFFF
    if code == 123: return "ArrowLeft"
    if code == 124: return "ArrowRight"
    if code == 125: return "ArrowDown"
    if code == 126: return "ArrowUp"
    if code == 36 or code == 76: return "Enter"
    if code == 53: return "Escape"
    if code == 48: return "Tab"
    if code == 51: return "Backspace"
    if code == 117: return "Delete"
    if code == 115: return "Home"
    if code == 119: return "End"
    if code == 116: return "PageUp"
    if code == 121: return "PageDown"
    if code == 122: return "F1"
    if code == 120: return "F2"
    if code == 99: return "F3"
    if code == 118: return "F4"
    if code == 96: return "F5"
    return from_ns(msg(event, "charactersIgnoringModifiers"))


struct AppKitHost[A: App](Movable):
    var rt: Runtime[Self.A]
    var window: Int
    var target: Int  # MojoTarget object that receives every event
    var widgets: List[Int]
    var shells: List[Int]  # per node: the box a control is drawn in when it isn't the control (a field's rounded frame); 0: none
    var objects: List[Int]  # per node: a Board object's box when it wears its content's role (the table's card); 0: none
    var boxed: Int  # the Board child being built inside its role's box (the box wears the role; the child doesn't, as on GTK)
    var dashes: List[Tuple[Int, Int, Int, Int]]  # (view, its dashed outline's shape layer, corner radius, width): paths follow the layout (dash_paths)
    var rounds: List[Tuple[Int, Int]]  # (view, its look's corner radius): at most half its laid-out size (dash_paths; a layer draws a star past that)
    var tick_boxes: List[Int]  # drawn tick boxes (D-510): the button, its look role, its width and height constraints
    var tick_k: List[Int]
    var tick_cw: List[Int]
    var tick_ch: List[Int]
    var tcells: List[Tuple[Int, Int, Int, Int, Int]]  # a Table's cells: (table, cell, its width constraint (0: the last column's), column, child node): fit_tables
    var focus: Int  # text field to keep focused across the next rebuild (-1: none)
    var canvases: List[AppleCanvas]
    var link: Int  # an NSTimer at 60 Hz: one tick per frame, for every canvas (0 = stopped)
    var activity: InputActivity
    var fx_due: Int  # when the runtime's effects (HTTP replies, timers) are next polled (µs; -1: nothing asked for)
    var resize_pending: Bool  # a new window size waits for the next run-loop turn (never rebuilt inside AppKit's layout)
    var pan_mode: Int  # a tiled Board's card being dragged: 1 by its header (moves), 2 by its corner (resizes), 0 none
    var pan_frame: CGRect  # its frame when the drag began
    var asked_w: Int  # a size the host itself set (a test's resize:, a window too big for its screen): asked once more after
    var asked_h: Int  # the app lays out to what it got, when the old screen's minimum stopped it short (0: none)
    var ticks: Int  # ticks so far (the Mac report logs the first)
    var last_frame: Float64  # the link's last timestamp (seconds)
    var theme_key: String  # the app's theme (Theme.key); its palette's colours and Inter when it paints native controls (a skin, D-149, D-260)
    var pal: Palette
    var skinned: Bool
    var look: Look  # the theme's type, control sizes and surfaces (mojoui/look.mojo): what GTK and the web write their rules from
    var popover: Int  # the NSPopover showing (a Popover node, or a context menu's items), and its node
    var popover_node: Int
    var sheet: Int  # the sheet window showing (a Dialog node), and its node
    var sheet_node: Int
    var toast: Int  # the toast view showing, if any
    var clip_version: Int  # the Clipboard view's version last copied (unverified on hardware)
    var embed_version: Int  # the WebFrame's version last opened in the browser (unverified on hardware)
    var pinned: List[Int]  # Scroll nodes pinned to their end (follow_ends)
    var toast_text: String
    var toast_claimed: Bool
    var has_menubar: Bool  # the screen put its own menus in the system menu bar (D-150)
    var ime_on: Bool  # (D-7979) bridge/mac_ime.m is linked in: the canvas is an NSTextInputClient
    var ime_text: String  # the composition (marked text) in progress, on canvas node ime_node
    var ime_node: Int
    var ime_key: String  # the keyDown: being offered to the input context (a doCommandBySelector: sends it as a KEY)
    var ime_mods: Int
    var report: MacReport  # Debug → Record: pictures and view dumps on the Desktop (mojoui/hosts/mac_report.mojo)
    var size_w: List[Int]  # per node: its fixed-width and fixed-height constraints (0: none), so a new size is a patch
    var size_h: List[Int]
    var sized: List[Tuple[Int, Int, Int, Int]]  # per node: the w, h, min_w, max_w it was built with
    var wraps: List[Int]  # a column's labels: they wrap to the width they're given (fit_wraps), as GTK's labels do
    var wrap_keeps: List[Int]  # fit_wraps' "at least its room" constraints on labels that wrap (D-540)
    var wrap_buttons: List[Tuple[Int, Int, Float64, Float64, Float64]]  # role buttons whose words wrap when squeezed: (button, its height constraint, its line, its padding down, across), D-537
    var parents: List[Int]  # per node: its stack's node, or -1 (worked out once per build)
    var rebuilds: Int  # whole-window rebuilds since the last report snapshot (its log line says how many)
    var resized_in_place: Int
    var steps: List[String]  # MOJOUI_TEST: steps run one by one, a report recording each (the GitHub Mac runner, 2026-10-23)
    var step_at: Int
    var webviews: Int  # the WebComponents' WKWebViews (mojoui/hosts/appkit_webview.mojo), on the heap: its address
    var web_focus: Int  # a WKWebView that had the keyboard when a rebuild moved it (it gets it back), or 0
    var shots_taken: Bool  # the web views' pictures for the next snapshot have arrived
    var step_wait_from: Int  # (test steps) when the next step started waiting for the pages (ns; 0: not waiting)
    var wait_title: String  # (test steps) waitfor:Title=N: the button being waited for ("" when none)
    var wait_until: Int  # (test steps) its deadline (now_ns)
    var probe_pending: Bool  # (test steps) a webjs: step's answer is still to be written in the log
    var dark_told: Int  # the system's light (0) or dark (1) mode as the app last heard it (App.appearance); -1: not yet
    # goal 75 M3: Canvas(…).gpu() canvases whose app draws a Scene are drawn by mojoui.gpu2d on Metal (gpu2d_metal)
    var g2d: Int  # the MetalCanvas2D on the heap (made at the first such draw), 0: not yet
    var g2d_why: String  # "": Metal is here (probed at start); else why those canvases stay on the CPU path
    var g2d_force: Bool  # MOJOUI_GPU2D=1: every canvas whose app draws a Scene takes the GPU path, .gpu() or not (testing)
    var g2d_frames: Int  # pictures Metal drew so far (framebench's renderer=)
    var g2d_defer: Bool  # (set by tick and framebench around their draws) a GPU frame is committed, not waited for: see finish_gpu2d
    var g2d_defer_on: Bool  # MOJOUI_GPU2D_DEFER=0: every GPU frame is waited for at once, as before D-7555 (to compare)
    var g2d_keep: Int  # GPU frames left in flight at the end of a frame (MOJOUI_GPU2D_INFLIGHT − 1)
    var label_inplace: Bool  # a label's new words of the same fitted size don't invalidate its size: no layout (D-7582; MOJOUI_LABEL_INPLACE=0: off)
    var labels_in_place: Int  # label changes made in place (the report)
    var labels_relaid: Int  # label changes that changed the label's size (laid out again)
    # committed GPU frames not yet shown, oldest first: canvas, ring slot, IOSurface, and what the CPU fallback needs
    var g2d_pk: List[Int]
    var g2d_pat: List[Int]
    var g2d_ps: List[Int]
    var g2d_pw: List[Int]
    var g2d_ph: List[Int]
    var g2d_pscale: List[Float64]
    var g2d_pb: List[CGRect]
    var g2d_pt: List[Int]  # (and when each was committed, ns)
    var g2d_shown_ms: List[Float64]  # commit → handed to Core Animation, per frame shown that way (framebench reads and clears it)
    var first_draw_age_ms: Float64  # (D-7988) the process's age when its first canvas picture was drawn (firstscreen:)
    var g2d_done: List[Float64]  # the GPU time of each completed frame, in commit order (framebench reads and clears it)
    var g2d_notify: Bool  # the renderer calls on_gpu2d_done when a committed frame completes
    var g2d_failed: Int  # committed GPU frames the GPU didn't complete (counted as GPU frames when committed: framebench moves them to cpu_frames)
    var g2d_parts: List[Float64]  # the last GPU frame's parts (ms): the app's Scene, the batches, Metal (encode + GPU), the GPU alone;
    # then layers rebuilt, kept, grown, polygon groups planned and drawn (on the canvas)

    def __init__(out self):
        Self.A.init_shared()
        var g2d_why = gpu2d_probe()  # (before the app is made: it may ask which backend it has, mojoui.gpu2d_backend)
        self.rt = Runtime(Self.A())
        self.rt.watch(budget_from_env())  # MOJOUI_BUDGET_MS: the slow-frame watchdog (SLOW: lines on stdout)
        self.window = 0
        self.target = 0
        self.widgets = List[Int]()
        self.shells = List[Int]()
        self.objects = List[Int]()
        self.boxed = -1
        self.dashes = List[Tuple[Int, Int, Int, Int]]()
        self.rounds = List[Tuple[Int, Int]]()
        self.tcells = List[Tuple[Int, Int, Int, Int, Int]]()
        self.tick_boxes = List[Int]()
        self.tick_k = List[Int]()
        self.tick_cw = List[Int]()
        self.tick_ch = List[Int]()
        self.focus = -1
        self.canvases = List[AppleCanvas]()
        self.link = 0
        self.activity = InputActivity()
        self.fx_due = -1
        self.resize_pending = False
        self.asked_w = 0
        self.asked_h = 0
        self.pan_mode = 0
        self.pan_frame = CGRect(0, 0, 0, 0)
        self.last_frame = 0
        self.ticks = 0
        var theme = self.rt.app.theme()
        self.theme_key = theme.key()
        self.pal = theme.palette.copy()
        self.skinned = theme.paint_native
        self.look = theme.look.copy()
        self.popover = 0
        self.popover_node = -1
        self.sheet = 0
        self.sheet_node = -1
        self.toast = 0
        self.clip_version = 0
        self.embed_version = 0
        self.pinned = List[Int]()
        self.toast_text = ""
        self.toast_claimed = False
        self.has_menubar = False
        self.report = MacReport()
        self.ime_on = False
        self.ime_text = ""
        self.ime_node = -1
        self.ime_key = ""
        self.ime_mods = 0
        self.steps = List[String]()
        self.step_at = 0
        var wv = alloc(Layout[MacWebViews].single()).unsafe_leak()  # (lives as long as the window: WebKit's callbacks hold its address)
        wv.unsafe_write(MacWebViews())
        self.webviews = Int(wv)
        self.web_focus = 0
        self.shots_taken = False
        self.step_wait_from = 0
        self.wait_title = ""
        self.wait_until = 0
        self.probe_pending = False
        self.dark_told = -1
        self.g2d = 0
        self.g2d_why = g2d_why
        self.g2d_force = env("MOJOUI_GPU2D") == "1"
        self.g2d_frames = 0
        self.g2d_defer = False
        self.g2d_defer_on = env("MOJOUI_GPU2D_DEFER") != "0"
        var inflight = env("MOJOUI_GPU2D_INFLIGHT")
        self.g2d_keep = 1 if inflight == "" else max(to_int(inflight) - 1, 0)
        self.label_inplace = env("MOJOUI_LABEL_INPLACE") != "0"
        self.labels_in_place = 0
        self.labels_relaid = 0
        self.g2d_pk = List[Int]()
        self.g2d_pat = List[Int]()
        self.g2d_ps = List[Int]()
        self.g2d_pw = List[Int]()
        self.g2d_ph = List[Int]()
        self.g2d_pscale = List[Float64]()
        self.g2d_pb = List[CGRect]()
        self.g2d_pt = List[Int]()
        self.g2d_shown_ms = List[Float64]()
        self.g2d_done = List[Float64]()
        self.first_draw_age_ms = -1
        self.g2d_notify = False
        self.g2d_failed = 0
        self.g2d_parts = List[Float64](length=13, fill=0)
        self.size_w = List[Int]()
        self.size_h = List[Int]()
        self.wraps = List[Int]()
        self.wrap_buttons = List[Tuple[Int, Int, Float64, Float64, Float64]]()
        self.wrap_keeps = List[Int]()
        self.parents = List[Int]()
        self.rebuilds = 0
        self.resized_in_place = 0
        self.sized = List[Tuple[Int, Int, Int, Int]]()

    def ink(self) -> Int:
        return ns_color(self.pal.ink) if self.skinned else msg(cls("NSColor"), "labelColor")

    def accent(self) -> Int:
        return ns_color(self.pal.accent) if self.skinned else msg(cls("NSColor"), "controlAccentColor")

    def ns_menu(self, title: String, children: List[Int], self_addr: Int) -> Int:
        """An NSMenu from ITEM nodes: items with ⌘ shortcuts, checkmarks, disabled and red (danger) ones, separators,
        section labels and submenus. Each item's tag is its node, so one action serves them all."""
        var menu = msg(msg(msg(cls("NSMenu"), "alloc"), "initWithTitle:", ns_string(title)), "autorelease")
        _ = msg(menu, "setAutoenablesItems:", 0)
        for c in children:
            ref n = self.rt.shown.nodes[c]
            if n.kind != ITEM:
                continue
            if n.style == 1:
                _ = msg(menu, "addItem:", msg(cls("NSMenuItem"), "separatorItem"))
                continue
            if n.style == 2:
                var head = msg(menu, "addItemWithTitle:action:keyEquivalent:", ns_string(n.text), 0, ns_string(""))
                _ = msg(head, "setEnabled:", 0)
                continue
            var key = key_equivalent(n.options[0]) if len(n.options) > 0 else (String(""), 0)
            var item = msg(menu, "addItemWithTitle:action:keyEquivalent:", ns_string(n.text), sel("menuItem:") if len(n.children) == 0 else 0, ns_string(key[0]))
            if key[1] != 0:
                _ = msg(item, "setKeyEquivalentModifierMask:", key[1])
            _ = msg(item, "setTarget:", self.target)
            _ = msg(item, "setTag:", tag_for(self_addr, c))
            if n.value & CHECKED != 0:
                _ = msg(item, "setState:", 1)
            if n.value & DISABLED != 0 or (len(n.children) == 0 and n.msg == 0):
                _ = msg(item, "setEnabled:", 0)
            if n.hint != "":
                var image = msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string(sf_symbol(n.hint)), 0)
                if image != 0:
                    _ = msg(item, "setImage:", image)
            if n.value & DANGER != 0:
                var red = msg(cls("NSMutableDictionary"), "dictionary")
                _ = msg(red, "setObject:forKey:", msg(cls("NSColor"), "systemRedColor"), ns_string("NSColor"))
                var attributed = msg(msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(n.text), red), "autorelease")
                _ = msg(item, "setAttributedTitle:", attributed)
            if len(n.children) > 0:
                _ = msg(item, "setSubmenu:", self.ns_menu(n.text, n.children, self_addr))
        return menu

    def install_menubar(self, bar_node: Int, self_addr: Int):
        """The app's MenuBar becomes the system menu bar: the app menu (About, Quit), then its menus (D-150)."""
        var app = msg(cls("NSApplication"), "sharedApplication")
        var bar = new("NSMenu")
        var app_item = new("NSMenuItem")
        _ = msg(bar, "addItem:", app_item)
        var app_menu = new("NSMenu")
        var title = self.rt.app.title()
        _ = msg(app_menu, "addItemWithTitle:action:keyEquivalent:", ns_string("About " + title), sel("orderFrontStandardAboutPanel:"), ns_string(""))
        _ = msg(app_menu, "addItem:", msg(cls("NSMenuItem"), "separatorItem"))
        _ = msg(app_menu, "addItemWithTitle:action:keyEquivalent:", ns_string("Hide " + title), sel("hide:"), ns_string("h"))
        _ = msg(app_menu, "addItemWithTitle:action:keyEquivalent:", ns_string("Quit " + title), sel("terminate:"), ns_string("q"))
        _ = msg(app_item, "setSubmenu:", app_menu)
        var has_edit = False
        for c in self.rt.shown.nodes[bar_node].children:
            ref m = self.rt.shown.nodes[c]
            if m.kind != MENU:
                continue
            has_edit = has_edit or m.text == "Edit"
            var item = new("NSMenuItem")
            _ = msg(bar, "addItem:", item)
            _ = msg(item, "setSubmenu:", self.ns_menu(m.text, m.children, self_addr))
        if not has_edit:  # text fields keep their Cut/Copy/Paste shortcuts
            var edit_item = new("NSMenuItem")
            _ = msg(bar, "addItem:", edit_item)
            var edit = msg(msg(cls("NSMenu"), "alloc"), "initWithTitle:", ns_string("Edit"))
            _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Cut"), sel("cut:"), ns_string("x"))
            _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Copy"), sel("copy:"), ns_string("c"))
            _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Paste"), sel("paste:"), ns_string("v"))
            _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Select All"), sel("selectAll:"), ns_string("a"))
            _ = msg(edit_item, "setSubmenu:", edit)
        _ = msg(app, "setMainMenu:", bar)

    def anchor_view(self, name: String) -> Int:
        for k in range(len(self.rt.shown.nodes)):
            if self.rt.shown.nodes[k].name == name and k < len(self.widgets) and self.widgets[k] != 0:
                return self.widgets[k]
        return msg(self.window, "contentView")

    def show_popover(mut self, i: Int, content: Int, self_addr: Int):
        """An NSPopover with `content` for node i, below its anchor (a Popover) or at a point in it (a context menu);
        shown on the next run-loop turn; a click elsewhere closes it, which is on_close."""
        var vc = new("NSViewController")
        var holder = new("NSStackView")
        _ = msg(holder, "setOrientation:", 1)
        _ = msg(holder, "setAlignment:", 5)  # leading
        _ = msg(holder, "setEdgeInsets:", Float64(12), Float64(14), Float64(12), Float64(14))  # (the web's .popover: padding 12px 14px)
        _ = msg(holder, "addArrangedSubview:", content)
        _ = msg(vc, "setView:", holder)
        # at least 260 wide, as the web's; its text wraps at the content's own max width (or 260 less the padding).
        # Before, fit_wraps measured these labels before the popover was laid out and gave them almost no width: the
        # sentence's choices read squeezed (the owner's Mac, 2026-10-23)
        var wrap_at = Float64(232)
        ref n = self.rt.shown.nodes[i]
        if len(n.children) > 0 and self.rt.shown.nodes[n.children[0]].max_w > 0:
            wrap_at = Float64(self.rt.shown.nodes[n.children[0]].max_w)
        _ = msg(msg(msg(holder, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(260)), "setActive:", 1)
        for l in self.wraps:
            if (msg(l, "isDescendantOf:", holder) & 0xFF) != 0:
                _ = msg(l, "setPreferredMaxLayoutWidth:", wrap_at)
        var popover = new("NSPopover")
        _ = msg(popover, "setContentViewController:", vc)
        _ = msg(popover, "setBehavior:", 1)  # transient: a click outside closes it
        _ = msg(popover, "setDelegate:", self.target)  # popoverDidClose:
        _ = msg(holder, "setIdentifier:", ns_string(String(tag_for(self_addr, i))))
        self.popover = popover
        self.popover_node = i
        _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("showPopover:"), ns_number(tag_for(self_addr, i)), Float64(0))

    def show_sheet(mut self, i: Int, content: Int, self_addr: Int):
        """A Dialog as a sheet on the window: its title bar with ✕ (on_close), then its content."""
        ref node = self.rt.shown.nodes[i]
        var width = Float64(node.w if node.w > 0 else 560)
        var sheet = msg(msg(cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:",
                        Float64(0), Float64(0), width, Float64(360), 1, 2, 0)  # titled; the content sizes it
        _ = msg(sheet, "setReleasedWhenClosed:", 0)
        _ = msg(sheet, "setTitle:", ns_string(node.text))
        var column = new("NSStackView")
        _ = msg(column, "setOrientation:", 1)
        _ = msg(column, "setAlignment:", 5)
        _ = msg(column, "setSpacing:", Float64(12))
        _ = msg(column, "setEdgeInsets:", Float64(16), Float64(20), Float64(16), Float64(20))
        var head = new("NSStackView")
        _ = msg(head, "setOrientation:", 0)
        var title = msg(cls("NSTextField"), "labelWithString:", ns_string(node.text))
        _ = msg(title, "setFont:", msg(cls("NSFont"), "boldSystemFontOfSize:", Float64(15)))
        _ = msg(head, "addArrangedSubview:", title)
        _ = msg(head, "addArrangedSubview:", flexible_spacer(False))
        var close = msg(cls("NSButton"), "buttonWithImage:target:action:", msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string("xmark"), ns_string("Close")), self.target, sel("closeOverlay:"))
        _ = msg(close, "setBordered:", 0)
        _ = msg(close, "setTag:", tag_for(self_addr, i))
        _ = msg(head, "addArrangedSubview:", close)
        _ = msg(column, "addArrangedSubview:", head)
        _ = msg(column, "addArrangedSubview:", content)
        _ = msg(msg(msg(column, "widthAnchor"), "constraintEqualToConstant:", width), "setActive:", 1)
        for l in self.wraps:  # (its labels wrap at the sheet's width less its padding: fit_wraps sees the window only)
            if (msg(l, "isDescendantOf:", column) & 0xFF) != 0:
                _ = msg(l, "setPreferredMaxLayoutWidth:", width - 40)
        _ = msg(sheet, "setContentView:", column)
        if self.skinned:
            _ = msg(sheet, "setBackgroundColor:", ns_color(self.pal.card))
        self.sheet = sheet
        self.sheet_node = i
        _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("showSheet:"), ns_number(tag_for(self_addr, i)), Float64(0))

    def item_rows(mut self, children: List[Int], self_addr: Int) -> Int:
        """A context menu's items as a column of borderless buttons (an NSPopover shows them, like the other hosts)."""
        var column = new("NSStackView")
        _ = msg(column, "setOrientation:", 1)
        _ = msg(column, "setAlignment:", 5)
        _ = msg(column, "setSpacing:", Float64(2))
        for c in children:
            ref n = self.rt.shown.nodes[c]
            if n.kind != ITEM:
                continue
            if n.style == 1:
                var sep = new("NSBox")
                _ = msg(sep, "setBoxType:", 2)
                _ = msg(column, "addArrangedSubview:", sep)
                continue
            if n.style == 2:
                var head = msg(cls("NSTextField"), "labelWithString:", ns_string(n.text))
                _ = msg(head, "setFont:", msg(cls("NSFont"), "systemFontOfSize:", Float64(11)))
                _ = msg(head, "setTextColor:", msg(cls("NSColor"), "secondaryLabelColor"))
                _ = msg(column, "addArrangedSubview:", head)
                continue
            var b = msg(cls("NSButton"), "buttonWithTitle:target:action:", ns_string(n.text + ("   " + n.options[0] if len(n.options) > 0 else "")), self.target, sel("tap:"))
            _ = msg(b, "setBordered:", 0)
            _ = msg(b, "setTag:", tag_for(self_addr, c))
            if n.hint != "" or n.value & CHECKED != 0:
                var image = msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string("checkmark" if n.value & CHECKED != 0 else sf_symbol(n.hint)), 0)
                _ = msg(b, "setImage:", image)
                _ = msg(b, "setImagePosition:", 2)  # NSImageLeft (3 is NSImageRight: the icon came after the title)
            if n.value & DANGER != 0:
                _ = msg(b, "setContentTintColor:", msg(cls("NSColor"), "systemRedColor"))
            if n.value & DISABLED != 0:
                _ = msg(b, "setEnabled:", 0)
            if len(n.children) > 0:  # a submenu: a pull-down of its items
                var pull = msg(msg(cls("NSPopUpButton"), "alloc"), "initWithFrame:pullsDown:", Float64(0), Float64(0), Float64(200), Float64(28), 1)
                _ = msg(pull, "setMenu:", self.ns_menu(n.text, n.children, self_addr))
                _ = msg(msg(pull, "menu"), "insertItemWithTitle:action:keyEquivalent:atIndex:", ns_string(n.text), 0, ns_string(""), 0)
                _ = msg(pull, "setBordered:", 0)
                _ = msg(column, "addArrangedSubview:", pull)
                continue
            self.widgets[c] = b
            _ = msg(column, "addArrangedSubview:", b)
        return column

    def submit_field_shown(self) -> Bool:
        """Whether a text field handles Return itself (then no button may also claim it)."""
        for n in self.rt.shown.nodes:
            if n.kind == FIELD and n.msg2 != 0:
                return True
        return False

    def wire(self, w: Int, i: Int, self_addr: Int, action: String):
        _ = msg(w, "setTag:", tag_for(self_addr, i))
        _ = msg(w, "setTarget:", self.target)
        _ = msg(w, "setAction:", sel(action))

    def build(mut self, i: Int, self_addr: Int) -> Int:
        var node = self.rt.shown.nodes[i].copy()  # copy: building children mutates self
        var sized = node.sized_width()  # the app's layout decides this view's width
        var w: Int
        if node.kind == PARAGRAPH:  # one wrapping label: the runs as an attributed string, AppKit breaks the lines (D-470)
            w = msg(cls("NSTextField"), "wrappingLabelWithString:", ns_string(""))
            _ = msg(w, "setAttributedStringValue:", self.paragraph_string(i))
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            var role = self.look.surface(node.name) if node.name != "" else -1
            if role >= 0 and self.look.surfaces[role].max_chars > 0:  # the role's measure: that many "0"s of its font (CSS's ch)
                var most = self.measure_of(role)  # (the paragraph's own font, as CSS's ch: its first run's could be inline code, D-522)
                _ = msg(msg(msg(w, "widthAnchor"), "constraintLessThanOrEqualToConstant:", most), "setActive:", 1)
                _ = msg(w, "setPreferredMaxLayoutWidth:", most)
            # its lines wrap at the width its column gives it, as the browser's and Pango's: 490 keeps one line unless a
            # real limit squeezes it, and fit_wraps tells it that width (a wrapping label is otherwise as wide as its one
            # line: the notebook's lines ran 1039 pt wide in a 914 pt column, D-521)
            _ = msg(w, "setContentCompressionResistancePriority:forOrientation:", Float32(490), 0)
            self.wraps.append(w)
            if node.msg != 0 or len(node.options) > 0:  # a link's tap: the click's place in the words names the run (paragraphTap:)
                var r = msg(msg(cls("NSClickGestureRecognizer"), "alloc"), "initWithTarget:action:", self.target, sel("paragraphTap:"))
                _ = msg(w, "addGestureRecognizer:", r)
        elif node.kind == TEXT:
            var shown = label_words(self.rt.shown.nodes, i)  # (the browser's line breaks and ends, D-548, D-549)
            w = msg(cls("NSTextField"), "labelWithString:", ns_string(shown))
            _ = msg(w, "setAlignment:", 1)  # NSTextAlignmentCenter (1 on Apple Silicon; 2 is right)
            var size = Float64(13)
            var bold = False
            if node.style == TITLE:
                size, bold = Float64(26), True
            elif node.style == HEADLINE:
                size, bold = Float64(15), True
            elif node.style == CAPTION:
                size = Float64(11)
                _ = msg(w, "setTextColor:", msg(cls("NSColor"), "secondaryLabelColor"))
            _ = msg(w, "setFont:", msg(cls("NSFont"), "boldSystemFontOfSize:" if bold else "systemFontOfSize:", size))
            if self.skinned:
                ref ts = self.look.type
                var sized_by = ts.title if node.style == TITLE else (ts.headline if bold else (ts.caption if node.style == CAPTION else ts.body))  # (the look's type scale: GTK's label.title-1, .title-4, .caption)
                _ = msg(w, "setFont:", look_font(self.look.type.family, 600 if bold else 400, sized_by, self.look.type.tabular))
                _ = msg(w, "setTextColor:", ns_color(self.look.type.ink_of(self.pal, node.style == CAPTION)))  # (the look's inks: omxqua's ink and ink2, as its sheets, D-676)
            var tl = self.text_look(i)
            if tl >= 0:  # a surface's own type (the status bar's figures: one theme's Inter 12, another's JetBrains Mono)
                ref sf = self.look.surfaces[tl]
                var inh = self.inherited_size(i)
                if sf.font != "" or sf.font_size > 0 or sf.font_weight > 0 or inh > 0:  # (no size of its own: the one it inherits, else its style's, a caption's 12)
                    _ = msg(w, "setFont:", look_font(sf.font if sf.font != "" else self.look.type.family, sf.font_weight, sf.font_size if sf.font_size > 0 else (inh if inh > 0 else msg[Float64](msg(w, "font"), "pointSize")), self.look.type.tabular))
                if sf.ink != 0:
                    _ = msg(w, "setTextColor:", ns_rgba(sf.ink))
                if sf.tracking != 0:  # (letter spacing: the label's string with NSKern, in its own font and colour)
                    var attrs = new("NSMutableDictionary")
                    _ = msg(attrs, "setObject:forKey:", msg(w, "font"), ns_string("NSFont"))
                    _ = msg(attrs, "setObject:forKey:", msg(w, "textColor"), ns_string("NSColor"))
                    _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", sf.tracking), ns_string("NSKern"))
                    _ = msg(w, "setAttributedStringValue:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(shown), attrs))
            elif self.skinned and self.inherited_size(i) > 0:  # (no role of its own with type: a table cell's words at the cell's size)
                _ = msg(w, "setFont:", look_font(self.look.type.family, 400, self.inherited_size(i), self.look.type.tabular))
            if node.value == TONE_WARN:
                _ = msg(w, "setTextColor:", ns_color(self.pal.warn) if self.skinned else msg(cls("NSColor"), "systemOrangeColor"))
            elif node.value == TONE_GOOD:
                _ = msg(w, "setTextColor:", ns_color(self.pal.good) if self.skinned else msg(cls("NSColor"), "systemGreenColor"))
            elif node.value == TONE_ACCENT:
                _ = msg(w, "setTextColor:", self.accent())
            elif node.value == TONE_STRONG:
                _ = msg(w, "setTextColor:", self.ink())
                _ = msg(w, "setFont:", look_font(self.look.type.family, 600, Float64(13), self.look.type.tabular) if self.skinned else msg(cls("NSFont"), "boldSystemFontOfSize:", Float64(13)))
            if self.skinned:  # the look's line height (CSS's: omxqua's body 14px/1.45), half the extra above and below (D-444)
                var font = msg(w, "font")
                var lh = Float64(0)
                if tl >= 0 and self.look.surfaces[tl].line_height > 0:
                    lh = self.look.surfaces[tl].line_height
                elif tl >= 0 and self.look.surfaces[tl].line_height < 0 and self.look.type.line > 0:
                    # the font's own line (CSS's normal: its ascender, descender and line gap), not the look's body line:
                    # a mono line at 11.5 pt was 17 high for the web's 15 (D-509)
                    lh = msg[Float64](font, "ascender") - msg[Float64](font, "descender") + msg[Float64](font, "leading")
                elif self.look.type.line > 0:  # (its style's own: a title's 1.1, not the body's 1.45, D-669)
                    lh = msg[Float64](font, "pointSize") * self.look.type.line_of(node.style == TITLE, bold and node.style != TITLE, node.style == CAPTION)
                if lh > 0:
                    var para = new("NSMutableParagraphStyle")
                    _ = msg(para, "setMinimumLineHeight:", lh)
                    _ = msg(para, "setMaximumLineHeight:", lh)
                    var attrs = new("NSMutableDictionary")
                    _ = msg(attrs, "setObject:forKey:", font, ns_string("NSFont"))
                    _ = msg(attrs, "setObject:forKey:", msg(w, "textColor"), ns_string("NSColor"))
                    _ = msg(attrs, "setObject:forKey:", para, ns_string("NSParagraphStyle"))
                    var natural = msg[Float64](font, "ascender") - msg[Float64](font, "descender")
                    _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", (lh - natural) / 2), ns_string("NSBaselineOffset"))
                    if tl >= 0 and self.look.surfaces[tl].tracking != 0:
                        _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", self.look.surfaces[tl].tracking), ns_string("NSKern"))
                    _ = msg(w, "setAttributedStringValue:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(shown), attrs))
                    # (a one-line label's cell sizes to its font, not its paragraph's lines: a line high at least)
                    _ = msg(msg(msg(w, "heightAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(Int(lh + 0.5))), "setActive:", 1)
            var p = self.parents[i] if i < len(self.parents) else -1
            if node.w > 0 or (p >= 0 and self.rt.shown.nodes[p].kind == VSTACK and self.rt.shown.nodes[p].align_items == START):
                _ = msg(w, "setAlignment:", 0)  # a leading column's lines (or a table's cell) read from the leading edge, as on GTK
            var own = self.look.surface(node.name) if node.name != "" else -1
            if own >= 0 and self.look.surfaces[own].one_line:  # the look's one-line words: cut with an ellipsis where they don't fit
                cut_with_ellipsis(w)
                _ = msg(w, "setContentCompressionResistancePriority:forOrientation:", Float32(490), 0)
            elif node.max_w == 0 and node.w == 0 and not self.in_row(i):  # a column's label: one line, wrapping when squeezed
                _ = msg(w, "setLineBreakMode:", 0)  # NSLineBreakByWordWrapping
                _ = msg(w, "setMaximumNumberOfLines:", 0)
                # 490: it keeps its one line unless a real limit squeezes it (a scroll view's width, 495; a fixed width):
                # at 250 a grid's labels collapsed to a letter wide (maccheck's column stats)
                _ = msg(w, "setContentCompressionResistancePriority:forOrientation:", Float32(490), 0)
                self.wraps.append(w)
        elif node.kind == BUTTON:
            var c = self.look.controls.copy()
            var icon_only = (node.style == ICON_ONLY or node.style == ICON_ON) and node.hint != ""
            var inline = node.style == TOOL_INLINE or node.style == TOOL_INLINE_ON
            var tool = node.style == TOOL or node.style == TOOL_ON
            var on = node.style == ICON_ON or node.style == TOOL_ON or node.style == TOOL_INLINE_ON
            var glyph = Float64(c.glyph if c.glyph > 0 else 16)
            # the icon: mojoui's Lucide drawing (what GTK and the web show); an SF Symbol for a name it doesn't have
            var image = svg_icon(node.hint, glyph) if node.hint != "" else 0
            var symbol = image == 0 and node.hint != ""
            if symbol:
                image = msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string(sf_symbol(node.hint)), ns_string(node.text))
            if icon_only:
                w = msg(cls("NSButton"), "buttonWithImage:target:action:", image, self.target, sel("tap:"))
                _ = msg(w, "setBordered:", 0)
                _ = msg(w, "setAccessibilityLabel:", ns_string(node.text))  # (the title is the name a screen reader says)
                if symbol:  # 15 pt symbols, as GTK's 16 px icons: AppKit's default (the label's 13 pt) read tiny in a toolbar (Mac, 2026-10-23)
                    _ = msg(w, "setSymbolConfiguration:", msg(cls("NSImageSymbolConfiguration"), "configurationWithPointSize:weight:", Float64(15), Float64(0)))
                if c.icon > 0:  # the look's icon button: its side high, as wide as its sheet draws it (icon_w, D-558), its corners rounded (GTK: min-width/min-height)
                    constrain(w, "widthAnchor", Float64(c.icon_w if c.icon_w > 0 else c.icon))
                    constrain(w, "heightAnchor", Float64(c.icon))
            else:
                w = msg(cls("NSButton"), "buttonWithTitle:target:action:", ns_string(node.text), self.target, sel("tap:"))
                if image != 0:
                    _ = msg(w, "setImage:", image)
                    # NSCellImagePosition: 2 left, 5 above, 7 leading (3 is right and 1 image only: the sheet tabs' icons came after
                    # their names, and a tool's title was hidden; Mac, 2026-10-25)
                    _ = msg(w, "setImagePosition:", 5 if tool else (7 if inline else 2))  # NSImageAbove / NSImageLeading / NSImageLeft
                    _ = msg(w, "setImageHugsTitle:", 1)
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            var token = node.style == TOKEN or node.style == TOKEN_LIT
            var drawn = self.drawn_controls() and not tool and not inline and not icon_only and not token
            if drawn:
                self.draw_button(w, node.style, node.text, i)
            elif token:  # a sentence's word: the chart's colour, underlined, the sentence's type (its line's look), no fill
                _ = msg(w, "setBordered:", 0)
                var k = self.look.surface("sentence-line")
                var size = self.look.surfaces[k].font_size if k >= 0 and self.look.surfaces[k].font_size > 0 else self.look.type.headline
                var weight = self.look.surfaces[k].font_weight if k >= 0 else 600
                var attrs = new("NSMutableDictionary")
                _ = msg(attrs, "setObject:forKey:", look_font(self.look.type.family, weight, size, self.look.type.tabular), ns_string("NSFont"))
                _ = msg(attrs, "setObject:forKey:", ns_color(self.pal.data(0)), ns_string("NSColor"))
                _ = msg(attrs, "setObject:forKey:", ns_number(0x0101), ns_string("NSUnderline"))  # single, dotted (the web's)
                _ = msg(attrs, "setObject:forKey:", ns_color(mix(self.pal.card, self.pal.data(0), 0.45)), ns_string("NSUnderlineColor"))
                var said = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(node.text), attrs)
                _ = msg(w, "setAttributedTitle:", said)
                var spans = msg[CGPoint](said, "size")  # (its text and 1 pt each side, as GTK's padding: 0 1px; a bare button pads 6)
                constrain(w, "widthAnchor", spans.x + 2)
                constrain(w, "heightAnchor", spans.y)
            if node.style == PROMINENT:
                if not self.submit_field_shown():  # else Return would fire the field and the button
                    _ = msg(w, "setKeyEquivalent:", ns_string("\r"))  # the blue default button; Return taps it
                if not drawn:
                    _ = msg(w, "setControlSize:", 3)  # NSControlSizeLarge
                    _ = msg(w, "setBezelColor:", self.accent())
            elif node.style == DESTRUCTIVE:
                _ = msg(w, "setHasDestructiveAction:", 1)
                if not drawn:
                    _ = msg(w, "setContentTintColor:", msg(cls("NSColor"), "systemRedColor"))
            elif drawn:
                pass
            elif node.style == SUBTLE or tool or inline:
                _ = msg(w, "setBordered:", 0)
                if tool:
                    _ = msg(w, "setFont:", look_font(self.look.type.family, 500, c.tool_font, self.look.type.tabular) if self.skinned else msg(cls("NSFont"), "systemFontOfSize:", Float64(11)))
                    if c.tool_w > 0:
                        _ = msg(msg(msg(w, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(c.tool_w)), "setActive:", 1)
                        _ = msg(msg(msg(w, "heightAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(c.tool_h)), "setActive:", 1)
                elif inline:  # the icon, then the title, one line, the look's height and side padding (GTK: padding 0 10px)
                    _ = msg(w, "setFont:", look_font(self.look.type.family, 500, c.inline_font, self.look.type.tabular) if self.skinned else msg(cls("NSFont"), "systemFontOfSize:", Float64(12)))
                    # its words, the web's icon room and 6 between them, its padding, as the web's flex button measures them
                    # (the button's own fitting size added its cell's insets: Save 77 for the web's 74, D-558)
                    var words = msg[CGPoint](msg(w, "attributedTitle"), "size")
                    constrain(w, "widthAnchor", Float64(Int(words.x + 0.999)) + Float64((BUTTON_ICON + 6 if image != 0 else 0) + 2 * c.inline_pad))
                    if c.inline_h > 0:
                        constrain(w, "heightAnchor", Float64(c.inline_h))
            if (tool or inline or icon_only) and (c.inline_radius > 0 or c.icon_radius > 0):  # a soft square behind it when on
                _ = msg(w, "setWantsLayer:", 1)
                _ = msg(msg(w, "layer"), "setCornerRadius:", Float64(c.icon_radius if icon_only else (c.tool_radius if tool else c.inline_radius)))
            if on:  # (the on state: the accent on a wash, as GTK's mui-tool-on)
                _ = msg(w, "setContentTintColor:", self.accent())
                _ = msg(w, "setState:", 1)
                if self.skinned:
                    _ = msg(w, "setWantsLayer:", 1)
                    _ = msg(msg(w, "layer"), "setBackgroundColor:", msg(ns_color(self.pal.accent_wash), "CGColor"))
            elif self.skinned and node.style != DESTRUCTIVE and node.style != PROMINENT and not drawn and not token:
                _ = msg(w, "setContentTintColor:", ns_color(self.pal.ink2) if (tool or inline or icon_only) else self.ink())
            # a button keeps its title whole: at the default 750 a row of them lost to a column's width at the same
            # priority, squeezing one to 11 pt (maccheck's Controls page, GitHub's Mac and the owner's, 2026-10-23)
            _ = msg(w, "setContentCompressionResistancePriority:forOrientation:", Float32(760), 0)
            if drawn and node.name != "" and self.look.surface(node.name) >= 0:  # (a role's button is its words and padding wide,
                # as CSS measures it: draw_button's required minimum keeps its title whole, and NSButton's own title inset
                # no longer widens it past the width it prefers: a name link 88 for 83, a link 80 for 75, D-536)
                _ = msg(w, "setContentCompressionResistancePriority:forOrientation:", Float32(470), 0)
            if node.align_items == START and not icon_only:  # its content at the leading edge (a sidebar row)
                _ = msg(w, "setAlignment:", 0)  # NSTextAlignmentLeft
                if node.hint != "":
                    _ = msg(w, "setImagePosition:", 7)  # NSImageLeading: icon, then title, from the leading edge
        elif node.kind == FIELD:
            # (.secret(): NSSecureTextField, AppKit's masked field, which also keeps the text off the pasteboard)
            w = msg(cls(String("NSSecureTextField") if node.style == FIELD_SECRET else String("NSTextField")), "textFieldWithString:", ns_string(node.text))
            _ = msg(w, "setPlaceholderString:", ns_string(node.hint))
            _ = msg(w, "setDelegate:", self.target)  # controlTextDidChange: as you type
            self.wire(w, i, self_addr, "submit:")  # the action fires on Return
            if self.drawn_controls():  # the look's box around a borderless field (GTK's entry, the web's input)
                _ = msg(w, "setBezeled:", 0)
                _ = msg(w, "setBordered:", 0)
                _ = msg(w, "setDrawsBackground:", 0)
                _ = msg(w, "setFocusRingType:", 1)  # NSFocusRingTypeNone (the box is the field)
                _ = msg(w, "setFont:", look_font(self.look.type.family, 400, self.look.type.body, self.look.type.tabular))
                _ = msg(w, "setTextColor:", self.ink())
                w = self.shell(i, w)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(220))
        elif node.kind == TOGGLE:
            w = msg(cls("NSButton"), "checkboxWithTitle:target:action:", ns_string(node.text), self.target, sel("toggle:"))
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            _ = msg(w, "setState:", node.value)  # NSControlStateValueOn = 1
            if self.skinned:  # (ticked in the theme's accent, as GTK's check:checked)
                _ = msg(w, "setBezelColor:", self.accent())
                _ = msg(w, "setContentTintColor:", self.accent())
            if self.skinned and node.text == "" and self.look.surface("tick-box") >= 0:  # a tick box with no words: the look's (D-510)
                self.draw_tick(w, self.look.surface("tick-box"), node.value != 0)
        elif node.kind == DROPDOWN:
            w = msg(
                msg(cls("NSPopUpButton"), "alloc"),
                "initWithFrame:pullsDown:",
                Float64(0), Float64(0), Float64(160), Float64(28),  # rect as 4 floats (arm64)
                0,  # pop-up, not pull-down
            )
            for o in node.options:
                _ = msg(w, "addItemWithTitle:", ns_string(o))
            _ = msg(w, "selectItemAtIndex:", node.value)
            self.wire(w, i, self_addr, "select:")
            if self.drawn_controls():  # the look's box (GTK's dropdown button, the web's select), its arrows inside
                _ = msg(w, "setBordered:", 0)
                _ = msg(w, "setFont:", look_font(self.look.type.family, 400, self.look.type.body, self.look.type.tabular))
                w = self.shell(i, w)
        elif node.kind == SLIDER:
            w = msg(
                cls("NSSlider"), "sliderWithValue:minValue:maxValue:target:action:",
                Float64(node.value), Float64(0), Float64(100), self.target, sel("slide:"),
            )
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            _ = msg(w, "setContinuous:", 1)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(240))
        elif node.kind == PROGRESS:
            w = new("NSProgressIndicator")
            _ = msg(w, "setStyle:", 0)  # bar
            _ = msg(w, "setIndeterminate:", 0)
            _ = msg(w, "setMinValue:", Float64(0))
            _ = msg(w, "setMaxValue:", Float64(100))
            _ = msg(w, "setDoubleValue:", Float64(node.value))
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(240))
        elif node.kind == DIVIDER:
            w = new("NSBox")
            _ = msg(w, "setBoxType:", 2)  # NSBoxSeparator
            if self.in_row(i) and not sized:  # between a row's groups (a toolbar): a 1 pt line across the row, as Mac toolbars have
                # (a 280 pt line each: four of them made omxplorer's window at least 1,554 pt wide, GitHub's Mac, 2026-10-23)
                constrain(w, "widthAnchor", Float64(1))
                if not node.sized_height():  # a control high (the web's .hstack > hr: 28)
                    constrain(w, "heightAnchor", Float64(28))
            else:
                if not sized:  # (the app sized it: its settings decide)
                    prefer(w, "widthAnchor", Float64(280))
                if not node.sized_height():
                    constrain(w, "heightAnchor", Float64(1))
        elif node.kind == CANVAS:
            # A MojoCanvas (an NSImageView whose scrollWheel: is Mojo) showing the app's pixels;
            # pan, pinch and click recognisers call back into it.
            w = msg(msg(cls("MojoCanvas"), "alloc"), "initWithFrame:", Float64(0), Float64(0), Float64(320), Float64(240))
            _ = msg(w, "setImageScaling:", 1)  # NSImageScaleAxesIndependently: the pixels fill the view
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            for orientation in range(2):  # its size comes from the layout, never from its picture
                _ = msg(w, "setContentHuggingPriority:forOrientation:", Float32(1), orientation)
                _ = msg(w, "setContentCompressionResistancePriority:forOrientation:", Float32(1), orientation)
            if not sized:
                prefer(w, "widthAnchor", Float64(320))
            if not node.sized_height():
                prefer(w, "heightAnchor", Float64(240))
            # presses, drags and clicks come from mouseDown:/mouseDragged:/mouseUp: (on_canvas_mouse_*): a pan
            # recognizer began only after the pointer had moved, and pressed where it had moved to, so a drag-select
            # needed a hard press (the owner's Mac, 2026-10-23); pinches and right clicks keep their recognizers
            for kind in [("NSMagnificationGestureRecognizer", "canvasPinch:"), ("NSClickGestureRecognizer", "canvasSecondary:")]:
                var r = msg(msg(cls(kind[0]), "alloc"), "initWithTarget:action:", w, sel(kind[1]))
                if kind[1] == "canvasSecondary:":
                    _ = msg(r, "setButtonMask:", 2)  # the right button: SECONDARY (a context menu)
                _ = msg(w, "addGestureRecognizer:", r)
            # A new size (window resized) wakes the display link.
            _ = msg(w, "setPostsFrameChangedNotifications:", 1)
            _ = msg(msg(cls("NSNotificationCenter"), "defaultCenter"), "addObserver:selector:name:object:", w, sel("canvasResized:"), ns_string("NSViewFrameDidChangeNotification"), w)
            _ = msg(msg(cls("NSNotificationCenter"), "defaultCenter"), "addObserver:selector:name:object:", w, sel("canvasResized:"), ns_string("NSWindowDidChangeBackingPropertiesNotification"), 0)  # another screen scale
            self.canvases.append(AppleCanvas(i, w))
        elif node.kind == IMAGE:
            w = msg(cls("NSImageView"), "imageViewWithImage:", ns_image(node.pixels, node.spacing, node.size))
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(node.spacing))
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
        elif (node.kind == SEGMENTED or node.kind == TABS) and self.skinned and self.look.segments.h > 0:
            w = self.segment_track(i, node.options, node.value, self_addr)
        elif node.kind == SEGMENTED or node.kind == TABS:
            w = msg(cls("NSSegmentedControl"), "segmentedControlWithLabels:trackingMode:target:action:",
                    ns_array(node.options), 0, self.target, sel("segment:"))  # 0 = select one
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            _ = msg(w, "setSelectedSegment:", node.value)
            if node.kind == TABS:
                _ = msg(w, "setControlSize:", 3)  # large
        elif node.kind == RADIO:
            w = new("NSStackView")
            _ = msg(w, "setOrientation:", 1)
            _ = msg(w, "setAlignment:", 1)  # leading
            for j in range(len(node.options)):
                var b = msg(cls("NSButton"), "radioButtonWithTitle:target:action:", ns_string(node.options[j]), self.target, sel("radio:"))
                _ = msg(b, "setTag:", tag_for(self_addr, i))
                _ = msg(b, "setState:", 1 if j == node.value else 0)
                _ = msg(w, "addArrangedSubview:", b)
        elif node.kind == TEXTAREA:
            w = msg(cls("NSTextView"), "scrollableTextView")
            var text = msg(w, "documentView")
            _ = msg(text, "setString:", ns_string(node.text))
            _ = msg(text, "setFont:", msg(cls("NSFont"), "systemFontOfSize:", Float64(13)))
            _ = msg(text, "setRichText:", 0)
            _ = msg(text, "setIdentifier:", ns_string(String(tag_for(self_addr, i))))  # NSTextView has no tag
            _ = msg(text, "setDelegate:", self.target)  # textDidChange:
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(320))
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
            self.widgets[i] = text
        elif node.kind == ALERT:
            # Shown on the next run-loop turn (not inside the event that asked for it).
            _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("showAlert:"), ns_number(tag_for(self_addr, i)), Float64(0))
            w = new("NSView")  # nothing in the layout itself
        elif node.kind == NAVBAR:
            w = new("NSStackView")
            _ = msg(w, "setOrientation:", 0)
            _ = msg(w, "setSpacing:", Float64(8))
            if node.msg != 0:
                var back = msg(cls("NSButton"), "buttonWithTitle:target:action:", ns_string("‹ Back"), self.target, sel("tap:"))
                _ = msg(back, "setTag:", tag_for(self_addr, i))
                _ = msg(w, "addArrangedSubview:", back)
            var title = msg(cls("NSTextField"), "labelWithString:", ns_string(node.text))
            _ = msg(title, "setFont:", msg(cls("NSFont"), "boldSystemFontOfSize:", Float64(17)))
            _ = msg(w, "addArrangedSubview:", title)
        elif node.kind == DATE:
            w = new("NSDatePicker")
            _ = msg(w, "setDatePickerStyle:", 0)  # text field and stepper
            _ = msg(w, "setDatePickerElements:", 0x00E0)  # year, month, day
            _ = msg(w, "setDateValue:", ns_date(node.text))
            self.wire(w, i, self_addr, "date:")
        elif node.kind == ICON and node.text == "app-logo" and self.rt.app.logo() != "":
            # the app's mark: NSImage reads SVG itself (macOS 14+); a symbol stands in if it can't
            var svg = self.rt.app.logo()
            var bytes = List[UInt8](svg.as_bytes())
            var logo = msg(msg(cls("NSImage"), "alloc"), "initWithData:", ns_data(bytes))
            if logo == 0:
                self.report.note("app-logo: NSImage can't read the SVG")
                logo = msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string("square.grid.2x2"), 0)
            _ = msg(logo, "setSize:", Float64(node.size), Float64(node.size))
            w = msg(cls("NSImageView"), "imageViewWithImage:", logo)
            constrain(w, "widthAnchor", Float64(node.size))
            constrain(w, "heightAnchor", Float64(node.size))
        elif node.kind == ICON:
            # mojoui's Lucide drawing (what GTK and the web show) in a box its size; an SF Symbol for a name it hasn't
            var drawing = svg_icon(node.text, Float64(node.size)) if node.size > 0 else 0
            if drawing != 0:
                w = msg(cls("NSImageView"), "imageViewWithImage:", drawing)
                constrain(w, "widthAnchor", Float64(node.size))
                constrain(w, "heightAnchor", Float64(node.size))
            else:
                var image = msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string(sf_symbol(node.text)), 0)
                w = msg(cls("NSImageView"), "imageViewWithImage:", image)
                var config = msg(cls("NSImageSymbolConfiguration"), "configurationWithPointSize:weight:", Float64(node.size), Float64(0))
                _ = msg(w, "setSymbolConfiguration:", config)
            _ = msg(w, "setContentTintColor:", msg(cls("NSColor"), "controlAccentColor"))
        elif node.kind == GRID:
            w = new("NSStackView")
            _ = msg(w, "setOrientation:", 1)
            _ = msg(w, "setSpacing:", Float64(node.spacing))
            var row = 0
            var fitted = node.style == 1
            var col_gap = node.spacing
            var gk = self.look.surface(node.name) if node.name != "" else -1
            if gk >= 0 and self.look.surfaces[gk].column_gap >= 0:  # (a role's column gap, the web's column-gap: D-495)
                col_gap = self.look.surfaces[gk].column_gap
            var firsts = List[Int]()  # (fitted: the first row's holders, one per column)
            var shares = List[Float64]()  # (column shares, Grid(shares=[52, 48]): the web's fr columns, D-535)
            var share_sum = Float64(0)
            if not fitted:
                for v in node.options:
                    var f = Float64(1)
                    try:
                        f = Float64(max(Int(v), 1))
                    except:
                        f = 1
                    shares.append(f)
                    share_sum += f
            var shared = len(shares) == node.value and share_sum > 0
            for k in range(len(node.children)):
                if k % node.value == 0:
                    row = new("NSStackView")
                    _ = msg(row, "setOrientation:", 0)
                    _ = msg(row, "setDistribution:", 0 if fitted or shared else 1)  # fitted, shared: by the constraints below; else fill equally
                    _ = msg(row, "setSpacing:", Float64(col_gap))
                    _ = msg(w, "addArrangedSubview:", row)
                    # every row spans the grid, its columns equal (as GTK's homogeneous grid): a row of its own size sat
                    # centred, so the Report's chart tile was half as wide as the tiles above it (GitHub's Mac, 2026-10-23)
                    _ = msg(msg(msg(row, "widthAnchor"), "constraintEqualToAnchor:", msg(w, "widthAnchor")), "setActive:", 1)
                var item = self.build(node.children[k], self_addr)
                if not fitted:
                    _ = msg(row, "addArrangedSubview:", item)
                    if shared:  # (each column its share of the row less the gaps; the last the rest, as fit_shares on GTK)
                        var col_k = k % node.value
                        if col_k < node.value - 1:
                            var part = shares[col_k] / share_sum
                            var c3 = msg(msg(item, "widthAnchor"), "constraintEqualToAnchor:multiplier:constant:", msg(row, "widthAnchor"), part, -Float64(col_gap * (node.value - 1)) * part)
                            _ = msg(c3, "setActive:", 1)
                        else:
                            hug(item, Float32(1), False)
                        # (its cells as tall as their row, as a table's: a value beside a key on two lines, D-538)
                        _ = msg(msg(msg(item, "heightAnchor"), "constraintEqualToAnchor:", msg(row, "heightAnchor")), "setActive:", 1)
                    continue
                # fitted (a definition list): every column but the last as wide as its widest item, the last the rest;
                # each item its own width from the column's start, centred down (the web's grid-template-columns:
                # max-content … minmax(0, 1fr), justify-items: start, align-items: center; GTK's place_in_grid, D-495)
                var col = k % node.value
                var holder = new("NSStackView")
                _ = msg(holder, "setOrientation:", 0)
                _ = msg(holder, "setSpacing:", Float64(0))
                _ = msg(holder, "setAlignment:", 10)  # centre Y
                var at_end = node.hint == "E" and col == node.value - 1  # (Grid(end=True): the last column's items at its trailing edge, D-535)
                if at_end and not self.rt.shown.nodes[node.children[k]].fills:
                    _ = msg(holder, "addArrangedSubview:", flexible_spacer(False))
                _ = msg(holder, "addArrangedSubview:", item)
                if self.rt.shown.nodes[node.children[k]].fills:
                    hug(item, Float32(1), False)
                elif not at_end:
                    _ = msg(holder, "addArrangedSubview:", flexible_spacer(False))
                _ = msg(row, "addArrangedSubview:", holder)
                if col == node.value - 1:
                    hug(holder, Float32(1), False)  # (the last column takes the rest)
                    continue
                if self.rt.shown.nodes[node.children[k]].kind == TEXT:  # (a key column is as wide as its widest words, never
                    # wrapped: the web's max-content, GTK's D-484; a wrapping label's 490 lost to the holder's 740, D-538)
                    _ = msg(item, "setContentCompressionResistancePriority:forOrientation:", Float32(750), 0)
                    for q in range(len(self.wraps)):
                        if self.wraps[q] == item:
                            self.wraps[q] = 0
                    _ = msg(item, "setMaximumNumberOfLines:", 1)
                hug(holder, Float32(740), False)  # (tight round its widest item: below a label's 750 resistance)
                if col >= len(firsts):
                    firsts.append(holder)
                else:
                    _ = msg(msg(msg(holder, "widthAnchor"), "constraintEqualToAnchor:", msg(firsts[col], "widthAnchor")), "setActive:", 1)
        elif node.kind == LAZYLIST:
            var table = new("NSTableView")
            var column = msg(msg(cls("NSTableColumn"), "alloc"), "initWithIdentifier:", ns_string("rows"))
            _ = msg(column, "setWidth:", Float64(320))
            _ = msg(table, "addTableColumn:", column)
            _ = msg(table, "setHeaderView:", 0)
            _ = msg(table, "setRowHeight:", Float64(node.spacing - 4))
            _ = msg(table, "setUsesAlternatingRowBackgroundColors:", 1)
            _ = msg(table, "setTag:", tag_for(self_addr, i))
            _ = msg(table, "setDataSource:", self.target)  # rows are asked for as they scroll into view
            _ = msg(table, "setTarget:", self.target)
            _ = msg(table, "setAction:", sel("rowTap:"))
            w = new("NSScrollView")
            _ = msg(w, "setHasVerticalScroller:", 1)
            _ = msg(w, "setDocumentView:", table)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(340))
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
            self.widgets[i] = table
        elif node.kind == BOARD:
            # A scroll view over a flipped content view (y runs down, as on every other host) where each child sits
            # at its own place; a child drags by a pan (the Board's on_move).
            w = top_scroll_view(True)
            _ = msg(w, "setDrawsBackground:", 0)
            var content = msg(msg(cls("MojoBoardView"), "alloc"), "initWithFrame:", Float64(0), Float64(0), Float64(node.spacing), Float64(node.size))
            _ = msg(w, "setDocumentView:", content)
            for k in range(len(node.children)):
                var c = node.children[k]
                var cn = self.rt.shown.nodes[c].copy()  # (copy: building the child mutates self)
                var look_at = self.look.surface(cn.name) if cn.name != "" else -1
                var boxed = look_at >= 0 and self.look.surfaces[look_at].pad_top >= 0
                self.boxed = c if boxed else -1
                var child = self.build(c, self_addr)
                self.boxed = -1
                _ = msg(child, "setTranslatesAutoresizingMaskIntoConstraints:", 1)
                var placed = child
                if boxed:
                    # a Board's object wears its content's tag, as on GTK and the web: the role's box at the object's
                    # place, its content inside the role's padding (the web's .object[data-tag=table] and its view)
                    var sf = self.look.surfaces[look_at].copy()
                    placed = new("MojoBoardView")
                    # its size first: the clip and the content follow the box's size changes, and grown from 0 × 0 they
                    # came out twice the box (the table's content 2144 × 694 in a 1084 × 358 box; Mac, 2026-10-25)
                    _ = msg(placed, "setFrame:", Float64(cn.x), Float64(cn.y), Float64(cn.w), Float64(cn.h))
                    self.paint_surface(placed, look_at, False)
                    var clip = new("MojoBoardView")  # (the object clips its content, as the web's .object: overflow hidden; its shadow stays)
                    _ = msg(clip, "setFrame:", Float64(0), Float64(0), Float64(cn.w), Float64(cn.h))
                    _ = msg(clip, "setAutoresizingMask:", 18)  # width and height follow the box
                    _ = msg(clip, "setWantsLayer:", 1)
                    _ = msg(msg(clip, "layer"), "setMasksToBounds:", 1)
                    _ = msg(msg(clip, "layer"), "setCornerRadius:", Float64(max(sf.radius_top, 0)))
                    # inside the role's padding, filling what's left (it ran 12 pt past the box's right edge, cut there)
                    _ = msg(child, "setFrame:", Float64(sf.pad_x), Float64(sf.pad_top), Float64(cn.w - 2 * sf.pad_x), Float64(cn.h - sf.pad_top - sf.pad_bottom))
                    _ = msg(child, "setAutoresizingMask:", 18)
                    _ = msg(clip, "addSubview:", child)
                    _ = msg(placed, "addSubview:", clip)
                    _ = msg(placed, "setTranslatesAutoresizingMaskIntoConstraints:", 1)
                    self.objects[c] = placed
                _ = msg(placed, "setFrame:", Float64(cn.x), Float64(cn.y), Float64(cn.w), Float64(cn.h))
                if node.text == "clips":  # (a tiled Board: the resize grip in the corner that drags, as GTK's and the web's)
                    _ = msg(placed, "addSubview:", make_grip(cn.w, cn.h, self.pal.ink3, (msg(placed, "isFlipped") & 0xFF) != 0))
                _ = msg(placed, "setIdentifier:", ns_string(String(tag_for(self_addr, c))))
                _ = msg(content, "addSubview:", placed)
                if node.msg != 0:  # on_move: drag it (by anywhere on it; the title strip in practice)
                    var pan = msg(msg(cls("NSPanGestureRecognizer"), "alloc"), "initWithTarget:action:", self.target, sel("boardPan:"))
                    _ = msg(placed, "addGestureRecognizer:", pan)
            if not sized:
                prefer(w, "widthAnchor", Float64(min(node.spacing, 760)))
            if not node.sized_height():
                prefer(w, "heightAnchor", Float64(min(node.size, 480)))
        elif node.kind == OVERLAY:
            w = new("NSView")
            for k in range(len(node.children)):
                var c = node.children[k]
                var child = self.build(c, self_addr)
                _ = msg(child, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
                _ = msg(w, "addSubview:", child)
                if k == 0:  # the base fills the overlay
                    for anchor in ["topAnchor", "bottomAnchor", "leadingAnchor", "trailingAnchor"]:
                        _ = msg(msg(msg(child, anchor), "constraintEqualToAnchor:", msg(w, anchor)), "setActive:", 1)
                else:  # an island: pinned to an edge or corner, 12 pt in (AppKit's y runs up: END is the bottom)
                    var pin = self.rt.shown.nodes[c].copy()
                    if self.skinned:
                        _ = msg(child, "setWantsLayer:", 1)
                        _ = msg(msg(child, "layer"), "setBackgroundColor:", msg(ns_color(self.pal.card), "CGColor"))
                        _ = msg(msg(child, "layer"), "setCornerRadius:", Float64(6))
                    if pin.x == START:
                        _ = msg(msg(msg(child, "leadingAnchor"), "constraintEqualToAnchor:constant:", msg(w, "leadingAnchor"), Float64(12)), "setActive:", 1)
                    elif pin.x == END:
                        _ = msg(msg(msg(child, "trailingAnchor"), "constraintEqualToAnchor:constant:", msg(w, "trailingAnchor"), Float64(-12)), "setActive:", 1)
                    else:
                        _ = msg(msg(msg(child, "centerXAnchor"), "constraintEqualToAnchor:", msg(w, "centerXAnchor")), "setActive:", 1)
                    if pin.y == END:
                        _ = msg(msg(msg(child, "bottomAnchor"), "constraintEqualToAnchor:constant:", msg(w, "bottomAnchor"), Float64(-12)), "setActive:", 1)
                    else:
                        _ = msg(msg(msg(child, "topAnchor"), "constraintEqualToAnchor:constant:", msg(w, "topAnchor"), Float64(12)), "setActive:", 1)
            if not sized:
                prefer(w, "widthAnchor", Float64(320))
            if not node.sized_height():
                prefer(w, "heightAnchor", Float64(240))
        elif node.kind == MENUBAR:
            self.install_menubar(i, self_addr)  # the system menu bar (D-150); nothing in the layout
            self.has_menubar = True
            w = new("NSView")
            for c in node.children:  # (menus and items keep their nodes; nothing to lay out)
                self.widgets[c] = 0
        elif node.kind == MENU and node.style == 0:
            w = new("NSView")  # (lives in the menu bar: see MENUBAR)
        elif node.kind == MENU:  # a context menu: a popover of its items at the right-click point
            self.show_popover(i, self.item_rows(node.children, self_addr), self_addr)
            w = new("NSView")
        elif node.kind == ITEM:
            w = new("NSView")
        elif node.kind == POPOVER:
            var column = new("NSStackView")
            _ = msg(column, "setOrientation:", 1)
            _ = msg(column, "setAlignment:", 5)
            _ = msg(column, "setSpacing:", Float64(8))
            if node.hint != "":
                var head = msg(cls("NSTextField"), "labelWithString:", ns_string(node.hint))
                _ = msg(head, "setFont:", look_font(self.look.type.family, 600, self.look.type.body, self.look.type.tabular) if self.skinned else msg(cls("NSFont"), "boldSystemFontOfSize:", Float64(13)))  # (the web's .popover-title: 13, 600)
                if self.skinned:
                    _ = msg(head, "setTextColor:", self.ink())
                _ = msg(column, "addArrangedSubview:", head)
            for c in node.children:
                _ = msg(column, "addArrangedSubview:", self.build(c, self_addr))
            self.show_popover(i, column, self_addr)
            w = new("NSView")
        elif node.kind == DIALOG:
            var content = new("NSStackView")
            _ = msg(content, "setOrientation:", 1)
            _ = msg(content, "setAlignment:", 5)
            for c in node.children:
                _ = msg(content, "addArrangedSubview:", self.build(c, self_addr))
            self.show_sheet(i, content, self_addr)
            w = new("NSView")
        elif node.kind == TOAST:
            if self.toast != 0 and self.toast_text == node.text:  # the same toast, still up: keep it
                _ = msg(self.toast, "setIdentifier:", ns_string(String(tag_for(self_addr, i))))
            else:
                if self.toast != 0:
                    _ = msg(self.toast, "removeFromSuperview")
                self.toast = make_toast(node.text, node.options[0] if len(node.options) > 0 else String(""), tag_for(self_addr, i), self.target, self.pal)
                self.toast_text = node.text
                _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("toastTimeout:"), ns_number(tag_for(self_addr, i)), Float64(node.size if node.size > 0 else 6))
            self.toast_claimed = True
            self.widgets[i] = self.toast
            w = new("NSView")
        elif node.kind == SPACER or node.kind == ROUTE:  # (a Route is state here: no URL)
            w = new("NSView")
        elif node.kind == TABLE:  # rows of cells wearing the look's table roles; fit_tables() shares the width as the web's <table> does
            w = new("NSStackView")
            _ = msg(w, "setOrientation:", 1)
            _ = msg(w, "setSpacing:", Float64(0))
            _ = msg(w, "setAlignment:", 5)  # leading
            var cols = max(node.value, 1)
            var row = 0
            for k in range(len(node.children)):
                var r = k // cols
                var col = k % cols
                if col == 0:
                    row = new("NSStackView")
                    _ = msg(row, "setOrientation:", 0)
                    _ = msg(row, "setSpacing:", Float64(0))
                    _ = msg(row, "setAlignment:", 3)  # top: each cell is the row's height
                    _ = msg(w, "addArrangedSubview:", row)
                    _ = msg(msg(msg(row, "widthAnchor"), "constraintEqualToAnchor:", msg(w, "widthAnchor")), "setActive:", 1)
                var c = node.children[k]
                var child = self.build(c, self_addr)
                var num = col < node.hint.byte_length() and String(node.hint[byte=col]) == "R"
                var ck = self.rt.shown.nodes[c].kind
                if ck == TOGGLE and self.rt.shown.nodes[c].text == "" and self.skinned:  # (a table's tick box: the table's size, D-510)
                    var tk = self.look.surface("tick-box-table-compact" if node.style == 2 else "tick-box-table")
                    if tk >= 0 and self.widgets[c] != 0:
                        self.draw_tick(self.widgets[c], tk, self.rt.shown.nodes[c].value != 0)
                var cell = new("NSStackView")
                _ = msg(cell, "setOrientation:", 0)
                _ = msg(cell, "setSpacing:", Float64(0))
                _ = msg(cell, "setAlignment:", 10)  # centre Y
                _ = msg(cell, "setDistribution:", 0)  # fill: the cell's view across it (a block in a <td>); gravity areas left a name its own width (run 40288990159)
                var keeps = ck == BUTTON or ck == TOGGLE  # (a button or a tick box keeps its width at its side; the rest fill, as a block in a <td>)
                if keeps and num:
                    _ = msg(cell, "addArrangedSubview:", flexible_spacer(False))
                _ = msg(cell, "addArrangedSubview:", child)
                if keeps and not num:
                    _ = msg(cell, "addArrangedSubview:", flexible_spacer(False))
                if ck == VSTACK or ck == DRAG or ck == DROP:  # (a column in a cell is its own height, centred, as a block in a <td>: the cell's 250 pins
                    hug(child, Float32(750), True)  # stood a model's name cell 44 high for 37, D-542)
                if not keeps:
                    hug(child, Float32(1), False)
                var role = String("table-head") if r == 0 else String("table-cell")
                var sk = self.look.surface(role)
                if r > 0 and r - 1 < node.text.byte_length() and String(node.text[byte = r - 1]) == "1" and self.look.surface("table-selected") >= 0:
                    sk = self.look.surface("table-selected")
                # a dense table's cells wear the dense roles over it, as the web's: their padding and rules (on a phone the
                # compact ones; a snug column's cells table-dense-snug); their words on one line, cut, but in a column that
                # wraps ("W") (D-493)
                var lim = node.options[col] if col < len(node.options) else String("")
                var dense = node.style == 1 or node.style == 2
                var over = -1
                if dense:
                    var compact = node.style == 2
                    var snug = r > 0 and not lim.startswith("T") and lim.endswith("S")
                    var name = ("table-dense-compact-" if compact else "table-dense-") + ("head" if r == 0 else ("snug" if snug else "cell"))
                    over = self.look.surface(name)
                    if over < 0:
                        over = self.look.surface("table-dense-head" if r == 0 else ("table-dense-snug" if snug else "table-dense-cell"))
                    if lim != "W":
                        self.one_line_words(c)
                if sk >= 0:
                    self.paint_surface(cell, sk, True, over)
                else:
                    _ = msg(cell, "setEdgeInsets:", Float64(9), Float64(16), Float64(9), Float64(16))
                if ck == TEXT and (msg(child, "isKindOfClass:", cls("NSTextField")) & 0xFF) != 0:
                    if self.rt.shown.nodes[c].name == "":  # (its words in the role's type: the head's caps, a figure's mono)
                        var tk = self.look.surface("table-num") if num and r > 0 and self.look.surface("table-num") >= 0 else self.look.surface(role)
                        if tk >= 0:
                            self.restyle_label(child, self.label_text(c, self.rt.shown.nodes[c].text), tk)
                    _ = msg(child, "setAlignment:", 2 if num else 0)  # NSTextAlignmentRight / Left
                _ = msg(row, "addArrangedSubview:", cell)
                hold_insets(cell)
                _ = msg(msg(msg(cell, "heightAnchor"), "constraintEqualToAnchor:", msg(row, "heightAnchor")), "setActive:", 1)
                var wc = 0
                if col < cols - 1:
                    wc = msg(msg(cell, "widthAnchor"), "constraintEqualToConstant:", Float64(80))
                    _ = msg(wc, "setPriority:", Float32(999))
                    _ = msg(wc, "setActive:", 1)
                else:
                    hug(cell, Float32(1), False)
                self.tcells.append((w, cell, wc, col, c))
        elif node.kind == SCROLL:
            w = top_scroll_view(False)
            _ = msg(w, "setDrawsBackground:", 0)
            var content = self.build(node.children[0], self_addr)
            _ = msg(content, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            var clip = msg(w, "contentView")
            ref inner = self.rt.shown.nodes[node.children[0]]
            # a content narrower than the clip (a column at its widest) sits in its middle, as the web's .scroll centres
            # it (align-items: center): in a document view as wide as the clip (the clip scrolls to its document's
            # origin, so a centred document sat at the left again, run 40294665922), the content centred in it (D-504)
            var doc = content
            if inner.max_w != 0 or inner.w != 0:
                doc = new("NSView")
                _ = msg(doc, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
                _ = msg(doc, "addSubview:", content)
                for anchor in ["topAnchor", "bottomAnchor", "centerXAnchor"]:
                    _ = msg(msg(msg(content, anchor), "constraintEqualToAnchor:", msg(doc, anchor)), "setActive:", 1)
                _ = msg(msg(msg(content, "widthAnchor"), "constraintLessThanOrEqualToAnchor:", msg(doc, "widthAnchor")), "setActive:", 1)
                var full = msg(msg(content, "widthAnchor"), "constraintEqualToAnchor:", msg(doc, "widthAnchor"))
                _ = msg(full, "setPriority:", Float32(494))  # (up to its widest: its own max-width is required)
                _ = msg(full, "setActive:", 1)
            var own = self.look.surface(node.name) if node.name != "" else -1
            if doc == content and own >= 0 and self.look.surfaces[own].pad_top >= 0:  # its role's padding inside what scrolls,
                ref sf = self.look.surfaces[own]  # as the web's padding on a scrolling element (the notebook's aside, D-528)
                doc = new("NSView")
                _ = msg(doc, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
                _ = msg(doc, "addSubview:", content)
                var left = Float64(sf.pad_left if sf.pad_left >= 0 else sf.pad_x)
                var right = Float64(sf.pad_right if sf.pad_right >= 0 else sf.pad_x)
                _ = msg(msg(msg(content, "topAnchor"), "constraintEqualToAnchor:constant:", msg(doc, "topAnchor"), Float64(sf.pad_top)), "setActive:", 1)
                _ = msg(msg(msg(content, "leadingAnchor"), "constraintEqualToAnchor:constant:", msg(doc, "leadingAnchor"), left), "setActive:", 1)
                _ = msg(msg(msg(doc, "trailingAnchor"), "constraintEqualToAnchor:constant:", msg(content, "trailingAnchor"), right), "setActive:", 1)
                _ = msg(msg(msg(doc, "bottomAnchor"), "constraintEqualToAnchor:constant:", msg(content, "bottomAnchor"), Float64(max(sf.pad_bottom, 0))), "setActive:", 1)
            _ = msg(w, "setDocumentView:", doc)
            for anchor in ["topAnchor", "leadingAnchor", "widthAnchor"]:
                var pin = msg(msg(doc, anchor), "constraintEqualToAnchor:", msg(clip, anchor))
                if anchor == "widthAnchor":  # (content the app made wider is cut off at the edge: it never widens the window)
                    _ = msg(pin, "setPriority:", Float32(495))  # below NSLayoutPriorityWindowSizeStayPut (500), above a wrapping label (490)
                _ = msg(pin, "setActive:", 1)
            if not node.sized_height() and node.size > 0:
                constrain(w, "heightAnchor", Float64(node.size))
            elif not node.sized_height() and not self.in_row(i):  # height 0, not growing down: as tall as its content, as the web's .scroll with no
                # max-height (a required 0 collapsed the notebook's document layout to nothing: run 40299704650, D-508);
                # above a column's 750 hugging, below what the window holds
                var tall = msg(msg(w, "heightAnchor"), "constraintEqualToAnchor:", msg(doc, "heightAnchor"))
                _ = msg(tall, "setPriority:", Float32(751))
                _ = msg(tall, "setActive:", 1)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(320))
            if node.value == 1:
                self.pinned.append(i)
        else:  # (a Draggable, a DropTarget and a WebFrame show their one child: drag and drop isn't built here yet)
            w = new("NSStackView")
            var vertical = node.kind == VSTACK or node.kind == DRAG or node.kind == DROP or node.kind == EMBED or node.kind == WEBCOMP
            _ = msg(w, "setOrientation:", 1 if vertical else 0)
            # align → NSStackView alignment (NSLayoutAttribute); STRETCH = per-child constraints below
            var align = 9 if vertical else 10  # centre X / centre Y
            if node.align_items == START:
                align = 5 if vertical else 3  # leading / top
            elif node.align_items == END:
                align = 6 if vertical else 4  # trailing / bottom
            elif node.align_items == STRETCH:  # every view is stretched below; placed from the leading (top) inset, as
                # NSStackView centres a stretched view in its whole bounds: a frame padded 0 above and 14 below put its
                # card 7 pt low and everything under it (D-505)
                var centred = False  # (a view held to its widest is centred on the stack: keep the centre then)
                for c in node.children:
                    if self.rt.shown.nodes[c].max_w != 0:
                        centred = True
                if not centred:
                    align = 5 if vertical else 3
            _ = msg(w, "setAlignment:", align)
            # across its axis a stack is as wide (tall) as its widest view: it hugs loosely, so a row of buttons is never
            # squeezed to a narrower row's width (maccheck's Delete button, 11 pt, GitHub's Mac, 2026-10-23)
            _ = msg(w, "setHuggingPriority:forOrientation:", Float32(250), 0 if vertical else 1)
            # along it, its views' own length, as a GTK box that isn't told to expand (a growing stack: hug() sets 1)
            _ = msg(w, "setHuggingPriority:forOrientation:", Float32(750), 1 if vertical else 0)
            _ = msg(w, "setSpacing:", Float64(node.spacing))
            if node.pad_v != 0 or node.pad_h != 0:  # padding = the stack's own edge insets
                _ = msg(w, "setEdgeInsets:", Float64(node.pad_v), Float64(node.pad_h), Float64(node.pad_v), Float64(node.pad_h))
            if vertical and node.style != 0:  # a Card: a raised panel (tinted for a warning or a success)
                var tint = self.pal.card if self.skinned else UInt32(0)
                if node.style == CARD_WARN:
                    tint = mix(self.pal.card, self.pal.warn, 0.09)
                elif node.style == CARD_GOOD:
                    tint = mix(self.pal.card, self.pal.good, 0.08)
                _ = msg(w, "setWantsLayer:", 1)
                _ = msg(msg(w, "layer"), "setBackgroundColor:", msg(ns_color(tint) if self.skinned else msg(cls("NSColor"), "controlBackgroundColor"), "CGColor"))
                _ = msg(msg(w, "layer"), "setCornerRadius:", Float64(6 if self.skinned else 10))
                if node.pad_v == 0 and node.pad_h == 0:
                    _ = msg(w, "setEdgeInsets:", Float64(12), Float64(14), Float64(12), Float64(14))
            var look_at = self.look.surface(node.name) if node.name != "" and i != self.boxed else -1  # (a boxed Board child: its box wears it)
            var inset_x = 2 * node.pad_h  # (what a filling child leaves across, both sides together: the view's padding, or its role's)
            var inset_y = 2 * node.pad_v
            if look_at >= 0:  # a framework role the theme's look shapes (the toolbar's island, the inspector's panel)
                var own_pad = node.pad_v == 0 and node.pad_h == 0
                self.paint_surface(w, look_at, own_pad)
                if node.w > 0 and node.h > 0:  # a fixed size (a dot): its corners at most half of it now
                    var r = max(self.look.surfaces[look_at].radius_top, self.look.surfaces[look_at].radius_bottom)
                    _ = msg(msg(w, "layer"), "setCornerRadius:", min(Float64(r), Float64(min(node.w, node.h)) / 2))
                if own_pad and self.look.surfaces[look_at].pad_top >= 0:
                    ref ps = self.look.surfaces[look_at]
                    inset_x = (ps.pad_left if ps.pad_left >= 0 else ps.pad_x) + (ps.pad_right if ps.pad_right >= 0 else ps.pad_x)
                    inset_y = ps.pad_top + ps.pad_bottom
            elif self.skinned and (node.name == "toolbar" or node.name == "status-bar" or node.name == "menubar"):  # the chrome band
                _ = msg(w, "setWantsLayer:", 1)
                _ = msg(msg(w, "layer"), "setBackgroundColor:", msg(ns_color(self.pal.chrome), "CGColor"))
            # justify → distribution (BETWEEN) or flexible spacers (START, CENTER, END), all native
            var grows = False
            var spacers = False  # a Spacer takes the free space along its stack, as GTK's expanding one (it sat 0 pt tall
            for c in node.children:  # and the status bar floated mid-window, GitHub's Mac, 2026-10-23)
                grows = grows or self.rt.shown.nodes[c].grows or (not vertical and self.rt.shown.nodes[c].kind == TABLE)
                spacers = spacers or self.rt.shown.nodes[c].kind == SPACER
            if node.justify_items == BETWEEN:
                _ = msg(w, "setDistribution:", 3)  # NSStackViewDistributionEqualSpacing
            elif grows or spacers or node.justify_items != 0:
                _ = msg(w, "setDistribution:", 0)  # fill: the lowest-hugging view takes the free space
            var lead = 0
            if (node.justify_items == CENTER or node.justify_items == END) and not grows and not spacers:  # a growing child (or a Spacer) takes it all
                lead = flexible_spacer(vertical)
                _ = msg(w, "addArrangedSubview:", lead)
            var first_spacer = 0
            var all_grow = not vertical and len(node.children) > 1  # a row whose views all grow shares its width equally
            for c in node.children:  # (the web's flex: 1 1 0, GTK's homogeneous box, D-447; the Mac gave each its content, D-506)
                all_grow = all_grow and self.rt.shown.nodes[c].grows and self.rt.shown.nodes[c].w == 0
            var first_grow = 0
            var before = lead  # (the view before this one in the stack: a Divider's room goes after it)
            var built = List[Int]()
            var ended = False  # (a view at the row's end took the free room before it: no room after the views)
            for c in node.children:
                var child = self.build(c, self_addr)
                built.append(child if self.rt.shown.nodes[c].kind != SPACER else 0)
                var end_role = self.look.surface(self.rt.shown.nodes[c].name) if self.rt.shown.nodes[c].name != "" else -1
                if not vertical and not grows and not spacers and end_role >= 0 and self.look.surfaces[end_role].ends_row:
                    # (the room before it: the web's margin-left auto, GTK's hexpand + END, D-529)
                    ended = True
                    var room_before = flexible_spacer(False)
                    _ = msg(w, "setDistribution:", 0)
                    _ = msg(w, "addArrangedSubview:", room_before)
                    _ = msg(w, "setCustomSpacing:afterView:", Float64(0), room_before)
                _ = msg(w, "addArrangedSubview:", child)
                ref cn = self.rt.shown.nodes[c]
                if cn.kind == DIVIDER and not (cn.sized_width() if not vertical else cn.sized_height()):
                    # a Divider keeps its room each side, as the web's hr: the look's (D-490: below 0 none), else 4 pt above and below
                    # in a column, 6 pt beside it in a row (D-440)
                    var own = self.look.controls.divider_gap if vertical else self.look.controls.divider_side
                    var room = Float64(node.spacing + (max(own, 0) if own != 0 else (4 if vertical else 6)))
                    if before != 0:
                        _ = msg(w, "setCustomSpacing:afterView:", room, before)
                    _ = msg(w, "setCustomSpacing:afterView:", room, child)
                before = child
                if all_grow:
                    if first_grow == 0:
                        first_grow = child
                    else:
                        _ = msg(msg(msg(child, "widthAnchor"), "constraintEqualToAnchor:", msg(first_grow, "widthAnchor")), "setActive:", 1)
                if cn.grows:  # flex-grow: lowest hugging priority along the stack
                    # (words that grow in a row nothing stretches take only the room the row was given: the row hugs them in
                    # its column, whose leading pins pull at 250, as the web's flex item in a shrink-to-fit row; a list
                    # item's words stood the column's 650 pt for 162, D-532)
                    var given = node.fills or (i < len(self.parents) and self.parents[i] >= 0 and self.rt.shown.nodes[self.parents[i]].align_items == STRETCH)
                    var words = cn.kind == TEXT or cn.kind == PARAGRAPH
                    hug(child, Float32(251 if (not vertical and words and not given) else 1), vertical)
                elif cn.kind == SPACER:  # (a growing view first, if there is one)
                    hug(child, Float32(2 if grows else 1), vertical)
                    if first_spacer != 0:  # spacers share the free space equally, as GTK's expanding ones (a toolbar's
                        var along = "heightAnchor" if vertical else "widthAnchor"  # middle tools sit centred)
                        _ = msg(msg(msg(child, along), "constraintEqualToAnchor:", msg(first_spacer, along)), "setActive:", 1)
                    else:
                        first_spacer = child
                elif grows or spacers:  # beside a growing view, keep to its own size (a chevron took a row's spare room, Mac)
                    var wrapping = False  # (a wrapping button's own size is its wrapped one: it keeps its line by D-537's 491 instead)
                    for wb in self.wrap_buttons:
                        if wb[0] == child:
                            wrapping = True
                    hug(child, Float32(490 if wrapping and not vertical else 750), vertical)
                if not vertical and not cn.fills and node.align_items != STRETCH and cn.h == 0:  # in a row not told to stretch: its own height (a trail in a 60 pt bar stood 60 high)
                    hug(child, Float32(740), True)  # (740: at 750 a model page's head stood 81 high, run 40263008055; a column's 750 squeezed wrapping words)
                var wrapper = node.kind == DRAG or node.kind == DROP or node.kind == EMBED or node.kind == WEBCOMP  # (its one view across it: the web's align-items: stretch, D-494)
                var spans = vertical and (cn.kind == SCROLL or cn.kind == TABLE)  # (a Scroll spans its column: the web's .scroll { width: 100% }, D-502; a Table too: table.table { width: 100% })
                if not vertical and cn.kind == TABLE and not cn.grows:  # (in a row, a Table takes the row: its width 100 %, a side-scroll's flex: 1 0 auto)
                    hug(child, Float32(1), False)
                if vertical and (cn.kind == TEXT or cn.kind == PARAGRAPH) and look_at >= 0 and self.look.surfaces[look_at].block_flow:
                    # (words in block flow: a block as wide as the column up to their max width, from its leading edge: under
                    # the column's 250 leading pins they stretch; an equality pulled the cards to the words, D-529)
                    hug(self.widgets[c] if c < len(self.widgets) and self.widgets[c] != 0 else child, Float32(249), False)  # (the words, not a margin's holder)
                if vertical and (cn.kind == VSTACK or cn.kind == HSTACK) and len(cn.children) == 0 and cn.w == 0 and not cn.fills and node.align_items != STRETCH:
                    # (an empty view in a column is as wide as its content, nothing, as the web's: the column's 250
                    # leading pins stood a markdown gap 668 wide, D-541)
                    var nothing = msg(msg(child, "widthAnchor"), "constraintEqualToConstant:", Float64(0))
                    _ = msg(nothing, "setPriority:", Float32(251))
                    _ = msg(nothing, "setActive:", 1)
                if cn.fills or node.align_items == STRETCH or wrapper or spans:  # stretch across: match the stack minus its insets
                    var side = "widthAnchor" if vertical else "heightAnchor"
                    var inset = Float64(inset_x if vertical else inset_y)
                    var c2 = msg(msg(child, side), "constraintEqualToAnchor:constant:", msg(w, side), -inset)
                    if vertical and cn.max_w != 0:  # (up to its widest, centred: the web's max-width with auto margins, GTK's clamp)
                        _ = msg(c2, "setPriority:", Float32(495))
                        _ = msg(msg(msg(child, "centerXAnchor"), "constraintEqualToAnchor:", msg(w, "centerXAnchor")), "setActive:", 1)
                    _ = msg(c2, "setActive:", 1)
            if not vertical:  # a row's padding holds above and below its tallest view (centred, a stack keeps its insets only loosely)
                var ins = msg[CGRect](w, "edgeInsets")  # (top, left, bottom, right)
                if ins.x + ins.width > 0:
                    for v in built:
                        if v != 0:
                            var held = msg(msg(w, "heightAnchor"), "constraintGreaterThanOrEqualToAnchor:constant:", msg(v, "heightAnchor"), ins.x + ins.width)
                            if node.h > 0:  # (a row given its own height keeps it; a taller view stands out of it, as the web's overflow, D-559)
                                _ = msg(held, "setPriority:", Float32(742))
                            _ = msg(held, "setActive:", 1)
            if node.justify_items == BETWEEN and not vertical and len(built) == len(node.children) and len(built) > 1:
                # (a row's labels stretch across their share of it, their words centred: the first text reads from the
                # leading edge, the last from the trailing one, as GTK and the web push them to the ends; giving them
                # hugging either shrank the row or lost to its fill, D-5728)
                var first = node.children[0]
                var last = node.children[len(node.children) - 1]
                # (the label itself, never a padding or margin holder: those don't take setAlignment:)
                var first_w = self.widgets[first] if first < len(self.widgets) else 0
                var last_w = self.widgets[last] if last < len(self.widgets) else 0
                if self.rt.shown.nodes[first].kind == TEXT and first_w != 0:
                    _ = msg(first_w, "setAlignment:", 0)  # NSTextAlignmentLeft
                if self.rt.shown.nodes[last].kind == TEXT and last_w != 0:
                    _ = msg(last_w, "setAlignment:", 2)  # NSTextAlignmentRight (2 on Apple Silicon)
            if node.justify_items == CENTER and not grows and not spacers:
                var trail = flexible_spacer(vertical)
                _ = msg(w, "addArrangedSubview:", trail)
                var side = "heightAnchor" if vertical else "widthAnchor"
                _ = msg(msg(msg(trail, side), "constraintEqualToAnchor:", msg(lead, side)), "setActive:", 1)
            elif (node.justify_items == START or (node.justify_items == 0 and (vertical or node.fills))) and not grows and not spacers and not ended:
                # (a filled row's default too: the web's flex-start; without the room its lone label took the row, a
                # model's repo line 211 for 179, D-552)
                # its views from the start, the free room after them (a column's default too, as the web's flex-start):
                # stretched taller than its views, a column stood one of them as tall as the rest (an overview panel's
                # foot 133 high for 15, D-514); no spacing before that room
                var last = 0
                for b in built:
                    if b != 0:
                        last = b
                if last != 0:
                    _ = msg(w, "setCustomSpacing:afterView:", Float64(0), last)
                var room = flexible_spacer(vertical)
                _ = msg(w, "addArrangedSubview:", room)
                if vertical:  # (a column's own stacks keep their content's height, so the free room is the room's, as the
                    # web's flex-start: a stack has no size of its own, and the widgets app's header stood 155 high for its
                    # 64, D-668. 251: over the room's nothing, under a label's 750 resistance and a default's 480)
                    for q in range(len(node.children)):
                        ref cq = self.rt.shown.nodes[node.children[q]]
                        if built[q] != 0 and cq.kind == VSTACK and not cq.grows and cq.h == 0:
                            var fit = msg(msg(built[q], "heightAnchor"), "constraintEqualToConstant:", Float64(0))
                            _ = msg(fit, "setPriority:", Float32(251))
                            _ = msg(fit, "setActive:", 1)
                if not vertical and not (node.fills or (i < len(self.parents) and self.parents[i] >= 0 and self.rt.shown.nodes[self.parents[i]].align_items == STRETCH)):
                    # (a row nothing stretches has no free room: none at 251, over its column's 250 leading pins, so the row
                    # is its views wide, as a web flex row in a shrink-to-fit place: filter chips 940 for 220, D-539. Tried
                    # and not kept: a room after every row's views (a row's default justify too) at 251 or 485 + depth:
                    # labels hug at 250, so words took the room; runs 40340434761, 40343522058)
                    var none = msg(msg(room, "widthAnchor"), "constraintEqualToConstant:", Float64(0))  # (a spacer has no size of its own to hug)
                    _ = msg(none, "setPriority:", Float32(251))
                    _ = msg(none, "setActive:", 1)
            hold_insets(w, Float32(742) if node.kind == HSTACK and node.h > 0 else Float32(1000))  # (a row given a height: its views may stand out of it, D-559)
            if node.align_items == CENTER or node.align_items == 0:
                # centred between its insets, not in its whole bounds: NSStackView centres at 260 ('NSStackView.Align'),
                # so a header padded 10 above and 0 below had its words 5 pt high (D-517)
                var ins = msg[CGRect](w, "edgeInsets")  # (top, left, bottom, right)
                var shift = (ins.x - ins.width) / 2 if not vertical else (ins.y - ins.height) / 2
                if shift != 0:
                    var axis = "centerYAnchor" if not vertical else "centerXAnchor"
                    var views = msg(w, "arrangedSubviews")
                    for j in range(msg(views, "count")):
                        var v = msg(views, "objectAtIndex:", j)
                        var c = msg(msg(v, axis), "constraintEqualToAnchor:constant:", msg(w, axis), shift)
                        _ = msg(c, "setPriority:", Float32(270))
                        _ = msg(c, "setActive:", 1)
        if node.kind == WEBCOMP:  # its widget in a WKWebView of its own (kept across rebuilds), else `instead`
            self.place_webview(i, w, self_addr)
        if self.widgets[i] == 0:  # (some branches already stored an inner control)
            self.widgets[i] = w
        return self.apply_layout(i, w)

    def segment_track(mut self, i: Int, options: List[String], value: Int, self_addr: Int) -> Int:
        """A segmented control in the look's shape (GTK's toggle-group, the web's .segmented): a track of borderless
        buttons, the chosen one filled; a click sends the node's message with the segment's index (segmentPick:)."""
        ref sg = self.look.segments
        var track = new("NSStackView")
        _ = msg(track, "setOrientation:", 0)
        _ = msg(track, "setSpacing:", Float64(0))
        _ = msg(track, "setDistribution:", 1)  # NSStackViewDistributionFillEqually (GTK's homogeneous group)
        _ = msg(track, "setEdgeInsets:", Float64(sg.track_pad), Float64(sg.track_pad), Float64(sg.track_pad), Float64(sg.track_pad))
        _ = msg(track, "setWantsLayer:", 1)
        var layer = msg(track, "layer")
        if sg.track != 0:
            _ = msg(layer, "setBackgroundColor:", msg(ns_rgba(sg.track), "CGColor"))
        if sg.ring != 0:
            _ = msg(layer, "setBorderWidth:", Float64(1))
            _ = msg(layer, "setBorderColor:", msg(ns_color(sg.ring), "CGColor"))
        _ = msg(layer, "setCornerRadius:", Float64(min(sg.track_radius, (sg.h + 2 * sg.track_pad) // 2)))
        _ = msg(layer, "setMasksToBounds:", 0 if sg.on_shadow else 1)
        for j in range(len(options)):
            var b = msg(cls("NSButton"), "buttonWithTitle:target:action:", ns_string(options[j]), self.target, sel("segmentPick:"))
            _ = msg(b, "setBordered:", 0)
            _ = msg(b, "setTag:", tag_for(self_addr, i))
            _ = msg(b, "setWantsLayer:", 1)
            constrain(b, "heightAnchor", Float64(sg.h))
            self.style_segment(b, j == value)
            var fit = msg[CGPoint](b, "fittingSize")
            _ = msg(msg(msg(b, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", fit.x + Float64(2 * sg.pad)), "setActive:", 1)
            _ = msg(track, "addArrangedSubview:", b)
        constrain(track, "heightAnchor", Float64(sg.h + 2 * sg.track_pad))  # (in a row it came out 24 pt, its insets lost: GitHub's macOS 26)
        return track

    def style_segment(self, b: Int, on: Bool):
        """One segment, chosen or not: its fill, title colour and weight, corners, and the chosen one's soft shadow."""
        ref sg = self.look.segments
        var layer = msg(b, "layer")
        _ = msg(layer, "setCornerRadius:", Float64(min(sg.radius, sg.h // 2)))
        _ = msg(layer, "setBackgroundColor:", msg(ns_color(sg.on_fill) if on else msg(cls("NSColor"), "clearColor"), "CGColor"))
        _ = msg(layer, "setShadowOpacity:", Float32(0.12 if on and sg.on_shadow else 0.0))
        _ = msg(layer, "setShadowRadius:", Float64(1.5))
        _ = msg(layer, "setShadowOffset:", Float64(0), Float64(-1))
        var attrs = new("NSMutableDictionary")
        _ = msg(attrs, "setObject:forKey:", look_font(self.look.type.family, sg.on_weight if on else sg.weight, sg.font_size, self.look.type.tabular), ns_string("NSFont"))
        _ = msg(attrs, "setObject:forKey:", ns_color(sg.on_ink if on else sg.ink), ns_string("NSColor"))
        _ = msg(b, "setAttributedTitle:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", msg(b, "title"), attrs))
        _ = msg(b, "setState:", 1 if on else 0)

    def drawn_controls(self) -> Bool:
        """Push buttons, fields and dropdowns drawn from the look (its height, corners, hairline), not AppKit's bezels."""
        return self.skinned and self.look.controls.control_h > 0

    def shell(mut self, i: Int, control: Int) -> Int:
        """A field's or a dropdown's box, as GTK's and the web's: the look's height and corners, the card's fill, a hairline;
        the control sits inside it, borderless, the look's padding from its sides. Returns the box (what the layout places)."""
        var c = self.look.controls.copy()
        var box = new("NSView")
        _ = msg(box, "setWantsLayer:", 1)
        var layer = msg(box, "layer")
        _ = msg(layer, "setBackgroundColor:", msg(ns_color(self.pal.card), "CGColor"))
        _ = msg(layer, "setBorderWidth:", Float64(1))
        _ = msg(layer, "setBorderColor:", msg(ns_color(self.pal.line_strong), "CGColor"))
        _ = msg(layer, "setCornerRadius:", Float64(min(c.field_radius, c.control_h // 2)))
        _ = msg(control, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
        _ = msg(box, "addSubview:", control)
        _ = msg(msg(msg(control, "leadingAnchor"), "constraintEqualToAnchor:constant:", msg(box, "leadingAnchor"), Float64(c.field_pad)), "setActive:", 1)
        _ = msg(msg(msg(control, "trailingAnchor"), "constraintEqualToAnchor:constant:", msg(box, "trailingAnchor"), -Float64(c.field_pad)), "setActive:", 1)
        _ = msg(msg(msg(control, "centerYAnchor"), "constraintEqualToAnchor:", msg(box, "centerYAnchor")), "setActive:", 1)
        constrain(box, "heightAnchor", Float64(c.control_h))
        _ = msg(box, "setContentHuggingPriority:forOrientation:", Float32(250), 0)
        self.widgets[i] = control  # (patches and reads go to the control; the dump and the layout see the box)
        self.shells[i] = box
        return box

    def draw_tick(mut self, w: Int, k: Int, on: Bool):
        """A tick box drawn from the look's role k (its size, corners and ring; ticked: the accent with a white tick),
        not AppKit's 16 pt check box: a theme's 22 pt table box is 22 here too, as on GTK and the web (D-510)."""
        ref sf = self.look.surfaces[k]
        _ = msg(w, "setButtonType:", 1)  # NSButtonTypePushOnPushOff: it keeps its state; the app's update says the rest
        _ = msg(w, "setBordered:", 0)
        _ = msg(w, "setImage:", 0)
        _ = msg(w, "setWantsLayer:", 1)
        var layer = msg(w, "layer")
        _ = msg(layer, "setCornerRadius:", Float64(max(sf.radius_top, 0)))
        _ = msg(layer, "setBorderWidth:", Float64(0) if on else Float64(max(sf.outline_w, 1)) * 1.5)
        _ = msg(layer, "setBorderColor:", msg(ns_rgba(sf.outline), "CGColor"))
        _ = msg(layer, "setBackgroundColor:", msg(self.accent() if on else msg(cls("NSColor"), "clearColor"), "CGColor"))
        var attrs = new("NSMutableDictionary")
        _ = msg(attrs, "setObject:forKey:", look_font(self.look.type.family, 700, Float64(sf.width) * 0.6, False), ns_string("NSFont"))
        _ = msg(attrs, "setObject:forKey:", ns_color(self.pal.accent_ink), ns_string("NSColor"))
        _ = msg(w, "setAttributedTitle:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string("✓" if on else ""), attrs))
        _ = msg(w, "setState:", 1 if on else 0)
        for q in range(len(self.tick_boxes)):  # (sized once; a table's box takes the table's size: the same constraints)
            if self.tick_boxes[q] == w:
                self.tick_k[q] = k
                _ = msg(self.tick_cw[q], "setConstant:", Float64(sf.width))
                _ = msg(self.tick_ch[q], "setConstant:", Float64(sf.height))
                return
        var cw = msg(msg(w, "widthAnchor"), "constraintEqualToConstant:", Float64(sf.width))
        var ch = msg(msg(w, "heightAnchor"), "constraintEqualToConstant:", Float64(sf.height))
        _ = msg(cw, "setActive:", 1)
        _ = msg(ch, "setActive:", 1)
        self.tick_boxes.append(w)
        self.tick_k.append(k)
        self.tick_cw.append(cw)
        self.tick_ch.append(ch)

    def icon_spaced(self, w: Int, said: Int, k: Int) -> Int:
        """A role button's title as shown beside its icon: the role's gap between them (the web's 6 pt unless the role
        names one), where AppKit leaves only its own ~2 pt (the console's Restart, its tabs). A hair space kerned by the
        difference opens it (a word joiner's kern was dropped: run 40425105160); `said` (no joiner) stays what the width is measured from (D-552, D-561)."""
        if k < 0 or msg(w, "image") == 0 or msg(said, "length") == 0:
            return said
        var gap = Float64(self.look.surfaces[k].gap) if self.look.surfaces[k].gap >= 0 else Float64(6)
        var spaced = msg(msg(cls("NSMutableAttributedString"), "alloc"), "initWithString:attributes:", ns_string(ICON_GAP_MARK),
                         msg(said, "attributesAtIndex:effectiveRange:", 0, 0))
        var hair = msg[CGPoint](spaced, "size").x  # (the hair space's own width counts toward the gap)
        _ = msg(spaced, "addAttribute:value:range:", ns_string("NSKern"), msg(cls("NSNumber"), "numberWithDouble:", max(gap - APPKIT_IMAGE_GAP - hair, Float64(0))), 0, 1)
        _ = msg(spaced, "appendAttributedString:", said)
        return spaced

    def draw_button(mut self, w: Int, style: Int, title: String, i: Int = -1):
        """A push button in the look's shape: its fill, hairline and corners on a layer, its title in the look's family,
        the look's height and padding (GTK's `button`, the web's). A button wearing a role (node i's tag) takes the role's
        fill, corners, side padding, height at least, type and ink, as GTK's and the web's role rules do (D-445)."""
        var c = self.look.controls.copy()
        var fill = self.pal.card
        var ink = self.pal.ink
        var line = self.pal.line_strong
        var weight = c.button_weight if c.button_weight > 0 else 500
        if style == PROMINENT:
            fill, ink, line, weight = self.pal.accent, self.pal.accent_ink, UInt32(0), c.button_weight if c.button_weight > 0 else 600
        elif style == DESTRUCTIVE:
            fill, ink, line, weight = self.pal.bad, UInt32(0xFFFFFFFF), UInt32(0), c.button_weight if c.button_weight > 0 else 600
        elif style == SUBTLE:
            fill, ink, line = UInt32(0), self.pal.ink2, UInt32(0)
        var radius = min(c.button_radius, c.control_h // 2)
        var pad = c.button_pad
        var high = c.control_h
        var size = c.button_font if c.button_font > 0 else self.look.type.body
        var family = self.look.type.family
        var k = self.look.surface(self.rt.shown.nodes[i].name) if i >= 0 and self.rt.shown.nodes[i].name != "" else -1
        if k >= 0:
            ref sf = self.look.surfaces[k]
            if not text_only(sf):  # (a box rule: its own fill, or none)
                fill, line = sf.fill, sf.outline
                if sf.radius_top >= 0:
                    radius = sf.radius_top
                if sf.pad_top >= 0:
                    pad = sf.pad_x
                high = max(high, sf.min_height)
            if sf.font_size > 0:
                size = sf.font_size
            elif i >= 0 and self.inherited_size(i) > 0:  # (its words at the size around it, as the web's button { font: inherit })
                size = self.inherited_size(i)
            if sf.font_weight > 0:
                weight = sf.font_weight
            if sf.font != "":
                family = sf.font
            if sf.ink != 0:
                ink = sf.ink
        if i >= 0 and self.rt.shown.nodes[i].h > 0:  # (the app's height: exactly that, as GTK's mui-fixed-h and the web)
            high = self.rt.shown.nodes[i].h
        _ = msg(w, "setBordered:", 0)
        _ = msg(w, "setWantsLayer:", 1)
        var layer = msg(w, "layer")
        _ = msg(layer, "setBackgroundColor:", msg(ns_rgba(fill) if fill != 0 else msg(cls("NSColor"), "clearColor"), "CGColor"))
        if line != 0:
            _ = msg(layer, "setBorderWidth:", Float64(1))
            _ = msg(layer, "setBorderColor:", msg(ns_rgba(line), "CGColor"))
        _ = msg(layer, "setCornerRadius:", Float64(min(radius, high // 2)))
        var attrs = new("NSMutableDictionary")
        _ = msg(attrs, "setObject:forKey:", look_font(family, weight, size, self.look.type.tabular), ns_string("NSFont"))
        _ = msg(attrs, "setObject:forKey:", ns_rgba(ink), ns_string("NSColor"))
        if k >= 0 and self.look.surfaces[k].tracking != 0:  # (its letter spacing, as the web's: the brand's -.02em, D-509)
            _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", self.look.surfaces[k].tracking), ns_string("NSKern"))
        var said = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(title), attrs)
        _ = msg(w, "setAttributedTitle:", self.icon_spaced(w, said, k))
        _ = msg(w, "setContentTintColor:", ns_rgba(ink))
        var fit = msg[CGPoint](w, "fittingSize")
        var wraps = False  # (a role's words-only button with its line's height: its words wrap when squeezed, as the web's and GTK's, D-537)
        var line_h = Float64(0)
        if k >= 0:  # (a role's button: its words, an icon and its gap (the web's 6 pt unless the role says), the role's padding, as CSS measures it; a bare cell adds its own 6)
            var words = msg[CGPoint](said, "size")
            var glyph = self.look.surfaces[k].icon_size if self.look.surfaces[k].icon_size > 0 else (c.glyph if c.glyph > 0 else 16)
            var gap = Float64(self.look.surfaces[k].gap) if self.look.surfaces[k].gap >= 0 else Float64(6)  # (the role's own gap, as the web's: tag-add's + against its word, 79 for 73, D-552)
            fit.x = Float64(Int(words.x + 0.999)) + (Float64(glyph) + gap if msg(w, "image") != 0 else 0)
            ref hs = self.look.surfaces[k]
            if hs.height == -2 and (i < 0 or self.rt.shown.nodes[i].h == 0):  # HEIGHT_AUTO: its line and its padding, no control height (the web's
                # height: auto; min-height: 0: a sidebar row's name, a link in a table's cell, D-498)
                var line = Float64(hs.line_height) if hs.line_height > 0 else (size * self.look.type.line if hs.line_height == 0 and self.look.type.line > 0 else words.y)
                high = Int(line + 0.5) + max(hs.pad_top, 0) + max(hs.pad_bottom, 0)
                if not hs.one_line and msg(w, "image") == 0 and title.find(" ") >= 0:
                    wraps, line_h = True, line
                    var widest = Float64(0)
                    for word in title.split(" "):
                        var one = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(String(word)), attrs)
                        widest = max(widest, msg[CGPoint](one, "size").x)
                    fit.x = Float64(Int(widest + 0.999))  # (at least its widest word: below that it can't wrap)
                    var cell = msg(w, "cell")
                    _ = msg(cell, "setWraps:", 1)
                    _ = msg(cell, "setLineBreakMode:", 0)  # NSLineBreakByWordWrapping
                    if line > 0:  # (its lines at the line's height, as the web's)
                        var para = new("NSMutableParagraphStyle")
                        _ = msg(para, "setMinimumLineHeight:", line)
                        _ = msg(para, "setMaximumLineHeight:", line)
                        _ = msg(para, "setLineBreakMode:", 0)
                        _ = msg(para, "setAlignment:", 0 if i >= 0 and self.rt.shown.nodes[i].align_items == START else 1)
                        _ = msg(attrs, "setObject:forKey:", para, ns_string("NSParagraphStyle"))
                        said = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(title), attrs)
                        _ = msg(w, "setAttributedTitle:", self.icon_spaced(w, said, k))
        # its title's width is the least it takes and the width it prefers, not a fixed one: a filling button (an
        # inspector row's title) stretches, as on GTK and the web; held to its fit, it held the Report inspector's
        # column to 117 pt through the rows' equal widths (Mac, 2026-10-24)
        _ = msg(msg(msg(w, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", fit.x + Float64(2 * pad)), "setActive:", 1)
        if wraps:  # (it prefers its one line; fit_wraps gives it the lines its width needs)
            var one_line = Float64(Int(msg[CGPoint](said, "size").x + 0.999)) + Float64(2 * pad)
            prefer(w, "widthAnchor", one_line)
            # (and keeps it over a wrapping label's 490: it wraps only where its row can't give it room, a chapter in its
            # outline column, not a text action beside a head, which wrapped to 65 x 40 for 76 x 24, D-537)
            var keep = msg(msg(w, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", one_line)
            _ = msg(keep, "setPriority:", Float32(491))
            _ = msg(keep, "setActive:", 1)
        else:
            prefer(w, "widthAnchor", fit.x + Float64(2 * pad))
        if i < 0 or self.rt.shown.nodes[i].h == 0:  # (apply_layout pins the app's own height)
            var hc = msg(msg(w, "heightAnchor"), "constraintEqualToConstant:", Float64(high))
            _ = msg(hc, "setActive:", 1)
            if wraps:
                self.wrap_buttons.append((w, hc, line_h, Float64(high) - Float64(Int(line_h + 0.5)), Float64(2 * pad)))

    def box_inset(self, i: Int, name: String) -> Tuple[Int, Int]:
        """What a Board object's role box takes from its content's size: the role's padding, across and down."""
        var k = self.look.surface(name)
        if k < 0 or self.look.surfaces[k].pad_top < 0:
            return (0, 0)
        return (2 * self.look.surfaces[k].pad_x, self.look.surfaces[k].pad_top + self.look.surfaces[k].pad_bottom)

    def paint_surface(mut self, w: Int, k: Int, pad: Bool, pad_from: Int = -1):
        """A look's surface on a stack's layer (mojoui/look.mojo; GTK and the web write the same values as CSS): its fill,
        corners (top and bottom apart), its rim as the layer's border, its widest shadow as the layer's shadow (a layer
        has one), hairlines along its edges, its padding unless the component set its own (as on the web, where the
        view's own padding wins over the sheet's)."""
        var sf = self.look.surfaces[k].copy()
        if pad_from >= 0:  # (its padding and hairlines from another role worn over it: a dense table's cells, D-493)
            ref o = self.look.surfaces[pad_from]
            sf.pad_top, sf.pad_bottom, sf.pad_x, sf.pad_left, sf.pad_right = o.pad_top, o.pad_bottom, o.pad_x, o.pad_left, o.pad_right
            if o.line_bottom != 0:
                sf.line_bottom = o.line_bottom
            if o.line_top != 0:
                sf.line_top = o.line_top
        _ = msg(w, "setWantsLayer:", 1)
        var layer = msg(w, "layer")
        _ = msg(layer, "setBackgroundColor:", msg(ns_rgba(sf.fill) if sf.fill != 0 else msg(cls("NSColor"), "clearColor"), "CGColor"))
        var flipped = (msg(w, "isFlipped") & 0xFF) != 0
        var radius = max(sf.radius_top, sf.radius_bottom)
        if radius > 0:
            _ = msg(layer, "setCornerRadius:", Float64(radius))
            if radius > 6:  # (a pill's or a dot's 999: half its size once it's laid out, as CSS clamps it)
                self.rounds.append((w, radius))
            if sf.radius_top != sf.radius_bottom:  # kCALayer{MinX,MaxX}{MinY,MaxY}Corner: MaxY is the top unless the view is flipped
                var top = 12 if not flipped else 3
                var bottom = 3 if not flipped else 12
                _ = msg(layer, "setMaskedCorners:", (top if sf.radius_top > 0 else 0) | (bottom if sf.radius_bottom > 0 else 0))
        var blur = -1
        for sh in sf.shadows:
            if sh.inset and not (sh.blur == 0 and sh.spread > 0):  # (a highlight inside the top edge: no layer equivalent)
                continue
            if sh.blur == 0 and sh.spread > 0:  # a ring (outside or inside the edge): the layer's border
                _ = msg(layer, "setBorderWidth:", Float64(sh.spread))
                _ = msg(layer, "setBorderColor:", msg(ns_rgba(sh.color), "CGColor"))
            elif sh.blur > blur:
                blur = sh.blur
                _ = msg(layer, "setShadowColor:", msg(ns_color(sh.color), "CGColor"))
                _ = msg(layer, "setShadowOpacity:", Float32(Float64(Int((sh.color >> 24) & 255)) / 255.0))
                _ = msg(layer, "setShadowRadius:", Float64(sh.blur) / 2.0)  # (CSS blur is about twice a layer's radius)
                _ = msg(layer, "setShadowOffset:", Float64(0), Float64(sh.y) if flipped else -Float64(sh.y))
        if blur >= 0:
            _ = msg(layer, "setMasksToBounds:", 0)
        for edge in range(2):
            var color = sf.line_top if edge == 0 else sf.line_bottom
            if color == 0:
                continue
            var line = new("NSView")
            _ = msg(line, "setWantsLayer:", 1)
            _ = msg(msg(line, "layer"), "setBackgroundColor:", msg(ns_rgba(color), "CGColor"))
            _ = msg(line, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            _ = msg(w, "addSubview:", line)
            for anchor in [String("leadingAnchor"), String("trailingAnchor"), String("topAnchor") if edge == 0 else String("bottomAnchor")]:
                _ = msg(msg(msg(line, anchor), "constraintEqualToAnchor:", msg(w, anchor)), "setActive:", 1)
            constrain(line, "heightAnchor", Float64(1))
        if sf.outline != 0 and not sf.dashed:
            _ = msg(layer, "setBorderWidth:", Float64(sf.outline_w))
            _ = msg(layer, "setBorderColor:", msg(ns_rgba(sf.outline), "CGColor"))
        elif sf.outline != 0:  # dashes: a shape layer whose path follows the view's size (dash_paths, after each layout)
            var shape = new("CAShapeLayer")
            _ = msg(shape, "setStrokeColor:", msg(ns_rgba(sf.outline), "CGColor"))
            _ = msg(shape, "setFillColor:", msg(msg(cls("NSColor"), "clearColor"), "CGColor"))
            _ = msg(shape, "setLineWidth:", Float64(sf.outline_w))
            var pattern = new("NSMutableArray")
            _ = msg(pattern, "addObject:", ns_number(6))
            _ = msg(pattern, "addObject:", ns_number(4))
            _ = msg(shape, "setLineDashPattern:", pattern)
            _ = msg(layer, "addSublayer:", shape)
            self.dashes.append((w, shape, max(sf.radius_top, 0), sf.outline_w))
        if pad and sf.pad_top >= 0:  # (leading and trailing apart when the role says so: the page frame's 2 | 14, D-499)
            _ = msg(w, "setEdgeInsets:", Float64(sf.pad_top), Float64(sf.pad_left if sf.pad_left >= 0 else sf.pad_x), Float64(sf.pad_bottom),
                    Float64(sf.pad_right if sf.pad_right >= 0 else sf.pad_x))
        if sf.min_height > 0:
            _ = msg(msg(msg(w, "heightAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(sf.min_height)), "setActive:", 1)

    def ancestor_role(self, i: Int, field: Int) -> Int:
        """The nearest role above node i that sets a type field its words inherit, as CSS's inherited properties
        (0: font_size, 1: line_height, 2: font, 3: ink); -1: none."""
        var p = self.parents[i] if i < len(self.parents) else -1
        while p >= 0:
            ref n = self.rt.shown.nodes[p]
            if n.name != "":
                var k = self.look.surface(n.name)
                if k >= 0:
                    ref sf = self.look.surfaces[k]
                    if (field == 0 and sf.font_size > 0) or (field == 1 and sf.line_height != 0) or (field == 2 and sf.font != "") or (field == 3 and sf.ink != 0):
                        return k
            p = self.parents[p] if p < len(self.parents) else -1
        return -1

    def inherited_size(self, i: Int) -> Float64:
        """The type size node i's words inherit, as CSS's font-size does: its own role's, else the nearest role above it
        with a size, a table's cells their head's or cell's (a label tagged mono in a table cell was the body's 14 pt for
        the cell's 12.88, 2 pt taller and wider; a name link 90 wide for 83, D-516). 0: none."""
        if self.rt.shown.nodes[i].name != "":
            var own = self.look.surface(self.rt.shown.nodes[i].name)
            if own >= 0 and self.look.surfaces[own].font_size > 0:
                return self.look.surfaces[own].font_size
        var c = i
        var p = self.parents[i] if i < len(self.parents) else -1
        while p >= 0:
            ref n = self.rt.shown.nodes[p]
            if n.kind == TABLE:
                var row = 0
                for q in range(len(n.children)):
                    if n.children[q] == c:
                        row = q // max(n.value, 1)
                var k = self.look.surface("table-head" if row == 0 else "table-cell")
                if k >= 0 and self.look.surfaces[k].font_size > 0:
                    return self.look.surfaces[k].font_size
            elif n.name != "":
                var k = self.look.surface(n.name)
                if k >= 0 and self.look.surfaces[k].font_size > 0:
                    return self.look.surfaces[k].font_size
            c = p
            p = self.parents[p] if p < len(self.parents) else -1
        return 0

    def text_look(self, i: Int) -> Int:
        """The surface whose text a label at node i wears (its own role, else the nearest tagged stack above it with a font,
        size or ink), -1 if none."""
        if self.rt.shown.nodes[i].name != "":
            var own = self.look.surface(self.rt.shown.nodes[i].name)
            if own >= 0 and (self.look.surfaces[own].font != "" or self.look.surfaces[own].font_size > 0 or self.look.surfaces[own].ink != 0
                             or self.look.surfaces[own].font_weight > 0):
                return own
        var p = self.parents[i] if i < len(self.parents) else -1
        while p >= 0:
            ref n = self.rt.shown.nodes[p]
            if n.name != "":
                var k = self.look.surface(n.name)
                if k >= 0 and (self.look.surfaces[k].font != "" or self.look.surfaces[k].font_size > 0 or self.look.surfaces[k].ink != 0
                               or self.look.surfaces[k].font_weight > 0):
                    return k
            p = self.parents[p] if p < len(self.parents) else -1
        return -1

    def apply_layout(mut self, i: Int, w: Int) -> Int:
        """Maps node i's own sizes (and, for non-stacks, padding) onto Auto Layout; returns what goes in the parent."""
        var node = self.rt.shown.nodes[i].copy()
        var outer = w
        if node.tip != "":
            _ = msg(w, "setToolTip:", ns_string(node.tip))
        var spoken = explicit_name(node)  # (mojoui.a11y: what VoiceOver says when the control's own words don't)
        if spoken != "":
            _ = msg(self.widgets[i] if self.widgets[i] != 0 else w, "setAccessibilityLabel:", ns_string(spoken))
        var is_stack = node.kind == VSTACK or node.kind == HSTACK
        if (node.pad_v != 0 or node.pad_h != 0) and not is_stack:  # wrap a leaf in a padded stack
            outer = new("NSStackView")
            _ = msg(outer, "setEdgeInsets:", Float64(node.pad_v), Float64(node.pad_h), Float64(node.pad_v), Float64(node.pad_h))
            _ = msg(outer, "addArrangedSubview:", w)
        var chip_at = self.look.surface(node.name) if node.name != "" and not is_stack and node.kind == TEXT else -1
        if chip_at >= 0 and (self.look.surfaces[chip_at].fill != 0 or len(self.look.surfaces[chip_at].shadows) > 0
                             or self.look.surfaces[chip_at].pad_top > 0 or self.look.surfaces[chip_at].pad_x > 0 or self.look.surfaces[chip_at].pad_bottom > 0
                             or self.look.surfaces[chip_at].line_bottom != 0 or self.look.surfaces[chip_at].line_top != 0):  # (or its padding, its rules: a group head's)
            # a label wearing a shaped role (a KPI's note chip): the shape around it, the role's padding inside
            if outer == w:
                outer = new("NSStackView")
                _ = msg(outer, "addArrangedSubview:", w)
            for orientation in range(2):  # (the shape hugs its words and padding, as the label would)
                hug(outer, Float32(750), orientation == 1)
            self.paint_surface(outer, chip_at, node.pad_v == 0 and node.pad_h == 0)
            hold_insets(outer, Float32(742) if node.kind == HSTACK and node.h > 0 else Float32(1000))  # (its padding, required: painted after hug() read no insets, so a caps head lost its 4 | 8, D-515; a row given a height lets a taller view stand out of it, D-559)
            var r = max(self.look.surfaces[chip_at].radius_top, 0)
            if r >= 999:  # (a pill: half its height, which a layer can't say ahead of the layout)
                _ = msg(msg(outer, "layer"), "setCornerRadius:", Float64(10))
            if i < len(self.shells):
                self.shells[i] = outer
        if i < len(self.sized):
            self.sized[i] = (node.w, node.h, node.min_w, node.max_w)
        var inset = self.box_inset(i, node.name) if i == self.boxed else (0, 0)  # (a boxed Board child fills its box's inside)
        if node.w != 0:
            var cw = msg(msg(outer, "widthAnchor"), "constraintEqualToConstant:", Float64(node.w - inset[0]))
            _ = msg(cw, "setActive:", 1)
            if i < len(self.size_w):
                self.size_w[i] = cw
        if node.h != 0:
            var ch = msg(msg(outer, "heightAnchor"), "constraintEqualToConstant:", Float64(node.h - inset[1]))
            if is_stack and len(node.children) > 0:  # (a stack given a height holds it unless its content needs more: GTK's minimum; squeezed, its words went to 0 pt)
                _ = msg(ch, "setPriority:", Float32(745))
                # at least that, required (GTK's size request): at 745 alone the stack around it hugged it smaller (its
                # hugging is 750: the console's 60 pt app bar stood 46 high, run 40286965370, D-500)
                _ = msg(msg(msg(outer, "heightAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(node.h - inset[1])), "setActive:", 1)
                if node.kind == HSTACK and (msg(w, "isKindOfClass:", cls("NSStackView")) & 0xFF) != 0:
                    # a row keeps the height it was given and lets a taller view stand out of it, as the web's flex row
                    # (overflow visible): NSStackView resists clipping its views at 1000 and grew omxplorer's 38 pt app
                    # bar to hold its 40 pt island (44, goal 32 M2). Below the height's 745, above a row child's 740 (D-559)
                    _ = msg(w, "setClippingResistancePriority:forOrientation:", Float32(742), 1)
            _ = msg(ch, "setActive:", 1)
            if i < len(self.size_h):
                self.size_h[i] = ch
        if node.min_w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(node.min_w)), "setActive:", 1)
        if node.max_w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintLessThanOrEqualToConstant:", Float64(node.max_w)), "setActive:", 1)
            if node.kind == TEXT:  # labels are single-line by default: let it wrap within the width
                _ = msg(w, "setMaximumNumberOfLines:", 0)
                _ = msg(w, "setLineBreakMode:", 0)  # word wrapping
                _ = msg(w, "setPreferredMaxLayoutWidth:", Float64(node.max_w - 2 * node.pad_h))
        var look_at = self.look.surface(node.name) if node.name != "" and is_stack else -1
        if look_at >= 0 and self.look.surfaces[look_at].max_chars > 0:  # a measured box (md-ul): at most its measure, as the web's max-width in ch (D-526)
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintLessThanOrEqualToConstant:", self.measure_of(look_at)), "setActive:", 1)
        var words_at = self.look.surface(node.name) if node.name != "" and (node.kind == TEXT or node.kind == PARAGRAPH) else -1
        if words_at >= 0 and self.look.surfaces[words_at].margin_top >= 0:  # (words with a margin of their own, a note's 10 above it in a flowing body, D-534)
            look_at = words_at
        if look_at >= 0 and self.look.surfaces[look_at].margin_top >= 0:  # the look's margin: the surface floats inside a holder
            ref sf = self.look.surfaces[look_at]
            var holder = new("NSView")
            _ = msg(outer, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            _ = msg(holder, "addSubview:", outer)
            _ = msg(msg(msg(outer, "topAnchor"), "constraintEqualToAnchor:constant:", msg(holder, "topAnchor"), Float64(sf.margin_top)), "setActive:", 1)
            _ = msg(msg(msg(outer, "bottomAnchor"), "constraintEqualToAnchor:constant:", msg(holder, "bottomAnchor"), -Float64(sf.margin_bottom)), "setActive:", 1)
            _ = msg(msg(msg(outer, "leadingAnchor"), "constraintEqualToAnchor:constant:", msg(holder, "leadingAnchor"), Float64(sf.margin_x)), "setActive:", 1)
            _ = msg(msg(msg(outer, "trailingAnchor"), "constraintEqualToAnchor:constant:", msg(holder, "trailingAnchor"), -Float64(sf.margin_x)), "setActive:", 1)
            outer = holder
        return outer

    def show(mut self, self_addr: Int):
        # Old controls are deliberately never released: that keeps a control alive
        # while its window content is replaced in the middle of its own action.
        # (Adding `release` later means delaying it until the handler returns.)
        if self.popover != 0:  # the previous screen's popover or context menu goes with it
            var old = self.popover
            self.popover = 0
            self.popover_node = -1
            _ = msg(old, "close")
        if self.sheet != 0:
            var old_sheet = self.sheet
            self.sheet = 0
            self.sheet_node = -1
            _ = msg(self.window, "endSheet:", old_sheet)
            _ = msg(old_sheet, "orderOut:", 0)
        self.widgets = List[Int](length=len(self.rt.shown.nodes), fill=0)  # 0 = nil: patches become no-ops
        self.shells = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.objects = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.dashes = List[Tuple[Int, Int, Int, Int]]()
        self.rounds = List[Tuple[Int, Int]]()
        self.tcells = List[Tuple[Int, Int, Int, Int, Int]]()
        self.tick_boxes = List[Int]()
        self.tick_k = List[Int]()
        self.tick_cw = List[Int]()
        self.tick_ch = List[Int]()
        self.size_w = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.wraps = List[Int]()
        self.wrap_buttons = List[Tuple[Int, Int, Float64, Float64, Float64]]()
        self.wrap_keeps = List[Int]()
        self.parents = List[Int](length=len(self.rt.shown.nodes), fill=-1)
        for k in range(len(self.rt.shown.nodes)):
            var kk = self.rt.shown.nodes[k].kind
            if kk == HSTACK or kk == VSTACK or kk == TABLE or kk == DRAG or kk == DROP or kk == EMBED or kk == WEBCOMP:  # (a table's cells and a
                for c in self.rt.shown.nodes[k].children:  # wrapper's view: their words inherit through them too, D-516)
                    self.parents[c] = k
        self.size_h = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.sized = List[Tuple[Int, Int, Int, Int]](length=len(self.rt.shown.nodes), fill=(0, 0, 0, 0))
        self.finish_gpu2d(0)  # (frames still on the GPU complete before their IOSurfaces go)
        for ref c in self.canvases:
            c.drop_surfaces()
        self.canvases = List[AppleCanvas]()
        if self.link != 0:
            _ = msg(self.link, "invalidate")
            self.link = 0
        var theme = self.rt.app.theme()
        if theme.key() != self.theme_key:  # Settings → Appearance: the skin switches live (D-156)
            self.theme_key = theme.key()
            self.pal = theme.palette.copy()
            self.skinned = theme.paint_native
            self.look = theme.look.copy()
        if self.skinned and self.window != 0:
            _ = msg(self.window, "setBackgroundColor:", ns_color(self.pal.page))
            _ = msg(self.window, "setAppearance:", msg(cls("NSAppearance"), "appearanceNamed:", ns_string("NSAppearanceNameDarkAqua" if self.pal.dark else "NSAppearanceNameAqua")))
        self.has_menubar = False
        if len(self.rt.shown.nodes) >= (1 << NODE_BITS):
            var note = msg(cls("NSTextField"), "labelWithString:", ns_string("Too many items to show (limit 65,535)."))
            _ = msg(self.window, "setContentView:", note)  # no stale controls left to use
            return
        var root = self.build(0, self_addr)
        if not self.has_menubar:
            make_menu(msg(cls("NSApplication"), "sharedApplication"), self.rt.app.title())
        if self.toast != 0 and not self.toast_claimed:  # the new screen has no toast: the old one goes
            _ = msg(self.toast, "removeFromSuperview")
            self.toast = 0
            self.toast_text = ""
        self.toast_claimed = False
        _ = msg(root, "setWantsLayer:", 1)  # an opaque page under everything: without it, a label's old text stayed on screen under its new text (Mac, 2026-10-22)
        if self.skinned:
            _ = msg(msg(root, "layer"), "setBackgroundColor:", msg(ns_color(self.pal.page), "CGColor"))
        else:
            _ = msg(msg(root, "layer"), "setBackgroundColor:", msg(msg(cls("NSColor"), "windowBackgroundColor"), "CGColor"))
        if self.rt.shown.nodes[0].grows or self.rt.shown.nodes[0].fills:  # the screen fills the window
            # in a page that scrolls: a screen taller than the window scrolls, as the web's page does, instead of its
            # words being squeezed to nothing (GTK's page scroller; D-440); across, it is the window's width
            var page = top_scroll_view(False)
            _ = msg(page, "setDrawsBackground:", 0)
            _ = msg(root, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            _ = msg(page, "setDocumentView:", root)
            var clip = msg(page, "contentView")
            for anchor in ["topAnchor", "leadingAnchor", "widthAnchor"]:
                _ = msg(msg(msg(root, anchor), "constraintEqualToAnchor:", msg(clip, anchor)), "setActive:", 1)
            _ = msg(msg(msg(root, "heightAnchor"), "constraintGreaterThanOrEqualToAnchor:", msg(clip, "heightAnchor")), "setActive:", 1)
            var fill = msg(msg(root, "heightAnchor"), "constraintEqualToAnchor:", msg(clip, "heightAnchor"))
            _ = msg(fill, "setPriority:", Float32(490))  # (fills a short screen; a taller one's words hold at 750)
            _ = msg(fill, "setActive:", 1)
            _ = msg(self.window, "setContentView:", page)
        else:
            var holder = new("NSStackView")  # centres the app's root in the window
            _ = msg(holder, "setOrientation:", 1)
            _ = msg(holder, "setAlignment:", 9)
            _ = msg(holder, "setEdgeInsets:", Float64(32), Float64(32), Float64(32), Float64(32))
            _ = msg(holder, "addArrangedSubview:", root)
            _ = msg(self.window, "setContentView:", holder)
        self.attach_toast()
        self.fit_tables()
        self.fit_wraps()
        self.dash_paths()
        self.start_frames()
        if 0 <= self.focus < len(self.widgets) and self.rt.shown.nodes[self.focus].kind == FIELD:
            # Keep typing in the new field, on the next run-loop turn (after AppKit has
            # finished ending the old field's edit), with the cursor at the end.
            _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("focusField:"), self.widgets[self.focus], Float64(0))
        self.focus = -1
        self.add_debug_menu(self_addr)
        self.sync_webviews(self_addr)

    def follow_ends(mut self):
        """Pinned Scrolls (a log) to their end after a change (its content may have grown). Unlike GTK and the web, it
        doesn't yet notice the person scrolled up to read (unverified on a Mac)."""
        var keep = List[Int]()
        for i in self.pinned:
            if i < len(self.widgets) and i < len(self.rt.shown.nodes) and self.rt.shown.nodes[i].kind == SCROLL and self.rt.shown.nodes[i].value == 1 and self.widgets[i] != 0:
                var doc = msg(self.widgets[i], "documentView")
                if doc != 0:
                    _ = msg(doc, "layoutSubtreeIfNeeded")
                    _ = msg(doc, "scrollPoint:", Float64(0), msg[CGRect](doc, "frame").height)  # (the clip counts y from the top)
                if i not in keep:
                    keep.append(i)
        self.pinned = keep^

    def copy_if_asked(mut self):
        """A Clipboard view whose version moved on: its text goes on the general pasteboard as plain text."""
        for ref n in self.rt.shown.nodes:
            if n.kind == CLIPBOARD and n.value > 0 and n.value != self.clip_version:
                self.clip_version = n.value
                var board = msg(cls("NSPasteboard"), "generalPasteboard")
                _ = msg(board, "clearContents")
                _ = msg(board, "setString:forType:", ns_string(n.text), ns_string("public.utf8-plain-text"))

    def open_if_asked(mut self):
        """A WebFrame whose version moved on: its page opens in the browser (NSWorkspace openURL:)."""
        for ref n in self.rt.shown.nodes:
            if n.kind == EMBED and n.value > 0 and n.value != self.embed_version:
                self.embed_version = n.value
                var url = n.hint if n.hint != "" else n.text
                if is_web_url(url):  # (http and https only, D-576)
                    _ = msg(msg(cls("NSWorkspace"), "sharedWorkspace"), "openURL:", msg(cls("NSURL"), "URLWithString:", ns_string(url)))

    def schedule_effects(mut self, self_addr: Int):
        """One delayed call (effectsDue:) for when the runtime next has a reply or a tick to hand over (Runtime.wake_in);
        an earlier need cancels a later one."""
        var now = now_ns() // 1000
        var w = self.rt.wake_in(now)
        if w < 0 or (self.fx_due >= 0 and self.fx_due <= now + w):
            return
        if self.fx_due >= 0:
            _ = msg(cls("NSObject"), "cancelPreviousPerformRequestsWithTarget:selector:object:", self.target, sel("effectsDue:"), ns_number(self_addr))
        self.fx_due = now + w
        _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("effectsDue:"), ns_number(self_addr), Float64(w) / 1e6)

    def apply(mut self, d: Diff, self_addr: Int):
        self.schedule_effects(self_addr)  # (every event comes through here: what it asked for gets its poll)
        self.copy_if_asked()
        self.open_if_asked()
        self.follow_ends()
        if self.window != 0 and self.rt.app.theme().key() != self.theme_key:
            # the theme switched (light/dark, a skin) with or without new views: native views and drawn canvases carry
            # its colours, so the screen is built again (the widgets' views are kept and get the new tokens, D-673)
            self.queue_snapshot(self_addr)
            self.rebuilds += 1
            self.show(self_addr)
            return
        if d.rebuild or len(d.patches) > 0:
            self.queue_snapshot(self_addr)
        if d.rebuild and self.resize_in_place(d):
            self.resized_in_place += 1
        elif d.rebuild:
            self.rebuilds += 1
            self.show(self_addr)
            return
        for p in d.patches:
            var w = self.widgets[p.node]
            var kind = self.rt.shown.nodes[p.node].kind
            if kind == WEBCOMP:  # (new props: sync_webviews hands them to its page)
                continue
            if p.op == SET_TEXT and kind != TEXTAREA and kind != DATE and kind != NAVBAR:
                if kind == TEXT:  # (in the words' own attributes: the look's line height, letter spacing)
                    var had = msg(w, "attributedStringValue")
                    if had != 0 and msg(had, "length") > 0:
                        var attrs = msg(had, "attributesAtIndex:effectiveRange:", 0, 0)
                        var words = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(self.label_text(p.node, p.text)), attrs)
                        self.set_label(w, had, words)
                        _ = msg(words, "release")  # (the field keeps its own copy: one leaked a string per change, e.g. a zoom label's every frame)
                    else:
                        _ = msg(w, "setStringValue:", ns_string(self.label_text(p.node, p.text)))
                elif kind == FIELD:
                    if from_ns(msg(w, "stringValue")) != p.text:  # don't fight the typist
                        _ = msg(w, "setStringValue:", ns_string(p.text))
                else:  # buttons and checkboxes (a drawn button's title keeps its type and ink)
                    var had = msg(w, "attributedTitle") if kind == BUTTON else 0
                    if had != 0 and msg(had, "length") > 0:
                        var attrs = msg(had, "attributesAtIndex:effectiveRange:", msg(had, "length") - 1, 0)  # (its words' own, not an icon gap's joiner, D-561)
                        var role = self.look.surface(self.rt.shown.nodes[p.node].name) if self.rt.shown.nodes[p.node].name != "" and from_ns(msg(had, "string")).startswith(ICON_GAP_MARK) else -1
                        _ = msg(w, "setAttributedTitle:", self.icon_spaced(w, msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(p.text), attrs), role))
                    else:
                        _ = msg(w, "setTitle:", ns_string(p.text))
            elif p.op == SET_VALUE:
                if kind == TOGGLE:
                    _ = msg(w, "setState:", p.number)
                    for q in range(len(self.tick_boxes)):  # (a drawn tick box: its fill and tick again)
                        if self.tick_boxes[q] == w:
                            self.draw_tick(w, self.tick_k[q], p.number != 0)
                elif kind == DROPDOWN:
                    _ = msg(w, "selectItemAtIndex:", p.number)
                elif kind == SLIDER or kind == PROGRESS:
                    _ = msg(w, "setDoubleValue:", Float64(p.number))
            elif p.op == SET_VALUE and (kind == SEGMENTED or kind == TABS):
                if (msg(w, "isKindOfClass:", cls("NSSegmentedControl")) & 0xFF) != 0:
                    _ = msg(w, "setSelectedSegment:", p.number)
                else:  # (the look's track: restyle its buttons)
                    var buttons = msg(w, "arrangedSubviews")
                    for j in range(msg(buttons, "count")):
                        self.style_segment(msg(buttons, "objectAtIndex:", j), j == p.number)
            elif p.op == SET_VALUE and kind == RADIO:
                var buttons = msg(w, "arrangedSubviews")
                for j in range(msg(buttons, "count")):
                    _ = msg(msg(buttons, "objectAtIndex:", j), "setState:", 1 if j == p.number else 0)
            elif p.op == SET_TEXT and kind == TEXTAREA:
                if from_ns(msg(w, "string")) != p.text:  # don't fight the typist
                    _ = msg(w, "setString:", ns_string(p.text))
            elif p.op == SET_TEXT and kind == DATE:
                if date_text(msg(w, "dateValue")) != p.text:  # don't fight someone mid-edit
                    _ = msg(w, "setDateValue:", ns_date(p.text))
            elif p.op == SET_TEXT and kind == NAVBAR:
                var views = msg(w, "arrangedSubviews")
                _ = msg(msg(views, "lastObject"), "setStringValue:", ns_string(p.text))
            elif p.op == SET_IMAGE:
                ref img = self.rt.shown.nodes[p.node]
                _ = msg(w, "setImage:", ns_image(img.pixels, img.spacing, img.size))
            elif p.op == SET_PLACE and w != 0:  # a Board child moved or resized
                ref moved = self.rt.shown.nodes[p.node]
                var box = self.objects[p.node] if p.node < len(self.objects) else 0
                if box != 0:  # (an object in its role's box: the box moves, the content keeps its place inside)
                    _ = msg(box, "setFrame:", Float64(moved.x), Float64(moved.y), Float64(moved.w), Float64(moved.h))
                else:
                    _ = msg(w, "setFrame:", Float64(moved.x), Float64(moved.y), Float64(moved.w), Float64(moved.h))
            # SET_MSG needs nothing: events look the message up in rt.shown.
        # Ask for the visible rows of every long list again: row text isn't part of the view.
        for k in range(len(self.rt.shown.nodes)):
            if self.rt.shown.nodes[k].kind == LAZYLIST and self.widgets[k] != 0:
                _ = msg(self.widgets[k], "reloadData")
        self.sync_webviews(self_addr)
        self.wake()

    def attach_toast(self):
        """The toast floats over the window's content, near its bottom. Attached once the new screen is the content: built
        into the old content, it went with it (the toast never showed on the Mac, 2026-10-23)."""
        if self.toast == 0 or self.window == 0:
            return
        var content = msg(self.window, "contentView")
        if content == 0 or msg(self.toast, "superview") == content:
            return
        _ = msg(self.toast, "removeFromSuperview")
        _ = msg(content, "addSubview:positioned:relativeTo:", self.toast, 1, 0)  # NSWindowAbove: over everything
        _ = msg(msg(msg(self.toast, "centerXAnchor"), "constraintEqualToAnchor:", msg(content, "centerXAnchor")), "setActive:", 1)
        _ = msg(msg(msg(self.toast, "bottomAnchor"), "constraintEqualToAnchor:constant:", msg(content, "bottomAnchor"), Float64(-24)), "setActive:", 1)

    def in_row(self, i: Int) -> Bool:
        """Whether node i sits in an HStack."""
        return i < len(self.parents) and self.parents[i] >= 0 and self.rt.shown.nodes[self.parents[i]].kind == HSTACK

    def measure_of(self, role: Int) -> Float64:
        """A role's measure (Surface.max_chars) in points: that many "0"s of the role's own font, as CSS's ch."""
        ref sf = self.look.surfaces[role]
        var size = sf.font_size if sf.font_size > 0 else (self.look.type.body if self.skinned else Float64(13))
        var font = look_font(sf.font if sf.font != "" else self.look.type.family, sf.font_weight if sf.font_weight > 0 else 400, size, self.look.type.tabular)
        var attrs = new("NSMutableDictionary")
        _ = msg(attrs, "setObject:forKey:", font, ns_string("NSFont"))
        var zero = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string("0"), attrs)
        return msg[CGPoint](zero, "size").x * Float64(sf.max_chars)

    def paragraph_string(self, i: Int) -> Int:
        """A Paragraph's runs as one attributed string: the paragraph's role gives the type and line height, each run's
        role its own (font, size, weight, ink, a fill behind it); bold, italic (slanted: Geist has no italic face, as the
        browser synthesises it), mono for code, a link underlined."""
        ref node = self.rt.shown.nodes[i]
        var family = self.look.type.family
        var size = self.look.type.body if self.skinned else Float64(13)
        var weight = 400
        var ink = self.pal.ink2 if self.skinned else UInt32(0)
        var lh = size * self.look.type.line if self.skinned else Float64(0)
        var tracking = Float64(0)
        var own = self.look.surface(node.name) if node.name != "" else -1
        # (what its role doesn't set it inherits from the roles around it, as CSS's font and line-height: a card foot's
        # words wear the foot's 11.5 mono and its font-own line, D-531)
        var up_size, up_line, up_font, up_ink = self.ancestor_role(i, 0), self.ancestor_role(i, 1), self.ancestor_role(i, 2), self.ancestor_role(i, 3)
        if up_font >= 0:
            family = self.look.surfaces[up_font].font
        if up_size >= 0:
            size = self.look.surfaces[up_size].font_size
            lh = size * self.look.type.line if self.skinned else Float64(0)
        if up_ink >= 0:
            ink = self.look.surfaces[up_ink].ink
        if up_line >= 0:
            var ul = self.look.surfaces[up_line].line_height
            lh = ul if ul > 0 else Float64(0)
        if own >= 0:
            ref sf = self.look.surfaces[own]
            family = sf.font if sf.font != "" else family
            size = sf.font_size if sf.font_size > 0 else size
            weight = sf.font_weight if sf.font_weight > 0 else weight
            ink = sf.ink if sf.ink != 0 else ink
            if sf.line_height != 0 or sf.font_size > 0:  # (below 0: the font's own line, as a label's, D-509, D-529; none: as inherited)
                lh = sf.line_height if sf.line_height > 0 else (Float64(0) if sf.line_height < 0 or (up_line >= 0 and self.look.surfaces[up_line].line_height < 0) else size * self.look.type.line)
            tracking = sf.tracking
        var para = new("NSMutableParagraphStyle")
        if lh > 0:
            _ = msg(para, "setMinimumLineHeight:", lh)
            _ = msg(para, "setMaximumLineHeight:", lh)
        var out = new("NSMutableAttributedString")
        for r in runs_of(node):
            var rf, rs, rw, rink, fill = family, size, weight, ink, UInt32(0)
            var kern = tracking
            var mono = r.code
            if r.role != "" and r.role != node.name:
                var k = self.look.surface(r.role)
                if k >= 0:
                    ref sf = self.look.surfaces[k]
                    if sf.font != "":
                        rf, mono = sf.font, False
                    rs = sf.font_size if sf.font_size > 0 else rs
                    rw = sf.font_weight if sf.font_weight > 0 else rw
                    rink = sf.ink if sf.ink != 0 else rink
                    fill = sf.fill
                    kern = sf.tracking if sf.tracking != 0 else kern
            if r.bold and rw < 600:
                rw = 700
            var font: Int
            if mono:
                font = look_font(self.look.type.mono, rw, rs) if self.skinned and self.look.type.mono != "" else msg(cls("NSFont"), "monospacedSystemFontOfSize:weight:", rs, Float64(0))
            else:
                font = look_font(rf, rw, rs, self.look.type.tabular) if self.skinned else msg(cls("NSFont"), "boldSystemFontOfSize:" if rw >= 600 else "systemFontOfSize:", rs)
            var attrs = new("NSMutableDictionary")
            _ = msg(attrs, "setObject:forKey:", font, ns_string("NSFont"))
            _ = msg(attrs, "setObject:forKey:", ns_rgba(rink) if rink != 0 else msg(cls("NSColor"), "labelColor"), ns_string("NSColor"))
            _ = msg(attrs, "setObject:forKey:", para, ns_string("NSParagraphStyle"))
            if fill != 0:
                _ = msg(attrs, "setObject:forKey:", ns_rgba(fill), ns_string("NSBackgroundColor"))
            if r.italic:
                _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", Float64(0.2)), ns_string("NSObliqueness"))
            if r.href != "":
                _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithInteger:", 1), ns_string("NSUnderline"))
            if kern != 0:  # (the role's letter spacing, as the web's: a heading's tighter tracking, D-526)
                _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", kern), ns_string("NSKern"))
            var piece = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(css_breaks(r.text)), attrs)
            _ = msg(out, "appendAttributedString:", piece)
        return out

    def set_label(mut self, w: Int, had: Int, words: Int):
        """Label w shows `words` (it showed `had`). When the new words take the same room (their one-line size, rounded
        up to whole points as AppKit's intrinsic size is, the same as the old words'; a wrapping label's also fitting its
        frame on one line), the label's intrinsic size isn't invalidated: NSControl's setter does that for every change,
        which marks the label for constraints and layout (a window layout pass, D-7581); the label is drawn again and
        nothing else is touched. Words that need other room go through the plain setter and lay out (D-7582)."""
        if self.label_inplace and same_room(w, had, words) and quiet_label(w):
            # (its own setter, with the intrinsic-size invalidation it makes skipped for this call: the cell takes the
            # words and the label is marked for drawing; nothing else changes)
            cfunc[NoneType]("objc_setAssociatedObject", w, sel(QUIET_KEY), w, 0)  # OBJC_ASSOCIATION_ASSIGN
            _ = msg(w, "setAttributedStringValue:", words)
            cfunc[NoneType]("objc_setAssociatedObject", w, sel(QUIET_KEY), 0, 0)
            self.labels_in_place += 1
            return
        _ = msg(w, "setAttributedStringValue:", words)
        self.labels_relaid += 1

    def label_text(self, n: Int, text: String) -> String:
        """What TEXT node n's label shows for `text`: its words as the browser lays them out (label_words, D-548, D-549)."""
        return label_words(self.rt.shown.nodes, n) if self.rt.shown.nodes[n].text == text else css_breaks(text)

    def restyle_label(self, w: Int, text: String, k: Int):
        """A label in surface k's type: its font, ink, letter spacing and line height (a table's head and figures)."""
        ref sf = self.look.surfaces[k]
        var font = look_font(sf.font if sf.font != "" else self.look.type.family, sf.font_weight if sf.font_weight > 0 else 400,
                             sf.font_size if sf.font_size > 0 else msg[Float64](msg(w, "font"), "pointSize"), self.look.type.tabular)
        _ = msg(w, "setFont:", font)
        if sf.ink != 0:
            _ = msg(w, "setTextColor:", ns_rgba(sf.ink))
        var attrs = new("NSMutableDictionary")
        _ = msg(attrs, "setObject:forKey:", font, ns_string("NSFont"))
        _ = msg(attrs, "setObject:forKey:", msg(w, "textColor"), ns_string("NSColor"))
        if sf.tracking != 0:
            _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", sf.tracking), ns_string("NSKern"))
        var lh = sf.line_height if sf.line_height > 0 else msg[Float64](font, "pointSize") * self.look.type.line
        if lh > 0:
            var para = new("NSMutableParagraphStyle")
            _ = msg(para, "setMinimumLineHeight:", lh)
            _ = msg(para, "setMaximumLineHeight:", lh)
            _ = msg(attrs, "setObject:forKey:", para, ns_string("NSParagraphStyle"))
            var natural = msg[Float64](font, "ascender") - msg[Float64](font, "descender")
            _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", (lh - natural) / 2), ns_string("NSBaselineOffset"))
            _ = msg(msg(msg(w, "heightAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(Int(lh + 0.5))), "setActive:", 1)
        _ = msg(w, "setAttributedStringValue:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(text), attrs))

    def cell_widths(self, child: Int, node: Int) -> Tuple[Float64, Float64]:
        """A table cell's content: (its narrowest: the longest word; its widest: one line), as CSS's min- and max-content."""
        if self.rt.shown.nodes[node].kind != TEXT or (msg(child, "isKindOfClass:", cls("NSTextField")) & 0xFF) == 0:
            var fit = msg[CGPoint](child, "fittingSize")
            return (fit.x, fit.x)
        var said = msg(child, "attributedStringValue")
        if said == 0 or msg(said, "length") == 0:
            return (Float64(0), Float64(0))
        var attrs = msg(said, "attributesAtIndex:effectiveRange:", 0, 0)
        var widest = msg[CGPoint](said, "size").x
        var narrow = Float64(0)
        for word in self.rt.shown.nodes[node].text.split(" "):
            var one = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(String(word)), attrs)
            narrow = max(narrow, msg[CGPoint](one, "size").x)
        return (Float64(Int(narrow + 0.999)), Float64(Int(widest + 0.999)))

    def one_line_words(mut self, n: Int):
        """The words in view n (and in its views) on one line, cut with an ellipsis: a dense table's cell (the web's
        table.dense td .text: nowrap, overflow hidden, text-overflow ellipsis)."""
        if n < 0 or n >= len(self.rt.shown.nodes) or n >= len(self.widgets):
            return
        var kids = self.rt.shown.nodes[n].children.copy()
        var w = self.widgets[n]
        if self.rt.shown.nodes[n].kind == TEXT and w != 0 and (msg(w, "isKindOfClass:", cls("NSTextField")) & 0xFF) != 0:
            cut_with_ellipsis(w)
            _ = msg(w, "setContentCompressionResistancePriority:forOrientation:", Float32(490), 0)
            for k in range(len(self.wraps)):
                if self.wraps[k] == w:
                    self.wraps[k] = 0  # (fit_wraps leaves it alone)
        for c in kids:
            self.one_line_words(c)

    def fit_tables(self):
        """Each Table's columns share its width as a browser's automatic table layout does (GTK's fit_tables): at least
        each column's narrowest, the room up to its widest shared by how much each wants, more room by the widest (D-442)."""
        if len(self.tcells) == 0 or self.window == 0:
            return
        _ = msg(msg(self.window, "contentView"), "layoutSubtreeIfNeeded")
        var start = 0
        while start < len(self.tcells):
            var table = self.tcells[start][0]
            var end = start
            var cols = 0
            while end < len(self.tcells) and self.tcells[end][0] == table:
                cols = max(cols, self.tcells[end][3] + 1)
                end += 1
            var room = msg[CGRect](table, "bounds").width
            var lo = List[Float64](length=cols, fill=0)
            var hi = List[Float64](length=cols, fill=0)
            var tn = -1  # (the Table's node: parents lists stacks only)
            for q in range(len(self.rt.shown.nodes)):
                if self.rt.shown.nodes[q].kind == TABLE and self.tcells[start][4] in self.rt.shown.nodes[q].children:
                    tn = q
                    break
            var dense = tn >= 0 and (self.rt.shown.nodes[tn].style == 1 or self.rt.shown.nodes[tn].style == 2)
            var lims = self.rt.shown.nodes[tn].options.copy() if tn >= 0 else List[String]()
            var caps = List[Int](length=cols, fill=0)  # (a cut column's widest: the web's td max-width, border-box)
            var fixed = List[Int](length=cols, fill=0)  # (a tick column's width: the web's th width)
            for c in range(min(cols, len(lims))):
                var lim = lims[c]
                var digits = String(lim[byte = 1:]) if lim.startswith("T") else (String(lim[byte = 0 : lim.byte_length() - 1]) if lim.endswith("S") else lim)
                var v = 0
                try:
                    v = Int(digits) if digits != "" and lim != "W" else 0
                except:
                    v = 0
                if lim.startswith("T"):
                    fixed[c] = max(v, 1)
                elif dense:
                    caps[c] = v
            for t in range(start, end):
                var cell = self.tcells[t][1]
                var ins = msg[CGRect](cell, "edgeInsets")  # (NSEdgeInsets: top, left, bottom, right)
                var views = msg(cell, "arrangedSubviews")
                var child = 0
                for j in range(msg(views, "count")):
                    var v = msg(views, "objectAtIndex:", j)
                    if (msg(v, "isMemberOfClass:", cls("NSView")) & 0xFF) == 0:  # (not a spacer)
                        child = v
                if child == 0:
                    continue
                var wh = self.cell_widths(child, self.tcells[t][4])
                var col = self.tcells[t][3]
                var a, b = wh[0] + ins.y + ins.height, wh[1] + ins.y + ins.height
                var lim = lims[col] if col < len(lims) else String("")
                if dense and lim != "W" and not lim.startswith("T"):  # (one-line words: the narrowest is the widest, as the browser's
                    a = b                                             # nowrap; a cut column's cells at most its width, the head not: D-493)
                    if (t - start) // cols > 0 and caps[col] > 0:
                        a, b = min(a, Float64(caps[col])), min(b, Float64(caps[col]))
                lo[col] = max(lo[col], a)
                hi[col] = max(hi[col], b)
            var sum_lo = Float64(0)
            var sum_hi = Float64(0)
            var free_hi = Float64(0)
            for c in range(cols):
                if fixed[c] > 0:  # the tick column: the theme's width overall, its box when wider; no share of more room
                    lo[c] = max(lo[c], Float64(fixed[c]))
                    hi[c] = lo[c]
                else:
                    free_hi += hi[c]
                sum_lo += lo[c]
                sum_hi += hi[c]
            if free_hi <= 0:
                free_hi = sum_hi
            # Each column's exact share, then whole points by rounding where each column ends (its edge is the
            # browser's to half a point): each cut to a whole point left the remainder, up to a point a column, to the
            # last one, and the models table's ACCESS column stood 5 pt wide of the web's (D-550, GTK's fit_tables).
            var widths = List[Float64](length=cols, fill=0)
            var exact = Float64(0)
            var edge = 0
            for c in range(cols):
                var v = lo[c]
                if room >= sum_hi and sum_hi > 0:
                    v = hi[c] + ((room - sum_hi) * hi[c] / free_hi if fixed[c] == 0 else Float64(0))
                elif room > sum_lo and sum_hi > sum_lo:
                    v = lo[c] + (room - sum_lo) * (hi[c] - lo[c]) / (sum_hi - sum_lo)
                exact += v
                var next = Int(exact + 0.5)
                widths[c] = Float64(next - edge)
                edge = next
            for t in range(start, end):
                var col = self.tcells[t][3]
                if self.tcells[t][2] == 0 or room <= 0:
                    continue
                _ = msg(self.tcells[t][2], "setConstant:", widths[col])
            start = end
        _ = msg(msg(self.window, "contentView"), "layoutSubtreeIfNeeded")

    def dash_paths(self):
        """Each dashed outline traced around its view's laid-out bounds (the add tile's dashes); each rounded surface's
        corners at most half its size."""
        if len(self.rounds) > 0 and self.window != 0:
            _ = msg(msg(self.window, "contentView"), "layoutSubtreeIfNeeded")
        for rd in self.rounds:
            var rb = msg[CGRect](rd[0], "bounds")
            var half_size = min(rb.width, rb.height) / 2
            if half_size > 0:
                _ = msg(msg(rd[0], "layer"), "setCornerRadius:", min(Float64(rd[1]), half_size))
        for d in self.dashes:
            var b = msg[CGRect](d[0], "bounds")
            var half = Float64(d[3]) / 2
            _ = msg(d[1], "setFrame:", b.x, b.y, b.width, b.height)
            var path = msg(cls("NSBezierPath"), "bezierPathWithRoundedRect:xRadius:yRadius:", b.x + half, b.y + half, b.width - 2 * half, b.height - 2 * half,
                           Float64(d[2]), Float64(d[2]))
            _ = msg(d[1], "setPath:", msg(path, "CGPath"))

    def fit_wraps(mut self):
        """Each column label wraps at the width the layout gave it: an NSTextField only wraps at a width it's told, so
        lay out, tell each label its width, lay out again (a long inspector line ran past the panel, GitHub's Mac)."""
        if (len(self.wraps) == 0 and len(self.wrap_buttons) == 0) or self.window == 0:
            return
        var content = msg(self.window, "contentView")
        if len(self.wrap_buttons) > 0:  # (a wrapping button as high as the lines its width needs, D-537)
            _ = msg(content, "layoutSubtreeIfNeeded")
            for wb in self.wrap_buttons:
                var bw = msg[CGRect](wb[0], "frame").width - wb[4]
                if bw <= 0 or wb[2] <= 0:
                    continue
                var r = msg[CGRect](msg(wb[0], "attributedTitle"), "boundingRectWithSize:options:", bw, Float64(100000), 1)  # NSStringDrawingUsesLineFragmentOrigin
                var lines = max(Int(r.height / wb[2] + 0.5), 1)
                _ = msg(wb[1], "setConstant:", Float64(Int(Float64(lines) * wb[2] + 0.5)) + wb[3])
            if len(self.wraps) == 0:
                _ = msg(content, "layoutSubtreeIfNeeded")
                return
        var here = List[Int]()  # (a popover's or a sheet's labels are in their own window: show_popover sets theirs)
        for l in self.wraps:
            if (msg(l, "isDescendantOf:", content) & 0xFF) != 0:
                here.append(l)
        for c in self.wrap_keeps:
            _ = msg(c, "setActive:", 0)
        self.wrap_keeps = List[Int]()
        for l in here:  # one line again, the width the layout allows now: 0 meant "the frame's width" to AppKit, and inside
            _ = msg(l, "setPreferredMaxLayoutWidth:", Float64(100000))  # a scroll view that frame started tiny, so the column shrank to 117 pt (the Report's inspector, 2026-10-24)
        _ = msg(content, "layoutSubtreeIfNeeded")
        for l in here:  # (at most its one line, as CSS's shrink-to-fit min(max-content, room): a short list item told its
            # column's width hugged that width, so a list that should hug its items took the whole column, D-528)
            var room = msg[CGRect](l, "frame").width
            var said = msg(l, "attributedStringValue")
            var line = msg[CGPoint](said, "size").x if said != 0 and msg(said, "length") > 0 else room
            _ = msg(l, "setPreferredMaxLayoutWidth:", min(room, Float64(Int(line + 0.999))))
            if line > room + 1:  # (words that wrap keep the room they wrap in, CSS's min(max-content, room) = room; an
                # NSTextField hugs its widest line, so a long list item stood 612 for the web's 646, D-540)
                var keep = msg(msg(l, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", room)
                _ = msg(keep, "setPriority:", Float32(252))
                _ = msg(keep, "setActive:", 1)
                self.wrap_keeps.append(keep)
        _ = msg(content, "layoutSubtreeIfNeeded")

    def resize_in_place(mut self, d: Diff) -> Bool:
        """A partial rebuild whose only change of shape is a view's new width or height (the island morphing, 60 times a
        second): the view's size constraints take the new numbers and every view stays. Rebuilding the window for it
        threw the charts' drawn pictures away each frame (the GitHub Mac runner, 2026-10-23). False: rebuild."""
        if not d.partial or len(d.resync) != 0 or len(d.kept) != len(self.rt.shown.nodes) or len(self.sized) != len(d.kept):
            return False
        for k in range(len(d.kept)):
            if d.kept[k] != k:
                return False
        for p in d.patches:
            if p.op != SET_SIZE:
                continue
            ref n = self.rt.shown.nodes[p.node]
            var was = self.sized[p.node]
            if n.min_w != was[2] or n.max_w != was[3] or (n.w != was[0] and self.size_w[p.node] == 0) or (n.h != was[1] and self.size_h[p.node] == 0):
                return False  # a size it wasn't built with (or none to change): rebuild
            if n.w == 0 or n.h == 0:
                if (n.w == 0 and was[0] != 0) or (n.h == 0 and was[1] != 0):
                    return False
        for p in d.patches:
            if p.op != SET_SIZE:
                continue
            ref n = self.rt.shown.nodes[p.node]
            var inset = self.box_inset(p.node, n.name) if p.node < len(self.objects) and self.objects[p.node] != 0 else (0, 0)
            if n.w != self.sized[p.node][0]:
                _ = msg(self.size_w[p.node], "setConstant:", Float64(n.w - inset[0]))
            if n.h != self.sized[p.node][1]:
                _ = msg(self.size_h[p.node], "setConstant:", Float64(n.h - inset[1]))
            if p.node < len(self.objects) and self.objects[p.node] != 0:  # (a boxed object resized: its box too, as SET_PLACE does)
                _ = msg(self.objects[p.node], "setFrame:", Float64(n.x), Float64(n.y), Float64(n.w), Float64(n.h))
            self.sized[p.node] = (n.w, n.h, n.min_w, n.max_w)
        return True

    # ---------- the Mac report (Debug menu) ----------

    def add_debug_menu(self, self_addr: Int):
        """Debug in the menu bar (whichever menus the screen put there): record a report, take one picture, open its folder."""
        var bar = msg(msg(cls("NSApplication"), "sharedApplication"), "mainMenu")
        if bar == 0 or msg(bar, "itemWithTitle:", ns_string("Debug")) != 0:
            return
        var item = new("NSMenuItem")
        _ = msg(item, "setTitle:", ns_string("Debug"))
        var menu = msg(msg(cls("NSMenu"), "alloc"), "initWithTitle:", ns_string("Debug"))
        _ = msg(menu, "setAutoenablesItems:", 0)
        var actions: List[Tuple[String, String, String]] = [("Record a report", "debugRecord:", "r"), ("Take a snapshot", "debugSnapshot:", "s"),
                                                            ("Open the report folder", "debugOpen:", "")]
        for a in actions:
            var it = msg(menu, "addItemWithTitle:action:keyEquivalent:", ns_string(a[0]), sel(a[1]), ns_string(a[2]))
            _ = msg(it, "setKeyEquivalentModifierMask:", (1 << 20) | (1 << 19))  # ⌘⌥
            _ = msg(it, "setTarget:", self.target)
            _ = msg(it, "setTag:", self_addr)
            if a[1] == "debugRecord:" and self.report.on:
                _ = msg(it, "setState:", 1)
        _ = msg(item, "setSubmenu:", menu)
        _ = msg(bar, "addItem:", item)

    def start_report(mut self):
        if self.report.on:
            return
        self.report.start(self.rt.app.title(), self.window)
        var b = msg[CGRect](msg(self.window, "contentView"), "bounds")
        self.report.note("content: " + pts(b.width) + " x " + pts(b.height) + " pt (told to the app as its size)")
        var bar = msg(msg(cls("NSApplication"), "sharedApplication"), "mainMenu")
        var debug = msg(bar, "itemWithTitle:", ns_string("Debug")) if bar != 0 else 0
        if debug != 0:
            _ = msg(msg(msg(debug, "submenu"), "itemAtIndex:", 0), "setState:", 1)

    def queue_snapshot(mut self, self_addr: Int):
        """A picture once the screen settles (0.4 s after the first change; changes in between share it)."""
        if not self.report.on or self.report.pending or self.report.count >= MAX_SHOTS:
            return
        self.report.pending = True
        _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("debugQueued:"), ns_number(self_addr), Float64(0.4))

    def snapshot(mut self):
        if self.report.on and self.report.count < MAX_SHOTS and self.window != 0 and not self.shots_taken:
            # (a WKWebView draws out of process: cacheDisplayInRect: leaves it blank, so WebKit pictures each first and
            # the last picture to arrive calls this again)
            if webview_shoot(self.webviews) > 0:
                self.shots_taken = True
                return
        self.shots_taken = False
        self.report.pending = False
        if not self.report.on or self.report.count >= MAX_SHOTS or self.window == 0:
            return
        var name = self.report.next_name()
        var content = msg(self.window, "contentView")
        var whole = content
        if (msg(content, "isKindOfClass:", cls("NSScrollView")) & 0xFF) != 0:
            # a screen taller than the window: the whole page, as the web's full-page screenshot and GTK's picture (D-461)
            var doc = msg(content, "documentView")
            if doc != 0 and msg[CGRect](doc, "bounds").height > msg[CGRect](content, "bounds").height + 0.5:
                whole = doc
        var pictured = self.report.save_png(whole, name + ".png", self.webviews)
        var problems = List[String]()
        var dump = self.dump_views(problems)
        self.report.write(name + ".txt", dump)
        var line = "snapshot " + name + ("" if pictured else " (no picture)")
        if self.popover != 0:  # (its own window: drawn into a picture of its own, NNN-popover.png)
            var pv = msg(msg(self.popover, "contentViewController"), "view")
            _ = msg(pv, "layoutSubtreeIfNeeded")
            if msg[CGRect](pv, "bounds").width < 1:  # (not on screen yet, or a runner's popover never shown: drawn at its own size)
                var fit = msg[CGPoint](pv, "fittingSize")
                _ = msg(pv, "setFrameSize:", fit.x, fit.y)
                _ = msg(pv, "layoutSubtreeIfNeeded")
            var shown = self.report.save_png(pv, name + "-popover.png")
            line += " · a popover is open (" + ("in " + name + "-popover.png" if shown else String("no picture")) + ")"
        if self.sheet != 0:
            var shown = self.report.save_png(msg(self.sheet, "contentView"), name + "-dialog.png")
            line += " · a dialog is open (" + ("in " + name + "-dialog.png" if shown else String("no picture")) + ")"
        line += " · " + String(self.rebuilds) + " rebuilds, " + String(self.resized_in_place) + " resized in place since the last"
        self.rebuilds = 0
        self.resized_in_place = 0
        self.report.note(line + " · " + String(len(problems)) + " problems")
        for k in range(min(len(problems), 12)):
            self.report.note("  " + problems[k])
        self.report.cause = "change"

    def dump_views(self, mut problems: List[String]) -> String:
        """Every node of the screen, indented as the view tree: its kind, text, what it asked for and where AppKit put it."""
        var content = msg(self.window, "contentView")
        var cb = msg[CGRect](content, "bounds")
        var out = String("window content " + pts(cb.width) + " x " + pts(cb.height) + " pt · x, y from the top left\n")
        var watch = env("MOJOUI_CONSTRAINTS")
        out += "kind 'text' [asked] @ x,y w x h  flags\n\n"
        var stack: List[Tuple[Int, Int]] = [(0, 0)]
        while len(stack) > 0:
            var top = stack.pop()
            var i = top[0]
            var depth = top[1]
            ref n = self.rt.shown.nodes[i]
            var line = String("")
            for _ in range(depth):
                line += "  "
            var box = self.objects[i] if i < len(self.objects) else 0
            if box != 0:  # (a Board object's box, then its content: the web lists its .object and its view, both tagged)
                var bb = msg[CGRect](box, "bounds")
                var br = msg[CGRect](box, "convertRect:toView:", bb.x, bb.y, bb.width, bb.height, 0)
                out += line + "Object #" + n.name + " @ " + pts(br.x) + "," + pts(cb.height - (br.y + br.height)) + " " + pts(br.width) + "x" + pts(br.height) + "\n"
                line += "  "
            line += kind_name(n.kind)
            if n.text != "" and n.kind != IMAGE:
                var t = n.text
                if n.text.byte_length() > 60:
                    var cut = 57
                    while cut > 0 and (Int(n.text.as_bytes()[cut]) & 0xC0) == 0x80:  # (not inside a character: "×" at byte 56 crashed it)
                        cut -= 1
                    t = String(n.text[byte=:cut]) + "..."
                line += " '" + t + "'"
            var asked = String("")
            if n.w != 0:
                asked += " w" + String(n.w)
            if n.h != 0:
                asked += " h" + String(n.h)
            if n.grows:
                asked += " grow"
            if n.fills:
                asked += " fill"
            if asked != "":
                line += " [" + String(asked[byte=1:]) + "]"
            if n.name != "":
                line += " #" + n.name  # (its tag: scripts/parity.py matches it to the web's data-tag)
            var w = self.widgets[i] if i < len(self.widgets) else 0
            if i < len(self.shells) and self.shells[i] != 0:
                w = self.shells[i]  # (a field's box: what the person sees, and what GTK and the web measure)
            if i == 0 and (n.grows or n.fills) and w != 0:
                # a screen that fills the window: its box is the page it fills, what the window shows (the web's root is
                # the window high and a taller screen overflows it, scrolling the page; the Mac's root is as tall as its
                # content in the page's scroll view: models 710 for the web's 640, D-551)
                w = content
            if w == 0:
                if n.kind != ITEM and n.kind != MENU and n.kind != CLIPBOARD and n.kind != ROUTE and n.kind != DIALOG and n.kind != POPOVER and n.kind != TOAST and n.kind != SPACER:
                    line += "  (no view)"
            elif (msg(w, "isKindOfClass:", cls("NSView")) & 0xFF) != 0:
                var b = msg[CGRect](w, "bounds")
                var r = msg[CGRect](w, "convertRect:toView:", b.x, b.y, b.width, b.height, 0)
                if (n.kind == TEXT or n.kind == PARAGRAPH) and (i >= len(self.shells) or self.shells[i] == 0):  # the text's own box: a label's frame has 2 pt each side (a Paragraph's too, D-536)
                    var inset = msg[CGRect](w, "alignmentRectInsets")  # (NSEdgeInsets: top, left, bottom, right) that GTK's and the web's labels don't
                    r.x += inset.y
                    r.width -= inset.y + inset.height
                var top_y = cb.height - (r.y + r.height)
                line += " @ " + pts(r.x) + "," + pts(top_y) + " " + pts(r.width) + "x" + pts(r.height)
                var flags = String("")
                if (msg(w, "isHiddenOrHasHiddenAncestor") & 0xFF) != 0:
                    flags += " hidden"
                if r.width < 1 or r.height < 1:
                    flags += " ZERO-SIZE"
                    problems.append(kind_name(n.kind) + " '" + n.text + "' (node " + String(i) + ") has no size: " + pts(r.width) + "x" + pts(r.height))
                elif r.x + r.width < 1 or top_y + r.height < 1 or r.x > cb.width - 1 or top_y > cb.height - 1:
                    flags += " OFF-WINDOW"
                    problems.append(kind_name(n.kind) + " '" + n.text + "' (node " + String(i) + ") is outside the window")
                if n.kind == CANVAS:
                    var k = self.canvas_at(i)
                    if k >= 0:
                        flags += " canvas " + String(self.canvases[k].wpx) + "x" + String(self.canvases[k].hpx) + " px drawn v" + String(self.canvases[k].drawn) + " of v" + String(n.value)
                        if self.canvases[k].gpu_frames > 0:
                            flags += " iosurface " + String(self.canvases[k].gpu_frames)
                        if self.canvases[k].wpx == 0:
                            problems.append("canvas node " + String(i) + " (id " + String(n.style) + ") was never drawn")
                if n.kind == CANVAS and n.tip != "":  # (a drawn view's words aren't views: what it says, as VoiceOver reads it)
                    flags += " says '" + n.tip + "'"
                if (n.kind == SCROLL or n.kind == BOARD) and (msg(w, "respondsToSelector:", sel("contentView")) & 0xFF) != 0:
                    # its clip (what the content gets), its bars' style (0 legacy, 1 overlay), the vertical bar's width and
                    # whether it shows, and its content insets (top, left, bottom, right): where a narrow clip's points went
                    var clip = msg[CGRect](msg(w, "contentView"), "frame")
                    var bar = msg(w, "verticalScroller")
                    var ins = msg[CGRect](w, "contentInsets")
                    flags += (" clip " + pts(clip.width) + "x" + pts(clip.height) + " bars " + String(msg(w, "scrollerStyle"))
                              + " vbar " + (pts(msg[CGRect](bar, "frame").width) + ("" if (msg(bar, "isHidden") & 0xFF) == 0 else " unshown") if bar != 0 else "none")  # ("unshown": parity.py skips a line saying " hidden", a hidden view; a hidden bar isn't one, D-518)
                              + " insets " + pts(ins.x) + "," + pts(ins.y) + "," + pts(ins.width) + "," + pts(ins.height))
                if n.kind == ICON or ((n.kind == BUTTON) and n.hint != ""):
                    var name = n.text if n.kind == ICON else n.hint
                    if sf_symbol(name) == "questionmark.square.dashed" and name != "app-logo":
                        flags += " NO-SYMBOL(" + name + ")"
                        problems.append("icon '" + name + "' has no SF Symbol")
                line += flags
            out += line + "\n"
            if n.name != "" and w != 0 and ("," + watch + ",").find("," + n.name + ",") >= 0:
                # MOJOUI_CONSTRAINTS (tags, comma-separated): what lays this view out vertically, for the report (its
                # hugging and resistance, then every constraint AppKit says affects its height: a row's views standing
                # the row's height on the Mac, D-507). Lines start "~" (scripts/parity.py reads only "@ x,y wxh")
                var axis = 0 if env("MOJOUI_CONSTRAINTS_AXIS") == "h" else 1  # (h: what lays it out across, its width)
                var an = String("h") if axis == 0 else String("v")
                out += line[byte=0 : depth * 2] + "  ~ hug " + an + " " + String(Int(msg[Float32](w, "contentHuggingPriorityForOrientation:", axis)))
                out += " resist " + an + " " + String(Int(msg[Float32](w, "contentCompressionResistancePriorityForOrientation:", axis)))
                if (msg(w, "isKindOfClass:", cls("NSStackView")) & 0xFF) != 0:
                    out += " stack-hug v " + String(Int(msg[Float32](w, "huggingPriorityForOrientation:", 1))) + " h " + String(Int(msg[Float32](w, "huggingPriorityForOrientation:", 0)))
                    out += " align " + String(msg(w, "alignment")) + " dist " + String(msg(w, "distribution"))
                out += "\n"
                var cs = msg(w, "constraintsAffectingLayoutForOrientation:", axis)
                for q in range(min(msg(cs, "count"), 40)):
                    var c = msg(cs, "objectAtIndex:", q)
                    out += line[byte=0 : depth * 2] + "  ~ " + String(Int(msg[Float32](c, "priority"))) + " " + from_ns(msg(c, "description")).replace("\n", " ") + "\n"
            var kids = n.children.copy()
            var j = len(kids) - 1
            while j >= 0:
                stack.append((kids[j], depth + 1))
                j -= 1
        if mac_at(self.webviews)[].core.state == 1:  # each WebComponent's view, as the host saw it (GTK's WEBVIEW:/WIDGET: lines)
            out += "\n" + webview_report(self.webviews)
        return out^

    def queue_resize(mut self, self_addr: Int):
        """The window says its size changed, often from inside AppKit's own layout pass: the app lays out to the new
        size on the next run-loop turn. Rebuilding there replaced the menu bar mid-layout, and macOS 26 aborts on that
        (the owner's crash report, 2026-10-23: setMainMenu: from windowDidResize: inside layoutIfNeeded). One pending
        turn takes every size a burst of resizes gives."""
        if self.resize_pending:
            return
        self.resize_pending = True
        var modes = msg(cls("NSArray"), "arrayWithObject:", ns_string("kCFRunLoopCommonModes"))  # (live: also while an edge is dragged)
        _ = msg(self.target, "performSelector:withObject:afterDelay:inModes:", sel("windowResizeLater:"), ns_number(self_addr), Float64(0), modes)

    def resized(mut self, self_addr: Int):
        """The window's content area changed size: the app lays out to it (App.resize), as on GTK and the web."""
        self.resize_pending = False
        var b = msg[CGRect](msg(self.window, "contentView"), "bounds")
        var w = Int(b.width + 0.5)
        var h = Int(b.height + 0.5)
        if w <= 0 or h <= 0:
            return
        var in_place = self.resized_in_place
        var d = self.rt.resize(w, h)
        self.apply(d, self_addr)
        if not d.rebuild or self.resized_in_place > in_place:  # (a whole rebuild fitted them already)
            self.fit_tables()
            self.fit_wraps()
        self.dash_paths()
        if self.asked_w > 0 and (w != self.asked_w or h != self.asked_h):
            # the old screen's minimum stopped the window short (omxplorer's labelled ribbon at 1,920 held a jump to 1,440
            # at 1,529): the app has laid out to what it got, maybe to a smaller minimum; the size asked again, once
            var aw = self.asked_w
            var ah = self.asked_h
            self.asked_w = 0
            self.asked_h = 0
            _ = msg(self.window, "setContentSize:", Float64(aw), Float64(ah))
        else:
            self.asked_w = 0
            self.asked_h = 0

    # ---------- canvases ----------

    def canvas_at(self, node: Int) -> Int:
        for k in range(len(self.canvases)):
            if self.canvases[k].node == node:
                return k
        return -1

    def input_activity(mut self, self_addr: Int):
        """(D-8023) Input came: macOS told that someone waits (mojoui.macactivity; off unless MOJOUI_ACTIVITY is set)."""
        if self.activity.touch():
            _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("activityDue:"), ns_number(self_addr), self.activity.due_in())

    def canvas_send(mut self, node: Int, kind: Int, x: Float64, y: Float64, dx: Float64, dy: Float64, zoom: Float64, self_addr: Int,
                    pressure: Float64 = 0):
        if self.report.on and kind != PAN and kind != ZOOM and kind != WHEEL:
            self.report.cause = "canvas " + gesture_name(kind)
            self.report.note("event: canvas node " + String(node) + " " + gesture_name(kind) + " at " + pts(x) + ", " + pts(y))
        self.gpu_input(node)
        self.input_activity(self_addr)
        var d = self.rt.gesture(node, kind, x, y, dx, dy, zoom, pressure)
        self.apply(d, self_addr)

    def ime_caret(self, node: Int) -> Tuple[Float64, Float64, Float64, Float64]:
        """(D-7979) The app's caret on canvas node `node` (canvas points from the top left; x < 0: none)."""
        if node < 0 or node >= len(self.rt.shown.nodes):
            return (-1.0, 0.0, 0.0, 0.0)
        return self.rt.app.caret(self.rt.shown.nodes[node].style)

    def ime_preedit(mut self, node: Int, text: String, self_addr: Int):
        """The composition on canvas `node` is now `text` ("": over): IME_PREEDIT with the caret, as GTK's preedit."""
        self.ime_text = text
        self.ime_node = node if text != "" else -1
        var r = self.ime_caret(node)
        if env("MOJOUI_IME_TRACE") == "1":
            print("IME: node=" + String(node) + " kind=" + String(self.rt.shown.nodes[node].kind if node >= 0 and node < len(self.rt.shown.nodes) else -1) + " caret=" + String(r[0]) + "," + String(r[1]), flush=True)
        var d = self.rt.text_event(node, IME_PREEDIT, text, r[0], r[1], r[2], r[3], Float64(text.byte_length()))
        self.apply(d, self_addr)

    def ime_commit(mut self, node: Int, text: String, self_addr: Int):
        """Text the input method committed on canvas `node`: IME_COMMIT, and the composition is over."""
        var had = self.ime_text != ""
        self.ime_text = ""
        self.ime_node = -1
        var d = self.rt.text_event(node, IME_COMMIT, text)
        self.apply(d, self_addr)
        if had:
            var d2 = self.rt.text_event(node, IME_PREEDIT, "")
            self.apply(d2, self_addr)

    def canvas_key(mut self, node: Int, name: String, mods: Int, self_addr: Int):
        """A KEY on canvas node `node` (keyDown, and the test steps that stand for it)."""
        self.gpu_input(node)
        var d = self.rt.key(node, name, mods)
        self.apply(d, self_addr)
        if (mods & 2) != 0 and (name == "v" or name == "V"):  # (D-7979) a paste: the pasteboard's text for the canvas, as GTK's
            var text = from_ns(msg(paste_board(), "stringForType:", ns_string("public.utf8-plain-text")))
            if text != "":
                var d2 = self.rt.text_event(node, PASTE, text)
                self.apply(d2, self_addr)

    def gpu_input(mut self, node: Int):
        """Input reached canvas node `node`: when it's drawn by gpu2d on Metal, the GPU is woken now if it's idle (it's
        about to draw a frame; D-7540)."""
        if self.g2d == 0 or node < 0 or node >= len(self.rt.shown.nodes):
            return
        if self.rt.shown.nodes[node].hint == "gpu" or self.g2d_force:
            Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=self.g2d)[].metal.wake()

    def tick(mut self, seconds: Float64, self_addr: Int):
        """Every display frame: frame events for canvases that asked, then redraws."""
        self.ticks += 1
        if self.ticks == 1:
            self.report.note("frames: first tick")
        var micro = Int((seconds - self.last_frame) * 1e6) if self.last_frame > 0 and seconds - self.last_frame < 0.25 else 16667
        self.last_frame = seconds
        var k = 0
        self.g2d_defer = True  # (GPU frames are committed, not waited for: shown when they complete, D-7555)
        while k < len(self.canvases):
            var node = self.canvases[k].node
            if self.rt.shown.nodes[node].msg2 != 0:
                var d = self.rt.frame(node, micro)
                self.apply(d, self_addr)
                if d.rebuild:
                    self.g2d_defer = False
                    self.finish_frame()
                    return
            self.draw_canvas(k, self_addr)
            k += 1
        self.g2d_defer = False
        self.finish_frame()
        if self.link != 0 and self.idle():  # nothing to animate or redraw: stop waking up
            self.finish_gpu2d(0)  # (the last frame is shown now: no tick follows)
            _ = msg(self.link, "invalidate")
            self.link = 0

    def finish_frame(mut self):
        """After a frame's draws: the window draws and commits its own views, then GPU frames are shown oldest first,
        leaving g2d_keep of them in flight (the next frame shows them; tick shows the last when it stops) (D-7555)."""
        self.finish_ready()
        if len(self.g2d_pk) <= self.g2d_keep:
            return
        if self.window != 0:
            _ = msg(self.window, "displayIfNeeded")
            _ = msg(cls("CATransaction"), "flush")  # (layer-backed views draw into their layers when it commits: now)
        self.finish_gpu2d(self.g2d_keep)

    def idle(self) -> Bool:
        for ref c in self.canvases:
            if self.rt.shown.nodes[c.node].msg2 != 0 or c.drawn != self.rt.shown.nodes[c.node].value or c.wpx == 0:
                return False
        return True

    def wake(mut self):
        """Something may need drawing (a new version, frames, a new size): tick again."""
        self.start_frames()

    def start_frames(mut self):
        """Ticks every canvas 60 times a second until they're idle. A plain NSTimer, in the common run-loop modes (it keeps
        ticking while a slider or a menu tracks the mouse). The view's display link (macOS 14+) never fired on the owner's
        Mac (macOS 26, 2026-10-22: no canvas ever drew), and a timer doesn't depend on the view being on screen."""
        if self.link != 0 or len(self.canvases) == 0:
            return
        self.link = msg(cls("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:", Float64(1.0 / 60.0), self.canvases[0].view, sel("canvasFrame:"), 0, 1)
        _ = msg(msg(cls("NSRunLoop"), "mainRunLoop"), "addTimer:forMode:", self.link, ns_string("kCFRunLoopCommonModes"))
        if self.ticks == 0:
            self.report.note("frames: timer started for " + String(len(self.canvases)) + " canvases (" + ("ok" if self.link != 0 else "NO TIMER") + ")")

    def keep_views(mut self, self_addr: Int):
        """(D-8016) The window is closing: a tiled canvas whose view is settled but not kept yet (a note opened and left
        within a second) is drawn up to three times more, now, so the next open shows it."""
        if self.g2d == 0:
            return
        var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=self.g2d)
        if not g[].tiles.keeping_due():
            return
        var t0 = Int(now_ns())
        g[].tiles.hurry = True
        for k in range(len(self.canvases)):
            for _ in range(3):
                if Int(now_ns()) - t0 > 200_000_000:
                    break
                self.canvases[k].drawn = -1
                self.draw_canvas(k, self_addr)
                if not g[].more:
                    break
        g[].tiles.hurry = False
        if env("MOJOUI_SNAP_LOG") == "1":
            print("SNAP: closing: kept in " + one_decimal(Float64(Int(now_ns()) - t0) / 1e6) + " ms", flush=True)

    def draw_canvas(mut self, k: Int, self_addr: Int):
        """Asks the app to paint canvas k at its real pixel size (if its size or version changed); the first picture
        drawn notes the process's age (firstscreen:, D-7988)."""
        var drawn0 = self.canvases[k].drawn
        var g0 = self.g2d_frames
        self._draw_canvas(k, self_addr)
        if self.first_draw_age_ms < 0 and k < len(self.canvases) and (self.canvases[k].drawn != drawn0 or self.g2d_frames != g0):
            self.first_draw_age_ms = process_age_ms()

    def _draw_canvas(mut self, k: Int, self_addr: Int):
        """Asks the app to paint canvas k at its real pixel size (if its size or version changed)."""
        var view = self.canvases[k].view
        var node = self.canvases[k].node
        var bounds = msg[CGRect](view, "bounds")
        var scale = msg[Float64](self.window, "backingScaleFactor") if self.window != 0 else 2.0
        var wpx = Int(bounds.width * scale + 0.5)
        var hpx = Int(bounds.height * scale + 0.5)
        var version = self.rt.shown.nodes[node].value
        if wpx <= 0 or hpx <= 0 or (wpx == self.canvases[k].wpx and hpx == self.canvases[k].hpx and version == self.canvases[k].drawn):
            return
        if self.g2d_why == "" and (self.rt.shown.nodes[node].hint == "gpu" or self.g2d_force):
            if self.draw_gpu2d(k, wpx, hpx, scale, bounds, version, self_addr):
                return
        if len(self.canvases[k].pixels) != wpx * hpx:
            self.canvases[k].pixels = List[UInt32](length=wpx * hpx, fill=0)
        var surface = Surface(Int(self.canvases[k].pixels.unsafe_ptr()), wpx, hpx, scale)
        comptime if MAC_GPU:
            self.offer_iosurface(k, wpx, hpx, surface)
        var d = self.rt.draw(node, surface)
        if wpx != self.canvases[k].wpx or hpx != self.canvases[k].hpx:
            self.report.note("canvas node " + String(node) + " (id " + String(self.rt.shown.nodes[node].style) + ") drew " + String(wpx) + "x" + String(hpx) + " px, "
                             + pts(bounds.width) + "x" + pts(bounds.height) + " pt")
        var on_gpu = False
        comptime if MAC_GPU:
            on_gpu = self.show_iosurface(k, surface, bounds)
        if not on_gpu and not self.show_pixels(k, wpx, hpx, bounds):
            return
        self.canvases[k].wpx = wpx
        self.canvases[k].hpx = hpx
        self.canvases[k].drawn = version
        self.apply(d, self_addr)

    def show_pixels(mut self, k: Int, wpx: Int, hpx: Int, bounds: CGRect) -> Bool:
        """The canvas's CPU pixels into its image view (a CGImage copy). False: no CGImage could be made."""
        var image = cg_image(self.canvases[k].pixels, wpx, hpx)
        if image == 0:
            self.report.note("canvas node " + String(self.canvases[k].node) + ": no CGImage from its pixels")
            return False
        var picture = msg(msg(cls("NSImage"), "alloc"), "initWithCGImage:size:", image, bounds.width, bounds.height)
        _ = msg(self.canvases[k].view, "setImage:", picture)
        _ = msg(picture, "release")
        cfunc[NoneType]("CGImageRelease", image)
        return True

    def gpu2d(mut self) -> Int:
        """The Metal renderer for .gpu() canvases (made the first time one draws: the shaders compile once, the pipelines
        and stencil states are built once), or 0 when Metal can't be set up: g2d_why says why, the backend name says
        cpu from then on, and those canvases take the CPU path."""
        if self.g2d == 0 and self.g2d_why == "":
            var t0 = Int(now_ns())
            var p = alloc(Layout[MetalCanvas2D].single()).unsafe_leak()  # (lives as long as the app)
            p.unsafe_write(MetalCanvas2D())
            if not p[].metal.ok:
                self.g2d_why = p[].metal.why
                set_backend_name("cpu (" + self.g2d_why + ")")
                print("mojoui: gpu2d: no Metal path (" + self.g2d_why + "); GPU canvases are drawn on the CPU", flush=True)
                self.report.note("gpu2d: no Metal path (" + self.g2d_why + ")")
                return 0
            self.g2d = Int(p)
            var ms = Float64(Int(now_ns()) - t0) / 1e6
            # the main thread draws these frames: it asks for the interactive class (a user is dragging), as an app's main
            # thread launched by the Finder has; one started from a shell inherits the shell's (D-7539)
            var qos0 = cfunc[UInt32]("qos_class_self")
            if env("MOJOUI_QOS") != "0":
                _ = cfunc[Int32]("pthread_set_qos_class_self_np", UInt32(0x21), Int32(0))  # QOS_CLASS_USER_INTERACTIVE
            var qos1 = cfunc[UInt32]("qos_class_self")
            print("mojoui: gpu2d on Metal (" + p[].metal.name + "): GPU canvases are drawn by our renderer, set up in " + one_decimal(ms) + " ms; main thread QoS "
                  + String(Int(qos0)) + " → " + String(Int(qos1)) + " (33 interactive, 25 initiated, 21 default, 0 unspecified)", flush=True)
            self.report.note("gpu2d: Metal on " + p[].metal.name + " (set up in " + one_decimal(ms) + " ms)")
        return self.g2d

    def ring_pick(mut self, k: Int, wpx: Int, hpx: Int, mtl: Int) -> Int:
        """An IOSurface of canvas k's ring (wpx × hpx) that Core Animation isn't showing, made when the size changes; the
        ring grows past three (to six) rather than tear or copy when the window server holds them all. -1: none.
        (Not a CAMetalLayer: presenting drawables let the system pace the app to the display and lower its clocks
        until each frame took ~8.5 ms, D-7535.)"""
        var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=mtl)
        ref c = self.canvases[k]
        if c.sw != wpx or c.sh != hpx:
            for s in c.surfaces:  # (the old size's: released below, their wraps first)
                c.retired.append(s)
            c.surfaces.clear()
            for _ in range(3):
                var s = io_surface(wpx, hpx)
                if s == 0:
                    break
                c.surfaces.append(s)
            c.sw = wpx
            c.sh = hpx
            c.next = 0
            if len(c.surfaces) == 0:
                self.report.note("canvas node " + String(c.node) + ": no IOSurface of " + String(wpx) + "x" + String(hpx) + " px")
        for x in c.retired:  # (forget drains every frame in flight first, D-7555: nothing still uses them)
            g[].metal.forget(x)
            cfunc[NoneType]("CFRelease", x)
        c.retired.clear()
        var n = len(c.surfaces)
        for j in range(n):
            var at = (c.next + j) % n
            var flying = False  # (committed, not yet shown: Core Animation doesn't hold it yet, the GPU does)
            for x in self.g2d_ps:
                if x == c.surfaces[at]:
                    flying = True
            if not flying and cfunc[UInt8]("IOSurfaceIsInUse", c.surfaces[at]) == 0:
                return at
        if n > 0 and n < 6:
            var s = io_surface(wpx, hpx)
            if s != 0:
                c.surfaces.append(s)
                return n
        return -1

    def layer_show(mut self, k: Int, s: Int, bounds: CGRect):
        """A sublayer of canvas k's view shows IOSurface s as its contents (Core Animation reads that memory: no copy)."""
        ref c = self.canvases[k]
        if c.layer == 0:
            _ = msg(c.view, "setWantsLayer:", 1)
            _ = msg(c.view, "setImage:", 0)
            c.layer = msg(msg(cls("CALayer"), "alloc"), "init")
            _ = msg(c.layer, "setContentsGravity:", ns_string("resize"))
            _ = msg(msg(c.view, "layer"), "addSublayer:", c.layer)
        _ = msg(cls("CATransaction"), "begin")
        _ = msg(cls("CATransaction"), "setDisableActions:", 1)  # (no implicit fade between frames)
        _ = msg(c.layer, "setFrame:", Float64(0), Float64(0), bounds.width, bounds.height)
        _ = msg(c.layer, "setContents:", s)
        _ = msg(c.layer, "setHidden:", 0)
        _ = msg(cls("CATransaction"), "commit")

    def draw_gpu2d(mut self, k: Int, wpx: Int, hpx: Int, scale: Float64, bounds: CGRect, version: Int, self_addr: Int) -> Bool:
        """Canvas k on the GPU (goal 75 M3): the app's Scene (draw_scene) → gpu2d's batches, layer by layer (unchanged
        layers keep theirs, D-7533) → Metal into a free IOSurface of the canvas's ring (one no frame in flight holds)
        and handed to Core Animation as a layer's contents (no copy) once the GPU completed it: at once, or, inside tick
        and framebench (g2d_defer), when the frame's completed handler says so or a later frame needs the slot, never
        blocking on the frame just committed (D-7555). When Metal can't take the frame (no free IOSurface, a failed
        command buffer) the same batches are drawn by gpu2d's CPU executor and shown as before. False: the app draws no
        Scene (the host's usual path draws it)."""
        var addr = self.gpu2d()
        if addr == 0:
            return False
        if len(self.g2d_pk) > 0 and not self.g2d_defer:  # (a waited-for draw: whatever is in flight is shown first)
            self.finish_gpu2d(0)
        var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=addr)
        if not self.g2d_notify:  # (frames committed without waiting are shown from the main queue when they complete)
            g[].metal.notify(self_addr, fn_address(on_gpu2d_done[Self.A]))
            self.g2d_notify = True
        var node = self.canvases[k].node
        var t0 = Int(now_ns())
        g[].scene.reset(wpx, hpx, scale)
        var r = self.rt.draw_scene(node, g[].scene)
        if not r[0]:
            return False
        var t1 = Int(now_ns())
        if len(self.g2d_pk) > self.g2d_keep:  # (no more than g2d_keep + 1 frames in flight)
            self.finish_gpu2d(self.g2d_keep)
        var at = self.ring_pick(k, wpx, hpx, addr)
        var on_gpu = False
        var pending = False
        if at >= 0:
            var s = self.canvases[k].surfaces[at]
            var defer = self.g2d_defer and self.g2d_defer_on
            on_gpu = g[].render_scene(node, s, wpx, hpx, 0, not defer)
            self.g2d_parts[0] = Float64(t1 - t0) / 1e6
            self.g2d_parts[1] = g[].build_ms
            self.g2d_parts[2] = Float64(Int(now_ns()) - t1) / 1e6 - g[].build_ms
            self.g2d_parts[4] = Float64(g[].rebuilt)
            self.g2d_parts[5] = Float64(g[].kept)
            self.g2d_parts[6] = Float64(g[].grown)
            self.g2d_parts[7] = Float64(g[].groups)
            self.g2d_parts[8] = Float64(g[].metal.drawn_groups)
            self.g2d_parts[11] = g[].metal.idle_ms
            self.g2d_parts[12] = Float64(g[].metal.woken)
            if on_gpu and defer:  # (committed: shown when it completes, finish_ready / show_oldest)
                pending = True
                self.g2d_pk.append(k)
                self.g2d_pat.append(at)
                self.g2d_ps.append(s)
                self.g2d_pw.append(wpx)
                self.g2d_ph.append(hpx)
                self.g2d_pscale.append(scale)
                self.g2d_pb.append(bounds.copy())
                self.g2d_pt.append(Int(now_ns()))
                self.canvases[k].next = (at + 1) % len(self.canvases[k].surfaces)
                self.canvases[k].gpu_frames += 1
                self.g2d_frames += 1
            elif on_gpu:
                self.g2d_done.append(g[].metal.gpu_ms)
                self.gpu2d_shown(k, at, bounds, True)
        if not on_gpu:
            self.gpu2d_cpu(k, wpx, hpx, scale, bounds, False)
        if wpx != self.canvases[k].wpx or hpx != self.canvases[k].hpx:
            self.report.note("canvas node " + String(node) + " (id " + String(self.rt.shown.nodes[node].style) + ") drew " + String(wpx) + "x" + String(hpx)
                             + " px on the " + ("GPU (gpu2d, Metal)" if on_gpu else "CPU (gpu2d's executor)") + (" (committed, shown when it completes)" if pending else ""))
        self.canvases[k].wpx = wpx
        self.canvases[k].hpx = hpx
        self.canvases[k].drawn = version if not (g[].scene.again or g[].more) else -1  # (mid-animation, or tiles still to raster (D-7993): drawn again next frame, as GTK)
        g[].end_frame()
        self.apply(r[1], self_addr)
        return True

    def gpu2d_shown(mut self, k: Int, at: Int, bounds: CGRect, count: Bool):
        """Canvas k's GPU frame is complete in ring slot `at`: Core Animation shows it (`count`: it's counted now, not
        when it was committed)."""
        ref c = self.canvases[k]
        if c.gpu_frames == 0 or (not count and c.gpu_frames == 1):
            self.report.note("canvas node " + String(c.node) + ": drawn by gpu2d on Metal into an IOSurface, shown without a copy")
        self.layer_show(k, c.surfaces[at], bounds)
        if count:
            self.canvases[k].next = (at + 1) % len(self.canvases[k].surfaces)
            self.canvases[k].gpu_frames += 1
            self.g2d_frames += 1

    def gpu2d_cpu(mut self, k: Int, wpx: Int, hpx: Int, scale: Float64, bounds: CGRect, drawn: Bool):
        """Canvas k's frame by gpu2d's CPU executor (Metal couldn't take it or didn't complete it), shown as pixels; the
        frame's Scene is the renderer's `scene`, or `prev` once end_frame ran (`drawn`)."""
        var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=self.g2d)
        if len(self.canvases[k].pixels) != wpx * hpx:
            self.canvases[k].pixels = List[UInt32](length=wpx * hpx, fill=0)
        else:
            for i in range(wpx * hpx):
                self.canvases[k].pixels[i] = 0
        var surface = Surface(Int(self.canvases[k].pixels.unsafe_ptr()), wpx, hpx, scale)
        if drawn:
            fill_batches(g[].frame, g[].prev, g[].atlas, g[].font)
        else:
            fill_batches(g[].frame, g[].scene, g[].atlas, g[].font)
        execute_cpu(g[].frame, g[].atlas, surface)
        if self.canvases[k].layer != 0:
            _ = msg(self.canvases[k].layer, "setHidden:", 1)
        _ = self.show_pixels(k, wpx, hpx, bounds)

    def finish_ready(mut self):
        """Shows the committed GPU frames the GPU has completed, oldest first, without waiting (the renderer's completed
        handler calls this on the main queue; a frame's end calls it too)."""
        if self.g2d == 0:
            return
        var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=self.g2d)
        while len(self.g2d_pk) > 0 and g[].metal.oldest_done():
            self.show_oldest()

    def finish_gpu2d(mut self, keep: Int):
        """GPU frames draw_gpu2d committed (g2d_defer) are waited for, oldest first, and handed to Core Animation until
        `keep` are left in flight (the picture is whole when CA gets it, D-7532; the main thread never waits for a frame
        it just committed, D-7555)."""
        if self.g2d == 0:
            return
        while len(self.g2d_pk) > keep:
            self.show_oldest()

    def show_oldest(mut self):
        """The oldest committed GPU frame, waited for if it's still on the GPU, into Core Animation. A frame the GPU
        didn't complete is drawn by the CPU executor instead when it's the newest."""
        var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=self.g2d)
        var k = self.g2d_pk.pop(0)
        var at = self.g2d_pat.pop(0)
        var s = self.g2d_ps.pop(0)
        var w = self.g2d_pw.pop(0)
        var h = self.g2d_ph.pop(0)
        var scale = self.g2d_pscale.pop(0)
        var bounds = self.g2d_pb.pop(0)
        var t_commit = self.g2d_pt.pop(0)
        var ok = g[].metal.complete_oldest()
        if ok:
            self.g2d_done.append(g[].metal.gpu_ms)
        else:
            self.g2d_failed += 1
            self.g2d_done.append(0.0)  # (its place in commit order kept)
        var same = k < len(self.canvases) and at < len(self.canvases[k].surfaces) and self.canvases[k].surfaces[at] == s
        if not same:  # (the screen was rebuilt in between: that canvas is drawn again from scratch)
            return
        if ok:
            self.gpu2d_shown(k, at, bounds, False)
            self.g2d_shown_ms.append(Float64(Int(now_ns()) - t_commit) / 1e6)
        elif len(self.g2d_pk) == 0:
            self.gpu2d_cpu(k, w, h, scale, bounds, True)

    def offer_iosurface(mut self, k: Int, wpx: Int, hpx: Int, mut surface: Surface):
        """The Mac with its GPU (D-5311): offers this draw an IOSurface to draw into (surface.shared_*), the first of the
        canvas's three that Core Animation isn't showing, locked until show_iosurface. MOJOUI_CANVAS_GPU=0: never."""
        if env("MOJOUI_CANVAS_GPU") == "0" or self.canvases[k].cpu_only:
            return
        ref c = self.canvases[k]
        if c.sw != wpx or c.sh != hpx:
            for s in c.surfaces:  # (released after this draw: the GPU may still hold them, Gpu.draw lets go first)
                c.retired.append(s)
            c.surfaces.clear()
            for _ in range(3):
                var s = io_surface(wpx, hpx)
                if s == 0:
                    break
                c.surfaces.append(s)
            c.sw = wpx
            c.sh = hpx
            c.next = 0
            if len(c.surfaces) < 3:
                self.report.note("canvas node " + String(c.node) + ": no IOSurface of " + String(wpx) + "x" + String(hpx) + " px (the picture is copied)")
                for s in c.surfaces:
                    cfunc[NoneType]("CFRelease", s)
                c.surfaces.clear()
                return
        var pick = -1
        for j in range(3):
            var at = (c.next + j) % 3
            if cfunc[UInt8]("IOSurfaceIsInUse", c.surfaces[at]) == 0:
                pick = at
                break
        if pick < 0:  # (all three still with Core Animation: this frame is copied rather than torn)
            return
        var s = c.surfaces[pick]
        _ = cfunc[Int32]("IOSurfaceLock", s, UInt32(0), 0)
        c.locked = pick
        surface.shared_address = cfunc("IOSurfaceGetBaseAddress", s)
        surface.shared_bytes = cfunc("IOSurfaceGetAllocSize", s)
        surface.shared_row = cfunc("IOSurfaceGetBytesPerRow", s) // 4
        surface.shared_id = Int(cfunc[UInt32]("IOSurfaceGetID", s))

    def show_iosurface(mut self, k: Int, surface: Surface, bounds: CGRect) -> Bool:
        """After the app drew: if its drawing code wrote the picture into the offered IOSurface, a sublayer of the canvas
        view shows that IOSurface as its contents (no copy: Core Animation reads the same memory the GPU wrote). False:
        it wasn't offered or wasn't used, and the host shows the pixels as before."""
        ref c = self.canvases[k]
        for x in c.retired:  # (the old size's: this draw's Gpu.draw has let go of their wraps)
            cfunc[NoneType]("CFRelease", x)
        c.retired.clear()
        if c.locked < 0:
            return False
        var s = c.surfaces[c.locked]
        _ = cfunc[Int32]("IOSurfaceUnlock", s, UInt32(0), 0)
        var at = c.locked
        c.locked = -1
        if surface.gpu_address == 0 or surface.gpu_address != surface.shared_address:
            if c.layer != 0:
                _ = msg(c.layer, "setHidden:", 1)
            elif c.gpu_frames == 0:  # (never drawn on the GPU yet: its IOSurfaces go now, made again if offered again;
                c.misses += 1  # after MISSES such draws it counts as a CPU canvas and isn't offered any more)
                c.cpu_only = c.misses >= MISSES
                for x in c.surfaces:
                    cfunc[NoneType]("CFRelease", x)
                c.surfaces.clear()
                c.sw = 0
                c.sh = 0
            return False
        if c.layer == 0:
            self.report.note("canvas node " + String(c.node) + ": its GPU picture is shown from an IOSurface (Metal, no copy)")
            print("mojoui: GPU canvas pictures go to the screen without a copy (Metal draws into an IOSurface; Core Animation shows it)", flush=True)
        self.layer_show(k, s, bounds)
        self.canvases[k].next = (at + 1) % 3
        self.canvases[k].gpu_frames += 1
        return True

    def send(mut self, node: Int, second: Bool, text: String, number: Int, self_addr: Int):
        """A control changed: build the event, run update(), patch the controls."""
        ref n = self.rt.shown.nodes[node]
        var message = n.msg2 if second else n.msg
        if message == 0:
            return
        self.focus = node if n.kind == FIELD else -1
        if self.report.on:
            self.report.cause = kind_name(n.kind) + " " + n.text
            self.report.note("event: " + kind_name(n.kind) + " '" + n.text + "' (node " + String(node) + ")" + (" text '" + text + "'" if text != "" else "") + (" number " + String(number) if number != 0 else ""))
        var d = self.rt.dispatch(Event(message, text, number))
        self.apply(d, self_addr)

    # ---------- WebComponents (goal 34b M2: mojoui/hosts/appkit_webview.mojo) ----------

    def place_webview(mut self, i: Int, box: Int, self_addr: Int):
        """WebComponent node i's WKWebView into its box: the one its key (tag, id) already has (moved from the old
        screen's box: it is never loaded again), or a new one. Without WebKit the box keeps its `instead` view."""
        ref n = self.rt.shown.nodes[i]
        if not is_widget_tag(n.hint) or not webviews_start(self.webviews, Self.A.web_assets(), self.target, self_addr):
            return
        var mw = mac_at(self.webviews)
        var k = mw[].core.slot_of(n.hint, n.value)
        if k < 0:
            k = webview_new(self.webviews, n.hint, n.value)
        var view = mw[].core.slots[k].view
        var parent = msg(view, "superview")
        if parent != box:
            if parent != 0:
                var fr = msg(self.window, "firstResponder") if self.window != 0 else 0
                if fr != 0 and (fr == view or ((msg(fr, "isKindOfClass:", cls("NSView")) & 0xFF) != 0 and (msg(fr, "isDescendantOf:", view) & 0xFF) != 0)):
                    self.web_focus = view  # (someone is typing in it: the keyboard follows it into the new screen)
                _ = msg(view, "removeFromSuperview")
            _ = msg(box, "setDetachesHiddenViews:", 1)
            _ = msg(box, "addArrangedSubview:", view)
            _ = msg(msg(msg(view, "widthAnchor"), "constraintEqualToAnchor:", msg(box, "widthAnchor")), "setActive:", 1)
        if mw[].core.slots[k].gone:  # (its web process ended twice: the stand-in shows, D-621)
            webview_instead(view)
            return
        _ = msg(view, "setHidden:", 0)
        var views = msg(box, "arrangedSubviews")
        for j in range(msg(views, "count")):  # (the stand-in stays built, hidden)
            var v = msg(views, "objectAtIndex:", j)
            if v != view:
                _ = msg(v, "setHidden:", 1)

    def system_dark(self) -> Bool:
        """Whether the system (or the app's NSApp appearance, which a test step sets) is in dark mode."""
        var app = msg(cls("NSApplication"), "sharedApplication")
        var look = msg(app, "effectiveAppearance")
        return look != 0 and "Dark" in from_ns(msg(look, "name"))

    def follow_appearance(mut self, self_addr: Int, said: Int = -1):
        """The system's light/dark mode, told to the app (App.appearance) when the window opens and whenever it changes
        (a run-loop turn after the system says so, never inside its notification); the screen follows (apply). `said`
        (1 dark, 0 light): the mode just set, which effectiveAppearance only reports a run-loop turn later."""
        var dark = self.system_dark() if said < 0 else said == 1
        if (1 if dark else 0) == self.dark_told:
            return
        var first = self.dark_told < 0
        self.dark_told = 1 if dark else 0
        var d = self.rt.appearance(dark)
        if not first:
            if self.report.on:
                self.report.cause = "appearance " + ("dark" if dark else "light")
            self.apply(d, self_addr)

    def sync_webviews(mut self, self_addr: Int):
        """After a build or patches: each shown WebComponent's page gets the theme and its props when they changed (JSON,
        through mojoui.native.receive: the widget's update(), never a remount); views whose key left go; commands go out."""
        var mw = mac_at(self.webviews)
        if mw[].core.state != 1:
            self.send_commands(self_addr)
            return
        for ref slot in mw[].core.slots:
            slot.seen = False
        var theme_key = String("")
        var theme_msg = String("")
        for i in range(len(self.rt.shown.nodes)):
            ref n = self.rt.shown.nodes[i]
            if n.kind != WEBCOMP:
                continue
            var k = mw[].core.slot_of(n.hint, n.value)
            if k < 0:
                continue
            mw[].core.slots[k].seen = True
            if theme_msg == "":
                var t = self.rt.app.theme()
                theme_key = t.key()
                theme_msg = theme_message(t)
            if mw[].core.slots[k].theme != theme_key:
                mw[].core.slots[k].theme = theme_key
                webview_send(self.webviews, k, theme_msg)
            if mw[].core.slots[k].props != n.text:
                mw[].core.slots[k].props = n.text
                webview_send(self.webviews, k, '{"widget":{"tag":' + json_string(n.hint) + ',"id":' + String(n.value) + ',"props":' + json_string(n.text) + "}}")
        var k = len(mw[].core.slots) - 1
        while k >= 0:
            if not mw[].core.slots[k].seen:
                if mw[].core.slots[k].view == self.web_focus:
                    self.web_focus = 0
                webview_drop(self.webviews, k)
            k -= 1
        if self.web_focus != 0 and msg(self.web_focus, "window") != 0:
            _ = msg(msg(self.web_focus, "window"), "makeFirstResponder:", self.web_focus)
            self.web_focus = 0
        self.send_commands(self_addr)

    def send_commands(mut self, self_addr: Int):
        """The widget commands the app asked for, each to its widget's page; one whose widget isn't on the screen is
        answered with an error (through the inbox, on the next run-loop turn, as a page's reply is)."""
        for url in self.rt.take_opens():  # (pages the app asked for: mojoui.browser)
            _ = browser_open_url(url)
        var commands = self.rt.take_commands()
        if len(commands) == 0:
            return
        var mw = mac_at(self.webviews)
        for c in commands:
            var k = mw[].core.slot_of(c.tag, c.widget) if mw[].core.state == 1 else -1
            if k >= 0:
                if c.reply != NO_MSG or c.name == "mojoui.set":  # (an agent's set: its answer is taken, then dropped by the runtime, D-636)
                    mw[].core.sent_to(c.seq, c.tag, c.widget)  # (only this widget's page may answer it, D-620)
                webview_send(self.webviews, k, '{"commands":[' + c.json() + "]}")
            elif c.reply != NO_MSG:
                var why = "no widget " + c.tag + "#" + String(c.widget) + " on the screen" + ("" if mw[].core.state == 1 else " (no WebKit)")
                mw[].core.inbox.append(Inbound(IN_REPLY, c.tag, c.widget, "", "null", c.seq, why))
                mw[].target = self.target
                mw[].host_addr = self_addr
                webview_arm(self.webviews)

    def webview_inbox(mut self, self_addr: Int):
        """Hands the pages' events and replies to update(), in order (by key, not node number: the screen may have been
        rebuilt since, D-595)."""
        var mw = mac_at(self.webviews)
        mw[].core.armed = False
        while len(mw[].core.inbox) > 0:
            var m = mw[].core.inbox.pop(0)
            if m.kind == IN_EVENT:
                for i in range(len(self.rt.shown.nodes)):
                    if self.rt.shown.nodes[i].kind == WEBCOMP and self.rt.shown.nodes[i].hint == m.tag and self.rt.shown.nodes[i].value == m.id:
                        if self.report.on:
                            self.report.cause = "widget " + m.tag + " " + m.name
                        self.apply(self.rt.widget_event(i, m.name, m.data), self_addr)
                        break
            elif self.rt.knows_reply(m.seq):
                if self.report.on:
                    self.report.cause = "reply " + m.tag
                self.apply(self.rt.reply(m.seq, m.data, m.error), self_addr)


def kind_name(kind: Int) -> String:
    """A node's kind, for the report."""
    var names: List[Tuple[Int, String]] = [(TEXT, "Text"), (BUTTON, "Button"), (VSTACK, "VStack"), (HSTACK, "HStack"), (SPACER, "Spacer"), (FIELD, "TextField"),
        (TOGGLE, "Toggle"), (DROPDOWN, "Dropdown"), (SLIDER, "Slider"), (PROGRESS, "Progress"), (DIVIDER, "Divider"), (SCROLL, "Scroll"), (IMAGE, "Image"),
        (SEGMENTED, "Segmented"), (RADIO, "Radio"), (TEXTAREA, "TextArea"), (ALERT, "Alert"), (TABS, "Tabs"), (NAVBAR, "NavBar"), (DATE, "Date"),
        (ICON, "Icon"), (GRID, "Grid"), (LAZYLIST, "LazyList"), (CANVAS, "Canvas"), (BOARD, "Board"), (OVERLAY, "Overlay"), (MENUBAR, "MenuBar"),
        (MENU, "Menu"), (ITEM, "Item"), (DIALOG, "Dialog"), (TOAST, "Toast"), (POPOVER, "Popover"), (CLIPBOARD, "Clipboard"), (TABLE, "Table"), (ROUTE, "Route"), (WEBCOMP, "WebComponent")]
    for p in names:
        if p[0] == kind:
            return p[1]
    return "kind" + String(kind)


def gesture_name(kind: Int) -> String:
    if kind == TAP: return "tap"
    if kind == DOUBLE: return "double-tap"
    if kind == PRESS: return "press"
    if kind == RELEASE: return "release"
    if kind == SECONDARY: return "right-click"
    if kind == KEY: return "key"
    if kind == WHEEL: return "wheel"
    return "gesture" + String(kind)


def hug(view: Int, priority: Float32, vertical: Bool):
    """How firmly a view keeps its own size along a stack; a stack view (a padded leaf's wrapper too) hugs its views
    by a priority of its own."""
    var orientation = 1 if vertical else 0
    _ = msg(view, "setContentHuggingPriority:forOrientation:", priority, orientation)
    if msg[Int8](view, "respondsToSelector:", sel("setHuggingPriority:forOrientation:")) != 0:
        if Int(msg(view, "orientation")) == orientation:  # along its own axis: it hugs its first and last views
            _ = msg(view, "setHuggingPriority:forOrientation:", priority, orientation)
            if priority > Float32(250):  # and keeps its own length by a weak shrink-to-fit: a stack has no intrinsic size, so
                # a row's fill distribution gave the console's crumbs (82 pt of words) the bar's free 650 pt and its Spacer
                # none (D-513); 251: over a Spacer's 1, under a label's 750 resistance
                var along = msg(msg(view, "heightAnchor" if vertical else "widthAnchor"), "constraintEqualToConstant:", Float64(0))
                _ = msg(along, "setPriority:", Float32(251))
                _ = msg(along, "setActive:", 1)
        else:
            # across its axis a stack's hugging pins every view's two edges to its own (NSStackView.Edge.Min, at that
            # priority): above a view's own resistance it stands each view as tall as the tallest (the console's app bar
            # at 750 stood brand, crumbs and the beacon slot 60 high: run 40299704650's constraint dump). So across, it
            # pulls at most 250 and keeps its own size by a weak shrink-to-fit instead, just above that pull (D-507)
            _ = msg(view, "setHuggingPriority:forOrientation:", min(priority, Float32(250)), orientation)
            if priority > Float32(250):
                var side = "heightAnchor" if vertical else "widthAnchor"
                var fit = msg(msg(view, side), "constraintEqualToConstant:", Float64(0))
                _ = msg(fit, "setPriority:", Float32(251))
                _ = msg(fit, "setActive:", 1)
                # its insets hold across, required (they were the Edge.Min pins' only: a padded chip lost its padding)
                var ins = msg[CGRect](view, "edgeInsets")  # (top, left, bottom, right)
                var pad = (ins.x + ins.width) if vertical else (ins.y + ins.height)
                var views = msg(view, "arrangedSubviews")
                for j in range(msg(views, "count")):
                    var v = msg(views, "objectAtIndex:", j)
                    _ = msg(msg(msg(view, side), "constraintGreaterThanOrEqualToAnchor:constant:", msg(v, side), pad), "setActive:", 1)


def hold_insets(stack: Int, priority: Float32 = Float32(1000)):
    """A stack's edge insets across its axis, required: NSStackView keeps them only by its hugging's Edge.Min pins (250
    across), so any weak shrink above that, an ancestor's, took a padded cell's padding away (run 40308229281: a dense
    table's head row 22 high for 38, D-515)."""
    var ins = msg[CGRect](stack, "edgeInsets")  # (top, left, bottom, right)
    var vertical_stack = Int(msg(stack, "orientation")) == 1
    var pad = (ins.y + ins.height) if vertical_stack else (ins.x + ins.width)
    if pad <= 0:
        return
    var side = "widthAnchor" if vertical_stack else "heightAnchor"
    var views = msg(stack, "arrangedSubviews")
    for j in range(msg(views, "count")):
        var v = msg(views, "objectAtIndex:", j)
        var held = msg(msg(stack, side), "constraintGreaterThanOrEqualToAnchor:constant:", msg(v, side), pad)
        if priority < 1000:  # (a row given its own height lets a taller view stand out of it, as the web's overflow, D-559)
            _ = msg(held, "setPriority:", priority)
        _ = msg(held, "setActive:", 1)


def flexible_spacer(vertical: Bool) -> Int:
    """An empty view that soaks up free space along a stack (for justify)."""
    var v = new("NSView")
    _ = msg(v, "setContentHuggingPriority:forOrientation:", Float32(1), 1 if vertical else 0)
    return v


def ns_image(pixels: List[UInt32], width: Int, height: Int) -> Int:
    """An NSImage from RGBA pixels, via PNG bytes made in Mojo (mojoui/png.mojo)."""
    var data = ns_data(encode_png(pixels, width, height))
    return msg(msg(msg(cls("NSImage"), "alloc"), "initWithData:", data), "autorelease")


def on_focus_field(target: Int, cmd: Int, field: Int) abi("C"):
    """Focuses a text field and puts the cursor at the end (not select-all)."""
    var window = msg(field, "window")
    if window == 0:
        return
    _ = msg(window, "makeFirstResponder:", field)
    var editor = msg(field, "currentEditor")
    if editor != 0:
        var length = msg(msg(field, "stringValue"), "length")
        _ = msg(editor, "setSelectedRange:", length, 0)  # NSRange {location, length} in two registers


def from_tag(control: Int) -> Tuple[Int, Int]:
    var tag = msg(control, "tag")
    return (tag >> NODE_BITS, tag & ((1 << NODE_BITS) - 1))


def host_at[A: App](addr: Int) -> Pointer[AppKitHost[A], MutUntrackedOrigin]:
    return Pointer[AppKitHost[A], MutUntrackedOrigin](unsafe_from_address=addr)


# ---------- MojoTarget methods (AppKit calls these) ----------

# ---------- MojoCanvas methods (self is the canvas view; its tag says host + node) ----------

def in_view(view: Int, p: CGPoint) -> CGPoint:
    """AppKit's y runs upwards; canvases count from the top-left."""
    return CGPoint(p.x, msg[CGRect](view, "bounds").height - p.y)


def on_gpu2d_done[A: App](host_addr: Int) abi("C"):
    """On the main queue: a GPU frame committed without waiting has completed; it's shown now (D-7555)."""
    host_at[A](host_addr)[].finish_ready()


def on_canvas_frame[A: App](view: Int, cmd: Int, timer: Int) abi("C"):
    var t = from_tag(view)
    host_at[A](t[0])[].tick(msg[Float64](msg(cls("NSProcessInfo"), "processInfo"), "systemUptime"), t[0])


def on_canvas_resized[A: App](view: Int, cmd: Int, notification: Int) abi("C"):
    var t = from_tag(view)
    host_at[A](t[0])[].wake()


def on_canvas_pan[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    """A drag: PRESS where it starts, PANs while it moves, RELEASE where it ends (as GTK sends them)."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var state = msg(recognizer, "state")
    var at = in_view(view, msg[CGPoint](recognizer, "locationInView:", view))
    var k = host[].canvas_at(t[1])
    if state == 1:  # began
        _ = msg(msg(view, "window"), "makeFirstResponder:", view)  # the keyboard, too
        if k >= 0:
            host[].canvases[k].moved = False
        host[].canvas_send(t[1], PRESS, at.x, at.y, 0, 0, 1, t[0])
        return
    if state == 3 or state == 4:  # ended or cancelled
        if k < 0 or host[].canvases[k].moved:
            host[].canvas_send(t[1], RELEASE, at.x, at.y, 0, 0, 1, t[0])
        return
    var moved = msg[CGPoint](recognizer, "translationInView:", view)
    _ = msg(recognizer, "setTranslation:inView:", Float64(0), Float64(0), view)  # deltas from here on
    if k >= 0 and abs(moved.x) + abs(moved.y) > 0:
        host[].canvases[k].moved = True
    host[].canvas_send(t[1], PAN, at.x, at.y, moved.x, -moved.y, 1, t[0])


def event_point(view: Int, event: Int) -> CGPoint:
    """A mouse event's point in a canvas, from its top-left."""
    var w = msg[CGPoint](event, "locationInWindow")
    return in_view(view, msg[CGPoint](view, "convertPoint:fromView:", w.x, w.y, 0))


def pen_pressure(event: Int) -> Float64:
    """A tablet pen's pressure (0–1) on a mouse event; 0 for a mouse or trackpad (their pressure is 0 or 1, not a
    pressure): only NSEventSubtypeTabletPoint (1) events carry one. Goal 40; built, not run on a Mac yet."""
    if msg(event, "subtype") != 1:
        return 0
    return min(max(Float64(msg[Float32](event, "pressure")), 0.0), 1.0)


def on_canvas_mouse_moved[A: App](view: Int, cmd: Int, event: Int) abi("C"):
    """(goal 79) The pointer moved over the canvas, no button held: HOVER there (apps draw hover states), as GTK's motion."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var at = event_point(view, event)
    var b = msg[CGRect](view, "bounds")
    if at.x < 0 or at.y < 0 or at.x > b.width or at.y > b.height:
        host[].canvas_send(t[1], HOVER, -1, -1, 0, 0, 1, t[0])
        return
    host[].canvas_send(t[1], HOVER, at.x, at.y, 0, 0, 1, t[0])


def on_canvas_mouse_down[A: App](view: Int, cmd: Int, event: Int) abi("C"):
    """The button goes down: PRESS there at once (GTK's drag-begin), or DOUBLE on a second click."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    _ = msg(msg(view, "window"), "makeFirstResponder:", view)  # the keyboard, too
    var at = event_point(view, event)
    var k = host[].canvas_at(t[1])
    if k >= 0:
        host[].canvases[k].moved = False
        host[].canvases[k].last_x = at.x
        host[].canvases[k].last_y = at.y
    if msg(event, "clickCount") >= 2:
        host[].canvas_send(t[1], DOUBLE, at.x, at.y, 0, 0, 1, t[0])
        return
    host[].canvas_send(t[1], PRESS, at.x, at.y, 0, 0, 1, t[0], pen_pressure(event))


def on_canvas_mouse_dragged[A: App](view: Int, cmd: Int, event: Int) abi("C"):
    """The pointer moves with the button down: PAN by how far it moved since the last event."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var at = event_point(view, event)
    var k = host[].canvas_at(t[1])
    if k < 0:
        return
    var dx = at.x - host[].canvases[k].last_x
    var dy = at.y - host[].canvases[k].last_y
    if dx == 0 and dy == 0:
        return
    host[].canvases[k].moved = True
    host[].canvases[k].last_x = at.x
    host[].canvases[k].last_y = at.y
    host[].canvas_send(t[1], PAN, at.x, at.y, dx, dy, 1, t[0], pen_pressure(event))


def on_canvas_mouse_up[A: App](view: Int, cmd: Int, event: Int) abi("C"):
    """The button comes up: RELEASE after a drag, TAP after a click (as GTK's click gesture's released)."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var at = event_point(view, event)
    var k = host[].canvas_at(t[1])
    if k >= 0 and host[].canvases[k].moved:
        host[].canvas_send(t[1], RELEASE, at.x, at.y, 0, 0, 1, t[0], pen_pressure(event))
    elif msg(event, "clickCount") < 2:
        host[].canvas_send(t[1], TAP, at.x, at.y, 0, 0, 1, t[0])


def accepts_first_mouse(view: Int, cmd: Int, event: Int) abi("C") -> Int8:
    return 1  # the first click on a window in the background reaches the canvas too (a select, not just a focus)


def on_canvas_double[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    var t = from_tag(view)
    var at = in_view(view, msg[CGPoint](recognizer, "locationInView:", view))
    host_at[A](t[0])[].canvas_send(t[1], DOUBLE, at.x, at.y, 0, 0, 1, t[0])


def on_canvas_secondary[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    """A right click: SECONDARY, where a context menu opens."""
    var t = from_tag(view)
    var at = in_view(view, msg[CGPoint](recognizer, "locationInView:", view))
    host_at[A](t[0])[].canvas_send(t[1], SECONDARY, at.x, at.y, 0, 0, 1, t[0])


def accepts_first_responder(view: Int, cmd: Int) abi("C") -> Int8:
    return 1  # a canvas takes the keyboard once clicked


def on_canvas_key[A: App](view: Int, cmd: Int, event: Int) abi("C"):
    """keyDown: on a canvas → KEY (the web's key names, GTK's modifier bits)."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    if t[1] >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[t[1]].size != 1:
        return
    var flags = msg(event, "modifierFlags")
    var mods = (1 if flags & MASK_SHIFT != 0 else 0) + (2 if flags & (MASK_COMMAND | (1 << 18)) != 0 else 0) + (4 if flags & MASK_OPTION != 0 else 0)
    var name = key_name_of(event)
    if name == "" or name.byte_length() > 32:
        return
    # (D-7979) a text caret on this canvas: the keystroke goes to the input context first (an input method composes or
    # inserts text through the NSTextInputClient methods; keys it doesn't take come back as doCommandBySelector:)
    if get_shared(SLOT_MAC_IME) != 0 and mods & 2 == 0 and host[].ime_caret(t[1])[0] >= 0:
        host[].ime_key = name
        host[].ime_mods = mods
        var took = shim_call2("mojoui_ime_key", view, event)
        host[].ime_key = ""
        if took != 0:
            return
    host[].canvas_key(t[1], name, mods, t[0])


# ---------- (D-7979) the input methods: bridge/mac_ime.m calls these with scalars only ----------

def paste_board() -> Int:
    """The pasteboard a paste reads: the general one; in test mode a private one (mojoui.test), so a test's clipboard:
    step never replaces what the person copied."""
    if env("MOJOUI_TEST") != "":
        return msg(cls("NSPasteboard"), "pasteboardWithName:", ns_string("mojoui.test"))
    return msg(cls("NSPasteboard"), "generalPasteboard")


def shim_sym(name: String) -> Int:
    """A function of the linked shim (bridge/mac_ime.m) by name; 0 when the build has none."""
    var n = name
    return external_call["dlsym", Int](Int(-2), n.as_c_string_span())  # (RTLD_DEFAULT)


def shim_call2(name: String, a: Int, b: Int) -> Int:
    var f = shim_sym(name)
    if f == 0:
        return 0
    return Pointer(to=f).unsafe_bitcast[def(Int, Int) thin abi("C") -> Int]()[](a, b)


def utf16_len(s: String) -> Int:
    var n = 0
    for cp in s.codepoints():
        n += 2 if Int(cp.to_u32()) > 0xFFFF else 1
    return n


def ime_text_of(utf8: Int, n: Int) -> String:
    var b = List[UInt8](length=n, fill=0)
    if n > 0:
        _ = external_call["memcpy", Int](Int(b.unsafe_ptr()), utf8, n)
    return String(from_utf8_lossy=Span(b))


def ime_marked_cb[A: App](view: Int, utf8: Int, n: Int, sel_loc: Int, sel_len: Int) abi("C"):
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var text = ime_text_of(utf8, n)
    print("IME: marked=\"" + text + "\" selected=" + String(sel_loc) + "," + String(sel_len), flush=True)
    host[].ime_preedit(t[1], text, t[0])


def ime_insert_cb[A: App](view: Int, utf8: Int, n: Int, a: Int, b: Int) abi("C"):
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var text = ime_text_of(utf8, n)
    if host[].ime_key != "" and host[].ime_text == "" and text.byte_length() == 1 and Int(text.as_bytes()[0]) < 32:
        host[].canvas_key(t[1], host[].ime_key, host[].ime_mods, t[0])  # (a control character: the key itself)
        return
    print("IME: insert=\"" + text + "\"", flush=True)
    host[].ime_commit(t[1], text, t[0])


def ime_unmark_cb[A: App](view: Int) abi("C"):
    var t = from_tag(view)
    var host = host_at[A](t[0])
    if host[].ime_text != "":
        var text = host[].ime_text
        host[].ime_commit(t[1], text, t[0])  # (the composition, as it stands, is the text)


def ime_marked_range_cb[A: App](view: Int, loc: Int, len: Int) abi("C") -> Int:
    var t = from_tag(view)
    var host = host_at[A](t[0])
    if host[].ime_text == "" or host[].ime_node != t[1]:
        return 0
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=loc)[] = 0
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=len)[] = utf16_len(host[].ime_text)
    return 1


def ime_selected_range_cb[A: App](view: Int, loc: Int, len: Int) abi("C") -> Int:
    var t = from_tag(view)
    var host = host_at[A](t[0])
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=loc)[] = utf16_len(host[].ime_text) if host[].ime_node == t[1] else 0
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=len)[] = 0
    return 1


def ime_rect_cb[A: App](view: Int, loc: Int, len: Int, xywh: Int) abi("C"):
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var r = host[].ime_caret(t[1])
    var out = Pointer[Float64, MutUntrackedOrigin](unsafe_from_address=xywh)
    out[] = max(r[0], 0.0)
    (out + 1)[] = r[1]
    (out + 2)[] = max(r[2], 1.0)
    (out + 3)[] = max(r[3], 1.0)


def ime_command_cb[A: App](view: Int, selector: Int) abi("C"):
    """doCommandBySelector: the keystroke the input method didn't take (Return, arrows, delete…): the KEY it is."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    if host[].ime_key != "":
        host[].canvas_key(t[1], host[].ime_key, host[].ime_mods, t[0])


def ime_install[A: App](canvas_class: Int) -> Bool:
    """The canvas class becomes an NSTextInputClient (bridge/mac_ime.m) when the shim is linked in."""
    var f = shim_sym("mojoui_ime_install")
    if f == 0:
        return False
    var call = Pointer(to=f).unsafe_bitcast[def(Int, Int, Int, Int, Int, Int, Int, Int) thin abi("C")]()[]
    call(canvas_class, fn_address(ime_marked_cb[A]), fn_address(ime_insert_cb[A]), fn_address(ime_unmark_cb[A]),
         fn_address(ime_marked_range_cb[A]), fn_address(ime_selected_range_cb[A]), fn_address(ime_rect_cb[A]), fn_address(ime_command_cb[A]))
    return True


def process_age_ms() -> Float64:
    """How long ago this process started (ms): its start time from proc_pidinfo (PROC_PIDTBSDINFO's pbi_start_tvsec and
    _tvusec at bytes 120 and 128 of struct proc_bsdinfo) against the wall clock; -1 when it can't be read."""
    var buf = List[UInt64](length=17, fill=0)  # (136 bytes)
    var n = external_call["proc_pidinfo", c_int](c_int(external_call["getpid", c_int]()), c_int(3), UInt64(0), Int(buf.unsafe_ptr()), c_int(136))
    if Int(n) < 136:
        return -1.0
    var tv = List[Int](length=2, fill=0)
    _ = external_call["gettimeofday", c_int](Int(tv.unsafe_ptr()), 0)
    var start_us = Int(buf[15]) * 1_000_000 + Int(buf[16])
    var now_us = tv[0] * 1_000_000 + (tv[1] & 0xFFFFFFFF)
    return Float64(now_us - start_us) / 1000.0


def rss_mb() -> Float64:
    """This process's resident memory (MB): proc_pidinfo's PROC_PIDTASKINFO (pti_resident_size, bytes 8–16)."""
    var buf = List[UInt64](length=12, fill=0)  # (struct proc_taskinfo: 96 bytes)
    var n = external_call["proc_pidinfo", c_int](c_int(external_call["getpid", c_int]()), c_int(4), UInt64(0), Int(buf.unsafe_ptr()), c_int(96))
    if Int(n) < 96:
        return -1.0
    return Float64(Int(buf[1])) / 1048576.0


def print_bench_state[A: App](host_addr: Int, what: String):
    """What macOS thinks of the app while it is measured (MOJOUI_BENCHSTATE=1): is it active, is its window key, is the
    screen locked (-1: not known), is an activity held (D-8023)."""
    var host = host_at[A](host_addr)
    var app = msg(cls("NSApplication"), "sharedApplication")
    var locked = -1
    var name = String("CGSessionCopyCurrentDictionary")
    var found = external_call["dlsym", Int](RTLD_DEFAULT, name.as_c_string_span())  # RTLD_DEFAULT
    if found != 0:
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=found)
        var d = Pointer(to=raw).unsafe_bitcast[def() thin abi("C") -> Int]()[]()
        if d != 0:
            var v = msg(d, "objectForKey:", ns_string("CGSSessionScreenIsLocked"))
            locked = msg(v, "intValue") if v != 0 else 0
            _ = msg(d, "release")
    print("BENCHSTATE: " + what + " active=" + String(Int(msg[Int8](app, "isActive"))) + " key=" + String(Int(msg[Int8](host[].window, "isKeyWindow")) if host[].window != 0 else -1)
          + " locked=" + String(locked) + " activity=" + String(host[].activity.mode) + (" held" if host[].activity.token != 0 else " not held"), flush=True)


def app_step_bench[A: App](host_addr: Int, label: String, what: String, n: Int):
    """noteswitch:N / omnibar:N / openall: as GTK's (D-7988): App.bench(first canvas, "bench:<what>") changes the app's
    state N times; each is timed from the call through its frame: the app's step and view, the canvas drawn as the tick
    draws it, AppKit's display and commit, and the GPU's time on it. Prints `<LABEL>: n= p50= p95= max=` (ms)."""
    var host = host_at[A](host_addr)
    if len(host[].canvases) == 0:
        print(label + ": no canvas", flush=True)
        return
    if env("MOJOUI_BENCHSTATE") == "1":
        print_bench_state[A](host_addr, label)
    bench_settle[A](host_addr, 500_000_000)
    var times = List[Float64]()
    for _ in range(n):
        var node = host[].canvases[0].node
        var t0 = Int(now_ns())
        host[].input_activity(host_addr)  # (the click or key the step stands for)
        _ = host[].rt.app.bench(host[].rt.shown.nodes[node].style, "bench:" + what)
        var d = host[].rt.refresh()
        host[].apply(d, host_addr)
        var ev = Float64(Int(now_ns()) - t0) / 1e6
        var done0 = len(host[].g2d_done)
        var t1 = Int(now_ns())
        var s0 = slept_ms(host[].g2d)
        if len(host[].canvases) > 0:
            host[].g2d_defer = True
            host[].draw_canvas(0, host_addr)
            host[].g2d_defer = False
        _ = msg(host[].window, "layoutIfNeeded")
        _ = msg(host[].window, "displayIfNeeded")
        host[].finish_frame()
        _ = msg(cls("CATransaction"), "flush")
        var dm = Float64(Int(now_ns()) - t1) / 1e6 - (slept_ms(host[].g2d) - s0)
        host[].finish_gpu2d(0)
        var gms = 0.0
        while len(host[].g2d_done) > done0:
            gms += host[].g2d_done.pop()
        times.append(ev + dm + gms)
        if env("MOJOUI_TRACE_FRAMES") == "1":  # (as GTK's: where a step's time goes)
            print("TRACE: " + label + " step: event " + one_decimal(ev) + " draw " + one_decimal(dm) + " gpu " + one_decimal(gms) + " scene " + one_decimal(host[].g2d_parts[0])
                  + " batch " + one_decimal(host[].g2d_parts[1]) + " rest " + one_decimal(host[].g2d_parts[2]), flush=True)
        bench_settle[A](host_addr, 300_000_000)
    print(label + ": n=" + String(len(times)) + " p50=" + one_decimal(pct(times, 0.5)) + " p95=" + one_decimal(pct(times, 0.95))
          + " max=" + one_decimal(pct(times, 1.0)), flush=True)


def bench_settle[A: App](host_addr: Int, ns: Int):
    """A bench step's preparation lands: the run loop turns until the host is idle (or ns pass)."""
    var host = host_at[A](host_addr)
    var by = Int(now_ns()) + ns
    while Int(now_ns()) < by:
        pump_run_loop(0.005)
        if host[].idle():
            break


def is_flipped(view: Int, cmd: Int) abi("C") -> Int8:
    return 1  # a Board's content and a scroll view's clip count y from the top, like every other host


def top_scroll_view(across: Bool) -> Int:
    """A scroll view whose clip view counts y from the top: content shorter than the view sits at its top, as on every
    other host (AppKit's own clip view keeps it at the bottom: the owner's Report and inspector pages, 2026-10-23)."""
    var w = new("NSScrollView")
    _ = msg(w, "setContentView:", new("MojoTopClipView"))
    # Overlay scroll bars, whatever the system setting: a Mac with a mouse (GitHub's Macs) shows legacy bars that take
    # 15 pt beside the content; the app sizes the content to its window, so AppKit widened the window by those points,
    # the app filled the new width, and the window grew without end (2026-10-23).
    # (AppKit keeps the person's own choice over this: with "Show scroll bars: Always", or a mouse and "Automatically",
    # the bars are legacy and take 17 pt from the clip whatever is set here; the dump's "bars 0", 2026-10-25. Bars that
    # hide while the content fits leave no white corner where two would meet.)
    _ = msg(w, "setHasVerticalScroller:", 1)
    if across:
        _ = msg(w, "setHasHorizontalScroller:", 1)
    _ = msg(w, "setAutohidesScrollers:", 1)
    _ = msg(w, "setScrollerStyle:", 1)  # NSScrollerStyleOverlay
    return w


def on_canvas_pinch[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var k = host[].canvas_at(t[1])
    if k < 0:
        return
    var m = msg[Float64](recognizer, "magnification")  # 0 at the start of each pinch
    if msg(recognizer, "state") == 1:  # began
        host[].canvases[k].pinch = 0
    var factor = (1 + m) / (1 + host[].canvases[k].pinch)
    host[].canvases[k].pinch = m
    var at = in_view(view, msg[CGPoint](recognizer, "locationInView:", view))
    host[].canvas_send(t[1], ZOOM, at.x, at.y, 0, 0, factor, t[0])


def on_canvas_tap[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    var t = from_tag(view)
    var at = in_view(view, msg[CGPoint](recognizer, "locationInView:", view))
    host_at[A](t[0])[].canvas_send(t[1], TAP, at.x, at.y, 0, 0, 1, t[0])


def on_canvas_scroll[A: App](view: Int, cmd: Int, event: Int) abi("C"):
    """Mouse wheel (4 notches = 2×) or trackpad scroll (pixels): zoom around the pointer. On a Canvas(scroll_pans=True)
    a plain scroll pans (WHEEL: AppKit's scrolling deltas already say how the content moves; a line = 40 points) and
    Command/Control+scroll zooms (built, not run: goal 40)."""
    var t = from_tag(view)
    var dy = msg[Float64](event, "scrollingDeltaY")
    var precise = (msg(event, "hasPreciseScrollingDeltas") & 0xFF) != 0
    var window_point = msg[CGPoint](event, "locationInWindow")
    var at = in_view(view, msg[CGPoint](view, "convertPoint:fromView:", window_point.x, window_point.y, 0))
    var host = host_at[A](t[0])
    var flags = msg(event, "modifierFlags")
    if t[1] < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[t[1]].spacing == 1 and flags & (MASK_COMMAND | (1 << 18)) == 0:
        var step = 1.0 if precise else 40.0
        host[].canvas_send(t[1], WHEEL, at.x, at.y, msg[Float64](event, "scrollingDeltaX") * step, dy * step, 1, t[0])
        return
    var notches = dy / 100.0 * 4.0 if precise else dy
    host_at[A](t[0])[].canvas_send(t[1], ZOOM, at.x, at.y, 0, 0, 2.0 ** (notches / 4.0), t[0])


def on_tap[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], False, "", 0, t[0])


def on_paragraph_tap[A: App](target: Int, cmd: Int, recognizer: Int) abi("C"):
    """A click on a Paragraph: the character under it (the label's words laid out again in its width, as its cell lays
    them: 2 pt in), the run holding it; a link's run sends on_link (event.number = the run, event.text = its href), or
    opens the href when the app doesn't listen."""
    var label = msg(recognizer, "view")
    var t = from_tag(label)
    var host = host_at[A](t[0])
    if t[1] >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[t[1]].kind != PARAGRAPH:
        return
    var at = in_view(label, msg[CGPoint](recognizer, "locationInView:", label))
    var bounds = msg[CGRect](label, "bounds")
    var storage = msg(msg(cls("NSTextStorage"), "alloc"), "initWithAttributedString:", msg(label, "attributedStringValue"))
    var layout = new("NSLayoutManager")
    var box = msg(msg(cls("NSTextContainer"), "alloc"), "initWithSize:", bounds.width - 4, Float64(100000))
    _ = msg(box, "setLineFragmentPadding:", Float64(0))
    _ = msg(layout, "addTextContainer:", box)
    _ = msg(storage, "addLayoutManager:", layout)
    var glyph = msg(layout, "glyphIndexForPoint:inTextContainer:", at.x - 2, at.y, box)
    var index = msg(layout, "characterIndexForGlyphAtIndex:", glyph)
    var runs = runs_of(host[].rt.shown.nodes[t[1]])
    var start = 0
    for k in range(len(runs)):
        var n = msg(ns_string(runs[k].text), "length")  # (UTF-16 units, as the string counts)
        if index < start + n:
            var href = link_href(host[].rt.shown.nodes[t[1]], k)
            if href == "":
                return
            if host[].rt.shown.nodes[t[1]].msg == 0:
                if is_web_url(href):  # (http and https only, D-576)
                    _ = msg(msg(cls("NSWorkspace"), "sharedWorkspace"), "openURL:", msg(cls("NSURL"), "URLWithString:", ns_string(href)))
                return
            host[].send(t[1], False, href, k, t[0])
            return
        start += n


def on_menu_item[A: App](target: Int, cmd: Int, item: Int) abi("C"):
    """A menu bar item (or its ⌘ shortcut): the ITEM node its tag names."""
    var t = from_tag(item)
    var host = host_at[A](t[0])
    if t[1] < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[t[1]].kind == ITEM:
        host[].send(t[1], False, "", 0, t[0])


def on_debug_record[A: App](target: Int, cmd: Int, item: Int) abi("C"):
    """Debug → Record a report: from now on, a picture and a view dump after every change."""
    var host = host_at[A](msg(item, "tag"))
    host[].start_report()
    host[].report.cause = "record"
    host[].snapshot()


def on_debug_snapshot[A: App](target: Int, cmd: Int, item: Int) abi("C"):
    var host = host_at[A](msg(item, "tag"))
    host[].start_report()
    host[].report.cause = "snapshot"
    host[].snapshot()


def on_debug_open[A: App](target: Int, cmd: Int, item: Int) abi("C"):
    var host = host_at[A](msg(item, "tag"))
    host[].start_report()
    _ = msg(msg(cls("NSWorkspace"), "sharedWorkspace"), "openURL:", msg(cls("NSURL"), "fileURLWithPath:", ns_string(host[].report.dir)))


def on_activity_due[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    var addr = msg(number, "longLongValue")
    if host_at[A](addr)[].activity.due():
        _ = msg(target, "performSelector:withObject:afterDelay:", sel("activityDue:"), number, host_at[A](addr)[].activity.due_in())


def on_effects_due[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    """The runtime's effects are due: replies and ticks go to update(), the screen catches up, the next call is set."""
    var addr = msg(number, "longLongValue")
    var host = host_at[A](addr)
    host[].fx_due = -1
    var d = host[].rt.poll(now_ns() // 1000)
    host[].apply(d, addr)


def on_debug_queued[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    host_at[A](msg(number, "longLongValue"))[].snapshot()


def env(name: String) -> String:
    var n = name
    var p = external_call["getenv", Int](n.as_c_string_span())
    if p == 0:
        return ""
    return from_ns(msg(cls("NSString"), "stringWithUTF8String:", p))


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


def to_float(s: String) -> Float64:
    try:
        return atof(s)
    except:
        return 0


def web_key(name: String) -> String:
    """A test step's key name as the web names it (what keyDown: sends): GDK's names (Return, BackSpace, Down…) mapped
    as GTK's gdk_keyval and key_name map them; web names and characters pass through."""
    var gdk: List[String] = ["Down", "Up", "Left", "Right", "Return", "KP_Enter", "Escape", "Tab", "ISO_Left_Tab",
                             "BackSpace", "Delete", "Page_Down", "Page_Up", "Home", "End", "space"]
    var web: List[String] = ["ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight", "Enter", "Enter", "Escape", "Tab", "Tab",
                             "Backspace", "Delete", "PageDown", "PageUp", "Home", "End", " "]
    for i in range(len(gdk)):
        if name == gdk[i]:
            return web[i]
    return name


def canvas_key_step[A: App](host_addr: Int, which: String, name: String, mods: Int):
    """One KEY on the canvas tagged `which`, as keyDown: sends it (the canvas looked up again: a key may rebuild)."""
    var host = host_at[A](host_addr)
    var node = canvas_node_at(host[], which)
    if node < 0:
        return
    host[].canvas_key(node, name, mods, host_addr)


def pct(xs: List[Float64], q: Float64) -> Float64:
    """The q-th quantile of xs (0 when empty), as GTK's framebench takes it."""
    if len(xs) == 0:
        return 0
    var v = xs.copy()
    sort(v)
    return v[min(len(v) - 1, Int(q * Float64(len(v))))]


def one_decimal(v: Float64) -> String:
    var tenths = Int(v * 10 + (0.5 if v >= 0 else -0.5))
    var sign = "-" if tenths < 0 else ""
    tenths = abs(tenths)
    return sign + String(tenths // 10) + "." + String(tenths % 10)


def pump_run_loop(seconds: Float64):
    """Lets the run loop handle what's due (the window server's events, timers) for at most `seconds`."""
    _ = msg(msg(cls("NSRunLoop"), "currentRunLoop"), "runMode:beforeDate:", ns_string("kCFRunLoopDefaultMode"),
            msg(cls("NSDate"), "dateWithTimeIntervalSinceNow:", seconds))


def frame_bench[A: App](host_addr: Int, rest: String):
    """framebench:K=pan|zoom|draw|finish|type|grow,N (goal 75, GTK's recipes): N gestures on canvas K, one at a time
    (PAN by 7,4 points, to and fro every 20; ZOOM by 1.01× around the middle, in then out; draw: one pen stroke of N
    moves; finish: short strokes, press, three moves, release; type: N characters of "native mojo is fast "; grow: per
    topic Tab (the first) or Enter, "t", Enter, then Space twice), each followed by the frame that shows it, done
    synchronously. A frame's work = the gesture's handling (update and the diff, plus a frame event when the canvas asks
    for them, as the tick sends) + the canvas's draw (the app's draw() into its pixels or the offered IOSurface, and the
    picture handed to AppKit: a CGImage in the image view, or the IOSurface as a layer's contents) + the paint (the
    window's displayIfNeeded and a CATransaction flush: the layer tree committed to the render server). The window
    server's compositing after the commit isn't in it. The 60 Hz timer is stopped while it runs (its tick would draw
    outside the timing). Prints GTK's FRAMEBENCH line; renderer= AppKit-IOSurface (every frame on the GPU's
    IOSurface), AppKit-CPU (every frame a CGImage of the CPU's pixels) or AppKit-mixed."""
    var host = host_at[A](host_addr)
    var kv = split_at(rest, "=")
    var spec = split_at(kv[1], ",")
    var what = spec[0] if spec[0] != "typing" else String("type")  # (GTK's name for the same step)
    var count = max(to_int(spec[1]), 1)
    var tag = kv[0]
    var node = canvas_node_at(host[], tag)
    var k = host[].canvas_at(node) if node >= 0 else -1
    if k < 0:
        print("TEST: no canvas", tag, flush=True)
        return
    var wait_by = Int(now_ns()) + 3_000_000_000  # (from a drawn, quiet canvas)
    while not host[].idle() and Int(now_ns()) < wait_by:
        pump_run_loop(0.005)
    if host[].link != 0:
        _ = msg(host[].link, "invalidate")
        host[].link = 0
    node = canvas_node_at(host[], tag)
    k = host[].canvas_at(node) if node >= 0 else -1
    if k < 0:
        print("TEST: no canvas", tag, flush=True)
        return
    var b = msg[CGRect](host[].canvases[k].view, "bounds")
    var w = b.width
    var h = b.height
    var grow_keys = List[String]()
    if what == "grow":
        for t in range(count):
            grow_keys.append("Tab" if t == 0 else "Enter")
            grow_keys.append("t")
            grow_keys.append("Enter")
        grow_keys.append(" ")
        grow_keys.append(" ")
        count = len(grow_keys)
    var works = List[Float64]()
    var events = List[Float64]()
    var draws = List[Float64]()
    var paints = List[Float64]()
    var x = w * 0.3
    var y = h * 0.3
    var missed = 0
    var on_gpu = 0
    var on_cpu = 0
    var on_g2d = 0
    var g_scene = List[Float64]()
    var g_batch = List[Float64]()
    var g_metal = List[Float64]()
    var g_gpu = List[Float64]()
    var g_layers = List[String]()
    var diag = List[String]()  # (per frame: event, paint, layout, slept, wall: FRAMES)
    var g2d_at = List[Int]()  # (per frame: which gpu2d frame of this step it is, -1: none)
    var walls = List[Float64]()  # (each frame's wall time, the GPU waits included)  # (per GPU frame: layers rebuilt/kept/grown, polygon groups)
    # (D-7984) the app readies the step first, as on GTK (a tool, a text box: App.bench "bench:<what>"), and for Personal
    # Note's own steps says where (an object to drag, the lead of 40 it selected) or prepares them (a history, a reopen)
    var drag_x0 = x
    var drag_y0 = y
    if what == "pan" or what == "zoom" or what == "draw" or what == "type" or what == "finish":
        _ = host[].rt.app.bench(host[].rt.shown.nodes[node].style, "bench:" + what)
        var d0 = host[].rt.refresh()
        host[].apply(d0, host_addr)
        bench_settle[A](host_addr, 300_000_000)
    if what == "dragone" or what == "drag40" or what == "undoredo" or what == "open" or what == "openpress" or what == "undo" or what == "redo":
        var sp = host[].rt.app.bench(host[].rt.shown.nodes[node].style, "bench:" + (String("open") if what == "openpress" else what))
        var d0 = host[].rt.refresh()
        host[].apply(d0, host_addr)
        bench_settle[A](host_addr, 500_000_000)
        if what == "dragone" or what == "drag40":
            if sp[0] < 0:
                print("FRAMEBENCH: " + tag + "=" + what + " the app gave no spot", flush=True)
                return
            x = sp[0]
            y = sp[1]
            drag_x0 = x
            drag_y0 = y
            count += 2  # (D-8000: the press that lifts and the drop are timed too, as on GTK)
    if what == "draw" or what == "pan":  # (a drag: press, the moves, release; the app's tool decides what it does)
        host[].canvases[k].moved = False
        host[].canvas_send(node, PRESS, x, y, 0, 0, 1, host_addr, 0.6 if what == "draw" else 0.0)
        host[].canvases[k].moved = True
        host[].draw_canvas(k, host_addr)
    var window = host[].window
    host[].finish_gpu2d(0)
    host[].g2d_done.clear()
    host[].g2d_shown_ms.clear()
    var failed0 = host[].g2d_failed
    var inplace0 = host[].labels_in_place
    var trace_dirty = env("MOJOUI_FRAMEBENCH_DIRTY") == "1"  # (diagnosis: which views ask for layout or constraints, frames 0–2)
    var relaid0 = host[].labels_relaid
    var during = List[Float64]()  # (open/openpress, D-7944 as on GTK: each frame after the open's own until it's complete)
    var presses = List[Float64]()  # (openpress: the press during the open, to the frame that shows it)
    var completes = List[Float64]()  # (the open request to the frame that completed it)
    for i in range(count):
        node = canvas_node_at(host[], tag)  # (a rebuild may have renumbered the screen)
        k = host[].canvas_at(node) if node >= 0 else -1
        if k < 0:
            missed += 1
            continue
        var drawn0 = host[].canvases[k].drawn
        var gpu0 = host[].canvases[k].gpu_frames
        var g2d0 = host[].g2d_frames
        take_waits(host[].g2d)  # (the waits before this frame aren't its own)
        var c0 = thread_cpu_ns()
        var ru0 = usage()
        var t0 = Int(now_ns())
        if what == "pan":
            var back = -1.0 if (i // 20) % 2 == 1 else 1.0  # (to and fro: what was on screen stays there)
            host[].canvas_send(node, PAN, x, y, 7 * back, 4 * back, 1, host_addr)
        elif what == "zoom":
            host[].canvas_send(node, ZOOM, w / 2, h / 2, 0, 0, 1.01 if i < count // 2 else 1.0 / 1.01, host_addr)
        elif what == "finish":  # (short strokes: press, three moves, release; each release adds a stroke to the page)
            var step = i % 5
            if step == 0:
                x = w * (0.15 + 0.6 * Float64((i // 5) % 10) / 10.0)
                y = h * (0.2 + 0.6 * Float64((i // 50) % 4) / 4.0)
                host[].canvases[k].moved = False
                host[].canvas_send(node, PRESS, x, y, 0, 0, 1, host_addr, 0.3)
            elif step < 4:
                x += 9.0
                y += 3.0 * Float64(step)
                host[].canvases[k].moved = True
                host[].canvas_send(node, PAN, x, y, 9, 3, 1, host_addr, 0.3 + 0.2 * Float64(step))
            else:
                host[].canvas_send(node, RELEASE, x, y, 0, 0, 1, host_addr, 0.5)
        elif what == "dragone" or what == "drag40":  # (benchmark-f034's dragPath, as GTK's: to +160,+90 (40: +120,+70), a sine of 40 across it)
            if i == 0:
                host[].canvases[k].moved = False
                host[].canvas_send(node, PRESS, x, y, 0, 0, 1, host_addr)
            elif i == count - 1:
                host[].canvas_send(node, RELEASE, x, y, 0, 0, 1, host_addr)
            else:
                host[].canvases[k].moved = True
                var t = Float64(i) / Float64(count - 2)
                var tx = drag_x0 + (160.0 if what == "dragone" else 120.0) * t
                var ty = drag_y0 + (90.0 if what == "dragone" else 70.0) * t + sin(t * 6.283185307) * 40
                host[].canvas_send(node, PAN, tx, ty, tx - x, ty - y, 1, host_addr)
                x = tx
                y = ty
        elif what == "undo" or what == "redo" or what == "undoredo":  # (⌘Z / ⇧⌘Z: one step back or forth each frame; undoredo alternates)
            host[].canvas_key(node, "z", 2 if what == "undo" or (what == "undoredo" and i % 2 == 0) else 3, host_addr)
        elif what == "open" or what == "openpress":  # (the app reopens the note, cold: its first frame is this frame's)
            host[].input_activity(host_addr)  # (the click the open stands for)
            _ = host[].rt.app.bench(host[].rt.shown.nodes[node].style, "bench:reopen")
            var dro = host[].rt.refresh()
            host[].apply(dro, host_addr)
        elif what == "type" or what == "grow":
            var typed = String("native mojo is fast ")
            var ch = String(typed[byte = i % 20 : i % 20 + 1])
            if what == "grow":
                ch = grow_keys[i]
            host[].canvas_key(node, ch, 0, host_addr)
        else:  # draw: a wandering line across the page
            x += 3.0 + Float64(i % 5) * 0.4
            y += 2.0 * (1.0 if (i // 40) % 2 == 0 else -1.0)
            host[].canvas_send(node, PAN, x, y, 3, 2, 1, host_addr, 0.3 + 0.6 * Float64(i % 50) / 50.0)
        node = canvas_node_at(host[], tag)
        k = host[].canvas_at(node) if node >= 0 else -1
        if k >= 0 and host[].rt.shown.nodes[node].msg2 != 0:  # (the frame event the tick would send first)
            var d = host[].rt.frame(node, 16667)
            host[].apply(d, host_addr)
            node = canvas_node_at(host[], tag)
            k = host[].canvas_at(node) if node >= 0 else -1
        var s0 = slept_ms(host[].g2d)
        var t1 = Int(now_ns())
        var drew = False
        if k >= 0:
            if host[].canvases[k].drawn != drawn0:  # (a rebuild made a new canvas: its picture is drawn from scratch)
                drawn0 = -1
            host[].g2d_defer = True  # (as tick: a GPU frame is committed, not waited for, D-7555)
            host[].draw_canvas(k, host_addr)
            host[].g2d_defer = False
        var s1 = slept_ms(host[].g2d)
        if trace_dirty and i < 3:  # (diagnosis only: its time lands in the frame's draw)
            print("DIRTY " + what + " f" + String(i) + ": " + dirty_views(msg(msg(window, "contentView"), "superview"), 0), flush=True)
        var t2 = Int(now_ns())
        var c2 = thread_cpu_ns()
        var need_l = msg(window, "contentView") != 0 and (msg(msg(window, "contentView"), "needsLayout") & 0xFF) != 0
        _ = msg(window, "layoutIfNeeded")  # (displayIfNeeded's first part, timed apart: FRAMES' L)
        var t2l = Int(now_ns())
        var c2l = thread_cpu_ns()
        _ = msg(window, "displayIfNeeded")
        var t2d = Int(now_ns())
        var sf0 = slept_ms(host[].g2d)
        host[].finish_frame()  # (as tick: completed frames shown, at most g2d_keep left in flight)
        var sf1 = slept_ms(host[].g2d)
        var t2f = Int(now_ns())
        _ = msg(cls("CATransaction"), "flush")
        var t3 = Int(now_ns())
        var c3 = thread_cpu_ns()
        var ru1 = usage()
        var s2 = slept_ms(host[].g2d)
        node = canvas_node_at(host[], tag)
        k = host[].canvas_at(node) if node >= 0 else -1
        if k >= 0:  # (a GPU frame counts even when the version reads the same: mid-animation it stays -1, drawn every frame)
            drew = host[].canvases[k].drawn != drawn0 or host[].g2d_frames != g2d0
        # (a gpu2d frame's work: its CPU time and the GPU's time on it, not the time the thread slept while the GPU
        # queued it or woke up: GTK's rule, D-7528, D-7541; the GPU's time is added below, once the frame completed. The
        # wall time is printed too, and on the Mac it must pass as well, D-7554; GPU times as frames complete, D-7556)
        if not drew:
            missed += 1
        else:
            var is_g2d = host[].g2d_frames != g2d0
            if is_g2d:
                on_g2d += 1
                g_scene.append(host[].g2d_parts[0])
                g_batch.append(host[].g2d_parts[1])
                g_metal.append(host[].g2d_parts[2])
                g_layers.append(String(Int(host[].g2d_parts[4])) + "/" + String(Int(host[].g2d_parts[5])) + "/" + String(Int(host[].g2d_parts[6])) + "/" + String(Int(host[].g2d_parts[8])) + ":" + String(Int(host[].g2d_parts[7]))
                                + " i" + one_decimal(host[].g2d_parts[11]) + " k" + String(Int(host[].g2d_parts[12])))
            if host[].canvases[k].gpu_frames != gpu0:
                on_gpu += 1
            else:
                on_cpu += 1
            var ev = Float64(t1 - t0) / 1e6
            var dm = Float64(t2 - t1) / 1e6 - (s1 - s0)  # (CPU only: the GPU's time is added when it's known)
            var pm = Float64(t3 - t2) / 1e6 - (s2 - s1)
            events.append(ev)
            draws.append(dm)
            paints.append(pm)
            works.append(ev + dm + pm)
            walls.append(Float64(t3 - t0) / 1e6)
            g2d_at.append(on_g2d - 1 if is_g2d else -1)
            # (the wall breakdown, D-7584: E event, D our draw (CPU, its sleeps out), L AppKit's layout (* = the content
            # view asked for one), P AppKit's display, F showing completed GPU frames, C the CATransaction commit; s the
            # GPU waits, c the main thread's CPU time (cp: in L–C), o off the CPU without our waits (the OS ran something
            # else, or a call blocked: wall − CPU − s); pf major/minor page faults and cs voluntary/involuntary context
            # switches in the frame (the process's, when any); then each GPU wait: d(rain) or w(ait for a frame)
            # slept/commit→start/GPU. The frame with the longest wall prints it on the FRAMEBENCH line as wall_worst)
            var wall = Float64(t3 - t0) / 1e6
            var cpu = Float64(c3 - c0) / 1e6
            var why = String(" e") + one_decimal(ev) + " d" + one_decimal(dm) + " L" + one_decimal(Float64(t2l - t2) / 1e6) + ("*" if need_l else "") + "/" + one_decimal(Float64(c2l - c2) / 1e6)
            why += " P" + one_decimal(Float64(t2d - t2l) / 1e6) + " F" + one_decimal(Float64(t2f - t2d) / 1e6 - (sf1 - sf0)) + " C" + one_decimal(Float64(t3 - t2f) / 1e6)
            why += " s" + one_decimal(s2 - s0) + " c" + one_decimal(cpu) + " cp" + one_decimal(Float64(c3 - c2) / 1e6) + " o" + one_decimal(max(wall - cpu - (s2 - s0), 0.0)) + " W" + one_decimal(wall)
            if ru1[0] != ru0[0] or ru1[1] != ru0[1]:  # (page faults in the frame: major = read from disk, minor)
                why += " pf" + String(ru1[1] - ru0[1]) + "/" + String(ru1[0] - ru0[0])
            if ru1[2] != ru0[2] or ru1[3] != ru0[3]:  # (context switches in the frame: voluntary/involuntary (preempted))
                why += " cs" + String(ru1[2] - ru0[2]) + "/" + String(ru1[3] - ru0[3])
            why += take_waits(host[].g2d)
            diag.append(why)
        if what == "open" or what == "openpress":  # (D-7984) the progressive open's later frames, each timed as one
            host[].finish_gpu2d(0)  # (the open's own frame's GPU time lands in its place first)
            var guard = Int(now_ns()) + 5_000_000_000
            var pressed = False
            var last_done = Int(now_ns())
            while Int(now_ns()) < guard:
                node = canvas_node_at(host[], tag)
                k = host[].canvas_at(node) if node >= 0 else -1
                if k < 0:
                    break
                var press_ev = 0.0
                var is_press = False
                if what == "openpress" and not pressed:  # (a press where the partial board shows an object: an edit during the open)
                    var sp = host[].rt.app.bench(host[].rt.shown.nodes[node].style, "bench:openspot")
                    if sp[0] >= 0:
                        pressed = True
                        is_press = True
                        var tp = Int(now_ns())
                        host[].canvas_send(node, PRESS, sp[0], sp[1], 0, 0, 1, host_addr)
                        host[].canvas_send(node, RELEASE, sp[0], sp[1], 0, 0, 1, host_addr)
                        press_ev = Float64(Int(now_ns()) - tp) / 1e6
                if not is_press and host[].rt.app.bench(host[].rt.shown.nodes[node].style, "bench:loading")[0] < 0.5:
                    break
                var work = open_tail_frame[A](host_addr, tag)
                last_done = Int(now_ns())
                if is_press:
                    presses.append(work + press_ev)
                    if env("MOJOUI_FRAMEBENCH_FRAMES") == "1":  # (where a press during an open goes: its handling, then its frame)
                        print("PRESS: event " + one_decimal(press_ev) + " frame " + one_decimal(work) + " scene " + one_decimal(host[].g2d_parts[0]) + " batch " + one_decimal(host[].g2d_parts[1])
                              + " rest " + one_decimal(host[].g2d_parts[2]), flush=True)
                elif work >= 0:
                    during.append(work)
            if what == "openpress" and not pressed:
                presses.append(-1)  # (the press never reached a frame: reported, and the row fails)
            completes.append(Float64(last_done - t0) / 1e6)
        pump_run_loop(0)  # (the window server's events, untimed)
    node = canvas_node_at(host[], tag)
    if node >= 0 and (what == "pan" or what == "draw"):
        host[].canvas_send(node, RELEASE, x, y, 0, 0, 1, host_addr, 0.6 if what == "draw" else 0.0)
    host[].finish_gpu2d(0)  # (the step's last frames: shown, their GPU times known)
    var failed = host[].g2d_failed - failed0  # (committed, but the GPU didn't complete them: the CPU executor drew what was shown)
    on_gpu -= failed
    on_cpu += failed
    for i in range(len(works)):  # (each gpu2d frame's GPU time, in commit order, into its draw and its work)
        var j = g2d_at[i]
        var gms = host[].g2d_done[j] if j >= 0 and j < len(host[].g2d_done) else 0.0
        draws[i] += gms
        works[i] += gms
        if j >= 0:
            g_gpu.append(gms)
    host[].wake()
    if env("MOJOUI_FRAMEBENCH_FRAMES") == "1":  # (every frame's work and its GPU parts, in order: where the slow ones fall)
        var line = String("FRAMES: ") + what
        for i in range(len(works)):
            line += " " + one_decimal(works[i])
            if i < len(g_scene):
                line += "(" + one_decimal(g_scene[i]) + "/" + one_decimal(g_batch[i]) + "/" + one_decimal(g_metal[i]) + "/" + one_decimal(g_gpu[i]) + " " + g_layers[i] + diag[i] + ")"
        print(line, flush=True)
    var worst = 0  # (the frame with the longest wall time: its breakdown on the FRAMEBENCH line, so a spike names its cause)
    for i in range(len(walls)):
        if walls[i] > walls[worst]:
            worst = i
    var wall_why = String("")
    if worst < len(diag):
        wall_why = " wall_worst=f" + String(worst) + ":" + String(diag[worst].strip()).replace(" ", ",")
        if worst < len(works):
            wall_why += ",work" + one_decimal(works[worst])
    var renderer = String("AppKit-IOSurface") if on_cpu == 0 and on_gpu > 0 else (String("AppKit-CPU") if on_gpu == 0 else String("AppKit-mixed"))
    if on_g2d > 0:  # (goal 75 M3: our renderer on Metal drew them; each frame's GPU work is in its draw time)
        renderer = String("gpu2d-Metal") if on_g2d == len(works) else String("gpu2d-Metal-mixed")
    var scale = msg[Float64](window, "backingScaleFactor") if window != 0 else 0.0
    if env("MOJOUI_BENCHSTATE") == "1":
        print_bench_state[A](host_addr, what)
    print("FRAMEBENCH: " + what + " n=" + String(len(works)) + " missed=" + String(missed) + " unchanged=0 renderer=" + renderer
          + " labels_in_place=" + String(host[].labels_in_place - inplace0) + " labels_relaid=" + String(host[].labels_relaid - relaid0)
          + " p50=" + one_decimal(pct(works, 0.5)) + " p95=" + one_decimal(pct(works, 0.95)) + " max=" + one_decimal(pct(works, 1.0))
          + " event_p95=" + one_decimal(pct(events, 0.95)) + " draw_p95=" + one_decimal(pct(draws, 0.95))
          + " paint_p95=" + one_decimal(pct(paints, 0.95)) + " draw_max=" + one_decimal(pct(draws, 1.0))
          + " paint_max=" + one_decimal(pct(paints, 1.0)) + " wall_p95=" + one_decimal(pct(walls, 0.95)) + " wall_max=" + one_decimal(pct(walls, 1.0)) + " gpu_frames=" + String(on_gpu) + " cpu_frames=" + String(on_cpu) + " gpu2d_frames=" + String(on_g2d)
          + " canvas=" + String(Int(w)) + "x" + String(Int(h)) + "pt@" + one_decimal(scale) + "x"
          + ((" scene_p95=" + one_decimal(pct(g_scene, 0.95)) + " batch_p95=" + one_decimal(pct(g_batch, 0.95)) + " metal_p95=" + one_decimal(pct(g_metal, 0.95))
              + " gpu_p50=" + one_decimal(pct(g_gpu, 0.5)) + " gpu_p95=" + one_decimal(pct(g_gpu, 0.95)) + " scene_max=" + one_decimal(pct(g_scene, 1.0))
              + " metal_max=" + one_decimal(pct(g_metal, 1.0)) + " gpu_max=" + one_decimal(pct(g_gpu, 1.0))
              + " shown=" + String(len(host[].g2d_shown_ms)) + " shown_p50=" + one_decimal(pct(host[].g2d_shown_ms, 0.5)) + " shown_p95=" + one_decimal(pct(host[].g2d_shown_ms, 0.95))
              + " shown_max=" + one_decimal(pct(host[].g2d_shown_ms, 1.0))) if on_g2d > 0 else String(""))
          + ((" during_n=" + String(len(during)) + " during_p95=" + one_decimal(pct(during, 0.95)) + " during_max=" + one_decimal(pct(during, 1.0))
              + " complete_p50=" + one_decimal(pct(completes, 0.5)) + " complete_max=" + one_decimal(pct(completes, 1.0))) if what == "open" or what == "openpress" else String(""))
          + ((" press_n=" + String(len(presses)) + " press_p95=" + one_decimal(pct(presses, 0.95)) + " press_max=" + one_decimal(pct(presses, 1.0))) if what == "openpress" else String(""))
          + wall_why, flush=True)


def open_tail_frame[A: App](host_addr: Int, tag: String) -> Float64:
    """One frame of a progressive open after its first, drawn as the tick draws it and timed as framebench times its own
    (the frame event, the draw's CPU time without its GPU waits, AppKit's display and commit, then the GPU's time on it
    once complete); -1 when nothing was drawn. Its GPU times are taken out of g2d_done so framebench's order holds."""
    var host = host_at[A](host_addr)
    var node = canvas_node_at(host[], tag)
    var k = host[].canvas_at(node) if node >= 0 else -1
    if k < 0:
        return -1.0
    var drawn0 = host[].canvases[k].drawn
    var g2d0 = host[].g2d_frames
    var done0 = len(host[].g2d_done)
    var t0 = Int(now_ns())
    if host[].rt.shown.nodes[node].msg2 != 0:
        var d = host[].rt.frame(node, 16667)
        host[].apply(d, host_addr)
        node = canvas_node_at(host[], tag)
        k = host[].canvas_at(node) if node >= 0 else -1
        if k < 0:
            return -1.0
    var s0 = slept_ms(host[].g2d)
    host[].g2d_defer = True
    host[].draw_canvas(k, host_addr)
    host[].g2d_defer = False
    var window = host[].window
    _ = msg(window, "layoutIfNeeded")
    _ = msg(window, "displayIfNeeded")
    host[].finish_frame()
    _ = msg(cls("CATransaction"), "flush")
    var t1 = Int(now_ns())
    var s1 = slept_ms(host[].g2d)
    var drew = host[].canvases[k].drawn != drawn0 or host[].g2d_frames != g2d0
    host[].finish_gpu2d(0)
    var gms = 0.0
    while len(host[].g2d_done) > done0:
        gms += host[].g2d_done.pop()
    pump_run_loop(0)
    if not drew:
        return -1.0
    return Float64(t1 - t0) / 1e6 - (s1 - s0) + gms


def dirty_views(v: Int, depth: Int) -> String:
    """Diagnosis (MOJOUI_FRAMEBENCH_DIRTY=1): the views under v that need layout (L), constraints (U), display (D) or their layer redrawn (Y)."""
    if v == 0 or depth > 40:
        return ""
    var out = String("")
    var l = (msg(v, "needsLayout") & 0xFF) != 0
    var u = (msg(v, "needsUpdateConstraints") & 0xFF) != 0
    var d = (msg(v, "needsDisplay") & 0xFF) != 0
    var ld = msg(v, "layer") != 0 and (msg(msg(v, "layer"), "needsDisplay") & 0xFF) != 0
    if l or u or d or ld:
        out += " " + from_ns(msg(msg(v, "className"), "description")) + "@" + String(depth) + ":" + ("L" if l else "") + ("U" if u else "") + ("D" if d else "") + ("Y" if ld else "")
        if (msg(v, "isKindOfClass:", cls("NSTextField")) & 0xFF) != 0:
            out += "'" + from_ns(msg(v, "stringValue")) + "'"
    var subs = msg(v, "subviews")
    for j in range(msg(subs, "count")):
        out += dirty_views(msg(subs, "objectAtIndex:", j), depth + 1)
    return out


def usage() -> List[Int]:
    """The process's minor and major page faults and voluntary and involuntary context switches so far (getrusage;
    macOS's struct rusage: two timevals, then longs), for framebench's wall breakdown (D-7584)."""
    var ru = List[Int](length=18, fill=0)
    _ = external_call["getrusage", c_int](c_int(0), Int(ru.unsafe_ptr()))  # RUSAGE_SELF
    return [ru[8], ru[9], ru[16], ru[17]]  # ru_minflt, ru_majflt, ru_nvcsw, ru_nivcsw


def thread_cpu_ns() -> Int:
    """The calling thread's CPU time (CLOCK_THREAD_CPUTIME_ID, 16 on macOS), for framebench's wall breakdown."""
    return Int(external_call["clock_gettime_nsec_np", UInt64](c_int(16)))


def take_waits(g2d: Int) -> String:
    """gpu2d's GPU waits since the last call, as framebench's breakdown shows them (D-7584), and forgets them."""
    if g2d == 0:
        return ""
    var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=g2d)
    var out = String("")
    var i = 0
    while i + 3 < len(g[].metal.wait_log):
        ref lg = g[].metal.wait_log
        out += (" d" if lg[i] == 1.0 else " w") + one_decimal(lg[i + 1])
        if lg[i + 2] >= 0:
            out += "/" + one_decimal(lg[i + 2]) + "/" + one_decimal(lg[i + 3])
        i += 4
    g[].metal.wait_log.clear()
    return out


def slept_ms(g2d: Int) -> Float64:
    """How long the main thread has slept waiting for gpu2d's GPU frames so far (0 without the Metal renderer)."""
    if g2d == 0:
        return 0.0
    return Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=g2d)[].metal.slept_ms


def gpu2d_probe() -> String:
    """At start, before the app is made: whether Canvas(…).gpu() canvases can be drawn by gpu2d on Metal ("": yes), told
    to the app through mojoui.gpu2d_backend ("gpu2d-Metal", or "cpu (why)"). MOJOUI_GPU2D=0: never (the CPU path)."""
    if env("MOJOUI_GPU2D") == "0":
        set_backend_name("cpu (MOJOUI_GPU2D=0)")
        return "MOJOUI_GPU2D=0"
    if metal_device_name() == "":
        set_backend_name("cpu (no Metal device)")
        return "no Metal device"
    set_backend_name("gpu2d-Metal")
    return ""


def gpu_check[A: App](host_addr: Int, which: String):
    """gpucheck:K (goal 75 M3): canvas K's current Scene drawn twice, by Metal (read back from an IOSurface) and by
    gpu2d's CPU executor, and compared as M1's bounds say (mean ≤ 1.5 levels, ≤ 0.5 % of pixels with a channel more than
    40 levels off). Prints `GPU2D METAL CHECK: … mean=… far=…% ok|FAIL`."""
    var host = host_at[A](host_addr)
    var node = canvas_node_at(host[], which)
    var k = host[].canvas_at(node) if node >= 0 else -1
    if k < 0:
        print("GPU2D METAL CHECK: no canvas " + which, flush=True)
        return
    var addr = host[].gpu2d()
    if addr == 0:
        print("GPU2D METAL CHECK: no Metal (" + host[].g2d_why + ")", flush=True)
        return
    var g = Pointer[MetalCanvas2D, MutUntrackedOrigin](unsafe_from_address=addr)
    var b = msg[CGRect](host[].canvases[k].view, "bounds")
    var scale = msg[Float64](host[].window, "backingScaleFactor") if host[].window != 0 else 2.0
    var w = Int(b.width * scale + 0.5)
    var h = Int(b.height * scale + 0.5)
    g[].scene.reset(w, h, scale)
    var r = host[].rt.draw_scene(node, g[].scene)
    if not r[0] or w <= 0 or h <= 0:
        print("GPU2D METAL CHECK: canvas " + which + " draws no Scene", flush=True)
        return
    fill_batches(g[].frame, g[].scene, g[].atlas, g[].font)
    var want = List[UInt32](length=w * h, fill=0)
    var surface = Surface(Int(want.unsafe_ptr()), w, h, scale)
    execute_cpu(g[].frame, g[].atlas, surface)
    # the whole frame at once (render), then the path the screen takes (render_scene: layers kept from last frame where
    # they didn't change, the rest built alone): both must match the CPU executor
    var whole = metal_vs_cpu(g, want, w, h, False, node)
    var layered = metal_vs_cpu(g, want, w, h, True, node)
    g[].end_frame()
    var ok = whole[0] <= 1.5 and whole[1] <= 0.5 and layered[0] <= 1.5 and layered[1] <= 0.5
    print("GPU2D METAL CHECK: canvas=" + which + " " + String(w) + "x" + String(h) + " ops=" + String(g[].prev.ops()) + " mean=" + String(round(whole[0], 4))
          + " far=" + String(round(whole[1], 4)) + "% differ=" + String(Int(whole[2])) + " layers_mean=" + String(round(layered[0], 4)) + " layers_far="
          + String(round(layered[1], 4)) + "% gpu_ms=" + String(round(g[].metal.gpu_ms, 3)) + (" ok" if ok else " FAIL"), flush=True)
    host[].canvases[k].drawn = -1  # (drawn again by the next tick: the check's Scene replaced nothing on screen)
    host[].apply(r[1], host_addr)


def metal_vs_cpu(g: Pointer[MetalCanvas2D, MutUntrackedOrigin], want: List[UInt32], w: Int, h: Int, layered: Bool, owner: Int) -> Tuple[Float64, Float64, Float64]:
    """g's current Scene drawn by Metal into a fresh IOSurface (the whole frame, or layer by layer as the screen does),
    read back and compared with `want`: (mean levels off, % of pixels with a channel more than 40 off, pixels that
    differ at all); (999, 100, w·h) when Metal didn't draw it."""
    var io = io_surface(w, h)
    var drew = False
    if io != 0:
        drew = g[].render_scene(owner, io, w, h) if layered else g[].metal.render(g[].frame, io, w, h)
    var got = read_iosurface(io, w, h) if drew else List[UInt32](length=w * h, fill=0)
    if io != 0:
        g[].metal.forget(io)
        cfunc[NoneType]("CFRelease", io)
    if not drew:
        return (999.0, 100.0, Float64(w * h))
    var total = 0
    var far = 0
    var differ = 0
    for i in range(w * h):
        var worst = 0
        for c in range(3):
            var d = abs(Int((want[i] >> UInt32(8 * c)) & 0xFF) - Int((got[i] >> UInt32(8 * c)) & 0xFF))
            total += d
            worst = max(worst, d)
        if worst > 40:
            far += 1
        if worst > 0:
            differ += 1
    return (Float64(total) / Float64(3 * w * h), 100.0 * Float64(far) / Float64(w * h), Float64(differ))


def find_node[A: App](host: AppKitHost[A], kind: Int, label: String, nth: Int, by_hint: Bool = False) -> Int:
    """The nth node of `kind` whose text (or hint) is `label` ("" = any), as the GTK host's test steps find it."""
    var seen = 0
    for i in range(len(host.rt.shown.nodes)):
        ref n = host.rt.shown.nodes[i]
        if n.kind == kind and (label == "" or (n.hint if by_hint else n.text) == label):
            if seen == nth:
                return i
            seen += 1
    if label != "" and nth == 0 and not by_hint:  # (no text matched: the node tagged so, as GTK's steps find a button by its tag)
        for i in range(len(host.rt.shown.nodes)):
            ref n = host.rt.shown.nodes[i]
            if n.kind == kind and n.name == label:
                return i
    return -1


def find_menu_item[A: App](host: AppKitHost[A], under: Int, title: String) -> Int:
    """The ITEM titled `title` anywhere under node `under` (submenus too)."""
    for c in host.rt.shown.nodes[under].children:
        ref n = host.rt.shown.nodes[c]
        if n.kind == ITEM and n.text == title:
            return c
        var deeper = find_menu_item(host, c, title)
        if deeper >= 0:
            return deeper
    return -1


def option_index[A: App](host: AppKitHost[A], i: Int, option: String) -> Int:
    ref opts = host.rt.shown.nodes[i].options
    for j in range(len(opts)):
        if opts[j] == option:
            return j
    return -1


def canvas_node_at[A: App](host: AppKitHost[A], which: String) -> Int:
    """A canvas step's target: the nth canvas ("0", "1"…) or the canvas tagged `which` ("grid"), as GTK's canvas_node."""
    var digits = which != ""
    for c in which.codepoints():
        if c < Codepoint.ord("0") or c > Codepoint.ord("9"):
            digits = False
    var seen = 0
    for i in range(len(host.rt.shown.nodes)):
        if host.rt.shown.nodes[i].kind != CANVAS:
            continue
        if (digits and seen == to_int(which)) or (not digits and host.rt.shown.nodes[i].name == which):
            return i
        seen += 1
    return -1


def run_step[A: App](host_addr: Int, step: String):
    """One MOJOUI_TEST step, in the GTK host's words (tap:Label[@n], type/submit/enter:Hint=text, select:n=Option,
    segment/tab/radio:n=Option, toggle:Label, menu:File>Item, pick:Title=/path) plus resize:WxH (the window's content)."""
    var host = host_at[A](host_addr)
    var vr = split_at(step, ":")
    var verb = vr[0]
    var rest = vr[1]
    var kv = split_at(rest, "=")
    if verb == "tap":
        var t = split_at(rest, "@")
        var i = find_node(host[], BUTTON, t[0], to_int(t[1]))
        if i < 0:
            host[].report.note("TEST: no button " + rest)
            return
        var w = host[].widgets[i] if i < len(host[].widgets) else 0
        if w != 0 and msg[Int8](w, "respondsToSelector:", sel("performClick:")) != 0:
            _ = msg(w, "performClick:", 0)  # AppKit's own click: the button's target and action, as a real click
        else:
            host[].send(i, False, "", 0, host_addr)
    elif verb == "pick":  # a FilePicker returning that file (a native dialog can't be driven)
        var i = find_node(host[], BUTTON, kv[0], 0)
        if i < 0:
            host[].report.note("TEST: no file picker " + kv[0])
            return
        host[].send(i, True, kv[1], 0, host_addr)
    elif verb == "type" or verb == "submit" or verb == "enter":
        var i = find_node(host[], FIELD, kv[0], 0, by_hint=True)
        if i < 0:
            host[].report.note("TEST: no field " + kv[0])
            return
        var w = host[].widgets[i] if i < len(host[].widgets) else 0
        var text = kv[1]
        if verb == "submit" and w != 0:
            text = from_ns(msg(w, "stringValue"))
        if w != 0:
            _ = msg(w, "setStringValue:", ns_string(text))
        if verb == "type" or verb == "enter":
            host[].send(i, False, text, 0, host_addr)
        if verb == "submit" or verb == "enter":
            host[].send(i, True, text, 0, host_addr)
    elif verb == "toggle":
        var i = find_node(host[], TOGGLE, rest, 0)
        if i < 0:
            host[].report.note("TEST: no toggle " + rest)
            return
        var w = host[].widgets[i] if i < len(host[].widgets) else 0
        if w != 0 and msg[Int8](w, "respondsToSelector:", sel("performClick:")) != 0:
            _ = msg(w, "performClick:", 0)
        else:
            host[].send(i, False, "", 0 if host[].rt.shown.nodes[i].value != 0 else 1, host_addr)
    elif verb == "select" or verb == "segment" or verb == "tab" or verb == "radio":
        var kind = DROPDOWN if verb == "select" else (SEGMENTED if verb == "segment" else (TABS if verb == "tab" else RADIO))
        var i = find_node(host[], kind, "", to_int(kv[0]))
        if i < 0:
            host[].report.note("TEST: no " + verb + " " + kv[0])
            return
        var index = option_index(host[], i, kv[1])
        if index < 0:
            host[].report.note("TEST: no option " + kv[1])
            return
        host[].send(i, False, kv[1], index, host_addr)
    elif verb == "say":  # say:TAG[@n]: what the n-th view tagged TAG says now (@-1: the last): its tooltip, else its words
        var ts = split_at(rest, "@")
        var tag = ts[0]
        var want = to_int(ts[1]) if ts[1] != "" else 0
        var hits = List[Int]()
        for k in range(len(host[].rt.shown.nodes)):
            if host[].rt.shown.nodes[k].name == tag:
                hits.append(k)
        var at = want if want >= 0 else len(hits) + want
        if at >= 0 and at < len(hits):
            ref n = host[].rt.shown.nodes[hits[at]]
            print("SAYS: " + rest + " = " + (n.tip if n.tip != "" else n.text), flush=True)
        else:
            print("TEST: nothing tagged " + rest, flush=True)
    elif verb == "menu":  # menu:File>Save: the bar's File menu's Save item
        var t = split_at(rest, ">")
        var menu = -1
        for k in range(len(host[].rt.shown.nodes)):
            ref n = host[].rt.shown.nodes[k]
            if n.kind == MENU and n.text == t[0]:
                menu = k
        var item = find_menu_item(host[], menu, t[1]) if menu >= 0 else -1
        if item < 0:
            host[].report.note("TEST: no menu item " + rest)
            return
        host[].send(item, False, "", 0, host_addr)
    elif verb == "tapat" or verb == "dragat" or verb == "drag":  # a canvas's click or drag, in GTK's words (K: the nth canvas, or its tag)
        var node = canvas_node_at(host[], kv[0])
        var k = host[].canvas_at(node) if node >= 0 else -1
        if k < 0:
            host[].report.note("TEST: no canvas " + kv[0])
            return
        var b = msg[CGRect](host[].canvases[k].view, "bounds")
        var nums = List[Float64]()
        var left = kv[1]
        while left != "":
            var cut = split_at(left, ",")
            nums.append(Float64(to_int(cut[0])))
            left = cut[1]
        if verb == "tapat" and len(nums) >= 2:  # tapat:K=x,y thousandths: press, then the click (GTK: drag-begin, released)
            var x = nums[0] / 1000.0 * b.width
            var y = nums[1] / 1000.0 * b.height
            host[].canvases[k].moved = False
            host[].canvas_send(node, HOVER, x, y, 0, 0, 1, host_addr)  # (the pointer got there first, as GTK's tapat: hover states)
            host[].canvas_send(node, PRESS, x, y, 0, 0, 1, host_addr)
            host[].canvas_send(node, TAP, x, y, 0, 0, 1, host_addr)
        elif len(nums) >= 2:  # drag:K=dx,dy from (10, 10); dragat:K=fx,fy,dx,dy from (fx, fy) thousandths: press, two moves (GTK's)
            var sx = 10.0
            var sy = 10.0
            var at = 0
            if verb == "dragat" and len(nums) >= 4:
                sx, sy, at = nums[0] / 1000.0 * b.width, nums[1] / 1000.0 * b.height, 2
            var dx = nums[at]
            var dy = nums[at + 1]
            host[].canvas_send(node, PRESS, sx, sy, 0, 0, 1, host_addr)
            host[].canvases[k].moved = True
            host[].canvas_send(node, PAN, sx + dx / 2, sy + dy / 2, dx / 2, dy / 2, 1, host_addr)
            host[].canvas_send(node, PAN, sx + dx, sy + dy, dx / 2, dy / 2, 1, host_addr)
    elif verb == "webjs" or verb == "webkill" or verb == "webtype" or verb == "webclick":
        # webjs:<tag>#<id>=<expression>: its value (awaited) in that widget's page, in the log as JS: <json>;
        # webkill:<tag>#<id>: ends its web process, as a crash would; webtype:<tag>#<id>=<text>: a click into the view,
        # then real key events; webclick:<tag>#<id>=<CSS selector>: a real click on that element (the next step waits)
        var key = split_at(kv[0], "#")
        var mw = mac_at(host[].webviews)
        var k = mw[].core.slot_of(key[0], to_int(key[1])) if mw[].core.state == 1 else -1
        if k < 0:
            host[].report.note("TEST: no web view " + kv[0])
            if verb == "webjs":
                host[].report.note('JS: "no web view"')
            return
        if verb == "webjs":
            host[].probe_pending = True
            webview_probe(host[].webviews, k, kv[1])
        elif verb == "webkill":
            webview_kill(host[].webviews, k)
        elif verb == "webtype":
            webview_type(host[].webviews, k, kv[1])
        else:
            webview_click(host[].webviews, k, kv[1])
    elif verb == "scheme":  # scheme:dark / scheme:light: the app's appearance switches, as the system's would (GTK's word)
        var app = msg(cls("NSApplication"), "sharedApplication")
        _ = msg(app, "setAppearance:", msg(cls("NSAppearance"), "appearanceNamed:", ns_string("NSAppearanceNameDarkAqua" if rest == "dark" else "NSAppearanceNameAqua")))
        host[].follow_appearance(host_addr, 1 if rest == "dark" else 0)
    elif verb == "set":  # set:<tag>#<id>.<field>=<JSON>: what an agent's set does (Runtime.set_widget → "mojoui.set" to the page)
        var key = split_at(kv[0], "#")
        var at = split_at(key[1], ".")
        if not host[].rt.set_widget(key[0], to_int(at[0]), at[1], kv[1]):
            host[].report.note("TEST: no widget " + kv[0] + " on the screen, or a value that isn't JSON")
        host[].send_commands(host_addr)
    elif (verb == "resize" and "=" in rest) or verb == "dragcard":
        # resize:<card>=dx,dy: a tiled card's corner dragged that far; dragcard:<a>=<b>: a's header dragged until its
        # middle is over b's middle; the app hears what tiled_pan sends when such a drag ends (GTK's words for both)
        var board = -1
        var index = -1
        var other = -1
        for b in range(len(host[].rt.shown.nodes)):
            if host[].rt.shown.nodes[b].kind == BOARD:
                for k in range(len(host[].rt.shown.nodes[b].children)):
                    var c = host[].rt.shown.nodes[b].children[k]
                    if host[].rt.shown.nodes[c].name == kv[0]:
                        board = b
                        index = k
                    elif host[].rt.shown.nodes[c].name == kv[1]:
                        other = c
        if board < 0:
            host[].report.note("TEST: no card " + kv[0])
            return
        var dx = 0.0
        var dy = 0.0
        if verb == "dragcard":
            if other < 0:
                host[].report.note("TEST: no card " + kv[1])
                return
            ref a = host[].rt.shown.nodes[host[].rt.shown.nodes[board].children[index]]
            ref t = host[].rt.shown.nodes[other]
            dx = Float64((t.x + t.w // 2) - (a.x + a.w // 2))
            dy = Float64((t.y + t.h // 2) - (a.y + a.h // 2))
        else:
            var xy = split_at(kv[1], ",")
            dx = Float64(to_int(xy[0]))
            dy = Float64(to_int(xy[1]))
        end_tiled_drag[A](host_addr, board, index, verb == "resize", dx, dy)  # (what tiled_pan does when a drag ends)
    elif verb == "key" or verb == "typekeys":  # key:K=shift+ctrl+alt+Name, typekeys:K=text (⏎ Enter, ⎋ Escape): canvas K's KEY gestures (GTK's words)
        var node = canvas_node_at(host[], kv[0])
        if node < 0:
            print("TEST: no canvas", kv[0], flush=True)
            return
        if host[].rt.shown.nodes[node].size != 1:
            print("TEST: canvas " + kv[0] + " doesn't take keys", flush=True)
            return
        var presses = List[String]()
        var mods = 0
        if verb == "typekeys":
            for ch in kv[1].codepoint_slices():
                var c = String(ch)
                presses.append("Enter" if c == "⏎" else ("Escape" if c == "⎋" else c))
        else:
            var name = kv[1]
            while True:  # (GTK's step bits shift, ctrl, alt → the app's SHIFT 1, CTRL 2, ALT 4, as keyDown: sends them)
                if name.startswith("shift+"):
                    mods |= 1
                    var cut = String(name[byte=6:])
                    name = cut
                elif name.startswith("ctrl+"):
                    mods |= 2
                    var cut = String(name[byte=5:])
                    name = cut
                elif name.startswith("alt+"):
                    mods |= 4
                    var cut = String(name[byte=4:])
                    name = cut
                else:
                    break
            presses.append(web_key(name))
        for p in presses:
            canvas_key_step[A](host_addr, kv[0], p, mods)
    elif verb == "clipboard":  # clipboard:text: the paste board holds text (as another app's copy would; in test mode the private one)
        var board = paste_board()
        _ = msg(board, "clearContents")
        _ = msg(board, "setString:forType:", ns_string(rest), ns_string("public.utf8-plain-text"))
    elif verb == "imemarked" or verb == "imefirstrect" or verb == "imeinsert":  # (D-7979) the real NSTextInputClient methods on the real view, as an input method calls them
        var node = canvas_node_at(host[], kv[0])
        var k = host[].canvas_at(node) if node >= 0 else -1
        var f = shim_sym("mojoui_ime_drive")
        if k < 0 or f == 0:
            host[].report.note("TEST: no canvas " + kv[0] + " or no input-method shim")
            return
        var drive = Pointer(to=f).unsafe_bitcast[def(Int, Int, Int, Int) thin abi("C")]()[]
        var text = kv[1]
        var out = List[Float64](length=8, fill=0)
        var kind = 0 if verb == "imemarked" else (1 if verb == "imefirstrect" else 2)
        drive(host[].canvases[k].view, kind, Int(text.as_c_string_span().unsafe_ptr()), Int(out.unsafe_ptr()))
        if kind == 1:
            print("IME: firstRect=" + String(out[0]) + "," + String(out[1]) + "," + String(out[2]) + "," + String(out[3]) + " markedRange=" + String(Int(out[4])) + ","
                  + String(Int(out[5])) + " selectedRange=" + String(Int(out[6])) + " hasMarkedText=" + String(Int(out[7])), flush=True)
        _ = len(out)
        _ = text.byte_length()
    elif verb == "render":  # render:K=path: canvas K painted by the app's draw() (the CPU painter, at the window's backing scale) into a PNG, as GTK's
        var node = canvas_node_at(host[], kv[0])
        var k = host[].canvas_at(node) if node >= 0 else -1
        if k < 0:
            host[].report.note("TEST: no canvas " + kv[0])
            return
        var b = msg[CGRect](host[].canvases[k].view, "bounds")
        var scale = msg[Float64](host[].window, "backingScaleFactor") if host[].window != 0 else 2.0
        if env("MOJOUI_RENDER_SCALE") != "":  # (offscreen at a scale of its own, whatever the screen's: the app at 2× on a 1× screen)
            try:
                scale = Float64(env("MOJOUI_RENDER_SCALE"))
            except:
                pass
        var wpx = Int(b.width * scale + 0.5)
        var hpx = Int(b.height * scale + 0.5)
        var px = List[UInt32](length=wpx * hpx, fill=0)
        var surface = Surface(Int(px.unsafe_ptr()), wpx, hpx, scale)
        surface.still = True
        var d = host[].rt.draw(node, surface)
        host[].apply(d, host_addr)
        var png = encode_png(px, wpx, hpx)
        try:
            with open(kv[1], "w") as f:
                f.write_bytes(Span(png))
            print("RENDER: " + kv[0] + " " + String(wpx) + "x" + String(hpx) + " " + kv[1], flush=True)
        except:
            host[].report.note("TEST: can't write " + kv[1])
    elif verb == "stroke":  # stroke:K=x,y,p;x,y,p;…: a pen's press, moves and release (canvas points), each carrying its pressure
        var node = canvas_node_at(host[], kv[0])
        var k = host[].canvas_at(node) if node >= 0 else -1
        if k < 0:
            print("TEST: no canvas", kv[0], flush=True)
            return
        var pts = List[Tuple[Float64, Float64, Float64]]()
        for part in kv[1].split(";"):
            var a = split_at(String(part), ",")
            var b = split_at(a[1], ",")
            pts.append((to_float(a[0]), to_float(b[0]), to_float(b[1])))
        if len(pts) == 0 or kv[1] == "":
            print("TEST: an empty stroke", flush=True)
            return
        host[].canvases[k].moved = False
        host[].canvas_send(node, PRESS, pts[0][0], pts[0][1], 0, 0, 1, host_addr, pts[0][2])
        for j in range(1, len(pts)):
            node = canvas_node_at(host[], kv[0])  # (a rebuild may have renumbered the screen)
            k = host[].canvas_at(node) if node >= 0 else -1
            if k < 0:
                return
            host[].canvases[k].moved = True
            host[].canvas_send(node, PAN, pts[j][0], pts[j][1], pts[j][0] - pts[j - 1][0], pts[j][1] - pts[j - 1][1], 1, host_addr, pts[j][2])
        var last = pts[len(pts) - 1]
        node = canvas_node_at(host[], kv[0])
        if node >= 0:
            host[].canvas_send(node, RELEASE, last[0], last[1], 0, 0, 1, host_addr, last[2])
    elif verb == "zoom" or verb == "wheel":  # zoom:K=f: ZOOM by f around the middle; wheel:K=dx,dy notches: WHEEL (a canvas whose scroll pans) or ZOOM (GTK's)
        var node = canvas_node_at(host[], kv[0])
        var k = host[].canvas_at(node) if node >= 0 else -1
        if k < 0:
            print("TEST: no canvas", kv[0], flush=True)
            return
        var b = msg[CGRect](host[].canvases[k].view, "bounds")
        if verb == "zoom":
            host[].canvas_send(node, ZOOM, b.width / 2, b.height / 2, 0, 0, to_float(kv[1]), host_addr)
        else:
            var d = split_at(kv[1], ",")
            var dx = to_float(d[0])
            var dy = to_float(d[1])
            if host[].rt.shown.nodes[node].spacing == 1:  # (a notch = 40 points; dx, dy = how far the content moves)
                host[].canvas_send(node, WHEEL, b.width / 2, b.height / 2, -dx * 40.0, -dy * 40.0, 1, host_addr)
            else:
                host[].canvas_send(node, ZOOM, b.width / 2, b.height / 2, 0, 0, 2.0 ** (-dy / 4.0), host_addr)
    elif verb == "firstscreen":  # firstscreen: the process's age when its first canvas picture was drawn and shown (as GTK's, D-7988)
        print("FIRSTSCREEN: " + String(round(host[].first_draw_age_ms, 1)), flush=True)
    elif verb == "noteswitch":  # noteswitch:N: App.bench("bench:switch") N times, each to its drawn frame
        app_step_bench[A](host_addr, "NOTESWITCH", "switch", max(to_int(rest), 1))
    elif verb == "omnibar":  # omnibar:N: App.bench("bench:omnibar") N times, each to its drawn frame
        app_step_bench[A](host_addr, "OMNIBAR", "omnibar", max(to_int(rest), 1))
    elif verb == "openall":  # openall: App.bench("bench:openall") (a note of each kind in turn), to the frame
        app_step_bench[A](host_addr, "OPENALL", "openall", 3)
    elif verb == "rss":  # rss: this process's resident memory (MB), as the kernel reports it (proc_pidinfo)
        print("RSS: " + String(round(rss_mb(), 1)), flush=True)
    elif verb == "appbench":  # appbench:K=<name>: the app readies a bench step on canvas K (App.bench "bench:<name>"), untimed, as GTK's (D-7984)
        var node = canvas_node_at(host[], kv[0])
        if node < 0:
            host[].report.note("TEST: no canvas " + kv[0])
            return
        _ = host[].rt.app.bench(host[].rt.shown.nodes[node].style, "bench:" + kv[1])
        var d = host[].rt.refresh()
        host[].apply(d, host_addr)
        bench_settle[A](host_addr, 500_000_000)
        print("APPBENCH: " + kv[1], flush=True)
    elif verb == "framebench":  # framebench:K=pan|zoom|draw|finish|type|grow,N: N gestures on canvas K, one frame each; percentiles of a frame's work
        frame_bench[A](host_addr, rest)
    elif verb == "gpushot":  # gpushot:K=path: the picture canvas K shows now (its layer's IOSurface, every frame in flight done), as a PNG (D-7993)
        var node = canvas_node_at(host[], kv[0])
        var k = host[].canvas_at(node) if node >= 0 else -1
        if k < 0 or host[].canvases[k].layer == 0:
            host[].report.note("TEST: no GPU picture on " + kv[0])
            return
        host[].finish_gpu2d(0)
        var io = msg(host[].canvases[k].layer, "contents")
        var w = host[].canvases[k].sw
        var h = host[].canvases[k].sh
        if io == 0 or w <= 0 or h <= 0:
            host[].report.note("TEST: no GPU picture on " + kv[0])
            return
        var px = read_iosurface(io, w, h)
        var png = encode_png(px, w, h)
        try:
            with open(kv[1], "w") as f:
                f.write_bytes(Span(png))
            print("GPUSHOT: " + kv[0] + " " + String(w) + "x" + String(h) + " " + kv[1], flush=True)
        except:
            host[].report.note("TEST: couldn't write " + kv[1])
    elif verb == "gpucheck":  # gpucheck:K: canvas K's Scene drawn by Metal and by gpu2d's CPU executor, compared (goal 75 M3)
        gpu_check[A](host_addr, rest)
    elif verb == "quit":  # quit: the run ends after this step (GTK's word; the app's closing() runs on terminate)
        host[].step_at = len(host[].steps)
    elif verb == "resize" or verb == "window":  # resize:900x700 (window:WxH, GTK's word): the window's content size, as a drag of its edge ends
        var wh = split_at(rest, "x")
        host[].asked_w = to_int(wh[0])
        host[].asked_h = to_int(wh[1])
        _ = msg(host[].window, "setContentSize:", Float64(to_int(wh[0])), Float64(to_int(wh[1])))
    elif verb != "wait" and verb != "pause" and verb != "waitfor":  # (pause:ms as GTK's and the web's; wait:ms the Mac's older word)
        host[].report.note("TEST: unknown step " + step)


def on_test_step[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    """The next MOJOUI_TEST step, then a picture once the screen settles; after the last, quit."""
    var addr = msg(number, "longLongValue")
    var host = host_at[A](addr)
    # (web views: the first step waits for every page to load and its widget to mount, as GTK's runs do (20 s at
    # most); a web step's probe, click or crash finishes before the next (15 s at most))
    var waits = (host[].step_at == 0 and not webviews_ready(host[].webviews)) or webview_busy(host[].webviews)
    if waits:
        if host[].step_wait_from == 0:
            host[].step_wait_from = Int(now_ns())
        if Int(now_ns()) - host[].step_wait_from < (20_000_000_000 if host[].step_at == 0 else 15_000_000_000):
            _ = msg(host[].target, "performSelector:withObject:afterDelay:", sel("testStep:"), ns_number(addr), Float64(0.05))
            return
        host[].report.note("TEST: the web views didn't settle in time")
    host[].step_wait_from = 0
    mac_at(host[].webviews)[].busy = False
    if host[].probe_pending:
        host[].probe_pending = False
        var mw = mac_at(host[].webviews)
        host[].report.note("JS: " + (mw[].core.probe_result if mw[].core.probe_done else String('"timed out"')))
    if host[].wait_title != "":  # waitfor:Title=N: until a button titled Title (or a text saying it) is on the screen, N ms at most (GTK's step)
        var found = find_node(host[], BUTTON, host[].wait_title, 0) >= 0 or find_node(host[], TEXT, host[].wait_title, 0) >= 0
        if not found and Int(now_ns()) < host[].wait_until:
            _ = msg(host[].target, "performSelector:withObject:afterDelay:", sel("testStep:"), ns_number(addr), Float64(0.1))
            return
        host[].report.note(("WAITED: " if found else "TEST: no button ") + host[].wait_title)
        host[].wait_title = ""
    if host[].step_at >= len(host[].steps):
        host[].report.note("TEST: done, " + String(len(host[].steps)) + " steps")
        if host[].sheet != 0:  # (an open sheet refuses terminate: the Settings run hung until the runner killed it, 2026-10-24)
            _ = msg(host[].window, "endSheet:", host[].sheet)
            _ = msg(host[].sheet, "orderOut:", 0)
            host[].sheet = 0
        if host[].popover != 0:
            _ = msg(host[].popover, "close")
            host[].popover = 0
        _ = msg(msg(cls("NSApplication"), "sharedApplication"), "terminate:", 0)
        return
    var step = host[].steps[host[].step_at]
    host[].step_at += 1
    host[].report.note("step " + String(host[].step_at) + ": " + step)
    if step.startswith("waitfor:"):
        var kw = split_at(split_at(step, ":")[1], "=")
        host[].wait_title = kw[0]
        host[].wait_until = Int(now_ns()) + to_int(kw[1]) * 1_000_000
        _ = msg(host[].target, "performSelector:withObject:afterDelay:", sel("testStep:"), ns_number(addr), Float64(0.1))
        return
    run_step[A](addr, step)
    host[].report.cause = "step-" + String(host[].step_at)
    host[].queue_snapshot(addr)
    var wait = 1.5
    if step.startswith("wait:") or step.startswith("pause:"):
        wait = Float64(to_int(split_at(step, ":")[1])) / 1000.0
    _ = msg(host[].target, "performSelector:withObject:afterDelay:", sel("testStep:"), ns_number(addr), wait)


def on_web_inbox[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    """The pages' events and replies, on a run-loop turn of their own (never inside WebKit's callback)."""
    var addr = msg(number, "longLongValue")
    host_at[A](addr)[].webview_inbox(addr)


def on_system_appearance[A: App](target: Int, cmd: Int, notification: Int) abi("C"):
    """The system switched light/dark: only queued (NSApp's appearance settles a moment later; never rebuild inside a
    notification, docs/lessons.md)."""
    var addr = 0
    var wins = msg(msg(cls("NSApplication"), "sharedApplication"), "windows")
    for i in range(msg(wins, "count")):  # (the host's window: its delegate is this target, its identifier the host's address)
        var w = msg(wins, "objectAtIndex:", i)
        if msg(w, "delegate") == target and msg(w, "identifier") != 0:
            addr = msg(msg(w, "identifier"), "longLongValue")
    if addr != 0:
        _ = msg(target, "performSelector:withObject:afterDelay:", sel("appearanceLater:"), ns_number(addr), Float64(0.1))


def on_appearance_later[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    var addr = msg(number, "longLongValue")
    host_at[A](addr)[].follow_appearance(addr)


def on_jobs_ended[A: App](target: Int, cmd: Int, nothing: Int) abi("C"):
    """mojoui.uijobs: a background job ended: App.jobs_message to update() on this run-loop turn, the screen patched."""
    var addr = 0
    var wins = msg(msg(cls("NSApplication"), "sharedApplication"), "windows")
    for i in range(msg(wins, "count")):  # (the host's window: its delegate is this target, its identifier the host's address)
        var w = msg(wins, "objectAtIndex:", i)
        if msg(w, "delegate") == target and msg(w, "identifier") != 0:
            addr = msg(msg(w, "identifier"), "longLongValue")
    if addr == 0:
        return
    var host = host_at[A](addr)
    var m = host[].rt.app.jobs_message()
    if m != 0:
        var d = host[].rt.dispatch(Event(m, String(""), 0))
        host[].apply(d, addr)


def on_window_resized[A: App](target: Int, cmd: Int, notification: Int) abi("C"):
    var window = msg(notification, "object")
    var addr = msg(msg(window, "identifier"), "longLongValue")
    host_at[A](addr)[].queue_resize(addr)


def on_window_resize_later[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    var addr = msg(number, "longLongValue")
    host_at[A](addr)[].resized(addr)


def on_close_overlay[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    """A dialog's or toast's ✕: on_close."""
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], True, "", 0, t[0])


def on_show_popover[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    """Shows the popover built for a node: below its anchor, or at a point in it for a context menu."""
    var tag = msg(number, "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if host[].popover == 0 or host[].popover_node != node or node >= len(host[].rt.shown.nodes):
        return  # the screen changed before it could be shown
    var n = host[].rt.shown.nodes[node].copy()
    var anchor = host[].anchor_view(n.text)
    var b = msg[CGRect](anchor, "bounds")
    if n.kind == MENU or n.x != 0 or n.y != 0:  # at a point (y from the top, as the app counts)
        var flipped = msg[Int8](anchor, "isFlipped") != 0
        var y = Float64(n.y) if flipped else b.height - Float64(n.y)
        _ = msg(host[].popover, "showRelativeToRect:ofView:preferredEdge:", Float64(n.x), y, Float64(1), Float64(1), anchor, 2)  # NSRectEdgeMaxX
    else:
        _ = msg(host[].popover, "showRelativeToRect:ofView:preferredEdge:", b.x, b.y, b.width, b.height, anchor, 1)  # NSRectEdgeMinY: below


def on_popover_closed[A: App](target: Int, cmd: Int, notification: Int) abi("C"):
    """popoverDidClose: a click elsewhere or Escape: on_close (unless the screen already replaced it)."""
    var popover = msg(notification, "object")
    var holder = msg(msg(popover, "contentViewController"), "view")
    try:
        var tag = Int(from_ns(msg(holder, "identifier")))
        var host_addr = tag >> NODE_BITS
        var node = tag & ((1 << NODE_BITS) - 1)
        var host = host_at[A](host_addr)
        if host[].popover == popover:
            host[].popover = 0
            host[].popover_node = -1
            if node < len(host[].rt.shown.nodes):
                host[].send(node, True, "", 0, host_addr)
    except:
        return


def on_show_sheet[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    var tag = msg(number, "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if host[].sheet == 0 or host[].sheet_node != node:
        return
    _ = msg(host[].window, "beginSheet:completionHandler:", host[].sheet, 0)


def on_toast_timeout[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    var tag = msg(number, "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if host[].toast != 0 and from_ns(msg(host[].toast, "identifier")) == String(tag) and node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].kind == TOAST:
        host[].send(node, True, "", 0, host_addr)


def on_board_pan[A: App](target: Int, cmd: Int, recognizer: Int) abi("C"):
    """A Board child dragged: the Board's on_move with the child's index and how far (as GTK and the web send it)."""
    var child = msg(recognizer, "view")
    var state = msg(recognizer, "state")
    if tiled_pan[A](child, recognizer, state):
        return
    if state != 2:  # changed
        return
    try:
        var tag = Int(from_ns(msg(child, "identifier")))
        var host_addr = tag >> NODE_BITS
        var node = tag & ((1 << NODE_BITS) - 1)
        var host = host_at[A](host_addr)
        var parent = msg(child, "superview")
        var moved = msg[CGPoint](recognizer, "translationInView:", parent)
        _ = msg(recognizer, "setTranslation:inView:", Float64(0), Float64(0), parent)
        for b in range(len(host[].rt.shown.nodes)):
            ref board = host[].rt.shown.nodes[b]
            if board.kind != BOARD:
                continue
            for k in range(len(board.children)):
                if board.children[k] == node:
                    var d = host[].rt.gesture(b, PAN, Float64(k), 0, moved.x, moved.y, 1)  # (a flipped content view: y runs down)
                    host[].apply(d, host_addr)
                    return
    except:
        return


def make_grip(w: Int, h: Int, color: UInt32, flipped: Bool) -> Int:
    """A tiled card's resize grip: two short diagonal strokes in its bottom-right 18 pt (mojoui.boardlook's _grip on GTK
    and the web), taking no clicks (the Board's pan does the resizing). `flipped`: the card's y runs down (a boxed
    object's MojoBoardView), else up (its own stack); the grip keeps to the bottom-right corner as the card resizes."""
    var grip = new("NSView")  # (unflipped: its layer's y runs up, as the strokes below are written)
    _ = msg(grip, "setFrame:", Float64(w - 23), Float64(h - 23) if flipped else Float64(5), Float64(18), Float64(18))
    _ = msg(grip, "setAutoresizingMask:", 1 | (8 if flipped else 32))  # NSViewMinXMargin, and the margin above it (MinY flipped, MaxY not)
    _ = msg(grip, "setWantsLayer:", 1)
    var shape = new("CAShapeLayer")
    var path = new("NSBezierPath")
    for line in [(5.0, 1.0, 17.0, 13.0), (12.0, 1.0, 17.0, 6.0)]:  # ("/" strokes near the corner, y up)
        _ = msg(path, "moveToPoint:", line[0], line[1])
        _ = msg(path, "lineToPoint:", line[2], line[3])
    _ = msg(shape, "setPath:", msg(path, "CGPath"))
    _ = msg(shape, "setStrokeColor:", msg(ns_color(color), "CGColor"))
    _ = msg(shape, "setLineWidth:", Float64(2))
    _ = msg(shape, "setLineCap:", ns_string("round"))
    _ = msg(shape, "setFillColor:", 0)
    _ = msg(shape, "setFrame:", Float64(0), Float64(0), Float64(18), Float64(18))
    _ = msg(msg(grip, "layer"), "addSublayer:", shape)
    return grip


def end_tiled_drag[A: App](host_addr: Int, board: Int, index: Int, resized: Bool, dx: Float64, dy: Float64, view: Int = 0):
    """A tiled card's drag ended (tiled_pan's Ended, and the resize:/dragcard: test steps): the app hears ZOOM (resized)
    or PAN (moved) with the whole distance and its tiling decides; then the dragged view goes to the card's place as the
    app now has it, so a drop on nothing or a clamped resize snaps back (GTK's snap-back, D-5411) instead of staying
    where the pointer left it."""
    var host = host_at[A](host_addr)
    var d = host[].rt.gesture(board, ZOOM if resized else PAN, Float64(index), 0, dx, dy, 1)
    host[].apply(d, host_addr)
    if view != 0 and msg(view, "superview") != 0 and board < len(host[].rt.shown.nodes) and index < len(host[].rt.shown.nodes[board].children):
        ref n = host[].rt.shown.nodes[host[].rt.shown.nodes[board].children[index]]
        _ = msg(view, "setFrame:", Float64(n.x), Float64(n.y), Float64(n.w), Float64(n.h))


def tiled_pan[A: App](child: Int, recognizer: Int, state: Int) -> Bool:
    """A card on a tiled Board (Board(clips=True)) dragged, as GTK's Board does it: from its corner it resizes, from its
    header it moves; the view follows the pointer and the app hears once, at the end (ZOOM resized, PAN moved), with
    the whole distance, so its tiling decides (a swap, an edge moved). False: not a tiled Board's card."""
    try:
        var tag = Int(from_ns(msg(child, "identifier")))
        var host_addr = tag >> NODE_BITS
        var node = tag & ((1 << NODE_BITS) - 1)
        var host = host_at[A](host_addr)
        var board = -1
        var index = -1
        for b in range(len(host[].rt.shown.nodes)):
            if host[].rt.shown.nodes[b].kind == BOARD and host[].rt.shown.nodes[b].text == "clips":
                for k in range(len(host[].rt.shown.nodes[b].children)):
                    if host[].rt.shown.nodes[b].children[k] == node:
                        board = b
                        index = k
        if board < 0:
            return False
        var parent = msg(child, "superview")
        var f = msg[CGRect](child, "frame")
        if state == 1:  # began: where on the card (the Board's content is flipped: y runs down)
            var at = msg[CGPoint](recognizer, "locationInView:", parent)
            var lx = at.x - f.x
            var ly = at.y - f.y
            host[].pan_mode = 2 if (lx > f.width - 24 and ly > f.height - 24) else (1 if ly < 44 else 0)
            host[].pan_frame = f.copy()
            if host[].pan_mode == 0:  # (the card's own content: its controls, a canvas's gestures)
                _ = msg(recognizer, "setEnabled:", 0)  # (cancels it: state is read-only from outside)
                _ = msg(recognizer, "setEnabled:", 1)
            return True
        var moved = msg[CGPoint](recognizer, "translationInView:", parent)
        ref f0 = host[].pan_frame
        if state == 2 and host[].pan_mode == 1:
            _ = msg(child, "setFrameOrigin:", f0.x + moved.x, f0.y + moved.y)
        elif state == 2 and host[].pan_mode == 2:
            _ = msg(child, "setFrameSize:", max(f0.width + moved.x, Float64(60)), max(f0.height + moved.y, Float64(60)))
        elif state == 3 and host[].pan_mode > 0:  # ended: the app's tiling decides where everything goes
            var resized = host[].pan_mode == 2
            host[].pan_mode = 0
            end_tiled_drag[A](host_addr, board, index, resized, moved.x, moved.y, child)
        elif state >= 4:  # cancelled or failed: back where it was
            if host[].pan_mode > 0:
                _ = msg(child, "setFrame:", f0.x, f0.y, f0.width, f0.height)
            host[].pan_mode = 0
        return True
    except:
        return False


def make_toast(text: String, action: String, tag: Int, target: Int, pal: Palette) -> Int:
    """A toast: a dark rounded strip at the bottom with the message, its action (on_action) and ✕ (on_close)."""
    var strip = new("NSStackView")
    _ = msg(strip, "setOrientation:", 0)
    _ = msg(strip, "setSpacing:", Float64(12))
    _ = msg(strip, "setEdgeInsets:", Float64(10), Float64(14), Float64(10), Float64(10))
    _ = msg(strip, "setWantsLayer:", 1)
    _ = msg(msg(strip, "layer"), "setBackgroundColor:", msg(ns_color(pal.ink), "CGColor"))
    _ = msg(msg(strip, "layer"), "setCornerRadius:", Float64(6))
    _ = msg(strip, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
    _ = msg(strip, "setIdentifier:", ns_string(String(tag)))
    var message = msg(cls("NSTextField"), "labelWithString:", ns_string(text))
    _ = msg(message, "setTextColor:", ns_color(pal.card))
    _ = msg(strip, "addArrangedSubview:", message)
    if action != "":
        var b = msg(cls("NSButton"), "buttonWithTitle:target:action:", ns_string(action), target, sel("tap:"))
        _ = msg(b, "setBordered:", 0)
        _ = msg(b, "setContentTintColor:", ns_color(mix(pal.accent, pal.card, 0.55)))
        _ = msg(b, "setTag:", tag)
        _ = msg(strip, "addArrangedSubview:", b)
    var close = msg(cls("NSButton"), "buttonWithImage:target:action:", msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string("xmark"), ns_string("Close")), target, sel("closeOverlay:"))
    _ = msg(close, "setBordered:", 0)
    _ = msg(close, "setContentTintColor:", ns_color(pal.card))
    _ = msg(close, "setTag:", tag)
    _ = msg(strip, "addArrangedSubview:", close)
    return strip


def register_fonts():
    """The app's own fonts (Contents/Resources/fonts, D-155), registered for this process through CoreText."""
    var bundle = msg(cls("NSBundle"), "mainBundle")
    for name in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "JetBrainsMono-Regular", "JetBrainsMono-Bold", "Geist-Variable", "GeistMono-Variable"]:
        var url = msg(bundle, "URLForResource:withExtension:subdirectory:", ns_string(name), ns_string("ttf"), ns_string("fonts"))
        if url != 0:
            _ = cfunc[Int8]("CTFontManagerRegisterFontsForURL", url, 1, 0)  # kCTFontManagerScopeProcess


def on_submit[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], True, from_ns(msg(sender, "stringValue")), 0, t[0])


def on_text_change[A: App](target: Int, cmd: Int, notification: Int) abi("C"):
    var field = msg(notification, "object")
    var t = from_tag(field)
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(field, "stringValue")), 0, t[0])


def on_toggle[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], False, "", msg(sender, "state"), t[0])


def on_select[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var index = msg(sender, "indexOfSelectedItem")
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(sender, "titleOfSelectedItem")), index, t[0])


def on_segment[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var index = msg(sender, "selectedSegment")
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(sender, "labelForSegment:", index)), index, t[0])


def on_segment_pick[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    """A segment of the look's track (segment_track): its index among the track's buttons, as on_segment's."""
    var t = from_tag(sender)
    var index = msg(msg(msg(sender, "superview"), "arrangedSubviews"), "indexOfObject:", sender)
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(sender, "title")), index, t[0])


def on_radio[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var index = msg(msg(msg(sender, "superview"), "arrangedSubviews"), "indexOfObject:", sender)
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(sender, "title")), index, t[0])


def on_text_did_change[A: App](target: Int, cmd: Int, notification: Int) abi("C"):
    var text = msg(notification, "object")
    try:
        var tag = Int(from_ns(msg(text, "identifier")))
        var host_addr = tag >> NODE_BITS
        host_at[A](host_addr)[].send(tag & ((1 << NODE_BITS) - 1), False, from_ns(msg(text, "string")), 0, host_addr)
    except:
        return


def on_date[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], False, date_text(msg(sender, "dateValue")), 0, t[0])


def on_show_alert[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    """Runs the alert for an Alert node (if it's still on screen) and sends the answer."""
    var tag = msg(number, "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if node >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[node].kind != ALERT:
        return  # the screen changed before it could be shown
    var n = host[].rt.shown.nodes[node].copy()
    var alert = msg(msg(cls("NSAlert"), "new"), "autorelease")
    _ = msg(alert, "setMessageText:", ns_string(n.text))
    _ = msg(alert, "setInformativeText:", ns_string(n.hint))
    for o in n.options:
        _ = msg(alert, "addButtonWithTitle:", ns_string(o))
    var index = msg(alert, "runModal") - 1000  # NSAlertFirstButtonReturn = 1000
    if 0 <= index < len(n.options):
        host[].send(node, False, n.options[index], index, host_addr)


def on_row_count[A: App](target: Int, cmd: Int, table: Int) abi("C") -> Int:
    var t = from_tag(table)
    var host = host_at[A](t[0])
    if t[1] >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[t[1]].kind != LAZYLIST:
        return 0
    return host[].rt.shown.nodes[t[1]].value


def on_row_value[A: App](target: Int, cmd: Int, table: Int, column: Int, row: Int) abi("C") -> Int:
    """NSTableView asks for one row's text only when it scrolls into view."""
    var t = from_tag(table)
    var host = host_at[A](t[0])
    if t[1] >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[t[1]].kind != LAZYLIST:
        return 0
    return ns_string(host[].rt.app.row(host[].rt.shown.nodes[t[1]].msg2, row))


def on_row_tap[A: App](target: Int, cmd: Int, table: Int) abi("C"):
    var row = msg(table, "clickedRow")
    if row < 0:
        return
    var t = from_tag(table)
    host_at[A](t[0])[].send(t[1], False, "", row, t[0])


def on_slide[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var value = Int(msg[Float64](sender, "doubleValue") + 0.5)
    host_at[A](t[0])[].send(t[1], False, "", value, t[0])


def quit_when_closed(target: Int, cmd: Int, app: Int) abi("C") -> Int8:
    return 1  # YES to applicationShouldTerminateAfterLastWindowClosed:


def on_will_terminate[A: App](target: Int, cmd: Int, note: Int) abi("C"):
    """The app is quitting (Quit, the last window closed, a log out): App.closing, once, before the process ends."""
    var addr = 0
    var wins = msg(msg(cls("NSApplication"), "sharedApplication"), "windows")
    for i in range(msg(wins, "count")):  # (the host's window: its delegate is this target, its identifier the host's address)
        var w = msg(wins, "objectAtIndex:", i)
        if msg(w, "delegate") == target and msg(w, "identifier") != 0:
            addr = msg(msg(w, "identifier"), "longLongValue")
    if addr != 0:
        var first = not host_at[A](addr)[].rt.closed
        host_at[A](addr)[].rt.closing()  # (what must not be lost first; its pictures after)
        if first and host_at[A](addr)[].rt.app.draws_after_closing():
            host_at[A](addr)[].keep_views(addr)


def on_window_should_close[A: App](target: Int, cmd: Int, window: Int) abi("C") -> c_int:
    """The close button, Cmd+W: NO when the app would lose something (App.may_close); it says what."""
    var id = msg(window, "identifier")
    if id == 0:
        return 1
    var host = host_at[A](msg(id, "longLongValue"))
    if host[].rt.closed or host[].rt.app.may_close():
        return 1
    var d = host[].rt.refresh()
    host[].apply(d)
    print("WINDOW: kept open", flush=True)
    return 0


def on_should_terminate[A: App](target: Int, cmd: Int, app: Int) abi("C") -> Int:
    """Quit (Cmd+Q): NSTerminateCancel (0) when the app would lose something (App.may_close), NSTerminateNow (1) else."""
    var wins = msg(msg(cls("NSApplication"), "sharedApplication"), "windows")
    for i in range(msg(wins, "count")):
        var w = msg(wins, "objectAtIndex:", i)
        if msg(w, "delegate") == target and msg(w, "identifier") != 0:
            return 1 if on_window_should_close[A](target, cmd, w) != 0 else 0
    return 1


def on_window_will_close[A: App](target: Int, cmd: Int, notification: Int) abi("C"):
    """The window is closing (its close button, Cmd+W): App.closing, once, while the window still knows its host."""
    var window = msg(notification, "object")
    var id = msg(window, "identifier")
    if id != 0:
        var addr = msg(id, "longLongValue")
        var first = not host_at[A](addr)[].rt.closed
        host_at[A](addr)[].rt.closing()  # (what must not be lost first; its pictures after)
        if first and host_at[A](addr)[].rt.app.draws_after_closing():
            host_at[A](addr)[].keep_views(addr)


def make_menu(app: Int, title: String):
    var bar = new("NSMenu")
    var app_item = new("NSMenuItem")
    _ = msg(bar, "addItem:", app_item)
    var app_menu = new("NSMenu")
    _ = msg(app_menu, "addItemWithTitle:action:keyEquivalent:", ns_string("Close Window"), sel("performClose:"), ns_string("w"))
    _ = msg(app_menu, "addItemWithTitle:action:keyEquivalent:", ns_string("Quit " + title), sel("terminate:"), ns_string("q"))
    _ = msg(app_item, "setSubmenu:", app_menu)
    # Edit menu: gives text fields their Cut/Copy/Paste/Select All shortcuts.
    var edit_item = new("NSMenuItem")
    _ = msg(bar, "addItem:", edit_item)
    var edit = msg(msg(cls("NSMenu"), "alloc"), "initWithTitle:", ns_string("Edit"))
    _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Cut"), sel("cut:"), ns_string("x"))
    _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Copy"), sel("copy:"), ns_string("c"))
    _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Paste"), sel("paste:"), ns_string("v"))
    _ = msg(edit, "addItemWithTitle:action:keyEquivalent:", ns_string("Select All"), sel("selectAll:"), ns_string("a"))
    _ = msg(edit_item, "setSubmenu:", edit)
    _ = msg(app, "setMainMenu:", bar)


def run[A: App]() -> c_int:
    """Opens the app in a native AppKit window and runs until it's closed."""
    _ = pool_push()
    var host = alloc(Layout[AppKitHost[A]].single()).unsafe_leak()  # lives as long as the app
    host.unsafe_write(AppKitHost[A]())
    var addr = Int(host)
    if (addr >> (63 - NODE_BITS)) != 0:
        print("mojoui: can't pack host address into a control tag")
        return 1

    var app = msg(cls("NSApplication"), "sharedApplication")
    # a regular app: Dock icon and menu bar; MOJOUI_OFFSCREEN=1 (a check on someone's own Mac): an accessory app whose
    # window is never shown or focused, its pictures still drawn by cacheDisplayInRect: (D-5722)
    var offscreen = env("MOJOUI_OFFSCREEN") == "1"
    _ = msg(app, "setActivationPolicy:", 1 if offscreen else 0)
    var title = host[].rt.app.title()
    make_menu(app, title)  # (replaced by the app's own MenuBar when its screen has one, D-150)

    var c = new_class("MojoTarget", "NSObject")
    add_method(c, "tap:", on_tap[A], "v@:@")
    add_method(c, "paragraphTap:", on_paragraph_tap[A], "v@:@")
    add_method(c, "submit:", on_submit[A], "v@:@")
    add_method(c, "toggle:", on_toggle[A], "v@:@")
    add_method(c, "select:", on_select[A], "v@:@")
    add_method(c, "slide:", on_slide[A], "v@:@")
    add_method(c, "controlTextDidChange:", on_text_change[A], "v@:@")
    add_method(c, "focusField:", on_focus_field, "v@:@")
    add_method(c, "segment:", on_segment[A], "v@:@")
    add_method(c, "segmentPick:", on_segment_pick[A], "v@:@")
    add_method(c, "radio:", on_radio[A], "v@:@")
    add_method(c, "textDidChange:", on_text_did_change[A], "v@:@")
    add_method(c, "date:", on_date[A], "v@:@")
    add_method(c, "showAlert:", on_show_alert[A], "v@:@")
    add_method(c, "menuItem:", on_menu_item[A], "v@:@")
    add_method(c, "closeOverlay:", on_close_overlay[A], "v@:@")
    add_method(c, "debugRecord:", on_debug_record[A], "v@:@")
    add_method(c, "debugSnapshot:", on_debug_snapshot[A], "v@:@")
    add_method(c, "debugOpen:", on_debug_open[A], "v@:@")
    add_method(c, "debugQueued:", on_debug_queued[A], "v@:@")
    add_method(c, "effectsDue:", on_effects_due[A], "v@:@")
    add_method(c, "activityDue:", on_activity_due[A], "v@:@")
    add_method(c, "testStep:", on_test_step[A], "v@:@")
    add_method(c, "webInbox:", on_web_inbox[A], "v@:@")
    add_method(c, "systemAppearance:", on_system_appearance[A], "v@:@")
    add_method(c, "appearanceLater:", on_appearance_later[A], "v@:@")
    add_method(c, "windowDidResize:", on_window_resized[A], "v@:@")
    add_method(c, "jobsEnded:", on_jobs_ended[A], "v@:@")  # (mojoui.uijobs: a background job ended → App.jobs_message)
    add_method(c, "windowResizeLater:", on_window_resize_later[A], "v@:@")
    add_method(c, "showPopover:", on_show_popover[A], "v@:@")
    add_method(c, "popoverDidClose:", on_popover_closed[A], "v@:@")
    add_method(c, "showSheet:", on_show_sheet[A], "v@:@")
    add_method(c, "toastTimeout:", on_toast_timeout[A], "v@:@")
    add_method(c, "boardPan:", on_board_pan[A], "v@:@")
    add_protocol(c, "NSPopoverDelegate")
    add_method(c, "rowTap:", on_row_tap[A], "v@:@")
    add_method(c, "numberOfRowsInTableView:", on_row_count[A], "q@:@")
    add_method(c, "tableView:objectValueForTableColumn:row:", on_row_value[A], "@@:@@q")
    add_protocol(c, "NSTableViewDataSource")
    add_method(c, "applicationShouldTerminateAfterLastWindowClosed:", quit_when_closed, "B@:@")
    add_method(c, "applicationWillTerminate:", on_will_terminate[A], "v@:@")  # (App.closing)
    add_method(c, "windowShouldClose:", on_window_should_close[A], "B@:@")  # (App.may_close)
    add_method(c, "applicationShouldTerminate:", on_should_terminate[A], "Q@:@")
    add_method(c, "windowWillClose:", on_window_will_close[A], "v@:@")
    register_class(c)
    var canvas = new_class("MojoCanvas", "NSImageView")
    add_method(canvas, "canvasFrame:", on_canvas_frame[A], "v@:@")
    add_method(canvas, "canvasResized:", on_canvas_resized[A], "v@:@")
    add_method(canvas, "canvasPan:", on_canvas_pan[A], "v@:@")
    add_method(canvas, "canvasPinch:", on_canvas_pinch[A], "v@:@")
    add_method(canvas, "canvasTap:", on_canvas_tap[A], "v@:@")
    add_method(canvas, "canvasDouble:", on_canvas_double[A], "v@:@")
    add_method(canvas, "canvasSecondary:", on_canvas_secondary[A], "v@:@")
    add_method(canvas, "scrollWheel:", on_canvas_scroll[A], "v@:@")
    add_method(canvas, "acceptsFirstResponder", accepts_first_responder, "B@:")
    add_method(canvas, "acceptsFirstMouse:", accepts_first_mouse, "B@:@")
    add_method(canvas, "mouseDown:", on_canvas_mouse_down[A], "v@:@")
    add_method(canvas, "mouseMoved:", on_canvas_mouse_moved[A], "v@:@")
    add_method(canvas, "mouseDragged:", on_canvas_mouse_dragged[A], "v@:@")
    add_method(canvas, "mouseUp:", on_canvas_mouse_up[A], "v@:@")
    add_method(canvas, "keyDown:", on_canvas_key[A], "v@:@")
    if ime_install[A](canvas):  # (D-7979: bridge/mac_ime.m linked in)
        put_shared(SLOT_MAC_IME, 1)
    register_class(canvas)
    var board = new_class("MojoBoardView", "NSView")  # a Board's content: y from the top
    add_method(board, "isFlipped", is_flipped, "B@:")
    register_class(board)
    var label = new_class("MojoLabel", "NSTextField")  # a label whose words can change without a relayout (D-7582)
    add_method(label, "invalidateIntrinsicContentSize", on_label_invalidate, "v@:")
    add_method(label, "invalidateIntrinsicContentSizeForCell:", on_label_invalidate_cell, "v@:@")
    add_method(label, "setNeedsLayout:", on_label_needs_layout, "v@:B")
    register_class(label)
    var clip = new_class("MojoTopClipView", "NSClipView")  # a scroll view's clip: short content at the top
    add_method(clip, "isFlipped", is_flipped, "B@:")
    register_class(clip)
    register_fonts()
    host[].target = msg(c, "new")
    _ = msg(app, "setDelegate:", host[].target)

    var size = host[].rt.app.window_size()
    var forced = env("MOJOUI_WINDOW")  # tests, as GTK's: "1440x900" (scripts/side.py puts the hosts side by side at one size)
    if forced != "":
        var wh = split_at(forced, "x")
        size = (to_int(wh[0]), to_int(wh[1]))
    host[].window = msg(
        msg(cls("NSWindow"), "alloc"),
        "initWithContentRect:styleMask:backing:defer:",
        Float64(0), Float64(0), Float64(size[0]), Float64(size[1]),  # rect as 4 floats (arm64)
        1 | 2 | 4 | 8,  # titled, closable, miniaturizable, resizable
        2,  # NSBackingStoreBuffered
        0,  # defer: NO
    )
    _ = msg(host[].window, "setTitle:", ns_string(title))
    _ = msg(host[].window, "setReleasedWhenClosed:", 0)
    _ = msg(host[].window, "setIdentifier:", ns_string(String(addr)))  # (windowDidResize: finds the host by it)
    _ = host[].rt.resize(size[0], size[1])  # the app lays out to its window from the first screen (App.resize)
    host[].follow_appearance(addr)  # (light or dark, before the first screen: App.appearance, D-673)
    _ = msg(msg(cls("NSDistributedNotificationCenter"), "defaultCenter"), "addObserver:selector:name:object:", host[].target,
            sel("systemAppearance:"), ns_string("AppleInterfaceThemeChangedNotification"), 0)
    host[].show(addr)
    host[].schedule_effects(addr)  # (what the starting state asked for)
    _ = msg(host[].window, "center")
    if offscreen:
        _ = msg(host[].window, "setAlphaValue:", Float64(0))
        _ = msg(host[].window, "setIgnoresMouseEvents:", 1)
        _ = msg(host[].window, "orderBack:", 0)
    else:
        _ = msg(host[].window, "setAcceptsMouseMovedEvents:", 1)  # (the canvas's mouseMoved: → HOVER)
        _ = msg(host[].window, "makeKeyAndOrderFront:", 0)
    if forced != "":  # (a window larger than its screen was shrunk to fit: the runner's screen is 1024 pt wide)
        _ = msg(host[].window, "setContentSize:", Float64(size[0]), Float64(size[1]))
    _ = msg(host[].window, "setDelegate:", host[].target)  # windowDidResize: → App.resize
    # the size it really got: a window larger than its screen is shrunk before the delegate listens (GitHub's
    # 1024 pt screen: the app laid out to 1,432 pt in a 1,410 pt window, cutting the Report's right edge)
    host[].queue_resize(addr)
    if not offscreen:
        _ = msg(app, "activateIgnoringOtherApps:", 1)
    var steps = env("MOJOUI_TEST")
    if host[].rt.app.records() or steps != "":  # the app asks for a report from the start (the Mac check app), or a test run
        host[].start_report()
        host[].report.cause = "launch"
        host[].queue_snapshot(addr)
    if steps != "":  # MOJOUI_TEST="tap:Open the sample;resize:900x700;…": the steps run by themselves, then the app quits
        for part in steps.split(";"):  # (GTK's test_steps: a `stroke:` step keeps its points, x,y,p;x,y,p;… parts with no ":";
            var piece = String(part)  # here only parts that start as a number, so a bare `quit` after a stroke stays a step)
            var last = len(host[].steps) - 1
            var number = piece != "" and (piece.startswith("-") or piece.startswith(".") or (piece.as_bytes()[0] >= 48 and piece.as_bytes()[0] <= 57))
            if last >= 0 and host[].steps[last].startswith("stroke:") and ":" not in piece and number:
                host[].steps[last] += ";" + piece
            elif piece != "":
                host[].steps.append(piece)
        _ = msg(host[].target, "performSelector:withObject:afterDelay:", sel("testStep:"), ns_number(addr), Float64(2))
    _ = msg(app, "run")
    return 0
