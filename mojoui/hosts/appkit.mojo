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

from mojoui.view import (
    TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE,
    SEGMENTED, RADIO, TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, BOARD, OVERLAY,
    MENUBAR, MENU, ITEM, DIALOG, TOAST, POPOVER, CLIPBOARD, TABLE, ROUTE, DRAG, DROP, EMBED, PAN, ZOOM, TAP, PRESS, RELEASE, DOUBLE, SECONDARY, KEY,
    START, CENTER, END, STRETCH, BETWEEN, Node,
    TITLE, HEADLINE, CAPTION, PROMINENT, DESTRUCTIVE, SUBTLE, ICON_ONLY, ICON_ON, TOOL, TOOL_ON, TOOL_INLINE, TOOL_INLINE_ON, TOKEN, TOKEN_LIT,
    TONE_WARN, TONE_GOOD, TONE_STRONG, TONE_ACCENT, CARD, CARD_WARN, CARD_GOOD,
)
from mojoui.menus import CHECKED, DISABLED, DANGER
from mojoui.theme import Palette, Theme, mix
from mojoui.theme import Look
from mojoui.look import text_only
from mojoui.icons_data import lucide_svg
from mojoui.diff import Diff, SET_TEXT, SET_VALUE, SET_IMAGE, SET_PLACE, SET_SIZE
from mojoui.png import encode_png
from mojoui.app import App, Event, Runtime
from mojoui.clock import now_ns
from mojoui.canvas import Surface
from mojoui.hosts.apple_canvas import CGPoint, CGRect, cfunc, cg_image, AppleCanvas
from mojoui.hosts.mac_report import MacReport, MAX_SHOTS, pts
from mojoui.hosts.objc import (
    cls, sel, msg, new, ns_string, ns_data, ns_array, ns_number, ns_date, date_text, sf_symbol, from_ns, constrain, prefer,
    new_class, add_method, add_protocol, register_class, pool_push,
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
    var focus: Int  # text field to keep focused across the next rebuild (-1: none)
    var canvases: List[AppleCanvas]
    var link: Int  # an NSTimer at 60 Hz: one tick per frame, for every canvas (0 = stopped)
    var fx_due: Int  # when the runtime's effects (HTTP replies, timers) are next polled (µs; -1: nothing asked for)
    var resize_pending: Bool  # a new window size waits for the next run-loop turn (never rebuilt inside AppKit's layout)
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
    var report: MacReport  # Debug → Record: pictures and view dumps on the Desktop (mojoui/hosts/mac_report.mojo)
    var size_w: List[Int]  # per node: its fixed-width and fixed-height constraints (0: none), so a new size is a patch
    var size_h: List[Int]
    var sized: List[Tuple[Int, Int, Int, Int]]  # per node: the w, h, min_w, max_w it was built with
    var wraps: List[Int]  # a column's labels: they wrap to the width they're given (fit_wraps), as GTK's labels do
    var parents: List[Int]  # per node: its stack's node, or -1 (worked out once per build)
    var rebuilds: Int  # whole-window rebuilds since the last report snapshot (its log line says how many)
    var resized_in_place: Int
    var steps: List[String]  # MOJOUI_TEST: steps run one by one, a report recording each (the GitHub Mac runner, 2026-10-23)
    var step_at: Int

    def __init__(out self):
        Self.A.init_shared()
        self.rt = Runtime(Self.A())
        self.window = 0
        self.target = 0
        self.widgets = List[Int]()
        self.shells = List[Int]()
        self.objects = List[Int]()
        self.boxed = -1
        self.dashes = List[Tuple[Int, Int, Int, Int]]()
        self.rounds = List[Tuple[Int, Int]]()
        self.focus = -1
        self.canvases = List[AppleCanvas]()
        self.link = 0
        self.fx_due = -1
        self.resize_pending = False
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
        self.steps = List[String]()
        self.step_at = 0
        self.size_w = List[Int]()
        self.size_h = List[Int]()
        self.wraps = List[Int]()
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
        if node.kind == TEXT:
            w = msg(cls("NSTextField"), "labelWithString:", ns_string(node.text))
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
                _ = msg(w, "setTextColor:", ns_color(self.pal.ink3 if node.style == CAPTION else self.pal.ink2))
            var tl = self.text_look(i)
            if tl >= 0:  # a surface's own type (the status bar's figures: Inter 12 on Liquid, JetBrains Mono on the skins)
                ref sf = self.look.surfaces[tl]
                if sf.font != "" or sf.font_size > 0 or sf.font_weight > 0:  # (no size of its own: the label keeps its style's, a caption's 12)
                    _ = msg(w, "setFont:", look_font(sf.font if sf.font != "" else self.look.type.family, sf.font_weight, sf.font_size if sf.font_size > 0 else msg[Float64](msg(w, "font"), "pointSize"), self.look.type.tabular))
                if sf.ink != 0:
                    _ = msg(w, "setTextColor:", ns_color(sf.ink))
                if sf.tracking != 0:  # (letter spacing: the label's string with NSKern, in its own font and colour)
                    var attrs = new("NSMutableDictionary")
                    _ = msg(attrs, "setObject:forKey:", msg(w, "font"), ns_string("NSFont"))
                    _ = msg(attrs, "setObject:forKey:", msg(w, "textColor"), ns_string("NSColor"))
                    _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithDouble:", sf.tracking), ns_string("NSKern"))
                    _ = msg(w, "setAttributedStringValue:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(node.text), attrs))
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
                elif self.look.type.line > 0:
                    lh = msg[Float64](font, "pointSize") * self.look.type.line
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
                    _ = msg(w, "setAttributedStringValue:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(node.text), attrs))
            var p = self.parents[i] if i < len(self.parents) else -1
            if node.w > 0 or (p >= 0 and self.rt.shown.nodes[p].kind == VSTACK and self.rt.shown.nodes[p].align_items == START):
                _ = msg(w, "setAlignment:", 0)  # a leading column's lines (or a table's cell) read from the leading edge, as on GTK
            if node.max_w == 0 and node.w == 0 and not self.in_row(i):  # a column's label: one line, wrapping when squeezed
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
                if c.icon > 0:  # the look's icon button: a square, its corners rounded (GTK: min-width/min-height)
                    constrain(w, "widthAnchor", Float64(c.icon))
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
                    var fit = msg[CGPoint](w, "fittingSize")
                    constrain(w, "widthAnchor", fit.x + Float64(2 * c.inline_pad + 6))  # (6: the gap GTK leaves between icon and title)
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
            if node.align_items == START and not icon_only:  # its content at the leading edge (a sidebar row)
                _ = msg(w, "setAlignment:", 0)  # NSTextAlignmentLeft
                if node.hint != "":
                    _ = msg(w, "setImagePosition:", 7)  # NSImageLeading: icon, then title, from the leading edge
        elif node.kind == FIELD:
            w = msg(cls("NSTextField"), "textFieldWithString:", ns_string(node.text))
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
            for k in range(len(node.children)):
                if k % node.value == 0:
                    row = new("NSStackView")
                    _ = msg(row, "setOrientation:", 0)
                    _ = msg(row, "setDistribution:", 1)  # fill equally
                    _ = msg(row, "setSpacing:", Float64(node.spacing))
                    _ = msg(w, "addArrangedSubview:", row)
                    # every row spans the grid, its columns equal (as GTK's homogeneous grid): a row of its own size sat
                    # centred, so the Report's chart tile was half as wide as the tiles above it (GitHub's Mac, 2026-10-23)
                    _ = msg(msg(msg(row, "widthAnchor"), "constraintEqualToAnchor:", msg(w, "widthAnchor")), "setActive:", 1)
                _ = msg(row, "addArrangedSubview:", self.build(node.children[k], self_addr))
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
        elif node.kind == TABLE:  # rows of stacks, the columns equal (NSGridView would size them to their content: not yet)
            w = new("NSStackView")
            _ = msg(w, "setOrientation:", 1)
            _ = msg(w, "setSpacing:", Float64(0))
            var cols = max(node.value, 1)
            var row = 0
            for k in range(len(node.children)):
                if k % cols == 0:
                    row = new("NSStackView")
                    _ = msg(row, "setOrientation:", 0)
                    _ = msg(row, "setDistribution:", 1)  # fill equally
                    _ = msg(row, "setSpacing:", Float64(16))
                    _ = msg(row, "setEdgeInsets:", Float64(9), Float64(16), Float64(9), Float64(16))
                    _ = msg(w, "addArrangedSubview:", row)
                    _ = msg(msg(msg(row, "widthAnchor"), "constraintEqualToAnchor:", msg(w, "widthAnchor")), "setActive:", 1)
                _ = msg(row, "addArrangedSubview:", self.build(node.children[k], self_addr))
        elif node.kind == SCROLL:
            w = top_scroll_view(False)
            _ = msg(w, "setDrawsBackground:", 0)
            var content = self.build(node.children[0], self_addr)
            _ = msg(content, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            _ = msg(w, "setDocumentView:", content)
            var clip = msg(w, "contentView")
            for anchor in ["topAnchor", "leadingAnchor", "widthAnchor"]:
                var pin = msg(msg(content, anchor), "constraintEqualToAnchor:", msg(clip, anchor))
                if anchor == "widthAnchor":  # (content the app made wider is cut off at the edge: it never widens the window)
                    _ = msg(pin, "setPriority:", Float32(495))  # below NSLayoutPriorityWindowSizeStayPut (500), above a wrapping label (490)
                _ = msg(pin, "setActive:", 1)
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(320))
            if node.value == 1:
                self.pinned.append(i)
        else:  # (a Draggable, a DropTarget and a WebFrame show their one child: drag and drop isn't built here yet)
            w = new("NSStackView")
            var vertical = node.kind == VSTACK or node.kind == DRAG or node.kind == DROP or node.kind == EMBED
            _ = msg(w, "setOrientation:", 1 if vertical else 0)
            # align → NSStackView alignment (NSLayoutAttribute); STRETCH = per-child constraints below
            var align = 9 if vertical else 10  # centre X / centre Y
            if node.align_items == START:
                align = 5 if vertical else 3  # leading / top
            elif node.align_items == END:
                align = 6 if vertical else 4  # trailing / bottom
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
            var inset_x = node.pad_h  # (what a filling child leaves on each side: the view's padding, or its role's)
            var inset_y = node.pad_v
            if look_at >= 0:  # a framework role the theme's look shapes (the toolbar's island, the inspector's panel)
                var own_pad = node.pad_v == 0 and node.pad_h == 0
                self.paint_surface(w, look_at, own_pad)
                if node.w > 0 and node.h > 0:  # a fixed size (a dot): its corners at most half of it now
                    var r = max(self.look.surfaces[look_at].radius_top, self.look.surfaces[look_at].radius_bottom)
                    _ = msg(msg(w, "layer"), "setCornerRadius:", min(Float64(r), Float64(min(node.w, node.h)) / 2))
                if own_pad and self.look.surfaces[look_at].pad_top >= 0:
                    inset_x = self.look.surfaces[look_at].pad_x
                    inset_y = (self.look.surfaces[look_at].pad_top + self.look.surfaces[look_at].pad_bottom) // 2
            elif self.skinned and (node.name == "toolbar" or node.name == "status-bar" or node.name == "menubar"):  # the chrome band
                _ = msg(w, "setWantsLayer:", 1)
                _ = msg(msg(w, "layer"), "setBackgroundColor:", msg(ns_color(self.pal.chrome), "CGColor"))
            # justify → distribution (BETWEEN) or flexible spacers (START, CENTER, END), all native
            var grows = False
            var spacers = False  # a Spacer takes the free space along its stack, as GTK's expanding one (it sat 0 pt tall
            for c in node.children:  # and the status bar floated mid-window, GitHub's Mac, 2026-10-23)
                grows = grows or self.rt.shown.nodes[c].grows
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
            var before = lead  # (the view before this one in the stack: a Divider's room goes after it)
            for c in node.children:
                var child = self.build(c, self_addr)
                _ = msg(w, "addArrangedSubview:", child)
                ref cn = self.rt.shown.nodes[c]
                if cn.kind == DIVIDER and not (cn.sized_width() if not vertical else cn.sized_height()):
                    # a Divider keeps its room each side, as the web's hr: 4 pt above and below in a column, 6 pt beside it in a row (D-440)
                    var room = Float64(node.spacing + (4 if vertical else 6))
                    if before != 0:
                        _ = msg(w, "setCustomSpacing:afterView:", room, before)
                    _ = msg(w, "setCustomSpacing:afterView:", room, child)
                before = child
                if cn.grows:  # flex-grow: lowest hugging priority along the stack
                    hug(child, Float32(1), vertical)
                elif cn.kind == SPACER:  # (a growing view first, if there is one)
                    hug(child, Float32(2 if grows else 1), vertical)
                    if first_spacer != 0:  # spacers share the free space equally, as GTK's expanding ones (a toolbar's
                        var along = "heightAnchor" if vertical else "widthAnchor"  # middle tools sit centred)
                        _ = msg(msg(msg(child, along), "constraintEqualToAnchor:", msg(first_spacer, along)), "setActive:", 1)
                    else:
                        first_spacer = child
                elif grows or spacers:  # beside a growing view, keep to its own size (a chevron took a row's spare room, Mac)
                    hug(child, Float32(750), vertical)
                if cn.fills or node.align_items == STRETCH:  # stretch across: match the stack minus its insets
                    var side = "widthAnchor" if vertical else "heightAnchor"
                    var inset = Float64(2 * (inset_x if vertical else inset_y))
                    var c2 = msg(msg(child, side), "constraintEqualToAnchor:constant:", msg(w, side), -inset)
                    _ = msg(c2, "setActive:", 1)
            if node.justify_items == CENTER and not grows and not spacers:
                var trail = flexible_spacer(vertical)
                _ = msg(w, "addArrangedSubview:", trail)
                var side = "heightAnchor" if vertical else "widthAnchor"
                _ = msg(msg(msg(trail, side), "constraintEqualToAnchor:", msg(lead, side)), "setActive:", 1)
            elif node.justify_items == START and not grows and not spacers:
                _ = msg(w, "addArrangedSubview:", flexible_spacer(vertical))
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
        _ = msg(layer, "setBackgroundColor:", msg(ns_color(fill) if fill != 0 else msg(cls("NSColor"), "clearColor"), "CGColor"))
        if line != 0:
            _ = msg(layer, "setBorderWidth:", Float64(1))
            _ = msg(layer, "setBorderColor:", msg(ns_color(line), "CGColor"))
        _ = msg(layer, "setCornerRadius:", Float64(min(radius, high // 2)))
        var attrs = new("NSMutableDictionary")
        _ = msg(attrs, "setObject:forKey:", look_font(family, weight, size, self.look.type.tabular), ns_string("NSFont"))
        _ = msg(attrs, "setObject:forKey:", ns_color(ink), ns_string("NSColor"))
        var said = msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(title), attrs)
        _ = msg(w, "setAttributedTitle:", said)
        _ = msg(w, "setContentTintColor:", ns_color(ink))
        var fit = msg[CGPoint](w, "fittingSize")
        if k >= 0:  # (a role's button: its words, an icon and the web's 6 pt gap, the role's padding, as CSS measures it; a bare cell adds its own 6)
            var words = msg[CGPoint](said, "size")
            fit.x = Float64(Int(words.x + 0.999)) + (Float64(c.glyph if c.glyph > 0 else 16) + 6 if msg(w, "image") != 0 else 0)
        # its title's width is the least it takes and the width it prefers, not a fixed one: a filling button (an
        # inspector row's title) stretches, as on GTK and the web; held to its fit, it held the Report inspector's
        # column to 117 pt through the rows' equal widths (Mac, 2026-10-24)
        _ = msg(msg(msg(w, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", fit.x + Float64(2 * pad)), "setActive:", 1)
        prefer(w, "widthAnchor", fit.x + Float64(2 * pad))
        if i < 0 or self.rt.shown.nodes[i].h == 0:  # (apply_layout pins the app's own height)
            constrain(w, "heightAnchor", Float64(high))

    def box_inset(self, i: Int, name: String) -> Tuple[Int, Int]:
        """What a Board object's role box takes from its content's size: the role's padding, across and down."""
        var k = self.look.surface(name)
        if k < 0 or self.look.surfaces[k].pad_top < 0:
            return (0, 0)
        return (2 * self.look.surfaces[k].pad_x, self.look.surfaces[k].pad_top + self.look.surfaces[k].pad_bottom)

    def paint_surface(mut self, w: Int, k: Int, pad: Bool):
        """A look's surface on a stack's layer (mojoui/look.mojo; GTK and the web write the same values as CSS): its fill,
        corners (top and bottom apart), its rim as the layer's border, its widest shadow as the layer's shadow (a layer
        has one), hairlines along its edges, its padding unless the component set its own (as on the web, where the
        view's own padding wins over the sheet's)."""
        var sf = self.look.surfaces[k].copy()
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
            _ = msg(layer, "setBorderColor:", msg(ns_color(sf.outline), "CGColor"))
        elif sf.outline != 0:  # dashes: a shape layer whose path follows the view's size (dash_paths, after each layout)
            var shape = new("CAShapeLayer")
            _ = msg(shape, "setStrokeColor:", msg(ns_color(sf.outline), "CGColor"))
            _ = msg(shape, "setFillColor:", msg(msg(cls("NSColor"), "clearColor"), "CGColor"))
            _ = msg(shape, "setLineWidth:", Float64(sf.outline_w))
            var pattern = new("NSMutableArray")
            _ = msg(pattern, "addObject:", ns_number(6))
            _ = msg(pattern, "addObject:", ns_number(4))
            _ = msg(shape, "setLineDashPattern:", pattern)
            _ = msg(layer, "addSublayer:", shape)
            self.dashes.append((w, shape, max(sf.radius_top, 0), sf.outline_w))
        if pad and sf.pad_top >= 0:
            _ = msg(w, "setEdgeInsets:", Float64(sf.pad_top), Float64(sf.pad_x), Float64(sf.pad_bottom), Float64(sf.pad_x))
        if sf.min_height > 0:
            _ = msg(msg(msg(w, "heightAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(sf.min_height)), "setActive:", 1)

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
            self.paint_surface(outer, chip_at, node.pad_v == 0 and node.pad_h == 0)
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
        self.size_w = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.wraps = List[Int]()
        self.parents = List[Int](length=len(self.rt.shown.nodes), fill=-1)
        for k in range(len(self.rt.shown.nodes)):
            if self.rt.shown.nodes[k].kind == HSTACK or self.rt.shown.nodes[k].kind == VSTACK:
                for c in self.rt.shown.nodes[k].children:
                    self.parents[c] = k
        self.size_h = List[Int](length=len(self.rt.shown.nodes), fill=0)
        self.sized = List[Tuple[Int, Int, Int, Int]](length=len(self.rt.shown.nodes), fill=(0, 0, 0, 0))
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
            _ = msg(self.window, "setContentView:", root)
        else:
            var holder = new("NSStackView")  # centres the app's root in the window
            _ = msg(holder, "setOrientation:", 1)
            _ = msg(holder, "setAlignment:", 9)
            _ = msg(holder, "setEdgeInsets:", Float64(32), Float64(32), Float64(32), Float64(32))
            _ = msg(holder, "addArrangedSubview:", root)
            _ = msg(self.window, "setContentView:", holder)
        self.attach_toast()
        self.fit_wraps()
        self.dash_paths()
        self.start_frames()
        if 0 <= self.focus < len(self.widgets) and self.rt.shown.nodes[self.focus].kind == FIELD:
            # Keep typing in the new field, on the next run-loop turn (after AppKit has
            # finished ending the old field's edit), with the cursor at the end.
            _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("focusField:"), self.widgets[self.focus], Float64(0))
        self.focus = -1
        self.add_debug_menu(self_addr)

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
                _ = msg(msg(cls("NSWorkspace"), "sharedWorkspace"), "openURL:", msg(cls("NSURL"), "URLWithString:", ns_string(n.hint if n.hint != "" else n.text)))

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
            if p.op == SET_TEXT and kind != TEXTAREA and kind != DATE and kind != NAVBAR:
                if kind == TEXT:  # (in the words' own attributes: the look's line height, letter spacing)
                    var had = msg(w, "attributedStringValue")
                    if had != 0 and msg(had, "length") > 0:
                        var attrs = msg(had, "attributesAtIndex:effectiveRange:", 0, 0)
                        _ = msg(w, "setAttributedStringValue:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(p.text), attrs))
                    else:
                        _ = msg(w, "setStringValue:", ns_string(p.text))
                elif kind == FIELD:
                    if from_ns(msg(w, "stringValue")) != p.text:  # don't fight the typist
                        _ = msg(w, "setStringValue:", ns_string(p.text))
                else:  # buttons and checkboxes (a drawn button's title keeps its type and ink)
                    var had = msg(w, "attributedTitle") if kind == BUTTON else 0
                    if had != 0 and msg(had, "length") > 0:
                        var attrs = msg(had, "attributesAtIndex:effectiveRange:", 0, 0)
                        _ = msg(w, "setAttributedTitle:", msg(msg(cls("NSAttributedString"), "alloc"), "initWithString:attributes:", ns_string(p.text), attrs))
                    else:
                        _ = msg(w, "setTitle:", ns_string(p.text))
            elif p.op == SET_VALUE:
                if kind == TOGGLE:
                    _ = msg(w, "setState:", p.number)
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

    def fit_wraps(self):
        """Each column label wraps at the width the layout gave it: an NSTextField only wraps at a width it's told, so
        lay out, tell each label its width, lay out again (a long inspector line ran past the panel, GitHub's Mac)."""
        if len(self.wraps) == 0 or self.window == 0:
            return
        var content = msg(self.window, "contentView")
        var here = List[Int]()  # (a popover's or a sheet's labels are in their own window: show_popover sets theirs)
        for l in self.wraps:
            if (msg(l, "isDescendantOf:", content) & 0xFF) != 0:
                here.append(l)
        for l in here:  # one line again, the width the layout allows now: 0 meant "the frame's width" to AppKit, and inside
            _ = msg(l, "setPreferredMaxLayoutWidth:", Float64(100000))  # a scroll view that frame started tiny, so the column shrank to 117 pt (the Report's inspector, 2026-10-24)
        _ = msg(content, "layoutSubtreeIfNeeded")
        for l in here:
            _ = msg(l, "setPreferredMaxLayoutWidth:", msg[CGRect](l, "frame").width)
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
        self.report.pending = False
        if not self.report.on or self.report.count >= MAX_SHOTS or self.window == 0:
            return
        var name = self.report.next_name()
        var content = msg(self.window, "contentView")
        var pictured = self.report.save_png(content, name + ".png")
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
                var t = n.text if n.text.byte_length() <= 60 else String(n.text[byte=:57]) + "..."
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
            if w == 0:
                if n.kind != ITEM and n.kind != MENU and n.kind != CLIPBOARD and n.kind != ROUTE and n.kind != DIALOG and n.kind != POPOVER and n.kind != TOAST and n.kind != SPACER:
                    line += "  (no view)"
            elif (msg(w, "isKindOfClass:", cls("NSView")) & 0xFF) != 0:
                var b = msg[CGRect](w, "bounds")
                var r = msg[CGRect](w, "convertRect:toView:", b.x, b.y, b.width, b.height, 0)
                if n.kind == TEXT and (i >= len(self.shells) or self.shells[i] == 0):  # the text's own box: a label's frame has 2 pt each side
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
                        if self.canvases[k].wpx == 0:
                            problems.append("canvas node " + String(i) + " (id " + String(n.style) + ") was never drawn")
                if (n.kind == SCROLL or n.kind == BOARD) and (msg(w, "respondsToSelector:", sel("contentView")) & 0xFF) != 0:
                    # its clip (what the content gets), its bars' style (0 legacy, 1 overlay), the vertical bar's width and
                    # whether it shows, and its content insets (top, left, bottom, right): where a narrow clip's points went
                    var clip = msg[CGRect](msg(w, "contentView"), "frame")
                    var bar = msg(w, "verticalScroller")
                    var ins = msg[CGRect](w, "contentInsets")
                    flags += (" clip " + pts(clip.width) + "x" + pts(clip.height) + " bars " + String(msg(w, "scrollerStyle"))
                              + " vbar " + (pts(msg[CGRect](bar, "frame").width) + ("" if (msg(bar, "isHidden") & 0xFF) == 0 else " hidden") if bar != 0 else "none")
                              + " insets " + pts(ins.x) + "," + pts(ins.y) + "," + pts(ins.width) + "," + pts(ins.height))
                if n.kind == ICON or ((n.kind == BUTTON) and n.hint != ""):
                    var name = n.text if n.kind == ICON else n.hint
                    if sf_symbol(name) == "questionmark.square.dashed" and name != "app-logo":
                        flags += " NO-SYMBOL(" + name + ")"
                        problems.append("icon '" + name + "' has no SF Symbol")
                line += flags
            out += line + "\n"
            var kids = n.children.copy()
            var j = len(kids) - 1
            while j >= 0:
                stack.append((kids[j], depth + 1))
                j -= 1
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
            self.fit_wraps()
        self.dash_paths()

    # ---------- canvases ----------

    def canvas_at(self, node: Int) -> Int:
        for k in range(len(self.canvases)):
            if self.canvases[k].node == node:
                return k
        return -1

    def canvas_send(mut self, node: Int, kind: Int, x: Float64, y: Float64, dx: Float64, dy: Float64, zoom: Float64, self_addr: Int):
        if self.report.on and kind != PAN and kind != ZOOM:
            self.report.cause = "canvas " + gesture_name(kind)
            self.report.note("event: canvas node " + String(node) + " " + gesture_name(kind) + " at " + pts(x) + ", " + pts(y))
        var d = self.rt.gesture(node, kind, x, y, dx, dy, zoom)
        self.apply(d, self_addr)

    def tick(mut self, seconds: Float64, self_addr: Int):
        """Every display frame: frame events for canvases that asked, then redraws."""
        self.ticks += 1
        if self.ticks == 1:
            self.report.note("frames: first tick")
        var micro = Int((seconds - self.last_frame) * 1e6) if self.last_frame > 0 and seconds - self.last_frame < 0.25 else 16667
        self.last_frame = seconds
        var k = 0
        while k < len(self.canvases):
            var node = self.canvases[k].node
            if self.rt.shown.nodes[node].msg2 != 0:
                var d = self.rt.frame(node, micro)
                self.apply(d, self_addr)
                if d.rebuild:
                    return
            self.draw_canvas(k, self_addr)
            k += 1
        if self.link != 0 and self.idle():  # nothing to animate or redraw: stop waking up
            _ = msg(self.link, "invalidate")
            self.link = 0

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

    def draw_canvas(mut self, k: Int, self_addr: Int):
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
        if len(self.canvases[k].pixels) != wpx * hpx:
            self.canvases[k].pixels = List[UInt32](length=wpx * hpx, fill=0)
        var surface = Surface(Int(self.canvases[k].pixels.unsafe_ptr()), wpx, hpx, scale)
        var d = self.rt.draw(node, surface)
        if wpx != self.canvases[k].wpx or hpx != self.canvases[k].hpx:
            self.report.note("canvas node " + String(node) + " (id " + String(self.rt.shown.nodes[node].style) + ") drew " + String(wpx) + "x" + String(hpx) + " px, "
                             + pts(bounds.width) + "x" + pts(bounds.height) + " pt")
        var image = cg_image(self.canvases[k].pixels, wpx, hpx)
        if image == 0:
            self.report.note("canvas node " + String(node) + ": no CGImage from its pixels")
            return
        var picture = msg(msg(cls("NSImage"), "alloc"), "initWithCGImage:size:", image, bounds.width, bounds.height)
        _ = msg(view, "setImage:", picture)
        _ = msg(picture, "release")
        cfunc[NoneType]("CGImageRelease", image)
        self.canvases[k].wpx = wpx
        self.canvases[k].hpx = hpx
        self.canvases[k].drawn = version
        self.apply(d, self_addr)

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


def kind_name(kind: Int) -> String:
    """A node's kind, for the report."""
    var names: List[Tuple[Int, String]] = [(TEXT, "Text"), (BUTTON, "Button"), (VSTACK, "VStack"), (HSTACK, "HStack"), (SPACER, "Spacer"), (FIELD, "TextField"),
        (TOGGLE, "Toggle"), (DROPDOWN, "Dropdown"), (SLIDER, "Slider"), (PROGRESS, "Progress"), (DIVIDER, "Divider"), (SCROLL, "Scroll"), (IMAGE, "Image"),
        (SEGMENTED, "Segmented"), (RADIO, "Radio"), (TEXTAREA, "TextArea"), (ALERT, "Alert"), (TABS, "Tabs"), (NAVBAR, "NavBar"), (DATE, "Date"),
        (ICON, "Icon"), (GRID, "Grid"), (LAZYLIST, "LazyList"), (CANVAS, "Canvas"), (BOARD, "Board"), (OVERLAY, "Overlay"), (MENUBAR, "MenuBar"),
        (MENU, "Menu"), (ITEM, "Item"), (DIALOG, "Dialog"), (TOAST, "Toast"), (POPOVER, "Popover"), (CLIPBOARD, "Clipboard"), (TABLE, "Table"), (ROUTE, "Route")]
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
    return "gesture" + String(kind)


def hug(view: Int, priority: Float32, vertical: Bool):
    """How firmly a view keeps its own size along a stack; a stack view (a padded leaf's wrapper too) hugs its views
    by a priority of its own."""
    var orientation = 1 if vertical else 0
    _ = msg(view, "setContentHuggingPriority:forOrientation:", priority, orientation)
    if msg[Int8](view, "respondsToSelector:", sel("setHuggingPriority:forOrientation:")) != 0:
        _ = msg(view, "setHuggingPriority:forOrientation:", priority, orientation)


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
    host[].canvas_send(t[1], PRESS, at.x, at.y, 0, 0, 1, t[0])


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
    host[].canvas_send(t[1], PAN, at.x, at.y, dx, dy, 1, t[0])


def on_canvas_mouse_up[A: App](view: Int, cmd: Int, event: Int) abi("C"):
    """The button comes up: RELEASE after a drag, TAP after a click (as GTK's click gesture's released)."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var at = event_point(view, event)
    var k = host[].canvas_at(t[1])
    if k >= 0 and host[].canvases[k].moved:
        host[].canvas_send(t[1], RELEASE, at.x, at.y, 0, 0, 1, t[0])
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
    var d = host[].rt.key(t[1], name, mods)
    host[].apply(d, t[0])


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
    """Mouse wheel (4 notches = 2×) or trackpad scroll (pixels): zoom around the pointer."""
    var t = from_tag(view)
    var dy = msg[Float64](event, "scrollingDeltaY")
    var precise = (msg(event, "hasPreciseScrollingDeltas") & 0xFF) != 0
    var window_point = msg[CGPoint](event, "locationInWindow")
    var at = in_view(view, msg[CGPoint](view, "convertPoint:fromView:", window_point.x, window_point.y, 0))
    var notches = dy / 100.0 * 4.0 if precise else dy
    host_at[A](t[0])[].canvas_send(t[1], ZOOM, at.x, at.y, 0, 0, 2.0 ** (notches / 4.0), t[0])


def on_tap[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], False, "", 0, t[0])


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


def find_node[A: App](host: AppKitHost[A], kind: Int, label: String, nth: Int, by_hint: Bool = False) -> Int:
    """The nth node of `kind` whose text (or hint) is `label` ("" = any), as the GTK host's test steps find it."""
    var seen = 0
    for i in range(len(host.rt.shown.nodes)):
        ref n = host.rt.shown.nodes[i]
        if n.kind == kind and (label == "" or (n.hint if by_hint else n.text) == label):
            if seen == nth:
                return i
            seen += 1
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
    elif verb == "resize":  # resize:900x700: the window's content size, as a drag of its edge ends
        var wh = split_at(rest, "x")
        _ = msg(host[].window, "setContentSize:", Float64(to_int(wh[0])), Float64(to_int(wh[1])))
    elif verb != "wait" and verb != "pause":  # (pause:ms as GTK's and the web's; wait:ms the Mac's older word)
        host[].report.note("TEST: unknown step " + step)


def on_test_step[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    """The next MOJOUI_TEST step, then a picture once the screen settles; after the last, quit."""
    var addr = msg(number, "longLongValue")
    var host = host_at[A](addr)
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
    run_step[A](addr, step)
    host[].report.cause = "step-" + String(host[].step_at)
    host[].queue_snapshot(addr)
    var wait = 1.5
    if step.startswith("wait:") or step.startswith("pause:"):
        wait = Float64(to_int(split_at(step, ":")[1])) / 1000.0
    _ = msg(host[].target, "performSelector:withObject:afterDelay:", sel("testStep:"), ns_number(addr), wait)


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
    if msg(recognizer, "state") != 2:  # changed
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
    _ = msg(app, "setActivationPolicy:", 0)  # a regular app: Dock icon and menu bar
    var title = host[].rt.app.title()
    make_menu(app, title)  # (replaced by the app's own MenuBar when its screen has one, D-150)

    var c = new_class("MojoTarget", "NSObject")
    add_method(c, "tap:", on_tap[A], "v@:@")
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
    add_method(c, "testStep:", on_test_step[A], "v@:@")
    add_method(c, "windowDidResize:", on_window_resized[A], "v@:@")
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
    add_method(canvas, "mouseDragged:", on_canvas_mouse_dragged[A], "v@:@")
    add_method(canvas, "mouseUp:", on_canvas_mouse_up[A], "v@:@")
    add_method(canvas, "keyDown:", on_canvas_key[A], "v@:@")
    register_class(canvas)
    var board = new_class("MojoBoardView", "NSView")  # a Board's content: y from the top
    add_method(board, "isFlipped", is_flipped, "B@:")
    register_class(board)
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
    host[].show(addr)
    host[].schedule_effects(addr)  # (what the starting state asked for)
    _ = msg(host[].window, "center")
    _ = msg(host[].window, "makeKeyAndOrderFront:", 0)
    if forced != "":  # (a window larger than its screen was shrunk to fit: the runner's screen is 1024 pt wide)
        _ = msg(host[].window, "setContentSize:", Float64(size[0]), Float64(size[1]))
    _ = msg(host[].window, "setDelegate:", host[].target)  # windowDidResize: → App.resize
    # the size it really got: a window larger than its screen is shrunk before the delegate listens (GitHub's
    # 1024 pt screen: the app laid out to 1,432 pt in a 1,410 pt window, cutting the Report's right edge)
    host[].queue_resize(addr)
    _ = msg(app, "activateIgnoringOtherApps:", 1)
    var steps = env("MOJOUI_TEST")
    if host[].rt.app.records() or steps != "":  # the app asks for a report from the start (the Mac check app), or a test run
        host[].start_report()
        host[].report.cause = "launch"
        host[].queue_snapshot(addr)
    if steps != "":  # MOJOUI_TEST="tap:Open the sample;resize:900x700;…": the steps run by themselves, then the app quits
        for part in steps.split(";"):
            if String(part) != "":
                host[].steps.append(String(part))
        _ = msg(host[].target, "performSelector:withObject:afterDelay:", sel("testStep:"), ns_number(addr), Float64(2))
    _ = msg(app, "run")
    return 0
