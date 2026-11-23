# keycaps: the shortcut labels each platform writes (D-7985).
from mojoui.keycaps import mod_label, keycap, device_name, on_apple
from std.sys.info import CompilationTarget


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("FAIL " + what)


def main() raises:
    check(keycap(".", mac=False) == "Ctrl .", "linux ctrl")
    check(keycap("N", alt=True, mac=False) == "Alt N", "linux alt")
    check(keycap(".", mac=True) == "⌘.", "mac cmd")
    check(keycap("N", alt=True, mac=True) == "⌥N", "mac option")
    check(mod_label(mac=True) == "⌘" and mod_label(mac=False) == "Ctrl", "mod label")
    check(device_name(mac=True) == "Mac" and device_name(mac=False) == "device", "device")
    check(on_apple() == CompilationTarget.is_macos(), "platform")
    print("PASS test_keycaps")
