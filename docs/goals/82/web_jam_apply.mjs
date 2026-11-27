// The web Personal Note's own applyJamEdits (src/mindmap/jam.js) on each case's map and the web validator's edits (goal 82
// M6's yardstick). stdin: web_jam.py's lines; stdout: the same lines with "map" filled in.  node web_jam_apply.mjs <web folder> <cases.json>
import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
const [web, casesPath] = process.argv.slice(2)
const { applyJamEdits } = await import(pathToFileURL(`${web}/src/mindmap/jam.js`).href)
const cases = JSON.parse(readFileSync(casesPath, 'utf8'))
const lines = readFileSync(0, 'utf8').split('\n').filter(Boolean)
for (const line of lines) {
  const row = JSON.parse(line)
  if (row.ok) row.map = applyJamEdits(structuredClone(cases[row.case].map), row.wire)
  console.log(JSON.stringify(row))
}
