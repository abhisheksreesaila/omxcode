# Goal 79: mojoui.buzanmap against the web map's own numbers (geometry.js, layout.js, renderer.js fit()).
#   pixi run mojo run -I . tests/test_buzanmap.mojo        → "buzanmap: ok"
from mojoui.buzanmap import BuzanMap, branch_geometry, ribbon_outline, Frame
from mojoui.skin import hexc, Skin
from mojoui.scene import Scene
from mojoui.notesshell import Boxes


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
    # (D-7936) the selected idea's branch controls: two anchors at t 1/3 and 2/3 of its curve, none for the root
    var sk = Skin("t")
    sk.derive()
    var sc = Scene(1424, 822, 1.0)
    var bx = Boxes()
    m.selected = root
    m.draw(sc, bx, 0, 0, 1424, 822, 1.0, sk, "The book")
    check(bx.find("map.anchor:The book") < 0, "no controls for the central topic")
    m.selected = c
    var bx2 = Boxes()
    m.draw(sc, bx2, 0, 0, 1424, 822, 1.0, sk, "The book")
    var a1 = bx2.find("map.anchor:Characters")
    var a2 = bx2.find("map.anchor:Characters@2")
    check(a1 >= 0 and a2 >= 0, "two anchors on the selected branch")
    var u = 1.0 / 3.0
    var v = 1 - u
    var ax = v * v * v * g.sx + 3 * v * v * u * g.ax + 3 * v * u * u * g.bx + u * u * u * g.ex
    var fv = m.fit(1424, 822, 80)
    check(abs(bx2.r[a1 * 4] + bx2.r[a1 * 4 + 2] / 2 - (fv[1] + ax * 1.0)) < 0.01, "the first anchor at t 1/3 of the curve")
    print("buzanmap: ok")
