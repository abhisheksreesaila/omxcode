# Mac host: draws a mojoui View with real AppKit controls.
#
# Events: every control's tag packs the host's address and the node index
# ((host << 16) | node), and its target is one MojoTarget object whose methods
# (tap:, submit:, toggle:, select:, slide:, controlTextDidChange:) are Mojo
# functions. AppKit doesn't send actions when we set values ourselves, so there's
# no echo to guard against (unlike GTK).

from std.ffi import c_int
from std.memory import Pointer
from std.memory.alloc import alloc, Layout

from mojoui.view import (
    TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE,
    SEGMENTED, RADIO, TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, BOARD, OVERLAY,
    MENUBAR, MENU, ITEM, DIALOG, TOAST, POPOVER, CLIPBOARD, PAN, ZOOM, TAP, PRESS, RELEASE, DOUBLE, SECONDARY, KEY,
    START, CENTER, END, STRETCH, BETWEEN, Node,
    TITLE, HEADLINE, CAPTION, PROMINENT, DESTRUCTIVE, SUBTLE, ICON_ONLY, ICON_ON, TOOL, TOOL_ON, as_tool,
    TONE_WARN, TONE_GOOD, TONE_STRONG, TONE_ACCENT, CARD, CARD_WARN, CARD_GOOD,
)
from mojoui.menus import CHECKED, DISABLED, DANGER
from mojoui.theme import Palette, Theme, mix
from mojoui.diff import Diff, SET_TEXT, SET_VALUE, SET_IMAGE, SET_PLACE
from mojoui.png import encode_png
from mojoui.app import App, Event, Runtime
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


def skin_font(name: String, size: Float64) -> Int:
    """The app's own font if it was registered (Inter, JetBrains Mono), else the system font."""
    var f = msg(cls("NSFont"), "fontWithName:size:", ns_string(name), size)
    if f == 0:
        f = msg(cls("NSFont"), "systemFontOfSize:", size)
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
    var focus: Int  # text field to keep focused across the next rebuild (-1: none)
    var canvases: List[AppleCanvas]
    var link: Int  # an NSTimer at 60 Hz: one tick per frame, for every canvas (0 = stopped)
    var resize_pending: Bool  # a new window size waits for the next run-loop turn (never rebuilt inside AppKit's layout)
    var ticks: Int  # ticks so far (the Mac report logs the first)
    var last_frame: Float64  # the link's last timestamp (seconds)
    var theme_key: String  # the app's theme (Theme.key); its palette's colours and Inter when it paints native controls (a skin, D-149, D-260)
    var pal: Palette
    var skinned: Bool
    var popover: Int  # the NSPopover showing (a Popover node, or a context menu's items), and its node
    var popover_node: Int
    var sheet: Int  # the sheet window showing (a Dialog node), and its node
    var sheet_node: Int
    var toast: Int  # the toast view showing, if any
    var clip_version: Int  # the Clipboard view's version last copied (unverified on hardware)
    var toast_text: String
    var toast_claimed: Bool
    var has_menubar: Bool  # the screen put its own menus in the system menu bar (D-150)
    var report: MacReport  # Debug → Record: pictures and view dumps on the Desktop (mojoui/hosts/mac_report.mojo)

    def __init__(out self):
        Self.A.init_shared()
        self.rt = Runtime(Self.A())
        self.window = 0
        self.target = 0
        self.widgets = List[Int]()
        self.focus = -1
        self.canvases = List[AppleCanvas]()
        self.link = 0
        self.resize_pending = False
        self.last_frame = 0
        self.ticks = 0
        var theme = self.rt.app.theme()
        self.theme_key = theme.key()
        self.pal = theme.palette.copy()
        self.skinned = theme.paint_native
        self.popover = 0
        self.popover_node = -1
        self.sheet = 0
        self.sheet_node = -1
        self.toast = 0
        self.clip_version = 0
        self.toast_text = ""
        self.toast_claimed = False
        self.has_menubar = False
        self.report = MacReport()

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
        _ = msg(holder, "setEdgeInsets:", Float64(10), Float64(12), Float64(10), Float64(12))
        _ = msg(holder, "addArrangedSubview:", content)
        _ = msg(vc, "setView:", holder)
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
                _ = msg(b, "setImagePosition:", 3)  # NSImageLeft
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
        node.style = as_tool(node.style) if node.kind == BUTTON else node.style  # (inline tools: drawn as tools here)
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
                _ = msg(w, "setFont:", skin_font("Inter-SemiBold" if bold else "Inter-Regular", Float64(20) if node.style == TITLE else (Float64(15) if bold else (Float64(12) if node.style == CAPTION else Float64(13)))))
                _ = msg(w, "setTextColor:", ns_color(self.pal.ink3 if node.style == CAPTION else self.pal.ink2))
            if node.value == TONE_WARN:
                _ = msg(w, "setTextColor:", ns_color(self.pal.warn) if self.skinned else msg(cls("NSColor"), "systemOrangeColor"))
            elif node.value == TONE_GOOD:
                _ = msg(w, "setTextColor:", ns_color(self.pal.good) if self.skinned else msg(cls("NSColor"), "systemGreenColor"))
            elif node.value == TONE_ACCENT:
                _ = msg(w, "setTextColor:", self.accent())
            elif node.value == TONE_STRONG:
                _ = msg(w, "setTextColor:", self.ink())
                _ = msg(w, "setFont:", skin_font("Inter-SemiBold", Float64(13)) if self.skinned else msg(cls("NSFont"), "boldSystemFontOfSize:", Float64(13)))
        elif node.kind == BUTTON:
            if (node.style == ICON_ONLY or node.style == ICON_ON) and node.hint != "":
                w = msg(cls("NSButton"), "buttonWithImage:target:action:", msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string(sf_symbol(node.hint)), ns_string(node.text)), self.target, sel("tap:"))
                _ = msg(w, "setBordered:", 0)
                if node.style == ICON_ON:  # (a toggle that is on: the accent, pressed)
                    _ = msg(w, "setContentTintColor:", self.accent())
                    _ = msg(w, "setState:", 1)
            else:
                w = msg(cls("NSButton"), "buttonWithTitle:target:action:", ns_string(node.text), self.target, sel("tap:"))
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            if node.hint != "" and node.style != ICON_ONLY and node.style != ICON_ON:
                var image = msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", ns_string(sf_symbol(node.hint)), 0)
                if image != 0:
                    _ = msg(w, "setImage:", image)
                    _ = msg(w, "setImagePosition:", 1 if node.style == TOOL or node.style == TOOL_ON else 3)  # NSImageAbove / NSImageLeft
            if node.style == PROMINENT:
                if not self.submit_field_shown():  # else Return would fire the field and the button
                    _ = msg(w, "setKeyEquivalent:", ns_string("\r"))  # the blue default button; Return taps it
                _ = msg(w, "setControlSize:", 3)  # NSControlSizeLarge
                _ = msg(w, "setBezelColor:", self.accent())
            elif node.style == DESTRUCTIVE:
                _ = msg(w, "setHasDestructiveAction:", 1)
                _ = msg(w, "setContentTintColor:", msg(cls("NSColor"), "systemRedColor"))
            elif node.style == SUBTLE or node.style == TOOL or node.style == TOOL_ON:
                _ = msg(w, "setBordered:", 0)
                if node.style == TOOL or node.style == TOOL_ON:
                    _ = msg(w, "setFont:", msg(cls("NSFont"), "systemFontOfSize:", Float64(11)))
                if node.style == TOOL_ON:
                    _ = msg(w, "setContentTintColor:", self.accent())
                    _ = msg(w, "setState:", 1)
            if self.skinned and node.style != TOOL_ON and node.style != ICON_ON and node.style != DESTRUCTIVE and node.style != PROMINENT:
                _ = msg(w, "setContentTintColor:", self.ink())
        elif node.kind == FIELD:
            w = msg(cls("NSTextField"), "textFieldWithString:", ns_string(node.text))
            _ = msg(w, "setPlaceholderString:", ns_string(node.hint))
            _ = msg(w, "setDelegate:", self.target)  # controlTextDidChange: as you type
            self.wire(w, i, self_addr, "submit:")  # the action fires on Return
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(220))
        elif node.kind == TOGGLE:
            w = msg(cls("NSButton"), "checkboxWithTitle:target:action:", ns_string(node.text), self.target, sel("toggle:"))
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            _ = msg(w, "setState:", node.value)  # NSControlStateValueOn = 1
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
            for kind in [("NSPanGestureRecognizer", "canvasPan:"), ("NSMagnificationGestureRecognizer", "canvasPinch:"), ("NSClickGestureRecognizer", "canvasTap:"),
                         ("NSClickGestureRecognizer", "canvasDouble:"), ("NSClickGestureRecognizer", "canvasSecondary:")]:
                var r = msg(msg(cls(kind[0]), "alloc"), "initWithTarget:action:", w, sel(kind[1]))
                if kind[1] == "canvasDouble:":
                    _ = msg(r, "setNumberOfClicksRequired:", 2)
                elif kind[1] == "canvasSecondary:":
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
            w = top_scroll_view()
            _ = msg(w, "setHasVerticalScroller:", 1)
            _ = msg(w, "setHasHorizontalScroller:", 1)
            _ = msg(w, "setDrawsBackground:", 0)
            var content = msg(msg(cls("MojoBoardView"), "alloc"), "initWithFrame:", Float64(0), Float64(0), Float64(node.spacing), Float64(node.size))
            _ = msg(w, "setDocumentView:", content)
            for k in range(len(node.children)):
                var c = node.children[k]
                var cn = self.rt.shown.nodes[c].copy()  # (copy: building the child mutates self)
                var child = self.build(c, self_addr)
                _ = msg(child, "setTranslatesAutoresizingMaskIntoConstraints:", 1)
                _ = msg(child, "setFrame:", Float64(cn.x), Float64(cn.y), Float64(cn.w), Float64(cn.h))
                _ = msg(child, "setIdentifier:", ns_string(String(tag_for(self_addr, c))))
                _ = msg(content, "addSubview:", child)
                if node.msg != 0:  # on_move: drag it (by anywhere on it; the title strip in practice)
                    var pan = msg(msg(cls("NSPanGestureRecognizer"), "alloc"), "initWithTarget:action:", self.target, sel("boardPan:"))
                    _ = msg(child, "addGestureRecognizer:", pan)
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
                _ = msg(head, "setFont:", msg(cls("NSFont"), "boldSystemFontOfSize:", Float64(13)))
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
                var content = msg(self.window, "contentView")
                if content != 0:
                    _ = msg(content, "addSubview:positioned:relativeTo:", self.toast, 1, 0)  # NSWindowAbove: over everything
                    _ = msg(msg(msg(self.toast, "centerXAnchor"), "constraintEqualToAnchor:", msg(content, "centerXAnchor")), "setActive:", 1)
                    _ = msg(msg(msg(self.toast, "bottomAnchor"), "constraintEqualToAnchor:constant:", msg(content, "bottomAnchor"), Float64(-24)), "setActive:", 1)
                _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("toastTimeout:"), ns_number(tag_for(self_addr, i)), Float64(node.size if node.size > 0 else 6))
            self.toast_claimed = True
            self.widgets[i] = self.toast
            w = new("NSView")
        elif node.kind == SPACER:
            w = new("NSView")
        elif node.kind == SCROLL:
            w = top_scroll_view()
            _ = msg(w, "setHasVerticalScroller:", 1)
            _ = msg(w, "setDrawsBackground:", 0)
            var content = self.build(node.children[0], self_addr)
            _ = msg(content, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            _ = msg(w, "setDocumentView:", content)
            var clip = msg(w, "contentView")
            for anchor in ["topAnchor", "leadingAnchor", "widthAnchor"]:
                _ = msg(msg(msg(content, anchor), "constraintEqualToAnchor:", msg(clip, anchor)), "setActive:", 1)
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(320))
        else:
            w = new("NSStackView")
            var vertical = node.kind == VSTACK
            _ = msg(w, "setOrientation:", 1 if vertical else 0)
            # align → NSStackView alignment (NSLayoutAttribute); STRETCH = per-child constraints below
            var align = 9 if vertical else 10  # centre X / centre Y
            if node.align_items == START:
                align = 5 if vertical else 3  # leading / top
            elif node.align_items == END:
                align = 6 if vertical else 4  # trailing / bottom
            _ = msg(w, "setAlignment:", align)
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
            if self.skinned and (node.name == "toolbar" or node.name == "status-bar" or node.name == "menubar"):  # the chrome band
                _ = msg(w, "setWantsLayer:", 1)
                _ = msg(msg(w, "layer"), "setBackgroundColor:", msg(ns_color(self.pal.chrome), "CGColor"))
            # justify → distribution (BETWEEN) or flexible spacers (START, CENTER, END), all native
            var grows = False
            for c in node.children:
                grows = grows or self.rt.shown.nodes[c].grows
            if node.justify_items == BETWEEN:
                _ = msg(w, "setDistribution:", 3)  # NSStackViewDistributionEqualSpacing
            elif grows or node.justify_items != 0:
                _ = msg(w, "setDistribution:", 0)  # fill: the lowest-hugging view takes the free space
            var lead = 0
            if (node.justify_items == CENTER or node.justify_items == END) and not grows:  # a growing child takes it all
                lead = flexible_spacer(vertical)
                _ = msg(w, "addArrangedSubview:", lead)
            for c in node.children:
                var child = self.build(c, self_addr)
                _ = msg(w, "addArrangedSubview:", child)
                ref cn = self.rt.shown.nodes[c]
                if cn.grows:  # flex-grow: lowest hugging priority along the stack
                    _ = msg(child, "setContentHuggingPriority:forOrientation:", Float32(1), 1 if vertical else 0)
                if cn.fills or node.align_items == STRETCH:  # stretch across: match the stack minus its insets
                    var side = "widthAnchor" if vertical else "heightAnchor"
                    var inset = Float64(2 * (node.pad_h if vertical else node.pad_v))
                    var c2 = msg(msg(child, side), "constraintEqualToAnchor:constant:", msg(w, side), -inset)
                    _ = msg(c2, "setActive:", 1)
            if node.justify_items == CENTER and not grows:
                var trail = flexible_spacer(vertical)
                _ = msg(w, "addArrangedSubview:", trail)
                var side = "heightAnchor" if vertical else "widthAnchor"
                _ = msg(msg(msg(trail, side), "constraintEqualToAnchor:", msg(lead, side)), "setActive:", 1)
            elif node.justify_items == START and not grows:
                _ = msg(w, "addArrangedSubview:", flexible_spacer(vertical))
        if self.widgets[i] == 0:  # (some branches already stored an inner control)
            self.widgets[i] = w
        return self.apply_layout(i, w)

    def apply_layout(self, i: Int, w: Int) -> Int:
        """Maps node i's own sizes (and, for non-stacks, padding) onto Auto Layout; returns what goes in the parent."""
        ref node = self.rt.shown.nodes[i]
        var outer = w
        if node.tip != "":
            _ = msg(w, "setToolTip:", ns_string(node.tip))
        var is_stack = node.kind == VSTACK or node.kind == HSTACK
        if (node.pad_v != 0 or node.pad_h != 0) and not is_stack:  # wrap a leaf in a padded stack
            outer = new("NSStackView")
            _ = msg(outer, "setEdgeInsets:", Float64(node.pad_v), Float64(node.pad_h), Float64(node.pad_v), Float64(node.pad_h))
            _ = msg(outer, "addArrangedSubview:", w)
        if node.w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintEqualToConstant:", Float64(node.w)), "setActive:", 1)
        if node.h != 0:
            _ = msg(msg(msg(outer, "heightAnchor"), "constraintEqualToConstant:", Float64(node.h)), "setActive:", 1)
        if node.min_w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(node.min_w)), "setActive:", 1)
        if node.max_w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintLessThanOrEqualToConstant:", Float64(node.max_w)), "setActive:", 1)
            if node.kind == TEXT:  # labels are single-line by default: let it wrap within the width
                _ = msg(w, "setMaximumNumberOfLines:", 0)
                _ = msg(w, "setLineBreakMode:", 0)  # word wrapping
                _ = msg(w, "setPreferredMaxLayoutWidth:", Float64(node.max_w - 2 * node.pad_h))
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
        self.canvases = List[AppleCanvas]()
        if self.link != 0:
            _ = msg(self.link, "invalidate")
            self.link = 0
        var theme = self.rt.app.theme()
        if theme.key() != self.theme_key:  # Settings → Appearance: the skin switches live (D-156)
            self.theme_key = theme.key()
            self.pal = theme.palette.copy()
            self.skinned = theme.paint_native
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
        self.start_frames()
        if 0 <= self.focus < len(self.widgets) and self.rt.shown.nodes[self.focus].kind == FIELD:
            # Keep typing in the new field, on the next run-loop turn (after AppKit has
            # finished ending the old field's edit), with the cursor at the end.
            _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("focusField:"), self.widgets[self.focus], Float64(0))
        self.focus = -1
        self.add_debug_menu(self_addr)

    def copy_if_asked(mut self):
        """A Clipboard view whose version moved on: its text goes on the general pasteboard as plain text."""
        for ref n in self.rt.shown.nodes:
            if n.kind == CLIPBOARD and n.value > 0 and n.value != self.clip_version:
                self.clip_version = n.value
                var board = msg(cls("NSPasteboard"), "generalPasteboard")
                _ = msg(board, "clearContents")
                _ = msg(board, "setString:forType:", ns_string(n.text), ns_string("public.utf8-plain-text"))

    def apply(mut self, d: Diff, self_addr: Int):
        self.copy_if_asked()
        if d.rebuild or len(d.patches) > 0:
            self.queue_snapshot(self_addr)
        if d.rebuild:
            self.show(self_addr)
            return
        for p in d.patches:
            var w = self.widgets[p.node]
            var kind = self.rt.shown.nodes[p.node].kind
            if p.op == SET_TEXT and kind != TEXTAREA and kind != DATE and kind != NAVBAR:
                if kind == TEXT:
                    _ = msg(w, "setStringValue:", ns_string(p.text))
                elif kind == FIELD:
                    if from_ns(msg(w, "stringValue")) != p.text:  # don't fight the typist
                        _ = msg(w, "setStringValue:", ns_string(p.text))
                else:  # buttons and checkboxes
                    _ = msg(w, "setTitle:", ns_string(p.text))
            elif p.op == SET_VALUE:
                if kind == TOGGLE:
                    _ = msg(w, "setState:", p.number)
                elif kind == DROPDOWN:
                    _ = msg(w, "selectItemAtIndex:", p.number)
                elif kind == SLIDER or kind == PROGRESS:
                    _ = msg(w, "setDoubleValue:", Float64(p.number))
            elif p.op == SET_VALUE and (kind == SEGMENTED or kind == TABS):
                _ = msg(w, "setSelectedSegment:", p.number)
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
                _ = msg(w, "setFrame:", Float64(moved.x), Float64(moved.y), Float64(moved.w), Float64(moved.h))
            # SET_MSG needs nothing: events look the message up in rt.shown.
        # Ask for the visible rows of every long list again: row text isn't part of the view.
        for k in range(len(self.rt.shown.nodes)):
            if self.rt.shown.nodes[k].kind == LAZYLIST and self.widgets[k] != 0:
                _ = msg(self.widgets[k], "reloadData")
        self.wake()

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
        if self.popover != 0:
            line += " · a popover is open (not in the picture)"
        if self.sheet != 0:
            line += " · a dialog is open (not in the picture)"
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
            var w = self.widgets[i] if i < len(self.widgets) else 0
            if w == 0:
                if n.kind != ITEM and n.kind != MENU and n.kind != CLIPBOARD and n.kind != DIALOG and n.kind != POPOVER and n.kind != TOAST and n.kind != SPACER:
                    line += "  (no view)"
            elif (msg(w, "isKindOfClass:", cls("NSView")) & 0xFF) != 0:
                var b = msg[CGRect](w, "bounds")
                var r = msg[CGRect](w, "convertRect:toView:", b.x, b.y, b.width, b.height, 0)
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
        var d = self.rt.resize(w, h)
        self.apply(d, self_addr)

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
        (MENU, "Menu"), (ITEM, "Item"), (DIALOG, "Dialog"), (TOAST, "Toast"), (POPOVER, "Popover"), (CLIPBOARD, "Clipboard")]
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


def top_scroll_view() -> Int:
    """A scroll view whose clip view counts y from the top: content shorter than the view sits at its top, as on every
    other host (AppKit's own clip view keeps it at the bottom: the owner's Report and inspector pages, 2026-10-23)."""
    var w = new("NSScrollView")
    _ = msg(w, "setContentView:", new("MojoTopClipView"))
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


def on_debug_queued[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    host_at[A](msg(number, "longLongValue"))[].snapshot()


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
    for name in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "JetBrainsMono-Regular", "JetBrainsMono-Bold"]:
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

    host[].window = msg(
        msg(cls("NSWindow"), "alloc"),
        "initWithContentRect:styleMask:backing:defer:",
        Float64(0), Float64(0), Float64(host[].rt.app.window_size()[0]), Float64(host[].rt.app.window_size()[1]),  # rect as 4 floats (arm64)
        1 | 2 | 4 | 8,  # titled, closable, miniaturizable, resizable
        2,  # NSBackingStoreBuffered
        0,  # defer: NO
    )
    _ = msg(host[].window, "setTitle:", ns_string(title))
    _ = msg(host[].window, "setReleasedWhenClosed:", 0)
    _ = msg(host[].window, "setIdentifier:", ns_string(String(addr)))  # (windowDidResize: finds the host by it)
    var size = host[].rt.app.window_size()
    _ = host[].rt.resize(size[0], size[1])  # the app lays out to its window from the first screen (App.resize)
    host[].show(addr)
    _ = msg(host[].window, "center")
    _ = msg(host[].window, "makeKeyAndOrderFront:", 0)
    _ = msg(host[].window, "setDelegate:", host[].target)  # windowDidResize: → App.resize
    _ = msg(app, "activateIgnoringOtherApps:", 1)
    if host[].rt.app.records():  # the app asks for a report from the start (the Mac check app)
        host[].start_report()
        host[].report.cause = "launch"
        host[].queue_snapshot(addr)
    _ = msg(app, "run")
    return 0
