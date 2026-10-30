# Jot (goal 42): a tiny notes app that keeps your data. Notes live in SQLite ($JOT_DB, default <config>/jot/jot.db):
# notes(id, title, body, updated) and an FTS5 index notes_fts kept in step by triggers. The list shows the notes (or
# what the search finds, as you type, every word a prefix); the editor's first line is the note's title. Typing is
# saved a moment after you stop, and at once before anything that reads the file (search, New, Delete, Export).
#
# Every change of state prints one line:   JOT: notes=<n> results=<n> open="<title>"
# each search:                             JOT SEARCH: q=<typed> results=<n> ms=<time>
# JOT_SEED=<n>: makes the file hold n generated notes, inserted by a background job (mojoui.jobs) while the window
# keeps drawing; it prints `JOT SEED: done <n> notes in <ms> ms` when it ends.

from mojoui import (
    App, Event, View, VStack, HStack, Text, Button, FilePicker, FileSaver, TextField, TextArea, LazyList, ProgressBar, Spacer, Divider,
    CAPTION, HEADLINE, PROMINENT, SUBTLE, PLAIN, DESTRUCTIVE, CENTER, NO_MSG,
)
from mojoui.effects import Every
from mojoui.dragdrop import DropTarget
from mojoui.paragraph import Paragraph, Run, Plain, Bold
from mojoui.jobs import start_ui_job
from mojoui.clock import now_ns
from mojoui.shared import environment, make_dir
from mojoui.files import config_dir
from mojoui.sqlite import Database, Statement, fts_prefix_query
from mojoui.theme import Theme
from themes.liquid import liquid
from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from std.collections import Dict
from std.ffi import external_call

comptime NEW = 1
comptime DELETE = 2
comptime SEARCH = 3
comptime EDIT = 4
comptime OPEN = 5
comptime SAVE_TICK = 6
comptime SEED_TICK = 7
comptime LANDED = 8
comptime IMPORT = 9
comptime EXPORT = 10
comptime DROPPED = 11
comptime NOTES = 1  # the LazyList's id
comptime SAVE_AFTER_MS = 400
comptime SEED_DELAY_MS = 600  # the window opens with what the file holds; the seed starts a moment later (D-1310)


def first_line(body: String) -> String:
    var nl = body.find("\n")
    var line = String(body[byte=:nl]) if nl >= 0 else body
    return String(line.strip())


def now_s() -> Int:
    return external_call["time", Int](0)



def open_notes(path: String) raises -> Database:
    """The notes file, with its tables made if it's new (WAL: a job may write while the window reads, D-1306)."""
    var db = Database(path)
    db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL")
    db.exec("""CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', updated INTEGER NOT NULL DEFAULT 0);
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(title, body, content='notes', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
        CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body); END;
        CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;""")
    return db^


# ---- seeding: generated notes that read like real ones, written by a job on its own connection

def subjects() -> List[String]:
    return [
        "Groceries", "Trip plan", "Meeting notes", "Book ideas", "Recipe", "Garden", "Workout", "Budget", "Reading list",
        "Gift ideas", "Project kickoff", "Car service", "Weekend", "Podcast notes", "Dentist", "Birthday party", "Moving house",
        "Language lessons", "Bike repair", "Photography", "Quarterly review", "Interview prep", "Holiday cards", "Bathroom paint",
    ]
def details() -> List[String]:
    return [
        "flights to Lisbon in May", "milk, eggs and lemons", "budget review with Priya", "a mystery set in Kyoto",
        "lentil soup with smoked paprika", "tomatoes need staking", "intervals on Tuesday and Thursday", "cancel the gym trial",
        "Piranesi and Dune next", "a fountain pen for Sam", "timeline and owners", "brakes squeak at low speed",
        "hike above Grasmere", "episode about tidal energy", "cleaning at half past nine", "balloons and a chocolate cake",
        "boxes from the hardware store", "irregular Portuguese verbs", "new chain and brake pads", "golden hour by the harbour",
        "revenue up eleven percent", "practise the system design question", "addresses from the old spreadsheet",
        "sage green or warm white",
    ]
def endings() -> List[String]:
    return [
        "Remember to check the calendar first.", "Ask Jordan what they think.", "Before Friday if possible.",
        "Keep the receipt.", "Compare three prices.", "Write it up afterwards.", "Not urgent.", "Book it this week.",
    ]


struct Words(Movable):
    var subjects: List[String]
    var details: List[String]
    var endings: List[String]

    def __init__(out self):
        self.subjects = subjects()
        self.details = details()
        self.endings = endings()

    def note(self, i: Int) -> Tuple[String, String]:
        """Note i's title and body (the same for the same i)."""
        var title = self.subjects[(i * 7919) % len(self.subjects)] + ": " + self.details[(i * 104729 + 13) % len(self.details)]
        return (title, title + "\n" + self.endings[(i * 31 + 5) % len(self.endings)] + " Note " + String(i + 1) + ".")


def gallery_notes() -> List[String]:
    """JOT_SCENE=gallery: a dozen notes a person might keep (the gallery's screenshots)."""
    return [
        "Trip plan: Lisbon in May\nFlights booked for the 14th. Tram 28 up to Alfama on the first morning, pastéis in Belém, a day trip to Sintra.",
        "Groceries\nMilk, eggs, sourdough, lemons, smoked paprika, two tins of chickpeas.",
        "Book club: Piranesi\nMeet at Ana's on Thursday. Bring the question about the statues.",
        "Lisbon restaurants\nTaberna da Rua das Flores (no bookings, go early). Cervejaria Ramiro for seafood.",
        "Garden\nStake the tomatoes; the basil wants more sun. Order bulbs before October.",
        "Quarterly review notes\nRevenue up eleven percent. Hire a second designer. Ship the import tool.",
        "Recipe: lentil soup\nOnion, carrot, red lentils, cumin, smoked paprika, lemon at the end.",
        "Gift ideas\nA fountain pen for Sam, the Kyoto mystery for Priya, plants for the new flat.",
        "Portuguese phrases\nObrigado / obrigada. Uma bica, por favor. Onde fica o elétrico 28?",
        "Bike repair\nNew chain and brake pads; the rear wheel is slightly out of true.",
        "Podcast notes: tidal energy\nThe Orkney turbines; why the Bay of Fundy is the record.",
        "Packing list for Lisbon\nComfortable shoes for the hills, a light jacket, adapters, the guidebook.",
    ]


struct Seed(JobBody):
    """Fills the file up to `want` notes, 500 to a transaction (the window's connection reads between them)."""
    comptime Out = Int
    var path: String
    var want: Int

    def __init__(out self, path: String, want: Int):
        self.path = path
        self.want = want

    def run(mut self, ctl: JobCtl) raises -> Int:
        var db = open_notes(self.path)
        var have = db.count("SELECT count(*) FROM notes")
        ctl.add_total(max(self.want - have, 0))
        var ins = db.prepare("INSERT INTO notes(title, body, updated) VALUES (?, ?, ?)")
        var t = now_s()
        var words = Words()
        var i = have
        while i < self.want:
            ctl.check()
            db.begin()
            var end = min(i + 500, self.want)
            for k in range(i, end):
                var note = words.note(k)
                ins.bind(1, note[0])
                ins.bind(2, note[1])
                ins.bind(3, t - (self.want - k) * 60)
                ins.run()
            db.commit()
            ctl.advance(end - i)
            i = end
        return self.want


struct Main(App):
    var db: Optional[Database]
    var path: String
    var problem: String
    var titles: Dict[Int, String]  # every note's title, by id (the list's rows)
    var ids: List[Int]  # the list: every note, or the search's results, newest first
    var all: Int  # how many notes the file holds
    var query: String
    var open_id: Int  # the note in the editor (0: none)
    var body: String
    var dirty: Bool
    var typed_at: Int
    var last: String  # the last JOT: line printed
    var seed_want: Int
    var seed: Optional[Job[Int]]
    var seed_t0: Int
    var seed_done: Int
    var seed_total: Int
    var made_at: Int
    var snippet: List[Run]  # while searching: the open note's best passage, the words found in bold

    def __init__(out self):
        self.snippet = List[Run]()
        self.made_at = now_ns()
        self.db = None
        self.path = environment("JOT_DB", "")
        if self.path == "":
            make_dir(config_dir("jot"))
            self.path = config_dir("jot") + "/jot.db"
        self.problem = ""
        self.titles = Dict[Int, String]()
        self.ids = List[Int]()
        self.all = 0
        self.query = ""
        self.open_id = 0
        self.body = ""
        self.dirty = False
        self.typed_at = 0
        self.last = ""
        self.seed = None
        self.seed_t0 = 0
        self.seed_done = 0
        self.seed_total = 0
        try:
            self.seed_want = Int(environment("JOT_SEED", "0"))
        except:
            self.seed_want = 0
        try:
            self.db = open_notes(self.path)
            if environment("JOT_SCENE") == "gallery" and self.db.value().count("SELECT count(*) FROM notes") == 0:
                for body in gallery_notes():
                    _ = self.add(body)
            self.load()
            if len(self.ids) > 0:
                self.show(self.ids[0])
        except e:
            self.problem = String(e)
        self.report()

    def title(self) -> String:
        return "Jot"

    def theme(self) -> Theme:
        return liquid()

    def window_size(self) -> Tuple[Int, Int]:
        return (920, 620)

    def jobs_message(self) -> Int:
        return LANDED

    def every(self) -> List[Every]:
        var out = List[Every]()
        if self.dirty:
            out.append(Every(SAVE_AFTER_MS // 4, SAVE_TICK))
        if self.seed_want > 0:
            out.append(Every(50, SEED_TICK))
        return out^

    # ---- the file

    def load(mut self) raises:
        """Every note's id and title from the file, newest first, then the search again."""
        self.titles = Dict[Int, String]()
        var q = self.db.value().prepare("SELECT id, title FROM notes ORDER BY id")
        while q.step():
            self.titles[q.int(0)] = q.text(1)
        self.all = len(self.titles)
        self.search()

    def search(mut self) raises:
        var ids = List[Int]()
        var wanted = fts_prefix_query(self.query)
        if wanted == "":
            for id in self.titles.keys():
                ids.append(id)
        else:
            var q = self.db.value().prepare("SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?")
            q.bind(1, wanted)
            while q.step():
                ids.append(q.int(0))
        sort(ids)
        ids.reverse()
        self.ids = ids^

    def mark(mut self) raises:
        """The open note's passage that matches the search, its found words in bold (FTS5's snippet()). Made when a
        result is opened, not as you type: a Paragraph whose runs change rebuilds its stack, and a rebuild while the
        search field is changing swallows the next change (D-1317)."""
        self.snippet = List[Run]()
        var wanted = fts_prefix_query(self.query)
        if wanted == "" or self.open_id == 0:
            return
        var q = self.db.value().prepare("SELECT snippet(notes_fts, -1, char(1), char(2), '…', 14) FROM notes_fts WHERE notes_fts MATCH ? AND rowid = ?")
        q.bind(1, wanted)
        q.bind(2, self.open_id)
        if not q.step():
            return
        var text = q.text(0).replace("\n", " ")
        for part in text.split("\x01"):
            var p = String(part)
            var end = p.find("\x02")
            if end >= 0:
                self.snippet.append(Bold(String(p[byte=:end])))
                var rest = String(p[byte = end + 1 :])
                if rest != "":
                    self.snippet.append(Plain(rest))
            elif p != "":
                self.snippet.append(Plain(p))

    def show(mut self, id: Int) raises:
        var q = self.db.value().prepare("SELECT body FROM notes WHERE id = ?")
        q.bind(1, id)
        if q.step():
            self.open_id = id
            self.body = q.text(0)
        else:
            self.open_id = 0
            self.body = ""

    def save(mut self) raises:
        """The editor's text into its note, now (title = its first line)."""
        if not self.dirty or self.open_id == 0:
            self.dirty = False
            return
        var up = self.db.value().prepare("UPDATE notes SET title = ?, body = ?, updated = ? WHERE id = ?")
        var title = first_line(self.body)
        up.bind(1, title)
        up.bind(2, self.body)
        up.bind(3, now_s())
        up.bind(4, self.open_id)
        up.run()
        self.titles[self.open_id] = title
        self.dirty = False

    def add(mut self, body: String) raises -> Int:
        var ins = self.db.value().prepare("INSERT INTO notes(title, body, updated) VALUES (?, ?, ?)")
        ins.bind(1, first_line(body))
        ins.bind(2, body)
        ins.bind(3, now_s())
        ins.run()
        var id = self.db.value().last_id()
        self.titles[id] = first_line(body)
        self.all = len(self.titles)
        return id

    def delete(mut self, id: Int) raises:
        var del_ = self.db.value().prepare("DELETE FROM notes WHERE id = ?")
        del_.bind(1, id)
        del_.run()
        _ = self.titles.pop(id)
        self.all = len(self.titles)

    def closing(mut self):
        """Quitting: what was typed but not yet saved goes into the file first."""
        var pending = self.dirty
        try:
            self.save()
        except e:
            print("JOT ERROR: " + String(e), flush=True)
        print("JOT QUIT: " + ("saved the open note" if pending else "nothing pending") + "; " + String(self.all) + " notes", flush=True)

    # ---- what happened

    def update(mut self, event: Event):
        if not self.db:
            return
        try:
            self.handle(event)
        except e:
            self.problem = String(e)
            print("JOT ERROR: " + self.problem, flush=True)
        self.report()

    def handle(mut self, event: Event) raises:
        var m = event.message
        if m == EDIT:
            if self.open_id == 0:  # (typing with no note open starts one)
                self.open_id = self.add("")
                self.search()
            self.body = event.text
            self.dirty = True
            self.typed_at = now_ns()
        elif m == SAVE_TICK:
            if self.dirty and now_ns() - self.typed_at >= SAVE_AFTER_MS * 1_000_000:
                self.save()
        elif m == NEW:
            self.save()
            self.snippet = List[Run]()
            self.query = ""
            var id = self.add("")
            self.search()
            self.show(id)
        elif m == DELETE:
            if self.open_id == 0:
                return
            self.dirty = False
            self.snippet = List[Run]()
            var at = 0
            for k in range(len(self.ids)):
                if self.ids[k] == self.open_id:
                    at = k
            self.delete(self.open_id)
            self.search()
            if len(self.ids) > 0:
                self.show(self.ids[min(at, len(self.ids) - 1)])
            else:
                self.open_id = 0
                self.body = ""
        elif m == SEARCH:
            self.save()
            self.query = event.text
            var t0 = now_ns()
            self.search()
            var ms = Float64(now_ns() - t0) / 1e6
            if self.query != "":
                print("JOT SEARCH: q=" + self.query + " results=" + String(len(self.ids)) + " ms=" + String(ms), flush=True)
        elif m == OPEN:
            if event.number >= 0 and event.number < len(self.ids):
                self.save()
                self.show(self.ids[event.number])
                self.mark()
        elif m == IMPORT or m == DROPPED:  # a .md or .txt file becomes a note, byte for byte
            self.save()
            var text: String
            with open(event.text, "r") as f:
                text = f.read()
            self.query = ""
            var id = self.add(text)
            self.search()
            self.show(id)
        elif m == EXPORT:  # the open note into the file the save dialog chose
            self.save()
            if self.open_id != 0:
                with open(event.text, "w") as f:
                    f.write(self.body)
                print("JOT EXPORT: " + String(self.body.byte_length()) + " bytes to " + event.text, flush=True)
        elif m == SEED_TICK:
            self.seeding()
        elif m == LANDED:
            self.seeding()

    def seeding(mut self) raises:
        """Starts the seed on the first tick, shows how far it is, and reads the file again when it ends."""
        if not self.seed:
            if self.seed_t0 == 0 and now_ns() - self.made_at >= SEED_DELAY_MS * 1_000_000:
                self.seed_t0 = now_ns()
                self.seed = start_ui_job(Seed(self.path, self.seed_want))
                print("JOT SEED: start " + String(self.seed_want) + " notes", flush=True)
            return
        var p = self.seed.value().progress()
        self.seed_done = p.done
        self.seed_total = p.total
        if self.seed.value().poll() == JOB_RUNNING:
            return
        var job = self.seed.take()
        var n = job.result()
        self.seed_want = 0
        self.load()
        if self.open_id == 0 and len(self.ids) > 0:
            self.show(self.ids[0])
        print("JOT SEED: done " + String(n) + " notes in " + String(Int(Float64(now_ns() - self.seed_t0) / 1e6)) + " ms", flush=True)

    def report(mut self):
        var line = "JOT: notes=" + String(self.all) + " results=" + String(len(self.ids)) + ' open="' + first_line(self.body) + '"'
        if line != self.last:
            self.last = line
            print(line, flush=True)

    # ---- the screen

    def file_name(self) -> String:
        """The open note's title as a file name (letters, digits, spaces and dashes), .md."""
        var out = String("")
        for c in first_line(self.body).codepoint_slices():
            var ch = String(c)
            var b = ch.as_bytes()[0]
            var word = ch.byte_length() > 1 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
            if word or ch == " " or ch == "-" or ch == "_":
                out += ch
        var name = String(out.strip())
        return (name if name != "" else String("note")) + ".md"

    def row(self, list_id: Int, index: Int) -> String:
        if index < 0 or index >= len(self.ids):
            return ""
        var t = self.titles.get(self.ids[index], String(""))
        return t if t != "" else String("New note")

    def view(self) -> View:
        var count = String(self.all) + (" note" if self.all == 1 else " notes")
        if self.query != "":
            count = String(len(self.ids)) + " of " + count
        var side = List[View]()
        side.append(TextField(self.query, "Search", on_change=SEARCH).fill().tag("search"))
        side.append(Text(count, CAPTION).tag("count"))
        if self.seed_want > 0:
            var share = (self.seed_done * 100) // max(self.seed_total, 1)
            side.append(Text("Adding " + String(self.seed_want) + " notes… " + String(share) + "%", CAPTION))
            side.append(ProgressBar(share))
        side.append(DropTarget(LazyList(len(self.ids), NOTES, on_tap=OPEN, height=440, row_height=44).grow().fill().tag("list"),
                               on_drop=NO_MSG, on_file=DROPPED).grow().fill().tag("notes"))
        var bar = List[View]()
        bar.append(Text("Jot", HEADLINE))
        bar.append(Spacer())
        bar.append(Button("New", NEW, PROMINENT))
        bar.append(Button("Delete", DELETE, SUBTLE))
        bar.append(FilePicker("Import", IMPORT, SUBTLE, accept=".md,.txt"))
        bar.append(FileSaver("Export", EXPORT, suggested=self.file_name(), style=SUBTLE, accept=".md,.txt"))
        var editor = List[View]()
        if self.problem != "":
            editor.append(Text(self.problem, CAPTION).tag("problem"))
        # (always there, " " when nothing was found: one view whose runs change, opened from a result)
        var found = self.snippet.copy() if len(self.snippet) > 0 else [Plain(" ")]
        editor.append(Paragraph(found^, style=CAPTION).tag("found"))
        if self.open_id != 0:
            editor.append(TextArea(self.body, "Start typing: the first line is the title", on_change=EDIT, height=480).grow().fill().tag("editor"))
        else:
            editor.append(Text("No note open. New makes one.", CAPTION))
        return VStack(
            HStack(bar^, spacing=8).fill().align(CENTER).padding(8, 14).tag("toolbar"),
            HStack(
                VStack(side^, spacing=8).width(300).fill().padding(12),
                VStack(editor^, spacing=8).grow().fill().padding(12),
                spacing=0,
            ).grow().fill(),
            spacing=0,
        ).grow().fill()
