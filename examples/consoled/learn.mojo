# /admin/learn/{name}: a model's notebook (spec §4 learn). An existing MXC_HOME/notebooks/<name>.ipynb is read as is
# (generated: false); else one is built offline from the model's local snapshot: config.json for the architecture rows
# and the parameter count, README.md for the card, the safetensors headers for the real total (D-4772).

from std.os.path import exists
from std.os import makedirs
from mojoui.json import Json, json_string, J_NUMBER, J_STRING, J_BOOL, J_NULL, J_ARRAY, J_OBJECT
from mojoui.process import file_tail
from views import serialize, num

comptime FIELDS = ["model_type", "architectures", "hidden_size", "num_hidden_layers", "num_attention_heads", "num_key_value_heads", "gqa_ratio", "head_dim", "intermediate_size", "vocab_size", "max_position_embeddings", "rope_theta", "rope_scaling", "tie_word_embeddings"]
comptime MEANINGS = [
    "The family name transformers uses to pick the model code.",
    "The class name that loads these weights; MAX matches on this.",
    "Width of the residual stream: the size of every token's vector as it moves through the layers.",
    "How many transformer blocks are stacked. Depth.",
    "Query heads per layer; each looks at the context in its own learned way.",
    "Key/value heads. Fewer than query heads means grouped-query attention (GQA): query heads share K/V, which shrinks the KV cache.",
    "Query heads per KV head. Higher means a smaller KV cache for the same context.",
    "Size of each attention head.",
    "Hidden width of the MLP (feed-forward) block, usually 3-4x hidden_size.",
    "Number of tokens the model knows; sets the embedding and output matrix size.",
    "Longest context the model was trained to handle.",
    "RoPE base frequency; larger values stretch positional encoding for longer contexts.",
    "Optional RoPE scaling (YaRN, linear, ...) used to extend context past training length.",
    "True means the output matrix reuses the input embeddings, saving vocab x hidden parameters.",
]


def read_text(path: String) -> String:
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return ""


def fmt(n: Int) -> String:
    """learn.py fmt: 494.03M, 1.84M, 136.13M, 1.20B, 3.5K."""
    var x = Float64(n)
    if x >= 1e9:
        return _two(x / 1e9) + "B"
    if x >= 1e6:
        return _two(x / 1e6) + "M"
    if x >= 1e3:
        return _two(x / 1e3) + "K"
    return String(n)


def _two(x: Float64) -> String:
    var c = Int(x * 100 + 0.5)
    var frac = c % 100
    return String(c // 100) + "." + ("0" if frac < 10 else "") + String(frac)


def cfg_int(j: Json, c: Int, key: String) -> Int:
    var n = j.get(c, key)
    return j.number(n) if n >= 0 and j.kind(n) == J_NUMBER else -1


def safetensors_total(folder: String) -> Int:
    """Parameters in the snapshot's *.safetensors files, from their JSON headers (dtype sizes ignored: element counts)."""
    from std.os import listdir
    var total = 0
    try:
        for name in listdir(folder):
            if not name.endswith(".safetensors"):
                continue
            with open(folder + "/" + name, "rb") as f:
                var head = f.read_bytes(8)
                var n = 0
                for i in range(8):
                    n |= Int(head[i]) << (8 * i)
                var meta = Json.parse(String(unsafe_from_utf8=f.read_bytes(n)))
                for k in range(meta.size(0)):
                    if meta.keys[0][k] == "__metadata__":
                        continue
                    var shape = meta.get(meta.at(0, k), "shape")
                    var count = 1
                    for d in range(meta.size(shape)):
                        count *= meta.number(meta.at(shape, d))
                    total += count
    except:
        return -1
    return total if total > 0 else -1


def notebook_json(name: String, repo: String, revision: String, weights: String, home: String, port: Int) raises -> String:
    var path = home + "/notebooks/" + name + ".ipynb"
    if exists(path):
        var nb = Json.parse(read_text(path))
        var arch = nb.get(nb.get(nb.get(0, "metadata"), "mxconsole"), "architecture")
        if arch >= 0:
            var cells = nb.get(0, "cells")
            var out = String("[")
            for i in range(nb.size(cells)):
                var c = nb.at(cells, i)
                var src = nb.get(c, "source")
                var text = String("")
                if nb.kind(src) == J_ARRAY:
                    for k in range(nb.size(src)):
                        text += nb.text(nb.at(src, k))
                else:
                    text = nb.text(src)
                var outputs = nb.get(c, "outputs")
                out += (", " if i > 0 else "") + '{"type": ' + json_string(nb.text(nb.get(c, "cell_type"))) + ', "source": ' + json_string(text)
                out += ', "outputs": ' + (serialize(nb, outputs) if outputs >= 0 else "[]") + "}"
            return _reply(name, path, False, serialize(nb, arch), out + "]")
    # build it from the snapshot
    var cfg_text = read_text(weights + "/config.json")
    var arch_json = String('{"architecture": null, "rows": [], "parameters": null, "safetensors_total": null}')
    var rows_md = String("")
    var params_md = String("")
    var total_est = -1
    var arch_name = String("")
    if cfg_text != "":
        var j = Json.parse(cfg_text)
        var c = j.get(0, "text_config") if j.get(0, "text_config") >= 0 else 0
        var archs = j.get(0, "architectures")
        if archs >= 0 and j.size(archs) > 0:
            arch_name = j.text(j.at(archs, 0))
        var h = cfg_int(j, c, "hidden_size")
        var L = cfg_int(j, c, "num_hidden_layers")
        var heads = cfg_int(j, c, "num_attention_heads")
        var kv = cfg_int(j, c, "num_key_value_heads")
        var hd = cfg_int(j, c, "head_dim")
        if hd < 0 and h > 0 and heads > 0:
            hd = h // heads
        var I = cfg_int(j, c, "intermediate_size")
        var V = cfg_int(j, c, "vocab_size")
        var tied_n = j.get(c, "tie_word_embeddings")
        if tied_n < 0:
            tied_n = j.get(0, "tie_word_embeddings")
        var tied = tied_n >= 0 and j.flag(tied_n)
        var rows = String("[")
        var first = True
        for f in range(14):
            var field = String(materialize[FIELDS]()[f])
            var value = String("")
            if field == "architectures":
                if archs >= 0 and j.size(archs) > 0:
                    var names = String("")
                    for k in range(j.size(archs)):
                        names += (", " if k > 0 else "") + j.text(j.at(archs, k))
                    value = json_string(names)
            elif field == "model_type":
                var n = j.get(0, "model_type")
                if n >= 0 and j.kind(n) != J_NULL:
                    value = serialize(j, n)
            elif field == "gqa_ratio":
                if heads > 0 and kv > 0:
                    value = json_string("1:1 (plain multi-head)") if heads == kv else json_string(_g(Float64(heads) / Float64(kv)) + ":1")
            elif field == "head_dim":
                if hd > 0:
                    value = String(hd)
            elif field == "tie_word_embeddings":
                if tied_n >= 0:
                    value = "true" if tied else "false"
            elif field == "rope_scaling":
                var n = j.get(c, "rope_scaling")
                if n >= 0 and j.kind(n) != J_NULL:
                    value = json_string(serialize(j, n))
            else:
                var n = j.get(c, field)
                if n >= 0 and j.kind(n) != J_NULL:
                    value = serialize(j, n)
                    if field == "rope_theta" and value.find(".") < 0:
                        value += ".0"
            if value == "":
                continue
            var meaning = String(materialize[MEANINGS]()[f])
            rows += ("" if first else ", ") + '{"field": ' + json_string(field) + ', "value": ' + value + ', "meaning": ' + json_string(meaning) + "}"
            var shown = value
            if shown.startswith('"'):
                var inner = String(shown[byte = 1 : shown.byte_length() - 1])
                shown = inner
            rows_md += "| `" + field + "` | " + shown + " | " + meaning + " |\n"
            first = False
        rows += "]"
        var params = String("null")
        if h > 0 and L > 0 and heads > 0 and V > 0 and I > 0:
            var kvh = kv if kv > 0 else heads
            var E = max(cfg_int(j, c, "num_local_experts"), cfg_int(j, c, "num_experts"), 1)
            var moe = cfg_int(j, c, "moe_intermediate_size")
            var W = (moe if moe > 0 else I) if E > 1 else I
            var emb = V * h
            var attn = h * heads * hd + 2 * h * kvh * hd + heads * hd * h
            var mlp = 3 * h * W * E
            var norms = 2 * h
            var head = 0 if tied else V * h
            total_est = emb + L * (attn + mlp + norms) + h + head
            params = ('{"embeddings": ' + String(emb) + ', "attention_per_layer": ' + String(attn) + ', "mlp_per_layer": ' + String(mlp)
                      + ', "norms_per_layer": ' + String(norms) + ', "layers": ' + String(L) + ', "lm_head": ' + String(head)
                      + ', "total": ' + String(total_est) + ', "experts": ' + String(E) + "}")
            params_md = ("## Where the parameters live\n\nA rough count from the config, checked against the real total from the safetensors metadata.\n\n| part | parameters | note |\n|---|---|---|\n"
                + "| token embeddings | " + fmt(emb) + " | vocab x hidden |\n| attention, per layer | " + fmt(attn) + " | Q, K, V and output projections |\n"
                + "| MLP, per layer | " + fmt(mlp) + " | gate, up and down projections |\n| attention, all " + String(L) + " layers | " + fmt(attn * L) + " | |\n"
                + "| MLP, all " + String(L) + " layers | " + fmt(mlp * L) + " | |\n| output head | " + fmt(head) + " | " + ("tied to embeddings, no extra weights" if tied else "separate from embeddings") + " |\n"
                + "| **estimated total** | **" + fmt(total_est) + "** | ignores biases; norms included |\n")
        var real = safetensors_total(weights)
        if real > 0 and total_est > 0:
            var diff = (Float64(total_est) - Float64(real)) / Float64(real) * 100
            params_md += "| safetensors total (local files) | " + fmt(real) + " | estimate is " + ("+" if diff >= 0 else "") + _one(diff) + "% off: " + ("close enough to trust the table" if abs(diff) < 5 else "the estimate is off; this model has parts the formula does not know about") + " |\n"
        arch_json = ('{"architecture": ' + (json_string(arch_name) if arch_name != "" else "null") + ', "rows": ' + rows + ', "parameters": ' + params
                     + ', "safetensors_total": ' + (String(real) if real > 0 else "null") + "}")
    var card = read_text(weights + "/README.md")
    if card.startswith("---"):
        var end = card.find("\n---", 3)
        if end > 0:
            var body = String(String(card[byte = end + 4 :]).strip())
            card = body
    if card.byte_length() > 6000:
        var cut = String(card[byte = : 6000])
        var nl = cut.rfind("\n")
        card = String(cut[byte = : nl if nl > 0 else 6000]) + "\n\n*(model card trimmed; the full card is on Hugging Face)*"
    var cells = List[Tuple[String, String]]()
    var what = "# " + name + "\n\n[`" + repo + "`](https://huggingface.co/" + repo + ") on Hugging Face. Everything below came from the model's local files and was generated by `consoled`.\n\n## What it is\n\n"
    if total_est > 0:
        what += "- **Parameters:** " + fmt(total_est) + "\n"
    if revision != "":
        what += "- **Revision:** " + String(revision[byte = : min(7, revision.byte_length())]) + "\n"
    cells.append(("markdown", what))
    cells.append(("markdown", "## Model card\n\n" + (card if card != "" else "*No model card text available.*")))
    if rows_md != "":
        cells.append(("markdown", "## Architecture\n\nFrom `config.json`:\n\n| field | value | what it means |\n|---|---|---|\n" + rows_md))
        cells.append(("markdown", params_md))
    else:
        cells.append(("markdown", "## Architecture\n\nNo `config.json` was available in the model's files."))
    cells.append(("markdown", "## See inside: MAX's implementation\n\nMAX's code for `" + arch_name + "` lives in `max/pipelines/architectures/` in the environment that runs `max serve`."))
    cells.append(("markdown", "## Try it\n\nThese cells talk to the local omxconsole endpoint. Opened from the console's Notebook panel, they just work. Started yourself (`jupyter lab`), set `MXC_API_KEY` (and optionally `MXC_BASE_URL`) in the environment before starting Jupyter."))
    cells.append(("code", 'import os\nBASE_URL = (os.environ.get("MXC_BASE_URL") or os.environ.get("HOTFIRE_BASE_URL")\n            or os.environ.get("MST_BASE_URL") or "http://127.0.0.1:' + String(port) + '/v1")\nAPI_KEY = (os.environ.get("MXC_API_KEY") or os.environ.get("HOTFIRE_API_KEY") or os.environ["MST_API_KEY"])  # create one in omxconsole: API keys › New key\nMODEL = "' + name + '"\nprint(BASE_URL, MODEL)'))
    cells.append(("markdown", "### OpenAI client"))
    cells.append(("code", 'from openai import OpenAI\nclient = OpenAI(base_url=BASE_URL, api_key=API_KEY)\nreply = client.chat.completions.create(\n    model=MODEL,\n    messages=[{"role": "user", "content": "In one sentence, what are you?"}],\n)\nprint(reply.choices[0].message.content)'))
    cells.append(("markdown", "### Streaming"))
    cells.append(("code", 'stream = client.chat.completions.create(\n    model=MODEL,\n    messages=[{"role": "user", "content": "Count from 1 to 10."}],\n    stream=True,\n)\nfor chunk in stream:\n    print(chunk.choices[0].delta.content or "", end="", flush=True)'))
    cells.append(("markdown", "### Raw HTTP with httpx"))
    cells.append(("code", 'import httpx\nr = httpx.post(f"{BASE_URL}/chat/completions", headers={"Authorization": f"Bearer {API_KEY}"},\n               json={"model": MODEL, "messages": [{"role": "user", "content": "Hello!"}]}, timeout=60)\nprint(r.json()["choices"][0]["message"]["content"])'))
    var out = String("[")
    for i in range(len(cells)):
        out += (", " if i > 0 else "") + '{"type": ' + json_string(cells[i][0]) + ', "source": ' + json_string(cells[i][1]) + ', "outputs": []}'
    return _reply(name, path, True, arch_json, out + "]")


def _g(x: Float64) -> String:
    """Python's :g for small ratios (7.0 → 7, 3.5 → 3.5)."""
    if x == Float64(Int(x)):
        return String(Int(x))
    return String(x)


def _one(x: Float64) -> String:
    var neg = x < 0
    var c = Int(abs(x) * 10 + 0.5)
    return ("-" if neg else "") + String(c // 10) + "." + String(c % 10)


def _reply(name: String, path: String, generated: Bool, arch: String, cells: String) -> String:
    return ('{"name": ' + json_string(name) + ', "path": ' + json_string(path) + ', "generated": ' + ("true" if generated else "false")
            + ', "kernelspec": {"name": "python3", "display_name": "Python 3", "language": "python"}, "architecture": ' + arch
            + ', "cells": ' + cells + "}")
