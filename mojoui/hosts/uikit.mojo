# iPhone host: draws a mojoui View with real UIKit controls.
#
# Start-up: UIApplicationMain → MojoAppDelegate → the scene from Info.plist →
# MojoSceneDelegate.scene:willConnectToSession:options:, which creates the app
# (A()) and its window. Events: each control's tag packs the host's address and
# the node index; its target is the scene delegate (tap:, changed:, submit:,
# toggle:, slide:). Dropdowns are menu buttons whose UIActions call a Mojo-built
# block; each action's identifier carries "<tag>:<option index>".

from std.ffi import external_call, c_int
from std.memory import Pointer
from std.memory.alloc import alloc, Layout

from mojoui.view import (
    TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE,
    SEGMENTED, RADIO, TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, BOARD, OVERLAY,
    MENUBAR, MENU, ITEM, DIALOG, TOAST, POPOVER, PARAGRAPH, PAN, ZOOM, TAP, PRESS, RELEASE, DOUBLE, SECONDARY, KEY,
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
from mojoui.hosts.objc import (
    cls, sel, msg, new, ns_string, ns_data, ns_array, ns_number, ns_date, date_text, sf_symbol, from_ns, constrain, prefer,
    global_block, data_block, block_data, new_class, add_method, add_protocol,
    register_class, pool_push,
)

comptime NODE_BITS = 16
comptime VALUE_CHANGED = 1 << 12
comptime TOUCH_UP_INSIDE = 1 << 6
comptime EDITING_CHANGED = 1 << 17
comptime EDITING_DID_END_ON_EXIT = 1 << 19  # Return pressed
comptime KEY_SHIFT = 1 << 17  # UIKeyModifierFlags
comptime KEY_CONTROL = 1 << 18
comptime KEY_ALTERNATE = 1 << 19
comptime KEY_COMMAND = 1 << 20
comptime POPOVER_STYLE = 7  # UIModalPresentationPopover
comptime FORM_SHEET = 3  # UIModalPresentationFormSheet


def ui_color(c: UInt32) -> Int:
    """A UIColor from a palette colour (R in the low byte)."""
    return msg(cls("UIColor"), "colorWithRed:green:blue:alpha:", Float64(Int(c & 255)) / 255.0, Float64(Int((c >> 8) & 255)) / 255.0,
               Float64(Int((c >> 16) & 255)) / 255.0, Float64(1))


def skin_font(name: String, size: Float64) -> Int:
    """The app's own font if it was registered (Inter, JetBrains Mono), else the system font."""
    var f = msg(cls("UIFont"), "fontWithName:size:", ns_string(name), size)
    if f == 0:
        f = msg(cls("UIFont"), "systemFontOfSize:", size)
    return f


def shortcut_parts(shortcut: String) -> Tuple[String, Int]:
    """"Ctrl+Shift+S" → ("s", ⌘⇧): Ctrl means ⌘ on Apple platforms (D-159). Arrows and F-keys come back as their names."""
    var name = shortcut
    var flags = 0
    while True:
        if name.startswith("Ctrl+"):
            flags |= KEY_COMMAND
            var cut = String(name[byte=5:])
            name = cut
        elif name.startswith("Shift+"):
            flags |= KEY_SHIFT
            var cut = String(name[byte=6:])
            name = cut
        elif name.startswith("Alt+"):
            flags |= KEY_ALTERNATE
            var cut = String(name[byte=4:])
            name = cut
        else:
            break
    return (name.lower() if name.byte_length() == 1 else name, flags)


def key_input(name: String) -> Int:
    """The UIKeyCommand input for a key: the character, or UIKit's own constant for arrows (an NSString looked up by name)."""
    var constant = String("")
    if name == "↑":
        constant = "UIKeyInputUpArrow"
    elif name == "↓":
        constant = "UIKeyInputDownArrow"
    elif name == "←":
        constant = "UIKeyInputLeftArrow"
    elif name == "→":
        constant = "UIKeyInputRightArrow"
    elif name == "Escape":
        constant = "UIKeyInputEscape"
    elif name.startswith("F") and name.byte_length() <= 3 and name != "F":
        constant = "UIKeyInput" + name
    if constant != "":
        var addr = external_call["dlsym", Int](-2, constant.as_c_string_span())
        return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)[] if addr != 0 else 0
    return ns_string(name)


def key_name_of(key: Int) -> String:
    """A UIKey → the web's key names (what the GTK and web hosts send)."""
    var code = msg(key, "keyCode")
    if code == 0x4F: return "ArrowRight"
    if code == 0x50: return "ArrowLeft"
    if code == 0x51: return "ArrowDown"
    if code == 0x52: return "ArrowUp"
    if code == 0x28 or code == 0x58: return "Enter"
    if code == 0x29: return "Escape"
    if code == 0x2B: return "Tab"
    if code == 0x2A: return "Backspace"
    if code == 0x4C: return "Delete"
    if code == 0x4A: return "Home"
    if code == 0x4D: return "End"
    if code == 0x4B: return "PageUp"
    if code == 0x4E: return "PageDown"
    if 0x3A <= code <= 0x45: return "F" + String(code - 0x39)
    return from_ns(msg(key, "charactersIgnoringModifiers"))


def tag_for(host_addr: Int, node: Int) -> Int:
    return (host_addr << NODE_BITS) | node


struct UIKitHost[A: App](Movable):
    var rt: Runtime[Self.A]
    var window: Int
    var view: Int  # the root view controller's view
    var root: Int  # our top stack view inside it
    var target: Int  # the scene delegate, which receives every control event
    var choose: Int  # the block every dropdown option calls
    var widgets: List[Int]  # the control for each node
    var extras: List[Int]  # a second view for some nodes (a toggle's label)
    var focus: Int  # text field to keep focused across the next rebuild (-1: none)
    var canvases: List[AppleCanvas]
    var link: Int  # CADisplayLink: one tick per display frame, for every canvas
    var last_frame: Float64
    var pick: Int  # the block every menu item's UIAction calls
    var theme_key: String  # the app's theme (Theme.key); its palette's colours and Inter when it paints native controls (a skin, D-149, D-260)
    var pal: Palette
    var skinned: Bool
    var floating: Int  # the presented popover / context menu / dialog controller, if any, and its node
    var floating_node: Int
    var toast: Int  # the toast view showing, if any
    var toast_text: String
    var toast_claimed: Bool
    var commands: Int  # NSArray of UIKeyCommands for the screen's shortcuts (the root controller returns it)

    def __init__(out self):
        Self.A.init_shared()
        self.rt = Runtime(Self.A())
        self.canvases = List[AppleCanvas]()
        self.link = 0
        self.last_frame = 0
        self.window = 0
        self.view = 0
        self.root = 0
        self.target = 0
        self.choose = 0
        self.widgets = List[Int]()
        self.extras = List[Int]()
        self.focus = -1
        self.pick = 0
        var theme = self.rt.app.theme()
        self.theme_key = theme.key()
        self.pal = theme.palette.copy()
        self.skinned = theme.paint_native
        self.floating = 0
        self.floating_node = -1
        self.toast = 0
        self.toast_text = ""
        self.toast_claimed = False
        self.commands = 0

    def ink(self) -> Int:
        return ui_color(self.pal.ink) if self.skinned else msg(cls("UIColor"), "labelColor")

    def accent(self) -> Int:
        return ui_color(self.pal.accent) if self.skinned else msg(cls("UIColor"), "tintColor")

    def menu_items(self, children: List[Int], self_addr: Int) -> Int:
        """A UIMenu's children from ITEM nodes: actions (checked, disabled, danger), inline groups at separators and
        labels, submenus; each action's identifier is the item's tag, so one block serves them all."""
        var groups = msg(cls("NSMutableArray"), "array")  # top-level elements
        var group = msg(cls("NSMutableArray"), "array")  # the current inline group
        var group_title = String("")
        for c in children:
            ref n = self.rt.shown.nodes[c]
            if n.kind != ITEM:
                continue
            if n.style == 1 or n.style == 2:  # a separator or a section label starts a new inline group
                if msg(group, "count") > 0:
                    _ = msg(groups, "addObject:", msg(cls("UIMenu"), "menuWithTitle:image:identifier:options:children:", ns_string(group_title), 0, 0, 1, group))
                group = msg(cls("NSMutableArray"), "array")
                group_title = n.text if n.style == 2 else String("")
                continue
            if len(n.children) > 0:  # a submenu
                var image = msg(cls("UIImage"), "systemImageNamed:", ns_string(sf_symbol(n.hint))) if n.hint != "" else 0
                _ = msg(group, "addObject:", msg(cls("UIMenu"), "menuWithTitle:image:identifier:options:children:", ns_string(n.text), image, 0, 0, self.menu_items(n.children, self_addr)))
                continue
            var image = msg(cls("UIImage"), "systemImageNamed:", ns_string(sf_symbol(n.hint))) if n.hint != "" else 0
            var id = ns_string(String(tag_for(self_addr, c)))
            var action = msg(cls("UIAction"), "actionWithTitle:image:identifier:handler:", ns_string(n.text), image, id, self.pick)
            if n.value & CHECKED != 0:
                _ = msg(action, "setState:", 1)  # UIMenuElementStateOn
            var attributes = (1 if n.value & DISABLED != 0 else 0) | (2 if n.value & DANGER != 0 else 0)  # disabled | destructive
            if attributes != 0:
                _ = msg(action, "setAttributes:", attributes)
            _ = msg(group, "addObject:", action)
        if msg(group, "count") > 0:
            _ = msg(groups, "addObject:", msg(cls("UIMenu"), "menuWithTitle:image:identifier:options:children:", ns_string(group_title), 0, 0, 1, group))
        return groups

    def item_rows(mut self, children: List[Int], self_addr: Int) -> Int:
        """A context menu's or submenu's items as a column of plain buttons (what a popover shows, D-158)."""
        var column = new("UIStackView")
        _ = msg(column, "setAxis:", 1)
        _ = msg(column, "setAlignment:", 0)  # fill
        _ = msg(column, "setSpacing:", Float64(2))
        for c in children:
            ref n = self.rt.shown.nodes[c]
            if n.kind != ITEM:
                continue
            if n.style == 1:
                var sep = new("UIView")
                _ = msg(sep, "setBackgroundColor:", ui_color(self.pal.line) if self.skinned else msg(cls("UIColor"), "separatorColor"))
                constrain(sep, "heightAnchor", Float64(1))
                _ = msg(column, "addArrangedSubview:", sep)
                continue
            if n.style == 2:
                var head = label(n.text, CAPTION)
                _ = msg(head, "setTextAlignment:", 0)
                _ = msg(column, "addArrangedSubview:", head)
                continue
            var config = msg(cls("UIButtonConfiguration"), "plainButtonConfiguration")
            _ = msg(config, "setTitle:", ns_string(n.text))
            _ = msg(config, "setTitleAlignment:", 1)  # leading
            _ = msg(config, "setImagePadding:", Float64(10))
            var symbol = "checkmark" if n.value & CHECKED != 0 else sf_symbol(n.hint) if n.hint != "" else String("")
            if symbol != "":
                _ = msg(config, "setImage:", msg(cls("UIImage"), "systemImageNamed:", ns_string(symbol)))
            if n.value & DANGER != 0:
                _ = msg(config, "setBaseForegroundColor:", msg(cls("UIColor"), "systemRedColor"))
            elif self.skinned:
                _ = msg(config, "setBaseForegroundColor:", self.ink())
            if len(n.options) > 0:
                _ = msg(config, "setSubtitle:", ns_string(n.options[0]))
            var b = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", config, 0)
            _ = msg(b, "setContentHorizontalAlignment:", 1)  # leading
            if len(n.children) > 0:  # a submenu: a menu on the row
                _ = msg(b, "setMenu:", msg(cls("UIMenu"), "menuWithTitle:children:", ns_string(""), self.menu_items(n.children, self_addr)))
                _ = msg(b, "setShowsMenuAsPrimaryAction:", 1)
            else:
                self.wire(b, c, self_addr, "tap:", TOUCH_UP_INSIDE)
            if n.value & DISABLED != 0:
                _ = msg(b, "setEnabled:", 0)
            self.widgets[c] = b
            _ = msg(column, "addArrangedSubview:", b)
        return column

    def floating_controller(mut self, i: Int, content: Int, self_addr: Int):
        """Presents `content` for node i on the next run-loop turn: a popover for MENU (context) and POPOVER, a form
        sheet for DIALOG. One floats at a time; the previous one goes."""
        var vc = new("UIViewController")
        var view = msg(vc, "view")
        _ = msg(view, "setBackgroundColor:", ui_color(self.pal.card) if self.skinned else msg(cls("UIColor"), "systemBackgroundColor"))
        _ = msg(content, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
        _ = msg(view, "addSubview:", content)
        var inset = Float64(8) if self.rt.shown.nodes[i].kind == MENU else Float64(16)
        _ = msg(msg(msg(content, "topAnchor"), "constraintEqualToAnchor:constant:", msg(view, "topAnchor"), inset), "setActive:", 1)
        _ = msg(msg(msg(content, "leadingAnchor"), "constraintEqualToAnchor:constant:", msg(view, "leadingAnchor"), inset), "setActive:", 1)
        _ = msg(msg(msg(content, "trailingAnchor"), "constraintEqualToAnchor:constant:", msg(view, "trailingAnchor"), -inset), "setActive:", 1)
        _ = msg(msg(msg(content, "bottomAnchor"), "constraintLessThanOrEqualToAnchor:constant:", msg(view, "bottomAnchor"), -inset), "setActive:", 1)
        var size = msg[CGPoint](content, "systemLayoutSizeFittingSize:", Float64(10), Float64(10))  # (a CGSize: two doubles, like a point)
        ref node = self.rt.shown.nodes[i]
        var width = Float64(node.w) if node.kind == DIALOG and node.w > 0 else max(size.x + 2 * inset, Float64(260))
        _ = msg(vc, "setPreferredContentSize:", width, size.y + 2 * inset)
        _ = msg(vc, "setModalPresentationStyle:", FORM_SHEET if node.kind == DIALOG else POPOVER_STYLE)
        _ = msg(view, "setTag:", tag_for(self_addr, i))  # (its view remembers whose it is, for on_close)
        _ = msg(msg(vc, "presentationController"), "setDelegate:", self.target)  # dismissed by a tap outside: on_close
        if node.kind != DIALOG:
            var pop = msg(vc, "popoverPresentationController")
            var anchor = self.view
            for k in range(len(self.rt.shown.nodes)):
                if self.rt.shown.nodes[k].name == node.text and k < len(self.widgets) and self.widgets[k] != 0:
                    anchor = self.widgets[k]
            _ = msg(pop, "setSourceView:", anchor)
            if node.kind == MENU or node.x != 0 or node.y != 0:
                _ = msg(pop, "setSourceRect:", Float64(node.x), Float64(node.y), Float64(1), Float64(1))
                _ = msg(pop, "setPermittedArrowDirections:", 0)  # none: a menu sits at the point
            else:
                var b = msg[CGRect](anchor, "bounds")
                _ = msg(pop, "setSourceRect:", b.x, b.y, b.width, b.height)
                _ = msg(pop, "setPermittedArrowDirections:", 1)  # up: below its anchor
            _ = msg(pop, "setDelegate:", self.target)  # keeps it a popover on an iPhone too
        self.floating = vc
        self.floating_node = i
        _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("presentFloating:"), ns_number(tag_for(self_addr, i)), Float64(0))

    def wire(self, w: Int, i: Int, self_addr: Int, action: String, events: Int):
        _ = msg(w, "setTag:", tag_for(self_addr, i))
        _ = msg(w, "addTarget:action:forControlEvents:", self.target, sel(action), events)

    def menu(self, options: List[String], selected: Int, tag: Int) -> Int:
        """A UIMenu with one action per option; the selected one is checked."""
        var actions = msg(cls("NSMutableArray"), "array")
        for j in range(len(options)):
            var id = ns_string(String(tag) + ":" + String(j))
            var action = msg(cls("UIAction"), "actionWithTitle:image:identifier:handler:", ns_string(options[j]), 0, id, self.choose)
            if j == selected:
                _ = msg(action, "setState:", 1)  # UIMenuElementStateOn
            _ = msg(actions, "addObject:", action)
        return msg(cls("UIMenu"), "menuWithTitle:children:", ns_string(""), actions)

    def build(mut self, i: Int, self_addr: Int) -> Int:
        var node = self.rt.shown.nodes[i].copy()  # copy: building children mutates self
        node.style = as_tool(node.style) if node.kind == BUTTON else node.style  # (inline tools: drawn as tools here)
        var sized = node.sized_width()  # the app's layout decides this view's width
        var w: Int
        var shown: Int  # what goes into the parent (usually w itself)
        if node.kind == TEXT or node.kind == PARAGRAPH:  # (a Paragraph: its plain words in a wrapping label; its runs' looks: not yet)
            w = label(node.text, node.style)
            if self.skinned:
                _ = msg(w, "setFont:", skin_font("Inter-SemiBold" if node.style == TITLE or node.style == HEADLINE else "Inter-Regular",
                                                 Float64(20 if node.style == TITLE else (15 if node.style == HEADLINE else (12 if node.style == CAPTION else 13)))))
                _ = msg(w, "setTextColor:", ui_color(self.pal.ink3 if node.style == CAPTION else self.pal.ink2))
            if node.value == TONE_WARN:
                _ = msg(w, "setTextColor:", ui_color(self.pal.warn) if self.skinned else msg(cls("UIColor"), "systemOrangeColor"))
            elif node.value == TONE_GOOD:
                _ = msg(w, "setTextColor:", ui_color(self.pal.good) if self.skinned else msg(cls("UIColor"), "systemGreenColor"))
            elif node.value == TONE_ACCENT:
                _ = msg(w, "setTextColor:", self.accent())
            elif node.value == TONE_STRONG:
                _ = msg(w, "setTextColor:", self.ink())
                _ = msg(w, "setFont:", skin_font("Inter-SemiBold", Float64(13)) if self.skinned else msg(cls("UIFont"), "boldSystemFontOfSize:", Float64(17)))
            shown = w
        elif node.kind == BUTTON:
            w = make_button(node.text, node.style, node.hint, self.skinned, self.pal)
            self.wire(w, i, self_addr, "tap:", TOUCH_UP_INSIDE)
            shown = w
        elif node.kind == FIELD:
            w = new("UITextField")
            _ = msg(w, "setBorderStyle:", 3)  # rounded rect
            _ = msg(w, "setText:", ns_string(node.text))
            _ = msg(w, "setPlaceholder:", ns_string(node.hint))
            _ = msg(w, "setReturnKeyType:", 9)  # Done
            self.wire(w, i, self_addr, "changed:", EDITING_CHANGED)
            _ = msg(w, "addTarget:action:forControlEvents:", self.target, sel("submit:"), EDITING_DID_END_ON_EXIT)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(200))  # leaves room for a button beside it on an iPhone SE
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(44))
            shown = w
        elif node.kind == TOGGLE and node.style == 1:  # a Checkbox: iOS has no box with a tick, so a button with one
            w = check_button(node.text, node.value == 1, self.accent())
            self.wire(w, i, self_addr, "check:", TOUCH_UP_INSIDE)
            shown = w
        elif node.kind == TOGGLE:
            w = new("UISwitch")
            _ = msg(w, "setOn:animated:", node.value, 0)
            if self.skinned:
                _ = msg(w, "setOnTintColor:", self.accent())
            self.wire(w, i, self_addr, "toggle:", VALUE_CHANGED)
            var text = label(node.text, 0)
            self.extras[i] = text
            shown = new("UIStackView")  # [label  switch]
            _ = msg(shown, "setAxis:", 0)
            _ = msg(shown, "setAlignment:", 3)  # centre
            _ = msg(shown, "setSpacing:", Float64(12))
            _ = msg(shown, "addArrangedSubview:", text)
            _ = msg(shown, "addArrangedSubview:", w)
        elif node.kind == DROPDOWN:
            var title = node.options[node.value] if node.value < len(node.options) else String("")
            w = make_button(title, 0)
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            _ = msg(w, "setMenu:", self.menu(node.options, node.value, tag_for(self_addr, i)))
            _ = msg(w, "setShowsMenuAsPrimaryAction:", 1)
            _ = msg(w, "setChangesSelectionAsPrimaryAction:", 1)  # shows the chosen option, with a checkmark
            shown = w
        elif node.kind == SLIDER:
            w = new("UISlider")
            _ = msg(w, "setMinimumValue:", Float32(0))
            _ = msg(w, "setMaximumValue:", Float32(100))
            _ = msg(w, "setValue:animated:", Float32(node.value), 0)
            self.wire(w, i, self_addr, "slide:", VALUE_CHANGED)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(260))
            shown = w
        elif node.kind == PROGRESS:
            w = msg(msg(cls("UIProgressView"), "alloc"), "initWithProgressViewStyle:", 0)
            _ = msg(w, "setProgress:animated:", Float32(node.value) / 100.0, 0)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(260))
            shown = w
        elif node.kind == DIVIDER:
            w = new("UIView")
            _ = msg(w, "setBackgroundColor:", msg(cls("UIColor"), "separatorColor"))
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(280))
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(1))
            shown = w
        elif node.kind == CANVAS:
            # A MojoCanvasView (a UIImageView) showing the app's pixels, with UIKit's own
            # pan, pinch and tap recognisers calling back into it.
            w = new("MojoCanvasView")
            _ = msg(w, "setContentMode:", 0)  # scale to fill: the pixels match its size
            _ = msg(w, "setUserInteractionEnabled:", 1)  # image views ignore touches by default
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            for axis in range(2):  # its size comes from the layout, never from its picture
                _ = msg(w, "setContentHuggingPriority:forAxis:", Float32(1), axis)
                _ = msg(w, "setContentCompressionResistancePriority:forAxis:", Float32(1), axis)
            if not sized:
                prefer(w, "widthAnchor", Float64(320))
            if not node.sized_height():
                prefer(w, "heightAnchor", Float64(240))
            for kind in [("UIPanGestureRecognizer", "canvasPan:"), ("UIPinchGestureRecognizer", "canvasPinch:"), ("UITapGestureRecognizer", "canvasTap:"),
                         ("UITapGestureRecognizer", "canvasDouble:"), ("UITapGestureRecognizer", "canvasSecondary:"), ("UILongPressGestureRecognizer", "canvasLongPress:")]:
                var r = msg(msg(cls(kind[0]), "alloc"), "initWithTarget:action:", w, sel(kind[1]))
                if kind[0] == "UIPanGestureRecognizer":
                    _ = msg(r, "setMaximumNumberOfTouches:", 1)  # two fingers are a pinch, not a pan
                elif kind[1] == "canvasTap:":
                    _ = msg(r, "setButtonMaskRequired:", 1)  # the primary button (a finger, a pencil, the pointer's first button)
                elif kind[1] == "canvasDouble:":
                    _ = msg(r, "setNumberOfTapsRequired:", 2)
                elif kind[1] == "canvasSecondary:":
                    _ = msg(r, "setButtonMaskRequired:", 2)  # UIEventButtonMaskSecondary: a right click (trackpad, mouse)
                _ = msg(w, "addGestureRecognizer:", r)
            if node.size == 1:  # Canvas(keys=True): the hardware keyboard, once touched
                _ = msg(w, "setTag:", tag_for(self_addr, i))
            self.canvases.append(AppleCanvas(i, w))
            shown = w
        elif node.kind == IMAGE:
            w = msg(msg(cls("UIImageView"), "alloc"), "initWithImage:", ui_image(node.pixels, node.spacing, node.size))
            _ = msg(w, "setContentMode:", 1)  # scale aspect fit
            # At most its pixel width (shrinks on narrow screens), always its own aspect ratio.
            var most = msg(msg(w, "widthAnchor"), "constraintLessThanOrEqualToConstant:", Float64(node.spacing))
            _ = msg(most, "setActive:", 1)
            var want = msg(msg(w, "widthAnchor"), "constraintEqualToConstant:", Float64(node.spacing))
            _ = msg(want, "setPriority:", Float32(750))  # preferred, but the screen width wins
            _ = msg(want, "setActive:", 1)
            var ratio = Float64(node.size) / Float64(max(node.spacing, 1))
            var aspect = msg(msg(w, "heightAnchor"), "constraintEqualToAnchor:multiplier:", msg(w, "widthAnchor"), ratio)
            _ = msg(aspect, "setActive:", 1)
            shown = w
        elif node.kind == SEGMENTED or node.kind == TABS:
            w = msg(msg(cls("UISegmentedControl"), "alloc"), "initWithItems:", ns_array(node.options))
            _ = msg(w, "setSelectedSegmentIndex:", node.value)
            self.wire(w, i, self_addr, "segment:", VALUE_CHANGED)
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(40 if node.kind == TABS else 34))
            shown = w
        elif node.kind == RADIO:
            w = new("UIStackView")
            _ = msg(w, "setAxis:", 1)
            _ = msg(w, "setAlignment:", 1)  # leading
            for j in range(len(node.options)):
                var b = radio_button(node.options[j], j == node.value)
                self.wire(b, i, self_addr, "radio:", TOUCH_UP_INSIDE)
                _ = msg(w, "addArrangedSubview:", b)
            shown = w
        elif node.kind == TEXTAREA:
            w = new("UITextView")
            _ = msg(w, "setText:", ns_string(node.text))
            _ = msg(w, "setFont:", msg(cls("UIFont"), "preferredFontForTextStyle:", ns_string("UICTFontTextStyleBody")))
            _ = msg(w, "setAdjustsFontForContentSizeCategory:", 1)
            _ = msg(w, "setBackgroundColor:", msg(cls("UIColor"), "secondarySystemBackgroundColor"))
            _ = msg(msg(w, "layer"), "setCornerRadius:", Float64(12))
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            _ = msg(w, "setDelegate:", self.target)  # textViewDidChange:
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(300))
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
            shown = w
        elif node.kind == ALERT:
            # Presented on the next run-loop turn (not inside the event that asked for it).
            _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("presentAlert:"), ns_number(tag_for(self_addr, i)), Float64(0))
            w = new("UIView")  # nothing in the layout itself
            shown = w
        elif node.kind == NAVBAR:
            w = new("UINavigationBar")
            var item = msg(msg(msg(cls("UINavigationItem"), "alloc"), "initWithTitle:", ns_string(node.text)), "autorelease")
            if node.msg != 0:
                var chevron = msg(cls("UIImage"), "systemImageNamed:", ns_string("chevron.backward"))
                var back = msg(msg(cls("UIBarButtonItem"), "alloc"), "initWithImage:style:target:action:", chevron, 0, self.target, sel("tap:"))
                _ = msg(back, "setTag:", tag_for(self_addr, i))
                _ = msg(back, "setAccessibilityLabel:", ns_string("Back"))
                _ = msg(item, "setLeftBarButtonItem:", back)
            _ = msg(w, "setItems:animated:", msg(cls("NSArray"), "arrayWithObject:", item), 0)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(340))
            shown = w
        elif node.kind == DATE:
            w = new("UIDatePicker")
            _ = msg(w, "setDatePickerMode:", 1)  # date only
            _ = msg(w, "setPreferredDatePickerStyle:", 2)  # compact
            _ = msg(w, "setDate:", ns_date(node.text))
            self.wire(w, i, self_addr, "date:", VALUE_CHANGED)
            shown = w
        elif node.kind == ICON:
            var config = msg(cls("UIImageSymbolConfiguration"), "configurationWithPointSize:", Float64(node.size))
            var image = msg(cls("UIImage"), "systemImageNamed:withConfiguration:", ns_string(sf_symbol(node.text)), config)
            w = msg(msg(cls("UIImageView"), "alloc"), "initWithImage:", image)
            shown = w
        elif node.kind == GRID:
            w = new("UIStackView")
            _ = msg(w, "setAxis:", 1)
            _ = msg(w, "setSpacing:", Float64(node.spacing))
            var row = 0
            for k in range(len(node.children)):
                if k % node.value == 0:
                    row = new("UIStackView")
                    _ = msg(row, "setAxis:", 0)
                    _ = msg(row, "setDistribution:", 1)  # fill equally
                    _ = msg(row, "setSpacing:", Float64(node.spacing))
                    _ = msg(w, "addArrangedSubview:", row)
                _ = msg(row, "addArrangedSubview:", self.build(node.children[k], self_addr))
            shown = w
        elif node.kind == LAZYLIST:
            w = msg(msg(cls("UITableView"), "alloc"), "initWithFrame:style:", Float64(0), Float64(0), Float64(340), Float64(node.size), 2)  # inset grouped
            _ = msg(w, "registerClass:forCellReuseIdentifier:", cls("UITableViewCell"), ns_string("row"))
            _ = msg(w, "setRowHeight:", Float64(node.spacing))
            _ = msg(w, "setTag:", tag_for(self_addr, i))
            _ = msg(w, "setDataSource:", self.target)  # rows are asked for as they scroll into view
            _ = msg(w, "setDelegate:", self.target)
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(340))
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
            shown = w
        elif node.kind == BOARD:
            # A scroll view over a content view where every child sits at its own place; a child with a header
            # drags by a pan (the Board's on_move), as on the other hosts.
            w = new("UIScrollView")
            var content = new("UIView")
            _ = msg(content, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            _ = msg(w, "addSubview:", content)
            var inner = msg(w, "contentLayoutGuide")
            for anchor in ["topAnchor", "bottomAnchor", "leadingAnchor", "trailingAnchor"]:
                _ = msg(msg(msg(content, anchor), "constraintEqualToAnchor:", msg(inner, anchor)), "setActive:", 1)
            constrain(content, "widthAnchor", Float64(node.spacing))
            constrain(content, "heightAnchor", Float64(node.size))
            for k in range(len(node.children)):
                var c = node.children[k]
                var cn = self.rt.shown.nodes[c].copy()  # (copy: building the child mutates self)
                var child = self.build(c, self_addr)
                _ = msg(child, "setTranslatesAutoresizingMaskIntoConstraints:", 1)
                _ = msg(child, "setFrame:", Float64(cn.x), Float64(cn.y), Float64(cn.w), Float64(cn.h))
                _ = msg(child, "setTag:", tag_for(self_addr, c))
                _ = msg(content, "addSubview:", child)
                if node.msg != 0:  # on_move: drag it by its top (the header strip)
                    var pan = msg(msg(cls("UIPanGestureRecognizer"), "alloc"), "initWithTarget:action:", self.target, sel("boardPan:"))
                    _ = msg(pan, "setMaximumNumberOfTouches:", 1)
                    _ = msg(child, "addGestureRecognizer:", pan)
            if not sized:
                prefer(w, "widthAnchor", Float64(min(node.spacing, 760)))
            if not node.sized_height():
                prefer(w, "heightAnchor", Float64(min(node.size, 480)))
            shown = w
        elif node.kind == OVERLAY:
            w = new("UIView")
            for k in range(len(node.children)):
                var c = node.children[k]
                var child = self.build(c, self_addr)
                _ = msg(child, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
                _ = msg(w, "addSubview:", child)
                if k == 0:  # the base fills the overlay
                    for anchor in ["topAnchor", "bottomAnchor", "leadingAnchor", "trailingAnchor"]:
                        _ = msg(msg(msg(child, anchor), "constraintEqualToAnchor:", msg(w, anchor)), "setActive:", 1)
                else:  # an island: pinned to an edge or corner, 12 pt in
                    var pin = self.rt.shown.nodes[c].copy()
                    if self.skinned:
                        _ = msg(child, "setBackgroundColor:", ui_color(self.pal.card))
                        _ = msg(msg(child, "layer"), "setCornerRadius:", Float64(6))
                        _ = msg(child, "setLayoutMargins:", Float64(6), Float64(10), Float64(6), Float64(10))
                        _ = msg(child, "setLayoutMarginsRelativeArrangement:", 1)
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
            shown = w
        elif node.kind == MENUBAR:
            w = new("UIStackView")  # a row of menu buttons (an iPad has no system menu bar of its own to fill)
            _ = msg(w, "setAxis:", 0)
            _ = msg(w, "setSpacing:", Float64(2))
            _ = msg(w, "setAlignment:", 3)
            for c in node.children:
                _ = msg(w, "addArrangedSubview:", self.build(c, self_addr))
            _ = msg(w, "addArrangedSubview:", flexible_spacer(False))
            shown = w
        elif node.kind == MENU and node.style == 0:  # a menu in the bar: a button showing a UIMenu of its items
            var config = msg(cls("UIButtonConfiguration"), "plainButtonConfiguration")
            _ = msg(config, "setTitle:", ns_string(node.text))
            if self.skinned:
                _ = msg(config, "setBaseForegroundColor:", ui_color(self.pal.chrome_ink))
            w = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", config, 0)
            _ = msg(w, "setMenu:", msg(cls("UIMenu"), "menuWithTitle:children:", ns_string(""), self.menu_items(node.children, self_addr)))
            _ = msg(w, "setShowsMenuAsPrimaryAction:", 1)
            for c in node.children:  # (items keep their nodes for shortcuts and reports; nothing to lay out)
                self.widgets[c] = 0
            shown = w
        elif node.kind == MENU:  # a context menu: a popover of its items at the right-click point (D-158)
            self.floating_controller(i, self.item_rows(node.children, self_addr), self_addr)
            w = new("UIView")  # nothing in the layout itself
            shown = w
        elif node.kind == ITEM:
            w = new("UIView")  # (built by its menu: see MENU)
            shown = w
        elif node.kind == POPOVER:
            var column = new("UIStackView")
            _ = msg(column, "setAxis:", 1)
            _ = msg(column, "setSpacing:", Float64(8))
            _ = msg(column, "setAlignment:", 1)
            if node.hint != "":
                var head = label(node.hint, HEADLINE)
                _ = msg(head, "setTextAlignment:", 0)
                _ = msg(column, "addArrangedSubview:", head)
            for c in node.children:
                _ = msg(column, "addArrangedSubview:", self.build(c, self_addr))
            self.floating_controller(i, column, self_addr)
            w = new("UIView")
            shown = w
        elif node.kind == DIALOG:
            var column = new("UIStackView")
            _ = msg(column, "setAxis:", 1)
            _ = msg(column, "setSpacing:", Float64(12))
            _ = msg(column, "setAlignment:", 0)
            var head = new("UIStackView")
            _ = msg(head, "setAxis:", 0)
            _ = msg(head, "setAlignment:", 3)
            var title = label(node.text, HEADLINE)
            _ = msg(title, "setTextAlignment:", 0)
            _ = msg(head, "addArrangedSubview:", title)
            _ = msg(head, "addArrangedSubview:", flexible_spacer(False))
            var close_config = msg(cls("UIButtonConfiguration"), "plainButtonConfiguration")
            _ = msg(close_config, "setImage:", msg(cls("UIImage"), "systemImageNamed:", ns_string("xmark")))
            var close = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", close_config, 0)
            _ = msg(close, "setAccessibilityLabel:", ns_string("Close"))
            _ = msg(close, "setTag:", tag_for(self_addr, i))
            _ = msg(close, "addTarget:action:forControlEvents:", self.target, sel("closeOverlay:"), TOUCH_UP_INSIDE)
            _ = msg(head, "addArrangedSubview:", close)
            _ = msg(column, "addArrangedSubview:", head)
            for c in node.children:
                _ = msg(column, "addArrangedSubview:", self.build(c, self_addr))
            self.floating_controller(i, column, self_addr)
            w = new("UIView")
            shown = w
        elif node.kind == TOAST:
            if self.toast != 0 and self.toast_text == node.text:  # the same toast, still up: keep it
                _ = msg(self.toast, "setTag:", tag_for(self_addr, i))
            else:
                if self.toast != 0:
                    _ = msg(self.toast, "removeFromSuperview")
                self.toast = make_toast(node.text, node.options[0] if len(node.options) > 0 else String(""), tag_for(self_addr, i), self.target, self.pal)
                self.toast_text = node.text
                _ = msg(self.window, "addSubview:", self.toast)
                _ = msg(msg(msg(self.toast, "centerXAnchor"), "constraintEqualToAnchor:", msg(self.window, "centerXAnchor")), "setActive:", 1)
                _ = msg(msg(msg(self.toast, "bottomAnchor"), "constraintEqualToAnchor:constant:", msg(msg(self.window, "safeAreaLayoutGuide"), "bottomAnchor"), Float64(-24)), "setActive:", 1)
                _ = msg(self.target, "performSelector:withObject:afterDelay:", sel("toastTimeout:"), ns_number(tag_for(self_addr, i)), Float64(node.size if node.size > 0 else 6))
            self.toast_claimed = True
            self.widgets[i] = self.toast
            w = new("UIView")
            shown = w
        elif node.kind == SPACER:
            w = new("UIView")
            shown = w
        elif node.kind == SCROLL:
            w = new("UIScrollView")
            var content = self.build(node.children[0], self_addr)
            _ = msg(content, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
            _ = msg(w, "addSubview:", content)
            var inner = msg(w, "contentLayoutGuide")
            for anchor in ["topAnchor", "bottomAnchor", "leadingAnchor", "trailingAnchor"]:
                _ = msg(msg(msg(content, anchor), "constraintEqualToAnchor:", msg(inner, anchor)), "setActive:", 1)
            var frame = msg(w, "frameLayoutGuide")
            _ = msg(msg(msg(content, "widthAnchor"), "constraintEqualToAnchor:", msg(frame, "widthAnchor")), "setActive:", 1)
            if not node.sized_height():
                constrain(w, "heightAnchor", Float64(node.size))
            if not sized:  # (the app sized it: its settings decide)
                prefer(w, "widthAnchor", Float64(320))
            shown = w
        else:
            w = new("UIStackView")
            var vertical = node.kind == VSTACK
            _ = msg(w, "setAxis:", 1 if vertical else 0)
            # align → UIStackView alignment: fill 0, leading/top 1, centre 3, trailing/bottom 4
            var align = 3
            if node.align_items == START:
                align = 1
            elif node.align_items == END:
                align = 4
            elif node.align_items == STRETCH:
                align = 0
            _ = msg(w, "setAlignment:", align)
            _ = msg(w, "setSpacing:", Float64(node.spacing))
            if node.pad_v != 0 or node.pad_h != 0:  # padding = the stack's own layout margins
                _ = msg(w, "setLayoutMargins:", Float64(node.pad_v), Float64(node.pad_h), Float64(node.pad_v), Float64(node.pad_h))
                _ = msg(w, "setLayoutMarginsRelativeArrangement:", 1)
            if vertical and node.style != 0:  # a Card: a raised panel (tinted for a warning or a success)
                var tint = self.pal.card if self.skinned else UInt32(0)
                if node.style == CARD_WARN:
                    tint = mix(self.pal.card, self.pal.warn, 0.09)
                elif node.style == CARD_GOOD:
                    tint = mix(self.pal.card, self.pal.good, 0.08)
                _ = msg(w, "setBackgroundColor:", ui_color(tint) if self.skinned else msg(cls("UIColor"), "secondarySystemBackgroundColor"))
                _ = msg(msg(w, "layer"), "setCornerRadius:", Float64(6 if self.skinned else 12))
                if node.pad_v == 0 and node.pad_h == 0:
                    _ = msg(w, "setLayoutMargins:", Float64(12), Float64(14), Float64(12), Float64(14))
                    _ = msg(w, "setLayoutMarginsRelativeArrangement:", 1)
            if self.skinned and node.name == "toolbar" or node.name == "status-bar" or node.name == "menubar":  # the chrome band
                if self.skinned:
                    _ = msg(w, "setBackgroundColor:", ui_color(self.pal.chrome))
            var grows = False
            for c in node.children:
                grows = grows or self.rt.shown.nodes[c].grows
            if node.justify_items == BETWEEN:
                _ = msg(w, "setDistribution:", 3)  # UIStackViewDistributionEqualSpacing
            else:
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
                    _ = msg(child, "setContentHuggingPriority:forAxis:", Float32(1), 1 if vertical else 0)
                if cn.fills and node.align_items != STRETCH:  # stretch across: the stack minus its padding
                    var side = "widthAnchor" if vertical else "heightAnchor"
                    var inset = Float64(2 * (node.pad_h if vertical else node.pad_v))
                    _ = msg(msg(msg(child, side), "constraintEqualToAnchor:constant:", msg(w, side), -inset), "setActive:", 1)
            if node.justify_items == CENTER and not grows:
                var trail = flexible_spacer(vertical)
                _ = msg(w, "addArrangedSubview:", trail)
                var side = "heightAnchor" if vertical else "widthAnchor"
                _ = msg(msg(msg(trail, side), "constraintEqualToAnchor:", msg(lead, side)), "setActive:", 1)
            elif node.justify_items == START and not grows:
                _ = msg(w, "addArrangedSubview:", flexible_spacer(vertical))
            shown = w
        self.widgets[i] = w
        return self.apply_layout(i, shown)

    def apply_layout(self, i: Int, shown: Int) -> Int:
        """Maps node i's own sizes (and, for non-stacks, padding) onto Auto Layout; returns what goes in the parent."""
        ref node = self.rt.shown.nodes[i]
        var outer = shown
        if node.tip != "" and self.widgets[i] != 0:  # a tooltip for the pointer (iPad with a trackpad or mouse)
            var tip = msg(msg(cls("UIToolTipInteraction"), "alloc"), "initWithDefaultToolTip:", ns_string(node.tip))
            _ = msg(self.widgets[i], "addInteraction:", tip)
        var is_stack = node.kind == VSTACK or node.kind == HSTACK
        if (node.pad_v != 0 or node.pad_h != 0) and not is_stack:  # wrap a leaf in a padded stack
            outer = new("UIStackView")
            _ = msg(outer, "setLayoutMargins:", Float64(node.pad_v), Float64(node.pad_h), Float64(node.pad_v), Float64(node.pad_h))
            _ = msg(outer, "setLayoutMarginsRelativeArrangement:", 1)
            _ = msg(outer, "addArrangedSubview:", shown)
        if node.w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintEqualToConstant:", Float64(node.w)), "setActive:", 1)
        if node.h != 0:
            _ = msg(msg(msg(outer, "heightAnchor"), "constraintEqualToConstant:", Float64(node.h)), "setActive:", 1)
        if node.min_w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintGreaterThanOrEqualToConstant:", Float64(node.min_w)), "setActive:", 1)
        if node.max_w != 0:
            _ = msg(msg(msg(outer, "widthAnchor"), "constraintLessThanOrEqualToConstant:", Float64(node.max_w)), "setActive:", 1)
        return outer

    def show(mut self, self_addr: Int):
        # Old controls are deliberately never released: that keeps a control alive
        # while the screen is replaced in the middle of its own action.
        if self.root != 0:
            _ = msg(self.root, "removeFromSuperview")
        var has_alert = False
        for n in self.rt.shown.nodes:
            if n.kind == ALERT:
                has_alert = True
        var root_vc = msg(self.window, "rootViewController")
        if not has_alert and root_vc != 0 and is_alert(msg(root_vc, "presentedViewController")):
            _ = msg(root_vc, "dismissViewControllerAnimated:completion:", 1, 0)  # our alert left the view
        if self.floating != 0:  # the previous screen's popover, context menu or dialog goes with it
            var old = self.floating
            self.floating = 0
            self.floating_node = -1
            if msg(old, "presentingViewController") != 0:
                _ = msg(old, "dismissViewControllerAnimated:completion:", 1, 0)
        self.widgets = List[Int](length=len(self.rt.shown.nodes), fill=0)  # 0 = nil: patches become no-ops
        self.extras = List[Int](length=len(self.rt.shown.nodes), fill=0)
        var theme = self.rt.app.theme()
        if theme.key() != self.theme_key:  # Settings → Appearance: the skin switches live (D-156)
            self.theme_key = theme.key()
            self.pal = theme.palette.copy()
            self.skinned = theme.paint_native
        if self.skinned:
            _ = msg(self.view, "setBackgroundColor:", ui_color(self.pal.page))
            _ = msg(self.window, "setOverrideUserInterfaceStyle:", 2 if self.pal.dark else 1)
            _ = msg(self.window, "setTintColor:", ui_color(self.pal.accent))
        self.canvases = List[AppleCanvas]()
        if self.link != 0:
            _ = msg(self.link, "invalidate")
            self.link = 0
        if len(self.rt.shown.nodes) >= (1 << NODE_BITS):
            self.root = label("Too many items to show (limit 65,535).", 0)  # no stale controls left to use
        else:
            self.root = self.build(0, self_addr)
        _ = msg(self.view, "addSubview:", self.root)
        if self.rt.shown.nodes[0].grows or self.rt.shown.nodes[0].fills:  # the screen fills the safe area
            pin_edges(self.root, self.view)
        else:
            pin_center(self.root, self.view)
        if self.toast != 0 and not self.toast_claimed:  # the new screen has no toast: the old one goes
            _ = msg(self.toast, "removeFromSuperview")
            self.toast = 0
            self.toast_text = ""
        self.toast_claimed = False
        # the screen's shortcuts: one UIKeyCommand per menu item that declares one (the root controller returns them)
        var commands = msg(cls("NSMutableArray"), "array")
        for k in range(len(self.rt.shown.nodes)):
            ref n = self.rt.shown.nodes[k]
            if n.kind == ITEM and len(n.options) > 0 and n.value & DISABLED == 0 and n.msg != 0:
                var parts = shortcut_parts(n.options[0])
                var input = key_input(parts[0])
                if input == 0:
                    continue
                var command = msg(cls("UIKeyCommand"), "commandWithTitle:image:action:input:modifierFlags:propertyList:",
                                  ns_string(n.text), 0, sel("shortcut:"), input, parts[1], ns_number(tag_for(self_addr, k)))
                _ = msg(commands, "addObject:", command)
        self.commands = commands
        if len(self.canvases) > 0:  # one display link ticks every canvas
            self.link = msg(cls("CADisplayLink"), "displayLinkWithTarget:selector:", self.canvases[0].view, sel("canvasFrame:"))
            _ = msg(self.link, "addToRunLoop:forMode:", msg(cls("NSRunLoop"), "mainRunLoop"), ns_string("kCFRunLoopCommonModes"))
        if 0 <= self.focus < len(self.widgets) and self.rt.shown.nodes[self.focus].kind == FIELD:
            # Keep the keyboard up on the new field, on the next run-loop turn (after
            # UIKit has finished with the old field).
            _ = msg(self.widgets[self.focus], "performSelector:withObject:afterDelay:", sel("becomeFirstResponder"), 0, Float64(0))
        self.focus = -1

    def apply(mut self, d: Diff, self_addr: Int):
        if d.rebuild:
            self.show(self_addr)
            return
        for p in d.patches:
            var w = self.widgets[p.node]
            ref node = self.rt.shown.nodes[p.node]
            if p.op == SET_TEXT and node.kind == TEXTAREA:
                if from_ns(msg(w, "text")) != p.text:  # don't fight the typist
                    _ = msg(w, "setText:", ns_string(p.text))
            elif p.op == SET_TEXT and node.kind == DATE:
                _ = msg(w, "setDate:", ns_date(p.text))
            elif p.op == SET_TEXT and node.kind == NAVBAR:
                _ = msg(msg(w, "topItem"), "setTitle:", ns_string(p.text))
            elif p.op == SET_VALUE and (node.kind == SEGMENTED or node.kind == TABS):
                _ = msg(w, "setSelectedSegmentIndex:", p.number)
            elif p.op == SET_VALUE and node.kind == RADIO:
                var buttons = msg(w, "arrangedSubviews")
                for j in range(msg(buttons, "count")):
                    set_radio(msg(buttons, "objectAtIndex:", j), j == p.number)
            elif p.op == SET_TEXT:
                if node.kind == TEXT:
                    _ = msg(w, "setText:", ns_string(p.text))
                elif node.kind == FIELD:
                    if from_ns(msg(w, "text")) != p.text:  # don't fight the typist
                        _ = msg(w, "setText:", ns_string(p.text))
                elif node.kind == TOGGLE:
                    _ = msg(self.extras[p.node], "setText:", ns_string(p.text))
                elif node.kind == BUTTON:
                    var config = msg(msg(w, "configuration"), "copy")
                    _ = msg(config, "setTitle:", ns_string(p.text))
                    _ = msg(w, "setConfiguration:", config)
            elif p.op == SET_VALUE:
                if node.kind == TOGGLE:
                    _ = msg(w, "setOn:animated:", p.number, 1)
                elif node.kind == DROPDOWN:
                    _ = msg(w, "setMenu:", self.menu(node.options, p.number, tag_for(self_addr, p.node)))
                elif node.kind == SLIDER:
                    _ = msg(w, "setValue:animated:", Float32(p.number), 1)
                elif node.kind == PROGRESS:
                    _ = msg(w, "setProgress:animated:", Float32(p.number) / 100.0, 1)
            elif p.op == SET_IMAGE:
                _ = msg(w, "setImage:", ui_image(node.pixels, node.spacing, node.size))
            elif p.op == SET_PLACE and w != 0:  # a Board child moved or resized
                _ = msg(w, "setFrame:", Float64(node.x), Float64(node.y), Float64(node.w), Float64(node.h))
            # SET_MSG needs nothing: events look the message up in rt.shown.
        # Ask for the visible rows of every long list again: row text isn't part of the view.
        for k in range(len(self.rt.shown.nodes)):
            if self.rt.shown.nodes[k].kind == LAZYLIST and self.widgets[k] != 0:
                _ = msg(self.widgets[k], "reloadData")
        self.wake()

    # ---------- canvases ----------

    def canvas_send(mut self, node: Int, kind: Int, x: Float64, y: Float64, dx: Float64, dy: Float64, zoom: Float64, self_addr: Int):
        var d = self.rt.gesture(node, kind, x, y, dx, dy, zoom)
        self.apply(d, self_addr)

    def tick(mut self, seconds: Float64, self_addr: Int):
        """Every display frame: frame events for canvases that asked, then redraws."""
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
            _ = msg(self.link, "setPaused:", 1)

    def idle(self) -> Bool:
        for ref c in self.canvases:
            if self.rt.shown.nodes[c.node].msg2 != 0 or c.drawn != self.rt.shown.nodes[c.node].value or c.wpx == 0:
                return False
        return True

    def wake(self):
        """Something may need drawing (a new version, frames, a new size): tick again."""
        if self.link != 0:
            _ = msg(self.link, "setPaused:", 0)

    def draw_canvas(mut self, k: Int, self_addr: Int):
        """Asks the app to paint canvas k at its real pixel size (if its size or version changed)."""
        var view = self.canvases[k].view
        var node = self.canvases[k].node
        var bounds = msg[CGRect](view, "bounds")
        var scale = msg[Float64](msg(view, "traitCollection"), "displayScale")
        if scale < 1:
            scale = 3.0
        var wpx = Int(bounds.width * scale + 0.5)
        var hpx = Int(bounds.height * scale + 0.5)
        var version = self.rt.shown.nodes[node].value
        if wpx <= 0 or hpx <= 0 or (wpx == self.canvases[k].wpx and hpx == self.canvases[k].hpx and version == self.canvases[k].drawn):
            return
        if len(self.canvases[k].pixels) != wpx * hpx:
            self.canvases[k].pixels = List[UInt32](length=wpx * hpx, fill=0)
        var surface = Surface(Int(self.canvases[k].pixels.unsafe_ptr()), wpx, hpx, scale)
        var d = self.rt.draw(node, surface)
        var image = cg_image(self.canvases[k].pixels, wpx, hpx)
        _ = msg(view, "setImage:", msg(cls("UIImage"), "imageWithCGImage:scale:orientation:", image, scale, 0))
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
        var d = self.rt.dispatch(Event(message, text, number))
        self.apply(d, self_addr)


def ui_image(pixels: List[UInt32], width: Int, height: Int) -> Int:
    """A UIImage from RGBA pixels, via PNG bytes made in Mojo (mojoui/png.mojo)."""
    return msg(cls("UIImage"), "imageWithData:", ns_data(encode_png(pixels, width, height)))


def is_alert(controller: Int) -> Bool:
    """Whether a presented view controller is an alert (not, say, the date picker's calendar)."""
    return controller != 0 and msg[Int8](controller, "isKindOfClass:", cls("UIAlertController")) != 0


def flexible_spacer(vertical: Bool) -> Int:
    """An empty view that soaks up free space along a stack (for justify)."""
    var v = new("UIView")
    _ = msg(v, "setContentHuggingPriority:forAxis:", Float32(1), 1 if vertical else 0)
    return v


def radio_button(title: String, selected: Bool) -> Int:
    """iOS has no radio button: a plain button with a circle / filled-circle symbol."""
    var config = msg(cls("UIButtonConfiguration"), "plainButtonConfiguration")
    _ = msg(config, "setTitle:", ns_string(title))
    _ = msg(config, "setImagePadding:", Float64(10))
    _ = msg(config, "setButtonSize:", 3)  # large touch target
    var b = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", config, 0)
    set_radio(b, selected)
    return b


def set_radio(button: Int, selected: Bool):
    var config = msg(msg(button, "configuration"), "copy")
    var symbol = "largecircle.fill.circle" if selected else "circle"
    _ = msg(config, "setImage:", msg(cls("UIImage"), "systemImageNamed:", ns_string(symbol)))
    _ = msg(button, "setConfiguration:", config)
    _ = msg(button, "setSelected:", 1 if selected else 0)


def label(text: String, style: Int) -> Int:
    var l = new("UILabel")
    _ = msg(l, "setText:", ns_string(text))
    var font = "UICTFontTextStyleBody"  # Dynamic Type: follows the user's text size
    if style == TITLE:
        font = "UICTFontTextStyleTitle0"  # large title
    elif style == HEADLINE:
        font = "UICTFontTextStyleHeadline"
    elif style == CAPTION:
        font = "UICTFontTextStyleFootnote"
        _ = msg(l, "setTextColor:", msg(cls("UIColor"), "secondaryLabelColor"))
    _ = msg(l, "setFont:", msg(cls("UIFont"), "preferredFontForTextStyle:", ns_string(font)))
    _ = msg(l, "setAdjustsFontForContentSizeCategory:", 1)
    _ = msg(l, "setTextAlignment:", 1)  # centre
    _ = msg(l, "setNumberOfLines:", 0)
    return l


def make_button(title: String, style: Int, icon: String = "", skinned: Bool = False, pal: Palette = Palette.plain()) -> Int:
    """iOS 26's glass buttons, filled/gray buttons before that; a skin draws flat buttons in its own colours.
    SUBTLE and ICON_ONLY are plain; TOOL puts the icon above a small title."""
    var config_cls = cls("UIButtonConfiguration")
    var glass = msg[Int8](config_cls, "respondsToSelector:", sel("prominentGlassButtonConfiguration")) != 0
    var maker: String
    if style == SUBTLE or style == ICON_ONLY or style == ICON_ON or style == TOOL or style == TOOL_ON:
        maker = "plainButtonConfiguration"
    elif style == PROMINENT:
        maker = "filledButtonConfiguration" if skinned else ("prominentGlassButtonConfiguration" if glass else "filledButtonConfiguration")
    else:
        maker = "grayButtonConfiguration" if skinned else ("glassButtonConfiguration" if glass else "grayButtonConfiguration")
    var config = msg(config_cls, maker)
    if style != ICON_ONLY and style != ICON_ON:
        _ = msg(config, "setTitle:", ns_string(title))
    if icon != "":
        _ = msg(config, "setImage:", msg(cls("UIImage"), "systemImageNamed:", ns_string(sf_symbol(icon))))
        _ = msg(config, "setImagePadding:", Float64(4 if style == TOOL or style == TOOL_ON else 8))
    if style == TOOL or style == TOOL_ON:
        _ = msg(config, "setImagePlacement:", 1)  # NSDirectionalRectEdgeTop: the icon above the title
        _ = msg(config, "setButtonSize:", 1)  # small
        if style == TOOL_ON:
            _ = msg(config, "setBaseBackgroundColor:", ui_color(pal.accent_wash) if skinned else msg(cls("UIColor"), "secondarySystemFillColor"))
            _ = msg(config, "setBaseForegroundColor:", ui_color(pal.accent) if skinned else msg(cls("UIColor"), "tintColor"))
            _ = msg(config, "setCornerStyle:", 1)  # small
            config = msg(config, "copy")
    elif style == ICON_ON:  # (a toggle that is on: Bold, Align left)
        _ = msg(config, "setBaseBackgroundColor:", ui_color(pal.accent_wash) if skinned else msg(cls("UIColor"), "secondarySystemFillColor"))
        _ = msg(config, "setBaseForegroundColor:", ui_color(pal.accent) if skinned else msg(cls("UIColor"), "tintColor"))
        _ = msg(config, "setCornerStyle:", 1)
    else:
        _ = msg(config, "setButtonSize:", 2 if skinned else 3)  # medium / large
        _ = msg(config, "setCornerStyle:", 1 if skinned else 4)  # small radius / capsule
    if style == DESTRUCTIVE:
        _ = msg(config, "setBaseForegroundColor:", msg(cls("UIColor"), "systemRedColor"))
    elif skinned and style == PROMINENT:
        _ = msg(config, "setBaseBackgroundColor:", ui_color(pal.accent))
        _ = msg(config, "setBaseForegroundColor:", ui_color(pal.accent_ink))
    elif skinned and style != TOOL_ON and style != ICON_ON:
        _ = msg(config, "setBaseForegroundColor:", ui_color(pal.ink))
        if style == 0:
            _ = msg(config, "setBaseBackgroundColor:", ui_color(pal.card))
    var b = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", config, 0)
    if style == ICON_ONLY or style == ICON_ON:
        _ = msg(b, "setAccessibilityLabel:", ns_string(title))
    return b


def check_button(title: String, on: Bool, accent: Int) -> Int:
    """A checkbox: a plain button with a square (ticked or not) before its title."""
    var config = msg(cls("UIButtonConfiguration"), "plainButtonConfiguration")
    _ = msg(config, "setTitle:", ns_string(title))
    _ = msg(config, "setImagePadding:", Float64(10))
    _ = msg(config, "setImage:", msg(cls("UIImage"), "systemImageNamed:", ns_string("checkmark.square.fill" if on else "square")))
    _ = msg(config, "setBaseForegroundColor:", accent if on else msg(cls("UIColor"), "labelColor"))
    var b = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", config, 0)
    _ = msg(b, "setContentHorizontalAlignment:", 1)  # leading
    _ = msg(b, "setSelected:", 1 if on else 0)
    return b


def make_toast(text: String, action: String, tag: Int, target: Int, pal: Palette) -> Int:
    """A toast: a dark rounded strip at the bottom with the message, its action (on_action) and ✕ (on_close)."""
    var strip = new("UIStackView")
    _ = msg(strip, "setAxis:", 0)
    _ = msg(strip, "setAlignment:", 3)
    _ = msg(strip, "setSpacing:", Float64(12))
    _ = msg(strip, "setLayoutMargins:", Float64(10), Float64(14), Float64(10), Float64(10))
    _ = msg(strip, "setLayoutMarginsRelativeArrangement:", 1)
    _ = msg(strip, "setBackgroundColor:", ui_color(pal.ink))
    _ = msg(msg(strip, "layer"), "setCornerRadius:", Float64(6))
    _ = msg(strip, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
    _ = msg(strip, "setTag:", tag)
    var message = label(text, 0)
    _ = msg(message, "setTextColor:", ui_color(pal.card))
    _ = msg(strip, "addArrangedSubview:", message)
    if action != "":
        var config = msg(cls("UIButtonConfiguration"), "plainButtonConfiguration")
        _ = msg(config, "setTitle:", ns_string(action))
        _ = msg(config, "setBaseForegroundColor:", ui_color(mix(pal.accent, pal.card, 0.55)))
        var b = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", config, 0)
        _ = msg(b, "setTag:", tag)
        _ = msg(b, "addTarget:action:forControlEvents:", target, sel("tap:"), TOUCH_UP_INSIDE)
        _ = msg(strip, "addArrangedSubview:", b)
    var close_config = msg(cls("UIButtonConfiguration"), "plainButtonConfiguration")
    _ = msg(close_config, "setImage:", msg(cls("UIImage"), "systemImageNamed:", ns_string("xmark")))
    _ = msg(close_config, "setBaseForegroundColor:", ui_color(pal.card))
    var close = msg(cls("UIButton"), "buttonWithConfiguration:primaryAction:", close_config, 0)
    _ = msg(close, "setTag:", tag)
    _ = msg(close, "addTarget:action:forControlEvents:", target, sel("closeOverlay:"), TOUCH_UP_INSIDE)
    _ = msg(strip, "addArrangedSubview:", close)
    return strip


def register_fonts():
    """The app's own fonts (fonts/ in the bundle, D-155), registered for this process through CoreText."""
    var bundle = msg(cls("NSBundle"), "mainBundle")
    for name in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "JetBrainsMono-Regular", "JetBrainsMono-Bold"]:
        var url = msg(bundle, "URLForResource:withExtension:subdirectory:", ns_string(name), ns_string("ttf"), ns_string("fonts"))
        if url != 0:
            _ = cfunc[Int8]("CTFontManagerRegisterFontsForURL", url, 1, 0)  # kCTFontManagerScopeProcess


def pin_center(view: Int, inside: Int):
    """Auto Layout: centre `view` in the safe area (clear of the Dynamic Island and
    home indicator), at most its width minus margins."""
    var guide = msg(inside, "safeAreaLayoutGuide")
    _ = msg(view, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
    for anchor in ["centerXAnchor", "centerYAnchor"]:
        var c = msg(msg(view, anchor), "constraintEqualToAnchor:", msg(guide, anchor))
        _ = msg(c, "setActive:", 1)
    var w = msg(
        msg(view, "widthAnchor"), "constraintLessThanOrEqualToAnchor:constant:", msg(guide, "widthAnchor"), Float64(-48)
    )
    _ = msg(w, "setActive:", 1)
    # Keeps content inside the safe area. Long content belongs in a Scroll; without
    # one, very tall screens get squashed rather than running off-screen.
    var h = msg(msg(view, "heightAnchor"), "constraintLessThanOrEqualToAnchor:", msg(guide, "heightAnchor"))
    _ = msg(h, "setActive:", 1)


def pin_edges(view: Int, inside: Int):
    """Auto Layout: fill the safe area (a screen that fills the window)."""
    var guide = msg(inside, "safeAreaLayoutGuide")
    _ = msg(view, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
    for anchor in ["leadingAnchor", "trailingAnchor", "topAnchor", "bottomAnchor"]:
        _ = msg(msg(msg(view, anchor), "constraintEqualToAnchor:", msg(guide, anchor)), "setActive:", 1)


def from_tag(control: Int) -> Tuple[Int, Int]:
    var tag = msg(control, "tag")
    return (tag >> NODE_BITS, tag & ((1 << NODE_BITS) - 1))


def host_at[A: App](addr: Int) -> Pointer[UIKitHost[A], MutUntrackedOrigin]:
    return Pointer[UIKitHost[A], MutUntrackedOrigin](unsafe_from_address=addr)


# ---------- scene delegate methods and the dropdown block (UIKit calls these) ----------

# ---------- MojoCanvasView methods (self is the canvas view; its tag says host + node) ----------

def on_canvas_frame[A: App](view: Int, cmd: Int, link: Int) abi("C"):
    var t = from_tag(view)
    host_at[A](t[0])[].tick(msg[Float64](link, "timestamp"), t[0])


def on_canvas_layout[A: App](view: Int, cmd: Int) abi("C"):
    """layoutSubviews: UIImageView's own, then wake the display link (the size may have changed)."""
    var parent = List[Int](length=2, fill=0)  # struct objc_super { receiver, super_class }
    parent[0] = view
    parent[1] = cls("UIImageView")
    _ = cfunc("objc_msgSendSuper", Int(parent.unsafe_ptr()), sel("layoutSubviews"))
    _ = len(parent)
    var t = from_tag(view)
    if t[0] != 0:
        host_at[A](t[0])[].wake()


def canvas_index[A: App](host: Pointer[UIKitHost[A], MutUntrackedOrigin], node: Int) -> Int:
    for k in range(len(host[].canvases)):
        if host[].canvases[k].node == node:
            return k
    return -1


def on_canvas_pan[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    """A one-finger drag: PRESS where it starts, PANs while it moves, RELEASE where it ends (as GTK sends them)."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    var state = msg(recognizer, "state")
    var at = msg[CGPoint](recognizer, "locationInView:", view)
    var k = canvas_index[A](host, t[1])
    if state == 1:  # began
        _ = msg(view, "becomeFirstResponder")
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
    host[].canvas_send(t[1], PAN, at.x, at.y, moved.x, moved.y, 1, t[0])


def on_canvas_double[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    var t = from_tag(view)
    var at = msg[CGPoint](recognizer, "locationInView:", view)
    host_at[A](t[0])[].canvas_send(t[1], DOUBLE, at.x, at.y, 0, 0, 1, t[0])


def on_canvas_secondary[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    """A right click (trackpad or mouse): SECONDARY, where a context menu opens."""
    var t = from_tag(view)
    var at = msg[CGPoint](recognizer, "locationInView:", view)
    host_at[A](t[0])[].canvas_send(t[1], SECONDARY, at.x, at.y, 0, 0, 1, t[0])


def on_canvas_long_press[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    """A long press with a finger: the same as a right click."""
    if msg(recognizer, "state") != 1:  # began
        return
    var t = from_tag(view)
    var at = msg[CGPoint](recognizer, "locationInView:", view)
    host_at[A](t[0])[].canvas_send(t[1], SECONDARY, at.x, at.y, 0, 0, 1, t[0])


def can_become_first_responder(view: Int, cmd: Int) abi("C") -> Int8:
    return 1  # a canvas takes the hardware keyboard once touched


def on_canvas_presses[A: App](view: Int, cmd: Int, presses: Int, event: Int) abi("C"):
    """pressesBegan:withEvent: hardware keys on a canvas → KEY (the web's key names, GTK's modifier bits)."""
    var t = from_tag(view)
    var host = host_at[A](t[0])
    if t[1] >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[t[1]].size != 1:
        return
    var all = msg(presses, "allObjects")
    for j in range(msg(all, "count")):
        var press = msg(all, "objectAtIndex:", j)
        var key = msg(press, "key")
        if key == 0:
            continue
        var flags = msg(key, "modifierFlags")
        var mods = (1 if flags & KEY_SHIFT != 0 else 0) + (2 if flags & (KEY_CONTROL | KEY_COMMAND) != 0 else 0) + (4 if flags & KEY_ALTERNATE != 0 else 0)
        var name = key_name_of(key)
        if name == "" or name.byte_length() > 32:
            continue
        var d = host[].rt.key(t[1], name, mods)
        host[].apply(d, t[0])


def on_canvas_pinch[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    var t = from_tag(view)
    var factor = msg[Float64](recognizer, "scale")
    _ = msg(recognizer, "setScale:", Float64(1))  # factors from here on
    var at = msg[CGPoint](recognizer, "locationInView:", view)
    host_at[A](t[0])[].canvas_send(t[1], ZOOM, at.x, at.y, 0, 0, factor, t[0])


def on_canvas_tap[A: App](view: Int, cmd: Int, recognizer: Int) abi("C"):
    var t = from_tag(view)
    var at = msg[CGPoint](recognizer, "locationInView:", view)
    host_at[A](t[0])[].canvas_send(t[1], TAP, at.x, at.y, 0, 0, 1, t[0])


def on_tap[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], False, "", 0, t[0])


def on_check[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    """A checkbox button: flip it, then send 1 or 0 like a toggle."""
    var t = from_tag(sender)
    var host = host_at[A](t[0])
    var now = 0 if msg[Int8](sender, "isSelected") != 0 else 1
    _ = msg(sender, "setSelected:", now)
    var config = msg(msg(sender, "configuration"), "copy")
    _ = msg(config, "setImage:", msg(cls("UIImage"), "systemImageNamed:", ns_string("checkmark.square.fill" if now == 1 else "square")))
    _ = msg(config, "setBaseForegroundColor:", host[].accent() if now == 1 else msg(cls("UIColor"), "labelColor"))
    _ = msg(sender, "setConfiguration:", config)
    host[].send(t[1], False, "", now, t[0])


def on_close_overlay[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    """A dialog's or toast's ✕: on_close."""
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], True, "", 0, t[0])


def on_shortcut[A: App](target: Int, cmd: Int, command: Int) abi("C"):
    """A UIKeyCommand fired: the item whose tag it carries."""
    var tag = msg(msg(command, "propertyList"), "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].kind == ITEM:
        host[].send(node, False, "", 0, host_addr)


def on_root_key_commands[A: App](controller: Int, cmd: Int) abi("C") -> Int:
    """The root view controller's keyCommands: the screen's shortcuts (the window's tag says which host)."""
    var window = msg(msg(controller, "view"), "window")
    if window == 0:
        return 0
    var addr = msg(window, "tag")
    if addr == 0:
        return 0
    return host_at[A](addr)[].commands


def on_pick_item[A: App](block: Int, action: Int) abi("C"):
    """A menu item (a UIAction) was chosen: its identifier is the item's tag."""
    var id = from_ns(msg(action, "identifier"))
    try:
        var tag = Int(id)
        var host_addr = tag >> NODE_BITS
        var node = tag & ((1 << NODE_BITS) - 1)
        var host = host_at[A](host_addr)
        if node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].kind == ITEM:
            host[].send(node, False, "", 0, host_addr)
    except:
        return


def on_present_floating[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    """Presents the popover, context menu or dialog built for a node (on the next run-loop turn)."""
    var tag = msg(number, "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if host[].floating == 0 or host[].floating_node != node:
        return  # the screen changed before it could be shown
    var root = msg(host[].window, "rootViewController")
    if msg(root, "presentedViewController") != 0:
        return
    _ = msg(root, "presentViewController:animated:completion:", host[].floating, 1, 0)


def on_floating_dismissed[A: App](target: Int, cmd: Int, presentation: Int) abi("C"):
    """presentationControllerDidDismiss: a tap outside a popover, a sheet swiped down: on_close."""
    var vc = msg(presentation, "presentedViewController")
    var tag = msg(msg(vc, "view"), "tag")  # (set when it was built)
    if tag == 0:
        return
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if host[].floating == vc:
        host[].floating = 0
        host[].floating_node = -1
        if node < len(host[].rt.shown.nodes):
            host[].send(node, True, "", 0, host_addr)


def adaptive_style(target: Int, cmd: Int, presentation: Int, traits: Int) abi("C") -> Int:
    return -1  # UIModalPresentationNone: a popover stays a popover on an iPhone too


def on_toast_timeout[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    var tag = msg(number, "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if host[].toast != 0 and msg(host[].toast, "tag") == tag and node < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[node].kind == TOAST:
        host[].send(node, True, "", 0, host_addr)


def on_board_pan[A: App](target: Int, cmd: Int, recognizer: Int) abi("C"):
    """A Board child dragged: the Board's on_move with the child's index and how far (as GTK and the web send it)."""
    var child = msg(recognizer, "view")
    var t = from_tag(child)
    var host = host_at[A](t[0])
    var state = msg(recognizer, "state")
    if state != 2:  # changed
        return
    var moved = msg[CGPoint](recognizer, "translationInView:", msg(child, "superview"))
    _ = msg(recognizer, "setTranslation:inView:", Float64(0), Float64(0), msg(child, "superview"))
    for b in range(len(host[].rt.shown.nodes)):
        ref board = host[].rt.shown.nodes[b]
        if board.kind != BOARD:
            continue
        for k in range(len(board.children)):
            if board.children[k] == t[1]:
                var d = host[].rt.gesture(b, PAN, Float64(k), 0, moved.x, moved.y, 1)
                host[].apply(d, t[0])
                return


def on_changed[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(sender, "text")), 0, t[0])


def on_submit[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], True, from_ns(msg(sender, "text")), 0, t[0])


def on_toggle[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var on = Int(msg[Int8](sender, "isOn"))
    host_at[A](t[0])[].send(t[1], False, "", 1 if on != 0 else 0, t[0])


def on_segment[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var index = msg(sender, "selectedSegmentIndex")
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(sender, "titleForSegmentAtIndex:", index)), index, t[0])


def on_radio[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var index = msg(msg(msg(sender, "superview"), "arrangedSubviews"), "indexOfObject:", sender)
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(msg(sender, "configuration"), "title")), index, t[0])


def on_text_view_change[A: App](target: Int, cmd: Int, view: Int) abi("C"):
    var t = from_tag(view)
    host_at[A](t[0])[].send(t[1], False, from_ns(msg(view, "text")), 0, t[0])


def on_date[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    host_at[A](t[0])[].send(t[1], False, date_text(msg(sender, "date")), 0, t[0])


def on_alert_action[A: App](block: Int, action: Int) abi("C"):
    """An alert button was tapped: the block carries "(host << 16) | node"; the action's title says which."""
    var tag = block_data(block)
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if node >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[node].kind != ALERT:
        return
    var title = from_ns(msg(action, "title"))
    ref opts = host[].rt.shown.nodes[node].options
    for j in range(len(opts)):
        if opts[j] == title:
            host[].send(node, False, title, j, host_addr)
            return


def on_present_alert[A: App](target: Int, cmd: Int, number: Int) abi("C"):
    var tag = msg(number, "longValue")
    var host_addr = tag >> NODE_BITS
    var node = tag & ((1 << NODE_BITS) - 1)
    var host = host_at[A](host_addr)
    if node >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[node].kind != ALERT:
        return  # the screen changed before it could be shown
    var n = host[].rt.shown.nodes[node].copy()
    var alert = msg(cls("UIAlertController"), "alertControllerWithTitle:message:preferredStyle:", ns_string(n.text), ns_string(n.hint), 1)
    var handler = data_block(on_alert_action[A], "v16@?0@8", tag)
    for j in range(len(n.options)):
        var lower = n.options[j].lower()
        var style = 1 if (j == 0 and len(n.options) > 1) else 0  # the first of several is Cancel
        if j > 0 and (lower.startswith("delete") or lower.startswith("remove")):
            style = 2  # destructive: shown in red
        var action = msg(cls("UIAlertAction"), "actionWithTitle:style:handler:", ns_string(n.options[j]), style, handler)
        _ = msg(alert, "addAction:", action)
    var root = msg(host[].window, "rootViewController")
    if is_alert(msg(root, "presentedViewController")):
        return  # already showing it (the screen was rebuilt twice while the alert was in the view)
    _ = msg(root, "presentViewController:animated:completion:", alert, 1, 0)


def on_row_count[A: App](target: Int, cmd: Int, table: Int, section: Int) abi("C") -> Int:
    var t = from_tag(table)
    var host = host_at[A](t[0])
    if t[1] >= len(host[].rt.shown.nodes) or host[].rt.shown.nodes[t[1]].kind != LAZYLIST:
        return 0
    return host[].rt.shown.nodes[t[1]].value


def on_row_cell[A: App](target: Int, cmd: Int, table: Int, index_path: Int) abi("C") -> Int:
    """UITableView asks for a row's cell only when it scrolls into view."""
    var t = from_tag(table)
    var host = host_at[A](t[0])
    var cell = msg(table, "dequeueReusableCellWithIdentifier:forIndexPath:", ns_string("row"), index_path)
    if t[1] < len(host[].rt.shown.nodes) and host[].rt.shown.nodes[t[1]].kind == LAZYLIST:
        var row = msg(index_path, "row")
        var config = msg(cell, "defaultContentConfiguration")
        _ = msg(config, "setText:", ns_string(host[].rt.app.row(host[].rt.shown.nodes[t[1]].msg2, row)))
        _ = msg(cell, "setContentConfiguration:", config)
    return cell


def on_row_select[A: App](target: Int, cmd: Int, table: Int, index_path: Int) abi("C"):
    _ = msg(table, "deselectRowAtIndexPath:animated:", index_path, 1)
    var t = from_tag(table)
    host_at[A](t[0])[].send(t[1], False, "", msg(index_path, "row"), t[0])


def on_slide[A: App](target: Int, cmd: Int, sender: Int) abi("C"):
    var t = from_tag(sender)
    var value = Int(msg[Float32](sender, "value") + 0.5)
    host_at[A](t[0])[].send(t[1], False, "", value, t[0])


def on_choose[A: App](block: Int, action: Int) abi("C"):
    """A dropdown option was chosen: its identifier is "<tag>:<index>"."""
    var id = from_ns(msg(action, "identifier"))
    var colon = id.find(":")
    if colon < 0:
        return
    try:
        var tag = Int(String(id[byte=:colon]))
        var index = Int(String(id[byte = colon + 1 :]))
        var host_addr = tag >> NODE_BITS
        var node = tag & ((1 << NODE_BITS) - 1)
        host_at[A](host_addr)[].send(node, False, from_ns(msg(action, "title")), index, host_addr)
    except:
        return


def did_finish_launching(target: Int, cmd: Int, app: Int, options: Int) abi("C") -> Int8:
    return 1  # YES; the scene builds the UI


def scene_will_connect[A: App](delegate: Int, cmd: Int, scene: Int, session: Int, options: Int) abi("C"):
    """Creates the app and its window when UIKit connects the scene."""
    var host = alloc(Layout[UIKitHost[A]].single()).unsafe_leak()  # lives as long as the app
    host.unsafe_write(UIKitHost[A]())
    var addr = Int(host)
    if (addr >> (63 - NODE_BITS)) != 0:
        print("mojoui: can't pack host address into a control tag")
        return
    host[].target = delegate
    host[].choose = global_block(on_choose[A], "v16@?0@8")  # void (^)(UIAction *)
    host[].pick = global_block(on_pick_item[A], "v16@?0@8")
    register_fonts()
    host[].window = msg(msg(cls("UIWindow"), "alloc"), "initWithWindowScene:", scene)  # kept for the app's life
    _ = msg(host[].window, "setTag:", addr)  # (the root controller finds its host through it: keyCommands)
    var controller = new("MojoViewController")
    host[].view = msg(controller, "view")
    _ = msg(host[].view, "setBackgroundColor:", msg(cls("UIColor"), "systemBackgroundColor"))
    host[].show(addr)
    _ = msg(host[].window, "setRootViewController:", controller)
    _ = msg(host[].window, "makeKeyAndVisible")


def run[A: App](argc: c_int, argv: Int) -> c_int:
    """Starts UIKit; the scene delegate then creates the app. Never returns."""
    _ = pool_push()
    var app_delegate = new_class("MojoAppDelegate", "UIResponder")
    add_protocol(app_delegate, "UIApplicationDelegate")
    add_method(app_delegate, "application:didFinishLaunchingWithOptions:", did_finish_launching, "B@:@@")
    register_class(app_delegate)

    var scene_delegate = new_class("MojoSceneDelegate", "UIResponder")
    add_protocol(scene_delegate, "UIWindowSceneDelegate")
    add_method(scene_delegate, "scene:willConnectToSession:options:", scene_will_connect[A], "v@:@@@")
    add_method(scene_delegate, "tap:", on_tap[A], "v@:@")
    add_method(scene_delegate, "changed:", on_changed[A], "v@:@")
    add_method(scene_delegate, "submit:", on_submit[A], "v@:@")
    add_method(scene_delegate, "toggle:", on_toggle[A], "v@:@")
    add_method(scene_delegate, "slide:", on_slide[A], "v@:@")
    add_method(scene_delegate, "segment:", on_segment[A], "v@:@")
    add_method(scene_delegate, "radio:", on_radio[A], "v@:@")
    add_method(scene_delegate, "date:", on_date[A], "v@:@")
    add_method(scene_delegate, "textViewDidChange:", on_text_view_change[A], "v@:@")
    add_method(scene_delegate, "presentAlert:", on_present_alert[A], "v@:@")
    add_method(scene_delegate, "check:", on_check[A], "v@:@")
    add_method(scene_delegate, "closeOverlay:", on_close_overlay[A], "v@:@")
    add_method(scene_delegate, "shortcut:", on_shortcut[A], "v@:@")
    add_method(scene_delegate, "presentFloating:", on_present_floating[A], "v@:@")
    add_method(scene_delegate, "presentationControllerDidDismiss:", on_floating_dismissed[A], "v@:@")
    add_method(scene_delegate, "adaptivePresentationStyleForPresentationController:traitCollection:", adaptive_style, "q@:@@")
    add_method(scene_delegate, "toastTimeout:", on_toast_timeout[A], "v@:@")
    add_method(scene_delegate, "boardPan:", on_board_pan[A], "v@:@")
    add_protocol(scene_delegate, "UIPopoverPresentationControllerDelegate")
    add_method(scene_delegate, "tableView:numberOfRowsInSection:", on_row_count[A], "q@:@q")
    add_method(scene_delegate, "tableView:cellForRowAtIndexPath:", on_row_cell[A], "@@:@@")
    add_method(scene_delegate, "tableView:didSelectRowAtIndexPath:", on_row_select[A], "v@:@@")
    add_protocol(scene_delegate, "UITextViewDelegate")
    add_protocol(scene_delegate, "UITableViewDataSource")
    add_protocol(scene_delegate, "UITableViewDelegate")
    register_class(scene_delegate)
    var canvas = new_class("MojoCanvasView", "UIImageView")
    add_method(canvas, "canvasFrame:", on_canvas_frame[A], "v@:@")
    add_method(canvas, "layoutSubviews", on_canvas_layout[A], "v@:")
    add_method(canvas, "canvasPan:", on_canvas_pan[A], "v@:@")
    add_method(canvas, "canvasPinch:", on_canvas_pinch[A], "v@:@")
    add_method(canvas, "canvasTap:", on_canvas_tap[A], "v@:@")
    add_method(canvas, "canvasDouble:", on_canvas_double[A], "v@:@")
    add_method(canvas, "canvasSecondary:", on_canvas_secondary[A], "v@:@")
    add_method(canvas, "canvasLongPress:", on_canvas_long_press[A], "v@:@")
    add_method(canvas, "canBecomeFirstResponder", can_become_first_responder, "B@:")
    add_method(canvas, "pressesBegan:withEvent:", on_canvas_presses[A], "v@:@@")
    register_class(canvas)
    # the root view controller: its keyCommands are the screen's shortcuts (menu items that declare one)
    var controller = new_class("MojoViewController", "UIViewController")
    add_method(controller, "keyCommands", on_root_key_commands[A], "@@:")
    add_method(controller, "canBecomeFirstResponder", can_become_first_responder, "B@:")
    register_class(controller)
    return external_call["UIApplicationMain", c_int](argc, argv, 0, ns_string("MojoAppDelegate"))
