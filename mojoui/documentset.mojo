# mojoui.documentset: a folder of documents as one card (goal 41 M10). A generic component over mojoui.documentcard: open a
# folder (or one PDF) and page through its files; say which fields to read, as data (the labels printed on the forms,
# "Order no., Exceptions, Signed by"), and Read runs the OCR model over every page of every file (a job:
# mojoui.documentjobs.FolderFeed) and finds each label's value by geometry (mojoui.formfields). The answer is a table, one
# row per file (file + a column per field, named by the label: "Order no." → order_no), which the app shows as a
# table card (`fields_name()`: "<folder> fields") and links like any table; each field's page and box stay here, so a row
# followed to this card (mojoui.links) shows its file with the chosen field (`Highlight`) marked.
#
#   var docs = DocumentSet("data/bol", msg_base=7700, canvas=270)     # a folder of PDFs, or one PDF
#   docs.set_labels("Order no., Carrier, Exceptions")              # the fields to find (data, never code)
#   update():  if docs.update(event): if docs.read_asked: feed.read(docs, OcrModel())   (documentjobs)
#   docs.take_read(words, fields)                                    # what the job read, per file
#   var r = docs.react(follow)                                       # a linked row: its file shown, its field highlighted
#   view():    docs.view().at(docs.card.x, docs.card.y).width(docs.card.w).height(docs.card.h)
#   draw():    if canvas == docs.card.canvas: docs.card.draw(surface, palette)
#
# Nothing here knows a form: the labels and the field to highlight come from whoever uses it (a person typing them, an
# agent's tool call). No omxcore (the job is in mojoui.documentjobs), so it tests with a plain `mojo run`.

from std.os import listdir
from std.os.path import isdir
from mojoui.app import Event
from mojoui.files import file_name, file_stem
from mojoui.pdfsource import Box
from mojoui.documentcard import DocumentCard, DOC_MESSAGES, DOC_CHROME_H, is_document_file
from mojoui.formfields import FieldLabel, Field
from mojoui.texttable import TextTable, csv_field, fixed
from mojoui.links import CardRows, Follow, Reaction, REACT_HIGHLIGHT
from mojoui.sqlname import sql_name
from mojoui.mediacard import HEAD_H
from mojoui.view import (View, Text, Button, TextField, Dropdown, Canvas, HStack, VStack, Spacer, Card, ProgressBar, HEADLINE,
                         CAPTION, ICON_ONLY, SUBTLE, CENTER, TONE_ACCENT)

comptime SET_PREV = DOC_MESSAGES + 0  # a set's own messages, after its document card's (msg_base + …)
comptime SET_NEXT = DOC_MESSAGES + 1
comptime SET_FILE = DOC_MESSAGES + 2  # the file dropdown (event.number)
comptime SET_LABELS = DOC_MESSAGES + 3  # the labels field: typing
comptime SET_LABELS_GO = DOC_MESSAGES + 4  # … Return: kept, and read
comptime SET_READ = DOC_MESSAGES + 5
comptime SET_FOCUS = DOC_MESSAGES + 6  # the Highlight dropdown (event.number)
comptime SET_CLOSE = DOC_MESSAGES + 7
comptime SET_MESSAGES = DOC_MESSAGES + 8
comptime SET_BAR_H = 40  # the second bar (fields, Read, Highlight)


def documents_in(path: String) raises -> List[String]:
    """The PDFs of a folder, sorted by name (a PDF: just it). Raises when there are none."""
    var out = List[String]()
    if isdir(path):
        var names = listdir(path)
        sort(names)
        var base = path if path.endswith("/") else path + "/"
        for n in names:
            if is_document_file(n):
                out.append(base + n)
    elif is_document_file(path):
        out.append(path)
    if len(out) == 0:
        raise Error("no PDF documents in " + path)
    return out^


def parse_labels(text: String) -> List[FieldLabel]:
    """ "Order no., Customer, Signed by" → labels, each named by its SQL name (order_no, customer, signed_by)."""
    var out = List[FieldLabel]()
    for part in text.split(","):
        var label = String(String(part).strip())
        if label != "":
            out.append(FieldLabel(sql_name(label), label))
    return out^


struct DocumentSet(Movable):
    var name: String  # the card's name: the folder's (or the one file's stem)
    var folder: String
    var files: List[String]
    var at: Int  # the file shown
    var card: DocumentCard  # shows files[at]
    var labels_text: String
    var labels: List[FieldLabel]
    var words: List[TextTable]  # per file, once read ([] before)
    var fields: List[List[Field]]  # per file, one per label
    var focus: Int  # the label a followed row highlights
    var msg_base: Int
    var read_asked: Bool  # the last update() asked to read (Read, or Return in the labels field)
    var closed: Bool  # the last update() was its close button
    var problem: String
    var reading: Bool  # a read runs (the card says so)

    def __init__(out self, path: String, msg_base: Int, canvas: Int, x: Int = 0, y: Int = 0, w: Int = 520) raises:
        var p = String(path.rstrip("/")) if path.byte_length() > 1 else path
        self.files = documents_in(p)
        self.folder = p
        self.name = file_name(p) if isdir(p) else file_stem(p)
        self.at = 0
        self.card = DocumentCard(self.files[0], msg_base, canvas, x, y, w)
        self.card.h = self.card.h + SET_BAR_H + 8
        self.labels_text = String("")
        self.labels = List[FieldLabel]()
        self.words = List[TextTable]()
        self.fields = List[List[Field]]()
        self.focus = 0
        self.msg_base = msg_base
        self.read_asked = False
        self.closed = False
        self.problem = String("")
        self.reading = False

    # ---------- what it is ----------

    def fields_name(self) -> String:
        """The name of the table its fields make (the app's table card): "<name> fields"."""
        return self.name + " fields"

    def is_read(self) -> Bool:
        return len(self.fields) == len(self.files) and len(self.labels) > 0

    def file(self) -> String:
        return file_name(self.files[self.at])

    def set_labels(mut self, text: String):
        """The fields to read, as the labels printed beside them, comma-separated. The highlighted field keeps its name."""
        var was = self.labels[self.focus].name if 0 <= self.focus < len(self.labels) else String("")
        self.labels_text = text
        self.labels = parse_labels(text)
        self.focus = 0
        for i in range(len(self.labels)):
            if self.labels[i].name == was:
                self.focus = i

    def set_focus(mut self, name: String) -> Bool:
        """Which field a followed row highlights, by its name or its label."""
        for i in range(len(self.labels)):
            if self.labels[i].name == name or self.labels[i].label == name:
                self.focus = i
                return True
        return False

    def take_read(mut self, var words: List[TextTable], var fields: List[List[Field]]):
        self.words = words^
        self.fields = fields^
        self.reading = False
        self.card.status = ""
        self.card.progress = -1
        self.card.version += 1

    def columns(self) -> List[String]:
        """Its table's columns: file, then one per field."""
        var out: List[String] = ["file"]
        for l in self.labels:
            out.append(l.name)
        return out^

    def rows(self) -> List[List[String]]:
        """One row per file: its name and each field's value ("" not found)."""
        var out = List[List[String]]()
        for i in range(len(self.files)):
            var r: List[String] = [file_name(self.files[i])]
            for k in range(len(self.labels)):
                r.append(self.fields[i][k].value if i < len(self.fields) and k < len(self.fields[i]) else String(""))
            out.append(r^)
        return out^

    def csv(self) -> String:
        var out = String()
        var cols = self.columns()
        for c in range(len(cols)):
            out += ("," if c > 0 else "") + csv_field(cols[c])
        out += "\n"
        for r in self.rows():
            for c in range(len(r)):
                out += ("," if c > 0 else "") + csv_field(r[c])
            out += "\n"
        return out^

    def card_rows(self) -> CardRows:
        """Its rows as mojoui.links reads them: the table's columns plus the highlighted field's page and box."""
        var cols = self.columns()
        for c in ["page", "x", "y", "w", "h"]:
            cols.append(c)
        var out = CardRows(self.name, self.fields_name(), cols)
        out.highlights("page", "x", "y", "w", "h")
        var rows = self.rows()
        for i in range(len(rows)):
            var r = rows[i].copy()
            if i < len(self.fields) and 0 <= self.focus < len(self.fields[i]) and self.fields[i][self.focus].found:
                ref f = self.fields[i][self.focus]
                r.append(String(f.page))
                r.append(fixed(f.box.x, 3))
                r.append(fixed(f.box.y, 3))
                r.append(fixed(f.box.w, 3))
                r.append(fixed(f.box.h, 3))
            out.add_row(r)
        return out^

    def describe(self) -> String:
        """For an agent: the folder, the file shown, the fields read, what is highlighted (page points)."""
        var out = self.name + ": " + String(len(self.files)) + (" document" if len(self.files) == 1 else " documents") + ", showing " + self.file()
        out += " (" + String(self.at + 1) + " of " + String(len(self.files)) + "), page " + String(self.card.page + 1)
        if self.is_read():
            out += "; fields read: " + ", ".join(self.columns()[1:].copy())
        elif len(self.labels) > 0:
            out += "; fields to read: " + self.labels_text
        for m in self.card.marks:
            out += "; highlighted " + self.focus_name() + " on page " + String(m.page + 1) + " at " + fixed(m.box.x, 1) + "," + fixed(m.box.y, 1) + " " + fixed(m.box.w, 1) + "x" + fixed(m.box.h, 1) + " pt"
        return out^

    def focus_name(self) -> String:
        return self.labels[self.focus].name if 0 <= self.focus < len(self.labels) else String("")

    # ---------- moving around ----------

    def show(mut self, i: Int) raises:
        var k = min(max(i, 0), len(self.files) - 1)
        if k != self.at:
            self.card.open(self.files[k])
            self.at = k
        else:
            self.card.clear_highlights()

    def react(mut self, f: Follow) -> Reaction:
        """A linked row: the file whose row matches is shown with the highlighted field's box marked (page points)."""
        var r = self.card_rows().react(f)
        if r.action == REACT_HIGHLIGHT and len(r.rows) > 0:
            try:
                self.show(r.rows[0])
                self.card.highlight(r.page, Box(r.x, r.y, r.w, r.h))
            except e:
                self.problem = String(e)
        return r^

    # ---------- events ----------

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + SET_MESSAGES

    def update(mut self, event: Event) -> Bool:
        self.read_asked = False
        self.closed = False
        if not self.owns(event.message):
            return False
        if self.card.update(event):
            self.closed = self.card.closed
            return True
        var m = event.message - self.msg_base
        try:
            if m == SET_PREV:
                self.show(self.at - 1)
            elif m == SET_NEXT:
                self.show(self.at + 1)
            elif m == SET_FILE:
                self.show(event.number)
            elif m == SET_LABELS:
                self.labels_text = event.text
            elif m == SET_LABELS_GO or m == SET_READ:
                var text = event.text if m == SET_LABELS_GO else self.labels_text.copy()
                self.set_labels(text)
                if len(self.labels) == 0:
                    self.problem = "Say which fields to read: the labels printed beside them, comma-separated"
                else:
                    self.read_asked = True
            elif m == SET_FOCUS:
                if 0 <= event.number < len(self.labels):
                    self.focus = event.number
            elif m == SET_CLOSE:
                self.closed = True
        except e:
            self.problem = String(e)
        self.card.version += 1
        return True

    # ---------- view ----------

    def view(self) -> View:
        var b = self.msg_base
        var top = List[View]()
        top.append(Text(self.name, HEADLINE).tag("documents-title").tooltip(String(len(self.files)) + " documents in " + self.folder))
        if self.card.w >= 680:  # (narrower: the count is in the title's tooltip and the file list)
            top.append(Text(String(len(self.files)) + (" document" if len(self.files) == 1 else " documents"), CAPTION).tone(TONE_ACCENT))
        top.append(Spacer())
        if len(self.files) > 1:
            top.append(Button("Previous document", b + SET_PREV, ICON_ONLY, icon="back").tag("document-prev").tooltip("The previous document"))
            var names = List[String]()
            for f in self.files:
                names.append(file_name(f))
            top.append(Dropdown(names^, self.at, b + SET_FILE).tag("document-file").tooltip("The document shown"))
            top.append(Button("Next document", b + SET_NEXT, ICON_ONLY, icon="chevron-right").tag("document-next").tooltip("The next document"))
        for v in self.card.controls():
            top.append(v.copy())
        top.append(Button("Remove", b + SET_CLOSE, ICON_ONLY, icon="close").tag("close-" + sql_name(self.name).replace("_", "-")).tooltip("Close " + self.name))
        var bar = List[View]()
        if self.card.status != "":
            bar.append(Text(self.card.status + (" · " + String(self.card.progress) + "%" if self.card.progress >= 0 else String("")), CAPTION).tag("documents-status"))
            if self.card.progress >= 0:
                bar.append(ProgressBar(self.card.progress).width(120).label(self.card.status))
            bar.append(Spacer())
        else:
            bar.append(TextField(self.labels_text, "Fields: the labels on the page, e.g. Invoice no., Total", b + SET_LABELS, b + SET_LABELS_GO).fill().grow()
                       .tag("fields").label("Fields to read").tooltip("The fields to read, as the labels printed beside their values, comma-separated; Return reads every document"))
            bar.append(Button("Read" if not self.is_read() else "Read again", b + SET_READ, SUBTLE, icon="search").tag("read-documents")
                       .tooltip("Read every page of every document (OCR, in the background) and find the fields: a table, one row per document"))
            if len(self.labels) > 0:
                var opts = List[String]()
                for l in self.labels:
                    opts.append(l.label)
                bar.append(Text("Highlight", CAPTION))
                bar.append(Dropdown(opts^, self.focus, b + SET_FOCUS).tag("highlight-field").tooltip("The field a linked row marks on its document"))
        if self.problem != "":
            bar.append(Text(self.problem, CAPTION))
        var head = HStack(top^, spacing=8).fill().align(CENTER).height(HEAD_H)
        var second = HStack(bar^, spacing=8).fill().align(CENTER).height(SET_BAR_H)
        var body = self.card.body()
        body = body^.label(self.describe())
        return Card(head^, second^, body^, spacing=4)
