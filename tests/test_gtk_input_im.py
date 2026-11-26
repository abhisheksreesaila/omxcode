"""The merge of goals 79 and 81 (D-8202): goal 81's M4 bursts with the input method's words among them. Goal 81 holds keys
while a rebuild waits; goal 79 sends keys through the input method first, and its commits come back as words (on_im_commit
→ canvas_words), held too. Every burst of tests/test_gtk_input.py gets one commit of a single letter ("canvas=iX": the
canvas's GtkIMMulticontext emits commit), first (nothing waits yet) or last (a rebuild waits: held). The input app doesn't
take words (App.takes_text), so Runtime.commit makes it the key X, which update() must hear once, in its place, then the composition's end
(IME_PREEDIT "", goal 79's on_im_commit).
The same judge and bars as goal 81's M4 (tests/test_gtk_input.py, its seeds, its app); only the bursts gain the commit.
Run: pixi run python tests/test_gtk_input_im.py [--no-build] [seeds]
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_gtk_input as t

_make = t.make
# (goal 79) a commit ends the composition: IME_PREEDIT with "" follows it (on_im_commit); its number as view.mojo has it
PREEDIT = int(re.search(r"^comptime IME_PREEDIT = (\d+)", (Path(t.ROOT) / "mojoui/view.mojo").read_text(), re.M)[1])
commits = [0, 0]  # first, last


def make(rng, model, words):
    items, want, now = _make(rng, model, words)
    if len(items) >= 2:
        c = rng.choice("ijklmnop")
        exp = [(t.CANVAS, c, t.KEY), (t.CANVAS, None, PREEDIT)]
        if rng.random() < 0.5:
            items, want = [f"canvas=i{c}"] + items, exp + want
            commits[0] += 1
        else:
            items, want = items + [f"canvas=i{c}"], want + exp
            commits[1] += 1
    return items, want, now


if __name__ == "__main__":
    t.make = make
    rc = t.main()
    print("FACT commits_first", commits[0])
    print("FACT commits_held", commits[1])
    if commits[1] < 50:
        print("gtk_input_im: FAIL (too few held commits)")
        rc = 1
    sys.exit(rc)
