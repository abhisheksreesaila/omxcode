# agentchat: a chat on an AG-UI agent (goal 35 M3; goal 48 M3: a thin app over mojoui.agentchat). The agent streams its
# words, and builds UI in the conversation by calling the frontend tool render_ui with data from the component catalog
# (mojoui.genui validates and renders it natively; anything outside the catalog is refused and the agent is told why).
#
#   scripts/agentchat.sh             the scripted agent (deterministic) and the app on GTK
#   docs/agui.md                     the live agent: the OMX Console's local models, or Claude

from mojoui.view import View
from mojoui.app import App, Event
from mojoui.canvas import Surface
from mojoui.theme import Theme
from mojoui.http import Request
from mojoui.shared import environment
from mojoui.agentchat import AgentChat, CHAT_PANEL
from mojoui.agui import Tool
from mojoui.sheet import Sheet
from mojoui.sheethub import SheetHub
from themes.omxqua import omxqua
from omxcore import Table, TEXT, DECIMAL, INT


def orders(rows: Int) -> Sheet:
    """`rows` made-up orders (region, product, units, revenue): the dataset the agent names and never receives."""
    try:
        var t = Table.empty()
        var region = t.add_column("region", TEXT)
        var product = t.add_column("product", TEXT)
        var units = t.add_column("units", INT)
        var revenue = t.add_column("revenue", DECIMAL, 2)
        var regions: List[String] = ["North", "South", "East", "West", "Central"]
        var products: List[String] = ["Trail shoe", "Rain shell", "Day pack", "Wool socks", "Fleece", "Water bottle", "Headlamp", "Trek poles"]
        var rc = List[Int64]()
        var pc = List[Int64]()
        for r in regions:
            rc.append(Int64(t.add_word(region, r)))
        for p in products:
            pc.append(Int64(t.add_word(product, p)))
        var x: UInt64 = 88172645463325252
        for _ in range(rows):
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            t.append(region, rc[Int(x % 5)])
            t.append(product, pc[Int((x >> 5) % 8)])
            t.append(units, Int64(Int((x >> 20) % 9) + 1))
            t.append(revenue, Int64(Int((x >> 8) % 50_000)))
        return Sheet(t^.share(), True)
    except:
        return Sheet(Table.empty().share(), False)


struct Main(App):
    comptime HTTP = True
    var chat: AgentChat[SheetHub]
    var themed: Theme

    def __init__(out self):
        var url = environment("AGUI_URL")
        self.chat = AgentChat[SheetHub](url if url != "" else String("http://127.0.0.1:8765/"), base=20_000, canvas_base=2000, layout=CHAT_PANEL,
                              title="Agent chat", welcome="Ask for a chart, a form, a trip or a dashboard.", show_url=True)
        self.chat.suggest("Hello")
        self.chat.suggest("Show me sales as a chart")
        self.chat.suggest("Make me a signup form")
        self.chat.suggest("Chart a million orders")
        var hub = SheetHub()
        var rows = environment("AGENTCHAT_ORDERS")  # (scripts/agui_bench.py: 0, so its memory is the chat's alone)
        var n = 1_000_000
        try:
            n = Int(rows) if rows != "" else 1_000_000
        except:
            pass
        if n > 0:
            hub.add("orders", orders(n))  # (~0.3 s at start for a million; the agent hears of it in each run's context)
        self.chat.set_hub(hub^)
        self.chat.offer(Tool("refund_order", "Refund an order", '{"type":"object","properties":{"order":{"type":"string"},"amount":{"type":"number"},"reason":{"type":"string"}},"required":["order","amount"]}'), confirm=True)
        self.themed = omxqua(False)

    def title(self) -> String:
        return "agentchat"

    def window_size(self) -> Tuple[Int, Int]:
        return (980, 820)

    def appearance(mut self, dark: Bool):
        self.themed = omxqua(dark)

    def theme(self) -> Theme:
        return self.themed.copy()

    def requests(mut self) -> List[Request]:
        return self.chat.requests()

    def update(mut self, e: Event):
        _ = self.chat.update(e)

    def draw(mut self, canvas: Int, mut surface: Surface):
        self.chat.draw(canvas, surface, self.themed.palette)

    def view(self) -> View:
        return self.chat.view().padding(28)
