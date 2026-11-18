"""Goal 72's proof: omx, the voice app, rebuilt on omxcode (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/72-check.py [M0 M1 ...]          (default: every milestone)

M6 has parts you can run alone: M6-UNITS, M6-TODO, M6-NEWS, M6-JOBS, M6-CLOUD (the other half adds M6-COMICS, M6-NOTES).
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


_BUILT = []


def build():
    if _BUILT:  # (once a run: the sub-scenarios share one binary)
        return _BUILT[0]
    r = sh(["scripts/build.sh", "omx", "linux"], 3600)
    _BUILT.append(None if r.returncode == 0 else "build failed: " + tail(r, 1500))
    return _BUILT[0]


def run_app(source, steps, window=None, record=None, timeout=300, env=None):
    """examples/omx on GTK on the headless display, the recorded voice as its microphone; the OMX lines it printed, in order,
    as dicts {kind, ...} (turn=, ms=, text=, ...)."""
    import headless

    headless.ensure()
    extra_env = env
    env = {"CUDA_VISIBLE_DEVICES": GPU, "OMX_LLM_GPU": "0", "OMX_MODELS": str(MODELS), "MOJOUI_AUDIO_SINK": SINK,
           "MOJOUI_AUDIO_SOURCE": source.replace("W/", str(WAV) + "/"), "MOJOUI_TEST": steps}
    env.update(extra_env or {})
    if window:
        env["MOJOUI_WINDOW"] = window
    r = sh([str(ROOT / "build/omx/linux/omx")], timeout, env)
    events = []
    for line in r.stdout.splitlines():
        m = re.match(r"OMX (\w+): (.*)$", line)
        if not m:
            continue
        kv, rest = {"raw": m.group(2)}, m.group(2)
        text_at = rest.find(" text=")
        if text_at >= 0:
            kv["text"], rest = rest[text_at + 6:], rest[:text_at]
        elif rest.startswith("text="):
            kv["text"], rest = rest[5:], ""
        for k, v in re.findall(r"(\w+)=(\S+)", rest):
            kv[k] = int(v) if v.lstrip("-").isdigit() else v
        events.append({"kind": m.group(1), **kv})
    return events, r


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
#
# The cards are the assistant's own (mojoui.assistant): to-do, news, think-it-through jobs, the cloud lane. The turns are typed
# (the Type box, as a person at a keyboard would) except where the voice itself is the point (the job's second turn is a
# recorded voice). Layout: the brain on card $G72_BRAIN_GPU (default 0), the voice models on card $G72_VOICE_GPU (default 1).
# Sub-scenarios: M6-UNITS, M6-TODO, M6-NEWS, M6-JOBS, M6-CLOUD (with the frame), and the other half's (M6-COMICS, M6-NOTES:
# BLOCKED until they are merged). M6 passes when every sub-scenario does.

BRAIN_GPU = os.environ.get("G72_BRAIN_GPU", "0")
VOICE_GPU = os.environ.get("G72_VOICE_GPU", "1")
SPLIT = {"CUDA_DEVICE_ORDER": "PCI_BUS_ID", "CUDA_VISIBLE_DEVICES": f"{VOICE_GPU},{BRAIN_GPU}", "OMX_LLM_GPU": "1"}
SILENT = "file:W/q1.wav@3000"  # a recorded voice that starts after the run is over: the microphone hears nothing
TYPED_OPEN = "waitfor:Listening=300000;wait:1500;tap:Type;wait:500;"


def turn(text, wait_ms=150000):
    """One typed turn, then until the assistant is listening again (the reply said)."""
    assert ";" not in text and "=" not in text
    return f"enter:Type to omx={text};wait:800;waitfor:Listening={wait_ms};wait:400;"


def replies(ev):
    return {e["turn"]: e.get("text", "") for e in of(ev, "REPLY")}


def raw_of(ev, kind):
    return [e["raw"] for e in of(ev, kind)]


def m6_units():
    out = []
    for name in ("todo", "news", "cloudlane"):
        b = sh(["pixi", "run", "mojo", "build", "--disable-warnings", "-I", ".", "-I", "vendor", f"tests/test_{name}.mojo", "-o", f"build/test_{name}"], 900)
        if b.returncode:
            return "FAIL", f"build test_{name}: " + tail(b, 600)
        r = sh([f"build/test_{name}"], 300)
        if r.returncode or f"{name}: ok" not in r.stdout:
            return "FAIL", f"test_{name}: " + tail(r, 600)
        out.append(r.stdout.strip().splitlines()[-1])
    return "PASS", " | ".join(out) + " (fixtures: 19 routing utterances land right: local, cloud, background)"


def m6_todo():
    """omx-local M16: five things said at once are on the list and on the card, 'I called mum' ticks that one, 'what's left' is
    answered from the list, a tap on a tick box ticks it, and the list is still there after the app is started again."""
    why = build()
    if why:
        return "FAIL", why
    ensure_wavs()
    store = OUT / "m6-todo.json"
    store.unlink(missing_ok=True)
    env = {**SPLIT, "MOJOUI_TODO": str(store)}
    steps = (TYPED_OPEN
             + turn("I have five things to do: buy milk, call mum, book the dentist, fix the bike and send the invoice.")
             + f"shot:{OUT}/todo_five.png;wait:300;"
             + turn("I finished the second one, I called mum.")
             + turn("What is left on my to do list?")
             + "tick:todo-1;wait:1500;" + f"shot:{OUT}/todo_ticked.png;wait:300")
    with NullSink():
        ev, r = run_app(SILENT, steps, env=env)
    pic("todo_five.png"), pic("todo_ticked.png")
    probs, said = [], []
    items = json.loads(store.read_text())["items"] if store.exists() else []
    texts = [i["text"].lower() for i in items]
    if len(items) != 5 or not all(any(k in t for t in texts) for k in ("milk", "mum", "dentist", "bike", "invoice")):
        probs.append(f"the file holds {[i['text'] for i in items]}, not the five things")
    else:
        said.append("five things in one turn: " + ", ".join(i["text"] for i in items))
    todo_lines = raw_of(ev, "TODO")
    if not any(" open=5 total=5" in l for l in todo_lines):
        probs.append("the card never showed 5 open: " + str(todo_lines))
    done = [i["text"] for i in items if i["done"]]
    if len(done) != 2 or not any("mum" in d.lower() for d in done) or not any("milk" in d.lower() for d in done):
        probs.append(f"after 'I called mum' and a tap on the first box the ticked ones are {done}, wanted 'call mum' and 'buy milk'")
    else:
        said.append("'I called mum' ticked 'call mum'; a tap on the first tick box ticked 'buy milk' (file and card agree)")
    if not any(" open=4 total=5" in l for l in todo_lines):
        probs.append("no moment with exactly the mum thing done (open=4): " + str(todo_lines))
    if not any(l.startswith("tick open=3") for l in todo_lines):
        probs.append("the tap on a tick box didn't reach the list: " + str(todo_lines))
    rep = replies(ev)
    if not re.search(r"\bfour\b|\b4\b", rep.get(3, ""), re.I):
        probs.append(f"'what is left' answered {rep.get(3)!r}, wanted four")
    else:
        said.append(f"'what's left' -> {rep[3]!r}")
    # restart: a new process reads the same file
    with NullSink():
        ev2, r2 = run_app(SILENT, TYPED_OPEN + turn("How many things are still open on my to do list?") + "waitfor:3 left of 5=1000;wait:300", env=env)
    rep2 = replies(ev2)
    if not re.search(r"\bthree\b|\b3\b", rep2.get(1, ""), re.I) or "WAITED: 3 left of 5" not in r2.stdout:
        probs.append(f"after a restart: answered {rep2.get(1)!r}, card '3 left of 5' {'shown' if 'WAITED: 3 left of 5' in r2.stdout else 'not shown'}")
    else:
        said.append(f"after a restart the list was still there: {rep2[1]!r}, card '3 left of 5'")
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


def m6_news():
    """omx-local M17: two topics, each a list card of >= 3 headlines with sources, on the shelf within 12 s, and a spoken gist."""
    why = build()
    if why:
        return "FAIL", why
    ensure_wavs()
    topics = ["What is happening with SpaceX?", "What is the latest news about the Linux kernel?"]
    steps = TYPED_OPEN + turn(topics[0]) + f"shot:{OUT}/news_one.png;wait:300;" + turn(topics[1]) + f"shot:{OUT}/news_two.png;wait:300"
    with NullSink():
        ev, r = run_app(SILENT, steps, env={**SPLIT})
    pic("news_one.png"), pic("news_two.png")
    probs, said = [], []
    news = [e for e in of(ev, "NEWS") if "failed" not in e["raw"]]
    if len(news) < 2:
        probs.append("fewer than two news cards: " + str(raw_of(ev, "NEWS")))
    for n in news[:2]:
        first = re.search(r"first=(.*)$", n["raw"])
        sourced = bool(first and " | " in first.group(1) and first.group(1).split(" | ")[0].strip())
        if n.get("items", 0) < 3 or not sourced:
            probs.append(f"{n.get('topic')}: {n.get('items')} items, first {first.group(1) if first else None!r}")
        elif n["card_ms"] > 12000:
            probs.append(f"{n.get('topic')}: the card took {n['card_ms']} ms (limit 12000)")
        else:
            said.append(f"{n.get('topic')}: {n['items']} headlines with sources, the card {n['card_ms']} ms after the question (feed {n['feed_ms']} ms)")
    rep = replies(ev)
    for t in (1, 2):
        text = rep.get(t, "")
        sentences = len(re.findall(r"[.!?](?:\s|$)", text))
        if len(text) < 20 or sentences < 2:
            probs.append(f"turn {t}'s gist is {text!r} ({sentences} sentences)")
        else:
            said.append(f"gist {t}: {text!r}")
    bench(news=[{k: n.get(k) for k in ("topic", "items", "feed_ms", "card_ms")} for n in news[:2]])
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


def m6_jobs():
    """omx-local M23: 'think it through' starts a job on its own sequence; while it thinks a spoken question is answered at once
    (first audio <= 1.5 s); the job card shows a clock then the answer, never the thinking; one spoken sentence says it is done
    (heard back through the speaker's own audio); and the next turn knows what the job concluded."""
    why = build()
    if why:
        return "FAIL", why
    ensure_wavs()
    task = ("Think it through and get back to me: I have 3,000 dollars. Should I buy a second RTX 3090 or one RTX 5090 for running "
            "local AI at home? Weigh price, power and which models fit.")
    follow = "What did you conclude about the graphics card question?"
    steps = (TYPED_OPEN + turn(task, 90000) + f"shot:{OUT}/job_running.png;wait:300;"
             + "waitfor:Dismiss=420000;wait:9000;" + f"shot:{OUT}/job_done.png;wait:300;" + turn(follow, 90000))
    with NullSink() as sink:
        sink.record(OUT / "m6-jobs.wav")
        ev, r = run_app("file:W/q1.wav@25", steps, env={**SPLIT}, timeout=900)
        sink.stop_recording()
    pic("job_running.png"), pic("job_done.png")
    probs, said = [], []
    kinds = [(e["kind"], e.get("raw", "")[:24]) for e in ev]
    started = [i for i, e in enumerate(ev) if e["kind"] == "JOB" and e["raw"].startswith("started")]
    finished = [i for i, e in enumerate(ev) if e["kind"] == "JOB" and (e["raw"].startswith("done") or e["raw"].startswith("failed"))]
    if not started:
        return "FAIL", "no job was started: " + str(raw_of(ev, "REPLY")[:2] or kinds[:8])
    voice_turns = [e for e in of(ev, "HEARD") if "capital" in e.get("text", "").lower()]
    first = [e for e in of(ev, "FIRST_AUDIO") if voice_turns and e["turn"] == voice_turns[0]["turn"]]
    if not voice_turns or not first:
        probs.append(f"the voice turn during the job: heard {[e.get('text') for e in voice_turns]}, first audio {first}")
    else:
        i_first = ev.index(first[0])
        running = bool(finished) and i_first < finished[0]
        ok = running and first[0]["ms"] <= 1500
        (said if ok else probs).append(
            f"a spoken question while the job ran (job {'still running' if running else 'ALREADY DONE: nothing proved'}): first audio {first[0]['ms']} ms (limit 1500); "
            f"answered {replies(ev).get(voice_turns[0]['turn'], '')!r}")
        bench(job_voice_first_audio_ms=first[0]["ms"])
        if "paris" not in replies(ev).get(voice_turns[0]["turn"], "").lower():
            probs.append("the voice turn's answer isn't Paris")
    done = [e for e in of(ev, "JOB") if e["raw"].startswith("done")]
    if not done:
        probs.append("the job did not finish: " + str(raw_of(ev, "JOB")))
    else:
        d = done[0]
        if d.get("answer_chars", 0) <= 200 or "<think>" in d["raw"] or "</think>" in d["raw"]:
            probs.append(f"the job's answer: {d.get('answer_chars')} chars, raw {d['raw'][:200]!r}")
        elif d.get("thought_chars", 0) <= 0:
            probs.append("no separate thinking came back (was thinking on?)")
        else:
            said.append(f"the job finished in {d['seconds']} s: {d['answer_chars']} chars of answer, {d['thought_chars']} chars of thinking kept off the card")
            bench(job_seconds=d["seconds"], job_answer_chars=d["answer_chars"], job_thought_chars=d["thought_chars"])
    if not any(e["raw"] == "notice" for e in of(ev, "JOB")):
        probs.append("no spoken notice")
    spoken = hear(OUT / "m6-jobs.wav")
    bench(m6_jobs_as_heard=spoken)
    (said if re.search(r"finished thinking", spoken, re.I) else probs).append(f"the speaker's audio, heard back: ...{spoken[-160:]!r}")
    rep = replies(ev)
    last = max(rep) if rep else 0
    if not re.search(r"3090|5090|3,?000|two cards|second", rep.get(last, ""), re.I):
        probs.append(f"the turn after the job didn't know what it concluded: {rep.get(last)!r}")
    else:
        said.append(f"the next turn knew the conclusion: {rep[last]!r}")
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


def edge_orange(png):
    """The share of the picture's border (4 px wide, the middle of each side) that is the warning tone's orange."""
    from PIL import Image

    im = Image.open(png).convert("RGB")
    w, h = im.size
    px = im.load()
    hits = total = 0
    for k in range(int(h * 0.2), int(h * 0.8)):
        for x in list(range(0, 4)) + list(range(w - 4, w)):
            r, g, b = px[x, k]
            total += 1
            hits += r > 200 and 90 < g < 200 and b < 130 and r - b > 90
    for k in range(int(w * 0.2), int(w * 0.8)):
        for y in list(range(0, 4)) + list(range(h - 4, h)):
            r, g, b = px[k, y]
            total += 1
            hits += r > 200 and 90 < g < 200 and b < 130 and r - b > 90
    return hits / max(total, 1)


def m6_cloud():
    """omx-local M6 and M18: 'ask Claude' goes to the logged-in `claude -p` once (capped, a record of the bytes sent), "Asking
    Claude." is said first, the lane chip says Claude · cloud and the whole screen has an orange frame while the cloud speaks,
    and neither is there on a local turn before or after. One real request per run."""
    why = build()
    if why:
        return "FAIL", why
    ensure_wavs()
    ledger = OUT / "m6-ledger.jsonl"
    ledger.unlink(missing_ok=True)
    env = {**SPLIT, "MOJOUI_LEDGER": str(ledger), "OMX_CLOUD_CAP": "3"}
    steps = (TYPED_OPEN + turn("What is two plus two?", 90000) + f"shot:{OUT}/frame_local.png;wait:300;"
             + "enter:Type to omx=Ask Claude: in one sentence, what is a monad?;wait:800;waitfor:Claude · cloud=30000;wait:1200;"
             + f"shot:{OUT}/frame_cloud.png;wait:300;waitfor:Local · Qwen 27B=120000;wait:1500;shot:{OUT}/frame_after.png;wait:300")
    with NullSink() as sink:
        sink.record(OUT / "m6-cloud.wav")
        ev, r = run_app(SILENT, steps, env=env, timeout=600)
        sink.stop_recording()
    for n in ("frame_local.png", "frame_cloud.png", "frame_after.png"):
        pic(n)
    probs, said = [], []
    lanes = [e["raw"].split()[0] for e in of(ev, "LANE")]
    if lanes != ["cloud", "local"]:
        probs.append(f"lane events {lanes}, wanted cloud then local")
    cloud = of(ev, "CLOUD")
    if not cloud or "failed" in cloud[0]["raw"] or len(cloud[0].get("text", "")) <= 10:
        probs.append("no cloud answer: " + str([c["raw"][:80] for c in cloud]))
    rows = [json.loads(l) for l in ledger.read_text().splitlines()] if ledger.exists() else []
    if len(rows) != 1 or rows[0].get("outcome") != "ok" or rows[0].get("bytes_out", 0) <= 0 or rows[0].get("bytes_in", 0) <= 0:
        probs.append(f"the ledger: {rows}")
    else:
        said.append(f"cloud via {rows[0]['provider']} {rows[0]['model']}: {rows[0]['bytes_out']} bytes out, {rows[0]['bytes_in']} in, {rows[0]['seconds']} s, one ledger row; "
                    f"answer {cloud[0]['text'][:90]!r}")
        bench(cloud_bytes_out=rows[0]["bytes_out"], cloud_seconds=rows[0]["seconds"])
    spoken = hear(OUT / "m6-cloud.wav")
    bench(m6_cloud_as_heard=spoken)
    (said if re.search(r"asking claude", spoken, re.I) else probs).append(f"spoken first: ...{spoken[:140]!r}")
    # the frame (M18): pixels at the screen's edge
    try:
        local, cl, after = (edge_orange(OUT / n) for n in ("frame_local.png", "frame_cloud.png", "frame_after.png"))
    except Exception as e:  # noqa: BLE001
        return "FAIL", f"frame pictures: {type(e).__name__}: {e}; " + "; ".join(probs)
    bench(frame_orange_local=round(local, 3), frame_orange_cloud=round(cl, 3), frame_orange_after=round(after, 3))
    if local > 0.02 or cl < 0.5 or after > 0.02:
        probs.append(f"the orange frame: local turn {local:.0%}, cloud turn {cl:.0%}, afterwards {after:.0%} of the edge (want ~0, >=50%, ~0)")
    else:
        said.append(f"orange frame at the edge: local {local:.0%}, cloud turn {cl:.0%}, back on local {after:.0%}; chip 'Claude · cloud' while it spoke")
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


def m6_other(name):
    return "BLOCKED", f"{name} belongs to the other half of M6 (comics, notes search): not merged into this branch yet"


M6_PARTS = {"M6-UNITS": m6_units, "M6-TODO": m6_todo, "M6-NEWS": m6_news, "M6-JOBS": m6_jobs, "M6-CLOUD": m6_cloud,
            "M6-COMICS": lambda: m6_other("M6-COMICS"), "M6-NOTES": lambda: m6_other("M6-NOTES")}


def m6():
    results = {}
    for k, fn in M6_PARTS.items():
        t0 = time.time()
        try:
            results[k] = fn()
        except Exception as e:  # noqa: BLE001
            results[k] = ("FAIL", f"{type(e).__name__}: {e}")
        print(f"  {k}: {results[k][0]}  {results[k][1]}  ({time.time() - t0:.0f} s)", flush=True)
    states = [v[0] for v in results.values()]
    summary = "; ".join(f"{k} {v[0]}" for k, v in results.items())
    if "FAIL" in states:
        return "FAIL", summary
    return ("BLOCKED", summary) if "BLOCKED" in states else ("PASS", summary)


def m7():
    return "BLOCKED", "M7 (nothing regressed) waits for M6 and goal 71's check"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7, **M6_PARTS}


def main():
    want = [a.upper() for a in sys.argv[1:]] or [k for k in MILESTONES if k not in M6_PARTS]
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
