# mojoui.grounding: what is in a picture and where, asked of the model's own eyes (goal 77 M6, D-7760..D-7764). The model
# (mojoui.llm with a vision projector) answers a question about a picture and names the things that matter with boxes; this
# turns its words into boxes in the picture's own pixels, validated, so a card can draw them and a pointer can land on them.
#
#   var sight = ground(llm, jpeg_bytes, "where is the banana?")      # blocking (tests, tools); raises when the model can't answer
#   sight.answer        # "The banana is in the middle, between the cup and the bottle."
#   for b in sight.boxes: b.label, b.x0, b.y0, b.x1, b.y1            # pixels of the picture, top-left origin
#   sight.find("banana")                                              # the box whose label is (or holds) that word, else -1
#
# An app that must not block builds the request itself and polls it: look_messages() is the user message, parse_sight() reads
# the reply (mojoui.looker does this).
#
# Coordinates (verified, D-7760): Qwen3.8's vision answers in 0-1000 relative coordinates, [x1, y1, x2, y2], whatever the
# picture's size (the Qwen-VL convention). On the 1280x720 test scene the banana drawn at pixels 550,222..856,563 (0-1000:
# 430,308..669,782) came back as 429,306..654,744, the mug's 171,275..422,484 as 131,381..314,665, all within a few
# per cent of the truth. They are converted here to pixels. A reply whose numbers go past 1000 can only
# be in pixels, and is read as such. What the model may get wrong is validated away: a box needs four numbers in the picture,
# x1 > x0 and y1 > y0, at least 1% of the picture each way, a label of 1..40 characters; at most 8 boxes; the same label twice
# at nearly the same place counts once.

from mojoui.json import Json, J_ARRAY, J_OBJECT, J_NUMBER, J_STRING, json_string
from mojoui.llm import Llm

comptime SCALE = 1000.0  # the model's relative coordinates
comptime MAX_BOXES = 8
comptime MAX_LABEL = 40
comptime MIN_SIDE = 0.01  # of the picture


@fieldwise_init
struct Box(Copyable, Movable):
    var label: String
    var x0: Float64
    var y0: Float64
    var x1: Float64
    var y1: Float64

    def area(self) -> Float64:
        return max(self.x1 - self.x0, 0.0) * max(self.y1 - self.y0, 0.0)

    def cx(self) -> Float64:
        return (self.x0 + self.x1) / 2.0

    def cy(self) -> Float64:
        return (self.y0 + self.y1) / 2.0


def iou(a: Box, b: Box) -> Float64:
    """Intersection over union of two boxes (0 when they don't touch)."""
    var w = min(a.x1, b.x1) - max(a.x0, b.x0)
    var h = min(a.y1, b.y1) - max(a.y0, b.y0)
    if w <= 0 or h <= 0:
        return 0.0
    var inter = w * h
    return inter / (a.area() + b.area() - inter)


struct Sight(Movable):
    """What the model saw: its answer and the boxes (pixels), or why there are none."""

    var answer: String
    var boxes: List[Box]
    var width: Int
    var height: Int
    var raw: String  # the model's own words
    var dropped: Int  # boxes it gave that failed validation
    var problem: String  # "" when the reply was read

    def __init__(out self, width: Int, height: Int):
        self.answer = String("")
        self.boxes = List[Box]()
        self.width = width
        self.height = height
        self.raw = String("")
        self.dropped = 0
        self.problem = String("")

    def find(self, word: String) -> Int:
        """The box named `word`: an exact label (any case), else the first label that holds the word or is held by it."""
        var w = word.lower()
        for k in range(len(self.boxes)):
            if self.boxes[k].label.lower() == w:
                return k
        for k in range(len(self.boxes)):
            var l = self.boxes[k].label.lower()
            if w.byte_length() > 0 and (l.find(w) >= 0 or w.find(l) >= 0):
                return k
        return -1

    def labels(self) -> String:
        var out = String("")
        for b in self.boxes:
            out += (", " if out.byte_length() > 0 else "") + b.label
        return out


def look_prompt(question: String) -> String:
    """The words that make the model answer in the shape parse_sight reads."""
    var q = String("What am I looking at, and what should I do?")
    if String(question.strip()) != "":
        q = question
    return (
        'The person asks: ' + json_string(q) + '. Reply with compact JSON only, on one line: {"answer": "<one or two short sentences that '
        'name the things by the same labels you give them>", "objects": [{"label": "<one or two words>", "bbox_2d": [x1, y1, x2, y2]}]}. '
        "bbox_2d is in 0-1000 coordinates relative to the picture's width and height. List the objects the question is about or "
        "the person needs, at most 5, the most relevant first."
    )


def look_messages(llm: Llm, image: Span[UInt8, _], question: String) raises -> String:
    """The messages (a JSON array) that ask the model `question` about the encoded picture `image` (jpeg or png)."""
    return "[" + llm.image_user(image, look_prompt(question)) + "]"


def _number(j: Json, node: Int) -> Optional[Float64]:
    if j.kind(node) != J_NUMBER:
        return None
    return j.real(node)


def parse_sight(text: String, width: Int, height: Int) -> Sight:
    """Reads the model's reply (JSON, maybe inside a code fence or after some words) into a Sight in pixels."""
    var sight = Sight(width, height)
    sight.raw = text
    var open = text.find("{")
    var close = text.rfind("}")
    var bare = text.find("[")
    var j = Json()
    var objects = -1
    try:
        if open >= 0 and close > open and (bare < 0 or open < bare):
            j = Json.parse(String(text[byte = open : close + 1]))
            sight.answer = j.text(j.get(0, "answer"))
            objects = j.get(0, "objects")
        elif bare >= 0:  # a bare list of boxes
            var end = text.rfind("]")
            if end > bare:
                j = Json.parse(String(text[byte = bare : end + 1]))
                objects = 0
        else:
            sight.problem = "the model didn't answer in JSON"
            return sight^
    except e:
        sight.problem = "the model's JSON couldn't be read: " + String(e)
        return sight^
    if objects < 0 or j.kind(objects) != J_ARRAY:
        sight.problem = "the answer has no objects list" if sight.answer == "" else ""
        return sight^
    # pixels or relative: any number past the scale (with some room for a box that touches the edge) can only be pixels
    var largest = 0.0
    for i in range(j.size(objects)):
        var box = j.get(j.at(objects, i), "bbox_2d")
        for c in range(j.size(box)):
            largest = max(largest, j.real(j.at(box, c)))
    var in_pixels = largest > SCALE * 1.02
    var sx = Float64(width) / (Float64(width) if in_pixels else SCALE)
    var sy = Float64(height) / (Float64(height) if in_pixels else SCALE)
    for i in range(j.size(objects)):
        var o = j.at(objects, i)
        var label = String(j.text(j.get(o, "label")).strip())
        var box = j.get(o, "bbox_2d")
        if len(label.as_bytes()) == 0 or len(label.as_bytes()) > MAX_LABEL or j.size(box) != 4:
            sight.dropped += 1
            continue
        var ok = True
        var v = List[Float64]()
        for c in range(4):
            var n = _number(j, j.at(box, c))
            if not n:
                ok = False
                break
            v.append(n.value())
        if not ok:
            sight.dropped += 1
            continue
        var b = Box(String(label), v[0] * sx, v[1] * sy, v[2] * sx, v[3] * sy)
        b.x0 = max(b.x0, 0.0)
        b.y0 = max(b.y0, 0.0)
        b.x1 = min(b.x1, Float64(width))
        b.y1 = min(b.y1, Float64(height))
        if b.x1 - b.x0 < MIN_SIDE * Float64(width) or b.y1 - b.y0 < MIN_SIDE * Float64(height):
            sight.dropped += 1
            continue
        var twin = False
        for other in sight.boxes:
            if other.label.lower() == b.label.lower() and iou(other, b) > 0.8:
                twin = True
        if twin or len(sight.boxes) >= MAX_BOXES:
            sight.dropped += 1
            continue
        sight.boxes.append(b^)
    return sight^


def image_size(data: Span[UInt8, _]) -> Tuple[Int, Int]:
    """Width and height of a PNG or JPEG file's bytes ((0, 0) when it is neither)."""
    var n = len(data)
    if n > 24 and data[0] == 137 and data[1] == 80 and data[2] == 78 and data[3] == 71:
        var w = (Int(data[16]) << 24) | (Int(data[17]) << 16) | (Int(data[18]) << 8) | Int(data[19])
        var h = (Int(data[20]) << 24) | (Int(data[21]) << 16) | (Int(data[22]) << 8) | Int(data[23])
        return (w, h)
    if n > 4 and data[0] == 0xFF and data[1] == 0xD8:
        var i = 2
        while i + 9 < n:
            if data[i] != 0xFF:
                i += 1
                continue
            var m = Int(data[i + 1])
            if m == 0xFF:
                i += 1
                continue
            if m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC:  # a frame header
                var h = (Int(data[i + 5]) << 8) | Int(data[i + 6])
                var w = (Int(data[i + 7]) << 8) | Int(data[i + 8])
                return (w, h)
            if m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7):
                i += 2
                continue
            i += 2 + ((Int(data[i + 2]) << 8) | Int(data[i + 3]))
    return (0, 0)


def ground(llm: Llm, image: Span[UInt8, _], question: String, seq: Int = 1) raises -> Sight:
    """Asks the model about the picture and waits for the answer (a test or a tool on a worker; an app polls instead): a Sight
    in the picture's pixels. Runs on sequence `seq` (1: background) so the conversation's prompt cache survives."""
    var size = image_size(image)
    if size[0] <= 0:
        raise Error("grounding: not a JPEG or PNG")
    var reply = llm.complete(look_messages(llm, image, question), seq=seq, max_tokens=500, temperature=0.0)
    return parse_sight(reply.text, size[0], size[1])
