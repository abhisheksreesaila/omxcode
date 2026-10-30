# mojoui.vision_presets: ready-made settings for mojoui.videotable's generic analyzers, per kind of footage (goal 39 M4).
# Nothing here is code that sees: only colour ranges, sizes and a stripe-code layout handed to the generic parts, so a new
# kind of footage is a new preset (or a real model in the Analyzer slot), not a new analyzer.
#
#   var table = scan(video, warehouse_analyzer(), warehouse_ranges(), WAREHOUSE_CELL)
#
# The warehouse: cardboard pallets on a belt, each with a white label carrying a 19-cell stripe code (an OCR stand-in;
# scripts/media_data.py's code_spec), an orange-red tear on damaged ones; workers whose faces are skin-tone disks.

from mojoui.videotable import ColourRange, StripeSpec, ObjectAnalyzer, FaceAnalyzer, Both

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
