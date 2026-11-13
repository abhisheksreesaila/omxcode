# mojoui.fleet: a folder of ROS 2 bags as a fleet in one sheet (goal 68 M4). Every bag (mojoui.bag: a rosbag2 folder,
# an .mcap or a .db3) is a run; the fleet is three tables and a story:
#   runs     one row per run: run, robot, duration_s, distance_m, stops, stopped_s, topics, cameras, messages, start_s
#   moments  every run at 10 Hz, every topic joined on time (each topic's last message at or before the moment):
#            run, robot, time_s (the bag's clock), t (seconds into the run), speed, turn_rate, x, y, moved_m, person_m,
#            then each topic's number fields as <topic>.<field> (empty where a run lacks that topic)
#   stops    one row per half-second a robot stood still (speed under 0.05 m/s): run, robot, t, stopped_for, moved_m,
#            person_m, turn_rate, time_s — the rows a person labels to teach Learn (mojoui.learn) why robots stop
#   story.json  the starter (mojoui.starter) that opens them: the runs as the sheet, a few questions in SQL
#
#   var f = read_fleet("~/bags", ctl)            # ctl: a JobCtl (progress: one step a bag)
#   f.write("~/bags/fleet")                     # runs.csv, moments.csv, stops.csv, story.json
#   f.runs[k].cameras                           # its camera topics; camera_video(Bag.open(f.runs[k].path), …) makes each a video
#
# Where the numbers come from (in order, the first a run has): speed and turn_rate from nav_msgs/Odometry's twist, else
# a geometry_msgs/Twist command (cmd_vel); x, y from Odometry's pose, else a JSON telemetry topic's robot_x/robot_y,
# else a PoseWithCovarianceStamped; person_m is the nearest of a JSON topic's participant<N>_x/_y to the robot (empty
# when a run has none). A run's robot is its folder's name up to the first "_" (r2b_galileo → r2b): name folders
# robot_run to say which robot it was. TF, camera calibration and picture topics aren't joined (cameras are videos).

from std.math import sqrt, isnan
from std.os import listdir, makedirs
from std.os.path import isdir, exists
from omxcore import Table, SharedTable, JobCtl, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, INT as MX_INT
from mojoui.bag import Bag, BagTable, BAG_INT, BAG_FLOAT, BAG_TEXT
from mojoui.sheet import Sheet
from mojoui.json import json_string

comptime HZ = 10  # moments a second
comptime STILL = 0.05  # m/s: under this a robot stands still
comptime STOP_ROWS = 5  # a stop row: this many moments (half a second) standing still


struct Run(Copyable, Movable):
    var name: String
    var robot: String
    var path: String
    var start_ns: Int
    var end_ns: Int
    var distance: Float64
    var stops: Int  # stretches of standing still at least half a second long
    var stopped_s: Float64
    var topics: Int
    var cameras: List[String]
    var messages: Int
    var note: String  # what wasn't read (protobuf topics…)

    def __init__(out self, name: String, path: String):
        self.name = name
        var cut = name.find("_")
        self.robot = String(name[byte=:cut]) if cut > 0 else name
        self.path = path
        self.start_ns = 0
        self.end_ns = 0
        self.distance = 0.0
        self.stops = 0
        self.stopped_s = 0.0
        self.topics = 0
        self.cameras = List[String]()
        self.messages = 0
        self.note = ""


@fieldwise_init
struct _Col(Copyable, Movable):
    var name: String  # <topic>.<field>
    var table: Int  # which of the run's tables
    var col: Int  # its column there


def _short(topic: String) -> String:
    """/chassis/odom → chassis_odom (a column's prefix)."""
    var t = String(topic.lstrip("/"))
    return t.replace("/", "_")


def _keep_field(name: String) -> Bool:
    if name == "t_ns" or "covariance" in name or name.startswith("header.") or ".header." in name or name == "item":
        return False
    return True


def _is_joined(tp_type: String, name: String) -> Bool:
    """The topics joined into moments: not pictures, calibration or TF (their own tables / videos)."""
    if "CompressedImage" in tp_type or tp_type.endswith("/Image") or "CameraInfo" in tp_type or "TFMessage" in tp_type or "PointCloud2" in tp_type:
        return False
    return True


struct Fleet(Movable):
    var folder: String
    var runs: List[Run]
    var runs_table: SharedTable
    var moments: SharedTable
    var stops: SharedTable
    var problems: List[String]

    def __init__(out self, folder: String):
        self.folder = folder
        self.runs = List[Run]()
        self.runs_table = Table.empty().share()
        self.moments = Table.empty().share()
        self.stops = Table.empty().share()
        self.problems = List[String]()

    def write(self, dest: String, videos: List[String] = List[String](), firsts: List[Float64] = List[Float64]()) raises:
        """runs.csv, moments.csv, stops.csv and story.json in dest (made if missing); videos: the hero run's cameras
        (paths relative to dest), each linked by time to the moments (firsts: its first picture's time_s)."""
        makedirs(dest, exist_ok=True)
        Sheet(self.runs_table, False).write_csv(dest + "/runs.csv")
        Sheet(self.moments, False).write_csv(dest + "/moments.csv")
        Sheet(self.stops, False).write_csv(dest + "/stops.csv")
        with open(dest + "/story.json", "w") as f:
            f.write(self.story(videos, firsts))

    def hero(self) -> String:
        """The run the story opens on: the first with a camera and people's places, else the first with a camera."""
        var first = String("")
        for r in self.runs:
            if len(r.cameras) > 0 and first == "":
                first = r.name
        return first if first != "" else (self.runs[0].name if len(self.runs) > 0 else "")

    def story(self, videos: List[String] = List[String](), firsts: List[Float64] = List[Float64]()) -> String:
        var names = List[String]()
        for r in self.runs:
            names.append(r.name)
        var q = List[Tuple[String, String, String]]()
        q.append(("stood_still", "Which runs stood still the longest, and how often did they stop?",
                  "SELECT run, robot, stopped_s, stops, duration_s FROM runs ORDER BY stopped_s DESC"))
        q.append(("person_near", "When was a person within 1.5 m of the robot?",
                  "SELECT run, robot, t, person_m, speed FROM moments WHERE person_m < 1.5 ORDER BY person_m"))
        q.append(("speed_by_robot", "How fast does each robot go when it moves?",
                  "SELECT robot, COUNT(*) AS moments, AVG(speed) AS speed FROM moments WHERE speed > 0.05 GROUP BY robot ORDER BY speed DESC"))
        q.append(("stops_by_run", "Where are the stops?", "SELECT run, COUNT(*) AS half_seconds, MIN(person_m) AS nearest_person FROM stops GROUP BY run ORDER BY half_seconds DESC"))
        var s = String("{\n  \"title\": ") + json_string("A fleet of " + String(len(self.runs)) + " robot runs") + ",\n"
        s += "  \"start\": \"Open the fleet\",\n"
        s += "  \"lead\": " + json_string("Every bag in " + self.folder + " as a run: the runs, every topic joined on time (moments), and the half-seconds each robot stood still (stops). Label 20 stops and Learn names the cause of the rest.") + ",\n"
        s += "  \"credit\": " + json_string("Runs: " + ", ".join(names) + ". Read by mojoui.bag (no ROS).") + ",\n"
        s += "  \"license\": \"as the bags' own (see ATTRIBUTION.txt beside them)\",\n  \"source\": " + json_string(self.folder) + ",\n"
        s += "  \"hero\": " + json_string(self.hero()) + ",\n"
        s += "  \"sheet\": \"runs.csv\",\n  \"tables\": [\"moments.csv\", \"stops.csv\"],\n"
        var links = String("\"runs.run = moments.run\", \"runs.run = stops.run\"")
        var vids = String("")
        for i in range(len(videos)):
            var file = String(videos[i][byte = videos[i].rfind("/") + 1 :])
            vids += ("," if i > 0 else "") + json_string(videos[i])
            # (one cursor: a moment's time_s on the bag's clock, the video's t from its first picture)
            links += ", " + json_string("moments.time_s ~ " + file + ".t " + String(-firsts[i]))
        s += "  \"videos\": [" + vids + "],\n"
        s += "  \"links\": [" + links + "],\n"
        s += "  \"questions\": [\n"
        for i in range(len(q)):
            s += "    {\"name\": " + json_string(q[i][0]) + ", \"question\": " + json_string(q[i][1]) + ", \"sql\": " + json_string(q[i][2]) + "}" + ("," if i < len(q) - 1 else "") + "\n"
        s += "  ]\n}\n"
        return s


def bag_folders(folder: String) -> List[String]:
    """The bags in folder: its subfolders holding an .mcap or .db3, and its own .mcap / .db3 files, by name."""
    var out = List[String]()
    var names = List[String]()
    try:
        for n in listdir(folder):
            names.append(String(n))
    except:
        return out^
    sort(names)
    for n in names:
        var p = String(folder.rstrip("/")) + "/" + n
        if isdir(p):
            try:
                for m in listdir(p):
                    var s = String(m)
                    if s.endswith(".mcap") or s.endswith(".db3"):
                        out.append(p)
                        break
            except:
                pass
        elif n.endswith(".mcap") or n.endswith(".db3"):
            out.append(p)
    return out^


struct _RunData(Movable):
    var run: Run
    var tables: List[BagTable]
    var cols: List[_Col]
    var times: List[Int]  # the moments' clock (ns)
    var speed: List[Float64]
    var turn: List[Float64]
    var x: List[Float64]
    var y: List[Float64]
    var moved: List[Float64]
    var person: List[Float64]

    def __init__(out self, var run: Run):
        self.run = run^
        self.tables = List[BagTable]()
        self.cols = List[_Col]()
        self.times = List[Int]()
        self.speed = List[Float64]()
        self.turn = List[Float64]()
        self.x = List[Float64]()
        self.y = List[Float64]()
        self.moved = List[Float64]()
        self.person = List[Float64]()


def _nan() -> Float64:
    return Float64(0) / Float64(0)


def _asof(t: BagTable, c: Int, times: List[Int]) -> List[Float64]:
    """Column c's value at each time: its last row at or before it (NaN before the first)."""
    var out = List[Float64](capacity=len(times))
    var ts = t.ints[t.slot[0]].copy()
    var k = -1
    for tm in times:
        while k + 1 < t.rows and Int(ts[k + 1]) <= tm:
            k += 1
        out.append(t.float_at(c, k) if k >= 0 else _nan())
    return out^


def _read_run(path: String) raises -> _RunData:
    var whole = String(path.rstrip("/"))
    var base = String(whole[byte = whole.rfind("/") + 1 :])
    var name = base
    if base.endswith(".mcap"):
        name = String(base[byte = : base.byte_length() - 5])
    elif base.endswith(".db3"):
        name = String(base[byte = : base.byte_length() - 4])
    var bag = Bag.open(path)
    var run = Run(name, path)
    run.start_ns = bag.start_ns
    run.end_ns = bag.end_ns
    run.topics = len(bag.topics)
    var want = List[Int]()
    var notes = List[String]()
    for k in range(len(bag.topics)):
        run.messages += bag.topics[k].count
        if bag.topics[k].is_camera():
            run.cameras.append(bag.topics[k].name)
        elif _is_joined(bag.topics[k].type, bag.topics[k].name):
            if bag.topics[k].encoding == "cdr" or bag.topics[k].encoding == "json":
                want.append(k)
            else:
                notes.append(bag.topics[k].name + " (" + bag.topics[k].encoding + ")")
    if len(notes) > 0:
        run.note = "not read: " + ", ".join(notes)
    var d = _RunData(run^)
    d.tables = bag.tables(want)
    var step = 1_000_000_000 // HZ
    var t = bag.start_ns
    while t <= bag.end_ns:
        d.times.append(t)
        t += step
    var n = len(d.times)
    # (the motion: Odometry, else a Twist command; the place: Odometry, else telemetry JSON, else an AMCL pose)
    var have_speed = False
    var have_xy = False
    for i in range(len(d.tables)):
        ref tb = d.tables[i]
        var vx = tb.index("twist.twist.linear.x")
        if vx > 0 and not have_speed:
            d.speed = _asof(tb, vx, d.times)
            d.turn = _asof(tb, tb.index("twist.twist.angular.z"), d.times)
            have_speed = True
        var px = tb.index("pose.pose.position.x")
        if px > 0 and not have_xy and "Odometry" in tb.type:
            d.x = _asof(tb, px, d.times)
            d.y = _asof(tb, tb.index("pose.pose.position.y"), d.times)
            have_xy = True
    for i in range(len(d.tables)):
        ref tb = d.tables[i]
        if not have_speed and tb.index("linear.x") > 0 and "Twist" in tb.type:
            d.speed = _asof(tb, tb.index("linear.x"), d.times)
            d.turn = _asof(tb, tb.index("angular.z"), d.times)
            have_speed = True
        if not have_xy and tb.index("robot_x") > 0:
            d.x = _asof(tb, tb.index("robot_x"), d.times)
            d.y = _asof(tb, tb.index("robot_y"), d.times)
            have_xy = True
    for i in range(len(d.tables)):
        ref tb = d.tables[i]
        if not have_xy and tb.index("pose.pose.position.x") > 0:
            d.x = _asof(tb, tb.index("pose.pose.position.x"), d.times)
            d.y = _asof(tb, tb.index("pose.pose.position.y"), d.times)
            have_xy = True
    if not have_speed:
        d.speed = List[Float64](length=n, fill=_nan())
        d.turn = List[Float64](length=n, fill=_nan())
    if not have_xy:
        d.x = List[Float64](length=n, fill=_nan())
        d.y = List[Float64](length=n, fill=_nan())
    for i in range(n):
        d.speed[i] = abs(d.speed[i])
    # (the nearest person: a JSON topic's participant<N>_x/_y)
    d.person = List[Float64](length=n, fill=_nan())
    for i in range(len(d.tables)):
        ref tb = d.tables[i]
        var k = 1
        while tb.index("participant" + String(k) + "_x") > 0:
            var px = _asof(tb, tb.index("participant" + String(k) + "_x"), d.times)
            var py = _asof(tb, tb.index("participant" + String(k) + "_y"), d.times)
            for j in range(n):
                var dist = sqrt((px[j] - d.x[j]) * (px[j] - d.x[j]) + (py[j] - d.y[j]) * (py[j] - d.y[j]))
                if not isnan(dist) and (isnan(d.person[j]) or dist < d.person[j]):
                    d.person[j] = dist
            k += 1
    # (distance: the sum of the steps between moments where the place is known)
    var moved = 0.0
    for j in range(n):
        if j > 0 and not isnan(d.x[j]) and not isnan(d.x[j - 1]):
            moved += sqrt((d.x[j] - d.x[j - 1]) * (d.x[j] - d.x[j - 1]) + (d.y[j] - d.y[j - 1]) * (d.y[j] - d.y[j - 1]))
        d.moved.append(moved)
    d.run.distance = moved
    # (stops: stretches of standing still at least STOP_ROWS moments long)
    var still = 0
    for j in range(n):
        if not isnan(d.speed[j]) and d.speed[j] < STILL:
            still += 1
            if still == STOP_ROWS:
                d.run.stops += 1
            d.run.stopped_s += 1.0 / Float64(HZ)
        else:
            still = 0
    # (every other number field, as <topic>.<field>)
    for i in range(len(d.tables)):
        ref tb = d.tables[i]
        for c in range(1, tb.columns()):
            if tb.kinds[c] != BAG_TEXT and _keep_field(tb.names[c]):
                d.cols.append(_Col(_short(tb.topic) + "." + tb.names[c], i, c))
    return d^


def _dec(v: Float64, places: Int) -> Int64:
    var p = 1.0
    for _ in range(places):
        p *= 10.0
    return Int64(Int(v * p + (0.5 if v >= 0 else -0.5)))


def _put(mut t: Table, c: Int, v: Float64, places: Int) raises:
    if isnan(v) or v > 9e12 or v < -9e12:
        t.append_null(c)
    else:
        t.append(c, _dec(v, places))


def read_fleet(folder: String, ctl: JobCtl = JobCtl()) raises -> Fleet:
    """Every bag in folder, read and joined (see the header). A bag that doesn't read is skipped and said in problems."""
    var paths = bag_folders(folder)
    if len(paths) == 0:
        raise Error(folder + " holds no ROS 2 bags (folders with an .mcap or .db3 file, or such files)")
    var f = Fleet(String(folder.rstrip("/")))
    ctl.add_total(len(paths))
    var data = List[_RunData]()
    for p in paths:
        try:
            data.append(_read_run(p))
        except e:
            f.problems.append(p + ": " + String(e))
        ctl.advance(1)
    if len(data) == 0:
        raise Error("no bag in " + folder + " could be read: " + "; ".join(f.problems))
    # (the union of the runs' topic fields, in first-seen order)
    var names = List[String]()
    for di in range(len(data)):
        for c in data[di].cols:
            if not (c.name in names):
                names.append(c.name)
    # runs
    var rt = Table.empty()
    var r_run = rt.add_column("run", MX_TEXT)
    var r_robot = rt.add_column("robot", MX_TEXT)
    var r_dur = rt.add_column("duration_s", MX_DECIMAL, 1)
    var r_dist = rt.add_column("distance_m", MX_DECIMAL, 2)
    var r_stops = rt.add_column("stops", MX_INT)
    var r_still = rt.add_column("stopped_s", MX_DECIMAL, 1)
    var r_topics = rt.add_column("topics", MX_INT)
    var r_cams = rt.add_column("cameras", MX_INT)
    var r_msgs = rt.add_column("messages", MX_INT)
    var r_start = rt.add_column("start_s", MX_DECIMAL, 3)
    for di in range(len(data)):
        ref d = data[di]
        rt.append_text(r_robot, d.run.robot)
        rt.append_text(r_run, d.run.name)
        rt.append(r_dur, _dec(Float64(d.run.end_ns - d.run.start_ns) / 1e9, 1))
        rt.append(r_dist, _dec(d.run.distance, 2))
        rt.append(r_stops, Int64(d.run.stops))
        rt.append(r_still, _dec(d.run.stopped_s, 1))
        rt.append(r_topics, Int64(d.run.topics))
        rt.append(r_cams, Int64(len(d.run.cameras)))
        rt.append(r_msgs, Int64(d.run.messages))
        rt.append(r_start, _dec(Float64(d.run.start_ns) / 1e9, 3))
    rt.check()
    # moments
    var mt = Table.empty()
    var m_run = mt.add_column("run", MX_TEXT)
    var m_robot = mt.add_column("robot", MX_TEXT)
    var m_time = mt.add_column("time_s", MX_DECIMAL, 3)
    var m_t = mt.add_column("t", MX_DECIMAL, 1)
    var m_speed = mt.add_column("speed", MX_DECIMAL, 3)
    var m_turn = mt.add_column("turn_rate", MX_DECIMAL, 3)
    var m_x = mt.add_column("x", MX_DECIMAL, 3)
    var m_y = mt.add_column("y", MX_DECIMAL, 3)
    var m_moved = mt.add_column("moved_m", MX_DECIMAL, 2)
    var m_person = mt.add_column("person_m", MX_DECIMAL, 2)
    var m_cols = List[Int]()
    for n in names:
        m_cols.append(mt.add_column(n, MX_DECIMAL, 4))
    # stops
    var st = Table.empty()
    var s_run = st.add_column("run", MX_TEXT)
    var s_robot = st.add_column("robot", MX_TEXT)
    var s_t = st.add_column("t", MX_DECIMAL, 1)
    var s_for = st.add_column("stopped_for", MX_DECIMAL, 1)
    var s_moved = st.add_column("moved_m", MX_DECIMAL, 2)
    var s_person = st.add_column("person_m", MX_DECIMAL, 2)
    var s_turn = st.add_column("turn_rate", MX_DECIMAL, 3)
    var s_time = st.add_column("time_s", MX_DECIMAL, 3)
    for di in range(len(data)):
        ref d = data[di]
        var n = len(d.times)
        var vals = List[List[Float64]]()
        var where = List[Int]()  # names index → this run's value list (-1: it lacks it)
        for name in names:
            var found = -1
            for ci in range(len(d.cols)):
                if d.cols[ci].name == name:
                    found = len(vals)
                    vals.append(_asof(d.tables[d.cols[ci].table], d.cols[ci].col, d.times))
            where.append(found)
        var still = 0
        for j in range(n):
            mt.append_text(m_run, d.run.name)
            mt.append_text(m_robot, d.run.robot)
            mt.append(m_time, _dec(Float64(d.times[j]) / 1e9, 3))
            mt.append(m_t, _dec(Float64(d.times[j] - d.run.start_ns) / 1e9, 1))
            _put(mt, m_speed, d.speed[j], 3)
            _put(mt, m_turn, d.turn[j], 3)
            _put(mt, m_x, d.x[j], 3)
            _put(mt, m_y, d.y[j], 3)
            _put(mt, m_moved, d.moved[j], 2)
            _put(mt, m_person, d.person[j], 2)
            for k in range(len(names)):
                if where[k] < 0:
                    mt.append_null(m_cols[k])
                else:
                    _put(mt, m_cols[k], vals[where[k]][j], 4)
            if not isnan(d.speed[j]) and d.speed[j] < STILL:
                still += 1
                if still % STOP_ROWS == 0:  # (a half-second of standing still: a stop row, at its first moment)
                    var j0 = j - STOP_ROWS + 1
                    var near = _nan()
                    var turn = 0.0
                    for q in range(j0, j + 1):
                        if not isnan(d.person[q]) and (isnan(near) or d.person[q] < near):
                            near = d.person[q]
                        turn += abs(d.turn[q]) if not isnan(d.turn[q]) else 0.0
                    st.append_text(s_run, d.run.name)
                    st.append_text(s_robot, d.run.robot)
                    st.append(s_t, _dec(Float64(d.times[j0] - d.run.start_ns) / 1e9, 1))
                    st.append(s_for, _dec(Float64(still - STOP_ROWS) / Float64(HZ), 1))
                    _put(st, s_moved, d.moved[j0], 2)
                    _put(st, s_person, near, 2)
                    st.append(s_turn, _dec(turn / Float64(STOP_ROWS), 3))
                    st.append(s_time, _dec(Float64(d.times[j0]) / 1e9, 3))
            else:
                still = 0
        f.runs.append(d.run.copy())
    mt.check()
    st.check()
    f.runs_table = rt^.share()
    f.moments = mt^.share()
    f.stops = st^.share()
    return f^
