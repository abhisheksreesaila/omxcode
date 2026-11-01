#!/usr/bin/env python3
"""Post-build step for isoarch diagrams embedded in omxlabs and omxcode pages (never edits the skill's template).

    python3 chrome.py OUT.html --accent '#3ccf6e' [--fonts ../assets/omxqua/src/fonts.css]

Makes a built diagram one fixed look that sits inside a dark omxqua page:
- only the drawing, its hover/click/select, and the flow bar (flow picker, ◀, Play, ▶|);
  no title, legend, style dropdown, Live, Theme, Fit, Fold, SVG or PNG;
- dark always, the `ink` style always; omxqua night tokens (surfaces, ink, lines, Geist) for the page,
  the brand accent for Play, the flow trail and the selection;
- solid panels, no blur; buttons styled like the site's pills.
Idempotent: running it twice gives the same file. Fails loudly if the template's palette moved.
"""
import re, sys
from pathlib import Path

def arg(name, default=None):
    a = sys.argv
    return a[a.index(name) + 1] if name in a else default

path = Path(sys.argv[1]); acc = arg("--accent", "#ededef"); fonts = arg("--fonts")
s = path.read_text()
s = re.sub(r'\n?<!-- omx-chrome -->.*?<!-- /omx-chrome -->', '', s, flags=re.S)

# 1 · dark + ink, whatever the viewer's system says
s = re.sub(r'<html lang="en"[^>]*>', '<html lang="en" data-theme="dark" data-style="ink">', s, count=1)
s = s.replace("style:STYLES.includes(spec.style) ? spec.style : 'fieldnotes'", "style:'ink'")
if "style:'ink'" not in s: sys.exit(f"{path}: couldn't fix the style (template changed?)")

# 2 · the drawing's dark palette → omxqua night (dev) + the brand accent
old = re.search(r"\{bg:'#14161b', ink:'#e8e9ee'.*?\}", s, flags=re.S)
if not old and "omx-palette" not in s: sys.exit(f"{path}: couldn't find the dark palette (template changed?)")
pal = (f"{{bg:'#151518', ink:'#ededef', muted:'#a9a9b1', edge:'#8a8a94', grid:'#1d1d21', halo:'#151518', accent:'{acc}', bug:'#ff6b6b', "
       f"pill:'#1d1d21', pillLine:'#2a2a30', nodeInk:'#0b0b0d', shadow:'#000000', shadowOp:.09, zone:0.10, thread:'{acc}', ticketInk:'#ededef'/*omx-palette*/}}")
s = re.sub(r"\{bg:'#151518', ink:'#ededef'.*?/\*omx-palette\*/\}", pal, s, flags=re.S) if "omx-palette" in s else s.replace(old.group(0), pal, 1)
s = re.sub(r'-webkit-backdrop-filter:blur\(\d+px\);?|backdrop-filter:blur\(\d+px\);?', '', s)

# 3 · the page chrome
css = f"""<!-- omx-chrome -->{f'<link rel="stylesheet" href="{fonts}">' if fonts else ''}
<style>
:root, :root[data-theme="dark"] {{ --bg:#151518; --ink:#ededef; --muted:#a9a9b1; --panel:#1d1d21; --line:#2a2a30; --chip:#1d1d21; --accent:{acc};
  --shadow:0 8px 30px #00000066; --r:999px; --font:"Geist", system-ui, -apple-system, "Segoe UI", sans-serif; }}
header, #legend, #styleSel, #bLive, #bTheme, #bFit, #bFold, #bSvg, #bPng {{ display:none !important; }}
body {{ grid-template-rows:1fr auto; background:var(--bg); }}
footer {{ border-top:1px solid #202025; padding:10px 14px; gap:8px; }}
footer button, footer select {{ height:36px; padding:0 14px; border:0; border-radius:999px; background:var(--chip); color:var(--ink);
  box-shadow:inset 0 0 0 1px var(--line); font:500 13px var(--font); transition:background .15s, transform .15s; }}
footer button:hover, footer select:hover {{ background:#25252a; }}
footer button:active {{ transform:scale(.96); }}
footer button:focus-visible, footer select:focus-visible {{ outline:2px solid var(--accent); outline-offset:2px; }}
#bPlay {{ background:var(--accent); color:#0b0b0d; box-shadow:none; font-weight:600; padding:0 18px; }}
#bPlay:hover {{ background:var(--accent); filter:brightness(1.08); }}
#caption {{ font:14px/1.45 var(--font); color:var(--ink); }}
#caption b {{ color:var(--accent); }}
#dots i.on {{ background:var(--accent); }}
#info {{ background:var(--panel); border:1px solid var(--line); border-radius:18px; font-family:var(--font); }}
.edge.on .line {{ stroke:var(--accent); }} .edge.on .head {{ fill:var(--accent); }} .edge.on .chev {{ stroke:var(--accent); }}
</style><!-- /omx-chrome -->
"""
s = s.replace("</head>", css + "</head>", 1)
path.write_text(s)
print(f"chrome: {path.name} · accent {acc}")
