"""Goal 43 review: does Chromium's WebGPU on this machine offer `shader-f16` under any flag set? (D-1415)

    pixi run python scripts/webgpu_f16_probe.py        -> docs/goals/43/webgpu-f16-probe.json

Launches the repo's Chromium (headless Xvfb display, as the race) once per configuration below, opens a page that asks
navigator.gpu for adapters (high-performance, low-power, compatibility feature level, fallback) and records each one's
info, features and limits. Nothing is downloaded; each run gets a fresh profile.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

CHROME = os.environ.get("CHROME", "/usr/lib/chromium/chromium")
OUT = ROOT / "docs" / "goals" / "43" / "webgpu-f16-probe.json"
BASE = ["--ozone-platform=x11", "--disable-gpu-sandbox", "--ignore-gpu-blocklist", "--no-first-run",
        "--no-default-browser-check", "--disable-extensions", "--password-store=basic", "--window-size=400,300"]
# (name, extra flags). Chromium takes only the last --enable-features, so each set spells its whole list. On the Xvfb
# display the GPU process only starts with ANGLE on Vulkan and no Vulkan surface (first probe: every set without them
# exited "GPU process due to errors during initialization", kept as the first rows), so the variations build on goal 36's
# working set (G36); sets without ANGLE run with --headless=new, which needs no X display.
G36 = ["--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-angle=vulkan", "--disable-vulkan-surface",
       "--enable-webgpu-developer-features"]
CONFIGS = [
    ("Vulkan, no ANGLE flag (on Xvfb)", ["--enable-unsafe-webgpu", "--enable-features=Vulkan"]),
    ("defaults + unsafe WebGPU (on Xvfb)", ["--enable-unsafe-webgpu"]),
    ("G36: goal 36's set (Vulkan via ANGLE, unsafe WebGPU)", G36),
    ("G36 + dawn allow_unsafe_apis", G36 + ["--enable-dawn-features=allow_unsafe_apis"]),
    ("G36 + WebGPUExperimentalFeatures + allow_unsafe_apis",
     [f if f != "--enable-features=Vulkan" else "--enable-features=Vulkan,WebGPUExperimentalFeatures" for f in G36]
     + ["--enable-dawn-features=allow_unsafe_apis"]),
    ("G36 + vulkan_use_storage_input_output_16 on", G36 + ["--enable-dawn-features=vulkan_use_storage_input_output_16"]),
    ("G36 + vulkan_use_storage_input_output_16 off", G36 + ["--disable-dawn-features=vulkan_use_storage_input_output_16"]),
    ("G36 + --use-webgpu-adapter=default", G36 + ["--use-webgpu-adapter=default"]),
    ("G36 + --use-webgpu-adapter=swiftshader (CPU)", G36 + ["--use-webgpu-adapter=swiftshader"]),
    ("G36 + --use-webgpu-adapter=opengles (Dawn GL backend)", G36 + ["--use-webgpu-adapter=opengles"]),
    ("G36 + --use-webgpu-adapter=compat", G36 + ["--use-webgpu-adapter=compat"]),
    ("G36 + --use-vulkan=native", G36 + ["--use-vulkan=native"]),
    ("G36 + --enable-dawn-backend-validation=disabled + skip_validation", G36 + ["--enable-dawn-features=skip_validation"]),
    ("--headless=new, Vulkan, no ANGLE", ["--headless=new", "--enable-unsafe-webgpu", "--enable-features=Vulkan"]),
    ("--headless=new, Vulkan via ANGLE", ["--headless=new"] + G36),
    ("--headless=new, ANGLE on GL", ["--headless=new", "--enable-unsafe-webgpu", "--use-angle=gl"]),
    ("--headless=new, ANGLE on SwiftShader", ["--headless=new", "--enable-unsafe-webgpu", "--use-angle=swiftshader"]),
    ("--headless=new + allow_unsafe_apis + WebGPUExperimentalFeatures",
     ["--headless=new", "--enable-unsafe-webgpu", "--enable-features=Vulkan,WebGPUExperimentalFeatures",
      "--enable-dawn-features=allow_unsafe_apis"]),
]

PAGE = r"""<!doctype html><meta charset=utf-8><body><script type=module>
const out = {gpu: !!navigator.gpu, adapters: {}};
async function probe(name, opts) {
  try {
    const a = await navigator.gpu.requestAdapter(opts);
    if (!a) { out.adapters[name] = null; return; }
    const limits = {};
    for (const k in a.limits) limits[k] = a.limits[k];
    out.adapters[name] = {info: {vendor: a.info.vendor, architecture: a.info.architecture, device: a.info.device,
      description: a.info.description, backend: a.info.backend, type: a.info.type, isFallbackAdapter: a.info.isFallbackAdapter},
      features: [...a.features].sort(), shader_f16: a.features.has('shader-f16'), limits};
    if (a.features.has('shader-f16')) {
      try { const d = await a.requestDevice({requiredFeatures: ['shader-f16']}); out.adapters[name].f16_device = !!d; d.destroy(); }
      catch (e) { out.adapters[name].f16_device = String(e); }
    }
  } catch (e) { out.adapters[name] = {error: String(e)}; }
}
if (navigator.gpu) {
  await probe('high-performance', {powerPreference: 'high-performance'});
  await probe('low-power', {powerPreference: 'low-power'});
  await probe('compatibility', {featureLevel: 'compatibility'});
  await probe('fallback', {forceFallbackAdapter: true});
}
await fetch('/report', {method: 'POST', body: JSON.stringify(out)});
</script>"""


def run(flags, timeout=40):
    got = {}
    done = threading.Event()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            got.update(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            self.send_response(204)
            self.end_headers()
            done.set()

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    prof = tempfile.mkdtemp(prefix="f16-probe-")
    log = Path(prof) / "chromium.log"
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    with open(log, "w") as f:
        p = subprocess.Popen([CHROME, f"--user-data-dir={prof}", *BASE, *flags, f"--app={url}"], stdout=f, stderr=f,
                             start_new_session=True)
    ok = done.wait(timeout)
    os.killpg(p.pid, 15)
    p.wait()
    srv.shutdown()
    tail = [ln for ln in log.read_text(errors="replace").splitlines() if "ERROR" in ln or "WARNING" in ln][-6:]
    shutil.rmtree(prof, ignore_errors=True)
    return got if ok else {"error": "no report in %d s" % timeout}, tail


def main():
    headless.ensure()
    version = subprocess.run([CHROME, "--version"], capture_output=True, text=True).stdout.strip()
    driver = subprocess.run(["nvidia-smi", "--query-gpu=index,name,driver_version", "--format=csv,noheader"],
                            capture_output=True, text=True).stdout.strip().splitlines()
    results = []
    for name, flags in CONFIGS:
        got, tail = run(flags)
        adapters = got.get("adapters") or {}
        f16 = sorted(k for k, a in adapters.items() if a and a.get("shader_f16"))
        summary = {k: (None if a is None else a.get("error") or f"{a['info'].get('description') or a['info'].get('vendor')} "
                       f"({a['info'].get('backend') or '?'}), {len(a['features'])} features, shader-f16 {a['shader_f16']}")
                   for k, a in adapters.items()}
        print(f"{name}: shader-f16 on {f16 or 'none'}; {summary or got.get('error')}", flush=True)
        results.append({"config": name, "flags": BASE + flags, "shader_f16_on": f16, "summary": summary,
                        "result": got, "chromium_log_errors": tail})
        time.sleep(1)
    any_f16 = [r["config"] for r in results if r["shader_f16_on"]]
    OUT.write_text(json.dumps({"chromium": version, "gpus": driver, "when": time.strftime("%Y-%m-%d %H:%M"),
                               "any_shader_f16": any_f16, "configs": results}, indent=1) + "\n")
    print("shader-f16 offered by:", any_f16 or "no configuration")


if __name__ == "__main__":
    main()
