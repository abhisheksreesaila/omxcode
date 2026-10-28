# The agent link's socket (goal 34b, docs/agent.md): a native host that runs widgets (GTK) lets an agent host attach to
# it through a Unix socket named by MOJOUI_AGENT_SOCKET: one JSON request per line in, one JSON answer per line out
# (view, event, gesture, key, set, describe, rows), the same protocol web.py's link speaks. The socket is opt-in (no
# variable, no socket) and the user's alone (mode 0600); it carries JSON only, and every request goes through the same
# checks a person's input does (the runtime's set_widget, the page's declared fields). Plain libc calls; the host
# watches the descriptors on its main loop (g_unix_fd_add), so requests run between GTK's own events, never inside one.

from std.ffi import external_call, c_int, c_char, c_uint
from std.memory import Pointer
from mojoui.json import json_string

comptime AF_UNIX = 1
comptime SOCK_STREAM = 1
comptime SOCK_CLOEXEC = 0x80000
comptime MSG_DONTWAIT = 0x40
comptime MSG_NOSIGNAL = 0x4000
comptime SUN_PATH = 108  # sockaddr_un's path bytes (with its NUL)
comptime MAX_LINE = 4 << 20  # a request past this (no newline yet) closes the connection


def listen_unix(path: String) -> Int:
    """A listening Unix socket at `path` (an old file there is replaced), readable and writable by this user only; -1
    if the path is too long or the socket can't be made."""
    var n = path.byte_length()
    if n == 0 or n >= SUN_PATH:
        return -1
    var fd = Int(external_call["socket", c_int](c_int(AF_UNIX), c_int(SOCK_STREAM | SOCK_CLOEXEC), c_int(0)))
    if fd < 0:
        return -1
    var addr = List[UInt8](length=2 + SUN_PATH, fill=0)  # sockaddr_un: sa_family_t (2 bytes, little-endian), then the path
    addr[0] = UInt8(AF_UNIX)
    var b = path.as_bytes()
    for k in range(n):
        addr[2 + k] = b[k]
    var p = path
    _ = external_call["unlink", c_int](p.as_c_string_span())
    var old = external_call["umask", c_uint](c_uint(0o177))  # (created 0600: the socket is the user's alone)
    var bound = external_call["bind", c_int](c_int(fd), Int(addr.unsafe_ptr()), c_uint(2 + n + 1))
    _ = external_call["umask", c_uint](old)
    _ = len(addr)
    if Int(bound) != 0 or Int(external_call["listen", c_int](c_int(fd), c_int(4))) != 0:
        _ = external_call["close", c_int](c_int(fd))
        return -1
    return fd


def accept_one(fd: Int) -> Int:
    return Int(external_call["accept4", c_int](c_int(fd), Int(0), Int(0), c_int(SOCK_CLOEXEC)))


def read_some(fd: Int) -> Tuple[Int, String]:
    """What has arrived on `fd` without waiting: (bytes read, as text); 0 bytes: the other side closed; -1: nothing yet
    or an error."""
    var buf = List[UInt8](length=65537, fill=0)
    var n = Int(external_call["recv", Int](c_int(fd), Int(buf.unsafe_ptr()), Int(65536), c_int(MSG_DONTWAIT)))
    if n <= 0:
        _ = len(buf)
        return (n, String(""))
    for k in range(n):
        if buf[k] == 0:  # (a NUL is never JSON text: the line is refused as not JSON)
            buf[k] = 1
    buf[n] = 0
    var text = String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=Int(buf.unsafe_ptr())))
    _ = len(buf)
    return (n, text^)


def send_all(fd: Int, text: String) -> Bool:
    var t = text
    var total = t.byte_length()
    var at = 0
    var base = Int(t.unsafe_ptr())
    while at < total:
        var n = Int(external_call["send", Int](c_int(fd), base + at, Int(total - at), c_int(MSG_NOSIGNAL)))
        if n <= 0:
            _ = t.byte_length()
            return False
        at += n
    _ = t.byte_length()
    return True


def close_fd(fd: Int):
    _ = external_call["close", c_int](c_int(fd))


def link_error(why: String) -> String:
    return '{"ok":false,"error":' + json_string(why) + "}"
