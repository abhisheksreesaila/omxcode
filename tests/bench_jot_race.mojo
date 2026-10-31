# Goal 42 M6, side A: mojoui.sqlite in a native process (scripts/jot_race.py runs it; side B is SQLite-wasm + OPFS).
#   bench_jot_race build <dir> <db>   pragmas.sql, schema.sql, then notes.tsv (title \t body per line) inserted with
#                                     insert.sql in transactions of 10,000 (Jot's triggers keep notes_fts in step);
#                                     prints BUILD {"notes":n,"build_s":s} (the file read and split before the clock)
#   bench_jot_race query <dir> <db>   opens the existing file, runs query.sql for each line of queries.txt (an FTS5
#                                     MATCH string), stepping every row; prints FIRST <monotonic ns> when the first
#                                     query is answered, then QUERY {"counts":[…],"ms":[…]}
# Everything SQL comes from the files jot_race.py writes, so both sides run the same statements.
from std.sys import argv
from std.time import perf_counter_ns

from mojoui.sqlite import Database


def read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def statements(sql: String) -> List[String]:
    var out = List[String]()
    for part in sql.split(";\n"):
        var s = String(String(part).strip())
        if s != "":
            out.append(s)
    return out^


def build(dir: String, path: String) raises:
    var lines = read(dir + "/notes.tsv").split("\n")
    var db = Database(path)
    for s in statements(read(dir + "/pragmas.sql")):
        db.exec(s)
    db.exec(read(dir + "/schema.sql"))
    var ins = db.prepare(String(read(dir + "/insert.sql").strip()))
    var t0 = perf_counter_ns()
    var n = 0
    db.begin()
    for line in lines:
        var l = String(line)
        var tab = l.find("\t")
        if tab < 0:
            continue
        ins.bind(1, String(l[byte=:tab]))
        ins.bind(2, String(l[byte = tab + 1 :]))
        ins.bind(3, n)
        ins.run()
        n += 1
        if n % 10000 == 0:
            db.commit()
            db.begin()
    db.commit()
    var secs = Float64(perf_counter_ns() - t0) / 1e9
    for s in statements(read(dir + "/finish.sql")):
        db.exec(s)
    print('BUILD {"notes":' + String(n) + ',"build_s":' + String(secs) + "}", flush=True)


def query(dir: String, path: String) raises:
    var db = Database(path)
    for s in statements(read(dir + "/open.sql")):
        db.exec(s)
    var q = db.prepare(String(read(dir + "/query.sql").strip()))
    var counts = String("")
    var times = String("")
    var first = True
    for line in read(dir + "/queries.txt").split("\n"):
        var m = String(line)
        if m == "":
            continue
        var t0 = perf_counter_ns()
        q.reset()
        q.bind(1, m)
        var n = 0
        while q.step():
            n += 1
        var t1 = perf_counter_ns()
        if first:
            print("FIRST " + String(Int(t1)), flush=True)
            first = False
        else:
            counts += ","
            times += ","
        counts += String(n)
        times += String(Float64(t1 - t0) / 1e6)
    print('QUERY {"counts":[' + counts + '],"ms":[' + times + "]}", flush=True)


def main() raises:
    var args = argv()
    if len(args) < 4:
        print("usage: bench_jot_race build|query <dir> <db>")
        return
    if String(args[1]) == "build":
        build(String(args[2]), String(args[3]))
    else:
        query(String(args[2]), String(args[3]))
