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

# Keys (keys.mojo): 6000–6199
comptime KEYS_FIRST = 6000
comptime KEYS_NEW = 6000  # the header's New key (opens or closes the form)
comptime KEYS_NAME = 6001  # the form's App name field
comptime KEYS_CREATE = 6002
comptime KEYS_CANCEL = 6003
comptime KEYS_DONE = 6004  # the shown key's ×
comptime KEYS_COPY = 6005  # Copy the shown key
comptime KEYS_POLL = 6006  # "last used" moves while you look: read again every 12 s
comptime KEYS_DISARM = 6007  # a tap-twice button gives up waiting (4 s)
comptime KEYS_ROTATE = 6010  # + the row
comptime KEYS_REVOKE = 6100  # + the row
comptime KEYS_GOT_LIST = 6190
comptime KEYS_GOT_NEW = 6191
comptime KEYS_GOT_ROTATE = 6192
comptime KEYS_GOT_REVOKE = 6193
comptime KEYS_LAST = 6199
# Gateway (gateway.mojo): 6200–6399
comptime GW_FIRST = 6200
comptime GW_POLL = 6200  # blade-gateway.js: every 4 s
comptime GW_RESTART = 6201
comptime GW_COPY = 6210  # + the source line (mxc status, mxc requests --limit 200, mxc console api, mxc expose, mxc expose --stop)
comptime GW_DOCS = 6220  # Open the API reference
comptime GW_ADD = 6221  # (no routes yet) Add a model
comptime GW_GOT_NETWORK = 6390
comptime GW_GOT_GATEWAY = 6391
comptime GW_GOT_LOG = 6392
comptime GW_GOT_RESTART = 6393
comptime GW_LAST = 6399
# Security (security.mojo): 6400–6599
comptime SEC_FIRST = 6400
comptime SEC_SECURE = 6400  # Make it secure / Try again
comptime SEC_STOP = 6401  # Stop exposing (tap twice)
comptime SEC_KEYS = 6402  # Manage API keys
comptime SEC_COPY_URL = 6403
comptime SEC_COPY_CA = 6404
comptime SEC_COPY_CURL = 6405
comptime SEC_DISARM = 6406
comptime SEC_GOT_NETWORK = 6590
comptime SEC_GOT_EXPOSE = 6591
comptime SEC_GOT_STOP = 6592
comptime SEC_LAST = 6599
# Settings (settings.mojo): 6600–6799
comptime SET_FIRST = 6600
comptime SET_THEME = 6600  # + 0 light, 1 dark
comptime SET_STOP = 6610  # Stop daemon (the first tap asks)
comptime SET_STOP_SURE = 6611  # Stop daemon in the warning box
comptime SET_CANCEL = 6612
comptime SET_COPY = 6620  # + the source line (mxc set … --keep-alive 10m, mxc set … --pin, mxc stop --all, mxc ps)
comptime SET_ADD = 6630  # (no models yet) Add a model
comptime SET_GOT_STOP = 6790
comptime SET_LAST = 6799

# Add a model (add.mojo): 7000–7999
comptime ADD_FIRST = 7000
comptime ADD_FIELD = 7000  # the search field's text changed (search 250 ms later)
comptime ADD_ENTER = 7001  # Return in the field: search now
comptime ADD_DEBOUNCE = 7002  # + 0 / 1: the debounce timer (alternating, so each keystroke restarts it)
comptime ADD_FILTER = 7010  # + 0 all, 1 fits, 2 needs porting
comptime ADD_EMPTY = 7020  # an empty state's action
comptime ADD_PICK = 7100  # + the result's row
comptime ADD_SUGGEST = 7200  # + the suggestion (the too-big card)
comptime ADD_PORT_IT = 7300
comptime ADD_CANCEL = 7301
comptime ADD_TO_SEARCH = 7302  # Back to search
comptime ADD_RETRY = 7303  # Try again / Start again
comptime ADD_LOG = 7304  # Hide log / Show log
comptime ADD_TICK = 7305  # the stages' clock (every 0.5 s while a run goes)
comptime ADD_PULL_POLL = 7306  # every 0.7 s while a pull runs
comptime ADD_PORT_POLL = 7307  # every 1.5 s while a port runs
comptime ADD_COPY_EP = 7308
comptime ADD_COPY_CURL = 7309
comptime ADD_OPEN = 7310  # Open <name>
comptime ADD_SECURE = 7311  # Make it secure
comptime ADD_ANOTHER = 7312
comptime ADD_BACK = 7313  # the header's Back (My models)
comptime ADD_COPY_CMD = 7314  # the guided port's command
comptime ADD_GOT_SEARCH = 7500
comptime ADD_GOT_PULL_START = 7501
comptime ADD_GOT_PULL = 7502
comptime ADD_GOT_PULLS = 7503  # (a 409 without its job: the list, to follow the running one)
comptime ADD_GOT_PORT_START = 7504
comptime ADD_GOT_PORT = 7505
comptime ADD_GOT_LOAD = 7506
comptime ADD_GOT_MODELS = 7507
comptime ADD_GOT_SMOKE = 7508
comptime ADD_GOT_CANCEL = 7509
comptime ADD_LAST = 7999

# canvases
comptime RING = 0  # the Beacon's ring
comptime SPARK = 1  # Overview's Tokens chart
comptime FIT = 2  # Overview's GPU fit bar
comptime BAR = 10  # + the bar (Benchmark)
