"""Re-record the original console's /admin/* replies (goal 33 M0) from a real mxconsole daemon on mxconsole's fakes.

    pixi run python scripts/console_record.py        # rewrites docs/goals/33/fixtures/ (about two minutes)

How: a real mxconsole daemon (mxconsole.gateway.create_app + Supervisor, the code `mxc daemon` runs) is started with
mxstudio's own Python (~/Projects/mxstudio/.pixi/envs/default, MXSTUDIO_PYTHON to override) in a scratch folder:
MXC_HOME, HOME, HF_HOME, TMPDIR and XDG_* all point into $TMPDIR/mxc-console-record (emptied first; a fixed name so
the paths in the replies stay the same between recordings), so ~/.mxc/mst.db and the real home are
never touched, and PYTHONDONTWRITEBYTECODE keeps even __pycache__ out of mxstudio. Nothing is written inside
~/Projects/mxstudio. Its fakes stand in for the outside world: tests/mxconsole/fake_max.py is `max serve` (no GPU),
fake_hub.py is Hugging Face for pulls (MXC_FAKE_HUB), and the test-double hooks of create_app (api_deps) take a fake
GPU (24 GB), a fake MAX catalog for search, and a fake model card and config for the notebook.

The state, made through the daemon's own API where it has one: three models (qwen2.5-0.5b loaded and serving,
llama3.2-1b and all-minilm-l6 stopped; registered in the store as a pull would, with sparse weights files and a
max-serve log), two labels, three API keys (one revoked), chat traffic from two apps plus refused keys, a finished
benchmark, the notebook built, and a pull of acme/helper-7b left in progress. Then the original console is driven
through scripts/console_side.py's ten screens at both sizes against scripts/console_fixture.py in record mode (a proxy
that keeps the last reply per request) while traffic keeps flowing, and the replies are saved as fixtures.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MXSTUDIO = Path(os.environ.get("MXSTUDIO_DIR", Path.home() / "Projects/mxstudio"))
PY = Path(os.environ.get("MXSTUDIO_PYTHON", MXSTUDIO / ".pixi/envs/default/bin/python"))
FAKES = MXSTUDIO / "tests" / "mxconsole"
ADMIN = {"X-Mst-Admin": "1"}
DEFAULT_PORT = 11435  # the daemon's own port: the replies' endpoints read as a real install's
GPU = [{"index": 0, "name": "NVIDIA GeForce RTX 4090", "used_mb": 9310, "total_mb": 24564, "util": 37}]
# models registered as a pull leaves them: (name, repo, architecture, weights bytes, labels)
MODELS = [("qwen2.5-0.5b", "Qwen/Qwen2.5-0.5B-Instruct", "Qwen2ForCausalLM", 988_097_824, ["work", "favorites"]),
          ("llama3.2-1b", "meta-llama/Llama-3.2-1B-Instruct", "LlamaForCausalLM", 2_471_645_608, ["work"]),
          ("all-minilm-l6", "sentence-transformers/all-MiniLM-L6-v2", "BertModel", 90_868_376, [])]
LOG = """\
12:02:11.204 INFO: Starting server using Qwen/Qwen2.5-0.5B-Instruct
12:02:11.209 INFO: Metrics initialized.
12:02:12.880 INFO: Building and compiling model...
12:02:19.415 INFO: Building graph took 6.534 seconds
12:02:41.022 INFO: Compiling model took 21.607 seconds
12:02:41.640 INFO: Paged KVCache Manager allocated 26 device blocks and 0 host blocks of 128 tokens each
12:02:42.113 INFO: Server ready on http://127.0.0.1:{port} (Press CTRL+C to quit)
12:03:05.551 INFO: 127.0.0.1 - "POST /v1/chat/completions HTTP/1.1" 200 OK
12:03:07.902 INFO: 127.0.0.1 - "POST /v1/chat/completions HTTP/1.1" 200 OK
12:03:12.318 INFO: 127.0.0.1 - "POST /v1/chat/completions HTTP/1.1" 200 OK
"""
CARD = """# Qwen2.5-0.5B-Instruct

Qwen2.5 is the latest series of Qwen large language models. This repo contains the instruction-tuned 0.5B model.

## Quickstart

Use it through any OpenAI-compatible client: send chat messages, get a reply.

## Evaluation

Detailed results are in the Qwen2.5 blog.
"""
CONFIG = {"model_type": "qwen2", "architectures": ["Qwen2ForCausalLM"], "hidden_size": 896,
          "num_hidden_layers": 24, "num_attention_heads": 14, "num_key_value_heads": 2,
          "intermediate_size": 4864, "vocab_size": 151936, "max_position_embeddings": 32768,
          "rope_theta": 1000000.0, "tie_word_embeddings": True}
CATALOG = {"Qwen2ForCausalLM": {"example_repo_ids": ["Qwen/Qwen2.5-0.5B-Instruct", "Qwen/Qwen2.5-1.5B-Instruct",
                                                     "Qwen/Qwen2.5-3B-Instruct", "Qwen/Qwen2.5-7B-Instruct",
                                                     "Qwen/Qwen2.5-32B-Instruct"], "supported_encodings": ["bfloat16"]},
           "LlamaForCausalLM": {"example_repo_ids": ["meta-llama/Llama-3.2-1B-Instruct", "HuggingFaceTB/SmolLM2-1.7B-Instruct",
                                                     "meta-llama/Llama-3.1-70B-Instruct"], "supported_encodings": ["bfloat16"]},
           "BertModel": {"example_repo_ids": ["sentence-transformers/all-MiniLM-L6-v2"], "supported_encodings": ["float32"]}}


# -- the daemon (runs under mxstudio's Python) -------------------------------------------------------------------
def daemon_main(port):
    sys.path.insert(0, str(FAKES))
    import uvicorn

    from mxconsole import metrics
    from mxconsole.gateway import create_app
    from mxconsole.learn import HFInfo
    from mxconsole.search import Sources
    from mxconsole.store import Store, mxc_home
    from mxconsole.supervisor import Supervisor
    from fakes import make_hf

    home = mxc_home()
    assert os.environ.get("MXC_HOME") and home != Path(os.environ.get("REAL_HOME", "/nonexistent")) / ".mxc", home
    store = Store.open()
    for name, repo, arch, size, labels in MODELS:
        weights = home / "weights" / name
        weights.mkdir(parents=True, exist_ok=True)
        with open(weights / "model.safetensors", "wb") as f:
            f.truncate(size)  # sparse: the size the console shows, no disk used
        (weights / "config.json").write_text("{}")
        store.add_model(name=name, repo_id=repo, revision="7ae557604adf67be50417f59c2c2f167def9a775",
                        source="huggingface", architecture=arch, weights_path=str(weights))
    (home / "logs").mkdir(parents=True, exist_ok=True)
    (home / "logs" / "qwen2.5-0.5b.log").write_text(LOG.replace("{port}", "41873"))

    metrics.gpus = lambda: GPU  # /admin/metrics reads nvidia-smi through this at call time

    class Card:
        def info(self, repo_id, revision):
            return HFInfo(repo_id=repo_id, revision="7ae5576", pipeline_tag="text-generation", license="apache-2.0",
                          downloads=1_834_521, likes=402, safetensors_total=494_032_768)

        def card_text(self, repo_id, revision):
            return CARD

        def config(self, repo_id, revision):
            return CONFIG

    sup = Supervisor(store, max_command=(sys.executable, str(FAKES / "fake_max.py")), gpus=lambda: GPU)

    def vram():  # the model's process holds GPU memory, as nvidia-smi would say
        return {s["pid"]: 3120 for s in sup.status() if s.get("pid")}

    deps = {"system": {"gpus": lambda: GPU, "gpu_procs": vram, "ppid": lambda pid: None},
            "search_sources": Sources(catalog=lambda: CATALOG, hub=make_hf, gpus=lambda: GPU, ram=lambda: (41.2, 62.7)),
            "learn_source": Card(),
            "jupyter_launcher": lambda path: f"http://127.0.0.1:8899/lab/tree/{path.name}?token=t"}
    uvicorn.run(create_app(store, sup, api_deps=deps), host="127.0.0.1", port=port, log_level="warning")


# -- the recorder (runs under this repo's pixi Python) -----------------------------------------------------------
def free_port():
    """The daemon's own port when it's free (the replies then read as a real install's), else any free port.
    The daemon must know its real port (MXC_PORT): the benchmark calls the gateway through it."""
    for want in (DEFAULT_PORT, 0):
        with socket.socket() as s:
            try:
                s.bind(("127.0.0.1", want))
            except OSError:
                continue
            return s.getsockname()[1]


def call(base, method, path, body=None, headers=ADMIN, ok=(200, 201, 202)):
    req = urllib.request.Request(base + path, method=method, headers={**headers, "Content-Type": "application/json"},
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, data = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, data = e.code, e.read()
    if ok and status not in ok:
        raise RuntimeError(f"{method} {path}: {status} {data[:300]!r}")
    return json.loads(data) if data[:1] in (b"{", b"[") else data


def chat(base, key, model="qwen2.5-0.5b", n=1):
    for _ in range(n):
        call(base, "POST", "/v1/chat/completions", {"model": model, "stream": True, "max_tokens": 48,
                                                     "stream_options": {"include_usage": True},
                                                     "messages": [{"role": "user", "content": "Summarise this note in one line."}]},
             headers={"Authorization": f"Bearer {key}"}, ok=None)


def seed(base):
    for label in ("work", "favorites"):
        call(base, "POST", "/admin/labels", {"name": label})
    for name, *_, labels in MODELS:
        for label in labels:
            call(base, "POST", f"/admin/labels/{label}/add", {"models": [name]})
    keys = {app: call(base, "POST", "/admin/keys", {"app": app})["key"] for app in ("notes-app", "zed-editor", "old-script")}
    call(base, "POST", "/admin/models/qwen2.5-0.5b/load")
    chat(base, keys["old-script"], n=2)
    call(base, "DELETE", "/admin/keys/old-script")
    chat(base, keys["old-script"])  # refused: counts in "blocked today"
    chat(base, "mst-not-a-real-key")
    chat(base, keys["notes-app"], n=6)
    chat(base, keys["zed-editor"], n=4)
    call(base, "POST", "/admin/bench", {"models": ["qwen2.5-0.5b"], "runs": 3})
    for _ in range(600):
        if not call(base, "GET", "/admin/bench")["running"]:
            break
        time.sleep(0.2)
    call(base, "GET", "/admin/learn/qwen2.5-0.5b")
    call(base, "POST", "/admin/pulls", {"ref": "acme/helper-7b"})
    return keys


def main():
    sys.path.insert(0, str(ROOT / "scripts"))
    import console_fixture
    import console_side

    tmp = Path(tempfile.gettempdir()) / "mxc-console-record"  # a fixed name: the paths in the replies stay the same
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()
    port = free_port()
    env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "REAL_HOME": str(Path.home()), "MXSTUDIO_DIR": str(MXSTUDIO),
           "HOME": str(tmp / "home"), "MXC_HOME": str(tmp / "mxc"), "HF_HOME": str(tmp / "hf"),
           "TMPDIR": str(tmp / "tmp"), "XDG_DATA_HOME": str(tmp / "xdg-data"), "XDG_CONFIG_HOME": str(tmp / "xdg-config"),
           "XDG_CACHE_HOME": str(tmp / "xdg-cache"), "PYTHONDONTWRITEBYTECODE": "1", "MXC_PORT": str(port),
           "MXC_FAKE_HUB": str(FAKES / "fake_hub.py"), "FAKE_HUB_MB": "24", "FAKE_HUB_CHUNK_DELAY": "4",
           "FAKE_MAX_TOKENS_OUT": "48", "FAKE_MAX_CHUNK_DELAY": "0.006", "FAKE_MAX_TTFT_DELAY": "0.04",
           "FAKE_MAX_USAGE": "1", "FAKE_MAX_DELAY": "1.5"}
    for d in ("home", "mxc", "hf", "tmp", "xdg-data", "xdg-config", "xdg-cache"):
        (tmp / d).mkdir()
    daemon = subprocess.Popen([str(PY), str(Path(__file__).resolve()), "--daemon", str(port)], cwd=tmp, env=env,
                              stdout=open(tmp / "daemon.log", "w"), stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    stop = threading.Event()
    try:
        for _ in range(300):
            try:
                urllib.request.urlopen(base + "/health", timeout=1)
                break
            except OSError:
                if daemon.poll() is not None:
                    raise RuntimeError("the daemon died:\n" + (tmp / "daemon.log").read_text()[-3000:])
                time.sleep(0.1)
        keys = seed(base)

        def traffic():  # the apps keep calling while the screens are recorded, so tokens/s is live
            i = 0
            while not stop.wait(1.3):
                chat(base, keys["notes-app" if i % 3 else "zed-editor"])
                i += 1
        threading.Thread(target=traffic, daemon=True).start()
        fx = console_fixture.Fixtures(upstream=base, host=f"127.0.0.1:{DEFAULT_PORT}")
        server, url = console_fixture.serve(fx)
        try:
            console_side.shoot(url, tmp / "shots")  # drives every screen at both sizes through the recording proxy
        finally:
            server.shutdown()
        stop.set()
        recorded_at = round(time.time(), 3)
        fx.save(recorded_at)
        print(f"recorded {len(fx.replies)} replies into {console_fixture.FIXTURES.relative_to(ROOT)}"
              f" (misses: {sorted(set(fx.misses))})")
    finally:
        stop.set()
        daemon.terminate()
        try:
            daemon.wait(timeout=15)
        except subprocess.TimeoutExpired:
            daemon.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--daemon"]:
        daemon_main(int(sys.argv[2]))
    else:
        main()
