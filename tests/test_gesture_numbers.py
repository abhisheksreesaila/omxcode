"""The merge of goals 79 and main (D-8210): a canvas event's kind (event.number) is one number for one meaning. Goal 79 gave
HOVER, IME_COMMIT, IME_PREEDIT and PASTE 11–14 while main gave the free Board's events and HOVER 11–15; keeping both sides
compiled and was wrong (a board's live drag would have arrived as a hover). Fails when two of mojoui/view.mojo's event kinds
share a number, when a shipped number moves (apps, web pages and saved test steps know them), or when a module keeps its own
copy of one (goal 81's gtk_held kept HOVER = 11: after the merge it would have joined board drags as pointer moves).
Run: pixi run python tests/test_gesture_numbers.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KINDS = ["PAN", "ZOOM", "TAP", "PRESS", "RELEASE", "DOUBLE", "KEY", "SECONDARY", "WHEEL", "SET_TO", "HOVER", "BOARD_LIVE", "BOARD_ZOOM",
         "BOARD_VIEW", "BOARD_PICK", "IME_COMMIT", "IME_PREEDIT", "PASTE", "PASTE_FILE"]
SHIPPED = {"PAN": 1, "ZOOM": 2, "TAP": 3, "PRESS": 4, "RELEASE": 5, "DOUBLE": 6, "KEY": 7, "SECONDARY": 8, "WHEEL": 9, "SET_TO": 10,
           "BOARD_LIVE": 11, "BOARD_ZOOM": 12, "BOARD_VIEW": 13, "HOVER": 14, "BOARD_PICK": 15}  # (main, as released)

view = (ROOT / "mojoui/view.mojo").read_text()
bad = []
nums = {}
for k in KINDS:
    m = re.findall(rf"^comptime {k} = (\d+)\b", view, re.M)
    if len(m) != 1:
        bad.append(f"{k}: {len(m)} definitions in view.mojo")
        continue
    nums[k] = int(m[0])
seen = {}
for k, n in nums.items():
    if n in seen:
        bad.append(f"{k} and {seen[n]} are both {n}")
    seen[n] = k
for k, n in SHIPPED.items():
    if nums.get(k) != n:
        bad.append(f"{k} moved: {nums.get(k)}, shipped as {n}")
# no copies elsewhere (a module that needs one imports it from mojoui.view)
names = "|".join(KINDS)
for p in list((ROOT / "mojoui").rglob("*.mojo")) + list((ROOT / "hosts").rglob("*.mojo")):
    if p.name == "view.mojo":
        continue
    for m in re.finditer(rf"^comptime ({names}) = (\d+)", p.read_text(), re.M):
        bad.append(f"{p.relative_to(ROOT)}: its own {m[1]} = {m[2]}")
# the web host's JavaScript names them too
js = (ROOT / "mojoui/hosts/web.py").read_text()
for m in re.finditer(r"\b(" + names + r") = (\d+)", js):
    if nums.get(m[1]) != int(m[2]):
        bad.append(f"web.py: {m[1]} = {m[2]}, view.mojo says {nums.get(m[1])}")
for b in bad:
    print("BAD ", b)
print("gesture numbers: ok" if not bad else "gesture numbers: FAIL")
sys.exit(1 if bad else 0)
