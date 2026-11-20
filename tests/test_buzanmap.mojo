# Goal 79: mojoui.buzanmap against the web map's own numbers (geometry.js, layout.js, renderer.js fit()).
#   pixi run mojo run -I . tests/test_buzanmap.mojo        → "buzanmap: ok"
from mojoui.buzanmap import BuzanMap, branch_geometry, ribbon_outline, Frame
from mojoui.skin import hexc


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("buzanmap: FAIL " + what)


def main() raises:
    var m = BuzanMap()
    var root = m.add(-1, "The book", 0, 0, hexc("#ef684b"))
    var c = m.add(root, "Characters", 280, -130, hexc("#efad28"))
    _ = m.add(c, "Mara", 500, -190, hexc("#efad28"))
    # card sizes as layout.js: root at least 180 × 76, an idea max(58, words) + 26 × 40
    check(m.card_size(root)[0] == 180 and m.card_size(root)[1] == 76, "root card")
    check(abs(m.card_size(2)[0] - (95.82 / 1.02 - 10)) < 1.0, "an idea card width (Mara: the web box 95.82 at 102 % is the card plus 10 of selection rect)")
    # one-bend branch: starts 30 inside the parent's edge toward the child, ends 2 inside the child
    var g = branch_geometry(m.frame(root), m.frame(c))
    check(g.sx > 0 and g.sx < 90 and g.ey > -130 and g.ex < 280, "branch end points")
    var pts = ribbon_outline(g, 34, 8, 36)
    check(len(pts) == 2 * 2 * 37, "ribbon outline")
    # fit: never above 1.35, centred
    var f = m.fit(1424, 822, 80)
    check(f[0] <= 1.35 and f[0] >= 0.45, "fit scale")
    print("buzanmap: ok")
