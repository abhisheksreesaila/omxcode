# omxplorer: open your data, shape it, report on it, on your GPU. A Numbers-style data app built only from
# omxcode (mojoui) components, following the Stitch "classic" designs (docs/design/mxstudio-app/):
#   Start  → choose a file (or the sample, or a blank table)
#   Import → the columns as read, with their types and shapes, before the table exists
#   Sheet  → a toolbar for the tab you're on (the sheet's tools and formats, or the Report's tiles and filter), the formula
#            bar, the table, the inspector, the tabs along the bottom (Excel's way: tap the current one to rename it),
#            the status bar

from mojoui.view import (View, Text, Button, FilePicker, TextField, Canvas, Board, VStack, HStack, Card, Spacer, Divider,
                         Dropdown, Segmented, Toggle, Tabs, Grid, Scroll, Icon, HEADLINE, CAPTION, TITLE, PROMINENT, SUBTLE, START, CENTER, END,
                         BETWEEN, STRETCH, CARD, CARD_WARN, CARD_GOOD, TONE_ACCENT, TONE_GOOD, TONE_WARN, TONE_STRONG, NO_MSG, TOOL, TOOL_INLINE, ICON_ONLY)
from mojoui.app import App, Event
from mojoui.scene import Scene
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.theme import Palette, Theme, hx, hex_of
from themes.liquid import liquid, liquid_palette, dark_tint
from themes.skins import skin, ledger_palette, graphite_palette, blueprint_palette
from mojoui.menus import MenuBar, Menu, Item, Separator, Submenu, ContextMenu
from mojoui.overlays import Dialog, Toast, Popover, Checkbox, Clipboard
from mojoui.view import Radio, TextArea

# omxplorer's skins (themes/: the framework knows none of them, D-260) and its brand (owner, D-254): indigo for the app
# itself, a tint per mode
comptime LEDGER = 3
comptime GRAPHITE = 4
comptime BLUEPRINT = 5
comptime LIQUID = 6  # the default (D-225)
comptime BRAND_INDIGO: UInt32 = 0xFFE5464F  # #4f46e5 (R in the low byte)
comptime SHEET_GREEN: UInt32 = 0xFF437A0E  # #0e7a43
comptime REPORT_RED: UInt32 = 0xFF3F24C8  # #c8243f
comptime LIGHT = 0  # the appearance (Settings → Appearance, settings.txt appearance=light|dark|system): Liquid light,
comptime DARK = 1  # Liquid dark (the default, owner 2026-10-30: "we can do Liquid dark mode", D-1241), or the system's
comptime SYSTEM = 2


def skin_name(design: Int) -> String:
    """The skin's name in settings.txt and CSS classes ("ledger")."""
    return "ledger" if design == LEDGER else ("graphite" if design == GRAPHITE else ("blueprint" if design == BLUEPRINT else "liquid"))


def skin_of(name: String) -> Int:
    """A settings.txt skin name back to its skin (Liquid when unknown: the default, D-225)."""
    return LEDGER if name == "ledger" else (GRAPHITE if name == "graphite" else (BLUEPRINT if name == "blueprint" else LIQUID))


def skin_palette(design: Int, accent: UInt32 = 0, dark: Bool = False) -> Palette:
    """The skin's colours with a mode's tint over them (in a report, red only means "a report": false and errors take
    other tones, D-254). `dark`: Liquid dark, the tint lifted to read on its surfaces (the other skins have one look)."""
    var liq = liquid_palette(dark)
    var p = (ledger_palette() if design == LEDGER else (graphite_palette() if design == GRAPHITE else (blueprint_palette() if design == BLUEPRINT else liq^))).with_accent(
        dark_tint(accent) if dark and design == LIQUID and accent != 0 else accent)
    if accent == REPORT_RED:
        p.bad = hx("#9f6b75") if not p.dark else hx("#c99aa3")
    return p^


def skin_theme(design: Int, accent: UInt32, dark: Bool = False) -> Theme:
    var pal = skin_palette(design, accent, dark)
    return liquid(pal) if design == LIQUID else skin(skin_name(design), pal)


def appearance_of(name: String) -> Int:
    """settings.txt's appearance back to LIGHT, DARK or SYSTEM (dark when unset: omxplorer's default, D-1241)."""
    return LIGHT if name == "light" else (SYSTEM if name == "system" else DARK)
from mojoui.view import SECONDARY
from mojoui.charts import grouped, fixed
from mojoui.numformat import fixed as numfixed, pow10


def money2(x: Float64) -> String:
    """x with two decimal places and thousands separators (rounded half away from zero), a minus when negative."""
    var a = x if x >= 0 else -x
    return ("-" if x < 0 else "") + numfixed(Int64(a * 100.0 + 0.5), 2, 2, True)
from mojoui.datagrid import (DataGrid, GRID_SELECTED, GRID_COLUMN, GRID_EDIT, GRID_READ_ONLY, GRID_REDRAW, GRID_FITTED, GRID_RESIZED,
                             GRID_TYPED, GRID_CLEAR, GRID_CANCEL, GRID_COMMIT)
from mojoui.sheet import Sheet, placeholder_sheet, blank_table, INT, DECIMAL, TEXT, DATE, BOOL
from mojoui.shared import environment, make_dir
from mojoui.files import file_name, file_stem, file_size, file_exists, read_recent, remember, read_setting, write_setting, adopt_config
from mojoui.csvio import read_table, empty_import, CsvImport, CsvColumn, kind_name
from mojoui.omxfile import save_omx, open_document
from mojoui.numformat import (ColumnFormat, format_number, AUTO, NUMBER, CURRENCY, PERCENT, COMPACT, DATE_LONG, DATE_MONTH, DATE_ISO,
                              NUMBER_STYLES, DATE_STYLES)
from mojoui.inspector import Inspector, Section, Row, Stepper, StatCards, NavRow, InspectorPage
from mojoui.sheetchrome import Tool, Toolbar, FormulaBar, StatusBar, Tab, BottomTabs, AppBar, Rail
from mojoui.cellstyle import (CellStyle, BOLD, ITALIC, UNDERLINE, STRIKE, INK_MASK, FILL_MASK, ALIGN_MASK, ink_bits, fill_bits, align_bits,
                              AUTO_ALIGN, ALIGN_LEFT, ALIGN_CENTRE, ALIGN_RIGHT, SWATCH_NAMES, swatch_name)
from mojoui.swatches import SwatchPicker, draw_swatches, swatch_at
from mojoui.sheetpage import (SheetObject, compute, shape_of, chart_view, chart_text, object_card, readout, free_spot, object_title, groups_of, OBJ_CHART, OBJ_PIVOT,
                              CHART_BAR, CHART_LINE, HEADER_H, chart_words, chart_choices, apply_choice, chosen, chart_sentence, SLOT_NAMES, slot_text,
                              number_columns, text_columns, COMBINES, ORDERS, TOPS, SLOT_COMBINE, SLOT_VALUE, SLOT_GROUP, SLOT_ORDER, SLOT_TOP,
                              SLOT_FILTER, SLOT_MARK, COMBINE_COUNT, start_move, MOVE_FRAMES, NUM_ANY, NUM_OVER, NUM_UNDER, NUM_BETWEEN,
                              NUM_AT_LEAST, NUM_AT_MOST, number_words, PART_NONE)
from mojoui.numformat import parse_decimal
from mojoui.sentence import Sentence
from mojoui.chartask import ask, ask_reply
from mojoui.reportpage import (ReportTile, ReportFilter, ReportPage, KpiTile, ChartTile, AddTile, new_tile, compute_tile, kpi_of, tile_fact, TILE_SUM, TILE_AVERAGE, TILE_COUNT,
                               TILE_CHART, TILE_DISTINCT, TILE_MEDIAN, TILE_LAST, TILE_NAMES)
from mojoui.chartview import ChartView
from mojoui.view import TAP, PAN, ZOOM, PRESS, RELEASE
from mojoui.sample import sample_table
from mojoui.island import Island, Activity, IslandView, HIT_BODY, HIT_ACTION, IDLE as ISLAND_IDLE, RUNNING as ISLAND_RUNNING, UNDO as ISLAND_UNDO, ERROR as ISLAND_ERROR
from mojoui.tablejobs import TableWork, TableFile, Answer
from mojoui.sheetjobs import warm_gpu, ChartQueue, ColumnFigures, column_job, take_numbers, Opened, open_job, pace, stopped, Job, JOB_RUNNING, JOB_DONE
from mojoui.clock import now_ns, shown_ms
from mojoui.draw import rect as draw_rect, with_alpha
from mojoui.mediacard import MediaCards, CardAction, OBJ_VIDEO, OBJ_IMAGE, VIDEO_TYPES, IMAGE_TYPES, is_media_file, is_video_file
from mojoui.tablecard import TableCards, sql_name, ACTION_MIN_W
from mojoui.videocard import VideoWork
from mojoui.videojobs import expect_analysis, Analyzed, Reel, analyze_job, reel_job, analyzer_names, analyzer_note, analyzer_rows, marks_of, flag_frames, segments_of, flag_columns, matching_column, lookup, codes_of
from mojoui.videojobs import analyzer_needs_log, use_analysis, INSPECTION
from mojoui.mediatimeline import MediaTimeline, value_lane
from mojoui.mediatimeline_jobs import TimelineFeed
from mojoui.trackcard import TrackCards, is_track, series_from_sheet, metric_label, metric_unit
from mojoui.mapview import MapMark, MARK_PLACE, MARK_FINDING
from mojoui.inspection_tables import is_places, read_places, compare_job, flight_plan, place_marks
from mojoui.vision_presets import DRONE_MATCH_M
from mojoui.player import SCRUB as PLAYER_SCRUB
from mojoui.view import SET_TO
from mojoui.timeseries import TimeSeries
from mojoui.videotable import VideoTable
from mojoui.videoexport import flagged_captions, Caption
from mojoui.links import Links, LINK_KEY, LINK_TIME
from mojoui.linkdrag import LinkDrag, DropCard, column_values, match_columns, is_time_column
from mojoui.timelane import TimeLane
from mojoui.peek import Peek
from mojoui.datagrid import GRID_HEADER_DRAG, GRID_HEADER_DROP
from mojoui.links import Selection, CardRows, Follow, Reaction, Link, End, BY_AGENT, LINKS_ADD, REACT_SEEK, REACT_HIGHLIGHT, REACT_SELECT
from mojoui.asksql import AskBook, implied_sql, lineage
from mojoui.documentset import DocumentSet, SET_MESSAGES
from mojoui.documentjobs import FolderFeed, open_folder_job
from mojoui.pygil import python_reclaim
from mojoui.ocrmodel import OcrModel
from mojoui.pdfsource import Box
from mojoui.texttable import TextTable
from mojoui.pack import Pack, PackJob, Clip, Packed
from mojoui.jobs import start_ui_job

# screens
comptime START_SCREEN = 0
comptime IMPORT = 1
comptime SHEET = 2

# messages
comptime PICK = 1  # a FilePicker returned a path (event.text)
comptime SAMPLE = 2
comptime BLANK = 3
comptime CREATE = 4  # Import → the sheet
comptime BACK = 5
comptime GRID = 6  # the table's canvas
comptime CELL_COMMIT = 7
comptime CELL_CANCEL = 8
comptime FX_COMMIT = 9  # the formula bar's Enter
comptime INSP_TAB = 10
comptime FORMAT = 11
comptime DECIMALS_LESS = 12
comptime DECIMALS_MORE = 13
comptime THOUSANDS = 14
comptime NEGATIVES = 15
comptime SYMBOL = 16
comptime ADD_ROW = 17
comptime BLOCK_CAP = 100_000  # a block's cells read one by one (its figures, Copy, a format) at most: larger blocks say so
comptime COPY = 28  # Edit > Copy (Ctrl+C): the selected cell or block, as tab-separated text
comptime NEW_FORMULA = 18
comptime FORMULA_SUBMIT = 19
comptime SORT = 20
comptime UNDO = 21
comptime TOGGLE_INSPECTOR = 22
comptime SAVE = 24
comptime IMPORT_COLUMN = 23  # Import: the column whose details show
comptime RECENT = 40  # + index (40–49): open a recent file
comptime INSERT_CHART = 25
comptime INSERT_PIVOT = 26
comptime MOVE = 27  # a sheet object dragged by its title bar
comptime CHART_STYLE = 29
comptime OBJ_VALUE = 30
comptime OBJ_GROUP = 31
comptime OBJ_ACROSS = 32
comptime REPORT_COL = 33
comptime FILTER_COL = 34
comptime FILTER_VALUE = 35
comptime ADD_TILE = 50  # + TILE_SUM … TILE_LAST (50–55)
comptime OBJ_TAP = 100  # + object: its chart's canvas
comptime OBJ_CLOSE = 200  # + object
comptime OBJ_PICK = 300  # + object: show it in the inspector
comptime TILE_TAP = 400  # + tile: a chart tile's canvas
comptime TILE_CLOSE = 500  # + tile
comptime RESIZE = 36  # a sheet object (or the table) resized by its corner
comptime SORT_ASC = 37  # the menus' sorts (the context menu's column, else the selected one)
comptime SORT_DESC = 38
comptime MENU_CLOSE = 39  # the context menu dismissed
comptime SETTINGS = 64  # File > Settings…
comptime ABOUT = 65  # Help > About omxplorer
comptime SHOW_REPORT = 66  # View > Report / Sheet
comptime SHOW_SHEET = 67
comptime FMT_NUMBER = 68  # Format as ▸ (the context menu's column, else the selected one)
comptime FMT_CURRENCY = 69
comptime FMT_PERCENT = 70
comptime UNDO_SORT = 71  # the sort toast's Undo
comptime TOAST_CLOSE = 72
comptime SETTINGS_CLOSE = 73
comptime SKIN = 74  # Settings: the skin picked (event.number)
comptime TIMINGS = 75  # Settings: show GPU timings in the status bar
comptime KEEP_INSPECTOR = 76  # Settings: the inspector opens with a sheet
comptime ABOUT_CLOSE = 77
comptime FX_HELP = 78  # the formula bar's ƒx: what formulas can do
comptime HELP_CLOSE = 79
comptime STYLE_BOLD = 80  # the format toggles: the selected cell, or the whole column when a column is selected
comptime STYLE_ITALIC = 81
comptime STYLE_UNDERLINE = 82
comptime STYLE_STRIKE = 83
comptime STYLE_ALIGN = 84  # + AUTO_ALIGN … ALIGN_RIGHT (84–87)
comptime CLEAR_FORMAT = 88
comptime PICK_INK = 89  # open the text colour's swatches (a popover), or the fill's
comptime PICK_FILL = 90
comptime PICK_CLOSE = 91
comptime SWATCH = 92  # the swatches' canvas tapped
comptime TAB = 93  # + 0 (the sheet), 1 (the Report): a bottom tab tapped
comptime RENAME_TAB = 95  # Sheet > Rename tab…: the current tab's name becomes a field
comptime RENAME_SUBMIT = 96
comptime RENAME_CANCEL = 97
comptime PREVIEW = 98  # the import preview's gestures: it scrolls (it's read-only: taps and keys do nothing)
comptime WORD_CLOSE = 99  # a chart word's choices dismissed
comptime WORD = 1000  # + ref × 10 + slot: a word of a chart's sentence tapped (ref: a sheet chart 0…39, a Report chart tile 40…79)
comptime CHOICE = 1900  # + k (k < 100): one of the tapped word's choices picked
comptime TILE_REF = 40  # (a Report tile's ref: TILE_REF + its index)
comptime ASK_CHANGE = 2000  # the ask field typed in (past CHOICE's hundred)
comptime ASK_SUBMIT = 2001  # its Return: the phrase edits the chart
comptime ASK_H = 66  # the ask field and its reply, under a chart's sentence
comptime PAGE = 2010  # + 0 (the chart's own page) … 4: the chart inspector's pages (Data, Order, Rows, Style)
comptime INSP_SET = 2020  # + slot: an inspector control changed a chart setting (event.number: the choice)
comptime NUM_PICK = 2030  # the Rows page's number condition: its kind (event.number), its low and high values (Return)
comptime NUM_LO = 2031
comptime NUM_HI = 2032
comptime NUM_KINDS: List[String] = ["Any", "Over", "Under", "At least", "At most", "Between"]
comptime SET_INK = 600  # + 0 (automatic) … 8: the Format menu's text colours
comptime SET_FILL = 610  # + 0 (none) … 8
comptime SWATCH_CANVAS = 5  # the swatches' canvas id
comptime ISLAND_CANVAS = 7  # the island's canvas id (the menu bar's living status, mojoui.island)
comptime ISLAND_TAP = 3100  # the island tapped (its action, or its panel)
comptime ISLAND_FRAME = 3101  # a display frame while the island moves or work runs: poll the jobs
comptime PANEL_CLOSE = 3102  # the island's panel closed
comptime JOBS_WAKE = 3109  # a background job or a media decoder finished (App.jobs_message: the wake pipe, no frame poll)
comptime BIG_FILE = 256 * 1024 * 1024  # from this many bytes a file opens in a background job (the island shows its progress)
comptime BIG_ROWS = 10_000_000  # from this many rows a chart's numbers and a column's figures come from background jobs
comptime SKINS: List[String] = ["Liquid", "Ledger", "Graphite", "Blueprint"]
comptime APPEARANCES: List[String] = ["Light", "Dark", "System"]
comptime APPEARANCE = 3290  # Settings: Light, Dark or System (event.number)
comptime INSERT_VIDEO = 3200  # Insert > Video… / Image…: a dialog with a file picker of that kind
comptime INSERT_IMAGE = 3201
comptime INSERT_CLOSE = 3202
comptime INSERT_TABLE = 3203  # Insert > Table…: a dialog with a table file picker (the table lands as a card beside the sheet's own)
comptime PICK_TABLE = 3204  # its picker returned a path
comptime ANALYZE_WITH = 3300  # + analyzer (ANALYZERS): the video card's Analyze popover chose one
comptime ANALYZE_CLOSE = 3310
comptime REEL_FLAG = 3320  # the Make a reel dialog: which flag keeps a frame (event.number), faces, the caption, go, close
comptime REEL_BLUR = 3321
comptime REEL_CAPTION = 3322
comptime REEL_GO = 3323
comptime REEL_CLOSE = 3324
comptime QUERY_OPEN = 3330  # the Query dialog (Insert > SQL query…, the toolbar's Query): its SQL, its answer's name, Run, close
comptime QUERY_TEXT = 3331
comptime QUERY_NAME = 3332
comptime QUERY_RUN = 3333
comptime QUERY_CLOSE = 3334
comptime QUERY_BAR = 3335  # the toolbar's query field: typed (its SQL), Return runs it (as the Query dialog's Run)
comptime QUERY_BAR_RUN = 3336
comptime EXPORT_CSV = 3340  # File > Export CSV: the sheet's own table as <documents>/<its name>.csv
comptime OBJ_TABLE = 5  # (Insert > Table…'s dialog: inserting = OBJ_TABLE)
comptime ACT_ANALYZE = 0  # a video card's actions (mojoui.mediacard CardAction)
comptime ACT_REEL = 1
comptime ACT_EDIT = 2
comptime ANALYZE_LOG = 3311  # the Analyze popover: which log (a track card) georeferences the video (event.number)
comptime COMPARE_OPEN = 3350  # Insert > Compare inspections…: two places tables (earlier, later), Compare, close
comptime COMPARE_A = 3351
comptime COMPARE_B = 3352
comptime COMPARE_GO = 3353
comptime COMPARE_CLOSE = 3354
comptime TRACK_MSG = 4200  # the logs in step with a video (mojoui.trackcard: 4 messages and 2 canvases a card)
comptime TRACK_CANVAS = 250
comptime MAX_TRACKS = 4
comptime TRACK_H = 330  # a new log card's height
comptime LINKS_MSG = 7600  # the sheet's links (mojoui.links: LINKS_MESSAGES), the link drag's panel (mojoui.linkdrag), the peek
comptime LINKDRAG_MSG = 7660
comptime PEEK_FRAME = 7680  # the peek's curves animating (its canvas's frames)
comptime HOLD = 7681  # a card held still on the sheet (Board(on_hold=…)): the peek
comptime DOCS_MSG = 7700  # folders of documents (mojoui.documentset): SET_MESSAGES each
comptime DOCS_CANVAS = 270
comptime MAX_DOCS = 2
comptime PICK_DOCS = 7750  # Insert > Documents…: a folder of PDFs (or one PDF) as a card
comptime PACK_DIR = "pack"  # Export pack writes <documents>/pack/<row's key>.pdf and .mp4
comptime ASK_TEXT = 7751  # the Query dialog's "Ask in words" (taught with the SQL beside it: mojoui.asksql.AskBook)
comptime LINKS_TOGGLE = 7682  # the toolbar's Links: the inspector shows the sheet's links
comptime PEEK_CANVAS = 180
comptime EDITOR_MSG = 4300  # the video editor (mojoui.mediatimeline: 64 messages, 3 canvases), opened from a video card's Edit
comptime EDITOR_CANVAS = 300
comptime PLAN_ALT_M = 25.0  # the next flight plan's height over each asset
comptime TABLE_MSG = 4100  # the table cards' messages (mojoui.tablecard: 4 a card) and canvases (1 a card)
comptime TABLE_CANVAS = 230
comptime MAX_TABLES = 8
comptime MEDIA_MSG = 4000  # the video and picture cards' messages (mojoui.mediacard: 8 a card) and canvases (2 a card)
comptime MEDIA_CANVAS = 200
comptime MAX_MEDIA = 8
comptime TABLE_FRAME = 22  # the table's frame adds this much to its height (the skins' table surface pads it above and below)
comptime MEDIA_W = 720  # a new video or picture card's width (points); its height follows the media's shape
comptime TABLE_TYPES = ".csv,.tsv,.txt,.parquet,.omx"
comptime OPEN_TYPES = TABLE_TYPES + "," + VIDEO_TYPES + "," + IMAGE_TYPES
comptime MAX_OBJECTS = 40  # per sheet, and tiles per report (canvas ids 10…49, 60…99, 120…159)
comptime TABLE_H = 400  # the table's height once objects share the sheet

comptime OMX_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="24" height="24"><g transform="translate(6 6) scale(.97)"><defs><clipPath id="L1c"><circle cx="42.0" cy="42.0" r="20.5"/></clipPath></defs><circle cx="42.0" cy="42.0" r="25.0" fill="none" stroke="#4f46e5" stroke-width="9.0"/><g clip-path="url(#L1c)"><rect x="28.5" y="47" width="7.5" height="60" rx="2" fill="#4f46e5"/><rect x="38.3" y="37.5" width="7.5" height="60" rx="2" fill="#4f46e5"/><rect x="48" y="28" width="7.5" height="60" rx="2" fill="#4f46e5"/></g><line x1="59.68" y1="59.68" x2="80" y2="80" stroke="#4f46e5" stroke-width="12" stroke-linecap="round"/></g></svg>'  # logo 1, the lens over bars (docs/design/brand/, D-254)
comptime APP = "omxcode"  # (settings live in ~/.config/omxcode; ~/.config/omxapp's are adopted, D-285)
comptime W = 1440  # the window (Stitch's artboards; the web check's viewport)
comptime INSPECTOR_W = 300
comptime RAIL_W = 48  # the sheet's side rail (goal 41)
comptime CHROME_H = 252  # the menu bar, toolbar, formula bar, bottom tabs, status bar and the gaps between them (goal 25: measured)
comptime COMPACT_W = 1440  # narrower windows: the toolbar's tools show only their icons (their titles are tooltips)
comptime FX_H = 42  # the formula bar and its gap (the report has none: its page is that much taller)
comptime SYMBOLS: List[String] = ["$", "€", "£", "₹"]
comptime NEGATIVE_STYLES: List[String] = ["−1,234", "(1,234)"]


def capital(s: String) -> String:
    """s with its first letter a capital ("median amount by region" → "Median amount by region")."""
    if s.byte_length() == 0:
        return s
    return String(s[byte=:1]).upper() + String(s[byte=1:])


struct Main(App):
    var screen: Int
    var has_table: Bool
    var frame: Sheet
    var ran_gpu: Bool  # the last totals ran on the GPU
    var imp: CsvImport
    var source: String  # what the table came from (a path, "sample", "blank")
    var name: String  # the table's name (the file's name without .csv)
    var grid: DataGrid
    var preview: DataGrid  # Import: the first rows, read-only
    var font: Font
    var pal: Palette
    var win_w: Int  # the window's content area in points (App.resize; W × 900 until the host says)
    var win_h: Int
    var looks: List[Theme]  # the skin's themes, one per tint (make_looks)
    var skin: Int  # the design (LIQUID by default, D-225, D-1241; Settings → Appearance writes settings.txt, D-156)
    var appearance_mode: Int  # LIGHT, DARK (the default) or SYSTEM: Liquid's light or dark (D-1241)
    var system_dark: Bool  # what the system said last (App.appearance)
    var import_col: Int
    var insp_tab: Int  # 0 Table, 1 Cell
    var inspector_open: Bool
    var formula_open: Bool  # the formula bar adds a column instead of editing a cell
    var edit_text: String
    var message: String
    var block_lines: List[String]  # the block's figures for the status bar (computed when the selection changes, not per redraw)
    var stats: List[Tuple[String, String]]  # the selected column's figures for the inspector's cards, and what they're for
    var stats_key: String
    var clip_text: String  # what Copy put on the clipboard last, and its version (the Clipboard view)
    var clip_version: Int
    var sum: Int  # the selected column's total and count (GPU, with the session's edits)
    var count: Int
    var milliseconds: Float64
    var recent: List[String]
    var version: Int
    var objects: List[SheetObject]  # charts and pivots on the sheet
    var media: MediaCards  # videos and pictures on the sheet (Board children after the objects)
    var tables: TableCards  # tables besides the sheet's own: a file added (Insert > Table…), a query's answer (Board children after the media)
    var tracks: TrackCards  # logs in step with a video: a chart with its cursor and a map (Board children after the tables)
    var editor: Optional[MediaTimeline]  # a video card's Edit: the editor over the whole window, until Done
    var feed: TimelineFeed
    var comparing: Optional[Job[Sheet]]  # Insert > Compare inspections, running (mojoui.inspection_tables.compare_job)
    var comparing_names: Tuple[String, String]
    var comparing_t0: Int
    var work: TableWork  # Insert > Table, the queries, Export CSV: jobs (mojoui.tablejobs), taken on JOBS_WAKE
    var warming: Optional[Job[Int]]  # the GPU started off the UI thread at launch (sheetjobs.warm_gpu): kept until it ends
    var compare_open: Bool  # Insert > Compare inspections…: its choices (indices into place_tables())
    var compare_a: Int
    var compare_b: Int
    var table_title: String  # the sheet's own table's title when it isn't the tab's name ("warehouse.mp4 · detections"), else ""
    var video: VideoWork  # the video cards' Analyze / Make a reel / Edit work (mojoui.videocard): its jobs and the last analysis' rows
    var found_table: String  # where the analysis' rows are shown: "" the sheet's own table, else a card's name
    var analyze_card: Int  # the card whose Analyze popover is open, -1 none
    var reel_card: Int  # the card whose Make a reel dialog is open, -1 none
    var reel_flag: Int  # the dialog's choices: which flag column (an index into reel_flags()), blur faces, which caption (0: none)
    var reel_blur: Bool
    var reel_caption: Int
    var reel_captions: List[Tuple[String, Int, Int, Int]]  # caption choices: (label, table card (-1: the sheet's own), key column, value column)
    var query_open: Bool
    var query_text: String
    var query_name: String
    var query_said: String
    var inserting: Int  # Insert > Video… or Image… open: OBJ_VIDEO or OBJ_IMAGE (0: closed)
    var active: Int  # the object the inspector shows (-1: none)
    var chart_sizes: List[Tuple[Float64, Float64]]  # per canvas id: points from the last draw (taps)
    var sheet_tab: Int  # 0: the table's sheet, 1: the Report
    var tiles: List[ReportTile]
    var filter: ReportFilter
    var report_col: Int  # the column new tiles use
    var seen_edits: Int  # the frame's edit count when the objects and tiles were last computed
    var table_x: Int  # the table's place and size on the sheet (it moves and resizes like any object)
    var table_y: Int
    var table_w: Int
    var table_h_set: Int  # 0: automatic
    var reveal: Int  # the sheet child to scroll into view (a new object), and how many times asked
    var reveal_count: Int
    var ctx_col: Int  # the column a context menu is open for (-1: none), and where it opened on the grid
    var ctx_x: Int
    var ctx_y: Int
    var settings_open: Bool  # File > Settings…
    var about_open: Bool  # Help > About
    var help_open: Bool  # ƒx's popover
    var toast: String  # the toast showing ("" none) and what its Undo does
    var toast_undo: Int
    var show_timings: Bool  # Settings: the GPU time in the status bar (settings.txt: timings)
    var sheet_name: String  # the sheet tab's name (the document's name until it's renamed; the file keeps the document's)
    var report_name: String  # the Report tab's name ("Report" until it's renamed)
    var renaming: Int  # the tab being renamed (0 the sheet, 1 the Report), -1 none
    var picking: Int  # the swatches open: PICK_INK or PICK_FILL, 0 none
    var word_ref: Int  # a chart word whose choices are open: its chart (a ref) and slot; -1 none
    var asking: Int  # the chart whose ask field shows (the last one tapped, inserted or asked): a ref, -1 none
    var ask_text: String  # what's typed in it
    var ask_said: String  # what it said back last
    var lit: List[Int]  # the slots the last ask changed (marked once), on chart `asking`
    var chart_undo: List[Tuple[Int, Int, SheetObject]]  # chart changes Undo can take back: (the table's undo depth then, the chart's ref, the chart before)
    var insp_page: Int  # the chart inspector's page (0: the chart; 1 Data, 2 Order, 3 Rows, 4 Style)
    var word_slot: Int
    var island: Island  # the menu bar's living status (D-255): the document at rest, work running, results, undo, errors
    var island_v: Int  # its canvas's version (a new picture each frame it moves)
    var island_undo: Int  # what its Undo does (NO_MSG: none)
    var panel_open: Bool  # its panel: the document, Recent, Device
    var ops: List[Tuple[String, String, Int]]  # Recent: what was done, its time ("0.69 s on …", or ""), its Undo message (NO_MSG: none), newest last
    var timings: List[Float64]  # the last queries' milliseconds (Device: the last 12, p50, p95)
    var charts: ChartQueue  # charts waiting for their numbers (big tables: background jobs)
    var held: List[Tuple[Int, SheetObject]]  # what a waiting chart showed before its change: drawn (faded) until its numbers land
    var col_job: Optional[Job[ColumnFigures]]  # the selected column's figures, coming (big tables)
    var col_started: Int
    var col_orphans: List[Job[ColumnFigures]]  # column jobs cancelled for a newer column, their threads not yet stopped
    var opening: Optional[Job[Opened]]  # a big file being read (its path in `source` once it lands)
    var opening_path: String
    var trace: Bool  # MOJOUI_TRACE: the jobs say what they do (for scripts/check)
    var links: Links  # the sheet's links: made by a person (a column dragged onto a card) or an agent, never by the app
    var ld: LinkDrag  # a column being dragged onto a card, and the panel that confirms the link
    var peek: Peek  # a card held: what it's linked to
    var links_open: Bool  # the inspector shows the Links panel
    var docs: List[DocumentSet]  # folders of documents on the sheet (Board children after the logs)
    var doc_feeds: List[FolderFeed]  # their page pictures and reads (jobs), one per set
    var query_ask: String  # the Query dialog's question in words
    var asked_sql: String  # the SQL the last query ran (JOIN LINKED written out): its answer's lineage
    var book: AskBook  # questions taught with their SQL
    var packing: Optional[Job[Packed]]  # Export pack: a table's rows as PDFs and clips (mojoui.pack)
    var pack_card: String  # the table it packs
    var doc_opening: Optional[Job[DocumentSet]]  # Insert > Documents…: the folder being opened (mojoui.documentjobs)
    var doc_opening_path: String

    def __init__(out self):
        self.screen = START_SCREEN
        self.has_table = False
        self.frame = placeholder_sheet()
        self.ran_gpu = False
        self.imp = empty_import()
        self.source = ""
        self.name = ""
        self.grid = DataGrid()
        self.preview = DataGrid()
        self.font = Font()
        self.looks = List[Theme]()
        adopt_config(APP, "omxapp")
        # Liquid by default, a saved skin honoured (D-1241: D-1176's skin_version rule is gone), in Liquid dark unless light is saved
        self.skin = skin_of(read_setting(APP, "skin", "liquid"))
        self.appearance_mode = appearance_of(read_setting(APP, "appearance", "dark"))
        self.system_dark = False
        self.win_w = W
        self.win_h = 900
        self.pal = skin_palette(self.skin, 0, self.appearance_mode == DARK)
        self.import_col = 0
        self.insp_tab = 1
        self.inspector_open = read_setting(APP, "inspector", "yes") != "no"
        self.formula_open = False
        self.edit_text = ""
        self.message = ""
        self.sum = 0
        self.count = 0
        self.clip_text = ""
        self.stats = List[Tuple[String, String]]()
        self.stats_key = ""
        self.block_lines = List[String]()
        self.clip_version = 0
        self.milliseconds = 0
        self.recent = read_recent(APP)
        self.objects = List[SheetObject]()
        self.media = MediaCards(MEDIA_MSG, MEDIA_CANVAS, MAX_MEDIA)
        self.tables = TableCards(TABLE_MSG, TABLE_CANVAS, MAX_TABLES)
        self.tracks = TrackCards(TRACK_MSG, TRACK_CANVAS, MAX_TRACKS)
        self.editor = None
        self.feed = TimelineFeed()
        self.work = TableWork()
        self.comparing = None
        self.comparing_names = (String(""), String(""))
        self.comparing_t0 = 0
        self.warming = warm_gpu()  # (the driver's ~0.2 s start-up on a job's thread: the first sheet made on the UI thread doesn't pay it)
        self.compare_open = False
        self.compare_a = 0
        self.compare_b = 1
        self.table_title = ""
        self.video = VideoWork()
        self.found_table = ""
        self.analyze_card = -1
        self.reel_card = -1
        self.reel_flag = 0
        self.reel_blur = True
        self.reel_caption = 0
        self.reel_captions = List[Tuple[String, Int, Int, Int]]()
        self.query_open = False
        self.query_text = ""
        self.query_name = "Query 1"
        self.query_said = ""
        self.inserting = 0
        self.active = -1
        self.chart_sizes = List[Tuple[Float64, Float64]](length=1000, fill=(400.0, 240.0))
        self.sheet_tab = 0
        self.tiles = List[ReportTile]()
        self.filter = ReportFilter(-1, 0)
        self.report_col = -1
        self.seen_edits = 0
        self.table_x = 0
        self.table_y = 0
        self.table_w = 0
        self.table_h_set = 0
        self.reveal = -1
        self.reveal_count = 0
        self.ctx_col = -1
        self.ctx_x = 0
        self.ctx_y = 0
        self.settings_open = False
        self.about_open = False
        self.help_open = False
        self.toast = ""
        self.toast_undo = NO_MSG
        self.show_timings = read_setting(APP, "timings", "yes") != "no"
        self.sheet_name = ""
        self.report_name = "Report"
        self.renaming = -1
        self.picking = 0
        self.word_ref = -1
        self.word_slot = 0
        self.asking = -1
        self.ask_text = ""
        self.ask_said = ""
        self.lit = List[Int]()
        self.insp_page = 0
        self.chart_undo = List[Tuple[Int, Int, SheetObject]]()
        self.island = Island()
        self.island_v = 0
        self.island_undo = NO_MSG
        self.panel_open = False
        self.ops = List[Tuple[String, String, Int]]()
        self.timings = List[Float64]()
        self.charts = ChartQueue()
        self.held = List[Tuple[Int, SheetObject]]()
        self.col_job = None
        self.col_started = 0
        self.col_orphans = List[Job[ColumnFigures]]()
        self.opening = None
        self.opening_path = ""
        self.trace = environment("MOJOUI_TRACE") != ""
        self.links = Links(LINKS_MSG)
        self.ld = LinkDrag(LINKDRAG_MSG)
        self.peek = Peek(PEEK_CANVAS, PEEK_FRAME)
        self.links_open = False
        self.docs = List[DocumentSet]()
        self.doc_feeds = List[FolderFeed]()
        self.query_ask = ""
        self.asked_sql = ""
        self.book = AskBook()
        self.packing = None
        self.pack_card = ""
        self.doc_opening = None
        self.doc_opening_path = ""
        self.version = 1
        var auto_open = environment("OMX_OPEN")  # a file to open straight away (the launcher's argument)
        if auto_open != "":
            self.open_path(auto_open)
        self.make_looks()

    @staticmethod
    def init_shared():
        pass

    def title(self) -> String:
        return "omxplorer" + (" · " + self.name if self.name != "" else "")

    def window_size(self) -> Tuple[Int, Int]:
        return (W, 900)

    def dark(self) -> Bool:
        """Liquid dark now: the appearance picked, or the system's."""
        return self.appearance_mode == DARK or (self.appearance_mode == SYSTEM and self.system_dark)

    def appearance(mut self, dark: Bool):
        """The system's light or dark: followed when the appearance is System."""
        var was = self.dark()
        self.system_dark = dark
        if self.dark() != was:
            self.restyle()

    def restyle(mut self):
        """The looks and the canvases' palette again (a skin or an appearance picked, the system switched)."""
        self.pal = skin_palette(self.skin, self.accent(), self.dark())
        self.make_looks()
        self.grid.redraw()
        self.preview.redraw()
        self.version += 1

    def resize(mut self, width: Int, height: Int):
        """The window's content area: the sheet, the report and the inspector fill it (goal 25 M2)."""
        self.win_w = max(width, 640)
        self.win_h = max(height, 480)
        if self.editor:
            self.editor.value().resize(self.win_w - 40, self.win_h - 32)  # (less the editor's margins)

    def grid_h(self) -> Int:
        """The sheet's height: the window less the menu bar, toolbar, formula bar, tabs and status bar."""
        return max(240, self.win_h - CHROME_H)

    def theme(self) -> Theme:
        """The skin with this mode's tint (kept: one per tint, made when the skin changes)."""
        var at = self.tint()
        if at < len(self.looks):
            return self.looks[at].copy()
        return skin_theme(self.skin, self.accent(), self.dark())  # (not reached: make_looks keeps one per tint)

    def tint(self) -> Int:
        """Which of make_looks' themes shows now: Liquid's indigo (0), the sheet's green (1), the report's red (2); other skins: 0."""
        if self.skin != LIQUID or self.screen != SHEET:
            return 0
        return 1 if self.sheet_tab == 0 else 2

    def make_looks(mut self):
        """The skin's themes, one per tint it shows (Liquid: indigo, the sheet's green, the report's red; others: their own)."""
        self.looks = List[Theme]()
        if self.skin == LIQUID:
            for a in [BRAND_INDIGO, SHEET_GREEN, REPORT_RED]:
                self.looks.append(skin_theme(self.skin, a, self.dark()))
        else:
            self.looks.append(skin_theme(self.skin, 0))

    def accent(self) -> UInt32:
        """Liquid's tint per mode (D-254): the sheet green, the report red, the rest the brand's indigo; other skins keep theirs."""
        if self.skin != LIQUID:
            return 0
        if self.screen == SHEET:
            return SHEET_GREEN if self.sheet_tab == 0 else REPORT_RED
        return BRAND_INDIGO

    def logo(self) -> String:
        return OMX_LOGO  # omxplorer's own skin on every platform (D-149), never the desktop's theme

    # ---------- data in ----------

    def use_table(mut self, var sheet: Sheet):
        """The new table takes over; only then is the old one's memory given back (CPU and GPU: ~26 GB at 100M
        rows). A file that fails to open never gets here, so the sheet on screen stays intact."""
        self.drop_jobs()  # (they read the old table and its GPU copy: stopped before those are given back)
        swap(self.frame, sheet)  # (sheet is the old one now)
        sheet.release()
        self.has_table = True
        self.stats_key = ""  # (the new file's edits count from 0 again: its stats are its own)
        self.chart_undo = List[Tuple[Int, Int, SheetObject]]()  # (chart edits name the old table's columns and charts)
        self.asking = -1
        self.word_ref = -1
        self.lit = List[Int]()
        self.insp_page = 0
        self.ask_text = ""
        self.ask_said = ""

    def open_path(mut self, path: String):
        """A CSV or Parquet file → the Import step (its columns as read; a Parquet file too big for memory is streamed,
        D-184); an .omx document → straight to its sheet; a video or picture → a card on the sheet (a new one when none is
        open). A bare file name is looked up in the documents folder (OMX_DOCUMENTS), where Save puts documents."""
        if not path.startswith("/") and path.find("/") < 0 and not file_exists(path):
            var docs = environment("OMX_DOCUMENTS", environment("HOME", ".") + "/Documents/omxplorer") + "/" + path
            if file_exists(docs):
                self.open_path(docs)
                return
        if is_media_file(path):
            self.open_media(path)
            return
        if path.endswith(".omx"):
            try:
                var objects = List[SheetObject]()
                var tiles = List[ReportTile]()
                var filter = ReportFilter(-1, 0)
                var tab_names = List[String]()
                var frame = open_document(path, objects, tiles, filter, tab_names)
                self.use_table(frame^)
                self.source = path
                self.name = file_stem(path)
                remember(APP, path, self.recent)
                self.to_sheet()
                if len(tab_names) > 0 and tab_names[0] != "":  # (the tabs' names as saved)
                    self.sheet_name = tab_names[0]
                if len(tab_names) > 1 and tab_names[1] != "":
                    self.report_name = tab_names[1]
                self.objects = objects^  # the sheet's charts and pivots, and the Report, as they were saved
                self.tiles = tiles^
                self.filter = filter^
                self.refresh()
                self.message = "Opened " + file_name(path) + " · " + grouped(self.frame.rows()) + " rows"
            except e:
                self.message = String(e)
            self.version += 1
            return
        var bytes = 0
        try:
            bytes = file_size(path)
        except:
            pass
        if bytes >= BIG_FILE:  # (read in a job: the window stays live, the island shows how far it is)
            self.stop_opening()  # (a file still being read gives way to this one)
            self.opening = open_job(path)
            self.opening_path = path
            if self.trace:
                print("JOB: start open " + file_name(path))
            self.say(Activity.running("Opening " + file_name(path), 0.0, grouped(bytes // (1024 * 1024)) + " MB"))
            self.version += 1
            return
        try:
            var imp = read_table(path)
            var sheet = Sheet(imp.scan.value()) if imp.streamed() else Sheet(imp.table)
            imp.let_go()  # (the sheet holds the table now; the import keeps only what it showed)
            var shapes = List[List[Float64]]()
            if not sheet.streamed():  # (a histogram reads every row: a streamed file's would take seconds a column)
                for c in range(sheet.stored()):
                    try:
                        shapes.append(shape_of(sheet, c))
                    except:
                        shapes.append(List[Float64]())
            self.imported(path, imp^, sheet^, shapes^)
        except e:
            self.message = String(e)
            self.say(Activity.error("Couldn't open " + file_name(path), "it isn't a table"))  # (stays until it's seen: the reason is in the status bar)
        self.version += 1

    def open_media(mut self, path: String, card_w: Int = 0):
        """A video or picture as a card on the sheet: beside the table on a sheet of its own (a blank one, made now), below
        what is there on a sheet already open (as a new chart goes); `card_w` > 0: at most that wide there."""
        var fresh = self.screen != SHEET or not self.has_table
        if fresh:
            self.open_blank()
            if self.screen != SHEET:
                return
        var width = self.sheet_width()
        var w = min(MEDIA_W, max(width - 360, 320))
        if card_w > 0 and not fresh:
            w = min(card_w, w)
        var spot = (0, 0)
        if not fresh:  # (cards are placed like charts: where nothing is, tables and videos included)
            spot = self.free_place(w, w * 9 // 16 + 132)
        try:
            var k = self.media.add(path, spot[0], spot[1], w)
            if self.media.cards[k].kind == OBJ_VIDEO:  # (two quiet actions: the rows it holds, and a reel of some of them)
                var n = self.video_number(k)
                var tail = "" if n == 0 else "-" + String(n + 1)
                self.media.cards[k].actions.append(CardAction("Analyze", "zap", "analyze" + tail, "Find what's in the video, frame by frame: the rows land on the sheet as a table"))
                self.media.cards[k].actions.append(CardAction("Make a reel", "video", "make-reel" + tail, "Cut the frames where a column of the analysis is true into a new video: faces blurred, a caption burned in"))
                self.media.cards[k].actions.append(CardAction("Edit", "sliders-horizontal", "edit" + tail, "Open the editor: a filmstrip timeline with the analysis and the log as lanes; split, trim, cut by a sentence, export"))
            if fresh:  # (the blank table sits beside the card, as tall as it: the video and its numbers side by side)
                self.table_x = w + 16
                self.table_w = max(width - w - 16, 320)
                self.table_h_set = self.media.cards[k].h - TABLE_FRAME
                self.sheet_name = file_stem(path)
                self.name = file_stem(path)
            self.reveal = 1 + len(self.objects) + k  # (child 0 is the table, then the objects, then the cards)
            self.reveal_count += 1
            self.message = "Opened " + file_name(path) + " · " + self.media.cards[k].facts()
            remember(APP, path, self.recent)
        except e:
            self.message = String(e)
            self.say(Activity.error("Couldn't open " + file_name(path), "it isn't a video or picture"))
        self.version += 1

    def video_number(self, k: Int) -> Int:
        """Card k is the how-manyth video card (0: the first), which names its actions for an agent (analyze, analyze-2)."""
        var n = 0
        for j in range(k):
            if self.media.cards[j].kind == OBJ_VIDEO:
                n += 1
        return n

    def card_of(self, path: String) -> Int:
        """The video card showing `path`, else -1."""
        for k in range(len(self.media)):
            if self.media.cards[k].path == path:
                return k
        return -1

    def documents(self) -> String:
        """Where Save, Export CSV and reels put files (OMX_DOCUMENTS), made when missing."""
        var d = environment("OMX_DOCUMENTS", environment("HOME", ".") + "/Documents/omxplorer")
        try:
            make_dir(d)
        except:
            pass
        return d

    def add_table_file(mut self, path: String):
        """Insert > Table…: a CSV or Parquet file as a table card beside what's on the sheet (the sheet's own table stays).
        Read, parsed and its grid measured in a job (mojoui.tablejobs): table_landed places it when it ends."""
        if self.work.insert(path, self.pal):
            self.message = "Reading " + file_name(path) + "…"
            self.say(Activity.running("Reading " + file_name(path), 0.0, "in the background"))
        else:
            self.message = self.work.problem
            self.work.problem = ""
        self.version += 1

    def table_landed(mut self, var f: TableFile):
        """A table file's card, read off the UI thread: beside what's on the sheet; a log (time, lat, lon) gets its chart
        and map first, right under its video."""
        var path = f.path
        try:
            var w = self.card_width(f.card.sheet.columns())
            var is_log = Bool(f.log)
            var h = 240 if is_log else 320  # (a log's rows matter less than its chart: a shorter card)
            if is_log:  # (its chart and map first, right under its video; the rows go where there's room)
                self.add_track(file_stem(path), f.log.take())
            var spot = self.free_place(w, h)
            var k = self.tables.adopt(f^.take_card(), spot[0], spot[1], w, h)
            if not is_log:
                self.reveal_table(k)
            self.message = "Added " + file_name(path) + " · " + self.tables.cards[k].facts()
            self.say(Activity.done(file_stem(path), self.tables.cards[k].facts()))
        except e:
            self.message = "Couldn't add " + file_name(path) + ": " + String(e)
            self.say(Activity.error("Couldn't add " + file_name(path), String(e)))
        self.version += 1

    def take_table_work(mut self):
        """What the table jobs finished (a file's card, a query's answer, an export): placed now, on the UI thread."""
        var f = self.work.take_file()
        if f:
            self.table_landed(f.take())
        var a = self.work.take_answer()
        if a:
            self.answer_landed(a.take())
        var x = self.work.take_export()
        if x:
            self.message = "Exported " + file_name(x.value().path) + " to your documents"
            self.say(Activity.done(file_name(x.value().path), grouped(x.value().rows) + " rows exported"))
            self.version += 1
        if self.work.problem != "":
            if self.query_open:
                self.query_said = self.work.problem
            self.message = self.work.problem
            self.say(Activity.error("Couldn't finish", self.work.problem))
            self.work.problem = ""
            self.version += 1

    def free_place(self, w: Int, h: Int) -> Tuple[Int, Int]:
        """Where a new w × h card goes: the first spot nothing on the sheet covers, below the table."""
        var taken = self.objects.copy()
        for k in range(len(self.media)):
            ref c = self.media.cards[k]
            taken.append(SheetObject.chart(0, 0, c.x, c.y, c.w, c.h))
        for k in range(len(self.tables)):
            ref t = self.tables.cards[k]
            taken.append(SheetObject.chart(0, 0, t.x, t.y, t.w, t.h))
        for k in range(len(self.tracks)):
            ref r = self.tracks.cards[k]
            taken.append(SheetObject.chart(0, 0, r.x, r.y, r.w, r.h))
        for k in range(len(self.docs)):
            ref d = self.docs[k].card
            taken.append(SheetObject.chart(0, 0, d.x, d.y, d.w, d.h))
        taken.append(SheetObject.chart(0, 0, self.table_x, self.table_y, self.table_w if self.table_w > 0 else self.sheet_width(), self.table_h() + TABLE_FRAME))  # (its frame: as tall as a card beside it)
        return free_spot(taken, -16, self.sheet_width(), w, h)

    def card_width(self, columns: Int) -> Int:
        """A new table card's width: room for its columns, between 360 and 640 points."""
        return min(max(columns * 120 + 100, 360), 640)

    def reveal_table(mut self, k: Int):
        self.reveal = 1 + len(self.objects) + len(self.media) + k  # (child 0 is the table, then the objects, the cards, the tables)
        self.reveal_count += 1

    def add_track(mut self, name: String, var log: TimeSeries):
        """A log beside its video: a card with a chart whose cursor follows the video, and the route's map (under the
        video, as wide as it)."""
        var video = self.tracks.video_for_log(name, self.media.video_paths())
        var w = 720
        var at = self.card_of(video)
        if at >= 0:
            w = self.media.cards[at].w
        var spot = self.free_place(w, TRACK_H)
        if at >= 0:  # (right under its video when that's free: the picture and its numbers in one column)
            ref c = self.media.cards[at]
            var under = self.free_place(w, TRACK_H)
            under = (c.x, c.y + c.h + 16)
            var clear = True
            for k in range(len(self.tables)):
                ref t = self.tables.cards[k]
                if t.x < under[0] + w and under[0] < t.x + t.w and t.y < under[1] + TRACK_H and under[1] < t.y + t.h:
                    clear = False
            for k in range(len(self.media)):
                ref m = self.media.cards[k]
                if k != at and m.x < under[0] + w and under[0] < m.x + m.w and m.y < under[1] + TRACK_H and under[1] < m.y + m.h:
                    clear = False
            if clear:
                spot = under
        try:
            var k = self.tracks.add(name, log^, video, spot[0], spot[1], w, TRACK_H)
            self.tracks.cards[k].note = "In step with " + (file_name(video) if video != "" else String("no video yet"))
            self.reveal = 1 + len(self.objects) + len(self.media) + len(self.tables) + k
            self.reveal_count += 1
            if self.trace:
                print("TRACK: " + name + " in step with " + file_name(video))
        except e:
            self.say(Activity.error("Couldn't show the log", String(e)))

    def track_time(self, k: Int) -> Float64:
        """The time of track k's video (its playhead), 0 when it has none."""
        var v = self.card_of(self.tracks.cards[k].video)
        if v >= 0 and self.media.cards[v].player:
            return self.media.cards[v].player.value().state.t()
        return 0.0

    def track_frame(self, k: Int) -> Int:
        var v = self.card_of(self.tracks.cards[k].video)
        if v >= 0 and self.media.cards[v].player:
            return self.media.cards[v].player.value().state.frame
        return 0

    def seek_video(mut self, path: String, t: Float64):
        """The video card showing `path` to time t, as its own scrubber would (its trace says so)."""
        var v = self.card_of(path)
        if v >= 0 and self.media.cards[v].player:
            _ = self.media.update(Event(self.media.msg(v) + PLAYER_SCRUB, String(t), SET_TO))

    def mark_track(mut self, video: String, var marks: List[MapMark]):
        """An inspection's places on its log's map (place_marks)."""
        var k = self.tracks.for_video(video)
        if k >= 0:
            self.tracks.cards[k].marks = marks^

    def place_tables(self) -> List[Tuple[String, Int]]:
        """The inspections on the sheet (places tables): their SQL names and where they are (-1: the sheet's own table,
        else a table card's index)."""
        var out = List[Tuple[String, Int]]()
        if self.has_table and is_places(self.frame):
            out.append((sql_name(self.name), -1))
        for k in range(len(self.tables)):
            if is_places(self.tables.cards[k].sheet):
                out.append((self.tables.sql_name_of(k), k))
        return out^

    def run_compare(mut self):
        """Insert > Compare inspections: the later flight against the earlier one; the assets that got worse land as
        the "worse" table card, with Flight plan as its action."""
        var pl = self.place_tables()
        self.compare_open = False
        if len(pl) < 2:
            self.say(Activity.error("Nothing to compare", "analyze two flights with Assets & defects first"))
            self.version += 1
            return
        var a = pl[min(self.compare_a, len(pl) - 1)]
        var b = pl[min(self.compare_b, len(pl) - 1)]
        if self.comparing:
            self.message = "A comparison is running already"
            self.version += 1
            return
        # (a job over snapshots of the two places tables: mojoui.inspection_tables.compare_job; compare_landed places it)
        if a[1] == -1 and b[1] == -1:
            self.comparing = compare_job(self.frame, self.frame, DRONE_MATCH_M)
        elif a[1] == -1:
            self.comparing = compare_job(self.frame, self.tables.cards[b[1]].sheet, DRONE_MATCH_M)
        elif b[1] == -1:
            self.comparing = compare_job(self.tables.cards[a[1]].sheet, self.frame, DRONE_MATCH_M)
        else:
            self.comparing = compare_job(self.tables.cards[a[1]].sheet, self.tables.cards[b[1]].sheet, DRONE_MATCH_M)
        self.comparing_names = (a[0], b[0])
        self.comparing_t0 = now_ns()
        self.say(Activity.running("Comparing " + a[0] + " and " + b[0], 0.0, "in the background"))
        self.version += 1

    def compare_landed(mut self, var sheet: Sheet):
        """The comparison's "worse" table: a card with Flight plan as its action."""
        var a = self.comparing_names[0]
        var b = self.comparing_names[1]
        try:
            var n = sheet.rows()
            var w = 560
            var spot = self.free_place(w, 260)
            var k = self.tables.add("worse", sheet^, spot[0], spot[1], w, 260, self.font, self.pal)
            self.tables.cards[k].note = a.replace("_places", "") + " → " + b.replace("_places", "")  # (one line: the flights)
            self.tables.cards[k].act_with("Flight plan", "route", "flight-plan", "Write the next flight plan: a waypoint over each asset that got worse (waypoints.csv in your documents)")
            self.reveal_table(k)
            if self.trace:
                print("JOB: compare " + a + " " + b + " " + String(n) + " worse")
            self.message = String(n) + " assets got worse from " + a + " to " + b + " (a new defect, or a bigger one)"
            self.say(Activity.done("worse", String(n) + " assets · " + fixed(Float64(now_ns() - self.comparing_t0) / 1e6, 1) + " ms"))
        except e:
            self.say(Activity.error("Couldn't compare", String(e)))
        self.version += 1

    def write_plan(mut self, k: Int):
        """A worse card's Flight plan: <documents>/waypoints.csv, shown as a card of its own."""
        var path = self.documents() + "/waypoints.csv"
        try:
            var n = flight_plan(path, self.tables.cards[k].sheet, PLAN_ALT_M, "inspect")
            if self.trace:
                print("JOB: flight plan " + String(n) + " waypoints")
            self.add_table_file(path)
            var at = self.tables.find("waypoints")
            if at >= 0:
                self.tables.cards[at].note = "the next flight · " + String(n) + " waypoints at " + fixed(Float64(PLAN_ALT_M), 0) + " m"
            self.message = "Wrote waypoints.csv: " + String(n) + " waypoints, one over each asset that got worse (in your documents)"
        except e:
            self.say(Activity.error("Couldn't write the flight plan", String(e)))
        self.version += 1

    def default_analyzer(self, k: Int) -> Int:
        """The analyzer Analyze starts on card k's video: Assets & defects when a log with positions is in step with it,
        else Objects & codes (the popover offers the others)."""
        var tk = self.tracks.for_video(self.media.cards[k].path)
        if tk >= 0 and self.tracks.cards[tk].series.index("lat") >= 0 and self.tracks.cards[tk].series.index("lon") >= 0:
            return INSPECTION
        return 0

    # ---------- links (mojoui.links, linkdrag, peek) ----------

    def drop_cards(self) -> List[DropCard]:
        """The cards on the sheet as the link UI sees them, in the Board's order: their names as shown, the table their
        columns come from ("" their own), where they are, their index among the Board's children."""
        var out = List[DropCard]()
        var own = self.table_title if self.table_title != "" else self.sheet_name
        out.append(DropCard(own, "", self.table_x, self.table_y, self.table_w if self.table_w > 0 else self.sheet_width(), self.table_h(), 0, False))
        var i = 1
        for k in range(len(self.objects)):
            ref o = self.objects[k]
            out.append(DropCard(object_title(o, self.frame), own, o.x, o.y, o.w, o.h, i, False))  # (a chart of the sheet's table: the same table)
            i += 1
        for k in range(len(self.media)):
            ref c = self.media.cards[k]
            var rows = String("")
            if self.video.found_path == c.path:
                var at = self.found_sheet_index()
                rows = own if at == -1 else (self.tables.cards[at].name if at >= 0 else String(""))
            out.append(DropCard(c.title(), rows, c.x, c.y, c.w, c.h, i, c.kind == OBJ_VIDEO))
            i += 1
        for k in range(len(self.tables)):
            ref t = self.tables.cards[k]
            out.append(DropCard(t.name, "", t.x, t.y, t.w, t.h, i, False))
            i += 1
        for k in range(len(self.tracks)):
            ref r = self.tracks.cards[k]
            out.append(DropCard(r.name, r.name if self.tables.find(r.name) >= 0 else String(""), r.x, r.y, r.w, r.h, i, False))  # (its rows' card: the same table)
            i += 1
        for k in range(len(self.docs)):
            ref d = self.docs[k]
            out.append(DropCard(d.name, d.fields_name() if d.is_read() else String(""), d.card.x, d.card.y, d.card.w, d.card.h, i, False))  # (its columns: its fields' table)
            i += 1
        return out^

    def sheet_of(self, c: DropCard) -> Int:
        """Where card c's columns are: -1 the sheet's own table, a table card's index, -2 none (a picture, a video not
        analyzed yet, a chart)."""
        var t = c.table if c.table != "" else c.name
        var own = self.table_title if self.table_title != "" else self.sheet_name
        if c.index == 0 or (t == own and self.has_table):
            return -1
        var k = self.tables.find(t)
        return k if k >= 0 else -2

    def column_dragged(mut self):
        """A table card's column header is being dragged (or was let go): the card under it lights up with its matching
        columns; let go over it, the panel asks to confirm."""
        var k = self.tables.dragged
        var x = self.tables.drag_x
        var y = self.tables.drag_y
        var cards = self.drop_cards()
        if self.tables.drag_state == GRID_HEADER_DRAG and not self.ld.active:
            self.peek.close()
            ref c = self.tables.cards[k]
            self.ld.begin(c.name, "", self.tables.drag_column, column_values(c.sheet, c.sheet.index(self.tables.drag_column)), x, y)
            self.message = "Drop " + self.tables.drag_column + " on a card to link them"
        if self.ld.move(x, y, cards) and self.ld.target >= 0:
            var at = self.sheet_of(cards[self.ld.target])
            if cards[self.ld.target].timed and is_time_column(self.ld.from_column):  # (a clock dropped on a video: a time link)
                self.ld.offer_time()
            elif at == -1:
                self.ld.offer(match_columns(self.ld.values, self.frame))
            elif at >= 0:
                self.ld.offer(match_columns(self.ld.values, self.tables.cards[at].sheet))
        if self.tables.drag_state == GRID_HEADER_DROP:
            if self.ld.drop():
                self.message = "Link " + self.ld.from_column + " to " + self.ld.target_card.name + "?"
            else:
                self.message = "Drop a column on another card that has columns (a video's come with Analyze) to link them"

    def sync_lanes(mut self):
        """Every time link paints: a linked log's first measure under its video, on the video's clock (mojoui.timelane);
        a time link only paints, it joins nothing."""
        for k in range(len(self.media)):
            if self.media.cards[k].lane:
                self.media.clear_lane(k)
        for l in self.links.items:
            if l.kind != LINK_TIME:
                continue
            var v = -1
            var log = String("")
            var offset = l.offset  # (the log's t = the video's t + offset)
            for k in range(len(self.media)):
                if self.media.cards[k].kind == OBJ_VIDEO and self.media.cards[k].title() == l.a.card:
                    v = k
                    log = l.b.card
                elif self.media.cards[k].kind == OBJ_VIDEO and self.media.cards[k].title() == l.b.card:
                    v = k
                    log = l.a.card
                    offset = -l.offset
            var t = self.tables.find(log)
            if v < 0 or t < 0:
                continue
            try:
                var ts = series_from_sheet(self.tables.cards[t].sheet)
                if len(ts.names) > 0:
                    self.media.show_lane(v, TimeLane.of(log, ts, ts.names[0], offset))
            except e:
                self.message = "Couldn't paint " + log + " under the video: " + String(e)

    def make_link(mut self):
        """The panel's Link: the link is made (by a person), the trace says so, the panel lists it."""
        var l = self.ld.link()
        try:
            self.know_tables()
            var i = self.links.add(l)
            self.resolve_links()
            if i >= len(self.links) or not self.links.items[i].same(l):
                self.message = self.links.problem  # (its column isn't in the table it resolved to: unlinked, saying why)
                return
            self.links.problem = String("")
            self.links.notes[i] = l.a.card + " ↔ " + l.b.card + " · " + self.ld.choice().count.text() + " match"
            print(self.ld.line(), flush=True)
            self.message = "Linked " + l.label() + ("" if l.kind == LINK_TIME else " (" + self.ld.choice().count.text() + " match)")
            if l.kind == LINK_TIME:
                self.links.notes[i] = l.b.card + " runs with " + l.a.card + "'s clock"
                self.sync_lanes()
        except e:
            self.message = String(e)

    # ---------- folders of documents (mojoui.documentset), a row followed through the links, Export pack (mojoui.pack) ----------

    def open_documents(mut self, path: String):
        """Insert > Documents…: a folder of PDFs (or one) as a card on the sheet; its first page drawn by a job."""
        if self.screen != SHEET:
            self.open_blank()
            if self.screen != SHEET:
                return
        if len(self.docs) >= MAX_DOCS:
            self.message = "Two folders of documents is the most a sheet holds: close one first"
            self.version += 1
            return
        if self.doc_opening:
            self.message = "Still opening " + self.doc_opening_path
            self.version += 1
            return
        try:  # (listing it and opening its first PDF: a job, PyMuPDF's first import alone takes 0.1 s)
            var k = len(self.docs)
            self.doc_opening = open_folder_job(path, DOCS_MSG + k * SET_MESSAGES, DOCS_CANVAS + k)
            self.doc_opening_path = path
            self.say(Activity.running("Opening " + file_name(path), 0.0, "documents"))
        except e:
            self.message = "Couldn't open " + path + ": " + String(e)
        self.version += 1

    def documents_opened(mut self):
        """A folder opened by its job: its card placed on the sheet, its first page drawn by a job."""
        if not self.doc_opening or self.doc_opening.value().poll() == JOB_RUNNING:
            return
        var job = self.doc_opening.take()
        python_reclaim()
        var path = self.doc_opening_path
        try:
            var k = len(self.docs)
            var d = job.result()
            d.msg_base = DOCS_MSG + k * SET_MESSAGES  # (a card closed meanwhile: it takes the next place)
            d.card.msg_base = d.msg_base
            d.card.canvas = DOCS_CANVAS + k
            var spot = self.free_place(d.card.w, d.card.h)
            d.card.x = spot[0]
            d.card.y = spot[1]
            self.docs.append(d^)
            self.doc_feeds.append(FolderFeed())
            self.doc_feeds[k].poll(self.docs[k])
            self.reveal = 1 + len(self.objects) + len(self.media) + len(self.tables) + len(self.tracks) + k
            self.reveal_count += 1
            self.message = "Added " + self.docs[k].name + " · " + String(len(self.docs[k].files)) + " documents: say which fields to read, then Read"
            self.say(Activity.done(self.docs[k].name, String(len(self.docs[k].files)) + " documents"))
            if self.trace:
                print("DOCUMENTS: " + self.docs[k].name + " " + String(len(self.docs[k].files)) + " documents", flush=True)
        except e:
            self.message = "Couldn't open " + path + ": " + String(e)
            self.say(Activity.error("Couldn't open " + file_name(path), String(e)))
        self.version += 1

    def docs_busy(self) -> Bool:
        for k in range(len(self.doc_feeds)):
            if self.doc_feeds[k].busy():
                return True
        return False

    def docs_of(self, message: Int) -> Int:
        for k in range(len(self.docs)):
            if self.docs[k].owns(message):
                return k
        return -1

    def docs_event(mut self, k: Int, event: Event):
        """A folder card's event: its page, its file, its fields, Read (a job), close."""
        _ = self.docs[k].update(event)
        if self.docs[k].closed:
            _ = self.docs.pop(k)
            _ = self.doc_feeds.pop(k)
            for j in range(len(self.docs)):  # (the cards after it take its place: their messages and canvases follow)
                self.docs[j].msg_base = DOCS_MSG + j * SET_MESSAGES
                self.docs[j].card.msg_base = DOCS_MSG + j * SET_MESSAGES
                self.docs[j].card.canvas = DOCS_CANVAS + j
            self.version += 1
            return
        if self.docs[k].read_asked:
            self.doc_feeds[k].read(self.docs[k], OcrModel(), self.pal)
            if self.doc_feeds[k].error != "":
                self.message = self.doc_feeds[k].error
                self.doc_feeds[k].error = ""
            else:
                self.say(Activity.running("Reading " + self.docs[k].name, 0.0, String(len(self.docs[k].files)) + " documents · " + self.docs[k].labels_text))
                if self.trace:
                    print("JOB: start read " + self.docs[k].name + " " + String(len(self.docs[k].files)) + " documents · fields " + ", ".join(self.docs[k].columns()[1:].copy()), flush=True)
        if self.docs[k].problem != "":
            self.message = self.docs[k].problem
            self.docs[k].problem = ""
        self.doc_feeds[k].poll(self.docs[k])
        self.version += 1

    def poll_documents(mut self):
        """The folders' jobs: page pictures land, reads report their share, a finished read becomes its fields' table card."""
        self.documents_opened()
        for k in range(len(self.docs)):
            self.doc_feeds[k].poll(self.docs[k])
            if self.docs[k].reading:
                self.island.progress(Float64(max(self.docs[k].card.progress, 0)) / 100.0, String(max(self.docs[k].card.progress, 0)) + "% · reading " + self.docs[k].name, self.font, now_ns())
            var got = self.doc_feeds[k].take_read()
            if got:
                var r = got.take()
                var secs = r.seconds
                var card = r.card.take()
                var words = List[TextTable]()
                while len(r.words) > 0:
                    words.insert(0, r.words.pop())
                self.docs[k].take_read(words^, r.fields.copy())
                var name = self.docs[k].fields_name()
                var at = self.tables.find(name)
                if at >= 0:  # (read again: the old table gives way)
                    self.tables.remove(at)
                try:
                    var w = self.card_width(card.sheet.columns())
                    var spot = self.free_place(w, 320)
                    var t = self.tables.adopt(card^, spot[0], spot[1], w, 320)
                    self.reveal_table(t)
                    var found = 0
                    var total = 0
                    for fs in self.docs[k].fields:
                        for f in fs:
                            total += 1
                            if f.found:
                                found += 1
                    self.message = name + ": " + String(len(self.docs[k].files)) + " documents read, " + String(found) + " of " + String(total) + " fields found"
                    self.say(Activity.done(name, String(found) + " of " + String(total) + " fields · " + fixed(secs, 1) + " s"))
                    if self.trace:
                        print("JOB: landed read " + self.docs[k].name + " " + String(len(self.docs[k].files)) + " documents " + fixed(secs * 1000.0, 1) + " ms (" + String(found) + " of " + String(total) + " fields)", flush=True)
                except e:
                    self.message = "Couldn't show " + name + ": " + String(e)
                self.version += 1
            if self.doc_feeds[k].error != "":
                self.message = self.doc_feeds[k].error
                self.say(Activity.error("Couldn't read " + self.docs[k].name, self.doc_feeds[k].error))
                self.doc_feeds[k].error = ""
                self.version += 1

    def know_tables(mut self):
        """Tells the links which columns each table has (the page's own and every table card's): a key link on a column
        its table doesn't have is refused or unlinked, the panel saying why (D-1341)."""
        if self.has_table:
            var cols = List[String]()
            for c in range(self.frame.columns()):
                cols.append(self.frame.name(c))
            _ = self.links.know(self.name, cols)
        for k in range(len(self.tables)):
            var cols = List[String]()
            for c in range(self.tables.cards[k].sheet.columns()):
                cols.append(self.tables.cards[k].sheet.name(c))
            _ = self.links.know(self.tables.cards[k].name, cols)

    def resolve_links(mut self):
        """A link typed on a video's name joins its analysis' rows (End.table); a folder's name, its fields' table."""
        self.know_tables()
        var at = self.found_sheet_index()
        if self.video.found_path != "" and at >= 0:
            var k = self.card_of(self.video.found_path)
            if k >= 0:
                _ = self.links.resolve(self.media.cards[k].title(), self.tables.cards[at].name)
        for k in range(len(self.docs)):
            _ = self.links.resolve(self.docs[k].name, self.docs[k].fields_name())

    def row_selection(self, k: Int) -> Selection:
        """Table card k's selected row, whole (every column's text), its selected column's value as the selection's."""
        ref c = self.tables.cards[k]
        var row = c.grid.cur_row
        var names = List[String]()
        var cells = List[String]()
        for col in range(c.sheet.columns()):
            names.append(c.sheet.name(col))
            cells.append(c.sheet.display(col, row) if row >= 0 else String(""))
        var col = c.grid.cur_col
        var cname = c.sheet.name(col) if 0 <= col < c.sheet.columns() else String("")
        var value = c.sheet.display(col, row) if 0 <= col < c.sheet.columns() and row >= 0 else String("")
        return Selection(c.name, c.name, row, cname, value).with_row(names, cells)

    def video_rows(self, k: Int, column: String) -> CardRows:
        """Video card k's analysis rows as mojoui.links reads them (only `column`, t and frame: a selection reads few)."""
        var at = self.found_sheet_index()
        var table = self.found_table if self.found_table != "" else self.name
        var out = CardRows(self.media.cards[k].title(), table, [column, "t", "frame"])
        out.seeks("t", "frame")
        if self.video.found_path != self.media.cards[k].path or at == -2:
            return out^
        if at == -1:
            fill_rows(out, self.frame)
        else:
            fill_rows(out, self.tables.cards[at].sheet)
        return out^

    def video_table(self, k: Int) -> String:
        """The table holding video card k's analysis rows ("" none)."""
        if self.video.found_path != self.media.cards[k].path or self.found_sheet_index() == -2:
            return ""
        return self.found_table if self.found_table != "" else self.name

    def follow_row(mut self, k: Int):
        """Table card k's selected row, followed through the sheet's links (mojoui.links): linked videos seek to its first
        sighting, folders of documents show its document with the chosen field marked, linked tables select its rows."""
        var sel = self.row_selection(k)
        if sel.row < 0:
            return
        var follows = self.links.follow(sel)
        _ = self.media.poll()  # (a probe that landed since: the player knows its length before it seeks)
        if self.trace:
            var cells = String("")
            for i in range(min(len(sel.names), 4)):
                cells += (" " if i > 0 else "") + sel.names[i] + "=" + sel.cells[i]
            print("SELECT: " + sel.card + " row " + String(sel.row + 1) + " " + cells + " · " + String(len(follows)) + " linked", flush=True)
        var said = List[String]()
        for ref f in follows:
            var done = False
            for v in range(len(self.media)):  # a video whose rows the link reaches: it seeks
                if self.media.cards[v].kind != OBJ_VIDEO or not self.media.cards[v].player:
                    continue
                var vt = self.video_table(v)
                if not (self.media.cards[v].title() == f.card or (vt != "" and vt == f.table)):
                    continue
                var r = self.video_rows(v, f.column).react(f)
                if r.action == REACT_SEEK and r.time >= 0 and r.time < 1e299:
                    var at = r.time
                    var fps = self.media.cards[v].player.value().state.fps
                    if r.frame >= 0 and fps > 0:  # (the row's own frame, not its time rounded to text: mid-frame, so it lands on it)
                        at = (Float64(r.frame) + 0.5) / fps
                    self.media.cards[v].player.value().seek(at)
                    said.append(self.media.cards[v].title() + " at " + fixed(r.time, 2) + " s")
                if self.trace:
                    print(r.line(), flush=True)
                done = True
            for d in range(len(self.docs)):  # a folder whose fields the link reaches: its document, the field marked
                if self.docs[d].fields_name() != f.table and self.docs[d].name != f.card:
                    continue
                var r = self.docs[d].react(f)
                if self.trace:
                    print(r.line().replace("FOLLOW: " + self.docs[d].name, "FOLLOW: " + self.docs[d].name + " " + self.docs[d].file()), flush=True)
                    if r.action == REACT_HIGHLIGHT:
                        print("DOCUMENT: " + self.docs[d].name + " " + self.docs[d].file() + " field=" + self.docs[d].focus_name() + " page=" + String(r.page)
                              + " x=" + fixed(r.x, 3) + " y=" + fixed(r.y, 3) + " w=" + fixed(r.w, 3) + " h=" + fixed(r.h, 3), flush=True)
                if r.action == REACT_HIGHLIGHT:
                    said.append(self.docs[d].file() + " · " + self.docs[d].focus_name())
                self.doc_feeds[d].poll(self.docs[d])
                done = True
            if done:
                continue
            var t = self.tables.find(f.table)  # a table card the link reaches: its rows are selected
            if t >= 0 and t != k:
                ref c = self.tables.cards[t]
                var col = c.sheet.index(f.column)
                if col >= 0:
                    var rows = CardRows(c.name, c.name, [f.column])
                    fill_rows(rows, c.sheet)
                    var r = rows.react(f)
                    if r.action == REACT_SELECT and len(r.rows) > 0:
                        c.grid.select(r.rows[0], col)
                        c.grid.reveal_cell(r.rows[0], col, c.sheet)
                        said.append(c.name + " row " + String(r.rows[0] + 1))
                    if self.trace:
                        print(r.line(), flush=True)
        if len(said) > 0:
            self.message = sel.card + " row " + String(sel.row + 1) + " → " + "; ".join(said)
        self.version += 1

    def pack_rows(mut self, k: Int):
        """Export pack: per row of table card k, a PDF (the row; what its links reach: the linked tables' rows, the video's
        frame with the thing marked, the document's page with the field marked) and a clip of the video around it (faces
        blurred, the row's key burned in), written by one job to <documents>/pack/<key>.pdf and .mp4."""
        if self.packing:
            self.message = "A pack is being written already"
            return
        ref c = self.tables.cards[k]
        if c.sheet.rows() == 0 or c.sheet.columns() == 0:
            self.message = "Nothing to pack: " + c.name + " has no rows"
            return
        var folder = self.documents() + "/" + PACK_DIR
        make_dir(folder)
        var job = PackJob(self.video.found)
        var keep = c.grid.cur_row
        var keep_col = c.grid.cur_col
        var key_name = c.sheet.name(0)
        var n = 0
        for row in range(c.sheet.rows()):
            if not c.sheet.alive(row):
                continue
            var key = c.sheet.display(0, row)
            var title = capital(key_name.replace("_", " ")) + " " + key
            var p = Pack(title, c.name + (" · " + self.query_ask if self.query_ask != "" else String("")), "omxplorer · " + self.sheet_name + " · " + c.name + " row " + String(row + 1))
            p.colour(hex_of(self.pal.accent))
            var facts = List[Tuple[String, String]]()
            for col in range(min(c.sheet.columns(), 6)):
                facts.append((c.sheet.name(col), c.sheet.display(col, row)))
            c.grid.select(row, 0)
            var sel = self.row_selection(k)
            var follows = self.links.follow(sel)
            var frame_t = -1.0
            var frame_video = String("")
            var frame_boxes = List[Box]()
            var frame_no = -1
            var doc_path = String("")
            var doc_page = 0
            var doc_boxes = List[Box]()
            var doc_caption = String("")
            var tables = List[Tuple[String, List[String], List[String]]]()
            for ref f in follows:
                for v in range(len(self.media)):
                    var vt = self.video_table(v)
                    if self.media.cards[v].kind != OBJ_VIDEO or not (self.media.cards[v].title() == f.card or (vt != "" and vt == f.table)):
                        continue
                    var r = self.video_rows(v, f.column).react(f)
                    if r.action == REACT_SEEK and r.time < 1e299 and frame_t < 0:
                        frame_t = r.time
                        frame_no = r.frame
                        frame_video = self.media.cards[v].path
                        for b in self.boxes_at(f.column, f.value, r.frame):
                            frame_boxes.append(b)
                for d in range(len(self.docs)):
                    if self.docs[d].fields_name() != f.table and self.docs[d].name != f.card:
                        continue
                    var rows = self.docs[d].card_rows()
                    var r = rows.react(f)
                    if r.action == REACT_HIGHLIGHT and len(r.rows) > 0 and doc_path == "":
                        doc_path = self.docs[d].files[r.rows[0]]
                        doc_page = r.page
                        doc_boxes.append(Box(r.x, r.y, r.w, r.h))
                        var lbl = self.docs[d].labels[self.docs[d].focus].label if 0 <= self.docs[d].focus < len(self.docs[d].labels) else String("")
                        var val = self.docs[d].fields[r.rows[0]][self.docs[d].focus].value if r.rows[0] < len(self.docs[d].fields) and self.docs[d].focus < len(self.docs[d].fields[r.rows[0]]) else String("")
                        doc_caption = file_name(doc_path) + ", page " + String(r.page + 1) + ": " + lbl + " reads “" + val + "”"
                        facts.append((lbl + " (" + file_name(doc_path) + ")", val if val != "" else String("—")))
                var t = self.tables.find(f.table)
                if t >= 0 and t != k:
                    ref tc = self.tables.cards[t]
                    if tc.sheet.rows() <= 100_000 and tc.sheet.index(f.column) >= 0:
                        var cr = CardRows(tc.name, tc.name, [f.column])
                        fill_rows(cr, tc.sheet)
                        var r = cr.react(f)
                        if r.action == REACT_SELECT and len(r.rows) > 0 and tc.sheet.columns() <= 12 and self.video_table_index() != t:
                            var cols = List[String]()
                            var vals = List[String]()
                            for col in range(tc.sheet.columns()):
                                cols.append(tc.sheet.name(col))
                                vals.append(tc.sheet.display(col, r.rows[0]))
                            tables.append((tc.name, cols^, vals^))
            if frame_t >= 0:
                facts.append(("Seen on camera", clock_text(frame_t) + " · frame " + String(frame_no)))
            p.page("Evidence")
            p.facts(facts)
            if frame_t >= 0:
                p.video_frame(frame_video, frame_t, frame_boxes, file_name(frame_video) + " at " + clock_text(frame_t) + " (frame " + String(frame_no) + "): the first frame it is seen")
            for ref tb in tables:
                var rows = List[List[String]]()
                rows.append(tb[2].copy())
                p.table(tb[1], rows, tb[0])
            if doc_path != "":
                p.page("Document")
                p.pdf_page(doc_path, doc_page, doc_boxes, doc_caption)
            else:
                p.page("Document")
                p.text("No document is linked to this row.")
            job.add(p^, folder + "/" + key + ".pdf")
            if frame_t >= 0:
                job.clip(Clip(frame_video, folder + "/" + key + ".mp4", max(frame_t - 1.5, 0.0), frame_t + 4.5, title + " · {t}", True))
            n += 1
        if keep >= 0:
            c.grid.select(keep, keep_col)
        var card_name = c.name
        self.packing = start_ui_job(job^)
        self.pack_card = card_name
        self.say(Activity.running("Packing " + card_name, 0.0, String(n) + " rows · a PDF and a clip each"))
        if self.trace:
            print("JOB: start pack " + card_name + " " + String(n) + " rows", flush=True)
        self.version += 1

    def video_table_index(self) -> Int:
        return self.found_sheet_index()

    def boxes_at(self, column: String, value: String, frame: Int) -> List[Box]:
        """The analysis rows' boxes on `frame` whose `column` holds `value` (the thing a pack marks on its frame)."""
        var out = List[Box]()
        var at = self.found_sheet_index()
        if at == -2 or frame < 0:
            return out^
        var cols: List[String] = [column, "frame", "x", "y", "w", "h"]
        var rows = CardRows("", "", cols)
        if at == -1:
            fill_rows(rows, self.frame)
        else:
            fill_rows(rows, self.tables.cards[at].sheet)
        for r in range(rows.rows()):
            if rows.cell(r, 0) == value and rows.cell(r, 1) == String(frame):
                try:
                    out.append(Box(atof(rows.cell(r, 2)), atof(rows.cell(r, 3)), atof(rows.cell(r, 4)), atof(rows.cell(r, 5))))
                except:
                    pass
        return out^

    def poll_pack(mut self):
        if not self.packing or self.packing.value().poll() == JOB_RUNNING:
            if self.packing:
                var p = self.packing.value().progress()
                var share = Float64(p.done) / Float64(p.total) if p.total > 0 else 0.0
                self.island.progress(min(share, 1.0), String(Int(share * 100)) + "% · packing", self.font, now_ns())
            return
        var job = self.packing.take()
        try:
            var r = job.result()
            self.message = "Packed " + self.pack_card + ": " + String(len(r.pdfs)) + " PDFs and " + String(len(r.clips)) + " clips in your documents (" + PACK_DIR + ")"
            self.say(Activity.done("Packed " + self.pack_card, String(len(r.pdfs)) + " PDFs · " + String(len(r.clips)) + " clips · " + fixed(r.milliseconds / 1000.0, 1) + " s"))
            if self.trace:
                print("JOB: landed pack " + self.pack_card + " " + String(len(r.pdfs)) + " pdfs " + String(len(r.clips)) + " clips " + fixed(r.milliseconds, 1) + " ms", flush=True)
                for f in r.pdfs:
                    print("PACK: " + f, flush=True)
                for f in r.clips:
                    print("PACK: " + f, flush=True)
        except e:
            self.message = "Couldn't write the pack: " + String(e)
            self.say(Activity.error("Couldn't write the pack", String(e)))
        self.version += 1

    def open_editor(mut self, k: Int):
        """Card k's video in the editor (mojoui.mediatimeline), over the whole window: the analysis' rows as lanes (when
        this video was analyzed), its log's columns as lines, the sentence bar. Done comes back to the sheet."""
        if k < 0 or k >= len(self.media) or not self.media.cards[k].player:
            return
        var path = self.media.cards[k].path
        if not self.media.cards[k].player.value().ready():
            self.message = file_name(path) + " is still opening"
            self.version += 1
            return
        try:
            var tk = self.tracks.for_video(path)
            var log = Optional[TimeSeries](self.tracks.cards[tk].series.copy()) if tk >= 0 else Optional[TimeSeries](None)
            var was = self.video.busy()
            var t = self.media.cards[k].player.value().state.t()
            var ed = MediaTimeline.open_with(self.media.cards[k].player.value().info, EDITOR_MSG, EDITOR_CANVAS, at=t, log=log.copy(),
                                             room_w=self.win_w - 40, room_h=self.win_h - 32)  # (the card's probe: nothing waits)
            self.video.prepare_editor(ed, self.media, k, log^)  # (mojoui.videocard: its rows as lanes, or its analysis started)
            if not was and self.video.analyzing:
                self.analysis_started(k)
            self.editor = ed^
            self.feed.poll(self.editor.value())
            if self.trace:
                print("EDITOR: open " + file_name(path), flush=True)
        except e:
            self.say(Activity.error("Couldn't open the editor", String(e)))
        self.version += 1

    def start_analysis(mut self, k: Int, which: Int):
        """Analyzer `which` over card k's video, as a background job (mojoui.videocard): the card shows how far it is, the
        island too."""
        var log = Optional[TimeSeries](None)
        var tk = self.tracks.for_video(self.media.cards[k].path)
        if tk >= 0:
            log = self.tracks.cards[tk].series.copy()
        if not self.video.analyze(self.media, k, which, log^):
            self.message = self.video.problem
            if analyzer_needs_log(which) and tk < 0:
                self.say(Activity.error("No log for " + file_name(self.media.cards[k].path), "insert its CSV (t, lat, lon) first"))
            self.video.problem = ""
            return
        self.analysis_started(k)

    def analysis_started(mut self, k: Int):
        var which = self.video.analyzing_which
        if self.trace:
            print("JOB: start analyze " + file_name(self.media.cards[k].path) + " with " + analyzer_names()[which])
        self.say(Activity.running("Analyzing " + file_name(self.media.cards[k].path), 0.0, analyzer_names()[which]))

    def analysis_landed(mut self, var a: Analyzed):
        """The rows land as a table: the sheet's own when it's still the blank one the video opened with (beside the
        card, as tall as it), else a table card beside the video. The video's player marks what was found."""
        var path = self.video.analyzing_path
        var rows_name = analyzer_rows(a.analyzer, path)
        var name = rows_name if rows_name != analyzer_rows(a.analyzer) else file_name(path) + " · " + rows_name  # (a name with the video's in it stands alone)
        var rows = self.video.found.rows()  # (VideoWork kept the rows and marked the card's player)
        var secs = a.milliseconds / 1000.0
        var k = self.card_of(path)
        var blank = self.source == "blank" and self.frame.edits() == 0 and len(self.objects) == 0 and len(self.tiles) == 0
        try:
            if blank:
                self.adopt_table(a.take_sheet())
                self.source = path
                self.name = rows_name
                if a.analyzer == INSPECTION:
                    self.mark_track(path, place_marks(self.frame))
                self.table_title = name
                self.found_table = ""
            else:
                var x = 0
                var y = 0
                var w = 640
                var h = 400
                if k >= 0:
                    ref c = self.media.cards[k]
                    x = c.x + c.w + 16
                    y = c.y
                    w = max(self.sheet_width() - x, 480)
                    h = c.h
                var t = self.tables.add(name, a.take_sheet(), x, y, w, h, self.font, self.pal)
                var said = analyzer_names()[a.analyzer]
                var paren = said.find(" (")
                self.tables.cards[t].note = String(said[byte=:paren]) if paren > 0 else said  # (the analyzer, short: one line in the title bar)
                if a.analyzer == INSPECTION:
                    self.mark_track(path, place_marks(self.tables.cards[t].sheet))
                self.found_table = name
                self.reveal_table(t)
        except e:
            self.say(Activity.error("Couldn't show the rows", String(e)))
            self.version += 1
            return
        if self.editor:  # (the editor waiting on these rows: its lanes and chips)
            self.video.feed_editor(self.editor.value())
            self.feed.poll(self.editor.value())
        self.timed(a.milliseconds)
        if self.trace:
            print("JOB: landed analyze " + file_name(path) + " " + String(rows) + " rows " + fixed(a.milliseconds, 1) + " ms")
        self.message = name + ": " + grouped(rows) + " rows from " + grouped(self.video.found.frames) + " frames in " + fixed(secs, 1) + " s (classic GPU vision; a model plugs in later)"
        self.say(Activity.done(name, grouped(rows) + " rows · " + fixed(secs, 1) + " s"))
        self.version += 1

    def adopt_table(mut self, var sheet: Sheet):
        """A new table for the sheet's own, keeping what's on the sheet around it (the video card it came from)."""
        self.use_table(sheet^)
        self.seen_edits = self.frame.edits()
        self.grid = DataGrid()
        self.grid.prepare(self.frame, self.font, self.pal)
        for c in range(self.frame.stored()):
            if self.frame.kind(c) == TEXT:
                self.grid.fit(c, self.frame, self.font, self.pal)
        var nums = self.numbers()
        self.report_col = nums[0] if len(nums) > 0 else 0
        self.grid.select(0, 0)
        self.select_cell(0, 0)
        self.refresh()

    def found_sheet_index(self) -> Int:
        """Where the analysis' rows are: -1 the sheet's own table, a table card's index, or -2 nowhere (closed)."""
        if self.video.found_path == "":
            return -2
        if self.found_table == "":
            return -1 if self.source == self.video.found_path else -2
        var k = self.tables.find(self.found_table)
        return k if k >= 0 else -2

    def reel_flags(self) -> List[Int]:
        """The analysis table's columns a reel can keep frames by (its true/false columns)."""
        var at = self.found_sheet_index()
        if at == -1:
            return flag_columns(self.frame)
        if at >= 0:
            return flag_columns(self.tables.cards[at].sheet)
        return List[Int]()

    def open_reel(mut self, k: Int):
        """The Make a reel dialog for card k: its choices worked out once (captions: a text column of another table that
        names the codes the video read, found by its values)."""
        self.reel_card = k
        self.reel_flag = 0
        self.reel_caption = 0
        self.reel_captions = List[Tuple[String, Int, Int, Int]]()
        self.reel_captions.append(("None", -2, -1, -1))
        if self.video.found_path == self.media.cards[k].path:
            var codes = codes_of(self.video.found)
            var found_at = self.found_sheet_index()
            for t in range(len(self.tables)):
                if t == found_at:
                    continue
                ref sh = self.tables.cards[t].sheet
                for v in range(sh.columns()):
                    if sh.kind(v) != TEXT:
                        continue
                    var key = matching_column(sh, codes, v)
                    if key[0] >= 0 and key[1] > 0:
                        self.reel_captions.append((self.tables.sql_name_of(t) + " · " + sh.name(v), t, key[0], v))
            if found_at != -1 and self.has_table:  # (the sheet's own table can name them too)
                for v in range(self.frame.stored()):
                    if self.frame.kind(v) == TEXT:
                        var key = matching_column(self.frame, codes, v)
                        if key[0] >= 0 and key[1] > 0:
                            self.reel_captions.append((sql_name(self.name) + " · " + self.frame.name(v), -1, key[0], v))
            if len(self.reel_captions) > 1:
                self.reel_caption = 1  # (a caption when there's one to burn: the reel says whose pallet it is)

    def start_reel(mut self):
        """The reel as a background job: the frames where the chosen flag is true, cut from the card's video, faces
        blurred (when asked), the chosen column burned in; <documents>/<video>-reel.mp4, shown as a new card when done."""
        var k = self.reel_card
        if k < 0 or k >= len(self.media) or self.video.reeling:
            return
        var path = self.media.cards[k].path
        var flags = self.reel_flags()
        if self.video.found_path != path or len(flags) == 0:
            self.message = "Analyze " + file_name(path) + " first: a reel keeps the frames where a column of its rows is true"
            self.version += 1
            return
        var flag = flags[min(self.reel_flag, len(flags) - 1)]
        var at = self.found_sheet_index()
        var captions = List[Caption]()
        if 0 < self.reel_caption < len(self.reel_captions):
            var ch = self.reel_captions[self.reel_caption]
            var names = lookup(self.frame, ch[2], ch[3]) if ch[1] == -1 else lookup(self.tables.cards[ch[1]].sheet, ch[2], ch[3])
            var flag_name = self.frame.name(flag) if at == -1 else self.tables.cards[at].sheet.name(flag)
            captions = flagged_captions(self.video.found, self.video.flagged_kind(), names, flag_name)
        var out = self.documents() + "/" + file_stem(path) + "-reel.mp4"
        var started = self.video.reel(self.media, k, self.frame, flag, captions, self.reel_blur, out) if at == -1 else self.video.reel(self.media, k, self.tables.cards[at].sheet, flag, captions, self.reel_blur, out)
        if not started:  # (mojoui.videocard says why: no frame has the flag, one runs already)
            self.message = self.video.problem
            self.video.problem = ""
            self.version += 1
            return
        self.reel_card = -1
        if self.trace:
            print("JOB: start reel " + file_name(out))
        self.say(Activity.running("Making " + file_name(out), 0.0, "in the background"))
        self.version += 1

    def reel_landed(mut self, var r: Reel):
        self.timed(r.milliseconds)
        if self.trace:
            print("JOB: landed reel " + file_name(r.path) + " " + String(r.frames) + " frames " + fixed(r.milliseconds, 1) + " ms")
        self.open_media(r.path, 560)  # (a reel sits beside what it came from, a little smaller than its source)
        self.message = "Made " + file_name(r.path) + " · " + fixed(r.seconds, 1) + " s from " + file_name(self.video.reeling_path) + " (in your documents)"
        self.say(Activity.done(file_name(r.path), fixed(r.seconds, 1) + " s reel · " + fixed(r.milliseconds / 1000.0, 1) + " s"))
        self.version += 1

    def run_query(mut self):
        """The Query dialog's (or the toolbar's query field's) SQL over the sheet's tables (its own and every card's), as a
        job: the answer lands as a table card named as asked (run again under the same name: the same card)."""
        var called = String(self.query_name.strip())
        if called == "":
            called = "Query 1"
        var text = self.query_text
        var asked = String(self.query_ask.strip())
        if asked != "":  # (a question in words: taught with the SQL beside it, or answered by what was taught, mojoui.asksql)
            if String(text.strip()) != "":
                self.book.teach(asked, text)
            else:
                text = self.book.sql_for(asked)
                if text == "":
                    self.query_said = "No SQL for that question yet: write it once below, and the question will run it from then on"
                    self.version += 1
                    return
        try:
            text = implied_sql(text, self.links)  # (JOIN LINKED: the joins the sheet's key links imply)
        except e:
            self.query_said = String(e)
            self.message = String(e)
            self.version += 1
            return
        self.asked_sql = text
        if self.trace:
            print("ASK: " + ("\"" + asked + "\" → " if asked != "" else "") + text, flush=True)
        if self.work.ask(self.tables, text, self.name if self.has_table else String(""), self.frame, called, self.pal):
            self.query_said = "Running…"
            self.say(Activity.running(called, 0.0, "SQL in the background"))
        else:
            self.query_said = self.work.problem
            self.work.problem = ""
        self.version += 1

    def answer_landed(mut self, var a: Answer):
        var ms = a.milliseconds
        var called = a.card.name
        try:
            var w = self.card_width(a.card.sheet.columns())
            if len(self.links) > 0:  # (it gets Export pack below: room for its title bar)
                w = max(w, ACTION_MIN_W)
            var spot = self.free_place(w, 320)
            var k = self.tables.adopt(a^.take_card(), spot[0], spot[1], w, 320)
            self.reveal_table(k)
            self.timed(ms)
            self.links.forget_derived(called)  # (where its columns came from: a row of it follows like a row of its source)
            for l in lineage(self.asked_sql):
                for j in range(len(self.tables)):
                    if j != k and self.tables.sql_name_of(j) == l.table:
                        self.links.derive(Link.key(End(called, l.column), End(self.tables.cards[j].name, l.source), BY_AGENT))
            if len(self.links) > 0:
                self.tables.cards[k].act_with("Export pack", "download", "export-pack", "A PDF and a video clip for every row: what its links reach (the video's frame, the document's page, the linked rows), in your documents' pack folder")
            self.query_said = grouped(self.tables.cards[k].sheet.rows()) + " rows in " + fixed(shown_ms(ms), 1) + " ms"
            self.query_open = False
            self.message = called + ": " + self.query_said
            if self.trace:
                print("QUERY: " + called + " " + String(self.tables.cards[k].sheet.rows()) + " rows")
            self.say(Activity.done(called, self.query_said))
        except e:
            self.query_said = String(e)
        self.version += 1

    def seek_to_row(mut self, row: Int):
        """A row of an analysis selected: its video shows that moment (the row's t)."""
        if self.video.found_path == "" or self.source != self.video.found_path or row < 0:
            return
        var t = self.frame.index("t")
        var k = self.card_of(self.video.found_path)
        if t < 0 or k < 0 or not self.media.cards[k].player or self.frame.is_null(t, row):
            return
        self.media.cards[k].player.value().seek(Float64(self.frame.value(t, row)) / 1000.0)

    def imported(mut self, path: String, var imp: CsvImport, var sheet: Sheet, var shapes: List[List[Float64]]):
        """A file read (here or by a job): its Import step."""
        self.use_table(sheet^)
        self.imp = imp^
        self.source = path
        self.name = file_stem(path)
        self.preview = DataGrid()
        self.preview.browse = True
        self.preview.prepare(self.frame, self.font, self.pal)
        self.preview.histograms = shapes^
        self.import_col = 0
        self.screen = IMPORT
        self.message = ""
        remember(APP, path, self.recent)

    def shape_of(self, c: Int) -> List[Float64]:
        """A column's distribution over every row, for the header's small histogram."""
        try:
            return shape_of(self.frame, c)
        except:
            return List[Float64]()

    def open_sample(mut self):
        var rows = 1_000_000
        var asked = environment("OMX_ROWS")
        if asked != "":
            try:
                rows = max(Int(asked), 1000)
            except:
                pass
        try:
            self.use_table(Sheet(sample_table(rows).share()))
        except e:
            self.message = String(e)
            self.version += 1
            return
        self.source = "sample"
        self.name = "orders"
        self.to_sheet()

    def open_blank(mut self):
        try:
            self.use_table(Sheet(blank_table().share()))
        except e:
            self.message = String(e)
            self.version += 1
            return
        self.source = "blank"
        self.name = "Table 1"
        self.to_sheet()

    def to_sheet(mut self):
        self.screen = SHEET
        self.charts.forget()  # (the objects go: their jobs would land on the new ones)
        self.held = List[Tuple[Int, SheetObject]]()
        self.objects = List[SheetObject]()
        self.media.clear()  # (a new sheet starts without the old one's videos and pictures)
        self.tables.clear()  # (and its extra tables)
        self.tracks.clear()  # (and its logs)
        self.editor = None
        self.table_title = ""
        self.video.found_path = ""
        self.found_table = ""
        self.active = -1
        self.tiles = List[ReportTile]()
        self.filter = ReportFilter(-1, 0)
        self.sheet_tab = 0
        self.sheet_name = self.name
        self.report_name = "Report"
        self.renaming = -1
        self.picking = 0
        var nums = self.numbers()
        var money = self.first_number()  # (the first decimal column: revenue rather than an order number)
        self.report_col = money if self.frame.kind(money) == DECIMAL else (nums[0] if len(nums) > 0 else 0)  # (no number column: the first, for Distinct and Count)
        self.table_x = 0
        self.table_y = 0
        self.table_w = 0
        self.table_h_set = 0
        self.seen_edits = self.frame.edits()
        self.grid = DataGrid()
        self.grid.prepare(self.frame, self.font, self.pal)
        for c in range(self.frame.stored()):
            if self.frame.kind(c) == TEXT:
                self.grid.fit(c, self.frame, self.font, self.pal)
        self.grid.select(0, min(self.first_number(), self.frame.columns() - 1))
        self.select_cell(self.grid.cur_row, self.grid.cur_col)
        self.message = ("Imported " + grouped(self.frame.rows()) + " rows from " + file_name(self.source)) if self.source != "sample" and self.source != "blank" else ""
        if self.frame.streamed():
            self.message = "Streamed from " + file_name(self.source) + ": your edits are kept beside it until you save"
        self.version += 1

    def numbers(self) -> List[Int]:
        """The columns a chart or tile can sum (numbers and formulas)."""
        var out = List[Int]()
        for c in range(self.frame.columns()):
            if self.frame.kind(c) == INT or self.frame.kind(c) == DECIMAL:
                out.append(c)
        return out^

    def texts(self) -> List[Int]:
        """The columns a chart or pivot can group by."""
        var out = List[Int]()
        for c in range(self.frame.stored()):
            if self.frame.kind(c) == TEXT:
                out.append(c)
        return out^

    def groupings(self) -> List[Int]:
        """Text columns by how few values they have (2 or more): a new chart groups by the first (region before
        customer), a new pivot uses the first two."""
        var out = List[Int]()
        var used = List[Bool](length=self.frame.stored(), fill=False)
        for _ in range(len(self.texts())):
            var best = -1
            for c in self.texts():
                var n = groups_of(self.frame, c)
                if not used[c] and n >= 2 and (best < 0 or n < groups_of(self.frame, best)):
                    best = c
            if best < 0:
                break
            used[best] = True
            out.append(best)
        return out^

    def names_of(self, cols: List[Int]) -> List[String]:
        var out = List[String]()
        for c in cols:
            out.append(self.frame.name(c))
        return out^

    def index_in(self, cols: List[Int], col: Int) -> Int:
        for k in range(len(cols)):
            if cols[k] == col:
                return k
        return 0

    def refresh(mut self):
        """Every chart, pivot and tile again (after an edit or a change to one)."""
        self.seen_edits = self.frame.edits()
        try:
            for k in range(len(self.objects)):
                if self.big():
                    self.ask_chart(k, self.objects[k].copy())
                    continue
                compute(self.objects[k], self.frame)
            for k in range(len(self.tiles)):
                compute_tile(self.tiles[k], self.frame, self.filter)
        except e:
            self.message = "Couldn't compute: " + String(e)
        self.version += 1

    def ask_views(self) -> List[View]:
        """The ask field and what it said last (under the chart being asked about)."""
        var out = List[View]()
        out.append(TextField(self.ask_text, "Ask: top 3, unpaid, as a line", on_change=ASK_CHANGE, on_submit=ASK_SUBMIT).fill().tag("ask"))
        out.append(Text(self.ask_said if self.ask_said != "" else "Or tap any coloured word", CAPTION).tag("ask-said"))
        return out^

    def has_chart(self, cref: Int) -> Bool:
        """Whether `cref` names a chart: a sheet chart (0…39) or a Report chart tile (TILE_REF + k)."""
        if cref >= TILE_REF:
            return cref - TILE_REF < len(self.tiles) and self.tiles[cref - TILE_REF].kind == TILE_CHART
        return 0 <= cref < len(self.objects) and self.objects[cref].kind == OBJ_CHART

    def chart_of(self, cref: Int) -> SheetObject:
        return self.tiles[cref - TILE_REF].chart.copy() if cref >= TILE_REF else self.objects[cref].copy()

    def set_chart(mut self, cref: Int, var c: SheetObject, logged: Bool = True):
        """A chart's new spec: computed (a tile through the Report's filter) and only then put back and logged for Undo
        (one step per change: a word's choice, an ask, an inspector control); a spec that can't be computed changes
        nothing and says why."""
        var before = self.chart_of(cref)
        start_move(c, before)  # (the bars move from what they showed)
        try:
            if cref >= TILE_REF:
                var t = self.tiles[cref - TILE_REF].copy()
                t.chart = c^
                t.col = t.chart.value  # (compute_tile reads the tile's column and group)
                t.group = t.chart.group
                compute_tile(t, self.frame, self.filter)
                self.message = object_title(t.chart, self.frame)  # (the chart's short title: its sentence and its time are on it)
                self.tiles[cref - TILE_REF] = t^
            elif self.big():  # (its words change now; its numbers come from a job and the bars move when they land)
                self.message = object_title(c, self.frame)
                self.hold(cref)
                self.ask_chart(cref, c)
                var keep = self.objects[cref].copy()
                take_numbers(c, keep)  # (its own numbers stay the old ones until the new land: the picture is the held one)
                c.moved = MOVE_FRAMES
                self.objects[cref] = c^
            else:
                compute(c, self.frame)
                self.message = object_title(c, self.frame)
                self.objects[cref] = c^
            if logged:
                self.chart_undo.append((self.frame.undo_depth(), cref, before^))
            self.lit = List[Int]()  # (an ask sets its own marks after this)
        except e:
            self.message = "Couldn't compute that chart: " + String(e)
        self.version += 1

    def ask_here(mut self, cref: Int):
        """The ask field moves to chart `cref` (its last reply and marks go with the old one)."""
        if cref != self.asking:
            self.asking = cref
            self.ask_said = ""
            self.ask_text = ""
            self.lit = List[Int]()
            self.insp_page = 0

    def table_h(self) -> Int:
        if self.table_h_set > 0:
            return self.table_h_set
        return TABLE_H if len(self.objects) + len(self.media) > 0 else self.grid_h() - 30  # (the Board keeps 30 pt under it)

    def first_number(self) -> Int:
        for c in range(self.frame.columns()):
            if self.frame.kind(c) == DECIMAL:
                return c
        return 0

    # ---------- the selection and its totals ----------

    def select_cell(mut self, row: Int, col: Int):
        self.seek_to_row(row)
        self.edit_text = self.frame.plain_text(col, row) if row >= 0 and col >= 0 else ""
        if self.grid.has_block():  # a block: its own figures (a drag sends one per cell crossed: no column totals)
            self.block_lines = self.block_status()
            self.column_stats()  # (the inspector follows the selected cell's column during a block too)
        else:
            self.block_lines = List[String]()
            self.totals()
        self.version += 1

    def totals(mut self):
        """The selected column's sum and count of values over every row (edits included)."""
        var col = self.grid.cur_col
        if col < 0 or not self.has_table or self.frame.kind(col) == TEXT:
            self.sum = 0
            self.count = self.frame.rows()
            self.column_stats()
            return
        if self.big():  # (a column job: the status bar and the inspector fill in when it lands; the window stays live)
            if self.col_job:  # (the column before it: cancelled, kept until its thread stops: it reads the GPU copy)
                var old = self.col_job.take()
                old.cancel()
                self.col_orphans.append(old^)
            self.col_job = column_job(self.frame, col, self.inspector_open)
            self.col_started = now_ns()
            self.stats = List[Tuple[String, String]]()
            self.stats_key = ""
            if self.trace:
                print("JOB: start column " + self.frame.name(col))
            return
        try:
            var r = self.frame.totals(col)
            self.sum = r.sums[0]
            self.count = r.present[0]  # (empty cells aren't averaged)
            self.milliseconds = r.milliseconds
            self.ran_gpu = r.on_gpu
        except e:
            self.sum = 0
            self.count = 0
            self.message = "Couldn't total " + self.frame.name(col) + ": " + String(e)
        self.column_stats()

    def column_stats(mut self):
        """The inspector's cards for the selected number column: Mean, Median, Empty, Distinct (the engine's, recomputed
        only when the column or its numbers change)."""
        var col = self.grid.cur_col
        if col < 0 or not self.has_table or self.frame.kind(col) == TEXT or self.frame.kind(col) == DATE or self.frame.kind(col) == BOOL or not self.inspector_open:
            self.stats = List[Tuple[String, String]]()
            self.stats_key = ""  # (the inspector closed: nothing to show; computed again when it opens)
            return
        var key = String(col) + "/" + String(self.frame.rows()) + "/" + String(self.frame.edits()) + "/" + String(self.frame.format_of(col).style)
        if key == self.stats_key:
            return
        self.stats_key = key
        var total = 0  # (the column's own totals: the status bar's may be a block's, goal 25 M4)
        var present = 0
        try:
            var r = self.frame.totals(col)
            total = r.sums[0]
            present = r.present[0]
        except:
            pass
        var out = List[Tuple[String, String]]()
        out.append(("Mean", self.frame.format_average(col, total, present)))
        var median = String("—")  # (a streamed file: median and distinct read every row group, so they wait for a tile)
        try:
            if self.frame.scan:
                raise Error("streamed")
            var m = self.frame.median(col)
            if m[1]:
                median = self.frame.format_median(col, m[0])
        except:
            pass
        out.append(("Median", median))
        out.append(("Empty", grouped(self.frame.rows() - present)))
        var distinct = String("—")
        try:
            if self.frame.scan:
                raise Error("streamed")
            distinct = grouped(self.frame.distinct(col))
        except:
            pass
        out.append(("Distinct", distinct))
        self.stats = out^

    def column_format(self) -> ColumnFormat:
        return self.frame.format_of(self.grid.cur_col) if self.grid.cur_col >= 0 else ColumnFormat.auto()

    def set_format(mut self, var f: ColumnFormat):
        if self.grid.cur_col < 0:
            return
        self.frame.change_format(self.grid.cur_col, f)  # (Undo takes it back)
        self.grid.redraw()
        if self.grid.cur_row >= 0:
            self.select_cell(self.grid.cur_row, self.grid.cur_col)
        self.message = self.frame.name(self.grid.cur_col) + ": " + f.summary() + " (the whole column)"
        self.version += 1

    def uses(self, c: Int) -> String:
        """What reads column c and would break without it: a chart, a pivot, a Report tile or its filter ("" none)."""
        if c < 0:
            return ""
        for o in self.objects:
            if o.value == c or o.group == c or o.across == c or (o.kind == OBJ_CHART and (o.only_col == c or o.num_col == c)):
                return "a chart" if o.kind == OBJ_CHART else "a pivot"
        for t in self.tiles:
            if t.col == c or (t.kind == TILE_CHART and (t.group == c or t.chart.only_col == c or t.chart.num_col == c)):
                return "a Report tile"
        if self.filter.col == c:
            return "the Report's filter"
        return ""

    # ---------- cell formats ----------

    def style_target(mut self) -> Tuple[Int, Int]:
        """What a format tool changes: the selected cell (column, row), or (column, -1) when a whole column is
        selected; (-1, -1) and a message when nothing is."""
        if self.grid.cur_col < 0:
            self.message = "Select a cell, or a column by its header, then format it"
            self.version += 1
            return (-1, -1)
        return (self.grid.cur_col, self.grid.cur_row)

    def restyle(mut self, mask: Int, value: Int):
        var at = self.style_target()
        if at[0] < 0:
            return
        if self.grid.has_block():  # every cell of the block, one Undo step
            if self.grid.block_size(self.frame) > BLOCK_CAP:
                self.message = "That block has " + grouped(self.grid.block_size(self.frame)) + " cells: format up to " + grouped(BLOCK_CAP) + " at a time, or a whole column by its header"
                self.version += 1
                return
            var cells = self.block_cells()
            self.frame.restyle_cells(cells, mask, value)
            self.message = String(len(cells)) + " cells: " + self.frame.style_of(at[0], at[1]).words()
            self.grid.redraw()
            self.version += 1
            return
        self.frame.restyle(at[0], at[1], mask, value)
        self.after_style(at[0], at[1])

    def block_cells(self) -> List[Tuple[Int, Int]]:
        """The selected block's cells as (column, row), row by row (a single cell when there's no block)."""
        var out = List[Tuple[Int, Int]]()
        var b = self.grid.block(self.frame)
        if b[0] < 0:
            return out^
        for i in range(b[0], b[1] + 1):
            var row = self.grid.shown_row(i, self.frame)
            if row < 0 or not self.frame.grid_alive(row):
                continue
            for c in range(b[2], b[3] + 1):
                out.append((c, row))
        return out^

    def copy_block(mut self):
        """Edit > Copy: the cell or block as tab-separated text (cells as shown), onto the clipboard."""
        if self.grid.block_size(self.frame) > BLOCK_CAP:
            self.message = "That block has " + grouped(self.grid.block_size(self.frame)) + " cells: copy up to " + grouped(BLOCK_CAP) + " at a time"
            self.version += 1
            return
        var b = self.grid.block(self.frame)
        if b[0] < 0:
            self.message = "Select a cell or a block of cells to copy"
            self.version += 1
            return
        var text = String("")
        var lines = 0
        for i in range(b[0], b[1] + 1):
            var row = self.grid.shown_row(i, self.frame)
            if row < 0 or not self.frame.grid_alive(row):
                continue
            if lines > 0:
                text += "\n"
            for c in range(b[2], b[3] + 1):
                if c > b[2]:
                    text += "\t"
                text += self.frame.display(c, row)
            lines += 1
        self.clip_text = text
        self.clip_version += 1
        self.message = "Copied " + String(lines * (b[3] - b[2] + 1)) + " cells"
        self.version += 1

    def block_status(self) -> List[String]:
        """The block's figures for the status bar: Cells (its size), Count (non-empty), Sum and Average (its numbers),
        each number column totalled exactly at its own scale. Over BLOCK_CAP cells only its size (reading millions of
        cells one by one would stall the window; a Report tile totals whole columns on the engine)."""
        var out = List[String]()
        var size = self.grid.block_size(self.frame)
        if size > BLOCK_CAP:
            out.append("Cells " + grouped(size))
            out.append("Too many cells to total here (over " + grouped(BLOCK_CAP) + "): a Report tile totals whole columns")
            return out^
        var b = self.grid.block(self.frame)
        var cells = 0
        var filled = 0
        var numbers = 0
        var sums = List[Int64]()  # per column of the block, at its own scale
        for _ in range(b[2], b[3] + 1):
            sums.append(0)
        for i in range(b[0], b[1] + 1):
            var row = self.grid.shown_row(i, self.frame)
            if row < 0 or not self.frame.grid_alive(row):
                continue
            for c in range(b[2], b[3] + 1):
                cells += 1
                if self.frame.is_null(c, row):
                    continue
                filled += 1
                if self.frame.kind(c) == INT or self.frame.kind(c) == DECIMAL:
                    numbers += 1
                    sums[c - b[2]] += self.frame.value(c, row)
        out.append("Cells " + grouped(cells))
        out.append("Count " + grouped(filled))
        if numbers > 0:
            var scale = -1  # (none seen yet)
            var exact = True  # one scale: the total stays an exact integer
            var total = 0.0
            for c in range(b[2], b[3] + 1):
                if self.frame.kind(c) == INT or self.frame.kind(c) == DECIMAL:
                    var sc = self.frame.scale(c)
                    if scale >= 0 and sc != scale:
                        exact = False
                    scale = max(scale, sc)
                    total += Float64(sums[c - b[2]]) / Float64(pow10(sc))
            var one = Int64(0)
            for c in range(b[2], b[3] + 1):
                if self.frame.kind(c) == INT or self.frame.kind(c) == DECIMAL:
                    one += sums[c - b[2]]
            var sum_text = (("-" if one < 0 else "") + numfixed(one, scale, 2, True)) if exact else money2(total)
            out.append("Sum " + sum_text)
            out.append("Average " + money2(total / Float64(numbers)))
        return out^

    def after_style(mut self, col: Int, row: Int):
        var words = self.frame.style_of(col, row).words()
        if row >= 0:
            self.message = self.frame.name(col) + " on row " + grouped(row + 1) + ": " + words
        else:
            self.message = "Column " + self.frame.name(col) + ": " + words + " (the whole column)"
        self.grid.redraw()
        self.version += 1

    # ---------- events ----------

    def write_cell(mut self, text: String):
        if self.grid.editing and self.grid.cur_row >= 0 and self.grid.cur_col >= 0:
            try:
                var col = self.grid.cur_col
                var row = self.grid.cur_row
                var before = self.frame.display(col, row)
                self.frame.set_text(col, row, text)
                self.message = self.frame.name(col) + " on row " + grouped(row + 1) + ": " + before + " → " + self.frame.display(col, row)
                self.grid.committed(self.frame)
                self.select_cell(self.grid.cur_row, self.grid.cur_col)
            except e:
                self.edit_text = text
                self.message = String(e) + " (fix it and press Enter)"
        self.version += 1

    def update(mut self, event: Event):
        self.handle(event)
        if self.has_table and self.frame.edits() != self.seen_edits:  # the table changed (any way): every object and tile again
            self.refresh()
        self.island.still = environment("MOJOUI_REDUCE_MOTION") != ""
        var rest = self.rest_face()
        if rest.lead != self.island.rest.lead or rest.text != self.island.rest.text:
            self.island.set_rest(rest^, self.font, now_ns())
            self.island_v += 1

    def big(self) -> Bool:
        """A table big enough that its queries run in the background (the window stays live meanwhile); OMX_BIG_ROWS
        moves the line (checks run the background paths on small files with it)."""
        var line = BIG_ROWS
        var asked = environment("OMX_BIG_ROWS")
        if asked != "":
            try:
                line = Int(asked)
            except:
                pass
        return self.has_table and self.frame.rows() >= line

    def rest_face(self) -> Activity:
        """The island at rest: the document and where its queries run (nothing before there's a document)."""
        var device = (self.frame.device_name + " · ready") if self.frame.device else String("CPU")
        if self.screen != SHEET or not self.has_table:
            return Activity.idle(device, "")
        return Activity.idle(self.sheet_name, grouped(self.frame.rows()) + " rows · " + device)

    def say(mut self, var a: Activity, undo: Int = NO_MSG):
        """Something for the island to show now (and, when it's done or undoable, for Recent)."""
        if a.kind != ISLAND_RUNNING:
            self.ops.append((a.lead, a.text, undo))
            if len(self.ops) > 40:
                _ = self.ops.pop(0)
        self.island_undo = undo
        self.island.show(a^, self.font, now_ns())
        self.island_v += 1

    def timed(mut self, ms: Float64):
        self.timings.append(ms)
        if len(self.timings) > 12:
            _ = self.timings.pop(0)

    def device_words(self, on_gpu: Bool) -> String:
        return self.frame.device_name if on_gpu and self.frame.device else String("CPU")

    def ask_chart(mut self, cref: Int, spec: SheetObject):
        """Chart `cref`'s numbers from a background job (the island shows it running; poll_jobs puts them in)."""
        self.charts.ask(cref, spec, self.frame)
        if self.trace:
            print("JOB: start chart" + String(cref) + " " + object_title(spec, self.frame))
        if self.charts.cref == cref:
            self.say(Activity.running(capital(object_title(spec, self.frame)), 0.0, "starting"))

    def drop_jobs(mut self):
        """Every background job on the current table stopped and forgotten, waiting until each has really stopped (the
        table and its GPU copy are about to be given back; a cancel is seen between blocks of rows)."""
        self.charts.forget(wait=True)
        self.held = List[Tuple[Int, SheetObject]]()
        if self.col_job:
            self.col_job.value().cancel()
            _ = self.col_job.value().wait()
            self.col_job = None
        while len(self.col_orphans) > 0:
            var old = self.col_orphans.pop()
            _ = old.wait()
        self.stop_opening()  # (a file still being read would land over the document opened since)
        if self.trace:
            print("JOB: dropped every job")  # (nothing of the old table lands after this line)

    def stop_opening(mut self):
        """A file still being read: cancelled, and forgotten once its thread has stopped."""
        if self.opening:
            self.opening.value().cancel()
            _ = self.opening.value().wait()
            self.opening = None
            self.opening_path = ""

    def hold(mut self, cref: Int):
        """Chart `cref` keeps showing what it shows now (faded) until its new numbers land (the first hold wins: a second
        change while it waits still moves from the picture on screen)."""
        for h in self.held:
            if h[0] == cref:
                return
        if 0 <= cref < len(self.objects):
            self.held.append((cref, self.objects[cref].copy()))

    def held_of(self, cref: Int) -> Optional[SheetObject]:
        for h in self.held:
            if h[0] == cref:
                return h[1].copy()
        return None

    def let_go(mut self, cref: Int):
        var kept = List[Tuple[Int, SheetObject]]()
        for h in self.held:
            if h[0] != cref:
                kept.append(h.copy())
        self.held = kept^

    def poll_jobs(mut self):
        """When a job's end wakes the UI (JOBS_WAKE), and at the island's frames while work runs (hosts without the wake
        find it there): landed charts move to their numbers, the column's figures arrive, the table work lands, the
        island follows (progress, then the time it took)."""
        self.take_table_work()
        self.poll_documents()
        self.poll_pack()
        if self.media.poll():  # (a video's probe or frame that landed: on frames too, for hosts without the wake, D-1264)
            self.version += 1
        if self.opening:
            var state = self.opening.value().poll()
            if state == JOB_RUNNING:
                var p = self.opening.value().progress()
                var share = Float64(p.done) / Float64(p.total) if p.total > 0 else 0.0
                self.island.progress(min(share, 1.0), String(Int(min(share, 1.0) * 100)) + "%", self.font, now_ns())
            else:
                var job = self.opening.take()
                var path = self.opening_path
                try:
                    var o = job.result()
                    var ms = o.milliseconds
                    self.imported(path, o.take_import(), o.take_sheet(), o.take_shapes())
                    self.timed(ms)
                    if self.trace:
                        print("JOB: landed open " + file_name(path) + " " + fixed(ms, 1) + " ms")
                    self.say(Activity.done(file_name(path), grouped(self.frame.rows()) + " rows ready · " + fixed(ms / 1000.0, 1) + " s"))
                except e:
                    self.say(Activity.error("Couldn't open " + file_name(path), String(e)))
                self.version += 1
        var shown = self.video.progress(self.media)  # (mojoui.videocard: the card's percent follows; the island says it)
        if shown[0] >= 0:
            self.island.progress(shown[0], shown[1], self.font, now_ns())
            self.version += 1
        var analysed = self.video.take_analysis(self.media)
        if analysed:
            self.analysis_landed(analysed.take())
        var reel = self.video.take_reel(self.media)
        if reel:
            self.reel_landed(reel.take())
        if self.video.problem != "":
            self.say(Activity.error("Couldn't finish", self.video.problem))
            self.message = self.video.problem
            self.video.problem = ""
            self.version += 1
        if self.comparing and self.comparing.value().poll() != JOB_RUNNING:
            var job = self.comparing.take()
            try:
                self.compare_landed(job.result())
            except e:
                self.say(Activity.error("Couldn't compare", String(e)))
                self.version += 1
        if len(self.col_orphans) > 0:
            var kept = List[Job[ColumnFigures]]()
            while len(self.col_orphans) > 0:
                var job = self.col_orphans.pop()
                if not stopped(job):
                    kept.append(job^)
            self.col_orphans = kept^
        var was = self.charts.cref
        while True:
            var got = self.charts.poll(self.frame)
            if self.charts.failed >= 0:  # (its old picture goes too: the chart shows what it has, and the island why)
                self.let_go(self.charts.failed)
                self.say(Activity.error("Couldn't compute the chart", self.charts.failure))
                self.version += 1
                continue
            if not got:
                break
            var cref = got.value()[0]
            var done = got.value()[1].copy()
            if 0 <= cref < len(self.objects):
                var obj = self.objects[cref].copy()
                var shown = self.held_of(cref)
                var before = shown.value().copy() if shown else obj.copy()
                self.let_go(cref)
                take_numbers(obj, done)
                if obj.kind == OBJ_CHART:
                    start_move(obj, before)  # (the bars move from what they showed to the answer)
                self.objects[cref] = obj^
                self.timed(done.milliseconds)
                var took = fixed(shown_ms(done.milliseconds) / 1000.0, 2) + " s on " + self.device_words(self.charts.landed_gpu)
                if self.trace:
                    print("JOB: landed chart" + String(cref) + " " + fixed(done.milliseconds, 1) + " ms")
                    print("CHART: chart" + String(cref) + "\n" + chart_text(self.objects[cref], self.frame).replace("\t", " | "))
                if not self.charts.running() and len(self.charts.waiting) == 0:  # (a cancelled thread still stopping isn't more work)
                    self.say(Activity.done(capital(object_title(self.objects[cref], self.frame)), took))
            self.version += 1
        if self.charts.running():
            if self.charts.cref != was:
                self.say(Activity.running(capital(object_title(self.charts.spec, self.frame)), 0.0, "starting"))
            var secs = self.charts.seconds()
            var speed = pace(self.charts.rows_done(), secs)
            self.island.progress(self.charts.share(), String(Int(self.charts.share() * 100)) + "% · " + (speed if speed != "" else fixed(secs, 1) + " s"), self.font, now_ns())
        if self.col_job:
            var state = self.col_job.value().poll()
            if state != JOB_RUNNING:
                var job = self.col_job.take()
                if state == JOB_DONE:
                    try:
                        var f = job.result()
                        if f.col == self.grid.cur_col:
                            self.sum = f.sum
                            self.count = f.present
                            self.milliseconds = f.milliseconds
                            self.ran_gpu = f.on_gpu
                            self.stats = self.figures_cards(f)
                            self.timed(f.milliseconds)
                            if self.trace:
                                print("JOB: landed column " + self.frame.name(f.col) + " " + fixed(f.milliseconds, 1) + " ms")
                    except e:
                        self.message = "Couldn't total: " + String(e)
                self.version += 1

    def figures_cards(self, f: ColumnFigures) -> List[Tuple[String, String]]:
        """The inspector's cards from a column job's figures."""
        var out = List[Tuple[String, String]]()
        out.append(("Mean", self.frame.format_average(f.col, f.sum, f.present)))
        out.append(("Median", self.frame.format_median(f.col, Int64(f.median)) if f.has_median else String("—")))
        out.append(("Empty", grouped(self.frame.rows() - f.present)))
        out.append(("Distinct", grouped(f.distinct) if f.distinct >= 0 else String("—")))
        return out^

    def handle(mut self, event: Event):
        var m = event.message
        if self.editor and self.editor.value().owns(m):  # (the editor over the window: its own messages)
            _ = self.editor.value().update(event)
            self.feed.poll(self.editor.value())
            if self.editor.value().closed:
                self.editor = None
                if self.trace:
                    print("EDITOR: done", flush=True)
                self.version += 1
            return
        if self.links.owns(event.message):
            self.know_tables()  # (a typed link is checked against its tables' columns)
        if self.links.update(event):  # (the Links panel: Unlink, an offset, a link typed)
            self.resolve_links()
            if self.links.problem != "":
                self.message = self.links.problem
            if self.trace and m - LINKS_MSG == LINKS_ADD and self.links.problem == "" and len(self.links) > 0:  # (LINKS_ADD: the link typed)
                print("LINK: " + self.links.items[len(self.links) - 1].label() + " (typed)", flush=True)
            self.sync_lanes()
            self.version += 1
            return
        if self.ld.update(event):  # (the link panel: Link, Cancel, a column picked)
            if self.ld.confirmed:
                self.make_link()
            self.version += 1
            return
        if m == HOLD:  # (a card held still: the peek; let go: it settles back)
            if event.text == "hold" and not self.ld.busy():
                var cards = self.drop_cards()
                for c in cards:
                    if c.index == event.number:
                        self.peek.show(c.name, cards, self.links)
                if self.peek.open:
                    print(self.peek.line(), flush=True)
                    self.message = self.peek.say()
            elif event.text == "release":
                self.peek.close()
            self.version += 1
            return
        if m == PEEK_FRAME:
            _ = self.peek.step(event.number)
            if self.peek.settled:
                print("PEEK: done", flush=True)
                self.message = ""
            self.version += 1
            return
        if m == LINKS_TOGGLE:
            self.links_open = not self.links_open
            if self.links_open:
                self.inspector_open = True
            self.version += 1
            return
        if self.tracks.update(event, self.font, self.pal):  # (a log's chart tapped or set: its video seeks; a column picked; close)
            if self.tracks.seek_card >= 0:
                var video = self.tracks.cards[self.tracks.seek_card].video
                self.seek_video(video, self.tracks.seek_to)
            self.version += 1
            return
        if self.media.update(event):  # (a video card's play, pause, seek and frames; a card's close; its actions)
            if self.media.closed >= 0:
                self.message = ""
                self.analyze_card = -1
                self.reel_card = -1
                self.version += 1
            elif self.media.acted == ACT_ANALYZE:  # (the analyzer that fits starts at once; the popover offers the others, D-1701)
                var k = self.media.acted_card
                self.analyze_card = k
                if not self.video.busy() and self.video.found_path != self.media.cards[k].path:
                    self.start_analysis(k, self.default_analyzer(k))
                self.version += 1
            elif self.media.acted == ACT_REEL:
                self.open_reel(self.media.acted_card)
                self.version += 1
            elif self.media.acted == ACT_EDIT:
                self.open_editor(self.media.acted_card)
            return
        var dk = self.docs_of(m)
        if dk >= 0:  # (a folder of documents: its pages, its files, its fields, Read)
            self.docs_event(dk, event)
            return
        if self.tables.update(event, self.font, self.pal, self.documents()):  # (a table card's grid, Export CSV, close)
            if self.tables.dragged >= 0:  # (a column's header carried out of its card: a link being made)
                self.column_dragged()
            elif self.tables.export_asked >= 0:  # (a card's Export CSV: written by a job, the message when it lands)
                if self.work.export(self.tables.cards[self.tables.export_asked].sheet, self.tables.export_path):
                    self.say(Activity.running("Exporting " + file_name(self.tables.export_path), 0.0, self.tables.cards[self.tables.export_asked].facts()))
                else:
                    self.message = self.work.problem
                    self.work.problem = ""
            elif self.tables.problem != "":
                self.say(Activity.error("Couldn't export", self.tables.problem))
            elif self.tables.acted >= 0:
                if self.tables.cards[self.tables.acted].action_tag == "export-pack":
                    self.pack_rows(self.tables.acted)
                else:
                    self.write_plan(self.tables.acted)
            elif self.tables.selected >= 0:  # (a row picked, by hand or set by an agent: followed through the links)
                self.follow_row(self.tables.selected)
            self.version += 1
            return
        if m != CELL_COMMIT and m != CELL_CANCEL and m != GRID and self.grid.editing:
            self.grid.cancel_edit()
            self.version += 1
        if m == PICK_DOCS:
            self.inserting = 0
            if event.text != "":
                self.open_documents(event.text)
            return
        if m == PICK or (m >= RECENT and m < RECENT + 10):
            self.inserting = 0  # (Insert > Video…'s dialog picked its file)
            var path = event.text if m == PICK else (self.recent[m - RECENT] if m - RECENT < len(self.recent) else String(""))
            if path != "":
                self.open_path(path)
        elif m == SAMPLE:
            self.open_sample()
        elif m == BLANK:
            self.open_blank()
        elif m == CREATE:
            self.to_sheet()
        elif m == BACK:
            self.screen = START_SCREEN
            self.version += 1
        elif m == IMPORT_COLUMN:
            self.import_col = event.number
            self.version += 1
        elif m == GRID and event.number == SECONDARY:  # a right click: the column's menu where it happened
            var col = self.grid.header_hit(event.x, event.y, self.frame)
            if col < 0:
                var rc = self.grid.cell_hit(event.x, event.y, self.frame)
                col = rc[1]
                if rc[0] >= 0 and rc[1] >= 0:
                    self.grid.select(rc[0], rc[1])
                    self.select_cell(rc[0], rc[1])
            self.ctx_col = col
            self.ctx_x = Int(event.x)
            self.ctx_y = Int(event.y)
            self.version += 1
        elif m == MENU_CLOSE:
            self.ctx_col = -1
            self.version += 1
        elif m == SETTINGS or m == SETTINGS_CLOSE:
            self.settings_open = m == SETTINGS
            self.version += 1
        elif m == ABOUT or m == ABOUT_CLOSE:
            self.about_open = m == ABOUT
            self.version += 1
        elif m == FX_HELP or m == HELP_CLOSE:
            self.help_open = m == FX_HELP and not self.help_open
            self.version += 1
        elif m == SKIN:
            if 0 <= event.number < 4:
                var all: List[Int] = [LIQUID, LEDGER, GRAPHITE, BLUEPRINT]
                self.skin = all[event.number]
                write_setting(APP, "skin", skin_name(self.skin))
                self.restyle()
            self.version += 1
        elif m == APPEARANCE:
            if 0 <= event.number < 3:
                self.appearance_mode = event.number
                write_setting(APP, "appearance", "light" if event.number == LIGHT else ("dark" if event.number == DARK else "system"))
                self.restyle()
            self.version += 1
        elif m == TIMINGS:
            self.show_timings = event.number == 1
            write_setting(APP, "timings", "yes" if self.show_timings else "no")
            self.version += 1
        elif m == KEEP_INSPECTOR:
            self.inspector_open = event.number == 1
            write_setting(APP, "inspector", "yes" if self.inspector_open else "no")
            self.version += 1
        elif m == TOAST_CLOSE:
            self.toast = ""
            self.version += 1
        elif m == UNDO_SORT:
            self.grid.clear_order()
            self.toast = ""
            self.message = "Sort undone"
            self.say(Activity.done("Sort undone", ""))
            self.version += 1
        elif m == JOBS_WAKE:  # (a job ended or a decoder landed a frame: take it now, not at the next display frame)
            self.poll_jobs()
            if self.media.poll():
                self.version += 1
            if self.editor:
                self.feed.poll(self.editor.value())
        elif m == ISLAND_FRAME:
            self.poll_jobs()
            if self.island.tick(self.font, now_ns()):
                self.island_undo = NO_MSG
            self.island_v += 1
        elif m == ISLAND_TAP and event.number == TAP:
            var hit = self.island.hit(event.x, event.y, t=now_ns())
            if hit == HIT_ACTION and self.island.now.kind == ISLAND_UNDO and self.island_undo != NO_MSG:
                var undo = self.island_undo
                self.island_undo = NO_MSG
                self.handle(Event(undo, "", 0))
            elif hit == HIT_ACTION and self.island.now.kind == ISLAND_ERROR:
                self.island.seen(self.font, now_ns())
            elif hit != 0:
                self.panel_open = not self.panel_open
            self.island_v += 1
            self.version += 1
        elif m == PANEL_CLOSE:
            self.panel_open = False
            self.version += 1
        elif m == PREVIEW:  # (only scrolling: the preview selects and edits nothing)
            if event.number == PAN or event.number == ZOOM or event.number == PRESS or event.number == RELEASE:  # (browse: no selecting)
                _ = self.preview.handle(event, self.frame, self.font, self.pal)
        elif m == GRID:
            var action = self.grid.handle(event, self.frame, self.font, self.pal)
            if action == GRID_SELECTED or action == GRID_EDIT or action == GRID_READ_ONLY or action == GRID_COLUMN:
                self.select_cell(self.grid.cur_row, self.grid.cur_col)
                if action == GRID_EDIT:
                    self.message = "Editing " + self.frame.name(self.grid.cur_col) + " on row " + grouped(self.grid.cur_row + 1) + ": Enter writes it, Escape cancels"
                elif action == GRID_READ_ONLY:
                    self.message = self.frame.name(self.grid.cur_col) + " is a formula: edit the columns it uses"
                elif action == GRID_COLUMN:
                    self.message = "Column " + self.frame.name(self.grid.cur_col) + ": format it in the inspector, or Sort"
            elif action == GRID_TYPED:
                self.select_cell(self.grid.cur_row, self.grid.cur_col)
                self.edit_text = self.grid.typed
            elif action == GRID_CANCEL:
                self.select_cell(self.grid.cur_row, self.grid.cur_col)
                self.message = "Edit cancelled"
            elif action == GRID_COMMIT:
                var typed = String(self.grid.typed)
                self.write_cell(typed)
            elif action == GRID_CLEAR:
                try:
                    self.frame.set_text(self.grid.cur_col, self.grid.cur_row, "")
                    self.select_cell(self.grid.cur_row, self.grid.cur_col)
                except:
                    self.message = self.frame.name(self.grid.cur_col) + " can't be empty yet: type a value"
            if action != 0:
                self.version += 1
        elif m == CELL_COMMIT or m == FX_COMMIT:
            if m == FX_COMMIT and not self.grid.editing:
                self.grid.editing = True  # (the formula bar edits the selected cell)
            self.write_cell(event.text)
        elif m == CELL_CANCEL:
            self.grid.cancel_edit()
            self.select_cell(self.grid.cur_row, self.grid.cur_col)
            self.message = "Edit cancelled"
        elif m == INSP_TAB:
            self.insp_tab = event.number
            self.version += 1
        elif m == TOGGLE_INSPECTOR:
            self.inspector_open = not self.inspector_open or self.links_open  # (from the Links panel: the inspector's own)
            self.links_open = False
            self.column_stats()
            self.version += 1
        elif m == FORMAT:
            var f = self.column_format()
            var kind = self.frame.kind(self.grid.cur_col) if self.grid.cur_col >= 0 else TEXT
            if kind == DATE:
                f.style = AUTO if event.number == 0 else DATE_LONG + event.number - 1
            else:
                f.style = event.number
                if f.style == CURRENCY and f.decimals < 0:
                    f.decimals = 2
                if f.style == PERCENT and f.decimals < 0:
                    f.decimals = 1
            self.set_format(f^)
        elif (m == DECIMALS_LESS or m == DECIMALS_MORE) and (self.grid.cur_col < 0 or not (self.frame.kind(self.grid.cur_col) == INT or self.frame.kind(self.grid.cur_col) == DECIMAL)):
            self.message = "Decimal places apply to number columns"
            self.version += 1
        elif m == DECIMALS_LESS or m == DECIMALS_MORE:
            var f = self.column_format()
            if f.style == AUTO:
                f.style = NUMBER
            var now = f.decimals if f.decimals >= 0 else (self.frame.scale(self.grid.cur_col) if self.frame.kind(self.grid.cur_col) == DECIMAL else 0)
            f.decimals = max(0, min(6, now + (1 if m == DECIMALS_MORE else -1)))
            self.set_format(f^)
        elif m == THOUSANDS:
            var f = self.column_format()
            if f.style == AUTO:
                f.style = NUMBER
            f.thousands = event.number == 1
            self.set_format(f^)
        elif m == NEGATIVES:
            var f = self.column_format()
            if f.style == AUTO:
                f.style = NUMBER
            f.parens = event.number == 1
            self.set_format(f^)
        elif m == SYMBOL:
            var f = self.column_format()
            f.style = CURRENCY
            f.symbol = materialize[SYMBOLS]()[event.number]
            if f.decimals < 0:
                f.decimals = 2
            self.set_format(f^)
        elif m == COPY:
            self.copy_block()
        elif m == ADD_ROW:
            try:
                var row = self.frame.append()
                self.grid.select(row, max(self.grid.cur_col, 0))
                self.grid.keep_in_view(row, max(self.grid.cur_col, 0), self.frame)
                self.select_cell(row, max(self.grid.cur_col, 0))
                self.message = "Row " + grouped(row + 1) + " added: type to fill it"
            except e:
                self.message = String(e)
            self.version += 1
        elif m == NEW_FORMULA:
            self.formula_open = not self.formula_open
            self.version += 1
        elif m == FORMULA_SUBMIT:
            try:
                var c = self.frame.formula(event.text)
                self.grid.min_widths = List[Float64]()
                self.grid.prepare(self.frame, self.font, self.pal)
                self.grid.select(max(self.grid.cur_row, 0), c)
                self.grid.reveal_cell(max(self.grid.cur_row, 0), c, self.frame)
                self.select_cell(self.grid.cur_row, c)
                self.formula_open = False
                self.message = "New column " + self.frame.name(c) + " = " + event.text
            except e:
                self.message = String(e)
            self.version += 1
        elif m == SORT or m == SORT_ASC or m == SORT_DESC:
            var col = self.ctx_col if self.ctx_col >= 0 else self.grid.cur_col
            self.ctx_col = -1
            if col >= 0:
                var desc = (not self.grid.sort_desc) if self.grid.sort_col == col else self.frame.kind(col) != TEXT
                if m == SORT_ASC:
                    desc = False
                elif m == SORT_DESC:
                    desc = True
                try:
                    self.grid.set_order(self.frame.permutation(col, desc), col, desc)
                    self.message = "Sorted by " + self.frame.name(col) + (" (largest first)" if desc else "")
                    self.say(Activity.undo("Sorted by " + self.frame.name(col), "largest first" if desc else "smallest first"), UNDO_SORT)
                except e:
                    self.message = "Couldn't sort: " + String(e)
            self.version += 1
        elif m == FMT_NUMBER or m == FMT_CURRENCY or m == FMT_PERCENT:
            var col = self.ctx_col if self.ctx_col >= 0 else self.grid.cur_col
            self.ctx_col = -1
            if col >= 0 and self.frame.kind(col) != TEXT and self.frame.kind(col) != DATE:
                if col != self.grid.cur_col:  # (the context menu's column: select it, keeping a whole-column selection whole)
                    self.grid.select(max(self.grid.cur_row, 0), col)
                var f = self.frame.format_of(col)
                var style = NUMBER if m == FMT_NUMBER else (CURRENCY if m == FMT_CURRENCY else PERCENT)
                f.style = AUTO if f.style == style else style  # (chosen again: back to automatic)
                if f.style == CURRENCY and f.decimals < 0:
                    f.decimals = 2
                if f.style == PERCENT and f.decimals < 0:
                    f.decimals = 1
                self.set_format(f^)
            else:
                self.message = "Formats apply to number columns"
                self.version += 1
        elif m == SHOW_REPORT or m == SHOW_SHEET:
            self.sheet_tab = 1 if m == SHOW_REPORT else 0
            self.renaming = -1
            self.picking = 0
            self.version += 1
        elif m == SAVE:
            var folder = environment("OMX_DOCUMENTS", environment("HOME", ".") + "/Documents/omxplorer")
            make_dir(folder)
            var path = folder + "/" + self.name + ".omx"
            try:
                var tabs: List[String] = [self.sheet_name, self.report_name]
                save_omx(path, self.frame, self.objects, self.tiles, self.filter, tabs)
                self.source = path
                remember(APP, path, self.recent)
                self.message = "Saved " + path
            except e:
                self.message = "Couldn't save: " + String(e)
            self.version += 1
        elif m == INSERT_CHART or m == INSERT_PIVOT:
            var texts = self.groupings()
            if len(self.objects) >= MAX_OBJECTS:
                self.message = "A sheet holds up to " + String(MAX_OBJECTS) + " charts and pivots: remove one first"
            elif len(texts) == 0 or len(self.numbers()) == 0:
                self.message = "A chart needs a number column and a text column to group by"
            else:
                var value = self.grid.cur_col if self.grid.cur_col >= 0 and (self.frame.kind(self.grid.cur_col) == INT or self.frame.kind(self.grid.cur_col) == DECIMAL) else self.numbers()[0]
                var width = self.sheet_width()
                var w = 520 if m == INSERT_CHART else max(width - 520 - 16, 520)  # (a chart and a pivot side by side)
                var spot = free_spot(self.objects, self.table_y + (self.table_h_set if self.table_h_set > 0 else TABLE_H), width, w, 340)  # (below the table as it'll be once objects share the sheet, wherever it is)
                var obj = SheetObject.chart(value, texts[0], spot[0], spot[1], w, 340) if m == INSERT_CHART else SheetObject.pivot(value, texts[0], texts[1] if len(texts) > 1 else -1, spot[0], spot[1], w, 340)
                var problem = String("")
                var later = self.big()
                try:
                    if not later:
                        compute(obj, self.frame)
                except e:
                    problem = String(e)
                if later:
                    self.ask_chart(len(self.objects), obj)
                self.objects.append(obj^)
                self.active = len(self.objects) - 1
                if m == INSERT_CHART:
                    self.ask_here(self.active)
                    self.inspector_open = True  # (a new chart opens its inspector: the toolbar only inserts)
                self.insp_tab = 2
                self.reveal = self.active + 1  # (child 0 is the table)
                self.reveal_count += 1
                if problem != "":  # (said, not replaced by the chart's timing)
                    self.message = "Couldn't compute the " + ("chart" if m == INSERT_CHART else "pivot") + ": " + problem
                else:
                    self.message = ("Chart: " if m == INSERT_CHART else "Pivot: ") + object_title(self.objects[self.active], self.frame) + " (" + fixed(shown_ms(self.objects[self.active].milliseconds), 1) + " ms on " + self.frame.last_device() + (", streamed from disk" if self.frame.streamed() else "") + ")"  # (once, when it lands: where it ran)
            self.version += 1
        elif m == INSERT_VIDEO or m == INSERT_IMAGE or m == INSERT_TABLE:
            self.inserting = OBJ_VIDEO if m == INSERT_VIDEO else (OBJ_IMAGE if m == INSERT_IMAGE else OBJ_TABLE)
            self.version += 1
        elif m == PICK_TABLE:
            self.inserting = 0
            self.analyze_card = -1  # (the rail's Table pressed: an open Analyze popover goes, as any press outside it)
            if event.text != "":
                if self.screen != SHEET:  # (from the Start screen: a blank sheet to put the table card on)
                    self.open_blank()
                self.add_table_file(event.text)
        elif m >= ANALYZE_WITH and m < ANALYZE_WITH + 10:
            var k = self.analyze_card
            self.analyze_card = -1
            var running = self.video.busy() and 0 <= k < len(self.media) and self.video.analyzing_path == self.media.cards[k].path and self.video.analyzing_which == m - ANALYZE_WITH
            if 0 <= k < len(self.media) and m - ANALYZE_WITH < len(analyzer_names()) and not running:  # (the one already running: it carries on)
                self.start_analysis(k, m - ANALYZE_WITH)
            self.version += 1
        elif m == ANALYZE_CLOSE:
            self.analyze_card = -1
            self.version += 1
        elif m == ANALYZE_LOG:  # (the log this video is in step with, picked in the Analyze popover)
            if 0 <= self.analyze_card < len(self.media) and 0 <= event.number < len(self.tracks):
                var path = self.media.cards[self.analyze_card].path
                for j in range(len(self.tracks)):
                    if self.tracks.cards[j].video == path:
                        self.tracks.cards[j].video = ""
                self.tracks.cards[event.number].video = path
                self.tracks.cards[event.number].note = "In step with " + file_name(path)
            self.version += 1
        elif m == COMPARE_OPEN:
            var pl = self.place_tables()
            self.compare_open = True
            self.compare_a = 0
            self.compare_b = max(len(pl) - 1, 0)
            self.version += 1
        elif m == COMPARE_A:
            self.compare_a = max(event.number, 0)
            self.version += 1
        elif m == COMPARE_B:
            self.compare_b = max(event.number, 0)
            self.version += 1
        elif m == COMPARE_GO:
            self.run_compare()
        elif m == COMPARE_CLOSE:
            self.compare_open = False
            self.version += 1
        elif m == REEL_FLAG:
            self.reel_flag = max(event.number, 0)
            self.version += 1
        elif m == REEL_BLUR:
            self.reel_blur = event.number == 1
            self.version += 1
        elif m == REEL_CAPTION:
            self.reel_caption = max(event.number, 0)
            self.version += 1
        elif m == REEL_GO:
            self.start_reel()
        elif m == REEL_CLOSE:
            self.reel_card = -1
            self.version += 1
        elif m == QUERY_OPEN:
            self.query_open = not self.query_open
            if self.query_open and self.query_text == "":  # (a start: the tables it can read, by name)
                self.query_text = "SELECT * FROM " + sql_name(self.name) + " LIMIT 100"
            self.query_said = ""
            self.version += 1
        elif m == QUERY_TEXT:
            self.query_text = event.text
        elif m == ASK_TEXT:
            self.query_ask = event.text
        elif m == QUERY_NAME:
            self.query_name = event.text
        elif m == QUERY_RUN:
            self.run_query()
        elif m == QUERY_BAR:
            self.query_text = event.text
        elif m == QUERY_BAR_RUN:
            if event.text != "":
                self.query_text = event.text
            self.run_query()
        elif m == QUERY_CLOSE:
            self.query_open = False
            self.version += 1
        elif m == EXPORT_CSV:  # (written by a job: mojoui.tablejobs; the message comes when it lands)
            var path = self.documents() + "/" + sql_name(self.name) + ".csv"
            if self.work.export(self.frame, path):
                self.say(Activity.running("Exporting " + file_name(path), 0.0, grouped(self.frame.rows()) + " rows"))
            else:
                self.message = self.work.problem
                self.work.problem = ""
            self.version += 1
        elif m == INSERT_CLOSE:
            self.inserting = 0
            self.version += 1
        elif m == MOVE or m == RESIZE:  # a sheet object (child 0: the table) dragged by its title bar, or by its corner
            var k = event.number - 1
            if k == -1:
                if m == MOVE:
                    self.table_x = max(0, self.table_x + Int(event.dx))
                    self.table_y = max(0, self.table_y + Int(event.dy))
                else:
                    self.table_w = max(360, (self.table_w if self.table_w > 0 else self.sheet_width()) + Int(event.dx))
                    self.table_h_set = max(200, self.table_h() + Int(event.dy))
            elif 0 <= k < len(self.objects):
                if m == MOVE:
                    self.objects[k].x = max(0, self.objects[k].x + Int(event.dx))
                    self.objects[k].y = max(0, self.objects[k].y + Int(event.dy))
                else:
                    self.objects[k].w = max(320, self.objects[k].w + Int(event.dx))
                    self.objects[k].h = max(220, self.objects[k].h + Int(event.dy))
            elif 0 <= k - len(self.objects) < len(self.media):  # (a video or picture card, after the objects)
                ref c = self.media.cards[k - len(self.objects)]
                if m == MOVE:
                    c.x = max(0, c.x + Int(event.dx))
                    c.y = max(0, c.y + Int(event.dy))
                else:
                    c.w = max(280, c.w + Int(event.dx))
                    c.h = max(200, c.h + Int(event.dy))
            elif 0 <= k - len(self.objects) - len(self.media) < len(self.tables):  # (a table card, after the media)
                ref t = self.tables.cards[k - len(self.objects) - len(self.media)]
                if m == MOVE:
                    t.x = max(0, t.x + Int(event.dx))
                    t.y = max(0, t.y + Int(event.dy))
                else:
                    t.w = max(320, t.w + Int(event.dx))
                    t.h = max(180, t.h + Int(event.dy))
            elif 0 <= k - len(self.objects) - len(self.media) - len(self.tables) < len(self.tracks):  # (a log card, after the tables)
                ref r = self.tracks.cards[k - len(self.objects) - len(self.media) - len(self.tables)]
                if m == MOVE:
                    r.x = max(0, r.x + Int(event.dx))
                    r.y = max(0, r.y + Int(event.dy))
                else:
                    r.w = max(360, r.w + Int(event.dx))
                    r.h = max(200, r.h + Int(event.dy))
            elif 0 <= k - len(self.objects) - len(self.media) - len(self.tables) - len(self.tracks) < len(self.docs):  # (a folder of documents, after the logs)
                ref d = self.docs[k - len(self.objects) - len(self.media) - len(self.tables) - len(self.tracks)].card
                if m == MOVE:
                    d.x = max(0, d.x + Int(event.dx))
                    d.y = max(0, d.y + Int(event.dy))
                else:
                    d.w = max(360, d.w + Int(event.dx))
                    d.h = max(300, d.h + Int(event.dy))
                d.version += 1
            self.version += 1
        elif m >= OBJ_TAP and m < OBJ_TAP + 100:
            var k = m - OBJ_TAP
            if k < len(self.objects) and event.number == TAP:
                var cv = chart_view(self.objects[k], self.frame)
                cv.size = self.chart_sizes[10 + k]
                if cv.tap(event.x, event.y, self.font, self.pal):
                    self.objects[k].selected = cv.selected
                    self.active = k
                    self.version += 1
            if k < len(self.objects) and event.number == TAP and self.objects[k].kind == OBJ_CHART:
                self.ask_here(k)
                self.version += 1
        elif m >= OBJ_CLOSE and m < OBJ_CLOSE + 100:
            var k = m - OBJ_CLOSE
            if k < len(self.objects):
                _ = self.objects.pop(k)
                self.charts.remove(k, self.frame)  # (its job goes; the ones after it move down a ref and carry on)
                var held = List[Tuple[Int, SheetObject]]()
                for h in self.held:
                    if h[0] != k:
                        held.append((h[0] - 1 if h[0] > k else h[0], h[1].copy()))
                self.held = held^
                self.chart_undo = List[Tuple[Int, Int, SheetObject]]()  # (refs after it moved: its changes can't be undone any more)
                self.asking = -1
                if self.active == k:
                    self.active = -1  # (the one shown was removed: show none)
                elif self.active > k:
                    self.active -= 1  # (the same object, one place earlier)
                if self.active < 0 and self.insp_tab == 2:
                    self.insp_tab = 1
                self.version += 1
        elif m >= OBJ_PICK and m < OBJ_PICK + 100:
            if m - OBJ_PICK < len(self.objects):
                self.active = m - OBJ_PICK
                self.insp_tab = 2
                if self.objects[self.active].kind == OBJ_CHART:
                    self.ask_here(self.active)
                self.inspector_open = True
                self.version += 1
        elif m == CHART_STYLE or m == OBJ_VALUE or m == OBJ_GROUP or m == OBJ_ACROSS:
            if 0 <= self.active < len(self.objects):
                ref o = self.objects[self.active]
                var nums = self.numbers()
                var texts = self.texts()
                if m == CHART_STYLE:
                    o.style = CHART_LINE if event.number == 1 else CHART_BAR
                elif m == OBJ_VALUE and 0 <= event.number < len(nums):
                    o.value = nums[event.number]
                elif m == OBJ_GROUP and o.kind == OBJ_CHART:
                    _ = apply_choice(o, self.frame, SLOT_GROUP, event.number)
                elif m == OBJ_GROUP and 0 <= event.number < len(texts):
                    o.group = texts[event.number]
                    o.part = PART_NONE  # (a text column's values, not a date's months)
                elif m == OBJ_ACROSS and 0 <= event.number <= len(texts):
                    o.across = texts[event.number - 1] if event.number > 0 else -1
                o.selected = -1
                try:
                    compute(o, self.frame)
                    self.message = object_title(o, self.frame)
                except e:
                    self.message = "Couldn't compute: " + String(e)
                self.version += 1
        elif m == REPORT_COL:  # (every column: Distinct counts text too; the number tiles say so on a text column)
            if 0 <= event.number < self.frame.columns():
                self.report_col = event.number
            self.version += 1
        elif m >= ADD_TILE and m <= ADD_TILE + TILE_LAST:
            var texts = self.groupings()
            var col = self.report_col
            var t = new_tile(m - ADD_TILE, col, texts[0] if len(texts) > 0 else -1)
            var number = col >= 0 and (self.frame.kind(col) == INT or self.frame.kind(col) == DECIMAL)
            if col < 0:
                self.message = "A tile needs a column: pick one in Tiles of"
            elif not number and t.kind != TILE_DISTINCT and t.kind != TILE_COUNT:
                self.message = materialize[TILE_NAMES]()[t.kind] + " needs a number column: " + self.frame.name(col) + " isn't one (Distinct counts any column)"
            elif len(self.tiles) >= MAX_OBJECTS:
                self.message = "A report holds up to " + String(MAX_OBJECTS) + " tiles: remove one first"
            elif t.kind == TILE_CHART and len(texts) == 0:
                self.message = "A chart tile needs a text column to group by"
            else:
                try:
                    compute_tile(t, self.frame, self.filter)
                except e:
                    self.message = "Couldn't compute: " + String(e)
                var chart_tile = t.kind == TILE_CHART
                self.tiles.append(t^)
                if chart_tile:
                    self.ask_here(TILE_REF + len(self.tiles) - 1)
                    self.inspector_open = True
            self.version += 1
        elif m >= TILE_CLOSE and m < TILE_CLOSE + 100:
            if m - TILE_CLOSE < len(self.tiles):
                _ = self.tiles.pop(m - TILE_CLOSE)
                self.chart_undo = List[Tuple[Int, Int, SheetObject]]()
                self.asking = -1
                self.version += 1
        elif m >= TILE_TAP and m < TILE_TAP + 100:
            var k = m - TILE_TAP
            if k < len(self.tiles) and event.number == TAP:
                var cv = chart_view(self.tiles[k].chart, self.frame)
                cv.size = self.chart_sizes[60 + k]
                if cv.tap(event.x, event.y, self.font, self.pal):
                    self.tiles[k].chart.selected = cv.selected
                    self.version += 1
            if k < len(self.tiles) and event.number == TAP and self.tiles[k].kind == TILE_CHART:
                self.ask_here(TILE_REF + k)
                self.version += 1
        elif m >= WORD and m < WORD + (TILE_REF + MAX_OBJECTS) * 10:  # a chart's word: its choices open on it
            var cref = (m - WORD) // 10
            if self.has_chart(cref):
                self.word_ref = cref
                self.word_slot = (m - WORD) % 10
                self.ask_here(cref)
                if cref < TILE_REF:
                    self.active = cref  # (the inspector follows the chart being edited)
                    self.insp_tab = 2
            self.version += 1
        elif m >= CHOICE and m < CHOICE + 100:
            if self.word_ref >= 0 and self.has_chart(self.word_ref):
                var c = self.chart_of(self.word_ref)
                var was = chart_sentence(c, self.frame)
                if apply_choice(c, self.frame, self.word_slot, m - CHOICE) and chart_sentence(c, self.frame) != was:  # (re-picking the current choice: no Undo step)
                    self.set_chart(self.word_ref, c^)
            self.word_ref = -1
            self.version += 1
        elif m == WORD_CLOSE:
            self.word_ref = -1
            self.version += 1
        elif m >= PAGE and m <= PAGE + 4:
            self.insp_page = m - PAGE
            self.version += 1
        elif m >= INSP_SET and m < INSP_SET + 7:  # (the inspector's controls: the same choices as the sentence's words)
            if self.asking >= 0 and self.has_chart(self.asking):
                var c = self.chart_of(self.asking)
                var was = chart_sentence(c, self.frame)
                if apply_choice(c, self.frame, m - INSP_SET, event.number) and chart_sentence(c, self.frame) != was:
                    self.set_chart(self.asking, c^)
            self.version += 1
        elif m == NUM_PICK or m == NUM_LO or m == NUM_HI:  # the Rows page's number condition
            if self.asking >= 0 and self.has_chart(self.asking):
                var c = self.chart_of(self.asking)
                var ncol = c.num_col if c.num_col >= 0 else c.value
                var was = chart_sentence(c, self.frame)
                if m == NUM_PICK:
                    if 0 <= event.number <= NUM_AT_MOST:
                        if c.num_col != ncol:  # (bounds are in their column's units: a new column starts from zero)
                            c.num_lo = 0
                            c.num_hi = 0
                        c.num_op = event.number
                        c.num_col = ncol if event.number != NUM_ANY else -1
                else:
                    try:
                        var v = Int(parse_decimal(event.text, self.frame.scale(ncol) if self.frame.kind(ncol) == DECIMAL else 0))
                        if m == NUM_LO:
                            c.num_lo = v
                        else:
                            c.num_hi = v
                        if c.num_op == NUM_BETWEEN and c.num_lo > c.num_hi:  # (typed the wrong way round: between still means between)
                            var lo = c.num_hi
                            c.num_hi = c.num_lo
                            c.num_lo = lo
                        c.num_col = ncol
                    except:
                        self.message = "Not a number: " + event.text
                if chart_sentence(c, self.frame) != was:
                    self.set_chart(self.asking, c^)
            self.version += 1
        elif m == ASK_CHANGE:  # (typing changes nothing else on screen: no rebuild under the field, so Return is never lost)
            self.ask_text = event.text
        elif m == ASK_SUBMIT:
            if self.asking >= 0 and self.has_chart(self.asking) and event.text != "":
                var c = self.chart_of(self.asking)
                var said = ask(c, self.frame, event.text)
                if len(said.changed) > 0:  # (an ask that leaves the chart as it was logs no Undo step and moves nothing)
                    self.set_chart(self.asking, c^)
                    self.lit = said.changed.copy()
                self.message = ask_reply(said)  # (what it took: in the status bar, once; the sentence marks the words)
                self.ask_said = self.message if len(said.skipped) > 0 or len(said.understood) == 0 else String("")  # (under the field only what it couldn't use)
                self.ask_text = ""
            self.version += 1
        elif m == FILTER_COL:
            var texts = self.texts()
            if 0 <= event.number <= len(texts):
                self.filter = ReportFilter(texts[event.number - 1] if event.number > 0 else -1, 0)
                self.refresh()
        elif m == FILTER_VALUE:
            if self.filter.col >= 0 and 0 <= event.number < groups_of(self.frame, self.filter.col):
                self.filter.code = event.number
                self.refresh()
        elif m == STYLE_BOLD or m == STYLE_ITALIC or m == STYLE_UNDERLINE or m == STYLE_STRIKE:
            var part = BOLD if m == STYLE_BOLD else (ITALIC if m == STYLE_ITALIC else (UNDERLINE if m == STYLE_UNDERLINE else STRIKE))
            var at = self.style_target()
            if at[0] >= 0:
                var on = self.frame.style_of(at[0], at[1]).bits & part != 0
                self.restyle(part, 0 if on else part)
        elif m >= STYLE_ALIGN and m <= STYLE_ALIGN + ALIGN_RIGHT:
            self.restyle(ALIGN_MASK, align_bits(m - STYLE_ALIGN))
        elif m >= SET_INK and m <= SET_INK + 8:
            self.picking = 0
            self.restyle(INK_MASK, ink_bits(m - SET_INK))
        elif m >= SET_FILL and m <= SET_FILL + 8:
            self.picking = 0
            self.restyle(FILL_MASK, fill_bits(m - SET_FILL))
        elif m == PICK_INK or m == PICK_FILL:
            self.picking = 0 if self.picking == m else m
            self.version += 1
        elif m == PICK_CLOSE:
            self.picking = 0
            self.version += 1
        elif m == SWATCH:
            var k = swatch_at(event.x, event.y)
            if event.number == TAP and k >= 0 and self.picking != 0:
                var fill = self.picking == PICK_FILL
                self.picking = 0
                self.restyle(FILL_MASK if fill else INK_MASK, fill_bits(k) if fill else ink_bits(k))
        elif m == CLEAR_FORMAT:
            var at = self.style_target()
            if at[0] >= 0:
                self.frame.clear_style(at[0], at[1])
                self.after_style(at[0], at[1])
        elif m == TAB or m == TAB + 1:
            if self.sheet_tab == m - TAB and self.renaming < 0:  # the current tab again: rename it
                self.renaming = m - TAB
            else:
                self.sheet_tab = m - TAB
                self.renaming = -1
                self.picking = 0
            self.version += 1
        elif m == RENAME_TAB:
            self.renaming = self.sheet_tab
            self.version += 1
        elif m == RENAME_SUBMIT:
            var name = String(event.text.strip())
            if name == "":
                self.message = "A tab needs a name: type one, or press Escape to keep " + (self.sheet_name if self.renaming == 0 else self.report_name)
            elif name.byte_length() > 64:
                self.message = "That name is too long: 64 letters at most"
            else:
                var was = self.sheet_name if self.renaming == 0 else self.report_name
                if self.renaming == 0:
                    self.sheet_name = name
                elif self.renaming == 1:
                    self.report_name = name
                self.message = "Renamed " + was + " to " + name
                self.renaming = -1
            self.version += 1
        elif m == RENAME_CANCEL:
            self.renaming = -1
            self.message = "Kept the name"
            self.version += 1
        elif m == UNDO and len(self.chart_undo) > 0 and self.chart_undo[len(self.chart_undo) - 1][0] >= self.frame.undo_depth():
            var last = self.chart_undo.pop()  # (a chart change came after the table's last change: it goes first)
            if self.has_chart(last[1]):
                self.set_chart(last[1], last[2].copy(), logged=False)
                self.message = "Undid a chart change: " + chart_sentence(self.chart_of(last[1]), self.frame)
            self.lit = List[Int]()
            self.version += 1
        elif m == UNDO and self.uses(self.frame.undo_drops()) != "":
            var gone = self.frame.undo_drops()
            self.message = "Can't undo the formula column " + self.frame.name(gone) + " yet: " + self.uses(gone) + " reads it. Remove that first"
            self.version += 1
        elif m == UNDO:
            var gone = self.frame.undo_drops()
            if gone >= 0:  # (what only looks at the column lets go of it: a sort, the Report's tile column)
                if self.grid.sort_col == gone:
                    self.grid.clear_order()
                if self.report_col == gone:
                    self.report_col = self.first_number()
            if self.frame.undo():
                self.grid.min_widths = List[Float64]()  # (a formula column may have gone)
                self.grid.prepare(self.frame, self.font, self.pal)
                if self.grid.cur_col >= self.frame.columns():
                    self.grid.select(self.grid.cur_row, self.frame.columns() - 1)
                if self.grid.cur_row >= self.frame.rows():  # (an added row taken back: the selection stays in the table, or reading it asserts)
                    self.grid.select(self.frame.rows() - 1, max(self.grid.cur_col, 0))
                self.grid.redraw()
                self.select_cell(self.grid.cur_row, self.grid.cur_col)
                self.refresh()
                self.message = "Undid " + self.frame.last_undone + " (" + self.sheet_name + ")"
            else:
                self.message = "Nothing to undo"
            self.version += 1

    # ---------- drawing ----------

    def jobs_message(self) -> Int:
        return JOBS_WAKE

    def describe(self, canvas: Int, first: Int, count: Int) -> String:
        """A chart's numbers, or the grid's shown rows, as tab-separated text for an agent (D-163). The grid: the header, then `count` rows from
        shown row `first` (count 0: what fits on screen, or 25 before the grid has been drawn)."""
        if self.screen != SHEET:
            return ""
        if self.editor and self.editor.value().draws(canvas):
            return self.editor.value().describe()
        if self.media.draws(canvas):
            return self.media.describe(canvas)  # (a video: its time and how to seek; a picture: what it is)
        if self.tracks.draws(canvas):
            for k in range(len(self.tracks)):
                if self.tracks.canvas(k) <= canvas < self.tracks.canvas(k) + 2:
                    return self.tracks.describe(canvas, self.track_time(k))
        if self.tables.draws(canvas):
            return self.tables.describe(canvas, first, count)  # (a table card: its rows)
        if DOCS_CANVAS <= canvas < DOCS_CANVAS + len(self.docs):
            return self.docs[canvas - DOCS_CANVAS].describe()  # (a folder: the document shown, what's marked)
        if 10 <= canvas < 10 + len(self.objects) and self.objects[canvas - 10].kind == OBJ_CHART:
            return chart_text(self.objects[canvas - 10], self.frame)  # (a chart: its bars' numbers)
        if canvas != 0:
            return ""
        var cols = self.frame.grid_columns()
        var out = String()
        for c in range(cols):
            out += ("\t" if c > 0 else "") + self.frame.grid_name(c)
        var n = count if count > 0 else (self.grid.rows_in(self.grid.size[1]) if self.grid.size[1] > 0 else 25)
        var i = self.grid.top + first
        var got = 0
        while got < n:
            var r = self.grid.shown_row(i, self.frame)
            if r < 0:
                break
            i += 1
            if not self.frame.grid_alive(r):
                continue
            out += "\n"
            for c in range(cols):
                out += ("\t" if c > 0 else "") + self.frame.grid_text(c, r)
            got += 1
        return out

    def spot(self, canvas: Int, name: String) -> Tuple[Float64, Float64]:
        """Where a grid's column header is drawn (App.spot): a table card's, or the sheet's own table's."""
        if self.tables.draws(canvas):
            return self.tables.spot(canvas, name)
        if canvas == 0 and self.has_table:
            return self.grid.header_spot(name, self.frame)
        return (-1.0, -1.0)

    def draw_scene(mut self, canvas: Int, mut scene: Scene) -> Bool:
        """The grid as a display list (goal 26; hosts that can draw one: GTK with MOJOUI_SCENE=1)."""
        if canvas != 0:
            return False
        self.pal = skin_palette(self.skin, self.accent(), self.dark())
        self.grid.draw_scene(scene, self.frame, self.font, self.pal)
        return True

    def chart_palette(self) -> Palette:
        """Charts draw in the skin's first series colour, not the mode's tint: the report's red would read as a loss (D-254)."""
        var base = skin_palette(self.skin, 0, self.dark())
        return self.pal.with_accent(base.data(0))

    def draw(mut self, canvas: Int, mut surface: Surface):
        self.pal = skin_palette(self.skin, self.accent(), self.dark())  # (the mode's tint, as the chrome has it)
        if 0 <= canvas < len(self.chart_sizes):
            self.chart_sizes[canvas] = (surface.points_width(), surface.points_height())
        if self.editor and self.editor.value().draws(canvas):
            self.editor.value().draw(canvas, surface, self.pal, self.font)
            return
        if self.tracks.draws(canvas):
            for k in range(len(self.tracks)):
                if self.tracks.canvas(k) <= canvas < self.tracks.canvas(k) + 2:
                    self.tracks.draw(canvas, surface, self.font, self.pal, self.track_time(k))
            return
        if canvas == PEEK_CANVAS:
            self.peek.draw(surface, self.pal)
            return
        if canvas == 0:
            self.grid.draw(surface, self.frame, self.font, self.pal)
        elif canvas == 1:
            self.preview.draw(surface, self.frame, self.font, self.pal)
        elif canvas == ISLAND_CANVAS:
            self.island.still = self.island.still or surface.still
            self.island.draw(surface, self.font, self.pal, now_ns())
        elif canvas == SWATCH_CANVAS:
            var col = self.grid.cur_col
            var st = self.frame.style_of(col, self.grid.cur_row) if col >= 0 else CellStyle()
            draw_swatches(surface, st.fill() if self.picking == PICK_FILL else st.ink(), self.picking == PICK_FILL, self.font, self.pal)
        elif 10 <= canvas < 10 + len(self.objects):
            var shown = self.held_of(canvas - 10)
            var cv = chart_view(shown.value().copy() if shown else self.objects[canvas - 10].copy(), self.frame)
            cv.draw(surface, self.font, self.chart_palette())
            if shown:  # (its numbers are coming: the old picture, faded, until they land)
                draw_rect(surface, 0, 0, Float64(surface.width), Float64(surface.height), with_alpha(self.pal.card, 0.55))
            if self.objects[canvas - 10].moved < MOVE_FRAMES:  # (mid-move: the next frame draws it further along)
                self.objects[canvas - 10].moved += 1
                surface.again = True
        elif self.media.draws(canvas):
            self.media.draw(canvas, surface, self.pal)
        elif DOCS_CANVAS <= canvas < DOCS_CANVAS + len(self.docs):
            self.docs[canvas - DOCS_CANVAS].card.draw(surface, self.pal)
            if self.docs[canvas - DOCS_CANVAS].card.wants()[0] >= 0:  # (the size it's drawn at asks for a sharper page: a job)
                self.doc_feeds[canvas - DOCS_CANVAS].poll(self.docs[canvas - DOCS_CANVAS])
        elif self.tables.draws(canvas):
            self.tables.draw(canvas, surface, self.font, self.pal)
        elif 60 <= canvas < 60 + len(self.tiles):
            var cv = chart_view(self.tiles[canvas - 60].chart, self.frame)
            cv.draw(surface, self.font, self.chart_palette())
            if self.tiles[canvas - 60].chart.moved < MOVE_FRAMES:
                self.tiles[canvas - 60].chart.moved += 1
                surface.again = True
        else:
            surface.fill(self.pal.card)  # (a KPI tile's sparkline: none yet)

    # ---------- screens ----------

    def view(self) -> View:
        if self.screen == IMPORT:
            return self.import_screen()
        if self.screen == SHEET and self.editor:
            return self.editor.value().view(self.pal).padding(16, 20)
        if self.screen == SHEET:
            return self.sheet_screen()
        return self.start_screen()

    def gpu_chip(self) -> String:
        if self.frame.device:
            return "● " + self.frame.device_name + " · ready"
        return "● CPU"

    def start_screen(self) -> View:
        """The Start screen (docs/design/universal/kit.html, 7): a side column of actions, a drop zone, recent files, samples."""
        var side = List[View]()
        side.append(Button("Start", NO_MSG, SUBTLE, icon="file").fill().align(START))  # (rows read from their leading edge, one icon set)
        side.append(Button("New blank sheet", BLANK, SUBTLE, icon="grid").fill().align(START))
        side.append(FilePicker("Open file…", PICK, style=SUBTLE, icon="open", accept=OPEN_TYPES).fill().align(START))
        side.append(FilePicker("Table", PICK_TABLE, style=SUBTLE, icon="table", accept=".csv,.tsv,.txt,.parquet").fill().align(START).tooltip("A CSV or Parquet file as a table card on a new sheet (read in the background)").tag("insert-table"))
        side.append(HStack(Icon("database", 16), Text("Connect a database", CAPTION), Spacer(), Text("soon", CAPTION).tone(TONE_ACCENT), spacing=10).fill().align(CENTER).padding(6, 12).tag("soon").tooltip("With MX frame, next"))
        side.append(Divider().fill())
        side.append(Button("Settings…", SETTINGS, SUBTLE, icon="settings").fill().align(START))
        side.append(Spacer())
        side.append(Card(Text(self.gpu_chip(), CAPTION).tone(TONE_GOOD), Text("Parquet files bigger than memory open too: streamed from disk, and you can still edit and save them.", CAPTION), spacing=4, tone=CARD_GOOD).fill())
        var sidebar = Card(VStack(side^, spacing=6).fill().grow().align(START), spacing=0).width(300).fill()
        var drop = Card(
            HStack(Icon("upload", 28),
                   VStack(Text("Drop a CSV, Parquet or .omx file here", HEADLINE),
                          Text("or choose a file. A million rows is fine: you see a preview first, and the rest loads while you work.", CAPTION), spacing=4).align(START),
                   Spacer(), FilePicker("Choose a file", PICK, style=PROMINENT, icon="import", accept=OPEN_TYPES), spacing=16).fill().align(CENTER),
            spacing=0,
        ).fill()
        var recent = List[View]()
        if len(self.recent) == 0:
            recent.append(HStack(Text("Files you open show up here.", CAPTION), Spacer()).fill())
        for k in range(min(len(self.recent), 6)):
            recent.append(HStack(Icon("file", 16), Text(file_name(self.recent[k])), Text(self.recent[k], CAPTION), Spacer(),
                                 Button("Open", RECENT + k, SUBTLE), spacing=12).fill().align(CENTER))
        var samples = HStack(
            Card(Text("Orders", HEADLINE), Text("1M rows · a year of sales by region, product and carrier", CAPTION), Spacer(),
                 Button("Open the sample", SAMPLE, icon="sample"), spacing=8).width(330).height(150),
            Card(Text("Blank sheet", HEADLINE), Text("An empty table to type into", CAPTION), Spacer(),
                 Button("New blank sheet", BLANK, icon="grid"), spacing=8).width(330).height(150),
            Card(Text("Taxi trips", HEADLINE), Text("100M rows · a GPU workout (docs/scale.md)", CAPTION), Spacer(), Text("Coming with MX frame", CAPTION), spacing=8).width(330).height(150),
            spacing=16,
        )
        var main = VStack(
            Text("Open a file", HEADLINE),
            drop,
            Text("Recent", HEADLINE),
            Card(VStack(recent^, spacing=8).fill(), spacing=8).fill(),
            Text("Try a sample", HEADLINE),
            samples,
            Text(self.message, CAPTION).tone(TONE_WARN) if self.message != "" else Spacer(),
            spacing=16,
        ).grow().align(START)
        var body = HStack(sidebar, main, spacing=24).padding(24, 32).fill().grow().align(STRETCH)
        var parts = List[View]()
        parts.append(self.menu_bar())
        parts.append(body^)
        parts.append(StatusBar(["Ready"], "omxplorer · omxcode"))
        for o in self.overlays():
            parts.append(o.copy())
        return VStack(parts^, spacing=0).fill().grow()

    def import_screen(self) -> View:
        """Import, step 2 (docs/design/liquid.md): a centred sheet: the file's facts and the steps, a preview of the first
        rows, then one left-aligned row per column (name, type, empty, distinct, first values), then Back and Create table."""
        var rows = List[View]()
        rows.append(self.import_row(Text("COLUMN", CAPTION), Text("TYPE", CAPTION), Text("EMPTY", CAPTION), Text("DISTINCT", CAPTION), Text("FIRST VALUES", CAPTION)))
        for k in range(len(self.imp.columns)):
            ref c = self.imp.columns[k]
            var first = String("")
            for s in range(min(3, len(c.sample))):
                first += ("  ·  " if s > 0 else "") + c.sample[s]
            rows.append(self.import_row(Text(c.name).tone(TONE_STRONG), Text(kind_name(c.kind)).tone(TONE_ACCENT),
                                        Text(grouped(c.empty) if c.empty >= 0 else "—").tone(TONE_WARN if c.empty > 0 else 0),
                                        Text(grouped(c.distinct) if c.kind == TEXT else "—"), Text(first, CAPTION)))
        var note = String("Empty cells stay empty; a column's type can change later from its menu.")
        if len(self.imp.skipped) > 0:
            note = String(len(self.imp.skipped)) + " more columns aren't read (4,096 is the limit)"
        if self.imp.streamed():
            note = "Too big for memory: streamed from disk, a row group at a time. You can edit, chart and save it as usual; its empty cells aren't counted up front."
        var dialog = Card(
            HStack(VStack(Text("Import " + file_name(self.imp.path), HEADLINE),
                          Text(grouped(self.imp.rows) + " rows · " + String(len(self.imp.columns)) + " columns · "
                               + ("streamed, opened in " if self.imp.streamed() else "read in ") + fixed(self.imp.seconds, 2) + " s", CAPTION).tone(TONE_GOOD), spacing=2).align(START),
                   Spacer(), Text("✓ File   ›   2  Columns   ›   3  Table", CAPTION), spacing=12).fill().align(CENTER),
            Canvas(1, self.version + self.preview.version, on_gesture=PREVIEW).fill().height(300).tag("import-preview"),
            Text("Columns", HEADLINE),
            Scroll(VStack(rows^, spacing=0).fill(), height=250).fill().tag("import-columns"),
            Spacer(),
            HStack(Button("Back", BACK), Text(note, CAPTION).tone(TONE_WARN if self.imp.streamed() or len(self.imp.skipped) > 0 else 0), Spacer(),
                   Button("Create table", CREATE, style=PROMINENT, icon="table"), spacing=14).fill().align(CENTER),
            spacing=14,
        ).width(1120).fill().grow().tag("import")
        return VStack(dialog, spacing=0).padding(28, 40).fill().grow().align(CENTER)

    def import_row(self, name: View, kind: View, empty: View, distinct: View, first: View) -> View:
        """One row of the import's column table: fixed columns, left-aligned, a hairline under it."""
        return VStack(HStack(name.copy().width(180), kind.copy().width(140), empty.copy().width(110), distinct.copy().width(110), first.copy(), Spacer(), spacing=12)
                      .fill().align(CENTER).height(34), Divider().fill(), spacing=0).fill()

    def menu_bar(self) -> View:
        """The menus every screen carries (on a Mac, the system menu bar): the same actions as the toolbar, with shortcuts."""
        var on_sheet = self.screen == SHEET
        var edits = on_sheet  # (a streamed file edits too, D-213)
        var col = self.ctx_col if self.ctx_col >= 0 else self.grid.cur_col
        var style = self.frame.format_of(col).style if on_sheet and col >= 0 else AUTO
        var format_as = Submenu("Format as", [Item("Number", FMT_NUMBER, checked=style == NUMBER, disabled=not on_sheet),
                                               Item("Currency", FMT_CURRENCY, checked=style == CURRENCY, disabled=not on_sheet),
                                               Item("Percent", FMT_PERCENT, checked=style == PERCENT, disabled=not on_sheet)], icon="format")
        var cells = on_sheet and self.sheet_tab == 0  # (formats apply to the sheet's cells; the Report has none)
        var st = self.frame.style_of(self.grid.cur_col, self.grid.cur_row) if cells and self.grid.cur_col >= 0 else CellStyle()
        var inks = List[View]()
        var fills = List[View]()
        for k in range(9):
            inks.append(Item(swatch_name(k), SET_INK + k, checked=st.ink() == k, disabled=not cells))
            fills.append(Item("None" if k == 0 else swatch_name(k), SET_FILL + k, checked=st.fill() == k, disabled=not cells))
        var bar = MenuBar([
            Menu("File", [Item("New blank sheet", BLANK, icon="grid", shortcut="Ctrl+N"), Item("Open…", BACK, icon="open", shortcut="Ctrl+O", disabled=not on_sheet),
                          Separator(), Item("Save", SAVE, icon="save", shortcut="Ctrl+S", disabled=not edits),
                          Item("Export CSV", EXPORT_CSV, icon="download", disabled=not on_sheet), Separator(),
                          Item("Settings…", SETTINGS, icon="gear", shortcut="Ctrl+,")]),
            Menu("Edit", [Item("Undo", UNDO, icon="undo", shortcut="Ctrl+Z", disabled=not on_sheet), Separator(),
                          Item("Copy", COPY, icon="copy", shortcut="Ctrl+C", disabled=not on_sheet or self.sheet_tab != 0), Separator(),  # (a streamed file's formats can be undone)
                          Item("Add row", ADD_ROW, icon="row-plus", shortcut="Ctrl+Shift+R", disabled=not edits)]),
            Menu("View", [Item("Inspector", TOGGLE_INSPECTOR, checked=self.inspector_open, shortcut="Ctrl+Shift+I", disabled=not on_sheet), Separator(),
                          Item("Sheet", SHOW_SHEET, icon="sheet", checked=on_sheet and self.sheet_tab == 0, disabled=not on_sheet),
                          Item("Report", SHOW_REPORT, icon="chart-bar", checked=on_sheet and self.sheet_tab == 1, disabled=not on_sheet), Separator(),
                          Item("Rename tab…", RENAME_TAB, icon="rename", disabled=not on_sheet)]),
            Menu("Insert", [Item("Chart", INSERT_CHART, icon="chart-bar", shortcut="Ctrl+Shift+C", disabled=not on_sheet),
                            Item("Pivot table", INSERT_PIVOT, icon="pivot", shortcut="Ctrl+Shift+P", disabled=not on_sheet),
                            Item("Video…", INSERT_VIDEO, icon="video", disabled=not on_sheet), Item("Image…", INSERT_IMAGE, icon="image", disabled=not on_sheet),
                            Item("Table…", INSERT_TABLE, icon="table", disabled=not on_sheet), Item("SQL query…", QUERY_OPEN, icon="database", disabled=not on_sheet),
                            Item("Compare inspections…", COMPARE_OPEN, icon="chart", disabled=not on_sheet or len(self.place_tables()) < 2), Separator(),
                            Item("Formula column", NEW_FORMULA, icon="formula", checked=self.formula_open, disabled=not edits),
                            Item("Row", ADD_ROW, icon="row-plus", disabled=not edits)]),
            Menu("Data", [Item("Sort smallest first", SORT_ASC, icon="sort", shortcut="Ctrl+Shift+↑", disabled=not edits),
                          Item("Sort largest first", SORT_DESC, shortcut="Ctrl+Shift+↓", disabled=not edits), Separator(), format_as.copy()]),
            Menu("Format", [Item("Bold", STYLE_BOLD, icon="bold", shortcut="Ctrl+B", checked=st.bold(), disabled=not cells),
                            Item("Italic", STYLE_ITALIC, icon="italic", shortcut="Ctrl+I", checked=st.italic(), disabled=not cells),
                            Item("Underline", STYLE_UNDERLINE, icon="underline", shortcut="Ctrl+U", checked=st.underline(), disabled=not cells),
                            Item("Strikethrough", STYLE_STRIKE, icon="strikethrough", shortcut="Ctrl+5", checked=st.strike(), disabled=not cells), Separator(),
                            Submenu("Text colour", inks^, icon="text-colour"), Submenu("Fill colour", fills^, icon="fill"),
                            Submenu("Align", [Item("Automatic", STYLE_ALIGN + AUTO_ALIGN, checked=st.align() == AUTO_ALIGN, disabled=not cells),
                                              Item("Left", STYLE_ALIGN + ALIGN_LEFT, checked=st.align() == ALIGN_LEFT, disabled=not cells),
                                              Item("Centre", STYLE_ALIGN + ALIGN_CENTRE, checked=st.align() == ALIGN_CENTRE, disabled=not cells),
                                              Item("Right", STYLE_ALIGN + ALIGN_RIGHT, checked=st.align() == ALIGN_RIGHT, disabled=not cells)], icon="align-left"),
                            Separator(), format_as.copy(), Item("Clear formatting", CLEAR_FORMAT, icon="clear-format", disabled=not cells), Separator(),
                            Item("Format inspector", TOGGLE_INSPECTOR, icon="format", checked=self.inspector_open, disabled=not on_sheet)]),
            Menu("Help", [Item("About omxplorer", ABOUT, icon="file")]),
        ])
        var doc = (self.sheet_name + " · " + grouped(self.frame.rows()) + " rows") if on_sheet else String("")
        _ = doc
        var t = now_ns()
        var moving = self.island.wants_frames(t) or self.charts.busy() or Bool(self.col_job) or Bool(self.opening) or len(self.col_orphans) > 0 or Bool(self.video.analyzing) or Bool(self.video.reeling) or self.work.busy() or Bool(self.comparing) or Bool(self.packing) or Bool(self.doc_opening) or self.docs_busy()
        var says = self.island.now.lead + (" · " + self.island.now.text if self.island.now.text != "" else String(""))
        var island: List[View] = [IslandView(ISLAND_CANVAS, self.island_v, ISLAND_TAP, ISLAND_FRAME if moving else NO_MSG).tooltip(says)]  # (the document, the GPU and what's happening, in one place: D-255)
        return AppBar("omxplorer", bar^, island^)

    def video_overlays(self) -> List[View]:
        """The video card's Analyze popover, Make a reel dialog and the Query dialog (each only while open)."""
        var out = List[View]()
        if self.screen != SHEET:
            return out^
        if 0 <= self.analyze_card < len(self.media):
            var items = List[View]()
            var names = analyzer_names()
            for i in range(len(names)):
                items.append(VStack(Button(names[i], ANALYZE_WITH + i, SUBTLE, icon="zap" if i == 0 else ("route" if analyzer_needs_log(i) else "layout-grid")).fill().align(START),
                                    Text(analyzer_note(i), CAPTION).max_width(340), spacing=2).align(START))
            var vpath = self.media.cards[self.analyze_card].path
            if len(self.tracks) > 0:  # (the log that puts the rows on the map: the one in step with this video, or pick one)
                var logs = List[String]()
                var at = 0
                for j in range(len(self.tracks)):
                    logs.append(self.tracks.cards[j].name)
                    if self.tracks.cards[j].video == vpath:
                        at = j
                items.append(HStack(Text("Log", CAPTION).width(40), Dropdown(logs, at, ANALYZE_LOG).tag("analyze-log").label("Log"), spacing=8).align(CENTER))
            else:
                items.append(Text("Assets & defects needs the flight's log: Insert > Table… a CSV with t, lat and lon.", CAPTION).max_width(340))
            items.append(Text("Runs on your GPU, frame by frame, in the background. Classic vision (colour, motion, printed codes) for now: a model plugs into the same slot.", CAPTION).max_width(340))
            var n = self.video_number(self.analyze_card)
            out.append(Popover("analyze" + ("" if n == 0 else "-" + String(n + 1)), "Analyze", VStack(items^, spacing=10).align(START), on_close=ANALYZE_CLOSE))
        if 0 <= self.reel_card < len(self.media):
            ref c = self.media.cards[self.reel_card]
            var parts = List[View]()
            var flags = self.reel_flags()
            if self.video.found_path != c.path or len(flags) == 0:
                parts.append(Text("Analyze " + c.title() + " first: a reel keeps the frames where a column of its rows is true.", CAPTION))
                parts.append(HStack(Spacer(), Button("Cancel", REEL_CLOSE), spacing=10).fill())
            else:
                var at = self.found_sheet_index()
                var names = List[String]()
                for f in flags:
                    names.append(self.frame.name(f) if at == -1 else self.tables.cards[at].sheet.name(f))
                var labels = List[String]()
                for ch in self.reel_captions:
                    labels.append(ch[0])
                parts.append(Text("The frames where a column of " + (self.table_title if at == -1 else self.found_table) + " is true, cut into one video.", CAPTION))
                parts.append(HStack(Text("Keep frames where", CAPTION).width(150), Dropdown(names, min(self.reel_flag, len(names) - 1), REEL_FLAG).tag("reel-where").label("Keep frames where"), spacing=10).align(CENTER))
                parts.append(HStack(Text("Caption", CAPTION).width(150), Dropdown(labels, min(self.reel_caption, len(labels) - 1), REEL_CAPTION).tag("reel-caption").label("Caption"), spacing=10).align(CENTER))
                parts.append(Toggle("Blur faces", self.reel_blur, REEL_BLUR).tag("reel-blur-faces"))
                parts.append(HStack(Text("Saved as " + file_stem(c.path) + "-reel.mp4 in your documents", CAPTION), Spacer(), Button("Cancel", REEL_CLOSE),
                                    Button("Make reel", REEL_GO, PROMINENT, icon="video").tag("reel-make"), spacing=10).fill().align(CENTER))
            out.append(Dialog("Make a reel", VStack(parts^, spacing=14).align(START), on_close=REEL_CLOSE, width=520))
        if self.query_open:
            var names = String(sql_name(self.name)) if self.has_table else String("")
            for k in range(len(self.tables)):
                names += (", " if names != "" else "") + sql_name(self.tables.cards[k].name)
            out.append(Dialog("Query", VStack(
                Text("SQL over this sheet's tables: " + names + ". Joins, IN and NOT IN, subqueries, WITH; FROM a JOIN LINKED: the joins its links imply.", CAPTION),
                TextField(self.query_ask, "Ask in words (optional): taught with the SQL below, asked again it runs it", on_change=ASK_TEXT, on_submit=QUERY_RUN).fill().tag("ask")
                    .label("Ask in words").tooltip("A question in words: with SQL below, the app learns that the question means it; alone, it runs what it learned"),
                TextArea(self.query_text, "SELECT … FROM …", QUERY_TEXT, height=110).fill().tag("sql"),
                HStack(Text("Answer as", CAPTION), TextField(self.query_name, "Query 1", on_change=QUERY_NAME, on_submit=QUERY_RUN).width(200).tag("query-name"),
                       Spacer(), Button("Cancel", QUERY_CLOSE), Button("Run", QUERY_RUN, PROMINENT, icon="play").tag("run-query"), spacing=10).fill().align(CENTER),
                Text(self.query_said, CAPTION).tone(TONE_WARN).tag("query-said") if self.query_said != "" else Spacer(),
                spacing=12).align(START).fill(), on_close=QUERY_CLOSE, width=640))
        if self.compare_open:
            var pl = self.place_tables()
            var names = List[String]()
            for ref x in pl:
                names.append(x[0])
            var parts = List[View]()
            if len(names) < 2:
                parts.append(Text("Analyze two flights with Assets & defects (inspection preset) first: each gives a places table.", CAPTION).max_width(440))
            else:
                parts.append(Text("Each asset of the later flight, matched to the earlier one's within " + fixed(Float64(DRONE_MATCH_M), 0) + " m: the ones with a new defect, or a bigger one, become the worse table.", CAPTION).max_width(480))
                parts.append(HStack(Text("Earlier flight", CAPTION).width(120), Dropdown(names, min(self.compare_a, len(names) - 1), COMPARE_A).tag("compare-earlier").label("Earlier flight"), spacing=10).align(CENTER))
                parts.append(HStack(Text("Later flight", CAPTION).width(120), Dropdown(names, min(self.compare_b, len(names) - 1), COMPARE_B).tag("compare-later").label("Later flight"), spacing=10).align(CENTER))
            parts.append(HStack(Spacer(), Button("Cancel", COMPARE_CLOSE), Button("Compare", COMPARE_GO, PROMINENT, icon="chart").tag("compare-go"), spacing=10).fill().align(CENTER))
            out.append(Dialog("Compare inspections", VStack(parts^, spacing=14).align(START), on_close=COMPARE_CLOSE, width=540))
        return out^

    def context_menu(self) -> View:
        """The column's menu, open over the grid where the right click was."""
        var col = self.ctx_col
        var numeric = self.frame.kind(col) == INT or self.frame.kind(col) == DECIMAL
        var style = self.frame.format_of(col).style
        var edits = True
        return ContextMenu("grid", self.ctx_x, self.ctx_y, [
            Item("Sort smallest first", SORT_ASC, icon="sort", disabled=not edits), Item("Sort largest first", SORT_DESC, disabled=not edits), Separator(),
            Submenu("Format as", [Item("Number", FMT_NUMBER, checked=style == NUMBER), Item("Currency", FMT_CURRENCY, checked=style == CURRENCY),
                                  Item("Percent", FMT_PERCENT, checked=style == PERCENT)], icon="format").copy() if numeric else Item("Format as", NO_MSG, icon="format", disabled=True),
            Separator(), Item("Insert formula column", NEW_FORMULA, icon="formula", disabled=not edits), Item("Add row", ADD_ROW, icon="row-plus", disabled=not edits)], on_close=MENU_CLOSE)

    def overlays(self) -> List[View]:
        """What floats over the screen right now: a dialog, the toast, ƒx's popover (each is in the view only while open)."""
        var out = List[View]()
        if self.settings_open:
            var at = 0 if self.skin == LIQUID else (1 if self.skin == LEDGER else (2 if self.skin == GRAPHITE else 3))
            out.append(Dialog("Settings", VStack(
                Text("Appearance", HEADLINE), Text("The same on every computer, whatever the system theme.", CAPTION),
                Radio(materialize[SKINS](), at, SKIN),
                Text("Liquid's light or dark (the other skins have one look each).", CAPTION),
                Segmented(materialize[APPEARANCES](), self.appearance_mode, APPEARANCE).tag("appearance"),
                Divider().fill(),
                Checkbox("Show GPU timings in the status bar", self.show_timings, TIMINGS),
                Checkbox("Open the inspector with a sheet", self.inspector_open, KEEP_INSPECTOR),
                HStack(Text("Kept in settings.txt in your config folder, so every launch looks the same.", CAPTION), Spacer(), Button("Done", SETTINGS_CLOSE, PROMINENT), spacing=10).fill().align(CENTER),
                spacing=12).align(START), on_close=SETTINGS_CLOSE))
        if self.inserting == OBJ_TABLE and self.screen == SHEET:
            out.append(Dialog("Add a table", VStack(
                Text("A CSV or Parquet file beside your table: join it, query it, export it. Your table stays as it is.", CAPTION),
                HStack(Spacer(), Button("Cancel", INSERT_CLOSE),
                       FilePicker("Choose a table…", PICK_TABLE, style=PROMINENT, icon="table", accept=".csv,.tsv,.txt,.parquet").tag("choose-table"), spacing=10).fill().align(CENTER),
                spacing=14).align(START), on_close=INSERT_CLOSE, width=440))
        for v in self.video_overlays():
            out.append(v.copy())
        if (self.inserting == OBJ_VIDEO or self.inserting == OBJ_IMAGE) and self.screen == SHEET:
            var video = self.inserting == OBJ_VIDEO
            out.append(Dialog("Insert a video" if video else "Insert a picture", VStack(
                Text(("A video plays on the sheet beside your data: play, pause and scrub it, or let an agent do it." if video
                      else "A picture sits on the sheet like a chart: move it by its title, resize it by its corner."), CAPTION),
                HStack(Spacer(), Button("Cancel", INSERT_CLOSE),
                       FilePicker("Choose a video…" if video else "Choose a picture…", PICK, style=PROMINENT, icon="video" if video else "image",
                                  accept=VIDEO_TYPES if video else IMAGE_TYPES), spacing=10).fill().align(CENTER),
                spacing=14).align(START), on_close=INSERT_CLOSE, width=440))
        if self.about_open:
            out.append(Dialog("About omxplorer", VStack(
                Text("omxplorer", TITLE).tone(TONE_ACCENT), Text("open data, shape it, report on it, on your GPU", CAPTION),
                Text(self.gpu_chip(), CAPTION).tone(TONE_GOOD),
                Text("One readable language, from button to kernel.", HEADLINE),
                Text("Written once in Mojo with omxcode: the same app, the same look, on Linux, the web, Mac, iPhone and Android.", CAPTION),
                HStack(Spacer(), Button("Done", ABOUT_CLOSE, PROMINENT), spacing=10).fill(),
                spacing=10).align(START), on_close=ABOUT_CLOSE, width=480))
        if self.picking != 0 and self.screen == SHEET:
            var fill = self.picking == PICK_FILL
            var names = String("Automatic") if not fill else String("None")
            for n in materialize[SWATCH_NAMES]():
                names += " · " + n
            out.append(Popover("fill" if fill else "text-colour", "Fill colour" if fill else "Text colour", VStack(
                SwatchPicker(SWATCH_CANVAS, self.version, SWATCH), Text(names, CAPTION), spacing=6).align(START), on_close=PICK_CLOSE))
        if self.help_open:
            out.append(Popover("formula-bar", "Formulas", VStack(
                Text("A formula makes a whole column from other columns: margin = revenue - cost", CAPTION),
                Text("+  −  ×  ÷  //  %   and parentheses", CAPTION), Text("min(a, b)   max(a, b)   −a", CAPTION),
                Text("Money keeps its decimals; division rounds the way the column does.", CAPTION), spacing=6).align(START).max_width(420), on_close=HELP_CLOSE))
        if self.word_ref >= 0 and self.has_chart(self.word_ref):  # a chart word's choices, attached to the word
            var c = self.chart_of(self.word_ref)
            var rows = List[View]()
            var now = chosen(c, self.frame, self.word_slot)
            var choices = chart_choices(c, self.frame, self.word_slot)
            for k in range(min(len(choices), 60)):
                rows.append(Button(choices[k], CHOICE + k, SUBTLE, icon="check" if k == now else "").fill().align(START).tag("choice"))
            out.append(Popover("word-" + String(self.word_ref) + "-" + String(self.word_slot), materialize[SLOT_NAMES]()[self.word_slot],
                               VStack(rows^, spacing=2).align(STRETCH).max_width(260), on_close=WORD_CLOSE))
        if self.panel_open:
            out.append(Popover("island", "Activity", self.island_panel(), on_close=PANEL_CLOSE))
        return out^

    def island_panel(self) -> View:
        """The island opened: the document, what's running now, Recent (with times, Undo on the undoable) and Device
        (the GPU and the last queries' times)."""
        var parts = List[View]()
        if self.has_table:
            parts.append(Text("Document", HEADLINE))
            parts.append(Row("Name", Text(self.sheet_name)))
            parts.append(Row("Rows", Text(grouped(self.frame.rows()))))
            parts.append(Row("Columns", Text(String(self.frame.columns()))))
        if self.charts.running():
            parts.append(Text("Now", HEADLINE))
            parts.append(Text(object_title(self.charts.spec, self.frame) + " · " + String(Int(self.charts.share() * 100)) + "% · " + fixed(self.charts.seconds(), 1) + " s", CAPTION).tag("island-now"))
        parts.append(Text("Recent", HEADLINE))
        if len(self.ops) == 0:
            parts.append(Text("Nothing yet: queries, edits and results show here", CAPTION))
        var shown = 0
        var k = len(self.ops) - 1
        while k >= 0 and shown < 8:
            var op = self.ops[k].copy()
            var line: List[View] = [Text(op[0], CAPTION), Spacer()]
            if op[1] != "":
                line.append(Text(op[1], CAPTION).tone(TONE_ACCENT))
            if op[2] != NO_MSG and k == len(self.ops) - 1:
                line.append(Button("Undo", op[2], SUBTLE))
            parts.append(HStack(line^, spacing=8).fill().align(CENTER).tag("recent"))
            shown += 1
            k -= 1
        parts.append(Text("Device", HEADLINE))
        parts.append(Row("Runs on", Text(self.frame.device_name if self.frame.device else "CPU")))
        if len(self.timings) > 0:
            var sorted_ms = self.timings.copy()
            sort(sorted_ms)
            var p50 = sorted_ms[len(sorted_ms) // 2]
            var p95 = sorted_ms[min(len(sorted_ms) - 1, Int(Float64(len(sorted_ms)) * 0.95))]
            var last = String("")
            for v in self.timings:
                last += (" · " if last != "" else "") + fixed(shown_ms(v), 1)
            parts.append(Row("Last " + String(len(self.timings)), Text(last + " ms", CAPTION)))
            parts.append(Row("p50 · p95", Text(fixed(shown_ms(p50), 1) + " ms · " + fixed(shown_ms(p95), 1) + " ms").tag("island-p50")))
        return VStack(parts^, spacing=8).align(STRETCH).width(380)

    def toolbar(self) -> View:
        """The tools for the tab you're on: the sheet's (edit, data, formats, insert) or the Report's (tiles, filter)."""
        var streamed = self.frame.streamed()  # (from disk, editable: D-213)
        var left: List[Tool] = [Tool("Save", "save", SAVE, False, "Save the document (Ctrl+S)"), Tool("Undo", "undo", UNDO, False, "Undo the last change (Ctrl+Z)")]
        var right: List[Tool] = [Tool("Links", "share", LINKS_TOGGLE, self.links_open, "The links on this sheet (" + String(len(self.links)) + "): see, unlink, set a time offset"),
                                 Tool("Format", "format", TOGGLE_INSPECTOR, self.inspector_open and not self.links_open, "Show or hide the inspector (Ctrl+Shift+I)")]
        var extra = List[View]()
        if streamed:
            extra.append(Text("Streamed from disk", CAPTION).tone(TONE_ACCENT).tooltip("This file is bigger than memory: its rows are read from disk as they're shown, and your edits are kept beside it until you save").tag("streamed"))
        extra.append(FilePicker("Open", PICK, style=ICON_ONLY if self.win_w < COMPACT_W else TOOL_INLINE, icon="import", accept=OPEN_TYPES).tooltip("Open a CSV, Parquet or .omx file, or a video or picture"))
        extra.append(FilePicker("Table", PICK_TABLE, style=TOOL_INLINE, icon="table", accept=".csv,.tsv,.txt,.parquet").tooltip("Insert a table: a CSV or Parquet file as a card beside the sheet's own (read in the background)").tag("insert-table"))
        extra.append(FilePicker("Documents", PICK_DOCS, style=TOOL_INLINE, icon="file", accept="folder,.pdf").tooltip("Insert documents: a folder of PDFs (or one) as a card; say which fields to read and Read finds them (OCR)").tag("insert-documents"))
        extra.append(TextField(self.query_text, "query", on_change=QUERY_BAR, on_submit=QUERY_BAR_RUN).width(260).tag("query-bar").label("SQL query over the sheet's tables").tooltip("SQL over the sheet's tables (its own and every card's); Return runs it, the answer lands as a table card"))
        if self.sheet_tab == 1:
            return Toolbar(left, self.report_tools(), right, extra, before=self.report_controls(), after=self.filter_controls(), inline=True)  # (its tile tools share one icon: their titles stay)
        var middle = List[Tool]()
        middle.append(Tool("Add row", "row-plus", ADD_ROW, False, "A new row at the end (Ctrl+Shift+R)"))
        middle.append(Tool("Formula", "formula", NEW_FORMULA, self.formula_open, "A new column computed from others"))
        middle.append(Tool("Sort", "sort", SORT, self.grid.sort_col >= 0, "Sort by the selected column; again to flip"))
        middle.append(Tool("Pivot", "pivot", INSERT_PIVOT, False, "A pivot table of the selected column (Ctrl+Shift+P)"))
        middle.append(Tool("Chart", "chart-bar", INSERT_CHART, False, "A chart of the selected column (Ctrl+Shift+C)"))
        middle.append(Tool("Query", "database", QUERY_OPEN, self.query_open, "Ask the sheet's tables in SQL: joins, IN, subqueries; the answer is a table"))
        return Toolbar(left, middle, right, extra, toggles=self.format_tools(), inline=True, compact=self.win_w < COMPACT_W)

    def format_tools(self) -> List[List[Tool]]:
        """Excel's Home tab, in small toggles: font, colours, alignment, number. Each shows the selection's state."""
        var col = self.grid.cur_col
        var st = self.frame.style_of(col, self.grid.cur_row) if col >= 0 else CellStyle()
        var number = self.frame.format_of(col).style if col >= 0 else AUTO
        var target = "the selected cell" if self.grid.cur_row >= 0 else "the selected column"
        var font: List[Tool] = [Tool("Bold", "bold", STYLE_BOLD, st.bold(), "Bold: " + target + " (Ctrl+B)"),
                                Tool("Italic", "italic", STYLE_ITALIC, st.italic(), "Italic (Ctrl+I)"),
                                Tool("Underline", "underline", STYLE_UNDERLINE, st.underline(), "Underline (Ctrl+U)"),
                                Tool("Strikethrough", "strikethrough", STYLE_STRIKE, st.strike(), "Strikethrough (Ctrl+5)")]
        var colours: List[Tool] = [Tool("Text colour", "text-colour", PICK_INK, st.ink() > 0 or self.picking == PICK_INK, "Text colour: " + swatch_name(st.ink())),
                                   Tool("Fill colour", "fill", PICK_FILL, st.fill() > 0 or self.picking == PICK_FILL, "Fill: " + (swatch_name(st.fill()) if st.fill() > 0 else "none"))]
        var align: List[Tool] = [Tool("Align left", "align-left", STYLE_ALIGN + ALIGN_LEFT, st.align() == ALIGN_LEFT, "Align left"),
                                 Tool("Align centre", "align-center", STYLE_ALIGN + ALIGN_CENTRE, st.align() == ALIGN_CENTRE, "Centre"),
                                 Tool("Align right", "align-right", STYLE_ALIGN + ALIGN_RIGHT, st.align() == ALIGN_RIGHT, "Align right")]
        var numbers: List[Tool] = [Tool("Currency", "currency", FMT_CURRENCY, number == CURRENCY, "Currency: the whole column (again: automatic)"),
                                   Tool("Percent", "percent", FMT_PERCENT, number == PERCENT, "Percent: the whole column (again: automatic)"),
                                   Tool("Fewer decimals", "decimals-less", DECIMALS_LESS, False, "One decimal place fewer: the whole column"),
                                   Tool("More decimals", "decimals-more", DECIMALS_MORE, False, "One decimal place more: the whole column"),
                                   Tool("Clear formatting", "clear-format", CLEAR_FORMAT, False, "Back to plain: " + target)]
        return [font^, colours^, align^, numbers^]

    def report_tools(self) -> List[Tool]:
        return [Tool("Sum tile", "plus", ADD_TILE + TILE_SUM, False, "A tile with the column's total"),
                Tool("Average tile", "plus", ADD_TILE + TILE_AVERAGE, False, "A tile with the column's average"),
                Tool("Median tile", "plus", ADD_TILE + TILE_MEDIAN, False, "A tile with the column's middle value"),
                Tool("Distinct tile", "plus", ADD_TILE + TILE_DISTINCT, False, "A tile with how many different values the column holds (text too)"),
                Tool("Count tile", "plus", ADD_TILE + TILE_COUNT, False, "A tile with the number of rows"),
                Tool("Chart tile", "chart-bar", ADD_TILE + TILE_CHART, False, "A chart of the column by group")]

    def report_controls(self) -> List[View]:
        """Before the Report's tile tools: the column new tiles use; after them, the filter every tile reads through."""
        var every = List[Int]()
        for c in range(self.frame.columns()):
            every.append(c)
        var out = List[View]()
        var compact = self.win_w < COMPACT_W  # (a narrow toolbar: short labels, never two lines)
        out.append(HStack(Text("Of" if compact else "Tiles of", CAPTION), Dropdown(self.names_of(every), max(self.report_col, 0), REPORT_COL).tag("tiles-of").tooltip("The column new tiles add up, average or count"), spacing=6).align(CENTER))
        return out^

    def filter_controls(self) -> List[View]:
        var texts = self.texts()
        var cols = List[String]()
        cols.append("Every row")
        for c in texts:
            cols.append(self.frame.name(c))
        var at_col = 0
        for k in range(len(texts)):
            if texts[k] == self.filter.col:
                at_col = k + 1
        var out = List[View]()
        out.append(HStack(Text("Filter" if self.win_w < COMPACT_W else "Filter · every tile", CAPTION), Dropdown(cols, at_col, FILTER_COL).tag("filter-column").tooltip("The rows every tile reads"), spacing=6).align(CENTER))
        if self.filter.col >= 0:
            var values = List[String]()
            for code in range(groups_of(self.frame, self.filter.col)):
                values.append(self.frame.text_of(self.filter.col, Int64(code)))
            out.append(HStack(Text("is", CAPTION), Dropdown(values, self.filter.code, FILTER_VALUE).tag("filter-value").label("Filter value"), spacing=6).align(CENTER))
        return out^

    def report_inspector(self) -> View:
        """The Report's inspector: the chart tile being edited (its sentence and pages), else where the Report's numbers
        come from (the tiles and the filter are in the toolbar)."""
        if self.asking >= TILE_REF and self.has_chart(self.asking):
            var one: List[String] = ["Chart"]
            return Inspector(one, 0, NO_MSG, self.chart_inspector(self.asking), INSPECTOR_W)
        var sections = List[View]()
        var data = List[View]()
        data.append(Row("Source", Text(self.sheet_name)))
        data.append(Row("Rows", Text(grouped(self.frame.rows()))))
        data.append(Row("Filter", Text(self.filter.words(self.frame), CAPTION)))
        data.append(Text("Edits in the table show here at once. Add tiles and set the filter in the toolbar.", CAPTION))
        sections.append(Section("Data", data))
        var tabs: List[String] = [self.report_name]
        return Inspector(tabs, 0, NO_MSG, sections, INSPECTOR_W)

    def chart_inspector(self, cref: Int) -> List[View]:
        """A chart's inspector: its sentence and what's set, a row per part opening its page (Data, Order, Rows, Style)."""
        var c = self.chart_of(cref)
        ref f = self.frame
        if self.insp_page == 1:
            var nums = number_columns(f)
            var texts = text_columns(f)
            var at_value = 0
            for k in range(len(nums)):
                if nums[k] == c.value:
                    at_value = k
            var groups = chart_choices(c, f, SLOT_GROUP)
            var at_group = max(chosen(c, f, SLOT_GROUP), 0)
            return InspectorPage("Data", PAGE, [
                Section("Combine", [Segmented(materialize[COMBINES](), c.combine, INSP_SET + SLOT_COMBINE).fill()]),
                Section("Value", [Dropdown(self.names_of(nums), at_value, INSP_SET + SLOT_VALUE).fill(),
                                  Text("Count reads rows: the value doesn't matter to it" if c.combine == COMBINE_COUNT else "Numbers and formula columns", CAPTION)]),
                Section("Group by", [Dropdown(groups, at_group, INSP_SET + SLOT_GROUP).fill()])])
        if self.insp_page == 2:
            var tops = materialize[TOPS]()
            var at_top = 0
            for k in range(len(tops)):
                if tops[k] == c.top:
                    at_top = k
            var shows: List[String] = ["All", "Top 3", "Top 5", "Top 10"]
            return InspectorPage("Order", PAGE, [
                Section("Order", [Dropdown(materialize[ORDERS](), c.order, INSP_SET + SLOT_ORDER).fill()]),
                Section("Show", [Segmented(shows, at_top, INSP_SET + SLOT_TOP).fill()])])
        if self.insp_page == 3:
            var at = max(chosen(c, f, SLOT_FILTER), 0)
            var note = String("The Report's filter applies too: ") + self.filter.words(f) if cref >= TILE_REF else String("Only these rows are added up")
            var ncol = c.num_col if c.num_col >= 0 else c.value
            var kinds = materialize[NUM_KINDS]()
            var kind_at = c.num_op if c.num_col >= 0 else 0  # (NUM_* in NUM_KINDS's order)
            var nums = List[View]()
            nums.append(Dropdown(kinds, kind_at, NUM_PICK).fill().tag("num-kind").label("Number filter"))
            if kind_at != NUM_ANY:
                var lo = f.format_value(ncol, Int64(c.num_lo), total=True)
                var hi = f.format_value(ncol, Int64(c.num_hi), total=True)
                if kind_at == NUM_OVER or kind_at == NUM_AT_LEAST or kind_at == NUM_BETWEEN:
                    nums.append(TextField(lo, "From", on_submit=NUM_LO).fill().tag("num-lo"))
                if kind_at == NUM_UNDER or kind_at == NUM_AT_MOST or kind_at == NUM_BETWEEN:
                    nums.append(TextField(hi, "To", on_submit=NUM_HI).fill().tag("num-hi"))
            nums.append(Text("On " + f.name(ncol) + ": type a value and press Return", CAPTION))
            return InspectorPage("Rows", PAGE, [Section("Rows", [Dropdown(chart_choices(c, f, SLOT_FILTER), at, INSP_SET + SLOT_FILTER).fill(), Text(note, CAPTION)]),
                                                Section(f.name(ncol), nums)])
        if self.insp_page == 4:
            var marks: List[String] = ["Bars", "Line"]
            return InspectorPage("Style", PAGE, [Section("As", [Segmented(marks, 1 if c.style == CHART_LINE else 0, INSP_SET + SLOT_MARK).fill()])])
        var head = List[View]()
        head.append(Text(chart_sentence(c, f), HEADLINE).tag("chart-sentence"))
        head.append(Text("Tap a coloured word in the chart's title, ask in its field, or open a part below. Follows edits to " + self.sheet_name + ".", CAPTION))
        var rows = List[View]()
        rows.append(NavRow("Data", slot_text(c, f, SLOT_COMBINE) + " of " + slot_text(c, f, SLOT_VALUE) + " · by " + slot_text(c, f, SLOT_GROUP), PAGE + 1, icon="formula"))
        rows.append(NavRow("Order", slot_text(c, f, SLOT_ORDER) + " · " + slot_text(c, f, SLOT_TOP), PAGE + 2, icon="sort"))
        rows.append(NavRow("Rows", slot_text(c, f, SLOT_FILTER), PAGE + 3, icon="filter-off"))
        rows.append(NavRow("Style", slot_text(c, f, SLOT_MARK), PAGE + 4, icon="chart-bar"))
        return [Section("Chart", head), Section("Parts", rows)]

    def object_inspector(self) -> List[View]:
        """The selected chart's or pivot's settings."""
        var sections = List[View]()
        ref o = self.objects[self.active]
        var nums = self.numbers()
        var texts = self.texts()
        var head = List[View]()
        head.append(Text(object_title(o, self.frame), HEADLINE))
        head.append(Text("Follows edits to " + self.sheet_name + ".", CAPTION))  # (its time is on the card, once)
        sections.append(Section("Chart" if o.kind == OBJ_CHART else "Pivot", head))
        var data = List[View]()
        if o.kind == OBJ_CHART:
            var styles: List[String] = ["Bar", "Line"]
            data.append(Row("Type", Segmented(styles, 1 if o.style == CHART_LINE else 0, CHART_STYLE)))
            data.append(Row("Value", Dropdown(self.names_of(nums), self.index_in(nums, o.value), OBJ_VALUE)))
            data.append(Row("Group by", Dropdown(chart_choices(o, self.frame, SLOT_GROUP), max(chosen(o, self.frame, SLOT_GROUP), 0), OBJ_GROUP)))  # (the sentence's choices: a date's month too)
        else:
            var across = List[String]()
            across.append("None")
            for c in texts:
                across.append(self.frame.name(c))
            data.append(Row("Value", Dropdown(self.names_of(nums), self.index_in(nums, o.value), OBJ_VALUE)))
            data.append(Row("Rows", Dropdown(self.names_of(texts), self.index_in(texts, o.group), OBJ_GROUP)))
            data.append(Row("Columns", Dropdown(across, self.index_in(texts, o.across) + 1 if o.across >= 0 else 0, OBJ_ACROSS)))
        sections.append(Section("Data", data))
        return sections^

    def inspector(self) -> View:
        if self.links_open:  # (the toolbar's Links: the sheet's links, their offsets, Unlink)
            return Inspector(["Links"], 0, LINKS_TOGGLE, self.links.panel(), INSPECTOR_W)
        if self.sheet_tab == 1:
            return self.report_inspector()
        var tabs: List[String] = ["Table", "Cell"]
        if 0 <= self.active < len(self.objects):
            tabs.append("Chart" if self.objects[self.active].kind == OBJ_CHART else "Pivot")
            if self.insp_tab == 2:
                if self.objects[self.active].kind == OBJ_CHART:  # (a chart: its sentence and pages, editing the chart being asked about)
                    if self.asking != self.active:
                        return Inspector(tabs, 2, INSP_TAB, self.object_inspector(), INSPECTOR_W)
                    return Inspector(tabs, 2, INSP_TAB, self.chart_inspector(self.active), INSPECTOR_W)
                return Inspector(tabs, 2, INSP_TAB, self.object_inspector(), INSPECTOR_W)
        var sections = List[View]()
        if self.insp_tab == 0:
            var info = List[View]()
            info.append(Row("Name", Text(self.sheet_name)))
            info.append(Row("Rows", Text(grouped(self.frame.rows()))))
            info.append(Row("Columns", Text(String(self.frame.columns()))))
            info.append(Row("From", Text(file_name(self.source) if self.source != "sample" else "the sample", CAPTION)))
            sections.append(Section("Table", info))
            var cols = List[View]()
            for c in range(self.frame.columns()):
                cols.append(Row(self.frame.name(c), Text(kind_name(self.frame.kind(c)) + ("" if self.frame.format_of(c).is_auto() else " · " + self.frame.format_of(c).summary()), CAPTION)))
            sections.append(Section("Columns", cols))
        else:
            var col = self.grid.cur_col
            var f = self.column_format()
            var kind = self.frame.kind(col) if col >= 0 else TEXT
            var head = List[View]()
            head.append(Text((self.frame.name(col) if col >= 0 else "No column") + " · " + kind_name(kind), HEADLINE))
            head.append(Text("A format applies to the whole column: the cells, the totals below, and everything that reads it.", CAPTION))
            sections.append(Section("Column", head))
            var fmt = List[View]()
            if kind == DATE:
                fmt.append(Dropdown(materialize[DATE_STYLES](), 0 if f.style == AUTO else f.style - DATE_LONG + 1, FORMAT).fill().label("Date format"))
            elif kind == TEXT:
                fmt.append(Text("Text", CAPTION))
            elif kind == BOOL:  # (no decimals or separators: a yes or a no, shown as a pill)
                fmt.append(Text("Yes / No", CAPTION))
            else:
                fmt.append(Dropdown(materialize[NUMBER_STYLES](), f.style, FORMAT).fill().label("Number format"))
                var places = f.decimals if f.decimals >= 0 else (self.frame.scale(col) if kind == DECIMAL else 0)
                fmt.append(Row("Decimals", Stepper(String(places), DECIMALS_LESS, DECIMALS_MORE)))
                fmt.append(Row("Thousands separator", Toggle("", f.thousands, THOUSANDS)))
                fmt.append(Row("Negatives", Segmented(materialize[NEGATIVE_STYLES](), 1 if f.parens else 0, NEGATIVES)))
                if f.style == CURRENCY:
                    var symbols = materialize[SYMBOLS]()
                    var at_symbol = 0
                    for k in range(len(symbols)):
                        if symbols[k] == f.symbol:
                            at_symbol = k
                    fmt.append(Row("Currency", Segmented(symbols, at_symbol, SYMBOL)))
            sections.append(Section("Data format", fmt))
            if len(self.stats) > 0:
                sections.append(Section("Column stats", [StatCards(self.stats)]))
        return Inspector(tabs, min(self.insp_tab, 1), INSP_TAB, sections, INSPECTOR_W)

    def status(self) -> View:
        var items = List[String]()
        var col = self.grid.cur_col
        if self.grid.has_block():
            var b = self.grid.block(self.frame)
            items.append("Selection " + String(b[1] - b[0] + 1) + " rows × " + String(b[3] - b[2] + 1) + " columns")
            for t in self.block_lines:
                items.append(t)
            if self.message != "":
                items.append(self.message)
            return StatusBar(items, (fixed(shown_ms(self.milliseconds), 1) + " ms on " + (self.frame.device_name if self.ran_gpu else "CPU")) if self.show_timings else "")
        if col >= 0 and self.grid.cur_row >= 0:
            items.append("Selection " + self.frame.name(col) + " · row " + grouped(self.grid.cur_row + 1) + " · " + self.frame.display(col, self.grid.cur_row))
        elif col >= 0:
            items.append("Selection column " + self.frame.name(col))
        items.append("Rows " + grouped(self.frame.rows()))
        items.append("Columns " + String(self.frame.columns()))
        if col >= 0 and (self.frame.kind(col) == INT or self.frame.kind(col) == DECIMAL):
            items.append("Sum " + self.frame.format_value(col, Int64(self.sum), total=True))
            items.append("Average " + self.frame.format_average(col, self.sum, self.count))
        if self.message != "":
            items.append(self.message)
        if self.frame.read_problem() != "":
            items.append("Couldn't read the file: " + self.frame.read_problem())
        return StatusBar(items, (fixed(shown_ms(self.milliseconds), 1) + " ms on " + (self.frame.device_name if self.ran_gpu else "CPU")) if self.show_timings else "")

    def sheet_width(self) -> Int:
        return self.win_w - 40 - RAIL_W - 16 - (INSPECTOR_W + 16 if self.inspector_open else 0)

    def rail(self) -> View:
        """The sheet's side rail (mojoui.sheetchrome.Rail): what goes on the page from a file (a table, a video, a picture)."""
        var items = List[View]()
        items.append(FilePicker("Table", PICK_TABLE, style=ICON_ONLY, icon="table", accept=TABLE_TYPES).tooltip("Insert a table from a CSV or Parquet file"))
        items.append(FilePicker("Documents", PICK_DOCS, style=ICON_ONLY, icon="file", accept="folder,.pdf").tooltip("Insert documents: a folder of PDFs, read into a table of their fields"))
        items.append(Button("Video", INSERT_VIDEO, ICON_ONLY, icon="video").tooltip("Insert a video"))
        items.append(Button("Picture", INSERT_IMAGE, ICON_ONLY, icon="image").tooltip("Insert a picture"))
        return Rail(items^, RAIL_W)

    def report_view(self) -> View:
        """The Report tab (Stitch 06): KPI and chart tiles over the filtered rows, and the row that adds them."""
        var kpis = List[View]()
        var charts = List[View]()
        var first_kpi = self.accent() != REPORT_RED  # (a red figure would read as a loss: in the report the tint is for the chrome only, D-254)
        for k in range(len(self.tiles)):
            ref t = self.tiles[k]
            if t.kind == TILE_CHART:
                var cv = chart_view(t.chart, self.frame)
                var asked = self.asking == TILE_REF + k
                var parts = List[View]()
                parts.append(HStack(Sentence(chart_words(t.chart, self.frame, WORD + (TILE_REF + k) * 10, TILE_REF + k, self.lit.copy() if asked else List[Int]()),
                                             width=max(30, (self.sheet_width() - 120) // 9), tag="sentence-" + String(TILE_REF + k)),
                                    Spacer(), Button("Remove", TILE_CLOSE + k, ICON_ONLY, icon="close"), spacing=8).fill().align(START))
                if asked:
                    for v in self.ask_views():
                        parts.append(v.copy())
                parts.append(Canvas(60 + k, self.version, on_gesture=TILE_TAP + k).fill().height(240))
                parts.append(Text(readout(t.chart, self.frame), CAPTION))
                charts.append(ChartTile(parts^))
            else:
                kpis.append(KpiTile(kpi_of(t, self.frame, self.filter, first_kpi).view(120 + k, self.version, TILE_CLOSE + k, tile_fact(t, self.frame))))
                first_kpi = False
        if len(kpis) > 0:  # (Stitch's report: a dashed card where the next tile goes)
            kpis.append(AddTile("Add a tile from the toolbar"))
        var matched = String("")
        for t in self.tiles:
            if t.kind == TILE_SUM or t.kind == TILE_AVERAGE or t.kind == TILE_COUNT:
                matched = " · " + grouped(t.count) + " of " + grouped(self.frame.rows()) + " rows"
                break
        var ran = " · " + fixed(shown_ms(self.milliseconds), 1) + " ms on " + ("the GPU" if self.ran_gpu else "the CPU") if self.show_timings else String("")
        var facts = String(matched + ran)
        if facts.startswith(" · "):
            var cut = String(facts[byte=len(String(" · ").as_bytes()):])  # (the dot is two bytes: " · " is four)
            facts = cut
        var page = ReportPage(self.report_name, self.sheet_name + " · " + self.filter.words(self.frame), kpis, charts, facts)
        if len(self.tiles) == 0:  # (an empty report says where tiles come from)
            page = VStack(page^, Card(Text("An empty report: add a tile from the toolbar above (Sum, Average, Count or Chart of the column you pick there). Every tile reads the table, so edits show here at once.", CAPTION), spacing=8).fill(), spacing=16).fill().align(START)
        return Scroll(page^.width(self.sheet_width() - 8).padding(4, 4), height=self.grid_h() + FX_H).fill().grow().tag("report-page")  # (full width: the charts span it)

    def sheet_screen(self) -> View:
        var width = self.sheet_width()
        var cell = (self.frame.name(self.grid.cur_col) if self.grid.cur_col >= 0 else "") + (" " + String(self.grid.cur_row + 1) if self.grid.cur_row >= 0 else "")
        var fx = FormulaBar("New column", "", FORMULA_SUBMIT, placeholder="A new column: its name, then its formula", on_help=FX_HELP) if self.formula_open else FormulaBar(cell, self.edit_text, FX_COMMIT, CELL_CANCEL, on_help=FX_HELP)
        var sorted = ("sorted by " + self.frame.name(self.grid.sort_col) + (" ↓" if self.grid.sort_desc else " ↑")) if self.grid.sort_col >= 0 else String("")
        var head = HStack(Text(self.table_title if self.table_title != "" else self.sheet_name, HEADLINE), Text(grouped(self.frame.rows()) + " rows", CAPTION).tone(TONE_ACCENT), Spacer(),
                          Text(sorted, CAPTION), spacing=12).fill().align(CENTER).height(HEADER_H - 8)
        var th = self.table_h()
        var items = List[View]()  # child 0: the table (its title bar is the drag handle; it stays put); then the objects; then the editor
        items.append(VStack(head, Canvas(0, self.version + self.grid.version, on_gesture=GRID, keys=True).fill().height(th - HEADER_H).tag("grid").label("Table " + self.sheet_name + ", " + grouped(self.frame.rows()) + " rows"), spacing=8)
                     .at(self.table_x, self.table_y).width(self.table_w if self.table_w > 0 else width).height(th).tag("table"))
        var bottom = self.table_y + th
        for k in range(len(self.objects)):
            ref o = self.objects[k]
            var asked = self.asking == k
            items.append(object_card(o, self.frame, 10 + k, self.version, OBJ_TAP + k, OBJ_CLOSE + k, OBJ_PICK + k, WORD + k * 10, k,
                                     self.lit.copy() if asked else List[Int](), self.ask_views() if asked else List[View](), ASK_H if asked else 0)
                         .at(o.x, o.y).width(o.w).height(o.h).tag("chart" + String(k) if o.kind == OBJ_CHART else "pivot" + String(k)))
            bottom = max(bottom, o.y + o.h)
        for k in range(len(self.media)):
            ref c = self.media.cards[k]
            items.append(self.media.view(k).at(c.x, c.y).width(c.w).height(c.h).tag(("video" if c.kind == OBJ_VIDEO else "image") + String(k)))
            bottom = max(bottom, c.y + c.h)
        for k in range(len(self.tables)):
            ref t = self.tables.cards[k]
            items.append(self.tables.view(k, self.version).at(t.x, t.y).width(t.w).height(t.h).tag("tablecard" + String(k)))
            bottom = max(bottom, t.y + t.h)
        for k in range(len(self.tracks)):
            ref r = self.tracks.cards[k]
            items.append(self.tracks.view(k, self.version * 100003 + self.track_frame(k)).at(r.x, r.y).width(r.w).height(r.h).tag("track" + String(k)))
            bottom = max(bottom, r.y + r.h)
        for k in range(len(self.docs)):
            ref d = self.docs[k].card
            items.append(self.docs[k].view().at(d.x, d.y).width(d.w).height(d.h).tag("documents" + String(k)))
            bottom = max(bottom, d.y + d.h)
        var ed = self.grid.editor_place(self.frame)
        if ed[2] > 0:
            items.append(self.grid.editor(self.edit_text, CELL_COMMIT, CELL_CANCEL).at(self.table_x + ed[0], self.table_y + HEADER_H + ed[1]).width(ed[2]).height(30))
        var tones = List[Int]()  # (a peek or a drop: how each card stands, mojoui.boardlook)
        for i in range(len(items)):
            tones.append(max(self.peek.tone(i), self.ld.tone(i)))
        for v in self.ld.views(width):  # (what floats over the cards: the column dragged, the panel; the peek's lines and labels)
            items.append(v.copy())
        for v in self.peek.views(width, bottom + 24):
            items.append(v.copy())
        var area = (Board(items^, width, bottom + 24, on_move=MOVE, on_resize=RESIZE, reveal=self.reveal, reveal_count=self.reveal_count,
                          tones=tones, on_hold=HOLD).fill().grow()) if self.sheet_tab == 0 else self.report_view()
        # The sheet's column takes the room the inspector leaves, the row takes the height the bars leave: sizes
        # come from the window (App.resize), never asked of it, so the window never grows to fit them (goal 25 M2).
        var main = (VStack(fx, area^, spacing=6) if self.sheet_tab == 0 else VStack(area^, spacing=6)).grow().align(STRETCH)
        var row = (HStack(self.rail(), main, self.inspector(), spacing=16) if self.inspector_open else HStack(self.rail(), main, spacing=16)).align(STRETCH)
        var tabs: List[Tab] = [Tab(self.sheet_name, "sheet"), Tab(self.report_name, "chart-bar")]
        var chip = List[View]()  # (the GPU's state shows once, in the menu bar)
        var parts = List[View]()
        parts.append(self.menu_bar())
        parts.append(self.toolbar())
        parts.append(row^.padding(0, 20).fill().grow())
        parts.append(BottomTabs(tabs, self.sheet_tab, TAB, self.renaming, RENAME_SUBMIT, RENAME_CANCEL, chip).height(30))  # (Excel's place for them)
        parts.append(self.status().height(30))
        if self.ctx_col >= 0 and self.sheet_tab == 0:
            parts.append(self.context_menu())
        parts.append(Clipboard(self.clip_text, self.clip_version))
        for o in self.overlays():
            parts.append(o.copy())
        return VStack(parts^, spacing=6).fill().grow()


def fill_rows(mut rows: CardRows, sheet: Sheet):
    """`rows`' columns read from `sheet` as text (a column the sheet lacks stays empty)."""
    var at = List[Int]()
    for c in rows.columns:
        at.append(sheet.index(c))
    for r in range(sheet.rows()):
        if not sheet.alive(r):
            continue
        var vals = List[String]()
        for i in at:
            vals.append(sheet.display(i, r) if i >= 0 else String(""))
        rows.add_row(vals)


def clock_text(t: Float64) -> String:
    """Seconds as m:ss.s ("0:05.3")."""
    var whole = Int(t)
    var tenth = Int((t - Float64(whole)) * 10.0)
    var sec = whole % 60
    return String(whole // 60) + ":" + ("0" if sec < 10 else "") + String(sec) + "." + String(tenth)
