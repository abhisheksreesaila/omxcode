# Ribbon sample (goal 76 M1): mojoui.ribbon on its own, in Liquid: Home · Insert · View tabs, captioned groups, small
# toggles, a file picker, a docked panel that opens from the View tab and closes from its ✕ (or the tab again), the
# File menu leading with the other menus hidden (their shortcuts still fire), compact under 900 pt.
# The same file on GTK, the web and the Mac.

from mojoui import App, Event, View, VStack, HStack, Text, Spacer, Icon, TITLE, CAPTION, HEADLINE, CENTER, STRETCH
from mojoui.menus import MenuBar, Menu, Item, Separator
from mojoui.ribbon import Ribbon, RibbonTab, ribbon_tab, ribbon_group, ribbon_tool, ribbon_picker, ribbon_toggle
from mojoui.inspector import Inspector, Section, Row
from mojoui.theme import Theme
from themes.liquid import liquid

comptime TAB = 100  # + the tab's index
comptime SAVE = 1
comptime UNDO = 2
comptime BOLD = 3
comptime ITALIC = 4
comptime PICK = 5
comptime CHART = 6
comptime NOTE = 7
comptime PANEL = 8
comptime CLOSE = 9
comptime NEW = 10
comptime COMPACT_W = 900


struct Main(App):
    var tab: Int
    var said: String
    var bold: Bool
    var italic: Bool
    var panel: Bool
    var width: Int
    var dark: Bool

    def __init__(out self):
        self.tab = 0
        self.said = "Nothing yet"
        self.bold = False
        self.italic = False
        self.panel = False
        self.width = 1200
        self.dark = False

    def title(self) -> String:
        return "Ribbon"

    def theme(self) -> Theme:
        return liquid(self.dark)

    def appearance(mut self, dark: Bool):
        self.dark = dark

    def resize(mut self, width: Int, height: Int):
        self.width = width

    def update(mut self, event: Event):
        var m = event.message
        if m >= TAB and m < TAB + 10:
            self.tab = m - TAB
            return
        if m == BOLD:
            self.bold = not self.bold
        elif m == ITALIC:
            self.italic = not self.italic
        elif m == PANEL:
            self.panel = not self.panel
        elif m == CLOSE:
            self.panel = False
        var names: List[String] = ["", "Save", "Undo", "Bold", "Italic", "Picked " + event.text, "Chart", "Note", "Panel", "Close", "New"]
        if 0 < m < len(names):
            self.said = names[m]
            print("RIBBON: " + names[m], flush=True)

    def ribbon(self) -> View:
        var tabs: List[RibbonTab] = [
            ribbon_tab("Home", [ribbon_group("Document", [ribbon_tool("Save", "save", SAVE, "Save (Ctrl+S)"), ribbon_tool("Undo", "undo", UNDO, "Undo (Ctrl+Z)")]),
                                ribbon_group("Font", [ribbon_toggle("Bold", "bold", BOLD, self.bold, "Bold (Ctrl+B)"), ribbon_toggle("Italic", "italic", ITALIC, self.italic, "Italic (Ctrl+I)")])]),
            ribbon_tab("Insert", [ribbon_group("From a file", [ribbon_picker("Table", "table", PICK, ".csv,.parquet", "A table from a CSV or Parquet file", tag="insert-table")]),
                                  ribbon_group("Make", [ribbon_tool("Chart", "chart-bar", CHART), ribbon_tool("Note", "note", NOTE)])]),
            ribbon_tab("View", [ribbon_group("Panels", [ribbon_tool("Details", "view", PANEL, "Show or hide the details panel", on=self.panel)])]),
        ]
        var menus = MenuBar([
            Menu("File", [Item("New", NEW, icon="file", shortcut="Ctrl+N"), Separator(), Item("Save", SAVE, icon="save", shortcut="Ctrl+S")]),
            Menu("Edit", [Item("Undo", UNDO, shortcut="Ctrl+Z")]).hidden(),  # (its shortcut, not a row: the ribbon has Undo)
            Menu("Format", [Item("Bold", BOLD, shortcut="Ctrl+B"), Item("Italic", ITALIC, shortcut="Ctrl+I")]).hidden(),
        ])
        var mark = HStack(Icon("app-logo", 18), Text("Ribbon", HEADLINE), spacing=6).align(CENTER).tag("app-mark")
        return Ribbon(tabs, self.tab, TAB, leading=[mark^, menus^], trailing=[Text(self.said, CAPTION).tag("said")], compact=self.width < COMPACT_W)

    def view(self) -> View:
        var page = VStack(Text("A page", TITLE), Text("Last: " + self.said + (" · bold" if self.bold else "") + (" · italic" if self.italic else "")),
                          Spacer(), spacing=12).padding(24).grow().align(STRETCH)
        var row = HStack(page^, Inspector(["Details"], 0, 0, [Section("Details", [Row("Bold", Text("yes" if self.bold else "no"))])], 280, on_close=CLOSE), spacing=0) if self.panel else HStack(page^, spacing=0)
        return VStack(self.ribbon(), row^.align(STRETCH).fill().grow(), spacing=0).fill().grow()
