// A server a script starts ends with it, however it ends (continuation 26: process.on('exit') isn't run on a signal, and a uvicorn of
// bothopen's stayed for three hours): the kernel ends it when node dies (Linux: setpriv --pdeathsig), and node ends on the signals.
import fs from 'node:fs'
import { spawn } from 'node:child_process'
const SETPRIV = process.platform === 'linux' && ['/usr/bin/setpriv', '/bin/setpriv'].find((f) => fs.existsSync(f))
export const withMe = (cmd, args) => (SETPRIV ? [SETPRIV, ['--pdeathsig', 'SIGTERM', cmd, ...args]] : [cmd, args])
for (const s of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(s, () => process.exit(1))  // (process.on('exit') handlers run then)
export const endWith = (child, what) => { child.on('exit', (code) => { console.log(`ENDED ${what} ${code}`); process.exit(1) }); return child }
