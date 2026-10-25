# The console's messages: one range per screen, so a new screen (M6: Add, Keys, Gateway, Security, Settings) takes a
# range of its own here and a file of its own, and app.mojo hands it its messages.

# the shell (app.mojo, topbar.mojo)
comptime ROUTE = 1
comptime POLL_CORE = 2  # core.js: every 3 s
comptime POLL_SYSTEM = 3  # system-data.js: every 5 s
comptime POLL_JOBS = 4  # beacon.js: every 3 s
comptime POLL_BENCH = 5  # blade-bench.js: every 5 s idle, 1 s while running
comptime POLL_LOG = 6  # blade-logs.js: every 2 s
comptime DISARM = 7  # a tap-twice button gives up waiting
comptime GOT_MODELS = 10
comptime GOT_METRICS = 11
comptime GOT_SERIES = 12
comptime GOT_REQUESTS = 13
comptime GOT_INFO = 14
comptime GOT_SYSTEM = 15
comptime GOT_PULLS = 16
comptime GOT_PORTS = 17
comptime GOT_LABELS = 18
comptime GOT_WRITE = 19  # a write's reply: poll again
comptime GOT_BENCH = 20
comptime GOT_HISTORY = 21
comptime GOT_LOG = 22
comptime GOT_LEARN = 23
comptime GOT_OPEN = 24
comptime HOME = 30
comptime CRUMB = 31  # + the crumb's place in the trail
comptime PLACE = 35  # + 0 keys, 1 gateway, 2 security, 3 settings
comptime MORE = 39
# My models (home.mojo)
comptime ADD = 40
comptime SEARCH = 41
comptime VIEW = 42  # + 0 list, 1 cards
comptime GROUP = 50  # + 0 all, 1 running, 2… the kinds
comptime LABEL_GROUP = 60  # + the label's index
comptime DROP_LABEL = 100  # + the label's index
comptime TICK = 140  # + the row
comptime TICK_ALL = 200
comptime OPEN = 210  # + the row
comptime TAP_LABEL = 260  # + the label's index (the tick bar)
comptime CLEAR = 300
comptime REMOVE_TICKED = 301
comptime EDIT_LABELS = 302
# the model page (modelpage.mojo)
comptime TAB = 310  # + 0 overview, 1 benchmark, 2 logs, 3 notebook
comptime CMD_STOP = 320
comptime CMD_RESTART = 321
comptime CMD_COPY = 322
comptime CMD_REMOVE = 323
comptime CMD_START = 324
comptime COPY_CURL = 326
comptime REMOVE_LABEL = 330  # + the label's index on this model
comptime KEYS = 351
# Benchmark (bench.mojo)
comptime BENCH_RUN = 360
comptime BENCH_ALL = 361
comptime HIST = 362  # + the run's place in the history
# Logs (logs.mojo)
comptime LOG_FOLLOW = 380
comptime LOG_COPY = 381
comptime LOG_FILTER = 382
# Notebook (notebook.mojo)
comptime NB_RUN = 390
comptime NB_CHAPTER = 400  # + the chapter
comptime NB_COPY = 450

# canvases
comptime RING = 0  # the Beacon's ring
comptime SPARK = 1  # Overview's Tokens chart
comptime FIT = 2  # Overview's GPU fit bar
comptime BAR = 10  # + the bar (Benchmark)
