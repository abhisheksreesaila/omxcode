// Goal 43's side B: whisper-large-v3-turbo through transformers.js (WebGPU, fp16) in headless Chromium, run by
// scripts/dictate_race.py. The page reports to the script's server: ready (model loaded and warmed up, the same two
// 1 s silences side A warms up on), then one result per clip (latency = audio handed in -> final text).
import { pipeline, env } from '@huggingface/transformers';

env.allowRemoteModels = false;  // the model files come from the script's server (downloaded once; their size recorded)
env.allowLocalModels = true;
env.localModelPath = '/models/';
env.useBrowserCache = false;
env.backends.onnx.wasm.wasmPaths = '/dist/';

const q = new URLSearchParams(location.search);
const realFetch = globalThis.fetch.bind(globalThis);
const report = (o) => realFetch('/report', { method: 'POST', body: JSON.stringify(o) });
// Every fetch the library makes is logged to the script (url, status, length, or the error), so a load failure names
// the request that failed and how (goal 43 review: the fp32 encoder's "Failed to fetch").
globalThis.fetch = async (input, init) => {
  const url = String((input && input.url) || input);
  const t = performance.now();
  try {
    const r = await realFetch(input, init);
    report({ fetch: url, status: r.status, length: r.headers.get('Content-Length'), ms: performance.now() - t });
    return r;
  } catch (e) {
    report({ fetch: url, error: String(e), ms: performance.now() - t });
    throw e;
  }
};
env.fetch = globalThis.fetch;  // (the library keeps its own reference, taken when it was imported)
addEventListener('unhandledrejection', (e) => report({ log: 'unhandledrejection: ' + String(e.reason && (e.reason.stack || e.reason)) }));
addEventListener('error', (e) => report({ log: 'error: ' + String(e.message) }));
const status = (s) => { document.getElementById('status').textContent = s; };

async function wav(url) {  // 16-bit PCM mono .wav -> Float32Array (outside the timed part)
  const b = new DataView(await (await fetch(url)).arrayBuffer());
  let k = 12;
  while (k + 8 <= b.byteLength) {
    const id = String.fromCharCode(b.getUint8(k), b.getUint8(k + 1), b.getUint8(k + 2), b.getUint8(k + 3));
    const size = b.getUint32(k + 4, true);
    if (id === 'data') {
      const out = new Float32Array(size / 2);
      for (let i = 0; i < out.length; i++) out[i] = b.getInt16(k + 8 + 2 * i, true) / 32768;
      return out;
    }
    k += 8 + size + (size & 1);
  }
  throw new Error('no data chunk in ' + url);
}

async function fetchTest(files) {  // ?fetchtest=a,b: read each file as transformers.js does (one Uint8Array of its length)
  const held = [];
  for (const f of files) {
    let loaded = 0;
    try {
      const r = await realFetch('/models/' + q.get('model') + '/' + f);
      const total = +r.headers.get('Content-Length');
      const buf = new Uint8Array(total);
      const reader = r.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf.set(value, loaded);
        loaded += value.length;
      }
      held.push(buf);
      await report({ log: `fetchtest ${f}: read ${loaded} of ${total}` });
    } catch (e) {
      await report({ log: `fetchtest ${f}: ${e} after ${loaded} bytes (holding ${held.reduce((a, b) => a + b.length, 0)} bytes already)` });
    }
  }
  await report({ done: true });
}

async function main() {
  if (q.get('fetchtest')) return fetchTest(q.get('fetchtest').split(','));
  try {
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
    const info = adapter ? adapter.info : null;
    const features = adapter ? [...adapter.features].sort() : [];
    globalThis.__adapter = { vendor: info && info.vendor, architecture: info && info.architecture, description: info && info.description, features };
    const model = q.get('model');
    const dtype = { encoder_model: q.get('enc') || 'fp16', decoder_model_merged: q.get('dec') || 'fp16' };
    // chunks=N: the fp32 encoder's external data split into N files (scripts/dictate_rechunk.py; one 2.55 GB file
    // can't be one ArrayBuffer in Chromium)
    const extra = q.get('chunks') ? { use_external_data_format: { 'encoder_model.onnx': +q.get('chunks') } } : {};
    status('loading ' + model);
    const asr = await pipeline('automatic-speech-recognition', model, { device: 'webgpu', dtype, ...extra });
    const opts = { language: 'en', task: 'transcribe' };
    await asr(new Float32Array(16000), opts);
    await asr(new Float32Array(16000), opts);
    await report({ ready: performance.now(), dtype, adapter: globalThis.__adapter });
    const ids = await (await fetch('/clips/list')).json();
    const first = await wav('/clips/' + ids[0] + '.wav');
    await asr(first, opts);  // warm-up on real speech, untimed (side A does the same)
    for (const id of ids) {
      const audio = await wav('/clips/' + id + '.wav');
      status('clip ' + id);
      const t = performance.now();
      const out = await asr(audio, opts);
      const ms = performance.now() - t;
      await report({ clip: id, ms, text: out.text.trim(), seconds: audio.length / 16000 });
    }
    await report({ done: true });
    status('done');
  } catch (e) {
    await report({ error: String((e && e.stack) || e).slice(0, 1500) + ' | memory ' + JSON.stringify(performance.memory ? {used: performance.memory.usedJSHeapSize, limit: performance.memory.jsHeapSizeLimit} : null) + ' | adapter ' + JSON.stringify(globalThis.__adapter) });
  }
}
main();
