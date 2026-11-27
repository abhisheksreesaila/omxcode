"""The web Personal Note's own Jam validator on docs/goals/82/jam-cases.json (goal 82 M6's yardstick): one JSON line per
case, the same shape tests/test_jam prints ("map" is filled in by web_jam_apply.mjs). Imports ~/Projects/personalnotev2's
jam_brain by path; writes nothing there (no bytecode).
    python3 -I docs/goals/82/web_jam.py <web folder> <cases.json>"""
import json
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import jam_brain  # noqa: E402

wire = {jam_brain.AddBranch: lambda e: {"op": "add_branch", "parentId": e.parent_id, "text": e.text, "emoji": e.emoji, "id": e.id},
        jam_brain.React: lambda e: {"op": "react", "nodeId": e.node_id, "vote": e.vote, "reason": e.reason},
        jam_brain.Ghost: lambda e: {"op": "ghost", "parentId": e.parent_id, "text": e.text, "why": e.why}}
for i, case in enumerate(json.load(open(sys.argv[2]))):
    try:
        edits = jam_brain.parse_edits(case["reply"], case["map"])
        print(json.dumps({"case": i, "ok": True, "wire": [wire[type(e)](e) for e in edits.edits], "dropped": edits.dropped}, ensure_ascii=False))
    except jam_brain.JamError as error:
        print(json.dumps({"case": i, "ok": False, "error": str(error)}, ensure_ascii=False))
print(json.dumps({"prompt": jam_brain.build_user_prompt(json.load(open(sys.argv[2]))[0]["map"], "  we should eat seafood  ", ["Day trips"])}, ensure_ascii=False))
