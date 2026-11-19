"""Milestone checker for GOAL.md (goal 75: silky on the GPU, Linux and Mac). Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/75-check.py [M0 M1 ...]          (default: every milestone)

Written before the work (2026-11-18), from the goal's words; never edited to make a milestone pass (add, don't weaken).
GPU timings run where the GPU is: pnote on the owner's Linux desktop (the real Wayland display, a window for a few
seconds) and on the owner's M4 Mac through scripts/mac-ssh (MAC_SSH, a window for about a minute). Each run prints a
line before it opens a window.

The app's contract (examples/pnote, beyond goal 74's):
  PNOTE_SCENE=whiteboard|canvas|mindmap   opens that judged scene as a fresh note (canvas: PNOTE_IMPORT's file, else
                                          build/g74/bench-note.json); the note's Canvas is tagged "note"
  PNOTE_GPU=0                             forces the CPU path (the baseline); default: the GPU path when the host has one
  framebench steps (both hosts): framebench:note=pan|zoom|draw|finish|grow,N; grow (mind map): one topic added each
  100 ms for N topics, then a collapse and an expand, every frame timed. Each prints
    FRAMEBENCH: <what> n=<frames> missed=<n> … renderer=<name> p50=<ms> p95=<ms> max=<ms> …
  and the app prints `PNOTE GPU: <backend or cpu> <why>` once at start.
  (added 11-18, review round 2) gpucheck:note on GTK prints `GPU2D GL CHECK: … texture= offloaded= fenced= unfenced=
  snap= inset= strip_press= strip_at= bg= scene_bg= mean= far=% ok|FAIL` (D-7575, D-7577); MOJOUI_OFFLOAD_REFUSE=1 makes
  GTK refuse every dmabuf (D-7575); framebench adds offload_fenced/offload_unfenced.
"""
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "build" / "g75"
APP = ROOT / "build" / "pnote" / "linux" / "pnote"
NOTE = ROOT / "build" / "g74" / "bench-note.json"
MAC_SSH = os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101")
P95 = 8.3
MAX = 16.7
# (added 11-18, D-7576, nothing lowered) a visible desktop run (MOJOUI_TESTSCREEN=0: the window on the owner's monitor)
# also gates the time to the screen: D-7571 drops GTK's raster from offloaded frames, honest only while the compositor's
# share (shown_*: paint end → presented) stays level with GTK's own path. Each scene then runs once more with GL
# textures (MOJOUI_OFFLOAD=0), the baseline, in the same check; the offloaded run needs shown_n = n and
#   shown_max ≤ baseline shown_max + SHOWN_MAX_SLACK (one 60 Hz refresh: no frame reaches the screen a refresh later
#                                                    than GL textures' worst frame)
#   shown_p95 ≤ baseline shown_p95 + SHOWN_P95_SLACK (a quarter refresh: the typical frame stays level; D-7572 measured
#                                                    offload 1.4–1.9 ms behind at low clocks)
# On scripts/testscreen's hidden headless output shown_* means nothing (it presents at once): printed, not gated.
VISIBLE = os.environ.get("MOJOUI_TESTSCREEN") == "0"
SHOWN_MAX_SLACK = 16.7
SHOWN_P95_SLACK = 4.2

STEPS = {
    # (D-7505: the tool keys between steps were added on 11-18 before any run: pan drags need the hand, draw the pen)
    "whiteboard": ["key:note=h", "framebench:note=pan,120", "framebench:note=zoom,60", "key:note=p", "framebench:note=draw,300", "framebench:note=finish,100"],
    "canvas": ["framebench:note=pan,120", "framebench:note=zoom,60"],
    "mindmap": ["framebench:note=pan,120", "framebench:note=zoom,60", "framebench:note=grow,20"],
}


def run(cmd, timeout=3600, env=None, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def mojo_test(path, ok_lines):
    if not (ROOT / path).exists():
        return False, f"{path} missing"
    r = run(["pixi", "run", "mojo", "run", "-I", ".", path], 1800)
    out = r.stdout + r.stderr
    missing = [l for l in ok_lines if l not in out]
    if r.returncode != 0 or missing:
        errs = " | ".join(l for l in out.splitlines() if "error" in l.lower() or "FAIL" in l)[-600:]
        return False, f"{path}: exit {r.returncode}, missing {missing} {errs}"
    return True, f"{path}: " + ", ".join(ok_lines)


def benches(out):
    """{what: {p50, p95, max, missed, n, renderer}} from FRAMEBENCH lines."""
    res = {}
    for line in out.splitlines():
        if not line.startswith("FRAMEBENCH:"):
            continue
        what = line.split()[1]
        kv = dict(re.findall(r"(\w+)=(\S+)", line))
        res[what] = kv
    return res


def gpu_line(out):
    m = re.search(r"^PNOTE GPU: (.*)$", out, re.M)
    return m.group(1) if m else "(no PNOTE GPU line)"


def build_linux():
    r = run(["scripts/build.sh", "pnote", "linux"], 3600)
    return r.returncode == 0 and APP.exists(), (r.stdout + r.stderr)[-500:]


def desktop(scene, gpu=True, offload=True, steps=None, env_extra=None, tag=""):
    """pnote on the real Wayland display (the RTX 3090), the scene's framebench steps. offload=False: GL textures
    (MOJOUI_OFFLOAD=0), the baseline for the visible run's time-to-screen gate. A GPU run ends with gpucheck:note
    (added 11-18, D-7575: the picture GTK holds, rendered by GTK's renderer as it composites it, vs gpu2d's CPU
    executor; the snap box's state). steps / env_extra / tag: another run (D-7575's forced refusal, D-7577's cases)."""
    runtime = "/run/user/%d" % os.getuid()
    socks = sorted(p.name for p in Path(runtime).glob("wayland-*") if not p.name.endswith(".lock"))
    if not socks:
        return None, "no Wayland display (the desktop isn't running)"
    print(f"(opening a pnote window on the desktop for the {scene} scene, a few seconds)", flush=True)
    data = OUT / f"desk-{scene}"
    shutil.rmtree(data, ignore_errors=True)
    env = {k: v for k, v in os.environ.items() if k != "DISPLAY"}
    env.update(WAYLAND_DISPLAY=socks[0], XDG_RUNTIME_DIR=runtime, PNOTE_DIR=str(data), PNOTE_SCENE=scene,
               PNOTE_IMPORT=str(NOTE), MOJOUI_TEST=";".join(["window:1440x900"] + (steps or STEPS[scene]) + (["gpucheck:note"] if gpu else []) + ["quit"]))
    env.update(env_extra or {})
    if not gpu:
        env["PNOTE_GPU"] = "0"
    if not offload:
        env["MOJOUI_OFFLOAD"] = "0"
    # (11-18, D-7573: on a hidden headless Hyprland output, same GPU and compositor, so no window pops up in front of the
    # owner; MOJOUI_TESTSCREEN=0 shows it on the desktop again)
    r = run([str(ROOT / "scripts" / "testscreen"), str(APP)], 900, env=env)
    out = r.stdout + r.stderr
    (OUT / f"desk-{scene}-{'gpu' if gpu else 'cpu'}{'' if offload else '-gltex'}{tag}.log").write_text(out)
    return out, ""


def mac(scene, gpu=True):
    """pnote on the owner's M4 Mac through scripts/mac-ssh; the app's stdout comes back as stdout.txt."""
    if run(["ssh", "-i", os.path.expanduser("~/.ssh/edx_mac"), "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", MAC_SSH, "true"], 60).returncode:
        return None, f"the Mac ({MAC_SSH}) isn't reachable"
    print(f"(opening a pnote window on the Mac for the {scene} scene, about a minute)", flush=True)
    steps = OUT / f"mac-{scene}.steps"
    # (added 11-18 for M3, D-7542: on the GPU path the scene ends with gpucheck, Metal vs gpu2d's CPU executor on the
    # scene as it stands, read back from an IOSurface: M1's bounds)
    steps.write_text("\n".join(["window:1440x900"] + STEPS[scene] + (["gpucheck:note"] if gpu else []) + ["quit"]) + "\n")
    env = dict(os.environ, MAC_SSH=MAC_SSH,
               MAC_ENV=",".join([f"PNOTE_SCENE={scene}", "PNOTE_IMPORT={data}/bench-note.json"] + ([] if gpu else ["PNOTE_GPU=0"])))
    r = run(["scripts/mac-ssh", "pnote", str(steps), str(NOTE)], 3600, env=env)
    lines = (r.stdout + r.stderr).strip().splitlines()
    report = Path(lines[-1]) if lines else None
    if r.returncode or not report or not (ROOT / report / "stdout.txt").exists():
        return None, f"mac-ssh exit {r.returncode}: {(r.stdout + r.stderr)[-400:]}"
    out = (ROOT / report / "stdout.txt").read_text()
    (OUT / f"mac-{scene}-{'gpu' if gpu else 'cpu'}.log").write_text(out)
    return out, ""


def step_bad(what, b, where="linux"):
    """'' when a framebench step is silky, else why not. (Added 11-18, D-7554, nothing lowered: when this was written
    the Mac's main thread waited for each frame's GPU (D-7532), so commit → GPU start and GPU end → wake-up were real
    stalls; it no longer waits (D-7555: up to two frames in flight, shown when they complete), but whatever sleeping is
    left (drains, a full ring) still lands in the wall clock. D-7541's frame work (CPU + GPU-busy) must pass AND the
    wall clock too (wall_p95 ≤ P95, wall_max ≤ MAX), and a GPU run has no frame drawn by the CPU executor
    (cpu_frames=0).)"""
    if not b or int(b.get("n", "0")) == 0:
        return f"{what}: no frames"
    p95, mx, missed = float(b["p95"]), float(b["max"]), int(b.get("missed", "0"))
    bad = []
    if p95 > P95 or mx > MAX or missed > 0:
        bad.append(f"p95 {p95} max {mx} missed {missed}")
    if where == "mac":
        if "wall_p95" not in b or "wall_max" not in b:
            bad.append("no wall_p95/wall_max")
        elif float(b["wall_p95"]) > P95 or float(b["wall_max"]) > MAX:
            bad.append(f"wall_p95 {b['wall_p95']} wall_max {b['wall_max']}")
        if b.get("renderer", "").startswith("gpu2d") and int(b.get("cpu_frames", "1")) != 0:
            bad.append(f"cpu_frames {b.get('cpu_frames')} (frames drawn off the GPU)")
    if where == "linux":  # (added 11-18, D-7564, nothing lowered: renderer= names only the last frame's path; every timed
        # frame of a GPU run must have been drawn by gpu2d-GL, as the Mac's cpu_frames=0)
        if "gpu_frames" not in b:
            bad.append("no gpu_frames")
        elif int(b["gpu_frames"]) != int(b["n"]):
            bad.append(f"gpu_frames {b['gpu_frames']} of {b['n']} (frames drawn off the GPU)")
    return f"{what} " + ", ".join(bad) if bad else ""


def shown_bad(what, b, base):
    """'' when a visible run's offloaded step reached the screen no later than the GL-texture baseline's (D-7576), else
    why not. b, base: that step's FRAMEBENCH fields from the offloaded run and the baseline run."""
    if not b:
        return f"{what}: no frames"
    if not base or "shown_max" not in base or int(base.get("shown_n", "0")) == 0:
        return f"{what}: no GL-texture baseline shown_* to compare with"
    if "shown_n" not in b or "shown_max" not in b or "shown_p95" not in b:
        return f"{what}: no shown_n/shown_p95/shown_max"
    bad = []
    if int(b["shown_n"]) != int(b["n"]):
        bad.append(f"shown_n {b['shown_n']} of {b['n']} (frames never presented)")
    lim_max = float(base["shown_max"]) + SHOWN_MAX_SLACK
    lim_p95 = float(base["shown_p95"]) + SHOWN_P95_SLACK
    if float(b["shown_max"]) > lim_max:
        bad.append(f"shown_max {b['shown_max']} > {lim_max:.1f} (GL textures' {base['shown_max']} + {SHOWN_MAX_SLACK})")
    if float(b["shown_p95"]) > lim_p95:
        bad.append(f"shown_p95 {b['shown_p95']} > {lim_p95:.1f} (GL textures' {base['shown_p95']} + {SHOWN_P95_SLACK})")
    return f"{what} " + ", ".join(bad) if bad else ""


def shown_steps(res, base, scene, steps=None):
    """'' when every timed step of the scene passes shown_bad, else what doesn't (steps: only these)."""
    bad = []
    for step in [x for x in STEPS[scene] if x.startswith("framebench:")]:
        what = step.split("=")[1].split(",")[0]
        if steps and what not in steps:
            continue
        why = shown_bad(what, res.get(what), base.get(what))
        if why:
            bad.append(why)
    return "; ".join(bad)


def shown_said(res):
    """The time to the screen per step (shown p95/max), for the PASS line."""
    return " shown " + " ".join(f"{w}:{b.get('shown_p95')}/{b.get('shown_max')}" for w, b in res.items())


_BASE = {}


def shown_gate(scene, res, steps=None):
    """(problem, note): on a visible desktop run, the time-to-screen gate against a GL-texture run of the same scene in
    this check (run once per scene, shared by M2/M4/M5); on testscreen, no gate and a note saying so (D-7576)."""
    if not VISIBLE:
        return "", shown_said(res) + " (not gated: the hidden headless output presents at once)"
    if scene not in _BASE:
        out, why = desktop(scene, offload=False)
        if out is None:
            return f"{scene}: GL-texture baseline: {why}", ""
        _BASE[scene] = benches(out)
    base = _BASE[scene]
    return shown_steps(res, base, scene, steps), shown_said(res) + " vs GL textures" + shown_said(base)


def gl_check(out):
    """The GPU2D GL CHECK line's fields ({} when there's none)."""
    m = re.search(r"^GPU2D GL CHECK: (.*)$", out, re.M)
    if not m:
        return {}
    kv = dict(re.findall(r"(\w+)=(\S+)", m.group(1)))
    kv["ok"] = m.group(1).endswith(" ok")
    kv["line"] = m.group(1)
    return kv


def gl_check_bad(c, snap=None):
    """'' when gpucheck's readback is within M1's bounds and the snap box is as it should be (D-7575, D-7577), else why
    not. snap: the state wanted (on, aside, none; None: any). When on: a press in the strip lands on the snap box (whose
    controllers forward it) and the box shows the scene's own background."""
    if not c:
        return "no GPU2D GL CHECK line"
    bad = []
    if not c["ok"] or float(c.get("mean", "999")) > 1.5 or float(c.get("far", "100%").rstrip("%")) > 0.5:
        bad.append("readback " + c["line"])
    if c.get("unfenced") != "0":
        bad.append(f"unfenced {c.get('unfenced')} (frames GTK composited without our fence)")
    if snap and c.get("snap") != snap:
        bad.append(f"snap {c.get('snap')}, wanted {snap}")
    if c.get("snap") == "on":
        if c.get("strip_press") != "snap":
            bad.append(f"a press in the strip lands on {c.get('strip_press')}, not the snap box")
        if c.get("bg") != c.get("scene_bg"):
            bad.append(f"snap box background {c.get('bg')} vs the scene's {c.get('scene_bg')}")
    if c.get("snap") == "aside" and c.get("inset") != "0.0,0.0":
        bad.append(f"stepped aside but inset {c.get('inset')}")
    return "; ".join(bad)


def offload_cases():
    """(problem, said): D-7575 and D-7577 on the desktop (added 11-18, review round 2):
    - forced refusal (MOJOUI_OFFLOAD_REFUSE=1: GTK composites every dmabuf itself): the pen's 300 moves, timed; some
      dmabuf frames refused, each handed over only after our fence (offload_fenced ≥ offload_refused, unfenced 0), every
      frame on the GPU, and GTK's own composite of the refused dmabuf matches the CPU executor;
    - see-through frames (MOJOUI_GPU2D_OPAQUE=0): the snap box steps aside (no inset);
    - no dmabuf export (MOJOUI_DMABUF=0): the snap box goes."""
    said = []
    out, why = desktop("whiteboard", steps=["key:note=p", "framebench:note=draw,300"], env_extra={"MOJOUI_OFFLOAD_REFUSE": "1"}, tag="-refuse")
    if out is None:
        return why, ""
    b = benches(out).get("draw", {})
    c = gl_check(out)
    bad = []
    if not b or int(b.get("n", "0")) != 300:
        bad.append(f"draw step: {b}")
    else:
        refused, fenced = int(b.get("offload_refused", "0")), int(b.get("offload_fenced", "-1"))
        if refused < 1:
            bad.append("no frame refused (the forced refusal didn't happen)")
        if fenced < refused or b.get("offload_unfenced") != "0":
            bad.append(f"offload_fenced {fenced} < offload_refused {refused} or offload_unfenced {b.get('offload_unfenced')}")
        if int(b.get("gpu_frames", "0")) != 300:
            bad.append(f"gpu_frames {b.get('gpu_frames')} of 300")
    why = gl_check_bad(c, "on")
    if why:
        bad.append(why)
    elif c.get("texture") != "GdkDmabufTexture" or c.get("offloaded") != "0" or c.get("fenced") != "1":
        bad.append("the checked frame wasn't a refused, fenced dmabuf: " + c["line"])
    if bad:
        return "forced refusal: " + "; ".join(bad), ""
    said.append(f"forced refusal: draw {b['p50']}/{b['p95']}/{b['max']} refused {b['offload_refused']} fenced {b['offload_fenced']} unfenced 0, "
                f"GTK's composite mean {c['mean']} far {c['far']}")
    for env_extra, want, tag in (({"MOJOUI_GPU2D_OPAQUE": "0"}, "aside", "-seethrough"), ({"MOJOUI_DMABUF": "0"}, "none", "-nodmabuf")):
        out, why = desktop("whiteboard", steps=["key:note=p", "framebench:note=draw,30"], env_extra=env_extra, tag=tag)
        if out is None:
            return why, ""
        why = gl_check_bad(gl_check(out), want)
        if why:
            return f"{list(env_extra)[0]}=0: {why}", ""
        said.append(f"{list(env_extra)[0]}=0: snap {want}")
    return "", "; ".join(said)


def silky(res, scene, where="linux"):
    """'' when every step of the scene is silky, else what isn't."""
    bad = []
    for step in [x for x in STEPS[scene] if x.startswith("framebench:")]:
        what = step.split("=")[1].split(",")[0]
        why = step_bad(what, res.get(what), where)
        if why:
            bad.append(why)
    return "; ".join(bad)


def wall(res):
    """The Mac's wall-clock p95/max per step, for the PASS line."""
    return " wall " + " ".join(f"{w}:{b.get('wall_p95')}/{b.get('wall_max')}" for w, b in res.items())


def summary(res):
    return " ".join(f"{w}:{b.get('p50')}/{b.get('p95')}/{b.get('max')}" for w, b in res.items())


def m0():
    OUT.mkdir(parents=True, exist_ok=True)
    ok, why = build_linux()
    if not ok:
        return "FAIL", "linux build: " + why
    rows = []
    probs = []
    for scene in STEPS:
        out, why = desktop(scene, gpu=False)
        if out is None:
            return "BLOCKED", why
        res = benches(out)
        want = len([x for x in STEPS[scene] if x.startswith("framebench:")])
        if len(res) != want:
            probs.append(f"desktop {scene}: {len(res)} of {want} framebench lines")
        rows.append(("Linux desktop (" + next((b.get("renderer", "?") for b in res.values()), "?") + "), today", scene, summary(res)))
        out, why = mac(scene, gpu=False)
        if out is None:
            return "BLOCKED", why
        res = benches(out)
        if len(res) != want:
            probs.append(f"mac {scene}: {len(res)} of {want} framebench lines")
        rows.append(("M4 Mac, today", scene, summary(res)))
    md = ["# Goal 75 baselines (today's renderers, before the GPU path)", "",
          f"Generated by docs/goals/75-check.py M0 on {time.strftime('%Y-%m-%d %H:%M')}. Each cell: step:p50/p95/max ms of frame work.", "",
          "| machine | scene | steps |", "|---|---|---|"] + [f"| {a} | {b} | {c} |" for a, b, c in rows]
    (ROOT / "docs" / "goals" / "75").mkdir(parents=True, exist_ok=True)
    (ROOT / "docs" / "goals" / "75" / "baseline.md").write_text("\n".join(md) + "\n")
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", "docs/goals/75/baseline.md: 3 scenes on both machines"


def m1():
    ok, why = mojo_test("tests/test_gpu2d.mojo", ["gpu2d batches: ok", "gpu2d cpu: ok"])
    return ("PASS" if ok else "FAIL"), why


def gpu_milestone(where, readback_test, ok_line):
    ok, why = mojo_test(readback_test, [ok_line]) if readback_test else (True, "")
    if not ok:
        return "FAIL", why
    said = []
    for scene in STEPS:
        out, why = desktop(scene) if where == "linux" else mac(scene)
        if out is None:
            return "BLOCKED", why
        g = gpu_line(out)
        if g.startswith("cpu") or g.startswith("(no"):
            return "FAIL", f"{scene}: not on the GPU ({g})"
        res = benches(out)
        bad = silky(res, scene, where)
        if bad:
            return "FAIL", f"{scene} ({g}): {bad}"
        check = ""
        if where == "linux":
            bad, note = shown_gate(scene, res)
            if bad:
                return "FAIL", f"{scene} time to screen: {bad}"
            c = gl_check(out)  # (added 11-18, D-7575/D-7577: GTK's composite of the picture, and the snap box)
            why = gl_check_bad(c, "on")
            if why:
                return "FAIL", f"{scene}: {why}"
            check = f" GTK readback mean {c['mean']} far {c['far']} snap inset {c['inset']}" + note
        if where == "mac":  # (the readback, M1's bounds: the app prints ok only when mean ≤ 1.5 and far ≤ 0.5 %)
            m = re.search(r"^GPU2D METAL CHECK: (.*)$", out, re.M)
            if not m or not m.group(1).endswith(" ok"):
                return "FAIL", f"{scene}: readback {m.group(1) if m else '(no GPU2D METAL CHECK line)'}"
            kv = dict(re.findall(r"(\w+)=([\d.]+)%?", m.group(1)))
            nums = [float(kv.get(k, "999")) for k in ("mean", "far", "layers_mean", "layers_far")]
            if nums[0] > 1.5 or nums[1] > 0.5 or nums[2] > 1.5 or nums[3] > 0.5:
                return "FAIL", f"{scene}: readback outside M1's bounds: {m.group(1)}"
            check = f" readback mean {nums[0]} far {nums[1]}%"
        said.append(f"{scene} {summary(res)}{wall(res) if where == 'mac' else ''}{check}")
    return "PASS", f"silky ({where}): " + "; ".join(said)


def m2():
    # (added 11-18, D-7576: the visible run's time-to-screen gate, proven on recorded lines since it can't run here)
    r = run(["pixi", "run", "python", "tests/test_75_shown_gate.py"], 300)
    if "shown gate: ok" not in r.stdout:
        return "FAIL", "tests/test_75_shown_gate.py: " + (r.stdout + r.stderr)[-300:]
    ok, why = build_linux()
    if not ok:
        return "FAIL", "linux build: " + why
    verdict, why = gpu_milestone("linux", "tests/test_gpu2d_gl.mojo", "gpu2d gl: ok")
    if verdict != "PASS":
        return verdict, why
    bad, said = offload_cases()
    if bad:
        return ("BLOCKED" if "Wayland" in bad else "FAIL"), bad
    return verdict, why + "; " + said


def m3():
    return gpu_milestone("mac", None, "")


def m4():
    ok, why = mojo_test("tests/test_mindmap.mojo", ["mindmap layout: ok", "mindmap keys: ok", "mindmap undo: ok", "mindmap motion: ok"])
    if not ok:
        return "FAIL", why
    if not (OUT / "compare.png").exists():
        return "FAIL", "no build/g75/compare.png (pnote's map beside Personal Note's)"
    said = []
    for where in ("linux", "mac"):
        out, why = desktop("mindmap") if where == "linux" else mac("mindmap")
        if out is None:
            return "BLOCKED", why
        res = benches(out)
        b = res.get("grow")
        why = step_bad("grow", b, where)
        if why:
            return "FAIL", f"{where} {why}: {b}"
        note = ""
        if where == "linux":
            bad, note = shown_gate("mindmap", res, ["grow"])
            if bad:
                return "FAIL", f"linux time to screen: {bad}"
        said.append(f"{where} grow {b['p50']}/{b['p95']}/{b['max']}" + (f" wall {b['wall_p95']}/{b['wall_max']}" if where == "mac" else note))
    return "PASS", "motion test; " + "; ".join(said) + "; compare.png"


def m5():
    said = []
    for where in ("linux", "mac"):
        out, why = desktop("whiteboard") if where == "linux" else mac("whiteboard")
        if out is None:
            return "BLOCKED", why
        res = benches(out)
        for what in ("draw", "finish"):
            b = res.get(what)
            why = step_bad(what, b, where)
            if why:
                return "FAIL", f"{where} {why}: {b}"
            said.append(f"{where} {what} {b['p50']}/{b['p95']}/{b['max']}" + (f" wall {b['wall_p95']}/{b['wall_max']}" if where == "mac" else ""))
        if where == "linux":
            bad, note = shown_gate("whiteboard", res, ["draw", "finish"])
            if bad:
                return "FAIL", f"linux time to screen: {bad}"
            said.append("linux" + note)
    return "PASS", "; ".join(said)


def m6():
    probs = []
    r = run(["pixi", "run", "python", "docs/goals/74-check.py", "M1", "M2", "M3", "M4", "M5", "M6", "M7"], 7200)
    if r.stdout.count(": PASS") < 7:
        probs.append("goal 74: " + " | ".join(l[:120] for l in r.stdout.splitlines() if "FAIL" in l or "BLOCKED" in l))
    r = run(["pixi", "run", "python", "docs/goals/40-check.py", "M0", "M1", "M2"], 3600)
    if r.stdout.count("PASS") < 3:
        probs.append("goal 40: " + r.stdout[-300:])
    r = run(["pixi", "run", "python", "scripts/components.py"], 1800)
    if "mojoui/gpu2d.mojo" not in (ROOT / "docs" / "components.md").read_text():
        probs.append("components.md doesn't list mojoui/gpu2d.mojo")
    lint = ROOT / "scripts" / "decisions_lint.py"
    if lint.exists():
        r = run(["pixi", "run", "python", str(lint)], 600)
        if r.returncode != 0:
            probs.append("decisions lint: " + (r.stdout + r.stderr)[-200:])
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", "goal 74 M1–M7, goal 40 M0–M2, matrix lists gpu2d, decisions lint"


CHECKS = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6}

if __name__ == "__main__":
    want = sys.argv[1:] or list(CHECKS)
    bad = False
    for k in want:
        try:
            verdict, why = CHECKS[k]()
        except Exception as e:
            verdict, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {verdict}  {why}", flush=True)
        bad = bad or verdict == "FAIL"
    sys.exit(1 if bad else 0)
