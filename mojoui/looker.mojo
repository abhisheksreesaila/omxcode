# mojoui.looker: the agent's eyes on the camera (goal 77 M6, D-7770..D-7779). Its tool is `look`: "what am I looking at", "what
# should I do", "where is the X". This component owns everything behind it, so an app only composes it (as it composes Creator):
#
#   var looker = Looker(CANVAS0)                                  # the camera is this machine's, or the page's on the web host
#   # the agent's tools:  agent.set_tools(... + looker.tools(llm.vision))
#   #                     a call looker.handles(c.name) goes to looker.call(c.id, c.arguments)
#   # tick (30 ms):       looker.tick(llm)       (takes the frame, asks the model, reads its answer; never waits)
#   #                     for a in looker.take_answers(): agent.answer(a.id, a.content, a.untrusted)
#   #                     for line in looker.take_log(): print line
#   # the shelf:          looker.views() (newest first); draw(): looker.draw(canvas, surface, palette); looker.spot(canvas, name)
#   # the app ends:       looker.closing()
#
# One look: the camera is asked for a still (mojoui.camera: the page's rear camera on the web host, the machine's own camera
# elsewhere), the still goes to the model's own eyes in this process (mojoui.llm with its projector, on the background
# sequence so the conversation's cache keeps) with the question, the reply is read into boxes (mojoui.grounding), and a card
# shows the picture with labelled boxes (mojoui.sight); each box is a part named by its label, so a pointer can land on it. The
# tool's result tells the agent what was seen, by those labels, so what it says aloud names the things the card shows. The frame
# is shown on the card, written to one temporary file for the decoder and deleted when decoded; it is kept nowhere and sent
# nowhere. The camera is let go after 15 s without a look (the page's camera light goes out).
# What the model read from the picture is text from outside (a sign in the scene may say anything), so the result is fenced and
# `untrusted` (mojoui.trust): the agent can't be steered by it into anything that reaches out or changes things this turn.

from std.memory import ArcPointer
from std.os import getenv, makedirs, remove
from std.os.path import exists
from mojoui.app import Event
from mojoui.camera import Camera, CAM_FAILED
from mojoui.clock import now_ns
from mojoui.creator import Answer
from mojoui.canvas import Surface
from mojoui.grounding import Sight, parse_sight, look_messages, image_size
from mojoui.json import Json, json_string
from mojoui.llm import Llm, TEXT, DONE, ERROR
from mojoui.llmagent import AppTool, T_CALL
from mojoui.picture import Picture
from mojoui.sight import draw_sight, sight_spot
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.trust import fence
from mojoui.view import View, Card, Text, VStack, Canvas, HEADLINE, CAPTION, BODY, START

comptime WAIT_MS = 9000  # a still that hasn't come by then: the camera gives none
comptime IDLE_MS = 15_000
comptime ASK_MS = 60_000  # the model's own limit for one look
comptime MAX_CARDS = 6
comptime CANVAS_HEIGHT = 240


struct LookCard(Movable):
    var question: String
    var answer: String
    var sight: Sight
    var path: String  # the frame on disk until it is decoded
    var opening: Optional[Picture]
    var held: Optional[ArcPointer[Picture]]
    var pts_w: Float64  # the canvas's size in points as last drawn (spot() needs it)
    var pts_h: Float64
    var ms: Int

    def __init__(out self, question: String, var sight: Sight):
        self.question = question
        self.answer = String("")
        self.sight = sight^
        self.path = String("")
        self.opening = None
        self.held = None
        self.pts_w = 0.0
        self.pts_h = 0.0
        self.ms = 0


struct Looker(Movable):
    var camera: Camera
    var canvas_base: Int
    var cards: List[LookCard]
    var version: Int
    var font: Font
    var call_id: String  # the look in progress ("": none)
    var question: String
    var stage: Int  # 0 idle, 1 waiting for the still, 2 the model is reading it
    var t_ns: Int  # the look began
    var asked_ns: Int  # the model was asked
    var req: Int
    var reply: String
    var jpeg: List[UInt8]
    var width: Int
    var height: Int
    var answers: List[Answer]
    var log: List[String]
    var last_ns: Int
    var dir: String
    var serial: Int

    def __init__(out self, canvas_base: Int):
        self.camera = Camera()
        self.canvas_base = canvas_base
        self.cards = List[LookCard]()
        self.version = 0
        self.font = Font()
        self.call_id = String("")
        self.question = String("")
        self.stage = 0
        self.t_ns = 0
        self.asked_ns = 0
        self.req = 0
        self.reply = String("")
        self.jpeg = List[UInt8]()
        self.width = 0
        self.height = 0
        self.answers = List[Answer]()
        self.log = List[String]()
        self.last_ns = 0
        self.dir = getenv("XDG_RUNTIME_DIR", getenv("TMPDIR", "/tmp")) + "/mojoui-look"
        self.serial = 0

    def tools(self, vision: Bool) -> List[AppTool]:
        var out = List[AppTool]()
        if vision:
            out.append(AppTool(
                "look",
                "Look through the camera at what is in front of the person, now: 'what am I looking at', 'what should I do with this', "
                "'where is the X'. Takes a picture, studies it, and puts a card on the screen with the picture and labelled boxes round "
                "the things that matter. Returns what was seen and the labels of the boxes: answer in one or two spoken sentences, "
                "naming the things by exactly those labels (for example 'the banana is in the middle'); the card shows the rest.",
                '{"type":"object","properties":{"question":{"type":"string","description":"what the person wants to know about what the camera sees, in their words"}},"required":["question"]}',
                0,
                T_CALL,
            ))
        return out^

    def handles(self, name: String) -> Bool:
        return name == "look"

    def call(mut self, id: String, args: String):
        """The `look` tool was called: the answer comes from take_answers() when the model has read the picture."""
        if self.call_id != "":
            self.answers.append(Answer(id, '{"error":"already looking: wait for that to finish"}'))
            return
        var q = String("")
        try:
            var j = Json.parse(args)
            q = j.text(j.get(0, "question"))
        except:
            pass
        self.camera.snapshot()
        if self.camera.state() == CAM_FAILED:
            self.refuse(id, "I can't see: " + self.camera.problem)
            return
        self.call_id = id
        self.question = q
        self.stage = 1
        self.t_ns = now_ns()
        self.last_ns = self.t_ns

    def refuse(mut self, id: String, why: String):
        self.log.append("LOOK: failed why=" + why)
        self.answers.append(Answer(id, '{"error":' + json_string(why) + "}"))

    def take_answers(mut self) -> List[Answer]:
        var out = self.answers^
        self.answers = List[Answer]()
        return out^

    def take_log(mut self) -> List[String]:
        var out = self.log^
        self.log = List[String]()
        return out^

    def closing(mut self):
        self.camera.stop()
        for k in range(len(self.cards)):
            self.forget_file(k)

    def forget_file(mut self, k: Int):
        if self.cards[k].path != "" and exists(self.cards[k].path):
            try:
                remove(self.cards[k].path)
            except:
                pass
        self.cards[k].path = String("")

    # --- every tick -------------------------------------------------------------------------------------------------

    def tick(mut self, mut llm: Llm):
        if self.stage == 1:
            self.waiting(llm)
        elif self.stage == 2:
            self.reading(llm)
        else:
            if self.camera.wanted and self.last_ns > 0 and (now_ns() - self.last_ns) // 1_000_000 > IDLE_MS:
                self.camera.stop()
        self.land()

    def waiting(mut self, mut llm: Llm):
        var landed = self.camera.tick()
        if self.camera.state() == CAM_FAILED:
            self.finish_failed("I can't see: " + self.camera.problem)
            return
        if landed:
            self.jpeg = self.camera.jpeg.copy()
            var size = image_size(self.jpeg)
            self.width = size[0]
            self.height = size[1]
            try:
                self.reply = String("")
                self.req = llm.chat(look_messages(llm, self.jpeg, self.question), seq=1, max_tokens=500, temperature=0.0)
                self.stage = 2
                self.asked_ns = now_ns()
            except e:
                self.finish_failed("I couldn't look: " + String(e))
            return
        if (now_ns() - self.t_ns) // 1_000_000 > WAIT_MS:
            self.finish_failed("the camera gave no picture in " + String(WAIT_MS // 1000) + " seconds" + (" (the page's camera may need permission)" if self.camera.web else ""))

    def reading(mut self, mut llm: Llm):
        try:
            for e in llm.poll(self.req):
                if e.kind == TEXT:
                    self.reply += e.text
                elif e.kind == ERROR:
                    self.finish_failed("I couldn't read the picture: " + e.text)
                    return
                elif e.kind == DONE:
                    self.landed(llm, e.text)
                    return
        except e:
            self.finish_failed("I couldn't read the picture: " + String(e))
            return
        if (now_ns() - self.asked_ns) // 1_000_000 > ASK_MS:
            llm.cancel(self.req)
            self.finish_failed("the model took too long to read the picture")

    def landed(mut self, llm: Llm, reason: String):
        var sight = parse_sight(self.reply, self.width, self.height)
        if sight.problem != "" and len(sight.boxes) == 0 and sight.answer == "":
            self.finish_failed("I looked but couldn't make it out (" + sight.problem + ")")
            return
        var ms = (now_ns() - self.t_ns) // 1_000_000
        var read_ms = (now_ns() - self.asked_ns) // 1_000_000
        var answer = sight.answer
        var labels = sight.labels()
        var boxes = len(sight.boxes)
        var where = String("")  # (each box as label:x0,y0,x1,y1 in the frame's pixels: what a checker compares with the truth)
        for b in sight.boxes:
            where += ("|" if where != "" else "") + b.label.replace(" ", "_") + ":" + String(Int(b.x0)) + "," + String(Int(b.y0)) + "," + String(Int(b.x1)) + "," + String(Int(b.y1))
        var card = LookCard(self.question, sight^)
        card.answer = answer
        card.ms = ms
        try:
            makedirs(self.dir, exist_ok=True)
            self.serial += 1
            card.path = self.dir + "/look-" + String(self.serial) + ".jpg"
            var f = open(card.path, "w")
            f.write_bytes(Span(self.jpeg))
            f.close()
            card.opening = Picture.opening(card.path)
        except err:
            self.log.append("LOOK: couldn't show the picture why=" + String(err))
        self.cards.append(card^)
        while len(self.cards) > MAX_CARDS:
            self.forget_file(0)
            _ = self.cards.pop(0)
        self.version += 1
        self.log.append("LOOK: ms=" + String(ms) + " read_ms=" + String(read_ms) + " frame_ms=" + String((self.asked_ns - self.t_ns) // 1_000_000)
                        + " image_ms=" + String(Int(llm.image_ms() + 0.5)) + " image_tokens=" + String(llm.image_tokens()) + " frame=" + String(self.width) + "x"
                        + String(self.height) + " boxes=" + String(boxes) + " where=" + where + " labels=" + labels + " source=" + self.camera.source() + " text=" + answer)
        var said = "What the camera shows: " + fence("camera", answer) + "\nLabels of the boxes on the card: " + fence("camera", labels if labels != "" else String("none"))
        self.answers.append(Answer(self.call_id, said + "\nThe card with the picture and the labelled boxes is on the screen: say the answer in one or two sentences, naming things by those labels.", True))
        self.call_id = String("")
        self.stage = 0
        self.last_ns = now_ns()

    def finish_failed(mut self, why: String):
        var id = self.call_id
        self.refuse(id, why)
        self.call_id = String("")
        self.stage = 0
        self.last_ns = now_ns()
        self.camera.stop()

    def land(mut self):
        """A frame decoded on its thread is taken, and its file deleted."""
        for k in range(len(self.cards)):
            if not self.cards[k].opening:
                continue
            if not self.cards[k].opening.value().poll():
                continue
            var pic = self.cards[k].opening.take()
            self.forget_file(k)
            if pic.problem == "":
                self.cards[k].held = ArcPointer(pic^)
            self.version += 1

    # --- the screen -------------------------------------------------------------------------------------------------

    def views(self) -> List[View]:
        """The cards, newest first."""
        var out = List[View]()
        for k in range(len(self.cards) - 1, -1, -1):
            var rows = List[View]()
            rows.append(Text("Looking", CAPTION))
            rows.append(Text(self.cards[k].answer if self.cards[k].answer != "" else self.cards[k].question, HEADLINE))
            rows.append(Canvas(self.canvas_base + k, self.version).passthrough().fill().height(CANVAS_HEIGHT).tag("look"))
            out.append(Card(rows^, spacing=8).fill().tag("look-card"))
        return out^

    def owns_canvas(self, canvas: Int) -> Bool:
        return canvas >= self.canvas_base and canvas < self.canvas_base + len(self.cards)

    def draw(mut self, canvas: Int, mut s: Surface, p: Palette):
        var k = canvas - self.canvas_base
        if k < 0 or k >= len(self.cards):
            return
        self.cards[k].pts_w = Float64(s.width) / s.scale
        self.cards[k].pts_h = Float64(s.height) / s.scale
        if self.cards[k].held:
            ref pic = self.cards[k].held.value()[]
            draw_sight(s, pic.pixels, pic.width, pic.height, self.cards[k].sight.boxes, self.font, p, 0)
        else:
            s.fill(p.card)

    def spot(self, canvas: Int, name: String) -> Tuple[Float64, Float64]:
        """Where the box labelled `name` is on the card's canvas, in points from its top-left ((-1, -1): none)."""
        var k = canvas - self.canvas_base
        if k < 0 or k >= len(self.cards):
            return (-1.0, -1.0)
        ref c = self.cards[k]
        return sight_spot(c.sight.boxes, c.sight.width, c.sight.height, c.pts_w, c.pts_h, name)
