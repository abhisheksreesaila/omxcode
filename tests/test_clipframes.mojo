# Goal 71 M2: mojoui.robotpool's Clips: frames decoded by the engine for the pool's cards.
#   G71_INDEX, G71_PICKS as test_robotpool; G71_OUT: writes frames.json and the raw frames there
# Six full-size frames (H, W, 3 bytes each) for docs/goals/71/oracle.py to compare with omxcore's Python decode; 24 posters
# timed cold (a fresh Clips: datasets opened, decoded, scaled) and cached; a poster's size and a loop's length.
from std.os import getenv
from mojoui.robotpool import RobotPool, Clips, POSTER_AT, split_key
from mojoui.clock import now_ns


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def keys_in(text: String, name: String) raises -> List[String]:
    var at = text.find('"' + name + '"')
    check(at >= 0, "picks.json has no " + name)
    var end = text.find("]", at)
    var out = List[String]()
    var i = text.find('"', at + name.byte_length() + 2)
    while i >= 0 and i < end:
        var j = text.find('"', i + 1)
        out.append(String(text[byte=i + 1:j]))
        i = text.find('"', j + 1)
    return out^


def main() raises:
    var out = getenv("G71_OUT", "build/g71/frames")
    var text = String()
    with open(getenv("G71_PICKS", "build/g71/picks.json"), "r") as f:
        text = f.read()
    var one = keys_in(text, "one")
    var exp = keys_in(text, "export")
    var pool = RobotPool.open(getenv("G71_INDEX", getenv("HOME") + "/Projects/mxframe/build/robotics/index.parquet"))
    # 24 posters, cold then cached
    var hits = pool.like([one[0]], 24)
    var keys = List[String]()
    for h in hits.hits:
        keys.append(h.key)
    var t0 = now_ns()
    var clips = Clips()
    clips.posters_for(pool, keys)
    var cold = Float64(now_ns() - t0) / 1e6
    check(len(clips.posters) == 24, "posters: " + String(len(clips.posters)))
    t0 = now_ns()
    clips.posters_for(pool, keys)
    for k in keys:
        _ = clips.posters[k].w
    var cached = Float64(now_ns() - t0) / 1e6
    var p = clips.poster(pool, keys[0])
    check(0 < max(p.w, p.h) and max(p.w, p.h) <= clips.side and len(p.pixels) == p.w * p.h, "poster " + String(p.w) + "x" + String(p.h))  # (never scaled up: LIBERO frames are 256 x 256)
    var lp = clips.loop(pool, keys[0], 16)
    check(len(lp) == 16 and lp[0].w == p.w, "loop: " + String(len(lp)))
    var differ = False
    for i in range(len(lp[0].pixels)):
        if lp[0].pixels[i] != lp[15].pixels[i]:
            differ = True
            break
    check(differ, "a loop's first and last frames are the same picture")
    # six full-size frames: three libero posters, and an SO-100 episode at 0 s, 1 s and its poster time
    var j = String('{"frames": [')
    var n = 0
    var picks = List[String]()
    var times = List[Float64]()
    for i in range(3):
        picks.append(one[i])
        times.append(pool.episodes[pool.at(one[i])].seconds * POSTER_AT)
    for t in [0.0, 1.0, pool.episodes[pool.at(exp[0])].seconds * POSTER_AT]:
        picks.append(exp[0])
        times.append(t)
    for i in range(len(picks)):
        var kp = split_key(picks[i])
        var got = clips.frames_rgb(kp[0], [kp[1]], [times[i]])
        var w, h = got[1], got[2]
        var hwc = List[UInt8](length=w * h * 3, fill=0)
        for y in range(h):
            for x in range(w):
                for c in range(3):
                    hwc[(y * w + x) * 3 + c] = got[0][c * w * h + y * w + x]
        var name = "frame" + String(i) + ".raw"
        with open(out + "/" + name, "w") as f:
            f.write_bytes(Span(hwc))
        j += (", " if n > 0 else "") + '{"key": "' + picks[i] + '", "t": ' + String(times[i]) + ', "w": ' + String(w) + ', "h": ' + String(h) + ', "raw": "' + name + '"}'
        n += 1
    j += '], "cold_ms": ' + String(cold) + ', "cached_ms": ' + String(cached) + ', "decoder": "' + clips.decoder + '"}'
    with open(out + "/frames.json", "w") as f:
        f.write(j)
    print("clipframes: 24 posters " + String(cold) + " ms cold, " + String(cached) + " ms cached (" + clips.decoder + "); " + String(n) + " frames written")
