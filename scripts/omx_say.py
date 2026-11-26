"""Speech as .wav files for a checker's microphone (goal 72): Kokoro (mojoui/voice_kokoro.py) says each text, resampled to the
16 kHz 16-bit mono that mojoui.audio's `file:` microphone source plays.

    CUDA_VISIBLE_DEVICES=1 pixi run -e voice python scripts/omx_say.py build/g72/wav "q1=What is the capital of France?" ...

Prints `name seconds` for each file. A pause before the words is added with `name@0.4=text` (seconds of silence first)."""
import sys
import wave
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "mojoui"))
from voice_kokoro import RATE, Voice  # noqa: E402


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    voice = Voice(device="cuda")
    for spec in sys.argv[2:]:
        name, text = spec.split("=", 1)
        lead = 0.0
        if "@" in name:
            name, lead = name.split("@")
            lead = float(lead)
        audio = np.concatenate([np.zeros(int(lead * RATE), dtype=np.float32)] + list(voice._synth(text)))
        pcm = resample_poly(audio, 2, 3)  # 24 kHz -> 16 kHz
        pcm16 = (np.clip(pcm, -1, 1) * 32767).astype("<i2")
        with wave.open(str(out / f"{name}.wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(pcm16.tobytes())
        print(name, round(len(pcm16) / 16000, 2), flush=True)


if __name__ == "__main__":
    main()
