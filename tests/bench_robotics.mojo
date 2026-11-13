# Goal 70 M2: goal 68's robotics compute, the app's own way vs the omxcore engine's, on the same data, with the answers
# compared. A path moves to the engine only if the engine is faster and gives the same answers.
#   scripts/mxbuild.sh tests/bench_robotics.mojo -o build/bench_robotics
#   build/bench_robotics BAGS_DIR SIM_PARQUET OUT_DIR [RUNS]
# Prints "TIME <path> <way> median=<ms> …" and "SAME <path> yes|no <why>" lines:
#   asof        the fleet's every-topic time join at 10 Hz (mojoui.fleet._asof per topic column) on every bag's joined
#               topics, vs one engine query per topic: a UNION of the topic's times and the moments', a running MAX of
#               the topic's row number (a window: omxcore has no ASOF JOIN and no IGNORE NULLS), its values read by it
#   asof_1m     the same on a made-up topic of 1,000,000 messages (3 number fields) and 100,000 moments
#   stops       the fleet's stop rows (half-seconds standing still) on 1,000,000 moments: the app's loop vs a gaps-and-islands
#               window query (running count of moving moments, ROW_NUMBER inside each still stretch)
#   learn_reads Learn's column reads (mojoui.learn.features_of: Sheet.value per cell) on a 100,000-row sheet vs the
#               engine's whole columns (Frame.bake, then Table.values)
#   similarity  the cosine of every row to row 0 and its top 10 over SIM_PARQUET (docs/goals/70/similarity.py writes it,
#               and times numpy's way, the app's today): engine queries (see bench_similarity)
from std.sys import argv
from std.time import perf_counter_ns
from std.math import isnan
from std.os import makedirs
from omxcore import Catalog, Table, TEXT as MX_TEXT, INT as MX_INT, FLOAT as MX_FLOAT, DECIMAL as MX_DECIMAL
from mojoui.bag import Bag, BagTable, BAG_TEXT, BAG_INT, BAG_FLOAT
from mojoui.fleet import bag_folders, _asof, _is_joined, HZ, STILL, STOP_ROWS
from mojoui.csvio import read_table
from mojoui.sheet import Sheet
from mojoui.learn import features_of, _skipped
from mojoui.tree import Features
from mojoui.tablecard import query_table


def ms_since(t0: Int) -> Float64:
    return Float64(Int(perf_counter_ns()) - t0) / 1e6


def median(var xs: List[Float64]) -> Float64:
    sort(xs)
    return xs[len(xs) // 2]


def say_time(path: String, way: String, xs: List[Float64]):
    var s = String("TIME ") + path + " " + way + " median=" + String(median(xs.copy()))
    for x in xs:
        s += " " + String(Float64(Int(x * 1000.0)) / 1000.0)
    print(s)


def nan() -> Float64:
    return Float64(0) / Float64(0)


# ---------------------------------------------------------------------------------------------------------- as-of


def topic_table(tb: BagTable, cols: List[Int]) raises -> Table:
    """A bag topic as an engine table: idx (its row), t (ns), then its number columns as FLOAT."""
    var t = Table.empty()
    var ci = t.add_column("idx", MX_INT)
    var ct = t.add_column("t", MX_INT)
    var cs = List[Int]()
    for k in range(len(cols)):
        cs.append(t.add_column("v" + String(k), MX_FLOAT))
    ref ts = tb.ints[tb.slot[0]]
    for r in range(tb.rows):
        t.append(ci, Int64(r))
        t.append(ct, ts[r])
        for k in range(len(cols)):
            var v = tb.float_at(cols[k], r)
            if isnan(v):
                t.append_null(cs[k])
            else:
                t.append_float(cs[k], v)
    t.check()
    return t^


def moments_table(times: List[Int]) raises -> Table:
    var t = Table.empty()
    var c = t.add_column("t", MX_INT)
    for x in times:
        t.append(c, Int64(x))
    t.check()
    return t^


comptime ASOF_SQL = ("WITH u AS (SELECT t, 0 AS kind, idx FROM topic UNION ALL SELECT t, 1 AS kind, -1 AS idx FROM moments), "
                     + "w AS (SELECT t, kind, MAX(idx) OVER (ORDER BY t, kind ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS k FROM u) "
                     + "SELECT t, k FROM w WHERE kind = 1 ORDER BY t")
# (each moment's as-of row number; the values are then read by it: `topic.*` in the select list of a 40-field topic is
# refused, "the query needs more than 48 registers")


def asof_engine(var topic: Table, times: List[Int], ncols: Int) raises -> List[List[Float64]]:
    """Each number column's value at each moment, by the engine (NaN before the topic's first message)."""
    var st = topic^.share()
    var cat = Catalog()
    cat.add_table("topic", st)
    cat.add_table("moments", moments_table(times).share())
    var a = query_table(cat, ASOF_SQL)
    var ks = a.values(1)
    var out = List[List[Float64]]()
    for k in range(ncols):
        var c = 2 + k
        var v = List[Float64](capacity=a.rows())
        for r in range(a.rows()):
            var i = Int(ks[r])
            v.append(nan() if i < 0 or st.is_null(c, i) else st.get_float(c, i))
        out.append(v^)
    return out^


def same_floats(a: List[Float64], b: List[Float64]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if isnan(a[i]) != isnan(b[i]) or (not isnan(a[i]) and a[i] != b[i]):
            return False
    return True


def number_cols(tb: BagTable) -> List[Int]:
    var out = List[Int]()
    for c in range(1, tb.columns()):
        if tb.kinds[c] != BAG_TEXT:
            out.append(c)
    return out^


def bench_asof_bags(bags: String, runs: Int) raises:
    var paths = bag_folders(bags)
    var tables = List[BagTable]()
    var timeline = List[List[Int]]()  # per table: its run's moments
    for p in paths:
        var bag = Bag.open(p)
        var want = List[Int]()
        for k in range(len(bag.topics)):
            if not bag.topics[k].is_camera() and _is_joined(bag.topics[k].type, bag.topics[k].name) and (bag.topics[k].encoding == "cdr" or bag.topics[k].encoding == "json"):
                want.append(k)
        var times = List[Int]()
        var t = bag.start_ns
        while t <= bag.end_ns:
            times.append(t)
            t += 1_000_000_000 // HZ
        var got = bag.tables(want)
        while len(got) > 0:
            var tb = got.pop(0)
            if tb.rows > 0 and len(number_cols(tb)) > 0:
                tables.append(tb^)
                timeline.append(times.copy())
    var cells = 0
    for i in range(len(tables)):
        cells += len(number_cols(tables[i])) * len(timeline[i])
    print("asof: " + String(len(paths)) + " bags, " + String(len(tables)) + " topics, " + String(cells) + " moment cells")
    var old_t = List[Float64]()
    var eng_t = List[Float64]()
    var eng_q = List[Float64]()
    var same = True
    for _ in range(runs):
        var t0 = Int(perf_counter_ns())
        var old = List[List[Float64]]()
        for i in range(len(tables)):
            for c in number_cols(tables[i]):
                old.append(_asof(tables[i], c, timeline[i]))
        old_t.append(ms_since(t0))
        var t1 = Int(perf_counter_ns())
        var eng = List[List[Float64]]()
        var q = 0.0
        for i in range(len(tables)):
            var cols = number_cols(tables[i])
            var tt = topic_table(tables[i], cols)
            var t2 = Int(perf_counter_ns())
            for v in asof_engine(tt^, timeline[i], len(cols)):
                eng.append(v.copy())
            q += ms_since(t2)
        eng_t.append(ms_since(t1))
        eng_q.append(q)
        if len(old) != len(eng):
            same = False
        else:
            for k in range(len(old)):
                same = same and same_floats(old[k], eng[k])
    say_time("asof", "app", old_t)
    say_time("asof", "engine", eng_t)
    say_time("asof", "engine_query_only", eng_q)
    print("SAME asof " + ("yes" if same else "no") + " every topic column at every moment")


def bench_asof_big(runs: Int) raises:
    var n = 1_000_000
    var tb = BagTable("/made_up", "made/Up")
    tb.add("t_ns", BAG_INT)
    for k in range(3):
        tb.add("f" + String(k), BAG_FLOAT)
    var seed = UInt64(7)
    var t = 1_000_000_000
    for r in range(n):
        seed = seed * 6364136223846793005 + 1442695040888963407
        t += Int((seed >> 33) % 2_000_000)  # (gaps 0..2 ms: about 1 ms a message)
        tb.ints[tb.slot[0]].append(Int64(t))
        for k in range(3):
            tb.floats[tb.slot[1 + k]].append(Float64(Int((seed >> UInt64(10 + k)) % 100000)) / 1000.0)
    tb.rows = n
    var times = List[Int]()
    var m = 999_000_000
    for _ in range(100_000):
        times.append(m)
        m += 10_000_000
    var cols = number_cols(tb)
    var old_t = List[Float64]()
    var eng_t = List[Float64]()
    var same = True
    for _ in range(runs):
        var t0 = Int(perf_counter_ns())
        var old = List[List[Float64]]()
        for c in cols:
            old.append(_asof(tb, c, times))
        old_t.append(ms_since(t0))
        var t1 = Int(perf_counter_ns())
        var eng = asof_engine(topic_table(tb, cols), times, len(cols))
        eng_t.append(ms_since(t1))
        for k in range(len(cols)):
            same = same and same_floats(old[k], eng[k])
    say_time("asof_1m", "app", old_t)
    say_time("asof_1m", "engine", eng_t)
    print("SAME asof_1m " + ("yes" if same else "no") + " 3 columns x 100,000 moments")


# ---------------------------------------------------------------------------------------------------------- stops


def stops_app(speed: List[Float64]) -> List[Int]:
    """mojoui.fleet's stop rows: the moment j0 each half-second of standing still starts at (as read_fleet writes them)."""
    var out = List[Int]()
    var still = 0
    for j in range(len(speed)):
        if not isnan(speed[j]) and speed[j] < STILL:
            still += 1
            if still % STOP_ROWS == 0:
                out.append(j - STOP_ROWS + 1)
        else:
            still = 0
    return out^


comptime STOPS_SQL = ("WITH s AS (SELECT j, CASE WHEN speed IS NOT NULL AND speed < 0.05 THEN 1 ELSE 0 END AS still FROM m), "
                      + "g AS (SELECT j, still, SUM(1 - still) OVER (ORDER BY j ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS island FROM s), "
                      + "r AS (SELECT j, still, ROW_NUMBER() OVER (PARTITION BY island ORDER BY j) AS rn FROM g WHERE still = 1) "
                      + "SELECT j - 4 AS j0 FROM r WHERE rn % 5 = 0 ORDER BY j0")


def bench_stops(runs: Int) raises:
    var n = 1_000_000
    var speed = List[Float64](capacity=n)
    var seed = UInt64(11)
    var moving = True
    for _ in range(n):
        seed = seed * 6364136223846793005 + 1442695040888963407
        if (seed >> 40) % 40 == 0:
            moving = not moving
        speed.append(nan() if (seed >> 20) % 500 == 0 else (0.02 if not moving else 0.4 + Float64(Int((seed >> 30) % 100)) / 100.0))
    var m = Table.empty()
    var cj = m.add_column("j", MX_INT)
    var cs = m.add_column("speed", MX_FLOAT)
    for j in range(n):
        m.append(cj, Int64(j))
        if isnan(speed[j]):
            m.append_null(cs)
        else:
            m.append_float(cs, speed[j])
    m.check()
    var shared = m^.share()
    var old_t = List[Float64]()
    var eng_t = List[Float64]()
    var same = True
    var found = 0
    for _ in range(runs):
        var t0 = Int(perf_counter_ns())
        var old = stops_app(speed)
        old_t.append(ms_since(t0))
        var t1 = Int(perf_counter_ns())
        var cat = Catalog()
        cat.add_table("m", shared)
        var a = query_table(cat, STOPS_SQL)
        eng_t.append(ms_since(t1))
        found = len(old)
        if a.rows() != len(old):
            same = False
        else:
            for i in range(len(old)):
                same = same and Int(a.get(0, i)) == old[i]
    say_time("stops", "app", old_t)
    say_time("stops", "engine", eng_t)
    print("SAME stops " + ("yes" if same else "no") + " " + String(found) + " stop rows over 1,000,000 moments")


# ---------------------------------------------------------------------------------------------------------- Learn


def features_engine(sheet: Sheet, label: String) raises -> Features:
    """features_of's columns, read whole from the baked table (Table.values) instead of a cell at a time."""
    var t = sheet.frame.bake()
    var n = t.rows()
    var f = Features(n)
    for c in range(t.columns()):
        var name = t.name(c)
        if _skipped(name, label):
            continue
        var vals = t.values(c)
        if t.kind(c) == MX_TEXT:
            var words = len(t.dictionary(c))
            if words > 50 and words * 2 > n:
                continue
            var codes = List[Int](capacity=n)
            var names = List[String](capacity=words)
            for w in t.dictionary(c):
                names.append(String(w))
            for r in range(n):
                codes.append(-1 if t.is_null(c, r) else Int(vals[r]))
            f.add_words(name, codes, names^)
        else:
            var div = 1.0
            for _ in range(t.scale(c) if t.kind(c) == MX_DECIMAL else 0):
                div *= 10.0
            var v = List[Float64](capacity=n)
            for r in range(n):
                v.append(nan() if t.is_null(c, r) else Float64(vals[r]) / div)
            f.add_number(name, v^)
    return f^


def same_features(a: Features, b: Features) -> Bool:
    if a.columns() != b.columns() or a.rows != b.rows:
        return False
    for c in range(a.columns()):
        if a.names[c] != b.names[c] or a.numeric[c] != b.numeric[c] or not same_floats(a.values[c], b.values[c]):
            return False
        if len(a.words[c]) != len(b.words[c]):
            return False
        for w in range(len(a.words[c])):
            if a.words[c][w] != b.words[c][w]:
                return False
    return True


def bench_learn(dest: String, runs: Int) raises:
    var n = 100_000
    var path = dest + "/learn100k.csv"
    with open(path, "w") as f:
        var s = String("run,speed,person_m,turn_rate,zone,cause\n")
        var seed = UInt64(3)
        for r in range(n):
            seed = seed * 6364136223846793005 + 1442695040888963407
            var sp = Float64(Int((seed >> 20) % 1000)) / 1000.0
            var pm = String("") if (seed >> 30) % 9 == 0 else String(Float64(Int((seed >> 35) % 400)) / 100.0)
            s += "r" + String(r // 1000) + "," + String(sp) + "," + pm + "," + String(Float64(Int((seed >> 12) % 200)) / 100.0) + ",z" + String(Int((seed >> 44) % 7)) + ","
            s += ("person" if r % 5000 == 0 else ("blocked" if r % 5000 == 1 else "")) + "\n"
        f.write(s)
    var sheet = Sheet(read_table(path).table, False)
    var old_t = List[Float64]()
    var eng_t = List[Float64]()
    var same = True
    for _ in range(runs):
        var t0 = Int(perf_counter_ns())
        var a = features_of(sheet, "cause")
        old_t.append(ms_since(t0))
        var t1 = Int(perf_counter_ns())
        var b = features_engine(sheet, "cause")
        eng_t.append(ms_since(t1))
        same = same and same_features(a, b)
    say_time("learn_reads", "app", old_t)
    say_time("learn_reads", "engine", eng_t)
    print("SAME learn_reads " + ("yes" if same else "no") + " every feature column of 100,000 rows")


# ---------------------------------------------------------------------------------------------------------- similarity


def balanced(terms: List[String], lo: Int, hi: Int) -> String:
    """terms[lo:hi] added as a balanced tree, ((a + b) + (c + d)): a chain of 384 `+` is refused (an expression may be
    256 levels deep)."""
    if hi - lo == 1:
        return terms[lo]
    var mid = (lo + hi) // 2
    return "(" + balanced(terms, lo, mid) + " + " + balanced(terms, mid, hi) + ")"


def bench_similarity(parquet: String, dest: String, runs: Int) raises:
    """Every row's cosine to row 0, then its top 10, by engine queries. The engine holds at most 64 distinct constants
    a query and has no CROSS JOIN (to join row 0's vector as a table) or vector column, so the dot product is split:
    one query per 48 dimensions (64 is refused: the engine adds constants of its own; a partial sum each, a balanced `+` tree),
    the partials added, then one ORDER BY sim DESC LIMIT 10 query."""
    var imp = read_table(parquet)
    var t = imp.table
    var dims = t.columns() - 1  # (row, e0 … e383)
    var chunks = List[String]()
    var d = 0
    while d < dims:
        var terms = List[String]()
        for k in range(d, min(d + 48, dims)):
            var x = String(t.get_float(t.index("e" + String(k)), 0))
            terms.append("e" + String(k) + " * " + x + ("" if "e" in x else "e0"))  # (an exponent makes it a DOUBLE literal; 19 places don't fit a decimal)
        chunks.append("SELECT row, " + balanced(terms, 0, len(terms)) + " AS p FROM emb ORDER BY row")
        d += 48
    var all_t = List[Float64]()
    var top_t = List[Float64]()
    var top_text = String("")
    var all_text = String("")
    for _ in range(runs):
        var cat = Catalog()
        cat.add_table("emb", t)
        var t0 = Int(perf_counter_ns())
        var sims = List[Float64](length=t.rows(), fill=0.0)
        for q in chunks:
            var a = query_table(cat, q)
            for r in range(a.rows()):
                sims[r] += a.get_float(1, r)
        all_t.append(ms_since(t0))
        var s = Table.empty()
        var cr = s.add_column("row", MX_INT)
        var cs = s.add_column("sim", MX_FLOAT)
        for r in range(len(sims)):
            s.append(cr, Int64(r))
            s.append_float(cs, sims[r])
        s.check()
        var sc = Catalog()
        sc.add_table("s", s^.share())
        var b = query_table(sc, "SELECT row, sim FROM s ORDER BY sim DESC LIMIT 10")
        top_t.append(ms_since(t0))
        top_text = String("")
        for r in range(b.rows()):
            top_text += String(b.get(0, r)) + "\t" + String(b.get_float(1, r)) + "\n"
        all_text = String("")
        for x in sims:
            all_text += String(x) + "\n"
    with open(dest + "/similarity_top10_engine.txt", "w") as f:
        f.write(top_text)
    with open(dest + "/similarity_all_engine.txt", "w") as f:
        f.write(all_text)
    say_time("similarity_all", "engine", all_t)
    say_time("similarity_top10", "engine", top_t)
    print("similarity: " + String(t.rows()) + " rows x " + String(dims) + " dims, " + String(len(chunks)) + " queries + a top-10 query (compared by docs/goals/70/similarity.py)")


def main() raises:
    var args = argv()
    var bags = String(args[1])
    var sim = String(args[2])
    var out = String(args[3])
    var runs = Int(String(args[4])) if len(args) > 4 else 5
    makedirs(out, exist_ok=True)
    bench_asof_bags(bags, runs)
    bench_asof_big(runs)
    bench_stops(runs)
    bench_learn(out, runs)
    bench_similarity(sim, out, runs)
