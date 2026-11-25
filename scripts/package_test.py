"""pnote's Linux download as a person gets it (review 6, P1 and P2): unpacked outside the checkout, an empty HOME, real input on a
headless X server. Its words are drawn as the checkout's are; installed, updated and removed, the notes stay; without its fonts
it says so and draws in the system's.   pixi run python -B scripts/package_test.py      (after scripts/build.sh pnote linux)"""
import os, re, shutil, sqlite3, subprocess, sys, tempfile, time
from pathlib import Path
import numpy as np
from PIL import Image
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / "docs/goals/79"))
from xdrive import App, X
bad = []
W = Path(tempfile.mkdtemp(prefix="omx-package-", dir="/var/tmp"))
WORDS = "hello first words"


def note(ok, what):
    print(("ok   " if ok else "BAD  ") + what, flush=True)
    if not ok:
        bad.append(what)


def run(binary, name, home, type_it=True):
    """The app from `binary`, a first start in `home`: the words typed; its picture and its log."""
    d = W / f"run-{name}"
    d.mkdir()
    os.environ["XBIN"] = str(binary)
    for k in ["MOJOUI_FONTS", "OMX_DATA", "OMX_CONFIG", "PNOTE_DB"]:
        os.environ.pop(k, None)
    os.chdir(d)
    a = App({"PNOTE_BOXES": str(d / "boxes.json"), "HOME": str(home), "XDG_DATA_HOME": "", "XDG_CONFIG_HOME": "", "XDG_CACHE_HOME": ""}, d / "log.txt", (1280, 820))
    X.XSetInputFocus(a.d, a.win, 1, 0)
    X.XSync(a.d, 0)
    time.sleep(1)
    if type_it:
        a.type(WORDS)
        time.sleep(2.5)
        a.key("Escape")
        time.sleep(0.3)
    a.move(640, 815)
    time.sleep(0.6)
    a.shot(d / "1.png")
    rc = a.close()
    return np.asarray(Image.open(d / "1.png").convert("RGB")).astype(int), (d / "log.txt").read_text(), rc


def notes(home):
    f = home / ".local/share/pnote/notes.db"
    if not f.exists():
        return ""
    c = sqlite3.connect(f"file:{f}?mode=ro", uri=True)
    return " ".join(x[0] for x in c.execute("SELECT content FROM notes"))


def ink(p):
    return int((p.max(axis=2) < 110).sum())


os.chdir(R)
r = subprocess.run(["scripts/package.sh", "pnote", "linux"], capture_output=True, text=True)
note(r.returncode == 0, "packaged: " + (r.stdout + r.stderr).strip().splitlines()[-1][:120])
tar = R / "dist/pnote-linux-x86_64.tar.gz"
subprocess.run(["tar", "-xzf", str(tar), "-C", str(W)], check=True)
P = W / "pnote-linux-x86_64"
top = sorted(x.name for x in P.iterdir())
note(not [x for x in top if "." in x and x.startswith("pnote.") and x != "pnote.png"], f"nothing but the app: {top}")
ofl = list((P / "licenses").glob("OFL-*.txt"))
note(len(ofl) >= 10 and (P / "fonts/geist/OFL.txt").exists(), f"its fonts and their licences ({len(ofl)})")
note((P / "NOTICE.txt").read_text().startswith("pnote for Linux") and "omxplorer" not in (P / "NOTICE.txt").read_text(), "its NOTICE is its own")

homes = {k: W / f"home-{k}" for k in ["checkout", "unpacked", "installed", "nofonts"]}
for h in homes.values():
    h.mkdir()
ref, log, rc = run(R / "build/pnote/linux/pnote", "checkout", homes["checkout"])
got, log, rc = run(P / "pnote", "unpacked", homes["unpacked"])
same = (np.abs(ref - got).max(axis=2) > 24).mean()
note(same < 0.0005 and ink(got) > 2000, f"unpacked outside the checkout it draws what the checkout's does, words and all ({same:.5f} of the pixels differ, {ink(got)} dark ones of {ink(ref)})")
note(WORDS in notes(homes["unpacked"]), "and what was typed is in the notes file")
note("fonttext" not in log, "no font was missing")

H = homes["installed"]
run(P / "pnote", "before-install", H)  # ("run it here" first, as the README says)
e = dict(os.environ, HOME=str(H))
for step in ["install", "the same again (an update)"]:
    q = subprocess.run([str(P / "install.sh")], env=e, capture_output=True, text=True)
    note(q.returncode == 0 and WORDS in notes(H), f"{step}: the notes are there ({(q.stdout + q.stderr).strip().splitlines()[-1]})")
got, log, rc = run(H / ".local/bin/pnote", "installed", H, False)
note("fonttext" not in log and ink(got) > 2000, f"installed, it draws its words ({ink(got)} dark pixels) and opens the notes")
q = subprocess.run([str(H / ".local/bin/pnote-uninstall")], env=e, capture_output=True, text=True)
note(q.returncode == 0 and WORDS in notes(H) and not (H / ".local/lib/pnote").exists() and not (H / ".local/bin/pnote").exists(), f"removed, the notes stay: {q.stdout.strip()}")

# (review 8: the package's folder kept as the notes folder, run there, then installed and removed: the words were gone)
K = W / "home-kept"
(K / ".local/share").mkdir(parents=True)
shutil.copytree(P, K / ".local/share/pnote")
run(K / ".local/share/pnote/pnote", "kept", K)
q = subprocess.run([str(K / ".local/share/pnote/install.sh")], env=dict(os.environ, HOME=str(K)), capture_output=True, text=True)
note(q.returncode != 0 and "unpack it somewhere else" in q.stderr and WORDS in notes(K) and not (K / ".local/lib").exists(), f"the package kept where the notes are: refused, the notes there: {q.stderr.strip().splitlines()[0][:150]}")
q = subprocess.run([str(P / "install.sh")], env=dict(os.environ, HOME=str(K)), capture_output=True, text=True)
q2 = subprocess.run([str(K / ".local/bin/pnote-uninstall")], env=dict(os.environ, HOME=str(K)), capture_output=True, text=True)
note(q.returncode == 0 and q2.returncode == 0 and WORDS in notes(K), "installed from elsewhere and removed: the notes there")
man = (P / "files.sha256").read_text().splitlines()
note(len(man) == sum(1 for x in P.rglob("*") if x.is_file()) - 2 and not [l for l in man if l.endswith((".db", "install.sh"))], f"the packager's list names every file of the program ({len(man)}) and nothing else")
nt = (P / "NOTICE.txt").read_text()
note(all((P / "lib" / x).exists() for x in re.findall(r"^  (lib\w+\.so)", nt, re.M)) and ("zstd" in nt) == bool(list((P / "lib").glob("libzstd*"))), "its NOTICE names the libraries it carries, no others")

shutil.copytree(P, W / "nofonts")
shutil.rmtree(W / "nofonts/fonts")
got, log, rc = run(W / "nofonts/pnote", "nofonts", homes["nofonts"])
note("fonttext: the font" in log and ink(got) > 0.4 * ink(ref), f"without its fonts it says so and draws words in the system's ({ink(got)} dark pixels of {ink(ref)})")
os.chdir(R)
print("package:", "ok" if not bad else f"BAD {bad}", "|", W)
if not bad:
    shutil.rmtree(W)
sys.exit(1 if bad else 0)
