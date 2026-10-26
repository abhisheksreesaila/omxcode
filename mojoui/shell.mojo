# mojoui.shell: an app's frame (goal 33 M7, D-415): a bar across the top (a brand, a trail, a status, links to the
# places every page shares) over one page card that fills the rest of the window. Each piece wears a framework role its
# theme shapes (sizes, spacing, colours: none here), so an app only says what is in its frame.
#
#   Shell(AppBar([Brand("omx", "omxconsole", HOME), BarRule(), Breadcrumbs(…), Spacer(), Beacon(…), NavLinks(links)]),
#         PageCard([header, Divider().fill(), body]), compact=self.compact())

from mojoui.view import View, Text, Button, VStack, HStack, SUBTLE, ICON_ONLY, CENTER, START, STRETCH, Node, VSTACK, _container

comptime COMPACT_WIDTH = 760  # a window this narrow or narrower gets the compact layout (a phone; one column, folded bars)


def is_compact(width: Int) -> Bool:
    """Whether a window `width` points wide takes the compact layout (COMPACT_WIDTH: phones, a narrow window)."""
    return width <= COMPACT_WIDTH


def AppBar(var items: List[View], compact: Bool = False) -> View:
    """The bar across the top of every page: its items left to right, centred on its middle (roles app-bar,
    app-bar-compact: its height, insets and spacing)."""
    return HStack(items^, spacing=0).align(CENTER).fill().tag("app-bar-compact" if compact else "app-bar")


def BrandMark(text: String) -> View:
    """An app's mark: a few letters centred on a small square (role brand-mark)."""
    return VStack(Text(text), spacing=0).align(CENTER).justify(CENTER).tag("brand-mark")


def BrandName(title: String, on_tap: Int) -> View:
    """The app's name beside its mark, tapping home (role brand-name)."""
    return Button(title, on_tap, SUBTLE).tag("brand-name")


def Brand(mark: String, name: String, on_tap: Int) -> View:
    """The mark and the name together, as the bar's first item ("" name: the mark alone; role brand)."""
    var items: List[View] = [BrandMark(mark)]
    if name != "":
        items.append(BrandName(name, on_tap))
    return HStack(items^, spacing=0).align(CENTER).tag("brand")


def BarRule(compact: Bool = False) -> View:
    """A short upright rule between parts of a bar (roles bar-rule, bar-rule-compact: the room round it, bar-rule-line:
    the line)."""
    return HStack(VStack(spacing=0).tag("bar-rule-line"), spacing=0).align(CENTER).tag("bar-rule-compact" if compact else "bar-rule")


def NavLink(title: String, icon: String, on_tap: Int, here: Bool = False, hue: Int = 0) -> View:
    """A quiet link to a place every page shares (role nav-link; nav-link-here where you are); `hue` colours its icon
    (1–6 the data colours, 7 good, 8 warning: nav-link-<hue>, nav-link-here-<hue>)."""
    var role = String("nav-link-here") if here else String("nav-link")
    return Button(title, on_tap, SUBTLE, icon).tag(role + ("-" + String(min(hue, 8)) if hue > 0 else String("")))


def NavLinks(var links: List[View]) -> View:
    """The places' links side by side (role nav-links)."""
    return HStack(links^, spacing=0).align(CENTER).tag("nav-links")


def NavMore(title: String, on_tap: Int) -> View:
    """The places folded into one ⋯ button, when the bar is compact (`title` names them for screen readers; role
    nav-more)."""
    return Button(title, on_tap, ICON_ONLY, icon="ellipsis").tag("nav-more")


def PageCard(var items: List[View]) -> View:
    """A page: one card that fills its frame; its parts bring their own padding (role page-card)."""
    return _container(Node(VSTACK, spacing=0), items).align(START).grow().tag("page-card")


def Shell(bar: View, page: View, compact: Bool = False) -> View:
    """The window: the bar over the page, which fills the rest (roles shell; page-frame and page-frame-compact: the
    room round the page)."""
    var frame = HStack(page.copy(), spacing=0).align(STRETCH).fill().grow().tag("page-frame-compact" if compact else "page-frame")
    return VStack(bar.copy(), frame^, spacing=0).align(START).fill().grow().tag("shell")
