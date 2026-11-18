# mojoui.geocode: where a named place is, from OpenStreetMap's geocoder (Nominatim), checked against a guess (goal 77 M3). A
# language model knows which place was meant and roughly where it is; a geocoder knows exactly where things called that are, but
# not which one was meant (Paris, Texas). So a place is the geocoder's answer when it lies within `limit_km` (60) of the guess,
# else the guess stands (omx-local's rule).
#
#   var geo = Geocoder.shared()                      # the process's (one cache, one queue, one request a second)
#   var a = geo[].lookup("Belém Tower, Lisbon")      # at once: a.state GEO_PENDING until the answer lands (call again each frame)
#   var p = settle(guess_lat, guess_lon, a)          # (lat, lon, how): how = "checked" (the geocoder's, near the guess) or "guessed"
#   km(lat1, lon1, lat2, lon2)                       # great-circle distance
#
# The web request runs on a thread (mojoui.webcache) through a process-wide gate of one request every 1.05 s (Nominatim's usage
# policy: at most one a second, a User-Agent naming the program, results cached), and every answer, "nothing found" too, is kept
# in $MOJOUI_GEO_CACHE (default ~/.cache/omxcode/geocode), one small file per query, so a place is asked for once.

from std.collections import Dict
from std.math import sin, cos, asin, sqrt, pi
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from std.os import getenv
from mojoui.json import Json, J_ARRAY
from mojoui.pointer import norm
from mojoui.shared import get_shared, put_shared
from mojoui.tiles import USER_AGENT
from mojoui.webcache import CachedFetch, Gate, fetch_cached

comptime SLOT_GEOCODER = 181  # mojoui.shared slot: the process's Geocoder
comptime GEOCODER_URL = "https://nominatim.openstreetmap.org/search"
comptime GEO_PENDING = 0
comptime GEO_FOUND = 1
comptime GEO_NONE = 2  # the geocoder knows no such place
comptime GEO_FAILED = 3  # no answer (offline, refused): the guess stands
comptime LIMIT_KM = 60.0


@fieldwise_init
struct GeoAnswer(Copyable, Movable, ImplicitlyCopyable):
    var state: Int
    var lat: Float64
    var lon: Float64
    var ms: Float64  # how long it took (0 while pending)
    var from_disk: Bool
    var why: String  # GEO_FAILED: why


def km(lat1: Float64, lon1: Float64, lat2: Float64, lon2: Float64) -> Float64:
    var r = pi / 180.0
    var dl = (lat2 - lat1) * r
    var dn = (lon2 - lon1) * r
    var h = sin(dl / 2) ** 2 + cos(lat1 * r) * cos(lat2 * r) * sin(dn / 2) ** 2
    return 6371.0 * 2.0 * asin(min(1.0, sqrt(h)))


def settle(guess_lat: Float64, guess_lon: Float64, a: GeoAnswer, limit_km: Float64 = LIMIT_KM) -> Tuple[Float64, Float64, String]:
    """Where a place is: the geocoder's answer when it lies within limit_km of the guess ("checked"), else the guess ("guessed")."""
    if a.state == GEO_FOUND and km(guess_lat, guess_lon, a.lat, a.lon) <= limit_km:
        return (a.lat, a.lon, String("checked"))
    return (guess_lat, guess_lon, String("guessed"))


def _hex(v: UInt64) -> String:
    var digits = "0123456789abcdef"
    var out = String("")
    for i in range(16):
        var d = Int((v >> UInt64(60 - 4 * i)) & 15)
        out += String(digits[byte = d : d + 1])
    return out^


def fnv64(s: String) -> UInt64:
    """FNV-1a, 64 bits: the same name for a query in every run (a cache file's name)."""
    var h = UInt64(14695981039346656037)
    for b in s.as_bytes():
        h = (h ^ UInt64(b)) * UInt64(1099511628211)
    return h


def url_quote(s: String) -> String:
    """A query string value: letters, digits and -_.~ as they are, every other byte %XX."""
    var hexd = "0123456789ABCDEF"
    var out = String("")
    for b in s.as_bytes():
        var c = Int(b)
        if (48 <= c <= 57) or (65 <= c <= 90) or (97 <= c <= 122) or c == 45 or c == 95 or c == 46 or c == 126:
            out += chr(c)
        else:
            out += "%" + String(hexd[byte = c >> 4 : (c >> 4) + 1]) + String(hexd[byte = c & 15 : (c & 15) + 1])
    return out^


def parse_answer(body: String) -> GeoAnswer:
    """Nominatim's JSON (a list of places, best first) as an answer: the first place, or GEO_NONE for an empty list."""
    try:
        var j = Json.parse(body)
        if j.kind(0) != J_ARRAY:
            return GeoAnswer(GEO_FAILED, 0, 0, 0, False, "not a list of places")
        if j.size(0) == 0:
            return GeoAnswer(GEO_NONE, 0, 0, 0, False, "")
        var first = j.at(0, 0)
        var lat = atof(j.text(j.get(first, "lat")))
        var lon = atof(j.text(j.get(first, "lon")))
        if lat < -90 or lat > 90 or lon < -180 or lon > 180:
            return GeoAnswer(GEO_FAILED, 0, 0, 0, False, "a place off the earth")
        return GeoAnswer(GEO_FOUND, lat, lon, 0, False, "")
    except e:
        return GeoAnswer(GEO_FAILED, 0, 0, 0, False, "unreadable: " + String(e))


struct _Ask(Movable):
    var key: String
    var job: CachedFetch

    def __init__(out self, key: String, var job: CachedFetch):
        self.key = key
        self.job = job^


struct Geocoder(Movable):
    var answers: Dict[String, GeoAnswer]
    var out: List[_Ask]
    var gate: Gate
    var url: String
    var dir: String

    def __init__(out self):
        self.answers = Dict[String, GeoAnswer]()
        self.out = List[_Ask]()
        self.gate = Gate.make(1050)
        self.url = getenv("MOJOUI_GEOCODER", GEOCODER_URL)
        self.dir = getenv("MOJOUI_GEO_CACHE", getenv("HOME", "/tmp") + "/.cache/omxcode/geocode")

    @staticmethod
    def shared() -> Pointer[Geocoder, MutUntrackedOrigin]:
        """The process's geocoder, made on the first call (on the UI thread)."""
        var have = get_shared(SLOT_GEOCODER)
        if have == 0:
            var p = alloc(Layout[Geocoder].single()).unsafe_leak()
            p.unsafe_write(Geocoder())
            have = Int(p)
            put_shared(SLOT_GEOCODER, have)
        return Pointer[Geocoder, MutUntrackedOrigin](unsafe_from_address=have)

    def poll(mut self):
        var i = 0
        while i < len(self.out):
            if not self.out[i].job.ready():
                i += 1
                continue
            var a = self.out.pop(i)
            var ans: GeoAnswer
            if a.job.status() != 200:
                ans = GeoAnswer(GEO_FAILED, 0, 0, a.job.ms(), False, a.job.problem())
            else:
                var body = a.job.take_body()
                ans = parse_answer(String(unsafe_from_utf8=body))
                ans.ms = a.job.ms()
                ans.from_disk = a.job.from_disk()
            self.answers[a.key] = ans

    def lookup(mut self, query: String) -> GeoAnswer:
        """The answer for `query` (GEO_PENDING until it lands: ask again later; the first call sends it)."""
        self.poll()
        var key = String(norm(query).strip())
        if key == "":
            return GeoAnswer(GEO_NONE, 0, 0, 0, False, "")
        var have = self.answers.get(key)
        if have:
            return have.value()
        for i in range(len(self.out)):
            if self.out[i].key == key:
                return GeoAnswer(GEO_PENDING, 0, 0, 0, False, "")
        var url = self.url + "?q=" + url_quote(query) + "&format=jsonv2&limit=1"
        self.out.append(_Ask(key, fetch_cached(url, self.dir + "/" + _hex(fnv64(key)) + ".json", USER_AGENT, self.gate)))
        return GeoAnswer(GEO_PENDING, 0, 0, 0, False, "")

    def busy(self) -> Bool:
        return len(self.out) > 0
