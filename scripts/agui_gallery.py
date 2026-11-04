"""Goal 48's example gallery: each scripted scenario run in examples/agentchat on GTK and the web at a tall size, so a
whole answer fits (docs/goals/48/ex-<scenario>-tall-<host>.png, shown in docs/agui.md).

  pixi run python scripts/agui_gallery.py [scenario …]
"""

import importlib.util
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "docs" / "goals" / "48"

SCENARIOS = [
    ("trip", "Plan a day in Lisbon", "", (1100, 1250)),
    ("dashboard", "Show me this quarter's sales", "", (1100, 1350)),
    ("booking", "Book a table for dinner", ";type:Name=Ada;slide:0=33;select:0=19:30;radio:0=Terrace;tap:Book;pause:1500", (1100, 1100)),
    ("approval", "Refund order 1042", ";tap:Approve;pause:1500", (1000, 700)),
    ("research", "Research home batteries", "", (1100, 1350)),
    ("release", "Write the release note for 2.4", "", (1000, 1150)),
    ("stream", "Build me a dashboard", "", (1100, 1350)),
    ("catalog", "Show every component", "", (1100, 2300)),
]


def main():
    import headless
    headless.ensure()
    import agui_agent
    import drive
    spec = importlib.util.spec_from_file_location("g35", ROOT / "docs/goals/35-check.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    only = sys.argv[1:]
    OUT.mkdir(parents=True, exist_ok=True)
    for name, prompt, more, (w, h) in SCENARIOS:
        if only and name not in only:
            continue
        steps = f"type:Message={prompt};tap:Send;pause:4500" + more
        os.environ["MOJOUI_WINDOW"] = f"{w}x{h}"
        try:
            g.chat_run("gtk", name, steps, shot=str(OUT / f"ex-{name}-tall-gtk.png"))
        finally:
            os.environ.pop("MOJOUI_WINDOW", None)
        with agui_agent.Server(scenario=name) as srv:
            r, out = drive.web_run(ROOT / "build" / "agentchat" / "web", f"type:Agent URL={srv.url};" + steps,
                                   shot=str(OUT / f"ex-{name}-tall-web.png"), viewport=(w, h), env={"AGUI_URL": srv.url})
        print(name, "gtk + web", "ok" if r.returncode == 0 else out[-300:])


if __name__ == "__main__":
    main()
