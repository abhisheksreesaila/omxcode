// Goal 79 M6: the web Personal Note's memory after opening a note of each kind (page, canvas, mind map), as the native
// app's `rss:` is read: Chromium's whole process tree (browser, renderer, GPU, utilities) plus the app's Python API, in MB
// of resident memory (/proc/<pid>/status VmRSS). Its own dist/ build, a scratch copy of the reference's database.
// Run from ~/Projects/personalnotev2:  node <mojo-ui>/docs/goals/79/webmem.mjs <pn.db> [--gpu]
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, execSync } from 'node:child_process'
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const src = process.argv[2]
const gpu = process.argv.includes('--gpu')
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-mem-'))
fs.copyFileSync(src, path.join(scratch, 'v.db'))
const PORT = 4997
const api = spawn('.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)],
  { env: { ...process.env, PERSONAL_NOTE_DB: path.join(scratch, 'v.db'), PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }, stdio: 'ignore' })
process.on('exit', () => { try { api.kill() } catch {} })
for (let i = 0; i < 200; i++) { try { if ((await fetch(`http://127.0.0.1:${PORT}/api/notebooks`)).ok) break } catch {} await new Promise((r) => setTimeout(r, 150)) }
const rss = (pid) => { try { return Number(/VmRSS:\s+(\d+)/.exec(fs.readFileSync(`/proc/${pid}/status`, 'utf8'))[1]) / 1024 } catch { return 0 } }
const tree = (pid) => { let out = [pid]; try { for (const c of execSync(`pgrep -P ${pid}`, { encoding: 'utf8' }).split('\n').filter(Boolean)) out = out.concat(tree(Number(c))) } catch {} return out }
const browser = await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage', ...(gpu ? ['--enable-gpu', '--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist'] : [])] })
const page = await (await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1.6 })).newPage()
await page.goto(`http://127.0.0.1:${PORT}/notes`)
await page.locator('#island-title').waitFor()
await page.waitForTimeout(1500)
const notes = await (await fetch(`http://127.0.0.1:${PORT}/api/notes`, { headers: { 'x-personal-note': '1' } })).json()
const list = Array.isArray(notes) ? notes : notes.notes
for (const kind of ['page', 'canvas', 'mindmap']) {
  const n = list.find((x) => x.noteType === kind)
  if (!(await page.locator('.sidebar.open').count())) { await page.click('#toggle-sidebar'); await page.waitForTimeout(500) }
  await page.click(`[data-note-id="${n.id}"]`)
  await page.waitForTimeout(1500)
}
await page.waitForTimeout(1500)
// (Playwright starts Chromium as a child of this script: its tree, less this script itself, is Chromium plus the API)
const apiPids = tree(api.pid)
const pids = tree(process.pid).filter((p) => p !== process.pid)
const chrome = pids.filter((p) => !apiPids.includes(p))
const total = pids.reduce((a, p) => a + rss(p), 0)
console.log(`WEB RSS MB: ${total.toFixed(1)} (${pids.length} processes; Chromium ${chrome.reduce((a, p) => a + rss(p), 0).toFixed(1)} in ${chrome.length}, API ${apiPids.reduce((a, p) => a + rss(p), 0).toFixed(1)})`)
await browser.close()
process.exit(0)
