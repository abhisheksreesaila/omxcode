# Pictures of omxconsole for its cover page and its gallery card, from the real app: the console on GTK (headless) against
# a consoled on a throwaway home (build/g55/home-shots: no benchmark there, so no tokens per second in any column), where
# the console itself finds and downloads Qwen2.5-0.5B, then one key made for the Keys page. No speed or times in any
# picture (docs/lessons.md, D-4762): the Ready picture is only its "is serving" card (see crop()).
# The model is stopped before the other pages are taken: the Beacon then shows the GPU's memory, not a live tok/s.
#   pixi run python scripts/console_shots.py [places|crop] -> build/g55/shots/*.png and docs/gallery/img/omxconsole-*.png
#   (places: only the pages after Add, on the home the last run filled; crop: only the crops, from the last shots)
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("check55", ROOT / "docs/goals/55-check.py")
c = importlib.util.module_from_spec(spec)
sys.modules["check55"] = c
spec.loader.exec_module(c)

OUT = ROOT / "build/g55/shots"
OUT.mkdir(parents=True, exist_ok=True)
ADD = f"""
window:1440x900
wait:4000
tap:Add a model
wait:2500
enter:Search models=qwen2.5
wait:8000
shot:{OUT}/find.png
tap:qwen2.5-0.5b
waitfor:Open=900000
wait:1500
shot:{OUT}/ready.png
"""
STEPS = f"""
window:1440x900
wait:4000
shot:{OUT}/models.png
tap:Keys
wait:2500
shot:{OUT}/keys.png
tap:Gateway
wait:2500
shot:{OUT}/gateway.png
tap:Security
wait:2000
shot:{OUT}/security.png
tap:Settings
wait:2000
shot:{OUT}/settings.png
"""


def main():
    if sys.argv[1:] != ["crop"]:
        take()
    crop()


def take():
    import headless
    headless.ensure()
    with c.Daemon(c.G55 / "home-shots") as d:
        if sys.argv[1:] != ["places"]:
            f = OUT / "add.steps"
            f.write_text(ADD)
            ok, out = c.console(f, d, OUT / "add-end.png", timeout=1200)
            print("add", "ok" if ok else "FAILED", out[-600:] if not ok else "")
        s, j = c.body(d.call("POST", "/admin/keys", {"app": "my-app"}))
        print("key my-app:", s)
        s, j = c.body(d.call("POST", "/admin/models/qwen2.5-0.5b/stop"))
        print("model stopped:", s)
        for name, steps in (("places", STEPS),):
            f = OUT / f"{name}.steps"
            f.write_text(steps)
            ok, out = c.console(f, d, OUT / f"{name}-end.png", timeout=300)
            print(name, "ok" if ok else "FAILED", out[-600:] if not ok else "")


def crop():
    """Ready: only its "is serving" card (the endpoint and a curl line), no stage times (D-4762) and nothing that depends on
    how much of the model was already on disk; My models and Keys down to where their content ends (a fresh install has
    one model and one key: the rest of the window is empty)."""
    from PIL import Image
    img = ROOT / "docs/gallery/img"
    for name, box in (("models", (0, 0, 1440, 660)), ("find", (0, 0, 1440, 900)), ("ready", (0, 590, 720, 825)), ("keys", (0, 0, 1440, 420))):
        out = Image.open(OUT / f"{name}.png").crop(box)
        out.save(img / f"omxconsole-{name}.png", optimize=True)
        print("wrote", img / f"omxconsole-{name}.png", out.size)


if __name__ == "__main__":
    main()
