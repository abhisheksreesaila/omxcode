# mojoui.log: structured logs for servers (goal 60 M1; fh-saas's utils_log): JSON lines, one object a line, secrets
# masked before anything is written, the file rotated by size. Thread-safe: one Log handle is shared by every request
# thread (a mutex around each line's write and the rotation). And `Audit`, the who-did-what table in a SQLite file.
#
#   var log = Log.open(getenv("SAAS_LOG"), max_bytes=10_000_000, keep=5)   # "" → JSON lines on stdout
#   log.secret(getenv("STRIPE_SECRET_KEY"))                                  # exact values never written
#   log.info("checkout", Fields().str("tenant", t).int("ms", 12))
#   → {"ts": 1762470000.123, "level": "info", "msg": "checkout", "tenant": "…", "ms": 12}
#   Audit.record(db, tenant, actor, "invite", detail)                         # host.db's audit(ts, tenant, actor, action, detail)
#
# Redaction (redact()): every registered secret, anywhere; and by shape: what follows "Bearer ", Stripe keys (sk_/rk_/
# whsec_ + their tail), cookie and query values named saas, code, state, token, access_token, refresh_token, id_token,
# client_secret, password, verifier, and anything under such a JSON key. Paths are logged without their query.

from std.os import getenv
from std.memory import Pointer
from std.memory.alloc import alloc, Layout, unsafe_alloc
from mojoui import libc
from mojoui.json import json_string
from mojoui.clock import wall_seconds
from mojoui.sqlite import Database

comptime MASK = "[redacted]"
comptime _SECRET_NAMES = ["saas", "code", "state", "token", "access_token", "refresh_token", "id_token", "client_secret",
                          "password", "verifier", "code_verifier", "secret", "authorization", "cookie", "session_id"]
comptime _SECRET_PREFIXES = ["sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_", "Bearer ", "Basic "]


def _is_word(c: UInt8) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 45 or c == 46 or c == 126 or c == 43 or c == 47 or c == 61 or c == 37


def _replace_all(text: String, needle: String, by: String) -> String:
    if needle.byte_length() == 0 or needle not in text:
        return text
    return text.replace(needle, by)


def redact(text: String, secrets: List[String]) -> String:
    """`text` with every secret masked (see the module's note)."""
    var out = text
    for s in secrets:
        if s.byte_length() >= 6:
            out = _replace_all(out, s, MASK)
    # by shape: a known prefix, then its token characters
    for pre in materialize[_SECRET_PREFIXES]():
        if pre not in out:
            continue
        var b = out.as_bytes()
        var res = String("")
        var i = 0
        var n = len(b)
        var pb = pre.as_bytes()
        var m = len(pb)
        while i < n:
            var hit = i + m <= n
            if hit:
                for k in range(m):
                    if b[i + k] != pb[k]:
                        hit = False
                        break
            if hit:
                var j = i + m
                while j < n and _is_word(b[j]):
                    j += 1
                res += pre + MASK
                i = j
            else:
                var j = i + 1
                while j < n and (b[j] & 0xC0) == 0x80:
                    j += 1
                res += String(StringSlice(unsafe_from_utf8=b[i:j]))
                i = j
        out = res
    # name=value (queries, cookies, forms) and "name": "value" (JSON)
    for name in materialize[_SECRET_NAMES]():
        out = _mask_named(out, name)
    return out


def _mask_named(text: String, name: String) -> String:
    if name not in text:
        return text
    var b = text.as_bytes()
    var nb = name.as_bytes()
    var n = len(b)
    var m = len(nb)
    var res = String("")
    var i = 0
    var last = 0
    while i + m < n:
        var hit = True
        for k in range(m):
            var c = b[i + k]
            if c >= 65 and c <= 90:
                c += 32
            if c != nb[k]:
                hit = False
                break
        if hit and i > 0 and _is_word(b[i - 1]) and b[i - 1] != 47 and b[i - 1] != 46:
            hit = False  # (part of a longer name: "postcode")
        if not hit:
            i += 1
            continue
        var j = i + m
        var quoted = False
        if j < n and b[j] == 34:  # "name": "value"
            j += 1
            while j < n and b[j] == 32:
                j += 1
            if j < n and b[j] == 58:
                j += 1
                while j < n and b[j] == 32:
                    j += 1
                if j < n and b[j] == 34:
                    quoted = True
                    j += 1
                else:
                    i += 1
                    continue
            else:
                i += 1
                continue
        elif j < n and (b[j] == 61 or b[j] == 58):  # name=value, name: value
            j += 1
            while j < n and b[j] == 32:
                j += 1
        else:
            i += 1
            continue
        var start = j
        if quoted:
            while j < n and b[j] != 34:
                j += 2 if b[j] == 92 else 1
        else:
            while j < n and b[j] != 38 and b[j] != 59 and b[j] != 32 and b[j] != 44 and b[j] != 34 and b[j] != 10:
                j += 1
        if j > n:
            j = n
        if j > start:
            res += String(StringSlice(unsafe_from_utf8=b[last:start])) + MASK
            last = j
        i = j
    res += String(StringSlice(unsafe_from_utf8=b[last:n]))
    return res


struct Fields(Copyable, Movable):
    """A log line's own fields, in order: `Fields().str("tenant", t).int("status", 200)`."""
    var body: String

    def __init__(out self):
        self.body = String("")

    def str(var self, key: String, value: String) -> Self:
        self.body += ", " + json_string(key) + ": " + json_string(value)
        return self^

    def int(var self, key: String, value: Int) -> Self:
        self.body += ", " + json_string(key) + ": " + String(value)
        return self^

    def num(var self, key: String, value: Float64) -> Self:
        self.body += ", " + json_string(key) + ": " + String(value)
        return self^


struct _LogState(Movable):
    var path: String
    var fd: Int  # -1: stdout
    var size: Int
    var max_bytes: Int
    var keep: Int
    var mu: Int
    var secrets: List[String]

    def __init__(out self, path: String, fd: Int, size: Int, max_bytes: Int, keep: Int, mu: Int):
        self.path = path
        self.fd = fd
        self.size = size
        self.max_bytes = max_bytes
        self.keep = keep
        self.mu = mu
        self.secrets = List[String]()


struct Log(ImplicitlyCopyable, Movable):
    """A handle to one log (copy it freely; every copy writes the same file under the same lock)."""
    var addr: Int

    def __init__(out self, *, addr: Int):
        self.addr = addr

    @staticmethod
    def open(path: String, max_bytes: Int = 10_000_000, keep: Int = 5) raises -> Log:
        """Appends to `path` (made 0600 if missing), rotating past `max_bytes` to path.1 … path.<keep>; "" → stdout."""
        var fd = -1
        var size = 0
        if path != "":
            fd = libc.open_append(path)
            if fd < 0:
                raise Error("log: can't open " + path)
            size = libc.file_size(fd)
        var mu = Int(unsafe_alloc[UInt8](64))
        _ = libc.pthread_mutex_init(mu)
        var st = alloc(Layout[_LogState].single()).unsafe_leak()
        st.unsafe_write(_LogState(path, fd, size, max_bytes, keep, mu))
        return Log(addr=Int(st))

    def _s(self) -> Pointer[_LogState, MutUntrackedOrigin]:
        return Pointer[_LogState, MutUntrackedOrigin](unsafe_from_address=self.addr)

    def secret(self, value: String):
        """Never write `value` (a key, a password): masked wherever it appears. (Register before serving starts.)"""
        if self.addr != 0 and value.byte_length() >= 6:
            self._s()[].secrets.append(value)

    def clean(self, text: String) -> String:
        if self.addr == 0:
            return redact(text, List[String]())
        return redact(text, self._s()[].secrets)

    def write(self, level: String, msg: String, fields: Fields = Fields()):
        var line = '{"ts": ' + String(Float64(Int(wall_seconds() * 1000)) / 1000) + ', "level": ' + json_string(level) + ', "msg": ' + json_string(msg) + fields.body + "}"
        self._line(self.clean(line))

    def info(self, msg: String, fields: Fields = Fields()):
        self.write("info", msg, fields)

    def warn(self, msg: String, fields: Fields = Fields()):
        self.write("warn", msg, fields)

    def error(self, msg: String, fields: Fields = Fields()):
        self.write("error", msg, fields)

    def request(self, rid: String, method: String, path: String, status: Int, ms: Float64, ip: String = ""):
        """One served request: its path without the query."""
        var q = path.find("?")
        var bare = String(path[byte = : q]) if q >= 0 else path
        var f = Fields().str("rid", rid).str("method", method).str("path", bare).int("status", status).num("ms", Float64(Int(ms * 1000)) / 1000)
        if ip != "":
            f = f^.str("ip", ip)
        self.write("error" if status >= 500 else "info", "request", f^)

    def _line(self, text: String):
        if self.addr == 0:  # (Log(addr=0): stdout, unlocked)
            print(text, flush=True)
            return
        var s = self._s()
        var data = text + "\n"
        _ = libc.pthread_mutex_lock(s[].mu)
        if s[].fd < 0:
            print(text, flush=True)
        else:
            if s[].size + data.byte_length() > s[].max_bytes and s[].size > 0:
                self._rotate()
            var off = 0
            var n = data.byte_length()
            var p = Int(data.unsafe_ptr())
            while off < n:
                var w = libc.write_fd(s[].fd, p + off, n - off)
                if w <= 0:
                    break
                off += w
            _ = data.byte_length()
            s[].size += off
        _ = libc.pthread_mutex_unlock(s[].mu)

    def _rotate(self):
        """path.<keep-1> → path.<keep> … path → path.1, then a fresh path (under the lock)."""
        var s = self._s()
        _ = libc.close(s[].fd)
        var k = s[].keep - 1
        while k >= 1:
            _ = libc.rename_path(s[].path + "." + String(k), s[].path + "." + String(k + 1))
            k -= 1
        if s[].keep >= 1:
            _ = libc.rename_path(s[].path, s[].path + ".1")
        s[].fd = libc.open_append(s[].path)
        s[].size = 0


struct Audit:
    """Who did what: rows in a SQLite file's `audit` table (host.db), for a tenant's admins to read."""

    comptime SCHEMA = "CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, tenant TEXT, actor TEXT, action TEXT NOT NULL, detail TEXT);CREATE INDEX IF NOT EXISTS audit_tenant ON audit(tenant, ts)"

    @staticmethod
    def record(db: Database, tenant: String, actor: String, action: String, detail: String = "") raises:
        """One row (autocommit, or inside the caller's transaction)."""
        var q = db.prepare("INSERT INTO audit(ts, tenant, actor, action, detail) VALUES (?, ?, ?, ?, ?)")
        q.bind(1, Int(wall_seconds()))
        q.bind(2, tenant)
        q.bind(3, actor)
        q.bind(4, action)
        q.bind(5, detail)
        q.run()
