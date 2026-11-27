# mojoui.systemask (goal 82): what an app asks the operating system for in its own words, from update(), with no button to hang it
# on: the system's file picker and save dialog, its print dialog for a PDF, its share sheet, full screen. Each host does it with
# the platform's own API (GTK: GtkFileDialog, GtkPrintUnixDialog + GtkPrintJob, GtkFileLauncher, gtk_window_fullscreen; AppKit:
# NSOpenPanel, NSSavePanel, PDFKit's print operation, NSSharingServicePicker, toggleFullScreen:) and answers with an Event.
#
#   var sys = SystemAsks()                       in the app; App.asks() returns sys.take()
#   sys.pick_file(PICKED, "Add a picture", ".png,.jpg,.jpeg,.webp,.gif")   → Event(PICKED, text=path) once per file chosen (nothing: cancelled)
#   sys.save_file(SAVED, "Save the PDF", "Note.pdf")                        → Event(SAVED, text=path); the app writes it
#   sys.print_pdf(PRINTED, "/tmp/note.pdf", "Garden plan")                  → Event(PRINTED, text="printed" | "cancelled" | why it failed)
#   sys.share(SHARED, "/tmp/note.png")                                       → Event(SHARED, text="shown" | why not)
#   sys.full_screen(True)                                                    (no answer)
#
# Tests can't drive a system dialog; a host prints "ASK: <kind> <title>" when it opens one and the test step `answer:<text>`
# answers the last one asked as the dialog would (MOJOUI_ASK_DRY=1: dialogs aren't opened at all, only printed).

comptime ASK_PICK = 1
comptime ASK_SAVE = 2
comptime ASK_PRINT = 3
comptime ASK_SHARE = 4
comptime ASK_FULLSCREEN = 5


@fieldwise_init
struct SystemAsk(Copyable, Movable):
    var kind: Int
    var msg: Int  # the answer's message (0: none wanted)
    var title: String  # the dialog's title, a print job's name
    var path: String  # the file to print or share; a save dialog's suggested name
    var accept: String  # a picker's file types (".png,.jpg"); "1"/"0" for full screen

    def kind_name(self) -> String:
        var names: List[String] = ["", "pick", "save", "print", "share", "fullscreen"]
        return names[self.kind] if self.kind > 0 and self.kind < len(names) else String("?")


struct SystemAsks(Movable):
    """The app's outbox of system asks (App.asks returns take())."""
    var asks: List[SystemAsk]

    def __init__(out self):
        self.asks = List[SystemAsk]()

    def pick_file(mut self, msg: Int, title: String, accept: String = ""):
        self.asks.append(SystemAsk(ASK_PICK, msg, title, "", accept))

    def save_file(mut self, msg: Int, title: String, suggested: String):
        self.asks.append(SystemAsk(ASK_SAVE, msg, title, suggested, ""))

    def print_pdf(mut self, msg: Int, pdf: String, job: String):
        self.asks.append(SystemAsk(ASK_PRINT, msg, job, pdf, ""))

    def share(mut self, msg: Int, path: String, title: String = "Share"):
        self.asks.append(SystemAsk(ASK_SHARE, msg, title, path, ""))

    def full_screen(mut self, on: Bool):
        self.asks.append(SystemAsk(ASK_FULLSCREEN, 0, "", "", "1" if on else "0"))

    def take(mut self) -> List[SystemAsk]:
        var out = self.asks^
        self.asks = List[SystemAsk]()
        return out^
