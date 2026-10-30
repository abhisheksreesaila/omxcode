"""Milestone checker for docs/goals/43-GOAL.md (goal 43: Dictate, what the web can't do). Prints PASS/FAIL per milestone.

Run: pixi run python docs/goals/43-check.py        (a subset: … 43-check.py M0 M3)
Written before the work (2026-10-30), from the goal's words; never edited to make a milestone pass (add, don't weaken).
GTK runs are headless. Audio goes through a virtual null sink this checker creates and always removes; the owner's real
microphone and speakers are never used. WER is computed here, from the texts the code printed, never taken on trust.
"""

import contextlib
import json
import os
import re
import subprocess
import sys
import time
import wave
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
DATA = ROOT / "docs" / "goals" / "43"
CLIPS = DATA / "clips"
APP = ROOT / "build" / "dictate"


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)


def words(text):
    return re.sub(r"[^a-z0-9' ]", " ", text.lower().replace("’", "'")).split()


def wer(refs, hyps):
    """Word error rate over all pairs (Levenshtein on words)."""
    errors = total = 0
    for r, h in zip(refs, hyps):
        r, h = words(r), words(h)
        d = list(range(len(h) + 1))
        for i in range(1, len(r) + 1):
            prev, d[0] = d[0], i
            for j in range(1, len(h) + 1):
                cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
                prev, d[j] = d[j], cur
        errors += d[len(h)]
        total += len(r)
    return errors / max(total, 1)


def clips():
    """The 20 LibriSpeech clips: (id, wav path, reference text)."""
    out = []
    for w in sorted(CLIPS.glob("*.wav")):
        t = w.with_suffix(".txt")
        if t.exists():
            out.append((w.stem, w, t.read_text().strip()))
    return out


def seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


@contextlib.contextmanager
def null_sink():
    name = f"g43_check_{os.getpid()}"
    r = run(["pactl", "load-module", "module-null-sink", f"sink_name={name}", "sink_properties=device.description=g43-check"])
    if r.returncode != 0:
        raise RuntimeError("couldn't make a null sink: " + r.stderr)
    module = r.stdout.strip()
    try:
        yield name, name + ".monitor"
    finally:
        run(["pactl", "unload-module", module])


def play(sink, path):
    return run(["paplay", f"--device={sink}", str(path)], 600)


def with_audio(cmd, files, env, lead=1.5, gap=1.5, timeout=900):
    """Runs cmd while files play into a fresh null sink (lead seconds after start, gap between); returns (code, output)."""
    import headless
    headless.ensure()
    with null_sink() as (sink, source):
        e = dict(os.environ, MOJOUI_AUDIO_SOURCE=source, **env)
        p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=e)
        time.sleep(lead)
        for f in files:
            play(sink, f)
            time.sleep(gap)
        try:
            out, _ = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            out, _ = p.communicate()
            return -9, out
        return p.returncode, out


def mojo_cmd(path, envname="speech"):
    return ["pixi", "run", "-e", envname, "mojo", "run", "-I", ".", path]


def m0():
    tone = DATA / "tone.wav"
    if not (ROOT / "tests/test_audio.mojo").exists() or not tone.exists():
        return False, "tests/test_audio.mojo or docs/goals/43/tone.wav missing"
    code, out = with_audio(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_audio.mojo"], [tone],
                           {"MOJOUI_AUDIO_SECONDS": str(round(seconds(tone) + 4)), "MOJOUI_AUDIO_REF": str(tone)})
    m = re.search(r"audio match: ([\d.]+)", out)
    if code != 0 or "audio capture: ok" not in out or "audio ui free: ok" not in out or not m:
        return False, f"exit {code}: {out[-500:]}"
    if float(m.group(1)) < 0.9:
        return False, f"audio match {m.group(1)} (≥ 0.9)"
    return True, f"captured the played tone through the sound server, match {m.group(1)}, the caller never blocked"


def m1():
    cs = clips()
    if len(cs) != 20:
        return False, f"{len(cs)} clips with reference text in docs/goals/43/clips (want 20)"
    if not (ROOT / "tests/test_speech.mojo").exists():
        return False, "tests/test_speech.mojo missing"
    r = run(mojo_cmd("tests/test_speech.mojo"), 3600, env=dict(os.environ, SPEECH_CLIPS=str(CLIPS)))
    out = r.stdout + r.stderr
    hyps = dict(re.findall(r"^speech hyp: (\S+) (.*)$", out, re.M))
    if r.returncode != 0 or "speech partials: ok" not in out or len(hyps) != 20:
        return False, f"exit {r.returncode}; {len(hyps)} hypotheses; partials {'speech partials: ok' in out}: {out[-400:]}"
    if "whisper-large-v3-turbo" not in out:
        return False, "the test doesn't say it ran whisper-large-v3-turbo"
    src = (ROOT / "mojoui/speech.mojo").read_text()
    if re.search(r"\b(requests|urllib|http\.client|socket)\b|\.wav\b.*write|tempfile", src):
        return False, "mojoui/speech.mojo looks like it hands audio over by file or network"
    w = wer([t for _, _, t in cs], [hyps.get(i, "") for i, _, _ in cs])
    if w > 0.05:
        return False, f"WER {w:.3f} (≤ 0.05)"
    return True, f"whisper-large-v3-turbo in process, 20 clips, WER {w:.3f}, partials before each clip ends"


def m2():
    r = run(["scripts/build.sh", "dictate", "linux"], 3600)
    if r.returncode != 0:
        return False, "linux build failed: " + (r.stdout + r.stderr)[-300:]
    cs = clips()[:5]
    if len(cs) < 5:
        return False, "clips missing"
    total = sum(seconds(w) for _, w, _ in cs) + 1.5 * len(cs) + 4
    shot = DATA / "dictate-gtk.png"
    steps = ["pause:500", "tap:Record", f"pause:{int(total * 1000)}", "tap:Stop", "pause:1500"]
    code, out = with_audio([str(APP / "linux" / "dictate")], [w for _, w, _ in cs],
                           {"MOJOUI_TEST": ";".join(steps), "MOJOUI_SHOT": str(shot)}, lead=2.0, timeout=int(total) + 300)
    finals = re.findall(r"^DICTATE FINAL: ms=([\d.]+) text=(.*)$", out, re.M)
    if code != 0 or len(finals) != 5:
        return False, f"exit {code}; {len(finals)} finals for 5 clips: {out[-400:]}"
    w = wer([t for _, _, t in cs], [t for _, t in finals])
    ms = sorted(float(m) for m, _ in finals)
    p95 = ms[min(len(ms) - 1, int(round(0.95 * (len(ms) - 1))))]
    if w > 0.08 or p95 > 500:
        return False, f"WER {w:.3f} (≤ 0.08); end of speech → final p95 {p95} ms (≤ 500)"
    if not shot.exists():
        return False, "no screenshot"
    return True, f"5 clips through the null sink: WER {w:.3f}, final text {ms[len(ms) // 2]:.0f} ms median / {p95:.0f} ms p95 after speech ends"


def m3():
    path = DATA / "race.json"
    if not path.exists():
        return False, "docs/goals/43/race.json missing (scripts/dictate_race.py)"
    race = json.loads(path.read_text())
    srcs = ["mojoui/audio.mojo", "mojoui/speech.mojo", "scripts/dictate_race.py"]
    stale = run(["git", "diff", "--quiet", race.get("commit", "none"), "HEAD", "--", *srcs]).returncode != 0
    dirty = run(["git", "diff", "--quiet", "HEAD", "--", *srcs]).returncode != 0
    if stale or dirty:
        return False, f"race.json is stale for {srcs}"
    cs = clips()
    refs = {i: t for i, _, t in cs}
    out = {}
    for side in ("a", "b"):
        s = race.get(side, {})
        need = ["model", "cold_start_s", "p50_ms", "p95_ms", "rtf", "peak_gpu_mb", "hyps"]
        missing = [k for k in need if k not in s]
        if missing:
            return False, f"race.json side {side} lacks {missing}"
        if sorted(s["hyps"]) != sorted(refs):
            return False, f"side {side} didn't transcribe the 20 clips"
        out[side] = wer([refs[i] for i in sorted(refs)], [s["hyps"][i] for i in sorted(refs)])
    a, b = race["a"], race["b"]
    if "gpu_index" not in race or "download_mb" not in b or "quiet" not in race:
        return False, "race.json lacks gpu_index, b.download_mb or quiet"
    same = a["model"].split("/")[-1].replace("-ONNX", "").lower() == b["model"].split("/")[-1].replace("-ONNX", "").lower()
    if not same and not race.get("b_why_other_model"):
        return False, f"different models ({a['model']} vs {b['model']}) and no reason given"
    verdict = (f"A {a['p50_ms']:.0f} ms p50, WER {out['a']:.3f}; B ({b['model']}) {b['p50_ms']:.0f} ms p50, WER {out['b']:.3f}; "
               f"cold start {a['cold_start_s']:.1f} s vs {b['cold_start_s']:.1f} s")
    if same:
        won = a["p50_ms"] <= b["p50_ms"] / 2 and out["a"] <= out["b"] + 0.01
    else:
        won = a["p50_ms"] < b["p50_ms"] and out["a"] < out["b"]
    if not won:
        return False, "omxcode didn't win: " + verdict
    return True, verdict


def m4():
    problems = []
    page = (ROOT / "docs" / "gallery" / "index.html").read_text()
    if "Dictation" not in page:
        problems.append("no Dictation section in the gallery")
    if "img/dictate-gtk.png" not in page or not (ROOT / "docs/gallery/img/dictate-gtk.png").exists():
        problems.append("dictate-gtk.png not shown or missing")
    race = DATA / "race.json"
    if race.exists():
        r = json.loads(race.read_text())
        for side in ("a", "b"):
            if f"{r[side]['p50_ms']:.0f}" not in page:
                problems.append(f"the gallery doesn't show side {side}'s p50 from race.json")
    else:
        problems.append("race.json missing")
    if run(["pixi", "run", "python", "scripts/components.py", "--check"]).returncode != 0:
        problems.append("docs/components.md is stale")
    comps = (ROOT / "docs" / "components.md").read_text().lower()
    for word in ("microphone", "speech model"):
        if word not in comps:
            problems.append(f"docs/components.md doesn't list {word}")
    llms = (ROOT / "docs" / "llms.txt").read_text()
    for mod in ("mojoui.audio", "mojoui.speech"):
        if mod not in llms:
            problems.append(f"docs/llms.txt doesn't name {mod}")
    top = (ROOT / "EXPERIMENTS.md").read_text().split("\n## ", 2)
    if len(top) < 2 or "43" not in top[1].splitlines()[0]:
        problems.append("EXPERIMENTS.md's newest entry isn't goal 43")
    r = run(["scripts/build.sh", "dictate", "mac"], 3600)
    if r.returncode != 0:
        problems.append("mac build failed: " + (r.stdout + r.stderr)[-150:])
    if problems:
        return False, "; ".join(problems)
    return True, "gallery Dictation section with the race's numbers, matrix, llms.txt, EXPERIMENTS; mac built"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4}

if __name__ == "__main__":
    pick = [a for a in sys.argv[1:] if a in MILESTONES] or list(MILESTONES)
    failed = 0
    for name in pick:
        try:
            ok, msg = MILESTONES[name]()
        except Exception as e:  # a crash in a proof is a FAIL, not a pass
            ok, msg = False, f"{type(e).__name__}: {e}"
        failed += not ok
        print(f"{name} {'PASS' if ok else 'FAIL'}: {msg}", flush=True)
    sys.exit(1 if failed else 0)
