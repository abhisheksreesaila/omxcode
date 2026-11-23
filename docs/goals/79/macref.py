#!/usr/bin/env python3
"""The Mac's M0 reference (D-7983, ruling A): ref.mjs run by the web Personal Note on the Mac in the Mac's own Chrome at
2.0 (the ruling B setup, docs/goals/79/mac-setup.md), the shots, boxes, text widths and database fetched back.
  macref.py <out dir>      (MAC_SSH, MAC_SSH_KEY as scripts/mac-ssh)    exit 2: the Mac setup isn't there"""
import os, pathlib, subprocess, sys, tempfile, tarfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
out = pathlib.Path(sys.argv[1])
host = os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101")
key = os.path.expanduser(os.environ.get("MAC_SSH_KEY", "~/.ssh/edx_mac"))
ssh = ["ssh", "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host]
web = "omxcode-g79-web"
if subprocess.run(ssh + [f"test -x ~/{web}/node/bin/node && test -d ~/{web}/pn/node_modules/playwright && test -x ~/{web}/pn/.venv/bin/python"]).returncode:
    print(f"MACREF: no ruling B setup at ~/{web} on the Mac", file=sys.stderr)
    sys.exit(2)
tmp = pathlib.Path(tempfile.mkdtemp())
with tarfile.open(tmp / "repo.tgz", "w:gz") as t:  # (this checkout's ref.mjs, fixture and fonts: the Mac runs the same script)
    t.add(ROOT / "docs/goals/79", arcname="docs/goals/79")
    t.add(ROOT / "fonts", arcname="fonts")
subprocess.run(["scp", "-q", "-i", key, str(tmp / "repo.tgz"), f"{host}:{web}/repo.tgz"], check=True)
stamp = subprocess.run(["date", "+%s"], capture_output=True, text=True).stdout.strip()
rdir = f"ref-{stamp}"  # (a fresh folder each run: nothing deleted)
r = subprocess.run(ssh + [f"cd ~/{web} && mkdir -p repo && tar -xzf repo.tgz -C repo && cd pn && PATH=$HOME/{web}/node/bin:$PATH PW_CHANNEL=chrome "
                          f"node ../repo/docs/goals/79/ref.mjs ../{rdir} --dpr=2 > ../{rdir}.log 2>&1; echo rc=$?; tail -3 ../{rdir}.log"],
                   capture_output=True, text=True, timeout=1200)
print(r.stdout.strip())
if "rc=0" not in r.stdout:
    sys.exit(1)
out.mkdir(parents=True, exist_ok=True)
subprocess.run(["scp", "-q", "-r", "-i", key, f"{host}:{web}/{rdir}/.", str(out)], check=True)
print("MACREF: " + (out / "made-by.json").read_text().replace("\n", " "))
