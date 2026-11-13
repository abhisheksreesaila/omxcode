# mojoui.plugins: one format for a model an app can run (goal 68 M0). A model plugin is a folder holding plugin.json;
# any app finds every plugin folder at run time (no rebuild) and runs it beside its data, in its own process.
#
#   {"format": "omx-plugin/1", "name": "scene", "kind": "classify-image", "runner": "max",
#    "about": "ResNet-18: a picture's ImageNet label", "licence": "BSD-3-Clause", "source": "torchvision:resnet18",
#    "inputs":  [{"name": "frame", "type": "image"}],
#    "outputs": [{"name": "label", "type": "text"}, {"name": "score", "type": "number"}],
#    "files":   {"graph": "scene.mef", "weights": "scene.safetensors", "labels": "labels.txt"},
#    "params":  {"size": 224}, "trust_remote_code": false}
#
#   kind    tabular · detect · segment · classify-image · embed-text
#   runner  tree   a decision model evaluated in Mojo (mojoui.treefile): its own tree, XGBoost JSON, LightGBM text
#           max    a MAX pack (mojoui.maxrt): a compiled graph + safetensors (scripts/packs/*)
#           torch  PyTorch + transformers in this process (mojoui/plugin_py.py), weights as safetensors only
#           onnx   ONNX Runtime in this process (mojoui/plugin_py.py)
#           skops  a scikit-learn model saved with skops (never pickle), its types checked before loading
#   inputs  tabular: the columns it reads ({"name", "type": number|text}); matched to a table's by name and type
#   outputs the columns it writes (a tabular model's prediction, a detector's kind/score/box, an embedder's vector)
#
#   var found = find_plugins()                   # every plugin folder in plugin_dirs(), by name; broken ones say why
#   for p in found: p.name, p.kind, p.runner, p.ok(), p.problem
#   var p = Plugin.read("build/plugins/stops")  # raises with the reason (a file outside the folder, a pickle, …)
#
# Safety (code and weights from outside, run in this process): a plugin's files must be inside its folder (no
# absolute paths, no "..", no link pointing out), never a pickle (.pkl .pickle .joblib .pt .pth .bin .ckpt .npy with
# objects), and a model's own code (transformers' trust_remote_code) runs only when plugin.json says
# "trust_remote_code": true, which only a person's yes for that model writes (mojoui.addmodel).

from std.os import getenv, listdir
from std.os.path import isdir, exists, realpath
from mojoui.json import Json, J_OBJECT, J_ARRAY, J_STRING, json_string

comptime PLUGIN_FORMAT = "omx-plugin/1"
comptime KINDS: List[String] = ["tabular", "detect", "segment", "classify-image", "embed-text"]
comptime RUNNERS: List[String] = ["tree", "max", "torch", "onnx", "skops"]
comptime PICKLES: List[String] = [".pkl", ".pickle", ".joblib", ".pt", ".pth", ".bin", ".ckpt", ".npy", ".npz", ".dill", ".sav"]


@fieldwise_init
struct PluginIO(Copyable, Movable):
    var name: String
    var type: String  # number, text, image, boxes, vector


struct Plugin(Copyable, Movable):
    var dir: String
    var name: String
    var kind: String
    var runner: String
    var about: String
    var licence: String
    var source: String
    var inputs: List[PluginIO]
    var outputs: List[PluginIO]
    var file_keys: List[String]
    var file_paths: List[String]  # the files, each checked to be inside dir
    var params: String  # its "params" object as JSON text ("{}" when none)
    var trust_remote_code: Bool
    var problem: String  # why it can't run ("" when it can)

    def __init__(out self, dir: String):
        self.dir = dir
        self.name = ""
        self.kind = ""
        self.runner = ""
        self.about = ""
        self.licence = ""
        self.source = ""
        self.inputs = List[PluginIO]()
        self.outputs = List[PluginIO]()
        self.file_keys = List[String]()
        self.file_paths = List[String]()
        self.params = "{}"
        self.trust_remote_code = False
        self.problem = ""

    def ok(self) -> Bool:
        return self.problem == ""

    def file(self, key: String) -> String:
        """The absolute path of files[key] ("" when it has none)."""
        for i in range(len(self.file_keys)):
            if self.file_keys[i] == key:
                return self.file_paths[i]
        return ""

    def param(self, key: String, default: String = "") -> String:
        try:
            var j = Json.parse(self.params)
            var n = j.get(0, key)
            if n < 0:
                return default
            return j.text(n) if j.kind(n) == J_STRING else j.dump(n)
        except:
            return default

    def param_number(self, key: String, default: Float64) -> Float64:
        try:
            var j = Json.parse(self.params)
            var n = j.get(0, key)
            return j.real(n) if n >= 0 else default
        except:
            return default

    def input_names(self) -> List[String]:
        var out = List[String]()
        for i in self.inputs:
            out.append(i.name)
        return out^

    @staticmethod
    def read(dir: String) raises -> Plugin:
        """dir/plugin.json, checked: a known kind and runner, a name, its files inside dir and none a pickle."""
        var p = Plugin(String(dir.rstrip("/")))
        var path = p.dir + "/plugin.json"
        if not exists(path):
            raise Error(p.dir + " has no plugin.json: not a model plugin")
        var j = Json.parse(open(path, "r").read())
        if j.kind(0) != J_OBJECT:
            raise Error(path + ": not a JSON object")
        var fmt = j.text(j.get(0, "format"), PLUGIN_FORMAT)
        if fmt != PLUGIN_FORMAT:
            raise Error(path + ": format " + fmt + " (this app reads " + PLUGIN_FORMAT + ")")
        p.name = j.text(j.get(0, "name"))
        p.kind = j.text(j.get(0, "kind"))
        p.runner = j.text(j.get(0, "runner"))
        p.about = j.text(j.get(0, "about"))
        p.licence = j.text(j.get(0, "licence"), j.text(j.get(0, "license")))
        p.source = j.text(j.get(0, "source"))
        p.trust_remote_code = j.flag(j.get(0, "trust_remote_code"))
        var pn = j.get(0, "params")
        if pn >= 0:
            p.params = j.dump(pn)
        if not valid_name(p.name):
            raise Error(path + ": its name '" + p.name + "' must be letters, digits and _ (it becomes a function and a column)")
        if not (p.kind in materialize[KINDS]()):
            raise Error(path + ": kind '" + p.kind + "' (one of " + ", ".join(materialize[KINDS]()) + ")")
        if not (p.runner in materialize[RUNNERS]()):
            raise Error(path + ": runner '" + p.runner + "' (one of " + ", ".join(materialize[RUNNERS]()) + ")")
        for key in ["inputs", "outputs"]:
            var arr = j.get(0, key)
            if arr >= 0 and j.kind(arr) == J_ARRAY:
                for i in range(j.size(arr)):
                    var e = j.at(arr, i)
                    var io = PluginIO(j.text(j.get(e, "name")), j.text(j.get(e, "type"), "number"))
                    if key == "inputs":
                        p.inputs.append(io^)
                    else:
                        p.outputs.append(io^)
        var files = j.get(0, "files")
        if files >= 0 and j.kind(files) == J_OBJECT:
            for i in range(j.size(files)):
                var key = j.key(files, i)
                var rel = j.text(j.get(files, key))
                p.file_keys.append(key)
                p.file_paths.append(inside(p.dir, rel))
        return p^


def valid_name(name: String) -> Bool:
    if name == "" or name.byte_length() > 40:
        return False
    for b in name.as_bytes():
        var c = Int(b)
        if not ((c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95):
            return False
    return not (Int(name.as_bytes()[0]) >= 48 and Int(name.as_bytes()[0]) <= 57)


def is_pickle(name: String) -> Bool:
    var low = name.lower()
    for ext in materialize[PICKLES]():
        if low.endswith(ext):
            return True
    return False


def inside(dir: String, rel: String) raises -> String:
    """dir/rel, refused unless it stays inside dir once links are followed, and refused for a pickle."""
    if rel == "" or rel.startswith("/") or rel.startswith("~") or "\\" in rel:
        raise Error("a plugin's file must be a path inside its folder, not '" + rel + "'")
    for part in rel.split("/"):
        if String(part) == "..":
            raise Error("a plugin's file must stay inside its folder ('" + rel + "' climbs out)")
    if is_pickle(rel):
        raise Error("'" + rel + "' is a pickle (it can run code when loaded): save the model as safetensors, ONNX, skops, XGBoost JSON or LightGBM text")
    var full = dir + "/" + rel
    if exists(full):
        var real_dir = realpath(dir)
        var real = realpath(full)
        if not real.startswith(real_dir + "/"):
            raise Error("'" + rel + "' points outside its plugin's folder (a link)")
    return full


def plugin_dirs() -> List[String]:
    """Where plugins live: $OMX_PLUGINS (folders, ":" between), else ~/.local/share/omxcode/plugins; then the MAX packs'
    folder ($OMX_PACKS, else build/packs), where scripts/packs/* write theirs."""
    var out = List[String]()
    var asked = getenv("OMX_PLUGINS", "")
    if asked != "":
        for d in asked.split(":"):
            if String(d) != "":
                out.append(String(d))
    else:
        out.append(getenv("HOME", ".") + "/.local/share/omxcode/plugins")
    out.append(getenv("OMX_PACKS", "build/packs"))
    return out^


def user_plugin_dir() -> String:
    """Where Add a model puts new plugins: the first of plugin_dirs()."""
    return plugin_dirs()[0]


def find_plugins(dirs: List[String] = List[String]()) -> List[Plugin]:
    """Every <dir>/<folder>/plugin.json, by folder name in each dir in turn; a name already found is skipped. A
    plugin that doesn't read is kept with its problem (an app shows why)."""
    var out = List[Plugin]()
    var where = dirs.copy() if len(dirs) > 0 else plugin_dirs()
    for d in where:
        if not isdir(d):
            continue
        var names = List[String]()
        try:
            for n in listdir(d):
                names.append(String(n))
        except:
            continue
        sort(names)
        for n in names:
            var dir = d + "/" + n
            if not exists(dir + "/plugin.json"):
                continue
            var p = Plugin(dir)
            try:
                p = Plugin.read(dir)
            except e:
                p.name = n
                p.problem = String(e)
            var taken = False
            for q in out:
                taken = taken or q.name == p.name
            if not taken:
                out.append(p^)
    return out^


def find_plugin(name: String) -> Plugin:
    """The plugin called name (problem set when there's none)."""
    for p in find_plugins():
        if p.name == name:
            return p.copy()
    var none = Plugin("")
    none.name = name
    none.problem = "no plugin called " + name + " (add one with Add a model)"
    return none^


def plugin_json(name: String, kind: String, runner: String, about: String, licence: String, source: String,
                inputs: List[PluginIO], outputs: List[PluginIO], file_keys: List[String], file_paths: List[String],
                params: String = "{}", trust_remote_code: Bool = False) -> String:
    """A plugin.json's text (what Add a model and the pack builders write)."""
    var s = String("{\n  \"format\": ") + json_string(PLUGIN_FORMAT) + ",\n  \"name\": " + json_string(name) + ",\n  \"kind\": " + json_string(kind)
    s += ",\n  \"runner\": " + json_string(runner) + ",\n  \"about\": " + json_string(about) + ",\n  \"licence\": " + json_string(licence)
    s += ",\n  \"source\": " + json_string(source) + ",\n  \"inputs\": ["
    for i in range(len(inputs)):
        s += ("," if i > 0 else "") + "{\"name\": " + json_string(inputs[i].name) + ", \"type\": " + json_string(inputs[i].type) + "}"
    s += "],\n  \"outputs\": ["
    for i in range(len(outputs)):
        s += ("," if i > 0 else "") + "{\"name\": " + json_string(outputs[i].name) + ", \"type\": " + json_string(outputs[i].type) + "}"
    s += "],\n  \"files\": {"
    for i in range(len(file_keys)):
        s += ("," if i > 0 else "") + json_string(file_keys[i]) + ": " + json_string(file_paths[i])
    s += "},\n  \"params\": " + params + ",\n  \"trust_remote_code\": " + ("true" if trust_remote_code else "false") + "\n}\n"
    return s
