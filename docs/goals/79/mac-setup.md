# Goal 79 on the owner's Mac: what was put where (ruling B, D-7977)

Mac: `bhoomijaprasad@100.76.9.101` (arm64, macOS 27.2). Nothing system-wide: no Homebrew, no sudo, nothing in
/usr/local, no `defaults`, no privacy settings. The owner's own Personal Note data is never touched: every run uses a
scratch database copied in from this checkout.

## ~/omxcode-g79-web (made 2026-11-22, continuation 15)
| path | what | how it got there |
|---|---|---|
| `~/omxcode-g79-web/node/` | Node.js v26.10.0 (darwin-arm64), the official tarball unpacked | `curl https://nodejs.org/dist/v26.10.0/node-v26.10.0-darwin-arm64.tar.xz` |
| `~/omxcode-g79-web/pn/` | a copy of Personal Note's code and its built `dist/` (from ~/Projects/personalnotev2 on the Linux box; no `.git`, `node_modules`, `.venv`, `data`) | tar over ssh |
| `~/omxcode-g79-web/pn/node_modules/` | Personal Note's npm packages, Playwright included (no browser download: Playwright drives the installed Chrome, channel `chrome`) | `npm install` in that folder (PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1) |
| `~/omxcode-g79-web/pn/.venv/bin/python` | a two-line wrapper calling the pixi env's Python (ref.mjs starts `.venv/bin/python -m uvicorn main:app`) | written by hand |
| `~/omxcode-g79-web/pyenv/` | a pixi project (`pixi.toml`) and its env `.pixi/`: Python 3.14 + python-fasthtml 0.14.6, python-dotenv, uvicorn[standard], cryptography, certifi (PN's requirements.txt) | `~/.pixi/bin/pixi install` (pixi was already on the Mac) |
| `~/omxcode-g79-web/repo/` | this checkout's docs/goals/79 (ref.mjs, fixture) and fonts/, refreshed by each run of docs/goals/79/macref.py | tar over ssh |
| `~/omxcode-g79-web/ref-mac/`, `ref-<time>/`, `*.log` | the reference shots each run makes (Chrome on the Mac at 2.0) and their logs | ref.mjs |
| `~/omxcode-g79-web/npm.log`, `ref.log` | install and first-run logs | — |

## Also made by goal 79's runs (earlier rounds)
- `~/omxcode-g54/data/out-<time>/`: each scripts/mac-ssh run's output folder; `~/omxcode-g54/data/widths/` (macwidths.py: a
  page, a fonts copy, a throwaway Chrome profile `widths/profile`); scratch databases copied in (`pn.db`, `race-600.db`).
- `~/Desktop/omxcode-report-Personal Note/<time>/`: the app's own test reports (pictures and view dumps), as every
  scripts/mac-ssh run has made since goal 56.

## Removal (the owner runs it; nothing else on the Mac refers to these)
```
rm -rf ~/omxcode-g79-web ~/omxcode-g54/data/out-* ~/omxcode-g54/data/widths
```
