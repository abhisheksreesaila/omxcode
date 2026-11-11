# Goal 60 M2: mojoui.migrate on real SQLite files: apply in order, idempotent, a broken migration leaves the file as it
# was (transaction), an edited applied file refuses, down undoes. The server's per-tenant run is 60-check.py's M2.
from std.os import makedirs, remove, listdir
from std.os.path import exists
from mojoui.migrate import Migrations, apply_all
from mojoui.sqlite import Database
from mojoui.serve import spawn
from mojoui import libc
from std.memory import Pointer
from std.atomic import Atomic

comptime _A = Atomic[Scalar[DType.int64]]
comptime RACE_DIR = "build/test_migrate_files"


def racer(addr: Int):
    """Applies the migrations on a connection of its own to race.db: word 0 counts finished, word 1 errors, word 2 the
    migrations applied in total."""
    var w = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)
    try:
        var n = Migrations.from_dir(RACE_DIR + "/m").apply(Database(RACE_DIR + "/race.db"))
        _ = _A.fetch_add(w + 2, Int64(n))
    except e:
        print("racer: " + String(e))
        _ = _A.fetch_add(w + 1, 1)
    _ = _A.fetch_add(w, 1)


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def cols(db: Database) raises -> String:
    var q = db.prepare("SELECT group_concat(name, ',') FROM pragma_table_info('notes')")
    return q.text(0) if q.step() else String("")


def main() raises:
    var dir = "build/test_migrate_files"
    if not exists(dir + "/m"):
        makedirs(dir + "/m")
    for f in listdir(dir + "/m"):
        remove(dir + "/m/" + String(f))
    for f in ["a.db", "b.db", "race.db"]:
        for s in ["", "-wal", "-shm"]:
            if exists(dir + "/" + f + s):
                remove(dir + "/" + f + s)
    write(dir + "/m/001_notes.sql", "-- up\nCREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT);\n-- down\nDROP TABLE notes;\n")
    write(dir + "/m/002_body.sql", "-- UP --\nALTER TABLE notes ADD COLUMN body TEXT;\n-- DOWN --\nALTER TABLE notes DROP COLUMN body;\n")
    var m = Migrations.from_dir(dir + "/m")
    var db = Database(dir + "/a.db")
    expect(m.apply(db) == 2, "two applied")
    expect(cols(db) == "id,title,body", "columns: " + cols(db))
    expect(len(m.applied(db)) == 2, "two rows")
    print("apply: ok")
    expect(m.apply(db) == 0 and len(m.applied(db)) == 2, "nothing twice")
    expect(apply_all(Migrations.from_dir(dir + "/m"), [dir + "/a.db", dir + "/b.db"]) == 2, "b caught up, a untouched")
    print("idempotent: ok")
    db.exec("INSERT INTO notes(title, body) VALUES ('x', 'y')")
    write(dir + "/m/003_broken.sql", "-- up\nCREATE TABLE half(x);\nCREATE TABLE oops(;\n-- down\nDROP TABLE half;\n")
    var m3 = Migrations.from_dir(dir + "/m")
    var failed = False
    try:
        m3.dry_run(db)
    except:
        failed = True
    expect(failed, "the dry run caught the broken one")
    failed = False
    try:
        _ = m3.apply(db)
    except e:
        failed = "003_broken" in String(e)
    expect(failed, "apply raised naming 003")
    expect(db.count("SELECT count(*) FROM sqlite_master WHERE name = 'half'") == 0, "half of 003 stayed")
    expect(len(m3.applied(db)) == 2 and db.count("SELECT count(*) FROM notes") == 1, "the file is as it was")
    failed = False
    try:
        _ = apply_all(m3, [dir + "/a.db", dir + "/b.db"])
    except:
        failed = True
    expect(failed and len(m3.applied(Database(dir + "/b.db"))) == 2, "apply_all refused before touching b")
    remove(dir + "/m/003_broken.sql")
    print("broken: ok")
    write(dir + "/m/002_body.sql", "-- UP --\nALTER TABLE notes ADD COLUMN body  TEXT;\n-- DOWN --\nALTER TABLE notes DROP COLUMN body;\n")
    failed = False
    try:
        _ = Migrations.from_dir(dir + "/m").apply(db)
    except e:
        failed = "edited" in String(e)
    expect(failed, "an edited applied file refuses")
    remove(dir + "/m/001_notes.sql")
    failed = False
    try:
        _ = Migrations.from_dir(dir + "/m")
    except:
        failed = True
    expect(failed, "a gap refuses")
    print("checksum: ok")
    write(dir + "/m/001_notes.sql", "-- up\nCREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT);\n-- down\nDROP TABLE notes;\n")
    write(dir + "/m/002_body.sql", "-- UP --\nALTER TABLE notes ADD COLUMN body TEXT;\n-- DOWN --\nALTER TABLE notes DROP COLUMN body;\n")
    var mm = Migrations.from_dir(dir + "/m")
    expect(mm.rollback(db, 1) == 1 and cols(db) == "id,title" and len(mm.applied(db)) == 1, "down to 1: " + cols(db))
    expect(mm.apply(db) == 1 and cols(db) == "id,title,body", "up again")
    print("down: ok")
    # race: two processes' worth of apply() wait on a third's write lock; each read "nothing applied" before it got the
    # lock, so the one that goes second must look again under the lock (round 3, R19)
    var hold = Database(dir + "/race.db")
    hold.exec("PRAGMA journal_mode=WAL")
    _ = Migrations.from_dir(dir + "/m").applied(hold)  # (its version table exists, empty: reading it needs no lock)
    hold.exec("BEGIN IMMEDIATE")
    var w = List[Int64](length=3, fill=0)
    for _ in range(2):
        _ = spawn[racer](Int(w.unsafe_ptr()))
    _ = libc.poll(0, 0, 400)  # (both have read the version and wait in BEGIN IMMEDIATE)
    hold.exec("ROLLBACK")
    var waited = 0
    while _A.load(w.unsafe_ptr()) < 2 and waited < 100:
        _ = libc.poll(0, 0, 100)
        waited += 1
    var total = len(Migrations.from_dir(dir + "/m").list)
    expect(_A.load(w.unsafe_ptr()) == 2 and w[1] == 0, "a racing apply failed (" + String(w[1]) + " of 2)")
    expect(Int(w[2]) == total, "applied " + String(w[2]) + " in total, want " + String(total) + " (once each)")
    _ = len(w)
    print("race: ok")
