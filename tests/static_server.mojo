# Goal 66 M0's server: mojoui.static's folder (STATIC_ROOT) on mojoui.serve at / (STATIC_PORT). Driven by
# docs/goals/66-check.py (raw requests, httpx, headless Chromium).
from std.os import getenv
from mojoui.serve import Handler, Req, Reply, serve
from mojoui.static import Static
from mojoui import libc


struct Site(Handler):
    var files: Static

    def __init__(out self, var files: Static):
        self.files = files^

    def answer(self, mut req: Req) -> Reply:
        var r = self.files.handle(req)
        if r.status != 0:
            return r^
        return Reply.not_found()

    def blocking(self, req: Req) -> Bool:
        return False

    def tick(self):
        pass

    def stop(self):
        pass


def main() raises:
    var served = serve(Site(Static(getenv("STATIC_ROOT", "."))), port=atol(getenv("STATIC_PORT", "8000")))
    print("SAAS: listening " + String(served.port), flush=True)
    while not served.stopped():
        _ = libc.poll(0, 0, 500)
    served.stop()
