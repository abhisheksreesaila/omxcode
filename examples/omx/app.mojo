# omx (goal 72 M4): a voice assistant that runs on this machine, composed only of the framework's parts. You talk, it
# listens, thinks and answers aloud; anything with several facts it shows as a card on the shelf; its own buttons are its
# tools. Nothing here is a host, a model runner or a drawing routine:
#
#   ears and mouth     mojoui.voiceloop.VoiceLoop      Microphone -> Silero VAD -> Parakeet; Kokoro -> Speaker; barge-in
#   brain              mojoui.llmagent.LlmAgent        Qwen3.8-27B in this process (mojoui.llm), AG-UI events, render_ui
#   cards              mojoui.agentui.Screens          the agent's render_ui calls, validated and drawn natively (mojoui.genui)
#   the orb, the rim   mojoui.orb                      the liquid orb that listens/thinks/speaks, the cloud lane's frame
#   the screens        mojoui.voiceui                  Home (big orb, greeting, chips) morphing to Work (small orb, shelf)
#   the look           themes.liquid                   Liquid light, and Liquid dark when the system is
#   the features      mojoui.assistant.Assistant      to-do (a file; the voice and the tick boxes edit it), news (cards of links), think-it-
#                                                      through jobs (the model's second sequence), the cloud lane (`claude -p`, only when asked for)
#
# Environment (nothing is hard-wired to a machine): OMX_MODELS = the folder with Qwen3.8-27B-UD-Q4_K_M.gguf and
# parakeet-tdt-0.6b-v3 (default ~/Projects/omx-local/models); OMX_LLM_GPU = the card the model loads on, counted among the
# cards the process can see (default 0), OMX_LLM_CTX = its context (default 65536); the voice models use the first visible
# card, so `CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=1,0 OMX_LLM_GPU=1` puts the voice on card 1 and the brain on
# card 0; OMX_LANE_SWITCH=1 shows the test button that flips the lane; OMX_CLOUD_CAP = cloud requests a session may make (3),
# OMX_CLAUDE_CMD = the command that answers them (`claude`), MOJOUI_LEDGER = the record of what went out, MOJOUI_TODO = the to-do
# file; MOJOUI_AUDIO_SOURCE / MOJOUI_AUDIO_SINK = the microphone and the speaker
# (mojoui.audio: `file:a.wav@2.5` plays a recorded voice as the microphone). Run it with scripts/omx.sh, or on a tablet
# with scripts/tablet.sh omx. Each turn prints OMX lines (what was heard, the reply, the card, the numbers) for the checker.

from mojoui.app import App, Event
from mojoui.view import View, Overlay
from mojoui.agui import Agent, EV_TEXT, EV_RUN_FINISHED, EV_RUN_ERROR
from mojoui.assistant import Assistant, ASSISTANT_SYSTEM
from mojoui.cloudlane import route, Route, LANE_CLOUD, LANE_BACKGROUND, ASK_DONE, ASK_FAILED
from mojoui.http import Http, Request
from mojoui.agentui import Screens
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.effects import Every
from mojoui.json import Json
from mojoui.llm import Llm
from mojoui.llmagent import LlmAgent, press, view_tools, render_ui_tool, DEFAULT_SYSTEM
from mojoui.orb import Orb, OrbView, RimView, draw_rim, ORB_IDLE, ORB_LISTEN, ORB_THINK, ORB_SPEAK
from mojoui.shared import environment
from mojoui.theme import Theme
from mojoui.voiceloop import VoiceLoop, LoopEvent, HEARD, STARTED, BARGED, READY, FAILED, LOOP_LOADING, LOOP_LISTENING, LOOP_HEARING, LOOP_THINKING, LOOP_SPEAKING
from mojoui.voiceui import VoiceHome, VoiceWork, VoiceDock, VoiceChips, VoiceLane
from themes.liquid import liquid

comptime TICK = 1
comptime MUTE = 2
comptime TYPE = 3
comptime STOP = 4
comptime DRAFT = 5
comptime SEND = 6
comptime LANE = 7
comptime CHIP = 100  # the suggestions: CHIP + k
comptime TODO = 1000  # the to-do card's tick boxes: TODO + the thing's index (mojoui.assistant owns 200 numbers)
comptime NEWS = 8  # the news feed's reply (mojoui.http)
comptime ORB_CANVAS = 1
comptime RIM_CANVAS = 2
comptime CARDS = 20_000  # the cards' controls (mojoui.agentui.Screens) and their canvases
comptime CARD_CANVASES = 2000


struct Main(App):
    comptime HTTP = True  # the news tool is a request (https through Flare: examples/omx/needs)

    var http: Http
    var assist: Assistant
    var loop: VoiceLoop
    var llm: Optional[LlmAgent]
    var client: Agent  # the conversation as the screen keeps it (AG-UI messages, the cards' calls)
    var screens: Screens[]
    var orb: Orb
    var look: Theme
    var suggestions: List[String]
    var note: String  # why something isn't working ("" when all is well)
    var work: Bool  # the Work screen (a turn has begun) rather than Home
    var muted: Bool
    var typing: Bool
    var draft: String
    var cloud: Bool  # the lane the answers come from: this machine, or a cloud model (the frame is orange)
    var heard: String
    var reply: String
    var said_before: String  # what the merged turn had said before the last continuation
    var queued: Bool  # a run waits for the one in flight to be cancelled
    var silent_run: Bool  # the run in flight was cancelled: its late words are not spoken
    var turns: Int
    var run_ns: Int
    var told_first: Int
    var trace: Bool  # OMX_TRACE=1: a line each time the voice loop changes state (what a checker reads when a turn ends early)
    var last_state: Int
    var shelf_version: Int
    var primed: Bool  # the model has been asked for its prompt cache (LlmAgent.prime)
    var cloud_turn: Bool  # the question went to the cloud model and its answer is awaited
    var cloud_done: Bool  # ... and has come back: the frame stays until it has been said
    var cloud_text: String
    var thought_through: Bool  # the turn's words asked to be thought through in the background (a job should follow)
    var jobs_before: Int
    var lane_switch: Bool  # the test button that flips the lane is shown (OMX_LANE_SWITCH)

    def __init__(out self):
        self.http = Http()
        self.assist = Assistant(TODO, NEWS)
        self.cloud_turn = False
        self.cloud_done = False
        self.cloud_text = ""
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
            self.llm = LlmAgent(Llm(models + "/Qwen3.8-27B-UD-Q4_K_M.gguf", gpu=gpu, n_ctx=ctx), "Your name is omx. " + String(DEFAULT_SYSTEM) + String(ASSISTANT_SYSTEM), max_tokens=1200)
            self.assist.register(self.llm.value())
        except e:
            self.note = "the language model didn't load: " + String(e)
        self.client = Agent("", 0, 0, "omx")
        self.client.offer(render_ui_tool())
        self.screens = Screens(CARDS, CARD_CANVASES)
        self.orb = Orb()
        self.look = liquid(False)
        self.suggestions = ["What is the capital of France?", "Compare the three largest planets by diameter", "What can you do?"]
        self.work = False
        self.muted = False
        self.typing = False
        self.draft = ""
        self.cloud = False
        self.heard = ""
        self.reply = ""
        self.said_before = ""
        self.queued = False
        self.silent_run = False
        self.turns = 0
        self.run_ns = 0
        self.told_first = 0
        self.trace = environment("OMX_TRACE") != ""
        self.last_state = -1
        self.shelf_version = 0

    def title(self) -> String:
        return "omx"

    def window_size(self) -> Tuple[Int, Int]:
        return (1000, 780)

    def appearance(mut self, dark: Bool):
        self.look = liquid(dark)

    def theme(self) -> Theme:
        return self.look.copy()

    def every(self) -> List[Every]:
        return [Every(30, TICK)]

    def requests(mut self) -> List[Request]:
        return self.http.take()

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
        elif m == SEND:
            var typed = self.draft
            self.send(typed)
            self.draft = ""
        elif m == STOP:
            self.loop.stop_speaking()
            self.cancel_run()
            self.cancel_cloud()
        elif m == LANE:
            self.cloud = not self.cloud
            self.orb.lane(self.cloud)
        elif m >= CHIP and m < CHIP + len(self.suggestions):
            var asked = self.suggestions[m - CHIP]
            self.send(asked)
        elif m == NEWS:
            if self.llm:
                _ = self.assist.on_http(e, self.llm.value())
        elif self.assist.owns(m):
            _ = self.assist.handle(e)
        elif self.screens.owns(m):
            if self.screens.handle(e, self.client):  # (a card's button: the agent hears it)
                self.start_run()

    def send(mut self, text: String):
        """Words typed or tapped: the same turn as words said."""
        if text.strip() == "":
            return
        self.heard_turn(self.loop.typed(String(text.strip())))

    def tick(mut self):
        if not self.primed and self.llm:
            self.primed = True
            self.llm.value().set_tools(view_tools(self.page(False)))
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
                print("OMX BARGE: ms=" + String(Int(e.ms + 0.5)), flush=True)
            elif e.kind == HEARD:
                self.heard_turn(e.copy())
        self.pump_run()
        self.drive_assistant()
        if self.loop.first_ns != self.told_first and self.loop.first_ns > 0:
            self.told_first = self.loop.first_ns
            print("OMX FIRST_AUDIO: turn=" + String(self.turns) + " ms=" + String(Int(self.loop.first_audio_ms() + 0.5)), flush=True)
        var s = self.loop.state()
        if self.trace and s != self.last_state:
            self.last_state = s
            print("OMX STATE: " + String(s) + " active=" + String(self.loop.active) + " said=" + String(self.loop.said) + " finished=" + String(self.loop.finished)
                  + " playing=" + String(self.loop.speaker.playing()) + " queued_ms=" + String(Int(self.loop.speaker.queued_ms())) + " latency_ms=" + String(Int(self.loop.speaker.latency_ms())) + " handed=" + String(self.loop.handed) + " spoken=" + String(self.loop.spoken) + " closed=" + String(self.loop.closed), flush=True)
        if s == LOOP_HEARING:
            self.orb.mode(ORB_LISTEN)
        elif s == LOOP_THINKING:
            self.orb.mode(ORB_THINK)
        elif s == LOOP_SPEAKING:
            self.orb.mode(ORB_SPEAK)
        else:
            self.orb.mode(ORB_IDLE)
        self.orb.drive(self.loop.level())

    # --- a turn ---------------------------------------------------------------------------------------------------

    def heard_turn(mut self, e: LoopEvent):
        """The person's words are in (said or typed): the Work screen, and a run of the agent on them."""
        self.work = True
        self.turns += 1
        var fresh = String(e.text[byte = self.said_before.byte_length() + 1 :]) if e.merged and e.text.byte_length() > self.said_before.byte_length() else e.text
        self.heard = e.text
        self.said_before = e.text
        self.reply = ""
        print("OMX HEARD: turn=" + String(self.turns) + " ms=" + String(Int(e.ms + 0.5)) + " text=" + e.text, flush=True)
        self.cancel_cloud()
        var lane = route(fresh)
        if lane.lane == LANE_CLOUD and self.ask_cloud(fresh, lane):
            return
        self.thought_through = lane.lane == LANE_BACKGROUND
        self.jobs_before = self.assist.jobs_started
        self.client.say(fresh + (" (Use think_it_through for this: they want it thought through in the background.)" if self.thought_through else ""))
        self.start_run()

    # --- the cloud lane: only when the person names it (mojoui.cloudlane) ------------------------------------------

    def ask_cloud(mut self, text: String, lane: Route) -> Bool:
        """The turn goes to the cloud model: True when it was asked (the frame is orange, "Asking Claude." is said); False when it
        wasn't (the cap, a secret in the words: the reason is said and the local model answers)."""
        var why = self.assist.cloud.begin(text, lane.model)
        if why != "":
            self.loop.say("Sorry, " + why + ". I'll answer here. ")
            return False
        self.cloud_turn = True
        self.cloud_done = False
        self.cloud_text = text
        self.cloud = True
        self.orb.lane(True)
        self.loop.say("Asking Claude. ")
        print("OMX LANE: cloud turn=" + String(self.turns) + " model=" + lane.model, flush=True)
        return True

    def cancel_cloud(mut self):
        if self.cloud_turn:
            self.assist.cloud.cancel()
        self.assist.cloud.idle()
        if self.cloud:
            print("OMX LANE: local turn=" + String(self.turns) + " (cloud turn dropped)", flush=True)
        self.cloud_turn = False
        self.cloud_done = False
        self.cloud = False
        self.orb.lane(False)

    def cloud_step(mut self):
        """The cloud's answer arrives (or fails); the frame goes when what it said has been said."""
        if self.cloud_turn:
            var state = self.assist.cloud.poll()
            if state == ASK_DONE:
                var answer = self.assist.cloud.answer
                self.reply = answer
                self.loop.say(answer)
                self.loop.end_reply()
                if self.llm:
                    self.llm.value().remember("user", self.cloud_text)
                    self.llm.value().remember("assistant", answer)
                print("OMX CLOUD: turn=" + String(self.turns) + " seconds=" + String(Int(self.assist.cloud.seconds() + 0.5)) + " bytes_out=" + String(self.assist.cloud.bytes_out)
                      + " used=" + String(self.assist.cloud.used) + " text=" + answer, flush=True)
                self.assist.cloud.idle()
                self.cloud_turn = False
                self.cloud_done = True
            elif state == ASK_FAILED:
                print("OMX CLOUD: failed turn=" + String(self.turns) + " why=" + self.assist.cloud.error, flush=True)
                self.assist.cloud.idle()
                self.cloud_turn = False
                self.cloud = False
                self.orb.lane(False)
                print("OMX LANE: local turn=" + String(self.turns), flush=True)
                self.loop.say("Claude didn't answer, so I'll answer here. ")
                self.jobs_before = self.assist.jobs_started
                self.client.say(self.cloud_text)
                self.start_run()
        elif self.cloud_done and not self.loop.active:
            self.cloud_done = False
            self.cloud = False
            self.orb.lane(False)
            print("OMX LANE: local turn=" + String(self.turns), flush=True)

    def drive_assistant(mut self):
        """The to-do file, the job's clock, the cloud's answer, and the one sentence when a job has finished."""
        if not self.llm:
            return
        _ = self.assist.tick(self.llm.value())
        self.cloud_step()
        var quiet = self.loop.idle() and not self.llm.value().running() and not self.cloud_turn
        var line = self.assist.notice(quiet)
        if line != "":
            _ = self.loop.announce(line)
        for l in self.assist.take_log():
            print("OMX " + l, flush=True)

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
        self.llm.value().set_tools(view_tools(self.page(False)))
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
            for c in calls:  # (the assistant's slow tools, then the app's own buttons, as the agent pressed them)
                if self.assist.is_tool(c.name):
                    self.assist.run_tool(c, self.llm.value(), self.http)
                    continue
                var result = press(self, c.name, c.arguments)
                self.llm.value().answer(c.id, result)
                self.llm.value().set_tools(view_tools(self.page(False)))
        elif self.queued:
            self.start_run()

    def take(mut self, ev: String):
        """One AG-UI event of the run: kept in the conversation, spoken, shown."""
        var kind = self.client.on_json(ev)
        if kind == EV_TEXT:
            try:
                var j = Json.parse(ev)
                var delta = j.text(j.get(0, "delta"))
                if not self.silent_run:
                    self.reply = self.reply + delta  # (not `+=`: see mojoui.voiceloop, D-7245)
                    self.loop.say(delta)
            except:
                pass
        elif kind == EV_RUN_FINISHED or kind == EV_RUN_ERROR:
            self.client.end_chunks()
            self.client.running = False
            if not self.silent_run:
                self.loop.end_reply()
                var first = self.llm.value().first_text_ms if self.llm else Float64(-1)
                print("OMX REPLY: turn=" + String(self.turns) + " first_words_ms=" + String(Int(first + 0.5)) + " text=" + self.reply, flush=True)
                if kind == EV_RUN_ERROR:
                    self.note = "the run failed: " + self.client.ended
                    print("OMX ERROR: " + self.client.ended, flush=True)
                if self.thought_through and self.assist.jobs_started == self.jobs_before:  # (asked to think it through, the model didn't: the job starts anyway)
                    self.thought_through = False
                    self.assist.start_job("", self.heard, "", self.llm.value())
        if self.screens.adopt(self.client) > 0:
            self.shelf_version += 1
            print("OMX CARD: turn=" + String(self.turns) + " ms=" + String(Int(Float64(now_ns() - self.run_ns) / 1e6 + 0.5)) + " cards="
                  + String(len(self.screens.uis)) + " shape=" + self.screens.uis[len(self.screens.uis) - 1].summary(), flush=True)

    # --- the screen -----------------------------------------------------------------------------------------------

    def status(self) -> String:
        if self.note != "":
            return self.note
        if self.muted:
            return "Muted"
        if self.cloud_turn:
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

    def page(self, cards: Bool) -> View:
        """The screen without the cards' own buttons when `cards` is False: those are the agent's to show, not to press, so
        the tools it is offered (the app's buttons) don't change when a card appears (the model's prompt cache keeps)."""
        var lane = VoiceLane("Local · Qwen 27B", "Claude · cloud", self.cloud, LANE, self.lane_switch)
        var busy = self.loop.state() == LOOP_THINKING or self.loop.state() == LOOP_SPEAKING or self.cloud_turn or (self.llm and self.llm.value().running())
        var dock = VoiceDock(self.muted, self.typing, self.draft, MUTE, TYPE, STOP, DRAFT, SEND, busy)
        if not cards:
            return VoiceWork(OrbView(ORB_CANVAS, self.orb.version(), False), "", "", "", lane, List[View](), dock)
        if self.work:
            var shelf = self.assist.cards()  # (the to-do list, the job, the news: the assistant's own, then what the agent drew)
            for k in range(len(self.screens.uis) - 1, -1, -1):  # (newest on top)
                shelf.append(self.screens.view(k, self.client.state, self.shelf_version))
            return VoiceWork(OrbView(ORB_CANVAS, self.orb.version(), False), self.status(), self.heard, self.reply, lane, shelf^, dock)
        return VoiceHome(OrbView(ORB_CANVAS, self.orb.version(), True), "Hi, I'm omx.", self.status(), lane, VoiceChips(self.suggestions, CHIP), dock)

    def view(self) -> View:
        if self.cloud:
            return Overlay(self.page(True), RimView(RIM_CANVAS, 1)).grow().fill()
        return self.page(True)

    def draw(mut self, canvas: Int, mut surface: Surface):
        if canvas == ORB_CANVAS:
            self.orb.draw(surface, self.look.palette)
        elif canvas == RIM_CANVAS:
            draw_rim(surface, self.look.palette, self.cloud)
        else:
            self.screens.draw(canvas, surface, self.look.palette, self.client.state)
