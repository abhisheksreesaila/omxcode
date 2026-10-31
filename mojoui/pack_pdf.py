"""mojoui.pack_pdf: backend of mojoui/packpdf.mojo (goal 41 M10). A pack (a JSON spec: a title, pages of blocks) becomes an
HTML document, printed to PDF by headless Chromium (Playwright). Nothing here knows any app: the blocks are generic.

    python pack_pdf.py spec.json out.pdf

Blocks: {"kind": "facts", "items": [[label, value], ...]}, {"kind": "text", "text": ...}, {"kind": "table", "columns": [...],
"rows": [[...], ...]}, {"kind": "pdf_page", "path", "page", "boxes": [[x, y, w, h], ...] (page points), "caption"},
{"kind": "video_frame", "path", "t" (seconds), "boxes": [[x, y, w, h], ...] (pixels), "caption"}, {"kind": "image", "path",
"caption"}. Pictures are made here (PyMuPDF draws a PDF page, ffmpeg takes a frame, Pillow marks the boxes) and embedded in
the HTML as data, so the PDF carries them. The browser: $MOJOUI_CHROMIUM, else /usr/bin/chromium, else Playwright's own. Colours come from the spec ("accent", "ink", "paper", "muted", "line").
"""

import base64
import html
import io
import json
import os
import subprocess
import sys


def png_data(img):
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def mark(img, boxes, colour, scale=1.0, width=4):
    from PIL import ImageDraw

    if not boxes:
        return img
    from PIL import Image

    img = img.convert("RGBA")
    over = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    r, g, b = colour
    pad = 4 * scale
    for x, y, w, h in boxes:
        x0, y0, x1, y1 = x * scale - pad, y * scale - pad, (x + w) * scale + pad, (y + h) * scale + pad
        d.rectangle([x0, y0, x1, y1], fill=(r, g, b, 48))
        d.rectangle([x0, y0, x1, y1], outline=(r, g, b, 255), width=width)
    return Image.alpha_composite(img, over).convert("RGB")


def pdf_page(block, colour):
    import pymupdf
    from PIL import Image

    doc = pymupdf.open(block["path"])
    page = doc[int(block.get("page", 0))]
    dpi = 144
    pix = page.get_pixmap(dpi=dpi)
    img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
    return mark(img, block.get("boxes") or [], colour, dpi / 72.0, 3)


def video_frame(block, colour):
    from PIL import Image

    t = max(float(block.get("t", 0)), 0.0)
    r = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", block["path"], "-frames:v", "1", "-f", "image2pipe",
                        "-vcodec", "png", "-"], capture_output=True)
    if r.returncode or not r.stdout:
        raise RuntimeError(f"ffmpeg couldn't take the frame at {t:.3f} s of {block['path']}: {r.stderr.decode()[-300:]}")
    img = Image.open(io.BytesIO(r.stdout)).convert("RGB")
    return mark(img, block.get("boxes") or [], colour, 1.0, 5)


def hex_rgb(h, default):
    try:
        h = h.lstrip("#")
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    except Exception:
        return default


def block_html(block, colour):
    k = block.get("kind")
    esc = html.escape
    if k == "facts":
        rows = "".join(f"<div class='fact'><span>{esc(str(a))}</span><b>{esc(str(b))}</b></div>" for a, b in block.get("items", []))
        return f"<div class='facts'>{rows}</div>"
    if k == "text":
        return f"<p>{esc(block.get('text', ''))}</p>"
    if k == "heading":
        return f"<h2>{esc(block.get('text', ''))}</h2>"
    if k == "table":
        head = "".join(f"<th>{esc(str(c))}</th>" for c in block.get("columns", []))
        body = "".join("<tr>" + "".join(f"<td>{esc(str(c))}</td>" for c in r) + "</tr>" for r in block.get("rows", []))
        cap = f"<div class='caption'>{esc(block['caption'])}</div>" if block.get("caption") else ""
        return f"<figure class='table'>{cap}<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></figure>"
    if k in ("pdf_page", "video_frame", "image"):
        if k == "pdf_page":
            img = pdf_page(block, colour)
        elif k == "video_frame":
            img = video_frame(block, colour)
        else:
            from PIL import Image
            img = Image.open(block["path"]).convert("RGB")
        cap = f"<figcaption>{esc(block['caption'])}</figcaption>" if block.get("caption") else ""
        cls = "page" if k == "pdf_page" else "frame"
        return f"<figure class='{cls}'><img src='{png_data(img)}'/>{cap}</figure>"
    raise ValueError(f"unknown block kind {k!r}")


CSS = """
@page { size: A4; margin: 16mm 16mm 18mm 16mm; }
* { box-sizing: border-box; }
body { font-family: 'Inter', 'Helvetica Neue', Arial, sans-serif; color: %(ink)s; background: %(paper)s; margin: 0; font-size: 10.5pt; line-height: 1.45; }
header.pack { display: flex; align-items: baseline; justify-content: space-between; border-bottom: 2px solid %(accent)s; padding-bottom: 8px; margin-bottom: 14px; }
header.pack h1 { font-size: 20pt; margin: 0; letter-spacing: -0.01em; }
header.pack .sub { color: %(muted)s; font-size: 9.5pt; }
section { page-break-after: always; }
section:last-child { page-break-after: auto; }
h2 { font-size: 13pt; margin: 0 0 10px; }
.facts { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin: 0 0 14px; }
.fact { border: 1px solid %(line)s; border-radius: 8px; padding: 8px 10px; background: #fff; }
.fact span { display: block; color: %(muted)s; font-size: 8pt; text-transform: uppercase; letter-spacing: 0.04em; }
.fact b { font-size: 11.5pt; }
p { margin: 0 0 12px; }
figure { margin: 0 0 14px; }
figure img { width: 100%%; border: 1px solid %(line)s; border-radius: 6px; display: block; }
figure.page img { max-height: 205mm; width: auto; max-width: 100%%; margin: 0 auto; }
figcaption, .caption { color: %(muted)s; font-size: 8.5pt; margin-top: 4px; }
.caption { margin: 0 0 4px; }
table { width: 100%%; border-collapse: collapse; font-size: 9pt; }
th { text-align: left; color: %(muted)s; font-weight: 600; border-bottom: 1px solid %(line)s; padding: 4px 6px; }
td { border-bottom: 1px solid %(line)s; padding: 4px 6px; font-variant-numeric: tabular-nums; }
footer { color: %(muted)s; font-size: 8pt; margin-top: 10px; }
"""


def build_html(spec):
    colours = {"accent": spec.get("accent") or "#1f8a5b", "ink": spec.get("ink") or "#1c2024", "paper": spec.get("paper") or "#ffffff",
               "muted": spec.get("muted") or "#5f6b76", "line": spec.get("line") or "#d9dee3"}
    colour = hex_rgb(colours["accent"], (31, 138, 91))
    pages = []
    for i, p in enumerate(spec.get("pages", [])):
        blocks = "".join(block_html(b, colour) for b in p.get("blocks", []))
        head = (f"<header class='pack'><h1>{html.escape(spec.get('title', ''))}</h1><div class='sub'>{html.escape(spec.get('subtitle', ''))}"
                f" · page {i + 1} of {len(spec.get('pages', []))}</div></header>")
        heading = f"<h2>{html.escape(p['heading'])}</h2>" if p.get("heading") else ""
        foot = f"<footer>{html.escape(spec['footer'])}</footer>" if spec.get("footer") else ""
        pages.append(f"<section>{head}{heading}{blocks}{foot}</section>")
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{CSS % colours}</style></head><body>{''.join(pages)}</body></html>"


def main():
    spec_path, out = sys.argv[1], sys.argv[2]
    with open(spec_path, encoding="utf-8") as f:
        spec = json.load(f)
    doc = build_html(spec)
    if out.endswith(".html"):
        with open(out, "w", encoding="utf-8") as f:
            f.write(doc)
        return
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        exe = os.environ.get("MOJOUI_CHROMIUM") or ("/usr/bin/chromium" if os.path.exists("/usr/bin/chromium") else None)
        browser = p.chromium.launch(executable_path=exe) if exe else p.chromium.launch()
        page = browser.new_page()
        page.set_content(doc, wait_until="load")
        page.pdf(path=out, format="A4", print_background=True, prefer_css_page_size=True)
        browser.close()
    print(f"PACK: {out} {len(spec.get('pages', []))} pages", flush=True)


if __name__ == "__main__":
    main()
