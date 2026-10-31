# mojoui.dbus: the session bus through GIO's GDBus (goal 45), for the tray item (mojoui.tray) and notifications
# (mojoui.notify). Linux only; on other hosts every call is a no-op that says so.
#
# GIO is loaded with dlopen (RTLD_GLOBAL) on first use and its functions are called by address, as mojoui.sqlite calls
# SQLite: a GTK app already has it linked, and `mojo run` (which links nothing) works too. Values travel as GVariant
# text ("('a', uint32 0)", parsed by g_variant_parse), so no variadic C call is needed. Calls are asynchronous: they
# return at once and the reply (or error) is handled on the main loop, which a GTK app runs and a test pumps
# (iterate()). Which bus: $DBUS_SESSION_BUS_ADDRESS, as every D-Bus client; the checks start a private one.

from std.ffi import external_call, c_int, c_char
from std.memory import Pointer
from std.sys import CompilationTarget
from mojoui.shared import get_shared, put_shared

comptime SLOT_GIO = 95  # mojoui.shared slots: GIO's handle (94 is mojoui.sqlite's)
comptime SLOT_BUS = 96  # the session bus connection


def _sym(name: String) -> Int:
    var n = name
    var anywhere = -2 if CompilationTarget.is_macos() else 0  # RTLD_DEFAULT
    return external_call["dlsym", Int](anywhere, n.as_c_string_span())


def gio[T: RegisterPassable = Int, *A: AnyType](name: String, *args: *A) -> T:
    """A GIO/GLib function by name (GIO loaded first)."""
    _ = gio_loaded()
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=_sym(name))
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def gio_loaded() -> Bool:
    comptime if not CompilationTarget.is_linux():
        return False
    if get_shared(SLOT_GIO) != 0:
        return True
    if _sym("g_dbus_connection_call") != 0:  # (linked already: a GTK app)
        put_shared(SLOT_GIO, 1)
        return True
    var dlopen = _sym("dlopen")
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=dlopen)
    var f = Pointer(to=raw).unsafe_bitcast[def(Int, c_int) thin abi("C") -> Int]()[]
    var name = String("libgio-2.0.so.0")
    var h = f(Int(name.as_c_string_span().unsafe_ptr()), c_int(2 | 0x100))  # RTLD_NOW | RTLD_GLOBAL
    if h == 0:
        return False
    put_shared(SLOT_GIO, h)
    return True


def c_text(addr: Int) -> String:
    if addr == 0:
        return String("")
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


def gerror_text(err: Int) -> String:
    """A GError's message (GError { domain; code; char *message })."""
    if err == 0:
        return ""
    return c_text(Pointer[Int, MutUntrackedOrigin](unsafe_from_address=err + 8)[])


def quoted(s: String) -> String:
    """s as a GVariant text string literal."""
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"


def variant(text: String) raises -> Int:
    """A floating GVariant from its text form ("('a', uint32 0)")."""
    var err = List[Int](length=1, fill=0)
    var t = text
    var v = gio[Int]("g_variant_parse", Int(0), Int(t.as_c_string_span().unsafe_ptr()), Int(0), Int(0), Int(err.unsafe_ptr()))
    if v == 0:
        var why = gerror_text(err[0])
        _ = len(err)
        raise Error("GVariant: " + why + " in " + text)
    _ = len(err)
    return v


def session_bus() raises -> Int:
    """The session bus connection (made once per process)."""
    comptime if not CompilationTarget.is_linux():
        raise Error("D-Bus: Linux only")
    var have = get_shared(SLOT_BUS)
    if have != 0:
        return have
    if not gio_loaded():
        raise Error("D-Bus: GIO isn't installed (libgio-2.0)")
    var err = List[Int](length=1, fill=0)
    var c = gio[Int]("g_bus_get_sync", c_int(2), Int(0), Int(err.unsafe_ptr()))  # G_BUS_TYPE_SESSION
    if c == 0:
        var why = gerror_text(err[0])
        _ = len(err)
        raise Error("D-Bus: no session bus (" + why + ")")
    _ = len(err)
    put_shared(SLOT_BUS, c)
    return c


def _on_reply(source: Int, res: Int, slot: Int) abi("C"):
    """A call's reply into its slot: the reply GVariant (> 0), or -1 when the call failed (no such name, an error)."""
    var err = List[Int](length=1, fill=0)
    var v = gio[Int]("g_dbus_connection_call_finish", source, res, Int(err.unsafe_ptr()))
    _ = len(err)
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=slot)[] = v if v != 0 else -1


def call_async(dest: String, path: String, iface: String, method: String, args: String, reply_slot: Int = 0) raises:
    """Calls a method without waiting. reply_slot (the address of an Int, 0: none): set on the main loop when the
    reply comes, to the reply's GVariant (> 0; g_variant_print shows it) or -1 if the call failed; 0 until then.
    Without one the reply is dropped."""
    var bus = session_bus()
    var params = variant(args) if args != "" else 0
    var d = dest
    var p = path
    var i = iface
    var m = method
    var cb = 0
    if reply_slot != 0:
        var f = _on_reply
        cb = Pointer(to=f).unsafe_bitcast[Int]()[]
    gio[NoneType]("g_dbus_connection_call", bus, Int(d.as_c_string_span().unsafe_ptr()), Int(p.as_c_string_span().unsafe_ptr()),
        Int(i.as_c_string_span().unsafe_ptr()), Int(m.as_c_string_span().unsafe_ptr()), params, Int(0), c_int(0), c_int(-1), Int(0), cb, reply_slot)
    _ = d.byte_length() + p.byte_length() + i.byte_length() + m.byte_length()


def printed(v: Int) -> String:
    """A GVariant's text form ("" for none)."""
    if v <= 0:
        return ""
    var t = gio[Int]("g_variant_print", v, c_int(1))
    var s = c_text(t)
    gio[NoneType]("g_free", t)
    return s


def child_text(params: Int, k: Int) -> String:
    """A string argument of a method call (params' k-th child)."""
    var v = gio[Int]("g_variant_get_child_value", params, Int(k))
    var s = c_text(gio[Int]("g_variant_get_string", v, Int(0)))
    gio[NoneType]("g_variant_unref", v)
    return s


def child_int(params: Int, k: Int) -> Int:
    """An int32 argument of a method call (params' k-th child)."""
    var v = gio[Int]("g_variant_get_child_value", params, Int(k))
    var n = Int(gio[Int32]("g_variant_get_int32", v))
    gio[NoneType]("g_variant_unref", v)
    return n


def iterate(ms: Int):
    """Runs the default main context for about ms milliseconds (tests and tools; a GTK app's loop does this itself)."""
    var t = Int(gio[Int]("g_get_monotonic_time"))
    var end = t + ms * 1000
    while Int(gio[Int]("g_get_monotonic_time")) < end:
        _ = gio[c_int]("g_main_context_iteration", Int(0), c_int(0))
        gio[NoneType]("g_usleep", Int(1000))
