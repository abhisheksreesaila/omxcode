# mojoui.pdfsource: a PDF's pages as pictures (goal 41 M7). A generic component: a document card shows them, an OCR model
# reads them, and any box on a page converts between the page's points and the picture's pixels.
#
#   var pdf = PdfSource("INV-2417.pdf")            # raises (a clear message) when the file is missing or isn't a PDF
#   pdf.pages, pdf.size(0)                          # page count; a page's width and height in points (1/72 inch)
#   var page = pdf.render(0, 200)                   # PdfPage: RGBA pixels (as Picture and VideoSource give them) at 200 dpi
#   page.to_pixels(Box(x, y, w, h))                 # a box in page points → the picture's pixels; page.to_points(...) back
#   pdf.text_words(0)                               # the page's own text layer as words (points): for checks, never for OCR
#
# How: PyMuPDF (pymupdf, MuPDF underneath; in the default and models environments) through Mojo's Python interop. The
# document is opened per call and nothing Python is kept in the struct, so a PdfSource can move to a job's thread; every
# call takes the Python lock through mojoui.pygil, so it works there too.

from std.python import Python, PythonObject
from mojoui.pygil import python_enter, python_exit

comptime POINTS_PER_INCH = 72.0


@fieldwise_init
struct Box(Copyable, Movable, ImplicitlyCopyable):
    """x, y: top-left; w, h. Its unit is the caller's (page points or picture pixels)."""

    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64

    def right(self) -> Float64:
        return self.x + self.w

    def bottom(self) -> Float64:
        return self.y + self.h

    def cx(self) -> Float64:
        return self.x + self.w / 2

    def cy(self) -> Float64:
        return self.y + self.h / 2

    def union(self, o: Box) -> Box:
        var x0 = min(self.x, o.x)
        var y0 = min(self.y, o.y)
        return Box(x0, y0, max(self.right(), o.right()) - x0, max(self.bottom(), o.bottom()) - y0)

    def iou(self, o: Box) -> Float64:
        var ix = max(0.0, min(self.right(), o.right()) - max(self.x, o.x))
        var iy = max(0.0, min(self.bottom(), o.bottom()) - max(self.y, o.y))
        var u = self.w * self.h + o.w * o.h - ix * iy
        return ix * iy / u if u > 0 else 0.0


struct PdfPage(Movable):
    """One page drawn as a picture: RGBA pixels (R in the low byte, opaque), `scale` pixels per point."""

    var page: Int
    var dpi: Int
    var width: Int  # pixels
    var height: Int
    var points_w: Float64  # the page's size in points
    var points_h: Float64
    var scale: Float64  # pixels per point = dpi / 72
    var pixels: List[UInt32]

    def __init__(out self):
        self.page = -1
        self.dpi = 0
        self.width = 0
        self.height = 0
        self.points_w = 0
        self.points_h = 0
        self.scale = 1
        self.pixels = List[UInt32]()

    def copy(self) -> PdfPage:
        var out = PdfPage()
        out.page = self.page
        out.dpi = self.dpi
        out.width = self.width
        out.height = self.height
        out.points_w = self.points_w
        out.points_h = self.points_h
        out.scale = self.scale
        out.pixels = self.pixels.copy()
        return out^

    def to_pixels(self, b: Box) -> Box:
        return Box(b.x * self.scale, b.y * self.scale, b.w * self.scale, b.h * self.scale)

    def to_points(self, b: Box) -> Box:
        return Box(b.x / self.scale, b.y / self.scale, b.w / self.scale, b.h / self.scale)


@fieldwise_init
struct PageWord(Copyable, Movable, ImplicitlyCopyable):
    """A word of a page's text layer and its box in points."""

    var text: String
    var box: Box


def _open(pymupdf: PythonObject, path: String) raises -> PythonObject:
    var os = Python.import_module("os")
    if not Bool(py=os.path.isfile(path)):
        raise Error("PdfSource: no file " + path)
    try:
        return pymupdf.open(path)
    except e:
        raise Error("PdfSource: cannot open " + path + " as a PDF (" + String(e) + ")")


def _sizes(path: String) raises -> List[Float64]:
    var pymupdf = Python.import_module("pymupdf")
    var doc = _open(pymupdf, path)
    var out = List[Float64]()
    var n = Int(py=doc.page_count)
    for i in range(n):
        var r = doc[i].rect
        out.append(Float64(py=r.width))
        out.append(Float64(py=r.height))
    doc.close()
    return out^


def _render(path: String, page: Int, dpi: Int, mut out: PdfPage) raises:
    var pymupdf = Python.import_module("pymupdf")
    var doc = _open(pymupdf, path)
    var pg = doc[page]
    var pix = pg.get_pixmap(dpi=dpi, alpha=False)
    var w = Int(py=pix.width)
    var h = Int(py=pix.height)
    var stride = Int(py=pix.stride)
    var n = Int(py=pix.n)
    var src = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(py=pix.samples_ptr))
    out.pixels = List[UInt32](length=w * h, fill=0)
    var dst = out.pixels.unsafe_ptr()
    for y in range(h):
        var row = src.unsafe_offset(y * stride)
        for x in range(w):
            var p = row.unsafe_offset(x * n)
            var r = UInt32(p[])
            var g = UInt32(p.unsafe_offset(1)[]) if n >= 3 else r
            var b = UInt32(p.unsafe_offset(2)[]) if n >= 3 else r
            dst.unsafe_offset(y * w + x)[] = r | (g << 8) | (b << 16) | (UInt32(255) << 24)
    out.width = w
    out.height = h
    out.points_w = Float64(py=pg.rect.width)
    out.points_h = Float64(py=pg.rect.height)
    doc.close()


def _words(path: String, page: Int) raises -> List[PageWord]:
    var pymupdf = Python.import_module("pymupdf")
    var doc = _open(pymupdf, path)
    var out = List[PageWord]()
    for w in doc[page].get_text("words"):
        var x0 = Float64(py=w[0])
        var y0 = Float64(py=w[1])
        out.append(PageWord(String(py=w[4]), Box(x0, y0, Float64(py=w[2]) - x0, Float64(py=w[3]) - y0)))
    doc.close()
    return out^


struct PdfSource(Copyable, Movable):
    """A PDF file: its page count and page sizes, read once; pages are drawn on demand."""

    var path: String
    var pages: Int
    var sizes: List[Float64]  # width, height per page, in points

    def __init__(out self, path: String) raises:
        self.path = path
        var g = python_enter()
        try:
            self.sizes = _sizes(path)
        except e:
            python_exit(g)
            raise e^
        python_exit(g)
        self.pages = len(self.sizes) // 2

    def size(self, page: Int) -> Tuple[Float64, Float64]:
        if page < 0 or page >= self.pages:
            return (0.0, 0.0)
        return (self.sizes[2 * page], self.sizes[2 * page + 1])

    def render(self, page: Int, dpi: Int = 150) raises -> PdfPage:
        """Page `page` (0-based) at `dpi` dots per inch: an opaque RGBA picture, white where the page is blank."""
        if page < 0 or page >= self.pages:
            raise Error("PdfSource: " + self.path + " has no page " + String(page + 1))
        var out = PdfPage()
        out.page = page
        out.dpi = dpi
        out.scale = Float64(dpi) / POINTS_PER_INCH
        var g = python_enter()
        try:
            _render(self.path, page, dpi, out)
        except e:
            python_exit(g)
            raise e^
        python_exit(g)
        return out^

    def text_words(self, page: Int) raises -> List[PageWord]:
        """The page's text layer, word by word (a digital PDF's own text; a scan has none). For checks and search;
        reading a page's picture is the OCR model's job."""
        var g = python_enter()
        try:
            var out = _words(self.path, page)
            python_exit(g)
            return out^
        except e:
            python_exit(g)
            raise e^
