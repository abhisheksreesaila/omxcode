# mojoui.inspection_tables: an inspection (mojoui.inspection) as tables a sheet shows, queries and exports, and two of
# them compared from those tables (goal 39 M8). Separate from mojoui.inspection because it needs omxcore's Table and
# mojoui.sheet: the inspection's model stays testable with a plain `mojo run`.
#
#   var t = places_table(assets, found)              # one row per asset and per defect: place, kind, asset, lat, lon, severity, size_m, seen_s
#   is_places(sheet)                                 # a table shaped like that (a sheet's own, a table card's)
#   var flight = read_places(sheet)                  # back to Places and Findings (flight.assets, flight.found)
#   var worse = compare_tables(sheet_a, sheet_b, 5.0)   # assets that got worse: asset, severity_a, severity_b, change, lat, lon
#   flight_plan(path, worse_sheet, 25.0, "inspect")  # the next flight: waypoints.csv (inspection.write_waypoints)
#   place_marks(sheet)                               # its assets and defects as map marks (mojoui.mapview)
#
# Positions are kept to seven decimals (a centimetre), severities as levels 1…5 (0: none), sizes in metres.

from omxcore import Table, Job, JobBody, JobCtl, INT as MX_INT, DECIMAL as MX_DECIMAL, TEXT as MX_TEXT
from mojoui.jobs import start_ui_job
from mojoui.geo import Place
from mojoui.inspection import Finding, Change, compare, worst, write_waypoints
from mojoui.sheet import Sheet
from mojoui.mapview import MapMark, MARK_PLACE, MARK_FINDING

comptime PLACE_COLUMNS: List[String] = ["place", "kind", "asset", "lat", "lon", "severity"]


def _scaled(v: Float64, places: Int) -> Int64:
    var k = 10.0 ** places
    return Int64(Int(v * k + (0.5 if v >= 0 else -0.5)))


def places_table(assets: List[Place], found: List[Finding]) raises -> Table:
    """Assets then defects, one row each: place (P01…, D01…), kind ("asset", "defect"), asset (the asset a defect is on;
    an asset's own name), lat, lon (7 places), severity (an asset's worst defect, a defect's level; 0 none), size_m
    (a defect's measured radius), seen_s (when an asset first came into view)."""
    var t = Table.empty()
    var place = t.add_column("place", MX_TEXT)
    var kind = t.add_column("kind", MX_TEXT)
    var asset = t.add_column("asset", MX_TEXT)
    var lat = t.add_column("lat", MX_DECIMAL, 7)
    var lon = t.add_column("lon", MX_DECIMAL, 7)
    var sev = t.add_column("severity", MX_INT)
    var size = t.add_column("size_m", MX_DECIMAL, 2)
    var seen = t.add_column("seen_s", MX_DECIMAL, 1)
    for ref p in assets:
        t.append_text(place, p.name)
        t.append_text(kind, "asset")
        t.append_text(asset, p.name)
        t.append(lat, _scaled(p.lat, 7))
        t.append(lon, _scaled(p.lon, 7))
        t.append(sev, Int64(worst(found, p.name)))
        t.append_null(size)
        t.append(seen, _scaled(p.first_t, 1))
    for i in range(len(found)):
        ref f = found[i]
        var n = String(i + 1)
        t.append_text(place, "D" + ("0" + n if i + 1 < 10 else n))
        t.append_text(kind, "defect")
        t.append_text(asset, f.asset)
        t.append(lat, _scaled(f.lat, 7))
        t.append(lon, _scaled(f.lon, 7))
        t.append(sev, Int64(f.severity))
        t.append(size, _scaled(f.radius_m, 2))
        t.append_null(seen)
    t.check()
    return t^


def is_places(sheet: Sheet) -> Bool:
    """A table with the places columns (place, kind, asset, lat, lon, severity)."""
    for ref n in materialize[PLACE_COLUMNS]():
        if sheet.index(n) < 0:
            return False
    return True


struct Flight(Movable):
    """An inspection read back from its table: its assets (Places) and their defects (Findings)."""

    var assets: List[Place]
    var found: List[Finding]

    def __init__(out self):
        self.assets = List[Place]()
        self.found = List[Finding]()


def _number(sheet: Sheet, c: Int, r: Int) -> Float64:
    if c < 0 or sheet.is_null(c, r):
        return 0.0
    try:
        return Float64(sheet.plain_text(c, r).replace(",", ""))
    except:
        return 0.0


def read_places(sheet: Sheet) raises -> Flight:
    """The table's assets and defects (rows edited or sorted on the sheet read as they are now)."""
    if not is_places(sheet):
        raise Error("not an inspection's places: it needs the columns place, kind, asset, lat, lon, severity")
    var place = sheet.index("place")
    var kind = sheet.index("kind")
    var asset = sheet.index("asset")
    var lat = sheet.index("lat")
    var lon = sheet.index("lon")
    var sev = sheet.index("severity")
    var size = sheet.index("size_m")
    var out = Flight()
    for r in range(sheet.rows()):
        if not sheet.alive(r):
            continue
        var k = sheet.plain_text(kind, r)
        if k == "asset":
            var p = Place("asset", _number(sheet, lat, r), _number(sheet, lon, r))
            p.name = sheet.plain_text(place, r)
            out.assets.append(p)
        elif k == "defect":
            out.found.append(Finding(sheet.plain_text(asset, r), _number(sheet, lat, r), _number(sheet, lon, r), Int(_number(sheet, sev, r)),
                                     _number(sheet, size, r)))
    return out^


def compare_tables(a: Sheet, b: Sheet, match_m: Float64) raises -> Table:
    """Flight b against flight a (inspection.compare): the assets that got worse (a new defect, or a worse one), in
    flight b's route order: asset, severity_a, severity_b, change, lat, lon (b's measured position)."""
    var fa = read_places(a)
    var fb = read_places(b)
    var changes = compare(fa.assets, fa.found, fb.assets, fb.found, match_m)
    var t = Table.empty()
    var asset = t.add_column("asset", MX_TEXT)
    var sa = t.add_column("severity_a", MX_INT)
    var sb = t.add_column("severity_b", MX_INT)
    var change = t.add_column("change", MX_TEXT)
    var lat = t.add_column("lat", MX_DECIMAL, 7)
    var lon = t.add_column("lon", MX_DECIMAL, 7)
    for ref p in fb.assets:
        for ref c in changes:
            if c.asset == p.name and c.is_worse():
                t.append_text(asset, c.asset)
                t.append(sa, Int64(c.severity_a))
                t.append(sb, Int64(c.severity_b))
                t.append_text(change, c.change)
                t.append(lat, _scaled(p.lat, 7))
                t.append(lon, _scaled(p.lon, 7))
    t.check()
    return t^


def flight_plan(path: String, worse: Sheet, alt_m: Float64, action: String) raises -> Int:
    """The next flight plan from a worse table (compare_tables' columns): a waypoint over each of its assets at its
    position, written to `path` by inspection.write_waypoints (asset, lat, lon, alt_m, action); the waypoints' count."""
    var asset = worse.index("asset")
    var lat = worse.index("lat")
    var lon = worse.index("lon")
    if asset < 0 or lat < 0 or lon < 0:
        raise Error("a flight plan needs a table with asset, lat and lon (Compare inspections makes one)")
    var sa = worse.index("severity_a")
    var sb = worse.index("severity_b")
    var change = worse.index("change")
    var places = List[Place]()
    var changes = List[Change]()
    for r in range(worse.rows()):
        if not worse.alive(r) or worse.is_null(asset, r):
            continue
        var p = Place("asset", _number(worse, lat, r), _number(worse, lon, r))
        p.name = worse.plain_text(asset, r)
        places.append(p)
        changes.append(Change(p.name, Int(_number(worse, sa, r)), Int(_number(worse, sb, r)),
                              worse.plain_text(change, r) if change >= 0 else String("worse")))
    write_waypoints(path, changes, places, alt_m, action, worse_only=False)
    return len(places)


def place_marks(sheet: Sheet) -> List[MapMark]:
    """A places table as map marks (mojoui.mapview): assets as named rings, defects as dots sized by severity; none when
    the table isn't one."""
    var marks = List[MapMark]()
    try:
        var f = read_places(sheet)
        for ref p in f.assets:
            marks.append(MapMark(p.lat, p.lon, p.name, MARK_PLACE, 0))
        for ref d in f.found:
            marks.append(MapMark(d.lat, d.lon, "", MARK_FINDING, d.severity))
    except:
        pass
    return marks^


# ---------- compare as a job (goal 41 M3) ----------


struct CompareJob(JobBody):
    """compare_tables off the UI thread: it owns snapshots of the two places tables; its answer is the "worse" sheet."""
    comptime Out = Sheet
    var a: Sheet
    var b: Sheet
    var match_m: Float64

    def __init__(out self, var a: Sheet, var b: Sheet, match_m: Float64):
        self.a = a^
        self.b = b^
        self.match_m = match_m

    def run(mut self, ctl: JobCtl) raises -> Sheet:
        return Sheet(compare_tables(self.a, self.b, self.match_m).share(), False)


def compare_job(a: Sheet, b: Sheet, match_m: Float64) -> Job[Sheet]:
    """The later flight's places (b) against the earlier one's (a), as a job (snapshots of both): its answer is the
    "worse" table compare_tables makes; the end wakes the UI (mojoui.jobs.start_ui_job)."""
    return start_ui_job(CompareJob(a.snapshot(), b.snapshot(), match_m))
