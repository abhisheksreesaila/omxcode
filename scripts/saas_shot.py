"""The saas gallery picture (goal 57 M6): ada (Pro) and ben (free) side by side, each a real run of the native app
against the server and the checker's Google and Stripe stand-ins (docs/goals/57-check.py), headless.

    pixi run python scripts/saas_shot.py        → docs/gallery/img/saas.png (and build/g57/shot-*.png)
"""
import importlib.util
import os
import threading
import time
import urllib.parse
from pathlib import Path

import httpx
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("g57", ROOT / "docs/goals/57-check.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def main():
    import headless
    headless.ensure()
    g.OUT.mkdir(parents=True, exist_ok=True)
    stand = g.StandIn()
    srv = g.Server("shot", stand)
    opened = g.OUT / "shot-opened.txt"
    opened.write_text("")
    opener = g.OUT / "shot-opener.sh"
    opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n')
    opener.chmod(0o755)
    stop, seen = threading.Event(), []

    def browser():  # plays the system browser, as M4's does
        while not stop.is_set():
            for url in [l for l in opened.read_text().splitlines() if l][len(seen):]:
                seen.append(url)
                if url.startswith(srv.base + "/login"):
                    u = url
                    for _ in range(4):
                        r = httpx.get(u, follow_redirects=False, timeout=20)
                        if r.status_code not in (301, 302, 303, 307):
                            break
                        u = urllib.parse.urljoin(u, r.headers["location"])
                elif "/pay/cs_test_" in url:
                    s = stand.pay(url.rsplit("/", 1)[1])
                    body, h = g.signed(g.event("checkout.session.completed", s))
                    httpx.post(srv.base + "/billing/webhook", content=body, headers=h)
            time.sleep(0.1)

    threading.Thread(target=browser, daemon=True).start()
    try:
        b = g.run(["scripts/build.sh", "saas", "linux"])
        assert not b.returncode, b.stderr[-800:]
        runs = [(("ada@example.com", "Ada"), "tap:Sign in with Google;waitfor:Sign out=20000;type:Note=Coffee beans;type:Amount=18.50;tap:Add;waitfor:Coffee beans=10000;"
                 "type:Note=Team lunch;type:Amount=64.20;tap:Add;waitfor:Team lunch=10000;tap:Upgrade;waitfor:Manage plan=20000"),
                (("ben@example.com", "Ben"), "tap:Sign in with Google;waitfor:Sign out=20000;type:Note=Rent;type:Amount=1200;tap:Add;waitfor:Rent=10000")]
        shots = []
        for who, steps in runs:
            stand.who = who
            shot = g.OUT / f"shot-{who[1].lower()}.png"
            r = g.run([str(g.APP)], 600, {"MOJOUI_TEST": steps, "MOJOUI_OPENER": str(opener), "SAAS_SERVER": srv.base,
                                         "MOJOUI_SHOT": str(shot), "MOJOUI_WINDOW": "520x560"})
            out = r.stdout + r.stderr
            assert "Signed in as " + who[0] in out, out[-1500:]
            shots.append(Image.open(shot).convert("RGB"))
        # each window centres its own content, so the panes' tops differ: crop both from their content's top (the
        # first row that differs from its own edge pixel), then lay them side by side, tops aligned
        def content_top(im):
            px = im.load()
            for y in range(im.size[1]):
                edge = px[2, y]
                if any(sum(abs(a - b) for a, b in zip(px[x, y], edge)) > 24 for x in range(0, im.size[0], 2)):
                    return y
            return 0
        tops = [max(content_top(im) - 32, 0) for im in shots]
        panes = [im.crop((0, t, im.size[0], im.size[1])) for im, t in zip(shots, tops)]
        h = min(p.size[1] for p in panes)
        panes = [p.crop((0, 0, p.size[0], h)) for p in panes]
        w = panes[0].size[0]
        gap = 24
        pic = Image.new("RGB", (w * 2 + gap, h), panes[0].getpixel((2, h - 2)))
        pic.paste(panes[0], (0, 0))
        pic.paste(panes[1], (w + gap, 0))
        dest = ROOT / "docs/gallery/img/saas.png"
        pic.save(dest, optimize=True)
        print("wrote", dest, pic.size)
    finally:
        stop.set()
        srv.stop()
        stand.close()


if __name__ == "__main__":
    import sys
    sys.path.insert(0, str(ROOT / "scripts"))
    main()
