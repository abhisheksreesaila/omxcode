# mojoui.addmodel (goal 68 M2), without big downloads: a model that can't run says why and nothing downloads; a model
# that runs its own code asks first, and Add without the yes downloads nothing; a dropped tree file becomes a plugin and
# answers on a row; a pickle is refused. Needs the network (the Hub's API) and the models environment:
#   scripts/mxbuild.sh tests/test_addmodel.mojo -o build/g68/bin/test_addmodel && OMX_PLUGINS=build/g68/addmodel-plugins pixi run -e models build/g68/bin/test_addmodel
from std.os import listdir, makedirs
from std.os.path import exists
from std.time import sleep
from omxcore import Table, DECIMAL as MX_DECIMAL
from mojoui.app import Event
from mojoui.sheet import Sheet
from mojoui.addmodel import AddModel, S_SAID, S_READY, S_FAILED, AM_ANSWER
from mojoui.plugins import user_plugin_dir, find_plugins


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def wait(mut a: AddModel) raises:
    for _ in range(3000):
        if not a.busy():
            return
        _ = a.poll()
        sleep(0.01)
    raise Error("still busy")


def main() raises:
    makedirs(user_plugin_dir(), exist_ok=True)
    var before = len(listdir(user_plugin_dir()))
    var a = AddModel(7950, True)
    a.check("openai-community/gpt2")
    wait(a)
    print("  ", a.line)
    check(a.stage == S_SAID and not a.pf.can_run and "Nothing downloaded" in a.why, "gpt2 can't run: " + a.why)
    a.add(False)
    check(len(listdir(user_plugin_dir())) == before, "nothing downloaded for a model that can't run")
    print("addmodel-cant-run: ok")

    a.check("https://huggingface.co/nomic-ai/nomic-embed-text-v1.5")
    wait(a)
    print("  ", a.line)
    check(a.pf.can_run and a.pf.remote_code and a.needs_consent, "nomic asks first")
    a.add(False)
    check(a.stage == S_SAID and len(listdir(user_plugin_dir())) == before, "Add without the yes downloads nothing")
    _ = a.view(find_plugins(), 0, 0)
    print("addmodel-consent: ok")

    a.check("build/g68/trees/xgb_multi.json")
    print("  ", a.line)
    check(a.stage == S_READY and a.kind == "tabular", "a dropped XGBoost file: " + a.why)
    var t = Table.empty()
    var c1 = t.add_column("speed", MX_DECIMAL, 3)
    var c2 = t.add_column("person_m", MX_DECIMAL, 2)
    var c3 = t.add_column("turn_rate", MX_DECIMAL, 2)
    t.append(c1, 30)
    t.append(c2, 90)
    t.append(c3, 0)
    t.append(c1, 900)
    t.append(c2, 300)
    t.append(c3, 10)
    t.check()
    var sheet = Sheet(t^.share(), False)
    a.answer_table(sheet, 0)
    print("  ", a.answer_where, ":", " | ".join(a.answer))
    check(a.answer[0].startswith("1 (") or a.answer[0].startswith("person") or "(" in a.answer[0], "an answer on row 1")
    var all = a.run_table(sheet)
    check(all.columns() == 5 and all.rows() == 2, "run on all: two columns more")
    print("  ", a.ran_said)
    print("addmodel-tree-file: ok")

    with open("build/g68/model.pkl", "w") as f:
        f.write("not really")
    a.check("build/g68/model.pkl")
    print("  ", a.line)
    check(a.stage == S_SAID and "pickle" in a.why, "a pickle refused")
    print("addmodel-pickle: ok")

    # (a dropped folder holding a MAX pack: compiled code, refused; packs come only from scripts/packs)
    makedirs("build/g68/drop-max", exist_ok=True)
    with open("build/g68/drop-max/plugin.json", "w") as f:
        f.write('{"format": "omx-plugin/1", "name": "sneaky", "kind": "detect", "runner": "max", "files": {"graph": "x.mef"}}')
    a.check("build/g68/drop-max")
    print("  ", a.why)
    check(a.stage == S_SAID and "compiled packs" in a.why, "a dropped MAX pack refused")
    print("addmodel-no-max-drop: ok")
