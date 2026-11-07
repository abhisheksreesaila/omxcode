# mojoui.starter: a starter, a folder of data with a story.json that says what it is, which an app offers on its Start
# screen (goal 62: the robot story on the hosted copy). Its tables are read once per process: App.init_shared() calls
# share_starter(folder), and every later read_table (mojoui.csvio) of one of its files, in any session or job, gets the
# same read-only columns (omxcore's SharedTable: shared by reference count) instead of reading the file again. A
# session's edits land in its own Frame overlay; nothing writes to the shared columns or to the files.
#
#   @staticmethod
#   def init_shared():
#       _ = share_starter(environment("OMX_STARTER"))          # (no folder: nothing)
#   var s = Starter.read(folder)                              # its words, files, links and questions
#   s.path(s.sheet)  → folder + "/fleet.csv"
#
# story.json: {"title", "start", "lead", "credit", "license", "source", "sheet": "fleet.csv", "tables": ["telemetry.parquet"],
#              "documents": "docs", "links": ["fleet.episode = telemetry.episode", …], "hero": "F00118",
#              "questions": [{"name": "regrasped", "question": "failures where…", "sql": "SELECT …"}, …]}

from mojoui.json import Json
from mojoui.csvio import share_file
from mojoui.shared import environment, exit_with


@fieldwise_init
struct Question(Copyable, Movable):
    """One of the story's questions: its words, the SQL that answers it, and the name its answer takes."""

    var name: String
    var question: String
    var sql: String


struct Starter(Copyable, Movable):
    var folder: String  # "": no starter
    var title: String
    var start: String  # the Start screen's button ("Start the story")
    var lead: String
    var credit: String
    var license: String
    var source: String
    var sheet: String  # the file the sheet opens (relative to the folder)
    var tables: List[String]  # files that become table cards
    var documents: String  # a folder of documents ("": none)
    var links: List[String]  # typed links (mojoui.links), in order
    var hero: String  # the row the story opens on: the first cell that equals it, in the sheet's first column
    var questions: List[Question]

    def __init__(out self):
        self.folder = ""
        self.title = ""
        self.start = "Start the story"
        self.lead = ""
        self.credit = ""
        self.license = ""
        self.source = ""
        self.sheet = ""
        self.tables = List[String]()
        self.documents = ""
        self.links = List[String]()
        self.hero = ""
        self.questions = List[Question]()

    @staticmethod
    def read(folder: String) raises -> Starter:
        """The starter in `folder` (its story.json); raises when there's none or it isn't one."""
        var s = Starter()
        s.folder = String(folder.rstrip("/"))
        var j = Json.parse(open(s.folder + "/story.json", "r").read())
        s.title = j.text(j.get(0, "title"))
        s.start = j.text(j.get(0, "start"), "Start the story")
        s.lead = j.text(j.get(0, "lead"))
        s.credit = j.text(j.get(0, "credit"))
        s.license = j.text(j.get(0, "license"))
        s.source = j.text(j.get(0, "source"))
        s.sheet = j.text(j.get(0, "sheet"))
        s.documents = j.text(j.get(0, "documents"))
        s.hero = j.text(j.get(0, "hero"))
        var t = j.get(0, "tables")
        for k in range(j.size(t) if t >= 0 else 0):
            s.tables.append(j.text(j.at(t, k)))
        var l = j.get(0, "links")
        for k in range(j.size(l) if l >= 0 else 0):
            s.links.append(j.text(j.at(l, k)))
        var q = j.get(0, "questions")
        for k in range(j.size(q) if q >= 0 else 0):
            var n = j.at(q, k)
            s.questions.append(Question(j.text(j.get(n, "name"), "Question " + String(k + 1)), j.text(j.get(n, "question")), j.text(j.get(n, "sql"))))
        if s.title == "" or s.sheet == "":
            raise Error("story.json names no title or sheet")
        for name in s.files():
            if name.startswith("/") or name.find("..") >= 0:
                raise Error("story.json names a file outside its folder: " + name)
        return s^

    def files(self) -> List[String]:
        """Its sheet, its tables and its documents folder, by their names in story.json."""
        var out = List[String]()
        out.append(self.sheet)
        for t in self.tables:
            out.append(t)
        if self.documents != "":
            out.append(self.documents)
        return out^

    def has(self) -> Bool:
        return self.folder != ""

    def path(self, name: String) -> String:
        """A file of the starter, by its name in story.json."""
        return self.folder + "/" + name


def share_starter(folder: String) -> Int:
    """App.init_shared(): the starter's sheet and tables read once for the whole process (mojoui.csvio.share_file);
    how many files it shared (0: no folder, or not a starter: said on stdout)."""
    if folder == "":
        return 0
    try:
        var s = Starter.read(folder)
        var n = 0
        var names = List[String]()
        names.append(s.sheet)
        for t in s.tables:
            names.append(t)
        for name in names:
            var rows = share_file(s.path(name))
            print("STARTER: shared " + name + " (" + String(rows) + " rows)", flush=True)
            n += 1
        return n
    except e:
        print("STARTER: not loaded: " + String(e), flush=True)
        if environment("MOJOUI_PUBLIC") == "1":  # (a public copy without its shared starter would read it once a visitor)
            print("STARTER: a public copy needs its starter: stopping", flush=True)
            exit_with(1)
        return 0
