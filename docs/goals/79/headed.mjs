// Goal 79 M6 (review 5, M3): the web side of the race in a VISIBLE browser window, on the screen native is raced on. Preloaded
// with `node --import`, it changes nothing in Personal Note's own scripts: every chromium.launch is headed (Linux: the whole
// Chromium on Wayland, on the hidden test screen through scripts/testscreen, in a window that holds 1440×900; the Mac: its
// own Chrome, ANGLE on Metal, a window that holds 1440×900), and every context's scale is the screen's own, never an
// emulated one: asked for another (--dpr), it stops. Before the first page and after the last it says what the window is:
//   WEBSTATE: headed=1 dpr=1.6 raf=59.97 inner=2150x900 screen=2150x900 visible=visible focus=1 renderer=… browser=…
// dpr and raf are read in a page with nothing emulated. The check refuses to judge when they aren't the native window's
// scale and refresh. Its profile is Playwright's temporary one (TMPDIR says where); the person's browser isn't touched.
import path from 'node:path'
import fs from 'node:fs'
import os from 'node:os'
const { chromium } = await import(path.join(process.cwd(), 'node_modules/playwright/index.mjs'))
const MAC = process.platform === 'darwin'
const launch = chromium.launch.bind(chromium)
const at = process.env.WEB_WINDOW_AT || '' // x,y: the screen's corner the window opens on (the Mac with two screens)

function whole() { // (Playwright's own whole Chromium; its headless shell can't open a window)
  const dir = path.join(os.homedir(), '.cache/ms-playwright')
  const own = chromium.executablePath()
  if (fs.existsSync(own) && !/headless/.test(own)) return own
  const have = fs.readdirSync(dir).filter((d) => /^chromium-\d+$/.test(d)).sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]))
  for (const d of have) for (const p of ['chrome-linux64/chrome', 'chrome-linux/chrome']) if (fs.existsSync(path.join(dir, d, p))) return path.join(dir, d, p)
  return own
}

// (Linux: the test screen's own rule gives each window 1500×1000, its page area 1440×900 and more on the screen: scripts/testscreen, MOJOUI_TESTSCREEN_RULE)
async function fill(page) {
  await page.bringToFront()
}

async function state(browser, when) {
  const context = await browser._plainContext({ viewport: null })
  const page = await context.newPage()
  await fill(page)
  await page.goto('data:text/html,<title>state</title><body style="margin:0"><div id=d style="width:40px;height:40px;background:teal">')
  await page.bringToFront()
  await page.waitForTimeout(600)
  const s = await page.evaluate(() => new Promise((res) => {
    let n = 0, t0 = 0
    const d = document.getElementById('d')
    const step = (t) => {
      if (!t0) t0 = t; else n++
      d.style.transform = `translateX(${n % 200}px)`
      if (t - t0 > 2000) {
        const gl = document.createElement('canvas').getContext('webgl')
        const e = gl && gl.getExtension('WEBGL_debug_renderer_info')
        res({ dpr: devicePixelRatio, raf: n / ((t - t0) / 1000), inner: `${innerWidth}x${innerHeight}`, screen: `${screen.width}x${screen.height}`, visible: document.visibilityState, focus: document.hasFocus() ? 1 : 0, renderer: gl ? (e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : 'webgl') : 'none' })
      } else requestAnimationFrame(step)
    }
    requestAnimationFrame(step)
  }))
  await context.close()
  console.log(`WEBSTATE: when=${when} headed=1 dpr=${+s.dpr.toFixed(4)} raf=${s.raf.toFixed(2)} inner=${s.inner} screen=${s.screen} visible=${s.visible} focus=${s.focus} browser=${browser.version()} renderer=${s.renderer}`)
  return s
}

chromium.launch = async (opts = {}) => {
  let args = opts.args ?? []
  const o = { ...opts, headless: false }
  if (MAC) {
    args = args.filter((a) => !/vulkan|angle/i.test(a))
    args.push('--use-angle=metal', '--ignore-gpu-blocklist', '--enable-gpu-rasterization', '--window-size=1500,1080', ...(at ? [`--window-position=${at}`] : []))
    if (process.env.PW_CHANNEL) o.channel = process.env.PW_CHANNEL
  } else {
    args = args.filter((a) => !/vulkan/i.test(a)) // (ANGLE has no Vulkan on Wayland; headed it draws on the GPU through GL)
    args.push('--ozone-platform=wayland', '--use-angle=gl', '--ignore-gpu-blocklist', '--enable-gpu-rasterization')
    o.executablePath = whole()
    delete o.channel
  }
  o.args = [...args, '--disable-session-crashed-bubble', '--no-first-run', '--no-default-browser-check']
  const browser = await launch(o)
  browser._plainContext = browser.newContext.bind(browser)
  const first = await state(browser, 'start')
  browser.newContext = async (c = {}) => {
    const asked = c.deviceScaleFactor
    if (asked !== undefined && Math.abs(asked - first.dpr) > 0.005) throw new Error(`headed: the screen's scale is ${first.dpr}, the page asked for ${asked}: not like for like`)
    const [w, h] = first.inner.split('x').map(Number)
    if (c.viewport && (c.viewport.width > w || c.viewport.height > h)) throw new Error(`headed: the window's ${first.inner} doesn't hold ${c.viewport.width}x${c.viewport.height}`)
    const context = await browser._plainContext({ ...c, deviceScaleFactor: first.dpr })
    const open = context.newPage.bind(context)
    context.newPage = async () => { const page = await open(); await fill(page); return page }
    return context
  }
  browser.newPage = async (c = {}) => (await browser.newContext(c)).newPage()
  const close = browser.close.bind(browser)
  browser.close = async () => { try { await state(browser, 'end') } catch (e) { console.log('WEBSTATE: end not read: ' + e) } await close() }
  return browser
}
