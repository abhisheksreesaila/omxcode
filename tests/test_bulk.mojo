# Goal 66 M4: mojoui.sqlite's bulk_upsert (by a key, keeping what a person edited, one transaction, 100k rows) and a
# query streamed as CSV by mojoui.csvstream through mojoui.serve (Reply.csv), fetched over HTTP.
from std.os import makedirs, getenv
from mojoui.sqlite import Database, Pool, bulk_upsert, set_edited
from mojoui.csvstream import csv_field, csv_row, stream_csv
from mojoui.serve import Server, Service, Req, Reply
from mojoui.http import Request, utf8_lossy
from mojoui.effects import Backend
from mojoui.clock import now_ns
from mojoui import libc


struct Csv(Service):
    var path: String

    def __init__(out self, path: String):
        self.path = path

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        var header = List[String]()
        header.append("id")
        header.append("text")
        return stream_csv(self.path, "SELECT id, text FROM t ORDER BY id", List[String](), header^, "t.csv")


def ok(c: Bool, what: String) raises:
    if not c:
        raise Error("FAILED: " + what)


def row(a: String, b: String, c: String, d: String) -> List[String]:
    var r = List[String]()
    r.append(a)
    r.append(b)
    r.append(c)
    r.append(d)
    return r^


def main() raises:
    var dir = getenv("BULK_DIR", getenv("TMPDIR", "/tmp") + "/mojoui-bulk-" + String(libc.getpid()))
    makedirs(dir, exist_ok=True)
    var path = dir + "/bulk-" + String(libc.getpid()) + ".db"
    var db = Pool.shared().open(path)
    db.exec("CREATE TABLE tx(id TEXT PRIMARY KEY, amount REAL, merchant TEXT, category TEXT, edited TEXT)")
    var cols = List[String]()
    for c in ["id", "amount", "merchant", "category"]:
        cols.append(String(c))
    var key = List[String]()
    key.append("id")
    var keep = List[String]()
    keep.append("category")
    var rows = List[List[String]]()
    rows.append(row("t1", "-12.5", "Cafe", "Dining"))
    rows.append(row("t2", "-40", "Grocer", "Groceries"))
    ok(bulk_upsert(db, "tx", key, cols, rows, keep) == 2 and db.count("SELECT count(*) FROM tx") == 2, "inserted")
    ok(db.one_text("SELECT typeof(amount) FROM tx WHERE id = 't1'") == "real", "affinity: a number")
    rows[1] = row("t2", "-41", "Grocer", "Food")
    rows.append(row("t3", "9", "Shop", "Other"))
    _ = bulk_upsert(db, "tx", key, cols, rows, keep)
    ok(db.count("SELECT count(*) FROM tx") == 3 and db.one_text("SELECT category FROM tx WHERE id = 't2'") == "Food", "updated by key")
    print("upsert: ok")

    ok(set_edited(db, "tx", "id", "t1", "category", "Coffee") == 1, "an edit")
    ok(set_edited(db, "tx", "id", "t1", "category", "Coffee!") == 1 and db.one_text("SELECT edited FROM tx WHERE id = 't1'") == "category", "edited listed once")
    rows[0] = row("t1", "-13", "Cafe", "Dining")
    _ = bulk_upsert(db, "tx", key, cols, rows, keep)
    ok(db.one_text("SELECT category FROM tx WHERE id = 't1'") == "Coffee!" and db.one_text("SELECT amount FROM tx WHERE id = 't1'") == "-13.0", "kept the edit, took the amount")
    ok(db.one_text("SELECT category FROM tx WHERE id = 't2'") == "Food", "unedited rows follow the source")
    print("keep_edited: ok")

    var bad = List[List[String]]()
    bad.append(row("t9", "1", "New", "X"))
    var short = List[String]()
    short.append("t10")
    bad.append(short^)
    var raised = False
    try:
        _ = bulk_upsert(db, "tx", key, cols, bad)
    except:
        raised = True
    ok(raised and db.count("SELECT count(*) FROM tx WHERE id = 't9'") == 0, "a bad row rolls the whole batch back")
    var evil = List[String]()
    evil.append("id; DROP TABLE tx")
    raised = False
    try:
        _ = bulk_upsert(db, "tx", key, evil, rows)
    except:
        raised = True
    ok(raised and db.count("SELECT count(*) FROM tx") == 3, "column names are checked")
    print("one_tx: ok")

    var big = List[List[String]]()
    for i in range(100_000):
        big.append(row("b" + String(i), String(-(i % 997)) + ".25", "Merchant " + String(i % 300), "Cat " + String(i % 12)))
    var t0 = now_ns()
    var n = bulk_upsert(db, "tx", key, cols, big, keep)
    var ms = (now_ns() - t0) // 1_000_000
    t0 = now_ns()
    _ = bulk_upsert(db, "tx", key, cols, big, keep)
    var ms2 = (now_ns() - t0) // 1_000_000
    ok(n == 100_000 and db.count("SELECT count(*) FROM tx") == 100_003, "100k rows")
    print("speed: ok " + String(max(ms, ms2)) + " ms for 100k rows (insert " + String(ms) + " ms, update " + String(ms2) + " ms)")

    ok(csv_field("plain") == "plain" and csv_field('a "q", c') == '"a ""q"", c"' and csv_field("a\nb") == '"a\nb"', "quoting")
    ok(csv_row(row("1", "x,y", "", "z")) == '1,"x,y",,z\r\n', "a row")
    print("csv_quote: ok")
    ok(csv_field("=1+1") == "'=1+1" and csv_field("+1") == "'+1" and csv_field("-2") == "'-2" and csv_field("@x") == "'@x" and csv_field("\tx") == "'\tx", "guard")
    ok(csv_field('=HYPERLINK("a,b")') == "\"'=HYPERLINK(\"\"a,b\"\")\"", "guard then quote")
    print("csv_guard: ok")

    db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, text)")
    var texts = ["plain", 'a "quoted", comma', "two\nlines", '=HYPERLINK("http://x")', "+1", "-2", "@sum"]
    for i in range(len(texts)):
        var st = db.prepare("INSERT INTO t(id, text) VALUES (?, ?)")
        st.bind(1, i + 1)
        st.bind(2, String(texts[i]))
        st.run()
    var st = db.prepare("INSERT INTO t(id, text) VALUES (8, ?)")
    st.bind(1, Float64(-3.5))
    st.run()
    for i in range(9, 3000):
        var s2 = db.prepare("INSERT INTO t(id, text) VALUES (?, ?)")
        s2.bind(1, i)
        s2.bind(2, "row " + String(i))
        s2.run()
    var served = Server.start(Csv(path), port=0)
    var res = Backend.send(Request.get(0, "http://127.0.0.1:" + String(served.port) + "/t.csv").timeout(10_000))
    var body = utf8_lossy(res.body)
    ok(res.status == 200 and res.header("content-type").startswith("text/csv") and res.header("content-disposition").find("t.csv") >= 0, "the reply's head: " + String(res.status))
    ok(body.startswith("id,text\r\n1,plain\r\n") and body.find("8,-3.5\r\n") >= 0 and body.find("2999,row 2999\r\n") >= 0, "the body")
    var out = getenv("BULK_CSV_OUT", dir + "/out.csv")
    with open(out, "w") as f:
        f.write(body)
    print("csv_stream: ok " + String(body.byte_length()) + " bytes streamed, " + res.header("transfer-encoding"))
    served.stop()
