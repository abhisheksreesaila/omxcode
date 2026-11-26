// probe c29 (goal 79): PN's scripts/benchmark-f034.mjs with PAUSE_MS before undo and before redo, and each step's time printed. Nothing else changed.
// F-034: one benchmark for the performance pass, on the 600-object benchmark note and on the 5,000+ object stress note, at devicePixelRatio 1 and 2.
// Real mouse, pen and keyboard input driven through the browser (Playwright), headless Chromium; the Vite dev server (port 4802) with /api mocked.
// Frame time = the gap between requestAnimationFrame callbacks (16.7 ms is 60 fps). "to frame" = from the input event to the frame after it.
// Scenarios: open, pan, zoom, drag one object, drag 40, undo/redo, pen (stroke at 100%), typing.
//
//   node scripts/benchmark-f034.mjs [--note=600|stress|both] [--dpr=1|2] [--count=5400] [--grid=4x4] [--flags='{"pageBitmaps":false}'] [--out=file.json] [--only=pan,zoom]
//
// `--flags` is handed to the app before it starts (window.__pnPerf, see src/modules/canvas-leafer/perf.js), so one optimization can be measured off and on.
// Add --gpu to start Chromium with the GPU (ANGLE/Vulkan) instead of the software rasteriser the headless default uses.
import fs from 'node:fs'
import { createServer } from 'vite'
import { chromium } from 'playwright'
import { COLUMNS, ROWS, generateNote } from './benchmark-note.mjs'
import { generateStressNote } from '../src/modules/speedtest/stress-note.js'
import { assertPortsFree, basePort } from './lib/ports.mjs'

const args = Object.fromEntries(process.argv.slice(2).map((arg) => { const [key, ...value] = arg.replace(/^--/, '').split('='); return [key, value.length ? value.join('=') : 'true'] }))
const dprs = args.dpr ? [Number(args.dpr)] : [1, 2]
const which = args.note ?? 'both'
const flags = args.flags ? JSON.parse(args.flags) : null
const only = args.only ? new Set(args.only.split(',')) : null
const PORT = basePort(4802)
await assertPortsFree([PORT])
const now = new Date().toISOString()
const summary = { id: 1, resourceId: 'res_bench', revision: 1, noteType: 'canvas', title: 'Benchmark note', notebookId: 1, createdAt: now, updatedAt: now }

const notes = []
if (which === '600' || which === 'both') notes.push({ name: '600 objects', content: generateNote(), pageState: { columns: COLUMNS, rows: ROWS } })
const [gridColumns, gridRows] = (args.grid ?? '4x4').split('x').map(Number)
if (which === 'stress' || which === 'both') { const stress = generateStressNote(Number(args.count ?? 5400), { columns: gridColumns, rows: gridRows }); notes.push({ name: `${stress.objects} objects (stress)`, content: stress.content, pageState: stress.pageState }) }

async function mockApi(page, note) {
  await page.route('**/api/**', async (route) => {
    const apiPath = new URL(route.request().url()).pathname.replace(/^\/api/, '')
    const json = (body) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) })
    if (apiPath === '/notebooks') return json([{ id: 1, resourceId: 'res_nb', revision: 1, name: 'Bench', color: '#76669a', noteCount: 1 }])
    if (apiPath === '/notes') return json([summary])
    if (apiPath === '/notes/1' && route.request().method() === 'GET') return json({ ...summary, content: note.content, pageState: note.pageState })
    return json({ revision: 2, resourceId: 'res_bench' })
  })
}

const at = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0
const stat = (values) => {
  const sorted = [...values].sort((a, b) => a - b)
  return { p50: +at(sorted, 0.5).toFixed(1), p95: +at(sorted, 0.95).toFixed(1), max: +(sorted.at(-1) ?? 0).toFixed(1), n: sorted.length }
}
const nextFrame = (page) => page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => resolve())))

async function frames(page, name, run) {
  await page.evaluate(() => {
    window.__frames = []
    let last = performance.now()
    const tick = (time) => { window.__frames.push(time - last); last = time; window.__loop = requestAnimationFrame(tick) }
    window.__loop = requestAnimationFrame(tick)
  })
  await run()
  const list = await page.evaluate(() => { cancelAnimationFrame(window.__loop); return window.__frames.slice(2) })
  return { scenario: name, ...stat(list), slow: list.filter((f) => f > 20).length }
}

// frame gaps and input-to-frame latency together
async function latency(page, name, events, run) {
  await page.evaluate((types) => {
    window.__lat = []
    window.__frames = []
    let last = performance.now()
    const tick = (time) => { window.__frames.push(time - last); last = time; window.__loop = requestAnimationFrame(tick) }
    window.__loop = requestAnimationFrame(tick)
    window.__probe = (event) => { const stamp = Math.abs(event.timeStamp - performance.now()) < 1000 ? event.timeStamp : performance.now(); requestAnimationFrame(() => setTimeout(() => window.__lat.push(performance.now() - stamp), 0)) }
    for (const type of types) window.addEventListener(type, window.__probe, true)
  }, events)
  await run()
  const { lat, list } = await page.evaluate((types) => { cancelAnimationFrame(window.__loop); for (const type of types) window.removeEventListener(type, window.__probe, true); return { lat: window.__lat, list: window.__frames.slice(2) } }, events)
  return { frame: { scenario: `${name}: frame gaps`, ...stat(list), slow: list.filter((f) => f > 20).length }, toFrame: { scenario: `${name}: input to frame`, ...stat(lat), slow: lat.filter((f) => f > 33).length } }
}

async function wheelPan(page) {
  await page.mouse.move(700, 450)
  for (let i = 0; i < 120; i += 1) { await page.mouse.wheel(i < 60 ? 6 : -6, i < 60 ? 24 : -24); await nextFrame(page) }
}

async function dragPath(page, from, to, steps = 90) {
  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  for (let i = 1; i <= steps; i += 1) {
    const t = i / steps
    await page.mouse.move(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t + Math.sin(t * Math.PI * 2) * 40)
    await nextFrame(page)
  }
  await page.mouse.up()
  await nextFrame(page)
}

async function visibleObjects(page, types) {
  return await page.evaluate((wanted) => {
    const { leaferCanvas, leaferEdits } = window.__personalNote
    const scene = leaferCanvas()
    const host = document.querySelector('#leafer-host').getBoundingClientRect()
    const out = []
    for (const object of leaferEdits.doc.objects) {
      if (!wanted.includes(object.type)) continue
      const box = scene.screenBox(object.id)
      if (!box) continue
      const x = host.left + box.x
      const y = host.top + box.y
      if (x > 260 && y > 120 && x + box.width < host.right - 80 && y + box.height < host.bottom - 140 && box.width > 12 && box.height > 12) out.push({ id: object.id, x: x + box.width / 2, y: y + box.height / 2, left: x, top: y, right: x + box.width, bottom: y + box.height })
    }
    return out
  }, types)
}

const screenOf = (page, x, y) => page.evaluate(([px, py]) => {
  const view = window.__personalNote.leaferCanvas().view()
  const host = document.querySelector('#leafer-host').getBoundingClientRect()
  return { x: host.left + view.x + px * view.scale, y: host.top + view.y + py * view.scale }
}, [x, y])

async function penStroke(page, cdp, points) {
  const send = (kind, point, force) => cdp.send('Input.dispatchMouseEvent', { type: kind, x: point.x, y: point.y, button: kind === 'mouseMoved' ? 'none' : 'left', buttons: kind === 'mouseReleased' ? 0 : 1, clickCount: kind === 'mouseMoved' ? 0 : 1, pointerType: 'pen', force })
  await send('mouseMoved', points[0], 0)
  await send('mousePressed', points[0], 0.5)
  for (let i = 1; i < points.length; i += 1) { await send('mouseMoved', points[i], 0.3 + 0.6 * Math.sin((i / points.length) * Math.PI)); await nextFrame(page) }
  await send('mouseReleased', points.at(-1), 0)
  await nextFrame(page)
}

const TEXT = 'The quick brown fox jumps over the lazy dog, and then types a few more words to fill a line or two. '

async function runNote(browser, note, dpr) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: dpr })
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', (error) => errors.push(error.message))
  if (flags) await page.addInitScript((value) => { window.__pnPerf = value }, flags)
  await mockApi(page, note)
  const t0 = performance.now()
  await page.goto(`http://127.0.0.1:${PORT}/notes`)
  await page.waitForFunction(() => document.documentElement.dataset.leaferSettled, null, { timeout: 120000 })
  const openMs = performance.now() - t0
  await page.waitForTimeout(1200)
  const setup = await page.evaluate(() => ({ openingZoom: +window.__personalNote.getCanvasScale().toFixed(2), ...window.__personalNote.leaferCanvas().stats() }))
  const rows = [{ scenario: 'open (to first settled frame, cold)', p50: +openMs.toFixed(0), p95: null, max: null, n: 1 }]
  const run = (name) => !only || only.has(name)
  const cdp = await context.newCDPSession(page)

  const zoomedOut = () => page.evaluate(() => {
    const { viewSize, state, getCanvasScale, setCanvasViewportOffset } = window.__personalNote
    state.canvasZoom = 0.3 / state.displayScale // 30%: below the 60% the page bitmaps are for
    setCanvasViewportOffset(24, 24)
    return getCanvasScale()
  })
  const at100 = () => page.evaluate(() => {
    const { viewSize, state, getCanvasScale, setCanvasViewportOffset } = window.__personalNote
    state.canvasZoom = 1
    setCanvasViewportOffset(viewSize.width / 2 - 430 * getCanvasScale(), 104)
  })
  if (run('pan') || run('zoom')) {
    await zoomedOut()
    await page.waitForTimeout(600)
    if (flags?.pageBitmaps !== 'off') { await wheelPan(page); await page.waitForTimeout(3500) }
  }
  if (run('pan')) rows.push(await frames(page, 'pan, zoomed out to 30%', () => wheelPan(page)))
  if (run('zoom')) {
    await zoomedOut()
    await page.waitForTimeout(300)
    await page.mouse.move(700, 450)
    rows.push(await frames(page, 'zoom (ctrl+wheel) from 30%', async () => {
      await page.keyboard.down('Control')
      for (let i = 0; i < 120; i += 1) { await page.mouse.wheel(0, i < 60 ? -12 : 12); await nextFrame(page) }
      await page.keyboard.up('Control')
    }))
    await page.waitForTimeout(500)
  }
  await at100()
  await page.waitForTimeout(600)
  if (run('pan')) rows.push(await frames(page, 'pan at 100%', () => wheelPan(page)))

  const shapes = await visibleObjects(page, ['shape', 'sticky'])
  const target = shapes[Math.floor(shapes.length / 2)]
  if (target && run('drag')) {
    await page.mouse.click(target.x, target.y)
    rows.push(await frames(page, 'drag one object (100%)', () => dragPath(page, { x: target.x, y: target.y }, { x: target.x + 160, y: target.y + 90 })))
    const crowd = (await visibleObjects(page, ['shape', 'sticky', 'text', 'image'])).slice(0, 40)
    await page.evaluate((ids) => window.__personalNote.leaferCanvas().select(ids), crowd.map((entry) => entry.id))
    await nextFrame(page)
    const lead = (await visibleObjects(page, ['shape', 'sticky', 'text', 'image'])).find((entry) => entry.id === crowd[0].id) ?? crowd[0]
    rows.push(await frames(page, `drag ${crowd.length} selected objects (100%)`, () => dragPath(page, { x: lead.x, y: lead.y }, { x: lead.x + 120, y: lead.y + 70 }, 60)))
    await page.evaluate(() => window.__personalNote.leaferCanvas().clearSelection())
  }

  if (run('undo')) {
    // thirty separate drags, then undo and redo them; each timed from the call to the return, and to the frame after it
    const movers = (await visibleObjects(page, ['shape', 'sticky', 'text'])).slice(0, 30)
    for (const mover of movers) {
      const current = (await visibleObjects(page, ['shape', 'sticky', 'text'])).find((entry) => entry.id === mover.id)
      if (!current) continue
      await page.mouse.click(current.x, current.y)
      await dragPath(page, { x: current.x, y: current.y }, { x: current.x + 25, y: current.y + 15 }, 6)
    }
    await page.evaluate(() => window.__personalNote.leaferCanvas().clearSelection())
    const recorded = await page.evaluate(() => window.__personalNote.leaferEdits.stats().undoSteps)
    if (recorded < 20) console.log(`  (only ${recorded} undo steps recorded)`)
    for (const kind of ['undo', 'redo']) {
      if (Number(process.env.PAUSE_MS || 0) > 0) await page.waitForTimeout(Number(process.env.PAUSE_MS))  // (probe c29: the bench's idle before a step, as native's)
      const times = await page.evaluate(async (which) => {
        const out = []
        const edits = window.__personalNote.leaferEdits
        for (let i = 0; i < 25; i += 1) {
          const t = performance.now()
          edits[which]()
          const sync = performance.now() - t
          await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)))
          out.push([sync, performance.now() - t])
        }
        return out
      }, kind)
      rows.push({ scenario: `${kind} (25 steps, the call)`, ...stat(times.map((t) => t[0])) })
      rows.push({ scenario: `${kind} (25 steps, to the frame after)`, ...stat(times.map((t) => t[1])) })
      console.log('STEPS ' + kind + ' ' + JSON.stringify(times.map((t) => +t[1].toFixed(1))))
    }
    await page.waitForTimeout(700)
  }

  if (run('pen')) {
    await page.click('[data-tool="pen"]')
    await page.waitForTimeout(200)
    const origin = await screenOf(page, 260, 300)
    const points = (index) => Array.from({ length: 61 }, (_, i) => ({ x: origin.x + index * 14 + (360 * i) / 60, y: origin.y + index * 60 + Math.sin((i / 60) * Math.PI * 2) * 50 }))
    const out = await latency(page, 'pen strokes (100%)', ['pointermove'], async () => { for (let s = 0; s < 4; s += 1) await penStroke(page, cdp, points(s)) })
    rows.push(out.frame, out.toFrame)
    await page.click('[data-tool="select"]').catch(() => {})
  }

  if (run('type')) {
    const id = await page.evaluate(() => window.__personalNote.leaferEdits.doc.objects.findLast((o) => o.type === 'text')?.id)
    await page.evaluate((target) => window.__personalNote.leaferCanvas().editText(target), id)
    await page.waitForSelector('.leafer-text-editor', { timeout: 10000 }).catch(() => {})
    await page.keyboard.press('Control+End')
    // The browser's own event timing (keydown to the next paint, in 8 ms steps; under 16 ms is not reported and counts as 16): a probe of ours
    // that waits for a timer after the frame reads late in a busy test browser and says nothing about the page.
    await page.evaluate(() => { window.__keys = []; new PerformanceObserver((list) => { for (const e of list.getEntries()) if (e.name === 'keydown') window.__keys.push(e.duration) }).observe({ type: 'event', durationThreshold: 16 }) })
    const typed = await frames(page, 'typing 80 characters: frame gaps', async () => { for (let i = 0; i < 80; i += 1) { await page.keyboard.type(TEXT[i % TEXT.length]); await nextFrame(page) } })
    await page.waitForTimeout(300)
    const keys = await page.evaluate(() => window.__keys)
    rows.push(typed, { scenario: 'typing 80 characters: key to paint', ...stat([...keys, ...Array(Math.max(0, 80 - keys.length)).fill(16)]), slow: keys.filter((d) => d > 32).length })
    await page.keyboard.press('Escape')
  }
  await context.close()
  return { setup, rows, errors }
}

const server = await createServer({ server: { port: PORT, strictPort: true, host: '127.0.0.1', proxy: { '/api': 'http://127.0.0.1:4809' } }, logLevel: 'error' })
await server.listen()
const launchArgs = ['--disable-dev-shm-usage', ...(args.gpu ? ['--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'] : [])]
const browser = await chromium.launch({ headless: true, args: launchArgs })
const results = []
try {
  for (const note of notes) {
    for (const dpr of dprs) {
      const result = await runNote(browser, note, dpr)
      results.push({ note: note.name, dpr, flags, ...result })
      console.log(`\n== ${note.name}, devicePixelRatio ${dpr}${flags ? ` flags ${JSON.stringify(flags)}` : ''}: ${result.setup.drawn} objects drawn, opens at ${result.setup.openingZoom}x ==`)
      console.table(result.rows)
      if (result.errors.length) console.log('page errors:', result.errors.join(' | '))
    }
  }
} finally {
  await browser.close()
  await server.close()
}
if (args.out) fs.writeFileSync(args.out, JSON.stringify({ when: new Date().toISOString(), browser: browser.version?.(), results }, null, 1))
