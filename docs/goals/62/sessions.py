"""M3's checks: visitors' sessions end. Plain GETs make no app session, a real tab makes one; an idle tab closes, says so
and its files go; past the cap a new visitor gets a busy page; Export pack arrives as one download and leaves nothing on
the server. The session count is the server's own (GET /health: JSON with "sessions")."""

import json
import re
import time
from pathlib import Path

from harness import Server, settle, try_settle, PROBE, Net, chromium, get


def sessions(srv):
    st, _, body = get(srv.url + "health")
    try:
        return json.loads(body)["sessions"] if st == 200 else None
    except (ValueError, KeyError):
        return None


def files_under(folder, exts=(".pdf", ".mp4", ".zip", ".csv", ".omx")):
    return sorted(str(p.relative_to(folder)) for p in Path(folder).rglob("*") if p.is_file() and p.suffix in exts)


def run_all(out):
    out = Path(out)
    lines = []

    def say(ok, what):
        lines.append(("PASS " if ok else "FAIL ") + what)
        print(lines[-1], flush=True)

    from playwright.sync_api import sync_playwright
    # ---- plain GETs, a real tab, an idle tab
    srv = Server(out / "idle", public=True, env={"MOJOUI_IDLE_S": "6"})
    try:
        n0 = sessions(srv)
        codes = {}
        for _ in range(500):
            st, _, _ = get(srv.url)
            codes[st] = codes.get(st, 0) + 1
        n1 = sessions(srv)
        say(n0 == 0 and n1 == 0, f"500 plain GET / ({codes}): sessions {n0} → {n1}")
        with sync_playwright() as p:
            b = chromium(p)
            page = b.new_context(viewport={"width": 1440, "height": 900}).new_page()
            page.add_init_script(PROBE)
            page.goto(srv.url)
            settle(page)
            n2 = sessions(srv)
            say(n2 == 1, f"a real tab makes one session: {n2}")
            sid = page.evaluate("() => document.getElementById('mojoui-root').dataset.sid")
            f = out / "mine.csv"
            f.write_text("a,b\n1,2\n3,4\n")
            page.locator("input[type=file]").first.set_input_files(str(f))
            try_settle(page)
            folder = srv.uploads / sid
            had = folder.exists() and any(folder.rglob("mine.csv"))
            t0 = time.time()
            ended = None
            while time.time() - t0 < 30:
                if re.search(r"session ended|ended after", page.inner_text("body"), re.I):
                    ended = time.time() - t0
                    break
                page.wait_for_timeout(250)
            page.screenshot(path=str(out / "idle-ended.png"))
            n3 = sessions(srv)
            gone = not folder.exists()
            say(had and ended is not None and n3 == 0 and gone,
                f"a tab idle past 6 s: {'says it ended after %.1f s' % ended if ended is not None else 'never says so'}; sessions {n3}; "
                f"its upload {'was there and is gone' if had and gone else ('was never there' if not had else 'is still there')}")
            b.close()
    finally:
        srv.stop()
    # ---- the cap
    srv = Server(out / "cap", public=True, env={"MOJOUI_MAX_SESSIONS": "2"})
    try:
        with sync_playwright() as p:
            b = chromium(p)
            pages = []
            for k in range(2):
                pg = b.new_context(viewport={"width": 1440, "height": 900}).new_page()
                pg.goto(srv.url)
                settle(pg)
                pages.append(pg)
            third = b.new_context(viewport={"width": 1440, "height": 900}).new_page()
            resp = third.goto(srv.url)
            third.wait_for_timeout(1500)
            text = third.inner_text("body")
            third.screenshot(path=str(out / "cap-busy.png"))
            n = sessions(srv)
            say(resp.status == 200 and re.search(r"busy|full", text, re.I) is not None and n == 2 and "Internal Server Error" not in text,
                f"past the cap (2): the third visitor gets {resp.status}, {'a busy page' if re.search(r'busy|full', text, re.I) else repr(text[:80])}; sessions {n}")
            b.close()
    finally:
        srv.stop()
    # ---- Export pack: one download, nothing left on the server
    srv = Server(out / "pack", public=True)
    try:
        with sync_playwright() as p:
            b = chromium(p)
            page = b.new_context(viewport={"width": 1440, "height": 900}, accept_downloads=True).new_page()
            page.add_init_script(PROBE)
            page.goto(srv.url)
            settle(page)
            import story as S
            v = S.Visitor(page, out / "pack-visitor", Net(page))
            v.start()
            v.question(3, "picked", r"\b3 rows", "3 rows")
            ok = v.pack("picked")
            page.wait_for_timeout(2000)
            left = files_under(srv.out)
            pk = v.R.get("pack", {})
            say(ok and not left, f"Export pack: one download ({pk.get('file')}, {len(pk.get('entries', []))} files, {pk.get('bytes', 0) // 1024} KB); "
                f"left on the server: {left[:6] if left else 'nothing'}")
            b.close()
    finally:
        srv.stop()
    return not any(l.startswith("FAIL") for l in lines), lines
