"""The web host's uploads and drops never leave files behind, and never refuse a file in silence (probe fixes, D-1704).

  evicted: a session evicted while a drop is still being written (two files: the first large, the eviction lands while
           it's copied) leaves no folder; an upload evicted the same way never reaches its closed app
  sweep:   a starting server removes upload/download folders whose server process has gone (and unowned ones older
           than a day); a live server's folder stays
  oversize: a dropped or picked file over OMXCODE_UPLOAD_MAX keeps nothing and answers with a notice the page shows

Run: pixi run python tests/test_web_files.py [build/jot/web]   (Jot's web build: a DropTarget with on_file, a FilePicker)
Prints `web files: ok`.
"""

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIG = 300 << 20  # the first dropped file: long enough to copy that the eviction lands mid-write


def load_web():
    spec = importlib.util.spec_from_file_location("web", ROOT / "mojoui/hosts/web.py")
    web = importlib.util.module_from_spec(spec)
    sys.modules["web"] = web
    spec.loader.exec_module(web)
    return web


def page(client):
    html = client.get("/").text
    sid = re.search(r'data-sid="([0-9a-f]+)"', html).group(1)
    drop = re.search(r'data-kind="drop" data-node="(\d+)"', html).group(1)
    v = re.search(r'id="mojoui-v"[^>]*value="(-?\d+)"|value="(-?\d+)"[^>]*id="mojoui-v"', html)
    v = v.group(1) or v.group(2)
    pick = re.search(r'hx-post="/upload/' + sid + r'"[^>]*hx-vals=\'\{"n": (\d+)\}\'', html)
    assert pick, "no FilePicker on the page"
    return sid, int(drop), int(v), int(pick.group(1))


def wait_for(cond, seconds=60):
    t = time.time()
    while time.time() - t < seconds:
        if cond():
            return True
        time.sleep(0.005)
    return False


def evicted(web, client, base, big):
    web.MAX_SESSIONS = 1
    sid, drop, v, pick = page(client)
    got = {}

    def send():
        with open(big, "rb") as f:
            got["r"] = client.post(f"/dropfile/{sid}", data={"n": str(drop), "v": str(v)},
                                   files=[("file", ("big.md", f, "text/markdown")), ("file", ("small.md", b"# after\n", "text/markdown"))])

    t = threading.Thread(target=send)
    t.start()
    assert wait_for(lambda: any((base / sid).glob("*/big.md"))), "the large file never started to land"
    page(client)  # (a second tab: MAX_SESSIONS 1 evicts the first, mid-write)
    t.join(120)
    left = sorted(str(p.relative_to(base)) for p in (base / sid).rglob("*")) if (base / sid).exists() else []
    assert not left, f"a drop finished after its session was evicted left files: {left}"
    print("evicted drop: ok (no folder left)")
    sid, drop, v, pick = page(client)
    got = {}

    def up():
        with open(big, "rb") as f:
            got["r"] = client.post(f"/upload/{sid}?n={pick}&v={v}", files={"file": ("big.md", f, "text/markdown")})

    t = threading.Thread(target=up)
    t.start()
    assert wait_for(lambda: (base / sid / "big.md").exists()), "the upload never started to land"
    page(client)
    t.join(120)
    assert got.get("r") is not None and got["r"].status_code == 200, f"the evicted upload answered {got.get('r')}"
    assert not (base / sid).exists() or not any((base / sid).rglob("*")), "an evicted upload left its file"
    print("evicted upload: ok (never reached the closed app, no file left)")
    web.MAX_SESSIONS = 200


def oversize(client, base):
    os.environ["OMXCODE_UPLOAD_MAX"] = "64"
    try:
        sid, drop, v, pick = page(client)
        r = client.post(f"/dropfile/{sid}", data={"n": str(drop), "v": str(v)},
                        files=[("file", ("huge.md", b"x" * 1000, "text/markdown"))])
        assert "huge.md" in r.text and "mojoui-notice" in r.text, f"an oversize drop answered without a notice: {r.text[:300]!r}"
        assert not any((base / sid).rglob("huge.md")), "an oversize drop kept its file"
        r = client.post(f"/upload/{sid}?n={pick}&v={v}", files={"file": ("huge.md", b"x" * 1000, "text/markdown")})
        assert "huge.md" in r.text and "mojoui-notice" in r.text, f"an oversize upload answered without a notice: {r.text[:300]!r}"
        assert not any((base / sid).rglob("huge.md")), "an oversize upload kept its file"
        print("oversize: ok (nothing kept, the page gets a notice)")
    finally:
        del os.environ["OMXCODE_UPLOAD_MAX"]


def main():
    module_dir = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "build/jot/web")
    with tempfile.TemporaryDirectory() as d:
        base = Path(d) / "uploads"
        os.environ["OMXCODE_UPLOADS"] = str(base)
        os.environ["JOT_DB"] = str(Path(d) / "jot.db")
        os.environ["JOT_HOME"] = d
        # a gone server's folders and an old unowned one, as a crash leaves them; and a live server's (this process)
        dead = subprocess.Popen(["true"]); dead.wait()
        for kind in (base, base.parent / "downloads"):
            (kind / "gone1").mkdir(parents=True)
            (kind / "gone1" / ".owner").write_text(str(dead.pid))
            (kind / "gone1" / "a.md").write_text("left by a crash")
            (kind / "old1").mkdir()
            (kind / "old1" / "b.md").write_text("old")
            os.utime(kind / "old1", (time.time() - 3 * 86400,) * 2)
            (kind / "live1").mkdir()
            (kind / "live1" / ".owner").write_text(str(os.getpid()))
        web = load_web()
        from starlette.testclient import TestClient
        app = web.make_app(module_dir)
        with TestClient(app) as client:
            for kind in (base, base.parent / "downloads"):
                assert not (kind / "gone1").exists(), f"{kind.name}: a gone server's folder survived the start"
                assert not (kind / "old1").exists(), f"{kind.name}: an unowned folder 3 days old survived the start"
                assert (kind / "live1").exists(), f"{kind.name}: a live server's folder was swept"
            print("sweep: ok (gone and old folders removed, a live one kept)")
            big = Path(d) / "big.md"
            with open(big, "wb") as f:
                f.truncate(BIG)
            oversize(client, base)
            evicted(web, client, base, big)
    print("web files: ok")


if __name__ == "__main__":
    main()
