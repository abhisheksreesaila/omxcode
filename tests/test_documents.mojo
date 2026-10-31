# Goal 41 M7: documents become rows. mojoui.pdfsource (pages → pictures), mojoui.ocrmodel (docTR in process, the reader
# slot), mojoui.texttable (words as rows), mojoui.formfields (label → value by geometry) and mojoui.documentcard.
#   G41_DATA=build/g41/data G41_OUT=build/g41 pixi run -e models mojo run -I . tests/test_documents.mojo
# Prints "pdf: ok", "texttable: ok", "document card: ok", "fields: exact N/M" (scored here only as a summary; check.py
# scores bol_fields.csv against truth.json itself), "funsd recall: X", "documents: ok".
#
# The BOLs are read from their PICTURES (each page drawn at DPI, then OCR); their text layer is used only to check
# pdfsource.text_words. The labels are data: the bill of lading's printed labels, handed to the generic find_fields().
# FUNSD (research use): fetched once into $G41_OUT/funsd (never committed); its first 20 test forms (sorted by name) are
# read and word recall = ground-truth words (lower case, punctuation stripped) found among the OCR's words on the same form.

from std.testing import assert_equal, assert_true, assert_false
from std.os import getenv
from std.collections import Set
from std.python import Python, PythonObject
from mojoui.app import Event
from mojoui.canvas import Surface, rgba
from mojoui.a11y import audit
from mojoui.clock import now_ns
from mojoui.documentcard import DocumentCard, DOC_NEXT, DOC_PREV, DOC_ZOOM_IN, DOC_FIT, DOC_GESTURE, DOC_CLOSE, is_document_file
from mojoui.formfields import FieldLabel, Field, find_fields
from mojoui.ocrmodel import OcrModel, read_document, read_page
from mojoui.pdfsource import Box, PdfSource, PdfPage
from mojoui.picture import Picture
from mojoui.pygil import python_start, python_enter, python_exit
from mojoui.texttable import TextTable, csv_field, csv_split
from mojoui.theme import Palette
from mojoui.view import PAN, ZOOM

comptime DPI = 200
comptime FUNSD_URL = "https://guillaumejaume.github.io/FUNSD/dataset.zip"
comptime FUNSD_FORMS = 20


def bol_labels() -> List[FieldLabel]:
    """The bill of lading's printed labels (data: another form passes its own)."""
    var l = List[FieldLabel]()
    l.append(FieldLabel("shipment_no", "Shipment no."))
    l.append(FieldLabel("date", "Date"))
    l.append(FieldLabel("consignee", "Consignee"))
    l.append(FieldLabel("carrier", "Carrier"))
    l.append(FieldLabel("pallets", "Pallets"))
    l.append(FieldLabel("exceptions", "Exceptions"))
    l.append(FieldLabel("signed_by", "Signed by"))
    return l^


def listdir(folder: String, suffix: String) raises -> List[String]:
    var os = Python.import_module("os")
    var out = List[String]()
    for n in Python.import_module("builtins").sorted(os.listdir(folder)):
        var s = String(py=n)
        if s.endswith(suffix):
            out.append(s)
    return out^


def mkdir(path: String) raises:
    _ = Python.import_module("os").makedirs(path, exist_ok=True)


def f2(v: Float64) -> String:
    var m = Int(v * 100 + (0.5 if v >= 0 else -0.5))
    var a = abs(m)
    var frac = String(a % 100)
    if frac.byte_length() < 2:
        frac = "0" + frac
    return ("-" if m < 0 else "") + String(a // 100) + "." + frac


# ---------- pieces ----------


def pdf_tests(bol: String) raises:
    var pdf = PdfSource(bol)
    assert_equal(pdf.pages, 1)
    var size = pdf.size(0)
    assert_equal(Int(size[0]), 612)
    assert_equal(Int(size[1]), 792)
    var page = pdf.render(0, 144)
    assert_equal(page.width, 1224)
    assert_equal(page.height, 1584)
    assert_equal(len(page.pixels), page.width * page.height)
    assert_equal(page.pixels[5] & 0xFFFFFF, UInt32(0xFFFFFF))  # (the page's white margin, opaque)
    assert_equal(page.pixels[5] >> 24, UInt32(255))
    var b = page.to_pixels(Box(10, 20, 30, 40))
    assert_equal(Int(b.x), 20)
    assert_equal(Int(b.h), 80)
    assert_equal(Int(page.to_points(b).y), 20)
    # the title's ink lands where its text-layer box says (dark pixels inside the box, page points → pixels)
    var words = pdf.text_words(0)
    var title = Box(0, 0, 0, 0)
    for w in words:
        if w.text == "LADING":
            title = w.box
    assert_true(title.w > 0)
    var tp = page.to_pixels(title)
    var dark = 0
    for y in range(Int(tp.y), Int(tp.bottom())):
        for x in range(Int(tp.x), Int(tp.right())):
            if (page.pixels[y * page.width + x] & 0xFF) < 100:
                dark += 1
    assert_true(dark > 200)
    var raised = False
    try:
        _ = PdfSource("build/no-such.pdf")
    except:
        raised = True
    assert_true(raised)
    assert_true(is_document_file("a/B.PDF") and not is_document_file("a.png"))
    print("pdf: ok")


def texttable_tests(folder: String) raises:
    var t = TextTable()
    t.add(0, "Hello", Box(1.5, 2.25, 3, 4), 0.9)
    t.add(1, "a, \"quoted\" word", Box(10, 20, 30, 40), 0.55)
    assert_equal(csv_field("a,b"), "\"a,b\"")
    var f = csv_split("1,\"a, \"\"q\"\"\",3")
    assert_equal(len(f), 3)
    assert_equal(f[1], "a, \"q\"")
    t.write_csv(folder + "/texttable.csv")
    var back = TextTable.read_csv(folder + "/texttable.csv")
    assert_equal(back.rows(), 2)
    assert_equal(back.text[1], "a, \"quoted\" word")
    assert_equal(back.page[1], 1)
    assert_equal(back.x[0], 1.5)
    assert_equal(back.confidence[1], 0.55)
    assert_equal(len(t.on_page(1)), 1)
    assert_equal(t.pages(), 2)
    print("texttable: ok")


def dist(a: UInt32, b: UInt32) -> Int:
    var d = 0
    for k in range(3):
        var sh = UInt32(8 * k)
        d += abs(Int((a >> sh) & 255) - Int((b >> sh) & 255))
    return d


def card_tests(bol: String, words: TextTable, fields: List[Field]) raises:
    var doc = DocumentCard(bol, msg_base=6000, canvas=300, x=0, y=0, w=420)
    assert_true(doc.h > 420)  # (a portrait page)
    doc.render_now()
    assert_equal(doc.shown.page, 0)
    var buf = List[UInt32](length=400 * 520, fill=0)
    var s = Surface(Int(buf.unsafe_ptr()), 400, 520, 1.0)
    var pal = Palette.plain()
    doc.draw(s, pal)
    # the page is fitted: 400 / 612 pt wide (width-bound), centred vertically
    var whole = doc.page_to_canvas(Box(0, 0, 612, 792), 400, 520, 1.0)
    assert_true(abs(whole.w - 400) < 0.5 and abs(whole.h - 792.0 * 400 / 612) < 0.5 and abs(whole.y - (520 - whole.h) / 2) < 0.5)
    # a highlight: an outline in the accent colour exactly around the field's box, drawn on the page
    var exc = Box(0, 0, 0, 0)
    for f in fields:
        if f.name == "exceptions":
            exc = f.box
    assert_true(exc.w > 0)
    doc.highlight(0, exc)
    doc.draw(s, pal)
    var r = doc.page_to_canvas(exc, 400, 520, 1.0)
    var edge = False  # (the outline's top edge, ~2 px above the box: nearer the accent than the page, on some row)
    for y in range(Int(r.y) - 5, Int(r.y)):
        var p = buf[y * 400 + Int(r.cx())]
        if dist(p, pal.accent) * 2 < dist(p, UInt32(0xFFFFFFFF)):
            edge = True
    assert_true(edge)
    var inside = buf[Int(r.cy()) * 400 + Int(r.right() + 1)]
    assert_true(inside & 0xFFFFFF != 0xFFFFFF)  # (the wash over the white page)
    assert_true(doc.describe().find("1 box highlighted") >= 0)
    # zoom about the canvas centre keeps the centre's page point still; pan moves it; fit resets
    var c0 = doc.page_to_canvas(Box(306, 396, 0, 0), 400, 520, 1.0)
    _ = doc.update(Event(6000 + DOC_ZOOM_IN, "", 0))
    var c1 = doc.page_to_canvas(Box(306, 396, 0, 0), 400, 520, 1.0)
    assert_true(doc.zoom > 1.2 and abs(c1.x - c0.x) < 0.5 and abs(c1.y - c0.y) < 0.5)
    _ = doc.update(Event(6000 + DOC_GESTURE, "", PAN, x=200, y=200, dx=30, dy=-20))
    var c2 = doc.page_to_canvas(Box(306, 396, 0, 0), 400, 520, 1.0)
    assert_true(abs(c2.x - c1.x - 30) < 0.5 and abs(c2.y - c1.y + 20) < 0.5)
    _ = doc.update(Event(6000 + DOC_GESTURE, "", ZOOM, x=100, y=100, zoom=2.0))
    assert_true(doc.zoom > 2.4)
    assert_equal(doc.wants()[0], -1)  # (144 dpi still gives a canvas pixel per picture pixel here)
    doc.set_zoom(6.0)
    var want = doc.wants()
    assert_true(want[0] == 0 and want[1] > 144)  # (zoomed far in: it asks for a sharper picture)
    doc.render_now()
    assert_true(doc.shown.dpi > 144)
    _ = doc.update(Event(6000 + DOC_FIT, "", 0))
    assert_equal(doc.zoom, 1.0)
    assert_equal(doc.pan_x, 0.0)
    # one page: next stays; close is reported
    _ = doc.update(Event(6000 + DOC_NEXT, "", 0))
    assert_equal(doc.page, 0)
    assert_false(doc.update(Event(5999, "", 0)))
    _ = doc.update(Event(6000 + DOC_CLOSE, "", 0))
    assert_true(doc.closed)
    # every control named (the canvas by its description)
    var v = doc.view()
    var unnamed = audit(v)
    if len(unnamed) > 0:
        print("A11Y UNNAMED:", unnamed[0])
    assert_equal(len(unnamed), 0)
    print("document card: ok")


def fields_tests() raises:
    """Fields on a hand-made page: values right of and under labels, a label word inside a sentence ignored."""
    var t = TextTable()
    t.add(0, "the", Box(10, 200, 15, 10), 1)
    t.add(0, "total", Box(28, 200, 20, 10), 1)  # ("total" in a sentence: not the label)
    t.add(0, "is", Box(51, 200, 8, 10), 1)
    t.add(0, "Total:", Box(10, 20, 30, 10), 1)
    t.add(0, "41.50", Box(60, 20, 25, 10), 0.8)
    t.add(0, "Ship", Box(10, 60, 20, 10), 1)
    t.add(0, "to", Box(33, 60, 10, 10), 1)
    t.add(0, "Acme", Box(10, 74, 25, 11), 0.9)
    t.add(0, "Foods", Box(38, 74, 28, 11), 0.7)
    t.add(0, "Unit", Box(10, 88, 20, 9), 1)  # (the next line under the value: not part of it)
    var l = List[FieldLabel]()
    l.append(FieldLabel("total", "Total"))
    l.append(FieldLabel("ship_to", "Ship to"))
    l.append(FieldLabel("missing", "Invoice no."))
    var f = find_fields(t, l)
    assert_equal(f[0].value, "41.50")
    assert_equal(f[1].value, "Acme Foods")
    assert_equal(f[1].confidence, 0.7)
    assert_equal(Int(f[1].box.w), 56)
    assert_false(f[2].found)
    print("form fields: ok")


# ---------- FUNSD ----------


def funsd_root(folder: String) raises -> String:
    var os = Python.import_module("os")
    var root = folder + "/funsd"
    var test = root + "/dataset/testing_data"
    if Bool(py=os.path.isdir(test + "/images")):
        return test
    mkdir(root)
    print("fetching FUNSD (research use, not committed) from", FUNSD_URL)
    var urllib = Python.import_module("urllib.request")
    _ = urllib.urlretrieve(FUNSD_URL, root + "/dataset.zip")
    var zf = Python.import_module("zipfile").ZipFile(root + "/dataset.zip")
    zf.extractall(root)
    zf.close()
    return test


def norm_word(s: String) -> String:
    var out = String("")
    for c in s.lower().codepoint_slices():
        var t = String(c)
        var b = t.as_bytes()
        if len(b) == 1:
            var ch = Int(b[0])
            if (ch >= 48 and ch <= 57) or (ch >= 97 and ch <= 122) or ch == 95:
                out += t
        elif len(b) > 1:
            out += t  # (letters outside ASCII count as letters)
    return out


def funsd_truth(path: String) raises -> List[String]:
    var json = Python.import_module("json")
    var builtins = Python.import_module("builtins")
    var d = json.load(builtins.open(path))
    var out = List[String]()
    for f in d["form"]:
        for w in f["words"]:
            var s = norm_word(String(py=w["text"]))
            if s.byte_length() > 0:
                out.append(s)
    return out^


def funsd(folder: String, mut ocr: OcrModel) raises -> Float64:
    var test = funsd_root(folder)
    var names = listdir(test + "/images", ".png")
    var total = 0
    var hits = 0
    var n = min(FUNSD_FORMS, len(names))
    for k in range(n):
        var name = names[k]
        var pic = Picture(test + "/images/" + name)
        var words = ocr.read(UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(pic.pixels.unsafe_ptr())), pic.width, pic.height)
        var seen = Set[String]()
        for w in words:
            var s = norm_word(w.text)
            if s.byte_length() > 0:
                seen.add(s)
        var truth = funsd_truth(test + "/annotations/" + String(name[byte = 0 : name.byte_length() - 4]) + ".json")
        var h = 0
        for t in truth:
            if t in seen:
                h += 1
        total += len(truth)
        hits += h
    return Float64(hits) / Float64(max(total, 1))


# ---------- main ----------


def main() raises:
    var data = getenv("G41_DATA", "build/g41/data")
    var out = getenv("G41_OUT", "build/g41")
    python_start()
    mkdir(out)
    texttable_tests(out)
    fields_tests()
    var bols = listdir(data + "/bol", ".pdf")
    assert_true(len(bols) > 0)
    pdf_tests(data + "/bol/" + bols[0])

    var ocr = OcrModel()
    ocr.load()
    print("ocr model:", ocr.name, "loaded in", Int(ocr.load_ms), "ms")
    var labels = bol_labels()
    var csv = String("file,field,value,page,x,y,w,h\n")
    var pages = 0
    var seconds = 0.0
    var found = 0
    var alone_differs = 0
    var first_words = TextTable()
    var first_fields = List[Field]()
    for k in range(len(bols)):
        var pdf = PdfSource(data + "/bol/" + bols[k])
        var t0 = now_ns()
        var words = read_document(pdf, ocr, DPI)
        seconds += Float64(now_ns() - t0) / 1e9
        pages += pdf.pages
        var fields = find_fields(words, labels)
        for li in range(len(labels)):  # (each label alone finds the same value: no field leans on the others being asked)
            var one = List[FieldLabel]()
            one.append(labels[li])
            var alone = find_fields(words, one)
            if alone[0].value != fields[li].value:
                print("ALONE DIFFERS:", bols[k], labels[li].name, alone[0].value, "vs", fields[li].value)
                alone_differs += 1
        for f in fields:
            if f.found:
                found += 1
                csv += bols[k] + "," + f.name + "," + csv_field(f.value) + "," + String(f.page) + "," + f2(f.box.x) + "," + f2(f.box.y) + ","
                csv += f2(f.box.w) + "," + f2(f.box.h) + "\n"
        if k == 0:
            first_words = words^
            first_fields = fields^
    with open(out + "/bol_fields.csv", "w") as fp:
        fp.write(csv)
    print("bols:", len(bols), "pages:", pages, "fields found:", found, "of", len(bols) * len(labels))
    print("ocr seconds per page:", f2(seconds / Float64(max(pages, 1))), "(drawn at", DPI, "dpi, model", f2(ocr.model_ms / 1000), "s last page)")
    print("ocr vram MB:", Int(ocr.vram_mb))
    first_words.write_csv(out + "/bol_words_first.csv")
    card_tests(data + "/bol/" + bols[0], first_words, first_fields)

    var rec = funsd(out, ocr)
    print("funsd recall:", f2(rec))
    assert_true(found >= len(bols) * len(labels) * 9 // 10)
    assert_equal(alone_differs, 0)
    print("documents: ok")
