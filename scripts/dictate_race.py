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
#
# Review round 1 (D-1416): the one-file fp32 encoder fails because Chromium can't allocate one 2.55 GB ArrayBuffer
# ("fp32-1file", kept to show it); "fp32" is the same tensors split into two external-data files under 1.9 GB
# (scripts/dictate_rechunk.py, byte-for-byte), which transformers.js loads as use_external_data_format = 2.
B_VARIANTS = [("fp16", "fp16"), ("fp32-1file", "fp32"), ("fp32", "fp32"), ("fp32", "q4"), ("q4", "fp32"), ("q4", "q4")]
B_DIR = Path.home() / ".cache" / "mojoui" / "models" / MODEL_B
B_CHUNKED = Path.home() / ".cache" / "mojoui" / "models" / "whisper-large-v3-turbo-encoder-chunked"
CHUNKS = 2
ATTEMPTS = 6  # runs per side/variant until one has no other process on the GPU (each waits for 20 s of quiet first)
B_WHY = {
    ("fp16", "fp16"): "the adapter has no shader-f16 under any of 18 Chromium flag sets (docs/goals/43/webgpu-f16-probe.json)",
    ("fp32-1file", "fp32"): "Chromium can't allocate one 2,547,875,840-byte ArrayBuffer for the single external-data file "
                            "(page fetchtest: 'RangeError: Array buffer allocation failed'; files up to 1.27 GB read whole); "
                            "transformers.js reports it as 'Failed to fetch'. Same tensors split under 2 GB = variant fp32 (D-1416)",
}
CHROME = os.environ.get("CHROME", "/usr/lib/chromium/chromium")
SPEECH_ENV = ROOT / ".pixi" / "envs" / "speech"
BUILD_LOGS = ROOT / "build" / "race"


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


def gpu_uuids():
    out = subprocess.run(["nvidia-smi", "--query-gpu=index,uuid", "--format=csv,noheader"], capture_output=True, text=True).stdout
    return {u.strip(): int(i) for i, u in (line.split(",") for line in out.strip().splitlines())}


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
    """A side thread that samples, about every 100 ms while a side runs: every GPU's memory.used and utilization.gpu,
    and the compute apps on each GPU (pid, name, memory). rise(): peak memory minus the level at start, per GPU.
    others(index, ours): the processes on that GPU that aren't the side's own (ours: a set of pids, or a callable), with
    the most memory each held; quiet(index, ours) says whether another process used that GPU materially (≥ 100 MiB held
    or grown by ≥ 100 MiB during the run)."""

    def __init__(self):
        self.uuid = gpu_uuids()
        self.base = gpu_mem()
        self.peak = dict(self.base)
        self.util = {i: [] for i in self.base}
        self.apps = {}  # (index, pid) -> [name, first MiB, max MiB]
        self.samples = 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while not self.stop.is_set():
            out = subprocess.run(["nvidia-smi", "--query-gpu=index,memory.used,utilization.gpu", "--format=csv,noheader,nounits"],
                                 capture_output=True, text=True).stdout
            for line in out.strip().splitlines():
                i, m, u = (x.strip() for x in line.split(","))
                self.peak[int(i)] = max(self.peak[int(i)], float(m))
                self.util[int(i)].append(float(u))
            out = subprocess.run(["nvidia-smi", "--query-compute-apps=gpu_uuid,pid,process_name,used_memory",
                                  "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout
            for line in out.strip().splitlines():
                f = [x.strip() for x in line.split(",")]
                if len(f) < 4 or not f[1].isdigit():
                    continue
                key = (self.uuid.get(f[0], -1), int(f[1]))
                mb = float(f[-1]) if f[-1].replace(".", "").isdigit() else 0.0
                if key not in self.apps:
                    self.apps[key] = [Path(",".join(f[2:-1]).split(" ")[0]).name, mb, mb, pgrp(key[1])]
                rec = self.apps[key]
                rec[2] = max(rec[2], mb)
            self.samples += 1
            self.stop.wait(0.1)

    def rise(self):
        self.stop.set()
        self.thread.join(5)
        return {i: self.peak[i] - self.base[i] for i in self.base}

    def others(self, index, group):
        """The compute apps seen on GPU `index` outside process group `group` (the side's own: started in a session of
        its own, so its group is its pid)."""
        return [{"pid": pid, "name": r[0], "first_mb": r[1], "max_mb": r[2]}
                for (i, pid), r in sorted(self.apps.items()) if i == index and r[3] != group]

    def report(self, index, group, seconds):
        u = self.util.get(index) or [0.0]
        others = self.others(index, group)
        material = [o for o in others if o["max_mb"] >= 100 or o["max_mb"] - o["first_mb"] >= 100]
        return {"samples": self.samples, "interval_s": round(seconds / max(self.samples, 1), 3),
                "util_mean": round(statistics.mean(u), 1), "util_max": max(u), "other_processes": others,
                "other_material": material, "quiet": not material}


def wait_quiet(index, hold=20.0, limit=1800.0):
    """Waits (up to `limit` s) until no compute app on GPU `index` other than this machine's always-there desktop ones
    holds >= 100 MiB, for `hold` seconds in a row; returns the seconds waited (another session's tests share the GPU)."""
    uuid = {v: k for k, v in gpu_uuids().items()}[index]
    t0 = time.time()
    calm = None
    while time.time() - t0 < limit:
        out = subprocess.run(["nvidia-smi", "--query-compute-apps=gpu_uuid,used_memory", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True).stdout
        busy = any(u.strip() == uuid and float(m) >= 100 for u, m in (ln.rsplit(",", 1) for ln in out.strip().splitlines() if "," in ln))
        if busy:
            calm = None
        elif calm is None:
            calm = time.time()
        elif time.time() - calm >= hold:
            break
        time.sleep(1)
    return round(time.time() - t0, 1)


def pgrp(pid):
    """A process's group id (/proc/<pid>/stat), or -1 once it's gone."""
    try:
        return int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[2])
    except (OSError, IndexError, ValueError):
        return -1


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
    p = subprocess.Popen([str(A_BIN)], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         start_new_session=True)  # (its own process group, so the GPU monitor can tell it from others)
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
    return cold, results, rise[index], gpu, peak.report(index, p.pid, time.perf_counter() - t0)


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
    rechunk()


def rechunk():
    if not (B_CHUNKED / "encoder_model.onnx_data_1").exists():
        subprocess.run(["pixi", "exec", "--spec", "onnx", "--spec", "python=3.12", "python", str(ROOT / "scripts" / "dictate_rechunk.py"),
                        str(B_DIR / "onnx"), str(B_CHUNKED)], cwd=ROOT, check=True)


def run_b(enc, dec, timeout=1800, extra=""):
    headless.ensure()
    ids = sorted(w.stem for w in CLIPS.glob("*.wav"))
    lock = threading.Lock()
    state = {"ready": None, "results": {}, "done": threading.Event(), "error": None, "served": 0, "info": None, "log": []}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _headers(self, code, ctype, length, extra=()):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")  # (cross-origin isolated: threaded wasm)
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()

        def _send(self, body, ctype):
            self._headers(200, ctype, len(body))
            self.wfile.write(body)

        def _file(self, f, ctype):
            """Streams a file from disk in 4 MiB pieces (never whole in memory), with HTTP Range (206) support."""
            size = f.stat().st_size
            start, end = 0, size - 1
            rng = self.headers.get("Range", "")
            if rng.startswith("bytes="):
                a, _, b = rng[6:].split(",")[0].partition("-")
                start, end = (int(a), int(b) if b else size - 1) if a else (size - int(b), size - 1)
                end = min(end, size - 1)
                if start > end:
                    self._headers(416, ctype, 0, [("Content-Range", f"bytes */{size}")])
                    return
                self._headers(206, ctype, end - start + 1, [("Accept-Ranges", "bytes"), ("Content-Range", f"bytes {start}-{end}/{size}")])
            else:
                self._headers(200, ctype, size, [("Accept-Ranges", "bytes")])
            sent = 0
            try:
                with open(f, "rb") as fh:
                    fh.seek(start)
                    left = end - start + 1
                    while left > 0:
                        piece = fh.read(min(left, 4 << 20))
                        if not piece:
                            break
                        self.wfile.write(piece)
                        sent += len(piece)
                        left -= len(piece)
            except (BrokenPipeError, ConnectionResetError) as e:
                state["log"].append(f"server: {self.path} {type(e).__name__} after {sent} of {end - start + 1} bytes")
            state["log"].append(f"server: {self.path} {'206' if rng else '200'} sent {sent} bytes")
            return sent

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in ("/", "/index.html"):
                return self._send((WEB / "index.html").read_bytes(), "text/html")
            if path == "/clips/list":
                return self._send(json.dumps(ids).encode(), "application/json")
            if path.startswith("/clips/"):
                return self._file(CLIPS / Path(path).name, "audio/wav")
            if path.startswith("/dist/"):
                f = WEB / "dist" / Path(path).name
                ctype = {".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm"}.get(f.suffix, "application/octet-stream")
                if f.exists():
                    return self._file(f, ctype)
            if path.startswith("/models/" + MODEL_B + "/"):
                rel = path[len("/models/" + MODEL_B + "/"):]
                base = B_CHUNKED if enc == "fp32" and rel.startswith("onnx/encoder_model.onnx") else B_DIR
                f = base / (rel[len("onnx/"):] if base is B_CHUNKED else rel)
                if f.is_file() and base in f.resolve().parents:
                    sent = self._file(f, "application/json" if f.suffix == ".json" else "application/octet-stream") or 0
                    with lock:  # (after the stream: reading the counter before a long send lost concurrent downloads)
                        state["served"] += sent
                    return
            state["log"].append(f"server: {self.path} 404")
            self.send_error(404)

        def do_POST(self):
            msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            now = time.perf_counter()
            if "fetch" in msg or "log" in msg:
                state["log"].append("page: " + json.dumps(msg))
            elif "ready" in msg:
                state["ready"] = now
                state["info"] = msg
            elif "clip" in msg:
                state["results"][msg["clip"]] = (msg["ms"], msg["seconds"], msg["text"])
            elif "error" in msg:
                state["error"] = msg["error"]
                state["log"].append("page error: " + msg["error"])
                state["done"].set()
            elif "done" in msg:
                state["done"].set()
            self._send(b"{}", "application/json")

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/index.html?model={MODEL_B}&enc={enc.split('-')[0]}&dec={dec}{'&chunks=%d' % CHUNKS if enc == 'fp32' else ''}{extra}"
    prof = tempfile.mkdtemp(prefix="dictate-web-prof-")
    log = open(Path(prof) / "chromium.log", "w")
    peak = Peak()
    t0 = time.perf_counter()
    proc = subprocess.Popen([CHROME, f"--user-data-dir={prof}", *_flags(), "--enable-logging=stderr", "--v=0", f"--app={url}"],
                            stdout=log, stderr=log, start_new_session=True)
    timed_out = False
    try:
        timed_out = not state["done"].wait(timeout)
    finally:
        rise = peak.rise()
        seconds = time.perf_counter() - t0
        os.killpg(proc.pid, 15)
        proc.wait()
        srv.shutdown()
        log.close()
        chromium = [ln for ln in (Path(prof) / "chromium.log").read_text(errors="replace").splitlines()
                    if any(w in ln for w in ("ERROR", "FATAL", "CONSOLE", "Out of memory", "oom", "net::"))]
        shutil.rmtree(prof, ignore_errors=True)
    index = max(rise, key=rise.get)
    gpu_report = peak.report(index, proc.pid, seconds)
    evidence = BUILD_LOGS / f"b-{enc}-{dec}.log"
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text("\n".join(state["log"] + ["--- chromium (ERROR/FATAL/CONSOLE lines) ---"] + chromium[-200:]) + "\n")
    if timed_out or state["error"]:
        failed = [ln for ln in state["log"] if '"error"' in ln or "Error" in ln or "after" in ln]
        return None, (state["error"] or f"timed out after {timeout} s"), {"page_and_server": failed[-8:],
                                                                           "chromium": chromium[-8:], "log": str(evidence.relative_to(ROOT))}
    return state["ready"] - t0, state["results"], rise, state["info"], state["served"] / 1e6, gpu_report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gpu", type=int, default=0, help="the GPU both sides should use (nvidia-smi's index)")
    ap.add_argument("--extra", default="", help="(with --probe) more query parameters for the page, e.g. &fetchtest=...")
    ap.add_argument("--probe", metavar="ENC/DEC", help="run one B variant only and print its fetch/server/Chromium log")
    args = ap.parse_args()
    if args.probe:
        build_b()
        enc, dec = args.probe.split("/")
        got = run_b(enc, dec, extra=args.extra)
        print("loaded" if got[0] is not None else "failed: " + json.dumps(got[1:], indent=1))
        print((BUILD_LOGS / f"b-{enc}-{dec}.log").read_text()[-6000:])
        return
    chk = _checker()
    refs = {i: t for i, _, t in chk.clips()}
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    before = utilisation(args.gpu)
    build_b()
    variants, runs = [], {}
    for enc, dec in B_VARIANTS:
        for attempt in range(ATTEMPTS):  # re-run when another process used the race's GPU materially during it
            waited = wait_quiet(args.gpu)
            got = run_b(enc, dec)
            if got[0] is None or got[5]["quiet"]:
                break
            print(f"B {enc}/{dec}: another process used the GPU ({got[5]['other_material']}); again")
        if got[0] is None:
            variants.append({"encoder": enc, "decoder": dec, "loaded": False, "error": got[1].split(" | adapter")[0][:400],
                             "evidence": got[2], **({"root_cause": B_WHY[(enc, dec)]} if (enc, dec) in B_WHY else {})})
            print(f"B {enc}/{dec}: didn't load: {variants[-1]['error'][:200]}")
            continue
        cold, res, rise, info, mb, gq = got
        v = summarise(MODEL_B, cold, res, rise[max(rise, key=rise.get)], refs, chk.wer)
        variants.append({"encoder": enc, "decoder": dec, "loaded": True, "p50_ms": v["p50_ms"], "p95_ms": v["p95_ms"],
                         "wer": v["wer"], "cold_start_s": v["cold_start_s"], "download_mb": round(mb, 1), "gpu_during": gq,
                         "attempts": attempt + 1, "waited_for_quiet_s": waited})
        runs[(enc, dec)] = got
        print(f"B {enc}/{dec}: p50 {v['p50_ms']} ms, p95 {v['p95_ms']}, WER {v['wer']}; GPU quiet {gq['quiet']}")
        time.sleep(3)
    if not runs:
        raise SystemExit("side B: no variant loaded")
    rise_any = next(iter(runs.values()))[2]
    seen = max(rise_any, key=rise_any.get)
    index = seen  # A follows the GPU B landed on (it can't be told), so both use one card
    time.sleep(3)
    for attempt in range(ATTEMPTS):
        wait_quiet(index)
        cold_a, res_a, peak_a, gpu_a, gq_a = run_a(index)
        if gq_a["quiet"]:
            break
        print(f"A: another process used the GPU ({gq_a['other_material']}); again")
    after = utilisation(index)
    a = summarise(MODEL_A, cold_a, res_a, peak_a, refs, chk.wer)
    # B is its fastest variant whose WER is within 0.01 of A's (a fast variant that transcribes worse isn't a fair
    # stand-in); if none is, its most accurate one.
    ok = [v for v in variants if v["loaded"] and v["wer"] <= a["wer"] + 0.01]
    pick = min(ok, key=lambda v: v["p50_ms"]) if ok else min((v for v in variants if v["loaded"]), key=lambda v: v["wer"])
    cold_b, res_b, rise_b, info_b, download_mb, gq_b = runs[(pick["encoder"], pick["decoder"])]
    b_precision = f"encoder {pick['encoder']}, decoder {pick['decoder']}"
    quiet_all = gq_a["quiet"] and all(v["gpu_during"]["quiet"] for v in variants if v["loaded"])
    race = {
        "commit": commit, "gpu_index": index, "gpu_asked": args.gpu, "b_gpu_seen": seen, "gpu": gpu_a,
        "gpu_pinning": "A: CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<index>; B: Chromium's Dawn/Vulkan adapter "
                       "(not selectable by flag on two identical cards): the GPU whose memory rose during B's run",
        "quiet": {"before_util_mean_max": before, "after_util_mean_max": after, "during_a": gq_a, "during_b": gq_b,
                  "all_runs_quiet": quiet_all,
                  "note": "before/after: nvidia-smi utilization.gpu (%) over 3 s on the race's GPU. during_*: a side thread "
                          "sampled utilization, memory and --query-compute-apps about every 100 ms while the side ran; "
                          "other_material = another process on that GPU holding or growing by >= 100 MiB (a run with one "
                          "is repeated, up to 3 times). Utilisation during a run is the GPU's, ours included."},
        "clips": len(refs), "audio_s": round(sum(chk.seconds(w) for _, w, _ in chk.clips()), 1),
        "a": a | {
            "precision": "fp16", "log_mel": "GPU (WhisperFeatureExtractor with device='cuda', torch)",
            "decoding": "greedy (num_beams=1, do_sample=False), language=en, task=transcribe, one 30 s window",
            "how": "omxcode: mojoui.speech in process (torch fp16, sdpa, greedy), samples by address"},
        "b": summarise(MODEL_B, cold_b, res_b, rise_b[index], refs, chk.wer) | {
            "precision": b_precision, "log_mel": "CPU, in JavaScript (transformers.js's WhisperFeatureExtractor)",
            "decoding": "greedy (the pipeline's default: num_beams 1, no sampling), language=en, task=transcribe, one 30 s window",
            "how": "transformers.js 4.3.2 on WebGPU (onnxruntime-web), greedy; b = the fastest of b.variants whose WER is "
                   "within 0.01 of A's",
            "pick_rule": "fastest p50 among loaded variants with WER <= A's WER + 0.01 (else the most accurate)",
            "variants": variants,
            "download_mb": round(download_mb, 1), "adapter": (info_b or {}).get("adapter"), "dtype": (info_b or {}).get("dtype"),
            "gpu_rise_mb_by_index": {str(k): round(v) for k, v in rise_b.items()}},
        "same_way": "latency = audio handed in -> final text, after warm-up (two 1 s silences at load, then the first clip); "
                    "cold start = process start -> model ready; peak GPU = nvidia-smi memory.used rise on the GPU",
        "same_weights": "both sides are openai/whisper-large-v3-turbo's weights (B: onnx-community's ONNX export of them)",
    }
    if race["a"]["precision"] != race["b"]["precision"]:
        race["precision_note"] = (
            f"A runs fp16; B runs {b_precision}. shader-f16 isn't offered by Chromium's WebGPU on this machine under any of "
            "18 flag sets (docs/goals/43/webgpu-f16-probe.json), so B can't run fp16; B ran every precision that loads "
            "(fp32 only after its external data was split into files under 2 GB: one 2.55 GB ArrayBuffer can't be "
            "allocated) and the fastest within 0.01 WER of A was raced.")
    (DATA / "race.json").write_text(json.dumps(race, indent=1) + "\n")
    a, b = race["a"], race["b"]
    print(f"A fp16: {a['p50_ms']} ms p50 / {a['p95_ms']} p95, WER {a['wer']}, cold {a['cold_start_s']} s, GPU {a['peak_gpu_mb']} MB")
    print(f"B {b_precision}: {b['p50_ms']} ms p50 / {b['p95_ms']} p95, WER {b['wer']}, cold {b['cold_start_s']} s, "
          f"GPU {b['peak_gpu_mb']} MB, download {b['download_mb']} MB")
    print(f"ratio {b['p50_ms'] / a['p50_ms']:.2f}x at the median; GPU {index} ({gpu_a}); quiet before {before}, after {after}, "
          f"all runs quiet: {quiet_all}")

if __name__ == "__main__":
    main()
