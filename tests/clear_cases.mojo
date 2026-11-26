# Goal 80: frames whose opening fill a backend may clear to (gpu2d.opening_fill), and frames where it must not. Shared by
# test_gpu2d_clear (GL) and test_gpu2d_metal_clear (a Mac).
from mojoui.scene import Scene

comptime CASES = 10


def clear_name(kind: Int) -> String:
    var names: List[String] = ["opaque fill", "translucent fill", "alpha 0 fill", "no fill", "two layers, the second filled and scaled",
        "layer 0 zoomed past the canvas", "layer 0 shrunk", "a fill in a clip", "layer 0 half a pixel off", "an empty first layer, the fill in the second"]
    return names[kind]


def clears(kind: Int) -> Bool:
    """Whether the frame may be cleared to its fill: layer 0's first thing (a fill covers the whole canvas whatever the
    layer's transform or clip)."""
    return kind != 3 and kind != 9


def clear_case(kind: Int, w: Int, h: Int, k: Float64, quad: Bool = False) -> Scene:
    """quad: something nearly invisible comes before the fill, so it isn't the opening one and is drawn as a quad."""
    var s = Scene(w, h, k)
    s.begin_layer("a")
    if kind == 5:
        s.layer_transform(-10, -10, 2.0)
    elif kind == 6:
        s.layer_transform(20, 10, 0.5)
    elif kind == 8:
        s.layer_transform(0.5, 0, 1.0)
    elif kind == 7:
        s.push_clip(20, 20, 100, 80)
    if kind == 9:
        s.begin_layer("b")
    if quad:
        s.rect(40, 40, 2, 2, 0x01000000, 0)
    var fills: List[UInt32] = [0xFFF0E4D0, 0x80336699, 0x00FFFFFF, 0, 0xFFF0F0F0, 0xFFE0E0A0, 0xFFE0E0A0, 0xFFE0E0A0, 0xFFE0E0A0, 0xFF204060]
    if kind != 3:
        s.fill(fills[kind])
    s.rect(20, 20, 80, 50, 0xFFC03020, 8)
    s.rect(60, 40, 70, 40, 0x802060C0, 0)
    if kind == 7:
        s.pop_clip()
    if kind == 4:
        s.begin_layer("b")
        s.layer_transform(30, 20, 0.5)
        s.fill(0x4000FF00)
        s.rect(0, 0, 100, 100, 0xFFFF8000, 4)
    return s^
