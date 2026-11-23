// Goal 79 M6 (continuation 17): the web Personal Note's note switch and omnibar, measured as the native rows are: five runs,
// each a fresh page (a fresh process natively), five note switches walking the sidebar's list and five omnibar opens
// (Ctrl/⌘+K); each run's p95 of five is its worst, the number is the median over the runs, as native_start takes it.
// A step runs from the input event's own timestamp to the frame after the change shows (a requestAnimationFrame, then a
// task after it: that frame's script, style, layout and paint are done): the new note's title in the title island; the
// search panel open. Generous to the web: a note's content may still be coming in (the settled time of a canvas is
// printed beside, not judged). Personal Note's own dist build and API, a scratch copy of the reference's database.
//   node <mojo-ui>/docs/goals/79/webswitch.mjs <pn.db> [--gpu] [--dpr=N]     (from ~/Projects/personalnotev2; on macOS the
// Mac's own Chrome with ANGLE on Metal, as webmem.mjs)
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
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-switch-'))
fs.copyFileSync(src, path.join(scratch, 'v.db'))
const PORT = 4998
const api = spawn(process.env.PN_PYTHON || '.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)],
  { env: { ...process.env, PERSONAL_NOTE_DB: path.join(scratch, 'v.db'), PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }, stdio: 'ignore' })
process.on('exit', () => { try { api.kill() } catch {} })
for (let i = 0; i < 200; i++) { try { if ((await fetch(`http://127.0.0.1:${PORT}/api/notebooks`)).ok) break } catch {} await new Promise((r) => setTimeout(r, 150)) }
const browser = MAC
  ? await chromium.launch({ headless: true, channel: process.env.PW_CHANNEL || 'chrome', args: gpu ? ['--use-angle=metal', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'] : [] })
  : await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage', ...(gpu ? ['--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'] : [])] })
const worst = (v) => Math.max(...v)
const median = (v) => [...v].sort((a, b) => a - b)[Math.floor(v.length / 2)]
// arms a measurement in the page: the next input event of `type` starts it; when `done()` is true the frame after ends it
const ARM = ([type, what, want]) => {
  window.__ms = new Promise((res) => {
    const done = () => what === 'title' ? (document.querySelector('#island-title')?.textContent || '').trim() === want : document.querySelector('#search-backdrop').hidden === (want === 'shut')
    addEventListener(type, (e) => {
      const t0 = e.timeStamp
      const look = () => { if (done()) { requestAnimationFrame(() => { const c = new MessageChannel(); c.port1.onmessage = () => res(performance.now() - t0); c.port2.postMessage(0) }) } else requestAnimationFrame(look) }
      queueMicrotask(() => { if (done()) look(); else requestAnimationFrame(look) })
    }, { capture: true, once: true })
  })
}
const sw = [], om = [], settled = []
let renderer = ''
for (let run = 0; run < 5; run++) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: DPR })
  const page = await ctx.newPage()
  await page.goto(`http://127.0.0.1:${PORT}/notes`)
  await page.locator('#island-title').waitFor()
  await page.waitForTimeout(1500)
  renderer ||= await page.evaluate(() => { const gl = document.createElement('canvas').getContext('webgl'); const e = gl?.getExtension('WEBGL_debug_renderer_info'); return e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : 'none' })
  if (!(await page.locator('.sidebar.open').count())) { await page.click('#toggle-sidebar'); await page.waitForTimeout(600) }
  const ids = await page.evaluate(() => [...document.querySelectorAll('.note-list-item[data-note-id]')].map((e) => e.dataset.noteId))
  const notes = await (await fetch(`http://127.0.0.1:${PORT}/api/notes`, { headers: { 'x-personal-note': '1' } })).json()
  const list = Array.isArray(notes) ? notes : notes.notes
  const title = (id) => list.find((n) => String(n.id) === id).title.trim()
  const a = [], s = []
  const active = await page.evaluate(() => document.querySelector('.note-list-item.active')?.dataset.noteId)
  let k = Math.max(0, ids.indexOf(active))
  for (let i = 0; i < 5; i++) {
    k = (k + 1) % ids.length
    await page.evaluate(ARM, ['click', 'title', title(ids[k])])
    await page.evaluate((id) => { window.__sid = id; window.__s0 = performance.now(); delete document.documentElement.dataset.leaferSettled }, ids[k])
    await page.click(`.note-list-item[data-note-id="${ids[k]}"]`)
    a.push(await page.evaluate(() => window.__ms))
    const st = await page.waitForFunction(() => document.documentElement.dataset.leaferSettled === window.__sid ? performance.now() - window.__s0 : false, null, { timeout: 1500 }).then((h) => h.jsonValue()).catch(() => null)
    if (st) s.push(st)
    await page.waitForTimeout(500)
  }
  const b = []
  for (let i = 0; i < 5; i++) {  // (opens only: a close fades for 200 ms before the panel is hidden, which says nothing about speed)
    await page.evaluate(ARM, ['keydown', 'search', 'open'])
    await page.keyboard.press(MAC ? 'Meta+k' : 'Control+k')
    b.push(await page.evaluate(() => window.__ms))
    await page.waitForTimeout(400)
    await page.keyboard.press('Escape')
    await page.waitForFunction(() => document.querySelector('#search-backdrop').hidden)
    await page.waitForTimeout(300)
  }
  console.log(`WEBSWITCH run ${run}: note switch ${a.map((v) => v.toFixed(1)).join(' ')}; omnibar ${b.map((v) => v.toFixed(1)).join(' ')}${s.length ? `; settled (not judged) ${s.map((v) => v.toFixed(0)).join(' ')}` : ''}`)
  sw.push(worst(a)); om.push(worst(b)); settled.push(...s)
  await ctx.close()
}
console.log(`WEBSWITCH renderer: ${browser.version()} ${renderer}`)
console.log(`WEBSWITCH note switch p95: ${median(sw).toFixed(1)} max: ${worst(sw).toFixed(1)}`)
console.log(`WEBSWITCH omnibar p95: ${median(om).toFixed(1)} max: ${worst(om).toFixed(1)}`)
await browser.close()
process.exit(0)
