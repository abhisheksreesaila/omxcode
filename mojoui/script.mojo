# mojoui.script: a script over every table an app holds (goal 49 M1). The UI is a shell; the script is the driver: what a
# person or an agent writes to read, join and transform the board's tables, videos and (later) models, in one place.
# A script is statements, run in order:
#
#   frames = SELECT * FROM episode;                       -- name = SQL: the answer is kept as the table `frames`
#   joined = SELECT f.frame, tl.gripper FROM frames f JOIN telemetry tl ON …;   -- later statements read earlier names
#   boxes  = regions(episode, 3.0, 8.5);                  -- name = fn(args): a function from the app's registry
#   SELECT count(*) FROM boxes                            -- a bare SELECT: kept as result_N
#
#   var catalog = Catalog(); tables.add_to(catalog)       # the app's tables (mojoui.tablecard), by their SQL names
#   var run = run_script(bind_params(text, params), catalog, functions)
#   if run.problem: …        # "line 3: SQL error at line 1, column 8: …": the results before it are kept
#   for i in range(len(run.names)): run.names[i], run.tables[i]   # each result, in order (each one a card, in an app)
#
# SQL runs on omxcore (joins, CTEs, subqueries, JOIN LINKED once mojoui.asksql has written it out): no compile, the
# engine plans it. Functions are where models plug in: anything implementing ScriptFunctions (has, call) turns its
# arguments (words, numbers, quoted text; a table's name is a word) into a table. Comments are `--` to the line's end;
# `;` inside single quotes doesn't end a statement; ${name} is a parameter (bind_params), so a saved script is a recipe
# another person reruns on their own data.

from std.time import perf_counter_ns
from omxcore import Catalog, Table, SharedTable, Frame as MxFrame, sql

comptime STMT_SQL = 0
comptime STMT_FN = 1


@fieldwise_init
struct Statement(Copyable, Movable):
    """One statement: its result's name ("" for a bare query), its body, its first line in the script, SQL or a call."""

    var name: String
    var text: String
    var line: Int
    var kind: Int
    var fn_name: String
    var args: List[String]


trait ScriptFunctions:
    """The functions a script may call: a registry the app (or a model plugin) provides."""

    def has(self, name: String) -> Bool:
        ...

    def call(mut self, name: String, args: List[String], mut catalog: Catalog) raises -> Table:
        ...


struct NoFunctions(ScriptFunctions):
    """A registry with nothing in it: scripts of SQL only."""

    def __init__(out self):
        pass

    def has(self, name: String) -> Bool:
        return False

    def call(mut self, name: String, args: List[String], mut catalog: Catalog) raises -> Table:
        raise Error("no function " + name)


struct ScriptRun(Movable):
    """What a run left: the named results in order, a line per statement, and the first problem (and its line)."""

    var names: List[String]
    var tables: List[SharedTable]
    var log: List[String]
    var problem: String
    var line: Int

    def __init__(out self):
        self.names = List[String]()
        self.tables = List[SharedTable]()
        self.log = List[String]()
        self.problem = ""
        self.line = 0


def _is_word(b: UInt8) -> Bool:
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95


def _is_space(b: UInt8) -> Bool:
    return b == 32 or b == 9 or b == 10 or b == 13


def _statement(raw: String, line: Int) raises -> Statement:
    """A statement from its text (comments gone): `name = body` or a bare body; a body that is `word(args)` is a call."""
    var s = String(raw.strip())
    var bytes = s.as_bytes()
    var n = s.byte_length()
    var name = String("")
    var i = 0
    while i < n and _is_word(bytes[i]):
        i += 1
    var j = i
    while j < n and _is_space(bytes[j]):
        j += 1
    if i > 0 and j < n and bytes[j] == UInt8(61) and (j + 1 >= n or bytes[j + 1] != UInt8(61)):
        name = String(s[byte=0:i])
        if bytes[0] >= 48 and bytes[0] <= 57:
            raise Error("line " + String(line) + ": a result's name starts with a letter: " + name)
        s = String(String(s[byte = j + 1 :]).strip())
    # a call: word(…) and nothing after the closing parenthesis
    var body = s.as_bytes()
    var m = s.byte_length()
    var k = 0
    while k < m and _is_word(body[k]):
        k += 1
    var head = String(s[byte=0:k]).lower()
    if k > 0 and k < m and body[k] == UInt8(40) and body[m - 1] == UInt8(41) and head != "select" and head != "with" and head != "values":
        var args = List[String]()
        var depth = 0
        var quoted = False
        var start = k + 1
        for p in range(k + 1, m - 1):
            var b = body[p]
            if b == UInt8(39):
                quoted = not quoted
            elif not quoted and b == UInt8(40):
                depth += 1
            elif not quoted and b == UInt8(41):
                depth -= 1
            elif not quoted and depth == 0 and b == UInt8(44):
                args.append(_arg(String(s[byte=start:p])))
                start = p + 1
        var last = String(String(s[byte = start : m - 1]).strip())
        if last != "" or len(args) > 0:
            args.append(_arg(last))
        return Statement(name, s, line, STMT_FN, String(s[byte=0:k]), args^)
    return Statement(name, s, line, STMT_SQL, "", List[String]())


def _arg(raw: String) -> String:
    """An argument as the function gets it: trimmed, a 'quoted' one without its quotes ('' is one quote)."""
    var a = String(raw.strip())
    if a.byte_length() >= 2 and a.startswith("'") and a.endswith("'"):
        return String(a[byte = 1 : a.byte_length() - 1]).replace("''", "'")
    return a


def strip_comments(text: String) -> String:
    """`text` without its `--` comments (outside single quotes); each comment's newline stays, so lines keep their
    numbers. Byte ranges are copied whole, so any UTF-8 text comes through intact."""
    var bytes = text.as_bytes()
    var n = text.byte_length()
    var out = String("")
    var seg = 0
    var quoted = False
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == UInt8(39):
            quoted = not quoted
        elif not quoted and b == UInt8(45) and i + 1 < n and bytes[i + 1] == UInt8(45):
            out += String(text[byte=seg:i])
            while i < n and bytes[i] != UInt8(10):
                i += 1
            seg = i
            continue
        i += 1
    return out + String(text[byte=seg:n])


def parse_script(text: String) raises -> List[Statement]:
    """The script's statements in order (raises "line N: …" for a bad one). `;` inside single quotes doesn't end a
    statement; `--` (outside quotes) comments to the line's end; empty statements (`;;`) are skipped."""
    var out = List[Statement]()
    var plain = strip_comments(text)
    var bytes = plain.as_bytes()
    var n = plain.byte_length()
    var seg = 0  # where the current statement's text starts
    var first = 0  # the line the current statement starts on (0: nothing in it yet)
    var line = 1
    var quoted = False
    for i in range(n):
        var b = bytes[i]
        if b == UInt8(39):
            quoted = not quoted
        if not quoted and b == UInt8(59):
            if first > 0:
                out.append(_statement(String(plain[byte=seg:i]), first))
            seg = i + 1
            first = 0
        elif first == 0 and not _is_space(b):
            first = line
        if b == UInt8(10):
            line += 1
    if quoted:
        raise Error("line " + String(line) + ": a quote is never closed")
    if first > 0:
        out.append(_statement(String(plain[byte=seg:n]), first))
    return out^


def bind_params(text: String, params: Dict[String, String]) raises -> String:
    """`text` with every ${name} replaced by its value, as written (raises for a name `params` doesn't have). Values go
    in as text, unquoted and unescaped: the script quotes them where it wants a string ('${episode}'); a value with a
    quote or a semicolon changes the statement, which is fine for a person's own data and nothing else."""
    var out = String("")
    var rest = text
    while True:
        var at = rest.find("${")
        if at < 0:
            break
        var end = rest.find("}", at)
        if end < 0:
            raise Error("a ${ is never closed")
        var key = String(rest[byte = at + 2 : end])
        if not (key in params):
            raise Error("no value for ${" + key + "}")
        out += String(rest[byte=0:at]) + params[key]
        var tail = String(rest[byte = end + 1 :])
        rest = tail
    return out + rest


def params_of(text: String) -> List[String]:
    """The ${names} a script asks for, once each, in order (a recipe's questions when it's reopened); a ${name} in a
    comment isn't asked."""
    var out = List[String]()
    var rest = strip_comments(text)
    while True:
        var at = rest.find("${")
        if at < 0:
            break
        var end = rest.find("}", at)
        if end < 0:
            break
        var key = String(rest[byte = at + 2 : end])
        if not (key in out):
            out.append(key)
        var tail = String(rest[byte = end + 1 :])
        rest = tail
    return out^


def last_call(text: String, names: List[String]) -> Optional[Statement]:
    """The script's last call to one of `names` (e.g. the video functions: what an export cuts), or None."""
    var found: Optional[Statement] = None
    try:
        for st in parse_script(text):
            if st.kind == STMT_FN and st.fn_name in names:
                found = st.copy()
    except:
        pass  # (a script that doesn't parse can't have run either: it applied nothing)
    return found^


def _short(s: String, most: Int = 72) -> String:
    var one = s.replace("\n", " ")
    if one.byte_length() <= most:
        return one
    return String(one[byte=0:most]) + "…"


def run_script[F: ScriptFunctions](text: String, mut catalog: Catalog, mut functions: F, taken: List[String] = List[String]()) -> ScriptRun:
    """Every statement in order over `catalog`; each result joins the catalog under its name, so later statements read
    it. Stops at the first problem ("line N: …"), keeping the results before it. `taken`: names the catalog's own
    tables hold (a result may not hide one: "line N: x is a table here already")."""
    var run = ScriptRun()
    var statements: List[Statement]
    try:
        statements = parse_script(text)
    except e:
        run.problem = String(e)
        if run.problem.startswith("line "):
            var sp = run.problem.find(":")
            try:
                run.line = Int(String(run.problem[byte = 5:sp]))
            except:
                pass
        return run^
    for k in range(len(statements)):
        ref st = statements[k]
        var name = st.name if st.name != "" else "result_" + String(k + 1)
        var t0 = perf_counter_ns()
        try:
            if name in taken:
                raise Error(name + " is a table here already: give the result another name")
            var t: Table
            if st.kind == STMT_FN:
                if not functions.has(st.fn_name):
                    raise Error("no function " + st.fn_name)
                t = functions.call(st.fn_name, st.args, catalog)
            else:
                var answer = sql(catalog, st.text)
                t = answer.take_table()
            var rows = t.rows()
            var shared = t^.share()
            catalog.add_frame(name, MxFrame(shared))
            run.names.append(name)
            run.tables.append(shared)
            var ms = Float64(perf_counter_ns() - t0) / 1e6
            run.log.append(name + " = " + _short(st.text) + " → " + String(rows) + " rows in " + String(Int(ms * 10.0 + 0.5) // 10) + "." + String(Int(ms * 10.0 + 0.5) % 10) + " ms")
        except e:
            run.problem = "line " + String(st.line) + ": " + String(e)
            run.line = st.line
            return run^
    return run^
