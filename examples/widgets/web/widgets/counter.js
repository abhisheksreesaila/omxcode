// mx-counter: a tiny counter widget in plain JavaScript, vendored with the app (no npm package): goal 34's first widget.
// Its own state is its count (Mojo never sends it); its props are a label and a step; each click emits "click"
// {count, step}; the command "read" answers {count, step}. Text goes in with textContent only: a label is never HTML.
// Agents read its count (describe) and may set it (the field count, an integer): the widget then emits "change" {count, step}.
mojoui.defineWidget({
  tag: 'mx-counter',
  events: ['click', 'change'],
  description: 'A counter: its count is its own; each click adds its step',
  mount(el, props, emit) {
    el.count = 0;
    el.emit = emit;
    el.step = Number(props.step) || 1;
    const label = document.createElement('span');
    label.className = 'label';
    label.textContent = String(props.label ?? '');
    const count = document.createElement('output');
    count.className = 'count';
    count.textContent = '0';
    const inc = document.createElement('button');
    inc.type = 'button';
    inc.className = 'inc';
    inc.textContent = `+${el.step}`;
    inc.addEventListener('click', () => {
      el.count += el.step;
      count.textContent = String(el.count);
      emit('click', { count: el.count, step: el.step });
    });
    el.append(label, count, inc);
  },
  update(el, props) {  // new props from Mojo: the count (the widget's own state) stays
    el.step = Number(props.step) || 1;
    el.querySelector('.label').textContent = String(props.label ?? '');
    el.querySelector('.inc').textContent = `+${el.step}`;
  },
  commands: {
    read(el) { return { count: el.count, step: el.step }; },
  },
  fields: {
    count: { type: 'integer', set(el, value) {
      el.count = value;
      el.querySelector('.count').textContent = String(el.count);
      el.emit('change', { count: el.count, step: el.step });
    } },
  },
  describe(el) {
    return { text: `count ${el.count}, step ${el.step}, label ${el.querySelector('.label').textContent}`, value: el.count, count: el.count, step: el.step };
  },
});
