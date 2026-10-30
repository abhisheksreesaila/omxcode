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

from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.jobs import start_ui_job
from mojoui.pygil import python_lend, python_reclaim
from mojoui.pdfsource import PdfSource, PdfPage
from mojoui.documentcard import DocumentCard
from mojoui.ocrmodel import OcrModel, read_page
from mojoui.texttable import TextTable
from mojoui.clock import now_ns


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
