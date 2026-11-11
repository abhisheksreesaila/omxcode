"""Web host: serves a mojoui app with FastHTML + HTMX.

The app itself is Mojo, compiled as a Python module (`mojoui_app`, built by
`scripts/build.sh <example> web` from hosts/web_main.mojo). This file only turns
its screen (JSON nodes) into plain HTML controls and sends browser events back.
Every control is standard HTML (input, select, range, progress, img), so the
browser draws its own native widgets; HTMX (vendored in static/, pinned 2.0.7)
posts events. The one piece of JavaScript is CANVAS_JS below, a fixed adapter for
Canvas views: it streams the frames the Mojo app paints (JPEG, pulled one at a time,
so a slow link just gets fewer frames) and sends pointer gestures back as events.

Run: pixi run python mojoui/hosts/web.py build/hello/web [port]
"""

import ctypes
import gzip
import hashlib
import os
import importlib
import io
import json
import re
import time
import traceback
import struct
import sys
from urllib.parse import urlsplit
import threading
import uuid
import zlib
from collections import OrderedDict
from pathlib import Path

from fasthtml.common import (
    A, to_xml, Button, Canvas, Dialog, Div, FastHTML, Form, H1, H2, H3, H4, Header, Hr, I, Img, Input, Label, Link, Main, Meta, NotStr,
    Iframe, Option, P, Progress, Response, Script, Select, Span, Style, Table, Tbody, Td, Textarea, Th, Thead, Title, Tr, UploadFile,
)
from PIL import Image

# Mirrors mojoui/view.mojo and mojoui/diff.mojo.
(TEXT, BUTTON, VSTACK, HSTACK, SPACER, FIELD, TOGGLE, DROPDOWN, SLIDER, PROGRESS, DIVIDER, SCROLL, IMAGE,
 SEGMENTED, RADIO, TEXTAREA, ALERT, TABS, NAVBAR, DATE, ICON, GRID, LAZYLIST, CANVAS, BOARD, OVERLAY, MENUBAR, MENU, ITEM,
 DIALOG, TOAST, POPOVER, CLIPBOARD, TABLE, ROUTE, DRAG, DROP, EMBED, PARAGRAPH, WEBCOMP) = range(1, 41)
CHOICES = (DROPDOWN, SEGMENTED, RADIO, TABS)  # value = selected index
BODY, TITLE, HEADLINE, CAPTION = 0, 1, 2, 3
PLAIN, PROMINENT, DESTRUCTIVE, SUBTLE, ICON_ONLY, TOOL, TOOL_ON, ICON_ON, TOOL_INLINE, TOOL_INLINE_ON, TOKEN, TOKEN_LIT = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
START, CENTER, END = 1, 2, 3
SET_TEXT, SET_MSG, SET_VALUE, SET_IMAGE, SET_FRAMES, SET_PLACE, SET_SIZE, SET_TIP, SET_TONES = 1, 2, 3, 4, 5, 6, 7, 8, 9
KEY = 7  # a canvas gesture: a key pressed while it had focus (text = the key, dx = modifiers)
SECONDARY = 8  # a right click on a canvas (x, y): where a context menu opens
CHECKED, DISABLED, DANGER = 1, 2, 4  # menu item flags (mojoui/menus.mojo)
# The hosted copy's switch (goal 62, docs/web-public.md): a server on the public internet. The agent link and the dev
# routes are off, a visitor's files live only in its session, controls that name a file take only what the visitor
# uploaded, no answer carries a server path, sessions are made only for a page load, held to a cap and ended when idle.
PUBLIC_SETTING = os.environ.get("MOJOUI_PUBLIC", "")  # (1 or 0: anything else stops the server, which won't guess)
PUBLIC = PUBLIC_SETTING == "1"
AGENT_SOCKET = "" if PUBLIC else os.environ.get("MOJOUI_AGENT_SOCKET", "")  # an agent host may attach here (docs/agent.md: the agent link)
# scripts/dev.sh's server (goal 34b M1c): widgets reload when their sources change, source maps are served; only
# 127.0.0.1 may ask, /dev/reload only with the token. Refused unless the app's build is a debug build (D-678), and never
# to be set on a deployed host (docs/js.md).
DEV = os.environ.get("MOJOUI_DEV") == "1" and not PUBLIC
DEV_TOKEN = os.environ.get("MOJOUI_DEV_TOKEN", "")
EVENT_DELAY = float(os.environ.get("MOJOUI_EVENT_DELAY_MS", "0")) / 1000  # checks only: answers events this much later
WAIT_S = float(os.environ.get("MOJOUI_WAIT_S", "0"))  # how long /wait holds with nothing to say (0: as long as the tab lives)
PUSH = os.environ.get("MOJOUI_PUSH", "1" if PUBLIC else "0") == "1"  # (local apps keep pulling at the display's rate)
PUSH_HZ = float(os.environ.get("MOJOUI_PUSH_HZ", "30"))  # how often /push paints its playing canvases (new pictures only are sent)
PUSH_MAX_S = float(os.environ.get("MOJOUI_PUSH_MAX_S", "240"))  # a push stream's longest life (a platform's request limit)
JPEG_QUALITY = 85
MAX_SESSIONS = int(os.environ.get("MOJOUI_MAX_SESSIONS", "6" if PUBLIC else "200"))  # public: past it, a busy page; else the oldest tab closes
IDLE_S = float(os.environ.get("MOJOUI_IDLE_S", "300" if PUBLIC else "0"))  # a tab with no input this long ends (0: never)
UNTOUCHED_S = 25.0  # public mode: a session whose page never came back (no /wait, frame or event) ends after this (round 4: 45 → 10)
SESSION_MAX_S = float(os.environ.get("MOJOUI_SESSION_MAX_S", "3600" if PUBLIC else "0"))  # public: a visit's longest life (0: none)
# public mode, new sessions (goal 62 round 3: 60 loads a second slowed every other tab): the whole server's rate and burst,
# one address's (X-Real-IP, which the platform's proxy sets), and, near the cap, the sessions one address may hold
NEW_PER_S = float(os.environ.get("MOJOUI_NEW_PER_S", "2"))
NEW_BURST = float(os.environ.get("MOJOUI_NEW_BURST", "6"))
IP_PER_S = float(os.environ.get("MOJOUI_IP_NEW_PER_S", "0.5"))
IP_BURST = 3.0
PER_IP = int(os.environ.get("MOJOUI_PER_IP", "2"))  # (round 4: at all times, not only near the cap)
UPLOADS_AT_ONCE = 2  # public mode: a visitor's uploads in flight
UPLOADS_IN_FLIGHT = int(os.environ.get("MOJOUI_UPLOADS_IN_FLIGHT_MB", "512")) << 20  # public mode: every upload in flight together
HEADER_S = 10.0  # public mode: a connection's request headers arrive within this (from its start, or partial ones after a response)
BODY_RATE = 16 << 10  # public mode: a request body arrives at this many bytes a second at least, after BODY_GRACE_S
BODY_GRACE_S = 10.0
BODY_IDLE_S = 15.0  # public mode: no part of a body for this long ends the request
BEHIND_PROXY = os.environ.get("MOJOUI_BEHIND_PROXY") == "1"  # public: a proxy sets X-Real-IP; without one it's the visitor's to forge, so unread (round 6)
PER_PEER = int(os.environ.get("MOJOUI_PER_PEER", "64"))  # public mode, no proxy in front: connections from one peer at once
ADDRESS_REQUESTS = 48  # public mode: one address's requests in flight (a tab holds about 12: /wait, /push, frames, events)
SESSION_REQUESTS = 6  # public mode: a session's blocking requests in flight (frames, events): past them, "retry" without a thread
# public mode: a table's memory once read (the upload check measures it), one table's and a visitor's tables' together
TABLE_KB = int(os.environ.get("MOJOUI_TABLE_MB", "256")) << 10
VISITOR_TABLES_KB = int(os.environ.get("MOJOUI_VISITOR_TABLES_MB", "384")) << 10
STATIC = Path(__file__).parent / "static"
ICONS = {p.stem: re.sub(r">\s+<", "><", re.sub(r"\s+", " ", p.read_text().split("-->", 1)[-1].strip()))
         for p in (STATIC / "icons").glob("*.svg")}  # Lucide (ISC)
LIST_WINDOW = 30  # rows sent around the visible part of a LazyList

# The host's own style sheet (served as mojoui.css by content hash; GTK's WebComponent views load it too, goal 34 M3).
CSS = (STATIC / "mojoui.css").read_text()


MENU_JS = r"""
// Menus (mojoui/menus.mojo, D-154): a bar menu opens on its title and closes on a click elsewhere or Escape; a context
// menu is placed inside its anchor (the view tagged data-anchor) and asks the app to close it when clicked away; a
// shortcut ("Ctrl+S") pressed anywhere fires the item that declares it.
(() => {
  const menus = window.mojouiMenu = {
    closeAll() { document.querySelectorAll('.menu.open:not(.context)').forEach(m => m.classList.remove('open')); },
    // the app's on_close for a context menu (or a popover): its own node and session, never inherited hx-vals
    dismiss(el) {
      const v = document.getElementById('mojoui-v').value;
      if (el.dataset.v !== undefined && el.dataset.v !== v) {  // the screen was rebuilt since (node numbers moved): its successor, by kind and title
        el = [...document.querySelectorAll(`[data-kind="${el.dataset.kind}"]`)].find(x => x.dataset.title === el.dataset.title && x.dataset.v === v);
        if (!el) return;
      }
      if (el.dataset.closing) return; el.dataset.closing = '1';
      htmx.ajax('POST', `/e/${el.dataset.sid}`, { values: { n: Number(el.dataset.node), second: 1, v }, swap: 'none', source: document.body }); },
    toggle(title) { const m = title.parentElement, was = m.classList.contains('open'); menus.closeAll(); if (!was) m.classList.add('open'); },
    place() {
      document.querySelectorAll('.menu.context, .popover').forEach(m => {
        const a = document.querySelector(`[data-tag="${m.dataset.anchor}"]`), r = a ? a.getBoundingClientRect() : { left: 0, top: 0, bottom: 0 };
        const at = Number(m.dataset.x) || Number(m.dataset.y);  // a popover with no point sits under its anchor
        let x = at || m.classList.contains('menu') ? r.left + Number(m.dataset.x) : r.left, y = at || m.classList.contains('menu') ? r.top + Number(m.dataset.y) : r.bottom + 4;
        const w = m.offsetWidth || 260, h = m.offsetHeight || 200;
        if (x + w > innerWidth - 8) x = Math.max(8, innerWidth - 8 - w);
        if (y + h > innerHeight - 8) y = Math.max(8, innerHeight - 8 - h);
        m.style.left = x + 'px'; m.style.top = y + 'px';
      });
      document.querySelectorAll('.toast:not([data-timer])').forEach(t => {  // a toast leaves by itself
        // (mid-settle, htmx lends an element with a reused id the old attributes: no seconds → no timer; and the element
        // the timer holds may be something else by the time it fires)
        const ms = Number(t.dataset.seconds) * 1000;
        if (!(ms > 0)) return;
        t.dataset.timer = setTimeout(() => { if (!document.body.contains(t)) return; if (t.dataset.kind === 'toast') menus.dismiss(t); else if (t.dataset.kind === 'notice') t.remove(); }, ms);
      });
    },
  };
  document.addEventListener('pointerdown', e => {
    if (!e.target.closest('.menu')) { menus.closeAll(); document.querySelectorAll('.menu.context').forEach(menus.dismiss); }
    if (!e.target.closest('.popover')) document.querySelectorAll('.popover').forEach(menus.dismiss);
  }, true);
  // A canvas drag outlives its canvas: the press's reply can rebuild the page, and a drag's moves and its release then
  // land on the new canvas, which never saw the press. They go to whichever canvas now shows the dragged node (st.drag),
  // so a drag-select isn't lost on a slow reply (omxplorer's drag flaked: one cell one run, 2×2 the next, 3×3 as on GTK
  // only when no move was lost; scripts/web_drag_reliable.py repeats it).
  for (const kind of ['pointermove', 'pointerup', 'pointercancel']) document.addEventListener(kind, e => {
    const d = window.mojouiDrag;
    if (!d || e.mojouiHandled || e.pointerId !== d.id) return;
    const div = document.querySelector(`[data-kind=canvas][data-node="${d.n}"]`);
    // (the new canvas may not be wired up yet, a screen still settling: wire it now, or the drag's moves were dropped
    // and a drag-select lost its last moves: 3 runs in 12 on 2026-10-28, and goal 32's web golden had kept one such run)
    if (div && !div.mojoui && window.mojouiAttach) window.mojouiAttach(div);
    if (div && div.mojoui && div.mojoui.drag) div.mojoui.drag(e, kind === 'pointermove' ? 'move' : 'up');
    else if (kind !== 'pointermove') window.mojouiDrag = null;
  });
  document.addEventListener('mouseover', e => {  // an open bar: hovering another title switches menus, as menus do
    const t = e.target.closest('.menubar > .menu > .menu-title');
    if (t && document.querySelector('.menubar > .menu.open') && !t.parentElement.classList.contains('open')) { menus.closeAll(); t.parentElement.classList.add('open'); }
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && document.querySelector('.menu.open:not(.context)')) { menus.closeAll(); return; }
    if (e.key === 'Escape') { const c = document.querySelector('.menu.context, .popover') || document.querySelector('.dialog-layer');
      if (c) { menus.dismiss(c); e.preventDefault(); e.stopPropagation(); return; } }
    if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
    const fkey = /^F\d{1,2}$/.test(e.key);
    if (!(e.ctrlKey || e.metaKey || e.altKey || fkey)) return;
    const key = e.key.length === 1 ? e.key.toUpperCase() : e.key;
    const name = (e.ctrlKey || e.metaKey ? 'Ctrl+' : '') + (e.shiftKey ? 'Shift+' : '') + (e.altKey ? 'Alt+' : '') + key;
    const typing = e.target.matches && e.target.matches('input, textarea, [contenteditable], [contenteditable] *');
    if (typing && ['Ctrl+C', 'Ctrl+X', 'Ctrl+V', 'Ctrl+A', 'Ctrl+Z'].includes(name)) return;  // a field's own copy, paste, select all, undo
    const item = [...document.querySelectorAll('[data-kind=item]:not([disabled])')].find(i => i.dataset.shortcut === name);
    if (item) { e.preventDefault(); e.stopPropagation(); menus.closeAll(); item.click(); }
  }, true);
  document.addEventListener('htmx:afterSettle', menus.place);
  // Clipboard(text, version): a new version puts the text on the system clipboard (window.mojouiClip keeps it for tests)
  const copyAsked = () => document.querySelectorAll('[data-kind=clipboard]').forEach(c => {
    const v = Number(c.dataset.version || 0);
    if (v > 0 && v !== window.mojouiClipVersion) {
      window.mojouiClipVersion = v; window.mojouiClip = c.dataset.text;
      if (navigator.clipboard) navigator.clipboard.writeText(c.dataset.text).catch(() => {});
    }
  });
  document.addEventListener('htmx:afterSettle', copyAsked);
  // Posts the page makes on its own (a route, the window's size, the colour scheme, a drop) each go in a lane of their
  // own: htmx keeps one request per source element and drops all but the last one queued behind it, so a size posted
  // beside a deep link's route (both on load) was lost when they shared document.body.
  // A lane is also what keeps an answer: htmx drops the answer to a request whose source element left the page while
  // it was out (its out-of-band swaps never happen), and a whole-screen answer replaces every element under
  // #mojoui-root. So every request whose answer carries screen changes goes from a lane (window.mojouiLane), never
  // from #mojoui-root or a view inside it: the effects' /pending sent from the root lost the logs tab's reply under
  // load (D-546).
  const lane = name => { let el = document.getElementById('mojoui-lane-' + name);
    if (!el) { el = document.createElement('i'); el.id = 'mojoui-lane-' + name; el.hidden = true; document.body.append(el); } return el; };
  window.mojouiLane = lane;
  // Two answers that each carry the whole screen (a route and a resize posted together on load, an event racing a
  // poll) can arrive out of order: an older screen (a lower #mojoui-v) never replaces a newer one.
  document.addEventListener('htmx:oobBeforeSwap', e => {
    const d = e.detail;
    if (!d || !d.target || d.target.id !== 'mojoui-root' || !d.fragment || !d.fragment.querySelector) return;
    const incoming = d.fragment.querySelector('#mojoui-v'), shown = document.getElementById('mojoui-v');
    if (incoming && shown && Number(incoming.value) < Number(shown.value)) d.shouldSwap = false;
  });
  // Draggable / DropTarget (DND_JS): the browser's drag and drop; a drop posts the payload as the target's on_drop
  document.addEventListener('dragstart', e => { const d = e.target.closest && e.target.closest('[data-kind=drag]');
    if (!d) return; e.dataTransfer.effectAllowed = 'copy'; e.dataTransfer.setData('text/plain', d.dataset.payload || ''); });
  const dropAt = e => e.target.closest && e.target.closest('[data-kind=drop]');
  document.addEventListener('dragover', e => { const t = dropAt(e);
    document.querySelectorAll('.drop-over').forEach(x => { if (x !== t) x.classList.remove('drop-over'); });
    if (t) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; t.classList.add('drop-over'); } });
  document.addEventListener('dragleave', e => { const t = dropAt(e); if (t && !t.contains(e.relatedTarget)) t.classList.remove('drop-over'); });
  document.addEventListener('drop', e => { const t = dropAt(e);
    document.querySelectorAll('.drop-over').forEach(x => x.classList.remove('drop-over'));
    if (!t) return; e.preventDefault();
    const v = document.getElementById('mojoui-v');
    if (e.dataTransfer.files && e.dataTransfer.files.length) {  // files from outside (DropTarget's on_file): each uploads, then its path
      if (t.dataset.files !== '1') return;
      // (all of them in one upload: the server hands them to on_file one after another, so the first one's new screen
      // can't make the rest arrive for a version that's gone)
      const form = new FormData(); for (const f of e.dataTransfer.files) form.append('file', f);
      form.append('n', t.dataset.node); form.append('v', v ? v.value : -1);
      const send = tries => fetch(`/dropfile/${t.dataset.sid}`, { method: 'POST', body: form }).then(r => r.text()).then(html => {
        if (html) htmx.swap(document.body, html, { swapStyle: 'none' }); })
        .catch(() => { if (tries < 2) setTimeout(() => send(tries + 1), 1000); });  // (a dropped connection: once or twice more, round 4)
      send(0);
      return;
    }
    htmx.ajax('POST', `/e/${t.dataset.sid}`, { values: { n: Number(t.dataset.node), text: e.dataTransfer.getData('text/plain'), v: v ? v.value : -1 }, swap: 'none', source: lane('drop') });
  });
  // FileSaver (DOWNLOAD_JS): the answer to /save appends an i.mojoui-download with the file's URL to the body; the page downloads it and removes it
  new MutationObserver(() => document.querySelectorAll('i.mojoui-download').forEach(d => { d.remove();
    const a = document.createElement('a'); a.href = d.dataset.url; a.download = d.dataset.name || ''; document.body.append(a); a.click(); a.remove(); })
  ).observe(document.documentElement, { childList: true, subtree: true });  // (this script runs in the head: no body yet)
  // After an answer's out-of-band swaps, each hook runs once, however many elements the answer swapped: one timer per
  // element and hook ran whole() 2,700 times in one streamed reply, each a style-sheet walk and a forced layout,
  // which dropped a third of the page's frames (goal 48)
  const swapped = new Set(); let swapTimer = 0;
  const afterSwaps = fn => document.addEventListener('htmx:oobAfterSwap', () => { swapped.add(fn);
    if (!swapTimer) swapTimer = setTimeout(() => { swapTimer = 0; const fns = [...swapped]; swapped.clear();
      for (const f of fns) try { f(); } catch (e) { console.error(e); } }, 0); });  // (one failing hook doesn't skip the rest)
  // Scroll(pinned): stays at its end as its content grows, unless scrolled up to read (back at the end, it follows again)
  const pin = () => document.querySelectorAll('.scroll[data-pin="1"]').forEach(e => { if (e.dataset.follow !== '0') e.scrollTop = e.scrollHeight; });
  document.addEventListener('scroll', e => { const t = e.target;
    if (t && t.dataset && t.dataset.pin === '1') t.dataset.follow = t.scrollHeight - t.scrollTop - t.clientHeight <= 4 ? '1' : '0'; }, true);
  document.addEventListener('htmx:afterSettle', pin);
  // A role whose width is its content's in whole pixels (Surface.whole_width: the look writes --mojoui-whole-width), as
  // a script that sizes a pill from scrollWidth does (omxqua's Beacon): found by the rules that carry the marker
  // (the rules are read again only when the page's style sheets change; every width is cleared, then all are read in
  // one layout, then set)
  let wholeSheets = [], wholeSel = '';
  const whole = () => { const sheets = [...document.styleSheets];
    if (sheets.length !== wholeSheets.length || sheets.some((sh, i) => sh !== wholeSheets[i])) {
      const sel = [];
      for (const sh of sheets) { let rules; try { rules = sh.cssRules; } catch (e) { continue; }
        for (const r of rules) if (r.style && r.style.getPropertyValue('--mojoui-whole-width')) sel.push(r.selectorText); }
      wholeSheets = sheets; wholeSel = sel.join(', ');
    }
    if (!wholeSel) return;
    const els = [...document.querySelectorAll(wholeSel)];
    els.forEach(e => { e.style.width = ''; });
    const widths = els.map(e => e.scrollWidth);
    els.forEach((e, i) => { e.style.width = widths[i] + 'px'; }); };
  document.addEventListener('htmx:afterSettle', whole);
  afterSwaps(whole);
  addEventListener('load', whole);
  afterSwaps(pin);
  addEventListener('load', pin);
  // Route(path): the URL's hash is the app's place. A hash the app doesn't show (the page opened at a link, Back,
  // Forward, a typed URL) goes to the app as on_change; a path the app moves to is written to the URL as a new entry.
  const routeEl = () => document.querySelector('[data-kind=route]');
  const hashPath = () => location.hash.replace(/^#/, '') || '/';
  let appRoute = null, routeAsked = null;
  const tellRoute = () => {
    const r = routeEl(), p = hashPath();
    if (!r || p === (r.dataset.route || '/') || p === routeAsked) return;
    routeAsked = p;
    const v = document.getElementById('mojoui-v');
    htmx.ajax('POST', `/e/${r.dataset.sid}`, { values: { n: Number(r.dataset.node), text: p, v: v ? v.value : -1, route: 1 }, swap: 'none', source: lane('route') });
  };
  const writeRoute = () => {
    const r = routeEl();
    if (!r) return;
    const want = r.dataset.route || '/';
    if (appRoute === null) { appRoute = want; return; }  // (what the page opened with: the hash may be a link to elsewhere)
    if (want === appRoute) return;
    appRoute = want; routeAsked = null;
    if (hashPath() !== want) history.pushState(null, '', '#' + want);
  };
  // After every swap too: a Route that first appears in a later screen (not on the first page) still gets the hash
  // the page opened at (tellRoute asks once per hash; the app's own moves are written first, so they match).
  const syncRoute = () => { writeRoute(); tellRoute(); };
  addEventListener('load', syncRoute);
  addEventListener('hashchange', tellRoute);
  addEventListener('popstate', tellRoute);
  document.addEventListener('htmx:afterSettle', syncRoute);
  afterSwaps(syncRoute);
  afterSwaps(copyAsked);
  afterSwaps(menus.place);
  addEventListener('load', menus.place); addEventListener('resize', menus.place);
  // The app lays out to the window (App.resize): its size on load, then whenever it settles after a change.
  let sizeTimer = 0, sizeSent = '';
  const tellSize = () => {
    const root = document.getElementById('mojoui-root');
    const w = Math.round(innerWidth), h = Math.round(innerHeight);
    if (!root || !root.dataset.sid || sizeSent === w + 'x' + h) return;
    sizeSent = w + 'x' + h;
    htmx.ajax('POST', `/resize/${root.dataset.sid}`, { values: { w, h }, swap: 'none', source: lane('size') });
  };
  addEventListener('load', tellSize);
  // The browser's colour scheme (App.appearance): on load and when the person switches.
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const tellScheme = () => {
    const root = document.getElementById('mojoui-root');
    if (root && root.dataset.sid) htmx.ajax('POST', `/appearance/${root.dataset.sid}`, { values: { dark: scheme.matches ? 1 : 0 }, swap: 'none', source: lane('scheme') });
  };
  addEventListener('load', tellScheme);
  scheme.addEventListener('change', tellScheme);
  addEventListener('resize', () => { clearTimeout(sizeTimer); sizeTimer = setTimeout(tellSize, 120); });
})();
"""

EFFECTS_JS = r"""
// .arrive() (goal 48): a view arrives once. Swaps replace elements, which would replay the animation on every update;
// a view already seen (by its node id) is marked arrived before the next paint (mutation callbacks run first).
(() => {
  const seen = new Set();
  // (a swap may replace the element, or morph its class back to the server's, which drops the mark: both are caught)
  const mark = el => { if (!el.id) return;
    if (seen.has(el.id)) { if (!el.classList.contains('mojoui-arrived')) el.classList.add('mojoui-arrived'); } else seen.add(el.id); };
  new MutationObserver(list => { for (const m of list) {
    if (m.type === 'attributes') { if (m.target.classList && m.target.classList.contains('mojoui-arrive')) mark(m.target); continue; }
    for (const n of m.addedNodes) {
      if (n.nodeType !== 1) continue;
      if (n.classList.contains('mojoui-arrive')) mark(n);
      n.querySelectorAll && n.querySelectorAll('.mojoui-arrive').forEach(mark); } } })
    .observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
})();
// The rest of the screen, fetched once for the whole page (/pending): one request at a time, at most ten a second, and once
// more after the last change. Every playing canvas used to ask on its own beside /wait's loop: dozens a second, which
// crowded a slow link's six connections and left the pictures queued (goal 62 M4).
(() => {
  let out = null, last = 0, again = false, timer = 0;
  window.mojouiPending = () => {
    if (out || timer) { again = true; return out || Promise.resolve(); }
    const wait = 100 - (performance.now() - last);
    if (wait > 0) { timer = setTimeout(() => { timer = 0; window.mojouiPending(); }, wait); return Promise.resolve(); }
    const root = document.getElementById('mojoui-root');
    if (!root || !root.dataset.sid) return Promise.resolve();
    last = performance.now(); again = false;
    out = htmx.ajax('POST', `/pending/${root.dataset.sid}`, { values: { v: document.getElementById('mojoui-v').value }, swap: 'none', source: window.mojouiLane('effects') })
      .catch(() => {}).finally(() => { out = null; if (again) window.mojouiPending(); });
    return out;
  };
  window.mojouiPendingBusy = () => !!(out || timer || again);
})();
// Changes the page didn't ask for (goal 33, goal 62 M0): an effect's answer, a timer, a background job that ended, an
// agent's step. The page always holds one /wait open; the server answers it only when changes are pending (then the page
// fetches them, /pending, as frames do) or the tab is gone, so an idle page fetches nothing. Before goal 62 it listened
// only while #mojoui-busy said requests or timers were out, and a job's end (an open, a chart) had nobody to tell.
(() => {
  let running = false;
  async function loop() {
    if (running) return;
    running = true;
    try {
      for (;;) {
        const root = document.getElementById('mojoui-root');
        if (!root || !root.dataset.sid) break;
        let said = '0';
        try { said = await (await fetch(`/wait/${root.dataset.sid}`, { cache: 'no-store' })).text(); }
        catch (e) { await new Promise(ok => setTimeout(ok, 1000)); continue; }
        if (said.startsWith('gone')) { if (window.mojouiGone) window.mojouiGone(said.slice(5)); break; }
        if (said === '1') await window.mojouiPending();
        else if (said !== '0') await new Promise(ok => setTimeout(ok, 1000));  // (an answer the page doesn't know: a proxy's error page)
      }
    } finally { running = false; }
  }
  document.addEventListener('DOMContentLoaded', loop);
  document.addEventListener('htmx:afterSettle', loop);
})();
"""

PAGE_JS = r"""
// The page's own behaviour as listeners: the Content-Security-Policy allows no inline script, inline handler or eval
// (D-593), so what used to sit in onclick/onfocus/onkeydown attributes, htmx's eval'd trigger filters and hx-vals "js:"
// lives here, keyed by data attributes the host renders.
(() => {
  const skinClasses = () => {  // the theme's body classes (skin(): #mojoui-skin-classes)
    const s = document.getElementById('mojoui-skin-classes');
    if (s && document.body.className !== (s.dataset.classes || '')) document.body.className = s.dataset.classes || '';
  };
  document.addEventListener('DOMContentLoaded', skinClasses);
  document.addEventListener('htmx:oobAfterSwap', skinClasses);
  // an in-place editor: focus selects its text (data-focus=select) or puts the caret at its end (end)
  document.addEventListener('focusin', e => {
    const t = e.target;
    if (!t.matches || !t.matches('input[data-focus]')) return;
    if (t.dataset.focus === 'end') { const k = t.value.length; t.setSelectionRange(k, k); } else t.select();
  });
  // a field with on_cancel: Escape posts it (second=2) with its text. Capture phase, as the inline handler it replaces
  // saw synthetic (non-bubbling) keys too; a listener before it that stopped the key (an open menu, held keys) wins.
  document.addEventListener('keydown', e => {
    const t = e.target;
    if (e.key !== 'Escape' || e.cancelBubble || !t.matches || !t.matches('input[data-cancel]')) return;
    e.preventDefault();
    htmx.ajax('POST', t.dataset.cancel, { values: { n: Number(t.dataset.node), second: 2, text: t.value, v: document.getElementById('mojoui-v').value }, swap: 'none', source: document.body });
  }, true);
  document.addEventListener('click', e => {
    const title = e.target.closest && e.target.closest('.menu-title[data-toggle]');
    if (title) window.mojouiMenu.toggle(title);
    if (e.target.closest && e.target.closest('[data-kind=item][data-closes]')) window.mojouiMenu.closeAll();
  });
  // an alert: Escape answers like its first button (Cancel)
  document.addEventListener('keyup', e => {
    if (e.key !== 'Escape') return;
    const b = document.querySelector('#mojoui-overlay dialog.alert .buttons button');
    if (b) b.click();
  });
  // a long list: Enter and Space choose a row as a click does; each request for rows says where the list is scrolled
  document.addEventListener('keyup', e => {
    if ((e.key === 'Enter' || e.key === ' ') && e.target.matches && e.target.matches('.lazylist .row')) e.target.click();
  });
  document.addEventListener('htmx:configRequest', e => {
    const el = e.detail && e.detail.elt;
    if (el && el.dataset && el.dataset.kind === 'list') e.detail.parameters.top = el.scrollTop;
  });
  // The shell (a GET that wasn't a page load, from a browser that sends no Sec-Fetch headers): load the page for real.
  // A page loaded that way drops ?boot=1 from its address.
  document.addEventListener('DOMContentLoaded', () => {
    const root = document.getElementById('mojoui-root');
    if (root && root.dataset.boot === '1') location.replace('/?boot=1' + location.hash);
    else if (/[?&]boot=1/.test(location.search)) history.replaceState(null, '', '/' + location.hash);
  });
  // A page that goes away (closed, reloaded, left) ends its session at once, so a reload doesn't hold two (public mode
  // counts them against its cap). A page brought back from the back-forward cache then finds it gone and says so.
  addEventListener('pagehide', () => { const r = document.getElementById('mojoui-root'); if (r && r.dataset.sid) navigator.sendBeacon(`/bye/${r.dataset.sid}`); });
  // The server ended this tab (idle too long, or it restarted): the page says so, over everything, and offers a reload.
  window.mojouiGone = text => {
    let d = document.getElementById('mojoui-gone');
    if (!d) { d = document.createElement('div'); d.id = 'mojoui-gone'; d.className = 'mojoui-gone'; d.setAttribute('role', 'alertdialog'); document.body.appendChild(d); }
    const p = document.createElement('p'), b = document.createElement('button');
    p.textContent = text || 'This page has expired. Reload it to start a new one.';
    b.textContent = 'Reload'; b.className = 'button prominent'; b.addEventListener('click', () => location.reload());
    d.replaceChildren(p, b);
    const root = document.getElementById('mojoui-root'); if (root) root.inert = true;
  };
})();
"""

BOARD_JS = r"""
// mojoui Board adapter (fixed, part of the web host). Drag an object's header to move it, its
// bottom-right corner to resize it; the app gets one event at the end (PAN = moved, ZOOM = resized,
// x = the object's index, dx/dy = how far) and answers with the final, snapped layout: a hidden
// "place" marker inside the object (or the board) that this adapter applies, so nothing re-renders.
(() => {
  const PAN = 1, ZOOM = 2;
  const shape = () => document.getElementById('mojoui-v').value;
  const revealed = window.mojouiRevealed = window.mojouiRevealed || {};
  function reveal(board, token) {
    // Scrolls the board's scroller so object (token % 64 - 1) shows, clear of the islands, then marks it briefly.
    const k = token % 64 - 1, obj = board.querySelectorAll(':scope > .object')[k], sc = board.parentElement;
    if (!obj || !sc) return;
    const top = obj.offsetTop, left = obj.offsetLeft, page = sc.clientHeight, wide = sc.clientWidth;
    if (top < sc.scrollTop + 72 || top + Math.min(obj.offsetHeight, page - 160) > sc.scrollTop + page - 56) sc.scrollTop = Math.max(top - 88, 0);
    if (left < sc.scrollLeft || left + Math.min(obj.offsetWidth, wide - 48) > sc.scrollLeft + wide) sc.scrollLeft = Math.max(left - 24, 0);
    obj.classList.remove('revealed'); void obj.offsetWidth; obj.classList.add('revealed');
  }
  function place(mark) {
    const p = mark.parentElement, d = mark.dataset;
    if (!p || p.classList.contains('moving')) return;  // (a drag in progress owns the position)
    if (p.classList.contains('board')) {
      p.style.width = d.w + 'px'; p.style.height = d.h + 'px';
      const key = p.dataset.sid + '/' + p.dataset.node, token = Number(d.reveal || 0);
      if (token && revealed[key] !== token) { revealed[key] = token; requestAnimationFrame(() => reveal(p, token)); }
    }
    else { p.style.left = d.x + 'px'; p.style.top = d.y + 'px'; p.dataset.x = d.x; p.dataset.y = d.y; p.dataset.tone = d.tone || '0'; }
  }
  // Board(on_hold=…): a press on an object held still for HOLD_MS is a hold (number PRESS, x = its index); letting go
  // after it sends RELEASE. Any press counts (a canvas's too: its own gestures still run), but not on a control.
  const HOLD_MS = 350, PRESS = 4, RELEASE = 5;
  function holds(board) {
    if (board.mojouiHolds) return;
    board.mojouiHolds = true;
    board.addEventListener('pointerdown', e => {
      if (board.dataset.hold !== '1' || e.button !== 0) return;
      const obj = e.target.closest('.object');
      if (!obj || obj.parentElement !== board || e.target.closest('input, textarea, select, button, a, [contenteditable]')) return;
      const x0 = e.clientX, y0 = e.clientY, index = Number(obj.dataset.index);
      let held = false, done = false;
      const post = number => htmx.ajax('POST', `/e/${board.dataset.sid}`, { values: { n: Number(board.dataset.node), number,
        x: index, y: 0, dx: x0, dy: y0, zoom: 1, v: shape() }, swap: 'none', source: window.mojouiLane('board') });
      const timer = setTimeout(() => { if (!done) { held = true; post(PRESS); } }, HOLD_MS);
      const move = ev => { if (!held && Math.abs(ev.clientX - x0) + Math.abs(ev.clientY - y0) > 8) finish(null); };
      const finish = ev => {
        done = true; clearTimeout(timer);
        window.removeEventListener('pointermove', move, true); window.removeEventListener('pointerup', finish, true); window.removeEventListener('pointercancel', finish, true);
        if (held && ev) post(RELEASE);
      };
      window.addEventListener('pointermove', move, true); window.addEventListener('pointerup', finish, true); window.addEventListener('pointercancel', finish, true);
    }, true);
  }
  function attach(board) {
    if (board.mojouiBoard) return;
    board.mojouiBoard = true;
    board.addEventListener('pointerdown', e => {
      if (getComputedStyle(board).display === 'flex') return;  // the narrow list: nothing to drag
      const obj = e.target.closest('.object');
      if (!obj || obj.parentElement !== board || e.button !== 0) return;
      if (e.target.closest('input, textarea, select, button, canvas, a, [contenteditable]')) return;
      const r = obj.getBoundingClientRect();
      const resizing = e.clientX > r.right - 24 && e.clientY > r.bottom - 24;
      if (!resizing && e.clientY - r.top > 44) return;  // only the header moves it
      e.preventDefault();
      const x0 = e.clientX, y0 = e.clientY, left = obj.offsetLeft, top = obj.offsetTop, w = obj.offsetWidth, h = obj.offsetHeight;
      obj.classList.add('moving');
      obj.setPointerCapture(e.pointerId);
      const move = ev => {
        const dx = ev.clientX - x0, dy = ev.clientY - y0;
        if (resizing) { obj.style.width = Math.max(w + dx, 120) + 'px'; obj.style.height = Math.max(h + dy, 80) + 'px'; }
        else { obj.style.left = Math.max(left + dx, 0) + 'px'; obj.style.top = Math.max(top + dy, 0) + 'px'; }
      };
      const up = ev => {
        obj.removeEventListener('pointermove', move); obj.removeEventListener('pointerup', up); obj.removeEventListener('pointercancel', up);
        obj.classList.remove('moving');
        const mark = obj.querySelector(':scope > [data-kind=place]');
        if (mark && !resizing) place(mark);  // back where the app last put it; its answer (if it moved) follows
        const dx = ev.clientX - x0, dy = ev.clientY - y0;
        htmx.ajax('POST', `/e/${board.dataset.sid}`, { values: { n: Number(board.dataset.node), number: resizing ? ZOOM : PAN,
          x: Number(obj.dataset.index), y: 0, dx, dy, zoom: 1, v: shape() }, swap: 'none', source: window.mojouiLane('board') });
      };
      obj.addEventListener('pointermove', move); obj.addEventListener('pointerup', up); obj.addEventListener('pointercancel', up);
    });
  }
  const scan = () => { document.querySelectorAll('[data-kind=board]').forEach(b => { attach(b); holds(b); }); document.querySelectorAll('[data-kind=place]').forEach(place); };
  scan();
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
})();
"""

CANVAS_JS = r"""
// mojoui Canvas adapter (fixed, part of the web host; apps never contain JavaScript).
// Frames: pulled one at a time from /frame (JPEG painted by the Mojo app at the canvas's
// pixel size); pulled continuously while the canvas asks for frames, otherwise only when
// its version or size changes. Gestures: drag = PAN, wheel/pinch = ZOOM, click = TAP,
// sent through htmx like any other event, so the rest of the page updates as usual.
(() => {
  const PAN = 1, ZOOM = 2, TAP = 3, PRESS = 4, RELEASE = 5, DOUBLE = 6, KEY = 7, SECONDARY = 8, WHEEL = 9;
  const shape = () => document.getElementById('mojoui-v').value;
  // the theme a canvas was drawn in (skin()'s classes and tokens): a drawn view paints from the theme, so a switch
  // (light/dark, a skin) redraws it even when its version didn't move (D-673)
  const skinNow = () => { const k = document.getElementById('mojoui-skin-classes'); return k ? (k.dataset.classes || '') + '|' + (k.dataset.tokens || '') : ''; };
  // keys a canvas uses itself (the page mustn't scroll or move focus on them)
  const OWN_KEYS = new Set(['ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight', 'Tab', 'Enter', 'PageDown', 'PageUp', 'Home', 'End', 'Backspace', 'Delete', 'Escape', 'F2', ' ']);
  // Keys typed on a canvas before the in-place editor they open has appeared (a round trip later) wait here, then
  // go into it in order (Enter and Escape act as in it); with no editor (a read-only cell) they go to the canvas.
  // Page-wide: the screen that shows the editor replaces the canvas element that sent the first key.
  // Keys on a canvas go to the app in order, however fast (a value typed on a grid stays with the grid: its editor
  // only echoes it). An editor that has the keyboard itself (F2, a double click, a click in it) is different: its
  // Enter or Escape is answered with a screen without it, so the keys pressed meanwhile wait here, page-wide, and
  // then go to the canvas in order (or back into the editor if it's still there: a value it refused).
  const isChar = (k, m) => [...k].length === 1 && !(m & 6);
  const early = { typing: false, inflight: 0, from: null, keys: [], replaying: false };
  const hold = from => { early.typing = true; early.from = from; early.since = performance.now(); if (from) setTimeout(release, 1600); };
  function release() {
    if (!early.typing || early.inflight) return;
    const editor = document.querySelector('input.cell-editor');
    // the editor's Enter/Escape not answered yet (an editor still there after 1.5 s: the value was refused, it stays open)
    if (early.from && early.from.isConnected && editor === early.from && performance.now() - early.since < 1500) return;
    early.typing = false; early.from = null;
    const div = document.querySelector(`[data-kind=canvas][data-node="${window.mojouiKeyCanvas}"]`);
    while (early.keys.length) {
      const [k, m] = early.keys.shift();
      if (editor) {
        editor.focus();
        if (k === 'Enter') { hold(editor); editor.form.requestSubmit(); return; }
        if (k === 'Escape') {  // (replayed past the listener below, which would otherwise hold it again)
          early.replaying = true; editor.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); early.replaying = false;
          hold(editor); return;
        }
        if (k === 'Backspace') editor.value = editor.value.slice(0, -1);
        else if (isChar(k, m)) editor.value += k;
        const end = editor.value.length; editor.setSelectionRange(end, end);
      } else if (div && div.mojoui) {
        div.mojoui.sendKey(k, m);  // (in order: a value typed on the grid stays with the grid, however fast)
      }
    }
  }
  // Enter or Escape pressed in an in-place editor: its answer replaces the editor, so hold what comes next.
  document.addEventListener('keydown', e => {
    if (early.replaying || ['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
    const m = (e.shiftKey ? 1 : 0) + (e.ctrlKey || e.metaKey ? 2 : 0) + (e.altKey ? 4 : 0);
    if (early.typing) { e.preventDefault(); e.stopPropagation(); early.keys.push([e.key, m]); return; }
    if (e.target.matches && e.target.matches('input.cell-editor') && (e.key === 'Enter' || e.key === 'Escape')) hold(e.target);
  }, true);
  // Every canvas's gestures and keys, in the order they happened, one at a time: page-wide, not per canvas
  // element, because an answer can replace the element (a key that opens an editor rebuilds the screen) while
  // the keys typed after it are still waiting to go.
  const events = window.mojouiEvents = { queue: [], sending: false };
  const shownPics = new Map();  // canvas tag → {pic, bmp, w, h}: its last picture (40 at most)
  // (a fetch that fails on the network, a dropped keep-alive connection: a short wait and again, as /wait does; after a few,
  // a "retry" answer, so the canvas's loop goes on instead of ending in an unhandled "Failed to fetch", round 4)
  // (an event answered 204 + X-Mojoui-Retry, its session's requests full: sent again shortly, at most 5 times, round 5)
  const retried = new Map();
  document.addEventListener('htmx:afterRequest', e => {
    const x = e.detail.xhr, c = e.detail.requestConfig;
    if (!x || !c || x.status !== 204 || x.getResponseHeader('X-Mojoui-Retry') !== '1') return;
    const key = c.path + ' ' + JSON.stringify(c.parameters || {}), now = Date.now(), seen = retried.get(key);
    const tries = seen && now - seen.at < 10000 ? seen.tries + 1 : 1;
    retried.set(key, { tries, at: now }); if (retried.size > 200) retried.clear();
    if (tries > 5) return;
    setTimeout(() => { const p = htmx.ajax(c.verb.toUpperCase(), c.path, { values: c.parameters, swap: 'none', source: window.mojouiLane('retry') });
                       if (p && p.catch) p.catch(() => {}); }, 100 * tries);
  });
  const getFrame = async (sid, n, params) => {
    for (let tries = 0; ; tries++) {
      try { return await fetch(`/frame/${sid}/${n}?${new URLSearchParams(params)}`); }
      catch (e) {
        if (tries >= 3) return new Response(null, { status: 204, headers: { 'X-Mojoui-Retry': '1' } });
        await new Promise(ok => setTimeout(ok, 250 * (tries + 1)));
      }
    }
  };
  // Pictures pushed to playing canvases (/push): one streamed answer a page carries every playing canvas's new pictures,
  // painted on the server's clock, so a slow link pays no round trip a picture (goal 62 M4: a pull a picture held one
  // visitor's video near 10 a second at 100 ms). Canvases join when they start playing; the stream opens again when the
  // set or a size changes, or the screen changed under it; if it can't open, each canvas pulls as before.
  const push = { members: new Map(), ctrl: null, key: '', failed: !window.ReadableStream, timer: 0 };
  const pushOn = () => { const r = document.getElementById('mojoui-root'); return !!(r && r.dataset.push === '1') && !push.failed; };
  document.addEventListener('visibilitychange', () => pushChanged());  // (a hidden tab's stream closes; it opens again when shown)
  const pushSize = div => { const r = div.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    return `${Math.max(1, Math.round(r.width * dpr))}:${Math.max(1, Math.round(r.height * dpr))}:${dpr}`; };
  function pushChanged() { if (!push.timer) push.timer = setTimeout(() => { push.timer = 0; pushOpen(); }, 30); }
  async function pushOpen() {
    const live = document.hidden ? [] : [...push.members].filter(([div]) => div.isConnected).slice(0, 8);
    const c = live.map(([div, m]) => `${div.dataset.node}:${m.size}:${m.st.cid}`).join(','), key = c + '|' + shape();
    if (push.ctrl && key === push.key) return;
    if (push.ctrl) push.ctrl.abort();
    push.ctrl = null; push.key = '';
    if (!live.length || push.failed) return;
    const ctrl = push.ctrl = new AbortController(); push.key = key;
    let got = 0;
    try {
      const still = matchMedia('(prefers-reduced-motion: reduce)').matches ? 1 : 0;
      const res = await fetch(`/push/${live[0][0].dataset.sid}?v=${shape()}&c=${c}&still=${still}`, { signal: ctrl.signal, cache: 'no-store' });
      if (res.status !== 200 || !res.body) { if (res.headers.get('X-Mojoui-Gone') !== '1') push.failed = true; return; }
      const reader = res.body.getReader();
      let buf = new Uint8Array(0);
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        const joined = new Uint8Array(buf.length + value.length); joined.set(buf); joined.set(value, buf.length); buf = joined;
        for (;;) {
          if (buf.length < 4) break;
          const dv = new DataView(buf.buffer, buf.byteOffset), hl = dv.getUint32(0);
          if (buf.length < 8 + hl) break;
          const bl = dv.getUint32(4 + hl);
          if (buf.length < 8 + hl + bl) break;
          const head = JSON.parse(new TextDecoder().decode(buf.subarray(4, 4 + hl))), body = buf.slice(8 + hl, 8 + hl + bl);
          buf = buf.slice(8 + hl + bl); got++;
          const fs = window.mojouiFrameStats = window.mojouiFrameStats || {}, k = fs[head.n] = fs[head.n] || { answers: 0, bytes: 0, pictures: 0, pictureBytes: 0 };
          k.answers++; k.bytes += 8 + hl + bl; if (head.status === 200) { k.pictures++; k.pictureBytes += bl; }  // (for checks: each canvas's share)
          if (head['x-mojoui-pending'] === '1') window.mojouiPending();
          const m = [...push.members].find(([div]) => Number(div.dataset.node) === head.n);
          if (m && head.status === 200) m[1].picture(head, body);
        }
      }
    } catch (e) { if (e.name !== 'AbortError' && !got) push.failed = true; }
    finally {
      if (push.ctrl === ctrl) { push.ctrl = null; push.key = ''; if ([...push.members.keys()].some(d => d.isConnected)) setTimeout(pushOpen, 100); }
    }
  }
  async function flushEvents() {
    if (events.sending) return;
    events.sending = true;
    try {
      while (events.queue.length) {
        const { sid, ...e } = events.queue.shift();
        if (e.number === KEY) early.inflight++;
        try { await htmx.ajax('POST', `/e/${sid}`, { values: { ...e, v: shape() }, swap: 'none', source: document.body }); }
        catch (err) { console.warn('mojoui: event not sent', err); }
        finally { if (e.number === KEY) { early.inflight--; setTimeout(release, 50); } }
        const div = document.querySelector(`[data-kind=canvas][data-node="${e.n}"]`);
        if (div && div.mojoui) { div.mojoui.want = true; div.mojoui.pump(); }
      }
    } finally { events.sending = false; }
  }
  // A key pressed while nothing has the keyboard (the screen was just rebuilt under it) goes to the canvas that had it.
  document.addEventListener('keydown', e => {
    if (e.target !== document.body || early.typing || window.mojouiKeyCanvas === undefined) return;
    const div = document.querySelector(`[data-kind=canvas][data-keys="1"][data-node="${window.mojouiKeyCanvas}"]`);
    if (!div) return;
    if (!div.mojoui) attach(div);  // (a screen still settling: its canvas isn't wired up yet)
    const cv = div.querySelector('canvas');
    e.preventDefault(); e.stopPropagation(); cv.focus({ preventScroll: true }); cv.dispatchEvent(new KeyboardEvent('keydown', e));
  }, true);
  window.mojouiAttach = attach;  // (a drag that outlives its canvas wires up the one that replaced it: MENU_JS's forwarder)
  // A drawn view's words (SET_TIP, in its meta): its tooltip, and its accessible name unless a label names it. After every
  // swap, not only when a frame arrives: words can change while the picture doesn't.
  window.mojouiWords = div => {
    const m = document.getElementById('n' + div.dataset.node + '-meta'), cv = div.querySelector('canvas');
    if (!m) return;
    if ((m.dataset.tip || '') !== (div.dataset.tip || '')) { div.dataset.tip = m.dataset.tip || ''; div.title = div.dataset.tip; }
    if (cv && (cv.getAttribute('aria-label') || '') !== (m.dataset.name || '')) cv.setAttribute('aria-label', m.dataset.name || '');
  };
  function attach(div) {
    if (div.mojoui) return;
    const cv = div.querySelector('canvas'), g = cv.getContext('2d');
    const n = Number(div.dataset.node), sid = div.dataset.sid;
    const st = div.mojoui = { want: true, busy: false, drawn: -1, skin: '', count: 0, times: [], queue: [], sending: false, updating: false,
                              cid: Math.random().toString(36).slice(2, 10), seq: 0, drawnSeq: 0 };
    // A canvas the screen rebuilt (same tag) shows its last picture at once and asks with its digest: an unchanged
    // picture then costs a 204, not the picture again (goal 62 M4: a new card rebuilt the screen over a slow link)
    const kept = div.dataset.tag && shownPics.get(div.dataset.tag);
    if (kept) { cv.width = kept.w; cv.height = kept.h; g.drawImage(kept.bmp, 0, 0); st.pic = kept.pic; st.count = 1; }
    const meta = () => document.getElementById('n' + n + '-meta');
    const playing = () => { const m = meta(); return !!m && m.dataset.frames !== '0'; };
    // One frame request; `seq` orders answers (a playing canvas keeps up to three out, so a slow link's round trips
    // overlap): only an answer newer than the picture shown is drawn. Returns what the loop does next.
    async function one(tick) {
      const m = meta(), version = m ? m.dataset.version : '', skin = skinNow(), seq = ++st.seq;
      const r = div.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
      const w = Math.max(1, Math.round(r.width * dpr)), h = Math.max(1, Math.round(r.height * dpr));
      const still = matchMedia('(prefers-reduced-motion: reduce)').matches ? 1 : 0;
      const params = { w, h, scale: dpr, v: shape(), tick, still, have: st.pic || '', cid: st.cid };
      const res = await getFrame(sid, n, params);
      if (res.status === 204 && res.headers.get('X-Mojoui-Same') === '1') {
        if (seq > st.drawnSeq) { st.drawn = version; st.skin = skin; }
        if (res.headers.get('X-Mojoui-Pending') === '1') update();
        return res.headers.get('X-Mojoui-Again') === '1' ? 'again' : 'ok';
      }
      if (res.status !== 200) {
        if (res.headers.get('X-Mojoui-Pending') === '1') update();
        if (res.headers.get('X-Mojoui-Gone') === '1' || res.status === 404) return 'gone';
        return 'retry';
      }
      const pic = res.headers.get('X-Mojoui-Pic') || '';
      const img = await createImageBitmap(await res.blob());
      if (seq < st.drawnSeq) return 'ok';  // (an older answer overtaken by a newer one)
      st.drawnSeq = seq; st.pic = pic;
      if (cv.width !== img.width || cv.height !== img.height) { cv.width = img.width; cv.height = img.height; }
      if (div.dataset.passthrough === '1') g.clearRect(0, 0, cv.width, cv.height);
      g.drawImage(img, 0, 0);
      if (div.dataset.tag) { shownPics.delete(div.dataset.tag); shownPics.set(div.dataset.tag, { pic, bmp: img, w: img.width, h: img.height });
                             if (shownPics.size > 40) shownPics.delete(shownPics.keys().next().value); }
      st.drawn = version; st.skin = skin; st.count++; st.times.push(performance.now());
      if (st.times.length > 1200) st.times.splice(0, 600);
      div.dataset.frame = `${st.count} ${cv.width}x${cv.height} ${r.width.toFixed(0)}x${r.height.toFixed(0)} ${dpr}`;
      if (res.headers.get('X-Mojoui-Pending') === '1') update();
      window.mojouiWords(div);
      return res.headers.get('X-Mojoui-Again') === '1' ? 'again' : 'ok';
    }
    // Playing: its pictures pushed (the page's one /push stream), or, where that can't open, pulled: requests paced by
    // the display, at most three out at once.
    async function play() {
      if (pushOn() && push.members.size < 8) {  // (more than eight playing canvases: the rest pull)
        const member = { st, size: pushSize(div), got: 0, shown: 0, picture: async (head, body) => {
          const mine = ++member.got;  // (its own order: an older picture decoded after a newer one isn't drawn over it)
          const img = await createImageBitmap(new Blob([body]));
          if (mine < member.shown) return;
          member.shown = mine;
          const m = meta(); st.pic = head['x-mojoui-pic'] || ''; st.drawn = m ? m.dataset.version : st.drawn; st.skin = skinNow();
          if (cv.width !== img.width || cv.height !== img.height) { cv.width = img.width; cv.height = img.height; }
          if (div.dataset.passthrough === '1') g.clearRect(0, 0, cv.width, cv.height);
          g.drawImage(img, 0, 0);
          if (div.dataset.tag) { shownPics.delete(div.dataset.tag); shownPics.set(div.dataset.tag, { pic: st.pic, bmp: img, w: img.width, h: img.height }); }
          st.count++; st.times.push(performance.now()); if (st.times.length > 1200) st.times.splice(0, 600);
          window.mojouiWords(div);
        } };
        push.members.set(div, member); pushChanged();
        while (div.isConnected && playing() && pushOn()) {
          await new Promise(ok => setTimeout(ok, 100));
          const size = pushSize(div);
          if (size !== member.size) { member.size = size; pushChanged(); }
          if (!push.ctrl && !push.timer) pushChanged();
        }
        push.members.delete(div); pushChanged();
        if (pushOn()) return false;
      }
      const out = new Set();
      let gone = false;
      while (div.isConnected && playing() && !gone) {
        while (out.size < 3 && playing() && !gone) {
          const p = one(1).then(r => { if (r === 'gone') gone = true; else if (r === 'retry') return new Promise(ok => setTimeout(ok, 50)); })
                          .catch(() => new Promise(ok => setTimeout(ok, 50))).finally(() => out.delete(p));
          out.add(p);
          await new Promise(ok => requestAnimationFrame(ok));
        }
        if (out.size) await Promise.race(out);
      }
      await Promise.allSettled([...out]);
      return gone;
    }
    async function pump() {
      if (st.busy) return;
      st.busy = true;
      try {
        while (div.isConnected && (st.want || playing())) {
          if (playing()) { st.want = false; if (await play()) return; st.want = true; continue; }
          const tick = playing() ? 1 : 0, m = meta();
          if (tick) await new Promise(ok => requestAnimationFrame(ok));  // at most one frame per display refresh
          const version = m ? m.dataset.version : '', skin = skinNow();
          st.want = false;
          const r = div.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
          const w = Math.max(1, Math.round(r.width * dpr)), h = Math.max(1, Math.round(r.height * dpr));
          const still = matchMedia('(prefers-reduced-motion: reduce)').matches ? 1 : 0;  // (less motion: animations jump to their end)
          const res = await getFrame(sid, n, { w, h, scale: dpr, v: shape(), tick, still, have: st.pic || '', cid: st.cid });
          if (res.status === 204 && res.headers.get('X-Mojoui-Same') === '1') {  // (the picture it shows is still the one: nothing sent)
            st.drawn = version; st.skin = skin;
            if (res.headers.get('X-Mojoui-Pending') === '1') update();
            if ((meta() && meta().dataset.version !== String(st.drawn)) || st.skin !== skinNow()) st.want = true;
            if (res.headers.get('X-Mojoui-Again') === '1') { st.want = true; await new Promise(ok => requestAnimationFrame(ok)); }
            continue;
          }
          if (res.status !== 200) {
            if (res.headers.get('X-Mojoui-Pending') === '1') update();  // e.g. a frame changed the screen's shape
            if (res.headers.get('X-Mojoui-Retry') === '1') await new Promise(ok => setTimeout(ok, 50));
            if (res.headers.get('X-Mojoui-Gone') === '1' || res.status === 404) return;
            if (res.status !== 204) await new Promise(ok => setTimeout(ok, 50));  // (anything else: a short wait, then again)
            continue;
          }
          st.pic = res.headers.get('X-Mojoui-Pic') || '';
          let img;
          try { img = await createImageBitmap(await res.blob()); }
          catch (e) { st.want = true; await new Promise(ok => setTimeout(ok, 250)); continue; }  // (cut mid-picture: again)
          if (div.dataset.tag) { shownPics.delete(div.dataset.tag); shownPics.set(div.dataset.tag, { pic: st.pic, bmp: img, w: img.width, h: img.height });
                                 if (shownPics.size > 40) shownPics.delete(shownPics.keys().next().value); }
          if (cv.width !== img.width || cv.height !== img.height) { cv.width = img.width; cv.height = img.height; }
          if (div.dataset.passthrough === '1') g.clearRect(0, 0, cv.width, cv.height);  // (its alpha: the last frame mustn't show through)
          g.drawImage(img, 0, 0);
          st.drawn = version; st.skin = skin; st.count++; st.times.push(performance.now());
          if (st.times.length > 1200) st.times.splice(0, 600);  // (frame times, for tests; bounded)
          div.dataset.frame = `${st.count} ${cv.width}x${cv.height} ${r.width.toFixed(0)}x${r.height.toFixed(0)} ${dpr}`;
          if (res.headers.get('X-Mojoui-Pending') === '1') update();
          if ((meta() && meta().dataset.version !== String(st.drawn)) || st.skin !== skinNow()) st.want = true;
          window.mojouiWords(div);  // (SET_TIP: a drawn view's words)
          if (res.headers.get('X-Mojoui-Again') === '1') { st.want = true; await new Promise(ok => requestAnimationFrame(ok)); }  // mid-animation (a gliding ring): the next frame
        }
      } finally { st.busy = false; }
    }
    // The rest of the screen (labels the app changed while drawing): fetched alongside the
    // frames, at most ~10 times a second, and always once more after the last change.
    const update = () => window.mojouiPending();  // (the page's one /pending: see EFFECTS_JS)
    st.pump = pump;
    st.sendKey = (k, m) => send(KEY, 0, 0, m, 0, 1, k);
    // pressure: PointerEvent.pressure on PRESS, PAN and RELEASE, from a pen only (0: the device has none; a mouse
    // reports 0.5 while pressed, which isn't a pressure; goal 40)
    function send(kind, x, y, dx, dy, zoom, text = '', pressure = 0) {
      const q = events.queue, last = q[q.length - 1], same = last && last.n === n && last.number === kind;
      if (same && (kind === PAN || kind === WHEEL)) { last.dx += dx; last.dy += dy; last.x = x; last.y = y; last.pressure = pressure; }
      else if (same && kind === ZOOM) { last.zoom *= zoom; }
      else q.push({ n, sid, number: kind, x, y, dx, dy, zoom, text, pressure });
      flushEvents();
    }
    const pointers = new Map();
    let moved = false, spread = 0;
    const at = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
    const distance = () => { const [a, b] = [...pointers.values()]; return Math.hypot(a[0] - b[0], a[1] - b[1]); };
    const keys = div.dataset.keys === '1';  // Canvas(keys=True): a press gives it the keyboard (as on GTK)
    if (keys) {
      cv.tabIndex = 0;
      cv.addEventListener('focus', () => { window.mojouiKeyCanvas = n; });
      cv.addEventListener('keydown', e => {
        if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
        const mods = (e.shiftKey ? 1 : 0) + (e.ctrlKey || e.metaKey ? 2 : 0) + (e.altKey ? 4 : 0);
        const typed = [...e.key].length === 1 && !(mods & 6);
        if ((OWN_KEYS.has(e.key) && !(mods & 6)) || typed || (mods & 2 && ['Home', 'End'].includes(e.key))) e.preventDefault();
        // a key typed on a cell opens an editor a round trip later: keys pressed meanwhile wait for it (not lost,
        // not sent to the grid), then go into the editor in order
        send(KEY, 0, 0, mods, 0, 1, e.key);  // (Ctrl and Alt keys too, as GTK sends them; the page keeps their defaults)
      });
    }
    cv.addEventListener('contextmenu', e => { e.preventDefault(); const [x, y] = at(e); send(SECONDARY, x, y, 0, 0, 1); });
    const mods = e => (e.shiftKey ? 1 : 0) + (e.ctrlKey || e.metaKey ? 2 : 0) + (e.altKey ? 4 : 0);  // SHIFT, CTRL, ALT (mojoui.view)
    const pen = e => e.pointerType === 'pen' ? (e.pressure || 0) : 0;
    cv.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;  // a right click opens a context menu (contextmenu), it doesn't press
      if (keys) cv.focus({ preventScroll: true });
      cv.setPointerCapture(e.pointerId); pointers.set(e.pointerId, at(e));
      if (pointers.size === 1) { moved = false; const [x, y] = at(e); send(PRESS, x, y, mods(e), 0, 1, '', pen(e)); window.mojouiDrag = { n, id: e.pointerId, x, y, moved: false }; }  // where a drag (or tap) starts (dx: Shift, Ctrl, Alt held)
      if (pointers.size === 2) spread = distance();
    });
    cv.addEventListener('pointermove', e => {
      if (!pointers.has(e.pointerId)) return;
      const [x, y] = at(e), [px, py] = pointers.get(e.pointerId);
      pointers.set(e.pointerId, [x, y]);
      if (pointers.size === 1) {
        e.mojouiHandled = true;
        if (Math.abs(x - px) + Math.abs(y - py) > 0) { if (Math.abs(x - px) + Math.abs(y - py) > 3) moved = true; send(PAN, x, y, x - px, y - py, 1, '', pen(e)); }
        const d = window.mojouiDrag; if (d && d.id === e.pointerId) { d.x = x; d.y = y; d.moved = moved; }
      } else if (pointers.size === 2) {
        const d = distance(), [a, b] = [...pointers.values()];
        if (spread > 0 && d > 0) send(ZOOM, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, 0, 0, d / spread);
        spread = d; moved = true;
      }
    });
    const up = e => {
      if (!pointers.has(e.pointerId)) return;
      e.mojouiHandled = true;
      if (window.mojouiDrag && window.mojouiDrag.id === e.pointerId) window.mojouiDrag = null;
      const [x, y] = at(e);
      pointers.delete(e.pointerId);
      // a second click within the double-click time is the DOUBLE that 'dblclick' sends, not another TAP (as on GTK)
      const now = performance.now(), second = st.lastTap && now - st.lastTap.t < 500 && Math.abs(x - st.lastTap.x) + Math.abs(y - st.lastTap.y) < 6;
      if (pointers.size === 0 && !moved && e.type === 'pointerup') { if (second) st.lastTap = null; else { st.lastTap = { t: now, x, y }; send(TAP, x, y, mods(e), 0, 1); } }
      else if (pointers.size === 0 && moved) send(RELEASE, x, y, 0, 0, 1, '', pen(e));  // a drag ended
    };
    cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
    st.drag = (e, what) => {  // the rest of a drag that began on the canvas this one replaced (window.mojouiDrag)
      const d = window.mojouiDrag, [x, y] = at(e);
      if (what === 'move') {
        if (Math.abs(x - d.x) + Math.abs(y - d.y) > 3) d.moved = true;
        if (x !== d.x || y !== d.y) send(PAN, x, y, x - d.x, y - d.y, 1);
        d.x = x; d.y = y;
      } else {
        window.mojouiDrag = null;
        if (d.moved) send(RELEASE, x, y, 0, 0, 1); else if (e.type === 'pointerup') send(TAP, x, y, mods(e), 0, 1);
      }
    };
    cv.addEventListener('dblclick', e => { const [x, y] = at(e); send(DOUBLE, x, y, 0, 0, 1); });
    cv.addEventListener('wheel', e => {
      e.preventDefault();
      const [x, y] = at(e), line = e.deltaMode === 1 ? 40 : 1, dy = e.deltaY * line;
      // Canvas(scroll_pans=True): a plain scroll pans (WHEEL, how far the content moves); ctrl+scroll, and a
      // trackpad pinch (the browser sends it as a wheel with ctrlKey), zoom
      if (div.dataset.scroll === 'pan' && !e.ctrlKey) { send(WHEEL, x, y, -e.deltaX * line, -dy, 1); return; }
      send(ZOOM, x, y, 0, 0, Math.pow(2, -dy / 400));  // 4 notches of 100 = 2×
    }, { passive: false });
    new ResizeObserver(() => { st.want = true; pump(); }).observe(div);
    pump();
  }
  const scan = () => document.querySelectorAll('[data-kind=canvas]').forEach(attach);
  // nothing has the keyboard: the first canvas that takes keys (the grid) gets it, so arrows work at once
  // (a button or file picker left focused by the click that changed the screen doesn't count: only a field that takes typing does)
  const typing = el => el && (el.matches('textarea, select, [contenteditable]') || (el.matches('input') && !el.matches('[type=file], [type=checkbox], [type=radio]')));
  function focusFirst() {
    if (window.mojouiKeyCanvas !== undefined || typing(document.activeElement)) return;
    const first = document.querySelector('[data-kind=canvas][data-keys="1"]');
    if (first) { if (!first.mojoui) attach(first); first.querySelector('canvas').focus({ preventScroll: true }); }
  }
  document.addEventListener('DOMContentLoaded', () => { scan(); focusFirst(); });
  document.addEventListener('htmx:afterSettle', () => {
    scan();
    release();
    focusFirst();
    const kdiv = document.querySelector(`[data-kind=canvas][data-node="${window.mojouiKeyCanvas}"]`);
    // an in-place editor closed: the keyboard goes back to the canvas it came from
    const back = kdiv && kdiv.querySelector('canvas');
    if (back && kdiv.dataset.keys === '1' && (!document.activeElement || document.activeElement === document.body)) back.focus({ preventScroll: true });
    document.querySelectorAll('[data-kind=canvas]').forEach(div => {
      const st = div.mojoui, m = document.getElementById('n' + div.dataset.node + '-meta');
      if (window.mojouiWords) window.mojouiWords(div);
      if (st && m && (m.dataset.version !== String(st.drawn) || m.dataset.frames !== '0' || st.skin !== skinNow())) { st.want = true; st.pump(); }
    });
  });
})();
"""




def png(rgba, w, h):
    """Encodes RGBA bytes as a PNG (no dependencies: zlib + the PNG chunk format)."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


# Secure by default (goal 34 M2, D-593–D-596): every response carries these headers. Scripts come only from our origin,
# by content hash (no inline script, no inline handler, no eval: the page's behaviour is in the hashed host bundle and the
# app's bundles). Styles allow 'unsafe-inline' (docs/js.md): every view's layout is a style attribute (padding, sizes,
# gaps) and the theme's palette and sheet are <style> elements swapped in live; CSS can't run script, and what it could
# load is held to our origin by img-src and font-src. Frames: any http(s) page, always sandboxed (frame_sandbox).
CSP = "; ".join([
    "default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'", "img-src 'self' data:", "font-src 'self'",
    "connect-src 'self'", "frame-src 'self' http: https:", "object-src 'none'", "base-uri 'none'", "form-action 'self'",
    "frame-ancestors 'self'",
])
SECURITY_HEADERS = [(k.lower().encode(), v.encode()) for k, v in (
    ("Content-Security-Policy", CSP), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "same-origin"),
    ("X-Frame-Options", "SAMEORIGIN"), ("Cross-Origin-Opener-Policy", "same-origin"))] + (
    [(b"strict-transport-security", b"max-age=31536000")] if os.environ.get("MOJOUI_PUBLIC") == "1" else [])
IMMUTABLE = "public, max-age=31536000, immutable"  # a file named by its content's hash never changes
FONT_URLS = {}  # font file name → its hashed URL (theme sheets name /static/fonts/<name>; skin() rewrites them)
FONT_REF = re.compile(r"url\(/static/fonts/([A-Za-z0-9_.-]+\.ttf)\)")


class SecurityHeaders:
    """ASGI middleware: SECURITY_HEADERS on every HTTP response (a route's own header of the same name wins)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                have = {k.lower() for k, _ in headers}
                headers += [(k, v) for k, v in SECURITY_HEADERS if k not in have]
                message = dict(message, headers=headers)
            await send(message)

        await self.app(scope, receive, send_with_headers)


class BodyTooLarge(Exception):
    """A request body ran past its route's limit while it was read (BodyLimit)."""


class BodyLimit:
    """ASGI middleware (public mode): a request body over its route's limit is refused (413) before anything reads it:
    FastHTML parses every form before its handler runs, so the upload caps alone came after the bytes were on the box
    (goal 62's review). Uploads may carry their cap (and a little form), every other route 1 MB. An upload must say its
    length, and `gate(path, length)` may refuse it before a byte is read: (words for the page or None, release)."""

    def __init__(self, app, big, gate=None, alive=None):
        self.app, self.big, self.gate, self.alive = app, big, gate, alive

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("method") not in ("POST", "PUT", "PATCH"):
            return await self.app(scope, receive, send)
        path = scope.get("path", "")
        upload = path.startswith(("/upload/", "/dropfile/"))
        limit = self.big if upload else 1 << 20
        length = dict(scope.get("headers", [])).get(b"content-length")
        if length is not None and (not length.isdigit() or int(length) > limit):
            return await _too_large(send)
        release = None
        if upload and self.gate is not None:
            if length is None:  # (a browser's upload says its length; one that doesn't can't reserve it)
                return await _answer(send, 411, b"text/plain", b"an upload says its length")
            refused, release, drain = self.gate(path, int(length))
            if refused:  # (read and dropped first, up to `drain` bytes: a browser shows an answer, not a reset connection)
                await _drain(receive, drain)
                return await _answer(send, 200, b"text/html; charset=utf-8", to_xml(notice(refused)).encode())
        seen, over, started, t0 = [0], [False], [False], time.monotonic()
        sid = (path.split("/") + ["", "", ""])[2]

        async def counted():
            import anyio
            # (round 5: a body arrives at BODY_RATE at least after BODY_GRACE_S, with no gap past BODY_IDLE_S, and an upload
            # stops when its session ends: slow ones held the server's upload budget and its connections)
            try:
                with anyio.fail_after(BODY_IDLE_S):
                    message = await receive()
            except TimeoutError:
                over[0] = True
                raise BodyTooLarge()
            if message["type"] == "http.request":
                seen[0] += len(message.get("body", b""))
                took = time.monotonic() - t0
                if seen[0] > limit or (took > BODY_GRACE_S and seen[0] < BODY_RATE * (took - BODY_GRACE_S)) \
                        or (upload and self.alive is not None and message.get("more_body") and not self.alive(sid)):
                    over[0] = True
                    raise BodyTooLarge()
            return message

        async def watched(message):
            if over[0]:  # (the app answered a body that ran past the limit, with its own 500: the page gets 413, once)
                if message["type"] == "http.response.start" and not started[0]:
                    started[0] = True
                    await _too_large(send)
                return
            if message["type"] == "http.response.start":
                started[0] = True
            await send(message)

        try:
            await self.app(scope, counted, watched)
        except BodyTooLarge:  # (a chunked body that ran past its limit; a handler's own errors go on up)
            if not started[0]:
                started[0] = True
                await _too_large(send)
        finally:
            if release:
                release()


async def _answer(send, status, kind, body):
    """BodyLimit's own answers: outside SecurityHeaders, so they carry its headers themselves (round 4)."""
    await send({"type": "http.response.start", "status": status, "headers": [(b"content-type", kind)] + list(SECURITY_HEADERS)})
    await send({"type": "http.response.body", "body": body})


async def _drain(receive, most, seconds=60):
    """Reads and drops a request's body, up to `most` bytes or `seconds`, so its answer reaches the browser."""
    import anyio
    seen = 0
    with anyio.move_on_after(seconds):
        while seen < most:
            m = await receive()
            if m["type"] != "http.request":
                return
            seen += len(m.get("body", b""))
            if not m.get("more_body"):
                return


class SessionRequests:
    """ASGI middleware (public mode), before anything of a request is read (round 5):
    - a request for a session that doesn't exist (every session route, ROUTES: all but the EXEMPT ones) is answered at once, "gone";
    - a session's requests in flight are at most SESSION_REQUESTS (past them a 204 with X-Mojoui-Retry, which the page
      retries, without a worker thread: round 4, 300 open /frame requests took anyio's 40 threads and /health to 8 s);
    - an address's requests in flight are at most ADDRESS_REQUESTS (429)."""

    EXEMPT = ("static", "assets", "health", "wait", "push", "bye", "download", "img", "favicon.ico", "")  # (no session work, or a few a tab holds)
    # (the routes that name a session, but the exempt ones; any other path, /dev/… on a public copy, gets its own answer)
    ROUTES = ("e", "w", "frame", "pending", "resize", "save", "reply", "appearance", "describe", "dropfile", "jslog", "rows", "spot", "upload")

    def __init__(self, app, alive):
        self.app, self.alive, self.open, self.lock = app, alive, {}, threading.Lock()
        self.said = [0.0]

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        parts = scope.get("path", "").split("/")
        route, sid = parts[1] if len(parts) > 1 else "", parts[2] if len(parts) > 2 else ""
        h = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        addr = address_key(h["x-real-ip"]) if BEHIND_PROXY and "x-real-ip" in h else address_key((scope.get("client") or ("", 0))[0])
        keys = ["a:" + addr]
        if route in self.ROUTES and len(parts) > 2:
            if not self.alive(sid):
                if time.monotonic() - self.said[0] > 10:  # (said at most every 10 s: a flood can't fill the log)
                    self.said[0] = time.monotonic()
                    print(f"REFUSED: requests for sessions that don't exist (/{route}/…)", flush=True)
                return await send_empty(send, 204, [(b"x-mojoui-gone", b"1")] + list(SECURITY_HEADERS))
            keys.append("s:" + sid)
        with self.lock:
            if self.open.get(keys[0], 0) >= ADDRESS_REQUESTS:
                busy = 429
            elif len(keys) > 1 and self.open.get(keys[1], 0) >= SESSION_REQUESTS:
                busy = 204
            else:
                busy = 0
                for k in keys:
                    self.open[k] = self.open.get(k, 0) + 1
        if busy == 429:
            return await send_empty(send, 429, [(b"retry-after", b"5")] + list(SECURITY_HEADERS))
        if busy:
            return await send_empty(send, 204, [(b"x-mojoui-retry", b"1")] + list(SECURITY_HEADERS))
        try:
            await self.app(scope, receive, send)
        finally:
            with self.lock:
                for k in keys:
                    self.open[k] -= 1
                    if self.open[k] <= 0:
                        del self.open[k]


async def send_empty(send, status, headers):
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": b""})


async def _too_large(send):
    await send({"type": "http.response.start", "status": 413, "headers": [(b"content-type", b"text/plain")] + list(SECURITY_HEADERS)})
    await send({"type": "http.response.body", "body": b"too large"})


class Scrub:
    """ASGI middleware (public mode): any server path left in a text answer (an engine's error naming its file, a
    message) is cut to what follows the folder, so no answer carries a server path. Each cut is logged (SCRUB:), so its
    source can be fixed too. Downloads and pictures pass as they are."""

    def __init__(self, app, roots):
        self.app = app
        uploads = re.escape(str(uploads_base().parent))
        alts = [re.escape(r) for r in sorted({str(x).rstrip("/") for x in roots if x and len(str(x)) > 1}, key=len, reverse=True)]
        # (an upload's folder names its session: the session and the file's own folder go too; a root counts only as a
        # whole path segment: the image's /app must not cut "/appearance", goal 62's review)
        end = r"(?=/|[^A-Za-z0-9._~-]|$)"
        self.rx = re.compile(("(?:" + uploads + r")(?:/[a-z]+)?(?:/[0-9a-f]{32})?(?:/[0-9a-f]{12})?" + end + "/?|(?:" + "|".join(alts) + ")" + end + "/?").encode())

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        start, chunks = {}, []

        async def buffered(message):
            if message["type"] == "http.response.start":
                headers = dict((k.lower(), v) for k, v in message.get("headers", []))
                ctype = headers.get(b"content-type", b"")
                if ctype.startswith((b"text/html", b"text/plain", b"application/json")):
                    start["msg"] = message
                    return
                return await send(message)
            if message["type"] == "http.response.body" and "msg" in start:
                chunks.append(message.get("body", b""))
                if message.get("more_body"):
                    return
                body = b"".join(chunks)
                cut = self.rx.sub(b"", body)
                if cut != body:  # (the server's own log: where it was, so its source can be fixed)
                    m = self.rx.search(body)
                    near = body[max(0, m.start() - 60):m.end() + 40].decode(errors="replace").replace("\n", " ")
                    print(f"SCRUB: {scope.get('path', '').split('/')[1][:12]}: cut a server path from the answer: …{near}…", flush=True)
                headers = [(k, v) for k, v in start["msg"].get("headers", []) if k.lower() != b"content-length"]
                accept = dict((k.lower(), v) for k, v in scope.get("headers", [])).get(b"accept-encoding", b"")
                if len(cut) > 1024 and b"gzip" in accept and not any(k.lower() == b"content-encoding" for k, _ in headers):
                    cut = gzip.compress(cut, 5)  # (a screen's HTML is 100+ KB: a slow link's seconds, goal 62 M4)
                    headers += [(b"content-encoding", b"gzip"), (b"vary", b"Accept-Encoding")]
                headers.append((b"content-length", str(len(cut)).encode()))
                await send(dict(start["msg"], headers=headers))
                return await send({"type": "http.response.body", "body": cut})
            await send(message)

        await self.app(scope, receive, buffered)


def content_name(name, data):
    """name.js → name.<sha256[:16]>.js: the file's URL changes whenever its bytes do."""
    stem, ext = name.rsplit(".", 1)
    return f"{stem}.{hashlib.sha256(data).hexdigest()[:16]}.{ext}"


def host_files():
    """The host's own files, by content hash: {name: (hashed name, bytes, media type)}. mojoui.js is every adapter
    (canvas, board, menus, effects, the page's listeners, widgets) in one script."""
    js = "\n".join([CANVAS_JS, BOARD_JS, MENU_JS, EFFECTS_JS, PAGE_JS, (STATIC / "mojoui-widgets.js").read_text()]).encode()
    out = {}
    for name, data, media in (("htmx.min.js", (STATIC / "htmx.min.js").read_bytes(), "text/javascript"),
                              ("mojoui.js", js, "text/javascript"), ("mojoui.css", CSS.encode(), "text/css")):
        out[name] = (content_name(name, data), data, media)
    return out


def debug_build(module_dir):
    """Whether the app's build is a debug build (MOJOUI_DEBUG=1 scripts/build.sh <app> web): its manifest lists bundles
    and names each one's source map, there beside it. A release build has no maps (scripts/web_assets.py)."""
    folder = Path(module_dir) / "assets"
    try:
        manifest = json.loads((folder / "manifest.json").read_text())
    except (OSError, ValueError):
        return False
    return isinstance(manifest, dict) and bool(manifest) and all(
        isinstance(m, dict) and m.get("map") and (folder / m["map"]).is_file() for m in manifest.values())


def app_assets(module_dir, mod):
    """The app's bundles (App.web_assets(), built by scripts/web_assets.py): ({hashed file: (bytes, media type)}, the
    page's tags for them). A listed name the build didn't make, or a file whose bytes don't match its hash, stops the
    server: nothing unlisted or unbundled is served."""
    names = json.loads(mod.web_assets()) if hasattr(mod, "web_assets") else []
    folder = Path(module_dir) / "assets"
    manifest = json.loads((folder / "manifest.json").read_text()) if (folder / "manifest.json").exists() else {}
    files, tags = {}, []
    for name in names:
        m = manifest.get(name)
        if m is None:
            raise SystemExit(f"mojoui web: the app lists {name} in web_assets(), but its build has none (scripts/build.sh <app> web)")
        data = (folder / m["file"]).read_bytes()
        if content_name(name, data) != m["file"]:
            raise SystemExit(f"mojoui web: assets/{m['file']} doesn't match its hash (rebuild it)")
        js = name.endswith(".js")
        files[m["file"]] = (data, "text/javascript" if js else "text/css")
        if DEV and m.get("map") and (folder / m["map"]).exists():  # (a debug build's source map: served only by the dev server)
            files[m["map"]] = ((folder / m["map"]).read_bytes(), "application/json")
        tags.append(Script(src=f"/assets/{m['file']}", defer=True, integrity=m["integrity"]) if js else
                    Link(rel="stylesheet", href=f"/assets/{m['file']}", integrity=m["integrity"]))
    return files, tags


ENGINE_LOCK = threading.Lock()  # apps with shared data: one call into Mojo at a time (shared GPU scratch)
SESSIONS_MADE = [0]


class Session:
    """One browser tab: its Mojo app, the screen last sent, and a lock so its events run one at a time."""

    def __init__(self, mod, shared=False):
        self.mod = mod
        with ENGINE_LOCK:  # (a new session computes on the shared GPU data)
            self.handle = mod.new_session()
            self.nodes = json.loads(mod.view(self.handle))
        SESSIONS_MADE[0] += 1
        if shared:
            print(f"SHARED: {mod.init_shared()} load, {SESSIONS_MADE[0]} sessions", flush=True)
        self.shape = 0  # bumps on every rebuild; node numbers only mean something within one shape
        self.images = {}  # node → version, for cache-busting image URLs
        self.focus = None  # field to focus after the next rebuild
        self.lock = ENGINE_LOCK if shared else threading.Lock()
        self.closed = False  # set (under lock) when the tab is evicted; its Mojo handle is gone
        self.list_top = {}  # LazyList node → last scroll position, to re-send its visible rows
        self.pending = None  # screen changes made while drawing canvases, not yet sent (a diff)
        self.frame_time = {}  # canvas node → time of its last frame event
        self.busy = False  # the app has HTTP requests out or timers running (Runtime.wake_in ≥ 0): the page waits on /wait
        self.busy_sent = False  # what the page was last told (#mojoui-busy)
        self.waiters = set()  # (event loop, asyncio.Event) of the page's open /wait
        self.waiters_lock = threading.Lock()
        self.commands = []  # widget commands the app asked for (mojoui.webcomponent), not yet sent to the page
        self.origin = ""  # this page's origin (WebFrame: allow-same-origin only for another one)
        self.widget_facts = {}  # (tag, id) → what the widget says about itself (mojoui-widgets.js facts), while an agent is attached
        self.last_active = time.monotonic()  # the visitor's last input (IDLE_S ends the tab after that long)
        self.made = time.monotonic()
        self.touched = False  # the page came back for anything (/wait, a frame, an event): a page, not a bare GET
        self.client = ""  # who made it: its address (public mode's places per address near the cap)
        self.upload_bytes = 0  # the bytes of this tab's uploads kept (a running total, round 5)
        self.tables_kb = {}  # public mode: path → a checked table's memory once read (the visitor's tables together)
        self.gone_reason = ""  # why the server ended it (the page says so)
        self.deliveries = []  # (url, name) of files the app handed over (App.take_download), for the next answer

    def wake(self):
        """Tell the page's open /wait that changes are pending."""
        with self.waiters_lock:
            for loop, ev in list(self.waiters):
                loop.call_soon_threadsafe(ev.set)


ALIGN_CSS = {1: "flex-start", 2: "center", 3: "flex-end", 4: "stretch", 6: "baseline"}  # START, CENTER, END, STRETCH, BASELINE
JUSTIFY_CSS = {1: "flex-start", 2: "center", 3: "flex-end", 5: "space-between"}  # START, CENTER, END, BETWEEN
SIZED_CONTROLS = (FIELD, TEXTAREA, SLIDER, PROGRESS, DROPDOWN, DATE, LAZYLIST, DIVIDER, SCROLL)


def place_mark(s, i):
    """The hidden marker inside node i's object (or Board) that carries where the shown view puts it;
    BOARD_JS applies it, so a move never re-renders the object (that would restart its canvases)."""
    n = s.nodes[i]
    if n["kind"] == BOARD:
        return I(hidden=True, id=f"n{i}-place", data_kind="place", data_w=str(n["spacing"]), data_h=str(n["size"]),
                 data_reveal=str(n["value"]))
    return I(hidden=True, id=f"n{i}-place", data_kind="place", data_x=str(n["x"]), data_y=str(n["y"]), data_tone=str(object_tone(s, i)))


def object_tone(s, i):
    """Board object i's tone (Board(tones=…): its Board's options, by its place among the children), 0 when none."""
    p = parent_of(s, i)
    if p < 0 or s.nodes[p]["kind"] != BOARD:
        return 0
    opts = s.nodes[p]["options"]
    k = s.nodes[p]["children"].index(i)
    try:
        return int(opts[k]) if k < len(opts) else 0
    except ValueError:
        return 0


def parent_of(s, i):
    parent_kind(s, i)  # (fills the cache)
    parents = s._parents[1]
    return parents[i] if 0 <= i < len(parents) else -1


def parent_kind(s, i):
    """The kind of node i's parent (-1 for the root), from a map kept per screen."""
    cached = getattr(s, "_parents", None)
    if cached is None or cached[0] is not s.nodes:
        parents = [-1] * len(s.nodes)
        for k, node in enumerate(s.nodes):
            for c in node["children"]:
                parents[c] = k
        cached = (s.nodes, parents)
        s._parents = cached
    p = cached[1][i] if 0 <= i < len(cached[1]) else -1
    return s.nodes[p]["kind"] if p >= 0 else -1


def render(s, i, sid):
    """One mojoui node → FastHTML components, plus its layout settings as CSS flexbox
    (a direct mapping: the browser's own layout does the work)."""
    el = render_node(s, i, sid)
    n = s.nodes[i]
    if n["kind"] == DIALOG:  # (its width is its panel's: the layer itself covers the window)
        return el
    css = []
    if n["pad_v"] or n["pad_h"]:
        css.append(f"padding:{n['pad_v']}px {n['pad_h']}px")
    if n["w"]:
        css.append(f"width:{n['w']}px;flex-shrink:0")  # (a role that shrinks says so in the theme's sheet, over this)
    if n["h"]:
        css.append(f"height:{n['h']}px")
    if n["min_w"]:
        css.append(f"min-width:{n['min_w']}px")
    if n["max_w"]:
        css.append(f"max-width:{n['max_w']}px")
    if n["grows"] and not (n["w"] and parent_kind(s, i) == HSTACK) and not (n["h"] and parent_kind(s, i) == VSTACK):
        # (a view with a fixed size along its stack never takes spare room there, as on GTK)
        css.append("flex:1 1 0;min-width:0" + (";min-height:0" if n["kind"] == SCROLL else ""))  # grow from zero, so a growing field never pushes its row onto two lines (and a growing scroll scrolls rather than push the page)
    if n["fills"]:
        css.append("align-self:stretch")
        if n["max_w"]:
            css.append("width:100%;margin-inline:auto")  # min(max, available), centred, as GTK's clamp does
    if n["kind"] == SCROLL and n["size"] == 0 and parent_kind(s, i) == HSTACK:
        css.append("contain:size")  # (as tall as its row is given, never as its content: a document's cells beside its aside; GTK's scroller asks for no height either)
    if n["kind"] == BUTTON:  # (on a button, START puts its icon and title at the leading edge: a sidebar row)
        if n["align_items"] == 1:
            css.append("justify-content:flex-start;text-align:left")
    elif n["align_items"] in ALIGN_CSS:
        css.append(f"align-items:{ALIGN_CSS[n['align_items']]}")
    if n["justify_items"] in JUSTIFY_CSS:
        css.append(f"justify-content:{JUSTIFY_CSS[n['justify_items']]}")
    if n["kind"] in SIZED_CONTROLS and (n["w"] or n["grows"] or n["fills"]):
        css.append("--control-width:100%;--control-max:100%")  # the control inside takes the size it was given (no viewport cap: goal 35)
    if css:
        old = el.attrs.get("style", "")
        el.attrs["style"] = (old + ";" if old else "") + ";".join(css)
    if n["name"]:
        el.attrs["data-tag"] = n["name"]
    if n.get("arrive"):  # (.arrive(): a spring the first time it's inserted; mojoui.css .mojoui-arrive)
        el.attrs["class"] = (el.attrs.get("class", "") + " mojoui-arrive").strip()
    if n.get("tip"):
        el.attrs["title"] = n["tip"]
        el.attrs["data-tip"] = n["tip"]
    if n["kind"] == CANVAS:  # a drawn view is a picture to a screen reader; its words (label or tooltip) are its name
        name_control(el, n.get("a11y_name", ""), role="img")
    elif n.get("a11y_name"):
        if n["kind"] in NAMED_AS_A_WHOLE:
            el.attrs["aria-label"] = n["a11y_name"]
            if n["kind"] == WEBCOMP and not el.attrs.get("role"):
                el.attrs["role"] = "group"  # (a plain div's aria-label is ignored: a named group holds the JS widget)
        else:
            name_control(el, n["a11y_name"])
    return el


NAMEABLE = ("button", "select", "input", "textarea", "canvas", "img", "iframe")
NAMED_AS_A_WHOLE = (SEGMENTED, RADIO, TABS, PROGRESS, WEBCOMP)  # (the group or the element is the control, not its first option)


def name_control(el, name, role=None):
    """The accessible name (mojoui.a11y.explicit_name) on the control itself, not the box around it (a field's form, a
    toggle's label): aria-label on the first <button>/<select>/<input>/<textarea>/<canvas>/<img>/<iframe> in `el`."""
    todo = [el]
    while todo:
        e = todo.pop(0)
        if getattr(e, "tag", None) in NAMEABLE:
            if name:
                e.attrs["aria-label"] = name
            if role:
                e.attrs["role"] = role
            return
        todo.extend(c for c in getattr(e, "children", ()) if hasattr(c, "tag"))


def web_url(url):
    """`url` when it's http:// or https:// (in any case) with a host and no space or control character, else None: the only
    links and pages the page follows or frames (D-576; mojoui.embed.is_web_url, the same rule for GTK and the Mac)."""
    low = url.lower()
    at = 7 if low.startswith("http://") else 8 if low.startswith("https://") else 0
    if not at or len(url) <= at or url[at] in "/?#" or any(ord(c) <= 32 or ord(c) == 127 for c in url):
        return None
    return url


WIDGET_TAG = re.compile(r"^[a-z][a-z0-9._]*-[a-z0-9._-]*$")
RESERVED_TAGS = {"annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri", "font-face-format", "font-face-name", "missing-glyph"}
EVENT_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_.:-]{0,63}$")
MAX_WIDGET_BYTES = 8 << 20  # an event's payload or a command's reply, as JSON text


def widget_tag(tag):
    """A custom element's name the page may create (mojoui.webcomponent.is_widget_tag: the same rule)."""
    return bool(WIDGET_TAG.fullmatch(tag)) and len(tag) <= 64 and tag not in RESERVED_TAGS  # (fullmatch: "$" lets a trailing \n by, D-618)


def event_name(name):
    """A widget's event or command name (mojoui.webcomponent.is_event_name: the same rule)."""
    return bool(EVENT_NAME.fullmatch(name))


FRAME_SANDBOX = "allow-scripts allow-forms"  # every WebFrame's sandbox: its page runs, in an origin of its own (D-596)
FRAME_EXTRA = ("allow-popups", "allow-modals", "allow-downloads", "allow-same-origin")


FRAME_ALLOW = ("clipboard-read", "clipboard-write", "fullscreen")  # what a WebFrame may ask for (options[1]); none by default
# Names of the machine the host runs on. localhost and 127.0.0.1 reach the same server only because the host binds
# 127.0.0.1 (main(): uvicorn.run(host="127.0.0.1")); IPv6 literals ([::1]) are never plain (origin_parts), so not listed.
LOOPBACK = {"localhost", "127.0.0.1", "0.0.0.0"}
PLAIN_URL = re.compile(r"(?i)(https?)://([^/?#]*)")
DOTTED_IPV4 = re.compile(r"(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}")
DNS_LABEL = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")


def origin_parts(url):
    """(scheme, host, port) of a URL whose authority is plain, else None. Python's urlsplit and the browser's URL parser
    disagree on unusual URLs (a backslash, "%" escapes, user info, IPv4 written as 127.1, 2130706433 or 0x7f.0.0.1, IPv6
    literals), so this doesn't try to out-parse the browser: only a plain authority counts (D-624): no backslash anywhere,
    no "@" or "%" in it, a host that is a dotted IPv4 address written the one plain way or a DNS name (labels of a-z, 0-9
    and inner hyphens, the last starting with a letter; upper case is lowered, one trailing dot dropped), and a port of digits."""
    if "\\" in url or any(ord(c) <= 32 or ord(c) == 127 for c in url):
        return None
    m = PLAIN_URL.match(url)
    if not m:
        return None
    scheme, authority = m.group(1).lower(), m.group(2)
    if "@" in authority or "%" in authority or "[" in authority or "]" in authority:
        return None
    host, _, port = authority.partition(":")
    if ":" in port or (port and not (port.isascii() and port.isdigit() and len(port) <= 5 and int(port) <= 65535)):
        return None
    host = host.lower()
    host = host[:-1] if host.endswith(".") else host
    if not DOTTED_IPV4.fullmatch(host):
        labels = host.split(".")
        if not host or not all(DNS_LABEL.fullmatch(l) for l in labels) or not labels[-1][0].isalpha():
            return None  # (the last label starts with a letter, as every TLD does: the browser reads 0x1, 1e3 or 7 there as a number, D-627)
    return scheme, host, int(port) if port else (443 if scheme == "https" else 80)


def same_origin_or_unsure(url, origin):
    """Whether `url` may be on this page's own origin: the same scheme, host and port, or two names of this machine on
    the same port (localhost and 127.0.0.1: the browser would call them two origins, but they reach the same server), or
    either side unknown (no origin known, or a URL whose authority isn't plain, origin_parts): unsure counts as ours."""
    a, b = origin_parts(url), origin_parts(origin) if origin else None
    if a is None or b is None:
        return True
    return a == b or (a[0] == b[0] and a[2] == b[2] and a[1] in LOOPBACK and b[1] in LOOPBACK)


def page_origin(scheme, netloc, headers):
    """This page's origin as its browser sees it, from the request; "" (unknown) when a proxy may have rewritten the host
    or scheme (X-Forwarded-*, Forwarded): then WebFrame never gets allow-same-origin (D-616)."""
    if any(h in headers for h in ("forwarded", "x-forwarded-host", "x-forwarded-proto", "x-forwarded-port", "x-original-host")):
        return ""
    return f"{scheme}://{netloc}"


def frame_sandbox(n, origin=""):
    """WebFrame's iframe sandbox: FRAME_SANDBOX plus what the app asked for from FRAME_EXTRA (options[0]). allow-same-origin
    only for a page surely on another origin than this one (it then keeps its own cookies; with ours it could lift its
    sandbox): compared as origins (origin_parts), never as strings, and refused when unsure (D-616). A URL check can't see
    where the framed page goes next: a page on another origin that redirects back to ours runs there with
    allow-same-origin (docs/js.md §5)."""
    asked = n["options"][0].split() if n.get("options") else []
    same = same_origin_or_unsure(n["text"], origin)
    extra = [t for t in FRAME_EXTRA if t in asked and not (t == "allow-same-origin" and same)]
    return " ".join([FRAME_SANDBOX] + extra)


def frame_allow(n):
    """The iframe's permissions policy: only what the app asked for (options[1]) from FRAME_ALLOW; none by default (D-617)."""
    asked = n["options"][1].split() if len(n.get("options") or []) > 1 else []
    return "; ".join(t for t in FRAME_ALLOW if t in asked)


def paragraph_runs(n, i, common):
    """A Paragraph's runs as inline elements (FastHTML escapes their words), one element per run whose classes say bold,
    italic, code and whose data-role is its role (the look's rule for it beats the base classes); a link is an <a>: its
    tap posts the run's index when the app listens (htmx cancels the anchor's own navigation), else the browser opens it
    in a new tab."""
    out, opts = [], n["options"]
    for k in range(len(opts) // 4):
        flags, role, href, text = opts[4 * k:4 * k + 4]
        cls = " ".join(["run"] + [c for f, c in (("b", "strong"), ("i", "em"), ("c", "code"), ("l", "link")) if f in flags])
        attrs = dict(cls=cls, data_role=role or None, data_kind="run")
        if "l" in flags:  # (the anchor around the run, as <a><code>…</code></a>: its underline drawn in the paragraph's type, the run's own inside)
            listen = dict(common, hx_vals=json.dumps({"n": i, "number": k})) if n["msg"] else dict(target="_blank", rel="noopener noreferrer")
            inner = Span(text, cls=cls.replace(" link", ""), data_role=role or None)
            if web_url(href) is None:  # (not http(s): no href, so the browser never follows it; a tap still reaches the app)
                listen.pop("target", None), listen.pop("rel", None)
                out.append(A(inner, cls="run link", data_kind="run", data_refused="1", **listen))
            else:
                out.append(A(inner, href=href, cls="run link", data_kind="run", **listen))
        else:
            out.append(Span(text, **attrs))
    return out


def render_node(s, i, sid):
    """One mojoui node → FastHTML components. Ids are n<i> so patches can find them;
    data-kind marks controls for tests and for anyone reading the HTML."""
    n = s.nodes[i]
    nid, kind, post = f"n{i}", n["kind"], f"/e/{sid}"
    vals = json.dumps({"n": i})
    common = dict(hx_post=post, hx_vals=vals, hx_swap="none", hx_include="#mojoui-v")
    if kind == TEXT:
        cls = {TITLE: "text title", HEADLINE: "text headline", CAPTION: "text caption"}.get(n["style"], "text")
        cls += {1: " tone-warn", 2: " tone-good", 3: " tone-strong", 4: " tone-accent"}.get(n["value"], "")
        tag = H1 if n["style"] == TITLE else (H3 if n["style"] == HEADLINE else P)
        return tag(n["text"], cls=cls, id=nid, data_kind="label")
    if kind == PARAGRAPH:  # inline runs in one block, wrapped by the browser; each run's element wears its role (data-role)
        runs = paragraph_runs(n, i, common)
        if n["value"] == 1 and len(runs) > 1:  # a lead: the first run a column of its own, the rest wrapping beside it
            inner = to_xml(runs[0], indent=False) + to_xml(Span(NotStr("".join(to_xml(el, indent=False) for el in runs[1:])), cls="rest"), indent=False)
            return P(NotStr(inner), cls="text paragraph lead", id=nid, data_kind="paragraph")
        inner = "".join(to_xml(el, indent=False) for el in runs)  # (no whitespace between or around the runs: it would be words)
        return P(NotStr(inner), cls="text paragraph", id=nid, data_kind="paragraph")
    if kind == BUTTON:
        cls = {PROMINENT: "prominent", DESTRUCTIVE: "destructive", SUBTLE: "subtle", ICON_ONLY: "subtle icon-only",
               ICON_ON: "subtle icon-only on", TOOL: "subtle tool", TOOL_ON: "subtle tool on",
               TOOL_INLINE: "subtle tool inline", TOOL_INLINE_ON: "subtle tool inline on", TOKEN: "token", TOKEN_LIT: "token lit"}.get(n["style"], "")
        if n["msg2"] and len(n["options"]) >= 3 and n["options"][1] == "save":  # a FileSaver: the app writes the file where the server
            # says, then the page downloads it (/save, DOWNLOAD_JS)
            svg = NotStr(ICONS.get(n["hint"], "").replace('width="24"', 'width="18"').replace('height="24"', 'height="18"')) if n["hint"] else ""
            title = Span(n["text"], cls="sr-only") if n["style"] in (ICON_ONLY, ICON_ON) and svg else Span(n["text"])
            return Button(*([svg, title] if svg else [title]), id=nid, cls=f"button saver {cls}" + (" with-icon" if svg else ""), data_kind="button",
                          hx_post=f"/save/{sid}", hx_vals=json.dumps({"n": i}), hx_include="#mojoui-v", hx_swap="none")
        if n["msg2"]:  # a FilePicker: a file input styled as the button; the file uploads, then on_pick gets its path
            svg = NotStr(ICONS.get(n["hint"], "").replace('width="24"', 'width="18"').replace('height="24"', 'height="18"')) if n["hint"] else ""
            accept = n["options"][0] if n["options"] else ""
            picker = Input(type="file", name="file", accept=accept or None, cls="picker-input", data_kind="picker", data_title=n["text"],
                           hx_post=f"/upload/{sid}", hx_encoding="multipart/form-data", hx_trigger="change", hx_swap="none",
                           hx_vals=json.dumps({"n": i}), hx_include="#mojoui-v")
            title = Span(n["text"], cls="sr-only") if n["style"] in (ICON_ONLY, ICON_ON) and svg else Span(n["text"])  # (icon-only: the title is for screen readers)
            kids = [svg, title, picker] if svg else [Span(n["text"]), picker]
            return Label(*kids, id=nid, cls=f"button picker {cls}" + (" with-icon" if svg and n["style"] not in (TOOL, TOOL_ON, TOOL_INLINE, TOOL_INLINE_ON) else ""), data_kind="button", tabindex="0")
        if n["style"] in (TOOL, TOOL_ON, TOOL_INLINE, TOOL_INLINE_ON):  # the icon above (or beside) a small title
            svg = NotStr(ICONS.get(n["hint"], "").replace('width="24"', 'width="18"').replace('height="24"', 'height="18"'))
            return Button(svg, Span(n["text"]), id=nid, cls=cls, data_kind="button", **common)
        if not n["hint"]:
            return Button(n["text"], id=nid, cls=cls, data_kind="button", **common)
        svg = NotStr(ICONS.get(n["hint"], "").replace('width="24"', 'width="18"').replace('height="24"', 'height="18"'))
        if n["style"] in (ICON_ONLY, ICON_ON):  # the title stays in the text (screen readers, tests), only the icon shows
            return Button(svg, Span(n["text"], cls="sr-only"), id=nid, cls=cls, title=n["text"], data_kind="button", **common)
        return Button(svg, Span(n["text"]), id=nid, cls=cls + " with-icon", data_kind="button", **common)
    if kind == FIELD:
        # The form makes Return submit (on_submit); typing posts on_change. Both go through
        # the form's queue, so a fast Return can't overtake the typing it follows.
        # hx-vals is inherited from ancestors, so the input says second=0 explicitly
        # (otherwise it would pick up the form's second=1 and every keystroke would "submit").
        editor = n["value"] in (1, 3)  # an in-place editor: .focused() (1) takes the keyboard, its text selected; .echo() (3) doesn't
        # (no inline handlers, D-593: PAGE_JS selects the text or puts the caret at the end on focus (data-focus), and posts
        # Escape as on_cancel (data-cancel), from document.body: the input's own hx-vals would win)
        secret = n["style"] == 1  # .secret() (FIELD_SECRET): masked as typed, never offered for saving
        field = Input(type="password" if secret else "text", name="text", value=n["text"], placeholder=n["hint"], data_kind="field",
                      cls="cell-editor" if editor else None, data_focus=("end" if n["value"] == 3 else "select") if editor else None,
                      data_cancel=post if n["size"] else None, data_node=str(i) if n["size"] else None,
                      autocomplete="off", autofocus=(s.focus == i or n["value"] == 1), hx_trigger="input",
                      hx_sync="closest form:queue all", **dict(common, hx_vals=json.dumps({"n": i, "second": 0})))
        return Form(field, cls="field", id=nid, hx_post=post, hx_vals=json.dumps({"n": i, "second": 1}),
                    hx_swap="none", hx_include="#mojoui-v", hx_sync="this:queue all")
    if kind == TOGGLE:
        box = Input(type="checkbox", name="on", checked=bool(n["value"]), hx_trigger="change", **common)
        if n["style"] == 1:  # a Checkbox: a box with a tick (reported as CHECK:)
            return Label(box, Span(n["text"]), cls="toggle check", id=nid, data_kind="toggle", data_check="1")
        return Label(box, Span(n["text"]), cls="toggle", id=nid, data_kind="toggle")
    if kind == DROPDOWN:
        opts = [Option(o, value=str(j), selected=(j == n["value"])) for j, o in enumerate(n["options"])]
        return Select(*opts, name="number", id=nid, data_kind="dropdown", hx_trigger="change", **common)
    if kind == SLIDER:
        return Input(type="range", min="0", max="100", value=str(n["value"]), name="number", id=nid,
                     data_kind="slider", hx_trigger="input changed delay:60ms", **common)
    if kind == PROGRESS:
        return Progress(value=str(n["value"]), max="100", id=nid, data_kind="progress")
    if kind == IMAGE:
        return Img(src=f"/img/{sid}/{i}?v={s.shape}.{s.images.get(i, 0)}", width=str(n["spacing"]),
                   height=str(n["size"]), id=nid, cls="image", data_kind="image", alt="")
    if kind in (SEGMENTED, TABS, RADIO):
        group = f"g{s.shape}-{i}"
        # Each group needs its own name (browsers link all same-named radios on a page);
        # the chosen index travels in hx-vals instead.
        items = [Label(Input(type="radio", name=group, value=str(j), checked=(j == n["value"]), hx_trigger="change",
                             **dict(common, hx_vals=json.dumps({"n": i, "number": j}))), Span(o))
                 for j, o in enumerate(n["options"])]
        cls, kind_name = {SEGMENTED: ("segmented", "segmented"), TABS: ("tabs", "tabs"), RADIO: ("radio", "radio")}[kind]
        return Div(*items, cls=cls, id=nid, role="radiogroup", data_kind=kind_name, data_group=group)
    if kind == TEXTAREA:
        return Textarea(n["text"], name="text", placeholder=n["hint"], id=nid, data_kind="textarea",
                        rows=str(max(n["size"] // 24, 2)), autofocus=(s.focus == i), hx_trigger="input",
                        hx_sync="this:queue all", **common)
    if kind == ALERT:
        return Div(id=nid, hidden=True)  # drawn in the overlay beside the page (render_alert)
    if kind == NAVBAR:
        back = (Button("‹ Back", data_kind="navback", **common),) if n["msg"] else ()
        return Header(*back, H2(n["text"]), cls="nav", id=nid, data_kind="nav", data_back="1" if n["msg"] else "0")
    if kind == DATE:
        return Input(type="date", name="text", value=n["text"], id=nid, data_kind="date", hx_trigger="change", **common)
    if kind == ICON:
        size = n["size"] or 24
        svg = ICONS.get(n["text"], "").replace('width="24"', f'width="{size}"').replace('height="24"', f'height="{size}"')
        return Span(NotStr(svg), cls="icon", id=nid, data_kind="icon", data_icon=n["text"], aria_hidden="true")
    if kind == GRID:
        kids = [render(s, c, sid) for c in n["children"]]
        if n["hint"] == "E":  # (the last column's items at its trailing edge: values and figures read from the right)
            for k, el in enumerate(kids):
                if k % max(n["value"], 1) == max(n["value"], 1) - 1:
                    el.attrs["style"] = (el.attrs.get("style", "") + ";" if el.attrs.get("style") else "") + "justify-self:end;text-align:right"
        if n["options"]:  # (each column its share of the width: 52fr 48fr)
            cols = " ".join(f"minmax(0, {int(x)}fr)" for x in n["options"])
            return Div(*kids, cls="grid", id=nid, data_kind="grid", data_columns=str(n["value"]),
                       style=f"grid-template-columns:{cols};gap:{n['spacing']}px;justify-items:stretch;align-items:stretch")  # (as a table's cells: each fills its cell, a row as high as its tallest)
        if n["style"] == 1:  # (fitted: the first columns as wide as their widest item, the last the rest; items from their start)
            cols = (f"repeat({n['value'] - 1}, max-content) " if n["value"] > 1 else "") + "minmax(0, 1fr)"
            return Div(*kids, cls="grid", id=nid, data_kind="grid", data_columns=str(n["value"]),
                       style=f"grid-template-columns:{cols};gap:{n['spacing']}px;justify-items:start;align-items:center")
        return Div(*kids, cls="grid", id=nid, data_kind="grid", data_columns=str(n["value"]),
                   style=f"grid-template-columns:repeat({n['value']}, minmax(0, 1fr));gap:{n['spacing']}px")  # (equal columns, as GTK's homogeneous grid)
    if kind == LAZYLIST:
        row_h = n["spacing"] or 48
        # Scroll events ask for the rows around the new position: throttled while scrolling, plus a
        # trailing request when it stops (so a fast drag ends on the right rows); newest reply wins.
        return Div(rows_div(s, i, sid, s.list_top.get(i, 0)),
                   cls="lazylist", id=nid, data_kind="list", data_row_height=str(row_h), style=f"height:{n['size']}px",
                   hx_post=f"/rows/{sid}/{i}", hx_trigger="scroll throttle:60ms, scroll delay:150ms",
                   hx_target=f"#rows{i}", hx_swap="outerHTML", hx_sync="this:replace",
                   hx_include="#mojoui-v")  # (its scroll position goes with each request: PAGE_JS, htmx:configRequest)
    if kind == BOARD:
        kids = []
        for k, c in enumerate(n["children"]):
            ch = s.nodes[c]
            kids.append(Div(render(s, c, sid), place_mark(s, c), cls="object", data_kind="object", data_index=str(k), data_tag=ch["name"],
                            data_x=str(ch["x"]), data_y=str(ch["y"]), data_w=str(ch["w"]), data_h=str(ch["h"]), data_tone=str(object_tone(s, c)),
                            style=f"left:{ch['x']}px;top:{ch['y']}px;width:{ch['w']}px;height:{ch['h']}px"))
        board = Div(*kids, place_mark(s, i), cls="board", id=f"{nid}-board", data_kind="board", data_node=str(i), data_sid=sid, data_hold="1" if n["hint"] else None,
                    style=f"width:{n['spacing']}px;height:{n['size']}px")
        return Div(board, cls="board-scroll", id=nid)  # the page scrolls when it's bigger than its room
    if kind == DIALOG:  # modal over a scrim; ✕ and Escape are on_close (its content's own buttons close it otherwise)
        close = Button("✕", type="button", cls="dialog-close", title="Close", aria_label="Close", **dict(common, hx_vals=json.dumps({"n": i, "second": 1})))
        head = Div(H3(n["text"], id=f"{nid}-t"), close, cls="dialog-head")
        body = Div(*[render(s, c, sid) for c in n["children"]], cls="dialog-body")
        panel = Div(head, body, cls="dialog", role="dialog", aria_modal="true", aria_labelledby=f"{nid}-t", style=f"width:{n['w'] or 560}px")
        return Div(Div(cls="scrim"), panel, cls="dialog-layer", id=nid, data_kind="dialog", data_title=n["text"], data_node=str(i), data_sid=sid, data_v=str(s.shape))
    if kind == TABLE:  # a real <table> (the browser sizes its columns); cells wear the roles table-head / table-cell (+ table-num, table-selected)
        cols, kids, align, sel = max(n["value"], 1), n["children"], n["hint"], n["text"]
        dense, compact, limits = n["style"] in (1, 2), n["style"] == 2, n["options"]

        def cell(make, c, k, role):
            num = k < len(align) and align[k] == "R"
            lim = limits[k] if k < len(limits) else ""
            snug = lim.endswith("S") and make is Td
            lim = lim.rstrip("S") if not lim.startswith("T") else lim
            role = role + (" table-dense-snug" if snug else "") + (" table-dense-compact-snug" if snug and compact else "")
            cls = " ".join(x for x in ("num" if num else "", "wrap" if lim == "W" else "") if x) or None
            tick_w = lim[1:] if lim.startswith("T") and lim[1:].isdigit() else "1"
            style = f"max-width:{lim}px" if lim.isdigit() and make is Td else (f"width:{tick_w}px" if lim.startswith("T") and make is Th else None)
            # (a dense table's cells stay on one line, cut at their widest; the tick column as narrow as its box: no share of the room)
            return make(render(s, c, sid), data_role=role + (" table-num" if num else ""), cls=cls, style=style)
        head = Tr(*[cell(Th, c, k, "table-head table-dense-head" + (" table-dense-compact-head" if compact else "") if dense else "table-head") for k, c in enumerate(kids[:cols])])
        rows = []
        for r, start in enumerate(range(cols, len(kids), cols)):
            picked = r < len(sel) and sel[r] == "1"
            role = "table-cell" + (" table-dense-cell" if dense else "") + (" table-dense-compact-cell" if compact else "") + (" table-selected" if picked else "")
            rows.append(Tr(*[cell(Td, c, k, role) for k, c in enumerate(kids[start:start + cols])], cls="sel" if picked else None))
        return Table(Thead(head), Tbody(*rows), cls=("table dense compact" if compact else "table dense") if dense else "table", id=nid, data_kind="table", data_rows=str(len(rows)),
                     data_columns=str(cols), data_selected=str(sel.count("1")))
    if kind == ROUTE:  # nothing on screen: the page keeps it in the URL's hash (ROUTE_JS)
        return Div(id=nid, data_kind="route", data_route=n["text"] or "/", data_node=str(i), data_sid=sid, hidden=True)
    if kind == DRAG:  # the browser's own drag and drop: dragstart puts the payload on the drag (DND_JS)
        return Div(*[render(s, c, sid) for c in n["children"]], cls="vstack drag", id=nid, draggable="true", data_kind="drag",
                   data_payload=n["text"], style="gap:0px;align-items:stretch")  # (a wrapper: its view where it would be, full width)
    if kind == DROP:  # dragover marks it, drop posts the payload as its on_drop (DND_JS)
        return Div(*[render(s, c, sid) for c in n["children"]], cls="vstack drop", id=nid, data_kind="drop", data_node=str(i),
                   data_sid=sid, data_files="1" if n["msg2"] else None, style="gap:0px;align-items:stretch")
    if kind == EMBED:  # a web page in an iframe (version 0: the stand-in child)
        if n["value"] <= 0:
            return Div(*[render(s, c, sid) for c in n["children"]], cls="vstack embed", id=nid, data_kind="embed", style="gap:0px")
        if web_url(n["text"]) is None:  # (http and https only, D-576: the stand-in instead of the frame)
            return Div(*[render(s, c, sid) for c in n["children"]], cls="vstack embed", id=nid, data_kind="embed", data_refused="1", style="gap:0px")
        return Div(Iframe(src=n["text"], title=n["text"], sandbox=frame_sandbox(n, getattr(s, "origin", "")), referrerpolicy="no-referrer",
                          allow=frame_allow(n) or None), cls="embed", id=nid, data_kind="embed",
                   data_url=n["text"], style=f"height:{n['size']}px" if n["size"] > 0 else "flex:1 1 0;min-height:0")  # (0: as tall as it's given)
    if kind == WEBCOMP:  # a JS widget (mojoui.webcomponent): mojoui-widgets.js puts its element in and keeps it across rebuilds
        tag, props = n["hint"], n["text"] or "{}"
        if not widget_tag(tag):
            return Div(cls="webcomponent", id=nid, data_kind="webcomponent", data_refused="1")
        try:
            ok = isinstance(json.loads(props), dict)
        except ValueError:
            ok = False
        return Div(cls="webcomponent", id=nid, data_kind="webcomponent", data_widget=tag, data_widget_id=str(n["value"]),
                   data_props=props if ok else "{}", data_refused=None if ok else "1")  # (FastHTML escapes the attribute)
    if kind == CLIPBOARD:  # nothing on screen: the page copies its text when its version moves on (CLIP_JS)
        return Div(id=nid, data_kind="clipboard", data_version=str(n["value"]), data_text=n["text"], hidden=True)
    if kind == TOAST:  # bottom centre; its action is msg, ✕ and its time running out are on_close
        action = n["options"][0] if n["options"] else ""
        parts = [Span(n["text"], cls="toast-text")]
        if action:
            parts.append(Button(action, type="button", cls="toast-action", data_action="1", **dict(common, hx_vals=json.dumps({"n": i, "second": 0}))))
        parts.append(Button("✕", type="button", cls="toast-close", aria_label="Close", **dict(common, hx_vals=json.dumps({"n": i, "second": 1}))))
        return Div(*parts, cls="toast", id=nid, data_kind="toast", data_title=n["text"], data_action=action, data_node=str(i), data_sid=sid,
                   data_seconds=str(n["size"] or 6), data_v=str(s.shape), role="status")
    if kind == POPOVER:  # a panel under (or at x, y inside) the view tagged text; placed by mojouiMenu.place
        head = (H4(n["hint"], cls="popover-title"),) if n["hint"] else ()
        return Div(*head, *[render(s, c, sid) for c in n["children"]], cls="popover", id=nid, data_kind="popover", data_title=n["hint"],
                   data_anchor=n["text"], data_x=str(n["x"]), data_y=str(n["y"]), data_node=str(i), data_sid=sid, data_v=str(s.shape), role="dialog")
    if kind == MENUBAR:
        return Div(*[render(s, c, sid) for c in n["children"]], cls="menubar", id=nid, data_kind="menubar", role="menubar")
    if kind == MENU:
        items = Div(*[render(s, c, sid) for c in n["children"]], cls="menu-items", role="menu")
        if n["style"] == 1:  # a context menu: open where the app said, inside its anchor; closes through on_close
            return Div(items, cls="menu context open", id=nid, data_kind="menu", data_title="context", data_anchor=n["text"],
                       data_x=str(n["x"]), data_y=str(n["y"]), data_node=str(i), data_sid=sid, data_v=str(s.shape))
        return Div(Button(n["text"], type="button", cls="menu-title", data_toggle="1", aria_haspopup="menu"), items,
                   cls="menu", id=nid, data_kind="menu", data_title=n["text"])
    if kind == ITEM:
        if n["style"] == 1:
            return Hr(cls="menu-sep", id=nid, data_kind="item", data_sep="1")
        if n["style"] == 2:
            return Div(n["text"], cls="menu-label", id=nid, data_kind="item", data_label="1")
        shortcut = n["options"][0] if n["options"] else ""
        flags = n["value"]
        lead = NotStr(ICONS.get("check", "").replace('width="24"', 'width="15"').replace('height="24"', 'height="15"')) if flags & CHECKED else \
            (NotStr(ICONS.get(n["hint"], "").replace('width="24"', 'width="15"').replace('height="24"', 'height="15"')) if n["hint"] else Span(cls="mi-blank"))
        if n["children"]:  # a submenu: opens beside the item
            head = Button(lead, Span(n["text"], cls="mi-title"), Span("›", cls="mi-key"), type="button", cls="mi sub", data_kind="item", data_title=n["text"], data_submenu="1")
            return Div(head, Div(*[render(s, c, sid) for c in n["children"]], cls="menu-items", role="menu"), cls="menu sub", id=nid)
        cls = "mi" + (" danger" if flags & DANGER else "") + (" checked" if flags & CHECKED else "")
        return Button(lead, Span(n["text"], cls="mi-title"), Span(shortcut, cls="mi-key") if shortcut else "", type="button", cls=cls, id=nid,
                      data_kind="item", data_title=n["text"], data_shortcut=shortcut or None, data_checked="1" if flags & CHECKED else None,
                      disabled=bool(flags & DISABLED), role="menuitem", data_closes="1", **dict(common, hx_vals=json.dumps({"n": i, "second": 0})))
    if kind == OVERLAY:
        kids = []
        for k, c in enumerate(n["children"]):
            if k == 0:
                kids.append(Div(render(s, c, sid), cls="overlay-base"))
            else:
                ch = s.nodes[c]
                h = {START: "start", END: "end"}.get(ch["x"], "center")
                v = "end" if ch["y"] == END else "start"
                kids.append(Div(render(s, c, sid), cls=f"island h-{h} v-{v}"))
        return Div(*kids, cls="overlay", id=nid, data_kind="overlay")
    if kind == CANVAS:
        # Its own size only when the app's layout doesn't size it (as on the other hosts).
        sized_w = n["w"] or (n["width_from_parent"] if "width_from_parent" in n else n["grows"] or n["fills"])
        sized_h = n["h"] or (n["height_from_parent"] if "height_from_parent" in n else n["grows"] or n["fills"])
        own = ";".join(([] if sized_w else ["width:320px"]) + ([] if sized_h else ["height:240px"]))
        return Div(Canvas(), canvas_meta(n, i), id=nid, cls="canvas", data_kind="canvas", data_node=str(i), data_sid=sid,
                   data_keys="1" if n["size"] == 1 else None, data_passthrough="1" if n["size"] == 2 else None,
                   data_scroll="pan" if n["spacing"] == 1 else None,
                   style=";".join(([own] if own else []) + (["pointer-events:none"] if n["size"] == 2 else [])) or None)
    if kind == DIVIDER:
        return Hr(id=nid)
    if kind == SPACER:
        return Div(cls="spacer", id=nid)
    kids = [render(s, c, sid) for c in n["children"]]
    if kind == SCROLL:
        return Div(*kids, cls="scroll", id=nid, style=f"max-height:{n['size']}px" if n["size"] > 0 else None, data_pin="1" if n["value"] == 1 else None)  # (0: as tall as it's given)
    cls = ({1: "vstack card", 2: "vstack card warn", 3: "vstack card good"}.get(n["style"], "vstack")) if kind == VSTACK else "hstack"
    return Div(*kids, cls=cls, id=nid, style=f"gap:{n['spacing']}px")


def canvas_meta(n, i):
    """What the canvas adapter needs to know (version, whether it wants frames), kept beside
    the <canvas> so a patch can replace it without clearing the picture."""
    return I(id=f"n{i}-meta", hidden=True, data_version=str(n["value"]), data_frames=str(n["msg2"]), data_tip=n.get("tip", ""), data_name=n.get("a11y_name", ""))


def render_alert(s, i, sid):
    """The modal for Alert node i, drawn in the overlay beside the inert page.
    Modal without scripts: a full-screen backdrop catches every click, focus starts on the
    first button, and Escape anywhere answers like the first button (Cancel), as elsewhere."""
    n = s.nodes[i]
    mid = f"n{i}-modal"  # its own id (the page keeps a hidden placeholder with id n<i>)
    common = dict(hx_post=f"/e/{sid}", hx_swap="none", hx_include="#mojoui-v")
    buttons = [Button(o, cls="prominent" if j == len(n["options"]) - 1 else "", autofocus=(j == 0),
                      hx_vals=json.dumps({"n": i, "number": j}), **common) for j, o in enumerate(n["options"])]
    dialog = Dialog(H3(n["text"], id=f"{mid}-t"), P(n["hint"]), Div(*buttons, cls="buttons"), open=True,
                    cls="alert", data_kind="alert", role="alertdialog", aria_labelledby=f"{mid}-t", aria_modal="true")
    return Div(Div(cls="alert-backdrop"), dialog, id=mid)  # (Escape: PAGE_JS clicks its first button)


def rows_div(s, i, sid, top):
    """The tall inner box of LazyList node i, holding only the rows around scroll position `top`."""
    n = s.nodes[i]
    row_h, count = n["spacing"] or 48, n["value"]
    return Div(*rows_html(s, i, sid, top), cls="rows", id=f"rows{i}", data_count=str(count),
               style=f"height:{count * row_h}px;position:relative")


def rows_html(s, i, sid, top):
    """The rows of LazyList node i around scroll position `top` (only these exist in the page)."""
    n = s.nodes[i]
    row_h, count = n["spacing"] or 48, n["value"]
    first = max(0, top // row_h - 5)
    texts = json.loads(s.mod.rows(s.handle, i, first, LIST_WINDOW))
    return [Div(t, cls="row", data_row=str(first + k), style=f"top:{(first + k) * row_h}px;height:{row_h}px",
                role="button", tabindex="0", hx_trigger="click",  # (Enter and Space click it: PAGE_JS)
                hx_post=f"/e/{sid}", hx_vals=json.dumps({"n": i, "number": first + k}), hx_swap="none",
                hx_target="this",  # htmx inherits hx-target: without this, rows inherit the list's
                hx_include="#mojoui-v") for k, t in enumerate(texts)]  # "find .rows", fail to find it, and silently send nothing


def uploads_base():
    """Where every page's uploads live (each in a folder named by its session); downloads are beside it."""
    return Path(os.environ.get("OMXCODE_UPLOADS", os.environ.get("OMXAPP_UPLOADS", Path.home() / ".cache" / "omxcode" / "uploads")))


def upload_limit():
    """One file's cap: OMXCODE_UPLOAD_MAX (32 GB by default: a 100M-row CSV is ~10 GB; 200 MB in public mode)."""
    return int(os.environ.get("OMXCODE_UPLOAD_MAX", os.environ.get("OMXAPP_UPLOAD_MAX", str(200 << 20) if PUBLIC else str(32 << 30))))


def visitor_limit():
    """What one page may keep in uploads, all files together: OMXCODE_VISITOR_MAX (public mode: 500 MB; else no cap, 0)."""
    return int(os.environ.get("OMXCODE_VISITOR_MAX", str(500 << 20) if PUBLIC else "0"))


def folder_bytes(folder):
    try:
        return sum(f.stat().st_size for f in Path(folder).rglob("*") if f.is_file() and f.name != ".owner")
    except OSError:
        return 0


TABLE_TYPES = (".csv", ".tsv", ".txt", ".parquet")
VIDEO_TYPES = (".mp4", ".mov", ".m4v", ".webm")


def check_upload(path, validator):
    """Public mode: a visitor's file is read before the app opens it, where a crash ends only the check (goal 62 M7): a
    table by `validator` (the app's own reader in a process of its own, hosts/validate_main.mojo), held to 4 GB and 60 s
    of CPU and first in line for the kernel's out-of-memory killer; a video by ffmpeg. (why not in plain words, no paths;
    "" when it may open, the table's memory once read in KB: past TABLE_KB it's refused, round 3's review). Runs in a
    worker thread under the app's CapacityLimiter (two at once)."""
    import shutil as _sh
    import subprocess

    kind = Path(path).suffix.lower()
    if kind in TABLE_TYPES:
        if not validator or not Path(validator).exists():
            print("UPLOAD: no validator: tables aren't opened (build hosts/validate_main.mojo beside the module)", flush=True)
            return "this copy can't check tables right now", 0
        cmd, why = [validator, str(path)], "it couldn't be read as a table"
    elif kind in VIDEO_TYPES:
        # (its first picture decoded, not just its header read: a truncated clip's header can be whole)
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file", "-i", str(path),  # (files only: no
               "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"]  # manifest may send it to a URL; as mojoui.video plays them)
        why = "it isn't a video this copy can play"
    else:
        return "the web copy opens CSV, Parquet and MP4 files", 0
    if not _sh.which("prlimit"):  # (make_app won't start a public copy without it)
        return "this copy can't check files right now", 0
    # (the check's own limits, 4 GB and 60 s of CPU, so a file can't take the server's; and if memory runs out anyway, the
    # kernel ends the check first, not the server)
    cmd = ["prlimit", f"--as={4 << 30}", "--cpu=60", "--", "sh", "-c", '{ echo 1000 > /proc/self/oom_score_adj; } 2>/dev/null; exec "$0" "$@"'] + cmd
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90,
                           env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/tmp", "LANG": "C.UTF-8", "MALLOC_ARENA_MAX": "2"})  # (none of the server's settings)
    except (subprocess.TimeoutExpired, OSError):
        return why, 0
    if r.returncode != 0 or (kind in VIDEO_TYPES and r.stderr.strip()):
        print(f"UPLOAD: refused a file ({why}; exit {r.returncode})", flush=True)
        return why, 0
    if kind not in TABLE_TYPES:
        return "", 0
    m = re.search(r"(\d+) rows, (\d+) columns(?:, (\d+) KB)?", r.stdout)
    if not m:
        return why, 0
    kb = max(int(m.group(3) or 0), int(m.group(1)) * int(m.group(2)) * 8 >> 10)  # (what the read took, and 8 bytes a cell at least)
    if TABLE_KB and kb > TABLE_KB:
        print(f"UPLOAD: refused a table that reads to {kb:,} KB (MOJOUI_TABLE_MB)", flush=True)
        return (f"it would take {size_words(kb << 10)} in memory once read, more than the web copy gives one table "
                f"({size_words(TABLE_KB << 10)}): open a smaller sample of it, or use the desktop app"), kb
    return "", kb


def takes_path(n):
    """A control that hands the app a file path: a FilePicker or FileSaver (a button with a second message) or a
    DropTarget's on_file. In public mode only the host makes those paths (an upload, /save), never the page's text."""
    return bool(n["msg2"]) and n["kind"] in (BUTTON, DROP)


def size_words(n):
    for unit, size in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= size:
            return f"{n / size:.3g} {unit}"
    return f"{n} bytes"


def notice(text, seconds=8):
    """A message from the host itself (not the app's view), shown like a toast and gone after a few seconds."""
    return Div(Div(Span(text, cls="toast-text"), cls="toast mojoui-notice", role="alert", data_kind="notice", data_seconds=str(seconds)),
               hx_swap_oob="beforeend:body")  # (beforeend inserts the wrapper's children: the notice itself)


def shutil_rmtree(folder):
    import shutil
    shutil.rmtree(folder, ignore_errors=True)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def owner_host():
    """This server's machine (and container: each has its own hostname and pids), as `.owner` names it."""
    import socket
    return socket.gethostname()


def safe_name(name, fallback):
    """A plain file name for an upload: no folders, no "..", and never `.owner` (the folder's pid file)."""
    name = Path(name or "").name
    return fallback if name in ("", ".", "..", ".owner") else name


def sweep_files(day=86400):
    """At start: upload and download folders whose server process is gone (its `.owner` pid, on this host), and
    unowned ones (servers before D-1704 wrote none) untouched for a day, go. A crash or a kill never ran forget_files;
    a live server's stay. Limits: a folder owned on another host or container is never swept (its pids can't be read
    here); a reused pid keeps a gone server's folder until a later start; an older-version server's session untouched
    for a day is swept."""
    swept = 0
    for kind in (uploads_base(), uploads_base().parent / "downloads", uploads_base().parent / "documents"):
        if not kind.is_dir():
            continue
        for folder in kind.iterdir():
            if not folder.is_dir():
                continue
            try:
                words = (folder / ".owner").read_text().split()
                if len(words) > 1 and words[1] != owner_host():
                    continue  # (another machine or container's server, sharing the folder: its pids aren't ours to read)
                gone = not alive(int(words[0]))
            except (OSError, ValueError, IndexError):
                try:
                    gone = time.time() - folder.stat().st_mtime > day
                except OSError:
                    continue
            if gone:
                shutil_rmtree(folder)
                swept += 1
    if swept:
        print(f"UPLOADS: swept {swept} folders a stopped server left", flush=True)


class Bucket:
    """A token bucket: ready() while a token is there; refills `rate` a second, up to `burst`."""

    def __init__(self, rate, burst):
        self.rate, self.burst, self.level, self.t = rate, burst, burst, time.monotonic()

    def ready(self):
        now = time.monotonic()
        self.level, self.t = min(self.burst, self.level + (now - self.t) * self.rate), now
        return self.level >= 1


RATES = {}  # public mode, new sessions: "" → the whole server's Bucket; an address → its own


def reset_rates():
    RATES.clear()


def rate_ok(addr):
    """Public mode: may `addr` make a session now? A token from the server's bucket and the address's, or none taken."""
    server = RATES.get("") or RATES.setdefault("", Bucket(NEW_PER_S, NEW_BURST))
    mine = RATES.get(addr) or RATES.setdefault(addr, Bucket(IP_PER_S, IP_BURST))
    if not (server.ready() and mine.ready()):
        return False
    server.level -= 1
    mine.level -= 1
    if len(RATES) > 10000:  # (addresses whose buckets are full again are forgotten)
        for k in [k for k, b in RATES.items() if k and b.ready() and b.level >= b.burst]:
            del RATES[k]
        for k in list(RATES)[1:max(1, len(RATES) - 5000)]:  # (still too many: the oldest go, bounded whatever comes)
            del RATES[k]
    return True


def client_address(req, h):
    """Who loaded the page: X-Real-IP, which the platform's proxy sets (Railway's does), else the connection's peer;
    as a key (round 4): a valid address only (at most 45 characters), and an IPv6 one as its /64, the block one home or
    office holds."""
    import ipaddress
    peer = req.client.host if req.client else ""
    header = h.get("x-real-ip") if BEHIND_PROXY else None  # (round 6: only a proxy's word; index and SessionRequests read the same)
    return address_key(header if header is not None else peer)


def address_key(text):
    """An address as a key: IPv4 (an IPv4-mapped IPv6 one too), IPv6 by its /48; anything that doesn't parse is one shared
    "unknown" (round 5: not the proxy's own address, which every visitor shares)."""
    import ipaddress
    try:
        ip = ipaddress.ip_address((text or "").strip()[:45])
    except ValueError:
        return "unknown"
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return str(ipaddress.ip_network(f"{ip}/48", strict=False)) if ip.version == 6 else str(ip)


def loopback(host):
    import ipaddress
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:
        return False


def make_app(module_dir):
    if PUBLIC_SETTING not in ("", "0", "1"):  # (a public copy whose switch reads "true" would otherwise start wide open)
        raise SystemExit(f"mojoui web: MOJOUI_PUBLIC is 1 (the public copy) or 0, not {PUBLIC_SETTING!r}: set one")
    if PUBLIC:
        import shutil as _sh
        if not _sh.which("prlimit"):  # (each upload is read in a process held by prlimit: without it, no limits at all)
            raise SystemExit("mojoui web: the public copy reads visitors' files in a process held by prlimit (util-linux), "
                             "and there's none on PATH: install util-linux")
    if DEV and not debug_build(module_dir):  # (the dev server's endpoints never run on a release build, D-678)
        raise SystemExit(f"mojoui web: MOJOUI_DEV=1 needs a debug build ({module_dir} is a release build: "
                         "MOJOUI_DEBUG=1 scripts/build.sh <app> web, or scripts/dev.sh <app>); never set it on a deployed host")
    sweep_files()  # (what a crashed or killed server left in the uploads and downloads folders, D-1704)
    sys.path.insert(0, str(Path(module_dir).resolve()))
    sys.mojoui_python_host = True  # (mojoui.pygil: Python, not the app, manages its lock here, D-1260)
    mod = importlib.import_module("mojoui_app")
    loads = mod.init_shared() if hasattr(mod, "init_shared") else 0  # the app's shared data, once per process
    if loads:
        print(f"SHARED: {loads} load, 0 sessions", flush=True)
    files = host_files()
    by_name = {hashed: (data, media) for hashed, data, media in files.values()}
    fonts = {}
    for f in sorted((STATIC / "fonts").glob("*.ttf")):
        data = f.read_bytes()
        fonts[content_name(f.name, data)] = data
        FONT_URLS[f.name] = f"/static/fonts/{content_name(f.name, data)}"
    assets, asset_tags = app_assets(module_dir, mod)
    dev_state = {"version": 0, "tags": asset_tags, "waiters": set(), "lock": threading.Lock()}  # (dev: the bundles change under the page)
    head_tags = () if DEV else tuple(asset_tags)  # (dev: the page's bundles are named per page load, the current build's)
    app = FastHTML(default_hdrs=False, secret_key=uuid.uuid4().hex, hdrs=(  # no .sesskey file
        # minimum-scale=1: a phone browser otherwise widens the page's layout viewport (innerWidth, innerHeight) to fit
        # anything wider than the screen, so a first screen laid out for a wider window read as a 780x1688 window,
        # and the app laid itself out for that, which kept the page that wide (D-547)
        Meta(charset="utf-8"), Meta(name="viewport", content="width=device-width, initial-scale=1, minimum-scale=1, viewport-fit=cover"),
        # No attribute inheritance: every element states its own hx-* attributes (list rows once
        # inherited their list's hx-target and silently sent nothing). Note: hx-vals is still
        # merged from ancestors even so, so elements set every key they rely on themselves.
        # No eval and no scripts from answers (the CSP forbids both anyway); no inline style for htmx's indicators.
        Meta(name="htmx-config", content='{"disableInheritance": true, "allowEval": false, "allowScriptTags": false, "includeIndicatorStyles": false}'),
        Script(src=f"/static/{files['htmx.min.js'][0]}"), Script(src=f"/static/{files['mojoui.js'][0]}"),
        Link(rel="stylesheet", href=f"/static/{files['mojoui.css'][0]}"), *head_tags))
    app.add_middleware(SecurityHeaders)
    if PUBLIC:
        roots = [Path(module_dir).resolve(), Path(__file__).resolve().parents[2], Path.home(), uploads_base().parent]
        for name in ("OMX_STARTER", "OMX_DOCUMENTS", "OMX_CONFIG"):
            if os.environ.get(name):
                roots += [Path(os.environ[name]), Path(os.environ[name]).resolve()]
        app.add_middleware(Scrub, roots=roots)
        app.add_middleware(BodyLimit, big=upload_limit() + (1 << 20), gate=lambda path, length: upload_gate(path, length),
                           alive=lambda sid: sid in sessions)
        app.add_middleware(SessionRequests, alive=lambda sid: sid in sessions)
        print(f"mojoui web: public mode: no agent link, no dev routes, {MAX_SESSIONS} sessions at most"
              + (f", idle ones end after {IDLE_S / 60:g} min" if IDLE_S else "") + f"; uploads {size_words(upload_limit())} a file, "
              + f"{size_words(visitor_limit())} a visitor", flush=True)
    sessions = OrderedDict()  # sid → Session, oldest first
    sessions_lock = threading.Lock()
    making = {}  # public mode: address → sessions being made now (their places are taken already)
    ended = OrderedDict()  # sid → why the server ended it (a page whose /wait comes back after that is told; the newest 1,000)
    flights = {}  # public mode: sid → (uploads in flight, the bytes they reserved)
    limiter = []  # the upload checks' anyio.CapacityLimiter (two at once), made in the event loop on first use

    def upload_gate(path, length):
        """BodyLimit's gate for /upload and /dropfile (public mode), before a byte is read: a visitor's uploads in flight
        are at most UPLOADS_AT_ONCE, and each reserves its length, so two at once can't pass the visitor's cap together
        (goal 62 round 3). (words for the page or None, release)."""
        parts = path.split("/")
        sid = parts[2] if len(parts) > 2 else ""
        if sid not in sessions:  # (round 4: no page, no upload: refused before a byte is read, nothing drained)
            print("UPLOAD: refused an upload for no session", flush=True)
            return "This page expired: reload it.", None, 0
        cap = visitor_limit()
        with sessions_lock:
            n, held = flights.get(sid, (0, 0))
            everyone = sum(b for _, b in flights.values())
            if n >= UPLOADS_AT_ONCE:
                return "Wait for your other uploads to finish first.", None, length
            if cap and sessions[sid].upload_bytes + held + length > cap:  # (a running total: no folder walk on the event loop)
                print(f"UPLOAD: refused an upload past the visitor's cap ({cap:,} bytes, {n} in flight)", flush=True)
                return f"This upload wasn't taken: your files here would pass {size_words(cap)}, the most one visitor keeps.", None, length
            if everyone + length > UPLOADS_IN_FLIGHT:  # (round 4: every visitor's uploads in flight together)
                print(f"UPLOAD: refused an upload past the server's uploads in flight ({everyone:,} bytes)", flush=True)
                return "The server is taking other visitors' uploads right now: try again in a minute.", None, length
            flights[sid] = (n + 1, held + length)

        def release():
            with sessions_lock:
                n, held = flights.pop(sid, (1, length))
                if n > 1:
                    flights[sid] = (n - 1, held - length)
        return None, release, 0

    def checks():
        import anyio
        if not limiter:
            limiter.append(anyio.CapacityLimiter(2))
        return limiter[0]

    def take_table(s, path, kb):
        """Public mode: a checked table counted against its visitor's tables together (VISITOR_TABLES_KB): "" when it
        fits, else why not in plain words."""
        with sessions_lock:
            held = sum(k for p, k in s.tables_kb.items() if Path(p).exists())
            if VISITOR_TABLES_KB and held + kb > VISITOR_TABLES_KB:
                print(f"UPLOAD: refused a table past the visitor's tables together ({held + kb:,} KB)", flush=True)
                return (f"with your tables already here it would take {size_words((held + kb) << 10)} in memory, more than "
                        f"the web copy holds for one visitor ({size_words(VISITOR_TABLES_KB << 10)}): use the desktop app for more")
            s.tables_kb[str(path)] = kb
        return ""

    def busy_page(words):
        return (Title("Busy"), Main(Div(H2("Busy right now", cls="text headline"), P(words, cls="text"),
                                        A("Try again", href="/", cls="button prominent"), cls="mojoui-busy-page"), id="mojoui-root"))

    def admit(addr):
        """Public mode, under sessions_lock: why a new session from `addr` can't be made now ("": it can, its place is
        taken). Every session holds a place from the moment it's made, a bare load's too (goal 62 round 3: bare loads
        overshot the cap twice over); one address holds PER_IP places at most; and loads are rate-limited."""
        taken = len(sessions) + sum(making.values())
        if taken >= MAX_SESSIONS:
            return f"{MAX_SESSIONS} visitors are exploring this copy, the most it holds at once. Try again in a few minutes."
        held = sum(1 for v in sessions.values() if v.client == addr) + making.get(addr, 0)
        if held >= PER_IP:  # (round 4: always; near the cap only, one address held 4 of 6)
            return f"{held} of this copy's places are open from your address already, the most one address holds: close a tab, or try again in a few minutes."
        if not rate_ok(addr):
            return "Many visitors are arriving at once. Try again in a few seconds."
        making[addr] = making.get(addr, 0) + 1
        return ""
    jslog_counts = {}  # sid → JS errors logged (at most 100 a page)
    validator = os.environ.get("MOJOUI_VALIDATE") or str(Path(module_dir) / "validate")  # (public mode: uploads read here first)

    def end_session(sid, s, reason):
        """The server ends a tab (idle, or the server is full and it was the oldest): its app closes, its files go, and
        its page, waiting on /wait, is told why."""
        with sessions_lock:
            if sessions.get(sid) is s:
                del sessions[sid]
        with s.lock:
            if not s.closed:
                s.closed = True
                s.gone_reason = reason
                mod.close(s.handle)
        forget_files(sid)
        jslog_counts.pop(sid, None)
        getattr(s, "downloads", {}).clear()
        with sessions_lock:  # (round 5: its uploads in flight no longer hold the server's budget; BodyLimit stops reading them)
            flights.pop(sid, None)
        if reason:
            with sessions_lock:
                ended[sid] = reason
                while len(ended) > 1000:
                    ended.popitem(last=False)
        s.wake()

    def reap():
        """IDLE_S: tabs with no input for that long end (their page says so); SESSION_MAX_S: a visit ends at that age;
        public mode: a session no page came back to ends after UNTOUCHED_S. Checked a few times a minute."""
        while True:
            time.sleep(max(0.25, min([5.0] + [t / 4 for t in (IDLE_S, SESSION_MAX_S, UNTOUCHED_S if PUBLIC else 0) if t > 0])))
            now = time.monotonic()
            gone = []
            with sessions_lock:
                for sid, s in sessions.items():
                    if SESSION_MAX_S > 0 and now - s.made > SESSION_MAX_S:
                        mins = SESSION_MAX_S / 60
                        said = f"{mins:g} minutes" if mins >= 1 else f"{SESSION_MAX_S:g} seconds"
                        gone.append((sid, s, f"This visit reached its longest, {said}, and its files are gone. Reload the page to start a new one."))
                    elif PUBLIC and not s.touched and now - s.made > UNTOUCHED_S:
                        # (a session no page came back to: a bare ?boot=1, a crawler; its place is free again in 10 s)
                        gone.append((sid, s, "This session ended because its page never came back to it. Reload the page to start a new one."))
                    elif IDLE_S > 0 and now - s.last_active > IDLE_S:
                        mins = IDLE_S / 60
                        said = f"{mins:g} minutes" if mins >= 1 else f"{IDLE_S:g} seconds"
                        gone.append((sid, s, f"This session ended after {said} without use, and its files are gone. Reload the page to start a new one."))
            for sid, s, why in gone:
                end_session(sid, s, why)
                print(f"SESSION: ended {'a visit at its longest' if 'longest' in why else 'an idle tab'} ({len(sessions)} open)", flush=True)

    if IDLE_S > 0 or SESSION_MAX_S > 0 or PUBLIC:
        threading.Thread(target=reap, daemon=True, name="mojoui-idle").start()

    @app.post("/bye/{sid}")
    def bye(sid: str):
        """The page went away (pagehide's beacon): its session ends now, not when it would have idled out."""
        s = sessions.get(sid)
        if s is not None:
            end_session(sid, s, "")
        return Response(status_code=204)

    @app.get("/health")
    async def health():  # (async: no worker thread, so a flood of blocking requests can't hold it up, round 4)
        """Is the server up, and how full (a platform's health check; no page, no session, no paths)."""
        from starlette.responses import JSONResponse
        with sessions_lock:
            n = len(sessions)
        return JSONResponse({"ok": True, "sessions": n, "max": MAX_SESSIONS}, headers={"Cache-Control": "no-store"})

    clock = threading.Condition()
    due = {}  # sid → (monotonic time its effects are due, its Session)

    def deliver(sid, s, path):
        """A file or folder the app made for the person (App.take_download): into this tab's downloads folder (a folder
        as one zip), removed from where the app wrote it, and named to the page by a one-time token (/download), never
        by its path. Only what lies in the tab's own folders (its documents, uploads) is sent."""
        import shutil
        src = Path(path).resolve()
        mine = [d.resolve() for d in (uploads_base().parent / "documents" / sid, uploads_base() / sid)]
        if not any(src == d or d in src.parents for d in mine) or not src.exists():
            if PUBLIC:
                print("REFUSED: a hand-over outside the tab's own folders", flush=True)
                return
            if not src.exists():
                return
        out = file_folder(sid, "downloads")
        size = sum(f.stat().st_size for f in src.rglob("*") if f.is_file()) if src.is_dir() else src.stat().st_size
        if PUBLIC and size > 300 << 20:  # (a download from a shared server: kept small)
            print("REFUSED: a hand-over over 300 MB", flush=True)
            shutil.rmtree(src, ignore_errors=True) if src.is_dir() else src.unlink(missing_ok=True)
            return
        if src.is_dir():
            import zipfile
            made = out / f"{src.name or 'files'}.zip"
            with zipfile.ZipFile(made, "w") as z:  # (pictures, clips and PDFs are compressed already: stored as they are)
                for f in sorted(src.rglob("*")):
                    if f.is_file():
                        z.write(f, f.relative_to(src), compress_type=zipfile.ZIP_STORED if f.suffix.lower() in (".mp4", ".pdf", ".png", ".jpg", ".zip") else zipfile.ZIP_DEFLATED)
            shutil.rmtree(src, ignore_errors=True) if PUBLIC else None
        else:
            made = out / src.name
            if PUBLIC:
                shutil.move(str(src), made)
            else:
                shutil.copyfile(src, made)
        token = uuid.uuid4().hex
        s.downloads = getattr(s, "downloads", {})
        s.downloads[token] = made
        s.deliveries.append((f"/download/{sid}/{token}", made.name))

    def note(sid, s):
        """After any call that ran update() (s.lock held): when this tab's effects (HTTP replies, timer ticks) are due
        next (Runtime.wake_in), for the clock thread; and what the app handed over, made ready for the page."""
        if hasattr(mod, "take_download"):
            got = mod.take_download(s.handle)
            if got:
                deliver(sid, s, got)
        if hasattr(mod, "commands"):  # (widget commands the update asked for: sent with the next answer, cmds_mark)
            taken = json.loads(mod.commands(s.handle))
            if taken:
                s.commands.extend(taken)
        if not hasattr(mod, "wake_in"):
            return
        w = mod.wake_in(s.handle)
        s.busy = w >= 0 or bool(AGENT_SOCKET)  # (an attached agent changes the screen behind the page: it keeps waiting on /wait)
        with clock:
            if w < 0:
                due.pop(sid, None)
            else:
                due[sid] = (time.monotonic() + w / 1e6, s)
                clock.notify()

    def tick():
        """The clock thread: polls each tab's runtime when its effects are due; the changes wait in the session for the
        page (its /wait returns, it asks /pending)."""
        while True:
            with clock:
                while True:
                    if not due:
                        clock.wait()
                        continue
                    sid, (at, s) = min(due.items(), key=lambda kv: kv[1][0])
                    delay = at - time.monotonic()
                    if delay <= 0:
                        del due[sid]
                        break
                    clock.wait(delay)
            with s.lock:
                if s.closed:
                    continue
                d = json.loads(mod.poll(s.handle))
                if d.get("rebuild") or d.get("patches"):
                    s.pending = merge(s.pending, d)
                    s.nodes = json.loads(mod.view(s.handle))
                note(sid, s)
                if has_changes(s) or s.busy != s.busy_sent:
                    s.wake()

    if hasattr(mod, "poll"):
        threading.Thread(target=tick, daemon=True, name="mojoui-effects").start()

    def has_changes(s):
        return bool(s.pending and (s.pending.get("rebuild") or s.pending.get("patches"))) or bool(s.commands) or bool(s.deliveries)

    def delivery_marks(s):
        """The downloads the app handed over since the last answer: the page fetches each (DOWNLOAD_JS), then they're gone."""
        marks = tuple(Div(I(cls="mojoui-download", hidden=True, data_url=url, data_name=name), hx_swap_oob="beforeend:body") for url, name in s.deliveries)
        s.deliveries = []
        return marks

    def jobs_ended(fd):
        """mojoui.jobs: a background job ended (its wake pipe is readable): App.jobs_message through every tab's update()
        at once, and the page told as an effect's changes are (pending + /wait); the frame poll stays the fallback."""
        while True:
            try:
                if not os.read(fd, 4096):
                    return
                time.sleep(0.01)  # (a burst of wakes, every playing video's every frame, is one round: goal 62 M5)
                os.set_blocking(fd, False)
                try:
                    os.read(fd, 65536)
                except BlockingIOError:
                    pass
                finally:
                    os.set_blocking(fd, True)
            except OSError:
                return
            with sessions_lock:
                live = list(sessions.items())
            for sid, s in live:
                with s.lock:
                    if s.closed:
                        continue
                    try:
                        d = json.loads(mod.jobs(s.handle))
                        if d.get("rebuild") or d.get("patches"):
                            s.pending = merge(s.pending, d)
                            s.nodes = json.loads(mod.view(s.handle))
                        note(sid, s)
                    except Exception:  # (one tab's failure is printed, and the next wake still reaches every tab)
                        traceback.print_exc()
                        continue
                    if has_changes(s) or s.busy != s.busy_sent:
                        s.wake()

    wake_fd = mod.wake_fd() if hasattr(mod, "wake_fd") else -1  # (before the first session: its jobs wake the tab too)
    if wake_fd >= 0:
        threading.Thread(target=jobs_ended, args=(wake_fd,), daemon=True, name="mojoui-jobs").start()

    def cmds_mark(s, oob=False):
        """The widget commands waiting for the page (mojoui-widgets.js runs each once, by its seq), then none."""
        batch, s.commands = s.commands, []
        mark = I(id="mojoui-cmds", hidden=True, data_cmds=json.dumps(batch))
        if oob:
            mark.attrs["hx-swap-oob"] = "true"
        return mark

    def busy_mark(s, oob=False):
        s.busy_sent = s.busy
        mark = I(id="mojoui-busy", hidden=True, data_busy="1" if s.busy else "0")
        if oob:
            mark.attrs["hx-swap-oob"] = "true"
        return mark

    def root(s, sid, oob=False):
        version = Input(type="hidden", id="mojoui-v", name="v", value=str(s.shape))
        alerts = [i for i, n in enumerate(s.nodes) if n["kind"] == ALERT]
        # While an alert is up the page behind is inert (no clicks, no keyboard focus);
        # the alert lives in an overlay beside it.
        full = s.nodes[0]["grows"] or s.nodes[0]["fills"]  # the screen fills the window
        page = Main(version, busy_mark(s), render(s, 0, sid), id="mojoui-root", cls="full" if full else None, inert=bool(alerts), data_sid=sid,
                    data_push="1" if PUSH else None,  # (playing canvases' pictures pushed: the public copy, or MOJOUI_PUSH=1)
                    data_agent="1" if AGENT_SOCKET else None, data_dev="1" if DEV else None)  # (widgets tell the host what they show only while an agent may read it)
        layer = Div(*[render_alert(s, i, sid) for i in alerts], id="mojoui-overlay")
        if oob:
            page.attrs["hx-swap-oob"] = "true"
            layer.attrs["hx-swap-oob"] = "true"
        return page, layer

    @app.get("/static/htmx.min.js")
    def htmx_js():
        return Response((STATIC / "htmx.min.js").read_bytes(), media_type="text/javascript",
                        headers={"Cache-Control": "public, max-age=86400"})

    @app.get("/static/fonts/{name}")
    def font(name: str):
        """The app's own fonts (Inter, JetBrains Mono, Geist: SIL OFL), so every browser shows the same type (D-155): by
        content hash (what the page names), or by plain name for older pages."""
        if name in fonts:
            return Response(fonts[name], media_type="font/ttf", headers={"Cache-Control": IMMUTABLE})
        path = STATIC / "fonts" / Path(name).name
        if path.suffix != ".ttf" or not path.exists():
            return Response(status_code=404)
        return Response(path.read_bytes(), media_type="font/ttf", headers={"Cache-Control": "public, max-age=86400"})

    @app.get("/favicon.ico")
    def favicon():
        """No icon file (an app's logo is its icon, inline): an empty answer, not a 404 in the console."""
        return Response(status_code=204, headers={"Cache-Control": "public, max-age=86400"})

    @app.get("/static/{name}")
    def static_file(name: str):
        """The host's scripts and style sheet, by content hash."""
        if name not in by_name:
            return Response(status_code=404)
        data, media = by_name[name]
        return Response(data, media_type=media, headers={"Cache-Control": IMMUTABLE})

    @app.get("/assets/{name}")
    def asset(name: str):
        """The app's bundles (App.web_assets()), by content hash; nothing else."""
        if name not in assets:
            return Response(status_code=404)
        data, media = assets[name]
        return Response(data, media_type=media, headers={"Cache-Control": IMMUTABLE})

    def close_all():
        """The server is stopping: every live session's App.closing (a pending save), then its handle goes."""
        with sessions_lock:
            while sessions:
                old_sid, old = sessions.popitem(last=False)
                with old.lock:
                    if not old.closed:
                        old.closed = True
                        mod.close(old.handle)
                forget_files(old_sid)
    import atexit
    atexit.register(close_all)

    @app.get("/")
    def index(req, boot: str = ""):
        """A page load: a new app session, its first screen. Only a browser loading the page makes one (Sec-Fetch-Dest:
        document, Sec-Fetch-Mode: navigate, not a prefetch), or the page itself (?boot=1, from a browser that sends no
        Sec-Fetch headers): a link preview, a crawler or a script's plain GET gets the shell, which makes nothing (goal
        62 M3). Public mode: past MAX_SESSIONS, a busy page."""
        h = {k.lower(): v for k, v in req.headers.items()}
        load = boot == "1" or (h.get("sec-fetch-dest") == "document" and h.get("sec-fetch-mode") == "navigate" and "prefetch" not in h.get("sec-purpose", ""))
        if not load:
            return Title("omxplorer" if not hasattr(mod, "title") else "omxcode"), Main(P("Opening…", cls="text caption"), id="mojoui-root", data_boot="1")
        addr = client_address(req, h) if PUBLIC else ""
        if PUBLIC:
            with sessions_lock:  # (the place is taken here, before the session is made: a burst can't pass the cap together)
                why = admit(addr)
            if why:
                return busy_page(why)
        sid = uuid.uuid4().hex  # one app session per page load (tab)

        def made():  # (under sessions_lock: its place moves from "being made" to the session, in one step, round 4)
            if PUBLIC:
                making[addr] -= 1
                if making[addr] <= 0:
                    del making[addr]
        try:
            s = Session(mod, shared=bool(loads))
            s.client = addr
            s.origin = page_origin(req.url.scheme, req.url.netloc, h)
            if hasattr(mod, "hosted"):  # (where this tab's documents go: its own folder in public mode, as the app likes else)
                with s.lock:
                    mod.hosted(s.handle, str(file_folder(sid, "documents")) if PUBLIC else "", PUBLIC)
                    s.nodes = json.loads(mod.view(s.handle))  # (the first screen as the app has it now: a public Start screen differs)
        except BaseException:
            with sessions_lock:
                made()
            raise
        if PUBLIC:
            print(f"SESSION: made for {addr}", flush=True)  # (scripts/deploy-railway reads this: is X-Real-IP the proxy's?)
        gone = []
        with sessions_lock:
            made()
            sessions[sid] = s
            if not PUBLIC:
                gone += list(sessions.items())[:max(0, len(sessions) - MAX_SESSIONS)]  # (local: the oldest tab gives way)
        for old_sid, old in gone:
            end_session(old_sid, old, "This page was closed to make room. Reload it to start again.")
        # The whole first page under the session's lock: once note() hands the tab to the clock thread, its effects'
        # replies can change the screen at any moment, and a page rendered meanwhile was torn (a deep link's Route
        # missing from the first page under load, so the route was never asked for; D-545).
        with s.lock:
            note(sid, s)  # (what the starting state asked for)
            s.theme_key = mod.theme_key(s.handle)
            s.theme_id = None
            if hasattr(mod, "logo") and "app-logo" not in ICONS:
                mark = mod.logo(s.handle)
                if mark:
                    ICONS["app-logo"] = mark
            icon = ()
            if "app-logo" in ICONS:  # (the app's mark as the tab's icon)
                from urllib.parse import quote
                icon = (Link(rel="icon", type="image/svg+xml", href="data:image/svg+xml," + quote(ICONS["app-logo"])),)
            return Title(mod.title(s.handle)), *icon, *root(s, sid), cmds_mark(s), *skin(s), *(dev_state["tags"] if DEV else ())

    def skin(s, oob=False):
        """The app's theme on the page (D-260): its body classes, its palette as CSS variables, and its style sheet; the
        host knows no theme. oob: after a change (Settings → Appearance, a mode's tint), swapped into the open page
        (D-156); the style sheet goes again only when the theme itself changed, not just its palette."""
        tid, classes, css_vars, css, *more = mod.theme(s.handle).split("\x1f")
        tokens = more[0] if more else "{}"  # (the Look's tokens as JSON, for widgets' theme(el, tokens): goal 34b)
        parts = (Style(css_vars, id="mojoui-skin"), I(hidden=True, id="mojoui-skin-classes", data_classes=classes, data_tokens=tokens))  # (PAGE_JS applies them)
        if (tid, len(css)) != s.theme_id:  # (the sheet itself changed: a new theme, or a theme's new sheet)
            parts += (Style(FONT_REF.sub(lambda m: f"url({FONT_URLS.get(m.group(1), '/static/fonts/' + m.group(1))})", css), id="mojoui-theme"),)
            s.theme_id = (tid, len(css))
        if oob:
            for el in parts:
                el.attrs["hx-swap-oob"] = "true"
        return parts

    @app.get("/img/{sid}/{n}")
    def image(sid: str, n: int):
        s = sessions.get(sid)
        if s is None:
            return Response(status_code=404)
        with s.lock:  # the pixels belong to the current screen: read them before any other event
            if s.closed:
                return Response(status_code=404)
            addr, w, h, nbytes = map(int, mod.image(s.handle, n).split())
            if not addr or nbytes != w * h * 4:
                return Response(status_code=404)
            data = png(ctypes.string_at(addr, nbytes), w, h)
        return Response(data, media_type="image/png", headers={"Cache-Control": "no-store"})

    @app.post("/rows/{sid}/{n}")
    def rows(sid: str, n: int, top: int = 0, v: int = -1):
        s = sessions.get(sid)
        if s is None:
            return ""
        with s.lock:
            if s.closed or v != s.shape or not 0 <= n < len(s.nodes) or s.nodes[n]["kind"] != LAZYLIST:
                return Response(status_code=204)  # htmx leaves the list alone on 204
            s.list_top[n] = max(top, 0)
            return rows_div(s, n, sid, s.list_top[n])

    def restyle(s, out):
        """A skin picked in Settings, or a mode's tint changed (Theme.key): the page restyles with whatever else goes out (D-156)."""
        key = mod.theme_key(s.handle)
        if key == s.theme_key:
            return out
        s.theme_key = key
        return (out if isinstance(out, tuple) else ((out,) if out != "" else ())) + skin(s, oob=True)

    def changes(s, sid, d, n=-1, text="", number=0):
        """What to send the page after a change: the whole screen on a rebuild, else the changed
        controls (out-of-band swaps). Call with s.lock held, after s.nodes was refreshed."""
        note(sid, s)
        out = changes_of(s, sid, d, n, text, number)
        if s.busy != s.busy_sent:  # (requests went out, or the last one came back: the page starts or stops waiting)
            mark = busy_mark(s, oob=True)
            out = (out if isinstance(out, tuple) else ((out,) if out != "" else ())) + (mark,)
        if s.commands:  # (after the screen: a command can name a widget this answer puts on it)
            out = (out if isinstance(out, tuple) else ((out,) if out != "" else ())) + (cmds_mark(s, oob=True),)
        if s.deliveries:  # (files the app handed over: downloads, App.take_download)
            out = (out if isinstance(out, tuple) else ((out,) if out != "" else ())) + delivery_marks(s)
        return out

    def changes_of(s, sid, d, n=-1, text="", number=0):
        if d["rebuild"]:
            s.pending = None  # the whole screen goes out: older pending patches name old nodes
            s.shape += 1
            s.images.clear()
            s.list_top.clear()
            source = s.nodes[n] if 0 <= n < len(s.nodes) else None
            typing = (FIELD, TEXTAREA)
            s.focus = n if source and source["kind"] in typing and s.nodes[n]["kind"] == source["kind"] else None
            out = root(s, sid, oob=True)
            s.focus = None
            return restyle(s, out)
        changed = []
        moved = []  # SET_PLACE: the object's div is moved in place (re-rendering it would restart its canvases)
        for p in d["patches"]:
            i, op = p["node"], p["op"]
            target = s.nodes[i]
            if op == SET_IMAGE:
                s.images[i] = s.images.get(i, 0) + 1
            if op == SET_PLACE or (op == SET_VALUE and target["kind"] == BOARD):  # (a Board's value: what to reveal)
                mark = place_mark(s, i)
                mark.attrs["hx-swap-oob"] = "true"
                moved.append(mark)
                continue
            if op == SET_TONES:  # (a Board's children's tones: each object's mark carries its own, BOARD_JS applies it)
                for c in target["children"]:
                    mark = place_mark(s, c)
                    mark.attrs["hx-swap-oob"] = "true"
                    moved.append(mark)
                continue
            # Don't re-send the control in use if it already shows this (that would steal
            # focus or interrupt a drag); other changes to it still go out.
            echo = i == n and ((op == SET_TEXT and target["kind"] in (FIELD, TEXTAREA, DATE) and target["text"] == text)
                               or (op == SET_VALUE and target["kind"] in (TOGGLE, SLIDER) + CHOICES
                                   and target["value"] == number))
            if (op != SET_MSG or target["kind"] == CANVAS) and not echo and i not in changed:
                changed.append(i)
        out = []
        for i in changed:
            if s.nodes[i]["kind"] == LAZYLIST:
                continue  # refreshed below without resetting its scroll position
            # A canvas keeps its <canvas> (and picture): only its version/frames note changes.
            el = canvas_meta(s.nodes[i], i) if s.nodes[i]["kind"] == CANVAS else render(s, i, sid)
            el.attrs["hx-swap-oob"] = "true"
            out.append(el)
        # Re-send the visible rows of every long list: row text isn't part of the view,
        # so an edit that keeps the count wouldn't show otherwise.
        for i, node in enumerate(s.nodes):
            if node["kind"] == LAZYLIST:
                el = rows_div(s, i, sid, s.list_top.get(i, 0))
                el.attrs["hx-swap-oob"] = "true"
                out.append(el)
        out += moved
        return restyle(s, tuple(out)) if out else restyle(s, "")

    def merge(a, b):
        """Two diffs one after the other, as one."""
        if a is None:
            return b
        if a["rebuild"] or b["rebuild"]:
            return {"rebuild": True}
        return {"rebuild": False, "patches": a["patches"] + b["patches"]}

    @app.post("/e/{sid}")
    def event(sid: str, n: int, v: int = -1, second: int = 0, text: str = "", number: int = 0, on: str = "",
              x: float = 0, y: float = 0, dx: float = 0, dy: float = 0, zoom: float = 1, route: int = 0, pressure: float = 0):
        import math
        if not all(math.isfinite(f) and abs(f) < 1e9 for f in (x, y, dx, dy, zoom, pressure)):
            return ""  # (NaN, inf or a huge number is no event: int() of one was a 500, round 6)
        if EVENT_DELAY:  # (checks only: a slow network, so keys typed meanwhile really wait for the answer)
            time.sleep(EVENT_DELAY)
        s = sessions.get(sid)
        if s is None:
            return Main(P("This page expired: reload it.", cls="text caption"), id="mojoui-root", hx_swap_oob="true")
        with s.lock:
            if s.closed:
                return Main(P("This page expired: reload it.", cls="text caption"), id="mojoui-root", hx_swap_oob="true")
            if route:  # a new hash (a link, Back): it names no control, so it goes to whichever Route the screen has now (an app whose
                found = [i for i, node in enumerate(json.loads(mod.view(s.handle))) if node["kind"] == ROUTE]  # replies rebuilt the screen meanwhile still hears it)
                if not found:
                    return ""
                d = json.loads(mod.event(s.handle, found[0], 0, text, 0))
                if d.get("ignored"):
                    return ""
                s.nodes = json.loads(mod.view(s.handle))
                return changes(s, sid, {"rebuild": True} if s.pending else d, found[0], text, 0)
            if s.pending and s.pending.get("rebuild"):  # a frame changed the screen; this event names old nodes
                return changes(s, sid, s.pending)  # send the new screen instead of acting on the wrong control
            if v != s.shape or not 0 <= n < len(s.nodes):
                return ""  # from an older screen (e.g. a double click on a row that's gone): ignore
            source = s.nodes[n]
            s.last_active = time.monotonic()
            s.touched = True
            if PUBLIC and second != 0 and takes_path(source):  # (a picker's, saver's or drop's path: only the host makes it; any second
                # but 0 reaches its second message: 2, Escape for a field, is a picker's pick too)
                print("REFUSED: a path for a file control sent as text", flush=True)
                return ""
            if source["kind"] == TOGGLE:
                number = 1 if on else 0
            if source["kind"] == CANVAS and number == KEY:
                d = json.loads(mod.key(s.handle, n, text, int(dx)))
            elif source["kind"] == FIELD and second == 2:  # Escape (on_cancel)
                d = json.loads(mod.cancel(s.handle, n, text))
            elif source["kind"] in (CANVAS, BOARD):
                d = json.loads(mod.gesture(s.handle, n, number, x, y, dx, dy, zoom, pressure))
            else:
                d = json.loads(mod.event(s.handle, n, second, text, number))
            if d.get("ignored"):
                return ""
            s.nodes = json.loads(mod.view(s.handle))  # the screen as Mojo now has it
            return changes(s, sid, d, n, text, number)  # (restyles too, when the skin or the tint changed)

    @app.post("/w/{sid}")
    def widget_event(sid: str, tag: str = "", id: int = 0, name: str = "", data: str = ""):
        """A widget's event (mojoui-widgets.js emit): the widget by its key (tag, id), not its node, so an event sent
        while the screen was rebuilt still lands. Only a word for a name and JSON for the payload get through."""
        s = sessions.get(sid)
        if s is None or not hasattr(mod, "widget_event") or not widget_tag(tag) or not event_name(name) or len(data) > MAX_WIDGET_BYTES:
            return ""
        try:
            json.loads(data)
        except ValueError:
            return ""
        with s.lock:
            if s.closed:
                return ""
            s.last_active = time.monotonic()
            found = [i for i, node in enumerate(s.nodes) if node["kind"] == WEBCOMP and node["hint"] == tag and node["value"] == id]
            if not found:
                return ""
            d = json.loads(mod.widget_event(s.handle, found[0], name, data))
            if d.get("ignored"):
                return ""
            if s.pending:  # (changes waiting from frames or effects go with it)
                d, s.pending = merge(s.pending, d), None
            s.nodes = json.loads(mod.view(s.handle))
            return changes(s, sid, d, found[0])

    @app.post("/reply/{sid}")
    def widget_reply(sid: str, seq: int = 0, data: str = "", error: str = ""):
        """A widget's answer to command `seq` (or why it has none): the runtime takes it once, as JSON."""
        s = sessions.get(sid)
        if s is None or not hasattr(mod, "reply"):
            return ""
        if len(data) > MAX_WIDGET_BYTES:
            data, error = "", "the reply is too big"
        with s.lock:
            if s.closed:
                return ""
            d = json.loads(mod.reply(s.handle, seq, data, error[:500]))
            if d.get("ignored"):
                return ""
            if s.pending:
                d, s.pending = merge(s.pending, d), None
            s.nodes = json.loads(mod.view(s.handle))
            return changes(s, sid, d)

    @app.post("/jslog/{sid}")
    def jslog(sid: str, message: str = "", source: str = "", line: int = 0, column: int = 0, widget: str = ""):
        """A widget's uncaught JS error, with its original file and line where the page could read the bundle's source map
        (debug builds): one line in the app's log. Plain text only, cut short, at most 100 per page."""
        if sid not in sessions:
            return ""
        jslog_counts[sid] = jslog_counts.get(sid, 0) + 1
        if jslog_counts[sid] > 100:
            return ""
        clean = lambda t, n: re.sub(r"[\x00-\x1f\x7f]", " ", str(t))[:n]
        where = f"{clean(source, 200)}:{int(line)}:{int(column)}" if source else "(no position)"
        print(f"JS ERROR: {where}: {clean(message, 500)}" + (f" ({clean(widget, 80)})" if widget else ""), flush=True)
        return ""

    if DEV:
        from starlette.responses import JSONResponse

        def local(req):
            return req.client is not None and req.client.host == "127.0.0.1"

        @app.get("/dev/assets")
        def dev_assets(req):
            """(dev) The bundles this build has now: [{name, file, integrity}], for the page to load the new ones."""
            if not local(req):
                return Response(status_code=403)
            names = json.loads(mod.web_assets()) if hasattr(mod, "web_assets") else []
            folder = Path(module_dir) / "assets"
            manifest = json.loads((folder / "manifest.json").read_text()) if (folder / "manifest.json").exists() else {}
            return JSONResponse([{"name": n, "file": manifest[n]["file"], "integrity": manifest[n]["integrity"]} for n in names if n in manifest])

        @app.post("/dev/reload")
        def dev_reload(req, token: str = ""):
            """(dev) scripts/dev.py rebuilt the bundles: serve the new ones, tell the open pages."""
            import hmac
            if not local(req) or not DEV_TOKEN or not hmac.compare_digest(token, DEV_TOKEN):
                return Response(status_code=403)
            try:
                fresh, tags = app_assets(module_dir, mod)
            except SystemExit as e:
                print(f"dev: not reloaded: {e}", flush=True)
                return Response(str(e), status_code=409)
            with dev_state["lock"]:
                assets.update(fresh)
                dev_state["tags"] = tags
                dev_state["version"] += 1
                for loop, ev in list(dev_state["waiters"]):
                    loop.call_soon_threadsafe(ev.set)
            return str(dev_state["version"])

        @app.get("/dev/wait/{seen}")
        async def dev_wait(req, seen: int):
            """(dev) Returns the bundles' version once it is past `seen` (20 s at most): the page then reloads its widgets."""
            import asyncio
            if not local(req):
                return Response(status_code=403)
            if dev_state["version"] > seen:
                return str(dev_state["version"])
            ev = asyncio.Event()
            entry = (asyncio.get_running_loop(), ev)
            with dev_state["lock"]:
                dev_state["waiters"].add(entry)
            try:
                if dev_state["version"] <= seen:
                    await asyncio.wait_for(ev.wait(), 20)
            except asyncio.TimeoutError:
                pass
            finally:
                with dev_state["lock"]:
                    dev_state["waiters"].discard(entry)
            return str(dev_state["version"])

    @app.get("/spot/{sid}/{n}")
    def canvas_spot(sid: str, n: int, name: str = ""):
        """App.spot: where on canvas node n the part called `name` is drawn ("x,y" in points; "-1,-1": nowhere). Test
        drivers reach a drawn part with it (scripts/drive.py's linkdrag)."""
        s = sessions.get(sid)
        if s is None:
            return "-1,-1"
        with s.lock:
            if s.closed or not 0 <= n < len(s.nodes) or s.nodes[n]["kind"] != CANVAS:
                return "-1,-1"
            return mod.spot(s.handle, n, name)

    @app.post("/describe/{sid}")
    def widget_describe(sid: str, tag: str = "", id: int = 0, data: str = ""):
        """What a widget says about itself (mojoui-widgets.js facts: its description, describe()'s JSON, its fields), kept for
        an attached agent. Only with an agent link; only JSON, a widget tag and a widget on the screen."""
        s = sessions.get(sid)
        if not AGENT_SOCKET or s is None or not widget_tag(tag) or len(data) > MAX_WIDGET_BYTES:
            return ""
        try:
            facts = json.loads(data)
        except ValueError:
            return ""
        if not isinstance(facts, dict):
            return ""
        with s.lock:
            if not s.closed and any(n["kind"] == WEBCOMP and n["hint"] == tag and n["value"] == id for n in s.nodes):
                s.widget_facts[(tag, id)] = facts
        return ""

    def link_session():
        """The agent link's session: the newest page (a tab opened later takes over)."""
        with sessions_lock:
            for sid in reversed(sessions):
                if not sessions[sid].closed:
                    return sid, sessions[sid]
        return None, None

    def link_call(op):
        """One agent-link request (docs/agent.md): view, event, gesture, key, set, describe, rows. Changes are pushed to
        the page the way an effect's are (pending + /wait)."""
        sid, s = link_session()
        if s is None:
            return {"ok": False, "error": "no page is open: open the app in a browser"}
        what = op.get("op")
        with s.lock:
            if s.closed:
                return {"ok": False, "error": "the page closed"}
            h = s.handle
            if what == "view":
                nodes = json.loads(mod.view(h))
                keys = {(n["hint"], n["value"]) for n in nodes if n["kind"] == WEBCOMP}
                s.widget_facts = {k: v for k, v in s.widget_facts.items() if k in keys}
                return {"ok": True, "title": mod.title(h), "design": mod.theme(h).split("\x1f")[0], "nodes": nodes,
                        "widgets": list(s.widget_facts.values()), "busy": has_changes(s) or s.busy_sent != s.busy}
            n = int(op.get("node", -1))
            if what in ("event", "gesture", "key", "describe", "rows") and not 0 <= n < len(s.nodes):
                return {"ok": False, "error": f"no node {n} on the screen"}
            if what == "describe":
                return {"ok": True, "text": mod.describe(h, n, int(op.get("first", 0)), int(op.get("count", 0)))}
            if what == "rows":
                return {"ok": True, "rows": json.loads(mod.rows(h, n, int(op.get("first", 0)), int(op.get("count", 50))))}
            if what == "set":
                tag, field, value = str(op.get("tag", "")), str(op.get("field", "")), str(op.get("value", ""))
                if not widget_tag(tag) or not event_name(field) or len(value) > MAX_WIDGET_BYTES:
                    return {"ok": False, "error": "a set names a widget's tag, a field (a word) and a JSON value"}
                ok = bool(mod.set_widget(h, tag, int(op.get("id", 0)), field, value))
                note(sid, s)
                s.wake()
                return {"ok": ok} if ok else {"ok": False, "error": f"no widget {tag}#{op.get('id')} on the screen, or the value isn't JSON"}
            if what == "event":
                d = json.loads(mod.event(h, n, int(op.get("second", 0)), str(op.get("text", "")), int(op.get("number", 0))))
            elif what == "gesture":
                d = json.loads(mod.gesture(h, n, int(op.get("kind", 3)), float(op.get("x", 0)), float(op.get("y", 0)), float(op.get("dx", 0)),
                                           float(op.get("dy", 0)), float(op.get("zoom", 1)), float(op.get("pressure", 0))))
            elif what == "key":
                d = json.loads(mod.key(h, n, str(op.get("name", "")), int(op.get("modifiers", 0))))
            else:
                return {"ok": False, "error": f"no op {what!r}"}
            if not d.get("ignored"):
                s.pending = merge(s.pending, d)
                s.nodes = json.loads(mod.view(h))
            note(sid, s)
            s.wake()
            return {"ok": not d.get("ignored")}

    if AGENT_SOCKET:
        import socketserver

        class LinkHandler(socketserver.StreamRequestHandler):
            def handle(self):
                for raw in self.rfile:
                    try:
                        op = json.loads(raw.decode("utf-8"))  # (a line that isn't UTF-8 is refused as one, as GTK's link does)
                        out = link_call(op) if isinstance(op, dict) else {"ok": False, "error": "a request is a JSON object"}
                    except UnicodeDecodeError:
                        out = {"ok": False, "error": "not UTF-8 JSON text"}
                    except Exception as ex:  # (a bad request is the agent's mistake: say so, keep the link)
                        out = {"ok": False, "error": f"{type(ex).__name__}: {ex}"}
                    self.wfile.write((json.dumps(out, ensure_ascii=False) + "\n").encode())
                    self.wfile.flush()

        Path(AGENT_SOCKET).unlink(missing_ok=True)
        old_mask = os.umask(0o177)  # (the socket is the user's alone: 0600)
        try:
            link = socketserver.ThreadingUnixStreamServer(AGENT_SOCKET, LinkHandler)
        finally:
            os.umask(old_mask)
        link.daemon_threads = True
        threading.Thread(target=link.serve_forever, daemon=True, name="mojoui-agent-link").start()
        print(f"mojoui web: agent link at {AGENT_SOCKET}", flush=True)

    @app.post("/resize/{sid}")
    def resize(sid: str, w: int = 0, h: int = 0):
        s = sessions.get(sid)
        if s is None or w <= 0 or h <= 0 or not hasattr(mod, "resize"):
            return ""
        with s.lock:
            if s.closed:
                return ""
            d = json.loads(mod.resize(s.handle, w, h))  # (not input: a page that resizes itself doesn't keep an idle tab alive)
            s.nodes = json.loads(mod.view(s.handle))
            return changes(s, sid, d)

    @app.post("/appearance/{sid}")
    def appearance(sid: str, dark: int = 0):
        s = sessions.get(sid)
        if s is None or not hasattr(mod, "appearance"):
            return ""
        with s.lock:
            if s.closed:
                return ""
            d = json.loads(mod.appearance(s.handle, dark))
            s.nodes = json.loads(mod.view(s.handle))
            return changes(s, sid, d)

    def file_folder(sid, kind="uploads"):
        """Where a page's files live where the app runs: uploads (FilePicker, a file drop) and downloads (FileSaver).
        Each folder names this server's process in `.owner`, so a later start can sweep what a crash left (sweep_files)."""
        folder = (uploads_base() / sid) if kind == "uploads" else (uploads_base().parent / kind / sid)  # (downloads, documents)
        folder.mkdir(parents=True, exist_ok=True)
        owner = folder / ".owner"
        if not owner.exists():
            owner.write_text(f"{os.getpid()} {owner_host()}")
        return folder

    def forget_files(sid):
        """A session ended: its uploads, downloads and documents go."""
        import shutil
        for folder in (uploads_base() / sid, uploads_base().parent / "downloads" / sid, uploads_base().parent / "documents" / sid):
            shutil.rmtree(folder, ignore_errors=True)

    def too_big(name, limit):
        """A file over the upload limit: nothing kept, and the page says so (D-1704: it used to be skipped in silence)."""
        print(f"UPLOAD: refused a file over OMXCODE_UPLOAD_MAX ({limit:,} bytes)", flush=True)
        return notice(f"{name} wasn't uploaded: it's larger than this server's limit ({size_words(limit)}).")

    def over_cap(name, cap):
        """Public mode: this visitor's uploads would pass OMXCODE_VISITOR_MAX: nothing kept, and the page says so."""
        print(f"UPLOAD: refused a file past the visitor's cap ({cap:,} bytes)", flush=True)
        return notice(f"{name} wasn't uploaded: your files here would pass {size_words(cap)}, the most one visitor keeps.")

    @app.post("/save/{sid}")
    def save(sid: str, n: int, v: int = -1):
        """A FileSaver tapped: on_save gets a path in this page's downloads folder (its suggested name, a plain file name);
        the app writes the file there in update(), then the answer tells the page to download it (DOWNLOAD_JS)."""
        s = sessions.get(sid)
        if s is None:
            return Main(P("This page expired: reload it.", cls="text caption"), id="mojoui-root", hx_swap_oob="true")
        with s.lock:
            if s.closed or v != s.shape or not 0 <= n < len(s.nodes):
                return ""
            node = s.nodes[n]
            if not (node["msg2"] and len(node["options"]) >= 3 and node["options"][1] == "save"):
                return ""
            name = Path(node["options"][2] or "").name
            if name in ("", ".", ".."):
                name = "download"
            path = file_folder(sid, "downloads") / name
            path.unlink(missing_ok=True)
            d = json.loads(mod.event(s.handle, n, 1, str(path), 0))
            if d.get("ignored"):
                return ""
            s.nodes = json.loads(mod.view(s.handle))
            out = changes(s, sid, d, n, str(path), 0)
            if not path.exists():  # (the app wrote nothing: no download)
                return out
            token = uuid.uuid4().hex
            s.downloads = getattr(s, "downloads", {})
            s.downloads[token] = path
            mark = Div(I(cls="mojoui-download", hidden=True, data_url=f"/download/{sid}/{token}", data_name=name), hx_swap_oob="beforeend:body")
            return (out if isinstance(out, tuple) else ((out,) if out != "" else ())) + (mark,)

    @app.get("/download/{sid}/{token}")
    def download(sid: str, token: str):
        """A file a FileSaver's app wrote, as an attachment under its suggested name."""
        from starlette.responses import FileResponse
        from starlette.background import BackgroundTask
        s = sessions.get(sid)
        path = getattr(s, "downloads", {}).pop(token, None) if s is not None else None
        if path is None or not Path(path).exists():
            return Response(status_code=404)
        # (once sent, it's gone: a download leaves nothing on the server, goal 62 M3)
        return FileResponse(path, filename=Path(path).name, background=BackgroundTask(lambda: Path(path).unlink(missing_ok=True)))

    @app.post("/dropfile/{sid}")
    async def dropfile(sid: str, req):
        """Files dropped from outside on a DropTarget with on_file, in one upload: each saved in a folder of its own (two
        files of one name don't overwrite), then on_file gets their paths one after another; the target is found again
        after each (its on_file message), since the first one's new screen may have renumbered it."""
        s = sessions.get(sid)
        if s is None:
            return ""
        form = await req.form()
        try:
            n, v = int(form.get("n", -1)), int(form.get("v", -1))
        except ValueError:
            return ""
        files = [f for f in form.getlist("file") if hasattr(f, "read")]
        if PUBLIC and len(files) > 20:  # (round 6: a drop is 20 files at most)
            return notice(f"A drop takes 20 files at most here, not {len(files)}: drop fewer at once.")
        with s.lock:
            if s.closed or v != s.shape or not 0 <= n < len(s.nodes) or s.nodes[n]["kind"] != DROP or not s.nodes[n]["msg2"]:
                return ""
            msg = s.nodes[n]["msg2"]
        limit = upload_limit()
        cap = visitor_limit()
        s.last_active = time.monotonic()
        paths, refused, dropped = [], [], 0
        for file in files:
            if s.closed:  # (evicted mid-upload: nothing more is written; D-1704)
                break
            name = safe_name(file.filename, "dropped")
            if (file.size or 0) > limit:
                refused.append(too_big(name, limit))
                continue
            if cap and s.upload_bytes + dropped + (file.size or 0) > cap:  # (this drop's earlier files count too: round 6)
                refused.append(over_cap(name, cap))
                continue
            try:
                folder = file_folder(sid) / uuid.uuid4().hex[:12]
                folder.mkdir()
                path, size = folder / name, 0
                with open(path, "wb") as out:
                    while chunk := await file.read(1 << 20):
                        size += len(chunk)
                        if size > limit:
                            break
                        out.write(chunk)
            except OSError:  # (the session's folder went while this was written: it was evicted)
                break
            if size > limit:
                shutil_rmtree(folder)
                refused.append(too_big(name, limit))
                continue
            if PUBLIC:
                import anyio
                why, kb = await anyio.to_thread.run_sync(check_upload, path, validator, limiter=checks())
                why = why or (take_table(s, path, kb) if kb else "")  # (a visitor's tables together: round 3)
                if why:
                    shutil_rmtree(folder)
                    refused.append(notice(f"{name} wasn't opened: {why}."))
                    continue
            paths.append(path)
            dropped += size
        outs = list(refused)
        with s.lock:
            if s.closed:  # (evicted while the files were written: what this request wrote goes too)
                forget_files(sid)
                return ""
            for path in paths:
                if s.closed:
                    break
                if not (0 <= n < len(s.nodes) and s.nodes[n]["kind"] == DROP and s.nodes[n]["msg2"] == msg):
                    n = next((k for k, node in enumerate(s.nodes) if node["kind"] == DROP and node["msg2"] == msg), -1)
                    if n < 0:
                        break
                s.upload_bytes += path.stat().st_size if path.exists() else 0
                d = json.loads(mod.event(s.handle, n, 1, str(path), 0))
                if d.get("ignored"):
                    continue
                s.nodes = json.loads(mod.view(s.handle))
                out = changes(s, sid, d, n, str(path), 0)
                outs.extend(out if isinstance(out, tuple) else ((out,) if out != "" else ()))
        return tuple(outs) if outs else ""

    @app.post("/upload/{sid}")
    async def upload(sid: str, n: int, file: UploadFile, v: int = -1):
        """A FilePicker's file: saved where the app runs (~/.cache/omxcode/uploads), then on_pick gets its path."""
        s = sessions.get(sid)
        if s is None:
            return Main(P("This page expired: reload it.", cls="text caption"), id="mojoui-root", hx_swap_oob="true")
        with s.lock:  # (from this screen, to a picker: checked before anything is written)
            if s.closed or v != s.shape or not 0 <= n < len(s.nodes) or not s.nodes[n]["msg2"]:
                return ""
            if PUBLIC and s.nodes[n]["kind"] != BUTTON:  # (public: only a FilePicker takes an upload)
                return ""
            s.last_active = time.monotonic()
        # each page its own folder; only a plain file name (no folders, no "..")
        name = safe_name(file.filename, "upload")
        limit = upload_limit()
        if (file.size or 0) > limit:
            return too_big(name, limit)
        cap = visitor_limit()
        if cap:  # (this visitor's uploads together: what's kept, plus this one, within the cap)
            limit = min(limit, cap - s.upload_bytes)
            if limit <= 0 or (file.size or 0) > limit:
                return over_cap(name, cap)
        size = 0
        try:
            # (public: its own folder, so a same-name upload can't overwrite or delete an accepted one and its check reads
            # exactly what the app opens; a desktop's own uploads keep their place, as tests/test_web_files.py reads it)
            folder = file_folder(sid) / uuid.uuid4().hex[:12] if PUBLIC else file_folder(sid)
            folder.mkdir(exist_ok=True)
            path = folder / name
            with open(path, "wb") as out:
                while chunk := await file.read(1 << 20):
                    size += len(chunk)
                    if size > limit:
                        break
                    out.write(chunk)
        except OSError:  # (the session's folder went while this was written: it was evicted)
            forget_files(sid)
            return ""
        if size > limit:
            shutil_rmtree(folder) if PUBLIC else path.unlink(missing_ok=True)
            return over_cap(name, cap) if cap and limit < upload_limit() else too_big(name, limit)
        if PUBLIC:
            import anyio
            why, kb = await anyio.to_thread.run_sync(check_upload, path, validator, limiter=checks())
            why = why or (take_table(s, path, kb) if kb else "")  # (a visitor's tables together: round 3)
            if why:
                shutil_rmtree(folder)
                return notice(f"{name} wasn't opened: {why}.")
        with s.lock:
            if s.closed:  # (evicted while it was written: its app is closed, D-1704; the file goes too)
                forget_files(sid)
                return ""
            if v != s.shape or not 0 <= n < len(s.nodes) or not s.nodes[n]["msg2"]:
                path.unlink(missing_ok=True)
                return ""
            s.upload_bytes += path.stat().st_size if path.exists() else 0
            d = json.loads(mod.event(s.handle, n, 1, str(path), 0))
            if d.get("ignored"):
                return ""
            s.nodes = json.loads(mod.view(s.handle))
            return changes(s, sid, d, n, str(path), 0)

    @app.get("/frame/{sid}/{n}")
    def frame(sid: str, n: int, w: int = 0, h: int = 0, scale: float = 1, v: int = -1, tick: int = 0, still: int = 0, have: str = "", cid: str = ""):
        """One canvas frame as a JPEG, painted by the app at w × h pixels. With tick=1 (the
        canvas asked for frames), a frame event goes to the app first. Changes to the rest of
        the screen wait in the session until the page asks for /pending. No frame: 204 with X-Mojoui-Retry (the screen
        changed under it: ask again once the page has caught up) or X-Mojoui-Gone (the tab or the canvas is gone), never a
        4xx, which every browser logs as a console error (goal 34 M2 reads the console)."""
        if PUBLIC:  # (pixels the page asks for: at most a big screen's, not 4096², goal 62's audit)
            w, h = min(max(w, 0), 3840), min(max(h, 0), 2400)
        sess = sessions.get(sid)
        if sess is None:  # a gone session (a closed or expired tab, a restarted server) reads as 204 + X-Mojoui-Gone, no
            # longer 404 (D-607): the page's poller stops on the header as it did on 404, and the browser logs no error
            return Response(status_code=204, headers={"X-Mojoui-Gone": "1"})
        sess.touched = True
        with sess.lock:
            if sess.closed:
                return Response(status_code=204, headers={"X-Mojoui-Gone": "1"})
            if v != sess.shape or not 0 <= n < len(sess.nodes) or sess.nodes[n]["kind"] != CANVAS:
                return Response(status_code=204, headers={"X-Mojoui-Retry": "1"})  # the screen changed under it: the page will catch up
            now = time.perf_counter()
            if sess.pending and sess.pending.get("rebuild"):  # the page must catch up first; don't run the app on
                return Response(status_code=204, headers={"X-Mojoui-Retry": "1", "X-Mojoui-Pending": "1"})
            if tick and sess.nodes[n]["msg2"]:
                last = sess.frame_time.get(n)
                us = int((now - last) * 1e6) if last else 16667
                sess.frame_time[n] = now
                fd = json.loads(mod.frame(sess.handle, n, us))
                sess.pending = merge(sess.pending, fd)
                if fd.get("rebuild") or fd.get("patches"):  # (the screen's JSON again only when it changed: twice a picture
                    sess.nodes = json.loads(mod.view(sess.handle))  # was most of a picture's time under Python's lock)
                note(sid, sess)
                if sess.pending.get("rebuild") or sess.nodes[n]["kind"] != CANVAS:
                    return Response(status_code=204, headers={"X-Mojoui-Retry": "1", "X-Mojoui-Pending": "1"})
            else:
                sess.frame_time.pop(n, None)
            r = json.loads(mod.draw(sess.handle, n, w, h, scale, still))
            sess.pending = merge(sess.pending, r["diff"])
            if r["diff"].get("rebuild") or r["diff"].get("patches"):
                sess.nodes = json.loads(mod.view(sess.handle))
            rgba = ctypes.string_at(r["address"], r["width"] * r["height"] * 4)
            pending = bool(sess.pending and (sess.pending.get("rebuild") or sess.pending.get("patches"))) or bool(sess.commands)
        # The picture the page already shows (`have`, the digest it was sent with) isn't sent again: a video drawn at the
        # display's rate changes 15 times a second, and each unchanged picture was encoded and sent anyway (goal 62 M4)
        pic = f"{zlib.crc32(rgba):08x}{r['width']:x}{r['height']:x}"
        # (a playing canvas keeps a few requests out: one already sent this picture to this canvas element, `cid`)
        key = (n, cid[:16])
        with sess.lock:
            sent = getattr(sess, "sent_pics", None)
            if sent is None:
                sent = sess.sent_pics = OrderedDict()
            was = sent.get(key)
        # (sent to this canvas element under 2 s ago: still on its way; after that the page's own `have` decides, so a
        # picture lost on the way is sent again, goal 62's review)
        if (have and have == pic) or (cid and was is not None and was[0] == pic and time.monotonic() - was[1] < 2.0):
            return Response(status_code=204, headers={"Cache-Control": "no-store", "X-Mojoui-Same": "1", "X-Mojoui-Pending": "1" if pending else "0",
                                                      "X-Mojoui-Again": "1" if r.get("again") else "0"})
        if cid:
            with sess.lock:
                sent[key] = (pic, time.monotonic())
                sent.move_to_end(key)
                while len(sent) > 64:
                    sent.popitem(last=False)
        out = io.BytesIO()
        picture = Image.frombuffer("RGBA", (r["width"], r["height"]), rgba, "raw", "RGBA", 0, 1)
        clear = sess.nodes[n]["kind"] == CANVAS and sess.nodes[n]["size"] == 2 if 0 <= n < len(sess.nodes) else False
        if clear:  # (.passthrough(): what it leaves unpainted shows the page beneath: PNG with its alpha, even animating)
            tick = 0
        else:
            picture = picture.convert("RGB")
        if tick:  # animating: small, fast JPEG frames
            picture.save(out, "JPEG", quality=JPEG_QUALITY)
        else:  # a still picture (charts, text): exact PNG
            picture.save(out, "PNG", compress_level=1)
        return Response(out.getvalue(), media_type="image/jpeg" if tick else "image/png",
                        headers={"Cache-Control": "no-store", "X-Mojoui-Pending": "1" if pending else "0", "X-Mojoui-Again": "1" if r.get("again") else "0",
                                 "X-Mojoui-Draw-Ms": f"{(time.perf_counter() - now) * 1000:.2f}", "X-Mojoui-Pic": pic})

    @app.get("/push/{sid}")
    async def push(sid: str, req, v: int = -1, c: str = "", still: int = 0):
        """Pictures pushed to a page's playing canvases (goal 62 M4): one streamed answer carries the new pictures of every
        canvas named in `c` ("n:w:h:scale:cid,…", at most 8), each painted on the server's clock (PUSH_HZ times a second;
        a picture the canvas already shows isn't sent), so a slow link pays no round trip a picture. Per item: 4 bytes of
        header length, the header (JSON: n, status, the X-Mojoui-* headers), 4 bytes of body length, the body. It ends when
        none of its canvases plays any more, the screen changed under it (Retry: the page opens a new one), the tab is
        gone, or the page goes; a stream lasts PUSH_MAX_S at most (the page opens another)."""
        import anyio
        from starlette.responses import StreamingResponse
        try:
            subs = []
            for part in [x for x in c.split(",") if x][:8]:
                n_, w_, h_, sc_, cid_ = part.split(":")  # (a pushed picture is at most 2560×1600: a big screen's canvas)
                subs.append((int(n_), min(max(int(w_), 1), 2560), min(max(int(h_), 1), 1600), float(sc_), cid_[:16]))
        except ValueError:
            return Response(status_code=400)
        s = sessions.get(sid)
        if s is None or s.closed or not subs:
            return Response(status_code=204, headers={"X-Mojoui-Gone": "1"})
        s.touched = True
        s.push_gen = getattr(s, "push_gen", 0) + 1  # (one stream a tab: a newer one ends this one at its next round)
        gen = s.push_gen

        def item(head, body=b""):
            hb = json.dumps(head).encode()
            return struct.pack(">I", len(hb)) + hb + struct.pack(">I", len(body)) + body

        def one_round(have, live):
            """Every live canvas once: (items to send, whether the stream ends)."""
            out, end = [], False
            for n_, w_, h_, sc_, cid_ in subs:
                if n_ not in live:
                    continue
                if not s.lock.acquire(timeout=0.2):  # (the tab is busy: this canvas waits for the next round, no worker held)
                    continue
                try:
                    node = s.nodes[n_] if 0 <= n_ < len(s.nodes) else None
                finally:
                    s.lock.release()
                if node is None or node["kind"] != CANVAS or not node["msg2"]:  # (it stopped playing: the page pulls its last picture)
                    live.discard(n_)
                    out.append(item({"n": n_, "status": 0, "stop": 1}))
                    continue
                r = frame(sid, n_, w_, h_, sc_, v, 1, 1 if still else 0, have.get(n_, ""), cid_)  # (reduced motion carried, as pulls do)
                head = {"n": n_, "status": r.status_code, **{k.lower(): val for k, val in r.headers.items() if k.lower().startswith("x-mojoui-")}}
                if r.status_code == 200:
                    have[n_] = r.headers.get("X-Mojoui-Pic", "")
                    out.append(item(head, r.body or b""))
                elif head.get("x-mojoui-gone") == "1" or head.get("x-mojoui-retry") == "1":
                    out.append(item(head))
                    end = True
                    break
                elif head.get("x-mojoui-pending") == "1":
                    out.append(item({"n": n_, "status": 204, "x-mojoui-pending": "1"}))
            return out, end

        async def stream():
            have, live = {}, {sub[0] for sub in subs}
            t_end = time.monotonic() + PUSH_MAX_S
            while live and time.monotonic() < t_end:
                if await req.is_disconnected() or getattr(s, "push_gen", gen) != gen or s.closed:
                    return
                t0 = time.monotonic()
                out, end = await anyio.to_thread.run_sync(lambda: one_round(have, live))
                for x in out:
                    yield x
                if end:
                    return
                await anyio.sleep(max(0.0, 1.0 / PUSH_HZ - (time.monotonic() - t0)))
            yield item({"status": 0, "end": 1})

        return StreamingResponse(stream(), media_type="application/octet-stream", headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})

    @app.get("/wait/{sid}")
    async def wait(sid: str):
        """Returns "1" once changes the page didn't ask for are pending (an effect's answer, a timer, a background job
        that ended, an agent's step; or the page must start or stop waiting), "gone" for a closed tab, "0" after
        MOJOUI_WAIT_S without any (0, the default: it waits as long as the tab lives, so an idle page fetches nothing;
        a platform whose proxy cuts idle requests sets it under that). Async: an open wait holds no worker thread. A
        tab holds at most 4 (a fifth ends the oldest with "0")."""
        import asyncio
        s = sessions.get(sid)
        if s is None or s.closed:
            return "gone" + (" " + ended[sid] if ended.get(sid) else "")
        s.touched = True
        if has_changes(s) or s.busy != s.busy_sent:
            return "1"
        ev = asyncio.Event()
        entry = (asyncio.get_running_loop(), ev)
        with s.waiters_lock:
            while len(s.waiters) >= 4:
                old_loop, old_ev = s.waiters.pop()
                old_loop.call_soon_threadsafe(old_ev.set)
            s.waiters.add(entry)
        try:
            if has_changes(s) or s.busy != s.busy_sent:  # (it came while we registered)
                return "1"
            await asyncio.wait_for(ev.wait(), WAIT_S or None)
            if s.closed:
                return "gone" + (" " + s.gone_reason if s.gone_reason else "")
            return "1" if has_changes(s) or s.busy != s.busy_sent else "0"
        except asyncio.TimeoutError:
            return "0"
        except asyncio.CancelledError:  # (the server is stopping: the page will find it gone, or back)
            return "0"
        finally:
            with s.waiters_lock:
                s.waiters.discard(entry)

    @app.post("/pending/{sid}")
    def pending(sid: str, v: int = -1):
        """Screen changes made while drawing canvases (e.g. a frame-time label)."""
        s = sessions.get(sid)
        if s is None:
            return ""
        with s.lock:
            if s.closed:
                return ""
            if s.pending is None:  # (nothing changed, but the page may have to stop waiting, run a widget's command, or download)
                out = (busy_mark(s, oob=True),) if s.busy != s.busy_sent else ()
                out += (cmds_mark(s, oob=True),) if s.commands else ()
                out += delivery_marks(s) if s.deliveries else ()
                return out or ""
            d, s.pending = s.pending, None
            return changes(s, sid, d)

    return app


def deadline_protocol():
    """uvicorn's h11 protocol with the public copy's connection rules (round 5: 520 idle or slow sockets made the site
    answer 503): a request's headers arrive within HEADER_S, from the connection's start or, after a response, once its
    next bytes come; with no proxy in front (MOJOUI_BEHIND_PROXY unset), one peer holds PER_PEER connections at most."""
    from uvicorn.protocols.http.h11_impl import H11Protocol
    peers = {}
    behind = BEHIND_PROXY

    class Deadlines(H11Protocol):
        def connection_made(self, transport):
            peer = (transport.get_extra_info("peername") or ("", 0))[0]
            self._peer = None if behind else peer
            if self._peer is not None:
                peers[peer] = peers.get(peer, 0) + 1
                if peers[peer] > PER_PEER:
                    transport.close()
            super().connection_made(transport)
            self._arm(first=True)

        def connection_lost(self, exc):
            if self._peer is not None:
                peers[self._peer] -= 1
                if peers[self._peer] <= 0:
                    del peers[self._peer]
                self._peer = None
            super().connection_lost(exc)

        def _arm(self, first=False):
            self._seen, self._got, self._first = self.cycle, False, first
            self.loop.call_later(HEADER_S, self._late, self.cycle)

        def data_received(self, data):
            self._got = True
            super().data_received(data)

        def _late(self, seen):
            if self.transport.is_closing() or self.cycle is not seen:
                return  # (a request came: its own body rules apply)
            if self._first or self._got:  # (nothing whole in time: a slow or idle socket; plain idle after a response is keep-alive's)
                self.transport.close()

        def on_response_complete(self):
            super().on_response_complete()
            self._arm()
    return Deadlines


if __name__ == "__main__":
    module_dir = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("MOJOUI_MODULE", "build/hello/web")
    port = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("PORT", "5001"))  # (a platform's port: $PORT)
    host = os.environ.get("HOST", "127.0.0.1")  # (a container listens on 0.0.0.0: HOST)
    if PUBLIC_SETTING not in ("", "0", "1"):
        raise SystemExit(f"mojoui web: MOJOUI_PUBLIC is 1 (the public copy) or 0, not {PUBLIC_SETTING!r}: set one")
    if not PUBLIC and not loopback(host):  # (beyond this machine only with the public copy's rules: goal 62 round 3)
        raise SystemExit(f"mojoui web: HOST={host} would serve this app beyond this machine without the public copy's rules: "
                         "set MOJOUI_PUBLIC=1 (scripts/web-start does), or HOST=127.0.0.1")
    import uvicorn

    print(f"mojoui web: http://{host}:{port}/", flush=True)
    # timeout_graceful_shutdown: a page's /wait is held while the tab lives; a stop (Ctrl+C, a platform's redeploy)
    # waits at most 3 s for answers in flight instead of for every tab to close
    uvicorn.run(make_app(module_dir), host=host, port=port, log_level="warning", timeout_graceful_shutdown=3, proxy_headers=False,
                limit_concurrency=2048 if PUBLIC else None, timeout_keep_alive=20 if PUBLIC else 75,
                http=deadline_protocol() if PUBLIC else "auto")  # (round 5: idle and slow connections are dropped, not counted)
