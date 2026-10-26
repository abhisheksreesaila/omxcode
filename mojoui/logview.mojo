# mojoui.logview: a log that follows its end (the console's Logs tab: a dark pane in the mono, like a terminal). Its lines
# sit in a Scroll pinned to its end: new lines keep it at the bottom, unless the person scrolled up to read (back at the
# end, it follows again). The pane wears the framework role "log" (tag="log").
#
#   LogView(self.lines, height=420).fill()

from mojoui.view import View, Text, VStack, HStack, Scroll, Icon, Button, Spacer, SUBTLE, START, CENTER
from mojoui.theme import Palette, Surface, Shadow, mix
from mojoui.codeblock import keep_spaces


def LogView(lines: List[String], height: Int = 320, empty: String = "", exact: Bool = False, short: Bool = False) -> View:
    """`lines` top to bottom, pinned to the last one; `empty`: what the pane says with no lines. `height` is the most it
    takes (0: as tall as it's given); `exact`: always that high, a few lines or many (a pane that fills its page, as the
    console's Logs tab); `short`: a few lines' height inside a card, the theme's (role log-short)."""
    var rows: List[View] = []
    for l in lines:
        rows.append(Text(keep_spaces(l) if l != "" else chr(160)))
    if len(rows) == 0 and empty != "":
        rows.append(Text(empty))
    var pane = Scroll(VStack(rows, spacing=0).align(START).fill(), height=0 if short else height, pinned=True).tag("log-short" if short else "log")
    return pane^.height(height) if exact and not short else pane^


# ---------- LogPane (goal 33 M6): a live log with a head, a toggle to hide it, and lines that say what they are ----------
# Add a model's "LIVE LOG" (blade-add.js): a dark pane whose head names it, with Hide log / Show log at its end; each line
# a time in the dim ink and its words, an error's red, a done step's green, a warning's amber (roles log-pane,
# log-pane-head, log-toggle, log-lines, log-time, log-er, log-ok, log-warn; logpane_roles gives a theme them).


comptime LOG_PLAIN = 0
comptime LOG_ERROR = 1  # .er
comptime LOG_OK = 2  # .okl
comptime LOG_WARN = 3  # .wl


@fieldwise_init
struct LogLine(Copyable, Movable):
    var stamp: String  # "21:34:02" ("" for a line the job wrote itself)
    var text: String
    var kind: Int  # LOG_PLAIN … LOG_WARN


def log_role(kind: Int) -> String:
    if kind == LOG_ERROR:
        return "log-er"
    if kind == LOG_OK:
        return "log-ok"
    if kind == LOG_WARN:
        return "log-warn"
    return "log-text"


def log_kind_of(line: String) -> Int:
    """A job's own line: an error's when it says error, fail or traceback (the original's /error|fail|traceback/i)."""
    var low = line.lower()
    return LOG_ERROR if ("error" in low or "fail" in low or "traceback" in low) else LOG_PLAIN


def LogPane(title: String, lines: List[LogLine], open: Bool, on_toggle: Int, height: Int = 320) -> View:
    """The pane: its head (an icon, `title` in small caps, Hide log / Show log sending `on_toggle`), then, while
    `open`, its lines pinned to the end in a Scroll `height` high."""
    var head = HStack(Icon("terminal", 13), Text(title), Spacer(), Button("Hide log" if open else "Show log", on_toggle, SUBTLE).height(20).tag("log-toggle"),
                      spacing=8).align(CENTER).fill().tag("log-pane-head")
    var items: List[View] = [head^]
    if open:
        var rows: List[View] = []
        for l in lines:
            var words: List[View] = []
            if l.stamp != "":
                words.append(Text(l.stamp + chr(160)).tag("log-time"))
            words.append(Text(keep_spaces(l.text) if l.text != "" else chr(160)).tag(log_role(l.kind)).grow())
            rows.append(HStack(words^, spacing=0).align(START).fill())
        var sc = Scroll(VStack(rows^, spacing=0).align(START).fill().tag("log-lines"), height=height, pinned=True).fill().tag("log-scroll")
        items.append(sc^.grow() if height == 0 else sc^)  # (0: as tall as the pane is given)
    return VStack(items^, spacing=0).align(START).tag("log-pane")


def logpane_roles(p: Palette, mono: String, code: UInt32, code_text: UInt32, radius: Int = 12) -> List[Surface]:
    """blade-add.css's .sr: the code surface, `radius` corners, 14 0 0; .srh 500 11px mono .06em in the dim ink, 0 16 8;
    .ltoggle 11px mono, 2 6, 6 corners; .log 12px mono, line height 1.6, 4 16 16; the dim, error, ok and warn inks
    mixed toward the code text as the original's color-mix() does."""
    var dim = mix(code, code_text, 0.45)
    var out = List[Surface]()
    var pane = Surface("log-pane", code, radius, radius, -1, -1, -1, 14, 0, 0, List[Shadow](), 0, 0, 0, -1, "", 0, code_text, 0, 0, 0, 0, 0, False)
    out.append(pane^)
    var head = Surface("log-pane-head", 0, -1, -1, -1, -1, -1, 0, 16, 8, List[Shadow](), 0, 0, 0, -1, mono, 11, dim, 500, 0.66, 0, 0, 0, False)
    out.append(head^)
    var toggle = Surface("log-toggle", 0, 6, 6, -1, -1, -1, 2, 6, 2, List[Shadow](), 0, 0, 0, 1, mono, 11, dim, 400, 0, 0, 0, 0, False)
    out.append(toggle^)
    var body = Surface("log-lines", 0, -1, -1, -1, -1, -1, 4, 16, 16, List[Shadow](), 0, 0, 0, -1, mono, 12, code_text, 0, 0, 19.2, 0, 0, False)
    out.append(body^)
    out.append(Surface("log-scroll", 0, -1, -1, -1, -1, -1, -1, -1, -1, List[Shadow](), 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False))
    var inks: List[UInt32] = [code_text, dim, mix(code_text, p.bad, 0.60), mix(code_text, p.good, 0.60), mix(code_text, p.warn, 0.60)]
    var roles: List[String] = ["log-text", "log-time", "log-er", "log-ok", "log-warn"]
    for k in range(5):
        out.append(Surface(roles[k], 0, -1, -1, -1, -1, -1, -1, -1, -1, List[Shadow](), 0, 0, 0, -1, mono, 12, inks[k], 0, 0, 19.2, 0, 0, False))
    return out^
