"""Record omxplorer's launch clips (docs/launch/posts.md): the native window and the browser, from a separate build folder.

  pixi run python scripts/clips.py [native|web|all]      → build/clips/sentence-gtk.mp4, sentence-web.mp4 (+ stills)
  pixi run python scripts/clips.py island                → build/clips/island-100m.mp4 (+ a still mid-query): goal 30's demo

  pixi run python scripts/clips.py robots [DATA]         → docs/img/clip-robots.mp4 (+ .jpg) and build/g47/shots/*.png: goal 47

island: the native window over goal 20's 100M-row file, from launch: it opens in the background (the island counts),
Create table, a chart, "median by region" (0.7 s), "by month, as a line" (3 s), the island running and landing each time.

native: GTK on the private headless display through scripts/live.py (real XTest input); only the ask field, because a
popover's shadow draws black on Xvfb (no compositor). web: headless Chromium, where a word's
popover is HTML: tap "Sum", pick Average (frames from Chromium's screencast, timed into a video by ffmpeg). Both open build/data/orders_1m.csv. Copies the builds to build/clips first,
so a check running from build/ never sees its binary change mid-run.
"""
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/clips"
DATA = ROOT / "build/data/orders_1m.csv"
SIZE = (1742, 876)
WEB = (1742, 1100)  # (the browser's board scrolls the chart under the fold at 876)

NATIVE = ";".join([
    "wait:5000", "click:1352,819", "wait:2500",  # Import → Create table
    "click:737,75", "wait:1500",  # toolbar Chart
    "drag:537,761,1390,761", "wait:1200", "move:900,300", "wait:600",  # the chart's corner: as wide as the table
    "record:{out}/sentence-gtk.mp4", "wait:1500",
    "click:280,507", "wait:300", "type:by product, largest first, top 5", "wait:500", "key:Return", "wait:2200",
    "click:280,507", "wait:300", "type:median", "wait:500", "key:Return", "wait:2200",
    "click:280,507", "wait:300", "type:sum by month, every month, in data order, as a line", "wait:500", "key:Return", "wait:2800",
    "shot:{out}/sentence-gtk.png", "stoprecord",
])


BIG = ROOT.parent / "mojo-ui" / "build/g20/big.parquet"
ISLAND = ";".join([
    "record:{out}/island-100m.mp4", "wait:3200",  # launch: the 100M-row file opens in a job (the island: "Opening big.parquet · N%")
    "click:1352,819", "wait:1500",  # Import → Create table
    "click:737,75", "wait:1200",  # toolbar Chart (sum by region: 50 ms)
    "drag:537,761,1390,761", "wait:900", "move:900,300", "wait:500",  # the chart's corner: as wide as the table
    "click:280,507", "wait:300", "type:median by region", "wait:400", "key:Return", "wait:2600",
    "click:280,507", "wait:300", "type:by month, as a line", "wait:400", "key:Return", "wait:1500",
    "shot:{out}/island-100m.png", "wait:4200",  # (the still: mid-query, the island with its share done and pace)
    "shot:{out}/island-100m-done.png", "stoprecord",
])


def island():
    shutil.rmtree(OUT / "gtk", ignore_errors=True)
    shutil.copytree(ROOT / "build/omxplorer/linux", OUT / "gtk")
    big = BIG if BIG.exists() else ROOT / "build/g20/big.parquet"
    r = subprocess.run([sys.executable, str(ROOT / "scripts/live.py"), str(OUT / "gtk/omxplorer"), ISLAND.format(out=OUT),
                        "--size", f"{SIZE[0]}x{SIZE[1]}", "--env", f"OMX_OPEN={big}", "--env", f"OMX_DOCUMENTS={OUT / 'docs'}"],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("island: " + (r.stdout + r.stderr)[-800:])
    print(f"island: {OUT / 'island-100m.mp4'}")


def native():
    shutil.rmtree(OUT / "gtk", ignore_errors=True)
    shutil.copytree(ROOT / "build/omxplorer/linux", OUT / "gtk")
    r = subprocess.run([sys.executable, str(ROOT / "scripts/live.py"), str(OUT / "gtk/omxplorer"), NATIVE.format(out=OUT),
                        "--size", f"{SIZE[0]}x{SIZE[1]}", "--env", f"OMX_OPEN={DATA}", "--env", f"OMX_DOCUMENTS={OUT / 'docs'}"],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("native: " + (r.stdout + r.stderr)[-800:])
    print(f"native: {OUT / 'sentence-gtk.mp4'}")


def web():
    from playwright.sync_api import sync_playwright
    sys.path.insert(0, str(ROOT / "scripts"))
    from drive import free_port, settle, CHROMIUM
    shutil.rmtree(OUT / "web", ignore_errors=True)
    shutil.copytree(ROOT / "build/omxplorer/web", OUT / "web")
    port = free_port()
    env = dict(os.environ, OMX_OPEN=str(DATA), OMX_DOCUMENTS=str(OUT / "docs"))
    server = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(OUT / "web"), str(port)], cwd=ROOT, env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f"http://127.0.0.1:{port}/"
    try:
        for _ in range(600):
            try:
                urllib.request.urlopen(url + "static/htmx.min.js", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=CHROMIUM, headless=True)
            warm = browser.new_page(viewport={"width": SIZE[0], "height": SIZE[1]})  # (the file opens before the recording starts)
            warm.goto(url)
            settle(warm)
            warm.close()
            page = browser.new_page(viewport={"width": WEB[0], "height": WEB[1]})
            page.goto(url)
            settle(page)
            page.get_by_role("button", name="Create table", exact=True).click()
            settle(page)
            page.locator("[data-tag='toolbar'] >> text=Chart").first.click()
            settle(page)
            chart = page.locator(".board > .object[data-tag='chart0']").bounding_box()
            table = page.locator(".board > .object[data-tag='table']").bounding_box()
            page.mouse.move(chart["x"] + chart["width"] - 4, chart["y"] + chart["height"] - 4)  # the chart's corner: as wide as the table
            page.mouse.down()
            page.mouse.move(table["x"] + table["width"] - 4, chart["y"] + chart["height"] - 4, steps=12)
            page.mouse.up()
            settle(page)
            page.mouse.move(900, 300)
            page.wait_for_timeout(800)
            frames = []  # (jpeg bytes, seconds): one each time the page repaints
            cdp = page.context.new_cdp_session(page)

            def frame(f):
                import base64
                frames.append((base64.b64decode(f["data"]), f["metadata"]["timestamp"]))
                cdp.send("Page.screencastFrameAck", {"sessionId": f["sessionId"]})
            cdp.on("Page.screencastFrame", frame)
            cdp.send("Page.startScreencast", {"format": "jpeg", "quality": 90, "maxWidth": WEB[0], "maxHeight": WEB[1]})
            page.wait_for_timeout(1200)
            page.locator("[data-tag='ask']").click()
            page.keyboard.type("by product, largest first, top 5", delay=40)
            page.keyboard.press("Enter")
            settle(page)
            page.wait_for_timeout(1500)
            page.locator("[data-tag='word-0-0']").click()  # the sentence's "Sum": its choices
            settle(page)
            page.wait_for_timeout(1200)
            page.locator(".popover >> text=Average").first.click()
            settle(page)
            page.wait_for_timeout(1500)
            page.locator("[data-tag='word-0-6']").click()  # "bars": a line
            settle(page)
            page.wait_for_timeout(900)
            page.locator(".popover >> text=a line").first.click()
            settle(page)
            page.wait_for_timeout(1800)
            page.screenshot(path=str(OUT / "sentence-web.png"))
            cdp.send("Page.stopScreencast")
            browser.close()
        to_video(frames, OUT / "sentence-web.mp4")
        print(f"web: {OUT / 'sentence-web.mp4'} ({len(frames)} frames)")
    finally:
        server.terminate()


def to_video(frames, path):
    """Screencast frames (sent only on a repaint) into a 30 fps video: each frame lasts until the next one."""
    work = OUT / "frames"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir()
    lines = []
    for k, (data, at) in enumerate(frames):
        (work / f"{k:05d}.jpg").write_bytes(data)
        lines.append(f"file '{k:05d}.jpg'")
        lines.append(f"duration {max(frames[k + 1][1] - at, 1 / 30) if k + 1 < len(frames) else 1.0:.4f}")
    lines.append(f"file '{len(frames) - 1:05d}.jpg'")  # (the concat demuxer's last frame needs naming twice)
    (work / "list.txt").write_text("\n".join(lines) + "\n")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(work / "list.txt"), "-vf", "fps=30,format=yuv420p",
                    "-c:v", "libx264", "-crf", "20", "-preset", "veryfast", str(path)], check=True)
    shutil.rmtree(work)


G47 = ROOT / "build/g47"
STEP = 103.0  # board points one wheel notch scrolls at 1920×1200 (GTK: the viewport's height to the power 2/3)


def robots(media=None, keep_raw=False):
    """Goal 47's clip and shots: "Why did the robot drop it?" in omxplorer (Liquid dark), the GTK window on the private
    headless display at 1920×1200 (scaled to 1440×900, as goal 41's claim clip), driven only through agent tools
    (scenario.py robots's steps and SQL). Writes build/g47/shots/NN-*.png (one per beat) and docs/img/clip-robots.mp4
    (+ .jpg): the moments a viewer follows, jump cuts between them, nothing sped up."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import csv
    import json
    import covers
    import scenario
    media = Path(media or G47 / "full").resolve()
    shots = G47 / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    docs = G47 / "clip-docs"
    shutil.rmtree(docs, ignore_errors=True)
    (docs / "config").mkdir(parents=True)
    (docs / "config" / "settings.txt").write_text("inspector=no\n")
    truth = json.loads((media / "truth.json").read_text())
    rows = list(csv.DictReader(open(media / "fleet.csv")))
    hero_row = [r["episode"] for r in rows].index(truth["hero"]) + 1
    r = covers.Rec(covers.copy_app("omxplorer", G47), {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(docs / "config"), "MOJOUI_BUDGET_MS": "50"},
                   G47 / "clip-robots.mp4", size=(1920, 1200))
    keep = []

    def now():
        return time.time() - r.t0

    def shot(name):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0", "-video_size", "1920x1200", "-i",
                        os.environ["DISPLAY"] + "+0,0", "-frames:v", "1", "-vf", "scale=1440:900:flags=lanczos", str(shots / name)], check=True)
        print("shot", shots / name, flush=True)

    def hold(secs, name=None):
        """Keep the next `secs` seconds of the recording (and a shot at their end)."""
        t = now()
        time.sleep(secs)
        if name:
            shot(name)
        keep.append((t, now()))

    def until(tool, timeout=300):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in r.tools():
                return
            time.sleep(0.2)
        r.close()
        raise SystemExit(f"{tool} never appeared")

    def show(card, above=12):
        """Scroll the board so `card` (by its name) starts near the top: up to the top, then down whole wheel notches
        (GTK's step for this viewport, measured: STEP points a notch)."""
        c = covers.cards(r)
        if card not in c:
            print(f"(no card {card}: {sorted(c)})", flush=True)
            return
        r.wheel(1895, 700, -40, pause=0.3)
        notches = max(0, round((c[card][1] - above) / STEP))
        if notches:
            r.wheel(1895, 700, notches, pause=0.5)

    def ask_field(before):
        return [n for n in r.tools() if n.startswith("ask") and n not in before][0]

    try:
        r.record()
        time.sleep(0.5)
        r.call("open-file", 0.0, path=str(media / "fleet.csv"))
        until("create-table")
        hold(1.2)  # the import step: 63,344 episodes read
        r.call("create-table", 0.0)
        until("chart")
        hold(2.2, "01-fleet.png")  # the fleet: one row per episode, 13 labs
        r.call("chart", 0.0)
        r.call("ask", 0.0, text=scenario.ROBOT_CHART, submit=True)
        hold(2.6, "02-success-by-lab.png")  # success by lab
        before = set(r.tools())
        r.call("pivot", 0.6)
        drops = [t["name"] for t in r.c.tools() if t["name"] not in before and t.get("description", "").startswith("Dropdown")]
        for name, option in zip(drops[:3], ("n", "lab", "outcome")):
            r.call(name, 0.3, option=option)
        hold(2.4, "03-pivot-lab-outcome.png")  # episodes by lab × outcome
        r.call("insert-table", 0.2)
        r.call("choose-table", 0.0, path=str(media / "telemetry.parquet"))
        until("table-telemetry")
        hold(1.8, "04-telemetry-17m.png")  # 16.8M telemetry rows land beside the fleet
        r.call("links", 0.3)
        t = now()
        for l in scenario.ROBOT_LINKS:
            r.call("link", 0.5, text=l, submit=True)
        keep.append((t, now()))
        hold(1.0, "05-links.png")  # the four links, typed: nothing joins until they exist
        for _ in range(3):  # (the inspector closes: the board gets the window's width)
            if "Inspector (Ctrl+Shift+I) ✓" not in r.c.call("screen")[0]:
                break
            r.call("view-inspector", 0.3)
        r.call("grid", 0.0, value=float(hero_row))
        until("telemetry-chart")
        time.sleep(0.8)
        show("episode")
        if "pause" in r.tools():  # (it starts playing when it opens)
            r.call("pause", 0.0)
        r.call("seek", 0.2, value=8.0)
        r.call("play", 0.0)
        hold(6.4)  # the featured failure plays: the shirt carried over the box, then it falls onto the box's outside wall
        if "pause" in r.tools():
            r.call("pause", 0.0)
        r.call("seek", 0.0, value=12.7)
        hold(1.4, "06-drop-falling.png")  # the shirt in the air, just let go (the lanes' cursor at 0:12.7)
        r.call("seek", 0.0, value=13.4)
        hold(1.4, "07-drop-fallen.png")  # the gripper open, the shirt hanging on the outside of the box
        r.call("insert-documents", 0.0, path=str(media / "paper"))
        until("fields")
        r.call("reader", 0.0, option="PDF text")
        r.call("fields", 0.0, text=scenario.ROBOT_FIELDS)
        r.call("read-documents", 0.0)
        until("highlight-field", 120)
        r.call("highlight-field", 0.0, option="recorded at")
        r.call("doc-fit", 0.1)  # (the whole page, centred: the marked line in view)
        r.call("grid", 0.2, value=float(hero_row + 1))
        r.call("grid", 0.0, value=float(hero_row))
        show("paper")
        hold(2.4, "08-paper-15hz.png")  # the paper (CC-BY), linked by its source: "recorded at 15Hz" marked
        for q, sql, name, label in ((scenario.ROBOT_Q1, scenario.ROBOT_SQL1, "regrasped", "09-ask-regrasped.png"),
                                     (scenario.ROBOT_Q2, scenario.ROBOT_SQL2, "fastest", "10-ask-speed-limit.png")):
            before = set(r.tools())
            r.call("query", 0.3)
            t = now()
            r.call(ask_field(before), 0.8, text=q)
            r.call("sql", 0.6, text=sql)
            r.call("query-name", 0.0, text=name)
            keep.append((t, now()))
            r.call("run-query", 0.0)
            until(f"table-{name}", 300)
            time.sleep(0.4)
            show(name)
            hold(2.6, label)
        before = set(r.tools())
        r.call("query", 0.0)
        r.call(ask_field(before), 0.0, text="the failures I picked")
        r.call("sql", 0.0, text=scenario.ROBOT_SQL3)
        r.call("query-name", 0.0, text="picked")
        r.call("run-query", 0.0)
        until("table-picked", 120)
        time.sleep(0.4)
        show("picked")
        r.call("table-picked", 0.3, value=1.0)
        pack = [t["name"] for t in r.c.tools() if t["name"].startswith("export-pack") and "picked" in t.get("description", "")]
        r.call(pack[0] if pack else "export-pack", 0.0)
        hold(2.8, "11-pack.png")  # Export pack: a PDF per picked failure (its frame, its telemetry, the paper's page)
    finally:
        r.close()
    raw = r.raw
    total = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(raw)],
                                 capture_output=True, text=True).stdout.strip() or 0)
    keep.sort()
    merged = []
    for a, b in keep:
        if merged and a <= merged[-1][1] + 0.05:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    drop, at = [], 0.0
    for a, b in merged:
        if a > at:
            drop.append((at, a))
        at = b
    if at < total:
        drop.append((at, total + 1))
    out = ROOT / "docs/img/clip-robots.mp4"
    kept = sum(b - a for a, b in merged)
    if keep_raw:
        shutil.copyfile(raw, G47 / "clip-robots.full.mp4")
    covers.finish(raw, out, poster_at=min(kept - 0.5, sum(b - a for a, b in merged[:7]) - 1.0), drop=drop, scale=(1440, 900))
    print(f"clip: {out} ({kept:.1f} s kept of {total:.1f} s)")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("native", "all"):
        native()
    if what in ("web", "all"):
        web()
    if what == "island":
        island()
    if what == "robots":
        args = [a for a in sys.argv[2:] if not a.startswith("--")]
        robots(args[0] if args else None, keep_raw="--raw" in sys.argv)
