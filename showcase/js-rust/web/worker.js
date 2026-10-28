// The frame loop: step in Rust/wasm (SIMD128 + a rayon pool over shared memory), draw with WebGL2 on an
// OffscreenCanvas. Each frame uploads one packed u32 per particle (sim::pack) from wasm memory to the GPU.
// Scripted mode (showcase/SPEC.md): ?scripted=1&n=N&frames=F[&threads=T] posts positions.bin and timings.json.
import init, { Field, attractor, initThreadPool } from './pkg/particles_wasm.js';

const W = 1280, H = 720;
let q, scripted, gl, wasm, threads, isolated, renderer;
let field, n, packedView;
let cursor = null, frames = 0;
const totals = [], steps = [], works = [];
let frame = 0, last = 0, fps = 60, stepAvg = 0, firstFrame = 0, lastStats = 0;

const VS = `#version 300 es
layout(location=0) in uint packed;
out vec3 colour;
void main() {
  if ((packed & 0x80000000u) != 0u) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; } // outside the view
  float px = float(packed & 2047u), py = float((packed >> 11) & 1023u), s = float((packed >> 21) & 255u) / 255.0;
  gl_Position = vec4((px + 0.5) / 640.0 - 1.0, 1.0 - (py + 0.5) / 360.0, 0.0, 1.0);
  gl_PointSize = 1.0;
  colour = mix(vec3(0.231, 0.169, 0.839), vec3(1.0), s) * 0.35; // #3b2bd6 -> white, per-particle weight
}`;
const FS = `#version 300 es
precision mediump float;
in vec3 colour;
out vec4 o;
void main() { o = vec4(colour, 1.0); }`;

function setupGL(canvas) {
  gl = canvas.getContext('webgl2', { antialias: false, alpha: false, depth: false, powerPreference: 'high-performance' });
  const dbg = gl.getExtension('WEBGL_debug_renderer_info');
  renderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  const shader = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const prog = gl.createProgram();
  gl.attachShader(prog, shader(gl.VERTEX_SHADER, VS));
  gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(prog);
  gl.useProgram(prog);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE); // additive
  gl.clearColor(0, 0, 0, 1);
  gl.viewport(0, 0, W, H);
  gl.bindVertexArray(gl.createVertexArray());
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.enableVertexAttribArray(0);
  gl.vertexAttribIPointer(0, 1, gl.UNSIGNED_INT, 0, 0);
}

function setN(count) {
  if (field) field.free();
  n = count;
  field = new Field(n);
  // memory may have grown (and its buffer been replaced): take a fresh view after allocating
  packedView = new Uint32Array(wasm.memory.buffer, field.packed_ptr(), n);
  gl.bufferData(gl.ARRAY_BUFFER, 4 * n, gl.STREAM_DRAW);
}

function tick(now) {
  if (last) {
    const ms = now - last;
    totals.push(ms);
    fps = 0.9 * fps + 0.1 * (1000 / ms);
  } else {
    firstFrame = performance.now();
  }
  last = now;
  const [cx, cy] = cursor && !scripted ? cursor : attractor(frame);
  const t0 = performance.now();
  field.step(cx, cy);
  const t1 = performance.now();
  gl.bufferSubData(gl.ARRAY_BUFFER, 0, packedView);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.drawArrays(gl.POINTS, 0, n);
  const t2 = performance.now();
  steps.push(t1 - t0);
  works.push(t2 - t0);
  stepAvg = 0.9 * stepAvg + 0.1 * (t1 - t0);
  if (now - lastStats > 100) {
    lastStats = now;
    postMessage({ type: 'stats', text: `N ${n.toLocaleString()}  ·  ${fps.toFixed(0)} fps  ·  step ${stepAvg.toFixed(2)} ms  ·  ${isolated ? threads + ' threads' : '1 thread'}` });
  }
  frame++;
  if (scripted && frame === frames) {
    requestAnimationFrame((end) => { totals.push(end - last); finish(); });
    return;
  }
  requestAnimationFrame(tick);
}

async function finish() {
  const positions = new Float32Array(new Float32Array(wasm.memory.buffer, field.pos_ptr(), 2 * n)); // copy out of shared memory
  const timings = {
    row: 'B-wasm', n, frames, threads: isolated ? threads : 1, crossOriginIsolated: isolated, renderer, simd: true,
    first_frame_ms: firstFrame, first_frame_epoch_ms: performance.timeOrigin + firstFrame,
    step_is: 'wasm step + pack for draw (wall time, all threads)', total: totals, step: steps, work: works,
  };
  // in 8 MB pieces: a driver watching the network (DevTools) copies every request body
  const bytes = new Uint8Array(positions.buffer), CH = 8 << 20;
  for (let off = 0; off < bytes.length || off === 0; off += CH) {
    await fetch(`/result/positions.bin?offset=${off}`, { method: 'POST', body: bytes.subarray(off, off + CH) });
    if (bytes.length === 0) break;
  }
  await fetch('/result/timings.json', { method: 'POST', body: JSON.stringify(timings) });
  postMessage({ type: 'done' });
}

onmessage = async ({ data }) => {
  try {
    if (data.type === 'init') {
      q = new URLSearchParams(data.search);
      scripted = q.has('scripted');
      frames = Number(q.get('frames') || 0);
      wasm = await init();
      threads = Number(q.get('threads') || navigator.hardwareConcurrency || 4);
      isolated = self.crossOriginIsolated;
      if (isolated) await initThreadPool(threads);
      setupGL(data.canvas);
      setN(Number(q.get('n') || 1000000));
      requestAnimationFrame(tick);
    } else if (data.type === 'cursor') cursor = data.c;
    else if (data.type === 'n') setN(data.n);
  } catch (e) {
    postMessage({ type: 'error', message: String(e && e.stack || e) });
  }
};
