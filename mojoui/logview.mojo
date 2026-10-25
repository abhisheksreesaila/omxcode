# mojoui.logview: a log that follows its end (the console's Logs tab: a dark pane in the mono, like a terminal). Its lines
# sit in a Scroll pinned to its end: new lines keep it at the bottom, unless the person scrolled up to read (back at the
# end, it follows again). The pane wears the framework role "log" (tag="log").
#
#   LogView(self.lines, height=420).fill()

from mojoui.view import View, Text, VStack, Scroll, START
from mojoui.codeblock import keep_spaces


def LogView(lines: List[String], height: Int = 320, empty: String = "") -> View:
    """`lines` top to bottom, pinned to the last one; `empty`: what the pane says with no lines."""
    var rows: List[View] = []
    for l in lines:
        rows.append(Text(keep_spaces(l) if l != "" else chr(160)))
    if len(rows) == 0 and empty != "":
        rows.append(Text(empty))
    return Scroll(VStack(rows, spacing=0).align(START).fill(), height=height, pinned=True).tag("log")
