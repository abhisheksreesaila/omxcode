"""mojoui/plugin_py.py: the model plugins that run on Python libraries, in the app's own process (goal 68: mojoui.plugins,
mojoui.addmodel). Loaded from its file by mojoui.pluginrun (never through sys.path); every call is short, and the long
ones (a download, loading a model, running it on every row or frame) run on a thread of their own and report progress
through `job(key)`, so the app's window (and the web host's server, which needs the GIL) stays live.

Hub:     preflight(text) → JSON: what it is, its size, whether it fits the GPU, its licence, whether it can run (why not),
         whether it runs its own code; download(repo, folder, allow_code) starts the download (job "dl:<folder>").
Models:  load(folder) starts loading (job "load:<folder>"); then, synchronously, classify_image(folder, addr, w, h),
         detect(folder, addr, w, h, queries), embed_text(folder, texts), tabular(folder, columns); run_*(…) do the same
         over every frame or row on a thread (job "run:<folder>").

Safety (code and weights from outside): weights are read as safetensors (transformers' use_safetensors=True), ONNX or
skops only; files named like pickles are never downloaded; a model's own Python files are downloaded and run
(trust_remote_code) only when the person allowed it for that model; skops files load only when every type in them is
scikit-learn's, NumPy's or SciPy's; ONNX Runtime gets no custom-op libraries.
"""
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request

HUB = os.environ.get("MOJOUI_HF_BASE", "https://huggingface.co")
LIMIT_BYTES = 2_000_000_000  # (goal 68: models over 2 GB are out of bounds)
JOBS = {}  # key → {"state": running|done|failed|cancelled, "done", "total", "error", "result"}
MODELS = {}  # folder → loaded model
LOCK = threading.Lock()

TASKS = {  # Hub pipeline_tag → (kind, what it does, in words)
    "image-classification": ("classify-image", "names what a picture shows"),
    "object-detection": ("detect", "finds things in a picture, with boxes"),
    "zero-shot-object-detection": ("detect", "finds things you name in a picture, with boxes"),
    "feature-extraction": ("embed-text", "turns text into numbers that compare by meaning"),
    "sentence-similarity": ("embed-text", "turns text into numbers that compare by meaning"),
    "image-segmentation": ("segment", "outlines things in a picture"),
    "mask-generation": ("segment", "outlines things in a picture"),
}
KEEP = re.compile(r"^(config\.json|preprocessor_config\.json|image_processor_config\.json|processor_config\.json|tokenizer\.json|"
                  r"tokenizer_config\.json|special_tokens_map\.json|vocab\.txt|vocab\.json|merges\.txt|added_tokens\.json|"
                  r"spiece\.model|sentencepiece\.bpe\.model|modules\.json|sentence_bert_config\.json|config_sentence_transformers\.json|"
                  r"1_Pooling/config\.json|generation_config\.json|[^/]*\.safetensors|model\.safetensors\.index\.json|README\.md)$")
PICKLE = re.compile(r"\.(bin|pt|pth|pkl|pickle|joblib|ckpt|h5|msgpack|npy|npz|dill|sav)$", re.I)  # (mojoui/plugins.mojo's PICKLES too)


def _get(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": "omxcode"})
    tok = os.environ.get("HF_TOKEN")
    if tok and url.startswith(HUB):
        req.add_unredirected_header("Authorization", "Bearer " + tok)
    return urllib.request.urlopen(req, timeout=timeout)


def repo_of(text):
    """A pasted name or link → "owner/name" ("" when it isn't one)."""
    t = text.strip()
    m = re.match(r"^(?:https?://)?(?:www\.)?(?:huggingface\.co|hf\.co)/([^/\s]+/[^/\s?#]+)", t)
    if m:
        t = m.group(1)
    t = t.removeprefix("hf:").strip("/")
    return t if re.match(r"^[A-Za-z0-9][\w.-]*/[\w.-]+$", t) else ""


def _gpu_free():
    """(free bytes, total bytes, name) of the first GPU; (0, 0, "") when there's none."""
    try:
        import torch

        if torch.cuda.is_available():
            free, total = torch.cuda.mem_get_info()
            return free, total, torch.cuda.get_device_name(0)
    except Exception:
        pass
    try:
        out = os.popen("nvidia-smi --query-gpu=memory.free,memory.total,name --format=csv,noheader,nounits 2>/dev/null").read().strip()
        if out:
            free, total, name = [x.strip() for x in out.splitlines()[0].split(",", 2)]
            return int(free) * 2**20, int(total) * 2**20, name
    except Exception:
        pass
    return 0, 0, ""


def _mb(n):
    return f"{n / 2**30:.1f} GB" if n >= 2**30 else f"{max(n / 2**20, 0.1):.0f} MB" if n >= 2**20 else f"{n / 1024:.0f} KB"


def _params(n):
    return f"{n / 1e9:.1f}B" if n >= 1e9 else f"{n / 1e6:.1f}M" if n >= 1e6 else f"{n / 1e3:.0f}K"


def preflight(text):
    """Everything said before a byte of the model downloads, as JSON (the app shows `line`, and `why` when it can't)."""
    repo = repo_of(text)
    out = {"repo": repo, "can_run": False, "why": "", "line": "", "kind": "", "licence": "", "bytes": 0, "remote_code": False,
           "code_files": [], "files": [], "sha": "", "about": "", "task": "", "fits": ""}
    if not repo:
        out["why"] = "Paste a Hugging Face model name (owner/name) or its link, or drop a model file or folder"
        out["line"] = out["why"]
        return json.dumps(out)
    try:
        info = json.load(_get(f"{HUB}/api/models/{repo}?blobs=true"))
    except urllib.error.HTTPError as e:
        out["why"] = f"{repo}: the Hub says {e.code} ({'no such model' if e.code in (401, 404) else e.reason}): nothing downloaded"
        out["line"] = out["why"]
        return json.dumps(out)
    except Exception as e:  # noqa: BLE001 (offline, DNS: said in words)
        out["why"] = f"Couldn't reach the Hugging Face Hub ({type(e).__name__}): check the connection; nothing downloaded"
        out["line"] = out["why"]
        return json.dumps(out)
    task = info.get("pipeline_tag") or ""
    card = info.get("cardData") or {}
    lic = card.get("license") or next((t[8:] for t in info.get("tags", []) if t.startswith("license:")), "") or "not stated"
    if isinstance(lic, list):
        lic = ", ".join(lic)
    cfg = info.get("config") or {}
    files = [(s["rfilename"], s.get("size") or (s.get("lfs") or {}).get("size") or 0) for s in info.get("siblings", [])]
    code = [f for f, _ in files if f.endswith(".py")]
    remote = bool(cfg.get("auto_map")) or bool(code)
    st = info.get("safetensors") or {}
    params = st.get("total") or 0
    keep = [(f, n) for f, n in files if KEEP.match(f) and not PICKLE.search(f)]
    weights = [(f, n) for f, n in keep if f.endswith(".safetensors")]
    # (a repo with weights in a subfolder only (onnx/, openvino/) or several variants: the root's safetensors)
    size = sum(n for _, n in keep)
    arch = (cfg.get("architectures") or [cfg.get("model_type") or ""])[0]
    out.update(task=task, licence=lic, bytes=size, remote_code=remote, code_files=code, sha=info.get("sha", ""),
               files=[f for f, _ in keep] + (code if remote else []),
               sizes={f: n for f, n in files if (f, n) in keep or (remote and f.endswith(".py"))},
               shas={s["rfilename"]: (s.get("lfs") or {}).get("sha256", "") for s in info.get("siblings", [])})
    kind, does = TASKS.get(task, ("", ""))
    out["kind"] = kind
    out["about"] = does
    free, total, gpu = _gpu_free()
    need = int(size * 1.3) + 200 * 2**20
    if gpu:
        out["fits"] = (f"fits the GPU ({_mb(size)} of {_mb(free)} free on {gpu})" if need <= free else
                       f"doesn't fit the GPU now ({_mb(need)} needed, {_mb(free)} free): it would run on the CPU, slowly")
    else:
        out["fits"] = "no GPU here: it runs on the CPU"
    what = f"{arch}, " if arch else ""
    what += f"{_params(params)} parameters, " if params else ""
    head = f"{repo}: {does or task or 'a model'} ({what}{_mb(size)})"
    why = ""
    if info.get("gated"):
        why = "it's gated: accept its terms on huggingface.co and set HF_TOKEN, then try again"
    elif not kind:
        why = f"a {task or 'model without a task tag'} model: this version runs picture classifiers, detectors, segmenters, text embedders and decision models"
    elif not weights:
        why = "its weights aren't in safetensors (only a pickle such as pytorch_model.bin, which can run code when loaded): not loaded, for safety"
    elif size > LIMIT_BYTES:
        why = f"it's {_mb(size)}: over the 2 GB this version takes"
    elif kind == "segment":
        why = "segmenters from the Hub aren't run yet (SAM 2.1 runs as a built-in)"
    out["can_run"] = not why
    out["why"] = (why[0].upper() + why[1:] + ". Nothing downloaded.") if why else ""
    out["line"] = f"{head} · {out['fits']} · licence {lic}"  # (why it can't run is said once, under it)
    if remote and not why:
        out["line"] += f" · it runs its own code ({', '.join(code[:3]) or 'auto_map in config.json'}) inside this app: only after you allow it"
    return json.dumps(out)


def job(key):
    with LOCK:
        j = JOBS.get(key)
        return json.dumps({k: v for k, v in j.items() if k != "result"} if j else {"state": "none"})


def cancel(key):
    with LOCK:
        if key in JOBS and JOBS[key]["state"] == "running":
            JOBS[key]["cancel"] = True


def _start(key, total, fn):
    with LOCK:
        if key in JOBS and JOBS[key]["state"] == "running":
            return
        JOBS[key] = {"state": "running", "done": 0, "total": total, "error": "", "cancel": False, "result": None, "t0": time.time()}

    def body():
        try:
            r = fn(JOBS[key])
            with LOCK:
                JOBS[key]["state"] = "cancelled" if JOBS[key]["cancel"] else "done"
                JOBS[key]["result"] = r
        except Exception as e:  # noqa: BLE001 (said in words in the app)
            with LOCK:
                JOBS[key]["state"] = "failed"
                JOBS[key]["error"] = f"{type(e).__name__}: {e}"[:600]

    threading.Thread(target=body, daemon=True).start()


def download(repo, folder, files_json, sha, allow_code, sizes_json="{}", shas_json="{}"):
    """The files preflight kept into folder/model (resumable .part files, each tried up to 5 times), on a thread:
    job "dl:<folder>". sizes_json: preflight's sizes (the Hub's), checked against what arrives."""
    files = [f for f in json.loads(files_json) if (allow_code or not f.endswith(".py")) and not PICKLE.search(f)]
    sizes = json.loads(sizes_json)
    shas = {k: v for k, v in json.loads(shas_json).items() if v}
    dest = os.path.join(folder, "model")

    def one(j, f, url, path, done0):
        part = path + ".part"
        for attempt in range(5):
            have = os.path.getsize(part) if os.path.exists(part) else 0
            want = sizes.get(f, 0)
            if want and have >= want:
                break
            req = urllib.request.Request(url, headers={"User-Agent": "omxcode"})
            if os.environ.get("HF_TOKEN"):
                req.add_unredirected_header("Authorization", "Bearer " + os.environ["HF_TOKEN"])
            if have:
                req.add_header("Range", f"bytes={have}-")
            try:
                with urllib.request.urlopen(req, timeout=60) as r, open(part, "ab" if (have and r.status == 206) else "wb") as out:
                    if have and r.status != 206:  # (the server sent the whole file, not the rest: start over)
                        have = 0
                    while True:
                        if j["cancel"]:
                            return False
                        b = r.read(1 << 20)
                        if not b:
                            break
                        out.write(b)
                        have += len(b)
                        j["done"] = done0 + have
                if not want:
                    break
            except (OSError, urllib.error.URLError) as e:
                j["retries"] = j.get("retries", 0) + 1
                if attempt == 4:
                    raise IOError(f"{f}: {e} (after 5 tries)")
                time.sleep(1.5 * (attempt + 1))
        if sizes.get(f) and os.path.getsize(part) != sizes[f]:
            got = os.path.getsize(part)
            if got > sizes[f]:
                os.remove(part)  # (more than the Hub says: start over next time)
            raise IOError(f"{f}: got {got} bytes of {sizes[f]}")
        if shas.get(f):  # (an LFS file: its sha256 as the Hub lists it)
            import hashlib

            h = hashlib.sha256()
            with open(part, "rb") as got:
                for b in iter(lambda: got.read(1 << 20), b""):
                    h.update(b)
            if h.hexdigest() != shas[f]:
                os.remove(part)
                raise IOError(f"{f}: its sha256 isn't the Hub's: removed")
        os.replace(part, path)
        return True

    def run(j):
        j["total"] = sum(sizes.get(f, 0) for f in files)
        done = 0
        for f in files:
            if os.path.isabs(f) or ".." in f.split("/"):
                raise ValueError(f"a file name that leaves the folder: {f}")
            path = os.path.join(dest, f)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if not (os.path.exists(path) and (not sizes.get(f) or os.path.getsize(path) == sizes[f])):
                if not one(j, f, f"{HUB}/{repo}/resolve/{sha or 'main'}/{urllib.parse.quote(f)}", path, done):
                    return None
            done += os.path.getsize(path)
            j["done"] = done
        return dest

    _start("dl:" + folder, 0, run)


# ------------------------------------------------------------------------------------------------------------ models


def _spec(folder):
    with open(os.path.join(folder, "plugin.json")) as f:
        return json.load(f)


def _inside(folder, rel):
    full = os.path.realpath(os.path.join(folder, rel))
    if not full.startswith(os.path.realpath(folder) + os.sep):
        raise ValueError(f"{rel}: outside the plugin's folder")
    if PICKLE.search(rel):
        raise ValueError(f"{rel}: a pickle (it can run code when loaded): refused")
    return full


def _skip_unsafe(folder, names):
    """shutil.copytree's ignore: pickles and partial downloads are never copied in."""
    return [n for n in names if PICKLE.search(n) or n.endswith(".part")]


def _safe_skops_type(name):
    """A type a skops file may hold: a class (never a function) from scikit-learn, NumPy or SciPy, and never one that
    calls a function it was given (FunctionTransformer)."""
    import importlib
    import inspect

    import sys

    root = name.split(".")[0]
    if root not in ("sklearn", "numpy", "scipy") or "Function" in name:
        return False
    importlib.import_module(root)  # (the package itself; never a submodule the file names: importing one runs its code)
    mod, _, attr = name.rpartition(".")
    m = sys.modules.get(mod)
    obj = getattr(m, attr, None) if m is not None else None
    return obj is not None and inspect.isclass(obj)


def _load(folder, j):
    spec = _spec(folder)
    runner, kind = spec["runner"], spec["kind"]
    params = spec.get("params") or {}
    files = spec.get("files") or {}
    remote = bool(spec.get("trust_remote_code")) and allowed(spec.get("source", ""))  # (plugin.json's word and the person's recorded yes)
    m = {"spec": spec, "kind": kind, "runner": runner}
    if runner == "onnx":
        import onnxruntime as ort

        so = ort.SessionOptions()
        m["session"] = ort.InferenceSession(_inside(folder, files["model"]), so, providers=["CPUExecutionProvider"])
    elif runner == "skops":
        import skops.io as sio

        path = _inside(folder, files["model"])
        untrusted = sio.get_untrusted_types(file=path)
        bad = [t for t in untrusted if not _safe_skops_type(t)]
        if bad:
            raise ValueError(f"the skops file holds types that aren't scikit-learn, NumPy or SciPy classes: {', '.join(bad[:4])}: not loaded")
        m["model"] = sio.load(path, trusted=untrusted)
    elif runner == "torch":
        import torch
        import transformers as tf

        src = os.path.realpath(os.path.join(folder, files.get("model", "model")))
        if not src.startswith(os.path.realpath(folder) + os.sep):
            raise ValueError("the model's folder is outside its plugin's folder")
        dev = "cuda" if torch.cuda.is_available() else "cpu"
        m["device"] = dev
        common = {"local_files_only": True, "trust_remote_code": remote}
        if kind == "classify-image":
            m["proc"] = tf.AutoImageProcessor.from_pretrained(src, **common)
            m["net"] = tf.AutoModelForImageClassification.from_pretrained(src, use_safetensors=True, **common)
        elif kind == "detect" and params.get("zero_shot"):
            m["proc"] = tf.AutoProcessor.from_pretrained(src, **common)
            m["net"] = tf.AutoModelForZeroShotObjectDetection.from_pretrained(src, use_safetensors=True, **common)
        elif kind == "detect":
            m["proc"] = tf.AutoImageProcessor.from_pretrained(src, **common)
            m["net"] = tf.AutoModelForObjectDetection.from_pretrained(src, use_safetensors=True, **common)
        elif kind == "embed-text":
            m["tok"] = tf.AutoTokenizer.from_pretrained(src, **common)
            m["net"] = tf.AutoModel.from_pretrained(src, use_safetensors=True, **common)
            m["pooling"] = params.get("pooling", "mean")
            m["prefix"] = params.get("prefix", "")
        else:
            raise ValueError(f"a {kind} model can't run on torch yet")
        m["net"] = m["net"].to(dev).eval()
    else:
        raise ValueError(f"runner {runner} isn't a Python one")
    return m


def load(folder):
    """Loads folder's model on a thread (job "load:<folder>"); a loaded one stays for the life of the process."""
    if folder in MODELS:
        with LOCK:
            JOBS["load:" + folder] = {"state": "done", "done": 1, "total": 1, "error": "", "cancel": False, "result": None}
        return

    def run(j):
        t0 = time.time()
        MODELS[folder] = _load(folder, j)
        MODELS[folder]["load_s"] = time.time() - t0
        return None

    _start("load:" + folder, 1, run)


def loaded(folder):
    return folder in MODELS


def _picture(addr, w, h):
    """An RGBA frame at addr (Mojo's List[UInt32]) as an RGB PIL image, copied once."""
    import ctypes

    import numpy as np
    from PIL import Image

    buf = (ctypes.c_uint8 * (w * h * 4)).from_address(addr)
    a = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 4)[:, :, :3].copy()
    return Image.fromarray(a)


def _classify(m, img, top):
    import torch

    with torch.inference_mode():
        x = m["proc"](images=img, return_tensors="pt").to(m["device"])
        p = m["net"](**x).logits.softmax(-1)[0]
    s, i = p.topk(min(top, p.shape[0]))
    names = m["net"].config.id2label
    return [(names[int(k)], float(v)) for v, k in zip(s, i)]


def _detect(m, img, queries, threshold):
    import torch

    threshold = float((m["spec"].get("params") or {}).get("threshold", threshold))  # (zero-shot detectors score lower: theirs is 0.2)

    with torch.inference_mode():
        if m["spec"].get("params", {}).get("zero_shot"):
            words = [q.strip() for q in queries.split(",") if q.strip()] or ["a person"]
            x = m["proc"](text=[words], images=img, return_tensors="pt").to(m["device"])
            out = m["net"](**x)
            r = m["proc"].post_process_object_detection(out, threshold=threshold, target_sizes=[img.size[::-1]])[0] \
                if hasattr(m["proc"], "post_process_object_detection") else \
                m["proc"].post_process_grounded_object_detection(out, threshold=threshold, target_sizes=[img.size[::-1]])[0]
            names = lambda k: words[int(k)]  # noqa: E731
        else:
            x = m["proc"](images=img, return_tensors="pt").to(m["device"])
            out = m["net"](**x)
            r = m["proc"].post_process_object_detection(out, threshold=threshold, target_sizes=[img.size[::-1]])[0]
            names = lambda k: m["net"].config.id2label[int(k)]  # noqa: E731
    boxes = []
    for s, k, b in zip(r["scores"], r["labels"], r["boxes"]):
        x0, y0, x1, y1 = [float(v) for v in b]
        boxes.append((names(k), float(s), x0, y0, x1 - x0, y1 - y0))
    boxes.sort(key=lambda b: -b[1])
    return boxes


def _embed(m, texts):
    import torch

    out = []
    with torch.inference_mode():
        for i in range(0, len(texts), 256):
            batch = [m["prefix"] + t for t in texts[i:i + 256]]
            x = m["tok"](batch, padding=True, truncation=True, max_length=256, return_tensors="pt").to(m["device"])
            h = m["net"](**x).last_hidden_state
            if m["pooling"] == "cls":
                v = h[:, 0]
            else:
                mask = x["attention_mask"].unsqueeze(-1).to(h.dtype)
                v = (h * mask).sum(1) / mask.sum(1).clamp(min=1)
            out.append(torch.nn.functional.normalize(v.float(), dim=-1).cpu())
    return torch.cat(out).numpy() if out else None


def classify_image(folder, addr, w, h, top=5):
    """[(label, score)] best first, as JSON."""
    return json.dumps(_classify(MODELS[folder], _picture(addr, w, h), top))


def detect(folder, addr, w, h, queries="", threshold=0.5):
    """[(kind, score, x, y, w, h)] in the picture's pixels, best first, as JSON."""
    return json.dumps(_detect(MODELS[folder], _picture(addr, w, h), queries, threshold))


def embed_text(folder, texts_json):
    """Each text's vector (L2-normalised), flat, as a list of floats; then its length (dim) last."""
    v = _embed(MODELS[folder], json.loads(texts_json))
    return list(v.flatten().tolist()) + [float(v.shape[1])]


def tabular(folder, columns_json):
    """A tabular (ONNX or skops) model on rows: columns_json is [[col0…], [col1…], …] in the plugin's input order.
    Returns JSON {"labels": [...] or null, "values": [[...] per row]} (class probabilities, or one value)."""
    import numpy as np

    m = MODELS[folder]
    X = np.asarray(json.loads(columns_json), dtype=np.float64).T
    classes = (m["spec"].get("params") or {}).get("classes")
    if m["runner"] == "onnx":
        s = m["session"]
        name = s.get_inputs()[0].name
        outs = s.run(None, {name: X.astype(np.float32)})
        probs = outs[-1] if len(outs) > 1 else outs[0]
        probs = np.asarray(probs, dtype=np.float64).reshape(len(X), -1)
        return json.dumps({"labels": classes, "values": probs.tolist()})
    model = m["model"]
    if hasattr(model, "predict_proba"):
        p = model.predict_proba(X)
        return json.dumps({"labels": classes or [str(c) for c in model.classes_], "values": p.tolist()})
    return json.dumps({"labels": None, "values": model.predict(X).reshape(len(X), -1).tolist()})


def run_video(folder, path, every, queries="", threshold=0.5):
    """The model on every `every`-th frame of the video at path, on a thread (job "run:<folder>"): rows of
    (frame, t, label, score[, x, y, w, h]) when it's done. Frames come from ffmpeg (as mojoui.video reads them)."""
    import subprocess

    import numpy as np
    from PIL import Image

    probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                                       "stream=width,height,r_frame_rate,nb_read_packets", "-of", "json", path],
                                      capture_output=True, text=True, check=True).stdout)["streams"][0]
    w, h, n = int(probe["width"]), int(probe["height"]), int(probe["nb_read_packets"])
    a, b = probe["r_frame_rate"].split("/")
    fps = float(a) / float(b)
    m = MODELS[folder]

    def run(j):
        j["total"] = n
        rows = []
        p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
        try:
            for f in range(n):
                raw = p.stdout.read(w * h * 3)
                if len(raw) < w * h * 3 or j["cancel"]:
                    break
                j["done"] = f + 1
                if f % every:
                    continue
                img = Image.fromarray(np.frombuffer(raw, np.uint8).reshape(h, w, 3))
                if m["kind"] == "classify-image":
                    label, score = _classify(m, img, 1)[0]
                    rows.append([f, f / fps, label, score])
                else:
                    for box in _detect(m, img, queries, threshold):
                        rows.append([f, f / fps, *box])
        finally:
            p.kill()
        return rows

    _start("run:" + folder, n, run)


def run_texts(folder, texts_json):
    """Every text's vector on a thread (job "run:<folder>"): the result is the matrix (texts × dim)."""
    texts = json.loads(texts_json)
    m = MODELS[folder]

    def run(j):
        j["total"] = len(texts)
        out = []
        for i in range(0, len(texts), 512):
            if j["cancel"]:
                break
            out.append(_embed(m, texts[i:i + 512]))
            j["done"] = min(i + 512, len(texts))
        import numpy as np

        return np.concatenate(out) if out else None

    _start("run:" + folder, len(texts), run)


def result_rows(key):
    """A finished job's rows (run_video) as JSON."""
    with LOCK:
        r = JOBS.get(key, {}).get("result")
    return json.dumps(r if isinstance(r, list) else [])


def similar(key, row_index):
    """After run_texts: every text's cosine to text row_index, as a list of floats."""
    with LOCK:
        v = JOBS.get(key, {}).get("result")
    if v is None:
        return []
    return list((v @ v[row_index]).astype(float).tolist())


def model_stats(folder):
    m = MODELS.get(folder) or {}
    vram = 0.0
    try:
        import torch

        if torch.cuda.is_available():
            vram = torch.cuda.memory_allocated() / 2**20
    except Exception:
        pass
    return json.dumps({"load_s": m.get("load_s", 0.0), "vram_mb": vram, "device": m.get("device", "cpu")})


OUTPUTS = {
    "classify-image": [{"name": "label", "type": "text"}, {"name": "score", "type": "number"}],
    "detect": [{"name": "kind", "type": "text"}, {"name": "score", "type": "number"}, {"name": "x", "type": "number"},
               {"name": "y", "type": "number"}, {"name": "w", "type": "number"}, {"name": "h", "type": "number"}],
    "embed-text": [{"name": "vector", "type": "vector"}],
    "segment": [{"name": "mask", "type": "image"}],
}


def plugin_name(repo):
    """A function name for a repo: its last part, lower case, letters, digits and _ ("yolos_tiny")."""
    n = re.sub(r"[^a-z0-9_]+", "_", repo.split("/")[-1].lower()).strip("_")
    n = re.sub(r"_+", "_", n)[:32].strip("_") or "model"
    return ("m_" + n) if n[0].isdigit() else n


def _consents():
    """The app's own record of a person's yes to a model's code: <config>/allowed-model-code.txt, a line per hf:repo@sha
    ($OMX_CONFIG, else ~/.config/omxcode). plugin.json's trust_remote_code alone never runs code (a folder could say so)."""
    base = os.environ.get("OMX_CONFIG") or os.path.join(os.path.expanduser("~"), ".config", "omxcode")
    return os.path.join(base, "allowed-model-code.txt")


def allowed(source):
    try:
        with open(_consents()) as f:
            return source in {l.strip() for l in f}
    except OSError:
        return False


def write_plugin(folder, preflight_json, allow_code):
    """folder/plugin.json for a downloaded Hub model (runner torch), from what preflight said and the files it got."""
    p = json.loads(preflight_json)
    params = {}
    if p["task"] == "zero-shot-object-detection":
        params["zero_shot"] = True
        params["queries"] = "a person, a robot, a box, a chair"
        params["threshold"] = 0.2
    if p["kind"] == "embed-text":
        pool = os.path.join(folder, "model", "1_Pooling", "config.json")
        if os.path.exists(pool):
            with open(pool) as f:
                c = json.load(f)
            params["pooling"] = "cls" if c.get("pooling_mode_cls_token") else "mean"
        if "e5" in p["repo"].lower():
            params["prefix"] = "query: "
    spec = {"format": "omx-plugin/1", "name": plugin_name(p["repo"]), "kind": p["kind"], "runner": "torch",
            "about": p["about"], "licence": p["licence"], "source": "hf:" + p["repo"] + ("@" + p["sha"] if p["sha"] else ""),
            "inputs": [{"name": "text", "type": "text"}] if p["kind"] == "embed-text" else [{"name": "frame", "type": "image"}],
            "outputs": OUTPUTS.get(p["kind"], []), "files": {"model": "model"}, "params": params,
            "trust_remote_code": bool(allow_code and p["remote_code"])}
    with open(os.path.join(folder, "plugin.json"), "w") as f:
        json.dump(spec, f, indent=2)
    if spec["trust_remote_code"]:  # (the person's yes, for this repo at this commit only)
        os.makedirs(os.path.dirname(_consents()), exist_ok=True)
        with open(_consents(), "a") as f:
            f.write(spec["source"] + "\n")
    return spec["name"]


def preflight_start(key, text):
    """preflight(text) on a thread: job key's result is its JSON (what the app shows before anything downloads)."""
    _start(key, 1, lambda j: preflight(text))


def result_text(key):
    with LOCK:
        r = JOBS.get(key, {}).get("result")
    return r if isinstance(r, str) else ""


def file_plugin(path, plugins_dir):
    """A model file or folder a person dropped → a plugin folder in plugins_dir (copied, never linked), as JSON
    {"folder", "name", "kind", "line", "why"}. Files: XGBoost JSON, LightGBM text, Learn's tree (omx-tree/1), ONNX,
    skops; folders: one with plugin.json (checked by the app after), or a Hugging Face model folder (config.json and
    safetensors). Pickles and anything else are refused with the reason."""
    import shutil

    path = os.path.abspath(path)
    out = {"folder": "", "name": "", "kind": "", "line": "", "why": ""}
    base = os.path.basename(path.rstrip("/"))
    stem = re.sub(r"\.(json|txt|onnx|skops)$", "", base)
    stem = re.sub(r"\.(xgb|lgb|tree|model)$", "", stem)
    name = plugin_name(stem)
    if not os.path.exists(path):
        out["why"] = f"{path}: no such file or folder"
    elif PICKLE.search(base):
        out["why"] = f"{base} is a pickle (it can run code when loaded): save the model as XGBoost JSON, LightGBM text, ONNX or skops instead. Nothing added."
    if out["why"]:
        out["line"] = out["why"]
        return json.dumps(out)
    dest = os.path.join(plugins_dir, name)
    k = 2
    while os.path.exists(dest):
        dest = os.path.join(plugins_dir, f"{name}_{k}")
        k += 1
    name = os.path.basename(dest)
    spec = {"format": "omx-plugin/1", "name": name, "kind": "tabular", "runner": "tree", "about": "", "licence": "yours",
            "source": "file:" + base, "inputs": [], "outputs": [{"name": "label", "type": "text"}, {"name": "score", "type": "number"}],
            "files": {"model": ""}, "params": {}, "trust_remote_code": False}
    if os.path.isdir(path):
        root = os.path.realpath(path)
        for d, dirs, files in os.walk(path):
            for f in dirs + files:
                full = os.path.join(d, f)
                if os.path.islink(full) and not os.path.realpath(full).startswith(root + os.sep):
                    out["why"] = f"{os.path.relpath(full, path)} is a link out of the folder: copy the real file in. Nothing added."
                    out["line"] = out["why"]
                    return json.dumps(out)
        if os.path.exists(os.path.join(path, "plugin.json")):
            shutil.copytree(path, dest, symlinks=False, ignore=_skip_unsafe)
            with open(os.path.join(dest, "plugin.json")) as f:
                s = json.load(f)
            if s.get("runner") not in ("tree", "onnx", "skops", "torch"):
                shutil.rmtree(dest)
                out["why"] = (f"{base}: a {s.get('runner')} plugin: compiled packs (MAX) are added only by scripts/packs into the packs folder, "
                              "never by a drop. Nothing added.")
                out["line"] = out["why"]
                return json.dumps(out)
            s["name"] = name
            s["trust_remote_code"] = False  # (a dropped folder never brings its own yes: only the Hub path's Allow writes it)
            with open(os.path.join(dest, "plugin.json"), "w") as f:
                json.dump(s, f, indent=1)
            out.update(folder=dest, name=name, kind=s.get("kind", ""), line=f"{base}: a model plugin ({s.get('kind')}, {s.get('runner')}) · {s.get('about', '')}")
            return json.dumps(out)
        cfg_path = os.path.join(path, "config.json")
        if not os.path.exists(cfg_path) or not any(f.endswith(".safetensors") for f in os.listdir(path)):
            out["why"] = f"{base}: a folder without plugin.json, or a Hugging Face model (config.json and .safetensors weights). Nothing added."
            out["line"] = out["why"]
            return json.dumps(out)
        with open(cfg_path) as f:
            arch = (json.load(f).get("architectures") or [""])[0]
        kind = "classify-image" if "ImageClassification" in arch else "detect" if "ObjectDetection" in arch else "embed-text" if arch.endswith("Model") else ""
        if not kind:
            out["why"] = f"{base}: a {arch or 'model'} (this version runs picture classifiers, detectors and text embedders). Nothing added."
            out["line"] = out["why"]
            return json.dumps(out)
        os.makedirs(dest)
        shutil.copytree(path, os.path.join(dest, "model"), symlinks=False, ignore=_skip_unsafe)
        spec.update(kind=kind, runner="torch", inputs=[{"name": "text", "type": "text"}] if kind == "embed-text" else [{"name": "frame", "type": "image"}],
                    outputs=OUTPUTS[kind], files={"model": "model"}, about=f"{arch} from {base}")
        if "ZeroShot" in arch or "Owl" in arch:
            spec["params"] = {"zero_shot": True, "queries": "a person, a robot, a box, a chair", "threshold": 0.2}
    else:
        os.makedirs(dest)
        low = base.lower()
        with open(path, "rb") as f:
            head = f.read(4096)
        if low.endswith(".onnx"):
            spec.update(runner="onnx", about="an ONNX model")
            target = "model.onnx"
        elif low.endswith(".skops"):
            spec.update(runner="skops", about="a scikit-learn model (skops)")
            target = "model.skops"
        elif head.lstrip().startswith(b"{"):
            j = json.load(open(path))
            if "learner" in j:
                spec["about"] = "an XGBoost model"
                spec["inputs"] = [{"name": n, "type": "number"} for n in j["learner"].get("feature_names") or []]
                classes = (j["learner"].get("attributes") or {}).get("classes")  # (Booster.set_attr(classes="a,b,c"))
                if classes:
                    spec["params"] = {"classes": classes.split(",")}
            elif j.get("format") == "omx-tree/1":
                spec["about"] = "a decision tree Learn made"
                spec["inputs"] = [{"name": n, "type": "number"} for n in j.get("features", [])]
                spec["params"] = {"classes": j.get("classes", [])}
            else:
                shutil.rmtree(dest)
                out["why"] = f"{base}: a JSON file that isn't an XGBoost model or a Learn tree. Nothing added."
                out["line"] = out["why"]
                return json.dumps(out)
            target = "model.json"
        elif head.startswith(b"tree") or b"\nTree=" in open(path, "rb").read():
            spec["about"] = "a LightGBM model"
            for line in open(path):
                if line.startswith("feature_names="):
                    spec["inputs"] = [{"name": n, "type": "number"} for n in line.strip()[14:].split(" ")]
                    break
            target = "model.txt"
        else:
            shutil.rmtree(dest)
            out["why"] = f"{base}: not a model file this version reads (XGBoost JSON, LightGBM text, Learn's tree, ONNX, skops). Nothing added."
            out["line"] = out["why"]
            return json.dumps(out)
        shutil.copyfile(path, os.path.join(dest, target))
        spec["files"] = {"model": target}
        if spec["runner"] == "skops":  # (its own feature names and classes, read without loading it)
            try:
                import skops.io as sio

                untrusted = sio.get_untrusted_types(file=os.path.join(dest, target))
                if all(_safe_skops_type(t) for t in untrusted):
                    m = sio.load(os.path.join(dest, target), trusted=untrusted)
                    names = list(getattr(m, "feature_names_in_", []))
                    spec["inputs"] = [{"name": str(n), "type": "number"} for n in names]
                    if hasattr(m, "classes_"):
                        spec["params"] = {"classes": [str(c) for c in m.classes_]}
            except Exception:
                pass
    with open(os.path.join(dest, "plugin.json"), "w") as f:
        json.dump(spec, f, indent=1)
    ins = ", ".join(i["name"] for i in spec["inputs"]) or "inputs not named in the file (add them to plugin.json)"
    out.update(folder=dest, name=name, kind=spec["kind"], line=f"{base}: {spec['about']} ({spec['kind']}, reads {ins}) · runs here, nothing downloaded")
    return json.dumps(out)
