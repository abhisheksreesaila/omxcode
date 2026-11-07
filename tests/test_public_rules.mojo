# Goal 62 round 3: the public copy's rules, one at a time (each a finding of the round-3 review):
#   - capped_sql and public_refusal: one SELECT at a time (WITH anywhere, behind parentheses or comments; UNION,
#     INTERSECT and EXCEPT; words inside quotes don't count); the cap past a trailing comment; a desktop takes anything
#   - the server's places for questions (MOJOUI_QUESTIONS): taken and given back, a desktop counts nothing
#   - check_budget and parking: a question stopped at the time budget still counts, for its visitor and the server,
#     until the engine ends it; then the visitor may ask again
#   - visitor_path_ok; files.mojo keeps nothing on disk in public mode; control_event takes no number a choice lacks
#   scripts/mxbuild.sh tests/test_public_rules.mojo -o build/test_public_rules && CUDA_VISIBLE_DEVICES= build/test_public_rules
# Prints "public rules: ok".
from std.testing import assert_equal, assert_true, assert_false
from std.os import setenv, getenv, makedirs
from std.time import sleep
from mojoui.tablejobs import TableWork, capped_sql, public_refusal, take_question, give_back_question, questions_running, answer_width
from mojoui.tablecard import TableCards
from mojoui.sheet import Sheet
from mojoui.csvio import read_table
from mojoui.files import visitor_path_ok, read_setting, write_setting, read_recent, remember, config_dir, file_exists
from mojoui.hosts.web import control_event
from mojoui.view import View, Dropdown, VStack
from mojoui.clock import now_ns
from themes.liquid import liquid_palette


def public(on: Bool):
    _ = setenv("MOJOUI_PUBLIC", "1" if on else "0", True)


def sql_rules() raises:
    public(True)
    assert_equal(public_refusal("SELECT 1"), "")
    assert_equal(public_refusal("  -- a note\n/* another */ select a FROM t WHERE b = 'WITH x UNION y'"), "")
    assert_equal(public_refusal("((SELECT a FROM t))"), "")
    assert_equal(public_refusal("SELECT * FROM (SELECT a FROM t ORDER BY a) AS s"), "")  # (a subquery: the engine's budgets hold it)
    assert_equal(public_refusal('SELECT "union" FROM t'), "")
    assert_true(public_refusal("WITH x AS (SELECT 1) SELECT * FROM x").find("one SELECT") >= 0)
    assert_true(public_refusal("(WITH x AS (SELECT 1) SELECT * FROM x)").find("WITH") >= 0, "(WITH … passed the rule")
    assert_true(public_refusal("( ( with x AS (SELECT 1) SELECT * FROM x ) )").find("WITH") >= 0)
    assert_true(public_refusal("/* x */ (\n-- y\nWITH x AS (SELECT 1) SELECT * FROM x)").find("WITH") >= 0)
    assert_true(public_refusal("SELECT * FROM (WITH x AS (SELECT 1) SELECT * FROM x) AS y").find("WITH") >= 0)
    assert_true(public_refusal("SELECT a FROM t UNION ALL SELECT a FROM t").find("UNION") >= 0)
    assert_true(public_refusal("SELECT a FROM t INTERSECT SELECT a FROM u").find("INTERSECT") >= 0)
    assert_true(public_refusal("SELECT * FROM (SELECT a FROM t EXCEPT SELECT a FROM u) AS d").find("EXCEPT") >= 0)
    assert_true(public_refusal("DELETE FROM t") != "")
    assert_true(public_refusal("(VALUES (1))") != "")
    assert_true(public_refusal("   ") != "")
    var capped = capped_sql("SELECT a FROM t -- the last word", 10)
    assert_true(capped.find("LIMIT 11") >= 0 and capped.find("\n) AS answer") >= 0, capped)  # (the comment ends at its line)
    assert_true(capped_sql("/* first */ SELECT a FROM t;", 10).find("LIMIT 11") >= 0)
    assert_equal(capped_sql("SELECT a FROM t", 0), "SELECT a FROM t")
    public(False)
    assert_equal(public_refusal("WITH x AS (SELECT 1) SELECT * FROM x"), "")  # (a desktop: anything the engine takes)
    print("sql rules: ok")


def places() raises:
    public(True)
    _ = setenv("MOJOUI_QUESTIONS", "2", True)
    _ = setenv("MOJOUI_QUESTION_WAIT_S", "1", True)
    var before = questions_running()
    var a = take_question()
    var b = take_question()
    assert_true(a and b)
    assert_equal(questions_running(), before + 2)
    var refused = False
    try:
        _ = take_question()
    except e:
        refused = String(e).find("other visitors") >= 0  # (after waiting MOJOUI_QUESTION_WAIT_S for a place)
    assert_true(refused, "a third question at once was let in")
    assert_equal(questions_running(), before + 2)
    give_back_question(a)
    give_back_question(b)
    assert_equal(questions_running(), before)
    public(False)
    assert_false(take_question())  # (a desktop: no limit, nothing counted)
    assert_equal(questions_running(), before)
    print("question places: ok")


def write_numbers(path: String, rows: Int) raises:
    var out = String("id,v\n")
    for i in range(rows):
        out += String(i) + "," + String((i * 7919) % 1000003) + "\n"
    with open(path, "w") as f:
        f.write(out)


def parking(folder: String) raises:
    public(True)
    _ = setenv("MOJOUI_QUESTIONS", "2", True)
    _ = setenv("MOJOUI_QUERY_THREADS", "1", True)
    _ = setenv("MOJOUI_QUERY_S", "1", True)
    var path = folder + "/public_rules_numbers.csv"
    write_numbers(path, 12_000_000)
    var pal = liquid_palette()
    var tables = TableCards(4100, 230, 4)
    var page = Sheet(read_table(path).table, False)
    var work = TableWork()
    var before = questions_running()
    # a sort inside a subquery: the engine has no stop check in it, so it runs on after the stop (the review's case)
    var slow = String("SELECT * FROM (SELECT id, v FROM nums ORDER BY v DESC, id) AS s")
    assert_true(work.ask(tables, slow, "nums", page, "Q1", pal), work.problem)
    sleep(0.3)  # (into its sort: a stop asked before the engine's first check would end it there)
    work.query_t0 = now_ns() - 100 * 1_000_000_000  # (as if it had run past the budget already)
    assert_true(work.check_budget(), "the time budget didn't stop the question")
    assert_true(work.problem.find("was stopped") >= 0, work.problem)
    assert_false(Bool(work.take_answer()))  # (parked: its thread still sorts)
    assert_equal(questions_running(), before + 1, "a stopped question no longer counted for the server while the engine ran it")
    assert_false(work.ask(tables, "SELECT COUNT(*) AS n FROM nums", "nums", page, "Q2", pal), "a second question started while the first still ran")
    assert_true(work.problem.find("still finishing") >= 0, work.problem)
    var waited = 0
    while questions_running() > before and waited < 120_000:
        sleep(0.01)
        waited += 10
    assert_equal(questions_running(), before, "the engine's end didn't give the place back")
    assert_true(work.ask(tables, "SELECT COUNT(*) AS n FROM nums", "nums", page, "Q3", pal), work.problem)
    var got = work.take_answer()
    waited = 0
    while not got and waited < 60_000:
        sleep(0.01)
        waited += 10
        got = work.take_answer()
    assert_true(Bool(got), "the next question never landed: " + work.problem)
    assert_equal(got.value().card.sheet.rows(), 1)
    assert_equal(questions_running(), before)
    public(False)
    print("check_budget and parking: ok (the stopped sort held its places, for the visitor and the server, until the engine ended it)")


def paths_and_files(folder: String) raises:
    public(True)
    var own = folder + "/visitor"
    assert_true(visitor_path_ok(own + "/a.csv", own))
    assert_true(visitor_path_ok(own + "/sub/a.csv", own + "/"))
    assert_false(visitor_path_ok(own + "/../a.csv", own))
    assert_false(visitor_path_ok(own + "x/a.csv", own))  # (a sibling folder that starts with the same name)
    assert_false(visitor_path_ok("/etc/passwd", own))
    assert_false(visitor_path_ok(own + "/a.csv", ""))
    public(False)
    assert_true(visitor_path_ok("/etc/passwd", own))  # (a desktop: anywhere)
    # files.mojo keeps nothing on disk in public mode: settings and the recent list stay in the session
    var home = folder + "/home" + String(now_ns())  # (a fresh one each run: the desktop half below writes there)
    makedirs(home, exist_ok=True)
    _ = setenv("XDG_CONFIG_HOME", home, True)
    _ = setenv("HOME", home, True)
    public(True)
    write_setting("publicrules", "skin", "dark")
    assert_equal(read_setting("publicrules", "skin", "light"), "light")
    var recent = List[String]()
    remember("publicrules", "/srv/visitor-a/secret.csv", recent)
    assert_equal(len(read_recent("publicrules")), 0)
    assert_false(file_exists(config_dir("publicrules") + "/settings.txt"), "public mode wrote a settings file")
    public(False)
    write_setting("publicrules", "skin", "dark")
    assert_equal(read_setting("publicrules", "skin", "light"), "dark")  # (a desktop keeps them)
    print("visitor paths and files: ok")


def choices() raises:
    var shown = VStack(Dropdown(["a", "b"], 0, 7))
    var at = -1
    for i in range(len(shown.nodes)):
        if shown.nodes[i].msg == 7:
            at = i
    assert_true(at >= 0, "no dropdown node")
    var e = control_event(shown, at, False, "anything", 1)
    assert_equal(e.message, 7)
    assert_equal(e.text, "b")  # (the option's text from the screen, not the sender)
    assert_equal(control_event(shown, at, False, "", 2).message, 0)  # (a number no option has: no event)
    assert_equal(control_event(shown, at, False, "", -1).message, 0)
    assert_equal(control_event(shown, len(shown.nodes), False, "", 0).message, 0)  # (no such node)
    print("control_event's choices: ok")


def peak_mb() -> Int:
    try:
        var text: String
        with open("/proc/self/status", "r") as f:
            text = f.read()
        for line in text.split("\n"):
            if line.startswith("VmHWM:"):
                return Int(String(String(String(line[byte = 6 :]).strip()).split(" ")[0])) // 1024
    except:
        pass
    return 0


def land(mut work: TableWork) raises -> Bool:
    var waited = 0
    while waited < 120_000:
        var a = work.take_answer()
        if a:
            return True
        if not work.query:
            return False
        sleep(0.01)
        waited += 10
    return False


def answers(folder: String) raises:
    """Round 4: an answer's bytes (columns × rows) are budgeted, kept answers count in the visitor's tables, and answers
    are capped: the review's 400 columns over 1M rows took ~4.8 GB."""
    public(True)
    assert_equal(answer_width("SELECT a, b, c FROM t", 10), 3)
    assert_equal(answer_width("SELECT COUNT(*), f(x, y) FROM t", 10), 2)
    assert_equal(answer_width("SELECT * FROM t", 10), 10)
    assert_equal(answer_width("SELECT t.*, x FROM t", 7), 8)
    assert_equal(answer_width("-- a, b\nSELECT 'a,b', (SELECT 1, 2) FROM t", 3), 2)
    _ = setenv("MOJOUI_QUERY_S", "60", True)
    _ = setenv("MOJOUI_QUESTION_WAIT_S", "1", True)
    var path = folder + "/public_rules_wide.csv"
    var out = String("id,v\n")
    for i in range(1_000_000):
        out += String(i) + "," + String(i % 997) + "\n"
    with open(path, "w") as f:
        f.write(out)
    var pal = liquid_palette()
    var tables = TableCards(4100, 230, 4)
    var page = Sheet(read_table(path).table, False)
    var work = TableWork()
    var cols = String("")
    for i in range(400):
        cols += ("" if i == 0 else ", ") + "v AS c" + String(i)
    with open("/proc/self/clear_refs", "w") as f:  # (5: the peak starts again from now)
        f.write("5")
    var before = peak_mb()
    assert_true(work.ask(tables, "SELECT " + cols + " FROM wide", "wide", page, "Q", pal), work.problem)
    assert_false(land(work), "400 columns of 1M rows were kept")
    var grew = peak_mb() - before
    assert_true(work.problem.find("would take more than") >= 0, work.problem)
    assert_true(grew < 600, "the refused wide answer took " + String(grew) + " MB at its peak")
    # an answer within the budget lands; with MOJOUI_ANSWERS=1 the next is refused until it's removed
    _ = setenv("MOJOUI_ANSWERS", "1", True)
    assert_true(work.ask(tables, "SELECT id, v FROM wide WHERE id < 1000", "wide", page, "A1", pal), work.problem)
    var got = work.take_answer()
    var waited = 0
    while not got and waited < 60_000:
        sleep(0.01)
        waited += 10
        got = work.take_answer()
    assert_true(Bool(got), work.problem)
    _ = tables.adopt(got.take().take_card(), 0, 0, 400, 300)
    assert_false(work.ask(tables, "SELECT id FROM wide WHERE id < 10", "wide", page, "A2", pal), "a second answer past MOJOUI_ANSWERS=1")
    assert_true(work.problem.find("answers on the page") >= 0, work.problem)
    # kept answers count in the visitor's tables: a 1 MB budget leaves no room once one answer is kept
    _ = setenv("MOJOUI_ANSWERS", "8", True)
    _ = setenv("MOJOUI_VISITOR_TABLES_MB", "0", True)
    assert_false(work.ask(tables, "SELECT id FROM wide WHERE id < 10", "wide", page, "A3", pal), "a question past the visitor's tables")
    assert_true(work.problem.find("Your tables and answers") >= 0, work.problem)
    _ = setenv("MOJOUI_VISITOR_TABLES_MB", "384", True)
    public(False)
    print("answers: ok (400 columns × 1M rows refused, +" + String(grew) + " MB at the peak; the answer cap and the visitor's budget hold)")


def main() raises:
    var folder = getenv("PUBLIC_RULES_DIR", "build/test_public_rules.d")
    makedirs(folder, exist_ok=True)
    sql_rules()
    places()
    paths_and_files(folder)
    choices()
    parking(folder)
    answers(folder)
    print("public rules: ok")
