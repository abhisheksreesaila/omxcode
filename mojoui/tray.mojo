# mojoui.tray: an item in the system tray (goal 45 M1), for an app that keeps working with its window closed
# (App.background()). Clicking it (Activate) calls the host back, which opens the window again.
#
#   var item = TrayItem("keeper", "Keeper", "folder-saved-search")   # id, title (its tooltip too), a themed icon name
#   item.publish(on_activate_address, user_data)                      # on_activate: def(Int) abi("C"), called with user_data
#
# Hosts publish it themselves for an app whose background() is True; an app doesn't touch it.
# Linux: a StatusNotifierItem (the freedesktop/KDE tray protocol every Linux panel speaks: KDE, GNOME's AppIndicator
# extension, waybar, …) on the session bus through GDBus (mojoui.dbus): the name org.kde.StatusNotifierItem-<pid>-1, the
# object /StatusNotifierItem, Activate / SecondaryActivate / ContextMenu (each opens the window) and the properties a
# panel reads; then it asks org.kde.StatusNotifierWatcher (the panel) to show it, if one is there. No menu yet
# (com.canonical.dbusmenu): the window has the app's controls. Mac: an NSStatusItem, made by the AppKit host
# (mojoui/hosts/appkit.mojo, built, not run).

from std.ffi import c_int, c_uint
from std.memory import Pointer
from std.memory.alloc import alloc, Layout, unsafe_alloc
from std.sys import CompilationTarget
from mojoui.dbus import gio, session_bus, variant, quoted, c_text, gerror_text, call_async

comptime SNI_XML = """<node><interface name='org.kde.StatusNotifierItem'>
<method name='Activate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>
<method name='SecondaryActivate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>
<method name='ContextMenu'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>
<method name='Scroll'><arg name='delta' type='i' direction='in'/><arg name='orientation' type='s' direction='in'/></method>
<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>
<property name='Title' type='s' access='read'/><property name='Status' type='s' access='read'/>
<property name='IconName' type='s' access='read'/><property name='ToolTip' type='(sa(iiay)ss)' access='read'/>
<property name='ItemIsMenu' type='b' access='read'/>
<signal name='NewStatus'><arg type='s'/></signal><signal name='NewTitle'/><signal name='NewIcon'/>
</interface></node>"""


struct _Tray(Movable):
    var id: String
    var title: String
    var icon: String
    var on_activate: Int
    var user: Int
    var activations: Int

    def __init__(out self, id: String, title: String, icon: String, on_activate: Int, user: Int):
        self.id = id
        self.title = title
        self.icon = icon
        self.on_activate = on_activate
        self.user = user
        self.activations = 0


def _tray(addr: Int) -> Pointer[_Tray, MutUntrackedOrigin]:
    return Pointer[_Tray, MutUntrackedOrigin](unsafe_from_address=addr)


def _on_method(conn: Int, sender: Int, path: Int, iface: Int, method: Int, params: Int, invocation: Int, user: Int) abi("C"):
    """A panel called a method: Activate (a click), SecondaryActivate, ContextMenu open the window; Scroll does nothing."""
    var name = c_text(method)
    gio[NoneType]("g_dbus_method_invocation_return_value", invocation, Int(0))
    if name == "Scroll":
        return
    var t = _tray(user)
    t[].activations += 1
    if t[].on_activate != 0:
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=t[].on_activate)
        var f = Pointer(to=raw).unsafe_bitcast[def(Int) thin abi("C") -> None]()[]
        f(t[].user)


def _on_get(conn: Int, sender: Int, path: Int, iface: Int, prop: Int, error: Int, user: Int) abi("C") -> Int:
    var t = _tray(user)
    var name = c_text(prop)
    try:
        if name == "Category":
            return variant("'ApplicationStatus'")
        if name == "Id":
            return variant(quoted(t[].id))
        if name == "Title":
            return variant(quoted(t[].title))
        if name == "Status":
            return variant("'Active'")
        if name == "IconName":
            return variant(quoted(t[].icon))
        if name == "ToolTip":
            return variant("(" + quoted(t[].icon) + ", @a(iiay) [], " + quoted(t[].title) + ", '')")
        if name == "ItemIsMenu":
            return variant("false")
    except:
        pass
    return 0


struct TrayItem(Movable):
    var id: String
    var title: String
    var icon: String
    var state: Int  # the _Tray the callbacks read (lives as long as the process, as the bus object does)
    var name: String  # the bus name it owns ("" until published)
    var reason: String

    def __init__(out self, id: String, title: String, icon: String = "application-x-executable"):
        self.id = id
        self.title = title
        self.icon = icon
        self.state = 0
        self.name = ""
        self.reason = ""

    def publish(mut self, on_activate: Int, user: Int) raises:
        """Puts the item on the session bus (Linux). on_activate (a def(Int) abi("C") address, 0: none) is called with
        user on the main loop's thread when it's clicked."""
        comptime if not CompilationTarget.is_linux():
            raise Error("tray: this host makes its own (the Mac's NSStatusItem is the AppKit host's)")
        var bus = session_bus()
        var st = alloc(Layout[_Tray].single()).unsafe_leak()
        st.unsafe_write(_Tray(self.id, self.title, self.icon, on_activate, user))
        self.state = Int(st)
        var err = List[Int](length=1, fill=0)
        var xml = String(SNI_XML)
        var node = gio[Int]("g_dbus_node_info_new_for_xml", Int(xml.as_c_string_span().unsafe_ptr()), Int(err.unsafe_ptr()))
        if node == 0:
            raise Error("tray: " + gerror_text(err[0]))
        var iname = String("org.kde.StatusNotifierItem")
        var info = gio[Int]("g_dbus_node_info_lookup_interface", node, Int(iname.as_c_string_span().unsafe_ptr()))
        var vt = unsafe_alloc[Int](11)  # GDBusInterfaceVTable: method_call, get_property, set_property, 8 spare (lives as long as the object)
        var m = _on_method
        var g = _on_get
        vt[0] = Pointer(to=m).unsafe_bitcast[Int]()[]
        vt.unsafe_offset(1)[] = Pointer(to=g).unsafe_bitcast[Int]()[]
        for k in range(2, 11):
            vt.unsafe_offset(k)[] = 0
        var path = String("/StatusNotifierItem")
        var id = gio[c_uint]("g_dbus_connection_register_object", bus, Int(path.as_c_string_span().unsafe_ptr()), info, Int(vt),
                             self.state, Int(0), Int(err.unsafe_ptr()))
        if Int(id) == 0:
            var why = gerror_text(err[0])
            _ = len(err)
            raise Error("tray: can't put the item on the bus (" + why + ")")
        _ = len(err)
        var pid = Int(gio[c_int]("getpid"))
        self.name = "org.kde.StatusNotifierItem-" + String(pid) + "-1"
        var n = self.name
        _ = gio[c_uint]("g_bus_own_name_on_connection", bus, Int(n.as_c_string_span().unsafe_ptr()), c_int(0), Int(0), Int(0), Int(0), Int(0))
        call_async("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                   "RegisterStatusNotifierItem", "(" + quoted(self.name) + ",)")

    def activations(self) -> Int:
        """How many times it was clicked (Activate and friends) since publish."""
        return _tray(self.state)[].activations if self.state != 0 else 0
