"""Goal 43 M3, the race: the same 20 clips through the same model on the same GPU, two ways. Writes docs/goals/43/race.json.

    pixi run python scripts/dictate_race.py [--gpu 0]

A = omxcode: mojoui.speech's SpeechModel in the app's own process (scripts/dictate_race_a.mojo, built with `mojo build`
so its cold start isn't a compile), each clip handed over by address.
B = transformers.js (@huggingface/transformers, pinned in showcase/dictate-web/package.json) on WebGPU (fp16 where
the adapter allows, else fp32: B_VARIANTS), in headless Chromium on the repo's Xvfb display with goal 36's flags (showcase/js-webgpu/check_a.py). The page
gets each clip as a file it decodes before the clock starts (a headless browser has no microphone; this favours B).
Model files for B come from a local folder served by this script (downloaded once from onnx-community; their size is
recorded as download_mb, the bytes the page fetched); A reads its Hugging Face cache. Neither side downloads in the run.

Measured the same way on both sides:
- cold start: the process (A's binary, B's Chromium) starting -> the model loaded and warmed up (two 1 s silences);
- per clip: audio handed in -> final text, after one more untimed warm-up on the first clip; p50, p95; rtf = the sum of
  latencies / the sum of clip lengths; WER here (the checker recomputes it from the hypotheses);
- peak GPU memory: nvidia-smi's memory.used on the race's GPU, the peak during the side's run minus the level before it.
The GPU: one index for both. A gets CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<index>; Chromium's Vulkan/Dawn
adapter can't be pinned by a flag on two identical cards, so B runs first and the GPU whose memory rose is the one it
used (recorded as b_gpu_seen); A then runs on that index. Quiet: utilisation of that GPU over 3 s before and after.
"""

import argparse
import importlib.util
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

DATA = ROOT / "docs" / "goals" / "43"
CLIPS = DATA / "clips"
WEB = ROOT / "showcase" / "dictate-web"
A_SRC = ROOT / "scripts" / "dictate_race_a.mojo"
A_BIN = ROOT / "build" / "race" / "race_a"
MODEL_A = "openai/whisper-large-v3-turbo"
MODEL_B = "onnx-community/whisper-large-v3-turbo"
B_FILES = ["onnx/encoder_model_fp16.onnx", "onnx/decoder_model_merged_fp16.onnx", "onnx/encoder_model.onnx",
           "onnx/encoder_model.onnx_data", "onnx/decoder_model_merged.onnx", "onnx/decoder_model_merged_q4.onnx",
           "onnx/encoder_model_q4.onnx"]
# B's precisions, tried in order: fp16 first (the goal's "fp16 where it loads"); when the adapter has no shader-f16 the
# same model's fp32 export, and fp32 encoder + 4-bit decoder (what transformers.js's own WebGPU Whisper demos use for the
# decoder); the fp32 encoder is 2.5 GB of external data, which the page fails to fetch, so then the 4-bit encoder with an
# fp32 or 4-bit decoder. Every variant that loads is run; B is the one with the lowest p50 (its best chance), all recorded.
B_VARIANTS = [("fp16", "fp16"), ("fp32", "fp32"), ("fp32", "q4"), ("q4", "fp32"), ("q4", "q4")]
B_DIR = Path.home() / ".cache" / "mojoui" / "models" / MODEL_B
CHROME = os.environ.get("CHROME", "/usr/lib/chromium/chromium")
SPEECH_ENV = ROOT / ".pixi" / "envs" / "speech"


def _checker():
    spec = importlib.util.spec_from_file_location("check43", DATA.parent / "43-check.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _flags():
    spec = importlib.util.spec_from_file_location("check_a", ROOT / "showcase" / "js-webgpu" / "check_a.py")
    src = (ROOT / "showcase" / "js-webgpu" / "check_a.py").read_text()
    start = src.index("FLAGS = [")
    ns = {}
    exec(src[start:src.index("]", start) + 1], ns)  # goal 36's flag list, read from its file (not copied)
    return ns["FLAGS"]


def gpu_mem():
    out = subprocess.run(["nvidia-smi", "--query-gpu=index,memory.used", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True).stdout
    return {int(i): float(m) for i, m in (line.split(",") for line in out.strip().splitlines())}


def utilisation(index, seconds=3.0):
    vals = []
    t = time.time()
    while time.time() - t < seconds:
        out = subprocess.run(["nvidia-smi", "-i", str(index), "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True).stdout
        vals.append(float(out.strip() or 0))
        time.sleep(0.25)
    return round(statistics.mean(vals), 1), max(vals)


class Peak:
    """Samples every GPU's memory.used every 100 ms; peak minus the level when it started, per GPU."""

    def __init__(self):
        self.base = gpu_mem()
        self.peak = dict(self.base)
        self.stop = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        while not self.stop.is_set():
            for i, m in gpu_mem().items():
                self.peak[i] = max(self.peak[i], m)
            self.stop.wait(0.1)

    def rise(self):
        self.stop.set()
        return {i: self.peak[i] - self.base[i] for i in self.base}


def summarise(model, cold, results, peak_mb, refs, wer):
    ids = sorted(results)
    ms = sorted(results[i][0] for i in ids)
    p95 = ms[min(len(ms) - 1, int(round(0.95 * (len(ms) - 1))))]
    return {
        "model": model, "cold_start_s": round(cold, 2), "p50_ms": round(statistics.median(ms), 1), "p95_ms": round(p95, 1),
        "rtf": round(sum(results[i][0] for i in ids) / 1000 / sum(results[i][1] for i in ids), 4),
        "wer": round(wer([refs[i] for i in ids], [results[i][2] for i in ids]), 4), "peak_gpu_mb": round(peak_mb),
        "ms": {i: round(results[i][0], 1) for i in ids}, "hyps": {i: results[i][2] for i in ids},
    }


def run_a(index):
    if not A_BIN.exists() or A_BIN.stat().st_mtime < max(p.stat().st_mtime for p in [A_SRC, ROOT / "mojoui/speech.mojo", ROOT / "mojoui/audio.mojo"]):
        A_BIN.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["pixi", "run", "-e", "speech", "mojo", "build", "-I", ".", str(A_SRC), "-o", str(A_BIN)], cwd=ROOT, check=True)
    lib = next((SPEECH_ENV / "lib").glob("libpython3*.so.1.0"))
    env = dict(os.environ, CUDA_DEVICE_ORDER="PCI_BUS_ID", CUDA_VISIBLE_DEVICES=str(index), SPEECH_CLIPS=str(CLIPS),
               MOJO_PYTHON_LIBRARY=str(lib), PATH=f"{SPEECH_ENV / 'bin'}:{os.environ['PATH']}", CONDA_PREFIX=str(SPEECH_ENV))
    peak = Peak()
    t0 = time.perf_counter()
    p = subprocess.Popen([str(A_BIN)], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    cold, results, gpu = None, {}, ""
    for line in p.stdout:
        if line.startswith("RACE READY"):
            cold = time.perf_counter() - t0
            gpu = line.split("|", 1)[1].strip()
        elif line.startswith("RACE CLIP"):
            _, _, cid, ms, secs, *text = line.rstrip("\n").split(" ")
            results[cid] = (float(ms), float(secs), " ".join(text))
    p.wait()
    rise = peak.rise()
    if p.returncode != 0 or cold is None:
        raise SystemExit("side A failed: " + p.stderr.read()[-2000:])
    return cold, results, rise[index], gpu


def build_b():
    subprocess.run(["pixi", "run", "bash", "-c",
                    "cd showcase/dictate-web && { [ -d node_modules ] || npm install --no-fund --no-audit; } && mkdir -p dist && "
                    "esbuild main.js --bundle --format=esm --platform=browser --outfile=dist/main.js --log-level=warning && "
                    "cp node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.* dist/"], cwd=ROOT, check=True)
    missing = [f for f in B_FILES if not (B_DIR / f).exists()]
    if missing:
        subprocess.run(["pixi", "run", "-e", "speech", "python", "-c",
                        "from huggingface_hub import snapshot_download as s; "
                        f"s({MODEL_B!r}, local_dir={str(B_DIR)!r}, allow_patterns=['*.json', '*.txt', *{B_FILES!r}])"], cwd=ROOT, check=True)


def run_b(enc, dec, timeout=1800):
    headless.ensure()
    ids = sorted(w.stem for w in CLIPS.glob("*.wav"))
    state = {"ready": None, "results": {}, "done": threading.Event(), "error": None, "served": 0, "info": None}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, body, ctype):
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")  # (cross-origin isolated: threaded wasm)
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in ("/", "/index.html"):
                return self._send((WEB / "index.html").read_bytes(), "text/html")
            if path == "/clips/list":
                return self._send(json.dumps(ids).encode(), "application/json")
            if path.startswith("/clips/"):
                return self._send((CLIPS / Path(path).name).read_bytes(), "audio/wav")
            if path.startswith("/dist/"):
                f = WEB / "dist" / Path(path).name
                ctype = {".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm"}.get(f.suffix, "application/octet-stream")
                if f.exists():
                    return self._send(f.read_bytes(), ctype)
            if path.startswith("/models/" + MODEL_B + "/"):
                f = B_DIR / path[len("/models/" + MODEL_B + "/"):]
                if f.is_file() and B_DIR in f.resolve().parents:
                    body = f.read_bytes()
                    state["served"] += len(body)
                    return self._send(body, "application/json" if f.suffix == ".json" else "application/octet-stream")
            self.send_error(404)

        def do_POST(self):
            msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            now = time.perf_counter()
            if "ready" in msg:
                state["ready"] = now
                state["info"] = msg
            elif "clip" in msg:
                state["results"][msg["clip"]] = (msg["ms"], msg["seconds"], msg["text"])
            elif "error" in msg:
                state["error"] = msg["error"]
                state["done"].set()
            elif "done" in msg:
                state["done"].set()
            self._send(b"{}", "application/json")

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/index.html?model={MODEL_B}&enc={enc}&dec={dec}"
    prof = tempfile.mkdtemp(prefix="dictate-web-prof-")
    log = open(Path(prof) / "chromium.log", "w")
    peak = Peak()
    t0 = time.perf_counter()
    proc = subprocess.Popen([CHROME, f"--user-data-dir={prof}", *_flags(), f"--app={url}"], stdout=log, stderr=log, start_new_session=True)
    try:
        if not state["done"].wait(timeout):
            raise SystemExit("side B timed out")
    finally:
        rise = peak.rise()
        os.killpg(proc.pid, 15)
        proc.wait()
        srv.shutdown()
        shutil.rmtree(prof, ignore_errors=True)
    if state["error"]:
        return None, state["error"]
    return state["ready"] - t0, state["results"], rise, state["info"], state["served"] / 1e6


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gpu", type=int, default=0, help="the GPU both sides should use (nvidia-smi's index)")
    args = ap.parse_args()
    chk = _checker()
    refs = {i: t for i, _, t in chk.clips()}
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    before = utilisation(args.gpu)
    build_b()
    variants, best = [], None
    for enc, dec in B_VARIANTS:
        got = run_b(enc, dec)
        if got[0] is None:
            variants.append({"encoder": enc, "decoder": dec, "loaded": False, "error": got[1].split("\n")[0][:300]})
            print(f"B {enc}/{dec}: didn't load: {variants[-1]['error']}")
            continue
        cold, res, rise, info, mb = got
        v = summarise(MODEL_B, cold, res, rise[max(rise, key=rise.get)], refs, chk.wer)
        variants.append({"encoder": enc, "decoder": dec, "loaded": True, "p50_ms": v["p50_ms"], "p95_ms": v["p95_ms"],
                         "wer": v["wer"], "cold_start_s": v["cold_start_s"], "download_mb": round(mb, 1)})
        print(f"B {enc}/{dec}: p50 {v['p50_ms']} ms, WER {v['wer']}")
        if best is None or v["p50_ms"] < best[0]:
            best = (v["p50_ms"], got)
        time.sleep(3)
    if best is None:
        raise SystemExit("side B: no variant loaded")
    cold_b, res_b, rise_b, info_b, download_mb = best[1]
    seen = max(rise_b, key=rise_b.get)
    index = seen  # A follows the GPU B landed on (it can't be told), so both use one card
    time.sleep(3)
    cold_a, res_a, peak_a, gpu_a = run_a(index)
    after = utilisation(index)
    race = {
        "commit": commit, "gpu_index": index, "gpu_asked": args.gpu, "b_gpu_seen": seen, "gpu": gpu_a,
        "gpu_pinning": "A: CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<index>; B: Chromium's Dawn/Vulkan adapter "
                       "(not selectable by flag on two identical cards): the GPU whose memory rose during B's run",
        "quiet": {"before_util_mean_max": before, "after_util_mean_max": after,
                  "note": "nvidia-smi utilization.gpu (%) over 3 s, on the race's GPU, before B and after A"},
        "clips": len(refs), "audio_s": round(sum(chk.seconds(w) for _, w, _ in chk.clips()), 1),
        "a": summarise(MODEL_A, cold_a, res_a, peak_a, refs, chk.wer) | {
            "how": "omxcode: mojoui.speech in process (torch fp16, sdpa, greedy), samples by address"},
        "b": summarise(MODEL_B, cold_b, res_b, rise_b[index], refs, chk.wer) | {
            "how": "transformers.js 4.3.2 on WebGPU (onnxruntime-web), greedy; the best variant of b_variants",
            "variants": variants,
            "download_mb": round(download_mb, 1), "adapter": (info_b or {}).get("adapter"), "dtype": (info_b or {}).get("dtype"),
            "gpu_rise_mb_by_index": {str(k): round(v) for k, v in rise_b.items()}},
        "same_way": "latency = audio handed in -> final text, after warm-up (two 1 s silences at load, then the first clip); "
                    "cold start = process start -> model ready; peak GPU = nvidia-smi memory.used rise on the GPU",
    }
    (DATA / "race.json").write_text(json.dumps(race, indent=1) + "\n")
    a, b = race["a"], race["b"]
    print(f"A {a['p50_ms']} ms p50 / {a['p95_ms']} p95, WER {a['wer']}, cold {a['cold_start_s']} s, GPU {a['peak_gpu_mb']} MB")
    print(f"B {b['p50_ms']} ms p50 / {b['p95_ms']} p95, WER {b['wer']}, cold {b['cold_start_s']} s, GPU {b['peak_gpu_mb']} MB, "
          f"download {b['download_mb']} MB")
    print(f"GPU {index} ({gpu_a}); quiet before {before}, after {after}")


if __name__ == "__main__":
    main()
