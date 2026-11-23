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
  return { total: span.getBoundingClientRect().width, glyphs, sizes }
})
console.log(JSON.stringify(out))
await b.close()
