"""Run examples/agentchat against a scripted AG-UI scenario and take a picture (a dev tool for goal 48).

  pixi run python scripts/agui_shot.py gtk catalog "type:Message=Show every component;tap:Send;pause:2500" build/shot.png
Prints the run's LABEL lines' tail and the RunAgentInputs the agent got.
"""

import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def main():
    host, scenario, steps, shot = sys.argv[1:5]
    import headless
    headless.ensure()
    spec = importlib.util.spec_from_file_location("g35", ROOT / "docs/goals/35-check.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    out, inputs = g.chat_run(host, scenario, steps, shot=shot)
    labels = [l for l in out.splitlines() if l.startswith("LABEL: ")]
    print("\n".join(labels[-40:]))
    print(f"RUNS: {len(inputs)}")
    for i in inputs[-2:]:
        print("STATE:", json.dumps(i.get("state"))[:300])
        tools = [m for m in i.get("messages", []) if m.get("role") == "tool"]
        print("TOOL RESULTS:", [t.get("content", "")[:120] for t in tools])


if __name__ == "__main__":
    main()
