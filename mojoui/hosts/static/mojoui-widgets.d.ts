// Types for widgets written in TypeScript (mojoui/hosts/static/mojoui-widgets.js is the implementation; docs/js.md).
// Reference it from a widget: /// <reference path="<relative path to>/mojoui/hosts/static/mojoui-widgets.d.ts" />
// (esbuild strips types without checking them; an editor or `tsc --noEmit` reads this file.)
declare namespace mojoui {
  /** Sends an event to the app's update(): event.name = name, event.text = JSON.stringify(payload), event.id = the widget's id.
   *  latest: an unsent event of the same name from this widget is replaced (a whole text, a position). */
  type Emit = (name: string, payload?: unknown, options?: { latest?: boolean }) => void;
  interface Widget<P = Record<string, unknown>, E extends HTMLElement = HTMLElement> {
    /** The custom element's name: lower case, with a hyphen (mx-name). WebComponent(tag, …) in Mojo places it. */
    tag: string;
    /** The events it may emit (others are refused). */
    events?: string[];
    /** Once per widget, when it first appears: build its DOM inside el (textContent, never innerHTML with props). */
    mount(el: E, props: P, emit: Emit): void;
    /** New props from Mojo (the element and its own state stay). */
    update?(el: E, props: P): void;
    /** It left the screen for good. */
    destroy?(el: E): void;
    /** Commands Mojo can call (mojoui.webcomponent.Command): the value returned (or resolved) is the JSON reply. */
    commands?: Record<string, (el: E, args: any) => unknown>;
    /** What it shows, as JSON data for agents and tests: text is one line about it, value its value (an editor's text, a
     *  count), anything else it wants to say (lines, a series). A string is read as {text}. Without describe, an agent
     *  sees the widget by its tag with "no description". */
    describe?(el: E): Description | string;
    /** The app's theme changed (or it just mounted): restyle in place from the Look's tokens (data). The same values are
     *  CSS variables on the page (--o-card, --o-ink, --o-font, --o-radius-card…) for the widget's sheet. */
    theme?(el: E, tokens: Tokens): void;
    /** It has nothing focusable inside but should be a Tab stop (a chart): the element itself takes the keyboard
     *  (tabindex 0, its description as its label); handle keys in mount. */
    focusable?: boolean;
    /** What it is, for an agent's tool (one sentence). */
    description?: string;
    /** What an agent may set: name → its JSON type and the setter. The host refuses any other name or type; set() changes
     *  the widget and the widget reports it as its own event (emit), so update() hears it as from a person. */
    fields?: Record<string, Field<E>>;
  }
  interface Tokens {
    id: string; dark: boolean;
    palette: { page: string; card: string; raised: string; ink: string; ink2: string; ink3: string; line: string; strong: string;
               accent: string; on_accent: string; wash: string; good: string; bad: string; warn: string; data: string[] };
    font: { family: string; mono: string; size: number; caption: number; line: number };
    corners: { card: number; button: number; field: number };
  }
  /** The tokens the host last handed the widgets (null before the first). */
  const tokens: Tokens | null;
  type JsonType = 'string' | 'number' | 'integer' | 'boolean' | 'array' | 'object';
  interface Description { text?: string; value?: unknown; [more: string]: unknown }
  interface Field<E extends HTMLElement = HTMLElement> { type: JsonType; set(el: E, value: any): void | Promise<void> }
  /** Tell the host the widget's description changed (emits, mounts, updates and commands already do). */
  function tell(): void;
  function defineWidget<P = Record<string, unknown>, E extends HTMLElement = HTMLElement>(spec: Widget<P, E>): void;
}
