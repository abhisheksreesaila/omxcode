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
    /** One line about its state, for tests and agents. */
    describe?(el: E): string;
  }
  function defineWidget<P = Record<string, unknown>, E extends HTMLElement = HTMLElement>(spec: Widget<P, E>): void;
}
