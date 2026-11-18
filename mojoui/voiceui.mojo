# mojoui.voiceui: the screens of a voice assistant (goal 72 M4), so the app only says what is on them. Two layouts that an
# app swaps between, Home (the big orb, a greeting, a few things to ask) and Work (the small orb beside what was said, the
# shelf of cards the agent built below), and the dock both share (mute, type, stop). Their spaces, sizes and type come from
# here and the theme, never from the app.
#
#   VoiceHome(OrbView(ORB, v, True), "Hi, I'm omx.", "Listening", lane, chips, dock)
#   VoiceWork(OrbView(ORB, v, False), "Listening", heard, reply, lane_badge, cards, dock)
#   VoiceLane("Local · Qwen 27B", "Cloud · Claude", on_cloud, LANE)    the chip and its switch (the tool `lane`)
#   VoiceDock(muted, typing, draft, MUTE, TYPE, STOP, DRAFT, SEND)       buttons are named mute, type, stop: an agent's tools
#   VoiceChips(["What is the capital of France?", …], CHIP)               one button per phrase, messages CHIP + k
#
# The orb and the rim come from mojoui.orb; the cards from mojoui.agentui.Screens.

from mojoui.chip import Badge, BADGE_OK, BADGE_WARN
from mojoui.view import (View, Text, Button, TextField, VStack, HStack, Spacer, Scroll, TITLE, HEADLINE, CAPTION, PLAIN, SUBTLE,
                         PROMINENT, CENTER, START, END)

def VoiceChips(phrases: List[String], first_msg: Int) -> View:
    """Things to ask, one tap each: the button's text is what is asked (message first_msg + its index)."""
    var items = List[View]()
    for k in range(len(phrases)):
        items.append(Button(phrases[k], first_msg + k, PLAIN).tag("ask-" + String(k + 1)).tooltip("Ask: " + phrases[k]))
    return VStack(items^, spacing=8).align(CENTER)


def VoiceLane(local: String, cloud: String, on_cloud: Bool, switch: Int) -> View:
    """The lane chip: which model answers, `local` (on this machine, a green dot) or `cloud` (an orange one; the app also
    shows mojoui.orb's rim while it is), and the button that switches between them."""
    var items = List[View]()
    items.append(Badge(cloud if on_cloud else local, BADGE_WARN if on_cloud else BADGE_OK, dot=True))
    items.append(Button("Switch lane", switch, SUBTLE).tag("lane").tooltip("Switch the lane the answers come from, this machine or the cloud."))
    return HStack(items^, spacing=8).align(CENTER)


def VoiceDock(muted: Bool, typing: Bool, draft: String, mute: Int, type_: Int, stop: Int, on_draft: Int, on_send: Int) -> View:
    """The row of controls under both screens: mute/unmute the microphone, open/close the typed input, stop the reply. While
    typing, the field takes the row above them. Each button's tag is the tool name an agent calls it by."""
    var row = List[View]()
    row.append(Button("Unmute" if muted else "Mute", mute, PROMINENT if muted else PLAIN).tag("mute").tooltip(
        "Turn the microphone off or on. Off, the assistant hears nothing."))
    row.append(Button("Close keyboard" if typing else "Type", type_, PLAIN).tag("type").tooltip("Show or hide the box for typing a question."))
    row.append(Button("Stop", stop, SUBTLE, icon="square").tag("stop").tooltip("Stop speaking and drop the answer being made."))
    var col = List[View]()
    if typing:
        col.append(TextField(draft, "Type to omx", on_draft, on_send).tag("question").tooltip("Type a question and press Enter."))
    col.append(HStack(row^, spacing=8).align(CENTER).justify(CENTER))
    return VStack(col^, spacing=8).align(CENTER).fill()


def VoiceHome(orb: View, greeting: String, status: String, lane: View, chips: View, dock: View) -> View:
    """Home: the orb fills the room, the greeting and what the assistant is doing under it with the lane it answers from,
    the things to ask, the dock."""
    var items = List[View]()
    items.append(orb.copy())
    items.append(Text(greeting, TITLE))
    items.append(Text(status, CAPTION))
    items.append(lane.copy())
    items.append(chips.copy())
    items.append(dock.copy())
    return VStack(items^, spacing=14).align(CENTER).fill().grow().padding(24).tag("voice-home")


def VoiceWork(orb: View, status: String, heard: String, reply: String, lane: View, var cards: List[View], dock: View) -> View:
    """Work: the small orb beside the status, what was heard and what is being said (the lane chip at the end), the shelf of
    cards below it (the newest first, the caller's order), the dock at the bottom."""
    var words = List[View]()
    words.append(Text(status, CAPTION))
    if heard != "":
        words.append(Text(heard, CAPTION))
    words.append(Text(reply if reply != "" else " ", HEADLINE))
    var head = List[View]()
    head.append(orb.copy())
    head.append(VStack(words^, spacing=4).align(START).grow())
    var items = List[View]()
    items.append(HStack(head^, spacing=14).align(CENTER).fill())
    items.append(lane.copy())
    items.append(Scroll(VStack(cards^, spacing=12).align(START).fill(), height=0).grow().fill().tag("shelf"))
    items.append(dock.copy())
    return VStack(items^, spacing=12).align(START).fill().grow().padding(20).tag("voice-work")
