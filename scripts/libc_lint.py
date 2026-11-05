"""Fails when a mojoui file declares a libc function that mojoui/libc.mojo owns (goal 50 M0, D-4760).

Mojo allows one signature per external symbol per binary, so mojoui declares the functions Flare (vendor/flare) and
other libraries also declare in one place, with their types. A second `external_call["recv", ...]` elsewhere in mojoui
compiles on its own and breaks the first app that links Flare too. Also lists any libc symbol vendor/flare declares that
mojoui declares outside mojoui/libc.mojo (a new clash, before an app finds it).

    pixi run python scripts/libc_lint.py        # exit 1 and the offending lines
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CALL = re.compile(r'external_call\[\s*"([A-Za-z_0-9]+)"')
SKIP = {"mojoui/libc.mojo", "mojoui/hosts/mojo_rt.mojo"}  # (mojo_rt: the iPhone runtime stand-ins, never with Flare)
# Declared the same way in every mojoui file (and by neither Flare nor the engine): dlsym(Int, C string) -> Int
SAME_EVERYWHERE = {"dlsym"}
# Declared in the omxcore engine's form on purpose: file -> symbols (none since goal 52: the engine's patch looks the
# disputed functions up, and framefeed starts its thread through mojoui.libc)
ENGINE_FORM = {}


def names(paths):
    out = set()
    for p in paths:
        out |= set(CALL.findall(p.read_text(errors="replace")))
    return out


def main():
    owned = names([ROOT / "mojoui/libc.mojo"])
    flare = names(list((ROOT / "vendor/flare").rglob("*.mojo")) + list((ROOT / "vendor/json").rglob("*.mojo")))
    engine = set()
    # the vendored engine's sources as built (build/omxcore-src: its archive with vendor/patches applied), else the
    # unpatched archives other checkouts left in ~/.cache
    built = ROOT / "build" / "omxcore-src"
    for d in [built] if (built / "mojo").exists() else sorted(Path.home().joinpath(".cache").glob("omxcore-*-src")):
        engine |= names(list((d / "mojo").rglob("*.mojo")))
    watch = (owned | flare | (engine & (owned | flare))) - SAME_EVERYWHERE
    bad = []
    for p in sorted((ROOT / "mojoui").rglob("*.mojo")):
        rel = p.relative_to(ROOT).as_posix()
        if rel in SKIP:
            continue
        for i, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            for name in CALL.findall(line):
                if name in watch and name not in ENGINE_FORM.get(rel, ()):
                    bad.append(f"{rel}:{i}: external_call[\"{name}\"]: call mojoui.libc.{name} (add it there with Flare's types)")
    if bad:
        print("\n".join(bad))
        sys.exit(1)
    print(f"libc lint: ok ({len(owned)} functions in mojoui/libc.mojo, {len(flare)} declared by vendor/flare)")


if __name__ == "__main__":
    main()
