"""M2's probes: in public mode, crafted requests that name a server path, read one from the Script window and from SQL,
walk out of /static, /assets and /static/fonts, upload past the caps, or reach the agent link and /dev, are each refused
with nothing opened, written or listed; a second visitor sees nothing of the first; no response during the story holds a
server path.

"Nothing opened, written or listed" is watched by the kernel: inotify on the probe folder (outside every folder the
server may use) reports any open, read, list, create or write there while the probes run."""

import ctypes
import json
import os
import re
import struct
import time
import urllib.parse
from pathlib import Path

from harness import Server, settle, try_settle, PROBE, OBJECTS, Net, chromium, get, G47, ROOT

MARK = "G62-PROBE-SECRET-7f3a"
IN_ACCESS, IN_MODIFY, IN_CLOSE_WRITE, IN_OPEN, IN_MOVED_TO, IN_CREATE = 0x1, 0x2, 0x8, 0x20, 0x80, 0x100


class Watch:
    """inotify on one folder: every open, read, list, create or write in it, as (event mask, name)."""

    def __init__(self, folder):
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        mask = IN_ACCESS | IN_MODIFY | IN_CLOSE_WRITE | IN_OPEN | IN_MOVED_TO | IN_CREATE
        self.wd = self.libc.inotify_add_watch(self.fd, str(folder).encode(), mask)
        if self.fd < 0 or self.wd < 0:
            raise OSError(ctypes.get_errno(), "inotify")

    def events(self):
        out = []
        while True:
            try:
                buf = os.read(self.fd, 65536)
            except BlockingIOError:
                return out
            i = 0
            while i < len(buf):
                _, mask, _, n = struct.unpack_from("iIII", buf, i)
                name = buf[i + 16:i + 16 + n].rstrip(b"\0").decode(errors="replace")
                out.append((mask, name or "."))
                i += 16 + n


def scan_paths(text, roots):
    """The server paths (any of roots) in text."""
    return sorted({r for r in roots if r and r in text})


class Probe:
    def __init__(self, out):
        self.out = Path(out)
        self.lines = []
        self.dir = self.out.parent / "m2-probe"  # (outside the server's scratch folder: nothing there is the server's)
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "secret.csv").write_text(f"who,what\n{MARK},never uploaded\n")
        (self.dir / "secret.omx").write_text(MARK)
        self.watch = Watch(self.dir)

    def say(self, ok, what):
        self.lines.append(("PASS " if ok else "FAIL ") + what)
        print(self.lines[-1], flush=True)

    def touched(self):
        return [f"{hex(m)}:{n}" for m, n in self.watch.events()]

    def expect_untouched(self, what, responses=()):
        time.sleep(0.6)  # (a job's thread may open it a moment after the answer)
        t = self.touched()
        leaked = [r for r in responses if MARK in r]
        self.say(not t and not leaked, f"{what}: " + (f"probe folder touched {t[:4]}" if t else "") + (" the secret came back" if leaked else "") + ("" if t or leaked else "refused, nothing opened"))


def page_state(page):
    return page.evaluate("""() => ({sid: document.getElementById('mojoui-root').dataset.sid, v: document.getElementById('mojoui-v').value,
        nodes: [...new Set([...document.querySelectorAll('[hx-vals]')].map(e => { try { return JSON.parse(e.getAttribute('hx-vals')).n } catch (x) { return null } })
                .concat([...document.querySelectorAll('[data-node]')].map(e => Number(e.dataset.node)))
                .filter(n => typeof n === 'number'))]})""")


def post(url, fields, files=None):
    if files:
        import uuid
        b = uuid.uuid4().hex
        body = b""
        for k, v in fields.items():
            body += f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
        for name, data in files:
            body += f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode() + data + b"\r\n"
        body += f"--{b}--\r\n".encode()
        return get(url, body, {"Content-Type": f"multipart/form-data; boundary={b}", "HX-Request": "true"})
    return get(url, urllib.parse.urlencode(fields).encode(), {"Content-Type": "application/x-www-form-urlencoded", "HX-Request": "true"})


def crafted_routes(P, base, sid, v, nodes, paths, where):
    """Every route that takes text, each control on the screen, each probe path."""
    texts = []
    for n in nodes:
        for path in paths:
            for second in (0, 1, 2):
                _, _, body = post(f"{base}e/{sid}", {"n": n, "v": v, "second": second, "text": path, "number": 0})
                texts.append(body.decode(errors="replace"))
    P.expect_untouched(f"/e on {where}: {len(nodes)} controls × {len(paths)} paths × second 0/1/2", texts)
    texts = []
    for n in nodes:
        texts.append(post(f"{base}save/{sid}", {"n": n, "v": v})[2].decode(errors="replace"))
    P.expect_untouched(f"/save on {where}: each control", texts)
    for path in paths:
        texts += [post(f"{base}{route}/{sid}", f)[2].decode(errors="replace") for route, f in (
            ("w", {"tag": "omx-probe", "id": 0, "name": "open", "data": json.dumps({"path": path})}),
            ("reply", {"seq": 1, "data": json.dumps({"path": path}), "error": path}),
            ("describe", {"tag": "omx-probe", "id": 0, "data": json.dumps({"path": path})}),
            ("jslog", {"message": path, "source": path}),
            ("pending", {"v": v}), ("resize", {"w": 900, "h": 700}), ("appearance", {"dark": 1}))]
        texts.append(get(f"{base}spot/{sid}/0?name=" + urllib.parse.quote(path))[2].decode(errors="replace"))
        texts.append(get(f"{base}download/{sid}/" + urllib.parse.quote(path, safe=""))[2].decode(errors="replace"))
        texts.append(get(f"{base}img/{sid}/0")[2].decode(errors="replace"))
    P.expect_untouched(f"/w, /reply, /describe, /jslog, /spot, /download, /img on {where}", texts)
    # uploads whose file name walks out of the visitor's folder
    for route in ("upload", "dropfile"):
        for n in nodes[:40]:
            for name in ("../../../m2-probe/written.csv", str(P.dir / "written.csv"), "..%2f..%2fwritten.csv", "/etc/written.csv"):
                post(f"{base}{route}/{sid}?n={n}&v={v}", {"n": n, "v": v}, files=[(name, b"a,b\n1,2\n")])
    wrote = list(P.dir.glob("written*")) + [p for p in (Path("/etc/written.csv"),) if p.exists()]
    P.say(not wrote, f"/upload and /dropfile with file names that walk out ({where}): " + (f"wrote {wrote}" if wrote else "every file stayed in its visitor's folder"))
    P.expect_untouched(f"uploads named outside ({where})")


def type_and_run(page, field_sel, text, button_re):
    page.fill(field_sel, text)
    page.locator("button", has_text=re.compile(button_re)).last.click()
    try_settle(page)


def run_all(out):
    out = Path(out)
    P = Probe(out)
    srv = Server(out, public=True, env={"OMXCODE_UPLOAD_MAX": str(1 << 20), "OMXCODE_VISITOR_MAX": str(3 << 20),
                                        "MOJOUI_AGENT_SOCKET": str(out.parent / "m2-agent.sock"), "MOJOUI_DEV": "1", "MOJOUI_DEV_TOKEN": "probe"})
    roots = [str(ROOT), str(G47), str(srv.out), str(srv.uploads), str(srv.home), str(Path.home()), str(P.dir), "/home/"]
    from harness import STARTER
    roots += [str(STARTER), str(STARTER.resolve())]
    paths = [str(P.dir / "secret.csv"), str(P.dir), str(P.dir / "secret.omx"), "/etc/passwd", "../../../../etc/passwd", "file://" + str(P.dir / "secret.csv")]
    try:
        # ---- the agent link and /dev are off
        sock = out.parent / "m2-agent.sock"
        P.say(not sock.exists() and not any("agent link at" in l for l in srv.log), "agent link off in public mode (MOJOUI_AGENT_SOCKET set): " + ("a socket was made" if sock.exists() else "no socket"))
        for path in ("dev/assets", "dev/wait/0", "dev/reload?token=probe"):
            st, _, body = get(srv.url + path, data=b"" if "reload" in path else None)
            P.say(st == 404, f"/{path.split('?')[0]} off: {st}")
        # ---- traversal on the static routes
        src = (ROOT / "mojoui/hosts/web.py").read_text()[:400]
        for path in ("static/..%2fweb.py", "static/..%2f..%2fhosts%2fweb.py", "static/%2e%2e/web.py", "static/fonts/..%2f..%2fweb.py",
                     "static/fonts/..%2f..%2f..%2fREADME.md.ttf", "static/fonts/%2e%2e%2f%2e%2e%2fweb.py", "assets/..%2fmanifest.json",
                     "assets/%2e%2e%2f%2e%2e%2fapp.sha256", "static/icons/..%2f..%2fweb.py", "static//etc/passwd", "assets/..%2f..%2f..%2f..%2f..%2fetc%2fpasswd"):
            st, _, body = get(srv.url + path)
            text = body.decode(errors="replace")
            P.say(st in (400, 404) and "root:x:0" not in text and "import" not in text[:2000] and src[:200] not in text, f"/{path}: {st}, {len(body)} bytes")
        from playwright.sync_api import sync_playwright
        with sync_playwright() as pw:
            b = chromium(pw)
            # ---- visitor 1: crafted requests on the Start screen, then uploads past the caps
            ctx = b.new_context(viewport={"width": 1440, "height": 900}, accept_downloads=True)
            page = ctx.new_page()
            page.add_init_script(PROBE)
            page.goto(srv.url)
            settle(page)
            st = page_state(page)
            crafted_routes(P, srv.url, st["sid"], st["v"], st["nodes"], paths, "the Start screen")
            page.goto(srv.url)
            settle(page)
            st = page_state(page)
            mine = srv.uploads / st["sid"]
            # per file: one byte past 1 MB
            r = post(f"{srv.url}upload/{st['sid']}?n={st['nodes'][0]}&v={st['v']}", {}, files=[("big.csv", b"x" * ((1 << 20) + 1))])
            kept = sum(f.stat().st_size for f in mine.rglob("*") if f.is_file()) if mine.exists() else 0
            P.say(kept <= 64 and b"larger than" in r[2], f"an upload one byte over the per-file cap (1 MB): refused, {kept} bytes kept")
            pick = page.locator("input[type=file]").first
            sizes = []
            for k in range(4):  # (0.9 MB each: the fourth would take this visitor past 3 MB)
                f = out / f"part{k}.csv"
                f.write_text("a,b\n" + "1,2\n" * (230000))
                pick.set_input_files(str(f))
                try_settle(page)
                page.wait_for_timeout(500)
                sizes.append(sum(x.stat().st_size for x in mine.rglob("*") if x.is_file() and x.name != ".owner") if mine.exists() else 0)
                page.goto(srv.url) if k == 1 else None
            body = page.inner_text("body")
            P.say(max(sizes) <= 3 << 20, f"uploads past the per-visitor cap (3 MB): kept {[round(s / 2**20, 2) for s in sizes]} MB")
            # visitor 1 opens a file of its own, named so a later visitor would recognise it
            secret = out / "visitor-one-secret.csv"
            secret.write_text("a,b\n1,2\n")
            page.goto(srv.url)
            settle(page)
            page.locator("input[type=file]").first.set_input_files(str(secret))
            try_settle(page)
            # ---- the story: crafted requests on its screen, the Script window, SQL, and every response scanned
            leaks = []

            def scan(resp):
                try:
                    ct = resp.headers.get("content-type", "")
                    text = json.dumps(dict(resp.headers))
                    if "image" not in ct and "font" not in ct:
                        text += resp.text()
                    found = scan_paths(text, roots)
                    if found:
                        leaks.append((resp.url.split("/", 3)[-1][:60], found, text[max(0, text.find(found[0]) - 80):text.find(found[0]) + 80]))
                except Exception:
                    pass

            ctx2 = b.new_context(viewport={"width": 1440, "height": 900}, accept_downloads=True)
            page2 = ctx2.new_page()
            page2.add_init_script(PROBE)
            page2.on("response", scan)
            page2.goto(srv.url)
            settle(page2)
            body2 = page2.inner_text("body")
            P.say("visitor-one-secret" not in body2 and "part0" not in body2, "a second visitor's Start screen shows nothing from the first: "
                  + ("it lists the first's file" if "visitor-one-secret" in body2 else "nothing"))
            import story as S
            R = S.play(page2, out / "visitor-2", Net(page2), pack=True)
            bad = [f"{k}: {v['note'][:120]}" for k, v in R["beats"].items() if not v["ok"]]
            P.say(not bad, "the story, played with every response scanned: " + ("; ".join(bad) if bad else "every beat"))
            st = page_state(page2)
            crafted_routes(P, srv.url, st["sid"], st["v"], st["nodes"], paths, "the story's screen")
            page2.goto(srv.url)  # (the crafted requests pressed every button: a fresh tab for the Script window and SQL)
            settle(page2)
            page2.locator("button", has_text=re.compile("Start the robot story")).first.click()
            page2.wait_for_function("() => /16,847,616/.test(document.body.innerText)", timeout=180000)
            try_settle(page2)
            for p_ in paths[:2] + ["/etc/passwd"]:
                for sql in (f"SELECT * FROM read_csv('{p_}')", f"SELECT * FROM '{p_}'", f"SELECT * FROM read_parquet('{p_}')",
                            f"COPY fleet TO '{P.dir}/written.csv'", f"ATTACH '{p_}' AS x"):
                    page2.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Query\s*$")).first.click()
                    try_settle(page2)
                    area = page2.locator("[data-kind=dialog] textarea, dialog textarea").last
                    if area.count():
                        area.fill(sql)
                        run = page2.locator("[data-kind=dialog] button, dialog button").filter(has_text=re.compile(r"^\s*Run"))
                        if run.count():
                            run.last.click()
                        try_settle(page2)
                    page2.keyboard.press("Escape")
                    try_settle(page2)
            P.expect_untouched("SQL that names a server path (read_csv, a quoted file, read_parquet, COPY TO, ATTACH)", [page2.inner_text("body")])
            page2.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Script\s*$")).first.click()
            try_settle(page2)
            area = page2.locator("textarea").last
            for p_ in paths[:2] + ["/etc/passwd"]:
                script = (f"a = SELECT * FROM read_csv('{p_}');\nb = SELECT * FROM '{p_}';\nc = regions('{p_}', 0, 1);\n"
                          f"d = scene('{p_}', 0, 1);\ne = SELECT * FROM read_text('{p_}')")
                if area.count():
                    area.fill(script)
                    run = page2.locator("button", has_text=re.compile(r"^\s*Run"))
                    if run.count():
                        run.last.click()
                    try_settle(page2)
            P.expect_untouched("the Script window naming a server path (read_csv, a quoted file, regions, scene, read_text)", [page2.inner_text("body")])
            P.say(not leaks, "no response during the story holds a server path: " + (f"{len(leaks)} did, first {leaks[0]}" if leaks else f"none (scanned for {len(roots)} roots)"))
            b.close()
        P.say(srv.p.poll() is None, "the server is still up after every probe")
    finally:
        srv.stop()
    P.expect_untouched("the whole run")
    return not any(l.startswith("FAIL") for l in P.lines), P.lines
