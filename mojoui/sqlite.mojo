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
# /usr/lib/libsqlite3.dylib on the Mac), and its functions are called through their addresses, as mojoui.uijobs calls
# libc's read(): no link flag on any host, and `mojo run` (whose JIT can't resolve a library it wasn't given) works
# too (D-1304). A Database and its statements belong to one thread: a job opens its own Database on the same file
# (WAL mode lets the UI read while a job writes, D-1306).
#
# Servers (goal 60, D-6009): `Pool.shared().open(path)` is this thread's own connection to the file (opened on first use,
# WAL + synchronous=NORMAL, closed when the thread ends), so request threads never share one; `begin()` on a pooled
# connection takes the file's in-process writer lock first, so writers queue on a mutex instead of SQLite's sleeping
# busy handler. Statements are cached per connection: prepare() of the same SQL again reuses the compiled statement.
# The pool's connections use at most `budget()` file descriptors (half the process's open-file limit; the soft limit is
# raised to the hard one when the pool is made), counted as SQLite's unix VFS uses them: a .db and a -wal descriptor a
# connection, one -shm a file, and a closed connection's .db descriptor kept until the last connection to its file
# closes (os_unix.c's pUnused: POSIX locks are per process). A thread opening one more first closes idle connections,
# its own before another thread's, a file with one connection before a shared one, least recently used first, so 16
# threads × a thousand tenants never run out of descriptors (EMFILE). Idle: nothing holds it but the pool (no Database
# copy, no statement) and it isn't inside a transaction (its file's writer lock): one in use is never closed (D-6018).

from std.ffi import external_call, c_int, c_char
from std.sys import CompilationTarget
from std.memory import Pointer, ArcPointer
from std.memory.alloc import alloc, Layout, unsafe_alloc
from mojoui.shared import get_shared, put_shared
from mojoui import libc

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
comptime SLOT_SQLITE_LIB = 94  # mojoui.shared slot: the loaded library (90–93 are mojoui.uijobs and geometry's)
comptime _TRANSIENT = -1  # (SQLite copies a bound value at once)
comptime SLOT_SQLITE_POOL = 97  # mojoui.shared slot: the process's Pool (95, 96 are mojoui.dbus's)
comptime _CACHE_MAX = 64  # statements kept per connection
comptime _MIN_BUDGET = 24  # descriptors


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
    goes (Mojo ends a value after its last use, which can be before a statement made from it is done). Keeps the idle
    compiled statements (by their SQL) and, for a pooled connection, its file's writer lock."""
    var db: Int
    var lib: _Lib
    var cache_sql: List[String]
    var cache_st: List[Int]
    var wlock: Int  # the file's in-process writer mutex (0: none, a plain Database)
    var held: Bool  # this connection holds it (between begin and commit/rollback)

    def __init__(out self, db: Int, lib: _Lib):
        self.db = db
        self.lib = lib
        self.cache_sql = List[String]()
        self.cache_st = List[Int]()
        self.wlock = 0
        self.held = False

    def take(mut self, sql: String) -> Int:
        for i in range(len(self.cache_sql)):
            if self.cache_sql[i] == sql:
                var st = self.cache_st[i]
                _ = self.cache_sql.pop(i)
                _ = self.cache_st.pop(i)
                return st
        return 0

    def give(mut self, sql: String, st: Int) -> Bool:
        if len(self.cache_st) >= _CACHE_MAX:
            return False
        for s in self.cache_sql:
            if s == sql:
                return False
        self.cache_sql.append(sql)
        self.cache_st.append(st)
        return True

    def __deinit__(deinit self):
        for st in self.cache_st:
            _ = _fn[_F_P](self.lib.finalize)(st)
        if self.held and self.wlock != 0:
            _ = libc.pthread_mutex_unlock(self.wlock)
        if self.db != 0:
            _ = _fn[_F_P](self.lib.close_v2)(self.db)


struct Statement(Movable):
    """A prepared statement: bind values (from 1), step through its rows, read columns (from 0). Reused after reset()."""
    var st: Int
    var db: Int
    var lib: _Lib
    var conn: ArcPointer[_Conn]  # (keeps the connection open while the statement lives)
    var sql: String  # (its key in the connection's cache)

    def __init__(out self, st: Int, conn: ArcPointer[_Conn], sql: String = ""):
        self.st = st
        self.db = conn[].db
        self.lib = conn[].lib
        self.conn = conn
        self.sql = sql

    def __deinit__(deinit self):
        if self.st == 0:
            return
        _ = _fn[_F_P](self.lib.reset)(self.st)
        _ = _fn[_F_P](self.lib.clear_bindings)(self.st)
        if self.sql == "" or not self.conn[].give(self.sql, self.st):
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


struct Database(Copyable, Movable):
    """One connection to a SQLite file (made if missing). Closed when it and every statement made from it have gone
    (a copy shares the connection)."""
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
        """A compiled statement: the connection's cached one for this SQL when it has one idle (it comes back when the
        Statement goes), else a new one."""
        var cached = self.conn[].take(sql)
        if cached != 0:
            return Statement(cached, self.conn, sql)
        var s = sql
        var out = List[Int](length=1, fill=0)
        var f = _fn[def(Int, Int, c_int, Int, Int) thin abi("C") -> c_int](self.lib.prepare_v2)
        var rc = f(self.db, Int(s.unsafe_ptr()), c_int(s.byte_length()), Int(out.unsafe_ptr()), 0)
        _ = s.byte_length()
        if Int(rc) != SQLITE_OK:
            raise Error("sqlite: " + self.error())
        if out[0] == 0:
            raise Error("sqlite: no statement in " + sql)
        return Statement(out[0], self.conn, sql)

    def begin(self) raises:
        """A write transaction (BEGIN IMMEDIATE); on a pooled connection, after taking the file's writer lock."""
        var took = False
        if self.conn[].wlock != 0 and not self.conn[].held:
            _ = libc.pthread_mutex_lock(self.conn[].wlock)
            self.conn[].held = True
            took = True
        try:
            self.exec("BEGIN IMMEDIATE")
        except e:
            if took:  # (a nested begin fails here too: never release the outer transaction's lock)
                self._release()
            raise e^

    def commit(self) raises:
        try:
            self.exec("COMMIT")
        except e:
            _ = self.rollback_quiet()
            raise e^
        self._release()

    def rollback(self) raises:
        try:
            self.exec("ROLLBACK")
        finally:
            self._release()

    def rollback_quiet(self) -> Bool:
        try:
            self.exec("ROLLBACK")
            self._release()
            return True
        except:
            self._release()
            return False

    def _release(self):
        if self.conn[].held:
            self.conn[].held = False
            _ = libc.pthread_mutex_unlock(self.conn[].wlock)

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

    def one_text(self, sql: String, args: List[String] = List[String]()) raises -> String:
        """The first column of the first row as text ("" when no row), each ? bound to the next of `args` as text: a
        reply SQLite builds itself, e.g. "SELECT json_group_array(json_object('name', name)) FROM models WHERE kind = ?"."""
        var q = self.prepare(sql)
        for i in range(len(args)):
            q.bind(i + 1, args[i])
        if not q.step():
            return ""
        return q.text(0)

    def run(self, sql: String, args: List[String] = List[String]()) raises -> Int:
        """Runs one statement with each ? bound to the next of `args` as text; the rows it changed."""
        var q = self.prepare(sql)
        for i in range(len(args)):
            q.bind(i + 1, args[i])
        q.run()
        return self.changes()


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


# per-thread connections (servers, D-6009, D-6018) --------------------------------------------------------------------

struct _ThreadDbs(Movable):
    """One thread's open connections, by path (in pthread thread-local storage; freed when the thread ends), each with
    its file's index in the pool and the tick it was last opened at. Its mutex guards the lists: the owner takes it to
    look one up, another thread over the budget takes it to close an idle one."""
    var paths: List[String]
    var dbs: List[Database]
    var files: List[Int]
    var used: List[Int]
    var tick: Int
    var mu: Int
    var pool: Int  # its _PoolState

    def __init__(out self, pool: Int):
        self.paths = List[String]()
        self.dbs = List[Database]()
        self.files = List[Int]()
        self.used = List[Int]()
        self.tick = 0
        self.mu = Int(unsafe_alloc[UInt8](64))
        _ = libc.pthread_mutex_init(self.mu)
        self.pool = pool

    def idle_best(self, conns: List[Int]) -> Int:
        """The connection to close first (call with `mu` held): idle (the pool's reference the only one: no Database
        copy, no statement; not inside a transaction), its file's only connection before a shared one, then least
        recently used. -1: none is idle."""
        var best = -1
        for i in range(len(self.paths)):
            ref d = self.dbs[i]
            if d.conn.count() != 1 or d.conn[].held:
                continue
            if best < 0:
                best = i
                continue
            var lone = conns[self.files[i]] == 1
            var best_lone = conns[self.files[best]] == 1
            if (lone and not best_lone) or (lone == best_lone and self.used[i] < self.used[best]):
                best = i
        return best

    def close_at(mut self, i: Int) -> Int:
        """Closes connection i (call with `mu` held): its file's index."""
        var f = self.files[i]
        _ = self.paths.pop(i)
        _ = self.used.pop(i)
        _ = self.files.pop(i)
        var gone = self.dbs.pop(i)
        _ = gone^  # (the last reference: the connection and its cached statements close here)
        return f


struct _PoolState(Movable):
    var key: Int  # the thread-local slot
    var mu: Int  # guards everything below (taken before a thread's own mutex, never after)
    var index: Dict[String, Int]  # a file's path → its index below
    var locks: List[Int]  # each file's writer mutex
    var conns: List[Int]  # each file's open pooled connections, all threads
    var pending: List[Int]  # each file's closed connections whose .db descriptor SQLite keeps until the last closes
    var recs: List[Int]  # every live thread's _ThreadDbs
    var fds: Int  # descriptors the pool's connections hold now (the model above)
    var budget: Int  # at most this many

    def __init__(out self, key: Int, mu: Int, budget: Int):
        self.key = key
        self.mu = mu
        self.index = Dict[String, Int]()
        self.locks = List[Int]()
        self.conns = List[Int]()
        self.pending = List[Int]()
        self.recs = List[Int]()
        self.fds = 0
        self.budget = budget

    def file(mut self, path: String) -> Int:
        """The file's index (made on first sight, with its writer mutex). Call with `mu` held."""
        var at = self.index.get(path, -1)
        if at >= 0:
            return at
        var mu = Int(unsafe_alloc[UInt8](64))
        _ = libc.pthread_mutex_init(mu)
        self.locks.append(mu)
        self.conns.append(0)
        self.pending.append(0)
        self.index[path] = len(self.locks) - 1
        return len(self.locks) - 1

    def opened(mut self, f: Int):
        """One more connection to file f: its .db (or a kept one SQLite reuses), its -wal, the file's -shm if first."""
        if self.pending[f] > 0:
            self.pending[f] -= 1  # (findReusableFd: the kept .db descriptor is this one's)
            self.fds -= 1
        self.fds += 2 + (1 if self.conns[f] == 0 else 0)
        self.conns[f] += 1

    def closed(mut self, f: Int):
        """One connection to file f gone: its -wal goes; its .db goes now if it was the file's last (with every kept
        one, and the -shm), else it is kept."""
        self.conns[f] -= 1
        if self.conns[f] == 0:
            self.fds -= 2 + 1 + self.pending[f]
            self.pending[f] = 0
        else:
            self.fds -= 1
            self.pending[f] += 1


def _drop_thread_dbs(addr: Int) abi("C"):
    if addr == 0:
        return
    var p = Pointer[_ThreadDbs, MutUntrackedOrigin](unsafe_from_address=addr)
    var st = Pointer[_PoolState, MutUntrackedOrigin](unsafe_from_address=p[].pool)
    _ = libc.pthread_mutex_lock(st[].mu)  # (out of the registry first: no other thread reaches it after this)
    for i in range(len(st[].recs)):
        if st[].recs[i] == addr:
            _ = st[].recs.pop(i)
            break
    _ = libc.pthread_mutex_lock(p[].mu)
    while len(p[].paths) > 0:  # (each closes now: a Database copy the thread left would end with it anyway)
        st[].closed(p[].close_at(len(p[].paths) - 1))
    _ = libc.pthread_mutex_unlock(p[].mu)
    _ = libc.pthread_mutex_unlock(st[].mu)
    p.unsafe_deinit_pointee()
    p.unsafe_free()


struct Pool(ImplicitlyCopyable, Movable):
    """The process's per-thread connections (one Pool per process: `Pool.shared()`). A handle: copy it freely."""
    var addr: Int

    def __init__(out self, *, addr: Int):
        self.addr = addr

    @staticmethod
    def shared() raises -> Pool:
        """The process's pool, made on the first call. (Call it while the program starts, before threads race to make it.)"""
        var have = get_shared(SLOT_SQLITE_POOL)
        if have != 0:
            return Pool(addr=have)
        var key = libc.pthread_key_create(_drop_thread_dbs)
        if key < 0:
            raise Error("sqlite: no thread-local slot for the pool")
        var mu = Int(unsafe_alloc[UInt8](64))
        _ = libc.pthread_mutex_init(mu)
        var soft = libc.raise_nofile()
        var st = alloc(Layout[_PoolState].single()).unsafe_leak()
        st.unsafe_write(_PoolState(key, mu, max((soft if soft > 0 else 1024) // 2, _MIN_BUDGET)))
        put_shared(SLOT_SQLITE_POOL, Int(st))
        return Pool(addr=Int(st))

    def _state(self) -> Pointer[_PoolState, MutUntrackedOrigin]:
        return Pointer[_PoolState, MutUntrackedOrigin](unsafe_from_address=self.addr)

    def budget(self) -> Int:
        """The pool's connections hold at most this many file descriptors, all threads together (beyond it only while
        every connection is in use)."""
        var s = self._state()
        _ = libc.pthread_mutex_lock(s[].mu)
        var b = s[].budget
        _ = libc.pthread_mutex_unlock(s[].mu)
        return b

    def set_budget(self, fds: Int):
        """Another budget (an app that knows its limits better; tests)."""
        var s = self._state()
        _ = libc.pthread_mutex_lock(s[].mu)
        s[].budget = max(fds, 4)
        _ = libc.pthread_mutex_unlock(s[].mu)

    def fds_now(self) -> Int:
        """Descriptors the pool's connections hold now, by the model above (tests)."""
        var s = self._state()
        _ = libc.pthread_mutex_lock(s[].mu)
        var n = s[].fds
        _ = libc.pthread_mutex_unlock(s[].mu)
        return n

    def open_here(self) -> Int:
        """This thread's open connections (tests)."""
        var mine = libc.pthread_getspecific(self._state()[].key)
        if mine == 0:
            return 0
        var t = Pointer[_ThreadDbs, MutUntrackedOrigin](unsafe_from_address=mine)
        _ = libc.pthread_mutex_lock(t[].mu)
        var n = len(t[].paths)
        _ = libc.pthread_mutex_unlock(t[].mu)
        return n

    def _close_one(self, mine: Int, from_others: Bool) -> Bool:
        """Closes the best idle connection of this thread (or of another one): False when none is idle. `mu` held."""
        var s = self._state()
        for r in s[].recs:
            if (r == mine) == from_others:
                continue
            var t = Pointer[_ThreadDbs, MutUntrackedOrigin](unsafe_from_address=r)
            _ = libc.pthread_mutex_lock(t[].mu)
            var i = t[].idle_best(s[].conns)
            if i >= 0:
                s[].closed(t[].close_at(i))
            _ = libc.pthread_mutex_unlock(t[].mu)
            if i >= 0:
                return True
        return False

    def _reserve(self, mine: Int, path: String) -> Int:
        """Room for one more connection to `path` (closing idle ones while it would pass the budget), counted at once
        so racing threads see it: the file's index."""
        var s = self._state()
        _ = libc.pthread_mutex_lock(s[].mu)
        var f = s[].file(path)
        while s[].fds + 3 > s[].budget:
            if not self._close_one(mine, False) and not self._close_one(mine, True):
                break  # (every connection in use: over the budget until they're done)
        s[].opened(f)
        _ = libc.pthread_mutex_unlock(s[].mu)
        return f

    def open(self, path: String, setup: String = "") raises -> Database:
        """This thread's connection to `path` (opened, with WAL and `setup`, on this thread's first use)."""
        var key = self._state()[].key
        var mine = libc.pthread_getspecific(key)
        if mine == 0:
            var rec = alloc(Layout[_ThreadDbs].single()).unsafe_leak()
            rec.unsafe_write(_ThreadDbs(self.addr))
            mine = Int(rec)
            _ = libc.pthread_setspecific(key, mine)
            var s = self._state()
            _ = libc.pthread_mutex_lock(s[].mu)
            s[].recs.append(mine)
            _ = libc.pthread_mutex_unlock(s[].mu)
        var t = Pointer[_ThreadDbs, MutUntrackedOrigin](unsafe_from_address=mine)
        _ = libc.pthread_mutex_lock(t[].mu)
        t[].tick += 1
        for i in range(len(t[].paths)):
            if t[].paths[i] == path:
                t[].used[i] = t[].tick
                var hit = t[].dbs[i].copy()
                _ = libc.pthread_mutex_unlock(t[].mu)
                return hit^
        _ = libc.pthread_mutex_unlock(t[].mu)
        var f = self._reserve(mine, path)
        var s = self._state()
        try:
            var db = Database(path)
            db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON")
            if setup != "":
                db.exec(setup)
            _ = libc.pthread_mutex_lock(s[].mu)
            db.conn[].wlock = s[].locks[f]
            _ = libc.pthread_mutex_lock(t[].mu)
            t[].paths.append(path)
            t[].dbs.append(db.copy())
            t[].files.append(f)
            t[].used.append(t[].tick)
            _ = libc.pthread_mutex_unlock(t[].mu)
            _ = libc.pthread_mutex_unlock(s[].mu)
            return db^
        except e:
            _ = libc.pthread_mutex_lock(s[].mu)
            s[].closed(f)
            _ = libc.pthread_mutex_unlock(s[].mu)
            raise e^
