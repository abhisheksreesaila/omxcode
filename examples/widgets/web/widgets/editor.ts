// mx-editor: CodeMirror 6 (from npm: web/package.json, pinned by package-lock.json) as a mojoui widget, in TypeScript.
// esbuild bundles and minifies it with CodeMirror at build time (scripts/web_assets.py). Props: doc and rev (Mojo's text
// replaces the editor's only when rev moves on: Load sample), placeholder. Each edit emits "change" {text}; commands:
// focus, selection (→ {anchor, head}), text (→ {text}). Agents read its text and line count (describe) and may set its
// text (the field text, a string): a set is an edit like typing, so it emits "change" and update() hears it.
/// <reference path="../../../../mojoui/hosts/static/mojoui-widgets.d.ts" />
import { Annotation, EditorState } from '@codemirror/state';
import { EditorView, keymap, placeholder } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';

type Props = { doc?: string; rev?: number; placeholder?: string };
type Host = HTMLElement & { mojouiView?: EditorView; mojouiRev?: number };

const fromMojo = Annotation.define<boolean>();  // (a change Mojo made: not sent back as an edit)

mojoui.defineWidget<Props, Host>({
  tag: 'mx-editor',
  events: ['change'],
  description: 'The note, in a CodeMirror 6 text editor',
  mount(el, props, emit) {
    el.mojouiRev = props.rev ?? 0;
    const sendEdits = EditorView.updateListener.of(u => {
      if (u.docChanged && !u.transactions.some(t => t.annotation(fromMojo))) emit('change', { text: u.state.doc.toString() }, { latest: true });
    });
    el.mojouiView = new EditorView({
      parent: el,
      state: EditorState.create({
        doc: props.doc ?? '',
        extensions: [history(), keymap.of([...defaultKeymap, ...historyKeymap]), placeholder(props.placeholder ?? ''),
          EditorView.lineWrapping, EditorView.contentAttributes.of({ 'aria-label': 'Note' }), sendEdits],
      }),
    });
  },
  update(el, props) {
    const view = el.mojouiView;
    if (!view || props.rev === undefined || props.rev === el.mojouiRev) return;
    el.mojouiRev = props.rev;
    const doc = props.doc ?? '';
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: doc }, selection: { anchor: doc.length }, annotations: fromMojo.of(true) });
  },
  destroy(el) {
    el.mojouiView?.destroy();
    el.mojouiView = undefined;
  },
  commands: {
    focus(el) { el.mojouiView?.focus(); return true; },
    selection(el) { const s = el.mojouiView!.state.selection.main; return { anchor: s.anchor, head: s.head }; },
    text(el) { return { text: el.mojouiView!.state.doc.toString() }; },
  },
  fields: {
    text: { type: 'string', set(el, value: string) {  // (not from Mojo: the edit goes back to update() as typing does)
      const view = el.mojouiView;
      if (view) view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: value }, selection: { anchor: value.length } });
    } },
  },
  describe(el) {
    const v = el.mojouiView;
    if (!v) return { text: 'no editor' };
    const doc = v.state.doc.toString();
    return { text: `${doc.length} characters, cursor at ${v.state.selection.main.head}: ${JSON.stringify(doc.slice(0, 80))}`,
             value: doc, lines: v.state.doc.lines, characters: doc.length, cursor: v.state.selection.main.head };
  },
});
