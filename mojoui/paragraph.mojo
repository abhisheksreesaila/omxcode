# mojoui.paragraph (goal 33 M7, D-470): a paragraph of styled runs that the HOST wraps, as a browser lays out text.
#
#   Paragraph([Plain("Use "), Code("mxc learn"), Plain(" or read "), Link("the docs", "https://…")], role="md-p", on_link=OPEN)
#
# A run is plain, bold, italic, code or a link (or bold and italic together, a link in code…); each may wear a role
# of its own (md-strong, md-code…) whose type the theme's Look gives (font, size, weight, ink, a fill behind it). The
# paragraph wears `role` (its type and line height). Mojo never breaks the lines: on the web the runs are inline
# elements of one block; on GTK one wrapping label with Pango markup (every run's words escaped); on the Mac one
# wrapping label with an attributed string; on the agent host the plain text.
#
# A link's tap sends `on_link` with event.number = the run's index and event.text = its href; with no on_link the
# host opens the href itself (the browser's new tab, GTK's and the Mac's default browser).
#
# Encoding (one node, kind PARAGRAPH): text = the plain text (the runs' words joined), msg = on_link, style = the text
# style (BODY…), options = RUN_FIELDS strings per run: flags ("b", "i", "c", "l" letters), role, href, text.

from mojoui.view import View, Node, PARAGRAPH, BODY, NO_MSG
from mojoui.theme import Look
from mojoui.linebreak import css_breaks

comptime RUN_FIELDS = 4


struct Run(Copyable, Movable, Equatable, Writable):
    """A run of inline text and how it looks. `href` is "" unless the run is a link; `role` "" wears no role of its
    own (the paragraph's type, plus bold, italic, mono or a link's underline by its flags)."""

    var text: String
    var bold: Bool
    var italic: Bool
    var code: Bool
    var href: String
    var role: String

    def __init__(out self, text: String):
        self = Self(text, False, False, False, "", "")

    def __init__(out self, text: String, bold: Bool, italic: Bool, code: Bool, href: String):
        self = Self(text, bold, italic, code, href, "")

    def __init__(out self, text: String, bold: Bool, italic: Bool, code: Bool, href: String, role: String):
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.href = href
        self.role = role

    def same_look(self, other: Self) -> Bool:
        return (self.bold == other.bold and self.italic == other.italic and self.code == other.code and self.href == other.href
                and self.role == other.role)

    def plain(self) -> Bool:
        return not (self.bold or self.italic or self.code) and self.href == ""

    def flags(self) -> String:
        return ("b" if self.bold else "") + ("i" if self.italic else "") + ("c" if self.code else "") + ("l" if self.href != "" else "")

    def __eq__(self, other: Self) -> Bool:
        return self.text == other.text and self.same_look(other)

    def write_to(self, mut writer: Some[Writer]):
        writer.write("Run('", self.text, "'", " bold" if self.bold else "", " italic" if self.italic else "",
                     " code" if self.code else "", " href=" + self.href if self.href != "" else "",
                     " role=" + self.role if self.role != "" else "", ")")


def Plain(text: String, role: String = "") -> Run:
    return Run(text, False, False, False, "", role)


def Bold(text: String, role: String = "") -> Run:
    return Run(text, True, False, False, "", role)


def Italic(text: String, role: String = "") -> Run:
    return Run(text, False, True, False, "", role)


def Code(text: String, role: String = "") -> Run:
    return Run(text, False, False, True, "", role)


def Link(text: String, href: String, role: String = "") -> Run:
    return Run(text, False, False, False, href, role)


def Paragraph(runs: List[Run], role: String = "paragraph", on_link: Int = NO_MSG, style: Int = BODY, lead: Bool = False) -> View:
    """One block of runs the host wraps. Empty runs are dropped. `lead`: the first run stands in a column of its own,
    the others wrapping beside it, both on the middle and the role's gap apart (a command's "$ ": the web's flex item;
    GTK and the Mac keep it inline). value = 1."""
    var opts = List[String]()
    var plain = String("")
    for r in runs:
        if r.text == "":
            continue
        opts.append(r.flags())
        opts.append(r.role)
        opts.append(r.href)
        opts.append(r.text)
        plain += r.text
    var node = Node(PARAGRAPH, plain, on_link, style=style, value=1 if lead else 0, options=opts^)
    node.name = role
    var nodes = List[Node]()
    nodes.append(node^)
    return View(nodes^)


def runs_of(node: Node) -> List[Run]:
    """A PARAGRAPH node's runs, back from its options."""
    var out = List[Run]()
    var k = 0
    while k + RUN_FIELDS <= len(node.options):
        var f = node.options[k]
        out.append(Run(node.options[k + 3], "b" in f, "i" in f, "c" in f, node.options[k + 2], node.options[k + 1]))
        k += RUN_FIELDS
    return out^


def link_href(node: Node, index: Int) -> String:
    """The href of run `index` ("" if it isn't a link): what a host puts in event.text."""
    var k = index * RUN_FIELDS
    if index < 0 or k + RUN_FIELDS > len(node.options):
        return ""
    return node.options[k + 2]


# ---------- GTK: Pango markup ----------

def escape_markup(text: String) -> String:
    """Text safe inside Pango markup (and XML): & < > " ' as entities, so words that look like markup stay words."""
    var out = String("")
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        var c = b[i]
        var rep = String("")
        if c == 38:
            rep = "&amp;"
        elif c == 60:
            rep = "&lt;"
        elif c == 62:
            rep = "&gt;"
        elif c == 34:
            rep = "&quot;"
        elif c == 39:
            rep = "&#39;"
        else:
            continue
        out += String(text[byte = start : i]) + rep
        start = i + 1
    out += String(text[byte = start : len(b)])
    return out^


def _hex2(v: Int) -> String:
    comptime digits = "0123456789abcdef"
    return String(digits[byte = (v >> 4) & 15]) + String(digits[byte = v & 15])


def _colour(c: UInt32) -> String:
    return "#" + _hex2(Int(c & 255)) + _hex2(Int((c >> 8) & 255)) + _hex2(Int((c >> 16) & 255))


def _alpha(c: UInt32) -> Int:
    """The colour's alpha as a percentage (Pango's fgalpha / bgalpha)."""
    return (Int((c >> 24) & 255) * 100 + 127) // 255


def _size(v: Float64) -> String:
    var tenths = Int(v * 10 + 0.5)
    return String(tenths // 10) + ("." + String(tenths % 10) if tenths % 10 != 0 else "") + "px"


def run_attributes(run: Run, look: Look, paragraph_role: String) -> String:
    """The Pango span attributes for a run: its role's type where the look gives one (family, size in px, weight, ink, a
    fill behind it), then its flags (bold, italic, mono, a link's underline). "" when it looks like the paragraph."""
    var attrs = String("")
    var family = String("")
    var size = Float64(0)
    var weight = 0
    if run.role != "" and run.role != paragraph_role:
        var k = look.surface(run.role)
        if k >= 0:
            ref s = look.surfaces[k]
            family = s.font
            size = s.font_size
            weight = s.font_weight
            if s.ink != 0:
                attrs += " foreground=\"" + _colour(s.ink) + "\"" + (" fgalpha=\"" + String(_alpha(s.ink)) + "%\"" if _alpha(s.ink) < 100 else "")
            if s.fill != 0:
                attrs += " background=\"" + _colour(s.fill) + "\"" + (" bgalpha=\"" + String(max(_alpha(s.fill), 1)) + "%\"" if _alpha(s.fill) < 100 else "")
            if s.tracking != 0:
                attrs += " letter_spacing=\"" + String(Int(s.tracking * 1024)) + "\""
    if run.code and family == "":
        family = look.type.mono if look.type.mono != "" else String("monospace")
    if family != "" or size > 0:
        attrs += " font_desc=\"" + escape_markup(family + (" " if family != "" and size > 0 else "") + (_size(size) if size > 0 else "")) + "\""
    if weight > 0:
        attrs += " weight=\"" + String(weight) + "\""
    elif run.bold:
        attrs += " weight=\"bold\""
    if run.italic:
        attrs += " style=\"italic\""
    if run.href != "":
        attrs += " underline=\"single\""
    return attrs^


def pango_markup(node: Node, look: Look) -> String:
    """A PARAGRAPH node as Pango markup: each run its span (escaped), a link inside <a href="<index>"> (GTK's
    activate-link hands the index back; the host looks the href up)."""
    var out = String("")
    var runs = runs_of(node)
    for k in range(len(runs)):
        ref r = runs[k]
        var attrs = run_attributes(r, look, node.name)
        var words = escape_markup(css_breaks(r.text))  # (the browser's line breaks, D-548)
        if attrs != "":
            words = "<span" + attrs + ">" + words + "</span>"
        if r.href != "":
            words = "<a href=\"" + String(k) + "\">" + words + "</a>"
        out += words
    return out^
