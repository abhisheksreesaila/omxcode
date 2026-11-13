"""Goal 68 M2: a model's own code runs only with a person's recorded yes (mojoui/plugin_py.py code_allowed): plugin.json's
flag alone, a source without a commit, or another repo's record never allow it. Prints "consent: ok".
    pixi run python -I docs/goals/68/consent_test.py"""
import importlib.util
import json
import os
import sys
import tempfile

spec = importlib.util.spec_from_file_location("pp", os.path.join(os.path.dirname(__file__), "../../../mojoui/plugin_py.py"))
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)
with tempfile.TemporaryDirectory() as d:
    os.environ["OMX_CONFIG"] = os.path.join(d, "config")
    folder = os.path.join(d, "m")
    os.makedirs(folder)
    pf = {"repo": "acme/coder", "task": "feature-extraction", "kind": "embed-text", "about": "", "licence": "mit", "sha": "abc123", "remote_code": True}
    pp.write_plugin(folder, json.dumps(pf), False)  # (no yes)
    s = json.load(open(os.path.join(folder, "plugin.json")))
    assert not s["trust_remote_code"] and not pp.code_allowed(s), "no yes, no code"
    s["trust_remote_code"] = True  # (a folder that says so itself)
    assert not pp.code_allowed(s), "plugin.json's flag alone"
    pp.write_plugin(folder, json.dumps(pf), True)  # (the person's yes)
    s = json.load(open(os.path.join(folder, "plugin.json")))
    assert s["trust_remote_code"] and pp.code_allowed(s), "the yes allows it"
    other = dict(s, source="hf:acme/other@abc123")
    assert not pp.code_allowed(other), "another repo's record"
    nosha = dict(s, source="hf:acme/coder")
    assert not pp.code_allowed(nosha), "a source without a commit"
print("consent: ok")
