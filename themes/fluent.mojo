# Fluent 2 (Microsoft's design system) as a mojoui theme: neutral greys, the brand blue, 4/8 px corners, soft
# elevation; light. The analytics showcase's look.
#
#   def theme(self) -> Theme: return fluent()

from mojoui.canvas import rgba
from mojoui.theme import Palette, Theme
from mojoui.theme import Look


# Fluent 2 tokens for GTK (apps whose design() is FLUENT): neutral greys, the brand blue as the accent,
# 4/8 px corners. Light theme. (Colours GTK can't take from CSS stay libadwaita's.)
comptime FLUENT_GTK = """
:root { --accent-bg-color: #0F6CBD; --accent-color: #0F6CBD; --accent-fg-color: #ffffff; }
window.fluent { background-color: #F7F7F8; color: #242424; font-size: 14px; }
window.fluent label.title-1 { font-size: 20px; font-weight: 600; letter-spacing: -0.01em; }
window.fluent label.title-4 { font-size: 14px; font-weight: 600; }
window.fluent label.caption { font-size: 12px; }
/* cards: white panels with a hairline and a soft lift */
window.fluent .mui-card { background-color: #ffffff; border-radius: 8px; padding: 12px 14px;
  box-shadow: 0 0 0 1px rgba(0,0,0,.06), 0 1px 2px rgba(0,0,0,.06), 0 4px 12px rgba(0,0,0,.04); }
/* islands: the chrome floating over the page */
window.fluent label.mui-tone-warn { color: #EA580C; } window.fluent label.mui-tone-good { color: #0F766E; }
window.fluent label.mui-tone-strong { font-weight: 700; } window.fluent label.mui-tone-accent { color: #0F6CBD; }
window.fluent .mui-card.mui-warn { background-color: #FFF7ED; box-shadow: inset 0 0 0 1px #FED7AA; }
window.fluent .mui-card.mui-good { background-color: #F0FDF4; box-shadow: inset 0 0 0 1px #BBF7D0; }
window.fluent .mui-island { background-color: #ffffff; border-radius: 10px; padding: 6px 10px; min-height: 32px;
  box-shadow: 0 0 0 1px rgba(0,0,0,.07), 0 6px 20px rgba(0,0,0,.10); }
/* the page: a quiet dotted canvas */
window.fluent .mui-board { background-color: #F7F7F8;
  background-image: radial-gradient(circle, #D6D6DA 1px, transparent 1.5px); background-size: 24px 24px; }
/* buttons: white with a hairline, semibold, 32 px; quiet ones have no fill until hovered */
window.fluent button { border-radius: 6px; min-height: 30px; padding: 2px 12px; font-weight: 600;
  background: #ffffff; color: #242424; box-shadow: inset 0 0 0 1px #D1D1D1; }
window.fluent button:hover { background: #F5F5F5; }
window.fluent button:active { background: #E0E0E0; }
window.fluent button.flat { background: transparent; box-shadow: none; font-weight: 500; color: #424242; }
window.fluent button.flat:hover { background: rgba(0,0,0,.05); }
window.fluent button.flat:active { background: rgba(0,0,0,.09); }
window.fluent button.image-button { min-width: 30px; padding: 2px 6px; }
window.fluent button.suggested-action { background: #0F6CBD; color: #ffffff; box-shadow: none; }
window.fluent button.suggested-action:hover { background: #115EA3; }
/* fields: white, hairline, Fluent's underline that turns blue on focus */
window.fluent entry, window.fluent textview, window.fluent dropdown > button { border-radius: 6px; background: #ffffff;
  box-shadow: inset 0 0 0 1px #D1D1D1, inset 0 -1px 0 0 #8A8A8A; font-weight: 400; }
window.fluent entry:focus-within { box-shadow: inset 0 0 0 1px #D1D1D1, inset 0 -2px 0 0 #0F6CBD; outline: none; }
window.fluent textview text { background: #ffffff; }
window.fluent dropdown > button { min-height: 30px; padding: 2px 10px; }
window.fluent dropdown > button:hover { background: #FAFAFA; }
window.fluent scrollbar slider { min-width: 8px; min-height: 8px; background-color: rgba(0,0,0,.28); }
"""


# Fluent 2 (Microsoft's design system) tokens, for apps whose design() is FLUENT: neutral greys,
# the brand blue, 4/8 px corners, the Segoe type ramp, soft elevation. Light theme.
comptime FLUENT_WEB = """
body.fluent { color-scheme: light; --accent: #0F6CBD; --danger: #C50F1F; --muted: #616161; --surface: #F0F0F0;
  --line: #E0E0E0; background: #F7F7F8; color: #242424;
  font: 14px/20px "Segoe UI Variable", "Segoe UI", "Adwaita Sans", Inter, system-ui, -apple-system, "Noto Sans", sans-serif; }
body.fluent .text.title { font-size: 28px; line-height: 36px; font-weight: 600; letter-spacing: 0; }
body.fluent .text.headline { font-size: 16px; line-height: 22px; font-weight: 600; }
body.fluent .text.caption { font-size: 12px; line-height: 16px; color: #616161; }
body.fluent .text { text-align: left; }
body.fluent button { border-radius: 6px; min-height: 32px; padding: 5px 12px; font-weight: 600; background: #fff;
  border: 1px solid #D1D1D1; transition: background .1s; }
body.fluent button:hover { filter: none; background: #F5F5F5; }
body.fluent button:active { transform: none; background: #E0E0E0; }
body.fluent button.prominent { background: #0F6CBD; border-color: transparent; color: #fff; }
body.fluent button.prominent:hover { background: #115EA3; }
body.fluent button.subtle { background: transparent; border-color: transparent; font-weight: 500; color: #424242; }
body.fluent button.subtle:hover { background: rgba(0,0,0,.05); }
body.fluent button.subtle:active { background: rgba(0,0,0,.09); }
body.fluent button.icon-only { padding: 5px 6px; min-width: 32px; justify-content: center; }
body.fluent select, body.fluent input[type=text], body.fluent input[type=date], body.fluent textarea { border-radius: 6px; min-height: 32px;
  border: 1px solid #D1D1D1; border-bottom-color: #8A8A8A; background: #fff; }
body.fluent input[type=text]:focus, body.fluent textarea:focus { outline: none; border-bottom: 2px solid #0F6CBD; }
body.fluent label.toggle { min-height: 32px; }
body.fluent .segmented, body.fluent .tabs { background: transparent; padding: 0; gap: 4px; }
body.fluent .segmented span, body.fluent .tabs span { min-height: 32px; padding: 0 12px; border-radius: 4px; font-weight: 400; color: #424242; }
body.fluent .segmented input:checked + span, body.fluent .tabs input:checked + span { background: #EBF3FC; color: #0F6CBD;
  box-shadow: inset 0 0 0 1px #B4D6FA; font-weight: 600; }
body.fluent .vstack.card { background: #fff; border-radius: 8px; padding: 12px 14px; box-sizing: border-box;
  box-shadow: 0 0 0 1px rgba(0,0,0,.06), 0 1px 2px rgba(0,0,0,.06), 0 4px 12px rgba(0,0,0,.04); }
body.fluent .island > * { background: #fff; border-radius: 10px; padding: 6px 10px; min-height: 32px; align-items: center;
  box-shadow: 0 0 0 1px rgba(0,0,0,.07), 0 6px 20px rgba(0,0,0,.10); }
body.fluent .board { background-color: #F7F7F8; background-image: radial-gradient(circle, #D6D6DA 1px, transparent 1.5px);
  background-size: 24px 24px; }
body.fluent hr { border-top-color: #E0E0E0; }
body.fluent .lazylist { border-radius: 4px; border-color: #E0E0E0; background: #fff; }
body.fluent .lazylist .row { border-bottom-color: #F0F0F0; }
body.fluent .canvas { background: transparent; }
"""


def fluent() -> Theme:
    return Theme("fluent", "fluent", Palette.plain(), String(FLUENT_GTK), String(FLUENT_WEB), rgba(66, 66, 66), rgba(255, 255, 255), False, Look.none())
