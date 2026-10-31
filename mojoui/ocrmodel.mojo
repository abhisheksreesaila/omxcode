# mojoui.ocrmodel: a learned OCR model in the reader slot (goal 41 M7, D-1102). A generic component: anything with
# `read(pixels, width, height)` that returns words with boxes is a TextReader; OcrModel (docTR) is the first one, and a
# later model (Unlimited-OCR, a model pack) replaces it without changing a caller.
#
#   var ocr = OcrModel()                                    # docTR: db_resnet50 + crnn_vgg16_bn, on the GPU when there is one
#   var words = ocr.read(pixels, width, height)             # List[OcrWord]: text, box in the picture's pixels, confidence
#   var table = read_document(PdfSource("a.pdf"), ocr, 200) # every page drawn at 200 dpi, read: a TextTable in page points
#
# Backend: PyTorch + docTR in this process through Mojo's Python interop (mojoui/ocr_torch.py), as mojoui.visionmodel
# runs OWLv2: the picture is handed over as an address (numpy wraps it, no copy, no file, no socket). The model stays
# loaded in the backend, one per name, for the life of the process; the Mojo side keeps only its name, so an OcrModel
# can be copied into a job and used on its thread (calls take the Python lock through mojoui.pygil).

from std.python import Python, PythonObject
from std.os import getenv
from std.reflection import source_location
from mojoui.pygil import python_enter, python_exit
from mojoui.pdfsource import Box, PdfSource, PdfPage
from mojoui.texttable import TextTable
from mojoui.clock import now_ns

comptime DOCTR = "db_resnet50+crnn_vgg16_bn"


@fieldwise_init
struct OcrWord(Copyable, Movable, ImplicitlyCopyable):
    """A word read off a picture: its text, its box in the picture's pixels, the reader's confidence (0..1)."""

    var text: String
    var box: Box
    var confidence: Float64


trait TextReader(Copyable, Movable):
    """The slot an OCR model fills: words, with boxes in the picture's pixels, from one RGBA picture."""

    def read(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int) raises -> List[OcrWord]:
        ...


def _backend() raises -> PythonObject:
    """mojoui/ocr_torch.py, loaded from its file (never through sys.path). Where: $MOJOUI_PY (a folder) if set, else the
    folder of this source file as the compiler saw it."""
    var sys = Python.import_module("sys")
    if Bool(py=sys.modules.__contains__("mojoui_ocr_torch")):
        return sys.modules["mojoui_ocr_torch"]
    var os = Python.import_module("os")
    var folder = getenv("MOJOUI_PY", "")
    if folder.byte_length() == 0:
        folder = String(py=os.path.dirname(os.path.abspath(source_location().file_name())))
    var path = os.path.join(folder, "ocr_torch.py")
    if not Bool(py=os.path.isfile(path)):
        raise Error("OcrModel: no backend at " + String(py=path) + " (set MOJOUI_PY to the folder of ocr_torch.py)")
    var util = Python.import_module("importlib.util")
    var spec = util.spec_from_file_location("mojoui_ocr_torch", path)
    var mod = util.module_from_spec(spec)
    sys.modules["mojoui_ocr_torch"] = mod
    spec.loader.exec_module(mod)
    mod.READERS = Python.dict()
    return mod


def _reader(name: String, device: String) raises -> PythonObject:
    var mod = _backend()
    var key = PythonObject(name + "@" + device)
    if not Bool(py=mod.READERS.__contains__(key)):
        mod.READERS[key] = mod.Reader(name, device)
    return mod.READERS[key]


def _floats(lst: PythonObject) raises -> List[Float64]:
    var array = Python.import_module("array")
    var a = array.array("d", lst)
    var n = Int(py=Python.import_module("builtins").len(a))
    var out = List[Float64](capacity=n)
    if n == 0:
        return out^
    var p = UnsafePointer[Float64, MutAnyOrigin](unsafe_from_address=Int(py=a.buffer_info()[0]))
    for i in range(n):
        out.append(p.unsafe_offset(i)[])
    return out^


def _read(name: String, device: String, addr: Int, width: Int, height: Int, mut stats: List[Float64]) raises -> List[OcrWord]:
    var r = _reader(name, device)
    var flat = _floats(r.read_address(addr, width, height))
    var texts = r.texts
    var out = List[OcrWord]()
    var k = 0
    while k * 5 + 4 < len(flat):
        var o = k * 5
        out.append(OcrWord(String(py=texts[k]), Box(flat[o], flat[o + 1], flat[o + 2], flat[o + 3]), flat[o + 4]))
        k += 1
    stats[0] = Float64(py=r.load_ms)
    stats[1] = Float64(py=r.model_ms)
    stats[2] = Float64(py=r.vram_mb())
    return out^


struct OcrModel(TextReader):
    """docTR (or another detector+recognizer pair named "<det>+<reco>"), loaded on the first read and kept."""

    var name: String
    var device: String
    var load_ms: Float64  # the model's load (the first read's process only; 0 when it was loaded already)
    var model_ms: Float64  # the last read's model time
    var vram_mb: Float64  # the most GPU memory torch has held so far

    def __init__(out self, name: String = DOCTR, device: String = "cuda"):
        self.name = name
        self.device = device
        self.load_ms = 0
        self.model_ms = 0
        self.vram_mb = 0

    def load(mut self) raises:
        """Loads the model now (else the first read does)."""
        var g = python_enter()
        try:
            var r = _reader(self.name, self.device)
            self.load_ms = Float64(py=r.load_ms)
        except e:
            python_exit(g)
            raise e^
        python_exit(g)

    def read(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int) raises -> List[OcrWord]:
        var stats = List[Float64](length=3, fill=0)
        var g = python_enter()
        var out: List[OcrWord]
        try:
            out = _read(self.name, self.device, Int(pixels), width, height, stats)
        except e:
            python_exit(g)
            raise e^
        python_exit(g)
        self.load_ms = stats[0]
        self.model_ms = stats[1]
        self.vram_mb = stats[2]
        return out^


def _luma(p: UInt32) -> Int:
    return (Int(p & 255) * 54 + Int((p >> 8) & 255) * 183 + Int((p >> 16) & 255) * 19) >> 8


def ink_box(pixels: List[UInt32], width: Int, height: Int, box: Box) -> Box:
    """`box` (pixels) shrunk to the ink inside it: the pixels darker than halfway between the box's lightest and darkest.
    Readers pad their word boxes by a few pixels (docTR: about a third of a short word's height); the ink box is what a
    highlight should hug, whatever the reader. The box itself when it holds no contrast."""
    var x0 = max(Int(box.x), 0)
    var y0 = max(Int(box.y), 0)
    var x1 = min(Int(box.right() + 0.999), width)
    var y1 = min(Int(box.bottom() + 0.999), height)
    if x1 <= x0 or y1 <= y0:
        return box
    var lo = 255
    var hi = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            var l = _luma(pixels[y * width + x])
            lo = min(lo, l)
            hi = max(hi, l)
    if hi - lo < 48:
        return box
    var mid = (lo + hi) // 2
    var bx0 = x1
    var by0 = y1
    var bx1 = x0 - 1
    var by1 = y0 - 1
    for y in range(y0, y1):
        for x in range(x0, x1):
            if _luma(pixels[y * width + x]) < mid:
                bx0 = min(bx0, x)
                by0 = min(by0, y)
                bx1 = max(bx1, x)
                by1 = max(by1, y)
    if bx1 < bx0:
        return box
    return Box(Float64(bx0), Float64(by0), Float64(bx1 - bx0 + 1), Float64(by1 - by0 + 1))


def read_page[R: TextReader](page: PdfPage, mut reader: R, mut into: TextTable, ink: Bool = True) raises -> Int:
    """The page's picture read by `reader`; its words go into `into` with boxes in page points (shrunk to their ink
    unless ink=False). Returns how many."""
    var p = page.pixels.unsafe_ptr()
    var words = reader.read(UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(p)), page.width, page.height)
    _ = len(page.pixels)
    for w in words:
        var b = ink_box(page.pixels, page.width, page.height, w.box) if ink else w.box
        into.add(page.page, w.text, page.to_points(b), w.confidence)
    return len(words)


def read_document[R: TextReader](pdf: PdfSource, mut reader: R, dpi: Int = 200) raises -> TextTable:
    """Every page drawn at `dpi` and read (the picture, never the PDF's text layer): one TextTable in page points."""
    var t0 = now_ns()
    var out = TextTable()
    for p in range(pdf.pages):
        var page = pdf.render(p, dpi)
        _ = read_page(page, reader, out)
    out.seconds = Float64(now_ns() - t0) / 1e9
    return out^
