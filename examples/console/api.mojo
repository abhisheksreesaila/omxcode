# The daemon's admin API as requests: the base URL from $MXC_URL (default: the fixture server's,
# scripts/console_fixture.py), the admin key from $MXC_ADMIN_KEY sent as the original's X-Mst-Admin header (core.js
# ADMIN: "1" when unset, as the original sends). Replies come back to update() as Events.

from mojoui.http import Http, Request
from mojoui.shared import environment
from mojoui.json import json_string

comptime DEFAULT_URL = "http://127.0.0.1:8765"


struct Api(Movable):
    var http: Http
    var base: String

    def __init__(out self):
        self.http = Http()
        var url = environment("MXC_URL", DEFAULT_URL)
        self.base = String(url.rstrip("/"))

    def admin(self, var r: Request) -> Request:
        if environment("MXC_ADMIN_KEY") != "":
            return r^.header_from_env("X-Mst-Admin", "MXC_ADMIN_KEY").timeout(15000)
        return r^.header("X-Mst-Admin", "1").timeout(15000)

    def get(mut self, message: Int, path: String, id: Int = 0):
        self.http.send(self.admin(Request.get(message, self.base + path).tagged(id)))

    def post(mut self, message: Int, path: String, json: String = "", id: Int = 0):
        if json == "":
            self.http.send(self.admin(Request(message, "POST", self.base + path, "").tagged(id)))
        else:
            self.http.send(self.admin(Request.post_json(message, self.base + path, json).tagged(id)))

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
