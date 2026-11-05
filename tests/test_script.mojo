# mojoui.script (goal 49 M1): a script's statements, run in order over a catalog; named results later statements read;
# errors that name their line; functions from a registry (where models plug in); ${params}.
#   pixi run mojo run -I . tests/test_script.mojo
# Prints "parse: ok", "run: ok", "chain: ok", "error: ok", "fn: ok", "frames: ok" (mojoui.videoscript: a video as a table).
from std.testing import assert_equal, assert_true, assert_false
from omxcore import Catalog, Table, Frame as MxFrame, INT as MX_INT
from mojoui.videoscript import VideoFunctions
from mojoui.script import parse_script, run_script, bind_params, ScriptFunctions, NoFunctions, STMT_SQL, STMT_FN


def numbers(n: Int) raises -> Table:
    var t = Table.empty()
    var x = t.add_column("x", MX_INT)
    for i in range(n):
        t.append(x, Int64(i + 1))
    t.check()
    return t^


struct Ones(ScriptFunctions):
    """A test registry: ones(n) is a table of n rows; calls counts them."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def has(self, name: String) -> Bool:
        return name == "ones"

    def call(mut self, name: String, args: List[String], mut catalog: Catalog) raises -> Table:
        self.calls += 1
        if len(args) != 1:
            raise Error("ones(n) takes one number")
        return numbers(Int(args[0]))


def main() raises:
    # parse: names, kinds, lines, function arguments; ';' in quotes and comments don't split
    var text = String("-- frames of the video\nframes = SELECT * FROM v;\n\nj = SELECT 'a;b' AS s\n  FROM t;  -- two lines\n")
    text += "SELECT 1;\nr = regions(episode, 3.0, 8.5);\nq = SELECT * FROM t -- no semicolon at the end"
    var st = parse_script(text)
    assert_equal(len(st), 5)
    assert_equal(st[0].name, "frames")
    assert_equal(st[0].line, 2)
    assert_equal(st[0].kind, STMT_SQL)
    assert_equal(st[0].text, "SELECT * FROM v")
    assert_equal(st[1].name, "j")
    assert_equal(st[1].line, 4)
    assert_true(st[1].text.find("'a;b'") >= 0, st[1].text)
    assert_equal(st[2].name, "")
    assert_equal(st[2].line, 6)
    assert_equal(st[3].kind, STMT_FN)
    assert_equal(st[3].fn_name, "regions")
    assert_equal(len(st[3].args), 3)
    assert_equal(st[3].args[0], "episode")
    assert_equal(st[3].args[2], "8.5")
    assert_equal(st[4].name, "q")
    assert_equal(st[4].line, 8)
    # a name that isn't a word is a parse error with its line
    var bad = False
    try:
        _ = parse_script("SELECT 1;\n2x = SELECT 1;")
    except e:
        bad = String(e).find("line 2") >= 0
    assert_true(bad, "a bad name names its line")
    print("parse: ok")

    # run: a named result over the catalog's table
    var cat = Catalog()
    cat.add_frame("t", MxFrame(numbers(5).share()))
    var none = NoFunctions()
    var r = run_script("a = SELECT x FROM t WHERE x > 2;", cat, none)
    assert_equal(r.problem, "")
    assert_equal(len(r.names), 1)
    assert_equal(r.names[0], "a")
    assert_equal(r.tables[0].rows(), 3)
    print("run: ok")

    # chain: a later statement reads an earlier result; a bare SELECT is named result_N
    var cat2 = Catalog()
    cat2.add_frame("t", MxFrame(numbers(5).share()))
    var r2 = run_script("a = SELECT x FROM t WHERE x > 2;\nb = SELECT count(*) AS n FROM a;\nSELECT x FROM a WHERE x = 5", cat2, none)
    assert_equal(r2.problem, "")
    assert_equal(len(r2.names), 3)
    assert_equal(r2.names[1], "b")
    assert_equal(r2.tables[1].rows(), 1)
    assert_equal(r2.names[2], "result_3")
    assert_equal(r2.tables[2].rows(), 1)
    assert_equal(len(r2.log), 3)
    assert_true(r2.log[0].startswith("a = SELECT"), r2.log[0])
    print("chain: ok")

    # error: the engine's message with the statement's line; earlier results kept, later ones not run
    var cat3 = Catalog()
    cat3.add_frame("t", MxFrame(numbers(5).share()))
    var r3 = run_script("a = SELECT x FROM t;\n\nb = SELECT nope FROM a;\nc = SELECT 1", cat3, none)
    assert_true(r3.problem.startswith("line 3:"), r3.problem)
    assert_equal(r3.line, 3)
    assert_equal(len(r3.names), 1)
    assert_equal(r3.names[0], "a")
    print("error: ok")

    # fn: a registered function's table is a result like any other; an unknown one is an error; ${params}
    var cat4 = Catalog()
    var ones = Ones()
    var r4 = run_script("z = ones(4);\nw = SELECT * FROM z WHERE x > 1;", cat4, ones)
    assert_equal(r4.problem, "")
    assert_equal(ones.calls, 1)
    assert_equal(r4.tables[0].rows(), 4)
    assert_equal(r4.tables[1].rows(), 3)
    var r5 = run_script("y = nope(1);", cat4, ones)
    assert_true(r5.problem.find("no function nope") >= 0, r5.problem)
    var params = Dict[String, String]()
    params["episode"] = "F00118"
    assert_equal(bind_params("SELECT * FROM t WHERE e = '${episode}'", params), "SELECT * FROM t WHERE e = 'F00118'")
    var unbound = False
    try:
        _ = bind_params("${missing}", params)
    except e:
        unbound = String(e).find("missing") >= 0
    assert_true(unbound, "an unbound ${name} is an error")
    assert_false(ones.has("regions"))
    print("fn: ok")

    # frames: a video is a table of its frames (frame, t), joinable with a 15 Hz log by round(t * 15)
    var videos = VideoFunctions()
    videos.add("episode", "clip.mp4", 15.0, 244)
    var cat6 = Catalog()
    var log = Table.empty()
    var lt = log.add_column("k", MX_INT)
    for i in range(300):
        log.append(lt, Int64(i))
    log.check()
    cat6.add_frame("log", MxFrame(log^.share()))
    videos.add_to(cat6)
    var r6 = run_script("f = SELECT * FROM episode;\nlast = SELECT frame, t FROM episode WHERE frame = 243;\nj = SELECT f.frame FROM f JOIN log ON log.k = f.frame;", cat6, videos)
    assert_equal(r6.problem, "")
    assert_equal(r6.tables[0].rows(), 244)
    assert_equal(r6.tables[1].rows(), 1)
    assert_equal(r6.tables[2].rows(), 244)
    print("frames: ok")
