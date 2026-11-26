# omx (goal 72 M4, on the Stage since goal 77 M7f): a voice assistant for a kitchen counter that runs on this machine, composed
# only of the framework's parts. You talk (or type), it listens, thinks and answers aloud; what it can show it shows, and it
# points at what it names. Nothing here is a host, a model runner or a drawing routine:
#
#   the screen         mojoui.stage.Stage                 the owner-approved Stage (docs/goals/77/stage-prototype.html): a top bar
#                                                         (people, Settings, what she is doing, the lane), the left column (the clock,
#                                                         Today, Pinned), the centre's live tiles, the right column (Live rows), the
#                                                         chat bar; a phone stacks it and keeps the bar at the bottom
#   the tiles          mojoui.livetiles + stagefeed       what matters now, urgent first: the assistant's own tiles (to-do, the job,
#                                                         the news), SAMPLE tiles for the sources omx doesn't have yet (samples.mojo),
#                                                         and the agent's (render_ui's LiveTiles and the tiles tool) on one card,
#                                                         "stage" (Screens.keep / Screens.tiles); drag a tile onto Pinned to pin it
#   the TV             mojoui.stagetv.StageTV             whenever a card shows (the agent's render_ui and card tools, the to-do list,
#                                                         the job, the news, the camera, a comic…) the chat bar grows into the TV: the
#                                                         card left, the conversation right (what was heard, what she said, the cards
#                                                         shown before: "Recent"); a new card swaps in place; × or 12 s of quiet after
#                                                         she stops speaking closes it (OMX_TV_QUIET = ms); a typed turn opens it on the
#                                                         conversation
#   ears and mouth     mojoui.voiceloop.VoiceLoop         Microphone -> Silero VAD -> Parakeet; Kokoro -> Speaker; barge-in
#   brain              mojoui.llmagent.LlmAgent           Qwen3.8-27B in this process (mojoui.llm), AG-UI events, render_ui, tiles
#   cards              mojoui.agentui.Screens             the agent's render_ui calls, validated and drawn natively (mojoui.genui)
#   the orb, the rim   mojoui.orb                         in the chat bar: listens/thinks/speaks; the cloud lane's frame
#   the pointer        mojoui.pointer.Pointer             a ring over the whole page that moves to the part she names (a card's part,
#                                                         a tile while the tiles show: mojoui.agentui.stage_parts)
#   the look           themes.omxqua.omxqua_counter        omxqua's Counter family, light or night as the system is (by the clock only when a person picks "night")
#   personalize        mojoui.personalize                 "make it darker", "use the mascot instead of the orb", "keep the scores
#                                                         bigger", "put it back": the agent's `personalize` tool (and Settings' knobs)
#                                                         change a few whitelisted settings per person (the top bar's All, A, S, M),
#                                                         kept in ~/.local/share/mojoui/look/omx (MOJOUI_LOOK); a scheme or accent
#                                                         morphs the window (mojoui.transition), the orb and the mascot crossfade
#                                                         (mojoui.mascot), the tiles reflow on their water spring (mojoui.livetiles)
#   the features       mojoui.assistant.Assistant         to-do (a file; the voice and the tick boxes edit it), news (cards of links),
#                                                         think-it-through jobs (the model's second sequence), the cloud lane (`claude
#                                                         -p`, only when asked for)
#   pictures, notes    mojoui.creator.Creator             make_comic / draw_picture (an image model on its own GPU, panel by panel on
#                                                         a card) and find_in_notes (e5 embeddings by MAX, a card citing the files)
#   maps               mojoui.tripmap (via mojoui.visual) show_map: a trip on real tiles, stops checked by a geocoder; the map flies to
#                                                         each stop as she names it (the cards' own move: Screens.point)
#   the camera         mojoui.looker.Looker               look: the tablet's (or this machine's) camera, the model's own eyes in this
#                                                         process, a card with the picture and labelled boxes she points at
#   how things work    mojoui.explain + mojoui.iso        explain: a small isometric diagram card; each block is a part she points at
#
# Environment (nothing is hard-wired to a machine): OMX_MODELS = the folder with Qwen3.8-27B-UD-Q4_K_M.gguf and
# parakeet-tdt-0.6b-v3 (default ~/Projects/omx-local/models); OMX_LLM_GPU = the card the model loads on, counted among the
# cards the process can see (default 0), OMX_LLM_CTX = its context (default 65536); OMX_MMPROJ = the vision projector that lets it see (default OMX_MODELS/mmproj-F16.gguf,
# without which there is no `look`); the voice models use the first visible
# card, so `CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=1,0 OMX_LLM_GPU=1` puts the voice on card 1 and the brain on
# card 0; OMX_LANE_SWITCH=1 shows the test button that flips the lane; OMX_CLOUD_CAP = cloud requests a session may make (3),
# OMX_CLAUDE_CMD = the command that answers them (`claude`), MOJOUI_LEDGER = the record of what went out, MOJOUI_TODO = the to-do
# file; MOJOUI_AUDIO_SOURCE / MOJOUI_AUDIO_SINK = the microphone and the speaker
# (mojoui.audio: `file:a.wav@2.5` plays a recorded voice as the microphone); OMX_TV_QUIET = the TV's quiet before it closes (ms);
# OMX_DARK=1 / 0 = the night / day look whatever the system and the person's look say (checks, recordings); OMX_MASCOT = a mascot
# pack folder (default: examples/stage/mascots/omx, found from the program); OMX_CLEAN=1 = no "sample" on the sample tiles (recordings only: samples.mojo).
# Run it with scripts/omx.sh, or on a tablet with scripts/tablet.sh omx. Each turn prints OMX lines (what was heard, the reply,
# the card, the numbers) for the checker.

from std.os.path import exists
from mojoui.app import App, Event
from mojoui.view import View, Node, Overlay, VStack, HStack, Text, Canvas, Spacer, CAPTION, CENTER, START, SPACE_S, SPACE_M, PRESS
from mojoui.overlays import Popover, Checkbox
from mojoui.agui import Agent, EV_TEXT, EV_RUN_FINISHED, EV_RUN_ERROR
from mojoui.assistant import Assistant, ASSISTANT_SYSTEM
from mojoui.cloudlane import route, LANE_CLOUD, LANE_BACKGROUND, STEP_ANSWERED, STEP_FAILED, STEP_FRAME_OFF
from mojoui.http import Http, Request
from mojoui.agentui import Screens, stage_parts
from mojoui.canvas import Surface
from mojoui.clock import now_ns, local_time, wall_clock_text, wall_date_text
from mojoui.effects import Every
from mojoui.geometry import rect_of
from mojoui.json import Json
from mojoui.genui import dump
from mojoui.llm import Llm
from mojoui.llmagent import LlmAgent, AppTool, press_with, view_tools, render_ui_tool
from mojoui.pointer import Pointer, PointerView, Part, parse_point
from mojoui.visual import Visual, VISUAL_SYSTEM, card_kind
from mojoui.creator import Creator
from mojoui.looker import Looker
from mojoui.orb import Orb, OrbView, RimView, draw_rim, ORB_IDLE, ORB_LISTEN, ORB_THINK, ORB_SPEAK
from mojoui.shared import environment
from mojoui.theme import Theme, Palette, ThemeCache
from mojoui.mascot import Presence, PRESENCE_ORB, PRESENCE_MASCOT, MASCOT_REST, mascot_pack_dir
from mojoui.personalize import (Personalize, LookChange, look_knobs, scheme_dark, is_night, accent_colour, stage_most, KNOB_COUNT,
                                PERSONALIZE, PERSONALIZE_ABOUT, PERSONALIZE_PARAMS)
from mojoui.transition import Morph
from mojoui.utf8 import head, boundary
from mojoui.voiceloop import VoiceLoop, LoopEvent, HEARD, STARTED, BARGED, READY, FAILED, POINT, LOOP_LOADING, LOOP_LISTENING, LOOP_HEARING, LOOP_THINKING, LOOP_SPEAKING
from mojoui.voiceui import VoiceDock, VoiceLane
from mojoui.livetiles import LiveTiles, Tile, Face, TileLook, Box, TAPPED, DROPPED, tile_icon
from mojoui.tilescard import TILES, TILES_ABOUT, TILES_PARAMS, tile_of, kind_of, is_sample
from mojoui.stage import Stage, StageClock, StageLabel, StageCard, StageRow, StageList, StageAvatar, StagePill, StageChat, StageNote, StageTool
from mojoui.stage import stage_compact, stage_layout
from mojoui.stagefeed import FeedTile, StageFeed, stage_feed, stage_tiles, tile_by_id, tint_hue
from mojoui.stagetv import StageTV, TVContent, StageThread, StageChips, StageMsg, TV_YOU, TV_OMX, TV_QUIET_MS, tv_now, RecentCards, RECENT_MAX
from themes.omxqua import omxqua_counter, counter_palette, counter_ground, counter_tv_look
from samples import sample_tiles, sample_kinds, sample_weather

comptime TICK = 1
comptime MUTE = 2
comptime TYPE = 3
comptime STOP = 4
comptime DRAFT = 5
comptime SEND = 6
comptime LANE = 7
comptime NEWS = 8  # the news feed's reply (mojoui.http)
comptime GESTURE = 9  # a press, drag or release on the tiles
comptime FRAME = 10  # the tiles' frame clock
comptime TV_FRAME = 11
comptime TV_CLOSE = 12
comptime SETTINGS = 13
comptime SETTINGS_CLOSE = 14
comptime SAMPLES = 15
comptime PERSON = 40  # PERSON + 0 … 3: the avatars
comptime RECENT = 60  # RECENT + k: a card shown before, into the TV again
comptime UNPIN = 70  # UNPIN + k: pinned tile k back on the stage
comptime KNOBS = 90  # KNOBS + 0 … 4: the look's knobs in Settings (mojoui.personalize.look_knobs)
comptime CHIP = 100  # the suggestions: CHIP + k
comptime TODO = 1000  # the to-do card's tick boxes: TODO + the thing's index (mojoui.assistant owns 200 numbers)
comptime ORB_CANVAS = 1
comptime RIM_CANVAS = 2
comptime POINTER_CANVAS = 3  # the ring she points with (mojoui.pointer), over the whole page
comptime TILES_CANVAS = 4
comptime TV_CANVAS = 5  # the TV's box (over the centre column)
comptime TV_VEIL = 6  # the TV body's veil
comptime CARDS = 20_000  # the cards' controls (mojoui.agentui.Screens) and their canvases
comptime CARD_CANVASES = 2000
comptime CREATOR_MSG = 900  # the image server's replies (mojoui.creator)
comptime CREATOR_CANVAS = 12_000  # the creator's cards' canvases
comptime LOOK_CANVAS = 15_000  # the camera cards' canvases (mojoui.looker)
comptime STAGE_CARD = "stage"  # the tiles' card on Screens: the app's tiles, the samples and the agent's
comptime TILES_TAG = "stage.tiles"  # the tiles' canvas (a dotted tag: every host reports its rect, mojoui.geometry)
comptime HINT = "Ask omx, or just say “omx”"


@fieldwise_init
struct PointMark(Copyable, Movable):
    var tag: String
    var due_ns: Int  # when its audio plays (the speaker's play clock)
    var sent_ns: Int  # when the app handed it to the ring
    var stamp: Int  # the ring's version when it was handed over


struct Main(App):
    comptime HTTP = True  # the news tool and the creator (the image server) send requests (https through Flare: examples/omx/needs)

    var http: Http
    var assist: Assistant
    var loop: VoiceLoop
    var llm: Optional[LlmAgent]
    var client: Agent  # the conversation as the screen keeps it (AG-UI messages, the cards' calls)
    var screens: Screens[]
    var creator: Creator  # comics, pictures and notes (mojoui.creator)
    var looker: Looker  # the camera and what the model sees through it (mojoui.looker)
    var presence: Presence  # the chat bar's orb, or the mascot a person asked for (they crossfade)
    var pointer: Pointer  # the ring that moves to the part of a card (or the tile) she is naming
    var turn_card: Int  # the first card of this turn: only this turn's cards are pointed at
    var parts_key: String  # what the loop's parts were last made from (cards, looks, the tiles' place, whether the TV hides them)
    var ring_said: String  # the ring's rect as last traced (OMX_TRACE: OMX RING lines follow it as a map flies the part to its middle)
    var turn_look: Int  # the camera's look serial when this turn began: only this turn's looks are pointed at
    var marks: List[PointMark]  # points sent to the ring, until the ring has been drawn on them (the lag is printed then)
    var dark: Bool
    var system_dark: Bool  # the system's dark: the look's "auto" follows it
    var night_was: Bool  # the clock was in the night (19:00-7:00) at the last restyle: "night" morphs when that changes
    var themes: ThemeCache  # one theme per scheme and accent, each built once (D-7889)
    var look: Personalize  # each person's look (mojoui.personalize)
    var morph: Morph  # the next change morphs (mojoui.transition)
    var width: Int
    var height: Int
    var suggestions: List[String]
    var note: String  # why something isn't working ("" when all is well)
    var muted: Bool
    var typing: Bool  # the chat bar's text box is open (the keyboard button; else the bar shows her subtitles)
    var draft: String
    var heard: String
    var reply: String
    var queued: Bool  # a run waits for the one in flight to be cancelled
    var silent_run: Bool  # the run in flight was cancelled: its late words are not spoken
    var turns: Int
    var run_ns: Int
    var told_first: Int
    var trace: Bool  # OMX_TRACE=1: a line each time the voice loop changes state (what a checker reads when a turn ends early)
    var last_state: Int
    var shelf_version: Int
    var primed: Bool  # the model has been asked for its prompt cache (LlmAgent.prime)
    var by_agent: Bool  # a button is being pressed by the model's tool call
    var thought_through: Bool  # the turn's words asked to be thought through in the background (a job should follow)
    var jobs_before: Int
    var lane_switch: Bool  # the test button that flips the lane is shown (OMX_LANE_SWITCH)
    # the Stage
    var tiles: LiveTiles  # the stage's tiles, as stagefeed places them (drawn here, not by the card: drop zones, a phone's columns)
    var all: List[Tile]  # every tile on the stage card, in its order
    var feed: StageFeed
    var pins: List[String]
    var stage_sig: String  # the stage card's arguments as last placed (placed again when they change)
    var samples_on: Bool
    var settings_open: Bool
    var person: Int
    var tv: StageTV
    var msgs: List[StageMsg]  # the conversation the TV shows
    var reply_msg: Int  # the TV message this turn's reply is being written into (-1 none yet)
    var recent: RecentCards  # the cards shown, newest first (keys: cardN, todo, job, newsK, lookN, makeK)
    var speaking: Bool  # she was speaking at the last tick (the TV's quiet counts from when she stops)
    var stopped_at: Int  # when she last stopped speaking (tv_now): her subtitles stay as long as the TV's quiet
    var todo_sig: String
    var job_sig: String
    var news_seen: Int
    var makes_seen: Int
    var looks_seen_n: Int
    var ticks: Int

    def __init__(out self):
        self.http = Http()
        self.assist = Assistant(TODO, NEWS)
        self.by_agent = False
        self.thought_through = False
        self.jobs_before = 0
        self.lane_switch = environment("OMX_LANE_SWITCH") != ""
        self.primed = False
        var models = environment("OMX_MODELS", environment("HOME") + "/Projects/omx-local/models")
        self.note = ""
        self.llm = None
        self.loop = VoiceLoop(parakeet_dir=models + "/parakeet-tdt-0.6b-v3")
        try:
            var gpu = Int(environment("OMX_LLM_GPU", "0"))
            var ctx = Int(environment("OMX_LLM_CTX", "65536"))
            var mmproj = environment("OMX_MMPROJ", models + "/mmproj-F16.gguf")
            self.llm = LlmAgent(Llm(models + "/Qwen3.8-27B-UD-Q4_K_M.gguf", gpu=gpu, n_ctx=ctx, mmproj=mmproj if exists(mmproj) else String("")), "Your name is omx. " + String(VISUAL_SYSTEM) + String(ASSISTANT_SYSTEM))
            self.assist.register(self.llm.value())
            Visual.register(self.llm.value())  # (the map card's show_map and the diagram's explain: mojoui.visual)
            self.llm.value().add_deferred(TILES, TILES_ABOUT, TILES_PARAMS)  # (the Stage's tiles: answered here, Screens.tiles on the stage card)
            self.llm.value().add_deferred(PERSONALIZE, PERSONALIZE_ABOUT, PERSONALIZE_PARAMS)  # (the person's look: answered here, mojoui.personalize)
            self.llm.value().trust.allow("stop")  # (the only button that stays pressable after notes or news were read in a turn: mojoui.trust)
            self.llm.value().trust.allow("type")
        except e:
            self.note = "the language model didn't load: " + String(e)
        self.client = Agent("", 0, 0, "omx")
        self.client.offer(render_ui_tool())
        self.screens = Screens(CARDS, CARD_CANVASES)
        var sd = environment("HOME") + "/Projects/omx-local"
        self.creator = Creator.from_environment("OMX", CREATOR_MSG, CREATOR_CANVAS, sd + "/third_party/stable-diffusion.cpp/build/bin/sd-server", models + "/card2")
        self.looker = Looker(LOOK_CANVAS)
        self.presence = Presence()
        var pack = mascot_pack_dir("OMX_MASCOT")  # (a folder in OMX_MASCOT, else the omx pack found from the program, not the working directory)
        if pack != "":
            try:  # (its resting strip decoded now, ~85 ms once: never while a change morphs)
                self.presence.load_mascot(pack)
                _ = self.presence.mascot.clips[MASCOT_REST].ensure_loaded()
            except e:
                print("omx: the mascot didn't load: " + String(e))
        self.pointer = Pointer()
        self.turn_card = 0
        self.parts_key = ""
        self.ring_said = ""
        self.turn_look = 0
        self.marks = List[PointMark]()
        self.dark = False
        self.system_dark = False
        self.night_was = False
        self.themes = ThemeCache()
        self.themes.put("light/default", omxqua_counter(False))
        self.themes.put("dark/default", omxqua_counter(True))
        self.look = Personalize("omx")
        self.morph = Morph()
        self.width = 1280
        self.height = 820
        self.suggestions = ["What is the capital of France?", "Compare the three largest planets by diameter", "What can you do?"]
        self.muted = False
        self.typing = False
        self.draft = ""
        self.heard = ""
        self.reply = ""
        self.queued = False
        self.silent_run = False
        self.turns = 0
        self.run_ns = 0
        self.told_first = 0
        self.trace = environment("OMX_TRACE") != ""
        self.last_state = -1
        self.shelf_version = 0
        self.tiles = LiveTiles()
        self.all = List[Tile]()
        self.feed = StageFeed()
        self.pins = List[String]()
        self.stage_sig = ""
        self.samples_on = environment("OMX_SAMPLES", "1") != "0"
        self.settings_open = False
        self.person = 0
        var quiet = TV_QUIET_MS
        try:
            var q = environment("OMX_TV_QUIET")
            if q != "":
                quiet = Int(q)
        except:
            pass
        self.tv = StageTV(TV_CANVAS, TV_VEIL, on_frame=TV_FRAME, on_close=TV_CLOSE, quiet_ms=quiet)
        self.tv.resize(1280)
        self.msgs = List[StageMsg]()
        self.reply_msg = -1
        self.recent = RecentCards()
        self.speaking = False
        self.stopped_at = -1
        self.todo_sig = ""
        self.job_sig = ""
        self.news_seen = 0
        self.makes_seen = 0
        self.looks_seen_n = 0
        self.ticks = 0
        self.keep_stage()

    def out(self, line: String):
        """A line for the checker (what was heard, said and called, with its numbers). What the person said, what was answered and
        what a tool was given stays off stdout unless OMX_TRACE=1: an app's output is read by whoever runs it (D-7256)."""
        if self.trace:
            print(line, flush=True)

    def title(self) -> String:
        return "omx"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 820)

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height
        self.tv.resize(width, height)
        var cols = 2 if stage_compact(width) else 4
        if cols != self.tiles.cols:
            self.tiles.set_columns(cols)

    def appearance(mut self, dark: Bool):
        self.system_dark = dark
        self.restyle()

    def theme_key(self) -> String:
        return ("dark/" if self.dark else "light/") + self.look.prefs.accent

    def restyle(mut self):
        """The look's scheme (auto: as the system is; night, opt-in: dark from 19:00 to 7:00 by this machine's clock) and accent
        into the theme, each theme built once, here (never in theme()); the canvases redraw in it. OMX_DARK=1 / 0 pins the
        night / day look over the system and the person's look (checks and recordings)."""
        var hour = local_time().hour
        self.night_was = is_night(hour)
        var pin = environment("OMX_DARK")
        self.dark = True if pin == "1" else (False if pin == "0" else scheme_dark(self.look.prefs, self.system_dark, hour))
        var key = self.theme_key()
        if not self.themes.has(key):
            var p = counter_palette(self.dark)
            self.themes.put(key, omxqua_counter(self.dark, accent_colour(p, self.look.prefs.accent) if self.look.prefs.accent != "default" else UInt32(0)))
        self.tiles.version += 1  # (the same tiles in the night's palette: their tints are names)
        self.tv.version += 1

    def personalized(mut self, c: LookChange):
        """A look change (the agent's personalize call, a knob, another person picked): the theme restyles, the presence
        crossfades, the tiles reflow on their water spring; only a new scheme or accent morphs the window."""
        self.out("OMX LOOK: " + self.look.profile + " " + self.look.prefs.json() + " ok=" + String(c.ok) + " " + c.message)
        if not c.moved():
            return
        var was = ("dark/" if self.dark else "light/") + c.before.accent  # (the theme before: the prefs have already changed)
        self.restyle()
        if self.theme_key() != was:  # (only a new scheme or accent morphs the window; the presence crossfades and the tiles reflow
            self.morph.morph()        # by themselves, D-8413)
        if c.before.presence != c.after.presence:
            _ = self.presence.show(PRESENCE_MASCOT if c.after.presence == "mascot" else PRESENCE_ORB)
        if c.before.density != c.after.density:
            self.stage_sig = ""
            self.place_stage()

    def transition(mut self) -> Int:
        return self.morph.take()

    def theme(self) -> Theme:
        return self.themes.get(self.theme_key())

    def every(self) -> List[Every]:
        return [Every(30, TICK)]

    # --- events ---------------------------------------------------------------------------------------------------

    def update(mut self, e: Event):
        var m = e.message
        if m == TICK:
            self.tick()
        elif m == MUTE:
            self.muted = not self.muted
            self.loop.muted = self.muted
        elif m == TYPE:
            self.typing = not self.typing
        elif m == DRAFT:
            self.draft = e.text
            self.tv.touch(tv_now())
        elif m == SEND:
            var typed = self.draft
            self.send(typed)
            self.draft = ""
        elif m == STOP:
            self.loop.stop_speaking()
            if not self.by_agent:  # (the model pressing it is inside the run it would cancel: it goes on and answers)
                self.cancel_run()
            self.cancel_cloud()
        elif m == LANE:
            self.assist.cloud.flip()
            self.presence.lane(self.assist.cloud.framed)
        elif m == GESTURE:
            if e.number == PRESS:
                self.drop_zones()
            self.tiles.gesture(e.number, e.x, e.y)
            for r in self.tiles.take_results():
                if r.kind == DROPPED and r.text == "pinned":
                    self.pin(r.id)
                elif r.kind == TAPPED:
                    self.tapped(r.id)
        elif m == FRAME:
            _ = self.tiles.frame(e.number)
            self.tv_tick()
        elif m == TV_FRAME:
            self.tv_tick()
        elif m == TV_CLOSE:
            self.tv.close(tv_now(), "x")
        elif m == SETTINGS:
            self.settings_open = not self.settings_open
        elif m == SETTINGS_CLOSE:
            self.settings_open = False
        elif m == SAMPLES:
            self.samples_on = not self.samples_on
            self.keep_stage()
        elif m >= PERSON and m < PERSON + 4:
            self.person = m - PERSON
            var names: List[String] = ["all", "a", "s", "m"]
            var before = self.look.prefs.copy()
            _ = self.look.use_profile(names[self.person])
            if not before.same(self.look.prefs):
                self.personalized(LookChange(True, "", before, self.look.prefs))
        elif m >= KNOBS and m < KNOBS + KNOB_COUNT:
            self.personalized(self.look.knob(e.number, m - KNOBS))
        elif m >= RECENT and m < RECENT + RECENT_MAX:
            var k = m - RECENT
            if k < len(self.recent.keys):
                var key = self.recent.keys[k]
                var t = self.recent.titles[k]
                self.show_card(key, t)
        elif m >= UNPIN and m < UNPIN + 20:
            self.unpin(m - UNPIN)
        elif m >= CHIP and m < CHIP + len(self.suggestions):
            var asked = self.suggestions[m - CHIP]
            self.send(asked)
        elif m == NEWS:
            if self.llm:
                _ = self.assist.on_http(e, self.llm.value())
        elif self.assist.owns(m):
            _ = self.assist.handle(e)
            self.tv.touch(tv_now())
        elif self.creator.owns(m):
            self.creator.reply(e)
        elif self.screens.owns(m):
            self.tv.touch(tv_now())
            if self.screens.handle(e, self.client):  # (a card's button: the agent hears it)
                self.start_run()

    def requests(mut self) -> List[Request]:
        var all = self.http.take()  # (the news tool's, then the image server's)
        for r in self.creator.take_requests():
            all.append(r.copy())
        return all^

    def closing(mut self):
        self.assist.cloud.close()  # (a running cloud request ends with the app)
        self.creator.closing()
        self.looker.closing()

    def controls(self) -> View:
        """The controls the agent may press, as plain buttons named by their tool names (mute, type, stop, and the lane switch when
        it shows): the chat bar wears the Stage's roles, so its buttons' tags are roles, not names. The same list whatever is
        on screen, so the model's prompt cache keeps."""
        var lane = VoiceLane("Local · Qwen 27B", "Claude · cloud", self.assist.cloud.framed, LANE, self.lane_switch)
        return VStack(lane, VoiceDock(self.muted, self.typing, self.draft, MUTE, TYPE, STOP, DRAFT, SEND, self.busy()), spacing=0)

    def tools(self) -> List[AppTool]:
        """What the agent may call: the app's controls (not the cards' own: those don't change the tool list when a card appears,
        so the model's prompt cache keeps) and the creator's and the camera's tools."""
        var all = view_tools(self.controls())
        for t in self.creator.tools():
            all.append(t.copy())
        for t in self.looker.tools(self.llm.value().llm.vision if self.llm else False):
            all.append(t.copy())
        return all^

    def send(mut self, text: String):
        """Words typed or tapped: the same turn as words said; the TV opens on the conversation (a card swaps in if one comes)."""
        if text.strip() == "":
            return
        var now = tv_now()
        if not self.tv.is_open:
            self.tv.open(now, "", "")
        self.tv.touch(now)
        self.heard_turn(self.loop.typed(String(text.strip())))

    def tick(mut self):
        self.ticks += 1
        if self.look.prefs.scheme == "night" and self.ticks % 1000 == 0:  # (every ~30 s, only while "night" is set: the hour
            if is_night(local_time().hour) != self.night_was:                 # crossing 19:00 or 7:00 morphs the look; auto never looks)
                var was = self.dark
                self.restyle()
                if self.dark != was:
                    self.morph.morph()
        if not self.primed and self.llm:
            self.primed = True
            self.llm.value().set_tools(self.tools())
            self.llm.value().prime(self.client.input_json())
        self.loop.hold = self.llm.value().warm() == False if self.llm else False  # (the first question meets a warm prompt cache)
        for ref e in self.loop.tick():
            if e.kind == READY:
                print("OMX READY: gpu=" + self.loop.gpu(), flush=True)
            elif e.kind == FAILED:
                self.note = e.text
                print("OMX FAILED: " + e.text, flush=True)
            elif e.kind == STARTED:
                self.cancel_unspoken()
            elif e.kind == BARGED:
                self.cancel_run()
                self.cancel_cloud()
                self.out("OMX BARGE: ms=" + String(Int(e.ms + 0.5)))
            elif e.kind == HEARD:
                self.heard_turn(e.copy())
            elif e.kind == POINT:
                self.point(e)
        self.tell_points()
        for line in self.screens.take_log():  # (what the cards did: a map's checked stops, its tiles, its flights)
            self.out("OMX " + line)
        self.screens.point_at(self.pointer.tag)  # (a pointed-at block rises, its step is marked)
        self.tiles.focus(String(self.pointer.tag[byte = 6:]) if self.pointer.tag.startswith(STAGE_CARD + ".") else String(""))
        self.creator.tick()
        for line in self.creator.take_log():
            self.out("OMX " + line)
        if self.llm:
            self.looker.tick(self.llm.value().llm)
        for line in self.looker.take_log():
            self.out("OMX " + line)
        self.pump_run()
        self.drive_assistant()
        self.watch_cards()
        if self.ticks % 10 == 0:
            self.keep_stage()
        if self.llm:
            var before = self.llm.value().compactions
            _ = self.llm.value().maintain()  # (never full: between turns the older conversation is condensed, mojoui.llmagent)
            if self.llm.value().compactions != before:
                self.out("OMX COMPACT: n=" + String(self.llm.value().compactions) + " messages=" + String(len(self.llm.value().history)) + " ms=" + String(Int(self.llm.value().compact_ms + 0.5)))
        if self.loop.first_ns != self.told_first and self.loop.first_ns > 0:
            self.told_first = self.loop.first_ns
            self.out("OMX FIRST_AUDIO: turn=" + String(self.turns) + " ms=" + String(Int(self.loop.first_audio_ms() + 0.5)))
        var s = self.loop.state()
        if self.trace and s != self.last_state:
            self.last_state = s
            print("OMX STATE: " + String(s) + " active=" + String(self.loop.active) + " said=" + String(self.loop.said) + " finished=" + String(self.loop.finished)
                  + " playing=" + String(self.loop.speaker.playing()) + " queued_ms=" + String(Int(self.loop.speaker.queued_ms())) + " latency_ms=" + String(Int(self.loop.speaker.latency_ms())) + " handed=" + String(self.loop.handed) + " spoken=" + String(self.loop.spoken) + " closed=" + String(self.loop.closed), flush=True)
        var talking = s == LOOP_SPEAKING
        if talking != self.speaking:  # (the TV's quiet counts from her last word, never while she talks)
            self.speaking = talking
            self.tv.speaking(tv_now(), talking)
            if not talking:
                self.stopped_at = tv_now()
        if s == LOOP_HEARING:
            self.presence.mode(ORB_LISTEN)
        elif s == LOOP_THINKING:
            self.presence.mode(ORB_THINK)
        elif s == LOOP_SPEAKING:
            self.presence.mode(ORB_SPEAK)
        else:
            self.presence.mode(ORB_IDLE)
        self.presence.drive(self.loop.level())
        self.tv_tick()

    def tv_tick(mut self):
        _ = self.tv.tick(tv_now())

    # --- a turn ---------------------------------------------------------------------------------------------------

    def heard_turn(mut self, e: LoopEvent):
        """The person's words are in (said or typed): into the conversation, and a run of the agent on them."""
        self.turn_card = len(self.screens.uis)  # (this turn's cards are the ones she points at)
        self.parts_key = ""
        self.turn_look = self.looker.serial
        self.loop.parts = List[Part]()
        self.turns += 1
        self.creator.turn_began()
        var fresh = self.assist.cloud.fresh(e.text, e.merged)  # (a merged turn continues the one before: only what is new)
        self.heard = e.text
        self.reply = ""
        self.stopped_at = -1
        self.msgs.append(StageMsg(TV_YOU, e.text, wall_clock_text(local_time())))
        self.reply_msg = -1
        self.tv.touch(tv_now())
        self.out("OMX HEARD: turn=" + String(self.turns) + " ms=" + String(Int(e.ms + 0.5)) + " text=" + e.text)
        self.cancel_cloud()
        var lane = route(fresh)
        if lane.lane == LANE_CLOUD and self.ask_cloud(fresh, lane.model):
            return
        self.thought_through = lane.lane == LANE_BACKGROUND
        self.jobs_before = self.assist.jobs_started
        self.client.say(fresh + (" (Use think_it_through for this: they want it thought through in the background.)" if self.thought_through else ""))
        self.start_run()

    def said(mut self, text: String):
        """Her words so far this turn, into the TV's conversation (one message a turn, growing as she speaks)."""
        if text == "":
            return
        if self.reply_msg < 0 or self.reply_msg >= len(self.msgs):
            self.msgs.append(StageMsg(TV_OMX, text, wall_clock_text(local_time())))
            self.reply_msg = len(self.msgs) - 1
        else:
            self.msgs[self.reply_msg].text = text
        if len(self.msgs) > 40:  # (the conversation keeps its last 40 lines)
            _ = self.msgs.pop(0)
            self.reply_msg -= 1

    def card_json(self) -> String:
        """The newest card as the agent built it (JSON; what a checker compares with what was asked)."""
        ref ui = self.screens.uis[len(self.screens.uis) - 1]
        return dump(ui.json, ui.json.get(0, "ui"))

    # --- pointing (mojoui.pointer): the voice loop says when a clause names a part of a card, the ring moves there ----------------

    def point(mut self, e: LoopEvent):
        """A spoken clause named a part (its audio is playing now): the ring goes to it."""
        var hit = parse_point(e.text)
        if not hit:
            return
        var tag = hit.value().tag()
        self.pointer.go(tag)
        _ = self.screens.point(tag)  # (the card moves for it too: a map flies to the stop)
        self.marks.append(PointMark(tag, e.ns, now_ns(), self.pointer.version()))
        self.out("OMX POINT_SENT: turn=" + String(self.turns) + " tag=" + tag + " at_ms=" + String(Int(e.ms)) + " late_ms=" + String(Int(Float64(now_ns() - e.ns) / 1e6)))

    def known_parts(self) -> List[Part]:
        """What she may point at now (agentui.stage_parts): this turn's card in the TV (a Screens card, or the camera's boxes),
        and the stage's tiles while the TV doesn't hide them."""
        return stage_parts(self.screens, self.tv, self.turn_card, self.looker.parts(self.turn_look), self.tiles.parts(STAGE_CARD, TILES_TAG), TILES_TAG)

    def tell_points(mut self):
        """The ring has been drawn on a point: its lag from the audio that names the part is printed (what the checker reads)."""
        var lay = self.tiles.layout()
        var key = String(len(self.screens.uis)) + "/" + String(self.looker.serial) + "/" + String(self.tv.hides_tiles()) + "/" + String(self.tv.is_open) + "/" + self.tv.target() + "/" + String(self.turn_card)
        for id in lay.ids:
            key += "," + id
        if key != self.parts_key:  # (a card arrived, the TV opened or closed, the tiles moved: what she may point at now)
            self.parts_key = key
            var parts = self.known_parts()
            self.pointer.know(parts)
            self.loop.parts = parts^
        if len(self.marks) > 0 and self.pointer.shown_stamp >= self.marks[0].stamp and self.pointer.shown_ns > 0:
            var m = self.marks.pop(0)
            self.out("OMX POINT: turn=" + String(self.turns) + " tag=" + m.tag + " lag_ms=" + String(Int(Float64(self.pointer.shown_ns - m.due_ns) / 1e6))
                     + " sent_ms=" + String(Int(Float64(m.sent_ns - m.due_ns) / 1e6)) + " seen=" + String(self.pointer.seen) + " ring=" + self.ring_text())
        if self.trace and self.pointer.active():  # (where the ring is now: a map's stop flies to the middle after the point)
            var said = self.pointer.tag + " ring=" + self.ring_text()
            if said != self.ring_said:
                self.ring_said = said
                self.out("OMX RING: tag=" + said)

    def ring_text(self) -> String:
        """What the ring is drawn round: x,y,w,h in points from the ring layer's corner ("-": not found)."""
        if len(self.pointer.rect) < 4:
            return "-"
        var out = String("")
        for i in range(4):
            out += ("," if i > 0 else "") + String(Int(self.pointer.rect[i] + 0.5))
        return out

    # --- the cloud lane: only when the person names it (mojoui.cloudlane.CloudTurn keeps the turn; the app says and shows) -----

    def ask_cloud(mut self, text: String, model: String) -> Bool:
        """The turn goes to the cloud model: True when it was asked (the frame is orange, "Asking Claude." is said); False when it
        wasn't (the cap, a secret in the words: the reason is said and the local model answers)."""
        var why = self.assist.cloud.ask(text, model)
        if why != "":
            self.loop.say("Sorry, " + why + ". I'll answer here. ")
            return False
        self.presence.lane(True)
        self.loop.say("Asking Claude. ")
        self.out("OMX LANE: cloud turn=" + String(self.turns) + " model=" + model)
        return True

    def cancel_cloud(mut self):
        if self.assist.cloud.cancel():
            self.out("OMX LANE: local turn=" + String(self.turns) + " (cloud turn dropped)")
        self.presence.lane(False)

    def cloud_step(mut self):
        """The cloud's answer arrives (or fails); the frame goes when what it said has been said."""
        var step = self.assist.cloud.step(self.loop.active)
        if step.kind == STEP_ANSWERED:
            self.reply = step.text
            self.said(step.text)
            self.loop.say(step.text)
            self.loop.end_reply()
            if self.llm:
                self.llm.value().remember("user", step.question)
                self.llm.value().remember("assistant", step.text)
            self.out("OMX CLOUD: turn=" + String(self.turns) + " seconds=" + String(Int(step.seconds + 0.5)) + " bytes_out=" + String(step.bytes_out)
                     + " used=" + String(step.used) + " text=" + step.text)
        elif step.kind == STEP_FAILED:
            self.out("OMX CLOUD: failed turn=" + String(self.turns) + " why=" + step.text)
            self.presence.lane(False)
            self.out("OMX LANE: local turn=" + String(self.turns))
            self.loop.say("Claude didn't answer, so I'll answer here. ")
            self.jobs_before = self.assist.jobs_started
            self.client.say(step.question)
            self.start_run()
        elif step.kind == STEP_FRAME_OFF:
            self.presence.lane(False)
            self.out("OMX LANE: local turn=" + String(self.turns))

    def drive_assistant(mut self):
        """The to-do file, the job's clock, the cloud's answer, and the one sentence when a job has finished."""
        if not self.llm:
            return
        _ = self.assist.tick(self.llm.value())
        self.cloud_step()
        var quiet = self.loop.idle() and not self.llm.value().running() and not self.assist.cloud.asking
        var line = self.assist.notice(quiet)
        if line != "":
            _ = self.loop.announce(line)
        for l in self.assist.take_log():
            self.out("OMX " + l)

    def start_run(mut self):
        if not self.llm:
            self.note = self.note if self.note != "" else "there is no language model to ask"
            return
        if self.llm.value().running():
            self.queued = True  # (the run in flight ends with RUN_FINISHED within a few ms of its cancel)
            self.cancel_run()
            return
        self.queued = False
        self.silent_run = False
        self.run_ns = now_ns()
        self.assist.turn_ns = self.run_ns
        self.assist.flush(self.llm.value())  # (what a job found joins the conversation here: the start of a turn)
        var input = self.client.local_input()
        self.llm.value().set_tools(self.tools())
        for ev in self.llm.value().begin(input):
            self.take(ev)

    def cancel_run(mut self):
        if self.llm and self.llm.value().running():
            self.silent_run = True
            self.llm.value().cancel()

    def cancel_unspoken(mut self):
        """The person went on talking before the reply made a sound: that run is dropped (their words are merged)."""
        if not self.loop.spoken:
            self.cancel_run()

    def pump_run(mut self):
        if not self.llm:
            return
        if self.llm.value().running():
            for ev in self.llm.value().poll():
                self.take(ev)
            var calls = self.llm.value().take_calls()
            for c in calls:  # (the assistant's slow tools, the creator's (answered when done), the tiles, then the app's own buttons)
                self.out("OMX TOOL: " + c.name + " " + c.arguments)
                if self.assist.is_tool(c.name):
                    self.assist.run_tool(c, self.llm.value(), self.http)
                    continue
                if self.creator.handles(c.name):
                    self.creator.call(c.id, c.name, c.arguments)
                    continue
                if self.looker.handles(c.name):
                    self.looker.call(c.id, c.arguments)
                    continue
                if c.name == PERSONALIZE:  # (the person's look: checked, applied with a morph, the result says what changed)
                    var ch = self.look.ask(c.arguments)
                    self.personalized(ch)
                    self.llm.value().answer(c.id, ch.result())
                    continue
                if c.name == TILES:
                    self.llm.value().answer(c.id, self.screens.tiles(c.arguments, into=STAGE_CARD))
                    self.place_stage()
                    continue
                self.by_agent = True
                var result = press_with(self, self.tools(), c.name, c.arguments)
                self.by_agent = False
                self.llm.value().answer(c.id, result)
                self.llm.value().set_tools(self.tools())
            for a in self.creator.take_answers():
                self.llm.value().answer(a.id, a.content, a.untrusted)
            for a in self.looker.take_answers():
                self.llm.value().answer(a.id, a.content, a.untrusted)
        elif self.queued:
            self.start_run()

    def take(mut self, ev: String):
        """One AG-UI event of the run: kept in the conversation, spoken, shown."""
        var kind = self.client.on_json(ev)
        if ev.find('"TOOL_CALL_START"') >= 0:  # (every tool the model calls, whoever answers it: what a checker reads to see which card it went for)
            try:
                var call = Json.parse(ev)
                var name = call.text(call.get(0, "toolCallName"))
                self.out("OMX CALL: turn=" + String(self.turns) + " name=" + name)
                if name.startswith("todo_"):  # (she talks about the list: it shows)
                    self.show_card("todo", "Your to-do list")
            except:
                pass
        if kind == EV_TEXT:
            try:
                var j = Json.parse(ev)
                var delta = j.text(j.get(0, "delta"))
                if not self.silent_run:
                    self.reply = self.reply + delta  # (not `+=`: see mojoui.voiceloop, D-7245)
                    self.loop.say(delta)
                    var so_far = self.reply
                    self.said(so_far)
            except:
                pass
        elif kind == EV_RUN_FINISHED or kind == EV_RUN_ERROR:
            self.client.end_chunks()
            self.client.running = False
            if not self.silent_run:
                self.loop.end_reply()
                var first = self.llm.value().first_text_ms if self.llm else Float64(-1)
                self.out("OMX REPLY: turn=" + String(self.turns) + " first_words_ms=" + String(Int(first + 0.5)) + " text=" + self.reply)
                if kind == EV_RUN_ERROR:
                    self.note = "the run failed: " + self.client.ended
                    print("OMX ERROR: " + self.client.ended, flush=True)
                if self.thought_through and self.assist.jobs_started == self.jobs_before:  # (asked to think it through, the model didn't: the job starts anyway)
                    self.thought_through = False
                    self.assist.start_job("", self.heard, "", self.llm.value())
        if self.screens.adopt(self.client) > 0:  # (render_ui's cards, and the card tools': show_map's maps, explain's diagrams)
            self.shelf_version += 1
            var k = len(self.screens.uis) - 1
            self.out("OMX CARD: turn=" + String(self.turns) + " ms=" + String(Int(Float64(now_ns() - self.run_ns) / 1e6 + 0.5)) + " cards="
                     + String(len(self.screens.uis)) + " cardkind=" + card_kind("", self.screens.uis[k].summary()) + " shape=" + self.screens.uis[k].summary() + " text=" + self.card_json())
            if self.screens.uis[k].tiles_node() >= 0:
                self.tiles_to_stage(k)
            else:
                var name = self.screens.uis[k].card
                self.show_card(name, self.turn_title())

    # --- the Stage: its tiles -------------------------------------------------------------------------------------

    def keep_stage(mut self):
        """The assistant's tiles and the samples on the stage card (Screens.keep: the agent's tiles and promotes stay; a sample
        steps aside for an agent's tile of its plain name), then placed."""
        var lead = String("")
        if self.assist.job and self.assist.job.value().state != 0:  # (a job that has finished leads once)
            lead = "job"
        var why = self.screens.keep(STAGE_CARD, self.assist.tiles(), self.assist.tile_kinds(), lead,
                                    sample_tiles() if self.samples_on else List[Tile](), sample_kinds())
        if why != "":
            self.out("OMX STAGE: refused " + why)
        self.place_stage()

    def place_stage(mut self):
        """The stage card's tiles placed (mojoui.stagefeed): the first is the urgent one, then the centre tiles, then samples that fill;
        the rest to Today (quiet ones) and Live (ticking ones); pinned ones to Pinned."""
        var k = self.screens.card_index(STAGE_CARD)
        if k < 0:
            return
        var sig = self.screens.uis[k].args()
        if sig == self.stage_sig:
            return
        self.stage_sig = sig
        ref ui = self.screens.uis[k]
        var n = ui.tiles_node()
        if n < 0:
            return
        var ts = ui.json.get(n, "tiles")
        var all = List[Tile]()
        var ranked = List[FeedTile]()
        for i in range(ui.json.size(ts)):
            var t = ui.json.at(ts, i)
            var tile = tile_of(ui.json, t)
            ranked.append(FeedTile(tile.id, kind_of(ui.json, t), is_sample(tile.id)))
            all.append(tile^)
        if len(ranked) == 0:
            return
        var big = len(all) > 0 and all[0].big
        self.feed = stage_feed(ranked, ranked[0].id, self.pins, most=stage_most(self.look.prefs, 3 if big else 6))  # (roomy: fewer, bigger tiles)
        self.all = all^
        self.tiles.set_tiles(stage_tiles(self.all, self.feed))
        self.feed.place(ranked, self.tiles.layout().ids)
        var shown = String("")
        for id in self.tiles.layout().ids:
            shown += ("," if shown != "" else "") + id
        self.out("OMX STAGE: shown=" + shown + " today=" + String(len(self.feed.today)) + " live=" + String(len(self.feed.live)) + " pinned=" + String(len(self.feed.pinned)))

    def tiles_to_stage(mut self, k: Int):
        """An agent's LiveTiles card: its tiles join the stage (Screens.merge_tiles: a tile already there takes the new face, its
        first one leads), then keep_stage (a sample the agent's tile now stands for leaves)."""
        _ = self.screens.merge_tiles(k, STAGE_CARD)
        self.keep_stage()

    def drop_zones(mut self):
        """Pinned, as a place a dragged tile can be let go (in the tiles canvas's points: it lies outside the canvas)."""
        var pins = rect_of("stage.pins")
        var cv = rect_of(TILES_TAG)
        if len(pins) == 4 and len(cv) == 4:
            self.tiles.drop_zone("pinned", Box(pins[0] - cv[0], pins[1] - cv[1], pins[2], pins[3]))

    def pin(mut self, id: String):
        for p in self.pins:
            if p == id:
                return
        self.pins.append(id)
        self.stage_sig = ""
        self.place_stage()

    def unpin(mut self, k: Int):
        if k < 0 or k >= len(self.pins):
            return
        _ = self.pins.pop(k)
        self.stage_sig = ""
        self.place_stage()

    def tapped(mut self, id: String):
        """A tap on a tile: its card into the TV (the to-do list, the job, the news)."""
        if id == "todo":
            self.show_card("todo", "Your to-do list")
        elif id == "job" and self.assist.job:
            var title = self.assist.job.value().title
            self.show_card("job", title)
        elif id == "news" and len(self.assist.news) > 0:
            self.show_card("news" + String(len(self.assist.news) - 1), "News: " + self.assist.news[len(self.assist.news) - 1].topic)

    # --- the TV: one card at a time, the conversation beside it ----------------------------------------------------------

    def turn_title(self) -> String:
        return head(self.heard, 70) if self.heard != "" else String("")

    def show_card(mut self, key: String, title: String):
        """Card `key` into the TV (opening it, or swapping the card in place), and to the front of Recent."""
        self.tv.open(tv_now(), title, key)
        self.recent.show(key, title)

    def watch_cards(mut self):
        """Cards that aren't the agent's render_ui (the to-do list changing, the job starting or ending, the news, a comic, the
        camera) go into the TV as they come."""
        var sig = String("")
        for ref i in self.assist.todo.items:
            sig += ("[x]" if i.done else "[ ]") + i.text + "|"
        if sig != self.todo_sig:
            var was = self.todo_sig
            self.todo_sig = sig
            if self.turns > 0 and was != sig and self.assist.todo_shown:
                self.show_card("todo", "Your to-do list")
            self.keep_stage()
        var js = String("")
        if self.assist.job:
            js = self.assist.job.value().title + "/" + String(self.assist.job.value().state)
        if js != self.job_sig:
            self.job_sig = js
            if js != "":
                var title = self.assist.job.value().title
                self.show_card("job", title)
            elif self.tv.is_open and self.tv.target() == "job":
                self.tv.close(tv_now(), "app")  # (dismissed: its card is gone)
            self.keep_stage()
        if len(self.assist.news) != self.news_seen:
            self.news_seen = len(self.assist.news)
            if self.news_seen > 0:
                self.show_card("news" + String(self.news_seen - 1), "News: " + self.assist.news[self.news_seen - 1].topic)
            self.keep_stage()
        if len(self.creator.cards) != self.makes_seen:
            self.makes_seen = len(self.creator.cards)
            if self.makes_seen > 0:
                self.show_card("make" + String(self.makes_seen - 1), self.turn_title())
        if len(self.looker.cards) != self.looks_seen_n:
            self.looks_seen_n = len(self.looker.cards)
            if self.looks_seen_n > 0:
                var name = self.looker.cards[self.looks_seen_n - 1].name  # ("look<serial>": its boxes' parts carry the same name)
                self.show_card(name, self.turn_title())

    def card_view(self, key: String) -> View:
        """The view for a TV card key: cardN (the agent's, Screens), todo, job, newsK, makeK (the creator's), lookK (the camera's)."""
        if key == "todo":
            return self.assist.todo_card()
        if key == "job":
            return self.assist.job_card()
        try:
            if key.startswith("news"):
                return self.assist.news_card(Int(String(key[byte = 4:])))
            if key.startswith("make"):
                var k = Int(String(key[byte = 4:]))
                if k >= 0 and k < len(self.creator.cards):
                    return self.creator.card_view(k)
            if key.startswith("look"):
                var views = self.looker.views()  # (newest first)
                for k in range(len(self.looker.cards)):
                    if self.looker.cards[k].name == key:
                        return views[len(views) - 1 - k].copy()
        except:
            pass
        var s = self.screens.card_index(key)
        if s >= 0:
            return self.screens.view(s, self.client.state, self.shelf_version)
        return View(List[Node]())

    def recent_view(self) -> View:
        """The cards shown before this one, one tap each back into the TV."""
        var items = List[View]()
        for k in self.recent.others(self.tv.card):
            items.append(StagePill(_icon_of(self.recent.keys[k]), head(self.recent.label(k), 34), RECENT + k))
        if len(items) == 0:
            return View(List[Node]())
        return VStack(StageLabel("clock", "Recent"), VStack(items^, spacing=SPACE_S).align(START), spacing=SPACE_S).align(START)

    # --- the screen -----------------------------------------------------------------------------------------------

    def busy(self) -> Bool:
        return self.loop.state() == LOOP_THINKING or self.loop.state() == LOOP_SPEAKING or self.assist.cloud.asking or Bool(self.llm and self.llm.value().running())

    def status(self) -> String:
        if self.note != "":
            return self.note
        if self.muted:
            return "Muted"
        if self.assist.cloud.asking:
            return "Asking Claude…"
        var s = self.loop.state()
        if s == LOOP_LOADING:
            return "Loading the voice and the model…"
        if s == LOOP_HEARING:
            return "Listening…"
        if s == LOOP_THINKING:
            return "Thinking…"
        if s == LOOP_SPEAKING:
            return "Speaking"
        return "Listening"

    def subtitle(self) -> String:
        """The chat bar's words when its box is closed: what she is saying (its last words; they stay as long as the TV's quiet
        after she stops), what she heard while she thinks."""
        var s = self.loop.state()
        var lingers = self.stopped_at >= 0 and (tv_now() - self.stopped_at) // 1000 < self.tv.quiet_ms  # (read after she stops, as long as the TV's quiet)
        if (s == LOOP_SPEAKING or s == LOOP_THINKING or lingers) and self.reply != "":
            var r = self.reply
            if r.byte_length() > 90:
                var cut = boundary(r, r.byte_length() - 90)  # (a character's first byte: a reply is UTF-8, "Belém")
                var tail = String(r[byte = cut:])
                var sp = tail.find(" ")
                r = "…" + (String(tail[byte = sp + 1:]) if sp >= 0 else tail)
            return r
        if s == LOOP_THINKING and self.heard != "":
            return "“" + head(self.heard, 80) + "”"
        if self.note != "":
            return self.note
        return ""

    def row(self, id: String) -> View:
        """A tile as a one-line side row: its icon, its head, its first face's big line (the job's clock ticking)."""
        var t = tile_by_id(self.all, id)
        var value = t.faces[0].big if len(t.faces) > 0 else String("")
        return StageRow(tile_icon(t.icon), t.head, value, tint_hue(t.tint))

    def view(self) -> View:
        var compact = stage_compact(self.width)
        var lane = VoiceLane("Local · Qwen 27B", "Claude · cloud", self.assist.cloud.framed, LANE, self.lane_switch)
        var where = HStack(Text(self.status(), CAPTION), lane.copy(), spacing=SPACE_S).align(CENTER)
        var settings = HStack(StagePill("settings", "Settings", SETTINGS, compact), spacing=0).tag("omx-settings")  # (the popover's
        # anchor wraps the pill: a role-wearing view is never tagged again, docs/lessons.md)
        var top_items = List[View]()
        top_items.append(StageAvatar("All", 0, PERSON))
        top_items.append(StageAvatar("A", 2, PERSON + 1))
        top_items.append(StageAvatar("S", 3, PERSON + 2))
        top_items.append(StageAvatar("M", 5, PERSON + 3))
        top_items.append(settings^)
        top_items.append(Spacer())
        if not compact:
            top_items.append(where.copy())
        if self.settings_open:
            var body = VStack(Text("Answers come from this machine (Qwen 27B) unless you ask for Claude.", CAPTION),
                              Checkbox("Sample tiles (calendar, weather, photos, home)", self.samples_on, SAMPLES),
                              look_knobs(self.look.prefs, KNOBS, self.look.can_undo()), spacing=SPACE_S).align(START)
            top_items.append(Popover("omx-settings", "Settings", body^, on_close=SETTINGS_CLOSE))
        var top = HStack(top_items^, spacing=SPACE_S).align(CENTER)
        # left: what she is doing (a phone), the clock and its weather line, Today, Pinned
        var t = local_time()
        var left_items = List[View]()
        if compact:
            left_items.append(where.copy())
        left_items.append(StageClock(wall_clock_text(t), wall_date_text(t), sample_weather() if self.samples_on else String(""), compact))
        var today = List[View]()
        for id in self.feed.today:
            today.append(self.row(id))
        if len(today) == 0:
            today.append(StageNote("Nothing else today"))
        left_items.append(StageLabel("calendar", "Today"))
        left_items.append(VStack(StageList(today), spacing=0).fill().tag("stage-today"))
        var pins = List[View]()
        for k in range(len(self.feed.pinned)):
            var p = tile_by_id(self.all, self.feed.pinned[k])
            var f = p.faces[0].copy() if len(p.faces) > 0 else Face(p.head, "")
            pins.append(StageCard(tile_icon(p.icon), p.head, f.big, f.sub, tint_hue(p.tint), on_unpin=UNPIN + k))
        if len(pins) == 0:
            pins.append(StageNote("Drag a tile here to keep it at your side"))
        left_items.append(VStack(VStack(StageLabel("pin", "Pinned"), StageList(pins), spacing=SPACE_S).align(START).fill().tag(
            "stage-drop" if self.tiles.hover_zone == "pinned" else "stage-pins"), spacing=0).fill().tag("stage.pins"))
        var left = VStack(left_items^, spacing=SPACE_M).align(START)
        # right: Live (rows that keep ticking: the job's clock)
        var live = List[View]()
        for id in self.feed.live:
            live.append(self.row(id))
        if len(live) == 0:
            live.append(StageNote("Nothing live right now"))
        var right = VStack(StageLabel("zap", "Live"), VStack(StageList(live), spacing=0).fill().tag("stage-live"), spacing=SPACE_M).align(START)
        # the chat bar: the orb, her subtitles or the text box, the keyboard, stop while she talks, the mic (mute)
        var tools = List[View]()
        tools.append(StageTool("Close keyboard" if self.typing else "Type", TYPE, "keyboard"))
        if self.busy():
            tools.append(StageTool("Stop", STOP, "square"))
        var chat = StageChat(OrbView(ORB_CANVAS, self.presence.version(), big=False, side=52), self.draft, "Type to omx" if self.typing else HINT,
                             on_change=DRAFT, on_submit=SEND, on_mic=MUTE, subtitle=self.subtitle(), field=self.typing, tools=tools^,
                             mic="Unmute" if self.muted else "Mute", mic_icon="mic-off" if self.muted else "mic")
        var stage = Canvas(TILES_CANVAS, self.tiles.version, on_gesture=GESTURE, on_frame=FRAME).grow().fill().tag(TILES_TAG)
        var lay = self.tv.layout()
        var thread = VStack(StageThread(self.msgs, lay.thread_w), self.recent_view(), spacing=SPACE_M).grow().fill()
        var content = TVContent(self.card_view(self.tv.card) if self.tv.card != "" else View(List[Node]()), thread^, StageChips(self.suggestions, CHIP))
        var page = Stage(top, left, stage, right, chat, self.width, compact_panel=self.tiles.compact_height() + 20, tv=self.tv, content=content)
        var ring = PointerView(POINTER_CANVAS, self.pointer.version())
        if self.assist.cloud.framed:
            return Overlay(page^, ring^, RimView(RIM_CANVAS, 1)).grow().fill()
        return Overlay(page^, ring^).grow().fill()

    def draw(mut self, canvas: Int, mut surface: Surface):
        var p = counter_palette(self.dark)  # (the palette only: the whole theme, its CSS included, is not rebuilt every frame, D-7876)
        if canvas == ORB_CANVAS:
            var gaze = self.pointer.look("orb-small")
            self.presence.look(gaze[0], gaze[1], gaze[2])
            var tint = accent_colour(p, self.look.prefs.accent) if self.look.prefs.accent != "default" else p.series[1]
            self.presence.draw(surface, p.with_accent(tint))  # (the Counter's accent is ink: the orb in the family's blue, or the accent picked)
        elif canvas == POINTER_CANVAS:
            self.pointer.draw(surface, p.with_accent(p.series[2]))  # (the ring in the family's teal: pointing reads apart from the ink)
        elif canvas == RIM_CANVAS:
            var rim = p.copy()
            rim.warn = p.series[3]  # (the cloud's frame in the family's orange: the Counter's warn is a darker ink for words)
            draw_rim(surface, rim, self.assist.cloud.framed)
        elif canvas == TILES_CANVAS:
            self.tiles.draw(surface, TileLook.on(p, counter_ground(self.dark)), self.screens.font)  # (on the stage's own ground; the cards' font)
        elif self.tv.draws(canvas):
            self.tv.draw(canvas, surface, counter_tv_look(self.dark))
        elif self.creator.owns_canvas(canvas):
            self.creator.draw(canvas, surface, p)
        elif self.looker.owns_canvas(canvas):
            self.looker.draw(canvas, surface, p)
        else:
            self.screens.draw(canvas, surface, p, self.client.state)


def _icon_of(key: String) -> String:
    """A Recent card's icon by its key."""
    if key == "todo":
        return "list-todo"
    if key == "job":
        return "brain"
    if key.startswith("news"):
        return "scroll-text"
    if key.startswith("look"):
        return "camera"
    if key.startswith("make"):
        return "image"
    return "sparkles"
