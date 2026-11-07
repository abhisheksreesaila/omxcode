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

from omxcore import Job, JobBody, JobCtl, Catalog, Table, SharedTable, JOB_RUNNING, TEXT
from mojoui.jobs import start_ui_job
from std.time import sleep
from mojoui.shared import environment, count_add, count_of
from mojoui.clock import now_ns, trace_on
from mojoui.charts import fixed, grouped
from mojoui.csvio import read_table
from mojoui.files import file_name, file_stem
from mojoui.sheet import Sheet
from mojoui.sheetjobs import stopped
from mojoui.tablecard import TableCard, TableCards, query_table, sql_name
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.timeseries import TimeSeries
from mojoui.trackcard import is_track, series_from_sheet
from mojoui.script import run_script, strip_comments
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
    var room: Int  # public: the bytes this answer may take (the answer budget, or what the visitor's tables leave); 0: no limit

    def __init__(out self, var names: List[String], var sheets: List[Sheet], text: String, called: String, pal: Palette, room: Int = 0):
        self.names = names^
        self.sheets = sheets^
        self.text = text
        self.called = called
        self.pal = pal.copy()
        self.room = room

    def run(mut self, ctl: JobCtl) raises -> Answer:
        var t0 = now_ns()
        var catalog = Catalog()
        for i in range(len(self.sheets)):
            catalog.add_frame(self.names[i], self.sheets[i].frame)
        var cap = public_rows()
        var sources = List[Int]()  # the dictionaries the question reads (an answer that projects them shares, not copies)
        var maxword = 0
        for i in range(len(self.sheets)):
            ref base = self.sheets[i].frame.base
            for c in range(base.columns()):
                if base.kind(c) == TEXT:
                    var d = base.dictionary(c)
                    sources.append(Int(d.unsafe_ptr()))
                    for w in d:
                        maxword = max(maxword, w.byte_length())
        var held = take_question()  # (public: one of the server's places for questions, held until the engine ends, even past a stop)
        var table: SharedTable
        try:
            if cap > 0 and self.room > 0:  # (round 5: the answer's real bytes, strings included, are what's budgeted)
                var star = 0
                for i in range(len(self.sheets)):
                    star += self.sheets[i].columns()
                var width = answer_width(self.text, star)
                var grows = text_growth(self.text)
                if grows > 0:  # (round 5: the engine computes a built string for every row before an outer LIMIT, so the worst
                    # it could build is bounded before it runs: each operand at the longest word read, the literals, a REPLACE
                    # as long as the text; over the most rows a table here has)
                    var length = self.text.byte_length()
                    var operands = 1 + self.text.count("||") + self.text.count(",")
                    var per_cell = 40 + operands * maxword * (length if grows == 2 else 1) + length
                    var most_rows = 0
                    for i in range(len(self.sheets)):
                        most_rows = max(most_rows, self.sheets[i].rows())
                    if per_cell * width * most_rows > self.room:
                        give_back_question(held)
                        held = False
                        raise Error("this question builds strings that could take more than the " + grouped(self.room >> 20)
                                    + " MB the web copy gives an answer (" + grouped(most_rows) + " rows × " + grouped(width)
                                    + " columns): ask about a smaller table, or without building strings")
                cap = max(1, min(cap, self.room // (8 * width)))
                table = query_table(catalog, capped_sql(self.text, cap), ctl, public_join_bytes(), public_threads(), public_sort_bytes()).share()
                var real = table_bytes(table, sources)
                if real > self.room or (table.rows() > cap and cap < public_rows()):
                    give_back_question(held)
                    held = False
                    raise Error("the answer would take more than " + grouped(self.room >> 20) + " MB (" + grouped(table.columns()) + " columns, "
                                + grouped(real >> 20) + " MB in " + grouped(table.rows()) + " rows), more than the web copy keeps for it: ask for fewer columns or rows")
            else:
                table = query_table(catalog, capped_sql(self.text, cap), ctl, public_join_bytes(), public_threads(), public_sort_bytes()).share()
        except e:  # (the engine's words for a join past its budget name its options: the visitor gets plain ones)
            give_back_question(held)
            if cap > 0 and String(e).find("join_budget") >= 0:
                raise Error("this question's join would take more memory than the web copy gives one question: join on a key with fewer matches, or filter first")
            raise e^
        give_back_question(held)
        if cap > 0 and table.rows() > cap:  # (the public copy keeps no answer over its cap: memory a visitor can't take from others)
            raise Error("the answer has more than " + grouped(cap) + " rows, more than the web copy keeps: ask for fewer (a filter, a GROUP BY or a LIMIT)")
        var answer = Sheet(table^, False)
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
        for f in materialize[FRAME_MODELS]():  # (the functions that make boxes: an image-labels pack's rows are labels, not marks)
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
    var query_t0: Int  # when the running question started (the public copy's time budget)
    var stopped_queries: List[Job[Answer]]  # questions stopped by the budget, kept until their threads end (never joined: D-284)
    var budget_hit: Bool  # the running question was stopped by its time budget
    var export_: Optional[Job[Exported]]
    var export_path: String
    var script_: Optional[Job[ScriptAnswer]]
    var problem: String

    def __init__(out self):
        self.script_ = None
        self.file = None
        self.file_path = ""
        self.query = None
        self.query_t0 = 0
        self.budget_hit = False
        self.stopped_queries = List[Job[Answer]]()
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
        self.reap_stopped()
        if len(self.stopped_queries) > 0:  # (a question stopped at the time budget runs on in the engine until its next check)
            self.problem = PARKED_WORDS
            return False
        var refused = public_refusal(text)
        if refused != "":
            self.problem = refused
            return False
        var room = 0
        if public_rows() > 0:  # (round 4: the visitor's kept answers and uploaded tables count, and answers are capped)
            var held = 0
            var answers = 0
            var starter = environment("OMX_STARTER")
            var shared = List[Int]()  # (dictionaries of the tables an answer may project: not the answer's own bytes)
            for k in range(len(tables)):
                if tables.cards[k].note != "a query":
                    ref base = tables.cards[k].sheet.frame.base
                    for c in range(base.columns()):
                        if base.kind(c) == TEXT:
                            shared.append(Int(base.dictionary(c).unsafe_ptr()))
            for k in range(len(tables)):
                ref c = tables.cards[k]
                if c.note == "a query":  # (round 5: kept answers by their real size, strings included)
                    answers += 1
                    held += table_bytes(c.sheet.frame.base, shared)
                elif c.source != "" and (starter == "" or not c.source.startswith(starter)):
                    held += table_bytes(c.sheet.frame.base, List[Int]())
            if answers >= public_answers():
                self.problem = "You have " + String(answers) + " answers on the page, the most the web copy keeps: remove one first"
                return False
            room = min(public_answer_bytes(), visitor_table_bytes() - held)
            if room < 8 << 10:
                self.problem = "Your tables and answers here take " + grouped(held >> 20) + " MB, the most the web copy holds for one visitor: remove one first"
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
        self.query = start_ui_job(QueryJob(names^, sheets^, text, called, pal, room))
        self.query_t0 = now_ns()
        self.budget_hit = False
        return True

    def running_query(self) -> Bool:
        return Bool(self.query)

    def check_budget(mut self) -> Bool:
        """The public copy's time budget (MOJOUI_QUERY_S, 20 s): a question running past it is stopped, and `problem` says
        so in plain words. True when it stopped one now (goal 62 M7: a visitor's question can't hold the shared server)."""
        var limit = public_query_s()
        if limit <= 0 or not self.query or self.query.value().poll() != JOB_RUNNING:
            return False
        if Float64(now_ns() - self.query_t0) / 1e9 < limit:
            return False
        self.query.value().cancel()
        self.budget_hit = True
        self.problem = "This question ran past the web copy's " + String(Int(limit)) + " s, so it was stopped: ask for less (a filter, a GROUP BY or a LIMIT)"
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
        var plain = strip_comments(text)
        if plain.find("classify(") >= 0 or plain.find("detect(") >= 0:  # (a model: MAX's environment set here, not in the job: mojoui.maxrt)
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
        if environment("MOJOUI_PUBLIC") == "1" and sheet.rows() > 1_000_000:  # (a download from a shared server, goal 62's review)
            self.problem = "The web copy exports at most 1,000,000 rows: ask a question for fewer first"
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

    def reap_stopped(mut self):
        """Lets go of the stopped questions whose threads have ended (the others stay: they still count as running)."""
        var kept = List[Job[Answer]]()
        while len(self.stopped_queries) > 0:
            var old = self.stopped_queries.pop()
            if not stopped(old):
                kept.append(old^)
        self.stopped_queries = kept^

    def take_answer(mut self) -> Optional[Answer]:
        self.reap_stopped()
        if not self.query or self.query.value().poll() == JOB_RUNNING:
            return None
        if self.budget_hit:  # (stopped by the time budget: its result would wait for the engine's next check, so park it)
            self.stopped_queries.append(self.query.take())
            self.budget_hit = False
            return None
        var job = self.query.take()
        try:
            var a = job.result()
            if trace_on():
                print("JOB: query landed in " + fixed(a.milliseconds, 1) + " ms (" + grouped(a.card.sheet.rows()) + " rows)", flush=True)
            return a^
        except e:
            if not self.budget_hit:  # (stopped by the time budget: its own words stay)
                self.problem = String(e)
            self.budget_hit = False
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


def public_rows() -> Int:
    """The public copy's cap on a question's answer (MOJOUI_QUERY_ROWS, 1,000,000 rows); 0 on a desktop: no cap."""
    if environment("MOJOUI_PUBLIC") != "1":
        return 0
    try:
        return Int(environment("MOJOUI_QUERY_ROWS", "1000000"))
    except:
        return 1_000_000


def public_join_bytes() -> Int:
    """The public copy's budget for a materialized join (MOJOUI_JOIN_BYTES, 512 MB); 0 on a desktop: the engine's own."""
    if environment("MOJOUI_PUBLIC") != "1":
        return 0
    try:
        return Int(environment("MOJOUI_JOIN_BYTES", String(512 << 20)))
    except:
        return 512 << 20


def public_query_s() -> Float64:
    """The public copy's time budget for a question (MOJOUI_QUERY_S, 20 s); 0 on a desktop: none."""
    if environment("MOJOUI_PUBLIC") != "1":
        return 0
    try:
        return Float64(Int(environment("MOJOUI_QUERY_S", "20")))
    except:
        return 20.0


def capped_sql(text: String, cap: Int) -> String:
    """A SELECT with an outer LIMIT of cap + 1, so an answer past the cap stops being built there (no cap: as it was)."""
    var t = String(text.strip())
    while t.startswith("--") or t.startswith("/*"):  # (a comment in front must not hide the SELECT from the cap)
        var end = t.find("\n") if t.startswith("--") else t.find("*/")
        if end < 0:
            return text
        t = String(String(t[byte = end + (1 if t.startswith("--") else 2) :]).strip())
    while t.endswith(";"):
        t = String(String(t[byte = 0 : t.byte_length() - 1]).strip())
    var up = t.upper()
    if cap <= 0 or not (up.startswith("SELECT") or up.startswith("(")):
        return text
    # (the parentheses on lines of their own: a trailing `-- comment` ends at its line, not over the wrapper)
    return "SELECT * FROM (\n" + t + "\n) AS answer LIMIT " + String(cap + 1)


def public_refusal(text: String) -> String:
    """Why the public copy won't run this question ("" when it will): one SELECT at a time, so every answer is capped
    while it's built and every part of it is held to the engine's budgets. No WITH, anywhere (it builds its whole answer
    first); no UNION, INTERSECT or EXCEPT (the engine builds each side whole, with no stop between: goal 62's round-3
    review); no script statements (they run outside the question's budgets). Words in quotes or comments don't count,
    and parentheses in front don't hide what follows ("(WITH …)" is a WITH)."""
    if environment("MOJOUI_PUBLIC") != "1":
        return ""
    var words = sql_words(text)
    for w in words:
        if w == "WITH":
            return "The web copy asks one SELECT at a time: WITH isn't offered here (write its part as a subquery in FROM)"
    for w in words:
        if w == "UNION" or w == "INTERSECT" or w == "EXCEPT":
            return "The web copy asks one SELECT at a time: UNION, INTERSECT and EXCEPT aren't offered here"
    var replaces = 0
    for w in words:
        if w == "REPLACE":
            replaces += 1
    if replaces > 1:  # (each REPLACE can multiply a string's length: round 5)
        return "The web copy takes one REPLACE a question"
    var first = 0
    while first < len(words) and words[first] == "(":
        first += 1
    if first >= len(words) or words[first] != "SELECT":
        return "The web copy asks one SELECT at a time"
    return ""


def is_word_byte(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128


def sql_words(text: String) -> List[String]:
    """A SQL text's words in capitals, and "(" for each opening parenthesis, outside quotes ('…', "…", `…`) and comments
    (-- … and /* … */): what the public copy's one-SELECT rule reads."""
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c == 45 and i + 1 < n and Int(b[i + 1]) == 45:  # -- to the line's end
            while i < n and Int(b[i]) != 10:
                i += 1
        elif c == 47 and i + 1 < n and Int(b[i + 1]) == 42:  # /* … */
            i += 2
            while i + 1 < n and not (Int(b[i]) == 42 and Int(b[i + 1]) == 47):
                i += 1
            i += 2
        elif c == 39 or c == 34 or c == 96:  # a quoted string or name ('' inside: two back to back, the same words)
            i += 1
            while i < n and Int(b[i]) != c:
                i += 1
            i += 1
        elif c == 40:
            out.append("(")
            i += 1
        elif is_word_byte(c):
            var j = i
            while j < n and is_word_byte(Int(b[j])):
                j += 1
            out.append(String(text[byte = i : j]).upper())
            i = j
        else:
            i += 1
    return out^


comptime SLOT_QUESTIONS = 88  # mojoui.shared slot: the questions the engine runs in this process now (the public copy counts)
comptime BUSY_WORDS = "The server is answering other visitors' questions: ask again in a moment"
comptime PARKED_WORDS = "Your last question is still finishing on the server (it was stopped at the time budget): ask again in a moment"


def public_questions() -> Int:
    """The public copy's questions at once on the whole server (MOJOUI_QUESTIONS, 2), each counted until the engine ends
    it, even past a stop (the engine's joins, set operations, subqueries and sorts have no stop checks yet); 0 on a
    desktop: no limit."""
    if environment("MOJOUI_PUBLIC") != "1":
        return 0
    try:
        return max(1, Int(environment("MOJOUI_QUESTIONS", "2")))
    except:
        return 2


def public_answer_bytes() -> Int:
    """The most one public answer may take (MOJOUI_ANSWER_MB, 64 MB at 8 bytes a cell)."""
    try:
        return Int(environment("MOJOUI_ANSWER_MB", "64")) << 20
    except:
        return 64 << 20


def visitor_table_bytes() -> Int:
    """A visitor's tables and answers together on the public copy (MOJOUI_VISITOR_TABLES_MB, 384, as the host's uploads)."""
    try:
        return Int(environment("MOJOUI_VISITOR_TABLES_MB", "384")) << 20
    except:
        return 384 << 20


def public_answers() -> Int:
    """The answer cards a visitor may keep on the public copy (MOJOUI_ANSWERS, 8)."""
    try:
        return max(1, Int(environment("MOJOUI_ANSWERS", "8")))
    except:
        return 8


def table_bytes(t: SharedTable, skip: List[Int]) -> Int:
    """A table's real bytes: 8 a cell (and its nulls), and the words of each TEXT dictionary it holds that isn't in
    `skip` (a dictionary shared with a table it was read from isn't its own), each counted once."""
    var total = 0
    var seen = List[Int]()
    for c in range(t.columns()):
        total += 8 * t.rows() + ((t.rows() + 7) // 8 if t.null_count(c) > 0 else 0)
        if t.kind(c) == TEXT:
            var d = t.dictionary(c)
            var at = Int(d.unsafe_ptr())
            if at in skip or at in seen:
                continue
            seen.append(at)
            for w in d:
                total += w.byte_length() + 32
    return total


def text_growth(text: String) -> Int:
    """Whether a question builds strings longer than the ones it reads: 0 no; 1 by joining them (||, CONCAT, a CAST);
    2 by a REPLACE (one at most on the public copy: public_refusal)."""
    var words = sql_words(text)
    var out = 0
    for w in words:
        if w == "REPLACE":
            return 2
        if w == "CONCAT" or w == "CAST":
            out = 1
    if out == 0 and (text.find("||") >= 0 or text.find("::") >= 0):
        out = 1
    return out


def answer_width(text: String, star: Int) -> Int:
    """The columns a SELECT's answer may have, estimated from its text before it runs: the most items of any of its
    select lists (a subquery's `SELECT *` passes its inner list's columns up: round 5), a `*` or `t.*` counting `star`
    (every column the question can see); outside quotes and comments."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var depth = 0
    var depths = List[Int]()  # the open select lists: their depth, items and stars
    var items = List[Int]()
    var stars = List[Int]()
    var most = 1
    while i < n:
        var c = Int(b[i])
        if c == 45 and i + 1 < n and Int(b[i + 1]) == 45:
            while i < n and Int(b[i]) != 10:
                i += 1
            continue
        if c == 47 and i + 1 < n and Int(b[i + 1]) == 42:
            i += 2
            while i + 1 < n and not (Int(b[i]) == 42 and Int(b[i + 1]) == 47):
                i += 1
            i += 2
            continue
        if c == 39 or c == 34 or c == 96:
            i += 1
            while i < n and Int(b[i]) != c:
                i += 1
            i += 1
            continue
        var top = len(depths) - 1
        if c == 40:
            depth += 1
        elif c == 41:
            depth -= 1
            while len(depths) > 0 and depths[len(depths) - 1] > depth:
                _ = depths.pop()
                _ = items.pop()
                _ = stars.pop()
        elif top >= 0 and depths[top] == depth and c == 44:
            items[top] += 1
        elif top >= 0 and depths[top] == depth and c == 42:
            stars[top] += 1
        elif is_word_byte(c):
            var j = i
            while j < n and is_word_byte(Int(b[j])):
                j += 1
            var w = String(text[byte = i : j]).upper()
            if w == "SELECT":
                depths.append(depth)
                items.append(1)
                stars.append(0)
            elif w == "FROM" and top >= 0 and depths[top] == depth:
                most = max(most, items[top] - stars[top] + stars[top] * max(star, 1))
                _ = depths.pop()
                _ = items.pop()
                _ = stars.pop()
            i = j
            continue
        i += 1
    for k in range(len(depths)):  # (a SELECT with no FROM)
        most = max(most, items[k] - stars[k] + stars[k] * max(star, 1))
    return most


def public_threads() -> Int:
    """The cores one public question may use (MOJOUI_QUERY_THREADS, 2: a shared server's other visitors keep the rest);
    0 on a desktop: every core."""
    if environment("MOJOUI_PUBLIC") != "1":
        return 0
    try:
        return max(1, Int(environment("MOJOUI_QUERY_THREADS", "2")))
    except:
        return 2


def public_sort_bytes() -> Int:
    """The bytes a public question's sort holds before it spills to disk (MOJOUI_SORT_BYTES, 256 MB); 0 on a desktop:
    the engine's own (2 GB)."""
    if environment("MOJOUI_PUBLIC") != "1":
        return 0
    try:
        return max(1 << 20, Int(environment("MOJOUI_SORT_BYTES", String(256 << 20))))
    except:
        return 256 << 20


def questions_running() -> Int:
    """The questions the engine is running in this process now (counted on the public copy only)."""
    return count_of(SLOT_QUESTIONS)


def take_question() raises -> Bool:
    """A place among the server's questions (public copy): True when one was taken (give_back_question once the engine
    has ended). A full server is waited on for up to MOJOUI_QUESTION_WAIT_S (10 s: the story's questions take well
    under a second), then this raises in plain words; False on a desktop (nothing counted)."""
    var most = public_questions()
    if most <= 0:
        return False
    var wait_s = 10.0
    try:
        wait_s = Float64(Int(environment("MOJOUI_QUESTION_WAIT_S", "10")))
    except:
        pass
    var t0 = now_ns()
    while True:
        if count_add(SLOT_QUESTIONS, 1) < most:
            return True
        _ = count_add(SLOT_QUESTIONS, -1)
        if Float64(now_ns() - t0) / 1e9 >= wait_s:
            raise Error(BUSY_WORDS)
        sleep(0.02)


def give_back_question(held: Bool):
    if held:
        _ = count_add(SLOT_QUESTIONS, -1)
