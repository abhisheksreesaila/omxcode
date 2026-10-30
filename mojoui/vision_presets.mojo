# mojoui.vision_presets: ready-made settings for mojoui.videotable's generic analyzers, per kind of footage (goal 39 M4).
# Nothing here is code that sees: only colour ranges, sizes and a stripe-code layout handed to the generic parts, so a new
# kind of footage is a new preset (or a real model in the Analyzer slot), not a new analyzer.
#
#   var table = scan(video, warehouse_analyzer(), warehouse_ranges(), WAREHOUSE_CELL)
#
# The warehouse: cardboard pallets on a belt, each with a white label carrying a 19-cell stripe code (an OCR stand-in;
# scripts/media_data.py's code_spec), an orange-red tear on damaged ones; workers whose faces are skin-tone disks.

from mojoui.videotable import ColourRange, StripeSpec, ObjectAnalyzer, FaceAnalyzer, Both, MeasuredRegionsAnalyzer
from mojoui.inspection import SizeScale

comptime WAREHOUSE_CELL = 4
comptime WARM = 0  # cardboard and skin: hue 14–45°, moderately saturated (the classes' order in warehouse_ranges)
comptime TEAR = 1  # the damage colour: red-orange, strongly saturated
comptime LIGHT = 2  # a label: almost no colour, bright


def warm_range() -> ColourRange:
    return ColourRange(14, 45, 56, 192, 60, 255)


def warehouse_ranges() -> List[ColourRange]:
    var r = List[ColourRange]()
    r.append(warm_range())
    r.append(ColourRange(350, 16, 150, 255, 90, 255))
    r.append(ColourRange(0, 359, 0, 30, 170, 255))
    return r^


def stripe_code_19() -> StripeSpec:
    """start 101 | 12 id bits | even parity | stop 101, 6 px cells; the bars cover 11–57 % of the label's height."""
    return StripeSpec(6, 0b101, 3, 12, True, 0b101, 3, 0.18, 0.52)


def warehouse_analyzer() -> Both[ObjectAnalyzer, FaceAnalyzer]:
    """Pallets (tracked, coded, damaged or not) and faces (for blurring)."""
    return Both(ObjectAnalyzer("pallet", warm_range(), WARM, LIGHT, TEAR, stripe_code_19(), min_w=96, min_h=110),
                FaceAnalyzer(WARM))


# ---------- the drone: a power line seen from above (scripts/media_data.py's drone section) ----------
#
#   var table = scan(video, drone_analyzer(), drone_ranges(), DRONE_CELL)
#   georeference(table, telemetry, drone_camera())
#   var poles = places(table, "insulator", DRONE_ASSET_RADIUS_M, DRONE_ASSET_MIN_ROWS)
#   var marks = places(table, "defect", DRONE_DEFECT_RADIUS_M, DRONE_DEFECT_MIN_ROWS)
#
# Assets are the insulator strings (bright, faintly blue-grey ceramic discs, three strings under each crossarm) joined
# into one place per crossarm; a defect is a scorch: a dark core with an orange-red rim, measured filled (rim and core).
# Classic GPU colour vision on generated footage, not a learned model: a detector in the Analyzer slot replaces these.

comptime DRONE_CELL = 4
comptime INSULATOR = 0  # classes' order in drone_ranges
comptime SCORCH = 1
comptime DRONE_ASSET_RADIUS_M = 6.0  # a crossarm's strings lie within ±2.5 m of its middle; poles stand 30 m apart
comptime DRONE_ASSET_MIN_ROWS = 20  # seen on at least that many string-rows (a pole is in view for ~3 s, 3 strings a frame)
comptime DRONE_DEFECT_RADIUS_M = 2.0
comptime DRONE_DEFECT_MIN_ROWS = 30  # a mark is in view for ~3 s (90 frames); field-edge colour fringes flicker for a few
comptime DRONE_DEFECT_TO_ASSET_M = 6.0  # a mark sits on a string, ≤ 4 m from the strings' middle
comptime DRONE_MATCH_M = 5.0  # the same asset on two flights: measured within metres of each other


def insulator_range() -> ColourRange:
    return ColourRange(180, 250, 8, 80, 130, 255)


def scorch_rim_range() -> ColourRange:
    return ColourRange(5, 35, 150, 255, 110, 255)


def drone_ranges() -> List[ColourRange]:
    var r = List[ColourRange]()
    r.append(insulator_range())
    r.append(scorch_rim_range())
    return r^


def drone_camera_gsd_per_m_alt() -> Float64:
    """The footage's camera: 0.001 m of ground per pixel per metre of altitude (6 cm/px at 60 m)."""
    return 0.001


def drone_analyzer() -> Both[MeasuredRegionsAnalyzer, MeasuredRegionsAnalyzer]:
    """Insulator strings (≈ 11 × 45 px at 60 m, a few degrees off vertical) and scorch marks (rim cells may be thin:
    a cell joins with 4 of its 16 pixels)."""
    return Both(MeasuredRegionsAnalyzer("insulator", insulator_range(), INSULATOR, min_w=6, max_w=36, min_h=12, max_h=72, min_area=40),
                MeasuredRegionsAnalyzer("defect", scorch_rim_range(), SCORCH, min_w=4, max_w=64, min_h=4, max_h=64, min_count=4, min_area=24))


def drone_severity() -> SizeScale:
    """The generator's scorch model: a 16-point blob of radius 0.22 + 0.17 × severity metres (each point's radius
    jittered ±15 %), area ≈ 16/2 · sin(2π/16) · r² = 3.06 r²; severity 1…5. The H.264 footage's 4:2:0 colour smears
    the rim about half a pixel outward: 0.03 m at 60 m (D-897)."""
    return SizeScale(0.22, 0.17, 5, 3.06, 0.03)
