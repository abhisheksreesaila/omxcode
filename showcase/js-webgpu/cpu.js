// Particle field, CPU baseline (?mode=cpu): the same SPEC simulation in plain JavaScript on the main thread.
// No WebGPU, no wasm, no workers: typed arrays (structure of arrays), one tight loop for the step, Canvas2D
// ImageData for the draw. This is the "JS alone" row.
//
// URL params: as main.js (?scripted=1&n=N&frames=F&positions=0&gain=&exposure=).

const SIZES = [1e5, 1e6, 2e6, 5e6, 10e6, 20e6];
const W = 1280, H = 720;
const DT = Math.fround(1 / 60);
const SLOW = [0x3b / 255, 0x2b / 255, 0xd6 / 255];

const q = new URLSearchParams(location.search);
const SCRIPTED = q.get('scripted') === '1';
const EXPOSURE = parseFloat(q.get('exposure') || '1.0');
const GAIN = parseFloat(q.get('gain') || '0.08');
const $ = (id) => document.getElementById(id);
const fmtN = (n) => (n >= 1e6 ? `${n / 1e6}M` : n >= 1e3 ? `${n / 1e3}k` : `${n}`);
const post = (path, body, type = 'application/octet-stream') =>
  fetch(path, { method: 'POST', body, headers: { 'Content-Type': type } });

let N = 0, px, py, vx, vy, gain = 0;
const count = new Float32Array(W * H), ksum = new Float32Array(W * H);
const canvas = $('c');
const ctx = canvas.getContext('2d', { alpha: false });
const img = ctx.createImageData(W, H);
const pix = new Uint32Array(img.data.buffer); // RGBA bytes, little-endian: 0xAABBGGRR

function setN(n) {
  N = n;
  px = new Float32Array(N); py = new Float32Array(N); vx = new Float32Array(N); vy = new Float32Array(N);
  let s = 42;
  const k = 1 / 16777216;
  for (let i = 0; i < N; i++) {
    s ^= s << 13; s ^= s >>> 17; s ^= s << 5;
    px[i] = ((s >>> 8) * k) * 2 - 1;
    s ^= s << 13; s ^= s >>> 17; s ^= s << 5;
    py[i] = ((s >>> 8) * k) * 2 - 1;
  }
  gain = GAIN * Math.min(1, Math.pow(1e6 / N, 0.8));
  $('n').textContent = fmtN(N);
}

function step(cx, cy) {
  const n = N, dt = DT;
  for (let i = 0; i < n; i++) {
    const dx = cx - px[i], dy = cy - py[i];
    const s = 0.5 / (dx * dx + dy * dy + 0.01);
    const nvx = vx[i] * 0.985 + dx * s * dt;
    const nvy = vy[i] * 0.985 + dy * s * dt;
    vx[i] = nvx; vy[i] = nvy;
    px[i] += nvx * dt; py[i] += nvy * dt;
  }
}

// Additive draw: colour is a linear blend of indigo and white by speed, so per pixel a count and a speed sum
// give the exact additive sum; then the same per-channel exponential tone map as the GPU build.
function draw() {
  count.fill(0); ksum.fill(0);
  const n = N, sx = W / 3.2, sy = H / 1.8;
  for (let i = 0; i < n; i++) {
    const fx = (px[i] + 1.6) * sx, fy = (0.9 - py[i]) * sy;
    if (fx < 0 || fy < 0 || fx >= W || fy >= H) continue;
    const p = (fy | 0) * W + (fx | 0);
    count[p] += 1;
    const k = Math.sqrt(vx[i] * vx[i] + vy[i] * vy[i]) / 1.5;
    ksum[p] += k < 1 ? k : 1;
  }
  const e = gain * EXPOSURE, r0 = SLOW[0], g0 = SLOW[1], b0 = SLOW[2];
  pix.fill(0xff000000);
  for (let p = 0; p < W * H; p++) {
    const c = count[p];
    if (c === 0) continue;
    const kk = ksum[p];
    const r = 255 * (1 - Math.exp(-e * (r0 * c + (1 - r0) * kk)));
    const g = 255 * (1 - Math.exp(-e * (g0 * c + (1 - g0) * kk)));
    const b = 255 * (1 - Math.exp(-e * (b0 * c + (1 - b0) * kk)));
    pix[p] = 0xff000000 | (b << 16) | (g << 8) | (r | 0);
  }
  ctx.putImageData(img, 0, 0);
}

const attractorPath = (f) => { const t = f * DT; return [Math.cos(t) * 0.5, Math.sin(t) * 0.5]; };
const nextFrame = () => new Promise((r) => requestAnimationFrame(r));
let fpsFrames = 0, fpsT = performance.now(), stepEma = null;
function tickReadout() {
  fpsFrames++;
  const now = performance.now();
  if (now - fpsT >= 500) {
    $('fps').textContent = Math.round(fpsFrames * 1000 / (now - fpsT));
    fpsFrames = 0; fpsT = now;
    if (stepEma != null) $('step').textContent = stepEma.toFixed(2);
  }
}

function interactive() {
  const slider = $('slider');
  slider.max = SIZES.length - 1;
  slider.value = 1;
  setN(SIZES[1]);
  slider.addEventListener('input', () => setN(SIZES[+slider.value]));
  let cursor = null;
  const toWorld = (e) => {
    const r = canvas.getBoundingClientRect();
    return [((e.clientX - r.left) / r.width * 2 - 1) * 1.6, (1 - (e.clientY - r.top) / r.height * 2) * 0.9];
  };
  canvas.addEventListener('pointermove', (e) => { cursor = toWorld(e); });
  canvas.addEventListener('pointerdown', (e) => { cursor = toWorld(e); });
  canvas.addEventListener('pointerleave', () => { cursor = null; });
  let frame = 0;
  const loop = () => {
    const c = cursor || attractorPath(frame++);
    const a = performance.now();
    step(c[0], c[1]);
    const ms = performance.now() - a;
    stepEma = stepEma == null ? ms : stepEma * 0.9 + ms * 0.1;
    draw();
    tickReadout();
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);
}

async function scripted(t0) {
  const n = parseInt(q.get('n') || '1000000', 10);
  const F = parseInt(q.get('frames') || '120', 10);
  const slider = $('slider');
  slider.max = SIZES.length - 1;
  slider.value = Math.max(0, SIZES.indexOf(n));
  slider.disabled = true;
  const tInit = performance.now();
  setN(n);
  const total = new Array(F), stepMs = new Array(F), drawMs = new Array(F), interval = new Array(F);
  let firstFrameMs = null, prevRaf = null;
  for (let f = 0; f < F; f++) {
    const raf = await nextFrame();
    interval[f] = prevRaf == null ? null : raf - prevRaf;
    prevRaf = raf;
    const a = performance.now();
    const c = attractorPath(f);
    step(c[0], c[1]);
    const b = performance.now();
    draw();
    const d = performance.now();
    stepMs[f] = b - a; drawMs[f] = d - b; total[f] = d - a;
    stepEma = stepMs[f];
    if (f === 0) {
      firstFrameMs = performance.now();
      post('/event/first_frame', JSON.stringify({ page_ms: firstFrameMs }), 'application/json');
    }
    tickReadout();
  }
  const timings = {
    build: 'js-cpu', adapter: 'cpu (plain JS, main thread)', n, frames: F,
    timestamps: 'performance.now (step = the JS loop; draw = splat + tone map + putImageData)',
    total_ms: total, cpu_encode_ms: null, gpu_frame_ms: null, step_ms: stepMs, draw_ms: drawMs,
    raf_interval_ms: interval, init_ms: firstFrameMs - tInit, page_first_frame_ms: firstFrameMs,
    setup_ms: tInit - t0, js_heap_mb: performance.memory ? performance.memory.usedJSHeapSize / 2 ** 20 : null,
  };
  if (q.get('positions') !== '0') {
    const pos = new Float32Array(2 * N);
    for (let i = 0; i < N; i++) { pos[2 * i] = px[i]; pos[2 * i + 1] = py[i]; }
    await post('/result/positions.bin', pos.buffer);
  }
  await post('/result/timings.json', JSON.stringify(timings), 'application/json');
  await post('/done', '{}', 'application/json');
}

export async function runCpu() {
  const t0 = performance.now();
  document.title = 'Particle field · plain JS (CPU)';
  if (SCRIPTED) await scripted(t0); else interactive();
}
