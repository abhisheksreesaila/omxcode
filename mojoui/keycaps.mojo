# Shortcut labels as each platform writes them (goal 79 M7, D-7985): the Mac writes the command key as ⌘ and Option as ⌥
# with no space before the key ("⌘.", "⌥N"); Linux, Windows and the web elsewhere write "Ctrl ." and "Alt N". The same
# rule the web's own apps follow (navigator.platform matching mac/iphone/ipad), so a native window and the web app in
# that machine's browser show the same labels. `mac` is a parameter so tests can check both sides on either machine.
from std.sys.info import CompilationTarget


def on_apple() -> Bool:
    """True on the Mac (and iPhone): the platform whose labels use ⌘ and ⌥."""
    return CompilationTarget.is_macos()


def mod_label(mac: Bool = on_apple()) -> String:
    """The primary modifier's name: ⌘ on the Mac, Ctrl elsewhere."""
    return String("⌘") if mac else String("Ctrl")


def keycap(key: String, alt: Bool = False, mac: Bool = on_apple()) -> String:
    """A shortcut label: the modifier (Ctrl/⌘, or Alt/⌥ when alt) then the key; the Mac writes them together."""
    if mac:
        return (String("⌥") if alt else String("⌘")) + key
    return (String("Alt ") if alt else String("Ctrl ")) + key


def device_name(mac: Bool = on_apple()) -> String:
    """What a 'this …' line calls the machine: Mac on the Mac, device elsewhere."""
    return String("Mac") if mac else String("device")
