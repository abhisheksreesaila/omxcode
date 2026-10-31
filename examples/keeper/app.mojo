# Keeper (goal 45): keeps a folder of notes searchable, and keeps doing it with its window closed. It watches $KEEPER_DIR
# (default ~/Notes; text and Markdown files, every folder under it) with mojoui.watch, keeps a full-text index of them
# in SQLite ($KEEPER_DB, default <config>/keeper/keeper.db: files(path, mtime, size) and the FTS5 table
# files_fts(path, body)), and has a search field and a list of what changed lately. Closing the window leaves it running
# (App.background): the tray item opens it again, and a file mentioning $KEEPER_ALERT's word raises a notification
# (mojoui.notify). Slow work runs as jobs (mojoui.jobs): the first scan, and indexing what changed.
#
# What it prints (docs/goals/45-check.py reads these):
#   KEEPER SCAN: start / KEEPER SCAN: done <n> files in <ms> ms          the scan (new, changed and gone files)
#   KEEPER INDEXED: <path> ms=<lag> at=<ns>                               a changed file is searchable (lag from the
#                                                                         watcher's event, at on the monotonic clock)
#   KEEPER SEARCH: q=<typed> results=<n>                                  each search
#   KEEPER ALERT: <path>                                                  a notification was sent

from mojoui import (
    App, Event, View, VStack, HStack, Text, TextField, LazyList, ProgressBar, Spacer, Icon,
    CAPTION, HEADLINE, CENTER,
)
from mojoui.effects import Every
from mojoui.jobs import start_ui_job
from mojoui.clock import now_ns
from mojoui.shared import environment, make_dir
from mojoui.files import config_dir
from mojoui.sqlite import Database, fts_prefix_query
from mojoui.watch import FolderWatcher, walk_files, file_stamp, CREATED, MODIFIED, RENAMED, DELETED, OVERFLOW
from mojoui.notify import notify
from mojoui.theme import Theme
from themes.liquid import liquid
from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from std.collections import Dict
from std.os import getenv

comptime SEARCH = 1
comptime TICK = 2
comptime LANDED = 3
comptime RESULTS = 1  # the LazyLists' ids
comptime RECENT = 2
comptime SCAN_DELAY_MS = 600  # the window opens with what the index holds; the scan starts a moment later
comptime MAX_BYTES = 2 * 1024 * 1024  # a bigger file is indexed by its first 2 MB
comptime BATCH = 2000  # files per transaction in the scan (the window's connection reads between them)


def kept(name: String) -> Bool:
    """Text and Markdown files."""
    return name.endswith(".md") or name.endswith(".txt") or name.endswith(".markdown")


def suffixes() -> List[String]:
    return [".md", ".txt", ".markdown"]


def open_index(path: String) raises -> Database:
    var db = Database(path)
    db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL")
    db.exec("""CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, mtime INTEGER NOT NULL, size INTEGER NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(path UNINDEXED, body);""")
    return db^


def read_text(path: String) -> String:
    try:
        var data: List[UInt8]
        with open(path, "r") as f:
            data = f.read_bytes(MAX_BYTES)
        return String(from_utf8_lossy=Span(data))
    except:
        return ""


struct Index(Movable):
    """The writes, on one connection (a job's): put a file in, take one out."""
    var db: Database

    def __init__(out self, path: String) raises:
        self.db = open_index(path)

    def put(mut self, path: String, mtime: Int, size: Int, body: String) raises:
        var find = self.db.prepare("SELECT id FROM files WHERE path = ?")
        find.bind(1, path)
        if find.step():
            var id = find.int(0)
            var up = self.db.prepare("UPDATE files SET mtime = ?, size = ? WHERE id = ?")
            up.bind(1, mtime)
            up.bind(2, size)
            up.bind(3, id)
            up.run()
            var del_ = self.db.prepare("DELETE FROM files_fts WHERE rowid = ?")
            del_.bind(1, id)
            del_.run()
            self.text(id, path, body)
            return
        var ins = self.db.prepare("INSERT INTO files(path, mtime, size) VALUES (?, ?, ?)")
        ins.bind(1, path)
        ins.bind(2, mtime)
        ins.bind(3, size)
        ins.run()
        self.text(self.db.last_id(), path, body)

    def text(mut self, id: Int, path: String, body: String) raises:
        var ins = self.db.prepare("INSERT INTO files_fts(rowid, path, body) VALUES (?, ?, ?)")
        ins.bind(1, id)
        ins.bind(2, path)
        ins.bind(3, body)
        ins.run()

    def drop(mut self, path: String, folder: Bool) raises:
        """A file (or every file under a folder) out of the index."""
        var q = self.db.prepare("SELECT id FROM files WHERE path = ? OR (? AND substr(path, 1, ?) = ?)")
        q.bind(1, path)
        q.bind(2, 1 if folder else 0)
        q.bind(3, path.byte_length() + 1)
        q.bind(4, path + "/")
        var ids = List[Int]()
        while q.step():
            ids.append(q.int(0))
        for id in ids:
            var a = self.db.prepare("DELETE FROM files WHERE id = ?")
            a.bind(1, id)
            a.run()
            var b = self.db.prepare("DELETE FROM files_fts WHERE rowid = ?")
            b.bind(1, id)
            b.run()


struct Scan(JobBody):
    """Brings the index in step with the folder: new and changed files in, gone ones out. Returns how many text files
    the folder holds."""
    comptime Out = Int
    var dir: String
    var db: String

    def __init__(out self, dir: String, db: String):
        self.dir = dir
        self.db = db

    def run(mut self, ctl: JobCtl) raises -> Int:
        var ix = Index(self.db)
        var known = Dict[String, Tuple[Int, Int]]()
        var q = ix.db.prepare("SELECT path, mtime, size FROM files")
        while q.step():
            known[q.text(0)] = (q.int(1), q.int(2))
        var files = walk_files(self.dir, suffixes())
        ctl.add_total(len(files))
        var i = 0
        while i < len(files):
            ctl.check()
            ix.db.begin()
            var end = min(i + BATCH, len(files))
            for k in range(i, end):
                var path = files[k]
                var stamp = file_stamp(path)
                var had = known.pop(path, (Int(-1), Int(-1)))
                if had[0] != stamp[0] or had[1] != stamp[1]:
                    ix.put(path, stamp[0], stamp[1], read_text(path))
            ix.db.commit()
            ctl.advance(end - i)
            i = end
        if len(known) > 0:  # (gone while the app wasn't watching)
            ix.db.begin()
            for item in known.items():
                ix.drop(item.key, False)
            ix.db.commit()
        return len(files)


@fieldwise_init
struct Change(Copyable, Movable):
    var kind: Int
    var path: String
    var old_path: String
    var at_ns: Int
    var is_dir: Bool


struct Reindex(JobBody):
    """What the watcher saw, into the index, one transaction; then each changed file's KEEPER INDEXED line (it's
    searchable once committed). Returns the files that mention the alert word, one per line."""
    comptime Out = String
    var db: String
    var changes: List[Change]
    var alert: String

    def __init__(out self, db: String, var changes: List[Change], alert: String):
        self.db = db
        self.changes = changes^
        self.alert = alert.lower()

    def run(mut self, ctl: JobCtl) raises -> String:
        var ix = Index(self.db)
        var done = List[Change]()
        var alerts = String("")
        ix.db.begin()
        for c in self.changes:
            if c.kind == DELETED:
                ix.drop(c.path, c.is_dir)
                continue
            if c.kind == RENAMED:
                ix.drop(c.old_path, False)
            var name = String(c.path[byte = c.path.rfind("/") + 1 :])
            if not kept(name):
                continue
            var stamp = file_stamp(c.path)
            if stamp[1] < 0:
                continue  # (gone again already)
            var body = read_text(c.path)
            ix.put(c.path, stamp[0], stamp[1], body)
            done.append(c.copy())
            if self.alert != "" and body.lower().find(self.alert) >= 0:
                alerts += c.path + "\n"
        ix.db.commit()
        for c in done:
            var at = now_ns()
            print("KEEPER INDEXED: " + c.path + " ms=" + String(Float64(at - c.at_ns) / 1e6) + " at=" + String(at), flush=True)
        return alerts


struct Main(App):
    var dir: String
    var path: String
    var alert: String
    var db: Optional[Database]
    var watcher: FolderWatcher
    var problem: String
    var made_at: Int
    var scan: Optional[Job[Int]]
    var scan_t0: Int
    var scanned: Bool
    var scan_done: Int
    var scan_total: Int
    var files: Int  # how many files the index holds
    var waiting: List[Change]  # what the watcher saw, not yet indexed
    var reindex: Optional[Job[String]]
    var query: String
    var found: List[String]
    var found_count: Int
    var recent: List[String]  # changed lately, newest first
    var recent_at: List[Int]
    var shown: Bool

    def __init__(out self):
        self.dir = environment("KEEPER_DIR", "")
        if self.dir == "":
            self.dir = getenv("HOME") + "/Notes"
        self.path = environment("KEEPER_DB", "")
        if self.path == "":
            make_dir(config_dir("keeper"))
            self.path = config_dir("keeper") + "/keeper.db"
        self.alert = environment("KEEPER_ALERT", "")
        self.db = None
        self.problem = ""
        self.made_at = now_ns()
        self.scan = None
        self.scan_t0 = 0
        self.scanned = False
        self.scan_done = 0
        self.scan_total = 0
        self.files = 0
        self.waiting = List[Change]()
        self.reindex = None
        self.query = ""
        self.found = List[String]()
        self.found_count = 0
        self.recent = List[String]()
        self.recent_at = List[Int]()
        self.shown = True
        make_dir(self.dir)
        self.watcher = FolderWatcher(self.dir, wake=True)  # (watching from the start: what changes during the scan isn't missed)
        self.watcher.start()
        try:
            self.db = open_index(self.path)
            self.files = self.db.value().count("SELECT count(*) FROM files")
        except e:
            self.problem = String(e)

    def title(self) -> String:
        return "Keeper"

    def theme(self) -> Theme:
        return liquid()

    def window_size(self) -> Tuple[Int, Int]:
        return (980, 640)

    def background(self) -> Bool:
        return True  # (Keeper's point: it keeps the folder searchable with its window closed)

    def window_shown(mut self, shown: Bool):
        self.shown = shown
        print("KEEPER WINDOW: " + ("open" if shown else "closed, still keeping " + self.dir), flush=True)

    def jobs_message(self) -> Int:
        return LANDED  # (a job ended, or the watcher saw something: mojoui.watch wakes the same pipe)

    def every(self) -> List[Every]:
        var out = List[Every]()
        if not self.scanned:
            out.append(Every(100, TICK))  # (the scan's start, then its progress bar)
        return out^

    def closing(mut self):
        self.watcher.stop()

    def update(mut self, event: Event):
        try:
            var m = event.message
            if m == SEARCH:
                self.query = event.text
                self.search()
                if self.query != "":
                    print("KEEPER SEARCH: q=" + self.query + " results=" + String(self.found_count), flush=True)
            elif m == TICK or m == LANDED:
                self.step()
        except e:
            self.problem = String(e)
            print("KEEPER ERROR: " + self.problem, flush=True)

    def step(mut self) raises:
        """The scan's start and end, what the watcher saw, a finished reindex: whatever is due now."""
        for e in self.watcher.take():
            if e.kind == OVERFLOW:
                self.scanned = False  # (the system dropped events: scan again)
                self.scan_t0 = 0
                continue
            self.waiting.append(Change(e.kind, e.path, e.old_path, e.at_ns, e.is_dir))
        if not self.scan and not self.scanned and self.scan_t0 == 0 and now_ns() - self.made_at >= SCAN_DELAY_MS * 1_000_000:
            self.scan_t0 = now_ns()
            self.scan = start_ui_job(Scan(self.dir, self.path))
            print("KEEPER SCAN: start " + self.dir, flush=True)
        if self.scan:
            var p = self.scan.value().progress()
            self.scan_done = p.done
            self.scan_total = p.total
            if self.scan.value().poll() != JOB_RUNNING:
                var job = self.scan.take()
                var n = job.result()
                self.scanned = True
                self.files = self.db.value().count("SELECT count(*) FROM files")
                print("KEEPER SCAN: done " + String(n) + " files in " + String(Int(Float64(now_ns() - self.scan_t0) / 1e6)) + " ms", flush=True)
                self.search()
        if self.reindex and self.reindex.value().poll() != JOB_RUNNING:
            var job = self.reindex.take()
            var alerts = job.result()
            for line in alerts.split("\n"):
                var path = String(line)
                if path == "":
                    continue
                var name = String(path[byte = path.rfind("/") + 1 :])
                notify("Keeper", name + " mentions " + self.alert, path)
                print("KEEPER ALERT: " + path, flush=True)
            self.files = self.db.value().count("SELECT count(*) FROM files")
            self.search()
        if not self.reindex and len(self.waiting) > 0 and self.scanned:
            var batch = self.waiting^
            self.waiting = List[Change]()
            var now = now_ns()
            for c in batch:
                if c.kind != DELETED and not c.is_dir:
                    self.recent.insert(0, c.path)
                    self.recent_at.insert(0, now)
            while len(self.recent) > 50:
                _ = self.recent.pop()
                _ = self.recent_at.pop()
            self.reindex = start_ui_job(Reindex(self.path, batch^, self.alert))

    def search(mut self) raises:
        self.found = List[String]()
        self.found_count = 0
        var wanted = fts_prefix_query(self.query)
        if wanted == "":
            return
        var c = self.db.value().prepare("SELECT count(*) FROM files_fts WHERE files_fts MATCH ?")
        c.bind(1, wanted)
        if c.step():
            self.found_count = c.int(0)
        var q = self.db.value().prepare("SELECT path FROM files_fts WHERE files_fts MATCH ? ORDER BY rank LIMIT 500")
        q.bind(1, wanted)
        while q.step():
            self.found.append(q.text(0))

    def short(self, path: String) -> String:
        return String(path[byte = self.dir.byte_length() + 1 :]) if path.startswith(self.dir + "/") else path

    def row(self, list_id: Int, index: Int) -> String:
        if list_id == RESULTS and index >= 0 and index < len(self.found):
            return self.short(self.found[index])
        if list_id == RECENT and index >= 0 and index < len(self.recent):
            var s = Int(Float64(now_ns() - self.recent_at[index]) / 1e9)
            var when = String("just now") if s < 10 else (String(s) + " s ago" if s < 120 else String(s // 60) + " min ago")
            return self.short(self.recent[index]) + "  ·  " + when
        return ""

    def view(self) -> View:
        var status: String
        if not self.scanned and self.scan_total > 0:
            status = "Reading " + String(self.scan_total) + " files… " + String((self.scan_done * 100) // max(self.scan_total, 1)) + "%"
        elif not self.scanned:
            status = "Looking through the folder…"
        else:
            status = "Watching " + String(self.files) + " files, also with the window closed"
        var left = List[View]()
        left.append(TextField(self.query, "Search", on_change=SEARCH).fill().tag("search"))
        if self.query != "":
            left.append(Text(String(self.found_count) + (" file" if self.found_count == 1 else " files") + " mention it", CAPTION).tag("count"))
        else:
            left.append(Text("Search every note in " + self.dir, CAPTION).tag("count"))
        left.append(LazyList(len(self.found), RESULTS, height=440, row_height=40).grow().fill().tag("results"))
        var right = List[View]()
        right.append(Text("Changed lately", HEADLINE))
        if len(self.recent) == 0:
            right.append(Text("Nothing yet. Edit a note and it shows here, even with the window closed.", CAPTION))
        right.append(LazyList(len(self.recent), RECENT, height=440, row_height=40).grow().fill().tag("recent"))
        var bar = List[View]()
        bar.append(Icon("book-open", 20))
        bar.append(Text("Keeper", HEADLINE))
        bar.append(Spacer())
        bar.append(Text(status, CAPTION).tag("status"))
        var top = List[View]()
        top.append(HStack(bar^, spacing=10).fill().align(CENTER).padding(10, 16).tag("toolbar"))
        if not self.scanned and self.scan_total > 0:
            top.append(ProgressBar((self.scan_done * 100) // max(self.scan_total, 1)).fill().padding(0, 16))
        if self.problem != "":
            top.append(Text(self.problem, CAPTION).padding(0, 16).tag("problem"))
        top.append(HStack(
            VStack(left^, spacing=8).grow().fill().padding(12),
            VStack(right^, spacing=8).width(340).fill().padding(12),
            spacing=0,
        ).grow().fill())
        return VStack(top^, spacing=0).grow().fill()
