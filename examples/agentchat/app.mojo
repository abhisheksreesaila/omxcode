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
from themes.omxqua import omxqua


struct Main(App):
    comptime HTTP = True
    var chat: AgentChat
    var themed: Theme

    def __init__(out self):
        var url = environment("AGUI_URL")
        self.chat = AgentChat(url if url != "" else String("http://127.0.0.1:8765/"), base=20_000, canvas_base=2000, layout=CHAT_PANEL,
                              title="Agent chat", welcome="Ask for a chart, a form, a trip or a dashboard.", show_url=True)
        self.chat.suggest("Hello")
        self.chat.suggest("Show me sales as a chart")
        self.chat.suggest("Make me a signup form")
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
