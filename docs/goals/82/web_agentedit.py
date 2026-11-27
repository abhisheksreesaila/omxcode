"""The web Personal Note's own agent_edit.merge_markdown / changed_lines on docs/goals/82/agentedit-cases.json (goal 82
M6's yardstick): one JSON line per case {"case", "undo", "span"}; span only for ASCII cases (the web counts UTF-16
units, mojoui.agentedit bytes). Imports ~/Projects/personalnotev2 by path; writes nothing there.
    python3 -I docs/goals/82/web_agentedit.py <web folder> <cases.json>"""
import json
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import agent_edit  # noqa: E402

for i, c in enumerate(json.load(open(sys.argv[2]))):
    undo = agent_edit.merge_markdown(c["after"], c["now"], c["before"])
    span = agent_edit.changed_lines(c["before"], c["after"]) if (c["before"] + c["after"]).isascii() else None
    print(json.dumps({"case": i, "undo": undo, "span": [span["from"], span["to"]] if span else None}, ensure_ascii=False))
