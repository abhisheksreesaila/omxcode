"""Goal 47's robot story played the way a visitor plays it: only clicks, selects and key presses in a real page (headless
Chromium), no agent link, no upload. One visitor per process, so M5 can run N at once.

    pixi run python docs/goals/62/story.py --url http://127.0.0.1:PORT/ --out build/g62/visitor-1 [--viewport 1440x900]
        [--no-pack] [--no-video] [--server-pid PID] [--mem-file F]

Beats: start (one click on the Start screen: the fleet linked to its telemetry, clips and paper, F00118 on screen),
pivot (n by lab × outcome, chosen in the inspector), video (F00118 plays: distinct pictures a second, bytes per new
picture), question 1 (regrasps: 2,997 rows) and question 2 (the 4 fastest), each one click on Run (click → rows shown),
pack (question 3, the three picked failures, then Export pack: it arrives as one download). Writes results.json in --out and prints one JSON line at the end."""

import argparse
import json
import re
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness import settle, try_settle, PROBE, OBJECTS, Net, chromium  # noqa: E402

TRUTH = {"fleet": "63,344", "telemetry": "16,847,616", "regrasps": "2,997", "fastest": "4 rows", "hero": "F00118"}

# Records when a Board card whose text matches re1 first shows up, and when its text first also matches re2.
WATCH = """([re1, re2]) => {
  const a = new RegExp(re1), b = new RegExp(re2); window.__watch = {appeared: null, filled: null, armed: false};
  const check = () => { if (!window.__watch.armed) return;  // (only what changes after the click counts)
    for (const o of document.querySelectorAll('[data-kind=object]')) { const t = o.textContent || '';
      if (a.test(t)) { if (window.__watch.appeared === null) window.__watch.appeared = performance.now();
                       if (b.test(t) && window.__watch.filled === null) window.__watch.filled = performance.now(); } } };
  document.addEventListener('click', () => { window.__watch.armed = true; }, {capture: true, once: true});
  new MutationObserver(check).observe(document.body, {childList: true, subtree: true, characterData: true});
}"""

# 8 s (by default) of one canvas: its pixels hashed every 15 ms (a 48x27 copy) → distinct pictures and changes a second.
SAMPLE = """async ([sel, ms]) => {
  const off = document.createElement('canvas'); off.width = 48; off.height = 27;
  const g = off.getContext('2d', {willReadFrequently: true}); let distinct = new Set(), last = '', changes = 0;
  const hash = () => { const v = document.querySelector(sel), cv = v && v.querySelector('canvas'); if (!cv || !cv.width) return '';
    g.drawImage(cv, 0, 0, 48, 27); const d = g.getImageData(0, 0, 48, 27).data; let h = 0;
    for (let i = 0; i < d.length; i += 4) h = (h * 31 + d[i] + d[i + 1] * 7 + d[i + 2] * 13) >>> 0; return String(h); };
  // (playing: from its first new picture, so the start-up after Play is its own number, startMs)
  const tc = performance.now(), first = hash();
  while (hash() === first && performance.now() - tc < 5000) await new Promise(r => setTimeout(r, 10));
  const t0 = performance.now(), startMs = +(t0 - tc).toFixed(0);
  const div0 = document.querySelector(sel), c0 = div0 && div0.mojoui ? div0.mojoui.count : 0;
  while (performance.now() - t0 < ms) {
    const v = document.querySelector(sel), cv = v && v.querySelector('canvas');
    if (cv && cv.width > 0) { g.drawImage(cv, 0, 0, 48, 27); const d = g.getImageData(0, 0, 48, 27).data; let h = 0;
      for (let i = 0; i < d.length; i += 4) h = (h * 31 + d[i] + d[i + 1] * 7 + d[i + 2] * 13) >>> 0;
      const k = String(h); if (k !== last) { changes++; last = k; } distinct.add(k); }
    await new Promise(r => setTimeout(r, 15));
  }
  const secs = (performance.now() - t0) / 1000, div1 = document.querySelector(sel);
  return {distinct: distinct.size, changes, changesPerSec: +(changes / secs).toFixed(1), secs: +secs.toFixed(2), startMs,
          drawsPerSec: +(((div1 && div1.mojoui ? div1.mojoui.count : 0) - c0) / secs).toFixed(1)};
}"""


class Visitor:
    def __init__(self, page, out, net):
        self.page, self.out, self.net = page, Path(out), net
        self.shots = self.out / "shots"
        self.shots.mkdir(parents=True, exist_ok=True)
        self.R = {"beats": {}, "timings": {}, "notes": []}

    def save(self):
        (self.out / "results.json").write_text(json.dumps(self.R, indent=1))

    def beat(self, name, ok, note="", shot=True):
        p = self.shots / f"{len(self.R['beats']):02d}-{re.sub('[^a-z0-9]+', '-', name.lower())}.png"
        if shot:
            try:
                self.page.screenshot(path=str(p))
            except Exception as e:
                note += f" (no screenshot: {e})"
        self.R["beats"][name] = {"ok": bool(ok), "note": str(note)[:400], "shot": str(p) if shot else ""}
        print(f"### BEAT {name}: {'OK' if ok else 'FAIL'} {str(note)[:200]}", flush=True)
        self.save()
        return ok

    def objects(self):
        return self.page.evaluate(OBJECTS)

    def wait_text(self, pattern, timeout=120):
        t0 = time.time()
        while time.time() - t0 < timeout:
            body = self.page.inner_text("body")
            if re.search(pattern, body):
                return time.time() - t0
            self.page.wait_for_timeout(200)
        return None

    # ---- the beats ----
    def start(self, timeout=180):
        page = self.page
        b = page.locator("button", has_text=re.compile(r"Start the robot story")).first
        b.wait_for(timeout=30000)
        t0 = time.perf_counter()
        b.click()
        took = None
        while time.perf_counter() - t0 < timeout:
            objs = " | ".join(self.objects())
            if (TRUTH["fleet"] in page.inner_text("body") and TRUTH["telemetry"] in objs and "video" in objs.lower() and "track" in objs.lower()
                    and "documents" in objs.lower() and page.locator("[data-tag=questions]").count()):
                took = time.perf_counter() - t0
                break
            page.wait_for_timeout(250)
        try_settle(page)
        objs = self.objects()
        self.R["timings"]["start_s"] = round(took, 2) if took else None
        self.R["start_objects"] = objs
        hero = [o for o in objs if o.startswith("video") and TRUTH["hero"] in o]  # (its clip: the fleet's row followed through the links)
        lanes = [o for o in objs if o.startswith("track") and "244 rows" in o]  # (its telemetry's slice: the key link)
        ok = took is not None and bool(hero) and bool(lanes)
        return self.beat("start", ok, f"{'%.1f s' % took if took else 'never'}; {len(objs)} cards: " + "; ".join(o[:60] for o in objs))

    def pivot(self):
        page = self.page
        page.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Pivot\s*$")).first.click()
        try_settle(page)
        runs = []
        for label, option in (("Value", "n"), ("Rows", "lab"), ("Columns", "outcome")):
            sel = f'select[aria-label="{label}"]'
            page.wait_for_selector(sel, timeout=20000)
            w0 = time.perf_counter()
            page.select_option(sel, label=option)
            try_settle(page)
            runs.append({"choice": f"{label}={option}", "wallMs": round((time.perf_counter() - w0) * 1000)})
        self.R["timings"]["pivot"] = runs
        piv = [o for o in self.objects() if o.startswith("pivot")]
        ok = bool(piv) and "lab" in piv[0] and "outcome" in piv[0] and "AUTOLab" in piv[0]
        return self.beat("pivot by lab", ok, piv[0] if piv else "no pivot card")

    def video(self, seconds=6.0):
        page = self.page
        vsel = "[data-kind=canvas][data-tag=video]"
        page.wait_for_selector(vsel, timeout=30000)
        card = page.locator("[data-kind=object][data-tag^=video]").first
        # (the story's opening plays the clip once, as following a row does: from the start again, as a person would:
        # pause it if it plays, tap the start of the seek bar, then Play)
        pause = card.locator("button", has_text=re.compile(r"^\s*pause\s*$", re.I))
        if pause.count():
            pause.first.click()
            try_settle(page)
        seek = card.locator("[data-kind=canvas][data-tag=seek]").first
        if seek.count():
            box = seek.bounding_box()
            page.mouse.click(box["x"] + 1, box["y"] + box["height"] / 2)
            try_settle(page)
        btn = card.locator("button", has_text=re.compile(r"^\s*play\s*$", re.I)).first
        t_click = time.perf_counter()
        btn.click()
        t0 = time.perf_counter()
        n0 = len(self.net.events)
        node0 = page.get_attribute(vsel, "data-node")
        fs0 = page.evaluate("() => JSON.parse(JSON.stringify(window.mojouiFrameStats || {}))")
        sample = page.evaluate(SAMPLE, [vsel, int(seconds * 1000)])
        fs1 = page.evaluate("() => JSON.parse(JSON.stringify(window.mojouiFrameStats || {}))")
        frames = [e for e in self.net.events[n0:] if e[1] == "response" and "/frame/" in e[2]]
        node = page.get_attribute(vsel, "data-node")
        vframes = [e for e in frames if f"/frame/" in e[2] and f"/{node}?" in e[2]]
        vbytes = sum(e[3] for e in vframes)  # (every answer for the video canvas: pictures, and "same" answers' headers)
        pictures = [e for e in vframes if e[4] == 200]
        per = (sum(e[3] for e in pictures) / len(pictures)) if pictures else 0
        # batched answers (POST /frames: every playing canvas's pictures in one): the page counts each canvas's share; the
        # batches' own HTTP bytes are shared out by those shares
        d = lambda k: {f: fs1.get(k, {}).get(f, 0) - fs0.get(k, {}).get(f, 0) for f in ("answers", "bytes", "pictures", "pictureBytes")}
        mine, every = d(node0), {f: sum(d(k)[f] for k in fs1) for f in ("answers", "bytes", "pictures", "pictureBytes")}
        batches = [e for e in self.net.events[n0:] if e[1] == "response" and "/frames/" in e[2]]
        if mine["answers"]:
            overhead = max(0, sum(e[3] for e in batches) - every["bytes"])
            vbytes += mine["bytes"] + overhead * (mine["bytes"] / every["bytes"] if every["bytes"] else 0)
            per = mine["pictureBytes"] / mine["pictures"] if mine["pictures"] else per
            pictures = pictures + [None] * mine["pictures"]
            vframes = vframes + [None] * mine["answers"]
        new_bytes = per * sample["distinct"]  # (each distinct picture shown once, at the average size of one picture)
        ratio = (vbytes / new_bytes) if new_bytes else None
        sample.update({"frameAnswers": len(vframes), "pictureAnswers": len(pictures), "videoBytes": vbytes, "allFrameBytes": sum(e[3] for e in frames),
                       "bytesPerNewPictureRatio": round(ratio, 2) if ratio else None, "secsSinceClick": round(t0 - t_click, 2)})
        self.R["timings"]["video"] = sample
        try:
            card.locator("button", has_text=re.compile(r"^\s*pause\s*$", re.I)).first.click(timeout=3000)
        except Exception:
            pass
        try_settle(page)
        ok = sample["changesPerSec"] >= 12
        return self.beat("F00118 plays", ok, f"{sample['changesPerSec']} pictures/s ({sample['distinct']} distinct in {sample['secs']} s), "
                         f"{len(vframes)} frame answers, {vbytes / 1024:.0f} KB, {sample['bytesPerNewPictureRatio']}× the new pictures' bytes")

    def question(self, k, name, rows_re, expect):
        page = self.page
        if not page.locator("[data-tag=questions]").count():  # (the inspector turned to a pivot: back to the story, as a visitor would)
            page.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Story\s*$")).first.click()
            try_settle(page)
        run = page.locator(f"[data-tag=questions] button[data-tag=run-question-{k}]").first
        run.wait_for(timeout=30000)
        page.evaluate(WATCH, [rf"\b{name}\b", rows_re])
        w0 = time.perf_counter()
        run.click()
        page.wait_for_function("() => window.__watch.filled !== null", timeout=300000)
        wall = time.perf_counter() - w0
        w = page.evaluate("() => window.__watch")
        t0c = page.evaluate("() => window.__probe.clicks[window.__probe.clicks.length - 1]")  # (the click itself, in the page)
        try_settle(page)
        ms = round(w["filled"] - t0c, 1)
        t = {"clickToRowsMs": ms, "cardAppearedMs": round(w["appeared"] - t0c, 1) if w["appeared"] else None, "wallMs": round(wall * 1000)}
        self.R["timings"][f"question{k}"] = t
        card = [o for o in self.objects() if re.search(rf"\b{name}\b", o)]
        ok = bool(card) and expect in card[-1]
        return self.beat(f"question {k}: {name}", ok, f"click → rows {ms} ms; {card[-1] if card else 'no card'}")

    def sql_shown(self):
        text = " ".join(self.page.locator("[data-tag=questions]").all_inner_texts())
        ok = "SELECT" in text and "JOIN LINKED" in text and "failures where the gripper" in text
        self.R["questions_text"] = text[:2000]
        return self.beat("questions in words with their SQL", ok, text[:200], shot=False)

    def pack(self, name="picked"):
        page = self.page
        card = page.locator("[data-tag^=tablecard]:has(button[data-tag=export-pack])", has_text=re.compile(rf"\b{name}\b")).last
        btn = card.locator("button[data-tag=export-pack]").first
        with page.expect_download(timeout=300000) as dl:
            btn.click()
        d = dl.value
        path = self.out / (d.suggested_filename or "pack.zip")
        d.save_as(str(path))
        names = []
        try:
            with zipfile.ZipFile(path) as z:
                names = z.namelist()
        except zipfile.BadZipFile:
            pass
        try_settle(page)
        self.R["pack"] = {"file": path.name, "bytes": path.stat().st_size, "entries": names[:40]}
        pdfs = [n for n in names if n.endswith(".pdf")]
        clips = [n for n in names if n.endswith(".mp4")]
        return self.beat("Export pack downloads", bool(pdfs) and bool(clips), f"{path.name}: {len(pdfs)} PDFs, {len(clips)} clips, {path.stat().st_size // 1024} KB")


def play(page, out, net, pack=True, video=True):
    v = Visitor(page, out, net)
    try:
        if not v.start():
            return v.R
        v.sql_shown()
        v.pivot()
        if video:
            v.video()
        v.question(1, "regrasped", r"2,997", TRUTH["regrasps"])
        v.question(2, "fastest", r"\b4 rows", TRUTH["fastest"])
        if pack:
            v.question(3, "picked", r"\b3 rows", "3 rows")
            v.pack("picked")
    except Exception as e:
        v.beat("crashed", False, repr(e)[:400])
    return v.R


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--viewport", default="1440x900")
    ap.add_argument("--no-pack", action="store_true")
    ap.add_argument("--no-video", action="store_true")
    ap.add_argument("--hold", type=float, default=0, help="seconds to keep the tab open after the story (at rest)")
    args = ap.parse_args()
    w, h = map(int, args.viewport.split("x"))
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = chromium(p)
        ctx = b.new_context(viewport={"width": w, "height": h}, accept_downloads=True)
        page = ctx.new_page()
        page.add_init_script(PROBE)
        errors = []
        page.on("pageerror", lambda e: errors.append("pageerror: " + str(e)[:300]))
        page.on("console", lambda m: errors.append(f"console {m.type}: {m.text[:300]}") if m.type == "error" else None)
        net = Net(page)
        t0 = time.perf_counter()
        page.goto(args.url, wait_until="load")
        settle(page)
        R = play(page, out, net, pack=not args.no_pack, video=not args.no_video)
        R["first_load_s"] = round(time.perf_counter() - t0, 2)
        R["errors"] = errors[:20]
        R["ok"] = all(b_["ok"] for b_ in R["beats"].values()) and bool(R["beats"])
        if args.hold:
            time.sleep(args.hold)
        (out / "results.json").write_text(json.dumps(R, indent=1))
        print("RESULT " + json.dumps({"ok": R["ok"], "beats": {k: v["ok"] for k, v in R["beats"].items()}, "timings": R["timings"]}), flush=True)
        b.close()


if __name__ == "__main__":
    main()
