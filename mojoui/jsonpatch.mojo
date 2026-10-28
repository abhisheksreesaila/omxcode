# mojoui.jsonpatch: a JSON document you can change, and JSON Patch (RFC 6902) on it (goal 35 M1, D-685). AG-UI's
# STATE_DELTA is a JSON Patch; an app's shared state is a JDoc. Pointers are RFC 6901 ("/a/b~1c/0", "-" past an array's end).
#
#   var state = JDoc.parse('{"count": 1}')
#   state.patch('[{"op": "replace", "path": "/count", "value": 3}]')     # raises (and changes nothing) if any op fails
#   state.dump()                                                       # '{"count":3}'
#   state.set("/form/name", json_string("Ada"))                        # add or replace one value (parents made as objects)
#
# A patch is atomic: it runs on a copy, which replaces the document only when every op succeeded.

from mojoui.json import Json, json_string, J_NULL, J_BOOL, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT

comptime MAX_PATCH_OPS = 10_000


struct JDoc(Copyable, Movable):
    """A JSON value as nodes: kinds (mojoui.json's J_*), a scalar's text (a string's value, a number's literal, "true" /
    "false"), and each array's or object's children (objects keep their keys, in order)."""

    var kinds: List[Int]
    var texts: List[String]
    var kids: List[List[Int]]
    var keys: List[List[String]]
    var root: Int

    def __init__(out self):
        self.kinds = List[Int]()
        self.texts = List[String]()
        self.kids = List[List[Int]]()
        self.keys = List[List[String]]()
        self.root = 0
        self.root = self.add(J_NULL, "null")

    @staticmethod
    def parse(text: String) raises -> JDoc:
        var j = Json.parse(text)
        var d = JDoc()
        d.root = d.take(j, 0)
        return d^

    def add(mut self, kind: Int, text: String) -> Int:
        self.kinds.append(kind)
        self.texts.append(text)
        self.kids.append(List[Int]())
        self.keys.append(List[String]())
        return len(self.kinds) - 1

    def take(mut self, j: Json, n: Int) -> Int:
        """Node `n` of a parsed Json (and everything under it) as new nodes here."""
        var k = j.kind(n)
        if k == J_STRING:
            return self.add(J_STRING, j.text(n))
        if k == J_NUMBER:
            return self.add(J_NUMBER, String(j.number(n)) if j.is_whole(n) else String(j.real(n)))
        if k == J_BOOL:
            return self.add(J_BOOL, "true" if j.flag(n) else "false")
        if k == J_NULL:
            return self.add(J_NULL, "null")
        var me = self.add(k, "")
        for i in range(j.size(n)):
            var c = self.take(j, j.at(n, i))
            self.kids[me].append(c)
            if k == J_OBJECT:
                self.keys[me].append(j.keys[n][i])
        return me

    def clone(mut self, n: Int) -> Int:
        """A deep copy of node `n` (copy: later changes to one don't show in the other)."""
        var kind = self.kinds[n]
        var text = self.texts[n]
        var me = self.add(kind, text)
        for i in range(len(self.kids[n])):
            var c = self.clone(self.kids[n][i])
            self.kids[me].append(c)
            if self.kinds[n] == J_OBJECT:
                var key = self.keys[n][i]
                self.keys[me].append(key)
        return me

    def graft(mut self, other: JDoc, n: Int) -> Int:
        """Node `n` of another document as new nodes here."""
        var me = self.add(other.kinds[n], other.texts[n])
        for i in range(len(other.kids[n])):
            var c = self.graft(other, other.kids[n][i])
            self.kids[me].append(c)
            if other.kinds[n] == J_OBJECT:
                self.keys[me].append(other.keys[n][i])
        return me

    # ---- reading ----

    def dump(self, n: Int = -1) -> String:
        """Node `n` (the root by default) as compact JSON."""
        var at = self.root if n < 0 else n
        var k = self.kinds[at]
        if k == J_STRING:
            return json_string(self.texts[at])
        if k == J_ARRAY:
            var out = String("[")
            for i in range(len(self.kids[at])):
                out += ("," if i > 0 else "") + self.dump(self.kids[at][i])
            return out + "]"
        if k == J_OBJECT:
            var out = String("{")
            for i in range(len(self.kids[at])):
                out += ("," if i > 0 else "") + json_string(self.keys[at][i]) + ":" + self.dump(self.kids[at][i])
            return out + "}"
        return self.texts[at]

    def find(self, pointer: String) -> Int:
        """The node at an RFC 6901 pointer, or -1."""
        try:
            var toks = tokens(pointer)
            var n = self.root
            for t in toks:
                n = self.child(n, t)
                if n < 0:
                    return -1
            return n
        except:
            return -1

    def child(self, n: Int, token: String) -> Int:
        if self.kinds[n] == J_OBJECT:
            for i in range(len(self.keys[n])):
                if self.keys[n][i] == token:
                    return self.kids[n][i]
            return -1
        if self.kinds[n] == J_ARRAY:
            var i = index_of(token, len(self.kids[n]) - 1)
            return self.kids[n][i] if i >= 0 else -1
        return -1

    def text_at(self, pointer: String, default: String = "") -> String:
        var n = self.find(pointer)
        return self.texts[n] if n >= 0 and self.kinds[n] == J_STRING else default

    def flag_at(self, pointer: String, default: Bool = False) -> Bool:
        var n = self.find(pointer)
        return self.texts[n] == "true" if n >= 0 and self.kinds[n] == J_BOOL else default

    def numbers_at(self, pointer: String) -> List[Float64]:
        """An array of numbers at `pointer` (anything else in it is skipped; none: empty)."""
        var out = List[Float64]()
        var n = self.find(pointer)
        if n < 0 or self.kinds[n] != J_ARRAY:
            return out^
        for c in self.kids[n]:
            if self.kinds[c] == J_NUMBER:
                try:
                    out.append(atof(self.texts[c]))
                except:
                    pass
        return out^

    def equal(self, a: Int, other: JDoc, b: Int) -> Bool:
        """JSON equality (RFC 6902's test): numbers by value, objects by their members whatever the order."""
        var ka = self.kinds[a]
        if ka != other.kinds[b]:
            return False
        if ka == J_NUMBER:
            try:
                return atof(self.texts[a]) == atof(other.texts[b])
            except:
                return self.texts[a] == other.texts[b]
        if ka == J_ARRAY:
            if len(self.kids[a]) != len(other.kids[b]):
                return False
            for i in range(len(self.kids[a])):
                if not self.equal(self.kids[a][i], other, other.kids[b][i]):
                    return False
            return True
        if ka == J_OBJECT:
            if len(self.kids[a]) != len(other.kids[b]):
                return False
            for i in range(len(self.kids[a])):
                var found = -1
                for k in range(len(other.keys[b])):
                    if other.keys[b][k] == self.keys[a][i]:
                        found = other.kids[b][k]
                if found < 0 or not self.equal(self.kids[a][i], other, found):
                    return False
            return True
        return self.texts[a] == other.texts[b]

    # ---- changing ----

    def set(mut self, pointer: String, value_json: String) raises:
        """Adds or replaces the value at `pointer` (missing parents are made as objects): an app's edit of shared state."""
        var v = JDoc.parse(value_json)
        var toks = tokens(pointer)
        if len(toks) == 0:
            self.root = self.graft(v, v.root)
            return
        var n = self.root
        for i in range(len(toks) - 1):
            var c = self.child(n, toks[i])
            if c < 0:
                if self.kinds[n] != J_OBJECT:
                    raise Error("no " + pointer)
                c = self.add(J_OBJECT, "")
                self.kids[n].append(c)
                self.keys[n].append(toks[i])
            n = c
        var node = self.graft(v, v.root)
        self.put(n, toks[len(toks) - 1], node, True)

    def put(mut self, parent: Int, token: String, node: Int, replace_member: Bool) raises:
        """RFC 6902 add into `parent`: an object's member (set), an array's index (insert) or "-" (append)."""
        if self.kinds[parent] == J_OBJECT:
            for i in range(len(self.keys[parent])):
                if self.keys[parent][i] == token:
                    self.kids[parent][i] = node
                    return
            self.kids[parent].append(node)
            self.keys[parent].append(token)
        elif self.kinds[parent] == J_ARRAY:
            var size = len(self.kids[parent])
            if token == "-":
                self.kids[parent].append(node)
                return
            var i = index_of(token, size)  # (add may insert at the end: index == size)
            if i < 0:
                raise Error("the index " + token + " is out of range")
            self.kids[parent].insert(i, node)
        else:
            raise Error("the parent is neither an object nor an array")

    def parent_of(self, toks: List[String]) raises -> Int:
        var n = self.root
        for i in range(len(toks) - 1):
            n = self.child(n, toks[i])
            if n < 0:
                raise Error("the path's parent doesn't exist")
        return n

    def detach(mut self, toks: List[String]) raises -> Int:
        """Removes the value at the pointer's tokens from its parent; returns its node."""
        var p = self.parent_of(toks)
        var last = toks[len(toks) - 1]
        if self.kinds[p] == J_OBJECT:
            for i in range(len(self.keys[p])):
                if self.keys[p][i] == last:
                    var n = self.kids[p].pop(i)
                    _ = self.keys[p].pop(i)
                    return n
            raise Error("no member " + last)
        if self.kinds[p] == J_ARRAY:
            var i = index_of(last, len(self.kids[p]) - 1)
            if i < 0:
                raise Error("the index " + last + " is out of range")
            return self.kids[p].pop(i)
        raise Error("the path's parent is neither an object nor an array")

    def apply_op(mut self, ops: Json, op: Int) raises:
        if ops.kind(op) != J_OBJECT:
            raise Error("an operation that isn't an object")
        for a in range(len(ops.keys[op])):
            for b in range(a + 1, len(ops.keys[op])):
                if ops.keys[op][a] == ops.keys[op][b]:
                    raise Error("an operation with the member " + json_string(ops.keys[op][a]) + " twice")
        var name_at = ops.get(op, "op")
        var path_at = ops.get(op, "path")
        if ops.kind(name_at) != J_STRING:
            raise Error("an operation without its op")
        if ops.kind(path_at) != J_STRING:
            raise Error("an operation without its path")
        var name = ops.text(name_at)
        var path = ops.text(path_at)
        var toks = tokens(path)
        if name == "add" or name == "replace" or name == "test":
            var v_at = ops.get(op, "value")
            if v_at < 0:
                raise Error(name + " without a value")
            var node = self.take(ops, v_at)
            if name == "test":
                var at = self.find(path)
                if at < 0:
                    raise Error("test: nothing at " + path)
                if not self.equal(at, self, node):
                    raise Error("test failed at " + path)
                return
            if name == "replace":
                if self.find(path) < 0:
                    raise Error("replace: nothing at " + path)
                if len(toks) == 0:
                    self.root = node
                    return
                var p = self.parent_of(toks)
                var last = toks[len(toks) - 1]
                if self.kinds[p] == J_ARRAY:
                    self.kids[p][index_of(last, len(self.kids[p]) - 1)] = node
                else:
                    self.put(p, last, node, True)
                return
            if len(toks) == 0:
                self.root = node
                return
            self.put(self.parent_of(toks), toks[len(toks) - 1], node, True)
        elif name == "remove":
            if len(toks) == 0:
                raise Error("remove: can't remove the whole document")
            _ = self.detach(toks)
        elif name == "move" or name == "copy":
            var from_at = ops.get(op, "from")
            if ops.kind(from_at) != J_STRING:
                raise Error(name + " without from")
            var src = ops.text(from_at)
            var ftoks = tokens(src)
            var at = self.find(src)
            if at < 0:
                raise Error(name + ": nothing at " + src)
            if name == "move":
                if src == path:
                    return
                if path.startswith(src + "/"):
                    raise Error("move: a value can't move into itself")
                var node = at
                if len(ftoks) == 0:
                    raise Error("move: can't move the whole document")
                _ = self.detach(ftoks)
                if len(toks) == 0:
                    self.root = node
                else:
                    self.put(self.parent_of(toks), toks[len(toks) - 1], node, True)
            else:
                var node = self.clone(at)
                if len(toks) == 0:
                    self.root = node
                else:
                    self.put(self.parent_of(toks), toks[len(toks) - 1], node, True)
        else:
            raise Error("an unknown op " + json_string(name))

    def patch(mut self, patch_json: String) raises:
        """Applies a JSON Patch (an array of operations) atomically: on any failure, raises and changes nothing."""
        var ops = Json.parse(patch_json)
        self.patch_at(ops, 0)

    def patch_at(mut self, ops: Json, at: Int) raises:
        """Applies the patch at node `at` of a parsed Json (an AG-UI STATE_DELTA's delta), atomically."""
        if ops.kind(at) != J_ARRAY:
            raise Error("a patch is an array of operations")
        if ops.size(at) > MAX_PATCH_OPS:
            raise Error("a patch of more than 10,000 operations")
        var work = self.copy()
        for i in range(ops.size(at)):
            try:
                work.apply_op(ops, ops.at(at, i))
            except e:
                raise Error("operation " + String(i) + ": " + String(e))
        work.compact()
        self = work^

    def compact(mut self):
        """Drops nodes nothing points at any more (after many patches, a long-lived state stays small)."""
        if len(self.kinds) < 64:
            return
        var fresh = JDoc()
        fresh.root = fresh.graft(self, self.root)
        self = fresh^


def tokens(pointer: String) raises -> List[String]:
    """An RFC 6901 pointer's reference tokens ("" is the whole document); ~1 is "/", ~0 is "~"."""
    var out = List[String]()
    if pointer.byte_length() == 0:
        return out^
    if not pointer.startswith("/"):
        raise Error("a pointer that doesn't start with / (" + pointer + ")")
    var parts = String(pointer[byte = 1 :]).split("/")
    for p in parts:
        var t = String(p)
        if t.find("~") >= 0:
            var b = t.as_bytes()
            for i in range(len(b)):
                if b[i] == 126 and (i + 1 >= len(b) or (b[i + 1] != 48 and b[i + 1] != 49)):
                    raise Error("a bad escape in the pointer " + pointer)
            t = t.replace("~1", "/").replace("~0", "~")
        out.append(t)
    return out^


def index_of(token: String, last: Int) -> Int:
    """An array index token (digits, no leading zero) up to `last`, or -1."""
    var n = token.byte_length()
    if n == 0 or n > 9:
        return -1
    var b = token.as_bytes()
    if n > 1 and b[0] == 48:
        return -1
    var v = 0
    for c in b:
        if c < 48 or c > 57:
            return -1
        v = v * 10 + Int(c) - 48
    return v if v <= last else -1
