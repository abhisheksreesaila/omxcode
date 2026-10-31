# mojoui.tray: an item in the system tray (goal 45 M1), for an app that keeps working with its window closed
# (App.background()). Clicking it (Activate) calls the host back, which opens the window again; its menu has Open and
# Quit, so an app running with its window closed can always be ended without killing it.
#
#   var item = TrayItem("keeper", "Keeper", "folder-saved-search")   # id, title (its tooltip too), a themed icon name
#   item.publish(on_activate_address, on_quit_address, user_data)     # each a def(Int) abi("C"), called with user_data
#   item.registered()                                                 # a panel shows it (its watcher took it)
#
# Hosts publish it themselves for an app whose background() is True; an app doesn't touch it. A host hides the window
# on close only while registered() (a panel is there to bring it back); otherwise closing ends the app as usual.
# Linux: a StatusNotifierItem (the freedesktop/KDE tray protocol every Linux panel speaks: KDE, GNOME's AppIndicator
# extension, waybar, …) on the session bus through GDBus (mojoui.dbus): the name org.kde.StatusNotifierItem-<pid>-1, the
# object /StatusNotifierItem, Activate / SecondaryActivate (each opens the window), ContextMenu (opens it too, for panels
# that don't read the menu) and the properties a panel reads, with Menu pointing at /MenuBar: a minimal
# com.canonical.dbusmenu (Open <title>, Quit; Event "clicked" runs them). It watches the bus for
# org.kde.StatusNotifierWatcher (the panel) and registers with it whenever one appears (at start, or a panel started or
# restarted later). Mac: an NSStatusItem, made by the AppKit host (mojoui/hosts/appkit.mojo; not made yet).

from std.ffi import c_int, c_uint
from std.memory import Pointer
from std.memory.alloc import alloc, Layout, unsafe_alloc
from std.sys import CompilationTarget
from mojoui.dbus import gio, session_bus, variant, quoted, c_text, gerror_text, call_async, child_text, child_int

comptime SNI_XML = """<node><interface name='org.kde.StatusNotifierItem'>
<method name='Activate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>
<method name='SecondaryActivate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>
<method name='ContextMenu'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>
<method name='Scroll'><arg name='delta' type='i' direction='in'/><arg name='orientation' type='s' direction='in'/></method>
<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>
<property name='Title' type='s' access='read'/><property name='Status' type='s' access='read'/>
<property name='IconName' type='s' access='read'/><property name='ToolTip' type='(sa(iiay)ss)' access='read'/>
<property name='ItemIsMenu' type='b' access='read'/><property name='Menu' type='o' access='read'/>
<signal name='NewStatus'><arg type='s'/></signal><signal name='NewTitle'/><signal name='NewIcon'/>
</interface></node>"""

comptime MENU_XML = """<node><interface name='com.canonical.dbusmenu'>
<method name='GetLayout'><arg type='i' name='parentId' direction='in'/><arg type='i' name='recursionDepth' direction='in'/>
<arg type='as' name='propertyNames' direction='in'/><arg type='u' name='revision' direction='out'/><arg type='(ia{sv}av)' name='layout' direction='out'/></method>
<method name='GetGroupProperties'><arg type='ai' name='ids' direction='in'/><arg type='as' name='propertyNames' direction='in'/>
<arg type='a(ia{sv})' name='properties' direction='out'/></method>
<method name='GetProperty'><arg type='i' name='id' direction='in'/><arg type='s' name='name' direction='in'/><arg type='v' name='value' direction='out'/></method>
<method name='Event'><arg type='i' name='id' direction='in'/><arg type='s' name='eventId' direction='in'/><arg type='v' name='data' direction='in'/>
<arg type='u' name='timestamp' direction='in'/></method>
<method name='EventGroup'><arg type='a(isvu)' name='events' direction='in'/><arg type='ai' name='idErrors' direction='out'/></method>
<method name='AboutToShow'><arg type='i' name='id' direction='in'/><arg type='b' name='needUpdate' direction='out'/></method>
<method name='AboutToShowGroup'><arg type='ai' name='ids' direction='in'/><arg type='ai' name='updatesNeeded' direction='out'/>
<arg type='ai' name='idErrors' direction='out'/></method>
<property name='Version' type='u' access='read'/><property name='TextDirection' type='s' access='read'/>
<property name='Status' type='s' access='read'/><property name='IconThemePath' type='as' access='read'/>
<signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})'/><arg type='a(ias)'/></signal>
<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>
<signal name='ItemActivationRequested'><arg type='i'/><arg type='u'/></signal>
</interface></node>"""
comptime MENU_OPEN = 1  # the menu's item ids
comptime MENU_QUIT = 3


struct _Tray(Movable):
    var id: String
    var title: String
    var icon: String
    var on_activate: Int
    var on_quit: Int
    var user: Int
    var activations: Int
    var quits: Int
    var name: String  # the bus name it owns
    var reply: Int  # RegisterStatusNotifierItem's reply (mojoui.dbus.call_async's slot: 0 waiting or none, > 0 taken, -1 refused)
    var watcher: Bool  # org.kde.StatusNotifierWatcher is on the bus
    var registrations: Int  # how many times it registered (once per watcher that appeared)

    def __init__(out self, id: String, title: String, icon: String, on_activate: Int, on_quit: Int, user: Int):
        self.id = id
        self.title = title
        self.icon = icon
        self.on_activate = on_activate
        self.on_quit = on_quit
        self.user = user
        self.activations = 0
        self.quits = 0
        self.name = ""
        self.reply = 0
        self.watcher = False
        self.registrations = 0


def _tray(addr: Int) -> Pointer[_Tray, MutUntrackedOrigin]:
    return Pointer[_Tray, MutUntrackedOrigin](unsafe_from_address=addr)


def _call_back(addr: Int, user: Int):
    if addr != 0:
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
        var f = Pointer(to=raw).unsafe_bitcast[def(Int) thin abi("C") -> None]()[]
        f(user)


def _open(t: Pointer[_Tray, MutUntrackedOrigin]):
    t[].activations += 1
    _call_back(t[].on_activate, t[].user)


def _quit(t: Pointer[_Tray, MutUntrackedOrigin]):
    t[].quits += 1
    _call_back(t[].on_quit, t[].user)


def _on_method(conn: Int, sender: Int, path: Int, iface: Int, method: Int, params: Int, invocation: Int, user: Int) abi("C"):
    """A panel called a method: Activate (a click), SecondaryActivate, ContextMenu open the window; Scroll does nothing."""
    var name = c_text(method)
    gio[NoneType]("g_dbus_method_invocation_return_value", invocation, Int(0))
    if name == "Scroll":
        return
    _open(_tray(user))


def _menu_item(id: Int, label: String) -> String:
    return "(" + String(id) + ", {'label': <" + quoted(label) + ">}, @av [])"


def _on_menu(conn: Int, sender: Int, path: Int, iface: Int, method: Int, params: Int, invocation: Int, user: Int) abi("C"):
    """com.canonical.dbusmenu, the least a panel needs: one level, Open <title> and Quit; Event "clicked" runs them."""
    var t = _tray(user)
    var name = c_text(method)
    var reply = String("")
    var run = 0
    if name == "GetLayout":
        reply = ("(uint32 1, (0, {'children-display': <'submenu'>}, [<" + _menu_item(MENU_OPEN, "Open " + t[].title)
                 + ">, <(2, {'type': <'separator'>}, @av [])>, <" + _menu_item(MENU_QUIT, "Quit") + ">]))")
    elif name == "GetGroupProperties":
        reply = ("([(0, {'children-display': <'submenu'>}), (" + String(MENU_OPEN) + ", {'label': <" + quoted("Open " + t[].title)
                 + ">}), (2, {'type': <'separator'>}), (" + String(MENU_QUIT) + ", {'label': <'Quit'>})],)")
    elif name == "GetProperty":
        reply = "(<''>,)"
    elif name == "Event":
        if child_text(params, 1) == "clicked":
            run = child_int(params, 0)
    elif name == "EventGroup":
        var events = gio[Int]("g_variant_get_child_value", params, Int(0))
        for k in range(Int(gio[Int]("g_variant_n_children", events))):
            var e = gio[Int]("g_variant_get_child_value", events, Int(k))
            if child_text(e, 1) == "clicked":
                run = child_int(e, 0)
            gio[NoneType]("g_variant_unref", e)
        gio[NoneType]("g_variant_unref", events)
        reply = "(@ai [],)"
    elif name == "AboutToShow":
        reply = "(false,)"
    elif name == "AboutToShowGroup":
        reply = "(@ai [], @ai [])"
    try:
        gio[NoneType]("g_dbus_method_invocation_return_value", invocation, variant(reply) if reply != "" else 0)
    except:
        gio[NoneType]("g_dbus_method_invocation_return_value", invocation, Int(0))
    if run == MENU_OPEN:
        _open(t)
    elif run == MENU_QUIT:
        _quit(t)


def _on_menu_get(conn: Int, sender: Int, path: Int, iface: Int, prop: Int, error: Int, user: Int) abi("C") -> Int:
    var name = c_text(prop)
    try:
        if name == "Version":
            return variant("uint32 3")
        if name == "TextDirection":
            return variant("'ltr'")
        if name == "Status":
            return variant("'normal'")
        if name == "IconThemePath":
            return variant("@as []")
    except:
        pass
    return 0


def _register(t: Pointer[_Tray, MutUntrackedOrigin]):
    """Asks the watcher (the panel) to show the item; its reply lands in t[].reply."""
    t[].reply = 0
    try:
        call_async("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                   "RegisterStatusNotifierItem", "(" + quoted(t[].name) + ",)", Int(Pointer(to=t[].reply)))
        t[].registrations += 1
    except:
        t[].reply = -1


def _watcher_appeared(conn: Int, name: Int, owner: Int, user: Int) abi("C"):
    var t = _tray(user)
    t[].watcher = True
    _register(t)


def _watcher_vanished(conn: Int, name: Int, user: Int) abi("C"):
    var t = _tray(user)
    t[].watcher = False
    t[].reply = 0  # (a panel that comes back registers it again: _watcher_appeared)


def _vtable(method: Int, get: Int) -> Int:
    var vt = unsafe_alloc[Int](11)  # GDBusInterfaceVTable: method_call, get_property, set_property, 8 spare (lives as long as the object)
    vt[0] = method
    vt.unsafe_offset(1)[] = get
    for k in range(2, 11):
        vt.unsafe_offset(k)[] = 0
    return Int(vt)


def _register_object(bus: Int, xml: String, iface: String, path: String, vt: Int, user: Int) raises:
    var err = List[Int](length=1, fill=0)
    var x = xml
    var node = gio[Int]("g_dbus_node_info_new_for_xml", Int(x.as_c_string_span().unsafe_ptr()), Int(err.unsafe_ptr()))
    if node == 0:
        raise Error("tray: " + gerror_text(err[0]))
    var i = iface
    var info = gio[Int]("g_dbus_node_info_lookup_interface", node, Int(i.as_c_string_span().unsafe_ptr()))
    var p = path
    var id = gio[c_uint]("g_dbus_connection_register_object", bus, Int(p.as_c_string_span().unsafe_ptr()), info, vt, user, Int(0), Int(err.unsafe_ptr()))
    if Int(id) == 0:
        var why = gerror_text(err[0])
        _ = len(err)
        raise Error("tray: can't put " + path + " on the bus (" + why + ")")
    _ = len(err)
    _ = x.byte_length() + i.byte_length() + p.byte_length()


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
        if name == "Menu":
            return variant("objectpath '/MenuBar'")
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

    def publish(mut self, on_activate: Int, on_quit: Int, user: Int) raises:
        """Puts the item and its menu on the session bus (Linux) and registers it with the panel's watcher whenever one
        is there. on_activate and on_quit (def(Int) abi("C") addresses, 0: none) are called with user on the main
        loop's thread: a click or the menu's Open, the menu's Quit."""
        comptime if not CompilationTarget.is_linux():
            raise Error("tray: this host makes its own (the Mac's NSStatusItem is the AppKit host's)")
        var bus = session_bus()
        var pid = Int(gio[c_int]("getpid"))
        self.name = "org.kde.StatusNotifierItem-" + String(pid) + "-1"
        var st = alloc(Layout[_Tray].single()).unsafe_leak()
        st.unsafe_write(_Tray(self.id, self.title, self.icon, on_activate, on_quit, user))
        st[].name = self.name
        self.state = Int(st)
        var m = _on_method
        var g = _on_get
        _register_object(bus, SNI_XML, "org.kde.StatusNotifierItem", "/StatusNotifierItem",
                         _vtable(Pointer(to=m).unsafe_bitcast[Int]()[], Pointer(to=g).unsafe_bitcast[Int]()[]), self.state)
        var mm = _on_menu
        var mg = _on_menu_get
        _register_object(bus, MENU_XML, "com.canonical.dbusmenu", "/MenuBar",
                         _vtable(Pointer(to=mm).unsafe_bitcast[Int]()[], Pointer(to=mg).unsafe_bitcast[Int]()[]), self.state)
        var n = self.name
        _ = gio[c_uint]("g_bus_own_name_on_connection", bus, Int(n.as_c_string_span().unsafe_ptr()), c_int(0), Int(0), Int(0), Int(0), Int(0))
        _ = n.byte_length()
        var w = String("org.kde.StatusNotifierWatcher")
        var on_up = _watcher_appeared
        var on_down = _watcher_vanished
        _ = gio[c_uint]("g_bus_watch_name_on_connection", bus, Int(w.as_c_string_span().unsafe_ptr()), c_int(0),
                        Pointer(to=on_up).unsafe_bitcast[Int]()[], Pointer(to=on_down).unsafe_bitcast[Int]()[], self.state, Int(0))
        _ = w.byte_length()

    def activations(self) -> Int:
        """How many times it was clicked (Activate and friends, the menu's Open) since publish."""
        return _tray(self.state)[].activations if self.state != 0 else 0

    def quits(self) -> Int:
        """How many times the menu's Quit ran."""
        return _tray(self.state)[].quits if self.state != 0 else 0

    def watcher(self) -> Bool:
        """A StatusNotifierWatcher (a panel's) is on the bus."""
        return _tray(self.state)[].watcher if self.state != 0 else False

    def registered(self) -> Bool:
        """The watcher took the item (its RegisterStatusNotifierItem replied without an error): a panel shows it, so a
        hidden window can be brought back. False with no panel, before the reply, or after the panel left."""
        return self.state != 0 and _tray(self.state)[].watcher and _tray(self.state)[].reply > 0

    def registrations(self) -> Int:
        """How many times it asked a watcher to take it (once per watcher that appeared)."""
        return _tray(self.state)[].registrations if self.state != 0 else 0
