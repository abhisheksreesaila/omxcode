# Goal 50 M0: mojoui (http, effects, sqlite, app) and Flare in one binary. Mojo allows one signature per external
# symbol per binary, so a libc function both declare with different types breaks the link (the 2026-10-26 probe:
# pthread_create, read, ...); this test uses the parts of each that call libc and must build and run.
from std.os import getenv
from mojoui.http import Request, Response
from mojoui.http_socket import SocketTransport
from mojoui.effects import start
from mojoui.sqlite import Database
from mojoui.app import App, Event
from mojoui.clock import now_ns
from flare.http import HttpClient


def main() raises:
    # mojoui: a request on a worker thread (pthread_create, sockets, poll) to a closed port
    var job = start[SocketTransport](Request.get(1, "http://127.0.0.1:9/"))
    var t0 = now_ns()
    while not job.ready() and now_ns() - t0 < 5_000_000_000:
        pass
    var r = job.response()
    if r.error == "":
        raise Error("mojoui: a closed port answered")
    # mojoui: SQLite
    var db = Database(":memory:")
    db.exec("create table t (x integer)")
    # flare: its client (sockets, poll, getaddrinfo) to the same closed port
    var c = HttpClient()
    var refused = False
    try:
        _ = c.get("http://127.0.0.1:9/")
    except:
        refused = True
    if not refused:
        raise Error("flare: a closed port answered")
    print("link: ok")
