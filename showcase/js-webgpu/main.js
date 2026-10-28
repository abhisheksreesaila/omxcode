// Particle field, build A: plain JS + WebGPU (showcase/SPEC.md).
// One storage buffer of vec4f (pos.xy, vel.zw); a compute pass steps it (step.wgsl); a second compute pass adds
// every on-screen particle to its pixel with atomics (splat.wgsl); a fullscreen pass tone-maps that onto the
// canvas (toneb.wgsl). ?render=points swaps the splat for a point-list draw with additive blending into a
// float16 target (draw.wgsl + tone.wgsl): same image, about half the speed at 20M on an RTX 3090.
// Nothing per particle crosses to JS after the initial upload.
//
// URL params: ?scripted=1&n=N&frames=F (scripted measurement run, results POSTed to serve.py)
//             &mode=cpu (plain-JS CPU baseline, cpu.js)  &wg=256 (workgroup size)  &positions=0 (skip the positions upload)  &gain= &exposure= (look)

const SIZES = [1e6, 2e6, 5e6, 10e6, 20e6];
const W = 1280, H = 720;
const DT = Math.fround(1 / 60);
const ACC_FORMAT = 'rgba16float';

const q = new URLSearchParams(location.search);
const SCRIPTED = q.get('scripted') === '1';
let WG = parseInt(q.get('wg') || '256', 10);
// 'atomic' (compute rasteriser, the default: ~2x faster than hardware points at 20M) or 'points' (point-list + blending)
const RENDER = q.get('render') || 'atomic';
const EXPOSURE = parseFloat(q.get('exposure') || '1.0');
// &await=0: don't wait for the GPU each scripted frame (total_ms is then CPU encode+submit only; use raf_interval_ms)
const AWAIT = q.get('await') !== '0';
const GAIN = parseFloat(q.get('gain') || '0.08'); // light per particle at 1M
const $ = (id) => document.getElementById(id);
const fmtN = (n) => (n >= 1e6 ? `${n / 1e6}M` : n >= 1e3 ? `${n / 1e3}k` : `${n}`);

async function post(path, body, type = 'application/octet-stream') {
  await fetch(path, { method: 'POST', body, headers: { 'Content-Type': type } });
}

function fail(msg) {
  const d = document.createElement('div');
  d.className = 'err';
  d.textContent = msg;
  document.body.append(d);
  if (SCRIPTED) post('/result/error.txt', msg, 'text/plain').then(() => post('/done', '{}'));
  throw new Error(msg);
}

// Seeded initial state (SPEC "State"): xorshift32, seed 42, one call per number, x then y.
function fillInitial(f32, n) {
  let s = 42;
  const k = 1 / 16777216;
  for (let i = 0, j = 0; i < n; i++, j += 4) {
    s ^= s << 13; s ^= s >>> 17; s ^= s << 5;
    f32[j] = ((s >>> 8) * k) * 2 - 1;
    s ^= s << 13; s ^= s >>> 17; s ^= s << 5;
    f32[j + 1] = ((s >>> 8) * k) * 2 - 1;
    // velocity: the mapped buffer is zero-filled already
  }
}

async function main() {
  const t0 = performance.now();
  if (!navigator.gpu) fail('WebGPU is not available in this browser.');
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
  if (!adapter) fail('No WebGPU adapter.');
  const info = adapter.info || {};
  const adapterName = [info.vendor, info.architecture, info.description].filter(Boolean).join(' ') || 'unknown';
  const hasTS = adapter.features.has('timestamp-query');
  const device = await adapter.requestDevice({
    requiredFeatures: hasTS ? ['timestamp-query'] : [],
    requiredLimits: {
      maxBufferSize: adapter.limits.maxBufferSize,
      maxStorageBufferBindingSize: adapter.limits.maxStorageBufferBindingSize,
      maxComputeInvocationsPerWorkgroup: adapter.limits.maxComputeInvocationsPerWorkgroup,
      maxComputeWorkgroupSizeX: adapter.limits.maxComputeWorkgroupSizeX,
    },
  });
  WG = Math.min(WG, device.limits.maxComputeInvocationsPerWorkgroup, device.limits.maxComputeWorkgroupSizeX);
  device.lost.then((e) => console.error('device lost', e.message));
  device.addEventListener('uncapturederror', (e) => {
    console.error('WebGPU error:', e.error.message);
    if (SCRIPTED) fail('WebGPU error: ' + e.error.message);
  });

  const canvas = $('c');
  const ctx = canvas.getContext('webgpu');
  const canvasFormat = navigator.gpu.getPreferredCanvasFormat();
  ctx.configure({ device, format: canvasFormat, alphaMode: 'opaque' });

  const [stepSrc, drawSrc, toneSrc, splatSrc, tonebSrc] = await Promise.all(
    ['step.wgsl', 'draw.wgsl', 'tone.wgsl', 'splat.wgsl', 'toneb.wgsl'].map((f) => fetch(f).then((r) => r.text())));

  // --- pipelines -------------------------------------------------------------------------------------------
  const stepPipe = device.createComputePipeline({
    layout: 'auto',
    compute: { module: device.createShaderModule({ code: stepSrc }), entryPoint: 'main', constants: { WG } },
  });
  const drawModule = device.createShaderModule({ code: drawSrc });
  const drawPipe = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module: drawModule, entryPoint: 'vs' },
    fragment: {
      module: drawModule, entryPoint: 'fs',
      targets: [{
        format: ACC_FORMAT,
        blend: { color: { srcFactor: 'one', dstFactor: 'one' }, alpha: { srcFactor: 'one', dstFactor: 'one' } },
      }],
    },
    primitive: { topology: 'point-list' },
  });
  const toneModule = device.createShaderModule({ code: toneSrc });
  const tonePipe = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module: toneModule, entryPoint: 'vs' },
    fragment: { module: toneModule, entryPoint: 'fs', targets: [{ format: canvasFormat }], constants: { EXPOSURE } },
    primitive: { topology: 'triangle-list' },
  });

  const acc = device.createTexture({ size: [W, H], format: ACC_FORMAT,
    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING });
  const accView = acc.createView();
  const toneBG = device.createBindGroup({ layout: tonePipe.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: accView }] });

  // compute-rasteriser variant: per-pixel count + speed sum, cleared every frame
  const atomicBuf = device.createBuffer({ size: W * H * 8, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
  const splatPipe = device.createComputePipeline({
    layout: 'auto',
    compute: { module: device.createShaderModule({ code: splatSrc }), entryPoint: 'main', constants: { WG } },
  });
  const tonebModule = device.createShaderModule({ code: tonebSrc });
  const tonebPipe = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module: tonebModule, entryPoint: 'vs' },
    fragment: { module: tonebModule, entryPoint: 'fs', targets: [{ format: canvasFormat }], constants: { EXPOSURE } },
    primitive: { topology: 'triangle-list' },
  });

  const params = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const drawParams = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const paramData = new ArrayBuffer(32);
  const pf = new Float32Array(paramData), pu = new Uint32Array(paramData);

  // --- particle state (rebuilt when N changes) -----------------------------------------------------------------
  let splatBG = null, tonebBG = null, gain = 0, saturated = 0;
  let N = 0, state = null, stepBG = null, drawBG = null, dispatch = [1, 1], rowStride = 0;
  function setN(n) {
    if (state) state.destroy();
    N = n;
    state = device.createBuffer({ size: N * 16, mappedAtCreation: true,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
    fillInitial(new Float32Array(state.getMappedRange()), N);
    state.unmap();
    const groups = Math.ceil(N / WG);
    const gx = Math.min(groups, device.limits.maxComputeWorkgroupsPerDimension);
    dispatch = [gx, Math.ceil(groups / gx)];
    rowStride = gx * WG;
    stepBG = device.createBindGroup({ layout: stepPipe.getBindGroupLayout(0), entries: [
      { binding: 0, resource: { buffer: params } }, { binding: 1, resource: { buffer: state } }] });
    drawBG = device.createBindGroup({ layout: drawPipe.getBindGroupLayout(0), entries: [
      { binding: 0, resource: { buffer: state } }, { binding: 1, resource: { buffer: drawParams } }] });
    splatBG = device.createBindGroup({ layout: splatPipe.getBindGroupLayout(0), entries: [
      { binding: 0, resource: { buffer: state } }, { binding: 1, resource: { buffer: atomicBuf } },
      { binding: 2, resource: { buffer: params } }] });
    tonebBG = device.createBindGroup({ layout: tonebPipe.getBindGroupLayout(0), entries: [
      { binding: 0, resource: { buffer: atomicBuf } }, { binding: 1, resource: { buffer: drawParams } }] });
    gain = GAIN * Math.min(1, Math.pow(1e6 / N, 0.8)); // more particles: a little brighter, not a white sheet
    device.queue.writeBuffer(drawParams, 0, new Float32Array([gain, 0, 0, 0]));
    // count at which the dimmest channel (green of #3b2bd6) is past 1 - exp(-8): adding more changes nothing
    saturated = Math.ceil(8 / (gain * EXPOSURE * 0.1686));
    $('n').textContent = fmtN(N);
  }

  // --- one frame ---------------------------------------------------------------------------------------------
  // ts: optional {set, base}: four timestamps (step begin/end, draw begin/end) at set[base..base+3]
  function encodeFrame(c, doStep, ts) {
    pf[0] = c[0]; pf[1] = c[1]; pf[2] = DT; pu[3] = N; pu[4] = rowStride; pu[5] = saturated;
    device.queue.writeBuffer(params, 0, paramData);
    const enc = device.createCommandEncoder();
    if (doStep) {
      const cp = enc.beginComputePass(ts ? { timestampWrites: { querySet: ts.set,
        beginningOfPassWriteIndex: ts.base, endOfPassWriteIndex: ts.base + 1 } } : undefined);
      cp.setPipeline(stepPipe);
      cp.setBindGroup(0, stepBG);
      cp.dispatchWorkgroups(dispatch[0], dispatch[1]);
      cp.end();
    }
    if (RENDER === 'atomic') {
      enc.clearBuffer(atomicBuf);
      const sp = enc.beginComputePass(ts ? { timestampWrites: { querySet: ts.set, beginningOfPassWriteIndex: ts.base + 2 } } : undefined);
      sp.setPipeline(splatPipe);
      sp.setBindGroup(0, splatBG);
      sp.dispatchWorkgroups(dispatch[0], dispatch[1]);
      sp.end();
      const tp = enc.beginRenderPass({
        colorAttachments: [{ view: ctx.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store',
          clearValue: [0, 0, 0, 1] }],
        timestampWrites: ts ? { querySet: ts.set, endOfPassWriteIndex: ts.base + 3 } : undefined,
      });
      tp.setPipeline(tonebPipe);
      tp.setBindGroup(0, tonebBG);
      tp.draw(3);
      tp.end();
      return enc;
    }
    const rp = enc.beginRenderPass({
      colorAttachments: [{ view: accView, loadOp: 'clear', storeOp: 'store', clearValue: [0, 0, 0, 0] }],
      timestampWrites: ts ? { querySet: ts.set, beginningOfPassWriteIndex: ts.base + 2 } : undefined,
    });
    rp.setPipeline(drawPipe);
    rp.setBindGroup(0, drawBG);
    rp.draw(N);
    rp.end();
    const tp = enc.beginRenderPass({
      colorAttachments: [{ view: ctx.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store',
        clearValue: [0, 0, 0, 1] }],
      timestampWrites: ts ? { querySet: ts.set, endOfPassWriteIndex: ts.base + 3 } : undefined,
    });
    tp.setPipeline(tonePipe);
    tp.setBindGroup(0, toneBG);
    tp.draw(3);
    tp.end();
    return enc;
  }

  const attractorPath = (f) => { const t = f * DT; return [Math.cos(t) * 0.5, Math.sin(t) * 0.5]; };
  const nextFrame = () => new Promise((r) => requestAnimationFrame(r));

  // readout: fps over half-second windows, step ms from GPU timestamps
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

  if (SCRIPTED) await scripted(); else interactive();

  // --- interactive -------------------------------------------------------------------------------------------
  function interactive() {
    const slider = $('slider');
    setN(SIZES[+slider.value]);
    slider.addEventListener('input', () => setN(SIZES[+slider.value]));
    let cursor = null;
    const toWorld = (e) => {
      const r = canvas.getBoundingClientRect();
      return [((e.clientX - r.left) / r.width * 2 - 1) * 1.6, (1 - (e.clientY - r.top) / r.height * 2) * 0.9];
    };
    canvas.addEventListener('pointermove', (e) => { cursor = toWorld(e); });
    canvas.addEventListener('pointerdown', (e) => { cursor = toWorld(e); });
    canvas.addEventListener('pointerleave', () => { cursor = null; });

    // a small pool of timestamp readbacks, so the readout never stalls the GPU
    const pool = hasTS && q.get('ts') !== '0' ? Array.from({ length: 3 }, () => ({
      set: device.createQuerySet({ type: 'timestamp', count: 4 }),
      resolve: device.createBuffer({ size: 32, usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC }),
      read: device.createBuffer({ size: 32, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST }),
      busy: false,
    })) : [];
    let frame = 0;
    const loop = () => {
      const c = cursor || attractorPath(frame);
      const slot = pool.find((p) => !p.busy);
      const enc = encodeFrame(c, true, slot ? { set: slot.set, base: 0 } : null);
      if (slot) {
        enc.resolveQuerySet(slot.set, 0, 4, slot.resolve, 0);
        enc.copyBufferToBuffer(slot.resolve, 0, slot.read, 0, 32);
        slot.busy = true;
      }
      device.queue.submit([enc.finish()]);
      if (slot) {
        slot.read.mapAsync(GPUMapMode.READ).then(() => {
          const t = new BigInt64Array(slot.read.getMappedRange());
          const ms = Number(t[1] - t[0]) / 1e6;
          slot.read.unmap();
          slot.busy = false;
          if (ms > 0) stepEma = stepEma == null ? ms : stepEma * 0.9 + ms * 0.1;
        });
      }
      frame++;
      tickReadout();
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  }

  // --- scripted ------------------------------------------------------------------------------------------------
  async function scripted() {
    const n = parseInt(q.get('n') || '1000000', 10);
    $('slider').value = Math.max(0, SIZES.indexOf(n));
    $('slider').disabled = true;
    const F = parseInt(q.get('frames') || '120', 10);
    const tInit = performance.now();
    setN(n);
    // one timestamp set per 1024 frames (4 stamps a frame, 4096 per set)
    const PER = 1024;
    const sets = hasTS ? Array.from({ length: Math.ceil(F / PER) }, () =>
      device.createQuerySet({ type: 'timestamp', count: 4 * PER })) : [];
    const total = new Array(F), interval = new Array(F), cpu = new Array(F);
    let firstFrameMs = null, prevRaf = null;
    for (let f = 0; f < F; f++) {
      const raf = await nextFrame();
      interval[f] = prevRaf == null ? null : raf - prevRaf;
      prevRaf = raf;
      const a = performance.now();
      const ts = hasTS ? { set: sets[Math.floor(f / PER)], base: (f % PER) * 4 } : null;
      device.queue.submit([encodeFrame(attractorPath(f), true, ts).finish()]);
      cpu[f] = performance.now() - a;
      if (AWAIT) await device.queue.onSubmittedWorkDone();
      total[f] = performance.now() - a;
      if (f === 0) {
        firstFrameMs = performance.now();
        post('/event/first_frame', JSON.stringify({ page_ms: firstFrameMs }), 'application/json');
      }
      tickReadout();
    }
    let step = null, draw = null, gpu = null;
    if (hasTS) {
      step = new Array(F); draw = new Array(F); gpu = new Array(F);
      for (let s = 0; s < sets.length; s++) {
        const count = Math.min(PER, F - s * PER) * 4;
        const resolve = device.createBuffer({ size: count * 8, usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC });
        const read = device.createBuffer({ size: count * 8, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
        const enc = device.createCommandEncoder();
        enc.resolveQuerySet(sets[s], 0, count, resolve, 0);
        enc.copyBufferToBuffer(resolve, 0, read, 0, count * 8);
        device.queue.submit([enc.finish()]);
        await read.mapAsync(GPUMapMode.READ);
        const t = new BigInt64Array(read.getMappedRange());
        for (let k = 0; k < count / 4; k++) {
          const f = s * PER + k;
          step[f] = Number(t[4 * k + 1] - t[4 * k]) / 1e6;
          draw[f] = Number(t[4 * k + 3] - t[4 * k + 2]) / 1e6;
          gpu[f] = Number(t[4 * k + 3] - t[4 * k]) / 1e6;
        }
        read.unmap();
      }
    }
    if (step) { stepEma = [...step].sort((a, b) => a - b)[step.length >> 1]; $('step').textContent = stepEma.toFixed(2); }
    const timings = {
      build: 'js-webgpu', adapter: adapterName, n, frames: F, workgroup: WG, render: RENDER,
      timestamps: hasTS ? 'gpu timestamp-query' : 'none',
      total_ms: total, cpu_encode_ms: cpu, gpu_frame_ms: gpu, step_ms: step, draw_ms: draw, raf_interval_ms: interval,
      init_ms: firstFrameMs - tInit, // seed + upload + first frame
      page_first_frame_ms: firstFrameMs, // since navigation start
      setup_ms: tInit - t0,
      js_heap_mb: performance.memory ? performance.memory.usedJSHeapSize / 2 ** 20 : null,
    };
    if (q.get('positions') !== '0') {
      const read = device.createBuffer({ size: N * 16, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
      const enc = device.createCommandEncoder();
      enc.copyBufferToBuffer(state, 0, read, 0, N * 16);
      device.queue.submit([enc.finish()]);
      await read.mapAsync(GPUMapMode.READ);
      const all = new Float32Array(read.getMappedRange());
      const pos = new Float32Array(2 * N);
      for (let i = 0, j = 0; i < N; i++, j += 4) { pos[2 * i] = all[j]; pos[2 * i + 1] = all[j + 1]; }
      read.unmap();
      read.destroy();
      await post('/result/positions.bin', pos.buffer);
    }
    await post('/result/timings.json', JSON.stringify(timings), 'application/json');
    await post('/done', '{}', 'application/json');
    // keep showing the last frame (for screenshots); no more steps
    const hold = () => { device.queue.submit([encodeFrame(attractorPath(F - 1), false, null).finish()]); requestAnimationFrame(hold); };
    requestAnimationFrame(hold);
  }
}

const start = q.get('mode') === 'cpu' ? () => import('./cpu.js').then((m) => m.runCpu()) : main; // ?mode=cpu: the plain-JS row
start().catch((e) => { console.error(e); if (SCRIPTED) post('/result/error.txt', String(e.stack || e), 'text/plain').then(() => post('/done', '{}')); });
