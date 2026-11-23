// Goal 79 M6 on the Mac (D-7986): Personal Note's own benchmarks launch Chromium with Linux's GPU flags (--use-angle=vulkan),
// which on macOS fall back to SwiftShader, a software renderer: the web would race without its GPU. Preloaded with
// `node --import`, this gives the web its best on the Mac without touching PN's scripts: every chromium.launch drops the
// Vulkan flags for ANGLE on Metal (the Apple GPU) and, with PW_CHANNEL set, drives that installed browser (ruling A:
// the Mac's own Chrome). It prints the WebGL renderer the first page reports, so the race says what it ran on.
import { chromium } from 'playwright'

const launch = chromium.launch.bind(chromium)
chromium.launch = async (opts = {}) => {
  const args = (opts.args ?? []).filter((a) => !/vulkan/i.test(a))
  args.push('--use-angle=metal', '--ignore-gpu-blocklist', '--enable-gpu-rasterization')
  const browser = await launch({ ...opts, args, ...(process.env.PW_CHANNEL ? { channel: process.env.PW_CHANNEL } : {}) })
  try {
    const page = await browser.newPage()
    const r = await page.evaluate(() => {
      const gl = document.createElement('canvas').getContext('webgl')
      const e = gl && gl.getExtension('WEBGL_debug_renderer_info')
      return gl ? (e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)) : 'no webgl'
    })
    console.error(`MACGPU: ${browser.version()} renderer ${r}`)
    await page.close()
  } catch (e) {
    console.error(`MACGPU: probe failed ${e}`)
  }
  return browser
}
