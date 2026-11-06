"""Goal 54 M3: omxplorer's web build in headless Chromium (scripts/drive.py): the fleet opened, a table card and a chart
inserted, the table card closed; the Board's cards read from the page after each change (their boxes as the browser
lays them out), then a 1440×900 shot. Prints "WEB: <step> overlaps=N cards=K" lines and a last summary line; exits 1
on an overlap.

    pixi run python docs/goals/54-web.py OUT.png
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import drive  # noqa: E402

FULL = ROOT / "build/g47/full"
CARDS = """() => [...document.querySelectorAll('.board > [data-tag]')].map(e => { const r = e.getBoundingClientRect();
  return [e.dataset.tag, Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]; })"""


def overlaps(cards):
    n = 0
    for i in range(len(cards)):
        for j in range(i + 1, len(cards)):
            _, ax, ay, aw, ah = cards[i]
            _, bx, by, bw, bh = cards[j]
            if ax < bx + bw - 1 and bx < ax + aw - 1 and ay < by + bh - 1 and by < ay + ah - 1:
                n += 1
    return n


def main():
    shot = sys.argv[1]
    seen = []

    def read(page, label):
        cards = page.evaluate(CARDS)
        seen.append((label, cards))
        return f"WEB: {label} overlaps={overlaps(cards)} cards={len(cards)} " + "; ".join(f"{c[0]} {c[1]},{c[2]} {c[3]}x{c[4]}" for c in cards)

    def during(page):
        out = [read(page, "table")]
        drive.step(page, f"pick:Table={FULL / 'limits.csv'}")
        page.locator('[data-tag="close-limits"]').first.wait_for(state="attached", timeout=60000)  # (the card landed)
        drive.step(page, "wait:800")
        drive.settle(page)
        out.append(read(page, "card"))
        for s in ["tap:Chart", "wait:1000"]:
            drive.step(page, s)
            drive.settle(page)
        out.append(read(page, "chart"))
        for s in ["tap:close-limits", "wait:1000"]:
            drive.step(page, s)
            drive.settle(page)
        out.append(read(page, "closed"))
        return "\n".join(out) + "\n"

    r, out = drive.web_run(ROOT / "build/omxplorer/web", f"pick:Choose a file={FULL / 'fleet.csv'};wait:Create table;tap:Create table;wait:1500",
                           shot=shot, viewport=(1440, 900), color_scheme="light", during=during)
    print("\n".join(l for l in out.splitlines() if l.startswith(("WEB:", "SHOT:", "CSP:"))))
    bad = [l for l, c in seen if overlaps(c)]
    counts = [len(c) for _, c in seen]
    if r.returncode or bad or len(seen) != 4 or not (counts[1] == counts[0] + 1 and counts[2] == counts[1] + 1 and counts[3] == counts[2] - 1):
        print(f"web: returncode {r.returncode}, overlaps at {bad}, cards {counts}\n" + out[-1500:])
        sys.exit(1)
    print(f"web: cards {counts} through open, insert, chart, close; no overlap; {shot}")


if __name__ == "__main__":
    main()
