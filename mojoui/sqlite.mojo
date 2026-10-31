# mojoui.sqlite: SQLite for apps that keep data (goal 42): open a file, prepared statements with bound values,
# transactions, SQLite's own error messages, FTS5 full-text search (built into the system's library and pixi's).
#
#   var db = Database(path)                                   # created if missing
#   db.exec("CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, title TEXT)")
#   var ins = db.prepare("INSERT INTO notes(title) VALUES (?)")
#   ins.bind(1, "Groceries"); ins.run()                       # (run: step to the end, then reset for the next use)
#   var q = db.prepare("SELECT id, title FROM notes WHERE title LIKE ?")
#   q.bind(1, "G%")
#   while q.step(): print(q.int(0), q.text(1))
#   db.begin(); …; db.commit()                                # or db.rollback()
#
# Errors raise with SQLite's message ("near \"SELEC\": syntax error"); the connection stays usable after one.
# How: the C library is loaded when the first Database opens (dlopen, looked up by address: libsqlite3.so.0 on Linux, the system's
# /usr/lib/libsqlite3.dylib on the Mac), and its functions are called through their addresses, as mojoui.jobs calls
# libc's read(): no link flag on any host, and `mojo run` (whose JIT can't resolve a library it wasn't given) works
# too (D-1304). A Database and its statements belong to one thread: a job opens its own Database on the same file
# (WAL mode lets the UI read while a job writes, D-1306).

from std.ffi import external_call, c_int, c_char
from std.sys import CompilationTarget
from std.memory import Pointer, ArcPointer
from mojoui.shared import get_shared, put_shared

comptime SQLITE_OK = 0
comptime SQLITE_ROW = 100
comptime SQLITE_DONE = 101
comptime SQLITE_INTEGER = 1
comptime SQLITE_FLOAT = 2
comptime SQLITE_TEXT = 3
comptime SQLITE_BLOB = 4
comptime SQLITE_NULL = 5
comptime _OPEN_READWRITE = 0x2
comptime _OPEN_CREATE = 0x4
comptime SLOT_SQLITE_LIB = 94  # mojoui.shared slot: the loaded library (90–93 are mojoui.jobs and geometry's)
comptime _TRANSIENT = -1  # (SQLite copies a bound value at once)


def _dlsym(handle: Int, name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](handle, n.as_c_string_span())


def _library() raises -> Int:
    """The C library's handle, loaded once per process and kept (every statement holds raw function addresses).
    dlopen is itself looked up and called by address: GTK's host declares it (pointer, int) → int and the standard
    library's OwnedDLHandle another way (the web's Python module uses that), and a program may declare a C function
    only once, so this declares neither (D-1311)."""
    var have = get_shared(SLOT_SQLITE_LIB)
    if have != 0:
        return have
    var anywhere = -2 if CompilationTarget.is_macos() else 0  # RTLD_DEFAULT
    var dlopen = _dlsym(anywhere, "dlopen")
    if dlopen == 0:
        raise Error("sqlite: no dlopen in this process")
    var names = List[String]()
    comptime if CompilationTarget.is_macos():
        names.append("/usr/lib/libsqlite3.dylib")
    else:
        names.append("libsqlite3.so.0")
        names.append("libsqlite3.so")
    for name in names:
        var n = name
        var h = _fn[def(Int, c_int) thin abi("C") -> Int](dlopen)(Int(n.as_c_string_span().unsafe_ptr()), c_int(2))  # RTLD_NOW
        if h != 0:
            put_shared(SLOT_SQLITE_LIB, h)
            return h
    raise Error("sqlite: the SQLite library isn't installed (libsqlite3)")


def _c_text(addr: Int) -> String:
    if addr == 0:
        return String("")
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


@fieldwise_init
struct _Lib(ImplicitlyCopyable, Movable):
    """The functions used, by address."""
    var open_v2: Int
    var close_v2: Int
    var prepare_v2: Int
    var finalize: Int
    var step: Int
    var reset: Int
    var clear_bindings: Int
    var bind_text: Int
    var bind_int64: Int
    var bind_double: Int
    var bind_null: Int
    var column_count: Int
    var column_type: Int
    var column_int64: Int
    var column_double: Int
    var column_text: Int
    var column_bytes: Int
    var errmsg: Int
    var exec: Int
    var last_insert_rowid: Int
    var changes: Int
    var busy_timeout: Int

    @staticmethod
    def load() raises -> _Lib:
        var h = _library()
        var lib = _Lib(
            _dlsym(h, "sqlite3_open_v2"), _dlsym(h, "sqlite3_close_v2"), _dlsym(h, "sqlite3_prepare_v2"),
            _dlsym(h, "sqlite3_finalize"), _dlsym(h, "sqlite3_step"), _dlsym(h, "sqlite3_reset"),
            _dlsym(h, "sqlite3_clear_bindings"), _dlsym(h, "sqlite3_bind_text"), _dlsym(h, "sqlite3_bind_int64"),
            _dlsym(h, "sqlite3_bind_double"), _dlsym(h, "sqlite3_bind_null"), _dlsym(h, "sqlite3_column_count"),
            _dlsym(h, "sqlite3_column_type"), _dlsym(h, "sqlite3_column_int64"), _dlsym(h, "sqlite3_column_double"),
            _dlsym(h, "sqlite3_column_text"), _dlsym(h, "sqlite3_column_bytes"), _dlsym(h, "sqlite3_errmsg"), _dlsym(h, "sqlite3_exec"),
            _dlsym(h, "sqlite3_last_insert_rowid"), _dlsym(h, "sqlite3_changes"), _dlsym(h, "sqlite3_busy_timeout"),
        )
        if lib.open_v2 == 0 or lib.column_bytes == 0 or lib.prepare_v2 == 0 or lib.bind_double == 0 or lib.busy_timeout == 0:
            raise Error("sqlite: the SQLite library is missing functions")
        return lib


def _fn[T: ImplicitlyCopyable](addr: Int) -> T:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    return Pointer(to=raw).unsafe_bitcast[T]()[]


# (the C signatures, as Mojo function types)
comptime _F_P = def(Int) thin abi("C") -> c_int  # (sqlite3*) / (sqlite3_stmt*) → int
comptime _F_PP = def(Int) thin abi("C") -> Int  # → pointer or int64
comptime _F_PI = def(Int, c_int) thin abi("C") -> c_int
comptime _F_PI_P = def(Int, c_int) thin abi("C") -> Int
comptime _F_PI_D = def(Int, c_int) thin abi("C") -> Float64


struct _Conn(Movable):
    """The open connection, shared by the Database and its statements (ArcPointer): it closes after the last of them
    goes (Mojo ends a value after its last use, which can be before a statement made from it is done)."""
    var db: Int
    var lib: _Lib

    def __init__(out self, db: Int, lib: _Lib):
        self.db = db
        self.lib = lib

    def __deinit__(deinit self):
        if self.db != 0:
            _ = _fn[_F_P](self.lib.close_v2)(self.db)


struct Statement(Movable):
    """A prepared statement: bind values (from 1), step through its rows, read columns (from 0). Reused after reset()."""
    var st: Int
    var db: Int
    var lib: _Lib
    var conn: ArcPointer[_Conn]  # (keeps the connection open while the statement lives)

    def __init__(out self, st: Int, conn: ArcPointer[_Conn]):
        self.st = st
        self.db = conn[].db
        self.lib = conn[].lib
        self.conn = conn

    def __deinit__(deinit self):
        if self.st != 0:
            _ = _fn[_F_P](self.lib.finalize)(self.st)

    def _check(self, rc: c_int) raises:
        if Int(rc) != SQLITE_OK:
            raise Error("sqlite: " + _c_text(_fn[_F_PP](self.lib.errmsg)(self.db)))

    def bind(mut self, index: Int, value: String) raises:
        var v = value
        var f = _fn[def(Int, c_int, Int, c_int, Int) thin abi("C") -> c_int](self.lib.bind_text)
        self._check(f(self.st, c_int(index), Int(v.unsafe_ptr()), c_int(v.byte_length()), _TRANSIENT))
        _ = v.byte_length()  # (alive through the call: SQLite has copied it)

    def bind(mut self, index: Int, value: Int) raises:
        var f = _fn[def(Int, c_int, Int) thin abi("C") -> c_int](self.lib.bind_int64)
        self._check(f(self.st, c_int(index), value))

    def bind(mut self, index: Int, value: Float64) raises:
        var f = _fn[def(Int, c_int, Float64) thin abi("C") -> c_int](self.lib.bind_double)
        self._check(f(self.st, c_int(index), value))

    def bind_null(mut self, index: Int) raises:
        self._check(_fn[_F_PI](self.lib.bind_null)(self.st, c_int(index)))

    def step(mut self) raises -> Bool:
        """The next row (True), or the end (False). Raises with SQLite's message on an error (a constraint, a lock)."""
        var rc = Int(_fn[_F_P](self.lib.step)(self.st))
        if rc == SQLITE_ROW:
            return True
        if rc == SQLITE_DONE:
            return False
        var why = _c_text(_fn[_F_PP](self.lib.errmsg)(self.db))
        _ = _fn[_F_P](self.lib.reset)(self.st)
        raise Error("sqlite: " + why)

    def reset(mut self):
        """Ready to run again, with fresh bindings."""
        _ = _fn[_F_P](self.lib.reset)(self.st)
        _ = _fn[_F_P](self.lib.clear_bindings)(self.st)

    def run(mut self) raises:
        """Steps to the end (an INSERT, UPDATE or DELETE), then reset()."""
        try:
            while self.step():
                pass
        except e:
            self.reset()
            raise e^
        self.reset()

    def columns(self) -> Int:
        return Int(_fn[_F_P](self.lib.column_count)(self.st))

    def is_null(self, col: Int) -> Bool:
        return Int(_fn[_F_PI](self.lib.column_type)(self.st, c_int(col))) == SQLITE_NULL

    def int(self, col: Int) -> Int:
        return _fn[_F_PI_P](self.lib.column_int64)(self.st, c_int(col))

    def float(self, col: Int) -> Float64:
        return _fn[_F_PI_D](self.lib.column_double)(self.st, c_int(col))

    def text(self, col: Int) -> String:
        """The column as UTF-8 text ("" for NULL), all of its bytes (an embedded NUL included: sqlite3_column_bytes,
        not the C string's end); bytes that aren't UTF-8 (a file another program wrote) read as U+FFFD."""
        var addr = _fn[_F_PI_P](self.lib.column_text)(self.st, c_int(col))  # (text first, then its length: SQLite's order)
        var n = Int(_fn[_F_PI](self.lib.column_bytes)(self.st, c_int(col)))
        if addr == 0 or n <= 0:
            return String("")
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
        var out = List[UInt8](capacity=n)
        for i in range(n):
            out.append(p.unsafe_offset(i)[])
        try:
            return String(from_utf8=Span(out))
        except:
            return String(from_utf8_lossy=Span(out))


struct Database(Movable):
    """One connection to a SQLite file (made if missing). Closed when it and every statement made from it have gone."""
    var db: Int
    var lib: _Lib
    var path: String
    var conn: ArcPointer[_Conn]

    def __init__(out self, path: String, busy_ms: Int = 5000) raises:
        self.lib = _Lib.load()
        self.path = path
        self.db = 0
        var p = path
        var out = List[Int](length=1, fill=0)
        var f = _fn[def(Int, Int, c_int, Int) thin abi("C") -> c_int](self.lib.open_v2)
        var rc = f(Int(p.as_c_string_span().unsafe_ptr()), Int(out.unsafe_ptr()), c_int(_OPEN_READWRITE | _OPEN_CREATE), 0)
        self.db = out[0]
        self.conn = ArcPointer(_Conn(self.db, self.lib))  # (closes it, failed opens too: SQLite wants a close either way)
        if Int(rc) != SQLITE_OK:
            var why = _c_text(_fn[_F_PP](self.lib.errmsg)(self.db)) if self.db != 0 else String("out of memory")
            raise Error("sqlite: can't open " + path + ": " + why)
        _ = _fn[_F_PI](self.lib.busy_timeout)(self.db, c_int(busy_ms))  # (another connection writing: wait, don't fail)

    def error(self) -> String:
        """SQLite's message for the last thing that failed on this connection."""
        return _c_text(_fn[_F_PP](self.lib.errmsg)(self.db))

    def exec(self, sql: String) raises:
        """Runs one or more statements with no values to bind (CREATE, PRAGMA, BEGIN)."""
        var s = sql
        var f = _fn[def(Int, Int, Int, Int, Int) thin abi("C") -> c_int](self.lib.exec)
        var rc = f(self.db, Int(s.as_c_string_span().unsafe_ptr()), 0, 0, 0)
        if Int(rc) != SQLITE_OK:
            raise Error("sqlite: " + self.error())

    def prepare(self, sql: String) raises -> Statement:
        var s = sql
        var out = List[Int](length=1, fill=0)
        var f = _fn[def(Int, Int, c_int, Int, Int) thin abi("C") -> c_int](self.lib.prepare_v2)
        var rc = f(self.db, Int(s.unsafe_ptr()), c_int(s.byte_length()), Int(out.unsafe_ptr()), 0)
        _ = s.byte_length()
        if Int(rc) != SQLITE_OK:
            raise Error("sqlite: " + self.error())
        if out[0] == 0:
            raise Error("sqlite: no statement in " + sql)
        return Statement(out[0], self.conn)

    def begin(self) raises:
        self.exec("BEGIN IMMEDIATE")

    def commit(self) raises:
        self.exec("COMMIT")

    def rollback(self) raises:
        self.exec("ROLLBACK")

    def last_id(self) -> Int:
        """The rowid of the last INSERT on this connection."""
        return _fn[_F_PP](self.lib.last_insert_rowid)(self.db)

    def changes(self) -> Int:
        """Rows the last INSERT, UPDATE or DELETE changed."""
        return Int(_fn[_F_P](self.lib.changes)(self.db))

    def count(self, sql: String) raises -> Int:
        """The first column of the first row of a query with no values ("SELECT count(*) FROM notes")."""
        var q = self.prepare(sql)
        if not q.step():
            return 0
        return q.int(0)


def fts_prefix_query(typed: String) -> String:
    """What a person typed in a search box as an FTS5 query that finds every word as a prefix ("lisb tr" →
    `"lisb"* "tr"*`: notes with a word starting lisb and one starting tr). Each word is quoted, so FTS5's own syntax
    (AND, NEAR, -, :, ^, quotes) is searched for as text, never run; "" when nothing searchable was typed."""
    var out = String("")
    for part in typed.split(" "):
        var word = String(part).strip()
        if word == "":
            continue
        var w = String(word).replace("\x00", "").replace('"', '""')  # (a pasted NUL would end FTS5's query text early)
        if w == "":
            continue
        if out != "":
            out += " "
        out += '"' + w + '"*'
    return out^
