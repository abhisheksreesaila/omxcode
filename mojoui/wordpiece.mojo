# mojoui.wordpiece: BERT's WordPiece tokenizer (uncased), for the text models packs hold (goal 51 M1). The same ids as
# Hugging Face's BertTokenizer for English text: lower-cased, split on whitespace and punctuation, each word as the
# longest pieces the vocabulary has ("##" continues a word), [UNK] for a word it can't spell, [CLS] … [SEP] around it.
#
#   var vocab = Vocab(pack + "/vocab.txt")
#   var ids = vocab.ids("Put the peach shirt in the box")      # [101, 2404, 1996, …, 102]
#
# Bytes above 127 (accents, other scripts) are kept inside words as they are (pieces end only between characters), not accent-stripped or split per CJK
# character as BERT's full basic tokenizer does: English is exact, other text close (a known difference).

comptime CLS = 101
comptime SEP = 102
comptime UNK = 100
comptime MAX_WORD = 100  # BERT's max_input_chars_per_word: a longer word is [UNK]


def _is_space(b: UInt8) -> Bool:
    return b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12


def _is_punct(b: UInt8) -> Bool:
    return (b >= 33 and b <= 47) or (b >= 58 and b <= 64) or (b >= 91 and b <= 96) or (b >= 123 and b <= 126)


struct Vocab(Movable):
    """A WordPiece vocabulary: a piece's id by its text."""

    var ids_of: Dict[String, Int]

    def __init__(out self, path: String) raises:
        self.ids_of = Dict[String, Int]()
        var text = open(path, "r").read()
        var k = 0
        for line in text.split("\n"):
            var w = String(line)
            if w.endswith("\r"):
                var cut = String(w[byte = 0 : w.byte_length() - 1])
                w = cut
            if w != "" or k < 30522:
                if w != "":
                    self.ids_of[w] = k
                k += 1

    def __len__(self) -> Int:
        return len(self.ids_of)

    def _word(self, word: String, mut out: List[Int]):
        """One word's pieces (greedy longest match), or [UNK]."""
        var n = word.byte_length()
        var bytes = word.as_bytes()
        if n > MAX_WORD:
            out.append(UNK)
            return
        var pieces = List[Int]()
        var start = 0
        while start < n:
            var end = n
            var found = -1
            while end > start:
                if end < n and (bytes[end] & 0xC0) == 0x80:  # (never inside a UTF-8 character: shorter by a whole one)
                    end -= 1
                    continue
                var sub = String(word[byte=start:end])
                if start > 0:
                    sub = "##" + sub
                var got = self.ids_of.get(sub)
                if got:
                    found = got.value()
                    break
                end -= 1
            if found < 0:
                out.append(UNK)
                return
            pieces.append(found)
            start = end
        for p in pieces:
            out.append(p)

    def ids(self, text: String, most: Int = 128) -> List[Int]:
        """[CLS], the text's pieces, [SEP]; at most `most` ids (cut before [SEP], as truncation does)."""
        var out = List[Int]()
        out.append(CLS)
        var low = text.lower()
        var bytes = low.as_bytes()
        var n = low.byte_length()
        var i = 0
        while i < n:
            var b = bytes[i]
            if _is_space(b) or b < 32 or b == 127:
                i += 1
                continue
            if _is_punct(b):
                self._word(String(low[byte = i : i + 1]), out)
                i += 1
                continue
            var j = i
            while j < n and not _is_space(bytes[j]) and not _is_punct(bytes[j]) and bytes[j] >= 32 and bytes[j] != 127:
                j += 1
            self._word(String(low[byte=i:j]), out)
            i = j
        if len(out) > most - 1:
            out.resize(most - 1, 0)
        out.append(SEP)
        return out^
