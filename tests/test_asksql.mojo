# mojoui.asksql + links' chained follow (goal 41 M10): JOIN LINKED written out from the sheet's key links, an answer's
# lineage, the question book, a row selection that follows through two links and through an answer's provenance.
#   pixi run mojo run -I . tests/test_asksql.mojo
from std.testing import assert_equal, assert_true
from mojoui.links import Link, Links, End, Selection, CardRows, LINK_KEY, BY_AGENT, REACT_SEEK, REACT_HIGHLIGHT
from mojoui.asksql import AskBook, implied_sql, lineage


def main() raises:
    var links = Links()
    var vid = End("dock.mp4", "code")
    vid.table = "dock.mp4 · detections"
    _ = links.add(Link.key(End("shipments", "shipment_id"), vid))
    _ = links.add(Link.key(End("shipments", "shipment_id"), End("bol fields", "shipment_no")))

    # JOIN LINKED: both joins (the query names both tables), only one when it names one, an error for a stranger
    var q = implied_sql("SELECT DISTINCT shipments.shipment_id AS shipment FROM shipments JOIN LINKED WHERE detections.damaged = true "
                        + "AND bol_fields.exceptions = 'None' ORDER BY shipment", links)
    assert_equal(q, "SELECT DISTINCT shipments.shipment_id AS shipment FROM shipments JOIN detections ON shipments.shipment_id = detections.code "
                 + "JOIN bol_fields ON shipments.shipment_id = bol_fields.shipment_no WHERE detections.damaged = true AND bol_fields.exceptions = 'None' ORDER BY shipment")
    var one = implied_sql("SELECT bol_fields.file FROM shipments JOIN LINKED WHERE shipments.status = 'x.y'", links)
    assert_equal(one, "SELECT bol_fields.file FROM shipments JOIN bol_fields ON shipments.shipment_id = bol_fields.shipment_no WHERE shipments.status = 'x.y'")
    var chain = implied_sql("SELECT detections.frame FROM bol_fields JOIN LINKED", links)  # (two hops: through shipments)
    assert_equal(chain, "SELECT detections.frame FROM bol_fields JOIN shipments ON shipments.shipment_id = bol_fields.shipment_no "
                 + "JOIN detections ON shipments.shipment_id = detections.code")
    assert_equal(implied_sql("SELECT 1 FROM t", links), "SELECT 1 FROM t")
    var lonely = Links()
    _ = lonely.add(Link.key(End("a", "x"), End("b", "x")))
    _ = lonely.add(Link.key(End("c", "y"), End("d", "y")))
    var raised = False
    try:
        _ = implied_sql("SELECT c.y FROM a JOIN LINKED", lonely)
    except e:
        raised = String(e).find("no chain of links reaches c") >= 0
    assert_true(raised, "a table no link reaches is an error")
    print("implied: ok")

    # lineage: plain table.column items only
    var lin = lineage("SELECT DISTINCT shipments.shipment_id AS shipment, count(*) AS n, bol_fields.file, detections.frame f FROM shipments")
    assert_equal(len(lin), 3)
    assert_equal(lin[0].column, "shipment")
    assert_equal(lin[0].table, "shipments")
    assert_equal(lin[0].source, "shipment_id")
    assert_equal(lin[1].column, "file")
    assert_equal(lin[2].column, "f")
    print("lineage: ok")

    # the book: a question taught once, asked again in other punctuation and case
    var book = AskBook()
    book.teach("Damaged pallets whose BOL says no exceptions", "SELECT 1")
    assert_equal(book.sql_for("damaged pallets, whose BOL says NO exceptions?"), "SELECT 1")
    assert_equal(book.sql_for("something else"), "")
    print("book: ok")

    # chained follow: a row of the answer → (derived) shipments → the video and the BOL fields
    links.derive(Link.key(End("answer", "shipment"), End("shipments", "shipment_id"), BY_AGENT))
    var names: List[String] = ["shipment"]
    var cells: List[String] = ["2417"]
    var sel = Selection("answer", "answer", 0, "", "").with_row(names, cells)
    var fs = links.follow(sel)
    assert_equal(len(fs), 3)
    var cards = List[String]()
    for f in fs:
        cards.append(f.card)
        assert_equal(f.value, "2417")
    assert_true("shipments" in cards and "dock.mp4" in cards and "bol fields" in cards, "reached " + ", ".join(cards))
    var video = CardRows("dock.mp4", "dock.mp4 · detections", ["code", "t", "frame"])
    video.seeks("t", "frame")
    video.add_row(["", "0.0", "0"])
    video.add_row(["2417", "5.4", "162"])
    video.add_row(["2417", "5.333", "160"])
    for f in fs:
        if f.card == "dock.mp4":
            var r = video.react(f)
            assert_equal(r.action, REACT_SEEK)
            assert_equal(r.frame, 160)
    # a row selection on shipments with its cells: links on its other columns follow too; the selected column alone too
    var srow = Selection("shipments", "shipments", 3, "carrier", "Polar").with_row(["shipment_id", "carrier"], ["2417", "Polar"])
    assert_equal(len(links.follow(srow)), 3)  # (bol fields, the video, and back to the answer through its lineage)
    var bare = Selection("shipments", "shipments", 3, "carrier", "Polar")
    assert_equal(len(links.follow(bare)), 0)
    # resolve: a typed link on a video joins its rows
    var typed = Links()
    _ = typed.add(Link.key(End("shipments", "shipment_id"), End("dock.mp4", "code")))
    assert_equal(typed.resolve("dock.mp4", "dock.mp4 · detections"), 1)
    assert_equal(typed.items[0].b.sql(), "detections")
    print("chain: ok")
