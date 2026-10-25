# mojoui.confirm: an action that asks to be tapped twice (the console's Revoke and Rotate: "Click again to revoke"). The
# first tap arms the button (it says so and wears tag="confirm-armed"; unarmed it's tag="confirm"), the second acts; it
# disarms by itself after a while (4 s, the console's), through a timer the app lists (App.every).
#
#   var keys: TwoStep                                      # in the app's state
#   ConfirmButton("Revoke", "Click again to revoke", self.keys.is_armed(k), REVOKE + k, icon="trash")
#   update(): if REVOKE <= m < REVOKE + n and self.keys.tap(m - REVOKE): revoke(m - REVOKE)  ·  DISARM: self.keys.disarm()
#   every(): return self.keys.every(DISARM)

from mojoui.view import View, Button, DESTRUCTIVE
from mojoui.effects import Every


@fieldwise_init
struct TwoStep(Copyable, Movable):
    """Which action is armed (-1: none): one at a time, as the console's."""

    var armed: Int

    def __init__(out self):
        self.armed = -1

    def tap(mut self, key: Int) -> Bool:
        """A tap on action `key`: True when it's the second (act now; disarmed), False when it only armed it."""
        if self.armed == key:
            self.armed = -1
            return True
        self.armed = key
        return False

    def disarm(mut self):
        self.armed = -1

    def is_armed(self, key: Int) -> Bool:
        return self.armed == key

    def every(self, msg: Int, ms: Int = 4000) -> List[Every]:
        """The disarming timer while something is armed (sends `msg`: call disarm())."""
        var out = List[Every]()
        if self.armed >= 0:
            out.append(Every(ms, msg))
        return out^


def ConfirmButton(title: String, armed_title: String, armed: Bool, on_tap: Int, icon: String = "", style: Int = DESTRUCTIVE) -> View:
    """The button: `title`, or `armed_title` once armed (it then asks for the second tap)."""
    return Button(armed_title if armed else title, on_tap, style=style, icon=icon).tag("confirm-armed" if armed else "confirm")
