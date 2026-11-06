"""Goal 53: the gallery's downloads (owner, 2026-11-05: "it goes into the galleries so you have to provide a link…
completely based on the app framework… I don't think we should have a web version"). Checks:
  M1 every download button on docs/gallery/index.html answers (HTTP 200 after redirects), and each gallery-apps asset is
     byte for byte the dist/ file that was run (sha256);
  M2 every Linux download was run bare (build/g53/bare.json: scripts/bare_run.py) and every Mac download ran on both of
     GitHub's Mac runners with exit 0 and no crash log (build/mac-ci/<run>/, the run named in the release notes);
  M3 no web build in the showcase: no Web chip or web screenshot in the gallery, no web shot on the cover or
     omxplorer's page, and the gallery page is what scripts/gallery_page.py writes.
  pixi run python docs/goals/53-check.py"""
import hashlib
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
REPO = "abhisheksreesaila/omxcode"
fails = []


def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        fails.append(what)


page = (ROOT / "docs/gallery/index.html").read_text()
links = re.findall(r'<a class="dl" href="([^"]+)"', page)
check(len(links) >= 12, f"{len(links)} download buttons in the gallery")

# M1
rel = json.loads(subprocess.run(["gh", "release", "view", "gallery-apps", "-R", REPO, "--json", "assets,body"],
                                capture_output=True, text=True).stdout or "{}")
digests = {a["name"]: (a.get("digest") or "").removeprefix("sha256:") for a in rel.get("assets", [])}
for url in links:
    try:
        req = urllib.request.Request(url, method="HEAD")
        code = urllib.request.urlopen(req, timeout=30).status
    except Exception as e:  # noqa: BLE001
        code = str(e)
    check(code == 200, f"M1 {url.rsplit('/', 2)[-2]}/{url.rsplit('/', 1)[-1]} answers ({code})")
    if "/gallery-apps/" in url:
        name = url.rsplit("/", 1)[-1]
        local = ROOT / "dist" / name
        mine = hashlib.sha256(local.read_bytes()).hexdigest() if local.exists() else "missing"
        check(digests.get(name) == mine, f"M1 {name} is the dist/ file that was run")

# M2
bare = json.loads((ROOT / "build/g53/bare.json").read_text()) if (ROOT / "build/g53/bare.json").exists() else {}
run = re.search(r"run (\d{8,})", rel.get("body", ""))
mac = ROOT / "build/mac-ci" / (run.group(1) if run else "none")
for url in links:
    name = url.rsplit("/", 1)[-1]
    if "/gallery-apps/" not in url:
        continue  # (omxplorer's own releases: proved by goals 34 and 50)
    app = name.split("-")[0]
    if "linux" in name:
        check(bare.get(app, {}).get("ok") is True, f"M2 {app}'s Linux download ran bare")
    else:
        for os_ in ("macos-15", "macos-26"):
            r = mac / f"report-{os_}"
            out = r / f"{app}-stdout.txt"
            if app == "widgets":  # (its runs are side.txt's screens)
                outs = [o for o in sorted((r / "side").glob("widgets-*.txt")) if not o.stem.endswith(("-log", "-views"))]
                ok = len(outs) > 0 and all(o.read_text().rstrip().endswith("exit 0") for o in outs)
            else:
                ok = out.exists() and out.read_text().rstrip().endswith("exit 0")
            crashes = list(r.rglob("*.ips")) if r.exists() else []
            check(ok and not crashes, f"M2 {app}'s Mac download ran on {os_} (run {mac.name})")

# M3
check(not re.search(r"<b>Web</b>", page), "M3 no Web chip in the gallery")
check(not re.search(r"-web[-.]", page), "M3 no web screenshot in the gallery")
cover = (ROOT / "docs/index.html").read_text()
plorer = (ROOT / "docs/omxplorer.html").read_text()
check("agentchat-web" not in cover and "omxplorer-sheet-web" not in cover and "The web, on WebGPU" not in cover,
      "M3 no web shot or web tile on the cover")
check("sentence-web" not in plorer, "M3 no web shot on omxplorer's page")
before = page
subprocess.run([sys.executable, str(ROOT / "scripts/gallery_page.py")], capture_output=True)
check((ROOT / "docs/gallery/index.html").read_text() == before, "M3 the gallery page is scripts/gallery_page.py's")

print(f"\n{len(fails)} failed" if fails else "\nall pass")
sys.exit(1 if fails else 0)
