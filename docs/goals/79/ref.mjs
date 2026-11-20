// Goal 79 M0: the reference, from the web Personal Note itself (its own dist/ build, served by its own API on a scratch
// database). Run from ~/Projects/personalnotev2 (it borrows that checkout's Playwright and Python venv):
//
//   node <mojo-ui>/docs/goals/79/ref.mjs <outdir> [--dpr=1.6] [--dump]
//
// Writes into <outdir>:
//   <screen>.png          the window, 1440×900 logical at the native run's device scale (1.6 on the Linux test screen)
//   <screen>.boxes.json   {name: [x, y, w, h]} in logical px, read from the DOM with getBoundingClientRect
//   textwidths.json       M1's lines (fixture.textlines) as Chromium lays them out: width in device px
//   pn.db                 the seeded scratch database, copied before any screen is shot (the native app opens a copy)
//   meta.json             dpr, viewport, Chromium's version, the note ids
// --dump also writes dom-<screen>.txt (every visible element with an id, aria-label or class) for choosing names.
//
// Fonts: the web app asks fonts.googleapis.com for its faces at run time. The shooter answers those requests with the
// same OFL families from <mojo-ui>/fonts (D-7901), so the web and the native app draw from identical files and the
// shots don't depend on the network. Nothing else in the page is touched.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '../../..')
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const argv = process.argv.slice(2)
const OUT = path.resolve(argv.find((a) => !a.startsWith('--')) ?? path.join(ROOT, 'build/g79/ref'))
const opt = Object.fromEntries(argv.filter((a) => a.startsWith('--')).map((a) => { const [k, v] = a.slice(2).split('='); return [k, v ?? '1'] }))
const DPR = Number(opt.dpr ?? 1.6)
const DUMP = !!opt.dump
const W = 1440, H = 900
fs.mkdirSync(OUT, { recursive: true })
const FIX = JSON.parse(fs.readFileSync(path.join(HERE, 'fixture.json'), 'utf8'))

// ---------- fonts: Google Fonts' css2 answered from fonts/ ----------
const FACES = {
  'Geist': [['normal', 'geist/Geist[wght].ttf'], ['italic', 'geist/Geist-Italic[wght].ttf']],
  'Geist Mono': [['normal', 'geistmono/GeistMono[wght].ttf']],
  'Bricolage Grotesque': [['normal', 'bricolagegrotesque/BricolageGrotesque[opsz,wdth,wght].ttf']],
  'IBM Plex Sans': [['normal', 'ibmplexsans/IBMPlexSans[wdth,wght].ttf'], ['italic', 'ibmplexsans/IBMPlexSans-Italic[wdth,wght].ttf']],
  'IBM Plex Mono': [['normal', 'ibmplexmono/IBMPlexMono-Regular.ttf', 400], ['normal', 'ibmplexmono/IBMPlexMono-Medium.ttf', 500], ['normal', 'ibmplexmono/IBMPlexMono-SemiBold.ttf', 600]],
  'Source Serif 4': [['normal', 'sourceserif4/SourceSerif4[opsz,wght].ttf'], ['italic', 'sourceserif4/SourceSerif4-Italic[opsz,wght].ttf']],
  'Instrument Serif': [['normal', 'instrumentserif/InstrumentSerif-Regular.ttf', 400], ['italic', 'instrumentserif/InstrumentSerif-Italic.ttf', 400]],
  'Caveat': [['normal', 'caveat/Caveat[wght].ttf']],
}
const fontCss = (families) => families.map((fam) => (FACES[fam] ?? []).map(([style, file, weight]) =>
  `@font-face { font-family: "${fam}"; font-style: ${style}; font-weight: ${weight ?? '100 900'}; font-display: block; src: url("https://pn-fonts.local/${encodeURI(file)}") format("truetype"); }`).join('\n')).join('\n')
async function routeFonts(ctx) {
  await ctx.route('https://fonts.googleapis.com/**', (route) => {
    const u = new URL(route.request().url())
    const fams = u.searchParams.getAll('family').map((f) => f.split(':')[0].replace(/\+/g, ' '))
    route.fulfill({ contentType: 'text/css', body: fontCss(fams) })
  })
  await ctx.route('https://fonts.gstatic.com/**', (route) => route.abort())
  await ctx.route('https://pn-fonts.local/**', (route) => {
    const file = decodeURI(new URL(route.request().url()).pathname.slice(1))
    route.fulfill({ contentType: 'font/ttf', body: fs.readFileSync(path.join(ROOT, 'fonts', file)), headers: { 'access-control-allow-origin': '*' } })
  })
}

// ---------- the web app on a scratch database ----------
const PORT = Number(opt.port ?? 4991)
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-ref-'))
const DB = path.join(scratch, 'v.db')
const env = { ...process.env, PERSONAL_NOTE_DB: DB, PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }
const BASE = `http://127.0.0.1:${PORT}`
const api = spawn('.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)], { env, stdio: 'ignore' })
const stop = () => { try { api.kill() } catch {} }
process.on('exit', stop)
const call = async (m, u, b) => (await fetch(`${BASE}/api${u}`, { method: m, headers: { 'content-type': 'application/json', 'x-personal-note': '1' }, body: b && JSON.stringify(b) })).json()
let up = false
for (let i = 0; i < 200 && !up; i++) { try { up = (await fetch(`${BASE}/api/notebooks`)).ok } catch {} if (!up) await new Promise((r) => setTimeout(r, 150)) }
if (!up) { console.error('ref: the web app did not start'); process.exit(2) }

const ids = {}
for (const nb of FIX.notebooks) ids[`notebook:${nb.name}`] = (await call('POST', '/notebooks', { name: nb.name })).id
for (const n of FIX.notes) {
  const made = await call('POST', '/notes', { title: n.title, noteType: n.noteType })
  ids[n.title] = made.id
  if (n.content) await call('PUT', `/notes/${made.id}`, { title: n.title, revision: made.revision, content: n.content })
}
// the seeded database, before any screen: what the native app opens (WAL folded in first)
await new Promise((r) => setTimeout(r, 300))
for (const f of ['pn.db', 'pn.db-wal', 'pn.db-shm']) fs.rmSync(path.join(OUT, f), { force: true })
spawnSyncPy(`import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close()`, DB, path.join(OUT, 'pn.db'))
function spawnSyncPy(code, ...a) {
  const out = spawnSync('.venv/bin/python', ['-c', code, ...a], { encoding: 'utf8' })
  if (out.status !== 0) { console.error(out.stderr); process.exit(2) }
}

// ---------- named elements ----------
// Every element on screen (checkVisibility with opacity and visibility, inside the viewport) that has an id, an
// aria-label, or one of CLASSES, named by the first of: #id, [aria-label], .class:text (duplicates get @2, @3…).
// Rows of the notes panel are row:<title>. Inside the editor (CodeMirror) and the canvas engine nothing is named: the
// SSIM bar covers their insides.
const CLASSES = ['brand-row', 'brand-mark', 'brand-name', 'sec-head', 'sec-ic', 'nav-row', 'empty-notebook', 'skin-label', 'sidebar-footer',
  'island', 'isl-face', 'page-desk', 'page-toolbar', 'page-tool-group', 'page-paper', 'page-editor', 'page-sheet-mark', 'tool-dock', 'dock-divider',
  'mindmap-hint', 'mindmap-zoom', 'mindmap-zoom-label', 'omni-chip', 'omni-body', 'spotlight', 'spotlight-input-row', 'search-result', 'omni-row',
  'omni-preview', 'search-preview', 'isl-meta', 'isl-grid', 'isl-btn', 'sw-nav', 'sw-pane', 'sw-head', 'sw-title', 'sw-blurb', 'sw-item', 'sw-skin', 'sw-art', 'sw-search', 'sw-group']
async function boxes(page) {
  return page.evaluate(({ CLASSES }) => {
    const out = {}
    const seen = new Map()
    const vw = innerWidth, vh = innerHeight
    const text = (el) => el.textContent.trim().replace(/\s+/g, ' ').slice(0, 40)
    for (const el of document.querySelectorAll('body *')) {
      if (el.closest('.cm-content, .cm-gutters, .leafer-app-view, .cm-scroller > :not(.cm-content)')) continue
      const cls = typeof el.className === 'string' ? el.className.split(/\s+/) : []
      const label = el.getAttribute('aria-label')
      const known = cls.find((c) => CLASSES.includes(c))
      let name = null
      if (el.matches('[data-note-id]') && text(el)) name = `row:${text(el)}`
      else if (el.id) name = `#${el.id}`
      else if (label) name = `[${label}]`
      else if (known) name = `.${known}` + (text(el) && !el.querySelector(CLASSES.map((c) => '.' + c).join(',')) ? `:${text(el)}` : '')
      if (!name) continue
      if (!el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue
      const r = el.getBoundingClientRect()
      if (r.width < 1 || r.height < 1 || r.right <= 0 || r.bottom <= 0 || r.left >= vw || r.top >= vh) continue
      const n = (seen.get(name) ?? 0) + 1
      seen.set(name, n)
      out[n > 1 ? `${name}@${n}` : name] = [+r.x.toFixed(2), +r.y.toFixed(2), +r.width.toFixed(2), +r.height.toFixed(2)]
    }
    return out
  }, { CLASSES })
}
async function dump(page, name) {
  if (!DUMP) return
  const txt = await page.evaluate(() => [...document.querySelectorAll('*')].filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && (e.id || e.getAttribute('aria-label') || (typeof e.className === 'string' && e.className)) })
    .map((e) => { const r = e.getBoundingClientRect(); const d = e.parentElement ? [...e.parentElement.children].indexOf(e) : 0; return `${'  '.repeat(Math.min(12, (function depth(n) { let k = 0; while (n.parentElement) { k++; n = n.parentElement } return k })(e)))}${e.tagName.toLowerCase()}#${e.id} .${typeof e.className === 'string' ? e.className : ''} [${e.getAttribute('aria-label') ?? ''}] ${r.x.toFixed(1)},${r.y.toFixed(1)} ${r.width.toFixed(1)}x${r.height.toFixed(1)} "${(e.childElementCount ? '' : e.textContent.trim().slice(0, 40))}"` }).join('\n'))
  fs.writeFileSync(path.join(OUT, `dom-${name}.txt`), txt)
}

// ---------- the screens ----------
const browser = await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage'] })
const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: DPR, reducedMotion: 'reduce' })
await routeFonts(ctx)
const p = await ctx.newPage()
await p.addInitScript(() => { if (!sessionStorage.getItem('pn-ref-skin-set')) { localStorage.setItem('personal-note:skin', 'paper'); sessionStorage.setItem('pn-ref-skin-set', '1') } })
await p.goto(`${BASE}/notes`)
await p.locator('#island-title').waitFor()
await p.evaluate(() => document.fonts.ready)
await p.waitForTimeout(1500)
const shot = async (name) => {
  await p.evaluate(() => document.fonts.ready)
  await p.waitForTimeout(900)
  await p.screenshot({ path: path.join(OUT, `${name}.png`) })
  fs.writeFileSync(path.join(OUT, `${name}.boxes.json`), JSON.stringify(await boxes(p), null, 1))
  await dump(p, name)
  console.log('ref: shot', name)
}
const sidebar = async (open) => { const is = await p.locator('.sidebar.open').count(); if (!!is !== open) { await p.click('#toggle-sidebar'); await p.waitForTimeout(600) } }
const openNote = async (title) => { await sidebar(true); await p.click(`[data-note-id="${ids[title]}"]`); await p.waitForTimeout(1500) }
await openNote('Lighthouse trip'); await shot('page-sidebar')
await sidebar(false); await shot('page')
await openNote('Garden plan'); await sidebar(false); await shot('canvas')
await openNote('Book mind map'); await sidebar(false); await shot('mindmap')
await p.click('#search-button'); await p.locator('#search-input').waitFor(); await p.fill('#search-input', 'li'); await shot('search')
await p.keyboard.press('Escape'); await p.waitForTimeout(400)
await p.click('#island-title'); await shot('island-card')
await p.click('#top-properties'); await p.waitForTimeout(800); await shot('settings')
for (const s of ['night', 'crayon']) {
  await p.evaluate((v) => localStorage.setItem('personal-note:skin', v), s)
  await p.goto(`${BASE}/notes`); await p.locator('#island-title').waitFor(); await p.evaluate(() => document.fonts.ready); await p.waitForTimeout(1500)
  await openNote('Lighthouse trip'); await shot(`page-sidebar-${s}`)
}

// ---------- M1's lines, as Chromium lays them out ----------
const tp = await ctx.newPage()
await tp.route('https://pn-ref.local/', (route) => route.fulfill({ contentType: 'text/html', body: `<!doctype html><meta charset="utf-8"><style>${fontCss(Object.keys(FACES))} body{margin:0} span{white-space:pre;font-kerning:normal}</style><body></body>` }))
await tp.goto('https://pn-ref.local/')
const widths = await tp.evaluate(async (lines) => {
  for (const l of lines) { const s = document.createElement('span'); s.id = l.id; s.textContent = l.text; Object.assign(s.style, { fontFamily: `"${l.family}"`, fontWeight: l.weight, fontStyle: l.style, fontSize: `${l.size}px`, position: 'absolute', left: '0', top: '0' }); document.body.appendChild(document.createElement('div')).appendChild(s) }
  await document.fonts.ready
  for (const l of lines) await document.fonts.load(`${l.style} ${l.weight} ${l.size}px "${l.family}"`, l.text)
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
  return Object.fromEntries(lines.map((l) => [l.id, document.getElementById(l.id).getBoundingClientRect().width * devicePixelRatio]))
}, FIX.textlines)
fs.writeFileSync(path.join(OUT, 'textwidths.json'), JSON.stringify({ dpr: DPR, widths }, null, 1))
fs.writeFileSync(path.join(OUT, 'meta.json'), JSON.stringify({ dpr: DPR, viewport: [W, H], chromium: browser.version(), ids, when: new Date().toISOString() }, null, 1))
await browser.close()
stop()
console.log('ref: done', OUT)
process.exit(0)
