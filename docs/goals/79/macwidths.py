#!/usr/bin/env python3
"""M1's lines as Chrome on the Mac lays them out (D-7976): the reference ref.mjs measures in Chromium on Linux, whose
fallback fonts for scripts the web faces lack (Hindi, Tamil, Arabic, CJK, emoji) are Linux's (Noto); the web app on a Mac
falls back to the Mac's. The same page as ref.mjs's (the web faces by @font-face, each line in a span, its width × the
device scale) is opened by the Mac's own Chrome (/Applications, already there: nothing installed), headless, with a
throwaway profile in the run's data folder, at device scale 2; the widths come back in the dumped DOM.
  macwidths.py <fixture.json> <out.json>     (MAC_SSH, MAC_SSH_KEY as scripts/mac-ssh)"""
import json, os, subprocess, sys, tempfile, pathlib, html

ROOT = pathlib.Path(__file__).resolve().parents[3]
FACES = {
    'Geist': [['normal', 'geist/Geist[wght].ttf'], ['italic', 'geist/Geist-Italic[wght].ttf']],
    'Geist Mono': [['normal', 'geistmono/GeistMono[wght].ttf']],
    'Bricolage Grotesque': [['normal', 'bricolagegrotesque/BricolageGrotesque[opsz,wdth,wght].ttf']],
    'IBM Plex Sans': [['normal', 'ibmplexsans/IBMPlexSans[wdth,wght].ttf'], ['italic', 'ibmplexsans/IBMPlexSans-Italic[wdth,wght].ttf']],
    'IBM Plex Mono': [['normal', 'ibmplexmono/IBMPlexMono-Regular.ttf', 400], ['normal', 'ibmplexmono/IBMPlexMono-Medium.ttf', 500], ['normal', 'ibmplexmono/IBMPlexMono-SemiBold.ttf', 600]],
    'Source Serif 4': [['normal', 'sourceserif4/SourceSerif4[opsz,wght].ttf'], ['italic', 'sourceserif4/SourceSerif4-Italic[opsz,wght].ttf']],
    'Instrument Serif': [['normal', 'instrumentserif/InstrumentSerif-Regular.ttf', 400], ['italic', 'instrumentserif/InstrumentSerif-Italic.ttf', 400]],
    'Caveat': [['normal', 'caveat/Caveat[wght].ttf']],
    'Literata': [['normal', 'literata/Literata[opsz,wght].ttf'], ['italic', 'literata/Literata-Italic[opsz,wght].ttf']],
    'Figtree': [['normal', 'figtree/Figtree[wght].ttf'], ['italic', 'figtree/Figtree-Italic[wght].ttf']],
}


def main():
    fixture, out = sys.argv[1], sys.argv[2]
    lines = json.loads(pathlib.Path(fixture).read_text())["textlines"]
    host = os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101")
    key = os.path.expanduser(os.environ.get("MAC_SSH_KEY", "~/.ssh/edx_mac"))
    remote = os.environ.get("MAC_SSH_DIR", "omxcode-g54") + "/data/widths"
    css = "\n".join(f'@font-face {{ font-family: "{fam}"; font-style: {st}; font-weight: {w[0] if w else "100 900"}; font-display: block; src: url("fonts/{f}") format("truetype"); }}'
                    for fam, faces in FACES.items() for st, f, *w in faces)
    page = f"""<!doctype html><meta charset="utf-8"><style>{css} body{{margin:0}} span{{white-space:pre;font-kerning:normal}}</style><body>
<pre id="out">pending</pre><script>
const lines = {json.dumps(lines)};
(async () => {{
  for (const l of lines) {{ const s = document.createElement('span'); s.id = l.id; s.textContent = l.text; Object.assign(s.style, {{ fontFamily: `"${{l.family}}"`, fontWeight: l.weight, fontStyle: l.style, fontSize: `${{l.size}}px`, position: 'absolute', left: '0', top: '0' }}); document.body.appendChild(document.createElement('div')).appendChild(s) }}
  const failed = []
  for (const l of lines) {{ try {{ await document.fonts.load(`${{l.style}} ${{l.weight}} ${{l.size}}px "${{l.family}}"`, l.text) }} catch (e) {{ failed.push(l.id) }} }}
  try {{ await document.fonts.ready }} catch (e) {{}}
  await new Promise((r) => setTimeout(r, 100))
  window.__failed = failed.concat(lines.filter((l) => !document.fonts.check(`${{l.style}} ${{l.weight}} ${{l.size}}px "${{l.family}}"`)).map((l) => l.id + '?'))
  document.getElementById('out').textContent = 'WID' + 'THS:' + JSON.stringify(Object.fromEntries(lines.map((l) => [l.id, document.getElementById(l.id).getBoundingClientRect().width * devicePixelRatio]).concat([['_failed', window.__failed.join(',')], ['_dpr', devicePixelRatio]])))
}})()
</script>"""
    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "widths.html").write_text(page)
    ssh = ["ssh", "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host]
    subprocess.run(ssh + [f"mkdir -p {remote}"], check=True)
    subprocess.run(["scp", "-q", "-i", key, str(tmp / "widths.html"), f"{host}:{remote}/"], check=True)
    subprocess.run(["scp", "-q", "-r", "-i", key, str(ROOT / "fonts"), f"{host}:{remote}/"], check=True)
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    cmd = (f'cd ~/{remote} && "{chrome}" --headless=new --disable-gpu --no-first-run --no-default-browser-check --allow-file-access-from-files '
           f'--user-data-dir="$PWD/profile" --force-device-scale-factor=2 --virtual-time-budget=15000 --dump-dom "file://$PWD/widths.html" 2>/dev/null')
    r = subprocess.run(ssh + [cmd], capture_output=True, text=True, timeout=180)
    dom = html.unescape(r.stdout)
    i = dom.find('<pre id="out">WIDTHS:')
    if i < 0:
        print("MACWIDTHS: no widths came back: " + dom[-400:], file=sys.stderr)
        sys.exit(1)
    j = dom.index("</pre>", i)
    widths = json.loads(dom[i + len('<pre id="out">WIDTHS:'):j])
    pathlib.Path(out).write_text(json.dumps({"dpr": 2, "widths": widths, "by": "Chrome on the Mac (macwidths.py)"}, indent=1))
    print("MACWIDTHS: " + json.dumps(widths))


if __name__ == "__main__":
    main()
