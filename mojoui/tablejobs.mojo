# mojoui.tablejobs: a page's table work off the UI thread (goal 41 M3), for TableCards (mojoui.tablecard): a CSV or
# Parquet file read into a card (Insert > Table…), a SQL query over the page's tables, Export CSV. Each runs as a job
# (mojoui.jobs.start_ui_job): its end wakes the UI, update() takes the answer and places it. A job owns its inputs (a
# snapshot of each sheet, docs/ui-threads.md rule 3), so the person goes on scrolling and editing meanwhile.
#
#   var work = TableWork()
#   work.insert(path)                                   # Insert > Table…: read, parse, the card's grid prepared, in the job
#   work.ask(tables, text, page_name, page, "Query 1")  # SQL over every card's table and the page's own
#   work.export(sheet, path)                            # Export CSV of any sheet (a card's, the page's)
#   work.script(tables, text, page_name, page, videos)  # a script (mojoui.script) over the cards, the page and the videos
#   on App.jobs_message:  var f = work.take_file()      # Optional[TableFile]: tables.adopt(f.take().take_card(), x, y, w, h)
#                         var a = work.take_answer()    # Optional[Answer]: a.card (named as asked), a.milliseconds
#                         var e = work.take_export()    # Optional[Exported]: e.path, e.rows
#                         var r = work.take_script()    # Optional[ScriptAnswer]: r.cards (one per named result), r.log, r.problem
#                         work.problem                  # why the last one failed ("": none)
#
# Tracing (MOJOUI_TRACE / MOJOUI_TEST) prints one line as each lands: `JOB: query landed in 12.3 ms (4 rows)`,
# `JOB: table landed big.csv in 812.0 ms (1,000,000 rows)`, `JOB: export landed big.csv in 640.2 ms (1,000,000 rows)`.

from omxcore import Job, JobBody, JobCtl, Catalog, JOB_RUNNING
from mojoui.jobs import start_ui_job
from mojoui.clock import now_ns, trace_on
from mojoui.charts import fixed, grouped
from mojoui.csvio import read_table
from mojoui.files import file_name, file_stem
from mojoui.sheet import Sheet
from mojoui.tablecard import TableCard, TableCards, query_table, sql_name
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.timeseries import TimeSeries
from mojoui.trackcard import is_track, series_from_sheet
from mojoui.script import run_script
from mojoui.videoscript import VideoFunctions, VIDEO_FUNCTIONS, applied_marks
from mojoui.models import ModelFunctions, FRAME_MODELS
from mojoui.player import Mark
from mojoui.maxrt import prepare_max


struct TableFile(Movable):
    """A file read into a card (not yet on the page: TableCards.adopt places it), and its log when it's one (a time
    column with lat and lon: trackcard.is_track)."""

    var path: String
    var card: TableCard
    var log: Optional[TimeSeries]
    var milliseconds: Float64

    def __init__(out self, path: String, var card: TableCard, var log: Optional[TimeSeries], milliseconds: Float64):
        self.path = path
        self.card = card^
        self.log = log^
        self.milliseconds = milliseconds

    def take_card(deinit self) -> TableCard:
        """The card, for TableCards.adopt (the rest is read first: the answer is consumed)."""
        return self.card^


struct Answer(Movable):
    """A query's answer as a card named as asked."""

    var card: TableCard
    var milliseconds: Float64

    def __init__(out self, var card: TableCard, milliseconds: Float64):
        self.card = card^
        self.milliseconds = milliseconds

    def take_card(deinit self) -> TableCard:
        return self.card^


struct Exported(Movable):
    var path: String
    var rows: Int
    var milliseconds: Float64

    def __init__(out self, path: String, rows: Int, milliseconds: Float64):
        self.path = path
        self.rows = rows
        self.milliseconds = milliseconds


struct ScriptAnswer(Movable):
    """A script's results, a card each (named as the script named them), its log (a line per statement run) and its
    first problem ("line N: …"; the results before it are kept)."""

    var cards: List[TableCard]
    var log: List[String]
    var problem: String
    var line: Int
    var milliseconds: Float64
    var marked: String  # the video its last call on frames (regions, detect…) ran on ("": none) …
    var marks: List[Mark]  # … and that result's boxes, for the video's player (made here, off the UI thread)

    def __init__(out self, var cards: List[TableCard], var log: List[String], problem: String, line: Int, milliseconds: Float64):
        self.cards = cards^
        self.log = log^
        self.problem = problem
        self.line = line
        self.milliseconds = milliseconds
        self.marked = ""
        self.marks = List[Mark]()


struct TableFileJob(JobBody):
    comptime Out = TableFile
    var path: String
    var pal: Palette

    def __init__(out self, path: String, pal: Palette):
        self.path = path
        self.pal = pal.copy()

    def run(mut self, ctl: JobCtl) raises -> TableFile:
        var t0 = now_ns()
        var imp = read_table(self.path, ctl)
        if imp.streamed():
            raise Error("it's bigger than memory: open it as the sheet's own table instead")
        var sheet = Sheet(imp.table, False)
        var log = Optional[TimeSeries](None)
        if is_track(sheet):
            log = series_from_sheet(sheet)
        var font = Font()  # (the job's own: the grid's widths are measured here, not on the UI thread)
        var card = TableCard(file_stem(self.path), sheet^, -1, 0, 0, 0, 0, font, self.pal)
        card.note = "from " + file_name(self.path)
        card.source = self.path
        return TableFile(self.path, card^, log^, Float64(now_ns() - t0) / 1e6)


struct QueryJob(JobBody):
    comptime Out = Answer
    var names: List[String]  # the SQL names, one per snapshot
    var sheets: List[Sheet]  # snapshots: the job reads these while the page goes on changing
    var text: String
    var called: String
    var pal: Palette

    def __init__(out self, var names: List[String], var sheets: List[Sheet], text: String, called: String, pal: Palette):
        self.names = names^
        self.sheets = sheets^
        self.text = text
        self.called = called
        self.pal = pal.copy()

    def run(mut self, ctl: JobCtl) raises -> Answer:
        var t0 = now_ns()
        var catalog = Catalog()
        for i in range(len(self.sheets)):
            catalog.add_frame(self.names[i], self.sheets[i].frame)
        var answer = Sheet(query_table(catalog, self.text).share(), False)
        var ms = Float64(now_ns() - t0) / 1e6
        var font = Font()
        var card = TableCard(self.called, answer^, -1, 0, 0, 0, 0, font, self.pal)
        card.note = "a query"
        return Answer(card^, ms)


struct ScriptJob(JobBody):
    comptime Out = ScriptAnswer
    var names: List[String]
    var sheets: List[Sheet]
    var videos: VideoFunctions
    var taken: List[String]  # the names a result may not take (the page's tables and videos; a script's own may be redone)
    var text: String
    var pal: Palette

    def __init__(out self, var names: List[String], var sheets: List[Sheet], var videos: VideoFunctions, var taken: List[String], text: String, pal: Palette):
        self.names = names^
        self.sheets = sheets^
        self.videos = videos^
        self.taken = taken^
        self.text = text
        self.pal = pal.copy()

    def run(mut self, ctl: JobCtl) raises -> ScriptAnswer:
        var t0 = now_ns()
        var catalog = Catalog()
        for i in range(len(self.sheets)):
            catalog.add_frame(self.names[i], self.sheets[i].frame)
        self.videos.add_to(catalog)
        var fns = ModelFunctions(self.videos.copy())  # (the videos' functions and the models: mojoui.models)
        var run = run_script(self.text, catalog, fns, self.taken)
        var font = Font()
        var cards = List[TableCard]()
        for i in range(len(run.names)):
            var card = TableCard(run.names[i], Sheet(run.tables[i], False), -1, 0, 0, 0, 0, font, self.pal)
            card.note = "a script"
            cards.append(card^)
        var answer = ScriptAnswer(cards^, run.log.copy(), run.problem, run.line, Float64(now_ns() - t0) / 1e6)
        var on_frames = materialize[VIDEO_FUNCTIONS]()
        for f in materialize[FRAME_MODELS]():
            on_frames.append(f)
        var m = applied_marks(self.text, run.names, run.tables, on_frames)
        answer.marked = m[0]
        answer.marks = m[1].copy()
        return answer^


struct ExportJob(JobBody):
    comptime Out = Exported
    var sheet: Sheet
    var path: String

    def __init__(out self, var sheet: Sheet, path: String):
        self.sheet = sheet^
        self.path = path

    def run(mut self, ctl: JobCtl) raises -> Exported:
        var t0 = now_ns()
        self.sheet.write_csv(self.path)
        return Exported(self.path, self.sheet.rows(), Float64(now_ns() - t0) / 1e6)


struct TableWork(Movable):
    """A page's running table jobs (one of each kind at a time; a second ask while one runs replaces nothing: it says
    so in `problem`)."""

    var file: Optional[Job[TableFile]]
    var file_path: String
    var query: Optional[Job[Answer]]
    var export_: Optional[Job[Exported]]
    var export_path: String
    var script_: Optional[Job[ScriptAnswer]]
    var problem: String

    def __init__(out self):
        self.script_ = None
        self.file = None
        self.file_path = ""
        self.query = None
        self.export_ = None
        self.export_path = ""
        self.problem = ""

    def busy(self) -> Bool:
        return Bool(self.file) or Bool(self.query) or Bool(self.export_) or Bool(self.script_)

    def inserting(self) -> String:
        """The file being read ("": none)."""
        return self.file_path if self.file else String("")

    def insert(mut self, path: String, pal: Palette) -> Bool:
        """Starts reading `path` into a card (False: one is being read already)."""
        if self.file:
            self.problem = "Still reading " + file_name(self.file_path)
            return False
        self.file_path = path
        self.file = start_ui_job(TableFileJob(path, pal))
        return True

    def ask(mut self, tables: TableCards, text: String, page_name: String, page: Sheet, called: String, pal: Palette) -> Bool:
        """Starts `text` (SQL) over every card's table and the page's own (`page` as `page_name`; "": left out); the
        answer's card is named `called` (False: a query runs already)."""
        if self.query:
            self.problem = "A query is running already"
            return False
        var names = List[String]()
        var sheets = List[Sheet]()
        var page_sql = String("")
        if page_name != "" and tables.find(page_name) < 0:
            page_sql = page_name
            names.append(sql_name(page_name))
            sheets.append(page.snapshot())
        for k in range(len(tables)):
            names.append(tables.sql_name_of(k, page_sql))
            sheets.append(tables.cards[k].sheet.snapshot())
        self.query = start_ui_job(QueryJob(names^, sheets^, text, called, pal))
        return True

    def script(mut self, tables: TableCards, text: String, page_name: String, page: Sheet, var videos: VideoFunctions, pal: Palette) -> Bool:
        """Starts a script (mojoui.script) over every card's table, the page's own (`page` as `page_name`; "": left out)
        and the videos (each a table of its frames; their functions callable). False: a script runs already."""
        if self.script_:
            self.problem = "A script is running already"
            return False
        var names = List[String]()
        var sheets = List[Sheet]()
        var page_sql = String("")
        if page_name != "" and tables.find(page_name) < 0:
            page_sql = page_name
            names.append(sql_name(page_name))
            sheets.append(page.snapshot())
        var taken = List[String]()
        if page_sql != "":
            taken.append(names[0])
        for k in range(len(tables)):
            names.append(tables.sql_name_of(k, page_sql))
            sheets.append(tables.cards[k].sheet.snapshot())
            if tables.cards[k].note != "a script":  # (a script's earlier results are its to redo; anything else is the person's)
                taken.append(names[len(names) - 1])
        for v in videos.names:
            taken.append(v)
        if text.find("classify(") >= 0 or text.find("detect(") >= 0:  # (a model: MAX's environment set here, not in the job: mojoui.maxrt)
            try:
                prepare_max()
            except e:
                self.problem = String(e)
                return False
        self.script_ = start_ui_job(ScriptJob(names^, sheets^, videos^, taken^, text, pal))
        return True

    def take_script(mut self) -> Optional[ScriptAnswer]:
        """The script's answer once its job has ended (None while it runs; None and `problem` set when the job failed)."""
        if not self.script_ or self.script_.value().poll() == JOB_RUNNING:
            return None
        var job = self.script_.take()
        try:
            var a = job.result()
            if trace_on():
                print("JOB: script landed in " + fixed(a.milliseconds, 1) + " ms (" + String(len(a.cards)) + " results)", flush=True)
            return a^
        except e:
            self.problem = String(e)
            if trace_on():
                print("JOB: script failed: " + String(e), flush=True)
            return None

    def export(mut self, sheet: Sheet, path: String) -> Bool:
        """Starts writing `sheet` (a snapshot of it) as CSV to `path` (False: an export runs already)."""
        if self.export_:
            self.problem = "Still exporting " + file_name(self.export_path)
            return False
        self.export_path = path
        self.export_ = start_ui_job(ExportJob(sheet.snapshot(), path))
        return True

    def take_file(mut self) -> Optional[TableFile]:
        """The file's card once its job has ended (None while it runs; None and `problem` set when it failed)."""
        if not self.file or self.file.value().poll() == JOB_RUNNING:
            return None
        var job = self.file.take()
        try:
            var f = job.result()
            if trace_on():
                print("JOB: table landed " + file_name(f.path) + " in " + fixed(f.milliseconds, 1) + " ms (" + grouped(f.card.sheet.rows()) + " rows)", flush=True)
            return f^
        except e:
            self.problem = "Couldn't add " + file_name(self.file_path) + ": " + String(e)
            if trace_on():
                print("JOB: table failed " + file_name(self.file_path) + ": " + String(e), flush=True)
            return None

    def take_answer(mut self) -> Optional[Answer]:
        if not self.query or self.query.value().poll() == JOB_RUNNING:
            return None
        var job = self.query.take()
        try:
            var a = job.result()
            if trace_on():
                print("JOB: query landed in " + fixed(a.milliseconds, 1) + " ms (" + grouped(a.card.sheet.rows()) + " rows)", flush=True)
            return a^
        except e:
            self.problem = String(e)
            if trace_on():
                print("JOB: query failed: " + String(e), flush=True)
            return None

    def take_export(mut self) -> Optional[Exported]:
        if not self.export_ or self.export_.value().poll() == JOB_RUNNING:
            return None
        var job = self.export_.take()
        try:
            var x = job.result()
            if trace_on():
                print("JOB: export landed " + file_name(x.path) + " in " + fixed(x.milliseconds, 1) + " ms (" + grouped(x.rows) + " rows)", flush=True)
            return x^
        except e:
            self.problem = "Couldn't export " + file_name(self.export_path) + ": " + String(e)
            return None
