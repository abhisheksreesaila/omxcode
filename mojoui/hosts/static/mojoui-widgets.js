// mojoui widgets (goal 34, mojoui/webcomponent.mojo): JavaScript widgets inside a Mojo screen.
//
// A bundle registers its widget once:
//   mojoui.defineWidget({ tag: 'mx-counter', events: ['click'], commands: { read(el, args) { return {...}; } },
//     mount(el, props, emit) { ... },  update(el, props) { ... },  destroy(el) { ... },
//     describe(el) { return { text: 'one line', value: ... }; },             // what it shows, as JSON (agents read it)
//     description: 'What it is, for agents',
//     fields: { count: { type: 'integer', set(el, value) { ... } } } })    // what an agent may set (JSON types only)
// Agents (goal 34b, docs/agent.md) see every widget: its description, describe()'s JSON and its fields go to the host
// (on the web only while an agent is attached); a set arrives as the built-in command "mojoui.set" {field, value}, which
// runs only a declared field's set() with a value of its declared JSON type; the widget reports the change itself, by
// emitting its own event.
// Widgets wear the app's theme (goal 34b M1b): the page carries the Look's tokens as CSS variables (--o-card, --o-ink,
// --o-font, --o-radius-card…) for a widget's sheet, and the runtime calls the widget's theme(el, tokens) with the same
// tokens as JSON data ({dark, palette, font, corners}) when it mounts and whenever the app's theme changes (light/dark
// live): the widget restyles itself in place, it is never mounted again.
// The screen holds a WebComponent view per widget: <div data-kind=webcomponent data-widget (its tag) data-widget-id data-props>.
// The host puts one element of that tag in it and keeps it for as long as the screen shows that key (tag + id): a
// rebuild of the whole page moves the live element into the new screen (Element.moveBefore where the browser has it:
// focus, selection and scroll stay), a props change calls update(), never mount() again. emit(name, payload) posts the
// event to the app (/w/<sid>), in order; a command from the app (#mojoui-cmds) calls the widget's command and posts its
// answer (/reply/<sid>). Everything that crosses is JSON text: props are parsed with JSON.parse, payloads and replies are
// JSON.stringify'd; nothing is eval'd or written as HTML (docs/js.md: security).
//
// On GTK (goal 34 M3) each widget has a WebKitGTK view of its own, with this same file and the same bundles: there is no
// htmx and no page around it. The host calls mojoui.native.receive(json) (props, the theme, commands: JSON text handed
// in as a function argument, never as code), and everything this side sends goes to the host's script message handler
// (window.webkit.messageHandlers.mojoui) as JSON text: events, replies, the widget's height, its one-line description.
(() => {
  const mojoui = window.mojoui = window.mojoui || {};
  const specs = new Map();  // tag → the widget's spec
  const mounts = mojoui.mounts = {};  // tag → how many times mount() ran (checks read it: a kept widget mounts once)
  const TAG = /^[a-z][a-z0-9._]*-[a-z0-9._-]*$/;
  const NAME = /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/;
  const TYPES = new Set(['string', 'number', 'integer', 'boolean', 'array', 'object']);
  const MAX_FACTS = 256 * 1024;  // (the web host's limit for what crosses: MAX_WIDGET_BYTES)
  const typeOf = v => v === null ? 'null' : Array.isArray(v) ? 'array' : Number.isInteger(v) ? 'integer' : typeof v;
  const fits = (type, v) => typeOf(v) === type || (type === 'number' && typeOf(v) === 'integer');
  let tokens = null, tokensText = '';  // the Look's tokens (data), as the host last handed them
  Object.defineProperty(mojoui, 'tokens', { get: () => tokens });
  function themeOne(el, spec) {
    if (!tokens || !spec || typeof spec.theme !== 'function' || !el.mojouiMounted || el.mojouiTokens === tokensText) return;
    el.mojouiTokens = tokensText;
    try { spec.theme(el, tokens); } catch (e) { console.error(`mojoui: ${spec.tag}.theme failed`, e); }
  }
  function takeTokens(text) {  // new tokens (JSON text): every mounted widget restyles once
    if (typeof text !== 'string' || text === tokensText) return;
    const t = parse(text, null);
    if (!t || typeof t !== 'object' || Array.isArray(t)) return;
    tokens = t;
    tokensText = text;
    for (const w of wrappers()) themeOne(w.firstElementChild, specs.get(w.dataset.widget));
    tell();
  }
  function pageTokens() {  // (the web) the skin's data-tokens, swapped in with the theme
    const k = document.getElementById('mojoui-skin-classes');
    if (k && k.dataset.tokens) takeTokens(k.dataset.tokens);
  }
  const keyOf = w => w.dataset.widget + '#' + w.dataset.widgetId;
  const parse = (text, fallback) => { try { return JSON.parse(text); } catch (e) { return fallback; } };
  const wrappers = () => document.querySelectorAll('#mojoui-root [data-kind=webcomponent][data-widget]');
  const keep = () => {  // where live widgets wait while the page around them is swapped
    let k = document.getElementById('mojoui-keep');
    if (!k) { k = document.createElement('div'); k.id = 'mojoui-keep'; k.hidden = true; document.body.append(k); }
    return k;
  };
  const move = (parent, el) => {
    if (parent.moveBefore && el.isConnected && parent.isConnected) { try { parent.moveBefore(el, null); return; } catch (e) { /* (falls back) */ } }
    parent.append(el);
  };

  // ---- events and replies to the app: one at a time, in order ----
  const queue = [];
  let sending = false;
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mojoui;  // (GTK's WebKitGTK host)
  async function flush() {
    if (sending) return;
    sending = true;
    try {
      while (queue.length) {
        const { path, values } = queue.shift();
        if (native) { native.postMessage(JSON.stringify(Object.assign({ path }, values))); continue; }
        const root = document.getElementById('mojoui-root');
        if (!root || !root.dataset.sid) break;
        try { await htmx.ajax('POST', `/${path}/${root.dataset.sid}`, { values, swap: 'none', source: window.mojouiLane('widgets') }); }
        catch (e) { console.warn('mojoui: widget event not sent', e); }
      }
    } finally { sending = false; }
  }
  mojoui.widgetQueue = queue;  // (checks wait for it to empty)
  mojoui.widgetBusy = () => sending || queue.length > 0;

  function emitter(el, spec) {
    return (name, payload, options) => {
      if (!NAME.test(String(name)) || (spec.events && !spec.events.includes(name))) { console.warn(`mojoui: ${spec.tag} has no event ${name}`); return; }
      const w = el.closest('[data-kind=webcomponent]');
      if (!w) return;
      const data = JSON.stringify(payload === undefined ? null : payload);
      const values = { tag: w.dataset.widget, id: w.dataset.widgetId, name, data };
      const last = queue[queue.length - 1];
      if (options && options.latest && last && last.path === 'w' && last.values.tag === values.tag && last.values.id === values.id && last.values.name === name) {
        last.values = values;  // (latest: an unsent event of the same name is replaced, e.g. a whole text)
      } else queue.push({ path: 'w', values });
      flush();
      tell();
    };
  }

  // ---- defineWidget: the widget as a custom element ----
  mojoui.defineWidget = spec => {
    if (!spec || typeof spec.tag !== 'string' || !TAG.test(spec.tag)) throw new Error('defineWidget: give a tag with a hyphen (mx-name)');
    if (typeof spec.mount !== 'function') throw new Error(`defineWidget(${spec.tag}): mount(el, props, emit) is required`);
    if (specs.has(spec.tag)) return;  // (its bundle loaded twice)
    const fields = spec.fields || {};
    if (typeof fields !== 'object' || Array.isArray(fields)) throw new Error(`defineWidget(${spec.tag}): fields is an object {name: {type, set(el, value)}}`);
    for (const [name, f] of Object.entries(fields)) {
      if (!NAME.test(name) || !f || !TYPES.has(f.type) || typeof f.set !== 'function')
        throw new Error(`defineWidget(${spec.tag}): field ${name} needs a word for a name, a JSON type (${[...TYPES].join(', ')}) and set(el, value)`);
    }
    specs.set(spec.tag, spec);
    class Widget extends HTMLElement {
      connectedCallback() {
        if (this.mojouiMounted) return;  // (moved without moveBefore: it stays as it is)
        const w = this.parentElement && this.parentElement.closest('[data-kind=webcomponent]');
        if (!w || w.dataset.widget !== spec.tag) return;
        this.mojouiMounted = true;
        this.mojouiProps = w.dataset.props;
        mounts[spec.tag] = (mounts[spec.tag] || 0) + 1;
        try { spec.mount(this, parse(w.dataset.props, {}), emitter(this, spec)); }
        catch (e) { console.error(`mojoui: ${spec.tag}.mount failed`, e); }
        if (spec.focusable && !this.hasAttribute('tabindex')) {  // (a widget with nothing focusable inside takes Tab itself)
          this.tabIndex = 0;
          if (!this.hasAttribute('aria-label') && typeof spec.description === 'string') this.setAttribute('aria-label', spec.description.slice(0, 200));
        }
        if (!native) pageTokens();
        themeOne(this, spec);
        tell();
      }
      connectedMoveCallback() { /* moved by the host (moveBefore): kept as it is */ }
      disconnectedCallback() {
        setTimeout(() => {  // (gone for good only if nothing put it back by the next turn)
          if (this.isConnected || !this.mojouiMounted) return;
          this.mojouiMounted = false;
          try { if (spec.destroy) spec.destroy(this); } catch (e) { console.error(`mojoui: ${spec.tag}.destroy failed`, e); }
        }, 0);
      }
    }
    customElements.define(spec.tag, Widget);
    adopt();
  };

  function said(w) {  // what describe() says: {text, value, …} as plain JSON data; null: no describe, or not mounted
    const el = w.firstElementChild, spec = specs.get(w.dataset.widget);
    if (!el || !spec || !el.mojouiMounted || typeof spec.describe !== 'function') return null;
    try {
      const d = spec.describe(el);
      const obj = d !== null && typeof d === 'object' && !Array.isArray(d) ? d : { text: String(d) };
      return JSON.parse(JSON.stringify(obj));  // (data only: no functions, no elements, no cycles)
    } catch (e) { return { text: 'describe failed' }; }
  }
  mojoui.describe = w => {  // one line about the widget (scripts/drive.py's WIDGET: line, GTK's report)
    const el = w.firstElementChild, spec = specs.get(w.dataset.widget);
    if (!el || !spec) return 'not defined';
    if (!el.mojouiMounted) return 'not mounted';
    if (!spec.describe) return 'no description';
    const d = said(w);
    return d && typeof d.text === 'string' ? d.text : JSON.stringify(d);
  };
  mojoui.facts = w => {  // what an agent sees of a widget: {tag, id, defined, mounted, description, said, fields: {name: type}}
    const spec = specs.get(w.dataset.widget), el = w.firstElementChild;
    const fields = {};
    for (const [name, f] of Object.entries((spec && spec.fields) || {})) fields[name] = f.type;
    return { tag: w.dataset.widget, id: Number(w.dataset.widgetId), defined: !!spec, mounted: !!(el && el.mojouiMounted),
             description: spec && typeof spec.description === 'string' ? spec.description.slice(0, 500) : '',
             said: said(w), fields };
  };

  // Every WebComponent view gets its live element: the one it had, the one parked for its key, or a new one (mounted
  // when connected, or when its bundle defines the tag). New props go to update().
  function adopt() {
    const parked = keep();
    for (const w of wrappers()) {
      const tag = w.dataset.widget, key = keyOf(w);
      if (!TAG.test(tag)) continue;
      let el = w.firstElementChild && w.firstElementChild.localName === tag ? w.firstElementChild : null;
      if (!el) {
        el = [...parked.children].find(c => c.mojouiKey === key) || null;
        if (el) move(w, el);
        else { el = document.createElement(tag); el.mojouiKey = key; w.append(el); }
      }
      el.mojouiKey = key;
      const spec = specs.get(tag);
      if (el.mojouiMounted && spec && el.mojouiProps !== w.dataset.props) {
        el.mojouiProps = w.dataset.props;
        try { if (spec.update) spec.update(el, parse(w.dataset.props, {})); } catch (e) { console.error(`mojoui: ${tag}.update failed`, e); }
        tell();
      }
    }
  }

  let focus = null;  // what had the keyboard inside a widget the page moved
  function park(target) {
    const list = target.matches && target.matches('[data-kind=webcomponent]') ? [target] : [];
    if (target.querySelectorAll) list.push(...target.querySelectorAll('[data-kind=webcomponent]'));
    for (const w of list) {
      const el = w.firstElementChild;
      if (!el || !el.mojouiKey) continue;
      if (el.contains(document.activeElement)) {  // (its keyboard focus and its text selection go back after the swap)
        const sel = document.getSelection();
        const range = sel && sel.rangeCount && el.contains(sel.anchorNode) && el.contains(sel.focusNode)
          ? [sel.anchorNode, sel.anchorOffset, sel.focusNode, sel.focusOffset] : null;
        focus = { el, active: document.activeElement, range };
      }
      move(keep(), el);
    }
  }
  function restore() {  // in the same task as the swap: before the browser reports a selection change to the widget
    adopt();
    if (!focus) return;
    const { el, active, range } = focus;
    focus = null;
    if (!el.isConnected || !active.isConnected || el.parentElement === keep()) return;
    if (!el.contains(document.activeElement)) active.focus({ preventScroll: true });
    if (range && range.every((n, k) => k % 2 || el.contains(n))) {
      try { document.getSelection().setBaseAndExtent(range[0], range[1], range[2], range[3]); } catch (e) { /* (the widget changed its DOM meanwhile) */ }
    }
  }
  function settle() {
    pageTokens();
    restore();
    for (const el of [...keep().children]) el.remove();  // (its key left the screen: disconnected, destroyed)
    runCommands();
  }

  document.addEventListener('htmx:oobBeforeSwap', e => {
    const d = e.detail, t = d && d.target;
    if (!t || !d.fragment) return;
    const fresh = d.fragment.querySelector && d.fragment.querySelector('[data-kind=webcomponent]');
    if (t.matches && t.matches('[data-kind=webcomponent]') && fresh && keyOf(fresh) === keyOf(t) && d.fragment.childElementCount === 1 && fresh === d.fragment.firstElementChild) {
      // the widget's own patch (new props): its view changes in place, the element stays where it is
      for (const a of [...t.attributes]) if (!fresh.hasAttribute(a.name)) t.removeAttribute(a.name);
      for (const a of [...fresh.attributes]) if (t.getAttribute(a.name) !== a.value) t.setAttribute(a.name, a.value);
      d.shouldSwap = false;
    } else {
      park(t);
    }
    setTimeout(settle, 0);  // (after every swap of this answer: they run back to back)
  });
  document.addEventListener('htmx:oobAfterSwap', () => { restore(); pageTokens(); });
  document.addEventListener('htmx:afterSettle', settle);
  document.addEventListener('DOMContentLoaded', settle);

  // ---- commands from the app: #mojoui-cmds holds the newest (seq numbers only grow within a page) ----
  let lastSeq = 0;
  function runCommands() {
    const box = document.getElementById('mojoui-cmds');
    runList(box ? parse(box.dataset.cmds || '[]', []) : []);
  }
  function runList(list) {
    if (!Array.isArray(list)) return;
    for (const c of list) {
      if (!c || !(Number(c.seq) > lastSeq)) continue;
      lastSeq = Number(c.seq);
      run(c);
    }
  }
  async function run(c) {
    let data = null, error = '';
    try {
      const w = [...wrappers()].find(x => x.dataset.widget === c.tag && x.dataset.widgetId === String(c.widget));
      const el = w && w.firstElementChild, spec = specs.get(c.tag);
      if (!el || !spec || !el.mojouiMounted) throw new Error(`no widget ${c.tag}#${c.widget} on the page`);
      if (c.name === 'mojoui.set') {  // (an agent's set: a declared field, a value of its JSON type, nothing else)
        const a = c.args && typeof c.args === 'object' ? c.args : {};
        const f = spec.fields && typeof a.field === 'string' && Object.prototype.hasOwnProperty.call(spec.fields, a.field) ? spec.fields[a.field] : null;
        if (!f) throw new Error(`${c.tag} has no settable field ${String(a.field).slice(0, 64)}`);
        if (!fits(f.type, a.value)) throw new Error(`${c.tag}.${a.field} takes ${f.type}, not ${typeOf(a.value)}`);
        await f.set(el, a.value);
        data = { set: a.field };
      } else {
        const fn = spec.commands && Object.prototype.hasOwnProperty.call(spec.commands, c.name) ? spec.commands[c.name] : null;
        if (typeof fn !== 'function') throw new Error(`${c.tag} has no command ${c.name}`);
        data = await fn(el, c.args);
      }
      if (data === undefined) data = null;
    } catch (e) {
      error = String((e && e.message) || e || 'failed').slice(0, 500);
      if (c.name === 'mojoui.set') console.warn('mojoui: set refused: ' + error);
    }
    let text = 'null';
    try { text = JSON.stringify(data); if (text === undefined) text = 'null'; } catch (e) { error = error || "the reply isn't JSON"; }
    queue.push({ path: 'reply', values: { seq: c.seq, data: text, error } });
    flush();
    tell();
  }

  // ---- GTK: one widget in a WebKitGTK view of its own (the host's page: an empty #mojoui-root) ----
  // ---- what the widgets say about themselves, for the host: GTK always (its report), the web while an agent is attached ----
  let telling = false;
  const told = new Map();  // key → what the host last heard
  const agentAttached = () => { const r = document.getElementById('mojoui-root'); return !!(r && r.dataset.agent === '1'); };
  function tell() {
    if (telling || (!native && !agentAttached())) return;
    telling = true;
    setTimeout(() => {
      telling = false;
      for (const w of wrappers()) {
        let facts = JSON.stringify(mojoui.facts(w));
        if (facts.length > MAX_FACTS) facts = JSON.stringify(Object.assign(mojoui.facts(w), { said: { text: 'too big to describe' } }));
        const key = keyOf(w), line = mojoui.describe(w), mounted = mounts[w.dataset.widget] || 0;
        const now = JSON.stringify([line, mounted, facts]);
        if (told.get(key) === now) continue;
        told.set(key, now);
        if (native) queue.push({ path: 'describe', values: { text: line, mounts: mounted, facts } });
        else queue.push({ path: 'describe', values: { tag: w.dataset.widget, id: w.dataset.widgetId, data: facts } });
      }
      flush();
    }, 30);
  }
  mojoui.tell = tell;  // (a widget whose state changes without an event may call it; every emit, mount, update and command does)
  document.addEventListener('htmx:afterSettle', () => tell());
  document.addEventListener('DOMContentLoaded', () => tell());
  if (native) {
    let height = -1;
    const sizes = new ResizeObserver(() => {  // the view is as tall as its widget, as the web's box is
      const w = wrappers()[0];
      const h = w ? Math.ceil(w.getBoundingClientRect().height) : 0;
      if (h !== height) { height = h; queue.push({ path: 'size', values: { height: h } }); flush(); }
    });
    document.addEventListener('securitypolicyviolation', e => { queue.push({ path: 'csp', values: { directive: String(e.effectiveDirective || '') } }); flush(); });
    // Tab order across the window (goal 34b M1b): the host hands this page Tab and Shift+Tab while its view has the
    // keyboard ({tab: 'forward' | 'back'}). The widget sees it first, as a keydown it may take (a code editor indenting);
    // otherwise the keyboard goes to the page's next stop, or, past its last (before its first), back to the host, which
    // moves it on through the window. The host's {focus: 'first' | 'last'} puts it on this page's first or last stop when
    // Tab brings it in.
    const STOPS = 'a[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), select:not([disabled]), textarea:not([disabled]),'
      + ' [tabindex]:not([tabindex="-1"]), [contenteditable=""], [contenteditable="true"]';
    const stops = () => [...document.querySelectorAll('#mojoui-root ' + STOPS.split(', ').join(', #mojoui-root '))]
      .filter(e => e.getClientRects().length > 0);
    function tab(back) {
      const a = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
      const ev = new KeyboardEvent('keydown', { key: 'Tab', code: 'Tab', shiftKey: back, bubbles: true, cancelable: true });
      if (a && !a.dispatchEvent(ev)) return;  // (the widget took it)
      const list = stops(), i = a ? list.findIndex(s => s === a || s.contains(a)) : -1;
      const j = i < 0 ? (back ? list.length - 1 : 0) : i + (back ? -1 : 1);
      if (j >= 0 && j < list.length) { list[j].focus({ preventScroll: false }); return; }
      queue.push({ path: 'tab', values: { forward: !back } });
      flush();
    }
    mojoui.native = {
      receive(text) {  // the host's message: {theme: {classes, css}}, {widget: {tag, id, props (JSON text)}}, {commands: [...]}
        const m = parse(String(text), null);
        if (!m || typeof m !== 'object') return false;
        if (m.theme && typeof m.theme === 'object') {
          document.body.className = String(m.theme.classes || '');
          let st = document.getElementById('mojoui-theme');
          if (!st) { st = document.createElement('style'); st.id = 'mojoui-theme'; document.head.prepend(st); }
          st.textContent = String(m.theme.css || '');  // (CSS text, as the web's theme <style>: style-src allows it, script-src doesn't)
          if (m.theme.tokens && typeof m.theme.tokens === 'object') takeTokens(JSON.stringify(m.theme.tokens));
        }
        if (m.widget && typeof m.widget === 'object' && TAG.test(String(m.widget.tag))) {
          const root = document.getElementById('mojoui-root');
          let w = wrappers()[0];
          if (!w) {
            w = document.createElement('div');
            w.dataset.kind = 'webcomponent';
            w.dataset.widget = String(m.widget.tag);
            w.dataset.widgetId = String(m.widget.id);
            w.dataset.props = String(m.widget.props);
            root.append(w);
            sizes.observe(w);
          } else if (w.dataset.widget !== String(m.widget.tag) || w.dataset.widgetId !== String(m.widget.id)) {
            return false;  // (a view holds one widget for good: its key never changes)
          } else w.dataset.props = String(m.widget.props);
          adopt();
        }
        if (Array.isArray(m.commands)) runList(m.commands);
        if (m.tab === 'forward' || m.tab === 'back') tab(m.tab === 'back');
        if (m.focus === 'first' || m.focus === 'last') {
          const list = stops(), el = m.focus === 'last' ? list[list.length - 1] : list[0];
          if (el) el.focus({ preventScroll: true });
        }
        return true;
      },
    };
  }
})();
