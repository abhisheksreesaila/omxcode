"""Does every GPU kernel fit an Apple GPU's threadgroup memory? (goal 32 M6; MAX's AppleMetalFamily: 32 KB of shared
memory per threadgroup, 1024 threads.) Scans mojoui/ and the vendored MX frame's source at its commit for shared
allocations (stack_allocation[..., address_space=AddressSpace.SHARED], LayoutTensor/tile buffers in SHARED) and
block sizes, sums each function's shared bytes and prints one line per kernel. Exit 1 if any is over, or can't be sized.

  pixi run python scripts/gpu_audit.py [--mxframe PATH]   (default: ../../mxframe, the owner's checkout)
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIMIT = 32 * 1024
SIZES = {"UInt8": 1, "Int8": 1, "UInt16": 2, "Int16": 2, "Float16": 2, "BFloat16": 2, "UInt32": 4, "Int32": 4, "Float32": 4,
         "UInt64": 8, "Int64": 8, "Float64": 8, "Int": 8, "UInt": 8, "Scalar[DType.float32]": 4, "Scalar[DType.float64]": 8}
SHARED = re.compile(r"stack_allocation\[\s*([^,\]]+?)\s*,\s*([\w\[\].]+)\s*,[^\]]*address_space\s*=\s*AddressSpace\.SHARED")
COMPTIME = re.compile(r"^\s*(?:comptime|alias)\s+(\w+)\s*(?::\s*\w+)?\s*=\s*([^#\n]+)", re.M)
DEF = re.compile(r"^\s*(?:def|fn)\s+(\w+)", re.M)


def consts(texts):
    out = {}
    for text in texts:
        for name, expr in COMPTIME.findall(text):
            out.setdefault(name, expr.strip())
    return out


def evaluate(expr, known, depth=0):
    """A comptime size expression with known names substituted; None if it can't be worked out here."""
    if depth > 8:
        return None
    names = set(re.findall(r"[A-Za-z_]\w*", expr))
    for n in names:
        if n not in known:
            return None
        v = evaluate(known[n], known, depth + 1)
        if v is None:
            return None
        expr = re.sub(rf"\b{n}\b", str(v), expr)
    if not re.fullmatch(r"[\d\s+\-*/()%]+", expr):
        return None
    try:
        return int(eval(expr, {"__builtins__": {}}))  # (digits and operators only)
    except Exception:
        return None


def scan(files):
    texts = {f: f.read_text(errors="replace") for f in files}
    known = consts(texts.values())
    rows = []
    for f, text in texts.items():
        for m in SHARED.finditer(text):
            fn = [d for d in DEF.finditer(text, 0, m.start())]
            name = fn[-1].group(1) if fn else "?"
            n = evaluate(m.group(1), known)
            size = SIZES.get(m.group(2))
            line = text[:m.start()].count("\n") + 1
            rows.append((f, line, name, None if n is None or size is None else n * size, m.group(0)[:90]))
    return rows


def mxframe_files(path):
    commit = (ROOT / "vendor" / "MXFRAME_COMMIT").read_text().split(" main ")[1].split()[0]
    out = Path(tempfile.mkdtemp(prefix="mxframe-src-"))
    a = subprocess.run(f"git -C {path} archive {commit} mojo | tar -x -C {out}", shell=True, capture_output=True, text=True)
    if a.returncode != 0:
        return None, f"can't read MX frame {commit} from {path}: {a.stderr.strip()[:200]}"
    return list(out.rglob("*.mojo")), commit


if __name__ == "__main__":
    mx = Path(sys.argv[sys.argv.index("--mxframe") + 1]) if "--mxframe" in sys.argv else ROOT.parent.parent / "mxframe"
    files = list((ROOT / "mojoui").rglob("*.mojo"))
    extra, commit = mxframe_files(mx)
    problems = []
    if extra is None:
        problems.append(commit)
    else:
        files += extra
    per_fn = {}
    for f, line, name, size, src in scan(files):
        where = f"{f.name}:{line} {name}"
        if size is None:
            problems.append(f"{where}: can't size {src}")
            continue
        per_fn[(f, name)] = per_fn.get((f, name), 0) + size
        print(f"{size:>7} B  {where}")
    for (f, name), total in per_fn.items():
        if total > LIMIT:
            problems.append(f"{f.name} {name}: {total} B of shared memory, over Apple's {LIMIT}")
    print(f"{len(per_fn)} kernels with shared memory, largest {max(per_fn.values(), default=0)} B; MX frame {commit if extra else '(not read)'}")
    print("\n".join(problems) or "every kernel fits 32 KB")
    sys.exit(1 if problems else 0)
