# mojoui.inspection: an inspection from the air as a table, and two inspections compared (goal 39 M8). Generic: things
# (poles, turbines, roof panels) and defects found on them, each a mojoui.geo Place; nothing here knows what a pole is.
#
#   var scale = SizeScale(0.22, 0.17, 5, 3.06, 0.03)      # a defect's ground area → a severity level 1…5
#   var found = findings(assets, defects, scale, 6.0)    # each defect: its asset (the nearest within 6 m), level, position
#   write_findings(path, found)                          # asset, lat, lon, severity (one row per defect)
#   var changes = compare(assets_a, found_a, assets_b, found_b, 5.0)   # assets joined across flights by distance
#   write_changes(path, changes, worse_only=True)        # asset, severity_a, severity_b, change
#   write_waypoints(path, changes, assets_b, 25.0, "inspect", worse_only=True)   # the next flight plan
#
# Severity is a size class, not a judgement: the scale's levels are the radii base_m + step_m × level of a mark whose area
# is area_k × radius² (π for a disc), read from the area measured on the ground. A real model (a classifier in the
# Analyzer slot) would set the level itself; the rest of this file doesn't change.

from std.math import sqrt
from mojoui.geo import Place, nearest, metres


@fieldwise_init
struct SizeScale(Copyable, Movable, ImplicitlyCopyable):
    """Ground area (m²) → level 1…levels: radius = sqrt(area / area_k) - bleed_m, level = round((radius - base_m) /
    step_m). bleed_m: how far the measured colour reaches past the mark's true edge (video codecs keep colour at half
    resolution, so a saturated rim smears about half a pixel outward)."""

    var base_m: Float64
    var step_m: Float64
    var levels: Int
    var area_k: Float64
    var bleed_m: Float64

    def radius(self, area_m2: Float64) -> Float64:
        return max(sqrt(max(area_m2, 0.0) / self.area_k) - self.bleed_m, 0.0)

    def level(self, area_m2: Float64) -> Int:
        var x = (self.radius(area_m2) - self.base_m) / self.step_m
        return min(max(Int(x + 0.5), 1), self.levels)


@fieldwise_init
struct Finding(Copyable, Movable, ImplicitlyCopyable):
    """A defect on an asset: the asset's name ("" when none is near), the defect's own position, its level and the
    radius it was measured at (m)."""

    var asset: String
    var lat: Float64
    var lon: Float64
    var severity: Int
    var radius_m: Float64


def findings(assets: List[Place], defects: List[Place], scale: SizeScale, max_m: Float64, on_assets_only: Bool = True) -> List[Finding]:
    """Each defect, assigned to the nearest asset within max_m metres, its level read from its median ground area.
    on_assets_only: a mark with no asset near is the defect colour somewhere else (a field's edge, a roof), left out."""
    var out = List[Finding]()
    for d in defects:
        var k = nearest(assets, d.lat, d.lon, max_m)
        if k < 0 and on_assets_only:
            continue
        out.append(Finding(assets[k].name if k >= 0 else String(""), d.lat, d.lon, scale.level(d.size), scale.radius(d.size)))
    return out^


def worst(found: List[Finding], asset: String) -> Int:
    """The highest level among an asset's defects (0: none)."""
    var s = 0
    for f in found:
        if f.asset == asset:
            s = max(s, f.severity)
    return s


@fieldwise_init
struct Change(Copyable, Movable, ImplicitlyCopyable):
    """One asset across two inspections: its name (flight b's), worst level then and now (0: none) and what changed:
    "new" (a defect where there was none), "worse", "same", "better", "fixed" (none now), "clean" (none either time),
    "unseen" (not found on flight a)."""

    var asset: String
    var severity_a: Int
    var severity_b: Int
    var change: String

    def is_worse(self) -> Bool:
        return self.change == "new" or self.change == "worse"


def compare(assets_a: List[Place], found_a: List[Finding], assets_b: List[Place], found_b: List[Finding], match_m: Float64) -> List[Change]:
    """Flight b's assets, each joined to flight a's nearest asset within match_m metres, with their worst levels."""
    var out = List[Change]()
    for p in assets_b:
        var sb = worst(found_b, p.name)
        var k = nearest(assets_a, p.lat, p.lon, match_m)
        if k < 0:
            out.append(Change(p.name, 0, sb, "unseen"))
            continue
        var sa = worst(found_a, assets_a[k].name)
        var c: String
        if sa == 0 and sb == 0:
            c = "clean"
        elif sa == 0:
            c = "new"
        elif sb == 0:
            c = "fixed"
        elif sb > sa:
            c = "worse"
        elif sb < sa:
            c = "better"
        else:
            c = "same"
        out.append(Change(p.name, sa, sb, c))
    return out^


def _num(v: Float64) -> String:
    """Seven decimals (a centimetre in latitude), the way telemetry writes positions."""
    var neg = v < 0
    var m = Int(abs(v) * 1e7 + 0.5)
    var frac = String(m % 10000000)
    while frac.byte_length() < 7:
        frac = "0" + frac
    return ("-" if neg else "") + String(m // 10000000) + "." + frac


def write_findings(path: String, found: List[Finding]) raises:
    """asset, lat, lon, severity, radius_m: one row per defect."""
    var s = String("asset,lat,lon,severity,radius_m\n")
    for f in found:
        s += f.asset + "," + _num(f.lat) + "," + _num(f.lon) + "," + String(f.severity) + "," + String(Float64(Int(f.radius_m * 100 + 0.5)) / 100.0) + "\n"
    with open(path, "w") as fh:
        fh.write(s)


def write_changes(path: String, changes: List[Change], worse_only: Bool = True) raises:
    """asset, severity_a, severity_b, change: the assets that got worse (or all of them)."""
    var s = String("asset,severity_a,severity_b,change\n")
    for c in changes:
        if c.is_worse() or not worse_only:
            s += c.asset + "," + String(c.severity_a) + "," + String(c.severity_b) + "," + c.change + "\n"
    with open(path, "w") as fh:
        fh.write(s)


def write_waypoints(path: String, changes: List[Change], assets: List[Place], alt_m: Float64, action: String,
                    worse_only: Bool = True) raises:
    """asset, lat, lon, alt_m, action: the next flight plan, a waypoint over each asset that got worse (or every asset),
    at its measured position (assets: the flight the changes' names come from), in route order."""
    var s = String("asset,lat,lon,alt_m,action\n")
    for p in assets:
        for c in changes:
            if c.asset == p.name and (c.is_worse() or not worse_only):
                s += p.name + "," + _num(p.lat) + "," + _num(p.lon) + "," + String(alt_m) + "," + action + "\n"
    with open(path, "w") as fh:
        fh.write(s)
