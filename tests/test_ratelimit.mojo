# mojoui.ratelimit (goal 60 M7, the auditor's flood note): the limit per key, the sliding window, and a flood of distinct
# live keys that stays bounded (the least recently seen are evicted; recent keys keep their counts).
from mojoui.ratelimit import RateLimit
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
    for i in range(250_000):
        var s = now_ns()
        _ = flood.hit("ip-" + String(i))
        slowest = max(slowest, Int(now_ns() - s))
        if i % 1000 == 0:
            _ = flood.hit("me")  # a regular keeps coming back: recent, never evicted
    expect(flood.size() <= 100_001, "the table grew past its cap: " + String(flood.size()))
    var refused = 0
    for _ in range(10):
        if flood.hit("me") > 0:
            refused += 1
    expect(refused > 0, "the regular's count was lost in the flood")
    print("flood: ok (" + String(flood.size()) + " keys after 250,000; slowest hit " + String(slowest // 1_000_000) + " ms)")
