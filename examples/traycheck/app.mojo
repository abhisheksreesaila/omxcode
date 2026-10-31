# traycheck (goal 45 M1): the smallest app in background mode. Closing its window leaves it running (App.background),
# a tray item opens the window again (mojoui.tray, published by the host), and closing sends a notification
# (mojoui.notify) whose text includes $TRAYCHECK_TEXT. TRAYCHECK_BACKGROUND=0 turns background mode off (closing ends it).
# Checked by docs/goals/45-check.py M1 on a private session bus.

from mojoui import App, Event, View, VStack, Text, CAPTION, HEADLINE
from mojoui.notify import notify
from mojoui.shared import environment
from mojoui.theme import Theme
from themes.liquid import liquid


struct Main(App):
    var shown: Bool
    var opened: Int

    def __init__(out self):
        self.shown = True
        self.opened = 0
        print("TRAYCHECK: built", flush=True)  # (a second launch hands over before this runs: probe fixes, D-1706)

    def title(self) -> String:
        return "Tray check"

    def theme(self) -> Theme:
        return liquid()

    @staticmethod
    def one_instance() -> String:
        return "traycheck"  # (a second launch opens this one's window and builds nothing)

    def background(self) -> Bool:
        return environment("TRAYCHECK_BACKGROUND", "1") != "0"

    def window_shown(mut self, shown: Bool):
        self.shown = shown
        if shown:
            self.opened += 1
            print("TRAYCHECK: window open again (" + String(self.opened) + ")", flush=True)
            return
        print("TRAYCHECK: window closed, still running", flush=True)
        try:
            notify("Tray check", "Still running in the background", "Closed, still here: " + environment("TRAYCHECK_TEXT", ""))
        except e:
            print("TRAYCHECK: no notification (" + String(e) + ")", flush=True)

    def update(mut self, event: Event):
        pass

    def view(self) -> View:
        return VStack(
            Text("Tray check", HEADLINE),
            Text("Close this window: the app keeps running in the tray.", CAPTION),
            spacing=8,
        ).padding(20)
