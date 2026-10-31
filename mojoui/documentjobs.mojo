# mojoui.documentjobs: a document card's slow work off the UI thread (goal 41 M7, docs/ui-threads.md). Drawing a page
# (PyMuPDF) and reading it (OCR, docTR on the GPU) run in jobs started with start_ui_job, so the window keeps drawing and
# a finished job wakes update() at once. Separate from mojoui.documentcard because it needs omxcore (jobs): the card's
# model and drawing stay testable with a plain `mojo run`.
#
#   var feed = DocumentFeed()
#   update():  if doc.update(event) or event.message == JOBS: feed.poll(doc)     # takes what ended, starts the page it wants
#              if doc.acted == 0: feed.read(doc, OcrModel())                     # its "Read" action: OCR every page, as a job
#              if feed.words_ready(): rows = feed.take_words()                   # a TextTable in page points
#
# Both jobs call Python, so starting one lends the Python lock (mojoui.pygil.python_lend) and taking its result reclaims it.

from omxcore import Job, JobBody, JobCtl, JobProgress, JOB_RUNNING
from mojoui.jobs import start_ui_job
from mojoui.pygil import python_lend, python_reclaim
from mojoui.pdfsource import PdfSource, PdfPage
from mojoui.documentcard import DocumentCard
from mojoui.ocrmodel import OcrModel, read_page
from mojoui.texttable import TextTable, csv_field
from mojoui.clock import now_ns
from mojoui.formfields import FieldLabel, Field, find_fields
from mojoui.documentset import DocumentSet
from mojoui.csvio import read_table
from mojoui.sheet import Sheet
from mojoui.tablecard import TableCard
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.shared import environment
from std.ffi import external_call, c_int


struct RenderJob(JobBody):
    comptime Out = PdfPage
    var pdf: PdfSource
    var page: Int
    var dpi: Int

    def __init__(out self, pdf: PdfSource, page: Int, dpi: Int):
        self.pdf = pdf.copy()
        self.page = page
        self.dpi = dpi

    def run(mut self, ctl: JobCtl) raises -> PdfPage:
        return self.pdf.render(self.page, self.dpi)


struct ReadJob(JobBody):
    """Every page drawn at `dpi` and read by the model: the document's words (page points)."""
    comptime Out = TextTable
    var pdf: PdfSource
    var model: OcrModel
    var dpi: Int

    def __init__(out self, pdf: PdfSource, model: OcrModel, dpi: Int):
        self.pdf = pdf.copy()
        self.model = model.copy()
        self.dpi = dpi

    def run(mut self, ctl: JobCtl) raises -> TextTable:
        var t0 = now_ns()
        var out = TextTable()
        for p in range(self.pdf.pages):
            ctl.check()
            var page = self.pdf.render(p, self.dpi)
            _ = read_page(page, self.model, out)
        out.seconds = Float64(now_ns() - t0) / 1e9
        return out^


struct DocumentFeed(Movable):
    var rendering: Optional[Job[PdfPage]]
    var reading: Optional[Job[TextTable]]
    var words: Optional[TextTable]  # the last finished reading, until take_words()
    var error: String  # why the last job failed ("" when it didn't)

    def __init__(out self):
        self.rendering = None
        self.reading = None
        self.words = None
        self.error = ""

    def busy(self) -> Bool:
        return Bool(self.rendering) or Bool(self.reading)

    def poll(mut self, mut doc: DocumentCard):
        """Takes finished work into the card and starts the page picture it wants (one render at a time)."""
        if self.rendering and self.rendering.value().poll() != JOB_RUNNING:
            var job = self.rendering.take()
            python_reclaim()
            try:
                doc.put_page(job.result())
            except e:
                self.error = String(e)
        if not self.rendering:
            var want = doc.wants()
            if want[0] >= 0:
                try:
                    python_lend()
                    self.rendering = start_ui_job(RenderJob(doc.pdf, want[0], want[1]))
                except e:
                    self.error = String(e)
        if self.reading and self.reading.value().poll() != JOB_RUNNING:
            var job = self.reading.take()
            python_reclaim()
            doc.status = ""
            doc.progress = -1
            doc.version += 1
            try:
                self.words = job.result()
            except e:
                self.error = String(e)
                doc.status = "Couldn't read it"

    def read(mut self, mut doc: DocumentCard, model: OcrModel, dpi: Int = 200):
        """Starts reading every page of the card's document (OCR); the card says "Reading" until it ends."""
        if self.reading:
            return
        try:
            python_lend()
            self.reading = start_ui_job(ReadJob(doc.pdf, model, dpi))
            doc.status = "Reading"
            doc.version += 1
        except e:
            self.error = String(e)

    def words_ready(self) -> Bool:
        return Bool(self.words)

    def take_words(mut self) -> TextTable:
        if self.words:
            return self.words.take()
        return TextTable()


# ---------- a folder of documents (mojoui.documentset) ----------


struct FolderRead(Movable):
    """What a folder's read found: per file its words (page points) and its fields (one per label), the fields as a table
    card (one row per file; columns typed by the engine's CSV reader, so numbers join numbers), how long it took."""

    var words: List[TextTable]
    var fields: List[List[Field]]
    var card: Optional[TableCard]
    var seconds: Float64

    def __init__(out self):
        self.words = List[TextTable]()
        self.fields = List[List[Field]]()
        self.card = None
        self.seconds = 0


struct ReadFolderJob(JobBody):
    """Every page of every file drawn at `dpi` and read by the model, each label's value found by geometry, the fields
    table made: all off the UI thread."""
    comptime Out = FolderRead
    var files: List[String]
    var labels: List[FieldLabel]
    var model: OcrModel
    var dpi: Int
    var name: String  # the fields table's name
    var pal: Palette

    def __init__(out self, files: List[String], labels: List[FieldLabel], model: OcrModel, dpi: Int, name: String, pal: Palette):
        self.files = files.copy()
        self.labels = labels.copy()
        self.model = model.copy()
        self.dpi = dpi
        self.name = name
        self.pal = pal.copy()

    def run(mut self, ctl: JobCtl) raises -> FolderRead:
        var t0 = now_ns()
        var out = FolderRead()
        ctl.add_total(len(self.files))
        for path in self.files:
            ctl.check()
            var pdf = PdfSource(path)
            var words = TextTable()
            for p in range(pdf.pages):
                var page = pdf.render(p, self.dpi)
                _ = read_page(page, self.model, words)
            out.fields.append(find_fields(words, self.labels))
            out.words.append(words^)
            ctl.advance(1)
        # the table: one row per file, written as CSV and read back by the engine's reader (it types the columns)
        var text = String("file")
        for l in self.labels:
            text += "," + csv_field(l.name)
        text += "\n"
        for i in range(len(self.files)):
            var n = self.files[i]
            var slash = n.rfind("/")
            text += csv_field(String(n[byte = slash + 1 :]) if slash >= 0 else n)
            for f in out.fields[i]:
                text += "," + csv_field(f.value)
            text += "\n"
        var tmp = environment("TMPDIR", "/tmp") + "/mojoui-fields-" + String(Int(external_call["getpid", c_int]())) + "-" + String(now_ns()) + ".csv"
        with open(tmp, "w") as f:
            f.write(text)
        var imp = read_table(tmp)
        _ = external_call["unlink", c_int](tmp.as_c_string_span())
        var card = TableCard(self.name, Sheet(imp.table, False), -1, 0, 0, 0, 0, Font(), self.pal)
        card.note = "read from " + String(len(self.files)) + " documents"
        out.card = card^
        out.seconds = Float64(now_ns() - t0) / 1e9
        return out^


struct FolderFeed(Movable):
    """A DocumentSet's work: its page pictures (one render at a time, as DocumentFeed) and reading the whole folder."""

    var pages: DocumentFeed
    var reading: Optional[Job[FolderRead]]
    var done: Optional[FolderRead]
    var error: String

    def __init__(out self):
        self.pages = DocumentFeed()
        self.reading = None
        self.done = None
        self.error = ""

    def busy(self) -> Bool:
        return self.pages.busy() or Bool(self.reading)

    def read(mut self, mut docs: DocumentSet, model: OcrModel, pal: Palette, dpi: Int = 200):
        """Starts reading every document of the set; its card says "Reading" with the share done."""
        if self.reading:
            return
        try:
            python_lend()
            self.reading = start_ui_job(ReadFolderJob(docs.files, docs.labels, model, dpi, docs.fields_name(), pal))
            docs.reading = True
            docs.card.status = "Reading " + String(len(docs.files)) + " documents"
            docs.card.progress = 0
            docs.card.version += 1
        except e:
            self.error = String(e)

    def poll(mut self, mut docs: DocumentSet):
        """Takes what ended: the page picture into its card (and asks for the next one it wants), the read's progress, the
        read itself (done: take it with take_read())."""
        self.pages.poll(docs.card)
        if self.pages.error != "":
            self.error = self.pages.error
            self.pages.error = ""
        if not self.reading:
            return
        var state = self.reading.value().poll()
        if state == JOB_RUNNING:
            var p = self.reading.value().progress()
            var share = Int(100 * p.done // p.total) if p.total > 0 else 0
            if share != docs.card.progress:
                docs.card.progress = share
                docs.card.version += 1
            return
        var job = self.reading.take()
        python_reclaim()
        docs.reading = False
        docs.card.status = ""
        docs.card.progress = -1
        docs.card.version += 1
        try:
            self.done = job.result()
        except e:
            self.error = "Couldn't read the documents: " + String(e)

    def take_read(mut self) -> Optional[FolderRead]:
        if self.done:
            return self.done.take()
        return None


struct OpenFolderJob(JobBody):
    """A folder of documents opened off the UI thread: listing it and opening its first PDF (PyMuPDF's first import alone
    takes ~0.1 s)."""
    comptime Out = DocumentSet
    var path: String
    var msg_base: Int
    var canvas: Int
    var w: Int

    def __init__(out self, path: String, msg_base: Int, canvas: Int, w: Int):
        self.path = path
        self.msg_base = msg_base
        self.canvas = canvas
        self.w = w

    def run(mut self, ctl: JobCtl) raises -> DocumentSet:
        return DocumentSet(self.path, self.msg_base, self.canvas, 0, 0, self.w)


def open_folder_job(path: String, msg_base: Int, canvas: Int, w: Int = 560) raises -> Job[DocumentSet]:
    """OpenFolderJob started (it calls Python: the lock is lent; reclaim it with python_reclaim() when it's taken)."""
    python_lend()
    return start_ui_job(OpenFolderJob(path, msg_base, canvas, w))
