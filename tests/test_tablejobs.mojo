# mojoui.tablejobs (goal 41 M3): Insert > Table, a SQL query and Export CSV as jobs, on goal 39's shipments.csv and a
# generated 200,000-row CSV:
#   scripts/mxbuild.sh tests/test_tablejobs.mojo -o build/test_tablejobs && G39_MEDIA=build/g39/media G39_OUT=build/g39 build/test_tablejobs
# Prints "tablejobs: ok". Each start returns at once (the work is on the job's thread); the answers equal the same work
# done here directly (read_table, query_table, the file read back).
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.time import sleep
from omxcore import Catalog
from mojoui.tablejobs import TableWork, TableFile, Answer, Exported
from mojoui.tablecard import TableCards, query_table
from mojoui.sheet import Sheet
from mojoui.csvio import read_table
from mojoui.clock import now_ns
from mojoui.text import Font
from themes.liquid import liquid_palette


def write_big(path: String, rows: Int) raises:
    var out = String("id,carrier,usd\n")
    var carriers: List[String] = ["Ridge", "Polar", "Atlas", "Kite"]
    for i in range(rows):
        out += String(i) + "," + carriers[(i * 7) % 4] + "," + String((i * 37) % 9999 + 1) + "\n"
    with open(path, "w") as f:
        f.write(out)


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")
    var pal = liquid_palette()
    var font = Font()
    var big = out + "/tablejobs-big.csv"
    write_big(big, 200_000)
    var work = TableWork()
    var tables = TableCards(4100, 230, 4)

    # Insert > Table: the start returns at once; the card (grid prepared) lands from the job
    var t0 = now_ns()
    assert_true(work.insert(big, pal))
    var start_ms = Float64(now_ns() - t0) / 1e6
    assert_true(start_ms < 20, "insert's start took " + String(start_ms) + " ms")
    assert_true(not work.insert(media + "/shipments.csv", pal), "one file at a time")
    var f = work.take_file()
    while not f:
        sleep(0.005)
        f = work.take_file()
    var file = f.take()
    assert_equal(file.card.sheet.rows(), 200_000)
    assert_equal(file.card.name, "tablejobs-big")
    var file_ms = file.milliseconds
    var k = tables.adopt(file^.take_card(), 10, 20, 600, 320)
    assert_equal(tables.cards[k].x, 10)
    assert_equal(tables.cards[k].slot, 0)
    assert_true(work.insert(media + "/shipments.csv", pal))
    f = work.take_file()
    while not f:
        sleep(0.005)
        f = work.take_file()
    var ships = f.take()
    var direct = Sheet(read_table(media + "/shipments.csv").table, False)
    assert_equal(ships.card.sheet.rows(), direct.rows())
    _ = tables.adopt(ships^.take_card(), 0, 400, 600, 320)

    # a query over the page's tables: an answer card named as asked, equal to the same SQL run here
    var sqltext = String("SELECT carrier, SUM(usd) AS usd FROM tablejobs_big GROUP BY carrier ORDER BY carrier")
    var page = Sheet(read_table(media + "/shipments.csv").table, False)
    var t1 = now_ns()
    assert_true(work.ask(tables, sqltext, "", page, "Query 1", pal))
    var ask_ms = Float64(now_ns() - t1) / 1e6
    assert_true(ask_ms < 20, "ask's start took " + String(ask_ms) + " ms")
    var a = work.take_answer()
    while not a:
        sleep(0.005)
        a = work.take_answer()
    var answer = a.take()
    assert_equal(answer.card.name, "Query 1")
    var cat = Catalog()
    tables.add_to(cat)
    var want = Sheet(query_table(cat, sqltext).share(), False)
    assert_equal(answer.card.sheet.rows(), want.rows())
    assert_equal(answer.card.sheet.rows(), 4)
    for r in range(4):
        assert_equal(answer.card.sheet.plain_text(1, r), want.plain_text(1, r))
    # a bad query fails in the job and says why
    assert_true(work.ask(tables, "SELECT nope FROM nowhere", "", page, "Query 2", pal))
    var bad = work.take_answer()
    var waited = 0
    while not bad and work.query and waited < 5000:
        sleep(0.005)
        waited += 1
        bad = work.take_answer()
    assert_true(not bad and work.problem != "", "a failed query's reason: " + work.problem)

    # Export CSV of the 200,000-row card: written by the job, read back whole
    var path = out + "/tablejobs-export.csv"
    var t2 = now_ns()
    assert_true(work.export(tables.cards[k].sheet, path))
    var ex_ms = Float64(now_ns() - t2) / 1e6
    assert_true(ex_ms < 20, "export's start took " + String(ex_ms) + " ms")
    var e = work.take_export()
    while not e:
        sleep(0.005)
        e = work.take_export()
    assert_equal(e.value().rows, 200_000)
    var back = read_table(path)
    assert_equal(Sheet(back.table, False).rows(), 200_000)
    print("tablejobs: ok (starts " + String(Int(start_ms * 1000)) + "/" + String(Int(ask_ms * 1000)) + "/" + String(Int(ex_ms * 1000)) + " µs; file "
          + String(Int(file_ms)) + " ms, query " + String(Int(answer.milliseconds)) + " ms, export " + String(Int(e.value().milliseconds)) + " ms)")
