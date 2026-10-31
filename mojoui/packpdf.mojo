# mojoui.packpdf: a pack's pages as a PDF (goal 41 M10), the model half of mojoui.pack (no omxcore, so it tests with a plain
# `mojo run`). A Pack is a title and pages of generic blocks (facts, words, a table, a PDF page with boxes marked, a video
# frame with boxes marked, a picture); write_pack_pdf hands its JSON to mojoui/pack_pdf.py, which assembles the HTML and
# prints it with Playwright's Chromium (PyMuPDF draws PDF pages, ffmpeg takes frames, Pillow marks the boxes).
#
#   var p = Pack("Shipment 2417", "answer · damaged pallets whose BOL says no exceptions")
#   p.page("Evidence"); p.facts([("Shipment", "2417")]); p.video_frame("dock.mp4", 5.33, [Box(0, 270, 132, 74)], "frame 160")
#   p.page("Document"); p.pdf_page("bol/BOL-2417.pdf", 0, [Box(54, 320, 26, 10)], "Exceptions reads None")
#   write_pack_pdf(p, "pack/2417.pdf")          # blocks: run it in a job (mojoui.pack.PackJob) from an app
#
# Its Python: $MOJOUI_PYTHON, else python3 on the PATH; pack_pdf.py's folder: $MOJOUI_PY, else this source's.

from std.ffi import external_call, c_int
from std.os import getenv
from std.reflection import source_location
from mojoui.json import json_string
from mojoui.pdfsource import Box
from mojoui.texttable import fixed
from mojoui.shared import environment


def _quote(s: String) -> String:
    var out = String("'")
    for c in s.codepoint_slices():
        if c == "'":
            out += "'\\''"
        else:
            out += c
    return out + "'"


def _boxes(boxes: List[Box]) -> String:
    var out = String("[")
    for i in range(len(boxes)):
        ref b = boxes[i]
        out += ("," if i > 0 else "") + "[" + fixed(b.x, 3) + "," + fixed(b.y, 3) + "," + fixed(b.w, 3) + "," + fixed(b.h, 3) + "]"
    return out + "]"


struct Pack(Copyable, Movable):
    """One item's PDF: a title and subtitle on every page, pages of blocks (JSON objects, as pack_pdf.py reads them)."""

    var title: String
    var subtitle: String
    var footer: String
    var colours: List[String]  # accent, ink, paper, muted, line ("" each: pack_pdf.py's)
    var headings: List[String]
    var blocks: List[List[String]]  # per page, its blocks' JSON

    def __init__(out self, title: String, subtitle: String = "", footer: String = ""):
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.colours = ["", "", "", "", ""]
        self.headings = List[String]()
        self.blocks = List[List[String]]()

    def pages(self) -> Int:
        return len(self.headings)

    def colour(mut self, accent: String, ink: String = "", paper: String = "", muted: String = "", line: String = ""):
        """The pack's colours as #rrggbb (the app's theme: its accent marks the boxes)."""
        self.colours = [accent, ink, paper, muted, line]

    def page(mut self, heading: String = ""):
        """Starts a page (the blocks after it go on it)."""
        self.headings.append(heading)
        self.blocks.append(List[String]())

    def _add(mut self, json: String):
        if len(self.headings) == 0:
            self.page()
        self.blocks[len(self.blocks) - 1].append(json)

    def facts(mut self, items: List[Tuple[String, String]]):
        var s = String('{"kind":"facts","items":[')
        for i in range(len(items)):
            s += ("," if i > 0 else "") + "[" + json_string(items[i][0]) + "," + json_string(items[i][1]) + "]"
        self._add(s + "]}")

    def text(mut self, words: String):
        self._add('{"kind":"text","text":' + json_string(words) + "}")

    def table(mut self, columns: List[String], rows: List[List[String]], caption: String = ""):
        var s = String('{"kind":"table","caption":') + json_string(caption) + ',"columns":['
        for i in range(len(columns)):
            s += ("," if i > 0 else "") + json_string(columns[i])
        s += '],"rows":['
        for r in range(len(rows)):
            s += ("," if r > 0 else "") + "["
            for c in range(len(rows[r])):
                s += ("," if c > 0 else "") + json_string(rows[r][c])
            s += "]"
        self._add(s + "]}")

    def pdf_page(mut self, path: String, page: Int, boxes: List[Box], caption: String = ""):
        """A PDF's page as a picture, `boxes` (page points) marked in the accent."""
        self._add('{"kind":"pdf_page","path":' + json_string(path) + ',"page":' + String(page) + ',"boxes":' + _boxes(boxes)
                  + ',"caption":' + json_string(caption) + "}")

    def video_frame(mut self, path: String, t: Float64, boxes: List[Box], caption: String = ""):
        """A video's frame at `t` seconds as a picture, `boxes` (the frame's pixels) marked in the accent."""
        self._add('{"kind":"video_frame","path":' + json_string(path) + ',"t":' + fixed(t, 4) + ',"boxes":' + _boxes(boxes)
                  + ',"caption":' + json_string(caption) + "}")

    def image(mut self, path: String, caption: String = ""):
        self._add('{"kind":"image","path":' + json_string(path) + ',"caption":' + json_string(caption) + "}")

    def json(self) -> String:
        var names: List[String] = ["accent", "ink", "paper", "muted", "line"]
        var s = String("{") + '"title":' + json_string(self.title) + ',"subtitle":' + json_string(self.subtitle) + ',"footer":' + json_string(self.footer)
        for i in range(len(names)):
            if i < len(self.colours) and self.colours[i] != "":
                s += "," + json_string(names[i]) + ":" + json_string(self.colours[i])
        s += ',"pages":['
        for p in range(len(self.headings)):
            s += ("," if p > 0 else "") + '{"heading":' + json_string(self.headings[p]) + ',"blocks":[' + ",".join(self.blocks[p]) + "]}"
        return s + "]}"


def _backend() -> String:
    var folder = getenv("MOJOUI_PY", "")
    if folder.byte_length() == 0:
        var f = String(source_location().file_name())
        var slash = f.rfind("/")
        folder = String(f[byte = 0:slash]) if slash >= 0 else String(".")
    return folder + "/pack_pdf.py"


def write_pack_pdf(pack: Pack, path: String) raises:
    """The pack as a PDF at `path` (blocks until it's written: a job's body, or a tool's)."""
    var spec = path + ".json"
    with open(spec, "w") as f:
        f.write(pack.json())
    var py = environment("MOJOUI_PYTHON", "python3")
    var cmd = _quote(py) + " " + _quote(_backend()) + " " + _quote(spec) + " " + _quote(path) + " > " + _quote(path + ".log") + " 2>&1"
    var c = cmd
    var rc = external_call["system", c_int](c.as_c_string_span())
    _ = external_call["unlink", c_int](spec.as_c_string_span())
    if rc != 0:
        var said = String("")
        try:
            with open(path + ".log", "r") as f:
                said = f.read()
        except:
            pass
        raise Error("the pack's PDF failed (" + path + "): " + String(said[byte = max(said.byte_length() - 400, 0) :]))
    var log = path + ".log"
    _ = external_call["unlink", c_int](log.as_c_string_span())
