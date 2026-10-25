# The model page (model-page.js): one page per model at #/models/<name>/<tab>. A header with the tabs and the model's
# verbs; below it the tab. Overview is here: Right now (four tiles), Tokens (the last 5 minutes), About, GPU fit, Call it.

from mojoui.view import View, Text, Button, Icon, VStack, HStack, Spacer, Divider, Canvas, SUBTLE, PLAIN, ICON_ONLY, CENTER, START, END
from mojoui.chip import Chip, Badge
from mojoui.codeblock import CodeBlock
from mojoui.sparkline import SparklineView
from mojoui.pagekit import TabStrip, FlatButton, Panel, PanelTitle, StatTile, Fact, FactText, SourceLine, StateWord, MonoLine, QuietText
from data import Store, Model, row_of, hardware, fmt, dur, rounded, round1, strip_arch
from msgs import TAB, CMD_STOP, CMD_RESTART, CMD_COPY, CMD_REMOVE, CMD_START, COPY_CURL, REMOVE_LABEL, KEYS, SPARK, FIT

comptime TAB_KEYS: List[String] = ["overview", "benchmark", "logs", "notebook"]
comptime TAB_TITLES: List[String] = ["Overview", "Benchmark", "Logs", "Notebook"]
comptime TAB_ICONS: List[String] = ["box", "gauge", "scroll-text", "book-open"]


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
        cmds.append(FlatButton("Stop", CMD_STOP, "square", filled=True))
        cmds.append(FlatButton("Restart", CMD_RESTART, "rotate-cw"))
    elif m.state == "starting":
        cmds.append(FlatButton("Stop", CMD_STOP, "square", filled=True))
    elif m.state == "crashed":
        cmds.append(FlatButton("Restart", CMD_RESTART, "rotate-cw", filled=True))
    else:
        cmds.append(FlatButton("Start", CMD_START, "play", filled=True))
    cmds.append(FlatButton("Copy endpoint", CMD_COPY, "copy"))
    cmds.append(FlatButton("Remove", CMD_REMOVE, "trash-2", danger=True))
    var tabs = TabStrip(materialize[TAB_TITLES](), materialize[TAB_ICONS](), tab_index(tab), TAB)
    if phone:
        return VStack(tabs^.fill(), HStack(cmds^, spacing=6).fill(), spacing=8).align(START).padding(10, 10).fill()
    var items: List[View] = [tabs^, Spacer()]
    items.append(HStack(cmds^, spacing=6).align(CENTER))
    return HStack(items^, spacing=10).align(CENTER).padding(12, 18).fill().tag("mhead")


def overview_view(st: Store, m: Model, phone: Bool, copies: Int) -> View:
    var r = row_of(st, m)
    var fit = fit_of(st, m.name)
    var url = st.lan_endpoint if st.lan_endpoint != "" else st.endpoint_now()
    # Right now: the same four tiles, always in this order (metricsView)
    var req = r.requests_value if r.requests_value >= 0 else 0
    var tiles = VStack(
        HStack(StatTile("Requests", fmt(Float64(req)), "", "last 5 minutes"), StatTile("Speed", fmt(r.tps_value) if r.tps_value >= 0 else String("—"),
               "tok/s" if r.tps_value >= 0 else String(""), "decode, median"), spacing=10).fill(),
        HStack(StatTile("Latency p50", fmt(r.ttft_value) if r.ttft_value >= 0 else String("—"), "ms" if r.ttft_value >= 0 else String(""), "time to first token"),
               StatTile("Memory", fmt(fit.this_gb, 1) if fit.this_gb > 0 else String("—"), "GB" if fit.this_gb > 0 else String(""), "GPU, this model"), spacing=10).fill(),
        spacing=10).fill()
    var right_now = Panel([PanelTitle("gauge", "Right now"), tiles^, SourceLine("mxc status")]).fill()
    var tokens = Panel([PanelTitle("scroll-text", "Tokens"), SparklineView(SPARK, len(st.points(m.name)) * 1000 + Int(r.tps_value)), SourceLine("mxc metrics --json")]).fill()
    # About
    var unload = "never (pinned)" if m.pinned else (("after " + dur(m.keep_alive) + " idle") if m.keep_alive > 0 else String("—"))
    var vram = String("—")
    if fit.this_gb > 0:
        vram = fmt(fit.this_gb, 1) + " GB" + ((" · " + String(Int(rounded(fit.this_gb / fit.total_gb * 100, 0))) + "% of " + fmt(fit.total_gb, 1) + " GB") if fit.total_gb > 0 else String(""))
    var state_text = r.state_label + ((" · " + r.note) if r.note != "" else String(""))
    var labels: List[View] = []
    for k in range(len(m.labels)):
        labels.append(HStack(Text("#" + m.labels[k]).tag("chip"), Button("Remove label " + m.labels[k], REMOVE_LABEL + k, ICON_ONLY, icon="x"), spacing=0).align(CENTER))
    labels.append(Chip("+label"))
    var about = Panel([PanelTitle("box", "About"),
                       Fact("Repository", FactText(r.repo if r.repo != "" else String("—"))),
                       Fact("Architecture", FactText(r.arch)),
                       Fact("Source", FactText(m.source if m.source != "" else String("—"))),
                       Fact("Unloads", FactText(unload)),
                       Fact("Endpoint", FactText(url)),
                       Fact("Reachable", HStack(FactText("LAN · HTTPS · " if st.lan_endpoint != "" else "This machine only · "), FactText("Security ›"), spacing=0)),
                       Fact("GPU memory", FactText(vram)),
                       Fact("State", StateWord(state_text, r.running)),
                       Fact("Labels", HStack(labels^, spacing=4).align(CENTER)),
                       SourceLine("mxc ls --json")]).fill()
    var fit_caps = HStack(MonoLine("this " + fmt(fit.this_gb, 1) + " GB" if fit.present else "no GPU found"), Spacer(),
                          MonoLine(("others " + fmt(fit.others_gb, 1) + " GB") if fit.present else ""), Spacer(),
                          MonoLine(("free " + fmt(fit.free_gb, 1) + " GB of " + fmt(fit.total_gb, 1) + " GB") if fit.present else ""), spacing=8).fill()
    var gpu = Panel([PanelTitle("gauge", "GPU fit"), Canvas(FIT, Int(fit.this_gb * 10) + Int(fit.total_gb * 1000)).height(10).fill().tag("gpu-fit"), fit_caps^]).fill()
    var call = Panel([PanelTitle("terminal", "Call it"),
                      HStack(Badge("local" if st.lan_endpoint == "" else "https · lan"), MonoLine(url), Spacer(), spacing=10).align(CENTER).fill(),
                      HStack(QuietText("API key"), MonoLine("$MXC_API_KEY"), Button("manage keys", KEYS, SUBTLE), spacing=8).align(CENTER),
                      CodeBlock(curl_for(url, m.name), on_copy=COPY_CURL, copies=copies, copied=copies > 0).fill(),
                      SourceLine("mxc keys new <app>")]).fill()
    var power = ("mxc stop " if m.state == "ready" or m.state == "starting" else "mxc serve ") + m.name
    var twins = VStack(SourceLine(power), SourceLine("mxc rm " + m.name), spacing=3).align(START)
    if phone:
        return VStack(right_now, tokens, about, gpu, call, twins, spacing=10).align(START).padding(10, 10).fill()
    return VStack(HStack(right_now^.grow(), tokens^.grow(), spacing=14).align(START).fill(),
                  HStack(about^.grow(), gpu^.grow(), spacing=14).align(START).fill(), call, twins, spacing=14).align(START).padding(16, 18).fill()
