"""Goal 78 M3: video and audio you can see (docs/goals/78.md). `check() -> (ok, why)`.

1. the unit test of the cell styling decision (mojoui.datagrid.play_kind: a video path ▶, an audio path ♪, an empty cell plain,
   a column that plays nowhere plain) and of the Links error ("=" with an offset says an offset needs "~");
2. omxplorer on GTK with a small table (build/g78/m3/plays.csv: DROID clips by full path, an empty cell, an audio path): the
   link `plays.clip = video.file` typed in the Links panel; the pointer on a clip cell shows a pointer and the link underlined
   (the grid's own HOVER), on an empty clip cell or another column it doesn't; the clip header's tooltip says it plays in
   video; clicking a clip cell plays it (a video card opens with that file); "plays.t = video.t +1.2" is refused with the
   offset's reason; shots of the styled column, hovered;
3. the web host: the same link through the page's Links panel, the column drawn (a shot), the pointer's cursor read from the
   page, a real click on a clip cell opening the video card.
"""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("g78common", HERE / "common.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

LINK = "plays.clip = video.file"


def table():
    d = c.OUT / "m3"
    d.mkdir(parents=True, exist_ok=True)
    clips = c.DATA / "clips"
    rows = [("F00118", str(clips / "F00118.mp4"), "success"), ("F00119", "", "failure"), ("F00120", str(d / "voice-note.wav"), "success"),
            ("F00121", str(clips / "F00121.mp4"), "failure")]
    p = d / "plays.csv"
    p.write_text("episode,clip,outcome\n" + "".join(f"{a},{b},{o}\n" for a, b, o in rows))
    return p


def units():
    ok, out, missing = c.mojo_test("tests/test_playcells.mojo", ["kind", "tip", "offset"])
    return (True, "test_playcells 3 ok") if ok else (False, f"test_playcells: missing {missing}: {out[-600:]}")


def gtk(p):
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", f"shot:{c.OUT}/m3-gtk-0-plain.png",
             "tap:Links", "pause:500", f"type:link={LINK}", f"submit:link", "pause:800", "tap:panel-close", "pause:600",
             f"shot:{c.OUT}/m3-gtk-1-video-column.png",
             "hoverspot:grid=clip@1", "pause:300", f"shot:{c.OUT}/m3-gtk-2-hover-link.png",
             "hoverspot:grid=clip@2", "pause:200", "hoverspot:grid=outcome@1", "pause:200", "hoverspot:grid=clip@3", "pause:200",
             "hoverspot:grid=clip", "pause:200",
             "tapspot:grid=clip@1", "pause:2500", "boards:played", f"shot:{c.OUT}/m3-gtk-3-played.png",
             "tap:Links", "pause:500", "type:link=plays.t = video.t +1.2", "submit:link", "pause:600", f"shot:{c.OUT}/m3-gtk-4-offset-error.png"]
    out = c.gtk(steps, "m3-gtk", open_path=p)
    hov = {}
    for line in out.splitlines():
        if line.startswith("HOVER: "):
            head, tip = line.split(" | tip=", 1)
            parts = head.split()
            hov[parts[2]] = (parts[3][len("cursor="):] if len(parts) > 3 else "", tip)
    probs = []
    if f"LINK: {LINK} (typed)" not in out:
        probs.append(f"the link {LINK} wasn't made: {[l for l in out.splitlines() if l.startswith('LINK')][-3:]}")
    want = {"clip@1": "pointer", "clip@2": "", "outcome@1": "", "clip@3": "pointer"}
    for spot, cur in want.items():
        if hov.get(spot, ("?",))[0] != cur:
            probs.append(f"the pointer on {spot}: cursor {hov.get(spot, ('none',))[0]!r} (want {cur!r})")
    if "plays in video" not in hov.get("clip", ("", ""))[1]:
        probs.append(f"the clip header's tooltip: {hov.get('clip')}")
    if "OPEN: video F00118.mp4" not in out:
        probs.append("clicking clip@1 didn't play F00118.mp4 in the video card")
    if "video0" not in c.boards(out).get("played", {}).get("cards", {}):
        probs.append(f"no video card after the click: {c.boards(out).get('played', {}).get('cards')}")
    prob = [l for l in out.splitlines() if l.startswith("LINKS: problem")]
    if not prob or 'an offset needs "~" (a time link)' not in prob[-1]:
        probs.append(f"'plays.t = video.t +1.2' said {prob[-1:]} (want: an offset needs \"~\")")
    if probs:
        return False, "GTK: " + "; ".join(probs)[:1200]
    return True, ("GTK: plays.clip = video.file draws clip's cells as links; the pointer on one: pointer cursor, underlined; empty cell and "
                  f"other column: plain; header tooltip {hov['clip'][1]!r}; a click played F00118.mp4 in a video card; the offset error: {prob[-1][len('LINKS: problem '):]!r}")


def web(p):
    import drive
    h = c.home("m3-web")
    env = {"OMX_DOCUMENTS": str(h / "docs"), "OMX_CONFIG": str(h / "config"), "OMX_OPEN": str(p)}
    seen = {}

    def during(page):
        # (Links opened from the ribbon by the steps; the link typed in its field)
        field = page.locator("input[data-tag=link], [data-tag=link] input").first
        field.fill(LINK)
        field.press("Enter")
        page.wait_for_timeout(900)
        page.locator("[data-tag=panel-close]").first.click()
        page.wait_for_timeout(900)
        page.screenshot(path=str(c.OUT / "m3-web-1-video-column.png"))
        g = page.locator("[data-tag=grid] canvas").first
        box = g.bounding_box()
        spot = page.evaluate("() => null")
        # where clip@1 is: the grid's own spot (header_spot "clip@1"), asked through the agent-free way: the page has no
        # App.spot, so read the cell from the grid's geometry: the gutter, then each column's width as drawn
        seen["box"] = box
        # (the clip column is the second: the gutter is 64, the episode column ~110 wide; a hand points into the cell's text)
        for top in (30, 52):  # (the header: 30, or 52 with each column's distribution under its name)
            for x in range(int(box["x"] + 150), int(box["x"] + 420), 18):
                page.mouse.move(x, box["y"] + top + 13)
                page.wait_for_timeout(250)
                if g.evaluate("e => getComputedStyle(e).cursor") == "pointer":
                    spot = (x, box["y"] + top + 13)
                    break
            if spot:
                break
        seen["spot"] = spot
        if spot:
            page.wait_for_timeout(300)
            page.screenshot(path=str(c.OUT / "m3-web-2-hover-link.png"))
            page.mouse.move(spot[0], spot[1] + 26)  # (the empty cell under it)
            page.wait_for_timeout(500)
            seen["empty"] = g.evaluate("e => getComputedStyle(e).cursor")
            page.mouse.click(spot[0], spot[1])
            page.wait_for_timeout(3000)
            seen["cards"] = page.evaluate(c.CARDS_JS)["cards"]
            page.screenshot(path=str(c.OUT / "m3-web-3-played.png"))
        return "WEB: done\n"

    steps = ";".join(["wait:Create table", "tap:Create table", "wait:Links", "pause:800", "tap:Insert", "pause:300", "tap:Links", "pause:800"])
    r, out = drive.web_run(c.WEB, steps, viewport=(c.W, c.H), color_scheme="light", env=env, during=during)
    (c.OUT / "m3-web.log").write_text(out)
    if r.returncode != 0:
        return False, f"web run: exit {r.returncode}: {out[-800:]}"
    probs = []
    if not seen.get("spot"):
        probs.append("no cell of the clip column shows a pointer under the mouse")
    elif seen.get("empty") == "pointer":
        probs.append("the empty clip cell shows a pointer too")
    if seen.get("spot") and "video0" not in seen.get("cards", {}):
        probs.append(f"a click on the clip cell opened no video card: {list(seen.get('cards', {}))}")
    if probs:
        return False, "web: " + "; ".join(probs)
    return True, "web: the clip column's cells point (the empty one doesn't), a real click opened the video card"


def check():
    if not (c.DATA / "clips/F00118.mp4").exists():
        return None, f"no DROID clips in {c.DATA}"
    c.OUT.mkdir(parents=True, exist_ok=True)
    p = table()
    parts = []
    ok, why = units()
    if not ok:
        return False, why
    parts.append(why)
    c.build(("omxplorer", "linux"))
    ok, why = gtk(p)
    if not ok:
        return False, why
    parts.append(why)
    c.build(("omxplorer", "web"))
    ok, why = web(p)
    if not ok:
        return False, why
    parts.append(why)
    return True, "; ".join(parts) + f"; shots {c.OUT}/m3-*.png"
