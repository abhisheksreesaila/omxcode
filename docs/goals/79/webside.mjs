// (review 5's probe, kept for bothopen.py)
// review 5: the real web app on a scratch file, driven by lines on stdin: node webside.mjs <db> <port> <scratch> (cwd personalnotev2)
import fs from 'node:fs'; import path from 'node:path'; import { spawn } from 'node:child_process'; import readline from 'node:readline'
const PN = process.cwd()
const { chromium } = await import(path.join(PN, 'node_modules/playwright/index.mjs'))
const [db, port, scratch] = process.argv.slice(2)
for (const d of ['plugins', 'ai', 'voice', 'search', 'speed']) fs.mkdirSync(path.join(scratch, d), { recursive: true })
const env = { ...process.env, PERSONAL_NOTE_DB: db, PERSONAL_NOTE_PLUGINS_DIR: scratch + '/plugins', PERSONAL_NOTE_AI_DIR: scratch + '/ai', PERSONAL_NOTE_VOICE_DIR: scratch + '/voice', PERSONAL_NOTE_SEARCH_DIR: scratch + '/search', PERSONAL_NOTE_SPEEDTEST_DIR: scratch + '/speed' }
const api = spawn('.venv/bin/python', ['-B', '-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', port], { env, stdio: 'ignore' })
process.on('exit', () => { try { api.kill() } catch {} })
for (let i = 0; i < 200; i++) { try { if ((await fetch(`http://127.0.0.1:${port}/api/notebooks`)).ok) break } catch {} await new Promise((r) => setTimeout(r, 150)) }
const H = { 'x-personal-note': '1', 'content-type': 'application/json' }
const get = async (u) => (await fetch(`http://127.0.0.1:${port}/api${u}`, { headers: H })).json()
const browser = await chromium.launch({ headless: true, args: ['--disable-gpu'] })
const page = await (await browser.newContext({ viewport: { width: 1200, height: 800 } })).newPage()
page.on('pageerror', (e) => console.log('PAGEERROR ' + e.message))
await page.goto(`http://127.0.0.1:${port}/notes`)
await page.locator('#island-title').waitFor()
await page.waitForTimeout(1200)
const all = async () => { const a = await get('/notes'); return Array.isArray(a) ? a : a.notes }
const ops = {
  async make([type, title]) { const r = await fetch(`http://127.0.0.1:${port}/api/notes`, { method: 'POST', headers: H, body: JSON.stringify({ title, noteType: type }) }); return r.status },
  async reload() { await page.reload(); await page.locator('#island-title').waitFor(); await page.waitForTimeout(1500); return 'ok' },
  async open([title]) {
    const note = (await all()).find((n) => n.title === title); if (!note) return 'no note ' + title
    if (!(await page.locator('.sidebar.open').count())) { await page.click('#toggle-sidebar'); await page.waitForTimeout(500) }
    const row = page.locator(`.note-list-item[data-note-id="${note.id}"]`).first()
    if (!(await row.isVisible().catch(() => false))) for (const b of await page.locator('.notebook-tab').all()) { await b.click(); await page.waitForTimeout(150); if (await row.isVisible().catch(() => false)) break }
    await row.click(); await page.waitForTimeout(1200); return await page.locator('#island-title').textContent() },
  async pageend() { await page.locator('.cm-content').focus(); await page.keyboard.press('Control+End'); return 'ok' },
  async type([t, delay]) { await page.keyboard.type(t, { delay: Number(delay || 0) }); return 'ok' },
  async press([k]) { await page.keyboard.press(k); return 'ok' },
  async click([x, y]) { await page.mouse.click(Number(x), Number(y)); return 'ok' },
  // another app of this person's, through the API (an agent, a second browser): the node with this word taken out
  async wipe([title, word]) {
    const note = (await all()).find((n) => n.title === title); if (!note) return 'no note ' + title
    const f = await get(`/notes/${note.id}`)
    const before = f.content.nodes.length
    f.content.nodes = f.content.nodes.filter((n) => !JSON.stringify(n).includes(word))
    if (f.content.nodes.length === before) return 'not there'
    const r = await fetch(`http://127.0.0.1:${port}/api/notes/${note.id}`, { method: 'PUT', headers: H, body: JSON.stringify({ ...f, expectedRevision: f.revision }) })
    return r.status },
  // the same, a word added to the first words there are
  async append([title, word]) {
    const note = (await all()).find((n) => n.title === title); if (!note) return 'no note ' + title
    const f = await get(`/notes/${note.id}`)
    if (f.noteType === 'page') f.content.markdown = (f.content.markdown || '') + ' ' + word
    else { const n = f.content.nodes.find((n) => typeof n.text === 'string' && n.text !== ''); if (!n) return 'no words'; n.text += ' ' + word }
    const r = await fetch(`http://127.0.0.1:${port}/api/notes/${note.id}`, { method: 'PUT', headers: H, body: JSON.stringify(f) })
    return r.status },
  async wait([ms]) { await page.waitForTimeout(Number(ms)); return 'ok' },
  async shot([f]) { await page.screenshot({ path: f }); return f },
  async title() { return await page.locator('#island-title').textContent() },
  async pagetext() { return await page.evaluate(() => document.querySelector('.cm-content')?.innerText ?? '(no page)') },
  async focus() { return await page.evaluate(() => { const a = document.activeElement; return (a?.className || a?.tagName || '?') + (a?.isContentEditable ? ' (writes)' : '') + ' ro=' + (document.querySelector('.cm-content')?.getAttribute('contenteditable') ?? '-') }) },
  async state() { return await page.evaluate(() => document.querySelector('#save-state, .save-state, #island-state')?.textContent ?? '?') + ' | ' + await page.evaluate(() => [...document.querySelectorAll('.toast, #toast, [role=status], [role=alert]')].map((e) => e.textContent.trim()).filter(Boolean).join(' / ')) },
  async notes() { const out = []; for (const n of await all()) { const f = await get(`/notes/${n.id}`); out.push([n.id, n.title, n.noteType, f.revision, n.noteType === 'page' ? f.content?.markdown : JSON.stringify(f.content)]) } return out },
  async del([title]) { const note = (await all()).find((n) => n.title === title); return (await fetch(`http://127.0.0.1:${port}/api/notes/${note.id}`, { method: 'DELETE', headers: H })).status },
}
console.log('READY')
for await (const line of readline.createInterface({ input: process.stdin })) {
  const [op, ...args] = JSON.parse(line)
  if (op === 'quit') break
  try { console.log('R ' + JSON.stringify(await ops[op](args))) } catch (e) { console.log('R ' + JSON.stringify('ERR ' + e.message.slice(0, 300))) }
}
await browser.close(); api.kill(); process.exit(0)
