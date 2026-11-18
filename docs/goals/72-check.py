"""Goal 72's proof: omx, the voice app, rebuilt on omxcode (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/72-check.py [M0 M1 ...]          (default: every milestone)

M4 and M5 are the app: examples/omx on GTK (headless Xvfb) and on the web host. The models run on GPU $G72_GPU (default 1:
GPU 0 belongs to the prototype), the recorded "person" is Kokoro's voice played into the app's microphone through
mojoui.audio's `file:` source, the app's speaker goes to a PulseAudio null sink this script loads and unloads, and what the
speaker played is recorded from the sink's monitor and heard back by Parakeet. Numbers: build/g72/omx-bench.json; pictures:
build/g72 and docs/goals/72. The heavy milestones (M1-M3: the models' own tests) run only when asked for by name or by default
(they take minutes on the GPU).
"""
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g72"
SHOTS = ROOT / "docs/goals/72"
WAV = OUT / "wav"
SINK = "g72omx"
GPU = os.environ.get("G72_GPU", "1")
MODELS = Path(os.environ.get("OMX_MODELS") or Path.home() / "Projects/omx-local/models")
sys.path.insert(0, str(ROOT / "scripts"))

SAYS = {  # the recorded person: name -> what Kokoro says
    "q1": "What is the capital of France?",
    "q2": "Compare the three largest planets by diameter.",
    "q3": "Tell me a long story about a dragon who learns to bake bread. Make it at least twelve sentences.",
    "i1": "Stop. What is two plus two?",
}
LIMITS = {"first_audio_ms": 1500, "barge_ms": 500, "web_answer_s": 2.0}
BENCH = OUT / "omx-bench.json"


def sh(cmd, timeout=1800, env=None, cwd=ROOT, **kw):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=cwd, env=e, capture_output=True, text=True, timeout=timeout, **kw)


def tail(r, n=600):
    return (r.stdout + r.stderr)[-n:]


def bench(**kv):
    data = json.loads(BENCH.read_text()) if BENCH.exists() else {}
    data.update(kv)
    OUT.mkdir(parents=True, exist_ok=True)
    BENCH.write_text(json.dumps(data, indent=1))


# ------------------------------------------------------------------------------------------------ the null sink, the recording


class NullSink:
    """A PulseAudio null sink for the app's speaker (silent on the desktop) and a recorder on its monitor."""

    def __init__(self):
        self.module = None
        self.rec = None

    def __enter__(self):
        sh("pactl list short modules | grep sink_name=%s | cut -f1 | xargs -r -n1 pactl unload-module" % SINK, shell=True)
        self.module = sh(["pactl", "load-module", "module-null-sink", f"sink_name={SINK}", f"sink_properties=device.description={SINK}"]).stdout.strip()
        return self

    def record(self, path):
        self.path = Path(path)
        self.rec = subprocess.Popen(["parec", f"--device={SINK}.monitor", "--rate=16000", "--channels=1", "--format=s16le",
                                     "--file-format=raw"], stdout=open(str(self.path) + ".raw", "wb"), stderr=subprocess.DEVNULL)

    def stop_recording(self):
        if self.rec:
            self.rec.send_signal(signal.SIGINT)
            self.rec.wait(10)
            self.rec = None
            raw = Path(str(self.path) + ".raw").read_bytes()
            with wave.open(str(self.path), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16000)
                w.writeframes(raw)
            Path(str(self.path) + ".raw").unlink()

    def __exit__(self, *a):
        self.stop_recording()
        if self.module:
            sh(["pactl", "unload-module", self.module])


def ensure_wavs():
    todo = [f"{k}={v}" for k, v in SAYS.items() if not (WAV / f"{k}.wav").exists()]
    if todo:
        r = sh(["pixi", "run", "-e", "voice", "python", "scripts/omx_say.py", str(WAV), *todo], 900, {"CUDA_VISIBLE_DEVICES": GPU})
        if r.returncode:
            raise RuntimeError("omx_say.py: " + tail(r))


def hear(wav):
    """Parakeet's text for a recording."""
    r = sh(["pixi", "run", "-e", "voice", "python", "scripts/omx_hear.py", str(wav)], 600,
           {"CUDA_VISIBLE_DEVICES": GPU, "MOJOUI_PARAKEET_DIR": str(MODELS / "parakeet-tdt-0.6b-v3")})
    said = [l[7:] for l in r.stdout.splitlines() if l.startswith("HEARD: ")]
    return said[-1] if said else "(" + tail(r, 300) + ")"


# ------------------------------------------------------------------------------------------------ running the app


def build():
    r = sh(["scripts/build.sh", "omx", "linux"], 3600)
    return None if r.returncode == 0 else "build failed: " + tail(r, 1500)


def parse_omx(stdout):
    """The OMX lines of an app run as dicts {kind, ...}."""
    events = []
    for line in stdout.splitlines():
        m = re.match(r"OMX (\w+): (.*)$", line)
        if not m:
            continue
        kv, rest = {}, m.group(2)
        text_at = rest.find(" text=")
        if text_at >= 0:
            kv["text"], rest = rest[text_at + 6:], rest[:text_at]
        elif rest.startswith("text="):
            kv["text"], rest = rest[5:], ""
        for k, v in re.findall(r"(\w+)=(\S+)", rest):
            kv[k] = int(v) if v.lstrip("-").isdigit() else v
        events.append({"kind": m.group(1), **kv})
    return events


def run_app(source, steps, window=None, record=None, timeout=300, env_extra=None):
    """examples/omx on GTK on the headless display, the recorded voice as its microphone; the OMX lines it printed, in order,
    as dicts {kind, ...} (turn=, ms=, text=, ...)."""
    import headless

    headless.ensure()
    env = {"CUDA_VISIBLE_DEVICES": GPU, "OMX_LLM_GPU": "0", "OMX_MODELS": str(MODELS), "MOJOUI_AUDIO_SINK": SINK,
           "MOJOUI_AUDIO_SOURCE": source.replace("W/", str(WAV) + "/"), "MOJOUI_TEST": steps,
           "OMX_SD": "0"}  # (the painter off: M4's layout has the brain and the voice on one card; M6's creator layout turns it on)
    if window:
        env["MOJOUI_WINDOW"] = window
    env.update(env_extra or {})
    r = sh([str(ROOT / "build/omx/linux/omx")], timeout, env)
    return parse_omx(r.stdout), r


def of(events, kind, turn=None):
    return [e for e in events if e["kind"] == kind and (turn is None or e.get("turn") == turn)]


def pic(name):
    SHOTS.mkdir(parents=True, exist_ok=True)
    src = OUT / name
    if src.exists():
        shutil.copy(src, SHOTS / name)
    return src.exists()


def shots(tag, window, dark):
    """The card screen in one window size and one scheme (and Home before it): four pictures a run."""
    steps = ("waitfor:Listening=180000;" + ("scheme:dark;" if dark else "") + "wait:1500;shot:%s/%s_home.png;wait:24000;shot:%s/%s_work.png;wait:500" % (OUT, tag, OUT, tag))
    ev, r = run_app("file:W/q2.wav@3", steps, window)
    got = [n for n in (f"{tag}_home.png", f"{tag}_work.png") if pic(n)]
    return ev, got, r


# ------------------------------------------------------------------------------------------------ the milestones


def m0():
    need = [MODELS / "Qwen3.8-27B-UD-Q4_K_M.gguf", MODELS / "parakeet-tdt-0.6b-v3", ROOT / "build/llm/libmojoui_llm.so"]
    missing = [str(p) for p in need if not p.exists()]
    smi = sh(["nvidia-smi", "--query-gpu=index,name,memory.total", "--format=csv,noheader"]).stdout.strip().splitlines()
    if missing:
        return "FAIL", "missing: " + ", ".join(missing)
    if len(smi) < 2:
        return "FAIL", f"{len(smi)} GPU(s) seen, need 2"
    return "PASS", f"{len(smi)} GPUs ({smi[1].split(',')[1].strip()} for the models), Qwen3.8-27B + Parakeet + the llama shim found"


def _run_binary(build_cmd, run_cmd, env=None, want=None, timeout=3600):
    b = sh(build_cmd, 3600)
    if b.returncode:
        return "FAIL", "build: " + tail(b, 500)
    r = sh(run_cmd, timeout, env)
    if r.returncode or (want and want not in r.stdout):
        return "FAIL", tail(r, 500)
    return "PASS", [l for l in r.stdout.splitlines() if l.strip()][-1][:160]


def m1():
    return _run_binary(["scripts/mxbuild.sh", "tests/test_llm.mojo", "-o", "build/test_llm"], ["build/test_llm"], {"LLM_GPU": GPU}, "llm ")


def m2():
    return _run_binary(["pixi", "run", "-e", "voice", "mojo", "build", "--disable-warnings", "-I", ".", "tests/test_voice.mojo", "-o", "build/g72/test_voice"],
                       ["pixi", "run", "-e", "voice", "build/g72/test_voice"], {"CUDA_VISIBLE_DEVICES": GPU}, "voice: ok")


def m3():
    state, why = _run_binary(["scripts/mojo_flare.sh", "build", "tests/test_llmagent.mojo", "-o", "build/test_llmagent"], ["build/test_llmagent"], {"LLM_GPU": GPU})
    if state != "PASS":
        return state, why
    r = sh(["pixi", "run", "python", "scripts/agui_llm_check.py"], 1800, {"LLM_GPU": GPU})
    return ("PASS", why + " | official AG-UI client: " + r.stdout.strip().splitlines()[-1][:120]) if r.returncode == 0 else ("FAIL", "agui_llm_check: " + tail(r, 400))


def app_lint():
    spec = importlib.util.spec_from_file_location("g33check", ROOT / "docs/goals/33-check.py")
    g33 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g33)
    return g33.lint_selftest() + g33.app_lint(["examples/omx"])


def m4():
    probs, said = [], []
    why = build()
    if why:
        return "FAIL", why
    lint = app_lint()
    (probs.append("app-lint: " + "; ".join(lint[:3])) if lint else said.append("app-lint clean (no host imports, colours, fonts or pixel sizes in examples/omx)"))
    ensure_wavs()
    with NullSink() as sink:
        # A: a spoken question, a spoken answer; then the card
        sink.record(OUT / "reply-a.wav")
        steps = ("waitfor:Listening=180000;wait:1500;shot:%s/a_home.png;wait:8000;shot:%s/a_turn1.png;wait:27000;shot:%s/a_card.png;wait:500" % (OUT, OUT, OUT))
        ev, r = run_app("file:W/q1.wav@3,W/q2.wav@14", steps)
        sink.stop_recording()
        for n in ("a_home.png", "a_turn1.png", "a_card.png"):
            pic(n)
        heard1, reply1, first1 = of(ev, "HEARD", 1), of(ev, "REPLY", 1), of(ev, "FIRST_AUDIO", 1)
        if of(ev, "FAILED"):
            probs.append("the app failed: " + of(ev, "FAILED")[0].get("text", ""))
        if not heard1 or "capital of france" not in heard1[0].get("text", "").lower():
            probs.append(f"turn 1 heard {heard1[0].get('text') if heard1 else None!r}")
        if not reply1 or "paris" not in reply1[0].get("text", "").lower():
            probs.append(f"turn 1 answered {reply1[0].get('text') if reply1 else None!r}, not Paris")
        if not first1:
            probs.append("no first audio stamp for turn 1")
        else:
            ok = first1[0]["ms"] <= LIMITS["first_audio_ms"]
            (said if ok else probs).append(f"first audio {first1[0]['ms']} ms after the question's last word (limit {LIMITS['first_audio_ms']})")
            bench(first_audio_ms=first1[0]["ms"], heard_ms=heard1[0]["ms"] if heard1 else None,
                  first_words_ms=reply1[0].get("first_words_ms") if reply1 else None)
        said.append(f"heard {heard1[0]['text']!r} in {heard1[0]['ms']} ms after the endpointer's quiet" if heard1 else "heard nothing")
        if reply1:
            said.append("answered " + repr(reply1[0]["text"]))
        spoken = hear(OUT / "reply-a.wav")
        bench(reply_a_as_heard=spoken)
        (said if "paris" in spoken.lower() else probs).append(f"Parakeet on the speaker's own audio: {spoken!r}")
        cards = of(ev, "CARD", 2)
        if not cards or not cards[0].get("shape", "").startswith("Card"):
            probs.append("turn 2 (planets) showed no card on the shelf: " + str(of(ev, "REPLY", 2) or ev[-3:]))
        else:
            said.append(f"card on the shelf {cards[0]['ms']} ms after the question was heard: {cards[0]['shape']}")
            bench(card_ms=cards[0]["ms"], card_shape=cards[0]["shape"])
        # B: an interruption
        sink.record(OUT / "reply-b.wav")
        steps = "waitfor:Listening=180000;wait:30000"
        ev, r = run_app("file:W/q3.wav@2,W/i1.wav@13", steps)
        sink.stop_recording()
        b = of(ev, "BARGE")
        if not b:
            probs.append("no barge-in: the second utterance did not stop the reply (events: %s)" % [e["kind"] for e in ev])
        else:
            ok = b[0]["ms"] <= LIMITS["barge_ms"]
            (said if ok else probs).append(f"an interruption stopped the speaker {b[0]['ms']} ms after the first voiced sample (limit {LIMITS['barge_ms']})")
            bench(barge_ms=b[0]["ms"])
            after = [e for e in of(ev, "HEARD") if re.search(r"two plus two|2 ?\+ ?2|2 plus 2", e.get("text", ""), re.I)]
            reply2 = [e for e in of(ev, "REPLY") if re.search(r"\b(four|4)\b", e.get("text", ""), re.I)]
            (said if after and reply2 else probs).append("and the new question was heard and answered: %r -> %r" % (after[0]["text"] if after else None, reply2[0]["text"] if reply2 else None))
    # screenshots: desktop and phone width, light and dark (the card screen each time)
    with NullSink():
        for tag, window, dark in (("desktop_light", None, False), ("desktop_dark", None, True),
                                  ("phone_light", "390x844", False), ("phone_dark", "390x844", True)):
            ev, got, r = shots(tag, window, dark)
            if len(got) != 2:
                probs.append(f"{tag}: pictures missing ({got})")
            elif not of(ev, "CARD"):
                probs.append(f"{tag}: no card shown in the run")
        said.append("screenshots: desktop and 390x844 phone width, light and dark, in docs/goals/72")
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


def m5():
    """The same app on the web host, through the tailnet's name (scripts/omx_tablet_check.py): no key refused, the question heard and
    answered aloud within 2 s, a tablet-width picture. Needs tailscale up on this machine and build/g72/wav (M4's)."""
    if not shutil.which("tailscale") or sh(["tailscale", "status"]).returncode:
        return "BLOCKED", "tailscale isn't running on this machine"
    ensure_wavs()
    r = sh(["pixi", "run", "python", "scripts/omx_tablet_check.py"], 1800, {"G72_GPU": GPU})
    if r.returncode or "omx_tablet: ok" not in r.stdout:
        return "FAIL", tail(r, 700)
    rep = json.loads((OUT / "omx-tablet.json").read_text())
    return "PASS", (f"over https://{rep['machine']}: no key -> {rep['no_key_page_status']} (page) and {rep['no_key_socket_status']} (socket); the key moved into a cookie; "
                    f"question -> first spoken audio {rep['question_to_first_audio_s']} s (limit {rep['limit_s']}); tablet-width picture docs/goals/72/tablet.png")


# ------------------------------------------------------------------------------------------------ M6: the features come home
# Each sub-scenario is a function m6_<name> returning (PASS|FAIL|BLOCKED, why); M6 passes when every one passes, so the other half
# of the milestone adds its own the same way (a BLOCKED there says what is missing). Mine: m6_comic, m6_picture, m6_notes.

SD_BIN = Path.home() / "Projects/omx-local/third_party/stable-diffusion.cpp/build/bin/sd-server"
LLAMA_SERVER = Path.home() / "Projects/omx-local/third_party/llama.cpp/build/bin/llama-server"
CREATOR_ENV = {  # the creator layout (D-7250): the brain on physical GPU 0 (visible index 1), voice and embeddings on GPU 1 (index 0),
                 # the image model's own process on GPU 1 (OMX_SD_GPU is physical)
    "CUDA_VISIBLE_DEVICES": "1,0", "OMX_LLM_GPU": "1", "OMX_SD": "1", "OMX_SD_GPU": "1", "OMX_SD_PORT": "8291",
    "OMX_NOTES_DIR": str(ROOT / "tests/fixtures/notes"), "OMX_NOTES_CACHE": str(OUT / "notes-cache"),
    "OMX_PICTURES": str(OUT / "pictures"),
}
COMIC_SAYS = "Make a comic about a little robot learning to bake bread."
PIC_SAYS = "Draw me a red fox sitting in a snowy forest."
NOTE_QS = [
    ("When is my next dental cleaning?", "health/dentist.md", r"14 february|february 14|fourteenth"),
    ("What tyre pressure did I write down for the front tyres?", "home/car.md", r"2\.3|two point three"),
    ("Who offered to narrate the onboarding video?", "work/q1-ideas.md", r"priya"),
    ("What time do I land in Lisbon?", "trips/lisbon.md", r"7:40|seven forty"),
    ("How long should grandma's lentil soup simmer?", "recipes.txt", r"\b25\b|twenty-five|twenty five"),
]
NAMED = {"health/dentist.md": r"dentist|dental", "home/car.md": r"\bcar\b|tyre|tire", "work/q1-ideas.md": r"ideas|q1|quarter|work",
         "trips/lisbon.md": r"lisbon|trip", "recipes.txt": r"recipe"}
_CREATOR = {}


def wait_for_gpu(index=0, under_mib=3000, minutes=45):
    """The creator layout needs the brain's card (GPU 0) to itself: another checkout's run holds ~18 GB there while it works, so wait."""
    until = time.time() + minutes * 60
    while time.time() < until:
        used = sh(["nvidia-smi", f"--id={index}", "--query-gpu=memory.used", "--format=csv,noheader,nounits"]).stdout.strip()
        if used.isdigit() and int(used) < under_mib:
            return True
        time.sleep(15)
    return False


def kill_painter():
    """Ends an image server this check left on its own port (looked up by its command line, not by name: other checkouts run theirs)."""
    for d in Path("/proc").iterdir():
        try:
            cmd = (d / "cmdline").read_bytes().split(b"\0")
            if d.name.isdigit() and b"--listen-port" in cmd and cmd[cmd.index(b"--listen-port") + 1] == CREATOR_ENV["OMX_SD_PORT"].encode():
                os.killpg(int(d.name), signal.SIGTERM)
        except (OSError, IndexError, ValueError):
            pass


def typed(text, then, open_box=False):
    """Steps that type `text` into the app's question box (`open_box`: open it first; the Type button toggles it, so only the first
    question taps it), then `then` (a wait or a waitfor)."""
    return ("tap:type;wait:500;" if open_box else "") + f"enter:Type to omx={text};{then}"


def blank_png(path):
    from PIL import Image
    import numpy as np
    im = np.asarray(Image.open(path).convert("L"), dtype=np.float32)
    return float(im.std()) < 12


def creator_session():
    """One run of the app with the creator's features: a comic, a picture, five questions about the notes, a path outside them.
    Pictures of the cards are taken as each lands (the shelf shows the newest first). Memoised: the three sub-scenarios read it."""
    if _CREATOR:
        return _CREATOR
    why = build()
    if why:
        _CREATOR.update(error=why)
        return _CREATOR
    if os.environ.get("G72_REUSE_SESSION") and (OUT / "creator-session.log").exists():  # (re-judge the last run: a vision check that was blocked)
        text = (OUT / "creator-session.log").read_text()
        _CREATOR.update(events=parse_omx(text), out=text)
        return _CREATOR
    shutil.rmtree(OUT / "pictures", ignore_errors=True)
    shutil.rmtree(OUT / "notes-cache", ignore_errors=True)
    ensure_wavs()
    kill_painter()
    if not wait_for_gpu():
        _CREATOR.update(error="GPU 0 stayed busy for 45 minutes (another run's brain is on it)")
        return _CREATOR
    steps = ["waitfor:Listening=240000", "wait:3000",
             typed(COMIC_SAYS, "waitfor:Drawn in=150000", open_box=True), "wait:1500", f"shot:{OUT}/comic_card.png",
             typed(PIC_SAYS, "waitfor:Drawn in=90000"), "wait:1500", f"shot:{OUT}/picture_card.png"]
    for k, (q, f, fact) in enumerate(NOTE_QS):
        steps.append(typed(q, "wait:24000"))
        if k == 0:
            steps.append(f"shot:{OUT}/notes_card.png")
    steps.append(typed("Use find_in_notes with the folder ../../.ssh and the question keys.", "wait:20000"))
    steps.append("wait:500")
    with NullSink():
        ev, r = run_app("file:W/q1.wav@3000", ";".join(steps), "390x844", timeout=900, env_extra=CREATOR_ENV)
    kill_painter()
    for n in ("comic_card.png", "picture_card.png", "notes_card.png"):
        pic(n)
    (OUT / "creator-session.log").write_text(r.stdout + r.stderr)
    _CREATOR.update(events=ev, out=r.stdout + r.stderr)
    return _CREATOR


def vision_check(png, question):
    """Qwen's own eyes: Qwen3.8-27B with its mmproj in omx-local's llama-server (a process of mine on GPU 0, after the app has
    ended and given the card back), asked what the main character of the picture is. mojoui.llm has no image input yet."""
    import base64
    import urllib.request
    mm = MODELS / "mmproj-F16.gguf"
    if not (LLAMA_SERVER.exists() and mm.exists()):
        return None, "no llama-server or mmproj under " + str(MODELS)
    if not wait_for_gpu():
        return None, "GPU 0 stayed busy for 45 minutes (another run's brain is on it)"
    log = open(OUT / "vision-server.log", "w")
    env = dict(os.environ, CUDA_VISIBLE_DEVICES="0")
    srv = subprocess.Popen([str(LLAMA_SERVER), "-m", str(MODELS / "Qwen3.8-27B-UD-Q4_K_M.gguf"), "--mmproj", str(mm), "-ngl", "999", "-c", "4096",
                            "-fa", "on", "--host", "127.0.0.1", "--port", "8199", "--no-webui"], stdout=log, stderr=log, env=env,
                           cwd=LLAMA_SERVER.parent, start_new_session=True)
    try:
        for _ in range(240):
            try:
                urllib.request.urlopen("http://127.0.0.1:8199/health", timeout=1)
                break
            except Exception:
                time.sleep(1)
                if srv.poll() is not None:
                    return None, "llama-server ended: " + (OUT / "vision-server.log").read_text()[-300:]
        else:
            return None, "llama-server never became healthy"
        uri = "data:image/png;base64," + base64.b64encode(Path(png).read_bytes()).decode()
        body = json.dumps({"messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": uri}},
                                                                        {"type": "text", "text": question}]}],
                           "max_tokens": 12, "chat_template_kwargs": {"enable_thinking": False}}).encode()
        req = urllib.request.Request("http://127.0.0.1:8199/v1/chat/completions", body, {"Content-Type": "application/json"})
        return json.loads(urllib.request.urlopen(req, timeout=120).read())["choices"][0]["message"]["content"], ""
    finally:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(srv.pid, sig)
                srv.wait(15)
                break
            except ProcessLookupError:
                break
            except subprocess.TimeoutExpired:
                continue


def m6_comic():
    """omx-local's M21, ported: first panel <= 20 s after the request, four in <= 60 s, none blank, Qwen sees the hero in panel 1."""
    o = creator_session()
    if "error" in o:
        return "FAIL", o["error"]
    ev = o["events"]
    if of(ev, "FAILED"):
        return "FAIL", "the app failed: " + of(ev, "FAILED")[0].get("text", "")
    lines = [e for e in of(ev, "COMIC") if "panel" in e]
    if not lines:
        return "FAIL", "no comic: " + str([(e["kind"], e.get("text", "")[:80]) for e in ev if e["kind"] in ("REPLY", "REFUSED", "CARD")][:4]) + " " + o["out"][-300:]
    first, last = lines[0]["ms"] / 1000, lines[-1]["ms"] / 1000
    files = [e["file"] for e in lines]
    probs = []
    if len(lines) < 4:
        probs.append(f"only {len(lines)} panels landed")
    if first > 20:
        probs.append(f"first panel after {first:.1f} s (> 20)")
    if last > 60:
        probs.append(f"all four after {last:.1f} s (> 60)")
    blanks = [Path(f).name for f in files if blank_png(f)]
    if blanks:
        probs.append("blank panels: " + ", ".join(blanks))
    seen, why = vision_check(files[0], "What is the main character in this picture? Answer in at most three words.") if files else (None, "no panel")
    bench(comic_first_panel_s=round(first, 1), comic_all_s=round(last, 1), comic_panel1_seen=seen)
    if probs:
        return "FAIL", "; ".join(probs)
    if seen is None:
        return "BLOCKED", f"first panel {first:.1f} s, four in {last:.1f} s, none blank; Qwen's eyes could not run: {why}"
    if "robot" not in seen.lower():
        return "FAIL", f"Qwen sees {seen!r} in panel 1"
    return "PASS", f"first panel {first:.1f} s, four panels {last:.1f} s, none blank, Qwen sees {seen.strip()!r} in panel 1; docs/goals/72/comic_card.png"


def m6_picture():
    o = creator_session()
    if "error" in o:
        return "FAIL", o["error"]
    ev = o["events"]
    got = [e for e in of(ev, "PICTURE") if "panel" in e]
    if not got:
        return "FAIL", "no single picture: " + o["out"][-300:]
    ms = got[0]["ms"] / 1000
    f = got[0]["file"]
    if not Path(f).exists() or blank_png(f):
        return "FAIL", f"the picture {f} is missing or blank"
    from PIL import Image
    w, h = Image.open(f).size
    if ms > 20 or (w, h) != (768, 768):
        return "FAIL", f"{w}x{h} after {ms:.1f} s"
    bench(picture_s=round(ms, 1))
    return "PASS", f"{w}x{h} picture {ms:.1f} s after the request, not blank, kept as {Path(f).name}; docs/goals/72/picture_card.png"


def m6_notes():
    """omx-local's M22, ported: >= 4 of 5 questions answered with the right file cited; a path outside the folder refused."""
    o = creator_session()
    if "error" in o:
        return "FAIL", o["error"]
    ev = o["events"]
    good, named, lines = 0, 0, []
    searches = [e for e in of(ev, "NOTES") if "first" in e]
    for k, (q, f, fact) in enumerate(NOTE_QS):
        turn = k + 3  # (turns 1 and 2 were the comic and the picture)
        said = " ".join(e.get("text", "") for e in of(ev, "REPLY", turn)).lower()
        cited = any(s.get("first") == f and s.get("text", "")[:12].lower() == q[:12].lower() for s in searches)
        ok = cited and re.search(fact, said) is not None
        good += ok
        named += bool(re.search(NAMED[f], said))
        lines.append(f"{f.split('/')[-1]}:{'ok' if ok else 'x(' + ('cited' if cited else 'cite') + ')'}")
    refused = [e for e in of(ev, "REFUSED") if "only read your notes folder" in e.get("text", "")]
    declined = of(ev, "REPLY", len(NOTE_QS) + 3)
    unit = sh([str(ROOT / "build/test_creator")], 300, {"CUDA_VISIBLE_DEVICES": "1"})
    refused_ok = "creator: ok" in unit.stdout
    bench(notes_good=good, notes_named=named, notes_search_ms=[s.get("search_ms") for s in searches])
    probs = []
    if good < 4:
        probs.append(f"{good}/5 notes answers right: {' '.join(lines)}")
    if not refused_ok:
        probs.append("the unit test of the outside-path refusal did not pass: " + tail(unit, 300))
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", (f"{good}/5 answered and cited ({' '.join(lines)}), the note named aloud in {named}/5; searches {[s.get('search_ms') for s in searches]} ms; "
                    f"'../../.ssh' refused (unit test), asked aloud in the app: {'the tool refused it' if refused else 'the model declined by itself: ' + (declined[0].get('text', '')[:80] if declined else '(no answer)')}; docs/goals/72/notes_card.png")


def m6():
    parts = {k[3:]: f for k, f in sorted(globals().items()) if k.startswith("m6_") and callable(f)}
    states, whys = [], []
    for name, f in parts.items():
        try:
            st, why = f()
        except Exception as e:  # shown, never swallowed
            st, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"  M6-{name}: {st}  {why}", flush=True)
        states.append(st)
        whys.append(f"{name}: {st}")
    state = "FAIL" if "FAIL" in states else ("BLOCKED" if "BLOCKED" in states else "PASS")
    return state, " | ".join(whys)


def m7():
    return "BLOCKED", "M7 (nothing regressed) waits for M6 and goal 71's check"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7}


def main():
    want = [a.upper() for a in sys.argv[1:]] or list(MILESTONES)
    bad = 0
    for k in want:
        t0 = time.time()
        try:
            state, why = MILESTONES[k]()
        except Exception as e:  # shown, never swallowed
            state, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {state}  {why}  ({time.time() - t0:.0f} s)", flush=True)
        bad += state == "FAIL"
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
