// Build A: the goal 38 dashboard (showcase-data/SPEC.md) in plain JS over DuckDB-WASM.
//
// The setup, picked by measurement (10M and 100M, scripted, real GPU Chromium; see check_a.py):
// - The data goes into an in-memory DuckDB table once (CREATE TABLE AS); every change then runs two prepared queries
//   on it. Querying the Parquet file on every change instead was ~6x slower at 10M (670 vs 110 ms median).
// - region and product become ENUMs (one byte, not strings): 3x faster filters and group-by (425 -> 125 ms at 10M).
// - Small files (10M rows, 130 MB): the single-threaded "eh" bundle, the file fetched and handed to DuckDB as a buffer.
// - Big files (100M rows, 1.3 GB): an uncompressed table needs ~4.1 GB, past wasm's 4 GB (DuckDB-WASM fails with "Out
//   of Memory Error: Allocation failure"), so the table lives in a compressed in-memory database (ATTACH ':memory:'
//   (COMPRESS), 750 MB for 100M rows). Its scans are slower, so the threaded "coi" bundle (4 threads) runs the queries:
//   ~750 ms median per change vs ~2,400 ms single-threaded. coi's Parquet extension does not load in DuckDB-WASM 1.33
//   ("mismatch in shared state of memory"), so parquet-wasm decodes the file into Arrow for it (loadViaParquetWasm).
//   coi is fragile here: 1-3 threads hang, 6 and 16 run out of memory ("offset is out of bounds"), 8 is slower than 4,
//   and at 4 the load failed the same way at ~90M rows until the wasm memory is grown once up front (see there).
//
// URL params (defaults by file size, as above):
//   rows=10M|100M      which data/orders-<rows>.parquet to open (default 10M)
//   bundle=eh|coi      DuckDB-WASM build: eh single-threaded; coi threaded (needs src=pqwasm)
//   src=buffer|url|pqwasm  how the bytes reach DuckDB: buffer (fetch, registerFileBuffer), url (DuckDB's HTTP file
//                      system, range requests: no copy of the file in wasm memory), pqwasm (see above)
//   threads=N          coi's thread count (default 4)
//   compress=auto|1|0  auto: only when the uncompressed table would not fit
//   types=enum|plain   plain: keep the Parquet's strings (for comparison)
//   load=table|file    file: query the Parquet file on every change (for comparison)
//   scripted=1&steps=S drive steps.json's first S changes, then POST answers.json + timings.json to the server
import * as duckdb from "@duckdb/duckdb-wasm";
import initParquetWasm, { ParquetFile } from "parquet-wasm";

const P = new URLSearchParams(location.search);
const ROWS = P.get("rows") || "10M";
const LOAD = P.get("load") || "table";
const TYPES = P.get("types") || "enum";
const COMPRESS = { "1": true, "0": false }[P.get("compress")] ?? "auto";
const SCRIPTED = P.get("scripted") === "1";
const TOP = 20, IDS = 50;

const $ = (id) => document.getElementById(id);
const ui = { from: $("from"), to: $("to"), min: $("min"), minv: $("minv"), region: $("region"), status: $("status"),
             rows: $("k-rows"), sum: $("k-sum"), margin: $("k-margin"), ms: $("k-ms"), chart: $("chart"), tbody: $("rows") };
const fmtInt = new Intl.NumberFormat("en-US");
const fmtMoney = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
const fmt2 = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fmtPct = new Intl.NumberFormat("en-US", { style: "percent", minimumFractionDigits: 2, maximumFractionDigits: 2 });
const nextPaint = () => new Promise((res) => requestAnimationFrame(() => {
  // rAF runs just before the frame is drawn; a message posted from it lands right after that frame.
  const ch = new MessageChannel();
  ch.port1.onmessage = () => res(performance.now());
  ch.port2.postMessage(0);
}));

let lastSplit = {};
let db, conn, qAgg = {}, qRows = {}, source;
const log = { setup: {}, steps: [] };

// ----------------------------------------------------------------------------------------------------------------
// DuckDB
// ----------------------------------------------------------------------------------------------------------------
async function openDuckDB() {
  const base = new URL("/dist/", location.href).href;
  const bundles = {
    eh: { mainModule: base + "duckdb-eh.wasm", mainWorker: base + "duckdb-browser-eh.worker.js" },
    coi: { mainModule: base + "duckdb-coi.wasm", mainWorker: base + "duckdb-browser-coi.worker.js",
           pthreadWorker: base + "duckdb-browser-coi.pthread.worker.js" },
  };
  const bundle = bundles[cfg.bundle];
  const t0 = performance.now();
  const worker = new Worker(bundle.mainWorker);
  db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), worker);
  await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  await db.open({ query: { castBigIntToDouble: true } });
  conn = await db.connect();
  // The Parquet extension (eh) comes from build.sh's pinned copy, not the internet.
  if (cfg.bundle === "eh")
    await conn.query(`SET custom_extension_repository = '${new URL("/dist/ext", location.href).href}'`);
  if (cfg.bundle === "coi") await conn.query(`SET threads = ${cfg.threads}`);
  const threads = (await conn.query("SELECT current_setting('threads') AS t")).getChild("t").get(0);
  log.setup.bundle = bundle.mainModule.split("/").pop();
  log.setup.duckdb_start_ms = performance.now() - t0;   // worker + wasm compile + open
  log.setup.threads = Number(threads);
  log.setup.crossOriginIsolated = self.crossOriginIsolated;
  log.setup.duckdb = await db.getVersion();
}

const COLS = { enum: "id, day, region::region_t AS region, product::product_t AS product, amount, cost, paid" };

// The setup for this file (see the top of this file); URL params override it.
let cfg;
async function chooseSetup() {
  const name = `orders-${ROWS}.parquet`, url = new URL(`/data/${name}`, location.href).href;
  const bytes = Number((await fetch(url, { method: "HEAD" })).headers.get("Content-Length"));
  const big = bytes >= 512e6;
  cfg = { name, url, bytes, bundle: P.get("bundle") || (big ? "coi" : "eh"),
          src: P.get("src") || (big ? "pqwasm" : "buffer"), threads: Number(P.get("threads") || 4) };
  if (cfg.bundle === "coi" && cfg.src !== "pqwasm") throw new Error("bundle=coi needs src=pqwasm (its parquet extension does not load)");
}

async function loadData() {
  const { name, url, bytes, src } = cfg;
  const t0 = performance.now();
  if (src === "pqwasm") {
    await loadViaParquetWasm(url, t0);
    source = "o";
  } else {
    if (src === "buffer") {
      const buf = new Uint8Array(await (await fetch(url)).arrayBuffer());
      log.setup.fetch_ms = performance.now() - t0;
      await db.registerFileBuffer(name, buf);
    } else {
      await db.registerFileURL(name, url, duckdb.DuckDBDataProtocol.HTTP, false);
    }
    const f = `read_parquet('${name}')`;
    source = f;
    if (LOAD === "table") {
      const rows = Number((await conn.query(`SELECT count(*)::DOUBLE AS n FROM ${f}`)).getChild("n").get(0));
      // An uncompressed in-memory table takes ~41 bytes a row here (31 of data + DuckDB's block overhead, measured);
      // past ~2 GB it would not fit beside the query's working memory, so compress (slower scans, a tenth the size).
      const compress = COMPRESS === "auto" ? rows * 41 > 2e9 : COMPRESS;
      log.setup.compress = compress;
      if (compress) await conn.query("ATTACH ':memory:' AS mem (COMPRESS); USE mem");
      if (TYPES !== "plain") {
        await conn.query(`CREATE TYPE region_t AS ENUM (SELECT DISTINCT region FROM ${f} ORDER BY 1)`);
        await conn.query(`CREATE TYPE product_t AS ENUM (SELECT DISTINCT product FROM ${f} ORDER BY 1)`);
      }
      const cols = COLS[TYPES] || "*";
      if (!compress) {
        await conn.query(`CREATE TABLE o AS SELECT ${cols} FROM ${f}`);
      } else {
        // Compressed storage is written at CHECKPOINT; load 10M rows at a time (id is the row number and the row groups
        // hold ids in order, so `id` ranges skip the other row groups) and checkpoint after each, so the uncompressed
        // staging never exceeds one chunk.
        await conn.query(`CREATE TABLE o AS SELECT ${cols} FROM ${f} LIMIT 0`);
        for (let lo = 0; lo < rows; lo += 1e7) {
          await conn.query(`INSERT INTO o SELECT ${cols} FROM ${f} WHERE id >= ${lo} AND id < ${lo + 1e7}`);
          await conn.query("CHECKPOINT mem");
          log.setup.loaded = { rows: Math.min(rows, lo + 1e7), ms: performance.now() - t0 };
          if (SCRIPTED) post("progress", log);
        }
      }
      const n = Number((await conn.query("SELECT count(*)::DOUBLE AS n FROM o")).getChild("n").get(0));
      if (n !== rows) throw new Error(`loaded ${n} rows of ${rows}`);
      if (src === "buffer") await db.dropFile(name);   // the bytes are in the table now: free them
      source = "o";
    }
  }
  log.setup.load_ms = performance.now() - t0;
  Object.assign(log.setup, { load: LOAD, src, types: LOAD === "table" ? TYPES : "parquet", file_bytes: bytes });
  log.setup.duckdb_memory_mb = Object.fromEntries((await conn.query(
    "SELECT tag, round(memory_usage_bytes / 1e6) AS mb FROM duckdb_memory() WHERE memory_usage_bytes > 0")).toArray().map((r) => [r.tag, r.mb]));
  // The region list for the filter comes from the data.
  const regions = (await conn.query(`SELECT DISTINCT region FROM ${source} ORDER BY region`)).getChild("region").toArray();
  for (const r of regions) ui.region.add(new Option(r, r));
  // Two prepared statements per region mode: one GROUP BY product scan gives the chart and the KPIs (rows, sum and
  // the margin's sum add up over the products), and a top-N for the table.
  // A: amount as DOUBLE (the file's float64 values whatever the table's type).
  const A = "amount::DOUBLE", C = "cost::DOUBLE";
  for (const all of [true, false]) {
    const where = `day BETWEEN CAST(? AS DATE) AND CAST(? AS DATE) AND amount >= ?` + (all ? "" : " AND region = ?");
    qAgg[all] = await conn.prepare(`SELECT product::VARCHAR AS product, count(*)::DOUBLE AS n, sum(${A}) AS s,
        sum((${A} - ${C}) / ${A}) AS m FROM ${source} WHERE ${where} GROUP BY product`);
    const cols = `id::DOUBLE AS id, day, region::VARCHAR AS region, product::VARCHAR AS product, ${A} AS amount,
        ${C} AS cost, paid`;
    qRows[all] = await conn.prepare(`SELECT ${cols} FROM ${source} WHERE ${where} ORDER BY day DESC, id ASC LIMIT ${IDS}`);
  }
}

// parquet-wasm decodes one row group at a time to an Arrow IPC stream; DuckDB inserts it into a staging table and
// appends it to `o` with region and product as ENUMs. The ENUMs' values come from a first pass over just those two
// columns, so a value that only shows up late is never missed. (For the coi bundle: its parquet extension won't load.)
async function loadViaParquetWasm(url, t0) {
  await initParquetWasm(new URL("/dist/parquet_wasm_bg.wasm", location.href));
  // A Blob, not one big Uint8Array: readParquet(bytes) would copy the whole 1.3 GB into parquet-wasm's memory on every
  // call ("offset is out of bounds" once it can't); ParquetFile reads just the row group's byte ranges from the Blob.
  const file = await ParquetFile.fromFile(await (await fetch(url)).blob());
  log.setup.fetch_ms = performance.now() - t0;
  const meta = file.metadata(), groups = meta.numRowGroups(), rows = Number(meta.fileMetadata().numRows());
  const compress = COMPRESS === "auto" ? rows * 41 > 2e9 : COMPRESS;   // as in loadData
  log.setup.compress = compress;
  if (compress) await conn.query("ATTACH ':memory:' AS mem (COMPRESS); USE mem");
  const stage = async (opts) => {
    await conn.query("DROP TABLE IF EXISTS stage");
    const ipc = (await file.read({ batchSize: 1 << 20, ...opts })).intoIPCStream();
    await conn.insertArrowFromIPCStream(ipc, { name: "stage", create: true });
  };
  // coi's wasm memory is shared; when it grows while a worker copies an Arrow buffer in, DuckDB-WASM's JS side can hold a
  // stale view and fail with "offset is out of bounds" (seen at ~90M rows). Grow it once, up front, then free it.
  if (cfg.bundle === "coi" && compress) {
    await conn.query("CREATE TABLE grow AS SELECT range FROM range(250000000)");
    await conn.query("DROP TABLE grow");
  }
  const regions = new Set(), products = new Set();
  for (let g = 0; g < groups; g++) {
    await stage({ rowGroups: [g], columns: ["region", "product"] });
    const r = await conn.query("SELECT list(DISTINCT region) AS r, list(DISTINCT product) AS p FROM stage");
    for (const v of r.getChild("r").get(0)) regions.add(v);
    for (const v of r.getChild("p").get(0)) products.add(v);
  }
  const lit = (set) => [...set].sort().map((v) => `'${v.replaceAll("'", "''")}'`).join(", ");
  await conn.query(`CREATE TYPE region_t AS ENUM (${lit(regions)})`);
  await conn.query(`CREATE TYPE product_t AS ENUM (${lit(products)})`);
  await conn.query("CREATE TABLE o (id BIGINT, day DATE, region region_t, product product_t, amount DOUBLE, cost DOUBLE, paid BOOLEAN)");
  for (let g = 0; g < groups; g++) {
    await stage({ rowGroups: [g] });
    await conn.query("INSERT INTO o SELECT id, day, region, product, amount, cost, paid FROM stage");
    if (compress && (g % 10 === 9 || g === groups - 1)) {
      await conn.query("DROP TABLE stage");
      await conn.query("CHECKPOINT mem");
      log.setup.loaded = { rows: Math.round((g + 1) * rows / groups), ms: performance.now() - t0 };
      if (SCRIPTED) post("progress", log);
    }
  }
  await conn.query("DROP TABLE IF EXISTS stage");
  const n = Number((await conn.query("SELECT count(*)::DOUBLE AS n FROM o")).getChild("n").get(0));
  if (n !== rows) throw new Error(`loaded ${n} rows of ${rows}`);
}

async function compute(st) {
  const all = st.region === "all";
  const args = [st.from, st.to, st.min_amount, ...(all ? [] : [st.region])];
  const a0 = performance.now();
  const agg = await qAgg[all].query(...args);
  const a1 = performance.now();
  const rows = await qRows[all].query(...args);
  lastSplit = { agg_ms: a1 - a0, rows_ms: performance.now() - a1 };
  const prod = agg.getChild("product").toArray(), n = agg.getChild("n").toArray(),
        s = agg.getChild("s").toArray(), m = agg.getChild("m").toArray();
  let count = 0, sum = 0, msum = 0;
  const groups = [];
  for (let i = 0; i < prod.length; i++) { count += n[i]; sum += s[i]; msum += m[i]; groups.push([prod[i], s[i]]); }
  groups.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const cols = ["id", "day", "region", "product", "amount", "cost", "paid"].map((c) => rows.getChild(c).toArray());
  const table = [];
  // DATE arrives as epoch milliseconds (Arrow DateDay); format only the 50 shown rows, not every candidate row in SQL.
  for (let i = 0; i < rows.numRows; i++) {
    const row = cols.map((c) => c[i]);
    row[1] = new Date(row[1]).toISOString().slice(0, 10);
    table.push(row);
  }
  return { rows: count, sum_amount: sum, avg_margin: count ? msum / count : null, top: groups.slice(0, TOP), table };
}

// ----------------------------------------------------------------------------------------------------------------
// Rendering
// ----------------------------------------------------------------------------------------------------------------
function renderChart(top) {
  const c = ui.chart, dpr = devicePixelRatio || 1;
  const w = c.clientWidth, h = c.clientHeight;
  if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr); }
  const g = c.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, h);
  g.font = "12px system-ui, sans-serif";
  g.textBaseline = "middle";
  if (!top.length) { g.fillStyle = "#6b7385"; g.fillText("Nothing matches", 8, 16); return; }
  const label = 110, value = 78, row = Math.min(28, h / TOP), bar = row * 0.68;
  const max = top[0][1], span = Math.max(1, w - label - value - 8);
  top.forEach(([p, s], i) => {
    const y = i * row + row / 2;
    g.fillStyle = "#1d2433"; g.textAlign = "right"; g.fillText(p, label - 8, y);
    g.fillStyle = i === 0 ? "#2f6fdf" : "#6f9be8";
    const bw = Math.max(1, (s / max) * span);
    g.fillRect(label, y - bar / 2, bw, bar);
    g.fillStyle = "#6b7385"; g.textAlign = "left"; g.fillText(fmtMoney.format(s), label + bw + 6, y);
  });
}

function render(r, queryMs) {
  ui.rows.textContent = fmtInt.format(r.rows);
  ui.sum.textContent = fmtMoney.format(r.sum_amount);
  ui.margin.textContent = r.avg_margin === null ? "–" : fmtPct.format(r.avg_margin);
  ui.ms.textContent = `${queryMs.toFixed(0)} ms`;
  renderChart(r.top);
  let html = "";
  for (const [id, day, region, product, amount, cost, paid] of r.table)
    html += `<tr><td>${id}</td><td>${day}</td><td>${region}</td><td>${product}</td><td class="n">${fmt2.format(amount)}</td>` +
            `<td class="n">${fmt2.format(cost)}</td><td>${paid ? "yes" : "no"}</td></tr>`;
  ui.tbody.innerHTML = html;
}

// ----------------------------------------------------------------------------------------------------------------
// Controls → state → compute → render. A change while a query runs is coalesced: only the latest state runs next.
// ----------------------------------------------------------------------------------------------------------------
const state = () => ({ from: ui.from.value, to: ui.to.value, min_amount: Number(ui.min.value), region: ui.region.value });
let busy = false, pending = null, onShown = null;

async function update(t0) {
  if (busy) { pending = t0; return; }
  busy = true;
  const st = state();
  const q0 = performance.now();
  const r = await compute(st);
  const q1 = performance.now();
  render(r, q1 - q0);
  const r1 = performance.now();
  const shown = await nextPaint();
  ui.status.textContent = `${ROWS} rows · ${(shown - t0).toFixed(0)} ms to screen`;
  busy = false;
  if (onShown) onShown({ st, r, t0, query_ms: q1 - q0, render_ms: r1 - q1, input_to_pixels_ms: shown - t0, shown, split: lastSplit });
  if (pending !== null) { const p = pending; pending = null; update(p); }
}

ui.min.addEventListener("input", (e) => { ui.minv.value = ui.min.value; update(performance.now()); });
for (const el of [ui.from, ui.to, ui.region]) el.addEventListener("change", () => update(performance.now()));

// ----------------------------------------------------------------------------------------------------------------
// Start, and scripted mode
// ----------------------------------------------------------------------------------------------------------------
const answer = (k, r) => ({ step: k, rows: r.rows, sum_amount: r.sum_amount, avg_margin: r.avg_margin,
                            top: r.top, ids: r.table.map((row) => Number(row[0])) });
const post = (name, data) => fetch(`/out/${name}`, { method: "POST", body: JSON.stringify(data) });
const shownOnce = () => new Promise((res) => { onShown = (x) => { onShown = null; res(x); }; });

async function main() {
  await chooseSetup();
  await openDuckDB();
  await loadData();
  log.setup.ready_ms = performance.now();
  if (SCRIPTED) post("progress", log);
  const first = shownOnce();
  update(performance.now());
  const s0 = await first;
  log.setup.first_dashboard_ms = s0.shown;   // from navigation start to the first dashboard on screen
  log.setup.gpu = gpuName();
  ui.status.textContent = `${ROWS} rows · ready in ${(s0.shown / 1000).toFixed(1)} s`;
  if (!SCRIPTED) return;
  const plan = await (await fetch("/steps.json")).json();
  const S = Math.min(Number(P.get("steps") || plan.steps.length), plan.steps.length);
  const answers = [answer(0, s0.r)];
  log.steps.push(timing(0, s0));
  for (const step of plan.steps.slice(0, S)) {
    await nextPaint(); await nextPaint();   // settle between changes
    const el = { from: ui.from, to: ui.to, min_amount: ui.min, region: ui.region }[step.change];
    const next = shownOnce();
    el.value = String(step[step.change]);
    el.dispatchEvent(new Event(step.change === "min_amount" ? "input" : "change"));
    const x = await next;
    const want = { from: step.from, to: step.to, min_amount: step.min_amount, region: step.region };
    if (JSON.stringify(x.st) !== JSON.stringify(want)) throw new Error(`step ${step.step}: state ${JSON.stringify(x.st)}`);
    answers.push(answer(step.step, x.r));
    log.steps.push(timing(step.step, x));
    post("progress", log);   // so a slow run can be watched (out/progress.json)
  }
  await post("answers", { build: "A js-duckdb", rows: ROWS, steps: answers });
  await post("timings", { build: "A js-duckdb", rows: ROWS, ...log });
  await post("done", {});
}
const timing = (k, x) => ({ step: k, input_to_pixels_ms: x.input_to_pixels_ms, query_ms: x.query_ms, render_ms: x.render_ms, ...x.split });

function gpuName() {
  try {
    const gl = document.createElement("canvas").getContext("webgl");
    const ext = gl.getExtension("WEBGL_debug_renderer_info");
    return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  } catch (e) { return String(e); }
}

main().catch(async (e) => {
  const msg = String(e && e.message || e);
  ui.status.textContent = "Error: " + msg;
  if (SCRIPTED) { await post("error", { error: msg, setup: log.setup }); await post("done", {}); }
});
