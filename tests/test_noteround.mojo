# Review 3, MUST 5, pages and mind maps: read, unedited, saved: the very text; edited: only what the edit means differs
# (a page's markdown; one idea), keys nobody here knows, due times, pictures, other people's ink, order and spelling kept;
# ideas and marks made in two sessions never share an id. Markdown survives the editor byte for byte. noteround: ok
from std.testing import assert_true, assert_equal
from mojoui.json import Json
from mojoui.pagesheet import PageSheet
from mojoui.buzanmap import BuzanMap, map_json_from
from webshell import page_markdown, read_map


def pages() raises:
    var texts: List[String] = ["", "\n", "# T\n\nhello **b**\n", "no newline at the end", "a\r\nb\r\n", "tabs\tand  spaces  \n\n\n", "é 漢字 📚 👩‍👩‍👧 é\n",
                               "| a | b |\n|---|---|\n", "```py\nx = 1\n\n  y\n```\n", "\\*esc\\* <u>u</u> ==hl== [[wiki]] $x^2$\n"]
    for t in texts:
        var p = PageSheet()
        p.set_markdown(t)
        assert_equal(p.markdown(), t, "markdown through the editor")
    var src = String('{ "version":1, "markdown" : "one\\ntwo", "ink":{"marks":[{"id":"w1","tool":"highlighter","points":[[1,2.50]],"future":true}],"drawings":[{"id":"d","d":"M 0 0"}],"layer":3},"pn":{"keep":[1 , 2]} ,"due":"2026-12-01"}')
    var p = PageSheet()
    p.set_markdown(page_markdown(src))
    assert_equal(p.page_json(src), src, "a page nobody edited: the very text")
    p.caret_end()
    p.insert(" é")
    assert_equal(p.page_json(src), src.replace('"one\\ntwo"', '"one\\ntwo é"'), "its words alone")
    assert_equal(p.page_json(p.page_json(src)), p.page_json(src), "saved twice: once")
    # a page whose ink is missing, or isn't an object; a page made here
    assert_equal(p.page_json('{"markdown":"x"}'), '{"markdown":"one\\ntwo é"}')
    assert_true(p.page_json("").startswith('{"version":1,"markdown":"one\\ntwo é","ink":'), "made here")


def maps() raises:
    var src = String('{"version":1,"title":"Old title","theme":{"x":[1]},"rootId":"root","nodes":[{"id":"root","parentId":null,"text":"Book","x":0,"y":0,"color":"#3d8fe8","fontSize":34,"bold":true,"font":"hand"},{"id":"a","parentId":"root","text":"Plot é","x":200.50,"y":-1e1,"color":"#EF684B","due":"2026-11-30T09:00","done":false,"image":{"src":"data:x"},"future":null},{"id":"b","parentId":"a","text":"Twist","x":400,"y":0,"color":"#ef684b"}],"links":[["a","b"]]}')
    var m = BuzanMap()
    var root = read_map(src, m)
    assert_equal(map_json_from(m, src, "New title", root), src, "a map nobody edited: the very text")
    m.topics[1].text = "Plot twist"
    assert_equal(map_json_from(m, src, "t", root), src.replace("Plot é", "Plot twist"), "one idea's words alone")
    m.topics[1].text = "Plot é"
    assert_equal(map_json_from(m, src, "t", root), src)
    m.selected = 0
    var i = m.add_idea(False)
    _ = m.edit_key("Enter", 0)
    var out = Json.parse(map_json_from(m, src, "t", root))
    var nodes = out.get(0, "nodes")
    assert_equal(out.size(nodes), 4)
    assert_equal(out.text(out.get(out.at(nodes, 3), "parentId")), "root")
    assert_equal(out.text(out.get(out.at(nodes, 1), "due")), "2026-11-30T09:00")
    assert_equal(out.text(out.get(0, "title")), "Old title", "its own title member")
    assert_equal(out.size(out.get(0, "links")), 1)
    # two sessions make ideas in the same map: never the same id
    var saved = map_json_from(m, src, "t", root)
    var m2 = BuzanMap()
    var r2 = read_map(saved, m2)
    m2.selected = 0
    _ = m2.add_idea(False)
    _ = m2.edit_key("Enter", 0)
    var ids = Dict[String, Bool]()
    var two = Json.parse(map_json_from(m2, saved, "t", r2))
    for q in range(two.size(two.get(0, "nodes"))):
        var id = two.text(two.get(two.at(two.get(0, "nodes"), q), "id"))
        assert_true(id not in ids, "its own id: " + id)
        ids[id] = True
    _ = i


def main() raises:
    pages()
    maps()
    print("noteround: ok")
