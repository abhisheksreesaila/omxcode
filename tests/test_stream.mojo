# mojoui.http streams through the runtime, as an app uses them (goal 35 M0): update() asks for a stream; each SSE event
# (or body piece) comes back as its own Event from Runtime.poll, then one end Event. Needs scripts/http_server.py:
#   STREAM_TEST_URL=http://127.0.0.1:PORT/ STREAM_TEST_DEAD=http://127.0.0.1:PORT2/ build/test_stream
# Prints one line per case (scripts/check.py M0 reads them).
from std.testing import assert_equal, assert_true
from std.os import getenv
from mojoui.app import App, Event, Runtime
from mojoui import View, Text
from mojoui.http import Http, Request, SseReader, utf8_whole, MAX_SSE_LINE
from mojoui.clock import now_ns

comptime CASES = 13
comptime ORDER = 0
comptime CHUNKS = 1
comptime TRICKLE = 2
comptime DROP = 3
comptime TIMEOUT = 4
comptime CANCEL = 5
comptime REFUSED = 6
comptime POST = 7
comptime STATUS = 8
comptime BIGEVENT = 9  # bounds (reviewer, D-719): one event past 1 MB, a stream that never ends, one that lasts, chunk sizes
comptime FLOOD = 10
comptime LONG = 11
comptime HUGECHUNK = 12
comptime BIGCHUNK = 13
comptime PIECE = 100  # PIECE + case: a piece; END + case: the end (ranges 100–113, 200–213)
comptime END = 200


struct Probe(App):
    comptime HTTP = True
    var http: Http
    var pieces: List[List[Event]]
    var ends: List[List[Event]]
    var piece_ms: List[List[Int]]
    var end_ns: List[Int]
    var after_end: List[Int]  # pieces that came after their end
    var cancel_ns: Int
    var t0: Int

    def __init__(out self):
        self.http = Http()
        self.pieces = List[List[Event]]()
        self.ends = List[List[Event]]()
        self.piece_ms = List[List[Int]]()
        self.end_ns = List[Int]()
        self.after_end = List[Int]()
        for _ in range(CASES + 1):
            self.pieces.append(List[Event]())
            self.ends.append(List[Event]())
            self.piece_ms.append(List[Int]())
            self.end_ns.append(0)
            self.after_end.append(0)
        self.cancel_ns = 0
        self.t0 = now_ns()

    def title(self) -> String:
        return "stream probe"

    def update(mut self, e: Event):
        if e.message >= PIECE and e.message <= PIECE + CASES:
            var k = e.message - PIECE
            if len(self.ends[k]) > 0:
                self.after_end[k] += 1
            self.pieces[k].append(e.copy())
            self.piece_ms[k].append((now_ns() - self.t0) // 1_000_000)
            if k == CANCEL and len(self.pieces[k]) == 5:
                self.http.cancel(55)
                self.cancel_ns = now_ns()
        elif e.message >= END and e.message <= END + CASES:
            var k = e.message - END
            self.ends[k].append(e.copy())
            self.end_ns[k] = now_ns()

    def view(self) -> View:
        return Text("stream probe")

    def requests(mut self) -> List[Request]:
        return self.http.take()

    def open(mut self, k: Int, var req: Request):
        self.http.send(req^.stream(END + k).tagged(50 + k))


def shown(s: String) -> String:
    return "'" + s + "'"


def end_of(app: Probe, k: Int) -> String:
    var e = app.ends[k][0].copy()
    return "end " + String(e.number) + " " + shown(e.error)


def until(mut rt: Runtime[Probe], k: Int, seconds: Int) raises -> Int:
    """Polls as a host's clock would (every wake_in) until case k ended; the polls made."""
    var deadline = now_ns() + seconds * 1_000_000_000
    var polls = 0
    while len(rt.app.ends[k]) == 0 and now_ns() < deadline:
        var w = rt.wake_in(now_ns() // 1000)
        assert_true(w >= 0 and w <= 4000, "polls often while a stream is out")
        var t = now_ns() + w * 1000
        while now_ns() < t:
            pass
        _ = rt.poll(now_ns() // 1000)
        polls += 1
    assert_equal(len(rt.app.ends[k]), 1, "case " + String(k) + " ended once")
    return polls


def main() raises:
    var base = getenv("STREAM_TEST_URL")
    assert_true(base != "", "set STREAM_TEST_URL (scripts/http_server.py)")
    # the SSE reader on its own: CRLF, comments, multi-line data, named events, a split across feeds
    var r = SseReader()
    var a = r.feed("data: one\r\n\r\n: note\nevent: tick\ndata: a\ndata: b\n".as_bytes())
    assert_equal(len(a), 1)
    assert_equal(a[0].data, "one")
    var b = r.feed("\nda".as_bytes())
    assert_equal(len(b), 1)
    assert_equal(b[0].name, "tick")
    assert_equal(b[0].data, "a\nb")
    var c = r.feed("ta: x\n\n".as_bytes())
    assert_equal(c[0].name, "message")
    assert_equal(c[0].data, "x")
    var cut = List[UInt8]()
    for byte in "é".as_bytes():
        cut.append(byte)
    assert_equal(utf8_whole(cut), 2)
    _ = cut.pop()
    assert_equal(utf8_whole(cut), 0, "half a character waits")

    var rt = Runtime(Probe())
    # 200 events in order
    var t0 = now_ns()
    rt.app.open(ORDER, Request.get(PIECE + ORDER, base + "sse?n=200"))
    _ = rt.dispatch(0)
    var dispatch_ms = Float64(now_ns() - t0) / 1e6
    _ = until(rt, ORDER, 20)
    var in_order = len(rt.app.pieces[ORDER]) == 200
    for i in range(len(rt.app.pieces[ORDER])):
        var e = rt.app.pieces[ORDER][i].copy()
        if e.text != String(i) or e.number != i + 1 or e.name != "message" or e.id != 50:
            in_order = False
    print("ORDER: " + String(len(rt.app.pieces[ORDER])) + " events, each its own update, data 0..199 " + ("in order" if in_order else "OUT OF ORDER") + "; " + end_of(rt.app, ORDER))
    print("DISPATCH: " + String(dispatch_ms) + " ms")
    # chunks (not SSE): each piece of the body as it comes
    rt.app.open(CHUNKS, Request.get(PIECE + CHUNKS, base + "chunked"))
    _ = rt.dispatch(0)
    _ = until(rt, CHUNKS, 20)
    var joined = String("")
    for ref e in rt.app.pieces[CHUNKS]:
        joined += e.text
        assert_equal(e.name, "chunk")
    print("CHUNKS: " + String(len(rt.app.pieces[CHUNKS])) + " pieces " + shown(joined) + "; " + end_of(rt.app, CHUNKS))
    # a slow trickle: each event arrives when it's sent; the loop keeps polling between them
    rt.app.open(TRICKLE, Request.get(PIECE + TRICKLE, base + "trickle?n=10&ms=150"))
    _ = rt.dispatch(0)
    var polls = until(rt, TRICKLE, 20)
    var at = String("")
    var first = rt.app.piece_ms[TRICKLE][0] if len(rt.app.piece_ms[TRICKLE]) > 0 else 0
    for ms in rt.app.piece_ms[TRICKLE]:
        at += (" " if at.byte_length() > 0 else "") + String(ms - first)
    print("TRICKLE: " + String(len(rt.app.pieces[TRICKLE])) + " events at " + at + "; polls between " + String(polls) + "; " + end_of(rt.app, TRICKLE))
    # a dropped connection mid-stream
    rt.app.open(DROP, Request.get(PIECE + DROP, base + "drop"))
    _ = rt.dispatch(0)
    _ = until(rt, DROP, 20)
    print("DROP: " + String(len(rt.app.pieces[DROP])) + " events; " + end_of(rt.app, DROP))
    # a timeout: the longest silence
    rt.app.open(TIMEOUT, Request.get(PIECE + TIMEOUT, base + "stall").timeout(500))
    _ = rt.dispatch(0)
    _ = until(rt, TIMEOUT, 20)
    var quiet_ms = (rt.app.end_ns[TIMEOUT] - rt.app.t0) // 1_000_000 - (rt.app.piece_ms[TIMEOUT][0] if len(rt.app.piece_ms[TIMEOUT]) > 0 else 0)
    print("TIMEOUT: " + String(len(rt.app.pieces[TIMEOUT])) + " events; " + end_of(rt.app, TIMEOUT) + " after " + String(quiet_ms) + " ms")
    # cancel by the app (after its 5th event, in update())
    rt.app.open(CANCEL, Request.get(PIECE + CANCEL, base + "forever"))
    _ = rt.dispatch(0)
    _ = until(rt, CANCEL, 30)
    var t_end = now_ns() + 400_000_000  # (keep polling a while: nothing more may arrive)
    while now_ns() < t_end:
        _ = rt.poll(now_ns() // 1000)
    print("CANCEL: " + String(len(rt.app.pieces[CANCEL])) + " events; " + end_of(rt.app, CANCEL) + "; after the end " + String(rt.app.after_end[CANCEL]))
    print("CANCEL_AT: " + String((rt.app.cancel_ns - rt.app.t0) // 1_000_000))
    # refused
    rt.app.open(REFUSED, Request.get(PIECE + REFUSED, getenv("STREAM_TEST_DEAD") + "sse"))
    _ = rt.dispatch(0)
    _ = until(rt, REFUSED, 20)
    print("REFUSED: " + String(len(rt.app.pieces[REFUSED])) + " events; " + end_of(rt.app, REFUSED))
    # a POST of JSON, streamed back (the AG-UI shape)
    rt.app.open(POST, Request.post_json(PIECE + POST, base + "sse", '{"hello": "sse"}').header("Accept", "text/event-stream"))
    _ = rt.dispatch(0)
    _ = until(rt, POST, 20)
    var last = rt.app.pieces[POST][len(rt.app.pieces[POST]) - 1].text if len(rt.app.pieces[POST]) > 0 else String("")
    print("POST: " + String(len(rt.app.pieces[POST])) + " events, the last " + shown(last) + "; " + end_of(rt.app, POST))
    # a 500 to a stream: no pieces, the body on the end
    rt.app.open(STATUS, Request.get(PIECE + STATUS, base + "fail"))
    _ = rt.dispatch(0)
    _ = until(rt, STATUS, 20)
    print("STATUS: " + String(len(rt.app.pieces[STATUS])) + " events; " + end_of(rt.app, STATUS) + " " + shown(rt.app.ends[STATUS][0].text))
    # bounds: an event past 1 MB; a flood past the stream's byte limit; a drip past its time limit; chunk sizes
    rt.app.open(BIGEVENT, Request.get(PIECE + BIGEVENT, base + "bigevent"))
    _ = rt.dispatch(0)
    _ = until(rt, BIGEVENT, 20)
    print("BIGEVENT: " + String(len(rt.app.pieces[BIGEVENT])) + " events; " + end_of(rt.app, BIGEVENT))
    rt.app.open(FLOOD, Request.get(PIECE + FLOOD, base + "flood").limit(1_000_000, 60_000))
    _ = rt.dispatch(0)
    _ = until(rt, FLOOD, 20)
    print("FLOOD: " + String(len(rt.app.pieces[FLOOD])) + " events; " + end_of(rt.app, FLOOD))
    rt.app.open(LONG, Request.get(PIECE + LONG, base + "forever").limit(64_000_000, 600))
    _ = rt.dispatch(0)
    _ = until(rt, LONG, 20)
    print("LONG: " + String(len(rt.app.pieces[LONG])) + " events; " + end_of(rt.app, LONG))
    rt.app.open(HUGECHUNK, Request.get(PIECE + HUGECHUNK, base + "hugechunk"))
    _ = rt.dispatch(0)
    _ = until(rt, HUGECHUNK, 20)
    print("HUGECHUNK: " + String(len(rt.app.pieces[HUGECHUNK])) + " events; " + end_of(rt.app, HUGECHUNK))
    rt.app.open(BIGCHUNK, Request.get(PIECE + BIGCHUNK, base + "bigchunk"))
    _ = rt.dispatch(0)
    _ = until(rt, BIGCHUNK, 20)
    print("BIGCHUNK: " + String(len(rt.app.pieces[BIGCHUNK])) + " events; " + end_of(rt.app, BIGCHUNK))
    # the reader alone: a line past its cap stops it
    var capped = SseReader()
    var long_line = List[UInt8](length=MAX_SSE_LINE + 10, fill=97)
    _ = capped.feed(Span(long_line))
    assert_true(capped.error.find("longer") >= 0, "a line past the cap: " + capped.error)
    assert_equal(len(capped.feed("data: more\n\n".as_bytes())), 0, "a stopped reader reads nothing more")
    assert_equal(len(rt.inflight), 0, "nothing left out")
    print("test_stream: all passed")
