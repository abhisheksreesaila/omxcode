"""What the web can do of what Keeper does (goal 45 M3), tried for real in headless Chromium; writes docs/goals/45/web.json.

    pixi run python scripts/keeper_web.py

Five things, each tried the best way the web offers, each answer carrying what was observed (an error, a timing, a log
line), never a guess:
  read_folder    File System Access showDirectoryPicker(): without a user gesture; with one made through the DevTools
                 protocol (a real input event): the picker itself (intercepted), the folder dropped onto the page
                 (Input.dispatchDragEvent → getAsFileSystemHandle), and <input webkitdirectory> filled through
                 DOM.setFileInputFiles. Where one reads the folder, it reads Keeper's 100,000-file corpus and is timed.
  notice_change  FileSystemObserver (behind --enable-features=FileSystemObserver if it isn't on), else polling the
                 folder's handle; each tried; lag from the file's close (this process's wall clock) to the page seeing
                 it (performance.timeOrigin + now(), offset measured by round trips).
  run_closed     a service worker with Background Sync and Periodic Background Sync registered (permissions granted
                 through the DevTools protocol), then the tab closed: does any of its code run when a file changes or a
                 minute passes? (the worker logs every event it gets to this script's server)
  notify_closed  showNotification from that worker with the tab closed
  tray           any API for an item in the system tray (and the Badging API, its nearest relative)
The corpus is the checker's own (docs/goals/45-check.py make_corpus), so both sides read the same files. Temp folders only;
the browser profile is a temp folder too. Nothing leaves the machine (the page and the worker talk to 127.0.0.1 only).
"""

import http.server
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "goals" / "45" / "web.json"
CHROMIUM = "/usr/bin/chromium"
FLAGS = ["--enable-features=FileSystemObserver,FileSystemAccessLocal", "--enable-experimental-web-platform-features"]

PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>Keeper on the web</title></head><body>
<button id="pick" style="position:fixed;left:10px;top:10px;width:200px;height:60px">Choose a folder</button>
<div id="drop" style="position:fixed;left:10px;top:100px;width:400px;height:300px;background:#eee">drop a folder here</div>
<input id="dir" type="file" webkitdirectory multiple style="position:fixed;left:10px;top:420px">
<script>
const now = () => performance.timeOrigin + performance.now();
window.R = {features: {showDirectoryPicker: 'showDirectoryPicker' in window, FileSystemObserver: 'FileSystemObserver' in window,
            serviceWorker: 'serviceWorker' in navigator, setAppBadge: 'setAppBadge' in navigator,
            SyncManager: 'SyncManager' in window, PeriodicSyncManager: 'PeriodicSyncManager' in window,
            tray_like: Object.getOwnPropertyNames(window).concat(Object.getOwnPropertyNames(Navigator.prototype)).filter(n => /tray|systray|statusitem|statusbar|notifyicon/i.test(n))}};
// without a user gesture: on load, nobody has clicked anything
setTimeout(() => showDirectoryPicker().then(h => R.no_gesture = 'ok: ' + h.name, e => R.no_gesture = e.name + ': ' + e.message), 50);
document.getElementById('pick').onclick = () => {
  R.picker_called = now();
  showDirectoryPicker().then(h => { window.dirHandle = h; R.picker = 'ok: ' + h.kind + ' ' + h.name; },
                             e => R.picker = e.name + ': ' + e.message);
};
const dz = document.getElementById('drop');
dz.ondragover = e => e.preventDefault();
dz.ondrop = async e => {
  e.preventDefault();
  R.dropped = [];
  for (const item of e.dataTransfer.items) {
    try {
      const h = await item.getAsFileSystemHandle();
      R.dropped.push(h ? h.kind + ' ' + h.name : 'null');
      if (h && h.kind === 'directory') window.dropHandle = h;
    } catch (err) { R.dropped.push(err.name + ': ' + err.message); }
  }
};
document.getElementById('dir').onchange = async e => {
  const t0 = now();
  const files = e.target.files;
  let n = 0, bytes = 0;
  for (const f of files) { if (/\.(md|txt|markdown)$/.test(f.name)) { bytes += (await f.text()).length; n++; } }
  R.input_read = {files: n, chars: bytes, ms: now() - t0, listed: files.length};
};
async function walk(dir, prefix, out) {
  for await (const [name, h] of dir.entries()) {
    if (h.kind === 'directory') await walk(h, prefix + name + '/', out);
    else out.push([prefix + name, h]);
  }
  return out;
}
window.readAll = async (h) => {
  const t0 = now();
  const all = await walk(h, '', []);
  let n = 0, chars = 0;
  for (const [p, fh] of all) { if (/\.(md|txt|markdown)$/.test(p)) { chars += (await (await fh.getFile()).text()).length; n++; } }
  return {files: n, chars, ms: now() - t0};
};
window.observe = async (h) => {
  window.seen = {};
  try {
    const obs = new FileSystemObserver((records) => {
      const t = now();
      for (const r of records) { const p = r.relativePathComponents.join('/'); if (!(p in seen)) seen[p] = t; }
    });
    await obs.observe(h, {recursive: true});
    window.obs = obs;
    return 'observing';
  } catch (e) { return e.name + ': ' + e.message; }
};
window.poll = async (h, ms) => {
  window.seen = {};
  const known = new Map();
  for (const [p, fh] of await walk(h, '', [])) known.set(p, (await fh.getFile()).lastModified);
  window.polling = true;
  window.polls = 0;
  (async function loop() {
    while (window.polling) {
      const t = now();
      for (const [p, fh] of await walk(h, '', [])) {
        if (!known.has(p)) { known.set(p, 0); if (!(p in seen)) seen[p] = now(); }
      }
      polls++;
      await new Promise(r => setTimeout(r, ms));
    }
  })();
  return 'polling every ' + ms + ' ms';
};
window.stash = (h) => new Promise((res) => {  // the folder's handle into IndexedDB, where the service worker can read it
  const rq = indexedDB.open('keeper', 1);
  rq.onupgradeneeded = () => rq.result.createObjectStore('h');
  rq.onsuccess = () => { const tx = rq.result.transaction('h', 'readwrite'); tx.objectStore('h').put(h, 'dir'); tx.oncomplete = () => res('stashed'); tx.onerror = () => res('stash failed: ' + tx.error); };
  rq.onerror = () => res('idb failed: ' + rq.error);
});
</script></body></html>"""

SW = r"""
const log = (what) => fetch('/log?' + new URLSearchParams({what, t: Date.now()}));
async function tryFolder() {
  try {
    const db = await new Promise((res, rej) => { const r = indexedDB.open('keeper', 1); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
    const h = await new Promise((res, rej) => { const g = db.transaction('h').objectStore('h').get('dir'); g.onsuccess = () => res(g.result); g.onerror = () => rej(g.error); });
    if (!h) return 'no handle stored';
    const perm = h.queryPermission ? await h.queryPermission({mode: 'read'}) : 'queryPermission missing';
    const names = []; for await (const [n] of h.entries()) { names.push(n); if (names.length > 3) break; }
    return 'permission ' + perm + ', read ' + names.length + ' entries';
  } catch (e) { return e.name + ': ' + e.message; }
}
async function tryNotify(tag) {
  try { await self.registration.showNotification('Keeper', {body: 'from ' + tag + ' with the tab closed', tag}); return 'shown'; }
  catch (e) { return e.name + ': ' + e.message; }
}
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(clients.claim()));
self.addEventListener('sync', (e) => e.waitUntil((async () => {
  const c = await clients.matchAll({includeUncontrolled: true});
  await log('sync ' + e.tag + ' clients=' + c.length + ' folder=[' + await tryFolder() + '] notify=[' + await tryNotify('sync') + ']');
})()));
self.addEventListener('periodicsync', (e) => e.waitUntil((async () => {
  const c = await clients.matchAll({includeUncontrolled: true});
  await log('periodicsync ' + e.tag + ' clients=' + c.length + ' folder=[' + await tryFolder() + '] notify=[' + await tryNotify('periodicsync') + ']');
})()));
self.addEventListener('fetch', () => {});
"""

LOG = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/log?"):
            LOG.append((time.time(), self.path[5:]))
            body, kind = b"ok", "text/plain"
        elif self.path.startswith("/sw.js"):
            body, kind = SW.encode(), "text/javascript"
        else:
            body, kind = PAGE.encode(), "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def corpus_maker():
    spec = importlib.util.spec_from_file_location("check45", ROOT / "docs" / "goals" / "45-check.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.make_corpus


def p95(xs):
    xs = sorted(xs)
    return round(xs[int(0.95 * (len(xs) - 1))], 3) if xs else None


def git_head():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def offset_ms(page):
    """This process's wall clock minus the page's (performance.timeOrigin + now()), best of 20 round trips."""
    best = None
    for _ in range(20):
        t0 = time.time() * 1000
        pt = page.evaluate("performance.timeOrigin + performance.now()")
        t1 = time.time() * 1000
        if best is None or t1 - t0 < best[0]:
            best = (t1 - t0, (t0 + t1) / 2 - pt)
    return best[1], best[0]


def changes(folder, n, tag, gap=0.02):
    """n new files in a new subfolder of folder; returns {relative path: wall-clock ms at close}."""
    sub = folder / tag
    sub.mkdir()
    out = {}
    for i in range(n):
        p = sub / f"c{i}.md"
        with open(p, "w") as f:
            f.write(f"change {i} {tag}\n")
        out[f"{tag}/c{i}.md"] = time.time() * 1000
        time.sleep(gap)
    return out


def lags(page, closed, off, wait_s=10):
    end = time.time() + wait_s
    seen = {}
    while time.time() < end:
        seen = page.evaluate("window.seen || {}")
        if all(k in seen for k in closed):
            break
        time.sleep(0.2)
    got = [max(0.0, seen[k] + off - closed[k]) for k in closed if k in seen]
    return got, len(got)


def drop_folder(page, cdp, folder):
    """The folder dropped onto the page through the DevTools protocol (a real drag: enter, over, drop)."""
    box = page.locator("#drop").bounding_box()
    x, y = box["x"] + 50, box["y"] + 50
    data = {"items": [], "files": [str(folder)], "dragOperationsMask": 1}
    for kind in ("dragEnter", "dragOver", "drop"):
        cdp.send("Input.dispatchDragEvent", {"type": kind, "x": x, "y": y, "data": data})
    for _ in range(50):
        r = page.evaluate("R.dropped")
        if r:
            return r
        time.sleep(0.1)
    return page.evaluate("R.dropped")


def main():
    from playwright.sync_api import sync_playwright

    tmp = Path(tempfile.mkdtemp(prefix="g45-web-"))
    try:
        corpus, small = tmp / "corpus", tmp / "small"
        t = time.time()
        corpus_maker()(corpus)
        small.mkdir()
        for i in range(400):  # a folder like M0's: a few hundred files
            (small / f"f{i}.md").write_text(f"file {i}\n")
        made = time.time() - t
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{srv.server_address[1]}/"
        res = {"commit": git_head(), "date": time.strftime("%Y-%m-%d %H:%M"), "flags": FLAGS, "corpus_files": 100_000, "entries": {}}
        with sync_playwright() as p:
            ctx = p.chromium.launch_persistent_context(str(tmp / "profile"), executable_path=CHROMIUM, headless=True, args=FLAGS)
            res["chromium"] = ctx.browser.version if ctx.browser else subprocess.run([CHROMIUM, "--version"], capture_output=True, text=True).stdout.strip()
            page = ctx.new_page()
            cdp = ctx.new_cdp_session(page)
            page.goto(url)
            time.sleep(1.0)
            R = page.evaluate("R")
            res["features"] = R["features"]

            # ---- read_folder
            no_gesture = R.get("no_gesture") or page.evaluate("R.no_gesture")
            tries = {"no_gesture": {"can": str(no_gesture).startswith("ok"), "evidence": f"showDirectoryPicker() on load, no click: {no_gesture}"}}
            routes = {}
            chooser = []
            cdp.on("Page.fileChooserOpened", lambda ev: chooser.append(ev))
            cdp.send("Page.enable")
            cdp.send("Page.setInterceptFileChooserDialog", {"enabled": True})
            page.click("#pick")  # (a real mouse event through the DevTools protocol: a user gesture)
            time.sleep(3)
            picker = page.evaluate("R.picker || null")
            routes["picker_intercepted"] = {"chooser_events": chooser, "promise": picker or "still pending after 3 s (a native dialog nobody can answer headless)",
                                            "can": bool(picker and picker.startswith("ok"))}
            dropped = drop_folder(page, cdp, corpus)
            got_handle = page.evaluate("!!window.dropHandle")
            routes["drop_folder"] = {"dropped": dropped, "can": got_handle}
            read_drop = None
            if got_handle:
                read_drop = page.evaluate("readAll(window.dropHandle)")
                routes["drop_folder"]["read"] = read_drop
            t0 = time.time()
            page.set_input_files("#dir", str(corpus))  # (DOM.setFileInputFiles: the folder chosen in <input webkitdirectory>)
            set_s = time.time() - t0
            read_input = None
            for _ in range(1200):
                read_input = page.evaluate("R.input_read || null")
                if read_input:
                    break
                time.sleep(0.25)
            routes["input_webkitdirectory"] = {"read": read_input, "set_files_s": round(set_s, 2),
                                               "can": bool(read_input and read_input["files"] == 100_000),
                                               "note": "a snapshot of File objects: no handle, so nothing to watch, and gone with the tab"}
            can_read = any(r["can"] for r in routes.values())
            tries["cdp_granted"] = {"can": can_read, "evidence": routes}
            reads = [r for r in (read_drop, read_input) if r and r.get("files") == 100_000]
            best = min(reads, key=lambda r: r["ms"]) if reads else None
            entry = {"label": "Read a folder", "can": tries["no_gesture"]["can"] or can_read, "tries": tries,
                     "evidence": f"no gesture: {no_gesture}; with a DevTools gesture: picker {routes['picker_intercepted']['promise']}, "
                                 f"drop handle {got_handle}, webkitdirectory {bool(read_input)}"}
            if best:
                entry["race"] = {"native": "scan_ms", "web_ms": round(best["ms"], 1), "files": best["files"],
                                 "what": "the web only reads the 100,000 files' text (no index); native's scan_ms reads and indexes them into SQLite FTS5"}
                entry["summary"] = (f"Only after a click: without one, {no_gesture.split(':')[0]}; with one, the web read the 100,000 files in "
                                    f"{best['ms'] / 1000:.1f} s (reading only)")
            else:
                entry["summary"] = f"Not without a click ({no_gesture.split(':')[0]}), and no DevTools gesture reached the files"
            res["entries"]["read_folder"] = entry

            # ---- notice_change (a small folder, like M0's, dropped for its handle)
            for _ in range(3):
                page.evaluate("R.dropped = null; window.dropHandle = null")
                dropped_small = drop_folder(page, cdp, small)
                if page.evaluate("!!window.dropHandle"):
                    break
            have = page.evaluate("!!window.dropHandle")
            off, rtt = offset_ms(page)
            ntries = {}
            if have:
                started = page.evaluate("observe(window.dropHandle)")
                if started == "observing":
                    closed = changes(small, 200, "obs")
                    got, n = lags(page, closed, off)
                    seen_now = page.evaluate("Object.keys(window.seen || {})")
                    ntries["FileSystemObserver"] = {"can": n > 0, "evidence": {"started": started, "seen": n, "of": 200, "p95_ms": p95(got),
                                                     "p50_ms": round(sorted(got)[len(got) // 2], 3) if got else None, "clock_offset_rtt_ms": round(rtt, 3),
                                                     "missed": sorted(set(closed) - set(seen_now)),
                                                     "lag_over": "the changes it reported (a miss is listed, not counted as a lag)"}}
                    page.evaluate("window.obs && window.obs.disconnect()")
                else:
                    ntries["FileSystemObserver"] = {"can": False, "evidence": f"FileSystemObserver offered: {R['features']['FileSystemObserver']}; observe(): {started}"}
                best_poll = None
                for every in (10, 50):
                    page.evaluate(f"poll(window.dropHandle, {every})")
                    closed = changes(small, 100, f"poll{every}")
                    got, n = lags(page, closed, off)
                    page.evaluate("window.polling = false")
                    time.sleep(0.2)
                    r = {"every_ms": every, "seen": n, "of": 100, "p95_ms": p95(got)}
                    if best_poll is None or (n == 100 and (r["p95_ms"] or 1e9) < (best_poll["p95_ms"] or 1e9)):
                        best_poll = r
                ntries["polling"] = {"can": best_poll["seen"] == 100, "evidence": {"best": best_poll, "how": "the dropped folder's handle walked every N ms; new names timed"}}
            else:
                why = f"no folder handle to watch (drop gave {dropped_small}; the picker can't be answered headless)"
                ntries["FileSystemObserver"] = {"can": False, "evidence": f"offered: {R['features']['FileSystemObserver']}; {why}"}
                ntries["polling"] = {"can": False, "evidence": why}
            nentry = {"label": "Notice a change", "tries": ntries, "can": any(t["can"] for t in ntries.values())}
            ok = [t["evidence"]["p95_ms"] if k == "FileSystemObserver" else t["evidence"]["best"]["p95_ms"] for k, t in ntries.items() if t["can"]]
            if ok:
                nentry["race"] = {"native": "watch_p95_ms", "web_ms": min(ok), "what": "file closed → the page sees it, p95 (native: M0's inotify lag)"}
                nentry["evidence"] = {k: t["evidence"] for k, t in ntries.items()}
                which = [k for k, t in ntries.items() if t["can"] and (t["evidence"].get("p95_ms") if k == "FileSystemObserver" else t["evidence"]["best"]["p95_ms"]) == min(ok)][0]
                missed = len(ntries["FileSystemObserver"]["evidence"].get("missed", [])) if isinstance(ntries["FileSystemObserver"]["evidence"], dict) else 0
                nentry["summary"] = (f"Only while the tab is open, on a dropped folder: {which} p95 {min(ok):.1f} ms"
                                     + (f", {missed} of 200 changes missed" if which == "FileSystemObserver" and missed else ""))
            else:
                nentry["evidence"] = {k: t["evidence"] for k, t in ntries.items()}
                nentry["summary"] = "No: nothing to watch without a folder handle"
            res["entries"]["notice_change"] = nentry

            # ---- run_closed, notify_closed: a service worker, then the tab closed
            if have:
                page.evaluate("stash(window.dropHandle)")
            ctx.grant_permissions(["notifications", "background-sync"], origin=url.rstrip("/"))
            try:  # (Periodic Background Sync's permission, through the DevTools protocol: Playwright has no name for it)
                # (setPermission, one permission: grantPermissions would replace the notification grant above)
                cdp.send("Browser.setPermission", {"origin": url.rstrip("/"), "permission": {"name": "periodic-background-sync"}, "setting": "granted"})
                res["periodic_grant"] = "granted through Browser.setPermission"
            except Exception as e:
                res["periodic_grant"] = f"Browser.setPermission failed: {e}"
            reg = page.evaluate("""async () => {
                const out = {};
                try { await navigator.serviceWorker.register('/sw.js'); await navigator.serviceWorker.ready; out.sw = 'active'; } catch (e) { out.sw = e.name + ': ' + e.message; return out; }
                const r = await navigator.serviceWorker.ready;
                try { out.periodic_permission = (await navigator.permissions.query({name: 'periodic-background-sync'})).state; } catch (e) { out.periodic_permission = e.name + ': ' + e.message; }
                try { await r.periodicSync.register('keeper-minute', {minInterval: 60 * 1000}); out.periodic = 'registered'; } catch (e) { out.periodic = e.name + ': ' + e.message; }
                try { out.periodic_tags = await r.periodicSync.getTags(); } catch (e) { out.periodic_tags = e.name; }
                return out;
            }""")
            ctx.set_offline(True)  # (the page and its worker offline: a Background Sync waits for the network)
            cdp.send("Network.enable")
            cdp.send("Network.emulateNetworkConditions", {"offline": True, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
            sync_reg = page.evaluate("""async () => { const r = await navigator.serviceWorker.ready;
                try { await r.sync.register('keeper-change'); return 'registered while offline (waits for the network)'; } catch (e) { return e.name + ': ' + e.message; } }""")
            before = len(LOG)
            page.close()  # the tab closes; the browser keeps running (kinder to the web than a person quitting it)
            closed_at = time.time()
            time.sleep(1)
            (small / "after-close.md").write_text("changed with the tab closed\n")
            time.sleep(4)
            after_change = LOG[before:]
            time.sleep(max(0, 75 - (time.time() - closed_at)))  # a minute and more with the tab closed
            after_minute = LOG[before:]
            # back online, still no tab: does the waiting Background Sync run now? (a network change, not a file change)
            ctx.set_offline(False)
            probe = ctx.new_page()
            pc = ctx.new_cdp_session(probe)
            probe.goto("about:blank")
            pc.send("Network.enable")
            pc.send("Network.emulateNetworkConditions", {"offline": False, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
            time.sleep(5)
            online = LOG[before:]
            ctx.close()
        import urllib.parse

        def closed_only(entries):
            """Worker events stamped after the tab closed (its own clock: Date.now(), wall clock as here)."""
            out = []
            for _, w in entries:
                q = urllib.parse.parse_qs(w)
                if int(q.get("t", ["0"])[0]) > closed_at * 1000:
                    out.append(q.get("what", [""])[0])
            return out
        res["worker_events_while_the_tab_was_open"] = [urllib.parse.parse_qs(w).get("what", [""])[0] for t_, w in LOG
                                                       if int(urllib.parse.parse_qs(w).get("t", ["0"])[0]) <= closed_at * 1000]
        log_change = closed_only(after_change)
        log_minute = closed_only(after_minute)
        log_online = closed_only(online)
        ran = bool(log_change or log_minute)
        res["entries"]["run_closed"] = {
            "label": "Run with the tab closed", "can": ran,
            "tries": {
                "background_sync": {"can": any("sync keeper" in w and not w.startswith("periodic") for w in log_change + log_minute),
                                    "evidence": {"registered": sync_reg, "worker": reg.get("sw"), "events_after_a_file_change": [w for w in log_change if not w.startswith("periodic")],
                                                 "events_in_the_75_s_after_close": [w for w in log_minute if not w.startswith("periodic")],
                                                 "events_after_going_online_with_no_page_of_it_open": log_online}},
                "periodic_sync": {"can": any(w.startswith("periodicsync") for w in log_minute),
                                  "evidence": {"permission": reg.get("periodic_permission"), "register": reg.get("periodic"), "tags": reg.get("periodic_tags"),
                                               "events_in_the_75_s_after_close": [w for w in log_minute if w.startswith("periodicsync")]}},
            },
            "evidence": f"after closing the tab: {len(log_change)} worker events after a file change, {len(log_minute)} in 75 s; going online then gave {log_online}",
            "summary": ("No: with the tab closed its worker got no event when a file changed or a minute passed"
                        if not ran else "Partly: its worker ran with the tab closed"),
        }
        shown = [w for w in log_change + log_minute if "notify=[shown]" in w]
        res["entries"]["notify_closed"] = {
            "label": "Notify with the tab closed", "can": bool(shown),
            "evidence": {"notifications_from_file_changes_or_time": shown,
                         "what_a_worker_could_do_when_woken": [w for w in log_online if "notify=" in w],
                         "why": "a worker may only show one while handling an event (push, sync, a click); a file change or a minute gave it none"},
            "summary": "No: a worker can show one only while it handles an event, and nothing woke it" if not shown else "Yes",
        }
        badge = None
        res["entries"]["tray"] = {
            "label": "An item in the tray", "can": False,
            "evidence": {"tray_like_names_in_window_and_navigator": R["features"]["tray_like"], "setAppBadge_offered": R["features"]["setAppBadge"],
                         "note": "no web API puts an item in the system tray ('statusbar' is the browser window's own status bar, a BarProp); the Badging API marks an installed app's own icon"},
            "summary": "No: there is no web API for one",
        }
        res["corpus_made_s"] = round(made, 1)
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(res, indent=1))
        for k, e in res["entries"].items():
            print(f"{k}: can={e['can']} | {e['summary']}")
        print("wrote", OUT)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
