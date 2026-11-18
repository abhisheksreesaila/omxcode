# mojoui.comic: a four-panel comic as a plan an agent hands in (goal 72 M6, D-7282). The model writes the plan as the
# arguments of a tool call: a title, ONE description of the hero that every panel repeats (so a painter draws the same
# character each time), and four panels of caption + scene. The plan is checked (a model's JSON is data), and turned into
# the prompts the image model gets: the same style, the same hero, one scene, and one seed for the strip (a steadier look).
#
#   var plan = ComicPlan.parse(args_json)           # raises with a message the model can act on
#   plan.prompt(2)                                  # "comic book panel, bold clean ink outlines, … . <hero>. <scene 3>"
#   comic_tool()                                    # the tool as the model sees it: name, words, JSON Schema
#
# Drawing the panels one by one, and the card that fills in, are mojoui.creator's.

from mojoui.json import Json
from mojoui.llmagent import AppTool, T_CALL

comptime PANELS = 4
comptime COMIC_STYLE = (
    "comic book panel, bold clean ink outlines, flat vivid colours, expressive faces, simple background, "
    "no text, no speech bubbles, no letters"
)
comptime PICTURE_STYLE = "Beautiful, detailed, good composition."
comptime MAX_CAPTION = 140
comptime MAX_TITLE = 80
comptime MAX_PROMPT = 600


struct ComicPlan(Copyable, Movable):
    var title: String
    var character: String
    var captions: List[String]
    var scenes: List[String]

    def __init__(out self):
        self.title = ""
        self.character = ""
        self.captions = List[String]()
        self.scenes = List[String]()

    @staticmethod
    def parse(args: String) raises -> ComicPlan:
        """The plan from a tool call's arguments: {"title", "character", "panels": [{"caption", "scene"} × 4]}. Raises with
        what is wrong in words the model can fix (it hears the message as the tool's result)."""
        var j = Json.parse(args)
        var plan = ComicPlan()
        plan.title = String(j.text(j.get(0, "title")).strip())
        plan.character = String(j.text(j.get(0, "character")).strip())
        if plan.character == "":
            raise Error("the plan needs a \"character\": how the hero looks (species or person, colours, clothes), repeated in every panel")
        var panels = j.get(0, "panels")
        if j.size(panels) != PANELS:
            raise Error("the plan needs exactly " + String(PANELS) + " panels, each {\"caption\", \"scene\"}; this one has " + String(j.size(panels)))
        for i in range(PANELS):
            var p = j.at(panels, i)
            var caption = String(j.text(j.get(p, "caption")).strip())
            var scene = String(j.text(j.get(p, "scene")).strip())
            if scene == "":
                raise Error("panel " + String(i + 1) + " has no \"scene\": say who is doing what, where")
            plan.captions.append(_cut(caption, MAX_CAPTION))
            plan.scenes.append(_cut(scene, MAX_PROMPT))
        plan.title = _cut(plan.title, MAX_TITLE) if plan.title != "" else String("A comic")
        plan.character = _cut(plan.character, MAX_PROMPT)
        return plan^

    def prompt(self, i: Int) -> String:
        """What the image model is asked for panel i (0-based): the style, the hero, the scene."""
        return String(COMIC_STYLE) + ". " + self.character + ". " + self.scenes[i]


def _cut(text: String, most: Int) -> String:
    """`text` at most `most` bytes, never through a character."""
    if text.byte_length() <= most:
        return text
    var n = most
    var b = text.as_bytes()
    while n > 0 and (Int(b[n]) & 0xC0) == 0x80:
        n -= 1
    return String(text[byte = :n])


def picture_prompt(subject: String) -> String:
    return _cut(String(subject.strip()), MAX_PROMPT) + ". " + String(PICTURE_STYLE)


def comic_tool() -> AppTool:
    return AppTool(
        "make_comic",
        "Draw a four-panel comic strip for the person on the picture card: use it for 'make a comic', 'draw a comic', 'a comic about…'. "
        "You write the plan: a short title, ONE concrete description of the hero (species or person, colours, clothing) that is "
        "repeated in every panel, and four panels, each a caption under 14 words and a scene saying only what is visible "
        "(who, doing what, where), never text or speech bubbles. The strip is drawn panel by panel on its own card, about 20 "
        "seconds; do not describe it again and do not call render_ui for it.",
        '{"type":"object","properties":{"title":{"type":"string"},"character":{"type":"string","description":"how the hero looks, reused in every panel"},'
        '"panels":{"type":"array","minItems":4,"maxItems":4,"items":{"type":"object","properties":{"caption":{"type":"string"},"scene":{"type":"string"}},'
        '"required":["caption","scene"]}}},"required":["title","character","panels"]}',
        0,
        T_CALL,
    )


def picture_tool() -> AppTool:
    return AppTool(
        "draw_picture",
        "Draw one picture for the person on its own card: use it for 'draw me…', 'a picture of…', 'illustrate…'. Describe the "
        "subject in a sentence with its look and setting. It takes a few seconds and appears by itself; do not call render_ui for it.",
        '{"type":"object","properties":{"subject":{"type":"string","description":"what to draw, in a descriptive sentence"}},"required":["subject"]}',
        0,
        T_CALL,
    )
