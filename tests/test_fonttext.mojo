# Goal 79 M1: mojoui.fonttext against Chromium. FONTTEXT_REF (textwidths.json from docs/goals/79/ref.mjs),
# FONTTEXT_FIXTURE (fixture.json's textlines), FONTTEXT_DPR (the device scale both were measured at).
#   pixi run mojo run -I . tests/test_fonttext.mojo
# Prints WIDTH/NOTDEF/CRISP lines (docs/goals/79-check.py judges the widths against Chromium's) and `fonttext: ok`.
from std.os import getenv
from mojoui.fonttext_check import fontcheck


def main() raises:
    var ref_path = getenv("FONTTEXT_REF", "build/g79/ref/textwidths.json")
    var fixture = getenv("FONTTEXT_FIXTURE", "docs/goals/79/fixture.json")
    var dpr = Float64(getenv("FONTTEXT_DPR", "1.6"))
    if not fontcheck(ref_path, fixture, dpr):
        raise Error("fonttext: FAIL")
