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

from omxcore import Job, JobBody, JobCtl, Catalog, Table, JOB_RUNNING
from mojoui.jobs import start_ui_job
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
        var cap = public_rows()
        var held = take_question()  # (public: one of the server's places for questions, held until the engine ends, even past a stop)
        var table: Table
        try:
            table = query_table(catalog, capped_sql(self.text, cap), ctl, public_join_bytes(), public_threads(), public_sort_bytes())
        except e:  # (the engine's words for a join past its budget name its options: the visitor gets plain ones)
            give_back_question(held)
            if cap > 0 and String(e).find("join_budget") >= 0:
                raise Error("this question's join would take more memory than the web copy gives one question: join on a key with fewer matches, or filter first")
            raise e^
        give_back_question(held)
        if cap > 0 and table.rows() > cap:  # (the public copy keeps no answer over its cap: memory a visitor can't take from others)
            raise Error("the answer has more than " + grouped(cap) + " rows, more than the web copy keeps: ask for fewer (a filter, a GROUP BY or a LIMIT)")
        var answer = Sheet(table^.share(), False)
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
        var most = public_questions()
        if most > 0 and questions_running() >= most:  # (QueryJob takes its place for sure: this says so before it starts)
            self.problem = BUSY_WORDS
            return False
        var refused = public_refusal(text)
        if refused != "":
            self.problem = refused
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
    has ended); raises in plain words when the server is answering its most; False on a desktop (nothing counted)."""
    var most = public_questions()
    if most <= 0:
        return False
    if count_add(SLOT_QUESTIONS, 1) >= most:
        _ = count_add(SLOT_QUESTIONS, -1)
        raise Error(BUSY_WORDS)
    return True


def give_back_question(held: Bool):
    if held:
        _ = count_add(SLOT_QUESTIONS, -1)
