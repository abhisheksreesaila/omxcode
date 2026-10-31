"""Goal 43's audio: docs/goals/43/tone.wav and the 20 LibriSpeech clips in docs/goals/43/clips/ (16 kHz mono .wav + .txt).

Run: pixi run python scripts/dictate_data.py
The LibriSpeech test-clean archive (openslr.org/12, CC BY 4.0, 346 MB) is downloaded once into ~/.cache/mojoui/librispeech,
never into the repo. Picks the same 20 utterances every time: walking speakers in sorted order, the first utterance of
each speaker that lasts 5-15 s, until 20 (one per speaker, so 20 different voices). Needs ffmpeg (flac -> wav).
"""

import math
import struct
import subprocess
import sys
import tarfile
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "goals" / "43"
URL = "https://www.openslr.org/resources/12/test-clean.tar.gz"
CACHE = Path.home() / ".cache" / "mojoui" / "librispeech" / "test-clean.tar.gz"
RATE = 16000


def write_wav(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples))


def tone():
    """3 s that can't line up with itself by accident: a rising chirp, three bursts of different pitch, a falling chirp."""
    out = []
    phase = 0.0
    for i in range(3 * RATE):
        t = i / RATE
        if t < 1.0:
            f = 300 + 1500 * t
        elif t < 2.0:
            f = (523.0, 0.0, 784.0, 0.0, 659.0)[int((t - 1.0) * 5)]
        else:
            f = 1800 - 1400 * (t - 2.0)
        phase += 2 * math.pi * f / RATE
        env = min(1.0, t * 50, (3.0 - t) * 50)
        out.append(0.5 * env * math.sin(phase) if f else 0.0)
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    write_wav(OUT / "tone.wav", tone())
    if not CACHE.exists():
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        print("downloading", URL, "->", CACHE)
        urllib.request.urlretrieve(URL, CACHE)
    clips = OUT / "clips"
    clips.mkdir(exist_ok=True)
    texts, flacs = {}, {}
    with tarfile.open(CACHE) as tar:
        for m in tar:
            if m.name.endswith(".trans.txt"):
                for line in tar.extractfile(m).read().decode().splitlines():
                    uid, _, text = line.partition(" ")
                    texts[uid] = text
            elif m.name.endswith(".flac"):
                flacs[Path(m.name).stem] = tar.extractfile(m).read()
    picked, speakers = [], set()
    for uid in sorted(flacs):
        spk = uid.split("-")[0]
        if spk in speakers:
            continue
        pcm = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "-", "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                             input=flacs[uid], capture_output=True, check=True).stdout
        secs = len(pcm) / 2 / RATE
        if 5.0 <= secs <= 15.0:
            with wave.open(str(clips / f"{uid}.wav"), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(RATE)
                w.writeframes(pcm)
            (clips / f"{uid}.txt").write_text(texts[uid] + "\n")
            picked.append((uid, secs))
            speakers.add(spk)
        if len(picked) == 20:
            break
    for uid, secs in picked:
        print(f"{uid} {secs:.1f}s")
    print(f"{len(picked)} clips, {sum(s for _, s in picked):.0f} s in {clips}")
    return 0 if len(picked) == 20 else 1


if __name__ == "__main__":
    sys.exit(main())
