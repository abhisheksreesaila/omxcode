"""What Parakeet hears in a recording (goal 72's checker listens to the assistant's own voice): the .wav's text on stdout.

    CUDA_VISIBLE_DEVICES=1 MOJOUI_PARAKEET_DIR=<folder> pixi run -e voice python scripts/omx_hear.py reply.wav

The recording is any 16-bit PCM .wav (parec's); it is resampled to 16 kHz mono, as the app's recogniser takes it."""
import sys
import wave

import numpy as np
from scipy.signal import resample_poly


def main():
    import os

    import torch  # noqa: F401  (imported first: it brings the cuDNN that onnxruntime's CUDA provider needs)
    import onnx_asr

    with wave.open(sys.argv[1], "rb") as w:
        rate, channels, raw = w.getframerate(), w.getnchannels(), w.readframes(w.getnframes())
    pcm = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        pcm = pcm.reshape(-1, channels).mean(axis=1)
    if rate != 16000:
        pcm = resample_poly(pcm, 16000, rate).astype(np.float32)
    folder = os.environ.get("MOJOUI_PARAKEET_DIR") or None
    asr = onnx_asr.load_model("nemo-parakeet-tdt-0.6b-v3", folder, quantization="int8",
                              providers=["CUDAExecutionProvider", "CPUExecutionProvider"])
    # the recording holds silence round the speech and may hold two replies: the whole thing, in one go (Parakeet takes minutes)
    print("HEARD: " + str(asr.recognize(pcm, sample_rate=16000)).strip())


if __name__ == "__main__":
    main()
