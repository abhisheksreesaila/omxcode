# mojoui.packpdf (goal 41 M10): a pack's JSON and its PDF. Two pages (facts, a table, a video frame with a box, a PDF page
# with a box) written by pack_pdf.py through Playwright's Chromium; the PDF has 2 pages, the title as text, 2 pictures.
#   G41_DATA=build/g41/data pixi run mojo run -I . tests/test_packpdf.mojo
from std.os import getenv
from std.python import Python
from std.testing import assert_equal, assert_true
from mojoui.packpdf import Pack, write_pack_pdf
from mojoui.pdfsource import Box


def main() raises:
    var data = getenv("G41_DATA", "build/g41/data")
    var p = Pack("Shipment 2417", "answer · a test", "made by tests/test_packpdf.mojo")
    p.colour("#1f8a5b")
    p.page("Evidence")
    p.facts([("Shipment", "2417"), ("Quote \" and ‘curly’", "ok")])
    p.video_frame(data + "/dock.mp4", 5.35, [Box(0, 270, 132, 74)], "frame 160")
    p.table(["a", "b"], [["1", "2"]], "a table")
    p.page("Document")
    p.pdf_page(data + "/bol/BOL-2417.pdf", 0, [Box(54, 320, 26, 10)], "Exceptions")
    assert_equal(p.pages(), 2)
    var json = Python.import_module("json")
    var spec = json.loads(p.json())
    assert_equal(String(py=spec["pages"][0]["blocks"][0]["items"][1][0]), "Quote \" and ‘curly’")
    print("json: ok")
    var out = getenv("G41_OUT", "build/g41") + "/test_pack.pdf"
    write_pack_pdf(p, out)
    var fitz = Python.import_module("pymupdf")
    var doc = fitz.open(out)
    assert_equal(Int(py=Python.import_module("builtins").len(doc)), 2)
    var text = String("")
    var images = 0
    for page in doc:
        text += String(py=page.get_text())
        images += Int(py=Python.import_module("builtins").len(page.get_images()))
    assert_true(text.find("Shipment 2417") >= 0, "title as text")
    assert_equal(images, 2)
    print("pdf: ok")
    var bad = Pack("x")
    bad.pdf_page("/nonexistent.pdf", 0, List[Box]())
    var raised = False
    try:
        write_pack_pdf(bad, getenv("G41_OUT", "build/g41") + "/test_pack_bad.pdf")
    except e:
        raised = String(e).find("failed") >= 0
    assert_true(raised, "a pack that can't be made raises, saying why")
    var osp = Python.import_module("os.path")
    var bad_out = getenv("G41_OUT", "build/g41") + "/test_pack_bad.pdf"
    assert_true(not Bool(py=osp.exists(bad_out + ".json")) and not Bool(py=osp.exists(bad_out + ".log")), "nothing left beside it")
    var unwritable = False
    try:
        write_pack_pdf(p, "/nonexistent-dir/pack.pdf")  # (its spec can't even be written)
    except e:
        unwritable = String(e).find("couldn't write /nonexistent-dir/pack.pdf.json") >= 0
    assert_true(unwritable, "an unwritable place says so")
    print("packpdf: ok")
