# Runtime.queue_pan and take_pans (D-8063): a drag's points since the last frame all reach the app, in order, and the screen is worked out once.
#   pixi run mojo run -I . tests/test_pans.mojo
from std.testing import assert_equal, assert_true
from mojoui import App, Event, View, Canvas, VStack, Text, PAN
from mojoui.app import Runtime, PanPoint


struct Pen(App):
    var xs: List[Float64]
    var ps: List[Float64]
    var travelled: Float64
    var order: List[String]

    def __init__(out self):
        self.xs = List[Float64]()
        self.ps = List[Float64]()
        self.travelled = 0
        self.order = List[String]()

    def title(self) -> String:
        return "pen"

    def view(self) -> View:
        return VStack(Text("points " + String(len(self.xs))), Canvas(0, len(self.xs), on_gesture=1))

    def update(mut self, event: Event):
        if event.message == 1 and event.number == PAN:
            self.xs.append(event.x)
            self.ps.append(event.pressure)
            self.travelled += event.dx
            self.order.append("pan")
        else:
            self.order.append("other")


def main() raises:
    var rt = Runtime[Pen](Pen())
    var node = -1
    for i in range(len(rt.shown.nodes)):
        if rt.shown.nodes[i].name == "" and rt.shown.nodes[i].msg == 1:
            node = i
    assert_true(node >= 0)
    for i in range(40):
        rt.queue_pan(node, PanPoint(Float64(i), 0, 1, 0, Float64(i) / 40))
    assert_equal(len(rt.app.xs), 0, "kept")
    var d = rt.take_pans()
    assert_equal(len(rt.app.xs), 40, "every point")
    for i in range(40):
        assert_equal(rt.app.xs[i], Float64(i))
        assert_equal(rt.app.ps[i], Float64(i) / 40)
    assert_equal(rt.app.travelled, 40.0)
    assert_true(len(d.patches) > 0 and rt.shown.nodes[node].value == 40, "the screen once, of the last")
    var none = rt.take_pans()
    assert_true(not none.rebuild and len(none.patches) == 0)
    # whatever else happens finds them delivered: a key, a menu's message, a timer
    for k in range(3):
        rt.queue_pan(node, PanPoint(100 + Float64(k), 0, 1, 0, 0))
        _ = rt.key(node, "z", 2) if k == 0 else (rt.dispatch(2) if k == 1 else rt.dispatch(Event(3, "", 0)))
        assert_equal(rt.app.xs[len(rt.app.xs) - 1], 100 + Float64(k))
        assert_equal(rt.app.order[len(rt.app.order) - 1], "other")
        assert_equal(rt.app.order[len(rt.app.order) - 2], "pan")
    rt.queue_pan(-1, PanPoint(0, 0, 0, 0, 0))
    rt.queue_pan(999, PanPoint(0, 0, 0, 0, 0))
    _ = rt.take_pans()
    assert_equal(len(rt.app.xs), 43)
    print("pans: ok")
