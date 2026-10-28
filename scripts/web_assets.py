"""An app's JavaScript and CSS for the web, built and checked (goal 34; docs/js.md). scripts/build.sh runs it after the
web module is built, for every app.

  pixi run python scripts/web_assets.py <example>          build, then lint
  pixi run python scripts/web_assets.py --lint <example>   the lint only
  pixi run python scripts/web_assets.py --webview <dir> <example>   GTK: the same bundles into <dir>/assets, and the
                                                           host's widget runtime beside them (nothing for an app without)

Build: an app with examples/<example>/web/package.json gets its packages installed from the committed lockfile
(`npm ci --ignore-scripts`: no package runs code at install time) into build/<example>/npm/ (never next to the app, never
in git); then esbuild bundles and minifies each entry in examples/<example>/web/widgets/ (*.js, *.ts, *.css) offline,
and each output is saved as build/<example>/web/assets/<name>.<sha256[:16]>.<ext> with manifest.json mapping the name the
app lists (counter.js; editor.ts → editor.js) to that file, its SRI integrity and its source.

Lint (fails the build): every name App.web_assets() lists is a bundled asset; every bundled asset is listed; every file
in assets/ is one the bundler made, with the bytes its name's hash says. MOJOUI_ASSETS_LISTED (a JSON list) stands in for
web_assets() in checks.
"""

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENTRY_TYPES = {".js": ".js", ".ts": ".js", ".mjs": ".js", ".css": ".css"}


def fail(msg):
    print(f"web_assets: {msg}", file=sys.stderr)
    sys.exit(1)


def tool(name):
    path = shutil.which(name)
    if not path:
        fail(f"{name} isn't on PATH (run through pixi: Node and esbuild come from conda-forge)")
    return path


def install(example, web):
    """npm ci from the committed lockfile into build/<example>/npm/; skipped when the lockfile hasn't changed."""
    pkg, lock = web / "package.json", web / "package-lock.json"
    if not pkg.exists():
        return None
    if not lock.exists():
        fail(f"{pkg.relative_to(ROOT)} has no package-lock.json beside it (npm install once, then commit the lockfile)")
    npm_dir = ROOT / "build" / example / "npm"
    stamp = npm_dir / "lock.sha256"
    want = hashlib.sha256(pkg.read_bytes() + lock.read_bytes()).hexdigest()
    if stamp.exists() and stamp.read_text() == want and (npm_dir / "node_modules").exists():
        return npm_dir / "node_modules"
    npm_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(pkg, npm_dir / "package.json")
    shutil.copy(lock, npm_dir / "package-lock.json")
    r = subprocess.run([tool("npm"), "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--prefer-offline", "--loglevel=error"],
                       cwd=npm_dir, capture_output=True, text=True)
    if r.returncode != 0:
        fail("npm ci failed:\n" + (r.stdout + r.stderr)[-1500:])
    stamp.write_text(want)
    return npm_dir / "node_modules"


def build(example, out=None):
    web = ROOT / "examples" / example / "web"
    out = out or ROOT / "build" / example / "web" / "assets"
    shutil.rmtree(out, ignore_errors=True)  # (only what this build makes ships)
    entries = sorted(p for p in (web / "widgets").glob("*") if p.suffix in ENTRY_TYPES) if (web / "widgets").is_dir() else []
    if not entries:
        return False
    modules = install(example, web)
    names = {}
    for p in entries:
        name = p.stem + ENTRY_TYPES[p.suffix]
        if name in names:
            fail(f"{p.name} and {names[name].name} both make {name}")
        names[name] = p
    out.mkdir(parents=True)
    manifest = {}
    with tempfile.TemporaryDirectory(prefix="web-assets-") as tmp:
        env = dict(os.environ, NODE_PATH=str(modules) if modules else "")
        debug = os.environ.get("MOJOUI_DEBUG") == "1"  # (a debug build: each bundle gets a source map, goal 34b M1c; release has none)
        cmd = [tool("esbuild"), *[str(p) for p in entries], "--bundle", "--minify", "--format=iife", "--target=es2020",
               "--platform=browser", "--charset=utf8", "--legal-comments=eof", f"--outdir={tmp}", "--entry-names=[name]",
               "--log-level=warning", *(["--sourcemap=linked", "--sources-content=false"] if debug else [])]
        r = subprocess.run(cmd, cwd=web, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            fail("esbuild failed:\n" + (r.stdout + r.stderr)[-2000:])
        for name, src in names.items():
            data = (Path(tmp) / name).read_bytes()
            stem, ext = name.rsplit(".", 1)
            map_file = None
            if debug and (Path(tmp) / (name + ".map")).exists():
                data, map_file = with_map(Path(tmp), name, data, web, modules, out)
            digest = hashlib.sha256(data).hexdigest()[:16]
            file = f"{stem}.{digest}.{ext}"
            (out / file).write_bytes(data)
            manifest[name] = {"file": file, "integrity": "sha384-" + base64.b64encode(hashlib.sha384(data).digest()).decode(),
                              "source": str(src.relative_to(web)), "bytes": len(data)}
            if map_file:
                manifest[name]["map"] = map_file
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    for name, m in sorted(manifest.items()):
        print(f"   assets/{m['file']}  ({m['bytes'] // 1024} KB, from web/{m['source']})")
    return True


def with_map(tmp, name, data, web, modules, out):
    """(debug builds) The bundle's source map, its sources named from the app's web/ folder (widgets/editor.ts) or npm
    (npm/@codemirror/view/…), saved by its own content hash; the bundle's last line names it. Returns (bundle, map file)."""
    m = json.loads((tmp / (name + ".map")).read_text())
    named = []
    for src in m.get("sources", []):
        full = (tmp / src).resolve()
        if full.is_relative_to(web.resolve()):
            named.append(str(full.relative_to(web.resolve())))
        elif modules and full.is_relative_to(Path(modules).resolve()):
            named.append("npm/" + str(full.relative_to(Path(modules).resolve())))
        else:
            named.append(full.name)
    m["sources"] = named
    m.pop("sourceRoot", None)
    body = json.dumps(m, separators=(",", ":")).encode()
    stem, ext = name.rsplit(".", 1)
    map_file = f"{stem}.{hashlib.sha256(body).hexdigest()[:16]}.{ext}.map"
    (out / map_file).write_bytes(body)
    text = data.decode()
    cut = max(text.rfind("//# sourceMappingURL="), text.rfind("/*# sourceMappingURL="))
    if cut >= 0:
        text = text[:cut].rstrip("\n")
    text += f"\n/*# sourceMappingURL={map_file} */\n" if ext == "css" else f"\n//# sourceMappingURL={map_file}\n"
    return text.encode(), map_file


def webview(example, folder):
    """GTK's copy (goal 34 M3): the same esbuild bundles (same inputs, same bytes, same hashed names) into
    <folder>/assets, and the web host's widget runtime (mojoui-widgets.js) and style sheet (mojoui.css) beside them. The GTK host serves these to
    each WebComponent's WebKitGTK view and nothing else; it loads only what App.web_assets() lists (the lint runs with
    the web build, which reads that list from the web module)."""
    shutil.rmtree(folder, ignore_errors=True)
    if build(example, folder / "assets"):
        for name in ("mojoui-widgets.js", "mojoui.css"):  # (the web host's widget runtime and its style sheet, as they are)
            shutil.copy(ROOT / "mojoui" / "hosts" / "static" / name, folder / name)
        print(f"web_assets: {example}: bundles for GTK's web views in {folder.relative_to(ROOT) if folder.is_relative_to(ROOT) else folder}")


def listed(example):
    """What App.web_assets() lists (the built web module), or MOJOUI_ASSETS_LISTED."""
    if os.environ.get("MOJOUI_ASSETS_LISTED"):
        return json.loads(os.environ["MOJOUI_ASSETS_LISTED"])
    module_dir = ROOT / "build" / example / "web"
    code = ("import json, sys; sys.path.insert(0, sys.argv[1]); import mojoui_app as m; "
            "print(m.web_assets() if hasattr(m, 'web_assets') else '[]')")
    r = subprocess.run([sys.executable, "-c", code, str(module_dir)], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"couldn't read web_assets() from {module_dir}: " + (r.stdout + r.stderr)[-600:])
    return json.loads(r.stdout.strip().splitlines()[-1])


def lint_problems(example):
    """Every problem with build/<example>/web/assets against App.web_assets() (an empty list: none)."""
    problems = []
    assets = ROOT / "build" / example / "web" / "assets"
    names = listed(example)
    manifest = json.loads((assets / "manifest.json").read_text()) if (assets / "manifest.json").exists() else {}
    for n in names:
        if "/" in n or "\\" in n or n.startswith(".") or Path(n).suffix not in (".js", ".css"):
            problems.append(f"web_assets() lists {n!r}: a bundle's name (name.js or name.css), no folders")
        elif n not in manifest:
            problems.append(f"web_assets() lists {n}, which the bundler didn't make (no web/widgets/{Path(n).stem}.js|.ts|.css)")
    for n in manifest:
        if n not in names:
            problems.append(f"{n} is bundled but web_assets() doesn't list it (an asset nobody asked for doesn't ship)")
    made = {m["file"]: m for m in manifest.values()}
    maps = {m["map"] for m in manifest.values() if m.get("map")}
    if assets.is_dir():
        for f in sorted(assets.iterdir()):
            if f.name == "manifest.json":
                continue
            if f.name in maps:  # (a debug build's source map: named by its own hash)
                if hashlib.sha256(f.read_bytes()).hexdigest()[:16] != f.name.rsplit(".", 3)[-3]:
                    problems.append(f"assets/{f.name} changed after bundling (its hash doesn't match)")
                continue
            m = made.get(f.name)
            if m is None:
                problems.append(f"assets/{f.name} wasn't produced by the bundler (not in manifest.json)")
                continue
            data = f.read_bytes()
            if hashlib.sha256(data).hexdigest()[:16] != f.name.rsplit(".", 2)[-2] or \
                    m["integrity"] != "sha384-" + base64.b64encode(hashlib.sha384(data).digest()).decode():
                problems.append(f"assets/{f.name} changed after bundling (its hash doesn't match)")
    for file in made:
        if not (assets / file).exists():
            problems.append(f"manifest.json names assets/{file}, which isn't there")
    return problems


def main():
    args = sys.argv[1:]
    if args[:1] == ["--webview"] and len(args) == 3:
        return webview(args[2], Path(args[1]).resolve())
    lint_only = "--lint" in args
    args = [a for a in args if a != "--lint"]
    if len(args) != 1:
        fail("usage: web_assets.py [--lint] <example>")
    example = args[0]
    if not (ROOT / "examples" / example).is_dir():
        fail(f"no examples/{example}")
    if not lint_only:
        build(example)
    problems = lint_problems(example)
    if problems:
        fail("the asset lint failed:\n  " + "\n  ".join(problems))
    print(f"web_assets: {example}: {len(listed(example))} asset(s), lint ok")


if __name__ == "__main__":
    main()
