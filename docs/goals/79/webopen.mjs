// Goal 79 M6 (continuation 20; the owner's ruling 2026-11-24): the web Personal Note's opening of a race note inside the
// running app, over the span the native open row has: from the click on the note in the sidebar (the event's own
// timestamp) to the frame after its canvas is settled (PN's own data-leafer-settled), each in a fresh browser context
// that stands on another note (the first open of that note there is), then the same note once more after leaving it
// (the web keeps what it keeps). Beside: the frames of the opens (requestAnimationFrame gaps from the click to settled),
// and in contexts of their own a press on the canvas made right after the click, to the frame after it. benchmark-f034's
// open row (a page load in a new context) is another thing and stays printed. Personal Note's own dist build and API,
// a scratch copy of the seeded race database.
//   node <mojo-ui>/docs/goals/79/webopen.mjs <race-N.db> [--gpu] [--dpr=N]     (from ~/Projects/personalnotev2)
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const src = process.argv[2]
const gpu = process.argv.includes('--gpu')
const MAC = process.platform === 'darwin'
const DPR = Number((process.argv.find((a) => a.startsWith('--dpr=')) ?? '--dpr=1.6').slice(6))
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-open-'))
fs.copyFileSync(src, path.join(scratch, 'v.db'))
const PORT = 4997
const api = spawn(process.env.PN_PYTHON || '.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)],
  { env: { ...process.env, PERSONAL_NOTE_DB: path.join(scratch, 'v.db'), PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }, stdio: 'ignore' })
process.on('exit', () => { try { api.kill() } catch {} })
for (let i = 0; i < 200; i++) { try { if ((await fetch(`http://127.0.0.1:${PORT}/api/notebooks`)).ok) break } catch {} await new Promise((r) => setTimeout(r, 150)) }
const browser = MAC
  ? await chromium.launch({ headless: true, channel: process.env.PW_CHANNEL || 'chrome', args: gpu ? ['--use-angle=metal', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'] : [] })
  : await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage', ...(gpu ? ['--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'] : [])] })
const notes = await (await fetch(`http://127.0.0.1:${PORT}/api/notes`, { headers: { 'x-personal-note': '1' } })).json()
const list = Array.isArray(notes) ? notes : notes.notes
const race = list.find((n) => n.title === 'Benchmark 600' || n.title === 'Stress note')
const page0 = list.find((n) => (n.noteType ?? n.note_type) === 'page' && !n.secure)
if (!race || !page0) { console.error('no race note or no page note in', src); process.exit(2) }
const p95 = (v) => { const s = [...v].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(s.length * 0.95))] }
const p50 = (v) => [...v].sort((a, b) => a - b)[Math.floor(v.length / 2)]
const worst = (v) => Math.max(...v)
// from the next click: __open = { ms, gaps } at the frame after the canvas `want` is settled; with a press: __press = ms
const ARM = (want) => {
  delete document.documentElement.dataset.leaferSettled
  window.__press = null
  window.__open = new Promise((res) => {
    addEventListener('click', (e) => {
      const t0 = e.timeStamp
      const gaps = []
      let last = t0
      const tick = (time) => {
        gaps.push(time - last); last = time
        if (document.documentElement.dataset.leaferSettled === want) { requestAnimationFrame((time2) => { gaps.push(time2 - last); const c = new MessageChannel(); c.port1.onmessage = () => res({ ms: performance.now() - t0, gaps: gaps.slice(1) }); c.port2.postMessage(0) }) } else requestAnimationFrame(tick)
      }
      requestAnimationFrame(tick)
      addEventListener('pointerdown', (p) => { const at = p.timeStamp; requestAnimationFrame(() => { const c = new MessageChannel(); c.port1.onmessage = () => { window.__press = { ms: performance.now() - at, open: document.documentElement.dataset.leaferSettled !== want } }; c.port2.postMessage(0) }) }, { capture: true, once: true })
    }, { capture: true, once: true })
  })
}
const row = (page, id) => page.locator(`.note-list-item[data-note-id="${id}"]`)
async function stand() {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: DPR })
  const page = await ctx.newPage()
  await page.goto(`http://127.0.0.1:${PORT}/notes`)
  await page.locator('#island-title').waitFor()
  await page.waitForTimeout(1500)
  if (!(await page.locator('.sidebar.open').count())) { await page.click('#toggle-sidebar'); await page.waitForTimeout(600) }
  await row(page, page0.id).first().click()
  await page.waitForTimeout(1500)
  return { ctx, page }
}
const first = [], again = [], gaps = [], press = []
for (let run = 0; run < 5; run++) {
  const { ctx, page } = await stand()
  await page.evaluate(ARM, String(race.id))
  await row(page, race.id).first().click()
  const o = await page.evaluate(() => window.__open)
  first.push(o.ms); gaps.push(...o.gaps)
  await page.waitForTimeout(1200)
  for (let k = 0; k < 4; k++) {
    await row(page, page0.id).first().click()
    await page.waitForTimeout(900)
    await page.evaluate(ARM, String(race.id))
    await row(page, race.id).first().click()
    const a = await page.evaluate(() => window.__open)
    again.push(a.ms); gaps.push(...a.gaps)
    await page.waitForTimeout(900)
  }
  await ctx.close()
  const p = await stand()
  await p.page.evaluate(ARM, String(race.id))
  await row(p.page, race.id).first().click()
  await p.page.mouse.click(900, 500)
  await p.page.evaluate(() => window.__open)
  const pr = await p.page.evaluate(() => window.__press)
  if (pr) press.push(pr)
  await p.ctx.close()
  console.log(`WEBOPEN run ${run}: first ${o.ms.toFixed(0)}; press ${pr ? `${pr.ms.toFixed(1)}${pr.open ? ' (during the open)' : ' (after it settled)'}` : 'none'}`)
}
const during = press.filter((p) => p.open).map((p) => p.ms)
console.log(`WEBOPEN renderer: ${browser.version()}`)
console.log(`WEBOPEN first p95: ${p95(first).toFixed(1)} max: ${worst(first).toFixed(1)} p50: ${p50(first).toFixed(1)} n: ${first.length}`)
console.log(`WEBOPEN again p95: ${p95(again).toFixed(1)} max: ${worst(again).toFixed(1)} p50: ${p50(again).toFixed(1)} n: ${again.length}`)
console.log(`WEBOPEN gaps p95: ${p95(gaps).toFixed(1)} max: ${worst(gaps).toFixed(1)} n: ${gaps.length}`)
if (during.length) console.log(`WEBOPEN press p95: ${p95(during).toFixed(1)} max: ${worst(during).toFixed(1)} n: ${during.length}`)
await browser.close()
process.exit(0)
