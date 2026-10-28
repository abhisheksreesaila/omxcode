#!/usr/bin/env bash
# A new JavaScript widget from the template (docs/js.md).
#   scripts/new_widget.sh <name> [<app>] [--ts]     e.g. scripts/new_widget.sh price-chart widgets
# Writes examples/<app>/web/widgets/<name>.js (or .ts with --ts): the custom element mx-<name>, which shows its "label"
# prop, emits "ping" {pings} when its button is clicked and answers the command "read" with {pings}. Then, in Mojo:
#   WebComponent("mx-<name>", Props().text("label", "Hello"), on_event=PING, id=1)     (mojoui.webcomponent)
#   web_assets() -> ["<name>.js"]
# and scripts/build.sh <app> web bundles it.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="" APP="widgets" EXT="js"
for a in "$@"; do
  case "$a" in
    --ts) EXT="ts" ;;
    -*) echo "unknown option $a" >&2; exit 2 ;;
    *) if [ -z "$NAME" ]; then NAME="$a"; else APP="$a"; fi ;;
  esac
done
[[ "$NAME" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || { echo "usage: scripts/new_widget.sh <name: lower case, digits, hyphens> [<app>] [--ts]" >&2; exit 2; }
[ -d "examples/$APP" ] || { echo "no examples/$APP" >&2; exit 2; }
DIR="examples/$APP/web/widgets"
OUT="$DIR/$NAME.$EXT"
[ -e "$DIR/$NAME.js" ] || [ -e "$DIR/$NAME.ts" ] && { echo "$DIR/$NAME.js or .ts exists already" >&2; exit 1; }
mkdir -p "$DIR"
TAG="mx-$NAME"
if [ "$EXT" = ts ]; then
  TYPES='/// <reference path="../../../../mojoui/hosts/static/mojoui-widgets.d.ts" />
type Props = { label?: string };
type Host = HTMLElement & { pings: number };
'
  DEFINE="mojoui.defineWidget<Props, Host>({"
else
  TYPES=""
  DEFINE="mojoui.defineWidget({"
fi
cat > "$OUT" <<EOF
// $TAG: made by scripts/new_widget.sh (docs/js.md). Props: label. Emits "ping" {pings}. Command: read → {pings}.
// Text goes in with textContent only: props are data, never HTML.
${TYPES}${DEFINE}
  tag: '$TAG',
  events: ['ping'],
  mount(el, props, emit) {
    el.pings = 0;
    const label = document.createElement('span');
    label.className = 'label';
    label.textContent = String(props.label ?? '');
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Ping';
    button.addEventListener('click', () => emit('ping', { pings: ++el.pings }));
    el.append(label, button);
  },
  update(el, props) {
    el.querySelector('.label')!.textContent = String(props.label ?? '');
  },
  destroy(el) {},
  commands: {
    read(el) { return { pings: el.pings }; },
  },
  describe(el) { return \`label \${el.querySelector('.label')!.textContent}, pings \${el.pings}\`; },
});
EOF
if [ "$EXT" = js ]; then sed -i 's/)!\./)./g' "$OUT"; fi  # (the non-null marks are TypeScript's)
echo "wrote $OUT ($TAG)"
echo "Mojo: WebComponent(\"$TAG\", Props().text(\"label\", \"Hello\"), on_event=YOUR_MSG, id=1); web_assets() lists \"$NAME.js\""
