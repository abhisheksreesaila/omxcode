// Goal 82: the web Personal Note's own behaviour for focus mode (M1), pictures (M2) and print/export (M4), shot on a scratch database
// on its own port (4982: goal 79's ref.mjs and other workers use 4991). Made from docs/goals/79/ref.mjs (fonts, server, seeding: the
// same), the screens replaced. Run from ~/Projects/personalnotev2:
//
//   node <mojo-ui>/docs/goals/82/web.mjs <outdir> --do=focus|pictures|print [--dpr=1.6] [--files=a.png,b.jpg]
//
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
import { createHash } from 'node:crypto'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '../../..')
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const argv = process.argv.slice(2)
const OUT = path.resolve(argv.find((a) => !a.startsWith('--')) ?? path.join(ROOT, 'build/g82/web'))
const opt = Object.fromEntries(argv.filter((a) => a.startsWith('--')).map((a) => { const [k, v] = a.slice(2).split('='); return [k, v ?? '1'] }))
const DPR = Number(opt.dpr ?? 1.6)
const DUMP = !!opt.dump
const W = 1440, H = 900
fs.mkdirSync(OUT, { recursive: true })
const FIX = JSON.parse(fs.readFileSync(opt.fixture ? path.resolve(opt.fixture) : path.join(HERE, '../79/fixture.json'), 'utf8')) // (--fixture: another set of notes for a one-off comparison)

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
  'Literata': [['normal', 'literata/Literata[opsz,wght].ttf'], ['italic', 'literata/Literata-Italic[opsz,wght].ttf']],
  'Figtree': [['normal', 'figtree/Figtree[wght].ttf'], ['italic', 'figtree/Figtree-Italic[wght].ttf']],
}
const unknownFamilies = new Set()
const fontCss = (families) => families.map((fam) => (FACES[fam] ?? []).map(([style, file, weight]) =>
  `@font-face { font-family: "${fam}"; font-style: ${style}; font-weight: ${weight ?? '100 900'}; font-display: block; src: url("https://pn-fonts.local/${encodeURI(file)}") format("truetype"); }`).join('\n')).join('\n')
// (D-8053) --fonts=live, the default since: the page's own requests answered by Google Fonts, each answer kept in a folder
// (--font-cache) so every shot of a run and every later run has the same bytes. --fonts=local: the families of fonts/ whole
// (D-7901, until then): it gave the page weights and optical sizes the real one never loads (Source Serif 4 at 700).
const FONTS = opt.fonts ?? 'live'
const CACHE = path.resolve(opt['font-cache'] ?? path.join(ROOT, 'build/g79/webfonts'))
const fontLog = {}
async function live(url, ua) {
  const key = path.join(CACHE, createHash('sha1').update(url).digest('hex'))
  if (!fs.existsSync(key)) {
    const r = await fetch(url, { headers: { 'user-agent': ua } })
    if (!r.ok) throw new Error(`${r.status} ${url}`)
    fs.mkdirSync(CACHE, { recursive: true })
    fs.writeFileSync(key + '.tmp', Buffer.from(await r.arrayBuffer()))
    fs.writeFileSync(key + '.url', url)
    fs.renameSync(key + '.tmp', key)
  }
  const body = fs.readFileSync(key)
  fontLog[url] = createHash('sha1').update(body).digest('hex')
  return body
}
async function routeFonts(ctx, ua) {
  if (FONTS === 'live') {
    await ctx.route('https://fonts.googleapis.com/**', async (route) => {
      const u = new URL(route.request().url())
      for (const f of u.searchParams.getAll('family').map((x) => x.split(':')[0].replace(/\+/g, ' '))) if (!FACES[f]) unknownFamilies.add(f)
      route.fulfill({ contentType: 'text/css', body: await live(route.request().url(), ua), headers: { 'access-control-allow-origin': '*' } })
    })
    await ctx.route('https://fonts.gstatic.com/**', async (route) => route.fulfill({ contentType: 'font/woff2', body: await live(route.request().url(), ua), headers: { 'access-control-allow-origin': '*' } }))
  }
  else {
    await ctx.route('https://fonts.googleapis.com/**', (route) => {
      const u = new URL(route.request().url())
      const fams = u.searchParams.getAll('family').map((f) => f.split(':')[0].replace(/\+/g, ' '))
      for (const f of fams) if (!FACES[f]) unknownFamilies.add(f)
      route.fulfill({ contentType: 'text/css', body: fontCss(fams) })
    })
    await ctx.route('https://fonts.gstatic.com/**', (route) => route.abort())
  }
  await ctx.route('https://pn-fonts.local/**', (route) => {
    const file = decodeURI(new URL(route.request().url()).pathname.slice(1))
    route.fulfill({ contentType: 'font/ttf', body: fs.readFileSync(path.join(ROOT, 'fonts', file)), headers: { 'access-control-allow-origin': '*' } })
  })
}

// ---------- the web app on a scratch database ----------
const PORT = Number(opt.port ?? 4982)
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-ref-'))
const DB = path.join(scratch, 'v.db')
const env = { ...process.env, PERSONAL_NOTE_DB: DB, PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }
// (goal 82) --db=<file>: the web app opens a copy of a notes file another app wrote (and the media/ folder beside it), unseeded
const GIVEN = opt.db ? path.resolve(opt.db) : null
if (GIVEN) {
  spawnSync('python3', ['-c', 'import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close()', GIVEN, DB])
  const media = path.join(path.dirname(GIVEN), 'media')
  if (fs.existsSync(media)) fs.cpSync(media, path.join(scratch, 'media'), { recursive: true })
}
const BASE = `http://127.0.0.1:${PORT}`
const api = spawn('.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)], { env, stdio: 'ignore' })
const stop = () => { try { api.kill() } catch {} }
process.on('exit', stop)
const call = async (m, u, b) => (await fetch(`${BASE}/api${u}`, { method: m, headers: { 'content-type': 'application/json', 'x-personal-note': '1' }, body: b && JSON.stringify(b) })).json()
let up = false
for (let i = 0; i < 200 && !up; i++) { try { up = (await fetch(`${BASE}/api/notebooks`)).ok } catch {} if (!up) await new Promise((r) => setTimeout(r, 150)) }
if (!up) { console.error('ref: the web app did not start'); process.exit(2) }

const ids = {}
if (GIVEN) {
  const listed = await call('GET', '/notes')
  for (const n of (Array.isArray(listed) ? listed : listed.notes ?? [])) ids[n.title] = n.id
}
if (!GIVEN) for (const nb of FIX.notebooks) ids[`notebook:${nb.name}`] = (await call('POST', '/notebooks', { name: nb.name })).id
if (!GIVEN) for (const n of FIX.notes) {
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
// (D-7983, ruling A) on the Mac the reference comes from the Mac's own Chrome: PW_CHANNEL=chrome (Playwright drives the
// installed Chrome; nothing downloaded); the machine and browser are written beside the shots (made-by.json)
const browser = await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage'], ...(process.env.PW_CHANNEL ? { channel: process.env.PW_CHANNEL } : {}) })
fs.mkdirSync(OUT, { recursive: true })
fs.writeFileSync(path.join(OUT, 'made-by.json'), JSON.stringify({ browser: `${process.env.PW_CHANNEL || 'chromium'} ${browser.version()}`, platform: process.platform, arch: process.arch, dpr: DPR }, null, 1))
const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: DPR, reducedMotion: 'reduce' })
const UA = (await (async () => { const t = await ctx.newPage(); const u = await t.evaluate(() => navigator.userAgent); await t.close(); return u })()).replace('HeadlessChrome', 'Chrome')
await routeFonts(ctx, UA)
const p = await ctx.newPage()
await p.addInitScript(() => { if (!sessionStorage.getItem('pn-ref-skin-set')) { localStorage.setItem('personal-note:skin', 'paper'); sessionStorage.setItem('pn-ref-skin-set', '1') } })
await p.goto(`${BASE}/notes`)
await p.locator('#island-title').waitFor()
await p.evaluate(() => document.fonts.ready)
await p.waitForTimeout(1500)
const shotTimes = {}
// (every face the page asked for is in: font-display is swap, a picture before that shows the fallback)
const settled = async () => { for (let k = 0; k < 40; k++) { await p.evaluate(() => document.fonts.ready); await p.waitForTimeout(450); if (await p.evaluate(() => document.fonts.status === 'loaded' && ![...document.fonts].some((f) => f.status === 'loading'))) break } await p.waitForTimeout(450) }
const shot = async (name) => {
  await settled()
  await p.screenshot({ path: path.join(OUT, `${name}.png`) })
  shotTimes[name] = new Date().toISOString()
  fs.writeFileSync(path.join(OUT, `${name}.boxes.json`), JSON.stringify(await boxes(p), null, 1))
  await dump(p, name)
  console.log('ref: shot', name)
}
const sidebar = async (open) => { const is = await p.locator('.sidebar.open').count(); if (!!is !== open) { await p.click('#toggle-sidebar'); await p.waitForTimeout(600) } }
const openNote = async (title) => { await sidebar(true); await p.click(`[data-note-id="${ids[title]}"]`); await p.waitForTimeout(1500) }

const DO = opt.do ?? 'focus'
const facts = {}
const ctrl = process.platform === 'darwin' ? 'Meta' : 'Control'
if (DO === 'focus') {
  // canvas: the shot before, in focus (the hint gone), the focus face on hover (the word count), and after leaving (must equal before)
  await openNote('Garden plan'); await shot('panel'); await sidebar(false); await p.mouse.move(700, 500); await shot('canvas-before')
  await p.keyboard.press(`${ctrl}+Period`); await p.waitForTimeout(3200); await p.mouse.move(700, 500); await shot('canvas-focus')
  facts.canvasFocusClass = await p.evaluate(() => document.querySelector('.app-shell')?.classList.contains('focus-mode'))
  await p.mouse.move(720, 30); await p.waitForTimeout(400); await shot('canvas-focus-strip')
  facts.canvasCount = await p.evaluate(() => document.querySelector('#focus-count')?.textContent)
  facts.canvasTitle = await p.evaluate(() => document.querySelector('#focus-title')?.textContent)
  await p.mouse.move(700, 500); await p.keyboard.press(`${ctrl}+Period`); await p.waitForTimeout(900); await shot('canvas-after')
  // page
  await openNote('Lighthouse trip'); await sidebar(false); await p.mouse.move(700, 500); await shot('page-before')
  await p.keyboard.press(`${ctrl}+Period`); await p.waitForTimeout(3200); await p.mouse.move(700, 500); await shot('page-focus')
  await p.mouse.move(720, 30); await p.waitForTimeout(400)
  facts.pageCount = await p.evaluate(() => document.querySelector('#focus-count')?.textContent)
  await p.mouse.move(700, 500); await p.keyboard.press('Escape'); await p.waitForTimeout(900); await shot('page-after')
  // a mind map: no focus, said in a toast
  await openNote('Book mind map'); await sidebar(false)
  await p.keyboard.press(`${ctrl}+Period`); await p.waitForTimeout(300)
  facts.mapToast = await p.evaluate(() => document.querySelector('.toast, #toast')?.textContent?.trim() ?? '')
  facts.mapFocus = await p.evaluate(() => document.querySelector('.app-shell')?.classList.contains('focus-mode'))
}
const mediaFacts = () => {
  const dir = path.join(scratch, 'media')
  if (!fs.existsSync(dir)) return []
  fs.mkdirSync(path.join(OUT, 'media'), { recursive: true })
  return fs.readdirSync(dir).filter((f) => !f.endsWith('.part')).sort().map((f) => {
    const b = fs.readFileSync(path.join(dir, f))
    fs.copyFileSync(path.join(dir, f), path.join(OUT, 'media', f))
    return { name: f, bytes: b.length, sha256: createHash('sha256').update(b).digest('hex'), mode: (fs.statSync(path.join(dir, f)).mode & 0o777).toString(8) }
  })
}
if (DO === 'pictures') {
  // the files, all at once, through the dock's Image input (the web's own path: prepareImage, POST /api/media, addImages)
  const files = (opt.files ?? '').split(',').filter(Boolean)
  await openNote('Garden plan'); await sidebar(false); await p.mouse.move(700, 500); await shot('pictures-before')
  await p.setInputFiles('#image-file', files)
  for (let k = 0; k < 60; k++) { await p.waitForTimeout(250); if (mediaFacts().length >= Number(opt.expect ?? files.length)) break }
  await p.waitForTimeout(2500)  // (placed, then saved: the web's save debounce is 650 ms)
  await p.mouse.move(700, 500); await shot('pictures-after')
  facts.note = await call('GET', `/notes/${ids['Garden plan']}`)
  facts.media = mediaFacts()
  facts.toast = await p.evaluate(() => [...document.querySelectorAll('.toast, #toast, .save-state, #save-state')].map((e) => e.textContent.trim()).join(' | '))
}
if (DO === 'open') {
  await openNote(opt.note ?? 'Garden plan'); await sidebar(false); await p.mouse.move(700, 500); await p.waitForTimeout(1500); await shot('open')
  facts.note = await call('GET', `/notes/${ids[opt.note ?? 'Garden plan']}`)
  facts.media = mediaFacts()
}
if (DO === 'print') {
  await openNote(opt.note ?? 'Garden plan'); await sidebar(false)
  await p.mouse.move(700, 500); await shot('canvas')
  await p.click('#island-title'); await p.waitForTimeout(500); await shot('card'); await p.click('#share-print')
  const total = await p.evaluate(() => Number(document.querySelector('#print-summary-count')?.textContent || 0))
  for (let k = 0; k < 80; k++) { await p.waitForTimeout(250); if (await p.locator('.print-sheet-card img').count() >= total) break }
  const sheets = await p.evaluate(async () => Promise.all([...document.querySelectorAll('.print-sheet-card img')].map(async (img) => {
    const b = await (await fetch(img.src)).arrayBuffer()
    let s = ''; const u = new Uint8Array(b); for (let i = 0; i < u.length; i += 1) s += String.fromCharCode(u[i]); return btoa(s)
  })))
  sheets.forEach((b64, k) => fs.writeFileSync(path.join(OUT, `sheet-${k + 1}.png`), Buffer.from(b64, 'base64')))
  facts.sheets = sheets.length
  facts.layout = await p.evaluate(() => document.querySelector('#print-layout')?.textContent)
  await p.click('#close-print'); await p.waitForTimeout(400)
  await p.click('#island-title'); await p.waitForTimeout(500)
  const [download] = await Promise.all([p.waitForEvent('download'), p.click('#share-png')])
  await download.saveAs(path.join(OUT, 'picture.png'))
  facts.picture = download.suggestedFilename()
}
fs.writeFileSync(path.join(OUT, 'facts.json'), JSON.stringify(facts, null, 1))
fs.writeFileSync(path.join(OUT, 'meta.json'), JSON.stringify({ dpr: DPR, viewport: [W, H], chromium: browser.version(), ids, shots: shotTimes, when: new Date().toISOString(), do: DO }, null, 1))
await browser.close()
stop()
console.log('web82: done', OUT, JSON.stringify(facts))
process.exit(0)
