"""Drive a mojoui web app in headless Chromium with the same steps as the GTK test mode.

  pixi run python scripts/drive.py build/gallery/web "type:Your name=Ada;toggle:Notifications"

Starts mojoui/hosts/web.py on a free port, performs each step on the real page
(clicks, typing, Return, ticking, choosing, sliding), then prints every control's
state as the browser reports it (LABEL/BUTTON/FIELD/TOGGLE/DROPDOWN/SLIDER/PROGRESS).
"""

import json
import re
import socket
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
CHROMIUM = "/usr/bin/chromium"

DUMP = """() => [...document.querySelectorAll('#mojoui-root [data-kind], #mojoui-overlay [data-kind]')].map(e => {
  const k = e.dataset.kind;
  if (k === 'label') { const tone = ['warn', 'good', 'strong', 'accent'].find(t => e.classList.contains('tone-' + t));
    return 'LABEL: ' + e.textContent + (tone ? String.fromCharCode(10) + 'TONE: ' + e.textContent + ' = ' + tone : ''); }
  if (k === 'button') return 'BUTTON: ' + e.textContent.trim() + (e.dataset.tip ? String.fromCharCode(10) + 'TIP: ' + e.textContent.trim() + ' = ' + e.dataset.tip : '');
  if (k === 'dialog') return 'DIALOG: ' + e.dataset.title;
  if (k === 'toast') return 'TOAST: ' + e.dataset.title + (e.dataset.action ? ' | ' + e.dataset.action : '');
  if (k === 'popover') return 'POPOVER: ' + e.dataset.title;
  if (k === 'field') return 'FIELD: ' + e.value;
  if (k === 'toggle') return (e.dataset.check ? 'CHECK: ' : 'TOGGLE: ') + e.querySelector('span').textContent + (e.querySelector('input').checked ? '=on' : '=off');
  if (k === 'dropdown') return 'DROPDOWN: ' + e.options[e.selectedIndex].text;
  if (k === 'slider') return 'SLIDER: ' + e.value;
  if (k === 'progress') return 'PROGRESS: ' + e.value;
  if (k === 'image') return 'IMAGE: ' + e.naturalWidth + 'x' + e.naturalHeight;
  const picked = () => { const i = e.querySelector('input:checked'); return i ? i.nextElementSibling.textContent : ''; };
  if (k === 'segmented') return 'SEGMENTED: ' + picked();
  if (k === 'tabs') return 'TABS: ' + picked();
  if (k === 'radio') return 'RADIO: ' + picked();
  if (k === 'textarea') return 'TEXTAREA: ' + e.value.split(String.fromCharCode(10)).join(String.fromCharCode(92) + 'n');
  if (k === 'menubar' || k === 'item') return '';
  if (k === 'paragraph') return 'PARAGRAPH: ' + e.textContent + ' (' + e.querySelectorAll('[data-kind=run]').length + ' runs, ' + e.querySelectorAll('a[data-kind=run]').length + ' links, ' + e.children.length + ' elements)';
  if (k === 'run') return 'LABEL: ' + e.textContent;  // (a paragraph's runs: its words, as GTK reports them)
  if (k === 'menu') { const items = box => [...box.children].map(c => {
      if (c.dataset.sep) return '\u2014';
      if (c.dataset.label) return '[' + c.textContent + ']';
      if (c.classList.contains('menu')) { const h = c.querySelector(':scope > .mi'); return h.dataset.title + ' \u25b8 (' + items(c.querySelector(':scope > .menu-items')).join(', ') + ')'; }
      return c.dataset.title + (c.dataset.shortcut ? ' (' + c.dataset.shortcut + ')' : '') + (c.dataset.checked ? ' \u2713' : '') + (c.disabled ? ' (off)' : ''); });
    return 'MENU: ' + e.dataset.title + ': ' + items(e.querySelector(':scope > .menu-items')).join(', '); }
  if (k === 'alert') return 'ALERT: ' + e.querySelector('h3').textContent + ' | ' + e.querySelector('p').textContent + ' | '
    + [...e.querySelectorAll('button')].map(b => b.textContent).join(', ');
  if (k === 'nav') return 'NAV: ' + e.querySelector('h2').textContent + (e.dataset.back === '1' ? ' (back)' : '');
  if (k === 'date') return 'DATE: ' + e.value;
  if (k === 'board') { const list = getComputedStyle(e).display === 'flex';
    const sc = e.parentElement, objs = [...e.querySelectorAll(":scope > .object")];
    const seen = objs.filter(o => o.offsetTop >= sc.scrollTop - 1 && o.offsetTop + 44 <= sc.scrollTop + sc.clientHeight + 1
      && o.offsetLeft >= sc.scrollLeft - 1 && o.offsetLeft + 44 <= sc.scrollLeft + sc.clientWidth + 1).map(o => o.dataset.tag).sort();
    return ['LAYOUT: ' + (list ? 'list' : 'board')].concat(list ? [] : objs.map(o =>
      'BOARD: ' + o.dataset.tag + ' at ' + o.dataset.x + ',' + o.dataset.y + ' ' + o.dataset.w + 'x' + o.dataset.h))
      .concat(list ? [] : ['INVIEW: ' + seen.join(', ')]).join(String.fromCharCode(10)); }
  if (k === 'object') return '';
  if (k === 'table') return 'TABLE: ' + (e.dataset.tag || '') + ' ' + e.dataset.rows + ' rows, ' + e.dataset.columns + ' columns, ' + e.dataset.selected + ' selected';
  if (k === 'route') return 'ROUTE: ' + e.dataset.route;
  if (k === 'icon') return 'ICON: ' + (e.querySelector('svg') ? e.dataset.icon : '?');
  if (k === 'grid') return 'GRID: ' + e.dataset.columns + ' columns, ' + e.children.length + ' items';
  if (k === 'canvas') { const cv = e.querySelector('canvas'), r = e.getBoundingClientRect(), st = e.mojoui;
    let colours = 0, painted = 0;
    if (cv.width > 0) { const d = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data, seen = new Map();
      const step = Math.max(1, Math.floor(d.length / 4 / 20000)), sample = [];
      for (let i = 0; i < d.length / 4; i += step) { const c = (d[4 * i] << 16) | (d[4 * i + 1] << 8) | d[4 * i + 2]; sample.push(c); seen.set(c, (seen.get(c) || 0) + 1); }
      colours = seen.size;
      let bg = 0, best = 0; seen.forEach((n, c) => { if (n > best) { best = n; bg = c; } });  // the background: the most common colour
      const far = c => Math.abs((c >> 16 & 255) - (bg >> 16 & 255)) + Math.abs((c >> 8 & 255) - (bg >> 8 & 255)) + Math.abs((c & 255) - (bg & 255)) > 30;
      painted = Math.floor(100 * sample.filter(far).length / sample.length); }
    return 'CANVAS: ' + Math.round(r.width) + 'x' + Math.round(r.height) + ' pt ' + cv.width + 'x' + cv.height + ' px scale '
      + (window.devicePixelRatio || 1).toFixed(1) + ' colours ' + colours + ' draws ' + (st ? st.count : 0) + ' painted ' + painted
      + (e.dataset.tip ? String.fromCharCode(10) + 'TIP: ' + e.dataset.tag + ' = ' + e.dataset.tip : ''); }
  if (k === 'list') { const r0 = e.querySelector('[data-row="0"]');
    return 'LIST: ' + e.querySelector('.rows').dataset.count + ' rows' + String.fromCharCode(10) + 'LISTROWS: ' + e.querySelectorAll('.row').length
      + (r0 ? String.fromCharCode(10) + 'LISTROW: ' + r0.textContent : ''); }
}).filter(Boolean).concat([...document.querySelectorAll('.scroll[data-pin="1"]')].map(e =>
  'PINNED: ' + (e.dataset.tag || '?') + (e.scrollHeight - e.scrollTop - e.clientHeight <= 4 ? ' at end' : ' not at end'))).concat([...document.querySelectorAll('[data-tag]')].map(e => {
  const r = e.getBoundingClientRect();
  return 'BOX: ' + e.dataset.tag + ' ' + [r.x, r.y, r.width, r.height].map(v => v.toFixed(1)).join(' ');
})).concat([...document.querySelectorAll('[data-kind=button], label.picker')].map(b => {
  const t = b.parentElement && b.parentElement.closest('[data-tag]'), r = b.getBoundingClientRect();
  return t && r.width > 0 ? 'BOX: ' + t.dataset.tag + '/' + (b.title || b.textContent.trim()) + ' ' + [r.x, r.y, r.width, r.height].map(v => v.toFixed(1)).join(' ') : '';
}).filter(Boolean)).concat(window.mojouiClip !== undefined ? ['CLIPBOARD: ' + window.mojouiClip.split(String.fromCharCode(9)).join(String.fromCharCode(92) + 't').split(String.fromCharCode(10)).join(String.fromCharCode(92) + 'n')] : []).concat([...document.body.classList].filter(c => c !== 'skin').map(c => 'DESIGN: ' + c)).concat(
  document.body.classList.contains('skin') && document.fonts.check('13px Inter') && document.fonts.check('13px "JetBrains Mono"') ? ["FONT: Inter, JetBrains Mono (the app's own)"] : []
).concat(['PAGE: ' + document.documentElement.scrollWidth + 'x' + document.documentElement.scrollHeight
  + ' in ' + innerWidth + 'x' + innerHeight]).join(String.fromCharCode(10))"""


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def exact(text):
    return re.compile("^" + re.escape(text) + "$")


def canvas_at(page, k):
    """A canvas by number (counting the content's canvases: the island, window chrome, is left out) or by its tag."""
    if not k.isdigit():
        return page.locator(f"[data-kind=canvas][data-tag={k}]").first
    return page.locator("[data-kind=canvas]:not([data-tag=island])").nth(int(k))


CANVASES_DRAWN = """() => [...document.querySelectorAll('[data-kind=canvas]')].every(div => {
  const st = div.mojoui, m = document.getElementById('n' + div.dataset.node + '-meta');
  if (!st || !m) return false;
  if (m.dataset.frames !== '0') return st.count > 0;  // playing: frames keep coming
  const ev = window.mojouiEvents;
  return !st.busy && !(ev && (ev.sending || ev.queue.length)) && !st.updating && !st.again && !st.timer && String(st.drawn) === m.dataset.version;
})"""


def settle(page):
    """Wait for HTMX's delayed triggers to fire and its requests to finish, and for every
    canvas to show its current version."""
    page.wait_for_timeout(250)
    page.wait_for_function("() => !document.querySelector('.htmx-request')", timeout=10000)
    page.wait_for_function("() => [...document.images].every(i => i.complete)", timeout=10000)
    page.wait_for_function(CANVASES_DRAWN, timeout=20000)
    page.wait_for_timeout(50)


def step(page, s):
    verb, _, rest = s.partition(":")
    if verb == "say":  # say:TAG: what the view tagged TAG says now (its tooltip: a drawn view's words), mid-run
        el = page.locator(f"[data-tag={rest}]").first
        return f"SAYS: {rest} = " + (el.get_attribute("data-tip") or "")
    if verb == "hold":  # hold:Title=ms: the button pressed and held that long, then its transform read (HOLD: title transform)
        title, _, ms = rest.partition("=")
        box = page.locator("[data-kind=button]").filter(has_text=exact(title)).first.bounding_box()
        page.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        page.mouse.down()
        page.wait_for_timeout(int(ms or 500))
        held = page.evaluate("(t) => { const b = [...document.querySelectorAll('[data-kind=button]')].find(e => e.textContent.trim() === t); return b ? getComputedStyle(b).transform : 'none'; }", title)
        page.mouse.up()
        return f"HOLD: {title} {held}"
    if verb == "tap":
        title, _, nth = rest.partition("@")
        page.locator("[data-kind=button]").filter(has_text=exact(title)).nth(int(nth or 0)).click()
    elif verb in ("type", "submit", "enter"):
        hint, _, text = rest.partition("=")
        field = page.locator(f"input[data-kind=field][placeholder={hint!r}]").first
        if verb in ("type", "enter"):
            field.fill(text)
        if verb in ("submit", "enter"):
            field.press("Enter")  # for "enter": straight after typing, no wait
    elif verb == "link":  # link:Text: the link of that text in a Paragraph, clicked
        page.locator("a[data-kind=run]").filter(has_text=exact(rest)).first.click()
    elif verb == "tick":  # tick:TAG: the tick box tagged TAG (a table's row has no label to find it by)
        page.locator(f"[data-tag={rest!r}] input").first.click()
    elif verb == "dragto":  # dragto:SRC=DST: the view tagged SRC dragged with the mouse onto the view tagged DST (the browser's drag and drop)
        src, _, dst = rest.partition("=")
        page.locator(f"[data-tag={src!r}]").first.drag_to(page.locator(f"[data-tag={dst!r}]").first)
    elif verb == "toggle":
        page.locator("[data-kind=toggle]").filter(has=page.locator("span", has_text=exact(rest))).first.locator("input").click()
    elif verb == "select":
        k, _, option = rest.partition("=")
        page.locator("select[data-kind=dropdown]").nth(int(k)).select_option(label=option)
    elif verb in ("segment", "tab", "radio"):
        k, _, option = rest.partition("=")
        kind = {"segment": "segmented", "tab": "tabs", "radio": "radio"}[verb]
        group = page.locator(f"[data-kind={kind}]").nth(int(k))
        group.locator("label").filter(has=page.locator("span", has_text=exact(option))).first.click()
    elif verb == "textarea":
        k, _, text = rest.partition("=")
        page.locator("textarea[data-kind=textarea]").nth(int(k)).fill(text.replace("\\n", "\n"))
    elif verb == "menu":  # menu:File>Save: open the bar's File menu and choose Save; menu:>Item: the open context menu's item
        title, _, item = rest.partition(">")
        if title:
            page.locator(f".menubar > .menu[data-title={title!r}] > .menu-title").first.click()
            page.wait_for_timeout(50)
            scope = page.locator(f".menubar > .menu[data-title={title!r}]")
        else:
            scope = page.locator(".menu.context")
        scope.locator(f"[data-kind=item][data-title={item!r}]").first.dispatch_event("click")  # (a submenu's item is shown on hover)
    elif verb == "toast":  # toast:Undo: the toast's action button
        page.locator("[data-kind=toast] button[data-action]").filter(has_text=exact(rest)).first.click()
    elif verb == "dismiss":  # dismiss: Escape on what floats (a popover, a context menu, else the dialog)
        page.keyboard.press("Escape")
    elif verb == "shortcut":  # shortcut:Ctrl+Shift+S: a real key press anywhere in the window
        *mods, key = rest.split("+")
        page.keyboard.press("+".join([{"Ctrl": "Control"}.get(m, m) for m in mods] + [key.lower() if len(key) == 1 else key]))
    elif verb == "rightclick":  # rightclick:K=fx,fy: a right click at (x, y) thousandths of canvas K
        k, _, arg = rest.partition("=")
        box = canvas_at(page, k).bounding_box()
        fx, fy = (int(v) / 1000 for v in arg.split(","))
        page.mouse.click(box["x"] + fx * box["width"], box["y"] + fy * box["height"], button="right")
    elif verb == "alert":
        if rest == "Escape":
            page.keyboard.press("Escape")  # the dialog's own cancel
        else:
            page.locator("dialog[data-kind=alert] button").filter(has_text=exact(rest)).first.click()
    elif verb == "back":
        page.locator("[data-kind=navback]").first.click()
    elif verb == "date":
        k, _, value = rest.partition("=")
        page.locator("input[data-kind=date]").nth(int(k)).fill(value)
    elif verb == "scroll":
        k, _, row = rest.partition("=")
        page.locator("[data-kind=list]").nth(int(k)).evaluate(
            "(e, row) => { e.scrollTop = row * Number(e.dataset.rowHeight); e.dispatchEvent(new Event('scroll')); }",
            int(row))
    elif verb == "row":
        k, _, row = rest.partition("=")
        page.locator("[data-kind=list]").nth(int(k)).locator(f'[data-row="{int(row)}"]').click()
    elif verb == "pick":  # pick:Title=/path: choose that file in the FilePicker (a real file input; it uploads)
        title, _, path = rest.partition("=")
        page.locator(f"input.picker-input[data-title={title!r}]").first.set_input_files(path)
    elif verb == "key":  # key:K=shift+ctrl+Name: a real key press, to whatever has the keyboard (a tapped canvas, an open editor)
        _, _, name = rest.partition("=")
        *mods, key = name.split("+")
        page.keyboard.press("+".join([m.capitalize() if m != "ctrl" else "Control" for m in mods] + [key]))
    elif verb == "typekeys":  # typekeys:K=text: real key presses at a fast typist's pace (30 ms apart, no waiting
        _, _, text = rest.partition("=")  # for the editor the first one opens: the keys after it mustn't be lost)
        for part in re.split("(⎋)", text):  # (⏎ Enter, ⎋ Escape: both at the same pace, nothing waits)
            if part == "⎋":
                page.keyboard.press("Escape")
                page.wait_for_timeout(30)
            elif part:
                page.keyboard.type(part.replace("⏎", "\n"), delay=30)
    elif verb in ("drag", "dragat", "doubletap", "zoom", "frames", "tapat", "shifttapat"):  # canvas steps: real mouse input on the canvas
        k, _, arg = rest.partition("=")
        canvas = canvas_at(page, k)
        box = canvas.bounding_box()
        cx, cy = round(box["x"] + box["width"] / 2), round(box["y"] + box["height"] / 2)
        if verb == "doubletap":  # a double click at (x, y) thousandths of the canvas
            fx, fy = (int(v) / 1000 for v in arg.split(","))
            page.mouse.dblclick(box["x"] + fx * box["width"], box["y"] + fy * box["height"])
        elif verb == "tapat" or verb == "shifttapat":  # a click at (x, y) thousandths of the canvas (shifttapat: with Shift held)
            fx, fy = (int(v) / 1000 for v in arg.split(","))
            if verb == "shifttapat":
                page.keyboard.down("Shift")
            page.mouse.click(box["x"] + fx * box["width"], box["y"] + fy * box["height"])
            if verb == "shifttapat":
                page.keyboard.up("Shift")
        elif verb == "dragat":  # start at (fx, fy) thousandths of the canvas, move (dx, dy) points
            fx, fy, dx, dy = (int(v) for v in arg.split(","))
            sx, sy = box["x"] + fx / 1000 * box["width"], box["y"] + fy / 1000 * box["height"]
            page.mouse.move(sx, sy)
            page.mouse.down()
            page.mouse.move(sx + dx / 2, sy + dy / 2)
            page.mouse.move(sx + dx, sy + dy)
            page.mouse.up()
        elif verb == "drag":
            dx, dy = (int(v) for v in arg.split(","))
            page.mouse.move(cx, cy)
            page.mouse.down()
            page.mouse.move(cx + dx / 2, cy + dy / 2)
            page.mouse.move(cx + dx, cy + dy)
            page.mouse.up()
        elif verb == "zoom":
            import math
            page.mouse.move(cx, cy)
            page.mouse.wheel(0, -400 * math.log2(float(arg)))  # 4 notches of 100 = 2×
        else:
            n = int(arg)
            # Steady state: skip 10 warm-up frames (the first pull waits for the Play event's round trip).
            start = canvas.evaluate("e => e.mojoui.count") + 10
            canvas.evaluate("(e, want) => new Promise(ok => { const t = setInterval(() => { if (e.mojoui.count >= want) { clearInterval(t); ok(); } }, 20); })",
                            start + n + 1)
            ms = canvas.evaluate("(e, a) => e.mojoui.times[a[1]] - e.mojoui.times[a[0]]", [start, start + n])
            return f"FRAMES: {n} in {ms:.1f} ms = {n / (ms / 1000):.1f} fps, draws {n}"
    elif verb in ("move", "resize"):  # a board object dragged by its header (or its corner) with the mouse
        tag, _, arg = rest.partition("=")
        dx, dy = (int(v) for v in arg.split(","))
        obj = page.locator(f"[data-kind=object][data-tag={tag!r}]").first
        obj.scroll_into_view_if_needed()  # (as a person would: the corner may sit below the fold)
        box = obj.bounding_box()
        sx = box["x"] + (box["width"] - 8 if verb == "resize" else 20)
        sy = box["y"] + (box["height"] - 8 if verb == "resize" else 16)
        page.mouse.move(sx, sy)
        page.mouse.down()
        page.mouse.move(sx + dx / 2, sy + dy / 2)
        page.mouse.move(sx + dx, sy + dy)
        page.mouse.up()
    elif verb == "style":  # style:selector=property: the first match's computed value (STYLE: selector property value)
        sel, prop = rest.rsplit("=", 1)  # (a selector may hold "=": [data-tag=inspector] hr)
        value = page.evaluate("([s, p]) => { const e = document.querySelector(s); return e ? getComputedStyle(e).getPropertyValue(p) : 'none'; }", [sel, prop])
        return f"STYLE: {sel} {prop} {value}"
    elif verb == "js":  # js:expression: its value, as JSON (JS: value): a probe for what the other steps can't ask
        return "JS: " + json.dumps(page.evaluate("(src) => { return eval(src); }", rest))
    elif verb == "attr":  # attr:selector=attribute: the first match's attribute (ATTR: selector attribute value, or none)
        sel, name = rest.rsplit("=", 1)
        value = page.evaluate("([s, a]) => { const e = document.querySelector(s); return e && e.getAttribute(a) !== null ? e.getAttribute(a) : 'none'; }", [sel, name])
        return f"ATTR: {sel} {name} {value[:80]}"
    elif verb == "wait":  # until a button with this title appears (e.g. after frames change the screen)
        page.locator("[data-kind=button]").filter(has_text=exact(rest)).first.wait_for(timeout=15000)
    elif verb == "pause":  # pause:1000: let animations run that long (as the GTK step does)
        page.wait_for_timeout(int(rest))
    elif verb == "slide":
        k, _, value = rest.partition("=")
        page.locator("input[data-kind=slider]").nth(int(k)).fill(value)
    else:
        raise ValueError(f"unknown step {s}")
    settle(page)


# Every tagged view, and each button in a tagged view, as the Mac's view dump writes it (scripts/parity.py compares them)
RECTS = """() => { const out = []; const r = e => { const b = e.getBoundingClientRect();
    return ' @ ' + Math.round(b.x) + ',' + Math.round(b.y) + ' ' + Math.round(b.width) + 'x' + Math.round(b.height); };
  for (const e of document.querySelectorAll('#mojoui-root [data-tag], #mojoui-overlay [data-tag]')) {
    out.push((e.dataset.kind || 'view') + ' #' + e.dataset.tag + r(e));
    for (const b of e.querySelectorAll(':scope [data-kind=button]'))
      if (b.closest('[data-tag]') === e) out.push('  button ' + JSON.stringify((b.textContent || b.title || '').trim()) + r(b)); }
  return out.join(String.fromCharCode(10)); }"""


def web_run(module_dir, steps, shot=None, viewport=(900, 900), tabs=1, rects=None, color_scheme=None, path="", reduced_motion=False):
    """Returns (result, output) like a process run: result.returncode is 0 on success.
    tabs > 1: that many pages open against the one server (each runs the steps); the server's own
    log lines (e.g. SHARED: …) come after the page's state. color_scheme: "light" or "dark" (prefers-color-scheme), else Chromium's.
    path: what follows the host's address on the first load (a deep link: "#/models/x/logs"); reduced_motion: the system asks for less motion."""
    from playwright.sync_api import sync_playwright

    port = free_port()
    server = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(module_dir), str(port)],
                              cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    url = f"http://127.0.0.1:{port}/"
    try:
        up = False
        for _ in range(1800):  # apps that load big shared data take a while to start
            try:
                urllib.request.urlopen(url + "static/htmx.min.js", timeout=1)  # cheap: "/" starts an app session
                up = True
                break
            except OSError:
                if server.poll() is not None:
                    return SimpleNamespace(returncode=1), "server died:\n" + server.stdout.read()
                time.sleep(0.1)
        if not up:
            return SimpleNamespace(returncode=1), "server didn't come up in 3 minutes"
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=CHROMIUM, headless=True)
            scheme = {"color_scheme": color_scheme} if color_scheme else {}
            if reduced_motion:
                scheme["reduced_motion"] = "reduce"
            page = browser.new_page(viewport={"width": viewport[0], "height": viewport[1]}, **scheme)
            others = [browser.new_page(viewport={"width": viewport[0], "height": viewport[1]}, **scheme) for _ in range(tabs - 1)]
            for other in others:
                other.goto(url)
                settle(other)
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            if os.environ.get("DRIVE_DEBUG"):  # every event the page posts, and the server's log, on stderr
                page.on("request", lambda r: print("REQ", r.method, r.url.split("/", 3)[-1], (r.post_data or "")[:160], file=sys.stderr) if "/e/" in r.url else None)
                page.on("console", lambda m: print("CONSOLE", m.text[:200], file=sys.stderr))
            page.goto(url + path)
            settle(page)
            extra = ""
            for s in [s for s in steps.split(";") if s]:
                line = step(page, s)
                settle(page)  # (a menu item's click posts and rebuilds the page: the next step must not land mid-rebuild)
                if line:
                    extra += line + "\n"
            out = "NATIVE: Chromium " + browser.version + "\n" + extra + page.evaluate(DUMP) + "\n"
            if rects:
                Path(rects).write_text(page.evaluate(RECTS) + "\n")
            if shot:
                page.screenshot(path=shot, full_page=True)
                out += f"SHOT: {shot}\n"
            if errors:
                out += "PAGE ERRORS: " + "; ".join(errors) + "\n"
            browser.close()
        server.terminate()
        log = server.stdout.read()
        out += "".join(l + "\n" for l in log.splitlines() if l.startswith("SHARED: "))
        return SimpleNamespace(returncode=1 if errors else 0), out
    finally:
        server.terminate()
        server.wait(timeout=10)


if __name__ == "__main__":
    shot = sys.argv[3] if len(sys.argv) > 3 else None
    import os
    size = tuple(int(v) for v in os.environ.get("VIEWPORT", "900x900").split("x"))
    r, out = web_run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "", shot=shot, viewport=size)
    print(out, end="")
    sys.exit(r.returncode)
