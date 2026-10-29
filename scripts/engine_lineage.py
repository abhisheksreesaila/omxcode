"""Which omxcore engine (MX frame until its F-165 rename) is vendored, proved without byte equality (D-269): each stable commit includes the ones
before it (STABLE.md), and the package doesn't build byte for byte the same twice (two builds of 321870f differ by a
byte in size and ~400K bytes inside), so "vendor is the archive's build" means:
  - vendor/OMXCORE_COMMIT names the pinned commit or a later stable one;
  - build/omxcore-src holds exactly that commit's `git archive` (diffed file by file) and a package built from it;
  - vendor/omxcore.mojoc is that build's size within 0.1 % (builds of one commit differ by bytes; the stable
    commits' packages by megabytes: 2.2 MB at 1889b7f, 4.0 MB at 321870f)."""
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
LINEAGE = ["7cbcc04", "1889b7f", "321870f", "23edc59", "3d2455d", "2585dc9", "8017543", "5053a44", "5e4cdb1", "834ef9a"]
def engine_repo():
    """The omxcore checkout to read archives from: $OMXCORE_REPO (or the older $MXFRAME_REPO), else the first of
    ../../mxframe (next to the mxapp folder) and ~/Projects/mxframe that is a git checkout (a worktree elsewhere has
    no ../../mxframe: the 2026-10-29 regression's lesson)."""
    for v in ("OMXCORE_REPO", "MXFRAME_REPO"):
        if os.environ.get(v):
            return Path(os.environ[v])
    for p in (ROOT.parent.parent / "mxframe", Path.home() / "Projects" / "mxframe"):
        if (p / ".git").exists():
            return p
    return ROOT.parent.parent / "mxframe"


REPO = engine_repo()


def vendored_at_least(pin):
    """None when the vendored engine is `pin` or a later stable commit and is proved built from its archive; else why not."""
    commit = (ROOT / "vendor/OMXCORE_COMMIT").read_text().splitlines()[0]
    named = commit.split("(")[0]
    later = [c for c in LINEAGE[LINEAGE.index(pin):] if c in named]
    if not later:
        return f"vendor/OMXCORE_COMMIT isn't {pin} or a later stable commit: {commit[:120]}"
    want = later[0]
    src = BUILD / "omxcore-src"
    built = src / "build" / "omxcore.mojoc"
    if not built.exists():
        return "build/omxcore-src has no package built from the archive (the rebuild line in vendor/OMXCORE_COMMIT)"
    if not (REPO / ".git").exists():
        return f"no omxcore checkout at {REPO} ($OMXCORE_REPO) to compare build/omxcore-src with {want}'s archive"
    with tempfile.TemporaryDirectory() as tmp:
        a = subprocess.run(f"git -C {REPO} archive {want} mojo kernels_aot scripts/build_mojo_pkg.sh | tar -x -C {tmp}",
                           shell=True, capture_output=True, text=True)
        if a.returncode != 0:
            return f"git archive {want} failed: {a.stderr[-200:]}"
        d = subprocess.run(["diff", "-rq", "-x", "build", "-x", ".omxcore-pkg.lock", "-x", ".mxframe-pkg.lock", "-x", "__pycache__", tmp, str(src)],
                           capture_output=True, text=True)
        if d.returncode != 0:
            return f"build/omxcore-src isn't {want}'s archive: {d.stdout[:200]}"
    vs, bs = (ROOT / "vendor/omxcore.mojoc").stat().st_size, built.stat().st_size
    if abs(vs - bs) > bs * 0.001:
        return f"vendor/omxcore.mojoc ({vs:,} bytes) isn't a build of {want} (its archive builds {bs:,})"
    return None
