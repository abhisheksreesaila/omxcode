"""M7's checks: a visitor can't stall or crash the server for the others. While visitor B plays the story in its own
process, visitor A asks a question past the time budget (MOJOUI_QUERY_S shortened to 1 s), one past the row cap (MOJOUI_QUERY_ROWS
shortened to 100,000) and one
past the join budget, and uploads malformed CSV, Parquet and MP4 files; each must end in plain words with the server up,
and every one of B's beats must pass. Then D-6218's suspected sequences, with real clicks."""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from harness import Server, settle, try_settle, PROBE, Net, chromium, get, ROOT, STARTER

QUESTIONS = [  # (SQL, the words that must come back, what it tests)
    ("SELECT episode, t, speed, gripper, COUNT(*) AS n FROM telemetry GROUP BY episode, t, speed, gripper ORDER BY n DESC",
     r"ran past the web copy's 1 s", "time"),
    ("SELECT * FROM telemetry", r"more than 100,000 rows", "rows"),
    ("SELECT COUNT(*) AS n FROM telemetry a JOIN telemetry b ON a.episode = b.episode", r"more memory than the web copy gives|ran past", "join"),
]


def malformed(out):
    """Files that look right by name and aren't: random bytes, a truncated real file, a valid header over garbage."""
    out.mkdir(parents=True, exist_ok=True)
    real_pq, real_mp4 = STARTER / "telemetry.parquet", STARTER / "clips/F00118.mp4"
    files = {
        "noise.csv": os.urandom(200_000),
        "noise.parquet": b"PAR1" + os.urandom(100_000) + b"PAR1",
        "truncated.parquet": open(real_pq, "rb").read(300_000),
        "footer-lies.parquet": b"PAR1" + os.urandom(1000) + (2 ** 31 - 1).to_bytes(4, "little") + b"PAR1",
        "noise.mp4": b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom" + os.urandom(100_000),
        "truncated.mp4": open(real_mp4, "rb").read(20_000),
    }
    for name, data in files.items():
        (out / name).write_bytes(data)
    return [out / n for n in files]


def run_all(out):
    out = Path(out)
    lines = []

    def say(ok, what):
        lines.append(("PASS " if ok else "FAIL ") + what)
        print(lines[-1], flush=True)

    srv = Server(out / "srv", public=True, env={"MOJOUI_QUERY_S": "1", "MOJOUI_QUERY_ROWS": "100000", "MOJOUI_MAX_SESSIONS": "20"})  # (budgets shortened for the check)
    try:
        b_out = out / "visitor-b"
        pb = subprocess.Popen([sys.executable, str(ROOT / "docs/goals/62/story.py"), "--url", srv.url, "--out", str(b_out), "--no-pack"],
                              cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        from playwright.sync_api import sync_playwright
        import story as S
        with sync_playwright() as p:
            b = chromium(p)
            page = b.new_context(viewport={"width": 1440, "height": 900}).new_page()
            page.add_init_script(PROBE)
            page.goto(srv.url)
            settle(page)
            S.Visitor(page, out / "visitor-a", Net(page)).start()
            for sql, words, what in QUESTIONS:
                page.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Query\s*$")).first.click()
                try_settle(page)
                page.locator("[data-kind=dialog] textarea, dialog textarea").last.fill(sql)
                t0 = time.time()
                page.locator("[data-kind=dialog] button, dialog button").filter(has_text=re.compile(r"^\s*Run")).last.click()
                said = None
                while time.time() - t0 < 60:
                    body = page.inner_text("body")
                    m = re.search(words, body)
                    if m:
                        said = body[max(0, m.start() - 60):m.end() + 40].replace("\n", " ")
                        break
                    page.wait_for_timeout(250)
                alive = srv.p.poll() is None and get(srv.url + "health")[0] == 200
                say(said is not None and alive, f"a question past the {what} budget: " + (f"stopped in {time.time() - t0:.1f} s, saying “…{said}…”" if said else "no plain words in 60 s")
                    + ("" if alive else "; the server is down"))
                page.keyboard.press("Escape")
                try_settle(page)
            for f in malformed(out / "files"):
                page.goto(srv.url)
                settle(page)
                page.locator("input[data-kind=picker]").first.set_input_files(str(f))
                said, t0 = None, time.time()
                while time.time() - t0 < 60:
                    body = page.inner_text("body")
                    m = re.search(r"wasn't opened: [^.]*\.|Couldn't open[^\n]*|isn't a table[^\n]*", body)
                    if m:
                        said = m.group(0)
                        break
                    page.wait_for_timeout(250)
                alive = srv.p.poll() is None and get(srv.url + "health")[0] == 200
                leak = said and ("/" in said.replace(f.name, ""))
                say(alive and said is not None and not leak, f"a malformed upload, {f.name}: " + (f"“{said}”" if said else "no plain words") + ("" if alive else "; the server died"))
            # D-6218's suspected sequences, with real clicks: a pivot, or the cursor on the last column, then another table
            page.goto(srv.url)
            settle(page)
            v = S.Visitor(page, out / "visitor-a2", Net(page))
            v.start()
            v.pivot()
            grid = page.locator("[data-kind=canvas][data-tag=grid]").first
            box = grid.bounding_box()
            page.mouse.click(box["x"] + box["width"] - 30, box["y"] + 60)
            for _ in range(30):
                page.keyboard.press("Tab")
            for label in ("File", "Open…"):
                page.locator("button", has_text=re.compile(rf"^\s*{label}")).first.click()
                page.wait_for_timeout(300)
            page.locator("button", has_text=re.compile("Open the sample")).first.click()
            page.wait_for_timeout(3000)
            for label in ("File", "New blank sheet"):
                page.locator("button", has_text=re.compile(rf"^\s*{label}")).first.click()
                page.wait_for_timeout(300)
            page.wait_for_timeout(2000)
            alive = srv.p.poll() is None and get(srv.url + "health")[0] == 200
            say(alive, "D-6218's sequences (a pivot and the last column, then the sample, then a blank sheet): " + ("the server is up" if alive else "the server died"))
            b.close()
        text, _ = pb.communicate(timeout=900)
        (out / "visitor-b.log").write_text(text or "")
        try:
            R = json.loads((b_out / "results.json").read_text())
        except (OSError, ValueError):
            R = {"beats": {}}
        bad = [f"{k}: {x['note'][:100]}" for k, x in R.get("beats", {}).items() if not x["ok"]]
        say(bool(R.get("beats")) and not bad, "visitor B played the story meanwhile: " + ("every beat" if not bad and R.get("beats") else "; ".join(bad) or "no result"))
    finally:
        srv.stop()
    return not any(l.startswith("FAIL") for l in lines), lines
