"""Goal 43 M4: the gallery's Dictation section, its numbers drawn from docs/goals/43/race.json (both sides, a loss
included), and img/dictate-gtk.png copied from docs/goals/43. Rewrites the <article id="dictation"> block in place
(or adds it after the Drawing section). Run: pixi run python scripts/dictate_gallery.py
"""

import json
import re
import shutil
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "gallery" / "index.html"
RACE = ROOT / "docs" / "goals" / "43" / "race.json"


def main():
    r = json.loads(RACE.read_text())
    a, b = r["a"], r["b"]
    shutil.copy(ROOT / "docs" / "goals" / "43" / "dictate-gtk.png", ROOT / "docs" / "gallery" / "img" / "dictate-gtk.png")
    won = a["p50_ms"] <= b["p50_ms"] / 2 and a["wer"] <= b["wer"] + 0.01
    verdict = (f"omxcode {b['p50_ms'] / a['p50_ms']:.1f}× faster at the median" if won
               else "omxcode didn't win by the goal's margin (half the web's median at the same accuracy): a FAIL, recorded")
    loaded = [v for v in b.get("variants", []) if v.get("loaded")]
    refused = [v for v in b.get("variants", []) if not v.get("loaded")]
    b_prec = f"{b['dtype']['encoder_model']} encoder, {b['dtype']['decoder_model_merged']} decoder" if b.get("dtype") else ""
    rows = [
        ("Model", escape(a["model"]), escape(b["model"])),
        ("Precision", "fp16", escape(b_prec)),
        ("Per clip, median (audio in → final text)", f"{a['p50_ms']:.0f} ms", f"{b['p50_ms']:.0f} ms"),
        ("Per clip, p95", f"{a['p95_ms']:.0f} ms", f"{b['p95_ms']:.0f} ms"),
        ("Real-time factor", f"{a['rtf']:.3f}", f"{b['rtf']:.3f}"),
        ("Word error rate (20 clips)", f"{a['wer']:.3f}", f"{b['wer']:.3f}"),
        ("Cold start (process → model ready)", f"{a['cold_start_s']:.1f} s", f"{b['cold_start_s']:.1f} s"),
        ("Peak GPU memory", f"{a['peak_gpu_mb']:,} MB", f"{b['peak_gpu_mb']:,} MB"),
        ("Downloaded by the page", "—", f"{b['download_mb']:,.0f} MB"),
    ]
    table = "".join(f"<tr><th>{k}</th><td>{x}</td><td>{y}</td></tr>" for k, x, y in rows)
    variants = "; ".join(f"{v['encoder']}/{v['decoder']}: {v['p50_ms']:.0f} ms median, WER {v['wer']:.3f}" for v in loaded)
    why_b = (f" fp16 didn't load in Chromium on this GPU (“{escape(refused[0]['error'][:90])}”), so the web side ran the same "
             f"model's other exports and keeps its fastest ({variants}).") if refused else ""
    block = f'''  <article class="card" data-kind="native" id="dictation">
    <div class="head"><h2>Dictation · speech to text on this machine's GPU, raced against the browser</h2><span class="tag native">Native wins</span>
      <span class="src"><a href="https://github.com/abhisheksreesaila/omxcode/tree/main/examples/dictate">examples/dictate/</a></span></div>
    <div class="body">
      <div class="shots">
        <figure><img src="img/dictate-gtk.png" alt="Dictate in a native Linux window, Liquid theme: a Record button, the model's name, and five transcripts of spoken LibriSpeech sentences, each with a readout like 316 ms after you stopped, on NVIDIA GeForce RTX 3090, on this machine" loading="lazy"><figcaption>Linux (GTK): five sentences played into a virtual microphone; each transcript says how long after the speaker stopped its final text was on screen, and where it ran.</figcaption></figure>
      </div>
      <div class="why">
        <p>Two components, not an app trick: <code>mojoui.audio</code> captures 16 kHz from the system's sound server on a thread of its own, and <code>mojoui.speech</code> runs whisper-large-v3-turbo on the GPU inside the app's own process, handed the samples by address (no file, no socket, no second process). Words appear while you speak; the final text of a sentence was on screen {escape(str(round(sorted(a['ms'].values())[len(a['ms']) // 2])))} ms (median, whole clip) after the audio went in on the race below, and 290–330 ms after the speaker stopped in the app.</p>
        <p>The race (same 20 LibriSpeech clips, same model, same RTX 3090, the GPU otherwise quiet): {verdict}.{why_b} The browser got each clip as a file, which favours it (it has no microphone headless).</p>
        <table class="race"><tr><th></th><th>omxcode (in process)</th><th>transformers.js (WebGPU, Chromium)</th></tr>{table}</table>
        <p>Measured by <code>scripts/dictate_race.py</code> (<code>docs/goals/43/race.json</code>, commit {escape(r['commit'][:7])}): latency from handing a clip in to its final text, after warm-up, the same way on both sides.</p>
      </div>
    </div>
  </article>
'''
    page = PAGE.read_text()
    if 'id="dictation"' in page:
        page = re.sub(r'  <article class="card" data-kind="[a-z]+" id="dictation">.*?</article>\n', block.replace("\\", "\\\\"), page, flags=re.S)
    else:
        at = page.index('id="drawing"')
        end = page.index("</article>\n", at) + len("</article>\n")
        page = page[:end] + "\n" + block + page[end:]
    PAGE.write_text(page)
    print("gallery: Dictation section written;", verdict)


if __name__ == "__main__":
    main()
