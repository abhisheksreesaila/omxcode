# Runtime.changes (D-8051): a timer's tick that changes no part of the screen isn't a change (a frame a host drew ahead stays the
# one to show); one that does, and any other update, is.
#   pixi run mojo run -I . tests/test_tickchanges.mojo
from std.testing import assert_equal, assert_true
from mojoui import App, Event, View, Text, VStack
from mojoui.app import Runtime
from mojoui.effects import Every


struct Ticker(App):
    var shown: Int
    var ticks: Int

    def __init__(out self):
        self.shown = 0
        self.ticks = 0

    def title(self) -> String:
        return "ticks"

    def view(self) -> View:
        return VStack(Text("shown " + String(self.shown)))

    def update(mut self, event: Event):
        if event.message == 1:
            self.ticks += 1
            if self.ticks == 3:
                self.shown += 1
        elif event.message == 2:
            self.ticks += 100  # (changes nothing on the screen either)

    def every(self) -> List[Every]:
        return [Every(10, 1)]


def main() raises:
    var rt = Runtime[Ticker](Ticker())
    rt.take_effects()
    var t = 1_000_000
    _ = rt.poll(t)
    var seen = rt.changes
    for k in range(2):
        t += 10_000
        var d = rt.poll(t)
        assert_true(not d.rebuild and len(d.patches) == 0, "nothing on the screen")
        assert_equal(rt.changes, seen)
    assert_equal(rt.app.ticks, 2)
    t += 10_000
    var d = rt.poll(t)
    assert_true(len(d.patches) > 0 or d.rebuild, "the third shows")
    assert_equal(rt.changes, seen + 1)
    var before = rt.changes
    _ = rt.dispatch(2)
    assert_equal(rt.changes, before + 1)
    print("tickchanges: ok")
