"""Goal 71 M4: every scene of the cold open is there: a frame 1.5 s into each scene (the start times cold-open.md lists) is not
blank (its brightness varies) and differs from every other scene's.

    pixi run python docs/goals/71/scenes.py <film.mp4> <start s> <start s> ...
"""
import subprocess
import sys

W, H = 192, 108


def frame(path, t):
    r = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.2f}", "-i", path, "-frames:v", "1", "-vf", f"scale={W}:{H},format=gray",
                        "-f", "rawvideo", "-"], capture_output=True)
    if r.returncode or len(r.stdout) != W * H:
        sys.exit(f"no frame at {t} s: {r.stderr.decode()[-200:]}")
    return r.stdout


def main(path, starts):
    frames = [frame(path, t + 1.5) for t in starts]
    for t, f in zip(starts, frames):
        mean = sum(f) / len(f)
        sd = (sum((x - mean) ** 2 for x in f) / len(f)) ** 0.5
        if sd < 12:
            sys.exit(f"the scene at {t} s looks blank (brightness spread {sd:.1f})")
    for i in range(len(frames)):
        for j in range(i + 1, len(frames)):
            diff = sum(abs(a - b) for a, b in zip(frames[i], frames[j])) / (W * H)
            if diff < 4:
                sys.exit(f"the scenes at {starts[i]} s and {starts[j]} s look the same (mean difference {diff:.1f})")
    print(f"{len(starts)} scenes: none blank, all different")


if __name__ == "__main__":
    main(sys.argv[1], [float(x) for x in sys.argv[2:]])
