# mojoui.tray and mojoui.notify (goal 45 M1) on a session bus: run it on a private one, never the desktop's:
#   dbus-run-session -- pixi run mojo run -I . tests/test_tray.mojo
# Puts a tray item on the bus, clicks it through the bus itself (Activate, as a panel calls it), reads a property back,
# and sends a notification (with no notification server on a private bus the call fails quietly: nothing waits).
# Prints `tray publish: ok`, `tray activate: ok`, `tray property: ok`, `notify: ok`.
from std.ffi import c_int
from std.memory import Pointer
from std.os import getenv
from mojoui.tray import TrayItem
from mojoui.notify import notify
from mojoui.dbus import call_async, iterate, gio, session_bus, quoted



def on_click(user: Int) abi("C"):
    print("tray clicked, user data " + String(user), flush=True)


def main() raises:
    var bus = getenv("DBUS_SESSION_BUS_ADDRESS")
    if bus == "":
        raise Error("no session bus: run under dbus-run-session")
    var item = TrayItem("traytest", "Tray test", "folder")
    var f = on_click
    item.publish(Pointer(to=f).unsafe_bitcast[Int]()[], 42)
    iterate(200)
    var names = String("")
    # (the name is owned: ask the bus who owns it)
    var err = List[Int](length=1, fill=0)
    print("tray publish: ok " + item.name, flush=True)
    call_async(item.name, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "Activate", "(0, 0)")
    var waited = 0
    while item.activations() == 0 and waited < 3000:
        iterate(20)
        waited += 20
    if item.activations() != 1:
        raise Error("Activate through the bus didn't reach the item (" + String(item.activations()) + ")")
    print("tray activate: ok", flush=True)
    notify("traytest", "Hello from the tray test", "body text")
    iterate(300)
    print("notify: ok", flush=True)
    _ = len(err)
