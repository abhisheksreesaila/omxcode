# mojoui.documentcard: a PDF as a card on a page (goal 41 M7). A generic component beside mojoui.mediacard's video and
# picture cards, with the same chrome (a title bar to drag, quiet actions, a close button) over one page of the document:
# page through it, zoom (buttons, pinch, wheel) and pan (drag), and `highlight(page, box)` a box given in page points
# (an OCR field, a search hit, a linked row's place), drawn as an accent outline over a light accent wash.
#
#   var doc = DocumentCard("BOL-2417.pdf", msg_base=6000, canvas=300, x=40, y=40, w=420)   # raises when it isn't a PDF
#   doc.render_now()                                 # or, off the UI thread: mojoui.documentjobs.DocumentFeed (doc.wants())
#   update():  if doc.update(event): …               # True when the event was the card's (doc.closed: its close button)
#   view():    doc.view().at(doc.x, doc.y).width(doc.w).height(doc.h)
#   draw():    if canvas == doc.canvas: doc.draw(surface, palette)
#   doc.highlight(0, Box(54, 320, 26, 10))           # shows page 0 with that box marked (and panned into view when zoomed)
#   doc.actions.append(CardAction("Read", "scroll-text", "read", "Read the text (OCR)"))   # up to 3 quiet actions
#
# Drawing: the page is fitted to the canvas (zoom 1), scaled by the zoom about the canvas centre and moved by the pan;
# page_to_canvas() is that transform (page points → canvas pixels), so a test or an overlay can find where a box lands.
# The page picture comes from mojoui.pdfsource; the card only asks for one (wants(): page and dpi) and draws what it has.

from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.draw import rect, with_alpha
from mojoui.files import file_name
from mojoui.mediacard import CardAction, HEAD_H, MAX_ACTIONS
from mojoui.pdfsource import Box, PdfSource, PdfPage
from mojoui.theme import Palette
from mojoui.view import (View, Text, Button, Canvas, HStack, Spacer, Card, ProgressBar, HEADLINE, CAPTION, ICON_ONLY, SUBTLE, CENTER,
                         PAN, ZOOM, DOUBLE, KEY)

comptime OBJ_DOCUMENT = 5  # (after mediacard's OBJ_VIDEO = 3, OBJ_IMAGE = 4: one numbering for what sits on a sheet)
comptime DOCUMENT_TYPES = ".pdf"
comptime DOC_PREV = 0  # a card's messages: msg_base + …
comptime DOC_NEXT = 1
comptime DOC_ZOOM_OUT = 2
comptime DOC_ZOOM_IN = 3
comptime DOC_FIT = 4
comptime DOC_CLOSE = 5
comptime DOC_GESTURE = 6
comptime DOC_ACTION = 7  # 7, 8, 9: its quiet actions
comptime DOC_MESSAGES = 10
comptime ZOOM_MIN = 1.0
comptime ZOOM_MAX = 6.0
comptime ZOOM_STEP = 1.25
comptime DOC_CHROME_H = 64  # the title bar, the gap, the padding (as a still's card)
comptime DOC_CHROME_W = 28


def is_document_file(path: String) -> Bool:
    var name = file_name(path).lower()
    return name.endswith(".pdf")


@fieldwise_init
struct Highlight(Copyable, Movable, ImplicitlyCopyable):
    """A marked box on a page, in page points."""

    var page: Int
    var box: Box


struct DocumentCard(Movable):
    var path: String
    var pdf: PdfSource
    var page: Int  # the page shown (0-based)
    var zoom: Float64  # 1 = the whole page fits
    var pan_x: Float64  # canvas points the page is moved by
    var pan_y: Float64
    var shown: PdfPage  # the page's picture as drawn now (shown.page may lag `page` until the new one is rendered)
    var marks: List[Highlight]
    var msg_base: Int
    var canvas: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var version: Int  # the canvas's version: bumped whenever what it draws changes
    var actions: List[CardAction]
    var status: String  # work running for the card ("Reading"), shown instead of its actions
    var progress: Int
    var closed: Bool  # the last update() was its close button
    var acted: Int  # the last update() was its action k (else -1)
    var last_fit: Float64  # canvas pixels per page point at zoom 1, from the last draw (0: not drawn yet)
    var last_size: Tuple[Int, Int]  # the canvas's pixels at the last draw
    var last_scale: Float64  # its pixels per point

    def __init__(out self, path: String, msg_base: Int, canvas: Int, x: Int = 0, y: Int = 0, w: Int = 420) raises:
        self.path = path
        self.pdf = PdfSource(path)
        if self.pdf.pages == 0:
            raise Error("DocumentCard: " + path + " has no pages")
        self.page = 0
        self.zoom = 1.0
        self.pan_x = 0
        self.pan_y = 0
        self.shown = PdfPage()
        self.marks = List[Highlight]()
        self.msg_base = msg_base
        self.canvas = canvas
        self.x = x
        self.y = y
        self.w = w
        self.h = 0
        self.version = 0
        self.actions = List[CardAction]()
        self.status = ""
        self.progress = -1
        self.closed = False
        self.acted = -1
        self.last_fit = 0
        self.last_size = (0, 0)
        self.last_scale = 1
        self.h = self.height_for(w)

    def open(mut self, path: String) raises:
        """Shows another document in the same card (a folder's next file): page 1, fitted, nothing marked; its picture is
        asked for again (wants())."""
        var pdf = PdfSource(path)
        if pdf.pages == 0:
            raise Error("DocumentCard: " + path + " has no pages")
        self.path = path
        self.pdf = pdf^
        self.page = 0
        self.zoom = 1.0
        self.pan_x = 0
        self.pan_y = 0
        self.shown = PdfPage()
        self.marks = List[Highlight]()
        self.version += 1

    # ---------- what it is ----------

    def title(self) -> String:
        return file_name(self.path)

    def pages(self) -> Int:
        return self.pdf.pages

    def facts(self) -> String:
        var s = self.pdf.size(self.page)
        return String(self.pdf.pages) + (" page" if self.pdf.pages == 1 else " pages") + " · " + String(Int(s[0] + 0.5)) + "×" + String(Int(s[1] + 0.5)) + " pt"

    def height_for(self, width: Int) -> Int:
        var s = self.pdf.size(self.page)
        var inner = Float64(max(width - DOC_CHROME_W, 1)) * s[1] / max(s[0], 1.0)
        return Int(inner) + DOC_CHROME_H

    def describe(self) -> String:
        """For an agent: where the card is in its document and what is marked."""
        var out = self.title() + ": page " + String(self.page + 1) + " of " + String(self.pdf.pages) + ", zoom " + String(Int(self.zoom * 100 + 0.5)) + "%"
        var n = 0
        for m in self.marks:
            if m.page == self.page:
                n += 1
        if n > 0:
            out += ", " + String(n) + (" box highlighted" if n == 1 else " boxes highlighted")
        return out

    # ---------- the page picture ----------

    def wants(self) -> Tuple[Int, Int]:
        """The page and dpi the card needs drawn ((-1, 0): what it has will do). The dpi follows the canvas and the zoom
        (one picture pixel per canvas pixel, 72–300 dpi, in steps of 24 so small changes don't ask again)."""
        var dpi = 144
        if self.last_fit > 0:
            dpi = Int(self.last_fit * self.zoom * 72.0 + 23.0) // 24 * 24
            dpi = min(max(dpi, 72), 300)
        if self.shown.page != self.page or self.shown.dpi < dpi * 3 // 4 or self.shown.dpi > dpi * 2:
            return (self.page, dpi)
        return (-1, 0)

    def put_page(mut self, var page: PdfPage):
        """A rendered page arrives (from a job or render_now()); kept if it is the page shown."""
        if page.page == self.page:
            self.shown = page^
            self.version += 1

    def render_now(mut self) raises:
        """Draws the page it wants here, on the caller's thread (tests, tools; an app uses a job)."""
        var want = self.wants()
        if want[0] >= 0:
            self.put_page(self.pdf.render(want[0], want[1]))

    # ---------- moving around ----------

    def go(mut self, page: Int):
        var p = min(max(page, 0), self.pdf.pages - 1)
        if p != self.page:
            self.page = p
            self.pan_x = 0
            self.pan_y = 0
            self.version += 1

    def set_zoom(mut self, zoom: Float64, about_x: Float64 = -1, about_y: Float64 = -1):
        """Zoom (1 = fit) about a canvas point in points (default: the canvas centre), so that point stays put."""
        var z = min(max(zoom, ZOOM_MIN), ZOOM_MAX)
        if z == self.zoom:
            return
        var cw = Float64(self.last_size[0]) / self.last_scale
        var ch = Float64(self.last_size[1]) / self.last_scale
        if about_x >= 0 and cw > 0:
            # the point under (about_x, about_y) relative to the centre moves by the zoom ratio: pan keeps it still
            var rx = about_x - cw / 2 - self.pan_x
            var ry = about_y - ch / 2 - self.pan_y
            self.pan_x -= rx * (z / self.zoom - 1)
            self.pan_y -= ry * (z / self.zoom - 1)
        else:
            self.pan_x *= z / self.zoom
            self.pan_y *= z / self.zoom
        self.zoom = z
        if z == 1.0:
            self.pan_x = 0
            self.pan_y = 0
        self._clamp()
        self.version += 1

    def pan(mut self, dx: Float64, dy: Float64):
        self.pan_x += dx
        self.pan_y += dy
        self._clamp()
        self.version += 1

    def _clamp(mut self):
        """Keeps at least half the canvas on the page: the page can't be dragged away."""
        if self.last_fit <= 0:
            return
        var s = self.pdf.size(self.page)
        var pw = s[0] * self.last_fit * self.zoom / self.last_scale  # the page in canvas points
        var ph = s[1] * self.last_fit * self.zoom / self.last_scale
        var cw = Float64(self.last_size[0]) / self.last_scale
        var ch = Float64(self.last_size[1]) / self.last_scale
        var mx = max((pw - cw) / 2 + cw / 2, 0.0)
        var my = max((ph - ch) / 2 + ch / 2, 0.0)
        self.pan_x = min(max(self.pan_x, -mx), mx)
        self.pan_y = min(max(self.pan_y, -my), my)

    def highlight(mut self, page: Int, box: Box):
        """Marks `box` (page points) on `page`, shows that page, and pans so the box's centre is in view."""
        self.marks.append(Highlight(page, box))
        self.go(page)
        if self.last_fit > 0 and self.zoom > 1.0:
            var s = self.pdf.size(self.page)
            var k = self.last_fit * self.zoom / self.last_scale  # canvas points per page point
            self.pan_x = (s[0] / 2 - box.cx()) * k
            self.pan_y = (s[1] / 2 - box.cy()) * k
            self._clamp()
        self.version += 1

    def clear_highlights(mut self):
        self.marks = List[Highlight]()
        self.version += 1

    def highlights_on_page(self) -> List[Box]:
        var out = List[Box]()
        for m in self.marks:
            if m.page == self.page:
                out.append(m.box)
        return out^

    # ---------- events ----------

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + DOC_MESSAGES

    def update(mut self, event: Event) -> Bool:
        self.closed = False
        self.acted = -1
        if not self.owns(event.message):
            return False
        var m = event.message - self.msg_base
        if m == DOC_PREV:
            self.go(self.page - 1)
        elif m == DOC_NEXT:
            self.go(self.page + 1)
        elif m == DOC_ZOOM_IN:
            self.set_zoom(self.zoom * ZOOM_STEP)
        elif m == DOC_ZOOM_OUT:
            self.set_zoom(self.zoom / ZOOM_STEP)
        elif m == DOC_FIT:
            self.set_zoom(1.0)
        elif m == DOC_CLOSE:
            self.closed = True
        elif m == DOC_GESTURE:
            if event.number == PAN:
                self.pan(event.dx, event.dy)
            elif event.number == ZOOM:
                self.set_zoom(self.zoom * event.zoom, event.x, event.y)
            elif event.number == DOUBLE:
                self.set_zoom(1.0 if self.zoom > 1.0 else 2.0, event.x, event.y)
            elif event.number == KEY:
                if event.text == "PageDown" or event.text == "ArrowRight":
                    self.go(self.page + 1)
                elif event.text == "PageUp" or event.text == "ArrowLeft":
                    self.go(self.page - 1)
                elif event.text == "+" or event.text == "=":
                    self.set_zoom(self.zoom * ZOOM_STEP)
                elif event.text == "-":
                    self.set_zoom(self.zoom / ZOOM_STEP)
                elif event.text == "0":
                    self.set_zoom(1.0)
        elif m >= DOC_ACTION and m - DOC_ACTION < len(self.actions):
            self.acted = m - DOC_ACTION
        return True

    # ---------- drawing ----------

    def page_to_canvas(self, box: Box, width: Int, height: Int, scale: Float64) -> Box:
        """Where a box in page points lands on a canvas of width × height pixels (scale pixels per point)."""
        var s = self.pdf.size(self.page)
        var fit = min(Float64(width) / max(s[0], 1.0), Float64(height) / max(s[1], 1.0))
        var k = fit * self.zoom
        var ox = (Float64(width) - s[0] * k) / 2 + self.pan_x * scale
        var oy = (Float64(height) - s[1] * k) / 2 + self.pan_y * scale
        return Box(ox + box.x * k, oy + box.y * k, box.w * k, box.h * k)

    def draw(mut self, mut s: Surface, pal: Palette):
        s.fill(pal.card)
        var size = self.pdf.size(self.page)
        self.last_fit = min(Float64(s.width) / max(size[0], 1.0), Float64(s.height) / max(size[1], 1.0))
        self.last_size = (s.width, s.height)
        self.last_scale = s.scale
        var pg = self.page_to_canvas(Box(0, 0, size[0], size[1]), s.width, s.height, s.scale)
        rect(s, pg.x - 1, pg.y - 1, pg.w + 2, pg.h + 2, pal.line)
        if self.shown.page != self.page or len(self.shown.pixels) != self.shown.width * self.shown.height or self.shown.width == 0:
            rect(s, pg.x, pg.y, pg.w, pg.h, pal.raised)  # (its picture is on its way)
        else:
            _blit(s, self.shown, pg)
        var pad = 2.0 * s.scale
        for b in self.highlights_on_page():
            var r = self.page_to_canvas(b, s.width, s.height, s.scale)
            var x0 = r.x - pad
            var y0 = r.y - pad
            var w = r.w + 2 * pad
            var h = r.h + 2 * pad
            rect(s, x0, y0, w, h, with_alpha(pal.accent, 0.20), 2 * s.scale)
            var t = max(1.5 * s.scale, 1.0)
            rect(s, x0, y0, w, t, pal.accent)
            rect(s, x0, y0 + h - t, w, t, pal.accent)
            rect(s, x0, y0, t, h, pal.accent)
            rect(s, x0 + w - t, y0, t, h, pal.accent)

    # ---------- view ----------

    def view(self) -> View:
        var parts = List[View]()
        parts.append(Text(self.title(), HEADLINE).tag("doc-title").tooltip(self.facts()))
        parts.append(Spacer())
        if self.status != "":
            parts.append(Text(self.status + (" · " + String(self.progress) + "%" if self.progress >= 0 else String("")), CAPTION).tag("doc-status"))
            if self.progress >= 0:
                parts.append(ProgressBar(self.progress).width(96).label(self.status))
        else:
            for i in range(min(len(self.actions), MAX_ACTIONS)):
                ref a = self.actions[i]
                parts.append(Button(a.label, self.msg_base + DOC_ACTION + i, SUBTLE, icon=a.icon).tag(a.tag).tooltip(a.tip))
        for v in self.controls():
            parts.append(v.copy())
        parts.append(Button("Remove", self.msg_base + DOC_CLOSE, ICON_ONLY, icon="close").tooltip("Close " + self.title()))
        var head = HStack(parts^, spacing=8).fill().align(CENTER).height(HEAD_H)
        return Card(head^, self.body(), spacing=4)

    def controls(self) -> List[View]:
        """Its page and zoom buttons (a card that wraps this one, like mojoui.documentset's, puts them in its own bar)."""
        var parts = List[View]()
        if self.pdf.pages > 1:
            parts.append(Button("Previous page", self.msg_base + DOC_PREV, ICON_ONLY, icon="back").tag("doc-prev").tooltip("Previous page"))
            parts.append(Text(String(self.page + 1) + " / " + String(self.pdf.pages), CAPTION).tag("doc-page"))
            parts.append(Button("Next page", self.msg_base + DOC_NEXT, ICON_ONLY, icon="chevron-right").tag("doc-next").tooltip("Next page"))
        parts.append(Button("−", self.msg_base + DOC_ZOOM_OUT, SUBTLE).tag("doc-zoom-out").tooltip("Zoom out"))
        parts.append(Button("+", self.msg_base + DOC_ZOOM_IN, SUBTLE).tag("doc-zoom-in").tooltip("Zoom in"))
        parts.append(Button("Fit", self.msg_base + DOC_FIT, SUBTLE).tag("doc-fit").tooltip("Fit the page"))
        return parts^

    def body(self) -> View:
        """The page itself: a canvas that pans, zooms and pages."""
        var body = Canvas(self.canvas, self.version, on_gesture=self.msg_base + DOC_GESTURE, keys=True).fill().grow().tag("document")
        return body^.label(self.describe())


def _blit(mut s: Surface, page: PdfPage, dst: Box):
    """The page's picture into `dst` (canvas pixels; may hang off the canvas), bilinear."""
    var x0 = max(Int(dst.x), 0)
    var y0 = max(Int(dst.y), 0)
    var x1 = min(Int(dst.right() + 0.999), s.width)
    var y1 = min(Int(dst.bottom() + 0.999), s.height)
    if x1 <= x0 or y1 <= y0:
        return
    var sx = Float64(page.width) / dst.w
    var sy = Float64(page.height) / dst.h
    var out = s.pixels()
    var src = page.pixels.unsafe_ptr()
    var pw = page.width
    var ph = page.height
    for y in range(y0, y1):
        var fy = min(max((Float64(y) + 0.5 - dst.y) * sy - 0.5, 0.0), Float64(ph - 1))
        var iy = Int(fy)
        var iy2 = min(iy + 1, ph - 1)
        var wy = fy - Float64(iy)
        for x in range(x0, x1):
            var fx = min(max((Float64(x) + 0.5 - dst.x) * sx - 0.5, 0.0), Float64(pw - 1))
            var ix = Int(fx)
            var ix2 = min(ix + 1, pw - 1)
            var wx = fx - Float64(ix)
            var a = src.unsafe_offset(iy * pw + ix)[]
            var b = src.unsafe_offset(iy * pw + ix2)[]
            var c = src.unsafe_offset(iy2 * pw + ix)[]
            var d = src.unsafe_offset(iy2 * pw + ix2)[]
            var px = UInt32(255) << 24
            for ch in range(3):
                var sh = UInt32(ch * 8)
                var va = Float64(Int((a >> sh) & 255))
                var vb = Float64(Int((b >> sh) & 255))
                var vc = Float64(Int((c >> sh) & 255))
                var vd = Float64(Int((d >> sh) & 255))
                var v = (va * (1 - wx) + vb * wx) * (1 - wy) + (vc * (1 - wx) + vd * wx) * wy
                px |= UInt32(Int(v + 0.5)) << sh
            out.unsafe_offset(y * s.width + x)[] = px
