# mojoui.jam: a brainstorm partner that grows a mind map (goal 82 M6; Personal Note's jam_brain.py, F-086/F-092, ported rule
# for rule). One brain call turns the map plus what was just said into map edits, validated whole: the brain may only add
# branches, react to a branch (thumbs up or down with a reason) and offer ghosts (faint suggestions the person accepts or
# lets go). Anything that removes, renames or moves a node, names an unknown node or reuses an id is refused whole
# (JamError), so the map is never half-changed; soft limits (too long, too many) trim and say why in `dropped`.
#
#   var user = jam_prompt(map_doc, said, ghosts_waiting)          # the words for the brain (JAM_SYSTEM is the system prompt)
#   var edits = parse_jam(reply, map_doc)                         # raises with the web's own words
#   var doc = apply_jam(map_doc, edits, stamp)                    # the map document with the edits in it (applyJamEdits)
#   edits.wire()                                                  # the web route's JSON: [{"op":"add_branch","parentId":…}, …]
#
# The map document is Personal Note's mind-map JSON (rootId, nodes [{id, parentId, text, x, y, color, …}], ghosts).
# Known difference from Python: is_emoji() reads emoji and symbol code-point ranges, not Unicode's category table (D-8706).

from mojoui.json import Json, json_string, J_STRING, J_NUMBER, J_ARRAY, J_OBJECT, J_NULL

comptime MAX_EDITS = 12
comptime MAX_GHOSTS = 3
comptime MAX_WORDS = 4
comptime MAX_TEXT = 40
comptime MAX_REASON = 80
comptime MAX_EMOJI = 8

comptime JAM_SYSTEM = """You are the quiet partner in a spoken brainstorm, growing a Tony Buzan mind map.
You get the current map (JSON) and what the person just said. Answer with JSON only, no prose, no code fence.

Buzan rules:
- The centre is the central idea. Main branches (children of the centre) are the big themes, a few of them.
- One keyword (at most 4 words) per branch, never a sentence. Put detail on sub-branches, one idea each.
- Use an emoji only where it makes a branch easier to find; leave it out otherwise.
- Reactions are short: a thumbs up or down on an existing branch with a reason under 80 characters.
- Offer 1 to 3 ghosts: faint "what about..." branches the person may accept or ignore, each with a short why.
- Add only what was said or what follows closely from it. Do not repeat branches already on the map.

You can only add and react. Never remove, rename or move a node.

Answer exactly in this shape (up to 12 edits in all):
{"edits": [
  {"op": "add_branch", "parent_id": "<existing node id or an id you gave earlier in this answer>", "text": "keyword", "emoji": "", "id": "<optional new id like n1>"},
  {"op": "react", "node_id": "<existing node id>", "vote": "up", "reason": "short reason"},
  {"op": "ghost", "parent_id": "<node id>", "text": "keyword", "why": "short reason"}
]}"""


@fieldwise_init
struct JamEdit(Copyable, Movable):
    var op: String  # add_branch | react | ghost
    var anchor: String  # add_branch / ghost: the parent's id; react: the node's id
    var text: String  # add_branch / ghost: the words
    var emoji: String  # add_branch
    var id: String  # add_branch: the brain's own id for it ("" none), so later edits can hang off it
    var vote: String  # react: up | down
    var reason: String  # react: why; ghost: why


struct JamEdits(Copyable, Movable):
    var edits: List[JamEdit]
    var dropped: List[String]  # why edits were trimmed

    def __init__(out self):
        self.edits = List[JamEdit]()
        self.dropped = List[String]()

    def wire(self) -> String:
        """The web route's JSON for these edits (routes.py jam_turn_edits)."""
        var out = String("[")
        for k in range(len(self.edits)):
            ref e = self.edits[k]
            if k > 0:
                out += ", "
            if e.op == "add_branch":
                out += '{"op": "add_branch", "parentId": ' + json_string(e.anchor) + ', "text": ' + json_string(e.text) + ', "emoji": ' + json_string(e.emoji) + ', "id": ' + json_string(e.id) + "}"
            elif e.op == "react":
                out += '{"op": "react", "nodeId": ' + json_string(e.anchor) + ', "vote": ' + json_string(e.vote) + ', "reason": ' + json_string(e.reason) + "}"
            else:
                out += '{"op": "ghost", "parentId": ' + json_string(e.anchor) + ', "text": ' + json_string(e.text) + ', "why": ' + json_string(e.reason) + "}"
        return out + "]"


def _chars(s: String) -> Int:
    var n = 0
    for _ in s.codepoints():
        n += 1
    return n


def _word_count(s: String) -> Int:
    var n = 0
    var inside = False
    for b in s.as_bytes():
        var space = b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12
        if not space and not inside:
            n += 1
        inside = not space
    return n


def _strip(s: String) -> String:
    return String(s.strip())


def is_emoji(text: String) -> Bool:
    """Only symbols, emoji modifiers and joiners: no letters, digits, spaces or punctuation (at most 8 code points)."""
    var n = _chars(text)
    if n == 0 or n > MAX_EMOJI:
        return False
    for c in text.codepoints():
        var v = Int(c)
        if v == 0x200B or v == 0x200C or v == 0xFEFF:
            return False
        var ok = ((v >= 0x1F000 and v <= 0x1FAFF) or (v >= 0x2600 and v <= 0x27BF) or (v >= 0x2B00 and v <= 0x2BFF) or (v >= 0x2300 and v <= 0x23FF)
                  or (v >= 0x2190 and v <= 0x21FF and v > 0x2194) or v == 0x200D or v == 0xFE0F or v == 0xFE0E or v == 0x20E3 or (v >= 0xE0020 and v <= 0xE007F)
                  or v == 0xA9 or v == 0xAE or v == 0x2122 or v == 0x2139 or v == 0x3030 or v == 0x303D or v == 0x3297 or v == 0x3299
                  or (v >= 0x1F3FB and v <= 0x1F3FF) or (v >= 0x0300 and v <= 0x036F) or (v >= 0x25A0 and v <= 0x25FF and v != 0x25F8))
        if not ok:
            return False
    return True


def _too_long(text: String, limit: Int, what: String, words: Int = 0) -> String:
    if _chars(text) > limit:
        return what + " longer than " + String(limit) + " characters"
    if words > 0 and _word_count(text) > words:
        return what + " longer than " + String(words) + " words"
    return ""


def _text(j: Json, item: Int, key: String, what: String, required: Bool = True) raises -> String:
    var n = j.get(item, key)
    if n < 0 or j.kind(n) == J_NULL or (j.kind(n) == J_STRING and j.text(n) == ""):
        if required:
            raise Error("The brain left out the " + what + ".")
        return ""
    if j.kind(n) != J_STRING:
        raise Error("The brain gave a " + what + " that is not text.")
    return _strip(j.text(n))


def _extract(raw: String) raises -> Json:
    var text = _strip(raw)
    if text.startswith("```") and text.endswith("```") and text.byte_length() >= 6:  # ^```(?:json)?\s*(.*?)\s*```$
        var inner = String(text[byte = 3 : text.byte_length() - 3])
        if inner.startswith("json"):
            var _cut1 = String(inner[byte = 4:])
            inner = _cut1^
        text = _strip(inner)
    try:
        return Json.parse(text)
    except:
        pass
    var start = text.find("{")
    var end = text.rfind("}")
    if start != -1 and end > start:
        try:
            return Json.parse(String(text[byte = start : end + 1]))
        except:
            pass
    raise Error("The brain did not answer with map edits (it did not return JSON).")


def _id_text(j: Json, n: Int) -> String:
    """str(node["id"]): a string as it is, a whole number as Python prints it."""
    if j.kind(n) == J_STRING:
        return j.text(n)
    if j.kind(n) == J_NUMBER and j.is_whole(n):
        return String(j.number(n))
    return j.dump(n)


def _has(xs: List[String], x: String) -> Bool:
    for y in xs:
        if y == x:
            return True
    return False


def _drop(mut xs: List[String], x: String):
    var out = List[String]()
    for y in xs:
        if y != x:
            out.append(y)
    xs = out^


def parse_jam(raw: String, map_doc: String) raises -> JamEdits:
    """The brain's answer, validated against the map (jam_brain.parse_edits): hard rules raise with the web's own
    message; soft limits trim and are reported in `dropped`."""
    var j = _extract(raw)
    var items = j.get(0, "edits") if j.kind(0) == J_OBJECT else -1
    if items < 0 or j.kind(items) != J_ARRAY:
        raise Error("The brain's answer has no list of edits.")
    var out = JamEdits()
    var count = j.size(items)
    for number in range(MAX_EDITS + 1, count + 1):
        out.dropped.append("edit " + String(number) + " cut: at most " + String(MAX_EDITS) + " edits are kept")
    count = min(count, MAX_EDITS)
    var m = Json.parse(map_doc)
    var known = List[String]()
    var nodes = m.get(0, "nodes")
    if nodes >= 0 and m.kind(nodes) == J_ARRAY:
        for k in range(m.size(nodes)):
            var idn = m.get(m.at(nodes, k), "id")
            if idn >= 0:
                known.append(_id_text(m, idn))
    var existing = known.copy()
    var lost = List[String]()
    var ghosts = 0
    for k in range(count):
        var number = k + 1
        var item = j.at(items, k)
        if j.kind(item) != J_OBJECT:
            raise Error("The brain gave an edit that is not an object.")
        var opn = j.get(item, "op")
        if opn < 0 or j.kind(opn) != J_STRING:
            raise Error("The brain gave an edit whose op is not text.")
        var op = j.text(opn)
        if op != "add_branch" and op != "react" and op != "ghost":
            raise Error('The brain tried "' + op + '", which is not allowed: it may only add, react or suggest.')
        var an = j.get(item, "node_id" if op == "react" else "parent_id")
        if an < 0 or j.kind(an) != J_STRING:
            raise Error("The brain gave an edit that names its node in a way that is not text.")
        var anchor = j.text(an)
        var new_id = _text(j, item, "id", "branch id", False) if op == "add_branch" else String("")
        if new_id != "" and _has(existing, new_id):
            raise Error("The brain reused the id '" + new_id + "', which would replace an existing node.")
        if _has(lost, anchor):
            out.dropped.append("edit " + String(number) + " dropped: it hangs off a dropped branch")
            if new_id != "":
                lost.append(new_id)
            continue
        if not _has(known, anchor):
            raise Error("The brain used an unknown node ('" + anchor + "').")
        if op == "add_branch":
            var text = _text(j, item, "text", "branch text")
            var emoji = _text(j, item, "emoji", "emoji", False)
            if emoji != "" and not is_emoji(emoji):
                out.dropped.append("edit " + String(number) + ": emoji ignored, it is not an emoji")
                emoji = ""
            var problem = _too_long(text, MAX_TEXT, "text")
            if problem == "":
                problem = _too_long(text, MAX_TEXT, "text", MAX_WORDS)
            if problem != "":
                out.dropped.append("edit " + String(number) + " dropped: " + problem)
                if new_id != "":
                    lost.append(new_id)
                continue
            out.edits.append(JamEdit("add_branch", anchor, text, emoji, new_id, "", ""))
            if new_id != "":
                _drop(lost, new_id)
                known.append(new_id)
                existing.append(new_id)
        elif op == "react":
            var vn = j.get(item, "vote")
            var vote = j.text(vn) if vn >= 0 and j.kind(vn) == J_STRING else String("")
            if vote != "up" and vote != "down":
                raise Error('The brain\'s reaction must be "up" or "down".')
            var reason = _text(j, item, "reason", "reaction reason")
            var problem = _too_long(reason, MAX_REASON, "reason")
            if problem != "":
                out.dropped.append("edit " + String(number) + " dropped: " + problem)
                continue
            out.edits.append(JamEdit("react", anchor, "", "", "", vote, reason))
        else:
            var text = _text(j, item, "text", "suggestion text")
            var why = _text(j, item, "why", "suggestion reason")
            var problem = _too_long(text, MAX_TEXT, "text")
            if problem == "":
                problem = _too_long(text, MAX_TEXT, "text", MAX_WORDS)
            if problem == "":
                problem = _too_long(why, MAX_REASON, "reason")
            if problem != "":
                out.dropped.append("edit " + String(number) + " dropped: " + problem)
                continue
            if ghosts >= MAX_GHOSTS:
                out.dropped.append("edit " + String(number) + " dropped: only " + String(MAX_GHOSTS) + " suggestions are kept")
                continue
            ghosts += 1
            out.edits.append(JamEdit("ghost", anchor, text, "", "", "", why))
    if count > 0 and len(out.edits) == 0:
        raise Error("Nothing usable was left in the brain's answer after trimming it.")
    return out^


def jam_prompt(map_doc: String, transcript: String, waiting: List[String]) raises -> String:
    """The user message for the brain (build_user_prompt): the map's outline, the suggestions still waiting, the words."""
    var m = Json.parse(map_doc)
    var outline = String("[")
    var nodes = m.get(0, "nodes")
    if nodes >= 0 and m.kind(nodes) == J_ARRAY:
        for k in range(m.size(nodes)):
            var n = m.at(nodes, k)
            var pid = m.get(n, "parentId")
            if k > 0:
                outline += ", "
            outline += '{"id": ' + json_string(_id_text(m, m.get(n, "id"))) + ', "parent_id": ' + (json_string(m.text(pid)) if pid >= 0 and m.kind(pid) == J_STRING else String("null")) + ', "text": ' + json_string(m.text(m.get(n, "text"))) + "}"
    outline += "]"
    var wait = String("")
    for k in range(len(waiting)):
        wait += ("; " if k > 0 else "") + waiting[k]
    if wait != "":
        wait = "Waiting suggestions (do not repeat): " + wait + "\n"
    var title = m.get(0, "title")
    var root = m.get(0, "rootId")
    return ("Mind map title: " + (m.text(title) if title >= 0 else String("")) + "\n" + "Centre node id: " + (m.text(root) if root >= 0 else String("")) + "\n"
            + "Map (nodes):\n" + outline + "\n" + wait + "\n" + 'The person just said:\n"""\n' + _strip(transcript) + '\n"""\n\nJSON only.')


def _same_words(a: String, b: String) -> Bool:
    return _strip(a).lower() == _strip(b).lower()


comptime _BRANCH_COLORS = ["#ef684b", "#efad28", "#65ae4f", "#2d9c91", "#3d8fe8", "#8c67cf", "#d85da8", "#5e6570"]  # (mindmap/model.js)


def _num(v: Float64) -> String:
    """A coordinate as JavaScript writes it (a whole number without ".0")."""
    if v == Float64(Int(v)):
        return String(Int(v))
    return String(v)


def apply_jam(map_doc: String, edits: JamEdits, stamp: String) raises -> String:
    """The map with one brain turn in it (mindmap/jam.js applyJamEdits): new branches under their parents (placed below
    their siblings, a main branch in a colour its siblings don't use), a reaction's vote and reason on its node, ghosts
    in the document's `ghosts` (the newest three, none repeating words already there). Nothing is removed, renamed or
    moved. `stamp` makes the new ids unique (the web's Date.now() in base 36)."""
    var m = Json.parse(map_doc)
    var nodes = m.get(0, "nodes")
    var root = m.text(m.get(0, "rootId"))
    var ids = List[String]()
    var parents = List[String]()
    var texts = List[String]()
    var xs = List[Float64]()
    var ys = List[Float64]()
    var colors = List[String]()
    var fonts = List[String]()
    var curves = List[String]()
    var dflt = m.get(0, "defaultPresentation")
    var presentation = "branch" if dflt >= 0 and m.text(dflt) == "branch" else "box"
    for k in range(m.size(nodes)):
        var n = m.at(nodes, k)
        ids.append(_id_text(m, m.get(n, "id")))
        var p = m.get(n, "parentId")
        parents.append(m.text(p) if p >= 0 and m.kind(p) == J_STRING else String(""))
        texts.append(m.text(m.get(n, "text")))
        xs.append(m.real(m.get(n, "x")))
        ys.append(m.real(m.get(n, "y")))
        var c = m.get(n, "color")
        colors.append(m.text(c) if c >= 0 else String(""))
        var f = m.get(n, "font")
        fonts.append(m.text(f) if f >= 0 and m.kind(f) == J_STRING and m.text(f) != "" else String("hand"))
        var cv = m.get(n, "curve")
        curves.append(m.dump(cv) if cv >= 0 and m.kind(cv) != J_NULL else String("78"))
    var added = List[String]()  # the new nodes' JSON
    var votes = List[Tuple[Int, String, String]]()  # (node index, vote, reason)
    var ghosts = List[String]()  # the document's ghosts, as JSON objects, oldest first
    var gtexts = List[String]()
    var g = m.get(0, "ghosts")
    if g >= 0 and m.kind(g) == J_ARRAY:
        for k in range(m.size(g)):
            ghosts.append(m.dump(m.at(g, k)))
            gtexts.append(m.text(m.get(m.at(g, k), "text")))
    var handles = List[Tuple[String, String]]()
    for k in range(len(edits.edits)):
        ref e = edits.edits[k]
        var anchor = e.anchor
        for h in handles:
            if h[0] == anchor:
                anchor = h[1]
        var at = -1
        for q in range(len(ids)):
            if ids[q] == anchor:
                at = q
        if at < 0:
            continue
        if e.op == "add_branch":  # (model.js makeNode, then jam.js place)
            var siblings = 0
            var used = List[String]()
            for q in range(len(ids)):
                if parents[q] == anchor:
                    siblings += 1
                    used.append(colors[q])
            var depth = 1
            var up = parents[at]
            var hops = 0
            while up != "" and hops < 10000:
                depth += 1
                hops += 1
                var nxt = String("")
                for q in range(len(ids)):
                    if ids[q] == up:
                        nxt = parents[q]
                up = nxt
            var side = (-1.0 if siblings % 2 == 1 else 1.0) if anchor == root else (-1.0 if xs[at] < 0 else 1.0)
            var position = Float64(siblings) - Float64(siblings - 1) / 2
            var x = xs[at] + side * max(190.0, 330.0 - Float64(depth) * 55.0)
            var y = ys[at] + position * 76.0
            var palette = materialize[_BRANCH_COLORS]()
            var color = String(palette[siblings % len(palette)]) if anchor == root else colors[at]
            if anchor == root:
                for c in palette:
                    if not _has(used, String(c)):
                        color = String(c)
                        break
            var placed = False
            while not placed:  # (moved down until it sits on nothing)
                placed = True
                for q in range(len(ids)):
                    if abs(xs[q] - x) < 150 and abs(ys[q] - y) < 56:
                        placed = False
                if not placed:
                    y += 62
            var nid = "jam-" + stamp + "-" + String(k)
            var node = ('{"id": ' + json_string(nid) + ', "parentId": ' + json_string(anchor) + ', "text": ' + json_string(e.text) + ', "x": ' + _num(x) + ', "y": ' + _num(y)
                        + ', "color": ' + json_string(color) + ', "fontSize": ' + String(max(15, 25 - depth * 3)) + ', "bold": ' + ("true" if depth == 1 else "false")
                        + ', "font": ' + json_string(fonts[at]) + ', "presentation": ' + json_string(presentation) + ', "curve": ' + curves[at]
                        + (', "emoji": ' + json_string(e.emoji) if e.emoji != "" else String("")) + "}")
            added.append(node)
            ids.append(nid)
            parents.append(anchor)
            texts.append(e.text)
            xs.append(x)
            ys.append(y)
            colors.append(color)
            fonts.append(fonts[at])
            curves.append(curves[at])
            if e.id != "":
                handles.append((e.id, nid))
        elif e.op == "react":
            votes.append((at, e.vote, e.reason))
        else:
            var repeats = False
            for t in texts:
                if _same_words(t, e.text):
                    repeats = True
            for t in gtexts:
                if _same_words(t, e.text):
                    repeats = True
            if repeats:
                continue
            ghosts.append('{"id": ' + json_string("ghost-" + stamp + "-" + String(k)) + ', "parentId": ' + json_string(anchor) + ', "text": ' + json_string(e.text) + ', "why": ' + json_string(e.reason) + "}")
            gtexts.append(e.text)
    # the document again: its own nodes (a reaction's fields set), the new ones, the ghosts (the newest three)
    var out = String("{")
    for k in range(m.size(0)):
        var key = m.key(0, k)
        var v = m.at(0, k)
        if key == "ghosts":
            continue
        if out != "{":
            out += ", "
        out += json_string(key) + ": "
        if key == "nodes":
            out += "["
            for q in range(m.size(v)):
                if q > 0:
                    out += ", "
                var node = m.at(v, q)
                var vote = -1
                for w in range(len(votes)):
                    if votes[w][0] == q:
                        vote = w  # (the last reaction to a node wins, as Object.assign in turn)
                if vote < 0:
                    out += m.dump(node)
                    continue
                var nd = String("{")
                for f in range(m.size(node)):
                    var fk = m.key(node, f)
                    if fk == "vote" or fk == "reason":
                        continue
                    nd += (", " if nd != "{" else "") + json_string(fk) + ": " + m.dump(m.at(node, f))
                out += nd + (", " if nd != "{" else "") + '"vote": ' + json_string(votes[vote][1]) + ', "reason": ' + json_string(votes[vote][2]) + "}"
            for a in added:
                out += ", " + a
            out += "]"
        else:
            out += m.dump(v)
    if len(ghosts) > 0:
        out += ', "ghosts": ['
        var first = max(0, len(ghosts) - MAX_GHOSTS)
        for q in range(first, len(ghosts)):
            out += (", " if q > first else "") + ghosts[q]
        out += "]"
    return out + "}"


@fieldwise_init
struct Ghost(Copyable, Movable):
    var id: String
    var parent: String
    var text: String
    var why: String


def jam_ghosts(map_doc: String) -> List[Ghost]:
    """The suggestions waiting in a map document (its `ghosts`)."""
    var out = List[Ghost]()
    try:
        var m = Json.parse(map_doc)
        var g = m.get(0, "ghosts")
        if g >= 0 and m.kind(g) == J_ARRAY:
            for k in range(m.size(g)):
                var n = m.at(g, k)
                out.append(Ghost(m.text(m.get(n, "id")), m.text(m.get(n, "parentId")), m.text(m.get(n, "text")), m.text(m.get(n, "why"))))
    except:
        pass
    return out^


def is_jam(map_doc: String) -> Bool:
    """A map opened in jam mode (`"jam": true`, editor.js startJam)."""
    try:
        var m = Json.parse(map_doc)
        var j = m.get(0, "jam")
        return j >= 0 and m.flag(j)
    except:
        return False


def _without_ghost(m: Json, drop: String) -> String:
    var out = String("{")
    for k in range(m.size(0)):
        var key = m.key(0, k)
        var v = m.at(0, k)
        if key == "ghosts":
            var kept = List[String]()
            for q in range(m.size(v)):
                if m.text(m.get(m.at(v, q), "id")) != drop:
                    kept.append(m.dump(m.at(v, q)))
            if len(kept) == 0:
                continue
            out += (", " if out != "{" else "") + '"ghosts": ['
            for q in range(len(kept)):
                out += (", " if q > 0 else "") + kept[q]
            out += "]"
            continue
        out += (", " if out != "{" else "") + json_string(key) + ": " + m.dump(v)
    return out + "}"


def answer_ghost(map_doc: String, id: String, yes: Bool, stamp: String) raises -> String:
    """Yes: the ghost becomes a real branch under its parent (placed as a new branch is); no: it goes, nothing is added
    (mindmap/jam.js acceptGhost / dismissGhost)."""
    var m = Json.parse(map_doc)
    var found = Ghost("", "", "", "")
    for g in jam_ghosts(map_doc):
        if g.id == id:
            found = g.copy()
    var rest = _without_ghost(m, id)
    if not yes or found.id == "":
        return rest^
    var edits = JamEdits()
    edits.edits.append(JamEdit("add_branch", found.parent, found.text, "", "", "", ""))
    return apply_jam(rest, edits, stamp)


def start_jam(map_doc: String, title: String) raises -> String:
    """The map in jam mode: `"jam": true`, its centre idea the title (editor.js startJam)."""
    var m = Json.parse(map_doc)
    var root = m.text(m.get(0, "rootId"))
    var out = String("{")
    for k in range(m.size(0)):
        var key = m.key(0, k)
        if key == "jam":
            continue
        var v = m.at(0, k)
        out += (", " if out != "{" else "") + json_string(key) + ": "
        if key == "nodes":
            out += "["
            for q in range(m.size(v)):
                var n = m.at(v, q)
                if q > 0:
                    out += ", "
                if _id_text(m, m.get(n, "id")) != root:
                    out += m.dump(n)
                    continue
                var nd = String("{")
                for f in range(m.size(n)):
                    var fk = m.key(n, f)
                    nd += (", " if nd != "{" else "") + json_string(fk) + ": " + (json_string(title) if fk == "text" else m.dump(m.at(n, f)))
                out += nd + "}"
            out += "]"
        elif key == "title":
            out += json_string(title)
        else:
            out += m.dump(v)
    return out + ', "jam": true}'
