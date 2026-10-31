# mojoui.tray and mojoui.notify (goal 45 M1) on a session bus: run it on a private one, never the desktop's:
#   dbus-run-session -- pixi run mojo run -I . tests/test_tray.mojo
# Puts a tray item on the bus with no panel there (not registered: a host must not hide a window then), then plays the
# panel itself: owns org.kde.StatusNotifierWatcher (the item registers with it), lets it go (not registered any more),
# owns it again (the item registers again: a panel that restarts gets it back). Clicks it through the bus (Activate, as
# a panel calls it), reads its menu (com.canonical.dbusmenu GetLayout: Open, Quit) and clicks Quit and Open there, and
# sends a notification (with no notification server on a private bus the call fails quietly: nothing waits).
# Prints `tray <step>: ok` per step and `tray: all ok`; raises on the first failure.
from std.ffi import c_int, c_uint
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from mojoui.tray import TrayItem
from mojoui.notify import notify
from mojoui.dbus import call_async, iterate, gio, session_bus, printed, child_text, gerror_text

comptime WATCHER_XML = """<node><interface name='org.kde.StatusNotifierWatcher'>
<method name='RegisterStatusNotifierItem'><arg name='service' type='s' direction='in'/></method>
</interface></node>"""


def on_click(user: Int) abi("C"):
    print("tray clicked, user data " + String(user), flush=True)


def on_quit(user: Int) abi("C"):
    print("tray quit, user data " + String(user), flush=True)


def on_register(conn: Int, sender: Int, path: Int, iface: Int, method: Int, params: Int, invocation: Int, user: Int) abi("C"):
    """The pretend panel's watcher: counts registrations and keeps the last name."""
    var names = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=user)
    names[] += 1
    print("watcher: registered " + child_text(params, 0), flush=True)
    gio[NoneType]("g_dbus_method_invocation_return_value", invocation, Int(0))


def until(item: TrayItem, want: Bool, ms: Int) -> Bool:
    var waited = 0
    while item.registered() != want and waited < ms:
        iterate(20)
        waited += 20
    return item.registered() == want


def own(name: String) -> Int:
    var n = name
    var id = Int(gio[c_uint]("g_bus_own_name_on_connection", session_bus_or_0(), Int(n.as_c_string_span().unsafe_ptr()), c_int(0), Int(0), Int(0), Int(0), Int(0)))
    _ = n.byte_length()
    return id


def session_bus_or_0() -> Int:
    try:
        return session_bus()
    except:
        return 0


def main() raises:
    if getenv("DBUS_SESSION_BUS_ADDRESS") == "":
        raise Error("no session bus: run under dbus-run-session")
    var bus = session_bus()
    var item = TrayItem("traytest", "Tray test", "folder")
    var f = on_click
    var q = on_quit
    item.publish(Pointer(to=f).unsafe_bitcast[Int]()[], Pointer(to=q).unsafe_bitcast[Int]()[], 42)
    iterate(300)
    if item.watcher() or item.registered() or item.registrations() != 0:
        raise Error("no panel on the bus, yet watcher=" + String(item.watcher()) + " registered=" + String(item.registered()))
    print("tray publish: ok " + item.name + " (no panel: not registered)", flush=True)

    # the pretend panel: its watcher object, then its name
    var count = unsafe_alloc[Int](1)
    count[0] = 0
    var err = List[Int](length=1, fill=0)
    var xml = String(WATCHER_XML)
    var node = gio[Int]("g_dbus_node_info_new_for_xml", Int(xml.as_c_string_span().unsafe_ptr()), Int(err.unsafe_ptr()))
    var iname = String("org.kde.StatusNotifierWatcher")
    var info = gio[Int]("g_dbus_node_info_lookup_interface", node, Int(iname.as_c_string_span().unsafe_ptr()))
    var vt = unsafe_alloc[Int](11)
    var r = on_register
    vt[0] = Pointer(to=r).unsafe_bitcast[Int]()[]
    for k in range(1, 11):
        vt.unsafe_offset(k)[] = 0
    var path = String("/StatusNotifierWatcher")
    var oid = gio[c_uint]("g_dbus_connection_register_object", bus, Int(path.as_c_string_span().unsafe_ptr()), info, Int(vt), Int(count), Int(0), Int(err.unsafe_ptr()))
    if Int(oid) == 0:
        raise Error("pretend watcher: " + gerror_text(err[0]))
    _ = len(err)
    var owned = own("org.kde.StatusNotifierWatcher")
    if not until(item, True, 3000) or count[0] != 1 or item.registrations() != 1:
        raise Error("a watcher appeared but the item didn't register (registered=" + String(item.registered()) + ", calls " + String(count[0]) + ")")
    print("tray register: ok (a watcher appeared, the item registered with it)", flush=True)
    gio[NoneType]("g_bus_unown_name", c_uint(owned))
    if not until(item, False, 3000):
        raise Error("the watcher left but the item still says registered")
    owned = own("org.kde.StatusNotifierWatcher")
    if not until(item, True, 3000) or count[0] != 2 or item.registrations() != 2:
        raise Error("the watcher came back but the item didn't register again (calls " + String(count[0]) + ")")
    print("tray re-register: ok (the watcher left: not registered; it came back: registered again)", flush=True)

    call_async(item.name, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "Activate", "(0, 0)")
    var waited = 0
    while item.activations() == 0 and waited < 3000:
        iterate(20)
        waited += 20
    if item.activations() != 1:
        raise Error("Activate through the bus didn't reach the item (" + String(item.activations()) + ")")
    print("tray activate: ok", flush=True)

    var menu = unsafe_alloc[Int](1)
    menu[0] = 0
    call_async(item.name, "/StatusNotifierItem", "org.freedesktop.DBus.Properties", "Get", "('org.kde.StatusNotifierItem', 'Menu')", Int(menu))
    waited = 0
    while menu[0] == 0 and waited < 3000:
        iterate(20)
        waited += 20
    var menu_prop = printed(menu[0])
    menu[0] = 0
    call_async(item.name, "/MenuBar", "com.canonical.dbusmenu", "GetLayout", "(0, -1, @as [])", Int(menu))
    waited = 0
    while menu[0] == 0 and waited < 3000:
        iterate(20)
        waited += 20
    var layout = printed(menu[0])
    if menu_prop.find("/MenuBar") < 0 or layout.find("'Open Tray test'") < 0 or layout.find("'Quit'") < 0:
        raise Error("menu: Menu property " + menu_prop + ", layout " + layout)
    print("tray menu: ok " + layout, flush=True)
    call_async(item.name, "/MenuBar", "com.canonical.dbusmenu", "Event", "(3, 'clicked', <0>, uint32 0)")
    call_async(item.name, "/MenuBar", "com.canonical.dbusmenu", "Event", "(1, 'clicked', <0>, uint32 0)")
    waited = 0
    while (item.quits() == 0 or item.activations() < 2) and waited < 3000:
        iterate(20)
        waited += 20
    if item.quits() != 1 or item.activations() != 2:
        raise Error("menu clicks: quits " + String(item.quits()) + ", opens " + String(item.activations() - 1))
    print("tray menu quit and open: ok", flush=True)

    notify("traytest", "Hello from the tray test", "body text")
    iterate(300)
    print("notify: ok", flush=True)
    _ = xml.byte_length() + iname.byte_length() + path.byte_length()
    print("tray: all ok", flush=True)
