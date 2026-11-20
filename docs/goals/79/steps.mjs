// Goal 79 M4: plays docs/goals/79/steps.json's web actions against the web Personal Note (its own dist/ build and API on a
// copy of the reference database), a shot after each step. Run from ~/Projects/personalnotev2:
//
//   node <mojo-ui>/docs/goals/79/steps.mjs <db> <outdir> [--dpr=1.6] [--only=N] [--dump]
//
// A web action is one of (coordinates in logical px of the 1440 × 900 window):
//   {"click": "<css selector>"}   {"at": [x, y]}   {"dbl": [x, y]}   {"drag": [[x0, y0], [x1, y1], …]}
//   {"key": "Control+z"}   {"type": "words"}   {"wait": ms}   "reload"
// After each step: wait for fonts and a quiet moment, then <outdir>/<NN>.png. At the end the app is given time to save.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { routeFonts } from './fonts.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '../../..')
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const argv = process.argv.slice(2)
const pos = argv.filter((a) => !a.startsWith('--'))
const opt = Object.fromEntries(argv.filter((a) => a.startsWith('--')).map((a) => { const k = a.slice(2).split('=')[0]; const v = a.includes('=') ? a.slice(a.indexOf('=') + 1) : '1'; return [k, v] }))
const DB = path.resolve(pos[0])
const OUT = path.resolve(pos[1])
const DPR = Number(opt.dpr ?? 1.6)
const W = 1440, H = 900
fs.mkdirSync(OUT, { recursive: true })
const STEPS = JSON.parse(fs.readFileSync(path.join(HERE, 'steps.json'), 'utf8')).steps

const PORT = Number(opt.port ?? 4992)
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-steps-'))
const env = { ...process.env, PERSONAL_NOTE_DB: DB, PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }
const BASE = `http://127.0.0.1:${PORT}`
const api = spawn('.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)], { env, stdio: 'ignore' })
process.on('exit', () => { try { api.kill() } catch {} })
let up = false
for (let i = 0; i < 200 && !up; i++) { try { up = (await fetch(`${BASE}/api/notebooks`)).ok } catch {} if (!up) await new Promise((r) => setTimeout(r, 150)) }
if (!up) { console.error('steps: the web app did not start'); process.exit(2) }

const browser = await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage'] })
const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: DPR, reducedMotion: 'reduce' })
await routeFonts(ctx, ROOT)
const p = await ctx.newPage()
await p.addInitScript(() => { if (!localStorage.getItem('pn-steps-skin-set')) { localStorage.setItem('personal-note:skin', 'paper'); localStorage.setItem('pn-steps-skin-set', '1') } })
const load = async () => {
  await p.goto(`${BASE}/notes`)
  await p.locator('#island-title').waitFor()
  await p.evaluate(() => document.fonts.ready)
  await p.waitForTimeout(1500)
}
await load()
for (let i = 0; i < STEPS.length; i++) {
  const s = STEPS[i]
  for (const a of s.web) {
    if (a === 'reload') { await p.waitForTimeout(1500); await load(); continue }
    if (a.click) await p.click(a.click)
    else if (a.at) await p.mouse.click(a.at[0], a.at[1])
    else if (a.dbl) await p.mouse.dblclick(a.dbl[0], a.dbl[1])
    else if (a.drag) {
      const pts = a.drag
      await p.mouse.move(pts[0][0], pts[0][1])
      await p.mouse.down()
      for (let k = 1; k < pts.length; k++) await p.mouse.move(pts[k][0], pts[k][1], { steps: 6 })
      await p.mouse.up()
    } else if (a.key) await p.keyboard.press(a.key)
    else if (a.type !== undefined) await p.keyboard.type(a.type, { delay: 20 })
    else if (a.wait) await p.waitForTimeout(a.wait)
    await p.waitForTimeout(250)
  }
  await p.evaluate(() => document.fonts.ready)
  await p.waitForTimeout(900)
  if (opt.probe) console.log('probe', i, JSON.stringify(await p.evaluate(opt.probe)))
  await p.screenshot({ path: path.join(OUT, `${String(i).padStart(2, '0')}.png`) })
  console.log('steps: web', i, s.name)
}
await p.waitForTimeout(2500) // (the app saves a moment after the last edit)
await browser.close()
process.exit(0)
