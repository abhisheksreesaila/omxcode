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

from harness import Server, fresh, settle, try_settle, PROBE, Net, chromium, get, ROOT, STARTER

QUESTIONS = [  # (SQL, the words that must come back, what it tests)
    ("SELECT episode, t, speed, gripper, COUNT(*) AS n FROM telemetry GROUP BY episode, t, speed, gripper ORDER BY n DESC",
     r"ran past the web copy's 1 s", "time"),
    ("SELECT * FROM telemetry", r"more than 100,000 rows", "rows"),
    ("WITH f AS (SELECT * FROM fleet) SELECT COUNT(*) AS n FROM f", r"asks one SELECT at a time", "one-SELECT (a WITH)"),
    ("x = SELECT * FROM fleet; y = SELECT * FROM x", r"asks one SELECT at a time", "one-SELECT (script statements)"),
    ("SELECT COUNT(*) AS episodes FROM fleet -- how many", r"\b1 row\b", "a trailing comment (answers)"),
    ("(WITH f AS (SELECT * FROM fleet) SELECT COUNT(*) AS n FROM f)", r"WITH isn't offered", "one-SELECT (a WITH behind a parenthesis)"),
    ("SELECT episode FROM telemetry UNION ALL SELECT episode FROM telemetry", r"UNION, INTERSECT and EXCEPT aren't offered", "one-SELECT (UNION ALL)"),
]
# round 3: a sort inside a subquery, over all of telemetry: the engine has no stop check in it, so it runs on past the stop
HEAVY = ("SELECT * FROM (SELECT * FROM (SELECT * FROM (SELECT * FROM telemetry ORDER BY speed DESC, t) AS a ORDER BY t, speed) AS b "
         "ORDER BY episode DESC, t DESC) AS c")  # (three sorts of every column: past the 256 MB sort budget, they spill)


def ask(page, sql, words, seconds=60):
    """Query → the SQL → Run; the plain words that came back (None if none in `seconds`)."""
    page.keyboard.press("Escape")  # (a dialog still open from the last question)
    try_settle(page)
    page.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Query\s*$")).first.click()
    try_settle(page)
    page.locator("[data-kind=dialog] textarea, dialog textarea").last.fill(sql)
    page.locator("[data-kind=dialog] button, dialog button").filter(has_text=re.compile(r"^\s*Run")).last.click()
    t0 = time.time()
    while time.time() - t0 < seconds:
        m = re.search(words, page.inner_text("body"))
        if m:
            return m.group(0)
        page.wait_for_timeout(200)
    return None


def cpu_s(pid):
    """The process's CPU seconds so far (user + system, every thread)."""
    f = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK")


def cores(pid, seconds):
    a, t0 = cpu_s(pid), time.time()
    time.sleep(seconds)
    return (cpu_s(pid) - a) / (time.time() - t0)


def server_state(srv):
    """What the server holds now: memory (RSS + swap, MB), its threads and its open files."""
    pid = srv.pid()
    st = Path(f"/proc/{pid}/status").read_text()
    return srv.memory()["mem_mb"], int(re.search(r"Threads:\s+(\d+)", st).group(1)), len(os.listdir(f"/proc/{pid}/fd"))


def round4(page, srv, out, say):
    """Round 4's exploits, each proven by the server's resources."""
    import socket
    import threading
    # 1. a 20 MB CSV of 1M rows and a 400-column answer (the review: ~4.8 GB, a 6.1 GB peak)
    wide = out / "files/wide.csv"
    with open(wide, "w") as f:
        f.write("id,v\n")
        f.writelines(f"{i},{i % 997}\n" for i in range(1_000_000))
    fresh(page, srv.url)
    settle(page)
    page.locator("input[data-kind=picker]").first.set_input_files(str(wide))
    t0 = time.time()
    while time.time() - t0 < 60 and "1,000,000" not in page.inner_text("body"):
        page.wait_for_timeout(250)
    create = page.locator("button", has_text=re.compile(r"^\s*Create table\s*$"))  # (an upload opens on the Import step)
    if create.count():
        create.first.click()
        try_settle(page)
    page.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Query\s*$")).first.wait_for(timeout=60000)
    m0, peak = srv.memory()["mem_mb"], [0]
    stop = threading.Event()

    def watch():
        while not stop.is_set():
            peak[0] = max(peak[0], srv.memory()["mem_mb"])
            time.sleep(0.1)
    threading.Thread(target=watch, daemon=True).start()
    said = ask(page, "SELECT " + ", ".join(f"v AS c{i}" for i in range(400)) + " FROM wide", r"would take more than [^:]*", 60)
    time.sleep(1)
    stop.set()
    say(said is not None and peak[0] - m0 < 400, f"400 columns over a 1M-row upload: “{said}”; the server {m0} MB, at most {peak[0]} MB meanwhile")
    for what, q in (("40 columns behind a subquery's SELECT *", "SELECT * FROM (SELECT " + ", ".join(f"v AS c{i}" for i in range(40)) + " FROM wide) AS s"),
                    ("a built 500-character string a row", "SELECT CAST(id AS TEXT) || '" + "0123456789" * 50 + "' AS s FROM wide")):
        m0, peak[0] = srv.memory()["mem_mb"], 0
        stop = threading.Event()
        threading.Thread(target=watch, daemon=True).start()
        said = ask(page, q, r"(?:would|could) take more than [^:]*", 60)
        time.sleep(1)
        stop.set()
        say(said is not None and peak[0] - m0 < 400, f"round 5, {what} over 1M rows: “{said}”; the server {m0} MB, at most {peak[0]} MB meanwhile")
    page.keyboard.press("Escape")
    # 2. three slow uploads for a made-up session, 200 MB each by their headers: refused before their bodies
    m0, th0, fd0 = server_state(srv)
    host, port = srv.url.split("//")[1].rstrip("/").split(":")
    answers, conns = [], []
    for k in range(3):
        c = socket.create_connection((host, int(port)))
        c.sendall((f"POST /upload/{'0' * 31}{k} HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\n"
                   f"Content-Length: {200 << 20}\r\n\r\n").encode() + b"--b\r\n" + b"x" * 65536)
        conns.append(c)
    t0 = time.time()
    for c in conns:
        c.settimeout(10)
        try:
            answers.append(c.recv(4096).decode(errors="replace"))
        except OSError:
            answers.append("")
    took = time.time() - t0
    m1, th1, fd1 = server_state(srv)
    [c.close() for c in conns]
    gone = sum(1 for a in answers if "204" in a.split("\r\n")[0] and "x-mojoui-gone" in a.lower())
    ok = gone == 3 and took < 5 and m1 - m0 < 50 and fd1 - fd0 <= 3
    say(ok, f"3 slow 200 MB uploads for a made-up session: answered in {took:.1f} s after 64 KB each ({gone} “gone”, before the upload gate since round 5); "
        f"the server {m0} → {m1} MB, open files {fd0} → {fd1}")
    # 3. 300 open /frame requests at 3840×2400 from one session: /health stays quick
    fresh(page, srv.url)
    settle(page)
    sid = page.evaluate("() => document.getElementById('mojoui-root').dataset.sid")
    node = page.evaluate("() => { const d = document.querySelector('[data-kind=canvas]'); return d ? d.dataset.node : '0' }")
    import urllib.request

    def frame():
        try:
            urllib.request.urlopen(f"{srv.url}frame/{sid}/{node}?w=3840&h=2400&scale=1&v=0&tick=1", timeout=60).read()
        except Exception:
            pass
    ts = [threading.Thread(target=frame, daemon=True) for _ in range(300)]
    [t.start() for t in ts]
    lat, threads = [], 0
    for _ in range(20):
        t1 = time.perf_counter()
        get(srv.url + "health")
        lat.append((time.perf_counter() - t1) * 1000)
        threads = max(threads, server_state(srv)[1])
        time.sleep(0.1)
    [t.join(60) for t in ts]
    lat.sort()
    say(lat[10] < 200 and lat[-1] < 1000 and srv.p.poll() is None,
        f"300 open /frame requests at 3840×2400 from one session: /health median {lat[10]:.0f} ms, worst {lat[-1]:.0f} ms; the server at most {threads} threads")
    # 4. a real browser's upload past the visitor's cap (50 MB here): the notice, not a reset connection
    big = out / "files/past-cap.csv"
    with open(big, "wb") as f:
        f.write(b"a,b\n" + b"1,2\n" * ((60 << 20) // 4))
    fresh(page, srv.url)
    settle(page)
    page.locator("input[data-kind=picker]").first.set_input_files(str(big))
    said, t0 = None, time.time()
    while time.time() - t0 < 120:
        m = re.search(r"wasn't taken: [^.]*\.|wasn't uploaded: [^.]*\.", page.inner_text("body"))
        if m:
            said = m.group(0)
            break
        page.wait_for_timeout(250)
    say(said is not None, f"a 60 MB upload past a 50 MB visitor cap, from Chromium: " + (f"“{said}”" if said else "no notice (a reset connection?)"))


def connections(out, say):
    """Round 5: slow and idle connections, and slow uploads, on a server with no proxy in front (the per-peer cap live),
    each proven by the server's open files and its upload budget. /health is asked from another address (127.0.0.2)."""
    import http.client
    import socket
    srv = Server(out / "srv-conn", public=True, env={"MOJOUI_UPLOADS_IN_FLIGHT_MB": "50", "OMXCODE_VISITOR_MAX": str(100 << 20)})
    host, port = "127.0.0.1", int(srv.url.split(":")[2].strip("/"))

    def other(path, headers=None):  # (another visitor, from 127.0.0.2)
        c = http.client.HTTPConnection(host, port, timeout=10, source_address=("127.0.0.2", 0))
        t0 = time.perf_counter()
        try:
            c.request("GET", path, headers=headers or {})
            r = c.getresponse()
            body = r.read().decode(errors="replace")
            return r.status, (time.perf_counter() - t0) * 1000, body
        except OSError as e:
            return 0, (time.perf_counter() - t0) * 1000, str(e)
        finally:
            c.close()

    def fds():  # (the server's open sockets: a page load's new session opens files of its own)
        d = f"/proc/{srv.pid()}/fd"
        out = 0
        for f in os.listdir(d):
            try:
                out += os.readlink(f"{d}/{f}").startswith("socket:")
            except OSError:
                pass
        return out
    try:
        time.sleep(1)
        base = fds()
        socks = []
        for k in range(600):  # 600 idle sockets and 100 that send half a request's headers, all from 127.0.0.1
            try:
                c = socket.create_connection((host, port), timeout=5)
                if k >= 500:
                    c.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")
                socks.append(c)
            except OSError:
                pass
        time.sleep(1)
        held = fds() - base
        st = [other("/health"), other("/", {"Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate", "X-Real-IP": "198.51.100.7"})]
        ok_now = all(code == 200 and ms < 1000 for code, ms, _ in st)
        time.sleep(HEADER_WAIT)
        left = fds() - base
        [c.close() for c in socks]
        say(ok_now and held <= 70 and left <= 5, f"600 idle and 100 half-header sockets from one address: the server held {held} of them "
            f"(64 a peer), /health and / answered another address {[c for c, _, _ in st]} in {max(ms for _, ms, _ in st):.0f} ms; "
            f"{HEADER_WAIT} s later {left} were left")
        # slow POSTs for a made-up session: answered before their bodies
        t0, answers = time.time(), []
        for k in range(50):
            c = socket.create_connection((host, port), timeout=5, source_address=("127.0.0.3", 0))
            c.sendall(f"POST /e/{'2' * 31}{k % 10} HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 100000\r\n\r\nn=1".encode())
            try:
                answers.append(c.recv(200).decode(errors="replace").split("\r\n")[0])
            except OSError:
                answers.append("")
            c.close()
        say(all("204" in a for a in answers) and time.time() - t0 < 10, f"50 slow POSTs to /e/<made-up session>: {sum('204' in a for a in answers)} answered "
            f"“gone” before their bodies, in {time.time() - t0:.1f} s")
        # slow uploads: one whose session ends, one under the rate floor; the server's 50 MB of uploads in flight comes back
        def page_of(ip):
            code, _, html = other("/", {"Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate", "X-Real-IP": ip})
            sid = re.search(r'data-sid="([0-9a-f]+)"', html).group(1)
            v = re.search(r'id="mojoui-v"[^>]*value="(-?\d+)"|value="(-?\d+)"[^>]*id="mojoui-v"', html)
            n = re.search(r'hx-post="/upload/' + sid + r'"[^>]*hx-vals=\'\{"n": (\d+)\}\'', html).group(1)
            return sid, int(v.group(1) or v.group(2)), int(n)

        def slow_upload(sid, v, n, size):
            head = (f'--b\r\nContent-Disposition: form-data; name="n"\r\n\r\n{n}\r\n--b\r\nContent-Disposition: form-data; name="v"\r\n\r\n{v}\r\n'
                    f'--b\r\nContent-Disposition: form-data; name="file"; filename="slow.csv"\r\nContent-Type: text/csv\r\n\r\n').encode()
            c = socket.create_connection((host, port), timeout=5, source_address=("127.0.0.4", 0))
            c.sendall(f"POST /upload/{sid} HTTP/1.1\r\nHost: x\r\nX-Real-IP: 198.51.100.{n % 200}\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: {size}\r\n\r\n".encode() + head + b"a,b\n" * 1000)
            return c

        def closed_within(c, seconds):
            t0 = time.time()
            c.settimeout(1)
            while time.time() - t0 < seconds:
                try:
                    c.sendall(b"1,2\n" * 64)
                    if c.recv(4096) == b"":
                        return time.time() - t0
                except socket.timeout:
                    continue
                except OSError:
                    return time.time() - t0
            return None
        a = page_of("198.51.100.21")
        ca = slow_upload(*a, 40 << 20)
        time.sleep(1)
        other(f"/health")
        c = http.client.HTTPConnection(host, port, timeout=10, source_address=("127.0.0.2", 0))
        c.request("POST", f"/bye/{a[0]}")
        c.getresponse().read()
        gone_a = closed_within(ca, 30)
        b = page_of("198.51.100.22")
        cb = slow_upload(*b, 30 << 20)
        cb.settimeout(2)
        try:
            refused_b = b"other visitors' uploads" in cb.recv(4096)
        except socket.timeout:
            refused_b = False
        cut_b = closed_within(cb, BODY_WAIT)
        say(gone_a is not None and not refused_b and cut_b is not None,
            f"a slow 40 MB upload whose session ends: its connection closed {gone_a and round(gone_a, 1)} s after; then another visitor's 30 MB "
            f"upload {'was refused' if refused_b else 'was taken'} under the server's 50 MB in flight, and trickling under the rate floor "
            f"it was cut after {cut_b and round(cut_b, 1)} s")
    finally:
        srv.stop()


HEADER_WAIT = 14  # (10 s for headers, and a little)
BODY_WAIT = 40  # (10 s of grace, then 16 KB/s)


def resources(out, say):
    """Round 3's review: a budget is proven by the server's CPU and memory coming back, not by the page's words. One
    question place on this server (MOJOUI_QUESTIONS=1), 2 cores and a 256 MB sort a question, a 1 s budget."""
    from playwright.sync_api import sync_playwright
    import story as S
    srv = Server(out / "srv-resources", public=True, env={"MOJOUI_QUERY_S": "1", "MOJOUI_QUESTIONS": "1", "MOJOUI_QUERY_THREADS": "2", "MOJOUI_QUESTION_WAIT_S": "1"})
    try:
        with sync_playwright() as p:
            b = chromium(p)
            pa_, pb_ = (b.new_context(viewport={"width": 1440, "height": 900}).new_page() for _ in range(2))
            for pg in (pa_, pb_):
                pg.goto(srv.url)
                settle(pg)
                S.Visitor(pg, out / f"visitor-res-{id(pg)}", Net(pg)).start()
            pid = srv.pid()
            time.sleep(3)
            base_cpu, base_mem = cores(pid, 3), srv.memory()["mem_mb"]
            import threading
            samples, stop = [], threading.Event()

            def sample():  # (every 0.25 s from Run until the server is back: (seconds, cores, MB))
                t_, c_ = time.time(), cpu_s(pid)
                while not stop.is_set():
                    time.sleep(0.25)
                    t2, c2 = time.time(), cpu_s(pid)
                    samples.append((t2, (c2 - c_) / (t2 - t_), srv.memory()["mem_mb"]))
                    t_, c_ = t2, c2
            th = threading.Thread(target=sample, daemon=True)
            th.start()
            t0 = time.time()
            said = ask(pa_, HEAVY, r"ran past the web copy's 1 s")
            t_stop = time.time()
            again = ask(pa_, "SELECT COUNT(*) AS n FROM fleet", r"still finishing on the server|\b1 row\b", 20)
            other = ask(pb_, "SELECT COUNT(*) AS n FROM fleet", r"answering other visitors' questions|\b1 row\b", 20)
            back = None
            while time.time() - t0 < 180 and back is None:
                time.sleep(1)
                tail = [x for x in samples if x[0] > time.time() - 2]
                if tail and max(c for _, c, _ in tail) < base_cpu + 0.3 and tail[-1][2] < base_mem + 300:
                    back = tail[-1]
            stop.set()
            running = [x for x in samples if t0 < x[0] < t_stop + 30 and x[1] > base_cpu + 0.3]
            busiest = max((c for _, c, _ in running), default=0)
            peak = max((m for _, _, m in samples), default=0)
            last_busy = max((t for t, _, _ in running), default=t_stop)
            say(said is not None, f"a sort in a subquery over every telemetry row, past the 1 s budget: “{said}” after {t_stop - t0:.1f} s; "
                f"the engine ran on {last_busy - t_stop:+.1f} s after the stop; meanwhile the same visitor's next question said “{again}”, another visitor's “{other}”")
            say(running and busiest <= 2.6, f"while it ran the server used at most {busiest:.1f} cores (2 a question, {len(running)} busy samples), not every core")
            say(back is not None, f"the server comes back: {base_cpu:.2f} cores and {base_mem} MB before; "
                + (f"{back[1]:.2f} cores and {back[2]} MB {back[0] - t0:.0f} s after Run (peak {peak} MB)" if back else f"not within 3 minutes (peak {peak} MB)"))
            pb_.keyboard.press("Escape")
            now = ask(pb_, "SELECT COUNT(*) AS n FROM fleet", r"\b1 row\b", 30)
            say(now is not None, "once the engine has ended it, the other visitor's question runs")
            b.close()
    finally:
        srv.stop()



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

    srv = Server(out / "srv", public=True, env={"MOJOUI_QUERY_S": "1", "MOJOUI_QUERY_ROWS": "100000", "MOJOUI_JOIN_BYTES": str(1 << 20),
                                                "MOJOUI_MAX_SESSIONS": "20",
                                                "MOJOUI_PER_IP": "20", "OMXCODE_VISITOR_MAX": str(50 << 20), "MOJOUI_BEHIND_PROXY": "1"})  # (budgets shortened for the check)
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
            fresh(page, srv.url)
            settle(page)
            S.Visitor(page, out / "visitor-a", Net(page)).start()
            say(page.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Script\s*$")).count() == 0,
                "the Script window (statements outside a question's budgets) isn't offered on the public copy")
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
                say(said is not None and alive, f"a question, {what}: " + (f"stopped in {time.time() - t0:.1f} s, saying “…{said}…”" if said else "no plain words in 60 s")
                    + ("" if alive else "; the server is down"))
                page.keyboard.press("Escape")
                try_settle(page)
            for f in malformed(out / "files"):
                fresh(page, srv.url)
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
            # round 3: a decode bomb (516 KB, 120M rows, ~0.9 GB once read), three times: refused before the server reads it
            import bomb
            bf = bomb.write(str(out / "files/readings.parquet"))
            before = srv.memory()["mem_mb"]
            for k in range(3):
                fresh(page, srv.url)
                settle(page)
                page.locator("input[data-kind=picker]").first.set_input_files(bf)
                said, t0 = None, time.time()
                while time.time() - t0 < 120:
                    m = re.search(r"wasn't opened: [^.]*\.", page.inner_text("body"))
                    if m:
                        said = m.group(0)
                        break
                    page.wait_for_timeout(250)
            after = srv.memory()["mem_mb"]
            say(said is not None and "one table" in said and after - before < 150 and srv.p.poll() is None,
                f"a 516 KB Parquet that reads to 120M rows, uploaded 3 times: “{said}”; the server {before} → {after} MB")
            round4(page, srv, out, say)
            # valid files still open: a small Parquet (pyarrow) and a real clip
            import pyarrow as pa
            import pyarrow.parquet as pq
            good = out / "files/good.parquet"
            pq.write_table(pa.table({"episode": ["E1", "E2"], "speed": [0.5, 1.5]}), good)
            clip = out / "files/F00118.mp4"
            clip.write_bytes((STARTER / "clips/F00118.mp4").read_bytes())
            for f, opened in ((good, r"Create table|2 rows"), (clip, r"F00118\.mp4|0:16")):
                fresh(page, srv.url)
                settle(page)
                page.locator("input[data-kind=picker]").first.set_input_files(str(f))
                t0, ok = time.time(), False
                while time.time() - t0 < 60:
                    body = page.inner_text("body")
                    if "wasn't opened" in body:
                        break
                    if re.search(opened, body):
                        ok = True
                        break
                    page.wait_for_timeout(250)
                say(ok, f"a valid upload, {f.name}, opens")
            # a refused upload doesn't touch an accepted one of the same name
            fresh(page, srv.url)
            settle(page)
            sid = page.evaluate("() => document.getElementById('mojoui-root').dataset.sid")
            first = out / "files/same/x.csv"
            first.parent.mkdir(parents=True, exist_ok=True)
            first.write_text("a,b\n1,2\n3,4\n")
            page.locator("input[data-kind=picker]").first.set_input_files(str(first))
            try_settle(page)
            page.goto(srv.url) if False else None
            back = page.locator("button", has_text=re.compile(r"^\s*Back\s*$"))
            if back.count():
                back.first.click()
                try_settle(page)
            bad = out / "files/same2/x.csv"
            bad.parent.mkdir(parents=True, exist_ok=True)
            bad.write_bytes(os.urandom(50_000))
            page.locator("input[data-kind=picker]").first.set_input_files(str(bad))
            page.wait_for_timeout(3000)
            kept = [p_ for p_ in (srv.uploads / sid).rglob("x.csv") if p_.read_bytes() == first.read_bytes()]
            say(bool(kept), "a refused x.csv after an accepted x.csv: the accepted one is still there" if kept else "a refused x.csv deleted or overwrote the accepted one")
            # a flood of push streams on one tab: the newest is the only one kept, and the server stays quick
            import threading
            import urllib.request
            node = page.evaluate("() => { const d = document.querySelector('[data-kind=canvas]'); return d ? d.dataset.node : '0' }")
            def stream():
                try:
                    with urllib.request.urlopen(f"{srv.url}push/{sid}?v=0&c={node}:2560:1600:1:x", timeout=10) as r:
                        r.read(1 << 20)
                except Exception:
                    pass
            ts = [threading.Thread(target=stream, daemon=True) for _ in range(40)]
            [t.start() for t in ts]
            lat = []
            for _ in range(10):
                t0 = time.perf_counter()
                get(srv.url + "health")
                lat.append((time.perf_counter() - t0) * 1000)
                time.sleep(0.1)
            lat.sort()
            say(lat[5] < 100 and srv.p.poll() is None, f"40 push streams opened on one tab at once: /health median {lat[5]:.0f} ms, the server up")
            # D-6218's suspected sequences, with real clicks: a pivot, or the cursor on the last column, then another table
            fresh(page, srv.url)
            settle(page)
            v = S.Visitor(page, out / "visitor-a2", Net(page))
            v.start()
            v.pivot()
            grid = page.locator("[data-kind=canvas][data-tag=grid]").first
            box = grid.bounding_box()
            page.mouse.click(box["x"] + box["width"] - 30, box["y"] + 60)
            for _ in range(30):
                page.keyboard.press("Tab")
            def menu(item):  # (File, then the item once the menu shows it: a click on a closed menu's item can't land)
                for _ in range(3):
                    page.keyboard.press("Escape")
                    page.locator("button", has_text=re.compile(r"^\s*File\s*$")).first.click()
                    it = page.locator(f'[data-kind=item][data-title="{item}"]').first
                    try:
                        it.wait_for(state="visible", timeout=3000)
                        it.click()
                        return
                    except Exception:
                        pass
                raise RuntimeError(f"File › {item} never showed")
            menu("Open…")
            page.locator("button", has_text=re.compile("Open the sample")).first.click()
            page.wait_for_timeout(3000)
            menu("New blank sheet")
            page.wait_for_timeout(2000)
            alive = srv.p.poll() is None and get(srv.url + "health")[0] == 200
            say(alive, "D-6218's sequences (a pivot and the last column, then the sample, then a blank sheet): " + ("the server is up" if alive else "the server died"))
            b.close()
        resources(out, say)
        connections(out, say)
        # the join budget alone (the engine counts a join's matches before it refuses: ~3 s here, so the time budget is
        # long on this second server); columns from both sides: its pairs are materialized, which the budget holds
        srv2 = Server(out / "srv-join", public=True, env={"MOJOUI_QUERY_S": "60", "MOJOUI_JOIN_BYTES": str(1 << 20)})
        try:
            with sync_playwright() as p2:
                b2 = chromium(p2)
                pg = b2.new_context(viewport={"width": 1440, "height": 900}).new_page()
                pg.goto(srv2.url)
                settle(pg)
                S.Visitor(pg, out / "visitor-join", Net(pg)).start()
                pg.locator("button[data-kind=button]", has_text=re.compile(r"^\s*Query\s*$")).first.click()
                try_settle(pg)
                pg.locator("[data-kind=dialog] textarea, dialog textarea").last.fill("SELECT a.episode, a.t, b.t AS t2 FROM telemetry a JOIN telemetry b ON a.episode = b.episode")
                t0 = time.time()
                pg.locator("[data-kind=dialog] button, dialog button").filter(has_text=re.compile(r"^\s*Run")).last.click()
                said = None
                while time.time() - t0 < 60:
                    m = re.search(r"more memory than the web copy gives[^\n]{0,60}", pg.inner_text("body"))
                    if m:
                        said = m.group(0)
                        break
                    pg.wait_for_timeout(250)
                mem = srv2.memory()
                say(said is not None and srv2.p.poll() is None, f"a join past the memory budget (1 MB for the check): " + (f"stopped in {time.time() - t0:.1f} s, saying “…{said}”; the server peaked at {mem['peak_rss_mb']} MB" if said else "no plain words in 60 s"))
                b2.close()
        finally:
            srv2.stop()
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
