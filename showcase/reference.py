"""NumPy float32 reference for showcase/SPEC.md: python showcase/reference.py N F out.bin"""
import sys
import numpy as np


def initial(n):
    s = np.uint32(42)
    out = np.empty(2 * n, np.float32)
    # xorshift32, sequential (the spec's order); vectorising would change the order
    vals = np.empty(2 * n, np.uint32)
    x = 42
    for i in range(2 * n):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        vals[i] = x
    out[:] = (vals >> 8).astype(np.float32) * np.float32(1 / 16777216)
    out = out * np.float32(2) - np.float32(1)
    return out.reshape(n, 2)


def run(n, frames):
    p = initial(n)
    v = np.zeros_like(p)
    dt = np.float32(1 / 60)
    for f in range(frames):
        t = f * float(dt)
        c = np.array([0.5 * np.cos(t), 0.5 * np.sin(t)], np.float32)
        d = c - p
        r2 = d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1] + np.float32(0.01)
        a = d * (np.float32(0.5) / r2)[:, None]
        v = v * np.float32(0.985) + a * dt
        p = p + v * dt
    return p


if __name__ == "__main__":
    n, frames, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    run(n, frames).astype("<f4").tofile(out)
