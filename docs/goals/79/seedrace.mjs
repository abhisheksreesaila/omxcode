// Goal 79 M6 (D-7929): the race's two canvas notes, written into scratch copies of the reference database through the
// web Personal Note's own API (its uvicorn app, as ref.mjs seeds the fixture), so native pnote races on exactly the rows
// the web app would store: PN's own generators (benchmark-note.mjs: 600 objects; stress-note.js: 5,400 asked), POSTed
// as a canvas note and PUT with its content and page state; the API converts and stores them as JSON Canvas.
// Run from ~/Projects/personalnotev2:
//   node <mojo-ui>/docs/goals/79/seedrace.mjs <reference pn.db> <outdir>     → <outdir>/race-600.db, race-stress.db
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'

const [refDb, outDir] = process.argv.slice(2)
if (!refDb || !outDir) { console.error('usage: seedrace.mjs <reference pn.db> <outdir>'); process.exit(2) }
fs.mkdirSync(outDir, { recursive: true })
const { generateNote, COLUMNS, ROWS } = await import(path.join(process.cwd(), 'scripts/benchmark-note.mjs'))
const { generateStressNote } = await import(path.join(process.cwd(), 'src/modules/speedtest/stress-note.js'))

const stress = generateStressNote(5400, { columns: 4, rows: 4 })
const NOTES = [
  { key: '600', title: 'Benchmark 600', content: generateNote(), pageState: { columns: COLUMNS, rows: ROWS } },
  { key: 'stress', title: 'Stress note', content: typeof stress.content === 'string' ? JSON.parse(stress.content) : stress.content, pageState: stress.pageState },
]

let port = 4993
for (const note of NOTES) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'pn-race-'))
  const db = path.join(scratch, 'v.db')
  fs.copyFileSync(refDb, db)
  const env = { ...process.env, PERSONAL_NOTE_DB: db, PERSONAL_NOTE_PLUGINS_DIR: path.join(scratch, 'plugins') }
  const base = `http://127.0.0.1:${port}`
  const api = spawn('.venv/bin/python', ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', String(port)], { env, stdio: 'ignore' })
  port += 1
  try {
    let up = false
    for (let i = 0; i < 200 && !up; i++) { try { up = (await fetch(`${base}/api/notebooks`)).ok } catch {} if (!up) await new Promise((r) => setTimeout(r, 150)) }
    if (!up) throw new Error('the web app did not start')
    const call = async (m, u, b) => {
      const r = await fetch(`${base}/api${u}`, { method: m, headers: { 'content-type': 'application/json', 'x-personal-note': '1' }, body: b && JSON.stringify(b) })
      const j = await r.json()
      if (!r.ok) throw new Error(`${m} ${u}: ${r.status} ${JSON.stringify(j).slice(0, 300)}`)
      return j
    }
    const made = await call('POST', '/notes', { title: note.title, noteType: 'canvas' })
    const saved = await call('PUT', `/notes/${made.id}`, { title: note.title, revision: made.revision, content: note.content, pageState: note.pageState })
    await new Promise((r) => setTimeout(r, 300))
    const out = path.join(outDir, `race-${note.key}.db`)
    for (const f of [out, out + '-wal', out + '-shm']) fs.rmSync(f, { force: true })
    const py = spawnSync('.venv/bin/python', ['-c', 'import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); print(s.execute("SELECT length(content) FROM notes WHERE id = ?", (int(sys.argv[3]),)).fetchone()[0])', db, out, String(made.id)], { encoding: 'utf8' })
    if (py.status !== 0) throw new Error(py.stderr)
    console.log(`SEEDED ${note.key}: note ${made.id} revision ${saved.revision}, ${py.stdout.trim()} bytes of JSON Canvas → ${out}`)
  } finally {
    try { api.kill() } catch {}
  }
}
