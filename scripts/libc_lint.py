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
    # a thread id written through a local's address handed over as an Int: the compiler may keep reading the local's
    # old value (goal 52: the engine's fan joined thread 0 and crashed; framefeed had the same line). Write it into a
    # buffer (List[Int], unsafe_alloc) instead.
    # Any plain local's address handed on as an Int is caught (the class, not only pthread_create; review round 2); a
    # buffer C only reads may say so with "(read only)" on the line.
    LOCAL_AS_INT = re.compile(r"Int\(\s*Pointer\(\s*to\s*=\s*[A-Za-z_][A-Za-z_0-9]*\s*\)\s*\)")
    roots = [ROOT / "mojoui", ROOT / "examples", ROOT / "tests"] + ([built / "mojo"] if (built / "mojo").exists() else [])
    for r in roots:
        for p in sorted(r.rglob("*.mojo")):
            for i, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
                if LOCAL_AS_INT.search(line) and "(read only)" not in line:
                    bad.append(f"{p}:{i}: a local's address as an Int (C may write it and the compiler not see it): use a buffer (List / unsafe_alloc), or mark a buffer C only reads \"(read only)\"")
    if bad:
        print("\n".join(bad))
        sys.exit(1)
    print(f"libc lint: ok ({len(owned)} functions in mojoui/libc.mojo, {len(flare)} declared by vendor/flare)")


if __name__ == "__main__":
    main()
