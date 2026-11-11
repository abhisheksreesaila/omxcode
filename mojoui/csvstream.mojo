# mojoui.csvstream: a query's rows streamed as CSV (goal 66 M4): RFC 4180 quoting (CRLF rows; a field with a comma, a
# quote, CR or LF in double quotes, quotes doubled) and a guard against formula injection: a text cell that starts with
# = + - @, tab or CR gets a leading ' so a spreadsheet shows it as text (numbers stored as numbers are written as they
# are: -12.5 stays a number). Written by a thread of its own into a mojoui.serve Pipe, so a large export never sits in
# memory and the reactor never waits on SQLite.
#
#   if req.matches("GET", "/api/transactions.csv"):
#       return stream_csv(tenant_db_path, "SELECT date, amount, merchant FROM transactions ORDER BY date", args,
#                         header, "transactions.csv")
from std.memory.alloc import unsafe_alloc
from std.memory import Pointer
from mojoui.serve import Reply, Pipe, spawn
from mojoui.sqlite import Pool, SQLITE_INTEGER, SQLITE_FLOAT, SQLITE_NULL


def csv_field(value: String, guard: Bool = True) -> String:
    var v = value
    if guard and v.byte_length() > 0:
        var c = v.as_bytes()[0]
        if c == UInt8(ord("=")) or c == UInt8(ord("+")) or c == UInt8(ord("-")) or c == UInt8(ord("@")) or c == UInt8(9) or c == UInt8(13):
            v = "'" + v
    var quote = False
    for b in v.as_bytes():
        if b == UInt8(ord(",")) or b == UInt8(ord('"')) or b == UInt8(10) or b == UInt8(13):
            quote = True
            break
    if not quote:
        return v^
    return '"' + v.replace('"', '""') + '"'


def csv_row(fields: List[String]) -> String:
    var out = String("")
    for i in range(len(fields)):
        out += ("," if i > 0 else "") + csv_field(fields[i])
    return out + "\r\n"


struct _CsvJob(Movable):
    var path: String
    var sql: String
    var args: List[String]
    var header: List[String]
    var pipe: Pipe

    def __init__(out self, path: String, sql: String, var args: List[String], var header: List[String], pipe: Pipe):
        self.path = path
        self.sql = sql
        self.args = args^
        self.header = header^
        self.pipe = pipe


def stream_csv(db_path: String, sql: String, var args: List[String], var header: List[String], filename: String) -> Reply:
    """A reply that streams the query's rows (args bound as text) under `header`, written on a thread of its own."""
    var pipe = Pipe()
    var job = unsafe_alloc[_CsvJob](1)
    job.unsafe_write(_CsvJob(db_path, sql, args^, header^, pipe.share()))
    var r = Reply.csv(pipe, filename)
    if not spawn[_csv_run](Int(job)):
        var j = Pointer[_CsvJob, MutUntrackedOrigin](unsafe_from_address=Int(job))
        j[].pipe.close()
        j[].pipe.release()
        j.unsafe_deinit_pointee()
        j.unsafe_free()
        pipe.release()
        return Reply.error(503, "no thread for the export: try again", "busy")
    pipe.release()
    return r^


def _csv_run(addr: Int):
    var j = Pointer[_CsvJob, MutUntrackedOrigin](unsafe_from_address=addr)
    var pipe = j[].pipe
    try:
        var db = Pool.shared().open(j[].path)
        var st = db.prepare(j[].sql)
        for i in range(len(j[].args)):
            st.bind(i + 1, j[].args[i])
        var chunk = csv_row(j[].header)
        while st.step():
            if pipe.gone():
                break
            for c in range(st.columns()):
                var k = st.kind(c)
                var cell: String
                if k == SQLITE_INTEGER:
                    cell = String(st.int(c))
                elif k == SQLITE_FLOAT:
                    cell = String(st.float(c))
                elif k == SQLITE_NULL:
                    cell = ""
                else:
                    cell = csv_field(st.text(c))
                chunk += ("," if c > 0 else "") + cell
            chunk += "\r\n"
            if chunk.byte_length() >= 32 * 1024:
                pipe.write(chunk)
                chunk = ""
        st.reset()
        if chunk != "":
            pipe.write(chunk)
    except e:
        pipe.write("\r\n# export failed\r\n")
    pipe.close()
    pipe.release()
    j.unsafe_deinit_pointee()
    j.unsafe_free()
