# Personal Note (web): a deletion made elsewhere is written back by the page's own late save

For the owner to file against ~/Projects/personalnotev2 (found by goal 79's both-open run, seed 101; see docs/goals/79-report.md).

**What happens.** A canvas is open in the web app. Another writer (an agent through the CLI or the API, or another app) deletes
an object of it. Within about a second the page's own pending save (its 650 ms debounce, or a save of words typed just before)
sends the whole board as the page holds it, and the server's merge adds the person's "unsaved edits" next to the other writer's
version. The deleted object is part of those edits (the page never removed it), so it comes back.

**Reproduce without the native app.** goal 79's `build/bothopenc.py` (the web alone): 5 times in 5.

**Why.** The merge is two-way: "add the other's new objects beside the person's unsaved edits" (src/modules/sync/controller.js:
`host.merge(note)`). Without the version both started from, a deletion on one side looks the same as an addition on the other.

**What pnote does instead (goal 82 M7, D-8603).** A three-way merge by object id (mojoui.merge3): base = the row as this window
last read it, theirs = the row now, mine = the save. An object they deleted that this window left alone stays deleted; their
additions and changes are taken; overlapping edits (both changed the same object, or one deleted what the other changed) are
not guessed at: held and said. Suggested fix for the web: keep the revision's content the page loaded (it already keeps the
revision number) and merge against it the same way.
