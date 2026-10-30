"""Accessibility check: every host hands a view's screen-reader name (mojoui.a11y) to its platform, read back from the
platform itself, not from our own tree. Prints PASS/FAIL per part; exit 1 on any FAIL.

  pixi run python scripts/check_a11y.py          (builds examples/a11ycheck for linux and web first)
  pixi run python scripts/check_a11y.py --no-build

core:  tests/test_a11y.mojo (the naming rule, the audit, a label's diff)
gtk:   GTK's test accessibility backend (GTK_A11Y=test) reports the label each control carries; the unnamed slider has none
web:   Chromium's accessibility tree (Playwright's aria snapshot) names each control; the drawn chart is an image named by
       its words, and the name follows the words when they change in place (a patch, no rebuild)
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402
import drive  # noqa: E402

APP = ROOT / "build/a11ycheck"
SUM = "Sum of amount by region, as bars"
AVG = "Average of amount by region, as bars"


def run(cmd, env=None, timeout=1800):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)
    return r.returncode, r.stdout + r.stderr


def core():
    code, out = run(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_a11y.mojo"])
    return code == 0 and "a11y: OK" in out, "tests/test_a11y.mojo: " + ("a11y: OK" if "a11y: OK" in out else out[-400:])


def gtk():
    headless.ensure()
    env = dict(os.environ, MOJOUI_TEST="a11y;tap:Rename;a11y", GTK_A11Y="test")
    code, out = run([str(APP / "linux/a11ycheck")], env=env, timeout=120)
    lines = [l for l in out.splitlines() if l.startswith("A11Y")]
    want = [
        "A11Y: 1 unnamed",
        "A11Y UNNAMED: SLIDER #7 (zoom): no name",
        "A11Y GTK LABEL: #7 none",
        "A11Y LABEL: #5 region = Region (ok)",
        f"A11Y LABEL: #8 chart = {SUM} (ok)",
        f"A11Y LABEL: #8 chart = {AVG} (ok)",
    ]
    missing = [w for w in want if w not in lines]
    bad = [l for l in lines if "(GTK:" in l]
    ok = code == 0 and not missing and not bad
    return ok, "GTK: " + ("labels as GTK reports them: " + "; ".join(l.split(": ", 1)[1] for l in lines[:5]) if ok else f"exit {code}; missing {missing}; differs {bad}")


def web():
    snaps = []

    def during(page):
        snaps.append(page.locator("body").aria_snapshot())
        page.get_by_role("button", name="Rename").click()
        page.wait_for_function(f"() => document.querySelector('canvas[aria-label=\"{AVG}\"]') !== null", timeout=10000)
        snaps.append(page.locator("body").aria_snapshot())
        return ""

    r, out = drive.web_run(APP / "web", "", during=during)
    if len(snaps) < 2:
        return False, "web: no accessibility tree: " + out[-400:]
    before, after = snaps
    want = ['button "Delete"', 'button "Rename"', 'combobox "Region"', 'textbox "Search"', f'img "{SUM}"']
    missing = [w for w in want if w not in before]
    slider = re.search(r"^\s*- slider(.*)$", before, re.M)
    unnamed_slider = slider is not None and '"' not in slider.group(1).split(":")[0]
    followed = f'img "{AVG}"' in after and f'img "{SUM}"' not in after
    ok = not missing and unnamed_slider and followed
    return ok, "web: " + ("Chromium names " + ", ".join(want[:4]) + f", the chart as img; after Rename: img \"{AVG}\"; the slider stays unnamed"
                          if ok else f"missing {missing}; slider unnamed {unnamed_slider}; followed {followed}\n{before}\n---\n{after}")


def main():
    if "--no-build" not in sys.argv:
        for target in ("linux", "web"):
            code, out = run(["scripts/build.sh", "a11ycheck", target])
            if code != 0:
                print(f"FAIL build {target}: {out[-600:]}")
                return 1
    failed = False
    for name, part in (("core", core), ("gtk", gtk), ("web", web)):
        ok, why = part()
        failed |= not ok
        print(("PASS " if ok else "FAIL ") + name + ": " + why, flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
