// Goal 79, continuation 20: the web Personal Note on a copy of the notes file native pnote wrote in first5.py: every note opens
// without an error and says what native wrote (pictures build/g79/first5-web-*.png, CPU Chromium); then the web edits a page and a
// canvas by hand and the copy is native's to open again. Scratch copies only.
//   node <mojo-ui>/docs/goals/79/first5web.mjs <notes.db> <copy.db> <outdir>      (from ~/Projects/personalnotev2)
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const [src, copy, out] = process.argv.slice(2)
for (const s of ['', '-wal', '-shm']) fs.rmSync(copy + s, { force: true })
for (const s of ['', '-wal']) if (fs.existsSync(src + s)) fs.copyFileSync(src + s, copy + s)
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-first5-'))
const PORT = 4996
const api = spawn('.venv/bin/python', ['-B', '-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(PORT)],
  { env: { ...process.env, PERSONAL_NOTE_DB: copy, PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }, stdio: 'ignore' })
process.on('exit', () => { try { api.kill() } catch {} })
for (let i = 0; i < 200; i++) { try { if ((await fetch(`http://127.0.0.1:${PORT}/api/notebooks`)).ok) break } catch {} await new Promise((r) => setTimeout(r, 150)) }
const get = async (u) => (await fetch(`http://127.0.0.1:${PORT}/api${u}`, { headers: { 'x-personal-note': '1' } })).json()
const bad = []
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'BAD  ') + what); if (!ok) bad.push(what) }
const all = await get('/notes')
const notes = Array.isArray(all) ? all : all.notes
const books = await get('/notebooks')
check(books.map((b) => b.name).sort().join() === 'My Notes,Travel é', 'notebooks: ' + books.map((b) => b.name).join(', '))
check(notes.length === 5, `${notes.length} notes`)
const browser = await chromium.launch({ headless: true })
const page = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage()
const errors = []
page.on('pageerror', (e) => errors.push(e.message))
page.on('console', (m) => { if (m.type() === 'error' && !/favicon|fonts|ERR_/.test(m.text())) errors.push(m.text()) })
await page.goto(`http://127.0.0.1:${PORT}/notes`)
await page.locator('#island-title').waitFor()
await page.waitForTimeout(1500)
let n = 0
const open = async (note) => {
  if (!(await page.locator('.sidebar.open').count())) { await page.click('#toggle-sidebar'); await page.waitForTimeout(500) }
  const row = page.locator(`.note-list-item[data-note-id="${note.id}"]`).first()
  if (!(await row.isVisible().catch(() => false))) { for (const b of await page.locator('.notebook-tab').all()) { await b.click(); await page.waitForTimeout(200); if (await row.isVisible().catch(() => false)) break } }
  await row.click()
  await page.waitForTimeout(1500)
}
for (const note of notes) {
  await open(note)
  await page.screenshot({ path: path.join(out, `first5-web-${++n}-${note.noteType}.png`) })
}
const of = async (f) => { for (const x of notes) { const full = await get(`/notes/${x.id}`); if (f(full)) return full } }
const goa = await of((x) => x.title === 'Goa é')
check(goa.content.markdown.startsWith('# Trip to Goa\n\nA **bold** plan') && goa.notebookId === 1, 'the page: its words and notebook')
const long = await of((x) => x.content?.markdown?.includes('line 59'))
check(long.content.ink.marks.length === 1 && long.content.ink.marks[0].tool === 'highlight', 'the highlight on the long page')
await open(long)
await page.evaluate(() => { document.querySelector('.page-desk').scrollTop = 0 })
await page.waitForTimeout(600)
await page.mouse.click(640, 500)
await page.keyboard.press('ArrowDown')
await page.waitForTimeout(600)
await page.screenshot({ path: path.join(out, 'first5-web-7-ink.png') })
const mark = await page.evaluate(() => { const m = document.querySelector('.page-mark path'); if (!m) return null; const r = m.getBoundingClientRect(); return [r.left, r.top, r.width, r.height] })
check(Boolean(mark), 'the highlight is drawn: ' + JSON.stringify(mark))
const word = await page.evaluate(() => { const w = document.createTreeWalker(document.querySelector('.cm-content'), NodeFilter.SHOW_TEXT); while (w.nextNode()) if (w.currentNode.data.includes('line 5 ')) { const r = document.createRange(); r.selectNodeContents(w.currentNode); const b = r.getBoundingClientRect(); return [b.left, b.top, b.width, b.height] } return null })
console.log('     rects of "line":', JSON.stringify(await page.evaluate(() => { const w = document.createTreeWalker(document.querySelector('.cm-content'), NodeFilter.SHOW_TEXT); const out = []; while (w.nextNode()) if (/line [345] /.test(w.currentNode.data)) { const r = document.createRange(); r.setStart(w.currentNode, 0); r.setEnd(w.currentNode, 1); const b = r.getBoundingClientRect(); out.push([w.currentNode.data, b.top, b.height]) } return out })), 'paper', JSON.stringify(await page.evaluate(() => { const b = document.querySelector('.page-paper').getBoundingClientRect(); return [b.left, b.top] })), 'g', await page.evaluate(() => document.querySelector('.page-mark').getAttribute('transform')))
check(mark && word && mark[0] < word[0] + 10 && mark[1] < word[1] + word[3] + 8 && mark[1] + mark[3] > word[1], `on its line: ${JSON.stringify(word)}`)
const map = await of((x) => x.noteType === 'mindmap')
check(map.content.nodes.map((x) => x.text).sort().join() === 'Ana,People,Places é,The plan for the summer trip to Goa', 'the map')
const canvas = await of((x) => x.noteType === 'canvas' && JSON.stringify(x.content).includes('sticky words'))
check(JSON.stringify(canvas.content).includes('second é line'), 'the canvas')
const found = await get('/search?q=tickets')
check(found.some((x) => x.id === goa.id), 'the web searches its words')
check(errors.length === 0, 'no errors in the web app: ' + errors.slice(0, 3).join(' | '))
// the web's own edits
await open(goa)
await page.locator('.cm-content').click()
await page.keyboard.press('Control+End')
await page.keyboard.type('\nThe web was here é')
await page.waitForTimeout(1800)
await open(canvas)
await page.keyboard.press('Escape')
await page.waitForTimeout(300)
await page.keyboard.press('t')
await page.mouse.click(640, 700)
await page.waitForTimeout(500)
await page.keyboard.type('typed in the web')
await page.keyboard.press('Escape')
await page.waitForTimeout(1800)
check((await get(`/notes/${goa.id}`)).content.markdown.endsWith('The web was here é'), 'the web edited the page')
check(JSON.stringify((await get(`/notes/${canvas.id}`)).content).includes('typed in the web'), 'and the canvas')
await page.screenshot({ path: path.join(out, 'first5-web-9-edited.png') })
await browser.close()
api.kill()
await new Promise((r) => setTimeout(r, 800))
console.log('first5web:', bad.length ? `${bad.length} BAD` : 'ok')
process.exit(bad.length ? 1 : 0)
