# mojoui.ratelimit (goal 60 M7, the auditor's flood note): the limit per key, the sliding window, and a flood of distinct
# live keys that stays bounded (the least recently seen are evicted; recent keys keep their counts). Round 3 (R5): the
# regular's first hit after the flood is refused, an over-full sweep leaves at most 90 % of the cap, and no hit takes
# over 50 ms: a sweep selects a cut from the cap's 100,000 last-seen times (5–15 ms measured here, quickselect), so 50 ms is over 3× that, still under
# a request's noticeable delay, and fails a sweep that went back to scanning on every hit (seconds).
from mojoui.ratelimit import RateLimit, _MAX_KEYS, _KEEP_KEYS
from mojoui.clock import now_ns


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var rl = RateLimit(limit=3, window_s=60)
    for _ in range(3):
        expect(rl.hit("a") == 0, "an allowed hit refused")
    var wait = rl.hit("a")
    expect(wait > 0 and wait <= 61, "the 4th hit wasn't refused with a wait")
    expect(rl.hit("b") == 0, "another key shares a's count")
    print("limit: ok")
    var short = RateLimit(limit=1, window_s=0.2)
    expect(short.hit("x") == 0 and short.hit("x") > 0, "the short window's limit")
    var t0 = now_ns()
    while now_ns() - t0 < 300_000_000:
        pass
    expect(short.hit("x") == 0, "the window didn't slide")
    print("window: ok")
    var flood = RateLimit(limit=5, window_s=600)
    _ = flood.hit("me")
    _ = flood.hit("me")
    var slowest = 0
    var sweeps = 0
    var last = flood.size()
    for i in range(250_000):
        var s = now_ns()
        _ = flood.hit("ip-" + String(i))
        slowest = max(slowest, Int(now_ns() - s))
        var size = flood.size()
        if size < last:  # (an over-full sweep just ran: what it left, plus this hit's key)
            sweeps += 1
            expect(size <= _KEEP_KEYS + 1, "an over-full sweep left " + String(size) + " keys (cap " + String(_MAX_KEYS) + ", 90 %: " + String(_KEEP_KEYS) + ")")
        last = size
        if i % 1000 == 0 and i > 0:
            _ = flood.hit("me")  # a regular keeps coming back: recent, never evicted
    expect(sweeps >= 1, "no over-full sweep ran")
    expect(flood.size() <= _MAX_KEYS + 1, "the table grew past its cap: " + String(flood.size()))
    expect(flood.hit("me") > 0, "the regular's first hit after the flood was allowed: its count was lost")
    expect(slowest <= 50_000_000, "a hit took " + String(slowest // 1_000_000) + " ms (bound 50 ms)")
    print("flood: ok (" + String(flood.size()) + " keys after 250,000; slowest hit " + String(slowest // 1_000_000) + " ms, " + String(sweeps) + " over-full sweeps)")
