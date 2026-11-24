// Goal 79 M6 (continuation 22, review 4 MUST 5): typing in the middle of a page's 20,000-character paragraph, in the web
// Personal Note: its own dist build and API, a scratch copy of the reference's database. 80 keys, one after the other's frame,
// each from its keydown's own timestamp to the frame after it shows (a requestAnimationFrame, then a task after it), as the
// undo rows are timed. With an output path the database is written there too (the native run types into the same note).
//   node <mojo-ui>/docs/goals/79/webtype.mjs <pn.db> [out.db] [--gpu] [--dpr=N]     (from ~/Projects/personalnotev2)
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const args = process.argv.slice(2).filter((a) => !a.startsWith('--'))
const gpu = process.argv.includes('--gpu')
const MAC = process.platform === 'darwin'
const DPR = Number((process.argv.find((a) => a.startsWith('--dpr=')) ?? '--dpr=1.6').slice(6))
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-type-'))
const db = path.join(scratch, 'v.db')
fs.copyFileSync(args[0], db)
const PORT = 4995
const py = process.env.PN_PYTHON || '.venv/bin/python'
const api = spawn(py, ['-B', '-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)], { env: { ...process.env, PERSONAL_NOTE_DB: db, PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }, stdio: 'ignore' })
process.on('exit', () => { try { api.kill() } catch {} })
const base = `http://127.0.0.1:${PORT}`
for (let i = 0; i < 200; i++) { try { if ((await fetch(`${base}/api/notebooks`)).ok) break } catch {} await new Promise((r) => setTimeout(r, 150)) }
const call = async (m, u, b) => { const r = await fetch(`${base}/api${u}`, { method: m, headers: { 'content-type': 'application/json', 'x-personal-note': '1' }, body: b && JSON.stringify(b) }); const j = await r.json(); if (!r.ok) throw new Error(`${m} ${u}: ${r.status} ${JSON.stringify(j).slice(0, 300)}`); return j }
const some = 'the quick brown fox **jumps** over a *lazy* dog with `code` and a [link](https://example.org/a) while it rains, '
const words = some.repeat(Math.ceil(20000 / some.length)).slice(0, 20000)
const made = await call('POST', '/notes', { title: 'Long paragraph', noteType: 'page' })
const full = await call('GET', `/notes/${made.id}`)
await call('PUT', `/notes/${made.id}`, { title: 'Long paragraph', revision: made.revision, content: { ...(full.content ?? {}), markdown: words } })
await new Promise((r) => setTimeout(r, 300))
if (args[1]) {
  for (const f of [args[1], args[1] + '-wal', args[1] + '-shm']) fs.rmSync(f, { force: true })
  const b = spawnSync(py, ['-c', 'import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close()', db, args[1]], { encoding: 'utf8' })
  if (b.status !== 0) throw new Error(b.stderr)
}
const browser = MAC
  ? await chromium.launch({ headless: true, channel: process.env.PW_CHANNEL || 'chrome', args: gpu ? ['--use-angle=metal', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'] : [] })
  : await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage', ...(gpu ? ['--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'] : [])] })
const page = await (await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: DPR })).newPage()
await page.goto(`${base}/notes`)
await page.locator('#island-title').waitFor()
await page.waitForTimeout(1500)
if (!(await page.locator('.sidebar.open').count())) { await page.click('#toggle-sidebar'); await page.waitForTimeout(600) }
await page.locator(`.note-list-item[data-note-id="${made.id}"]`).first().click()
await page.waitForTimeout(1500)
const box = await page.locator('.cm-content').boundingBox()
await page.mouse.click(box.x + box.width / 2, 450) // (in the middle of the shown lines)
await page.waitForTimeout(300)
await page.evaluate(() => { window.__l = []; addEventListener('keydown', (e) => { const t = e.timeStamp; requestAnimationFrame(() => { const c = new MessageChannel(); c.port1.onmessage = () => window.__l.push(performance.now() - t); c.port2.postMessage(0) }) }, true) })
const keys = 'native mojo is fast '
for (let k = 0; k < 80; k++) {
  await page.keyboard.press(keys[k % keys.length] === ' ' ? 'Space' : keys[k % keys.length])
  await page.waitForFunction((n) => window.__l.length > n, k)
}
const l = (await page.evaluate(() => window.__l)).sort((a, b) => a - b)
const held = (await page.locator('.cm-content').count()) === 1
console.log(`WEBTYPE p95: ${l[Math.min(l.length - 1, Math.floor(l.length * 0.95))].toFixed(1)} max: ${l.at(-1).toFixed(1)} n: ${l.length}${held ? '' : ' (no editor)'}`)
await browser.close()
try { api.kill() } catch {}
process.exit(0)
