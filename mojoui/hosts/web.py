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
import hashlib
import os
import importlib
import io
import json
import re
import time
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
SET_TEXT, SET_MSG, SET_VALUE, SET_IMAGE, SET_FRAMES, SET_PLACE, SET_SIZE, SET_TIP = 1, 2, 3, 4, 5, 6, 7, 8
KEY = 7  # a canvas gesture: a key pressed while it had focus (text = the key, dx = modifiers)
SECONDARY = 8  # a right click on a canvas (x, y): where a context menu opens
CHECKED, DISABLED, DANGER = 1, 2, 4  # menu item flags (mojoui/menus.mojo)
AGENT_SOCKET = os.environ.get("MOJOUI_AGENT_SOCKET", "")  # an agent host may attach here (docs/agent.md: the agent link)
# scripts/dev.sh's server (goal 34b M1c): widgets reload when their sources change, source maps are served; only
# 127.0.0.1 may ask, /dev/reload only with the token. Refused unless the app's build is a debug build (D-678), and never
# to be set on a deployed host (docs/js.md).
DEV = os.environ.get("MOJOUI_DEV") == "1"
DEV_TOKEN = os.environ.get("MOJOUI_DEV_TOKEN", "")
EVENT_DELAY = float(os.environ.get("MOJOUI_EVENT_DELAY_MS", "0")) / 1000  # checks only: answers events this much later
JPEG_QUALITY = 85
MAX_SESSIONS = 200  # oldest tabs are closed beyond this
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
        t.dataset.timer = setTimeout(() => { if (document.body.contains(t) && t.dataset.kind === 'toast') menus.dismiss(t); }, ms);
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
    htmx.ajax('POST', `/e/${t.dataset.sid}`, { values: { n: Number(t.dataset.node), text: e.dataTransfer.getData('text/plain'), v: v ? v.value : -1 }, swap: 'none', source: lane('drop') });
  });
  // Scroll(pinned): stays at its end as its content grows, unless scrolled up to read (back at the end, it follows again)
  const pin = () => document.querySelectorAll('.scroll[data-pin="1"]').forEach(e => { if (e.dataset.follow !== '0') e.scrollTop = e.scrollHeight; });
  document.addEventListener('scroll', e => { const t = e.target;
    if (t && t.dataset && t.dataset.pin === '1') t.dataset.follow = t.scrollHeight - t.scrollTop - t.clientHeight <= 4 ? '1' : '0'; }, true);
  document.addEventListener('htmx:afterSettle', pin);
  // A role whose width is its content's in whole pixels (Surface.whole_width: the look writes --mojoui-whole-width), as
  // a script that sizes a pill from scrollWidth does (omxqua's Beacon): found by the rules that carry the marker
  const whole = () => { const sel = [];
    for (const sh of document.styleSheets) { let rules; try { rules = sh.cssRules; } catch (e) { continue; }
      for (const r of rules) if (r.style && r.style.getPropertyValue('--mojoui-whole-width')) sel.push(r.selectorText); }
    if (sel.length) document.querySelectorAll(sel.join(', ')).forEach(e => { e.style.width = ''; e.style.width = e.scrollWidth + 'px'; }); };
  document.addEventListener('htmx:afterSettle', whole);
  document.addEventListener('htmx:oobAfterSwap', () => setTimeout(whole, 0));
  addEventListener('load', whole);
  document.addEventListener('htmx:oobAfterSwap', () => setTimeout(pin, 0));
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
  document.addEventListener('htmx:oobAfterSwap', () => setTimeout(syncRoute, 0));
  document.addEventListener('htmx:oobAfterSwap', () => setTimeout(copyAsked, 0));
  document.addEventListener('htmx:oobAfterSwap', () => setTimeout(menus.place, 0));
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
// Effects (goal 33): while the app has HTTP requests out or timers running (#mojoui-busy), the page waits on /wait for
// the server's clock thread to hand their answers to update(), then fetches what changed (/pending), as frames do.
(() => {
  let running = false;
  const busy = () => { const b = document.getElementById('mojoui-busy'); return !!b && b.dataset.busy === '1'; };
  async function loop() {
    if (running) return;
    running = true;
    try {
      while (busy()) {
        const root = document.getElementById('mojoui-root');
        let said = '0';
        try { said = await (await fetch(`/wait/${root.dataset.sid}`, { cache: 'no-store' })).text(); }
        catch (e) { await new Promise(ok => setTimeout(ok, 500)); continue; }
        if (said === 'gone') break;
        if (said === '1') await htmx.ajax('POST', `/pending/${root.dataset.sid}`, { values: { v: document.getElementById('mojoui-v').value }, swap: 'none', source: window.mojouiLane('effects') });
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
    else { p.style.left = d.x + 'px'; p.style.top = d.y + 'px'; p.dataset.x = d.x; p.dataset.y = d.y; }
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
  const scan = () => { document.querySelectorAll('[data-kind=board]').forEach(attach); document.querySelectorAll('[data-kind=place]').forEach(place); };
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
  const PAN = 1, ZOOM = 2, TAP = 3, PRESS = 4, RELEASE = 5, DOUBLE = 6, KEY = 7, SECONDARY = 8;
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
  function attach(div) {
    if (div.mojoui) return;
    const cv = div.querySelector('canvas'), g = cv.getContext('2d');
    const n = Number(div.dataset.node), sid = div.dataset.sid;
    const st = div.mojoui = { want: true, busy: false, drawn: -1, skin: '', count: 0, times: [], queue: [], sending: false, updating: false };
    const meta = () => document.getElementById('n' + n + '-meta');
    const playing = () => { const m = meta(); return !!m && m.dataset.frames !== '0'; };
    async function pump() {
      if (st.busy) return;
      st.busy = true;
      try {
        while (div.isConnected && (st.want || playing())) {
          const tick = playing() ? 1 : 0, m = meta();
          if (tick) await new Promise(ok => requestAnimationFrame(ok));  // at most one frame per display refresh
          const version = m ? m.dataset.version : '', skin = skinNow();
          st.want = false;
          const r = div.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
          const w = Math.max(1, Math.round(r.width * dpr)), h = Math.max(1, Math.round(r.height * dpr));
          const still = matchMedia('(prefers-reduced-motion: reduce)').matches ? 1 : 0;  // (less motion: animations jump to their end)
          const res = await fetch(`/frame/${sid}/${n}?w=${w}&h=${h}&scale=${dpr}&v=${shape()}&tick=${tick}&still=${still}`);
          if (res.status !== 200) {
            if (res.headers.get('X-Mojoui-Pending') === '1') update();  // e.g. a frame changed the screen's shape
            if (res.headers.get('X-Mojoui-Retry') === '1') await new Promise(ok => setTimeout(ok, 50));
            if (res.headers.get('X-Mojoui-Gone') === '1' || res.status === 404) return;
            if (res.status !== 204) await new Promise(ok => setTimeout(ok, 50));  // (anything else: a short wait, then again)
            continue;
          }
          const img = await createImageBitmap(await res.blob());
          if (cv.width !== img.width || cv.height !== img.height) { cv.width = img.width; cv.height = img.height; }
          g.drawImage(img, 0, 0);
          st.drawn = version; st.skin = skin; st.count++; st.times.push(performance.now());
          if (st.times.length > 1200) st.times.splice(0, 600);  // (frame times, for tests; bounded)
          div.dataset.frame = `${st.count} ${cv.width}x${cv.height} ${r.width.toFixed(0)}x${r.height.toFixed(0)} ${dpr}`;
          if (res.headers.get('X-Mojoui-Pending') === '1') update();
          if ((meta() && meta().dataset.version !== String(st.drawn)) || st.skin !== skinNow()) st.want = true;
          if (meta() && (meta().dataset.tip || '') !== (div.dataset.tip || '')) { div.dataset.tip = meta().dataset.tip || ''; div.title = div.dataset.tip; }  // (SET_TIP: a drawn view's words)
          if (res.headers.get('X-Mojoui-Again') === '1') { st.want = true; await new Promise(ok => requestAnimationFrame(ok)); }  // mid-animation (a gliding ring): the next frame
        }
      } finally { st.busy = false; }
    }
    // The rest of the screen (labels the app changed while drawing): fetched alongside the
    // frames, at most ~10 times a second, and always once more after the last change.
    function update() {
      if (st.updating) { st.again = true; return; }
      const wait = 100 - (performance.now() - (st.updated || 0));
      if (wait > 0) { st.again = true; if (!st.timer) st.timer = setTimeout(() => { st.timer = 0; update(); }, wait); return; }
      st.updating = true; st.again = false; st.updated = performance.now();
      htmx.ajax('POST', `/pending/${sid}`, { values: { v: shape() }, swap: 'none', source: window.mojouiLane('canvas-' + n) })
        .finally(() => { st.updating = false; if (st.again) update(); });
    }
    st.pump = pump;
    st.sendKey = (k, m) => send(KEY, 0, 0, m, 0, 1, k);
    function send(kind, x, y, dx, dy, zoom, text = '') {
      const q = events.queue, last = q[q.length - 1], same = last && last.n === n && last.number === kind;
      if (same && kind === PAN) { last.dx += dx; last.dy += dy; last.x = x; last.y = y; }
      else if (same && kind === ZOOM) { last.zoom *= zoom; }
      else q.push({ n, sid, number: kind, x, y, dx, dy, zoom, text });
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
    cv.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;  // a right click opens a context menu (contextmenu), it doesn't press
      if (keys) cv.focus({ preventScroll: true });
      cv.setPointerCapture(e.pointerId); pointers.set(e.pointerId, at(e));
      if (pointers.size === 1) { moved = false; const [x, y] = at(e); send(PRESS, x, y, mods(e), 0, 1); window.mojouiDrag = { n, id: e.pointerId, x, y, moved: false }; }  // where a drag (or tap) starts (dx: Shift, Ctrl, Alt held)
      if (pointers.size === 2) spread = distance();
    });
    cv.addEventListener('pointermove', e => {
      if (!pointers.has(e.pointerId)) return;
      const [x, y] = at(e), [px, py] = pointers.get(e.pointerId);
      pointers.set(e.pointerId, [x, y]);
      if (pointers.size === 1) {
        e.mojouiHandled = true;
        if (Math.abs(x - px) + Math.abs(y - py) > 0) { if (Math.abs(x - px) + Math.abs(y - py) > 3) moved = true; send(PAN, x, y, x - px, y - py, 1); }
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
      else if (pointers.size === 0 && moved) send(RELEASE, x, y, 0, 0, 1);  // a drag ended
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
      const [x, y] = at(e), dy = e.deltaMode === 1 ? e.deltaY * 40 : e.deltaY;
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
    ("X-Frame-Options", "SAMEORIGIN"), ("Cross-Origin-Opener-Policy", "same-origin"))]
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
    return I(hidden=True, id=f"n{i}-place", data_kind="place", data_x=str(n["x"]), data_y=str(n["y"]))


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
    if n.get("tip"):
        el.attrs["title"] = n["tip"]
        el.attrs["data-tip"] = n["tip"]
    return el


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
        field = Input(type="text", name="text", value=n["text"], placeholder=n["hint"], data_kind="field",
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
                            data_x=str(ch["x"]), data_y=str(ch["y"]), data_w=str(ch["w"]), data_h=str(ch["h"]),
                            style=f"left:{ch['x']}px;top:{ch['y']}px;width:{ch['w']}px;height:{ch['h']}px"))
        board = Div(*kids, place_mark(s, i), cls="board", id=f"{nid}-board", data_kind="board", data_node=str(i), data_sid=sid,
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
                   data_sid=sid, style="gap:0px;align-items:stretch")
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
                   data_keys="1" if n["size"] == 1 else None, style=own or None)
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
    return I(id=f"n{i}-meta", hidden=True, data_version=str(n["value"]), data_frames=str(n["msg2"]), data_tip=n.get("tip", ""))


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


def make_app(module_dir):
    if DEV and not debug_build(module_dir):  # (the dev server's endpoints never run on a release build, D-678)
        raise SystemExit(f"mojoui web: MOJOUI_DEV=1 needs a debug build ({module_dir} is a release build: "
                         "MOJOUI_DEBUG=1 scripts/build.sh <app> web, or scripts/dev.sh <app>); never set it on a deployed host")
    sys.path.insert(0, str(Path(module_dir).resolve()))
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
    sessions = OrderedDict()  # sid → Session, oldest first
    sessions_lock = threading.Lock()

    clock = threading.Condition()
    due = {}  # sid → (monotonic time its effects are due, its Session)

    def note(sid, s):
        """After any call that ran update() (s.lock held): when this tab's effects (HTTP replies, timer ticks) are due
        next (Runtime.wake_in), for the clock thread."""
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
        return bool(s.pending and (s.pending.get("rebuild") or s.pending.get("patches"))) or bool(s.commands)

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

    @app.get("/")
    def index(req):
        sid = uuid.uuid4().hex  # one app session per page load (tab)
        s = Session(mod, shared=bool(loads))
        s.origin = page_origin(req.url.scheme, req.url.netloc, {k.lower(): v for k, v in req.headers.items()})
        with sessions_lock:
            sessions[sid] = s
            while len(sessions) > MAX_SESSIONS:
                old_sid, old = sessions.popitem(last=False)
                with old.lock:
                    old.closed = True
                    mod.close(old.handle)
                import shutil  # (its uploads go with it)
                shutil.rmtree(Path(os.environ.get("OMXCODE_UPLOADS", os.environ.get("OMXAPP_UPLOADS", Path.home() / ".cache" / "omxcode" / "uploads"))) / old_sid, ignore_errors=True)
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
              x: float = 0, y: float = 0, dx: float = 0, dy: float = 0, zoom: float = 1, route: int = 0):
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
            if source["kind"] == TOGGLE:
                number = 1 if on else 0
            if source["kind"] == CANVAS and number == KEY:
                d = json.loads(mod.key(s.handle, n, text, int(dx)))
            elif source["kind"] == FIELD and second == 2:  # Escape (on_cancel)
                d = json.loads(mod.cancel(s.handle, n, text))
            elif source["kind"] in (CANVAS, BOARD):
                d = json.loads(mod.gesture(s.handle, n, number, x, y, dx, dy, zoom))
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

    jslog_counts = {}

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
                                           float(op.get("dy", 0)), float(op.get("zoom", 1))))
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
            d = json.loads(mod.resize(s.handle, w, h))
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

    @app.post("/upload/{sid}")
    async def upload(sid: str, n: int, file: UploadFile, v: int = -1):
        """A FilePicker's file: saved where the app runs (~/.cache/omxcode/uploads), then on_pick gets its path."""
        s = sessions.get(sid)
        if s is None:
            return Main(P("This page expired: reload it.", cls="text caption"), id="mojoui-root", hx_swap_oob="true")
        with s.lock:  # (from this screen, to a picker: checked before anything is written)
            if v != s.shape or not 0 <= n < len(s.nodes) or not s.nodes[n]["msg2"]:
                return ""
        # each page its own folder; only a plain file name (no folders, no "..")
        folder = Path(os.environ.get("OMXCODE_UPLOADS", os.environ.get("OMXAPP_UPLOADS", Path.home() / ".cache" / "omxcode" / "uploads"))) / sid
        folder.mkdir(parents=True, exist_ok=True)
        name = Path(file.filename or "").name
        if name in ("", ".", ".."):
            name = "upload"
        path = folder / name
        limit = int(os.environ.get("OMXCODE_UPLOAD_MAX", os.environ.get("OMXAPP_UPLOAD_MAX", str(32 << 30))))  # (32 GB by default: a 100M-row CSV is ~10 GB)
        size = 0
        with open(path, "wb") as out:
            while chunk := await file.read(1 << 20):
                size += len(chunk)
                if size > limit:
                    out.close()
                    path.unlink(missing_ok=True)
                    return ""
                out.write(chunk)
        with s.lock:
            if v != s.shape or not 0 <= n < len(s.nodes) or not s.nodes[n]["msg2"]:
                path.unlink(missing_ok=True)
                return ""
            d = json.loads(mod.event(s.handle, n, 1, str(path), 0))
            if d.get("ignored"):
                return ""
            s.nodes = json.loads(mod.view(s.handle))
            return changes(s, sid, d, n, str(path), 0)

    @app.get("/frame/{sid}/{n}")
    def frame(sid: str, n: int, w: int = 0, h: int = 0, scale: float = 1, v: int = -1, tick: int = 0, still: int = 0):
        """One canvas frame as a JPEG, painted by the app at w × h pixels. With tick=1 (the
        canvas asked for frames), a frame event goes to the app first. Changes to the rest of
        the screen wait in the session until the page asks for /pending. No frame: 204 with X-Mojoui-Retry (the screen
        changed under it: ask again once the page has caught up) or X-Mojoui-Gone (the tab or the canvas is gone), never a
        4xx, which every browser logs as a console error (goal 34 M2 reads the console)."""
        sess = sessions.get(sid)
        if sess is None:  # a gone session (a closed or expired tab, a restarted server) reads as 204 + X-Mojoui-Gone, no
            # longer 404 (D-607): the page's poller stops on the header as it did on 404, and the browser logs no error
            return Response(status_code=204, headers={"X-Mojoui-Gone": "1"})
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
                sess.pending = merge(sess.pending, json.loads(mod.frame(sess.handle, n, us)))
                sess.nodes = json.loads(mod.view(sess.handle))
                note(sid, sess)
                if sess.pending.get("rebuild") or sess.nodes[n]["kind"] != CANVAS:
                    return Response(status_code=204, headers={"X-Mojoui-Retry": "1", "X-Mojoui-Pending": "1"})
            else:
                sess.frame_time.pop(n, None)
            r = json.loads(mod.draw(sess.handle, n, w, h, scale, still))
            sess.pending = merge(sess.pending, r["diff"])
            sess.nodes = json.loads(mod.view(sess.handle))
            rgba = ctypes.string_at(r["address"], r["width"] * r["height"] * 4)
            pending = bool(sess.pending and (sess.pending.get("rebuild") or sess.pending.get("patches"))) or bool(sess.commands)
        out = io.BytesIO()
        picture = Image.frombuffer("RGBA", (r["width"], r["height"]), rgba, "raw", "RGBA", 0, 1).convert("RGB")
        if tick:  # animating: small, fast JPEG frames
            picture.save(out, "JPEG", quality=JPEG_QUALITY)
        else:  # a still picture (charts, text): exact PNG
            picture.save(out, "PNG", compress_level=1)
        return Response(out.getvalue(), media_type="image/jpeg" if tick else "image/png",
                        headers={"Cache-Control": "no-store", "X-Mojoui-Pending": "1" if pending else "0", "X-Mojoui-Again": "1" if r.get("again") else "0",
                                 "X-Mojoui-Draw-Ms": f"{(time.perf_counter() - now) * 1000:.2f}"})

    @app.get("/wait/{sid}")
    async def wait(sid: str):
        """Returns "1" once changes made by the tab's effects are pending (or the page must start or stop waiting),
        "0" after 20 s without any, "gone" for a closed tab. Async: an open wait holds no worker thread."""
        import asyncio
        s = sessions.get(sid)
        if s is None or s.closed:
            return "gone"
        if has_changes(s) or s.busy != s.busy_sent:
            return "1"
        ev = asyncio.Event()
        entry = (asyncio.get_running_loop(), ev)
        with s.waiters_lock:
            s.waiters.add(entry)
        try:
            if has_changes(s) or s.busy != s.busy_sent:  # (it came while we registered)
                return "1"
            await asyncio.wait_for(ev.wait(), 20)
            return "1"
        except asyncio.TimeoutError:
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
            if s.pending is None:  # (nothing changed, but the page may have to stop waiting, or run a widget's command)
                out = (busy_mark(s, oob=True),) if s.busy != s.busy_sent else ()
                out += (cmds_mark(s, oob=True),) if s.commands else ()
                return out or ""
            d, s.pending = s.pending, None
            return changes(s, sid, d)

    return app


if __name__ == "__main__":
    module_dir = sys.argv[1] if len(sys.argv) > 1 else "build/hello/web"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5001
    import uvicorn

    print(f"mojoui web: http://127.0.0.1:{port}/", flush=True)
    uvicorn.run(make_app(module_dir), host="127.0.0.1", port=port, log_level="warning")
