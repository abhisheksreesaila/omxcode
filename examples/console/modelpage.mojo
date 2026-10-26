# The model page (model-page.js): one page per model at #/models/<name>/<tab>. A header with the tabs and the model's
# verbs; below it the tab. Overview is here: Right now (four tiles), Tokens (the last 5 minutes), About, GPU fit, Call it.

from mojoui.view import View, Text, Button, Icon, VStack, HStack, Spacer, Divider, Canvas, SUBTLE, PLAIN, ICON_ONLY, CENTER, START, END
from mojoui.chip import Chip, Badge
from mojoui.codeblock import CodeBlock
from mojoui.sparkline import SparklineView
from mojoui.header import PillTabs, TabHeader, ActionGroup
from mojoui.buttons import FlatButton
from mojoui.panel import Panel, PanelTitle, PanelFoot, PanelRow, PanelGrid, StatTile, StatGrid, Fact, FactText, FactLink, FactList, KEYS_WIDE, KEYS_COMPACT
from mojoui.marks import StatusMark, GOOD, QUIET
from mojoui.words import CommandLines
from mojoui.copy import CopyRow, LabeledValue, CodePanel
from mojoui.meter import UsageBar
from mojoui.chip import TagEditor
from data import Store, Model, row_of, hardware, fmt, dur, rounded, round1, strip_arch
from msgs import PLACE, TAB, CMD_STOP, CMD_RESTART, CMD_COPY, CMD_REMOVE, CMD_START, COPY_CURL, REMOVE_LABEL, ADD_LABEL, KEYS, SPARK, FIT

comptime TAB_KEYS: List[String] = ["overview", "benchmark", "logs", "notebook"]
comptime TAB_TITLES: List[String] = ["Overview", "Benchmark", "Logs", "Notebook"]
comptime TAB_ICONS: List[String] = ["box", "gauge", "scroll-text", "book-open"]
comptime TAB_HUES: List[Int] = [2, 5, 0, 2]  # model-page.js MODEL_TABS: --hue-network (data-2), --hue-bench (data-5), --hue-logs (ink-2), --hue-notebook (data-2)


def tab_index(tab: String) -> Int:
    var keys = materialize[TAB_KEYS]()
    for k in range(len(keys)):
        if keys[k] == tab:
            return k
    return 0


def curl_for(url: String, name: String) -> String:
    return ("curl " + url + "/chat/completions \\\n  -H \"Authorization: Bearer $MXC_API_KEY\" \\\n  -H \"Content-Type: application/json\" \\\n"
            + "  -d '{\"model\":\"" + name + "\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")


@fieldwise_init
struct Fit(Copyable, Movable):
    """model-page.js fitView: this model's GPU memory against the others and the card."""
    var present: Bool
    var total_gb: Float64
    var this_gb: Float64
    var others_gb: Float64
    var free_gb: Float64


def fit_of(st: Store, name: String) -> Fit:
    var hw = hardware(st)
    var mine = 0.0
    var others = 0.0
    for c in st.crew:
        if c[0] == name:
            mine = round1(c[1])
        else:
            others += round1(c[1])
    return Fit(hw.present, hw.total_gb, mine, round1(others), round1(hw.total_gb - hw.used_gb))


def model_header(m: Model, tab: String, phone: Bool) -> View:
    """The tabs and the verbs for the model's state (commandsFor): one filled verb, the power one; Remove last."""
    var cmds: List[View] = []
    if m.state == "ready":
        cmds.append(FlatButton("Stop", CMD_STOP, "square", filled=True, compact=phone))
        cmds.append(FlatButton("Restart", CMD_RESTART, "rotate-cw", hue=8, compact=phone))  # (commandsFor: restart in --oq-warn)
    elif m.state == "starting":
        cmds.append(FlatButton("Stop", CMD_STOP, "square", filled=True, compact=phone))
    elif m.state == "crashed":
        cmds.append(FlatButton("Restart", CMD_RESTART, "rotate-cw", filled=True, compact=phone))
    else:
        cmds.append(FlatButton("Start", CMD_START, "play", filled=True, compact=phone))
    cmds.append(FlatButton("Copy endpoint", CMD_COPY, "copy", square=phone, compact=phone))
    cmds.append(FlatButton("Remove", CMD_REMOVE, "trash-2", danger=True, compact=phone))
    var tabs = PillTabs(materialize[TAB_TITLES](), materialize[TAB_ICONS](), tab_index(tab), TAB, materialize[TAB_HUES](), fill=phone)
    return TabHeader(tabs^, ActionGroup(cmds^, fill=phone), compact=phone)


def overview_view(st: Store, m: Model, phone: Bool, copies: Int) -> View:
    var r = row_of(st, m)
    var fit = fit_of(st, m.name)
    var url = st.lan_endpoint if st.lan_endpoint != "" else st.endpoint_now()
    # Right now: the same four tiles, always in this order (metricsView)
    var req = r.requests_value if r.requests_value >= 0 else 0
    var tiles = StatGrid([StatTile("Requests", fmt(Float64(req)), "", "last 5 minutes"),
                          StatTile("Speed", fmt(r.tps_value) if r.tps_value >= 0 else String("—"), "tok/s" if r.tps_value >= 0 else String(""), "decode, median"),
                          StatTile("Latency p50", fmt(r.ttft_value) if r.ttft_value >= 0 else String("—"), "ms" if r.ttft_value >= 0 else String(""), "time to first token"),
                          StatTile("Memory", fmt(fit.this_gb, 1) if fit.this_gb > 0 else String("—"), "GB" if fit.this_gb > 0 else String(""), "GPU, this model")])
    var right_now = Panel([PanelTitle("gauge", "Right now", 1), tiles^, PanelFoot("mxc status")])
    var tokens = Panel([PanelTitle("scroll-text", "Tokens", 1), SparklineView(SPARK, len(st.points(m.name)) * 1000 + Int(r.tps_value)), PanelFoot("mxc metrics --json")])
    # About
    var unload = "never (pinned)" if m.pinned else (("after " + dur(m.keep_alive) + " idle") if m.keep_alive > 0 else String("—"))
    var vram = String("—")
    if fit.this_gb > 0:
        vram = fmt(fit.this_gb, 1) + " GB" + ((" · " + String(Int(rounded(fit.this_gb / fit.total_gb * 100, 0))) + "% of " + fmt(fit.total_gb, 1) + " GB") if fit.total_gb > 0 else String(""))
    var state_text = r.state_label + ((" · " + r.note) if r.note != "" else String(""))
    var keys = KEYS_COMPACT if phone else KEYS_WIDE
    var facts = FactList([Fact("Repository", FactText(r.repo if r.repo != "" else String("—")), keys),
                          Fact("Architecture", FactText(r.arch), keys),
                          Fact("Source", FactText(m.source if m.source != "" else String("—")), keys),
                          Fact("Unloads", FactText(unload), keys),
                          Fact("Endpoint", FactText(url), keys),
                          Fact("Reachable", HStack(FactText("LAN · HTTPS · " if st.lan_endpoint != "" else "This machine only · "), FactLink("Security ›", PLACE + 2), spacing=0), keys),
                          Fact("GPU memory", FactText(vram), keys),
                          Fact("State", StatusMark(state_text, GOOD if r.running else QUIET, mono=True, live=r.running), keys),
                          Fact("Labels", TagEditor(m.labels, REMOVE_LABEL, "label", ADD_LABEL), keys)])
    var about = Panel([PanelTitle("box", "About", 2), facts^, PanelFoot("mxc ls --json")])
    var figures: List[String] = ["this " + fmt(fit.this_gb, 1) + " GB" if fit.present else "no GPU found", ("others " + fmt(fit.others_gb, 1) + " GB") if fit.present else "",
                                 ("free " + fmt(fit.free_gb, 1) + " GB of " + fmt(fit.total_gb, 1) + " GB") if fit.present else ""]
    var gpu = Panel([PanelTitle("gauge", "GPU fit", 3), HStack(UsageBar(FIT, Int(fit.this_gb * 10) + Int(fit.total_gb * 1000), figures).grow(), spacing=0).fill().tag("gpu-fit")])
    var call = Panel([PanelTitle("terminal", "Call it", 4),
                      CopyRow("local" if st.lan_endpoint == "" else "https · lan", url, CMD_COPY),
                      LabeledValue("API key", "$MXC_API_KEY", "manage keys", KEYS),
                      CodePanel(curl_for(url, m.name), on_copy=COPY_CURL, copies=copies, copied=copies > 0),
                      PanelFoot("mxc keys new <app>")])
    var power = ("mxc stop " if m.state == "ready" or m.state == "starting" else "mxc serve ") + m.name
    var twins = CommandLines([power, "mxc rm " + m.name])
    return PanelGrid([PanelRow([right_now^, tokens^], compact=phone), PanelRow([about^, gpu^], compact=phone), call^, twins^], compact=phone)
