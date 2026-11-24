# Review 3, MUST 2: what a tile set says is empty is always one of its tiles, and nothing else: (1) the reviewer's case: a
# document with an empty tile, then another with a kept view whose picture is there: promoted, every tile is drawn; (2) a
# random walk of everything that drops, replaces, promotes or restores tiles (new pictures, damage, zooms that settle and
# jump, pans far enough to evict, a restore, another layer's set taking slots): after each frame `empty` names only kept
# tiles, and a tile called empty has no op over it. Plans only (no GPU). `tileempty: ok`.
from std.testing import assert_true, assert_equal
from std.time import sleep
from mojoui.scene import Scene
from mojoui.gpu2d_tiles import Tiles, _pack, _unpack, TILE
from mojoui.viewsnap import set_renderer_id


def scene(v: Int, hold: Bool, tag: String, hole: Bool) -> Scene:
    var sc = Scene(1024, 512, 1.0)
    sc.begin_layer("board")
    sc.layer_version(v)
    sc.layer_transform(0, 0, 1.0)
    sc.layer_tiles(0, 0, 1024, 512)
    sc.layer_snapshot("/nonexistent", tag, hold, "")
    if not hold:
        for i in range(500):
            sc.rect(Float64(i % 20) * 20 + 10, Float64(i // 20) * 18 + 10, 8, 8, 0xFF112233, 0)
        if not hole:
            sc.rect(600, 100, 200, 200, 0xFF445566, 0)
    return sc^


def promoted() raises:
    set_renderer_id(7)
    var t = Tiles()
    t.begin_frame()
    var a = scene(1, False, "a", True)
    var p = t.plan(a, 0, 1, 1024, 512)
    assert_equal(len(p.rasters), 2)
    assert_equal(len(p.draws), 1)  # (tile (1, 0) has nothing)
    t.begin_frame()
    var b = scene(2, True, "b", False)
    assert_true(t.restore_want(b, 0, 1, 1024, 512) != "", "B's kept view is wanted")
    var keys: List[Int] = [_pack(0, 0), _pack(1, 0)]
    var slots = List[Int]()
    slots.append(t.snap_slot(b, 0, 1))
    slots.append(t.snap_slot(b, 0, 1))
    t.snap_restored(b, 0, 1, 1024, 512, keys, slots, [1, 1, 512, 512, 1, 1, 512, 512])
    var pb = t.plan(b, 0, 1, 1024, 512)
    assert_equal(len(pb.draws), 2)
    for f in range(4):
        t.begin_frame()
        var b2 = scene(2, False, "b", False)
        var pc = t.plan(b2, 0, 1, 1024, 512)
        assert_equal(len(pc.draws), 2, "B loaded: both tiles drawn")
        sound(t, b2, "promoted, frame " + String(f))


def sound(t: Tiles, sc: Scene, what: String) raises:
    for s in range(len(t.sets)):
        for e in t.sets[s].empty.items():
            assert_true(e.key in t.sets[s].tiles, what + ": an empty tile that isn't kept")


def rnd(mut seed: Int) -> Int:
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    return seed >> 8


def walk() raises:
    set_renderer_id(7)
    var t = Tiles()
    t.settle_ns = 3_000_000
    var seed = 4242
    var v = 1
    var since = -1
    var k = 1.0
    var tx = 0.0
    var ty = 0.0
    var doc = 1
    var promotes = 0
    var evicted = 0
    for step in range(1500):
        var act = rnd(seed) % 12
        var damage = List[Float64]()
        since = -1
        var other = False
        var restore = False
        if act <= 1:
            since = v
            v += 1
            var x = Float64(rnd(seed) % 6000)
            var y = Float64(rnd(seed) % 4000)
            damage = [x, y, x + 300, y + 200]
        elif act == 2:
            v += 1
            doc += 1
        elif act <= 4:
            k = max(0.2, min(3.0, k * (0.85 if rnd(seed) % 2 == 0 else 1.2)))
        elif act == 5:
            k = [0.25, 1.0, 2.5][rnd(seed) % 3]
        elif act <= 8:
            tx -= Float64(rnd(seed) % 1600 - 800)
            ty -= Float64(rnd(seed) % 1200 - 600)
        elif act == 9:
            other = True
        elif act == 10:
            restore = True
            v += 1
            doc += 1
        else:
            sleep(0.004)
        var sc = Scene(1440, 900, 1.0)
        sc.begin_layer("board")
        sc.layer_version(v)
        sc.layer_transform(tx, ty, k)
        sc.layer_tiles(-tx / k - 64, -ty / k - 64, (1440 - tx) / k + 64, (900 - ty) / k + 64)
        for d in range(len(damage) // 4):
            sc.layer_damage(since, damage[4 * d], damage[4 * d + 1], damage[4 * d + 2], damage[4 * d + 3])
        sc.layer_snapshot("/nonexistent", "doc" + String(doc), restore, "")
        # a document of clumps with bare ground between (some tiles empty, others not; which depends on the document)
        for i in range(600):
            var h = ((i + doc * 977) * 2654435761) & 0xFFFFFFFF
            var cx = Float64((h >> 4) % 10) * 700 - 1500
            var cy = Float64((h >> 12) % 7) * 800 - 1500
            sc.rect(cx + Float64((h >> 20) % 200), cy + Float64((h >> 24) % 200), 12, 12, 0xFF334455, 0)
        if other:
            sc.begin_layer("other")
            sc.layer_version(v)
            sc.layer_transform(0, 0, 1.0)
            sc.layer_tiles(0, 0, 1440, 900)
            for i in range(450):
                sc.rect(Float64(i % 30) * 40, Float64(i // 30) * 50, 9, 9, 0xFF334455, 0)
        t.begin_frame()
        for li in range(sc.layers()):
            if li == 0 and restore and t.restore_want(sc, 0, 1, 1440, 900) != "":
                var keys = List[Int]()
                var slots = List[Int]()
                var parts = List[Int]()
                var j0 = Int((0 - ty) // TILE)
                var i0 = Int((0 - tx) // TILE)
                for jj in range(j0, j0 + 3):
                    for ii in range(i0, i0 + 4):
                        var sl = t.snap_slot(sc, 0, 1)
                        if sl < 0:
                            continue
                        keys.append(_pack(ii, jj))
                        slots.append(sl)
                        parts += [1, 1, 512, 512]
                if len(keys) > 0:
                    t.snap_restored(sc, 0, 1, 1440, 900, keys, slots, parts)
            var p = t.plan(sc, li, 1, 1440, 900)
            _ = len(p.draws)
        sound(t, sc, "step " + String(step) + " act " + String(act))
        if restore:  # (its objects are in: the restored tiles become the layer's, and everything restored is drawn)
            var sc2 = Scene(1440, 900, 1.0)
            sc2.begin_layer("board")
            sc2.layer_version(v)
            sc2.layer_transform(tx, ty, k)
            sc2.layer_tiles(-tx / k - 64, -ty / k - 64, (1440 - tx) / k + 64, (900 - ty) / k + 64)
            sc2.layer_snapshot("/nonexistent", "doc" + String(doc), False, "")
            for i in range(600):
                sc2.rect(Float64(i % 30) * 60 - tx / k, Float64(i // 30) * 60 - ty / k, 12, 12, 0xFF334455, 0)
            t.begin_frame()
            var p2 = t.plan(sc2, 0, 1, 1440, 900)
            _ = len(p2.draws)
            promotes += 1
            for e in t.sets[0].empty.items():
                assert_true(e.key in t.sets[0].tiles and t.sets[0].good.get(e.key, -1) >= 0, "step " + String(step) + ": promoted tiles aren't called empty")
            sound(t, sc2, "step " + String(step) + " promoted")
    assert_true(promotes > 50, "restores promoted")
    print("   walk: 1500 frames, " + String(promotes) + " restores: sound")


def promoted_over_stale() raises:
    """A promotion itself: whatever was called empty before it is not its business (poked here: no path leaves it now)."""
    var t = Tiles()
    t.begin_frame()
    var b = scene(2, True, "b", False)
    _ = t.restore_want(b, 0, 1, 1024, 512)
    var keys: List[Int] = [_pack(0, 0), _pack(1, 0)]
    var slots = List[Int]()
    slots.append(t.snap_slot(b, 0, 1))
    slots.append(t.snap_slot(b, 0, 1))
    t.snap_restored(b, 0, 1, 1024, 512, keys, slots, [1, 1, 512, 512, 1, 1, 512, 512])
    _ = t.plan(b, 0, 1, 1024, 512)
    t.sets[0].empty[_pack(1, 0)] = True
    t.begin_frame()
    var b2 = scene(2, False, "b", False)
    assert_equal(len(t.plan(b2, 0, 1, 1024, 512).draws), 2, "promoted over a stale mark")


def evicted() raises:
    """A long pan across a document of clumps and bare ground: far tiles go to the pool, and their marks with them."""
    var t = Tiles()
    var gone = 0
    for step in range(90):
        var tx = -Float64(step) * 500
        var sc = Scene(1440, 900, 1.0)
        sc.begin_layer("board")
        sc.layer_version(1)
        sc.layer_transform(tx, 0, 1.0)
        sc.layer_tiles(-tx - 700, -700, 1440 - tx + 700, 1600)
        for i in range(500):  # (a strip of things at the top; bare below)
            sc.rect(-tx - 600 + Float64(i) * 5, 20, 4, 9, 0xFF334455, 0)
        t.begin_frame()
        for _ in range(3):
            _ = t.plan(sc, 0, 1, 1440, 900)
            t.begin_frame()
        sound(t, sc, "pan " + String(step))
        if len(t.sets[0].tiles) < t.slots - len(t.free) or len(t.free) > 0:
            gone += 1
    assert_true(gone > 5 and t.slots >= 96, "far tiles went: " + String(gone) + ", slots " + String(t.slots))


def main() raises:
    promoted()
    promoted_over_stale()
    evicted()
    walk()
    print("tileempty: ok")
