# mojoui.documentset (goal 41 M10): a folder of documents as one card. Opens M0's BOL folder, reads three of its files with
# the OCR model (as FolderFeed's job does, here on this thread), finds fields from labels given as data, makes the table's
# rows, and follows a linked row to a file with its chosen field highlighted (IoU ≥ 0.5 with truth's box).
#   G41_DATA=build/g41/data pixi run -e models mojo run -I . tests/test_documentset.mojo
from std.os import getenv
from std.python import Python
from std.testing import assert_equal, assert_true
from mojoui.app import Event
from mojoui.documentset import DocumentSet, documents_in, parse_labels, SET_NEXT, SET_FILE, SET_LABELS_GO, SET_FOCUS
from mojoui.formfields import find_fields, Field
from mojoui.links import Follow, LINK_KEY, REACT_HIGHLIGHT
from mojoui.ocrmodel import OcrModel, read_page
from mojoui.pdfsource import Box, PdfSource
from mojoui.texttable import TextTable
from mojoui.pygil import python_start


def main() raises:
    python_start()
    var data = getenv("G41_DATA", "build/g41/data")
    var files = documents_in(data + "/bol")
    assert_equal(len(files), 17)
    assert_true(files[0].endswith("BOL-1075.pdf"), "sorted by name")
    var labels = parse_labels("Shipment no., Exceptions, Signed by")
    assert_equal(len(labels), 3)
    assert_equal(labels[0].name, "shipment_no")
    assert_equal(labels[2].name, "signed_by")
    var docs = DocumentSet(data + "/bol/", 100, 7)
    assert_equal(docs.name, "bol")
    assert_equal(docs.fields_name(), "bol fields")
    _ = docs.update(Event(100 + SET_NEXT, "", 0))
    assert_equal(docs.file(), "BOL-1080.pdf")
    _ = docs.update(Event(100 + SET_FILE, "", 0))
    assert_equal(docs.file(), "BOL-1075.pdf")
    _ = docs.update(Event(100 + SET_LABELS_GO, "Shipment no., Exceptions, Signed by", 0))
    assert_true(docs.read_asked, "Return in the fields reads")
    print("folder: ok")

    # read every file (here: the job's body, on this thread), the fields by geometry
    var ocr = OcrModel()
    var words = List[TextTable]()
    var fields = List[List[Field]]()
    for path in docs.files:
        var pdf = PdfSource(path)
        var t = TextTable()
        _ = read_page(pdf.render(0, 200), ocr, t)
        fields.append(find_fields(t, docs.labels))
        words.append(t^)
    docs.take_read(words^, fields^)
    assert_true(docs.is_read(), "read")
    var cols = docs.columns()
    assert_equal(len(cols), 4)
    var rows = docs.rows()
    assert_equal(rows[0][0], "BOL-1075.pdf")
    assert_equal(rows[0][1], "1075")
    print("read: ok")

    # a linked row (shipments.shipment_id = bol fields.shipment_no, value 2417): its file shown, Exceptions marked
    _ = docs.update(Event(100 + SET_FOCUS, "", 1))
    assert_equal(docs.focus_name(), "exceptions")
    var r = docs.react(Follow("bol fields", "bol fields", LINK_KEY, "shipment_no", "2417", -1, -1.0, "shipments.shipment_id = bol fields.shipment_no"))
    assert_equal(r.action, REACT_HIGHLIGHT)
    assert_equal(docs.file(), "BOL-2417.pdf")
    assert_equal(len(docs.card.marks), 1)
    var json = Python.import_module("json")
    var truth = json.loads(Python.import_module("pathlib").Path(data + "/truth.json").read_text())
    var want = Box(0, 0, 0, 0)
    for b in truth["bols"]:
        if String(py=b["file"]) == "BOL-2417.pdf":
            var bx = b["fields"]["exceptions"]["box"]
            want = Box(Float64(py=bx[0]), Float64(py=bx[1]), Float64(py=bx[2]), Float64(py=bx[3]))
    var iou = docs.card.marks[0].box.iou(want)
    assert_true(iou >= 0.5, "Exceptions box IoU " + String(iou))
    assert_true(docs.describe().find("highlighted exceptions") >= 0, docs.describe())
    var none = docs.react(Follow("bol fields", "bol fields", LINK_KEY, "shipment_no", "9999", -1, -1.0, ""))
    assert_equal(none.action, 0)
    print("follow: ok")
    print("documentset: ok")
