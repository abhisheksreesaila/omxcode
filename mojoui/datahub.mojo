# mojoui.datahub: datasets an app holds for its agent's UI (goal 48 M5). A DataGrid or ChartView an agent builds may
# name a dataset instead of carrying rows, so an agent shows a million rows it never sends. The UI pieces (mojoui.genui,
# agentui, agentchat) are generic over a Hub; NoData (the default) holds none, so an app that doesn't use datasets links
# no engine. mojoui.sheethub's SheetHub holds MX frame sheets (the GPU when there is one).

from mojoui.datagrid import DataGrid
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.app import Event


@fieldwise_init
struct Grouped(Copyable, Movable):
    """A chart's numbers from a dataset: a label and a value per group, what it cost, or why it couldn't."""

    var labels: List[String]
    var values: List[Float64]
    var note: String  # "1,000,000 rows · 2.1 ms on the GPU"
    var problem: String  # "" when it worked


trait Hub(Copyable, Movable, Defaultable, Deinitable):
    def find(self, name: String) -> Int:
        """The dataset called `name` (-1: none)."""
        ...

    def names_text(self) -> String:
        """Its datasets' names, for a message ("orders, trips"; "none")."""
        ...

    def name(self, k: Int) -> String:
        ...

    def rows(self, k: Int) -> Int:
        ...

    def describe(self) -> String:
        """The datasets for the agent (a run's context): [{name, rows, columns: [{name, kind}]}]."""
        ...

    def group(self, k: Int, group_by: String, value: String, how: String, top: Int) -> Grouped:
        """`how` (sum, average or count) of number column `value` per value of text column `group_by`, the largest
        `top` groups first."""
        ...

    def draw_grid(self, k: Int, mut grid: DataGrid, mut s: Surface, font: Font, p: Palette):
        ...

    def handle_grid(self, k: Int, mut grid: DataGrid, e: Event, font: Font, p: Palette):
        ...


struct NoData(Hub):
    """No datasets (the default): a UI that names one is refused, saying so."""

    def __init__(out self):
        pass

    def find(self, name: String) -> Int:
        return -1

    def names_text(self) -> String:
        return "none"

    def name(self, k: Int) -> String:
        return ""

    def rows(self, k: Int) -> Int:
        return 0

    def describe(self) -> String:
        return "[]"

    def group(self, k: Int, group_by: String, value: String, how: String, top: Int) -> Grouped:
        return Grouped(List[String](), List[Float64](), "", "no datasets")

    def draw_grid(self, k: Int, mut grid: DataGrid, mut s: Surface, font: Font, p: Palette):
        pass

    def handle_grid(self, k: Int, mut grid: DataGrid, e: Event, font: Font, p: Palette):
        pass
