// mojoui widgets (goal 34, mojoui/webcomponent.mojo): JavaScript widgets inside a Mojo screen.
//
// A bundle registers its widget once:
//   mojoui.defineWidget({ tag: 'mx-counter', events: ['click'], commands: { read(el, args) { return {...}; } },
//     mount(el, props, emit) { ... },  update(el, props) { ... },  destroy(el) { ... },  describe(el) { return '...'; } })
// The screen holds a WebComponent view per widget: <div data-kind=webcomponent data-widget (its tag) data-widget-id data-props>.
// The host puts one element of that tag in it and keeps it for as long as the screen shows that key (tag + id): a
// rebuild of the whole page moves the live element into the new screen (Element.moveBefore where the browser has it:
// focus, selection and scroll stay), a props change calls update(), never mount() again. emit(name, payload) posts the
// event to the app (/w/<sid>), in order; a command from the app (#mojoui-cmds) calls the widget's command and posts its
// answer (/reply/<sid>). Everything that crosses is JSON text: props are parsed with JSON.parse, payloads and replies are
// JSON.stringify'd; nothing is eval'd or written as HTML (docs/js.md: security).
(() => {
  const mojoui = window.mojoui = window.mojoui || {};
  const specs = new Map();  // tag → the widget's spec
  const mounts = mojoui.mounts = {};  // tag → how many times mount() ran (checks read it: a kept widget mounts once)
  const TAG = /^[a-z][a-z0-9._]*-[a-z0-9._-]*$/;
  const NAME = /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/;
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
  async function flush() {
    if (sending) return;
    sending = true;
    try {
      while (queue.length) {
        const { path, values } = queue.shift();
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
    };
  }

  // ---- defineWidget: the widget as a custom element ----
  mojoui.defineWidget = spec => {
    if (!spec || typeof spec.tag !== 'string' || !TAG.test(spec.tag)) throw new Error('defineWidget: give a tag with a hyphen (mx-name)');
    if (typeof spec.mount !== 'function') throw new Error(`defineWidget(${spec.tag}): mount(el, props, emit) is required`);
    if (specs.has(spec.tag)) return;  // (its bundle loaded twice)
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

  mojoui.describe = w => {  // what the widget says about itself (scripts/drive.py's WIDGET: line; agents later)
    const el = w.firstElementChild, spec = specs.get(w.dataset.widget);
    if (!el || !spec) return 'not defined';
    if (!el.mojouiMounted) return 'not mounted';
    try { return spec.describe ? String(spec.describe(el)) : 'mounted'; } catch (e) { return 'describe failed'; }
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
  document.addEventListener('htmx:oobAfterSwap', restore);
  document.addEventListener('htmx:afterSettle', settle);
  document.addEventListener('DOMContentLoaded', settle);

  // ---- commands from the app: #mojoui-cmds holds the newest (seq numbers only grow within a page) ----
  let lastSeq = 0;
  function runCommands() {
    const box = document.getElementById('mojoui-cmds');
    const list = box ? parse(box.dataset.cmds || '[]', []) : [];
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
      const fn = spec.commands && Object.prototype.hasOwnProperty.call(spec.commands, c.name) ? spec.commands[c.name] : null;
      if (typeof fn !== 'function') throw new Error(`${c.tag} has no command ${c.name}`);
      data = await fn(el, c.args);
      if (data === undefined) data = null;
    } catch (e) { error = String((e && e.message) || e || 'failed').slice(0, 500); }
    let text = 'null';
    try { text = JSON.stringify(data); if (text === undefined) text = 'null'; } catch (e) { error = error || "the reply isn't JSON"; }
    queue.push({ path: 'reply', values: { seq: c.seq, data: text, error } });
    flush();
  }
})();
