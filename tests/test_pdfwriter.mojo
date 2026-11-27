# mojoui.pdfwriter (goal 82 M4): pages, paths, words drawn from their fonts' outlines, a picture. tests/test_pdfwriter.py reads it
# with poppler (pdfinfo, pdftotext, pdftoppm) and qpdf --check.
#   pixi run mojo run -I . -I vendor tests/test_pdfwriter.mojo <dir>
from mojoui.pdfwriter import PdfPainter, PT_PER_PX
from mojoui.fonttext import TextStyle, engine
from std.sys import argv


def main() raises:
    var dir = String(argv()[1]) if len(argv()) > 1 else String("/tmp")
    var pdf = PdfPainter()
    pdf.page(860 * PT_PER_PX, 1080 * PT_PER_PX)
    pdf.rect(0, 0, 860, 1080, 0xFFFFFFFF, 0)
    pdf.rect(60, 60, 300, 120, 0xFF5CD6E0, 16)  # (a sticky's colour, rounded)
    pdf.run(TextStyle("Source Serif 4", 400, False, 24), "Garden plan: beds by the south wall", 80, 120, 0xFF1E2020, 0)
    pdf.run(TextStyle("Geist", 700, False, 18), "Tomatoes, Basil and Marigolds", 80, 250, 0xFF1E2020, 0)
    pdf.run(TextStyle("Geist", 400, False, 18), "नमस्ते 漢字", 80, 300, 0xFF20201E, 0)
    pdf.stroke([100.0, 400, 200, 450, 300, 400], 3, 0xFF2563EB)
    pdf.circle(500, 500, 40, 0x80DC2626)
    var px = List[UInt32]()
    for y in range(16):
        for x in range(16):
            px.append(UInt32(x * 16) | (UInt32(y * 16) << 8) | (UInt32(128) << 16) | (UInt32(255) << 24))
    pdf.image(px, 16, 16, 600, 600, 160, 160)
    pdf.page(860 * PT_PER_PX, 1080 * PT_PER_PX)
    pdf.begin_layer("p2")
    pdf.layer_transform(-860, 0, 1)  # (the second cell of a 2-column grid)
    pdf.push_clip(860, 0, 860, 1080)
    pdf.run(TextStyle("Source Serif 4", 400, False, 24), "Second page words", 900, 100, 0xFF1E2020, 0)
    pdf.run(TextStyle("Source Serif 4", 400, False, 24), "clipped away", 100, 100, 0xFF1E2020, 0)
    pdf.pop_clip()
    pdf.save(dir + "/test.pdf")
    print("test_pdfwriter: written " + dir + "/test.pdf, fonts " + String(len(pdf.fonts)))
