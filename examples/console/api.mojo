# The daemon's admin API as requests: the base URL from $MXC_URL (default: the console's own consoled, when one sits
# next to its binary (the download: http://127.0.0.1:$MXC_PORT, 11435 unless set); else the fixture server's,
# scripts/console_fixture.py), the admin key from $MXC_ADMIN_KEY sent as the original's X-Mst-Admin header (core.js
# ADMIN: "1" when unset, as the original sends). Replies come back to update() as Events.

from mojoui.http import Http, Request
from mojoui.shared import environment
from mojoui.json import json_string
from mojoui.companion import exe_dir
from std.os.path import exists

comptime DEFAULT_URL = "http://127.0.0.1:8765"
comptime LOAD_TIMEOUT_MS = 660_000  # (consoled answers a load once the model's server runs, up to 10 minutes: D-5539)


def own_url() -> String:
    """Where the console's own consoled listens: 127.0.0.1 and $MXC_PORT (11435, the Python daemon's, unless set)."""
    return "http://127.0.0.1:" + environment("MXC_PORT", "11435")


struct Api(Movable):
    var http: Http
    var base: String

    def __init__(out self):
        self.http = Http()
        var url = environment("MXC_URL", own_url() if exists(exe_dir() + "/consoled") else String(DEFAULT_URL))
        self.base = String(url.rstrip("/"))

    def admin(self, var r: Request, timeout_ms: Int = 15000) -> Request:
        if environment("MXC_ADMIN_KEY") != "":
            return r^.header_from_env("X-Mst-Admin", "MXC_ADMIN_KEY").timeout(timeout_ms)
        return r^.header("X-Mst-Admin", "1").timeout(timeout_ms)

    def get(mut self, message: Int, path: String, id: Int = 0):
        self.http.send(self.admin(Request.get(message, self.base + path).tagged(id)))

    def post(mut self, message: Int, path: String, json: String = "", id: Int = 0, timeout_ms: Int = 15000):
        """`timeout_ms`: longer for a call that waits on purpose (a model's load answers once its server runs)."""
        if json == "":
            self.http.send(self.admin(Request(message, "POST", self.base + path, "").tagged(id), timeout_ms))
        else:
            self.http.send(self.admin(Request.post_json(message, self.base + path, json).tagged(id), timeout_ms))

    def send(mut self, message: Int, method: String, path: String, json: String = "", id: Int = 0):
        var r = Request(message, method, self.base + path, json)
        if json != "":
            r = r^.header("Content-Type", "application/json")
        self.http.send(self.admin(r^.tagged(id)))

    def take(mut self) -> List[Request]:
        return self.http.take()


def chat_curl(endpoint: String, model: String, say: String, spaced: Bool = False, cacert: String = "") -> String:
    """The chat completion call to paste in a terminal, the key from $MXC_API_KEY (model-page.js, blade-add.js curlFor,
    blade-security.js): the model's name and the words go through json_string and the JSON sits in single quotes for
    the shell, a ' in it written '\\''. `spaced`: blade-add.js's {"model": …} spacing, else the compact {"model":…};
    `cacert`: the CA file to trust (the LAN endpoint)."""
    var colon = String(": ") if spaced else String(":")
    var comma = String(", ") if spaced else String(",")
    var body = ("{\"model\"" + colon + json_string(model) + comma + "\"messages\"" + colon + "[{\"role\"" + colon + "\"user\"" + comma
                + "\"content\"" + colon + json_string(say) + "}]}")
    var trust = ("--cacert " + cacert + " ") if cacert != "" else String("")
    return ("curl " + trust + endpoint + "/chat/completions \\\n  -H \"Authorization: Bearer $MXC_API_KEY\" \\\n  -H \"Content-Type: application/json\" \\\n"
            + "  -d '" + body.replace("'", "'\\''") + "'")
