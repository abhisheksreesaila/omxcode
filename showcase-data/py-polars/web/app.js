// Build B's page: plain JS. Every control change asks the API for the new numbers and redraws.
// Scripted mode (?scripted=1&steps=S): applies steps.json's changes through the same controls, timing each one from
// the change to the frame after the new numbers are drawn, then posts answers.json and timings.json to the server.
"use strict";

const $ = (id) => document.getElementById(id);
const el = { from: $("from"), to: $("to"), min: $("min"), minOut: $("min-out"), region: $("region"),
  rows: $("k-rows"), sum: $("k-sum"), margin: $("k-margin"), time: $("k-time"), chart: $("chart"), tbody: $("rows") };
const intFmt = new Intl.NumberFormat("en-US");
const moneyFmt = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 });
const centsFmt = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const pctFmt = new Intl.NumberFormat("en-US", { style: "percent", minimumFractionDigits: 2, maximumFractionDigits: 2 });
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// Resolves after the browser has painted the frame that follows the current DOM changes.
const afterPaint = () => new Promise((resolve) => requestAnimationFrame(() => {
  const ch = new MessageChannel();
  ch.port1.onmessage = () => resolve(performance.now());
  ch.port2.postMessage(0);
}));

function state() {
  return { from: el.from.value, to: el.to.value, min_amount: Number(el.min.value), region: el.region.value };
}

let inflight = null;   // the AbortController of the request in flight; a newer change cancels it
let last = null;       // the last result drawn, with its timings
let current = null;    // the promise of the refresh the latest change started (scripted mode awaits it)
let meta = null;
const onChange = () => { current = refresh(); };

async function refresh(t0 = performance.now()) {
  if (inflight) inflight.abort();
  const ctl = (inflight = new AbortController());
  const s = state();
  const q = new URLSearchParams({ day_from: s.from, day_to: s.to, min_amount: s.min_amount, region: s.region });
  const tFetch = performance.now();
  let res, data;
  try {
    res = await fetch(`/api/query?${q}`, { signal: ctl.signal, cache: "no-store" });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    data = await res.json();
  } catch (e) {
    if (e.name === "AbortError") return null;
    throw e;
  }
  const tData = performance.now();
  const compute = Number(res.headers.get("X-Compute-Ms"));
  draw(data);
  const tDrawn = performance.now();
  inflight = null;
  const tPixels = await afterPaint();
  el.time.textContent = `${compute.toFixed(1)} ms · ${(tPixels - t0).toFixed(0)} ms`;
  last = { state: s, data, t: { input_to_pixels_ms: tPixels - t0, server_compute_ms: compute,
    fetch_ms: tData - tFetch, draw_ms: tDrawn - tData, paint_wait_ms: tPixels - tDrawn }, tPixels };
  return last;
}

function draw(d) {
  el.rows.textContent = intFmt.format(d.rows);
  el.sum.textContent = moneyFmt.format(d.sum_amount);
  el.margin.textContent = d.avg_margin === null ? "–" : pctFmt.format(d.avg_margin);
  drawChart(d.top);
  drawTable(d.table);
}

function drawChart(top) {
  const svg = el.chart, w = svg.clientWidth, h = svg.clientHeight;
  if (!top.length) {
    svg.innerHTML = `<text x="${w / 2}" y="${h / 2}" text-anchor="middle" class="v">Nothing matches</text>`;
    return;
  }
  const label = 104, valueW = 56, rowH = h / 20, barH = Math.max(4, rowH * 0.62), max = top[0][1];
  const span = Math.max(10, w - label - valueW);
  let out = "";
  top.forEach(([name, sum], i) => {
    const y = i * rowH, bw = Math.max(1, (sum / max) * span);
    out += `<text x="${label - 8}" y="${y + rowH / 2}" dy=".35em" text-anchor="end">${esc(name)}</text>` +
      `<rect x="${label}" y="${y + (rowH - barH) / 2}" width="${bw}" height="${barH}" rx="3"/>` +
      `<text class="v" x="${label + bw + 6}" y="${y + rowH / 2}" dy=".35em">${moneyFmt.format(sum)}</text>`;
  });
  svg.innerHTML = out;
}

function drawTable(t) {
  if (!t.rows.length) {
    el.tbody.innerHTML = `<tr><td colspan="7" class="empty">No orders match</td></tr>`;
    return;
  }
  el.tbody.innerHTML = t.rows.map(([id, day, region, product, amount, cost, paid]) =>
    `<tr><td>${id}</td><td>${day}</td><td>${esc(region)}</td><td>${esc(product)}</td>` +
    `<td class="n">${centsFmt.format(amount)}</td><td class="n">${centsFmt.format(cost)}</td><td>${paid ? "yes" : "no"}</td></tr>`).join("");
}

function setControls(s) {
  el.from.value = s.from; el.to.value = s.to; el.min.value = s.min_amount; el.minOut.value = s.min_amount;
  el.region.value = s.region;
}

const CONTROL = { from: "from", to: "to", min_amount: "min", region: "region" };

async function start() {
  const params = new URLSearchParams(location.search);
  meta = await (await fetch("/api/meta")).json();
  $("source").textContent = `${meta.file} · ${intFmt.format(meta.rows)} rows · FastAPI + Polars`;
  for (const r of meta.regions) el.region.add(new Option(r, r));
  for (const input of [el.from, el.to]) { input.min = meta.first_day; input.max = meta.last_day; }
  setControls({ from: meta.first_day, to: meta.last_day, min_amount: 1, region: "all" });

  el.from.addEventListener("change", onChange);
  el.to.addEventListener("change", onChange);
  el.region.addEventListener("change", onChange);
  el.min.addEventListener("input", () => { el.minOut.value = el.min.value; onChange(); });
  window.addEventListener("resize", () => last && drawChart(last.data.top));

  if (!params.has("scripted")) { await refresh(); return; }
  await scripted(Number(params.get("steps") || 0));
}

async function scripted(n) {
  const all = await (await fetch("/steps.json")).json();
  const answers = [], timings = [];
  const record = (st, r) => {
    const d = r.data;
    answers.push({ step: st.step, rows: d.rows, sum_amount: d.sum_amount, avg_margin: d.avg_margin, top: d.top,
      ids: d.table.rows.map((row) => row[0]) });
    timings.push({ step: st.step, change: st.change || "open", ...r.t });
  };
  setControls(all.opening);
  const first = await refresh();
  record(all.opening, first);
  const firstDashboardEpochMs = performance.timeOrigin + first.tPixels;
  for (const st of all.steps.slice(0, n)) {
    await afterPaint();                      // start each step from an idle page
    const input = el[CONTROL[st.change]];
    const t0 = performance.now();
    input.value = st.change === "min_amount" ? String(st.min_amount) : st[st.change];
    input.dispatchEvent(new Event(st.change === "min_amount" ? "input" : "change"));   // runs onChange now
    const r = await current;
    const want = { from: st.from, to: st.to, min_amount: st.min_amount, region: st.region };
    if (JSON.stringify(r.state) !== JSON.stringify(want)) throw new Error(`step ${st.step}: page state ${JSON.stringify(r.state)}`);
    r.t.input_to_pixels_ms = r.tPixels - t0;
    record(st, r);
  }
  const body = { answers: { steps: answers },
    timings: { file: meta.file, first_dashboard_epoch_ms: firstDashboardEpochMs, steps: timings } };
  await fetch("/api/results", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  document.title = "done";
}

start().catch((e) => { document.title = "error"; document.body.dataset.error = String(e.stack || e); console.error(e); });
