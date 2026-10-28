// The page: UI in plain JS. The frame loop (Rust/wasm step + WebGL2 draw) runs in a worker on an OffscreenCanvas,
// because rayon blocks the calling thread while its pool works, and the main thread must never block.
const canvas = document.getElementById('c');
const readout = document.getElementById('readout');
const nSelect = document.getElementById('n');
const q = new URLSearchParams(location.search);
nSelect.value = q.get('n') || '1000000';

const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
const offscreen = canvas.transferControlToOffscreen();
worker.postMessage({ type: 'init', canvas: offscreen, search: location.search }, [offscreen]);
worker.onmessage = ({ data }) => {
  if (data.type === 'stats') readout.textContent = data.text;
  else if (data.type === 'done') document.title = 'done';
  else if (data.type === 'error') { readout.textContent = data.message; console.error(data.message); }
};
worker.onerror = (e) => console.error('worker: ' + e.message);

canvas.onpointermove = (e) => {
  const r = canvas.getBoundingClientRect();
  worker.postMessage({ type: 'cursor', c: [((e.clientX - r.left) / r.width * 2 - 1) * 1.6, (1 - (e.clientY - r.top) / r.height * 2) * 0.9] });
};
canvas.onpointerleave = () => worker.postMessage({ type: 'cursor', c: null });
nSelect.onchange = () => worker.postMessage({ type: 'n', n: Number(nSelect.value) });
