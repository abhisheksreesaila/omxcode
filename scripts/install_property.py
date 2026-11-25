"""The installer's property (review 8): HOMEs with a person's files anywhere, at the installer's own places too, links and folders among
them; installs, updates, uninstalls and the layout of before in random order, some killed at a random moment. After every step every
file and link the person made is byte for byte there; a refusal changed nothing at all.
   python3 scripts/install_property.py [seeds [first]]      (TEMPLATE=…: another installer; scratch HOMEs only)"""
import hashlib, os, random, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path
R = Path(__file__).resolve().parents[1]
T = Path(os.environ.get("TEMPLATE", R / "linux/install.sh.in")).read_text()
W = Path(tempfile.mkdtemp(prefix="omx-installprop-"))
sha = lambda b: hashlib.sha256(b).hexdigest()


def package(d, v):
    files = {"app": f"#!/bin/sh\necho app {v}\n", "app.png": f"icon {v}\n", "lib/a.so": "lib\n", "README.txt": f"readme {v}\n", "fonts/geist/Geist[wght] x.ttf": "font\n", "data/both.txt": f"both {v}\n"}
    files |= {"only1/old.txt": "old 1\n"} if v == 1 else {}
    files |= {"new2.txt": "new 2\n", "deep/er/x.bin": "x 2\n"} if v == 2 else {}
    for f, t in files.items():
        (d / f).parent.mkdir(parents=True, exist_ok=True)
        (d / f).write_text(t)
    (d / "app").chmod(0o755)
    s = T
    for k, x in {"EX": "app", "COMMENT": "An app", "CATS": "Utility;", "MIME": "", "DATA": ".apphome/files"}.items():
        s = s.replace(f"@{k}@", x)
    (d / "install.sh").write_text(s)
    (d / "install.sh").chmod(0o755)
    (d / "files.sha256").write_text("".join(f"{sha((d / f).read_bytes())}  {755 if f == 'app' else 644} {f}\n" for f in sorted(files)))


for v in (1, 2, 3):
    package(W / f"v{v}", v)


def picture(h):
    out = {}
    for p in sorted(h.rglob("*")):
        r = str(p.relative_to(h))
        out[r] = ("l", os.readlink(p)) if p.is_symlink() else (("d",) if p.is_dir() else ("f", p.read_bytes()))
    return out


class World:
    def __init__(self, seed):
        self.r, self.h, self.mine, self.n, self.log = random.Random(seed), W / f"home{seed}", {}, 0, []
        self.h.mkdir()
        self.env = dict(os.environ, HOME=str(self.h))
        self.env.pop("XDG_DATA_HOME", None)
        if self.r.random() < 0.15:
            self.env["XDG_DATA_HOME"] = str(self.h / self.r.choice([".local/share", "xdg", ".local/lib"]))
        self.put(".local/share/app/notes.db")
        if self.r.random() < 0.3:
            self.old_layout(self.r.choice([1, 2]))

    def real(self, rel):
        return self.h / rel

    def put(self, rel, data=None):
        """The person writes a file there (over whatever file is there: it is theirs then)."""
        p = self.real(rel)
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            if p.is_dir() and not p.is_symlink():
                return
            if p.is_symlink():
                p.unlink()
            self.n += 1
            b = data if data is not None else f"the person's own words {self.n}\n".encode()
            p.write_bytes(b)
        except OSError:
            return
        rp = os.path.join(os.path.realpath(p.parent), p.name)
        self.mine = {k: v for k, v in self.mine.items() if k != rp}
        self.mine[rp] = ("f", b)

    def old_layout(self, v):
        o, b = self.real(".local/share/app"), self.real(".local/bin")
        shutil.copytree(W / f"v{v}", o, dirs_exist_ok=True)
        (o / "install.sh").unlink()
        (o / "files.sha256").unlink()
        for d in [b, self.real(".local/share/applications"), self.real(".local/share/icons/hicolor/256x256/apps")]:
            d.mkdir(parents=True, exist_ok=True)
        if not (b / "app").exists():
            os.symlink(o / "app", b / "app")
        e = self.real(".local/share/applications/app.desktop")
        e.write_text(f"[Desktop Entry]\nType=Application\nName=app\nComment=An app\nExec={o}/app %f\nIcon=app\nTerminal=false\nCategories=Utility;\nMimeType=\n")
        shutil.copy(o / "app.png", self.real(".local/share/icons/hicolor/256x256/apps/app.png"))
        u = b / "app-uninstall"
        if self.r.random() < 0.7 and not u.exists():  # (as the installer of before wrote it; without it nobody's installer put that program there)
            u.write_text(f'#!/usr/bin/env bash\nrm -rf "{o}" "{b}/app" "{e}" "{self.h}/.local/share/icons/hicolor/256x256/apps/app.png" "{u}"\n[ "$(readlink "{b}/omxc")" != "{o}/omxc" ] || rm -f "{b}/omxc"\necho "app removed"\n')
            u.chmod(0o755)

    PLACES = [".local/bin/app", ".local/bin/app-uninstall", ".local/bin/omxc", ".local/bin/other", ".local/share/applications/app.desktop", ".local/share/applications/mine.desktop",
              ".local/share/icons/hicolor/256x256/apps/app.png", ".local/lib/app/app", ".local/lib/app/README.txt", ".local/lib/app/mine.txt", ".local/lib/app/notes.db", ".local/lib/app/lib/a.so",
              ".local/lib/app/lib/mine.so", ".local/lib/app/only1/old.txt", ".local/lib/app/only1/mine.txt", ".local/lib/app/new2.txt", ".local/lib/app/unsaved/x.json", ".local/lib/app/fonts/geist/Geist[wght] x.ttf",
              ".local/share/app/notes.db", ".local/share/app/notes.db-wal", ".local/share/app/app", ".local/share/app/README.txt", ".local/share/app/lib/mine", ".local/share/app/snaps/a.snap", ".config/app/settings.txt",
              ".apphome/files/doc", "Documents/x.txt", "app", "app.png", "README.txt", ".local/lib/app/.manifest.bak", ".local/lib/other", ".local/lib/app/deep/er"]

    def person(self):
        k = self.r.random()
        p = self.r.choice(self.PLACES)
        if k < 0.6:
            self.put(p)
            return f"writes {p}"
        if k < 0.75:  # a link of the person's, to a file or a folder of theirs
            q = self.real(p)
            if q.exists() or q.is_symlink():
                return "nothing"
            self.n += 1
            t = self.real(f"things{self.n}")
            t.mkdir()
            (t / "x").write_text(f"thing {self.n}\n")
            self.mine[os.path.realpath(t / "x")] = ("f", f"thing {self.n}\n".encode())
            try:
                q.parent.mkdir(parents=True, exist_ok=True)
                to = t / "x" if self.r.random() < 0.5 else t
                os.symlink(to, q)
                self.mine[os.path.join(os.path.realpath(q.parent), q.name)] = ("l", str(to))
            except OSError:
                pass
            return f"links {p}"
        if k < 0.85:  # a folder of the program moved away, a link left in its place: what is in it is the person's copy now
            f = self.real(self.r.choice([".local/lib/app/fonts", ".local/lib/app/lib", ".local/lib/app/only1", ".local/share/app/lib"]))
            if not f.is_dir() or f.is_symlink():
                return "nothing"
            self.n += 1
            t = self.real(f"moved{self.n}")
            was = os.path.realpath(f)
            f.rename(t)
            self.mine = {(os.path.realpath(t) + k[len(was):] if k.startswith(was + "/") else k): v for k, v in self.mine.items()}
            for x in t.rglob("*"):
                if x.is_file() and not x.is_symlink():
                    self.mine[os.path.realpath(x)] = ("f", x.read_bytes())
            os.symlink(t, f)
            self.mine[os.path.join(os.path.realpath(f.parent), f.name)] = ("l", str(t))
            return f"moves {f.name} away"
        if k < 0.93:  # a list tampered with, naming the person's things outside the program with their very sums
            m = self.real(".local/lib/app/.manifest")
            if m.is_file() and not m.is_symlink():
                with open(m, "a") as f:
                    for rp, v in list(self.mine.items())[:6]:
                        rel = os.path.relpath(rp, os.path.realpath(self.h))
                        if v[0] == "f" and not rel.startswith(".local/lib/app/") and rel not in (".local/share/applications/app.desktop", ".local/share/icons/hicolor/256x256/apps/app.png", ".local/bin/app-uninstall"):
                            f.write(f"{sha(v[1])}  ~/{rel}\n{sha(v[1])}  ../../../{rel}\n{sha(v[1])}  {rp}\n")
                return "tampers with the list"
            return "nothing"
        m = self.real(".local/lib/app/.manifest")
        if m.is_file():
            m.unlink()
        return "deletes the list"

    def run(self, cmd, kill):
        e = self.env
        p = subprocess.Popen([str(cmd)], env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        if kill:
            time.sleep(self.r.random() * 0.12)
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        out = p.communicate()[0]
        return p.returncode, out

    def step(self):
        k = self.r.random()
        if k < 0.45:
            self.log.append("the person " + self.person())
        else:
            kill = self.r.random() < 0.25
            before = picture(self.h)
            if k < 0.85:
                v = self.r.choice([1, 2, 2, 3])
                src = W / f"v{v}"
                if self.r.random() < 0.15:  # (from a copy that lies at one of its own places, or beside the person's things)
                    self.n += 1
                    src = self.real(self.r.choice([".local/share/app", ".local/lib/app", ".config/app/pkg", f"pkg{self.n}", ".local/share/app/pkg"]))
                    try:
                        for f in (W / f"v{v}").rglob("*"):
                            if f.is_file():
                                q = src / f.relative_to(W / f"v{v}")
                                q.parent.mkdir(parents=True, exist_ok=True)
                                if not q.exists() and not q.is_symlink():
                                    shutil.copy(f, q)
                    except OSError:
                        pass
                    before = picture(self.h)
                if not (src / "install.sh").is_file():
                    return
                rc, out = self.run(src / "install.sh", kill)
                what = f"installs {src}"
                if rc not in (0, -9) and "nothing was changed" in out:
                    assert picture(self.h) == before, f"it said that nothing was changed: {out}"
                elif rc not in (0, -9):
                    raise AssertionError(f"stopped in the middle: {rc} {out}")
            else:
                u = self.real(".local/bin/app-uninstall")
                if not u.is_file() or u.is_symlink() or b"the person" in u.read_bytes() or not os.access(u, os.X_OK):
                    return
                if b"its installer wrote" not in u.read_bytes():
                    return
                rc, out = self.run(u, kill)
                what = "uninstalls"
            self.log.append(f"{what}{' (killed)' if kill else ''}: {rc} {(out.strip().splitlines() or [''])[0][:120]}")
        for rp, v in self.mine.items():
            now = ("l", os.readlink(rp)) if os.path.islink(rp) else (("f", Path(rp).read_bytes()) if os.path.isfile(rp) else None)
            assert now == v, f"the person's {rp} was {v[1]!r}, is {now}"


def main():
    seeds, first = int(sys.argv[1]) if len(sys.argv) > 1 else 60, int(sys.argv[2]) if len(sys.argv) > 2 else 1
    steps = 0
    for seed in range(first, first + seeds):
        w = World(seed)
        try:
            for _ in range(30):
                w.step()
                steps += 1
        except AssertionError as e:
            print(f"seed {seed}: {e}")
            print("\n".join("  " + x for x in w.log))
            print("install_property: BAD")
            return 1
        shutil.rmtree(w.h)
    print(f"    {seeds} HOMEs, {steps} steps")
    print("install_property: ok")
    return 0


rc = main()
shutil.rmtree(W, ignore_errors=True)
sys.exit(rc)
