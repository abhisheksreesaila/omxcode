# mojoui.migrate: versioned schema migrations for SQLite files (goal 60 M2; fh-saas's utils_migrate), for one file or
# every tenant's. Files are `NNN_name.sql` with an `-- up` and a `-- down` section (fh-saas's `-- UP --` / `-- DOWN --`
# read too). Applied versions are kept in the file's `schema_migrations(version, name, checksum, applied)`, each with the
# SHA-256 of its file as applied.
#
#   var m = Migrations.from_dir("migrations/tenant")         # sorted by version; a gap or a duplicate raises
#   m.verify(db)          # raises when an applied migration's file was edited or is gone
#   m.dry_run(db)         # the pending ones on an in-memory copy of the file's schema: raises on SQL that can't apply
#   _ = m.apply(db)       # verify, then every pending one in one transaction: all or none; the number applied
#   m.rollback(db, to=1)  # downs, newest first, in one transaction (never run by a server on its own)
#
# Many files (a tenant each): `apply_all(m, paths)` verifies and dry-runs every file before it changes any, then
# applies file by file, each in its own transaction. A failure that only real rows can cause (a UNIQUE index over
# duplicates) stops at that file with the earlier ones applied: the error names it, and starting again resumes.

from std.os import listdir
from std.os.path import exists
from mojoui.sqlite import Database
from mojoui.hash import sha256_hex
from mojoui.clock import wall_seconds

def _table_sql(table: String) -> String:
    return "CREATE TABLE IF NOT EXISTS " + table + "(version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL, applied INTEGER NOT NULL)"


@fieldwise_init
struct Migration(Copyable, Movable):
    var version: Int
    var name: String
    var up: String
    var down: String
    var checksum: String


def _marker(line: String) -> String:
    """"up" / "down" for a section line (`-- up`, `-- UP --`), else ""."""
    var s = line.strip()
    if not s.startswith("--"):
        return ""
    var word = String(s[byte = 2 :]).strip().lower()
    if word.endswith("--"):
        word = String(String(word[byte = : word.byte_length() - 2]).strip())
    if word == "up" or word == "down":
        return word
    return ""


def parse(version: Int, name: String, text: String) raises -> Migration:
    var up = String("")
    var down = String("")
    var at = String("")
    for raw in text.split("\n"):
        var line = String(raw)
        var m = _marker(line)
        if m != "":
            at = m
            continue
        if at == "up":
            up += line + "\n"
        elif at == "down":
            down += line + "\n"
    if up.strip() == "":
        raise Error("migrate: " + name + " has no `-- up` section")
    return Migration(version, name, up, down, sha256_hex(text))


struct Migrations(Copyable, Movable):
    var list: List[Migration]
    var table: String  # where a file keeps its applied versions (a module sharing a file uses its own: accounts_migrations)

    def __init__(out self, var list: List[Migration], table: String = "schema_migrations"):
        self.list = list^
        self.table = table

    @staticmethod
    def from_dir(dir: String) raises -> Migrations:
        var found = List[Migration]()
        if not exists(dir):
            raise Error("migrate: no folder " + dir)
        for entry in listdir(dir):
            var f = String(entry)
            if not f.endswith(".sql") or f.byte_length() < 8 or String(f[byte = 3 : 4]) != "_":
                continue
            var digits = String(f[byte = : 3])
            var v: Int
            try:
                v = atol(digits)
            except:
                continue
            var text: String
            with open(dir + "/" + f, "r") as h:
                text = h.read()
            found.append(parse(v, f, text))
        for i in range(1, len(found)):  # (by version; a handful of files)
            var j = i
            while j > 0 and found[j - 1].version > found[j].version:
                found.swap_elements(j - 1, j)
                j -= 1
        for i in range(len(found)):
            if found[i].version != i + 1:
                raise Error("migrate: versions must run 1, 2, 3… without gaps or repeats (" + found[i].name + ")")
        return Migrations(found^)

    def top(self) -> Int:
        return len(self.list)

    def applied(self, db: Database) raises -> List[Int]:
        db.exec(_table_sql(self.table))
        var q = db.prepare("SELECT version, checksum FROM " + self.table + " ORDER BY version")
        var out = List[Int]()
        while q.step():
            out.append(q.int(0))
        return out^

    def verify(self, db: Database) raises:
        """Every applied migration still has its file, unchanged (else raises, naming it)."""
        db.exec(_table_sql(self.table))
        var q = db.prepare("SELECT version, name, checksum FROM " + self.table + " ORDER BY version")
        while q.step():
            var v = q.int(0)
            if v < 1 or v > len(self.list):
                raise Error("migrate: version " + String(v) + " (" + q.text(1) + ") was applied but its file is gone")
            if self.list[v - 1].checksum != q.text(2):
                raise Error("migrate: " + self.list[v - 1].name + " was edited after it was applied (checksum differs): add a new migration instead")

    def _current(self, db: Database) raises -> Int:
        db.exec(_table_sql(self.table))
        return db.count("SELECT COALESCE(MAX(version), 0) FROM " + self.table)

    def dry_run(self, db: Database) raises:
        """The pending migrations, applied to an in-memory copy of the file's schema (no rows): raises with SQLite's
        message when one can't apply."""
        var cur = self._current(db)
        if cur >= len(self.list):
            return
        var mem = Database(":memory:")
        var q = db.prepare("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name != '" + self.table + "' ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 1 ELSE 2 END, rowid")
        while q.step():
            mem.exec(q.text(0))
        for i in range(cur, len(self.list)):
            try:
                mem.exec(self.list[i].up)
            except e:
                raise Error("migrate: " + self.list[i].name + " can't apply: " + String(e))

    def apply(self, db: Database) raises -> Int:
        """Verify, then every pending migration in one transaction (all or none). The number applied."""
        self.verify(db)
        var cur = self._current(db)
        if cur >= len(self.list):
            return 0
        db.begin()
        try:
            for i in range(cur, len(self.list)):
                ref m = self.list[i]
                try:
                    db.exec(m.up)
                except e:
                    raise Error("migrate: " + m.name + " failed: " + String(e))
                var ins = db.prepare("INSERT INTO " + self.table + "(version, name, checksum, applied) VALUES (?, ?, ?, ?)")
                ins.bind(1, m.version)
                ins.bind(2, m.name)
                ins.bind(3, m.checksum)
                ins.bind(4, Int(wall_seconds()))
                ins.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        return len(self.list) - cur

    def rollback(self, db: Database, to: Int) raises -> Int:
        """Runs the downs of every version above `to`, newest first, in one transaction; the number undone."""
        self.verify(db)
        var cur = self._current(db)
        if to >= cur:
            return 0
        db.begin()
        try:
            var v = cur
            while v > to:
                ref m = self.list[v - 1]
                if m.down.strip() == "":
                    raise Error("migrate: " + m.name + " has no `-- down` section")
                db.exec(m.down)
                var d = db.prepare("DELETE FROM " + self.table + " WHERE version = ?")
                d.bind(1, v)
                d.run()
                v -= 1
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        return cur - to


def apply_all(m: Migrations, paths: List[String]) raises -> Int:
    """Every file verified and dry-run before any changes, then each applied in its own transaction; total applied."""
    for p in paths:
        var db = Database(p)
        m.verify(db)
        m.dry_run(db)
    var n = 0
    for p in paths:
        n += m.apply(Database(p))
    return n
