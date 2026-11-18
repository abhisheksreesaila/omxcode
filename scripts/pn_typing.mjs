// Goal 74 M7: typing latency in Personal Note's page editor (CodeMirror 6) on a 1,000,000-character note, in headless
// Chromium, the way Personal Note's own benchmarks run it (its Vite dev server, a mocked /api). Read-only on its repo.
//
//   node scripts/pn_typing.mjs ~/Projects/personalnotev2          (run with cwd = that repo)
//
// The note is the same seeded Markdown pnote makes for PNOTE_PAGE_CHARS (examples/pnote/app.mojo seeded_page). The caret
// goes to the end (Ctrl+End), as pnote's does; then 200 keys are pressed one at a time ("native mojo is fast " over
// and over). A key's latency = from the keydown event to the frame after it (two requestAnimationFrame turns: the
// browser has laid out and painted). Also: frame intervals while typing (requestAnimationFrame gaps).
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import path from 'node:path'

const PN = path.resolve(process.argv[2] || '.')
const req = createRequire(path.join(PN, 'package.json'))
const { createServer } = await import(pathToFileURL(req.resolve('vite')).href)
const pw = await import(pathToFileURL(req.resolve('playwright')).href)
const chromium = pw.chromium || pw.default.chromium

function seededPage(n) {
  const words = ['the', 'note', 'canvas', 'mojo', 'fast', 'native', 'editor', 'ink', 'page', 'map', 'a', 'of', '**bold**', '*soft*', '`code`']
  let out = '# A long page\n'
  let s = 11 >>> 0
  let para = 0
  while (Buffer.byteLength(out) < n) {
    s = (s ^ (s << 13)) >>> 0
    s = (s ^ (s >>> 17)) >>> 0
    s = (s ^ (s << 5)) >>> 0
    out += words[s % words.length]
    if (s % 17 === 0) {
      para += 1
      out += '\n' + (para % 5 === 0 ? '- ' : (para % 23 === 0 ? `## Part ${para}\n` : ''))
    } else out += ' '
  }
  return out
}

const stat = (values) => {
  const sorted = [...values].sort((a, b) => a - b)
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0
  return { median: +at(0.5).toFixed(2), p95: +at(0.95).toFixed(2), max: +(sorted.at(-1) ?? 0).toFixed(2), n: sorted.length }
}

const markdown = seededPage(1_000_000)
const now = new Date().toISOString()
const summary = { id: 1, resourceId: 'res_page', revision: 1, noteType: 'page', title: 'A long page', notebookId: 1, createdAt: now, updatedAt: now }
const notebooks = [{ id: 1, resourceId: 'res_nb', revision: 1, name: 'Bench', color: '#76669a', noteCount: 1 }]
const content = { version: 1, markdown, ink: { marks: [], drawings: [] } }

const server = await createServer({ root: PN, configFile: path.join(PN, 'vite.config.js'), server: { port: 4561, strictPort: true, host: '127.0.0.1' }, logLevel: 'error' })
await server.listen()
const baseUrl = server.resolvedUrls.local[0]
const browser = await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage'] })
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 })
  const page = await context.newPage()
  page.on('pageerror', (error) => console.error('page error:', error.message))
  await page.route('**/api/**', async (route) => {
    const apiPath = new URL(route.request().url()).pathname.replace(/^\/api/, '')
    const json = (body) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) })
    if (apiPath === '/notebooks') return json(notebooks)
    if (apiPath === '/notes') return json([summary])
    if (apiPath === '/notes/1' && route.request().method() === 'GET') return json({ ...summary, content })
    return json({})
  })
  const t0 = Date.now()
  await page.goto(new URL('notes', baseUrl).href)
  await page.waitForSelector('.cm-content', { timeout: 120000 })
  await page.waitForTimeout(1500)
  const openMs = Date.now() - t0
  await page.click('.cm-content')
  await page.keyboard.press('Control+End')
  await page.waitForTimeout(500)
  await page.evaluate(() => {
    window.__work = []
    let t0 = 0
    let t1 = 0
    document.addEventListener('keydown', () => { t0 = performance.now(); t1 = t0 }, true)
    const done = () => { t1 = performance.now() }
    window.addEventListener('keydown', done)
    window.addEventListener('input', done)
    document.addEventListener('keydown', () => {
      requestAnimationFrame(() => setTimeout(() => {}, 0))
      requestAnimationFrame(() => {
        // (runs after the editor's own frame callbacks queued before it: CodeMirror measures in rAF)
        requestAnimationFrame(() => {})
        const ts = performance.now()
        void document.body.offsetHeight
        const te = performance.now()
        window.__work.push((t1 - t0) + (te - ts))
      })
    }, true)
    window.__lat = []
    window.__frames = []
    document.addEventListener('keydown', (e) => {
      const t = performance.now()
      requestAnimationFrame(() => requestAnimationFrame(() => window.__lat.push(performance.now() - t)))
    }, true)
    let last = performance.now()
    const tick = (time) => { window.__frames.push(time - last); last = time; window.__loop = requestAnimationFrame(tick) }
    window.__loop = requestAnimationFrame(tick)
  })
  const typed = 'native mojo is fast '
  for (let i = 0; i < 200; i += 1) {
    await page.keyboard.press(typed[i % typed.length] === ' ' ? 'Space' : typed[i % typed.length])
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r()))))
  }
  await page.waitForTimeout(300)
  const { lat, frames, length, work } = await page.evaluate(() => {
    cancelAnimationFrame(window.__loop)
    const docLength = () => {
      const el = document.querySelector('.cm-content')
      if (!el) return -1
      for (const k of Object.keys(el)) {
        const o = el[k]
        const v = o && (o.view || o.root?.view || (o.state ? o : null))
        if (v && v.state && v.state.doc) return v.state.doc.length
      }
      return -2
    }
    return { lat: window.__lat, frames: window.__frames.slice(2), length: docLength(), work: window.__work }
  })
  console.log(`Personal Note page editor (CodeMirror 6), headless Chromium, 1440x900 @1x`)
  console.log(`note: ${markdown.length} characters; editor reports ${length}; opened (goto → editor shown) in ${openMs} ms`)
  console.log(`keydown → painted frame (ms): ${JSON.stringify(stat(lat))}`)
  console.log(`main-thread work per key: the key's handlers + style and layout of the next frame (ms): ${JSON.stringify(stat(work))}`)
  console.log(`frame intervals while typing (ms): ${JSON.stringify(stat(frames))}`)
  await context.close()
} finally {
  await browser.close()
  await server.close()
}
