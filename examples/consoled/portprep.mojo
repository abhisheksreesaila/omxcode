# The port's hard-won decisions, re-expressed in Mojo (the Python daemon's port.py plus the pure parts of
# port_auto.py; D-6401, D-6404): which donor architecture a model starts from, which of Modular's skill files we
# patch and why, the workspace's PORT.md, the gate-script hash, and what makes two failures "the same".
# Nothing here starts a process: ports.mojo runs it. tests/test_port_donor.mojo covers every function.

from std.os import listdir, getenv
from std.os.path import exists, isdir
from mojoui.hash import sha256_hex
from mojoui.json import Json
from mojoui.workbook import read_text, write_text

comptime SKILLS_REPO = "https://github.com/modular/skills"
# The skills commit the owner's 14 real runs used (2026-10-12). Modular's HEAD follows MAX nightly: on 2026-10-29 its
# gate scripts moved to `max.functional`, which the pinned serving MAX (26.7) doesn't have, so a pull from HEAD
# failed every port at the build gate (D-6416). Move this together with the serving MAX, never alone.
comptime SKILLS_REV = "c77190849f2029459082b3e1092134558ff787ab"
comptime ENTRY_SKILL = "import-model"
comptime FALLBACK_DONOR = "LlamaForCausalLM"
comptime KEY_FIELDS = ["model_type", "architectures", "hidden_size", "num_hidden_layers", "num_attention_heads",
                       "num_key_value_heads", "intermediate_size", "vocab_size", "max_position_embeddings",
                       "rope_theta", "rope_scaling", "rms_norm_eps", "hidden_act", "tie_word_embeddings",
                       "torch_dtype", "sliding_window", "num_experts", "num_local_experts"]
# What the gates run: hashed before every use, so tampering is detectable (D-6404).
comptime GATE_PATHS = ["scripts", "pixi.toml", "SKILL.md"]
# The skill's own scripts, the only commands the agent may run (port_auto.SKILL_SCRIPTS).
comptime SKILL_SCRIPTS = ["inspect_hf.py", "list_checkpoint_keys.py", "list_native_archs.py", "check_walls.py",
                          "scaffold.py", "check_port.py", "run_oss_gates.py", "compare_layers.py", "import_model.py"]
# The verify gate asks the parity server for log probabilities, which MAX refuses under its overlap scheduler.
# `--force` makes the flag win over an architecture that turns the scheduler on (MAX 26.7, OLMoE); it also skips
# the architecture's required arguments, so prefix caching and chunked prefill are turned off here. Kept verbatim
# from the 14 real runs (D-6404).
comptime PARITY_SERVE_FLAGS = ["--no-enable-overlap-scheduler", "--force", "--no-enable-prefix-caching",
                               "--no-enable-chunked-prefill"]


def norm(name: String) -> String:
    """port.py _norm: the architecture's family name — "LlamaForCausalLM" → "llama"."""
    var text = name
    var at = text.find("For")
    while at > 0:
        # a trailing "For<Something>" only (the Python's `For[A-Z]\w*$`)
        var rest = String(text[byte = at + 3 :])
        if rest.byte_length() > 0 and rest != "" and _upper(rest.as_bytes()[0]) and rest.find("For") < 0:
            var cut = String(text[byte = : at])
            text = cut
            break
        at = text.find("For", at + 1)
    var out = String("")
    for b in text.lower().as_bytes():
        var c = Int(b)
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
            out += String(chr(c))
    return out^


def _upper(b: UInt8) -> Bool:
    return Int(b) >= 65 and Int(b) <= 90


def common_prefix(a: String, b: String) -> Int:
    var n = 0
    var x = a.as_bytes()
    var y = b.as_bytes()
    while n < len(x) and n < len(y) and x[n] == y[n]:
        n += 1
    return n


@fieldwise_init
struct Donor(Copyable, Movable):
    var architecture: String
    var source_dir: String  # "" when MAX's architectures folder could not be read
    var reason: String
    var v3_dir: String  # the `_modulev3` twin, "" when there is none

    def slug(self) -> String:
        return _base(self.source_dir)

    def v3_slug(self) -> String:
        return _base(self.v3_dir)


def _base(path: String) -> String:
    var cut = path.rfind("/")
    return String(path[byte = cut + 1 :]) if cut >= 0 else path


def source_dir(arch: String, arch_dir: String) -> String:
    """port.py _source_dir: MAX's folder for this architecture (the shortest name that starts with it)."""
    if arch_dir == "" or not isdir(arch_dir):
        return ""
    var want = norm(arch)
    var best = String("")
    try:
        for name in listdir(arch_dir):
            var n = String(name)
            if n.endswith("_modulev3") or n.startswith("__") or not isdir(arch_dir + "/" + n):
                continue
            if norm(n).startswith(want) and (best == "" or n.byte_length() < best.byte_length()):
                best = n
    except:
        return ""
    return arch_dir + "/" + best if best != "" else String("")


def v3_twin(src: String) -> String:
    if src == "" or not isdir(src + "_modulev3"):
        return ""
    return src + "_modulev3"


def pick_donor(arch: String, model_type: String, catalog: List[String], arch_dir: String) -> Donor:
    """port.py pick_donor, unchanged: the closest supported architecture is the one whose family name shares the
    longest prefix with the target's (and its model_type), a full-name prefix counting extra (the same family at a
    nearby version), shorter names winning ties. Picking a donor is *the* trick of the whole pipeline (StableLm
    from Llama), so the rule is kept as it was earned (D-6404)."""
    var targets = List[String]()
    for t in [norm(arch), norm(model_type)]:
        if String(t) != "":
            targets.append(String(t))
    var best = String("")
    var best_score = 0
    for cand in catalog:
        var c = norm(cand)
        var score = 0
        for t in targets:
            var shared = common_prefix(t, c)
            if shared < 3:
                continue
            var s = shared + (10 if t.startswith(c) else 0)
            if s > score:
                score = s
        if score > best_score or (score == best_score and best != "" and score > 0 and c.byte_length() < norm(best).byte_length()):
            best = cand
            best_score = score
    if best == "":
        var fb = String(FALLBACK_DONOR)
        var found = False
        for cand in catalog:
            if cand == FALLBACK_DONOR:
                found = True
        if not found and len(catalog) > 0:
            var sorted_names = catalog.copy()
            sort(sorted_names)
            fb = sorted_names[0]
        var src = source_dir(fb, arch_dir)
        return Donor(fb, src, "fallback: nothing in MAX's catalog shares a name with " + (arch if arch != "" else model_type)
                     + "; " + fb + " is the most common decoder-only starting point", v3_twin(src))
    var src2 = source_dir(best, arch_dir)
    var names = String("")
    for i in range(len(targets)):
        names += (", " if i > 0 else "") + targets[i]
    return Donor(best, src2, "its name (" + norm(best) + ") matches the start of " + (arch if arch != "" else model_type)
                 + " (" + names + "), so it is the same family at a nearby version", v3_twin(src2))


def max_arch_dir(max_cmd: String) -> String:
    """MAX's own architectures folder, under the install `max` runs from (port.py read it through importlib; here
    the install prefix of MXC_MAX is walked, which is the same folder)."""
    var first = String(max_cmd.split(" ")[0])
    var at = first.find("/bin/max")
    if at <= 0:
        return ""
    var prefix = String(first[byte = : at])
    var libs = prefix + "/lib"
    if not isdir(libs):
        return ""
    try:
        for name in listdir(libs):
            var d = libs + "/" + String(name) + "/site-packages/max/pipelines/architectures"
            if isdir(d):
                return d
    except:
        return ""
    return ""


def catalog_names(catalog_json: String) -> List[String]:
    """The architecture names in MAX's catalog (`max list --json`, cached by pulls.mojo)."""
    var out = List[String]()
    if catalog_json == "":
        return out^
    try:
        var j = Json.parse(catalog_json)
        for k in range(j.size(0)):
            out.append(j.key(0, k))
    except:
        pass
    return out^


def package_slug(name: String) -> String:
    """port_auto.package_slug: the port package's folder name, a valid Python identifier (MAX imports it by name)."""
    var slug = String("")
    var last_us = True
    for b in name.lower().as_bytes():
        var c = Int(b)
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
            slug += String(chr(c))
            last_us = False
        elif not last_us:
            slug += "_"
            last_us = True
    while slug.endswith("_"):
        var shorter = String(slug[byte = : slug.byte_length() - 1])
        slug = shorter
    while slug.startswith("_"):
        var tail = String(slug[byte = 1 :])
        slug = tail
    if slug == "":
        return "port"
    var c0 = Int(slug.as_bytes()[0])
    return slug if c0 >= 97 and c0 <= 122 else "m_" + slug


def workspace_name(name: String) -> String:
    """port.py _workspace_name: never all digits (job folders are ports/<id>, and the agent may write its workspace)."""
    var digits = name != ""
    for b in name.as_bytes():
        if Int(b) < 48 or Int(b) > 57:
            digits = False
    return "model-" + name if digits else name


def check_port_dir(path: String) -> String:
    """port.py check_port_dir: why this folder is not a MAX custom architecture package, or ""."""
    if not isdir(path):
        return path + " is not a directory"
    var leaf = _base(path)
    var identifier = leaf != ""
    for i in range(len(leaf.as_bytes())):
        var c = Int(leaf.as_bytes()[i])
        var ok = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95 or (c >= 48 and c <= 57 and i > 0)
        if not ok:
            identifier = False
    if path.find(":") >= 0 or not identifier:
        return path + ": MAX imports the port dir by its folder name, so the name must be a valid Python identifier and the path must not contain ':'"
    var missing = String("")
    for f in ["arch.py", "__init__.py"]:
        if not exists(path + "/" + String(f)):
            missing += (", " if missing != "" else "") + String(f)
    if missing != "":
        return path + " is missing " + missing + "; the " + ENTRY_SKILL + " skill produces arch.py and an __init__.py that exposes ARCHITECTURES"
    try:
        if read_text(path + "/__init__.py").find("ARCHITECTURES") < 0:
            return path + "/__init__.py does not define ARCHITECTURES"
    except:
        return path + "/__init__.py could not be read"
    return ""


# ---- Modular's skill: the patches and the pin ------------------------------------------------------------------
# Known bugs in Modular's published skill that break a gate for every model, fixed in our clone (trusted, our own
# code). Each: (file under the skills root, the buggy text, the fix, why). Applied right after the clone is updated
# and again after any restore, before the gate hash is taken or compared. Both were paid for by real runs (D-6404).
comptime PATCH_FILES = ["import-model/scripts/compare_layers.py", "import-model/scripts/compare_layers.py"]
comptime PATCH_FROM = ["            input_ids[0, :pos].tolist(), skip_special_tokens=True",
                       '    return hf_text == mx_text or bool(\n']
comptime PATCH_TO = ["            ids[0, :pos].tolist(), skip_special_tokens=True",
                     '    return hf_text == mx_text or (hf_text == "\\ufffd" and mx_text == "") or bool(\n']
comptime PATCH_WHY = ["the multi-position probe reads `input_ids` where it stored `ids` (NameError in logits_multi)",
                      'a lone UTF-8 byte token decodes to U+FFFD in HF but to "" from the server, which holds the incomplete character back, so the multi-position probe failed ports that picked the same token (StableLM, run 23)']
comptime SKILL_MANIFEST = "import-model/pixi.toml"


def pin_max(manifest_text: String, serving_max: String) -> String:
    """The skill's manifest with `max = "<serving_max>"`: the skill allows any MAX 26.x, so a fresh solve picks
    whatever nightly is newest, and a port must be built against the MAX that will serve it (D-6404)."""
    var out = String("")
    var first = True
    for line in manifest_text.split("\n"):
        var l = String(line)
        if l.startswith("max ") or l.startswith("max="):
            var eq = l.find("=")
            if eq > 0 and l.find('"') > eq:
                l = 'max = "' + serving_max + '"'
        out += ("\n" if not first else "") + l
        first = False
    return out^


def max_pinned(manifest_text: String, serving_max: String) -> Bool:
    return manifest_text.find('max = "' + serving_max + '"') >= 0


def apply_skill_patches(skills_root: String, serving_max: String) -> List[String]:
    """Apply the patches where the buggy text is present and pin the skill env's MAX; what was changed (idempotent)."""
    var done = List[String]()
    if serving_max != "":
        var f = skills_root + "/" + SKILL_MANIFEST
        try:
            var text = read_text(f)
            if not max_pinned(text, serving_max):
                write_text(f, pin_max(text, serving_max))
                done.append(SKILL_MANIFEST + ": MAX pinned to " + serving_max + ", the version that will serve the port")
        except:
            pass
    for i in range(len(materialize[PATCH_FILES]())):
        var path = skills_root + "/" + String(materialize[PATCH_FILES]()[i])
        try:
            var text = read_text(path)
            var want = String(materialize[PATCH_FROM]()[i])
            if text.find(want) >= 0:
                write_text(path, text.replace(want, String(materialize[PATCH_TO]()[i])))
                done.append(String(materialize[PATCH_FILES]()[i]) + ": " + String(materialize[PATCH_WHY]()[i]))
        except:
            pass
    return done^


def stale_patches(skills_root: String) -> List[String]:
    """A patch whose buggy text is gone *and* whose fix isn't there either: Modular changed that code, so the
    patch may no longer be needed (or no longer applies). Said in the log, never fatal."""
    var out = List[String]()
    for i in range(len(materialize[PATCH_FILES]())):
        var path = skills_root + "/" + String(materialize[PATCH_FILES]()[i])
        try:
            var text = read_text(path)
            if text.find(String(materialize[PATCH_FROM]()[i])) < 0 and text.find(String(materialize[PATCH_TO]()[i])) < 0:
                out.append("our fix for " + String(materialize[PATCH_FILES]()[i]) + " no longer applies (Modular changed that code): "
                           + String(materialize[PATCH_WHY]()[i]))
        except:
            pass
    return out^


def gate_files(skills_root: String) -> List[String]:
    """Every file the gates run (the skill's scripts, manifest and SKILL.md), sorted."""
    var base = skills_root + "/" + ENTRY_SKILL
    var out = List[String]()
    for g in materialize[GATE_PATHS]():
        var p = base + "/" + String(g)
        if isdir(p):
            _walk(p, out)
        elif exists(p):
            out.append(p)
    sort(out)
    return out^


def _walk(folder: String, mut out: List[String]):
    try:
        for name in listdir(folder):
            var p = folder + "/" + String(name)
            if String(name) == "__pycache__":
                continue
            if isdir(p):
                _walk(p, out)
            else:
                out.append(p)
    except:
        pass


def gate_hash(skills_root: String) -> String:
    """Hash of the files the gates run, so tampering is detectable (port_auto.gate_hash)."""
    var blob = String("")
    var base = skills_root + "/" + ENTRY_SKILL + "/"
    for f in gate_files(skills_root):
        var rel = String(f).replace(base, "")
        try:
            blob += rel + "\0" + read_text(f) + "\0"
        except:
            blob += rel + "\0?\0"
    return sha256_hex(blob)


# ---- what makes two failures "the same" ------------------------------------------------------------------------

def reached_text(reached: Float64) -> String:
    if reached < 2:
        return "it got to the build check"
    if reached < 3:
        return "it built but did not serve"
    return "it served; the comparison failed"


def _volatile(line: String) -> String:
    """port_auto's _VOLATILE: drop what changes every run — clock times, port numbers, request ids."""
    var out = String("")
    var b = List[UInt8]()
    for x in line.as_bytes():
        b.append(x)
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        if c == 58 and _digits_at(b, i + 1) >= 4:  # ":1234"
            i += 1 + _digits_at(b, i + 1)
            continue
        if _digits_at(b, i) == 2 and i + 2 < len(b) and Int(b[i + 2]) == 58 and _digits_at(b, i + 3) == 2:  # 12:34:56
            var j = i + 5
            while j < len(b) and (Int(b[j]) == 58 or Int(b[j]) == 46 or (Int(b[j]) >= 48 and Int(b[j]) <= 57)):
                j += 1
            i = j
            continue
        if _digits_at(b, i) >= 4 and (i == 0 or Int(b[i - 1]) == 32):
            i += _digits_at(b, i)
            continue
        out += String(chr(c))
        i += 1
    var at = out.find("Request ID: ")
    if at >= 0:
        out = String(out[byte = : at]) + "Request ID: "
    return out^


def _digits_at(b: List[UInt8], at: Int) -> Int:
    var n = 0
    while at + n < len(b) and Int(b[at + n]) >= 48 and Int(b[at + n]) <= 57:
        n += 1
    return n


def _is_gate_line(line: String) -> Bool:
    """A gate's own result line ("checkpoint_meta  PASS", "overall: 3/4")."""
    if line.strip().startswith("overall:"):
        return True
    for word in ["  PASS", " PASS ", "  FAIL", " FAIL ", "  WARN", "  SKIP"]:
        if line.find(String(word)) >= 0:
            return True
    return line.endswith(" PASS") or line.endswith(" FAIL") or line.endswith(" WARN") or line.endswith(" SKIP")


def _is_progress(line: String) -> Bool:
    for word in ["%|", "it/s]", "s/it]", "tok/s", "Tput"]:
        if line.find(String(word)) >= 0:
            return True
    return False


def failure_signature(message: String, output: String, reached: Float64) -> String:
    """port_auto.failure_signature: what decides "the same failure" — a comparison's gate result lines (its
    progress bars and throughput change every run); a serve failure's error lines; a build check's whole output
    minus progress bars (the same counts with different weight names must differ). The stop-on-repeat rule this
    feeds saved a whole attempt on EXAONE and BLOOM (D-6404)."""
    var kept = List[String]()
    if reached >= 3:
        for line in output.split("\n"):
            if _is_gate_line(String(line)):
                kept.append(String(_volatile(String(line)).strip()))
        if len(kept) == 0:
            for line in output.split("\n"):
                if not _is_progress(String(line)):
                    kept.append(String(_volatile(String(line)).strip()))
    elif reached >= 2:
        for line in output.split("\n"):
            var l = String(line)
            if l.find("FAIL") >= 0 or l.find("error") >= 0 or l.find("Error") >= 0:
                kept.append(String(_volatile(l).strip()))
    else:
        for line in output.split("\n"):
            if not _is_progress(String(line)):
                kept.append(String(_volatile(String(line)).strip()))
    var text = _volatile(message) + "\n"
    for k in kept:
        if k != "":
            text += k + "\n"
    return text^


comptime INFRA_WORDS = ["429 Too Many Requests", "maximum queue size reached", "Temporary failure in name resolution",
                        "ConnectionError", "Connection reset", "Connection refused", "ConnectTimeout", "ReadTimeout",
                        "HF side failed: [Errno 30] Read-only file system", "502 Bad Gateway", "503 Service", "504 Server Error"]
comptime HUB_SIDE = ["huggingface.co", "HF side failed:", "checkpoint_meta", "hub_config"]


def infra_error(output: String, server_alive: Bool) -> String:
    """The first line of `out` that shows the Hub or our HF cache failing, or "" (also when our own server died):
    a failed check whose reference side couldn't reach the Hub isn't the port's fault, and BLOOM lost a whole
    attempt to a 429 before this existed (D-6404)."""
    if not server_alive:
        return ""
    for line in output.split("\n"):
        var l = String(line)
        var infra = False
        for w in materialize[INFRA_WORDS]():
            if l.find(String(w)) >= 0:
                infra = True
        if not infra and (l.find("HTTP 5") >= 0 or l.find("HTTPError 5") >= 0):
            infra = True
        var hub = False
        for w in materialize[HUB_SIDE]():
            if l.find(String(w)) >= 0:
                hub = True
        if infra and hub and l.find("MAX server") < 0:
            var t = String(l.strip())
            return String(t[byte = : min(200, t.byte_length())])
    return ""
