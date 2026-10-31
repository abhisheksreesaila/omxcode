# Goal 41 M7: a document card's page drawing and OCR as jobs (mojoui.documentjobs), with Python on the job's thread
# (mojoui.pygil). Needs omxcore, so it is built, then run in the models environment:
#   scripts/mxbuild.sh tests/test_document_jobs.mojo -o build/test_document_jobs && \
#     G41_DATA=build/g41/data pixi run -e models build/test_document_jobs
# Prints "document jobs: ok": the page arrives through a job; the OCR job's words equal a direct read's; while the OCR ran,
# the calling thread kept going (its longest gap between turns, printed) and could still call Python itself.

from std.testing import assert_equal, assert_true
from std.os import getenv
from std.ffi import external_call, c_int
from std.python import Python
from mojoui.clock import now_ns
from mojoui.documentcard import DocumentCard
from mojoui.documentjobs import DocumentFeed
from mojoui.ocrmodel import OcrModel, read_document
from mojoui.pdfsource import PdfSource
from mojoui.pygil import python_start, python_lent, python_guard


def nap(ms: Int):
    _ = external_call["usleep", c_int](c_int(ms * 1000))


def main() raises:
    var data = getenv("G41_DATA", "build/g41/data")
    python_start()
    var names = Python.import_module("builtins").sorted(Python.import_module("os").listdir(data + "/bol"))
    var path = data + "/bol/" + String(py=names[0])
    var ocr = OcrModel()
    ocr.load()  # (on this thread: the first load imports torch, which is slow; the job then only reads)
    var doc = DocumentCard(path, msg_base=6000, canvas=300)
    var feed = DocumentFeed()
    feed.poll(doc)
    assert_true(feed.busy())
    assert_equal(python_lent(), 1)
    var t0 = now_ns()
    while feed.busy():
        nap(2)
        feed.poll(doc)
    assert_equal(feed.error, "")
    assert_equal(doc.shown.page, 0)
    assert_equal(python_lent(), 0)
    print("render job:", Float64(now_ns() - t0) / 1e6, "ms")

    feed.read(doc, ocr, 200)
    assert_equal(doc.status, "Reading")
    var turns = 0
    var longest = 0
    var last = now_ns()
    var side = 0
    var guarded = String("")
    while feed.busy():
        nap(2)
        var t = now_ns()
        longest = max(longest, Int(t - last))
        last = t
        turns += 1
        if turns == 3:
            side = PdfSource(path).pages  # (Python on this thread while the job holds the lock out)
            try:  # (a bare Python call here would hang: the guard says so instead, D-1344)
                python_guard("probe")
            except e:
                guarded = String(e)
        feed.poll(doc)
    assert_equal(feed.error, "")
    assert_true(feed.words_ready())
    var words = feed.take_words()
    assert_equal(side, 1)
    assert_true(guarded.find("probe: Python called without its lock on this thread (1 job(s) hold it lent)") >= 0, "guard: " + guarded)
    python_guard("after")  # (the lock is back: no error)
    print("guard: ok")
    assert_equal(doc.status, "")
    var direct = read_document(PdfSource(path), ocr, 200)
    assert_equal(words.rows(), direct.rows())
    for i in range(words.rows()):
        assert_equal(words.text[i], direct.text[i])
    print("ocr job:", words.rows(), "words in", words.seconds, "s;", turns, "turns meanwhile, longest gap", Float64(longest) / 1e6, "ms")
    assert_true(turns >= 5 and Float64(longest) / 1e6 < 100)
    print("document jobs: ok")
