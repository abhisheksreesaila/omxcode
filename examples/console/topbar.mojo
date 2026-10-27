# The top bar on every page (topbar.js, nav.js, beacon.js): the brand (home), the breadcrumb trail, the Beacon (the one
# thing happening now), the four places. On a phone the brand's word, the earlier crumbs and the places' words fold
# away (the places into ⋯).

from mojoui.view import View, Text, Button, Icon, HStack, VStack, Spacer, SUBTLE, ICON_ONLY, CENTER, START
from mojoui.breadcrumbs import Breadcrumbs
from places import Place, crumbs_for
from mojoui.shell import AppBar, Brand, BarRule, NavLink, NavLinks, NavMore
from mojoui.beacon import Beacon
from data import Store, hardware
from msgs import HOME, CRUMB, PLACE, MORE, RING
from mojoui.numformat import rounded, en_number

comptime PLACE_KEYS: List[String] = ["keys", "gateway", "security", "settings"]
comptime PLACE_TITLES: List[String] = ["Keys", "Gateway", "Security", "Settings"]
comptime PLACE_ICONS: List[String] = ["key-round", "route", "lock", "sliders-horizontal"]
comptime PLACE_HUES: List[Int] = [3, 2, 8, 0]  # (nav.js: data-3, data-2, warn, ink-2)


@fieldwise_init
struct BeaconState(Copyable, Movable):
    var kind: String  # pull, port, crash, starting, running, idle, nogpu, offline, loading
    var label: String
    var value: String
    var percent: Float64  # the ring (-1: unknown)


def beacon_state(st: Store) -> BeaconState:
    """beacon.js beaconState: a pull or port in progress > a crashed model > starting > running (live tok/s) > GPU idle."""
    if st.pull_name != "":
        return BeaconState("pull", "Pulling " + st.pull_name, ("…" if st.pull_percent < 0 else String(Int(rounded(st.pull_percent, 0))) + "%"), st.pull_percent)
    if st.port_name != "":
        return BeaconState("port", "Porting " + st.port_name, st.port_step, -1)
    for m in st.models:
        if m.state == "crashed":
            return BeaconState("crash", m.name + " crashed", "", -1)
    for m in st.models:
        if m.state == "starting":
            return BeaconState("starting", "Starting " + m.name, "", -1)
    var running = 0
    var tps = 0
    for m in st.models:
        if m.state == "ready":
            running += 1
            var pts = st.points(m.name)
            tps += Int(rounded(pts[len(pts) - 1], 0)) if len(pts) > 0 else 0
    if running > 0:
        return BeaconState("running", String(running) + " running", String(tps) + " tok/s", -1)
    if st.error != "":
        return BeaconState("offline", "daemon offline", "", -1)
    var hw = hardware(st)
    if not st.loaded:
        return BeaconState("loading", "…", "", -1)
    if not hw.present:
        return BeaconState("nogpu", "No GPU", "", -1)
    return BeaconState("idle", hw.short, en_number(hw.used_gb, 1) + "/" + en_number(hw.total_gb, 1) + " GB", -1)


def top_bar(place: Place, st: Store, phone: Bool) -> View:
    var items: List[View] = [Brand("omx", "" if phone else "omxconsole", HOME)]
    var crumbs = crumbs_for(place)
    items.append(BarRule(compact=phone))
    if phone:
        items.append(Breadcrumbs(crumbs, on_tap=CRUMB, mono_last=place.page == "model", compact=True).grow())
    else:
        items.append(Breadcrumbs(crumbs, on_tap=CRUMB, mono_last=place.page == "model"))
        items.append(Spacer())
    var b = beacon_state(st)
    var pct = b.percent
    var ring = RING if b.kind == "pull" or b.kind == "port" else -1
    items.append(Beacon(b.label, "" if phone else b.value, ring, Int(pct * 10) if pct >= 0 else 0, live=b.kind == "running" or b.kind == "crash", compact=phone))
    if phone:
        items.append(NavMore("Keys, Gateway, Security, Settings", MORE))
    else:
        var links: List[View] = []
        var keys = materialize[PLACE_KEYS]()
        for k in range(4):
            links.append(NavLink(materialize[PLACE_TITLES]()[k], materialize[PLACE_ICONS]()[k], PLACE + k, here=place.page == keys[k], hue=materialize[PLACE_HUES]()[k]))
        items.append(NavLinks(links^))
    return AppBar(items^, compact=phone)
