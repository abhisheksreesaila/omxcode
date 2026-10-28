"""The web host's dev server (goal 34b review, D-678): MOJOUI_DEV is refused unless the app's build is a debug build (its
manifest names a source map for every bundle); /dev/* answers only 127.0.0.1; /dev/reload only with the dev token.

Run: pixi run python tests/test_web_dev.py <debug build's web dir> <release build's web dir>
Each case runs in its own process (web.py reads MOJOUI_DEV when it is imported).
"""

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKEN = "right-token"


def child(module_dir, case):
    spec = importlib.util.spec_from_file_location("web", ROOT / "mojoui/hosts/web.py")
    web = importlib.util.module_from_spec(spec)
    sys.modules["web"] = web
    spec.loader.exec_module(web)
    if case == "release":
        try:
            web.make_app(module_dir)
        except SystemExit as e:
            assert "debug build" in str(e), e
            print("refused:", e)
            return
        raise AssertionError("MOJOUI_DEV was taken with a release build")
    from starlette.testclient import TestClient
    app = web.make_app(module_dir)
    far = TestClient(app, client=("10.0.0.5", 50000))
    for method, path, data in [("get", "/dev/assets", None), ("post", "/dev/reload", {"token": TOKEN}), ("get", "/dev/wait/0", None)]:
        r = getattr(far, method)(path, data=data) if data else getattr(far, method)(path)
        assert r.status_code == 403, f"{path} from 10.0.0.5 answered {r.status_code}"
    near = TestClient(app, client=("127.0.0.1", 50000))
    for data in ({"token": "wrong-token"}, {"token": ""}, {}):
        r = near.post("/dev/reload", data=data)
        assert r.status_code == 403, f"/dev/reload with {data} answered {r.status_code}"
    r = near.post("/dev/reload", data={"token": TOKEN})
    assert r.status_code == 200, f"/dev/reload with the token answered {r.status_code}"
    assert near.get("/dev/assets").status_code == 200
    print("dev endpoints: ok")


def main():
    if len(sys.argv) == 4:
        return child(sys.argv[1], sys.argv[3])
    debug, release = sys.argv[1], sys.argv[2]
    env = dict(os.environ, MOJOUI_DEV="1", MOJOUI_DEV_TOKEN=TOKEN)
    env.pop("MOJOUI_AGENT_SOCKET", None)
    for d, case in ((release, "release"), (debug, "debug")):
        r = subprocess.run([sys.executable, __file__, d, "-", case], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
        print(r.stdout.strip())
        if r.returncode != 0:
            print(r.stderr[-1500:])
            sys.exit(f"web_dev: the {case} case failed")
    print("web_dev: ok")


if __name__ == "__main__":
    main()
