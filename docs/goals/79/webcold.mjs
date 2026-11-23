// Goal 79 M6 (D-7950): the web Personal Note's cold start, like with like. From the process's start to its first screen,
// measured by one visible marker for both: the title island (#island-title) holding the note's title, painted (two
// animation frames after it is there, as PN's own benchmark-first-screen.mjs marks its first screen).
//   desktop:  Personal Note's own desktop launcher (desktop.py through docs/goals/79/desktop_cold.py: its server and its
//             Chromium app window), process start by /proc as the native FIRSTSCREEN
//   chromium: a fresh Chromium process (the binary and flags PN's launcher uses, a new profile) opening the built app,
//             its API already serving; from just before the spawn
// Each run uses a scratch copy of the database and fresh folders; windows go to the hidden test screen (scripts/testscreen
// runs this). Prints `WEBCOLD <mode> run <i>: <ms>` per run and `WEBCOLD <mode> median: <ms>`.
// Run from ~/Projects/personalnotev2:  node <mojo-ui>/docs/goals/79/webcold.mjs <pn.db> <desktop|chromium> [runs]
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
const PN = process.cwd()
const HERE = path.dirname(new URL(import.meta.url).pathname)
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const [src, mode, runsArg] = process.argv.slice(2)
const RUNS = Number(runsArg || 5)
// (D-7988) on macOS the Mac's own Chrome (ruling A); PN's own Mac launcher is a WKWebView window with no DevTools port,
// so only the chromium mode runs there
const MAC_CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const CHROMIUM = process.platform === 'darwin' ? MAC_CHROME : fs.existsSync('/usr/lib/chromium/chromium') ? '/usr/lib/chromium/chromium' : 'chromium'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const WATCH = `new Promise((res) => { const had = !!(document.querySelector('#island-title')?.textContent || '').trim()
  const t = () => { const e = document.querySelector('#island-title'); if (e && e.textContent.trim()) requestAnimationFrame(() => requestAnimationFrame(() => res({ at: performance.timeOrigin + performance.now(), had }))); else requestAnimationFrame(t) }; t() })`

async function marker(port, deadline) {
  let browser
  while (!browser) {
    try { browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`) } catch { if (Date.now() > deadline) throw new Error('no DevTools port'); await sleep(5) }
  }
  let page
  while (!page) {
    for (const c of browser.contexts()) for (const p of c.pages()) if (p.url().includes('/notes')) page = p
    if (!page) { if (Date.now() > deadline) throw new Error('no page'); await sleep(5) }
  }
  let r
  while (!r) { try { r = await page.evaluate(WATCH) } catch { if (Date.now() > deadline) throw new Error('page never answered'); await sleep(5) } }
  return { r, browser }
}

function killTree(child) { try { process.kill(-child.pid, 'SIGTERM') } catch {} setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL') } catch {} }, 1500) }

if (process.platform === 'darwin' && mode === 'desktop') {
  console.log('WEBCOLD desktop median: none (not measurable on macOS: PN\'s Mac launcher is a WKWebView window, no DevTools port to read its first paint)')
  process.exit(0)
}
const times = []
let api
if (mode === 'chromium') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-cold-api-'))
  fs.copyFileSync(src, path.join(dir, 'c.db'))
  api = spawn('.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', '4996'],
    { env: { ...process.env, PERSONAL_NOTE_DB: path.join(dir, 'c.db'), PERSONAL_NOTE_PLUGINS_DIR: path.join(dir, 'plugins') }, stdio: 'ignore', detached: true })
  for (let i = 0; i < 200; i++) { try { if ((await fetch('http://127.0.0.1:4996/api/notebooks')).ok) break } catch {} await sleep(100) }
}
for (let i = 0; i < RUNS; i++) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `pn-cold-${mode}-`))
  const port = 9300 + i
  let child, start
  if (mode === 'desktop') {
    fs.copyFileSync(src, path.join(dir, 'd.db'))
    child = spawn(path.join(PN, '.venv/bin/python'), [path.join(HERE, 'desktop_cold.py'), PN, String(port)], {
      env: { ...process.env, PERSONAL_NOTE_DB: path.join(dir, 'd.db'), XDG_DATA_HOME: path.join(dir, 'data'), PERSONAL_NOTE_PLUGINS_DIR: path.join(dir, 'plugins') },
      stdio: ['ignore', 'pipe', 'inherit'], detached: true })
    start = await new Promise((res) => { let buf = ''; child.stdout.on('data', (d) => { buf += d; const m = /PROCSTART_EPOCH_MS: ([\d.]+)/.exec(buf); if (m) res(Number(m[1])) }) })
  } else {
    start = Date.now()
    child = spawn(CHROMIUM, ['--app=http://127.0.0.1:4996/notes', `--user-data-dir=${path.join(dir, 'profile')}`, '--ozone-platform-hint=auto', '--disable-extensions',
      '--no-first-run', '--no-default-browser-check', `--remote-debugging-port=${port}`], { stdio: 'ignore', detached: true })
  }
  try {
    const { r, browser } = await marker(port, Date.now() + 30000)
    const ms = r.at - start
    times.push(ms)
    console.log(`WEBCOLD ${mode} run ${i}: ${ms.toFixed(1)}${r.had ? ' (late: the marker was there before the watch began; an upper bound)' : ''}`)
    try { await browser.close() } catch {}
  } catch (e) {
    console.log(`WEBCOLD ${mode} run ${i}: failed (${e.message})`)
  }
  killTree(child)
  await sleep(2500)
}
if (api) killTree(api)
const sorted = [...times].sort((a, b) => a - b)
console.log(`WEBCOLD ${mode} median: ${sorted.length ? sorted[Math.floor(sorted.length / 2)].toFixed(1) : 'none'}`)
setTimeout(() => process.exit(0), 3000)
