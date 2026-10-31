# mojoui.notify: a desktop notification (goal 45 M1), from the window or from an app working with its window closed.
#
#   notify("Keeper", "plan.md mentions zebra", "in ~/Notes/plan.md")     # app name, title, body; returns at once
#
# Linux: org.freedesktop.Notifications.Notify on the session bus (mojoui.dbus, asynchronous: the notification server
# shows it; if there's none, the call fails quietly and nothing waits). Mac: UNUserNotificationCenter (a request with
# the title and body, added with no completion handler), built, not run: it also needs the person's permission, which
# a signed app asks for (requestAuthorizationWithOptions: takes a block; not made yet, docs/components.md).

from std.sys import CompilationTarget
from std.ffi import c_int
from std.memory import Pointer
from mojoui.dbus import call_async, quoted, _sym
from mojoui.hosts.objc import msg, cls, ns_string


def notify(app: String, title: String, body: String = "", icon: String = "") raises:
    comptime if CompilationTarget.is_linux():
        call_async("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify",
                   "(" + quoted(app) + ", uint32 0, " + quoted(icon) + ", " + quoted(title) + ", " + quoted(body) + ", @as [], @a{sv} {}, -1)")
    else:
        var fw = String("/System/Library/Frameworks/UserNotifications.framework/UserNotifications")
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=_sym("dlopen"))
        var dlopen = Pointer(to=raw).unsafe_bitcast[def(Int, c_int) thin abi("C") -> Int]()[]
        var lib = dlopen(Int(fw.as_c_string_span().unsafe_ptr()), c_int(2))
        if lib == 0:
            raise Error("notify: no UserNotifications framework")
        var content = msg(msg(cls("UNMutableNotificationContent"), "alloc"), "init")
        _ = msg(content, "setTitle:", ns_string(title))
        _ = msg(content, "setBody:", ns_string(body))
        var req = msg(cls("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", ns_string(app + ":" + title), content, 0)
        var center = msg(cls("UNUserNotificationCenter"), "currentNotificationCenter")
        _ = msg(center, "addNotificationRequest:withCompletionHandler:", req, 0)
