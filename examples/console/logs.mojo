# The model page's Logs tab (blade-logs.js): one model's server log in a dark mono pane that follows its end. Pause,
# filter, copy. GET /admin/models/<name>/log every 2 s while open and following (the daemon sends the last ~8 KB).

from mojoui.view import View, Text, Button, TextField, VStack, HStack, Spacer, CENTER, START
from mojoui.logview import LogView
from mojoui.pagekit import MonoLine, FlatButton, BareCard, CardFoot, SmallButton
from msgs import LOG_FOLLOW, LOG_COPY, LOG_FILTER

comptime MAX_LINES = 2000


struct Logs(Copyable, Movable):
    var text: String
    var truncated: Bool
    var loaded: Bool
    var error: String
    var follow: Bool
    var needle: String

    def __init__(out self):
        self.text = ""
        self.truncated = False
        self.loaded = False
        self.error = ""
        self.follow = True
        self.needle = ""

    def lines(self) -> Tuple[List[String], Int]:
        """visibleLines: blank lines dropped, a cut first line dropped, the last MAX_LINES kept, then the filter; the
        total counts lines before the filter."""
        var all = List[String]()
        var first = True
        for l in self.text.split("\n"):
            var line = String(l)
            if first and self.truncated:
                first = False
                continue
            first = False
            if String(line.strip()) != "":
                all.append(line)
        if len(all) > MAX_LINES:
            var tail = List[String]()
            for k in range(len(all) - MAX_LINES, len(all)):
                tail.append(all[k])
            all = tail^
        var total = len(all)
        var q = String(self.needle.strip()).lower()
        if q == "":
            return (all^, total)
        var out = List[String]()
        for l in all:
            if q in l.lower():
                out.append(l)
        return (out^, total)

    def visible_text(self) -> String:
        var t = self.lines()
        var out = String("")
        for k in range(len(t[0])):
            out += ("\n" if k > 0 else "") + t[0][k]
        return out


def logs_view(lg: Logs, model: String, pane_height: Int, phone: Bool) -> View:
    var t = lg.lines()
    var shown = t[0].copy()
    var total = t[1]
    var count = String("")
    if lg.error == "" and lg.loaded:
        count = (String(len(shown)) + " of " + String(total) + " lines") if String(lg.needle.strip()) != "" else (String(total) + " line" + ("" if total == 1 else "s"))
    var empty = String("Loading…") if not lg.loaded else (lg.error if lg.error != "" else ("No line matches the filter." if total > 0 else "Nothing in this log yet."))
    var head = HStack(MonoLine(model + " · max serve"), Spacer(), SmallButton("Pause" if lg.follow else "Follow", LOG_FOLLOW, "pause" if lg.follow else "play"),
                      SmallButton("Copy", LOG_COPY, "copy"), spacing=8).align(CENTER).fill()
    var bar = HStack(TextField(lg.needle, placeholder="Filter lines", on_change=LOG_FILTER).width(340 if not phone else 270), Spacer(), MonoLine(count),
                     spacing=12).align(CENTER).fill()
    var pane = BareCard([LogView(shown.copy() if lg.error == "" else List[String](), height=pane_height, empty=empty, exact=True).fill(),
                         CardFoot("mxc logs " + model + " -f", tail="the last 8 KB · refreshes every 2 s")]).fill()
    return VStack(head, bar, pane, spacing=12).align(START).padding(10, 18).fill()
