// Goal 79 M1, ruling C (D-7991): where the Mac's emoji line differs, glyph by glyph, on the live page. The fixture's
// emoji line is laid out in the Mac's own Chrome (Playwright, channel chrome) as ref.mjs lays it out, and each
// grapheme's box comes from Range.getClientRects; then single emoji at sizes 10–40 px. Prints JSON.
//   node emojiprobe.mjs <widths.html>     (from ~/omxcode-g79-web/pn on the Mac)
import { chromium } from 'playwright'
const b = await chromium.launch({ headless: true, channel: process.env.PW_CHANNEL || 'chrome', args: ['--allow-file-access-from-files'] })
const p = await (await b.newContext({ deviceScaleFactor: 2 })).newPage()
await p.goto('file://' + process.argv[2])
await p.waitForFunction(() => document.getElementById('out').textContent.startsWith('WIDTHS'), null, { timeout: 20000 })
const out = await p.evaluate(() => {
  const span = document.getElementById('emoji')
  const text = span.textContent
  const seg = [...new Intl.Segmenter('en', { granularity: 'grapheme' }).segment(text)]
  const node = span.firstChild
  const glyphs = seg.map((g) => { const r = document.createRange(); r.setStart(node, g.index); r.setEnd(node, g.index + g.segment.length); const rs = [...r.getClientRects()]; return { g: g.segment, x: rs[0]?.left, w: rs.reduce((a, q) => a + q.width, 0) } })
  const sizes = {}
  for (let z = 10; z <= 40; z++) {
    const s = document.createElement('span'); s.style.cssText = `font-family:"Geist";font-size:${z}px;white-space:pre;position:absolute`; s.textContent = '📚'; document.body.appendChild(s)
    sizes[z] = s.getBoundingClientRect().width; s.remove()
  }
  // (continuation 17) sizes between whole ones, small and large ones, and the same text on a zoomed canvas: pnote shapes at
  // the layout size and scales the drawing; the web's board scales with a CSS transform (zoomed) or redraws at size × zoom
  const at = (z, css = '') => { const s = document.createElement('span'); s.style.cssText = `font-family:"Geist";font-size:${z}px;white-space:pre;position:absolute;${css}`; s.textContent = '📚'; document.body.appendChild(s); const r = s.getBoundingClientRect().width; s.remove(); return r }
  const more = {}, zoomed = {}
  for (const z of [6, 7, 8, 9, 9.5, 10.4, 11.5, 12.25, 12.8, 13.33, 13.5, 14.4, 15.2, 15.5, 15.9, 16.5, 17.25, 18.5, 19.2, 20.5, 21.6, 22.4, 23.3, 23.5, 23.9, 24.5, 25.6, 30.5, 44, 48, 64.5, 96]) more[z] = at(z)
  for (const k of [0.3, 0.5, 0.75, 1.25, 1.5, 2, 3]) zoomed[k] = { transform: at(18, `transform:scale(${k});transform-origin:0 0`) / k, size: at(18 * k), zoom: at(18, `zoom:${k}`) / k }
  return { total: span.getBoundingClientRect().width, glyphs, sizes, more, zoomed }
})
console.log(JSON.stringify(out))
await b.close()
