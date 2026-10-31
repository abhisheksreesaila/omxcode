// Goal 42 M6, side B (see index.html). Runs exactly the SQL files scripts/jot_race.py serves, as side A does.
import sqlite3InitModule from './node_modules/@sqlite.org/sqlite-wasm/dist/index.mjs';

const text = async (name) => (await fetch(name, { cache: 'no-store' })).text();
const statements = (sql) => sql.split(';\n').map((s) => s.trim()).filter(Boolean);

async function openDb(sqlite3, vfs) {
  if (vfs === 'opfs-sahpool') {
    const pool = await sqlite3.installOpfsSAHPoolVfs({ name: 'opfs-sahpool', initialCapacity: 6 });
    return new pool.OpfsSAHPoolDb('/jot-race.db');
  }
  if (!sqlite3.oo1.OpfsDb) throw new Error('the opfs VFS is unavailable (needs SharedArrayBuffer: cross-origin isolation)');
  return new sqlite3.oo1.OpfsDb('/jot-race.db', 'c');
}

async function build(sqlite3, vfs) {
  const [pragmas, schema, insert, finish, tsv] = await Promise.all(
    ['pragmas.sql', 'schema.sql', 'insert.sql', 'finish.sql', 'notes.tsv'].map(text));
  const lines = tsv.split('\n');
  const db = await openDb(sqlite3, vfs);
  const journal = [];
  for (const s of statements(pragmas)) db.exec({ sql: s, callback: (row) => journal.push(row) });
  db.exec(schema);
  const ins = db.prepare(insert.trim());
  const t0 = performance.now();
  let n = 0;
  let largest = 0;
  try {
    db.exec('BEGIN');
    for (const l of lines) {
      const tab = l.indexOf('\t');
      if (tab < 0) continue;
      ins.bind([l.slice(0, tab), l.slice(tab + 1), n]).stepReset();
      n += 1;
      if (n % 10000 === 0) {
        db.exec('COMMIT');
        largest = n;
        if (n % 100000 === 0) postMessage({ log: `${vfs}: ${n} notes` });
        db.exec('BEGIN');
      }
    }
    db.exec('COMMIT');
    largest = n;
  } catch (e) {
    return { error: String(e), notes: largest };
  }
  const build_s = (performance.now() - t0) / 1000;
  for (const s of statements(finish)) db.exec(s);
  const size = db.selectValue('SELECT page_count * page_size FROM pragma_page_count, pragma_page_size');
  db.close();
  return { notes: n, build_s, journal: String(journal), db_bytes: size };
}

async function query(sqlite3, vfs) {
  const [open, sql, queries] = await Promise.all(['open.sql', 'query.sql', 'queries.txt'].map(text));
  const db = await openDb(sqlite3, vfs);
  for (const s of statements(open)) db.exec(s);
  const q = db.prepare(sql.trim());
  const counts = [];
  const ms = [];
  let first = true;
  for (const m of queries.split('\n')) {
    if (!m) continue;
    const t0 = performance.now();
    q.reset();
    q.bind([m]);
    let n = 0;
    while (q.step()) n += 1;
    const t1 = performance.now();
    if (first) { postMessage({ first: true }); first = false; }  // (the first query also counts, as on side A)
    counts.push(n);
    ms.push(t1 - t0);
  }
  const notes = db.selectValue('SELECT count(*) FROM notes');
  q.finalize();
  db.close();
  return { counts, ms, notes };
}

onmessage = async (e) => {
  const { mode, vfs, isolated } = e.data;
  try {
    const sqlite3 = await sqlite3InitModule();
    const out = mode === 'build' ? await build(sqlite3, vfs) : await query(sqlite3, vfs);
    postMessage({ ...out, vfs, isolated, version: sqlite3.version.libVersion });
  } catch (err) {
    postMessage({ error: String(err && err.stack || err), vfs });
  }
};
